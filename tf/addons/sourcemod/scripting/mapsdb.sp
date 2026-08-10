#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#define REQUIRE_PLUGIN

#include "include/database.inc"

#define MAPSDB_DEFAULT_CFG "default"
#define MAPSDB_SECRET_CFG "secrets"
#define MAPSDB_SAMPLE_INTERVAL 600.0
#define MAPSDB_POPULATION_SAMPLE_INTERVAL_DEFAULT 30.0
#define MAPSDB_PLUGIN_STATS_FLUSH_INTERVAL_DEFAULT "30.0"
#define MAPSDB_DB_CONFIG "default"
#define MAPSDB_QUERY_MAX 4096
#define MAPSDB_SESSION_TABLE "map_statistics_sessions"
#define MAPSDB_POPULATION_TABLE "server_population_statistics_samples"

char g_sCurrentMap[PLATFORM_MAX_PATH];
char g_sCurrentGamemode[32];
char g_sMapSessionId[64];

Database g_hDb = null;
Handle g_hSampleTimer = null;
Handle g_hPopulationSampleTimer = null;
Handle g_hDatabaseReconnectTimer = null;
ConVar g_cvPopulationSampleInterval = null;
ConVar g_cvSampleDebug = null;
bool g_bLateLoad = false;
bool g_bDbReady = false;
bool g_bDbConnecting = false;
int g_iMapStartedAt = 0;
int g_iRoundStartedAt = 0;
int g_iLastPopulationSampleAt = 0;
int g_iSampleSequence = 0;
int g_iJoiningPlayers = 0;
int g_iLeavingPlayers = 0;
bool g_bRoundRunning = false;

public Plugin myinfo =
{
    name = "MapsDB Loader",
    author = "Hombre",
    description = "Executes mapsdb configs and logs periodic map popularity samples",
    version = "1.1",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    g_bLateLoad = late;
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_RealPlayerCount");
    MarkNativeAsOptional("DGM_RealTeamPlayerCount");
    MarkNativeAsOptional("DGM_GetServerCapacity");
    MarkNativeAsOptional("DGM_IsRoundRunning");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvPopulationSampleInterval = CreateConVar(
        "sm_mapsdb_population_sample_interval",
        "30.0",
        "Seconds between detailed MapsDB server_population_statistics_samples writes.",
        _,
        true,
        10.0);
    CreateConVar(
        "sm_mapsdb_plugin_statistics_flush_interval",
        MAPSDB_PLUGIN_STATS_FLUSH_INTERVAL_DEFAULT,
        "Seconds between plugin statistics SQL queue flushes.",
        _,
        true,
        1.0);
    g_cvSampleDebug = CreateConVar(
        "sm_mapsdb_sample_debug",
        "0",
        "Print MapsDB sample writes to server console.",
        _,
        true,
        0.0,
        true,
        1.0);

    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_win", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_stalemate", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("teamplay_game_over", Event_RoundEnd, EventHookMode_PostNoCopy);

    ConnectMapsDb();

    if (g_bLateLoad)
    {
        OnMapStart();
    }
}

public void OnPluginEnd()
{
    FinalizeCurrentMapSession("plugin_end");
    StopSampleTimer();
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_hDb, g_bDbReady);
    g_bDbConnecting = false;
}

public void OnMapStart()
{
    g_iMapStartedAt = GetTime();
    g_iRoundStartedAt = 0;
    g_iLastPopulationSampleAt = g_iMapStartedAt;
    g_iSampleSequence = 0;
    g_iJoiningPlayers = 0;
    g_iLeavingPlayers = 0;
    g_bRoundRunning = false;

    UpdateCurrentMapName(g_sCurrentMap, sizeof(g_sCurrentMap));
    UpdateGamemodeKey();
    BuildMapSessionId(g_sMapSessionId, sizeof(g_sMapSessionId));

    CreateTimer(5.0, Timer_RunDefaultConfig, _, TIMER_FLAG_NO_MAPCHANGE);

    StopSampleTimer();
    g_hSampleTimer = CreateTimer(MAPSDB_SAMPLE_INTERVAL, Timer_RecordPopularitySample, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    StartPopulationSampleTimer();
}

public void OnMapEnd()
{
    FinalizeCurrentMapSession("map_end");
    StopSampleTimer();
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        g_iJoiningPlayers++;
    }
}

public void OnClientDisconnect(int client)
{
    if (!IsFakeClient(client))
    {
        g_iLeavingPlayers++;
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_iRoundStartedAt = GetTime();
    g_bRoundRunning = true;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundRunning = false;
}

public void OnConfigsExecuted()
{
    ConVar hostnameCvar = FindConVar("hostname");
    if (hostnameCvar == null)
    {
        return;
    }

    char hostname[128];
    hostnameCvar.GetString(hostname, sizeof(hostname));

    if (StrEqual(hostname, "Team Fortress", false))
    {
        PrintToServer("[MapsDB] Hostname isn't set. Executing mapsdb/server_once.cfg");
        ServerCommand("exec mapsdb/server_once.cfg");
    }
}

public Action Timer_RunDefaultConfig(Handle timer)
{
    ExecMapsDbConfig(MAPSDB_DEFAULT_CFG);
    CreateTimer(1.0, Timer_RunGamemodeConfig, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

public Action Timer_RunGamemodeConfig(Handle timer)
{
    UpdateGamemodeKey();
    ExecMapsDbConfig(g_sCurrentGamemode);
    CreateTimer(1.0, Timer_RunMapConfig, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

public Action Timer_RunMapConfig(Handle timer)
{
    ExecMapsDbConfig(g_sCurrentMap);
    CreateTimer(1.0, Timer_RunSecretsConfig, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

public Action Timer_RunSecretsConfig(Handle timer)
{
    ExecMapsDbConfig(MAPSDB_SECRET_CFG);
    return Plugin_Stop;
}

public Action Timer_RecordPopularitySample(Handle timer)
{
    if (!KogasaSql_IsReady(g_hDb, g_bDbReady))
    {
        ConnectMapsDb();
        return Plugin_Continue;
    }

    char mapName[128];
    UpdateCurrentMapName(mapName, sizeof(mapName));

    if (!mapName[0])
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }

    if (StrContains(mapName, "mge_", false) != -1)
    {
        return Plugin_Continue;
    }

    int playerCount = GetPopularityPlayerCount();
    int now = GetTime();

    char escapedMap[256];
    KogasaSql_Escape(g_hDb, mapName, escapedMap, sizeof(escapedMap), "MapsDB");

    char query[512];
    FormatEx(query, sizeof(query),
        "INSERT INTO mapsdb_popularity_log (map_name, player_count, sampled_at) VALUES ('%s', %d, %d)",
        escapedMap, playerCount, now);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);

    FormatEx(query, sizeof(query),
        "INSERT INTO mapsdb (map_name, popularity) VALUES ('%s', %d) ON DUPLICATE KEY UPDATE popularity = popularity + %d",
        escapedMap, playerCount, playerCount);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);

    if (IsSampleDebugEnabled())
    {
        PrintToServer("[MapsDB] Recorded popularity sample for '%s' (+%d)", mapName, playerCount);
    }

    return Plugin_Continue;
}

public Action Timer_RecordPopulationSample(Handle timer)
{
    if (!KogasaSql_IsReady(g_hDb, g_bDbReady))
    {
        ConnectMapsDb();
        return Plugin_Continue;
    }

    char mapName[128];
    UpdateCurrentMapName(mapName, sizeof(mapName));
    if (!mapName[0])
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }

    if (StrContains(mapName, "mge_", false) != -1)
    {
        return Plugin_Continue;
    }

    char gamemode[32];
    UpdateGamemodeKey();
    strcopy(gamemode, sizeof(gamemode), g_sCurrentGamemode);
    if (!gamemode[0])
    {
        strcopy(gamemode, sizeof(gamemode), "default");
    }

    int now = GetTime();
    int playerCount = GetPopulationPlayerCount();
    int visibleMax = GetServerCapacity();
    int redCount = GetRealTeamPlayerCount(2);
    int bluCount = GetRealTeamPlayerCount(3);
    int spectatorCount = CountSpectatorPlayers();
    bool roundRunning = IsRoundRunning();
    int mapElapsed = GetMapElapsedSeconds(now);
    int roundElapsed = GetRoundElapsedSeconds(now, roundRunning);
    int hostPort = GetHostPort();
    int sampleSequence = ++g_iSampleSequence;
    int sampleDelta = GetPopulationSampleDeltaSeconds(now);
    int playerSecondsDelta = playerCount * sampleDelta;
    int joiningPlayers = g_iJoiningPlayers;
    int leavingPlayers = g_iLeavingPlayers;
    int weekday;
    int hourOfDay;
    GetWeekdayHour(now, weekday, hourOfDay);

    g_iJoiningPlayers = 0;
    g_iLeavingPlayers = 0;
    g_iLastPopulationSampleAt = now;

    if (!g_sMapSessionId[0])
    {
        BuildMapSessionId(g_sMapSessionId, sizeof(g_sMapSessionId));
    }

    char escapedMap[256];
    char escapedGamemode[96];
    char escapedSessionId[128];
    KogasaSql_Escape(g_hDb, mapName, escapedMap, sizeof(escapedMap), "MapsDB");
    KogasaSql_Escape(g_hDb, gamemode, escapedGamemode, sizeof(escapedGamemode), "MapsDB");
    KogasaSql_Escape(g_hDb, g_sMapSessionId, escapedSessionId, sizeof(escapedSessionId), "MapsDB");

    char query[2048];
    FormatEx(query, sizeof(query),
        "INSERT INTO " ... MAPSDB_POPULATION_TABLE ... " (sampled_at, host_port, map_session_id, sample_sequence, map_name, gamemode, player_count, visible_max, red_count, blu_count, spectator_count, map_elapsed_seconds, round_elapsed_seconds, round_running, weekday, hour_of_day, joining_players, leaving_players, player_seconds_delta) VALUES (%d, %d, '%s', %d, '%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
        now,
        hostPort,
        escapedSessionId,
        sampleSequence,
        escapedMap,
        escapedGamemode,
        playerCount,
        visibleMax,
        redCount,
        bluCount,
        spectatorCount,
        mapElapsed,
        roundElapsed,
        roundRunning ? 1 : 0,
        weekday,
        hourOfDay,
        joiningPlayers,
        leavingPlayers,
        playerSecondsDelta);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);

    UpsertMapSessionRollup(
        now,
        hostPort,
        escapedSessionId,
        escapedMap,
        escapedGamemode,
        playerCount,
        sampleDelta,
        playerSecondsDelta,
        joiningPlayers,
        leavingPlayers,
        weekday,
        hourOfDay);

    if (IsSampleDebugEnabled())
    {
        PrintToServer("[MapsDB] Recorded population sample for '%s' session=%s seq=%d pop=%d red=%d blu=%d spec=%d joins=%d leaves=%d elapsed=%d",
            mapName,
            g_sMapSessionId,
            sampleSequence,
            playerCount,
            redCount,
            bluCount,
            spectatorCount,
            joiningPlayers,
            leavingPlayers,
            mapElapsed);
    }

    return Plugin_Continue;
}

public void SQL_OnWriteComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[MapsDB] SQL write failed: %s", error);

    if (KogasaSql_IsTransientError(error))
    {
        ScheduleMapsDbReconnect(KOGASA_SQL_RECONNECT_FAST_DELAY);
    }
}

public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        g_bDbConnecting = false;
        g_bDbReady = false;
        LogError("[MapsDB] Database connect failed: %s", error);
        ScheduleMapsDbReconnect(KOGASA_SQL_RECONNECT_DELAY);
        return;
    }

    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_hDb, g_bDbReady);

    g_hDb = view_as<Database>(hndl);
    g_bDbConnecting = false;
    g_bDbReady = true;
    EnsurePopulationSampleSchema();
    EnsureMapSessionSchema();
}

static void ConnectMapsDb()
{
    if (g_bDbConnecting)
    {
        return;
    }

    if (!KogasaSql_CheckConfigOrLog("MapsDB", MAPSDB_DB_CONFIG))
    {
        return;
    }

    g_bDbConnecting = true;
    SQL_TConnect(SQL_OnConnect, MAPSDB_DB_CONFIG);
}

static void ScheduleMapsDbReconnect(float delay)
{
    g_bDbReady = false;

    if (g_hDatabaseReconnectTimer != null)
    {
        return;
    }

    g_hDatabaseReconnectTimer = CreateTimer(delay, Timer_ReconnectMapsDb);
}

public Action Timer_ReconnectMapsDb(Handle timer)
{
    g_hDatabaseReconnectTimer = null;
    ConnectMapsDb();
    return Plugin_Stop;
}

static void EnsurePopulationSampleSchema()
{
    if (g_hDb == null)
    {
        return;
    }

    char query[MAPSDB_QUERY_MAX];
    query[0] = '\0';
    StrCat(query, sizeof(query), "CREATE TABLE IF NOT EXISTS " ... MAPSDB_POPULATION_TABLE ... " (");
    StrCat(query, sizeof(query), "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,");
    StrCat(query, sizeof(query), "sampled_at INT NOT NULL,");
    StrCat(query, sizeof(query), "host_port INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_session_id VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "sample_sequence INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_name VARCHAR(128) NOT NULL,");
    StrCat(query, sizeof(query), "gamemode VARCHAR(32) NOT NULL,");
    StrCat(query, sizeof(query), "player_count INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "visible_max INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "red_count INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "blu_count INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "spectator_count INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_elapsed_seconds INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "round_elapsed_seconds INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "round_running TINYINT(1) NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "weekday TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "hour_of_day TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "joining_players INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "leaving_players INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "player_seconds_delta INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "KEY idx_sampled_at (sampled_at),");
    StrCat(query, sizeof(query), "KEY idx_map_name (map_name),");
    StrCat(query, sizeof(query), "KEY idx_host_port (host_port),");
    StrCat(query, sizeof(query), "KEY idx_map_sampled_at (map_name, sampled_at),");
    StrCat(query, sizeof(query), "KEY idx_host_sampled_at (host_port, sampled_at),");
    StrCat(query, sizeof(query), "KEY idx_map_session (map_session_id),");
    StrCat(query, sizeof(query), "KEY idx_weekday_hour (weekday, hour_of_day)");
    StrCat(query, sizeof(query), ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, query);

    query[0] = '\0';
    StrCat(query, sizeof(query), "ALTER TABLE " ... MAPSDB_POPULATION_TABLE ... " ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS map_session_id VARCHAR(64) NOT NULL DEFAULT '', ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS sample_sequence INT NOT NULL DEFAULT 0, ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS weekday TINYINT NOT NULL DEFAULT 0, ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS hour_of_day TINYINT NOT NULL DEFAULT 0, ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS joining_players INT NOT NULL DEFAULT 0, ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS leaving_players INT NOT NULL DEFAULT 0, ");
    StrCat(query, sizeof(query), "ADD COLUMN IF NOT EXISTS player_seconds_delta INT NOT NULL DEFAULT 0");
    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, query);

    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, "CREATE INDEX IF NOT EXISTS idx_map_session ON " ... MAPSDB_POPULATION_TABLE ... " (map_session_id)");
    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, "CREATE INDEX IF NOT EXISTS idx_weekday_hour ON " ... MAPSDB_POPULATION_TABLE ... " (weekday, hour_of_day)");
}

static void EnsureMapSessionSchema()
{
    if (g_hDb == null)
    {
        return;
    }

    char query[MAPSDB_QUERY_MAX];
    query[0] = '\0';
    StrCat(query, sizeof(query), "CREATE TABLE IF NOT EXISTS " ... MAPSDB_SESSION_TABLE ... " (");
    StrCat(query, sizeof(query), "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,");
    StrCat(query, sizeof(query), "map_session_id VARCHAR(64) NOT NULL,");
    StrCat(query, sizeof(query), "host_port INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_name VARCHAR(128) NOT NULL,");
    StrCat(query, sizeof(query), "gamemode VARCHAR(32) NOT NULL,");
    StrCat(query, sizeof(query), "started_at INT NOT NULL,");
    StrCat(query, sizeof(query), "ended_at INT NOT NULL,");
    StrCat(query, sizeof(query), "duration INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "start_players INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "end_players INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "peak_players INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "avg_players DECIMAL(8,2) NOT NULL DEFAULT 0.00,");
    StrCat(query, sizeof(query), "player_seconds BIGINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "joins INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "leaves INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "sample_count INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "end_reason VARCHAR(32) NOT NULL DEFAULT 'active',");
    StrCat(query, sizeof(query), "weekday TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "hour_of_day TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "updated_at INT NOT NULL,");
    StrCat(query, sizeof(query), "UNIQUE KEY uniq_host_session (host_port, map_session_id),");
    StrCat(query, sizeof(query), "KEY idx_map_started (map_name, started_at),");
    StrCat(query, sizeof(query), "KEY idx_started_at (started_at),");
    StrCat(query, sizeof(query), "KEY idx_peak_players (peak_players),");
    StrCat(query, sizeof(query), "KEY idx_weekday_hour (weekday, hour_of_day)");
    StrCat(query, sizeof(query), ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    SQL_TQuery(g_hDb, SQL_OnSchemaComplete, query);
}

static void UpsertMapSessionRollup(
    int now,
    int hostPort,
    const char[] escapedSessionId,
    const char[] escapedMap,
    const char[] escapedGamemode,
    int playerCount,
    int sampleDelta,
    int playerSecondsDelta,
    int joiningPlayers,
    int leavingPlayers,
    int weekday,
    int hourOfDay)
{
    if (!KogasaSql_IsReady(g_hDb, g_bDbReady) || !escapedSessionId[0])
    {
        return;
    }

    int startedAt = g_iMapStartedAt > 0 ? g_iMapStartedAt : now;
    int duration = now - startedAt;
    if (duration < sampleDelta)
    {
        duration = sampleDelta;
    }
    if (duration < 1)
    {
        duration = 1;
    }

    char query[MAPSDB_QUERY_MAX];
    FormatEx(query, sizeof(query),
        "INSERT INTO " ... MAPSDB_SESSION_TABLE ... " "
        ... "(map_session_id, host_port, map_name, gamemode, started_at, ended_at, duration, start_players, end_players, peak_players, avg_players, player_seconds, joins, leaves, sample_count, end_reason, weekday, hour_of_day, updated_at) "
        ... "VALUES ('%s', %d, '%s', '%s', %d, %d, %d, %d, %d, %d, %.2f, %d, %d, %d, 1, 'active', %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "ended_at = VALUES(ended_at), "
        ... "duration = GREATEST(VALUES(ended_at) - started_at, VALUES(duration), duration), "
        ... "end_players = VALUES(end_players), "
        ... "peak_players = GREATEST(peak_players, VALUES(peak_players)), "
        ... "player_seconds = player_seconds + VALUES(player_seconds), "
        ... "joins = joins + VALUES(joins), "
        ... "leaves = leaves + VALUES(leaves), "
        ... "sample_count = sample_count + 1, "
        ... "avg_players = ROUND(player_seconds / GREATEST(duration, 1), 2), "
        ... "end_reason = 'active', "
        ... "updated_at = VALUES(updated_at)",
        escapedSessionId,
        hostPort,
        escapedMap,
        escapedGamemode,
        startedAt,
        now,
        duration,
        playerCount,
        playerCount,
        playerCount,
        float(playerCount),
        playerSecondsDelta,
        joiningPlayers,
        leavingPlayers,
        weekday,
        hourOfDay,
        now);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);
}

static void FinalizeCurrentMapSession(const char[] reason)
{
    if (!KogasaSql_IsReady(g_hDb, g_bDbReady) || !g_sMapSessionId[0])
    {
        return;
    }

    int now = GetTime();
    int hostPort = GetHostPort();

    char escapedSessionId[128];
    char escapedReason[64];
    KogasaSql_Escape(g_hDb, g_sMapSessionId, escapedSessionId, sizeof(escapedSessionId), "MapsDB");
    KogasaSql_Escape(g_hDb, reason, escapedReason, sizeof(escapedReason), "MapsDB");

    char query[1024];
    FormatEx(query, sizeof(query),
        "UPDATE " ... MAPSDB_SESSION_TABLE ... " "
        ... "SET ended_at = GREATEST(ended_at, %d), "
        ... "duration = GREATEST(%d - started_at, duration), "
        ... "avg_players = ROUND(player_seconds / GREATEST(GREATEST(%d - started_at, duration), 1), 2), "
        ... "end_reason = '%s', "
        ... "updated_at = %d "
        ... "WHERE host_port = %d AND map_session_id = '%s'",
        now,
        now,
        now,
        escapedReason,
        now,
        hostPort,
        escapedSessionId);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);
}

public void SQL_OnSchemaComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[MapsDB] SQL schema update failed: %s", error);
    if (KogasaSql_IsTransientError(error))
    {
        ScheduleMapsDbReconnect(KOGASA_SQL_RECONNECT_FAST_DELAY);
    }
}

static void StopSampleTimer()
{
    if (g_hSampleTimer != null)
    {
        KillTimer(g_hSampleTimer);
        g_hSampleTimer = null;
    }

    if (g_hPopulationSampleTimer != null)
    {
        KillTimer(g_hPopulationSampleTimer);
        g_hPopulationSampleTimer = null;
    }
}

static void StartPopulationSampleTimer()
{
    float interval = MAPSDB_POPULATION_SAMPLE_INTERVAL_DEFAULT;
    if (g_cvPopulationSampleInterval != null)
    {
        interval = g_cvPopulationSampleInterval.FloatValue;
    }

    if (interval < 10.0)
    {
        interval = 10.0;
    }

    g_hPopulationSampleTimer = CreateTimer(interval, Timer_RecordPopulationSample, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

static int GetPopularityPlayerCount()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") == FeatureStatus_Available)
    {
        return DGM_RealPlayerCount();
    }

    return CountHumanPlayers();
}

static int GetPopulationPlayerCount()
{
    return GetClientCount(false);
}

static int GetRealTeamPlayerCount(int team)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealTeamPlayerCount") == FeatureStatus_Available)
    {
        return DGM_RealTeamPlayerCount(team);
    }

    return CountHumanPlayersOnTeam(team, false);
}

static int GetServerCapacity()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetServerCapacity") == FeatureStatus_Available)
    {
        return DGM_GetServerCapacity();
    }

    return MaxClients;
}

static bool IsRoundRunning()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_IsRoundRunning") == FeatureStatus_Available)
    {
        return DGM_IsRoundRunning();
    }

    return g_bRoundRunning;
}

static int GetMapElapsedSeconds(int now)
{
    if (g_iMapStartedAt <= 0 || now < g_iMapStartedAt)
    {
        return 0;
    }

    return now - g_iMapStartedAt;
}

static int GetPopulationSampleDeltaSeconds(int now)
{
    if (g_iLastPopulationSampleAt <= 0 || now <= g_iLastPopulationSampleAt)
    {
        return 0;
    }

    return now - g_iLastPopulationSampleAt;
}

static int GetRoundElapsedSeconds(int now, bool roundRunning)
{
    if (!roundRunning || g_iRoundStartedAt <= 0 || now < g_iRoundStartedAt)
    {
        return 0;
    }

    return now - g_iRoundStartedAt;
}

static int GetHostPort()
{
    ConVar hostPort = FindConVar("hostport");
    if (hostPort == null)
    {
        return 0;
    }

    return hostPort.IntValue;
}

static void BuildMapSessionId(char[] output, int maxlen)
{
    int mapStartedAt = g_iMapStartedAt;
    if (mapStartedAt <= 0)
    {
        mapStartedAt = GetTime();
    }

    Format(output, maxlen, "%d-%d", GetHostPort(), mapStartedAt);
}

static void GetWeekdayHour(int timestamp, int &weekday, int &hourOfDay)
{
    char buffer[8];

    FormatTime(buffer, sizeof(buffer), "%w", timestamp);
    weekday = StringToInt(buffer);

    FormatTime(buffer, sizeof(buffer), "%H", timestamp);
    hourOfDay = StringToInt(buffer);
}

static bool IsSampleDebugEnabled()
{
    return g_cvSampleDebug != null && g_cvSampleDebug.BoolValue;
}

static void UpdateCurrentMapName(char[] output, int outputLen)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_CurrentNormalizedMap") == FeatureStatus_Available
        && DGM_CurrentNormalizedMap(output, outputLen))
    {
        return;
    }

    char rawMap[PLATFORM_MAX_PATH];
    GetCurrentMap(rawMap, sizeof(rawMap));
    UpdateNormalizedMapName(rawMap, output, outputLen);
}

static int CountHumanPlayers()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }
        count++;
    }

    return count;
}

static int CountHumanPlayersOnTeam(int team, bool includeUnassigned)
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        int clientTeam = GetClientTeam(client);
        if (clientTeam == team || (includeUnassigned && team == 1 && clientTeam <= 1))
        {
            count++;
        }
    }

    return count;
}

static int CountSpectatorPlayers()
{
    return CountHumanPlayersOnTeam(1, true);
}

static void UpdateNormalizedMapName(const char[] input, char[] output, int outputLen)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_NormalizeMapName") == FeatureStatus_Available
        && DGM_NormalizeMapName(input, output, outputLen))
    {
        return;
    }

    strcopy(output, outputLen, input);
    TrimString(output);
}

static void UpdateGamemodeKey()
{
    strcopy(g_sCurrentGamemode, sizeof(g_sCurrentGamemode), "default");
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") == FeatureStatus_Available)
    {
        DGM_GetGameModeKey(g_sCurrentGamemode, sizeof(g_sCurrentGamemode));
        ResolveMapsDbConfigName(g_sCurrentGamemode, g_sCurrentGamemode, sizeof(g_sCurrentGamemode));
    }
}

static void ExecMapsDbConfig(const char[] configName)
{
    if (configName[0] == '\0')
    {
        return;
    }

    char resolvedName[32];
    ResolveMapsDbConfigName(configName, resolvedName, sizeof(resolvedName));

    ServerCommand("exec mapsdb/%s.cfg", resolvedName);
    ServerExecute();
}

static void ResolveMapsDbConfigName(const char[] configName, char[] resolvedName, int maxlen)
{
    if (StrEqual(configName, "pl", false))
    {
        strcopy(resolvedName, maxlen, "payload");
        return;
    }

    if (StrEqual(configName, "plr", false))
    {
        strcopy(resolvedName, maxlen, "payloadrace");
        return;
    }

    if (StrEqual(configName, "ad", false))
    {
        strcopy(resolvedName, maxlen, "adcp");
        return;
    }

    strcopy(resolvedName, maxlen, configName);
}
