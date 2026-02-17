#include <sourcemod>
#include <sdktools>
#include <sdktools_functions>
#include <sdktools_voice>
#include <clientprefs>
#include <basecomm>
#include <morecolors>

#pragma semicolon 1
#pragma newdecls required

#define MAX_FILTERS 128
#define MAX_BLACKLIST 128
#define MAX_WORD_LENGTH 64
#define MAX_FORCED_STATUS 128
#define MAX_COMMANDS 64
#define FILTERS_OUTBOX_CLEANUP_INTERVAL 120
#define FILTERS_OUTBOX_RETENTION_SECONDS 3600
#define FILTERS_IGNORED_STEAMID64 "76561199812613650" // [U:1:1852347922]
#define REDLIST_RAPES_THRESHOLD 1
#define PRENAME_MAX_PATTERN 64
#define PRENAME_MAX_RENAME 64

// Player state structure
enum struct PlayerState
{
    bool isWhitelisted;        // Player bypasses all filters and blacklist
    bool isFilterWhitelisted;  // Player bypasses word filters only
    bool isBlacklisted;        // Player cannot send any messages
    bool isredlisted;         // Player cannot hear blacklisted clients
    int rapesGiven;
    int whaleKills;
    bool hugsStatsLoaded;
    bool whaleStatsLoaded;
    bool cookiesProcessed;
}

PlayerState g_PlayerState[MAXPLAYERS + 1];
bool g_VoiceBlocked[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_AutoRedlistKills[MAXPLAYERS + 1];
int g_AutoRedlistRapes[MAXPLAYERS + 1];
bool g_AutoRedlistGotKills[MAXPLAYERS + 1];
bool g_AutoRedlistGotRapes[MAXPLAYERS + 1];

native int Hugs_GetRapesGiven(int client);
native bool Hugs_AreStatsLoaded(int client);
native int WhaleTracker_GetCumulativeKills(int client);
native bool WhaleTracker_AreStatsLoaded(int client);

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("filters");
    CreateNative("Filters_IsRedlisted", Native_Filters_IsRedlisted);
    CreateNative("Filters_GetChatName", Native_Filters_GetChatName);
    MarkNativeAsOptional("Hugs_GetRapesGiven");
    MarkNativeAsOptional("Hugs_AreStatsLoaded");
    MarkNativeAsOptional("WhaleTracker_GetCumulativeKills");
    MarkNativeAsOptional("WhaleTracker_AreStatsLoaded");
    return APLRes_Success;
}

// Cookie handles
Handle g_hCookieWhitelist;
Handle g_hCookieFilterWhitelist;
Handle g_hCookieBlacklist;
Handle g_hCookieredlist;
Handle g_hChatFrontend;

// Per-client name color tokens (empty string means team color)
char g_NameColors[MAXPLAYERS + 1][32];

// Truthtext handles
Handle g_sEnabled = INVALID_HANDLE;
Handle g_sChatMode2 = INVALID_HANDLE;
ConVar g_hChatDebug = null;
ConVar g_hFiltersCaseSensitive = null;
ConVar g_hFiltersEnabled = null;
ConVar g_hBlacklistMinLen = null;
ConVar g_hFiltersChristmas = null;
ConVar g_hFiltersTeamChat = null;
ConVar g_hRedlistEnabled = null;

// Global arrays for word filtering
char g_FilterWords[MAX_FILTERS][MAX_WORD_LENGTH];
char g_ReplacementWords[MAX_FILTERS][MAX_WORD_LENGTH];
int g_FilterCount = 0;

// Global array for blacklisted words
char g_BlacklistWords[MAX_BLACKLIST][MAX_WORD_LENGTH];
int g_BlacklistCount = 0;
char g_BlacklistWords50[MAX_BLACKLIST][MAX_WORD_LENGTH];
int g_Blacklist50Count = 0;

// Global arrays for forced status
char g_ForcedStatusSteamIDs[MAX_FORCED_STATUS][32];
char g_ForcedStatusTypes[MAX_FORCED_STATUS][32]; // "whitelist", "blacklist", "redlist", or "filter_whitelist"
int g_ForcedStatusCount = 0;

// Global array for whitelisted/immunue commands
char g_AllowedCommands[MAX_COMMANDS][MAX_WORD_LENGTH];
int g_AllowedCommandsCount = 0;

// Web name color overrides (from filters.cfg -> webnames section)
// Web name color overrides (from filters.cfg -> webnames section)
StringMap g_WebNameColors = null;

// Connection event queue
ArrayList g_ConnectQueue = null;
Handle g_ConnectQueueTimer = null;
char g_sServerName[128];
ConVar g_hHostnameCvar = null;
StringMap g_PrenameIdRules = null;
StringMap g_PrenameOutputMap = null;
char g_PrenameDebugLogPath[PLATFORM_MAX_PATH];
bool g_PrenameDebugMigrate = false;
bool g_PrenameRulesLoaded = false;

enum struct ConnectEvent
{
    char name[MAX_NAME_LENGTH];
    bool connected;
}

char g_sHostIp[64];
char g_sPublicHostIp[64];
char g_sHostStamp[96];
ConVar g_hHostIpCvar = null;
ConVar g_hHostPortCvar = null;
int g_iHostPort = 27015;
bool g_bOutboxStampReady = false;
int g_iPendingSchemaQueries = 0;
int g_iLastOutboxCleanup = 0;

bool Filters_DebugEnabled()
{
    return g_hChatDebug != null && g_hChatDebug.BoolValue;
}

bool Filters_RedlistEnabled()
{
    return g_hRedlistEnabled != null && g_hRedlistEnabled.BoolValue;
}

void Filters_LogDebug(const char[] fmt, any ...)
{
    if (!Filters_DebugEnabled())
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogMessage("[Filters][Chat] %s", buffer);
}

static void Filters_ResetExternalStats(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_PlayerState[client].rapesGiven = 0;
    g_PlayerState[client].whaleKills = 0;
    g_PlayerState[client].hugsStatsLoaded = false;
    g_PlayerState[client].whaleStatsLoaded = false;

    g_AutoRedlistKills[client] = 0;
    g_AutoRedlistRapes[client] = 0;
    g_AutoRedlistGotKills[client] = false;
    g_AutoRedlistGotRapes[client] = false;
}

static bool Filters_TryGetRapesGiven(int client, int &value)
{
    if (GetFeatureStatus(FeatureType_Native, "Hugs_GetRapesGiven") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "Hugs_AreStatsLoaded") != FeatureStatus_Available)
    {
        return false;
    }

    if (!Hugs_AreStatsLoaded(client))
    {
        return false;
    }

    value = Hugs_GetRapesGiven(client);
    return true;
}

static bool Filters_TryGetWhaleKills(int client, int &value)
{
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetCumulativeKills") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "WhaleTracker_AreStatsLoaded") != FeatureStatus_Available)
    {
        return false;
    }

    if (!WhaleTracker_AreStatsLoaded(client))
    {
        return false;
    }

    value = WhaleTracker_GetCumulativeKills(client);
    return true;
}

static void Filters_UpdateExternalStats(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    int value = 0;
    if (Filters_TryGetRapesGiven(client, value))
    {
        g_PlayerState[client].rapesGiven = value;
        g_PlayerState[client].hugsStatsLoaded = true;
    }
    else
    {
        g_PlayerState[client].hugsStatsLoaded = false;
    }

    if (Filters_TryGetWhaleKills(client, value))
    {
        g_PlayerState[client].whaleKills = value;
        g_PlayerState[client].whaleStatsLoaded = true;
    }
    else
    {
        g_PlayerState[client].whaleStatsLoaded = false;
    }

}

static bool Filters_IsIgnoredClient(int client)
{
    char steamId[32];
    if (GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return StrEqual(steamId, FILTERS_IGNORED_STEAMID64, false);
    }

    return false;
}

static void RefreshHostAddress()
{
    if (g_hHostIpCvar == null)
    {
        g_hHostIpCvar = FindConVar("ip");
        if (g_hHostIpCvar == null)
        {
            g_hHostIpCvar = FindConVar("hostip");
        }
    }

    if (g_hHostIpCvar != null)
    {
        g_hHostIpCvar.GetString(g_sHostIp, sizeof(g_sHostIp));
    }
    else
    {
        g_sHostIp[0] = '\0';
    }

    if (!g_sHostIp[0])
    {
        strcopy(g_sHostIp, sizeof(g_sHostIp), "0.0.0.0");
    }

    if (g_hHostPortCvar == null)
    {
        g_hHostPortCvar = FindConVar("hostport");
    }
    g_iHostPort = (g_hHostPortCvar != null) ? g_hHostPortCvar.IntValue : 27015;

    RefreshPublicHostIp();

    Filters_LogDebug("Host identity refreshed: local=%s public=%s port=%d",
        g_sHostIp[0] ? g_sHostIp : "(unset)",
        g_sPublicHostIp[0] ? g_sPublicHostIp : "(unset)",
        g_iHostPort);
    Filters_UpdateHostStampString();
}

static void RefreshServerHostname()
{
    if (g_hHostnameCvar == null)
    {
        g_hHostnameCvar = FindConVar("hostname");
    }
    if (g_hHostnameCvar != null)
    {
        g_hHostnameCvar.GetString(g_sServerName, sizeof(g_sServerName));
    }
    else
    {
        g_sServerName[0] = '\0';
    }
}

static void RefreshPublicHostIp()
{
    strcopy(g_sPublicHostIp, sizeof(g_sPublicHostIp), "173.255.237.230");
}

static void Filters_GetPreferredHostIp(char[] buffer, int maxlen)
{
    if (!g_sPublicHostIp[0] && !g_sHostIp[0])
    {
        RefreshHostAddress();
    }

    if (g_sPublicHostIp[0])
    {
        strcopy(buffer, maxlen, g_sPublicHostIp);
    }
    else
    {
        strcopy(buffer, maxlen, g_sHostIp);
    }
}

static void Filters_GetLocalHostStamp(char[] ipOut, int ipLen, int &portOut)
{
    Filters_GetPreferredHostIp(ipOut, ipLen);
    portOut = g_iHostPort;
}

static bool Filters_IsLocalHostStamp(const char[] otherIp, int otherPort)
{
    if (!otherIp[0] || otherPort <= 0)
    {
        return false;
    }

    char localIp[64];
    Filters_GetPreferredHostIp(localIp, sizeof(localIp));
    if (!localIp[0])
    {
        return false;
    }

    return (StrEqual(localIp, otherIp, false) && otherPort == g_iHostPort);
}

static void Filters_UpdateHostStampString()
{
    char ip[64];
    int port;
    Filters_GetLocalHostStamp(ip, sizeof(ip), port);
    if (!ip[0])
    {
        strcopy(ip, sizeof(ip), "0.0.0.0");
    }
    Format(g_sHostStamp, sizeof(g_sHostStamp), "%s:%d", ip, port);
}

static void Filters_GetHostStamp(char[] buffer, int maxlen)
{
    if (!g_sHostStamp[0])
    {
        Filters_UpdateHostStampString();
    }
    strcopy(buffer, maxlen, g_sHostStamp);
}

public Plugin myinfo = 
{
    name = "filters",
    author = "Hombre",
    description = "Chat Management + Filtered/Blacklisted Words + Web Communication Frontend",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    if (g_WebNameColors == null)
    {
        g_WebNameColors = new StringMap();
    }

    if (g_ConnectQueue == null)
    {
        g_ConnectQueue = new ArrayList(sizeof(ConnectEvent));
    }
    if (g_PrenameIdRules == null)
    {
        g_PrenameIdRules = new StringMap();
    }
    if (g_PrenameOutputMap == null)
    {
        g_PrenameOutputMap = new StringMap();
    }
    BuildPath(Path_SM, g_PrenameDebugLogPath, sizeof(g_PrenameDebugLogPath), "logs/prename_migrate.log");

    LoadFilterConfig();

    // Truthtext Convars
    g_sEnabled = CreateConVar("nobroly", "1", "If 0, filter chat to one word");
    g_sChatMode2 = CreateConVar("filtermode", "0", "Enable/Disable the quarantined filter mode");
    g_hChatDebug = CreateConVar("filters_chat_debug", "0", "Enable verbose debug logging for chat relay");
    g_hChatFrontend = CreateConVar("filters_chat_frontend", "1", "Enable/Disable db functions");
    g_hFiltersEnabled = CreateConVar("filters", "0", "If 0, blacklist word matching is disabled.");
    g_hRedlistEnabled = CreateConVar("redlist", "1", "Enable/Disable redlist features.", _, true, 0.0, true, 1.0);
    g_hBlacklistMinLen = CreateConVar("filters_blacklist_minlen", "8", "Minimum message length to check blacklist words.");
    g_hFiltersChristmas = CreateConVar("filters_christmas", "0", "If 1, red chat is {axis} and blue chat is {green}.");
    g_hFiltersTeamChat = CreateConVar("teamchat", "0", "If 1, normal chat is sent to the sender's team only.");
    g_hFiltersCaseSensitive = CreateConVar(
        "filters_case_sensitive",
        "1",
        "If 1, chat filters are case-sensitive (exact casing must match)"
    );
    HookConVarChange(g_sChatMode2, Filters_OnFilterModeChanged);
    HookConVarChange(g_hRedlistEnabled, Filters_OnRedlistChanged);
    
    // Initialize cookies
    g_hCookieWhitelist = RegClientCookie("filter_whitelist", "Player is whitelisted from all filters", CookieAccess_Protected);
    g_hCookieFilterWhitelist = RegClientCookie("filter_filterwhitelist", "Player is whitelisted from word filters only", CookieAccess_Protected);
    g_hCookieBlacklist = RegClientCookie("filter_blacklist", "Player is blacklisted from sending messages", CookieAccess_Protected);
    g_hCookieredlist = RegClientCookie("filter_redlist", "Player cannot hear blacklisted clients", CookieAccess_Protected);
    
    // Register admin commands for managing player states
    RegAdminCmd("sm_whitelist", Command_Whitelist, ADMFLAG_CHAT, "sm_whitelist <player> - Whitelists a player from all filters");
    RegAdminCmd("sm_unwhitelist", Command_UnWhitelist, ADMFLAG_CHAT, "sm_unwhitelist <player> - Removes whitelist from a player");
    
    RegAdminCmd("sm_filterwhitelist", Command_FilterWhitelist, ADMFLAG_CHAT, "sm_filterwhitelist <player> - Whitelists a player from word filters only");
    RegAdminCmd("sm_unfilterwhitelist", Command_UnFilterWhitelist, ADMFLAG_CHAT, "sm_unfilterwhitelist <player> - Removes filter whitelist from a player");
    
    RegAdminCmd("sm_blacklist", Command_Blacklist, ADMFLAG_CHAT, "sm_blacklist <player> - Blacklists a player from sending messages");
    RegAdminCmd("sm_unblacklist", Command_UnBlacklist, ADMFLAG_CHAT, "sm_unblacklist <player> - Removes blacklist from a player");
    RegAdminCmd("sm_whitelists", Command_ListWhitelists, ADMFLAG_CHAT, "sm_whitelists - Lists whitelisted players");
    RegAdminCmd("sm_blacklists", Command_ListBlacklists, ADMFLAG_CHAT, "sm_blacklists - Lists blacklisted players");
    RegAdminCmd("sm_redlist", Command_redlist, ADMFLAG_CHAT, "sm_redlist <player> - redlist a player (can't hear blacklisted clients)");
    RegAdminCmd("sm_unredlist", Command_Unredlist, ADMFLAG_CHAT, "sm_unredlist <player> - Removes redlist from a player");
    RegAdminCmd("sm_redlists", Command_Listredlists, ADMFLAG_CHAT, "sm_redlists - Lists redlisted players");
    RegAdminCmd("sm_filtershelp", Command_FiltersHelp, ADMFLAG_CHAT, "sm_filtershelp - Shows filters convar help");
    RegConsoleCmd("sm_filters_debug", Command_FiltersDebug, "Show debug stats for filters");
    RegConsoleCmd("sm_colors", Command_Colors, "Show available chat colors");
    RegConsoleCmd("sm_colours", Command_Colors, "Show available chat colours");
    RegConsoleCmd("sm_prename", Command_Prename, "sm_prename <name_substring|steamid> <newname> (admins) or sm_prename <newname> (self)");
    RegConsoleCmd("sm_reset", Command_PrenameReset, "sm_reset <name_substring|steamid> (admins) or sm_reset (self)");
    RegAdminCmd("sm_migrate", Command_PrenameMigrate, ADMFLAG_SLAY, "sm_migrate - Migrates legacy name rules to SteamID rules for connected clients");

    // Web chat relay
    RegConsoleCmd("sm_websay", Command_WebSay, "Relay a web chat message to all players");

    RefreshHostAddress();
    Filters_SQLConnect();
    CreateTimer(2.0, Timer_PollOutbox, _, TIMER_REPEAT);

    // Restore existing clients' state after reloads
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }
        if (AreClientCookiesCached(i))
        {
            ProcessCookies(i);
        }
        else
        {
            g_PlayerState[i].isWhitelisted = false;
            g_PlayerState[i].isFilterWhitelisted = false;
            g_PlayerState[i].isBlacklisted = false;
            g_PlayerState[i].isredlisted = false;
            g_NameColors[i][0] = '\0';
        }

        Filters_ResetExternalStats(i);
        Filters_UpdateExternalStats(i);
    }

    Filters_UpdateVoiceOverrides();
}

public void OnConfigsExecuted()
{
    RefreshHostAddress();
    RefreshServerHostname();
}

public void OnLibraryAdded(const char[] name)
{
    if (!StrEqual(name, "hugs", false) && !StrEqual(name, "whaletracker", false))
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Filters_UpdateExternalStats(i);
        }
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (!StrEqual(name, "hugs", false) && !StrEqual(name, "whaletracker", false))
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            Filters_ResetExternalStats(i);
        }
    }
}

public void OnMapStart()
{
    char mapName[128];
    GetCurrentMap(mapName, sizeof(mapName));
    Filters_InsertSystemMessage(false, false, "{gold}[Server]{default}: Map changed to {cornflowerblue}%s", mapName);
}

// Database for chat log
Database g_hFiltersDb = null;
bool g_bDbReady = false;
char g_sDbConfig[32] = "default";

void Filters_SQLConnect()
{
    if (g_hFiltersDb != null)
    {
        delete g_hFiltersDb;
        g_hFiltersDb = null;
        g_bDbReady = false;
    }
    Filters_LogDebug("Connecting to database config '%s'", g_sDbConfig);
    Database.Connect(T_Filters_SQLConnect, g_sDbConfig);
}

public void T_Filters_SQLConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[Filters] DB connection failed: %s", error);
        return;
    }

    g_hFiltersDb = db;
    g_bDbReady = true;
    g_bOutboxStampReady = false;
    if (!g_hFiltersDb.SetCharset("utf8mb4"))
    {
        LogError("[Filters] Failed to set utf8mb4 charset");
    }

    static const char schemaQueries[][] =
    {
        "CREATE TABLE IF NOT EXISTS whaletracker_chat ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY,"
        ... "created_at INT NOT NULL,"
        ... "steamid VARCHAR(32) NULL,"
        ... "personaname VARCHAR(128) NULL,"
        ... "iphash VARCHAR(64) NULL,"
        ... "message TEXT NOT NULL,"
        ... "alert TINYINT(1) NOT NULL DEFAULT 1,"
        ... "INDEX(created_at)) DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS whaletracker_chat_outbox ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY,"
        ... "created_at INT NOT NULL,"
        ... "iphash VARCHAR(64) NOT NULL,"
        ... "display_name VARCHAR(128) DEFAULT '',"
        ... "message TEXT NOT NULL,"
        ... "host_ip VARCHAR(64) NOT NULL DEFAULT '',"
        ... "host_port INT NOT NULL DEFAULT 0,"
        ... "webchatonly TINYINT(1) NOT NULL DEFAULT 0,"
        ... "alert TINYINT(1) NOT NULL DEFAULT 1,"
        ... "server_ip VARCHAR(64) NULL,"
        ... "server_port INT NULL,"
        ... "delivered_to TEXT NULL,"
        ... "INDEX(created_at)) DEFAULT CHARSET=utf8mb4",
        "ALTER TABLE whaletracker_chat ADD COLUMN IF NOT EXISTS alert TINYINT(1) NOT NULL DEFAULT 1 AFTER message",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS host_ip VARCHAR(64) NOT NULL DEFAULT '' AFTER message",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS host_port INT NOT NULL DEFAULT 0 AFTER host_ip",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS webchatonly TINYINT(1) NOT NULL DEFAULT 0 AFTER host_port",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS alert TINYINT(1) NOT NULL DEFAULT 1 AFTER webchatonly",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS server_ip VARCHAR(64) NULL AFTER webchatonly",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS server_port INT NULL AFTER server_ip",
        "ALTER TABLE whaletracker_chat_outbox ADD COLUMN IF NOT EXISTS delivered_to TEXT NULL AFTER server_port",
        "CREATE TABLE IF NOT EXISTS prename_rules (pattern VARCHAR(64) PRIMARY KEY, newname VARCHAR(64) NOT NULL)",
        "CREATE TABLE IF NOT EXISTS filters_namecolors (steamid VARCHAR(32) PRIMARY KEY, color VARCHAR(32) NOT NULL DEFAULT '', updated_at INT NOT NULL DEFAULT 0)"
    };

    g_iPendingSchemaQueries = sizeof(schemaQueries);
    if (g_iPendingSchemaQueries <= 0)
    {
        g_bOutboxStampReady = true;
        g_PrenameRulesLoaded = false;
        Filters_PrenameLoadRules();
    }
    else
    {
        for (int i = 0; i < sizeof(schemaQueries); i++)
        {
            g_hFiltersDb.Query(Filters_SchemaQueryCallback, schemaQueries[i]);
        }
    }

    Filters_LogDebug("Database connection established");
}

public void Filters_SimpleSqlCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters] SQL error: %s", error);
    }
}

public void Filters_SchemaQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters] Schema query failed: %s", error);
    }

    if (g_iPendingSchemaQueries > 0)
    {
        g_iPendingSchemaQueries--;
    }

    if (g_iPendingSchemaQueries <= 0)
    {
        g_bOutboxStampReady = true;
        Filters_LogDebug("Schema ready; host stamp support enabled");
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                LoadNameColorFromDb(i);
            }
        }
        if (!g_PrenameRulesLoaded)
        {
            g_PrenameRulesLoaded = true;
            Filters_PrenameLoadRules();
        }
    }
}

// Poll DB outbox and relay to all chat, then delete processed rows
public Action Timer_PollOutbox(Handle timer, any data)
{
    if (GetConVarInt(g_hChatFrontend) < 1)
	return Plugin_Continue;

    if (!g_bDbReady || !g_bOutboxStampReady)
    {
        Filters_LogDebug("DB/schema not ready; skipping outbox poll");
        return Plugin_Continue;
    }
    char hostStamp[96];
    Filters_GetHostStamp(hostStamp, sizeof(hostStamp));
    if (!hostStamp[0])
    {
        Filters_LogDebug("Host stamp unavailable; skipping outbox poll");
        return Plugin_Continue;
    }
    char needle[128];
    Format(needle, sizeof(needle), "|%s|", hostStamp);
    char escapedNeedle[192];
    SQL_EscapeString(g_hFiltersDb, needle, escapedNeedle, sizeof(escapedNeedle));
    char query[512];
    Format(query, sizeof(query), "SELECT id, iphash, display_name, message, host_ip, host_port, webchatonly, alert, server_ip, server_port, delivered_to FROM whaletracker_chat_outbox WHERE delivered_to IS NULL OR LOCATE('%s', delivered_to) = 0 ORDER BY id ASC LIMIT 20", escapedNeedle);
    g_hFiltersDb.Query(Filters_OutboxQueryCallback, query);
    Filters_LogDebug("Polling chat outbox for pending messages");
    return Plugin_Continue;
}

public void Filters_OutboxQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0' || results == null)
    {
        if (error[0] != '\0') LogError("[Filters] Outbox query failed: %s", error);
        return;
    }
    char localStamp[96];
    char hostNeedle[128];
    Filters_GetHostStamp(localStamp, sizeof(localStamp));
    hostNeedle[0] = '\0';
    if (localStamp[0])
    {
        Format(hostNeedle, sizeof(hostNeedle), "|%s|", localStamp);
    }
    while (results.FetchRow())
    {
        int id = results.FetchInt(0);
        char hash[64];
        results.FetchString(1, hash, sizeof(hash));
        char display[128];
        results.FetchString(2, display, sizeof(display));
        char msg[512];
        results.FetchString(3, msg, sizeof(msg));
        bool isPlayerRelay = (strncmp(hash, "player:", 7) == 0);
        char label[256];
        char colorTag[32] = "{gold}";
        if (!isPlayerRelay)
        {
            if (display[0])
            {
                Filters_GetWebNameColor(display, colorTag, sizeof(colorTag));
                Format(label, sizeof(label), "%s[%s]{default}", colorTag, display);
            }
            else if (StrEqual(hash, "system"))
            {
                Format(label, sizeof(label), "{gold}[Server]{default}");
            }
            else
            {
                Filters_GetWebNameColor(hash, colorTag, sizeof(colorTag));
                Format(label, sizeof(label), "%s[Web Player # %s]{default}", colorTag, hash);
            }
        }
        char sourceIp[64];
        results.FetchString(4, sourceIp, sizeof(sourceIp));
        int sourcePort = 0;
        int fieldCount = results.FieldCount;
        if (fieldCount > 5)
        {
            sourcePort = results.FetchInt(5);
        }
        bool webchatOnly = false;
        if (fieldCount > 6)
        {
            webchatOnly = results.FetchInt(6) != 0;
        }
        // alert flag and server_ip/server_port are reserved for future use
        if (fieldCount > 10 && hostNeedle[0])
        {
            char deliveredTo[256];
            results.FetchString(10, deliveredTo, sizeof(deliveredTo));
            if (StrContains(deliveredTo, hostNeedle, false) != -1)
            {
                Filters_LogDebug("Skipping chat id %d; already delivered per schema", id);
                Filters_MarkOutboxDelivered(id);
                continue;
            }
        }
        bool fromLocalServer = Filters_IsLocalHostStamp(sourceIp, sourcePort);

        bool suppressChatBroadcast = webchatOnly || StrEqual(hash, "system") || fromLocalServer;
        if (isPlayerRelay)
        {
            if (!suppressChatBroadcast)
            {
                Filters_PrintToChatAll(msg);
            }
            if (!fromLocalServer && !webchatOnly)
            {
                PrintToServer("%s", msg);
            }
        }
        else
        {
            char out[640];
            Format(out, sizeof(out), "%s %s", label, msg);
            if (!suppressChatBroadcast)
            {
                Filters_PrintToChatAll(out);
            }
            if (!fromLocalServer && !webchatOnly)
            {
                PrintToServer("%s", out);
            }
        }
        if (fromLocalServer)
        {
            Filters_LogDebug("Suppressed relay of local chat id %d (%s:%d)", id, sourceIp, sourcePort);
        }
        else if (webchatOnly)
        {
            Filters_LogDebug("Suppressed relay of webchat-only chat id %d", id);
        }
        Filters_LogDebug("Relayed chat id %d hash %s name %s msg %s (from %s:%d)", id, hash, display, msg, sourceIp, sourcePort);
        Filters_MarkOutboxDelivered(id);
    }
    Filters_MaybeCleanupOutbox();
}

static void Filters_MarkOutboxDelivered(int rowId)
{
    if (rowId <= 0 || !g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }
    char stamp[96];
    Filters_GetHostStamp(stamp, sizeof(stamp));
    if (!stamp[0])
    {
        return;
    }
    char escapedStamp[192];
    SQL_EscapeString(g_hFiltersDb, stamp, escapedStamp, sizeof(escapedStamp));
    char query[512];
    Format(query, sizeof(query), "UPDATE whaletracker_chat_outbox SET delivered_to = CASE WHEN delivered_to IS NULL OR delivered_to = '' THEN '|%s|' WHEN LOCATE('|%s|', delivered_to) = 0 THEN CONCAT(delivered_to, '|%s|') ELSE delivered_to END WHERE id = %d", escapedStamp, escapedStamp, escapedStamp, rowId);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Filters_MaybeCleanupOutbox()
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }
    int now = GetTime();
    if (g_iLastOutboxCleanup != 0 && now - g_iLastOutboxCleanup < FILTERS_OUTBOX_CLEANUP_INTERVAL)
    {
        return;
    }
    g_iLastOutboxCleanup = now;
    int cutoff = now - FILTERS_OUTBOX_RETENTION_SECONDS;
    if (cutoff <= 0)
    {
        return;
    }
    char query[128];
    Format(query, sizeof(query),
        "DELETE FROM whaletracker_chat_outbox WHERE created_at < %d",
        cutoff);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Filters_QueueOutboxMessage(int timestamp, const char[] iphash, const char[] displayName, const char[] message, bool webchatOnly, bool alertFlag)
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    char escapedMsg[512];
    SQL_EscapeString(g_hFiltersDb, message, escapedMsg, sizeof(escapedMsg));
    char escapedHash[128];
    SQL_EscapeString(g_hFiltersDb, iphash, escapedHash, sizeof(escapedHash));
    char escapedDisplay[256];
    SQL_EscapeString(g_hFiltersDb, displayName, escapedDisplay, sizeof(escapedDisplay));
    int webFlag = webchatOnly ? 1 : 0;
    int alert = alertFlag ? 1 : 0;

    char query[1024];
    if (g_bOutboxStampReady)
    {
        char localIp[64];
        int localPort;
        Filters_GetLocalHostStamp(localIp, sizeof(localIp), localPort);
        char escapedIp[128];
        SQL_EscapeString(g_hFiltersDb, localIp, escapedIp, sizeof(escapedIp));
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat_outbox (created_at, iphash, display_name, message, host_ip, host_port, webchatonly, alert) VALUES (%d, '%s', '%s', '%s', '%s', %d, %d, %d)",
            timestamp,
            escapedHash,
            escapedDisplay,
            escapedMsg,
            escapedIp,
            localPort,
            webFlag,
            alert);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat_outbox (created_at, iphash, display_name, message, webchatonly, alert) VALUES (%d, '%s', '%s', '%s', %d, %d)",
            timestamp,
            escapedHash,
            escapedDisplay,
            escapedMsg,
            webFlag,
            alert);
    }

    g_hFiltersDb.Query(Filters_OutboxInsertCallback, query);
}

static void Filters_RelayChatToServers(int client, const char[] message)
{
    if (!g_bDbReady || g_hFiltersDb == null || !g_bOutboxStampReady)
    {
        return;
    }

    char hash[64];
    if (client > 0 && IsClientInGame(client))
    {
        char steamId[32];
        if (GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
        {
            Format(hash, sizeof(hash), "player:%s", steamId);
        }
        else
        {
            Format(hash, sizeof(hash), "player:uid%d", GetClientUserId(client));
        }
    }
    else
    {
        strcopy(hash, sizeof(hash), "player:unknown");
    }

    char displayName[128];
    if (client > 0 && IsClientInGame(client))
    {
        GetClientName(client, displayName, sizeof(displayName));
    }
    else
    {
        strcopy(displayName, sizeof(displayName), "");
    }

    Filters_QueueOutboxMessage(GetTime(), hash, displayName, message, false, true);
}

void Filters_LogChatMessage(int client, const char[] message)
{
    if (GetConVarInt(g_hChatFrontend) < 1)
        return;
    if (Filters_IsIgnoredClient(client))
        return;
    if (!g_bDbReady)
    {
        Filters_LogDebug("DB not ready; skipping chat log for client %d", client);
        return;
    }


    char steamId[32];
    bool hasSteam = false;
    steamId[0] = '\0';
    if (client > 0 && IsClientInGame(client) && GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        hasSteam = true;
    }
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    char escapedName[MAX_NAME_LENGTH * 2];
    char escapedMsg[512];
    SQL_EscapeString(g_hFiltersDb, name, escapedName, sizeof(escapedName));
    SQL_EscapeString(g_hFiltersDb, message, escapedMsg, sizeof(escapedMsg));
    char query[1024];
    if (hasSteam)
    {
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message, alert) VALUES (%d, '%s', '%s', NULL, '%s', 1)",
            GetTime(), steamId, escapedName, escapedMsg);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message, alert) VALUES (%d, NULL, '%s', NULL, '%s', 1)",
            GetTime(), escapedName, escapedMsg);
    }
    g_hFiltersDb.Query(Filters_InsertChatCallback, query);
    Filters_LogDebug("Logged chat from %s: %s", hasSteam ? steamId : "unknown", message);
    Filters_RelayChatToServers(client, message);
}

public void Filters_InsertChatCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters] Failed to log chat: %s", error);
        return;
    }
    Filters_LogDebug("Chat insert succeeded");
}

void Filters_InsertSystemMessage(bool webchatOnly, bool alertFlag, const char[] format, any ...)
{
    if (!g_bDbReady)
    {
        Filters_LogDebug("DB not ready; skipping system message");
        return;
    }

    char message[256];
    VFormat(message, sizeof(message), format, 4);

    int timestamp = GetTime();
    char escapedMsg[512];
    SQL_EscapeString(g_hFiltersDb, message, escapedMsg, sizeof(escapedMsg));
    char localIp[64];
    int localPort;
    Filters_GetLocalHostStamp(localIp, sizeof(localIp), localPort);
    char escapedIp[128];
    SQL_EscapeString(g_hFiltersDb, localIp, escapedIp, sizeof(escapedIp));

    // Broadcast immediately to the local server unless webchat-only.
    if (!webchatOnly)
    {
        Filters_PrintToChatAll(message);
        PrintToServer("%s", message);
        Filters_LogDebug("Local system message broadcast: %s", message);
    }
    else
    {
        Filters_LogDebug("Webchat-only system message queued without local broadcast: %s", message);
    }

    char query[1024];
    int alert = alertFlag ? 1 : 0;
    Format(query, sizeof(query),
        "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message, alert) VALUES (%d, NULL, '[SERVER]', 'system', '%s', %d)",
        timestamp,
        escapedMsg,
        alert);
    g_hFiltersDb.Query(Filters_InsertChatCallback, query);

    Filters_QueueOutboxMessage(timestamp, "system", "", message, webchatOnly, alertFlag);
    Filters_LogDebug("Queued system message: %s", message);
}

void Filters_AnnouncePlayerEvent(int client, bool connected)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    ConnectEvent event;
    GetClientName(client, event.name, sizeof(event.name));
    event.connected = connected;

    g_ConnectQueue.PushArray(event);

    if (g_ConnectQueueTimer == null)
    {
        g_ConnectQueueTimer = CreateTimer(3.0, Timer_ProcessConnectQueue);
    }
}

public Action Timer_ProcessConnectQueue(Handle timer)
{
    g_ConnectQueueTimer = null;

    int count = g_ConnectQueue.Length;
    if (count > 5)
    {
        Filters_LogDebug("Dropped %d connection events due to spam/map change", count);
        g_ConnectQueue.Clear();
        return Plugin_Stop;
    }

    for (int i = 0; i < count; i++)
    {
        ConnectEvent event;
        g_ConnectQueue.GetArray(i, event);

        if (event.connected)
        {
            Filters_AnnouncePlayerJoin(event.name);
        }
        else
        {
            Filters_AnnouncePlayerLeave(event.name);
        }
    }

    g_ConnectQueue.Clear();
    return Plugin_Stop;
}

public void Filters_OutboxInsertCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters] Failed to insert chat outbox entry: %s", error);
    }
}

enum struct ChatContext
{
    bool pluginEnabled;
    bool cordMode;
    bool isBlacklisted;
    bool isWhitelisted;
    bool isFilterWhitelisted;
    bool hasBlacklistedTerm;
    bool isGagged;
}

enum FilterStatusList
{
    FilterStatus_Whitelist = 0,
    FilterStatus_Blacklist,
    FilterStatus_redlist
};

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!client)
        return Plugin_Continue;

    char dead[64];
    BuildDeathPrefix(client, dead, sizeof(dead));

    if (HandleNameColorCommand(client, sArgs))
    {
        return Plugin_Stop;
    }

    if (HandleFiltersHelpCommand(client, sArgs))
    {
        return Plugin_Stop;
    }

    if (HandleListStatusCommand(client, sArgs))
    {
        return Plugin_Stop;
    }

    if (CheckCommands(sArgs))
    {
        PrintToServer("%s", sArgs);
        return Plugin_Continue;
    }

    if (TryHandleTeamChat(client, command, sArgs, dead))
    {
        return Plugin_Stop;
    }

    ChatContext context;
    BuildChatContext(client, sArgs, context);

    if (context.hasBlacklistedTerm || context.isBlacklisted)
    {
        LogBlacklistedMessage(client, sArgs, context.hasBlacklistedTerm, context.isBlacklisted);
    }

    char nameColorTag[40];
    BuildNameColorTag(client, nameColorTag, sizeof(nameColorTag));

    char messageColorTag[16];
    BuildMessageColorTag(client, messageColorTag, sizeof(messageColorTag));

    char output[256];
    Format(output, sizeof(output), "%s%s%s%N%s : %s", messageColorTag, dead, nameColorTag, client, messageColorTag, sArgs);

    ApplyFiltersIfNeeded(output, sizeof(output), context);

    if (HandleCordModeBlacklistedChat(client, output, context))
    {
        return Plugin_Stop;
    }

    if (HandleRestrictedMessage(client, output, context))
    {
        return Plugin_Stop;
    }

    if (HandleEnabledChat(client, output, context))
    {
        return Plugin_Stop;
    }

    SendFallbackMessage(client);
    return Plugin_Stop;
}

void BuildChatContext(int client, const char[] sArgs, ChatContext context)
{
    context.pluginEnabled = GetConVarInt(g_sEnabled) != 0;
    context.cordMode = GetConVarInt(g_sChatMode2) != 0;
    context.isBlacklisted = g_PlayerState[client].isBlacklisted;
    context.isWhitelisted = g_PlayerState[client].isWhitelisted;
    context.isFilterWhitelisted = g_PlayerState[client].isFilterWhitelisted;
    context.hasBlacklistedTerm = CheckBlacklistedTerms(sArgs);
    context.isGagged = BaseComm_IsClientGagged(client);
}

static void LogBlacklistedMessage(int client, const char[] message, bool hasBlacklistedTerm, bool isBlacklistedClient)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
    {
        strcopy(steamId, sizeof(steamId), "unknown");
    }

    LogToFileEx("addons/sourcemod/logs/filters_blacklist.log",
        "name=\"%s\" steamid=\"%s\" term=%d blacklisted=%d msg=\"%s\"",
        name, steamId, hasBlacklistedTerm ? 1 : 0, isBlacklistedClient ? 1 : 0, message);
}

void BuildDeathPrefix(int client, char[] deadPrefix, int length)
{
    if (!IsPlayerAlive(client))
    {
        Format(deadPrefix, length, "*負け犬* ");
        return;
    }

    deadPrefix[0] = '\0';
}

bool HandleNameColorCommand(int client, const char[] sArgs)
{
    if (!sArgs[0])
    {
        return false;
    }

    char buffer[256];
    strcopy(buffer, sizeof(buffer), sArgs);
    TrimString(buffer);

    if (!buffer[0])
    {
        return false;
    }

    char commandToken[16];
    int nextIndex = BreakString(buffer, commandToken, sizeof(commandToken));

    if (!StrEqual(commandToken, "!name", false) && !StrEqual(commandToken, "/name", false) && !StrEqual(commandToken, "!color", false) && !StrEqual(commandToken, "/color", false))
    {
        return false;
    }

    if (nextIndex == -1 || !buffer[nextIndex])
    {
        if (g_NameColors[client][0] != '\0')
        {
            CPrintToChat(client, "{default}[Filters] Your name color is currently {%s}%s{default}. Use !name <color> or !name default.", g_NameColors[client], g_NameColors[client]);
        }
        else
        {
            CPrintToChat(client, "{default}[Filters] Your name color uses the {teamcolor}team color{default}. Use !name <color> to change it.");
        }
        return true;
    }

    char colorName[32];
    strcopy(colorName, sizeof(colorName), buffer[nextIndex]);
    TrimString(colorName);

    if (!colorName[0])
    {
        if (g_NameColors[client][0] != '\0')
        {
            CPrintToChat(client, "{default}[Filters] Your name color is currently {%s}%s{default}. Use !name <color> or !name default.", g_NameColors[client], g_NameColors[client]);
        }
        else
        {
            CPrintToChat(client, "{default}[Filters] Your name color uses the {teamcolor}team color{default}. Use !name <color> to change it.");
        }
        return true;
    }

    ToLowercase(colorName);

    if (StrEqual(colorName, "default", false) || StrEqual(colorName, "team", false) || StrEqual(colorName, "teamcolor", false))
    {
        if (!g_NameColors[client][0])
        {
            CPrintToChat(client, "{default}[Filters] Your name color already uses the {teamcolor}team color{default}.");
            return true;
        }

        g_NameColors[client][0] = '\0';
        SaveNameColorToDb(client, "");
        CPrintToChat(client, "{default}[Filters] Your name color has been reset to the {teamcolor}team color{default}.");
        return true;
    }

    if (!CColorExists(colorName))
    {
        CPrintToChat(client, "{default}[Filters] Unknown color \"%s\". Example: !name deeppink", colorName);
        return true;
    }

    if (StrEqual(g_NameColors[client], colorName, false))
    {
        CPrintToChat(client, "{default}[Filters] Your name color is already {%s}%s{default}.", g_NameColors[client], g_NameColors[client]);
        return true;
    }

    strcopy(g_NameColors[client], sizeof(g_NameColors[]), colorName);
    SaveNameColorToDb(client, colorName);

    CPrintToChat(client, "{default}[Filters] Your name color is now {%s}%s{default}.", colorName, colorName);
    return true;
}

bool Filters_CanUseListCommand(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    return g_PlayerState[client].isWhitelisted;
}

bool Filters_CanUseHelpCommand(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    if (!g_PlayerState[client].isWhitelisted)
    {
        return false;
    }

    return CheckCommandAccess(client, "sm_filtershelp", ADMFLAG_CHAT, true);
}

void Filters_PrintHelp(int client)
{
    CPrintToChat(client, "{default}[Filters] nobroly - If 0, filter chat to one word.");
    CPrintToChat(client, "{default}[Filters] filtermode - Enable/Disable the quarantined filter mode.");
    CPrintToChat(client, "{default}[Filters] filters_chat_debug - Enable verbose debug logging for chat relay.");
    CPrintToChat(client, "{default}[Filters] filters_chat_frontend - Enable/Disable db functions.");
    CPrintToChat(client, "{default}[Filters] filters_filters - If 0, blacklist word matching is disabled.");
    CPrintToChat(client, "{default}[Filters] filters_blacklist_minlen - Minimum message length to check blacklist words.");
    CPrintToChat(client, "{default}[Filters] filters_christmas - If 1, red chat is {axis} and blue chat is {green}.");
    CPrintToChat(client, "{default}[Filters] teamchat - If 1, normal chat is sent to the sender's team only.");
    CPrintToChat(client, "{default}[Filters] filters_case_sensitive - If 1, chat filters are case-sensitive.");
}

bool HandleFiltersHelpCommand(int client, const char[] sArgs)
{
    if (!sArgs[0])
    {
        return false;
    }

    char buffer[256];
    strcopy(buffer, sizeof(buffer), sArgs);
    TrimString(buffer);

    if (!buffer[0] || buffer[0] != '/')
    {
        return false;
    }

    char commandToken[32];
    BreakString(buffer, commandToken, sizeof(commandToken));

    if (!StrEqual(commandToken, "/filtershelp", false))
    {
        return false;
    }

    if (!Filters_CanUseHelpCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return true;
    }

    Filters_PrintHelp(client);
    return true;
}

void Filters_PrintStatusList(int client, FilterStatusList status)
{
    char label[16];
    switch (status)
    {
        case FilterStatus_Whitelist: strcopy(label, sizeof(label), "Whitelisted");
        case FilterStatus_Blacklist: strcopy(label, sizeof(label), "Blacklisted");
        case FilterStatus_redlist: strcopy(label, sizeof(label), "redlisted");
        default: strcopy(label, sizeof(label), "Players");
    }

    char header[96];
    Format(header, sizeof(header), "{default}[Filters] %s: ", label);
    int headerLen = strlen(header);

    char line[256];
    strcopy(line, sizeof(line), header);
    int lineLen = headerLen;
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        if (status == FilterStatus_Whitelist && !g_PlayerState[i].isWhitelisted)
        {
            continue;
        }
        if (status == FilterStatus_Blacklist && !g_PlayerState[i].isBlacklisted)
        {
            continue;
        }
        if (status == FilterStatus_redlist && !g_PlayerState[i].isredlisted)
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        int nameLen = strlen(name);
        int extraLen = nameLen + (count > 0 && lineLen > headerLen ? 2 : 0);

        if (lineLen + extraLen >= sizeof(line) - 1)
        {
            CPrintToChat(client, "%s", line);
            strcopy(line, sizeof(line), header);
            lineLen = headerLen;
        }

        char next[256];
        if (lineLen == headerLen)
        {
            Format(next, sizeof(next), "%s%s", line, name);
        }
        else
        {
            Format(next, sizeof(next), "%s, %s", line, name);
        }
        strcopy(line, sizeof(line), next);
        lineLen = strlen(line);
        count++;
    }

    if (count == 0)
    {
        CPrintToChat(client, "{default}[Filters] %s: none", label);
        return;
    }

    CPrintToChat(client, "%s", line);
}

bool HandleListStatusCommand(int client, const char[] sArgs)
{
    if (!sArgs[0])
    {
        return false;
    }

    char buffer[256];
    strcopy(buffer, sizeof(buffer), sArgs);
    TrimString(buffer);

    if (!buffer[0] || buffer[0] != '/')
    {
        return false;
    }

    char commandToken[32];
    BreakString(buffer, commandToken, sizeof(commandToken));

    bool listWhitelist = StrEqual(commandToken, "/whitelists", false);
    bool listBlacklist = StrEqual(commandToken, "/blacklists", false);
    bool listredlist = StrEqual(commandToken, "/redlists", false);

    if (!listWhitelist && !listBlacklist && !listredlist)
    {
        return false;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return true;
    }

    if (listWhitelist)
    {
        Filters_PrintStatusList(client, FilterStatus_Whitelist);
    }
    else if (listBlacklist)
    {
        Filters_PrintStatusList(client, FilterStatus_Blacklist);
    }
    else
    {
        Filters_PrintStatusList(client, FilterStatus_redlist);
    }
    return true;
}

bool TryHandleTeamChat(int client, const char[] command, const char[] sArgs, const char[] deadPrefix)
{
    if (!StrEqual(command, "say_team"))
    {
        return false;
    }

    char tag[16];
    BuildTeamTag(GetClientTeam(client), tag, sizeof(tag));

    char colorTag[40];
    BuildNameColorTag(client, colorTag, sizeof(colorTag));

    char messageColorTag[16];
    BuildMessageColorTag(client, messageColorTag, sizeof(messageColorTag));

    char output[256];
    Format(output, sizeof(output), "%s%s%s %s%N%s : %s", messageColorTag, deadPrefix, tag, colorTag, client, messageColorTag, sArgs);
    bool cordMode = GetConVarInt(g_sChatMode2) != 0;
    if (cordMode)
    {
        if (g_PlayerState[client].isBlacklisted)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (IsClientInGame(i) && g_PlayerState[i].isBlacklisted && Filters_ShouldReceiveChat(i, client))
                {
                    Filters_SendChatToReceiver(i, client, output);
                }
            }

            SendToWhitelistedAdminsBlacklisted(client, output, "fm1:");
            PrintToServer("x: %s", output);
            return true;
        }

        int senderTeam = GetClientTeam(client);
        char prefixed[256];
        bool prefixedReady = false;

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i))
            {
                continue;
            }
            if (!Filters_ShouldReceiveChat(i, client))
            {
                continue;
            }

            bool isWhitelisted = g_PlayerState[i].isWhitelisted;
            bool isBlacklisted = g_PlayerState[i].isBlacklisted;
            if (GetClientTeam(i) == senderTeam)
            {
                if (!isBlacklisted || isWhitelisted)
                {
                    Filters_SendChatToReceiver(i, client, output);
                }
            }
            else if (isWhitelisted)
            {
                if (!prefixedReady)
                {
                    Format(prefixed, sizeof(prefixed), "t: %s", output);
                    prefixedReady = true;
                }
                Filters_SendChatToReceiver(i, client, prefixed);
            }
        }

        PrintToServer("%s", output);
        return true;
    }

    if (g_PlayerState[client].isBlacklisted)
    {
        int senderTeam = GetClientTeam(client);
        char prefixed[256];
        bool prefixedReady = false;

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || !Filters_ShouldReceiveChat(i, client))
            {
                continue;
            }

            if (GetClientTeam(i) == senderTeam)
            {
                Filters_SendChatToReceiver(i, client, output);
            }
            else if (g_PlayerState[i].isWhitelisted)
            {
                if (!prefixedReady)
                {
                    Format(prefixed, sizeof(prefixed), "t: %s", output);
                    prefixedReady = true;
                }
                Filters_SendChatToReceiver(i, client, prefixed);
            }
        }
    }
    else
    {
        CPrintToChatTeam(GetClientTeam(client), client, output);
    }
    PrintToServer("%s", output);
    return true;
}

void BuildTeamTag(int team, char[] tag, int length)
{
    switch (team)
    {
        case 3: strcopy(tag, length, "(輝夜)");
        case 2: strcopy(tag, length, "(妹紅)");
        default: strcopy(tag, length, "(永琳)");
    }
}

void ToLowercase(char[] text)
{
    for (int i = 0; text[i] != '\0'; i++)
    {
        text[i] = CharToLower(text[i]);
    }
}

void BuildNameColorTag(int client, char[] colorTag, int length)
{
    if (g_NameColors[client][0] != '\0')
    {
        Format(colorTag, length, "{%s}", g_NameColors[client]);
    }
    else
    {
        strcopy(colorTag, length, "{teamcolor}");
    }
}

void BuildMessageColorTag(int client, char[] colorTag, int length)
{
    if (g_hFiltersChristmas != null && g_hFiltersChristmas.BoolValue)
    {
        int team = GetClientTeam(client);
        if (team == 3)
        {
            strcopy(colorTag, length, "{lightgreen}");
            return;
        }
        if (team == 2)
        {
            strcopy(colorTag, length, "{tomato}");
            return;
        }
    }

    strcopy(colorTag, length, "{default}");
}

static bool Filters_ShouldReceiveChat(int receiver, int sender)
{
    if (receiver <= 0 || !IsClientInGame(receiver))
    {
        return false;
    }

    if (!Filters_RedlistEnabled())
    {
        return true;
    }

    if (!g_PlayerState[receiver].isredlisted)
    {
        return true;
    }

    return (sender > 0 && sender <= MaxClients && g_PlayerState[sender].isredlisted);
}

static void Filters_PrintToChatAll(const char[] message)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Filters_ShouldReceiveChat(i, 0))
        {
            continue;
        }
        CPrintToChat(i, "%s", message);
    }
}

static void Filters_SendChatToReceiver(int receiver, int sender, const char[] message)
{
    if (receiver <= 0 || !IsClientInGame(receiver))
    {
        return;
    }

    if (Filters_RedlistEnabled()
        && sender > 0
        && sender <= MaxClients
        && g_PlayerState[sender].isredlisted
        && !g_PlayerState[receiver].isredlisted)
    {
        if (g_PlayerState[receiver].isWhitelisted)
        {
            CPrintToChatEx(receiver, sender, "{axis}[Fake] %s", message);
        }
        return;
    }

    CPrintToChatEx(receiver, sender, "%s", message);
}

static void Filters_PrintToChatAllEx(int sender, const char[] message)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Filters_ShouldReceiveChat(i, sender))
        {
            continue;
        }
        Filters_SendChatToReceiver(i, sender, message);
    }
}

void Filters_UpdateVoiceOverrides()
{
    bool cordMode = GetConVarInt(g_sChatMode2) != 0;
    bool redlistEnabled = Filters_RedlistEnabled();
    for (int sender = 1; sender <= MaxClients; sender++)
    {
        if (!IsClientInGame(sender))
        {
            continue;
        }

        bool senderBlacklisted = g_PlayerState[sender].isBlacklisted;
        for (int receiver = 1; receiver <= MaxClients; receiver++)
        {
            if (receiver == sender || !IsClientInGame(receiver))
            {
                continue;
            }

            bool shouldBlock = false;
            if (redlistEnabled && g_PlayerState[receiver].isredlisted)
            {
                shouldBlock = !g_PlayerState[sender].isredlisted;
            }
            else if (cordMode)
            {
                bool receiverBlacklisted = g_PlayerState[receiver].isBlacklisted;
                bool receiverWhitelisted = g_PlayerState[receiver].isWhitelisted;
                shouldBlock = receiverBlacklisted
                    ? !senderBlacklisted
                    : (senderBlacklisted && !receiverBlacklisted && !receiverWhitelisted);
            }

            if (shouldBlock)
            {
                if (!g_VoiceBlocked[receiver][sender])
                {
                    SetListenOverride(receiver, sender, Listen_No);
                    g_VoiceBlocked[receiver][sender] = true;
                }
            }
            else if (g_VoiceBlocked[receiver][sender])
            {
                SetListenOverride(receiver, sender, Listen_Default);
                g_VoiceBlocked[receiver][sender] = false;
            }
        }
    }
}

void ApplyFiltersIfNeeded(char[] message, int maxlen, const ChatContext context)
{
    if (context.isFilterWhitelisted)
    {
        return;
    }

    FilterString(message, maxlen);
}

bool HandleCordModeBlacklistedChat(int client, const char[] message, const ChatContext context)
{
    if (!context.isBlacklisted || !context.cordMode)
    {
        return false;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_PlayerState[i].isBlacklisted && Filters_ShouldReceiveChat(i, client))
        {
            Filters_SendChatToReceiver(i, client, message);
        }
    }

    SendToWhitelistedAdminsBlacklisted(client, message, "fm1:");
    PrintToServer("x: %s", message);
    return true;
}

bool HandleRestrictedMessage(int client, const char[] message, const ChatContext context)
{
    if (((context.hasBlacklistedTerm && !context.isWhitelisted) && !context.cordMode) || context.isGagged)
    {
        CPrintToChatEx(client, client, "%s", message);
        PrintToServer("x: %s", message);
        SendToWhitelistedAdmins(client, message, "x:");
        return true;
    }

    return false;
}

bool HandleEnabledChat(int client, const char[] message, const ChatContext context)
{
    if (!context.pluginEnabled)
    {
        return false;
    }

    bool teamChatOnly = g_hFiltersTeamChat != null && g_hFiltersTeamChat.BoolValue;

    if (!context.cordMode)
    {
        if (context.isBlacklisted)
        {
            int senderTeam = GetClientTeam(client);
            char prefixed[256];
            bool prefixedReady = false;
            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsClientInGame(i) || !Filters_ShouldReceiveChat(i, client))
                {
                    continue;
                }

                if (!teamChatOnly)
                {
                    Filters_SendChatToReceiver(i, client, message);
                    continue;
                }

                if (GetClientTeam(i) == senderTeam)
                {
                    Filters_SendChatToReceiver(i, client, message);
                }
                else if (g_PlayerState[i].isWhitelisted)
                {
                    if (!prefixedReady)
                    {
                        Format(prefixed, sizeof(prefixed), "t: %s", message);
                        prefixedReady = true;
                    }
                    Filters_SendChatToReceiver(i, client, prefixed);
                }
            }
        }
        else if (teamChatOnly)
        {
            CPrintToChatTeam(GetClientTeam(client), client, message);
        }
        else
        {
            Filters_PrintToChatAllEx(client, message);
        }
    }
    else
    {
        /*int randomChance = GetRandomInt(1, 20);
        if (randomChance == 1)
        {
            if (teamChatOnly)
            {
                CPrintToChatTeam(GetClientTeam(client), message);
            }
            else
            {
                CPrintToChatAllEx(client, "%s", message);
            }
        }*/
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i))
            {
                continue;
            }
            if (!Filters_ShouldReceiveChat(i, client))
            {
                continue;
            }
            if (!g_PlayerState[i].isBlacklisted
                && (!teamChatOnly || GetClientTeam(i) == GetClientTeam(client)))
            {
                Filters_SendChatToReceiver(i, client, message);
            }
        }
    }

    PrintToServer("%s", message);
    if (!teamChatOnly)
    {
        Filters_LogChatMessage(client, message);
    }
    return true;
}

void SendFallbackMessage(int client)
{
    char colorTag[40];
    BuildNameColorTag(client, colorTag, sizeof(colorTag));

    char output[256];
    Format(output, sizeof(output), "%s%N{default}: {gold}nigger", colorTag, client);
    Filters_PrintToChatAllEx(client, output);
    Filters_LogChatMessage(client, output);
}

public Action Command_WebSay(int client, int args)
{
    // Console-only intended, but allow any caller
    char raw[256];
    GetCmdArgString(raw, sizeof(raw));
    TrimString(raw);
    if (!raw[0] || GetConVarInt(g_hChatFrontend) < 1)
    {
        return Plugin_Handled;
    }
    char hash[32];
    char msgPart[256];
    int idx = BreakString(raw, hash, sizeof(hash));
    if (idx == -1)
    {
        strcopy(msgPart, sizeof(msgPart), hash);
        strcopy(hash, sizeof(hash), "web");
    }
    else
    {
        strcopy(msgPart, sizeof(msgPart), raw[idx]);
        if (!hash[0])
        {
            strcopy(hash, sizeof(hash), "web");
        }
    }
    TrimString(msgPart);
    if (!msgPart[0])
    {
        return Plugin_Handled;
    }

    char colorTag[32];
    if (!Filters_GetWebNameColor(hash, colorTag, sizeof(colorTag)))
    {
        strcopy(colorTag, sizeof(colorTag), "{gold}");
    }

    char label[96];
    Format(label, sizeof(label), "%s[%s]{default}", colorTag, hash);
    char out[256];
    Format(out, sizeof(out), "%s %s", label, msgPart);
    Filters_PrintToChatAll(out);
    Filters_LogDebug("sm_websay broadcast hash %s message %s", hash, msgPart);
    // Log web message
    if (g_bDbReady)
    {
        char escapedMsg[512];
        SQL_EscapeString(g_hFiltersDb, msgPart, escapedMsg, sizeof(escapedMsg));
        char query[1024];
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message, alert) VALUES (%d, NULL, NULL, '%s', '%s', 1)",
            GetTime(), hash, escapedMsg);
        g_hFiltersDb.Query(Filters_InsertChatCallback, query);
    }
    else
    {
        Filters_LogDebug("DB not ready; unable to log sm_websay message");
    }
    return Plugin_Handled;
}

// Helper function to send message to whitelisted admins
void SendToWhitelistedAdmins(int sender, const char[] message, const char[] prefix = "")
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
            
        if (g_PlayerState[i].isWhitelisted)
        {
            if (prefix[0] != '\0')
            {
                char out[512];
                Format(out, sizeof(out), "%s %s", prefix, message);
                Filters_SendChatToReceiver(i, sender, out);
            }
            else
                Filters_SendChatToReceiver(i, sender, message);
        }
    }
}

void SendToWhitelistedAdminsBlacklisted(int sender, const char[] message, const char[] prefix = "")
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;

        if (g_PlayerState[i].isWhitelisted)
        {
            if (prefix[0] != '\0')
            {
                char out[512];
                Format(out, sizeof(out), "%s %s", prefix, message);
                Filters_SendChatToReceiver(i, sender, out);
            }
            else
                Filters_SendChatToReceiver(i, sender, message);
        }
    }
}

void LoadFilterConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/filters.cfg");
    
    if (!FileExists(configPath))
    {
        LogMessage("Config file not found, creating default: %s", configPath);
        CreateDefaultConfig(configPath);
    }
    
    KeyValues kv = new KeyValues("filters");
    
    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to parse config file: %s", configPath);
        delete kv;
        SetFailState("Failed to parse filters.cfg");
        return;
    }
    
    // Reset counts
    g_FilterCount = 0;
    g_BlacklistCount = 0;
    g_Blacklist50Count = 0;
    g_ForcedStatusCount = 0;
    g_AllowedCommandsCount = 0;

    if (g_WebNameColors == null)
    {
        g_WebNameColors = new StringMap();
    }
    else
    {
        g_WebNameColors.Clear();
    }
    
    // Load filter_words section
    if (kv.JumpToKey("filter_words"))
    {
        if (kv.GotoFirstSubKey(false)) // false = values, not sections
        {
            do
            {
                if (g_FilterCount >= MAX_FILTERS)
                {
                    LogError("Maximum filter limit reached (%d)", MAX_FILTERS);
                    break;
                }
                
                char original[MAX_WORD_LENGTH];
                char filtered[MAX_WORD_LENGTH];
                
                kv.GetSectionName(original, sizeof(original));
                kv.GetString(NULL_STRING, filtered, sizeof(filtered));
                
                strcopy(g_FilterWords[g_FilterCount], MAX_WORD_LENGTH, original);
                strcopy(g_ReplacementWords[g_FilterCount], MAX_WORD_LENGTH, filtered);
                
                g_FilterCount++;
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load blacklist_words section
    if (kv.JumpToKey("blacklist_words"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_BlacklistCount >= MAX_BLACKLIST)
                {
                    LogError("Maximum blacklist limit reached (%d)", MAX_BLACKLIST);
                    break;
                }
                
                char word[MAX_WORD_LENGTH];
                kv.GetSectionName(word, sizeof(word));
                
                strcopy(g_BlacklistWords[g_BlacklistCount], MAX_WORD_LENGTH, word);
                
                g_BlacklistCount++;
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }

    // Load blacklist_words_50 section
    if (kv.JumpToKey("blacklist_words_50"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_Blacklist50Count >= MAX_BLACKLIST)
                {
                    LogError("Maximum blacklist_50 limit reached (%d)", MAX_BLACKLIST);
                    break;
                }

                char word[MAX_WORD_LENGTH];
                kv.GetSectionName(word, sizeof(word));

                strcopy(g_BlacklistWords50[g_Blacklist50Count], MAX_WORD_LENGTH, word);

                g_Blacklist50Count++;
            }
            while (kv.GotoNextKey(false));

            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load force_status section
    if (kv.JumpToKey("force_status"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_ForcedStatusCount >= MAX_FORCED_STATUS)
                {
                    LogError("Maximum forced status limit reached (%d)", MAX_FORCED_STATUS);
                    break;
                }
                
                char steamid[32];
                char status[32];
                
                kv.GetSectionName(steamid, sizeof(steamid));
                kv.GetString(NULL_STRING, status, sizeof(status));
                
                // Validate status type
                if (StrEqual(status, "whitelist") || StrEqual(status, "blacklist") || StrEqual(status, "redlist") || StrEqual(status, "filter_whitelist"))
                {
                    strcopy(g_ForcedStatusSteamIDs[g_ForcedStatusCount], 32, steamid);
                    strcopy(g_ForcedStatusTypes[g_ForcedStatusCount], 32, status);
                    g_ForcedStatusCount++;
                }
                else
                {
                    LogError("Invalid status type '%s' for SteamID '%s'", status, steamid);
                }
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load commands section
    if (kv.JumpToKey("commands"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_AllowedCommandsCount >= MAX_COMMANDS)
                {
                    LogError("Maximum commands limit reached (%d)", MAX_COMMANDS);
                    break;
                }
                
                char command[MAX_WORD_LENGTH];
                kv.GetSectionName(command, sizeof(command));
                
                strcopy(g_AllowedCommands[g_AllowedCommandsCount], MAX_WORD_LENGTH, command);
                
                g_AllowedCommandsCount++;
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }

    // Load webnames section for web chat color overrides
    if (kv.JumpToKey("webnames"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char name[128];
                char color[32];
                kv.GetSectionName(name, sizeof(name));
                kv.GetString(NULL_STRING, color, sizeof(color));

                TrimString(name);
                TrimString(color);
                if (!name[0] || !color[0])
                {
                    continue;
                }

                StringToLower(name);
                g_WebNameColors.SetString(name, color);
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    delete kv;
    
    PrintToServer("[Word Filter] Loaded %d filter words, %d blacklist words, %d blacklist_50 words, %d forced status entries, and %d commands",
                  g_FilterCount, g_BlacklistCount, g_Blacklist50Count, g_ForcedStatusCount, g_AllowedCommandsCount);
}

// Example usage function - filters a string
public void FilterString(char[] input, int maxlen)
{
    bool caseSensitive = g_hFiltersCaseSensitive == null ? true : g_hFiltersCaseSensitive.BoolValue;

    // Apply word filters
    for (int i = 0; i < g_FilterCount; i++)
    {
        ReplaceString(input, maxlen, g_FilterWords[i], g_ReplacementWords[i], caseSensitive);
    }
}

    // Example usage function - checks if string contains blacklisted word
    public bool ContainsBlacklistedWord(const char[] input)
{
    char lowerInput[256];
    strcopy(lowerInput, sizeof(lowerInput), input);
    StringToLower(lowerInput);
    
    for (int i = 0; i < g_BlacklistCount; i++)
    {
        char lowerBlacklist[MAX_WORD_LENGTH];
        strcopy(lowerBlacklist, sizeof(lowerBlacklist), g_BlacklistWords[i]);
        StringToLower(lowerBlacklist);
        
        if (StrContains(lowerInput, lowerBlacklist) != -1)
        {
            return true;
        }
    }
    
    return false;
}

// Helper function to convert string to lowercase
void StringToLower(char[] input)
{
    int len = strlen(input);
    for (int i = 0; i < len; i++)
    {
        input[i] = CharToLower(input[i]);
    }
}

bool Filters_GetWebNameColor(const char[] name, char[] outColor, int maxlen)
{
    if (g_WebNameColors == null)
    {
        return false;
    }

    char key[128];
    strcopy(key, sizeof(key), name);
    TrimString(key);
    if (!key[0])
    {
        return false;
    }

    StringToLower(key);
    return g_WebNameColors.GetString(key, outColor, maxlen);
}

// Creates default config file
void CreateDefaultConfig(const char[] path)
{
    File file = OpenFile(path, "w");
    
    if (file == null)
    {
        LogError("Failed to create config file: %s", path);
        SetFailState("Could not create filters.cfg");
        return;
    }
    
    // Write default config structure
    file.WriteLine("\"filters\"");
    file.WriteLine("{");
    file.WriteLine("    \"filter_words\"");
    file.WriteLine("    {");
    file.WriteLine("        \"badword1\"    \"filtered\"");
    file.WriteLine("        \"badword2\"    \"filtered\"");
    file.WriteLine("    }");
    file.WriteLine("    \"blacklist_words\"");
    file.WriteLine("    {");
    file.WriteLine("        \"blockedword1\"    \"\"");
    file.WriteLine("        \"blockedword2\"    \"\"");
    file.WriteLine("        \"blockedword3\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("    \"blacklist_words_50\"");
    file.WriteLine("    {");
    file.WriteLine("        \"softblocked1\"    \"\"");
    file.WriteLine("        \"softblocked2\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("    \"force_status\"");
    file.WriteLine("    {");
    file.WriteLine("        \"STEAM_0:0:12345678\"    \"whitelist\"");
    file.WriteLine("        \"STEAM_0:1:87654321\"    \"blacklist\"");
    file.WriteLine("        \"STEAM_0:0:33445566\"    \"redlist\"");
    file.WriteLine("        \"STEAM_0:0:11223344\"    \"filter_whitelist\"");
    file.WriteLine("    }");
    file.WriteLine("    \"commands\"");
    file.WriteLine("    {");
    file.WriteLine("        \"rtv\"    \"\"");
    file.WriteLine("        \"unrtv\"    \"\"");
    file.WriteLine("        \"nominate\"    \"\"");
    file.WriteLine("        \"nextmap\"    \"\"");
    file.WriteLine("        \"motd\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("}");
    
    delete file;
    
    LogMessage("Default config file created: %s", path);
}

void LoadNameColorFromDb(int client)
{
    g_NameColors[client][0] = '\0';

    if (!g_bDbReady || g_hFiltersDb == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
    {
        return;
    }

    char escapedSteam[64];
    SQL_EscapeString(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    Format(query, sizeof(query), "SELECT color FROM filters_namecolors WHERE steamid = '%s' LIMIT 1", escapedSteam);
    g_hFiltersDb.Query(Filters_LoadNameColorCallback, query, GetClientUserId(client));
}

void SaveNameColorToDb(int client, const char[] color)
{
    if (!g_bDbReady || g_hFiltersDb == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
    {
        return;
    }

    char escapedSteam[64];
    char escapedColor[64];
    SQL_EscapeString(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam));
    SQL_EscapeString(g_hFiltersDb, color, escapedColor, sizeof(escapedColor));

    char query[320];
    Format(query, sizeof(query),
        "REPLACE INTO filters_namecolors (steamid, color, updated_at) VALUES ('%s', '%s', %d)",
        escapedSteam, escapedColor, GetTime());
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

public void Filters_LoadNameColorCallback(Database db, DBResultSet results, const char[] error, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[Filters] Failed to load name color: %s", error);
        return;
    }

    if (results == null || !results.FetchRow())
    {
        g_NameColors[client][0] = '\0';
        return;
    }

    char dbColor[32];
    results.FetchString(0, dbColor, sizeof(dbColor));
    TrimString(dbColor);
    ToLowercase(dbColor);

    if (!dbColor[0])
    {
        g_NameColors[client][0] = '\0';
        return;
    }

    if (!CColorExists(dbColor))
    {
        g_NameColors[client][0] = '\0';
        PrintToServer("[FILTERS] %N had invalid DB name color '%s', resetting to team color", client, dbColor);
        SaveNameColorToDb(client, "");
        return;
    }

    strcopy(g_NameColors[client], sizeof(g_NameColors[]), dbColor);
    PrintToServer("[FILTERS] %N loaded custom name color '%s' (db)", client, g_NameColors[client]);
}

// Process client cookies on connect/cache
void ProcessCookies(int client)
{
    if (g_PlayerState[client].cookiesProcessed)
    {
        return;
    }

    g_PlayerState[client].cookiesProcessed = true;

    char cookie[32];

    LoadNameColorFromDb(client);
    
    // Check if client has forced status from config
    char steamid[32];
    if (GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        for (int i = 0; i < g_ForcedStatusCount; i++)
        {
            if (StrEqual(steamid, g_ForcedStatusSteamIDs[i]))
            {
                if (StrEqual(g_ForcedStatusTypes[i], "whitelist"))
                {
                    PrintToServer("[FILTERS] %N is force whitelisted (from config)", client);
                    g_PlayerState[client].isWhitelisted = true;
                    return; // Skip cookie processing for forced status
                }
                else if (StrEqual(g_ForcedStatusTypes[i], "blacklist"))
                {
                    PrintToServer("[FILTERS] %N is force blacklisted (from config)", client);
                    g_PlayerState[client].isBlacklisted = true;
                    return;
                }
                else if (StrEqual(g_ForcedStatusTypes[i], "redlist"))
                {
                    PrintToServer("[FILTERS] %N is force redlisted (from config)", client);
                    g_PlayerState[client].isredlisted = true;
                    SetClientCookie(client, g_hCookieredlist, "1");
                    return;
                }
                else if (StrEqual(g_ForcedStatusTypes[i], "filter_whitelist"))
                {
                    PrintToServer("[FILTERS] %N is force filter whitelisted (from config)", client);
                    g_PlayerState[client].isFilterWhitelisted = true;
                    return;
                }
            }
        }
    }
    
    // Process cookies normally if no forced status
    GetClientCookie(client, g_hCookieWhitelist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is whitelisted", client);
        g_PlayerState[client].isWhitelisted = true;
    }
    else
    {
        g_PlayerState[client].isWhitelisted = false;
    }
    
    GetClientCookie(client, g_hCookieFilterWhitelist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is filter whitelisted", client);
        g_PlayerState[client].isFilterWhitelisted = true;
    }
    else
    {
        g_PlayerState[client].isFilterWhitelisted = false;
    }
    
    GetClientCookie(client, g_hCookieBlacklist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is blacklisted", client);
        g_PlayerState[client].isBlacklisted = true;
    }
    else
    {
        g_PlayerState[client].isBlacklisted = false;
    }

    GetClientCookie(client, g_hCookieredlist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is redlisted", client);
        g_PlayerState[client].isredlisted = true;
    }
    else
    {
        g_PlayerState[client].isredlisted = false;
    }

}

static void Filters_StartAutoRedlistCheck(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (g_hFiltersDb == null || !g_bDbReady)
    {
        return;
    }

    char steamId64[32];
    if (GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
    {
        char query[256];
        Format(query, sizeof(query), "SELECT kills FROM whaletracker WHERE steamid = '%s' LIMIT 1", steamId64);
        g_hFiltersDb.Query(Filters_AutoRedlistKillsCallback, query, GetClientUserId(client));
    }

    char steamId2[32];
    if (GetClientAuthId(client, AuthId_Steam2, steamId2, sizeof(steamId2)))
    {
        char query[256];
        Format(query, sizeof(query), "SELECT rapes_given FROM hugs_stats WHERE steamid = '%s' LIMIT 1", steamId2);
        g_hFiltersDb.Query(Filters_AutoRedlistRapesCallback, query, GetClientUserId(client));
    }
}

static bool Filters_IsForcedRedlist(int client)
{
    char steamid[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        return false;
    }

    for (int i = 0; i < g_ForcedStatusCount; i++)
    {
        if (StrEqual(steamid, g_ForcedStatusSteamIDs[i]) && StrEqual(g_ForcedStatusTypes[i], "redlist"))
        {
            return true;
        }
    }

    return false;
}

static bool Filters_IsAdminClient(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }

    return (GetUserFlagBits(client) != 0);
}

static void Filters_EvaluateAutoRedlist(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (g_PlayerState[client].isWhitelisted)
    {
        return;
    }

    if (Filters_IsAdminClient(client) && !Filters_IsForcedRedlist(client))
    {
        if (g_PlayerState[client].isredlisted)
        {
            PerformUnredlist(0, client);
        }
        return;
    }

    bool hasRapes = g_AutoRedlistGotRapes[client];

    if (!hasRapes)
    {
        return;
    }

    int rapes = g_AutoRedlistRapes[client];
    bool belowThreshold = rapes < REDLIST_RAPES_THRESHOLD;

    if (!g_PlayerState[client].isredlisted)
    {
        if (belowThreshold)
        {
            Performredlist(0, client);
        }
        return;
    }

    if (!belowThreshold && !Filters_IsForcedRedlist(client))
    {
        PerformUnredlist(0, client);
    }
}

public void Filters_AutoRedlistKillsCallback(Database db, DBResultSet results, const char[] error, any userId)
{
    if (error[0])
    {
        LogError("[Filters] Failed to query WhaleTracker kills: %s", error);
        return;
    }

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    int kills = 0;
    if (results != null && results.FetchRow())
    {
        kills = results.FetchInt(0);
    }

    g_AutoRedlistKills[client] = kills;
    g_AutoRedlistGotKills[client] = true;
    Filters_EvaluateAutoRedlist(client);
}

public void Filters_AutoRedlistRapesCallback(Database db, DBResultSet results, const char[] error, any userId)
{
    if (error[0])
    {
        LogError("[Filters] Failed to query hugs rapes: %s", error);
        return;
    }

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    int rapes = 0;
    if (results != null && results.FetchRow())
    {
        rapes = results.FetchInt(0);
    }

    g_AutoRedlistRapes[client] = rapes;
    g_AutoRedlistGotRapes[client] = true;
    Filters_EvaluateAutoRedlist(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (AreClientCookiesCached(client) && !g_PlayerState[client].cookiesProcessed)
    {
        ProcessCookies(client);
        Filters_UpdateVoiceOverrides();
    }

    if (!IsFakeClient(client))
    {
        Filters_StartAutoRedlistCheck(client);
        LoadNameColorFromDb(client);
    }

    Filters_UpdateExternalStats(client);
}

public void OnClientCookiesCached(int client)
{
    if (!g_PlayerState[client].cookiesProcessed)
    {
        ProcessCookies(client);
    }
    Filters_UpdateVoiceOverrides();
    Filters_UpdateExternalStats(client);
    LoadNameColorFromDb(client);
}

public void Filters_OnFilterModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Filters_UpdateVoiceOverrides();
}

public void Filters_OnRedlistChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Filters_UpdateVoiceOverrides();
}

public void OnClientPutInServer(int client)
{
    Filters_AnnouncePlayerEvent(client, true);
    Filters_ResetExternalStats(client);
    if (!IsFakeClient(client))
    {
        CreateTimer(1.0, Timer_PrenameApply, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnClientDisconnect(int client)
{
    g_PlayerState[client].isWhitelisted = false;
    g_PlayerState[client].isFilterWhitelisted = false;
    g_PlayerState[client].isBlacklisted = false;
    g_PlayerState[client].isredlisted = false;
    g_PlayerState[client].cookiesProcessed = false;
    g_NameColors[client][0] = '\0';
    Filters_ResetExternalStats(client);
    for (int i = 1; i <= MaxClients; i++)
    {
        g_VoiceBlocked[client][i] = false;
        g_VoiceBlocked[i][client] = false;
    }
    Filters_AnnouncePlayerEvent(client, false);
}

public void OnPluginEnd()
{
    if (g_WebNameColors != null)
    {
        delete g_WebNameColors;
        g_WebNameColors = null;
    }

    if (g_hFiltersDb != null)
    {
        delete g_hFiltersDb;
        g_hFiltersDb = null;
    }

    if (g_PrenameIdRules != null)
    {
        delete g_PrenameIdRules;
        g_PrenameIdRules = null;
    }
    if (g_PrenameOutputMap != null)
    {
        delete g_PrenameOutputMap;
        g_PrenameOutputMap = null;
    }
}

public any Native_Filters_IsRedlisted(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    return g_PlayerState[client].isredlisted;
}

public any Native_Filters_GetChatName(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int maxlen = GetNativeCell(3);

    char buffer[256];
    buffer[0] = '\0';

    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        char colorTag[32];
        BuildNameColorTag(client, colorTag, sizeof(colorTag));

        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));

        Format(buffer, sizeof(buffer), "%s%s{default}", colorTag, name);
    }

    SetNativeString(2, buffer, maxlen, true);
    return 1;
}

// ==================== WHITELIST COMMANDS ====================

public Action Command_Whitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_whitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed whitelist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = true;
    SetClientCookie(target, g_hCookieWhitelist, "1");
    LogAction(client, target, "\"%L\" whitelisted \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

void PerformUnWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = false;
    SetClientCookie(target, g_hCookieWhitelist, "0");
    LogAction(client, target, "\"%L\" removed whitelist from \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

// ==================== FILTER WHITELIST COMMANDS ====================

public Action Command_FilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_filterwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformFilterWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Filter whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Filter whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnFilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unfilterwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnFilterWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed filter whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed filter whitelist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformFilterWhitelist(int client, int target)
{
    g_PlayerState[target].isFilterWhitelisted = true;
    SetClientCookie(target, g_hCookieFilterWhitelist, "1");
    LogAction(client, target, "\"%L\" filter whitelisted \"%L\"", client, target);
}

void PerformUnFilterWhitelist(int client, int target)
{
    g_PlayerState[target].isFilterWhitelisted = false;
    SetClientCookie(target, g_hCookieFilterWhitelist, "0");
    LogAction(client, target, "\"%L\" removed filter whitelist from \"%L\"", client, target);
}

// ==================== BLACKLIST COMMANDS ====================

public Action Command_Blacklist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_blacklist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformBlacklist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Blacklisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Blacklisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnBlacklist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unblacklist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnBlacklist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed blacklist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed blacklist from %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_ListWhitelists(int client, int args)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return Plugin_Handled;
    }

    Filters_PrintStatusList(client, FilterStatus_Whitelist);
    return Plugin_Handled;
}

public Action Command_ListBlacklists(int client, int args)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return Plugin_Handled;
    }

    Filters_PrintStatusList(client, FilterStatus_Blacklist);
    return Plugin_Handled;
}

public Action Command_Listredlists(int client, int args)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return Plugin_Handled;
    }

    Filters_PrintStatusList(client, FilterStatus_redlist);
    return Plugin_Handled;
}

public Action Command_FiltersHelp(int client, int args)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseHelpCommand(client))
    {
        CPrintToChat(client, "{default}[Filters] You do not have access to this command.");
        return Plugin_Handled;
    }

    Filters_PrintHelp(client);
    return Plugin_Handled;
}

public Action Command_FiltersDebug(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    Filters_UpdateExternalStats(client);

    int rapes = g_PlayerState[client].rapesGiven;
    int kills = g_PlayerState[client].whaleKills;
    char redlisted[4];
    if (g_PlayerState[client].isredlisted)
    {
        strcopy(redlisted, sizeof(redlisted), "yes");
    }
    else
    {
        strcopy(redlisted, sizeof(redlisted), "no");
    }
    char over50[4];
    if (kills > 50)
    {
        strcopy(over50, sizeof(over50), "yes");
    }
    else
    {
        strcopy(over50, sizeof(over50), "no");
    }

    CPrintToChat(client, "{default}[SM] Rapes sent: %d | WhaleTracker kills: %d | Kills > 50: %s | Redlisted: %s", rapes, kills, over50, redlisted);

    if (!g_PlayerState[client].hugsStatsLoaded || !g_PlayerState[client].whaleStatsLoaded)
    {
        CPrintToChat(client, "{default}[SM] Stats are still loading; values may be 0.");
    }

    return Plugin_Handled;
}

void PerformBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = true;
    SetClientCookie(target, g_hCookieBlacklist, "1");
    LogAction(client, target, "\"%L\" blacklisted \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

void PerformUnBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = false;
    SetClientCookie(target, g_hCookieBlacklist, "0");
    LogAction(client, target, "\"%L\" removed blacklist from \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

// ==================== redlist COMMANDS ====================

public Action Command_redlist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_redlist <player>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;

    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }

    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        Performredlist(client, target);
    }

    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "redlisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "redlisted %s", target_name);
    }

    return Plugin_Handled;
}

public Action Command_Unredlist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unredlist <player>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;

    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }

    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnredlist(client, target);
    }

    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed redlist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed redlist from %s", target_name);
    }

    return Plugin_Handled;
}

void Performredlist(int client, int target)
{
    g_PlayerState[target].isredlisted = true;
    SetClientCookie(target, g_hCookieredlist, "1");
    LogAction(client, target, "\"%L\" redlisted \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

void PerformUnredlist(int client, int target)
{
    g_PlayerState[target].isredlisted = false;
    SetClientCookie(target, g_hCookieredlist, "0");
    LogAction(client, target, "\"%L\" removed redlist from \"%L\"", client, target);
    Filters_UpdateVoiceOverrides();
}

void CPrintToChatTeam(int team, int sender, const char[] message)
{
    char prefixed[256];
    bool prefixedReady = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }
        if (!Filters_ShouldReceiveChat(client, sender))
        {
            continue;
        }

        if (GetClientTeam(client) == team)
        {
            Filters_SendChatToReceiver(client, sender, message);
        }
        else if (g_PlayerState[client].isWhitelisted)
        {
            if (!prefixedReady)
            {
                Format(prefixed, sizeof(prefixed), "t: %s", message);
                prefixedReady = true;
            }
            Filters_SendChatToReceiver(client, sender, prefixed);
        }
    }
}

public Action Command_Colors(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    CPrintToChat(client, "{aliceblue}aliceblue, {antiquewhite}antiquewhite, {aqua}aqua, {aquamarine}aquamarine, {azure}azure, {beige}beige, {bisque}bisque, {black}black, {blanchedalmond}blanchedalmond, {blue}blue");
    CPrintToChat(client, "{blueviolet}blueviolet, {brown}brown, {burlywood}burlywood, {cadetblue}cadetblue, {chartreuse}chartreuse, {chocolate}chocolate, {coral}coral, {cornflowerblue}cornflowerblue, {cornsilk}cornsilk, {crimson}crimson");
    CPrintToChat(client, "{cyan}cyan, {darkblue}darkblue, {darkcyan}darkcyan, {darkgoldenrod}darkgoldenrod, {darkgray}darkgray, {darkgrey}darkgrey, {darkgreen}darkgreen, {darkkhaki}darkkhaki, {darkmagenta}darkmagenta, {darkolivegreen}darkolivegreen");
    CPrintToChat(client, "{darkorange}darkorange, {darkorchid}darkorchid, {darkred}darkred, {darksalmon}darksalmon, {darkseagreen}darkseagreen, {darkslateblue}darkslateblue, {darkslategray}darkslategray, {darkslategrey}darkslategrey, {darkturquoise}darkturquoise, {darkviolet}darkviolet");
    CPrintToChat(client, "{deeppink}deeppink, {deepskyblue}deepskyblue, {dimgray}dimgray, {dimgrey}dimgrey, {dodgerblue}dodgerblue, {firebrick}firebrick, {floralwhite}floralwhite, {forestgreen}forestgreen, {fuchsia}fuchsia, {gainsboro}gainsboro");
    CPrintToChat(client, "{ghostwhite}ghostwhite, {gold}gold, {goldenrod}goldenrod, {gray}gray, {grey}grey, {green}green, {greenyellow}greenyellow, {honeydew}honeydew, {hotpink}hotpink, {indianred}indianred");
    CPrintToChat(client, "{indigo}indigo, {ivory}ivory, {khaki}khaki, {lavender}lavender, {lavenderblush}lavenderblush, {lawngreen}lawngreen, {lemonchiffon}lemonchiffon, {lightblue}lightblue, {lightcoral}lightcoral, {lightcyan}lightcyan");
    CPrintToChat(client, "{lightgoldenrodyellow}lightgoldenrodyellow, {lightgray}lightgray, {lightgrey}lightgrey, {lightgreen}lightgreen, {lightpink}lightpink, {lightsalmon}lightsalmon, {lightseagreen}lightseagreen, {lightskyblue}lightskyblue, {lightslategray}lightslategray, {lightslategrey}lightslategrey");
    CPrintToChat(client, "{lightsteelblue}lightsteelblue, {lightyellow}lightyellow, {lime}lime, {limegreen}limegreen, {linen}linen, {magenta}magenta, {maroon}maroon, {mediumaquamarine}mediumaquamarine, {mediumblue}mediumblue, {mediumorchid}mediumorchid");
    CPrintToChat(client, "{mediumpurple}mediumpurple, {mediumseagreen}mediumseagreen, {mediumslateblue}mediumslateblue, {mediumspringgreen}mediumspringgreen, {mediumturquoise}mediumturquoise, {mediumvioletred}mediumvioletred, {midnightblue}midnightblue, {mintcream}mintcream, {mistyrose}mistyrose, {moccasin}moccasin");
    CPrintToChat(client, "{navajowhite}navajowhite, {navy}navy, {oldlace}oldlace, {olive}olive, {olivedrab}olivedrab, {orange}orange, {orangered}orangered, {orchid}orchid, {palegoldenrod}palegoldenrod, {palegreen}palegreen");
    CPrintToChat(client, "{paleturquoise}paleturquoise, {palevioletred}palevioletred, {papayawhip}papayawhip, {peachpuff}peachpuff, {peru}peru, {pink}pink, {plum}plum, {powderblue}powderblue, {purple}purple, {red}red");
    CPrintToChat(client, "{rosybrown}rosybrown, {royalblue}royalblue, {saddlebrown}saddlebrown, {salmon}salmon, {sandybrown}sandybrown, {seagreen}seagreen, {seashell}seashell, {sienna}sienna, {silver}silver, {skyblue}skyblue");
    CPrintToChat(client, "{slateblue}slateblue, {slategray}slategray, {slategrey}slategrey, {snow}snow, {springgreen}springgreen, {steelblue}steelblue, {tan}tan, {teal}teal, {thistle}thistle, {tomato}tomato");
    CPrintToChat(client, "{turquoise}turquoise, {violet}violet, {wheat}wheat, {white}white, {whitesmoke}whitesmoke, {yellow}yellow, {yellowgreen}yellowgreen");

    return Plugin_Handled;
}

bool CheckCommands(const char[] sArgs)
{
    // Allow any message starting with !
    if (strncmp(sArgs, "!", 1) == 0) {
        return true;
    }
    
    // Allow any message containing %
    if (StrContains(sArgs, "%", false) != -1) {
        return true;
    }
    
    // Check against allowed commands list from config
    for (int i = 0; i < g_AllowedCommandsCount; i++) {
        if (StrEqual(sArgs, g_AllowedCommands[i], false)) {
            return true;
        }
    }
    return false;
}

bool CheckBlacklistedTerms(const char[] sArgs)
{
    if (g_hFiltersEnabled != null && !g_hFiltersEnabled.BoolValue)
    {
        return false;
    }

    if (g_hBlacklistMinLen != null && strlen(sArgs) < g_hBlacklistMinLen.IntValue)
    {
        return false;
    }

    for (int i = 0; i < g_BlacklistCount; i++)
    {
        // skip empty entries
        if (g_BlacklistWords[i][0] == '\0')
            continue;

        if (StrContains(sArgs, g_BlacklistWords[i], false) != -1)
        {
            PrintToServer("Blacklisted term: %s", g_BlacklistWords[i]);
            return true;
        }
    }

    for (int i = 0; i < g_Blacklist50Count; i++)
    {
        if (g_BlacklistWords50[i][0] == '\0')
            continue;

        if (StrContains(sArgs, g_BlacklistWords50[i], false) != -1)
        {
            if (GetRandomInt(0, 1) == 1)
            {
                PrintToServer("Blacklisted term (50%%): %s", g_BlacklistWords50[i]);
                return true;
            }
            return false;
        }
    }

    return false;
}
static void Filters_AnnouncePlayerJoin(const char[] name)
{
    char serverName[128];
    Filters_GetServerName(serverName, sizeof(serverName));
    if (serverName[0])
    {
        Filters_InsertSystemMessage(true, false, "{gold}[Server]{default}: {cornflowerblue}%s{default} connected to {gold}[%s]{default}.", name, serverName);
    }
    else
    {
        Filters_InsertSystemMessage(true, false, "{gold}[Server]{default}: {cornflowerblue}%s{default} connected to the server.", name);
    }
}

static void Filters_AnnouncePlayerLeave(const char[] name)
{
    char serverName[128];
    Filters_GetServerName(serverName, sizeof(serverName));
    if (serverName[0])
    {
        Filters_InsertSystemMessage(true, false, "{gold}[Server]{default}: {cornflowerblue}%s{default} disconnected from {gold}[%s]{default}.", name, serverName);
    }
    else
    {
        Filters_InsertSystemMessage(true, false, "{gold}[Server]{default}: {cornflowerblue}%s{default} disconnected from the server.", name);
    }
}

static void Filters_GetServerName(char[] buffer, int maxlen)
{
    if (!g_sServerName[0])
    {
        RefreshServerHostname();
    }
    strcopy(buffer, maxlen, g_sServerName);
}

// ==================== PRENAME (MERGED) ====================

static void Filters_PrenameLoadRules()
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    g_hFiltersDb.Query(Filters_PrenameLoadRulesCallback, "SELECT pattern, newname FROM prename_rules");
}

public void Filters_PrenameLoadRulesCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters/Prename] Failed to load rules: %s", error);
        return;
    }

    if (g_PrenameIdRules != null)
    {
        g_PrenameIdRules.Clear();
    }
    if (g_PrenameOutputMap != null)
    {
        g_PrenameOutputMap.Clear();
    }

    if (results == null)
    {
        return;
    }

    while (results.FetchRow())
    {
        char pattern[PRENAME_MAX_PATTERN];
        char newname[PRENAME_MAX_RENAME];
        results.FetchString(0, pattern, sizeof(pattern));
        results.FetchString(1, newname, sizeof(newname));

        if (Prename_IsIdString(pattern))
        {
            g_PrenameIdRules.SetString(pattern, newname);
            continue;
        }

        char lowerNew[PRENAME_MAX_RENAME];
        strcopy(lowerNew, sizeof(lowerNew), newname);
        Prename_ToLowercaseInPlace(lowerNew, sizeof(lowerNew));
        if (!g_PrenameOutputMap.ContainsKey(lowerNew))
        {
            g_PrenameOutputMap.SetString(lowerNew, newname);
        }
    }
}

public Action Timer_PrenameApply(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Stop;
    }

    Prename_Apply(client);
    return Plugin_Stop;
}

static bool Prename_Apply(int client)
{
    if (!g_bDbReady || g_hFiltersDb == null || g_PrenameIdRules == null || g_PrenameOutputMap == null)
    {
        return false;
    }

    char currentName[MAX_NAME_LENGTH];
    GetClientName(client, currentName, sizeof(currentName));

    char lowerName[MAX_NAME_LENGTH];
    strcopy(lowerName, sizeof(lowerName), currentName);
    Prename_ToLowercaseInPlace(lowerName, sizeof(lowerName));

    char steam2[32], steam64[32];
    Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));

    char rename[PRENAME_MAX_RENAME];
    if (Prename_TryGetIdRule(steam64, steam2, rename, sizeof(rename)))
    {
        if (!StrEqual(currentName, rename, false))
        {
            SetClientName(client, rename);
        }
        return false;
    }

    char output[PRENAME_MAX_RENAME];
    if (!Prename_TryGetOutputMatch(lowerName, output, sizeof(output)))
    {
        return false;
    }

    char migrateId[32];
    Prename_GetPreferredClientId(steam64, steam2, migrateId, sizeof(migrateId));
    if (migrateId[0] != '\0')
    {
        Prename_SaveRule(migrateId, output);
        Prename_SetIdRuleCache(migrateId, output);
    }

    if (!StrEqual(currentName, output, false))
    {
        SetClientName(client, output);
    }
    return true;
}

public Action Command_Prename(int client, int args)
{
    bool isAdmin = (client <= 0) || CheckCommandAccess(client, "sm_prename_admin", ADMFLAG_SLAY, true);

    if (!isAdmin)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            return Plugin_Handled;
        }

        if (args < 1)
        {
            ReplyToCommand(client, "[Kogasa] Usage: sm_prename <newname>");
            return Plugin_Handled;
        }

        char selfName[PRENAME_MAX_RENAME];
        GetCmdArg(1, selfName, sizeof(selfName));
        TrimString(selfName);
        if (!selfName[0])
        {
            ReplyToCommand(client, "[Kogasa] Usage: sm_prename <newname>");
            return Plugin_Handled;
        }

        char steam2[32], steam64[32], steamId[32];
        Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));
        Prename_GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
        if (!steamId[0])
        {
            ReplyToCommand(client, "[Kogasa] Failed to resolve your SteamID.");
            return Plugin_Handled;
        }

        Prename_SaveRule(steamId, selfName);
        Prename_SetIdRuleCache(steamId, selfName);
        SetClientName(client, selfName);
        ReplyToCommand(client, "[Kogasa] Your prename was set to '%s'.", selfName);
        return Plugin_Handled;
    }

    if (args < 2)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_prename <name_substring|steamid> <newname>");
        return Plugin_Handled;
    }

    char patternRaw[PRENAME_MAX_PATTERN];
    char newname[PRENAME_MAX_RENAME];
    GetCmdArg(1, patternRaw, sizeof(patternRaw));
    GetCmdArg(2, newname, sizeof(newname));
    TrimString(patternRaw);
    TrimString(newname);

    if (!patternRaw[0] || !newname[0])
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_prename <name_substring|steamid> <newname>");
        return Plugin_Handled;
    }

    if (Prename_IsIdString(patternRaw))
    {
        Prename_SaveRule(patternRaw, newname);
        Prename_SetIdRuleCache(patternRaw, newname);
        ReplyToCommand(client, "[Kogasa] Prename rule saved: '%s' -> '%s'", patternRaw, newname);
        return Plugin_Handled;
    }

    int matches = 0;
    int target = 0;
    char matchList[256];
    matchList[0] = '\0';
    char name[MAX_NAME_LENGTH];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        GetClientName(i, name, sizeof(name));
        if (StrContains(name, patternRaw, false) == -1)
        {
            continue;
        }

        matches++;
        if (target == 0)
        {
            target = i;
        }

        if (matchList[0] == '\0')
        {
            strcopy(matchList, sizeof(matchList), name);
        }
        else if (strlen(matchList) + strlen(name) + 2 < sizeof(matchList))
        {
            StrCat(matchList, sizeof(matchList), ", ");
            StrCat(matchList, sizeof(matchList), name);
        }
    }

    if (matches == 0)
    {
        ReplyToCommand(client, "[Kogasa] No client matches '%s'.", patternRaw);
        return Plugin_Handled;
    }

    if (matches > 1)
    {
        ReplyToCommand(client, "[Kogasa] Multiple matches for '%s': %s", patternRaw, matchList);
        return Plugin_Handled;
    }

    char steam2[32], steam64[32], steamId[32];
    Prename_GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
    Prename_GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));

    if (!steamId[0])
    {
        ReplyToCommand(client, "[Kogasa] Failed to resolve SteamID for %s.", matchList);
        return Plugin_Handled;
    }

    Prename_SaveRule(steamId, newname);
    Prename_SetIdRuleCache(steamId, newname);
    SetClientName(target, newname);
    ReplyToCommand(client, "[Kogasa] Prename rule saved: %s -> %s (%s)", matchList, newname, steamId);
    return Plugin_Handled;
}

public Action Command_PrenameReset(int client, int args)
{
    bool isAdmin = (client <= 0) || CheckCommandAccess(client, "sm_prename_admin", ADMFLAG_SLAY, true);

    if (!isAdmin)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            return Plugin_Handled;
        }

        char steam2[32], steam64[32], steamId[32];
        Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));
        Prename_GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
        if (!steamId[0])
        {
            ReplyToCommand(client, "[Kogasa] Failed to resolve your SteamID.");
            return Plugin_Handled;
        }

        Prename_DeleteRule(steamId);
        Prename_RemoveIdRuleCache(steamId);
        ReplyToCommand(client, "[Kogasa] Your prename rule has been reset.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_reset <name_substring|steamid>");
        return Plugin_Handled;
    }

    char idRaw[PRENAME_MAX_PATTERN];
    GetCmdArg(1, idRaw, sizeof(idRaw));
    TrimString(idRaw);

    if (!idRaw[0])
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_reset <name_substring|steamid>");
        return Plugin_Handled;
    }

    char steam2[32], steam64[32];
    if (Prename_IsIdString(idRaw))
    {
        if (StrContains(idRaw, "STEAM_", false) == 0)
        {
            int match = Prename_FindClientBySteam2(idRaw);
            if (match > 0)
            {
                Prename_GetClientIds(match, steam2, sizeof(steam2), steam64, sizeof(steam64));
                char resolvedId[32];
                Prename_GetPreferredClientId(steam64, steam2, resolvedId, sizeof(resolvedId));
                if (resolvedId[0])
                {
                    Prename_DeleteRule(resolvedId);
                    Prename_RemoveIdRuleCache(resolvedId);
                    ReplyToCommand(client, "[Kogasa] Prename rule removed for '%s'", resolvedId);
                    return Plugin_Handled;
                }
            }
        }

        Prename_DeleteRule(idRaw);
        Prename_RemoveIdRuleCache(idRaw);
        ReplyToCommand(client, "[Kogasa] Prename rule removed for '%s'", idRaw);
        return Plugin_Handled;
    }

    char targetName[MAX_NAME_LENGTH];
    int target = Prename_FindSingleClientByName(client, idRaw, targetName, sizeof(targetName));
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    char steamId[32];
    Prename_GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
    Prename_GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
    if (!steamId[0])
    {
        ReplyToCommand(client, "[Kogasa] Failed to resolve SteamID for %s.", targetName);
        return Plugin_Handled;
    }

    Prename_DeleteRule(steamId);
    Prename_RemoveIdRuleCache(steamId);
    ReplyToCommand(client, "[Kogasa] Prename rule removed for %s (%s).", targetName, steamId);
    return Plugin_Handled;
}

public Action Command_PrenameMigrate(int client, int args)
{
    int migrated = 0;
    int processed = 0;

    g_PrenameDebugMigrate = true;
    Prename_DebugLog("---- migrate start ----");
    Prename_DebugLog("db_ready=%d id_rules=%d output_rules=%d",
        g_bDbReady ? 1 : 0,
        Prename_GetStringMapCount(g_PrenameIdRules),
        Prename_GetStringMapCount(g_PrenameOutputMap));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }
        processed++;
        migrated += Prename_MigrateLegacyForClient(i);
    }

    Prename_DebugLog("---- migrate end migrated=%d processed=%d ----", migrated, processed);
    g_PrenameDebugMigrate = false;

    ReplyToCommand(client, "[Kogasa] Migrated %d rule(s) across %d client(s).", migrated, processed);
    return Plugin_Handled;
}

static int Prename_MigrateLegacyForClient(int client)
{
    if (!g_bDbReady || g_hFiltersDb == null || g_PrenameIdRules == null || g_PrenameOutputMap == null)
    {
        Prename_DebugLog("client=%d skip db_ready=%d id_rules=%d output_rules=%d",
            client,
            g_bDbReady ? 1 : 0,
            Prename_GetStringMapCount(g_PrenameIdRules),
            Prename_GetStringMapCount(g_PrenameOutputMap));
        return 0;
    }

    char currentName[MAX_NAME_LENGTH];
    GetClientName(client, currentName, sizeof(currentName));

    char lowerName[MAX_NAME_LENGTH];
    strcopy(lowerName, sizeof(lowerName), currentName);
    Prename_ToLowercaseInPlace(lowerName, sizeof(lowerName));

    char steam2[32], steam64[32], migrateId[32];
    Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));
    Prename_GetPreferredClientId(steam64, steam2, migrateId, sizeof(migrateId));

    if (!migrateId[0])
    {
        Prename_DebugLog("client=%d name=\"%s\" no_steamid", client, currentName);
        return 0;
    }

    char existing[PRENAME_MAX_RENAME];
    if (Prename_TryGetIdRule(steam64, steam2, existing, sizeof(existing)) && StrEqual(existing, currentName, false))
    {
        Prename_DebugLog("client=%d name=\"%s\" id=%s already_set", client, currentName, migrateId);
        return 0;
    }

    char output[PRENAME_MAX_RENAME];
    char matchKey[PRENAME_MAX_RENAME];
    if (!Prename_FindBestOutputMatch(lowerName, output, sizeof(output), matchKey, sizeof(matchKey)))
    {
        Prename_DebugLog("client=%d name=\"%s\" id=%s no_output_match", client, currentName, migrateId);
        return 0;
    }

    if (!StrEqual(output, currentName, false))
    {
        Prename_DebugLog("client=%d name=\"%s\" id=%s output=\"%s\" skipped_not_equal", client, currentName, migrateId, output);
        return 0;
    }

    Prename_SaveRule(migrateId, currentName);
    Prename_SetIdRuleCache(migrateId, currentName);
    Prename_DebugLog("client=%d name=\"%s\" id=%s migrated=1", client, currentName, migrateId);
    return 1;
}

static void Prename_SaveRule(const char[] pattern, const char[] newname)
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    char escapedPattern[PRENAME_MAX_PATTERN * 2];
    char escapedNewname[PRENAME_MAX_RENAME * 2];
    SQL_EscapeString(g_hFiltersDb, pattern, escapedPattern, sizeof(escapedPattern));
    SQL_EscapeString(g_hFiltersDb, newname, escapedNewname, sizeof(escapedNewname));

    char query[256];
    Format(query, sizeof(query),
        "REPLACE INTO prename_rules (pattern, newname) VALUES ('%s', '%s')",
        escapedPattern, escapedNewname);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);

    if (Prename_IsIdString(pattern))
    {
        Prename_SyncPointsCacheValue(pattern, newname);
    }
}

static void Prename_DeleteRule(const char[] pattern)
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    char escapedPattern[PRENAME_MAX_PATTERN * 2];
    SQL_EscapeString(g_hFiltersDb, pattern, escapedPattern, sizeof(escapedPattern));

    char query[256];
    Format(query, sizeof(query), "DELETE FROM prename_rules WHERE pattern = '%s'", escapedPattern);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);

    if (Prename_IsIdString(pattern))
    {
        Prename_SyncPointsCacheValue(pattern, "");
    }
}

static void Prename_SyncPointsCacheValue(const char[] steamId, const char[] prename)
{
    if (!g_bDbReady || g_hFiltersDb == null || !steamId[0])
    {
        return;
    }

    char escapedSteam[64];
    char escapedPrename[PRENAME_MAX_RENAME * 2];
    SQL_EscapeString(g_hFiltersDb, steamId, escapedSteam, sizeof(escapedSteam));
    SQL_EscapeString(g_hFiltersDb, prename, escapedPrename, sizeof(escapedPrename));

    char query[256];
    Format(query, sizeof(query),
        "UPDATE whaletracker_points_cache SET prename = '%s' WHERE steamid = '%s'",
        escapedPrename, escapedSteam);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Prename_SetIdRuleCache(const char[] steamid, const char[] newname)
{
    if (g_PrenameIdRules == null)
    {
        return;
    }
    g_PrenameIdRules.SetString(steamid, newname);
}

static void Prename_RemoveIdRuleCache(const char[] steamid)
{
    if (g_PrenameIdRules == null)
    {
        return;
    }
    g_PrenameIdRules.Remove(steamid);
}

static bool Prename_TryGetIdRule(const char[] steam64, const char[] steam2, char[] output, int maxlen)
{
    if (g_PrenameIdRules == null)
    {
        return false;
    }

    if (steam64[0] && g_PrenameIdRules.GetString(steam64, output, maxlen))
    {
        return true;
    }

    if (steam2[0] && g_PrenameIdRules.GetString(steam2, output, maxlen))
    {
        return true;
    }

    return false;
}

static bool Prename_TryGetOutputMatch(const char[] lowerName, char[] output, int maxlen)
{
    char key[PRENAME_MAX_RENAME];
    return Prename_FindBestOutputMatch(lowerName, output, maxlen, key, sizeof(key));
}

static bool Prename_FindBestOutputMatch(const char[] lowerName, char[] output, int outMax, char[] keyOut, int keyMax)
{
    if (g_PrenameOutputMap == null)
    {
        return false;
    }

    StringMapSnapshot snap = g_PrenameOutputMap.Snapshot();
    int count = snap.Length;
    int bestLen = -1;
    char key[PRENAME_MAX_RENAME];
    char bestKey[PRENAME_MAX_RENAME];
    bestKey[0] = '\0';

    for (int i = 0; i < count; i++)
    {
        snap.GetKey(i, key, sizeof(key));
        if (StrContains(lowerName, key) == -1)
        {
            continue;
        }

        int keyLen = strlen(key);
        if (keyLen > bestLen)
        {
            bestLen = keyLen;
            strcopy(bestKey, sizeof(bestKey), key);
        }
    }

    delete snap;

    if (bestKey[0] == '\0')
    {
        return false;
    }

    if (keyMax > 0)
    {
        strcopy(keyOut, keyMax, bestKey);
    }

    return g_PrenameOutputMap.GetString(bestKey, output, outMax);
}

static int Prename_FindSingleClientByName(int requester, const char[] patternRaw, char[] matchName, int matchMax)
{
    char pattern[PRENAME_MAX_PATTERN];
    strcopy(pattern, sizeof(pattern), patternRaw);
    Prename_ToLowercaseInPlace(pattern, sizeof(pattern));

    int matches = 0;
    int target = -1;
    char matchList[256];
    matchList[0] = '\0';

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));

        char lowerName[MAX_NAME_LENGTH];
        strcopy(lowerName, sizeof(lowerName), name);
        Prename_ToLowercaseInPlace(lowerName, sizeof(lowerName));

        if (StrContains(lowerName, pattern, false) == -1)
        {
            continue;
        }

        matches++;
        target = i;
        if (matchMax > 0)
        {
            strcopy(matchName, matchMax, name);
        }

        if (matches == 1)
        {
            strcopy(matchList, sizeof(matchList), name);
        }
        else if (strlen(matchList) + strlen(name) + 2 < sizeof(matchList))
        {
            StrCat(matchList, sizeof(matchList), ", ");
            StrCat(matchList, sizeof(matchList), name);
        }
    }

    if (matches == 0)
    {
        ReplyToCommand(requester, "[Kogasa] No client matches '%s'.", patternRaw);
        return -1;
    }

    if (matches > 1)
    {
        ReplyToCommand(requester, "[Kogasa] Multiple matches for '%s': %s", patternRaw, matchList);
        return -1;
    }

    return target;
}

static int Prename_FindClientBySteam2(const char[] steam2)
{
    if (!steam2[0])
    {
        return -1;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        char id[32];
        GetClientAuthId(i, AuthId_Steam2, id, sizeof(id), true);
        if (StrEqual(id, steam2, false))
        {
            return i;
        }
    }

    return -1;
}

static void Prename_ToLowercaseInPlace(char[] text, int maxlen)
{
    int length = strlen(text);
    if (length > maxlen - 1)
    {
        length = maxlen - 1;
    }

    for (int i = 0; i < length; i++)
    {
        text[i] = CharToLower(text[i]);
    }
}

static void Prename_GetPreferredClientId(const char[] steam64, const char[] steam2, char[] output, int maxlen)
{
    output[0] = '\0';
    if (steam64[0])
    {
        strcopy(output, maxlen, steam64);
    }
    else if (steam2[0])
    {
        strcopy(output, maxlen, steam2);
    }
}

static void Prename_GetClientIds(int client, char[] steam2, int steam2Max, char[] steam64, int steam64Max)
{
    steam2[0] = '\0';
    steam64[0] = '\0';
    GetClientAuthId(client, AuthId_SteamID64, steam64, steam64Max, true);
    GetClientAuthId(client, AuthId_Steam2, steam2, steam2Max, true);
}

static bool Prename_IsIdString(const char[] text)
{
    if (!text[0])
    {
        return false;
    }

    if (StrContains(text, "STEAM_", false) == 0)
    {
        return true;
    }

    int len = strlen(text);
    if (len < 15)
    {
        return false;
    }

    for (int i = 0; i < len; i++)
    {
        if (!IsCharNumeric(text[i]))
        {
            return false;
        }
    }

    return true;
}

static void Prename_DebugLog(const char[] fmt, any ...)
{
    if (!g_PrenameDebugMigrate)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_PrenameDebugLogPath, "%s", buffer);
}

static int Prename_GetStringMapCount(StringMap map)
{
    if (map == null)
    {
        return 0;
    }

    StringMapSnapshot snap = map.Snapshot();
    int count = snap.Length;
    delete snap;
    return count;
}
