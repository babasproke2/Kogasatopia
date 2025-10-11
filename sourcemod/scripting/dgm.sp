#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <tf2>
#include <controlpoints>

#define PLUGIN_VERSION "3.0"

ConVar g_cvEnabled;
ConVar g_cvHalveSetupTime;
ConVar g_cvAsymCapRespawn;
ConVar g_cvEnabledOverride;
ConVar g_cvRedTime;
ConVar g_cvBluTime;
ConVar g_cvAutoAddTime;
ConVar g_cvTimeOverride;
ConVar g_cvRespawnTime;
bool g_bSymmetrical;

int g_PointCaptures = 0;

ConVar g_cHostname;
ConVar g_hVisibleMaxPlayers;
ConVar g_cvDebug;

public Plugin myinfo = {
    name = "Gamemode Detector",
    author = "Hombre",
    description = "Handles gamemode settings and instant respawns for server operators. Control point features are WIP for the future.",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

public void OnPluginStart()
{
    g_cvEnabledOverride = CreateConVar("force_enable_respawns", "3", "Enable/Disable respawn times", _, true, 0.0, true, 3.0);
    g_cvTimeOverride = CreateConVar("respawn_otime", "0", "Override respawn time with this", _, true, 0.0, true, 16.0);
    g_cvRedTime = CreateConVar("respawn_redtime", "3.0", "Red respawn time length", _, true, 0.0, true, 16.0);
    g_cvBluTime = CreateConVar("respawn_blutime", "3.0", "Blu respawn time length", _, true, 0.0, true, 16.0);
    g_cvAutoAddTime = CreateConVar("sm_autoaddtime", "1", "Automatically extend koth times?", _, true, 0.0, true, 1.0);
    g_cvEnabled = CreateConVar("disable_respawn_times", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    g_cvAsymCapRespawn = CreateConVar("respawn_red_on_cap", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    g_cvRespawnTime = CreateConVar("respawn_time", "3.0", "Respawn time length", _, true, 0.0, true, 16.0);
    g_cvHalveSetupTime = CreateConVar("sm_halvesetuptime", "0", "Locate and reduce setup time by 50% - only enable this per-map or in gamemode configs", _, true, 0.0, true, 1.0);

    g_cvDebug = CreateConVar("sm_dgm_debug", "0", "Debug DetectGameMode to console", _, true, 0.0, true, 1.0);
    
    RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_KICK, "Toggles respawn times");
    RegAdminCmd("sm_noset", Command_ResetSetup, ADMFLAG_KICK, "Set round setup time to 10 seconds");

    g_cHostname = FindConVar("hostname");
    RegConsoleCmd("sm_stats", Command_Stats, "Show player count, map and hostname");
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("teamplay_round_start", Event_RoundActive);
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_Pre);
    HookEvent("teamplay_point_captured", Event_PointCaptured, EventHookMode_PostNoCopy);   
}

// Fires when a control point is captured
// This was created to be a QoL feature for asymmetrical gamemodes
public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    //This stuff is mostly WIP for dynamic changes on maps in the future
    // Asymmetrical: respawn all dead RED players
    if (g_cvAsymCapRespawn && !g_bSymmetrical)
    {    
        if (g_cvDebug) PrintToServer("Debug: respawning red players...");
        for (int i = 1; i <= MaxClients; i++)
            if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsPlayerAlive(i))
                TF2_RespawnPlayer(i);
    }

    // The rest of this is WIP for the future

    char cappers[256];
    event.GetString("cappers", cappers, sizeof(cappers));

    int firstCapper = cappers[0] - '0'; // players are encoded as ASCII digits
    int team = -1;
    int redSum = 0;
    int bluSum = 0;
    if (IsClientInGame(firstCapper))
    {
        team = GetClientTeam(firstCapper);
    }

    char teamName[8];
    switch (team)
    {
        case 2: 
        {
            strcopy(teamName, sizeof(teamName), "RED");
            redSum++;
        }
        case 3: 
        {
            strcopy(teamName, sizeof(teamName), "BLU");
            bluSum--;
        }
        default: 
        {
            strcopy(teamName, sizeof(teamName), "UNKNOWN");
        }
    }
    int finalSum = bluSum + redSum;
    g_PointCaptures++;
    if (g_cvDebug)
        PrintToServer("DGM Debug: Total captures: %d", g_PointCaptures);
        PrintToServer("DGM Debug: %s team captured a point. RED: %d, BLU: %d, sum: %d", teamName, redSum, bluSum, finalSum);
    return;
}

public Action Command_Stats(int client, int args)
{
    // Reject server console or invalid clients
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    // Player count (humans + bots)
    int playerCount = GetClientCount(false);

    // Current map name
    char map[64];
    GetCurrentMap(map, sizeof(map));

    // Hostname string
    char hostname[128];
    if (g_cHostname != null)
    {
        g_cHostname.GetString(hostname, sizeof(hostname));
    }
    else
    {
        strcopy(hostname, sizeof(hostname), "Unknown");
    }

    g_hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    int visMax = GetConVarInt(g_hVisibleMaxPlayers);

    // Respawn-related ConVars
    float respawnTime = GetConVarFloat(g_cvRespawnTime);
    float timeOverride = GetConVarFloat(g_cvTimeOverride);
    float redTime = GetConVarFloat(g_cvRedTime);
    float bluTime = GetConVarFloat(g_cvBluTime);
    int enabledRespawnOverride = GetConVarInt(g_cvEnabled);
    int asymCapRespawn = GetConVarInt(g_cvAsymCapRespawn);

    // Send the message to the caller
    PrintToChat(client,
        "\x01[Stats] Players: \x04%d\x01 | Map: \x04%s\x01 | Server: \x04%s\x01 | Max Players: \x04%i",
        playerCount, map, hostname, visMax);

    PrintToChat(client, "[Respawn] respawn_time: %.2f | respawn_otime: %.2f | red: %.2f | blu: %.2f | disable_respawn_times: %d | respawn_red_on_cap: %d",
        respawnTime, timeOverride, redTime, bluTime, enabledRespawnOverride, asymCapRespawn);

    return Plugin_Handled;
}

public Action Command_RespawnToggle(int client, int args)
{
    int currentValue = GetConVarInt(g_cvEnabledOverride);
    int newValue = (currentValue == 1 || currentValue == 3) ? 0 : 1;
    SetConVarInt(g_cvEnabledOverride, newValue);
    PrintToChat(client, "Respawn times %s", newValue == 0 ? "forced on" : "forced off");
    return Plugin_Handled;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    int override = GetConVarInt(g_cvEnabledOverride);
    float overridetime = GetConVarFloat(g_cvTimeOverride);

    if (!IsValidClient(client)) return;
    if (GetConVarInt(g_cvEnabled) == 1 || override == 1)
    {
        float time = overridetime != 0.0 ? overridetime : GetConVarFloat(g_cvRespawnTime);
        float bluTime = GetConVarFloat(g_cvBluTime);
        float redTime = GetConVarFloat(g_cvRedTime);
        int team = GetClientTeam(client);
        if (overridetime == 0.0 && bluTime != redTime)
        {
            if (team == 2) time = redTime;
            else if (team == 3) time = bluTime;
        }
        if (time > 0.0)
            CreateTimer(time, Timer_RespawnClient, client);
    }
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    if (g_cvTimeOverride != null)    g_cvTimeOverride.RestoreDefault();
    g_PointCaptures = 0;
    if (GetConVarInt(g_cvHalveSetupTime))
    {
        HalfSetupTime();
    }
    SetConVarInt(g_cvTimeOverride, 0);
	if (GetConVarInt(g_cvAutoAddTime)) {
		int entityTimer = FindEntityByClassname(-1, "tf_logic_koth");
		if (entityTimer > -1)
		{
			SetVariantInt(300);
			AcceptEntityInput(entityTimer, "SetBlueTimer");
			SetVariantInt(300);
			AcceptEntityInput(entityTimer, "SetRedTimer");
		}
	}
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    SetConVarInt(g_cvTimeOverride, 30);
    if (g_cvEnabledOverride != null) g_cvEnabledOverride.RestoreDefault();
    if (g_cvRedTime != null)         g_cvRedTime.RestoreDefault();
    if (g_cvBluTime != null)         g_cvBluTime.RestoreDefault();
}

public Action Timer_RespawnClient(Handle timer, int client)
{
    if (IsValidClient(client) && !IsPlayerAlive(client) && GetClientTeam(client) > 1) {
        TF2_RespawnPlayer(client);
    }
    return Plugin_Stop;
}

public Action Command_ResetSetup(int client, int args)
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt == -1)
    {
        if (client > 0) PrintToChat(client, "No team_round_timer entity found.");
        else PrintToServer("[SM] No team_round_timer entity found.");
        return Plugin_Handled;
    }

    int time = 10;
    SetVariantInt(time);
    AcceptEntityInput(timerEnt, "SetTime");

    if (client > 0) PrintToChatAll("Setup time reduced to %i seconds.", time);
    PrintToServer("[SM] Setup time set to %i seconds.", time);
    return Plugin_Handled;
}

public void HalfSetupTime()
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt != -1)
    {
        int time = 30;
        SetVariantInt(time);
        AcceptEntityInput(timerEnt, "SetTime");
        PrintToServer("[SM] Setup time set to %i seconds.", time);
    }
}

public Action DisableTruce()
{
    // Find the tf_gamerules entity
    int gamerules = FindEntityByClassname(-1, "tf_gamerules");
    if (gamerules == -1)
    {
        PrintToServer("[SM] No tf_gamerules entity found.");
        return Plugin_Handled;
    }

    // Prepare the variant for input
    int whale = 0; // false
    SetVariantInt(whale);

    // Call the entity input with the variant
    AcceptEntityInput(gamerules, "SetMapForcedTruceDuringBossFight", -1, -1, whale);

    PrintToServer("[SM] Set SetMapForcedTruceDuringBossFight in tf_gamerules to 0 (false)");
    return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client)) {
        RequestFrame(Frame_CheckPlayerCount);
    }
}

public void OnClientDisconnect(int client)
{
    if (!IsFakeClient(client)) {
        RequestFrame(Frame_CheckPlayerCount);
    }
}

public void Frame_CheckPlayerCount(any data)
{
    int playerCount = GetClientCount(false);
    if (!g_bSymmetrical) {
        ServerCommand(playerCount < 11 ? "exec d_highpop_pl.cfg" : "exec d_lowpop.cfg");
        if (g_cvDebug) PrintToServer("DGM Debug: Playercount %i, gamemode is not symmetrical.", playerCount);
    } else {
        ServerCommand(playerCount < 7 ? "exec d_highpop.cfg" : "exec d_lowpop.cfg");
        if (g_cvDebug) PrintToServer("DGM Debug: Playercount %i, gamemode is not symmetrical.", playerCount);
    }
}

static bool IsValidClient(int client)
{
    return (client >= 1 && client <= MaxClients) && IsClientInGame(client);
}

public void OnConfigsExecuted()
{
	DetectGameMode();
}

static void DetectGameMode()
{
    TF2_GameMode gameMode = TF2_DetectGameMode();
    CreateDefaultConfigs();
    bool sym = false;
    if (IsMedievalMap()) {
        ServerCommand("exec d_medieval.cfg");
    }
    else if (IsPDMap()) {
        ServerCommand("exec d_pd.cfg");
        sym = true;
    }
    else
    {
        switch (gameMode)
        {
            case TF2_GameMode_Arena:
            {
                ServerCommand("exec d_arena.cfg");
                sym = true;
            }
            case TF2_GameMode_KOTH:
            {
                ServerCommand("exec d_koth.cfg");
                sym = true;
            }
            case TF2_GameMode_PL:
            {
                ServerCommand("exec d_payload.cfg");
            }
            case TF2_GameMode_PLR:
            {
                ServerCommand("exec d_payloadrace.cfg");
                sym = true;
            }
            case TF2_GameMode_CTF:
            {
                ServerCommand("exec d_ctf.cfg");
                sym = true;
            }
            case TF2_GameMode_5CP:
            {
                ServerCommand("exec d_5cp.cfg");
                sym = true;
            }
            case TF2_GameMode_ADCP:
            {
                ServerCommand("exec d_adcp.cfg");
            }
            case TF2_GameMode_TC:
            {
                ServerCommand("exec d_tc.cfg");
            }
            case TF2_GameMode_Unknown:
            {
                ServerCommand("exec d_default.cfg");
                sym = true;
            }
        }
    }
    g_bSymmetrical = sym;
}

static void CreateDefaultConfigs()
{
    char configNames[][] = {
        "d_arena.cfg",
        "d_koth.cfg", 
        "d_payload.cfg",
        "d_payloadrace.cfg",
        "d_ctf.cfg",
        "d_5cp.cfg",
        "d_adcp.cfg",
        "d_tc.cfg",
        "d_medieval.cfg",
        "d_pd.cfg",
        "d_default.cfg"
    };
    
    char configPath[PLATFORM_MAX_PATH];
    
    for (int i = 0; i < sizeof(configNames); i++)
    {
        BuildPath(Path_SM, configPath, sizeof(configPath), "../../cfg/%s", configNames[i]);
        if (!FileExists(configPath))
        {
            File file = OpenFile(configPath, "w");
            if (file != null)
            {
                file.WriteLine("// %s configuration", configNames[i]);
                file.WriteLine("// This file is auto-generated");
                file.WriteLine("");
                file.WriteLine("echo \"Executing %s\"", configNames[i]);
                file.Close();
                LogMessage("Created config file: %s", configPath);
            }
        }
    }
}

static bool IsMedievalMap()
{
    return FindEntityByClassname(-1, "tf_logic_medieval") != -1;
}

static bool IsPDMap()
{
    return FindEntityByClassname(-1, "tf_logic_player_destruction") != -1;
}
