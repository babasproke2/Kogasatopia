#define MEMOMAN_EVENT_TABLE "points_store_memoman_event"
#define MEMOMAN_EVENT_STEAMID64 "76561199873606169"
#define MEMOMAN_EVENT_REWARD_DELAY 1.0
#define MEMOMAN_EVENT_ADVERT_INTERVAL 900.0
#define MEMOMAN_EVENT_SOURCE_COUNT 7
#define MEMOMAN_EVENT_LEADERBOARD_LIMIT 10
#define MEMOMAN_EVENT_LEADERBOARD_SOURCE_COUNT 8

enum struct MemomanRewardRequest
{
    char steamId64[32];
    char username[MAX_NAME_LENGTH];
    int source;
}

static const char g_MemomanEventSourceIds[MEMOMAN_EVENT_SOURCE_COUNT][] =
{
    "custom_weapon_kill",
    "loch_n_load_kill",
    "loch_n_load_airshot",
    "sentry_kill",
    "sentry_level_3",
    "uber_deployed",
    "double_donk"
};

static const int g_MemomanEventSourceAmounts[MEMOMAN_EVENT_SOURCE_COUNT] =
{
    1,
    1,
    1,
    1,
    1,
    1,
    1
};

static const char g_MemomanEventSourceReasons[MEMOMAN_EVENT_SOURCE_COUNT][] =
{
    "Kill with a custom weapon",
    "Loch-n-Load kill",
    "Loch-n-Load airshot kill",
    "Sentry kill",
    "Upgraded Sentry to Level 3",
    "Deployed ÜberCharge",
    "Episten"
};

static const char g_MemomanEventSourceColumns[MEMOMAN_EVENT_SOURCE_COUNT][] =
{
    "custom_weapon_kills",
    "loch_n_load_kills",
    "loch_n_load_airshots",
    "sentry_kills",
    "sentries_upgraded_level_3",
    "ubercharges_deployed",
    "double_donks"
};

static const char g_MemomanEventLeaderboardSourceNames[MEMOMAN_EVENT_LEADERBOARD_SOURCE_COUNT][] =
{
    "Custom Weapon Kill",
    "Loch-n-Load Kill",
    "Loch-n-Load Airshot",
    "Built a Sentry",
    "Sentry Kill",
    "Level 3 Sentry",
    "ÜberCharge",
    "Episten"
};

ArrayList g_MemomanEventQueue = null;
Handle g_MemomanEventAdvertTimer = null;
bool g_MemomanEventReady = false;
bool g_MemomanEventBusy = false;
int g_MemomanEventGeneration = 0;
int g_MemomanEventBalance = 0;

void MemomanEvent_OnPluginStart()
{
    g_MemomanEventQueue = new ArrayList(sizeof(MemomanRewardRequest));
    RegConsoleCmd("sm_memo", Command_MemomanEvent, "Show the Memoman Graverobbing Event.");
    RegConsoleCmd("sm_ml", Command_MemomanEventLeaderboard, "Show the Memoman event leaderboard.");
    RegConsoleCmd("sm_memoleaderboard", Command_MemomanEventLeaderboard, "Show the Memoman event leaderboard.");
    g_MemomanEventAdvertTimer = CreateTimer(
        MEMOMAN_EVENT_ADVERT_INTERVAL,
        Timer_MemomanEventAdvert,
        _,
        TIMER_REPEAT);
}

void MemomanEvent_OnPluginEnd()
{
    delete g_MemomanEventAdvertTimer;
    g_MemomanEventAdvertTimer = null;
    delete g_MemomanEventQueue;
    g_MemomanEventQueue = null;
}

void MemomanEvent_OnDatabaseDisconnected()
{
    g_MemomanEventGeneration++;
    g_MemomanEventReady = false;
    g_MemomanEventBusy = false;
    g_MemomanEventBalance = 0;
    if (g_MemomanEventQueue != null)
    {
        g_MemomanEventQueue.Clear();
    }
}

void MemomanEvent_EnsureSchema()
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
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "username VARCHAR(128) NOT NULL DEFAULT '', "
            ... "gems_gained INT NOT NULL DEFAULT 0, "
            ... "custom_weapon_kills INT NOT NULL DEFAULT 0, "
            ... "loch_n_load_kills INT NOT NULL DEFAULT 0, "
            ... "loch_n_load_airshots INT NOT NULL DEFAULT 0, "
            ... "sentries_built INT NOT NULL DEFAULT 0, "
            ... "sentry_kills INT NOT NULL DEFAULT 0, "
            ... "sentries_upgraded_level_3 INT NOT NULL DEFAULT 0, "
            ... "ubercharges_deployed INT NOT NULL DEFAULT 0, "
            ... "double_donks INT NOT NULL DEFAULT 0, "
            ... "updated_at INT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (steamid64), "
            ... "KEY idx_memoman_event_gems (gems_gained)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            MEMOMAN_EVENT_TABLE);
    }
    else
    {
        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
            ... "username VARCHAR(128) NOT NULL DEFAULT '', "
            ... "gems_gained INTEGER NOT NULL DEFAULT 0, "
            ... "custom_weapon_kills INTEGER NOT NULL DEFAULT 0, "
            ... "loch_n_load_kills INTEGER NOT NULL DEFAULT 0, "
            ... "loch_n_load_airshots INTEGER NOT NULL DEFAULT 0, "
            ... "sentries_built INTEGER NOT NULL DEFAULT 0, "
            ... "sentry_kills INTEGER NOT NULL DEFAULT 0, "
            ... "sentries_upgraded_level_3 INTEGER NOT NULL DEFAULT 0, "
            ... "ubercharges_deployed INTEGER NOT NULL DEFAULT 0, "
            ... "double_donks INTEGER NOT NULL DEFAULT 0, "
            ... "updated_at INTEGER NOT NULL DEFAULT 0)",
            MEMOMAN_EVENT_TABLE);
    }

    g_Database.Query(SQL_OnMemomanEventSchemaReady, query, g_MemomanEventGeneration);
}

public void SQL_OnMemomanEventSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (data != g_MemomanEventGeneration)
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event schema creation failed: %s", error);
        return;
    }

    char query[256];
    Format(query, sizeof(query),
        "ALTER TABLE %s ADD COLUMN double_donks %s NOT NULL DEFAULT 0",
        MEMOMAN_EVENT_TABLE,
        g_IsMySql ? "INT" : "INTEGER");
    g_Database.Query(SQL_OnMemomanEventDoubleDonksColumnReady, query, data);
}

public void SQL_OnMemomanEventDoubleDonksColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (data != g_MemomanEventGeneration)
    {
        return;
    }
    if (error[0] != '\0' && !Db_IsDuplicateColumnError(error))
    {
        LogError("[points_store] Memoman event Double Donk schema update failed: %s", error);
        return;
    }

    g_MemomanEventReady = true;
    MemomanEvent_LoadBalance();
}

void MemomanEvent_LoadBalance()
{
    if (!g_MemomanEventReady || g_Database == null)
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query),
        "SELECT balance FROM %s WHERE steamid64 = '%s'",
        BP_BALANCE_TABLE,
        MEMOMAN_EVENT_STEAMID64);
    g_Database.Query(SQL_OnMemomanEventBalanceLoaded, query, g_MemomanEventGeneration);
}

public void SQL_OnMemomanEventBalanceLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (data != g_MemomanEventGeneration)
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event balance load failed: %s", error);
        return;
    }

    g_MemomanEventBalance = (results != null && results.FetchRow()) ? results.FetchInt(0) : 0;
    MemomanEvent_ProcessNext();
}

int MemomanEvent_FindSource(const char[] sourceId)
{
    for (int i = 0; i < MEMOMAN_EVENT_SOURCE_COUNT; i++)
    {
        if (StrEqual(sourceId, g_MemomanEventSourceIds[i], false))
        {
            return i;
        }
    }
    return -1;
}

bool MemomanEvent_QueueReward(int client, const char[] sourceId)
{
    int source = MemomanEvent_FindSource(sourceId);
    if (source < 0
        || !g_MemomanEventReady
        || !AreBonusPointsReady(client)
        || g_Database == null)
    {
        return false;
    }

    MemomanRewardRequest request;
    if (!GetClientSteamId64(client, request.steamId64, sizeof(request.steamId64))
        || StrEqual(request.steamId64, MEMOMAN_EVENT_STEAMID64, false))
    {
        return false;
    }

    GetClientName(client, request.username, sizeof(request.username));
    request.source = source;

    DataPack pack = new DataPack();
    pack.WriteString(request.steamId64);
    pack.WriteString(request.username);
    pack.WriteCell(request.source);
    pack.WriteCell(g_MemomanEventGeneration);
    CreateTimer(
        MEMOMAN_EVENT_REWARD_DELAY,
        Timer_QueueMemomanEventReward,
        pack,
        TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    return true;
}

public Action Timer_QueueMemomanEventReward(Handle timer, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    MemomanRewardRequest request;
    pack.ReadString(request.steamId64, sizeof(request.steamId64));
    pack.ReadString(request.username, sizeof(request.username));
    request.source = pack.ReadCell();
    int generation = pack.ReadCell();

    if (generation == g_MemomanEventGeneration
        && g_MemomanEventReady
        && g_MemomanEventQueue != null)
    {
        g_MemomanEventQueue.PushArray(request, sizeof(request));
        MemomanEvent_ProcessNext();
    }
    return Plugin_Stop;
}

DataPack MemomanEvent_CreateRequestPack(MemomanRewardRequest request)
{
    DataPack pack = new DataPack();
    pack.WriteString(request.steamId64);
    pack.WriteString(request.username);
    pack.WriteCell(request.source);
    pack.WriteCell(g_MemomanEventGeneration);
    return pack;
}

bool MemomanEvent_ReadRequestPack(any data, MemomanRewardRequest request)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    pack.ReadString(request.steamId64, sizeof(request.steamId64));
    pack.ReadString(request.username, sizeof(request.username));
    request.source = pack.ReadCell();
    int generation = pack.ReadCell();
    delete pack;
    return generation == g_MemomanEventGeneration;
}

void MemomanEvent_ProcessNext()
{
    if (g_MemomanEventBusy
        || !g_MemomanEventReady
        || g_Database == null
        || g_MemomanEventQueue == null
        || g_MemomanEventQueue.Length == 0)
    {
        return;
    }

    MemomanRewardRequest request;
    g_MemomanEventQueue.GetArray(0, request, sizeof(request));
    g_MemomanEventQueue.Erase(0);
    g_MemomanEventBusy = true;

    char escapedSteamId[65];
    if (!EscapeSql(request.steamId64, escapedSteamId, sizeof(escapedSteamId)))
    {
        MemomanEvent_FinishRequest();
        return;
    }

    char query[384];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT IGNORE INTO %s (steamid64, balance) VALUES ('%s', 0)",
            BP_BALANCE_TABLE,
            escapedSteamId);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT OR IGNORE INTO %s (steamid64, balance) VALUES ('%s', 0)",
            BP_BALANCE_TABLE,
            escapedSteamId);
    }

    g_Database.Query(
        SQL_OnMemomanEventRecipientReady,
        query,
        MemomanEvent_CreateRequestPack(request));
}

public void SQL_OnMemomanEventRecipientReady(Database db, DBResultSet results, const char[] error, any data)
{
    MemomanRewardRequest request;
    if (!MemomanEvent_ReadRequestPack(data, request))
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event recipient initialization failed: %s", error);
        MemomanEvent_FinishRequest();
        return;
    }

    int amount = g_MemomanEventSourceAmounts[request.source];
    char escapedSteamId[65];
    EscapeSql(request.steamId64, escapedSteamId, sizeof(escapedSteamId));

    char query[1024];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "UPDATE %s AS balance_row "
            ... "JOIN %s AS event_source ON event_source.steamid64 = '%s' AND event_source.balance >= %d "
            ... "SET balance_row.balance = CASE "
            ... "WHEN balance_row.steamid64 = '%s' THEN balance_row.balance - %d "
            ... "ELSE balance_row.balance + %d END "
            ... "WHERE balance_row.steamid64 IN ('%s', '%s')",
            BP_BALANCE_TABLE,
            BP_BALANCE_TABLE,
            MEMOMAN_EVENT_STEAMID64,
            amount,
            MEMOMAN_EVENT_STEAMID64,
            amount,
            amount,
            MEMOMAN_EVENT_STEAMID64,
            escapedSteamId);
    }
    else
    {
        Format(query, sizeof(query),
            "UPDATE %s SET balance = CASE "
            ... "WHEN steamid64 = '%s' THEN balance - %d ELSE balance + %d END "
            ... "WHERE steamid64 IN ('%s', '%s') AND "
            ... "(SELECT balance FROM %s WHERE steamid64 = '%s') >= %d",
            BP_BALANCE_TABLE,
            MEMOMAN_EVENT_STEAMID64,
            amount,
            amount,
            MEMOMAN_EVENT_STEAMID64,
            escapedSteamId,
            BP_BALANCE_TABLE,
            MEMOMAN_EVENT_STEAMID64,
            amount);
    }

    g_Database.Query(
        SQL_OnMemomanEventTransferred,
        query,
        MemomanEvent_CreateRequestPack(request));
}

public void SQL_OnMemomanEventTransferred(Database db, DBResultSet results, const char[] error, any data)
{
    MemomanRewardRequest request;
    if (!MemomanEvent_ReadRequestPack(data, request))
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event transfer failed: %s", error);
        MemomanEvent_FinishRequest();
        return;
    }
    if (results == null || results.AffectedRows < 2)
    {
        MemomanEvent_FinishRequest();
        return;
    }

    int amount = g_MemomanEventSourceAmounts[request.source];
    int recipient = Kogasa_FindClientBySteamId64(request.steamId64);
    if (recipient > 0 && g_ClientBonusPointsLoaded[recipient])
    {
        g_ClientBonusPoints[recipient] += amount;
        CPrintToChat(
            recipient,
            "%s{magenta}+%d{default} for {magenta}Memoman event: {gold}%s",
            g_CurrencyPrefix,
            amount,
            g_MemomanEventSourceReasons[request.source]);
        PlayBonusPointsSound(recipient, true);
    }

    int memoman = Kogasa_FindClientBySteamId64(MEMOMAN_EVENT_STEAMID64);
    if (memoman > 0 && g_ClientBonusPointsLoaded[memoman])
    {
        g_ClientBonusPoints[memoman] = g_ClientBonusPoints[memoman] > amount
            ? g_ClientBonusPoints[memoman] - amount
            : 0;
    }

    MemomanEvent_UpdateLeaderboard(request);
    LogPointsStoreEvent(
        "event=memoman_reward|time=%d|source=%s|recipient_steamid64=%s|recipient_name=\"%s\"|amount=%d",
        GetTime(),
        g_MemomanEventSourceIds[request.source],
        request.steamId64,
        request.username,
        amount);

    char query[256];
    Format(query, sizeof(query),
        "SELECT balance FROM %s WHERE steamid64 = '%s'",
        BP_BALANCE_TABLE,
        MEMOMAN_EVENT_STEAMID64);
    g_Database.Query(
        SQL_OnMemomanEventPostTransferBalance,
        query,
        MemomanEvent_CreateRequestPack(request));
}

void MemomanEvent_UpdateLeaderboard(MemomanRewardRequest request)
{
    int amount = g_MemomanEventSourceAmounts[request.source];
    char escapedSteamId[65];
    char escapedName[(MAX_NAME_LENGTH * 2) + 1];
    if (!EscapeSql(request.steamId64, escapedSteamId, sizeof(escapedSteamId))
        || !EscapeSql(request.username, escapedName, sizeof(escapedName)))
    {
        return;
    }

    char query[1536];
    if (g_IsMySql)
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, username, gems_gained, %s, updated_at) "
            ... "VALUES ('%s', '%s', %d, %d, %d) "
            ... "ON DUPLICATE KEY UPDATE username = VALUES(username), "
            ... "gems_gained = gems_gained + VALUES(gems_gained), "
            ... "%s = %s + VALUES(%s), updated_at = VALUES(updated_at)",
            MEMOMAN_EVENT_TABLE,
            g_MemomanEventSourceColumns[request.source],
            escapedSteamId,
            escapedName,
            amount,
            amount,
            GetTime(),
            g_MemomanEventSourceColumns[request.source],
            g_MemomanEventSourceColumns[request.source],
            g_MemomanEventSourceColumns[request.source]);
    }
    else
    {
        Format(query, sizeof(query),
            "INSERT INTO %s (steamid64, username, gems_gained, %s, updated_at) "
            ... "VALUES ('%s', '%s', %d, %d, %d) "
            ... "ON CONFLICT(steamid64) DO UPDATE SET username = excluded.username, "
            ... "gems_gained = gems_gained + excluded.gems_gained, "
            ... "%s = %s + excluded.%s, updated_at = excluded.updated_at",
            MEMOMAN_EVENT_TABLE,
            g_MemomanEventSourceColumns[request.source],
            escapedSteamId,
            escapedName,
            amount,
            amount,
            GetTime(),
            g_MemomanEventSourceColumns[request.source],
            g_MemomanEventSourceColumns[request.source],
            g_MemomanEventSourceColumns[request.source]);
    }

    g_Database.Query(SQL_OnMemomanEventLeaderboardUpdated, query);
}

public void SQL_OnMemomanEventLeaderboardUpdated(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event leaderboard update failed: %s", error);
    }
}

public void SQL_OnMemomanEventPostTransferBalance(Database db, DBResultSet results, const char[] error, any data)
{
    MemomanRewardRequest request;
    if (!MemomanEvent_ReadRequestPack(data, request))
    {
        return;
    }

    if (error[0] != '\0' || results == null || !results.FetchRow())
    {
        if (error[0] != '\0')
        {
            LogError("[points_store] Memoman event post-transfer balance query failed: %s", error);
        }
        MemomanEvent_FinishRequest();
        return;
    }

    int amount = g_MemomanEventSourceAmounts[request.source];
    int balanceAfter = results.FetchInt(0);
    int balanceBefore = balanceAfter + amount;
    g_MemomanEventBalance = balanceAfter;

    if (((balanceBefore + 99) / 100) > ((balanceAfter + 99) / 100))
    {
        char currencyLong[BP_CURRENCY_LONG_MAX];
        GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
        CPrintToChatAll(
            "%s {blue}Memoman{default} has %s%d %s{default} remaining!",
            g_CurrencyPrefix,
            g_CurrencyColorTag,
            balanceAfter,
            currencyLong);
    }

    MemomanEvent_FinishRequest();
}

void MemomanEvent_FinishRequest()
{
    g_MemomanEventBusy = false;
    MemomanEvent_ProcessNext();
}

public Action Timer_MemomanEventAdvert(Handle timer, any data)
{
    if (g_MemomanEventReady && g_MemomanEventBalance > 0)
    {
        CPrintToChatAll(
            "%s There's a {blue}Memoman Graverobbing Event{default}, use {gold}!memo{default} to learn more!",
            g_CurrencyPrefix);
    }
    return Plugin_Continue;
}

public Action Command_MemomanEvent(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }
    if (!g_MemomanEventReady || g_Database == null)
    {
        CPrintToChat(client, "%s The Memoman event is temporarily unavailable.", g_CurrencyPrefix);
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_MemomanEventGeneration);

    char query[256];
    Format(query, sizeof(query),
        "SELECT balance FROM %s WHERE steamid64 = '%s'",
        BP_BALANCE_TABLE,
        MEMOMAN_EVENT_STEAMID64);
    g_Database.Query(SQL_OnMemomanEventCommandBalance, query, pack);
    return Plugin_Handled;
}

public void SQL_OnMemomanEventCommandBalance(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (generation != g_MemomanEventGeneration || !Client_IsHumanInGame(client))
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event command balance query failed: %s", error);
        CPrintToChat(client, "%s The Memoman event is temporarily unavailable.", g_CurrencyPrefix);
        return;
    }

    int balance = (results != null && results.FetchRow()) ? results.FetchInt(0) : 0;
    g_MemomanEventBalance = balance;

    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    CPrintToChat(client, "{magenta} --- Memoman Graverobbing Event ---");
    CPrintToChat(
        client,
        "{blue}Memoman{default}'s remaining %s%s{default}: %d",
        g_CurrencyColorTag,
        currencyLong,
        balance);
    CPrintToChat(
        client,
        "Steal %s from {blue}Memoman{default}'s account through the following methods:",
        currencyLong);
    CPrintToChat(
        client,
        "Loch-n-Load kill, Loch-n-Load airshot kill, kills with custom weapons, sentry kills, upgrading a sentry to level 3, deploying ÜberCharges, and a {gold}Secret Method");
}

public Action Command_MemomanEventLeaderboard(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }
    if (!g_MemomanEventReady || g_Database == null)
    {
        CPrintToChat(client, "%s The Memoman event is temporarily unavailable.", g_CurrencyPrefix);
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_MemomanEventGeneration);

    char query[768];
    Format(query, sizeof(query),
        "SELECT steamid64, username, gems_gained, custom_weapon_kills, "
        ... "loch_n_load_kills, loch_n_load_airshots, sentries_built, "
        ... "sentry_kills, sentries_upgraded_level_3, ubercharges_deployed, double_donks "
        ... "FROM %s WHERE gems_gained > 0 "
        ... "ORDER BY gems_gained DESC, steamid64 ASC LIMIT %d",
        MEMOMAN_EVENT_TABLE,
        MEMOMAN_EVENT_LEADERBOARD_LIMIT);
    g_Database.Query(SQL_OnMemomanEventLeaderboard, query, pack);
    return Plugin_Handled;
}

void MemomanEvent_BuildTopSources(DBResultSet results, char[] buffer, int maxlen)
{
    int topSources[3] = {-1, -1, -1};
    int topValues[3];

    for (int source = 0; source < MEMOMAN_EVENT_LEADERBOARD_SOURCE_COUNT; source++)
    {
        int value = results.FetchInt(3 + source);
        if (value <= 0)
        {
            continue;
        }

        for (int position = 0; position < sizeof(topSources); position++)
        {
            if (topSources[position] != -1 && value <= topValues[position])
            {
                continue;
            }

            for (int shift = sizeof(topSources) - 1; shift > position; shift--)
            {
                topSources[shift] = topSources[shift - 1];
                topValues[shift] = topValues[shift - 1];
            }
            topSources[position] = source;
            topValues[position] = value;
            break;
        }
    }

    buffer[0] = '\0';
    char sourceText[96];
    for (int position = 0; position < sizeof(topSources); position++)
    {
        if (topSources[position] == -1)
        {
            continue;
        }
        if (buffer[0] != '\0')
        {
            StrCat(buffer, maxlen, ", ");
        }

        Format(
            sourceText,
            sizeof(sourceText),
            "{magenta}%s %s%d{gold}",
            g_MemomanEventLeaderboardSourceNames[topSources[position]],
            g_CurrencyColorTag,
            topValues[position]);
        StrCat(buffer, maxlen, sourceText);
    }
}

public void SQL_OnMemomanEventLeaderboard(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (generation != g_MemomanEventGeneration || !Client_IsHumanInGame(client))
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Memoman event leaderboard query failed: %s", error);
        CPrintToChat(client, "%s Failed to load the Memoman event leaderboard.", g_CurrencyPrefix);
        return;
    }

    CPrintToChat(client, "{magenta} ----- Memoman Graverobbing Event -----");

    int rank = 0;
    while (results != null && results.FetchRow())
    {
        rank++;

        char storedName[128];
        char displayName[128];
        results.FetchString(1, storedName, sizeof(storedName));
        StripMenuColorTags(storedName, displayName, sizeof(displayName));
        if (displayName[0] == '\0')
        {
            results.FetchString(0, displayName, sizeof(displayName));
        }

        char topSources[320];
        MemomanEvent_BuildTopSources(results, topSources, sizeof(topSources));

        CPrintToChat(
            client,
            "%d. %s %s%d{default} - {gold}%s",
            rank,
            displayName,
            g_CurrencyColorTag,
            results.FetchInt(2),
            topSources);
    }

    if (rank == 0)
    {
        CPrintToChat(client, "%s No Memoman event rewards have been recorded.", g_CurrencyPrefix);
    }
}
