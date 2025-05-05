#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include "detectgamemode/gamemode_stocks.sp"

#define PLUGIN_VERSION "1.0"
#define ASK_COOLDOWN 12.0

public Plugin myinfo = {
    name = "Help Me Medic",
    author = "Hombre",
    description = "If no Medics, ask a player to switch",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

Handle g_hTimer = INVALID_HANDLE;
ConVar g_cvMinPlayers;

bool g_bAsked[MAXPLAYERS + 1];
Handle g_hCooldownTimer[MAXPLAYERS + 1] = {INVALID_HANDLE, ...};

public void OnPluginStart() {
    CreateConVar("sm_medicbalance_version", PLUGIN_VERSION, "Medic Balance Plugin Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_cvMinPlayers = CreateConVar("sm_medicbalance_minplayers", "12",  "Minimum players required on a team before medic checks occur (0 = disabled)",  _, true, 0.0, true, 32.0);
    
    HookEvent("teamplay_round_start", Event_RoundStart);
    HookEvent("teamplay_round_win", Event_RoundEnd);
    HookEvent("player_changeclass", Event_PlayerChangeClass);
    HookEvent("player_team", Event_PlayerTeam);
    
    RegConsoleCmd("sm_mediccheck", Command_MedicCheck, "Force a medic check");
    RegConsoleCmd("sm_medic", Command_Medic, "Switches player to Medic instantly.");
}

public void OnMapEnd() {
    if (g_hTimer != INVALID_HANDLE) {
        KillTimer(g_hTimer);
    }
}

public void OnMapStart() {
    if (g_hTimer != INVALID_HANDLE) {
        KillTimer(g_hTimer);
    }
}

public Action Command_MedicCheck(int client, int args) {
    CheckTeamsForMedics();
    return Plugin_Handled;
}

public void OnClientDisconnect(int client) {
    ResetClientAskStatus(client);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // Initialize asked status
    for (int i = 1; i <= MaxClients; i++) {
        g_bAsked[i] = false;
        g_hCooldownTimer[i] = INVALID_HANDLE;
    }
    // Start the timer when round starts
    if (g_hTimer != INVALID_HANDLE) {
        KillTimer(g_hTimer);
    }
    if (IsPayloadMap()) { //This is from detectgamemode.sp
	g_hTimer = CreateTimer(1.0, Timer_CheckMedics, _, TIMER_REPEAT);
    }
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    // Stop the timer when round ends
    if (g_hTimer != INVALID_HANDLE) {
        KillTimer(g_hTimer);
        g_hTimer = INVALID_HANDLE;
    }
    
    // Reset all ask statuses
    for (int i = 1; i <= MaxClients; i++) {
        ResetClientAskStatus(i);
    }
}

public void Event_PlayerChangeClass(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && TF2_GetPlayerClass(client) == TFClass_Medic) {
        ResetClientAskStatus(client);
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0) {
        ResetClientAskStatus(client);
    }
}

public Action Timer_CheckMedics(Handle timer) {
    CheckTeamsForMedics();
    return Plugin_Continue;
}

void CheckTeamsForMedics() {
    CheckTeamForMedic(TFTeam_Red);
    CheckTeamForMedic(TFTeam_Blue);
}

void CheckTeamForMedic(TFTeam team) {
    if (GetClientCount() < g_cvMinPlayers.IntValue) {
        return;
    }

    int medicsOnTeam = CountMedicsOnTeam(team);
    
    if (medicsOnTeam == 0) {
        int randomPlayer = FindRandomPlayerOnTeam(team);
        
        if (randomPlayer != -1) {
            AskPlayerToSwitchToMedic(randomPlayer);
        }
    }
}

int CountMedicsOnTeam(TFTeam team) {
    int medicCount = 0;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == team && TF2_GetPlayerClass(i) == TFClass_Medic) {
            medicCount++;
        }
    }
    
    return medicCount;
}

int FindRandomPlayerOnTeam(TFTeam team) {
    int[] clients = new int[MaxClients];
    int clientCount = 0;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsPlayerAlive(i) && TF2_GetClientTeam(i) == team && TF2_GetPlayerClass(i) != TFClass_Medic) {
            clients[clientCount++] = i;
        }
    }
    
    if (clientCount == 0) {
        return -1;
    }
    
    return clients[GetRandomInt(0, clientCount - 1)];
}

void AskPlayerToSwitchToMedic(int client) {
    g_bAsked[client] = true;
    PrintToChat(client, "\x0787CEFA[Help Me Medic]\x01 Your team has no Medics! Use \x03!medic\x01 to switch and get 50% free uber automatically.");

    // Set cooldown timer
    if (g_hCooldownTimer[client] != INVALID_HANDLE) {
        KillTimer(g_hCooldownTimer[client]);
    }
    g_hCooldownTimer[client] = CreateTimer(ASK_COOLDOWN, Timer_ResetAskStatus, GetClientUserId(client));
}

public Action Timer_ResetAskStatus(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    if (client > 0) {
        g_bAsked[client] = false;
    }
    g_hCooldownTimer[client] = INVALID_HANDLE;
    return Plugin_Stop;
}

void ResetClientAskStatus(int client) {
    g_bAsked[client] = false;
    if (g_hCooldownTimer[client] != INVALID_HANDLE) {
        KillTimer(g_hCooldownTimer[client]);
        g_hCooldownTimer[client] = INVALID_HANDLE;
    }
}

public Action Command_Medic(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;
    if (!g_bAsked[client])
	return Plugin_Handled;

    // Force player to switch to Medic
    TF2_SetPlayerClass(client, TFClass_Medic);
    TF2_RespawnPlayer(client);
    int medigun = GetPlayerWeaponSlot(client, 1);
    SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", 0.50);

    return Plugin_Handled;
}
