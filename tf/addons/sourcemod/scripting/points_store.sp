#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <tf2_stocks>

#include <multicolors>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <filters_api>
#include <saysounds>
#define REQUIRE_PLUGIN

#include "include/kogasa_sql.inc"
#include "include/kogasa_steam_identity.inc"
#include "include/plugin_statistics.inc"

#define BP_TRANS_DB_CONFIG_DEFAULT "default"
#define BP_TRANS_TABLE "bonuspoints_transactions"
#define BP_BALANCE_TABLE "points_store_balances"
#define BP_ECONOMY_TABLE "points_store_economy"
#define BP_ECONOMY_WELFARE_POOL_KEY "welfare_pool"
#define BP_ECONOMY_CUMULATIVE_SPENT_KEY "cumulative_spent"
#define BP_ECONOMY_KEY_MAX 64
#define BP_TRANS_ITEM_KEY_MAX 64
#define BP_TRANS_ITEM_NAME_MAX 128
#define BP_TRANS_ITEM_DESCRIPTION_MAX 256
#define BP_SOUND_COMMAND "xp_gain"
#define BP_EVENT_LOG_LINE_MAX 1024
#define BP_CURRENCY_SHORT_MAX 32
#define BP_CURRENCY_LONG_MAX 64
#define BP_CURRENCY_COLOR_MAX 32
#define BP_WELFARE_SOUND_COMMAND "monkey"
#define BP_WELFARE_MIN 4
#define BP_WELFARE_MAX 16
#define BP_PURCHASE_PERMANENT 0
#define BP_PURCHASE_UNLIMITED_USES -1
#define LOTTO_TABLE "points_store_lotteries"
#define LOTTO_TICKET_TABLE "points_store_lottery_tickets"
#define LOTTO_WORD_MAX 64
#define LOTTO_TOKEN_MAX 128
#define LOTTO_TICKET_MAX 2048
#define LOTTO_TICKET_PRINT_MAX 2304
#define LOTTO_HASH_MAX 32
#define LOTTO_SHORT_HASH_LEN 7
#define LOTTO_SHORT_HASH_MAX 8
#define LOTTO_NAME_MAX 256
#define LOTTO_REVEAL_INTERVAL 0.5
#define LOTTO_TICKET_UNIT 5
#define LOTTO_EXTRA_WINNER_PARTICIPANTS 4
#define LOTTO_EXTRA_WINNER_PERCENT 5
#define LOTTO_WELFARE_POOL_PERCENT 5
#define REFLECT_BONUS_PER_MAP_LIMIT 3
#define BP_LEADERBOARD_PAGE_SIZE 10

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
ConVar g_CvarLotteryDisabled = null;
bool g_DatabaseReady = false;
bool g_IsMySql = false;
Handle g_hDatabaseReconnectTimer = null;
bool g_EconomyStateLoaded = false;
int g_WelfarePoolBalance = 0;
int g_CumulativeSpentBalance = 0;
char g_CurrencyShortLabel[BP_CURRENCY_SHORT_MAX];
char g_CurrencyLongLabel[BP_CURRENCY_LONG_MAX];
char g_CurrencyColorTag[BP_CURRENCY_COLOR_MAX + 2];
char g_CurrencyPrefix[96];
float g_NextSendAllowedAt[MAXPLAYERS + 1];
StringMap g_PerMapAwardCounts = null;
StringMap g_LotteryPendingSteamIds = null;
int g_LotteryPendingTicketWrites = 0;

ArrayList g_LotteryWords = null;
ArrayList g_LotteryRarities = null;
ArrayList g_LotteryDrawTokens = null;
int g_LotteryTotalWeight = 0;

bool g_LotteryReady = false;
bool g_LotteryCreating = false;
bool g_LotteryDrawInProgress = false;
int g_CurrentLotteryId = 0;
char g_CurrentLotteryHash[LOTTO_HASH_MAX];
char g_CurrentLotteryHashColor[BP_CURRENCY_COLOR_MAX + 2];

bool g_LotteryWaitingCustom[MAXPLAYERS + 1];
bool g_ClientLotteryTicketLoaded[MAXPLAYERS + 1];
bool g_ClientLotteryHasTicket[MAXPLAYERS + 1];
int g_ClientLotteryId[MAXPLAYERS + 1];
int g_ClientLotteryTicketValue[MAXPLAYERS + 1];
char g_ClientLotteryTicket[MAXPLAYERS + 1][LOTTO_TICKET_MAX];

Handle g_LotteryDrawTimer = null;
Handle g_LotteryCallTimer = null;
int g_LotteryCallRequesterUserId = 0;
int g_LotteryCallLotteryId = 0;
int g_LotteryDrawIndex = 0;
int g_LotteryDrawLotteryId = 0;
int g_LotteryDrawPrizePool = 0;
int g_LotteryDrawWinnerPrize = 0;
int g_LotteryDrawWelfarePoolPrize = 0;
char g_LotteryDrawWinnerSteamId[32];
char g_LotteryDrawWinnerName[LOTTO_NAME_MAX];
int g_LotteryDrawExtraWinnerCount = 0;
int g_LotteryDrawExtraWinnerPrizes[MAXPLAYERS + 1];
char g_LotteryDrawExtraWinnerSteamIds[MAXPLAYERS + 1][32];
char g_LotteryDrawExtraWinnerNames[MAXPLAYERS + 1][LOTTO_NAME_MAX];
char g_LotteryDrawHash[LOTTO_HASH_MAX];
char g_LotteryDrawHashColor[BP_CURRENCY_COLOR_MAX + 2];

static const char g_LotteryColors[][] =
{
    "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black",
    "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
    "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue", "darkcyan",
    "darkgoldenrod", "darkgray", "darkgrey", "darkgreen", "darkkhaki", "darkmagenta", "darkolivegreen",
    "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen", "darkslateblue",
    "darkslategray", "darkslategrey", "darkturquoise", "darkviolet", "deeppink", "deepskyblue",
    "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen", "fuchsia",
    "gainsboro", "ghostwhite", "gold", "goldenrod", "gray", "grey", "green", "greenyellow",
    "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki", "lavender", "lavenderblush",
    "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan", "lightgoldenrodyellow",
    "lightgray", "lightgrey", "lightgreen", "lightpink", "lightsalmon", "lightseagreen", "lightskyblue",
    "lightslategray", "lightslategrey", "lightsteelblue", "lightyellow", "lime", "limegreen", "linen",
    "magenta", "maroon", "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple",
    "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred",
    "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite", "navy", "oldlace", "olive",
    "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise",
    "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple",
    "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown", "seagreen", "seashell",
    "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey", "snow", "springgreen",
    "steelblue", "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white",
    "whitesmoke", "yellow", "yellowgreen"
};

public Plugin myinfo =
{
    name = "points_store",
    author = "Kogasa",
    description = "Currency purchase receipts, shop UI, and ownership API.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    RegPluginLibrary("points_store");
    CreateNative("PointsStore_AreBonusPointsLoaded", Native_PointsStore_AreBonusPointsLoaded);
    CreateNative("PointsStore_GetBonusPoints", Native_PointsStore_GetBonusPoints);
    CreateNative("PointsStore_ApplyBonusPoints", Native_PointsStore_ApplyBonusPoints);
    CreateNative("PointsStore_ApplyBonusPointsSteamId", Native_PointsStore_ApplyBonusPointsSteamId);
    CreateNative("PointsStore_SpendBonusPoints", Native_PointsStore_SpendBonusPoints);
    CreateNative("PointsStore_HasPurchase", Native_PointsStore_HasPurchase);
    CreateNative("PointsStore_GetPurchasePrice", Native_PointsStore_GetPurchasePrice);
    CreateNative("PointsStore_GetPurchaseExpiresAt", Native_PointsStore_GetPurchaseExpiresAt);
    CreateNative("PointsStore_GetPurchaseUsesRemaining", Native_PointsStore_GetPurchaseUsesRemaining);
    CreateNative("PointsStore_ConsumePurchaseUse", Native_PointsStore_ConsumePurchaseUse);
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
    g_LotteryPendingSteamIds = new StringMap();
    g_LotteryWords = new ArrayList(ByteCountToCells(LOTTO_WORD_MAX));
    g_LotteryRarities = new ArrayList();
    g_LotteryDrawTokens = new ArrayList(ByteCountToCells(LOTTO_TOKEN_MAX));

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
        ClearClientLotteryTicketCache(i);
    }

    g_CvarDatabase = CreateConVar("sm_bonuspoints_transactions_database", BP_TRANS_DB_CONFIG_DEFAULT, "Databases.cfg entry for bonuspoints_transactions.");
    char dbConfig[64];
    g_CvarDatabase.GetString(dbConfig, sizeof(dbConfig));
    PluginStats_Init("points_store_statistics_events", dbConfig);
    g_CvarEventLogging = CreateConVar("sm_points_store_event_logging", "0", "Write structured currency economy events to points_store_statistics_events.", _, true, 0.0, true, 1.0);
    g_CvarLogRandomMisses = CreateConVar("sm_points_store_log_random_misses", "0", "Log failed random-chance currency rolls when event logging is enabled.", _, true, 0.0, true, 1.0);
    g_CvarCurrencyShort = CreateConVar("sm_points_store_currency_short", "BP", "Short currency label used in compact messages, e.g. BP or Gem.");
    g_CvarCurrencyLong = CreateConVar("sm_points_store_currency_long", "Bonus Points", "Long currency label used in menus and prose, e.g. Bonus Points or Gems.");
    g_CvarCurrencyColor = CreateConVar("sm_points_store_currency_color", "magenta", "Multicolors tag name used for the currency prefix, without braces.");
    g_CvarSendCooldown = CreateConVar("sm_points_store_send_cooldown", "15.0", "Seconds a client must wait between successful !send currency transfers.", _, true, 0.0);
    g_CvarEnableWelfare = CreateConVar("sm_points_store_welfare", "1", "Enable welfare?", _, true, 0.0, true, 1.0);
    g_CvarWelfareMinPlayers = CreateConVar("sm_points_store_welfare_min_players", "3", "Minimum GetClientCount(false) value required to collect welfare. 0 disables the requirement.", _, true, 0.0, true, 64.0);
    g_CvarLotteryDisabled = CreateConVar("sm_points_store_lottery_disabled", "0", "Disable lottery ticket commands and lottery draws on this server.", _, true, 0.0, true, 1.0);
    g_CvarCurrencyShort.AddChangeHook(OnCurrencyConVarChanged);
    g_CvarCurrencyLong.AddChangeHook(OnCurrencyConVarChanged);
    g_CvarCurrencyColor.AddChangeHook(OnCurrencyConVarChanged);
    g_CvarLotteryDisabled.AddChangeHook(OnLotteryDisabledConVarChanged);
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
    RegConsoleCmd("sm_gemranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_gemsranks", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_gemsleaderboard", Command_ShowCurrencyLeaderboard, "Show the currency leaderboard.");
    RegConsoleCmd("sm_sendgem", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_gemsend", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_welfare", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_collectwelfare", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_handout", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_gibs", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_welfarecheck", Command_Welfare, "Collect once-per-map welfare currency.");
    RegConsoleCmd("sm_lottery", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_gamble", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_bet", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_lotto", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_pool", Command_LotteryPrizePool, "Show the lottery prize pool.");
    RegConsoleCmd("sm_prizepool", Command_LotteryPrizePool, "Show the lottery prize pool.");
    RegConsoleCmd("sm_ticket", Command_ViewLotteryTicket, "View your current lottery ticket.");
    RegConsoleCmd("sm_viewticket", Command_ViewLotteryTicket, "View your current lottery ticket.");
    RegConsoleCmd("sm_lottorefund", Command_LotteryRefund, "Refund your current lottery ticket.");
    RegConsoleCmd("sm_lotteryrefund", Command_LotteryRefund, "Refund your current lottery ticket.");
    RegConsoleCmd("sm_refund", Command_LotteryRefund, "Refund your current lottery ticket.");
    RegAdminCmd("sm_dolottery", Command_DoLottery, ADMFLAG_GENERIC, "Draw the current currency lottery.");
    RegAdminCmd("sm_dolotto", Command_DoLottery, ADMFLAG_GENERIC, "Draw the current currency lottery.");

    LoadStoreItems();
    LoadLotteryWords();
    ConnectDatabase();
}

public void OnPluginEnd()
{
    PluginStats_Flush();

    delete g_ItemKeys;
    delete g_ItemNames;
    delete g_ItemPrices;
    delete g_ItemDurations;
    delete g_ItemUses;
    delete g_PerMapAwardCounts;
    delete g_LotteryPendingSteamIds;
    delete g_LotteryWords;
    delete g_LotteryRarities;
    delete g_LotteryDrawTokens;

    if (g_LotteryDrawTimer != null)
    {
        KillTimer(g_LotteryDrawTimer);
        g_LotteryDrawTimer = null;
    }

    if (g_LotteryCallTimer != null)
    {
        KillTimer(g_LotteryCallTimer);
        g_LotteryCallTimer = null;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        delete g_ClientPurchases[i];
        g_ClientPurchases[i] = null;
        delete g_ClientPurchaseExpiresAt[i];
        g_ClientPurchaseExpiresAt[i] = null;
        delete g_ClientPurchaseUsesRemaining[i];
        g_ClientPurchaseUsesRemaining[i] = null;
    }

    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_Database, g_DatabaseReady);
    PluginStats_Shutdown();
}

public void OnMapStart()
{
    PluginStats_OnMapStart();
    if (g_PerMapAwardCounts != null)
    {
        g_PerMapAwardCounts.Clear();
    }
}

public void OnMapEnd()
{
    PluginStats_Flush();
    CancelPendingLotteryCall();
    CancelActiveLotteryDrawForMapChange();
}

public void OnClientAuthorized(int client, const char[] auth)
{
    g_NextSendAllowedAt[client] = 0.0;
    ClearClientStoreCache(client);
    LoadClientPurchases(client);
    LoadClientBonusPoints(client);
    LoadClientLotteryTicket(client);
}

public void OnClientDisconnect(int client)
{
    g_NextSendAllowedAt[client] = 0.0;
    g_LotteryWaitingCustom[client] = false;
    ClearClientStoreCache(client);
    ClearClientLotteryTicketCache(client);
}

void ConnectDatabase()
{
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);
    KogasaSql_Close(g_Database, g_DatabaseReady);
    g_LotteryReady = false;
    g_LotteryCreating = false;
    g_CurrentLotteryId = 0;
    g_CurrentLotteryHash[0] = '\0';
    g_CurrentLotteryHashColor[0] = '\0';
    CancelPendingLotteryCall();

    char dbConfig[64];
    g_CvarDatabase.GetString(dbConfig, sizeof(dbConfig));
    TrimString(dbConfig);
    if (dbConfig[0] == '\0')
    {
        strcopy(dbConfig, sizeof(dbConfig), BP_TRANS_DB_CONFIG_DEFAULT);
    }

    if (!KogasaSql_CheckConfigOrLog("points_store", dbConfig))
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
    KogasaSql_CancelTimer(g_hDatabaseReconnectTimer);

    EnsureSchema();
}

void ScheduleDatabaseReconnect(float delay = KOGASA_SQL_RECONNECT_DELAY)
{
    g_DatabaseReady = false;
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
    if (error[0] != '\0' && !IsDuplicateColumnError(error))
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
    if (error[0] != '\0' && !IsDuplicateColumnError(error))
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

bool IsDuplicateColumnError(const char[] error)
{
    return KogasaSql_IsDuplicateColumnError(error);
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

void EnsureLotterySchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[2048];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INT NOT NULL AUTO_INCREMENT, "
            ... "hash VARCHAR(32) NOT NULL, "
            ... "hash_color VARCHAR(32) NOT NULL, "
            ... "created_at INT NOT NULL, "
            ... "finished TINYINT NOT NULL DEFAULT 0, "
            ... "finished_at INT NOT NULL DEFAULT 0, "
            ... "winner_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "winner_name VARCHAR(255) NOT NULL DEFAULT '', "
            ... "prize_pool INT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (id), "
            ... "UNIQUE KEY unique_points_store_lottery_hash (hash), "
            ... "KEY idx_points_store_lottery_finished (finished))",
            LOTTO_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "hash VARCHAR(32) NOT NULL UNIQUE, "
            ... "hash_color VARCHAR(32) NOT NULL, "
            ... "created_at INTEGER NOT NULL, "
            ... "finished INTEGER NOT NULL DEFAULT 0, "
            ... "finished_at INTEGER NOT NULL DEFAULT 0, "
            ... "winner_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "winner_name VARCHAR(255) NOT NULL DEFAULT '', "
            ... "prize_pool INTEGER NOT NULL DEFAULT 0)",
            LOTTO_TABLE);
    }

    g_Database.Query(SQL_OnLotterySchemaReady, query);
}

public void SQL_OnLotterySchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Lottery schema creation failed: %s", error);
        return;
    }

    char query[4096];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INT NOT NULL AUTO_INCREMENT, "
            ... "lottery_id INT NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "display_name VARCHAR(255) NOT NULL DEFAULT '', "
            ... "ticket TEXT NOT NULL, "
            ... "ticket_value INT NOT NULL, "
            ... "created_at INT NOT NULL, "
            ... "PRIMARY KEY (id), "
            ... "UNIQUE KEY unique_points_store_lottery_ticket (lottery_id, steamid64), "
            ... "KEY idx_points_store_lottery_ticket_lottery (lottery_id), "
            ... "KEY idx_points_store_lottery_ticket_steamid64 (steamid64))",
            LOTTO_TICKET_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "lottery_id INTEGER NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "display_name VARCHAR(255) NOT NULL DEFAULT '', "
            ... "ticket TEXT NOT NULL, "
            ... "ticket_value INTEGER NOT NULL, "
            ... "created_at INTEGER NOT NULL, "
            ... "UNIQUE (lottery_id, steamid64))",
            LOTTO_TICKET_TABLE);
    }

    g_Database.Query(SQL_OnLotteryTicketsSchemaReady, query);
}

public void SQL_OnLotteryTicketsSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Lottery ticket schema creation failed: %s", error);
        return;
    }

    if (!g_IsMySql)
    {
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_points_store_lottery_finished ON points_store_lotteries (finished)");
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_points_store_lottery_ticket_lottery ON points_store_lottery_tickets (lottery_id)");
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_points_store_lottery_ticket_steamid64 ON points_store_lottery_tickets (steamid64)");
    }

    EnsureEconomySchema();
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

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientPurchases(i);
            LoadClientBonusPoints(i);
            LoadClientLotteryTicket(i);
        }
    }

    EnsureActiveLottery();
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

bool IsLotteryEnabled()
{
    return g_CvarLotteryDisabled == null || !g_CvarLotteryDisabled.BoolValue;
}

void ClearLocalLotteryState()
{
    CancelPendingLotteryCall();

    if (g_LotteryDrawTimer != null)
    {
        KillTimer(g_LotteryDrawTimer);
        g_LotteryDrawTimer = null;
    }

    g_LotteryReady = false;
    g_LotteryCreating = false;
    g_LotteryDrawInProgress = false;
    g_CurrentLotteryId = 0;
    g_CurrentLotteryHash[0] = '\0';
    g_CurrentLotteryHashColor[0] = '\0';
    ClearAllClientLotteryCaches();
    ResetLotteryDrawState();
}

void EnsureActiveLottery()
{
    if (!IsLotteryEnabled())
    {
        ClearLocalLotteryState();
        return;
    }

    if (!g_DatabaseReady || g_Database == null || g_LotteryCreating)
    {
        return;
    }

    if (g_LotteryReady && g_CurrentLotteryId > 0)
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query),
        "SELECT id, hash, hash_color, created_at FROM %s WHERE finished = 0 ORDER BY id DESC LIMIT 1",
        LOTTO_TABLE);
    g_Database.Query(SQL_OnActiveLotterySelected, query);
}

public void SQL_OnActiveLotterySelected(Database db, DBResultSet results, const char[] error, any data)
{
    if (!IsLotteryEnabled())
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to load active lottery: %s", error);
        return;
    }

    if (results != null && results.FetchRow())
    {
        int lotteryId = results.FetchInt(0);
        char hash[LOTTO_HASH_MAX];
        char hashColor[BP_CURRENCY_COLOR_MAX + 2];
        results.FetchString(1, hash, sizeof(hash));
        results.FetchString(2, hashColor, sizeof(hashColor));
        SetActiveLottery(lotteryId, hash, hashColor);
        return;
    }

    CreateActiveLottery();
}

void CreateActiveLottery()
{
    if (!IsLotteryEnabled() || !g_DatabaseReady || g_Database == null || g_LotteryCreating)
    {
        return;
    }

    g_LotteryCreating = true;

    int createdAt = GetTime();
    char hash[LOTTO_HASH_MAX];
    char colorName[BP_CURRENCY_COLOR_MAX];
    char hashColor[BP_CURRENCY_COLOR_MAX + 2];
    BuildLotteryHash(createdAt, hash, sizeof(hash));
    GetRandomLotteryColorName(colorName, sizeof(colorName));
    Format(hashColor, sizeof(hashColor), "{%s}", colorName);

    char escapedHash[(LOTTO_HASH_MAX * 2) + 1];
    char escapedHashColor[((BP_CURRENCY_COLOR_MAX + 2) * 2) + 1];
    if (!EscapeSql(hash, escapedHash, sizeof(escapedHash)) || !EscapeSql(hashColor, escapedHashColor, sizeof(escapedHashColor)))
    {
        g_LotteryCreating = false;
        LogError("[points_store] Failed to escape new lottery hash.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteString(hash);
    pack.WriteString(hashColor);

    char query[512];
    Format(query, sizeof(query),
        "INSERT INTO %s (hash, hash_color, created_at, finished) VALUES ('%s', '%s', %d, 0)",
        LOTTO_TABLE,
        escapedHash,
        escapedHashColor,
        createdAt);
    g_Database.Query(SQL_OnActiveLotteryInserted, query, pack);
}

public void SQL_OnActiveLotteryInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char hash[LOTTO_HASH_MAX];
    char hashColor[BP_CURRENCY_COLOR_MAX + 2];
    pack.ReadString(hash, sizeof(hash));
    pack.ReadString(hashColor, sizeof(hashColor));
    delete pack;

    g_LotteryCreating = false;

    if (!IsLotteryEnabled())
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to create active lottery: %s", error);
        return;
    }

    char escapedHash[(LOTTO_HASH_MAX * 2) + 1];
    if (!EscapeSql(hash, escapedHash, sizeof(escapedHash)))
    {
        LogError("[points_store] Failed to escape created lottery hash.");
        return;
    }

    DataPack selectPack = new DataPack();
    selectPack.WriteString(hash);
    selectPack.WriteString(hashColor);

    char query[256];
    Format(query, sizeof(query),
        "SELECT id FROM %s WHERE hash = '%s' LIMIT 1",
        LOTTO_TABLE,
        escapedHash);
    g_Database.Query(SQL_OnActiveLotteryInsertedSelected, query, selectPack);
}

public void SQL_OnActiveLotteryInsertedSelected(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char hash[LOTTO_HASH_MAX];
    char hashColor[BP_CURRENCY_COLOR_MAX + 2];
    pack.ReadString(hash, sizeof(hash));
    pack.ReadString(hashColor, sizeof(hashColor));
    delete pack;

    if (!IsLotteryEnabled())
    {
        return;
    }

    if (error[0] != '\0' || results == null || !results.FetchRow())
    {
        LogError("[points_store] Failed to select newly created lottery: %s", error[0] ? error : "no row returned");
        return;
    }

    SetActiveLottery(results.FetchInt(0), hash, hashColor);
}

void SetActiveLottery(int lotteryId, const char[] hash, const char[] hashColor)
{
    g_CurrentLotteryId = lotteryId;
    strcopy(g_CurrentLotteryHash, sizeof(g_CurrentLotteryHash), hash);
    strcopy(g_CurrentLotteryHashColor, sizeof(g_CurrentLotteryHashColor), hashColor);
    g_LotteryReady = true;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientLotteryTicket(i);
        }
    }
}

void ClearClientLotteryTicketCache(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_ClientLotteryTicketLoaded[client] = false;
    g_ClientLotteryHasTicket[client] = false;
    g_ClientLotteryId[client] = 0;
    g_ClientLotteryTicketValue[client] = 0;
    g_ClientLotteryTicket[client][0] = '\0';
}

void ClearAllClientLotteryCaches()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ClearClientLotteryTicketCache(i);
    }
}

bool IsLotteryTicketWritePending(const char[] steamId)
{
    int pending = 0;
    return g_LotteryPendingSteamIds != null && g_LotteryPendingSteamIds.GetValue(steamId, pending);
}

void BeginLotteryTicketWrite(const char[] steamId)
{
    if (g_LotteryPendingSteamIds != null && !IsLotteryTicketWritePending(steamId))
    {
        g_LotteryPendingSteamIds.SetValue(steamId, 1, true);
        g_LotteryPendingTicketWrites++;
    }
}

void FinishLotteryTicketWrite(const char[] steamId)
{
    if (g_LotteryPendingSteamIds != null && IsLotteryTicketWritePending(steamId))
    {
        g_LotteryPendingSteamIds.Remove(steamId);
        if (g_LotteryPendingTicketWrites > 0)
        {
            g_LotteryPendingTicketWrites--;
        }
    }
}

void LoadClientLotteryTicket(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    ClearClientLotteryTicketCache(client);
    if (!IsLotteryEnabled() || !g_DatabaseReady || g_Database == null || !g_LotteryReady || g_CurrentLotteryId <= 0 || !IsClientAuthorizedHuman(client))
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
        LogError("[points_store] Failed to escape SteamID64 for lottery ticket load for client %d.", client);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_CurrentLotteryId);
    pack.WriteString(steamId);

    char query[384];
    Format(query, sizeof(query),
        "SELECT ticket, ticket_value FROM %s WHERE lottery_id = %d AND steamid64 = '%s' LIMIT 1",
        LOTTO_TICKET_TABLE,
        g_CurrentLotteryId,
        escapedSteamId);
    g_Database.Query(SQL_OnClientLotteryTicketLoaded, query, pack);
}

public void SQL_OnClientLotteryTicketLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int expectedLotteryId = pack.ReadCell();
    char expectedSteamId[32];
    pack.ReadString(expectedSteamId, sizeof(expectedSteamId));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsLotteryEnabled() || !IsClientAuthorizedHuman(client) || expectedLotteryId != g_CurrentLotteryId)
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
        LogError("[points_store] Failed to load lottery ticket for %s: %s", expectedSteamId, error);
        g_ClientLotteryTicketLoaded[client] = false;
        return;
    }

    g_ClientLotteryTicketLoaded[client] = true;
    g_ClientLotteryHasTicket[client] = false;
    g_ClientLotteryId[client] = expectedLotteryId;
    g_ClientLotteryTicketValue[client] = 0;
    g_ClientLotteryTicket[client][0] = '\0';

    if (results != null && results.FetchRow())
    {
        results.FetchString(0, g_ClientLotteryTicket[client], sizeof(g_ClientLotteryTicket[]));
        g_ClientLotteryTicketValue[client] = results.FetchInt(1);
        g_ClientLotteryHasTicket[client] = g_ClientLotteryTicket[client][0] != '\0' && g_ClientLotteryTicketValue[client] > 0;
    }
}

bool IsLotteryReadyForClient(int client, bool needTicketLoaded = true)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (!IsLotteryEnabled())
    {
        CPrintToChat(client, "%s[Lotto]{default} The lottery is disabled on this server.", colorTag);
        return false;
    }

    if (!g_DatabaseReady || g_Database == null || !g_LotteryReady || g_CurrentLotteryId <= 0)
    {
        CPrintToChat(client, "%s[Lotto]{default} The lottery database is not ready.", colorTag);
        EnsureActiveLottery();
        return false;
    }

    if (needTicketLoaded && !g_ClientLotteryTicketLoaded[client])
    {
        LoadClientLotteryTicket(client);
        CPrintToChat(client, "%s[Lotto]{default} Your lottery ticket is loading. Try again in a moment.", colorTag);
        return false;
    }

    return true;
}

public Action Command_Lottery(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    if (!IsLotteryReadyForClient(client))
    {
        return Plugin_Handled;
    }

    if (args >= 1)
    {
        char amountArg[32];
        GetCmdArg(1, amountArg, sizeof(amountArg));
        StripQuotes(amountArg);
        TrimString(amountArg);

        if (StrEqual(amountArg, "all", false))
        {
            AttemptLotteryAllTicketPurchase(client);
            return Plugin_Handled;
        }

        int amount = 0;
        if (ParsePositiveInteger(amountArg, amount))
        {
            AttemptLotteryTicketPurchase(client, amount);
            return Plugin_Handled;
        }
    }

    ShowLotteryMenu(client);
    return Plugin_Handled;
}

public Action Command_LotteryRefund(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    if (!IsLotteryReadyForClient(client))
    {
        return Plugin_Handled;
    }

    RefundLotteryTicket(client);
    return Plugin_Handled;
}

public Action Command_LotteryPrizePool(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    if (!IsLotteryReadyForClient(client, false))
    {
        return Plugin_Handled;
    }

    PrintLotteryPrizePool(client);
    return Plugin_Handled;
}

public Action Command_ViewLotteryTicket(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    if (!IsLotteryReadyForClient(client))
    {
        return Plugin_Handled;
    }

    PrintClientLotteryTicket(client);
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client <= 0 || client > MaxClients || !g_LotteryWaitingCustom[client])
    {
        return Plugin_Continue;
    }

    g_LotteryWaitingCustom[client] = false;

    char text[32];
    strcopy(text, sizeof(text), sArgs);
    StripQuotes(text);
    TrimString(text);

    int amount = 0;
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    if (!IsLotteryReadyForClient(client))
    {
        return Plugin_Handled;
    }

    if (StrEqual(text, "all", false))
    {
        AttemptLotteryAllTicketPurchase(client);
        return Plugin_Handled;
    }

    if (!ParsePositiveInteger(text, amount))
    {
        CPrintToChat(client, "%s[Lottery]{default} Ticket value must be a positive integer or {gold}all{default}.", colorTag);
        return Plugin_Handled;
    }

    AttemptLotteryTicketPurchase(client, amount);
    return Plugin_Handled;
}

bool ParsePositiveInteger(const char[] text, int &value)
{
    value = 0;

    char trimmed[32];
    strcopy(trimmed, sizeof(trimmed), text);
    TrimString(trimmed);

    int len = strlen(trimmed);
    if (len <= 0)
    {
        return false;
    }

    for (int i = 0; i < len; i++)
    {
        if (trimmed[i] < '0' || trimmed[i] > '9')
        {
            return false;
        }
    }

    value = StringToInt(trimmed);
    return value > 0;
}

int RoundLotteryTicketValue(int amount)
{
    if (amount <= 0)
    {
        return 0;
    }

    return (amount / LOTTO_TICKET_UNIT) * LOTTO_TICKET_UNIT;
}

int GetLotteryChanceCount(int amount)
{
    int roundedAmount = RoundLotteryTicketValue(amount);
    if (roundedAmount <= 0)
    {
        return 0;
    }

    return roundedAmount / LOTTO_TICKET_UNIT;
}

void ShowLotteryMenu(int client)
{
    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    if (g_ClientLotteryHasTicket[client])
    {
        ShowOwnedLotteryTicketMenu(client);
        return;
    }

    Menu menu = new Menu(MenuHandler_LotteryBuy);
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    char title[BP_CURRENCY_LONG_MAX + 16];
    Format(title, sizeof(title), "%s Lottery", currencyLong);
    menu.SetTitle(title);

    char display[128];
    Format(display, sizeof(display), "10 %s", currencyLong);
    menu.AddItem("10", display);
    Format(display, sizeof(display), "25 %s", currencyLong);
    menu.AddItem("25", display);
    Format(display, sizeof(display), "50 %s", currencyLong);
    menu.AddItem("50", display);
    Format(display, sizeof(display), "100 %s", currencyLong);
    menu.AddItem("100", display);
    menu.AddItem("custom", "Custom (type in chat)");
    menu.AddItem("pool", "Prize pool");
    menu.Display(client, MENU_TIME_FOREVER);
}

void ShowOwnedLotteryTicketMenu(int client)
{
    Menu menu = new Menu(MenuHandler_LotteryOwned);
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    char title[BP_CURRENCY_LONG_MAX + 16];
    Format(title, sizeof(title), "%s Lotto", currencyLong);
    menu.SetTitle(title);
    menu.AddItem("view", "View ticket");
    menu.AddItem("refund", "Refund ticket");
    menu.AddItem("pool", "Prize pool");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_LotteryBuy(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || !IsClientInGameHuman(client))
    {
        return 0;
    }

    char info[32];
    menu.GetItem(item, info, sizeof(info));
    if (StrEqual(info, "custom", false))
    {
        PromptLotteryCustomAmount(client);
        return 0;
    }

    if (StrEqual(info, "pool", false))
    {
        PrintLotteryPrizePool(client);
        return 0;
    }

    int amount = StringToInt(info);
    if (amount > 0)
    {
        AttemptLotteryTicketPurchase(client, amount);
    }
    return 0;
}

public int MenuHandler_LotteryOwned(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || !IsClientInGameHuman(client))
    {
        return 0;
    }

    char info[32];
    menu.GetItem(item, info, sizeof(info));
    if (StrEqual(info, "view", false))
    {
        PrintClientLotteryTicket(client);
    }
    else if (StrEqual(info, "refund", false))
    {
        RefundLotteryTicket(client);
    }
    else if (StrEqual(info, "pool", false))
    {
        PrintLotteryPrizePool(client);
        return 0;
    }
    return 0;
}

void PromptLotteryCustomAmount(int client)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    g_LotteryWaitingCustom[client] = true;
    CPrintToChat(client, "%s[Lottery]{default} Type your ticket value, or {gold}all{default}. Values are rounded down to the nearest %s%d{default}.", colorTag, colorTag, LOTTO_TICKET_UNIT);
}

void PrintClientLotteryTicket(int client)
{
    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    if (!g_ClientLotteryHasTicket[client])
    {
        CPrintToChat(client, "%s[Lottery]{default} You do not have a ticket in the current lottery.", colorTag);
        return;
    }

    char display[LOTTO_TICKET_PRINT_MAX];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    BuildLotteryTicketDisplay(g_ClientLotteryTicket[client], display, sizeof(display));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    CPrintToChat(client, "%s[Lottery]{default} Your ticket: %s\n{gold}Value:{default} %s%d %s{default}", colorTag, display, colorTag, g_ClientLotteryTicketValue[client], currencyLong);
}

void AttemptLotteryAllTicketPurchase(int client)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    if (g_ClientLotteryHasTicket[client])
    {
        ShowOwnedLotteryTicketMenu(client);
        return;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s[Lottery]{default} Your %s are loading. Try again in a moment.", colorTag, currencyLong);
        return;
    }

    AttemptLotteryTicketPurchase(client, GetCachedBonusPoints(client));
}

void AttemptLotteryTicketPurchase(int client, int amount)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    if (g_LotteryDrawInProgress)
    {
        CPrintToChat(client, "%s[Lottery]{default} A lottery draw is already in progress.", colorTag);
        return;
    }

    if (amount <= 0)
    {
        CPrintToChat(client, "%s[Lottery]{default} Ticket value must be greater than 0.", colorTag);
        return;
    }

    int roundedAmount = RoundLotteryTicketValue(amount);
    if (roundedAmount <= 0)
    {
        CPrintToChat(client, "%s[Lottery]{default} Ticket value must be at least %s%d %s{default}.", colorTag, colorTag, LOTTO_TICKET_UNIT, currencyLong);
        return;
    }

    if (roundedAmount != amount)
    {
        CPrintToChat(client, "%s[Lottery]{default} Ticket value rounded down to %s%d %s{default}.", colorTag, colorTag, roundedAmount, currencyLong);
        amount = roundedAmount;
    }

    if (g_ClientLotteryHasTicket[client])
    {
        AttemptLotteryTicketReplacement(client, amount);
        return;
    }

    if (g_LotteryWords == null || g_LotteryWords.Length <= 0)
    {
        CPrintToChat(client, "%s[Lottery]{default} No lottery words are configured.", colorTag);
        return;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s[Lottery]{default} Your %s are loading. Try again in a moment.", colorTag, currencyLong);
        return;
    }

    if (GetCachedBonusPoints(client) < amount)
    {
        CPrintToChat(client, "%s[Lottery]{default} You only have %s%d %s{default}.", colorTag, colorTag, GetCachedBonusPoints(client), currencyLong);
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not read your SteamID64.", colorTag);
        return;
    }

    if (IsLotteryTicketWritePending(steamId))
    {
        CPrintToChat(client, "%s[Lottery]{default} Your lottery ticket is still being saved. Try again in a moment.", colorTag);
        return;
    }

    char ticket[LOTTO_TICKET_MAX];
    GenerateLotteryTicket(ticket, sizeof(ticket));
    if (ticket[0] == '\0')
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not generate a ticket.", colorTag);
        return;
    }

    char displayName[LOTTO_NAME_MAX];
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));

    char escapedSteamId[65];
    char escapedTicket[(LOTTO_TICKET_MAX * 2) + 1];
    char escapedName[(LOTTO_NAME_MAX * 2) + 1];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(ticket, escapedTicket, sizeof(escapedTicket))
        || !EscapeSql(displayName, escapedName, sizeof(escapedName)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not prepare your ticket.", colorTag);
        return;
    }

    if (!SpendBonusPointsWithContext(client, amount, "lottery_ticket", 0))
    {
        CPrintToChat(client, "%s[Lottery]{default} You can't afford that ticket.", colorTag);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_CurrentLotteryId);
    pack.WriteCell(amount);
    pack.WriteString(steamId);
    pack.WriteString(ticket);
    pack.WriteString(displayName);
    BeginLotteryTicketWrite(steamId);

    char query[8192];
    Format(query, sizeof(query),
        "INSERT INTO %s (lottery_id, steamid64, display_name, ticket, ticket_value, created_at) VALUES (%d, '%s', '%s', '%s', %d, %d)",
        LOTTO_TICKET_TABLE,
        g_CurrentLotteryId,
        escapedSteamId,
        escapedName,
        escapedTicket,
        amount,
        GetTime());
    g_Database.Query(SQL_OnLotteryTicketInserted, query, pack);
}

void AttemptLotteryTicketReplacement(int client, int amount)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    if (g_LotteryDrawInProgress)
    {
        CPrintToChat(client, "%s[Lottery]{default} A lottery draw is already in progress.", colorTag);
        return;
    }

    if (!g_ClientLotteryHasTicket[client] || g_ClientLotteryTicketValue[client] <= 0)
    {
        AttemptLotteryTicketPurchase(client, amount);
        return;
    }

    if (g_LotteryWords == null || g_LotteryWords.Length <= 0)
    {
        CPrintToChat(client, "%s[Lottery]{default} No lottery words are configured.", colorTag);
        return;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s[Lottery]{default} Your %s are loading. Try again in a moment.", colorTag, currencyLong);
        return;
    }

    int oldAmount = g_ClientLotteryTicketValue[client];
    int postRefundBalance = GetCachedBonusPoints(client) + oldAmount;
    if (postRefundBalance < amount)
    {
        CPrintToChat(client, "%s[Lottery]{default} Refunding your current ticket would only give you %s%d %s{default}.", colorTag, colorTag, postRefundBalance, currencyLong);
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not read your SteamID64.", colorTag);
        return;
    }

    if (IsLotteryTicketWritePending(steamId))
    {
        CPrintToChat(client, "%s[Lottery]{default} Your lottery ticket is still being saved. Try again in a moment.", colorTag);
        return;
    }

    char ticket[LOTTO_TICKET_MAX];
    GenerateLotteryTicket(ticket, sizeof(ticket));
    if (ticket[0] == '\0')
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not generate a ticket.", colorTag);
        return;
    }

    char displayName[LOTTO_NAME_MAX];
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));

    char escapedSteamId[65];
    char escapedOldTicket[(LOTTO_TICKET_MAX * 2) + 1];
    char escapedTicket[(LOTTO_TICKET_MAX * 2) + 1];
    char escapedName[(LOTTO_NAME_MAX * 2) + 1];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(g_ClientLotteryTicket[client], escapedOldTicket, sizeof(escapedOldTicket))
        || !EscapeSql(ticket, escapedTicket, sizeof(escapedTicket))
        || !EscapeSql(displayName, escapedName, sizeof(escapedName)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not prepare your ticket.", colorTag);
        return;
    }

    int balanceDelta = oldAmount - amount;
    int createdAt = GetTime();

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_CurrentLotteryId);
    pack.WriteCell(amount);
    pack.WriteCell(oldAmount);
    pack.WriteCell(balanceDelta);
    pack.WriteString(steamId);
    pack.WriteString(g_ClientLotteryTicket[client]);
    pack.WriteString(ticket);
    pack.WriteString(displayName);
    BeginLotteryTicketWrite(steamId);

    Transaction txn = new Transaction();
    char query[8192];
    Format(query, sizeof(query),
        "UPDATE %s SET display_name = '%s', ticket = '%s', ticket_value = %d, created_at = %d WHERE lottery_id = %d AND steamid64 = '%s' AND ticket = '%s' AND ticket_value = %d AND EXISTS (SELECT 1 FROM %s WHERE steamid64 = '%s' AND balance + %d >= %d)",
        LOTTO_TICKET_TABLE,
        escapedName,
        escapedTicket,
        amount,
        createdAt,
        g_CurrentLotteryId,
        escapedSteamId,
        escapedOldTicket,
        oldAmount,
        BP_BALANCE_TABLE,
        escapedSteamId,
        oldAmount,
        amount);
    txn.AddQuery(query);

    if (balanceDelta != 0)
    {
        if (g_IsMySql)
        {
            Format(query, sizeof(query),
                "INSERT INTO %s (steamid64, balance) SELECT '%s', %d FROM DUAL WHERE EXISTS (SELECT 1 FROM %s WHERE lottery_id = %d AND steamid64 = '%s' AND ticket = '%s' AND ticket_value = %d AND created_at = %d) ON DUPLICATE KEY UPDATE balance = GREATEST(0, balance + VALUES(balance))",
                BP_BALANCE_TABLE,
                escapedSteamId,
                balanceDelta,
                LOTTO_TICKET_TABLE,
                g_CurrentLotteryId,
                escapedSteamId,
                escapedTicket,
                amount,
                createdAt);
        }
        else
        {
            Format(query, sizeof(query),
                "INSERT INTO %s (steamid64, balance) SELECT '%s', %d WHERE EXISTS (SELECT 1 FROM %s WHERE lottery_id = %d AND steamid64 = '%s' AND ticket = '%s' AND ticket_value = %d AND created_at = %d) ON CONFLICT(steamid64) DO UPDATE SET balance = MAX(0, balance + excluded.balance), updated_at = CURRENT_TIMESTAMP",
                BP_BALANCE_TABLE,
                escapedSteamId,
                balanceDelta,
                LOTTO_TICKET_TABLE,
                g_CurrentLotteryId,
                escapedSteamId,
                escapedTicket,
                amount,
                createdAt);
        }
        txn.AddQuery(query);
    }

    g_Database.Execute(txn, SQLTxn_OnLotteryTicketReplaced, SQLTxn_OnLotteryTicketReplaceFailure, pack);
}

public void SQLTxn_OnLotteryTicketReplaced(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    int amount = pack.ReadCell();
    int oldAmount = pack.ReadCell();
    int balanceDelta = pack.ReadCell();
    char steamId[32];
    char oldTicket[LOTTO_TICKET_MAX];
    char ticket[LOTTO_TICKET_MAX];
    char displayName[LOTTO_NAME_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(oldTicket, sizeof(oldTicket));
    pack.ReadString(ticket, sizeof(ticket));
    pack.ReadString(displayName, sizeof(displayName));
    delete pack;
    FinishLotteryTicketWrite(steamId);

    int client = GetClientOfUserId(userId);
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (numQueries <= 0 || results[0] == null || results[0].AffectedRows <= 0)
    {
        if (IsClientInGameHuman(client))
        {
            CPrintToChat(client, "%s[Lottery]{default} Your existing ticket could not be replaced. Try again in a moment.", colorTag);
            LoadClientLotteryTicket(client);
        }
        return;
    }

    if (IsClientAuthorizedHuman(client) && lotteryId == g_CurrentLotteryId)
    {
        char currentSteamId[32];
        if (GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId)) && StrEqual(currentSteamId, steamId, false))
        {
            int balanceBefore = GetCachedBonusPoints(client);
            if (g_ClientBonusPointsLoaded[client])
            {
                g_ClientBonusPoints[client] += balanceDelta;
                if (g_ClientBonusPoints[client] < 0)
                {
                    g_ClientBonusPoints[client] = 0;
                }
            }

            g_ClientLotteryTicketLoaded[client] = true;
            g_ClientLotteryHasTicket[client] = true;
            g_ClientLotteryId[client] = lotteryId;
            g_ClientLotteryTicketValue[client] = amount;
            strcopy(g_ClientLotteryTicket[client], sizeof(g_ClientLotteryTicket[]), ticket);

            char currencyLong[BP_CURRENCY_LONG_MAX];
            char display[LOTTO_TICKET_PRINT_MAX];
            GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
            BuildLotteryTicketDisplay(ticket, display, sizeof(display));

            if (balanceDelta != 0)
            {
                LogBonusPointsDelta(client, balanceDelta, balanceBefore, GetCachedBonusPoints(client), "lottery_ticket_replace", lotteryId, false, false, 1.0, true, 0, 0);
            }

            CPrintToChatAllEx(client, "{default}%s changed his {gold}!lottery{default} ticket from %s%d %s{default} to %s%d %s{default}", displayName, colorTag, oldAmount, currencyLong, colorTag, amount, currencyLong);
            CPrintToChat(client, "%s[Lottery]{default} Your ticket: %s", colorTag, display);
        }
    }
}

public void SQLTxn_OnLotteryTicketReplaceFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;
    FinishLotteryTicketWrite(steamId);

    int client = GetClientOfUserId(userId);
    if (IsClientInGameHuman(client))
    {
        char colorTag[BP_CURRENCY_COLOR_MAX + 2];
        GetCurrencyColorTag(colorTag, sizeof(colorTag));
        CPrintToChat(client, "%s[Lottery]{default} Your ticket could not be replaced. Try again in a moment.", colorTag);
        LoadClientLotteryTicket(client);
    }

    LogError("[points_store] Lottery ticket replacement failed for %s (query %d): %s", steamId, failIndex, error);
}

public void SQL_OnLotteryTicketInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    int amount = pack.ReadCell();
    char steamId[32];
    char ticket[LOTTO_TICKET_MAX];
    char displayName[LOTTO_NAME_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(ticket, sizeof(ticket));
    pack.ReadString(displayName, sizeof(displayName));
    delete pack;
    FinishLotteryTicketWrite(steamId);

    int client = GetClientOfUserId(userId);
    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to insert lottery ticket for %s: %s", steamId, error);
        CreditSteamId64BonusPoints(steamId, amount, "lottery_ticket_save_refund", lotteryId);
        if (IsClientInGameHuman(client))
        {
            char colorTag[BP_CURRENCY_COLOR_MAX + 2];
            GetCurrencyColorTag(colorTag, sizeof(colorTag));
            CPrintToChat(client, "%s[Lottery]{default} Your ticket could not be saved, so your payment was refunded.", colorTag);
            LoadClientLotteryTicket(client);
        }
        return;
    }

    if (IsClientAuthorizedHuman(client) && lotteryId == g_CurrentLotteryId)
    {
        char currentSteamId[32];
        if (GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId)) && StrEqual(currentSteamId, steamId, false))
        {
            g_ClientLotteryTicketLoaded[client] = true;
            g_ClientLotteryHasTicket[client] = true;
            g_ClientLotteryId[client] = lotteryId;
            g_ClientLotteryTicketValue[client] = amount;
            strcopy(g_ClientLotteryTicket[client], sizeof(g_ClientLotteryTicket[]), ticket);

            char colorTag[BP_CURRENCY_COLOR_MAX + 2];
            char currencyLong[BP_CURRENCY_LONG_MAX];
            char display[LOTTO_TICKET_PRINT_MAX];
            GetCurrencyColorTag(colorTag, sizeof(colorTag));
            GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
            BuildLotteryTicketDisplay(ticket, display, sizeof(display));

            CPrintToChatAllEx(client, "{default}%s bought a {gold}!lottery{default} ticket for %s%d %s{default}", displayName, colorTag, amount, currencyLong);
            CPrintToChat(client, "%s[Lottery]{default} Your ticket: %s", colorTag, display);
        }
    }
}

void RefundLotteryTicket(int client)
{
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (!IsLotteryReadyForClient(client))
    {
        return;
    }

    if (g_LotteryDrawInProgress)
    {
        CPrintToChat(client, "%s[Lottery]{default} You cannot refund while a lottery draw is in progress.", colorTag);
        return;
    }

    if (!g_ClientLotteryHasTicket[client])
    {
        CPrintToChat(client, "%s[Lottery]{default} You do not have a ticket in the current lottery.", colorTag);
        return;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not read your SteamID64.", colorTag);
        return;
    }

    if (IsLotteryTicketWritePending(steamId))
    {
        CPrintToChat(client, "%s[Lottery]{default} Your lottery ticket is still being saved. Try again in a moment.", colorTag);
        return;
    }

    char escapedSteamId[65];
    char escapedTicket[(LOTTO_TICKET_MAX * 2) + 1];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(g_ClientLotteryTicket[client], escapedTicket, sizeof(escapedTicket)))
    {
        CPrintToChat(client, "%s[Lottery]{default} Could not prepare your refund.", colorTag);
        return;
    }

    char displayName[LOTTO_NAME_MAX];
    BuildPurchaseDisplayName(client, displayName, sizeof(displayName));

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_CurrentLotteryId);
    pack.WriteCell(g_ClientLotteryTicketValue[client]);
    pack.WriteString(steamId);
    pack.WriteString(g_ClientLotteryTicket[client]);
    pack.WriteString(displayName);
    BeginLotteryTicketWrite(steamId);

    char query[384];
    Format(query, sizeof(query),
        "DELETE FROM %s WHERE lottery_id = %d AND steamid64 = '%s' AND ticket = '%s' AND ticket_value = %d",
        LOTTO_TICKET_TABLE,
        g_CurrentLotteryId,
        escapedSteamId,
        escapedTicket,
        g_ClientLotteryTicketValue[client]);
    g_Database.Query(SQL_OnLotteryTicketRefunded, query, pack);
}

public void SQL_OnLotteryTicketRefunded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    int amount = pack.ReadCell();
    char steamId[32];
    char ticket[LOTTO_TICKET_MAX];
    char displayName[LOTTO_NAME_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(ticket, sizeof(ticket));
    pack.ReadString(displayName, sizeof(displayName));
    delete pack;
    FinishLotteryTicketWrite(steamId);

    int client = GetClientOfUserId(userId);
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to refund lottery ticket for %s: %s", steamId, error);
        if (IsClientInGameHuman(client))
        {
            CPrintToChat(client, "%s[Lottery]{default} Could not refund your ticket.", colorTag);
        }
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LogError("[points_store] Lottery refund skipped for %s because the cached ticket was stale.", steamId);
        if (IsClientInGameHuman(client))
        {
            CPrintToChat(client, "%s[Lottery]{default} Your ticket changed. Try again in a moment.", colorTag);
            LoadClientLotteryTicket(client);
        }
        return;
    }

    CreditSteamId64BonusPoints(steamId, amount, "lottery_ticket_refund", lotteryId);
    if (IsClientAuthorizedHuman(client) && lotteryId == g_CurrentLotteryId)
    {
        ClearClientLotteryTicketCache(client);
        g_ClientLotteryTicketLoaded[client] = true;
    }

    if (IsClientInGameHuman(client))
    {
        CPrintToChatAllEx(client, "{default}%s refunded his lottery ticket! %s(%d){default}", displayName, colorTag, amount);
    }
    else
    {
        CPrintToChatAll("{default}%s refunded his lottery ticket! %s(%d){default}", displayName, colorTag, amount);
    }
}

void PrintLotteryPrizePool(int client)
{
    if (!IsLotteryReadyForClient(client, false))
    {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_CurrentLotteryId);

    char query[256];
    Format(query, sizeof(query),
        "SELECT COALESCE(SUM(ticket_value), 0), COUNT(*) FROM %s WHERE lottery_id = %d",
        LOTTO_TICKET_TABLE,
        g_CurrentLotteryId);
    g_Database.Query(SQL_OnLotteryPrizePoolLoaded, query, pack);
}

public void SQL_OnLotteryPrizePoolLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsClientInGameHuman(client) || lotteryId != g_CurrentLotteryId)
    {
        return;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    if (error[0] != '\0')
    {
        CPrintToChat(client, "%s[Lotto]{default} Could not load the prize pool.", colorTag);
        LogError("[points_store] Failed to load lottery prize pool: %s", error);
        return;
    }

    int pool = 0;
    int participants = 0;
    if (results != null && results.FetchRow())
    {
        pool = results.FetchInt(0);
        participants = results.FetchInt(1);
    }

    CPrintToChat(client, "%s[Lotto]{default} Prize pool: %s%d", colorTag, colorTag, pool);
    CPrintToChat(client, "{default}Participants: {gold}%d", participants);
}

public Action Command_DoLottery(int client, int args)
{
    if (!IsLotteryEnabled())
    {
        ReplyToCommand(client, "[Lotto] The lottery is disabled on this server.");
        return Plugin_Handled;
    }

    if (!g_DatabaseReady || g_Database == null || !g_LotteryReady || g_CurrentLotteryId <= 0)
    {
        ReplyToCommand(client, "[Lotto] The lottery database is not ready.");
        EnsureActiveLottery();
        return Plugin_Handled;
    }

    if (g_LotteryCallTimer != null)
    {
        ReplyToCommand(client, "[Lotto] A lottery draw is already scheduled.");
        return Plugin_Handled;
    }

    if (g_LotteryDrawInProgress)
    {
        ReplyToCommand(client, "[Lotto] A lottery draw is already in progress.");
        return Plugin_Handled;
    }

    g_LotteryCallRequesterUserId = client > 0 ? GetClientUserId(client) : 0;
    g_LotteryCallLotteryId = g_CurrentLotteryId;

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char shortHash[LOTTO_SHORT_HASH_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetLotteryShortHash(g_CurrentLotteryHash, shortHash, sizeof(shortHash));
    CPrintToChatAll("%s[Lotto]{default} Lottery %s%s{default} is being called in 60 seconds!", colorTag, g_CurrentLotteryHashColor, shortHash);

    g_LotteryCallTimer = CreateTimer(60.0, Timer_LotteryCall, _, TIMER_FLAG_NO_MAPCHANGE);
    if (g_LotteryCallTimer == null)
    {
        g_LotteryCallRequesterUserId = 0;
        g_LotteryCallLotteryId = 0;
        ReplyToCommand(client, "[Lotto] Could not schedule the lottery draw.");
    }
    return Plugin_Handled;
}

public Action Timer_LotteryCall(Handle timer, any data)
{
    if (g_LotteryCallTimer != timer)
    {
        return Plugin_Stop;
    }

    int requesterUserId = g_LotteryCallRequesterUserId;
    int lotteryId = g_LotteryCallLotteryId;
    g_LotteryCallTimer = null;
    g_LotteryCallRequesterUserId = 0;
    g_LotteryCallLotteryId = 0;

    if (!IsLotteryEnabled())
    {
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery is disabled on this server.");
        return Plugin_Stop;
    }

    StartLotteryDraw(requesterUserId, lotteryId);
    return Plugin_Stop;
}

public Action Timer_RetryStartLotteryDraw(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int requesterUserId = pack.ReadCell();
    int lotteryId = pack.ReadCell();

    if (!IsLotteryEnabled())
    {
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery is disabled on this server.");
        return Plugin_Stop;
    }

    StartLotteryDraw(requesterUserId, lotteryId, true);
    return Plugin_Stop;
}

void StartLotteryDraw(int requesterUserId, int lotteryId, bool retry = false)
{
    if (!IsLotteryEnabled())
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery is disabled on this server.");
        return;
    }

    if (!g_DatabaseReady || g_Database == null || !g_LotteryReady || g_CurrentLotteryId <= 0)
    {
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery database is not ready.");
        EnsureActiveLottery();
        return;
    }

    if (lotteryId != g_CurrentLotteryId)
    {
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The scheduled lottery is no longer active.");
        return;
    }

    if (g_LotteryDrawInProgress && !retry)
    {
        ReplyToLotteryRequester(requesterUserId, "[Lotto] A lottery draw is already in progress.");
        return;
    }

    if (!g_LotteryDrawInProgress)
    {
        g_LotteryDrawInProgress = true;
    }

    if (g_LotteryPendingTicketWrites > 0)
    {
        DataPack retryPack = new DataPack();
        retryPack.WriteCell(requesterUserId);
        retryPack.WriteCell(lotteryId);
        CreateTimer(1.0, Timer_RetryStartLotteryDraw, retryPack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteCell(lotteryId);

    char query[256];
    Format(query, sizeof(query),
        "SELECT COUNT(*), COALESCE(SUM(ticket_value), 0) FROM %s WHERE lottery_id = %d",
        LOTTO_TICKET_TABLE,
        lotteryId);
    g_Database.Query(SQL_OnLotteryDrawStatsLoaded, query, pack);
}

public void SQL_OnLotteryDrawStatsLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int requesterUserId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    delete pack;

    if (!IsLotteryEnabled())
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery is disabled on this server.");
        return;
    }

    if (lotteryId != g_CurrentLotteryId)
    {
        g_LotteryDrawInProgress = false;
        return;
    }

    if (error[0] != '\0')
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] Could not load lottery tickets.");
        LogError("[points_store] Failed to load lottery draw stats: %s", error);
        return;
    }

    int ticketCount = 0;
    int prizePool = 0;
    if (results != null && results.FetchRow())
    {
        ticketCount = results.FetchInt(0);
        prizePool = results.FetchInt(1);
    }

    if (ticketCount <= 0 || prizePool <= 0)
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] There are no tickets in the current lottery.");
        return;
    }

    DataPack winnerPack = new DataPack();
    winnerPack.WriteCell(requesterUserId);
    winnerPack.WriteCell(lotteryId);
    winnerPack.WriteCell(prizePool);

    char query[512];
    Format(query, sizeof(query),
        "SELECT steamid64, display_name, ticket, ticket_value FROM %s WHERE lottery_id = %d ORDER BY id",
        LOTTO_TICKET_TABLE,
        lotteryId);
    g_Database.Query(SQL_OnLotteryWinnerSelected, query, winnerPack);
}

public void SQL_OnLotteryWinnerSelected(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int requesterUserId = pack.ReadCell();
    int lotteryId = pack.ReadCell();
    int prizePool = pack.ReadCell();
    delete pack;

    if (!IsLotteryEnabled())
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The lottery is disabled on this server.");
        return;
    }

    if (lotteryId != g_CurrentLotteryId)
    {
        g_LotteryDrawInProgress = false;
        return;
    }

    if (error[0] != '\0' || results == null)
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] Could not select a winner.");
        LogError("[points_store] Failed to select lottery winner: %s", error[0] ? error : "no row returned");
        return;
    }

    ArrayList steamIds = new ArrayList(ByteCountToCells(32));
    ArrayList storedNames = new ArrayList(ByteCountToCells(LOTTO_NAME_MAX));
    ArrayList tickets = new ArrayList(ByteCountToCells(LOTTO_TICKET_MAX));
    ArrayList ticketChances = new ArrayList();
    bool selectedWinners[MAXPLAYERS + 1];
    int totalChances = 0;

    while (results.FetchRow())
    {
        int ticketValue = results.FetchInt(3);
        int chanceCount = GetLotteryChanceCount(ticketValue);
        if (chanceCount <= 0)
        {
            continue;
        }

        if (steamIds.Length >= MAXPLAYERS)
        {
            break;
        }

        char steamId[32];
        char storedName[LOTTO_NAME_MAX];
        char ticket[LOTTO_TICKET_MAX];
        results.FetchString(0, steamId, sizeof(steamId));
        results.FetchString(1, storedName, sizeof(storedName));
        results.FetchString(2, ticket, sizeof(ticket));

        steamIds.PushString(steamId);
        storedNames.PushString(storedName);
        tickets.PushString(ticket);
        ticketChances.Push(chanceCount);
        totalChances += chanceCount;
    }

    int validTicketCount = steamIds.Length;
    if (validTicketCount <= 0 || totalChances <= 0)
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] Could not select a winner.");
        LogError("[points_store] Failed to select lottery winner: no valid ticket values for prize pool %d.", prizePool);
        delete steamIds;
        delete storedNames;
        delete tickets;
        delete ticketChances;
        return;
    }

    int mainWinnerIndex = PickLotteryWinnerIndex(ticketChances, selectedWinners);
    if (mainWinnerIndex < 0)
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] Could not select a winner.");
        LogError("[points_store] Failed to select lottery winner: no weighted index for %d tickets and %d chances.", validTicketCount, totalChances);
        delete steamIds;
        delete storedNames;
        delete tickets;
        delete ticketChances;
        return;
    }

    selectedWinners[mainWinnerIndex] = true;

    g_LotteryDrawExtraWinnerCount = validTicketCount / LOTTO_EXTRA_WINNER_PARTICIPANTS;
    if (g_LotteryDrawExtraWinnerCount > validTicketCount - 1)
    {
        g_LotteryDrawExtraWinnerCount = validTicketCount - 1;
    }

    int extraPrize = (prizePool * LOTTO_EXTRA_WINNER_PERCENT) / 100;
    int welfarePoolPrize = (prizePool * LOTTO_WELFARE_POOL_PERCENT) / 100;
    if (extraPrize <= 0)
    {
        g_LotteryDrawExtraWinnerCount = 0;
    }

    if (g_LotteryDrawExtraWinnerCount <= 0)
    {
        welfarePoolPrize = 0;
    }

    char mainSteamId[32];
    char mainStoredName[LOTTO_NAME_MAX];
    char mainTicket[LOTTO_TICKET_MAX];
    steamIds.GetString(mainWinnerIndex, mainSteamId, sizeof(mainSteamId));
    storedNames.GetString(mainWinnerIndex, mainStoredName, sizeof(mainStoredName));
    tickets.GetString(mainWinnerIndex, mainTicket, sizeof(mainTicket));

    strcopy(g_LotteryDrawWinnerSteamId, sizeof(g_LotteryDrawWinnerSteamId), mainSteamId);
    ResolveLotteryWinnerName(mainSteamId, mainStoredName, g_LotteryDrawWinnerName, sizeof(g_LotteryDrawWinnerName));

    for (int i = 0; i < g_LotteryDrawExtraWinnerCount; i++)
    {
        int extraWinnerIndex = PickLotteryWinnerIndex(ticketChances, selectedWinners);
        if (extraWinnerIndex < 0)
        {
            g_LotteryDrawExtraWinnerCount = i;
            break;
        }

        selectedWinners[extraWinnerIndex] = true;
        g_LotteryDrawExtraWinnerPrizes[i] = extraPrize;
        char extraSteamId[32];
        char extraStoredName[LOTTO_NAME_MAX];
        steamIds.GetString(extraWinnerIndex, extraSteamId, sizeof(extraSteamId));
        storedNames.GetString(extraWinnerIndex, extraStoredName, sizeof(extraStoredName));

        strcopy(g_LotteryDrawExtraWinnerSteamIds[i], sizeof(g_LotteryDrawExtraWinnerSteamIds[]), extraSteamId);
        ResolveLotteryWinnerName(extraSteamId, extraStoredName, g_LotteryDrawExtraWinnerNames[i], sizeof(g_LotteryDrawExtraWinnerNames[]));
    }

    g_LotteryDrawWelfarePoolPrize = welfarePoolPrize * g_LotteryDrawExtraWinnerCount;
    g_LotteryDrawWinnerPrize = prizePool - ((extraPrize * g_LotteryDrawExtraWinnerCount) + g_LotteryDrawWelfarePoolPrize);
    if (g_LotteryDrawWinnerPrize <= 0)
    {
        g_LotteryDrawWinnerPrize = prizePool;
        g_LotteryDrawExtraWinnerCount = 0;
        g_LotteryDrawWelfarePoolPrize = 0;
    }

    g_LotteryDrawLotteryId = lotteryId;
    g_LotteryDrawPrizePool = prizePool;
    g_LotteryDrawIndex = 0;
    strcopy(g_LotteryDrawHash, sizeof(g_LotteryDrawHash), g_CurrentLotteryHash);
    strcopy(g_LotteryDrawHashColor, sizeof(g_LotteryDrawHashColor), g_CurrentLotteryHashColor);
    BuildLotteryDrawTokens(mainTicket);

    delete steamIds;
    delete storedNames;
    delete tickets;
    delete ticketChances;

    if (g_LotteryDrawTokens.Length <= 0)
    {
        g_LotteryDrawInProgress = false;
        ReplyToLotteryRequester(requesterUserId, "[Lotto] The selected ticket had no printable words.");
        return;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    char shortHash[LOTTO_SHORT_HASH_MAX];
    GetLotteryShortHash(g_LotteryDrawHash, shortHash, sizeof(shortHash));
    CPrintToChatAll("%s[Lotto]{default} Drawing lottery %s%s{default}...", colorTag, g_LotteryDrawHashColor, shortHash);

    g_LotteryDrawTimer = CreateTimer(LOTTO_REVEAL_INTERVAL, Timer_LotteryReveal, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

int PickLotteryWinnerIndex(ArrayList ticketChances, bool[] selectedWinners)
{
    int totalChances = 0;
    int ticketCount = ticketChances.Length;
    for (int i = 0; i < ticketCount; i++)
    {
        if (!selectedWinners[i])
        {
            totalChances += ticketChances.Get(i);
        }
    }

    if (totalChances <= 0)
    {
        return -1;
    }

    int roll = GetRandomInt(1, totalChances);
    int running = 0;
    for (int i = 0; i < ticketCount; i++)
    {
        if (selectedWinners[i])
        {
            continue;
        }

        running += ticketChances.Get(i);
        if (roll <= running)
        {
            return i;
        }
    }

    return -1;
}

public Action Timer_LotteryReveal(Handle timer, any data)
{
    if (g_LotteryDrawTimer != timer)
    {
        return Plugin_Stop;
    }

    if (!IsLotteryEnabled())
    {
        g_LotteryDrawTimer = null;
        g_LotteryDrawInProgress = false;
        ResetLotteryDrawState();
        return Plugin_Stop;
    }

    if (g_LotteryDrawIndex < g_LotteryDrawTokens.Length)
    {
        char token[LOTTO_TOKEN_MAX];
        g_LotteryDrawTokens.GetString(g_LotteryDrawIndex, token, sizeof(token));
        CPrintToChatAll("%s", token);
        g_LotteryDrawIndex++;
        return Plugin_Continue;
    }

    g_LotteryDrawTimer = null;
    FinalizeLotteryDraw();
    return Plugin_Stop;
}

void FinalizeLotteryDraw()
{
    if (!IsLotteryEnabled())
    {
        g_LotteryDrawInProgress = false;
        ResetLotteryDrawState();
        return;
    }

    char winnerName[LOTTO_NAME_MAX];
    ResolveLotteryWinnerName(g_LotteryDrawWinnerSteamId, g_LotteryDrawWinnerName, winnerName, sizeof(winnerName));

    char escapedSteamId[65];
    char escapedWinnerName[(LOTTO_NAME_MAX * 2) + 1];
    if (!EscapeSql(g_LotteryDrawWinnerSteamId, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(winnerName, escapedWinnerName, sizeof(escapedWinnerName)))
    {
        LogError("[points_store] Failed to escape lottery winner data.");
        g_LotteryDrawInProgress = false;
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(g_LotteryDrawLotteryId);
    pack.WriteCell(g_LotteryDrawWinnerPrize);
    pack.WriteString(g_LotteryDrawWinnerSteamId);
    pack.WriteString(winnerName);
    pack.WriteString(g_LotteryDrawHash);
    pack.WriteString(g_LotteryDrawHashColor);

    char query[768];
    Format(query, sizeof(query),
        "UPDATE %s SET finished = 1, finished_at = %d, winner_steamid64 = '%s', winner_name = '%s', prize_pool = %d WHERE id = %d AND finished = 0",
        LOTTO_TABLE,
        GetTime(),
        escapedSteamId,
        escapedWinnerName,
        g_LotteryDrawPrizePool,
        g_LotteryDrawLotteryId);
    g_Database.Query(SQL_OnLotteryFinished, query, pack);
}

public void SQL_OnLotteryFinished(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int lotteryId = pack.ReadCell();
    int winnerPrize = pack.ReadCell();
    char winnerSteamId[32];
    char winnerName[LOTTO_NAME_MAX];
    char hash[LOTTO_HASH_MAX];
    char hashColor[BP_CURRENCY_COLOR_MAX + 2];
    pack.ReadString(winnerSteamId, sizeof(winnerSteamId));
    pack.ReadString(winnerName, sizeof(winnerName));
    pack.ReadString(hash, sizeof(hash));
    pack.ReadString(hashColor, sizeof(hashColor));
    delete pack;

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed to mark lottery %d finished: %s", lotteryId, error);
        char colorTag[BP_CURRENCY_COLOR_MAX + 2];
        GetCurrencyColorTag(colorTag, sizeof(colorTag));
        CPrintToChatAll("%s[Lotto]{default} The lottery could not be finalized. Prize was not paid; check logs.", colorTag);
        g_LotteryDrawInProgress = false;
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LogError("[points_store] Lottery %d was already finalized; skipping duplicate payout.", lotteryId);
        g_LotteryDrawInProgress = false;
        g_LotteryReady = false;
        g_CurrentLotteryId = 0;
        g_CurrentLotteryHash[0] = '\0';
        g_CurrentLotteryHashColor[0] = '\0';
        ClearAllClientLotteryCaches();
        ResetLotteryDrawState();
        EnsureActiveLottery();
        return;
    }

    CreditSteamId64BonusPoints(winnerSteamId, winnerPrize, "lottery_main_payout", lotteryId);
    for (int i = 0; i < g_LotteryDrawExtraWinnerCount; i++)
    {
        CreditSteamId64BonusPoints(g_LotteryDrawExtraWinnerSteamIds[i], g_LotteryDrawExtraWinnerPrizes[i], "lottery_extra_payout", lotteryId);
    }
    RecordLotteryWelfarePoolCredit(g_LotteryDrawWelfarePoolPrize, lotteryId);

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char shortHash[LOTTO_SHORT_HASH_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    GetLotteryShortHash(hash, shortHash, sizeof(shortHash));
    CPrintToChatAll("%s[Lotto]{default} %s won lottery %s%s{default} for %s%d %s{default}!", colorTag, winnerName, hashColor, shortHash, colorTag, winnerPrize, currencyLong);

    for (int i = 0; i < g_LotteryDrawExtraWinnerCount; i++)
    {
        CPrintToChatAll("{default}%s won %s%d %s{default}!", g_LotteryDrawExtraWinnerNames[i], colorTag, g_LotteryDrawExtraWinnerPrizes[i], currencyLong);
    }

    g_LotteryDrawInProgress = false;
    g_LotteryReady = false;
    g_CurrentLotteryId = 0;
    g_CurrentLotteryHash[0] = '\0';
    g_CurrentLotteryHashColor[0] = '\0';
    ClearAllClientLotteryCaches();
    ResetLotteryDrawState();
    EnsureActiveLottery();
}

void ResetLotteryDrawState()
{
    g_LotteryDrawIndex = 0;
    g_LotteryDrawLotteryId = 0;
    g_LotteryDrawPrizePool = 0;
    g_LotteryDrawWinnerPrize = 0;
    g_LotteryDrawWelfarePoolPrize = 0;
    g_LotteryDrawWinnerSteamId[0] = '\0';
    g_LotteryDrawWinnerName[0] = '\0';
    g_LotteryDrawExtraWinnerCount = 0;
    for (int i = 0; i <= MaxClients; i++)
    {
        g_LotteryDrawExtraWinnerPrizes[i] = 0;
        g_LotteryDrawExtraWinnerSteamIds[i][0] = '\0';
        g_LotteryDrawExtraWinnerNames[i][0] = '\0';
    }
    g_LotteryDrawHash[0] = '\0';
    g_LotteryDrawHashColor[0] = '\0';
    if (g_LotteryDrawTokens != null)
    {
        g_LotteryDrawTokens.Clear();
    }
}

void CancelPendingLotteryCall()
{
    if (g_LotteryCallTimer != null)
    {
        KillTimer(g_LotteryCallTimer);
        g_LotteryCallTimer = null;
    }
    g_LotteryCallRequesterUserId = 0;
    g_LotteryCallLotteryId = 0;
}

void CancelActiveLotteryDrawForMapChange()
{
    if (g_LotteryDrawTimer != null)
    {
        KillTimer(g_LotteryDrawTimer);
        g_LotteryDrawTimer = null;
    }

    if (g_LotteryDrawInProgress)
    {
        LogMessage("[points_store] Lottery draw state cleared on map end for lottery %d.", g_LotteryDrawLotteryId);
    }

    g_LotteryDrawInProgress = false;
    ResetLotteryDrawState();
}

void ReplyToLotteryRequester(int userId, const char[] format, any ...)
{
    char message[256];
    VFormat(message, sizeof(message), format, 3);

    int client = userId > 0 ? GetClientOfUserId(userId) : 0;
    if (client > 0 || userId == 0)
    {
        ReplyToCommand(client, "%s", message);
    }
}

void BuildLotteryTicketDisplay(const char[] storedTicket, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    int out = 0;
    int len = strlen(storedTicket);
    for (int i = 0; i < len && out < maxlen - 1; i++)
    {
        if (i > 0 && storedTicket[i] == '{' && out < maxlen - 2)
        {
            buffer[out++] = ' ';
        }
        buffer[out++] = storedTicket[i];
    }
    buffer[out] = '\0';
}

void BuildLotteryDrawTokens(const char[] storedTicket)
{
    g_LotteryDrawTokens.Clear();

    int len = strlen(storedTicket);
    int start = 0;
    for (int i = 1; i < len; i++)
    {
        if (storedTicket[i] == '{')
        {
            PushLotteryDrawToken(storedTicket, start, i);
            start = i;
        }
    }

    if (start < len)
    {
        PushLotteryDrawToken(storedTicket, start, len);
    }
}

void PushLotteryDrawToken(const char[] storedTicket, int start, int end)
{
    char token[LOTTO_TOKEN_MAX];
    int out = 0;
    for (int i = start; i < end && out < sizeof(token) - 1; i++)
    {
        token[out++] = storedTicket[i];
    }
    token[out] = '\0';
    TrimString(token);
    if (token[0] != '\0')
    {
        g_LotteryDrawTokens.PushString(token);
    }
}

void GenerateLotteryTicket(char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (g_LotteryWords == null || g_LotteryWords.Length <= 0)
    {
        return;
    }

    int wordCount = GetRandomInt(6, 10);
    bool allowDuplicates = g_LotteryWords.Length < wordCount;
    StringMap usedWords = new StringMap();

    for (int i = 0; i < wordCount; i++)
    {
        char word[LOTTO_WORD_MAX];
        bool picked = false;
        for (int attempt = 0; attempt < 64; attempt++)
        {
            if (!PickWeightedLotteryWord(word, sizeof(word)))
            {
                break;
            }

            int dummy = 0;
            if (allowDuplicates || !usedWords.GetValue(word, dummy))
            {
                picked = true;
                usedWords.SetValue(word, 1, true);
                break;
            }
        }

        if (!picked)
        {
            continue;
        }

        char colorName[BP_CURRENCY_COLOR_MAX];
        char token[LOTTO_TOKEN_MAX];
        GetRandomLotteryColorName(colorName, sizeof(colorName));
        Format(token, sizeof(token), "{%s}%s", colorName, word);
        StrCat(buffer, maxlen, token);
    }

    delete usedWords;
}

bool PickWeightedLotteryWord(char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (g_LotteryWords == null || g_LotteryWords.Length <= 0)
    {
        return false;
    }

    int totalWeight = g_LotteryTotalWeight;
    if (totalWeight <= 0)
    {
        totalWeight = 1;
    }

    int roll = GetRandomInt(1, totalWeight);
    int running = 0;
    for (int i = 0; i < g_LotteryWords.Length; i++)
    {
        int rarity = g_LotteryRarities.Get(i);
        running += GetLotteryRarityWeight(rarity);
        if (roll <= running)
        {
            g_LotteryWords.GetString(i, buffer, maxlen);
            return buffer[0] != '\0';
        }
    }

    g_LotteryWords.GetString(g_LotteryWords.Length - 1, buffer, maxlen);
    return buffer[0] != '\0';
}

int GetLotteryRarityWeight(int rarity)
{
    switch (rarity)
    {
        case 1: return 12;
        case 2: return 4;
        case 3: return 1;
    }
    return 1;
}

void GetRandomLotteryColorName(char[] buffer, int maxlen)
{
    int index = GetRandomInt(0, sizeof(g_LotteryColors) - 1);
    strcopy(buffer, maxlen, g_LotteryColors[index]);
}

void BuildLotteryHash(int createdAt, char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    buffer[0] = '\0';

    char input[32];
    IntToString(createdAt, input, sizeof(input));

    int hash = -2128831035;
    int len = strlen(input);
    for (int i = 0; i < len; i++)
    {
        hash ^= input[i];
        hash *= 16777619;
    }

    int h1 = hash & 0x7fffffff;
    int h2 = (hash ^ (createdAt * 1103515245)) & 0x7fffffff;
    Format(buffer, maxlen, "%07x%07x", h1, h2);
}

void GetLotteryShortHash(const char[] hash, char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    buffer[0] = '\0';

    int copyLen = strlen(hash);
    if (copyLen < LOTTO_SHORT_HASH_LEN)
    {
        strcopy(buffer, maxlen, "unknown");
        return;
    }

    copyLen = LOTTO_SHORT_HASH_LEN;
    if (copyLen > maxlen - 1)
    {
        copyLen = maxlen - 1;
    }

    for (int i = 0; i < copyLen; i++)
    {
        buffer[i] = hash[i];
    }
    buffer[copyLen] = '\0';
}

void ResolveLotteryWinnerName(const char[] steamId, const char[] storedName, char[] buffer, int maxlen)
{
    int client = FindClientBySteamId64(steamId);
    if (client > 0)
    {
        BuildPurchaseDisplayName(client, buffer, maxlen);
        return;
    }

    if (storedName[0] != '\0')
    {
        strcopy(buffer, maxlen, storedName);
        return;
    }

    strcopy(buffer, maxlen, steamId);
}

int FindClientBySteamId64(const char[] steamId)
{
    return Kogasa_FindClientBySteamId64(steamId, true);
}

void CreditSteamId64BonusPoints(const char[] steamId, int amount, const char[] reason = "direct_credit", int lotteryId = 0)
{
    if (amount <= 0 || !g_DatabaseReady || g_Database == null)
    {
        return;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[points_store] Failed to escape SteamID64 for direct lottery credit.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteString(steamId);
    pack.WriteCell(amount);
    pack.WriteString(reason);
    pack.WriteCell(lotteryId);

    char query[512];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) VALUES ('%s', %d) ON DUPLICATE KEY UPDATE balance = GREATEST(0, balance + VALUES(balance))",
            BP_BALANCE_TABLE,
            escapedSteamId,
            amount);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) VALUES ('%s', %d) ON CONFLICT(steamid64) DO UPDATE SET balance = MAX(0, balance + excluded.balance), updated_at = CURRENT_TIMESTAMP",
            BP_BALANCE_TABLE,
            escapedSteamId,
            amount);
    }

    g_Database.Query(SQL_OnLotteryDirectCredit, query, pack);
}

public void SQL_OnLotteryDirectCredit(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    int amount = pack.ReadCell();
    char reason[64];
    pack.ReadString(reason, sizeof(reason));
    int lotteryId = pack.ReadCell();
    delete pack;

    if (error[0] != '\0')
    {
        LogError("[points_store] Failed direct lottery credit for %s: %s", steamId, error);
        return;
    }

    int client = FindClientBySteamId64(steamId);
    int balanceAfter = -1;
    if (client > 0 && g_ClientBonusPointsLoaded[client])
    {
        g_ClientBonusPoints[client] += amount;
        if (g_ClientBonusPoints[client] < 0)
        {
            g_ClientBonusPoints[client] = 0;
        }
        balanceAfter = g_ClientBonusPoints[client];
    }

    LogLotteryCreditEvent(reason, steamId, amount, lotteryId, client, balanceAfter);
}

void LoadLotteryWords()
{
    g_LotteryWords.Clear();
    g_LotteryRarities.Clear();
    g_LotteryTotalWeight = 0;

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/points_store.cfg");

    File file = OpenFile(configPath, "r");
    if (file == null)
    {
        LogError("[points_store] Could not open %s for lottery words.", configPath);
        return;
    }

    bool inLottery = false;
    int depth = 0;
    char line[256];
    while (!IsEndOfFile(file) && ReadFileLine(file, line, sizeof(line)))
    {
        StripLineComment(line);
        TrimString(line);
        if (line[0] == '\0')
        {
            continue;
        }

        if (!inLottery)
        {
            char section[64];
            if (ExtractFirstQuotedToken(line, section, sizeof(section)) && StrEqual(section, "lottery", false))
            {
                inLottery = true;
                if (StrContains(line, "{") != -1)
                {
                    depth = 1;
                }
            }
            continue;
        }

        if (StrContains(line, "{") != -1)
        {
            depth++;
            continue;
        }

        if (StrContains(line, "}") != -1)
        {
            depth--;
            if (depth <= 0)
            {
                break;
            }
            continue;
        }

        if (depth <= 0)
        {
            continue;
        }

        char word[LOTTO_WORD_MAX];
        char rarityText[16];
        if (!ExtractTwoQuotedTokens(line, word, sizeof(word), rarityText, sizeof(rarityText)))
        {
            continue;
        }

        TrimString(word);
        TrimString(rarityText);
        int rarity = StringToInt(rarityText);
        if (rarity < 1)
        {
            rarity = 1;
        }
        else if (rarity > 3)
        {
            rarity = 3;
        }

        if (word[0] != '\0')
        {
            g_LotteryWords.PushString(word);
            g_LotteryRarities.Push(rarity);
            g_LotteryTotalWeight += GetLotteryRarityWeight(rarity);
        }
    }

    delete file;
    LogMessage("[points_store] Loaded %d lottery word(s).", g_LotteryWords.Length);
}

void StripLineComment(char[] line)
{
    bool inQuote = false;
    int len = strlen(line);
    for (int i = 0; i < len; i++)
    {
        if (line[i] == '"')
        {
            inQuote = !inQuote;
            continue;
        }

        if (!inQuote && line[i] == '/' && i + 1 < len && line[i + 1] == '/')
        {
            line[i] = '\0';
            return;
        }
    }
}

bool ExtractFirstQuotedToken(const char[] text, char[] token, int tokenLen)
{
    int pos = 0;
    return ReadQuotedToken(text, pos, token, tokenLen);
}

bool ExtractTwoQuotedTokens(const char[] text, char[] first, int firstLen, char[] second, int secondLen)
{
    int pos = 0;
    return ReadQuotedToken(text, pos, first, firstLen) && ReadQuotedToken(text, pos, second, secondLen);
}

bool ReadQuotedToken(const char[] text, int &pos, char[] token, int tokenLen)
{
    token[0] = '\0';
    int len = strlen(text);
    while (pos < len && text[pos] != '"')
    {
        pos++;
    }

    if (pos >= len)
    {
        return false;
    }

    pos++;
    int out = 0;
    while (pos < len && text[pos] != '"')
    {
        if (out < tokenLen - 1)
        {
            token[out++] = text[pos];
        }
        pos++;
    }
    token[out] = '\0';

    if (pos >= len)
    {
        return false;
    }

    pos++;
    return true;
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

bool IsClientInGameHuman(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
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
    if (!IsClientInGameHuman(client))
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
    return IsClientInGameHuman(client) && g_ClientBonusPointsLoaded[client];
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

public void OnLotteryDisabledConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (IsLotteryEnabled())
    {
        EnsureActiveLottery();
        return;
    }

    ClearLocalLotteryState();
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

    switch (TF2_GetPlayerClass(client))
    {
        case TFClass_Scout:     strcopy(className, maxlen, "scout");
        case TFClass_Soldier:   strcopy(className, maxlen, "soldier");
        case TFClass_Pyro:      strcopy(className, maxlen, "pyro");
        case TFClass_DemoMan:   strcopy(className, maxlen, "demoman");
        case TFClass_Heavy:     strcopy(className, maxlen, "heavy");
        case TFClass_Engineer:  strcopy(className, maxlen, "engineer");
        case TFClass_Medic:     strcopy(className, maxlen, "medic");
        case TFClass_Sniper:    strcopy(className, maxlen, "sniper");
        case TFClass_Spy:       strcopy(className, maxlen, "spy");
        default:                strcopy(className, maxlen, "unknown");
    }

    SanitizeLogField(className, maxlen);
}

bool IsBonusPointsNumericTargetType(const char[] type)
{
    return StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false);
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

void QueuePointsStoreEvent(const char[] message)
{
    PluginStats_LogMessage(message);
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

void LogLotteryCreditEvent(const char[] reason, const char[] steamId, int amount, int lotteryId, int client, int balanceAfter)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char safeReason[64];
    char safeSteamId[32];
    char clientName[MAX_NAME_LENGTH];
    char clientClass[16];
    strcopy(safeReason, sizeof(safeReason), reason);
    strcopy(safeSteamId, sizeof(safeSteamId), steamId);
    SanitizeLogField(safeReason, sizeof(safeReason));
    SanitizeLogField(safeSteamId, sizeof(safeSteamId));

    if (client > 0)
    {
        char ignoredSteamId[32];
        GetClientLogIdentity(client, ignoredSteamId, sizeof(ignoredSteamId), clientName, sizeof(clientName));
        GetClientLogClass(client, clientClass, sizeof(clientClass));
    }
    else
    {
        strcopy(clientName, sizeof(clientName), "offline");
        strcopy(clientClass, sizeof(clientClass), "none");
    }

    LogPointsStoreEvent(
        "event=lottery_credit|time=%d|reason=%s|lottery_id=%d|client=%d|steamid64=%s|name=\"%s\"|class=%s|amount=%d|balance_after=%d",
        GetTime(),
        safeReason,
        lotteryId,
        client,
        safeSteamId,
        clientName,
        clientClass,
        amount,
        balanceAfter);
}

#include "points_store/bonus_labels.inc"

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

    int client = FindClientBySteamId64(steamId);
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

void RecordLotteryWelfarePoolCredit(int amount, int lotteryId)
{
    if (amount <= 0)
    {
        return;
    }

    if (QueueEconomyDelta(BP_ECONOMY_WELFARE_POOL_KEY, amount))
    {
        g_WelfarePoolBalance += amount;
    }

    LogEconomyEvent("lottery_welfare_pool", 0, amount, "lottery_tax", lotteryId, g_WelfarePoolBalance, g_CumulativeSpentBalance);
}

void PlayBonusPointsSound(int client, bool force)
{
    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") != FeatureStatus_Available)
    {
        return;
    }

    SaySounds_PlayCommand(client, BP_SOUND_COMMAND, force);
}

void PlayWelfareSound()
{
    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") != FeatureStatus_Available)
    {
        return;
    }

    SaySounds_PlayCommand(0, BP_WELFARE_SOUND_COMMAND, false);
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
    return count;
}

void BuildPerMapAwardSuffix(int perMapUsed, int perMap, char[] suffix, int maxlen)
{
    suffix[0] = '\0';
    if (perMap > 0 && perMapUsed > 0)
    {
        Format(suffix, maxlen, " (%d/%d)", perMapUsed, perMap);
    }
}

int GetEffectivePerMapAwardLimit(const char[] type, int perMap)
{
    if (StrEqual(type, "reflect", false))
    {
        return REFLECT_BONUS_PER_MAP_LIMIT;
    }

    return perMap;
}

bool ApplyBonusPointsNow(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, int perMap = 0, const char[] targetNameSnapshot = "")
{
    perMap = GetEffectivePerMapAwardLimit(type, perMap);

    if (!IsClientInGameHuman(client) || points == 0)
    {
        LogBonusPointsRejected(!IsClientInGameHuman(client) ? "invalid_client" : "zero_delta", client, points, type, target, 0, randomChance, 0.0);
        return false;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        LogBonusPointsRejected("balance_not_loaded", client, points, type, target, 0, randomChance, 0.0);
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

bool ApplyBonusPoints(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0, int perMap = 0)
{
    perMap = GetEffectivePerMapAwardLimit(type, perMap);

    if (delay < 0.0)
    {
        delay = 0.0;
    }

    if (delay == 0.0)
    {
        return ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target, perMap);
    }

    if (!IsClientInGameHuman(client) || points == 0)
    {
        LogBonusPointsRejected(!IsClientInGameHuman(client) ? "deferred_invalid_client" : "deferred_zero_delta", client, points, type, target, 0, randomChance, 0.0);
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
    if (StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false))
    {
        pack.WriteCell(target);
    }
    else
    {
        if (IsClientInGameHuman(target))
        {
            BuildPurchaseDisplayName(target, targetNameSnapshot, sizeof(targetNameSnapshot));
        }
        pack.WriteCell(IsClientInGameHuman(target) ? GetClientUserId(target) : 0);
    }
    pack.WriteString(targetNameSnapshot);

    CreateTimer(delay, Timer_DeferredApplyBonusPoints, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    return true;
}

bool ApplyBonusPointsSteamId(const char[] steamId, int points, bool playSound = true, bool chatAlert = true, const char[] type = "", int perMap = 0)
{
    if (steamId[0] == '\0' || points == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    int client = FindClientBySteamId64(steamId);
    if (client > 0 && AreBonusPointsReady(client))
    {
        return ApplyBonusPointsNow(client, points, playSound, chatAlert, 1.0, type, 0, perMap);
    }

    perMap = GetEffectivePerMapAwardLimit(type, perMap);

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
    int target = (StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false)) ? targetValue : GetClientOfUserId(targetValue);

    ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target, perMap, targetNameSnapshot);
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

    if (StrEqual(type, "points_diff", false) && IsClientInGameHuman(target))
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

    if (StrEqual(type, "top_score_kill", false) && IsClientInGameHuman(target))
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

    if (StrEqual(type, "player_dom", false) && IsClientInGameHuman(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Dominating{default} %N%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "player_revenge", false) && IsClientInGameHuman(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Revenge{default} on %N%s", prefix, sign, points, target, perMapSuffix);
        return;
    }
    if (StrEqual(type, "player_revenge", false) && targetNameSnapshot[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Revenge{default} on %s%s", prefix, sign, points, targetNameSnapshot, perMapSuffix);
        return;
    }

    if (StrEqual(type, "killstreak", false))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}Killstreak: %d{default}%s", prefix, sign, points, target, perMapSuffix);
        return;
    }

    if (StrEqual(type, "multikill", false))
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
    if (!IsClientInGameHuman(client))
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

    char query[1152];
    Format(query, sizeof(query),
        "SELECT b.steamid64, b.balance, COALESCE(NULLIF(pc.prename,''), NULLIF(pc.name,''), b.steamid64), COALESCE(NULLIF(pc.name_color,''), 'gold') "
        ... "FROM %s b "
        ... "LEFT JOIN whaletracker_points_cache pc ON %s "
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

    if (!IsClientInGameHuman(client))
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
    if (!IsClientInGameHuman(client))
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
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    char prefix[96];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    int target = client;
    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);
        if (targetArg[0])
        {
            int candidate = FindTarget(client, targetArg, true, false);
            if (candidate > 0 && IsClientInGameHuman(candidate))
            {
                target = candidate;
            }
            else
            {
                CPrintToChat(client, "%s Could not find player '%s'.", prefix, targetArg);
                return Plugin_Handled;
            }
        }
    }

    if (!AreBonusPointsReady(target))
    {
        LoadClientBonusPoints(target);
        CPrintToChat(client, "%s %N's %s are loading. Try again in a moment.", prefix, target, currencyLong);
        return Plugin_Handled;
    }

    char msg1[384];
    FormatEx(msg1, sizeof(msg1),
        "%N's %s: {lightgreen}%i{default}\n"
        ... "{lightgreen}+3{default}: Medic drops, penta-kills, ending 20+ killstreaks\n"
        ... "{lightgreen}+2{default}: Triple-kills, quadra-kills, ending 10+ killstreaks",
        target,
        currencyLong,
        GetCachedBonusPoints(target));

    char msg2[256];
    FormatEx(msg2, sizeof(msg2),
        "{lightgreen}+1:{default} Airshot kills, market garden kills, ubers, killstreaks, dominations, revenge, meatshot kills, Sandman-Cleaver combos, medic assist lives");

    CPrintToChat(client, "%s", msg1);
    CPrintToChat(client, "%s", msg2);
    return Plugin_Handled;
}

public Action Command_SendBonusPoints(int client, int args)
{
    if (!IsClientInGameHuman(client))
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
    if (target <= 0 || !IsClientInGameHuman(target))
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
        if (!IsClientInGameHuman(i))
        {
            continue;
        }

        CPrintToChatEx(i, client, "%s %s sent %s %i %s%s{default}!", prefix, senderDisplay, targetDisplay, amount, colorTag, sentCurrencyShort);
    }
    return Plugin_Handled;
}

public Action Command_Welfare(int client, int args)
{
    if (!IsClientInGameHuman(client))
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
    if (minPlayers > 0 && GetClientCount(false) < minPlayers)
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
        if (IsClientInGameHuman(client))
        {
            CPrintToChat(client, "%s Could not collect welfare right now.", prefix);
        }
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LoadEconomyState();
        if (IsClientInGameHuman(client))
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

    if (!IsClientInGameHuman(client) || !ApplyBonusPoints(client, amount, false, false, 1.0, "welfare", 0, 0.0, 1))
    {
        QueueEconomyDelta(BP_ECONOMY_WELFARE_POOL_KEY, amount);
        g_WelfarePoolBalance += amount;
        LogEconomyEvent("welfare_pool_refund", client, amount, "welfare", 0, g_WelfarePoolBalance, g_CumulativeSpentBalance);
        if (IsClientInGameHuman(client))
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

    for (int i = 0; i < g_ItemPrices.Length; i++)
    {
        g_ItemKeys.GetString(i, itemKey, sizeof(itemKey));
        g_ItemNames.GetString(i, itemName, sizeof(itemName));
        int price = g_ItemPrices.Get(i);
        int ownedPrice = GetCachedPurchasePrice(client, itemKey);

        if (ownedPrice > 0)
        {
            Format(display, sizeof(display), "%s BOUGHT", itemName);
            menu.AddItem(itemKey, display, ITEMDRAW_DISABLED);
        }
        else
        {
            GetCurrencyShortLabelForAmount(price, currencyShort, sizeof(currencyShort));
            Format(display, sizeof(display), "%s %d %s", itemName, price, currencyShort);
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

    if (!IsClientInGameHuman(client))
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
    if (!IsClientInGameHuman(client))
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

    char currencyShort[BP_CURRENCY_SHORT_MAX];
    char purchaseDisplay[96];
    int price = g_ItemPrices.Get(itemIndex);
    GetCurrencyShortLabelForAmount(price, currencyShort, sizeof(currencyShort));
    Format(purchaseDisplay, sizeof(purchaseDisplay), "Purchase (%d %s)", price, currencyShort);
    menu.AddItem("purchase", purchaseDisplay);
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
        if (IsClientInGameHuman(client))
        {
            ShowShopMenu(client);
        }
        return 0;
    }

    if (action != MenuAction_Select || !IsClientInGameHuman(client))
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
        if (IsClientInGameHuman(client))
        {
            PrintToChat(client, "[Shop] Your purchase could not be saved. Contact an admin.");
        }
        return;
    }

    g_ClientPurchases[client].SetValue(itemKey, price);
    g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
    g_ClientPurchaseUsesRemaining[client].SetValue(itemKey, useCount);
    LogPurchaseEvent("purchase_success", "ok", client, itemKey, itemName, price, GetCachedBonusPoints(client));
    if (IsClientInGameHuman(client))
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
    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") != FeatureStatus_Available)
    {
        return;
    }

    SaySounds_PlayCommand(0, "xp_gain", false);
}

static void BuildPurchaseDisplayName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen)
        && buffer[0] != '\0')
    {
        ResolveTeamColorTag(client, buffer, maxlen);
        return;
    }

    char colorTag[16];
    BuildTeamColorTag(client, colorTag, sizeof(colorTag));
    Format(buffer, maxlen, "%s%N{default}", colorTag, client);
}

static void ResolveTeamColorTag(int client, char[] buffer, int maxlen)
{
    if (StrContains(buffer, "{teamcolor}", false) == -1)
    {
        return;
    }

    char colorTag[16];
    BuildTeamColorTag(client, colorTag, sizeof(colorTag));
    ReplaceString(buffer, maxlen, "{teamcolor}", colorTag, false);
}

static void BuildTeamColorTag(int client, char[] colorTag, int length)
{
    switch (GetClientTeam(client))
    {
        case 2: strcopy(colorTag, length, "{red}");
        case 3: strcopy(colorTag, length, "{blue}");
        default: strcopy(colorTag, length, "{default}");
    }
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
    int points = GetNativeCell(2);
    bool playSound = (numParams >= 3) ? view_as<bool>(GetNativeCell(3)) : true;
    bool chatAlert = (numParams >= 4) ? view_as<bool>(GetNativeCell(4)) : true;
    float randomChance = (numParams >= 5) ? view_as<float>(GetNativeCell(5)) : 1.0;

    char type[64];
    type[0] = '\0';
    if (numParams >= 6)
    {
        GetNativeString(6, type, sizeof(type));
        TrimString(type);
    }

    if (points < 0 && type[0] == '\0')
    {
        BuildCallerSpendType(plugin, type, sizeof(type));
    }

    int target = (numParams >= 7) ? GetNativeCell(7) : 0;
    float delay = (numParams >= 8) ? view_as<float>(GetNativeCell(8)) : 3.0;
    int perMap = (numParams >= 9) ? GetNativeCell(9) : 0;
    return ApplyBonusPoints(client, points, playSound, chatAlert, randomChance, type, target, delay, perMap);
}

public any Native_PointsStore_ApplyBonusPointsSteamId(Handle plugin, int numParams)
{
    char steamId[32];
    GetNativeString(1, steamId, sizeof(steamId));
    TrimString(steamId);

    int points = GetNativeCell(2);
    bool playSound = (numParams >= 3) ? view_as<bool>(GetNativeCell(3)) : true;
    bool chatAlert = (numParams >= 4) ? view_as<bool>(GetNativeCell(4)) : true;

    char type[64];
    type[0] = '\0';
    if (numParams >= 5)
    {
        GetNativeString(5, type, sizeof(type));
        TrimString(type);
    }

    int perMap = (numParams >= 6) ? GetNativeCell(6) : 0;
    return ApplyBonusPointsSteamId(steamId, points, playSound, chatAlert, type, perMap);
}

public any Native_PointsStore_SpendBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int points = GetNativeCell(2);
    char type[64];
    BuildCallerSpendType(plugin, type, sizeof(type));
    return SpendBonusPointsWithContext(client, points, type);
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
