#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>
#include <adt_array>
#undef REQUIRE_PLUGIN
#include <points_store_api>
#include "include/dgm_api.inc"
#define REQUIRE_PLUGIN
#include "include/plugin_statistics.inc"
#include "include/kogasa_sql.inc"

// Configuration locations
#define VOTEMENU_CONFIG      "configs/votemenu.cfg"
#define VOTEMENU_CFG_PREFIX  ""          // Files are expected to be relative to tf/cfg

#define VOTEMENU_CURRENCY_SHORT_MAX 32
#define VOTEMENU_DB_CONFIG_DEFAULT "default"
#define POINTS_STORE_BALANCE_TABLE "points_store_balances"
#define VOTEMENU_STATISTICS_TABLE "votemenu_statistics_events"

enum struct VoteOption
{
    char id[64];
    char name[128];
    char announcer[128];
    char message[256];
    char winFile[128];
    char loseFile[128];
    float ratio;
}

ArrayList g_VoteOptions = null;
VoteOption g_CurrentVote;
bool g_VoteInProgress = false;
bool g_VoteOutcomePending = false;
ConVar g_CvarShop = null;
ConVar g_CvarShopCost = null;
ConVar g_CvarAdmins = null;
ConVar g_CvarAdminsFree = null;
ConVar g_CvarDatabase = null;
ConVar g_CvarVoteDuration = null;
Database g_Database = null;
bool g_DatabaseReady = false;
Handle g_hDatabaseReconnectTimer = null;
bool g_PendingVoteCharge = false;
int g_PendingChargeUserId = 0;
int g_PendingChargeCost = 0;
char g_PendingChargeSteamId64[32];
char g_PendingChargeName[MAX_NAME_LENGTH];
int g_MapStartedAt = 0;
int g_CurrentVoteInitiatorUserId = 0;
char g_CurrentVoteInitiatorSteamId64[32];
char g_CurrentVoteInitiatorName[MAX_NAME_LENGTH];

public Plugin myinfo =
{
    name = "Vote Menu",
    author = "Codex",
    description = "Config-driven yes/no vote executor",
    version = "1.0.0"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("PointsStore_AreBonusPointsLoaded");
    MarkNativeAsOptional("PointsStore_GetBonusPoints");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegConsoleCmd("sm_votemenu", Command_VoteMenu, "Open the vote menu");
    g_CvarShop = CreateConVar("sm_votemenu_shop", "1", "Require points_store currency to start a votemenu vote when points_store is available.", _, true, 0.0, true, 1.0);
    g_CvarShopCost = CreateConVar("sm_votemenu_shop_cost", "50", "points_store currency cost to start a votemenu vote. 0 disables currency integration.", _, true, 0.0);
    g_CvarAdmins = CreateConVar("sm_votemenu_admins_only", "0", "Restrict votemenu usage to admins.", _, true, 0.0, true, 1.0);
    g_CvarAdminsFree = CreateConVar("sm_votemenu_admins_free", "0", "Let admins use votemenu without points_store currency integration.", _, true, 0.0, true, 1.0);
    g_CvarDatabase = CreateConVar("sm_votemenu_database", VOTEMENU_DB_CONFIG_DEFAULT, "Database config used for offline paid-vote charges.");
    g_CvarVoteDuration = CreateConVar("sm_votemenu_duration", "7.0", "Vote menu vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_CvarDatabase.AddChangeHook(OnVoteMenuDatabaseChanged);
    g_VoteOptions = new ArrayList(sizeof(VoteOption));
    g_MapStartedAt = GetTime();
    PluginStats_Init(VOTEMENU_STATISTICS_TABLE);
    LoadVoteMenuConfig();
    ConnectVoteMenuDatabase();
}

public void OnPluginEnd()
{
    PluginStats_Shutdown();
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_Database, g_DatabaseReady);
}

public void OnMapStart()
{
    g_MapStartedAt = GetTime();
    PluginStats_OnMapStart();
    LoadVoteMenuConfig();
    ClearCurrentVoteInitiator();
}

public Action Command_VoteMenu(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (AreVoteMenuAdminsRequired() && !IsVoteMenuAdmin(client))
    {
        CPrintToChat(client, "{red}[Vote]{default} You do not have access to the vote menu.");
        return Plugin_Handled;
    }

    if (IsVoteMenuBusy() || !IsNewVoteAllowed())
    {
        CPrintToChat(client, "{red}[Vote]{default} A vote is already running or cooling down.");
        return Plugin_Handled;
    }

    if (g_VoteOptions.Length == 0)
    {
        CPrintToChat(client, "{red}[Vote]{default} No vote options are configured.");
        return Plugin_Handled;
    }

    Menu menu = new Menu(VoteMenuHandler);
    char title[128];
    FormatVoteMenuTitle(client, title, sizeof(title));
    menu.SetTitle("%s", title);
    char label[256];
    VoteOption opt;
    for (int i = 0; i < g_VoteOptions.Length; i++)
    {
        g_VoteOptions.GetArray(i, opt);
        char display[256];
        if (opt.name[0])
        {
            strcopy(display, sizeof(display), opt.name);
        }
        else if (opt.message[0])
        {
            strcopy(display, sizeof(display), opt.message);
        }
        else
        {
            strcopy(display, sizeof(display), opt.id);
        }

        Format(label, sizeof(label), "%s", display);
        menu.AddItem(opt.id, label);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int VoteMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char itemId[64];
        menu.GetItem(param2, itemId, sizeof(itemId));
        int index = FindVoteIndex(itemId);
        if (index == -1)
        {
            CPrintToChat(param1, "{red}[Vote]{default} Invalid vote option.");
            return 0;
        }

        if (IsVoteMenuBusy() || !IsNewVoteAllowed())
        {
            CPrintToChat(param1, "{red}[Vote]{default} A vote is already running or cooling down.");
            return 0;
        }

        if (!PrepareVoteMenuCharge(param1))
        {
            return 0;
        }

        g_VoteOptions.GetArray(index, g_CurrentVote);
        if (!StartYesNoVote(param1))
        {
            ClearPendingVoteCharge();
            ClearCurrentVoteInitiator();
        }
    }
    return 0;
}

public void OnVoteMenuDatabaseChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ConnectVoteMenuDatabase();
}

public void SQL_OnVoteMenuDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        g_DatabaseReady = false;
        LogError("[votemenu] Database connection failed: %s", error[0] ? error : "unknown error");
        ScheduleVoteMenuDatabaseReconnect();
        return;
    }

    if (g_Database != null)
    {
        delete g_Database;
    }

    g_Database = view_as<Database>(hndl);
    g_DatabaseReady = true;
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
}

static void ConnectVoteMenuDatabase()
{
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_Database, g_DatabaseReady);

    char dbConfig[64];
    if (g_CvarDatabase != null)
    {
        g_CvarDatabase.GetString(dbConfig, sizeof(dbConfig));
        TrimString(dbConfig);
    }
    if (!dbConfig[0])
    {
        strcopy(dbConfig, sizeof(dbConfig), VOTEMENU_DB_CONFIG_DEFAULT);
    }

    if (!KogasaSql_CheckConfigOrLog("votemenu", dbConfig))
    {
        return;
    }

    SQL_TConnect(SQL_OnVoteMenuDatabaseConnected, dbConfig);
}

static void ScheduleVoteMenuDatabaseReconnect(float delay = KOGASA_SQL_RECONNECT_DELAY)
{
    g_DatabaseReady = false;
    if (g_hDatabaseReconnectTimer == null)
    {
        g_hDatabaseReconnectTimer = CreateTimer(delay, Timer_ReconnectVoteMenuDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ReconnectVoteMenuDatabase(Handle timer, any data)
{
    g_hDatabaseReconnectTimer = null;
    ConnectVoteMenuDatabase();
    return Plugin_Stop;
}

static bool IsVoteMenuBusy()
{
    return g_VoteInProgress || g_VoteOutcomePending;
}

static bool IsPointsStoreAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available;
}

static bool IsVoteMenuAdmin(int client)
{
    return client > 0 && CheckCommandAccess(client, "sm_votemenu", ADMFLAG_GENERIC, true);
}

static bool AreVoteMenuAdminsRequired()
{
    return g_CvarAdmins != null && g_CvarAdmins.BoolValue;
}

static bool AreVoteMenuAdminsFree()
{
    return g_CvarAdminsFree != null && g_CvarAdminsFree.BoolValue;
}

static int GetVoteMenuCost()
{
    if (g_CvarShopCost == null)
    {
        return 0;
    }

    int cost = g_CvarShopCost.IntValue;
    return cost > 0 ? cost : 0;
}

static void GetVoteMenuCurrencyShort(char[] buffer, int maxlen)
{
    ConVar currency = FindConVar("sm_points_store_currency_short");
    if (currency == null)
    {
        strcopy(buffer, maxlen, "BP");
        return;
    }

    currency.GetString(buffer, maxlen);
    TrimString(buffer);
    if (buffer[0] == '\0')
    {
        strcopy(buffer, maxlen, "BP");
    }
}

static bool IsVoteMenuShopEnabled(int client)
{
    if (AreVoteMenuAdminsFree() && IsVoteMenuAdmin(client))
    {
        return false;
    }

    return g_CvarShop != null && g_CvarShop.BoolValue && GetVoteMenuCost() > 0 && IsPointsStoreAvailable();
}

static void FormatVoteMenuTitle(int client, char[] title, int maxlen)
{
    if (!IsVoteMenuShopEnabled(client))
    {
        strcopy(title, maxlen, "Start a vote");
        return;
    }

    char currency[VOTEMENU_CURRENCY_SHORT_MAX];
    GetVoteMenuCurrencyShort(currency, sizeof(currency));
    Format(title, maxlen, "Start a vote (%d %s)", GetVoteMenuCost(), currency);
}

static bool PrepareVoteMenuCharge(int client)
{
    ClearPendingVoteCharge();

    if (!IsVoteMenuShopEnabled(client))
    {
        return true;
    }

    int cost = GetVoteMenuCost();
    if (!KogasaSql_IsReady(g_Database, g_DatabaseReady))
    {
        CPrintToChat(client, "{red}[Vote]{default} Vote payments are not ready yet.");
        ConnectVoteMenuDatabase();
        return false;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
    {
        CPrintToChat(client, "{red}[Vote]{default} Could not read your SteamID64 for the vote charge.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && !PointsStore_AreBonusPointsLoaded(client))
    {
        CPrintToChat(client, "{red}[Vote]{default} Your store balance is still loading.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available)
    {
        int balance = PointsStore_GetBonusPoints(client);
        if (balance < cost)
        {
            char currency[VOTEMENU_CURRENCY_SHORT_MAX];
            GetVoteMenuCurrencyShort(currency, sizeof(currency));
            CPrintToChat(client, "{red}[Vote]{default} Starting a vote costs {gold}%d %s{default}; your balance is {lightgreen}%d %s{default}.", cost, currency, balance, currency);
            return false;
        }
    }

    g_PendingVoteCharge = true;
    g_PendingChargeUserId = GetClientUserId(client);
    g_PendingChargeCost = cost;
    strcopy(g_PendingChargeSteamId64, sizeof(g_PendingChargeSteamId64), steamId);
    GetClientName(client, g_PendingChargeName, sizeof(g_PendingChargeName));
    return true;
}

static bool StartYesNoVote(int initiator)
{
    if (IsVoteMenuBusy() || !IsNewVoteAllowed())
    {
        CPrintToChat(initiator, "{red}[Vote]{default} A vote is already running or cooling down.");
        return false;
    }

    CaptureCurrentVoteInitiator(initiator);

    char startMsg[384];
    char announcer[128];
    char detail[256];
    if (g_CurrentVote.announcer[0] != '\0')
    {
        strcopy(announcer, sizeof(announcer), g_CurrentVote.announcer);
    }
    else
    {
        strcopy(announcer, sizeof(announcer), "{green}Someone");
    }
    if (g_CurrentVote.message[0] != '\0')
    {
        strcopy(detail, sizeof(detail), g_CurrentVote.message);
    }
    else
    {
        strcopy(detail, sizeof(detail), g_CurrentVote.id);
    }

    if (StrContains(detail, "has started ", false) == 0)
    {
        ReplaceStringEx(detail, sizeof(detail), "has started ", "started ", -1, -1, false);
    }

    Format(startMsg, sizeof(startMsg), "%s {default}%s Required: {gold}%d%%{default}", announcer, detail, GetVoteRequiredPercent(g_CurrentVote.ratio));
    CPrintToChatAll("%s", startMsg);
    LogVoteMenuVoteStarted(initiator, detail);

    Menu vote = new Menu(YesNoVoteHandler, MENU_ACTIONS_ALL);
    char title[256];
    if (g_CurrentVote.name[0])
    {
        strcopy(title, sizeof(title), g_CurrentVote.name);
    }
    else
    {
        strcopy(title, sizeof(title), detail);
    }
    vote.SetTitle("Vote: %s", title);
    vote.AddItem("yes", "Yes");
    vote.AddItem("no", "No");
    vote.ExitButton = false;
    vote.ExitBackButton = false;

    int voteDuration = RoundToNearest(g_CvarVoteDuration.FloatValue);
    if (!vote.DisplayVoteToAll(voteDuration))
    {
        delete vote;
        LogVoteMenuVoteCancelled("display_failed", 0, 0, 0);
        ClearCurrentVoteInitiator();
        return false;
    }

    g_VoteInProgress = true;
    return true;
}

public int YesNoVoteHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        g_VoteInProgress = false;
        delete menu;
    }
    else if (action == MenuAction_VoteEnd)
    {
        int winningVotes, totalVotes;
        GetMenuVoteInfo(param2, winningVotes, totalVotes);

        char info[8];
        menu.GetItem(param1, info, sizeof(info));

        int yesVotes = 0;
        int noVotes = 0;
        if (StrEqual(info, "yes"))
        {
            yesVotes = winningVotes;
            noVotes = totalVotes - winningVotes;
        }
        else
        {
            noVotes = winningVotes;
            yesVotes = totalVotes - winningVotes;
        }

        float ratio = (totalVotes > 0) ? float(yesVotes) / float(totalVotes) : 0.0;
        bool passed = (totalVotes > 0) && (ratio >= g_CurrentVote.ratio);

        LogVoteMenuVoteResult(passed ? "passed" : "failed", yesVotes, noVotes, totalVotes, ratio);
        AnnounceVoteResult(yesVotes, noVotes, ratio, passed);
        if (passed)
        {
            ChargePassedVoteAndExecuteOutcome();
        }
        else
        {
            ClearPendingVoteCharge();
            ExecuteVoteOutcome(false);
        }
    }
    else if (action == MenuAction_VoteCancel)
    {
        g_VoteInProgress = false;
        ClearPendingVoteCharge();
        int reason = param1;
        if (reason == VoteCancel_NoVotes)
        {
            LogVoteMenuVoteCancelled("no_votes", 0, 0, 0);
            CPrintToChatAll("{red}[Vote]{default} Vote failed: no votes received.");
        }
        else
        {
            LogVoteMenuVoteCancelled("cancelled", reason, 0, 0);
            CPrintToChatAll("{red}[Vote]{default} Vote cancelled.");
        }
        ClearCurrentVoteInitiator();
    }
    return 0;
}

static void ChargePassedVoteAndExecuteOutcome()
{
    if (!g_PendingVoteCharge)
    {
        ExecuteVoteOutcome(true);
        return;
    }

    int client = GetClientOfUserId(g_PendingChargeUserId);
    if (client > 0 && IsClientInGame(client) && IsPendingChargeClient(client) && IsPointsStoreAvailable())
    {
        if (!PointsStore_SpendBonusPoints(client, g_PendingChargeCost))
        {
            AnnounceVoteChargeFailure("payment could not be collected");
            ClearPendingVoteCharge();
            return;
        }

        char currency[VOTEMENU_CURRENCY_SHORT_MAX];
        GetVoteMenuCurrencyShort(currency, sizeof(currency));
        CPrintToChat(client, "{green}[Vote]{default} Vote passed; spent {gold}%d %s{default}.", g_PendingChargeCost, currency);
        ClearPendingVoteCharge();
        ExecuteVoteOutcome(true);
        ClearCurrentVoteInitiator();
        return;
    }

    ChargeOfflinePendingVoteAndExecute();
}

static bool IsPendingChargeClient(int client)
{
    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
    {
        return false;
    }

    return StrEqual(steamId, g_PendingChargeSteamId64, false);
}

static void ChargeOfflinePendingVoteAndExecute()
{
    if (!g_DatabaseReady || g_Database == null)
    {
        AnnounceVoteChargeFailure("payment database is unavailable");
        ClearPendingVoteCharge();
        ConnectVoteMenuDatabase();
        return;
    }

    char escapedSteamId[65];
    if (!EscapeVoteMenuSql(g_PendingChargeSteamId64, escapedSteamId, sizeof(escapedSteamId)))
    {
        AnnounceVoteChargeFailure("payment identity could not be escaped");
        ClearPendingVoteCharge();
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteString(g_CurrentVote.winFile);
    pack.WriteString(g_PendingChargeSteamId64);
    pack.WriteString(g_PendingChargeName);
    pack.WriteCell(g_PendingChargeCost);

    char query[512];
    Format(query, sizeof(query),
        "UPDATE %s SET balance = balance - %d WHERE steamid64 = '%s' AND balance >= %d",
        POINTS_STORE_BALANCE_TABLE,
        g_PendingChargeCost,
        escapedSteamId,
        g_PendingChargeCost);

    g_VoteOutcomePending = true;
    ClearPendingVoteCharge();
    g_Database.Query(SQL_OnOfflineVoteChargeComplete, query, pack);
}

public void SQL_OnOfflineVoteChargeComplete(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char winFile[128];
    char steamId[32];
    char playerName[MAX_NAME_LENGTH];
    pack.ReadString(winFile, sizeof(winFile));
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(playerName, sizeof(playerName));
    int cost = pack.ReadCell();
    delete pack;

    g_VoteOutcomePending = false;

    if (error[0] != '\0')
    {
        LogError("[votemenu] Offline vote charge failed for %s: %s", steamId, error);
        AnnounceVoteChargeFailure("payment query failed");
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        char currency[VOTEMENU_CURRENCY_SHORT_MAX];
        GetVoteMenuCurrencyShort(currency, sizeof(currency));
        CPrintToChatAll("{red}[Vote]{default} Vote passed, but {gold}%s{default} could not be charged {gold}%d %s{default}; no action was taken.", playerName, cost, currency);
        ClearCurrentVoteInitiator();
        return;
    }

    char currency[VOTEMENU_CURRENCY_SHORT_MAX];
    GetVoteMenuCurrencyShort(currency, sizeof(currency));
    CPrintToChatAll("{green}[Vote]{default} Charged {gold}%s{default} {gold}%d %s{default} for the passed vote.", playerName, cost, currency);
    ExecuteVoteScript(winFile);
    ClearCurrentVoteInitiator();
}

static void AnnounceVoteChargeFailure(const char[] reason)
{
    CPrintToChatAll("{red}[Vote]{default} Vote passed, but %s; no action was taken.", reason);
    ClearCurrentVoteInitiator();
}

static void ClearPendingVoteCharge()
{
    g_PendingVoteCharge = false;
    g_PendingChargeUserId = 0;
    g_PendingChargeCost = 0;
    g_PendingChargeSteamId64[0] = '\0';
    g_PendingChargeName[0] = '\0';
}

static bool EscapeVoteMenuSql(const char[] input, char[] output, int maxlen)
{
    if (g_Database == null)
    {
        strcopy(output, maxlen, input);
        return false;
    }

    int written = 0;
    return g_Database.Escape(input, output, maxlen, written);
}

static void AnnounceVoteResult(int yesVotes, int noVotes, float ratio, bool passed)
{
    char buffer[192];
    Format(buffer, sizeof(buffer), "{green}Yes{default}: %d  {red}No{default}: %d  ({gold}%.0f%% yes{default})", yesVotes, noVotes, ratio * 100.0);
    CPrintToChatAll("%s", buffer);

    if (passed)
    {
        CPrintToChatAll("{green}[Vote]{default} Vote passed.");
    }
    else
    {
        CPrintToChatAll("{red}[Vote]{default} Vote failed.");
    }
}

static int GetVoteRequiredPercent(float ratio)
{
    if (ratio < 0.0)
    {
        ratio = 0.0;
    }
    else if (ratio > 1.0)
    {
        ratio = 1.0;
    }

    return RoundToCeil((ratio * 100.0) - 0.001);
}

static void ExecuteVoteOutcome(bool passed)
{
    char script[128];
    if (passed)
    {
        strcopy(script, sizeof(script), g_CurrentVote.winFile);
    }
    else
    {
        strcopy(script, sizeof(script), g_CurrentVote.loseFile);
    }

    if (!script[0])
    {
        ClearCurrentVoteInitiator();
        return;
    }

    ExecuteVoteScript(script);
    ClearCurrentVoteInitiator();
}

static void ExecuteVoteScript(const char[] script)
{
    if (!script[0])
    {
        return;
    }

    char cmd[192];
    Format(cmd, sizeof(cmd), "exec %s%s", VOTEMENU_CFG_PREFIX, script);
    ServerCommand("%s", cmd);
}

static void CaptureCurrentVoteInitiator(int client)
{
    g_CurrentVoteInitiatorUserId = GetClientUserId(client);
    g_CurrentVoteInitiatorSteamId64[0] = '\0';
    g_CurrentVoteInitiatorName[0] = '\0';

    GetClientAuthId(client, AuthId_SteamID64, g_CurrentVoteInitiatorSteamId64, sizeof(g_CurrentVoteInitiatorSteamId64), true);
    GetClientName(client, g_CurrentVoteInitiatorName, sizeof(g_CurrentVoteInitiatorName));
}

static void ClearCurrentVoteInitiator()
{
    g_CurrentVoteInitiatorUserId = 0;
    g_CurrentVoteInitiatorSteamId64[0] = '\0';
    g_CurrentVoteInitiatorName[0] = '\0';
}

static int GetVoteMenuMapElapsedSeconds()
{
    int now = GetTime();
    if (g_MapStartedAt <= 0 || now < g_MapStartedAt)
    {
        return 0;
    }

    return now - g_MapStartedAt;
}

static void SanitizeVoteMenuStatsField(const char[] input, char[] output, int maxlen)
{
    int pos = 0;
    for (int i = 0; input[i] != '\0' && pos < maxlen - 1; i++)
    {
        char c = input[i];
        if (c == '|' || c == '\n' || c == '\r' || c == '\t')
        {
            c = ' ';
        }

        output[pos++] = c;
    }
    output[pos] = '\0';
    TrimString(output);
}

static void GetCurrentVoteStatsFields(char[] optionId, int optionIdLen, char[] optionName, int optionNameLen)
{
    SanitizeVoteMenuStatsField(g_CurrentVote.id, optionId, optionIdLen);
    if (g_CurrentVote.name[0])
    {
        SanitizeVoteMenuStatsField(g_CurrentVote.name, optionName, optionNameLen);
        return;
    }
    if (g_CurrentVote.message[0])
    {
        SanitizeVoteMenuStatsField(g_CurrentVote.message, optionName, optionNameLen);
        return;
    }

    strcopy(optionName, optionNameLen, optionId);
}

static void GetCurrentVoteInitiatorStatsFields(char[] steamId, int steamIdLen, char[] playerName, int playerNameLen)
{
    strcopy(steamId, steamIdLen, g_CurrentVoteInitiatorSteamId64);
    SanitizeVoteMenuStatsField(g_CurrentVoteInitiatorName, playerName, playerNameLen);
}

static void LogVoteMenuVoteStarted(int client, const char[] detail)
{
    char optionId[96];
    char optionName[160];
    char playerName[MAX_NAME_LENGTH];
    char steamId[32];
    char cleanDetail[256];
    GetCurrentVoteStatsFields(optionId, sizeof(optionId), optionName, sizeof(optionName));
    GetCurrentVoteInitiatorStatsFields(steamId, sizeof(steamId), playerName, sizeof(playerName));
    SanitizeVoteMenuStatsField(detail, cleanDetail, sizeof(cleanDetail));

    char message[512];
    Format(message, sizeof(message),
        "event=vote_started|option_id=%s|option_name=%s|detail=%s|client=%d|userid=%d|steamid64=%s|name=%s|required_ratio=%.4f|required_percent=%d|map_elapsed_seconds=%d|cost=%d|shop_enabled=%d",
        optionId,
        optionName,
        cleanDetail,
        client,
        g_CurrentVoteInitiatorUserId,
        steamId,
        playerName,
        g_CurrentVote.ratio,
        GetVoteRequiredPercent(g_CurrentVote.ratio),
        GetVoteMenuMapElapsedSeconds(),
        g_PendingChargeCost,
        g_PendingVoteCharge ? 1 : 0);
    PluginStats_LogMessage(message);
}

static void LogVoteMenuVoteResult(const char[] result, int yesVotes, int noVotes, int totalVotes, float yesRatio)
{
    char optionId[96];
    char optionName[160];
    char playerName[MAX_NAME_LENGTH];
    char steamId[32];
    GetCurrentVoteStatsFields(optionId, sizeof(optionId), optionName, sizeof(optionName));
    GetCurrentVoteInitiatorStatsFields(steamId, sizeof(steamId), playerName, sizeof(playerName));

    char message[512];
    Format(message, sizeof(message),
        "event=vote_result|result=%s|option_id=%s|option_name=%s|userid=%d|steamid64=%s|name=%s|yes_votes=%d|no_votes=%d|total_votes=%d|yes_ratio=%.4f|required_ratio=%.4f|required_percent=%d|map_elapsed_seconds=%d|cost=%d|shop_enabled=%d",
        result,
        optionId,
        optionName,
        g_CurrentVoteInitiatorUserId,
        steamId,
        playerName,
        yesVotes,
        noVotes,
        totalVotes,
        yesRatio,
        g_CurrentVote.ratio,
        GetVoteRequiredPercent(g_CurrentVote.ratio),
        GetVoteMenuMapElapsedSeconds(),
        g_PendingChargeCost,
        g_PendingVoteCharge ? 1 : 0);
    PluginStats_LogMessage(message);
}

static void LogVoteMenuVoteCancelled(const char[] reason, int cancelReason, int yesVotes, int noVotes)
{
    char optionId[96];
    char optionName[160];
    char playerName[MAX_NAME_LENGTH];
    char steamId[32];
    GetCurrentVoteStatsFields(optionId, sizeof(optionId), optionName, sizeof(optionName));
    GetCurrentVoteInitiatorStatsFields(steamId, sizeof(steamId), playerName, sizeof(playerName));

    char message[512];
    Format(message, sizeof(message),
        "event=vote_cancelled|reason=%s|cancel_reason=%d|option_id=%s|option_name=%s|userid=%d|steamid64=%s|name=%s|yes_votes=%d|no_votes=%d|required_ratio=%.4f|required_percent=%d|map_elapsed_seconds=%d|cost=%d|shop_enabled=%d",
        reason,
        cancelReason,
        optionId,
        optionName,
        g_CurrentVoteInitiatorUserId,
        steamId,
        playerName,
        yesVotes,
        noVotes,
        g_CurrentVote.ratio,
        GetVoteRequiredPercent(g_CurrentVote.ratio),
        GetVoteMenuMapElapsedSeconds(),
        g_PendingChargeCost,
        g_PendingVoteCharge ? 1 : 0);
    PluginStats_LogMessage(message);
}

static int FindVoteIndex(const char[] id)
{
    VoteOption opt;
    for (int i = 0; i < g_VoteOptions.Length; i++)
    {
        g_VoteOptions.GetArray(i, opt);
        if (StrEqual(opt.id, id, false))
        {
            return i;
        }
    }
    return -1;
}

static void LoadVoteMenuConfig()
{
    g_VoteOptions.Clear();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s", VOTEMENU_CONFIG);

    KeyValues kv = new KeyValues("votemenu");
    if (!kv.ImportFromFile(path))
    {
        LogError("[votemenu] Failed to read config: %s", path);
        delete kv;
        return;
    }

    if (!kv.GotoFirstSubKey(false))
    {
        delete kv;
        return;
    }

    char section[64];
    do
    {
        kv.GetSectionName(section, sizeof(section));

        VoteOption opt;
        strcopy(opt.id, sizeof(opt.id), section);
        kv.GetString("name", opt.name, sizeof(opt.name), "");
        kv.GetString("announcer", opt.announcer, sizeof(opt.announcer), "");
        kv.GetString("message", opt.message, sizeof(opt.message), section);
        opt.ratio = kv.GetFloat("ratio", 0.6);
        kv.GetString("win", opt.winFile, sizeof(opt.winFile), "");
        // Accept a stray key name if the config has a typo like lose'
        kv.GetString("lose", opt.loseFile, sizeof(opt.loseFile), "");
        if (!opt.loseFile[0])
        {
            kv.GetString("lose'", opt.loseFile, sizeof(opt.loseFile), "");
        }

        g_VoteOptions.PushArray(opt);
    }
    while (kv.GotoNextKey(false));

    delete kv;
}
