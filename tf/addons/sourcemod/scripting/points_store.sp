#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>
#undef REQUIRE_PLUGIN
#include <saysounds>
#define REQUIRE_PLUGIN
#include "include/dgm_api.inc"
#include "include/plugin_statistics.inc"

native bool Filters_GetChatName(int client, char[] buffer, int maxlen);

#define BP_TRANS_DB_CONFIG_DEFAULT "default"
#define BP_TRANS_TABLE "bonuspoints_transactions"
#define BP_BALANCE_TABLE "points_store_balances"
#define BP_TRANS_ITEM_KEY_MAX 64
#define BP_TRANS_ITEM_NAME_MAX 128
#define BP_SOUND_COMMAND "xp_gain"
#define BP_EVENT_LOG_LINE_MAX 1024
#define BP_CURRENCY_SHORT_MAX 32
#define BP_CURRENCY_LONG_MAX 64
#define BP_CURRENCY_COLOR_MAX 32
#define BP_PURCHASE_PERMANENT 0

ArrayList g_ItemKeys = null;
ArrayList g_ItemNames = null;
ArrayList g_ItemPrices = null;
ArrayList g_ItemDurations = null;

StringMap g_ClientPurchases[MAXPLAYERS + 1];
StringMap g_ClientPurchaseExpiresAt[MAXPLAYERS + 1];
bool g_ClientPurchasesLoaded[MAXPLAYERS + 1];
int g_ClientBonusPoints[MAXPLAYERS + 1];
bool g_ClientBonusPointsLoaded[MAXPLAYERS + 1];
bool g_ClientBonusPointsPending[MAXPLAYERS + 1];

Database g_Database = null;
ConVar g_CvarDatabase = null;
ConVar g_CvarEventLogging = null;
ConVar g_CvarLogRandomMisses = null;
ConVar g_CvarCurrencyShort = null;
ConVar g_CvarCurrencyLong = null;
ConVar g_CvarCurrencyColor = null;
ConVar g_CvarSendCooldown = null;
bool g_DatabaseReady = false;
bool g_IsMySql = false;
char g_CurrencyShortLabel[BP_CURRENCY_SHORT_MAX];
char g_CurrencyLongLabel[BP_CURRENCY_LONG_MAX];
char g_CurrencyColorTag[BP_CURRENCY_COLOR_MAX + 2];
char g_CurrencyPrefix[96];
float g_NextSendAllowedAt[MAXPLAYERS + 1];

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
    MarkNativeAsOptional("DGM_GetGameMode");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    RegPluginLibrary("points_store");
    CreateNative("PointsStore_AreBonusPointsLoaded", Native_PointsStore_AreBonusPointsLoaded);
    CreateNative("PointsStore_GetBonusPoints", Native_PointsStore_GetBonusPoints);
    CreateNative("PointsStore_ApplyBonusPoints", Native_PointsStore_ApplyBonusPoints);
    CreateNative("PointsStore_SpendBonusPoints", Native_PointsStore_SpendBonusPoints);
    CreateNative("PointsStore_HasPurchase", Native_PointsStore_HasPurchase);
    CreateNative("PointsStore_GetPurchasePrice", Native_PointsStore_GetPurchasePrice);
    CreateNative("PointsStore_GetPurchaseExpiresAt", Native_PointsStore_GetPurchaseExpiresAt);
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_ItemKeys = new ArrayList(ByteCountToCells(BP_TRANS_ITEM_KEY_MAX));
    g_ItemNames = new ArrayList(ByteCountToCells(BP_TRANS_ITEM_NAME_MAX));
    g_ItemPrices = new ArrayList();
    g_ItemDurations = new ArrayList();

    for (int i = 1; i <= MaxClients; i++)
    {
        g_ClientPurchases[i] = new StringMap();
        g_ClientPurchaseExpiresAt[i] = new StringMap();
        g_ClientPurchasesLoaded[i] = false;
        g_ClientBonusPoints[i] = 0;
        g_ClientBonusPointsLoaded[i] = false;
        g_ClientBonusPointsPending[i] = false;
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
    RegConsoleCmd("sm_send", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_sendbp", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_bpsend", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_gem", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_gems", Command_ShowBonusPoints, "Show your currency balance.");
    RegConsoleCmd("sm_sendgem", Command_SendBonusPoints, "Send currency to another player.");
    RegConsoleCmd("sm_gemsend", Command_SendBonusPoints, "Send currency to another player.");

    LoadStoreItems();
    ConnectDatabase();
}

public void OnPluginEnd()
{
    PluginStats_Flush();

    delete g_ItemKeys;
    delete g_ItemNames;
    delete g_ItemPrices;
    delete g_ItemDurations;

    for (int i = 1; i <= MaxClients; i++)
    {
        delete g_ClientPurchases[i];
        g_ClientPurchases[i] = null;
        delete g_ClientPurchaseExpiresAt[i];
        g_ClientPurchaseExpiresAt[i] = null;
    }

    delete g_Database;
    g_Database = null;
    PluginStats_Shutdown();
}

public void OnMapStart()
{
    PluginStats_OnMapStart();
}

public void OnMapEnd()
{
    PluginStats_Flush();
}

public void OnClientAuthorized(int client, const char[] auth)
{
    g_NextSendAllowedAt[client] = 0.0;
    ClearClientStoreCache(client);
    LoadClientPurchases(client);
    LoadClientBonusPoints(client);
}

public void OnClientDisconnect(int client)
{
    g_NextSendAllowedAt[client] = 0.0;
    ClearClientStoreCache(client);
}

void ConnectDatabase()
{
    g_DatabaseReady = false;
    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    char dbConfig[64];
    g_CvarDatabase.GetString(dbConfig, sizeof(dbConfig));
    TrimString(dbConfig);
    if (dbConfig[0] == '\0')
    {
        strcopy(dbConfig, sizeof(dbConfig), BP_TRANS_DB_CONFIG_DEFAULT);
    }

    if (!SQL_CheckConfig(dbConfig))
    {
        LogError("[bonuspoints_transactions] Database config '%s' not found.", dbConfig);
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, dbConfig);
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[bonuspoints_transactions] Database connection failed: %s", error[0] ? error : "unknown error");
        return;
    }

    g_Database = view_as<Database>(hndl);

    char driverIdent[32];
    DBDriver driver = g_Database.Driver;
    driver.GetIdentifier(driverIdent, sizeof(driverIdent));
    g_IsMySql = StrEqual(driverIdent, "mysql", false);

    EnsureSchema();
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

    if (!g_IsMySql)
    {
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_bonuspoints_transactions_steamid64 ON bonuspoints_transactions (steamid64)");
        g_Database.Query(SQL_OnIgnoredResult, "CREATE INDEX IF NOT EXISTS idx_bonuspoints_transactions_item_key ON bonuspoints_transactions (item_key)");
    }

    EnsureBalanceSchema();
}

bool IsDuplicateColumnError(const char[] error)
{
    return StrContains(error, "Duplicate column", false) != -1
        || StrContains(error, "duplicate column", false) != -1;
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

    g_DatabaseReady = true;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorizedHuman(i))
        {
            LoadClientPurchases(i);
            LoadClientBonusPoints(i);
        }
    }
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
    g_ItemPrices.Clear();
    g_ItemDurations.Clear();

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/points_store.cfg");

    KeyValues kv = new KeyValues("points_store");
    if (!FileToKeyValues(kv, configPath))
    {
        LogError("[bonuspoints_transactions] Could not load %s", configPath);
        delete kv;
        return;
    }

    StringMap durations = new StringMap();
    LoadStoreItemDurations(kv, durations);

    if (!kv.GotoFirstSubKey())
    {
        LogError("[bonuspoints_transactions] No items found in %s", configPath);
        delete durations;
        delete kv;
        return;
    }

    do
    {
        char priceKey[32];
        kv.GetSectionName(priceKey, sizeof(priceKey));
        int price = StringToInt(priceKey);
        if (price <= 0)
        {
            continue;
        }

        if (!kv.GotoFirstSubKey(false))
        {
            continue;
        }

        do
        {
            char itemKey[BP_TRANS_ITEM_KEY_MAX];
            char itemName[BP_TRANS_ITEM_NAME_MAX];
            int durationSeconds = BP_PURCHASE_PERMANENT;
            kv.GetSectionName(itemKey, sizeof(itemKey));
            kv.GetString(NULL_STRING, itemName, sizeof(itemName));
            TrimString(itemKey);
            TrimString(itemName);
            durations.GetValue(itemKey, durationSeconds);

            if (itemKey[0] == '\0' || itemName[0] == '\0')
            {
                continue;
            }

            AddStoreItemSorted(itemKey, itemName, price, durationSeconds);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }
    while (kv.GotoNextKey());

    delete durations;
    delete kv;
    LogMessage("[bonuspoints_transactions] Loaded %d shop item(s).", g_ItemPrices.Length);
}

void LoadStoreItemDurations(KeyValues kv, StringMap durations)
{
    if (!kv.JumpToKey("durations", false))
    {
        return;
    }

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            char itemKey[BP_TRANS_ITEM_KEY_MAX];
            char durationText[32];
            kv.GetSectionName(itemKey, sizeof(itemKey));
            kv.GetString(NULL_STRING, durationText, sizeof(durationText));
            TrimString(itemKey);
            TrimString(durationText);

            int durationSeconds = ParseDurationSeconds(durationText);
            if (itemKey[0] != '\0' && durationSeconds > 0)
            {
                durations.SetValue(itemKey, durationSeconds, true);
            }
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }

    kv.GoBack();
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

void AddStoreItemSorted(const char[] itemKey, const char[] itemName, int price, int durationSeconds)
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
        g_ItemPrices.Push(price);
        g_ItemDurations.Push(durationSeconds);
        return;
    }

    g_ItemKeys.ShiftUp(insertAt);
    g_ItemNames.ShiftUp(insertAt);
    g_ItemPrices.ShiftUp(insertAt);
    g_ItemDurations.ShiftUp(insertAt);
    g_ItemKeys.SetString(insertAt, itemKey);
    g_ItemNames.SetString(insertAt, itemName);
    g_ItemPrices.Set(insertAt, price);
    g_ItemDurations.Set(insertAt, durationSeconds);
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

    return GetClientAuthId(client, AuthId_SteamID64, steamId, maxlen);
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

    char query[320];
    Format(query, sizeof(query),
        "SELECT item_key, price_paid, expires_at FROM %s WHERE steamid64 = '%s' AND (expires_at = 0 OR expires_at > %d)",
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
            if (pricePaid > 0 && (expiresAt == BP_PURCHASE_PERMANENT || expiresAt > GetTime()))
            {
                g_ClientPurchases[client].SetValue(itemKey, pricePaid);
                g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
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
    if (client <= 0 || client > MaxClients || g_ClientPurchases[client] == null || g_ClientPurchaseExpiresAt[client] == null)
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
        g_ClientPurchases[client].Remove(itemKey);
        g_ClientPurchaseExpiresAt[client].Remove(itemKey);
        return 0;
    }

    return pricePaid > 0 ? pricePaid : 0;
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

    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, steamLen, true))
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

bool IsBonusPointsNumericTargetType(const char[] type)
{
    return StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false);
}

bool IsPointsEventLoggingEnabled()
{
    return g_CvarEventLogging != null && g_CvarEventLogging.BoolValue;
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

void LogBonusPointsDelta(int client, int delta, int balanceBefore, int balanceAfter, const char[] type, int target, bool playSound, bool chatAlert, float randomChance, bool saveQueued)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));

    int targetValue = target;
    int targetClient = 0;
    char targetSteamId[32];
    char targetName[MAX_NAME_LENGTH];
    strcopy(targetSteamId, sizeof(targetSteamId), "none");
    strcopy(targetName, sizeof(targetName), "none");

    if (!IsBonusPointsNumericTargetType(type) && target > 0 && target <= MaxClients && IsClientConnected(target))
    {
        targetClient = target;
        GetClientLogIdentity(target, targetSteamId, sizeof(targetSteamId), targetName, sizeof(targetName));
    }

    LogPointsStoreEvent(
        "event=bp_delta|time=%d|client=%d|steamid64=%s|name=\"%s\"|delta=%d|balance_before=%d|balance_after=%d|type=%s|target_value=%d|target_client=%d|target_steamid64=%s|target_name=\"%s\"|play_sound=%d|chat_alert=%d|random_chance=%.3f|save_queued=%d",
        GetTime(),
        client,
        steamId,
        clientName,
        delta,
        balanceBefore,
        balanceAfter,
        safeType,
        targetValue,
        targetClient,
        targetSteamId,
        targetName,
        playSound ? 1 : 0,
        chatAlert ? 1 : 0,
        randomChance,
        saveQueued ? 1 : 0);
}

void LogBonusPointsRejected(const char[] reason, int client, int points, const char[] type, int target, int balance, float randomChance, float randomRoll)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));

    char safeReason[64];
    char safeType[64];
    strcopy(safeReason, sizeof(safeReason), reason);
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeReason, sizeof(safeReason));
    SanitizeLogField(safeType, sizeof(safeType));

    LogPointsStoreEvent(
        "event=bp_rejected|time=%d|reason=%s|client=%d|steamid64=%s|name=\"%s\"|requested_delta=%d|balance=%d|type=%s|target_value=%d|random_chance=%.3f|random_roll=%.3f",
        GetTime(),
        safeReason,
        client,
        steamId,
        clientName,
        points,
        balance,
        safeType,
        target,
        randomChance,
        randomRoll);
}

void LogBonusPointsDeferredQueue(int client, int points, const char[] type, int target, float delay, bool playSound, bool chatAlert, float randomChance)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));

    char safeType[64];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeLogField(safeType, sizeof(safeType));

    LogPointsStoreEvent(
        "event=bp_deferred_queue|time=%d|client=%d|steamid64=%s|name=\"%s\"|requested_delta=%d|type=%s|target_value=%d|delay=%.2f|play_sound=%d|chat_alert=%d|random_chance=%.3f",
        GetTime(),
        client,
        steamId,
        clientName,
        points,
        safeType,
        target,
        delay,
        playSound ? 1 : 0,
        chatAlert ? 1 : 0,
        randomChance);
}

void LogPurchaseEvent(const char[] eventName, const char[] reason, int client, const char[] itemKey, const char[] itemName, int price, int balance)
{
    if (!IsPointsEventLoggingEnabled())
    {
        return;
    }

    char steamId[32];
    char clientName[MAX_NAME_LENGTH];
    GetClientLogIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName));

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
        "event=%s|time=%d|reason=%s|client=%d|steamid64=%s|name=\"%s\"|item_key=%s|item_name=\"%s\"|price=%d|balance=%d",
        safeEvent,
        GetTime(),
        safeReason,
        client,
        steamId,
        clientName,
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
    char targetSteamId[32];
    char targetName[MAX_NAME_LENGTH];
    GetClientLogIdentity(sender, senderSteamId, sizeof(senderSteamId), senderName, sizeof(senderName));
    GetClientLogIdentity(target, targetSteamId, sizeof(targetSteamId), targetName, sizeof(targetName));

    char safeEvent[64];
    char safeReason[64];
    strcopy(safeEvent, sizeof(safeEvent), eventName);
    strcopy(safeReason, sizeof(safeReason), reason);
    SanitizeLogField(safeEvent, sizeof(safeEvent));
    SanitizeLogField(safeReason, sizeof(safeReason));

    LogPointsStoreEvent(
        "event=%s|time=%d|reason=%s|sender=%d|sender_steamid64=%s|sender_name=\"%s\"|target=%d|target_steamid64=%s|target_name=\"%s\"|amount=%d|sender_balance=%d|target_balance=%d",
        safeEvent,
        GetTime(),
        safeReason,
        sender,
        senderSteamId,
        senderName,
        target,
        targetSteamId,
        targetName,
        amount,
        GetCachedBonusPoints(sender),
        GetCachedBonusPoints(target));
}

void GetBonusPointsTypeLabel(const char[] type, char[] label, int maxlen)
{
    label[0] = '\0';

    if (StrEqual(type, "airshot", false))
    {
        strcopy(label, maxlen, "Airshot");
    }
    else if (StrEqual(type, "medic_kill", false))
    {
        strcopy(label, maxlen, "Medic Kill");
    }
    else if (StrEqual(type, "heavy_kill", false))
    {
        strcopy(label, maxlen, "Heavy Kill");
    }
    else if (StrEqual(type, "medic_drop", false))
    {
        strcopy(label, maxlen, "Medic Drop");
    }
    else if (StrEqual(type, "medic_uber_drop_kill", false))
    {
        strcopy(label, maxlen, "Medic Uber Drop Kill");
    }
    else if (StrEqual(type, "airshot_kill", false))
    {
        strcopy(label, maxlen, "Airshot Kill");
    }
    else if (StrEqual(type, "meatshot_kill", false))
    {
        strcopy(label, maxlen, "Meatshot kill");
    }
    else if (StrEqual(type, "uber_deployed", false))
    {
        strcopy(label, maxlen, "UberCharge");
    }
    else if (StrEqual(type, "market_garden", false) || StrEqual(type, "market_garden_kill", false))
    {
        strcopy(label, maxlen, "Market Garden Kill");
    }
    else if (StrEqual(type, "player_dom", false))
    {
        strcopy(label, maxlen, "Dominating");
    }
    else if (StrEqual(type, "player_revenge", false))
    {
        strcopy(label, maxlen, "Revenge");
    }
    else if (StrEqual(type, "killstreak_end", false))
    {
        strcopy(label, maxlen, "Killstreak shut down");
    }
}

void GetMultikillBonusPointsLabel(int kills, char[] label, int maxlen)
{
    label[0] = '\0';

    switch (kills)
    {
        case 3: strcopy(label, maxlen, "Triple Kill");
        case 4: strcopy(label, maxlen, "Quadra Kill");
        case 5: strcopy(label, maxlen, "Penta Kill");
    }
}

bool QueueBonusPointsDeltaSave(int client, int delta)
{
    if (delta == 0 || !g_DatabaseReady || g_Database == null)
    {
        return false;
    }

    char steamId[32];
    if (!GetClientSteamId64(client, steamId, sizeof(steamId)))
    {
        return false;
    }

    char escapedSteamId[65];
    if (!EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
    {
        LogError("[points_store] Failed to escape SteamID64 for bonus-point save for client %d.", client);
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

void PlayBonusPointsSound(int client, bool force)
{
    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") != FeatureStatus_Available)
    {
        return;
    }

    SaySounds_PlayCommand(client, BP_SOUND_COMMAND, force);
}

bool ApplyBonusPointsNow(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0)
{
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
        LogBonusPointsRejected("insufficient_points", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll);
        return false;
    }

    int balanceBefore = g_ClientBonusPoints[client];
    g_ClientBonusPoints[client] += points;
    if (g_ClientBonusPoints[client] < 0)
    {
        g_ClientBonusPoints[client] = 0;
    }

    bool saveQueued = QueueBonusPointsDeltaSave(client, points);
    LogBonusPointsDelta(client, points, balanceBefore, g_ClientBonusPoints[client], type, target, playSound, chatAlert, randomChance, saveQueued);
    if (!saveQueued)
    {
        LogBonusPointsRejected("save_not_queued", client, points, type, target, g_ClientBonusPoints[client], randomChance, randomRoll);
    }

    if (playSound)
    {
        PlayBonusPointsSound(client, true);
    }

    if (!chatAlert)
    {
        return true;
    }

    PrintBonusPointsDelta(client, points, type, target);
    return true;
}

bool ApplyBonusPoints(int client, int points = 1, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0)
{
    if (delay < 0.0)
    {
        delay = 0.0;
    }

    if (delay == 0.0)
    {
        return ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target);
    }

    if (!IsClientInGameHuman(client) || points == 0)
    {
        LogBonusPointsRejected(!IsClientInGameHuman(client) ? "deferred_invalid_client" : "deferred_zero_delta", client, points, type, target, 0, randomChance, 0.0);
        return false;
    }

    LogBonusPointsDeferredQueue(client, points, type, target, delay, playSound, chatAlert, randomChance);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(points);
    pack.WriteCell(playSound ? 1 : 0);
    pack.WriteCell(chatAlert ? 1 : 0);
    pack.WriteFloat(randomChance);
    pack.WriteString(type);
    if (StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false))
    {
        pack.WriteCell(target);
    }
    else
    {
        pack.WriteCell(IsClientInGameHuman(target) ? GetClientUserId(target) : 0);
    }

    CreateTimer(delay, Timer_DeferredApplyBonusPoints, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    return true;
}

bool SpendBonusPoints(int client, int points)
{
    if (points <= 0)
    {
        return false;
    }

    return ApplyBonusPoints(client, -points, false, false, 1.0, "spend", 0, 0.0);
}

bool SpendBonusPointsWithContext(int client, int points, const char[] type, int target = 0)
{
    if (points <= 0)
    {
        return false;
    }

    return ApplyBonusPoints(client, -points, false, false, 1.0, type, target, 0.0);
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
    int targetValue = pack.ReadCell();
    int target = (StrEqual(type, "killstreak", false) || StrEqual(type, "multikill", false)) ? targetValue : GetClientOfUserId(targetValue);

    ApplyBonusPointsNow(client, points, playSound, chatAlert, randomChance, type, target);
    return Plugin_Stop;
}

void PrintBonusPointsDelta(int client, int points, const char[] type, int target)
{
    char prefix[96];
    char colorTag[BP_CURRENCY_COLOR_MAX + 2];
    GetCurrencyPrefix(prefix, sizeof(prefix));
    GetCurrencyColorTag(colorTag, sizeof(colorTag));

    if (points < 0)
    {
        CPrintToChat(client, "%s{limegreen}%i", prefix, points);
        return;
    }

    char sign[2];
    sign[0] = '+';
    sign[1] = '\0';

    if (StrEqual(type, "points_diff", false) && IsClientInGameHuman(target))
    {
        char targetName[256];
        BuildPurchaseDisplayName(target, targetName, sizeof(targetName));
        CPrintToChat(client, "%s {limegreen}%s%i{default} for killing %s", prefix, sign, points, targetName);
        return;
    }

    if (StrEqual(type, "mvp_kill", false) && IsClientInGameHuman(target))
    {
        char targetName[256];
        BuildPurchaseDisplayName(target, targetName, sizeof(targetName));
        CPrintToChat(client, "%s {limegreen}%s%i{default} for killing %sMVP %s", prefix, sign, points, colorTag, targetName);
        return;
    }

    if (StrEqual(type, "player_dom", false) && IsClientInGameHuman(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for Dominating %N", prefix, sign, points, target);
        return;
    }

    if (StrEqual(type, "player_revenge", false) && IsClientInGameHuman(target))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for Revenge on %N", prefix, sign, points, target);
        return;
    }

    if (StrEqual(type, "killstreak", false))
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for Killstreak: %d", prefix, sign, points, target);
        return;
    }

    if (StrEqual(type, "multikill", false))
    {
        char multikillLabel[32];
        GetMultikillBonusPointsLabel(target, multikillLabel, sizeof(multikillLabel));
        if (multikillLabel[0] != '\0')
        {
            CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%s", prefix, sign, points, multikillLabel);
        }
        else
        {
            CPrintToChat(client, "%s {limegreen}%s%i{default} for Multikill: %d", prefix, sign, points, target);
        }
        return;
    }

    char label[64];
    GetBonusPointsTypeLabel(type, label, sizeof(label));
    if (label[0] != '\0')
    {
        CPrintToChat(client, "%s {limegreen}%s%i{default} for {gold}%s", prefix, sign, points, label);
        return;
    }

    CPrintToChat(client, "%s {limegreen}%s%i", prefix, sign, points);
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
        "{lightgreen}+1:{default} Airshot kills, market garden kills, ubers, killstreaks, dominations, revenge, meatshot kills");

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
    AttemptPurchase(client, itemKey);
    return 0;
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

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    pack.WriteString(itemKey);
    pack.WriteString(itemName);
    pack.WriteCell(price);
    pack.WriteCell(expiresAt);

    char query[768];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, item_key, price_paid, expires_at) "
            ... "VALUES ('%s', '%s', %d, %d) "
            ... "ON DUPLICATE KEY UPDATE price_paid = VALUES(price_paid), expires_at = VALUES(expires_at), purchased_at = CURRENT_TIMESTAMP",
            BP_TRANS_TABLE,
            escapedSteamId,
            escapedItemKey,
            price,
            expiresAt);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, item_key, price_paid, expires_at) "
            ... "VALUES ('%s', '%s', %d, %d) "
            ... "ON CONFLICT(steamid64, item_key) DO UPDATE SET price_paid = excluded.price_paid, expires_at = excluded.expires_at, purchased_at = CURRENT_TIMESTAMP",
            BP_TRANS_TABLE,
            escapedSteamId,
            escapedItemKey,
            price,
            expiresAt);
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
        g_ClientPurchases[client].Remove(itemKey);
        g_ClientPurchaseExpiresAt[client].Remove(itemKey);
        if (IsClientInGameHuman(client))
        {
            PrintToChat(client, "[Shop] Your purchase could not be saved. Contact an admin.");
        }
        return;
    }

    g_ClientPurchases[client].SetValue(itemKey, price);
    g_ClientPurchaseExpiresAt[client].SetValue(itemKey, expiresAt);
    LogPurchaseEvent("purchase_success", "ok", client, itemKey, itemName, price, GetCachedBonusPoints(client));
    if (IsClientInGameHuman(client))
    {
        char prefix[96];
        GetCurrencyPrefix(prefix, sizeof(prefix));

        char displayName[256];
        BuildPurchaseDisplayName(client, displayName, sizeof(displayName));
        CPrintToChatAllEx(client, "%s %s bought {gold}%s{default}!", prefix, displayName, itemName);
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

    int target = (numParams >= 7) ? GetNativeCell(7) : 0;
    float delay = (numParams >= 8) ? view_as<float>(GetNativeCell(8)) : 3.0;
    return ApplyBonusPoints(client, points, playSound, chatAlert, randomChance, type, target, delay);
}

public any Native_PointsStore_SpendBonusPoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int points = GetNativeCell(2);
    return SpendBonusPoints(client, points);
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
