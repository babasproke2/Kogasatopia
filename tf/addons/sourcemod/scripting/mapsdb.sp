#include <sourcemod>
#include "include/dgm_api.inc"

#pragma semicolon 1
#pragma newdecls required

#define MAPSDB_DEFAULT_CFG "default"
#define MAPSDB_SECRET_CFG "secrets"
#define MAPSDB_SAMPLE_INTERVAL 600.0
#define MAPSDB_DB_CONFIG "default"

char g_sCurrentMap[PLATFORM_MAX_PATH];
char g_sCurrentGamemode[32];

Database g_hDb = null;
Handle g_hSampleTimer = null;
bool g_bLateLoad = false;

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
    return APLRes_Success;
}

public void OnPluginStart()
{
    ConnectMapsDb();

    if (g_bLateLoad)
    {
        OnMapStart();
    }
}

public void OnPluginEnd()
{
    StopSampleTimer();

    if (g_hDb != null)
    {
        delete g_hDb;
        g_hDb = null;
    }
}

public void OnMapStart()
{
    UpdateCurrentMapName(g_sCurrentMap, sizeof(g_sCurrentMap));
    UpdateGamemodeKey();

    CreateTimer(5.0, Timer_RunDefaultConfig, _, TIMER_FLAG_NO_MAPCHANGE);

    StopSampleTimer();
    g_hSampleTimer = CreateTimer(MAPSDB_SAMPLE_INTERVAL, Timer_RecordPopularitySample, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    StopSampleTimer();
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
        PrintToServer("[MapsDB] Hostname isn't set. Executing server_once.cfg");
        ServerCommand("exec server_once.cfg");
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
    if (g_hDb == null)
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
    SQL_EscapeString(g_hDb, mapName, escapedMap, sizeof(escapedMap));

    char query[512];
    FormatEx(query, sizeof(query),
        "INSERT INTO mapsdb_popularity_log (map_name, player_count, sampled_at) VALUES ('%s', %d, %d)",
        escapedMap, playerCount, now);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);

    FormatEx(query, sizeof(query),
        "INSERT INTO mapsdb (map_name, popularity) VALUES ('%s', %d) ON DUPLICATE KEY UPDATE popularity = popularity + %d",
        escapedMap, playerCount, playerCount);
    SQL_TQuery(g_hDb, SQL_OnWriteComplete, query);

    PrintToServer("[MapsDB] Recorded popularity sample for '%s' (+%d)", mapName, playerCount);
    return Plugin_Continue;
}

public void SQL_OnWriteComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[MapsDB] SQL write failed: %s", error);

    if (StrContains(error, "Lost connection", false) != -1 || StrContains(error, "server has gone away", false) != -1)
    {
        ConnectMapsDb();
    }
}

public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[MapsDB] Database connect failed: %s", error);
        return;
    }

    if (g_hDb != null)
    {
        delete g_hDb;
    }

    g_hDb = view_as<Database>(hndl);
}

static void ConnectMapsDb()
{
    SQL_TConnect(SQL_OnConnect, MAPSDB_DB_CONFIG);
}

static void StopSampleTimer()
{
    if (g_hSampleTimer != null)
    {
        KillTimer(g_hSampleTimer);
        g_hSampleTimer = null;
    }
}


static int GetPopularityPlayerCount()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") == FeatureStatus_Available)
    {
        return DGM_RealPlayerCount();
    }

    return CountHumanPlayers();
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
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") != FeatureStatus_Available)
    {
        return;
    }

    DGM_GetGameModeKey(g_sCurrentGamemode, sizeof(g_sCurrentGamemode));
}

static void ExecMapsDbConfig(const char[] configName)
{
    if (configName[0] == '\0')
    {
        return;
    }

    ServerCommand("exec mapsdb/%s.cfg", configName);
}
