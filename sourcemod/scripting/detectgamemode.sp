#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2_stocks>

#define PLUGIN_VERSION "2.1"
#define RESPAWN_CHECK_INTERVAL 15.0

public Plugin myinfo = {
    name = "Gamemode Detector",
    author = "Hombre",
    description = "Handles gamemode settings and instant respawns",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

public void OnPluginStart()
{
    g_cvEnabledOverride = CreateConVar("respawn_time_override", "3", "Enable/Disable respawn times", _, true, 0.0, true, 3.0);
    g_cvEnabled = CreateConVar("disable_respawn_times", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    g_cvRespawnTime = CreateConVar("respawn_time", "1.0", "Respawn time length", _, true, 0.0, true, 10.0);
    g_cvBots = CreateConVar("sm_bots", "0", "Allow dynamic bots at low playercounts", _, true, 0.0, true, 1.0);
    g_cvCritCheck = CreateConVar("sm_critcheck", "1", "Allow crit checking", _, true, 0.0, true, 1.0);
    
    RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_KICK, "Toggles respawn times");
    RegConsoleCmd("sm_bots", Command_BotToggle, "Toggle lowpop bots");
    
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("teamplay_round_active", Event_RoundActive);
    
    CreateTimer(RESPAWN_CHECK_INTERVAL, Timer_CritToggle, _, TIMER_REPEAT);
}

public void OnConfigsExecuted()
{
    DetectGameMode();
}

public Action Timer_CritToggle(Handle timer)
{
    if (!GetConVarBool(g_cvCritCheck)) {
        return Plugin_Continue;
    }

    char auth[32];
    bool critsEnabled = false;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            if (GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth))) {
                if (StrEqual(auth, "STEAM_0:1:33166791")) {
                    critsEnabled = true;
                    break;
                }
            }
        }
    }

    ServerCommand(critsEnabled ? "exec d_crits.cfg" : "exec d_nocrits.cfg");
    return Plugin_Continue;
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
        if (g_bArena) return;
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (!(IsValidClient(client))) return;

        if (GetConVarInt(g_cvEnabled) == 1) {
                float time = GetConVarFloat(g_cvRespawnTime);
                CreateTimer(time, Timer_RespawnClient, client);
                return;
        }
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    if (GetConVarBool(g_cvBots) && GetClientCount(true) < 8) {
        ServerCommand("exec bots");
    }
}

public Action Timer_RespawnClient(Handle timer, int client)
{
    if (IsValidClient(client) && !IsPlayerAlive(client) && GetClientTeam(client) > 1) {
        TF2_RespawnPlayer(client);
    }
    return Plugin_Continue;
}

public Action Command_BotToggle(int client, int args)
{
    if (client == 0) {
        return Plugin_Continue;
    }

    bool botsEnabled = GetConVarBool(g_cvBots);
    SetConVarBool(g_cvBots, !botsEnabled);
    
    ServerCommand(botsEnabled ? "exec nobots" : "exec bots");
    PrintToChatAll("Bots %s! Use !bots again to %s them.", 
        botsEnabled ? "disabled" : "enabled", 
        botsEnabled ? "enable" : "disable");
    
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
    bool isSymmetrical = g_bSymmetrical;
    
    if (!isSymmetrical) {
        // Asymmetric case
        ServerCommand(playerCount > 11 ? "exec d_highpop_pl.cfg" : "exec d_lowpop.cfg");
    } else {
        // Symmetrical case
        ServerCommand(playerCount > 15 ? "exec d_highpop.cfg" : "exec d_lowpop.cfg");
    }
}

bool IsValidClient(int client)
{
    return (1 <= client <= MaxClients) && IsClientInGame(client);
}
