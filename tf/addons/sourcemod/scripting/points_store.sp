#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdkhooks>

#include <tf2>
#include <tf2_stocks>

#include <multicolors>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <filters_api>
#include <saysounds>
#include <weapons>
#include <whaletracker_api>
#define REQUIRE_PLUGIN
#include <plugin_statistics>

#include "include/client_validation.inc"
#include "include/chat_colors.inc"
#include "include/database.inc"
#include "include/steam_identity.inc"
#include "include/tf2_classes.inc"

#define BP_TRANS_DB_CONFIG_DEFAULT "default"
#define BP_TRANS_TABLE "bonuspoints_transactions"
#define BP_BALANCE_TABLE "points_store_balances"
#define BP_ECONOMY_TABLE "points_store_economy"
#define BP_IDEMPOTENT_AWARDS_TABLE "points_store_idempotent_awards"
#define BP_PER_MAP_AWARDS_TABLE "points_store_per_map_awards"
#define BP_IDEMPOTENT_KEY_MAX 128
#define BP_PER_MAP_SCOPE_MAX 128
#define BP_PER_MAP_ACTION_NONE 0
#define BP_PER_MAP_ACTION_RESTORE 1
#define BP_PER_MAP_ACTION_RESET 2
#define BP_ECONOMY_WELFARE_POOL_KEY "welfare_pool"
#define BP_ECONOMY_CUMULATIVE_SPENT_KEY "cumulative_spent"
#define BP_ECONOMY_KEY_MAX 64
#define BP_TRANS_ITEM_KEY_MAX 64
#define BP_TRANS_ITEM_NAME_MAX 128
#define BP_TRANS_ITEM_DESCRIPTION_MAX 256
#define BP_SOUND_COMMAND "xp_gain"
#define BP_LEVEL_UP_SOUND_COMMAND "xp_levelup"
#define BP_BALANCE_MILESTONE 500
#define BP_EVENT_LOG_LINE_MAX 1024
#define BP_CURRENCY_SHORT_MAX 32
#define BP_CURRENCY_LONG_MAX 64
#define BP_CURRENCY_COLOR_MAX 32
#define BP_WELFARE_SOUND_COMMAND "monkey"
#define BP_WELFARE_MIN 4
#define BP_WELFARE_MAX 16
#define BP_PURCHASE_PERMANENT 0
#define BP_PURCHASE_UNLIMITED_USES -1
#define BP_LEADERBOARD_PAGE_SIZE 10
#define BP_BALANCE_SEARCH_MAX 20
#define BP_BALANCE_SEARCH_NAME_MAX 128

ArrayList g_ItemKeys = null;
ArrayList g_ItemNames = null;
ArrayList g_ItemDescriptions = null;
ArrayList g_ItemPrices = null;
ArrayList g_ItemDurations = null;
ArrayList g_ItemUses = null;

StringMap g_ClientPurchases[MAXPLAYERS + 1];
StringMap g_ClientPurchaseExpiresAt[MAXPLAYERS + 1];
StringMap g_ClientPurchaseUsesRemaining[MAXPLAYERS + 1];
bool g_ClientPurchasesLoaded[MAXPLAYERS + 1];
int g_ClientBonusPoints[MAXPLAYERS + 1];
bool g_ClientBonusPointsLoaded[MAXPLAYERS + 1];
bool g_ClientBonusPointsPending[MAXPLAYERS + 1];
char g_ClientShopDetailItem[MAXPLAYERS + 1][BP_TRANS_ITEM_KEY_MAX];

Database g_Database = null;
ConVar g_CvarDatabase = null;
ConVar g_CvarEventLogging = null;
ConVar g_CvarLogRandomMisses = null;
ConVar g_CvarCurrencyShort = null;
ConVar g_CvarCurrencyLong = null;
ConVar g_CvarCurrencyColor = null;
ConVar g_CvarSendCooldown = null;
ConVar g_CvarEnableWelfare = null;
ConVar g_CvarWelfareMinPlayers = null;
ConVar g_CvarBountyMinPlayers = null;
ConVar g_CvarBountyMinAmount = null;
ConVar g_CvarBountyMaxAmount = null;
ConVar g_CvarBountyTimeLimitMinutes = null;
ConVar g_CvarAutoBountyMinDeaths = null;
bool g_DatabaseReady = false;
bool g_IsMySql = false;
bool g_IdempotentAwardsReady = false;
Handle g_hDatabaseReconnectTimer = null;
GlobalForward g_IdempotentAwardForward = null;
bool g_EconomyStateLoaded = false;
int g_WelfarePoolBalance = 0;
int g_CumulativeSpentBalance = 0;
char g_CurrencyShortLabel[BP_CURRENCY_SHORT_MAX];
char g_CurrencyLongLabel[BP_CURRENCY_LONG_MAX];
char g_CurrencyColorTag[BP_CURRENCY_COLOR_MAX + 2];
char g_CurrencyPrefix[96];
float g_NextSendAllowedAt[MAXPLAYERS + 1];
int g_BalanceSearchGeneration[MAXPLAYERS + 1];
StringMap g_PerMapAwardCounts = null;
bool g_PerMapAwardsReady = false;
bool g_PerMapSchemaReady = false;
bool g_PerMapLateLoad = false;
bool g_PerMapIgnoreInitialMapStart = false;
int g_PerMapStateGeneration = 0;
int g_PerMapStateAction = 0;
int g_PerMapServerPort = 0;
char g_PerMapName[BP_PER_MAP_SCOPE_MAX];
#include "points_store/lotteries.inc"
#include "points_store/bounties.inc"
#include "points_store/rewards.inc"
#include "points_store/bonus_labels.inc"
#include "points_store/dailies.inc"
#include "points_store/memoman_event.inc"
#include "points_store/gameplay_rewards.inc"

public Plugin myinfo =
{
    name = "points_store",
    author = "Kogasa, Hombre",
    description = "Currency purchase receipts, shop UI, and ownership API.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    g_PerMapLateLoad = late;
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("Filters_GetSteamIdColorTag");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeHours");
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeSeconds");
    RegPluginLibrary("points_store");
    CreateNative("PointsStore_AreBonusPointsLoaded", Native_PointsStore_AreBonusPointsLoaded);
    CreateNative("PointsStore_GetBonusPoints", Native_PointsStore_GetBonusPoints);
    CreateNative("PointsStore_ApplyBonusPoints", Native_PointsStore_ApplyBonusPoints);
    CreateNative("PointsStore_ApplyBonusPointsSteamId", Native_PointsStore_ApplyBonusPointsSteamId);
    CreateNative("PointsStore_GetRewardAmount", Native_PointsStore_GetRewardAmount);
    CreateNative("PointsStore_GetRewardPerMapLimit", Native_PointsStore_GetRewardPerMapLimit);
    CreateNative("PointsStore_GetRewardLongName", Native_PointsStore_GetRewardLongName);
    CreateNative("PointsStore_GetRewardShortDescription", Native_PointsStore_GetRewardShortDescription);
    CreateNative("PointsStore_GetRewardLongDescription", Native_PointsStore_GetRewardLongDescription);
    CreateNative("PointsStore_ApplyBonusPointsSteamIdOnce", Native_PointsStore_ApplyBonusPointsSteamIdOnce);
    CreateNative("PointsStore_RefundBonusPoints", Native_PointsStore_RefundBonusPoints);
    CreateNative("PointsStore_RefundBonusPointsSteamId", Native_PointsStore_RefundBonusPointsSteamId);
    CreateNative("PointsStore_SpendBonusPoints", Native_PointsStore_SpendBonusPoints);
    CreateNative("PointsStore_StealBonusPoints", Native_PointsStore_StealBonusPoints);
    CreateNative("PointsStore_AwardMemomanEvent", Native_PointsStore_AwardMemomanEvent);
    CreateNative("PointsStore_HasPurchase", Native_PointsStore_HasPurchase);
    CreateNative("PointsStore_GetPurchasePrice", Native_PointsStore_GetPurchasePrice);
    CreateNative("PointsStore_GetPurchaseExpiresAt", Native_PointsStore_GetPurchaseExpiresAt);
    CreateNative("PointsStore_GetPurchaseUsesRemaining", Native_PointsStore_GetPurchaseUsesRemaining);
    CreateNative("PointsStore_ConsumePurchaseUse", Native_PointsStore_ConsumePurchaseUse);
    g_IdempotentAwardForward = new GlobalForward(
        "PointsStore_OnApplyBonusPointsSteamIdOnce",
        ET_Ignore,
        Param_String,
        Param_Cell,
        Param_Cell);
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_ItemKeys = new ArrayList(ByteCountToCells(BP_TRANS_ITEM_KEY_MAX));
    g_ItemNames = new ArrayList(ByteCountToCells(BP_TRANS_ITEM_NAME_MAX));
    g_ItemDescriptions = new ArrayList(ByteCountToCells(BP_TRANS_ITEM_DESCRIPTION_MAX));
    g_ItemPrices = new ArrayList();
    g_ItemDurations = new ArrayList();
    g_ItemUses = new ArrayList();
    g_PerMapAwardCounts = new StringMap();
    g_PerMapIgnoreInitialMapStart = g_PerMapLateLoad;
    g_PerMapStateAction = g_PerMapLateLoad ? BP_PER_MAP_ACTION_RESTORE : BP_PER_MAP_ACTION_RESET;
    RefreshPerMapAwardScope();
    Rewards_OnPluginStart();

    for (int i = 1; i <= MaxClients; i++)
    {
        g_ClientPurchases[i] = new StringMap();
        g_ClientPurchaseExpiresAt[i] = new StringMap();
        g_ClientPurchaseUsesRemaining[i] = new StringMap();
        g_ClientPurchasesLoaded[i] = false;
        g_ClientBonusPoints[i] = 0;
        g_ClientBonusPointsLoaded[i] = false;
        g_ClientBonusPointsPending[i] = false;
        g_ClientShopDetailItem[i][0] = '\0';
    }

    g_CvarDatabase = CreateConVar("sm_bonuspoints_transactions_database", BP_TRANS_DB_CONFIG_DEFAULT, "Databases.cfg entry for bonuspoints_transactions.");
    g_CvarEventLogging = CreateConVar("sm_points_store_event_logging", "1", "Write structured currency economy events through plugin statistics.", _, true, 0.0, true, 1.0);
    g_CvarLogRandomMisses = CreateConVar("sm_points_store_log_random_misses", "0", "Log failed random-chance currency rolls when event logging is enabled.", _, true, 0.0, true, 1.0);
    g_CvarCurrencyShort = CreateConVar("sm_points_store_currency_short", "Gems", "Short currency label used in compact messages, e.g. BP or Gem.");
    g_CvarCurrencyLong = CreateConVar("sm_points_store_currency_long", "Gems", "Long currency label used in menus and prose, e.g. Bonus Points or Gems.");
    g_CvarCurrencyColor = CreateConVar("sm_points_store_currency_color", "cyan", "Multicolors tag name used for the currency prefix, without braces.");
    g_CvarSendCooldown = CreateConVar("sm_points_store_send_cooldown", "15.0", "Seconds a client must wait between successful !send currency transfers.", _, true, 0.0);
    g_CvarEnableWelfare = CreateConVar("sm_points_store_welfare", "1", "Enable welfare?", _, true, 0.0, true, 1.0);
    g_CvarWelfareMinPlayers = CreateConVar("sm_points_store_welfare_min_players", "3", "Minimum number of human clients in game required to collect welfare. 0 disables the requirement.", _, true, 0.0, true, 64.0);
    g_CvarBountyMinPlayers = CreateConVar("sm_points_store_bounty_min_players", "6", "Minimum GetClientCount(false) required to place bounties and advance bounty playtime.", _, true, 0.0, true, 64.0);
    g_CvarBountyMinAmount = CreateConVar("sm_points_store_bounty_min_amount", "50", "Minimum Gem value of an individual bounty.", _, true, 1.0);
    g_CvarBountyMaxAmount = CreateConVar("sm_points_store_bounty_max_amount", "1000", "Maximum Gem value of an individual bounty, including kill growth.", _, true, 1.0);
    g_CvarBountyTimeLimitMinutes = CreateConVar("sm_points_store_bounty_time_limit_minutes", "20.0", "Qualifying playtime required to survive a bounty, in minutes.", _, true, 1.0, true, 1440.0);
    g_CvarAutoBountyMinDeaths = CreateConVar("sm_points_store_auto_bounty_min_deaths", "2", "Minimum live scoreboard deaths required for automatic bounty selection.", _, true, 0.0);
    g_CvarCurrencyShort.AddChangeHook(OnCurrencyConVarChanged);
    g_CvarCurrencyLong.AddChangeHook(OnCurrencyConVarChanged);
    g_CvarCurrencyColor.AddChangeHook(OnCurrencyConVarChanged);
    RefreshCurrencyLabels();

    RegConsoleCmd("sm_shop", Command_Shop, "Open the points store.");
    RegConsoleCmd("sm_store", Command_Shop, "Open the points store.");
    RegConsoleCmd("sm_buy", Command_Shop, "Open the points store.");
    RegConsoleCmd("sm_bonus", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_bonuspoints", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_bp", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_currencyranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_bonuspointsranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_bpranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_gl", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_send", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_sendbp", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_bpsend", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_gem", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_gems", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_wallet", Command_ShowBonusPoints, "Show your currency balance.");
    AddCommandListener(CommandListener_ShowBonusPointsAlias, "gem");
    AddCommandListener(CommandListener_ShowBonusPointsAlias, "gems");
    AddCommandListener(CommandListener_ShowBonusPointsAlias, "wallet");
    RegConsoleCmd("sm_gemranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_gemsranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_gemsleaderboard", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_sendgem", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_gemsend", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_welfare", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_collectwelfare", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_handout", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_gibs", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_ebt", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_welfarecheck", Command_Welfare, "Collect once-per-map welfare currency.");
    AddCommandListener(CommandListener_WelfareAlias, "gibs");
    AddCommandListener(CommandListener_WelfareAlias, "welfare");
    AddCommandListener(CommandListener_WelfareAlias, "ebt");
    AddCommandListener(CommandListener_WelfareChatAlias, "say");
    AddCommandListener(CommandListener_WelfareChatAlias, "say_team");
    AddCommandListener(CommandListener_PointsStoreChatAlias, "say");
    AddCommandListener(CommandListener_PointsStoreChatAlias, "say_team");

    Lotteries_OnPluginStart();
    Bounties_OnPluginStart();
    Dailies_OnPluginStart();
    MemomanEvent_OnPluginStart();
    GameplayRewards_OnPluginStart();

    LoadStoreItems();
    ConnectDatabase();
}

public void OnPluginEnd()
{
    Lotteries_OnPluginEnd();
    Bounties_OnPluginEnd();
    MemomanEvent_OnPluginEnd();
    delete g_IdempotentAwardForward;

    delete g_ItemKeys;
    delete g_ItemNames;
    delete g_ItemPrices;
    delete g_ItemDurations;
    delete g_ItemUses;
    delete g_PerMapAwardCounts;
    Rewards_OnPluginEnd();

    for (int i = 1; i <= MaxClients; i++)
    {
        delete g_ClientPurchases[i];
        g_ClientPurchases[i] = null;
        delete g_ClientPurchaseExpiresAt[i];
        g_ClientPurchaseExpiresAt[i] = null;
        delete g_ClientPurchaseUsesRemaining[i];
        g_ClientPurchaseUsesRemaining[i] = null;
    }

    Db_CancelTimer(g_hDatabaseReconnectTimer);
    Db_Close(g_Database, g_DatabaseReady);
}

public void OnMapStart()
{
    Lotteries_OnMapStart();
    Bounties_OnMapStart();
    RefreshPerMapAwardScope();
    if (g_PerMapIgnoreInitialMapStart)
    {
        g_PerMapIgnoreInitialMapStart = false;
        return;
    }

    ResetPerMapAwardState();
}

public void OnMapEnd()
{
    Lotteries_OnMapEnd();
}

public void OnClientAuthorized(int client, const char[] auth)
{
    Bounties_OnClientAuthorized(client);
    g_NextSendAllowedAt[client] = 0.0;
    ClearClientStoreCache(client);
    LoadClientPurchases(client);
    LoadClientBonusPoints(client);
    Lotteries_OnClientAuthorized(client);
}

public void OnClientPutInServer(int client)
{
    GameplayRewards_OnClientPutInServer(client);
}

public void OnClientDisconnect(int client)
{
    GameplayRewards_OnClientDisconnect(client);
    Bounties_OnClientDisconnect(client);
    g_NextSendAllowedAt[client] = 0.0;
    ClearClientStoreCache(client);
    Lotteries_OnClientDisconnect(client);
}

void ConnectDatabase()
{
    Db_CancelTimer(g_hDatabaseReconnectTimer);
    Db_Close(g_Database, g_DatabaseReady);
    g_IdempotentAwardsReady = false;
    g_PerMapAwardsReady = false;
    g_PerMapSchemaReady = false;
    g_BountyDatabaseReady = false;
    g_BountyExpiryPending = false;
    g_BountyProgressPending = false;
    g_BountyDisconnectRefundPending = false;
    g_BountyAutomaticPlacementPending = false;
    g_ActiveBountyCount = 0;
    MemomanEvent_OnDatabaseDisconnected();
    Lotteries_OnDatabaseDisconnected();

    char dbConfig[64];
    g_CvarDatabase.GetString(dbConfig, sizeof(dbConfig));
    TrimString(dbConfig);
    if (dbConfig[0] == '\0')
    {
        strcopy(dbConfig, sizeof(dbConfig), BP_TRANS_DB_CONFIG_DEFAULT);
    }

    if (!Db_CheckConfigOrLog("points_store", dbConfig))
    {
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, dbConfig);
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[bonuspoints_transactions] Database connection failed: %s", error[0] ? error : "unknown error");
        ScheduleDatabaseReconnect();
        return;
    }

    g_Database = view_as<Database>(hndl);

    char driverIdent[32];
    DBDriver driver = g_Database.Driver;
    driver.GetIdentifier(driverIdent, sizeof(driverIdent));
    g_IsMySql = StrEqual(driverIdent, "mysql", false);
    Db_CancelTimer(g_hDatabaseReconnectTimer);

    EnsureSchema();
}

void ScheduleDatabaseReconnect(float delay = DB_RECONNECT_DELAY)
{
    g_DatabaseReady = false;
    g_IdempotentAwardsReady = false;
    g_BountyDatabaseReady = false;
    if (g_hDatabaseReconnectTimer == null)
    {
        g_hDatabaseReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    g_hDatabaseReconnectTimer = null;
    ConnectDatabase();
    return Plugin_Stop;
}

void EnsureSchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[1024];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INT NOT NULL AUTO_INCREMENT, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "item_key VARCHAR(64) NOT NULL, "
            ... "price_paid INT NOT NULL, "
            ... "purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
            ... "expires_at INT NOT NULL DEFAULT 0, "
            ... "uses_remaining INT NOT NULL DEFAULT -1, "
            ... "PRIMARY KEY (id), "
            ... "UNIQUE KEY unique_bonuspoints_purchase (steamid64, item_key), "
            ... "KEY idx_bonuspoints_transactions_steamid64 (steamid64), "
            ... "KEY idx_bonuspoints_transactions_item_key (item_key))",
            BP_TRANS_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "item_key VARCHAR(64) NOT NULL, "
            ... "price_paid INT NOT NULL, "
            ... "purchased_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
            ... "expires_at INTEGER NOT NULL DEFAULT 0, "
            ... "uses_remaining INTEGER NOT NULL DEFAULT -1, "
            ... "UNIQUE (steamid64, item_key))",
            BP_TRANS_TABLE);
    }

    g_Database.Query(SQL_OnPurchaseSchemaReady, query);
}

public void SQL_OnPurchaseSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Purchase schema creation failed: %s", error);
        return;
    }

    char query[256];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS expires_at INT NOT NULL DEFAULT 0",
            BP_TRANS_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0",
            BP_TRANS_TABLE);
    }

    g_Database.Query(SQL_OnPurchaseExpiryColumnReady, query);
}

public void SQL_OnPurchaseExpiryColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0' && !Db_IsDuplicateColumnError(error))
    {
        LogError("[points_store] Purchase expiry schema update failed: %s", error);
        return;
    }

    char query[256];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS uses_remaining INT NOT NULL DEFAULT -1",
            BP_TRANS_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN uses_remaining INTEGER NOT NULL DEFAULT -1",
            BP_TRANS_TABLE);
    }

    g_Database.Query(SQL_OnPurchaseUsesColumnReady, query);
}

public void SQL_OnPurchaseUsesColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0' && !Db_IsDuplicateColumnError(error))
    {
        LogError("[points_store] Purchase uses schema update failed: %s", error);
        return;
    }

    if (!g_IsMySql)
    {
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_bonuspoints_transactions_steamid64 ON bonuspoints_transactions (steamid64)");
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_bonuspoints_transactions_item_key ON bonuspoints_transactions (item_key)");
    }

    EnsureBalanceSchema();
}

void EnsureBalanceSchema()
{
    char query[512];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "balance INT NOT NULL DEFAULT 0, "
            ... "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, "
            ... "PRIMARY KEY (steamid64))",
            BP_BALANCE_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
            ... "balance INT NOT NULL DEFAULT 0, "
            ... "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
            BP_BALANCE_TABLE);
    }

    g_Database.Query(SQL_OnSchemaReady, query);
}

public void SQL_OnSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Balance schema creation failed: %s", error);
        return;
    }

    EnsureLotterySchema();
}

void EnsureEconomySchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[512];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "stat_key VARCHAR(64) NOT NULL, "
            ... "value BIGINT NOT NULL DEFAULT 0, "
            ... "updated_at INT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (stat_key))",
            BP_ECONOMY_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "stat_key VARCHAR(64) NOT NULL PRIMARY KEY, "
            ... "value INTEGER NOT NULL DEFAULT 0, "
            ... "updated_at INTEGER NOT NULL DEFAULT 0)",
            BP_ECONOMY_TABLE);
    }

    g_Database.Query(SQL_OnEconomySchemaReady, query);
}

public void SQL_OnEconomySchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Economy schema creation failed: %s", error);
        FinishSchemaReady();
        return;
    }

    Transaction txn = new Transaction();
    char query[512];
    int now = GetTime();

    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (stat_key, value, updated_at) VALUES ('%s', 0, %d) ON DUPLICATE KEY UPDATE stat_key = stat_key",
            BP_ECONOMY_TABLE,
            BP_ECONOMY_WELFARE_POOL_KEY,
            now);
        txn.AddQuery(query);

        Format(query, sizeof(query),
            "INSERT INTO %s (stat_key, value, updated_at) VALUES ('%s', 0, %d) ON DUPLICATE KEY UPDATE stat_key = stat_key",
            BP_ECONOMY_TABLE,
            BP_ECONOMY_CUMULATIVE_SPENT_KEY,
            now);
        txn.AddQuery(query);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT OR IGNORE INTO %s (stat_key, value, updated_at) VALUES ('%s', 0, %d)",
            BP_ECONOMY_TABLE,
            BP_ECONOMY_WELFARE_POOL_KEY,
            now);
        txn.AddQuery(query);

        Format(query, sizeof(query),
            "INSERT OR IGNORE INTO %s (stat_key, value, updated_at) VALUES ('%s', 0, %d)",
            BP_ECONOMY_TABLE,
            BP_ECONOMY_CUMULATIVE_SPENT_KEY,
            now);
        txn.AddQuery(query);
    }

    g_Database.Execute(txn, SQLTxn_OnEconomyRowsReady, SQLTxn_OnEconomyRowsFailure);
}

public void SQLTxn_OnEconomyRowsReady(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    FinishSchemaReady();
    LoadEconomyState();
}

public void SQLTxn_OnEconomyRowsFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("[points_store] Economy row initialization failed (query %d): %s", failIndex, error);
    FinishSchemaReady();
}

void FinishSchemaReady()
{
    g_DatabaseReady = true;
    EnsureIdempotentAwardsSchema();
    EnsurePerMapAwardsSchema();
    EnsureBountySchema();
    MemomanEvent_EnsureSchema();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientPurchases(i);
            LoadClientBonusPoints(i);
        }
    }
    Lotteries_OnDatabaseReady();
}

void EnsureIdempotentAwardsSchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[1024];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "award_key VARCHAR(%d) NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "amount INT NOT NULL, "
            ... "reason VARCHAR(64) NOT NULL DEFAULT '', "
            ... "created_at INT NOT NULL, "
            ... "PRIMARY KEY (award_key)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            BP_IDEMPOTENT_AWARDS_TABLE,
            BP_IDEMPOTENT_KEY_MAX);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "award_key VARCHAR(%d) PRIMARY KEY, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "amount INTEGER NOT NULL, "
            ... "reason VARCHAR(64) NOT NULL DEFAULT '', "
            ... "created_at INTEGER NOT NULL)",
            BP_IDEMPOTENT_AWARDS_TABLE,
            BP_IDEMPOTENT_KEY_MAX);
    }

    g_Database.Query(SQL_OnIdempotentAwardsSchemaReady, query);
}

public void SQL_OnIdempotentAwardsSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        g_IdempotentAwardsReady = false;
        LogError("[points_store] Idempotent award schema creation failed: %s", error);
        return;
    }

    g_IdempotentAwardsReady = true;
}

void RefreshPerMapAwardScope()
{
    ConVar hostPort = FindConVar("hostport");
    g_PerMapServerPort = hostPort != null ? hostPort.IntValue : 0;
    GetCurrentMap(g_PerMapName, sizeof(g_PerMapName));
}

void EnsurePerMapAwardsSchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[1024];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "server_port INT NOT NULL, "
            ... "map_name VARCHAR(128) NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "reward_id VARCHAR(64) NOT NULL, "
            ... "award_count INT NOT NULL DEFAULT 0, "
            ... "updated_at INT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (server_port, map_name, steamid64, reward_id)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            BP_PER_MAP_AWARDS_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "server_port INTEGER NOT NULL, "
            ... "map_name VARCHAR(128) NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "reward_id VARCHAR(64) NOT NULL, "
            ... "award_count INTEGER NOT NULL DEFAULT 0, "
            ... "updated_at INTEGER NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (server_port, map_name, steamid64, reward_id))",
            BP_PER_MAP_AWARDS_TABLE);
    }

    g_Database.Query(SQL_OnPerMapAwardsSchemaReady, query);
}

public void SQL_OnPerMapAwardsSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        g_PerMapSchemaReady = false;
        g_PerMapAwardsReady = false;
        LogError("[points_store] Per-map award schema creation failed: %s", error);
        return;
    }

    g_PerMapSchemaReady = true;
    BeginPerMapStateAction();
}

void ResetPerMapAwardState()
{
    if (g_PerMapAwardCounts != null)
    {
        g_PerMapAwardCounts.Clear();
    }

    g_PerMapAwardsReady = false;
    g_PerMapStateAction = BP_PER_MAP_ACTION_RESET;
    if (g_PerMapSchemaReady && g_DatabaseReady)
    {
        BeginPerMapStateAction();
    }
}

void BeginPerMapStateAction()
{
    if (!g_PerMapSchemaReady || !g_DatabaseReady || g_Database == null)
    {
        return;
    }

    RefreshPerMapAwardScope();
    int generation = ++g_PerMapStateGeneration;

    if (g_PerMapStateAction == BP_PER_MAP_ACTION_NONE)
    {
        g_PerMapAwardsReady = true;
        return;
    }

    char query[768];
    if (g_PerMapStateAction == BP_PER_MAP_ACTION_RESET)
    {
        Format(query, sizeof(query),
            "DELETE FROM %s WHERE server_port = %d",
            BP_PER_MAP_AWARDS_TABLE,
            g_PerMapServerPort);
        g_Database.Query(SQL_OnPerMapAwardsReset, query, generation);
        return;
    }

    char escapedMap[257];
    if (!EscapeSql(g_PerMapName, escapedMap, sizeof(escapedMap)))
    {
        LogError("[points_store] Failed to escape the current map for per-map award restoration.");
        return;
    }

    Format(query, sizeof(query),
        "SELECT steamid64, reward_id, award_count FROM %s "
        ... "WHERE server_port = %d AND map_name = '%s'",
        BP_PER_MAP_AWARDS_TABLE,
        g_PerMapServerPort,
        escapedMap);
    g_Database.Query(SQL_OnPerMapAwardsRestored, query, generation);
}

public void SQL_OnPerMapAwardsReset(Database db, DBResultSet results, const char[] error, any data)
{
    if (data != g_PerMapStateGeneration)
    {
        return;
    }
    if (error[0] != '\0')
    {
        g_PerMapAwardsReady = false;
        LogError("[points_store] Failed to reset per-map awards: %s", error);
        return;
    }

    g_PerMapStateAction = BP_PER_MAP_ACTION_NONE;
    g_PerMapAwardsReady = true;
}

public void SQL_OnPerMapAwardsRestored(Database db, DBResultSet results, const char[] error, any data)
{
    if (data != g_PerMapStateGeneration)
    {
        return;
    }
    if (error[0] != '\0')
    {
        g_PerMapAwardsReady = false;
        LogError("[points_store] Failed to restore per-map awards: %s", error);
        return;
    }

    g_PerMapAwardCounts.Clear();
    char steamId[32];
    char rewardId[64];
    char key[128];
    int restored = 0;
    while (results != null && results.FetchRow())
    {
        results.FetchString(0, steamId, sizeof(steamId));
        results.FetchString(1, rewardId, sizeof(rewardId));
        int count = results.FetchInt(2);
        if (count > 0 && BuildPerMapAwardKeyForSteamId(steamId, rewardId, key, sizeof(key)))
        {
            g_PerMapAwardCounts.SetValue(key, count, true);
            restored++;
        }
    }

    g_PerMapStateAction = BP_PER_MAP_ACTION_NONE;
    g_PerMapAwardsReady = true;
    LogMessage("[points_store] Restored %d per-map reward counter(s) for %s on port %d.", restored, g_PerMapName, g_PerMapServerPort);
}

void LoadEconomyState()
{
    if (!g_DatabaseReady || g_Database == null)
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query),
        "SELECT stat_key, value FROM %s WHERE stat_key IN ('%s', '%s')",
        BP_ECONOMY_TABLE,
        BP_ECONOMY_WELFARE_POOL_KEY,
        BP_ECONOMY_CUMULATIVE_SPENT_KEY);
    g_Database.Query(SQL_OnEconomyStateLoaded, query);
}

public void SQL_OnEconomyStateLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Economy state load failed: %s", error);
        return;
    }

    int welfarePool = 0;
    int cumulativeSpent = 0;
    char statKey[BP_ECONOMY_KEY_MAX];
    while (results != null && results.FetchRow())
    {
        results.FetchString(0, statKey, sizeof(statKey));
        if (StrEqual(statKey, BP_ECONOMY_WELFARE_POOL_KEY, false))
        {
            welfarePool = results.FetchInt(1);
        }
        else if (StrEqual(statKey, BP_ECONOMY_CUMULATIVE_SPENT_KEY, false))
        {
            cumulativeSpent = results.FetchInt(1);
        }
    }

    g_WelfarePoolBalance = welfarePool;
    g_CumulativeSpentBalance = cumulativeSpent;
    g_EconomyStateLoaded = true;
}

public Action CommandListener_ShowBonusPointsAlias(int client, const char[] command, int argc)
{
    return Command_ShowBonusPoints(client, 0);
}

public Action CommandListener_PointsStoreChatAlias(int client, const char[] command, int argc)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Continue;
    }

    char text[32];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);

    if (StrEqual(text, "gem", false) || StrEqual(text, "gems", false) || StrEqual(text, "wallet", false))
    {
        return Command_ShowBonusPoints(client, 0);
    }

    if (StrEqual(text, "refund", false))
    {
        return Command_LotteryRefund(client, 0);
    }

    if (StrEqual(text, "pool", false))
    {
        return Command_LotteryPrizePool(client, 0);
    }

    if (StrEqual(text, "daily", false)
        || StrEqual(text, "dailies", false)
        || StrEqual(text, "limit", false)
        || StrEqual(text, "limits", false))
    {
        return Command_Dailies(client, 0);
    }

    return Plugin_Continue;
}

public void SQL_OnIgnoredResult(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[bonuspoints_transactions] SQL query failed: %s", error);
    }
}

void LoadStoreItems()
{
    g_ItemKeys.Clear();
    g_ItemNames.Clear();
    g_ItemDescriptions.Clear();
    g_ItemPrices.Clear();
    g_ItemDurations.Clear();
    g_ItemUses.Clear();

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/points_store.cfg");

    KeyValues kv = new KeyValues("points_store");
    if (!FileToKeyValues(kv, configPath))
    {
        LogError("[bonuspoints_transactions] Could not load %s", configPath);
        delete kv;
        return;
    }

    if (!kv.GotoFirstSubKey())
    {
        LogError("[bonuspoints_transactions] No items found in %s", configPath);
        delete kv;
        return;
    }

    do
    {
        char itemKey[BP_TRANS_ITEM_KEY_MAX];
        char itemName[BP_TRANS_ITEM_NAME_MAX];
        char description[BP_TRANS_ITEM_DESCRIPTION_MAX];
        char priceText[32];
        char durationText[32];
        char usesText[32];
        kv.GetSectionName(itemKey, sizeof(itemKey));
        kv.GetString("price", priceText, sizeof(priceText));
        kv.GetString("long_name", itemName, sizeof(itemName));
        kv.GetString("description", description, sizeof(description), "No description configured.");
        kv.GetString("duration", durationText, sizeof(durationText));
        kv.GetString("uses", usesText, sizeof(usesText));
        TrimString(itemKey);
        TrimString(itemName);
        TrimString(description);
        TrimString(priceText);
        TrimString(durationText);
        TrimString(usesText);

        int price = StringToInt(priceText);
        if (itemKey[0] == '\0' || itemName[0] == '\0' || price <= 0)
        {
            continue;
        }

        int durationSeconds = ParseDurationSeconds(durationText);
        int useCount = BP_PURCHASE_UNLIMITED_USES;
        if (usesText[0] != '\0')
        {
            useCount = StringToInt(usesText);
            if (useCount <= 0)
            {
                useCount = BP_PURCHASE_UNLIMITED_USES;
            }
        }

        AddStoreItemSorted(itemKey, itemName, description, price, durationSeconds, useCount);
    }
    while (kv.GotoNextKey());

    delete kv;
    LogMessage("[bonuspoints_transactions] Loaded %d shop item(s).", g_ItemPrices.Length);
}

int ParseDurationSeconds(const char[] input)
{
    char text[32];
    strcopy(text, sizeof(text), input);
    TrimString(text);

    int len = strlen(text);
    if (len <= 0)
    {
        return BP_PURCHASE_PERMANENT;
    }

    int multiplier = 1;
    char suffix = text[len - 1];
    if (suffix == 'd' || suffix == 'D')
    {
        multiplier = 86400;
        text[len - 1] = '\0';
    }
    else if (suffix == 'h' || suffix == 'H')
    {
        multiplier = 3600;
        text[len - 1] = '\0';
    }
    else if (suffix == 'm' || suffix == 'M')
    {
        multiplier = 60;
        text[len - 1] = '\0';
    }
    else if (suffix == 's' || suffix == 'S')
    {
        text[len - 1] = '\0';
    }

    TrimString(text);
    int amount = StringToInt(text);
    if (amount <= 0)
    {
        return BP_PURCHASE_PERMANENT;
    }

    return amount * multiplier;
}

void AddStoreItemSorted(const char[] itemKey, const char[] itemName, const char[] description, int price, int durationSeconds, int useCount)
{
    if (FindStoreItem(itemKey) != -1)
    {
        LogError("[bonuspoints_transactions] Duplicate item_key '%s' ignored.", itemKey);
        return;
    }

    int insertAt = g_ItemPrices.Length;
    for (int i = 0; i < g_ItemPrices.Length; i++)
    {
        if (price > g_ItemPrices.Get(i))
        {
            insertAt = i;
            break;
        }
    }

    if (insertAt == g_ItemPrices.Length)
    {
        g_ItemKeys.PushString(itemKey);
        g_ItemNames.PushString(itemName);
        g_ItemDescriptions.PushString(description);
        g_ItemPrices.Push(price);
        g_ItemDurations.Push(durationSeconds);
        g_ItemUses.Push(useCount);
        return;
    }

    g_ItemKeys.ShiftUp(insertAt);
    g_ItemNames.ShiftUp(insertAt);
    g_ItemDescriptions.ShiftUp(insertAt);
    g_ItemPrices.ShiftUp(insertAt);
    g_ItemDurations.ShiftUp(insertAt);
    g_ItemUses.ShiftUp(insertAt);
    g_ItemKeys.SetString(insertAt, itemKey);
    g_ItemNames.SetString(insertAt, itemName);
    g_ItemDescriptions.SetString(insertAt, description);
    g_ItemPrices.Set(insertAt, price);
    g_ItemDurations.Set(insertAt, durationSeconds);
    g_ItemUses.Set(insertAt, useCount);
}

int FindStoreItem(const char[] itemKey)
{
    char currentKey[BP_TRANS_ITEM_KEY_MAX];
    for (int i = 0; i < g_ItemKeys.Length; i++)
    {
        g_ItemKeys.GetString(i, currentKey, sizeof(currentKey));
        if (StrEqual(currentKey, itemKey, false))
        {
            return i;
        }
    }
    return -1;
}

bool IsClientAuthorizedHuman(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientConnected(client)
        && IsClientAuthorized(client)
        && !IsFakeClient(client);
}

void ClearClientPurchaseCache(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (g_ClientPurchases[client] == null)
    {
        g_ClientPurchases[client] = new StringMap();
    }
    else
    {
        g_ClientPurchases[client].Clear();
    }
    if (g_ClientPurchaseExpiresAt[client] == null)
    {
        g_ClientPurchaseExpiresAt[client] = new StringMap();
    }
    else
    {
        g_ClientPurchaseExpiresAt[client].Clear();
    }
    if (g_ClientPurchaseUsesRemaining[client] == null)
    {
        g_ClientPurchaseUsesRemaining[client] = new StringMap();
    }
    else
    {
        g_ClientPurchaseUsesRemaining[client].Clear();
    }
    g_ClientPurchasesLoaded[client] = false;
}

void ClearClientBonusPointsCache(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_ClientBonusPoints[client] = 0;
    g_ClientBonusPointsLoaded[client] = false;
    g_ClientBonusPointsPending[client] = false;
}

void ClearClientStoreCache(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        g_ClientShopDetailItem[client][0] = '\0';
    }

    ClearClientPurchaseCache(client);
    ClearClientBonusPointsCache(client);
}

bool GetClientSteamId64(int client, char[] steamId, int maxlen)
{
    steamId[0] = '\0';
    if (!IsClientAuthorizedHuman(client))
    {
        return false;
    }

    return Kogasa_GetClientSteamId64(client, steamId, maxlen, true);
}

bool EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    if (g_Database == null)
    {
        return false;
    }

    int written = 0;
    return g_Database.Escape(input, output, maxlen, written);
}

void LoadClientPurchases(int client)
{
    if (!g_DatabaseReady || g_Database == null || !IsClientAuthorizedHuman(client))
    {
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[bonuspoints_transactions] Failed to escape SteamID64 for client %d.", client);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);

    char query[384];
    Format(query, sizeof(query),
        "SELECT item_key, price_paid, expires_at, uses_remaining FROM %s WHERE steamid64 = '%s' AND (expires_at = 0 OR expires_at > %d) AND uses_remaining != 0",
        BP_TRANS_TABLE,
        escapedSteamId,
        GetTime());
    g_Database.Query(SQL_OnClientPurchasesLoaded, query, pack);
}

void LoadClientBonusPoints(int client)
{
    if (!g_DatabaseReady || g_Database == null || !IsClientAuthorizedHuman(client) || g_ClientBonusPointsPending[client])
    {
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[points_store] Failed to escape SteamID64 for bonus-point load for client %d.", client);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);

    g_ClientBonusPointsPending[client] = true;

    char query[256];
    Format(query, sizeof(query),
        "SELECT balance FROM %s WHERE steamid64 = '%s'",
        BP_BALANCE_TABLE,
        escapedSteamId);
    g_Database.Query(SQL_OnClientBonusPointsLoaded, query, pack);
}

public void SQL_OnClientPurchasesLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    char expectedSteamId[32];
    pack.ReadString(expectedSteamId, sizeof(expectedSteamId));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsClientAuthorizedHuman(client))
    {
        return;
    }

    char currentSteamId[32];
    if (!GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId)) || !StrEqual(currentSteamId, expectedSteamId, false))
    {
        return;
    }

    g_ClientPurchases[client].Clear();
    g_ClientPurchaseExpiresAt[client].Clear();
    g_ClientPurchaseUsesRemaining[client].Clear();

    if (error[0] != '\0')
    {
        LogError("[bonuspoints_transactions] Failed to load purchases for %s: %s", expectedSteamId, error);
        g_ClientPurchasesLoaded[client] = false;
        return;
    }

    if (results != null)
    {
        char itemKey[BP_TRANS_ITEM_KEY_MAX];
        while (results.FetchRow())
        {
            results.FetchString(0, itemKey, sizeof(itemKey));
            int pricePaid = results.FetchInt(1);
            int expiresAt = results.FetchInt(2);
            int usesRemaining = results.FetchInt(3);
            int configuredUses = GetConfiguredItemUses(itemKey);
            if (configuredUses > 0 && usesRemaining == BP_PURCHASE_UNLIMITED_USES)
            {
                usesRemaining = configuredUses;
                SavePurchaseUsesRemaining(client, itemKey, usesRemaining);
            }
            if (pricePaid > 0 && usesRemaining != 0 && (expiresAt == BP_PURCHASE_PERMANENT || expiresAt > GetTime()))
            {
                g_ClientPurchases[client].SetValue(itemKey, pricePaid);
                g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
                g_ClientPurchaseUsesRemaining[client].SetValue(itemKey, usesRemaining);
            }
        }
    }

    g_ClientPurchasesLoaded[client] = true;
}

public void SQL_OnClientBonusPointsLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    char expectedSteamId[32];
    pack.ReadString(expectedSteamId, sizeof(expectedSteamId));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsClientAuthorizedHuman(client))
    {
        return;
    }

    g_ClientBonusPointsPending[client] = false;

    char currentSteamId[32];
    if (!GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId)) || !StrEqual(currentSteamId, expectedSteamId, false))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to load bonus points for %s: %s", expectedSteamId, error);
        g_ClientBonusPointsLoaded[client] = false;
        return;
    }

    g_ClientBonusPoints[client] = 0;
    if (results != null && results.FetchRow())
    {
        g_ClientBonusPoints[client] = results.FetchInt(0);
        if (g_ClientBonusPoints[client] < 0)
        {
            g_ClientBonusPoints[client] = 0;
        }
    }

    g_ClientBonusPointsLoaded[client] = true;
}

int GetCachedPurchasePrice(int client, const char[] itemKey)
{
    if (client <= 0 || client > MaxClients || g_ClientPurchases[client] == null || g_ClientPurchaseExpiresAt[client] == null || g_ClientPurchaseUsesRemaining[client] == null)
    {
        return 0;
    }

    int pricePaid = 0;
    if (!g_ClientPurchases[client].GetValue(itemKey, pricePaid))
    {
        return 0;
    }

    int expiresAt = BP_PURCHASE_PERMANENT;
    g_ClientPurchaseExpiresAt[client].GetValue(itemKey, expiresAt);
    if (expiresAt != BP_PURCHASE_PERMANENT && expiresAt <= GetTime())
    {
        RemoveCachedPurchase(client, itemKey);
        return 0;
    }

    int usesRemaining = BP_PURCHASE_UNLIMITED_USES;
    g_ClientPurchaseUsesRemaining[client].GetValue(itemKey, usesRemaining);
    if (usesRemaining == 0)
    {
        RemoveCachedPurchase(client, itemKey);
        return 0;
    }

    return pricePaid > 0 ? pricePaid : 0;
}

int GetConfiguredItemUses(const char[] itemKey)
{
    int itemIndex = FindStoreItem(itemKey);
    if (itemIndex == -1)
    {
        return BP_PURCHASE_UNLIMITED_USES;
    }

    return g_ItemUses.Get(itemIndex);
}

int GetCachedPurchaseExpiresAt(int client, const char[] itemKey)
{
    if (GetCachedPurchasePrice(client, itemKey) <= 0)
    {
        return -1;
    }

    int expiresAt = BP_PURCHASE_PERMANENT;
    if (g_ClientPurchaseExpiresAt[client] != null)
    {
        g_ClientPurchaseExpiresAt[client].GetValue(itemKey, expiresAt);
    }

    return expiresAt;
}

int GetCachedPurchaseUsesRemaining(int client, const char[] itemKey)
{
    if (GetCachedPurchasePrice(client, itemKey) <= 0)
    {
        return 0;
    }

    int usesRemaining = BP_PURCHASE_UNLIMITED_USES;
    if (g_ClientPurchaseUsesRemaining[client] != null)
    {
        g_ClientPurchaseUsesRemaining[client].GetValue(itemKey, usesRemaining);
    }

    return usesRemaining;
}

int ConsumeCachedPurchaseUse(int client, const char[] itemKey)
{
    if (GetCachedPurchasePrice(client, itemKey) <= 0)
    {
        return -1;
    }

    int usesRemaining = BP_PURCHASE_UNLIMITED_USES;
    g_ClientPurchaseUsesRemaining[client].GetValue(itemKey, usesRemaining);
    if (usesRemaining <= 0)
    {
        return -1;
    }

    usesRemaining--;
    if (usesRemaining > 0)
    {
        g_ClientPurchaseUsesRemaining[client].SetValue(itemKey, usesRemaining);
    }
    else
    {
        RemoveCachedPurchase(client, itemKey);
        BroadcastPurchaseRanOut(client, itemKey);
    }

    SavePurchaseUsesRemaining(client, itemKey, usesRemaining);
    return usesRemaining;
}

void BroadcastPurchaseRanOut(int client, const char[] itemKey)
{
    if (!Client_IsHumanInGame(client))
    {
        return;
    }

    char itemName[BP_TRANS_ITEM_NAME_MAX];
    if (!GetStoreItemName(itemKey, itemName, sizeof(itemName)))
    {
        strcopy(itemName, sizeof(itemName), itemKey);
    }

    char prefix[96];
    GetCurrencyPrefix(prefix, sizeof(prefix));

    char displayName[256];
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));
    CPrintToChatAllEx(client, "%s %s's {gold}%s{default} ran out!", prefix, displayName, itemName);
}

bool GetStoreItemName(const char[] itemKey, char[] itemName, int maxlen)
{
    itemName[0] = '\0';

    int itemIndex = FindStoreItem(itemKey);
    if (itemIndex == -1)
    {
        return false;
    }

    g_ItemNames.GetString(itemIndex, itemName, maxlen);
    return itemName[0] != '\0';
}

void RemoveCachedPurchase(int client, const char[] itemKey)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (g_ClientPurchases[client] != null)
    {
        g_ClientPurchases[client].Remove(itemKey);
    }
    if (g_ClientPurchaseExpiresAt[client] != null)
    {
        g_ClientPurchaseExpiresAt[client].Remove(itemKey);
    }
    if (g_ClientPurchaseUsesRemaining[client] != null)
    {
        g_ClientPurchaseUsesRemaining[client].Remove(itemKey);
    }
}

void SavePurchaseUsesRemaining(int client, const char[] itemKey, int usesRemaining)
{
    if (g_Database == null || client <= 0 || client > MaxClients)
    {
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return;
    }

    char escapedSteamId[65];
    char escapedItemKey[(BP_TRANS_ITEM_KEY_MAX * 2) + 1];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)) || !EscapeSql(itemKey, escapedItemKey, sizeof(escapedItemKey)))
    {
        LogError("[points_store] Failed to escape purchase-use update for client %d.", client);
        return;
    }

    char query[384];
    Format(query, sizeof(query),
        "UPDATE %s SET uses_remaining = %d WHERE steamid64 = '%s' AND item_key = '%s'",
        BP_TRANS_TABLE,
        usesRemaining,
        escapedSteamId,
        escapedItemKey);
    g_Database.Query(SQL_OnPurchaseUsesUpdated, query);
}

public void SQL_OnPurchaseUsesUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to update purchase uses: %s", error);
    }
}

bool AreBonusPointsReady(int client)
{
    return Client_IsHumanInGame(client) && g_ClientBonusPointsLoaded[client];
}

int GetCachedBonusPoints(int client)
{
    if (client <= 0 || client > MaxClients || !g_ClientBonusPointsLoaded[client])
    {
        return 0;
    }

    return g_ClientBonusPoints[client] > 0 ? g_ClientBonusPoints[client] : 0;
}

void GetCurrencyShortLabel(char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, g_CurrencyShortLabel);
}

void GetCurrencyShortLabelForAmount(int amount, char[] buffer, int maxlen)
{
    GetCurrencyShortLabel(buffer, maxlen);

    int len = strlen(buffer);
    if (amount == 1 && len > 0 && buffer[len - 1] == 's')
    {
        buffer[len - 1] = '\0';
    }
}

void GetCurrencyLongLabel(char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, g_CurrencyLongLabel);
}

void GetCurrencyColorTag(char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, g_CurrencyColorTag);
}

void GetCurrencyPrefix(char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, g_CurrencyPrefix);
}

public void OnCurrencyConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshCurrencyLabels();
}

void RefreshCurrencyLabels()
{
    g_CurrencyShortLabel[0] = '\0';
    if (g_CvarCurrencyShort != null)
    {
        g_CvarCurrencyShort.GetString(g_CurrencyShortLabel, sizeof(g_CurrencyShortLabel));
        TrimString(g_CurrencyShortLabel);
    }

    if (g_CurrencyShortLabel[0] == '\0')
    {
        strcopy(g_CurrencyShortLabel, sizeof(g_CurrencyShortLabel), "BP");
    }

    g_CurrencyLongLabel[0] = '\0';
    if (g_CvarCurrencyLong != null)
    {
        g_CvarCurrencyLong.GetString(g_CurrencyLongLabel, sizeof(g_CurrencyLongLabel));
        TrimString(g_CurrencyLongLabel);
    }

    if (g_CurrencyLongLabel[0] == '\0')
    {
        strcopy(g_CurrencyLongLabel, sizeof(g_CurrencyLongLabel), "Bonus Points");
    }

    char color[BP_CURRENCY_COLOR_MAX];
    color[0] = '\0';
    if (g_CvarCurrencyColor != null)
    {
        g_CvarCurrencyColor.GetString(color, sizeof(color));
        TrimString(color);
    }

    if (color[0] == '\0')
    {
        strcopy(color, sizeof(color), "magenta");
    }

    if (color[0] == '{')
    {
        strcopy(g_CurrencyColorTag, sizeof(g_CurrencyColorTag), color);
    }
    else
    {
        Format(g_CurrencyColorTag, sizeof(g_CurrencyColorTag), "{%s}", color);
    }

    Format(g_CurrencyPrefix, sizeof(g_CurrencyPrefix), "%s[%s]{default}", g_CurrencyColorTag, g_CurrencyShortLabel);
    Bounties_RefreshPrefix();
}

void SanitizeLogField(char[] value, int maxlen)
{
    ReplaceString(value, maxlen, "|", "/", false);
    ReplaceString(value, maxlen, "\r", " ", false);
    ReplaceString(value, maxlen, "\n", " ", false);
    ReplaceString(value, maxlen, "\t", " ", false);
    ReplaceString(value, maxlen, "\"", "'", false);
}

void GetClientLogIdentity(int client, char[] steamId, int steamLen, char[] name, int nameLen)
{
    steamId[0] = '\0';
    name[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        strcopy(steamId, steamLen, "none");
        strcopy(name, nameLen, "none");
        return;
    }

    if (!Kogasa_GetClientSteamId64(client, steamId, steamLen, true))
    {
        strcopy(steamId, steamLen, "unknown");
    }

    if (!GetClientName(client, name, nameLen) || name[0] == '\0')
    {
        strcopy(name, nameLen, "unknown");
    }

    SanitizeLogField(steamId, steamLen);
    SanitizeLogField(name, nameLen);
}

void GetClientLogClass(int client, char[] className, int maxlen)
{
    strcopy(className, maxlen, "none");

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    TF2Classes_GetKey(TF2_GetPlayerClass(client), className, maxlen, "unknown");

    SanitizeLogField(className, maxlen);
}

bool IsBonusPointsNumericTargetType(const char[] type)
{
    return StrEqual(type, "killstreak", false)
        || StrEqual(type, "killstreak_5_10", false)
        || StrEqual(type, "killstreak_above_10", false)
        || StrEqual(type, "killstreak_end", false)
        || StrEqual(type, "killstreak_end_7_14", false)
        || StrEqual(type, "killstreak_end_15_19", false)
        || StrEqual(type, "killstreak_end_20_plus", false)
        || StrEqual(type, "multikill", false)
        || StrEqual(type, "multikill_3_4", false)
        || StrEqual(type, "multikill_5_plus", false)
        || StrEqual(type, "medic_assists", false)
        || StrEqual(type, "medic_high_uber_kill", false);
}

bool IsPointsEventLoggingEnabled()
{
    return g_CvarEventLogging != null && g_CvarEventLogging.BoolValue;
}

bool IsWelfareEnabled()
{
    return g_CvarEnableWelfare != null && g_CvarEnableWelfare.BoolValue;
}

int GetWelfareMinPlayers()
{
    if (g_CvarWelfareMinPlayers == null)
    {
        return 0;
    }

    int minPlayers = g_CvarWelfareMinPlayers.IntValue;
    return minPlayers > 0 ? minPlayers : 0;
}

int GetWelfareHumanPlayerCount()
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Client_IsHumanInGame(client))
        {
            count++;
        }
    }
    return count;
}

void QueuePointsStoreEvent(const char[] message)
{
    char eventName[64];
    GetPointsStoreEventName(message, eventName, sizeof(eventName));
    PluginStats_Record(eventName, message);
}

void GetPointsStoreEventName(const char[] message, char[] output, int maxlen)
{
    int read = strncmp(message, "event=", 6, false) == 0 ? 6 : 0;
    int write = 0;
    while (message[read] && message[read] != '|' && write < maxlen - 1)
    {
        char c = message[read++];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
        {
            output[write++] = c;
        }
    }
    output[write] = '\0';
    if (!output[0])
    {
        strcopy(output, maxlen, "points_store_event");
    }
}

void LogPointsStoreEvent(const char[] format, any ...)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char message[BP_EVENT_LOG_LINE_MAX];
    VFormat(message, sizeof(message), format, 2);
    QueuePointsStoreEvent(message);
}

void LogBonusPointsDelta(int client, int delta, int balanceBefore, int balanceAfter, const char[] type, int target, bool playSound, bool chatAlert, float randomChance, bool saveQueued, int perMap = 0, int perMapUsed = 0, const char[] targetNameSnapshot = "")
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));
    GetClientLogClass(client, clientClass, sizeof(clientClass));

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));

    int targetValue = target;
    int targetClient = 0;
    char targetSteamId[32];
    char targetName[MAX_NAME_LENGTH];
    char targetClass[16];
    strcopy(targetSteamId, sizeof(targetSteamId), "none");
    strcopy(targetName, sizeof(targetName), "none");
    strcopy(targetClass, sizeof(targetClass), "none");

    if (!IsBonusPointsNumericTargetType(type) && target > 0 && target <= MaxClients && IsClientConnected(target))
    {
        targetClient = target;
        GetClientLogIdentity(target, targetSteamId, sizeof(targetSteamId), targetName, sizeof(targetName));
        GetClientLogClass(target, targetClass, sizeof(targetClass));
    }
    else if (targetNameSnapshot[0] != '\0')
    {
        strcopy(targetName, sizeof(targetName), targetNameSnapshot);
        SanitizeLogField(targetName, sizeof(targetName));
    }

    LogPointsStoreEvent(
        "event=bp_delta|time=%d|client=%d|steamid64=%s|name=\"%s\"|class=%s|delta=%d|balance_before=%d|balance_after=%d|type=%s|target_value=%d|target_client=%d|target_steamid64=%s|target_name=\"%s\"|target_class=%s|play_sound=%d|chat_alert=%d|random_chance=%.3f|save_queued=%d|per_map=%d|per_map_used=%d",
        GetTime(),
        client,
        steamId,
        clientName,
        clientClass,
        delta,
        balanceBefore,
        balanceAfter,
        safeType,
        targetValue,
        targetClient,
        targetSteamId,
        targetName,
        targetClass,
        playSound ? 1 : 0,
        chatAlert ? 1 : 0,
        randomChance,
        saveQueued ? 1 : 0,
        perMap,
        perMapUsed);
}

void LogBonusPointsRejected(const char[] reason, int client, int points, const char[] type, int target, int balance, float randomChance, float randomRoll, int perMap = 0, int perMapUsed = 0)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));
    GetClientLogClass(client, clientClass, sizeof(clientClass));

    char safeReason[64];
    char safeType[64];
    strcopy(safeReason, sizeof(safeReason), reason);
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeReason, sizeof(safeReason));
    SanitizeLogField(safeType, sizeof(safeType));

    LogPointsStoreEvent(
        "event=bp_rejected|time=%d|reason=%s|client=%d|steamid64=%s|name=\"%s\"|class=%s|requested_delta=%d|balance=%d|type=%s|target_value=%d|random_chance=%.3f|random_roll=%.3f|per_map=%d|per_map_used=%d",
        GetTime(),
        safeReason,
        client,
        steamId,
        clientName,
        clientClass,
        points,
        balance,
        safeType,
        target,
        randomChance,
        randomRoll,
        perMap,
        perMapUsed);
}

void LogBonusPointsDeferredQueue(int client, int points, const char[] type, int target, float delay, bool playSound, bool chatAlert, float randomChance, int perMap = 0)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));
    GetClientLogClass(client, clientClass, sizeof(clientClass));

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));

    LogPointsStoreEvent(
        "event=bp_deferred_queue|time=%d|client=%d|steamid64=%s|name=\"%s\"|class=%s|requested_delta=%d|type=%s|target_value=%d|delay=%.2f|play_sound=%d|chat_alert=%d|random_chance=%.3f|per_map=%d",
        GetTime(),
        client,
        steamId,
        clientName,
        clientClass,
        points,
        safeType,
        target,
        delay,
        playSound ? 1 : 0,
        chatAlert ? 1 : 0,
        randomChance,
        perMap);
}

void LogPurchaseEvent(const char[] eventName, const char[] reason, int client, const char[] itemKey, const char[] itemName, int price, int balance)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));
    GetClientLogClass(client, clientClass, sizeof(clientClass));

    char safeEvent[64];
    char safeReason[64];
    char safeItemKey[BP_TRANS_ITEM_KEY_MAX];
    char safeItemName[BP_TRANS_ITEM_NAME_MAX];
    strcopy(safeEvent, sizeof(safeEvent), eventName);
    strcopy(safeReason, sizeof(safeReason), reason);
    strcopy(safeItemKey, sizeof(safeItemKey), itemKey);
    strcopy(safeItemName, sizeof(safeItemName), itemName);
    SanitizeLogField(safeEvent, sizeof(safeEvent));
    SanitizeLogField(safeReason, sizeof(safeReason));
    SanitizeLogField(safeItemKey, sizeof(safeItemKey));
    SanitizeLogField(safeItemName, sizeof(safeItemName));

    LogPointsStoreEvent(
        "event=%s|time=%d|reason=%s|client=%d|steamid64=%s|name=\"%s\"|class=%s|item_key=%s|item_name=\"%s\"|price=%d|balance=%d",
        safeEvent,
        GetTime(),
        safeReason,
        client,
        steamId,
        clientName,
        clientClass,
        safeItemKey,
        safeItemName,
        price,
        balance);
}

void LogTransferEvent(const char[] eventName, const char[] reason, int sender, int target, int amount)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char senderSteamId[32];
    char senderName[MAX_NAME_LENGTH];
    char senderClass[16];
    char targetSteamId[32];
    char targetName[MAX_NAME_LENGTH];
    char targetClass[16];
    GetClientLogIdentity(sender, senderSteamId, sizeof(senderSteamId), senderName, sizeof(senderName));
    GetClientLogClass(sender, senderClass, sizeof(senderClass));
    GetClientLogIdentity(target, targetSteamId, sizeof(targetSteamId), targetName, sizeof(targetName));
    GetClientLogClass(target, targetClass, sizeof(targetClass));

    char safeEvent[64];
    char safeReason[64];
    strcopy(safeEvent, sizeof(safeEvent), eventName);
    strcopy(safeReason, sizeof(safeReason), reason);
    SanitizeLogField(safeEvent, sizeof(safeEvent));
    SanitizeLogField(safeReason, sizeof(safeReason));

    LogPointsStoreEvent(
        "event=%s|time=%d|reason=%s|sender=%d|sender_steamid64=%s|sender_name=\"%s\"|sender_class=%s|target=%d|target_steamid64=%s|target_name=\"%s\"|target_class=%s|amount=%d|sender_balance=%d|target_balance=%d",
        safeEvent,
        GetTime(),
        safeReason,
        sender,
        senderSteamId,
        senderName,
        senderClass,
        target,
        targetSteamId,
        targetName,
        targetClass,
        amount,
        GetCachedBonusPoints(sender),
        GetCachedBonusPoints(target));
}

bool QueueBonusPointsDeltaSaveForSteamId(const char[] steamId, int delta)
{
    if (delta == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    if (steamId[0] == '\0')
    {
        return false;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[points_store] Failed to escape SteamID64 for bonus-point save.");
        return false;
    }

    char query[512];
    Format(query, sizeof(query),
        "INSERT INTO %s (steamid64, balance) "
        ... "VALUES ('%s', %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "balance = GREATEST(0, balance + VALUES(balance))",
        BP_BALANCE_TABLE,
        escapedSteamId,
        delta);

    g_Database.Query(SQL_OnIgnoredResult, query);
    return true;
}

bool QueueBonusPointsDeltaSaveForSteamIdWithCacheRefresh(const char[] steamId, int delta, const char[] type, int perMap, int perMapUsed)
{
    if (delta == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    if (steamId[0] == '\0')
    {
        return false;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[points_store] Failed to escape SteamID64 for bonus-point save.");
        return false;
    }

    char query[512];
    Format(query, sizeof(query),
        "INSERT INTO %s (steamid64, balance) "
        ... "VALUES ('%s', %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "balance = GREATEST(0, balance + VALUES(balance))",
        BP_BALANCE_TABLE,
        escapedSteamId,
        delta);

    DataPack pack = new DataPack();
    pack.WriteString(steamId);
    pack.WriteCell(delta);
    pack.WriteString(type);
    pack.WriteCell(perMap);
    pack.WriteCell(perMapUsed);

    g_Database.Query(SQL_OnBonusPointsSteamIdDeltaSaved, query, pack);
    return true;
}

public void SQL_OnBonusPointsSteamIdDeltaSaved(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    int delta = pack.ReadCell();
    char type[64];
    pack.ReadString(type, sizeof(type));
    int perMap = pack.ReadCell();
    int perMapUsed = pack.ReadCell();
    delete pack;

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed direct SteamID64 bonus-point save for %s: %s", steamId, error);
        return;
    }

    int client = Kogasa_FindClientBySteamId64(steamId);
    int balanceAfter = -1;
    if (client > 0 && g_ClientBonusPointsLoaded[client])
    {
        g_ClientBonusPoints[client] += delta;
        if (g_ClientBonusPoints[client] < 0)
        {
            g_ClientBonusPoints[client] = 0;
        }
        balanceAfter = g_ClientBonusPoints[client];
    }

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));
    LogPointsStoreEvent(
        "event=bp_delta_offline|time=%d|steamid64=%s|delta=%d|type=%s|per_map=%d|per_map_used=%d|client=%d|balance_after=%d",
        GetTime(),
        steamId,
        delta,
        safeType,
        perMap,
        perMapUsed,
        client,
        balanceAfter);
}

void FireIdempotentAwardResult(const char[] awardKey, bool success, bool newlyApplied)
{
    if (g_IdempotentAwardForward == null)
    {
        return;
    }

    Call_StartForward(g_IdempotentAwardForward);
    Call_PushString(awardKey);
    Call_PushCell(success);
    Call_PushCell(newlyApplied);
    Call_Finish();
}

void ApplyIdempotentAwardToCache(const char[] steamId, int amount, const char[] type)
{
    int client = Kogasa_FindClientBySteamId64(steamId);
    int balanceAfter = -1;
    if (client > 0 && g_ClientBonusPointsLoaded[client])
    {
        g_ClientBonusPoints[client] += amount;
        balanceAfter = g_ClientBonusPoints[client];
    }

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));
    LogPointsStoreEvent(
        "event=bp_idempotent_award|time=%d|steamid64=%s|amount=%d|type=%s|client=%d|balance_after=%d",
        GetTime(),
        steamId,
        amount,
        safeType,
        client,
        balanceAfter);
}

bool QueueIdempotentBonusPointsAward(const char[] steamId, int amount, const char[] awardKey, const char[] type)
{
    if (!g_DatabaseReady || !g_IdempotentAwardsReady || g_Database == null
        || steamId[0] == '\0' || amount <= 0 || awardKey[0] == '\0')
    {
        return false;
    }

    int steamLen = strlen(steamId);
    if (steamLen < 16 || steamLen >= 32 || strlen(awardKey) >= BP_IDEMPOTENT_KEY_MAX)
    {
        return false;
    }

    for (int i = 0; i < steamLen; i++)
    {
        if (!IsCharNumeric(steamId[i]))
        {
            return false;
        }
    }

    char escapedSteam[65];
    char escapedKey[(BP_IDEMPOTENT_KEY_MAX * 2) + 1];
    char escapedType[129];
    if (!EscapeSql(steamId, escapedSteam, sizeof(escapedSteam))
        || !EscapeSql(awardKey, escapedKey, sizeof(escapedKey))
        || !EscapeSql(type, escapedType, sizeof(escapedType)))
    {
        return false;
    }

    Transaction txn = new Transaction();
    char query[768];
    Format(query, sizeof(query),
        "INSERT INTO %s (award_key, steamid64, amount, reason, created_at) "
        ... "VALUES ('%s', '%s', %d, '%s', %d)",
        BP_IDEMPOTENT_AWARDS_TABLE,
        escapedKey,
        escapedSteam,
        amount,
        escapedType,
        GetTime());
    txn.AddQuery(query);

    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) VALUES ('%s', %d) "
            ... "ON DUPLICATE KEY UPDATE balance = GREATEST(0, balance + VALUES(balance))",
            BP_BALANCE_TABLE,
            escapedSteam,
            amount);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) VALUES ('%s', %d) "
            ... "ON CONFLICT(steamid64) DO UPDATE SET balance = MAX(0, balance + excluded.balance)",
            BP_BALANCE_TABLE,
            escapedSteam,
            amount);
    }
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteString(awardKey);
    pack.WriteString(steamId);
    pack.WriteCell(amount);
    pack.WriteString(type);
    g_Database.Execute(txn, SQLTxn_OnIdempotentAwardSuccess, SQLTxn_OnIdempotentAwardFailure, pack);
    return true;
}

public void SQLTxn_OnIdempotentAwardSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char awardKey[BP_IDEMPOTENT_KEY_MAX];
    char steamId[32];
    char type[64];
    pack.ReadString(awardKey, sizeof(awardKey));
    pack.ReadString(steamId, sizeof(steamId));
    int amount = pack.ReadCell();
    pack.ReadString(type, sizeof(type));
    delete pack;

    ApplyIdempotentAwardToCache(steamId, amount, type);
    FireIdempotentAwardResult(awardKey, true, true);
}

public void SQLTxn_OnIdempotentAwardFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char awardKey[BP_IDEMPOTENT_KEY_MAX];
    char steamId[32];
    char type[64];
    pack.ReadString(awardKey, sizeof(awardKey));
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadCell();
    pack.ReadString(type, sizeof(type));

    bool duplicate = StrContains(error, "Duplicate entry", false) != -1
        || StrContains(error, "UNIQUE constraint failed", false) != -1;
    if (!duplicate)
    {
        LogError("[points_store] Idempotent award '%s' failed at query %d: %s", awardKey, failIndex, error);
        delete pack;
        FireIdempotentAwardResult(awardKey, false, false);
        return;
    }

    char escapedKey[(BP_IDEMPOTENT_KEY_MAX * 2) + 1];
    if (!EscapeSql(awardKey, escapedKey, sizeof(escapedKey)))
    {
        delete pack;
        FireIdempotentAwardResult(awardKey, false, false);
        return;
    }

    char query[384];
    Format(query, sizeof(query),
        "SELECT steamid64, amount, reason FROM %s WHERE award_key = '%s' LIMIT 1",
        BP_IDEMPOTENT_AWARDS_TABLE,
        escapedKey);
    g_Database.Query(SQL_OnIdempotentAwardVerified, query, pack);
}

public void SQL_OnIdempotentAwardVerified(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char awardKey[BP_IDEMPOTENT_KEY_MAX];
    char expectedSteamId[32];
    char expectedType[64];
    pack.ReadString(awardKey, sizeof(awardKey));
    pack.ReadString(expectedSteamId, sizeof(expectedSteamId));
    int expectedAmount = pack.ReadCell();
    pack.ReadString(expectedType, sizeof(expectedType));
    delete pack;

    if (error[0] != '\0' || results == null || !results.FetchRow())
    {
        LogError("[points_store] Could not verify existing idempotent award '%s': %s", awardKey, error);
        FireIdempotentAwardResult(awardKey, false, false);
        return;
    }

    char actualSteamId[32];
    char actualType[64];
    results.FetchString(0, actualSteamId, sizeof(actualSteamId));
    int actualAmount = results.FetchInt(1);
    results.FetchString(2, actualType, sizeof(actualType));

    bool matches = StrEqual(actualSteamId, expectedSteamId, false)
        && actualAmount == expectedAmount
        && StrEqual(actualType, expectedType, false);
    if (!matches)
    {
        LogError("[points_store] Idempotent award key collision for '%s'.", awardKey);
    }
    FireIdempotentAwardResult(awardKey, matches, false);
}

bool QueueBonusPointsDeltaSave(int client, int delta)
{
    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return false;
    }

    return QueueBonusPointsDeltaSaveForSteamId(steamId, delta);
}

bool ShouldRecordCurrencySpend(const char[] type)
{
    if (StrEqual(type, "transfer_out", false)
        || StrEqual(type, "transfer_in", false)
        || StrEqual(type, "transfer_refund", false)
        || StrEqual(type, "welfare", false))
    {
        return false;
    }

    if (StrContains(type, "lottery_", false) == 0)
    {
        return false;
    }

    return true;
}

bool QueueEconomyDelta(const char[] statKey, int delta)
{
    if (delta == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    char escapedKey[(BP_ECONOMY_KEY_MAX * 2) + 1];
    if (!EscapeSql(statKey, escapedKey, sizeof(escapedKey)))
    {
        LogError("[points_store] Failed to escape economy key '%s'.", statKey);
        return false;
    }

    char query[512];
    int now = GetTime();
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (stat_key, value, updated_at) VALUES ('%s', %d, %d) ON DUPLICATE KEY UPDATE value = GREATEST(0, value + VALUES(value)), updated_at = VALUES(updated_at)",
            BP_ECONOMY_TABLE,
            escapedKey,
            delta,
            now);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (stat_key, value, updated_at) VALUES ('%s', %d, %d) ON CONFLICT(stat_key) DO UPDATE SET value = MAX(0, value + excluded.value), updated_at = excluded.updated_at",
            BP_ECONOMY_TABLE,
            escapedKey,
            delta,
            now);
    }

    g_Database.Query(SQL_OnIgnoredResult, query);
    return true;
}

void LogEconomyEvent(const char[] eventName, int client, int amount, const char[] type, int target, int welfarePool, int cumulativeSpent)
{
    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));
    GetClientLogClass(client, clientClass, sizeof(clientClass));

    char safeEvent[64];
    char safeType[64];
    strcopy(safeEvent, sizeof(safeEvent), eventName);
    if (type[0] == '\0')
    {
        strcopy(safeType, sizeof(safeType), "unspecified");
    }
    else
    {
        strcopy(safeType, sizeof(safeType), type);
    }
    SanitizeLogField(safeEvent, sizeof(safeEvent));
    SanitizeLogField(safeType, sizeof(safeType));

    char message[BP_EVENT_LOG_LINE_MAX];
    Format(message, sizeof(message),
        "event=%s|time=%d|client=%d|steamid64=%s|name=\"%s\"|class=%s|amount=%d|type=%s|target_value=%d|welfare_pool=%d|cumulative_spent=%d",
        safeEvent,
        GetTime(),
        client,
        steamId,
        clientName,
        clientClass,
        amount,
        safeType,
        target,
        welfarePool,
        cumulativeSpent);
    QueuePointsStoreEvent(message);
}

void RecordCurrencySpend(int client, int amount, const char[] type, int target)
{
    if (amount <= 0 || !ShouldRecordCurrencySpend(type))
    {
        return;
    }

    if (QueueEconomyDelta(BP_ECONOMY_WELFARE_POOL_KEY, amount))
    {
        g_WelfarePoolBalance += amount;
    }
    if (QueueEconomyDelta(BP_ECONOMY_CUMULATIVE_SPENT_KEY, amount))
    {
        g_CumulativeSpentBalance += amount;
    }

    LogEconomyEvent("currency_spent", client, amount, type, target, g_WelfarePoolBalance, g_CumulativeSpentBalance);
}

void PlayBonusPointsSound(int client, bool force)
{
    SaySounds_TryPlayCommand(client, BP_SOUND_COMMAND, force);
}

void PlayWelfareSound()
{
    SaySounds_TryPlayCommand(0, BP_WELFARE_SOUND_COMMAND);
}

void PlayLevelUpSound(int client)
{
    SaySounds_TryPlayCommand(client, BP_LEVEL_UP_SOUND_COMMAND, true);
}

bool CrossedBonusPointsMilestone(int balanceBefore, int balanceAfter)
{
    return balanceAfter > balanceBefore
        && (balanceBefore / BP_BALANCE_MILESTONE) < (balanceAfter / BP_BALANCE_MILESTONE);
}

void AnnounceBonusPointsMilestone(int client, int balance)
{
    if (!Client_IsHumanInGame(client))
    {
        return;
    }

    char prefix[96];
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char displayName[256];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));

    CPrintToChatAllEx(client, "%s %s{default} now has %s%d %s{default}!", prefix, displayName, colorTag, balance, currencyLong);
    PlayLevelUpSound(client);
}


bool BuildPerMapAwardKeyForSteamId(const char[] steamId, const char[] type, char[] key, int maxlen)
{
    key[0] = '\0';

    if (g_PerMapAwardCounts == null || steamId[0] == '\0' || type[0] == '\0')
    {
        return false;
    }

    Format(key, maxlen, "%s:%s", steamId, type);
    return true;
}

bool BuildPerMapAwardKey(int client, const char[] type, char[] key, int maxlen)
{
    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        key[0] = '\0';
        return false;
    }

    return BuildPerMapAwardKeyForSteamId(steamId, type, key, maxlen);
}

int GetPerMapAwardCount(int client, const char[] type)
{
    if (!g_PerMapAwardsReady)
    {
        return 0;
    }

    char key[128];
    if (!BuildPerMapAwardKey(client, type, key, sizeof(key)))
    {
        return 0;
    }

    int count = 0;
    g_PerMapAwardCounts.GetValue(key, count);
    return count;
}

bool CanApplyPerMapAward(int client, int points, const char[] type, int perMap, int &used)
{
    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        used = 0;
        return false;
    }

    return CanApplyPerMapAwardForSteamId(steamId, points, type, perMap, used);
}

bool CanApplyPerMapAwardForSteamId(const char[] steamId, int points, const char[] type, int perMap, int &used)
{
    used = 0;
    if (points <= 0 || perMap <= 0)
    {
        return true;
    }
    if (!g_PerMapAwardsReady)
    {
        return false;
    }

    char key[128];
    if (!BuildPerMapAwardKeyForSteamId(steamId, type, key, sizeof(key)))
    {
        return false;
    }

    g_PerMapAwardCounts.GetValue(key, used);
    return used < perMap;
}

int IncrementPerMapAwardCount(int client, const char[] type)
{
    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return 0;
    }

    return IncrementPerMapAwardCountForSteamId(steamId, type);
}

int IncrementPerMapAwardCountForSteamId(const char[] steamId, const char[] type)
{
    char key[128];
    if (!BuildPerMapAwardKeyForSteamId(steamId, type, key, sizeof(key)))
    {
        return 0;
    }

    int count = 0;
    g_PerMapAwardCounts.GetValue(key, count);
    count++;
    g_PerMapAwardCounts.SetValue(key, count, true);
    if (!QueuePerMapAwardIncrement(steamId, type))
    {
        LogError("[points_store] Failed to persist per-map award '%s' for %s.", type, steamId);
    }
    return count;
}

bool QueuePerMapAwardIncrement(const char[] steamId, const char[] type)
{
    if (!g_PerMapAwardsReady || !g_DatabaseReady || g_Database == null
        || steamId[0] == '\0' || type[0] == '\0')
    {
        return false;
    }

    char escapedMap[257];
    char escapedSteamId[65];
    char escapedType[129];
    if (!EscapeSql(g_PerMapName, escapedMap, sizeof(escapedMap))
        || !EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(type, escapedType, sizeof(escapedType)))
    {
        return false;
    }

    char query[1024];
    int now = GetTime();
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (server_port, map_name, steamid64, reward_id, award_count, updated_at) "
            ... "VALUES (%d, '%s', '%s', '%s', 1, %d) "
            ... "ON DUPLICATE KEY UPDATE award_count = award_count + 1, updated_at = VALUES(updated_at)",
            BP_PER_MAP_AWARDS_TABLE,
            g_PerMapServerPort,
            escapedMap,
            escapedSteamId,
            escapedType,
            now);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (server_port, map_name, steamid64, reward_id, award_count, updated_at) "
            ... "VALUES (%d, '%s', '%s', '%s', 1, %d) "
            ... "ON CONFLICT(server_port, map_name, steamid64, reward_id) DO UPDATE SET "
            ... "award_count = award_count + 1, updated_at = excluded.updated_at",
            BP_PER_MAP_AWARDS_TABLE,
            g_PerMapServerPort,
            escapedMap,
            escapedSteamId,
            escapedType,
            now);
    }

    g_Database.Query(SQL_OnIgnoredResult, query);
    return true;
}

void BuildPerMapAwardSuffix(int perMapUsed, int perMap, char[] suffix, int maxlen)
{
    suffix[0] = '\0';
    if (perMap > 0 && perMapUsed > 0)
    {
        Format(suffix, maxlen, " (%d/%d)", perMapUsed, perMap);
    }
}

bool ApplyBonusPointsNow(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, int perMap = 0, const char[] targetNameSnapshot = "", bool announceMilestone = false)
{
    if (!Client_IsHumanInGame(client) || points == 0)
    {
        LogBonusPointsRejected(!Client_IsHumanInGame(client) ? "invalid_client" : "zero_delta", client, points, type, target, 0, randomChance, 0.0);
        return false;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        LogBonusPointsRejected("balance_not_loaded", client, points, type, target, 0, randomChance, 0.0);
        return false;
    }

    if (points < 0 && g_BountyPlacementPending[client])
    {
        LogBonusPointsRejected("bounty_placement_pending", client, points, type, target, g_ClientBonusPoints[client], randomChance, 0.0);
        return false;
    }

    if (randomChance < 0.1)
    {
        randomChance = 0.1;
    }
    else if (randomChance > 1.0)
    {
        randomChance = 1.0;
    }

    float randomRoll = GetRandomFloat(0.0, 1.0);
    if (randomRoll > randomChance)
    {
        if (g_CvarLogRandomMisses != null && g_CvarLogRandomMisses.BoolValue)
        {
            LogBonusPointsRejected("random_chance_failed", client, points, type, target, GetCachedBonusPoints(client), randomChance, randomRoll);
        }
        return false;
    }

    if (points < 0 && g_ClientBonusPoints[client] < -points)
    {
        LogBonusPointsRejected("insufficient_points", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll, perMap, 0);
        return false;
    }

    int perMapUsed = 0;
    if (points > 0 && perMap > 0 && !g_PerMapAwardsReady)
    {
        LogBonusPointsRejected("per_map_state_not_ready", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll, perMap, 0);
        return false;
    }
    if (!CanApplyPerMapAward(client, points, type, perMap, perMapUsed))
    {
        LogBonusPointsRejected("per_map_limit", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll, perMap, perMapUsed);
        return false;
    }

    int balanceBefore = g_ClientBonusPoints[client];
    g_ClientBonusPoints[client] += points;
    if (g_ClientBonusPoints[client] < 0)
    {
        g_ClientBonusPoints[client] = 0;
    }

    bool saveQueued = QueueBonusPointsDeltaSave(client, points);
    if (points > 0 && perMap > 0)
    {
        perMapUsed = IncrementPerMapAwardCount(client, type);
    }
    LogBonusPointsDelta(client, points, balanceBefore, g_ClientBonusPoints[client], type, target, playSound, chatAlert, randomChance, saveQueued, perMap, perMapUsed, targetNameSnapshot);
    if (!saveQueued)
    {
        LogBonusPointsRejected("save_not_queued", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll, perMap, perMapUsed);
    }
    else if (points < 0)
    {
        RecordCurrencySpend(client, -points, type, target);
    }

    if (saveQueued && announceMilestone && points > 0 && CrossedBonusPointsMilestone(balanceBefore, g_ClientBonusPoints[client]))
    {
        AnnounceBonusPointsMilestone(client, g_ClientBonusPoints[client]);
    }

    if (saveQueued && points > 0 && perMap > 1 && perMapUsed == perMap)
    {
        CreateTimer(3.0, Timer_CompletionBonus, GetClientUserId(client));
    }

    if (playSound)
    {
        PlayBonusPointsSound(client, true);
    }

    if (!chatAlert)
    {
        return true;
    }

    PrintBonusPointsDelta(client, points, type, target, perMapUsed, perMap, targetNameSnapshot);
    return true;
}

public Action Timer_CompletionBonus(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);
    RewardDefinition reward;
    if (GetRewardDefinition("completion_bonus", reward)
        && ApplyBonusPointsNow(
            client,
            reward.amount,
            false,
            true,
            1.0,
            reward.id,
            0,
            reward.perMapLimit))
    {
        PlayLevelUpSound(client);
    }
    return Plugin_Stop;
}

bool ApplyBonusPoints(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0, int perMap = 0, bool announceMilestone = false)
{
    if (delay < 0.0)
    {
        delay = 0.0;
    }

    if (delay == 0.0)
    {
        return ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target, perMap, "", announceMilestone);
    }

    if (!Client_IsHumanInGame(client) || points == 0)
    {
        LogBonusPointsRejected(!Client_IsHumanInGame(client) ? "deferred_invalid_client" : "deferred_zero_delta", client, points, type, target, 0, randomChance, 0.0);
        return false;
    }

    LogBonusPointsDeferredQueue(client, points, type, target, delay, playSound, chatAlert, randomChance, perMap);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(points);
    pack.WriteCell(playSound ? 1 : 0);
    pack.WriteCell(chatAlert ? 1 : 0);
    pack.WriteFloat(randomChance);
    pack.WriteString(type);
    pack.WriteCell(perMap);
    char targetNameSnapshot[256];
    targetNameSnapshot[0] = '\0';
    if (IsBonusPointsNumericTargetType(type))
    {
        pack.WriteCell(target);
    }
    else
    {
        if (Client_IsHumanInGame(target))
        {
            BuildPurchaseDisplayName(target, targetNameSnapshot, sizeof(targetNameSnapshot));
        }
        pack.WriteCell(Client_IsHumanInGame(target) ? GetClientUserId(target) : 0);
    }
    pack.WriteString(targetNameSnapshot);
    pack.WriteCell(announceMilestone ? 1 : 0);

    CreateTimer(delay, Timer_DeferredApplyBonusPoints, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    return true;
}

bool ApplyBonusPointsSteamId(const char[] steamId, int points, bool playSound = true, bool chatAlert = true, const char[] type = "", int perMap = 0, bool announceMilestone = false)
{
    if (steamId[0] == '\0' || points == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    int client = Kogasa_FindClientBySteamId64(steamId);
    if (client > 0 && AreBonusPointsReady(client))
    {
        return ApplyBonusPointsNow(client, points, playSound, chatAlert, 1.0, type, 0, perMap, "", announceMilestone);
    }

    int perMapUsed = 0;
    if (!CanApplyPerMapAwardForSteamId(steamId, points, type, perMap, perMapUsed))
    {
        return false;
    }

    if (points > 0 && perMap > 0)
    {
        perMapUsed = IncrementPerMapAwardCountForSteamId(steamId, type);
    }

    if (!QueueBonusPointsDeltaSaveForSteamIdWithCacheRefresh(steamId, points, type, perMap, perMapUsed))
    {
        return false;
    }

    return true;
}

bool SpendBonusPointsWithContext(int client, int points, const char[] type, int target = 0)
{
    if (points <= 0)
    {
        return false;
    }

    return ApplyBonusPoints(client, -points, false, false, 1.0, type, target, 0.0);
}

int StealBonusPointsWithContext(int victim, int recipient, int points, const char[] type)
{
    if (points <= 0 || victim == recipient || !g_DatabaseReady || g_Database == null)
    {
        return 0;
    }

    if (!Client_IsHumanInGame(victim) || !Client_IsHumanInGame(recipient))
    {
        return 0;
    }

    if (!AreBonusPointsReady(victim))
    {
        LoadClientBonusPoints(victim);
        return 0;
    }

    if (!AreBonusPointsReady(recipient))
    {
        LoadClientBonusPoints(recipient);
        return 0;
    }

    int actual = points;
    if (g_ClientBonusPoints[victim] < actual)
    {
        actual = g_ClientBonusPoints[victim];
    }

    if (actual <= 0)
    {
        return 0;
    }

    int victimBefore = g_ClientBonusPoints[victim];
    int recipientBefore = g_ClientBonusPoints[recipient];

    g_ClientBonusPoints[victim] -= actual;
    if (g_ClientBonusPoints[victim] < 0)
    {
        g_ClientBonusPoints[victim] = 0;
    }
    g_ClientBonusPoints[recipient] += actual;

    bool victimSaveQueued = QueueBonusPointsDeltaSave(victim, -actual);
    bool recipientSaveQueued = QueueBonusPointsDeltaSave(recipient, actual);

    LogBonusPointsDelta(victim, -actual, victimBefore, g_ClientBonusPoints[victim], type, recipient, false, false, 1.0, victimSaveQueued);
    LogBonusPointsDelta(recipient, actual, recipientBefore, g_ClientBonusPoints[recipient], type, victim, false, false, 1.0, recipientSaveQueued);

    if (!victimSaveQueued || !recipientSaveQueued)
    {
        LogBonusPointsRejected("steal_save_not_queued", victim, -actual, type, recipient, g_ClientBonusPoints[victim], 1.0, 0.0);
        LogBonusPointsRejected("steal_save_not_queued", recipient, actual, type, victim, g_ClientBonusPoints[recipient], 1.0, 0.0);
    }

    return actual;
}

void BuildCallerSpendType(Handle plugin, char[] type, int maxlen)
{
    char filename[PLATFORM_MAX_PATH];
    GetPluginFilename(plugin, filename, sizeof(filename));
    if (filename[0] == '\0')
    {
        strcopy(type, maxlen, "spend_unknown");
        return;
    }

    ReplaceString(filename, sizeof(filename), ".smx", "", false);
    ReplaceString(filename, sizeof(filename), "/", "_", false);
    ReplaceString(filename, sizeof(filename), "\\", "_", false);
    Format(type, maxlen, "spend_%s", filename);
}

public Action Timer_DeferredApplyBonusPoints(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int client = GetClientOfUserId(pack.ReadCell());
    int points = pack.ReadCell();
    bool playSound = pack.ReadCell() != 0;
    bool chatAlert = pack.ReadCell() != 0;
    float randomChance = pack.ReadFloat();
    char type[64];
    pack.ReadString(type, sizeof(type));
    int perMap = pack.ReadCell();
    int targetValue = pack.ReadCell();
    char targetNameSnapshot[256];
    pack.ReadString(targetNameSnapshot, sizeof(targetNameSnapshot));
    bool announceMilestone = pack.ReadCell() != 0;
    int target = IsBonusPointsNumericTargetType(type) ? targetValue : GetClientOfUserId(targetValue);

    ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target, perMap, targetNameSnapshot, announceMilestone);
    return Plugin_Stop;
}

void PrintBonusPointsDelta(int client, int points, const char[] type, int target, int perMapUsed = 0, int perMap = 0, const char[] targetNameSnapshot = "")
{
    char prefix[96];
    GetCurrencyPrefix(prefix, sizeof(prefix));

    if (points < 0)
    {
        CPrintToChat(client, "%s{limegreen}%i", prefix, points);
        return;
    }

    char sign[2];
    sign[0] = '+';
    sign[1] = '\0';

    char perMapSuffix[24];
    BuildPerMapAwardSuffix(perMapUsed, perMap, perMapSuffix, sizeof(perMapSuffix));

    if (StrEqual(type, "points_diff", false) && Client_IsHumanInGame(target))
    {
        char targetName[256];
        BuildPurchaseDisplayName(target, targetName, sizeof(targetName));
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}killing{default} %s%s", prefix, sign, points, targetName, perMapSuffix);
        return;
    }
    if (StrEqual(type, "points_diff", false) && targetNameSnapshot[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}killing{default} %s%s", prefix, sign, points, targetNameSnapshot, perMapSuffix);
        return;
    }

    if (StrEqual(type, "top_score_kill", false) && Client_IsHumanInGame(target))
    {
        char targetName[256];
        BuildPurchaseDisplayName(target, targetName, sizeof(targetName));
        CPrintToChat(client, "%s {limegreen}%s%i{default} for killing {gold}Top-scoring player{default} (%s)%s", prefix, sign, points, targetName, perMapSuffix);
        return;
    }
    if (StrEqual(type, "top_score_kill", false) && targetNameSnapshot[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for killing {gold}Top-scoring player{default} (%s)%s", prefix, sign, points, targetNameSnapshot, perMapSuffix);
        return;
    }

    if (StrEqual(type, "player_dom", false) && Client_IsHumanInGame(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Dominating{default} %N%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "player_revenge", false) && Client_IsHumanInGame(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Revenge{default} on %N%s", prefix, sign, points, target, perMapSuffix);
        return;
    }
    if (StrEqual(type, "player_revenge", false) && targetNameSnapshot[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Revenge{default} on %s%s", prefix, sign, points, targetNameSnapshot, perMapSuffix);
        return;
    }

    if (StrEqual(type, "killstreak", false)
        || StrEqual(type, "killstreak_5_10", false)
        || StrEqual(type, "killstreak_above_10", false))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Killstreak: %d{default}%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "multikill", false)
        || StrEqual(type, "multikill_3_4", false)
        || StrEqual(type, "multikill_5_plus", false))
    {
        char multikillLabel[32];
        GetMultikillBonusPointsLabel(target, multikillLabel, sizeof(multikillLabel));
        if (multikillLabel[0] != '\0')
        {
            CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%s{default}%s", prefix, sign, points, multikillLabel, perMapSuffix);
        }
        else
        {
            CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Multikill: %d{default}%s", prefix, sign, points, target, perMapSuffix);
        }
        return;
    }

    if (StrEqual(type, "medic_assists", false))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Assists: %d{default}%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "medic_high_uber_kill", false))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Medic high ÜberCharge kill (%d%%){default}%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "medic_assists_life", false) && target > 0)
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%d assists life{default}%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    char label[64];
    GetBonusPointsTypeLabel(type, label, sizeof(label));
    if (label[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%s{default}%s", prefix, sign, points, label, perMapSuffix);
        return;
    }

    GetBonusPointsFallbackLabel(type, label, sizeof(label));
    if (label[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%s{default}%s", prefix, sign, points, label, perMapSuffix);
        return;
    }

    CPrintToChat(client, "%s {limegreen}%s%i%s", prefix, sign, points, perMapSuffix);
}

void NormalizeLeaderboardColorTag(char[] colorTag, int maxlen)
{
    TrimString(colorTag);

    if (colorTag[0] == '\0'
        || StrEqual(colorTag, "teamcolor", false)
        || StrEqual(colorTag, "{teamcolor}", false))
    {
        strcopy(colorTag, maxlen, "gold");
        return;
    }

    int len = strlen(colorTag);
    if (len >= 2 && colorTag[0] == '{' && colorTag[len - 1] == '}')
    {
        int out = 0;
        for (int i = 1; i < len - 1 && out < maxlen - 1; i++)
        {
            colorTag[out++] = colorTag[i];
        }
        colorTag[out] = '\0';
    }

    if (colorTag[0] == '\0')
    {
        strcopy(colorTag, maxlen, "gold");
    }
}

public Action Command_ShowCurrencyLeaderboard(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    char prefix[96];
    GetCurrencyPrefix(prefix, sizeof(prefix));

    if (!g_DatabaseReady || g_Database == null)
    {
        CPrintToChat(client, "%s Database is not ready.", prefix);
        return Plugin_Handled;
    }

    int page = 1;
    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        int parsed = StringToInt(arg);
        if (parsed > 0)
        {
            page = parsed;
        }
    }

    int offset = (page - 1) * BP_LEADERBOARD_PAGE_SIZE;

    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    CPrintToChat(client, "{green}[Store]{default} %s leaderboard will print momentarily...", currencyLong);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(page);

    char joinCondition[128];
    if (g_IsMySql)
    {
        strcopy(joinCondition, sizeof(joinCondition), "BINARY pc.steamid = BINARY b.steamid64");
    }
    else
    {
        strcopy(joinCondition, sizeof(joinCondition), "pc.steamid = b.steamid64");
    }

    char query[1400];
    Format(query, sizeof(query),
        "SELECT b.steamid64, b.balance, COALESCE(NULLIF(pr.newname,''), NULLIF(fs.last_name,''), b.steamid64), COALESCE(NULLIF(pc.name_color,''), 'gold') "
        ... "FROM %s b "
        ... "LEFT JOIN whaletracker_points_cache pc ON %s "
        ... "LEFT JOIN prename_rules pr ON pr.pattern = b.steamid64 "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = b.steamid64 COLLATE utf8mb4_uca1400_ai_ci "
        ... "WHERE b.balance > 0 "
        ... "ORDER BY b.balance DESC, b.steamid64 ASC "
        ... "LIMIT %d OFFSET %d",
        BP_BALANCE_TABLE,
        joinCondition,
        BP_LEADERBOARD_PAGE_SIZE,
        offset);
    g_Database.Query(PointsStore_ShowCurrencyLeaderboardCallback, query, pack);
    return Plugin_Handled;
}

public void PointsStore_ShowCurrencyLeaderboardCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int page = pack.ReadCell();
    delete pack;

    if (!Client_IsHumanInGame(client))
    {
        return;
    }

    char prefix[96];
    GetCurrencyPrefix(prefix, sizeof(prefix));

    if (error[0] != '\0')
    {
        CPrintToChat(client, "%s Failed to load currency leaderboard.", prefix);
        LogError("[points_store] Failed to load currency leaderboard: %s", error);
        return;
    }

    char currencyColor[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(currencyColor, sizeof(currencyColor));

    int rows = 0;
    while (results != null && results.FetchRow())
    {
        int rank = ((page - 1) * BP_LEADERBOARD_PAGE_SIZE) + rows + 1;
        int balance = results.FetchInt(1);

        char displayName[128];
        char colorTag[32];
        results.FetchString(2, displayName, sizeof(displayName));
        results.FetchString(3, colorTag, sizeof(colorTag));
        TrimString(displayName);
        NormalizeLeaderboardColorTag(colorTag, sizeof(colorTag));

        if (displayName[0] == '\0')
        {
            results.FetchString(0, displayName, sizeof(displayName));
            TrimString(displayName);
        }
        if (displayName[0] == '\0')
        {
            strcopy(displayName, sizeof(displayName), "Unknown");
        }

        rows++;
        CPrintToChat(client, "#%d {%s}%s{default} %s%d", rank, colorTag, displayName, currencyColor, balance);
    }

    if (rows == 0)
    {
        CPrintToChat(client, "%s No currency leaderboard entries on page %d.", prefix, page);
        return;
    }

    CPrintToChat(client, "Use !%scurrencyranks %d{default} to view the next 10 ranks!", currencyColor, page + 1);
}

public Action Command_Shop(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    if (!g_DatabaseReady || g_Database == null)
    {
        PrintToChat(client, "[Shop] The shop database is not ready.");
        return Plugin_Handled;
    }

    if (!g_ClientPurchasesLoaded[client])
    {
        PrintToChat(client, "[Shop] Your purchases are loading. Try again in a moment.");
        LoadClientPurchases(client);
        return Plugin_Handled;
    }

    ShowShopMenu(client);
    return Plugin_Handled;
}

public Action Command_ShowBonusPoints(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    int target = client;
    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);
        if (targetArg[0])
        {
            int targets[MAXPLAYERS];
            char targetName[MAX_TARGET_LENGTH];
            bool targetNameIsMl;
            int count = ProcessTargetString(
                targetArg,
                client,
                targets,
                sizeof(targets),
                COMMAND_FILTER_NO_BOTS,
                targetName,
                sizeof(targetName),
                targetNameIsMl);
            if (count == 1 && Client_IsHumanInGame(targets[0]))
            {
                target = targets[0];
            }
            else
            {
                RequestOfflineBalanceSearch(client, targetArg);
                return Plugin_Handled;
            }
        }
    }

    if (!AreBonusPointsReady(target))
    {
        char prefix[96];
        char currencyLong[BP_CURRENCY_LONG_MAX];
        GetCurrencyPrefix(prefix, sizeof(prefix));
        GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
        LoadClientBonusPoints(target);
        CPrintToChat(client, "%s %N's %s are loading. Try again in a moment.", prefix, target, currencyLong);
        return Plugin_Handled;
    }

    char displayName[256];
    BuildPurchaseDisplayName(target, displayName, sizeof(displayName));
    PrintBonusPointsSummary(client, displayName, GetCachedBonusPoints(target));
    return Plugin_Handled;
}

void PrintBonusPointsSummary(int client, const char[] displayName, int balance)
{
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    char msg1[384];
    FormatEx(msg1, sizeof(msg1),
        "%s{default}'s %s: {lightgreen}%i{default}\n"
        ... "{lightgreen}+3{default}: Medic drops, penta-kills, ending 20+ killstreaks\n"
        ... "{lightgreen}+2{default}: Triple-kills, quadra-kills, ending 10+ killstreaks",
        displayName,
        currencyLong,
        balance);

    char msg2[256];
    FormatEx(msg2, sizeof(msg2),
        "{lightgreen}+1:{default} Airshot kills, market garden kills, ubers, killstreaks, dominations, revenge, meatshot kills, Sandman-Cleaver combos, medic assist lives");

    CPrintToChat(client, "%s", msg1);
    CPrintToChat(client, "%s", msg2);
}

void RequestOfflineBalanceSearch(int client, const char[] search)
{
    if (!g_DatabaseReady || g_Database == null)
    {
        CPrintToChat(client, "%s Player search is temporarily unavailable.", g_CurrencyPrefix);
        return;
    }

    char escapedSearch[(BP_BALANCE_SEARCH_NAME_MAX * 2) + 1];
    if (!EscapeSql(search, escapedSearch, sizeof(escapedSearch)))
    {
        CPrintToChat(client, "%s Could not search for that player.", g_CurrencyPrefix);
        return;
    }

    ConVar minKdConVar = FindConVar("sm_whaletracker_rank_min_kd_sum");
    ConVar minPlaytimeConVar = FindConVar("sm_whaletracker_rank_min_playtime_seconds");
    int minKd = minKdConVar != null ? minKdConVar.IntValue : 200;
    int minPlaytime = minPlaytimeConVar != null ? minPlaytimeConVar.IntValue : 10800;
    int generation = ++g_BalanceSearchGeneration[client];

    char query[2304];
    FormatEx(query, sizeof(query),
        "SELECT w.steamid, "
        ... "COALESCE(NULLIF(pr.newname COLLATE utf8mb4_uca1400_ai_ci, ''), NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid), "
        ... "COALESCE(b.balance, 0), GREATEST(COALESCE(w.playtime, 0), 0) "
        ... "FROM whaletracker w "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = w.steamid "
        ... "LEFT JOIN prename_rules pr ON pr.pattern COLLATE utf8mb4_uca1400_ai_ci = w.steamid "
        ... "LEFT JOIN %s b ON BINARY b.steamid64 = BINARY w.steamid "
        ... "WHERE (GREATEST(COALESCE(w.kills, 0), 0) + GREATEST(COALESCE(w.deaths, 0), 0)) >= %d "
        ... "AND GREATEST(COALESCE(w.playtime, 0), 0) >= %d "
        ... "AND (COALESCE(pr.newname, '') LIKE '%%%s%%' "
        ... "OR COALESCE(fs.last_name, '') LIKE '%%%s%%' "
        ... "OR COALESCE(w.cached_personaname, '') LIKE '%%%s%%') "
        ... "ORDER BY GREATEST(COALESCE(w.playtime, 0), 0) DESC LIMIT %d",
        BP_BALANCE_TABLE,
        minKd,
        minPlaytime,
        escapedSearch,
        escapedSearch,
        escapedSearch,
        BP_BALANCE_SEARCH_MAX);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(generation);
    pack.WriteString(search);
    g_Database.Query(SQL_OnOfflineBalanceSearch, query, pack);
}

public void SQL_OnOfflineBalanceSearch(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    char search[BP_BALANCE_SEARCH_NAME_MAX];
    pack.ReadString(search, sizeof(search));
    delete pack;

    if (!Client_IsHumanInGame(client) || generation != g_BalanceSearchGeneration[client])
    {
        return;
    }
    if (error[0])
    {
        LogError("[points_store] Offline balance search failed: %s", error);
        CPrintToChat(client, "%s Player search failed.", g_CurrencyPrefix);
        return;
    }

    Menu menu = new Menu(MenuHandler_OfflineBalanceSearch);
    menu.SetTitle("Select player balance:");
    int count = 0;
    while (rows != null && rows.FetchRow())
    {
        char steamId[32];
        char name[BP_BALANCE_SEARCH_NAME_MAX];
        char display[192];
        rows.FetchString(0, steamId, sizeof(steamId));
        rows.FetchString(1, name, sizeof(name));
        int balance = rows.FetchInt(2);
        FormatEx(display, sizeof(display), "%s (%d %s)", name, balance, g_CurrencyLongLabel);
        menu.AddItem(steamId, display);
        count++;
    }

    if (count == 0)
    {
        delete menu;
        CPrintToChat(client, "%s No ranked player matched {gold}%s{default}.", g_CurrencyPrefix, search);
        return;
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_OfflineBalanceSearch(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select || !Client_IsHumanInGame(client))
    {
        return 0;
    }

    char steamId[32];
    char escapedSteamId[65];
    menu.GetItem(item, steamId, sizeof(steamId));
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        return 0;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT COALESCE(b.balance, 0), "
        ... "COALESCE(NULLIF(pr.newname COLLATE utf8mb4_uca1400_ai_ci, ''), NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid) "
        ... "FROM whaletracker w "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = w.steamid "
        ... "LEFT JOIN prename_rules pr ON pr.pattern COLLATE utf8mb4_uca1400_ai_ci = w.steamid "
        ... "LEFT JOIN %s b ON BINARY b.steamid64 = BINARY w.steamid "
        ... "WHERE BINARY w.steamid = BINARY '%s' LIMIT 1",
        BP_BALANCE_TABLE,
        escapedSteamId);
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    g_Database.Query(SQL_OnOfflineBalanceSelected, query, pack);
    return 0;
}

public void SQL_OnOfflineBalanceSelected(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    if (!Client_IsHumanInGame(client))
    {
        return;
    }
    if (error[0] || rows == null || !rows.FetchRow())
    {
        if (error[0])
        {
            LogError("[points_store] Offline balance selection failed: %s", error);
        }
        CPrintToChat(client, "%s That player's balance could not be loaded.", g_CurrencyPrefix);
        return;
    }

    int balance = rows.FetchInt(0);
    char name[BP_BALANCE_SEARCH_NAME_MAX];
    char displayName[256];
    char colorTag[32];
    rows.FetchString(1, name, sizeof(name));
    colorTag[0] = '\0';
    if (GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdColorTag") == FeatureStatus_Available)
    {
        Filters_GetSteamIdColorTag(steamId, colorTag, sizeof(colorTag));
    }
    if (!colorTag[0])
    {
        strcopy(colorTag, sizeof(colorTag), "{default}");
    }
    FormatEx(displayName, sizeof(displayName), "%s%s", colorTag, name);
    PrintBonusPointsSummary(client, displayName, balance);
}

public Action Command_SendBonusPoints(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    char prefix[96];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    float cooldownRemaining = (GetSendBonusPointsCooldown() > 0.0) ? (g_NextSendAllowedAt[client] - GetEngineTime()) : 0.0;
    if (cooldownRemaining > 0.0)
    {
        CPrintToChat(client, "%s Wait {gold}%d{default} seconds before sending %s again.", prefix, RoundToCeil(cooldownRemaining), currencyLong);
        return Plugin_Handled;
    }

    if (args < 2)
    {
        CPrintToChat(client, "%s Usage: !sendbp <player> <amount>", prefix);
        return Plugin_Handled;
    }

    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    TrimString(targetArg);

    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0 || !Client_IsHumanInGame(target))
    {
        CPrintToChat(client, "%s Could not find player '%s'.", prefix, targetArg);
        return Plugin_Handled;
    }

    if (target == client)
    {
        CPrintToChat(client, "%s You cannot send %s to yourself.", prefix, currencyLong);
        return Plugin_Handled;
    }

    char amountArg[32];
    GetCmdArg(2, amountArg, sizeof(amountArg));
    int amount = StringToInt(amountArg);
    if (amount <= 0)
    {
        CPrintToChat(client, "%s Amount must be greater than 0.", prefix);
        return Plugin_Handled;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s Your %s are loading. Try again in a moment.", prefix, currencyLong);
        return Plugin_Handled;
    }

    if (!AreBonusPointsReady(target))
    {
        LoadClientBonusPoints(target);
        CPrintToChat(client, "%s %N's %s are loading. Try again in a moment.", prefix, target, currencyLong);
        return Plugin_Handled;
    }

    if (GetCachedBonusPoints(client) < amount)
    {
        char balanceCurrencyShort[BP_CURRENCY_SHORT_MAX];
        GetCurrencyShortLabelForAmount(GetCachedBonusPoints(client), balanceCurrencyShort, sizeof(balanceCurrencyShort));
        CPrintToChat(client, "%s You only have {lightgreen}%i{default} %s.", prefix, GetCachedBonusPoints(client), balanceCurrencyShort);
        return Plugin_Handled;
    }

    if (!ApplyBonusPoints(client, -amount, false, false, 1.0, "transfer_out", target, 0.0))
    {
        CPrintToChat(client, "%s Could not spend your %s.", prefix, currencyLong);
        return Plugin_Handled;
    }

    if (!ApplyBonusPoints(target, amount, false, false, 1.0, "transfer_in", client, 0.0))
    {
        ApplyBonusPoints(client, amount, false, false, 1.0, "transfer_refund", target, 0.0);
        LogTransferEvent("transfer_failed", "target_credit_failed", client, target, amount);
        CPrintToChat(client, "%s Could not give %s to %N.", prefix, currencyLong, target);
        return Plugin_Handled;
    }

    PlayBonusPointsSound(0, true);
    LogTransferEvent("transfer_success", "ok", client, target, amount);
    StartSendBonusPointsCooldown(client);

    char senderDisplay[256];
    char targetDisplay[256];
    char sentCurrencyShort[BP_CURRENCY_SHORT_MAX];
    BuildPurchaseDisplayName(client, senderDisplay, sizeof(senderDisplay));
    BuildPurchaseDisplayName(target, targetDisplay, sizeof(targetDisplay));
    GetCurrencyShortLabelForAmount(amount, sentCurrencyShort, sizeof(sentCurrencyShort));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!Client_IsHumanInGame(i))
        {
            continue;
        }

        CPrintToChatEx(i, client, "%s %s sent %s %i %s%s{default}!", prefix, senderDisplay, targetDisplay, amount, colorTag, sentCurrencyShort);
    }
    return Plugin_Handled;
}

public Action CommandListener_WelfareAlias(int client, const char[] command, int argc)
{
    return Command_Welfare(client, argc);
}

public Action CommandListener_WelfareChatAlias(int client, const char[] command, int argc)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Continue;
    }

    char text[32];
    GetCmdArgString(text, sizeof(text));
    TrimString(text);
    StripQuotes(text);
    TrimString(text);

    if (StrEqual(text, "gibs", false) || StrEqual(text, "welfare", false) || StrEqual(text, "ebt", false))
    {
        return Command_Welfare(client, 0);
    }

    return Plugin_Continue;
}

public Action Command_Welfare(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    char prefix[96];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    if (!IsWelfareEnabled())
    {
        CPrintToChat(client, "%s Welfare is currently disabled", prefix);
        return Plugin_Handled;
    }

    int minPlayers = GetWelfareMinPlayers();
    if (minPlayers > 0 && GetWelfareHumanPlayerCount() < minPlayers)
    {
        CPrintToChat(client, "%s Minimum playercount for welfare collection is {gold}%d", prefix, minPlayers);
        return Plugin_Handled;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s Your %s are loading. Try again in a moment.", prefix, currencyLong);
        return Plugin_Handled;
    }

    if (GetPerMapAwardCount(client, "welfare") >= 1)
    {
        CPrintToChat(client, "%s You already collected {gold}!welfare{default} this map.", prefix);
        return Plugin_Handled;
    }

    if (!g_EconomyStateLoaded)
    {
        LoadEconomyState();
        CPrintToChat(client, "%s Welfare pool is loading. Try again in a moment.", prefix);
        return Plugin_Handled;
    }

    if (g_WelfarePoolBalance <= 0)
    {
        CPrintToChat(client, "%s Welfare pool is empty right now.", prefix);
        return Plugin_Handled;
    }

    int amount = GetRandomInt(BP_WELFARE_MIN, BP_WELFARE_MAX);
    if (amount > g_WelfarePoolBalance)
    {
        amount = g_WelfarePoolBalance;
    }

    DebitWelfarePoolForClient(client, amount);
    return Plugin_Handled;
}

void DebitWelfarePoolForClient(int client, int amount)
{
    if (amount <= 0 || !g_DatabaseReady || g_Database == null)
    {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(amount);

    char query[384];
    Format(query, sizeof(query),
        "UPDATE %s SET value = value - %d, updated_at = %d WHERE stat_key = '%s' AND value >= %d",
        BP_ECONOMY_TABLE,
        amount,
        GetTime(),
        BP_ECONOMY_WELFARE_POOL_KEY,
        amount);
    g_Database.Query(SQL_OnWelfarePoolDebited, query, pack);
}

public void SQL_OnWelfarePoolDebited(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int amount = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    char prefix[96];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (error[0] != '\0')
    {
        LogError("[points_store] Welfare pool debit failed: %s", error);
        if (Client_IsHumanInGame(client))
        {
            CPrintToChat(client, "%s Could not collect welfare right now.", prefix);
        }
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LoadEconomyState();
        if (Client_IsHumanInGame(client))
        {
            CPrintToChat(client, "%s Welfare pool is empty right now.", prefix);
        }
        return;
    }

    g_WelfarePoolBalance -= amount;
    if (g_WelfarePoolBalance < 0)
    {
        g_WelfarePoolBalance = 0;
    }

    if (!Client_IsHumanInGame(client) || !ApplyBonusPoints(client, amount, false, false, 1.0, "welfare", 0, 0.0, 1))
    {
        QueueEconomyDelta(BP_ECONOMY_WELFARE_POOL_KEY, amount);
        g_WelfarePoolBalance += amount;
        LogEconomyEvent("welfare_pool_refund", client, amount, "welfare", 0, g_WelfarePoolBalance, g_CumulativeSpentBalance);
        if (Client_IsHumanInGame(client))
        {
            CPrintToChat(client, "%s Could not collect welfare right now.", prefix);
        }
        return;
    }

    PlayWelfareSound();
    LogEconomyEvent("welfare_pool_debit", client, amount, "welfare", 0, g_WelfarePoolBalance, g_CumulativeSpentBalance);

    char displayName[256];
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));
    CPrintToChatAllEx(client, "{default}%s collected %s%d %s{default} from {gold}!welfare{default}", displayName, colorTag, amount, currencyLong);
}

float GetSendBonusPointsCooldown()
{
    if (g_CvarSendCooldown == null)
    {
        return 0.0;
    }

    float cooldown = g_CvarSendCooldown.FloatValue;
    return cooldown > 0.0 ? cooldown : 0.0;
}

void StartSendBonusPointsCooldown(int client)
{
    float cooldown = GetSendBonusPointsCooldown();
    if (cooldown <= 0.0 || client <= 0 || client > MaxClients)
    {
        return;
    }

    g_NextSendAllowedAt[client] = GetEngineTime() + cooldown;
}

void ShowShopMenu(int client)
{
    Menu menu = new Menu(MenuHandler_Shop);
    char currencyShort[BP_CURRENCY_SHORT_MAX];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyShortLabel(currencyShort, sizeof(currencyShort));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    char title[BP_CURRENCY_LONG_MAX + 16];
    Format(title, sizeof(title), "%s Shop", currencyLong);
    menu.SetTitle(title);

    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    char itemName[BP_TRANS_ITEM_NAME_MAX];
    char display[BP_TRANS_ITEM_NAME_MAX + 32];

    for (int ownershipGroup = 0; ownershipGroup < 2; ownershipGroup++)
    {
        bool showPurchased = ownershipGroup == 1;
        for (int i = 0; i < g_ItemPrices.Length; i++)
        {
            g_ItemKeys.GetString(i, itemKey, sizeof(itemKey));
            bool purchased = GetCachedPurchasePrice(client, itemKey) > 0;
            if (purchased != showPurchased)
            {
                continue;
            }

            g_ItemNames.GetString(i, itemName, sizeof(itemName));
            int price = g_ItemPrices.Get(i);
            if (purchased)
            {
                Format(display, sizeof(display), "%s BOUGHT", itemName);
            }
            else
            {
                GetCurrencyShortLabelForAmount(price, currencyShort, sizeof(currencyShort));
                Format(display, sizeof(display), "%s %d %s", itemName, price, currencyShort);
            }
            menu.AddItem(itemKey, display);
        }
    }

    if (g_ItemPrices.Length == 0)
    {
        menu.AddItem("", "No shop items configured", ITEMDRAW_DISABLED);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Shop(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
    {
        return 0;
    }

    if (!Client_IsHumanInGame(client))
    {
        return 0;
    }

    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    menu.GetItem(item, itemKey, sizeof(itemKey));
    ShowShopItemMenu(client, itemKey);
    return 0;
}

void ShowShopItemMenu(int client, const char[] itemKey)
{
    if (!Client_IsHumanInGame(client))
    {
        return;
    }

    int itemIndex = FindStoreItem(itemKey);
    if (itemIndex == -1)
    {
        PrintToChat(client, "[Shop] That item is no longer available.");
        ShowShopMenu(client);
        return;
    }

    strcopy(g_ClientShopDetailItem[client], sizeof(g_ClientShopDetailItem[]), itemKey);

    char itemName[BP_TRANS_ITEM_NAME_MAX];
    g_ItemNames.GetString(itemIndex, itemName, sizeof(itemName));

    Menu menu = new Menu(MenuHandler_ShopItem);
    menu.SetTitle(itemName);
    menu.AddItem("description", "Description");

    if (GetCachedPurchasePrice(client, itemKey) > 0)
    {
        menu.AddItem("purchased", "Purchased", ITEMDRAW_DISABLED);
    }
    else
    {
        char currencyShort[BP_CURRENCY_SHORT_MAX];
        char purchaseDisplay[96];
        int price = g_ItemPrices.Get(itemIndex);
        GetCurrencyShortLabelForAmount(price, currencyShort, sizeof(currencyShort));
        Format(purchaseDisplay, sizeof(purchaseDisplay), "Purchase (%d %s)", price, currencyShort);
        menu.AddItem("purchase", purchaseDisplay);
    }
    menu.AddItem("back", "Back");
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ShopItem(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        if (Client_IsHumanInGame(client))
        {
            ShowShopMenu(client);
        }
        return 0;
    }

    if (action != MenuAction_Select || !Client_IsHumanInGame(client))
    {
        return 0;
    }

    char actionName[32];
    menu.GetItem(item, actionName, sizeof(actionName));

    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    strcopy(itemKey, sizeof(itemKey), g_ClientShopDetailItem[client]);
    if (!itemKey[0] || FindStoreItem(itemKey) == -1)
    {
        PrintToChat(client, "[Shop] That item is no longer available.");
        ShowShopMenu(client);
        return 0;
    }

    if (StrEqual(actionName, "description", false))
    {
        PrintStoreItemDescription(client, itemKey);
        ShowShopItemMenu(client, itemKey);
    }
    else if (StrEqual(actionName, "purchase", false))
    {
        AttemptPurchase(client, itemKey);
    }
    else if (StrEqual(actionName, "back", false))
    {
        ShowShopMenu(client);
    }

    return 0;
}

void PrintStoreItemDescription(int client, const char[] itemKey)
{
    int itemIndex = FindStoreItem(itemKey);
    if (itemIndex == -1)
    {
        return;
    }

    char itemName[BP_TRANS_ITEM_NAME_MAX];
    char description[BP_TRANS_ITEM_DESCRIPTION_MAX];
    g_ItemNames.GetString(itemIndex, itemName, sizeof(itemName));
    g_ItemDescriptions.GetString(itemIndex, description, sizeof(description));
    TrimString(description);
    if (!description[0])
    {
        strcopy(description, sizeof(description), "No description configured.");
    }

    CPrintToChat(client, "{gold}[Shop]{default} %s: %s", itemName, description);
}

void AttemptPurchase(int client, const char[] itemKey)
{
    char prefix[96];
    char currencyShort[BP_CURRENCY_SHORT_MAX];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyShortLabel(currencyShort, sizeof(currencyShort));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (!g_DatabaseReady || g_Database == null)
    {
        LogPurchaseEvent("purchase_rejected", "database_not_ready", client, itemKey, "", 0, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] The shop database is not ready.");
        return;
    }

    if (!g_ClientPurchasesLoaded[client])
    {
        LogPurchaseEvent("purchase_rejected", "purchases_not_loaded", client, itemKey, "", 0, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] Your purchases are loading. Try again in a moment.");
        return;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        LogPurchaseEvent("purchase_rejected", "balance_not_loaded", client, itemKey, "", 0, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] Your %s are loading. Try again in a moment.", currencyLong);
        return;
    }

    int itemIndex = FindStoreItem(itemKey);
    if (itemIndex == -1)
    {
        LogPurchaseEvent("purchase_rejected", "item_not_found", client, itemKey, "", 0, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] That item is no longer available.");
        return;
    }

    char itemName[BP_TRANS_ITEM_NAME_MAX];
    g_ItemNames.GetString(itemIndex, itemName, sizeof(itemName));
    int price = g_ItemPrices.Get(itemIndex);
    int durationSeconds = g_ItemDurations.Get(itemIndex);
    int useCount = g_ItemUses.Get(itemIndex);
    int expiresAt = (durationSeconds > 0) ? (GetTime() + durationSeconds) : BP_PURCHASE_PERMANENT;

    if (GetCachedPurchasePrice(client, itemKey) > 0)
    {
        LogPurchaseEvent("purchase_rejected", "already_owned", client, itemKey, itemName, price, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] You already own this item.");
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        PrintToChat(client, "[Shop] Could not read your SteamID64.");
        return;
    }

    char escapedSteamId[65];
    char escapedItemKey[(BP_TRANS_ITEM_KEY_MAX * 2) + 1];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)) || !EscapeSql(itemKey, escapedItemKey, sizeof(escapedItemKey)))
    {
        LogPurchaseEvent("purchase_rejected", "sql_escape_failed", client, itemKey, itemName, price, GetCachedBonusPoints(client));
        PrintToChat(client, "[Shop] Could not prepare your purchase.");
        return;
    }

    if (!SpendBonusPointsWithContext(client, price, "shop_purchase", 0))
    {
        LogPurchaseEvent("purchase_rejected", "insufficient_points", client, itemKey, itemName, price, GetCachedBonusPoints(client));
        CPrintToChat(client, "%s You can't afford {gold}%s;", prefix, itemName);
        CPrintToChat(client, "{default}Your balance: {lightgreen}%d%s", GetCachedBonusPoints(client), currencyShort);
        CPrintToChat(client, "{default}Earn %s through gameplay; see %s!bp", currencyLong, colorTag);
        return;
    }

    g_ClientPurchases[client].SetValue(itemKey, price);
    g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
    g_ClientPurchaseUsesRemaining[client].SetValue(itemKey, useCount);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    pack.WriteString(itemKey);
    pack.WriteString(itemName);
    pack.WriteCell(price);
    pack.WriteCell(expiresAt);
    pack.WriteCell(useCount);

    char query[896];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, item_key, price_paid, expires_at, uses_remaining) "
            ... "VALUES ('%s', '%s', %d, %d, %d) "
            ... "ON DUPLICATE KEY UPDATE price_paid = VALUES(price_paid), expires_at = VALUES(expires_at), uses_remaining = VALUES(uses_remaining), purchased_at = CURRENT_TIMESTAMP",
            BP_TRANS_TABLE,
            escapedSteamId,
            escapedItemKey,
            price,
            expiresAt,
            useCount);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, item_key, price_paid, expires_at, uses_remaining) "
            ... "VALUES ('%s', '%s', %d, %d, %d) "
            ... "ON CONFLICT(steamid64, item_key) DO UPDATE SET price_paid = excluded.price_paid, expires_at = excluded.expires_at, uses_remaining = excluded.uses_remaining, purchased_at = CURRENT_TIMESTAMP",
            BP_TRANS_TABLE,
            escapedSteamId,
            escapedItemKey,
            price,
            expiresAt,
            useCount);
    }

    g_Database.Query(SQL_OnPurchaseInserted, query, pack);
}

public void SQL_OnPurchaseInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    char expectedSteamId[32];
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    char itemName[BP_TRANS_ITEM_NAME_MAX];
    pack.ReadString(expectedSteamId, sizeof(expectedSteamId));
    pack.ReadString(itemKey, sizeof(itemKey));
    pack.ReadString(itemName, sizeof(itemName));
    int price = pack.ReadCell();
    int expiresAt = pack.ReadCell();
    int useCount = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsClientAuthorizedHuman(client))
    {
        return;
    }

    char currentSteamId[32];
    if (!GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId)) || !StrEqual(currentSteamId, expectedSteamId, false))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[bonuspoints_transactions] Failed to insert purchase for %s/%s: %s", expectedSteamId, itemKey, error);
        LogPurchaseEvent("purchase_save_failed", error, client, itemKey, itemName, price, GetCachedBonusPoints(client));
        RemoveCachedPurchase(client, itemKey);
        if (Client_IsHumanInGame(client))
        {
            PrintToChat(client, "[Shop] Your purchase could not be saved. Contact an admin.");
        }
        return;
    }

    g_ClientPurchases[client].SetValue(itemKey, price);
    g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
    g_ClientPurchaseUsesRemaining[client].SetValue(itemKey, useCount);
    LogPurchaseEvent("purchase_success", "ok", client, itemKey, itemName, price, GetCachedBonusPoints(client));
    if (Client_IsHumanInGame(client))
    {
        char colorTag[BP_CURRENCY_COLOR_MAX + 2];
        char currencyShort[BP_CURRENCY_SHORT_MAX];
        GetCurrencyColorTag(colorTag, sizeof(colorTag));
        GetCurrencyShortLabelForAmount(price, currencyShort, sizeof(currencyShort));

        char displayName[256];
        BuildPurchaseDisplayName(client, displayName, sizeof(displayName));
        CPrintToChatAllEx(client, "%s[!shop]{default} %s bought {gold}%s{default} for %d %s%s{default}", colorTag, displayName, itemName, price, colorTag, currencyShort);
        PlayPurchaseSound();
    }
}

static void PlayPurchaseSound()
{
    SaySounds_TryPlayCommand(0, "xp_gain");
}

void BuildPurchaseDisplayName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen)
        && buffer[0] != '\0')
    {
        ChatColors_ResolveTeamTag(client, buffer, maxlen);
        return;
    }

    char colorTag[16];
    ChatColors_GetTeamTag(client, colorTag, sizeof(colorTag));
    Format(buffer, maxlen, "%s%N{default}", colorTag, client);
}

public any Native_PointsStore_AreBonusPointsLoaded(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return AreBonusPointsReady(client);
}

public any Native_PointsStore_GetBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return GetCachedBonusPoints(client);
}

public any Native_PointsStore_ApplyBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char rewardId[BP_REWARD_ID_MAX];
    GetNativeString(2, rewardId, sizeof(rewardId));
    TrimString(rewardId);

    RewardDefinition reward;
    if (!GetRewardDefinition(rewardId, reward))
    {
        return false;
    }

    bool playSound = (numParams >= 3) ? view_as<bool>(GetNativeCell(3)) : true;
    bool chatAlert = (numParams >= 4) ? view_as<bool>(GetNativeCell(4)) : true;
    float randomChance = (numParams >= 5) ? view_as<float>(GetNativeCell(5)) : 1.0;
    int target = (numParams >= 6) ? GetNativeCell(6) : 0;
    float delay = (numParams >= 7) ? view_as<float>(GetNativeCell(7)) : 3.0;
    return ApplyBonusPoints(
        client,
        reward.amount,
        playSound,
        chatAlert,
        randomChance,
        reward.id,
        target,
        delay,
        reward.perMapLimit,
        true);
}

public any Native_PointsStore_ApplyBonusPointsSteamId(Handle plugin, int numParams)
{
    char steamId[32];
    GetNativeString(1, steamId, sizeof(steamId));
    TrimString(steamId);

    char rewardId[BP_REWARD_ID_MAX];
    GetNativeString(2, rewardId, sizeof(rewardId));
    TrimString(rewardId);

    RewardDefinition reward;
    if (!GetRewardDefinition(rewardId, reward))
    {
        return false;
    }

    bool playSound = (numParams >= 3) ? view_as<bool>(GetNativeCell(3)) : true;
    bool chatAlert = (numParams >= 4) ? view_as<bool>(GetNativeCell(4)) : true;
    return ApplyBonusPointsSteamId(
        steamId,
        reward.amount,
        playSound,
        chatAlert,
        reward.id,
        reward.perMapLimit,
        true);
}

public any Native_PointsStore_RefundBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int points = GetNativeCell(2);
    char type[64];
    strcopy(type, sizeof(type), "api_refund");
    if (numParams >= 3)
    {
        GetNativeString(3, type, sizeof(type));
        TrimString(type);
    }
    return points > 0 && ApplyBonusPoints(client, points, false, false, 1.0, type, 0, 0.0);
}

bool GetNativeRewardDefinition(int parameter, RewardDefinition definition)
{
    char rewardId[BP_REWARD_ID_MAX];
    GetNativeString(parameter, rewardId, sizeof(rewardId));
    TrimString(rewardId);
    return GetRewardDefinition(rewardId, definition);
}

public any Native_PointsStore_GetRewardAmount(Handle plugin, int numParams)
{
    RewardDefinition reward;
    return GetNativeRewardDefinition(1, reward) ? reward.amount : 0;
}

public any Native_PointsStore_GetRewardPerMapLimit(Handle plugin, int numParams)
{
    RewardDefinition reward;
    return GetNativeRewardDefinition(1, reward) ? reward.perMapLimit : -1;
}

public any Native_PointsStore_GetRewardLongName(Handle plugin, int numParams)
{
    RewardDefinition reward;
    return GetNativeRewardDefinition(1, reward)
        && SetNativeString(2, reward.longName, GetNativeCell(3), true) == SP_ERROR_NONE;
}

public any Native_PointsStore_GetRewardShortDescription(Handle plugin, int numParams)
{
    RewardDefinition reward;
    return GetNativeRewardDefinition(1, reward)
        && SetNativeString(2, reward.shortDescription, GetNativeCell(3), true) == SP_ERROR_NONE;
}

public any Native_PointsStore_GetRewardLongDescription(Handle plugin, int numParams)
{
    RewardDefinition reward;
    return GetNativeRewardDefinition(1, reward)
        && SetNativeString(2, reward.longDescription, GetNativeCell(3), true) == SP_ERROR_NONE;
}

public any Native_PointsStore_RefundBonusPointsSteamId(Handle plugin, int numParams)
{
    char steamId[32];
    GetNativeString(1, steamId, sizeof(steamId));
    TrimString(steamId);
    int points = GetNativeCell(2);
    char type[64];
    strcopy(type, sizeof(type), "api_refund");
    if (numParams >= 3)
    {
        GetNativeString(3, type, sizeof(type));
        TrimString(type);
    }
    return points > 0 && ApplyBonusPointsSteamId(steamId, points, false, false, type);
}

public any Native_PointsStore_ApplyBonusPointsSteamIdOnce(Handle plugin, int numParams)
{
    char steamId[32];
    char awardKey[BP_IDEMPOTENT_KEY_MAX];
    char type[64];
    GetNativeString(1, steamId, sizeof(steamId));
    int amount = GetNativeCell(2);
    GetNativeString(3, awardKey, sizeof(awardKey));
    strcopy(type, sizeof(type), "api_idempotent_award");
    if (numParams >= 4)
    {
        GetNativeString(4, type, sizeof(type));
    }
    TrimString(steamId);
    TrimString(awardKey);
    TrimString(type);

    return QueueIdempotentBonusPointsAward(steamId, amount, awardKey, type);
}

public any Native_PointsStore_SpendBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int points = GetNativeCell(2);
    char type[64];
    BuildCallerSpendType(plugin, type, sizeof(type));
    return SpendBonusPointsWithContext(client, points, type);
}

public any Native_PointsStore_StealBonusPoints(Handle plugin, int numParams)
{
    int victim = GetNativeCell(1);
    int recipient = GetNativeCell(2);
    int points = GetNativeCell(3);

    char type[64];
    type[0] = '\0';
    if (numParams >= 4)
    {
        GetNativeString(4, type, sizeof(type));
        TrimString(type);
    }
    if (type[0] == '\0')
    {
        strcopy(type, sizeof(type), "api_steal");
    }

    return StealBonusPointsWithContext(victim, recipient, points, type);
}

public any Native_PointsStore_AwardMemomanEvent(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char sourceId[64];
    char detailId[64];
    char detailName[128];
    GetNativeString(2, sourceId, sizeof(sourceId));
    if (numParams >= 3)
    {
        GetNativeString(3, detailId, sizeof(detailId));
    }
    if (numParams >= 4)
    {
        GetNativeString(4, detailName, sizeof(detailName));
    }
    TrimString(sourceId);
    TrimString(detailId);
    TrimString(detailName);
    return MemomanEvent_QueueReward(client, sourceId, detailId, detailName);
}

public any Native_PointsStore_HasPurchase(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    GetNativeString(2, itemKey, sizeof(itemKey));
    return GetCachedPurchasePrice(client, itemKey) > 0;
}

public any Native_PointsStore_GetPurchasePrice(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    GetNativeString(2, itemKey, sizeof(itemKey));
    return GetCachedPurchasePrice(client, itemKey);
}

public any Native_PointsStore_GetPurchaseExpiresAt(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    GetNativeString(2, itemKey, sizeof(itemKey));
    return GetCachedPurchaseExpiresAt(client, itemKey);
}

public any Native_PointsStore_GetPurchaseUsesRemaining(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    GetNativeString(2, itemKey, sizeof(itemKey));
    return GetCachedPurchaseUsesRemaining(client, itemKey);
}

public any Native_PointsStore_ConsumePurchaseUse(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    char itemKey[BP_TRANS_ITEM_KEY_MAX];
    GetNativeString(2, itemKey, sizeof(itemKey));
    return ConsumeCachedPurchaseUse(client, itemKey);
}
