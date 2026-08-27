// Whale scramble vote helper (NativeVotes)
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>

#include <tf2_stocks>

#include <morecolors>
#include <nativevotes>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <clans_api>
#include <filters_api>
#include <points_store_api>
#include <saysounds>
#include <whaletracker_api>
#define REQUIRE_PLUGIN
#include <plugin_statistics>

#include "include/steam_identity.inc"
#include "include/buildings.inc"
#include "include/duel_detection.inc"

native int FilterAlerts_SuppressTeamAlertWindow(float seconds);

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

#define TEAM_MOVE_SAYSOUND "tp-enderman"

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
ConVar g_hWhaleRankBalance = null;
ConVar g_hDisableTfAuto = null;
ConVar g_hShortRoundAutoSeconds = null;
ConVar g_hKothNoCapAuto = null;
ConVar g_hPayloadStompFirstCapSeconds = null;
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
bool g_bPayloadStompCheckedThisRound = false;
int g_iRoundCaptureCount = 0;
int g_iLastFullRoundWinner = 0;
int g_iWinStreak = 0;
bool g_bPendingFullRoundWin = false;
int g_iPendingFullRoundWinningTeam = 0;
bool g_bScrambledThisRound = false;
bool g_bLastRoundHadScramble = false;
int g_iRoundStartTimestamp = 0;
int g_iScrambleRespawnAttempts[MAXPLAYERS + 1];
int g_iScrambleRespawnExpectedTeam[MAXPLAYERS + 1];

#define TEAM_RED  2
#define TEAM_BLU  3
#define MAX_RANDOM_SWAP  5
#define MAX_TOP_SWAP  MAX_RANDOM_SWAP
#define MAX_SWAP_BUFFER  MAX_RANDOM_SWAP
#define MIN_SCRAMBLE_PLAYERS  3
#define SCORE_BALANCE_ENTRY_SUM  0
#define SCORE_BALANCE_ENTRY_CLIENT0  1
#define SCORE_BALANCE_ENTRY_CELLS  (SCORE_BALANCE_ENTRY_CLIENT0 + MAX_SWAP_BUFFER)

enum ScrambleScoreKind
{
    ScrambleScore_Frags = 0,
    ScrambleScore_WhaleRank
};
#define SCRAMBLE_PLAYER_PERCENT_DIVISOR  5
#define SCRAMBLE_RESPAWN_RETRY_DELAY  0.50
#define SCRAMBLE_RESPAWN_RETRY_COUNT  8
#define SCRAMBLE_SETUP_POLISH_DELAY  0.75
#define SCRAMBLE_SETUP_UBER_DELAY  0.25
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_DELAY  0.85
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_REPEAT_DELAY  1.10
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_COUNT  3
#define POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM "scramImmunity24h"
#define WHALESCRAMBLE_STATS_DETAIL_MAX 384
public Plugin myinfo =
{
    name = "whalescramble",
    author = "Hombre, AW 'Swixel' Stanley",
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
    MarkNativeAsOptional("DGM_GetRecentControlPointCaptureIntervalSeconds");
    MarkNativeAsOptional("DGM_IsSetupActive");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("WhaleTracker_AreStatsLoaded");
    MarkNativeAsOptional("WhaleTracker_GetWhalePoints");
    return APLRes_Success;
}

public void OnPluginStart()
{
    UpdateNativeVotes();
    DuelDetection_Initialize();
    g_hLogEnabled = CreateConVar("sm_whalescramble_log", "1", "Enable whalescramble debug logging.", _, true, 0.0, true, 1.0);
    LogWhale("Plugin started.");
    g_hAutoRounds = CreateConVar("whalescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("whalescramble_votetime", "4", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hCountBots = CreateConVar("whalescramble_count_bots", "1", "Include bots when selecting whale scramble targets.", _, true, 0.0, true, 1.0);
    g_hTopSwap = CreateConVar("sm_ws_topswap", "0", "Enable topswap scramble mode.", _, true, 0.0, true, 1.0);
    g_hRandom = CreateConVar("sm_ws_random", "1", "Enable random scramble mode.", _, true, 0.0, true, 1.0);
    g_hFragBalance = CreateConVar("sm_ws_frags", "1", "Enable frag-balanced random scramble mode.", _, true, 0.0, true, 1.0);
    g_hWhaleRankBalance = CreateConVar("sm_ws_whaletracker_ranks", "0", "Enable WhaleTracker rank-balanced scramble mode.", _, true, 0.0, true, 1.0);
    g_hDisableTfAuto = CreateConVar("sm_whalescramble_disable_tf_auto", "1", "Disable TF2's built-in mp_scrambleteams_auto while WhaleScramble owns auto scrambles.", _, true, 0.0, true, 1.0);
    g_hShortRoundAutoSeconds = CreateConVar("sm_whalescramble_short_round_seconds", "60", "Automatically whale scramble when the previous round duration is under this many seconds. 0 disables.", _, true, 0.0, true, 600.0);
    g_hKothNoCapAuto = CreateConVar("sm_whalescramble_koth_no_cap", "1", "Automatically whale scramble when a full KOTH round ends with either team never capturing the point.", _, true, 0.0, true, 1.0);
    g_hPayloadStompFirstCapSeconds = CreateConVar("sm_whalescramble_payload_stomp_first_cap_seconds", "100", "Immediately whale scramble when BLU captures the first payload control point within this many seconds. 0 disables.", _, true, 0.0, true, 600.0);
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
    RegAdminCmd("sm_whalebalance", Command_WhaleBalance, ADMFLAG_GENERIC, "Balance by WhaleTracker rank; optionally favor red/blu 60:40.");
    RegAdminCmd("sm_whalescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");
    RegAdminCmd("sm_forcescramblevote", Command_ForceScrambleVote, ADMFLAG_GENERIC, "Force a whale scramble vote.");

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
    // This handler reads "full_round" and "team", so it needs a copied event.
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_Post);
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
    ResetVotes();
    ClearScrambleRespawnAttempts();
    ClearScrambleCooldown();
    ClearAutoScramblePending();
    ApplyEngineScramblePolicy();
    g_iRoundsSinceAuto = 0;
    ResetWinStreakTracking();
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
    ResetWinStreakTracking();
    LogWhale("Map end: votes reset.");
}

public void OnPluginEnd()
{
    ResetVotes();
    ClearScrambleCooldown();
    ClearAutoScramblePending();
    DuelDetection_Shutdown();
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
    ClearScrambleRespawnState(client);
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

public Action Command_WhaleBalance(int client, int args)
{
    int favoredTeam = 0;
    if (args > 0)
    {
        char teamArg[16];
        GetCmdArg(1, teamArg, sizeof(teamArg));
        if (StrEqual(teamArg, "red", false))
        {
            favoredTeam = TEAM_RED;
        }
        else if (StrEqual(teamArg, "blu", false) || StrEqual(teamArg, "blue", false))
        {
            favoredTeam = TEAM_BLU;
        }
        else
        {
            ReplyToCommand(client, "[whalescramble] Usage: sm_whalebalance [red|blu|blue]");
            return Plugin_Handled;
        }
    }

    if (client > 0)
    {
        LogWhale("Admin WhaleTracker rank balance requested by %N (%d), favoredTeam=%d.", client, GetClientUserId(client), favoredTeam);
    }
    else
    {
        LogWhale("WhaleTracker rank balance requested by server console, favoredTeam=%d.", favoredTeam);
    }
    StartWhaleRankBalanceScramble(client, true, true, true, favoredTeam);
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
    LogWhaleStat("round_context", "full_round=%d|winning_team=%d|vote_running=%d|active_kind=%d|active_team=%d",
        fullRound ? 1 : 0,
        event.GetInt("team"),
        g_bVoteRunning ? 1 : 0,
        g_eActiveVoteKind,
        g_iActiveSurrenderTeam);
    ResetSurrenderVotes("round_win");

    if (fullRound)
    {
        CreateTimer(0.1, Timer_CheckShortRoundAutoScramble, _, TIMER_FLAG_NO_MAPCHANGE);
        CheckKothNoCapAutoScramble();
        QueueFullRoundWinForWinStreak(event.GetInt("team"));
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
        LogWhaleStat("auto_scramble_decision", "trigger=short_round|result=skipped|reason=native_unavailable|threshold=%d", threshold);
        return Plugin_Stop;
    }

    int duration = DGM_GetLastRoundDurationSeconds();
    if (duration <= 0 || duration >= threshold)
    {
        LogWhale("Short-round auto scramble skipped: duration=%d threshold=%d.", duration, threshold);
        LogWhaleStat("auto_scramble_decision", "trigger=short_round|result=skipped|reason=duration|duration=%d|threshold=%d", duration, threshold);
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
    g_bPayloadStompCheckedThisRound = false;
    g_iRoundCaptureCount = 0;
    g_bScrambledThisRound = false;
    g_iRoundStartTimestamp = GetTime();

    CheckPendingFullRoundWinAutoScramble();

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
        LogWhaleStat("auto_scramble_decision", "trigger=pending_round_start|result=failed|reason=start_failed");
    }
}

public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    int team = event.GetInt("team");
    g_iRoundCaptureCount++;

    if (team == TEAM_RED)
    {
        g_bKothRedCapped = true;
    }
    else if (team == TEAM_BLU)
    {
        g_bKothBluCapped = true;
    }

    if (team == TEAM_BLU && g_iRoundCaptureCount == 1 && !g_bPayloadStompCheckedThisRound)
    {
        g_bPayloadStompCheckedThisRound = true;
        CreateTimer(0.1, Timer_CheckPayloadStompFirstCapture, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_CheckPayloadStompFirstCapture(Handle timer)
{
    if (g_hPayloadStompFirstCapSeconds == null)
    {
        return Plugin_Stop;
    }

    int threshold = g_hPayloadStompFirstCapSeconds.IntValue;
    if (threshold <= 0)
    {
        return Plugin_Stop;
    }

    if (!IsCurrentPayloadGamemode())
    {
        LogWhaleStat("auto_scramble_decision", "trigger=payload_first_cap|result=skipped|reason=gamemode|threshold=%d", threshold);
        return Plugin_Stop;
    }

    if (GetFeatureStatus(FeatureType_Native, "DGM_GetRecentControlPointCaptureIntervalSeconds") != FeatureStatus_Available)
    {
        LogWhale("Payload first-cap auto scramble skipped: DGM_GetRecentControlPointCaptureIntervalSeconds unavailable.");
        LogWhaleStat("auto_scramble_decision", "trigger=payload_first_cap|result=skipped|reason=native_unavailable|threshold=%d", threshold);
        return Plugin_Stop;
    }

    int interval = DGM_GetRecentControlPointCaptureIntervalSeconds();
    if (interval <= 0 || interval > threshold)
    {
        LogWhale("Payload first-cap auto scramble skipped: interval=%d threshold=%d.", interval, threshold);
        LogWhaleStat("auto_scramble_decision", "trigger=payload_first_cap|result=skipped|reason=interval|interval=%d|threshold=%d", interval, threshold);
        return Plugin_Stop;
    }

    if (StartAutoScramble(true))
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Payload stomp detected: first point captured in {lightgreen}%d{default} seconds, scrambling!", interval);
        LogWhale("Payload first-cap auto scramble triggered: interval=%d threshold=%d.", interval, threshold);
        LogWhaleStat("auto_scramble_decision", "trigger=payload_first_cap|result=triggered|interval=%d|threshold=%d", interval, threshold);
    }
    else
    {
        LogWhale("Payload first-cap auto scramble failed to start: interval=%d threshold=%d.", interval, threshold);
        LogWhaleStat("auto_scramble_decision", "trigger=payload_first_cap|result=failed|interval=%d|threshold=%d", interval, threshold);
    }

    return Plugin_Stop;
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

static bool IsCurrentPayloadGamemode()
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

    return StrEqual(gamemodeKey, "pl", false);
}

static void ClearPendingFullRoundWin()
{
    g_bPendingFullRoundWin = false;
    g_iPendingFullRoundWinningTeam = 0;
}

static void ResetWinStreakTracking()
{
    g_iLastFullRoundWinner = 0;
    g_iWinStreak = 0;
    ClearPendingFullRoundWin();
}

static void QueueFullRoundWinForWinStreak(int winningTeam)
{
    if (g_bPendingFullRoundWin)
    {
        LogWhale(
            "Full-round win already queued for win-streak; replacing queuedTeam=%d with team=%d.",
            g_iPendingFullRoundWinningTeam,
            winningTeam);
    }

    g_bPendingFullRoundWin = true;
    g_iPendingFullRoundWinningTeam = winningTeam;
}

static void CheckPendingFullRoundWinAutoScramble()
{
    if (!g_bPendingFullRoundWin)
    {
        return;
    }

    int winningTeam = g_iPendingFullRoundWinningTeam;
    ClearPendingFullRoundWin();
    LogWhale("Processing queued full-round win for win-streak: team=%d.", winningTeam);
    CheckWinStreakAutoScramble(winningTeam);
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
    ClearPendingFullRoundWin();
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
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=not_enough_players|total=%d|min=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d", modeName, totalPlayers, MIN_SCRAMBLE_PLAYERS, redCount, bluCount, redEligible, bluEligible);
        return;
    }

    if (redCount <= 0 || bluCount <= 0)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least 1 player (RED=%d BLU=%d).", redCount, bluCount);
        LogWhale("%s scramble aborted: one team empty (red=%d blu=%d).", modeName, redCount, bluCount);
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=empty_team|total=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d", modeName, totalPlayers, redCount, bluCount, redEligible, bluEligible);
        return;
    }

    NotifyFailure(issuer, broadcastFailures, "Not enough eligible players to swap (RED=%d BLU=%d).", redEligible, bluEligible);
    LogWhale("%s scramble aborted: not enough eligible players (red=%d blu=%d).", modeName, redEligible, bluEligible);
    LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=not_enough_eligible|total=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d", modeName, totalPlayers, redCount, bluCount, redEligible, bluEligible);
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
        LogWhaleStat("vote_request", "kind=surrender|result=rejected|reason=invalid_team|team=%d", GetClientTeam(client));
        return;
    }

    char actionName[16];
    GetVoteActionName(kind, actionName, sizeof(actionName));

    if (scrambleCooldown)
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} %s is on cooldown.", actionName);
        LogWhale("Vote request rejected: %s cooldown active (client %N).", actionName, client);
        LogWhaleStat("vote_request", "kind=%s|result=rejected|reason=cooldown", actionName);
        return;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        LogWhale("Vote request rejected: vote already running (client %N kind=%s).", client, actionName);
        LogWhaleStat("vote_request", "kind=%s|result=rejected|reason=vote_running", actionName);
        return;
    }

    if (HasPlayerRequestedVote(client, kind))
    {
        CPrintToChat(client, "{blue}[WhaleScramble]{default} You already requested a %s vote.", actionName);
        LogWhale("Vote request rejected: already requested (client %N kind=%s).", client, actionName);
        LogWhaleStat("vote_request", "kind=%s|result=rejected|reason=already_requested", actionName);
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
    LogWhaleStat("vote_request", "kind=%s|result=counted|count=%d|threshold=4|team=%d", actionName, requestCount, GetClientTeam(client));

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
            LogWhaleStat("vote_result", "kind=surrender|phase=start|result=failed|reason=invalid_team|team=%d", (client > 0 && IsClientInGame(client)) ? GetClientTeam(client) : 0);
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
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=cooldown", actionName);
        return false;
    }

    if (!g_bNativeVotes)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} NativeVotes is unavailable.");
        }
        LogWhale("Vote start failed: NativeVotes unavailable.");
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=nativevotes_unavailable", actionName);
        return false;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is already running.");
        }
        LogWhale("Vote start failed: vote already running.");
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=vote_running", actionName);
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
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=vote_delay|delay=%d", actionName, delay);
        return false;
    }

    if (!NativeVotes_IsNewVoteAllowed())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} A vote is not allowed right now.");
        }
        LogWhale("Vote start failed: new vote not allowed.");
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=new_vote_not_allowed", actionName);
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
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=display_failed", actionName);
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
    LogWhaleStat("vote_result", "kind=%s|phase=start|result=started|duration=%d|allow_low_pop=%d|active_team=%d", actionName, voteTime, allowLowPop ? 1 : 0, g_iActiveSurrenderTeam);
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
        LogWhaleStat("auto_scramble_decision", "trigger=auto|result=blocked|reason=cooldown");
        return false;
    }

    if (!suppressFeedback)
    {
        CPrintToChatAll("{blue}[WhaleScramble]{default} Auto scramble triggered.");
    }

    LogWhale("Auto scramble triggered.");
    LogWhaleStat("auto_scramble_decision", "trigger=auto|result=triggered");
    return StartConfiguredWhaleScramble(0, !suppressFeedback, false, false);
}

static bool StartConfiguredWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced)
{
    if (g_hTopSwap != null && g_hTopSwap.BoolValue)
    {
        LogWhale("Configured scramble mode: topswap forced=%d.", forced ? 1 : 0);
        return StartWhaleScramble(issuer, broadcastFailures, allowLowPop, forced);
    }
    else if (g_hWhaleRankBalance != null && g_hWhaleRankBalance.BoolValue)
    {
        LogWhale("Configured scramble mode: WhaleTracker ranks forced=%d.", forced ? 1 : 0);
        return StartWhaleRankBalanceScramble(issuer, broadcastFailures, allowLowPop, forced, 0);
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
    LogWhaleStat("scramble_result", "mode=configured|result=aborted|reason=no_enabled_modes|forced=%d", forced ? 1 : 0);
    return false;
}

public int ScrambleVoteHandler(NativeVote vote, MenuAction action, int param1, int param2)
{
    WhaleVoteKind voteKind = g_eActiveVoteKind;
    char voteKindName[16];
    GetVoteKindName(voteKind, voteKindName, sizeof(voteKindName));
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
            LogWhaleStat("vote_result", "kind=%s|phase=end|result=cancelled|reason=%d", voteKindName, param1);
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
                LogWhaleStat("vote_result", "kind=none|phase=end|result=failed|reason=missing_kind");
                return 0;
            }

            int votes = 0;
            int totalVotes = 0;
            NativeVotes_GetInfo(param2, votes, totalVotes);

            if (totalVotes <= 0)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
                LogWhale("Vote failed: no votes.");
                LogWhaleStat("vote_result", "kind=%s|phase=end|result=failed|reason=no_votes", voteKindName);
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
                LogWhaleStat("vote_result", "kind=%s|phase=end|result=failed|reason=lost|yes=%d|total=%d|yes_percent=%.1f", voteKindName, yesVotes, totalVotes, yesPercent * 100.0);
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
                        LogWhaleStat("vote_result", "kind=surrender|phase=end|result=failed|reason=invalid_active_team|active_team=%d", g_iActiveSurrenderTeam);
                        return 0;
                    }
                    LogWhale("Surrender vote passed: issuing mp_scrambleteams surrenderTeam=%d winningTeam=%d yes=%d total=%d.",
                        g_iActiveSurrenderTeam,
                        winningTeamNum,
                        yesVotes,
                        totalVotes);
                    StartScrambleCooldown();
                    ServerCommand("mp_scrambleteams");
                    SaySounds_TryPlayCommand(0, TEAM_MOVE_SAYSOUND, true);
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
                        LogWhaleStat("vote_result", "kind=surrender|phase=end|result=passed|success=1|yes=%d|total=%d|yes_percent=%.1f|surrender_team=%d|winning_team=%d", yesVotes, totalVotes, yesPercent * 100.0, g_iActiveSurrenderTeam, GetOpposingTeam(g_iActiveSurrenderTeam));
                        LogSurrenderState("vote_pass");
                    }
                    else
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Whale scrambling teams...");
                        LogWhale("Vote passed: yes=%d total=%d (%.1f%%).", yesVotes, totalVotes, yesPercent * 100.0);
                        LogWhaleStat("vote_result", "kind=scramble|phase=end|result=passed|success=1|yes=%d|total=%d|yes_percent=%.1f", yesVotes, totalVotes, yesPercent * 100.0);
                    }
                }
                else
                {
                    if (voteKind == WhaleVote_Surrender)
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Unable to surrender right now.");
                        LogWhale("Surrender vote passed but command could not be issued.");
                        LogWhaleStat("vote_result", "kind=surrender|phase=end|result=passed|success=0|reason=command_failed|yes=%d|total=%d|yes_percent=%.1f", yesVotes, totalVotes, yesPercent * 100.0);
                    }
                    else
                    {
                        NativeVotes_DisplayPassCustom(vote, "Vote passed. Scramble conditions not met.");
                        LogWhale("Vote passed but scramble conditions not met.");
                        LogWhaleStat("vote_result", "kind=scramble|phase=end|result=passed|success=0|reason=scramble_conditions|yes=%d|total=%d|yes_percent=%.1f", yesVotes, totalVotes, yesPercent * 100.0);
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
        LogWhaleStat("auto_scramble_decision", "trigger=%s|result=blocked|reason=already_pending", reason);
        return false;
    }

    if (g_hNoSequentialAuto != null && g_hNoSequentialAuto.BoolValue)
    {
        if (g_bScrambledThisRound)
        {
            LogWhale("Auto scramble blocked by no-sequential guard: already scrambled this round; reason=%s.", reason);
            LogWhaleStat("auto_scramble_decision", "trigger=%s|result=blocked|reason=scrambled_this_round", reason);
            return false;
        }

        if (g_bLastRoundHadScramble)
        {
            LogWhale("Auto scramble blocked by no-sequential guard: previous round scrambled; reason=%s.", reason);
            LogWhaleStat("auto_scramble_decision", "trigger=%s|result=blocked|reason=previous_round_scrambled", reason);
            return false;
        }
    }

    LogWhale("Auto scramble arming accepted: reason=%s.", reason);
    LogWhaleStat("auto_scramble_decision", "trigger=%s|result=armed", reason);
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
        LogWhaleStat("auto_scramble_decision", "trigger=pending_round_start|result=expired");
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
        if (DuelDetection_IsClientInDuel(i)) continue;

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
            if (DuelDetection_IsClientInDuel(i)) continue;

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

    LogWhaleStat("scramble_attempt", "mode=topswap|issuer=%d|allow_low_pop=%d|forced=%d|total=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d|desired_swap=%d|swap=%d|ignore_immunity=%d|fallback=%d",
        issuer,
        allowLowPop ? 1 : 0,
        forced ? 1 : 0,
        totalPlayers,
        redCount,
        bluCount,
        redEligible,
        bluEligible,
        desiredSwapCount,
        swapCount,
        ignoreImmunity ? 1 : 0,
        needsFallback ? 1 : 0);

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, "Topswap");
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        LogWhaleStat("scramble_result", "mode=topswap|result=aborted|reason=team_size|swap=%d|red=%d|blu=%d", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        LogWhaleStat("scramble_result", "mode=topswap|result=aborted|reason=eligible_size|swap=%d|eligible_red=%d|eligible_blu=%d", swapCount, redEligible, bluEligible);
        return false;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    pack.WriteString("topswap");
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
        if (DuelDetection_IsClientInDuel(i)) continue;

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
            if (DuelDetection_IsClientInDuel(i)) continue;

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

    LogWhaleStat("scramble_attempt", "mode=random|issuer=%d|allow_low_pop=%d|forced=%d|total=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d|candidate_red=%d|candidate_blu=%d|desired_swap=%d|swap=%d|ignore_immunity=%d|fallback=%d",
        issuer,
        allowLowPop ? 1 : 0,
        forced ? 1 : 0,
        totalPlayers,
        redCount,
        bluCount,
        redEligible,
        bluEligible,
        redCandidateCount,
        bluCandidateCount,
        desiredSwapCount,
        swapCount,
        ignoreImmunity ? 1 : 0,
        needsFallback ? 1 : 0);

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, "Random");
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("Random scramble aborted: team size too small (swap=%d red=%d blu=%d).", swapCount, redCount, bluCount);
        LogWhaleStat("scramble_result", "mode=random|result=aborted|reason=team_size|swap=%d|red=%d|blu=%d", swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("Random scramble aborted: eligible too small (swap=%d red=%d blu=%d).", swapCount, redEligible, bluEligible);
        LogWhaleStat("scramble_result", "mode=random|result=aborted|reason=eligible_size|swap=%d|eligible_red=%d|eligible_blu=%d", swapCount, redEligible, bluEligible);
        return false;
    }

    if (!SelectRandomPlayers(redCandidates, redCandidateCount, topRed, swapCount)
        || !SelectRandomPlayers(bluCandidates, bluCandidateCount, topBlu, swapCount))
    {
        NotifyFailure(issuer, broadcastFailures, "Failed to select random swap targets.");
        LogWhale("Random scramble aborted: random selection failed (swap=%d redCandidates=%d bluCandidates=%d).", swapCount, redCandidateCount, bluCandidateCount);
        LogWhaleStat("scramble_result", "mode=random|result=aborted|reason=selection_failed|swap=%d|candidate_red=%d|candidate_blu=%d", swapCount, redCandidateCount, bluCandidateCount);
        return false;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    pack.WriteString("random");
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
    return StartScoreBalanceWhaleScramble(issuer, broadcastFailures, allowLowPop, forced, ScrambleScore_Frags, 0);
}

static bool StartWhaleRankBalanceScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced, int favoredTeam)
{
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_AreStatsLoaded") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetWhalePoints") != FeatureStatus_Available)
    {
        NotifyFailure(issuer, broadcastFailures, "WhaleTracker rank data is unavailable.");
        LogWhaleStat("scramble_result", "mode=whaletracker_rank|result=aborted|reason=native_unavailable");
        return false;
    }

    return StartScoreBalanceWhaleScramble(issuer, broadcastFailures, allowLowPop, forced, ScrambleScore_WhaleRank, favoredTeam);
}

static int GetScrambleBalanceScore(int client, ScrambleScoreKind scoreKind)
{
    if (scoreKind == ScrambleScore_Frags)
    {
        return GetClientFrags(client);
    }

    if (IsFakeClient(client) || !WhaleTracker_AreStatsLoaded(client))
    {
        return 0;
    }

    return WhaleTracker_GetWhalePoints(client);
}

static bool StartScoreBalanceWhaleScramble(int issuer, bool broadcastFailures, bool allowLowPop, bool forced, ScrambleScoreKind scoreKind, int favoredTeam)
{
    char modeKey[32];
    char modeLabel[32];
    if (scoreKind == ScrambleScore_WhaleRank)
    {
        strcopy(modeKey, sizeof(modeKey), "whaletracker_rank");
        strcopy(modeLabel, sizeof(modeLabel), "WhaleTracker rank");
    }
    else
    {
        strcopy(modeKey, sizeof(modeKey), "frag_balance");
        strcopy(modeLabel, sizeof(modeLabel), "Frag balance");
    }

    LogWhale("StartScoreBalanceWhaleScramble: mode=%s issuer=%d allowLowPop=%d forced=%d favoredTeam=%d.", modeKey, issuer, allowLowPop ? 1 : 0, forced ? 1 : 0, favoredTeam);
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
    int clientScores[MAXPLAYERS + 1];
    int redScoreTotal = 0;
    int bluScoreTotal = 0;
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
            "%s scramble: ignoring immunity due to %s total=%d threshold=%d.",
            modeLabel,
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
        if (DuelDetection_IsClientInDuel(i))
            continue;

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU)
            continue;

        int score = GetScrambleBalanceScore(i, scoreKind);
        clientScores[i] = score;
        if (team == TEAM_RED)
        {
            redScoreTotal += score;
        }
        else
        {
            bluScoreTotal += score;
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
        "%s counts: total=%d red=%d blu=%d eligibleRed=%d eligibleBlu=%d desiredSwap=%d swap=%d redScore=%d bluScore=%d.",
        modeLabel,
        totalPlayers,
        redCount,
        bluCount,
        redEligible,
        bluEligible,
        desiredSwapCount,
        swapCount,
        redScoreTotal,
        bluScoreTotal);

    bool needsFallback = (desiredSwapCount > 0 && swapCount < desiredSwapCount);
    if (needsFallback)
    {
        LogWhale("%s eligibility low; recalculating without class filters.", modeLabel);
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
            if (DuelDetection_IsClientInDuel(i))
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

    LogWhaleStat("scramble_attempt", "mode=%s|issuer=%d|allow_low_pop=%d|forced=%d|total=%d|red=%d|blu=%d|eligible_red=%d|eligible_blu=%d|candidate_red=%d|candidate_blu=%d|desired_swap=%d|swap=%d|ignore_immunity=%d|fallback=%d|red_score=%d|blu_score=%d|favored_team=%d",
        modeKey,
        issuer,
        allowLowPop ? 1 : 0,
        forced ? 1 : 0,
        totalPlayers,
        redCount,
        bluCount,
        redEligible,
        bluEligible,
        redCandidateCount,
        bluCandidateCount,
        desiredSwapCount,
        swapCount,
        ignoreImmunity ? 1 : 0,
        needsFallback ? 1 : 0,
        redScoreTotal,
        bluScoreTotal,
        favoredTeam);

    if (swapCount == 0)
    {
        NotifySwapCountFailure(issuer, broadcastFailures, totalPlayers, redCount, bluCount, redEligible, bluEligible, modeLabel);
        return false;
    }

    if (redCount < swapCount || bluCount < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d players (RED=%d BLU=%d).", swapCount, redCount, bluCount);
        LogWhale("%s scramble aborted: team size too small (swap=%d red=%d blu=%d).", modeLabel, swapCount, redCount, bluCount);
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=team_size|swap=%d|red=%d|blu=%d", modeKey, swapCount, redCount, bluCount);
        return false;
    }

    if (redEligible < swapCount || bluEligible < swapCount)
    {
        NotifyFailure(issuer, broadcastFailures, "Each team needs at least %d eligible players (RED=%d BLU=%d).", swapCount, redEligible, bluEligible);
        LogWhale("%s scramble aborted: eligible too small (swap=%d red=%d blu=%d).", modeLabel, swapCount, redEligible, bluEligible);
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=eligible_size|swap=%d|eligible_red=%d|eligible_blu=%d", modeKey, swapCount, redEligible, bluEligible);
        return false;
    }

    if (!SelectScoreBalancePlayers(redCandidates, bluCandidates, clientScores, redCandidateCount, bluCandidateCount, redScoreTotal, bluScoreTotal, topRed, topBlu, swapCount, favoredTeam))
    {
        NotifyFailure(issuer, broadcastFailures, "Failed to select %s swap targets.", modeLabel);
        LogWhale("%s scramble aborted: selection failed (swap=%d redCandidates=%d bluCandidates=%d redScore=%d bluScore=%d).", modeLabel, swapCount, redCandidateCount, bluCandidateCount, redScoreTotal, bluScoreTotal);
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=selection_failed|swap=%d|candidate_red=%d|candidate_blu=%d|red_score=%d|blu_score=%d", modeKey, swapCount, redCandidateCount, bluCandidateCount, redScoreTotal, bluScoreTotal);
        return false;
    }

    int selectedRedScore = 0;
    int selectedBluScore = 0;
    for (int i = 0; i < swapCount; i++)
    {
        selectedRedScore += clientScores[topRed[i]];
        selectedBluScore += clientScores[topBlu[i]];
    }

    int finalRedScore = redScoreTotal - selectedRedScore + selectedBluScore;
    int finalBluScore = bluScoreTotal - selectedBluScore + selectedRedScore;
    int beforeDiff = GetScoreBalanceDifference(redScoreTotal, bluScoreTotal, favoredTeam);
    int afterDiff = GetScoreBalanceDifference(finalRedScore, finalBluScore, favoredTeam);
    LogWhale(
        "%s selected: swap=%d redScore=%d bluScore=%d selectedRedScore=%d selectedBluScore=%d beforeDiff=%d afterDiff=%d.",
        modeLabel,
        swapCount,
        redScoreTotal,
        bluScoreTotal,
        selectedRedScore,
        selectedBluScore,
        beforeDiff,
        afterDiff);
    LogWhaleStat("scramble_result", "mode=%s|result=selected|swap=%d|red_score=%d|blu_score=%d|selected_red_score=%d|selected_blu_score=%d|before_diff=%d|after_diff=%d|favored_team=%d",
        modeKey,
        swapCount,
        redScoreTotal,
        bluScoreTotal,
        selectedRedScore,
        selectedBluScore,
        beforeDiff,
        afterDiff,
        favoredTeam);

    DataPack pack = new DataPack();
    pack.WriteCell(issuer > 0 ? GetClientUserId(issuer) : 0);
    pack.WriteCell(swapCount);
    pack.WriteCell(ignoreImmunity ? 1 : 0);
    pack.WriteString(modeKey);
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
        LogWhale("%s scramble executing immediately: swapCount=%d.", modeLabel, swapCount);
        Timer_DoSwap(null, pack);
    }
    else
    {
        CreateTimer(0.1, Timer_DoSwap, pack, TIMER_FLAG_NO_MAPCHANGE);
        LogWhale("%s scramble scheduled: swapCount=%d.", modeLabel, swapCount);
    }

    return true;
}

static bool SelectScoreBalancePlayers(
    int redCandidates[MAXPLAYERS + 1],
    int bluCandidates[MAXPLAYERS + 1],
    int clientScores[MAXPLAYERS + 1],
    int redCandidateCount,
    int bluCandidateCount,
    int redScoreTotal,
    int bluScoreTotal,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int selectedCount,
    int favoredTeam)
{
    if (selectedCount <= 0 || selectedCount > MAX_SWAP_BUFFER || redCandidateCount < selectedCount || bluCandidateCount < selectedCount)
    {
        return false;
    }

    ArrayList bluSubsets = new ArrayList(SCORE_BALANCE_ENTRY_CELLS);
    int chosenBlu[MAX_SWAP_BUFFER];
    AddScoreBalanceSubsetsRecursive(bluCandidates, clientScores, bluCandidateCount, selectedCount, 0, 0, 0, chosenBlu, bluSubsets);
    if (bluSubsets.Length <= 0)
    {
        delete bluSubsets;
        return false;
    }

    bluSubsets.SortCustom(SortScoreBalanceSubsetBySum);

    int chosenRed[MAX_SWAP_BUFFER];
    int bestFinalDiff = 0;
    bool found = false;
    int redMultiplier;
    int bluMultiplier;
    GetScoreBalanceMultipliers(favoredTeam, redMultiplier, bluMultiplier);
    int swapMultiplier = redMultiplier + bluMultiplier;
    EvaluateScoreBalanceRedSubsetsRecursive(
        redCandidates,
        clientScores,
        redCandidateCount,
        selectedCount,
        0,
        0,
        0,
        chosenRed,
        bluSubsets,
        (redMultiplier * redScoreTotal) - (bluMultiplier * bluScoreTotal),
        swapMultiplier,
        selectedRed,
        selectedBlu,
        bestFinalDiff,
        found);

    delete bluSubsets;
    return found;
}

static void AddScoreBalanceSubsetsRecursive(
    int candidates[MAXPLAYERS + 1],
    int clientScores[MAXPLAYERS + 1],
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
        int entry[SCORE_BALANCE_ENTRY_CELLS];
        entry[SCORE_BALANCE_ENTRY_SUM] = currentSum;
        for (int i = 0; i < MAX_SWAP_BUFFER; i++)
        {
            entry[SCORE_BALANCE_ENTRY_CLIENT0 + i] = (i < selectedCount) ? chosen[i] : 0;
        }
        subsets.PushArray(entry, sizeof(entry));
        return;
    }

    int remainingNeeded = selectedCount - chosenCount;
    for (int i = start; i <= candidateCount - remainingNeeded; i++)
    {
        int client = candidates[i];
        chosen[chosenCount] = client;
        AddScoreBalanceSubsetsRecursive(candidates, clientScores, candidateCount, selectedCount, i + 1, chosenCount + 1, currentSum + clientScores[client], chosen, subsets);
    }
}

static void EvaluateScoreBalanceRedSubsetsRecursive(
    int redCandidates[MAXPLAYERS + 1],
    int clientScores[MAXPLAYERS + 1],
    int redCandidateCount,
    int selectedCount,
    int start,
    int chosenCount,
    int currentRedScore,
    int chosenRed[MAX_SWAP_BUFFER],
    ArrayList bluSubsets,
    int teamScoreDelta,
    int swapMultiplier,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int &bestFinalDiff,
    bool &found)
{
    if (chosenCount == selectedCount)
    {
        int targetScaled = (swapMultiplier * currentRedScore) - teamScoreDelta;
        int index = FindFirstScoreBalanceSubsetAtLeastScaled(bluSubsets, targetScaled, swapMultiplier);
        TryScoreBalanceCandidate(bluSubsets, index, selectedCount, currentRedScore, chosenRed, teamScoreDelta, swapMultiplier, selectedRed, selectedBlu, bestFinalDiff, found);
        TryScoreBalanceCandidate(bluSubsets, index - 1, selectedCount, currentRedScore, chosenRed, teamScoreDelta, swapMultiplier, selectedRed, selectedBlu, bestFinalDiff, found);
        return;
    }

    int remainingNeeded = selectedCount - chosenCount;
    for (int i = start; i <= redCandidateCount - remainingNeeded; i++)
    {
        int client = redCandidates[i];
        chosenRed[chosenCount] = client;
        EvaluateScoreBalanceRedSubsetsRecursive(
            redCandidates,
            clientScores,
            redCandidateCount,
            selectedCount,
            i + 1,
            chosenCount + 1,
            currentRedScore + clientScores[client],
            chosenRed,
            bluSubsets,
            teamScoreDelta,
            swapMultiplier,
            selectedRed,
            selectedBlu,
            bestFinalDiff,
            found);
    }
}

static void TryScoreBalanceCandidate(
    ArrayList bluSubsets,
    int index,
    int selectedCount,
    int currentRedScore,
    int chosenRed[MAX_SWAP_BUFFER],
    int teamScoreDelta,
    int swapMultiplier,
    int selectedRed[MAX_SWAP_BUFFER],
    int selectedBlu[MAX_SWAP_BUFFER],
    int &bestFinalDiff,
    bool &found)
{
    if (index < 0 || index >= bluSubsets.Length)
    {
        return;
    }

    int entry[SCORE_BALANCE_ENTRY_CELLS];
    bluSubsets.GetArray(index, entry, sizeof(entry));

    int finalDiff = ScoreBalanceAbs(teamScoreDelta - (swapMultiplier * currentRedScore) + (swapMultiplier * entry[SCORE_BALANCE_ENTRY_SUM]));
    if (found && finalDiff >= bestFinalDiff)
    {
        return;
    }

    for (int i = 0; i < MAX_SWAP_BUFFER; i++)
    {
        selectedRed[i] = (i < selectedCount) ? chosenRed[i] : 0;
        selectedBlu[i] = (i < selectedCount) ? entry[SCORE_BALANCE_ENTRY_CLIENT0 + i] : 0;
    }

    bestFinalDiff = finalDiff;
    found = true;
}

static int FindFirstScoreBalanceSubsetAtLeastScaled(ArrayList subsets, int targetScaled, int multiplier)
{
    int low = 0;
    int high = subsets.Length;
    int entry[SCORE_BALANCE_ENTRY_CELLS];

    while (low < high)
    {
        int mid = (low + high) / 2;
        subsets.GetArray(mid, entry, sizeof(entry));
        if ((multiplier * entry[SCORE_BALANCE_ENTRY_SUM]) < targetScaled)
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

static int SortScoreBalanceSubsetBySum(int index1, int index2, Handle array, Handle hndl)
{
    ArrayList subsets = view_as<ArrayList>(array);
    int entry1[SCORE_BALANCE_ENTRY_CELLS];
    int entry2[SCORE_BALANCE_ENTRY_CELLS];
    subsets.GetArray(index1, entry1, sizeof(entry1));
    subsets.GetArray(index2, entry2, sizeof(entry2));

    if (entry1[SCORE_BALANCE_ENTRY_SUM] < entry2[SCORE_BALANCE_ENTRY_SUM])
    {
        return -1;
    }
    if (entry1[SCORE_BALANCE_ENTRY_SUM] > entry2[SCORE_BALANCE_ENTRY_SUM])
    {
        return 1;
    }
    return 0;
}

static int ScoreBalanceAbs(int value)
{
    return value < 0 ? -value : value;
}

static void GetScoreBalanceMultipliers(int favoredTeam, int &redMultiplier, int &bluMultiplier)
{
    // A 60:40 target is equivalent to 2 * favored score == 3 * other score.
    redMultiplier = 1;
    bluMultiplier = 1;
    if (favoredTeam == TEAM_RED)
    {
        redMultiplier = 2;
        bluMultiplier = 3;
    }
    else if (favoredTeam == TEAM_BLU)
    {
        redMultiplier = 3;
        bluMultiplier = 2;
    }
}

static int GetScoreBalanceDifference(int redScore, int bluScore, int favoredTeam)
{
    int redMultiplier;
    int bluMultiplier;
    GetScoreBalanceMultipliers(favoredTeam, redMultiplier, bluMultiplier);
    return ScoreBalanceAbs((redMultiplier * redScore) - (bluMultiplier * bluScore));
}

public Action Timer_DoSwap(Handle timer, DataPack pack)
{
    pack.Reset();
    int issuerUserId = pack.ReadCell();
    int swapCount = pack.ReadCell();
    bool ignoreImmunity = view_as<bool>(pack.ReadCell());
    char scrambleMode[32];
    pack.ReadString(scrambleMode, sizeof(scrambleMode));

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
        if (DuelDetection_IsClientInDuel(r) || DuelDetection_IsClientInDuel(b))
        {
            LogWhale("Skipping scramble pair: duel active before immunity pass (red=%N blu=%N).", r, b);
            LogWhaleStat("immunity_skip", "type=duel|phase=before_immunity|mode=%s", scrambleMode);
            continue;
        }
        if (!ResolveScramblePurchaseImmunity(r, TEAM_RED, redIds, bluIds, swapCount, i, ignoreImmunity)) continue;
        if (!ResolveScramblePurchaseImmunity(b, TEAM_BLU, redIds, bluIds, swapCount, i, ignoreImmunity)) continue;
        if (GetClientTeam(r) != TEAM_RED || GetClientTeam(b) != TEAM_BLU) continue;
        if (DuelDetection_IsClientInDuel(r) || DuelDetection_IsClientInDuel(b))
        {
            LogWhale("Skipping scramble pair: duel active after immunity pass (red=%N blu=%N).", r, b);
            LogWhaleStat("immunity_skip", "type=duel|phase=after_immunity|mode=%s", scrambleMode);
            continue;
        }

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
                QueueScrambleRespawn(r, TEAM_BLU);
            }
            MarkScrambleImmune(r);
        }
        if (b > 0 && IsClientInGame(b) && GetClientTeam(b) == TEAM_BLU)
        {
            ChangeClientTeam(b, TEAM_RED);
            if (!suppressRespawn)
            {
                QueueScrambleRespawn(b, TEAM_RED);
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
        SaySounds_TryPlayCommand(0, TEAM_MOVE_SAYSOUND, true);
        LogWhale("Scramble executed: moved=%d pairs=%d suppressRespawn=%d.", moved, pairCount, suppressRespawn ? 1 : 0);
        LogWhaleStat("scramble_result", "mode=%s|result=executed|moved=%d|pairs=%d|suppress_respawn=%d|setup=%d|ignore_immunity=%d", scrambleMode, moved, pairCount, suppressRespawn ? 1 : 0, setupScramble ? 1 : 0, ignoreImmunity ? 1 : 0);
        if (suppressRespawn)
        {
            QueuePostAutoScrambleRespawnSweep();
        }
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
        LogWhaleStat("scramble_result", "mode=%s|result=aborted|reason=no_eligible_pairs|swap=%d|ignore_immunity=%d", scrambleMode, swapCount, ignoreImmunity ? 1 : 0);
    }
    return Plugin_Stop;
}

static void ClearScrambleRespawnAttempts()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ClearScrambleRespawnState(client);
    }
}

static void ClearScrambleRespawnState(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_iScrambleRespawnAttempts[client] = 0;
    g_iScrambleRespawnExpectedTeam[client] = 0;
}

static bool QueueScrambleRespawn(int client, int expectedTeam)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }
    if (DuelDetection_IsClientInDuel(client))
    {
        return false;
    }

    if (expectedTeam != TEAM_RED && expectedTeam != TEAM_BLU)
    {
        expectedTeam = GetClientTeam(client);
    }

    g_iScrambleRespawnAttempts[client] = SCRAMBLE_RESPAWN_RETRY_COUNT;
    g_iScrambleRespawnExpectedTeam[client] = expectedTeam;
    CreateTimer(SCRAMBLE_RESPAWN_RETRY_DELAY, Timer_VerifyScrambleRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    return true;
}

public Action Timer_VerifyScrambleRespawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }
    if (DuelDetection_IsClientInDuel(client))
    {
        ClearScrambleRespawnState(client);
        return Plugin_Stop;
    }

    int team = GetClientTeam(client);
    if (team != TEAM_RED && team != TEAM_BLU)
    {
        ClearScrambleRespawnState(client);
        return Plugin_Stop;
    }

    if (g_iScrambleRespawnAttempts[client] <= 0)
    {
        return Plugin_Stop;
    }

    int expectedTeam = g_iScrambleRespawnExpectedTeam[client];
    if (expectedTeam != TEAM_RED && expectedTeam != TEAM_BLU)
    {
        expectedTeam = team;
    }

    g_iScrambleRespawnAttempts[client]--;
    if (team != expectedTeam)
    {
        if (g_iScrambleRespawnAttempts[client] <= 0)
        {
            LogWhale("Scramble respawn failed: %N settled on team=%d while expectedTeam=%d.", client, team, expectedTeam);
            LogWhaleStat("respawn_recovery", "result=failed|reason=wrong_team|team=%d|expected_team=%d", team, expectedTeam);
            ClearScrambleRespawnState(client);
            return Plugin_Stop;
        }

        CreateTimer(SCRAMBLE_RESPAWN_RETRY_DELAY, Timer_VerifyScrambleRespawn, userid, TIMER_FLAG_NO_MAPCHANGE);
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

    if (IsPlayerAlive(client) || g_iScrambleRespawnAttempts[client] <= 0)
    {
        if (!IsPlayerAlive(client))
        {
            LogWhale("Scramble respawn failed: %N team=%d expectedTeam=%d attempts exhausted.", client, team, expectedTeam);
            LogWhaleStat("respawn_recovery", "result=failed|reason=attempts_exhausted|team=%d|expected_team=%d", team, expectedTeam);
        }

        ClearScrambleRespawnState(client);
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
    CreateTimer(SCRAMBLE_SETUP_POLISH_DELAY, Timer_ApplySetupScramblePolish, 0, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Setup scramble polish: queued delayed respawn verification.");
    LogWhaleStat("respawn_recovery", "context=setup_polish|result=queued");
}

public Action Timer_ApplySetupScramblePolish(Handle timer, any data)
{
    QueueScrambleRespawnsForActiveTeams("setup polish");
    CreateTimer(SCRAMBLE_SETUP_UBER_DELAY, Timer_FillSetupMedicUbers, 0, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

static void QueuePostAutoScrambleRespawnSweep()
{
    CreateTimer(SCRAMBLE_AUTO_RESPAWN_SWEEP_DELAY, Timer_PostAutoScrambleRespawnSweep, SCRAMBLE_AUTO_RESPAWN_SWEEP_COUNT, TIMER_FLAG_NO_MAPCHANGE);
    LogWhale("Post-auto scramble respawn sweep queued.");
    LogWhaleStat("respawn_recovery", "context=post_auto_sweep|result=queued|sweeps=%d", SCRAMBLE_AUTO_RESPAWN_SWEEP_COUNT);
}

public Action Timer_PostAutoScrambleRespawnSweep(Handle timer, any remainingSweeps)
{
    QueueScrambleRespawnsForActiveTeams("post-auto sweep");

    int remaining = remainingSweeps - 1;
    if (remaining > 0)
    {
        CreateTimer(SCRAMBLE_AUTO_RESPAWN_SWEEP_REPEAT_DELAY, Timer_PostAutoScrambleRespawnSweep, remaining, TIMER_FLAG_NO_MAPCHANGE);
    }

    return Plugin_Stop;
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
    LogWhaleStat("respawn_recovery", "context=setup_timer|result=restored|seconds=%d", elapsed);
}

static void QueueScrambleRespawnsForActiveTeams(const char[] context)
{
    int queued = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || DuelDetection_IsClientInDuel(i))
        {
            continue;
        }

        int team = GetClientTeam(i);
        if (team != TEAM_RED && team != TEAM_BLU)
        {
            continue;
        }

        if (QueueScrambleRespawn(i, team))
        {
            queued++;
        }
    }

    LogWhale("%s: queued respawn verification for %d active team client(s).", context, queued);
    LogWhaleStat("respawn_recovery", "context=%s|result=queued|queued=%d", context, queued);
}

public Action Timer_FillSetupMedicUbers(Handle timer, any data)
{
    FillSetupMedicUbers();
    return Plugin_Stop;
}

static void FillSetupMedicUbers()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || DuelDetection_IsClientInDuel(i) || TF2_GetPlayerClass(i) != TFClass_Medic)
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
    if (DuelDetection_IsClientInDuel(client))
    {
        return 0;
    }

    if (!ignoreClass)
    {
        TFClassType cls = TF2_GetPlayerClass(client);
        if (cls == TFClass_Spy
            || (forced && (Kogasa_IsEngineerWithBuildings(client) || cls == TFClass_Medic)))
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
    if (DuelDetection_IsClientInDuel(client))
    {
        return false;
    }

    TFClassType cls = TF2_GetPlayerClass(client);
    return !forced || (!Kogasa_IsEngineerWithBuildings(client) && cls != TFClass_Medic);
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
        LogWhaleStat("immunity_skip", "type=paid|result=blocked|team=%d|pair_index=%d", team, pairIndex);
        return false;
    }

    int usesRemaining = PointsStore_ConsumePurchaseUse(client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
    if (usesRemaining < 0)
    {
        return true;
    }

    CPrintToChat(client, "{magenta}[Store]{default} You were protected by your {gold}Scramble Immunity (8 times){default}! Uses remaining: {lightgreen}%d", usesRemaining);
    LogWhale("Paid scramble immunity protected %N; replacement=%N usesRemaining=%d.", client, replacement, usesRemaining);
    LogWhaleStat("immunity_skip", "type=paid|result=replaced|team=%d|uses_remaining=%d|pair_index=%d", team, usesRemaining, pairIndex);

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

        if (DuelDetection_IsClientInDuel(i))
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
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
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
    // Clans returns -1 while its cache/client state is unavailable. Fail open
    // so a transient clan lookup issue cannot make every scramble candidate invalid.
    return count > 1;
}

static void MarkScrambleImmune(int client)
{
    if (client <= 0 || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
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
    LogMessage("[whalescramble] %s", buffer);
}

static void LogWhaleStat(const char[] eventName, const char[] fmt, any ...)
{
    char detail[WHALESCRAMBLE_STATS_DETAIL_MAX];
    detail[0] = '\0';
    if (fmt[0] != '\0')
    {
        VFormat(detail, sizeof(detail), fmt, 3);
        SanitizeWhaleStatField(detail, sizeof(detail));
    }

    char message[512];
    if (detail[0] != '\0')
    {
        Format(message, sizeof(message), "event=%s|%s", eventName, detail);
    }
    else
    {
        Format(message, sizeof(message), "event=%s", eventName);
    }

    PluginStats_Record(eventName, message);
}

static void SanitizeWhaleStatField(char[] value, int maxlen)
{
    for (int i = 0; i < maxlen && value[i] != '\0'; i++)
    {
        if (value[i] == '\n' || value[i] == '\r' || value[i] == '\t')
        {
            value[i] = ' ';
        }
    }
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
