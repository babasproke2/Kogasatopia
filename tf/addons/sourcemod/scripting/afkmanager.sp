#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <entity_prop_stocks>
#include <sdktools_voice>

#include <tf2_stocks>
#undef REQUIRE_PLUGIN
#include <dgm_api>
#define REQUIRE_PLUGIN

#include "include/client_validation.inc"

public Plugin myinfo =
{
	name = "AFK Manager",
	author = "random, Hombre",
	description = "Customized AFK management",
	version = "1.0",
	url = "http://castaway.tf"
};

#define ACTION_BUTTONS (IN_ATTACK | IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_ATTACK2 | IN_RELOAD | IN_SCORE)

int g_iLastPressTime[MAXPLAYERS+1];
bool g_bMovedToSpec[MAXPLAYERS+1];
int g_iCurrentTime = 0;

ConVar g_cvEnabled;
ConVar g_cvAfkAction;
ConVar g_cvAfkAliveTime;
ConVar g_cvAfkSpecTime;
ConVar g_cvAfkSpecMovedTime;
ConVar g_cvMinPlayerCount;
ConVar g_cvKickSpecMinPlayerCount;

GlobalForward g_fwOnAfkKick;

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max) {
    MarkNativeAsOptional("DGM_ServerCapacitycheck");
    RegPluginLibrary("afkmanager");
    return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sm_afkmanager_enabled","1","Enable AFK Manager", _, true, 0.0, true, 1.0);
    g_cvAfkAction = CreateConVar("sm_afkmanager_afk_action", "1", "What action to take upon AFK players.\n0 = Kick immediately\n1 = Move to spectator, and kick AFK spectators\n2 = Move to spectator, but don't kick spectators", _, true, 0.0, true, 2.0);
    g_cvAfkAliveTime = CreateConVar("sm_afkmanager_alive_time", "60", "How long a player must be AFK for for action to be taken upon them, in seconds.", _, true, 60.0);
    g_cvAfkSpecTime = CreateConVar("sm_afkmanager_spec_time", "300", "How long a player must be AFK in spectator before they are kicked, in seconds.", _, true, 60.0);
    g_cvAfkSpecMovedTime = CreateConVar("sm_afkmanager_spec_moved_time", "180", "How long a player must be AFK in spectator for, after being moved to it due to being afk, before they are kicked, in seconds.", _, true, 60.0);
    g_cvMinPlayerCount = CreateConVar("sm_afkmanager_min_player_count", "2", "Minimum number of players on the server before the AFK manager starts taking action on players.");
    g_cvKickSpecMinPlayerCount = CreateConVar("sm_afkmanager_kick_spec_min_player_count", "24", "Minimum number of players on the server before AFK spectators are kicked.", _, true, 0.0);

	g_fwOnAfkKick = new GlobalForward("OnAFKKick", ET_Hook, Param_Cell);

	AutoExecConfig(true, "afkmanager", "sourcemod");

	HookEvent("player_team", OnGameEvent, EventHookMode_Post);
	HookEvent("player_changeclass", OnGameEvent, EventHookMode_Post);

	AddCommandListener(OnSpecChanged,"spec_next");
	AddCommandListener(OnSpecChanged,"spec_prev");

	ConVar idleMethod = FindConVar("mp_idledealmethod");
	if (idleMethod != null) {
		idleMethod.SetInt(0);
	}

	g_iCurrentTime = GetTime();
    CreateTimer(1.0, AfkDaemon,_,TIMER_REPEAT);
}

public void OnMapStart() {
	for (int idx = 1; idx <= MaxClients; idx++) {
		ResetClientState(idx);
	}
}

public void OnClientConnected(int client) {
	ResetClientState(client);
}

public Action OnPlayerRunCmd(
	int client, int &buttons, int &impulse, float velocity[3], float angles[3],
	int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]
) {
	if (Client_IsHumanInGame(client)
		&& ((buttons & ACTION_BUTTONS) != 0 || mouse[0] != 0 || mouse[1] != 0)) {
		MarkClientActive(client);
	}
	return Plugin_Continue;
}

public void OnClientSpeaking(int client) {
	MarkClientActive(client);
}

Action OnSpecChanged(int client, const char[] command, int argc) {
	// spectators moving cameras is not covered by button checks (annoyingly!)
	MarkClientActive(client);
	return Plugin_Continue;
}

Action OnGameEvent(Event event, const char[] name, bool dontbroadcast) {
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	MarkClientActive(client);
	if (client > 0 && StrEqual(name, "player_team")
		&& GetEventInt(event, "team") >= view_as<int>(TFTeam_Red)) {
		g_bMovedToSpec[client] = false;
	}
	return Plugin_Continue;
}

Action AfkDaemon(Handle timer, any data) {
	g_iCurrentTime = GetTime();

	if (g_cvEnabled.BoolValue) {
		AfkManage();
	}

    return Plugin_Continue;
}

void MarkClientActive(int client) {
	if (client <= 0 || client > MaxClients) {
		return;
	}

	g_iLastPressTime[client] = g_iCurrentTime;
}

void ResetClientState(int client) {
	if (client <= 0 || client > MaxClients) {
		return;
	}

	g_iLastPressTime[client] = g_iCurrentTime;
	g_bMovedToSpec[client] = false;
}

bool Kick(int client) {
	Action result = Plugin_Continue;
	Call_StartForward(g_fwOnAfkKick);
	Call_PushCell(client);
	Call_Finish(result);
	if (result == Plugin_Continue) {
		KickClient(client,"#TF_Idle_kicked");
		return true;
	}
	return false;
}

void AfkManage() {
	int action = g_cvAfkAction.IntValue;
	int aliveTime = g_cvAfkAliveTime.IntValue;
	int spectatorTime = g_cvAfkSpecTime.IntValue;
	int movedSpectatorTime = g_cvAfkSpecMovedTime.IntValue;
	bool belowMinimum = GetClientCount(true) < g_cvMinPlayerCount.IntValue;
	bool canKickSpectators = CanKickAfkSpectators(g_cvKickSpecMinPlayerCount.IntValue);

	for (int client = 1; client <= MaxClients; client++) {
		if (!Client_IsHumanInGame(client)) {
			continue;
		}

		if (belowMinimum) {
			MarkClientActive(client);
			continue;
		}

		int lastActivity = g_iLastPressTime[client];
		if (lastActivity == 0) {
			continue;
		}

		int elapsed = g_iCurrentTime - lastActivity;
		TFTeam team = TF2_GetClientTeam(client);
		if (team == TFTeam_Unassigned || team == TFTeam_Spectator) {
			if (!canKickSpectators) {
				MarkClientActive(client);
				continue;
			}

			int timeout = g_bMovedToSpec[client] ? movedSpectatorTime : spectatorTime;
			bool shouldKick = (action == 0 && elapsed > spectatorTime)
				|| (action == 1 && elapsed > timeout);
			if (shouldKick && !Kick(client)) {
				MarkClientActive(client);
			}
			continue;
		}

		if (team != TFTeam_Red && team != TFTeam_Blue) {
			continue;
		}

		if (!IsPlayerAlive(client) && TF2_GetPlayerClass(client) != TFClass_Unknown) {
			// Do not count dead time, but keep counting while the class menu is open.
			g_iLastPressTime[client]++;
			continue;
		}

		if (elapsed <= aliveTime) {
			continue;
		}

		if (action == 0) {
			if (!Kick(client)) {
				MarkClientActive(client);
			}
		} else if (action == 1) {
			TF2_ChangeClientTeam(client, TFTeam_Spectator);
			MarkClientActive(client);
			g_bMovedToSpec[client] = true;
		} else if (action == 2) {
			TF2_ChangeClientTeam(client, TFTeam_Spectator);
		}
	}
}

bool CanKickAfkSpectators(int fallbackMinPlayerCount) {
    if (GetFeatureStatus(FeatureType_Native, "DGM_ServerCapacitycheck") == FeatureStatus_Available) {
        return DGM_ServerCapacitycheck(1.0, false);
    }

    return GetClientCount(false) >= fallbackMinPlayerCount;
}
