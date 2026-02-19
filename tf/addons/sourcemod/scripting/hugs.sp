	#include <sourcemod>
	#include <clientprefs>
	#include <sdktools>
	#include <dbi>
	#include <morecolors>
	

	#pragma semicolon 1
	#pragma newdecls required

	public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
	{
		RegPluginLibrary("hugs");
		CreateNative("Hugs_GetRapesGiven", Native_Hugs_GetRapesGiven);
		CreateNative("Hugs_AreStatsLoaded", Native_Hugs_AreStatsLoaded);
		MarkNativeAsOptional("Filters_IsRedlisted");
		return APLRes_Success;
	}

	public Plugin myinfo =
	{
		name = "hugs",
		author = "Your Name",
		description = "Allows players to hug/rape each other, track hugs/rapes, check stats, and view last huggers/rapists",
		version = "1.5",
		url = "https://example.com"
	};

#define HUGS_DB_CONFIG "default"
#define HUGS_DB_TABLE  "hugs_stats"
#define MAX_HISTORY_ENTRIES 5
#define HISTORY_STRING_LEN 256

int g_iHugsReceived[MAXPLAYERS + 1];
int g_iHugsGiven[MAXPLAYERS + 1];
int g_iRapesReceived[MAXPLAYERS + 1];
int g_iRapesGiven[MAXPLAYERS + 1];
char g_szLastHuggers[MAXPLAYERS + 1][MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH];
char g_szLastRapists[MAXPLAYERS + 1][HISTORY_STRING_LEN];
	char g_szClientSteamId[MAXPLAYERS + 1][32];
	bool g_bStatsLoaded[MAXPLAYERS + 1];
	bool g_bStatsPending[MAXPLAYERS + 1];

	Database g_hDatabase = null;
Handle g_hDbReconnectTimer = null;
ConVar g_hMultiplierCvar = null;
int g_iMultiplier = 1;
Handle g_hReminderTimer[MAXPLAYERS + 1];
Handle g_hStatsRetryTimer[MAXPLAYERS + 1];
int g_iSchemaOpsPending = 0;
Handle g_hRedlistCookie = INVALID_HANDLE;

native bool Filters_IsRedlisted(int client);

	public any Native_Hugs_GetRapesGiven(Handle plugin, int numParams)
	{
		int client = GetNativeCell(1);
		if (!IsClientIndexValid(client))
		{
			return 0;
		}
		return g_iRapesGiven[client];
	}

	public any Native_Hugs_AreStatsLoaded(Handle plugin, int numParams)
	{
		int client = GetNativeCell(1);
		return IsClientIndexValid(client) && g_bStatsLoaded[client];
	}

	// Cooldown variables
	float g_fLastHugTime[MAXPLAYERS + 1];
	float g_fLastRapeTime[MAXPLAYERS + 1];
	const float COOLDOWN_TIME = 8.0; // 8-second cooldown

	// --- State ---
	bool g_bDuelRequested = false;
	bool g_bDuelActive    = false;
	int  g_iRequester     = 0;
	int  g_iTarget        = 0;
	int  g_iScoreReq      = 0;
	int  g_iScoreTgt      = 0;

	Handle g_hRequestTimer = null;

	// --- ConVars ---
	ConVar g_hTargetScore;
	ConVar g_hRequestTimeout;

	public void OnPluginStart()
	{
		LoadTranslations("common.phrases");

		RegConsoleCmd("sm_hug", Command_Hug, "Hug another player by name");
		RegConsoleCmd("sm_rape", Command_Rape, "Rape another player by name");
		RegConsoleCmd("sm_checkhugs", Command_CheckHugs, "Check your total hugs received and given");
		RegConsoleCmd("sm_checkrapes", Command_CheckRapes, "Check your total rapes received and given");
		RegConsoleCmd("sm_hugcheck", Command_CheckHugs, "Check your total hugs received and given");
		RegConsoleCmd("sm_rapecheck", Command_CheckRapes, "Check your total rapes received and given");
		RegConsoleCmd("sm_hugs", Command_CheckHugs); // Alias for !checkhugs
		RegConsoleCmd("sm_rapes", Command_CheckRapes); // Alias for !checkrapes

		RegAdminCmd("sm_prape", Command_Prape, ADMFLAG_SLAY, "sm_prape <player> - Sets rapes_given to at least 1");

		AddCommandListener(Hugs_SayListener, "say");
		AddCommandListener(Hugs_SayListener, "say_team");

		RegConsoleCmd("sm_hl", Command_Leaderboard, "Show hugs/rapes leaderboard");
		RegConsoleCmd("sm_rl", Command_Leaderboard, "Show hugs/rapes leaderboard");
		RegConsoleCmd("sm_leaderboard", Command_Leaderboard, "Show hugs/rapes leaderboard");
		RegConsoleCmd("sm_rapesleaderboard", Command_Leaderboard, "Show hugs/rapes leaderboard");
		RegConsoleCmd("sm_hugsleaderboard", Command_Leaderboard, "Show hugs/rapes leaderboard");

		// Set default values for cookies if they don't exist
		SetCookieMenuItem(StatsCookieMenuHandler, 0, "Hug/Rape Stats");
		
		RegConsoleCmd("sm_duel",   Command_Duel,   "Challenge a player: !duel <name substring>");
		RegConsoleCmd("sm_rapeduel",   Command_Duel,   "Alias of !duel");
		RegConsoleCmd("sm_accept", Command_Accept, "Accept a pending duel");

		HookEvent("player_death",            Event_PlayerDeath, EventHookMode_Post);
		HookEvent("teamplay_round_win",      Event_RoundEnd,    EventHookMode_Post);
		HookEvent("teamplay_round_stalemate",Event_RoundEnd,    EventHookMode_Post);

		g_hTargetScore    = CreateConVar("sm_rapeduel_targetscore", "5",  "rapes needed to win a duel", _, true, 1.0);
		g_hRequestTimeout = CreateConVar("sm_rapeduel_requesttime", "30", "Seconds before a duel request expires", _, true, 5.0);

		AutoExecConfig(true, "rapeduel");

		for (int i = 1; i <= MaxClients; i++)
		{
			ResetClientStats(i);
			g_fLastHugTime[i] = 0.0;
			g_fLastRapeTime[i] = 0.0;
			g_hReminderTimer[i] = null;
			g_hStatsRetryTimer[i] = null;
		}

		g_hMultiplierCvar = CreateConVar("sm_hugs_multiplier", "1", "Multiplier for hug/rape stats (0 or 1 disable).", FCVAR_NOTIFY);
		g_hMultiplierCvar.AddChangeHook(ConVarChanged_Multiplier);
		UpdateMultiplierValue();

		ConnectToDatabase();
		EnsureRedlistCookie();
	}

	void EnsureRedlistCookie()
	{
		if (g_hRedlistCookie == INVALID_HANDLE)
		{
			g_hRedlistCookie = FindClientCookie("filter_redlist");
		}
	}

	bool IsClientRedlisted(int client)
	{
		if (!IsClientIndexValid(client))
		{
			return false;
		}

		if (GetFeatureStatus(FeatureType_Native, "Filters_IsRedlisted") == FeatureStatus_Available)
		{
			return Filters_IsRedlisted(client);
		}

		if (!AreClientCookiesCached(client))
		{
			return false;
		}

		EnsureRedlistCookie();
		if (g_hRedlistCookie == INVALID_HANDLE)
		{
			return false;
		}

		char cookie[8];
		GetClientCookie(client, g_hRedlistCookie, cookie, sizeof(cookie));
		return StrEqual(cookie, "1");
	}

	Action Hugs_SayListener(int client, const char[] command, int argc)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
		{
			return Plugin_Continue;
		}

		char message[256];
		GetCmdArgString(message, sizeof(message));
		StripQuotes(message);
		TrimString(message);

		if (!message[0])
		{
			return Plugin_Continue;
		}

		if (message[0] != '!' && message[0] != '/')
		{
			return Plugin_Continue;
		}

		char payload[256];
		strcopy(payload, sizeof(payload), message);
		payload[0] = ' ';
		TrimString(payload);
		if (!payload[0])
		{
			return Plugin_Continue;
		}

		char cmdName[64];
		char args[192];
		strcopy(cmdName, sizeof(cmdName), payload);
		int spaceIndex = FindCharInString(cmdName, ' ');
		if (spaceIndex != -1)
		{
			cmdName[spaceIndex] = '\0';
			strcopy(args, sizeof(args), payload[spaceIndex + 1]);
			TrimString(args);
		}
		else
		{
			args[0] = '\0';
		}

		if (!StrEqual(cmdName, "hug", false) && !StrEqual(cmdName, "rape", false))
		{
			return Plugin_Continue;
		}

		if (!IsClientRedlisted(client))
		{
			return Plugin_Continue;
		}

		if (StrEqual(cmdName, "hug", false))
		{
			if (args[0])
			{
				FakeClientCommand(client, "sm_hug %s", args);
			}
			else
			{
				FakeClientCommand(client, "sm_hug");
			}
		}
		else
		{
			if (args[0])
			{
				FakeClientCommand(client, "sm_rape %s", args);
			}
			else
			{
				FakeClientCommand(client, "sm_rape");
			}
		}

		return Plugin_Handled;
	}

	public void OnClientPutInServer(int client)
	{
		ResetClientStats(client);
		g_fLastHugTime[client] = 0.0;
		g_fLastRapeTime[client] = 0.0;

		if (!IsHumanClient(client))
		{
			if (IsClientIndexValid(client))
			{
				g_bStatsLoaded[client] = true;
			}
			return;
		}

		AttemptLoadClientStats(client);
		MaybeScheduleReminder(client);
	}

	public void OnClientAuthorized(int client, const char[] auth)
	{
		if (!IsHumanClient(client))
		{
			return;
		}

		AttemptLoadClientStats(client);
	}

	public void OnClientDisconnect(int client)
	{
		SaveClientStats(client);
		ResetClientStats(client);
		CancelReminderTimer(client);

		if (g_bDuelRequested)
		{
			if (client == g_iRequester || client == g_iTarget)
			{
				PrintToChatSafe(g_iRequester, "\x04[RAPE DUEL]\x01 Duel request canceled (%N disconnected).", client);
				PrintToChatSafe(g_iTarget,    "\x04[RAPE DUEL]\x01 Duel request canceled (%N disconnected).", client);
				ResetDuel();
			}
		}
	else if (g_bDuelActive)
	{
		if (client == g_iRequester || client == g_iTarget)
		{
			int winner = (client == g_iRequester) ? g_iTarget : g_iRequester;
				if (IsClientInGame(winner))
				{
					PrintToChatAll("\x04[RAPE DUEL]\x01 %N disconnected. %N wins the rape duel by forfeit! Final Score: %N %d - %N %d",
								   client, winner,
								   g_iRequester, g_iScoreReq,
								   g_iTarget,    g_iScoreTgt);
				}
				ResetDuel();
		}
	}
}

public void ConVarChanged_Multiplier(ConVar convar, const char[] oldValue, const char[] newValue)
{
	UpdateMultiplierValue();
	if (ShouldUseMultiplier())
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsHumanClientInGame(i))
			{
				MaybeScheduleReminder(i);
			}
		}
	}
}

void UpdateMultiplierValue()
{
	g_iMultiplier = (g_hMultiplierCvar != null) ? g_hMultiplierCvar.IntValue : 1;
	if (!ShouldUseMultiplier())
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			CancelReminderTimer(i);
		}
	}
}

bool ShouldUseMultiplier()
{
	int value = g_iMultiplier;
	if (value < 0)
	{
		value = -value;
	}
	return value > 1;
}

int GetEffectiveMultiplier()
{
	int value = g_iMultiplier;
	if (value < 0)
	{
		value = -value;
	}
	return (value > 1) ? value : 1;
}

void MaybeScheduleReminder(int client)
{
	CancelReminderTimer(client);
	if (!ShouldUseMultiplier() || !IsHumanClientInGame(client))
	{
		return;
	}

	g_hReminderTimer[client] = CreateTimer(60.0, Timer_MultiplierReminder, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

void CancelReminderTimer(int client)
{
	if (!IsClientIndexValid(client))
	{
		return;
	}

	if (g_hReminderTimer[client] != null)
	{
		CloseHandle(g_hReminderTimer[client]);
		g_hReminderTimer[client] = null;
	}
}

void CancelStatsRetryTimer(int client)
{
	if (!IsClientIndexValid(client))
	{
		return;
	}

	if (g_hStatsRetryTimer[client] != null)
	{
		CloseHandle(g_hStatsRetryTimer[client]);
		g_hStatsRetryTimer[client] = null;
	}
}

void ScheduleStatsRetry(int client)
{
	CancelStatsRetryTimer(client);
	if (!IsClientIndexValid(client))
	{
		return;
	}

	g_hStatsRetryTimer[client] = CreateTimer(5.0, Timer_RetryStatsLoad, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RetryStatsLoad(Handle timer, any data)
{
	int client = GetClientOfUserId(data);
	if (!IsClientIndexValid(client) || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	if (g_hStatsRetryTimer[client] == timer)
	{
		g_hStatsRetryTimer[client] = null;
	}

	AttemptLoadClientStats(client);
	return Plugin_Stop;
}

public Action Timer_MultiplierReminder(Handle timer, any data)
{
	int client = GetClientOfUserId(data);
	if (!IsClientIndexValid(client) || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	if (g_hReminderTimer[client] == timer)
	{
		g_hReminderTimer[client] = null;
	}

	if (!ShouldUseMultiplier())
	{
		return Plugin_Stop;
	}

	if (IsClientRedlisted(client))
	{
		return Plugin_Stop;
	}

	int mult = GetEffectiveMultiplier();
	CPrintToChat(client, "{green}[Hugs]{default} There's an ongoing {crimson}%dx rapes event!!!{default} All hugs & rapes are multiplied by {crimson}%d{default}.", mult, mult);
	return Plugin_Stop;
}

	public void StatsCookieMenuHandler(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
	{
		if (action == CookieMenuAction_DisplayOption)
		{
			Format(buffer, maxlen, "Check Hug/Rape Stats");
		}
		else if (action == CookieMenuAction_SelectOption)
		{
			Command_CheckHugs(client, 0);
		}
	}

	public Action Command_Leaderboard(int client, int args)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
		{
			return Plugin_Handled;
		}

		if (!IsDatabaseReady())
		{
			ReplyToCommand(client, "[Kogasa] Database not ready.");
			return Plugin_Handled;
		}

		char query[512];
		Format(query, sizeof(query),
			"SELECT h.name, h.rapes_given, h.rapes_received, h.hugs_given, h.hugs_received, h.steamid, "
			... "(SELECT personaname FROM whaletracker WHERE steamid = "
			... "CAST(76561197960265728 + (SUBSTRING_INDEX(h.steamid, ':', -1) * 2) + SUBSTRING_INDEX(SUBSTRING_INDEX(h.steamid, ':', 2), ':', -1) AS CHAR) "
			... "AND personaname != '' LIMIT 1) AS wt_name "
			... "FROM %s h ORDER BY h.rapes_given DESC LIMIT 10",
			HUGS_DB_TABLE);
		SQL_TQuery(g_hDatabase, SQL_OnLeaderboardLoaded, query, GetClientUserId(client));
		return Plugin_Handled;
	}

	public void SQL_OnLeaderboardLoaded(Database db, DBResultSet results, const char[] error, any data)
	{
		int client = GetClientOfUserId(data);
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
		{
			return;
		}

		if (error[0])
		{
			LogError("[Hugs] Failed to load leaderboard: %s", error);
			CPrintToChat(client, "[Kogasa] Failed to load leaderboard.");
			return;
		}

		CPrintToChat(client, "{green}[Hugs Leaderboard]");
		int rank = 1;
		while (results.FetchRow())
		{
			char name[MAX_NAME_LENGTH];
			results.FetchString(0, name, sizeof(name));
			int rapesGiven = results.FetchInt(1);
			int rapesReceived = results.FetchInt(2);
			
			char steamid[64];
			results.FetchString(5, steamid, sizeof(steamid));
			
			char wt_name[MAX_NAME_LENGTH];
			results.FetchString(6, wt_name, sizeof(wt_name));

			if (name[0] == '\0' || StrEqual(name, "Unknown"))
			{
				if (wt_name[0] != '\0' && !StrEqual(wt_name, "Unknown"))
				{
					strcopy(name, sizeof(name), wt_name);
				}
				else
				{
					strcopy(name, sizeof(name), "Unknown");
				}
			}

			char rankStr[64];
			GetRapeRank(rapesGiven, rankStr, sizeof(rankStr));

			CPrintToChat(client, "{default}#%d: {gold}%s {default} Rapes: {gold}%d | Received: {crimson} %d {default}| {olive}%s", rank, name, rapesGiven, rapesReceived, rankStr);
			rank++;
		}
	}

	/* ---------------- Commands ---------------- */

	public Action Command_Duel(int client, int args)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
			return Plugin_Handled;

		if (args < 1)
		{
			PrintToChat(client, "Usage: !duel <player name substring>");
			return Plugin_Handled;
		}

		if (g_bDuelRequested || g_bDuelActive)
		{
			PrintToChat(client, "A duel is already pending or in progress.");
			return Plugin_Handled;
		}

		char targetName[128];
		GetCmdArgString(targetName, sizeof(targetName));
		StripQuotes(targetName);
		TrimString(targetName);

		int target = FindPlayerBySubstring(targetName, client);
		if (target == 0)
		{
			PrintToChat(client, "No player found matching \"%s\".", targetName);
			return Plugin_Handled;
		}
		if (target == client)
		{
			PrintToChat(client, "You cannot duel yourself.");
			return Plugin_Handled;
		}

		// Set state
		g_iRequester     = client;
		g_iTarget        = target;
		g_bDuelRequested = true;
		g_iScoreReq      = 0;
		g_iScoreTgt      = 0;

		float timeout = g_hRequestTimeout.FloatValue;
		StartRequestTimer(timeout);

		// Private messages only to challenger and target
		PrintToChatAll("\x04[RAPE DUEL]\x01 %N challenged %N to a duel! (expires in %.0fs)", client, target, timeout);
		PrintToChat(target, "\x04[RAPE DUEL]\x01 %N challenged you to a duel! Type !accept to start! (expires in %.0fs).", client, timeout);

		// Play sound to both
		ClientCommand(client, "playgamesound ui/duel_challenge.wav");
		ClientCommand(target, "playgamesound ui/duel_challenge.wav");

		return Plugin_Handled;
	}

	public Action Command_Accept(int client, int args)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
			return Plugin_Handled;

		if (!g_bDuelRequested || g_bDuelActive)
		{
			PrintToChat(client, "There is no pending duel for you to accept.");
			return Plugin_Handled;
		}
		if (client != g_iTarget)
		{
			PrintToChat(client, "You were not challenged.");
			return Plugin_Handled;
		}

		CancelRequestTimer();

		g_bDuelRequested = false;
		g_bDuelActive    = true;
		g_iScoreReq      = 0;
		g_iScoreTgt      = 0;

		int targetScore = g_hTargetScore.IntValue;

		PrintToChatAll("\x04[RAPE DUEL]\x01 %N accepted %N's challenge! First to %d rapes wins!",
					   g_iTarget, g_iRequester, targetScore);

		ClientCommand(g_iTarget, "playgamesound ui/duel_challenge_accepted.wav");
		ClientCommand(g_iRequester, "playgamesound ui/duel_challenge_accepted.wav");
		return Plugin_Handled;
	}

	/* ---------------- Events ---------------- */

	public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
	{
		if (!g_bDuelActive) return;

		int victim   = GetClientOfUserId(event.GetInt("userid"));
		int attacker = GetClientOfUserId(event.GetInt("attacker"));
		int deathFlags = event.GetInt("death_flags");

		if (!IsClientIndexValid(attacker) || !IsClientIndexValid(victim))
			return;

		if (deathFlags & 32)
			return;

		bool duelKill = (attacker == g_iRequester && victim == g_iTarget) ||
						(attacker == g_iTarget     && victim == g_iRequester);

		if (!duelKill)
			return;

		if (attacker == g_iRequester)
			g_iScoreReq++;
		else
			g_iScoreTgt++;

		PrintToChatAll("\x04[RAPE DUEL]\x01 %N raped %N! Score: %N %d - %N %d",
					   attacker, victim,
					   g_iRequester, g_iScoreReq,
					   g_iTarget,    g_iScoreTgt);

		int targetScore = g_hTargetScore.IntValue;
		if (g_iScoreReq >= targetScore || g_iScoreTgt >= targetScore)
		{
			int winner = (g_iScoreReq > g_iScoreTgt) ? g_iRequester : g_iTarget;
			int loser  = (winner == g_iRequester) ? g_iTarget : g_iRequester;

			PrintToChatAll("\x04[RAPE DUEL]\x01 %N HAS RAPED %N!!! Final Score: %N %d - %N %d",
						   winner, loser,
						   g_iRequester, g_iScoreReq,
						   g_iTarget,    g_iScoreTgt);
			UpdateRapeStatsDuel(g_iRequester, g_iTarget, g_iScoreReq, g_iScoreTgt);
			ResetDuel();
		}
	}

	public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
	{
		if (!g_bDuelActive && !g_bDuelRequested)
			return;

		if (g_bDuelRequested)
		{
			// Pending request never accepted before round end
			PrintToChatSafe(g_iRequester, "\x04[RAPE DUEL]\x01 Duel request with %N expired at round end.", g_iTarget);
			PrintToChatSafe(g_iTarget,    "\x04[RAPE DUEL]\x01 Duel request from %N expired at round end.", g_iRequester);
			ResetDuel();
			return;
		}

		if (g_iScoreReq == 0 && g_iScoreTgt == 0)
		{
			PrintToChatAll("\x04[RAPE DUEL]\x01 Duel between %N and %N ended with no rapes.", g_iRequester, g_iTarget);
		}
		else if (g_iScoreReq == g_iScoreTgt)
		{
			PrintToChatAll("\x04[RAPE DUEL]\x01 Duel between %N and %N ended in a tie (%d - %d).",
						   g_iRequester, g_iTarget, g_iScoreReq, g_iScoreTgt);
		}
		else
		{
			int winner = (g_iScoreReq > g_iScoreTgt) ? g_iRequester : g_iTarget;
			int loser  = (winner == g_iRequester) ? g_iTarget : g_iRequester;
			PrintToChatAll("\x04[RAPE DUEL]\x01 Round ended: %N wins the rape duel over %N! Final Score: %N %d - %N %d",
						   winner, loser,
						   g_iRequester, g_iScoreReq,
						   g_iTarget,    g_iScoreTgt);
		}
		UpdateRapeStatsDuel(g_iRequester, g_iTarget, g_iScoreReq, g_iScoreTgt);
		ResetDuel();
	}

	public void checkRapeChievements(int client)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
			return;
		
		if (!EnsureStatsReady(client, false))
			return;

		int count = g_iRapesGiven[client];
		
		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));
		
		switch (count)
		{
			case 1:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Strange!", name);
			}
			case 10:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Unremarkable!", name);
			}
			case 25:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Scarcely Lethal!", name);
			}
			case 45:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Mildly Menacing!", name);
			}
			case 70:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Somewhat Threatening!", name);
			}
			case 100:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Uncharitable!", name);
			}
			case 135:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Notably Dangerous!", name);
			}
			case 175:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Sufficiently Lethal!", name);
			}
			case 225:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Truly Feared!", name);
			}
			case 275:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Spectacularly Lethal!", name);
			}
			case 350:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Gore-Spattered!", name);
			}
			case 500:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Wicked Nasty!", name);
			}
			case 750:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Positively Inhumane!", name);
			}
			case 999:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Totally Ordinary!", name);
			}
			case 1000:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Face-Melting!", name);
			}
			case 1500:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Rage-Inducing!", name);
			}
			case 2500:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Server-Clearing!", name);
			}
			case 5000:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Epic!", name);
			}
			case 7500:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Legendary!", name);
			}
			case 7616:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Australian!", name);
			}
			case 8500:
			{
				PrintToChatAll("%s's rapes have reached a new rank: Hale's Own!", name);
			}
		}

	}

	void GetRapeRank(int count, char[] buffer, int maxlen)
	{
		if (count >= 8500) strcopy(buffer, maxlen, "Hale's Own");
		else if (count >= 7616) strcopy(buffer, maxlen, "Australian");
		else if (count >= 7500) strcopy(buffer, maxlen, "Legendary");
		else if (count >= 5000) strcopy(buffer, maxlen, "Epic");
		else if (count >= 2500) strcopy(buffer, maxlen, "Server-Clearing");
		else if (count >= 1500) strcopy(buffer, maxlen, "Rage-Inducing");
		else if (count >= 1000) strcopy(buffer, maxlen, "Face-Melting");
		else if (count >= 999) strcopy(buffer, maxlen, "Totally Ordinary");
		else if (count >= 750) strcopy(buffer, maxlen, "Positively Inhumane");
		else if (count >= 500) strcopy(buffer, maxlen, "Wicked Nasty");
		else if (count >= 350) strcopy(buffer, maxlen, "Gore-Spattered");
		else if (count >= 275) strcopy(buffer, maxlen, "Spectacularly Lethal");
		else if (count >= 225) strcopy(buffer, maxlen, "Truly Feared");
		else if (count >= 175) strcopy(buffer, maxlen, "Sufficiently Lethal");
		else if (count >= 135) strcopy(buffer, maxlen, "Notably Dangerous");
		else if (count >= 100) strcopy(buffer, maxlen, "Uncharitable");
		else if (count >= 70) strcopy(buffer, maxlen, "Somewhat Threatening");
		else if (count >= 45) strcopy(buffer, maxlen, "Mildly Menacing");
		else if (count >= 25) strcopy(buffer, maxlen, "Scarcely Lethal");
		else if (count >= 10) strcopy(buffer, maxlen, "Unremarkable");
		else strcopy(buffer, maxlen, "Strange");
	}

	/* ---------------- Helpers ---------------- */

	bool IsClientIndexValid(int client)
	{
		return (client > 0 && client <= MaxClients);
	}

	bool IsHumanClient(int client)
	{
		return (IsClientIndexValid(client) && IsClientConnected(client) && !IsFakeClient(client));
	}

	bool IsHumanClientInGame(int client)
	{
		return (IsHumanClient(client) && IsClientInGame(client));
	}

	bool IsGroupTargetArg(const char[] arg)
	{
		return (StrEqual(arg, "@all", false) || StrEqual(arg, "@red", false) || StrEqual(arg, "@blue", false));
	}

	bool IsCooldownBlocked(float lastTime, float currentTime, float &remaining)
	{
		if (COOLDOWN_TIME - (currentTime - lastTime) > COOLDOWN_TIME)
		{
			remaining = 0.0;
			return false;
		}

		float elapsed = currentTime - lastTime;
		if (elapsed < COOLDOWN_TIME)
		{
			remaining = COOLDOWN_TIME - elapsed;
			return true;
		}

		remaining = 0.0;
		return false;
	}

	int FindPlayerBySubstring(const char[] partial, int exclude)
	{
		char name[64];
		// Exact (case-insensitive)
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i == exclude || !IsClientInGame(i)) continue;
			GetClientName(i, name, sizeof(name));
			if (StrEqual(name, partial, false))
				return i;
		}
		// Substring
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i == exclude || !IsClientInGame(i)) continue;
			GetClientName(i, name, sizeof(name));
			if (StrContains(name, partial, false) != -1)
				return i;
		}
		return 0;
	}

	void ResetDuel()
	{
		CancelRequestTimer();
		g_bDuelRequested = false;
		g_bDuelActive    = false;
		g_iRequester     = 0;
		g_iTarget        = 0;
		g_iScoreReq      = 0;
		g_iScoreTgt      = 0;
	}

	void StartRequestTimer(float seconds)
	{
		CancelRequestTimer();
		g_hRequestTimer = CreateTimer(seconds, Timer_RequestExpire, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	void CancelRequestTimer()
	{
		if (g_hRequestTimer != null)
		{
			CloseHandle(g_hRequestTimer);
			g_hRequestTimer = null;
		}
	}

	public Action Timer_RequestExpire(Handle timer)
	{
		if (timer != g_hRequestTimer)
			return Plugin_Stop;

		g_hRequestTimer = null;

		if (!g_bDuelRequested || g_bDuelActive)
			return Plugin_Stop;

		if (IsClientInGame(g_iRequester))
			PrintToChatSafe(g_iRequester, "\x04[RAPE DUEL]\x01 Duel request to %N expired.", g_iTarget);
		if (IsClientInGame(g_iTarget))
			PrintToChatSafe(g_iTarget, "\x04[RAPE DUEL]\x01 Duel request from %N expired.", g_iRequester);

		ResetDuel();
		return Plugin_Stop;
	}

	// Safe Print (skip if client invalid / disconnected)
	void PrintToChatSafe(int client, const char[] fmt, any ...)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
			return;

		char buffer[256];
		VFormat(buffer, sizeof(buffer), fmt, 3);
		PrintToChat(client, "%s", buffer);
	}

	public Action Command_Hug(int client, int args)
	{
		if (args < 1)
		{
			ReplyToCommand(client, "[Kogasa] Usage: !hug <name>");
			return Plugin_Handled;
		}

		if (IsSpecialClient(client))
		{
			return Plugin_Handled;
		}

		if (!EnsureStatsReady(client, true))
		{
			return Plugin_Handled;
		}

		float currentTime = GetGameTime();
		float remaining = 0.0;
		if (IsCooldownBlocked(g_fLastHugTime[client], currentTime, remaining))
		{
			ReplyToCommand(client, "[Kogasa] You must wait %.1f seconds before hugging again.", remaining);
			return Plugin_Handled;
		}

		char arg1[32];
		GetCmdArg(1, arg1, sizeof(arg1));

		char target_name[MAX_TARGET_LENGTH];
		int target_list[MAXPLAYERS], target_count;
		bool tn_is_ml;

		if ((target_count = ProcessTargetString(
					arg1,
					client,
					target_list,
					MAXPLAYERS,
					COMMAND_FILTER_NO_BOTS | COMMAND_FILTER_NO_IMMUNITY,
					target_name,
					sizeof(target_name),
					tn_is_ml)) <= 0)
		{
			ReplyToTargetError(client, target_count);
			return Plugin_Handled;
		}

		int successCount = 0;
		char clientName[MAX_NAME_LENGTH];
		GetClientName(client, clientName, sizeof(clientName));

		bool isGroupTarget = IsGroupTargetArg(arg1);

		for (int i = 0; i < target_count; i++)
		{
			int target = target_list[i];
			if (target == client) continue;

			if (!EnsureStatsReady(target, false))
			{
				continue;
			}

			char targetNameDisplay[MAX_NAME_LENGTH];
			GetClientName(target, targetNameDisplay, sizeof(targetNameDisplay));

			// Send message to the recipient unless they are redlisted
			if (!IsClientRedlisted(target))
			{
				PrintToChat(target, "\x01[SM] \x04%s \x01hugged you!", clientName);
			}

			// Send message to the sender
			PrintToChat(client, "\x01[SM] You hugged \x04%s\x01!", targetNameDisplay);

			// Update hug stats
			// If it's a group target, we don't increment per target here
			UpdateHugStats(client, target, !isGroupTarget);

			// Update last huggers list
			UpdateLastHuggers(target, clientName);
			
			successCount++;
		}

		if (isGroupTarget && successCount > 0)
		{
			int amount = GetEffectiveMultiplier();
			g_iHugsGiven[client] += amount;
			SaveClientStats(client);
		}

		if (successCount > 0)
		{
			PrintToChat(client, "\x01[SM] Use !hugs to check your stats.");
			g_fLastHugTime[client] = currentTime;
		}

		return Plugin_Handled;
	}

	public Action Command_Rape(int client, int args)
	{
		if (args < 1)
		{
			ReplyToCommand(client, "[Kogasa] Usage: !rape <name>");
			return Plugin_Handled;
		}

		if (IsSpecialClient(client))
		{
			return Plugin_Handled;
		}

		if (!EnsureStatsReady(client, true))
		{
			return Plugin_Handled;
		}

		float currentTime = GetGameTime();
		float remaining = 0.0;
		if (IsCooldownBlocked(g_fLastRapeTime[client], currentTime, remaining))
		{ 
			ReplyToCommand(client, "[Kogasa] You must wait %.1f seconds before raping again.", remaining);
			return Plugin_Handled;
		}

		char arg1[32];
		GetCmdArg(1, arg1, sizeof(arg1));

		char target_name[MAX_TARGET_LENGTH];
		int target_list[MAXPLAYERS], target_count;
		bool tn_is_ml;

		if ((target_count = ProcessTargetString(
					arg1,
					client,
					target_list,
					MAXPLAYERS,
					COMMAND_FILTER_NO_BOTS | COMMAND_FILTER_NO_IMMUNITY,
					target_name,
					sizeof(target_name),
					tn_is_ml)) <= 0)
		{
			ReplyToTargetError(client, target_count);
			return Plugin_Handled;
		}

		int successCount = 0;
		char clientName[MAX_NAME_LENGTH];
		GetClientName(client, clientName, sizeof(clientName));

		bool isGroupTarget = IsGroupTargetArg(arg1);

		for (int i = 0; i < target_count; i++)
		{
			int target = target_list[i];
			if (target == client) continue;

			if (!EnsureStatsReady(target, false))
			{
				continue;
			}

			char targetNameDisplay[MAX_NAME_LENGTH];
			GetClientName(target, targetNameDisplay, sizeof(targetNameDisplay));

			// Send message to the recipient unless they are redlisted
			if (!IsClientRedlisted(target))
			{
				PrintToChat(target, "\x01[SM] \x04%s \x01raped you!", clientName);
			}

			// Send message to the sender
			PrintToChat(client, "\x01[SM] You raped \x04%s\x01!", targetNameDisplay);

			// Update rape stats
			// If it's a group target, we don't increment per target here
			UpdateRapeStats(client, target, !isGroupTarget);

			// Update last rapists list
			UpdateLastRapists(target, client);
			
			successCount++;
		}

		if (isGroupTarget && successCount > 0)
		{
			int amount = GetEffectiveMultiplier();
			g_iRapesGiven[client] += amount;
			SaveClientStats(client);
		}

		if (successCount > 0)
		{
			PrintToChat(client, "\x01[SM] Use !rapes to check your stats.");
			g_fLastRapeTime[client] = currentTime;
		}

		return Plugin_Handled;
	}

	public Action Command_CheckHugs(int client, int args)
	{
		if (!EnsureStatsReady(client, true))
		{
			return Plugin_Handled;
		}

		char lastHuggers[HISTORY_STRING_LEN];
		BuildHuggerHistoryString(client, lastHuggers, sizeof(lastHuggers));

		PrintToChat(client, "\x01[SM] Hugs Received: \x04%d\x01 | Hugs Given: \x04%d", g_iHugsReceived[client], g_iHugsGiven[client]);
		PrintToChat(client, "\x01[SM] Last Huggers: \x04%s", lastHuggers);

		return Plugin_Handled;
	}

	public Action Command_CheckRapes(int client, int args)
	{
		if (!EnsureStatsReady(client, true))
		{
			return Plugin_Handled;
		}

		char lastRapists[HISTORY_STRING_LEN];
		BuildRapistHistoryString(client, lastRapists, sizeof(lastRapists));
		int count = g_iRapesGiven[client];

		PrintToChat(client, "\x01[SM] Rapes Received: \x04%d\x01 | Rapes Given: \x04%d", g_iRapesReceived[client], g_iRapesGiven[client]);
		PrintToChat(client, "\x01[SM] Last Rapists: \x04%s", lastRapists);
		
		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));

		char rankStr[64];
		GetRapeRank(count, rankStr, sizeof(rankStr));
		PrintToChatAll("%s's rapes have reached a new rank: %s!", name, rankStr);

		return Plugin_Handled;
	}

	public Action Command_Prape(int client, int args)
	{
		if (args < 1)
		{
			ReplyToCommand(client, "[Kogasa] Usage: sm_prape <player>");
			return Plugin_Handled;
		}

		if (!IsDatabaseReady())
		{
			ReplyToCommand(client, "[Kogasa] Database not ready.");
			return Plugin_Handled;
		}

		char arg[64];
		GetCmdArg(1, arg, sizeof(arg));

		char target_name[MAX_TARGET_LENGTH];
		int target_list[MAXPLAYERS], target_count;
		bool tn_is_ml;

		target_count = ProcessTargetString(
			arg,
			client,
			target_list,
			sizeof(target_list),
			COMMAND_FILTER_CONNECTED,
			target_name,
			sizeof(target_name),
			tn_is_ml
		);

		if (target_count <= 0)
		{
			ReplyToTargetError(client, target_count);
			return Plugin_Handled;
		}

		for (int i = 0; i < target_count; i++)
		{
			int target = target_list[i];
			if (!IsClientInGame(target) || IsFakeClient(target))
			{
				continue;
			}

			if (!EnsureClientSteamId(target))
			{
				continue;
			}

			char steamEsc[64];
			SQL_EscapeString(g_hDatabase, g_szClientSteamId[target], steamEsc, sizeof(steamEsc));

			char query[256];
			Format(query, sizeof(query),
				"INSERT INTO %s (steamid, rapes_given) VALUES ('%s', 1) ON DUPLICATE KEY UPDATE rapes_given = GREATEST(rapes_given, 1)",
				HUGS_DB_TABLE, steamEsc);
			SQL_TQuery(g_hDatabase, SQL_OnPrapeSaved, query, GetClientUserId(target));

			if (g_bStatsLoaded[target] && g_iRapesGiven[target] < 1)
			{
				g_iRapesGiven[target] = 1;
			}
		}

		if (tn_is_ml)
		{
			ShowActivity2(client, "[Kogasa] ", "Set rapes_given to 1 for %s", target_name);
		}
		else
		{
			ShowActivity2(client, "[Kogasa] ", "Set rapes_given to 1 for %s", target_name);
		}

		return Plugin_Handled;
	}

	void UpdateHugStats(int sender, int recipient, bool incrementSender = true)
	{
		if (!EnsureStatsReady(sender, false) || !EnsureStatsReady(recipient, false))
		{
			return;
		}

		int amount = GetEffectiveMultiplier();
		if (incrementSender)
		{
			g_iHugsGiven[sender] += amount;
			SaveClientStats(sender);
		}
		g_iHugsReceived[recipient] += amount;
		SaveClientStats(recipient);
	}

	void UpdateRapeStats(int sender, int recipient, bool incrementSender = true)
	{
		if (!EnsureStatsReady(sender, false) || !EnsureStatsReady(recipient, false))
		{
			return;
		}

		int amount = GetEffectiveMultiplier();
		if (incrementSender)
		{
			g_iRapesGiven[sender] += amount;
			SaveClientStats(sender);
		}
		g_iRapesReceived[recipient] += amount;
		SaveClientStats(recipient);
	}

void UpdateRapeStatsDuel(int sender, int recipient, int score1, int score2)
{
		if (!EnsureStatsReady(sender, false) || !EnsureStatsReady(recipient, false))
		{
			return;
		}

		int amount = GetEffectiveMultiplier();
		g_iRapesGiven[sender] += score1 * amount;
		PrintToChat(sender, "[Kogasa] %i rapes have been credited to your account!", score1 * amount);

	g_iRapesReceived[recipient] += score2 * amount;
	PrintToChat(recipient, "[Kogasa] you just received %i rapes!", score2 * amount);
		
	UpdateLastRapists(recipient, sender);
	SaveClientStats(sender);
	SaveClientStats(recipient);
}

void BuildHuggerHistoryString(int client, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	bool appended = false;

	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		if (!g_szLastHuggers[client][i][0])
		{
			continue;
		}

		if (appended)
		{
			StrCat(buffer, maxlen, ", ");
		}

		StrCat(buffer, maxlen, g_szLastHuggers[client][i]);
		appended = true;
	}

	if (!appended)
	{
		strcopy(buffer, maxlen, "None");
	}
}

void BuildRapistHistoryString(int client, char[] buffer, int maxlen)
{
	if (g_szLastRapists[client][0])
	{
		strcopy(buffer, maxlen, g_szLastRapists[client]);
	}
	else
	{
		strcopy(buffer, maxlen, "None");
	}
}

void UpdateLastHuggers(int recipient, const char[] huggerName)
{
	for (int i = MAX_HISTORY_ENTRIES - 1; i > 0; i--)
	{
		strcopy(g_szLastHuggers[recipient][i], MAX_NAME_LENGTH, g_szLastHuggers[recipient][i - 1]);
	}

	strcopy(g_szLastHuggers[recipient][0], MAX_NAME_LENGTH, huggerName);
	SaveClientStats(recipient);
}

void UpdateLastRapists(int recipient, int sender)
{
	char rapistName[MAX_NAME_LENGTH];
	GetClientName(sender, rapistName, sizeof(rapistName));
	
	char rapists[MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH];
	int count = ParseHistoryList(g_szLastRapists[recipient], rapists);
	int limit = (count < (MAX_HISTORY_ENTRIES - 1)) ? count : (MAX_HISTORY_ENTRIES - 1);

	for (int i = limit; i > 0; i--)
	{
		strcopy(rapists[i], MAX_NAME_LENGTH, rapists[i - 1]);
	}

	strcopy(rapists[0], MAX_NAME_LENGTH, rapistName);

	int newCount = (count >= MAX_HISTORY_ENTRIES) ? MAX_HISTORY_ENTRIES : count + 1;
	ImplodeStrings(rapists, newCount, ",", g_szLastRapists[recipient], HISTORY_STRING_LEN);
	SaveClientStats(recipient);
	
	// Check for achievement progress from the sender
	checkRapeChievements(sender);
}

	int ParseHistoryList(const char[] input, char output[][MAX_NAME_LENGTH])
	{
		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			output[i][0] = '\0';
		}

		if (!input[0])
		{
			return 0;
		}

		int count = ExplodeString(input, ",", output, MAX_HISTORY_ENTRIES, MAX_NAME_LENGTH);
		if (count < 0)
		{
			count = MAX_HISTORY_ENTRIES;
		}

		for (int i = 0; i < count; i++)
		{
			TrimString(output[i]);
		}

		return count;
	}


	bool IsSpecialClient(int client)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
			return false;

		char steamID[32];
		if (!GetClientAuthId(client, AuthId_Steam3, steamID, sizeof(steamID)))
			return false;

		if (StrEqual(steamID, "[U:1:1605262060]") || StrEqual(steamID, "[U:1:360445377]"))
		{
			return true;
		}

		return false;
	}

void ResetClientStats(int client)
{
	if (!IsClientIndexValid(client))
	{
		return;
	}

	CancelStatsRetryTimer(client);
	g_iHugsReceived[client] = 0;
	g_iHugsGiven[client] = 0;
	g_iRapesReceived[client] = 0;
	g_iRapesGiven[client] = 0;
	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		g_szLastHuggers[client][i][0] = '\0';
	}
	g_szLastRapists[client][0] = '\0';
	g_szClientSteamId[client][0] = '\0';
	g_bStatsLoaded[client] = false;
	g_bStatsPending[client] = false;
}

	bool EnsureStatsReady(int client, bool notify)
	{
		if (!IsHumanClient(client))
		{
			return true;
		}

		if (g_bStatsLoaded[client])
		{
			return true;
		}

		if (notify)
		{
			PrintToChat(client, "[Kogasa] Your hug/rape stats are still loading. Please wait.");
		}

		AttemptLoadClientStats(client);
		return false;
	}

	bool EnsureClientSteamId(int client)
	{
		if (!IsClientIndexValid(client))
		{
			return false;
		}

		if (g_szClientSteamId[client][0])
		{
			return true;
		}

		char auth[32];
		if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
		{
			return false;
		}

		if (StrEqual(auth, "STEAM_ID_PENDING"))
		{
			return false;
		}

		strcopy(g_szClientSteamId[client], sizeof(g_szClientSteamId[]), auth);
		return true;
	}

	bool IsDatabaseReady()
	{
		return (g_hDatabase != null);
	}

	void AttemptLoadClientStats(int client)
	{
		if (!IsHumanClient(client))
		{
			return;
		}

		if (g_bStatsLoaded[client] || g_bStatsPending[client])
		{
			return;
		}

		if (!IsDatabaseReady())
		{
			return;
		}

		if (!EnsureClientSteamId(client))
		{
			return;
		}

		char steamEsc[96];
		SQL_EscapeString(g_hDatabase, g_szClientSteamId[client], steamEsc, sizeof(steamEsc));

	char query[512];
	Format(query, sizeof(query), "SELECT hugs_given, hugs_received, rapes_given, rapes_received, last_hugger1, last_hugger2, last_hugger3, last_hugger4, last_hugger5, last_rapists FROM %s WHERE steamid = '%s'", HUGS_DB_TABLE, steamEsc);

		g_bStatsPending[client] = true;
		SQL_TQuery(g_hDatabase, SQL_OnStatsLoaded, query, GetClientUserId(client));
	}

	public void SQL_OnStatsLoaded(Database db, DBResultSet results, const char[] error, any data)
	{
		int client = GetClientOfUserId(data);
		if (!IsClientIndexValid(client))
		{
			return;
		}

		g_bStatsPending[client] = false;

		if (!IsClientInGame(client))
		{
			return;
		}

	if (error[0])
	{
		LogError("[Hugs] Failed to load stats: %s", error);
		ScheduleStatsRetry(client);
		return;
	}

	int hugsGiven = 0;
	int hugsReceived = 0;
	int rapesGiven = 0;
	int rapesReceived = 0;
	char lastRapists[HISTORY_STRING_LEN];

	lastRapists[0] = '\0';

	if (results != null && results.FetchRow())
	{
		hugsGiven = results.FetchInt(0);
		hugsReceived = results.FetchInt(1);
		rapesGiven = results.FetchInt(2);
		rapesReceived = results.FetchInt(3);
		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			results.FetchString(4 + i, g_szLastHuggers[client][i], MAX_NAME_LENGTH);
		}
		results.FetchString(9, lastRapists, sizeof(lastRapists));
	}
	else
	{
		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			g_szLastHuggers[client][i][0] = '\0';
		}
	}

	g_iHugsGiven[client] = hugsGiven;
	g_iHugsReceived[client] = hugsReceived;
	g_iRapesGiven[client] = rapesGiven;
	g_iRapesReceived[client] = rapesReceived;
	strcopy(g_szLastRapists[client], HISTORY_STRING_LEN, lastRapists);
	g_bStatsLoaded[client] = true;
	CancelStatsRetryTimer(client);
}

	void SaveClientStats(int client)
	{
		if (!IsHumanClient(client))
		{
			return;
		}

		if (!g_bStatsLoaded[client])
		{
			return;
		}

		if (!IsDatabaseReady())
		{
			return;
		}

		if (!EnsureClientSteamId(client))
		{
			return;
		}

		char steamEsc[96];
		SQL_EscapeString(g_hDatabase, g_szClientSteamId[client], steamEsc, sizeof(steamEsc));

		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));
		char nameEsc[MAX_NAME_LENGTH * 2 + 1];
		SQL_EscapeString(g_hDatabase, name, nameEsc, sizeof(nameEsc));

	char rapistsEsc[HISTORY_STRING_LEN * 2 + 1];
	char huggerEscaped[MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH * 2 + 1];
	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		SQL_EscapeString(g_hDatabase, g_szLastHuggers[client][i], huggerEscaped[i], sizeof(huggerEscaped[]));
	}
	SQL_EscapeString(g_hDatabase, g_szLastRapists[client], rapistsEsc, sizeof(rapistsEsc));

    char query[2048];
    Format(query, sizeof(query), "REPLACE INTO %s (steamid, name, hugs_given, hugs_received, rapes_given, rapes_received, last_hugger1, last_hugger2, last_hugger3, last_hugger4, last_hugger5, last_rapists) VALUES ('%s', '%s', %d, %d, %d, %d, '%s', '%s', '%s', '%s', '%s', '%s')",
        HUGS_DB_TABLE, steamEsc, nameEsc, g_iHugsGiven[client], g_iHugsReceived[client], g_iRapesGiven[client], g_iRapesReceived[client],
        huggerEscaped[0], huggerEscaped[1], huggerEscaped[2], huggerEscaped[3], huggerEscaped[4], rapistsEsc);

		SQL_TQuery(g_hDatabase, SQL_OnStatsSaved, query);
	}

	public void SQL_OnStatsSaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] Failed to save stats: %s", error);
		}
	}

	public void SQL_OnPrapeSaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] Failed to update rapes_given: %s", error);
		}
	}

	void ConnectToDatabase()
	{
		if (g_hDatabase != null)
		{
			delete g_hDatabase;
			g_hDatabase = null;
		}

		if (g_hDbReconnectTimer != null)
		{
			CloseHandle(g_hDbReconnectTimer);
			g_hDbReconnectTimer = null;
		}

		if (!SQL_CheckConfig(HUGS_DB_CONFIG))
		{
			LogError("[Hugs] Database config '%s' not found.", HUGS_DB_CONFIG);
			return;
		}

		SQL_TConnect(SQL_OnDatabaseConnected, HUGS_DB_CONFIG);
	}

	public Action Timer_ReconnectDatabase(Handle timer, any data)
	{
		g_hDbReconnectTimer = null;
		ConnectToDatabase();
		return Plugin_Stop;
	}

	public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
	{
		if (hndl == null)
		{
			LogError("[Hugs] Failed to connect to database: %s", error[0] ? error : "unknown error");
			if (g_hDbReconnectTimer == null)
			{
				g_hDbReconnectTimer = CreateTimer(10.0, Timer_ReconnectDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
			}
			return;
		}

		g_hDatabase = view_as<Database>(hndl);
		EnsureStatsTable();
	}

	void EnsureStatsTable()
	{
		if (!IsDatabaseReady())
		{
			return;
		}

		g_iSchemaOpsPending = 0;

		char query[2048];
		Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (steamid VARCHAR(64) PRIMARY KEY, name VARCHAR(%d) NOT NULL DEFAULT '', hugs_given INTEGER NOT NULL DEFAULT 0, hugs_received INTEGER NOT NULL DEFAULT 0, rapes_given INTEGER NOT NULL DEFAULT 0, rapes_received INTEGER NOT NULL DEFAULT 0, last_hugger1 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger2 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger3 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger4 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger5 VARCHAR(%d) NOT NULL DEFAULT '', last_rapists VARCHAR(%d) NOT NULL DEFAULT '')",
			HUGS_DB_TABLE, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, HISTORY_STRING_LEN);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		// Add name column if it doesn't exist (for existing tables)
		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS name VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, MAX_NAME_LENGTH);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS last_rapists VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, HISTORY_STRING_LEN);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		static const char g_LastHuggerColumns[MAX_HISTORY_ENTRIES][16] =
		{
			"last_hugger1",
			"last_hugger2",
			"last_hugger3",
			"last_hugger4",
			"last_hugger5"
		};

		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, g_LastHuggerColumns[i], MAX_NAME_LENGTH);
			g_iSchemaOpsPending++;
			SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);
		}
	}

	void RequestStatsReload()
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i) && !IsFakeClient(i))
			{
				AttemptLoadClientStats(i);
			}
		}
	}

	public void SQLErrorCheckCallback(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] SQL error: %s", error);
		}
	}

	public void SQL_OnSchemaOpComplete(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] SQL error: %s", error);
		}

		if (g_iSchemaOpsPending > 0)
		{
			g_iSchemaOpsPending--;
		}

		if (g_iSchemaOpsPending == 0)
		{
			RequestStatsReload();
		}
	}
