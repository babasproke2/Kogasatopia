#define MAIL_STIMULUS_DEPLOYMENTS_TABLE "mail_stimulus_deployments"
#define MAIL_STIMULUS_RECIPIENTS_TABLE "mail_stimulus_recipients"
#define MAIL_STIMULUS_TITLE "Stimulus Check"
#define MAIL_STIMULUS_REQUEST_PREFIX "server_mail:stimulus:"
#define MAIL_STIMULUS_DEPLOY_COST 200
#define MAIL_STIMULUS_DEFAULT_GEMS 100
#define MAIL_STIMULUS_SECONDS_PER_DAY 86400

ConVar g_MailStimulusExpiryDays = null;
char g_MailStimulusPendingDescription[MAXPLAYERS + 1][MAIL_CONTENTS_MAX];
bool g_MailStimulusDeploymentPending[MAXPLAYERS + 1];
bool g_MailStimulusCheckPending[MAXPLAYERS + 1];
bool g_MailStimulusChecked[MAXPLAYERS + 1];

void Stimulus_OnPluginStart()
{
    g_MailStimulusExpiryDays = CreateConVar(
        "sm_server_mail_stimulus_expiry_days",
        "7",
        "Days an unredeemed Stimulus Check remains in mail. 0 disables expiry.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        365.0);
    RegAdminCmd(
        "sm_deploystimmy",
        Command_DeployStimmy,
        ADMFLAG_GENERIC,
        "Deploy a Stimulus Check to every currently ranked WhaleTracker client.");
}

void Stimulus_ResetClient(int client)
{
    g_MailStimulusPendingDescription[client][0] = '\0';
    g_MailStimulusDeploymentPending[client] = false;
    g_MailStimulusCheckPending[client] = false;
    g_MailStimulusChecked[client] = false;
}

void Stimulus_OnMapStart()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_MailStimulusCheckPending[client] = false;
        g_MailStimulusChecked[client] = false;
    }

    Stimulus_CleanupExpiredMail();
}

int Stimulus_GetExpirySeconds()
{
    if (g_MailStimulusExpiryDays == null)
    {
        return 7 * MAIL_STIMULUS_SECONDS_PER_DAY;
    }

    return g_MailStimulusExpiryDays.IntValue * MAIL_STIMULUS_SECONDS_PER_DAY;
}

int Stimulus_GetMailExpiry(const char[] title, int createdAt)
{
    if (!StrEqual(title, MAIL_STIMULUS_TITLE, false))
    {
        return 0;
    }

    int expirySeconds = Stimulus_GetExpirySeconds();
    return expirySeconds > 0 ? createdAt + expirySeconds : 0;
}

int Stimulus_GetAwardGems()
{
    ConVar gems = FindConVar("sm_whaletracker_stimulus_gems");
    if (gems == null || gems.IntValue <= 0)
    {
        return MAIL_STIMULUS_DEFAULT_GEMS;
    }
    return gems.IntValue;
}

void Stimulus_EnsureSchema()
{
    char query[2048];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "deployment_id BIGINT NOT NULL AUTO_INCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL, "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "created_at INT NOT NULL, "
            ... "contents VARCHAR(512) NOT NULL, "
            ... "gems INT NOT NULL, "
            ... "PRIMARY KEY (deployment_id)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            MAIL_STIMULUS_DEPLOYMENTS_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "deployment_id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL, "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "created_at INTEGER NOT NULL, "
            ... "contents VARCHAR(512) NOT NULL, "
            ... "gems INTEGER NOT NULL)",
            MAIL_STIMULUS_DEPLOYMENTS_TABLE);
    }
    g_MailDatabase.Query(SQL_OnStimulusDeploymentSchemaReady, query);
}

public void SQL_OnStimulusDeploymentSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Stimulus deployment schema creation failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    char query[2048];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "deployment_id BIGINT NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "awarded_at INT NOT NULL DEFAULT 0, "
            ... "mail_id BIGINT NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (deployment_id, steamid64), "
            ... "KEY idx_stimulus_recipient_pending (steamid64, awarded_at)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            MAIL_STIMULUS_RECIPIENTS_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "deployment_id INTEGER NOT NULL, "
            ... "steamid64 VARCHAR(32) NOT NULL, "
            ... "awarded_at INTEGER NOT NULL DEFAULT 0, "
            ... "mail_id INTEGER NOT NULL DEFAULT 0, "
            ... "PRIMARY KEY (deployment_id, steamid64))",
            MAIL_STIMULUS_RECIPIENTS_TABLE);
    }
    g_MailDatabase.Query(SQL_OnStimulusRecipientSchemaReady, query);
}

public void SQL_OnStimulusRecipientSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Stimulus recipient schema creation failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    FinishMailSchemaReady();
}

void Stimulus_BackfillExistingExpiry()
{
    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        return;
    }

    int expirySeconds = Stimulus_GetExpirySeconds();
    if (expirySeconds <= 0)
    {
        return;
    }

    char query[1536];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s m "
            ... "INNER JOIN %s r ON r.mail_id = m.mail_id "
            ... "INNER JOIN %s d ON d.deployment_id = r.deployment_id "
            ... "SET m.created_at = d.created_at, m.expires_at = d.created_at + %d "
            ... "WHERE m.title = '%s' AND m.gems_redeemed = 0",
            MAIL_TABLE,
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            MAIL_STIMULUS_DEPLOYMENTS_TABLE,
            expirySeconds,
            MAIL_STIMULUS_TITLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s SET "
            ... "created_at = COALESCE((SELECT d.created_at FROM %s r "
            ... "INNER JOIN %s d ON d.deployment_id = r.deployment_id "
            ... "WHERE r.mail_id = %s.mail_id), created_at), "
            ... "expires_at = COALESCE((SELECT d.created_at + %d FROM %s r "
            ... "INNER JOIN %s d ON d.deployment_id = r.deployment_id "
            ... "WHERE r.mail_id = %s.mail_id), created_at + %d) "
            ... "WHERE title = '%s' AND gems_redeemed = 0",
            MAIL_TABLE,
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            MAIL_STIMULUS_DEPLOYMENTS_TABLE,
            MAIL_TABLE,
            expirySeconds,
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            MAIL_STIMULUS_DEPLOYMENTS_TABLE,
            MAIL_TABLE,
            expirySeconds,
            MAIL_STIMULUS_TITLE);
    }
    g_MailDatabase.Query(SQL_OnStimulusMaintenance, query);
}

void Stimulus_CleanupExpiredMail()
{
    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "DELETE FROM %s WHERE expires_at > 0 AND expires_at <= %d AND gems_redeemed = 0",
        MAIL_TABLE,
        GetTime());
    g_MailDatabase.Query(SQL_OnStimulusMaintenance, query);

    int expirySeconds = Stimulus_GetExpirySeconds();
    if (expirySeconds <= 0)
    {
        return;
    }

    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "DELETE r FROM %s r INNER JOIN %s d ON d.deployment_id = r.deployment_id "
            ... "WHERE r.awarded_at = 0 AND d.created_at <= %d",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            MAIL_STIMULUS_DEPLOYMENTS_TABLE,
            GetTime() - expirySeconds);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "DELETE FROM %s WHERE awarded_at = 0 AND deployment_id IN "
            ... "(SELECT deployment_id FROM %s WHERE created_at <= %d)",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            MAIL_STIMULUS_DEPLOYMENTS_TABLE,
            GetTime() - expirySeconds);
    }
    g_MailDatabase.Query(SQL_OnStimulusMaintenance, query);
}

public void SQL_OnStimulusMaintenance(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Stimulus mail maintenance failed: %s", error);
    }
}

public Action Command_DeployStimmy(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    if (args == 0)
    {
        CPrintToChat(client, "%s A Stimulus Check description is required.", MAIL_PREFIX);
        CPrintToChat(client,
            "%s Use {gold}!deploystimmy Stimulus Check as an apology for server crash{default}.",
            MAIL_PREFIX);
        return Plugin_Handled;
    }

    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    if (g_MailStimulusDeploymentPending[client])
    {
        CPrintToChat(client, "%s Your previous Stimulus Check deployment is still being saved.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    GetCmdArgString(
        g_MailStimulusPendingDescription[client],
        sizeof(g_MailStimulusPendingDescription[]));
    StripQuotes(g_MailStimulusPendingDescription[client]);
    TrimString(g_MailStimulusPendingDescription[client]);
    if (g_MailStimulusPendingDescription[client][0] == '\0')
    {
        CPrintToChat(client, "%s A Stimulus Check description is required.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    char currencyColor[40];
    char currencyName[64];
    char menuTitle[768];
    GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
    FormatEx(menuTitle, sizeof(menuTitle),
        "Deploy Stimulus Check?\nCost: %d %s\n\n%s",
        MAIL_STIMULUS_DEPLOY_COST,
        currencyName,
        g_MailStimulusPendingDescription[client]);

    Menu menu = new Menu(MenuHandler_DeployStimmy);
    menu.SetTitle(menuTitle);
    menu.AddItem("yes", "Yes");
    menu.AddItem("no", "No");
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_DeployStimmy(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel && client > 0 && client <= MaxClients)
    {
        g_MailStimulusPendingDescription[client][0] = '\0';
        return 0;
    }

    if (action != MenuAction_Select || !IsMailClient(client))
    {
        return 0;
    }

    char choice[8];
    menu.GetItem(item, choice, sizeof(choice));
    if (StrEqual(choice, "yes"))
    {
        Stimulus_BeginDeployment(client);
    }
    else
    {
        g_MailStimulusPendingDescription[client][0] = '\0';
        CPrintToChat(client, "%s Stimulus Check deployment cancelled.", MAIL_PREFIX);
    }
    return 0;
}

bool Stimulus_IsCurrencyAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_RefundBonusPointsSteamId") == FeatureStatus_Available;
}

void Stimulus_BeginDeployment(int client)
{
    if (g_MailStimulusPendingDescription[client][0] == '\0'
        || !g_MailDatabaseReady
        || g_MailDatabase == null
        || !Stimulus_IsCurrencyAvailable())
    {
        CPrintToChat(client, "%s Stimulus Check deployment is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    if (!PointsStore_AreBonusPointsLoaded(client))
    {
        CPrintToChat(client, "%s Your currency balance is still loading.", MAIL_PREFIX);
        return;
    }

    char currencyColor[40];
    char currencyName[64];
    GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
    if (PointsStore_GetBonusPoints(client) < MAIL_STIMULUS_DEPLOY_COST)
    {
        CPrintToChat(client,
            "%s You need %s%d %s{default} to deploy a Stimulus Check.",
            MAIL_PREFIX,
            currencyColor,
            MAIL_STIMULUS_DEPLOY_COST,
            currencyName);
        return;
    }

    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(
        client,
        senderSteamId,
        sizeof(senderSteamId),
        senderName,
        sizeof(senderName)))
    {
        CPrintToChat(client, "%s Could not resolve your Steam identity.", MAIL_PREFIX);
        return;
    }

    char escapedSteam[65];
    char escapedName[(MAIL_NAME_MAX * 2) + 1];
    char escapedContents[(MAIL_CONTENTS_MAX * 2) + 1];
    if (!EscapeMailSql(senderSteamId, escapedSteam, sizeof(escapedSteam))
        || !EscapeMailSql(senderName, escapedName, sizeof(escapedName))
        || !EscapeMailSql(
            g_MailStimulusPendingDescription[client],
            escapedContents,
            sizeof(escapedContents)))
    {
        CPrintToChat(client, "%s Could not prepare the Stimulus Check.", MAIL_PREFIX);
        return;
    }

    if (!PointsStore_SpendBonusPoints(client, MAIL_STIMULUS_DEPLOY_COST))
    {
        CPrintToChat(client, "%s Failed to deduct the deployment cost.", MAIL_PREFIX);
        return;
    }

    g_MailStimulusDeploymentPending[client] = true;
    char query[2048];
    FormatEx(query, sizeof(query),
        "INSERT INTO %s (sender_steamid64, sender_name, created_at, contents, gems) "
        ... "VALUES ('%s', '%s', %d, '%s', %d)",
        MAIL_STIMULUS_DEPLOYMENTS_TABLE,
        escapedSteam,
        escapedName,
        GetTime(),
        escapedContents,
        Stimulus_GetAwardGems());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(senderSteamId);
    g_MailDatabase.Query(SQL_OnStimulusDeploymentInserted, query, pack);
    g_MailStimulusPendingDescription[client][0] = '\0';
}

void Stimulus_RefundDeployment(int userId, const char[] steamId)
{
    int client = GetClientOfUserId(userId);
    if (IsMailClient(client))
    {
        g_MailStimulusDeploymentPending[client] = false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_RefundBonusPointsSteamId") != FeatureStatus_Available
        || !PointsStore_RefundBonusPointsSteamId(
            steamId,
            MAIL_STIMULUS_DEPLOY_COST,
            "server_mail_stimulus_refund"))
    {
        LogError("[server_mail] Failed to refund Stimulus Check deployment cost to %s.", steamId);
    }
}

public void SQL_OnStimulusDeploymentInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    char senderSteamId[MAIL_STEAMID_MAX];
    pack.ReadString(senderSteamId, sizeof(senderSteamId));
    delete pack;

    if (error[0] != '\0' || results == null || results.InsertId <= 0)
    {
        LogError("[server_mail] Stimulus Check deployment insert failed: %s", error);
        Stimulus_RefundDeployment(userId, senderSteamId);
        return;
    }

    int deploymentId = results.InsertId;
    char query[2048];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT IGNORE INTO %s (deployment_id, steamid64, awarded_at, mail_id) "
            ... "SELECT %d, steamid, 0, 0 FROM whaletracker "
            ... "WHERE (GREATEST(COALESCE(kills, 0), 0) + GREATEST(COALESCE(deaths, 0), 0)) >= %d "
            ... "AND GREATEST(COALESCE(playtime, 0), 0) >= %d",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            deploymentId,
            GetRankMinimumKillsDeaths(),
            GetRankMinimumPlaytime());
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT OR IGNORE INTO %s (deployment_id, steamid64, awarded_at, mail_id) "
            ... "SELECT %d, steamid, 0, 0 FROM whaletracker "
            ... "WHERE (MAX(COALESCE(kills, 0), 0) + MAX(COALESCE(deaths, 0), 0)) >= %d "
            ... "AND MAX(COALESCE(playtime, 0), 0) >= %d",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            deploymentId,
            GetRankMinimumKillsDeaths(),
            GetRankMinimumPlaytime());
    }

    DataPack nextPack = new DataPack();
    nextPack.WriteCell(userId);
    nextPack.WriteString(senderSteamId);
    nextPack.WriteCell(deploymentId);
    g_MailDatabase.Query(SQL_OnStimulusRecipientsInserted, query, nextPack);
}

void Stimulus_DeleteDeployment(int deploymentId)
{
    if (g_MailDatabase == null || deploymentId <= 0)
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "DELETE FROM %s WHERE deployment_id = %d",
        MAIL_STIMULUS_DEPLOYMENTS_TABLE,
        deploymentId);
    g_MailDatabase.Query(SQL_OnStimulusMaintenance, query);
}

public void SQL_OnStimulusRecipientsInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    char senderSteamId[MAIL_STEAMID_MAX];
    pack.ReadString(senderSteamId, sizeof(senderSteamId));
    int deploymentId = pack.ReadCell();
    delete pack;

    if (error[0] != '\0' || results == null || results.AffectedRows <= 0)
    {
        LogError("[server_mail] Stimulus recipient snapshot failed: %s", error);
        Stimulus_DeleteDeployment(deploymentId);
        Stimulus_RefundDeployment(userId, senderSteamId);
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        g_MailStimulusChecked[client] = false;
    }

    int admin = GetClientOfUserId(userId);
    if (IsMailClient(admin))
    {
        g_MailStimulusDeploymentPending[admin] = false;
        char currencyColor[40];
        char currencyName[64];
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
        CPrintToChat(admin,
            "%s Stimulus Check deployed to {gold}%d ranked clients{default} for %s%d %s{default}.",
            MAIL_PREFIX,
            results.AffectedRows,
            currencyColor,
            MAIL_STIMULUS_DEPLOY_COST,
            currencyName);
    }
}

bool Stimulus_CheckPendingForClient(int client)
{
    if (!IsMailClient(client)
        || !g_MailDatabaseReady
        || g_MailDatabase == null
        || g_MailStimulusCheckPending[client]
        || g_MailStimulusChecked[client])
    {
        return false;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name)))
    {
        return false;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        return false;
    }

    char query[1536];
    int expirySeconds = Stimulus_GetExpirySeconds();
    FormatEx(query, sizeof(query),
        "SELECT d.deployment_id, d.sender_steamid64, d.sender_name, d.contents, d.gems, d.created_at "
        ... "FROM %s r INNER JOIN %s d ON d.deployment_id = r.deployment_id "
        ... "WHERE r.steamid64 = '%s' AND r.awarded_at = 0 "
        ... "AND (%d = 0 OR d.created_at > %d) "
        ... "ORDER BY d.deployment_id ASC",
        MAIL_STIMULUS_RECIPIENTS_TABLE,
        MAIL_STIMULUS_DEPLOYMENTS_TABLE,
        escapedSteam,
        expirySeconds,
        GetTime() - expirySeconds);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    g_MailStimulusCheckPending[client] = true;
    g_MailDatabase.Query(SQL_OnPendingStimulusLoaded, query, pack);
    return true;
}

public void SQL_OnPendingStimulusLoaded(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char steamId[MAIL_STEAMID_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    if (!IsMailClient(client))
    {
        return;
    }

    g_MailStimulusCheckPending[client] = false;
    if (error[0] != '\0')
    {
        LogError("[server_mail] Pending Stimulus Check query failed for %s: %s", steamId, error);
        g_MailStimulusChecked[client] = false;
        return;
    }

    g_MailStimulusChecked[client] = true;
    char receiverSteamId[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(
        client,
        receiverSteamId,
        sizeof(receiverSteamId),
        receiverName,
        sizeof(receiverName))
        || !StrEqual(receiverSteamId, steamId, false))
    {
        return;
    }

    while (rows != null && rows.FetchRow())
    {
        int deploymentId = rows.FetchInt(0);
        char senderSteamId[MAIL_STEAMID_MAX];
        char senderName[MAIL_NAME_MAX];
        char contents[MAIL_CONTENTS_MAX];
        rows.FetchString(1, senderSteamId, sizeof(senderSteamId));
        rows.FetchString(2, senderName, sizeof(senderName));
        rows.FetchString(3, contents, sizeof(contents));
        int gems = rows.FetchInt(4);
        int deploymentCreatedAt = rows.FetchInt(5);

        char requestKey[MAIL_REQUEST_KEY_MAX];
        FormatEx(requestKey, sizeof(requestKey),
            "%s%d:%s",
            MAIL_STIMULUS_REQUEST_PREFIX,
            deploymentId,
            steamId);
        if (!QueueMailInsert(
            senderSteamId,
            senderName,
            receiverSteamId,
            receiverName,
            MAIL_STIMULUS_TITLE,
            contents,
            gems,
            requestKey,
            0,
            true,
            false,
            "",
            0,
            deploymentCreatedAt))
        {
            g_MailStimulusChecked[client] = false;
        }
    }
}

bool Stimulus_ParseRequestKey(
    const char[] requestKey,
    int &deploymentId,
    char[] steamId,
    int steamLen)
{
    char parts[4][64];
    if (ExplodeString(requestKey, ":", parts, sizeof(parts), sizeof(parts[])) != 4
        || !StrEqual(parts[0], "server_mail")
        || !StrEqual(parts[1], "stimulus")
        || StringToIntEx(parts[2], deploymentId) == 0
        || deploymentId <= 0
        || !Kogasa_IsSteamId64(parts[3]))
    {
        return false;
    }

    strcopy(steamId, steamLen, parts[3]);
    return true;
}

void Stimulus_OnMailInsertResult(const char[] requestKey, bool success, int mailId)
{
    int deploymentId;
    char steamId[MAIL_STEAMID_MAX];
    if (!Stimulus_ParseRequestKey(requestKey, deploymentId, steamId, sizeof(steamId)))
    {
        return;
    }

    int client = Kogasa_FindClientBySteamId64(steamId);
    if (!success || mailId <= 0)
    {
        if (IsMailClient(client))
        {
            g_MailStimulusChecked[client] = false;
        }
        return;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        if (IsMailClient(client))
        {
            g_MailStimulusChecked[client] = false;
        }
        return;
    }

    char query[768];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s SET awarded_at = IF(awarded_at = 0, %d, awarded_at), mail_id = %d "
            ... "WHERE deployment_id = %d AND steamid64 = '%s'",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            GetTime(),
            mailId,
            deploymentId,
            escapedSteam);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "UPDATE %s SET awarded_at = CASE WHEN awarded_at = 0 THEN %d ELSE awarded_at END, mail_id = %d "
            ... "WHERE deployment_id = %d AND steamid64 = '%s'",
            MAIL_STIMULUS_RECIPIENTS_TABLE,
            GetTime(),
            mailId,
            deploymentId,
            escapedSteam);
    }

    DataPack pack = new DataPack();
    pack.WriteString(steamId);
    g_MailDatabase.Query(SQL_OnStimulusRecipientAwarded, query, pack);
}

public void SQL_OnStimulusRecipientAwarded(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char steamId[MAIL_STEAMID_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    if (error[0] == '\0' && results != null && results.AffectedRows > 0)
    {
        return;
    }

    LogError("[server_mail] Failed to mark Stimulus Check awarded for %s: %s", steamId, error);
    int client = Kogasa_FindClientBySteamId64(steamId);
    if (IsMailClient(client))
    {
        g_MailStimulusChecked[client] = false;
    }
}

public any Native_ServerMail_CheckPendingStimulus(Handle plugin, int numParams)
{
    return Stimulus_CheckPendingForClient(GetNativeCell(1));
}
