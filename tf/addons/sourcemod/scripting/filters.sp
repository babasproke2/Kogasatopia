#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <basecomm>

#include <sdktools>
#include <sdktools_functions>
#include <sdktools_voice>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <adminsdb_api>
#include <hugs_api>
#include <mutecheck_api>
#include <points_store_api>
#include <tags_api>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/database.inc"
#include "include/steam_identity.inc"

#define MAX_FILTERS 128
#define MAX_BLACKLIST 128
#define MAX_WORD_LENGTH 64
#define MAX_FORCED_STATUS 128
#define MAX_COMMANDS 64
#define FILTERS_OUTBOX_CLEANUP_INTERVAL 120
#define FILTERS_OUTBOX_RETENTION_SECONDS 3600
#define FILTERS_CHAT_RETENTION_SECONDS 86400
#define FILTERS_OUTBOX_POLL_INTERVAL 2.0
#define FILTERS_MUTE_CHECK_INTERVAL 1.0
#define FILTERS_CONNECT_QUEUE_DELAY 3.0
#define FILTERS_DEFAULT_DB_CONFIG "default"
#define FILTERS_DEFAULT_HOST_IP "0.0.0.0"
#define FILTERS_PUBLIC_HOST_IP "173.255.237.230"
#define FILTERS_ACCESS_DENIED "{default}[Filters] You do not have access to this command."
#define REDLIST_RAPES_THRESHOLD 1
#define PRENAME_MAX_PATTERN 64
#define PRENAME_MAX_RENAME 64
#define NAME_COLOR_AMERICA "america"
#define NAME_PATTERN_MAP "map"
#define NAME_PATTERN_TRANS "trans"
#define NAME_PATTERN_RAINBOW "rainbow"
#define NAME_PATTERN_GRADIENT_PREFIX "gradient:"
#define NAME_PATTERN_TRIPLE_GRADIENT_PREFIX "gradient3:"
#define NAME_PATTERN_MAX 96
#define NAME_GRADIENT_MAX_STEPS 8
#define NAME_GRADIENT_DEFAULT_COMPLETION 50
#define NAME_GRADIENT_MAX_COMPLETION 90
#define AMERICA_NAME_ACCESS_ITEM "america_flag_name"
#define MAP_NAME_ACCESS_ITEM "map_flag_name"
#define TRANS_NAME_ACCESS_ITEM "trans_flag_name"
#define RAINBOW_NAME_ACCESS_ITEM "rainbow_name_access"
#define GRADIENT_NAME_ACCESS_ITEM "gradient_name_access"
#define TRIPLE_GRADIENT_ACCESS_ITEM "triple_gradient_upgrade"
#define CHAT_PREFIX_MAXLEN 128

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
bool g_MuteDeafened[MAXPLAYERS + 1];
int g_AutoRedlistKills[MAXPLAYERS + 1];
int g_AutoRedlistRapes[MAXPLAYERS + 1];
bool g_AutoRedlistGotKills[MAXPLAYERS + 1];
bool g_AutoRedlistGotRapes[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("filters");
    CreateNative("Filters_IsRedlisted", Native_Filters_IsRedlisted);
    CreateNative("Filters_GetChatName", Native_Filters_GetChatName);
    CreateNative("Filters_GetSteamIdColorTag", Native_Filters_GetSteamIdColorTag);
    CreateNative("Filters_GetLastRecordedSteamName", Native_Filters_GetLastRecordedSteamName);
    MarkNativeAsOptional("AdminsDB_GetClientWhitelistLevel");
    MarkNativeAsOptional("Hugs_GetRapesGiven");
    MarkNativeAsOptional("Hugs_AreStatsLoaded");
    MarkNativeAsOptional("MuteCheck_GetMutedClientCount");
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("WhaleTracker_GetCumulativeKills");
    MarkNativeAsOptional("WhaleTracker_AreStatsLoaded");
    MarkNativeAsOptional("Tags_GetSelectedTag");
    return APLRes_Success;
}

// Cookie handles
Handle g_hCookieFilterWhitelist;
Handle g_hCookieredlist;
Handle g_hChatFrontend;

// Per-client name color and pattern preferences (empty string means unset)
char g_NameColors[MAXPLAYERS + 1][32];
char g_NamePatterns[MAXPLAYERS + 1][NAME_PATTERN_MAX];

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
ConVar g_hPChat = null;
ConVar g_hMuteDeafenEnabled = null;

// Global arrays for word filtering
char g_FilterWords[MAX_FILTERS][MAX_WORD_LENGTH];
char g_ReplacementWords[MAX_FILTERS][MAX_WORD_LENGTH];
int g_FilterCount = 0;
char g_CaseInsensitiveFilterWords[MAX_FILTERS][MAX_WORD_LENGTH];
char g_CaseInsensitiveReplacementWords[MAX_FILTERS][MAX_WORD_LENGTH];
int g_CaseInsensitiveFilterCount = 0;

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
StringMap g_WebNameColors = null;

// Connection event queue
ArrayList g_ConnectQueue = null;
Handle g_ConnectQueueTimer = null;
Handle g_hPollOutboxTimer = null;
Handle g_hMuteDeafenTimer = null;
int g_iOutboxTimerGeneration = 0;
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
int g_iLastChatCleanup = 0;

bool Filters_DebugEnabled()
{
    return g_hChatDebug != null && g_hChatDebug.BoolValue;
}

bool Filters_RedlistEnabled()
{
    return g_hRedlistEnabled != null && g_hRedlistEnabled.BoolValue;
}

bool Filters_PChatEnabled()
{
    return g_hPChat == null || g_hPChat.BoolValue;
}

bool Filters_MuteDeafenEnabled()
{
    return g_hMuteDeafenEnabled != null && g_hMuteDeafenEnabled.BoolValue;
}

bool Filters_IsClientGagged(int client)
{
    return BaseComm_IsClientGagged(client)
        || (Filters_MuteDeafenEnabled() && g_MuteDeafened[client]);
}

static int Filters_GetFilterMode()
{
    if (g_sChatMode2 == INVALID_HANDLE)
    {
        return 0;
    }

    int mode = GetConVarInt(g_sChatMode2);
    if (mode < 0)
    {
        return 0;
    }
    if (mode > 2)
    {
        return 2;
    }
    return mode;
}

static bool Filters_IsCordModeEnabled()
{
    return Filters_GetFilterMode() != 0;
}

static bool Filters_CordModeWhitelistedCanReceiveBlacklisted()
{
    return Filters_GetFilterMode() != 0;
}

static bool Filters_CordModeBlacklistedCanReceiveWhitelisted()
{
    return Filters_GetFilterMode() == 1;
}

void Filters_LogDebug(const char[] fmt, any ...)
{
    if (!Filters_DebugEnabled())
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogMessage("[Filters][Chat] %s", buffer);
}

static bool Filters_IsClientIndex(int client)
{
    return client > 0 && client <= MaxClients;
}

static bool Filters_IsRealClientInGame(int client)
{
    return Filters_IsClientIndex(client) && IsClientInGame(client) && !IsFakeClient(client);
}


static void Filters_ClearClientState(int client)
{
    if (!Filters_IsClientIndex(client))
    {
        return;
    }

    g_PlayerState[client].isWhitelisted = false;
    g_PlayerState[client].isFilterWhitelisted = false;
    g_PlayerState[client].isBlacklisted = false;
    g_PlayerState[client].isredlisted = false;
    g_PlayerState[client].cookiesProcessed = false;
    g_NameColors[client][0] = '\0';
    g_NamePatterns[client][0] = '\0';
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
        strcopy(g_sHostIp, sizeof(g_sHostIp), FILTERS_DEFAULT_HOST_IP);
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
    strcopy(g_sPublicHostIp, sizeof(g_sPublicHostIp), FILTERS_PUBLIC_HOST_IP);
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
        strcopy(ip, sizeof(ip), FILTERS_DEFAULT_HOST_IP);
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
    LoadTranslations("common.phrases");

    Filters_EnsureCollections();
    LoadFilterConfig();
    Filters_CreateConVars();
    Filters_RegisterCookies();
    Filters_RegisterCommands();

    RefreshHostAddress();
    Filters_SQLConnect();
    Filters_StartTimers();
    Filters_RestoreConnectedClients();

    Filters_UpdateVoiceOverrides();
}

static void Filters_EnsureCollections()
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
}

static void Filters_CreateConVars()
{
    g_sEnabled = CreateConVar("nobroly", "1", "If 0, filter chat to one word");
    g_sChatMode2 = CreateConVar("filtermode", "0", "0=off, 1=quarantine with mutual whitelist/blacklist visibility, 2=quarantine with whitelist monitoring only");
    g_hChatDebug = CreateConVar("filters_chat_debug", "0", "Enable verbose debug logging for chat relay");
    g_hChatFrontend = CreateConVar("filters_chat_frontend", "1", "Enable/Disable reading frontend chat from the database");
    g_hFiltersEnabled = CreateConVar("filters", "0", "If 0, blacklist word matching is disabled.");
    g_hRedlistEnabled = CreateConVar("redlist", "0", "Enable/Disable redlist features.", _, true, 0.0, true, 1.0);
    g_hBlacklistMinLen = CreateConVar("filters_blacklist_minlen", "8", "Minimum message length to check blacklist words.");
    g_hFiltersChristmas = CreateConVar("filters_christmas", "0", "If 1, red chat is {axis} and blue chat is {green}.");
    g_hFiltersTeamChat = CreateConVar("teamchat", "0", "If 1, normal chat is sent to the sender's team only.");
    g_hPChat = CreateConVar("sm_pchat", "1", "If 0, filtered/monitored chat is only printed to server console and not shown to whitelisted clients.", _, true, 0.0, true, 1.0);
    g_hMuteDeafenEnabled = CreateConVar(
        "sm_filters_mute_deafen",
        "0",
        "If 1, clients who mute another connected player cannot hear voice chat or send chat until no connected players are muted.",
        _,
        true,
        0.0,
        true,
        1.0
    );
    g_hFiltersCaseSensitive = CreateConVar(
        "filters_case_sensitive",
        "1",
        "If 1, chat filters are case-sensitive (exact casing must match)"
    );

    HookConVarChange(g_sChatMode2, Filters_OnFilterModeChanged);
    HookConVarChange(g_hRedlistEnabled, Filters_OnRedlistChanged);
    HookConVarChange(g_hMuteDeafenEnabled, Filters_OnMuteDeafenChanged);
}

static void Filters_RegisterCookies()
{
    g_hCookieFilterWhitelist = RegClientCookie("filter_filterwhitelist", "Player is whitelisted from word filters only", CookieAccess_Protected);
    g_hCookieredlist = RegClientCookie("filter_redlist", "Player cannot hear blacklisted clients", CookieAccess_Protected);
}

static void Filters_RegisterCommands()
{
    RegAdminCmd("sm_filterwhitelist", Command_FilterWhitelist, ADMFLAG_CHAT, "sm_filterwhitelist <player> - Whitelists a player from word filters only");
    RegAdminCmd("sm_unfilterwhitelist", Command_UnFilterWhitelist, ADMFLAG_CHAT, "sm_unfilterwhitelist <player> - Removes filter whitelist from a player");

    RegAdminCmd("sm_redlist", Command_redlist, ADMFLAG_CHAT, "sm_redlist <player> - redlist a player (can't hear blacklisted clients)");
    RegAdminCmd("sm_unredlist", Command_Unredlist, ADMFLAG_CHAT, "sm_unredlist <player> - Removes redlist from a player");
    RegAdminCmd("sm_redlists", Command_Listredlists, ADMFLAG_CHAT, "sm_redlists - Lists redlisted players");
    RegAdminCmd("sm_filtershelp", Command_FiltersHelp, ADMFLAG_CHAT, "sm_filtershelp - Shows filters convar help");
    RegConsoleCmd("sm_filters_debug", Command_FiltersDebug, "Show debug stats for filters");
    RegConsoleCmd("sm_colors", Command_Colors, "Show available chat colors");
    RegConsoleCmd("sm_colours", Command_Colors, "Show available chat colours");
    AddCommandListener(Listener_Colors, "colors");
    RegConsoleCmd("sm_gradientmenu", Command_GradientMenu, "Adjust where the second gradient color becomes full.");
    RegConsoleCmd("sm_gm", Command_GradientMenu, "Adjust where the second gradient color becomes full.");
    RegConsoleCmd("sm_prename", Command_Prename, "sm_prename <name_substring|steamid> <newname> (admins) or sm_prename <newname> (self)");
    RegConsoleCmd("sm_reset", Command_PrenameReset, "sm_reset <name|steamid> (admins) or sm_reset (self)");
    RegAdminCmd("sm_migrate", Command_PrenameMigrate, ADMFLAG_SLAY, "sm_migrate - Migrates legacy name rules to SteamID rules for connected clients");

    RegConsoleCmd("sm_websay", Command_WebSay, "Relay a web chat message to all players");
}

static void Filters_StartTimers()
{
    if (g_hPollOutboxTimer == null)
    {
        g_iOutboxTimerGeneration++;
        g_hPollOutboxTimer = CreateTimer(FILTERS_OUTBOX_POLL_INTERVAL, Timer_PollOutbox, g_iOutboxTimerGeneration, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }

    if (g_hMuteDeafenTimer == null)
    {
        g_hMuteDeafenTimer = CreateTimer(FILTERS_MUTE_CHECK_INTERVAL, Timer_RefreshMuteDeafenState, _, TIMER_REPEAT);
    }
}

static void Filters_StopOutboxTimer()
{
    // The timer handle can already be closed by SourceMod lifecycle events. Retire it by generation instead.
    g_iOutboxTimerGeneration++;
    g_hPollOutboxTimer = null;
}

static bool Filters_CanCheckMutedClients()
{
    return Filters_MuteDeafenEnabled()
        && GetFeatureStatus(FeatureType_Native, "MuteCheck_GetMutedClientCount") == FeatureStatus_Available;
}

static void Filters_ClearMuteDeafenState()
{
    bool changed = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_MuteDeafened[client])
        {
            g_MuteDeafened[client] = false;
            changed = true;
        }
    }

    if (changed)
    {
        Filters_UpdateVoiceOverrides();
    }
}

static void Filters_RefreshMuteDeafenState()
{
    bool canCheck = Filters_CanCheckMutedClients();
    bool changed = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        bool shouldDeafen = canCheck
            && Filters_IsRealClientInGame(client)
            && MuteCheck_GetMutedClientCount(client) > 0;

        if (g_MuteDeafened[client] != shouldDeafen)
        {
            g_MuteDeafened[client] = shouldDeafen;
            changed = true;
        }
    }

    if (changed)
    {
        Filters_UpdateVoiceOverrides();
    }
}

public Action Timer_RefreshMuteDeafenState(Handle timer)
{
    Filters_RefreshMuteDeafenState();
    return Plugin_Continue;
}

static void Filters_RestoreConnectedClients()
{
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
            Filters_ClearClientState(i);
        }

        Filters_ResetExternalStats(i);
        Filters_UpdateExternalStats(i);
    }
}

public void OnConfigsExecuted()
{
    RefreshHostAddress();
    RefreshServerHostname();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "mutecheck", false))
    {
        Filters_RefreshMuteDeafenState();
        return;
    }

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
    if (StrEqual(name, "mutecheck", false))
    {
        Filters_ClearMuteDeafenState();
        return;
    }

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
    // On a first-load map start, an OnPluginStart-created timer may still be alive.
    // Stop it before recreating the poller so one server cannot relay each row twice.
    Filters_StopOutboxTimer();
    Filters_StartTimers();

    char mapName[128];
    GetCurrentMap(mapName, sizeof(mapName));
    Filters_InsertSystemMessage(false, false, "{gold}[Server]{default}: Map changed to {cornflowerblue}%s", mapName);
}

// Database for chat log
Database g_hFiltersDb = null;
bool g_bDbReady = false;
char g_sDbConfig[32] = FILTERS_DEFAULT_DB_CONFIG;
Handle g_hFiltersDbReconnectTimer = null;

static bool Filters_DbAvailable()
{
    return Db_IsReady(g_hFiltersDb, g_bDbReady);
}

void Filters_SQLConnect()
{
    Db_CancelTimer(g_hFiltersDbReconnectTimer);
    Db_Close(g_hFiltersDb, g_bDbReady);
    if (!Db_CheckConfigOrLog("Filters", g_sDbConfig))
    {
        return;
    }

    Filters_LogDebug("Connecting to database config '%s'", g_sDbConfig);
    Database.Connect(T_Filters_SQLConnect, g_sDbConfig);
}

void Filters_ScheduleSqlReconnect(float delay = DB_RECONNECT_DELAY)
{
    g_bDbReady = false;
    if (g_hFiltersDbReconnectTimer == null)
    {
        g_hFiltersDbReconnectTimer = CreateTimer(delay, Timer_ReconnectFiltersSql, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ReconnectFiltersSql(Handle timer, any data)
{
    g_hFiltersDbReconnectTimer = null;
    Filters_SQLConnect();
    return Plugin_Stop;
}

public void T_Filters_SQLConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[Filters] DB connection failed: %s", error);
        Filters_ScheduleSqlReconnect();
        return;
    }

    g_hFiltersDb = db;
    g_bDbReady = true;
    g_bOutboxStampReady = false;
    Db_CancelTimer(g_hFiltersDbReconnectTimer);
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
        "CREATE TABLE IF NOT EXISTS whaletracker_chat_outbox_deliveries ("
        ... "outbox_id INT NOT NULL,"
        ... "server_stamp VARCHAR(96) NOT NULL,"
        ... "delivered_at INT NOT NULL,"
        ... "PRIMARY KEY(outbox_id, server_stamp),"
        ... "INDEX(delivered_at),"
        ... "INDEX(server_stamp)) DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS prename_rules (pattern VARCHAR(64) PRIMARY KEY, newname VARCHAR(64) NOT NULL)",
        "CREATE TABLE IF NOT EXISTS filters_steam_names ("
        ... "steamid64 VARCHAR(32) PRIMARY KEY,"
        ... "last_name VARCHAR(128) NOT NULL DEFAULT '',"
        ... "last_name_lower VARCHAR(128) NOT NULL DEFAULT '',"
        ... "updated_at INT NOT NULL DEFAULT 0,"
        ... "INDEX(last_name_lower),"
        ... "INDEX(updated_at)) DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS filters_namecolors (steamid VARCHAR(32) PRIMARY KEY, color VARCHAR(32) NOT NULL DEFAULT '', pattern VARCHAR(96) NOT NULL DEFAULT '', updated_at INT NOT NULL DEFAULT 0)",
        "ALTER TABLE filters_namecolors ADD COLUMN IF NOT EXISTS pattern VARCHAR(96) NOT NULL DEFAULT '' AFTER color",
        "ALTER TABLE filters_namecolors MODIFY COLUMN pattern VARCHAR(96) NOT NULL DEFAULT ''"
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
        if (Db_IsTransientError(error))
        {
            Filters_ScheduleSqlReconnect(DB_RECONNECT_FAST_DELAY);
        }
    }
}

public void Filters_SchemaQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters] Schema query failed: %s", error);
        if (Db_IsTransientError(error))
        {
            Filters_ScheduleSqlReconnect(DB_RECONNECT_FAST_DELAY);
        }
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
                LoadNamePreferencesFromDb(i);
            }
        }
        if (!g_PrenameRulesLoaded)
        {
            Filters_PrenameLoadRules();
        }
    }
}

// Poll DB outbox and atomically claim one delivery row per server.
public Action Timer_PollOutbox(Handle timer, any data)
{
    if (data != g_iOutboxTimerGeneration || timer != g_hPollOutboxTimer)
    {
        return Plugin_Stop;
    }

    if (GetConVarInt(g_hChatFrontend) < 1)
	return Plugin_Continue;

    if (!Filters_DbAvailable() || !g_bOutboxStampReady)
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
    char escapedStamp[192];
    Db_Escape(g_hFiltersDb, hostStamp, escapedStamp, sizeof(escapedStamp), "filters");
    char query[1024];
    Format(query, sizeof(query), "SELECT id, iphash, display_name, message, host_ip, host_port, webchatonly, alert, server_ip, server_port, delivered_to FROM whaletracker_chat_outbox o WHERE NOT EXISTS (SELECT 1 FROM whaletracker_chat_outbox_deliveries d WHERE d.outbox_id = o.id AND d.server_stamp = '%s') ORDER BY id ASC LIMIT 20", escapedStamp);
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
                Filters_RecordOutboxDelivery(id, localStamp);
                Filters_LogDebug("Migrated legacy delivery stamp for chat id %d", id);
                continue;
            }
        }
        Filters_ClaimOutboxForDelivery(id, hash, display, msg, sourceIp, sourcePort, webchatOnly, localStamp);
    }
    Filters_MaybeCleanupOutbox();
    Filters_MaybeCleanupChatHistory();
}

static void Filters_RecordOutboxDelivery(int rowId, const char[] localStamp)
{
    if (rowId <= 0 || !localStamp[0] || !Filters_DbAvailable())
    {
        return;
    }

    char escapedStamp[192];
    Db_Escape(g_hFiltersDb, localStamp, escapedStamp, sizeof(escapedStamp), "filters");
    char query[512];
    Format(query, sizeof(query),
        "INSERT IGNORE INTO whaletracker_chat_outbox_deliveries (outbox_id, server_stamp, delivered_at) VALUES (%d, '%s', %d)",
        rowId,
        escapedStamp,
        GetTime());
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Filters_ClaimOutboxForDelivery(int rowId, const char[] hash, const char[] display, const char[] msg, const char[] sourceIp, int sourcePort, bool webchatOnly, const char[] localStamp)
{
    if (rowId <= 0 || !localStamp[0] || !Filters_DbAvailable())
    {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(rowId);
    pack.WriteString(hash);
    pack.WriteString(display);
    pack.WriteString(msg);
    pack.WriteString(sourceIp);
    pack.WriteCell(sourcePort);
    pack.WriteCell(webchatOnly ? 1 : 0);

    char query[512];
    char escapedStamp[192];
    Db_Escape(g_hFiltersDb, localStamp, escapedStamp, sizeof(escapedStamp), "filters");
    Format(query, sizeof(query),
        "INSERT IGNORE INTO whaletracker_chat_outbox_deliveries (outbox_id, server_stamp, delivered_at) VALUES (%d, '%s', %d)",
        rowId,
        escapedStamp,
        GetTime());
    g_hFiltersDb.Query(Filters_OutboxClaimCallback, query, pack);
}

public void Filters_OutboxClaimCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    if (error[0] != '\0' || results == null)
    {
        if (error[0] != '\0') LogError("[Filters] Outbox delivery claim failed: %s", error);
        delete pack;
        return;
    }

    pack.Reset();
    int id = pack.ReadCell();
    char hash[64];
    pack.ReadString(hash, sizeof(hash));
    char display[128];
    pack.ReadString(display, sizeof(display));
    char msg[512];
    pack.ReadString(msg, sizeof(msg));
    char sourceIp[64];
    pack.ReadString(sourceIp, sizeof(sourceIp));
    int sourcePort = pack.ReadCell();
    bool webchatOnly = pack.ReadCell() != 0;
    delete pack;

    if (results.AffectedRows <= 0)
    {
        Filters_LogDebug("Skipping chat id %d; this server already claimed delivery", id);
        return;
    }

    Filters_DeliverOutboxRow(id, hash, display, msg, sourceIp, sourcePort, webchatOnly);
}

static void Filters_DeliverOutboxRow(int id, const char[] hash, const char[] display, const char[] msg, const char[] sourceIp, int sourcePort, bool webchatOnly)
{
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
}

static void Filters_MaybeCleanupOutbox()
{
    if (!Filters_DbAvailable())
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
        "DELETE FROM whaletracker_chat_outbox_deliveries WHERE delivered_at < %d",
        cutoff);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);

    Format(query, sizeof(query),
        "DELETE FROM whaletracker_chat_outbox WHERE created_at < %d",
        cutoff);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Filters_MaybeCleanupChatHistory()
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }
    int now = GetTime();
    if (g_iLastChatCleanup != 0 && now - g_iLastChatCleanup < FILTERS_OUTBOX_CLEANUP_INTERVAL)
    {
        return;
    }
    g_iLastChatCleanup = now;
    int cutoff = now - FILTERS_CHAT_RETENTION_SECONDS;
    if (cutoff <= 0)
    {
        return;
    }
    char query[128];
    Format(query, sizeof(query),
        "DELETE FROM whaletracker_chat WHERE created_at < %d",
        cutoff);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Filters_SanitizeDbMessage(const char[] message, char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, message);
    ReplaceString(buffer, maxlen, "{teamcolor}", "{grey}", false);
}

static void Filters_QueueOutboxMessage(int timestamp, const char[] iphash, const char[] displayName, const char[] message, bool webchatOnly, bool alertFlag)
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    char sanitizedMsg[512];
    char escapedMsg[512];
    Filters_SanitizeDbMessage(message, sanitizedMsg, sizeof(sanitizedMsg));
    Db_Escape(g_hFiltersDb, sanitizedMsg, escapedMsg, sizeof(escapedMsg), "filters");
    char escapedHash[128];
    Db_Escape(g_hFiltersDb, iphash, escapedHash, sizeof(escapedHash), "filters");
    char escapedDisplay[256];
    Db_Escape(g_hFiltersDb, displayName, escapedDisplay, sizeof(escapedDisplay), "filters");
    int webFlag = webchatOnly ? 1 : 0;
    int alert = alertFlag ? 1 : 0;

    char query[1024];
    if (g_bOutboxStampReady)
    {
        char localIp[64];
        int localPort;
        Filters_GetLocalHostStamp(localIp, sizeof(localIp), localPort);
        char escapedIp[128];
        Db_Escape(g_hFiltersDb, localIp, escapedIp, sizeof(escapedIp), "filters");
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
    if (!Filters_DbAvailable() || !g_bOutboxStampReady)
    {
        return;
    }

    char hash[64];
    if (client > 0 && IsClientInGame(client))
    {
        char steamId[32];
        if (Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
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
    if (!Filters_DbAvailable())
    {
        Filters_LogDebug("DB not ready; skipping chat log for client %d", client);
        return;
    }


    char steamId[32];
    bool hasSteam = false;
    steamId[0] = '\0';
    if (client > 0 && IsClientInGame(client) && Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        hasSteam = true;
    }
    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    char escapedName[MAX_NAME_LENGTH * 2];
    char sanitizedMsg[512];
    char escapedMsg[512];
    Db_Escape(g_hFiltersDb, name, escapedName, sizeof(escapedName), "filters");
    Filters_SanitizeDbMessage(message, sanitizedMsg, sizeof(sanitizedMsg));
    Db_Escape(g_hFiltersDb, sanitizedMsg, escapedMsg, sizeof(escapedMsg), "filters");
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
    if (!Filters_DbAvailable())
    {
        Filters_LogDebug("DB not ready; skipping system message");
        return;
    }

    char message[256];
    VFormat(message, sizeof(message), format, 4);

    int timestamp = GetTime();
    char sanitizedMsg[512];
    char escapedMsg[512];
    Filters_SanitizeDbMessage(message, sanitizedMsg, sizeof(sanitizedMsg));
    Db_Escape(g_hFiltersDb, sanitizedMsg, escapedMsg, sizeof(escapedMsg), "filters");
    char localIp[64];
    int localPort;
    Filters_GetLocalHostStamp(localIp, sizeof(localIp), localPort);
    char escapedIp[128];
    Db_Escape(g_hFiltersDb, localIp, escapedIp, sizeof(escapedIp), "filters");

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
        g_ConnectQueueTimer = CreateTimer(FILTERS_CONNECT_QUEUE_DELAY, Timer_ProcessConnectQueue);
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

static void Filters_AnnounceClientJoin(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steam2[32], steam64[32];
    Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));

    char prename[PRENAME_MAX_RENAME];
    if (Prename_TryGetIdRule(steam64, steam2, prename, sizeof(prename)))
    {
        TrimString(prename);
        if (prename[0])
        {
            Filters_AnnouncePlayerJoin(prename);
            return;
        }
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    Filters_AnnouncePlayerJoin(name);
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
    FilterStatus_redlist = 0
};

enum FilterAdminAction
{
    FilterAdmin_FilterWhitelist = 0,
    FilterAdmin_UnFilterWhitelist,
    FilterAdmin_redlist,
    FilterAdmin_Unredlist
};

static void Filters_ApplyAdminTargetAction(int client, int target, FilterAdminAction action)
{
    switch (action)
    {
        case FilterAdmin_FilterWhitelist: PerformFilterWhitelist(client, target);
        case FilterAdmin_UnFilterWhitelist: PerformUnFilterWhitelist(client, target);
        case FilterAdmin_redlist: Performredlist(client, target);
        case FilterAdmin_Unredlist: PerformUnredlist(client, target);
    }
}

static Action Filters_RunTargetAdminCommand(int client, int args, const char[] usage, const char[] activity, FilterAdminAction action)
{
    if (args < 1)
    {
        ReplyToCommand(client, usage);
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    char targetName[MAX_TARGET_LENGTH];
    int targetList[MAXPLAYERS];
    bool targetNameIsMl;
    int targetCount = ProcessTargetString(
        arg,
        client,
        targetList,
        MAXPLAYERS,
        0,
        targetName,
        sizeof(targetName),
        targetNameIsMl);

    if (targetCount <= 0)
    {
        ReplyToTargetError(client, targetCount);
        return Plugin_Handled;
    }

    for (int i = 0; i < targetCount; i++)
    {
        Filters_ApplyAdminTargetAction(client, targetList[i], action);
    }

    ShowActivity2(client, "[Kogasa] ", activity, targetName);
    return Plugin_Handled;
}

static Action Filters_RunStatusListCommand(int client, FilterStatusList status)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, FILTERS_ACCESS_DENIED);
        return Plugin_Handled;
    }

    Filters_PrintStatusList(client, status);
    return Plugin_Handled;
}

static Action Filters_RunFiltersHelpCommand(int client)
{
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    if (!Filters_CanUseHelpCommand(client))
    {
        CPrintToChat(client, FILTERS_ACCESS_DENIED);
        return Plugin_Handled;
    }

    Filters_PrintHelp(client);
    return Plugin_Handled;
}

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

    char messageColorTag[16];
    BuildMessageColorTag(client, messageColorTag, sizeof(messageColorTag));

    char displayName[384];
    BuildChatDisplayName(client, displayName, sizeof(displayName));

    char output[256];
    Format(output, sizeof(output), "%s%s%s%s : %s", messageColorTag, dead, displayName, messageColorTag, sArgs);

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
    Filters_RefreshAdminDbStatus(client);
    context.pluginEnabled = GetConVarInt(g_sEnabled) != 0;
    context.cordMode = Filters_IsCordModeEnabled();
    context.isBlacklisted = g_PlayerState[client].isBlacklisted;
    context.isWhitelisted = g_PlayerState[client].isWhitelisted;
    context.isFilterWhitelisted = g_PlayerState[client].isFilterWhitelisted;
    context.hasBlacklistedTerm = CheckBlacklistedTerms(sArgs);
    context.isGagged = Filters_IsClientGagged(client);
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
    if (!Kogasa_GetClientSteam2(client, steamId, sizeof(steamId), true))
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
    bool americaCommand = StrEqual(commandToken, "!america", false) || StrEqual(commandToken, "/america", false);
    bool mapCommand = StrEqual(commandToken, "!mapflag", false) || StrEqual(commandToken, "/mapflag", false);
    bool transCommand = StrEqual(commandToken, "!trans", false) || StrEqual(commandToken, "/trans", false);
    bool rainbowCommand = StrEqual(commandToken, "!rainbow", false) || StrEqual(commandToken, "/rainbow", false);
    bool gradientCommand = StrEqual(commandToken, "!gradient", false) || StrEqual(commandToken, "/gradient", false)
        || StrEqual(commandToken, "!hue", false) || StrEqual(commandToken, "/hue", false);

    if (!americaCommand
        && !mapCommand
        && !transCommand
        && !rainbowCommand
        && !gradientCommand
        && !StrEqual(commandToken, "!name", false)
        && !StrEqual(commandToken, "/name", false)
        && !StrEqual(commandToken, "!color", false)
        && !StrEqual(commandToken, "/color", false))
    {
        return false;
    }

    if (gradientCommand)
    {
        return HandleGradientNameCommand(client, buffer, nextIndex);
    }

    if (americaCommand)
    {
        return HandlePresetNamePatternCommand(client, NAME_COLOR_AMERICA, AMERICA_NAME_ACCESS_ITEM, "America Flag Name Color", "america");
    }

    if (mapCommand)
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_MAP, MAP_NAME_ACCESS_ITEM, "MAP Flag Name Color", "map");
    }

    if (transCommand)
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_TRANS, TRANS_NAME_ACCESS_ITEM, "Trans Name Color", "trans");
    }

    if (rainbowCommand)
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_RAINBOW, RAINBOW_NAME_ACCESS_ITEM, "Rainbow Name Color", "rainbow");
    }

    if (nextIndex == -1 || !buffer[nextIndex])
    {
        PrintCurrentNamePreference(client);
        return true;
    }

    char colorName[32];
    strcopy(colorName, sizeof(colorName), buffer[nextIndex]);
    TrimString(colorName);

    if (!colorName[0])
    {
        PrintCurrentNamePreference(client);
        return true;
    }

    ToLowercase(colorName);

    if (StrEqual(colorName, "default", false) || StrEqual(colorName, "team", false) || StrEqual(colorName, "teamcolor", false))
    {
        if (!g_NameColors[client][0] && !HasValidNamePattern(client))
        {
            CPrintToChat(client, "{default}[Filters] Your name color already uses the {teamcolor}team color{default}.");
            return true;
        }

        ResetNamePreferences(client);
        CPrintToChat(client, "{default}[Filters] Your name color has been reset to the {teamcolor}team color{default}.");
        return true;
    }

    if (IsAmericaNamePattern(colorName))
    {
        return HandlePresetNamePatternCommand(client, NAME_COLOR_AMERICA, AMERICA_NAME_ACCESS_ITEM, "America Flag Name Color", "america");
    }

    if (IsMapNamePattern(colorName))
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_MAP, MAP_NAME_ACCESS_ITEM, "MAP Flag Name Color", "map");
    }

    if (IsTransNamePattern(colorName))
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_TRANS, TRANS_NAME_ACCESS_ITEM, "Trans Name Color", "trans");
    }

    if (IsRainbowNamePattern(colorName))
    {
        return HandlePresetNamePatternCommand(client, NAME_PATTERN_RAINBOW, RAINBOW_NAME_ACCESS_ITEM, "Rainbow Name Color", "rainbow");
    }

    if (!CColorExists(colorName))
    {
        CPrintToChat(client, "{default}[Filters] Unknown color \"%s\". Example: !name deeppink, !america, !mapflag, !trans, !rainbow, or !gradient blue red", colorName);
        return true;
    }

    if (StrEqual(g_NameColors[client], colorName, false))
    {
        CPrintToChat(client, "{default}[Filters] Your name color is already {%s}%s{default}.", g_NameColors[client], g_NameColors[client]);
        return true;
    }

    SetNameColorPreference(client, colorName);

    CPrintToChat(client, "{default}[Filters] Your name color is now {%s}%s{default}.", colorName, colorName);
    return true;
}

static void PrintCurrentNamePreference(int client)
{
    if (HasValidNamePattern(client))
    {
        char renderedName[256];
        BuildRenderedClientName(client, renderedName, sizeof(renderedName));
        CPrintToChat(client,
            "{default}[Filters] Your name color is currently %s. Use !name <color>, !america, !mapflag, !trans, !rainbow, !gradient <color1> <color2>, or !name default.",
            renderedName);
    }
    else if (g_NameColors[client][0] != '\0')
    {
        CPrintToChat(client,
            "{default}[Filters] Your name color is currently {%s}%s{default}. Use !name <color>, !america, !mapflag, !trans, !rainbow, !gradient <color1> <color2>, or !name default.",
            g_NameColors[client],
            g_NameColors[client]);
    }
    else
    {
        CPrintToChat(client,
            "{default}[Filters] Your name color uses the {teamcolor}team color{default}. Use !name <color>, !america, !mapflag, !trans, !rainbow, or !gradient <color1> <color2> to change it.");
    }
}

static bool ClientHasNamePatternAccess(int client, const char[] itemKey, const char[] itemName)
{
    if (GetFeatureStatus(FeatureType_Native, "PointsStore_HasPurchase") != FeatureStatus_Available)
    {
        CPrintToChat(client, "{default}[Filters] Name pattern purchases are temporarily unavailable.");
        return false;
    }

    if (!PointsStore_HasPurchase(client, itemKey))
    {
        CPrintToChat(client,
            "{default}[Filters] Purchase {gold}%s{default} from {gold}!shop{default} before using this name pattern.",
            itemName);
        return false;
    }

    return true;
}

static bool HandlePresetNamePatternCommand(int client, const char[] pattern, const char[] itemKey, const char[] itemName, const char[] patternName)
{
    if (StrEqual(g_NamePatterns[client], pattern, false))
    {
        ClearNamePatternPreference(client);
        CPrintToChat(client, "{default}[Filters] Your %s name pattern has been disabled.", patternName);
        return true;
    }

    if (!ClientHasNamePatternAccess(client, itemKey, itemName))
    {
        return true;
    }

    SetNamePatternPreference(client, pattern);

    char renderedName[256];
    BuildRenderedClientName(client, renderedName, sizeof(renderedName));
    CPrintToChat(client, "{default}[Filters] Your name color is now %s.", renderedName);
    return true;
}

static int ParseGradientCommandColors(
    const char[] command,
    int argumentsIndex,
    char[] firstColor,
    int firstLen,
    char[] secondColor,
    int secondLen,
    char[] thirdColor,
    int thirdLen)
{
    firstColor[0] = '\0';
    secondColor[0] = '\0';
    thirdColor[0] = '\0';
    if (argumentsIndex == -1 || !command[argumentsIndex])
    {
        return 0;
    }

    char arguments[128];
    strcopy(arguments, sizeof(arguments), command[argumentsIndex]);
    TrimString(arguments);
    int secondIndex = BreakString(arguments, firstColor, firstLen);
    if (secondIndex == -1 || !arguments[secondIndex])
    {
        return 0;
    }

    char remaining[96];
    strcopy(remaining, sizeof(remaining), arguments[secondIndex]);
    TrimString(remaining);
    int extraIndex = BreakString(remaining, secondColor, secondLen);
    if (extraIndex != -1 && remaining[extraIndex])
    {
        char trailing[64];
        strcopy(trailing, sizeof(trailing), remaining[extraIndex]);
        TrimString(trailing);
        int fourthIndex = BreakString(trailing, thirdColor, thirdLen);
        if (fourthIndex != -1 && trailing[fourthIndex])
        {
            return 0;
        }
    }

    TrimString(firstColor);
    TrimString(secondColor);
    TrimString(thirdColor);
    ToLowercase(firstColor);
    ToLowercase(secondColor);
    ToLowercase(thirdColor);
    if (!firstColor[0] || !secondColor[0])
    {
        return 0;
    }
    return thirdColor[0] ? 3 : 2;
}

static bool HandleGradientNameCommand(int client, const char[] command, int argumentsIndex)
{
    if (!ClientHasNamePatternAccess(client, GRADIENT_NAME_ACCESS_ITEM, "Gradient Color Name Access"))
    {
        return true;
    }

    char firstColor[32];
    char secondColor[32];
    char thirdColor[32];
    int colorCount = ParseGradientCommandColors(
        command,
        argumentsIndex,
        firstColor,
        sizeof(firstColor),
        secondColor,
        sizeof(secondColor),
        thirdColor,
        sizeof(thirdColor));
    if (colorCount == 0)
    {
        CPrintToChat(client,
            "{default}[Filters] Usage: {gold}!gradient <color1> <color2> [color3]{default}. Use {gold}!colors{default} to list colors.");
        return true;
    }

    if (colorCount == 3
        && !ClientHasNamePatternAccess(client, TRIPLE_GRADIENT_ACCESS_ITEM, "Triple Gradient Upgrade"))
    {
        return true;
    }

    if (!CColorExists(firstColor))
    {
        CPrintToChat(client, "{default}[Filters] Unknown color \"%s\". Use {gold}!colors{default} to list colors.", firstColor);
        return true;
    }
    if (!CColorExists(secondColor))
    {
        CPrintToChat(client, "{default}[Filters] Unknown color \"%s\". Use {gold}!colors{default} to list colors.", secondColor);
        return true;
    }
    if (colorCount == 3 && !CColorExists(thirdColor))
    {
        CPrintToChat(client, "{default}[Filters] Unknown color \"%s\". Use {gold}!colors{default} to list colors.", thirdColor);
        return true;
    }

    char pattern[NAME_PATTERN_MAX];
    if (colorCount == 3)
    {
        FormatEx(pattern, sizeof(pattern), "%s%s:%s:%s", NAME_PATTERN_TRIPLE_GRADIENT_PREFIX, firstColor, secondColor, thirdColor);
    }
    else
    {
        FormatEx(pattern, sizeof(pattern), "%s%s:%s:%d", NAME_PATTERN_GRADIENT_PREFIX, firstColor, secondColor, NAME_GRADIENT_DEFAULT_COMPLETION);
    }
    if (StrEqual(g_NamePatterns[client], pattern, false))
    {
        CPrintToChat(client, "{default}[Filters] Your name already uses that gradient.");
        return true;
    }

    SetNamePatternPreference(client, pattern);
    char renderedName[256];
    BuildRenderedClientName(client, renderedName, sizeof(renderedName));
    CPrintToChat(client, "{default}[Filters] Your name gradient is now %s.", renderedName);
    return true;
}

public Action Command_GradientMenu(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }
    if (!ClientHasNamePatternAccess(client, GRADIENT_NAME_ACCESS_ITEM, "Gradient Color Name Access"))
    {
        return Plugin_Handled;
    }
    if (IsTripleGradientNamePattern(g_NamePatterns[client]))
    {
        CPrintToChat(client, "{default}[Filters] Gradient Control only adjusts two-color gradients.");
        return Plugin_Handled;
    }

    char firstColor[32];
    char secondColor[32];
    int completionPercent;
    if (!ParseGradientNamePattern(
        g_NamePatterns[client],
        firstColor,
        sizeof(firstColor),
        secondColor,
        sizeof(secondColor),
        completionPercent))
    {
        CPrintToChat(client, "{default}[Filters] Use {gold}!gradient <color1> <color2>{default} before opening Gradient Control.");
        return Plugin_Handled;
    }

    ShowGradientControlMenu(client, completionPercent);
    return Plugin_Handled;
}

static void ShowGradientControlMenu(int client, int completionPercent)
{
    Menu menu = new Menu(MenuHandler_GradientControl);
    menu.SetTitle("Gradient Control");

    int positionCount = GetGradientControlPositionCount();
    menu.AddItem("left", "Adjust Left", completionPercent > GetGradientControlPercent(0) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.AddItem("right", "Adjust Right", completionPercent < GetGradientControlPercent(positionCount - 1) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

    char percentage[16];
    FormatEx(percentage, sizeof(percentage), "%d%%", completionPercent);
    menu.AddItem("percentage", percentage, ITEMDRAW_DISABLED);
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_GradientControl(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select || client <= 0 || !IsClientInGame(client))
    {
        return 0;
    }

    char direction[16];
    menu.GetItem(item, direction, sizeof(direction));

    char firstColor[32];
    char secondColor[32];
    int completionPercent;
    if (!ParseGradientNamePattern(
        g_NamePatterns[client],
        firstColor,
        sizeof(firstColor),
        secondColor,
        sizeof(secondColor),
        completionPercent))
    {
        CPrintToChat(client, "{default}[Filters] Your active name pattern is no longer a gradient.");
        return 0;
    }

    if (StrEqual(direction, "left", false))
    {
        completionPercent = GetAdjacentGradientControlPercent(completionPercent, false);
    }
    else if (StrEqual(direction, "right", false))
    {
        completionPercent = GetAdjacentGradientControlPercent(completionPercent, true);
    }

    char pattern[NAME_PATTERN_MAX];
    FormatEx(pattern, sizeof(pattern), "%s%s:%s:%d", NAME_PATTERN_GRADIENT_PREFIX, firstColor, secondColor, completionPercent);
    SetNamePatternPreference(client, pattern);
    ShowGradientControlMenu(client, completionPercent);
    return 0;
}

static int GetGradientControlSlotCount()
{
    int count = 0;
    for (int slot = 1; slot <= NAME_GRADIENT_MAX_STEPS; slot++)
    {
        int percent = RoundToNearest(float(slot) * 100.0 / float(NAME_GRADIENT_MAX_STEPS));
        if (percent > NAME_GRADIENT_MAX_COMPLETION)
        {
            break;
        }
        count++;
    }
    return count;
}

static int GetGradientControlPositionCount()
{
    int slotCount = GetGradientControlSlotCount();
    return GetGradientControlPercent(slotCount - 1) < NAME_GRADIENT_MAX_COMPLETION ? slotCount + 1 : slotCount;
}

static int GetGradientControlPercent(int position)
{
    int slotCount = GetGradientControlSlotCount();
    if (position >= slotCount)
    {
        return NAME_GRADIENT_MAX_COMPLETION;
    }
    if (position < 0)
    {
        position = 0;
    }
    return RoundToNearest(float(position + 1) * 100.0 / float(NAME_GRADIENT_MAX_STEPS));
}

static int GetAdjacentGradientControlPercent(int completionPercent, bool moveRight)
{
    int positionCount = GetGradientControlPositionCount();
    if (moveRight)
    {
        for (int position = 0; position < positionCount; position++)
        {
            int candidate = GetGradientControlPercent(position);
            if (candidate > completionPercent)
            {
                return candidate;
            }
        }
        return GetGradientControlPercent(positionCount - 1);
    }

    for (int position = positionCount - 1; position >= 0; position--)
    {
        int candidate = GetGradientControlPercent(position);
        if (candidate < completionPercent)
        {
            return candidate;
        }
    }
    return GetGradientControlPercent(0);
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
    CPrintToChat(client, "{default}[Filters] filtermode - 0=off, 1=quarantine with mutual whitelist/blacklist visibility, 2=quarantine with whitelist monitoring only.");
    CPrintToChat(client, "{default}[Filters] filters_chat_debug - Enable verbose debug logging for chat relay.");
    CPrintToChat(client, "{default}[Filters] filters_chat_frontend - Enable/Disable reading frontend chat from the database.");
    CPrintToChat(client, "{default}[Filters] filters_filters - If 0, blacklist word matching is disabled.");
    CPrintToChat(client, "{default}[Filters] filters_blacklist_minlen - Minimum message length to check blacklist words.");
    CPrintToChat(client, "{default}[Filters] filters_christmas - If 1, red chat is {axis} and blue chat is {green}.");
    CPrintToChat(client, "{default}[Filters] teamchat - If 1, normal chat is sent to the sender's team only.");
    CPrintToChat(client, "{default}[Filters] sm_pchat - If 0, filtered/monitored chat is only printed to server console instead of whitelisted clients.");
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
        CPrintToChat(client, FILTERS_ACCESS_DENIED);
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

    bool listredlist = StrEqual(commandToken, "/redlists", false);

    if (!listredlist)
    {
        return false;
    }

    if (!Filters_CanUseListCommand(client))
    {
        CPrintToChat(client, FILTERS_ACCESS_DENIED);
        return true;
    }

    Filters_PrintStatusList(client, FilterStatus_redlist);
    return true;
}

bool TryHandleTeamChat(int client, const char[] command, const char[] sArgs, const char[] deadPrefix)
{
    if (!StrEqual(command, "say_team"))
    {
        return false;
    }

    Filters_RefreshAdminDbStatus(client);

    char tag[16];
    BuildTeamTag(GetClientTeam(client), tag, sizeof(tag));

    char messageColorTag[16];
    BuildMessageColorTag(client, messageColorTag, sizeof(messageColorTag));

    char displayName[384];
    BuildChatDisplayName(client, displayName, sizeof(displayName));

    char output[256];
    Format(output, sizeof(output), "%s%s%s %s%s : %s", messageColorTag, deadPrefix, tag, displayName, messageColorTag, sArgs);
    if (Filters_IsClientGagged(client))
    {
        CPrintToChatEx(client, client, "%s", output);
        PrintToServer("x: %s", output);
        SendToWhitelistedAdmins(client, output, "x:");
        return true;
    }

    int filterMode = Filters_GetFilterMode();
    bool cordMode = filterMode != 0;
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

            if (Filters_CordModeWhitelistedCanReceiveBlacklisted())
            {
                SendToWhitelistedAdminsBlacklisted(client, output, "fm1:");
            }
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
                if (!isBlacklisted || isWhitelisted || (g_PlayerState[client].isWhitelisted && Filters_CordModeBlacklistedCanReceiveWhitelisted()))
                {
                    Filters_SendChatToReceiver(i, client, output);
                }
            }
            else if (Filters_CanSeeEnemyTeamChat(i))
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
            else if (Filters_CanSeeEnemyTeamChat(i))
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

static bool Filters_FindClientBySteamId64(const char[] steamId, int &client)
{
    client = Kogasa_FindClientBySteamId64(steamId, true);
    return client > 0;
}

static bool Filters_GetClientColorToken(int client, char[] colorTag, int maxlen)
{
    colorTag[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    char formattedTag[40];
    BuildNameColorTag(client, formattedTag, sizeof(formattedTag));
    TrimString(formattedTag);
    if (!formattedTag[0])
    {
        return false;
    }

    int length = strlen(formattedTag);
    if (length >= 3 && formattedTag[0] == '{' && formattedTag[length - 1] == '}')
    {
        formattedTag[length - 1] = '\0';
        strcopy(colorTag, maxlen, formattedTag[1]);
        return (colorTag[0] != '\0');
    }

    strcopy(colorTag, maxlen, formattedTag);
    return (colorTag[0] != '\0');
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

static bool IsAmericaNamePattern(const char[] pattern)
{
    return StrEqual(pattern, NAME_COLOR_AMERICA, false);
}

static bool IsMapNamePattern(const char[] pattern)
{
    return StrEqual(pattern, NAME_PATTERN_MAP, false);
}

static bool IsTransNamePattern(const char[] pattern)
{
    return StrEqual(pattern, NAME_PATTERN_TRANS, false);
}

static bool IsRainbowNamePattern(const char[] pattern)
{
    return StrEqual(pattern, NAME_PATTERN_RAINBOW, false);
}

static bool ParseGradientNamePattern(
    const char[] pattern,
    char[] firstColor,
    int firstLen,
    char[] secondColor,
    int secondLen,
    int &completionPercent)
{
    firstColor[0] = '\0';
    secondColor[0] = '\0';
    completionPercent = NAME_GRADIENT_DEFAULT_COMPLETION;
    if (StrContains(pattern, NAME_PATTERN_GRADIENT_PREFIX, false) != 0)
    {
        return false;
    }

    char colors[NAME_PATTERN_MAX];
    strcopy(colors, sizeof(colors), pattern[strlen(NAME_PATTERN_GRADIENT_PREFIX)]);
    int separator = FindCharInString(colors, ':');
    if (separator <= 0 || !colors[separator + 1])
    {
        return false;
    }

    colors[separator] = '\0';
    strcopy(firstColor, firstLen, colors);

    char remainder[NAME_PATTERN_MAX];
    strcopy(remainder, sizeof(remainder), colors[separator + 1]);
    int percentageSeparator = FindCharInString(remainder, ':');
    if (percentageSeparator == -1)
    {
        strcopy(secondColor, secondLen, remainder);
    }
    else
    {
        remainder[percentageSeparator] = '\0';
        strcopy(secondColor, secondLen, remainder);

        char percentageText[8];
        strcopy(percentageText, sizeof(percentageText), remainder[percentageSeparator + 1]);
        int parsedLength = StringToIntEx(percentageText, completionPercent);
        if (parsedLength <= 0
            || percentageText[parsedLength] != '\0'
            || completionPercent <= 0
            || completionPercent > NAME_GRADIENT_MAX_COMPLETION)
        {
            return false;
        }
    }
    TrimString(firstColor);
    TrimString(secondColor);
    ToLowercase(firstColor);
    ToLowercase(secondColor);
    return firstColor[0] != '\0'
        && secondColor[0] != '\0'
        && CColorExists(firstColor)
        && CColorExists(secondColor);
}

static bool IsGradientNamePattern(const char[] pattern)
{
    char firstColor[32];
    char secondColor[32];
    int completionPercent;
    return ParseGradientNamePattern(pattern, firstColor, sizeof(firstColor), secondColor, sizeof(secondColor), completionPercent);
}

static bool ParseTripleGradientNamePattern(
    const char[] pattern,
    char[] firstColor,
    int firstLen,
    char[] secondColor,
    int secondLen,
    char[] thirdColor,
    int thirdLen)
{
    firstColor[0] = '\0';
    secondColor[0] = '\0';
    thirdColor[0] = '\0';
    if (StrContains(pattern, NAME_PATTERN_TRIPLE_GRADIENT_PREFIX, false) != 0)
    {
        return false;
    }

    char colors[3][32];
    int count = ExplodeString(
        pattern[strlen(NAME_PATTERN_TRIPLE_GRADIENT_PREFIX)],
        ":",
        colors,
        sizeof(colors),
        sizeof(colors[]));
    if (count != 3)
    {
        return false;
    }

    for (int i = 0; i < sizeof(colors); i++)
    {
        TrimString(colors[i]);
        ToLowercase(colors[i]);
        if (!colors[i][0] || !CColorExists(colors[i]))
        {
            return false;
        }
    }

    strcopy(firstColor, firstLen, colors[0]);
    strcopy(secondColor, secondLen, colors[1]);
    strcopy(thirdColor, thirdLen, colors[2]);
    return true;
}

static bool IsTripleGradientNamePattern(const char[] pattern)
{
    char firstColor[32];
    char secondColor[32];
    char thirdColor[32];
    return ParseTripleGradientNamePattern(
        pattern,
        firstColor,
        sizeof(firstColor),
        secondColor,
        sizeof(secondColor),
        thirdColor,
        sizeof(thirdColor));
}

static bool IsValidNamePattern(const char[] pattern)
{
    return IsAmericaNamePattern(pattern)
        || IsMapNamePattern(pattern)
        || IsTransNamePattern(pattern)
        || IsRainbowNamePattern(pattern)
        || IsGradientNamePattern(pattern)
        || IsTripleGradientNamePattern(pattern);
}

static bool HasValidNamePattern(int client)
{
    return IsValidNamePattern(g_NamePatterns[client]);
}

static bool GetActiveNamePattern(int client, char[] pattern, int maxlen)
{
    pattern[0] = '\0';

    if (!HasValidNamePattern(client))
    {
        return false;
    }

    strcopy(pattern, maxlen, g_NamePatterns[client]);
    return true;
}

static bool GetNamedColorRgb(const char[] colorName, int &rgb)
{
    CCheckTrie();
    return GetTrieValue(CTrie, colorName, rgb);
}

static void BuildGradientName(
    const char[] name,
    const char[] firstColor,
    const char[] secondColor,
    int completionPercent,
    char[] output,
    int maxlen)
{
    output[0] = '\0';

    int firstRgb;
    int secondRgb;
    if (!GetNamedColorRgb(firstColor, firstRgb) || !GetNamedColorRgb(secondColor, secondRgb))
    {
        strcopy(output, maxlen, name);
        return;
    }

    int charCount = CountUtf8Chars(name);
    if (charCount <= 0)
    {
        strcopy(output, maxlen, "{default}");
        return;
    }

    int firstRed = (firstRgb >> 16) & 0xFF;
    int firstGreen = (firstRgb >> 8) & 0xFF;
    int firstBlue = firstRgb & 0xFF;
    int secondRed = (secondRgb >> 16) & 0xFF;
    int secondGreen = (secondRgb >> 8) & 0xFF;
    int secondBlue = secondRgb & 0xFF;
    int stepCount = charCount < NAME_GRADIENT_MAX_STEPS ? charCount : NAME_GRADIENT_MAX_STEPS;
    int denominator = stepCount > 1 ? stepCount - 1 : 1;
    int completionIndex = charCount > 1
        ? RoundToCeil(float(charCount - 1) * float(completionPercent) / 100.0)
        : 1;
    int currentStep = -1;
    int charIndex = 0;
    int byteIndex = 0;

    while (name[byteIndex] != '\0')
    {
        int step = charCount > 1 ? charIndex * (stepCount - 1) / completionIndex : 0;
        if (step >= stepCount)
        {
            step = stepCount - 1;
        }
        if (step != currentStep)
        {
            int red = (firstRed * (denominator - step) + secondRed * step + denominator / 2) / denominator;
            int green = (firstGreen * (denominator - step) + secondGreen * step + denominator / 2) / denominator;
            int blue = (firstBlue * (denominator - step) + secondBlue * step + denominator / 2) / denominator;
            int rgb = (red << 16) | (green << 8) | blue;

            char colorCode[8];
            FormatEx(colorCode, sizeof(colorCode), "\x07%06X", rgb);
            StrCat(output, maxlen, colorCode);
            currentStep = step;
        }

        int charBytes = IsCharMB(name[byteIndex]);
        if (charBytes <= 0)
        {
            charBytes = 1;
        }

        char glyph[8];
        int copyLen = charBytes;
        if (copyLen > sizeof(glyph) - 1)
        {
            copyLen = sizeof(glyph) - 1;
        }
        for (int i = 0; i < copyLen; i++)
        {
            glyph[i] = name[byteIndex + i];
        }
        glyph[copyLen] = '\0';
        StrCat(output, maxlen, glyph);

        byteIndex += charBytes;
        charIndex++;
    }

    StrCat(output, maxlen, "\x01");
}

static void BuildTripleGradientName(
    const char[] name,
    const char[] firstColor,
    const char[] secondColor,
    const char[] thirdColor,
    char[] output,
    int maxlen)
{
    output[0] = '\0';

    int rgbStops[3];
    if (!GetNamedColorRgb(firstColor, rgbStops[0])
        || !GetNamedColorRgb(secondColor, rgbStops[1])
        || !GetNamedColorRgb(thirdColor, rgbStops[2]))
    {
        strcopy(output, maxlen, name);
        return;
    }

    int charCount = CountUtf8Chars(name);
    if (charCount <= 0)
    {
        strcopy(output, maxlen, "{default}");
        return;
    }

    int stepCount = charCount < NAME_GRADIENT_MAX_STEPS ? charCount : NAME_GRADIENT_MAX_STEPS;
    int denominator = stepCount > 1 ? stepCount - 1 : 1;
    int currentStep = -1;
    int charIndex = 0;
    int byteIndex = 0;

    while (name[byteIndex] != '\0')
    {
        int step = charCount > 1 ? charIndex * (stepCount - 1) / (charCount - 1) : 0;
        if (step != currentStep)
        {
            int scaledStep = step * 2;
            int firstStop = scaledStep <= denominator ? 0 : 1;
            int secondStop = firstStop + 1;
            int blend = firstStop == 0 ? scaledStep : scaledStep - denominator;
            int fromRgb = rgbStops[firstStop];
            int toRgb = rgbStops[secondStop];
            int red = ((((fromRgb >> 16) & 0xFF) * (denominator - blend))
                + (((toRgb >> 16) & 0xFF) * blend) + denominator / 2) / denominator;
            int green = ((((fromRgb >> 8) & 0xFF) * (denominator - blend))
                + (((toRgb >> 8) & 0xFF) * blend) + denominator / 2) / denominator;
            int blue = (((fromRgb & 0xFF) * (denominator - blend))
                + ((toRgb & 0xFF) * blend) + denominator / 2) / denominator;
            AppendRgbColorCode((red << 16) | (green << 8) | blue, output, maxlen);
            currentStep = step;
        }

        int charBytes = IsCharMB(name[byteIndex]);
        if (charBytes <= 0)
        {
            charBytes = 1;
        }
        char glyph[8];
        int copyLen = charBytes < sizeof(glyph) ? charBytes : sizeof(glyph) - 1;
        for (int i = 0; i < copyLen; i++)
        {
            glyph[i] = name[byteIndex + i];
        }
        glyph[copyLen] = '\0';
        StrCat(output, maxlen, glyph);
        byteIndex += charBytes;
        charIndex++;
    }

    StrCat(output, maxlen, "\x01");
}

static void SetNameColorPreference(int client, const char[] color)
{
    strcopy(g_NameColors[client], sizeof(g_NameColors[]), color);
    g_NamePatterns[client][0] = '\0';
    SaveNamePreferencesToDb(client);
}

static void SetNamePatternPreference(int client, const char[] pattern)
{
    strcopy(g_NamePatterns[client], sizeof(g_NamePatterns[]), pattern);
    SaveNamePreferencesToDb(client);
}

static void ClearNamePatternPreference(int client)
{
    g_NamePatterns[client][0] = '\0';
    SaveNamePreferencesToDb(client);
}

static void ResetNamePreferences(int client)
{
    g_NamePatterns[client][0] = '\0';
    g_NameColors[client][0] = '\0';
    SaveNamePreferencesToDb(client);
}

static int CountUtf8Chars(const char[] text)
{
    int count = 0;
    int index = 0;

    while (text[index] != '\0')
    {
        int charBytes = IsCharMB(text[index]);
        if (charBytes <= 0)
        {
            charBytes = 1;
        }

        index += charBytes;
        count++;
    }

    return count;
}

static void AppendRgbColorCode(int rgb, char[] output, int maxlen)
{
    char colorCode[8];
    FormatEx(colorCode, sizeof(colorCode), "\x07%06X", rgb);
    StrCat(output, maxlen, colorCode);
}

static void BuildPaletteName(const char[] name, const int[] colors, int colorCount, char[] output, int maxlen)
{
    output[0] = '\0';

    int charCount = CountUtf8Chars(name);
    if (charCount <= 0 || colorCount <= 0)
    {
        strcopy(output, maxlen, "\x01");
        return;
    }

    int currentSegment = -1;
    int charIndex = 0;
    int byteIndex = 0;

    while (name[byteIndex] != '\0')
    {
        int segment = (charIndex * colorCount) / charCount;
        segment = segment < colorCount ? segment : colorCount - 1;

        if (segment != currentSegment)
        {
            AppendRgbColorCode(colors[segment], output, maxlen);
            currentSegment = segment;
        }

        int charBytes = IsCharMB(name[byteIndex]);
        if (charBytes <= 0)
        {
            charBytes = 1;
        }

        char glyph[8];
        int copyLen = charBytes;
        if (copyLen > sizeof(glyph) - 1)
        {
            copyLen = sizeof(glyph) - 1;
        }

        for (int i = 0; i < copyLen; i++)
        {
            glyph[i] = name[byteIndex + i];
        }
        glyph[copyLen] = '\0';
        StrCat(output, maxlen, glyph);

        byteIndex += charBytes;
        charIndex++;
    }

    StrCat(output, maxlen, "\x01");
}

static void BuildAmericaName(const char[] name, char[] output, int maxlen)
{
    int colors[] = {
        0xFFFFFF, 0x1E90FF, 0xFFFFFF, 0x1E90FF, 0xFFFFFF, 0x1E90FF,
        0xFF4040, 0xFF4040, 0xFFFFFF, 0xFFFFFF, 0xFF4040, 0xFF4040
    };
    BuildPaletteName(name, colors, sizeof(colors), output, maxlen);
}

static void BuildMapName(const char[] name, char[] output, int maxlen)
{
    int colors[] = {0x6495ED, 0x99CCFF, 0xFFFF5E, 0xFFFFFF, 0xFFFF5E, 0xFFC0CB, 0xFF69B4};
    BuildPaletteName(name, colors, sizeof(colors), output, maxlen);
}

static void BuildTransName(const char[] name, char[] output, int maxlen)
{
    int colors[] = {0x5BCEFA, 0xFFFFFF, 0xF5A9B8};
    BuildPaletteName(name, colors, sizeof(colors), output, maxlen);
}

static void BuildRainbowName(const char[] name, char[] output, int maxlen)
{
    int colors[] = {0xFF4040, 0xFFA500, 0xFFFF00, 0x3EFF3E, 0x99CCFF, 0x9370D8, 0xEE82EE};
    BuildPaletteName(name, colors, sizeof(colors), output, maxlen);
}

static void BuildRenderedClientName(int client, char[] output, int maxlen)
{
    output[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    char pattern[NAME_PATTERN_MAX];
    if (GetActiveNamePattern(client, pattern, sizeof(pattern)))
    {
        if (IsAmericaNamePattern(pattern))
        {
            BuildAmericaName(name, output, maxlen);
            return;
        }
        if (IsMapNamePattern(pattern))
        {
            BuildMapName(name, output, maxlen);
            return;
        }
        if (IsTransNamePattern(pattern))
        {
            BuildTransName(name, output, maxlen);
            return;
        }
        if (IsRainbowNamePattern(pattern))
        {
            BuildRainbowName(name, output, maxlen);
            return;
        }

        char firstColor[32];
        char secondColor[32];
        char thirdColor[32];
        if (ParseTripleGradientNamePattern(
            pattern,
            firstColor,
            sizeof(firstColor),
            secondColor,
            sizeof(secondColor),
            thirdColor,
            sizeof(thirdColor)))
        {
            BuildTripleGradientName(name, firstColor, secondColor, thirdColor, output, maxlen);
            return;
        }

        int completionPercent;
        if (ParseGradientNamePattern(pattern, firstColor, sizeof(firstColor), secondColor, sizeof(secondColor), completionPercent))
        {
            BuildGradientName(name, firstColor, secondColor, completionPercent, output, maxlen);
            return;
        }
    }

    BuildColorOnlyClientName(client, output, maxlen);
}

static void BuildChatPrefix(int client, char[] output, int maxlen)
{
    output[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Tags_GetSelectedTag") != FeatureStatus_Available)
    {
        return;
    }

    if (!Tags_GetSelectedTag(client, output, maxlen) || !output[0])
    {
        output[0] = '\0';
    }
}

static void BuildDisplayChatPrefix(int client, char[] output, int maxlen)
{
    output[0] = '\0';

    char rawPrefix[CHAT_PREFIX_MAXLEN];
    BuildChatPrefix(client, rawPrefix, sizeof(rawPrefix));
    if (!rawPrefix[0])
    {
        return;
    }

    if (rawPrefix[0] == '[')
    {
        strcopy(output, maxlen, rawPrefix);
        return;
    }

    Format(output, maxlen, "[{gold}%s{default}]", rawPrefix);
}

static void BuildColorOnlyClientName(int client, char[] output, int maxlen)
{
    output[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    char colorTag[40];
    BuildNameColorTag(client, colorTag, sizeof(colorTag));
    Format(output, maxlen, "%s%s{default}", colorTag, name);
}

static void BuildChatDisplayName(int client, char[] output, int maxlen)
{
    output[0] = '\0';

    char chatPrefix[CHAT_PREFIX_MAXLEN];
    BuildDisplayChatPrefix(client, chatPrefix, sizeof(chatPrefix));

    char renderedName[256];
    BuildRenderedClientName(client, renderedName, sizeof(renderedName));

    if (chatPrefix[0])
    {
        Format(output, maxlen, "%s %s", chatPrefix, renderedName);
        return;
    }

    strcopy(output, maxlen, renderedName);
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
        if (g_PlayerState[receiver].isWhitelisted && Filters_PChatEnabled())
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
    int filterMode = Filters_GetFilterMode();
    bool cordMode = filterMode != 0;
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
            if (g_MuteDeafened[receiver])
            {
                shouldBlock = true;
            }
            else if (redlistEnabled && g_PlayerState[receiver].isredlisted)
            {
                shouldBlock = !g_PlayerState[sender].isredlisted;
            }
            else if (cordMode)
            {
                bool receiverBlacklisted = g_PlayerState[receiver].isBlacklisted;
                bool receiverWhitelisted = g_PlayerState[receiver].isWhitelisted;
                if (receiverBlacklisted)
                {
                    shouldBlock = !senderBlacklisted && !(g_PlayerState[sender].isWhitelisted && Filters_CordModeBlacklistedCanReceiveWhitelisted());
                }
                else
                {
                    shouldBlock = senderBlacklisted && !receiverWhitelisted;
                }
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

    if (Filters_CordModeWhitelistedCanReceiveBlacklisted())
    {
        SendToWhitelistedAdminsBlacklisted(client, message, "fm1:");
    }
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
                else if (Filters_CanSeeEnemyTeamChat(i))
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
            if ((!g_PlayerState[i].isBlacklisted || (context.isWhitelisted && Filters_CordModeBlacklistedCanReceiveWhitelisted()))
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
    char displayName[384];
    BuildChatDisplayName(client, displayName, sizeof(displayName));

    char output[256];
    Format(output, sizeof(output), "%s: {gold}nigger", displayName);
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
        char sanitizedMsg[512];
        char escapedMsg[512];
        char escapedHash[64];
        Filters_SanitizeDbMessage(msgPart, sanitizedMsg, sizeof(sanitizedMsg));
        Db_Escape(g_hFiltersDb, sanitizedMsg, escapedMsg, sizeof(escapedMsg), "filters");
        Db_Escape(g_hFiltersDb, hash, escapedHash, sizeof(escapedHash), "filters");
        char query[1024];
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message, alert) VALUES (%d, NULL, NULL, '%s', '%s', 1)",
            GetTime(), escapedHash, escapedMsg);
        g_hFiltersDb.Query(Filters_InsertChatCallback, query);
        Filters_QueueOutboxMessage(GetTime(), hash, "", msgPart, false, true);
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
    if (!Filters_PChatEnabled())
    {
        return;
    }

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
    SendToWhitelistedAdmins(sender, message, prefix);
}

static void Filters_EnsureConfigFile(char[] configPath, int maxlen)
{
    BuildPath(Path_SM, configPath, maxlen, "configs/filters.cfg");

    if (!FileExists(configPath))
    {
        LogMessage("Config file not found, creating default: %s", configPath);
        CreateDefaultConfig(configPath);
    }
}

static bool Filters_BeginConfigSection(KeyValues kv, const char[] sectionName)
{
    if (!kv.JumpToKey(sectionName))
    {
        return false;
    }

    if (!kv.GotoFirstSubKey(false))
    {
        kv.GoBack();
        return false;
    }

    return true;
}

static void Filters_EndConfigSection(KeyValues kv)
{
    kv.GoBack();
    kv.GoBack();
}

static void Filters_ResetLoadedConfig()
{
    g_FilterCount = 0;
    g_CaseInsensitiveFilterCount = 0;
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
}

static void Filters_LoadFilterWords(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "filter_words"))
    {
        return;
    }

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

    Filters_EndConfigSection(kv);
}

static void Filters_LoadCaseInsensitiveFilterWords(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "filters_case_insensitive"))
    {
        return;
    }

    do
    {
        if (g_CaseInsensitiveFilterCount >= MAX_FILTERS)
        {
            LogError("Maximum case-insensitive filter limit reached (%d)", MAX_FILTERS);
            break;
        }

        char original[MAX_WORD_LENGTH];
        char filtered[MAX_WORD_LENGTH];
        kv.GetSectionName(original, sizeof(original));
        kv.GetString(NULL_STRING, filtered, sizeof(filtered));

        strcopy(g_CaseInsensitiveFilterWords[g_CaseInsensitiveFilterCount], MAX_WORD_LENGTH, original);
        strcopy(g_CaseInsensitiveReplacementWords[g_CaseInsensitiveFilterCount], MAX_WORD_LENGTH, filtered);
        g_CaseInsensitiveFilterCount++;
    }
    while (kv.GotoNextKey(false));

    Filters_EndConfigSection(kv);
}

static void Filters_LoadBlacklistWords(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "blacklist_words"))
    {
        return;
    }

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

    Filters_EndConfigSection(kv);
}

static void Filters_LoadBlacklist50Words(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "blacklist_words_50"))
    {
        return;
    }

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

    Filters_EndConfigSection(kv);
}

static bool Filters_IsValidForcedStatusType(const char[] status)
{
    return StrEqual(status, "redlist")
        || StrEqual(status, "filter_whitelist");
}

static void Filters_LoadForcedStatuses(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "force_status"))
    {
        return;
    }

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

        if (Filters_IsValidForcedStatusType(status))
        {
            strcopy(g_ForcedStatusSteamIDs[g_ForcedStatusCount], sizeof(g_ForcedStatusSteamIDs[]), steamid);
            strcopy(g_ForcedStatusTypes[g_ForcedStatusCount], sizeof(g_ForcedStatusTypes[]), status);
            g_ForcedStatusCount++;
        }
        else
        {
            LogError("Invalid status type '%s' for SteamID '%s'", status, steamid);
        }
    }
    while (kv.GotoNextKey(false));

    Filters_EndConfigSection(kv);
}

static void Filters_LoadAllowedCommands(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "commands"))
    {
        return;
    }

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

    Filters_EndConfigSection(kv);
}

static void Filters_LoadWebNameOverrides(KeyValues kv)
{
    if (!Filters_BeginConfigSection(kv, "webnames"))
    {
        return;
    }

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

    Filters_EndConfigSection(kv);
}

void LoadFilterConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    Filters_EnsureConfigFile(configPath, sizeof(configPath));

    KeyValues kv = new KeyValues("filters");
    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to parse config file: %s", configPath);
        delete kv;
        SetFailState("Failed to parse filters.cfg");
        return;
    }

    Filters_ResetLoadedConfig();
    Filters_LoadFilterWords(kv);
    Filters_LoadCaseInsensitiveFilterWords(kv);
    Filters_LoadBlacklistWords(kv);
    Filters_LoadBlacklist50Words(kv);
    Filters_LoadForcedStatuses(kv);
    Filters_LoadAllowedCommands(kv);
    Filters_LoadWebNameOverrides(kv);

    delete kv;

    PrintToServer("[Word Filter] Loaded %d filter words, %d case-insensitive filters, %d blacklist words, %d blacklist_50 words, %d forced status entries, and %d commands",
                  g_FilterCount, g_CaseInsensitiveFilterCount, g_BlacklistCount, g_Blacklist50Count, g_ForcedStatusCount, g_AllowedCommandsCount);
}

public void FilterString(char[] input, int maxlen)
{
    bool caseSensitive = g_hFiltersCaseSensitive == null ? true : g_hFiltersCaseSensitive.BoolValue;

    // Apply word filters
    for (int i = 0; i < g_FilterCount; i++)
    {
        ReplaceString(input, maxlen, g_FilterWords[i], g_ReplacementWords[i], caseSensitive);
    }

    for (int i = 0; i < g_CaseInsensitiveFilterCount; i++)
    {
        ReplaceString(input, maxlen, g_CaseInsensitiveFilterWords[i], g_CaseInsensitiveReplacementWords[i], false);
    }
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
    file.WriteLine("    \"filters_case_insensitive\"");
    file.WriteLine("    {");
    file.WriteLine("        \"bruh\"    \"trans rights\"");
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

void SaveNamePreferencesToDb(int client)
{
    if (!g_bDbReady || g_hFiltersDb == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[32];
    if (!Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true))
    {
        return;
    }

    char escapedSteam[64];
    char escapedColor[64];
    char escapedPattern[(NAME_PATTERN_MAX * 2) + 1];
    Db_Escape(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam), "filters");
    Db_Escape(g_hFiltersDb, g_NameColors[client], escapedColor, sizeof(escapedColor), "filters");
    Db_Escape(g_hFiltersDb, g_NamePatterns[client], escapedPattern, sizeof(escapedPattern), "filters");

    char query[512];
    Format(query, sizeof(query),
        "REPLACE INTO filters_namecolors (steamid, color, pattern, updated_at) VALUES ('%s', '%s', '%s', %d)",
        escapedSteam, escapedColor, escapedPattern, GetTime());
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

void LoadNamePreferencesFromDb(int client)
{
    g_NameColors[client][0] = '\0';
    g_NamePatterns[client][0] = '\0';

    if (!g_bDbReady || g_hFiltersDb == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[32];
    if (!Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true))
    {
        return;
    }

    char escapedSteam[64];
    Db_Escape(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam), "filters");

    char query[256];
    Format(query, sizeof(query), "SELECT color, pattern FROM filters_namecolors WHERE steamid = '%s' LIMIT 1", escapedSteam);
    g_hFiltersDb.Query(Filters_LoadNamePreferencesCallback, query, GetClientUserId(client));
}

public void Filters_LoadNamePreferencesCallback(Database db, DBResultSet results, const char[] error, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[Filters] Failed to load name preferences: %s", error);
        return;
    }

    if (results == null || !results.FetchRow())
    {
        g_NameColors[client][0] = '\0';
        g_NamePatterns[client][0] = '\0';
        return;
    }

    char dbColor[32];
    char dbPattern[NAME_PATTERN_MAX];
    results.FetchString(0, dbColor, sizeof(dbColor));
    results.FetchString(1, dbPattern, sizeof(dbPattern));
    TrimString(dbColor);
    TrimString(dbPattern);
    ToLowercase(dbColor);
    ToLowercase(dbPattern);

    g_NameColors[client][0] = '\0';
    g_NamePatterns[client][0] = '\0';

    bool normalize = false;

    if (dbColor[0])
    {
        if (CColorExists(dbColor))
        {
            strcopy(g_NameColors[client], sizeof(g_NameColors[]), dbColor);
        }
        else
        {
            PrintToServer("[FILTERS] %N had invalid DB name color '%s', resetting to team color", client, dbColor);
            normalize = true;
        }
    }

    if (dbPattern[0])
    {
        if (IsValidNamePattern(dbPattern))
        {
            strcopy(g_NamePatterns[client], sizeof(g_NamePatterns[]), dbPattern);
        }
        else
        {
            PrintToServer("[FILTERS] %N had invalid DB name pattern '%s', clearing it", client, dbPattern);
            normalize = true;
        }
    }

    if (normalize)
    {
        SaveNamePreferencesToDb(client);
    }
}

// Process client cookies on connect/cache
void ProcessCookies(int client)
{
    if (!Filters_IsClientIndex(client) || !AreClientCookiesCached(client))
    {
        return;
    }

    if (g_PlayerState[client].cookiesProcessed)
    {
        return;
    }

    g_PlayerState[client].cookiesProcessed = true;

    char cookie[32];

    Filters_RefreshAdminDbStatus(client);

    // Check if client has forced redlist/filter status from config.
    char steamid[32];
    if (Kogasa_GetClientSteam2(client, steamid, sizeof(steamid), true))
    {
        for (int i = 0; i < g_ForcedStatusCount; i++)
        {
            if (StrEqual(steamid, g_ForcedStatusSteamIDs[i]))
            {
                if (StrEqual(g_ForcedStatusTypes[i], "redlist"))
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
    
    // Process filters-owned cookies normally if no forced status.
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

static int Filters_GetAdminsDbLevel(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "AdminsDB_GetClientWhitelistLevel") != FeatureStatus_Available)
    {
        return 0;
    }

    return AdminsDB_GetClientWhitelistLevel(client);
}

static bool Filters_CanSeeEnemyTeamChat(int client)
{
    return Filters_PChatEnabled() && Filters_GetAdminsDbLevel(client) >= 3;
}

static void Filters_RefreshAdminDbStatus(int client)
{
    if (!Filters_IsRealClientInGame(client))
    {
        return;
    }

    int level = Filters_GetAdminsDbLevel(client);
    g_PlayerState[client].isWhitelisted = level >= 2;
    g_PlayerState[client].isBlacklisted = level < 0;
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
    if (Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true))
    {
        char query[256];
        Format(query, sizeof(query), "SELECT kills FROM whaletracker WHERE steamid = '%s' LIMIT 1", steamId64);
        g_hFiltersDb.Query(Filters_AutoRedlistKillsCallback, query, GetClientUserId(client));
    }

    char steamId2[32];
    if (Kogasa_GetClientSteam2(client, steamId2, sizeof(steamId2), true))
    {
        char query[256];
        Format(query, sizeof(query), "SELECT rapes_given FROM hugs_stats WHERE steamid = '%s' LIMIT 1", steamId2);
        g_hFiltersDb.Query(Filters_AutoRedlistRapesCallback, query, GetClientUserId(client));
    }
}

static bool Filters_IsForcedRedlist(int client)
{
    char steamid[32];
    if (!Kogasa_GetClientSteam2(client, steamid, sizeof(steamid), true))
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

    if (Filters_IsRealClientInGame(client))
    {
        Filters_StartAutoRedlistCheck(client);
        LoadNamePreferencesFromDb(client);
        Filters_RecordSteamName(client);
        Prename_Apply(client);
        Filters_AnnounceClientJoin(client);
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
    LoadNamePreferencesFromDb(client);
}

public void Filters_OnFilterModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Filters_UpdateVoiceOverrides();
}

public void Filters_OnRedlistChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Filters_UpdateVoiceOverrides();
}

public void Filters_OnMuteDeafenChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    Filters_RefreshMuteDeafenState();
}

public void OnClientPutInServer(int client)
{
    Filters_ResetExternalStats(client);
}

public void OnClientDisconnect(int client)
{
    Filters_ClearClientState(client);
    Filters_ResetExternalStats(client);
    g_MuteDeafened[client] = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_VoiceBlocked[client][i] = false;
        g_VoiceBlocked[i][client] = false;
    }
    Filters_AnnouncePlayerEvent(client, false);
}

public void OnPluginEnd()
{
    Filters_StopOutboxTimer();
    if (g_hMuteDeafenTimer != null)
    {
        delete g_hMuteDeafenTimer;
        g_hMuteDeafenTimer = null;
    }

    for (int receiver = 1; receiver <= MaxClients; receiver++)
    {
        for (int sender = 1; sender <= MaxClients; sender++)
        {
            if (g_VoiceBlocked[receiver][sender])
            {
                SetListenOverride(receiver, sender, Listen_Default);
                g_VoiceBlocked[receiver][sender] = false;
            }
        }
    }

    g_ConnectQueueTimer = null;
    g_hFiltersDbReconnectTimer = null;

    if (g_ConnectQueue != null)
    {
        delete g_ConnectQueue;
        g_ConnectQueue = null;
    }

    if (g_WebNameColors != null)
    {
        delete g_WebNameColors;
        g_WebNameColors = null;
    }

    Db_Close(g_hFiltersDb, g_bDbReady);

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
        BuildRenderedClientName(client, buffer, sizeof(buffer));
    }

    SetNativeString(2, buffer, maxlen, true);
    return 1;
}

public any Native_Filters_GetSteamIdColorTag(Handle plugin, int numParams)
{
    char steamId[32];
    GetNativeString(1, steamId, sizeof(steamId));

    int maxlen = GetNativeCell(3);
    char buffer[32];
    buffer[0] = '\0';

    int client = 0;
    if (maxlen > 0 && Filters_FindClientBySteamId64(steamId, client))
    {
        Filters_GetClientColorToken(client, buffer, sizeof(buffer));
    }

    SetNativeString(2, buffer, maxlen, true);
    return (buffer[0] != '\0');
}

public any Native_Filters_GetLastRecordedSteamName(Handle plugin, int numParams)
{
    char steamId64[32];
    GetNativeString(1, steamId64, sizeof(steamId64));

    int maxlen = GetNativeCell(3);
    if (maxlen <= 0)
    {
        return false;
    }

    char buffer[128];
    buffer[0] = '\0';

    if (steamId64[0] != '\0' && Filters_QueryLastRecordedSteamName(steamId64, buffer, sizeof(buffer)))
    {
        SetNativeString(2, buffer, maxlen, true);
        return true;
    }

    SetNativeString(2, "", maxlen, true);
    return false;
}

// ==================== FILTER WHITELIST COMMANDS ====================

public Action Command_FilterWhitelist(int client, int args)
{
    return Filters_RunTargetAdminCommand(client, args,
        "[Kogasa] Usage: sm_filterwhitelist <player>",
        "Filter whitelisted %s",
        FilterAdmin_FilterWhitelist);
}

public Action Command_UnFilterWhitelist(int client, int args)
{
    return Filters_RunTargetAdminCommand(client, args,
        "[Kogasa] Usage: sm_unfilterwhitelist <player>",
        "Removed filter whitelist from %s",
        FilterAdmin_UnFilterWhitelist);
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

public Action Command_Listredlists(int client, int args)
{
    return Filters_RunStatusListCommand(client, FilterStatus_redlist);
}

public Action Command_FiltersHelp(int client, int args)
{
    return Filters_RunFiltersHelpCommand(client);
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

// ==================== redlist COMMANDS ====================

public Action Command_redlist(int client, int args)
{
    return Filters_RunTargetAdminCommand(client, args,
        "[Kogasa] Usage: sm_redlist <player>",
        "redlisted %s",
        FilterAdmin_redlist);
}

public Action Command_Unredlist(int client, int args)
{
    return Filters_RunTargetAdminCommand(client, args,
        "[Kogasa] Usage: sm_unredlist <player>",
        "Removed redlist from %s",
        FilterAdmin_Unredlist);
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
        else if (Filters_CanSeeEnemyTeamChat(client))
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

public Action Listener_Colors(int client, const char[] command, int argc)
{
    return Command_Colors(client, argc);
}

public Action Command_Colors(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    static const char colorLines[][] =
    {
        "{aliceblue}aliceblue, {antiquewhite}antiquewhite, {aqua}aqua, {aquamarine}aquamarine, {azure}azure, {beige}beige, {bisque}bisque, {black}black, {blanchedalmond}blanchedalmond, {blue}blue",
        "{blueviolet}blueviolet, {brown}brown, {burlywood}burlywood, {cadetblue}cadetblue, {chartreuse}chartreuse, {chocolate}chocolate, {coral}coral, {cornflowerblue}cornflowerblue, {cornsilk}cornsilk, {crimson}crimson",
        "{cyan}cyan, {darkblue}darkblue, {darkcyan}darkcyan, {darkgoldenrod}darkgoldenrod, {darkgray}darkgray, {darkgrey}darkgrey, {darkgreen}darkgreen, {darkkhaki}darkkhaki, {darkmagenta}darkmagenta, {darkolivegreen}darkolivegreen",
        "{darkorange}darkorange, {darkorchid}darkorchid, {darkred}darkred, {darksalmon}darksalmon, {darkseagreen}darkseagreen, {darkslateblue}darkslateblue, {darkslategray}darkslategray, {darkslategrey}darkslategrey, {darkturquoise}darkturquoise, {darkviolet}darkviolet",
        "{deeppink}deeppink, {deepskyblue}deepskyblue, {dimgray}dimgray, {dimgrey}dimgrey, {dodgerblue}dodgerblue, {firebrick}firebrick, {floralwhite}floralwhite, {forestgreen}forestgreen, {fuchsia}fuchsia, {gainsboro}gainsboro",
        "{ghostwhite}ghostwhite, {gold}gold, {goldenrod}goldenrod, {gray}gray, {grey}grey, {green}green, {greenyellow}greenyellow, {honeydew}honeydew, {hotpink}hotpink, {indianred}indianred",
        "{indigo}indigo, {ivory}ivory, {khaki}khaki, {lavender}lavender, {lavenderblush}lavenderblush, {lawngreen}lawngreen, {lemonchiffon}lemonchiffon, {lightblue}lightblue, {lightcoral}lightcoral, {lightcyan}lightcyan",
        "{lightgoldenrodyellow}lightgoldenrodyellow, {lightgray}lightgray, {lightgrey}lightgrey, {lightgreen}lightgreen, {lightpink}lightpink, {lightsalmon}lightsalmon, {lightseagreen}lightseagreen, {lightskyblue}lightskyblue, {lightslategray}lightslategray, {lightslategrey}lightslategrey",
        "{lightsteelblue}lightsteelblue, {lightyellow}lightyellow, {lime}lime, {limegreen}limegreen, {linen}linen, {magenta}magenta, {maroon}maroon, {mediumaquamarine}mediumaquamarine, {mediumblue}mediumblue, {mediumorchid}mediumorchid",
        "{mediumpurple}mediumpurple, {mediumseagreen}mediumseagreen, {mediumslateblue}mediumslateblue, {mediumspringgreen}mediumspringgreen, {mediumturquoise}mediumturquoise, {mediumvioletred}mediumvioletred, {midnightblue}midnightblue, {mintcream}mintcream, {mistyrose}mistyrose, {moccasin}moccasin",
        "{navajowhite}navajowhite, {navy}navy, {oldlace}oldlace, {olive}olive, {olivedrab}olivedrab, {orange}orange, {orangered}orangered, {orchid}orchid, {palegoldenrod}palegoldenrod, {palegreen}palegreen",
        "{paleturquoise}paleturquoise, {palevioletred}palevioletred, {papayawhip}papayawhip, {peachpuff}peachpuff, {peru}peru, {pink}pink, {plum}plum, {powderblue}powderblue, {purple}purple, {red}red",
        "{rosybrown}rosybrown, {royalblue}royalblue, {saddlebrown}saddlebrown, {salmon}salmon, {sandybrown}sandybrown, {seagreen}seagreen, {seashell}seashell, {sienna}sienna, {silver}silver, {skyblue}skyblue",
        "{slateblue}slateblue, {slategray}slategray, {slategrey}slategrey, {snow}snow, {springgreen}springgreen, {steelblue}steelblue, {tan}tan, {teal}teal, {thistle}thistle, {tomato}tomato",
        "{turquoise}turquoise, {violet}violet, {wheat}wheat, {white}white, {whitesmoke}whitesmoke, {yellow}yellow, {yellowgreen}yellowgreen"
    };

    for (int i = 0; i < sizeof(colorLines); i++)
    {
        CPrintToChat(client, "%s", colorLines[i]);
    }
    CPrintToChat(client, "{default}[Filters] Store owners can use {gold}!america{default}, {gold}!mapflag{default}, {gold}!trans{default}, or {gold}!rainbow{default} for preset patterns.");
    CPrintToChat(client, "{default}[Filters] Gradient access owners can use {gold}!gradient <color1> <color2>{default} or {gold}!hue <color1> <color2>{default}.");

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

static void Filters_RecordSteamName(int client)
{
    if (!Filters_DbAvailable() || !Filters_IsRealClientInGame(client))
    {
        return;
    }

    char steamId64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)) || steamId64[0] == '\0')
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));
    TrimString(name);
    if (name[0] == '\0')
    {
        return;
    }

    char lowerName[128];
    strcopy(lowerName, sizeof(lowerName), name);
    Prename_ToLowercaseInPlace(lowerName, sizeof(lowerName));

    char escapedSteam[64];
    char escapedName[256];
    char escapedLower[256];
    Db_Escape(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam), "filters");
    Db_Escape(g_hFiltersDb, name, escapedName, sizeof(escapedName), "filters");
    Db_Escape(g_hFiltersDb, lowerName, escapedLower, sizeof(escapedLower), "filters");

    char query[768];
    Format(query, sizeof(query),
        "INSERT INTO filters_steam_names (steamid64, last_name, last_name_lower, updated_at) "
        ... "VALUES ('%s', '%s', '%s', %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "last_name = VALUES(last_name), "
        ... "last_name_lower = VALUES(last_name_lower), "
        ... "updated_at = VALUES(updated_at)",
        escapedSteam,
        escapedName,
        escapedLower,
        GetTime());
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static bool Filters_QueryLastRecordedSteamName(const char[] steamId64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!Filters_DbAvailable() || steamId64[0] == '\0')
    {
        return false;
    }

    char escapedSteam[64];
    Db_Escape(g_hFiltersDb, steamId64, escapedSteam, sizeof(escapedSteam), "filters");

    char query[256];
    Format(query, sizeof(query),
        "SELECT last_name FROM filters_steam_names WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DBResultSet results = SQL_Query(g_hFiltersDb, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_hFiltersDb, error, sizeof(error));
        LogError("[Filters] Last recorded Steam name query failed: %s", error);
        return false;
    }

    bool found = false;
    if (results.FetchRow())
    {
        results.FetchString(0, buffer, maxlen);
        TrimString(buffer);
        found = (buffer[0] != '\0');
    }

    delete results;
    return found;
}

// ==================== PRENAME (MERGED) ====================

static void Filters_PrenameLoadRules()
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    g_PrenameRulesLoaded = false;
    g_hFiltersDb.Query(Filters_PrenameLoadRulesCallback, "SELECT pattern, newname FROM prename_rules");
}

public void Filters_PrenameLoadRulesCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Filters/Prename] Failed to load rules: %s", error);
        g_PrenameRulesLoaded = false;
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
        g_PrenameRulesLoaded = true;
        Filters_ApplyPrenameToConnectedClients();
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
        }
    }

    g_PrenameRulesLoaded = true;
    Filters_ApplyPrenameToConnectedClients();
}

static void Filters_ApplyPrenameToConnectedClients()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Filters_IsRealClientInGame(client))
        {
            Prename_Apply(client);
        }
    }
}

static bool Prename_Apply(int client)
{
    if (!g_bDbReady || g_hFiltersDb == null || g_PrenameIdRules == null)
    {
        return false;
    }

    char currentName[MAX_NAME_LENGTH];
    GetClientName(client, currentName, sizeof(currentName));

    char steam2[32], steam64[32];
    Prename_GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));

    char rename[PRENAME_MAX_RENAME];
    if (Prename_TryGetIdRule(steam64, steam2, rename, sizeof(rename)))
    {
        if (!StrEqual(currentName, rename, false))
        {
            SetClientName(client, rename);
        }
        return true;
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

    char targetName[MAX_NAME_LENGTH];
    int target = Prename_FindSingleClientByName(client, patternRaw, targetName, sizeof(targetName));
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    char steam2[32], steam64[32], steamId[32];
    Prename_GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
    Prename_GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
    if (!steamId[0])
    {
        ReplyToCommand(client, "[Kogasa] Failed to resolve SteamID for %s.", targetName);
        return Plugin_Handled;
    }

    Prename_SaveRule(steamId, newname);
    Prename_SetIdRuleCache(steamId, newname);
    SetClientName(target, newname);
    ReplyToCommand(client, "[Kogasa] Prename rule saved: %s -> %s (%s)", targetName, newname, steamId);
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
        ReplyToCommand(client, "[Kogasa] Usage: sm_reset <name|steamid>");
        return Plugin_Handled;
    }

    char targetRaw[PRENAME_MAX_PATTERN];
    GetCmdArg(1, targetRaw, sizeof(targetRaw));
    TrimString(targetRaw);

    if (!targetRaw[0])
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_reset <name|steamid>");
        return Plugin_Handled;
    }

    char steam2[32], steam64[32];
    if (!Prename_IsIdString(targetRaw))
    {
        char targetName[MAX_NAME_LENGTH];
        int target = Prename_FindSingleClientByName(client, targetRaw, targetName, sizeof(targetName));
        if (target <= 0)
        {
            return Plugin_Handled;
        }

        char resolvedId[32];
        Prename_GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
        Prename_GetPreferredClientId(steam64, steam2, resolvedId, sizeof(resolvedId));
        if (!resolvedId[0])
        {
            ReplyToCommand(client, "[Kogasa] Failed to resolve SteamID for %s.", targetName);
            return Plugin_Handled;
        }

        Prename_DeleteRule(resolvedId);
        Prename_RemoveIdRuleCache(resolvedId);
        ReplyToCommand(client, "[Kogasa] Prename rule removed for %s (%s)", targetName, resolvedId);
        return Plugin_Handled;
    }

    if (StrContains(targetRaw, "STEAM_", false) == 0)
    {
        int match = Prename_FindClientBySteam2(targetRaw);
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

    Prename_DeleteRule(targetRaw);
    Prename_RemoveIdRuleCache(targetRaw);
    ReplyToCommand(client, "[Kogasa] Prename rule removed for '%s'", targetRaw);
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
    Db_Escape(g_hFiltersDb, pattern, escapedPattern, sizeof(escapedPattern), "filters");
    Db_Escape(g_hFiltersDb, newname, escapedNewname, sizeof(escapedNewname), "filters");

    char query[256];
    Format(query, sizeof(query),
        "REPLACE INTO prename_rules (pattern, newname) VALUES ('%s', '%s')",
        escapedPattern, escapedNewname);
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, query);
}

static void Prename_DeleteRule(const char[] pattern)
{
    if (!g_bDbReady || g_hFiltersDb == null)
    {
        return;
    }

    char escapedPattern[PRENAME_MAX_PATTERN * 2];
    Db_Escape(g_hFiltersDb, pattern, escapedPattern, sizeof(escapedPattern), "filters");

    char query[256];
    Format(query, sizeof(query), "DELETE FROM prename_rules WHERE pattern = '%s'", escapedPattern);
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
        Kogasa_GetClientSteam2(i, id, sizeof(id), true);
        if (StrEqual(id, steam2, false))
        {
            return i;
        }
    }

    return -1;
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
    Kogasa_GetClientSteamId64(client, steam64, steam64Max, true);
    Kogasa_GetClientSteam2(client, steam2, steam2Max, true);
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
