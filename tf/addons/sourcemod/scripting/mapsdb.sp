#include <sourcemod>

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
    char rawMap[PLATFORM_MAX_PATH];
    GetCurrentMap(rawMap, sizeof(rawMap));
    NormalizeMapName(rawMap, g_sCurrentMap, sizeof(g_sCurrentMap));
    DetermineGamemode(g_sCurrentMap, g_sCurrentGamemode, sizeof(g_sCurrentGamemode));

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

    char rawMap[PLATFORM_MAX_PATH];
    char mapName[128];
    GetCurrentMap(rawMap, sizeof(rawMap));
    NormalizeMapName(rawMap, mapName, sizeof(mapName));

    if (!mapName[0])
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }

    if (StrContains(mapName, "mge_", false) != -1)
    {
        return Plugin_Continue;
    }

    int playerCount = CountHumanPlayers();
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

static void NormalizeMapName(const char[] input, char[] output, int outputLen)
{
    strcopy(output, outputLen, input);
    ReplaceStringEx(output, outputLen, "workshop\\", "");
    ReplaceStringEx(output, outputLen, "workshop/", "");

    int slash = FindCharInString(output, '/', true);
    if (slash != -1 && output[slash + 1] != '\0')
    {
        strcopy(output, outputLen, output[slash + 1]);
    }

    int backslash = FindCharInString(output, '\\', true);
    if (backslash != -1 && output[backslash + 1] != '\0')
    {
        strcopy(output, outputLen, output[backslash + 1]);
    }

    int dot = FindCharInString(output, '.');
    if (dot > 0)
    {
        output[dot] = '\0';
    }

    TrimString(output);
}

static void DetermineGamemode(const char[] mapName, char[] gamemode, int gamemodeLen)
{
    strcopy(gamemode, gamemodeLen, "default");

    if (StrContains(mapName, "ctf_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "ctf");
        return;
    }
    if (StrContains(mapName, "cp_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "cp");
        return;
    }
    if (StrContains(mapName, "pl_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "pl");
        return;
    }
    if (StrContains(mapName, "plr_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "plr");
        return;
    }
    if (StrContains(mapName, "koth_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "koth");
        return;
    }
    if (StrContains(mapName, "pd_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "pd");
        return;
    }
    if (StrContains(mapName, "sd_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "sd");
        return;
    }
    if (StrContains(mapName, "arena_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "arena");
        return;
    }
    if (StrContains(mapName, "mvm_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "mvm");
        return;
    }
}

static void ExecMapsDbConfig(const char[] configName)
{
    if (configName[0] == '\0')
    {
        return;
    }

    ServerCommand("exec mapsdb/%s.cfg", configName);
}
