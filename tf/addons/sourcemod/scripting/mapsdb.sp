#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define MAPSDB_EXEC_FORMAT "exec mapsdb/%s.cfg"
#define MAPSDB_DEFAULT_CFG "default"
#define MAPSDB_DEFAULT_CFG "secrets"

char g_sCurrentMap[PLATFORM_MAX_PATH];
char g_sCurrentGamemode[32];

public Plugin myinfo =
{
    name = "MapsDB Loader",
    author = "Codex",
    description = "Executes mapsdb configs for server, gamemode, and map",
    version = "1.0",
    url = ""
};

public void OnMapStart()
{
    GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
    DetermineGamemode(g_sCurrentMap, g_sCurrentGamemode, sizeof(g_sCurrentGamemode));

    CreateTimer(5.0, Timer_RunDefaultConfig, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
    char hostname[128];
    GetConVarString(FindConVar("hostname"), hostname, sizeof(hostname));

    if (StrEqual(hostname, "Team Fortress", false))
    {
        PrintToServer("[MapsDB] Hostname isn't set. Executing server_once.cfg");
        ServerCommand("exec server_once.cfg");
    }
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

static void ExecMapsDbConfig(const char[] configName)
{
    if (configName[0] == '\0')
    {
        return;
    }

    char command[PLATFORM_MAX_PATH];
    Format(command, sizeof(command), MAPSDB_EXEC_FORMAT, configName);
    ServerCommand("%s", command);
}
