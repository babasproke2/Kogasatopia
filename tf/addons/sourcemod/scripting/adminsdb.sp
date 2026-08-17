#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dbi>
#include <files>

#include <morecolors>

#include "include/database.inc"
#include "include/steam_identity.inc"

#define ADMIN_DB_CONFIG "default"
#define ADMIN_TABLE_NAME "admins"
#define ADMIN_WHITELIST_TABLE_NAME "adminsdb_whitelists"
#define MAX_FLAG_LEN 32
#define MAX_NAME_LEN 128

char g_sAdminsFile[PLATFORM_MAX_PATH];
Database g_hDatabase = null;
bool g_bDatabaseReady = false;
Handle g_hReconnectTimer = null;
StringMap g_WhitelistLevels = null;
int g_ClientWhitelistLevel[MAXPLAYERS + 1];
static const char STEAM64_BASE_STR[] = "76561197960265728";

public Plugin myinfo =
{
    name = "AdminsDB Sync",
    author = "Hombre",
    description = "Syncs admins_simple.ini to database",
    version = "1.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errMax)
{
    RegPluginLibrary("adminsdb");
    CreateNative("AdminsDB_GetClientWhitelistLevel", Native_AdminsDB_GetClientWhitelistLevel);
    CreateNative("AdminsDB_GetSteamWhitelistLevel", Native_AdminsDB_GetSteamWhitelistLevel);
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    g_WhitelistLevels = new StringMap();
    BuildPath(Path_SM, g_sAdminsFile, sizeof(g_sAdminsFile), "configs/admins_simple.ini");
    ConnectToDatabase();
    RegConsoleCmd("sm_admins", Command_ShowAdmins, "Lists online admins");
    RegConsoleCmd("sm_checkid", Command_CheckId, "Shows your SteamID formats");
    RegAdminCmd("sm_whitelist", Command_Whitelist, ADMFLAG_CHAT, "sm_whitelist <player> <1-3> - Sets whitelist level");
    RegAdminCmd("sm_unwhitelist", Command_UnWhitelist, ADMFLAG_CHAT, "sm_unwhitelist <player> - Clears whitelist level");
    RegAdminCmd("sm_blacklist", Command_Blacklist, ADMFLAG_CHAT, "sm_blacklist <player> <1-3> - Sets blacklist level");
    RegAdminCmd("sm_unblacklist", Command_UnBlacklist, ADMFLAG_CHAT, "sm_unblacklist <player> - Clears blacklist level");
    RegAdminCmd("sm_whitelists", Command_ListWhitelists, ADMFLAG_CHAT, "sm_whitelists - Lists whitelisted clients");
    RegAdminCmd("sm_blacklists", Command_ListBlacklists, ADMFLAG_CHAT, "sm_blacklists - Lists blacklisted clients");
}

public void OnPluginEnd()
{
    Db_CancelTimer(g_hReconnectTimer);
    Db_Close(g_hDatabase, g_bDatabaseReady);

    if (g_WhitelistLevels != null)
    {
        delete g_WhitelistLevels;
        g_WhitelistLevels = null;
    }
}

public void OnClientPostAdminCheck(int client)
{
    RefreshClientWhitelistLevel(client);
}

public void OnClientDisconnect(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        g_ClientWhitelistLevel[client] = 0;
    }
}

void ConnectToDatabase()
{
    Db_CancelTimer(g_hReconnectTimer);
    Db_Close(g_hDatabase, g_bDatabaseReady);

    if (!Db_CheckConfigOrLog("AdminsDB", ADMIN_DB_CONFIG))
    {
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, ADMIN_DB_CONFIG);
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[AdminsDB] Database connection failed: %s", error[0] ? error : "unknown error");
        ScheduleDatabaseReconnect();
        return;
    }

    g_hDatabase = view_as<Database>(hndl);
    g_bDatabaseReady = true;
    Db_CancelTimer(g_hReconnectTimer);
    EnsureAdminTable();
    EnsureWhitelistTable();
    SyncAdmins();
    LoadWhitelistLevels();
}

void ScheduleDatabaseReconnect(float delay = DB_RECONNECT_DELAY)
{
    g_bDatabaseReady = false;
    if (g_hReconnectTimer == null)
    {
        g_hReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase);
    }
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    g_hReconnectTimer = null;
    ConnectToDatabase();
    return Plugin_Stop;
}

void EnsureAdminTable()
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (steamid2 VARCHAR(32) NOT NULL, steamid64 VARCHAR(32) NOT NULL, admin_status ENUM('yes','no') NOT NULL DEFAULT 'no')", ADMIN_TABLE_NAME);
    SQL_TQuery(g_hDatabase, SQLErrorCheckCallback, query);
}

void EnsureWhitelistTable()
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (steamid64 VARCHAR(32) PRIMARY KEY, level INT NOT NULL DEFAULT 0) DEFAULT CHARSET=utf8mb4", ADMIN_WHITELIST_TABLE_NAME);
    SQL_TQuery(g_hDatabase, SQLErrorCheckCallback, query);
}

void LoadWhitelistLevels()
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        return;
    }

    char query[128];
    Format(query, sizeof(query), "SELECT steamid64, level FROM %s WHERE level <> 0", ADMIN_WHITELIST_TABLE_NAME);
    SQL_TQuery(g_hDatabase, SQL_OnWhitelistLevelsLoaded, query);
}

public void SQL_OnWhitelistLevelsLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[AdminsDB] Failed to load whitelist levels: %s", error);
        return;
    }

    if (g_WhitelistLevels == null)
    {
        g_WhitelistLevels = new StringMap();
    }
    else
    {
        g_WhitelistLevels.Clear();
    }

    if (results != null)
    {
        char steamId64[32];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId64, sizeof(steamId64));
            int level = AdminsDb_ClampStoredLevel(results.FetchInt(1));
            if (steamId64[0] != '\0' && level != 0)
            {
                g_WhitelistLevels.SetValue(steamId64, level);
            }
        }
    }

    RefreshConnectedWhitelistLevels();
}

void SyncAdmins()
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        LogError("[AdminsDB] Cannot sync admins: no database connection");
        return;
    }

    if (!FileExists(g_sAdminsFile))
    {
        LogError("[AdminsDB] Admin file missing: %s", g_sAdminsFile);
        return;
    }

    ArrayList entries = new ArrayList(ByteCountToCells(128));
    if (!ParseAdminFile(entries))
    {
        delete entries;
        return;
    }

    if (entries.Length == 0)
    {
        delete entries;
        LogError("[AdminsDB] No admins found to sync.");
        return;
    }

    SQL_LockDatabase(g_hDatabase);

    char truncateQuery[128];
    Format(truncateQuery, sizeof(truncateQuery), "TRUNCATE TABLE %s", ADMIN_TABLE_NAME);
    if (!SQL_FastQuery(g_hDatabase, truncateQuery))
    {
        LogError("[AdminsDB] Failed to clear admins table.");
        SQL_UnlockDatabase(g_hDatabase);
        delete entries;
        return;
    }

    char record[192];
    char fields[3][64];
    char query[256];

    for (int i = 0; i < entries.Length; i++)
    {
        entries.GetString(i, record, sizeof(record));

        int count = ExplodeString(record, "|", fields, sizeof(fields), sizeof(fields[]));
        if (count != 3)
        {
            continue;
        }

        Format(query, sizeof(query),
            "INSERT INTO %s (steamid2, steamid64, admin_status) VALUES ('%s', '%s', '%s')",
            ADMIN_TABLE_NAME, fields[0], fields[1], fields[2]);

        if (!SQL_FastQuery(g_hDatabase, query))
        {
            LogError("[AdminsDB] Failed to insert %s into admins table.", fields[0]);
        }
    }

    SQL_UnlockDatabase(g_hDatabase);
    LogMessage("[AdminsDB] Synced %d admin entries.", entries.Length);
    delete entries;
}

bool ParseAdminFile(ArrayList entries)
{
    entries.Clear();

    File file = OpenFile(g_sAdminsFile, "r");
    if (file == null)
    {
        LogError("[AdminsDB] Unable to open %s", g_sAdminsFile);
        return false;
    }

    char line[256];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (!line[0])
        {
            continue;
        }

        StripInlineComment(line);
        TrimString(line);

        if (!line[0] || (line[0] == '/' && line[1] == '/'))
        {
            continue;
        }

        char steam2[32];
        char flags[MAX_FLAG_LEN];
        if (!ExtractQuotedPair(line, steam2, sizeof(steam2), flags, sizeof(flags)))
        {
            continue;
        }

        char steam64[32];
        if (!ConvertSteam2ToSteam64(steam2, steam64, sizeof(steam64)))
        {
            LogError("[AdminsDB] Failed to convert %s to Steam64", steam2);
            continue;
        }

        char status[4];
        if (StrContains(flags, "z", false) != -1)
        {
            strcopy(status, sizeof(status), "yes");
        }
        else
        {
            strcopy(status, sizeof(status), "no");
        }

        char entry[96];
        Format(entry, sizeof(entry), "%s|%s|%s", steam2, steam64, status);
        entries.PushString(entry);
    }

    delete file;
    return true;
}

void StripInlineComment(char[] line)
{
    bool inQuote = false;
    int len = strlen(line);

    for (int i = 0; i < len - 1; i++)
    {
        if (line[i] == '"')
        {
            inQuote = !inQuote;
        }
        else if (!inQuote && line[i] == '/' && line[i + 1] == '/')
        {
            line[i] = '\0';
            break;
        }
    }
}

bool ExtractQuotedPair(const char[] input, char[] first, int firstLen, char[] second, int secondLen)
{
    int len = strlen(input);
    int quotes[4];
    int count = 0;

    for (int i = 0; i < len && count < 4; i++)
    {
        if (input[i] == '"')
        {
            quotes[count++] = i;
        }
    }

    if (count < 4)
    {
        return false;
    }

    int start = quotes[0] + 1;
    int end = quotes[1];
    int copyLen = end - start;
    if (copyLen <= 0)
    {
        return false;
    }
    if (copyLen >= firstLen)
    {
        copyLen = firstLen - 1;
    }
    for (int i = 0; i < copyLen; i++)
    {
        first[i] = input[start + i];
    }
    first[copyLen] = '\0';

    start = quotes[2] + 1;
    end = quotes[3];
    copyLen = end - start;
    if (copyLen <= 0)
    {
        return false;
    }
    if (copyLen >= secondLen)
    {
        copyLen = secondLen - 1;
    }
    for (int i = 0; i < copyLen; i++)
    {
        second[i] = input[start + i];
    }
    second[copyLen] = '\0';

    TrimString(first);
    TrimString(second);
    return true;
}

bool ConvertSteam2ToSteam64(const char[] steam2, char[] steam64, int maxlen)
{
    char parts[3][32];
    int count = ExplodeString(steam2, ":", parts, sizeof(parts), sizeof(parts[]));
    if (count != 3)
    {
        return false;
    }

    int universe = StringToInt(parts[1]);
    int account = StringToInt(parts[2]);
    int addition = account * 2 + universe;

    char addStr[32];
    Format(addStr, sizeof(addStr), "%d", addition);

    AddDecimalStrings(STEAM64_BASE_STR, addStr, steam64, maxlen);
    return true;
}

bool ConvertSteam3ToSteam64(const char[] steam3, char[] steam64, int maxlen)
{
    char input[64];
    strcopy(input, sizeof(input), steam3);
    TrimString(input);

    ReplaceString(input, sizeof(input), "[", "", false);
    ReplaceString(input, sizeof(input), "]", "", false);

    char parts[3][32];
    int count = ExplodeString(input, ":", parts, sizeof(parts), sizeof(parts[]));
    if (count != 3 || !StrEqual(parts[0], "U", false))
    {
        return false;
    }

    AddDecimalStrings(STEAM64_BASE_STR, parts[2], steam64, maxlen);
    return steam64[0] != '\0';
}

bool IsDecimalSteam64(const char[] steamId)
{
    int len = strlen(steamId);
    if (len < 16 || len > 20)
    {
        return false;
    }

    for (int i = 0; i < len; i++)
    {
        if (steamId[i] < '0' || steamId[i] > '9')
        {
            return false;
        }
    }

    return true;
}

bool NormalizeSteamIdToSteam64(const char[] input, char[] steam64, int maxlen)
{
    steam64[0] = '\0';

    char value[64];
    strcopy(value, sizeof(value), input);
    TrimString(value);
    if (!value[0])
    {
        return false;
    }

    if (IsDecimalSteam64(value))
    {
        strcopy(steam64, maxlen, value);
        return true;
    }

    if (StrContains(value, "STEAM_", false) == 0)
    {
        return ConvertSteam2ToSteam64(value, steam64, maxlen);
    }

    if (value[0] == '[' || StrContains(value, "U:", false) == 0)
    {
        return ConvertSteam3ToSteam64(value, steam64, maxlen);
    }

    return false;
}

void AddDecimalStrings(const char[] base, const char[] delta, char[] output, int maxlen)
{
    char buffer[64];
    int pos = 0;
    int carry = 0;
    int i = strlen(base) - 1;
    int j = strlen(delta) - 1;

    while ((i >= 0 || j >= 0 || carry > 0) && pos < sizeof(buffer) - 1)
    {
        int digitBase = (i >= 0) ? (view_as<int>(base[i]) - view_as<int>('0')) : 0;
        int digitDelta = (j >= 0) ? (view_as<int>(delta[j]) - view_as<int>('0')) : 0;
        int sum = digitBase + digitDelta + carry;
        buffer[pos++] = '0' + (sum % 10);
        carry = sum / 10;
        i--;
        j--;
    }

    buffer[pos] = '\0';

    for (int start = 0, end = pos - 1; start < end; start++, end--)
    {
        char temp = buffer[start];
        buffer[start] = buffer[end];
        buffer[end] = temp;
    }

    strcopy(output, maxlen, buffer);
}

public void SQLErrorCheckCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[AdminsDB] SQL error: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
    }
}

public any Native_AdminsDB_GetClientWhitelistLevel(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return AdminsDb_GetClientWhitelistLevel(client);
}

public any Native_AdminsDB_GetSteamWhitelistLevel(Handle plugin, int numParams)
{
    char steamId[64];
    GetNativeString(1, steamId, sizeof(steamId));
    return AdminsDb_GetSteamWhitelistLevel(steamId);
}

int AdminsDb_ClampStoredLevel(int level)
{
    if (level > 3)
    {
        return 3;
    }
    if (level < -3)
    {
        return -3;
    }
    return level;
}

int AdminsDb_GetSteamWhitelistLevel(const char[] steamId)
{
    char steamId64[32];
    if (!NormalizeSteamIdToSteam64(steamId, steamId64, sizeof(steamId64)) || g_WhitelistLevels == null)
    {
        return 0;
    }

    int level = 0;
    if (!g_WhitelistLevels.GetValue(steamId64, level))
    {
        return 0;
    }
    return AdminsDb_ClampStoredLevel(level);
}

int AdminsDb_GetClientWhitelistLevel(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return 0;
    }

    return AdminsDb_ClampStoredLevel(g_ClientWhitelistLevel[client]);
}

void RefreshClientWhitelistLevel(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_ClientWhitelistLevel[client] = 0;
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId64[32];
    if (Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true))
    {
        g_ClientWhitelistLevel[client] = AdminsDb_GetSteamWhitelistLevel(steamId64);
    }
}

void RefreshConnectedWhitelistLevels()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        RefreshClientWhitelistLevel(client);
    }
}

Action RunWhitelistLevelCommand(int client, int args, bool blacklist)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[AdminsDB] Usage: sm_%s <player> <1-3>", blacklist ? "blacklist" : "whitelist");
        return Plugin_Handled;
    }

    char targetArg[64];
    char levelArg[16];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    GetCmdArg(2, levelArg, sizeof(levelArg));

    int absoluteLevel = StringToInt(levelArg);
    if (absoluteLevel < 1 || absoluteLevel > 3)
    {
        ReplyToCommand(client, "[AdminsDB] Level must be 1, 2, or 3.");
        return Plugin_Handled;
    }

    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    int level = blacklist ? -absoluteLevel : absoluteLevel;
    SetTargetWhitelistLevel(client, target, level);
    return Plugin_Handled;
}

Action RunClearWhitelistLevelCommand(int client, int args, const char[] commandName)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[AdminsDB] Usage: %s <player>", commandName);
        return Plugin_Handled;
    }

    char targetArg[64];
    GetCmdArg(1, targetArg, sizeof(targetArg));

    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    SetTargetWhitelistLevel(client, target, 0);
    return Plugin_Handled;
}

void SetTargetWhitelistLevel(int admin, int target, int level)
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        ReplyToCommand(admin, "[AdminsDB] Whitelist database is not ready.");
        ConnectToDatabase();
        return;
    }

    if (IsFakeClient(target))
    {
        ReplyToCommand(admin, "[AdminsDB] Target is a bot.");
        return;
    }

    char steamId64[32];
    if (!Kogasa_GetClientSteamId64(target, steamId64, sizeof(steamId64), true))
    {
        ReplyToCommand(admin, "[AdminsDB] Could not read target SteamID64.");
        return;
    }

    char escapedSteam[64];
    Db_Escape(g_hDatabase, steamId64, escapedSteam, sizeof(escapedSteam), "AdminsDB");

    char query[256];
    if (level == 0)
    {
        Format(query, sizeof(query), "DELETE FROM %s WHERE steamid64 = '%s'", ADMIN_WHITELIST_TABLE_NAME, escapedSteam);
        if (g_WhitelistLevels != null)
        {
            g_WhitelistLevels.Remove(steamId64);
        }
    }
    else
    {
        level = AdminsDb_ClampStoredLevel(level);
        Format(query, sizeof(query),
            "REPLACE INTO %s (steamid64, level) VALUES ('%s', %d)",
            ADMIN_WHITELIST_TABLE_NAME,
            escapedSteam,
            level);
        if (g_WhitelistLevels != null)
        {
            g_WhitelistLevels.SetValue(steamId64, level);
        }
    }

    g_ClientWhitelistLevel[target] = level;
    SQL_TQuery(g_hDatabase, SQLErrorCheckCallback, query);

    char targetName[MAX_NAME_LENGTH];
    GetClientName(target, targetName, sizeof(targetName));
    if (level > 0)
    {
        ShowActivity2(admin, "[AdminsDB] ", "set whitelist level %d for %s", level, targetName);
        LogAction(admin, target, "\"%L\" set whitelist level %d for \"%L\"", admin, level, target);
    }
    else if (level < 0)
    {
        ShowActivity2(admin, "[AdminsDB] ", "set blacklist level %d for %s", -level, targetName);
        LogAction(admin, target, "\"%L\" set blacklist level %d for \"%L\"", admin, -level, target);
    }
    else
    {
        ShowActivity2(admin, "[AdminsDB] ", "cleared whitelist/blacklist level for %s", targetName);
        LogAction(admin, target, "\"%L\" cleared whitelist/blacklist level for \"%L\"", admin, target);
    }
}

public Action Command_Whitelist(int client, int args)
{
    return RunWhitelistLevelCommand(client, args, false);
}

public Action Command_Blacklist(int client, int args)
{
    return RunWhitelistLevelCommand(client, args, true);
}

public Action Command_UnWhitelist(int client, int args)
{
    return RunClearWhitelistLevelCommand(client, args, "sm_unwhitelist");
}

public Action Command_UnBlacklist(int client, int args)
{
    return RunClearWhitelistLevelCommand(client, args, "sm_unblacklist");
}

public Action Command_ListWhitelists(int client, int args)
{
    return RunWhitelistLevelListCommand(client, true);
}

public Action Command_ListBlacklists(int client, int args)
{
    return RunWhitelistLevelListCommand(client, false);
}

Action RunWhitelistLevelListCommand(int client, bool whitelist)
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        ReplyToCommand(client, "[AdminsDB] Whitelist database is not ready.");
        ConnectToDatabase();
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(client <= 0 ? 0 : GetClientUserId(client));
    pack.WriteCell(whitelist ? 1 : 0);

    char query[512];
    Format(query, sizeof(query),
        "SELECT aw.steamid64, aw.level, COALESCE(NULLIF(fs.last_name, ''), aw.steamid64) "
        ... "FROM %s aw "
        ... "LEFT JOIN filters_steam_names fs ON fs.steamid64 = aw.steamid64 COLLATE utf8mb4_uca1400_ai_ci "
        ... "WHERE aw.level %s 0 "
        ... "ORDER BY ABS(aw.level) DESC, aw.steamid64 ASC LIMIT 64",
        ADMIN_WHITELIST_TABLE_NAME,
        whitelist ? ">" : "<");
    SQL_TQuery(g_hDatabase, SQL_OnWhitelistLevelList, query, pack);
    return Plugin_Handled;
}

public void SQL_OnWhitelistLevelList(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userId = pack.ReadCell();
    bool whitelist = pack.ReadCell() != 0;
    delete pack;

    int client = userId == 0 ? 0 : GetClientOfUserId(userId);
    if (userId != 0 && (client <= 0 || !IsClientInGame(client)))
    {
        return;
    }

    if (error[0] != '\0')
    {
        if (client > 0)
        {
            CPrintToChat(client, "{green}[AdminsDB]{default} Failed to load %s.", whitelist ? "whitelists" : "blacklists");
        }
        else
        {
            PrintToServer("[AdminsDB] Failed to load %s.", whitelist ? "whitelists" : "blacklists");
        }
        LogError("[AdminsDB] Failed to list whitelist levels: %s", error);
        return;
    }

    if (client > 0)
    {
        CPrintToChat(client, "{green}[AdminsDB]{default} %s:", whitelist ? "Whitelists" : "Blacklists");
    }
    else
    {
        PrintToServer("[AdminsDB] %s:", whitelist ? "Whitelists" : "Blacklists");
    }
    int count = 0;
    if (results != null)
    {
        char steamId64[32];
        char displayName[128];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId64, sizeof(steamId64));
            int level = results.FetchInt(1);
            results.FetchString(2, displayName, sizeof(displayName));
            if (client > 0)
            {
                CPrintToChat(client, "{green}[AdminsDB]{default} {gold}%d{default}: %s ({lightgreen}%s{default})", level, displayName, steamId64);
            }
            else
            {
                PrintToServer("[AdminsDB] %d: %s (%s)", level, displayName, steamId64);
            }
            count++;
        }
    }

    if (count == 0)
    {
        if (client > 0)
        {
            CPrintToChat(client, "{green}[AdminsDB]{default} None found.");
        }
        else
        {
            PrintToServer("[AdminsDB] None found.");
        }
    }
}

public Action Command_ShowAdmins(int client, int args)
{
    int admins[MAXPLAYERS + 1];
    int adminCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (AdminsDb_IsClientRootAdmin(i))
        {
            admins[adminCount++] = i;
        }
    }

    if (client <= 0 || !IsClientInGame(client))
    {
        if (adminCount == 0)
        {
            PrintToServer("[AdminsDB] No admins are currently online.");
        }
        else
        {
            PrintToServer("[AdminsDB] %d admin(s) online:", adminCount);
            char name[MAX_NAME_LENGTH];
            for (int i = 0; i < adminCount; i++)
            {
                GetClientName(admins[i], name, sizeof(name));
                PrintToServer(" - %s", name);
            }
        }
        return Plugin_Handled;
    }

    if (adminCount == 0)
    {
        CPrintToChat(client, "{green}[AdminsDB]{default} No admins are currently online.");
        return Plugin_Handled;
    }

    CPrintToChat(client, "{green}[AdminsDB]{default} Online admins (%d):", adminCount);
    char adminName[MAX_NAME_LENGTH];
    for (int i = 0; i < adminCount; i++)
    {
        GetClientName(admins[i], adminName, sizeof(adminName));
        CPrintToChat(client, "{green}[AdminsDB]{default} {gold}%s", adminName);
    }

    return Plugin_Handled;
}

public Action Command_CheckId(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    int target = client;
    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArg(1, targetArg, sizeof(targetArg));
        target = FindTarget(client, targetArg, true, false);
        if (target <= 0)
        {
            return Plugin_Handled;
        }
    }

    if (IsFakeClient(target))
    {
        CPrintToChat(client, "{green}[AdminsDB]{default} Target is a bot.");
        return Plugin_Handled;
    }

    char steam2[32];
    char steam3[32];
    char steam64[32];

    bool ok2 = Kogasa_GetClientSteam2(target, steam2, sizeof(steam2), false);
    bool ok3 = Kogasa_GetClientSteam3(target, steam3, sizeof(steam3), false);
    bool ok64 = Kogasa_GetClientSteamId64(target, steam64, sizeof(steam64), false);

    if (!ok2 && !ok3 && !ok64)
    {
        CPrintToChat(client, "{green}[AdminsDB]{default} Unable to read SteamID.");
        return Plugin_Handled;
    }

    if (!ok2)
    {
        strcopy(steam2, sizeof(steam2), "Unknown");
    }
    if (!ok3)
    {
        strcopy(steam3, sizeof(steam3), "Unknown");
    }
    if (!ok64)
    {
        strcopy(steam64, sizeof(steam64), "Unknown");
    }

    char targetName[MAX_NAME_LENGTH];
    GetClientName(target, targetName, sizeof(targetName));
    CPrintToChat(client, "{green}[AdminsDB]{default} %s", targetName);
    CPrintToChat(client, "{green}[AdminsDB]{default} Steam2: {gold}%s", steam2);
    CPrintToChat(client, "{green}[AdminsDB]{default} Steam3: {gold}%s", steam3);
    CPrintToChat(client, "{green}[AdminsDB]{default} Steam64: {gold}%s", steam64);

    return Plugin_Handled;
}

bool AdminsDb_IsClientRootAdmin(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    return (GetUserFlagBits(client) & ADMFLAG_ROOT) != 0;
}
