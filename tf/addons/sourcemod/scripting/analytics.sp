#include <sourcemod>
#include <geoip>
#include "include/dgm_api.inc"

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.5"

#define CONNECTION_LOG_PATH "logs/connections"
#define ANALYTICS_DB_CONFIG "default"
#define ANALYTICS_FLUSH_INTERVAL 30.0
#define ANALYTICS_SQL_MAX 8192

char g_sQuickStatsPath[PLATFORM_MAX_PATH];

Database g_hDb = null;
ArrayList g_hEventQueue = null;
Handle g_hFlushTimer = null;
bool g_bDbReady = false;

bool g_bClientIsAdmin[MAXPLAYERS + 1] = { false, ... };
bool g_bClientConnected[MAXPLAYERS + 1] = { false, ... };

enum struct PlayerStats
{
    int Killstreak;
    int Score;
    int Frags;
    int Deaths;
    int Assists;
    int Damage;
    char Team[32];
    char Class[32];
    char Time[32];
}

enum struct AnalyticsEvent
{
    int OccurredAt;
    int HostPort;
    int ConnectionMinutes;
    int Weekday;
    int HourOfDay;
    bool IsAdmin;
    char EventType[32];
    char PlayerName[64];
    char SteamId[64];
    char IpSubnet[64];
    char Country[64];
    char MapName[128];
    char Gamemode[32];
    char Reason[192];
}

public Plugin myinfo =
{
    name = "analytics",
    author = "Xander, IT-KiLLER, Dosergen, Hombre",
    description = "Logs player connection analytics to SQL with country and masked IP subnet data.",
    version = PLUGIN_VERSION,
    url = "https://forums.alliedmods.net/showthread.php?t=201967"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_GetServerCapacity");
    MarkNativeAsOptional("DGM_RealPlayerCount");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("sm_log_connections_version", PLUGIN_VERSION, "Log Connections version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    InitializeLogPath(CONNECTION_LOG_PATH);
    g_hEventQueue = new ArrayList(sizeof(AnalyticsEvent));
    g_hFlushTimer = CreateTimer(ANALYTICS_FLUSH_INTERVAL, Timer_FlushAnalyticsEvents, _, TIMER_REPEAT);

    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    ConnectAnalyticsDb();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            g_bClientConnected[client] = true;
            g_bClientIsAdmin[client] = IsPlayerAdmin(client);
        }
    }
}

public void OnPluginEnd()
{
    FlushAnalyticsEvents();

    if (g_hFlushTimer != null)
    {
        KillTimer(g_hFlushTimer);
        g_hFlushTimer = null;
    }

    delete g_hEventQueue;
    g_hEventQueue = null;

    if (g_hDb != null)
    {
        delete g_hDb;
        g_hDb = null;
    }
}

public void OnAllPluginsLoaded()
{
    CreateTimer(5.0, UpdateQuickStats, _, TIMER_REPEAT);
}

public void OnMapStart()
{
    QueueMapChangeEvent();
}

public void OnRebuildAdminCache(AdminCachePart part)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            g_bClientIsAdmin[client] = IsPlayerAdmin(client);
        }
    }
}

public void OnClientPostAdminCheck(int client)
{
    if (!client || IsFakeClient(client))
    {
        return;
    }

    if (g_bClientConnected[client])
    {
        return;
    }

    g_bClientConnected[client] = true;
    g_bClientIsAdmin[client] = IsPlayerAdmin(client);
    QueueClientEvent(client, true);
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client || IsFakeClient(client))
    {
        return;
    }

    if (!g_bClientConnected[client])
    {
        return;
    }

    char reason[192] = "Unknown";
    event.GetString("reason", reason, sizeof(reason));

    g_bClientConnected[client] = false;
    QueueClientEvent(client, false, reason);
    g_bClientIsAdmin[client] = false;
}

public Action Timer_FlushAnalyticsEvents(Handle timer)
{
    FlushAnalyticsEvents();
    return Plugin_Continue;
}

void QueueMapChangeEvent()
{
    AnalyticsEvent event;
    PopulateBaseEvent(event, CountConnectedHumans() < 1 ? "map_change_empty" : "map_change");
    strcopy(event.PlayerName, sizeof(event.PlayerName), "");
    strcopy(event.SteamId, sizeof(event.SteamId), "");
    strcopy(event.IpSubnet, sizeof(event.IpSubnet), "");
    strcopy(event.Country, sizeof(event.Country), "");
    strcopy(event.Reason, sizeof(event.Reason), "");
    event.IsAdmin = false;
    event.ConnectionMinutes = 0;
    QueueAnalyticsEvent(event);
}

void QueueClientEvent(int client, bool isConnecting, const char[] disconnectReason = "")
{
    AnalyticsEvent event;
    PopulateBaseEvent(event, isConnecting ? "connect" : "disconnect");

    GetClientName(client, event.PlayerName, sizeof(event.PlayerName));
    if (!GetClientAuthId(client, AuthId_Steam2, event.SteamId, sizeof(event.SteamId), false))
    {
        strcopy(event.SteamId, sizeof(event.SteamId), "Unknown");
    }

    char rawIp[64];
    GetClientNetworkInfo(client, rawIp, sizeof(rawIp), event.IpSubnet, sizeof(event.IpSubnet), event.Country, sizeof(event.Country));
    event.IsAdmin = g_bClientIsAdmin[client];
    event.ConnectionMinutes = isConnecting ? 0 : RoundToCeil(GetClientTime(client) / 60.0);
    strcopy(event.Reason, sizeof(event.Reason), disconnectReason);

    QueueAnalyticsEvent(event);
}

void PopulateBaseEvent(AnalyticsEvent event, const char[] eventType)
{
    event.OccurredAt = GetTime();
    event.HostPort = GetHostPort();
    event.ConnectionMinutes = 0;
    event.IsAdmin = false;

    strcopy(event.EventType, sizeof(event.EventType), eventType);
    GetAnalyticsMapName(event.MapName, sizeof(event.MapName));
    GetAnalyticsGamemode(event.Gamemode, sizeof(event.Gamemode));
    GetWeekdayHour(event.OccurredAt, event.Weekday, event.HourOfDay);
}

void QueueAnalyticsEvent(AnalyticsEvent event)
{
    if (g_hEventQueue == null)
    {
        return;
    }

    g_hEventQueue.PushArray(event);
}

void FlushAnalyticsEvents()
{
    if (g_hEventQueue == null || g_hEventQueue.Length == 0)
    {
        return;
    }

    if (!g_bDbReady || g_hDb == null)
    {
        ConnectAnalyticsDb();
        return;
    }

    char query[ANALYTICS_SQL_MAX];
    strcopy(query, sizeof(query),
        "INSERT INTO server_connection_events (occurred_at, host_port, map_name, gamemode, event_type, is_admin, player_name, steamid, ip_subnet, country, connection_minutes, reason, weekday, hour_of_day, imported, source_file, source_line, created_at) VALUES ");

    bool hasRows = false;
    int createdAt = GetTime();

    AnalyticsEvent event;
    for (int i = 0; i < g_hEventQueue.Length; i++)
    {
        g_hEventQueue.GetArray(i, event);

        char values[2048];
        FormatAnalyticsEventValues(event, values, sizeof(values), createdAt);

        int needed = strlen(query) + strlen(values) + (hasRows ? 2 : 0) + 1;
        if (hasRows && needed >= sizeof(query))
        {
            SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);
            strcopy(query, sizeof(query),
                "INSERT INTO server_connection_events (occurred_at, host_port, map_name, gamemode, event_type, is_admin, player_name, steamid, ip_subnet, country, connection_minutes, reason, weekday, hour_of_day, imported, source_file, source_line, created_at) VALUES ");
            hasRows = false;
        }

        if (hasRows)
        {
            StrCat(query, sizeof(query), ", ");
        }
        StrCat(query, sizeof(query), values);
        hasRows = true;
    }

    if (hasRows)
    {
        SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);
    }

    g_hEventQueue.Clear();
}

void FormatAnalyticsEventValues(AnalyticsEvent event, char[] output, int maxlen, int createdAt)
{
    char mapName[256];
    char gamemode[96];
    char eventType[96];
    char playerName[160];
    char steamId[160];
    char ipSubnet[160];
    char country[160];
    char reason[384];

    SQL_EscapeString(g_hDb, event.MapName, mapName, sizeof(mapName));
    SQL_EscapeString(g_hDb, event.Gamemode, gamemode, sizeof(gamemode));
    SQL_EscapeString(g_hDb, event.EventType, eventType, sizeof(eventType));
    SQL_EscapeString(g_hDb, event.PlayerName, playerName, sizeof(playerName));
    SQL_EscapeString(g_hDb, event.SteamId, steamId, sizeof(steamId));
    SQL_EscapeString(g_hDb, event.IpSubnet, ipSubnet, sizeof(ipSubnet));
    SQL_EscapeString(g_hDb, event.Country, country, sizeof(country));
    SQL_EscapeString(g_hDb, event.Reason, reason, sizeof(reason));

    FormatEx(output, maxlen,
        "(%d, %d, '%s', '%s', '%s', %d, '%s', '%s', '%s', '%s', %d, '%s', %d, %d, 0, NULL, NULL, %d)",
        event.OccurredAt,
        event.HostPort,
        mapName,
        gamemode,
        eventType,
        event.IsAdmin ? 1 : 0,
        playerName,
        steamId,
        ipSubnet,
        country,
        event.ConnectionMinutes,
        reason,
        event.Weekday,
        event.HourOfDay,
        createdAt);
}

public void SQL_OnWriteComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[analytics] SQL write failed: %s", error);

    if (StrContains(error, "Lost connection", false) != -1 || StrContains(error, "server has gone away", false) != -1)
    {
        g_bDbReady = false;
        ConnectAnalyticsDb();
    }
}

public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        g_bDbReady = false;
        LogError("[analytics] Database connect failed: %s", error);
        return;
    }

    if (g_hDb != null)
    {
        delete g_hDb;
    }

    g_hDb = view_as<Database>(hndl);
    g_bDbReady = true;
    EnsureAnalyticsSchema();
}

void ConnectAnalyticsDb()
{
    SQL_TConnect(SQL_OnConnect, ANALYTICS_DB_CONFIG);
}

void EnsureAnalyticsSchema()
{
    if (g_hDb == null)
    {
        return;
    }

    char query[4096];
    query[0] = '\0';
    StrCat(query, sizeof(query), "CREATE TABLE IF NOT EXISTS server_connection_events (");
    StrCat(query, sizeof(query), "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,");
    StrCat(query, sizeof(query), "occurred_at INT NOT NULL,");
    StrCat(query, sizeof(query), "host_port INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_name VARCHAR(128) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "gamemode VARCHAR(32) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "event_type VARCHAR(32) NOT NULL,");
    StrCat(query, sizeof(query), "is_admin TINYINT(1) NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "player_name VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "steamid VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "ip_subnet VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "country VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "connection_minutes INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "reason VARCHAR(192) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "weekday TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "hour_of_day TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "imported TINYINT(1) NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "source_file VARCHAR(255) NULL,");
    StrCat(query, sizeof(query), "source_line INT NULL,");
    StrCat(query, sizeof(query), "created_at INT NOT NULL,");
    StrCat(query, sizeof(query), "KEY idx_occurred_at (occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_host_occurred_at (host_port, occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_map_occurred_at (map_name, occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_steamid (steamid),");
    StrCat(query, sizeof(query), "KEY idx_event_type (event_type),");
    StrCat(query, sizeof(query), "KEY idx_weekday_hour (weekday, hour_of_day),");
    StrCat(query, sizeof(query), "UNIQUE KEY uniq_import_source (source_file, source_line)");
    StrCat(query, sizeof(query), ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, query);
}

public void SQL_OnSchemaComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[analytics] SQL schema update failed: %s", error);
    }
}

public Action UpdateQuickStats(Handle timer)
{
    char serverPort[10];
    ConVar cvarPort = FindConVar("hostport");
    if (cvarPort != null)
    {
        cvarPort.GetString(serverPort, sizeof(serverPort));
    }
    else
    {
        strcopy(serverPort, sizeof(serverPort), "0");
    }

    char hostname[100];
    ConVar cvarHost = FindConVar("hostname");
    if (cvarHost != null)
    {
        cvarHost.GetString(hostname, sizeof(hostname));
    }
    else
    {
        strcopy(hostname, sizeof(hostname), "Unknown");
    }

    char mapName[100];
    GetAnalyticsMapName(mapName, sizeof(mapName));

    int playerLimit = GetQuickStatsCapacity();
    int playerCount = GetQuickStatsPlayerCount();

    char filename[64];
    Format(filename, sizeof(filename), StrEqual(serverPort, "27015") ? "quickstats.txt" : "server%s_quickstats.txt", serverPort);
    BuildPath(Path_SM, g_sQuickStatsPath, sizeof(g_sQuickStatsPath), "/logs/connections/%s", filename);

    char fileContent[8192];
    int pos = 0;
    pos += Format(fileContent[pos], sizeof(fileContent) - pos,
        "Hostname:%s\nPort:%s\nPlayer Count:%d/%d\nMap Name:%s\n",
        hostname, serverPort, playerCount, playerLimit, mapName);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client))
        {
            continue;
        }

        PlayerStats stats;
        BuildPlayerStats(client, stats);

        char playerName[64];
        GetClientName(client, playerName, sizeof(playerName));

        pos += Format(fileContent[pos], sizeof(fileContent) - pos,
            "Player %d: %s[X]%s[X]%d[X]%d[X]%d[X]%d[X]%d[X]%d[X]%s[X]%s\n",
            client,
            playerName,
            stats.Class,
            stats.Killstreak,
            stats.Score,
            stats.Frags,
            stats.Deaths,
            stats.Assists,
            stats.Damage,
            stats.Team,
            stats.Time);
    }

    File file = OpenFile(g_sQuickStatsPath, "w");
    if (file != null)
    {
        WriteFileString(file, fileContent, false);
        delete file;
    }
    else
    {
        LogError("Failed to open quickstats file: %s", g_sQuickStatsPath);
    }

    return Plugin_Continue;
}

void BuildPlayerStats(int client, PlayerStats stats)
{
    if (IsClientInGame(client))
    {
        stats.Killstreak = GetEntProp(client, Prop_Send, "m_nStreaks");
        stats.Score = GetEntProp(client, Prop_Send, "m_iPoints");
        stats.Frags = GetClientFrags(client);
        stats.Deaths = GetClientDeaths(client);
        stats.Assists = GetEntProp(client, Prop_Send, "m_iKillAssists");
        stats.Damage = GetEntProp(client, Prop_Send, "m_iDamageDone");

        int team = GetClientTeam(client);
        if (team == 2)
        {
            strcopy(stats.Team, sizeof(stats.Team), "RedTeam");
        }
        else if (team == 3)
        {
            strcopy(stats.Team, sizeof(stats.Team), "BlueTeam");
        }
        else
        {
            strcopy(stats.Team, sizeof(stats.Team), "SpectatorTeam");
        }

        if (IsPlayerAlive(client))
        {
            int classId = GetEntProp(client, Prop_Send, "m_iClass");
            Format(stats.Class, sizeof(stats.Class), "Class%d", classId);
        }
        else
        {
            strcopy(stats.Class, sizeof(stats.Class), "Respawning");
        }

        if (!IsFakeClient(client))
        {
            GetFormattedTime(RoundToCeil(GetClientTime(client)), stats.Time, sizeof(stats.Time));
        }
        else
        {
            strcopy(stats.Time, sizeof(stats.Time), "BOT");
        }
        return;
    }

    strcopy(stats.Class, sizeof(stats.Class), "Respawning");
    strcopy(stats.Team, sizeof(stats.Team), "SpectatorTeam");
    strcopy(stats.Time, sizeof(stats.Time), "00:00:00");
    stats.Killstreak = 0;
    stats.Score = 0;
    stats.Frags = 0;
    stats.Deaths = 0;
    stats.Assists = 0;
    stats.Damage = 0;
}

void GetAnalyticsMapName(char[] mapName, int maxLen)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_CurrentNormalizedMap") == FeatureStatus_Available
        && DGM_CurrentNormalizedMap(mapName, maxLen))
    {
        return;
    }

    GetCurrentMap(mapName, maxLen);
    if (GetFeatureStatus(FeatureType_Native, "DGM_NormalizeMapName") == FeatureStatus_Available)
    {
        DGM_NormalizeMapName(mapName, mapName, maxLen);
    }
}

void GetAnalyticsGamemode(char[] gamemode, int maxLen)
{
    strcopy(gamemode, maxLen, "default");
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") == FeatureStatus_Available)
    {
        DGM_GetGameModeKey(gamemode, maxLen);
    }
}

int GetQuickStatsCapacity()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetServerCapacity") == FeatureStatus_Available)
    {
        int capacity = DGM_GetServerCapacity();
        if (capacity > 0)
        {
            return capacity;
        }
    }

    return GetVisibleMaxPlayers();
}

int GetQuickStatsPlayerCount()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") == FeatureStatus_Available)
    {
        return DGM_RealPlayerCount();
    }

    return GetClientCount(false);
}

int CountConnectedHumans()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientConnected(client) && !IsFakeClient(client))
        {
            count++;
        }
    }

    return count;
}

int GetVisibleMaxPlayers()
{
    ConVar visibleMax = FindConVar("sv_visiblemaxplayers");
    if (visibleMax != null)
    {
        int value = visibleMax.IntValue;
        if (value > 0)
        {
            return value;
        }
    }

    return MaxClients;
}

int GetHostPort()
{
    ConVar hostPort = FindConVar("hostport");
    if (hostPort == null)
    {
        return 0;
    }

    return hostPort.IntValue;
}

void GetClientNetworkInfo(int client, char[] rawIp, int rawLen, char[] maskedIp, int maskedLen, char[] country, int countryLen)
{
    if (!GetClientIP(client, rawIp, rawLen, false))
    {
        strcopy(rawIp, rawLen, "Unknown");
        strcopy(maskedIp, maskedLen, "Unknown");
        strcopy(country, countryLen, "Unknown");
        return;
    }

    if (!GeoipCountry(rawIp, country, countryLen))
    {
        strcopy(country, countryLen, "Unknown");
    }

    MaskIPv4LastOctet(rawIp, maskedIp, maskedLen);
}

void MaskIPv4LastOctet(const char[] ipAddress, char[] output, int maxlen)
{
    int firstDot = -1;
    int secondDot = -1;
    int thirdDot = -1;

    for (int i = 0; ipAddress[i] != '\0'; i++)
    {
        if (ipAddress[i] != '.')
        {
            continue;
        }

        if (firstDot == -1)
        {
            firstDot = i;
        }
        else if (secondDot == -1)
        {
            secondDot = i;
        }
        else if (thirdDot == -1)
        {
            thirdDot = i;
        }
        else
        {
            strcopy(output, maxlen, "Unknown");
            return;
        }
    }

    if (firstDot == -1 || secondDot == -1 || thirdDot == -1 || ipAddress[thirdDot + 1] == '\0')
    {
        strcopy(output, maxlen, "Unknown");
        return;
    }

    strcopy(output, maxlen, ipAddress);
    output[thirdDot + 1] = '\0';
    StrCat(output, maxlen, "0");
}

void GetFormattedTime(int seconds, char[] buffer, int maxLen)
{
    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    int secs = seconds % 60;
    Format(buffer, maxLen, "%02d:%02d:%02d", hours, minutes, secs);
}

void GetWeekdayHour(int timestamp, int &weekday, int &hourOfDay)
{
    char buffer[8];

    FormatTime(buffer, sizeof(buffer), "%w", timestamp);
    weekday = StringToInt(buffer);

    FormatTime(buffer, sizeof(buffer), "%H", timestamp);
    hourOfDay = StringToInt(buffer);
}

void InitializeLogPath(const char[] path)
{
    char filepath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filepath, sizeof(filepath), path);
    if (!DirExists(filepath))
    {
        CreateDirectory(filepath, 511, true);
        if (!DirExists(filepath))
        {
            LogMessage("Failed to create directory at %s - Please manually create that path and reload this plugin.", path);
        }
    }
}

bool IsPlayerAdmin(int client)
{
    return CheckCommandAccess(client, "Generic_admin", ADMFLAG_GENERIC, false);
}
