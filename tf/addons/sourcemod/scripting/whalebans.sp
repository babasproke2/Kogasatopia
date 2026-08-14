/**
 * SourceMod base ban behavior derived from AlliedModders LLC's basebans plugin.
 * Licensed under the GNU General Public License, version 3.0.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#undef REQUIRE_PLUGIN
#include <adminmenu>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/database.inc"
#include "include/steam_identity.inc"

#define WHALEBANS_DB_CONFIG "default"
#define WHALEBANS_RECONNECT_DELAY 10.0
#define WHALEBANS_EXPIRY_INTERVAL 60.0

public Plugin myinfo =
{
    name = "Whale Bans",
    author = "AlliedModders LLC, Hombre",
    description = "Database-backed dual Steam/IP bans with WhaleTracker-aware target ordering.",
    version = "1.1.1",
    url = "https://kogasa.tf"
};

enum struct BanSelection
{
    int targetUserId;
    int duration;
    bool waitingForReason;
}

BanSelection g_BanSelection[MAXPLAYERS + 1];
TopMenu g_AdminMenu = null;
KeyValues g_BanReasons = null;
char g_BanReasonsPath[PLATFORM_MAX_PATH];
Database g_Database = null;
bool g_DatabaseReady = false;
Handle g_DatabaseReconnectTimer = null;
Handle g_ExpiryTimer = null;
int g_SelectedBanId[MAXPLAYERS + 1];
char g_SelectedBanName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int maxlen)
{
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeSeconds");
    return APLRes_Success;
}

public void OnPluginStart()
{
    BuildPath(Path_SM, g_BanReasonsPath, sizeof(g_BanReasonsPath), "configs/banreasons.txt");
    LoadBanReasons();

    LoadTranslations("common.phrases");
    LoadTranslations("basebans.phrases");
    LoadTranslations("core.phrases");

    RegAdminCmd("sm_ban", Command_Ban, ADMFLAG_BAN, "sm_ban <#userid|name> <minutes|0> [reason]");
    RegAdminCmd("sm_banip", Command_BanIp, ADMFLAG_BAN, "sm_banip <ip|#userid|name> <time> [reason]");
    RegAdminCmd("sm_unban", Command_Unban, ADMFLAG_UNBAN, "sm_unban [steamid|ip]");
    RegConsoleCmd("sm_abortban", Command_AbortBan, "Abort a pending custom ban reason.");

    ConnectDatabase();
    g_ExpiryTimer = CreateTimer(WHALEBANS_EXPIRY_INTERVAL, Timer_ExpireBans, _, TIMER_REPEAT);

    TopMenu topMenu;
    if (LibraryExists("adminmenu") && (topMenu = GetAdminTopMenu()) != null)
    {
        OnAdminMenuReady(topMenu);
    }
}

public void OnPluginEnd()
{
    delete g_BanReasons;
    g_BanReasons = null;
    Db_CancelTimer(g_DatabaseReconnectTimer);
    delete g_ExpiryTimer;
    g_ExpiryTimer = null;
    Db_Close(g_Database, g_DatabaseReady);
}

public void OnConfigsExecuted()
{
    LoadBanReasons();
}

public void OnClientDisconnect(int client)
{
    ResetBanSelection(client);
    g_SelectedBanId[client] = 0;
    g_SelectedBanName[client][0] = '\0';
}

public void OnClientPostAdminCheck(int client)
{
    CheckClientBan(client);
}

void ResetBanSelection(int client)
{
    g_BanSelection[client].targetUserId = 0;
    g_BanSelection[client].duration = 0;
    g_BanSelection[client].waitingForReason = false;
}

void LoadBanReasons()
{
    delete g_BanReasons;
    g_BanReasons = new KeyValues("banreasons");

    if (!g_BanReasons.ImportFromFile(g_BanReasonsPath))
    {
        SetFailState("Error in %s: File not found, corrupt or in the wrong format", g_BanReasonsPath);
        return;
    }

    char sectionName[64];
    if (!g_BanReasons.GetSectionName(sectionName, sizeof(sectionName))
        || !StrEqual(sectionName, "banreasons"))
    {
        SetFailState("Error in %s: Couldn't find 'banreasons'", g_BanReasonsPath);
        return;
    }

    g_BanReasons.Rewind();
}

bool IsDatabaseReady()
{
    return Db_IsReady(g_Database, g_DatabaseReady);
}

void ConnectDatabase()
{
    Db_CancelTimer(g_DatabaseReconnectTimer);
    Db_Close(g_Database, g_DatabaseReady);

    if (!Db_CheckConfigOrLog("WhaleBans", WHALEBANS_DB_CONFIG))
    {
        ScheduleDatabaseReconnect();
        return;
    }

    Database.Connect(SQL_OnDatabaseConnected, WHALEBANS_DB_CONFIG);
}

void ScheduleDatabaseReconnect(float delay = WHALEBANS_RECONNECT_DELAY)
{
    g_DatabaseReady = false;
    if (g_DatabaseReconnectTimer == null)
    {
        g_DatabaseReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase);
    }
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    g_DatabaseReconnectTimer = null;
    ConnectDatabase();
    return Plugin_Stop;
}

public void SQL_OnDatabaseConnected(Database database, const char[] error, any data)
{
    if (database == null)
    {
        LogError("[WhaleBans] Database connection failed: %s", error);
        ScheduleDatabaseReconnect();
        return;
    }

    g_Database = database;
    g_DatabaseReady = false;
    Db_CancelTimer(g_DatabaseReconnectTimer);
    if (!g_Database.SetCharset("utf8mb4"))
    {
        LogError("[WhaleBans] Failed to set the database charset to utf8mb4.");
    }

    char query[4096];
    FormatEx(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS whalebans ("
        ... "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, "
        ... "name_at_ban VARCHAR(128) NOT NULL DEFAULT '', "
        ... "steamid VARCHAR(32) NOT NULL DEFAULT '', "
        ... "steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
        ... "ip VARCHAR(45) NOT NULL DEFAULT '', "
        ... "ban_date INT NOT NULL DEFAULT 0, "
        ... "ping_at_ban INT NOT NULL DEFAULT 0, "
        ... "playtime_at_ban INT NOT NULL DEFAULT 0, "
        ... "ban_length INT NOT NULL DEFAULT 0, "
        ... "expires_at INT NOT NULL DEFAULT 0, "
        ... "ban_status VARCHAR(16) NOT NULL DEFAULT 'ongoing', "
        ... "reason VARCHAR(255) NOT NULL DEFAULT '', "
        ... "banned_by_name VARCHAR(128) NOT NULL DEFAULT '', "
        ... "banned_by_steamid64 VARCHAR(32) NOT NULL DEFAULT '', "
        ... "unbanned_at INT NOT NULL DEFAULT 0, "
        ... "INDEX whalebans_active_steam (ban_status, steamid64), "
        ... "INDEX whalebans_active_ip (ban_status, ip), "
        ... "INDEX whalebans_recent (ban_status, ban_date)"
        ... ") CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    g_Database.Query(SQL_OnSchemaReady, query);
}

public void SQL_OnSchemaReady(Database database, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[WhaleBans] Failed to create schema: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    g_DatabaseReady = true;
    ExpireFinishedBans();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            CheckClientBan(client);
        }
    }
}

public Action Timer_ExpireBans(Handle timer, any data)
{
    ExpireFinishedBans();
    return Plugin_Continue;
}

void ExpireFinishedBans()
{
    if (!IsDatabaseReady())
    {
        return;
    }

    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE whalebans SET ban_status = 'unbanned', unbanned_at = expires_at "
        ... "WHERE ban_status = 'ongoing' AND expires_at > 0 AND expires_at <= %d",
        now);
    g_Database.Query(SQL_OnMaintenanceQuery, query);
}

public void SQL_OnMaintenanceQuery(Database database, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[WhaleBans] Maintenance query failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
    }
}

void CheckClientBan(int client)
{
    if (!IsDatabaseReady() || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[KOGASA_STEAMID_MAX];
    char ip[46];
    if (!Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true)
        || !GetClientIP(client, ip, sizeof(ip), true))
    {
        return;
    }

    char escapedSteamId64[KOGASA_STEAMID_MAX * 2];
    char escapedIp[92];
    if (!Db_Escape(g_Database, steamId64, escapedSteamId64, sizeof(escapedSteamId64), "WhaleBans")
        || !Db_Escape(g_Database, ip, escapedIp, sizeof(escapedIp), "WhaleBans"))
    {
        return;
    }

    int now = GetTime();
    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT reason FROM whalebans "
        ... "WHERE ban_status = 'ongoing' AND (expires_at = 0 OR expires_at > %d) "
        ... "AND ((steamid64 <> '' AND steamid64 = '%s') OR (ip <> '' AND ip = '%s')) "
        ... "ORDER BY ban_date DESC LIMIT 1",
        now,
        escapedSteamId64,
        escapedIp);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId64);
    g_Database.Query(SQL_OnClientBanChecked, query, pack);
}

public void SQL_OnClientBanChecked(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char expectedSteamId64[KOGASA_STEAMID_MAX];
    pack.ReadString(expectedSteamId64, sizeof(expectedSteamId64));
    delete pack;

    if (error[0])
    {
        LogError("[WhaleBans] Client ban check failed: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    char currentSteamId64[KOGASA_STEAMID_MAX];
    if (client == 0 || !IsClientInGame(client)
        || !Kogasa_GetClientSteamId64(client, currentSteamId64, sizeof(currentSteamId64), true)
        || !StrEqual(currentSteamId64, expectedSteamId64))
    {
        return;
    }

    if (results == null || !results.FetchRow())
    {
        return;
    }

    char reason[256];
    results.FetchString(0, reason, sizeof(reason));
    KickClient(client, "Banned: %s", reason[0] ? reason : "Banned");
}

bool IsWhaleTrackerRanked(int client)
{
    return GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") == FeatureStatus_Available
        && WhaleTracker_GetRankedPlaytimeSeconds(client) > 0;
}

bool BanTargetComesBefore(
    int left,
    int right,
    bool leftRanked,
    bool rightRanked,
    float leftConnectedTime,
    float rightConnectedTime)
{
    if (leftRanked != rightRanked)
    {
        return !leftRanked;
    }

    if (leftConnectedTime != rightConnectedTime)
    {
        if (leftRanked)
        {
            return leftConnectedTime > rightConnectedTime;
        }
        return leftConnectedTime < rightConnectedTime;
    }

    char leftName[MAX_NAME_LENGTH];
    char rightName[MAX_NAME_LENGTH];
    GetClientName(left, leftName, sizeof(leftName));
    GetClientName(right, rightName, sizeof(rightName));
    return strcmp(leftName, rightName, false) < 0;
}

void FormatConnectedTime(int client, char[] output, int maxlen)
{
    int totalSeconds = RoundToFloor(GetClientTime(client));
    int seconds = totalSeconds % 60;
    int totalMinutes = totalSeconds / 60;

    if (totalMinutes >= 60)
    {
        FormatEx(output, maxlen, "%d:%02d:%02d", totalMinutes / 60, totalMinutes % 60, seconds);
        return;
    }

    FormatEx(output, maxlen, "%d:%02d", totalMinutes, seconds);
}

void DisplayBanTargetMenu(int client)
{
    int targets[MAXPLAYERS + 1];
    bool ranked[MAXPLAYERS + 1];
    float connectedTime[MAXPLAYERS + 1];
    int targetCount;

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || IsFakeClient(target) || !CanUserTarget(client, target))
        {
            continue;
        }

        ranked[target] = IsWhaleTrackerRanked(target);
        connectedTime[target] = GetClientTime(target);

        int insertAt = targetCount;
        while (insertAt > 0)
        {
            int previous = targets[insertAt - 1];
            if (!BanTargetComesBefore(
                target,
                previous,
                ranked[target],
                ranked[previous],
                connectedTime[target],
                connectedTime[previous]))
            {
                break;
            }

            targets[insertAt] = previous;
            insertAt--;
        }

        targets[insertAt] = target;
        targetCount++;
    }

    Menu menu = new Menu(MenuHandler_BanTarget);
    char title[100];
    Format(title, sizeof(title), "%T:", "Ban player", client);
    menu.SetTitle(title);
    menu.ExitBackButton = CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, false);

    for (int index = 0; index < targetCount; index++)
    {
        int target = targets[index];
        char userId[16];
        char connected[24];
        char display[MAX_NAME_LENGTH + 32];
        IntToString(GetClientUserId(target), userId, sizeof(userId));
        FormatConnectedTime(target, connected, sizeof(connected));
        FormatEx(display, sizeof(display), "%N (%s)", target, connected);
        menu.AddItem(userId, display);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanDurationMenu(int client)
{
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    if (target == 0)
    {
        PrintToChat(client, "[SM] %t", "Player no longer available");
        return;
    }

    Menu menu = new Menu(MenuHandler_BanDuration);
    char title[100];
    Format(title, sizeof(title), "%T: %N", "Ban player", client, target);
    menu.SetTitle(title);
    menu.ExitBackButton = true;
    menu.AddItem("0", "Permanent");
    menu.AddItem("10", "10 Minutes");
    menu.AddItem("30", "30 Minutes");
    menu.AddItem("60", "1 Hour");
    menu.AddItem("240", "4 Hours");
    menu.AddItem("1440", "1 Day");
    menu.AddItem("10080", "1 Week");
    menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanReasonMenu(int client)
{
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    if (target == 0)
    {
        PrintToChat(client, "[SM] %t", "Player no longer available");
        return;
    }

    Menu menu = new Menu(MenuHandler_BanReason);
    char title[100];
    Format(title, sizeof(title), "%T: %N", "Ban reason", client, target);
    menu.SetTitle(title);
    menu.ExitBackButton = true;
    menu.AddItem("", "Custom reason (type in chat)");

    g_BanReasons.Rewind();
    if (g_BanReasons.GotoFirstSubKey(false))
    {
        do
        {
            char reasonName[100];
            char reason[255];
            g_BanReasons.GetSectionName(reasonName, sizeof(reasonName));
            g_BanReasons.GetString(NULL_STRING, reason, sizeof(reason));
            menu.AddItem(reason, reasonName);
        }
        while (g_BanReasons.GotoNextKey(false));
    }
    g_BanReasons.Rewind();

    menu.Display(client, MENU_TIME_FOREVER);
}

void PerformBan(int client, int target, int duration, const char[] reason)
{
    if (target == 0 || GetClientOfUserId(g_BanSelection[client].targetUserId) != target)
    {
        if (client == 0)
        {
            PrintToServer("[SM] %t", "Player no longer available");
        }
        else
        {
            PrintToChat(client, "[SM] %t", "Player no longer available");
        }
        return;
    }

    QueueBanRecord(client, target, duration, reason, "", false);
    ResetBanSelection(client);
}

void QueueBanRecord(
    int client,
    int target,
    int duration,
    const char[] reason,
    const char[] explicitIp,
    bool ipCommand)
{
    if (!IsDatabaseReady())
    {
        ReplyToCommand(client, "[SM] WhaleBans database is unavailable; no ban was applied.");
        return;
    }

    char name[MAX_NAME_LENGTH];
    char steamId[32];
    char steamId64[KOGASA_STEAMID_MAX];
    char ip[46];
    int ping;
    int knownPlaytime;
    if (target > 0 && IsClientInGame(target))
    {
        GetClientName(target, name, sizeof(name));
        Kogasa_GetClientSteam2(target, steamId, sizeof(steamId), true);
        Kogasa_GetClientSteamId64(target, steamId64, sizeof(steamId64), true);
        GetClientIP(target, ip, sizeof(ip), true);
        ping = RoundToNearest(GetClientAvgLatency(target, NetFlow_Both) * 1000.0);
        if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") == FeatureStatus_Available)
        {
            knownPlaytime = WhaleTracker_GetRankedPlaytimeSeconds(target);
        }
    }
    else
    {
        strcopy(name, sizeof(name), explicitIp);
        strcopy(ip, sizeof(ip), explicitIp);
    }

    char adminName[MAX_NAME_LENGTH];
    char adminSteamId64[KOGASA_STEAMID_MAX];
    if (client > 0 && IsClientInGame(client))
    {
        GetClientName(client, adminName, sizeof(adminName));
        Kogasa_GetClientSteamId64(client, adminSteamId64, sizeof(adminSteamId64), true);
    }
    else
    {
        strcopy(adminName, sizeof(adminName), "Console");
    }

    char escapedName[MAX_NAME_LENGTH * 2];
    char escapedSteamId[64];
    char escapedSteamId64[KOGASA_STEAMID_MAX * 2];
    char escapedIp[92];
    char escapedReason[512];
    char escapedAdminName[MAX_NAME_LENGTH * 2];
    char escapedAdminSteamId64[KOGASA_STEAMID_MAX * 2];
    if (!Db_Escape(g_Database, name, escapedName, sizeof(escapedName), "WhaleBans")
        || !Db_Escape(g_Database, steamId, escapedSteamId, sizeof(escapedSteamId), "WhaleBans")
        || !Db_Escape(g_Database, steamId64, escapedSteamId64, sizeof(escapedSteamId64), "WhaleBans")
        || !Db_Escape(g_Database, ip, escapedIp, sizeof(escapedIp), "WhaleBans")
        || !Db_Escape(g_Database, reason, escapedReason, sizeof(escapedReason), "WhaleBans")
        || !Db_Escape(g_Database, adminName, escapedAdminName, sizeof(escapedAdminName), "WhaleBans")
        || !Db_Escape(g_Database, adminSteamId64, escapedAdminSteamId64, sizeof(escapedAdminSteamId64), "WhaleBans"))
    {
        ReplyToCommand(client, "[SM] Failed to prepare the ban record.");
        return;
    }

    int now = GetTime();
    int expiresAt = duration > 0 ? now + duration * 60 : 0;
    char query[4096];
    FormatEx(query, sizeof(query),
        "INSERT INTO whalebans "
        ... "(name_at_ban, steamid, steamid64, ip, ban_date, ping_at_ban, playtime_at_ban, "
        ... "ban_length, expires_at, ban_status, reason, banned_by_name, banned_by_steamid64) "
        ... "VALUES ('%s', '%s', '%s', '%s', %d, %d, "
        ... "GREATEST(%d, COALESCE((SELECT playtime FROM whaletracker WHERE steamid = '%s' LIMIT 1), 0)), "
        ... "%d, %d, 'ongoing', '%s', '%s', '%s')",
        escapedName,
        escapedSteamId,
        escapedSteamId64,
        escapedIp,
        now,
        ping,
        knownPlaytime,
        escapedSteamId64,
        duration,
        expiresAt,
        escapedReason,
        escapedAdminName,
        escapedAdminSteamId64);

    DataPack pack = new DataPack();
    pack.WriteCell(client > 0 ? GetClientUserId(client) : 0);
    pack.WriteCell(target > 0 ? GetClientUserId(target) : 0);
    pack.WriteCell(duration);
    pack.WriteCell(ipCommand ? 1 : 0);
    pack.WriteString(name);
    pack.WriteString(steamId);
    pack.WriteString(steamId64);
    pack.WriteString(ip);
    pack.WriteString(reason);
    g_Database.Query(SQL_OnBanInserted, query, pack);
}

public void SQL_OnBanInserted(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int adminUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int duration = pack.ReadCell();
    bool ipCommand = pack.ReadCell() != 0;
    char name[MAX_NAME_LENGTH];
    char steamId[32];
    char steamId64[KOGASA_STEAMID_MAX];
    char ip[46];
    char reason[256];
    pack.ReadString(name, sizeof(name));
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(steamId64, sizeof(steamId64));
    pack.ReadString(ip, sizeof(ip));
    pack.ReadString(reason, sizeof(reason));
    delete pack;

    int client = adminUserId > 0 ? GetClientOfUserId(adminUserId) : 0;
    int target = targetUserId > 0 ? GetClientOfUserId(targetUserId) : 0;
    if (error[0])
    {
        LogError("[WhaleBans] Failed to insert ban: %s", error);
        ReplyToCommand(client, "[SM] Failed to save the ban; no ban was applied.");
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        return;
    }

    if (steamId[0])
    {
        BanIdentity(steamId, duration, BANFLAG_AUTHID, reason, "sm_ban", client);
    }
    if (ip[0])
    {
        BanIdentity(ip, duration, BANFLAG_IP, reason, "sm_banip", client);
    }

    if (ipCommand)
    {
        ReplyToCommand(client, "[SM] %t", "Ban added");
        LogAction(
            client,
            target,
            "\"%L\" added database ban (minutes \"%d\") (steamid64 \"%s\") (ip \"%s\") (reason \"%s\")",
            client,
            duration,
            steamId64,
            ip,
            reason);
    }
    else
    {
        if (duration == 0)
        {
            if (reason[0])
            {
                ShowActivity(client, "%t", "Permabanned player reason", name, reason);
            }
            else
            {
                ShowActivity(client, "%t", "Permabanned player", name);
            }
        }
        else if (reason[0])
        {
            ShowActivity(client, "%t", "Banned player reason", name, duration, reason);
        }
        else
        {
            ShowActivity(client, "%t", "Banned player", name, duration);
        }

        LogAction(
            client,
            target,
            "\"%L\" database banned \"%s\" (minutes \"%d\") (steamid64 \"%s\") (ip \"%s\") (reason \"%s\")",
            client,
            name,
            duration,
            steamId64,
            ip,
            reason);
    }

    if (target > 0 && IsClientInGame(target))
    {
        char currentSteamId64[KOGASA_STEAMID_MAX];
        char currentIp[46];
        Kogasa_GetClientSteamId64(target, currentSteamId64, sizeof(currentSteamId64), true);
        GetClientIP(target, currentIp, sizeof(currentIp), true);
        if ((!steamId64[0] || StrEqual(currentSteamId64, steamId64))
            && (!ip[0] || StrEqual(currentIp, ip)))
        {
            KickClient(target, "Banned: %s", reason[0] ? reason : "Banned");
        }
    }
}

public Action Command_Ban(int client, int args)
{
    if (args < 2)
    {
        if (GetCmdReplySource() == SM_REPLY_TO_CHAT && client != 0 && args == 0)
        {
            DisplayBanTargetMenu(client);
        }
        else
        {
            ReplyToCommand(client, "[SM] Usage: sm_ban <#userid|name> <minutes|0> [reason]");
        }
        return Plugin_Handled;
    }

    char arguments[256];
    char targetArgument[65];
    char durationArgument[12];
    GetCmdArgString(arguments, sizeof(arguments));

    int offset = BreakString(arguments, targetArgument, sizeof(targetArgument));
    int target = FindTarget(client, targetArgument, true);
    if (target == -1)
    {
        return Plugin_Handled;
    }

    int consumed = BreakString(arguments[offset], durationArgument, sizeof(durationArgument));
    if (consumed != -1)
    {
        offset += consumed;
    }
    else
    {
        offset = 0;
        arguments[0] = '\0';
    }

    g_BanSelection[client].targetUserId = GetClientUserId(target);
    PerformBan(client, target, StringToInt(durationArgument), arguments[offset]);
    return Plugin_Handled;
}

public Action Command_BanIp(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SM] Usage: sm_banip <ip|#userid|name> <time> [reason]");
        return Plugin_Handled;
    }

    char arguments[256];
    char targetArgument[50];
    char durationArgument[20];
    GetCmdArgString(arguments, sizeof(arguments));

    int offset = BreakString(arguments, targetArgument, sizeof(targetArgument));
    int consumed = BreakString(arguments[offset], durationArgument, sizeof(durationArgument));
    if (consumed != -1)
    {
        offset += consumed;
    }
    else
    {
        offset = 0;
        arguments[0] = '\0';
    }

    if (StrEqual(targetArgument, "0"))
    {
        ReplyToCommand(client, "[SM] %t", "Cannot ban that IP");
        return Plugin_Handled;
    }

    char targetName[MAX_TARGET_LENGTH];
    int targetList[1];
    bool targetNameIsMl;
    int target = -1;
    if (ProcessTargetString(
        targetArgument,
        client,
        targetList,
        sizeof(targetList),
        COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_MULTI,
        targetName,
        sizeof(targetName),
        targetNameIsMl) > 0)
    {
        target = targetList[0];
    }

    bool hasRcon;
    if (client == 0 || (client == 1 && !IsDedicatedServer()))
    {
        hasRcon = true;
    }
    else
    {
        AdminId admin = GetUserAdmin(client);
        hasRcon = admin != INVALID_ADMIN_ID && GetAdminFlag(admin, Admin_RCON);
    }

    int matchedClient = -1;
    if (target != -1 && !IsFakeClient(target) && (hasRcon || CanUserTarget(client, target)))
    {
        GetClientIP(target, targetArgument, sizeof(targetArgument), true);
        matchedClient = target;
    }

    if (matchedClient == -1 && !hasRcon)
    {
        ReplyToCommand(client, "[SM] %t", "No Access");
        return Plugin_Handled;
    }

    int duration = StringToInt(durationArgument);
    QueueBanRecord(client, matchedClient, duration, arguments[offset], targetArgument, true);
    return Plugin_Handled;
}

public Action Command_Unban(int client, int args)
{
    if (!IsDatabaseReady())
    {
        ReplyToCommand(client, "[SM] WhaleBans database is unavailable.");
        return Plugin_Handled;
    }

    if (args == 0)
    {
        if (client == 0)
        {
            ReplyToCommand(client, "[SM] Usage: sm_unban <steamid|ip>");
            return Plugin_Handled;
        }

        DisplayActiveBanMenu(client);
        return Plugin_Handled;
    }

    char identity[50];
    GetCmdArgString(identity, sizeof(identity));
    ReplaceString(identity, sizeof(identity), "\"", "");

    char escapedIdentity[100];
    if (!Db_Escape(g_Database, identity, escapedIdentity, sizeof(escapedIdentity), "WhaleBans"))
    {
        ReplyToCommand(client, "[SM] Failed to prepare the unban.");
        return Plugin_Handled;
    }

    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT id, steamid, ip FROM whalebans "
        ... "WHERE ban_status = 'ongoing' AND (steamid = '%s' OR steamid64 = '%s' OR ip = '%s') "
        ... "ORDER BY ban_date DESC LIMIT 1",
        escapedIdentity,
        escapedIdentity,
        escapedIdentity);

    DataPack pack = new DataPack();
    pack.WriteCell(client > 0 ? GetClientUserId(client) : 0);
    pack.WriteString(identity);
    g_Database.Query(SQL_OnDirectUnbanLookup, query, pack);
    return Plugin_Handled;
}

void DisplayActiveBanMenu(int client)
{
    if (!IsDatabaseReady())
    {
        ReplyToCommand(client, "[SM] WhaleBans database is unavailable.");
        return;
    }

    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT id, name_at_ban FROM whalebans "
        ... "WHERE ban_status = 'ongoing' AND (expires_at = 0 OR expires_at > %d) "
        ... "ORDER BY ban_date DESC, id DESC LIMIT 100",
        now);
    g_Database.Query(SQL_OnActiveBansLoaded, query, GetClientUserId(client));
}

public void SQL_OnActiveBansLoaded(Database database, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client == 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[WhaleBans] Failed to load active bans: %s", error);
        ReplyToCommand(client, "[SM] Failed to load active bans.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ActiveBans);
    menu.SetTitle("Currently banned clients");
    int count;
    while (results != null && results.FetchRow())
    {
        int banId = results.FetchInt(0);
        char name[MAX_NAME_LENGTH];
        results.FetchString(1, name, sizeof(name));
        if (!name[0])
        {
            strcopy(name, sizeof(name), "Unknown");
        }

        char id[16];
        IntToString(banId, id, sizeof(id));
        menu.AddItem(id, name);
        count++;
    }

    if (count == 0)
    {
        delete menu;
        ReplyToCommand(client, "[SM] There are no currently banned clients.");
        return;
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ActiveBans(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char id[16];
        char name[MAX_NAME_LENGTH];
        menu.GetItem(selection, id, sizeof(id), _, name, sizeof(name));
        g_SelectedBanId[client] = StringToInt(id);
        strcopy(g_SelectedBanName[client], sizeof(g_SelectedBanName[]), name);
        DisplaySelectedBanMenu(client);
    }
    return 0;
}

void DisplaySelectedBanMenu(int client)
{
    if (g_SelectedBanId[client] <= 0)
    {
        DisplayActiveBanMenu(client);
        return;
    }

    Menu menu = new Menu(MenuHandler_SelectedBan);
    char title[MAX_NAME_LENGTH + 32];
    FormatEx(title, sizeof(title), "Ban: %s", g_SelectedBanName[client]);
    menu.SetTitle(title);
    menu.AddItem("unban", "Unban");
    menu.AddItem("date", "Check ban date");
    menu.AddItem("reason", "Check ban reason");
    menu.AddItem("back", "Go back");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_SelectedBan(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char actionName[16];
        menu.GetItem(selection, actionName, sizeof(actionName));
        if (StrEqual(actionName, "back"))
        {
            DisplayActiveBanMenu(client);
        }
        else if (StrEqual(actionName, "unban"))
        {
            UnbanSelectedRecord(client);
        }
        else
        {
            LoadSelectedBanDetail(client, StrEqual(actionName, "date"));
        }
    }
    return 0;
}

void UnbanSelectedRecord(int client)
{
    if (!IsDatabaseReady() || g_SelectedBanId[client] <= 0)
    {
        ReplyToCommand(client, "[SM] The selected ban is unavailable.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT steamid, ip FROM whalebans WHERE id = %d AND ban_status = 'ongoing' LIMIT 1",
        g_SelectedBanId[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_SelectedBanId[client]);
    pack.WriteString(g_SelectedBanName[client]);
    g_Database.Query(SQL_OnSelectedBanIdentityLoaded, query, pack);
}

public void SQL_OnSelectedBanIdentityLoaded(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int banId = pack.ReadCell();
    char name[MAX_NAME_LENGTH];
    pack.ReadString(name, sizeof(name));
    if (error[0] || results == null || !results.FetchRow())
    {
        if (error[0])
        {
            LogError("[WhaleBans] Failed to load identities for ban %d: %s", banId, error);
        }
        if (client > 0)
        {
            ReplyToCommand(client, "[SM] The selected ban is no longer active.");
        }
        delete pack;
        return;
    }

    char steamId[32];
    char ip[46];
    results.FetchString(0, steamId, sizeof(steamId));
    results.FetchString(1, ip, sizeof(ip));
    delete pack;
    QueueUnbanUpdate(client, banId, name, steamId, ip, true);
}

void QueueUnbanUpdate(
    int client,
    int banId,
    const char[] name,
    const char[] steamId,
    const char[] ip,
    bool fromMenu)
{
    char query[384];
    FormatEx(query, sizeof(query),
        "UPDATE whalebans SET ban_status = 'unbanned', unbanned_at = %d "
        ... "WHERE id = %d AND ban_status = 'ongoing'",
        GetTime(),
        banId);

    DataPack pack = new DataPack();
    pack.WriteCell(client > 0 ? GetClientUserId(client) : 0);
    pack.WriteCell(banId);
    pack.WriteCell(fromMenu ? 1 : 0);
    pack.WriteString(name);
    pack.WriteString(steamId);
    pack.WriteString(ip);
    g_Database.Query(SQL_OnBanUnbanned, query, pack);
}

void RemoveEngineBanPair(const char[] steamId, const char[] ip, int client)
{
    if (steamId[0])
    {
        RemoveBan(steamId, BANFLAG_AUTHID, "sm_unban", client);
    }
    if (ip[0])
    {
        RemoveBan(ip, BANFLAG_IP, "sm_unban", client);
    }
}

public void SQL_OnBanUnbanned(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    int banId = pack.ReadCell();
    bool fromMenu = pack.ReadCell() != 0;
    char name[MAX_NAME_LENGTH];
    char steamId[32];
    char ip[46];
    pack.ReadString(name, sizeof(name));
    pack.ReadString(steamId, sizeof(steamId));
    pack.ReadString(ip, sizeof(ip));
    delete pack;

    if (error[0])
    {
        LogError("[WhaleBans] Failed to unban record %d: %s", banId, error);
        ReplyToCommand(client, "[SM] Failed to unban %s.", name);
        return;
    }

    if (results.AffectedRows > 0)
    {
        RemoveEngineBanPair(steamId, ip, client);
        ReplyToCommand(client, "[SM] Unbanned %s.", name);
        LogAction(client, -1, "\"%L\" unbanned database ban id \"%d\" (\"%s\")", client, banId, name);
    }
    else
    {
        ReplyToCommand(client, "[SM] %s is no longer actively banned.", name);
    }

    if (fromMenu && client > 0)
    {
        g_SelectedBanId[client] = 0;
        g_SelectedBanName[client][0] = '\0';
        DisplayActiveBanMenu(client);
    }
}

void LoadSelectedBanDetail(int client, bool showDate)
{
    if (!IsDatabaseReady() || g_SelectedBanId[client] <= 0)
    {
        ReplyToCommand(client, "[SM] The selected ban is unavailable.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT ban_date, reason FROM whalebans WHERE id = %d LIMIT 1",
        g_SelectedBanId[client]);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(showDate ? 1 : 0);
    g_Database.Query(SQL_OnSelectedBanDetailLoaded, query, pack);
}

public void SQL_OnSelectedBanDetailLoaded(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    bool showDate = pack.ReadCell() != 0;
    delete pack;

    if (client == 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0] || results == null || !results.FetchRow())
    {
        if (error[0])
        {
            LogError("[WhaleBans] Failed to load ban details: %s", error);
        }
        ReplyToCommand(client, "[SM] Failed to load the selected ban.");
        return;
    }

    if (showDate)
    {
        int banDate = results.FetchInt(0);
        if (banDate <= 0)
        {
            ReplyToCommand(client, "[SM] Ban date: unavailable (legacy import)");
            DisplaySelectedBanMenu(client);
            return;
        }

        char formattedDate[64];
        FormatTime(formattedDate, sizeof(formattedDate), "%b %d, %Y %I:%M %p", banDate);
        ReplyToCommand(client, "[SM] Ban date: %s", formattedDate);
    }
    else
    {
        char reason[256];
        results.FetchString(1, reason, sizeof(reason));
        ReplyToCommand(client, "[SM] Ban reason: %s", reason[0] ? reason : "No reason supplied");
    }
    DisplaySelectedBanMenu(client);
}

public void SQL_OnDirectUnbanLookup(Database database, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    char identity[50];
    pack.ReadString(identity, sizeof(identity));
    if (error[0] || results == null || !results.FetchRow())
    {
        if (error[0])
        {
            LogError("[WhaleBans] Direct unban lookup failed: %s", error);
            ReplyToCommand(client, "[SM] Failed to unban %s.", identity);
        }
        else
        {
            ReplyToCommand(client, "[SM] No active bans matched %s.", identity);
        }
        delete pack;
        return;
    }

    int banId = results.FetchInt(0);
    char steamId[32];
    char ip[46];
    results.FetchString(1, steamId, sizeof(steamId));
    results.FetchString(2, ip, sizeof(ip));
    delete pack;
    QueueUnbanUpdate(client, banId, identity, steamId, ip, false);
}

public Action Command_AbortBan(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN))
    {
        ReplyToCommand(client, "[SM] %t", "No Access");
        return Plugin_Handled;
    }

    if (!g_BanSelection[client].waitingForReason)
    {
        ReplyToCommand(client, "[SM] %t", "AbortBan not waiting for custom reason");
        return Plugin_Handled;
    }

    g_BanSelection[client].waitingForReason = false;
    ReplyToCommand(client, "[SM] %t", "AbortBan applied successfully");
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] args)
{
    if (!g_BanSelection[client].waitingForReason || IsChatTrigger())
    {
        return Plugin_Continue;
    }

    g_BanSelection[client].waitingForReason = false;
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    PerformBan(client, target, g_BanSelection[client].duration, args);
    return Plugin_Stop;
}

public void OnAdminMenuReady(Handle topMenuHandle)
{
    TopMenu topMenu = TopMenu.FromHandle(topMenuHandle);
    if (topMenu == g_AdminMenu)
    {
        return;
    }

    g_AdminMenu = topMenu;
    TopMenuObject playerCommands = g_AdminMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);
    if (playerCommands != INVALID_TOPMENUOBJECT)
    {
        g_AdminMenu.AddItem("sm_ban", AdminMenu_Ban, playerCommands, "sm_ban", ADMFLAG_BAN);
    }
}

public void AdminMenu_Ban(
    TopMenu topMenu,
    TopMenuAction action,
    TopMenuObject objectId,
    int client,
    char[] buffer,
    int maxlen)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlen, "%T", "Ban player", client);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        ResetBanSelection(client);
        DisplayBanTargetMenu(client);
    }
}

public int MenuHandler_BanTarget(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack && g_AdminMenu != null)
    {
        g_AdminMenu.Display(client, TopMenuPosition_LastCategory);
    }
    else if (action == MenuAction_Select)
    {
        char userId[16];
        menu.GetItem(selection, userId, sizeof(userId));
        int target = GetClientOfUserId(StringToInt(userId));
        if (target == 0)
        {
            PrintToChat(client, "[SM] %t", "Player no longer available");
        }
        else if (!CanUserTarget(client, target))
        {
            PrintToChat(client, "[SM] %t", "Unable to target");
        }
        else
        {
            g_BanSelection[client].targetUserId = GetClientUserId(target);
            DisplayBanDurationMenu(client);
        }
    }
    return 0;
}

public int MenuHandler_BanDuration(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack)
    {
        DisplayBanTargetMenu(client);
    }
    else if (action == MenuAction_Select)
    {
        char duration[16];
        menu.GetItem(selection, duration, sizeof(duration));
        g_BanSelection[client].duration = StringToInt(duration);
        DisplayBanReasonMenu(client);
    }
    return 0;
}

public int MenuHandler_BanReason(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack)
    {
        DisplayBanDurationMenu(client);
    }
    else if (action == MenuAction_Select)
    {
        if (selection == 0)
        {
            g_BanSelection[client].waitingForReason = true;
            PrintToChat(client, "[SM] %t", "Custom ban reason explanation", "sm_abortban");
        }
        else
        {
            char reason[255];
            menu.GetItem(selection, reason, sizeof(reason));
            int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
            PerformBan(client, target, g_BanSelection[client].duration, reason);
        }
    }
    return 0;
}
