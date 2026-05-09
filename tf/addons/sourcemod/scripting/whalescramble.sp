// Whale scramble vote helper (NativeVotes)
#include <sourcemod>
#include <morecolors>
#include <nativevotes>
#include <dhooks>
#include <tf2_stocks>
#include <clans_api>
#include <whaletracker_api>
#include "include/dgm_api.inc"

#pragma semicolon 1
#pragma newdecls required

native int FilterAlerts_SuppressTeamAlertWindow(float seconds);
native bool Filters_GetChatName(int client, char[] buffer, int maxlen);

static const char SCRAMBLE_COMMANDS[][] =
{
    "sm_scramble",
    "sm_scwamble",
    "sm_sc",
    "sm_scram",
    "sm_shitteam"
};

static const char SCRAMBLE_KEYWORDS[][] =
{
    "scramble",
    "scwamble",
    "sc",
    "scram",
    "shitteam"
};

static const char SURRENDER_KEYWORDS[][] =
{
    "surrender",
    "itsover"
};

enum WhaleVoteKind
{
    WhaleVote_None = 0,
    WhaleVote_Scramble,
    WhaleVote_Surrender
};

bool g_bPlayerRequestedScramble[MAXPLAYERS + 1];
bool g_bPlayerRequestedSurrender[MAXPLAYERS + 1];
int g_iPlayerSurrenderVoteTeam[MAXPLAYERS + 1];
int g_iScrambleVoteRequests = 0;
bool g_bVoteRunning = false;
bool g_bNativeVotes = false;
bool g_bVoteAllowLowPop = false;
WhaleVoteKind g_eActiveVoteKind = WhaleVote_None;
int g_iActiveSurrenderTeam = 0;
bool scrambleCooldown = false;
NativeVote g_hVote = null;
Handle g_hScrambleCooldownTimer = null;
Handle g_hAutoScrambleTimer = null;
ConVar g_hLogEnabled = null;
ConVar g_hAutoRounds = null;
ConVar g_hVoteTime = null;
ConVar g_hCountBots = null;
ConVar g_hTopSwap = null;
ConVar g_hRandom = null;
ConVar g_hEngineHook = null;
int g_iRoundsSinceAuto = 0;
char g_sLogPath[PLATFORM_MAX_PATH];
StringMap g_hScrambleImmunity = null;
DynamicHook g_hHandleScrambleTeams = null;
int g_iHandleScrambleHookId = INVALID_HOOK_ID;
bool g_bAllowNextEngineScramble = false;
float g_flAllowEngineScrambleUntil = 0.0;

#define TEAM_RED  2
#define TEAM_BLU  3
#define MAX_TOP_SWAP  4
#define MAX_RANDOM_SWAP  5
#define MAX_SWAP_BUFFER  MAX_RANDOM_SWAP
#define AUTO_SCRAMBLE_DELAY 3.0

public Plugin myinfo =
{
    name = "whalescramble",
    author = "Hombre",
    description = "Player-triggered whale scramble vote helper",
    version = "1.1.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("FilterAlerts_SuppressTeamAlertWindow");
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("Clans_GetSameTeamClanMemberCount");
    MarkNativeAsOptional("WhaleTracker_IsCurrentRoundMvp");
    MarkNativeAsOptional("DGM_IsSmallFormatGamemode");
    return APLRes_Success;
}

public void OnPluginStart()
{
    UpdateNativeVotes();
    g_hLogEnabled = CreateConVar("sm_whalescramble_log", "1", "Enable whalescramble debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/whalescramble.log");
    LogWhale("Plugin started.");
    g_hAutoRounds = CreateConVar("votescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("votescramble_votetime", "4", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hCountBots = CreateConVar("whalescramble_count_bots", "0", "Include bots when selecting whale scramble targets.", _, true, 0.0, true, 1.0);
    g_hTopSwap = CreateConVar("sm_ws_topswap", "0", "Enable topswap scramble mode.", _, true, 0.0, true, 1.0);
    g_hRandom = CreateConVar("sm_ws_random", "1", "Enable random scramble mode.", _, true, 0.0, true, 1.0);
    g_hEngineHook = CreateConVar("sm_whalescramble_engine_hook", "1", "Replace TF2 engine/auto scrambles with Whalescramble when possible.", _, true, 0.0, true, 1.0);
    g_hScrambleImmunity = new StringMap();
    InitEngineScrambleHook();
    HookEngineScrambleHandler();

    for (int i = 0; i < sizeof(SCRAMBLE_COMMANDS); i++)
    {
        RegConsoleCmd(SCRAMBLE_COMMANDS[i], Command_Scramble);
    }
    RegConsoleCmd("sm_votescramble", Command_Scramble);
    RegConsoleCmd("sm_whalescramble", Command_Scramble);
    RegConsoleCmd("sm_surrender", Command_SurrenderRound);
    RegConsoleCmd("sm_itsover", Command_SurrenderRound);
    RegAdminCmd("sm_forcescramble", Command_WhaleScramble, ADMFLAG_GENERIC, "Immediately perform a whale scramble.");
    RegAdminCmd("sm_forcewhalescramble", Command_WhaleScramble, ADMFLAG_GENERIC, "Immediately perform a whale scramble.");
    RegAdminCmd("sm_whalescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");
    RegAdminCmd("sm_forcescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_PostNoCopy);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
}

public void OnAllPluginsLoaded()
{
    UpdateNativeVotes();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        UpdateNativeVotes();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        g_bNativeVotes = false;
    }
}

public void OnMapStart()
{
    ResetVotes();
    ClearScrambleCooldown();
    ClearAutoScrambleTimer();
    g_iRoundsSinceAuto = 0;
    if (g_hScrambleImmunity != null)
    {
        g_hScrambleImmunity.Clear();
    }
    HookEngineScrambleHandler();
    LogWhale("Map start: immunity cleared, votes reset.");
}

public void OnMapEnd()
{
    ResetVotes();
    ClearScrambleCooldown();
    ClearAutoScrambleTimer();
    UnhookEngineScrambleHandler();
    g_iRoundsSinceAuto = 0;
    LogWhale("Map end: votes reset.");
}

public void OnPluginEnd()
{
    ResetVotes();
    ClearScrambleCooldown();
    ClearAutoScrambleTimer();
    UnhookEngineScrambleHandler();
    LogWhale("Plugin ended.");
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (g_bPlayerRequestedScramble[client])
    {
        g_bPlayerRequestedScramble[client] = false;
        if (g_iScrambleVoteRequests > 0)
        {
            g_iScrambleVoteRequests--;
        }
    }
    if (g_bPlayerRequestedSurrender[client])
    {
        LogWhale("Cleared surrender vote on disconnect: %N team=%d.", client, GetClientTeam(client));
        ClearClientSurrenderVote(client);
        LogSurrenderState("disconnect_clear");
    }
}

public void OnClientPutInServer(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
}

public Action Command_Scramble(int client, int args)
{
    LogWhale("Scramble request via command from %N (%d).", client, GetClientUserId(client));
    HandleVoteRequest(client, WhaleVote_Scramble);
    return Plugin_Handled;
}

public Action Command_SurrenderRound(int client, int args)
{
    LogWhale("Surrender request via command from %N (%d).", client, GetClientUserId(client));
    HandleVoteRequest(client, WhaleVote_Surrender);
    return Plugin_Handled;
}

public Action Command_WhaleScramble(int client, int args)
{
    LogWhale("Admin whale scramble requested by %N (%d).", client, GetClientUserId(client));
    StartConfiguredWhaleScramble(client, true, true, true);
    return Plugin_Handled;
}

public Action Command_ForceScrambleVote(int client, int args)
{
    LogWhale("Admin force vote requested by %N (%d).", client, GetClientUserId(client));
    StartVote(client, false, true, WhaleVote_Scramble);
    return Plugin_Handled;
}

public Action SayListener(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    TrimString(text);
    StripQuotes(text);
    TrimString(text);

    if (!text[0])
    {
        return Plugin_Continue;
    }

    for (int i = 0; i < sizeof(SCRAMBLE_KEYWORDS); i++)
    {
        if (StrEqual(text, SCRAMBLE_KEYWORDS[i], false))
        {
            LogWhale("Scramble request via chat from %N (%d): %s", client, GetClientUserId(client), text);
            HandleVoteRequest(client, WhaleVote_Scramble);
            return Plugin_Handled;
        }
    }

    for (int i = 0; i < sizeof(SURRENDER_KEYWORDS); i++)
    {
        if (StrEqual(text, SURRENDER_KEYWORDS[i], false))
        {
            LogWhale("Surrender request via chat from %N (%d): %s", client, GetClientUserId(client), text);
            HandleVoteRequest(client, WhaleVote_Surrender);
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    ClearScrambleCooldown();
    LogWhale("Round win: full_round=%d voteRunning=%d activeKind=%d activeTeam=%d.",
        event.GetBool("full_round") ? 1 : 0,
        g_bVoteRunning ? 1 : 0,
        g_eActiveVoteKind,
        g_iActiveSurrenderTeam);
    ResetSurrenderVotes("round_win");

    if (g_hAutoRounds == null)
    {
        return;
    }

    // full_round is 1 if the entire map/round is over (Red lost or Blue finished final stage)
    // full_round is 0 if it was just a stage completion (e.g., Goldrush Stage 1)
    if (!(event.GetBool("full_round")))
        return;

    int roundsRequired = g_hAutoRounds.IntValue;
    if (roundsRequired <= 1)
    {
        return;
    }

    g_iRoundsSinceAuto++;
    if (g_iRoundsSinceAuto < roundsRequired)
    {
        return;
    }

    if (g_hAutoScrambleTimer != null)
    {
        LogWhale("Auto scramble already pending.");
        return;
    }

    g_hAutoScrambleTimer = CreateTimer(AUTO_SCRAMBLE_DELAY, Timer_StartAutoScramble, _, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Auto scramble scheduled in %.1f seconds.", AUTO_SCRAMBLE_DELAY);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (!g_bPlayerRequestedSurrender[client])
    {
        return;
    }

    int oldTeam = event.GetInt("oldteam");
    int newTeam = event.GetInt("team");
    if (event.GetBool("disconnect") || oldTeam != newTeam)
    {
        LogWhale("Cleared surrender vote on team change: %N old=%d new=%d disconnect=%d.", client, oldTeam, newTeam, event.GetBool("disconnect") ? 1 : 0);
        ClearClientSurrenderVote(client);
        LogSurrenderState("team_change_clear");
    }
}

static void UpdateNativeVotes()
{
    g_bNativeVotes = LibraryExists("nativevotes") && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_YesNo);
}

static void GetVoteActionName(WhaleVoteKind kind, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    switch (kind)
    {
        case WhaleVote_Surrender:
        {
            strcopy(buffer, maxlen, "surrender");
            return;
        }
    }

    strcopy(buffer, maxlen, "scramble");
}

static bool IsPlayerOnPlayableTeam(int client)
{
    int team = GetClientTeam(client);
    return team == TEAM_RED || team == TEAM_BLU;
}

static int GetOpposingTeam(int team)
{
    if (team == TEAM_RED)
    {
        return TEAM_BLU;
    }
    if (team == TEAM_BLU)
    {
        return TEAM_RED;
    }
    return 0;
}

static void GetColoredTeamName(int team, char[] buffer, int maxlen)
{
    if (team == TEAM_RED)
    {
        strcopy(buffer, maxlen, "{red}RED{default}");
        return;
    }
    if (team == TEAM_BLU)
    {
        strcopy(buffer, maxlen, "{blue}BLU{default}");
        return;
    }

    strcopy(buffer, maxlen, "{default}UNKNOWN{default}");
}

static void GetVoteKindName(WhaleVoteKind kind, char[] buffer, int maxlen)
{
    switch (kind)
    {
        case WhaleVote_Scramble:
        {
            strcopy(buffer, maxlen, "scramble");
            return;
        }
        case WhaleVote_Surrender:
        {
            strcopy(buffer, maxlen, "surrender");
            return;
        }
    }

    strcopy(buffer, maxlen, "none");
}

static int GetPlayableTeamClientCount(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        if (GetClientTeam(i) == team)
        {
            count++;
        }
    }
    return count;
}

static bool ShouldIgnoreScrambleImmunity(int totalPlayers, bool randomMode)
{
    if (randomMode)
    {
        return totalPlayers <= (MAX_RANDOM_SWAP * 2);
    }

    return totalPlayers <= (MAX_TOP_SWAP * 2);
}

static void InitEngineScrambleHook()
{
    if (g_hHandleScrambleTeams != null)
    {
        return;
    }

    GameData gameData = new GameData("whalescramble");
    if (gameData == null)
    {
        LogError("[WhaleScramble] Failed to load gamedata: whalescramble");
        return;
    }

    int offset = gameData.GetOffset("CTeamplayRules::HandleScrambleTeams");
    delete gameData;

    if (offset == -1)
    {
        LogError("[WhaleScramble] Missing CTeamplayRules::HandleScrambleTeams offset in gamedata");
        return;
    }

    g_hHandleScrambleTeams = DHookCreate(offset, HookType_GameRules, ReturnType_Void, ThisPointer_Ignore);
    if (g_hHandleScrambleTeams == null)
    {
        LogError("[WhaleScramble] Failed to create CTeamplayRules::HandleScrambleTeams hook");
        return;
    }

    LogWhale("Engine scramble hook prepared.");
}

static void HookEngineScrambleHandler()
{
    if (g_iHandleScrambleHookId != INVALID_HOOK_ID || g_hHandleScrambleTeams == null)
    {
        return;
    }

    if (g_hEngineHook != null && !g_hEngineHook.BoolValue)
    {
        LogWhale("Engine scramble hook disabled by sm_whalescramble_engine_hook.");
        return;
    }

    g_iHandleScrambleHookId = g_hHandleScrambleTeams.HookGamerules(Hook_Pre, DHook_HandleScrambleTeams);
    if (g_iHandleScrambleHookId == INVALID_HOOK_ID)
    {
        LogError("[WhaleScramble] Failed to hook CTeamplayRules::HandleScrambleTeams");
        return;
    }

    LogWhale("Engine scramble hook installed id=%d.", g_iHandleScrambleHookId);
}

static void UnhookEngineScrambleHandler()
{
    if (g_iHandleScrambleHookId == INVALID_HOOK_ID)
    {
        return;
    }

    DHookRemoveHookID(g_iHandleScrambleHookId);
    LogWhale("Engine scramble hook removed id=%d.", g_iHandleScrambleHookId);
    g_iHandleScrambleHookId = INVALID_HOOK_ID;
}

static void AllowNextEngineScramble(float seconds)
{
    g_bAllowNextEngineScramble = true;
    g_flAllowEngineScrambleUntil = GetEngineTime() + seconds;
}

static bool ShouldAllowEngineScrambleThrough()
{
    if (!g_bAllowNextEngineScramble)
    {
        return false;
    }

    if (GetEngineTime() > g_flAllowEngineScrambleUntil)
    {
        g_bAllowNextEngineScramble = false;
        g_flAllowEngineScrambleUntil = 0.0;
        return false;
    }

    g_bAllowNextEngineScramble = false;
    g_flAllowEngineScrambleUntil = 0.0;
    return true;
}

public MRESReturn DHook_HandleScrambleTeams()
{
    if (g_hEngineHook != null && !g_hEngineHook.BoolValue)
    {
        return MRES_Ignored;
    }

    if (ShouldAllowEngineScrambleThrough())
    {
        LogWhale("Engine scramble allowed through for explicit mp_scrambleteams path.");
        return MRES_Ignored;
    }

    bool started = StartAutoScramble(true);
    if (!started)
    {
        LogWhale("Engine scramble hook could not start Whalescramble; allowing TF2 handler.");
        return MRES_Ignored;
    }

    LogWhale("Engine scramble replaced with Whalescramble.");
    return MRES_Supercede;
}

static bool IsSmallFormatGamemode()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_IsSmallFormatGamemode") != FeatureStatus_Available)
    {
        return false;
    }

    return DGM_IsSmallFormatGamemode();
}

static int GetScrambleVoteRequestCount()
{
    return g_iScrambleVoteRequests;
}

static int GetSurrenderVoteCountForTeam(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bPlayerRequestedSurrender[i] && g_iPlayerSurrenderVoteTeam[i] == team)
        {
            count++;
        }
    }
    return count;
}

static void LogSurrenderState(const char[] reason)
{
    char voteKind[16];
    GetVoteKindName(g_eActiveVoteKind, voteKind, sizeof(voteKind));

    LogWhale("Surrender state [%s]: reqRed=%d reqBlu=%d playersRed=%d playersBlu=%d voteRunning=%d voteKind=%s activeTeam=%d cooldown=%d.",
        reason,
        GetSurrenderVoteCountForTeam(TEAM_RED),
        GetSurrenderVoteCountForTeam(TEAM_BLU),
        GetPlayableTeamClientCount(TEAM_RED),
        GetPlayableTeamClientCount(TEAM_BLU),
        g_bVoteRunning ? 1 : 0,
        voteKind,
        g_iActiveSurrenderTeam,
        scrambleCooldown ? 1 : 0);
}

static void SetPlayerVoteRequested(int client, WhaleVoteKind kind, bool value)
{
    if (kind == WhaleVote_Surrender)
    {
        g_bPlayerRequestedSurrender[client] = value;
        return;
    }

    g_bPlayerRequestedScramble[client] = value;
}

static void ClearClientSurrenderVote(int client)
{
    g_bPlayerRequestedSurrender[client] = false;
    g_iPlayerSurrenderVoteTeam[client] = 0;
}

static bool HasPlayerRequestedVote(int client, WhaleVoteKind kind)
{
    if (kind == WhaleVote_Surrender)
    {
        return g_bPlayerRequestedSurrender[client];
    }

    return g_bPlayerRequestedScramble[client];
}

static void IncrementScrambleVoteRequestCount()
{
    g_iScrambleVoteRequests++;
}

static void HandleVoteRequest(int client, WhaleVoteKind kind)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (kind == WhaleVote_Surrender && !IsPlayerOnPlayableTeam(client))
    {
        CPrintToChat(client, "{gold}[WhaleScramble] {default}Only teams {red}RED {default}and {blue}BLU{default} can surrender!");
        LogWhale("Surrender request rejected: invalid team (client %N team=%d).", client, GetClientTeam(client));
        return;
    }

    char actionName[16];
    GetVoteActionName(kind, actionName, sizeof(actionName));

    if (scrambleCooldown)
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} %s is on cooldown.", actionName);
        LogWhale("Vote request rejected: %s cooldown active (client %N).", actionName, client);
        return;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        LogWhale("Vote request rejected: vote already running (client %N kind=%s).", client, actionName);
        return;
    }

    if (HasPlayerRequestedVote(client, kind))
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} You already requested a %s vote.", actionName);
        LogWhale("Vote request rejected: already requested (client %N kind=%s).", client, actionName);
        return;
    }

    SetPlayerVoteRequested(client, kind, true);
    if (kind == WhaleVote_Surrender)
    {
        g_iPlayerSurrenderVoteTeam[client] = GetClientTeam(client);
    }
    else
    {
        IncrementScrambleVoteRequestCount();
    }

    int requestCount = GetScrambleVoteRequestCount();
    if (kind == WhaleVote_Surrender)
    {
        requestCount = GetSurrenderVoteCountForTeam(g_iPlayerSurrenderVoteTeam[client]);
        LogWhale("Surrender request counted: %N team=%d teamCount=%d redRequests=%d bluRequests=%d.",
            client,
            g_iPlayerSurrenderVoteTeam[client],
            requestCount,
            GetSurrenderVoteCountForTeam(TEAM_RED),
            GetSurrenderVoteCountForTeam(TEAM_BLU));
        LogSurrenderState("request_counted");
    }
    CPrintToChatAll("{blue}[WhaleScramble]{default} %N requested a %s vote (%d/4).", client, actionName, requestCount);
    LogWhale("Vote request counted: %N kind=%s (%d/%d).", client, actionName, requestCount, 4);

    if (requestCount >= 4)
    {
        if (kind == WhaleVote_Surrender)
        {
            LogWhale("Surrender threshold reached: team=%d trigger=%N.", g_iPlayerSurrenderVoteTeam[client], client);
        }
        StartVote(client, false, false, kind);
    }
}

static bool StartVote(int client, bool suppressFeedback, bool allowLowPop, WhaleVoteKind kind)
{
    char actionName[16];
    GetVoteActionName(kind, actionName, sizeof(actionName));
    LogWhale("Starting %s vote: caller=%d allowLowPop=%d suppressFeedback=%d.", actionName, client, allowLowPop ? 1 : 0, suppressFeedback ? 1 : 0);

    if (kind == WhaleVote_Surrender)
    {
        if (client <= 0 || !IsClientInGame(client) || !IsPlayerOnPlayableTeam(client))
        {
            if (!suppressFeedback && client > 0 && IsClientInGame(client))
            {
                CPrintToChat(client, "{gold}[WhaleScramble] {default}Only teams {red}RED {default}and {blue}BLU{default} can surrender!");
            }
            LogWhale("Vote start failed: surrender caller invalid team (client=%d team=%d).", client, (client > 0 && IsClientInGame(client)) ? GetClientTeam(client) : 0);
            return false;
        }

        LogWhale("Starting surrender vote: caller=%N callerTeam=%d redRequests=%d bluRequests=%d allowLowPop=%d suppressFeedback=%d.",
            client,
            GetClientTeam(client),
            GetSurrenderVoteCountForTeam(TEAM_RED),
            GetSurrenderVoteCountForTeam(TEAM_BLU),
            allowLowPop ? 1 : 0,
            suppressFeedback ? 1 : 0);
    }

    if (scrambleCooldown)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} %s is on cooldown.", actionName);
        }
        LogWhale("Vote start failed: %s cooldown active.", actionName);
        return false;
    }

    if (!g_bNativeVotes)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} NativeVotes is unavailable.");
        }
        LogWhale("Vote start failed: NativeVotes unavailable.");
        return false;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        }
        LogWhale("Vote start failed: vote already running.");
        return false;
    }

    int delay = NativeVotes_CheckVoteDelay();
    if (delay > 0)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            NativeVotes_DisplayCallVoteFail(client, NativeVotesCallFail_Recent, delay);
        }
        LogWhale("Vote start failed: vote delay %d.", delay);
        return false;
    }

    if (!NativeVotes_IsNewVoteAllowed())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is not allowed right now.");
        }
        LogWhale("Vote start failed: new vote not allowed.");
        return false;
    }

    if (g_hVote != null)
    {
        g_hVote.Close();
        g_hVote = null;
    }

    g_hVote = new NativeVote(ScrambleVoteHandler, NativeVotesType_Custom_YesNo, MENU_ACTIONS_ALL);
    if (kind == WhaleVote_Surrender)
    {
        NativeVotes_SetTitle(g_hVote, "Surrender round?");
    }
    else
    {
        NativeVotes_SetTitle(g_hVote, "Whale scramble teams?");
    }

    int voteTime = 4;
    if (g_hVoteTime != null)
    {
        voteTime = g_hVoteTime.IntValue;
    }
    if (voteTime < 1)
    {
        voteTime = 1;
    }

    g_bVoteRunning = NativeVotes_DisplayToAll(g_hVote, voteTime);
    if (!g_bVoteRunning)
    {
        g_hVote.Close();
        g_hVote = null;
        g_bVoteAllowLowPop = false;
        g_eActiveVoteKind = WhaleVote_None;
        LogWhale("Vote start failed: display to all returned false.");
        return false;
    }

    g_bVoteAllowLowPop = allowLowPop;
    g_eActiveVoteKind = kind;
    if (kind == WhaleVote_Surrender && client > 0 && IsClientInGame(client))
    {
        g_iActiveSurrenderTeam = GetClientTeam(client);
    }
    else
    {
        g_iActiveSurrenderTeam = 0;
    }
    LogWhale("%s vote started: duration=%d allowLowPop=%d activeSurrenderTeam=%d.", actionName, voteTime, allowLowPop ? 1 : 0, g_iActiveSurrenderTeam);
    if (kind == WhaleVote_Surrender)
    {
        LogSurrenderState("vote_started");
    }
    return true;
}

static bool StartAutoScramble(bool suppressFeedback)
{
    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        return false;
    }

    if (!suppressFeedback)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Auto scramble triggered.");
    }

    LogWhale("Auto scramble triggered.");
    return StartConfiguredWhaleScramble(0, !suppressFeedback, false, false);
}

public Action Timer_StartAutoScramble(Handle timer)
{
    if (timer == g_hAutoScrambleTimer)
    {
        g_hAutoScrambleTimer = null;
    }

    StartAutoScramble(true);
    return Plugin_Stop;
}

static bool StartConfiguredWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    if (g_hTopSwap != null && g_hTopSwap.BoolValue)
    {
        LogWhale("Configured scramble mode: topswap forced=%d.", forced ? 1 : 0);
        return StartWhaleScramble(issuer, broadcastFailures, allowLowPop, forced);
    }
    else if (g_hRandom != null && g_hRandom.BoolValue)
    {
        LogWhale("Configured scramble mode: random forced=%d.", forced ? 1 : 0);
        return StartRandomWhaleScramble(issuer, broadcastFailures, allowLowPop, forced);
    }

    NotifyFailure(issuer, broadcastFailures, "No scramble mode is enabled. Set sm_ws_topswap or sm_ws_random to 1.");
    LogWhale("Configured scramble aborted: no enabled modes.");
    return false;
}

public int ScrambleVoteHandler(NativeVote vote, MenuAction action, int param1, int param2)
{
    WhaleVoteKind voteKind = g_eActiveVoteKind;
    if (voteKind == WhaleVote_Surrender)
    {
        LogWhale("Surrender vote action: action=%d param1=%d param2=%d activeTeam=%d voteRunning=%d.", action, param1, param2, g_iActiveSurrenderTeam, g_bVoteRunning ? 1 : 0);
    }

    switch (action)
    {
        case MenuAction_End:
        {
            vote.Close();
            g_hVote = null;
            g_bVoteRunning = false;
            g_bVoteAllowLowPop = false;
            g_eActiveVoteKind = WhaleVote_None;
            g_iActiveSurrenderTeam = 0;
            if (voteKind == WhaleVote_Scramble)
            {
                ResetScrambleVotes();
            }
            LogWhale("Vote ended.");
            if (voteKind == WhaleVote_Surrender)
            {
                LogSurrenderState("vote_end");
            }
            return 0;
        }
        case MenuAction_VoteCancel:
        {
            if (param1 == VoteCancel_NoVotes)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
            }
            else
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
            }
            g_bVoteAllowLowPop = false;
            g_eActiveVoteKind = WhaleVote_None;
            g_iActiveSurrenderTeam = 0;
            if (voteKind == WhaleVote_Scramble)
            {
                ResetScrambleVotes();
            }
            LogWhale("Vote cancelled: %d.", param1);
            if (voteKind == WhaleVote_Surrender)
            {
                LogSurrenderState("vote_cancel");
            }
            return 0;
        }
        case MenuAction_VoteEnd:
        {
            if (voteKind == WhaleVote_None)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
                g_bVoteAllowLowPop = false;
                LogWhale("Vote end failed closed: active vote kind missing.");
                return 0;
            }

            int votes = 0;
            int totalVotes = 0;
            NativeVotes_GetInfo(param2, votes, totalVotes);

            if (totalVotes <= 0)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
                LogWhale("Vote failed: no votes.");
                return 0;
            }

            int yesVotes = (param1 == NATIVEVOTES_VOTE_YES) ? votes : (totalVotes - votes);
            float yesPercent = float(yesVotes) / float(totalVotes);

            if (yesPercent < 0.50)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Loses);
                CPrintToChatAll("Vote failed (Yes %.0f%%).", yesPercent * 100.0);
                g_bVoteAllowLowPop = false;
                LogWhale("Vote failed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
                if (voteKind == WhaleVote_Surrender)
                {
                    LogSurrenderState("vote_fail");
                }
            }
            else
            {
                bool success = false;
                if (voteKind == WhaleVote_Surrender)
                {
                    int winningTeamNum = GetOpposingTeam(g_iActiveSurrenderTeam);
                    if (g_iActiveSurrenderTeam != TEAM_RED && g_iActiveSurrenderTeam != TEAM_BLU || winningTeamNum == 0)
                    {
                        NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
                        g_bVoteAllowLowPop = false;
                        LogWhale("Surrender vote failed closed: invalid active surrender team=%d.", g_iActiveSurrenderTeam);
                        return 0;
                    }
                    LogWhale("Surrender vote passed: issuing mp_scrambleteams surrenderTeam=%d winningTeam=%d yes=%d total=%d.",
                        g_iActiveSurrenderTeam,
                        winningTeamNum,
                        yesVotes,
                        totalVotes);
                    StartScrambleCooldown();
                    AllowNextEngineScramble(5.0);
                    ServerCommand("mp_scrambleteams");
                    success = true;
                }
                else
                {
                    success = StartConfiguredWhaleScramble(0, true, g_bVoteAllowLowPop, false);
                }

                if (success)
                {
                    if (voteKind == WhaleVote_Surrender)
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Surrendering round...");
                        char surrenderTeam[32];
                        char winningTeam[32];
                        GetColoredTeamName(g_iActiveSurrenderTeam, surrenderTeam, sizeof(surrenderTeam));
                        GetColoredTeamName(GetOpposingTeam(g_iActiveSurrenderTeam), winningTeam, sizeof(winningTeam));
                        CPrintToChatAll("Team %s surrendered to %s!", surrenderTeam, winningTeam);
                        LogWhale("Surrender vote passed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
                        LogSurrenderState("vote_pass");
                    }
                    else
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Whale scrambling teams...");
                        LogWhale("Vote passed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
                    }
                }
                else
                {
                    if (voteKind == WhaleVote_Surrender)
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Unable to surrender right now.");
                        LogWhale("Surrender vote passed but command could not be issued.");
                    }
                    else
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Scramble conditions not met.");
                        LogWhale("Vote passed but scramble conditions not met.");
                    }
                }
                g_bVoteAllowLowPop = false;
                g_eActiveVoteKind = WhaleVote_None;
                g_iActiveSurrenderTeam = 0;
            }
            return 0;
        }
    }
    return 0;
}

static void ResetScrambleVotes()
{
    g_iScrambleVoteRequests = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bPlayerRequestedScramble[i] = false;
    }
}

static void ResetVotes()
{
    ResetScrambleVotes();
    ResetSurrenderVotes("full_reset");
    g_bVoteRunning = false;
    g_eActiveVoteKind = WhaleVote_None;
    g_iActiveSurrenderTeam = 0;
}

static void ResetSurrenderVotes(const char[] reason)
{
    bool preserveActiveSurrenderVote = g_bVoteRunning && g_eActiveVoteKind == WhaleVote_Surrender;
    LogWhale("Reset surrender votes: reason=%s preserveActive=%d.", reason, preserveActiveSurrenderVote ? 1 : 0);

    if (!preserveActiveSurrenderVote && g_eActiveVoteKind == WhaleVote_Surrender)
    {
        g_eActiveVoteKind = WhaleVote_None;
    }
    if (!preserveActiveSurrenderVote)
    {
        g_iActiveSurrenderTeam = 0;
    }
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bPlayerRequestedSurrender[i] = false;
        g_iPlayerSurrenderVoteTeam[i] = 0;
    }
    LogSurrenderState(reason);
}

static void StartScrambleCooldown()
{
    scrambleCooldown = true;
    if (g_hScrambleCooldownTimer != null)
    {
        delete g_hScrambleCooldownTimer;
        g_hScrambleCooldownTimer = null;
    }

    g_hScrambleCooldownTimer = CreateTimer(120.0, Timer_ResetScrambleCooldown, _, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Scramble cooldown started.");
}

static void ClearScrambleCooldown()
{
    scrambleCooldown = false;
    if (g_hScrambleCooldownTimer != null)
    {
        delete g_hScrambleCooldownTimer;
        g_hScrambleCooldownTimer = null;
    }
}

static void ClearAutoScrambleTimer()
{
    if (g_hAutoScrambleTimer != null)
    {
        delete g_hAutoScrambleTimer;
        g_hAutoScrambleTimer = null;
    }
}

static bool StartWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    LogWhale("StartWhaleScramble: issuer=%d allowLowPop=%d forced=%d.", issuer, allowLowPop ? 1 : 0, forced ? 1 : 0);
    g_iRoundsSinceAuto = 0;
    int totalPlayers = 0;
    int redCount = 0;
    int bluCount = 0;
    int redEligible = 0;
    int bluEligible = 0;

    int topRed[MAX_SWAP_BUFFER];
    int topBlu[MAX_SWAP_BUFFER];
    int topRedScore[MAX_SWAP_BUFFER];
    int topBluScore[MAX_SWAP_BUFFER];

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        topRed[i] = 0;
        topBlu[i] = 0;
        topRedScore[i] = -999999;
        topBluScore[i] = -999999;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        totalPlayers++;
        if (team == TEAM_RED) redCount++;
        else bluCount++;
    }

    bool smallFormatGamemode = IsSmallFormatGamemode();
    bool effectiveAllowLowPop = allowLowPop || smallFormatGamemode;
    bool ignoreImmunity = smallFormatGamemode || ShouldIgnoreScrambleImmunity(totalPlayers, false);
    if (ignoreImmunity)
    {
        LogWhale(
            "Topswap scramble: ignoring immunity due to %s total=%d threshold=%d.",
            smallFormatGamemode ? "small-format gamemode" : "low player count",
            totalPlayers,
            MAX_TOP_SWAP * 2);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        if (!ignoreImmunity && IsScrambleImmune(i)) continue;

        if (team == TEAM_RED) redEligible++;
        else bluEligible++;

        int score = GetScrambleScore(i, false, forced);
        if (team == TEAM_RED)
        {
            InsertTopN(i, score, topRed, topRedScore, MAX_TOP_SWAP);
        }
        else
        {
            InsertTopN(i, score, topBlu, topBluScore, MAX_TOP_SWAP);
        }
    }

    LogWhale("Counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible);
    int swapCount = 0;
    bool lowPop = smallFormatGamemode || (totalPlayers < 12);

    if (!lowPop)
    {
        if (totalPlayers >= 20)
        {
            swapCount = MAX_TOP_SWAP;
        }
        else
        {
            swapCount = 3;
        }
    }
    else if (effectiveAllowLowPop)
    {
        swapCount = redEligible < bluEligible ? redEligible : bluEligible;
        if (swapCount > 2)
        {
            swapCount = 2;
        }
    }

    bool needsFallback = (redEligible < swapCount || bluEligible < swapCount);
    if (effectiveAllowLowPop && lowPop && swapCount == 0)
    {
        needsFallback = true;
    }
    if (needsFallback)
    {
        LogWhale("Eligibility low; recalculating without class filters.");
        redEligible = 0;
        bluEligible = 0;
        for (int i = 0; i < MAX_SWAP_BUFFER; i++)
        {
            topRed[i] = 0;
            topBlu[i] = 0;
            topRedScore[i] = -999999;
            topBluScore[i] = -999999;
        }

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

            int team = GetClientTeam(i);
            if (team != TEAM_RED && team != TEAM_BLU) continue;
            if (!ignoreImmunity && IsScrambleImmune(i)) continue;

            if (team == TEAM_RED) redEligible++;
            else bluEligible++;

            int score = GetScrambleScore(i, true, forced);
            if (team == TEAM_RED)
            {
                InsertTopN(i, score, topRed, topRedScore, MAX_TOP_SWAP);
            }
            else
            {
                InsertTopN(i, score, topBlu, topBluScore, MAX_TOP_SWAP);
            }
        }
        if (effectiveAllowLowPop && lowPop)
        {
            swapCount = redEligible < bluEligible ? redEligible : bluEligible;
            if (swapCount > 2)
            {
                swapCount = 2;
            }
        }
    }

    if (swapCount == 0)
    {
        if (effectiveAllowLowPop && lowPop)
        {
            NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
            LogWhale("Scramble aborted: not enough eligible players (red=%d blu=%d).", redEligible, bluEligible);
        }
        else
        {
            NotifyFailure(issuer, broadcastFailures, "Need at least 12 players (current: %d).", totalPlayers);
            LogWhale("Scramble aborted: not enough players (total=%d).", totalPlayers);
        }
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        return false;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Scramble scheduled: swapCount=%d.", swapCount);
    return true;
}

static bool StartRandomWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    LogWhale("StartRandomWhaleScramble: issuer=%d allowLowPop=%d forced=%d.", issuer, allowLowPop ? 1 : 0, forced ? 1 : 0);
    g_iRoundsSinceAuto = 0;
    int totalPlayers = 0;
    int redCount = 0;
    int bluCount = 0;
    int redEligible = 0;
    int bluEligible = 0;
    int redCandidates[MAXPLAYERS + 1];
    int bluCandidates[MAXPLAYERS + 1];
    int redCandidateCount = 0;
    int bluCandidateCount = 0;
    int topRed[MAX_SWAP_BUFFER];
    int topBlu[MAX_SWAP_BUFFER];

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        topRed[i] = 0;
        topBlu[i] = 0;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        totalPlayers++;
        if (team == TEAM_RED) redCount++;
        else bluCount++;
    }

    bool smallFormatGamemode = IsSmallFormatGamemode();
    bool effectiveAllowLowPop = allowLowPop || smallFormatGamemode;
    bool ignoreImmunity = smallFormatGamemode || ShouldIgnoreScrambleImmunity(totalPlayers, true);
    if (ignoreImmunity)
    {
        LogWhale(
            "Random scramble: ignoring immunity due to %s total=%d threshold=%d.",
            smallFormatGamemode ? "small-format gamemode" : "low player count",
            totalPlayers,
            MAX_RANDOM_SWAP * 2);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU) continue;

        if (!ignoreImmunity && IsScrambleImmune(i)) continue;
        if (!IsSimpleScrambleEligibleClass(i, forced)) continue;

        if (team == TEAM_RED)
        {
            redEligible++;
            if (redCandidateCount < sizeof(redCandidates))
            {
                redCandidates[redCandidateCount++] = i;
            }
        }
        else
        {
            bluEligible++;
            if (bluCandidateCount < sizeof(bluCandidates))
            {
                bluCandidates[bluCandidateCount++] = i;
            }
        }
    }

    LogWhale("Random counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible);
    int swapCount = 0;
    bool lowPop = smallFormatGamemode || (totalPlayers < 12);

    if (!lowPop)
    {
        if (totalPlayers >= 20)
        {
            swapCount = MAX_RANDOM_SWAP;
        }
        else
        {
            swapCount = 4;
        }
    }
    else if (effectiveAllowLowPop)
    {
        swapCount = redEligible < bluEligible ? redEligible : bluEligible;
        if (swapCount > 2)
        {
            swapCount = 2;
        }
    }

    bool needsFallback = (redEligible < swapCount || bluEligible < swapCount);
    if (effectiveAllowLowPop && lowPop && swapCount == 0)
    {
        needsFallback = true;
    }
    if (needsFallback)
    {
        LogWhale("Random eligibility low; recalculating without class filters.");
        redEligible = 0;
        bluEligible = 0;
        redCandidateCount = 0;
        bluCandidateCount = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue)) continue;

            int team = GetClientTeam(i);
            if (team != TEAM_RED && team != TEAM_BLU) continue;
            if (!ignoreImmunity && IsScrambleImmune(i)) continue;

            if (team == TEAM_RED)
            {
                redEligible++;
                if (redCandidateCount < sizeof(redCandidates))
                {
                    redCandidates[redCandidateCount++] = i;
                }
            }
            else
            {
                bluEligible++;
                if (bluCandidateCount < sizeof(bluCandidates))
                {
                    bluCandidates[bluCandidateCount++] = i;
                }
            }
        }
        if (effectiveAllowLowPop && lowPop)
        {
            swapCount = redEligible < bluEligible ? redEligible : bluEligible;
            if (swapCount > 2)
            {
                swapCount = 2;
            }
        }
    }

    if (swapCount == 0)
    {
        if (effectiveAllowLowPop && lowPop)
        {
            NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
            LogWhale("Random scramble aborted: not enough eligible players (red=%d blu=%d).", redEligible, bluEligible);
        }
        else
        {
            NotifyFailure(issuer, broadcastFailures, "Need at least 12 players (current: %d).", totalPlayers);
            LogWhale("Random scramble aborted: not enough players (total=%d).", totalPlayers);
        }
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Random scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Random scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        return false;
    }

    if (!SelectRandomPlayers(redCandidates, redCandidateCount, topRed, swapCount)
        || !SelectRandomPlayers(bluCandidates, bluCandidateCount, topBlu, swapCount))
    {
        NotifyFailure(issuer, broadcastFailures, "Failed to select random swap targets.");
        LogWhale("Random scramble aborted: random selection failed (swap=%d redCandidates=%d bluCandidates=%d).", swapCount, redCandidateCount, bluCandidateCount);
        return false;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Random scramble scheduled: swapCount=%d.", swapCount);
    return true;
}

public Action Timer_DoSwap(Handle timer, DataPack pack)
{
    pack.Reset();
    int issuerUserId = pack.ReadCell();
    int swapCount = pack.ReadCell();

    int redIds[MAX_SWAP_BUFFER];
    int bluIds[MAX_SWAP_BUFFER];

    for (int i = 0; i < swapCount; i++)
    {
        redIds[i] = pack.ReadCell();
    }
    for (int i = 0; i < swapCount; i++)
    {
        bluIds[i] = pack.ReadCell();
    }

    delete pack;

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_SuppressTeamAlertWindow") == FeatureStatus_Available)
    {
        FilterAlerts_SuppressTeamAlertWindow(2.0);
    }

    int moved = 0;
    int pairR[MAX_SWAP_BUFFER];
    int pairB[MAX_SWAP_BUFFER];
    int pairCount = 0;
    for (int i = 0; i < swapCount; i++)
    {
        int r = GetClientOfUserId(redIds[i]);
        int b = GetClientOfUserId(bluIds[i]);

        if (r <= 0 || b <= 0) continue;
        if (!IsClientInGame(r) || !IsClientInGame(b)) continue;
        if (GetClientTeam(r) != TEAM_RED || GetClientTeam(b) != TEAM_BLU) continue;

        if (pairCount < MAX_SWAP_BUFFER)
        {
            pairR[pairCount] = r;
            pairB[pairCount] = b;
            pairCount++;
        }

        if (r > 0 && IsClientInGame(r) && GetClientTeam(r) == TEAM_RED)
        {
            ChangeClientTeam(r, TEAM_BLU);
            TF2_RespawnPlayer(r);
            MarkScrambleImmune(r);
        }
        if (b > 0 && IsClientInGame(b) && GetClientTeam(b) == TEAM_BLU)
        {
            ChangeClientTeam(b, TEAM_RED);
            TF2_RespawnPlayer(b);
            MarkScrambleImmune(b);
        }
    }

    moved = pairCount * 2;
    if (moved > 0)
    {
        ResetSurrenderVotes("whalescramble_execute");
        StartScrambleCooldown();
        CPrintToChatAll("{tomato}[{purple}Gap{tomato}]{default} {gold}Whalescrambling{default} %d players!", moved);
        LogWhale("Scramble executed: moved=%d pairs=%d.", moved, pairCount);
        for (int i = 0; i < pairCount; i++)
        {
            int r = pairR[i];
            int b = pairB[i];

            char nameR[256];
            char nameB[256];
            bool hasFilterR = GetFiltersNameOrEmpty(r, nameR, sizeof(nameR));
            bool hasFilterB = GetFiltersNameOrEmpty(b, nameB, sizeof(nameB));

            int srcClient = r;
            bool useTeamColorR = false;
            bool useTeamColorB = false;

            if (!hasFilterR && !hasFilterB)
            {
                srcClient = r;
                useTeamColorR = true;
            }
            else if (!hasFilterR)
            {
                srcClient = r;
                useTeamColorR = true;
            }
            else if (!hasFilterB)
            {
                srcClient = b;
                useTeamColorB = true;
            }

            if (!hasFilterR)
            {
                BuildFallbackName(r, useTeamColorR, nameR, sizeof(nameR));
            }
            if (!hasFilterB)
            {
                BuildFallbackName(b, useTeamColorB, nameB, sizeof(nameB));
            }

            CPrintToChatAllEx(srcClient, "%s <-> %s", nameR, nameB);
            LogWhale("Pair %d: %N <-> %N.", i + 1, r, b);
        }

        for (int i = 0; i < pairCount; i++)
        {
            int r = pairR[i];
            int b = pairB[i];
            if (r > 0 && IsClientInGame(r))
            {
                PrintCenterText(r, "You have been scrambled!");
            }
            if (b > 0 && IsClientInGame(b))
            {
                PrintCenterText(b, "You have been scrambled!");
            }
        }
    }
    else
    {
        int issuer = GetClientOfUserId(issuerUserId);
        if (issuer > 0 && IsClientInGame(issuer))
        {
            ReplyToCommand(issuer, "[whalescramble] No eligible players to swap.");
        }
        LogWhale("Scramble executed: no eligible pairs.");
    }
    return Plugin_Stop;
}

public Action Timer_ResetScrambleCooldown(Handle timer)
{
    if (timer == g_hScrambleCooldownTimer)
    {
        g_hScrambleCooldownTimer = null;
    }
    scrambleCooldown = false;
    LogWhale("Scramble cooldown expired.");
    return Plugin_Stop;
}

static void NotifyFailure(int issuer, bool broadcastFailures, const char[] fmt, any ...)
{
    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 4);
    if (issuer > 0 && IsClientInGame(issuer))
    {
        ReplyToCommand(issuer, "[whalescramble] %s", buffer);
        return;
    }
    if (broadcastFailures)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} %s", buffer);
    }
}

static void InsertTopN(int client, int score, int clients[MAX_SWAP_BUFFER], int scores[MAX_SWAP_BUFFER], int maxCount)
{
    for (int i = 0; i < maxCount; i++)
    {
        if (score > scores[i])
        {
            for (int j = maxCount - 1; j > i; j--)
            {
                scores[j] = scores[j - 1];
                clients[j] = clients[j - 1];
            }
            scores[i] = score;
            clients[i] = client;
            return;
        }
    }
}

static int GetScrambleScore(int client, bool ignoreClass, bool forced)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return 0;
    }

    if (!ignoreClass)
    {
        TFClassType cls = TF2_GetPlayerClass(client);
        if (cls == TFClass_Spy
            || (forced && (cls == TFClass_Engineer || cls == TFClass_Medic)))
        {
            return 0;
        }
    }

    return GetClientFrags(client);
}

static bool IsSimpleScrambleEligibleClass(int client, bool forced)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    TFClassType cls = TF2_GetPlayerClass(client);
    return !forced || (cls != TFClass_Engineer && cls != TFClass_Medic);
}

static bool SelectRandomPlayers(const int candidates[MAXPLAYERS + 1], int candidateCount, int selected[MAX_SWAP_BUFFER], int selectedCount)
{
    if (selectedCount <= 0 || selectedCount > MAX_SWAP_BUFFER || candidateCount < selectedCount)
    {
        return false;
    }

    int pool[MAXPLAYERS + 1];
    for (int i = 0; i < candidateCount; i++)
    {
        pool[i] = candidates[i];
    }

    for (int i = 0; i < selectedCount; i++)
    {
        int remaining = candidateCount - i;
        int pick = GetRandomInt(0, remaining - 1);
        selected[i] = pool[pick];
        pool[pick] = pool[remaining - 1];
    }

    return true;
}

static bool IsScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return false;
    }

    if (IsClientCurrentRoundMvpSafe(client))
    {
        return true;
    }

    if (HasClanTeammateProtection(client))
    {
        return true;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    int dummy = 0;
    return g_hScrambleImmunity.GetValue(steamId, dummy);
}

static bool IsClientCurrentRoundMvpSafe(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_IsCurrentRoundMvp") != FeatureStatus_Available)
    {
        return false;
    }

    return WhaleTracker_IsCurrentRoundMvp(client);
}

static bool HasClanTeammateProtection(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "Clans_GetSameTeamClanMemberCount") != FeatureStatus_Available)
    {
        return false;
    }

    int count = Clans_GetSameTeamClanMemberCount(client);
    return (count < 0 || count > 1);
}

static void MarkScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return;
    }

    g_hScrambleImmunity.SetValue(steamId, 1, true);
}

static void LogWhale(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static bool GetFiltersNameOrEmpty(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (client <= 0 || !IsClientInGame(client))
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available)
    {
        if (Filters_GetChatName(client, buffer, maxlen) && buffer[0] != '\0')
        {
            return true;
        }
    }
    return false;
}

static void BuildFallbackName(int client, bool useTeamColor, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    if (useTeamColor)
    {
        Format(buffer, maxlen, "{teamcolor}%s{default}", name);
        return;
    }

    char colorTag[16];
    switch (GetClientTeam(client))
    {
        case TEAM_RED: strcopy(colorTag, sizeof(colorTag), "{red}");
        case TEAM_BLU: strcopy(colorTag, sizeof(colorTag), "{blue}");
        case 4: strcopy(colorTag, sizeof(colorTag), "{green}");
        case 5: strcopy(colorTag, sizeof(colorTag), "{yellow}");
        default: strcopy(colorTag, sizeof(colorTag), "{default}");
    }

    Format(buffer, maxlen, "%s%s{default}", colorTag, name);
}
