#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <multicolors>

#undef REQUIRE_PLUGIN
#include <filters_api>
#include <points_store_api>
#include <saysounds>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/kogasa_steam_identity.inc"

#define MAIL_DB_CONFIG "server_mail"
#define MAIL_TABLE "mail"
#define MAIL_STEAMID_MAX 32
#define MAIL_NAME_MAX 128
#define MAIL_TITLE_MAX 128
#define MAIL_CONTENTS_MAX 512
#define MAIL_REQUEST_KEY_MAX 128
#define MAIL_SEARCH_MAX 64
#define MAIL_LIST_MAX 50
#define MAIL_RECONNECT_DELAY 5.0
#define MAIL_PREFIX "{cornflowerblue}[Mail]{default}"

enum MailViewMode
{
    MailView_Inbox = 0,
    MailView_Sent
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

ArrayList g_MailSearchResults[MAXPLAYERS + 1];
char g_MailPendingContents[MAXPLAYERS + 1][MAIL_CONTENTS_MAX];
char g_MailPendingSearch[MAXPLAYERS + 1][MAIL_NAME_MAX];
int g_MailSearchGeneration[MAXPLAYERS + 1];

StringMap g_MailPendingRedemptions = null;
StringMap g_MailRedemptionUsers = null;
StringMap g_MailRedemptionTitles = null;
StringMap g_MailRedemptionSteamIds = null;

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

    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("Filters_GetSteamIdColorTag");
    MarkNativeAsOptional("Filters_GetLastRecordedSteamName");
    MarkNativeAsOptional("PointsStore_ApplyBonusPointsSteamIdOnce");
    MarkNativeAsOptional("SaySounds_PlayCommand");
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
    RegConsoleCmd("sm_send", Command_SendMail, "Send mail to a ranked player.");

    g_MailPendingRedemptions = new StringMap();
    g_MailRedemptionUsers = new StringMap();
    g_MailRedemptionTitles = new StringMap();
    g_MailRedemptionSteamIds = new StringMap();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            ClearClientMailState(client);
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

    for (int client = 1; client <= MaxClients; client++)
    {
        delete g_MailSearchResults[client];
    }

    if (g_MailReconnectTimer != null)
    {
        delete g_MailReconnectTimer;
        g_MailReconnectTimer = null;
    }
    delete g_MailDatabase;
    g_MailDatabase = null;
}

public void OnClientDisconnect(int client)
{
    ClearClientMailState(client);
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
}

void ClearClientMailState(int client)
{
    delete g_MailSearchResults[client];
    g_MailSearchResults[client] = null;
    g_MailPendingContents[client][0] = '\0';
    g_MailPendingSearch[client][0] = '\0';
    g_MailSearchGeneration[client]++;
}

bool IsMailClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

bool IsPointsStoreAwardAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPointsSteamIdOnce") == FeatureStatus_Available;
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

    g_MailDatabaseReady = true;
}

bool EscapeMailSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    return g_MailDatabaseReady && g_MailDatabase != null
        && g_MailDatabase.Escape(input, output, maxlen);
}

bool IsValidSteamId64(const char[] steamId)
{
    int length = strlen(steamId);
    if (length < 16 || length >= MAIL_STEAMID_MAX)
    {
        return false;
    }

    for (int i = 0; i < length; i++)
    {
        if (!IsCharNumeric(steamId[i]))
        {
            return false;
        }
    }
    return true;
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

int FindMailClientBySteamId(const char[] steamId)
{
    return Kogasa_FindClientBySteamId64(steamId, true);
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

    BeginMailCommand(client);
    return Plugin_Handled;
}

public Action Command_SendMail(int client, int args)
{
    if (!IsMailClient(client))
    {
        return Plugin_Handled;
    }

    BeginMailCommand(client);
    return Plugin_Handled;
}

void ShowMailMainMenu(int client)
{
    Menu menu = new Menu(MenuHandler_MailMain);
    menu.SetTitle("Mail");
    menu.AddItem("send", "Send Mail");
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
        CPrintToChat(client, "%s Type {gold}!send playername hey how are you?{default} to send a player mail, even an offline player!", MAIL_PREFIX);
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
        CPrintToChat(client, "%s Usage: {gold}!send playername message", MAIL_PREFIX);
        return;
    }

    char contents[MAIL_CONTENTS_MAX];
    strcopy(contents, sizeof(contents), raw[position]);
    TrimString(search);
    TrimString(contents);
    if (search[0] == '\0' || contents[0] == '\0')
    {
        CPrintToChat(client, "%s Usage: {gold}!send playername message", MAIL_PREFIX);
        return;
    }

    strcopy(g_MailPendingSearch[client], sizeof(g_MailPendingSearch[]), search);
    strcopy(g_MailPendingContents[client], sizeof(g_MailPendingContents[]), contents);
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
        ... "COALESCE(NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid), "
        ... "GREATEST(COALESCE(w.playtime, 0), 0) "
        ... "FROM whaletracker w "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = w.steamid "
        ... "WHERE (GREATEST(COALESCE(w.kills, 0), 0) + GREATEST(COALESCE(w.deaths, 0), 0)) >= %d "
        ... "AND GREATEST(COALESCE(w.playtime, 0), 0) >= %d "
        ... "AND (COALESCE(fs.last_name, '') LIKE '%%%s%%' "
        ... "OR COALESCE(w.cached_personaname, '') LIKE '%%%s%%') "
        ... "ORDER BY GREATEST(COALESCE(w.playtime, 0), 0) DESC, "
        ... "LOWER(COALESCE(NULLIF(fs.last_name, ''), NULLIF(w.cached_personaname, ''), w.steamid)) ASC "
        ... "LIMIT %d",
        GetRankMinimumKillsDeaths(),
        GetRankMinimumPlaytime(),
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
    menu.SetTitle("Send mail to:");

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

    char senderSteamId[MAIL_STEAMID_MAX];
    char senderName[MAIL_NAME_MAX];
    if (!GetMailClientIdentity(client, senderSteamId, sizeof(senderSteamId), senderName, sizeof(senderName)))
    {
        CPrintToChat(client, "%s Could not resolve your Steam identity.", MAIL_PREFIX);
        return 0;
    }

    if (!QueueMailInsert(
        senderSteamId,
        senderName,
        receiverSteamId,
        receiverName,
        senderName,
        g_MailPendingContents[client],
        0,
        "",
        GetClientUserId(client),
        true))
    {
        CPrintToChat(client, "%s Failed to queue mail. Try again.", MAIL_PREFIX);
    }
    g_MailPendingContents[client][0] = '\0';
    return 0;
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
    bool notifyPlayers = false)
{
    if (!g_MailDatabaseReady || g_MailDatabase == null
        || !IsValidSteamId64(receiverSteamId)
        || senderName[0] == '\0' || receiverName[0] == '\0'
        || title[0] == '\0' || contents[0] == '\0' || gems < 0)
    {
        return false;
    }

    if (senderSteamId[0] != '\0' && !IsValidSteamId64(senderSteamId))
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
    if (!EscapeMailSql(senderSteamId, escapedSenderSteam, sizeof(escapedSenderSteam))
        || !EscapeMailSql(senderName, escapedSenderName, sizeof(escapedSenderName))
        || !EscapeMailSql(receiverSteamId, escapedReceiverSteam, sizeof(escapedReceiverSteam))
        || !EscapeMailSql(receiverName, escapedReceiverName, sizeof(escapedReceiverName))
        || !EscapeMailSql(title, escapedTitle, sizeof(escapedTitle))
        || !EscapeMailSql(contents, escapedContents, sizeof(escapedContents))
        || !EscapeMailSql(requestKey, escapedRequest, sizeof(escapedRequest)))
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

    char query[4096];
    if (g_MailDatabaseIsMySql)
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO %s "
            ... "(sender_steamid64, sender_name, receiver_steamid64, receiver_name, created_at, title, contents, gems, gems_redeemed, idempotency_key) "
            ... "VALUES ('%s', '%s', '%s', '%s', %d, '%s', '%s', %d, 0, %s) "
            ... "ON DUPLICATE KEY UPDATE mail_id = LAST_INSERT_ID(mail_id)",
            MAIL_TABLE,
            escapedSenderSteam,
            escapedSenderName,
            escapedReceiverSteam,
            escapedReceiverName,
            GetTime(),
            escapedTitle,
            escapedContents,
            gems,
            idempotencyValue);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT OR IGNORE INTO %s "
            ... "(sender_steamid64, sender_name, receiver_steamid64, receiver_name, created_at, title, contents, gems, gems_redeemed, idempotency_key) "
            ... "VALUES ('%s', '%s', '%s', '%s', %d, '%s', '%s', %d, 0, %s)",
            MAIL_TABLE,
            escapedSenderSteam,
            escapedSenderName,
            escapedReceiverSteam,
            escapedReceiverName,
            GetTime(),
            escapedTitle,
            escapedContents,
            gems,
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
    delete pack;

    if (error[0] != '\0' || results == null)
    {
        LogError("[server_mail] Mail insert failed: %s", error);
        FireMailSendResult(requestKey, false, 0, false);

        int sender = GetClientOfUserId(senderUserId);
        if (notifyPlayers && IsMailClient(sender))
        {
            CPrintToChat(sender, "%s Failed to send mail.", MAIL_PREFIX);
        }
        return;
    }

    int mailId = results.InsertId;
    bool newlyCreated = results.AffectedRows == 1;
    FireMailSendResult(requestKey, true, mailId, newlyCreated);

    if (!notifyPlayers || !newlyCreated)
    {
        return;
    }

    int sender = GetClientOfUserId(senderUserId);
    if (IsMailClient(sender))
    {
        int receiver = FindMailClientBySteamId(receiverSteamId);
        char coloredReceiver[256];
        BuildColoredMailName(receiver, receiverSteamId, receiverName, coloredReceiver, sizeof(coloredReceiver));
        CPrintToChatEx(sender, receiver > 0 ? receiver : sender, "%s Sent to %s{default}.", MAIL_PREFIX, coloredReceiver);
    }

    int receiver = FindMailClientBySteamId(receiverSteamId);
    if (IsMailClient(receiver))
    {
        int liveSender = FindMailClientBySteamId(senderSteamId);
        char coloredSender[256];
        BuildColoredMailName(liveSender, senderSteamId, senderName, coloredSender, sizeof(coloredSender));
        CPrintToChatEx(receiver, liveSender > 0 ? liveSender : receiver,
            "{cornflowerblue}[Mail] %s{default} sent you mail!",
            coloredSender);
    }
}

void BuildMailDisplayTitle(const char[] title, int timestamp, int gems, char[] output, int maxlen)
{
    char date[32];
    FormatTime(date, sizeof(date), "%m-%d-%Y", timestamp);
    if (gems > 0)
    {
        Format(output, maxlen, "%s %s (%d)", title, date, gems);
    }
    else
    {
        Format(output, maxlen, "%s %s", title, date);
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
    if (mode == MailView_Inbox)
    {
        FormatEx(query, sizeof(query),
            "SELECT mail_id, title, created_at, gems, sender_name FROM %s "
            ... "WHERE receiver_steamid64 = '%s' ORDER BY created_at DESC, mail_id DESC LIMIT %d",
            MAIL_TABLE,
            escapedSteam,
            MAIL_LIST_MAX);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "SELECT mail_id, title, created_at, gems, receiver_name FROM %s "
            ... "WHERE sender_steamid64 = '%s' ORDER BY created_at DESC, mail_id DESC LIMIT %d",
            MAIL_TABLE,
            escapedSteam,
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
    menu.SetTitle(mode == MailView_Inbox ? "Inbox" : "Sent Mail");

    char info[32];
    char title[MAIL_TITLE_MAX];
    char partyName[MAIL_NAME_MAX];
    char displayTitle[256];
    char display[384];
    int count;
    while (rows != null && rows.FetchRow())
    {
        int mailId = rows.FetchInt(0);
        rows.FetchString(1, title, sizeof(title));
        int timestamp = rows.FetchInt(2);
        int gems = rows.FetchInt(3);
        rows.FetchString(4, partyName, sizeof(partyName));
        BuildMailDisplayTitle(title, timestamp, gems, displayTitle, sizeof(displayTitle));

        Format(info, sizeof(info), "%c:%d", mode == MailView_Inbox ? 'i' : 's', mailId);
        Format(display, sizeof(display), "%s - %s", displayTitle, partyName);
        menu.AddItem(info, display);
        count++;
    }

    if (count == 0)
    {
        menu.AddItem("none", mode == MailView_Inbox ? "No received mail" : "No sent mail", ITEMDRAW_DISABLED);
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
        "SELECT mail_id, sender_name, receiver_name, created_at, title, contents, gems, gems_redeemed "
        ... "FROM %s WHERE mail_id = %d AND %s = '%s' LIMIT 1",
        MAIL_TABLE,
        mailId,
        mode == MailView_Inbox ? "receiver_steamid64" : "sender_steamid64",
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(view_as<int>(mode));
    g_MailDatabase.Query(SQL_OnMailDetailsLoaded, query, pack);
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
    char senderName[MAIL_NAME_MAX];
    char receiverName[MAIL_NAME_MAX];
    char title[MAIL_TITLE_MAX];
    char contents[MAIL_CONTENTS_MAX];
    rows.FetchString(1, senderName, sizeof(senderName));
    rows.FetchString(2, receiverName, sizeof(receiverName));
    int timestamp = rows.FetchInt(3);
    rows.FetchString(4, title, sizeof(title));
    rows.FetchString(5, contents, sizeof(contents));
    int gems = rows.FetchInt(6);
    bool redeemed = rows.FetchInt(7) != 0;

    char displayTitle[256];
    char dateLong[64];
    char menuTitle[1024];
    BuildMailDisplayTitle(title, timestamp, gems, displayTitle, sizeof(displayTitle));
    FormatTime(dateLong, sizeof(dateLong), "%Y-%m-%d %H:%M", timestamp);
    FormatEx(menuTitle, sizeof(menuTitle),
        "%s\n%s: %s\nDate: %s\n\n%s",
        displayTitle,
        mode == MailView_Inbox ? "From" : "To",
        mode == MailView_Inbox ? senderName : receiverName,
        dateLong,
        contents);

    Menu menu = new Menu(MenuHandler_MailDetails);
    menu.SetTitle(menuTitle);

    char info[32];
    Format(info, sizeof(info), "back:%d", view_as<int>(mode));
    if (mode == MailView_Inbox && gems > 0)
    {
        if (redeemed)
        {
            menu.AddItem("redeemed", "Attached Gems: Redeemed", ITEMDRAW_DISABLED);
        }
        else if (!IsPointsStoreAwardAvailable())
        {
            menu.AddItem("unavailable", "Attached Gems: Currency system unavailable", ITEMDRAW_DISABLED);
        }
        else
        {
            Format(info, sizeof(info), "redeem:%d", mailId);
            char redeemLabel[128];
            Format(redeemLabel, sizeof(redeemLabel), "Redeem %d Gems", gems);
            menu.AddItem(info, redeemLabel);
        }
        Format(info, sizeof(info), "back:%d", view_as<int>(mode));
        menu.AddItem(info, "Back");
    }
    else
    {
        menu.AddItem(info, "Back");
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MailDetails(Menu menu, MenuAction action, int client, int item)
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
    if (StrContains(info, "redeem:", false) == 0)
    {
        BeginMailRedemption(client, StringToInt(info[7]));
    }
    else if (StrContains(info, "back:", false) == 0)
    {
        RequestMailList(client, view_as<MailViewMode>(StringToInt(info[5])));
    }
    return 0;
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
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' AND gems > 0 AND gems_redeemed = 0 LIMIT 1",
        MAIL_TABLE,
        mailId,
        escapedSteam);

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

    char awardKey[MAIL_REQUEST_KEY_MAX];
    Format(awardKey, sizeof(awardKey), "server_mail:redeem:%d", mailId);
    g_MailPendingRedemptions.SetValue(awardKey, mailId);
    g_MailRedemptionUsers.SetValue(awardKey, userId);
    g_MailRedemptionTitles.SetString(awardKey, title);
    g_MailRedemptionSteamIds.SetString(awardKey, steamId);

    if (!PointsStore_ApplyBonusPointsSteamIdOnce(steamId, gems, awardKey, "server_mail_redemption"))
    {
        ClearPendingRedemption(awardKey);
        CPrintToChat(client, "%s Currency redemption could not be queued. Try again.", MAIL_PREFIX);
    }
}

void ClearPendingRedemption(const char[] awardKey)
{
    g_MailPendingRedemptions.Remove(awardKey);
    g_MailRedemptionUsers.Remove(awardKey);
    g_MailRedemptionTitles.Remove(awardKey);
    g_MailRedemptionSteamIds.Remove(awardKey);
}

public void PointsStore_OnApplyBonusPointsSteamIdOnce(const char[] awardKey, bool success, bool newlyApplied)
{
    int mailId;
    if (!g_MailPendingRedemptions.GetValue(awardKey, mailId))
    {
        return;
    }

    int userId;
    char steamId[MAIL_STEAMID_MAX];
    char title[MAIL_TITLE_MAX];
    g_MailRedemptionUsers.GetValue(awardKey, userId);
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
        "UPDATE %s SET gems_redeemed = 1 "
        ... "WHERE mail_id = %d AND receiver_steamid64 = '%s' AND gems_redeemed = 0",
        MAIL_TABLE,
        mailId,
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteString(awardKey);
    pack.WriteCell(userId);
    pack.WriteString(steamId);
    pack.WriteString(title);
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
    if (IsMailClient(client))
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

    if (GetFeatureStatus(FeatureType_Native, "SaySounds_PlayCommand") == FeatureStatus_Available)
    {
        SaySounds_PlayCommand(0, "xp_levelup", true);
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

    int receiver = FindMailClientBySteamId(receiverSteam);
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
