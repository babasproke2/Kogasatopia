#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

#include <multicolors>

#undef REQUIRE_PLUGIN
#include <filters_api>
#include <hugs_api>
#include <points_store_api>
#include <rtd_api>
#include <saysounds>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/steam_identity.inc"

#define MAIL_DB_CONFIG "server_mail"
#define MAIL_TABLE "mail"
#define MAIL_STEAMID_MAX 32
#define MAIL_NAME_MAX 128
#define MAIL_TITLE_MAX 128
#define MAIL_CONTENTS_MAX 512
#define MAIL_REQUEST_KEY_MAX 128
#define MAIL_SEARCH_MAX 64
#define MAIL_ATTACHMENT_MAX 16
#define MAIL_LIST_MAX 50
#define MAIL_RECONNECT_DELAY 5.0
#define MAIL_SEND_COOLDOWN 60.0
#define MAIL_UNREAD_REMINDER_DELAY 30.0
#define MAIL_UNREAD_REMINDER_RETRY 5.0
#define MAIL_RTD_GIFT_COST 50
#define MAIL_PREFIX "{cornflowerblue}[Mail]{default}"

enum MailViewMode
{
    MailView_Inbox = 0,
    MailView_Sent,
    MailView_Unread
};

enum MailRedemptionQueueResult
{
    MailRedemption_Queued = 0,
    MailRedemption_AlreadyPending,
    MailRedemption_Failed
};

enum struct MailSearchResult
{
    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    int playtime;
    bool connected;
}

Database g_MailDatabase = null;
bool g_MailDatabaseReady = false;
bool g_MailDatabaseIsMySql = false;
Handle g_MailReconnectTimer = null;
GlobalForward g_MailSendResultForward = null;
Cookie g_MailUnreadReminderCookie = null;
Handle g_MailUnreadReminderTimer[MAXPLAYERS + 1];
bool g_MailUnreadReminderPending[MAXPLAYERS + 1];

ArrayList g_MailSearchResults[MAXPLAYERS + 1];
char g_MailPendingContents[MAXPLAYERS + 1][MAIL_CONTENTS_MAX];
char g_MailPendingSearch[MAXPLAYERS + 1][MAIL_NAME_MAX];
int g_MailPendingGems[MAXPLAYERS + 1];
char g_MailPendingAttachment[MAXPLAYERS + 1][MAIL_ATTACHMENT_MAX];
int g_MailSearchGeneration[MAXPLAYERS + 1];
int g_MailGiftSerial = 0;
float g_MailNextSendAllowedAt[MAXPLAYERS + 1];
bool g_MailUserSendPending[MAXPLAYERS + 1];
bool g_MailRedeemAllPending[MAXPLAYERS + 1];
bool g_MailReadAllPending[MAXPLAYERS + 1];

StringMap g_MailPendingRedemptions = null;
StringMap g_MailRedemptionUsers = null;
StringMap g_MailRedemptionTitles = null;
StringMap g_MailRedemptionSteamIds = null;
StringMap g_MailRedemptionAmounts = null;
StringMap g_MailPendingAttachments = null;

public Plugin myinfo =
{
    name = "server_mail",
    author = "Hombre",
    description = "Persistent player mail with optional currency attachments.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errMax)
{
    RegPluginLibrary("server_mail");
    CreateNative("ServerMail_Send", Native_ServerMail_Send);
    CreateNative("ServerMail_SendCustom", Native_ServerMail_SendCustom);
    CreateNative("ServerMail_SendCurrency", Native_ServerMail_SendCurrency);
    CreateNative("ServerMail_SendSteamId", Native_ServerMail_SendSteamId);
    CreateNative("ServerMail_SendCustomSteamId", Native_ServerMail_SendCustomSteamId);
    CreateNative("ServerMail_SendCurrencySteamId", Native_ServerMail_SendCurrencySteamId);
    CreateNative("ServerMail_CheckPendingStimulus", Native_ServerMail_CheckPendingStimulus);

    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("Filters_GetSteamIdColorTag");
    MarkNativeAsOptional("Filters_GetLastRecordedSteamName");
    MarkNativeAsOptional("Hugs_RedeemMailedHug");
    MarkNativeAsOptional("Hugs_RedeemMailedFeed");
    MarkNativeAsOptional("Hugs_RedeemMailedRape");
    MarkNativeAsOptional("Hugs_AnnounceMailedInteraction");
    MarkNativeAsOptional("PointsStore_ApplyBonusPointsSteamIdOnce");
    MarkNativeAsOptional("PointsStore_RefundBonusPointsSteamId");
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("RTD_ApplyGiftedRoll");
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeHours");

    g_MailSendResultForward = new GlobalForward(
        "ServerMail_OnMailSendResult",
        ET_Ignore,
        Param_String,
        Param_Cell,
        Param_Cell,
        Param_Cell);
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegConsoleCmd("sm_mail", Command_Mail, "Open mail or send mail to a ranked player.");
    RegConsoleCmd("sm_dm", Command_Mail, "Open mail or send mail to a ranked player.");
    RegConsoleCmd("sm_inbox", Command_Inbox, "Open your mail inbox.");
    RegConsoleCmd("sm_unread", Command_Unread, "Open unread mail.");
    RegConsoleCmd("sm_readall", Command_ReadAll, "Mark all received mail as read.");
    RegConsoleCmd("sm_redeem", Command_RedeemAll, "Redeem every unclaimed Gem attachment in your inbox.");
    RegConsoleCmd("sm_redeemall", Command_RedeemAll, "Redeem every unclaimed Gem attachment in your inbox.");
    RegConsoleCmd("sm_gift", Command_Gift, "Mail Gems to a ranked player.");
    RegConsoleCmd("sm_mailhug", Command_MailHug, "Mail a one-use hug to a ranked player.");
    RegConsoleCmd("sm_hugmail", Command_MailHug, "Mail a one-use hug to a ranked player.");
    RegConsoleCmd("sm_gifthug", Command_MailHug, "Mail a one-use hug to a ranked player.");
    RegConsoleCmd("sm_mailfeed", Command_MailFeed, "Mail a one-use feed to a ranked player.");
    RegConsoleCmd("sm_feedmail", Command_MailFeed, "Mail a one-use feed to a ranked player.");
    RegConsoleCmd("sm_mailrape", Command_MailRape, "Mail a one-use rape to a ranked player.");
    RegConsoleCmd("sm_rapemail", Command_MailRape, "Mail a one-use rape to a ranked player.");
    RegConsoleCmd("sm_giftrape", Command_MailRape, "Mail a one-use rape to a ranked player.");
    RegConsoleCmd("sm_mailrtd", Command_MailRtd, "Mail a prepaid RTD roll to a ranked player.");
    RegConsoleCmd("sm_sendrtd", Command_MailRtd, "Mail a prepaid RTD roll to a ranked player.");
    RegConsoleCmd("sm_giftrtd", Command_MailRtd, "Mail a prepaid RTD roll to a ranked player.");
    HookEvent("player_team", Event_MailPlayerTeam, EventHookMode_Post);
    g_MailUnreadReminderCookie = new Cookie(
        "server_mail_unread_reminder_day",
        "Last date the unread-mail reminder was displayed.",
        CookieAccess_Private);
    Stimulus_OnPluginStart();

    g_MailPendingRedemptions = new StringMap();
    g_MailRedemptionUsers = new StringMap();
    g_MailRedemptionTitles = new StringMap();
    g_MailRedemptionSteamIds = new StringMap();
    g_MailRedemptionAmounts = new StringMap();
    g_MailPendingAttachments = new StringMap();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            ClearClientMailState(client);
            ResetUnreadMailReminder(client);
            ScheduleUnreadMailReminder(client);
        }
    }

    ConnectMailDatabase();
}

public void OnPluginEnd()
{
    delete g_MailSendResultForward;
    delete g_MailPendingRedemptions;
    delete g_MailRedemptionUsers;
    delete g_MailRedemptionTitles;
    delete g_MailRedemptionSteamIds;
    delete g_MailRedemptionAmounts;
    delete g_MailPendingAttachments;

    for (int client = 1; client <= MaxClients; client++)
    {
        delete g_MailSearchResults[client];
        delete g_MailUnreadReminderTimer[client];
    }

    delete g_MailUnreadReminderCookie;

    if (g_MailReconnectTimer != null)
    {
        delete g_MailReconnectTimer;
        g_MailReconnectTimer = null;
    }
    delete g_MailDatabase;
    g_MailDatabase = null;
}

public void OnClientPutInServer(int client)
{
    ResetUnreadMailReminder(client);
}

public void OnClientDisconnect(int client)
{
    ResetUnreadMailReminder(client);
    ClearClientMailState(client);
    g_MailNextSendAllowedAt[client] = 0.0;
    g_MailUserSendPending[client] = false;
    g_MailRedeemAllPending[client] = false;
    g_MailReadAllPending[client] = false;
    Stimulus_ResetClient(client);
}

public void OnMapStart()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_MailUnreadReminderTimer[client] = null;
    }
    Stimulus_OnMapStart();
}

public void Event_MailPlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsMailClient(client))
    {
        return;
    }

    int team = event.GetInt("team");
    if (team == 2 || team == 3)
    {
        ScheduleUnreadMailReminder(client);
    }
    else
    {
        CancelUnreadMailReminder(client);
    }
}

void ScheduleUnreadMailReminder(int client, float delay = MAIL_UNREAD_REMINDER_DELAY)
{
    if (!IsMailClient(client) || (GetClientTeam(client) != 2 && GetClientTeam(client) != 3)
        || g_MailUnreadReminderTimer[client] != null || g_MailUnreadReminderPending[client])
    {
        return;
    }

    g_MailUnreadReminderTimer[client] = CreateTimer(
        delay,
        Timer_CheckUnreadMail,
        GetClientUserId(client),
        TIMER_FLAG_NO_MAPCHANGE);
}

void CancelUnreadMailReminder(int client)
{
    delete g_MailUnreadReminderTimer[client];
    g_MailUnreadReminderTimer[client] = null;
}

void ResetUnreadMailReminder(int client)
{
    CancelUnreadMailReminder(client);
    g_MailUnreadReminderPending[client] = false;
}

public Action Timer_CheckUnreadMail(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0 && client <= MaxClients)
    {
        g_MailUnreadReminderTimer[client] = null;
    }

    if (!IsMailClient(client) || (GetClientTeam(client) != 2 && GetClientTeam(client) != 3))
    {
        return Plugin_Stop;
    }
    if (!AreClientCookiesCached(client))
    {
        ScheduleUnreadMailReminder(client, MAIL_UNREAD_REMINDER_RETRY);
        return Plugin_Stop;
    }
    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        ScheduleUnreadMailReminder(client, MAIL_UNREAD_REMINDER_RETRY);
        return Plugin_Stop;
    }

    char today[16];
    char lastReminderDay[16];
    FormatTime(today, sizeof(today), "%Y%m%d", GetTime());
    g_MailUnreadReminderCookie.Get(client, lastReminderDay, sizeof(lastReminderDay));
    if (StrEqual(today, lastReminderDay))
    {
        return Plugin_Stop;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    char escapedSteam[(MAIL_STEAMID_MAX * 2) + 1];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name))
        || !EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        return Plugin_Stop;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT 1 FROM %s WHERE receiver_steamid64 = '%s' AND read_at = 0 "
        ... "AND (expires_at = 0 OR expires_at > %d OR gems_redeemed != 0) LIMIT 1",
        MAIL_TABLE,
        escapedSteam,
        GetTime());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(today);
    g_MailUnreadReminderPending[client] = true;
    g_MailDatabase.Query(SQL_OnUnreadMailReminderChecked, query, pack);
    return Plugin_Stop;
}

public void SQL_OnUnreadMailReminderChecked(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char reminderDay[16];
    pack.ReadString(reminderDay, sizeof(reminderDay));
    delete pack;

    if (client > 0 && client <= MaxClients)
    {
        g_MailUnreadReminderPending[client] = false;
    }
    if (error[0] != '\0')
    {
        LogError("[server_mail] Unread-mail reminder query failed: %s", error);
        return;
    }
    if (!IsMailClient(client) || (GetClientTeam(client) != 2 && GetClientTeam(client) != 3)
        || rows == null || !rows.FetchRow())
    {
        return;
    }

    g_MailUnreadReminderCookie.Set(client, reminderDay);
    CPrintToChat(client,
        "%s You have unread server mail; use {gold}!inbox{default} to read it!",
        MAIL_PREFIX);
}

public void OnLibraryRemoved(const char[] name)
{
    if (!StrEqual(name, "points_store", false))
    {
        return;
    }

    g_MailPendingRedemptions.Clear();
    g_MailRedemptionUsers.Clear();
    g_MailRedemptionTitles.Clear();
    g_MailRedemptionSteamIds.Clear();
    g_MailRedemptionAmounts.Clear();
}

void ClearClientMailState(int client)
{
    delete g_MailSearchResults[client];
    g_MailSearchResults[client] = null;
    g_MailPendingContents[client][0] = '\0';
    g_MailPendingSearch[client][0] = '\0';
    g_MailPendingGems[client] = 0;
    g_MailPendingAttachment[client][0] = '\0';
    g_MailSearchGeneration[client]++;
}

bool IsMailClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

bool CheckMailSendCooldown(int client)
{
    if (g_MailUserSendPending[client])
    {
        CPrintToChat(client, "%s Your mail is still being sent. Try again in a moment.", MAIL_PREFIX);
        return false;
    }

    float remaining = g_MailNextSendAllowedAt[client] - GetEngineTime();
    if (remaining > 0.0)
    {
        CPrintToChat(client,
            "%s Wait {gold}%d{default} seconds before sending mail or gifts again.",
            MAIL_PREFIX,
            RoundToCeil(remaining));
        return false;
    }

    return true;
}

void FinishUserMailSend(int senderUserId, bool success)
{
    int client = GetClientOfUserId(senderUserId);
    if (!IsMailClient(client))
    {
        return;
    }

    g_MailUserSendPending[client] = false;
    if (success)
    {
        g_MailNextSendAllowedAt[client] = GetEngineTime() + MAIL_SEND_COOLDOWN;
    }
}

bool IsPointsStoreAwardAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPointsSteamIdOnce") == FeatureStatus_Available;
}

bool IsPointsStoreGiftAvailable()
{
    return IsPointsStoreAwardAvailable()
        && GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_RefundBonusPointsSteamId") == FeatureStatus_Available;
}

void ConnectMailDatabase()
{
    g_MailDatabaseReady = false;
    delete g_MailDatabase;
    g_MailDatabase = null;

    if (g_MailReconnectTimer != null)
    {
        delete g_MailReconnectTimer;
        g_MailReconnectTimer = null;
    }

    if (!SQL_CheckConfig(MAIL_DB_CONFIG))
    {
        LogError("[server_mail] Missing databases.cfg entry '%s'.", MAIL_DB_CONFIG);
        ScheduleMailReconnect();
        return;
    }

    Database.Connect(SQL_OnMailDatabaseConnected, MAIL_DB_CONFIG);
}

void ScheduleMailReconnect()
{
    if (g_MailReconnectTimer == null)
    {
        g_MailReconnectTimer = CreateTimer(MAIL_RECONNECT_DELAY, Timer_MailReconnect, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_MailReconnect(Handle timer)
{
    g_MailReconnectTimer = null;
    ConnectMailDatabase();
    return Plugin_Stop;
}

public void SQL_OnMailDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[server_mail] Database connection failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    g_MailDatabase = db;
    g_MailDatabase.SetCharset("utf8mb4");

    char driver[32];
    g_MailDatabase.Driver.GetIdentifier(driver, sizeof(driver));
    g_MailDatabaseIsMySql = StrEqual(driver, "mysql", false);
    EnsureMailSchema();
}

void EnsureMailSchema()
{
    char query[2048];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "mail_id BIGINT NOT NULL AUTO_INCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "receiver_steamid64 VARCHAR(32) NOT NULL, "
            ... "receiver_name VARCHAR(128) NOT NULL, "
            ... "created_at INT NOT NULL, "
            ... "title VARCHAR(128) NOT NULL, "
            ... "contents VARCHAR(512) NOT NULL, "
            ... "gems INT NOT NULL DEFAULT 0, "
            ... "gems_redeemed TINYINT NOT NULL DEFAULT 0, "
            ... "attachment_type VARCHAR(16) NOT NULL DEFAULT '', "
            ... "attachment_redeemed TINYINT NOT NULL DEFAULT 0, "
            ... "expires_at INT NOT NULL DEFAULT 0, "
            ... "read_at INT NOT NULL DEFAULT 0, "
            ... "idempotency_key VARCHAR(128) NULL, "
            ... "PRIMARY KEY (mail_id), "
            ... "UNIQUE KEY unique_mail_idempotency (idempotency_key), "
            ... "KEY idx_mail_receiver (receiver_steamid64, created_at), "
            ... "KEY idx_mail_sender (sender_steamid64, created_at)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            MAIL_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS %s ("
            ... "mail_id INTEGER PRIMARY KEY AUTOINCREMENT, "
            ... "sender_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
            ... "sender_name VARCHAR(128) NOT NULL, "
            ... "receiver_steamid64 VARCHAR(32) NOT NULL, "
            ... "receiver_name VARCHAR(128) NOT NULL, "
            ... "created_at INTEGER NOT NULL, "
            ... "title VARCHAR(128) NOT NULL, "
            ... "contents VARCHAR(512) NOT NULL, "
            ... "gems INTEGER NOT NULL DEFAULT 0, "
            ... "gems_redeemed INTEGER NOT NULL DEFAULT 0, "
            ... "attachment_type VARCHAR(16) NOT NULL DEFAULT '', "
            ... "attachment_redeemed INTEGER NOT NULL DEFAULT 0, "
            ... "expires_at INTEGER NOT NULL DEFAULT 0, "
            ... "read_at INTEGER NOT NULL DEFAULT 0, "
            ... "idempotency_key VARCHAR(128) UNIQUE)");
    }

    g_MailDatabase.Query(SQL_OnMailSchemaReady, query);
}

public void SQL_OnMailSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Mail schema creation failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    EnsureMailExpiryColumn();
}

void EnsureMailExpiryColumn()
{
    char query[256];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS expires_at INT NOT NULL DEFAULT 0 AFTER gems_redeemed",
            MAIL_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0",
            MAIL_TABLE);
    }
    g_MailDatabase.Query(SQL_OnMailExpiryColumnReady, query);
}

public void SQL_OnMailExpiryColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "duplicate column", false) == -1
        && StrContains(error, "already exists", false) == -1)
    {
        LogError("[server_mail] Mail expiry schema migration failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    EnsureMailReadColumn();
}

void EnsureMailReadColumn()
{
    char query[256];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS read_at INT NOT NULL DEFAULT 1 AFTER expires_at",
            MAIL_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN read_at INTEGER NOT NULL DEFAULT 1",
            MAIL_TABLE);
    }
    g_MailDatabase.Query(SQL_OnMailReadColumnReady, query);
}

public void SQL_OnMailReadColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "duplicate column", false) == -1
        && StrContains(error, "already exists", false) == -1)
    {
        LogError("[server_mail] Mail read-state schema migration failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    EnsureMailAttachmentTypeColumn();
}

void EnsureMailAttachmentTypeColumn()
{
    char query[256];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS attachment_type VARCHAR(16) NOT NULL DEFAULT '' AFTER gems_redeemed",
            MAIL_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN attachment_type VARCHAR(16) NOT NULL DEFAULT ''",
            MAIL_TABLE);
    }
    g_MailDatabase.Query(SQL_OnMailAttachmentTypeColumnReady, query);
}

public void SQL_OnMailAttachmentTypeColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "duplicate column", false) == -1
        && StrContains(error, "already exists", false) == -1)
    {
        LogError("[server_mail] Mail attachment-type migration failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    char query[256];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN IF NOT EXISTS attachment_redeemed TINYINT NOT NULL DEFAULT 0 AFTER attachment_type",
            MAIL_TABLE);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "ALTER TABLE %s ADD COLUMN attachment_redeemed INTEGER NOT NULL DEFAULT 0",
            MAIL_TABLE);
    }
    g_MailDatabase.Query(SQL_OnMailAttachmentStateColumnReady, query);
}

public void SQL_OnMailAttachmentStateColumnReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "duplicate column", false) == -1
        && StrContains(error, "already exists", false) == -1)
    {
        LogError("[server_mail] Mail attachment-state migration failed: %s", error);
        ScheduleMailReconnect();
        return;
    }

    Stimulus_EnsureSchema();
}

void FinishMailSchemaReady()
{
    g_MailDatabaseReady = true;
    char recoveryQuery[256];
    // Preserve at-most-once delivery if the server stops between applying an
    // attachment and persisting its final redeemed state.
    FormatEx(recoveryQuery, sizeof(recoveryQuery),
        "UPDATE %s SET attachment_redeemed = 1 WHERE attachment_redeemed = 2",
        MAIL_TABLE);
    g_MailDatabase.Query(SQL_OnInterruptedAttachmentsRecovered, recoveryQuery);
    Stimulus_BackfillExistingExpiry();
    Stimulus_CleanupExpiredMail();
}

public void SQL_OnInterruptedAttachmentsRecovered(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Failed to recover interrupted mail attachments: %s", error);
    }
}

bool EscapeMailSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    return g_MailDatabaseReady && g_MailDatabase != null
        && g_MailDatabase.Escape(input, output, maxlen);
}

bool GetMailClientIdentity(int client, char[] steamId, int steamLen, char[] name, int nameLen)
{
    steamId[0] = '\0';
    name[0] = '\0';

    if (client == 0)
    {
        strcopy(name, nameLen, "kogasa.tf");
        return true;
    }

    if (!IsMailClient(client)
        || !Kogasa_GetClientSteamId64(client, steamId, steamLen, true)
        || !GetClientName(client, name, nameLen))
    {
        return false;
    }

    TrimString(name);
    return name[0] != '\0';
}

void BuildColoredMailName(int client, const char[] steamId, const char[] fallbackName, char[] output, int maxlen)
{
    output[0] = '\0';
    if (IsMailClient(client)
        && GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, output, maxlen)
        && output[0] != '\0')
    {
        return;
    }

    char colorTag[32];
    colorTag[0] = '\0';
    if (steamId[0] != '\0'
        && GetFeatureStatus(FeatureType_Native, "Filters_GetSteamIdColorTag") == FeatureStatus_Available)
    {
        Filters_GetSteamIdColorTag(steamId, colorTag, sizeof(colorTag));
    }

    if (colorTag[0] == '\0')
    {
        strcopy(colorTag, sizeof(colorTag), IsMailClient(client) ? "{teamcolor}" : "{default}");
    }
    Format(output, maxlen, "%s%s", colorTag, fallbackName);
}

void GetCurrencyFormatting(char[] colorTag, int colorLen, char[] currencyName, int nameLen)
{
    strcopy(colorTag, colorLen, "{cyan}");
    strcopy(currencyName, nameLen, "Gems");

    ConVar color = FindConVar("sm_points_store_currency_color");
    if (color != null)
    {
        char rawColor[32];
        color.GetString(rawColor, sizeof(rawColor));
        TrimString(rawColor);
        if (rawColor[0] != '\0')
        {
            Format(colorTag, colorLen, "{%s}", rawColor);
        }
    }

    ConVar currency = FindConVar("sm_points_store_currency_long");
    if (currency != null)
    {
        currency.GetString(currencyName, nameLen);
        TrimString(currencyName);
    }
}

public Action Command_Mail(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    if (args == 0)
    {
        ShowMailMainMenu(client);
        return Plugin_Handled;
    }

    if (!CheckMailSendCooldown(client))
    {
        return Plugin_Handled;
    }

    BeginMailCommand(client);
    return Plugin_Handled;
}

public Action Command_Inbox(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    RequestMailList(client, MailView_Inbox);
    return Plugin_Handled;
}

public Action Command_Unread(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    RequestMailList(client, MailView_Unread);
    return Plugin_Handled;
}

public Action Command_ReadAll(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }
    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }
    if (g_MailReadAllPending[client])
    {
        CPrintToChat(client, "%s Your mail is still being updated.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    char escapedSteam[65];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name))
        || !EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        return Plugin_Handled;
    }

    char query[384];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET read_at = %d WHERE receiver_steamid64 = '%s' AND read_at = 0",
        MAIL_TABLE,
        GetTime(),
        escapedSteam);
    g_MailReadAllPending[client] = true;
    g_MailDatabase.Query(SQL_OnAllMailMarkedRead, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnAllMailMarkedRead(Database db, DBResultSet results, const char[] error, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0)
    {
        g_MailReadAllPending[client] = false;
    }
    if (error[0] != '\0')
    {
        LogError("[server_mail] Failed to mark all mail as read: %s", error);
        if (IsMailClient(client))
        {
            CPrintToChat(client, "%s Failed to update your mail.", MAIL_PREFIX);
        }
        return;
    }
    if (IsMailClient(client))
    {
        CPrintToChat(client, "%s All received mail has been marked as read.", MAIL_PREFIX);
    }
}

public Action Command_RedeemAll(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    if (!g_MailDatabaseReady || g_MailDatabase == null || !IsPointsStoreAwardAvailable())
    {
        CPrintToChat(client, "%s Currency redemption is temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    if (g_MailRedeemAllPending[client])
    {
        CPrintToChat(client, "%s Your mailed Gems are still being checked.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name)))
    {
        return Plugin_Handled;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        CPrintToChat(client, "%s Your Steam identity could not be prepared.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT mail_id, title, gems FROM %s "
        ... "WHERE receiver_steamid64 = '%s' AND gems > 0 AND gems_redeemed = 0 "
        ... "AND (expires_at = 0 OR expires_at > %d) ORDER BY mail_id",
        MAIL_TABLE,
        escapedSteam,
        GetTime());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    g_MailRedeemAllPending[client] = true;
    g_MailDatabase.Query(SQL_OnRedeemAllLoaded, query, pack);
    return Plugin_Handled;
}

public void SQL_OnRedeemAllLoaded(Database db, DBResultSet rows, const char[] error, any data)
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
    g_MailRedeemAllPending[client] = false;

    if (error[0] != '\0' || rows == null)
    {
        LogError("[server_mail] Failed to load redeemable mail: %s", error);
        CPrintToChat(client, "%s Your mailed Gems could not be loaded.", MAIL_PREFIX);
        return;
    }

    int queued = 0;
    int pending = 0;
    int failed = 0;
    int totalGems = 0;
    while (rows.FetchRow())
    {
        int mailId = rows.FetchInt(0);
        char title[MAIL_TITLE_MAX];
        rows.FetchString(1, title, sizeof(title));
        int gems = rows.FetchInt(2);

        MailRedemptionQueueResult result = QueueValidatedMailRedemption(client, mailId, steamId, title, gems);
        if (result == MailRedemption_Queued)
        {
            queued++;
            totalGems += gems;
        }
        else if (result == MailRedemption_AlreadyPending)
        {
            pending++;
        }
        else
        {
            failed++;
        }
    }

    if (queued > 0)
    {
        char currencyColor[40];
        char currencyName[64];
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
        CPrintToChat(client,
            "%s Redeeming {gold}%d{default} mailed Gem attachment%s worth %s%d %s{default}.",
            MAIL_PREFIX,
            queued,
            queued == 1 ? "" : "s",
            currencyColor,
            totalGems,
            currencyName);
    }
    else if (pending > 0)
    {
        CPrintToChat(client, "%s Your mailed Gems are already being redeemed.", MAIL_PREFIX);
    }
    else
    {
        CPrintToChat(client, "%s You have no unredeemed Gems in your inbox.", MAIL_PREFIX);
    }

    if (failed > 0)
    {
        CPrintToChat(client, "%s Some mailed Gems could not be queued. Try again.", MAIL_PREFIX);
    }
}

public Action Command_Gift(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    if (!g_MailDatabaseReady || !IsPointsStoreGiftAvailable())
    {
        CPrintToChat(client, "%s Gifting is temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    if (!CheckMailSendCooldown(client))
    {
        return Plugin_Handled;
    }

    if (args != 2)
    {
        CPrintToChat(client, "%s Usage: {gold}!gift playername amount", MAIL_PREFIX);
        return Plugin_Handled;
    }

    char search[MAIL_NAME_MAX];
    char amountText[32];
    GetCmdArg(1, search, sizeof(search));
    GetCmdArg(2, amountText, sizeof(amountText));
    TrimString(search);
    TrimString(amountText);

    int amount;
    if (search[0] == '\0' || StringToIntEx(amountText, amount) == 0 || amount <= 0)
    {
        CPrintToChat(client, "%s Usage: {gold}!gift playername amount", MAIL_PREFIX);
        return Plugin_Handled;
    }

    if (!PointsStore_AreBonusPointsLoaded(client))
    {
        CPrintToChat(client, "%s Your currency balance is still loading.", MAIL_PREFIX);
        return Plugin_Handled;
    }

    int balance = PointsStore_GetBonusPoints(client);
    if (balance < amount)
    {
        char currencyColor[40];
        char currencyName[64];
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
        CPrintToChat(client,
            "%s You need %s%d %s{default} to send that gift.",
            MAIL_PREFIX,
            currencyColor,
            amount,
            currencyName);
        return Plugin_Handled;
    }

    char currencyColor[40];
    char currencyName[64];
    GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
    strcopy(g_MailPendingSearch[client], sizeof(g_MailPendingSearch[]), search);
    FormatEx(g_MailPendingContents[client], sizeof(g_MailPendingContents[]),
        "You received %d %s.", amount, currencyName);
    g_MailPendingGems[client] = amount;
    RequestMailPlayerSearch(client);
    return Plugin_Handled;
}

public Action Command_MailHug(int client, int args)
{
    return BeginAttachmentMailCommand(client, args, "hug");
}

public Action Command_MailFeed(int client, int args)
{
    return BeginAttachmentMailCommand(client, args, "feed");
}

public Action Command_MailRape(int client, int args)
{
    return BeginAttachmentMailCommand(client, args, "rape");
}

public Action Command_MailRtd(int client, int args)
{
    return BeginAttachmentMailCommand(client, args, "rtd");
}

bool IsHugsMailAvailable(const char[] attachmentType)
{
    if (StrEqual(attachmentType, "hug"))
    {
        return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedHug") == FeatureStatus_Available;
    }
    if (StrEqual(attachmentType, "feed"))
    {
        return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedFeed") == FeatureStatus_Available;
    }
    return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedRape") == FeatureStatus_Available;
}

bool IsRtdMailAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "RTD_ApplyGiftedRoll") == FeatureStatus_Available;
}

public Action BeginAttachmentMailCommand(int client, int args, const char[] attachmentType)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }
    if (!g_MailDatabaseReady)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }
    if (!CheckMailSendCooldown(client))
    {
        return Plugin_Handled;
    }
    if (args != 1)
    {
        CPrintToChat(client, "%s Usage: {gold}!mail%s playername", MAIL_PREFIX, attachmentType);
        return Plugin_Handled;
    }
    if ((StrEqual(attachmentType, "hug") || StrEqual(attachmentType, "feed") || StrEqual(attachmentType, "rape"))
        && !IsHugsMailAvailable(attachmentType))
    {
        CPrintToChat(client, "%s Hug gifts are temporarily unavailable.", MAIL_PREFIX);
        return Plugin_Handled;
    }
    if (StrEqual(attachmentType, "rtd"))
    {
        if (!IsRtdMailAvailable() || !IsPointsStoreGiftAvailable())
        {
            CPrintToChat(client, "%s RTD gifts are temporarily unavailable.", MAIL_PREFIX);
            return Plugin_Handled;
        }
        if (!PointsStore_AreBonusPointsLoaded(client))
        {
            CPrintToChat(client, "%s Your currency balance is still loading.", MAIL_PREFIX);
            return Plugin_Handled;
        }
        if (PointsStore_GetBonusPoints(client) < MAIL_RTD_GIFT_COST)
        {
            CPrintToChat(client, "%s You need {cyan}%d Gems{default} to mail an RTD.", MAIL_PREFIX, MAIL_RTD_GIFT_COST);
            return Plugin_Handled;
        }
    }

    char search[MAIL_NAME_MAX];
    GetCmdArgString(search, sizeof(search));
    StripQuotes(search);
    TrimString(search);
    if (search[0] == '\0')
    {
        CPrintToChat(client, "%s Usage: {gold}!mail%s playername", MAIL_PREFIX, attachmentType);
        return Plugin_Handled;
    }

    strcopy(g_MailPendingSearch[client], sizeof(g_MailPendingSearch[]), search);
    strcopy(g_MailPendingAttachment[client], sizeof(g_MailPendingAttachment[]), attachmentType);
    g_MailPendingGems[client] = 0;
    if (StrEqual(attachmentType, "hug"))
    {
        strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), "You received a one-time hug.");
    }
    else if (StrEqual(attachmentType, "feed"))
    {
        strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), "You received a one-time feed.");
    }
    else if (StrEqual(attachmentType, "rape"))
    {
        strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), "You received a one-time rape.");
    }
    else
    {
        strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), "Open this mail to use your gifted RTD roll.");
    }
    RequestMailPlayerSearch(client);
    return Plugin_Handled;
}

void ShowMailMainMenu(int client)
{
    Menu menu = new Menu(MenuHandler_MailMain);
    menu.SetTitle("Mail");
    menu.AddItem("send", "Send Mail");
    menu.AddItem("gift", "Gift Gems");
    menu.AddItem("inbox", "Check Inbox");
    menu.AddItem("sent", "Read Sent Mail");
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MailMain(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || !IsMailClient(client))
    {
        return 0;
    }

    char info[16];
    menu.GetItem(item, info, sizeof(info));
    if (StrEqual(info, "send"))
    {
        CPrintToChat(client, "%s Type {gold}!mail playername hey how are you?{default} to send a player mail, even an offline player!", MAIL_PREFIX);
    }
    else if (StrEqual(info, "gift"))
    {
        CPrintToChat(client, "%s Type {gold}!gift playername amount{default} to mail a player Gems.", MAIL_PREFIX);
    }
    else if (StrEqual(info, "inbox"))
    {
        RequestMailList(client, MailView_Inbox);
    }
    else if (StrEqual(info, "sent"))
    {
        RequestMailList(client, MailView_Sent);
    }
    return 0;
}

void BeginMailCommand(int client)
{
    if (!g_MailDatabaseReady)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char raw[MAIL_CONTENTS_MAX + MAIL_NAME_MAX];
    GetCmdArgString(raw, sizeof(raw));
    StripQuotes(raw);
    TrimString(raw);

    char search[MAIL_NAME_MAX];
    int position = BreakString(raw, search, sizeof(search));
    if (position == -1)
    {
        CPrintToChat(client, "%s Usage: {gold}!mail playername message", MAIL_PREFIX);
        return;
    }

    char contents[MAIL_CONTENTS_MAX];
    strcopy(contents, sizeof(contents), raw[position]);
    TrimString(search);
    TrimString(contents);
    if (search[0] == '\0' || contents[0] == '\0')
    {
        CPrintToChat(client, "%s Usage: {gold}!mail playername message", MAIL_PREFIX);
        return;
    }

    strcopy(g_MailPendingSearch[client], sizeof(g_MailPendingSearch[]), search);
    strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), contents);
    g_MailPendingGems[client] = 0;
    RequestMailPlayerSearch(client);
}

int GetRankMinimumKillsDeaths()
{
    ConVar convar = FindConVar("sm_whaletracker_rank_min_kd_sum");
    return convar != null ? convar.IntValue : 200;
}

int GetRankMinimumPlaytime()
{
    ConVar convar = FindConVar("sm_whaletracker_rank_min_playtime_seconds");
    return convar != null ? convar.IntValue : 10800;
}

void RequestMailPlayerSearch(int client)
{
    char escapedSearch[(MAIL_NAME_MAX * 2) + 1];
    if (!EscapeMailSql(g_MailPendingSearch[client], escapedSearch, sizeof(escapedSearch)))
    {
        CPrintToChat(client, "%s Could not search for that player.", MAIL_PREFIX);
        return;
    }

    delete g_MailSearchResults[client];
    g_MailSearchResults[client] = null;
    int generation = ++g_MailSearchGeneration[client];

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
        ... "ORDER BY GREATEST(COALESCE(w.playtime, 0), 0) DESC, "
        ... "LOWER(COALESCE(NULLIF(pr.newname COLLATE utf8mb4_uca1400_ai_ci, ''), NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid)) ASC "
        ... "LIMIT %d",
        GetRankMinimumKillsDeaths(),
        GetRankMinimumPlaytime(),
        escapedSearch,
        escapedSearch,
        escapedSearch,
        MAIL_SEARCH_MAX);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(generation);
    g_MailDatabase.Query(SQL_OnMailPlayerSearch, query, pack);
}

int FindSearchResult(ArrayList results, const char[] steamId)
{
    MailSearchResult entry;
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

public void SQL_OnMailPlayerSearch(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    delete pack;

    if (!IsMailClient(client) || generation != g_MailSearchGeneration[client])
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[server_mail] Ranked-player search failed: %s", error);
        CPrintToChat(client, "%s Player search failed.", MAIL_PREFIX);
        return;
    }

    ArrayList results = new ArrayList(sizeof(MailSearchResult));
    MailSearchResult entry;
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
        if (!IsMailClient(target))
        {
            continue;
        }

        char steamId[MAIL_STEAMID_MAX];
        char currentName[MAIL_NAME_MAX];
        if (!Kogasa_GetClientSteamId64(target, steamId, sizeof(steamId), true)
            || !GetClientName(target, currentName, sizeof(currentName)))
        {
            continue;
        }

        int index = FindSearchResult(results, steamId);
        int rankedHours = 0;
        if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeHours") == FeatureStatus_Available)
        {
            rankedHours = WhaleTracker_GetRankedPlaytimeHours(target);
        }

        if (index == -1)
        {
            if (rankedHours <= 0 || StrContains(currentName, g_MailPendingSearch[client], false) == -1)
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
        if (rankedHours > 0)
        {
            entry.playtime = rankedHours * 3600;
        }
        entry.connected = true;
        results.SetArray(index, entry, sizeof(entry));
    }

    results.SortCustom(SortMailSearchResults);
    g_MailSearchResults[client] = results;
    ShowMailSearchResults(client);
}

public int SortMailSearchResults(int index1, int index2, Handle array, Handle data)
{
    ArrayList results = view_as<ArrayList>(array);
    MailSearchResult left;
    MailSearchResult right;
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

void ShowMailSearchResults(int client)
{
    ArrayList results = g_MailSearchResults[client];
    if (results == null || results.Length == 0)
    {
        CPrintToChat(client, "%s No ranked player matched '{gold}%s{default}'.", MAIL_PREFIX, g_MailPendingSearch[client]);
        return;
    }

    Menu menu = new Menu(MenuHandler_MailSearchResults);
    if (StrEqual(g_MailPendingAttachment[client], "hug"))
    {
        menu.SetTitle("Mail a hug to:");
    }
    else if (StrEqual(g_MailPendingAttachment[client], "feed"))
    {
        menu.SetTitle("Mail a feed to:");
    }
    else if (StrEqual(g_MailPendingAttachment[client], "rape"))
    {
        menu.SetTitle("Mail a rape to:");
    }
    else if (StrEqual(g_MailPendingAttachment[client], "rtd"))
    {
        menu.SetTitle("Mail an RTD to:");
    }
    else
    {
        menu.SetTitle(g_MailPendingGems[client] > 0 ? "Gift Gems to:" : "Send mail to:");
    }

    MailSearchResult entry;
    char display[256];
    int count = results.Length;
    if (count > MAIL_SEARCH_MAX)
    {
        count = MAIL_SEARCH_MAX;
    }

    for (int i = 0; i < count; i++)
    {
        results.GetArray(i, entry, sizeof(entry));
        int steamLength = strlen(entry.steamId);
        char suffix[7];
        if (steamLength > 6)
        {
            strcopy(suffix, sizeof(suffix), entry.steamId[steamLength - 6]);
        }
        else
        {
            strcopy(suffix, sizeof(suffix), entry.steamId);
        }
        Format(display, sizeof(display), "%s%s - ...%s",
            entry.name,
            entry.connected ? " [online]" : "",
            suffix);
        menu.AddItem(entry.steamId, display);
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MailSearchResults(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select || !IsMailClient(client)
        || g_MailPendingContents[client][0] == '\0')
    {
        return 0;
    }

    char receiverSteamId[MAIL_STEAMID_MAX];
    menu.GetItem(item, receiverSteamId, sizeof(receiverSteamId));

    char receiverName[MAIL_NAME_MAX];
    strcopy(receiverName, sizeof(receiverName), receiverSteamId);
    ArrayList results = g_MailSearchResults[client];
    int index = results != null ? FindSearchResult(results, receiverSteamId) : -1;
    if (index != -1)
    {
        MailSearchResult entry;
        results.GetArray(index, entry, sizeof(entry));
        strcopy(receiverName, sizeof(receiverName), entry.name);
    }

    QueuePendingMailToTarget(client, receiverSteamId, receiverName, false);
    return 0;
}

void ShowRtdMailCostMenu(int client, const char[] receiverSteamId, const char[] receiverName)
{
    Menu menu = new Menu(MenuHandler_RtdMailCost);
    menu.SetTitle("Spend %d Gems to mail an RTD to %s?", MAIL_RTD_GIFT_COST, receiverName);
    menu.AddItem(receiverSteamId, "Yes");
    menu.AddItem("no", "No");
    menu.ExitButton = true;
    menu.Display(client, 15);
}

public int MenuHandler_RtdMailCost(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && IsMailClient(client))
    {
        ClearClientMailState(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsMailClient(client))
    {
        return 0;
    }

    char receiverSteamId[MAIL_STEAMID_MAX];
    menu.GetItem(item, receiverSteamId, sizeof(receiverSteamId));
    if (StrEqual(receiverSteamId, "no"))
    {
        ClearClientMailState(client);
        return 0;
    }

    char receiverName[MAIL_NAME_MAX];
    strcopy(receiverName, sizeof(receiverName), receiverSteamId);
    ArrayList results = g_MailSearchResults[client];
    int index = results != null ? FindSearchResult(results, receiverSteamId) : -1;
    if (index != -1)
    {
        MailSearchResult entry;
        results.GetArray(index, entry, sizeof(entry));
        strcopy(receiverName, sizeof(receiverName), entry.name);
    }
    QueuePendingMailToTarget(client, receiverSteamId, receiverName, true);
    return 0;
}

void RefundMailSendCost(const char[] senderSteamId, int amount)
{
    if (amount <= 0)
    {
        return;
    }
    if (!IsPointsStoreGiftAvailable()
        || !PointsStore_RefundBonusPointsSteamId(
            senderSteamId,
            amount,
            "server_mail_send_refund"))
    {
        LogError("[server_mail] Failed to refund %d Gems to %s.", amount, senderSteamId);
    }
}

void QueuePendingMailToTarget(
    int client,
    const char[] receiverSteamId,
    const char[] receiverName,
    bool rtdConfirmed)
{
    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, senderSteamId, sizeof(senderSteamId), senderName, sizeof(senderName)))
    {
        CPrintToChat(client, "%s Could not resolve your Steam identity.", MAIL_PREFIX);
        ClearClientMailState(client);
        return;
    }
    if (!CheckMailSendCooldown(client))
    {
        ClearClientMailState(client);
        return;
    }
    if (StrEqual(senderSteamId, receiverSteamId, false))
    {
        CPrintToChat(client, "%s You cannot mail a gift to yourself.", MAIL_PREFIX);
        ClearClientMailState(client);
        return;
    }

    bool isRtd = StrEqual(g_MailPendingAttachment[client], "rtd");
    if (isRtd && !rtdConfirmed)
    {
        ShowRtdMailCostMenu(client, receiverSteamId, receiverName);
        return;
    }

    int gems = g_MailPendingGems[client];
    int senderCost = gems > 0 ? gems : (isRtd ? MAIL_RTD_GIFT_COST : 0);
    if (senderCost > 0)
    {
        if (!IsPointsStoreGiftAvailable() || !PointsStore_AreBonusPointsLoaded(client)
            || PointsStore_GetBonusPoints(client) < senderCost
            || !PointsStore_SpendBonusPoints(client, senderCost))
        {
            CPrintToChat(client, "%s You no longer have enough Gems for that gift.", MAIL_PREFIX);
            ClearClientMailState(client);
            return;
        }
    }

    char requestKey[MAIL_REQUEST_KEY_MAX];
    requestKey[0] = '\0';
    if (senderCost > 0 || g_MailPendingAttachment[client][0] != '\0')
    {
        g_MailGiftSerial++;
        FormatEx(requestKey, sizeof(requestKey),
            "server_mail:gift:%s:%s:%d:%d",
            senderSteamId,
            receiverSteamId,
            GetTime(),
            g_MailGiftSerial);
    }

    char title[MAIL_TITLE_MAX];
    strcopy(title, sizeof(title), "N/A");
    if (StrEqual(g_MailPendingAttachment[client], "hug"))
    {
        FormatEx(title, sizeof(title), "Hug from %s", senderName);
    }
    else if (StrEqual(g_MailPendingAttachment[client], "feed"))
    {
        FormatEx(title, sizeof(title), "Feed from %s", senderName);
    }
    else if (StrEqual(g_MailPendingAttachment[client], "rape"))
    {
        FormatEx(title, sizeof(title), "Rape from %s", senderName);
    }
    else if (isRtd)
    {
        FormatEx(title, sizeof(title), "rtd from %s", senderName);
    }

    bool queued = QueueMailInsert(
        senderSteamId,
        senderName,
        receiverSteamId,
        receiverName,
        title,
        g_MailPendingContents[client],
        gems,
        requestKey,
        GetClientUserId(client),
        true,
        true,
        g_MailPendingAttachment[client],
        senderCost);
    if (!queued)
    {
        RefundMailSendCost(senderSteamId, senderCost);
        CPrintToChat(client, "%s Failed to queue mail. Try again.", MAIL_PREFIX);
    }
    else
    {
        g_MailUserSendPending[client] = true;
    }
    ClearClientMailState(client);
}

void FireMailSendResult(const char[] requestKey, bool success, int mailId, bool newlyCreated)
{
    if (g_MailSendResultForward == null || requestKey[0] == '\0')
    {
        return;
    }

    Call_StartForward(g_MailSendResultForward);
    Call_PushString(requestKey);
    Call_PushCell(success);
    Call_PushCell(mailId);
    Call_PushCell(newlyCreated);
    Call_Finish();
}

bool QueueMailInsert(
    const char[] senderSteamId,
    const char[] senderName,
    const char[] receiverSteamId,
    const char[] receiverName,
    const char[] title,
    const char[] contents,
    int gems,
    const char[] requestKey,
    int senderUserId = 0,
    bool notifyPlayers = false,
    bool userInitiated = false,
    const char[] attachmentType = "",
    int senderCost = 0,
    int createdAtOverride = 0)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null
        || !Kogasa_IsSteamId64(receiverSteamId)
        || senderName[0] == '\0' || receiverName[0] == '\0'
        || title[0] == '\0' || contents[0] == '\0' || gems < 0 || senderCost < 0
        || (attachmentType[0] != '\0'
            && !StrEqual(attachmentType, "hug")
            && !StrEqual(attachmentType, "feed")
            && !StrEqual(attachmentType, "rape")
            && !StrEqual(attachmentType, "rtd")))
    {
        return false;
    }

    if (senderSteamId[0] != '\0' && !Kogasa_IsSteamId64(senderSteamId))
    {
        return false;
    }
    if (gems > 0 && !IsPointsStoreAwardAvailable())
    {
        return false;
    }

    char escapedSenderSteam[65];
    char escapedSenderName[(MAIL_NAME_MAX * 2) + 1];
    char escapedReceiverSteam[65];
    char escapedReceiverName[(MAIL_NAME_MAX * 2) + 1];
    char escapedTitle[(MAIL_TITLE_MAX * 2) + 1];
    char escapedContents[(MAIL_CONTENTS_MAX * 2) + 1];
    char escapedRequest[(MAIL_REQUEST_KEY_MAX * 2) + 1];
    char escapedAttachment[(MAIL_ATTACHMENT_MAX * 2) + 1];
    if (!EscapeMailSql(senderSteamId, escapedSenderSteam, sizeof(escapedSenderSteam))
        || !EscapeMailSql(senderName, escapedSenderName, sizeof(escapedSenderName))
        || !EscapeMailSql(receiverSteamId, escapedReceiverSteam, sizeof(escapedReceiverSteam))
        || !EscapeMailSql(receiverName, escapedReceiverName, sizeof(escapedReceiverName))
        || !EscapeMailSql(title, escapedTitle, sizeof(escapedTitle))
        || !EscapeMailSql(contents, escapedContents, sizeof(escapedContents))
        || !EscapeMailSql(requestKey, escapedRequest, sizeof(escapedRequest))
        || !EscapeMailSql(attachmentType, escapedAttachment, sizeof(escapedAttachment)))
    {
        return false;
    }

    char idempotencyValue[(MAIL_REQUEST_KEY_MAX * 2) + 16];
    if (requestKey[0] == '\0')
    {
        strcopy(idempotencyValue, sizeof(idempotencyValue), "NULL");
    }
    else
    {
        Format(idempotencyValue, sizeof(idempotencyValue), "'%s'", escapedRequest);
    }

    int createdAt = createdAtOverride > 0 ? createdAtOverride : GetTime();
    int expiresAt = Stimulus_GetMailExpiry(title, createdAt);
    char query[4096];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s "
            ... "(sender_steamid64, sender_name, receiver_steamid64, receiver_name, created_at, title, contents, gems, gems_redeemed, attachment_type, attachment_redeemed, expires_at, read_at, idempotency_key) "
            ... "VALUES ('%s', '%s', '%s', '%s', %d, '%s', '%s', %d, 0, '%s', 0, %d, 0, %s) "
            ... "ON DUPLICATE KEY UPDATE mail_id = LAST_INSERT_ID(mail_id)",
            MAIL_TABLE,
            escapedSenderSteam,
            escapedSenderName,
            escapedReceiverSteam,
            escapedReceiverName,
            createdAt,
            escapedTitle,
            escapedContents,
            gems,
            escapedAttachment,
            expiresAt,
            idempotencyValue);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT OR IGNORE INTO %s "
            ... "(sender_steamid64, sender_name, receiver_steamid64, receiver_name, created_at, title, contents, gems, gems_redeemed, attachment_type, attachment_redeemed, expires_at, read_at, idempotency_key) "
            ... "VALUES ('%s', '%s', '%s', '%s', %d, '%s', '%s', %d, 0, '%s', 0, %d, 0, %s)",
            MAIL_TABLE,
            escapedSenderSteam,
            escapedSenderName,
            escapedReceiverSteam,
            escapedReceiverName,
            createdAt,
            escapedTitle,
            escapedContents,
            gems,
            escapedAttachment,
            expiresAt,
            idempotencyValue);
    }

    DataPack pack = new DataPack();
    pack.WriteString(requestKey);
    pack.WriteCell(senderUserId);
    pack.WriteCell(notifyPlayers ? 1 : 0);
    pack.WriteString(senderSteamId);
    pack.WriteString(senderName);
    pack.WriteString(receiverSteamId);
    pack.WriteString(receiverName);
    pack.WriteCell(gems);
    pack.WriteCell(senderCost);
    pack.WriteCell(userInitiated ? 1 : 0);
    g_MailDatabase.Query(SQL_OnMailInserted, query, pack);
    return true;
}

public void SQL_OnMailInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char requestKey[MAIL_REQUEST_KEY_MAX];
    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char receiverSteamId[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    pack.ReadString(requestKey, sizeof(requestKey));
    int senderUserId = pack.ReadCell();
    bool notifyPlayers = view_as<bool>(pack.ReadCell());
    pack.ReadString(senderSteamId, sizeof(senderSteamId));
    pack.ReadString(senderName, sizeof(senderName));
    pack.ReadString(receiverSteamId, sizeof(receiverSteamId));
    pack.ReadString(receiverName, sizeof(receiverName));
    int gems = pack.ReadCell();
    int senderCost = pack.ReadCell();
    bool userInitiated = pack.ReadCell() != 0;
    delete pack;

    if (error[0] != '\0' || results == null)
    {
        if (userInitiated)
        {
            FinishUserMailSend(senderUserId, false);
        }

        LogError("[server_mail] Mail insert failed: %s", error);
        FireMailSendResult(requestKey, false, 0, false);
        Stimulus_OnMailInsertResult(requestKey, false, 0);

        RefundMailSendCost(senderSteamId, senderCost);

        int sender = GetClientOfUserId(senderUserId);
        if (notifyPlayers && IsMailClient(sender))
        {
            CPrintToChat(sender, "%s Failed to send mail.", MAIL_PREFIX);
        }
        return;
    }

    int mailId = results.InsertId;
    bool newlyCreated = results.AffectedRows == 1;
    if (userInitiated)
    {
        FinishUserMailSend(senderUserId, newlyCreated);
    }
    FireMailSendResult(requestKey, true, mailId, newlyCreated);
    Stimulus_OnMailInsertResult(requestKey, true, mailId);

    if (!newlyCreated && senderCost > 0)
    {
        RefundMailSendCost(senderSteamId, senderCost);
    }

    if (!notifyPlayers || !newlyCreated)
    {
        return;
    }

    int receiver = Kogasa_FindClientBySteamId64(receiverSteamId);
    int liveSender = Kogasa_FindClientBySteamId64(senderSteamId);
    if (gems > 0 && StrContains(requestKey, "server_mail:stimulus:", false) == 0)
    {
        char coloredReceiver[256];
        char currencyColor[40];
        char currencyName[64];
        BuildColoredMailName(receiver, receiverSteamId, receiverName, coloredReceiver, sizeof(coloredReceiver));
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));

        if (IsMailClient(receiver))
        {
            CPrintToChatAllEx(receiver,
                "{cornflowerblue}[Mail] %s{default} received a Stimulus Check! (%s%d %s{default})",
                coloredReceiver,
                currencyColor,
                gems,
                currencyName);
        }
        else
        {
            CPrintToChatAll(
                "{cornflowerblue}[Mail] %s{default} received a Stimulus Check! (%s%d %s{default})",
                coloredReceiver,
                currencyColor,
                gems,
                currencyName);
        }
        return;
    }

    if (gems > 0 && StrContains(requestKey, "server_mail:gift:", false) == 0)
    {
        char coloredSender[256];
        char coloredReceiver[256];
        char currencyColor[40];
        char currencyName[64];
        BuildColoredMailName(liveSender, senderSteamId, senderName, coloredSender, sizeof(coloredSender));
        BuildColoredMailName(receiver, receiverSteamId, receiverName, coloredReceiver, sizeof(coloredReceiver));
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));

        int author = IsMailClient(liveSender) ? liveSender : receiver;
        if (IsMailClient(author))
        {
            CPrintToChatAllEx(author,
                "{cornflowerblue}[Mail] %s{default} gifted %s{default} %s%d %s{default}!",
                coloredSender,
                coloredReceiver,
                currencyColor,
                gems,
                currencyName);
        }
        else
        {
            CPrintToChatAll(
                "{cornflowerblue}[Mail] %s{default} gifted %s{default} %s%d %s{default}!",
                coloredSender,
                coloredReceiver,
                currencyColor,
                gems,
                currencyName);
        }
        return;
    }

    int sender = GetClientOfUserId(senderUserId);
    if (IsMailClient(sender))
    {
        char coloredReceiver[256];
        BuildColoredMailName(receiver, receiverSteamId, receiverName, coloredReceiver, sizeof(coloredReceiver));
        CPrintToChatEx(sender, receiver > 0 ? receiver : sender, "%s Sent to %s{default}.", MAIL_PREFIX, coloredReceiver);
    }

    if (IsMailClient(receiver))
    {
        char coloredSender[256];
        BuildColoredMailName(liveSender, senderSteamId, senderName, coloredSender, sizeof(coloredSender));
        CPrintToChatEx(receiver, liveSender > 0 ? liveSender : receiver,
            "{cornflowerblue}[Mail] %s{default} sent you mail!",
            coloredSender);
    }
}

void BuildMailListDisplay(
    const char[] title,
    int timestamp,
    int gems,
    const char[] partyName,
    bool unread,
    char[] output,
    int maxlen)
{
    char date[32];
    char currencyColor[40];
    char currencyName[64];
    char markedPartyName[MAIL_NAME_MAX + 8];
    FormatTime(date, sizeof(date), "%m-%d-%Y", timestamp);
    GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
    FormatEx(markedPartyName, sizeof(markedPartyName), unread ? "%s (!)" : "%s", partyName);

    if (StrEqual(title, "N/A", false))
    {
        if (gems > 0)
        {
            FormatEx(output, maxlen, "%s (%d %s) - %s", markedPartyName, gems, currencyName, date);
        }
        else
        {
            FormatEx(output, maxlen, "%s - %s", markedPartyName, date);
        }
        return;
    }

    if (gems > 0)
    {
        FormatEx(output, maxlen, "%s (%d %s) - %s - %s", markedPartyName, gems, currencyName, title, date);
    }
    else
    {
        FormatEx(output, maxlen, "%s - %s - %s", markedPartyName, title, date);
    }
}

void RequestMailList(int client, MailViewMode mode)
{
    if (!g_MailDatabaseReady)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name)))
    {
        return;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        return;
    }

    char query[1024];
    int now = GetTime();
    if (mode != MailView_Sent)
    {
        char unreadClause[32];
        strcopy(unreadClause, sizeof(unreadClause), mode == MailView_Unread ? "AND read_at = 0 " : "");
        FormatEx(query, sizeof(query),
            "SELECT mail_id, title, created_at, gems, sender_name, read_at FROM %s "
            ... "WHERE receiver_steamid64 = '%s' "
            ... "AND (expires_at = 0 OR expires_at > %d OR gems_redeemed != 0) "
            ... "%s"
            ... "ORDER BY created_at DESC, mail_id DESC LIMIT %d",
            MAIL_TABLE,
            escapedSteam,
            now,
            unreadClause,
            MAIL_LIST_MAX);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "SELECT mail_id, title, created_at, gems, receiver_name, read_at FROM %s "
            ... "WHERE sender_steamid64 = '%s' "
            ... "AND (expires_at = 0 OR expires_at > %d OR gems_redeemed != 0) "
            ... "ORDER BY created_at DESC, mail_id DESC LIMIT %d",
            MAIL_TABLE,
            escapedSteam,
            now,
            MAIL_LIST_MAX);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(view_as<int>(mode));
    g_MailDatabase.Query(SQL_OnMailListLoaded, query, pack);
}

public void SQL_OnMailListLoaded(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    MailViewMode mode = view_as<MailViewMode>(pack.ReadCell());
    delete pack;

    if (!IsMailClient(client))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[server_mail] Mail list query failed: %s", error);
        CPrintToChat(client, "%s Failed to load mail.", MAIL_PREFIX);
        return;
    }

    Menu menu = new Menu(MenuHandler_MailList);
    if (mode == MailView_Unread)
    {
        menu.SetTitle("Unread Mail");
    }
    else
    {
        menu.SetTitle(mode == MailView_Inbox ? "Inbox" : "Sent Mail");
    }

    char info[32];
    char title[MAIL_TITLE_MAX];
    char partyName[MAIL_NAME_MAX];
    char display[384];
    int count;
    while (rows != null && rows.FetchRow())
    {
        int mailId = rows.FetchInt(0);
        rows.FetchString(1, title, sizeof(title));
        int timestamp = rows.FetchInt(2);
        int gems = rows.FetchInt(3);
        rows.FetchString(4, partyName, sizeof(partyName));
        bool unread = mode != MailView_Sent && rows.FetchInt(5) == 0;
        BuildMailListDisplay(title, timestamp, gems, partyName, unread, display, sizeof(display));

        Format(info, sizeof(info), "%c:%d", mode == MailView_Sent ? 's' : 'i', mailId);
        menu.AddItem(info, display);
        count++;
    }

    if (count == 0)
    {
        if (mode == MailView_Unread)
        {
            menu.AddItem("none", "No unread mail", ITEMDRAW_DISABLED);
        }
        else
        {
            menu.AddItem("none", mode == MailView_Inbox ? "No received mail" : "No sent mail", ITEMDRAW_DISABLED);
        }
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MailList(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && IsMailClient(client))
    {
        ShowMailMainMenu(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsMailClient(client))
    {
        return 0;
    }

    char info[32];
    menu.GetItem(item, info, sizeof(info));
    if (info[1] != ':' || (info[0] != 'i' && info[0] != 's'))
    {
        return 0;
    }

    RequestMailDetails(client, StringToInt(info[2]), info[0] == 'i' ? MailView_Inbox : MailView_Sent);
    return 0;
}

void RequestMailDetails(int client, int mailId, MailViewMode mode)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null)
    {
        CPrintToChat(client, "%s Mail is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    if (mailId <= 0 || !GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name)))
    {
        return;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        return;
    }
    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT mail_id, sender_steamid64, sender_name, receiver_steamid64, receiver_name, contents, gems, gems_redeemed, attachment_type, attachment_redeemed "
        ... "FROM %s WHERE mail_id = %d AND %s = '%s' "
        ... "AND (expires_at = 0 OR expires_at > %d OR gems_redeemed != 0) LIMIT 1",
        MAIL_TABLE,
        mailId,
        mode == MailView_Inbox ? "receiver_steamid64" : "sender_steamid64",
        escapedSteam,
        GetTime());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(view_as<int>(mode));
    g_MailDatabase.Query(SQL_OnMailDetailsLoaded, query, pack);
}

void MarkMailRead(int mailId)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null || mailId <= 0)
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET read_at = %d WHERE mail_id = %d AND read_at = 0",
        MAIL_TABLE,
        GetTime(),
        mailId);
    g_MailDatabase.Query(SQL_OnMailMarkedRead, query);
}

public void SQL_OnMailMarkedRead(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[server_mail] Failed to mark mail as read: %s", error);
    }
}

public void SQL_OnMailDetailsLoaded(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    MailViewMode mode = view_as<MailViewMode>(pack.ReadCell());
    delete pack;

    if (!IsMailClient(client))
    {
        return;
    }
    if (error[0] != '\0' || rows == null || !rows.FetchRow())
    {
        CPrintToChat(client, "%s That mail could not be loaded.", MAIL_PREFIX);
        return;
    }

    int mailId = rows.FetchInt(0);
    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char receiverSteamId[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    char contents[MAIL_CONTENTS_MAX];
    rows.FetchString(1, senderSteamId, sizeof(senderSteamId));
    rows.FetchString(2, senderName, sizeof(senderName));
    rows.FetchString(3, receiverSteamId, sizeof(receiverSteamId));
    rows.FetchString(4, receiverName, sizeof(receiverName));
    rows.FetchString(5, contents, sizeof(contents));
    int gems = rows.FetchInt(6);
    bool redeemed = rows.FetchInt(7) != 0;
    char attachmentType[MAIL_ATTACHMENT_MAX];
    rows.FetchString(8, attachmentType, sizeof(attachmentType));
    bool attachmentRedeemed = rows.FetchInt(9) == 1;

    if (mode == MailView_Inbox)
    {
        MarkMailRead(mailId);

        bool hugsInteraction = StrEqual(attachmentType, "hug")
            || StrEqual(attachmentType, "feed")
            || StrEqual(attachmentType, "rape");
        if (!hugsInteraction)
        {
            int sender = Kogasa_FindClientBySteamId64(senderSteamId);
            char coloredSender[256];
            BuildColoredMailName(sender, senderSteamId, senderName, coloredSender, sizeof(coloredSender));
            CPrintToChatEx(client,
                sender > 0 ? sender : client,
                "{cornflowerblue}[Mail] %s{default}: %s",
                coloredSender,
                contents);
        }
        else if (attachmentRedeemed
            && GetFeatureStatus(FeatureType_Native, "Hugs_AnnounceMailedInteraction") == FeatureStatus_Available)
        {
            Hugs_AnnounceMailedInteraction(
                client,
                senderSteamId,
                senderName,
                attachmentType);
        }

        if (gems > 0 && !redeemed)
        {
            BeginMailRedemption(client, mailId);
        }
        if (attachmentType[0] != '\0' && !attachmentRedeemed)
        {
            BeginMailAttachmentRedemption(client, mailId);
        }
        return;
    }

    int receiver = Kogasa_FindClientBySteamId64(receiverSteamId);
    char coloredReceiver[256];
    BuildColoredMailName(receiver, receiverSteamId, receiverName, coloredReceiver, sizeof(coloredReceiver));
    CPrintToChatEx(client,
        receiver > 0 ? receiver : client,
        "{cornflowerblue}[Mail]{default} To %s{default}: %s",
        coloredReceiver,
        contents);
}

void BeginMailRedemption(int client, int mailId)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null
        || !IsPointsStoreAwardAvailable() || mailId <= 0)
    {
        CPrintToChat(client, "%s Currency redemption is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char awardKey[MAIL_REQUEST_KEY_MAX];
    Format(awardKey, sizeof(awardKey), "server_mail:redeem:%d", mailId);
    int unused;
    if (g_MailPendingRedemptions.GetValue(awardKey, unused))
    {
        CPrintToChat(client, "%s This attachment is already being redeemed.", MAIL_PREFIX);
        return;
    }

    char steamId[MAIL_STEAMID_MAX];
    char name[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, steamId, sizeof(steamId), name, sizeof(name)))
    {
        return;
    }

    char escapedSteam[65];
    EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam));
    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT title, gems FROM %s "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' "
        ... "AND gems > 0 AND gems_redeemed = 0 "
        ... "AND (expires_at = 0 OR expires_at > %d) LIMIT 1",
        MAIL_TABLE,
        mailId,
        escapedSteam,
        GetTime());

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(mailId);
    pack.WriteString(steamId);
    g_MailDatabase.Query(SQL_OnMailRedemptionValidated, query, pack);
}

public void SQL_OnMailRedemptionValidated(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int mailId = pack.ReadCell();
    char steamId[MAIL_STEAMID_MAX];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (!IsMailClient(client))
    {
        return;
    }
    if (error[0] != '\0' || rows == null || !rows.FetchRow())
    {
        CPrintToChat(client, "%s This attachment is unavailable or already redeemed.", MAIL_PREFIX);
        return;
    }

    char title[MAIL_TITLE_MAX];
    rows.FetchString(0, title, sizeof(title));
    int gems = rows.FetchInt(1);

    MailRedemptionQueueResult result = QueueValidatedMailRedemption(client, mailId, steamId, title, gems);
    if (result == MailRedemption_AlreadyPending)
    {
        CPrintToChat(client, "%s This attachment is already being redeemed.", MAIL_PREFIX);
    }
    else if (result == MailRedemption_Failed)
    {
        CPrintToChat(client, "%s Currency redemption could not be queued. Try again.", MAIL_PREFIX);
    }
}

MailRedemptionQueueResult QueueValidatedMailRedemption(
    int client,
    int mailId,
    const char[] steamId,
    const char[] rawTitle,
    int gems)
{
    if (!IsMailClient(client) || mailId <= 0 || gems <= 0 || !IsPointsStoreAwardAvailable())
    {
        return MailRedemption_Failed;
    }

    char awardKey[MAIL_REQUEST_KEY_MAX];
    Format(awardKey, sizeof(awardKey), "server_mail:redeem:%d", mailId);
    int unused;
    if (g_MailPendingRedemptions.GetValue(awardKey, unused))
    {
        return MailRedemption_AlreadyPending;
    }

    char title[MAIL_TITLE_MAX];
    strcopy(title, sizeof(title), rawTitle);
    if (StrEqual(title, "N/A", false))
    {
        char currencyColor[40];
        char currencyName[64];
        GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
        FormatEx(title, sizeof(title), "%d %s", gems, currencyName);
    }

    g_MailPendingRedemptions.SetValue(awardKey, mailId);
    g_MailRedemptionUsers.SetValue(awardKey, GetClientUserId(client));
    g_MailRedemptionTitles.SetString(awardKey, title);
    g_MailRedemptionSteamIds.SetString(awardKey, steamId);
    g_MailRedemptionAmounts.SetValue(awardKey, gems);

    if (!PointsStore_ApplyBonusPointsSteamIdOnce(steamId, gems, awardKey, "server_mail_redemption"))
    {
        ClearPendingRedemption(awardKey);
        return MailRedemption_Failed;
    }

    return MailRedemption_Queued;
}

void ClearPendingRedemption(const char[] awardKey)
{
    g_MailPendingRedemptions.Remove(awardKey);
    g_MailRedemptionUsers.Remove(awardKey);
    g_MailRedemptionTitles.Remove(awardKey);
    g_MailRedemptionSteamIds.Remove(awardKey);
    g_MailRedemptionAmounts.Remove(awardKey);
}

public void PointsStore_OnApplyBonusPointsSteamIdOnce(const char[] awardKey, bool success, bool newlyApplied)
{
    int mailId;
    if (!g_MailPendingRedemptions.GetValue(awardKey, mailId))
    {
        return;
    }

    int userId;
    int gems;
    char steamId[MAIL_STEAMID_MAX];
    char title[MAIL_TITLE_MAX];
    g_MailRedemptionUsers.GetValue(awardKey, userId);
    g_MailRedemptionAmounts.GetValue(awardKey, gems);
    g_MailRedemptionSteamIds.GetString(awardKey, steamId, sizeof(steamId));
    g_MailRedemptionTitles.GetString(awardKey, title, sizeof(title));

    if (!success)
    {
        int client = GetClientOfUserId(userId);
        if (IsMailClient(client))
        {
            CPrintToChat(client, "%s Currency redemption failed. Try again.", MAIL_PREFIX);
        }
        ClearPendingRedemption(awardKey);
        return;
    }

    char escapedSteam[65];
    if (!EscapeMailSql(steamId, escapedSteam, sizeof(escapedSteam)))
    {
        ClearPendingRedemption(awardKey);
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET gems_redeemed = 1, expires_at = 0, "
        ... "read_at = CASE WHEN read_at = 0 THEN %d ELSE read_at END "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' AND gems_redeemed = 0",
        MAIL_TABLE,
        GetTime(),
        mailId,
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteString(awardKey);
    pack.WriteCell(userId);
    pack.WriteString(steamId);
    pack.WriteString(title);
    pack.WriteCell(gems);
    g_MailDatabase.Query(SQL_OnMailMarkedRedeemed, query, pack);
}

public void SQL_OnMailMarkedRedeemed(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    char awardKey[MAIL_REQUEST_KEY_MAX];
    char steamId[MAIL_STEAMID_MAX];
    char title[MAIL_TITLE_MAX];
    pack.ReadString(awardKey, sizeof(awardKey));
    int userId = pack.ReadCell();
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(title, sizeof(title));
    int gems = pack.ReadCell();
    delete pack;
    ClearPendingRedemption(awardKey);

    if (error[0] != '\0' || results == null || results.AffectedRows <= 0)
    {
        if (error[0] != '\0')
        {
            LogError("[server_mail] Failed to mark mail redeemed: %s", error);
        }
        return;
    }

    int client = GetClientOfUserId(userId);
    char fallbackName[MAIL_NAME_MAX];
    strcopy(fallbackName, sizeof(fallbackName), steamId);
    if (IsMailClient(client))
    {
        GetClientName(client, fallbackName, sizeof(fallbackName));
    }
    else if (GetFeatureStatus(FeatureType_Native, "Filters_GetLastRecordedSteamName") == FeatureStatus_Available)
    {
        Filters_GetLastRecordedSteamName(steamId, fallbackName, sizeof(fallbackName));
    }

    char coloredName[256];
    char currencyColor[40];
    char currencyName[64];
    BuildColoredMailName(client, steamId, fallbackName, coloredName, sizeof(coloredName));
    GetCurrencyFormatting(currencyColor, sizeof(currencyColor), currencyName, sizeof(currencyName));
    if (StrEqual(title, "Stimulus Check", false) && IsMailClient(client))
    {
        CPrintToChatAllEx(client,
            "{cornflowerblue}[Mail] %s{default} redeemed %s%d %s{default} from a %sStimulus Check{default}!",
            coloredName,
            currencyColor,
            gems,
            currencyName,
            currencyColor);
    }
    else if (StrEqual(title, "Stimulus Check", false))
    {
        CPrintToChatAll(
            "{cornflowerblue}[Mail] %s{default} redeemed %s%d %s{default} from a %sStimulus Check{default}!",
            coloredName,
            currencyColor,
            gems,
            currencyName,
            currencyColor);
    }
    else if (IsMailClient(client))
    {
        CPrintToChatAllEx(client,
            "{cornflowerblue}[Mail] %s{default} redeemed %s%s{default}!",
            coloredName,
            currencyColor,
            title);
    }
    else
    {
        CPrintToChatAll(
            "{cornflowerblue}[Mail] %s{default} redeemed %s%s{default}!",
            coloredName,
            currencyColor,
            title);
    }

    SaySounds_TryPlayCommand(0, "xp_levelup", true);
}

void BuildMailAttachmentKey(int mailId, char[] key, int maxlen)
{
    FormatEx(key, maxlen, "server_mail:attachment:%d", mailId);
}

bool IsMailAttachmentProviderAvailable(const char[] attachmentType)
{
    if (StrEqual(attachmentType, "hug"))
    {
        return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedHug") == FeatureStatus_Available;
    }
    if (StrEqual(attachmentType, "feed"))
    {
        return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedFeed") == FeatureStatus_Available;
    }
    if (StrEqual(attachmentType, "rape"))
    {
        return GetFeatureStatus(FeatureType_Native, "Hugs_RedeemMailedRape") == FeatureStatus_Available;
    }
    if (StrEqual(attachmentType, "rtd"))
    {
        return GetFeatureStatus(FeatureType_Native, "RTD_ApplyGiftedRoll") == FeatureStatus_Available;
    }
    return false;
}

void BeginMailAttachmentRedemption(int client, int mailId)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null || mailId <= 0)
    {
        CPrintToChat(client, "%s That attachment is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char key[MAIL_REQUEST_KEY_MAX];
    BuildMailAttachmentKey(mailId, key, sizeof(key));
    int unused;
    if (g_MailPendingAttachments.GetValue(key, unused))
    {
        CPrintToChat(client, "%s That attachment is already being used.", MAIL_PREFIX);
        return;
    }

    char receiverSteamId[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(
            client,
            receiverSteamId,
            sizeof(receiverSteamId),
            receiverName,
            sizeof(receiverName)))
    {
        return;
    }

    char escapedReceiver[65];
    if (!EscapeMailSql(receiverSteamId, escapedReceiver, sizeof(escapedReceiver)))
    {
        return;
    }

    g_MailPendingAttachments.SetValue(key, GetClientUserId(client));
    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT sender_steamid64, sender_name, attachment_type FROM %s "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' "
        ... "AND attachment_type != '' AND attachment_redeemed = 0 LIMIT 1",
        MAIL_TABLE,
        mailId,
        escapedReceiver);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(mailId);
    pack.WriteString(receiverSteamId);
    g_MailDatabase.Query(SQL_OnMailAttachmentValidated, query, pack);
}

public void SQL_OnMailAttachmentValidated(Database db, DBResultSet rows, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int mailId = pack.ReadCell();
    char receiverSteamId[MAIL_STEAMID_MAX];
    pack.ReadString(receiverSteamId, sizeof(receiverSteamId));
    delete pack;

    char key[MAIL_REQUEST_KEY_MAX];
    BuildMailAttachmentKey(mailId, key, sizeof(key));
    int client = GetClientOfUserId(userId);
    if (!IsMailClient(client))
    {
        g_MailPendingAttachments.Remove(key);
        return;
    }
    if (error[0] != '\0' || rows == null || !rows.FetchRow())
    {
        if (error[0] != '\0')
        {
            LogError("[server_mail] Attachment validation failed: %s", error);
        }
        g_MailPendingAttachments.Remove(key);
        CPrintToChat(client, "%s That attachment is unavailable or already used.", MAIL_PREFIX);
        return;
    }

    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char attachmentType[MAIL_ATTACHMENT_MAX];
    rows.FetchString(0, senderSteamId, sizeof(senderSteamId));
    rows.FetchString(1, senderName, sizeof(senderName));
    rows.FetchString(2, attachmentType, sizeof(attachmentType));
    if (!IsMailAttachmentProviderAvailable(attachmentType))
    {
        g_MailPendingAttachments.Remove(key);
        CPrintToChat(client, "%s That attachment's plugin is temporarily unavailable.", MAIL_PREFIX);
        return;
    }

    char escapedReceiver[65];
    if (!EscapeMailSql(receiverSteamId, escapedReceiver, sizeof(escapedReceiver)))
    {
        g_MailPendingAttachments.Remove(key);
        return;
    }
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET attachment_redeemed = 2 "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' AND attachment_redeemed = 0",
        MAIL_TABLE,
        mailId,
        escapedReceiver);

    DataPack claimPack = new DataPack();
    claimPack.WriteCell(userId);
    claimPack.WriteCell(mailId);
    claimPack.WriteString(receiverSteamId);
    claimPack.WriteString(senderSteamId);
    claimPack.WriteString(senderName);
    claimPack.WriteString(attachmentType);
    g_MailDatabase.Query(SQL_OnMailAttachmentClaimed, query, claimPack);
}

void SetMailAttachmentState(
    int mailId,
    const char[] receiverSteamId,
    int fromState,
    int toState,
    int userId,
    const char[] attachmentType)
{
    char escapedReceiver[65];
    char key[MAIL_REQUEST_KEY_MAX];
    BuildMailAttachmentKey(mailId, key, sizeof(key));
    if (!EscapeMailSql(receiverSteamId, escapedReceiver, sizeof(escapedReceiver)))
    {
        g_MailPendingAttachments.Remove(key);
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE %s SET attachment_redeemed = %d "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' AND attachment_redeemed = %d",
        MAIL_TABLE,
        toState,
        mailId,
        escapedReceiver,
        fromState);
    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteCell(mailId);
    pack.WriteCell(toState);
    pack.WriteString(attachmentType);
    g_MailDatabase.Query(SQL_OnMailAttachmentStateSet, query, pack);
}

public void SQL_OnMailAttachmentClaimed(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    int mailId = pack.ReadCell();
    char receiverSteamId[MAIL_STEAMID_MAX];
    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char attachmentType[MAIL_ATTACHMENT_MAX];
    pack.ReadString(receiverSteamId, sizeof(receiverSteamId));
    pack.ReadString(senderSteamId, sizeof(senderSteamId));
    pack.ReadString(senderName, sizeof(senderName));
    pack.ReadString(attachmentType, sizeof(attachmentType));
    delete pack;

    char key[MAIL_REQUEST_KEY_MAX];
    BuildMailAttachmentKey(mailId, key, sizeof(key));
    int client = GetClientOfUserId(userId);
    if (error[0] != '\0' || results == null || results.AffectedRows != 1)
    {
        if (error[0] != '\0')
        {
            LogError("[server_mail] Attachment claim failed: %s", error);
        }
        g_MailPendingAttachments.Remove(key);
        if (IsMailClient(client))
        {
            CPrintToChat(client, "%s That attachment is unavailable or already being used.", MAIL_PREFIX);
        }
        return;
    }

    bool applied = false;
    bool providerAvailable = IsMailAttachmentProviderAvailable(attachmentType);
    if (providerAvailable && IsMailClient(client) && StrEqual(attachmentType, "hug"))
    {
        applied = Hugs_RedeemMailedHug(senderSteamId, receiverSteamId, senderName);
    }
    else if (providerAvailable && IsMailClient(client) && StrEqual(attachmentType, "feed"))
    {
        applied = Hugs_RedeemMailedFeed(senderSteamId, receiverSteamId, senderName);
    }
    else if (providerAvailable && IsMailClient(client) && StrEqual(attachmentType, "rape"))
    {
        applied = Hugs_RedeemMailedRape(senderSteamId, receiverSteamId, senderName);
    }
    else if (providerAvailable && IsMailClient(client) && StrEqual(attachmentType, "rtd"))
    {
        applied = RTD_ApplyGiftedRoll(client);
    }

    if (!applied && IsMailClient(client))
    {
        CPrintToChat(client, "%s That attachment could not be used now; it remains in your inbox.", MAIL_PREFIX);
    }
    SetMailAttachmentState(
        mailId,
        receiverSteamId,
        2,
        applied ? 1 : 0,
        userId,
        attachmentType);
}

public void SQL_OnMailAttachmentStateSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    pack.ReadCell();
    int mailId = pack.ReadCell();
    pack.ReadCell();
    char attachmentType[MAIL_ATTACHMENT_MAX];
    pack.ReadString(attachmentType, sizeof(attachmentType));
    delete pack;

    char key[MAIL_REQUEST_KEY_MAX];
    BuildMailAttachmentKey(mailId, key, sizeof(key));
    g_MailPendingAttachments.Remove(key);
    if (error[0] != '\0' || results == null || results.AffectedRows != 1)
    {
        LogError("[server_mail] Failed to finalize %s attachment %d: %s", attachmentType, mailId, error);
        return;
    }

}

bool ValidateNativeStringLength(int param, int maxlen)
{
    int length;
    return GetNativeStringLength(param, length) == SP_ERROR_NONE && length > 0 && length < maxlen;
}

bool QueueConnectedNativeMail(int numParams, bool customTitle, bool currency)
{
    int sender = GetNativeCell(1);
    int receiver = GetNativeCell(2);
    if ((sender != 0 && !IsMailClient(sender)) || !IsMailClient(receiver))
    {
        return false;
    }

    int titleParam = customTitle ? 3 : 0;
    int contentsParam = customTitle ? 4 : 3;
    int gemsParam = currency ? 5 : 0;
    int requestParam = currency ? 6 : (customTitle ? 5 : 4);
    if (!ValidateNativeStringLength(contentsParam, MAIL_CONTENTS_MAX)
        || (customTitle && !ValidateNativeStringLength(titleParam, MAIL_TITLE_MAX)))
    {
        return false;
    }

    char senderSteam[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char receiverSteam[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(sender, senderSteam, sizeof(senderSteam), senderName, sizeof(senderName))
        || !GetMailClientIdentity(receiver, receiverSteam, sizeof(receiverSteam), receiverName, sizeof(receiverName)))
    {
        return false;
    }

    char title[MAIL_TITLE_MAX];
    char contents[MAIL_CONTENTS_MAX];
    char requestKey[MAIL_REQUEST_KEY_MAX];
    if (customTitle)
    {
        GetNativeString(titleParam, title, sizeof(title));
    }
    else
    {
        strcopy(title, sizeof(title), senderName);
    }
    GetNativeString(contentsParam, contents, sizeof(contents));
    requestKey[0] = '\0';
    if (numParams >= requestParam)
    {
        GetNativeString(requestParam, requestKey, sizeof(requestKey));
    }
    int gems = currency ? GetNativeCell(gemsParam) : 0;

    return QueueMailInsert(
        senderSteam,
        senderName,
        receiverSteam,
        receiverName,
        title,
        contents,
        gems,
        requestKey,
        sender > 0 ? GetClientUserId(sender) : 0,
        true);
}

bool QueueSteamNativeMail(int numParams, bool customTitle, bool currency)
{
    int titleParam = customTitle ? 4 : 0;
    int contentsParam = customTitle ? 5 : 4;
    int gemsParam = currency ? 6 : 0;
    int requestParam = currency ? 7 : (customTitle ? 6 : 5);
    if (!ValidateNativeStringLength(2, MAIL_NAME_MAX)
        || !ValidateNativeStringLength(3, MAIL_STEAMID_MAX)
        || !ValidateNativeStringLength(contentsParam, MAIL_CONTENTS_MAX)
        || (customTitle && !ValidateNativeStringLength(titleParam, MAIL_TITLE_MAX)))
    {
        return false;
    }

    char senderSteam[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    char receiverSteam[MAIL_STEAMID_MAX];
    char receiverName[MAIL_NAME_MAX];
    char title[MAIL_TITLE_MAX];
    char contents[MAIL_CONTENTS_MAX];
    char requestKey[MAIL_REQUEST_KEY_MAX];
    GetNativeString(1, senderSteam, sizeof(senderSteam));
    GetNativeString(2, senderName, sizeof(senderName));
    GetNativeString(3, receiverSteam, sizeof(receiverSteam));

    int receiver = Kogasa_FindClientBySteamId64(receiverSteam);
    strcopy(receiverName, sizeof(receiverName), receiverSteam);
    if (IsMailClient(receiver))
    {
        GetClientName(receiver, receiverName, sizeof(receiverName));
    }
    else if (GetFeatureStatus(FeatureType_Native, "Filters_GetLastRecordedSteamName") == FeatureStatus_Available)
    {
        Filters_GetLastRecordedSteamName(receiverSteam, receiverName, sizeof(receiverName));
    }

    if (customTitle)
    {
        GetNativeString(titleParam, title, sizeof(title));
    }
    else
    {
        strcopy(title, sizeof(title), senderName);
    }
    GetNativeString(contentsParam, contents, sizeof(contents));
    requestKey[0] = '\0';
    if (numParams >= requestParam)
    {
        GetNativeString(requestParam, requestKey, sizeof(requestKey));
    }
    int gems = currency ? GetNativeCell(gemsParam) : 0;

    return QueueMailInsert(
        senderSteam,
        senderName,
        receiverSteam,
        receiverName,
        title,
        contents,
        gems,
        requestKey,
        0,
        true);
}

public any Native_ServerMail_Send(Handle plugin, int numParams)
{
    return QueueConnectedNativeMail(numParams, false, false);
}

public any Native_ServerMail_SendCustom(Handle plugin, int numParams)
{
    return QueueConnectedNativeMail(numParams, true, false);
}

public any Native_ServerMail_SendCurrency(Handle plugin, int numParams)
{
    return QueueConnectedNativeMail(numParams, true, true);
}

public any Native_ServerMail_SendSteamId(Handle plugin, int numParams)
{
    return QueueSteamNativeMail(numParams, false, false);
}

public any Native_ServerMail_SendCustomSteamId(Handle plugin, int numParams)
{
    return QueueSteamNativeMail(numParams, true, false);
}

public any Native_ServerMail_SendCurrencySteamId(Handle plugin, int numParams)
{
    return QueueSteamNativeMail(numParams, true, true);
}

#include "server_mail/stimulus.sp"
