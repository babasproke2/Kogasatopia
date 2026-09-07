/*
Release notes:

---- 1.0.0 (01/11/2013) ----
- Restores a player's score when they reconnect
- Stored scores are trashed on mapchange and when a new match starts


---- 1.1.1 (09/11/2013) ----
- Fixed a bug where the scores would not be restored


---- 1.1.2 (28/01/2014) ----
- Fixed a minor error when the server is closing
- Fixed a bug that sometimes caused RestoreScore not to work for certain players (SteamID fix)


---- 1.1.3 (14/07/2025) ----
- Updated code to be compatible with SourceMod 1.12


Known issues:
- Not compatible with TFTrue.
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>
#include <sdkhooks>
#undef REQUIRE_PLUGIN
#include <updater>


#define PLUGIN_VERSION "1.1.3"
#define UPDATE_URL		"https://sourcemod.krus.dk/restorescore/update.txt"


public Plugin myinfo = {
	name = "Restore Score",
	author = "F2",
	description = "Restores the score of a player when reconnecting",
	version = PLUGIN_VERSION,
	url = "https://github.com/F2/F2s-sourcemod-plugins"
};

bool g_bHookActivated = false;

int g_iScoreAdjustment[MAXPLAYERS+1]; // Backstab kill-point deductions for this connection.
int g_iQualifyingTeleports[MAXPLAYERS+1];
int g_iAddScore[MAXPLAYERS+1]; // The old scores that are currently being added to the clients.
KeyValues g_kvOldScores = null; // Keys are steamids of players disconnected, and values are their old scores.



// Previously provided by f2stocks.inc
bool IsRealPlayer(int client) {
	return client > 0
		&& client <= MaxClients
		&& IsClientConnected(client)
		&& IsClientInGame(client)
		&& !IsClientSourceTV(client);
}

// Previously provided by f2stocks.inc
int TF2_GetPlayerScore(int client) {
	if (!IsClientConnected(client))
		return -1;

	int offset = FindSendPropInfo("CTFPlayerResource", "m_iTotalScore");
	if (offset < 1)
		return -1;

	int entity = GetPlayerResourceEntity();
	if (entity == -1)
		return -1;

	return GetEntData(entity, offset + (client * 4));
}



public void OnPluginStart() {
	HookEvent("player_death", Event_player_death, EventHookMode_Post);
	HookEvent("player_teleported", Event_player_teleported, EventHookMode_Post);
	HookEvent("player_activate", Event_player_activate, EventHookMode_Post);
	HookEvent("player_disconnect", Event_player_disconnect, EventHookMode_Pre);
	HookEvent("teamplay_restart_round", Event_restart_round, EventHookMode_Post);
	
	g_kvOldScores = CreateKeyValues("OldScores");
	
	if (LibraryExists("updater"))
		Updater_AddPlugin(UPDATE_URL);
}

public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "updater"))
		Updater_AddPlugin(UPDATE_URL);
}

public void OnPluginEnd() {
	StopHook();
	delete g_kvOldScores;
}



// Clear the old scores when the match is reset and on mapchange.
void ResetOldScores() {
	// Stop the hook (for performance reasons)
	StopHook();
	
	// Clear the old scores
	delete g_kvOldScores;
	g_kvOldScores = CreateKeyValues("OldScores");
	
	for (int client = 1; client <= MaxClients; client++) {
		g_iAddScore[client] = 0;
		g_iScoreAdjustment[client] = 0;
		g_iQualifyingTeleports[client] = 0;
	}
}

public void Event_restart_round(Event event, const char[] name, bool dontBroadcast) {
	ResetOldScores();
}

public void OnMapStart() {
	ResetOldScores();
}




public void OnClientPutInServer(int client) {
	g_iAddScore[client] = 0;
	g_iScoreAdjustment[client] = 0;
	g_iQualifyingTeleports[client] = 0;
}

public void Event_player_death(Event event, const char[] name, bool dontBroadcast) {
	if (event.GetInt("customkill") != TF_CUSTOM_BACKSTAB
		|| (event.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER))
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (!IsRealPlayer(attacker) || attacker == victim
		|| TF2_GetPlayerClass(attacker) != TFClass_Spy)
		return;

	// Leave TF2's real score intact; remove only the ordinary kill point
	// from the displayed total after the player manager recalculates it.
	g_iScoreAdjustment[attacker]--;
	StartHook();
}

public void Event_player_teleported(Event event, const char[] name, bool dontBroadcast) {
	int teleportedUserId = event.GetInt("userid");
	int builderUserId = event.GetInt("builderid");
	if (builderUserId == teleportedUserId)
		return;

	int teleported = GetClientOfUserId(teleportedUserId);
	int builder = GetClientOfUserId(builderUserId);
	if (!IsRealPlayer(teleported) || !IsRealPlayer(builder)
		|| TF2_GetPlayerClass(builder) != TFClass_Engineer
		|| GetClientTeam(teleported) != GetClientTeam(builder))
		return;

	g_iQualifyingTeleports[builder]++;
	if ((g_iQualifyingTeleports[builder] % 2) == 0) {
		// TF2 awards one TFSTAT_TELEPORTS point per two teammate uses.
		g_iScoreAdjustment[builder]--;
		StartHook();
	}
}

// When a player connects, check if it is a returning player, and adjust his score accordingly.
public void Event_player_activate(Event event, const char[] name, bool dontBroadcast) {
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!IsRealPlayer(client))
		return;
	
	char steamid[64];
	if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), false))
		return;
	KvRewind(g_kvOldScores);
	if (KvJumpToKey(g_kvOldScores, steamid) == false)
		return;
	int oldscore = KvGetNum(g_kvOldScores, "score");
	KvGoBack(g_kvOldScores);
	KvDeleteKey(g_kvOldScores, steamid);
	
	g_iAddScore[client] = oldscore;
	//SetEntProp(client, Prop_Data, "m_iFrags", KvGetNum(g_kvOldScores, "kills"));
	//SetEntProp(client, Prop_Data, "m_iDeaths", KvGetNum(g_kvOldScores, "deaths"));
	//SetEntProp(client, Prop_Data, "m_iAssists", KvGetNum(g_kvOldScores, "assists"));
	
	StartHook();
}

// When a player disconnects, remember the score.
public void Event_player_disconnect(Event event, const char[] name, bool dontBroadcast) {
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	
	g_iAddScore[client] = 0;
	g_iScoreAdjustment[client] = 0;
	g_iQualifyingTeleports[client] = 0;
	
	// Clear the old scores if the server is empty
	if (GetClientCount() == 1) {
		ResetOldScores();
		return;
	}
	
	if (!IsRealPlayer(client))
		return;
	
	// Save the score if it is above 0
	int score = TF2_GetPlayerScore(client);
	if (score <= 0)
		return;
	char steamid[64];
	if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid), false))
		return;
	
	KvRewind(g_kvOldScores);
	if (KvJumpToKey(g_kvOldScores, steamid, true) == false)
		return;
	
	KvSetNum(g_kvOldScores, "score", score);
	//KvSetNum(g_kvOldScores, "kills", GetEntProp(client, Prop_Data, "m_iFrags"));
	//KvSetNum(g_kvOldScores, "deaths", GetEntProp(client, Prop_Data, "m_iDeaths"));
	//KvSetNum(g_kvOldScores, "assists", GetEntProp(client, Prop_Data, "m_iAssists"));
	KvGoBack(g_kvOldScores);
}



// --- This is where the magic happens! ---
void StartHook() {
	if (g_bHookActivated)
		return;
	g_bHookActivated = true;
	int iIndex = FindEntityByClassname(-1, "tf_player_manager");
	if (iIndex == -1)
		SetFailState("Unable to find tf_player_manager entity");
	
	SDKHook(iIndex, SDKHook_ThinkPost, Hook_OnThinkPost);
}

void StopHook() {
	if (!g_bHookActivated)
		return;
	g_bHookActivated = false;
	int iIndex = FindEntityByClassname(-1, "tf_player_manager");
	if (iIndex == -1)
		SetFailState("Unable to find tf_player_manager entity");
	
	SDKUnhook(iIndex, SDKHook_ThinkPost, Hook_OnThinkPost);
}

public void Hook_OnThinkPost(int iEnt) {
	static int iTotalScoreOffset = -1;
	if (iTotalScoreOffset == -1)
		iTotalScoreOffset = FindSendPropInfo("CTFPlayerResource", "m_iTotalScore");
	
	// Get all players' current scores
	int iTotalScore[MAXPLAYERS+1];
	GetEntDataArray(iEnt, iTotalScoreOffset, iTotalScore, MaxClients+1);
	
	// Apply reconnect credit and backstab deductions to the fresh engine totals.
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			iTotalScore[i] += g_iAddScore[i] + g_iScoreAdjustment[i];
			if (iTotalScore[i] < 0)
				iTotalScore[i] = 0;
		}
	}
	
	// Set all players' new scores
	SetEntDataArray(iEnt, iTotalScoreOffset, iTotalScore, MaxClients+1);
}
// ----------------------------------------
