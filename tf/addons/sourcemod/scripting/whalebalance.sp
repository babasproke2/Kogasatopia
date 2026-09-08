#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

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

#include "include/database.inc"
#include "include/duel_detection.inc"
#include "include/steam_identity.inc"
#include "include/buildings.inc"

native int FilterAlerts_MarkAutobalance(int client);
native int FilterAlerts_SuppressTeamAlertWindow(float seconds);

#define CHECK_INTERVAL      3.0
#define MAP_START_DELAY     30.0
#define TEAM_RED            2
#define TEAM_BLUE           3
#define TEAM_GREEN          4
#define TEAM_YELLOW         5
#define GAME_TEAM_COUNT     4
#define MEDIC_AUTOBALANCE_UBER_FLOOR 0.05
#define POINTS_STORE_AB_IMMUNITY_ITEM "abImmunity24h"
#define TEAM_MOVE_SAYSOUND "tp-enderman"
#define TEAM_SWAP_COST 25
#define TEAM_SWAP_REWARD_ID "team_swap_receiver"
#define TEAM_SWAP_TIMEOUT 60.0
#define TEAM_BALANCE_SETTLE_TIME 3.0
#define TEAM_BALANCE_OPERATION_LEASE 5.0
#define TEAM_BALANCE_MOVE_PROTECTION 15.0
#define TEAM_BALANCE_SCRAMBLE_COOLDOWN 120.0
#define TEAM_BALANCE_RESPAWN_RETRY_DELAY 0.50
#define TEAM_BALANCE_RESPAWN_RETRY_COUNT 8
#define POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM "scramImmunity24h"

enum TeamBalanceState
{
    TeamBalance_Idle = 0,
    TeamBalance_Autobalance,
    TeamBalance_ManualSwap,
    TeamBalance_ScrambleVote,
    TeamBalance_ScramblePending,
    TeamBalance_ScrambleMoving,
    TeamBalance_Settling
};

StringMap g_hMapImmunity = null;            // SteamID64 set for map-long immunity.
StringMap g_hPersistentImmunity = null;     // SteamID64 set for persistent admin immunity.
StringMap g_hVolunteers = null;             // SteamID64 set for persistent autobalance volunteers.
StringMap g_hScrambleImmunity = null;       // SteamID64 set for two completed scrambles.
Database  g_hImmunityDb = null;
Handle    g_hImmunityDbReconnectTimer = null;
bool      g_bImmunityDbReady = false;
bool      g_bVolunteerDbReady = false;
int       g_iPersistentVolunteerCount = 0;
ConVar  g_hLogEnabled;
ConVar  g_hDiffThreshold;
ConVar  g_hActionDelay;
ConVar  g_hMaxUnbalanceTime;
ConVar  g_hForceThresholdDelta;
ConVar  g_hSimpleSelection;
ConVar  g_hIgnoreWinning;
ConVar  g_hDatabaseConfig;
ConVar  g_hMpAutoteamBalance;
ConVar  g_hMpTeamsUnbalanceLimit;
int     g_iSavedAutoteamBalance;
int     g_iSavedUnbalanceLimit;
Handle  g_hAutoBalanceTimer = INVALID_HANDLE;
float   g_fImbalanceDetectedAt = 0.0;
int     g_iSwapRequestSenderUserId[MAXPLAYERS + 1];
int     g_iSwapRequestSenderTeam[MAXPLAYERS + 1];
int     g_iSwapRequestTargetTeam[MAXPLAYERS + 1];
Handle  g_hSwapRequestTimer[MAXPLAYERS + 1];
bool    g_bSwapRequestFinalizing[MAXPLAYERS + 1];
TeamBalanceState g_eTeamBalanceState = TeamBalance_Idle;
float   g_fTeamBalanceStateUntil = 0.0;
float   g_fScrambleCooldownUntil = 0.0;
int     g_iScramblesSinceImmunityClear = 0;
int     g_iBalanceRespawnAttempts[MAXPLAYERS + 1];
int     g_iBalanceRespawnExpectedTeam[MAXPLAYERS + 1];
float   g_fBalanceMovedUntil[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "whalebalance",
    author      = "Hombre, AW 'Swixel' Stanley",
    description = "Unified autobalance, team-swap, scramble-vote, and ranking controller.",
    version     = "3.0",
    url         = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("autobalance_4teams");
    RegPluginLibrary("whalebalance");
    CreateNative("Autobalance_HasPendingTeamSwap", Native_HasPendingTeamSwap);
    CreateNative("TeamBalance_IsBusy", Native_TeamBalanceIsBusy);
    CreateNative("TeamBalance_IsScrambleCooldownActive", Native_TeamBalanceIsScrambleCooldownActive);
    CreateNative("TeamBalance_BeginScrambleVote", Native_TeamBalanceBeginScrambleVote);
    CreateNative("TeamBalance_EndScrambleVote", Native_TeamBalanceEndScrambleVote);
    CreateNative("TeamBalance_BeginScramble", Native_TeamBalanceBeginScramble);
    CreateNative("TeamBalance_CancelScramble", Native_TeamBalanceCancelScramble);
    CreateNative("TeamBalance_FinishScramble", Native_TeamBalanceFinishScramble);
    CreateNative("TeamBalance_IsScrambleCandidate", Native_TeamBalanceIsScrambleCandidate);
    CreateNative("TeamBalance_HasScramblePurchaseImmunity", Native_TeamBalanceHasScramblePurchaseImmunity);
    CreateNative("TeamBalance_ConsumeScramblePurchaseImmunity", Native_TeamBalanceConsumeScramblePurchaseImmunity);
    CreateNative("TeamBalance_MoveScramblePair", Native_TeamBalanceMoveScramblePair);
    CreateNative("TeamBalance_QueueRespawn", Native_TeamBalanceQueueRespawn);
    MarkNativeAsOptional("FilterAlerts_MarkAutobalance");
    MarkNativeAsOptional("FilterAlerts_SuppressTeamAlertWindow");
    MarkNativeAsOptional("Clans_GetSameTeamClanMemberCount");
    MarkNativeAsOptional("PointsStore_ApplyBonusPoints");
    MarkNativeAsOptional("PointsStore_GetRewardAmount");
    MarkNativeAsOptional("PointsStore_RefundBonusPoints");
    MarkNativeAsOptional("PointsStore_AreBonusPointsLoaded");
    MarkNativeAsOptional("PointsStore_GetBonusPoints");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("PointsStore_ConsumePurchaseUse");
    MarkNativeAsOptional("DGM_IsSmallFormatGamemode");
    MarkNativeAsOptional("DGM_RealTeamPlayerCount");
    MarkNativeAsOptional("DGM_GetObjectiveLeaderTeam");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_GetLastRoundDurationSeconds");
    MarkNativeAsOptional("DGM_GetRecentControlPointCaptureIntervalSeconds");
    MarkNativeAsOptional("DGM_IsSetupActive");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("WhaleTracker_AreStatsLoaded");
    MarkNativeAsOptional("WhaleTracker_GetWhalePoints");
    return APLRes_Success;
}

public any Native_HasPendingTeamSwap(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return HasPendingTeamSwap(client);
}

public any Native_TeamBalanceIsBusy(Handle plugin, int numParams)
{
    TeamBalance_RefreshState();
    return g_eTeamBalanceState != TeamBalance_Idle;
}

public any Native_TeamBalanceIsScrambleCooldownActive(Handle plugin, int numParams)
{
    return TeamBalance_IsScrambleCooldownActiveInternal();
}

public any Native_TeamBalanceBeginScrambleVote(Handle plugin, int numParams)
{
    float leaseSeconds = view_as<float>(GetNativeCell(1));
    if (leaseSeconds < 1.0)
    {
        leaseSeconds = 1.0;
    }

    return TeamBalance_TryBegin(TeamBalance_ScrambleVote, leaseSeconds + 2.0, false);
}

public any Native_TeamBalanceEndScrambleVote(Handle plugin, int numParams)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote)
    {
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
    return 0;
}

public any Native_TeamBalanceBeginScramble(Handle plugin, int numParams)
{
    bool bypassCooldown = view_as<bool>(GetNativeCell(1));
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote)
    {
        TeamBalance_SetState(TeamBalance_ScramblePending, TEAM_BALANCE_OPERATION_LEASE);
        return true;
    }

    return TeamBalance_TryBegin(TeamBalance_ScramblePending, TEAM_BALANCE_OPERATION_LEASE, bypassCooldown);
}

public any Native_TeamBalanceCancelScramble(Handle plugin, int numParams)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote
        || g_eTeamBalanceState == TeamBalance_ScramblePending
        || g_eTeamBalanceState == TeamBalance_ScrambleMoving)
    {
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
    return 0;
}

public any Native_TeamBalanceFinishScramble(Handle plugin, int numParams)
{
    bool movedPlayers = view_as<bool>(GetNativeCell(1));
    bool countForImmunity = view_as<bool>(GetNativeCell(2));
    TeamBalance_FinishScrambleInternal(movedPlayers, countForImmunity);
    return 0;
}

public any Native_TeamBalanceIsScrambleCandidate(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int expectedTeam = GetNativeCell(2);
    bool ignoreImmunity = view_as<bool>(GetNativeCell(3));
    bool allowBots = view_as<bool>(GetNativeCell(4));
    return TeamBalance_IsScrambleCandidateInternal(client, expectedTeam, ignoreImmunity, allowBots);
}

public any Native_TeamBalanceHasScramblePurchaseImmunity(Handle plugin, int numParams)
{
    return TeamBalance_HasScramblePurchaseImmunityInternal(GetNativeCell(1));
}

public any Native_TeamBalanceConsumeScramblePurchaseImmunity(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (!TeamBalance_HasScramblePurchaseImmunityInternal(client))
    {
        return -1;
    }

    return PointsStore_ConsumePurchaseUse(client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
}

public any Native_TeamBalanceMoveScramblePair(Handle plugin, int numParams)
{
    return TeamBalance_MoveScramblePairInternal(
        GetNativeCell(1),
        GetNativeCell(2),
        view_as<bool>(GetNativeCell(3)),
        view_as<bool>(GetNativeCell(4)),
        view_as<bool>(GetNativeCell(5))
    );
}

public any Native_TeamBalanceQueueRespawn(Handle plugin, int numParams)
{
    return TeamBalance_QueueRespawnInternal(GetNativeCell(1), GetNativeCell(2), false);
}

static bool TeamBalance_IsScrambleCooldownActive()
{
    return TeamBalance_IsScrambleCooldownActiveInternal();
}

static bool TeamBalance_BeginScrambleVote(float leaseSeconds)
{
    if (leaseSeconds < 1.0)
    {
        leaseSeconds = 1.0;
    }
    return TeamBalance_TryBegin(TeamBalance_ScrambleVote, leaseSeconds + 2.0, false);
}

static void TeamBalance_EndScrambleVote()
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote)
    {
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
}

static bool TeamBalance_BeginScramble(bool bypassCooldown = false)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote)
    {
        TeamBalance_SetState(TeamBalance_ScramblePending, TEAM_BALANCE_OPERATION_LEASE);
        return true;
    }
    return TeamBalance_TryBegin(
        TeamBalance_ScramblePending, TEAM_BALANCE_OPERATION_LEASE, bypassCooldown);
}

static void TeamBalance_CancelScramble()
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState == TeamBalance_ScrambleVote
        || g_eTeamBalanceState == TeamBalance_ScramblePending
        || g_eTeamBalanceState == TeamBalance_ScrambleMoving)
    {
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
}

static void TeamBalance_FinishScramble(
    bool movedPlayers, bool countForImmunity = true)
{
    TeamBalance_FinishScrambleInternal(movedPlayers, countForImmunity);
}

static bool TeamBalance_IsScrambleCandidate(
    int client, int expectedTeam, bool ignoreImmunity, bool allowBots)
{
    return TeamBalance_IsScrambleCandidateInternal(
        client, expectedTeam, ignoreImmunity, allowBots);
}

static bool TeamBalance_HasScramblePurchaseImmunity(int client)
{
    return TeamBalance_HasScramblePurchaseImmunityInternal(client);
}

static int TeamBalance_ConsumeScramblePurchaseImmunity(int client)
{
    if (!TeamBalance_HasScramblePurchaseImmunityInternal(client))
    {
        return -1;
    }
    return PointsStore_ConsumePurchaseUse(
        client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
}

static bool TeamBalance_MoveScramblePair(
    int redClient,
    int bluClient,
    bool ignoreImmunity,
    bool allowBots,
    bool suppressRespawn)
{
    return TeamBalance_MoveScramblePairInternal(
        redClient, bluClient, ignoreImmunity, allowBots, suppressRespawn);
}

static bool TeamBalance_QueueRespawn(int client, int expectedTeam)
{
    return TeamBalance_QueueRespawnInternal(client, expectedTeam, false);
}

static void TeamBalance_SetState(TeamBalanceState state, float leaseSeconds)
{
    g_eTeamBalanceState = state;
    g_fTeamBalanceStateUntil = (state != TeamBalance_Idle && leaseSeconds > 0.0)
        ? GetEngineTime() + leaseSeconds
        : 0.0;
}

static void TeamBalance_RefreshState()
{
    if (g_eTeamBalanceState == TeamBalance_Idle || g_fTeamBalanceStateUntil <= 0.0)
    {
        return;
    }

    if (GetEngineTime() >= g_fTeamBalanceStateUntil)
    {
        LogBalance("Balance state lease expired: state=%d", view_as<int>(g_eTeamBalanceState));
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
}

static bool TeamBalance_IsScrambleCooldownActiveInternal()
{
    if (g_fScrambleCooldownUntil <= 0.0)
    {
        return false;
    }

    if (GetEngineTime() >= g_fScrambleCooldownUntil)
    {
        g_fScrambleCooldownUntil = 0.0;
        LogBalance("Scramble cooldown expired.");
        return false;
    }

    return true;
}

static bool TeamBalance_TryBegin(TeamBalanceState state, float leaseSeconds, bool bypassScrambleCooldown)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState != TeamBalance_Idle)
    {
        return false;
    }

    if (!bypassScrambleCooldown
        && (state == TeamBalance_ScrambleVote || state == TeamBalance_ScramblePending)
        && TeamBalance_IsScrambleCooldownActiveInternal())
    {
        return false;
    }

    TeamBalance_SetState(state, leaseSeconds);
    return true;
}

static void TeamBalance_FinishOperation(bool movedPlayers)
{
    if (movedPlayers)
    {
        TeamBalance_SetState(TeamBalance_Settling, TEAM_BALANCE_SETTLE_TIME);
    }
    else
    {
        TeamBalance_SetState(TeamBalance_Idle, 0.0);
    }
}

static void TeamBalance_FinishScrambleInternal(bool movedPlayers, bool countForImmunity)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState != TeamBalance_ScramblePending
        && g_eTeamBalanceState != TeamBalance_ScrambleMoving)
    {
        LogBalance("Ignored invalid scramble completion transition from state=%d", view_as<int>(g_eTeamBalanceState));
        return;
    }

    if (!movedPlayers)
    {
        TeamBalance_FinishOperation(false);
        return;
    }

    g_fScrambleCooldownUntil = GetEngineTime() + TEAM_BALANCE_SCRAMBLE_COOLDOWN;
    if (countForImmunity)
    {
        g_iScramblesSinceImmunityClear++;
        if (g_iScramblesSinceImmunityClear >= 2)
        {
            if (g_hScrambleImmunity != null)
            {
                g_hScrambleImmunity.Clear();
            }
            g_iScramblesSinceImmunityClear = 0;
            LogBalance("Cleared scramble immunity after two completed scrambles.");
        }
    }

    TeamBalance_FinishOperation(true);
    LogBalance("Scramble completed; cooldown and settle window started.");
}

static bool TeamBalance_IsScrambleCandidateInternal(int client, int expectedTeam, bool ignoreImmunity, bool allowBots)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }
    if (!allowBots && IsFakeClient(client))
    {
        return false;
    }
    if ((expectedTeam == TEAM_RED || expectedTeam == TEAM_BLUE) && GetClientTeam(client) != expectedTeam)
    {
        return false;
    }
    if (GetClientTeam(client) != TEAM_RED && GetClientTeam(client) != TEAM_BLUE)
    {
        return false;
    }
    if (DuelDetection_IsClientInDuel(client))
    {
        return false;
    }
    if (TeamBalance_IsRecentlyMoved(client))
    {
        return false;
    }
    if (!ignoreImmunity && TeamBalance_IsScrambleImmuneInternal(client))
    {
        return false;
    }

    return true;
}

static bool TeamBalance_IsScrambleImmuneInternal(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return false;
    }
    bool clanProtectionAvailable = GetFeatureStatus(FeatureType_Native, "Clans_GetSameTeamClanMemberCount") == FeatureStatus_Available;
    if (HasClanTeammateProtection(client, GetClientTeam(client), clanProtectionAvailable))
    {
        return true;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        return false;
    }

    int dummy;
    return g_hScrambleImmunity.GetValue(steamId, dummy);
}

static void TeamBalance_MarkScrambleImmune(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || g_hScrambleImmunity == null)
    {
        return;
    }

    char steamId[32];
    if (Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        g_hScrambleImmunity.SetValue(steamId, 1, true);
    }
}

static bool TeamBalance_HasScramblePurchaseImmunityInternal(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }
    if (GetFeatureStatus(FeatureType_Native, "PointsStore_HasPurchase") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "PointsStore_ConsumePurchaseUse") != FeatureStatus_Available)
    {
        return false;
    }

    return PointsStore_HasPurchase(client, POINTS_STORE_SCRAMBLE_IMMUNITY_ITEM);
}

static bool TeamBalance_MoveScramblePairInternal(int redClient, int bluClient, bool ignoreImmunity, bool allowBots, bool suppressRespawn)
{
    TeamBalance_RefreshState();
    if (g_eTeamBalanceState != TeamBalance_ScramblePending && g_eTeamBalanceState != TeamBalance_ScrambleMoving)
    {
        return false;
    }
    if (!TeamBalance_IsScrambleCandidateInternal(redClient, TEAM_RED, ignoreImmunity, allowBots)
        || !TeamBalance_IsScrambleCandidateInternal(bluClient, TEAM_BLUE, ignoreImmunity, allowBots)
        || TeamBalance_HasScramblePurchaseImmunityInternal(redClient)
        || TeamBalance_HasScramblePurchaseImmunityInternal(bluClient))
    {
        return false;
    }

    TeamBalance_SetState(TeamBalance_ScrambleMoving, TEAM_BALANCE_OPERATION_LEASE);
    ChangeClientTeam(redClient, TEAM_BLUE);
    ChangeClientTeam(bluClient, TEAM_RED);
    TeamBalance_MarkRecentlyMoved(redClient);
    TeamBalance_MarkRecentlyMoved(bluClient);
    if (!suppressRespawn)
    {
        TeamBalance_QueueRespawnInternal(redClient, TEAM_BLUE, false);
        TeamBalance_QueueRespawnInternal(bluClient, TEAM_RED, false);
    }
    TeamBalance_MarkScrambleImmune(redClient);
    TeamBalance_MarkScrambleImmune(bluClient);
    return true;
}

static bool TeamBalance_MoveAutobalanceClient(int client, int expectedTeam, int targetTeam)
{
    if (g_eTeamBalanceState != TeamBalance_Autobalance
        || !IsGameTeam(expectedTeam) || !IsGameTeam(targetTeam) || expectedTeam == targetTeam
        || !IsBasicBalanceCandidate(client, expectedTeam)
        || IsClientImmune(client) || HasAutobalancePurchaseImmunity(client))
    {
        return false;
    }

    ChangeClientTeam(client, targetTeam);
    TeamBalance_MarkRecentlyMoved(client);
    TeamBalance_QueueRespawnInternal(client, targetTeam, true);
    SetClientMapImmunity(client, true);
    TeamBalance_FinishOperation(true);
    return true;
}

static bool TeamBalance_QueueRespawnInternal(int client, int expectedTeam, bool immediate)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || DuelDetection_IsClientInDuel(client))
    {
        return false;
    }
    if (!IsGameTeam(expectedTeam))
    {
        expectedTeam = GetClientTeam(client);
    }
    if (!IsGameTeam(expectedTeam))
    {
        return false;
    }

    g_iBalanceRespawnAttempts[client] = TEAM_BALANCE_RESPAWN_RETRY_COUNT;
    g_iBalanceRespawnExpectedTeam[client] = expectedTeam;
    if (immediate && GetClientTeam(client) == expectedTeam)
    {
        if (TF2_GetPlayerClass(client) == TFClass_Unknown)
        {
            TF2_SetPlayerClass(client, TFClass_Scout);
        }
        if (!IsPlayerAlive(client))
        {
            TF2_RespawnPlayer(client);
        }
    }
    CreateTimer(TEAM_BALANCE_RESPAWN_RETRY_DELAY, Timer_TeamBalanceVerifyRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    return true;
}

static void TeamBalance_ClearRespawnState(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        g_iBalanceRespawnAttempts[client] = 0;
        g_iBalanceRespawnExpectedTeam[client] = 0;
    }
}

static bool TeamBalance_IsRecentlyMoved(int client)
{
    return client > 0 && client <= MaxClients && g_fBalanceMovedUntil[client] > GetEngineTime();
}

static void TeamBalance_MarkRecentlyMoved(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        g_fBalanceMovedUntil[client] = GetEngineTime() + TEAM_BALANCE_MOVE_PROTECTION;
    }
}

static void TeamBalance_ResetRuntime()
{
    TeamBalance_SetState(TeamBalance_Idle, 0.0);
    g_fScrambleCooldownUntil = 0.0;
    g_iScramblesSinceImmunityClear = 0;
    if (g_hScrambleImmunity != null)
    {
        g_hScrambleImmunity.Clear();
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        TeamBalance_ClearRespawnState(client);
        g_fBalanceMovedUntil[client] = 0.0;
    }
}

public Action Timer_TeamBalanceVerifyRespawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }
    if (DuelDetection_IsClientInDuel(client) || g_iBalanceRespawnAttempts[client] <= 0)
    {
        TeamBalance_ClearRespawnState(client);
        return Plugin_Stop;
    }

    int team = GetClientTeam(client);
    int expectedTeam = g_iBalanceRespawnExpectedTeam[client];
    g_iBalanceRespawnAttempts[client]--;
    if (team != expectedTeam)
    {
        if (g_iBalanceRespawnAttempts[client] > 0)
        {
            CreateTimer(TEAM_BALANCE_RESPAWN_RETRY_DELAY, Timer_TeamBalanceVerifyRespawn, userid, TIMER_FLAG_NO_MAPCHANGE);
        }
        else
        {
            TeamBalance_ClearRespawnState(client);
        }
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
    if (IsPlayerAlive(client) || g_iBalanceRespawnAttempts[client] <= 0)
    {
        TeamBalance_ClearRespawnState(client);
        return Plugin_Stop;
    }

    CreateTimer(TEAM_BALANCE_RESPAWN_RETRY_DELAY, Timer_TeamBalanceVerifyRespawn, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    DuelDetection_Initialize();
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    g_hDiffThreshold = CreateConVar("sm_autobalance_diff", "1", "Autobalance when team size difference is above this value.", _, true, 1.0, true, 10.0);
    g_hActionDelay = CreateConVar("sm_autobalance_action_delay", "10", "Seconds an imbalance must persist before normal autobalance can move a player.", _, true, 0.0, true, 120.0);
    g_hMaxUnbalanceTime = CreateConVar("sm_autobalance_max_unbalance_time", "5", "Maximum seconds an imbalance may persist before forced autobalance. 0 disables.", _, true, 0.0, true, 300.0);
    g_hForceThresholdDelta = CreateConVar("sm_autobalance_force_threshold_delta", "1", "Force autobalance when team-size diff is at least normal threshold plus this value.", _, true, 0.0, true, 10.0);
    g_hSimpleSelection = CreateConVar("sm_autobalance_simple_selection", "1", "If enabled, autobalance prefers the most recently joined dead player without Engineer buildings on the oversized team, then falls back to lower-priority eligible players by userID.", _, true, 0.0, true, 1.0);
    g_hIgnoreWinning = CreateConVar("sm_autobalance_ignore_winning", "3", "0 disables. 1 blocks losing-to-winning moves. Values above 1 allow losing-to-winning moves when value is >= current team-size diff.", _, true, 0.0);
    g_hDatabaseConfig = CreateConVar("sm_autobalance_database", "default", "Database config name from databases.cfg to use for persistent autobalance immunity.");
    RegAdminCmd("sm_immune", Command_Immune, ADMFLAG_GENERIC, "sm_immune <name> - Toggle persistent autobalance immunity for a player.");
    RegConsoleCmd("sm_volunteer", Command_Volunteer, "sm_volunteer [name] - Toggle autobalance volunteer status.");
    RegConsoleCmd("sm_swap", Command_RequestTeamSwap, "sm_swap [name] - Request a team swap with an enemy player.");
    RegConsoleCmd("sm_requestswap", Command_RequestTeamSwap, "sm_requestswap [name] - Request a team swap with an enemy player.");
    RegConsoleCmd("sm_sw", Command_RequestTeamSwap, "sm_sw [name] - Request a team swap with an enemy player.");
    RegAdminCmd("sm_forceswap", Command_ForceTeamSwap, ADMFLAG_GENERIC, "sm_forceswap <name> [name] - Force two players to swap teams.");
    RegConsoleCmd("sm_yes", Command_AcceptTeamSwap, "Accept a pending team-swap request.");
    LogBalance("[whalebalance] Plugin started.");
    g_hMapImmunity = new StringMap();
    g_hPersistentImmunity = new StringMap();
    g_hVolunteers = new StringMap();
    g_hScrambleImmunity = new StringMap();
    TeamBalance_ResetRuntime();
    ClearAllTeamSwapRequests();

    ApplyServerBalanceCvars(true);
    ConnectImmunityDatabase();
    WhaleScramble_OnPluginStart();
}

public void OnMapStart()
{
    TeamBalance_ResetRuntime();
    ClearAllTeamSwapRequests();
    StopAutobalanceTimer();
    g_fImbalanceDetectedAt = 0.0;
    g_hAutoBalanceTimer = CreateTimer(MAP_START_DELAY, Timer_StartAutobalance);

    if (g_hMapImmunity != null)
    {
        g_hMapImmunity.Clear();
    }
    WhaleScramble_OnMapStart();
}

public void OnMapEnd()
{
    TeamBalance_ResetRuntime();
    ClearAllTeamSwapRequests();
    StopAutobalanceTimer();
    g_fImbalanceDetectedAt = 0.0;
    WhaleScramble_OnMapEnd();
}

public void OnClientDisconnect(int client)
{
    TeamBalance_ClearRespawnState(client);
    if (client > 0 && client <= MaxClients)
    {
        g_fBalanceMovedUntil[client] = 0.0;
    }
    ClearTeamSwapRequestsForClient(client);
    WhaleScramble_OnClientDisconnect(client);
}

public void OnPluginEnd()
{
    WhaleScramble_OnPluginEnd();
    ApplyServerBalanceCvars(false);
    DuelDetection_Shutdown();
    ClearAllTeamSwapRequests();

    StopAutobalanceTimer();

    Db_CancelTimer(g_hImmunityDbReconnectTimer);
    g_bImmunityDbReady = false;
    g_bVolunteerDbReady = false;

    if (g_hImmunityDb != null)
    {
        delete g_hImmunityDb;
        g_hImmunityDb = null;
    }

    if (g_hMapImmunity != null)
    {
        delete g_hMapImmunity;
        g_hMapImmunity = null;
    }

    if (g_hPersistentImmunity != null)
    {
        delete g_hPersistentImmunity;
        g_hPersistentImmunity = null;
    }

    if (g_hVolunteers != null)
    {
        delete g_hVolunteers;
        g_hVolunteers = null;
    }

    if (g_hScrambleImmunity != null)
    {
        delete g_hScrambleImmunity;
        g_hScrambleImmunity = null;
    }

}

// ---------------------------------------------------------------------------
// Voluntary team swaps
// ---------------------------------------------------------------------------

public Action Command_RequestTeamSwap(int client, int args)
{
    if (!IsTeamSwapClient(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ShowTeamSwapMenu(client);
        return Plugin_Handled;
    }

    char targetArg[MAX_TARGET_LENGTH];
    GetCmdArgString(targetArg, sizeof(targetArg));
    StripQuotes(targetArg);
    TrimString(targetArg);

    int target = FindTarget(client, targetArg, true, false);
    if (target > 0)
    {
        SendTeamSwapRequest(client, target);
    }

    return Plugin_Handled;
}

public Action Command_ForceTeamSwap(int client, int args)
{
    if (args < 1 || args > 2 || (args == 1 && client == 0))
    {
        ReplyToCommand(client, "[Team Swap] Usage: sm_forceswap <name> [name]");
        return Plugin_Handled;
    }

    int first = client;
    int second;
    char targetArg[MAX_TARGET_LENGTH];

    if (args == 1)
    {
        GetCmdArg(1, targetArg, sizeof(targetArg));
        second = FindTarget(client, targetArg, true, false);
    }
    else
    {
        GetCmdArg(1, targetArg, sizeof(targetArg));
        first = FindTarget(client, targetArg, true, false);
        if (first <= 0)
        {
            return Plugin_Handled;
        }

        GetCmdArg(2, targetArg, sizeof(targetArg));
        second = FindTarget(client, targetArg, true, false);
    }

    if (first <= 0 || second <= 0)
    {
        return Plugin_Handled;
    }

    if (first == second)
    {
        ReplyToCommand(client, "[Team Swap] Select two different players.");
        return Plugin_Handled;
    }

    int firstTeam = GetClientTeam(first);
    int secondTeam = GetClientTeam(second);
    if (!IsTeamSwapClient(first) || !IsTeamSwapClient(second)
        || !IsGameTeam(firstTeam) || !IsGameTeam(secondTeam) || firstTeam == secondTeam)
    {
        ReplyToCommand(client, "[Team Swap] Both players must be on different playing teams.");
        return Plugin_Handled;
    }

    if (DuelDetection_IsClientInDuel(first) || DuelDetection_IsClientInDuel(second))
    {
        ReplyToCommand(client, "[Team Swap] Players in a duel cannot swap teams.");
        return Plugin_Handled;
    }

    ClearTeamSwapRequestsForClient(first);
    ClearTeamSwapRequestsForClient(second);
    if (!TeamBalance_MoveManualPair(first, second))
    {
        ReplyToCommand(client, "[Team Swap] Team balancing is busy; try again in a moment.");
        return Plugin_Handled;
    }

    ReplyToCommand(client, "[Team Swap] Force-swapped %N with %N.", first, second);
    if (first != client)
    {
        CPrintToChat(first, "[Team Swap] An admin force-swapped you with %N.", second);
    }
    if (second != client)
    {
        CPrintToChat(second, "[Team Swap] An admin force-swapped you with %N.", first);
    }
    return Plugin_Handled;
}

public Action Command_AcceptTeamSwap(int client, int args)
{
    if (!IsTeamSwapClient(client) || !HasPendingTeamSwap(client))
    {
        return Plugin_Continue;
    }

    if (g_bSwapRequestFinalizing[client])
    {
        return Plugin_Handled;
    }

    int sender = GetClientOfUserId(g_iSwapRequestSenderUserId[client]);
    int senderTeam = g_iSwapRequestSenderTeam[client];
    int targetTeam = g_iSwapRequestTargetTeam[client];
    BeginTeamSwapRequestFinalization(client);

    if (!IsTeamSwapClient(sender))
    {
        CPrintToChat(client, "[Team Swap] The requester is no longer available.");
        return Plugin_Handled;
    }

    if (GetClientTeam(sender) != senderTeam || GetClientTeam(client) != targetTeam
        || senderTeam == targetTeam || !IsGameTeam(senderTeam) || !IsGameTeam(targetTeam))
    {
        CPrintToChat(client, "[Team Swap] The request is no longer valid because someone changed teams.");
        CPrintToChat(sender, "[Team Swap] Your request is no longer valid because someone changed teams.");
        return Plugin_Handled;
    }

    if (DuelDetection_IsClientInDuel(sender) || DuelDetection_IsClientInDuel(client))
    {
        CPrintToChat(client, "[Team Swap] Players in a duel cannot swap teams.");
        CPrintToChat(sender, "[Team Swap] Players in a duel cannot swap teams.");
        return Plugin_Handled;
    }

    TeamBalance_RefreshState();
    if (g_eTeamBalanceState != TeamBalance_Idle)
    {
        CPrintToChat(client, "[Team Swap] Team balancing is busy; try again in a moment.");
        CPrintToChat(sender, "[Team Swap] Team balancing is busy; try again in a moment.");
        return Plugin_Handled;
    }

    if (!CanUseTeamSwapStore(sender, true) || !CanUseTeamSwapStore(client, false))
    {
        CPrintToChat(client, "[Team Swap] The Gems store is not ready for both players.");
        CPrintToChat(sender, "[Team Swap] The Gems store is not ready for both players.");
        return Plugin_Handled;
    }

    if (PointsStore_GetBonusPoints(sender) < TEAM_SWAP_COST)
    {
        CPrintToChat(sender, "[Team Swap] You need {gold}%d Gems{default} to swap teams.", TEAM_SWAP_COST);
        CPrintToChat(client, "[Team Swap] The requester can no longer afford the team swap.");
        return Plugin_Handled;
    }

    if (!PointsStore_SpendBonusPoints(sender, TEAM_SWAP_COST))
    {
        CPrintToChat(sender, "[Team Swap] The {gold}%d Gem{default} payment failed.", TEAM_SWAP_COST);
        CPrintToChat(client, "[Team Swap] The requester's payment failed.");
        return Plugin_Handled;
    }

    if (!PointsStore_ApplyBonusPoints(client, TEAM_SWAP_REWARD_ID, true, true, 1.0, sender, 0.0))
    {
        PointsStore_RefundBonusPoints(sender, TEAM_SWAP_COST, "team_swap_refund");
        CPrintToChat(sender, "[Team Swap] The receiver reward failed; your Gems were refunded.");
        CPrintToChat(client, "[Team Swap] Your reward could not be applied, so the swap was cancelled.");
        return Plugin_Handled;
    }

    TeamBalance_MoveManualPair(sender, client);

    char senderName[256];
    char targetName[256];
    BuildTeamSwapDisplayName(sender, senderName, sizeof(senderName));
    BuildTeamSwapDisplayName(client, targetName, sizeof(targetName));
    CPrintToChatEx(sender, client, "[Team Swap] You swapped teams with %s{default} for {gold}%d Gems{default}.", targetName, TEAM_SWAP_COST);
    int teamSwapReward = PointsStore_GetRewardAmount(TEAM_SWAP_REWARD_ID);
    CPrintToChatEx(client, sender, "[Team Swap] You swapped teams with %s{default} and received {green}+%d Gems{default}.", senderName, teamSwapReward);
    return Plugin_Handled;
}

static void ShowTeamSwapMenu(int client)
{
    int clientTeam = GetClientTeam(client);
    if (!IsGameTeam(clientTeam))
    {
        CPrintToChat(client, "[Team Swap] Join a playing team before requesting a swap.");
        return;
    }

    Menu menu = new Menu(MenuHandler_TeamSwap);
    menu.SetTitle("Swap teams with an enemy - %d Gems", TEAM_SWAP_COST);

    int targetCount = 0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsTeamSwapClient(target) || target == client || !IsGameTeam(GetClientTeam(target))
            || GetClientTeam(target) == clientTeam || DuelDetection_IsClientInDuel(target))
        {
            continue;
        }

        char userId[16];
        char name[MAX_NAME_LENGTH];
        IntToString(GetClientUserId(target), userId, sizeof(userId));
        GetClientName(target, name, sizeof(name));
        menu.AddItem(userId, name);
        targetCount++;
    }

    if (targetCount == 0)
    {
        delete menu;
        CPrintToChat(client, "[Team Swap] No enemy players are available.");
        return;
    }

    menu.ExitButton = true;
    menu.Display(client, 30);
}

public int MenuHandler_TeamSwap(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(item, info, sizeof(info));
        int target = GetClientOfUserId(StringToInt(info));
        SendTeamSwapRequest(client, target);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

static bool SendTeamSwapRequest(int sender, int target)
{
    if (!IsTeamSwapClient(sender) || !IsTeamSwapClient(target))
    {
        return false;
    }

    int senderTeam = GetClientTeam(sender);
    int targetTeam = GetClientTeam(target);
    if (sender == target || !IsGameTeam(senderTeam) || !IsGameTeam(targetTeam) || senderTeam == targetTeam)
    {
        CPrintToChat(sender, "[Team Swap] Select a player on an enemy team.");
        return false;
    }

    if (DuelDetection_IsClientInDuel(sender) || DuelDetection_IsClientInDuel(target))
    {
        CPrintToChat(sender, "[Team Swap] Players in a duel cannot swap teams.");
        return false;
    }

    if (!CanUseTeamSwapStore(sender, true))
    {
        return false;
    }

    if (PointsStore_GetBonusPoints(sender) < TEAM_SWAP_COST)
    {
        CPrintToChat(sender, "[Team Swap] You need {gold}%d Gems{default} to swap teams.", TEAM_SWAP_COST);
        return false;
    }

    if (FindOutgoingTeamSwapRequest(sender) > 0)
    {
        CPrintToChat(sender, "[Team Swap] You already have a pending request.");
        return false;
    }

    if (HasPendingTeamSwap(target))
    {
        CPrintToChat(sender, "[Team Swap] That player already has a pending request.");
        return false;
    }

    g_iSwapRequestSenderUserId[target] = GetClientUserId(sender);
    g_iSwapRequestSenderTeam[target] = senderTeam;
    g_iSwapRequestTargetTeam[target] = targetTeam;
    g_bSwapRequestFinalizing[target] = false;
    g_hSwapRequestTimer[target] = CreateTimer(TEAM_SWAP_TIMEOUT, Timer_ExpireTeamSwapRequest, GetClientUserId(target), TIMER_FLAG_NO_MAPCHANGE);

    char senderName[256];
    BuildTeamSwapDisplayName(sender, senderName, sizeof(senderName));
    CPrintToChat(sender, "[Team Swap] Request sent to %N. You will be charged {gold}%d Gems{default} if accepted.", target, TEAM_SWAP_COST);
    CPrintToChatEx(target, sender, "[Team Swap] %s{default} wants to swap teams with you! Use {gold}!yes{default} to accept.", senderName);
    return true;
}

public Action Timer_ExpireTeamSwapRequest(Handle timer, any targetUserId)
{
    int target = GetClientOfUserId(targetUserId);
    if (!IsTeamSwapClient(target))
    {
        return Plugin_Stop;
    }

    g_hSwapRequestTimer[target] = null;
    int sender = GetClientOfUserId(g_iSwapRequestSenderUserId[target]);
    if (IsTeamSwapClient(sender))
    {
        CPrintToChat(sender, "[Team Swap] Your request to %N expired.", target);
    }
    CPrintToChat(target, "[Team Swap] The pending team-swap request expired.");
    ClearTeamSwapRequest(target);
    return Plugin_Stop;
}

static void BeginTeamSwapRequestFinalization(int target)
{
    g_bSwapRequestFinalizing[target] = true;
    if (g_hSwapRequestTimer[target] != null)
    {
        delete g_hSwapRequestTimer[target];
        g_hSwapRequestTimer[target] = null;
    }
    RequestFrame(Frame_ClearFinalizedTeamSwap, target);
}

public void Frame_ClearFinalizedTeamSwap(any target)
{
    if (target > 0 && target <= MaxClients && g_bSwapRequestFinalizing[target])
    {
        ClearTeamSwapRequest(target);
    }
}

static bool HasPendingTeamSwap(int target)
{
    return target > 0 && target <= MaxClients && g_iSwapRequestSenderUserId[target] > 0;
}

static int FindOutgoingTeamSwapRequest(int sender)
{
    int senderUserId = GetClientUserId(sender);
    for (int target = 1; target <= MaxClients; target++)
    {
        if (g_iSwapRequestSenderUserId[target] == senderUserId)
        {
            return target;
        }
    }
    return 0;
}

static void ClearTeamSwapRequest(int target)
{
    if (target <= 0 || target > MaxClients)
    {
        return;
    }

    if (g_hSwapRequestTimer[target] != null)
    {
        delete g_hSwapRequestTimer[target];
        g_hSwapRequestTimer[target] = null;
    }
    g_iSwapRequestSenderUserId[target] = 0;
    g_iSwapRequestSenderTeam[target] = 0;
    g_iSwapRequestTargetTeam[target] = 0;
    g_bSwapRequestFinalizing[target] = false;
}

static void ClearTeamSwapRequestsForClient(int client)
{
    int userId = GetClientUserId(client);
    ClearTeamSwapRequest(client);
    for (int target = 1; target <= MaxClients; target++)
    {
        if (g_iSwapRequestSenderUserId[target] == userId)
        {
            ClearTeamSwapRequest(target);
        }
    }
}

static void ClearAllTeamSwapRequests()
{
    for (int target = 1; target <= MaxClients; target++)
    {
        ClearTeamSwapRequest(target);
    }
}

static bool IsTeamSwapClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

static bool TeamBalance_MoveManualPair(int first, int second)
{
    if (!TeamBalance_TryBegin(TeamBalance_ManualSwap, TEAM_BALANCE_OPERATION_LEASE, true))
    {
        return false;
    }

    int firstTeam = GetClientTeam(first);
    int secondTeam = GetClientTeam(second);
    bool firstWasAlive = IsPlayerAlive(first);
    bool secondWasAlive = IsPlayerAlive(second);

    ChangeClientTeam(first, secondTeam);
    ChangeClientTeam(second, firstTeam);
    TeamBalance_MarkRecentlyMoved(first);
    TeamBalance_MarkRecentlyMoved(second);
    if (firstWasAlive)
    {
        TeamBalance_QueueRespawnInternal(first, secondTeam, true);
    }
    if (secondWasAlive)
    {
        TeamBalance_QueueRespawnInternal(second, firstTeam, true);
    }
    TeamBalance_FinishOperation(true);
    return true;
}

static bool CanUseTeamSwapStore(int client, bool printFailure)
{
    bool available = GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_GetRewardAmount") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_RefundBonusPoints") == FeatureStatus_Available;
    if (!available)
    {
        if (printFailure)
        {
            CPrintToChat(client, "[Team Swap] The Gems store is unavailable.");
        }
        return false;
    }

    if (!PointsStore_AreBonusPointsLoaded(client))
    {
        if (printFailure)
        {
            CPrintToChat(client, "[Team Swap] Your Gems are still loading.");
        }
        return false;
    }
    return true;
}

static void BuildTeamSwapDisplayName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen) && buffer[0] != '\0')
    {
        return;
    }

    Format(buffer, maxlen, "{teamcolor}%N", client);
}

// ---------------------------------------------------------------------------
// Main balance timer
// ---------------------------------------------------------------------------

public Action Timer_StartAutobalance(Handle timer)
{
    if (timer != g_hAutoBalanceTimer)
    {
        return Plugin_Stop;
    }

    g_hAutoBalanceTimer = CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT);
    return Plugin_Stop;
}

public Action Timer_Autobalance(Handle timer)
{
    if (ShouldSuppressAutobalanceForGamemode())
    {
        return Plugin_Continue;
    }

    TeamBalance_RefreshState();
    if (g_eTeamBalanceState != TeamBalance_Idle)
    {
        return Plugin_Continue;
    }

    int teamCounts[6];

    for (int i = 1; i <= MaxClients; i++)
    {
        // Bots occupy real team slots and therefore count toward imbalance,
        // but IsBasicBalanceCandidate() keeps them out of every target pool.
        if (!IsClientInGame(i))
        {
            continue;
        }

        int team = GetClientTeam(i);
        if (!IsGameTeam(team))
        {
            continue;
        }

        teamCounts[team]++;
    }

    // Build the list of active teams (always RED + BLU; add GREEN/YELLOW if populated).
    int activeTeams[GAME_TEAM_COUNT];
    int activeCount = 0;
    activeTeams[activeCount++] = TEAM_RED;
    activeTeams[activeCount++] = TEAM_BLUE;

    if (teamCounts[TEAM_GREEN] > 0 || teamCounts[TEAM_YELLOW] > 0)
    {
        activeTeams[activeCount++] = TEAM_GREEN;
        activeTeams[activeCount++] = TEAM_YELLOW;
    }

    // Sort active teams by count descending (simple insertion sort; max 4 elements).
    int sortedTeams[GAME_TEAM_COUNT];
    int sortedCounts[GAME_TEAM_COUNT];
    for (int i = 0; i < activeCount; i++)
    {
        sortedTeams[i]  = activeTeams[i];
        sortedCounts[i] = teamCounts[activeTeams[i]];
    }

    for (int i = 1; i < activeCount; i++)
    {
        int keyTeam  = sortedTeams[i];
        int keyCount = sortedCounts[i];
        int j = i - 1;
        while (j >= 0 && sortedCounts[j] < keyCount)
        {
            sortedTeams[j + 1]  = sortedTeams[j];
            sortedCounts[j + 1] = sortedCounts[j];
            j--;
        }
        sortedTeams[j + 1]  = keyTeam;
        sortedCounts[j + 1] = keyCount;
    }

    int biggestTeam   = sortedTeams[0];
    int biggestCount  = sortedCounts[0];
    int smallestTeam  = sortedTeams[activeCount - 1];
    int smallestCount = sortedCounts[activeCount - 1];

    if (biggestTeam == 0 || smallestTeam == 0 || biggestTeam == smallestTeam)
    {
        return Plugin_Continue;
    }

    int diff = biggestCount - smallestCount;
    int diffThreshold = 1;
    if (g_hDiffThreshold != null)
    {
        diffThreshold = g_hDiffThreshold.IntValue;
        if (diffThreshold < 1) diffThreshold = 1;
    }

    if (diff <= diffThreshold)
    {
        g_fImbalanceDetectedAt = 0.0;
        return Plugin_Continue;
    }

    float now = GetEngineTime();
    if (g_fImbalanceDetectedAt <= 0.0)
    {
        g_fImbalanceDetectedAt = now;
    }

    float imbalanceAge = now - g_fImbalanceDetectedAt;
    float actionDelay = (g_hActionDelay != null) ? g_hActionDelay.FloatValue : 0.0;
    float maxUnbalanceTime = (g_hMaxUnbalanceTime != null) ? g_hMaxUnbalanceTime.FloatValue : 0.0;
    int forceThresholdDelta = (g_hForceThresholdDelta != null) ? g_hForceThresholdDelta.IntValue : 1;
    if (forceThresholdDelta < 0)
    {
        forceThresholdDelta = 0;
    }

    bool forceByThreshold = diff >= (diffThreshold + forceThresholdDelta);
    bool forceByTime = maxUnbalanceTime > 0.0 && imbalanceAge >= maxUnbalanceTime;
    bool forceBalance = forceByThreshold || forceByTime;
    if (!forceBalance && imbalanceAge < actionDelay)
    {
        if (IsBalanceLoggingEnabled())
        {
            LogBalance(
                "Delay balance: diff=%d threshold=%d age=%.1f actionDelay=%.1f forceThreshold=%d maxTime=%.1f",
                diff, diffThreshold, imbalanceAge, actionDelay, diffThreshold + forceThresholdDelta, maxUnbalanceTime
            );
        }
        return Plugin_Continue;
    }

    bool loggingEnabled = IsBalanceLoggingEnabled();
    bool clanProtectionAvailable = (GetFeatureStatus(FeatureType_Native, "Clans_GetSameTeamClanMemberCount") == FeatureStatus_Available);

    char fromTeamName[16];
    char toTeamName[16];
    AB_GetTeamName(biggestTeam,  fromTeamName, sizeof(fromTeamName));
    AB_GetTeamName(smallestTeam, toTeamName,   sizeof(toTeamName));
    char fromTeamChat[24];
    char toTeamChat[24];
    AB_GetTeamChatLabel(biggestTeam,  fromTeamChat, sizeof(fromTeamChat));
    AB_GetTeamChatLabel(smallestTeam, toTeamChat,   sizeof(toTeamChat));

    if (ShouldSkipWinningTeamAutobalance(biggestTeam, smallestTeam, diff))
    {
        if (loggingEnabled)
        {
            LogBalance(
                "Skip balance from %s to %s: sm_autobalance_ignore_winning=%.2f blocked losing-to-winning move at diff=%d",
                fromTeamName, toTeamName, g_hIgnoreWinning.FloatValue, diff
            );
        }
        return Plugin_Continue;
    }

    if (loggingEnabled)
    {
        LogBalance(
            "Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s age=%.1f",
            teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
            fromTeamName, biggestCount, toTeamName, smallestCount,
            forceBalance ? "yes" : "no",
            imbalanceAge
        );
    }
    PrintToServer(
        "[whalebalance] Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s age=%.1f",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no",
        imbalanceAge
    );

    // ------------------------------------------------------------------
    // Candidate selection.
    //
    // Volunteer selection runs before normal candidate filters. Volunteers
    // intentionally bypass autobalance immunity, but still keep Engineer
    // and medic uber protection.
    //
    // By this point diff > threshold, so the balance is always forced.
    // Simple selection uses one scan and picks the most recent eligible
    // player by priority. Weighted selection scans once, then rolls among
    // all eligible candidates with a bias toward lower scores.
    // ------------------------------------------------------------------

    if (!TeamBalance_TryBegin(TeamBalance_Autobalance, TEAM_BALANCE_OPERATION_LEASE, true))
    {
        return Plugin_Continue;
    }

    int totalScore   = 0;
    int totalPlayers = 0;
    float avg = 0.0;
    int pick = 0;
    int candidateCount = 0;
    bool simpleSelection = (g_hSimpleSelection != null && g_hSimpleSelection.BoolValue);
    bool volunteerSelection = false;

    int volunteerNonMedicCount = 0;
    int volunteerMedicCount = 0;
    if (HasCachedVolunteers())
    {
        pick = SelectVolunteerPlayer(biggestTeam, volunteerNonMedicCount, volunteerMedicCount);
    }
    if (pick > 0)
    {
        volunteerSelection = true;
        candidateCount = (volunteerNonMedicCount > 0) ? volunteerNonMedicCount : volunteerMedicCount;

        if (loggingEnabled)
        {
            LogBalance(
                "Volunteer priority on %s: picked %N from %d non-medic and %d medic volunteer candidates",
                fromTeamName, pick, volunteerNonMedicCount, volunteerMedicCount
            );
        }
    }
    else if (simpleSelection)
    {
        pick = SelectPreferredRecentPlayer(biggestTeam, clanProtectionAvailable);
        candidateCount = (pick > 0) ? 1 : 0;
        if (pick <= 0)
        {
            if (loggingEnabled)
            {
                LogBalance("Skip balance on %s: simple selection found no eligible candidates", fromTeamName);
            }
            TeamBalance_FinishOperation(false);
            return Plugin_Continue;
        }
    }
    else
    {
        int candidates[MAXPLAYERS];

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayer(i, biggestTeam, clanProtectionAvailable))
            {
                continue;
            }

            totalScore += GetClientScore(i);
            totalPlayers++;
            candidates[candidateCount++] = i;
        }

        if (totalPlayers == 0)
        {
            if (loggingEnabled)
            {
                int immuneCount = 0;
                for (int i = 1; i <= MaxClients; i++)
                {
                    if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != biggestTeam) continue;
                    if (IsClientImmune(i)) immuneCount++;
                }

                LogBalance(
                    "Skip balance on %s: no eligible players (teamPlayers=%d, immune=%d)",
                    fromTeamName, biggestCount, immuneCount
                );
            }

            TeamBalance_FinishOperation(false);
            return Plugin_Continue;
        }

        avg = float(totalScore) / float(totalPlayers);

        // Weight selection toward lowest-scoring candidates.
        // Build a cumulative-weight array where each candidate's weight is
        // (maxScore - score + 1) so the lowest scorer is most likely.
        int maxScore = 0;
        for (int i = 0; i < candidateCount; i++)
        {
            int s = GetClientScore(candidates[i]);
            if (s > maxScore) maxScore = s;
        }

        int weights[MAXPLAYERS];
        int totalWeight = 0;
        for (int i = 0; i < candidateCount; i++)
        {
            weights[i]   = maxScore - GetClientScore(candidates[i]) + 1;
            totalWeight += weights[i];
        }

        int roll = GetRandomInt(0, totalWeight - 1);
        pick = candidates[0];
        int running = 0;
        for (int i = 0; i < candidateCount; i++)
        {
            running += weights[i];
            if (roll < running)
            {
                pick = candidates[i];
                break;
            }
        }
    }

    if (!ResolveAutobalancePurchaseImmunity(pick, biggestTeam, clanProtectionAvailable, loggingEnabled))
    {
        TeamBalance_FinishOperation(false);
        return Plugin_Continue;
    }

    if (DuelDetection_IsClientInDuel(pick))
    {
        if (loggingEnabled)
        {
            LogBalance("Skip balance on %N: client entered a duel before move", pick);
        }
        TeamBalance_FinishOperation(false);
        return Plugin_Continue;
    }

    if (loggingEnabled)
    {
        LogBalance(
            "Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d simple=%d volunteer=%d",
            pick, GetClientUserId(pick),
            fromTeamName, toTeamName,
            GetClientScore(pick), avg, candidateCount, simpleSelection ? 1 : 0, volunteerSelection ? 1 : 0
        );
    }
    PrintToServer(
        "[whalebalance] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d simple=%d volunteer=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount, simpleSelection ? 1 : 0, volunteerSelection ? 1 : 0
    );

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_MarkAutobalance") == FeatureStatus_Available)
    {
        FilterAlerts_MarkAutobalance(pick);
    }

    if (!TeamBalance_MoveAutobalanceClient(pick, biggestTeam, smallestTeam))
    {
        TeamBalance_FinishOperation(false);
        if (loggingEnabled)
        {
            LogBalance("Skip balance on %N: candidate became invalid before the authoritative move", pick);
        }
        return Plugin_Continue;
    }
    if (volunteerSelection && GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints") == FeatureStatus_Available)
    {
        PointsStore_ApplyBonusPoints(pick, "autobalance_volunteer", true, true, 1.0, 0, 0.0);
    }
    g_fImbalanceDetectedAt = 0.0;
    SaySounds_TryPlayCommand(0, TEAM_MOVE_SAYSOUND, true);

    CPrintToChatAllEx(
        pick,
        "{tomato}[{purple}Gap{tomato}]{default} Sending {teamcolor}%N{default} from %s to %s",
        pick, fromTeamChat, toTeamChat
    );

    char teamColorName[24];
    AB_GetTeamColorName(smallestTeam, teamColorName, sizeof(teamColorName));
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to %s{default}!", teamColorName);

    return Plugin_Continue;
}

static void StopAutobalanceTimer()
{
    if (g_hAutoBalanceTimer == INVALID_HANDLE)
    {
        return;
    }

    KillTimer(g_hAutoBalanceTimer);
    g_hAutoBalanceTimer = INVALID_HANDLE;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool ShouldSuppressAutobalanceForGamemode()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_IsSmallFormatGamemode") != FeatureStatus_Available)
    {
        return false;
    }

    return DGM_IsSmallFormatGamemode();
}

static bool ShouldSkipWinningTeamAutobalance(int fromTeam, int toTeam, int diff)
{
    if (g_hIgnoreWinning == null || g_hIgnoreWinning.FloatValue <= 0.0)
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "DGM_GetObjectiveLeaderTeam") != FeatureStatus_Available)
    {
        return false;
    }

    int winningTeam = DGM_GetObjectiveLeaderTeam();
    int losingTeam = AB_GetOpposingCoreTeam(winningTeam);

    if (losingTeam == 0 || fromTeam != losingTeam || toTeam != winningTeam)
    {
        return false;
    }

    float ignoreWinning = g_hIgnoreWinning.FloatValue;
    if (ignoreWinning > 1.0 && ignoreWinning >= float(diff))
    {
        return false;
    }

    return true;
}

static int AB_GetOpposingCoreTeam(int team)
{
    if (team == TEAM_RED)
    {
        return TEAM_BLUE;
    }

    if (team == TEAM_BLUE)
    {
        return TEAM_RED;
    }

    return 0;
}

static bool IsEligiblePlayer(int client, int team, bool clanProtectionAvailable)
{
    if (!IsBasicBalanceCandidate(client, team)) return false;
    if (IsProtectedBalanceCandidate(client, team, clanProtectionAvailable)) return false;

    return true;
}

static bool IsBasicBalanceCandidate(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (DuelDetection_IsClientInDuel(client)) return false;
    if (TeamBalance_IsRecentlyMoved(client)) return false;
    if (ClientHasDecapitationHeads(client)) return false;

    return true;
}

static bool ClientHasDecapitationHeads(int client)
{
    if (!HasEntProp(client, Prop_Send, "m_iDecapitations"))
    {
        return false;
    }

    int heads = GetEntProp(client, Prop_Send, "m_iDecapitations");
    return heads != 0;
}

static bool IsProtectedBalanceCandidate(int client, int team, bool clanProtectionAvailable)
{
    if (IsMedicWithProtectedUber(client)) return true;
    if (Kogasa_IsEngineerWithBuildings(client)) return true;
    if (IsClientImmune(client)) return true;
    if (HasClanTeammateProtection(client, team, clanProtectionAvailable)) return true;

    return false;
}

static bool IsMedicWithProtectedUber(int client)
{
    if (TF2_GetPlayerClass(client) != TFClass_Medic)
    {
        return false;
    }

    int medigun = GetPlayerWeaponSlot(client, 1);
    if (medigun <= MaxClients || !IsValidEntity(medigun))
    {
        return false;
    }

    if (!HasEntProp(medigun, Prop_Send, "m_flChargeLevel"))
    {
        return false;
    }

    // m_flChargeLevel is normalized: 0.05 is 5% uber.
    return GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel") > MEDIC_AUTOBALANCE_UBER_FLOOR;
}

static bool HasClanTeammateProtection(int client, int team, bool clanProtectionAvailable)
{
    if (!clanProtectionAvailable)
    {
        return false;
    }

    int count = Clans_GetSameTeamClanMemberCount(client, team);
    // Clans returns -1 while its cache/client state is unavailable. Fail open
    // here; treating unknown as protected can block every autobalance candidate.
    return count > 1;
}

static int GetSimpleSelectionPriority(int client)
{
    int priority = 0;

    if (!IsPlayerAlive(client))
    {
        priority += 2;
    }

    if (!Kogasa_IsEngineerWithBuildings(client))
    {
        priority += 1;
    }

    return priority;
}

static int SelectPreferredRecentPlayer(int team, bool clanProtectionAvailable)
{
    int pick = 0;
    int bestPriority = -1;
    int highestUserId = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsBasicBalanceCandidate(i, team)) continue;

        int priority = GetSimpleSelectionPriority(i);
        int currentUserId = GetClientUserId(i);
        if (priority < bestPriority || (priority == bestPriority && currentUserId <= highestUserId))
        {
            continue;
        }

        if (IsProtectedBalanceCandidate(i, team, clanProtectionAvailable))
        {
            continue;
        }

        if (priority > bestPriority || (priority == bestPriority && currentUserId > highestUserId))
        {
            bestPriority = priority;
            highestUserId = currentUserId;
            pick = i;
        }
    }

    return pick;
}

static bool IsVolunteerCandidate(int client, int team)
{
    if (!IsBasicBalanceCandidate(client, team)) return false;
    if (!IsClientVolunteer(client)) return false;
    if (IsClientImmune(client)) return false;
    if (HasAutobalancePurchaseImmunity(client)) return false;
    if (Kogasa_IsEngineerWithBuildings(client)) return false;
    if (IsMedicWithProtectedUber(client)) return false;

    return true;
}

static int SelectVolunteerPlayer(int team, int &nonMedicCount, int &medicCount)
{
    int nonMedics[MAXPLAYERS];
    int medics[MAXPLAYERS];
    nonMedicCount = 0;
    medicCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsVolunteerCandidate(i, team)) continue;

        if (TF2_GetPlayerClass(i) == TFClass_Medic)
        {
            medics[medicCount++] = i;
        }
        else
        {
            nonMedics[nonMedicCount++] = i;
        }
    }

    if (nonMedicCount > 0)
    {
        return nonMedics[GetRandomInt(0, nonMedicCount - 1)];
    }

    if (medicCount > 0)
    {
        return medics[GetRandomInt(0, medicCount - 1)];
    }

    return 0;
}

static bool IsClientImmune(int client)
{
    return IsClientMapImmune(client) || IsClientPersistentlyImmune(client);
}

static bool HasAutobalancePurchaseImmunity(int client)
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

    return PointsStore_HasPurchase(client, POINTS_STORE_AB_IMMUNITY_ITEM);
}

static bool ResolveAutobalancePurchaseImmunity(int &pick, int team, bool clanProtectionAvailable, bool loggingEnabled)
{
    if (!HasAutobalancePurchaseImmunity(pick))
    {
        return true;
    }

    int replacement = SelectAutobalanceReplacementForPass(pick, team, clanProtectionAvailable);
    if (replacement <= 0)
    {
        if (loggingEnabled)
        {
            LogBalance("Skip balance on %N: protected by paid immunity and no replacement was available", pick);
        }
        return false;
    }

    int usesRemaining = PointsStore_ConsumePurchaseUse(pick, POINTS_STORE_AB_IMMUNITY_ITEM);
    CPrintToChat(pick, "{magenta}[Store]{default} You were protected by your {gold}Autobalance Immunity (16 times){default}! Uses remaining: {lightgreen}%d", usesRemaining);
    if (loggingEnabled)
    {
        LogBalance("Paid autobalance immunity protected %N; replacement=%N usesRemaining=%d", pick, replacement, usesRemaining);
    }

    pick = replacement;
    return true;
}

static int SelectAutobalanceReplacementForPass(int protectedClient, int team, bool clanProtectionAvailable)
{
    int bestClient = 0;
    int bestScore = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == protectedClient)
        {
            continue;
        }

        if (!IsEligiblePlayer(i, team, clanProtectionAvailable))
        {
            continue;
        }

        if (HasAutobalancePurchaseImmunity(i))
        {
            continue;
        }

        int score = GetClientScore(i);
        if (bestClient == 0 || score < bestScore)
        {
            bestClient = i;
            bestScore = score;
        }
    }

    return bestClient;
}

static bool IsClientPersistentlyImmune(int client)
{
    if (g_hPersistentImmunity == null || !IsClientInGame(client))
    {
        return false;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        return false;
    }

    int dummy = 0;
    return g_hPersistentImmunity.GetValue(steamId, dummy);
}

static bool IsClientMapImmune(int client)
{
    if (g_hMapImmunity == null || !IsClientInGame(client)) return false;

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        return false;
    }

    int dummy = 0;
    return g_hMapImmunity.GetValue(steamId, dummy);
}

static bool SetClientMapImmunity(int client, bool immune)
{
    if (g_hMapImmunity == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        return false;
    }

    if (immune)
    {
        g_hMapImmunity.SetValue(steamId, 1, true);
    }
    else
    {
        g_hMapImmunity.Remove(steamId);
    }
    return true;
}

static bool IsClientVolunteer(int client)
{
    if (g_hVolunteers == null || !IsClientInGame(client))
    {
        return false;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), true))
    {
        return false;
    }

    int dummy = 0;
    return g_hVolunteers.GetValue(steamId, dummy);
}

static bool HasCachedVolunteers()
{
    return g_bVolunteerDbReady && g_hVolunteers != null && g_iPersistentVolunteerCount > 0;
}

static void SetPersistentVolunteerCache(const char[] steamId, bool volunteer)
{
    if (g_hVolunteers == null || !steamId[0])
    {
        return;
    }

    int existing = 0;
    bool wasVolunteer = g_hVolunteers.GetValue(steamId, existing);

    if (volunteer)
    {
        g_hVolunteers.SetValue(steamId, 1, true);
        if (!wasVolunteer)
        {
            g_iPersistentVolunteerCount++;
        }
    }
    else
    {
        if (wasVolunteer)
        {
            g_hVolunteers.Remove(steamId);
            if (g_iPersistentVolunteerCount > 0)
            {
                g_iPersistentVolunteerCount--;
            }
        }
    }
}

static void ConnectImmunityDatabase()
{
    Db_CancelTimer(g_hImmunityDbReconnectTimer);

    char configName[64];
    g_hDatabaseConfig.GetString(configName, sizeof(configName));
    TrimString(configName);
    if (!configName[0])
    {
        strcopy(configName, sizeof(configName), DB_DEFAULT_CONFIG);
    }

    if (!Db_CheckConfigOrLog("whalebalance", configName))
    {
        return;
    }

    Database.Connect(SQL_OnImmunityDatabaseConnected, configName);
}

static void ScheduleImmunityDatabaseReconnect(float delay = DB_RECONNECT_DELAY)
{
    g_bImmunityDbReady = false;
    g_bVolunteerDbReady = false;
    if (g_hImmunityDbReconnectTimer == null)
    {
        g_hImmunityDbReconnectTimer = CreateTimer(delay, Timer_ReconnectImmunityDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ReconnectImmunityDatabase(Handle timer, any data)
{
    g_hImmunityDbReconnectTimer = null;
    ConnectImmunityDatabase();
    return Plugin_Stop;
}

public void SQL_OnImmunityDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[whalebalance] Immunity DB connection failed: %s", error);
        ScheduleImmunityDatabaseReconnect();
        return;
    }

    if (g_hImmunityDb != null)
    {
        delete g_hImmunityDb;
    }

    g_hImmunityDb = db;
    g_bImmunityDbReady = false;
    g_bVolunteerDbReady = false;
    g_iPersistentVolunteerCount = 0;
    Db_CancelTimer(g_hImmunityDbReconnectTimer);

    if (!g_hImmunityDb.SetCharset("utf8mb4"))
    {
        LogError("[whalebalance] Failed to set utf8mb4 charset");
    }

    g_hImmunityDb.Query(SQL_OnImmunitySchemaReady,
        "CREATE TABLE IF NOT EXISTS autobalance_immunity ("
        ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
        ... "immune TINYINT(1) NOT NULL DEFAULT 1)");
}

public void SQL_OnImmunitySchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[whalebalance] Immunity schema creation failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleImmunityDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    if (g_hPersistentImmunity != null)
    {
        g_hPersistentImmunity.Clear();
    }

    g_hImmunityDb.Query(SQL_OnPersistentImmunityLoaded,
        "SELECT steamid64 FROM autobalance_immunity WHERE immune != 0");

    g_hImmunityDb.Query(SQL_OnVolunteerSchemaReady,
        "CREATE TABLE IF NOT EXISTS autobalance_volunteers ("
        ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
        ... "volunteer TINYINT(1) NOT NULL DEFAULT 1)");
}

public void SQL_OnPersistentImmunityLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[whalebalance] Persistent immunity preload failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleImmunityDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    if (g_hPersistentImmunity == null)
    {
        g_hPersistentImmunity = new StringMap();
    }
    else
    {
        g_hPersistentImmunity.Clear();
    }

    if (results != null)
    {
        char steamId[32];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId, sizeof(steamId));
            TrimString(steamId);
            if (!steamId[0])
            {
                continue;
            }

            g_hPersistentImmunity.SetValue(steamId, 1, true);
        }
    }

    g_bImmunityDbReady = true;
}

public void SQL_OnVolunteerSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[whalebalance] Volunteer schema creation failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleImmunityDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    if (g_hVolunteers != null)
    {
        g_hVolunteers.Clear();
    }
    g_iPersistentVolunteerCount = 0;

    g_hImmunityDb.Query(SQL_OnPersistentVolunteersLoaded,
        "SELECT steamid64 FROM autobalance_volunteers WHERE volunteer != 0");
}

public void SQL_OnPersistentVolunteersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[whalebalance] Persistent volunteer preload failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleImmunityDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    if (g_hVolunteers == null)
    {
        g_hVolunteers = new StringMap();
    }
    else
    {
        g_hVolunteers.Clear();
    }
    g_iPersistentVolunteerCount = 0;

    if (results != null)
    {
        char steamId[32];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId, sizeof(steamId));
            TrimString(steamId);
            if (!steamId[0])
            {
                continue;
            }

            g_hVolunteers.SetValue(steamId, 1, true);
            g_iPersistentVolunteerCount++;
        }
    }

    g_bVolunteerDbReady = true;
}

static void AB_EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    Db_Escape(g_hImmunityDb, input, output, maxlen, "whalebalance");
}

public Action Command_Volunteer(int client, int args)
{
    if (g_hImmunityDb == null || !g_bVolunteerDbReady)
    {
        ReplyToCommand(client, "[whalebalance] Persistent volunteer database is not ready.");
        return Plugin_Handled;
    }

    int target = client;
    bool targetChangedByAdmin = false;

    if (args >= 1)
    {
        if (client > 0 && !CheckCommandAccess(client, "sm_volunteer_target", ADMFLAG_GENERIC, true))
        {
            ReplyToCommand(client, "[whalebalance] Usage: sm_volunteer");
            return Plugin_Handled;
        }

        char targetArg[MAX_TARGET_LENGTH];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);

        target = FindTarget(client, targetArg, true, false);
        if (target <= 0)
        {
            return Plugin_Handled;
        }

        targetChangedByAdmin = (target != client);
    }

    if (target <= 0)
    {
        ReplyToCommand(client, "[whalebalance] Usage: sm_volunteer [client name/substring]");
        return Plugin_Handled;
    }

    if (!IsClientInGame(target) || IsFakeClient(target))
    {
        ReplyToCommand(client, "[whalebalance] Invalid volunteer target.");
        return Plugin_Handled;
    }

    bool wasVolunteer = IsClientVolunteer(target);

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(target, steamId, sizeof(steamId), true))
    {
        ReplyToCommand(client, "[whalebalance] Failed to read SteamID64 for %N.", target);
        return Plugin_Handled;
    }

    char escapedSteam[64];
    AB_EscapeSql(steamId, escapedSteam, sizeof(escapedSteam));

    char query[256];
    if (wasVolunteer)
    {
        FormatEx(query, sizeof(query),
            "DELETE FROM autobalance_volunteers WHERE steamid64 = '%s'",
            escapedSteam);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "REPLACE INTO autobalance_volunteers (steamid64, volunteer) VALUES ('%s', 1)",
            escapedSteam);
    }

    DataPack pack = new DataPack();
    pack.WriteCell((client > 0) ? GetClientUserId(client) : 0);
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(wasVolunteer ? 1 : 0);
    pack.WriteCell(targetChangedByAdmin ? 1 : 0);
    pack.WriteString(steamId);

    g_hImmunityDb.Query(SQL_OnPersistentVolunteerToggled, query, pack);
    return Plugin_Handled;
}

public void SQL_OnPersistentVolunteerToggled(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    bool wasVolunteer = (pack.ReadCell() != 0);
    bool targetChangedByAdmin = (pack.ReadCell() != 0);
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    int actor = (actorUserId > 0) ? GetClientOfUserId(actorUserId) : 0;
    int target = GetClientOfUserId(targetUserId);
    bool nowVolunteer = !wasVolunteer;

    if (error[0])
    {
        if (actorUserId == 0 || (actor > 0 && IsClientInGame(actor)))
        {
            if (actor > 0 && IsClientInGame(actor))
            {
                PrintToChat(actor, "[Autobalance] Failed to toggle volunteer status.");
            }
            else
            {
                ReplyToCommand(actor, "[Autobalance] Failed to toggle volunteer status.");
            }
        }

        LogError("[whalebalance] Persistent volunteer toggle failed for %s: %s", steamId, error);
        if (Db_IsTransientError(error))
        {
            ScheduleImmunityDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    SetPersistentVolunteerCache(steamId, nowVolunteer);

    if (targetChangedByAdmin)
    {
        if (actorUserId == 0 || (actor > 0 && IsClientInGame(actor)))
        {
            if (target > 0 && IsClientInGame(target))
            {
                if (actor > 0 && IsClientInGame(actor))
                {
                    PrintToChat(actor,
                        nowVolunteer
                            ? "[Autobalance] %N is now an autobalance volunteer."
                            : "[Autobalance] %N is no longer an autobalance volunteer.",
                        target);
                }
                else
                {
                    ReplyToCommand(actor,
                        nowVolunteer
                            ? "[Autobalance] %N is now an autobalance volunteer."
                            : "[Autobalance] %N is no longer an autobalance volunteer.",
                        target);
                }
            }
            else
            {
                if (actor > 0 && IsClientInGame(actor))
                {
                    PrintToChat(actor,
                        nowVolunteer
                            ? "[Autobalance] Autobalance volunteer status applied."
                            : "[Autobalance] Autobalance volunteer status removed.");
                }
                else
                {
                    ReplyToCommand(actor,
                        nowVolunteer
                            ? "[Autobalance] Autobalance volunteer status applied."
                            : "[Autobalance] Autobalance volunteer status removed.");
                }
            }
        }

        if (target > 0 && IsClientInGame(target))
        {
            PrintToChat(target,
                nowVolunteer
                    ? "[Autobalance] You are now an autobalance volunteer; use !volunteer to opt out."
                    : "[Autobalance] You are no longer an autobalance volunteer; use !volunteer to opt in.");
        }

        if (actor > 0 && IsClientInGame(actor) && target > 0 && IsClientInGame(target))
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied by %N to %N"
                    : "Volunteer status removed by %N from %N",
                actor, target);
        }
        else if (target > 0 && IsClientInGame(target))
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied by console to %N"
                    : "Volunteer status removed by console from %N",
                target);
        }
        else
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied for %s"
                    : "Volunteer status removed for %s",
                steamId);
        }
        return;
    }

    if (target > 0 && IsClientInGame(target))
    {
        PrintToChat(target,
            nowVolunteer
                ? "[Autobalance] You are now an autobalance volunteer; use !volunteer to opt out."
                : "[Autobalance] You are no longer an autobalance volunteer; use !volunteer to opt in.");
        LogBalance(
            nowVolunteer
                ? "%N volunteered for autobalance"
                : "%N stopped volunteering for autobalance",
            target);
    }
}

public Action Command_Immune(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[whalebalance] Usage: sm_immune <client name/substring>");
        return Plugin_Handled;
    }

    if (g_hImmunityDb == null || !g_bImmunityDbReady)
    {
        ReplyToCommand(client, "[whalebalance] Persistent immunity database is not ready.");
        return Plugin_Handled;
    }

    char targetArg[MAX_TARGET_LENGTH];
    GetCmdArgString(targetArg, sizeof(targetArg));
    TrimString(targetArg);

    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(target, steamId, sizeof(steamId), true))
    {
        ReplyToCommand(client, "[whalebalance] Failed to read SteamID64 for %N.", target);
        return Plugin_Handled;
    }

    bool wasImmune = false;
    if (g_hPersistentImmunity != null)
    {
        int dummy = 0;
        wasImmune = g_hPersistentImmunity.GetValue(steamId, dummy);
    }

    char escapedSteam[64];
    AB_EscapeSql(steamId, escapedSteam, sizeof(escapedSteam));

    char query[256];
    if (wasImmune)
    {
        FormatEx(query, sizeof(query),
            "DELETE FROM autobalance_immunity WHERE steamid64 = '%s'",
            escapedSteam);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "REPLACE INTO autobalance_immunity (steamid64, immune) VALUES ('%s', 1)",
            escapedSteam);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(wasImmune ? 1 : 0);
    pack.WriteString(steamId);

    g_hImmunityDb.Query(SQL_OnPersistentImmunityToggled, query, pack);
    return Plugin_Handled;
}

public void SQL_OnPersistentImmunityToggled(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    bool wasImmune = (pack.ReadCell() != 0);
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    int target = GetClientOfUserId(targetUserId);

    if (error[0])
    {
        if (actor > 0 && IsClientInGame(actor))
        {
            ReplyToCommand(actor, "[whalebalance] Failed to toggle persistent immunity.");
        }

        LogError("[whalebalance] Persistent immunity toggle failed for %s: %s", steamId, error);
        return;
    }

    if (g_hPersistentImmunity != null)
    {
        if (wasImmune)
        {
            g_hPersistentImmunity.Remove(steamId);
        }
        else
        {
            g_hPersistentImmunity.SetValue(steamId, 1, true);
        }
    }

    if (target > 0 && IsClientInGame(target))
    {
        if (wasImmune)
        {
            CPrintToChatAllEx(target, "{lightgreen}[Server]{default} {teamcolor}%N{default} is no longer persistently autobalance-immune.", target);
            LogBalance("Persistent immunity removed by %N from %N", actor, target);
        }
        else
        {
            CPrintToChatAllEx(target, "{lightgreen}[Server]{default} {teamcolor}%N{default} is now persistently autobalance-immune.", target);
            LogBalance("Persistent immunity applied by %N to %N", actor, target);
        }
        return;
    }

    if (actor > 0 && IsClientInGame(actor))
    {
        ReplyToCommand(actor,
            wasImmune
                ? "[whalebalance] Persistent immunity removed."
                : "[whalebalance] Persistent immunity applied.");
    }
}

static bool IsGameTeam(int team)
{
    return team == TEAM_RED || team == TEAM_BLUE || team == TEAM_GREEN || team == TEAM_YELLOW;
}

static int GetClientScore(int client)
{
    return GetClientFrags(client);
}

static void AB_GetTeamName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "RED");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "BLU");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "GREEN");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "YELLOW");
        default:          strcopy(buffer, maxlen, "UNKNOWN");
    }
}

static void AB_GetTeamChatLabel(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}RED{default}");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}BLU{default}");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}GREEN{default}");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}YELLOW{default}");
        default:          strcopy(buffer, maxlen, "{default}UNKNOWN");
    }
}

static void AB_GetTeamColorName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}Red");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}Blue");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}Green");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}Yellow");
        default:          strcopy(buffer, maxlen, "{default}Unknown");
    }
}

static bool IsBalanceLoggingEnabled()
{
    return g_hLogEnabled != null && g_hLogEnabled.BoolValue;
}

static void LogBalance(const char[] fmt, any ...)
{
    if (!IsBalanceLoggingEnabled())
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    char eventName[64];
    DeriveBalanceEventName(buffer, eventName, sizeof(eventName));
    PluginStats_Record(eventName, buffer);
}

static void DeriveBalanceEventName(const char[] message, char[] output, int maxlen)
{
    int start = strncmp(message, "[whalebalance] ", 15, false) == 0 ? 15 : 0;
    if (strncmp(message[start], "Autobalancing ", 14, false) == 0)
    {
        strcopy(output, maxlen, "autobalance_move");
        return;
    }
    if (strncmp(message[start], "Imbalance:", 10, false) == 0)
    {
        strcopy(output, maxlen, "imbalance_detected");
        return;
    }
    if (strncmp(message[start], "Skip balance", 12, false) == 0)
    {
        strcopy(output, maxlen, "balance_skipped");
        return;
    }

    int write = 0;
    for (int read = start; message[read] && write < maxlen - 1; read++)
    {
        char c = message[read];
        if (c == ':' || c == '.' || c == '(')
        {
            break;
        }
        if (c >= 'A' && c <= 'Z')
        {
            c += 32;
        }
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        {
            output[write++] = c;
        }
        else if ((c == ' ' || c == '-' || c == '_') && write > 0 && output[write - 1] != '_')
        {
            output[write++] = '_';
        }
    }
    while (write > 0 && output[write - 1] == '_')
    {
        write--;
    }
    output[write] = '\0';
    if (!output[0])
    {
        strcopy(output, maxlen, "autobalance_event");
    }
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");

    if (g_hMpTeamsUnbalanceLimit == null)
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");

    if (pluginLoaded)
    {
        // Save originals before we overwrite them.
        if (g_hMpAutoteamBalance != null)
        {
            g_iSavedAutoteamBalance = g_hMpAutoteamBalance.IntValue;
            g_hMpAutoteamBalance.IntValue = 0;
        }

        if (g_hMpTeamsUnbalanceLimit != null)
        {
            g_iSavedUnbalanceLimit = g_hMpTeamsUnbalanceLimit.IntValue;
            g_hMpTeamsUnbalanceLimit.IntValue = 1;
        }
    }
    else
    {
        // Restore originals on unload.
        if (g_hMpAutoteamBalance != null)
            g_hMpAutoteamBalance.IntValue = g_iSavedAutoteamBalance;

        if (g_hMpTeamsUnbalanceLimit != null)
            g_hMpTeamsUnbalanceLimit.IntValue = g_iSavedUnbalanceLimit;
    }
}

// ---------------------------------------------------------------------------
// Integrated WhaleScramble vote, automatic-trigger, and ranking subsystem
// ---------------------------------------------------------------------------

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
NativeVote g_hVote = null;
ConVar g_hScrambleLogEnabled = null;
ConVar g_hAutoRounds = null;
ConVar g_hVoteTime = null;
ConVar g_hCountBots = null;
ConVar g_hTopSwap = null;
ConVar g_hRandom = null;
ConVar g_hFragBalance = null;
ConVar g_hWhaleRankBalance = null;
ConVar g_hStackRedPayload = null;
ConVar g_hDisableTfAuto = null;
ConVar g_hShortRoundAutoSeconds = null;
ConVar g_hKothNoCapAuto = null;
ConVar g_hPayloadStompFirstCapSeconds = null;
ConVar g_hWinStreakAuto = null;
ConVar g_hNoSequentialAuto = null;
ConVar g_hMpScrambleTeamsAuto = null;
int g_iRoundsSinceAuto = 0;
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
bool g_bStackRedPayloadAttempted = false;
int g_iRoundStartTimestamp = 0;

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
#define SCRAMBLE_SETUP_POLISH_DELAY  0.75
#define SCRAMBLE_SETUP_UBER_DELAY  0.25
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_DELAY  0.85
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_REPEAT_DELAY  1.10
#define SCRAMBLE_AUTO_RESPAWN_SWEEP_COUNT  3
#define WHALESCRAMBLE_STATS_DETAIL_MAX 384
void WhaleScramble_OnPluginStart()
{
    UpdateNativeVotes();
    g_hScrambleLogEnabled = CreateConVar("sm_whalescramble_log", "1", "Enable whalescramble debug logging.", _, true, 0.0, true, 1.0);
    LogWhale("Plugin started.");
    g_hAutoRounds = CreateConVar("whalescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("whalescramble_votetime", "4", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hCountBots = CreateConVar("whalescramble_count_bots", "1", "Include bots when selecting whale scramble targets.", _, true, 0.0, true, 1.0);
    g_hTopSwap = CreateConVar("sm_ws_topswap", "0", "Enable topswap scramble mode.", _, true, 0.0, true, 1.0);
    g_hRandom = CreateConVar("sm_ws_random", "1", "Enable random scramble mode.", _, true, 0.0, true, 1.0);
    g_hFragBalance = CreateConVar("sm_ws_frags", "1", "Enable frag-balanced random scramble mode.", _, true, 0.0, true, 1.0);
    g_hWhaleRankBalance = CreateConVar("sm_ws_whaletracker_ranks", "0", "Enable WhaleTracker rank-balanced scramble mode.", _, true, 0.0, true, 1.0);
    g_hStackRedPayload = CreateConVar("whalescramble_stack_red_pl", "1", "Run one RED-favored 60:40 WhaleTracker balance per payload map when setup teams become ready.", _, true, 0.0, true, 1.0);
    g_hDisableTfAuto = CreateConVar("sm_whalescramble_disable_tf_auto", "1", "Disable TF2's built-in mp_scrambleteams_auto while WhaleScramble owns auto scrambles.", _, true, 0.0, true, 1.0);
    g_hShortRoundAutoSeconds = CreateConVar("sm_whalescramble_short_round_seconds", "60", "Automatically whale scramble when the previous round duration is under this many seconds. 0 disables.", _, true, 0.0, true, 600.0);
    g_hKothNoCapAuto = CreateConVar("sm_whalescramble_koth_no_cap", "1", "Automatically whale scramble when a full KOTH round ends with either team never capturing the point.", _, true, 0.0, true, 1.0);
    g_hPayloadStompFirstCapSeconds = CreateConVar("sm_whalescramble_payload_stomp_first_cap_seconds", "100", "Immediately whale scramble when BLU captures the first payload control point within this many seconds. 0 disables.", _, true, 0.0, true, 600.0);
    g_hWinStreakAuto = CreateConVar("sm_whalescramble_win_streak", "2", "Automatically whale scramble after one team wins this many full rounds in a row. 0 disables.", _, true, 0.0, true, 20.0);
    g_hNoSequentialAuto = CreateConVar("sm_whalescramble_no_sequential", "1", "Block auto scrambles from happening in consecutive rounds or more than once in one round.", _, true, 0.0, true, 1.0);
    g_hMpScrambleTeamsAuto = FindConVar("mp_scrambleteams_auto");
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

void WhaleScramble_OnMapStart()
{
    g_bStackRedPayloadAttempted = false;
    ResetVotes();
    ClearAutoScramblePending();
    ApplyEngineScramblePolicy();
    g_iRoundsSinceAuto = 0;
    ResetWinStreakTracking();
    LogWhale("Map start: votes reset; team-balance controller owns runtime state.");
}

void WhaleScramble_OnMapEnd()
{
    ResetVotes();
    ClearAutoScramblePending();
    g_iRoundsSinceAuto = 0;
    ResetWinStreakTracking();
    LogWhale("Map end: votes reset.");
}

void WhaleScramble_OnPluginEnd()
{
    ResetVotes();
    TeamBalance_CancelScramble();
    ClearAutoScramblePending();
    LogWhale("Plugin ended.");
}

void WhaleScramble_OnClientDisconnect(int client)
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

public void DGM_OnSetupTeamRatioReady(int realTeamPlayers, int connectedClients)
{
    if (g_bStackRedPayloadAttempted || g_hStackRedPayload == null || !g_hStackRedPayload.BoolValue)
    {
        return;
    }

    char gamemodeKey[16];
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") != FeatureStatus_Available
        || !DGM_GetGameModeKey(gamemodeKey, sizeof(gamemodeKey))
        || !StrEqual(gamemodeKey, "pl"))
    {
        return;
    }

    g_bStackRedPayloadAttempted = true;
    LogWhale(
        "Payload setup team ratio ready: realTeamPlayers=%d connectedClients=%d; starting RED-favored WhaleTracker balance.",
        realTeamPlayers,
        connectedClients);
    LogWhaleStat(
        "auto_scramble_decision",
        "trigger=setup_team_ratio|result=triggered|mode=whaletracker_rank|favored_team=%d|real_team_players=%d|connected_clients=%d",
        TEAM_RED,
        realTeamPlayers,
        connectedClients);
    StartWhaleRankBalanceScramble(0, false, true, true, TEAM_RED);
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
        TeamBalance_IsScrambleCooldownActive() ? 1 : 0);
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

    if (TeamBalance_IsScrambleCooldownActive())
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

    if (TeamBalance_IsScrambleCooldownActive())
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

    if (!TeamBalance_BeginScrambleVote(float(voteTime)))
    {
        g_hVote.Close();
        g_hVote = null;
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[WhaleScramble]{default} Team balancing is busy; try again in a moment.");
        }
        LogWhale("Vote start failed: authoritative team-balance state is busy.");
        LogWhaleStat("vote_result", "kind=%s|phase=start|result=failed|reason=balance_busy", actionName);
        return false;
    }

    g_bVoteRunning = NativeVotes_DisplayToAll(g_hVote, voteTime);
    if (!g_bVoteRunning)
    {
        TeamBalance_CancelScramble();
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

    if (TeamBalance_IsScrambleCooldownActive())
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
            TeamBalance_EndScrambleVote();
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
            TeamBalance_CancelScramble();
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
                TeamBalance_CancelScramble();
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
                TeamBalance_CancelScramble();
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
                LogWhale("Vote failed: no votes.");
                LogWhaleStat("vote_result", "kind=%s|phase=end|result=failed|reason=no_votes", voteKindName);
                return 0;
            }

            int yesVotes = (param1 == NATIVEVOTES_VOTE_YES) ? votes : (totalVotes - votes);
            float yesPercent = float(yesVotes) / float(totalVotes);

            if (yesPercent < 0.50)
            {
                TeamBalance_CancelScramble();
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
                    if (TeamBalance_BeginScramble(false))
                    {
                        TeamBalance_FinishScramble(true, false);
                        ServerCommand("mp_scrambleteams");
                        SaySounds_TryPlayCommand(0, TEAM_MOVE_SAYSOUND, true);
                        success = true;
                    }
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
                    TeamBalance_CancelScramble();
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
        if (!TeamBalance_IsScrambleCandidate(i, 0, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue)) continue;
        int team = GetClientTeam(i);

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
            if (!TeamBalance_IsScrambleCandidate(i, 0, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue)) continue;
            int team = GetClientTeam(i);

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

    if (!TeamBalance_BeginScramble(forced))
    {
        delete pack;
        NotifyFailure(issuer, broadcastFailures, "Team balancing is busy; try again in a moment.");
        LogWhale("Topswap scramble aborted: authoritative team-balance state is busy.");
        return false;
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
        if (!TeamBalance_IsScrambleCandidate(i, 0, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue)) continue;
        int team = GetClientTeam(i);
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
            if (!TeamBalance_IsScrambleCandidate(i, 0, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue)) continue;
            int team = GetClientTeam(i);

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

    if (!TeamBalance_BeginScramble(forced))
    {
        delete pack;
        NotifyFailure(issuer, broadcastFailures, "Team balancing is busy; try again in a moment.");
        LogWhale("Random scramble aborted: authoritative team-balance state is busy.");
        return false;
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
        // Score accounting includes recently moved/immune players because they
        // still contribute to their team's total; the controller filters the
        // actual candidate pool below.
        if (!IsClientInGame(i)
            || (IsFakeClient(i) && (g_hCountBots == null || !g_hCountBots.BoolValue))
            || DuelDetection_IsClientInDuel(i))
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

        if (!TeamBalance_IsScrambleCandidate(i, team, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue))
            continue;
        if (scoreKind == ScrambleScore_WhaleRank && IsWhaleRankBalanceIgnoredClass(i))
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
            if (!TeamBalance_IsScrambleCandidate(i, 0, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue))
                continue;
            int team = GetClientTeam(i);
            if (scoreKind == ScrambleScore_WhaleRank && IsWhaleRankBalanceIgnoredClass(i))
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

    if (!TeamBalance_BeginScramble(forced))
    {
        delete pack;
        NotifyFailure(issuer, broadcastFailures, "Team balancing is busy; try again in a moment.");
        LogWhale("%s scramble aborted: authoritative team-balance state is busy.", modeLabel);
        return false;
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
    bool allowBots = g_hCountBots != null && g_hCountBots.BoolValue;
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

        if (!TeamBalance_MoveScramblePair(r, b, ignoreImmunity, allowBots, suppressRespawn))
        {
            LogWhale("Skipping scramble pair: authoritative validation rejected red=%N blu=%N.", r, b);
            LogWhaleStat("scramble_pair", "result=rejected|reason=controller_validation|mode=%s", scrambleMode);
            continue;
        }

        if (pairCount < MAX_SWAP_BUFFER)
        {
            pairR[pairCount] = r;
            pairB[pairCount] = b;
            pairCount++;
        }
    }

    moved = pairCount * 2;
    if (moved > 0)
    {
        TeamBalance_FinishScramble(true);
        g_bScrambledThisRound = true;
        ResetSurrenderVotes("whalescramble_execute");
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
        TeamBalance_FinishScramble(false);
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

        if (TeamBalance_QueueRespawn(i, team))
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

static bool IsWhaleRankBalanceIgnoredClass(int client)
{
    TFClassType playerClass = TF2_GetPlayerClass(client);
    return playerClass == TFClass_Medic || playerClass == TFClass_Engineer;
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

    int usesRemaining = TeamBalance_ConsumeScramblePurchaseImmunity(client);
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

        if (!TeamBalance_IsScrambleCandidate(i, team, ignoreImmunity, g_hCountBots != null && g_hCountBots.BoolValue))
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

static bool HasScramblePurchaseImmunity(int client)
{
    return TeamBalance_HasScramblePurchaseImmunity(client);
}

static void LogWhale(const char[] fmt, any ...)
{
    if (g_hScrambleLogEnabled == null || !g_hScrambleLogEnabled.BoolValue)
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
