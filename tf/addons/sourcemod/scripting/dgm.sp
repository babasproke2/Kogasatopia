#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <tf2>
#define PLUGIN_VERSION "4.3"

ConVar g_cvEnabled;
ConVar g_cvSetSetupTime;
ConVar g_cvAsymCapRespawn;
ConVar g_cvThreshold;
ConVar g_cvRedTime;
ConVar g_cvBluTime;
ConVar g_cvAutoAddTime;
ConVar g_cvTimeOverride;
ConVar g_cvRespawnTime;
ConVar g_cvPlayerCountConfigs;
bool g_bSymmetrical;
float g_fBaseRespawnTime = 0.0;
bool g_bBaseRespawnInitialized = false;

ConVar g_cHostname;
ConVar g_hVisibleMaxPlayers;

int g_PointCaptures;
bool g_InternalOverride; // For disabling this plugin's respawn time management in any case


// Add a ConVar to hook the value of mp_disable_respawn_times
Handle g_cvMpDisableRespawnTimes = INVALID_HANDLE;

public Plugin myinfo = {
    name = "Gamemode Detector",
    author = "Hombre",
    description = "Handles instant respawns",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

public void OnPluginStart()
{
    // Disable respawn times with this plugin?
    g_cvEnabled = CreateConVar("disable_respawn_times", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    // The respawn time
    g_cvRespawnTime = CreateConVar("respawn_time", "3.0", "Respawn time length", _, true, 0.0, true, 30.0);
    // See description
    g_cvThreshold = CreateConVar("sm_highpop_threshhold", "12.0", "Threshhold for executing the highpop config", _, true, 0.0, true, 100.0);
    // For micromanagement, if this convar isn't 0, it'll use the given time
    g_cvTimeOverride = CreateConVar("respawn_otime", "0", "Override respawn time with this", _, true, 0.0, true, 30.0);
    // Respawn times for individual teams (beta)
    g_cvRedTime = CreateConVar("respawn_redtime", "3.0", "Red respawn time length", _, true, 0.0, true, 16.0);
    g_cvBluTime = CreateConVar("respawn_blutime", "3.0", "Blu respawn time length", _, true, 0.0, true, 16.0);
    // Auto add time to king of the hill timers?
    g_cvAutoAddTime = CreateConVar("sm_autoaddtime", "300", "Automatically extend koth times? > 0 for the time in seconds");
    // Always respawn red team on control point capture in asymmetrical gamemodes?
    g_cvAsymCapRespawn = CreateConVar("respawn_red_on_cap", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    // Change the setup time to this in asymmetrical gamemodes
    g_cvSetSetupTime = CreateConVar("sm_setuptime", "40", "Set setup time to X - 0 to disable management - only enable this per-map or in gamemode configs", _, true, 0.0, true,60.0);
    // Enable automatic player count configuration switching
    g_cvPlayerCountConfigs = CreateConVar("sm_playercount_configs", "1", "Enable auto config switching based on player count", _, true, 0.0, true, 1.0);
    // Hook the value of mp_disable_respawn_times
    g_cvMpDisableRespawnTimes = FindConVar("mp_disable_respawn_times");
    HookConVarChange(g_cvRespawnTime, ConVarChange_MpDisableRespawnTimes);
    
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("teamplay_round_start", Event_RoundActive);
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_Pre);
    HookEvent("teamplay_point_captured", Event_PointCaptured, EventHookMode_PostNoCopy);   

    RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_KICK, "Toggles respawn times");
    RegAdminCmd("sm_noset", Command_ResetSetup, ADMFLAG_KICK, "Set round setup time to 10 seconds");

    g_cHostname = FindConVar("hostname");
    RegConsoleCmd("sm_st", Command_Stats, "Show player count, map and hostname");
    RegConsoleCmd("sm_manual", Command_CvarHelp, "Displays information about plugin ConVars.");

    g_bSymmetrical = true;
}

public void OnMapStart()
{
    g_bBaseRespawnInitialized = false;
}

// I prefer the visual effect when TF2's mp_disable_respawn_times cvar is true but dislike that it can be exploited
// Also takes about 5~ seconds for the respawn to occur
public void ConVarChange_MpDisableRespawnTimes(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (StringToInt(newValue) > 5 || g_InternalOverride)
    {
        SetConVarInt(g_cvMpDisableRespawnTimes, 0);
    } else 
    {
        SetConVarInt(g_cvMpDisableRespawnTimes, 1);
    }
}

// We can be sure entities are loaded by this point
public void OnConfigsExecuted()
{
    if (!g_bBaseRespawnInitialized)
    {
        g_fBaseRespawnTime = GetConVarFloat(g_cvRespawnTime);
        g_bBaseRespawnInitialized = true;
    }
    if (GetConVarBool(g_cvPlayerCountConfigs))
    {
        RequestFrame(AdjustByPlayerCount); // Good to have this third check for the start of a map
    }
    g_InternalOverride = false; // Reset this on map change
}

// Fires when a control point is captured
public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    //This stuff is mostly WIP for dynamic changes on maps in the future
	// For now, all of these  features are from asymmetrical gamemode types
	if (!g_bSymmetrical)
	{
		g_PointCaptures++;
		if (g_PointCaptures >= 3)
		{
			g_InternalOverride = true; // Stop managing respawn times if approaching last
		}
		// Asymmetrical: respawn all dead RED players
		if (g_cvAsymCapRespawn && !g_bSymmetrical)
		{    
			for (int i = 1; i <= MaxClients; i++)
				if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsPlayerAlive(i))
					TF2_RespawnPlayer(i);
		}
		return;
	}
}

public void OnClientPutInServer(int client)
{
    if (GetConVarBool(g_cvPlayerCountConfigs))
    {
        RequestFrame(AdjustByPlayerCount);
    }
}

public void OnClientDisconnect(int client)
{
    if (GetConVarBool(g_cvPlayerCountConfigs))
    {
        RequestFrame(AdjustByPlayerCount);
    }
}

// This command lets me see everything this plugin is doing at a given moment among other things
public Action Command_Stats(int client, int args)
{
    bool fromConsole = (client <= 0 || !IsClientInGame(client));

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

    // Get visible max players
    if (g_hVisibleMaxPlayers == null)
    {
        g_hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    }
    int visMax = GetConVarInt(g_hVisibleMaxPlayers);

    // Respawn-related ConVars
    float respawnTime = GetConVarFloat(g_cvRespawnTime);
    float timeOverride = GetConVarFloat(g_cvTimeOverride);
    float redTime = GetConVarFloat(g_cvRedTime);
    float bluTime = GetConVarFloat(g_cvBluTime);
    int enabledRespawnOverride = GetConVarInt(g_cvEnabled);
    int asymCapRespawn = GetConVarInt(g_cvAsymCapRespawn);

    // Output function (chooses chat or console)
    if (fromConsole)
    {
        PrintToServer("[DGM] Players: %d", playerCount);
        PrintToServer("Map: %s | Server: %s | Max Players: %d", map, hostname, visMax);
        PrintToServer("  respawn_time: %.2f", respawnTime);
        PrintToServer("  red: %.2f | blu: %.2f | otime:%.2f", redTime, bluTime, timeOverride);
        PrintToServer("  disable_respawn_times: %d | respawn_red_on_cap: %d",
                      enabledRespawnOverride, asymCapRespawn);
    }
    else
    {
        PrintToChat(client, "\x04[DGM]\x01 Players: \x04%d\x01 | Map: \x04%s\x01 | Server: \x04%s\x01 | Max: \x04%d",
                    playerCount, map, hostname, visMax);

        PrintToChat(client, "\x04[Respawn]\x01 respawn_time: \x04%.2f\x01 | respawn_otime: \x04%.2f",
                    respawnTime, timeOverride);

        PrintToChat(client, "\x04[Respawn]\x01 red: \x04%.2f\x01 | blu: \x04%.2f", redTime, bluTime);

        PrintToChat(client, "\x04[Respawn]\x01 disable_respawn_times: \x04%d\x01 | respawn_red_on_cap: \x04%d",
                    enabledRespawnOverride, asymCapRespawn);
    }

    return Plugin_Handled;
}

public Action Command_CvarHelp(int client, int args)
{
    char lines[][] = {
        "disable_respawn_times: 0/1 - If 1, plugin-controlled respawn timers are enabled",
        "respawn_time: float - Default respawn delay (seconds) when not overridden",
        "sm_highpop_threshhold: int - Player count threshold to execute high-pop configs",
        "respawn_otime: float - If >0, forces this respawn delay for all players",
        "respawn_redtime: float - Respawn time (seconds) specifically for Red team (beta)",
        "respawn_blutime: float - Respawn time (seconds) specifically for Blu team (beta)",
        "sm_autoaddtime: int - Seconds to add to KOTH timers when enabled (0 disables)",
        "respawn_red_on_cap: 0/1 - In asymmetrical modes, when 1, respawns Red instantly on cap",
        "sm_setuptime: int - Forces round setup time to this value (0 = disabled)",
        "mp_disable_respawn_times: 0/1 - Server cvar hooked by this plugin to toggle visual respawn behavior"
    };

    bool fromConsole = (client <= 0 || !IsClientInGame(client));

    if (fromConsole)
    {
        PrintToServer("[DGM ConVar Help]");
        for (int i = 0; i < sizeof(lines); i++)
        {
            PrintToServer("  %s", lines[i]);
        }
    }
    else
    {
        PrintToChat(client, "\x04[DGM ConVar Help]\x01");
        for (int i = 0; i < sizeof(lines); i++)
        {
            PrintToChat(client, "\x01%s", lines[i]);
        }
    }

    return Plugin_Handled;
}

public Action Command_RespawnToggle(int client, int args)
{
    g_InternalOverride = !g_InternalOverride; // toggles between true and false
    PrintToChat(client, "Respawn times %s", g_InternalOverride ? "forced on" : "forced off");
    return Plugin_Handled;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
        if (g_InternalOverride)
        {
            SetConVarInt(g_cvMpDisableRespawnTimes, 0);
            return;
        }
        if (!GetConVarInt(g_cvEnabled)) return;
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (!(IsValidClient(client))) return;

        float override = GetConVarFloat(g_cvTimeOverride);
        if (override > 0)
        {
            CreateTimer(override, Timer_RespawnClient, client);
            return;
        }

        float time = GetConVarFloat(g_cvRespawnTime);
        int team = GetClientTeam(client);
        float redTime = GetConVarFloat(g_cvRedTime);
        float bluTime = GetConVarFloat(g_cvBluTime);
        if (redTime != bluTime)
        {
        if (team == 2) time = redTime;
        else if (team == 3) time = bluTime;
        }
        CreateTimer(time, Timer_RespawnClient, client);
        return;
}

public Action Timer_RespawnClient(Handle timer, int client)
{
    if (IsValidClient(client) && !IsPlayerAlive(client) && GetClientTeam(client) > 1) {
        TF2_RespawnPlayer(client);
    }
    return Plugin_Stop;
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    if (g_cvTimeOverride != null)    g_cvTimeOverride.RestoreDefault();
    g_InternalOverride = false; // This is set to true when a round is won, it changes back to false now
    g_PointCaptures = 0;
    if (GetConVarInt(g_cvSetSetupTime) != 0)
    {
        SetSetupTime();
    }
	if (GetConVarInt(g_cvAutoAddTime)) {
        int addTime = GetConVarInt(g_cvAutoAddTime);
		int entityTimer = FindEntityByClassname(-1, "tf_logic_koth");
		if (entityTimer > -1)
		{
			SetVariantInt(addTime);
			AcceptEntityInput(entityTimer, "SetBlueTimer");
			SetVariantInt(addTime);
			AcceptEntityInput(entityTimer, "SetRedTimer");
		}
	}
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    SetConVarInt(g_cvTimeOverride, 30);
    g_PointCaptures = 0;
    g_InternalOverride = true; // We're gonna stop clients from getting insta-respawned with this
}

public Action Command_ResetSetup(int client , int args)
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt == -1)
    {
        if (client > 0) PrintToChat(client, "No team_round_timer entity found.");
        else PrintToServer("[SM] No team_round_timer entity found.");
        return Plugin_Handled;
    }

    int time = 10;
    if (args > 0)
    {
        if (!GetCmdArgIntEx( 1, args))
        {
            ReplyToCommand(client, "Given time must be a number!" );
            return Plugin_Continue;
        }
    }
	char temp[ 4 ];
	GetCmdArg( 1, temp, 4 );
	time = StringToInt(temp) + 1;
    SetVariantInt(time);
    AcceptEntityInput(timerEnt, "SetTime");

    if (client > 0) PrintToChatAll("Setup time reduced to %i seconds.", time);
    PrintToServer("[SM] Setup time set to %i seconds.", time);
    return Plugin_Handled;
}

public void SetSetupTime()
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt != -1)
    {
        int time = GetConVarInt(g_cvSetSetupTime);
        SetVariantInt(time);
        AcceptEntityInput(timerEnt, "SetTime");
        PrintToServer("[SM] Setup time set to %i seconds.", time);
    }
}

public void AdjustByPlayerCount(any data)
{
    if (!GetConVarBool(g_cvPlayerCountConfigs))
    {
        return;
    }
    if (!g_bBaseRespawnInitialized)
    {
        g_fBaseRespawnTime = GetConVarFloat(g_cvRespawnTime);
        g_bBaseRespawnInitialized = true;
    }

    int playerCount = GetClientCount(true);
    int threshhold = GetConVarInt(g_cvThreshold);
    float currentRespawn = GetConVarFloat(g_cvRespawnTime);

    if (playerCount > threshhold)
    {
        if (currentRespawn < g_fBaseRespawnTime)
        {
            SetConVarFloat(g_cvRespawnTime, g_fBaseRespawnTime);
        }
        return;
    }

    if (g_fBaseRespawnTime <= 9.0)
    {
        return;
    }

    float reduced = g_fBaseRespawnTime - 4.0;
    if (FloatAbs(currentRespawn - reduced) > 0.01)
    {
        SetConVarFloat(g_cvRespawnTime, reduced);
    }
}

static bool IsValidClient(int client)
{
    return (client >= 1 && client <= MaxClients) && IsClientInGame(client);
}
