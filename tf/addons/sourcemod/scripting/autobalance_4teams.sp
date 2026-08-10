#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

#include <sdktools>

#include <tf2_stocks>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <clans_api>
#include <filters_api>
#include <points_store_api>
#include <saysounds>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/database.inc"
#include "include/duel_detection.inc"
#include "include/steam_identity.inc"
#include "include/buildings.inc"
#include "include/statistics.inc"

native int FilterAlerts_MarkAutobalance(int client);

#define CHECK_INTERVAL      3.0
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

StringMap g_hMapImmunity = null;            // SteamID64 set for map-long immunity.
StringMap g_hPersistentImmunity = null;     // SteamID64 set for persistent admin immunity.
StringMap g_hVolunteers = null;             // SteamID64 set for persistent autobalance volunteers.
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

public Plugin myinfo =
{
    name        = "autobalance_4teams",
    author      = "Hombre, AW 'Swixel' Stanley",
    description = "Moves players when 4 teams are imbalanced.",
    version     = "1.3",
    url         = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("autobalance_4teams");
    CreateNative("Autobalance_HasPendingTeamSwap", Native_HasPendingTeamSwap);
    MarkNativeAsOptional("FilterAlerts_MarkAutobalance");
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
    MarkNativeAsOptional("DGM_GetObjectiveLeaderTeam");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("Filters_GetChatName");
    return APLRes_Success;
}

public any Native_HasPendingTeamSwap(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return HasPendingTeamSwap(client);
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
    char dbConfig[64];
    g_hDatabaseConfig.GetString(dbConfig, sizeof(dbConfig));
    PluginStats_Init("autobalance_statistics_events", dbConfig);
    RegAdminCmd("sm_immune", Command_Immune, ADMFLAG_GENERIC, "sm_immune <name> - Toggle persistent autobalance immunity for a player.");
    RegConsoleCmd("sm_volunteer", Command_Volunteer, "sm_volunteer [name] - Toggle autobalance volunteer status.");
    RegConsoleCmd("sm_swap", Command_RequestTeamSwap, "sm_swap [name] - Request a team swap with an enemy player.");
    RegConsoleCmd("sm_requestswap", Command_RequestTeamSwap, "sm_requestswap [name] - Request a team swap with an enemy player.");
    RegConsoleCmd("sm_sw", Command_RequestTeamSwap, "sm_sw [name] - Request a team swap with an enemy player.");
    RegConsoleCmd("sm_yes", Command_AcceptTeamSwap, "Accept a pending team-swap request.");
    LogBalance("[autobalance_4teams] Plugin started.");
    g_hMapImmunity = new StringMap();
    g_hPersistentImmunity = new StringMap();
    g_hVolunteers = new StringMap();
    ClearAllTeamSwapRequests();

    ApplyServerBalanceCvars(true);
    ConnectImmunityDatabase();
}

public void OnMapStart()
{
    PluginStats_OnMapStart();
    ClearAllTeamSwapRequests();
    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }

    g_hAutoBalanceTimer = CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT);

    if (g_hMapImmunity != null)
    {
        g_hMapImmunity.Clear();
    }
}

public void OnMapEnd()
{
    ClearAllTeamSwapRequests();
}

public void OnClientDisconnect(int client)
{
    ClearTeamSwapRequestsForClient(client);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);
    DuelDetection_Shutdown();
    ClearAllTeamSwapRequests();

    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }

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

    PluginStats_Shutdown();
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

    bool senderWasAlive = IsPlayerAlive(sender);
    bool targetWasAlive = IsPlayerAlive(client);
    ChangeClientTeam(sender, targetTeam);
    ChangeClientTeam(client, senderTeam);
    if (senderWasAlive)
    {
        TF2_RespawnPlayer(sender);
    }
    if (targetWasAlive)
    {
        TF2_RespawnPlayer(client);
    }

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

public Action Timer_Autobalance(Handle timer)
{
    if (ShouldSuppressAutobalanceForGamemode())
    {
        return Plugin_Continue;
    }

    int teamCounts[6];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
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
        "[autobalance_4teams] Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s age=%.1f",
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
        return Plugin_Continue;
    }

    if (DuelDetection_IsClientInDuel(pick))
    {
        if (loggingEnabled)
        {
            LogBalance("Skip balance on %N: client entered a duel before move", pick);
        }
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
        "[autobalance_4teams] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d simple=%d volunteer=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount, simpleSelection ? 1 : 0, volunteerSelection ? 1 : 0
    );

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_MarkAutobalance") == FeatureStatus_Available)
    {
        FilterAlerts_MarkAutobalance(pick);
    }

    ChangeClientTeam(pick, smallestTeam);
    TF2_RespawnPlayer(pick);
    if (volunteerSelection && GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints") == FeatureStatus_Available)
    {
        PointsStore_ApplyBonusPoints(pick, "autobalance_volunteer", true, true, 1.0, 0, 0.0);
    }
    SetClientMapImmunity(pick, true);
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

    if (!Db_CheckConfigOrLog("autobalance_4teams", configName))
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
        LogError("[autobalance_4teams] Immunity DB connection failed: %s", error);
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
        LogError("[autobalance_4teams] Failed to set utf8mb4 charset");
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
        LogError("[autobalance_4teams] Immunity schema creation failed: %s", error);
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
        LogError("[autobalance_4teams] Persistent immunity preload failed: %s", error);
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
        LogError("[autobalance_4teams] Volunteer schema creation failed: %s", error);
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
        LogError("[autobalance_4teams] Persistent volunteer preload failed: %s", error);
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
    Db_Escape(g_hImmunityDb, input, output, maxlen, "autobalance_4teams");
}

public Action Command_Volunteer(int client, int args)
{
    if (g_hImmunityDb == null || !g_bVolunteerDbReady)
    {
        ReplyToCommand(client, "[autobalance_4teams] Persistent volunteer database is not ready.");
        return Plugin_Handled;
    }

    int target = client;
    bool targetChangedByAdmin = false;

    if (args >= 1)
    {
        if (client > 0 && !CheckCommandAccess(client, "sm_volunteer_target", ADMFLAG_GENERIC, true))
        {
            ReplyToCommand(client, "[autobalance_4teams] Usage: sm_volunteer");
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
        ReplyToCommand(client, "[autobalance_4teams] Usage: sm_volunteer [client name/substring]");
        return Plugin_Handled;
    }

    if (!IsClientInGame(target) || IsFakeClient(target))
    {
        ReplyToCommand(client, "[autobalance_4teams] Invalid volunteer target.");
        return Plugin_Handled;
    }

    bool wasVolunteer = IsClientVolunteer(target);

    char steamId[32];
    if (!Kogasa_GetClientSteamId64(target, steamId, sizeof(steamId), true))
    {
        ReplyToCommand(client, "[autobalance_4teams] Failed to read SteamID64 for %N.", target);
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

        LogError("[autobalance_4teams] Persistent volunteer toggle failed for %s: %s", steamId, error);
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
        ReplyToCommand(client, "[autobalance_4teams] Usage: sm_immune <client name/substring>");
        return Plugin_Handled;
    }

    if (g_hImmunityDb == null || !g_bImmunityDbReady)
    {
        ReplyToCommand(client, "[autobalance_4teams] Persistent immunity database is not ready.");
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
        ReplyToCommand(client, "[autobalance_4teams] Failed to read SteamID64 for %N.", target);
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
            ReplyToCommand(actor, "[autobalance_4teams] Failed to toggle persistent immunity.");
        }

        LogError("[autobalance_4teams] Persistent immunity toggle failed for %s: %s", steamId, error);
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
                ? "[autobalance_4teams] Persistent immunity removed."
                : "[autobalance_4teams] Persistent immunity applied.");
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
    PluginStats_LogMessage(buffer);
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
