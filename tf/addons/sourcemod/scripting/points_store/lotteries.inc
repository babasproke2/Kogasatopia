#if defined _points_store_lotteries_included
    #endinput
#endif
#define _points_store_lotteries_included

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
#define LOTTO_TICKET_WRITE_TIMEOUT 15.0
#define LOTTO_TICKET_MUTATION_COOLDOWN 2.0
#define LOTTO_MAP_CHANGE_DELAY 120.0

ConVar g_CvarLotteryDisabled = null;
ConVar g_CvarLotteryMaxTicketValue = null;
ConVar g_CvarLotteryEqualTicketValue = null;

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
bool g_CurrentLotterySuper = false;
bool g_CurrentLotteryEqual = false;
bool g_LotteryEqualRefundInProgress = false;

bool g_LotteryWaitingCustom[MAXPLAYERS + 1];
bool g_ClientLotteryTicketLoaded[MAXPLAYERS + 1];
bool g_ClientLotteryHasTicket[MAXPLAYERS + 1];
int g_ClientLotteryId[MAXPLAYERS + 1];
int g_ClientLotteryTicketValue[MAXPLAYERS + 1];
char g_ClientLotteryTicket[MAXPLAYERS + 1][LOTTO_TICKET_MAX];
float g_NextLotteryTicketMutationAt[MAXPLAYERS + 1];

Handle g_LotteryDrawTimer = null;
Handle g_LotteryCallTimer = null;
int g_LotteryCallRequesterUserId = 0;
int g_LotteryCallLotteryId = 0;
int g_LotteryMapChangeLotteryId = 0;
int g_LotteryDrawIndex = 0;
int g_LotteryDrawLotteryId = 0;
int g_LotteryDrawPrizePool = 0;
int g_LotteryDrawWinnerPrize = 0;
int g_LotteryDrawWelfarePoolPrize = 0;
int g_LotteryDrawWinnerTicketValue = 0;
char g_LotteryDrawWinnerSteamId[32];
char g_LotteryDrawWinnerName[LOTTO_NAME_MAX];
int g_LotteryDrawExtraWinnerCount = 0;
int g_LotteryDrawExtraWinnerPrizes[MAXPLAYERS + 1];
int g_LotteryDrawExtraWinnerTicketValues[MAXPLAYERS + 1];
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

void Lotteries_OnPluginStart()
{
    g_LotteryPendingSteamIds = new StringMap();
    g_LotteryWords = new ArrayList(ByteCountToCells(LOTTO_WORD_MAX));
    g_LotteryRarities = new ArrayList();
    g_LotteryDrawTokens = new ArrayList(ByteCountToCells(LOTTO_TOKEN_MAX));

    for (int client = 1; client <= MaxClients; client++)
    {
        ClearClientLotteryTicketCache(client);
        g_NextLotteryTicketMutationAt[client] = 0.0;
    }

    g_CvarLotteryDisabled = CreateConVar("sm_points_store_lottery_disabled", "0", "Disable lottery ticket commands and lottery draws on this server.", _, true, 0.0, true, 1.0);
    g_CvarLotteryMaxTicketValue = CreateConVar("sm_points_store_lottery_max_ticket_value", "1000", "Maximum lottery ticket value. Bets above this are capped. 0 disables the cap.", _, true, 0.0);
    g_CvarLotteryEqualTicketValue = CreateConVar("sm_points_store_lottery_equal_ticket_value", "100", "Required ticket value during an Equal Lottery.", _, true, 1.0);
    g_CvarLotteryDisabled.AddChangeHook(OnLotteryDisabledConVarChanged);
    g_CvarLotteryEqualTicketValue.AddChangeHook(OnLotteryEqualTicketValueChanged);

    RegConsoleCmd("sm_lottery", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_gamble", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_bet", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_lotto", Command_Lottery, "Open the currency lottery.");
    RegConsoleCmd("sm_allin", Command_LotteryAll, "Bet all available currency on the lottery.");
    AddCommandListener(CommandListener_LotteryAllAlias, "allin");
    AddCommandListener(CommandListener_LotteryAllChatAlias, "say");
    AddCommandListener(CommandListener_LotteryAllChatAlias, "say_team");
    RegConsoleCmd("sm_lottos", Command_LotteryHistory, "Show recent lottery history.");
    RegConsoleCmd("sm_lottohistory", Command_LotteryHistory, "Show recent lottery history.");
    RegConsoleCmd("sm_lottowhen", Command_LotteryTime, "Show time until the next lottery draw.");
    RegConsoleCmd("sm_when", Command_LotteryTime, "Show time until the next lottery draw.");
    RegConsoleCmd("sm_lottotime", Command_LotteryTime, "Show time until the next lottery draw.");
    RegConsoleCmd("sm_time", Command_LotteryTime, "Show time until the next lottery draw.");
    RegConsoleCmd("sm_pool", Command_LotteryPrizePool, "Show the lottery prize pool.");
    RegConsoleCmd("sm_prizepool", Command_LotteryPrizePool, "Show the lottery prize pool.");
    AddCommandListener(CommandListener_LotteryPoolAlias, "pool");
    RegConsoleCmd("sm_ticket", Command_ViewLotteryTicket, "View your current lottery ticket.");
    RegConsoleCmd("sm_viewticket", Command_ViewLotteryTicket, "View your current lottery ticket.");
    RegConsoleCmd("sm_lottorefund", Command_LotteryRefund, "Refund your current lottery ticket.");
    RegConsoleCmd("sm_lotteryrefund", Command_LotteryRefund, "Refund your current lottery ticket.");
    RegConsoleCmd("sm_refund", Command_LotteryRefund, "Refund your current lottery ticket.");
    AddCommandListener(CommandListener_LotteryRefundAlias, "refund");
    RegAdminCmd("sm_dolottery", Command_DoLottery, ADMFLAG_GENERIC, "Draw the current currency lottery.");
    RegAdminCmd("sm_dolotto", Command_DoLottery, ADMFLAG_GENERIC, "Draw the current currency lottery.");

    LoadLotteryWords();
}

void Lotteries_OnPluginEnd()
{
    delete g_LotteryPendingSteamIds;
    delete g_LotteryWords;
    delete g_LotteryRarities;
    delete g_LotteryDrawTokens;

    if (g_LotteryDrawTimer != null)
    {
        KillTimer(g_LotteryDrawTimer);
        g_LotteryDrawTimer = null;
    }
    CancelPendingLotteryCall();
}

void Lotteries_OnMapEnd()
{
    int interruptedLotteryId = 0;
    if (g_LotteryCallTimer != null)
    {
        interruptedLotteryId = g_LotteryCallLotteryId;
    }

    CancelPendingLotteryCall();

    if (interruptedLotteryId > 0)
    {
        g_LotteryMapChangeLotteryId = interruptedLotteryId;
    }
}

void Lotteries_OnMapStart()
{
    if (g_LotteryMapChangeLotteryId <= 0 || g_LotteryCallTimer != null
        || g_LotteryDrawInProgress)
    {
        return;
    }

    g_LotteryCallRequesterUserId = 0;
    g_LotteryCallLotteryId = g_LotteryMapChangeLotteryId;
    g_LotteryMapChangeLotteryId = 0;
    g_LotteryCallTimer = CreateTimer(
        LOTTO_MAP_CHANGE_DELAY,
        Timer_LotteryCall,
        _,
        TIMER_FLAG_NO_MAPCHANGE);

    if (g_LotteryCallTimer == null)
    {
        LogError("[points_store] Could not reschedule lottery %d after a map change.", g_LotteryCallLotteryId);
        g_LotteryCallLotteryId = 0;
    }
}

void Lotteries_OnClientAuthorized(int client)
{
    g_NextLotteryTicketMutationAt[client] = 0.0;
    LoadClientLotteryTicket(client);
}

void Lotteries_OnClientDisconnect(int client)
{
    g_LotteryWaitingCustom[client] = false;
    g_NextLotteryTicketMutationAt[client] = 0.0;
    ClearClientLotteryTicketCache(client);
}

void Lotteries_OnDatabaseDisconnected()
{
    g_LotteryReady = false;
    g_LotteryCreating = false;
    g_CurrentLotteryId = 0;
    g_CurrentLotteryHash[0] = '\0';
    g_CurrentLotteryHashColor[0] = '\0';
    g_CurrentLotterySuper = false;
    g_CurrentLotteryEqual = false;
    g_LotteryEqualRefundInProgress = false;
    CancelPendingLotteryCall();
}

void Lotteries_OnDatabaseReady()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientAuthorizedHuman(client))
        {
            LoadClientLotteryTicket(client);
        }
    }
    EnsureActiveLottery();
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
            ... "super_lottery TINYINT NOT NULL DEFAULT 0, "
            ... "equal_lottery TINYINT NOT NULL DEFAULT 0, "
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
            ... "super_lottery INTEGER NOT NULL DEFAULT 0, "
            ... "equal_lottery INTEGER NOT NULL DEFAULT 0, "
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

    char query[256];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS super_lottery TINYINT NOT NULL DEFAULT 0 AFTER created_at",
            LOTTO_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN super_lottery INTEGER NOT NULL DEFAULT 0",
            LOTTO_TABLE);
    }

    g_Database.Query(SQL_OnLotterySuperColumnReady, query);
}

public void SQL_OnLotterySuperColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "Duplicate column", false) == -1
        && StrContains(error, "duplicate column", false) == -1)
    {
        LogError("[points_store] Lottery super_lottery migration failed: %s", error);
    }

    char query[256];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS equal_lottery TINYINT NOT NULL DEFAULT 0 AFTER super_lottery",
            LOTTO_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN equal_lottery INTEGER NOT NULL DEFAULT 0",
            LOTTO_TABLE);
    }

    g_Database.Query(SQL_OnLotteryEqualColumnReady, query);
}

public void SQL_OnLotteryEqualColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "Duplicate column", false) == -1
        && StrContains(error, "duplicate column", false) == -1
        && StrContains(error, "already exists", false) == -1)
    {
        LogError("[points_store] Lottery equal_lottery migration failed: %s", error);
    }

    EnsureLotteryTicketsSchema();
}

void EnsureLotteryTicketsSchema()
{
    if (g_Database == null)
    {
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

bool IsLotteryEnabled()
{
    return g_CvarLotteryDisabled == null || !g_CvarLotteryDisabled.BoolValue;
}

int GetLotteryMaxTicketValue()
{
    if (g_CvarLotteryMaxTicketValue == null)
    {
        return 1000;
    }

    return g_CvarLotteryMaxTicketValue.IntValue;
}

int GetLotteryEqualTicketValue()
{
    if (g_CvarLotteryEqualTicketValue == null)
    {
        return 100;
    }

    return g_CvarLotteryEqualTicketValue.IntValue;
}

int ClampLotteryTicketValue(int client, int amount)
{
    if (g_CurrentLotterySuper || g_CurrentLotteryEqual)
    {
        return amount;
    }

    int maxTicketValue = GetLotteryMaxTicketValue();
    if (maxTicketValue <= 0 || amount <= maxTicketValue)
    {
        return amount;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    CPrintToChat(client, "%s[Lottery]{default} Ticket value capped at %s%d %s{default}.", colorTag, colorTag, maxTicketValue, currencyLong);
    return maxTicketValue;
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
    g_CurrentLotterySuper = false;
    g_CurrentLotteryEqual = false;
    g_LotteryEqualRefundInProgress = false;
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
        "SELECT id, hash, hash_color, super_lottery, equal_lottery FROM %s WHERE finished = 0 ORDER BY id DESC LIMIT 1",
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
        bool superLottery = results.FetchInt(3) != 0;
        bool equalLottery = results.FetchInt(4) != 0;
        SetActiveLottery(lotteryId, hash, hashColor, superLottery, equalLottery);
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

    SetActiveLottery(results.FetchInt(0), hash, hashColor, false, false);
}

void SetActiveLottery(
    int lotteryId,
    const char[] hash,
    const char[] hashColor,
    bool superLottery,
    bool equalLottery)
{
    g_CurrentLotteryId = lotteryId;
    strcopy(g_CurrentLotteryHash, sizeof(g_CurrentLotteryHash), hash);
    strcopy(g_CurrentLotteryHashColor, sizeof(g_CurrentLotteryHashColor), hashColor);
    g_CurrentLotterySuper = superLottery;
    g_CurrentLotteryEqual = equalLottery && !superLottery;
    g_LotteryReady = true;

    if (g_CurrentLotteryEqual)
    {
        BeginEqualLotteryRefunds();
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientLotteryTicket(i);
        }
    }
}

void SetCurrentLotterySuper(bool superLottery)
{
    g_CurrentLotterySuper = superLottery;
    if (superLottery)
    {
        g_CurrentLotteryEqual = false;
    }

    if (!superLottery || !g_DatabaseReady || g_Database == null || g_CurrentLotteryId <= 0)
    {
        return;
    }

    char query[192];
    Format(query, sizeof(query),
        "UPDATE %s SET super_lottery = 1, equal_lottery = 0 WHERE id = %d AND finished = 0",
        LOTTO_TABLE,
        g_CurrentLotteryId);
    g_Database.Query(SQL_OnIgnoredResult, query);
}

void SetCurrentLotteryEqual(bool equalLottery)
{
    g_CurrentLotteryEqual = equalLottery;
    if (equalLottery)
    {
        g_CurrentLotterySuper = false;
    }

    if (!equalLottery || !g_DatabaseReady || g_Database == null || g_CurrentLotteryId <= 0)
    {
        return;
    }

    char query[192];
    Format(query, sizeof(query),
        "UPDATE %s SET super_lottery = 0, equal_lottery = 1 WHERE id = %d AND finished = 0",
        LOTTO_TABLE,
        g_CurrentLotteryId);
    g_Database.Query(SQL_OnIgnoredResult, query);
    BeginEqualLotteryRefunds();
}

void BeginEqualLotteryRefunds()
{
    if (!g_CurrentLotteryEqual || g_LotteryEqualRefundInProgress
        || !g_DatabaseReady || g_Database == null || g_CurrentLotteryId <= 0)
    {
        return;
    }

    g_LotteryEqualRefundInProgress = true;
    ContinueEqualLotteryRefunds(g_CurrentLotteryId);
}

void ContinueEqualLotteryRefunds(int lotteryId)
{
    if (!g_CurrentLotteryEqual || lotteryId != g_CurrentLotteryId
        || !g_DatabaseReady || g_Database == null)
    {
        g_LotteryEqualRefundInProgress = false;
        return;
    }

    if (g_LotteryPendingTicketWrites > 0)
    {
        CreateTimer(0.5, Timer_RetryEqualLotteryRefunds, lotteryId, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    int requiredValue = GetLotteryEqualTicketValue();
    DataPack pack = new DataPack();
    pack.WriteCell(lotteryId);
    pack.WriteCell(requiredValue);

    char query[384];
    FormatEx(query, sizeof(query),
        "SELECT steamid64, ticket_value FROM %s "
        ... "WHERE lottery_id = %d AND ticket_value != %d",
        LOTTO_TICKET_TABLE,
        lotteryId,
        requiredValue);
    g_Database.Query(SQL_OnEqualLotteryInvalidTicketsLoaded, query, pack);
}

public Action Timer_RetryEqualLotteryRefunds(Handle timer, any lotteryId)
{
    if (!g_CurrentLotteryEqual || lotteryId != g_CurrentLotteryId)
    {
        return Plugin_Stop;
    }

    g_LotteryEqualRefundInProgress = true;
    ContinueEqualLotteryRefunds(lotteryId);
    return Plugin_Stop;
}

public void SQL_OnEqualLotteryInvalidTicketsLoaded(
    Database db,
    DBResultSet rows,
    const char[] error,
    any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int lotteryId = pack.ReadCell();
    int requiredValue = pack.ReadCell();
    delete pack;

    if (!g_CurrentLotteryEqual || lotteryId != g_CurrentLotteryId)
    {
        g_LotteryEqualRefundInProgress = false;
        return;
    }
    if (error[0] != '\0')
    {
        g_LotteryEqualRefundInProgress = false;
        LogError("[points_store] Failed to load invalid Equal Lottery tickets: %s", error);
        CreateTimer(1.0, Timer_RetryEqualLotteryRefunds, lotteryId, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    ArrayList steamIds = new ArrayList(ByteCountToCells(32));
    ArrayList amounts = new ArrayList();
    char steamId[32];
    while (rows != null && rows.FetchRow())
    {
        rows.FetchString(0, steamId, sizeof(steamId));
        steamIds.PushString(steamId);
        amounts.Push(rows.FetchInt(1));
    }

    if (steamIds.Length == 0)
    {
        delete steamIds;
        delete amounts;
        g_LotteryEqualRefundInProgress = false;
        ReloadAllClientLotteryTickets();
        if (requiredValue != GetLotteryEqualTicketValue())
        {
            BeginEqualLotteryRefunds();
        }
        return;
    }

    Transaction txn = new Transaction();
    char query[1024];
    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT steamid64, ticket_value FROM %s WHERE lottery_id = %d AND ticket_value != %d "
            ... "ON DUPLICATE KEY UPDATE balance = GREATEST(0, balance + VALUES(balance))",
            BP_BALANCE_TABLE,
            LOTTO_TICKET_TABLE,
            lotteryId,
            requiredValue);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT steamid64, ticket_value FROM %s WHERE lottery_id = %d AND ticket_value != %d "
            ... "ON CONFLICT(steamid64) DO UPDATE SET balance = MAX(0, balance + excluded.balance), updated_at = CURRENT_TIMESTAMP",
            BP_BALANCE_TABLE,
            LOTTO_TICKET_TABLE,
            lotteryId,
            requiredValue);
    }
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM %s WHERE lottery_id = %d AND ticket_value != %d",
        LOTTO_TICKET_TABLE,
        lotteryId,
        requiredValue);
    txn.AddQuery(query);

    DataPack txnPack = new DataPack();
    txnPack.WriteCell(lotteryId);
    txnPack.WriteCell(requiredValue);
    txnPack.WriteCell(view_as<int>(steamIds));
    txnPack.WriteCell(view_as<int>(amounts));
    g_Database.Execute(
        txn,
        SQLTxn_OnEqualLotteryTicketsRefunded,
        SQLTxn_OnEqualLotteryTicketsRefundFailure,
        txnPack);
}

public void SQLTxn_OnEqualLotteryTicketsRefunded(
    Database db,
    any data,
    int numQueries,
    DBResultSet[] results,
    any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int lotteryId = pack.ReadCell();
    int requiredValue = pack.ReadCell();
    ArrayList steamIds = view_as<ArrayList>(pack.ReadCell());
    ArrayList amounts = view_as<ArrayList>(pack.ReadCell());
    delete pack;

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    char steamId[32];
    for (int i = 0; i < steamIds.Length; i++)
    {
        steamIds.GetString(i, steamId, sizeof(steamId));
        int amount = amounts.Get(i);
        int client = Kogasa_FindClientBySteamId64(steamId);
        int balanceAfter = -1;
        if (IsClientAuthorizedHuman(client))
        {
            if (g_ClientBonusPointsLoaded[client])
            {
                g_ClientBonusPoints[client] += amount;
                balanceAfter = g_ClientBonusPoints[client];
            }
            else
            {
                LoadClientBonusPoints(client);
            }

            ClearClientLotteryTicketCache(client);
            g_ClientLotteryTicketLoaded[client] = true;

            CPrintToChat(client,
                "%s[Lottery]{default} An {gold}Equal Value Lottery{default} is coming; your ticket has been refunded! Bet again with a value of {gold}%d{default} to get a ticket.",
                colorTag,
                requiredValue);
        }
        LogLotteryCreditEvent("lottery_equal_refund", steamId, amount, lotteryId, client, balanceAfter);
    }

    delete steamIds;
    delete amounts;
    g_LotteryEqualRefundInProgress = false;
    ReloadAllClientLotteryTickets();
    if (g_CurrentLotteryEqual && lotteryId == g_CurrentLotteryId
        && requiredValue != GetLotteryEqualTicketValue())
    {
        BeginEqualLotteryRefunds();
    }
}

public void SQLTxn_OnEqualLotteryTicketsRefundFailure(
    Database db,
    any data,
    int numQueries,
    const char[] error,
    int failIndex,
    any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int lotteryId = pack.ReadCell();
    pack.ReadCell();
    ArrayList steamIds = view_as<ArrayList>(pack.ReadCell());
    ArrayList amounts = view_as<ArrayList>(pack.ReadCell());
    delete pack;
    delete steamIds;
    delete amounts;

    g_LotteryEqualRefundInProgress = false;
    LogError("[points_store] Equal Lottery refund transaction failed at query %d: %s", failIndex, error);
    if (g_CurrentLotteryEqual && lotteryId == g_CurrentLotteryId)
    {
        CreateTimer(1.0, Timer_RetryEqualLotteryRefunds, lotteryId, TIMER_FLAG_NO_MAPCHANGE);
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

void ReloadAllClientLotteryTickets()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientLotteryTicket(i);
        }
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

        DataPack pack = new DataPack();
        pack.WriteString(steamId);
        CreateTimer(LOTTO_TICKET_WRITE_TIMEOUT, Timer_LotteryTicketWriteTimeout, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
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

public Action Timer_LotteryTicketWriteTimeout(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));

    if (IsLotteryTicketWritePending(steamId))
    {
        LogError("[points_store] Lottery ticket write for %s timed out; clearing pending guard.", steamId);
        FinishLotteryTicketWrite(steamId);
    }

    return Plugin_Stop;
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

    if (needTicketLoaded && g_LotteryEqualRefundInProgress)
    {
        CPrintToChat(client, "%s[Lotto]{default} Equal Lottery tickets are being updated. Try again in a moment.", colorTag);
        return false;
    }

    if (needTicketLoaded
        && (!g_ClientLotteryTicketLoaded[client] || g_ClientLotteryId[client] != g_CurrentLotteryId))
    {
        LoadClientLotteryTicket(client);
        CPrintToChat(client, "%s[Lotto]{default} Your lottery ticket is loading. Try again in a moment.", colorTag);
        return false;
    }

    return true;
}

bool CanStartLotteryTicketMutation(int client)
{
    float remaining = g_NextLotteryTicketMutationAt[client] - GetEngineTime();
    if (remaining <= 0.0)
    {
        return true;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    CPrintToChat(
        client,
        "%s[Lottery]{default} Wait {gold}%d seconds{default} before buying, refunding, or changing a ticket.",
        colorTag,
        RoundToCeil(remaining));
    return false;
}

void StartLotteryTicketMutationCooldown(int client)
{
    g_NextLotteryTicketMutationAt[client] = GetEngineTime() + LOTTO_TICKET_MUTATION_COOLDOWN;
}

public Action Command_Lottery(int client, int args)
{
    if (!Client_IsHumanInGame(client))
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

public Action Command_LotteryAll(int client, int args)
{
    if (!Client_IsHumanInGame(client) || !IsLotteryReadyForClient(client))
    {
        return Plugin_Handled;
    }

    AttemptLotteryAllTicketPurchase(client);
    return Plugin_Handled;
}

public Action CommandListener_LotteryAllAlias(int client, const char[] command, int argc)
{
    return Command_LotteryAll(client, 0);
}

public Action CommandListener_LotteryAllChatAlias(int client, const char[] command, int argc)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Continue;
    }

    char text[32];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);
    if (!StrEqual(text, "allin", false))
    {
        return Plugin_Continue;
    }

    return Command_LotteryAll(client, 0);
}

public Action Command_LotteryRefund(int client, int args)
{
    if (!Client_IsHumanInGame(client))
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

public Action CommandListener_LotteryRefundAlias(int client, const char[] command, int argc)
{
    return Command_LotteryRefund(client, 0);
}

public Action Command_LotteryTime(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    PrintLotteryTime(client, true);
    return Plugin_Handled;
}

void PrintLotteryTime(int client, bool includePrefix)
{
    int secondsUntilLottery = SecondsUntilNextLotteryDraw(GetTime());
    int minutesUntilLottery = (secondsUntilLottery + 59) / 60;
    char minuteLabel[16];
    strcopy(minuteLabel, sizeof(minuteLabel), minutesUntilLottery == 1 ? "minute" : "minutes");

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (includePrefix)
    {
        CPrintToChat(client, "%s[Lotto]{default} Time until the lottery: {gold}%d %s", colorTag, minutesUntilLottery, minuteLabel);
    }
    else
    {
        CPrintToChat(client, "{default}Time until the lottery: {gold}%d %s", minutesUntilLottery, minuteLabel);
    }

}

int SecondsUntilNextLotteryDraw(int timestamp)
{
    static int drawSeconds[] = {60, 960, 1860, 2760};
    int elapsedThisHour = timestamp % 3600;

    for (int i = 0; i < sizeof(drawSeconds); i++)
    {
        if (elapsedThisHour <= drawSeconds[i])
        {
            return drawSeconds[i] - elapsedThisHour;
        }
    }

    return 3660 - elapsedThisHour;
}

public Action Command_LotteryPrizePool(int client, int args)
{
    if (!Client_IsHumanInGame(client))
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

public Action CommandListener_LotteryPoolAlias(int client, const char[] command, int argc)
{
    return Command_LotteryPrizePool(client, 0);
}

public Action Command_LotteryHistory(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }

    if (!g_DatabaseReady || g_Database == null)
    {
        char colorTag[BP_CURRENCY_COLOR_MAX + 2];
        GetCurrencyColorTag(colorTag, sizeof(colorTag));
        CPrintToChat(client, "%s[Lotto]{default} The lottery database is not ready.", colorTag);
        ConnectDatabase();
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));

    char query[512];
    Format(query, sizeof(query),
        "SELECT l.id, l.hash, l.finished_at, l.winner_name, l.prize_pool, COALESCE(t.ticket_value, 0) FROM %s l LEFT JOIN %s t ON t.lottery_id = l.id AND t.steamid64 = l.winner_steamid64 WHERE l.finished = 1 ORDER BY l.finished_at DESC, l.id DESC LIMIT 25",
        LOTTO_TABLE,
        LOTTO_TICKET_TABLE);
    g_Database.Query(SQL_OnLotteryHistoryLoaded, query, pack);
    return Plugin_Handled;
}

public void SQL_OnLotteryHistoryLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!Client_IsHumanInGame(client))
    {
        return;
    }

    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    if (error[0] != '\0')
    {
        CPrintToChat(client, "%s[Lotto]{default} Could not load lottery history.", colorTag);
        LogError("[points_store] Failed to load lottery history: %s", error);
        return;
    }

    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));

    Menu menu = new Menu(MenuHandler_LotteryHistory);
    menu.SetTitle("Recent Lottos");

    int count = 0;
    if (results != null)
    {
        while (results.FetchRow())
        {
            int lotteryId = results.FetchInt(0);
            char hash[LOTTO_HASH_MAX];
            char shortHash[LOTTO_SHORT_HASH_MAX];
            char winnerName[LOTTO_NAME_MAX];
            char cleanWinnerName[LOTTO_NAME_MAX];
            char finishedAt[32];
            char info[16];
            char display[192];

            results.FetchString(1, hash, sizeof(hash));
            int finishedTimestamp = results.FetchInt(2);
            results.FetchString(3, winnerName, sizeof(winnerName));
            int prizePool = results.FetchInt(4);
            int investment = results.FetchInt(5);
            char profit[24];
            FormatLotteryHistoryProfit(profit, sizeof(profit), prizePool, investment);

            GetLotteryShortHash(hash, shortHash, sizeof(shortHash));
            StripMenuColorTags(winnerName, cleanWinnerName, sizeof(cleanWinnerName));
            if (cleanWinnerName[0] == '\0')
            {
                strcopy(cleanWinnerName, sizeof(cleanWinnerName), "Unknown");
            }
            FormatTime(finishedAt, sizeof(finishedAt), "%m/%d %H:%M", finishedTimestamp);
            IntToString(lotteryId, info, sizeof(info));
            Format(display, sizeof(display), "#%d %s %s - %s - %d %s%s", lotteryId, shortHash, finishedAt, cleanWinnerName, prizePool, currencyLong, profit);
            menu.AddItem(info, display, ITEMDRAW_DISABLED);
            count++;
        }
    }

    if (count == 0)
    {
        menu.AddItem("none", "No finished lottos found.", ITEMDRAW_DISABLED);
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

void FormatLotteryHistoryProfit(char[] buffer, int maxlen, int payout, int investment)
{
    buffer[0] = '\0';
    if (investment <= 0)
    {
        return;
    }

    int percent = RoundToNearest((float(payout - investment) / float(investment)) * 100.0);
    Format(buffer, maxlen, percent >= 0 ? " +%d%%" : " %d%%", percent);
}

public int MenuHandler_LotteryHistory(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void StripMenuColorTags(const char[] input, char[] output, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    int out = 0;
    bool inTag = false;
    int len = strlen(input);
    for (int i = 0; i < len && out < maxlen - 1; i++)
    {
        int colorCodeLength = 0;
        if (input[i] == '\x07')
        {
            colorCodeLength = 6;
        }
        else if (input[i] == '\x08')
        {
            colorCodeLength = 8;
        }

        if (colorCodeLength > 0)
        {
            bool hasCompleteColor = i + colorCodeLength < len;
            for (int offset = 1; hasCompleteColor && offset <= colorCodeLength; offset++)
            {
                char character = input[i + offset];
                hasCompleteColor = (character >= '0' && character <= '9')
                    || (character >= 'A' && character <= 'F')
                    || (character >= 'a' && character <= 'f');
            }

            if (hasCompleteColor)
            {
                i += colorCodeLength;
            }
            continue;
        }

        if (input[i] >= '\x01' && input[i] <= '\x06')
        {
            continue;
        }

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
    TrimString(output);
}

public Action Command_ViewLotteryTicket(int client, int args)
{
    if (!Client_IsHumanInGame(client))
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
    if (g_CurrentLotteryEqual)
    {
        return amount == GetLotteryEqualTicketValue() ? 1 : 0;
    }

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
    if (g_CurrentLotteryEqual)
    {
        int requiredValue = GetLotteryEqualTicketValue();
        char info[16];
        IntToString(requiredValue, info, sizeof(info));
        Format(display, sizeof(display), "%d %s", requiredValue, currencyLong);
        menu.AddItem(info, display);
        menu.AddItem("pool", "Prize pool");
        menu.Display(client, MENU_TIME_FOREVER);
        return;
    }

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

    if (action != MenuAction_Select || !Client_IsHumanInGame(client))
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

    if (action != MenuAction_Select || !Client_IsHumanInGame(client))
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
    if (g_CurrentLotteryEqual)
    {
        CPrintToChat(client,
            "%s[Lottery]{default} Equal Lottery tickets must have a value of {gold}%d{default}.",
            colorTag,
            GetLotteryEqualTicketValue());
        return;
    }

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
    int ticketValue = g_CurrentLotteryEqual
        ? GetLotteryEqualTicketValue()
        : g_ClientLotteryTicketValue[client];
    BuildLotteryTicketDisplay(g_ClientLotteryTicket[client], display, sizeof(display));
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    CPrintToChat(client, "%s[Lottery]{default} Your ticket: %s\n{gold}Value:{default} %s%d %s{default}", colorTag, display, colorTag, ticketValue, currencyLong);
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

    if (g_CurrentLotteryEqual)
    {
        AttemptLotteryTicketPurchase(client, GetLotteryEqualTicketValue());
        return;
    }

    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s[Lottery]{default} Your %s are loading. Try again in a moment.", colorTag, currencyLong);
        return;
    }

    int available = GetCachedBonusPoints(client);
    if (g_ClientLotteryHasTicket[client])
    {
        available += g_ClientLotteryTicketValue[client];
    }

    AttemptLotteryTicketPurchase(client, available);
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

    if (g_CurrentLotteryEqual && amount != GetLotteryEqualTicketValue())
    {
        CPrintToChat(client,
            "%s[Lottery]{default} Equal Lottery tickets must have a value of {gold}%d{default}.",
            colorTag,
            GetLotteryEqualTicketValue());
        return;
    }

    amount = ClampLotteryTicketValue(client, amount);

    if (!g_CurrentLotteryEqual)
    {
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

    if (!CanStartLotteryTicketMutation(client))
    {
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

    StartLotteryTicketMutationCooldown(client);

    int createdAt = GetTime();

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
        createdAt);
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
    if (amount == oldAmount)
    {
        CPrintToChat(client, "%s[Lottery]{default} Your current ticket is equal to {gold}%d", colorTag, amount);
        return;
    }

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

    if (!CanStartLotteryTicketMutation(client))
    {
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
    StartLotteryTicketMutationCooldown(client);
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
        if (Client_IsHumanInGame(client))
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
    if (Client_IsHumanInGame(client))
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
        if (Client_IsHumanInGame(client))
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

    if (!CanStartLotteryTicketMutation(client))
    {
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
    StartLotteryTicketMutationCooldown(client);
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
        if (Client_IsHumanInGame(client))
        {
            CPrintToChat(client, "%s[Lottery]{default} Could not refund your ticket.", colorTag);
        }
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LogError("[points_store] Lottery refund skipped for %s because the cached ticket was stale.", steamId);
        if (Client_IsHumanInGame(client))
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

    if (Client_IsHumanInGame(client))
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
    if (!Client_IsHumanInGame(client) || lotteryId != g_CurrentLotteryId)
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
    PrintLotteryTime(client, false);
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
    GetCurrencyColorTag(colorTag, sizeof(colorTag));
    int callDelay = GetRandomInt(20, 80);

    g_LotteryCallTimer = CreateTimer(float(callDelay), Timer_LotteryCall, _, TIMER_FLAG_NO_MAPCHANGE);
    if (g_LotteryCallTimer == null)
    {
        g_LotteryCallRequesterUserId = 0;
        g_LotteryCallLotteryId = 0;
        ReplyToCommand(client, "[Lotto] Could not schedule the lottery draw.");
        return Plugin_Handled;
    }

    int specialLotteryRoll = GetRandomInt(1, 100);
    if (g_CurrentLotterySuper || (!g_CurrentLotteryEqual && specialLotteryRoll <= 35))
    {
        SetCurrentLotterySuper(true);
        CPrintToChatAll("%s[Lotto]{default} A {gold}SUPER LOTTERY{default} is being called soon, {gold}!bet{default} no longer has a size limit!", colorTag);
    }
    else if (g_CurrentLotteryEqual || specialLotteryRoll <= 70)
    {
        SetCurrentLotteryEqual(true);
        CPrintToChatAll(
            "%s[Lotto]{default} An {gold}Equal Lottery{default} is being called soon, {gold}only tickets with a value of %d are accepted!",
            colorTag,
            GetLotteryEqualTicketValue());
    }
    else
    {
        CPrintToChatAll("%s[Lotto]{default} A lottery is being called soon, {gold}!bet{default} now!", colorTag);
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

    if (g_LotteryPendingTicketWrites > 0 || g_LotteryEqualRefundInProgress)
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
    ArrayList ticketValues = new ArrayList();
    ArrayList ticketChances = new ArrayList();
    ArrayList selectedWinners = new ArrayList();
    int totalChances = 0;

    while (results.FetchRow())
    {
        int ticketValue = results.FetchInt(3);
        int chanceCount = GetLotteryChanceCount(ticketValue);
        if (chanceCount <= 0)
        {
            continue;
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
        ticketValues.Push(ticketValue);
        ticketChances.Push(chanceCount);
        selectedWinners.Push(0);
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
        delete ticketValues;
        delete ticketChances;
        delete selectedWinners;
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
        delete ticketValues;
        delete ticketChances;
        delete selectedWinners;
        return;
    }

    selectedWinners.Set(mainWinnerIndex, 1);

    g_LotteryDrawExtraWinnerCount = validTicketCount / LOTTO_EXTRA_WINNER_PARTICIPANTS;
    if (g_LotteryDrawExtraWinnerCount > validTicketCount - 1)
    {
        g_LotteryDrawExtraWinnerCount = validTicketCount - 1;
    }
    if (g_LotteryDrawExtraWinnerCount > sizeof(g_LotteryDrawExtraWinnerPrizes))
    {
        g_LotteryDrawExtraWinnerCount = sizeof(g_LotteryDrawExtraWinnerPrizes);
    }

    int extraPrize = (prizePool * LOTTO_EXTRA_WINNER_PERCENT) / 100;
    if (extraPrize <= 0)
    {
        g_LotteryDrawExtraWinnerCount = 0;
    }

    int welfarePoolPrize = 0;

    char mainSteamId[32];
    char mainStoredName[LOTTO_NAME_MAX];
    char mainTicket[LOTTO_TICKET_MAX];
    steamIds.GetString(mainWinnerIndex, mainSteamId, sizeof(mainSteamId));
    storedNames.GetString(mainWinnerIndex, mainStoredName, sizeof(mainStoredName));
    tickets.GetString(mainWinnerIndex, mainTicket, sizeof(mainTicket));

    strcopy(g_LotteryDrawWinnerSteamId, sizeof(g_LotteryDrawWinnerSteamId), mainSteamId);
    g_LotteryDrawWinnerTicketValue = ticketValues.Get(mainWinnerIndex);
    ResolveLotteryWinnerName(mainSteamId, mainStoredName, g_LotteryDrawWinnerName, sizeof(g_LotteryDrawWinnerName));

    for (int i = 0; i < g_LotteryDrawExtraWinnerCount; i++)
    {
        int extraWinnerIndex = PickLotteryWinnerIndex(ticketChances, selectedWinners);
        if (extraWinnerIndex < 0)
        {
            g_LotteryDrawExtraWinnerCount = i;
            break;
        }

        selectedWinners.Set(extraWinnerIndex, 1);
        g_LotteryDrawExtraWinnerPrizes[i] = extraPrize;
        g_LotteryDrawExtraWinnerTicketValues[i] = ticketValues.Get(extraWinnerIndex);
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
    delete ticketValues;
    delete ticketChances;
    delete selectedWinners;

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

    // Reveals survive map changes so the already-selected winner is still paid.
    g_LotteryDrawTimer = CreateTimer(LOTTO_REVEAL_INTERVAL, Timer_LotteryReveal, _, TIMER_REPEAT);
}

int PickLotteryWinnerIndex(ArrayList ticketChances, ArrayList selectedWinners)
{
    int totalChances = 0;
    int ticketCount = ticketChances.Length;
    for (int i = 0; i < ticketCount; i++)
    {
        if (selectedWinners.Get(i) == 0)
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
        if (selectedWinners.Get(i) != 0)
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

void FormatLotteryPayoutDelta(char[] buffer, int maxlen, int payout, int investment)
{
    int delta = payout - investment;
    float percent = 0.0;
    if (investment > 0)
    {
        percent = (float(delta) / float(investment)) * 100.0;
    }

    if (delta >= 0)
    {
        Format(buffer, maxlen, "{green}(+%.2f%%)", percent);
    }
    else
    {
        Format(buffer, maxlen, "{red}(-%.2f%%)", -percent);
    }
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
        g_CurrentLotterySuper = false;
        g_CurrentLotteryEqual = false;
        g_LotteryEqualRefundInProgress = false;
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
    char winnerDelta[32];
    FormatLotteryPayoutDelta(winnerDelta, sizeof(winnerDelta), winnerPrize, g_LotteryDrawWinnerTicketValue);
    CPrintToChatAll("%s[Lotto]{default} %s won lottery %s%s{default} for %s%d %s{default} %s{default}!", colorTag, winnerName, hashColor, shortHash, colorTag, winnerPrize, currencyLong, winnerDelta);

    for (int i = 0; i < g_LotteryDrawExtraWinnerCount; i++)
    {
        char extraDelta[32];
        FormatLotteryPayoutDelta(extraDelta, sizeof(extraDelta), g_LotteryDrawExtraWinnerPrizes[i], g_LotteryDrawExtraWinnerTicketValues[i]);
        CPrintToChatAll("{default}%s won %s%d %s{default} %s{default}!", g_LotteryDrawExtraWinnerNames[i], colorTag, g_LotteryDrawExtraWinnerPrizes[i], currencyLong, extraDelta);
    }

    g_LotteryDrawInProgress = false;
    g_LotteryReady = false;
    g_CurrentLotteryId = 0;
    g_CurrentLotteryHash[0] = '\0';
    g_CurrentLotteryHashColor[0] = '\0';
    g_CurrentLotterySuper = false;
    g_CurrentLotteryEqual = false;
    g_LotteryEqualRefundInProgress = false;
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
    g_LotteryDrawWinnerTicketValue = 0;
    g_LotteryDrawWinnerSteamId[0] = '\0';
    g_LotteryDrawWinnerName[0] = '\0';
    g_LotteryDrawExtraWinnerCount = 0;
    for (int i = 0; i <= MaxClients; i++)
    {
        g_LotteryDrawExtraWinnerPrizes[i] = 0;
        g_LotteryDrawExtraWinnerTicketValues[i] = 0;
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
    int client = Kogasa_FindClientBySteamId64(steamId);
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

    int client = Kogasa_FindClientBySteamId64(steamId);
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

    if (Client_IsHumanInGame(client))
    {
        if (StrEqual(reason, "lottery_main_payout", false))
        {
            PlayLevelUpSound(client);
        }
        else if (StrEqual(reason, "lottery_extra_payout", false))
        {
            PlayBonusPointsSound(client, true);
        }
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

public void OnLotteryDisabledConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (IsLotteryEnabled())
    {
        EnsureActiveLottery();
        return;
    }

    ClearLocalLotteryState();
}

public void OnLotteryEqualTicketValueChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_CurrentLotteryEqual)
    {
        BeginEqualLotteryRefunds();
    }
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
