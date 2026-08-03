#if defined _points_store_bounties_included
    #endinput
#endif
#define _points_store_bounties_included

#define BOUNTY_TABLE "points_store_bounties"
#define BOUNTY_STEAMID_MAX 32
#define BOUNTY_NAME_MAX 128
#define BOUNTY_SEARCH_MAX 64
#define BOUNTY_TOKEN_MAX 128
#define BOUNTY_SYSTEM_STEAMID "system"
#define BOUNTY_WALL_EXPIRY_SECONDS 604800
#define BOUNTY_PLAYTIME_EXPIRY_SECONDS 1200
#define BOUNTY_HALFTIME_SECONDS (BOUNTY_PLAYTIME_EXPIRY_SECONDS / 2)
#define BOUNTY_HALFTIME_REMAINING_MINUTES ((BOUNTY_PLAYTIME_EXPIRY_SECONDS - BOUNTY_HALFTIME_SECONDS) / 60)
#define BOUNTY_KILL_GROWTH_PERCENT 5
#define BOUNTY_MEDIC_ASSISTS_PER_GROWTH 2
#define BOUNTY_MAINTENANCE_INTERVAL 60.0
#define BOUNTY_CHALLENGE_SOUND "duel_challenge"
#define BOUNTY_EVENT_SOUND "duel_event"
#define BOUNTY_AUTOMATIC_CHANCE_PERCENT 15
#define BOUNTY_AUTOMATIC_AMOUNT 100
#define BOUNTY_AUTOMATIC_MIN_BALANCE 500

enum struct BountySearchResult
{
    char steamId[BOUNTY_STEAMID_MAX];
    char name[BOUNTY_NAME_MAX];
    int playtime;
    bool connected;
}

static const int g_BountyAmounts[] = {10, 25, 50, 100, 250, 1000};

bool g_BountyDatabaseReady = false;
bool g_BountyExpiryPending = false;
bool g_BountyProgressPending = false;
bool g_BountyNotificationQueryPending = false;
StringMap g_ActiveBountyTargets = null;
int g_BountyTargetCacheGeneration = 0;
bool g_BountyPlacementPending[MAXPLAYERS + 1];
ArrayList g_BountySearchResults[MAXPLAYERS + 1];
char g_BountyPendingSearch[MAXPLAYERS + 1][BOUNTY_NAME_MAX];
char g_BountyPendingTargetSteamId[MAXPLAYERS + 1][BOUNTY_STEAMID_MAX];
char g_BountyPendingTargetName[MAXPLAYERS + 1][BOUNTY_NAME_MAX];
int g_BountyPendingAmount[MAXPLAYERS + 1];
int g_BountyMedicAssistsLife[MAXPLAYERS + 1];
int g_BountySearchGeneration[MAXPLAYERS + 1];
int g_BountyOperationSerial = 0;
Handle g_BountyMaintenanceTimer = null;
char g_BountyPrefix[96];
int g_BountySchemaChecksPending = 0;
bool g_BountySchemaCheckFailed = false;
bool g_BountyAutomaticPlacementPending = false;

static const char g_BountyHelpLines[][] =
{
    "Bounties last 20 minutes of playtime or one week in real time.",
    "When a client with a bounty on them is dominated, the bounty ends and pays the dominator the Gems.",
    "Each kill, or every 2 assists as Medic, increases the bounty by 5% of its original value."
};

void Bounties_OnPluginStart()
{
    RegConsoleCmd("sm_bounty", Command_PlaceBounty, "Place a bounty on a ranked player.");
    RegConsoleCmd("sm_placebounty", Command_PlaceBounty, "Place a bounty on a ranked player.");
    RegConsoleCmd("sm_bounties", Command_ShowBounties, "Show active player bounties.");
    RegConsoleCmd("sm_bh", Command_BountyHelp, "Explain player bounties.");
    RegConsoleCmd("sm_bountyhelp", Command_BountyHelp, "Explain player bounties.");
    HookEvent("player_death", Event_BountyPlayerDeath, EventHookMode_Post);
    HookEvent("teamplay_round_start", Event_BountyRoundStart, EventHookMode_PostNoCopy);

    g_ActiveBountyTargets = new StringMap();

    for (int client = 1; client <= MaxClients; client++)
    {
        ResetBountyClientState(client);
    }

    g_BountyMaintenanceTimer = CreateTimer(
        BOUNTY_MAINTENANCE_INTERVAL,
        Timer_BountyMaintenance,
        _,
        TIMER_REPEAT);
    Bounties_RefreshPrefix();
}

void Bounties_RefreshPrefix()
{
    FormatEx(g_BountyPrefix, sizeof(g_BountyPrefix), "%s[Bounties]{default}", g_CurrencyColorTag);
}

int GetBountyMinPlayers()
{
    return g_CvarBountyMinPlayers != null ? g_CvarBountyMinPlayers.IntValue : 6;
}

int GetBountyMaxAmount()
{
    return g_CvarBountyMaxAmount != null ? g_CvarBountyMaxAmount.IntValue : 1000;
}

bool IsBountyPopulationEligible()
{
    return GetClientCount(false) >= GetBountyMinPlayers();
}

public Action Command_BountyHelp(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    char firstLine[256];
    FormatEx(firstLine, sizeof(firstLine),
        "Use {gold}'!bounty makocake 100'{default} to place a %s100 Gem{default} bounty on Makocake.",
        g_CurrencyColorTag);
    CPrintToChat(client, "%s %s", g_BountyPrefix, firstLine);
    for (int i = 0; i < sizeof(g_BountyHelpLines); i++)
    {
        CPrintToChat(client, "%s %s", g_BountyPrefix, g_BountyHelpLines[i]);
    }
    CPrintToChat(client,
        "%s An individual bounty cannot exceed %s%d %s{default}.",
        g_BountyPrefix,
        g_CurrencyColorTag,
        GetBountyMaxAmount(),
        g_CurrencyLongLabel);
    int thresholdDisplay = GetBountyMinPlayers() - 1;
    if (thresholdDisplay < 0)
    {
        thresholdDisplay = 0;
    }
    CPrintToChat(client,
        "%s Bounties can only be placed when more than {gold}%d{default} players are connected, and playtime does not count below that threshold.",
        g_BountyPrefix,
        thresholdDisplay);
    return Plugin_Handled;
}

void Bounties_OnPluginEnd()
{
    delete g_BountyMaintenanceTimer;
    delete g_ActiveBountyTargets;
    g_ActiveBountyTargets = null;
    for (int client = 1; client <= MaxClients; client++)
    {
        delete g_BountySearchResults[client];
        g_BountySearchResults[client] = null;
    }
}

void Bounties_OnMapStart()
{
    g_BountyAutomaticPlacementPending = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        g_BountyMedicAssistsLife[client] = 0;
    }

    if (g_BountyDatabaseReady)
    {
        ProcessExpiredBounties();
        RequestBountyProgress();
        RequestPendingBountyNotifications();
        RefreshActiveBountyTargets();
    }
}

public void Event_BountyRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_BountyDatabaseReady || g_Database == null || g_BountyAutomaticPlacementPending
        || GetRandomInt(1, 100) > BOUNTY_AUTOMATIC_CHANCE_PERCENT)
    {
        return;
    }

    char steamIds[2048];
    char steamId[BOUNTY_STEAMID_MAX];
    char escapedSteamId[(BOUNTY_STEAMID_MAX * 2) + 1];
    char fragment[80];
    int candidateCount = 0;
    steamIds[0] = '\0';

    for (int client = 1; client <= MaxClients; client++)
    {
        int team = IsClientInGameHuman(client) ? GetClientTeam(client) : 0;
        if ((team != 2 && team != 3) || !AreBonusPointsReady(client)
            || GetCachedBonusPoints(client) <= BOUNTY_AUTOMATIC_MIN_BALANCE
            || !GetClientSteamId64(client, steamId, sizeof(steamId))
            || !EscapeSql(steamId, escapedSteamId, sizeof(escapedSteamId)))
        {
            continue;
        }

        FormatEx(fragment, sizeof(fragment), "%s'%s'", candidateCount > 0 ? "," : "", escapedSteamId);
        StrCat(steamIds, sizeof(steamIds), fragment);
        candidateCount++;
    }

    if (candidateCount == 0)
    {
        return;
    }

    char query[3072];
    FormatEx(query, sizeof(query),
        "SELECT w.steamid FROM whaletracker w INNER JOIN %s b ON b.steamid64 = w.steamid "
        ... "WHERE w.steamid IN (%s) AND b.balance > %d "
        ... "AND (COALESCE(w.kills, 0) + COALESCE(w.assists, 0)) > "
        ... "(5 * CASE WHEN COALESCE(w.deaths, 0) > 0 THEN w.deaths ELSE 1 END) "
        ... "ORDER BY %s LIMIT 1",
        BP_BALANCE_TABLE,
        steamIds,
        BOUNTY_AUTOMATIC_MIN_BALANCE,
        g_IsMySql ? "RAND()" : "RANDOM()");
    g_BountyAutomaticPlacementPending = true;
    g_Database.Query(SQL_OnAutomaticBountyCandidateSelected, query);
}

public void SQL_OnAutomaticBountyCandidateSelected(Database db, DBResultSet rows, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        g_BountyAutomaticPlacementPending = false;
        LogError("[points_store] Automatic bounty candidate query failed: %s", error);
        return;
    }

    char steamId[BOUNTY_STEAMID_MAX];
    if (rows == null || !rows.FetchRow())
    {
        g_BountyAutomaticPlacementPending = false;
        return;
    }
    rows.FetchString(0, steamId, sizeof(steamId));

    int target = FindClientBySteamId64(steamId);
    int team = IsClientInGameHuman(target) ? GetClientTeam(target) : 0;
    if ((team != 2 && team != 3) || !AreBonusPointsReady(target)
        || GetCachedBonusPoints(target) <= BOUNTY_AUTOMATIC_MIN_BALANCE)
    {
        g_BountyAutomaticPlacementPending = false;
        return;
    }

    QueueAutomaticBounty(target, steamId);
}

void QueueAutomaticBounty(int target, const char[] targetSteamId)
{
    char targetName[BOUNTY_NAME_MAX];
    char escapedTargetSteam[(BOUNTY_STEAMID_MAX * 2) + 1];
    char escapedTargetName[(BOUNTY_NAME_MAX * 2) + 1];
    GetClientName(target, targetName, sizeof(targetName));
    if (!EscapeSql(targetSteamId, escapedTargetSteam, sizeof(escapedTargetSteam))
        || !EscapeSql(targetName, escapedTargetName, sizeof(escapedTargetName)))
    {
        g_BountyAutomaticPlacementPending = false;
        return;
    }

    int now = GetTime();
    int targetPlaytime = 0;
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") == FeatureStatus_Available)
    {
        targetPlaytime = WhaleTracker_GetRankedPlaytimeSeconds(target, targetSteamId);
    }

    char query[1536];
    FormatEx(query, sizeof(query),
        "INSERT INTO %s (sender_steamid64, sender_name, target_steamid64, target_name, amount, placed_at, expires_at, "
        ... "qualifying_playtime_seconds, last_target_playtime_seconds, sender_notified, status) "
        ... "VALUES ('%s', 'kogasa.tf', '%s', '%s', %d, %d, %d, 0, %d, 1, 'active')",
        BOUNTY_TABLE,
        BOUNTY_SYSTEM_STEAMID,
        escapedTargetSteam,
        escapedTargetName,
        BOUNTY_AUTOMATIC_AMOUNT,
        now,
        now + BOUNTY_WALL_EXPIRY_SECONDS,
        targetPlaytime);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(target));
    pack.WriteString(targetSteamId);
    pack.WriteString(targetName);
    g_Database.Query(SQL_OnAutomaticBountyPlaced, query, pack);
}

public void SQL_OnAutomaticBountyPlaced(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int target = GetClientOfUserId(pack.ReadCell());
    char targetSteamId[BOUNTY_STEAMID_MAX];
    char targetName[BOUNTY_NAME_MAX];
    pack.ReadString(targetSteamId, sizeof(targetSteamId));
    pack.ReadString(targetName, sizeof(targetName));
    delete pack;
    g_BountyAutomaticPlacementPending = false;

    if (error[0] != '\0' || results == null || results.AffectedRows <= 0)
    {
        LogError("[points_store] Automatic bounty placement failed: %s", error[0] ? error : "no row inserted");
        return;
    }

    MarkActiveBountyTarget(targetSteamId);

    char targetDisplay[256];
    BuildBountyDisplayName(targetSteamId, targetName, targetDisplay, sizeof(targetDisplay));
    char currencyName[BP_CURRENCY_SHORT_MAX];
    GetCurrencyShortLabelForAmount(BOUNTY_AUTOMATIC_AMOUNT, currencyName, sizeof(currencyName));
    for (int recipient = 1; recipient <= MaxClients; recipient++)
    {
        if (IsClientInGameHuman(recipient))
        {
            CPrintToChatEx(recipient, target > 0 ? target : recipient,
                "%s A bounty has been placed on %s! Dominate him to receive %s%d %s{default}!",
                g_BountyPrefix,
                targetDisplay,
                g_CurrencyColorTag,
                BOUNTY_AUTOMATIC_AMOUNT,
                currencyName);
        }
    }
    PrintBountyTargetInstructions(target);
    PlayBountySaySound(BOUNTY_CHALLENGE_SOUND);
    LogPointsStoreEvent(
        "event=bounty_placed|time=%d|sender=%s|target=%s|amount=%d|expires_at=%d|automatic=1",
        GetTime(), BOUNTY_SYSTEM_STEAMID, targetSteamId, BOUNTY_AUTOMATIC_AMOUNT,
        GetTime() + BOUNTY_WALL_EXPIRY_SECONDS);
}

void PrintBountyTargetInstructions(int target)
{
    if (!IsClientInGameHuman(target))
    {
        return;
    }

    CPrintToChat(target,
        "%s If an enemy dominates you, they collect the bounty; if you avoid being dominated for {gold}%d minutes{default}, you collect the gems yourself!",
        g_BountyPrefix,
        BOUNTY_PLAYTIME_EXPIRY_SECONDS / 60);
}

void Bounties_OnClientAuthorized(int client)
{
    ResetBountyClientState(client);
}

void Bounties_OnClientDisconnect(int client)
{
    ResetBountyClientState(client);
}

void ResetBountyClientState(int client)
{
    delete g_BountySearchResults[client];
    g_BountySearchResults[client] = null;
    g_BountyPendingSearch[client][0] = '\0';
    g_BountyPendingTargetSteamId[client][0] = '\0';
    g_BountyPendingTargetName[client][0] = '\0';
    g_BountyPendingAmount[client] = 0;
    g_BountyMedicAssistsLife[client] = 0;
    g_BountyPlacementPending[client] = false;
    g_BountySearchGeneration[client]++;
}

void EnsureBountySchema()
{
    if (g_Database == null)
    {
        return;
    }

    char query[4096];
    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "bounty_id BIGINT NOT NULL AUTO_INCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL, "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "target_steamid64 VARCHAR(32) NOT NULL, "
            ... "target_name VARCHAR(128) NOT NULL, "
            ... "amount INT NOT NULL, "
            ... "bonus_amount INT NOT NULL DEFAULT 0, "
            ... "placed_at INT NOT NULL, "
            ... "expires_at INT NOT NULL, "
            ... "qualifying_playtime_seconds INT NOT NULL DEFAULT 0, "
            ... "last_target_playtime_seconds INT NOT NULL DEFAULT 0, "
            ... "halftime_announced TINYINT NOT NULL DEFAULT 0, "
            ... "status VARCHAR(16) NOT NULL DEFAULT 'active', "
            ... "resolved_at INT NOT NULL DEFAULT 0, "
            ... "resolution_token VARCHAR(128) NOT NULL DEFAULT '', "
            ... "claimed_by_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "claimed_by_name VARCHAR(128) NOT NULL DEFAULT '', "
            ... "sender_notified TINYINT NOT NULL DEFAULT 0, "
            ... "target_notified TINYINT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (bounty_id), "
            ... "KEY idx_bounties_active_target (status, target_steamid64, expires_at), "
            ... "KEY idx_bounties_resolution (resolution_token), "
            ... "KEY idx_bounties_notifications (status, sender_notified, target_notified)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            BOUNTY_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "bounty_id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL, "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "target_steamid64 VARCHAR(32) NOT NULL, "
            ... "target_name VARCHAR(128) NOT NULL, "
            ... "amount INTEGER NOT NULL, "
            ... "bonus_amount INTEGER NOT NULL DEFAULT 0, "
            ... "placed_at INTEGER NOT NULL, "
            ... "expires_at INTEGER NOT NULL, "
            ... "qualifying_playtime_seconds INTEGER NOT NULL DEFAULT 0, "
            ... "last_target_playtime_seconds INTEGER NOT NULL DEFAULT 0, "
            ... "halftime_announced INTEGER NOT NULL DEFAULT 0, "
            ... "status VARCHAR(16) NOT NULL DEFAULT 'active', "
            ... "resolved_at INTEGER NOT NULL DEFAULT 0, "
            ... "resolution_token VARCHAR(128) NOT NULL DEFAULT '', "
            ... "claimed_by_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "claimed_by_name VARCHAR(128) NOT NULL DEFAULT '', "
            ... "sender_notified INTEGER NOT NULL DEFAULT 0, "
            ... "target_notified INTEGER NOT NULL DEFAULT 0)"
            , BOUNTY_TABLE);
    }

    g_Database.Query(SQL_OnBountySchemaReady, query);
}

public void SQL_OnBountySchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        g_BountyDatabaseReady = false;
        LogError("[points_store] Bounty schema creation failed: %s", error);
        return;
    }

    g_BountySchemaChecksPending = 4;
    g_BountySchemaCheckFailed = false;
    CheckBountySchemaColumn("bonus_amount", "INTEGER NOT NULL DEFAULT 0");
    CheckBountySchemaColumn("qualifying_playtime_seconds", "INTEGER NOT NULL DEFAULT 0");
    CheckBountySchemaColumn("last_target_playtime_seconds", "INTEGER NOT NULL DEFAULT 0");
    CheckBountySchemaColumn("halftime_announced", "INTEGER NOT NULL DEFAULT 0");
}

void CheckBountySchemaColumn(const char[] column, const char[] definition)
{
    char query[256];
    FormatEx(query, sizeof(query), "SELECT %s FROM %s LIMIT 0", column, BOUNTY_TABLE);

    DataPack pack = new DataPack();
    pack.WriteString(column);
    pack.WriteString(definition);
    g_Database.Query(SQL_OnBountySchemaColumnChecked, query, pack);
}

public void SQL_OnBountySchemaColumnChecked(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    if (error[0] == '\0')
    {
        delete pack;
        FinishBountySchemaColumnCheck(true);
        return;
    }

    pack.Reset();
    char column[64];
    char definition[128];
    pack.ReadString(column, sizeof(column));
    pack.ReadString(definition, sizeof(definition));

    char query[384];
    FormatEx(query, sizeof(query), "ALTER TABLE %s ADD COLUMN %s %s", BOUNTY_TABLE, column, definition);
    g_Database.Query(SQL_OnBountySchemaColumnAdded, query, pack);
}

public void SQL_OnBountySchemaColumnAdded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char column[64];
    pack.ReadString(column, sizeof(column));
    delete pack;

    if (error[0] != '\0')
    {
        LogError("[points_store] Could not add bounty column '%s': %s", column, error);
        FinishBountySchemaColumnCheck(false);
        return;
    }
    FinishBountySchemaColumnCheck(true);
}

void FinishBountySchemaColumnCheck(bool success)
{
    if (!success)
    {
        g_BountySchemaCheckFailed = true;
    }
    g_BountySchemaChecksPending--;
    if (g_BountySchemaChecksPending > 0)
    {
        return;
    }
    if (g_BountySchemaCheckFailed)
    {
        g_BountyDatabaseReady = false;
        return;
    }

    g_BountyDatabaseReady = true;
    if (!g_IsMySql)
    {
        g_Database.Query(SQL_OnIgnoredResult,
            "CREATE INDEX IF NOT EXISTS idx_bounties_active_target ON points_store_bounties (status, target_steamid64, expires_at)");
        g_Database.Query(SQL_OnIgnoredResult,
            "CREATE INDEX IF NOT EXISTS idx_bounties_resolution ON points_store_bounties (resolution_token)");
    }
    ProcessExpiredBounties();
    RequestBountyProgress();
    RequestPendingBountyNotifications();
    RefreshActiveBountyTargets();
}

public Action Timer_BountyMaintenance(Handle timer)
{
    if (g_BountyDatabaseReady)
    {
        ProcessExpiredBounties();
        RequestBountyProgress();
        RequestPendingBountyNotifications();
        RefreshActiveBountyTargets();
    }
    return Plugin_Continue;
}

public Action Command_PlaceBounty(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }
    if (!g_BountyDatabaseReady || g_Database == null)
    {
        CPrintToChat(client, "%s Bounties are temporarily unavailable.", g_BountyPrefix);
        return Plugin_Handled;
    }
    if (!IsBountyPopulationEligible())
    {
        CPrintToChat(client,
            "%s At least {gold}%d{default} connected players are required to place a bounty.",
            g_BountyPrefix,
            GetBountyMinPlayers());
        return Plugin_Handled;
    }
    if (args < 1)
    {
        CPrintToChat(client, "%s Usage: {gold}!bounty playername [amount]", g_BountyPrefix);
        return Plugin_Handled;
    }
    if (!AreBonusPointsReady(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s Your currency balance is still loading.", g_BountyPrefix);
        return Plugin_Handled;
    }
    if (g_BountyPlacementPending[client])
    {
        CPrintToChat(client, "%s Your bounty is still being saved. Try again shortly.", g_BountyPrefix);
        return Plugin_Handled;
    }

    g_BountyPendingSearch[client][0] = '\0';
    g_BountyPendingAmount[client] = 0;

    int searchArgCount = args;
    if (args >= 2)
    {
        char amountText[16];
        int amount;
        GetCmdArg(args, amountText, sizeof(amountText));
        int parsedLength = StringToIntEx(amountText, amount);
        if (parsedLength > 0 && amountText[parsedLength] == '\0')
        {
            if (!IsBountyAmountAllowed(amount))
            {
                CPrintToChat(client,
                    "%s Bounty amount must be between {gold}1 and %d{default}.",
                    g_BountyPrefix,
                    GetBountyMaxAmount());
                return Plugin_Handled;
            }
            if (GetCachedBonusPoints(client) < amount)
            {
                CPrintToChat(client, "%s You do not have enough %s.", g_BountyPrefix, g_CurrencyLongLabel);
                return Plugin_Handled;
            }

            g_BountyPendingAmount[client] = amount;
            searchArgCount--;
        }
    }

    char searchPart[BOUNTY_NAME_MAX];
    for (int i = 1; i <= searchArgCount; i++)
    {
        GetCmdArg(i, searchPart, sizeof(searchPart));
        if (g_BountyPendingSearch[client][0] != '\0')
        {
            StrCat(g_BountyPendingSearch[client], sizeof(g_BountyPendingSearch[]), " ");
        }
        StrCat(g_BountyPendingSearch[client], sizeof(g_BountyPendingSearch[]), searchPart);
    }
    TrimString(g_BountyPendingSearch[client]);
    if (g_BountyPendingSearch[client][0] == '\0')
    {
        CPrintToChat(client, "%s Usage: {gold}!bounty playername [amount]", g_BountyPrefix);
        return Plugin_Handled;
    }

    RequestBountyPlayerSearch(client);
    return Plugin_Handled;
}

bool IsBountyAmountAllowed(int amount)
{
    return amount > 0 && amount <= GetBountyMaxAmount();
}

int GetBountyRankMinimumKillsDeaths()
{
    ConVar convar = FindConVar("sm_whaletracker_rank_min_kd_sum");
    return convar != null ? convar.IntValue : 200;
}

int GetBountyRankMinimumPlaytime()
{
    ConVar convar = FindConVar("sm_whaletracker_rank_min_playtime_seconds");
    return convar != null ? convar.IntValue : 10800;
}

void RequestBountyPlayerSearch(int client)
{
    char escapedSearch[(BOUNTY_NAME_MAX * 2) + 1];
    if (!EscapeSql(g_BountyPendingSearch[client], escapedSearch, sizeof(escapedSearch)))
    {
        CPrintToChat(client, "%s Could not search for that player.", g_BountyPrefix);
        return;
    }

    delete g_BountySearchResults[client];
    g_BountySearchResults[client] = null;
    int generation = ++g_BountySearchGeneration[client];

    char query[2048];
    FormatEx(query, sizeof(query),
        "SELECT w.steamid, "
        ... "COALESCE(NULLIF(pr.newname COLLATE utf8mb4_uca1400_ai_ci, ''), NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid), "
        ... "GREATEST(COALESCE(w.playtime, 0), 0) "
        ... "FROM whaletracker w "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = w.steamid "
        ... "LEFT JOIN prename_rules pr ON pr.pattern COLLATE utf8mb4_uca1400_ai_ci = w.steamid "
        ... "WHERE (GREATEST(COALESCE(w.kills, 0), 0) + GREATEST(COALESCE(w.deaths, 0), 0)) >= %d "
        ... "AND GREATEST(COALESCE(w.playtime, 0), 0) >= %d "
        ... "AND (COALESCE(pr.newname, '') LIKE '%%%s%%' "
        ... "OR COALESCE(fs.last_name, '') LIKE '%%%s%%' "
        ... "OR COALESCE(w.cached_personaname, '') LIKE '%%%s%%') "
        ... "ORDER BY GREATEST(COALESCE(w.playtime, 0), 0) DESC LIMIT %d",
        GetBountyRankMinimumKillsDeaths(),
        GetBountyRankMinimumPlaytime(),
        escapedSearch,
        escapedSearch,
        escapedSearch,
        BOUNTY_SEARCH_MAX);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(generation);
    g_Database.Query(SQL_OnBountyPlayerSearch, query, pack);
}

int FindBountySearchResult(ArrayList results, const char[] steamId)
{
    BountySearchResult entry;
    for (int i = 0; i < results.Length; i++)
    {
        results.GetArray(i, entry, sizeof(entry));
        if (StrEqual(entry.steamId, steamId, false))
        {
            return i;
        }
    }
    return -1;
}

public void SQL_OnBountyPlayerSearch(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (!IsClientInGameHuman(client) || generation != g_BountySearchGeneration[client])
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Bounty player search failed: %s", error);
        CPrintToChat(client, "%s Player search failed.", g_BountyPrefix);
        return;
    }

    ArrayList results = new ArrayList(sizeof(BountySearchResult));
    BountySearchResult entry;
    while (rows != null && rows.FetchRow())
    {
        rows.FetchString(0, entry.steamId, sizeof(entry.steamId));
        rows.FetchString(1, entry.name, sizeof(entry.name));
        entry.playtime = rows.FetchInt(2);
        entry.connected = false;
        results.PushArray(entry, sizeof(entry));
    }

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGameHuman(target))
        {
            continue;
        }

        char steamId[BOUNTY_STEAMID_MAX];
        char currentName[BOUNTY_NAME_MAX];
        if (!GetClientSteamId64(target, steamId, sizeof(steamId)))
        {
            continue;
        }
        GetClientName(target, currentName, sizeof(currentName));

        int index = FindBountySearchResult(results, steamId);
        int rankedHours = 0;
        if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeHours") == FeatureStatus_Available)
        {
            rankedHours = WhaleTracker_GetRankedPlaytimeHours(target);
        }

        if (index == -1)
        {
            if (rankedHours <= 0 || StrContains(currentName, g_BountyPendingSearch[client], false) == -1)
            {
                continue;
            }
            strcopy(entry.steamId, sizeof(entry.steamId), steamId);
            strcopy(entry.name, sizeof(entry.name), currentName);
            entry.playtime = rankedHours * 3600;
            entry.connected = true;
            results.PushArray(entry, sizeof(entry));
            continue;
        }

        results.GetArray(index, entry, sizeof(entry));
        strcopy(entry.name, sizeof(entry.name), currentName);
        entry.connected = true;
        if (rankedHours > 0)
        {
            entry.playtime = rankedHours * 3600;
        }
        results.SetArray(index, entry, sizeof(entry));
    }

    results.SortCustom(SortBountySearchResults);
    g_BountySearchResults[client] = results;
    ShowBountySearchResults(client);
}

public int SortBountySearchResults(int index1, int index2, Handle array, Handle data)
{
    ArrayList results = view_as<ArrayList>(array);
    BountySearchResult left;
    BountySearchResult right;
    results.GetArray(index1, left, sizeof(left));
    results.GetArray(index2, right, sizeof(right));

    if (left.connected != right.connected)
    {
        return left.connected ? -1 : 1;
    }
    if (left.playtime != right.playtime)
    {
        return left.playtime > right.playtime ? -1 : 1;
    }
    return strcmp(left.name, right.name, false);
}

void ShowBountySearchResults(int client)
{
    ArrayList results = g_BountySearchResults[client];
    if (results == null || results.Length == 0)
    {
        CPrintToChat(client, "%s No ranked player matched '{gold}%s{default}'.", g_BountyPrefix, g_BountyPendingSearch[client]);
        return;
    }

    Menu menu = new Menu(MenuHandler_BountySearchResults);
    menu.SetTitle("Place a bounty on:");
    BountySearchResult entry;
    char display[256];
    for (int i = 0; i < results.Length && i < BOUNTY_SEARCH_MAX; i++)
    {
        results.GetArray(i, entry, sizeof(entry));
        FormatEx(display, sizeof(display), "%s%s", entry.name, entry.connected ? " [online]" : "");
        menu.AddItem(entry.steamId, display);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_BountySearchResults(Menu menu, MenuAction action, int client, int item)
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

    char targetSteamId[BOUNTY_STEAMID_MAX];
    menu.GetItem(item, targetSteamId, sizeof(targetSteamId));
    char senderSteamId[BOUNTY_STEAMID_MAX];
    if (!GetClientSteamId64(client, senderSteamId, sizeof(senderSteamId)))
    {
        return 0;
    }
    if (StrEqual(senderSteamId, targetSteamId, false))
    {
        CPrintToChat(client, "%s You cannot place a bounty on yourself.", g_BountyPrefix);
        return 0;
    }

    strcopy(g_BountyPendingTargetSteamId[client], sizeof(g_BountyPendingTargetSteamId[]), targetSteamId);
    strcopy(g_BountyPendingTargetName[client], sizeof(g_BountyPendingTargetName[]), targetSteamId);
    ArrayList results = g_BountySearchResults[client];
    int index = results != null ? FindBountySearchResult(results, targetSteamId) : -1;
    if (index != -1)
    {
        BountySearchResult entry;
        results.GetArray(index, entry, sizeof(entry));
        strcopy(g_BountyPendingTargetName[client], sizeof(g_BountyPendingTargetName[]), entry.name);
    }

    if (g_BountyPendingAmount[client] > 0)
    {
        ShowBountyConsentMenu(client);
    }
    else
    {
        ShowBountyAmountMenu(client);
    }
    return 0;
}

void ShowBountyAmountMenu(int client)
{
    Menu menu = new Menu(MenuHandler_BountyAmount);
    menu.SetTitle("Bounty on %s:", g_BountyPendingTargetName[client]);
    char info[16];
    char display[64];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    for (int i = 0; i < sizeof(g_BountyAmounts); i++)
    {
        if (g_BountyAmounts[i] > GetBountyMaxAmount())
        {
            continue;
        }
        IntToString(g_BountyAmounts[i], info, sizeof(info));
        FormatEx(display, sizeof(display), "%d %s", g_BountyAmounts[i], currencyLong);
        menu.AddItem(info, display);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_BountyAmount(Menu menu, MenuAction action, int client, int item)
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

    char info[16];
    menu.GetItem(item, info, sizeof(info));
    int amount = StringToInt(info);
    if (!IsBountyAmountAllowed(amount) || !AreBonusPointsReady(client) || GetCachedBonusPoints(client) < amount)
    {
        CPrintToChat(client, "%s You do not have enough %s.", g_BountyPrefix, g_CurrencyLongLabel);
        return 0;
    }

    g_BountyPendingAmount[client] = amount;
    ShowBountyConsentMenu(client);
    return 0;
}

void ShowBountyConsentMenu(int client)
{
    char currencyLong[BP_CURRENCY_LONG_MAX];
    char currencyColor[BP_CURRENCY_COLOR_MAX + 2];
    char targetDisplay[256];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    GetCurrencyColorTag(currencyColor, sizeof(currencyColor));

    int target = FindClientBySteamId64(g_BountyPendingTargetSteamId[client]);
    if (target > 0)
    {
        BuildPurchaseDisplayName(target, targetDisplay, sizeof(targetDisplay));
    }
    else
    {
        char colorTag[32];
        if (GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdColorTag") == FeatureStatus_Available
            && Filters_GetSteamIdColorTag(g_BountyPendingTargetSteamId[client], colorTag, sizeof(colorTag))
            && colorTag[0] != '\0')
        {
            FormatEx(targetDisplay, sizeof(targetDisplay), "%s%s{default}", colorTag, g_BountyPendingTargetName[client]);
        }
        else
        {
            FormatEx(targetDisplay, sizeof(targetDisplay), "{gold}%s{default}", g_BountyPendingTargetName[client]);
        }
    }

    CPrintToChatEx(client,
        target > 0 ? target : client,
        "%s Spend %s%d %s{default} to place a bounty on %s?",
        g_BountyPrefix,
        currencyColor,
        g_BountyPendingAmount[client],
        currencyLong,
        targetDisplay);

    Menu menu = new Menu(MenuHandler_BountyConsent);
    menu.SetTitle("Spend %d %s to place a bounty on %s?",
        g_BountyPendingAmount[client],
        currencyLong,
        g_BountyPendingTargetName[client]);
    menu.AddItem("yes", "Yes");
    menu.AddItem("no", "No");
    menu.ExitButton = true;
    menu.Display(client, 20);
}

public int MenuHandler_BountyConsent(Menu menu, MenuAction action, int client, int item)
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

    char info[8];
    menu.GetItem(item, info, sizeof(info));
    if (!StrEqual(info, "yes"))
    {
        return 0;
    }
    if (g_BountyPlacementPending[client])
    {
        CPrintToChat(client, "%s Your bounty is still being saved. Try again shortly.", g_BountyPrefix);
        return 0;
    }
    if (!AreBonusPointsReady(client) || GetCachedBonusPoints(client) < g_BountyPendingAmount[client])
    {
        CPrintToChat(client, "%s You no longer have enough %s.", g_BountyPrefix, g_CurrencyLongLabel);
        return 0;
    }
    if (!IsBountyAmountAllowed(g_BountyPendingAmount[client]))
    {
        CPrintToChat(client,
            "%s The maximum bounty is now {gold}%d{default}. Choose another amount.",
            g_BountyPrefix,
            GetBountyMaxAmount());
        return 0;
    }
    if (!IsBountyPopulationEligible())
    {
        CPrintToChat(client,
            "%s At least {gold}%d{default} connected players are required to place a bounty.",
            g_BountyPrefix,
            GetBountyMinPlayers());
        return 0;
    }

    QueueBountyPlacement(client);
    return 0;
}

void QueueBountyPlacement(int client)
{
    char senderSteamId[BOUNTY_STEAMID_MAX];
    char senderName[BOUNTY_NAME_MAX];
    GetClientName(client, senderName, sizeof(senderName));
    if (!GetClientSteamId64(client, senderSteamId, sizeof(senderSteamId)))
    {
        return;
    }

    int amount = g_BountyPendingAmount[client];
    char escapedSenderSteam[65];
    char escapedSenderName[(BOUNTY_NAME_MAX * 2) + 1];
    char escapedTargetSteam[65];
    char escapedTargetName[(BOUNTY_NAME_MAX * 2) + 1];
    if (amount <= 0
        || !EscapeSql(senderSteamId, escapedSenderSteam, sizeof(escapedSenderSteam))
        || !EscapeSql(senderName, escapedSenderName, sizeof(escapedSenderName))
        || !EscapeSql(g_BountyPendingTargetSteamId[client], escapedTargetSteam, sizeof(escapedTargetSteam))
        || !EscapeSql(g_BountyPendingTargetName[client], escapedTargetName, sizeof(escapedTargetName)))
    {
        CPrintToChat(client, "%s Could not place that bounty.", g_BountyPrefix);
        return;
    }

    int now = GetTime();
    int target = FindClientBySteamId64(g_BountyPendingTargetSteamId[client]);
    int targetPlaytime = 0;
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") == FeatureStatus_Available)
    {
        targetPlaytime = WhaleTracker_GetRankedPlaytimeSeconds(target, g_BountyPendingTargetSteamId[client]);
    }
    Transaction txn = new Transaction();
    char query[2048];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET balance = balance - %d WHERE steamid64 = '%s' AND balance >= %d",
        BP_BALANCE_TABLE,
        amount,
        escapedSenderSteam,
        amount);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "INSERT INTO %s (sender_steamid64, sender_name, target_steamid64, target_name, amount, placed_at, expires_at, "
        ... "qualifying_playtime_seconds, last_target_playtime_seconds, status) "
        ... "SELECT '%s', '%s', '%s', '%s', %d, %d, %d, 0, %d, 'active' WHERE %s = 1",
        BOUNTY_TABLE,
        escapedSenderSteam,
        escapedSenderName,
        escapedTargetSteam,
        escapedTargetName,
        amount,
        now,
        now + BOUNTY_WALL_EXPIRY_SECONDS,
        targetPlaytime,
        g_IsMySql ? "ROW_COUNT()" : "changes()");
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(senderSteamId);
    pack.WriteString(senderName);
    pack.WriteString(g_BountyPendingTargetSteamId[client]);
    pack.WriteString(g_BountyPendingTargetName[client]);
    pack.WriteCell(amount);
    g_BountyPlacementPending[client] = true;
    g_Database.Execute(txn, SQLTxn_OnBountyPlaced, SQLTxn_OnBountyPlacementFailed, pack);
}

public void SQLTxn_OnBountyPlaced(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char senderSteamId[BOUNTY_STEAMID_MAX];
    char senderName[BOUNTY_NAME_MAX];
    char targetSteamId[BOUNTY_STEAMID_MAX];
    char targetName[BOUNTY_NAME_MAX];
    pack.ReadString(senderSteamId, sizeof(senderSteamId));
    pack.ReadString(senderName, sizeof(senderName));
    pack.ReadString(targetSteamId, sizeof(targetSteamId));
    pack.ReadString(targetName, sizeof(targetName));
    int amount = pack.ReadCell();
    delete pack;

    bool placed = numQueries >= 2 && results[1] != null && results[1].AffectedRows > 0;
    if (client > 0)
    {
        g_BountyPlacementPending[client] = false;
    }
    if (!placed)
    {
        if (IsClientInGameHuman(client))
        {
            LoadClientBonusPoints(client);
            CPrintToChat(client, "%s You no longer have enough %s for that bounty.", g_BountyPrefix, g_CurrencyLongLabel);
        }
        return;
    }

    MarkActiveBountyTarget(targetSteamId);

    if (IsClientInGameHuman(client))
    {
        char currentSteamId[BOUNTY_STEAMID_MAX];
        if (GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId))
            && StrEqual(currentSteamId, senderSteamId, false)
            && g_ClientBonusPointsLoaded[client])
        {
            int balanceBefore = g_ClientBonusPoints[client];
            g_ClientBonusPoints[client] -= amount;
            if (g_ClientBonusPoints[client] < 0)
            {
                g_ClientBonusPoints[client] = 0;
            }
            LogBonusPointsDelta(client, -amount, balanceBefore, g_ClientBonusPoints[client], "bounty_escrow", 0, false, false, 1.0, true, 0, 0);
        }
    }

    int target = FindClientBySteamId64(targetSteamId);
    char senderDisplay[256];
    char targetDisplay[256];
    if (IsClientInGameHuman(client))
    {
        BuildPurchaseDisplayName(client, senderDisplay, sizeof(senderDisplay));
    }
    else
    {
        strcopy(senderDisplay, sizeof(senderDisplay), senderName);
    }
    if (target > 0)
    {
        BuildPurchaseDisplayName(target, targetDisplay, sizeof(targetDisplay));
    }
    else
    {
        strcopy(targetDisplay, sizeof(targetDisplay), targetName);
    }

    char currencyColor[BP_CURRENCY_COLOR_MAX + 2];
    char currencyName[BP_CURRENCY_SHORT_MAX];
    GetCurrencyColorTag(currencyColor, sizeof(currencyColor));
    GetCurrencyShortLabelForAmount(amount, currencyName, sizeof(currencyName));
    for (int recipient = 1; recipient <= MaxClients; recipient++)
    {
        if (IsClientInGameHuman(recipient))
        {
            CPrintToChatEx(recipient, IsClientInGameHuman(client) ? client : recipient,
                "%s %s placed a %s%d %s{default} bounty on %s! Dominate him to get the gems!",
                g_BountyPrefix,
                senderDisplay,
                currencyColor,
                amount,
                currencyName,
                targetDisplay);
        }
    }
    PlayBountySaySound(BOUNTY_CHALLENGE_SOUND);
    PrintBountyTargetInstructions(target);

    LogPointsStoreEvent(
        "event=bounty_placed|time=%d|sender=%s|target=%s|amount=%d|expires_at=%d",
        GetTime(), senderSteamId, targetSteamId, amount, GetTime() + BOUNTY_WALL_EXPIRY_SECONDS);
}

public void SQLTxn_OnBountyPlacementFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    delete pack;
    if (client > 0)
    {
        g_BountyPlacementPending[client] = false;
    }
    LogError("[points_store] Bounty placement failed at query %d: %s", failIndex, error);
    if (IsClientInGameHuman(client))
    {
        LoadClientBonusPoints(client);
        CPrintToChat(client, "%s Could not place that bounty.", g_BountyPrefix);
    }
}

public Action Command_ShowBounties(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }
    if (!g_BountyDatabaseReady || g_Database == null)
    {
        CPrintToChat(client, "%s Bounties are temporarily unavailable.", g_BountyPrefix);
        return Plugin_Handled;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT target_steamid64, MAX(target_name), SUM(amount + bonus_amount) AS total_amount "
        ... "FROM %s WHERE status = 'active' AND expires_at > %d "
        ... "GROUP BY target_steamid64 ORDER BY total_amount DESC, MAX(target_name) ASC LIMIT 100",
        BOUNTY_TABLE,
        GetTime());
    g_Database.Query(SQL_OnBountyListLoaded, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnBountyListLoaded(Database db, DBResultSet rows, const char[] error, any userId)
{
    int client = GetClientOfUserId(userId);
    if (!IsClientInGameHuman(client))
    {
        return;
    }
    if (error[0] != '\0')
    {
        LogError("[points_store] Bounty list failed: %s", error);
        CPrintToChat(client, "%s Failed to load bounties.", g_BountyPrefix);
        return;
    }

    Menu menu = new Menu(MenuHandler_BountyList);
    menu.SetTitle("Bounties");
    char steamId[BOUNTY_STEAMID_MAX];
    char name[BOUNTY_NAME_MAX];
    char display[256];
    char currencyLong[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyLong, sizeof(currencyLong));
    int count = 0;
    while (rows != null && rows.FetchRow())
    {
        rows.FetchString(0, steamId, sizeof(steamId));
        rows.FetchString(1, name, sizeof(name));
        int amount = rows.FetchInt(2);
        int target = FindClientBySteamId64(steamId);
        if (target > 0)
        {
            GetClientName(target, name, sizeof(name));
        }
        FormatEx(display, sizeof(display), "%s (%d %s)", name, amount, currencyLong);
        menu.AddItem(steamId, display, ITEMDRAW_DISABLED);
        count++;
    }
    if (count == 0)
    {
        menu.AddItem("none", "No active bounties", ITEMDRAW_DISABLED);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_BountyList(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

void MarkActiveBountyTarget(const char[] steamId)
{
    if (g_ActiveBountyTargets == null)
    {
        g_ActiveBountyTargets = new StringMap();
    }

    int existingMarker;
    bool wasActive = g_ActiveBountyTargets.GetValue(steamId, existingMarker);
    g_BountyTargetCacheGeneration++;
    g_ActiveBountyTargets.SetValue(steamId, 1, true);
    if (!wasActive)
    {
        int target = FindClientBySteamId64(steamId);
        if (target > 0)
        {
            g_BountyMedicAssistsLife[target] = 0;
        }
    }
}

void RefreshActiveBountyTargets()
{
    if (!g_BountyDatabaseReady || g_Database == null)
    {
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT DISTINCT target_steamid64 FROM %s WHERE status = 'active' AND expires_at > %d",
        BOUNTY_TABLE,
        GetTime());

    g_BountyTargetCacheGeneration++;
    g_Database.Query(SQL_OnActiveBountyTargetsLoaded, query, g_BountyTargetCacheGeneration);
}

public void SQL_OnActiveBountyTargetsLoaded(Database db, DBResultSet rows, const char[] error, any generation)
{
    if (error[0] != '\0')
    {
        LogError("[points_store] Active bounty target cache refresh failed: %s", error);
        return;
    }
    if (generation != g_BountyTargetCacheGeneration)
    {
        return;
    }

    StringMap refreshedTargets = new StringMap();
    char steamId[BOUNTY_STEAMID_MAX];
    while (rows != null && rows.FetchRow())
    {
        rows.FetchString(0, steamId, sizeof(steamId));
        refreshedTargets.SetValue(steamId, 1, true);
    }

    delete g_ActiveBountyTargets;
    g_ActiveBountyTargets = refreshedTargets;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGameHuman(client) && !IsClientActiveBountyTarget(client))
        {
            g_BountyMedicAssistsLife[client] = 0;
        }
    }
}

public void Event_BountyPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int deathFlags = event.GetInt("death_flags");
    if (deathFlags & TF_DEATHFLAG_DEADRINGER)
    {
        return;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int assister = GetClientOfUserId(event.GetInt("assister"));

    if (IsClientInGameHuman(victim))
    {
        g_BountyMedicAssistsLife[victim] = 0;
    }

    if (IsClientInGameHuman(assister) && assister != victim)
    {
        if (TF2_GetPlayerClass(assister) == TFClass_Medic && IsClientActiveBountyTarget(assister))
        {
            g_BountyMedicAssistsLife[assister]++;
            if (g_BountyMedicAssistsLife[assister] >= BOUNTY_MEDIC_ASSISTS_PER_GROWTH)
            {
                g_BountyMedicAssistsLife[assister] -= BOUNTY_MEDIC_ASSISTS_PER_GROWTH;
                GrowActiveBountiesForKill(assister, true);
            }
        }
        else
        {
            g_BountyMedicAssistsLife[assister] = 0;
        }
    }

    if (!IsClientInGameHuman(attacker) || !IsClientInGameHuman(victim) || attacker == victim)
    {
        return;
    }

    if (IsPlayerAlive(attacker))
    {
        GrowActiveBountiesForKill(attacker, false);
    }

    if (deathFlags & TF_DEATHFLAG_KILLERDOMINATION)
    {
        ClaimBountiesForDomination(attacker, victim);
    }
}

bool IsClientActiveBountyTarget(int client)
{
    if (g_ActiveBountyTargets == null)
    {
        return false;
    }

    char steamId[BOUNTY_STEAMID_MAX];
    int cacheMarker;
    return GetClientSteamId64(client, steamId, sizeof(steamId))
        && g_ActiveBountyTargets.GetValue(steamId, cacheMarker);
}

void GrowActiveBountiesForKill(int attacker, bool fromMedicAssists)
{
    if (!g_BountyDatabaseReady || g_Database == null)
    {
        return;
    }

    char attackerSteamId[BOUNTY_STEAMID_MAX];
    char escapedAttackerSteam[65];
    if (!GetClientSteamId64(attacker, attackerSteamId, sizeof(attackerSteamId))
        || !EscapeSql(attackerSteamId, escapedAttackerSteam, sizeof(escapedAttackerSteam)))
    {
        return;
    }

    int cacheMarker;
    if (g_ActiveBountyTargets == null || !g_ActiveBountyTargets.GetValue(attackerSteamId, cacheMarker))
    {
        return;
    }

    int maxAmount = GetBountyMaxAmount();
    char query[768];
    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s SET bonus_amount = LEAST(%d - amount, bonus_amount + GREATEST(1, FLOOR(amount * %d / 100))) "
            ... "WHERE target_steamid64 = '%s' AND status = 'active' AND expires_at > %d "
            ... "AND amount < %d AND amount + bonus_amount < %d",
            BOUNTY_TABLE,
            maxAmount,
            BOUNTY_KILL_GROWTH_PERCENT,
            escapedAttackerSteam,
            GetTime(),
            maxAmount,
            maxAmount);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s SET bonus_amount = MIN(%d - amount, bonus_amount + MAX(1, (amount * %d / 100))) "
            ... "WHERE target_steamid64 = '%s' AND status = 'active' AND expires_at > %d "
            ... "AND amount < %d AND amount + bonus_amount < %d",
            BOUNTY_TABLE,
            maxAmount,
            BOUNTY_KILL_GROWTH_PERCENT,
            escapedAttackerSteam,
            GetTime(),
            maxAmount,
            maxAmount);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteString(attackerSteamId);
    pack.WriteCell(fromMedicAssists);
    g_Database.Query(SQL_OnBountyKillGrowth, query, pack);
}

public void SQL_OnBountyKillGrowth(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int attacker = GetClientOfUserId(pack.ReadCell());
    char attackerSteamId[BOUNTY_STEAMID_MAX];
    pack.ReadString(attackerSteamId, sizeof(attackerSteamId));
    bool fromMedicAssists = pack.ReadCell() != 0;
    delete pack;

    if (error[0] != '\0')
    {
        LogError("[points_store] Bounty kill growth failed: %s", error);
        return;
    }

    int bountyCount = results != null ? results.AffectedRows : 0;
    if (bountyCount > 0)
    {
        LogPointsStoreEvent(
            "event=bounty_kill_growth|time=%d|target=%s|client=%d|bounties=%d|growth_percent=%d|source=%s",
            GetTime(), attackerSteamId, attacker, bountyCount, BOUNTY_KILL_GROWTH_PERCENT,
            fromMedicAssists ? "medic_assists" : "kill");
    }
}

void BuildBountyOperationToken(const char[] prefix, char[] buffer, int maxlen)
{
    ConVar hostPort = FindConVar("hostport");
    int port = hostPort != null ? hostPort.IntValue : 0;
    g_BountyOperationSerial++;
    FormatEx(buffer, maxlen, "%s_%d_%d_%d_%d", prefix, GetTime(), port, g_BountyOperationSerial, GetRandomInt(1000, 999999));
}

void PlayBountySaySound(const char[] command)
{
    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") == FeatureStatus_Available)
    {
        SaySounds_PlayCommand(0, command, true);
    }
}

void ClaimBountiesForDomination(int attacker, int victim)
{
    if (!g_BountyDatabaseReady || g_Database == null)
    {
        return;
    }

    char attackerSteamId[BOUNTY_STEAMID_MAX];
    char victimSteamId[BOUNTY_STEAMID_MAX];
    char attackerName[BOUNTY_NAME_MAX];
    char victimName[BOUNTY_NAME_MAX];
    GetClientName(attacker, attackerName, sizeof(attackerName));
    GetClientName(victim, victimName, sizeof(victimName));
    if (!GetClientSteamId64(attacker, attackerSteamId, sizeof(attackerSteamId))
        || !GetClientSteamId64(victim, victimSteamId, sizeof(victimSteamId)))
    {
        return;
    }

    char token[BOUNTY_TOKEN_MAX];
    BuildBountyOperationToken("claim", token, sizeof(token));
    char escapedToken[(BOUNTY_TOKEN_MAX * 2) + 1];
    char escapedAttackerSteam[65];
    char escapedAttackerName[(BOUNTY_NAME_MAX * 2) + 1];
    char escapedVictimSteam[65];
    if (!EscapeSql(token, escapedToken, sizeof(escapedToken))
        || !EscapeSql(attackerSteamId, escapedAttackerSteam, sizeof(escapedAttackerSteam))
        || !EscapeSql(attackerName, escapedAttackerName, sizeof(escapedAttackerName))
        || !EscapeSql(victimSteamId, escapedVictimSteam, sizeof(escapedVictimSteam)))
    {
        return;
    }

    int now = GetTime();
    Transaction txn = new Transaction();
    char query[2048];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET status = 'claimed', resolved_at = %d, resolution_token = '%s', "
        ... "claimed_by_steamid64 = '%s', claimed_by_name = '%s' "
        ... "WHERE target_steamid64 = '%s' AND status = 'active' AND expires_at > %d",
        BOUNTY_TABLE,
        now,
        escapedToken,
        escapedAttackerSteam,
        escapedAttackerName,
        escapedVictimSteam,
        now);
    txn.AddQuery(query);

    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT '%s', SUM(amount + bonus_amount) FROM %s WHERE resolution_token = '%s' HAVING SUM(amount + bonus_amount) > 0 "
            ... "ON DUPLICATE KEY UPDATE balance = balance + VALUES(balance)",
            BP_BALANCE_TABLE,
            escapedAttackerSteam,
            BOUNTY_TABLE,
            escapedToken);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT '%s', SUM(amount + bonus_amount) FROM %s WHERE resolution_token = '%s' HAVING SUM(amount + bonus_amount) > 0 "
            ... "ON CONFLICT(steamid64) DO UPDATE SET balance = balance + excluded.balance",
            BP_BALANCE_TABLE,
            escapedAttackerSteam,
            BOUNTY_TABLE,
            escapedToken);
    }
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "SELECT COALESCE(SUM(amount + bonus_amount), 0) FROM %s WHERE resolution_token = '%s'",
        BOUNTY_TABLE,
        escapedToken);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteString(attackerSteamId);
    pack.WriteString(attackerName);
    pack.WriteString(victimSteamId);
    pack.WriteString(victimName);
    pack.WriteString(token);
    g_Database.Execute(txn, SQLTxn_OnBountyClaimed, SQLTxn_OnBountyClaimFailed, pack);
}

public void SQLTxn_OnBountyClaimed(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int attacker = GetClientOfUserId(pack.ReadCell());
    char attackerSteamId[BOUNTY_STEAMID_MAX];
    char attackerName[BOUNTY_NAME_MAX];
    char victimSteamId[BOUNTY_STEAMID_MAX];
    char victimName[BOUNTY_NAME_MAX];
    char token[BOUNTY_TOKEN_MAX];
    pack.ReadString(attackerSteamId, sizeof(attackerSteamId));
    pack.ReadString(attackerName, sizeof(attackerName));
    pack.ReadString(victimSteamId, sizeof(victimSteamId));
    pack.ReadString(victimName, sizeof(victimName));
    pack.ReadString(token, sizeof(token));
    delete pack;

    int amount = 0;
    if (numQueries >= 3 && results[2] != null && results[2].FetchRow())
    {
        amount = results[2].FetchInt(0);
    }
    if (amount <= 0)
    {
        return;
    }

    RefreshActiveBountyTargets();

    if (IsClientInGameHuman(attacker))
    {
        char currentSteamId[BOUNTY_STEAMID_MAX];
        if (GetClientSteamId64(attacker, currentSteamId, sizeof(currentSteamId))
            && StrEqual(currentSteamId, attackerSteamId, false)
            && g_ClientBonusPointsLoaded[attacker])
        {
            int balanceBefore = g_ClientBonusPoints[attacker];
            g_ClientBonusPoints[attacker] += amount;
            LogBonusPointsDelta(attacker, amount, balanceBefore, g_ClientBonusPoints[attacker], "bounty_claim", 0, true, true, 1.0, true, 0, 0);
        }
        PlayBonusPointsSound(attacker, true);
    }

    char attackerDisplay[256];
    char victimDisplay[256];
    if (IsClientInGameHuman(attacker))
    {
        BuildPurchaseDisplayName(attacker, attackerDisplay, sizeof(attackerDisplay));
    }
    else
    {
        strcopy(attackerDisplay, sizeof(attackerDisplay), attackerName);
    }
    int victim = FindClientBySteamId64(victimSteamId);
    if (victim > 0)
    {
        BuildPurchaseDisplayName(victim, victimDisplay, sizeof(victimDisplay));
    }
    else
    {
        strcopy(victimDisplay, sizeof(victimDisplay), victimName);
    }

    char currencyColor[BP_CURRENCY_COLOR_MAX + 2];
    char currencyName[BP_CURRENCY_SHORT_MAX];
    GetCurrencyColorTag(currencyColor, sizeof(currencyColor));
    GetCurrencyShortLabelForAmount(amount, currencyName, sizeof(currencyName));
    for (int recipient = 1; recipient <= MaxClients; recipient++)
    {
        if (IsClientInGameHuman(recipient))
        {
            CPrintToChatEx(recipient, IsClientInGameHuman(attacker) ? attacker : recipient,
                "%s %s received %s%d %s{default} for dominating %s!",
                g_BountyPrefix,
                attackerDisplay,
                currencyColor,
                amount,
                currencyName,
                victimDisplay);
        }
    }
    PlayBountySaySound(BOUNTY_EVENT_SOUND);

    LogPointsStoreEvent(
        "event=bounty_claimed|time=%d|claimant=%s|target=%s|amount=%d|token=%s",
        GetTime(), attackerSteamId, victimSteamId, amount, token);
    RequestPendingBountyNotifications();
}

public void SQLTxn_OnBountyClaimFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    delete pack;
    LogError("[points_store] Bounty claim failed at query %d: %s", failIndex, error);
}

void ProcessExpiredBounties()
{
    if (!g_BountyDatabaseReady || g_Database == null || g_BountyExpiryPending)
    {
        return;
    }

    char token[BOUNTY_TOKEN_MAX];
    BuildBountyOperationToken("expire", token, sizeof(token));
    char escapedToken[(BOUNTY_TOKEN_MAX * 2) + 1];
    if (!EscapeSql(token, escapedToken, sizeof(escapedToken)))
    {
        return;
    }

    int now = GetTime();
    Transaction txn = new Transaction();
    char query[2048];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET status = 'expired', resolved_at = %d, resolution_token = '%s' "
        ... "WHERE status = 'active' AND expires_at <= %d",
        BOUNTY_TABLE,
        now,
        escapedToken,
        now);
    txn.AddQuery(query);

    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT sender_steamid64, SUM(amount) FROM %s WHERE resolution_token = '%s' AND sender_steamid64 != '%s' GROUP BY sender_steamid64 "
            ... "ON DUPLICATE KEY UPDATE balance = balance + VALUES(balance)",
            BP_BALANCE_TABLE,
            BOUNTY_TABLE,
            escapedToken,
            BOUNTY_SYSTEM_STEAMID);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT sender_steamid64, SUM(amount) FROM %s WHERE resolution_token = '%s' AND sender_steamid64 != '%s' GROUP BY sender_steamid64 "
            ... "ON CONFLICT(steamid64) DO UPDATE SET balance = balance + excluded.balance",
            BP_BALANCE_TABLE,
            BOUNTY_TABLE,
            escapedToken,
            BOUNTY_SYSTEM_STEAMID);
    }
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "SELECT sender_steamid64, MAX(sender_name), target_steamid64, MAX(target_name), amount "
        ... "FROM %s WHERE resolution_token = '%s' "
        ... "GROUP BY bounty_id, sender_steamid64, target_steamid64, amount ORDER BY bounty_id",
        BOUNTY_TABLE,
        escapedToken);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteString(token);
    g_BountyExpiryPending = true;
    g_Database.Execute(txn, SQLTxn_OnBountiesExpired, SQLTxn_OnBountyExpiryFailed, pack);
}

public void SQLTxn_OnBountiesExpired(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char token[BOUNTY_TOKEN_MAX];
    pack.ReadString(token, sizeof(token));
    delete pack;
    g_BountyExpiryPending = false;

    int totalRefunded = 0;
    int expiredCount = 0;
    if (numQueries >= 3 && results[2] != null)
    {
        char senderSteamId[BOUNTY_STEAMID_MAX];
        char senderName[BOUNTY_NAME_MAX];
        char targetSteamId[BOUNTY_STEAMID_MAX];
        char targetName[BOUNTY_NAME_MAX];
        while (results[2].FetchRow())
        {
            results[2].FetchString(0, senderSteamId, sizeof(senderSteamId));
            results[2].FetchString(1, senderName, sizeof(senderName));
            results[2].FetchString(2, targetSteamId, sizeof(targetSteamId));
            results[2].FetchString(3, targetName, sizeof(targetName));
            int amount = results[2].FetchInt(4);
            bool systemBounty = StrEqual(senderSteamId, BOUNTY_SYSTEM_STEAMID, false);
            expiredCount++;
            if (!systemBounty)
            {
                totalRefunded += amount;
            }
            int sender = FindClientBySteamId64(senderSteamId);
            if (!systemBounty && sender > 0 && g_ClientBonusPointsLoaded[sender])
            {
                int balanceBefore = g_ClientBonusPoints[sender];
                g_ClientBonusPoints[sender] += amount;
                LogBonusPointsDelta(sender, amount, balanceBefore, g_ClientBonusPoints[sender], "bounty_week_refund", 0, false, false, 1.0, true, 0, 0);
            }

            char senderDisplay[256];
            char targetDisplay[256];
            BuildBountyDisplayName(senderSteamId, senderName, senderDisplay, sizeof(senderDisplay));
            BuildBountyDisplayName(targetSteamId, targetName, targetDisplay, sizeof(targetDisplay));
            for (int recipient = 1; recipient <= MaxClients; recipient++)
            {
                if (IsClientInGameHuman(recipient))
                {
                    CPrintToChatEx(recipient, sender > 0 ? sender : recipient,
                        "%s %s's bounty on %s expired due to one week without resolution!",
                        g_BountyPrefix,
                        senderDisplay,
                        targetDisplay);
                }
            }
        }
    }
    if (expiredCount > 0)
    {
        LogPointsStoreEvent(
            "event=bounty_expired|time=%d|refund_total=%d|token=%s",
            GetTime(), totalRefunded, token);
        PlayBountySaySound(BOUNTY_EVENT_SOUND);
        RequestPendingBountyNotifications();
        RefreshActiveBountyTargets();
    }
}

public void SQLTxn_OnBountyExpiryFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    delete pack;
    g_BountyExpiryPending = false;
    LogError("[points_store] Bounty expiry failed at query %d: %s", failIndex, error);
}

void BuildBountyDisplayName(const char[] steamId, const char[] fallbackName, char[] buffer, int maxlen)
{
    int client = FindClientBySteamId64(steamId);
    if (client > 0)
    {
        BuildPurchaseDisplayName(client, buffer, maxlen);
        return;
    }

    char colorTag[32];
    if (GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdColorTag") == FeatureStatus_Available
        && Filters_GetSteamIdColorTag(steamId, colorTag, sizeof(colorTag))
        && colorTag[0] != '\0')
    {
        FormatEx(buffer, maxlen, "%s%s{default}", colorTag, fallbackName);
        return;
    }
    strcopy(buffer, maxlen, fallbackName);
}

void RequestBountyProgress()
{
    if (!g_BountyDatabaseReady || g_Database == null || g_BountyProgressPending)
    {
        return;
    }
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") != FeatureStatus_Available)
    {
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT DISTINCT target_steamid64 FROM %s WHERE status = 'active' AND expires_at > %d",
        BOUNTY_TABLE,
        GetTime());
    g_BountyProgressPending = true;
    g_Database.Query(SQL_OnBountyProgressTargetsLoaded, query);
}

public void SQL_OnBountyProgressTargetsLoaded(Database db, DBResultSet rows, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        g_BountyProgressPending = false;
        LogError("[points_store] Bounty progress target query failed: %s", error);
        return;
    }

    bool countPlaytime = IsBountyPopulationEligible();
    int now = GetTime();
    int updateCount = 0;
    Transaction txn = new Transaction();
    char targetSteamId[BOUNTY_STEAMID_MAX];
    char escapedTargetSteam[65];
    char query[2048];
    while (rows != null && rows.FetchRow())
    {
        rows.FetchString(0, targetSteamId, sizeof(targetSteamId));
        int target = FindClientBySteamId64(targetSteamId);
        if (!IsClientInGameHuman(target))
        {
            continue;
        }

        int currentPlaytime = WhaleTracker_GetRankedPlaytimeSeconds(target);
        if (currentPlaytime <= 0 || !EscapeSql(targetSteamId, escapedTargetSteam, sizeof(escapedTargetSteam)))
        {
            continue;
        }

        if (g_IsMySql)
        {
            FormatEx(query, sizeof(query),
                "UPDATE %s SET qualifying_playtime_seconds = LEAST(%d, qualifying_playtime_seconds + "
                ... "IF(%d = 1 AND last_target_playtime_seconds > 0 AND %d >= last_target_playtime_seconds, "
                ... "%d - last_target_playtime_seconds, 0)), last_target_playtime_seconds = %d "
                ... "WHERE target_steamid64 = '%s' AND status = 'active' AND expires_at > %d",
                BOUNTY_TABLE,
                BOUNTY_PLAYTIME_EXPIRY_SECONDS,
                countPlaytime ? 1 : 0,
                currentPlaytime,
                currentPlaytime,
                currentPlaytime,
                escapedTargetSteam,
                now);
        }
        else
        {
            FormatEx(query, sizeof(query),
                "UPDATE %s SET qualifying_playtime_seconds = MIN(%d, qualifying_playtime_seconds + "
                ... "CASE WHEN %d = 1 AND last_target_playtime_seconds > 0 AND %d >= last_target_playtime_seconds "
                ... "THEN %d - last_target_playtime_seconds ELSE 0 END), last_target_playtime_seconds = %d "
                ... "WHERE target_steamid64 = '%s' AND status = 'active' AND expires_at > %d",
                BOUNTY_TABLE,
                BOUNTY_PLAYTIME_EXPIRY_SECONDS,
                countPlaytime ? 1 : 0,
                currentPlaytime,
                currentPlaytime,
                currentPlaytime,
                escapedTargetSteam,
                now);
        }
        txn.AddQuery(query);
        updateCount++;
    }

    if (updateCount == 0)
    {
        delete txn;
        g_BountyProgressPending = false;
        return;
    }

    char token[BOUNTY_TOKEN_MAX];
    char escapedToken[(BOUNTY_TOKEN_MAX * 2) + 1];
    BuildBountyOperationToken("survived", token, sizeof(token));
    if (!EscapeSql(token, escapedToken, sizeof(escapedToken)))
    {
        delete txn;
        g_BountyProgressPending = false;
        return;
    }

    FormatEx(query, sizeof(query),
        "UPDATE %s SET halftime_announced = 2 "
        ... "WHERE status = 'active' AND expires_at > %d AND halftime_announced = 0 "
        ... "AND qualifying_playtime_seconds >= %d",
        BOUNTY_TABLE,
        now,
        BOUNTY_HALFTIME_SECONDS);
    txn.AddQuery(query);

    int halftimeQueryIndex = updateCount + 1;
    FormatEx(query, sizeof(query),
        "SELECT amount + bonus_amount, target_steamid64, target_name FROM %s "
        ... "WHERE status = 'active' AND halftime_announced = 2 ORDER BY bounty_id",
        BOUNTY_TABLE);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "UPDATE %s SET halftime_announced = 1 WHERE halftime_announced = 2",
        BOUNTY_TABLE);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "UPDATE %s SET status = 'survived', resolved_at = %d, resolution_token = '%s', target_notified = 1 "
        ... "WHERE status = 'active' AND expires_at > %d AND qualifying_playtime_seconds >= %d",
        BOUNTY_TABLE,
        now,
        escapedToken,
        now,
        BOUNTY_PLAYTIME_EXPIRY_SECONDS);
    txn.AddQuery(query);

    if (g_IsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT target_steamid64, SUM(amount + bonus_amount) FROM %s "
            ... "WHERE resolution_token = '%s' GROUP BY target_steamid64 "
            ... "ON DUPLICATE KEY UPDATE balance = balance + VALUES(balance)",
            BP_BALANCE_TABLE,
            BOUNTY_TABLE,
            escapedToken);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s (steamid64, balance) "
            ... "SELECT target_steamid64, SUM(amount + bonus_amount) FROM %s "
            ... "WHERE resolution_token = '%s' GROUP BY target_steamid64 "
            ... "ON CONFLICT(steamid64) DO UPDATE SET balance = balance + excluded.balance",
            BP_BALANCE_TABLE,
            BOUNTY_TABLE,
            escapedToken);
    }
    txn.AddQuery(query);

    int summaryQueryIndex = updateCount + 5;
    FormatEx(query, sizeof(query),
        "SELECT target_steamid64, MAX(target_name), SUM(amount + bonus_amount) "
        ... "FROM %s WHERE resolution_token = '%s' GROUP BY target_steamid64",
        BOUNTY_TABLE,
        escapedToken);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteString(token);
    pack.WriteCell(halftimeQueryIndex);
    pack.WriteCell(summaryQueryIndex);
    g_Database.Execute(txn, SQLTxn_OnBountiesSurvived, SQLTxn_OnBountyProgressFailed, pack);
}

public void SQLTxn_OnBountiesSurvived(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char token[BOUNTY_TOKEN_MAX];
    pack.ReadString(token, sizeof(token));
    int halftimeQueryIndex = pack.ReadCell();
    int summaryQueryIndex = pack.ReadCell();
    delete pack;
    g_BountyProgressPending = false;

    if (halftimeQueryIndex < numQueries && results[halftimeQueryIndex] != null)
    {
        char targetSteamId[BOUNTY_STEAMID_MAX];
        char targetName[BOUNTY_NAME_MAX];
        char targetDisplay[256];
        char currencyName[BP_CURRENCY_SHORT_MAX];
        while (results[halftimeQueryIndex].FetchRow())
        {
            int amount = results[halftimeQueryIndex].FetchInt(0);
            results[halftimeQueryIndex].FetchString(1, targetSteamId, sizeof(targetSteamId));
            results[halftimeQueryIndex].FetchString(2, targetName, sizeof(targetName));
            BuildBountyDisplayName(targetSteamId, targetName, targetDisplay, sizeof(targetDisplay));
            GetCurrencyShortLabelForAmount(amount, currencyName, sizeof(currencyName));

            int target = FindClientBySteamId64(targetSteamId);
            for (int recipient = 1; recipient <= MaxClients; recipient++)
            {
                if (IsClientInGameHuman(recipient))
                {
                    CPrintToChatEx(recipient, target > 0 ? target : recipient,
                        "%s %s's bounty is now %s%d %s{default} and expires in {gold}%d minutes{default}!",
                        g_BountyPrefix,
                        targetDisplay,
                        g_CurrencyColorTag,
                        amount,
                        currencyName,
                        BOUNTY_HALFTIME_REMAINING_MINUTES);
                }
            }
            LogPointsStoreEvent(
                "event=bounty_halftime|time=%d|target=%s|amount=%d",
                GetTime(), targetSteamId, amount);
        }
    }

    bool resolvedAny = false;
    if (summaryQueryIndex < numQueries && results[summaryQueryIndex] != null)
    {
        char targetSteamId[BOUNTY_STEAMID_MAX];
        char targetName[BOUNTY_NAME_MAX];
        while (results[summaryQueryIndex].FetchRow())
        {
            results[summaryQueryIndex].FetchString(0, targetSteamId, sizeof(targetSteamId));
            results[summaryQueryIndex].FetchString(1, targetName, sizeof(targetName));
            int payout = results[summaryQueryIndex].FetchInt(2);
            resolvedAny = true;

            int target = FindClientBySteamId64(targetSteamId);
            if (target > 0 && g_ClientBonusPointsLoaded[target])
            {
                int balanceBefore = g_ClientBonusPoints[target];
                g_ClientBonusPoints[target] += payout;
                LogBonusPointsDelta(target, payout, balanceBefore, g_ClientBonusPoints[target], "bounty_survived", 0, true, true, 1.0, true, 0, 0);
                PlayLevelUpSound(target);
            }

            char targetDisplay[256];
            BuildBountyDisplayName(targetSteamId, targetName, targetDisplay, sizeof(targetDisplay));
            char currencyName[BP_CURRENCY_SHORT_MAX];
            GetCurrencyShortLabelForAmount(payout, currencyName, sizeof(currencyName));
            for (int recipient = 1; recipient <= MaxClients; recipient++)
            {
                if (IsClientInGameHuman(recipient))
                {
                    CPrintToChatEx(recipient, target > 0 ? target : recipient,
                        "%s %s received %s%d %s{default} for surviving a bounty hunt!",
                        g_BountyPrefix,
                        targetDisplay,
                        g_CurrencyColorTag,
                        payout,
                        currencyName);
                }
            }

            LogPointsStoreEvent(
                "event=bounty_survived|time=%d|target=%s|payout=%d|token=%s",
                GetTime(), targetSteamId, payout, token);
        }
    }

    if (resolvedAny)
    {
        PlayBountySaySound(BOUNTY_EVENT_SOUND);
        RequestPendingBountyNotifications();
        RefreshActiveBountyTargets();
    }
}

public void SQLTxn_OnBountyProgressFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    delete pack;
    g_BountyProgressPending = false;
    LogError("[points_store] Bounty progress failed at query %d: %s", failIndex, error);
}

bool IsBountyMailAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "ServerMail_SendCustomSteamId") == FeatureStatus_Available;
}

void RequestPendingBountyNotifications()
{
    if (!g_BountyDatabaseReady || g_Database == null || g_BountyNotificationQueryPending || !IsBountyMailAvailable())
    {
        return;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT bounty_id, status, sender_steamid64, sender_name, target_steamid64, target_name, amount, bonus_amount, "
        ... "claimed_by_name, sender_notified, target_notified FROM %s "
        ... "WHERE (status = 'claimed' AND sender_notified = 0) "
        ... "OR (status = 'survived' AND sender_notified = 0) "
        ... "OR (status = 'expired' AND (sender_notified = 0 OR target_notified = 0)) "
        ... "ORDER BY resolved_at ASC, bounty_id ASC LIMIT 100",
        BOUNTY_TABLE);
    g_BountyNotificationQueryPending = true;
    g_Database.Query(SQL_OnPendingBountyNotifications, query);
}

public void SQL_OnPendingBountyNotifications(Database db, DBResultSet rows, const char[] error, any data)
{
    g_BountyNotificationQueryPending = false;
    if (error[0] != '\0')
    {
        LogError("[points_store] Bounty notification query failed: %s", error);
        return;
    }
    if (!IsBountyMailAvailable())
    {
        return;
    }

    char status[16];
    char senderSteamId[BOUNTY_STEAMID_MAX];
    char senderName[BOUNTY_NAME_MAX];
    char targetSteamId[BOUNTY_STEAMID_MAX];
    char targetName[BOUNTY_NAME_MAX];
    char claimantName[BOUNTY_NAME_MAX];
    char contents[512];
    char requestKey[BOUNTY_TOKEN_MAX];
    char currencyName[BP_CURRENCY_LONG_MAX];
    GetCurrencyLongLabel(currencyName, sizeof(currencyName));

    while (rows != null && rows.FetchRow())
    {
        int bountyId = rows.FetchInt(0);
        rows.FetchString(1, status, sizeof(status));
        rows.FetchString(2, senderSteamId, sizeof(senderSteamId));
        rows.FetchString(3, senderName, sizeof(senderName));
        rows.FetchString(4, targetSteamId, sizeof(targetSteamId));
        rows.FetchString(5, targetName, sizeof(targetName));
        int amount = rows.FetchInt(6);
        int payout = amount + rows.FetchInt(7);
        rows.FetchString(8, claimantName, sizeof(claimantName));
        bool senderNotified = rows.FetchInt(9) != 0;
        bool targetNotified = rows.FetchInt(10) != 0;

        if (StrEqual(status, "claimed", false) && !senderNotified)
        {
            FormatEx(contents, sizeof(contents), "%s completed your bounty of %d %s on %s!", claimantName, payout, currencyName, targetName);
            FormatEx(requestKey, sizeof(requestKey), "bounty_claim_sender_%d", bountyId);
            ServerMail_SendCustomSteamId("", "kogasa.tf", senderSteamId, "Bounty completed", contents, requestKey);
        }
        else if (StrEqual(status, "survived", false) && !senderNotified)
        {
            FormatEx(contents, sizeof(contents), "%s survived your bounty of %d %s and received %d %s.", targetName, amount, currencyName, payout, currencyName);
            FormatEx(requestKey, sizeof(requestKey), "bounty_survived_sender_%d", bountyId);
            ServerMail_SendCustomSteamId("", "kogasa.tf", senderSteamId, "Bounty survived", contents, requestKey);
        }
        else if (StrEqual(status, "expired", false))
        {
            if (!senderNotified)
            {
                FormatEx(contents, sizeof(contents), "Your bounty of %d %s on %s expired and was refunded.", amount, currencyName, targetName);
                FormatEx(requestKey, sizeof(requestKey), "bounty_expire_sender_%d", bountyId);
                ServerMail_SendCustomSteamId("", "kogasa.tf", senderSteamId, "Bounty expired", contents, requestKey);
            }
            if (!targetNotified)
            {
                FormatEx(contents, sizeof(contents), "%s's bounty of %d %s on you expired.", senderName, amount, currencyName);
                FormatEx(requestKey, sizeof(requestKey), "bounty_expire_target_%d", bountyId);
                ServerMail_SendCustomSteamId("", "kogasa.tf", targetSteamId, "Bounty expired", contents, requestKey);
            }
        }
    }
}

public void ServerMail_OnMailSendResult(const char[] requestKey, bool success, int mailId, bool newlyCreated)
{
    if (!success || !g_BountyDatabaseReady || g_Database == null)
    {
        return;
    }

    char claimPrefix[] = "bounty_claim_sender_";
    char survivedPrefix[] = "bounty_survived_sender_";
    char expireSenderPrefix[] = "bounty_expire_sender_";
    char expireTargetPrefix[] = "bounty_expire_target_";
    int bountyId = 0;
    char column[32];
    column[0] = '\0';
    if (StrContains(requestKey, claimPrefix, false) == 0)
    {
        bountyId = StringToInt(requestKey[strlen(claimPrefix)]);
        column = "sender_notified";
    }
    else if (StrContains(requestKey, survivedPrefix, false) == 0)
    {
        bountyId = StringToInt(requestKey[strlen(survivedPrefix)]);
        column = "sender_notified";
    }
    else if (StrContains(requestKey, expireSenderPrefix, false) == 0)
    {
        bountyId = StringToInt(requestKey[strlen(expireSenderPrefix)]);
        column = "sender_notified";
    }
    else if (StrContains(requestKey, expireTargetPrefix, false) == 0)
    {
        bountyId = StringToInt(requestKey[strlen(expireTargetPrefix)]);
        column = "target_notified";
    }

    if (bountyId <= 0 || column[0] == '\0')
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET %s = 1 WHERE bounty_id = %d",
        BOUNTY_TABLE,
        column,
        bountyId);
    g_Database.Query(SQL_OnIgnoredResult, query);
}
