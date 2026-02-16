#include <sourcemod>
#include <dbi>
#include <files>
#include <morecolors>

#pragma semicolon 1
#pragma newdecls required

#define ADMIN_DB_CONFIG "default"
#define ADMIN_TABLE_NAME "admins"
#define MAX_FLAG_LEN 32
#define MAX_NAME_LEN 128

char g_sAdminsFile[PLATFORM_MAX_PATH];
Database g_hDatabase = null;
Handle g_hReconnectTimer = null;
static const char STEAM64_BASE_STR[] = "76561197960265728";

public Plugin myinfo =
{
    name = "AdminsDB Sync",
    author = "Hombre",
    description = "Syncs admins_simple.ini to database",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    BuildPath(Path_SM, g_sAdminsFile, sizeof(g_sAdminsFile), "configs/admins_simple.ini");
    ConnectToDatabase();
    RegConsoleCmd("sm_admins", Command_ShowAdmins, "Lists online admins");
    RegConsoleCmd("sm_checkid", Command_CheckId, "Shows your SteamID formats");
}

public void OnPluginEnd()
{
    if (g_hReconnectTimer != null)
    {
        CloseHandle(g_hReconnectTimer);
        g_hReconnectTimer = null;
    }

    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }
}

void ConnectToDatabase()
{
    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }

    if (g_hReconnectTimer != null)
    {
        CloseHandle(g_hReconnectTimer);
        g_hReconnectTimer = null;
    }

    if (!SQL_CheckConfig(ADMIN_DB_CONFIG))
    {
        LogError("[AdminsDB] Database config '%s' not found.", ADMIN_DB_CONFIG);
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, ADMIN_DB_CONFIG);
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[AdminsDB] Database connection failed: %s", error[0] ? error : "unknown error");
        if (g_hReconnectTimer == null)
        {
            g_hReconnectTimer = CreateTimer(10.0, Timer_ReconnectDatabase, _, TIMER_FLAG_NO_MAPCHANGE);
        }
        return;
    }

    g_hDatabase = view_as<Database>(hndl);
    EnsureAdminTable();
    SyncAdmins();
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    g_hReconnectTimer = null;
    ConnectToDatabase();
    return Plugin_Stop;
}

void EnsureAdminTable()
{
    if (g_hDatabase == null)
    {
        return;
    }

    char query[256];
    Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (steamid2 VARCHAR(32) NOT NULL, steamid64 VARCHAR(32) NOT NULL, admin_status ENUM('yes','no') NOT NULL DEFAULT 'no')", ADMIN_TABLE_NAME);
    SQL_TQuery(g_hDatabase, SQLErrorCheckCallback, query);
}

void SyncAdmins()
{
    if (g_hDatabase == null)
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
    }
}

public Action Command_ShowAdmins(int client, int args)
{
    int admins[MAXPLAYERS + 1];
    int adminCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (AdminsDb_IsClientAdmin(i))
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

    bool ok2 = GetClientAuthId(target, AuthId_Steam2, steam2, sizeof(steam2), false);
    bool ok3 = GetClientAuthId(target, AuthId_Steam3, steam3, sizeof(steam3), false);
    bool ok64 = GetClientAuthId(target, AuthId_SteamID64, steam64, sizeof(steam64), false);

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

bool AdminsDb_IsClientAdmin(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }
    AdminId id = GetUserAdmin(client);
    return (id != INVALID_ADMIN_ID);
}
