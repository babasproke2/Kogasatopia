#include <sourcemod>
#include <sdktools>
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

// Player state structure
enum struct PlayerState
{
    bool isWhitelisted;        // Player bypasses all filters and blacklist
    bool isFilterWhitelisted;  // Player bypasses word filters only
    bool isBlacklisted;        // Player cannot send any messages
}

PlayerState g_PlayerState[MAXPLAYERS + 1];

// Cookie handles
Handle g_hCookieWhitelist;
Handle g_hCookieFilterWhitelist;
Handle g_hCookieBlacklist;
Handle g_hCookieNameColor;
Handle g_hChatFrontend;

// Per-client name color tokens (empty string means team color)
char g_NameColors[MAXPLAYERS + 1][32];

// Truthtext handles
Handle g_sEnabled = INVALID_HANDLE;
Handle g_sChatMode2 = INVALID_HANDLE;
ConVar g_hChatDebug = null;

// Global arrays for word filtering
char g_FilterWords[MAX_FILTERS][MAX_WORD_LENGTH];
char g_ReplacementWords[MAX_FILTERS][MAX_WORD_LENGTH];
int g_FilterCount = 0;

// Global array for blacklisted words
char g_BlacklistWords[MAX_BLACKLIST][MAX_WORD_LENGTH];
int g_BlacklistCount = 0;

// Global arrays for forced status
char g_ForcedStatusSteamIDs[MAX_FORCED_STATUS][32];
char g_ForcedStatusTypes[MAX_FORCED_STATUS][32]; // "whitelist", "blacklist", or "filter_whitelist"
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

enum struct ConnectEvent
{
    char name[MAX_NAME_LENGTH];
    bool connected;
}

bool Filters_DebugEnabled()
{
    return g_hChatDebug != null && g_hChatDebug.BoolValue;
}

void Filters_LogDebug(const char[] fmt, any ...)
{
    if (!Filters_DebugEnabled())
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogMessage("[Filters][Chat] %s", buffer);
}

public Plugin myinfo = 
{
    name = "Chat Manager",
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

    LoadFilterConfig();

    // Truthtext Convars
    g_sEnabled = CreateConVar("nobroly", "1", "If 0, filter chat to one word");
    g_sChatMode2 = CreateConVar("filtermode", "0", "Enable/Disable the quarantined filter mode");
    g_hChatDebug = CreateConVar("filters_chat_debug", "0", "Enable verbose debug logging for chat relay");
    g_hChatFrontend = CreateConVar("filters_chat_frontend", "1", "Enable/Disable db functions");
    
    // Initialize cookies
    g_hCookieWhitelist = RegClientCookie("filter_whitelist", "Player is whitelisted from all filters", CookieAccess_Protected);
    g_hCookieFilterWhitelist = RegClientCookie("filter_filterwhitelist", "Player is whitelisted from word filters only", CookieAccess_Protected);
    g_hCookieBlacklist = RegClientCookie("filter_blacklist", "Player is blacklisted from sending messages", CookieAccess_Protected);
    g_hCookieNameColor = RegClientCookie("filter_namecolor", "Player's custom chat name color", CookieAccess_Protected);
    
    // Register admin commands for managing player states
    RegAdminCmd("sm_whitelist", Command_Whitelist, ADMFLAG_CHAT, "sm_whitelist <player> - Whitelists a player from all filters");
    RegAdminCmd("sm_unwhitelist", Command_UnWhitelist, ADMFLAG_CHAT, "sm_unwhitelist <player> - Removes whitelist from a player");
    
    RegAdminCmd("sm_filterwhitelist", Command_FilterWhitelist, ADMFLAG_CHAT, "sm_filterwhitelist <player> - Whitelists a player from word filters only");
    RegAdminCmd("sm_unfilterwhitelist", Command_UnFilterWhitelist, ADMFLAG_CHAT, "sm_unfilterwhitelist <player> - Removes filter whitelist from a player");
    
    RegAdminCmd("sm_blacklist", Command_Blacklist, ADMFLAG_CHAT, "sm_blacklist <player> - Blacklists a player from sending messages");
    RegAdminCmd("sm_unblacklist", Command_UnBlacklist, ADMFLAG_CHAT, "sm_unblacklist <player> - Removes blacklist from a player");

    // Web chat relay
    RegConsoleCmd("sm_websay", Command_WebSay, "Relay a web chat message to all players");

    Filters_SQLConnect();
    CreateTimer(2.0, Timer_PollOutbox, _, TIMER_REPEAT);

    // Restore existing clients' custom colors after reloads
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }
        if (AreClientCookiesCached(i))
        {
            LoadNameColorCookie(i);
        }
        else
        {
            g_NameColors[i][0] = '\0';
        }
    }
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
    if (!g_hFiltersDb.SetCharset("utf8mb4"))
    {
        LogError("[Filters] Failed to set utf8mb4 charset");
    }

    static const char queries[][] =
    {
        "CREATE TABLE IF NOT EXISTS whaletracker_chat ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY,"
        ... "created_at INT NOT NULL,"
        ... "steamid VARCHAR(32) NULL,"
        ... "personaname VARCHAR(128) NULL,"
        ... "iphash VARCHAR(64) NULL,"
        ... "message TEXT NOT NULL,"
        ... "INDEX(created_at)) DEFAULT CHARSET=utf8mb4",
        "CREATE TABLE IF NOT EXISTS whaletracker_chat_outbox ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY,"
        ... "created_at INT NOT NULL,"
        ... "iphash VARCHAR(64) NOT NULL,"
        ... "display_name VARCHAR(128) DEFAULT '',"
        ... "message TEXT NOT NULL,"
        ... "INDEX(created_at)) DEFAULT CHARSET=utf8mb4"
    };

    for (int i = 0; i < sizeof(queries); i++)
    {
        g_hFiltersDb.Query(Filters_SimpleSqlCallback, queries[i]);
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

// Poll DB outbox and relay to all chat, then delete processed rows
public Action Timer_PollOutbox(Handle timer, any data)
{
    if (!g_bDbReady)
    {
        Filters_LogDebug("DB not ready; skipping outbox poll");
        return Plugin_Continue;
    }
    char query[256];
    Format(query, sizeof(query), "SELECT id, iphash, display_name, message FROM whaletracker_chat_outbox ORDER BY id ASC LIMIT 20");
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
    int ids[64];
    int count = 0;
    while (results.FetchRow() && count < sizeof(ids))
    {
        int id = results.FetchInt(0);
        char hash[64];
        results.FetchString(1, hash, sizeof(hash));
        char display[128];
        results.FetchString(2, display, sizeof(display));
        char msg[512];
        results.FetchString(3, msg, sizeof(msg));
        char label[256];
        char colorTag[32] = "{gold}";
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
        char out[640];
        Format(out, sizeof(out), "%s %s", label, msg);
        bool suppressChatBroadcast = StrEqual(hash, "system");
        if (!suppressChatBroadcast)
        {
            CPrintToChatAll("%s", out);
        }
        PrintToServer("%s", out);
        Filters_LogDebug("Relayed chat id %d hash %s name %s msg %s", id, hash, display, msg);
        ids[count++] = id;
    }
    if (count <= 0) return;
    // Build delete query
    char del[512];
    strcopy(del, sizeof(del), "DELETE FROM whaletracker_chat_outbox WHERE id IN (");
    char num[16];
    for (int i = 0; i < count; i++)
    {
        if (i > 0) StrCat(del, sizeof(del), ",");
        IntToString(ids[i], num, sizeof(num));
        StrCat(del, sizeof(del), num);
    }
    StrCat(del, sizeof(del), ")");
    g_hFiltersDb.Query(Filters_SimpleSqlCallback, del);
    Filters_LogDebug("Acknowledged %d outbox messages", count);
}

void Filters_LogChatMessage(int client, const char[] message)
{
    if (GetConVarInt(g_hChatFrontend) < 1)
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
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message) VALUES (%d, '%s', '%s', NULL, '%s')",
            GetTime(), steamId, escapedName, escapedMsg);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message) VALUES (%d, NULL, '%s', NULL, '%s')",
            GetTime(), escapedName, escapedMsg);
    }
    g_hFiltersDb.Query(Filters_InsertChatCallback, query);
    Filters_LogDebug("Logged chat from %s: %s", hasSteam ? steamId : "unknown", message);
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

void Filters_InsertSystemMessage(const char[] format, any ...)
{
    if (!g_bDbReady)
    {
        Filters_LogDebug("DB not ready; skipping system message");
        return;
    }

    char message[256];
    VFormat(message, sizeof(message), format, 2);

    int timestamp = GetTime();
    char escapedMsg[512];
    SQL_EscapeString(g_hFiltersDb, message, escapedMsg, sizeof(escapedMsg));

    char query[1024];
    Format(query, sizeof(query),
        "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message) VALUES (%d, NULL, '[SERVER]', 'system', '%s')",
        timestamp,
        escapedMsg);
    g_hFiltersDb.Query(Filters_InsertChatCallback, query);

    Format(query, sizeof(query),
        "INSERT INTO whaletracker_chat_outbox (created_at, iphash, message) VALUES (%d, 'system', '%s')",
        timestamp,
        escapedMsg);
    g_hFiltersDb.Query(Filters_OutboxInsertCallback, query);
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
            Filters_InsertSystemMessage("{gold}[Server]{default}: {cornflowerblue}%s{default} connected to the server.", event.name);
        }
        else
        {
            Filters_InsertSystemMessage("{gold}[Server]{default}: {cornflowerblue}%s{default} disconnected from the server.", event.name);
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

    char nameColorTag[40];
    BuildNameColorTag(client, nameColorTag, sizeof(nameColorTag));

    char output[256];
    Format(output, sizeof(output), "{default}%s%s%N{default}: %s", dead, nameColorTag, client, sArgs);

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

    if (!StrEqual(commandToken, "!name", false) && !StrEqual(commandToken, "/name", false))
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
        SetClientCookie(client, g_hCookieNameColor, "");
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
    SetClientCookie(client, g_hCookieNameColor, colorName);

    CPrintToChat(client, "{default}[Filters] Your name color is now {%s}%s{default}.", colorName, colorName);
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

    char output[256];
    Format(output, sizeof(output), "{default}%s%s %s%N{default}: %s", deadPrefix, tag, colorTag, client, sArgs);
    CPrintToChatTeam(GetClientTeam(client), output);
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
        if (IsClientInGame(i) && g_PlayerState[i].isBlacklisted)
        {
            CPrintToChatEx(i, client, "%s", message);
        }
    }

    SendToWhitelistedAdmins(client, message, "x:");
    PrintToServer("x: %s", message);
    return true;
}

bool HandleRestrictedMessage(int client, const char[] message, const ChatContext context)
{
    if ((context.hasBlacklistedTerm && !context.isWhitelisted) || context.isGagged)
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

    if (!context.cordMode)
    {
        CPrintToChatAllEx(client, "%s", message);
    }
    else
    {
        int randomChance = GetRandomInt(1, 20);
        if (randomChance == 1)
        {
            CPrintToChatAll(message);
        }
        else
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (IsClientInGame(i) && !g_PlayerState[i].isBlacklisted)
                {
                    CPrintToChatEx(i, client, "%s", message);
                }
            }
        }
    }

    PrintToServer("%s", message);
    Filters_LogChatMessage(client, message);
    return true;
}

void SendFallbackMessage(int client)
{
    char colorTag[40];
    BuildNameColorTag(client, colorTag, sizeof(colorTag));

    char output[256];
    Format(output, sizeof(output), "%s%N{default}: {greenyellow}BROLY", colorTag, client);
    CPrintToChatAllEx(client, "%s", output);
    Filters_LogChatMessage(client, output);
}

public Action Command_WebSay(int client, int args)
{
    // Console-only intended, but allow any caller
    char raw[256];
    GetCmdArgString(raw, sizeof(raw));
    TrimString(raw);
    if (!raw[0])
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
    CPrintToChatAll("%s", out);
    Filters_LogDebug("sm_websay broadcast hash %s message %s", hash, msgPart);
    // Log web message
    if (g_bDbReady)
    {
        char escapedMsg[512];
        SQL_EscapeString(g_hFiltersDb, msgPart, escapedMsg, sizeof(escapedMsg));
        char query[1024];
        Format(query, sizeof(query),
            "INSERT INTO whaletracker_chat (created_at, steamid, personaname, iphash, message) VALUES (%d, NULL, NULL, '%s', '%s')",
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
                CPrintToChatEx(i, sender, "%s %s", prefix, message);
            else
                CPrintToChatEx(i, sender, "%s", message);
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
                if (StrEqual(status, "whitelist") || StrEqual(status, "blacklist") || StrEqual(status, "filter_whitelist"))
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
    
    PrintToServer("[Word Filter] Loaded %d filter words, %d blacklist words, %d forced status entries, and %d commands", 
                  g_FilterCount, g_BlacklistCount, g_ForcedStatusCount, g_AllowedCommandsCount);
}

// Example usage function - filters a string
public void FilterString(char[] input, int maxlen)
{
    // Apply word filters
    for (int i = 0; i < g_FilterCount; i++)
    {
        ReplaceString(input, maxlen, g_FilterWords[i], g_ReplacementWords[i], false);
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
    file.WriteLine("    \"force_status\"");
    file.WriteLine("    {");
    file.WriteLine("        \"STEAM_0:0:12345678\"    \"whitelist\"");
    file.WriteLine("        \"STEAM_0:1:87654321\"    \"blacklist\"");
    file.WriteLine("        \"STEAM_0:0:11223344\"    \"filter_whitelist\"");
    file.WriteLine("    }");
    file.WriteLine("    \"commands\"");
    file.WriteLine("    {");
    file.WriteLine("        \"rtv\"    \"\"");
    file.WriteLine("        \"nominate\"    \"\"");
    file.WriteLine("        \"nextmap\"    \"\"");
    file.WriteLine("        \"motd\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("}");
    
    delete file;
    
    LogMessage("Default config file created: %s", path);
}

void LoadNameColorCookie(int client)
{
    if (g_hCookieNameColor == INVALID_HANDLE)
    {
        g_NameColors[client][0] = '\0';
        return;
    }

    char colorCookie[32];
    GetClientCookie(client, g_hCookieNameColor, colorCookie, sizeof(colorCookie));

    if (!colorCookie[0])
    {
        g_NameColors[client][0] = '\0';
        return;
    }

    ToLowercase(colorCookie);

    if (!CColorExists(colorCookie))
    {
        g_NameColors[client][0] = '\0';
        PrintToServer("[FILTERS] %N had invalid name color '%s', resetting to team color", client, colorCookie);
        SetClientCookie(client, g_hCookieNameColor, "");
        return;
    }

    strcopy(g_NameColors[client], sizeof(g_NameColors[]), colorCookie);
    PrintToServer("[FILTERS] %N loaded custom name color '%s'", client, g_NameColors[client]);
}

// Process client cookies on connect/cache
void ProcessCookies(int client)
{
    char cookie[32];

    LoadNameColorCookie(client);
    
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

}

public void OnClientPostAdminCheck(int client)
{
    if (AreClientCookiesCached(client))
    {
        ProcessCookies(client);
    }
}

public void OnClientCookiesCached(int client)
{
    ProcessCookies(client);
}

public void OnClientPutInServer(int client)
{
    Filters_AnnouncePlayerEvent(client, true);
}

public void OnClientDisconnect(int client)
{
    g_PlayerState[client].isWhitelisted = false;
    g_PlayerState[client].isFilterWhitelisted = false;
    g_PlayerState[client].isBlacklisted = false;
    g_NameColors[client][0] = '\0';
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
}

// ==================== WHITELIST COMMANDS ====================

public Action Command_Whitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_whitelist <player>");
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
        ShowActivity2(client, "[SM] ", "Whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_unwhitelist <player>");
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
        ShowActivity2(client, "[SM] ", "Removed whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Removed whitelist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = true;
    SetClientCookie(target, g_hCookieWhitelist, "1");
    LogAction(client, target, "\"%L\" whitelisted \"%L\"", client, target);
}

void PerformUnWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = false;
    SetClientCookie(target, g_hCookieWhitelist, "0");
    LogAction(client, target, "\"%L\" removed whitelist from \"%L\"", client, target);
}

// ==================== FILTER WHITELIST COMMANDS ====================

public Action Command_FilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_filterwhitelist <player>");
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
        ShowActivity2(client, "[SM] ", "Filter whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Filter whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnFilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_unfilterwhitelist <player>");
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
        ShowActivity2(client, "[SM] ", "Removed filter whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Removed filter whitelist from %s", target_name);
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
        ReplyToCommand(client, "[SM] Usage: sm_blacklist <player>");
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
        ShowActivity2(client, "[SM] ", "Blacklisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Blacklisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnBlacklist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_unblacklist <player>");
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
        ShowActivity2(client, "[SM] ", "Removed blacklist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[SM] ", "Removed blacklist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = true;
    SetClientCookie(target, g_hCookieBlacklist, "1");
    LogAction(client, target, "\"%L\" blacklisted \"%L\"", client, target);
}

void PerformUnBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = false;
    SetClientCookie(target, g_hCookieBlacklist, "0");
    LogAction(client, target, "\"%L\" removed blacklist from \"%L\"", client, target);
}

void CPrintToChatTeam(int team, const char[] message)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && GetClientTeam(client) == team)
        {
            CPrintToChatEx(client, client, "%s", message);
        }
    }
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
    for (int i = 0; i < MAX_BLACKLIST; i++)
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
    return false;
}
