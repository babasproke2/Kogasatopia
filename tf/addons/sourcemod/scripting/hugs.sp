#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <dbi>

#include <sdktools>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <filters_api>
#define REQUIRE_PLUGIN

#include "include/database.inc"
#include "include/steam_identity.inc"

	public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
	{
		RegPluginLibrary("hugs");
		CreateNative("Hugs_GetRapesGiven", Native_Hugs_GetRapesGiven);
		CreateNative("Hugs_AreStatsLoaded", Native_Hugs_AreStatsLoaded);
		CreateNative("Hugs_RedeemMailedHug", Native_Hugs_RedeemMailedHug);
		CreateNative("Hugs_RedeemMailedFeed", Native_Hugs_RedeemMailedFeed);
		CreateNative("Hugs_RedeemMailedRape", Native_Hugs_RedeemMailedRape);
		CreateNative("Hugs_AnnounceMailedInteraction", Native_Hugs_AnnounceMailedInteraction);
		MarkNativeAsOptional("Filters_IsRedlisted");
		MarkNativeAsOptional("Filters_GetChatName");
		MarkNativeAsOptional("Filters_GetSteamIdColorTag");
		MarkNativeAsOptional("Filters_GetSteamIdChatName");
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
#define HUGS_DUEL_HISTORY_TABLE "hugs_duel_history"
#define MAX_HISTORY_ENTRIES 5
#define HISTORY_STRING_LEN 256

int g_iHugsReceived[MAXPLAYERS + 1];
int g_iHugsGiven[MAXPLAYERS + 1];
int g_iFeedsReceived[MAXPLAYERS + 1];
int g_iFeedsGiven[MAXPLAYERS + 1];
int g_iRapesReceived[MAXPLAYERS + 1];
int g_iRapesGiven[MAXPLAYERS + 1];
char g_szLastHuggers[MAXPLAYERS + 1][MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH];
char g_szLastFeeders[MAXPLAYERS + 1][MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH];
char g_szLastRapists[MAXPLAYERS + 1][HISTORY_STRING_LEN];
	char g_szClientSteamId[MAXPLAYERS + 1][32];
	bool g_bStatsLoaded[MAXPLAYERS + 1];
	bool g_bStatsPending[MAXPLAYERS + 1];

	Database g_hDatabase = null;
bool g_bDatabaseReady = false;
Handle g_hDbReconnectTimer = null;
ConVar g_hMultiplierCvar = null;
int g_iMultiplier = 1;
Handle g_hReminderTimer[MAXPLAYERS + 1];
Handle g_hStatsRetryTimer[MAXPLAYERS + 1];
int g_iSchemaOpsPending = 0;
Handle g_hRedlistCookie = INVALID_HANDLE;

enum HugsLeaderboardKind
{
	HugsLeaderboard_Hugs = 0,
	HugsLeaderboard_Rapes
};

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

	public any Native_Hugs_RedeemMailedHug(Handle plugin, int numParams)
	{
		return Native_RedeemMailedInteraction(false, false);
	}

	public any Native_Hugs_RedeemMailedFeed(Handle plugin, int numParams)
	{
		return Native_RedeemMailedInteraction(false, true);
	}

	public any Native_Hugs_RedeemMailedRape(Handle plugin, int numParams)
	{
		return Native_RedeemMailedInteraction(true, false);
	}

	public any Native_Hugs_AnnounceMailedInteraction(Handle plugin, int numParams)
	{
		int receiver = GetNativeCell(1);
		char senderSteamId64[KOGASA_STEAMID_MAX];
		char senderName[MAX_NAME_LENGTH];
		char interactionType[16];
		GetNativeString(2, senderSteamId64, sizeof(senderSteamId64));
		GetNativeString(3, senderName, sizeof(senderName));
		GetNativeString(4, interactionType, sizeof(interactionType));

		if (!IsHumanClient(receiver) || !Kogasa_IsSteamId64(senderSteamId64))
		{
			return false;
		}

		bool rape = StrEqual(interactionType, "rape");
		bool feed = StrEqual(interactionType, "feed");
		if (!rape && !feed && !StrEqual(interactionType, "hug"))
		{
			return false;
		}

		int sender = Kogasa_FindClientBySteamId64(senderSteamId64);
		AnnounceMailedInteraction(sender, receiver, senderSteamId64, senderName, rape, feed);
		return true;
	}

	bool Native_RedeemMailedInteraction(bool rape, bool feed)
	{
		char senderSteamId64[KOGASA_STEAMID_MAX];
		char receiverSteamId64[KOGASA_STEAMID_MAX];
		char senderName[MAX_NAME_LENGTH];
		GetNativeString(1, senderSteamId64, sizeof(senderSteamId64));
		GetNativeString(2, receiverSteamId64, sizeof(receiverSteamId64));
		GetNativeString(3, senderName, sizeof(senderName));
		return ApplyMailedInteraction(senderSteamId64, receiverSteamId64, senderName, rape, feed);
	}

	bool ApplyMailedInteraction(
		const char[] senderSteamId64,
		const char[] receiverSteamId64,
		const char[] senderName,
		bool rape,
		bool feed)
	{
		if (!IsDatabaseReady() || senderName[0] == '\0'
			|| !Kogasa_IsSteamId64(senderSteamId64)
			|| !Kogasa_IsSteamId64(receiverSteamId64)
			|| StrEqual(senderSteamId64, receiverSteamId64, false))
		{
			return false;
		}

		int receiver = Kogasa_FindClientBySteamId64(receiverSteamId64);
		if (!IsHumanClient(receiver) || !EnsureStatsReady(receiver, false))
		{
			return false;
		}
		if (rape && IsRapeProtected(receiver))
		{
			CPrintToChat(receiver, "{green}[Hugs]{default} Your rape protection blocked that mailed interaction.");
			return false;
		}

		int sender = Kogasa_FindClientBySteamId64(senderSteamId64);
		if (sender > 0 && !EnsureStatsReady(sender, false))
		{
			return false;
		}

		int amount = GetEffectiveMultiplier();
		if (sender > 0)
		{
			if (rape)
			{
				g_iRapesGiven[sender] += amount;
			}
			else if (feed)
			{
				g_iFeedsGiven[sender] += amount;
			}
			else
			{
				g_iHugsGiven[sender] += amount;
			}
			SaveClientStats(sender);
		}
		else if (!CreditOfflineMailedInteraction(senderSteamId64, senderName, rape, feed, amount))
		{
			return false;
		}

		if (rape)
		{
			g_iRapesReceived[receiver] += amount;
			UpdateLastRapistsByName(receiver, senderName);
			if (sender > 0)
			{
				checkRapeChievements(sender);
			}
		}
		else if (feed)
		{
			g_iFeedsReceived[receiver] += amount;
			UpdateLastFeeders(receiver, senderName);
		}
		else
		{
			g_iHugsReceived[receiver] += amount;
			UpdateLastHuggers(receiver, senderName);
		}
		SaveClientStats(receiver);
		AnnounceMailedInteraction(sender, receiver, senderSteamId64, senderName, rape, feed);
		return true;
	}

	void AnnounceMailedInteraction(
		int sender,
		int receiver,
		const char[] senderSteamId64,
		const char[] senderName,
		bool rape,
		bool feed)
	{
		char senderDisplay[256];
		BuildMailedHugsChatName(sender, senderSteamId64, senderName, senderDisplay, sizeof(senderDisplay));

		char receiverDisplay[256];
		BuildHugsChatName(receiver, receiverDisplay, sizeof(receiverDisplay));
		char action[16];
		strcopy(action, sizeof(action), rape ? "raped" : (feed ? "fed" : "hugged"));

		if (!IsClientRedlisted(receiver))
		{
			CPrintToChatEx(receiver, sender > 0 ? sender : receiver,
				"{green}[Hugs] %s{default} %s you!", senderDisplay, action);
		}
		if (sender > 0)
		{
			CPrintToChatEx(sender, receiver,
				"{green}[Hugs]{default} You %s %s{default}!", action, receiverDisplay);
		}
	}

	void BuildMailedHugsChatName(
		int client,
		const char[] steamId64,
		const char[] fallbackName,
		char[] buffer,
		int maxlen)
	{
		if (client > 0)
		{
			BuildHugsChatName(client, buffer, maxlen);
			return;
		}
		if (GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdChatName") == FeatureStatus_Available
			&& Filters_GetSteamIdChatName(steamId64, fallbackName, buffer, maxlen)
			&& buffer[0])
		{
			return;
		}

		char colorTag[32];
		colorTag[0] = '\0';
		if (GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdColorTag") == FeatureStatus_Available)
		{
			Filters_GetSteamIdColorTag(steamId64, colorTag, sizeof(colorTag));
		}
		if (!colorTag[0])
		{
			strcopy(colorTag, sizeof(colorTag), "{green}");
		}
		Format(buffer, maxlen, "%s%s", colorTag, fallbackName);
	}

	bool CreditOfflineMailedInteraction(
		const char[] senderSteamId64,
		const char[] senderName,
		bool rape,
		bool feed,
		int amount)
	{
		char senderSteam2[KOGASA_STEAMID_MAX];
		if (!Kogasa_ConvertSteamId64ToSteam2(senderSteamId64, senderSteam2, sizeof(senderSteam2)))
		{
			return false;
		}

		char steamEsc[96];
		char nameEsc[(MAX_NAME_LENGTH * 2) + 1];
		if (!Db_Escape(g_hDatabase, senderSteam2, steamEsc, sizeof(steamEsc), "Hugs")
			|| !Db_Escape(g_hDatabase, senderName, nameEsc, sizeof(nameEsc), "Hugs"))
		{
			return false;
		}

		char column[32];
		strcopy(column, sizeof(column), rape ? "rapes_given" : (feed ? "feeds_given" : "hugs_given"));
		char query[768];
		FormatEx(query, sizeof(query),
			"INSERT INTO %s (steamid, name, %s) VALUES ('%s', '%s', %d) "
			... "ON DUPLICATE KEY UPDATE name = VALUES(name), %s = %s + %d",
			HUGS_DB_TABLE, column, steamEsc, nameEsc, amount, column, column, amount);
		SQL_TQuery(g_hDatabase, SQL_OnMailedInteractionSaved, query);
		return true;
	}

	public void SQL_OnMailedInteractionSaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0] != '\0')
		{
			LogError("[Hugs] Failed to credit mailed interaction: %s", error);
		}
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
	char g_szDuelSteamIds[2][32];
	char g_szDuelNames[2][MAX_NAME_LENGTH];

	Handle g_hRequestTimer = null;

	// --- ConVars ---
	ConVar g_hTargetScore;
	ConVar g_hRequestTimeout;
	ConVar g_hRapeProtectionDuration;
	Handle g_hRapeProtectionTimer[MAXPLAYERS + 1];
	int g_iRapeProtectorUserId[MAXPLAYERS + 1];
	char g_szRapeProtectorName[MAXPLAYERS + 1][MAX_NAME_LENGTH + 32];
	char g_szRapeProtectedName[MAXPLAYERS + 1][MAX_NAME_LENGTH + 32];

	public void OnPluginStart()
	{
		LoadTranslations("common.phrases");

		RegConsoleCmd("sm_hug", Command_Hug, "Hug another player by name");
		RegConsoleCmd("sm_feed", Command_Feed, "Feed another player by name");
		RegConsoleCmd("sm_rape", Command_Rape, "Rape another player by name");
		RegConsoleCmd("sm_checkhugs", Command_CheckHugs, "Check your total hugs received and given");
		RegConsoleCmd("sm_checkrapes", Command_CheckRapes, "Check your total rapes received and given");
		RegConsoleCmd("sm_hugcheck", Command_CheckHugs, "Check your total hugs received and given");
		RegConsoleCmd("sm_rapecheck", Command_CheckRapes, "Check your total rapes received and given");
		RegConsoleCmd("sm_hugs", Command_CheckHugs); // Alias for !checkhugs
		RegConsoleCmd("sm_feeds", Command_CheckFeeds); // Alias for !feeds
		RegConsoleCmd("sm_fed", Command_CheckFeeds); // Alias for !fed
		RegConsoleCmd("sm_rapes", Command_CheckRapes); // Alias for !checkrapes

		RegAdminCmd("sm_prape", Command_Prape, ADMFLAG_SLAY, "sm_prape <player> - Sets rapes_given to at least 1");

		AddCommandListener(Hugs_SayListener, "say");
		AddCommandListener(Hugs_SayListener, "say_team");

		RegConsoleCmd("sm_hl", Command_Leaderboard, "Show hugs leaderboard");
		RegConsoleCmd("sm_hl2", Command_Leaderboard, "Show hugs received leaderboard");
		RegConsoleCmd("sm_rl", Command_Leaderboard, "Show rapes leaderboard");
		RegConsoleCmd("sm_rl2", Command_Leaderboard, "Show rapes received leaderboard");
		RegConsoleCmd("sm_leaderboard", Command_Leaderboard, "Show rapes leaderboard");
		RegConsoleCmd("sm_rapesleaderboard", Command_Leaderboard, "Show rapes leaderboard");
		RegConsoleCmd("sm_hugsleaderboard", Command_Leaderboard, "Show hugs leaderboard");

		// Set default values for cookies if they don't exist
		SetCookieMenuItem(StatsCookieMenuHandler, 0, "Hug/Rape Stats");
		
		RegConsoleCmd("sm_duel",   Command_Duel,   "Challenge a player: !duel <name substring>");
		RegConsoleCmd("sm_rapeduel",   Command_Duel,   "Alias of !duel");
		RegConsoleCmd("sm_duelhistory", Command_DuelHistory, "Show recent duel victories");
		RegConsoleCmd("sm_rapeduelhistory", Command_DuelHistory, "Show recent duel victories");
		RegConsoleCmd("sm_accept", Command_Accept, "Accept a pending duel");
		RegConsoleCmd("sm_protect", Command_RapeProtect, "Protect a player from rape");
		RegConsoleCmd("sm_guard", Command_RapeProtect, "Protect a player from rape");
		RegConsoleCmd("sm_rapeprotect", Command_RapeProtect, "Protect a player from rape");
		RegConsoleCmd("sm_rapeshield", Command_RapeProtect, "Protect a player from rape");
		RegConsoleCmd("sm_shield", Command_RapeProtect, "Protect a player from rape");
		RegConsoleCmd("sm_defend", Command_RapeProtect, "Protect a player from rape");

		HookEvent("player_death",            Event_PlayerDeath, EventHookMode_Post);
		HookEvent("teamplay_round_win",      Event_RoundEnd,    EventHookMode_Post);
		HookEvent("teamplay_round_stalemate",Event_RoundEnd,    EventHookMode_Post);

		g_hTargetScore    = CreateConVar("sm_rapeduel_targetscore", "5",  "rapes needed to win a duel", _, true, 1.0);
		g_hRequestTimeout = CreateConVar("sm_rapeduel_requesttime", "30", "Seconds before a duel request expires", _, true, 5.0);
		g_hRapeProtectionDuration = CreateConVar("sm_rapeprotection_duration", "60", "Seconds that rape protection lasts.", _, true, 1.0);

		AutoExecConfig(true, "rapeduel");

		for (int i = 1; i <= MaxClients; i++)
		{
			ResetClientStats(i);
			g_fLastHugTime[i] = 0.0;
			g_fLastRapeTime[i] = 0.0;
			g_hReminderTimer[i] = null;
			g_hStatsRetryTimer[i] = null;
			g_hRapeProtectionTimer[i] = null;
			g_iRapeProtectorUserId[i] = 0;
			g_szRapeProtectorName[i][0] = '\0';
			g_szRapeProtectedName[i][0] = '\0';
		}

		g_hMultiplierCvar = CreateConVar("sm_hugs_multiplier", "1", "Multiplier for hug/rape stats (0 or 1 disable).", FCVAR_NOTIFY);
		g_hMultiplierCvar.AddChangeHook(ConVarChanged_Multiplier);
		UpdateMultiplierValue();

		ConnectToDatabase();
		EnsureRedlistCookie();
	}

	public void OnPluginEnd()
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			ClearRapeProtection(i, true);
		}
		Db_CancelTimer(g_hDbReconnectTimer);
		Db_Close(g_hDatabase, g_bDatabaseReady);
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

		if (!StrEqual(cmdName, "hug", false) && !StrEqual(cmdName, "feed", false) && !StrEqual(cmdName, "rape", false))
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
		else if (StrEqual(cmdName, "feed", false))
		{
			if (args[0])
			{
				FakeClientCommand(client, "sm_feed %s", args);
			}
			else
			{
				FakeClientCommand(client, "sm_feed");
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
		ClearRapeProtection(client, true);
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
		ClearRapeProtection(client, true);
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
				int winnerScore = (winner == g_iRequester) ? g_iScoreReq : g_iScoreTgt;
				int loserScore = (winner == g_iRequester) ? g_iScoreTgt : g_iScoreReq;
				RecordDuelVictory(winner, client, winnerScore, loserScore, "forfeit");
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

	HugsLeaderboardKind GetLeaderboardKindFromCommand()
	{
		char command[64];
		GetCmdArg(0, command, sizeof(command));

		if (StrEqual(command, "sm_hl", false) || StrEqual(command, "sm_hl2", false) || StrEqual(command, "sm_hugsleaderboard", false))
		{
			return HugsLeaderboard_Hugs;
		}

		return HugsLeaderboard_Rapes;
	}

	bool IsLeaderboardReceivedFirstCommand()
	{
		char command[64];
		GetCmdArg(0, command, sizeof(command));
		return StrEqual(command, "sm_hl2", false) || StrEqual(command, "sm_rl2", false);
	}

	public Action Command_Leaderboard(int client, int args)
	{
		if (!IsClientIndexValid(client) || !IsClientInGame(client))
		{
			return Plugin_Handled;
		}

		if (!IsDatabaseReady())
		{
			ReplyToCommand(client, "[SM] Database not ready.");
			return Plugin_Handled;
		}

		HugsLeaderboardKind kind = GetLeaderboardKindFromCommand();
		bool receivedFirst = IsLeaderboardReceivedFirstCommand();
		char givenColumn[32];
		char receivedColumn[32];
		if (kind == HugsLeaderboard_Hugs)
		{
			strcopy(givenColumn, sizeof(givenColumn), "h.hugs_given");
			strcopy(receivedColumn, sizeof(receivedColumn), "h.hugs_received");
		}
		else
		{
			strcopy(givenColumn, sizeof(givenColumn), "h.rapes_given");
			strcopy(receivedColumn, sizeof(receivedColumn), "h.rapes_received");
		}

		char primaryColumn[32];
		char secondaryColumn[32];
		strcopy(primaryColumn, sizeof(primaryColumn), receivedFirst ? receivedColumn : givenColumn);
		strcopy(secondaryColumn, sizeof(secondaryColumn), receivedFirst ? givenColumn : receivedColumn);

		char steam64Expr[288];
		strcopy(steam64Expr, sizeof(steam64Expr), "CONVERT(CAST(76561197960265728 + (SUBSTRING_INDEX(h.steamid, ':', -1) * 2) + SUBSTRING_INDEX(SUBSTRING_INDEX(h.steamid, ':', 2), ':', -1) AS CHAR) USING utf8mb4)");

		char query[2048];
		Format(query, sizeof(query),
			"SELECT h.name, %s AS given_count, %s AS received_count, h.steamid, "
			... "COALESCE(NULLIF(pr.newname, ''), NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, '')) AS wt_name "
			... "FROM %s h "
			... "LEFT JOIN prename_rules pr ON pr.pattern = %s COLLATE utf8mb4_general_ci "
			... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = %s COLLATE utf8mb4_uca1400_ai_ci "
			... "LEFT JOIN whaletracker w ON w.steamid = %s COLLATE utf8mb4_uca1400_ai_ci "
			... "WHERE %s > 0 OR %s > 0 "
			... "ORDER BY %s DESC, %s DESC, h.name ASC LIMIT 10",
			givenColumn,
			receivedColumn,
			HUGS_DB_TABLE,
			steam64Expr,
			steam64Expr,
			steam64Expr,
			givenColumn,
			receivedColumn,
			primaryColumn,
			secondaryColumn);

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		pack.WriteCell(view_as<int>(kind));
		SQL_TQuery(g_hDatabase, SQL_OnLeaderboardLoaded, query, pack);
		return Plugin_Handled;
	}

	public void SQL_OnLeaderboardLoaded(Database db, DBResultSet results, const char[] error, any data)
	{
		DataPack pack = view_as<DataPack>(data);
		pack.Reset();
		int client = GetClientOfUserId(pack.ReadCell());
		HugsLeaderboardKind kind = view_as<HugsLeaderboardKind>(pack.ReadCell());
		delete pack;

		if (!IsClientIndexValid(client) || !IsClientInGame(client))
		{
			return;
		}

		if (error[0])
		{
			LogError("[Hugs] Failed to load leaderboard: %s", error);
			CPrintToChat(client, "[SM] Failed to load leaderboard.");
			return;
		}

		CPrintToChat(client, (kind == HugsLeaderboard_Hugs) ? "{green}[Hugs Leaderboard]" : "{green}[Rapes Leaderboard]");
		int rank = 1;
		while (results.FetchRow())
		{
			char name[MAX_NAME_LENGTH];
			results.FetchString(0, name, sizeof(name));
			int given = results.FetchInt(1);
			int received = results.FetchInt(2);
			
			char steamid[64];
			results.FetchString(3, steamid, sizeof(steamid));
			
			char wt_name[MAX_NAME_LENGTH];
			results.FetchString(4, wt_name, sizeof(wt_name));

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

			if (kind == HugsLeaderboard_Hugs)
			{
				CPrintToChat(client, "{default}#%d: {gold}%s {default} Hugs: {gold}%d | Received: {crimson}%d", rank, name, given, received);
			}
			else
			{
				char rankStr[64];
				GetRapeRank(given, rankStr, sizeof(rankStr));
				CPrintToChat(client, "{default}#%d: {gold}%s {default} Rapes: {gold}%d | Received: {crimson}%d {default}| {olive}%s", rank, name, given, received, rankStr);
			}
			rank++;
		}

		if (rank == 1)
		{
			CPrintToChat(client, "{default}No leaderboard entries yet.");
		}
	}

	/* ---------------- Commands ---------------- */

	public Action Command_RapeProtect(int client, int args)
	{
		if (!IsHumanClientInGame(client))
		{
			return Plugin_Handled;
		}

		if (args < 1)
		{
			CPrintToChat(client, "{green}[Hugs]{default} Usage: !protect <player>");
			return Plugin_Handled;
		}

		char targetArg[MAX_TARGET_LENGTH];
		GetCmdArg(1, targetArg, sizeof(targetArg));
		int target = FindTarget(client, targetArg, true, false);
		if (target <= 0)
		{
			return Plugin_Handled;
		}

		if (target == client)
		{
			CPrintToChat(client, "{green}[Hugs]{default} You cannot protect yourself.");
			return Plugin_Handled;
		}

		if (IsRapeProtected(target))
		{
			CPrintToChat(client, "{green}[Hugs]{default} %N is already protected.", target);
			return Plugin_Handled;
		}

		BuildHugsChatName(client, g_szRapeProtectorName[target], sizeof(g_szRapeProtectorName[]));
		BuildHugsChatName(target, g_szRapeProtectedName[target], sizeof(g_szRapeProtectedName[]));
		g_iRapeProtectorUserId[target] = GetClientUserId(client);
		float duration = g_hRapeProtectionDuration.FloatValue;
		g_hRapeProtectionTimer[target] = CreateTimer(duration, Timer_RapeProtectionExpired, GetClientSerial(target));

		CPrintToChatAllEx(client, "{green}[Hugs]{default} %s{default} is now protecting %s{default} from rape!", g_szRapeProtectorName[target], g_szRapeProtectedName[target]);
		return Plugin_Handled;
	}

	public Action Timer_RapeProtectionExpired(Handle timer, any targetSerial)
	{
		int target = GetClientFromSerial(targetSerial);
		if (!IsClientIndexValid(target) || g_hRapeProtectionTimer[target] != timer)
		{
			return Plugin_Stop;
		}

		g_hRapeProtectionTimer[target] = null;
		if (IsHumanClientInGame(target))
		{
			CPrintToChatAllEx(target, "{green}[Hugs]{default} %s{default}'s rape protection of %s{default} has now expired!", g_szRapeProtectorName[target], g_szRapeProtectedName[target]);
		}
		g_iRapeProtectorUserId[target] = 0;
		g_szRapeProtectorName[target][0] = '\0';
		g_szRapeProtectedName[target][0] = '\0';
		return Plugin_Stop;
	}

	bool IsRapeProtected(int target)
	{
		return IsClientIndexValid(target)
			&& g_hRapeProtectionTimer[target] != null
			&& g_iRapeProtectorUserId[target] > 0;
	}

	void ClearRapeProtection(int target, bool killTimer)
	{
		if (!IsClientIndexValid(target))
		{
			return;
		}

		if (killTimer && g_hRapeProtectionTimer[target] != null)
		{
			KillTimer(g_hRapeProtectionTimer[target]);
		}
		g_hRapeProtectionTimer[target] = null;
		g_iRapeProtectorUserId[target] = 0;
		g_szRapeProtectorName[target][0] = '\0';
		g_szRapeProtectedName[target][0] = '\0';
	}

	void BuildHugsChatName(int client, char[] buffer, int maxlen)
	{
		if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
			&& Filters_GetChatName(client, buffer, maxlen)
			&& buffer[0])
		{
			return;
		}

		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));
		Format(buffer, maxlen, "{default}%s", name);
	}

	public Action Command_DuelHistory(int client, int args)
	{
		if (!IsHumanClientInGame(client))
		{
			return Plugin_Handled;
		}

		if (!IsDatabaseReady())
		{
			CPrintToChat(client, "{green}[Hugs]{default} The duel history database is not ready.");
			return Plugin_Handled;
		}

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientUserId(client));
		char query[384];
		Format(query, sizeof(query),
			"SELECT id, winner_name, loser_name, winner_score, loser_score, finished_at FROM %s ORDER BY finished_at DESC, id DESC LIMIT 25",
			HUGS_DUEL_HISTORY_TABLE);
		SQL_TQuery(g_hDatabase, SQL_OnDuelHistoryLoaded, query, pack);
		return Plugin_Handled;
	}

	public void SQL_OnDuelHistoryLoaded(Database db, DBResultSet results, const char[] error, any data)
	{
		DataPack pack = view_as<DataPack>(data);
		pack.Reset();
		int client = GetClientOfUserId(pack.ReadCell());
		delete pack;
		if (!IsHumanClientInGame(client))
		{
			return;
		}

		if (error[0])
		{
			LogError("[Hugs] Failed to load duel history: %s", error);
			CPrintToChat(client, "{green}[Hugs]{default} Could not load duel history.");
			return;
		}

		Menu menu = new Menu(MenuHandler_DuelHistory);
		menu.SetTitle("Recent Rape Duels");
		int count = 0;
		while (results != null && results.FetchRow())
		{
			int duelId = results.FetchInt(0);
			char winnerName[MAX_NAME_LENGTH], loserName[MAX_NAME_LENGTH];
			char cleanWinner[MAX_NAME_LENGTH], cleanLoser[MAX_NAME_LENGTH];
			char finishedAt[32], info[16], display[192];
			results.FetchString(1, winnerName, sizeof(winnerName));
			results.FetchString(2, loserName, sizeof(loserName));
			int winnerScore = results.FetchInt(3);
			int loserScore = results.FetchInt(4);
			int finishedTimestamp = results.FetchInt(5);

			StripMenuColorTags(winnerName, cleanWinner, sizeof(cleanWinner));
			StripMenuColorTags(loserName, cleanLoser, sizeof(cleanLoser));
			FormatTime(finishedAt, sizeof(finishedAt), "%m/%d %H:%M", finishedTimestamp);
			IntToString(duelId, info, sizeof(info));
			Format(display, sizeof(display), "#%d %s - %s defeated %s (%d-%d)", duelId, finishedAt, cleanWinner, cleanLoser, winnerScore, loserScore);
			menu.AddItem(info, display, ITEMDRAW_DISABLED);
			count++;
		}

		if (count == 0)
		{
			menu.AddItem("none", "No completed duels found.", ITEMDRAW_DISABLED);
		}
		menu.ExitButton = true;
		menu.Display(client, MENU_TIME_FOREVER);
	}

	public int MenuHandler_DuelHistory(Menu menu, MenuAction action, int client, int item)
	{
		if (action == MenuAction_End)
		{
			delete menu;
		}
		return 0;
	}

	void StripMenuColorTags(const char[] input, char[] output, int maxlen)
	{
		int out = 0;
		bool inTag = false;
		for (int i = 0; input[i] != '\0' && out < maxlen - 1; i++)
		{
			if (input[i] == '{')
			{
				inTag = true;
				continue;
			}
			if (inTag)
			{
				if (input[i] == '}')
				{
					inTag = false;
				}
				continue;
			}
			output[out++] = input[i];
		}
		output[out] = '\0';
	}

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

		if (!g_bDuelRequested || g_bDuelActive || client != g_iTarget)
			return Plugin_Continue;

		CancelRequestTimer();

		g_bDuelRequested = false;
		g_bDuelActive    = true;
		g_iScoreReq      = 0;
		g_iScoreTgt      = 0;
		CaptureDuelParticipantSnapshots();

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
			int winnerScore = (winner == g_iRequester) ? g_iScoreReq : g_iScoreTgt;
			int loserScore = (winner == g_iRequester) ? g_iScoreTgt : g_iScoreReq;
			RecordDuelVictory(winner, loser, winnerScore, loserScore, "target_score");
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
			int winnerScore = (winner == g_iRequester) ? g_iScoreReq : g_iScoreTgt;
			int loserScore = (winner == g_iRequester) ? g_iScoreTgt : g_iScoreReq;
			RecordDuelVictory(winner, loser, winnerScore, loserScore, "round_end");
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
		g_szDuelSteamIds[0][0] = '\0';
		g_szDuelSteamIds[1][0] = '\0';
		g_szDuelNames[0][0] = '\0';
		g_szDuelNames[1][0] = '\0';
	}

	void CaptureDuelParticipantSnapshots()
	{
		int clients[2];
		clients[0] = g_iRequester;
		clients[1] = g_iTarget;
		for (int i = 0; i < sizeof(clients); i++)
		{
			g_szDuelSteamIds[i][0] = '\0';
			g_szDuelNames[i][0] = '\0';
			if (!IsHumanClient(clients[i]))
			{
				continue;
			}

			Kogasa_GetClientSteamId64(clients[i], g_szDuelSteamIds[i], sizeof(g_szDuelSteamIds[]), true);
			GetClientName(clients[i], g_szDuelNames[i], sizeof(g_szDuelNames[]));
		}
	}

	void RecordDuelVictory(int winner, int loser, int winnerScore, int loserScore, const char[] resultType)
	{
		if (!IsDatabaseReady() || winnerScore < 0 || loserScore < 0)
		{
			return;
		}

		int winnerSlot = (winner == g_iRequester) ? 0 : 1;
		int loserSlot = (loser == g_iRequester) ? 0 : 1;
		if (!g_szDuelSteamIds[winnerSlot][0] || !g_szDuelSteamIds[loserSlot][0])
		{
			return;
		}

		char winnerSteamEsc[65], loserSteamEsc[65];
		char winnerNameEsc[(MAX_NAME_LENGTH * 2) + 1], loserNameEsc[(MAX_NAME_LENGTH * 2) + 1];
		char resultEsc[65];
		if (!Db_Escape(g_hDatabase, g_szDuelSteamIds[winnerSlot], winnerSteamEsc, sizeof(winnerSteamEsc), "Hugs")
			|| !Db_Escape(g_hDatabase, g_szDuelSteamIds[loserSlot], loserSteamEsc, sizeof(loserSteamEsc), "Hugs")
			|| !Db_Escape(g_hDatabase, g_szDuelNames[winnerSlot], winnerNameEsc, sizeof(winnerNameEsc), "Hugs")
			|| !Db_Escape(g_hDatabase, g_szDuelNames[loserSlot], loserNameEsc, sizeof(loserNameEsc), "Hugs")
			|| !Db_Escape(g_hDatabase, resultType, resultEsc, sizeof(resultEsc), "Hugs"))
		{
			return;
		}

		char query[1024];
		Format(query, sizeof(query),
			"INSERT INTO %s (winner_steamid64, winner_name, loser_steamid64, loser_name, winner_score, loser_score, result_type, finished_at) VALUES ('%s', '%s', '%s', '%s', %d, %d, '%s', %d)",
			HUGS_DUEL_HISTORY_TABLE,
			winnerSteamEsc,
			winnerNameEsc,
			loserSteamEsc,
			loserNameEsc,
			winnerScore,
			loserScore,
			resultEsc,
			GetTime());
		SQL_TQuery(g_hDatabase, SQL_OnDuelVictorySaved, query);
	}

	public void SQL_OnDuelVictorySaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] Failed to save duel victory: %s", error);
		}
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
			ReplyToCommand(client, "[SM] Usage: !hug <name>");
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
			ReplyToCommand(client, "[SM] You must wait %.1f seconds before hugging again.", remaining);
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

	public Action Command_Feed(int client, int args)
	{
		if (args < 1)
		{
			ReplyToCommand(client, "[SM] Usage: !feed <name>");
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
			ReplyToCommand(client, "[SM] You must wait %.1f seconds before feeding again.", remaining);
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
				PrintToChat(target, "\x01[SM] \x04%s \x01fed you!", clientName);
			}

			// Send message to the sender
			PrintToChat(client, "\x01[SM] You fed \x04%s\x01!", targetNameDisplay);

			// Update feed stats
			// If it's a group target, we don't increment per target here
			UpdateFeedStats(client, target, !isGroupTarget);

			// Update last feeders list
			UpdateLastFeeders(target, clientName);

			successCount++;
		}

		if (isGroupTarget && successCount > 0)
		{
			int amount = GetEffectiveMultiplier();
			g_iFeedsGiven[client] += amount;
			SaveClientStats(client);
		}

		if (successCount > 0)
		{
			PrintToChat(client, "\x01[SM] Use !feeds to check your stats.");
			g_fLastHugTime[client] = currentTime;
		}

		return Plugin_Handled;
	}

	public Action Command_Rape(int client, int args)
	{
		if (args < 1)
		{
			ReplyToCommand(client, "[SM] Usage: !rape <name>");
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
			ReplyToCommand(client, "[SM] You must wait %.1f seconds before raping again.", remaining);
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

			if (IsRapeProtected(target))
			{
				CPrintToChat(client, "{green}[Hugs]{default} %N is currently protected from rape.", target);
				continue;
			}

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

	public Action Command_CheckFeeds(int client, int args)
	{
		if (!EnsureStatsReady(client, true))
		{
			return Plugin_Handled;
		}

		char lastFeeders[HISTORY_STRING_LEN];
		BuildFeederHistoryString(client, lastFeeders, sizeof(lastFeeders));

		PrintToChat(client, "\x01[SM] Feeded: \x04%d\x01 | Fed: \x04%d", g_iFeedsReceived[client], g_iFeedsGiven[client]);
		PrintToChat(client, "\x01[SM] Last Feeders: \x04%s", lastFeeders);

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
			ReplyToCommand(client, "[SM] Usage: sm_prape <player>");
			return Plugin_Handled;
		}

		if (!IsDatabaseReady())
		{
			ReplyToCommand(client, "[SM] Database not ready.");
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
			Db_Escape(g_hDatabase, g_szClientSteamId[target], steamEsc, sizeof(steamEsc), "Hugs");

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
			ShowActivity2(client, "[SM] ", "Set rapes_given to 1 for %s", target_name);
		}
		else
		{
			ShowActivity2(client, "[SM] ", "Set rapes_given to 1 for %s", target_name);
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

	void UpdateFeedStats(int sender, int recipient, bool incrementSender = true)
	{
		if (!EnsureStatsReady(sender, false) || !EnsureStatsReady(recipient, false))
		{
			return;
		}

		int amount = GetEffectiveMultiplier();
		if (incrementSender)
		{
			g_iFeedsGiven[sender] += amount;
			SaveClientStats(sender);
		}
		g_iFeedsReceived[recipient] += amount;
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
		PrintToChat(sender, "[SM] %i rapes have been credited to your account!", score1 * amount);

	g_iRapesReceived[recipient] += score2 * amount;
	PrintToChat(recipient, "[SM] you just received %i rapes!", score2 * amount);
		
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

void BuildFeederHistoryString(int client, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	bool appended = false;

	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		if (!g_szLastFeeders[client][i][0])
		{
			continue;
		}

		if (appended)
		{
			StrCat(buffer, maxlen, ", ");
		}

		StrCat(buffer, maxlen, g_szLastFeeders[client][i]);
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

void UpdateLastFeeders(int recipient, const char[] feederName)
{
	for (int i = MAX_HISTORY_ENTRIES - 1; i > 0; i--)
	{
		strcopy(g_szLastFeeders[recipient][i], MAX_NAME_LENGTH, g_szLastFeeders[recipient][i - 1]);
	}

	strcopy(g_szLastFeeders[recipient][0], MAX_NAME_LENGTH, feederName);
	SaveClientStats(recipient);
}

void UpdateLastRapists(int recipient, int sender)
{
	char rapistName[MAX_NAME_LENGTH];
	GetClientName(sender, rapistName, sizeof(rapistName));
	UpdateLastRapistsByName(recipient, rapistName);

	// Check for achievement progress from the sender
	checkRapeChievements(sender);
}

void UpdateLastRapistsByName(int recipient, const char[] rapistName)
{
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
		if (!Kogasa_GetClientSteam3(client, steamID, sizeof(steamID), true))
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
	g_iFeedsReceived[client] = 0;
	g_iFeedsGiven[client] = 0;
	g_iRapesReceived[client] = 0;
	g_iRapesGiven[client] = 0;
	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		g_szLastHuggers[client][i][0] = '\0';
		g_szLastFeeders[client][i][0] = '\0';
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
			PrintToChat(client, "[SM] Your hug/rape stats are still loading. Please wait.");
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
		if (!Kogasa_GetClientSteam2(client, auth, sizeof(auth), true))
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
		return Db_IsReady(g_hDatabase, g_bDatabaseReady);
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
		Db_Escape(g_hDatabase, g_szClientSteamId[client], steamEsc, sizeof(steamEsc), "Hugs");

	char query[768];
	Format(query, sizeof(query), "SELECT hugs_given, hugs_received, feeds_given, feeds_received, rapes_given, rapes_received, last_hugger1, last_hugger2, last_hugger3, last_hugger4, last_hugger5, last_feeder1, last_feeder2, last_feeder3, last_feeder4, last_feeder5, last_rapists FROM %s WHERE steamid = '%s'", HUGS_DB_TABLE, steamEsc);

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
		if (Db_IsTransientError(error))
		{
			ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
		}
		ScheduleStatsRetry(client);
		return;
	}

	int hugsGiven = 0;
	int hugsReceived = 0;
	int feedsGiven = 0;
	int feedsReceived = 0;
	int rapesGiven = 0;
	int rapesReceived = 0;
	char lastRapists[HISTORY_STRING_LEN];

	lastRapists[0] = '\0';

	if (results != null && results.FetchRow())
	{
		hugsGiven = results.FetchInt(0);
		hugsReceived = results.FetchInt(1);
		feedsGiven = results.FetchInt(2);
		feedsReceived = results.FetchInt(3);
		rapesGiven = results.FetchInt(4);
		rapesReceived = results.FetchInt(5);
		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			results.FetchString(6 + i, g_szLastHuggers[client][i], MAX_NAME_LENGTH);
			results.FetchString(11 + i, g_szLastFeeders[client][i], MAX_NAME_LENGTH);
		}
		results.FetchString(16, lastRapists, sizeof(lastRapists));
	}
	else
	{
		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			g_szLastHuggers[client][i][0] = '\0';
			g_szLastFeeders[client][i][0] = '\0';
		}
	}

	g_iHugsGiven[client] = hugsGiven;
	g_iHugsReceived[client] = hugsReceived;
	g_iFeedsGiven[client] = feedsGiven;
	g_iFeedsReceived[client] = feedsReceived;
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
		Db_Escape(g_hDatabase, g_szClientSteamId[client], steamEsc, sizeof(steamEsc), "Hugs");

		char name[MAX_NAME_LENGTH];
		GetClientName(client, name, sizeof(name));
		char nameEsc[MAX_NAME_LENGTH * 2 + 1];
		Db_Escape(g_hDatabase, name, nameEsc, sizeof(nameEsc), "Hugs");

	char rapistsEsc[HISTORY_STRING_LEN * 2 + 1];
	char huggerEscaped[MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH * 2 + 1];
	char feederEscaped[MAX_HISTORY_ENTRIES][MAX_NAME_LENGTH * 2 + 1];
	for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
	{
		Db_Escape(g_hDatabase, g_szLastHuggers[client][i], huggerEscaped[i], sizeof(huggerEscaped[]), "Hugs");
		Db_Escape(g_hDatabase, g_szLastFeeders[client][i], feederEscaped[i], sizeof(feederEscaped[]), "Hugs");
	}
	Db_Escape(g_hDatabase, g_szLastRapists[client], rapistsEsc, sizeof(rapistsEsc), "Hugs");

    char query[3072];
    Format(query, sizeof(query), "REPLACE INTO %s (steamid, name, hugs_given, hugs_received, feeds_given, feeds_received, rapes_given, rapes_received, last_hugger1, last_hugger2, last_hugger3, last_hugger4, last_hugger5, last_feeder1, last_feeder2, last_feeder3, last_feeder4, last_feeder5, last_rapists) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s')",
        HUGS_DB_TABLE, steamEsc, nameEsc, g_iHugsGiven[client], g_iHugsReceived[client], g_iFeedsGiven[client], g_iFeedsReceived[client], g_iRapesGiven[client], g_iRapesReceived[client],
        huggerEscaped[0], huggerEscaped[1], huggerEscaped[2], huggerEscaped[3], huggerEscaped[4],
        feederEscaped[0], feederEscaped[1], feederEscaped[2], feederEscaped[3], feederEscaped[4], rapistsEsc);

		SQL_TQuery(g_hDatabase, SQL_OnStatsSaved, query);
	}

	public void SQL_OnStatsSaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] Failed to save stats: %s", error);
			if (Db_IsTransientError(error))
			{
				ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
			}
		}
	}

	public void SQL_OnPrapeSaved(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] Failed to update rapes_given: %s", error);
			if (Db_IsTransientError(error))
			{
				ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
			}
		}
	}

	void ConnectToDatabase()
	{
		Db_CancelTimer(g_hDbReconnectTimer);
		Db_Close(g_hDatabase, g_bDatabaseReady);

		if (!Db_CheckConfigOrLog("Hugs", HUGS_DB_CONFIG))
		{
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

	void ScheduleDatabaseReconnect(float delay = DB_RECONNECT_DELAY)
	{
		g_bDatabaseReady = false;
		if (g_hDbReconnectTimer == null)
		{
			g_hDbReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
		}
	}

	public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
	{
		if (hndl == null)
		{
			LogError("[Hugs] Failed to connect to database: %s", error[0] ? error : "unknown error");
			ScheduleDatabaseReconnect();
			return;
		}

		g_hDatabase = view_as<Database>(hndl);
		g_bDatabaseReady = true;
		Db_CancelTimer(g_hDbReconnectTimer);
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
		Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (steamid VARCHAR(64) PRIMARY KEY, name VARCHAR(%d) NOT NULL DEFAULT '', hugs_given INTEGER NOT NULL DEFAULT 0, hugs_received INTEGER NOT NULL DEFAULT 0, feeds_given INTEGER NOT NULL DEFAULT 0, feeds_received INTEGER NOT NULL DEFAULT 0, rapes_given INTEGER NOT NULL DEFAULT 0, rapes_received INTEGER NOT NULL DEFAULT 0, last_hugger1 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger2 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger3 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger4 VARCHAR(%d) NOT NULL DEFAULT '', last_hugger5 VARCHAR(%d) NOT NULL DEFAULT '', last_feeder1 VARCHAR(%d) NOT NULL DEFAULT '', last_feeder2 VARCHAR(%d) NOT NULL DEFAULT '', last_feeder3 VARCHAR(%d) NOT NULL DEFAULT '', last_feeder4 VARCHAR(%d) NOT NULL DEFAULT '', last_feeder5 VARCHAR(%d) NOT NULL DEFAULT '', last_rapists VARCHAR(%d) NOT NULL DEFAULT '')",
			HUGS_DB_TABLE, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, MAX_NAME_LENGTH, HISTORY_STRING_LEN);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		// Add name column if it doesn't exist (for existing tables)
		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS name VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, MAX_NAME_LENGTH);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS feeds_given INTEGER NOT NULL DEFAULT 0", HUGS_DB_TABLE);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS feeds_received INTEGER NOT NULL DEFAULT 0", HUGS_DB_TABLE);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS last_rapists VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, HISTORY_STRING_LEN);
		g_iSchemaOpsPending++;
		SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS %s (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, winner_steamid64 VARCHAR(32) NOT NULL, winner_name VARCHAR(%d) NOT NULL DEFAULT '', loser_steamid64 VARCHAR(32) NOT NULL, loser_name VARCHAR(%d) NOT NULL DEFAULT '', winner_score INT NOT NULL DEFAULT 0, loser_score INT NOT NULL DEFAULT 0, result_type VARCHAR(32) NOT NULL DEFAULT '', finished_at INT NOT NULL, PRIMARY KEY (id), KEY idx_hugs_duel_finished (finished_at), KEY idx_hugs_duel_winner (winner_steamid64)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
			HUGS_DUEL_HISTORY_TABLE,
			MAX_NAME_LENGTH,
			MAX_NAME_LENGTH);
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

		static const char g_LastFeederColumns[MAX_HISTORY_ENTRIES][16] =
		{
			"last_feeder1",
			"last_feeder2",
			"last_feeder3",
			"last_feeder4",
			"last_feeder5"
		};

		for (int i = 0; i < MAX_HISTORY_ENTRIES; i++)
		{
			Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, g_LastHuggerColumns[i], MAX_NAME_LENGTH);
			g_iSchemaOpsPending++;
			SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);

			Format(query, sizeof(query), "ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s VARCHAR(%d) NOT NULL DEFAULT ''", HUGS_DB_TABLE, g_LastFeederColumns[i], MAX_NAME_LENGTH);
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

	public void SQL_OnSchemaOpComplete(Database db, DBResultSet results, const char[] error, any data)
	{
		if (error[0])
		{
			LogError("[Hugs] SQL error: %s", error);
			if (Db_IsTransientError(error))
			{
				ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
			}
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
