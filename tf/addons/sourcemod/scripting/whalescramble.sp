// Whale scramble vote helper (NativeVotes)
#include <sourcemod>
#include <morecolors>
#include <nativevotes>
#include <sdktools>
#include <tf2_stocks>
#undef REQUIRE_PLUGIN
#include <clans_api>
#include <whaletracker_api>
#include <points_store_api>
#define REQUIRE_PLUGIN
#include "include/dgm_api.inc"
#include "include/plugin_statistics.inc"

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
ConVar g_hLogEnabled = null;
ConVar g_hAutoRounds = null;
ConVar g_hVoteTime = null;
ConVar g_hCountBots = null;
ConVar g_hTopSwap = null;
ConVar g_hRandom = null;
ConVar g_hFragBalance = null;
ConVar g_hDisableTfAuto = null;
ConVar g_hShortRoundAutoSeconds = null;
ConVar g_hKothNoCapAuto = null;
ConVar g_hWinStreakAuto = null;
ConVar g_hNoSequentialAuto = null;
ConVar g_hMpScrambleTeamsAuto = null;
int g_iRoundsSinceAuto = 0;
StringMap g_hScrambleImmunity = null;
bool g_bAutoScramblePendingRoundStart = false;
float g_flAutoScramblePendingRoundStartUntil = 0.0;
bool g_bExecuteSwapImmediately = false;
bool g_bSuppressSwapRespawn = false;
bool g_bKothRedCapped = false;
bool g_bKothBluCapped = false;
int g_iLastFullRoundWinner = 0;
int g_iWinStreak = 0;
bool g_bScrambledThisRound = false;
bool g_bLastRoundHadScramble = false;
int g_iRoundStartTimestamp = 0;
int g_iScrambleRespawnAttempts[MAXPLAYERS + 1];

#define TEAM_RED  2
#define TEAM_BLU  3
#define MAX_RANDOM_SWAP  5
#define MAX_TOP_SWAP  MAX_RANDOM_SWAP
#define MAX_SWAP_BUFFER  MAX_RANDOM_SWAP
#define MIN_SCRAMBLE_PLAYERS  3
#define FRAG_BALANCE_ENTRY_SUM  0
#define FRAG_BALANCE_ENTRY_CLIENT0  1
#define FRAG_BALANCE_ENTRY_CELLS  (FRAG_BALANCE_ENTRY_CLIENT0 + MAX_SWAP_BUFFER)
#define SCRAMBLE_PLAYER_PERCENT_DIVISOR  5
#define SCRAMBLE_RESPAWN_RETRY_DELAY  0.2
#define SCRAMBLE_RESPAWN_RETRY_COUNT  3
#define POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM "scramImmunity24h"
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
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("PointsStore_ConsumePurchaseUse");
    MarkNativeAsOptional("DGM_IsSmallFormatGamemode");
    MarkNativeAsOptional("DGM_RealTeamPlayerCount");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_GetLastRoundDurationSeconds");
    MarkNativeAsOptional("DGM_IsSetupActive");
    return APLRes_Success;
}

public void OnPluginStart()
{
    UpdateNativeVotes();
    g_hLogEnabled = CreateConVar("sm_whalescramble_log", "1", "Enable whalescramble debug logging.", _, true, 0.0, true, 1.0);
    PluginStats_Init("whalescramble_statistics_events");
    LogWhale("Plugin started.");
    g_hAutoRounds = CreateConVar("whalescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("whalescramble_votetime", "4", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hCountBots = CreateConVar("whalescramble_count_bots", "1", "Include bots when selecting whale scramble targets.", _, true, 0.0, true, 1.0);
    g_hTopSwap = CreateConVar("sm_ws_topswap", "0", "Enable topswap scramble mode.", _, true, 0.0, true, 1.0);
    g_hRandom = CreateConVar("sm_ws_random", "1", "Enable random scramble mode.", _, true, 0.0, true, 1.0);
    g_hFragBalance = CreateConVar("sm_ws_frags", "0", "Enable frag-balanced random scramble mode.", _, true, 0.0, true, 1.0);
    g_hDisableTfAuto = CreateConVar("sm_whalescramble_disable_tf_auto", "1", "Disable TF2's built-in mp_scrambleteams_auto while WhaleScramble owns auto scrambles.", _, true, 0.0, true, 1.0);
    g_hShortRoundAutoSeconds = CreateConVar("sm_whalescramble_short_round_seconds", "60", "Automatically whale scramble when the previous round duration is under this many seconds. 0 disables.", _, true, 0.0, true, 600.0);
    g_hKothNoCapAuto = CreateConVar("sm_whalescramble_koth_no_cap", "1", "Automatically whale scramble when a full KOTH round ends with either team never capturing the point.", _, true, 0.0, true, 1.0);
    g_hWinStreakAuto = CreateConVar("sm_whalescramble_win_streak", "2", "Automatically whale scramble after one team wins this many full rounds in a row. 0 disables.", _, true, 0.0, true, 20.0);
    g_hNoSequentialAuto = CreateConVar("sm_whalescramble_no_sequential", "1", "Block auto scrambles from happening in consecutive rounds or more than once in one round.", _, true, 0.0, true, 1.0);
    g_hMpScrambleTeamsAuto = FindConVar("mp_scrambleteams_auto");
    g_hScrambleImmunity = new StringMap();

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
    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("teamplay_point_captured", Event_PointCaptured, EventHookMode_Post);
    HookEvent("teamplay_game_over", Event_GameOver, EventHookMode_PostNoCopy);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
}

public void OnConfigsExecuted()
{
    ApplyEngineScramblePolicy();
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
    PluginStats_OnMapStart();
    ResetVotes();
    ClearScrambleRespawnAttempts();
    ClearScrambleCooldown();
    ClearAutoScramblePending();
    ApplyEngineScramblePolicy();
    g_iRoundsSinceAuto = 0;
    if (g_hScrambleImmunity != null)
    {
        g_hScrambleImmunity.Clear();
    }
    LogWhale("Map start: immunity cleared, votes reset.");
}

public void OnMapEnd()
{
    ResetVotes();
    ClearScrambleRespawnAttempts();
    ClearScrambleCooldown();
    ClearAutoScramblePending();
    g_iRoundsSinceAuto = 0;
    LogWhale("Map end: votes reset.");
}

public void OnPluginEnd()
{
    ResetVotes();
    ClearScrambleCooldown();
    ClearAutoScramblePending();
    LogWhale("Plugin ended.");
    PluginStats_Shutdown();
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
    g_iScrambleRespawnAttempts[client] = 0;
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
    bool fullRound = event.GetBool("full_round");
    LogWhale("Round win: full_round=%d voteRunning=%d activeKind=%d activeTeam=%d.",
        fullRound ? 1 : 0,
        g_bVoteRunning ? 1 : 0,
        g_eActiveVoteKind,
        g_iActiveSurrenderTeam);
    ResetSurrenderVotes("round_win");

    if (fullRound)
    {
        CreateTimer(0.1, Timer_CheckShortRoundAutoScramble, _, TIMER_FLAG_NO_MAPCHANGE);
        CheckKothNoCapAutoScramble();
        CheckWinStreakAutoScramble(event.GetInt("team"));
        g_bLastRoundHadScramble = g_bScrambledThisRound;
    }

    if (g_hAutoRounds == null)
    {
        return;
    }

    // full_round is 1 if the entire map/round is over (Red lost or Blue finished final stage)
    // full_round is 0 if it was just a stage completion (e.g., Goldrush Stage 1)
    if (!fullRound)
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

    TryArmAutoScrambleForNextRound("round-count");
}

public Action Timer_CheckShortRoundAutoScramble(Handle timer)
{
    if (g_hShortRoundAutoSeconds == null)
    {
        return Plugin_Stop;
    }

    int threshold = g_hShortRoundAutoSeconds.IntValue;
    if (threshold <= 0)
    {
        return Plugin_Stop;
    }

    if (GetFeatureStatus(FeatureType_Native, "DGM_GetLastRoundDurationSeconds") != FeatureStatus_Available)
    {
        LogWhale("Short-round auto scramble skipped: DGM_GetLastRoundDurationSeconds unavailable.");
        return Plugin_Stop;
    }

    int duration = DGM_GetLastRoundDurationSeconds();
    if (duration <= 0 || duration >= threshold)
    {
        LogWhale("Short-round auto scramble skipped: duration=%d threshold=%d.", duration, threshold);
        return Plugin_Stop;
    }

    if (TryArmAutoScrambleForNextRound("short-round"))
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Round ended in under {lightgreen}%d{default} seconds, scrambling!", threshold);
        LogWhale("Short-round auto scramble armed: duration=%d threshold=%d.", duration, threshold);
    }
    return Plugin_Stop;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bKothRedCapped = false;
    g_bKothBluCapped = false;
    g_bScrambledThisRound = false;
    g_iRoundStartTimestamp = GetTime();

    if (!ConsumeAutoScramblePending())
    {
        return;
    }

    g_bExecuteSwapImmediately = true;
    g_bSuppressSwapRespawn = true;
    bool started = StartAutoScramble(true);
    g_bSuppressSwapRespawn = false;
    g_bExecuteSwapImmediately = false;

    if (!started)
    {
        LogWhale("Pending auto scramble could not start on round start.");
    }
}

public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    int team = event.GetInt("team");
    if (team == TEAM_RED)
    {
        g_bKothRedCapped = true;
    }
    else if (team == TEAM_BLU)
    {
        g_bKothBluCapped = true;
    }
}

static void CheckKothNoCapAutoScramble()
{
    if (g_hKothNoCapAuto == null || !g_hKothNoCapAuto.BoolValue)
    {
        return;
    }

    if (!IsCurrentKothGamemode())
    {
        return;
    }

    if (g_bKothRedCapped && g_bKothBluCapped)
    {
        return;
    }

    if (TryArmAutoScrambleForNextRound("koth-no-cap"))
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} KOTH steamroll detected, scrambling!");
        LogWhale("KOTH no-cap auto scramble armed: redCapped=%d bluCapped=%d.", g_bKothRedCapped ? 1 : 0, g_bKothBluCapped ? 1 : 0);
    }
}

static bool IsCurrentKothGamemode()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") != FeatureStatus_Available)
    {
        return false;
    }

    char gamemodeKey[32];
    if (!DGM_GetGameModeKey(gamemodeKey, sizeof(gamemodeKey)))
    {
        return false;
    }

    return StrEqual(gamemodeKey, "koth", false);
}

static void CheckWinStreakAutoScramble(int winningTeam)
{
    if (g_hWinStreakAuto == null)
    {
        return;
    }

    int threshold = g_hWinStreakAuto.IntValue;
    if (threshold <= 0)
    {
        return;
    }

    if (winningTeam != TEAM_RED && winningTeam != TEAM_BLU)
    {
        g_iLastFullRoundWinner = 0;
        g_iWinStreak = 0;
        return;
    }

    if (winningTeam == g_iLastFullRoundWinner)
    {
        g_iWinStreak++;
    }
    else
    {
        g_iLastFullRoundWinner = winningTeam;
        g_iWinStreak = 1;
    }

    if (g_iWinStreak < threshold)
    {
        return;
    }

    if (TryArmAutoScrambleForNextRound("win-streak"))
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Win streak reached {lightgreen}%d{default}, scrambling!", threshold);
        LogWhale("Win-streak auto scramble armed: team=%d streak=%d threshold=%d.", winningTeam, g_iWinStreak, threshold);
    }
}

public void Event_GameOver(Event event, const char[] name, bool dontBroadcast)
{
    ClearAutoScramblePending();
    LogWhale("Game over: auto scramble pending state cleared.");
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

static void GetScrambleTeamCounts(int &redCount, int &bluCount, int &totalPlayers)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealTeamPlayerCount") == FeatureStatus_Available)
    {
        redCount = DGM_RealTeamPlayerCount(TEAM_RED);
        bluCount = DGM_RealTeamPlayerCount(TEAM_BLU);
    }
    else
    {
        redCount = GetPlayableTeamClientCount(TEAM_RED);
        bluCount = GetPlayableTeamClientCount(TEAM_BLU);
    }

    totalPlayers = redCount + bluCount;
}

static int CalculateDesiredScrambleSwapCount(int totalPlayers, int redCount, int bluCount, int maxSwapPairs)
{
    if (totalPlayers < MIN_SCRAMBLE_PLAYERS || redCount <= 0 || bluCount <= 0)
    {
        return 0;
    }

    int swapCount = (totalPlayers + SCRAMBLE_PLAYER_PERCENT_DIVISOR - 1) / SCRAMBLE_PLAYER_PERCENT_DIVISOR;
    if (swapCount < 1)
    {
        swapCount = 1;
    }
    if (swapCount > maxSwapPairs)
    {
        swapCount = maxSwapPairs;
    }
    if (swapCount > redCount)
    {
        swapCount = redCount;
    }
    if (swapCount > bluCount)
    {
        swapCount = bluCount;
    }

    return swapCount;
}

static int LimitSwapCountToEligibility(int swapCount, int redEligible, int bluEligible)
{
    if (swapCount > redEligible)
    {
        swapCount = redEligible;
    }
    if (swapCount > bluEligible)
    {
        swapCount = bluEligible;
    }
    if (swapCount < 0)
    {
        swapCount = 0;
    }

    return swapCount;
}

static void NotifySwapCountFailure(int issuer, bool broadcastFailures, int totalPlayers, int redCount, int bluCount, int redEligible, int bluEligible, const char[] modeName)
{
    if (totalPlayers < MIN_SCRAMBLE_PLAYERS)
    {
        NotifyFailure(issuer, broadcastFailures, "Need at least %d RED/BLU players (current: %d).", MIN_SCRAMBLE_PLAYERS, totalPlayers);
        LogWhale("%s scramble aborted: not enough players (total=%d min=%d).", modeName, totalPlayers, MIN_SCRAMBLE_PLAYERS);
        return;
    }

    if (redCount <= 0 || bluCount <= 0)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least 1 player (RED=%d BLU=%d).", redCount, bluCount);
        LogWhale("%s scramble aborted: one team empty (red=%d blu=%d).", modeName, redCount, bluCount);
        return;
    }

    NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
    LogWhale("%s scramble aborted: not enough eligible players (red=%d blu=%d).", modeName, redEligible, bluEligible);
}

static bool ShouldIgnoreScrambleImmunity(int totalPlayers, bool randomMode)
{
    if (randomMode)
    {
        return totalPlayers <= (MAX_RANDOM_SWAP * 2);
    }

    return totalPlayers <= (MAX_TOP_SWAP * 2);
}

static void ApplyEngineScramblePolicy()
{
    if (g_hDisableTfAuto == null || !g_hDisableTfAuto.BoolValue)
    {
        return;
    }

    if (g_hMpScrambleTeamsAuto == null)
    {
        g_hMpScrambleTeamsAuto = FindConVar("mp_scrambleteams_auto");
    }

    if (g_hMpScrambleTeamsAuto == null)
    {
        LogWhale("Unable to find mp_scrambleteams_auto for policy enforcement.");
        return;
    }

    if (g_hMpScrambleTeamsAuto.BoolValue)
    {
        g_hMpScrambleTeamsAuto.SetBool(false);
        LogWhale("Disabled TF2 mp_scrambleteams_auto; WhaleScramble owns auto scrambles.");
    }
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

    if (scrambleCooldown)
    {
        LogWhale("Auto scramble aborted: scramble cooldown active.");
        return false;
    }

    if (!suppressFeedback)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Auto scramble triggered.");
    }

    LogWhale("Auto scramble triggered.");
    return StartConfiguredWhaleScramble(0, !suppressFeedback, false, false);
}

static bool StartConfiguredWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    if (g_hTopSwap != null && g_hTopSwap.BoolValue)
    {
        LogWhale("Configured scramble mode: topswap forced=%d.", forced ? 1 : 0);
        return StartWhaleScramble(issuer, broadcastFailures, allowLowPop, forced);
    }
    else if (g_hFragBalance != null && g_hFragBalance.BoolValue)
    {
        LogWhale("Configured scramble mode: frags forced=%d.", forced ? 1 : 0);
        return StartFragBalanceWhaleScramble(issuer, broadcastFailures, allowLowPop, forced);
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

static void ArmAutoScrambleForNextRound()
{
    g_bAutoScramblePendingRoundStart = true;
    g_flAutoScramblePendingRoundStartUntil = GetEngineTime() + 20.0;
    LogWhale("Auto scramble armed for next round start.");
}

static bool TryArmAutoScrambleForNextRound(const char[] reason)
{
    if (g_bAutoScramblePendingRoundStart)
    {
        LogWhale("Auto scramble already pending; reason=%s.", reason);
        return false;
    }

    if (g_hNoSequentialAuto != null && g_hNoSequentialAuto.BoolValue)
    {
        if (g_bScrambledThisRound)
        {
            LogWhale("Auto scramble blocked by no-sequential guard: already scrambled this round; reason=%s.", reason);
            return false;
        }

        if (g_bLastRoundHadScramble)
        {
            LogWhale("Auto scramble blocked by no-sequential guard: previous round scrambled; reason=%s.", reason);
            return false;
        }
    }

    LogWhale("Auto scramble arming accepted: reason=%s.", reason);
    ArmAutoScrambleForNextRound();
    return true;
}

static bool ConsumeAutoScramblePending()
{
    if (!g_bAutoScramblePendingRoundStart)
    {
        return false;
    }

    if (GetEngineTime() > g_flAutoScramblePendingRoundStartUntil)
    {
        ClearAutoScramblePending();
        LogWhale("Auto scramble pending state expired before round start.");
        return false;
    }

    ClearAutoScramblePending();
    return true;
}

static void ClearAutoScramblePending()
{
    g_bAutoScramblePendingRoundStart = false;
    g_flAutoScramblePendingRoundStartUntil = 0.0;
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

    GetScrambleTeamCounts(redCount, bluCount, totalPlayers);

    bool smallFormatGamemode = IsSmallFormatGamemode();
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

    int desiredSwapCount = CalculateDesiredScrambleSwapCount(totalPlayers, redCount, bluCount, MAX_TOP_SWAP);
    int swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    LogWhale("Counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d desiredSwap=%d swap=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible, desiredSwapCount, swapCount);

    bool needsFallback = (desiredSwapCount > 0 && swapCount < desiredSwapCount);
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
        swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    }

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, "Topswap");
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
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    if (g_bExecuteSwapImmediately)
    {
        LogWhale("Scramble executing immediately: swapCount=%d.", swapCount);
        Timer_DoSwap(null, pack);
    }
    else
    {
        CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
        LogWhale("Scramble scheduled: swapCount=%d.", swapCount);
    }
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

    GetScrambleTeamCounts(redCount, bluCount, totalPlayers);

    bool smallFormatGamemode = IsSmallFormatGamemode();
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

    int desiredSwapCount = CalculateDesiredScrambleSwapCount(totalPlayers, redCount, bluCount, MAX_RANDOM_SWAP);
    int swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    LogWhale("Random counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d desiredSwap=%d swap=%d.", totalPlayers, redCount, bluCount, redEligible, bluEligible, desiredSwapCount, swapCount);

    bool needsFallback = (desiredSwapCount > 0 && swapCount < desiredSwapCount);
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
        swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    }

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, "Random");
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
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    if (g_bExecuteSwapImmediately)
    {
        LogWhale("Random scramble executing immediately: swapCount=%d.", swapCount);
        Timer_DoSwap(null, pack);
    }
    else
    {
        CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
        LogWhale("Random scramble scheduled: swapCount=%d.", swapCount);
    }
    return true;
}

static bool StartFragBalanceWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    LogWhale("StartFragBalanceWhaleScramble: issuer=%d allowLowPop=%d forced=%d.", issuer, allowLowPop ? 1 : 0, forced ? 1 : 0);
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
    int clientFrags[MAXPLAYERS + 1];
    int redFragTotal = 0;
    int bluFragTotal = 0;
    int topRed[MAX_SWAP_BUFFER];
    int topBlu[MAX_SWAP_BUFFER];

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        topRed[i] = 0;
        topBlu[i] = 0;
    }

    GetScrambleTeamCounts(redCount, bluCount, totalPlayers);

    bool smallFormatGamemode = IsSmallFormatGamemode();
    bool ignoreImmunity = smallFormatGamemode || ShouldIgnoreScrambleImmunity(totalPlayers, true);
    if (ignoreImmunity)
    {
        LogWhale(
            "Frag balance scramble: ignoring immunity due to %s total=%d threshold=%d.",
            smallFormatGamemode ? "small-format gamemode" : "low player count",
            totalPlayers,
            MAX_RANDOM_SWAP * 2);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue))
            continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU)
            continue;

        int frags = GetClientFrags(i);
        clientFrags[i] = frags;
        if (team == TEAM_RED)
        {
            redFragTotal += frags;
        }
        else
        {
            bluFragTotal += frags;
        }

        if (!ignoreImmunity && IsScrambleImmune(i))
            continue;
        if (!IsSimpleScrambleEligibleClass(i, forced))
            continue;

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

    int desiredSwapCount = CalculateDesiredScrambleSwapCount(totalPlayers, redCount, bluCount, MAX_RANDOM_SWAP);
    int swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    LogWhale(
        "Frag balance counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d desiredSwap=%d swap=%d redFrags=%d bluFrags=%d.",
        totalPlayers,
        redCount,
        bluCount,
        redEligible,
        bluEligible,
        desiredSwapCount,
        swapCount,
        redFragTotal,
        bluFragTotal);

    bool needsFallback = (desiredSwapCount > 0 && swapCount < desiredSwapCount);
    if (needsFallback)
    {
        LogWhale("Frag balance eligibility low; recalculating without class filters.");
        redEligible = 0;
        bluEligible = 0;
        redCandidateCount = 0;
        bluCandidateCount = 0;

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i))
                continue;
            if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue))
                continue;

            int team = GetClientTeam(i);
            if (team != TEAM_RED && team != TEAM_BLU)
                continue;
            if (!ignoreImmunity && IsScrambleImmune(i))
                continue;

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

        swapCount = LimitSwapCountToEligibility(desiredSwapCount, redEligible, bluEligible);
    }

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, "Frag balance");
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Frag balance scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Frag balance scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        return false;
    }

    if (!SelectFragBalancePlayers(redCandidates, bluCandidates, clientFrags, redCandidateCount, bluCandidateCount, redFragTotal, bluFragTotal, topRed, topBlu, swapCount))
    {
        NotifyFailure(issuer, broadcastFailures, "Failed to select frag-balanced swap targets.");
        LogWhale("Frag balance scramble aborted: selection failed (swap=%d redCandidates=%d bluCandidates=%d redFrags=%d bluFrags=%d).", swapCount, redCandidateCount, bluCandidateCount, redFragTotal, bluFragTotal);
        return false;
    }

    int selectedRedFrags = 0;
    int selectedBluFrags = 0;
    for (int i = 0; i < swapCount; i++)
    {
        selectedRedFrags += clientFrags[topRed[i]];
        selectedBluFrags += clientFrags[topBlu[i]];
    }

    int beforeDiff = FragBalanceAbs(redFragTotal - bluFragTotal);
    int afterDiff = FragBalanceAbs((redFragTotal - bluFragTotal) - (2 * selectedRedFrags) + (2 * selectedBluFrags));
    LogWhale(
        "Frag balance selected: swap=%d redFrags=%d bluFrags=%d selectedRedFrags=%d selectedBluFrags=%d beforeDiff=%d afterDiff=%d.",
        swapCount,
        redFragTotal,
        bluFragTotal,
        selectedRedFrags,
        selectedBluFrags,
        beforeDiff,
        afterDiff);

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topRed[i]));
    }
    for (int i = 0; i < swapCount; i++)
    {
        pack.WriteCell(GetClientUserId(topBlu[i]));
    }

    if (g_bExecuteSwapImmediately)
    {
        LogWhale("Frag balance scramble executing immediately: swapCount=%d.", swapCount);
        Timer_DoSwap(null, pack);
    }
    else
    {
        CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
        LogWhale("Frag balance scramble scheduled: swapCount=%d.", swapCount);
    }

    return true;
}

static bool SelectFragBalancePlayers(
    int redCandidates[MAXPLAYERS + 1],
    int bluCandidates[MAXPLAYERS + 1],
    int clientFrags[MAXPLAYERS + 1],
    int redCandidateCount,
    int bluCandidateCount,
    int redFragTotal,
    int bluFragTotal,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int selectedCount)
{
    if (selectedCount <= 0 || selectedCount > MAX_SWAP_BUFFER || redCandidateCount < selectedCount || bluCandidateCount < selectedCount)
    {
        return false;
    }

    ArrayList bluSubsets = new ArrayList(FRAG_BALANCE_ENTRY_CELLS);
    int chosenBlu[MAX_SWAP_BUFFER];
    AddFragBalanceSubsetsRecursive(bluCandidates, clientFrags, bluCandidateCount, selectedCount, 0, 0, 0, chosenBlu, bluSubsets);
    if (bluSubsets.Length <= 0)
    {
        delete bluSubsets;
        return false;
    }

    bluSubsets.SortCustom(SortFragBalanceSubsetBySum);

    int chosenRed[MAX_SWAP_BUFFER];
    int bestFinalDiff = 0;
    bool found = false;
    EvaluateFragBalanceRedSubsetsRecursive(
        redCandidates,
        clientFrags,
        redCandidateCount,
        selectedCount,
        0,
        0,
        0,
        chosenRed,
        bluSubsets,
        redFragTotal - bluFragTotal,
        selectedRed,
        selectedBlu,
        bestFinalDiff,
        found);

    delete bluSubsets;
    return found;
}

static void AddFragBalanceSubsetsRecursive(
    int candidates[MAXPLAYERS + 1],
    int clientFrags[MAXPLAYERS + 1],
    int candidateCount,
    int selectedCount,
    int start,
    int chosenCount,
    int currentSum,
    int chosen[MAX_SWAP_BUFFER],
    ArrayList subsets)
{
    if (chosenCount == selectedCount)
    {
        int entry[FRAG_BALANCE_ENTRY_CELLS];
        entry[FRAG_BALANCE_ENTRY_SUM] = currentSum;
        for (int i = 0; i < MAX_SWAP_BUFFER; i++)
        {
            entry[FRAG_BALANCE_ENTRY_CLIENT0 + i] = (i < selectedCount) ? chosen[i] : 0;
        }
        subsets.PushArray(entry, sizeof(entry));
        return;
    }

    int remainingNeeded = selectedCount - chosenCount;
    for (int i = start; i <= candidateCount - remainingNeeded; i++)
    {
        int client = candidates[i];
        chosen[chosenCount] = client;
        AddFragBalanceSubsetsRecursive(candidates, clientFrags, candidateCount, selectedCount, i + 1, chosenCount + 1, currentSum + clientFrags[client], chosen, subsets);
    }
}

static void EvaluateFragBalanceRedSubsetsRecursive(
    int redCandidates[MAXPLAYERS + 1],
    int clientFrags[MAXPLAYERS + 1],
    int redCandidateCount,
    int selectedCount,
    int start,
    int chosenCount,
    int currentRedSum,
    int chosenRed[MAX_SWAP_BUFFER],
    ArrayList bluSubsets,
    int teamFragDelta,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int &bestFinalDiff,
    bool &found)
{
    if (chosenCount == selectedCount)
    {
        int targetTwice = (2 * currentRedSum) - teamFragDelta;
        int index = FindFirstFragBalanceSubsetAtLeastTwice(bluSubsets, targetTwice);
        TryFragBalanceCandidate(bluSubsets, index, selectedCount, currentRedSum, chosenRed, teamFragDelta, selectedRed, selectedBlu, bestFinalDiff, found);
        TryFragBalanceCandidate(bluSubsets, index - 1, selectedCount, currentRedSum, chosenRed, teamFragDelta, selectedRed, selectedBlu, bestFinalDiff, found);
        return;
    }

    int remainingNeeded = selectedCount - chosenCount;
    for (int i = start; i <= redCandidateCount - remainingNeeded; i++)
    {
        int client = redCandidates[i];
        chosenRed[chosenCount] = client;
        EvaluateFragBalanceRedSubsetsRecursive(
            redCandidates,
            clientFrags,
            redCandidateCount,
            selectedCount,
            i + 1,
            chosenCount + 1,
            currentRedSum + clientFrags[client],
            chosenRed,
            bluSubsets,
            teamFragDelta,
            selectedRed,
            selectedBlu,
            bestFinalDiff,
            found);
    }
}

static void TryFragBalanceCandidate(
    ArrayList bluSubsets,
    int index,
    int selectedCount,
    int currentRedSum,
    int chosenRed[MAX_SWAP_BUFFER],
    int teamFragDelta,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int &bestFinalDiff,
    bool &found)
{
    if (index < 0 || index >= bluSubsets.Length)
    {
        return;
    }

    int entry[FRAG_BALANCE_ENTRY_CELLS];
    bluSubsets.GetArray(index, entry, sizeof(entry));

    int finalDiff = FragBalanceAbs(teamFragDelta - (2 * currentRedSum) + (2 * entry[FRAG_BALANCE_ENTRY_SUM]));
    if (found && finalDiff >= bestFinalDiff)
    {
        return;
    }

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        selectedRed[i] = (i < selectedCount) ? chosenRed[i] : 0;
        selectedBlu[i] = (i < selectedCount) ? entry[FRAG_BALANCE_ENTRY_CLIENT0 + i] : 0;
    }

    bestFinalDiff = finalDiff;
    found = true;
}

static int FindFirstFragBalanceSubsetAtLeastTwice(ArrayList subsets, int targetTwice)
{
    int low = 0;
    int high = subsets.Length;
    int entry[FRAG_BALANCE_ENTRY_CELLS];

    while (low < high)
    {
        int mid = (low + high) / 2;
        subsets.GetArray(mid, entry, sizeof(entry));
        if ((2 * entry[FRAG_BALANCE_ENTRY_SUM]) < targetTwice)
        {
            low = mid + 1;
        }
        else
        {
            high = mid;
        }
    }

    return low;
}

static int SortFragBalanceSubsetBySum(int index1, int index2, Handle array, Handle hndl)
{
    ArrayList subsets = view_as<ArrayList>(array);
    int entry1[FRAG_BALANCE_ENTRY_CELLS];
    int entry2[FRAG_BALANCE_ENTRY_CELLS];
    subsets.GetArray(index1, entry1, sizeof(entry1));
    subsets.GetArray(index2, entry2, sizeof(entry2));

    if (entry1[FRAG_BALANCE_ENTRY_SUM] < entry2[FRAG_BALANCE_ENTRY_SUM])
    {
        return -1;
    }
    if (entry1[FRAG_BALANCE_ENTRY_SUM] > entry2[FRAG_BALANCE_ENTRY_SUM])
    {
        return 1;
    }
    return 0;
}

static int FragBalanceAbs(int value)
{
    return value < 0 ? -value : value;
}

public Action Timer_DoSwap(Handle timer, DataPack pack)
{
    pack.Reset();
    int issuerUserId = pack.ReadCell();
    int swapCount = pack.ReadCell();
    bool ignoreImmunity = view_as<bool>(pack.ReadCell());

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

    bool suppressRespawn = g_bSuppressSwapRespawn;
    bool setupScramble = IsSetupActive();
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
        if (!ResolveScramblePurchaseImmunity(r, TEAM_RED, redIds, bluIds, swapCount, i, ignoreImmunity)) continue;
        if (!ResolveScramblePurchaseImmunity(b, TEAM_BLU, redIds, bluIds, swapCount, i, ignoreImmunity)) continue;
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
            if (!suppressRespawn)
            {
                QueueScrambleRespawn(r);
            }
            MarkScrambleImmune(r);
        }
        if (b > 0 && IsClientInGame(b) && GetClientTeam(b) == TEAM_BLU)
        {
            ChangeClientTeam(b, TEAM_RED);
            if (!suppressRespawn)
            {
                QueueScrambleRespawn(b);
            }
            MarkScrambleImmune(b);
        }
    }

    moved = pairCount * 2;
    if (moved > 0)
    {
        g_bScrambledThisRound = true;
        ResetSurrenderVotes("whalescramble_execute");
        StartScrambleCooldown();
        CPrintToChatAll("{tomato}[{purple}Gap{tomato}]{default} {gold}Whalescrambling{default} %d players!", moved);
        LogWhale("Scramble executed: moved=%d pairs=%d suppressRespawn=%d.", moved, pairCount, suppressRespawn ? 1 : 0);
        if (setupScramble)
        {
            ApplySetupScramblePolish();
        }
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

static void ClearScrambleRespawnAttempts()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iScrambleRespawnAttempts[client] = 0;
    }
}

static void QueueScrambleRespawn(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    g_iScrambleRespawnAttempts[client] = SCRAMBLE_RESPAWN_RETRY_COUNT;
    CreateTimer(SCRAMBLE_RESPAWN_RETRY_DELAY, Timer_VerifyScrambleRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_VerifyScrambleRespawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }

    int team = GetClientTeam(client);
    if (team != TEAM_RED && team != TEAM_BLU)
    {
        g_iScrambleRespawnAttempts[client] = 0;
        return Plugin_Stop;
    }

    if (TF2_GetPlayerClass(client) == TFClass_Unknown)
    {
        TF2_SetPlayerClass(client, TFClass_Scout);
    }

    if (!IsPlayerAlive(client))
    {
        TF2_RespawnPlayer(client);
    }

    g_iScrambleRespawnAttempts[client]--;
    if (IsPlayerAlive(client) || g_iScrambleRespawnAttempts[client] <= 0)
    {
        g_iScrambleRespawnAttempts[client] = 0;
        return Plugin_Stop;
    }

    CreateTimer(SCRAMBLE_RESPAWN_RETRY_DELAY, Timer_VerifyScrambleRespawn, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

static bool IsSetupActive()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_IsSetupActive") != FeatureStatus_Available)
    {
        LogWhale("Setup scramble polish skipped: DGM_IsSetupActive unavailable.");
        return false;
    }

    return DGM_IsSetupActive();
}

static void ApplySetupScramblePolish()
{
    RestoreSetupTimerAfterScramble();
    RespawnSetupScramblePlayers();
    FillSetupMedicUbers();
}

static void RestoreSetupTimerAfterScramble()
{
    int elapsed = GetTime() - g_iRoundStartTimestamp;
    if (elapsed <= 0)
    {
        return;
    }

    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt == -1)
    {
        return;
    }

    SetVariantInt(elapsed);
    AcceptEntityInput(timerEnt, "AddTime");
    g_iRoundStartTimestamp = GetTime();
    LogWhale("Setup scramble polish: restored %d seconds to setup timer.", elapsed);
}

static void RespawnSetupScramblePlayers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU)
        {
            continue;
        }

        if (TF2_GetPlayerClass(i) == TFClass_Unknown)
        {
            TF2_SetPlayerClass(i, TFClass_Scout);
        }

        if (!IsPlayerAlive(i))
        {
            TF2_RespawnPlayer(i);
        }
    }
}

static void FillSetupMedicUbers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || TF2_GetPlayerClass(i) != TFClass_Medic)
        {
            continue;
        }

        int medigun = GetPlayerWeaponSlot(i, 1);
        if (medigun <= MaxClients || !IsValidEntity(medigun) || !HasEntProp(medigun, Prop_Send, "m_flChargeLevel"))
        {
            continue;
        }

        SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", 1.0);
    }
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
            || (forced && (IsEngineerWithBuildings(client) || cls == TFClass_Medic)))
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
    return !forced || (!IsEngineerWithBuildings(client) && cls != TFClass_Medic);
}

static bool IsEngineerWithBuildings(int client)
{
    if (client <= 0 || !IsClientInGame(client) || TF2_GetPlayerClass(client) != TFClass_Engineer)
    {
        return false;
    }

    return ClientOwnsBuilding(client, "obj_sentrygun")
        || ClientOwnsBuilding(client, "obj_dispenser")
        || ClientOwnsBuilding(client, "obj_teleporter");
}

static bool ClientOwnsBuilding(int client, const char[] classname)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (HasEntProp(entity, Prop_Send, "m_hBuilder")
            && GetEntPropEnt(entity, Prop_Send, "m_hBuilder") == client)
        {
            return true;
        }
    }

    return false;
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

static bool ResolveScramblePurchaseImmunity(int &client, int team, int redIds[MAX_SWAP_BUFFER], int bluIds[MAX_SWAP_BUFFER], int swapCount, int pairIndex, bool ignoreImmunity)
{
    if (!HasScramblePurchaseImmunity(client))
    {
        return true;
    }

    int replacement = SelectScrambleReplacementForPass(client, team, redIds, bluIds, swapCount, ignoreImmunity);
    if (replacement <= 0)
    {
        LogWhale("Skipping scramble target %N: paid immunity available and no replacement found.", client);
        return false;
    }

    int usesRemaining = PointsStore_ConsumePurchaseUse(client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
    if (usesRemaining < 0)
    {
        return true;
    }

    CPrintToChat(client, "{magenta}[Store]{default} You were protected by your {gold}Scramble Immunity (8 times){default}! Uses remaining: {lightgreen}%d", usesRemaining);
    LogWhale("Paid scramble immunity protected %N; replacement=%N usesRemaining=%d.", client, replacement, usesRemaining);

    client = replacement;
    if (team == TEAM_RED)
    {
        redIds[pairIndex] = GetClientUserId(replacement);
    }
    else if (team == TEAM_BLU)
    {
        bluIds[pairIndex] = GetClientUserId(replacement);
    }

    return true;
}

static int SelectScrambleReplacementForPass(int protectedClient, int team, int redIds[MAX_SWAP_BUFFER], int bluIds[MAX_SWAP_BUFFER], int swapCount, bool ignoreImmunity)
{
    int candidates[MAXPLAYERS + 1];
    int candidateCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == protectedClient)
        {
            continue;
        }

        if (!IsClientInGame(i))
        {
            continue;
        }

        if (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue))
        {
            continue;
        }

        if (GetClientTeam(i) != team)
        {
            continue;
        }

        if (IsClientSelectedForScramble(i, redIds, bluIds, swapCount))
        {
            continue;
        }

        if (HasScramblePurchaseImmunity(i))
        {
            continue;
        }

        if (!ignoreImmunity && IsScrambleImmune(i))
        {
            continue;
        }

        candidates[candidateCount++] = i;
    }

    if (candidateCount <= 0)
    {
        return 0;
    }

    return candidates[GetRandomInt(0, candidateCount - 1)];
}

static bool IsClientSelectedForScramble(int client, int redIds[MAX_SWAP_BUFFER], int bluIds[MAX_SWAP_BUFFER], int swapCount)
{
    int userId = GetClientUserId(client);
    for (int i = 0; i < swapCount; i++)
    {
        if (redIds[i] == userId || bluIds[i] == userId)
        {
            return true;
        }
    }

    return false;
}

static bool IsScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return false;
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

static bool HasScramblePurchaseImmunity(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_HasPurchase") != FeatureStatus_Available)
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_ConsumePurchaseUse") != FeatureStatus_Available)
    {
        return false;
    }

    return PointsStore_HasPurchase(client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
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
    PluginStats_LogMessage(buffer);
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
