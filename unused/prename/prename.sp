#include <sourcemod>
#include <sdktools_functions>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0"
#define DB_CONFIG "default"
#define MAX_PATTERN 64
#define MAX_RENAME 64

StringMap g_IdRules = null;
StringMap g_OutputMap = null;
Database g_Db = null;
bool g_DbReady = false;
char g_DebugLogPath[PLATFORM_MAX_PATH];
bool g_DebugMigrate = false;

public Plugin myinfo =
{
    name = "prename",
    author = "Hombre",
    description = "Permanently rename players on join based on substring rules.",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_IdRules = new StringMap();
    g_OutputMap = new StringMap();

    RegAdminCmd("sm_prename", Command_Prename, ADMFLAG_SLAY, "sm_prename <name_substring|steamid> <newname>");
    RegAdminCmd("sm_reset", Command_PrenameReset, ADMFLAG_SLAY, "sm_reset <name_substring|steamid> - Removes a prename rule");
    RegAdminCmd("sm_migrate", Command_Migrate, ADMFLAG_SLAY, "sm_migrate - Migrates legacy name rules to SteamID rules for connected clients");

    BuildPath(Path_SM, g_DebugLogPath, sizeof(g_DebugLogPath), "logs/prename_migrate.log");

    SQL_TConnect(SQL_OnConnect, DB_CONFIG);
}

public void OnClientPutInServer(int client)
{
    CreateTimer(1.0, Timer_ApplyPrename, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyPrename(Handle timer, any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Stop;
    }

    ApplyPrename(client);
    return Plugin_Stop;
}

static bool ApplyPrename(int client)
{
    if (!g_DbReady || g_IdRules == null || g_OutputMap == null)
    {
        return false;
    }

    char currentName[MAX_NAME_LENGTH];
    GetClientName(client, currentName, sizeof(currentName));

    char lowerName[MAX_NAME_LENGTH];
    strcopy(lowerName, sizeof(lowerName), currentName);
    ToLowercaseInPlace(lowerName, sizeof(lowerName));

    char steam2[32];
    char steam64[32];
    GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));

    char rename[MAX_RENAME];
    if (TryGetIdRule(steam64, steam2, rename, sizeof(rename)))
    {
        if (!StrEqual(currentName, rename, false))
        {
            SetClientName(client, rename);
        }
        return false;
    }

    char output[MAX_RENAME];
    if (!TryGetOutputMatch(lowerName, output, sizeof(output)))
    {
        return false;
    }

    char migrateId[32];
    GetPreferredClientId(steam64, steam2, migrateId, sizeof(migrateId));
    if (migrateId[0])
    {
        SaveRule(migrateId, output);
        SetIdRuleCache(migrateId, output);
    }

    if (!StrEqual(currentName, output, false))
    {
        SetClientName(client, output);
    }
    return true;
}

public Action Command_Prename(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SM] Usage: sm_prename <name_substring|steamid> <newname>");
        return Plugin_Handled;
    }

    char patternRaw[MAX_PATTERN];
    char newname[MAX_RENAME];
    GetCmdArg(1, patternRaw, sizeof(patternRaw));
    GetCmdArg(2, newname, sizeof(newname));

    TrimString(patternRaw);
    TrimString(newname);
    if (!patternRaw[0] || !newname[0])
    {
        ReplyToCommand(client, "[SM] Usage: sm_prename <name_substring|steamid> <newname>");
        return Plugin_Handled;
    }

    if (IsIdString(patternRaw))
    {
        SaveRule(patternRaw, newname);
        SetIdRuleCache(patternRaw, newname);
        ReplyToCommand(client, "[SM] Prename rule saved: '%s' -> '%s'", patternRaw, newname);
        return Plugin_Handled;
    }

    int matches = 0;
    int target = 0;
    char matchList[256];
    matchList[0] = '\0';
    char name[MAX_NAME_LENGTH];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }
        GetClientName(i, name, sizeof(name));
        if (StrContains(name, patternRaw, false) == -1)
        {
            continue;
        }
        matches++;
        if (target == 0)
        {
            target = i;
        }
        if (matchList[0] == '\0')
        {
            strcopy(matchList, sizeof(matchList), name);
        }
        else if (strlen(matchList) + strlen(name) + 2 < sizeof(matchList))
        {
            StrCat(matchList, sizeof(matchList), ", ");
            StrCat(matchList, sizeof(matchList), name);
        }
    }

    if (matches == 0)
    {
        ReplyToCommand(client, "[SM] No client matches '%s'.", patternRaw);
        return Plugin_Handled;
    }

    if (matches > 1)
    {
        ReplyToCommand(client, "[SM] Multiple matches for '%s': %s", patternRaw, matchList);
        return Plugin_Handled;
    }

    char steam2[32];
    char steam64[32];
    GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
    char steamId[32];
    GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
    if (!steamId[0])
    {
        ReplyToCommand(client, "[SM] Failed to resolve SteamID for %s.", matchList);
        return Plugin_Handled;
    }

    SaveRule(steamId, newname);
    SetIdRuleCache(steamId, newname);
    SetClientName(target, newname);
    ReplyToCommand(client, "[SM] Prename rule saved: %s -> %s (%s)", matchList, newname, steamId);

    return Plugin_Handled;
}

public Action Command_PrenameReset(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_reset <name_substring|steamid>");
        return Plugin_Handled;
    }

    char idRaw[MAX_PATTERN];
    GetCmdArg(1, idRaw, sizeof(idRaw));
    TrimString(idRaw);

    if (!idRaw[0])
    {
        ReplyToCommand(client, "[SM] Usage: sm_reset <name_substring|steamid>");
        return Plugin_Handled;
    }

    // If a SteamID was provided, clear directly.
    char steam2[32];
    char steam64[32];
    if (IsIdString(idRaw))
    {
        if (StrContains(idRaw, "STEAM_", false) == 0)
        {
            int match = FindClientBySteam2(idRaw);
            if (match > 0)
            {
                GetClientIds(match, steam2, sizeof(steam2), steam64, sizeof(steam64));
                char steamId[32];
                GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
                if (steamId[0])
                {
                    DeleteRule(steamId);
                    RemoveIdRuleCache(steamId);
                    ReplyToCommand(client, "[SM] Prename rule removed for '%s'", steamId);
                    return Plugin_Handled;
                }
            }
        }

        DeleteRule(idRaw);
        RemoveIdRuleCache(idRaw);
        ReplyToCommand(client, "[SM] Prename rule removed for '%s'", idRaw);
        return Plugin_Handled;
    }

    // Otherwise treat it as a name substring and resolve to a single client.
    char targetName[MAX_NAME_LENGTH];
    int target = FindSingleClientByName(client, idRaw, targetName, sizeof(targetName));
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    GetClientIds(target, steam2, sizeof(steam2), steam64, sizeof(steam64));
    char steamId[32];
    GetPreferredClientId(steam64, steam2, steamId, sizeof(steamId));
    if (!steamId[0])
    {
        ReplyToCommand(client, "[SM] Failed to resolve SteamID for %s.", targetName);
        return Plugin_Handled;
    }

    DeleteRule(steamId);
    RemoveIdRuleCache(steamId);
    ReplyToCommand(client, "[SM] Prename rule removed for %s (%s).", targetName, steamId);
    return Plugin_Handled;
}

static int FindSingleClientByName(int requester, const char[] patternRaw, char[] matchName, int matchMax)
{
    char pattern[MAX_PATTERN];
    strcopy(pattern, sizeof(pattern), patternRaw);
    ToLowercaseInPlace(pattern, sizeof(pattern));

    int matches = 0;
    int target = -1;
    char matchList[256];
    matchList[0] = '\0';

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));

        char lowerName[MAX_NAME_LENGTH];
        strcopy(lowerName, sizeof(lowerName), name);
        ToLowercaseInPlace(lowerName, sizeof(lowerName));

        if (StrContains(lowerName, pattern, false) == -1)
        {
            continue;
        }

        matches++;
        target = i;
        if (matchMax > 0)
        {
            strcopy(matchName, matchMax, name);
        }

        if (matches == 1)
        {
            strcopy(matchList, sizeof(matchList), name);
        }
        else if (strlen(matchList) + strlen(name) + 2 < sizeof(matchList))
        {
            StrCat(matchList, sizeof(matchList), ", ");
            StrCat(matchList, sizeof(matchList), name);
        }
    }

    if (matches == 0)
    {
        ReplyToCommand(requester, "[SM] No client matches '%s'.", patternRaw);
        return -1;
    }

    if (matches > 1)
    {
        ReplyToCommand(requester, "[SM] Multiple matches for '%s': %s", patternRaw, matchList);
        return -1;
    }

    return target;
}

static int FindClientBySteam2(const char[] steam2)
{
    if (!steam2[0])
    {
        return -1;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        char id[32];
        GetClientAuthId(i, AuthId_Steam2, id, sizeof(id), true);
        if (StrEqual(id, steam2, false))
        {
            return i;
        }
    }

    return -1;
}

public Action Command_Migrate(int client, int args)
{
    int migrated = 0;
    int processed = 0;

    g_DebugMigrate = true;
    DebugLog("---- migrate start ----");
    DebugLog("db_ready=%d id_rules=%d output_rules=%d", g_DbReady ? 1 : 0, GetStringMapCount(g_IdRules), GetStringMapCount(g_OutputMap));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }
        processed++;
        migrated += MigrateLegacyForClient(i);
    }

    DebugLog("---- migrate end migrated=%d processed=%d ----", migrated, processed);
    g_DebugMigrate = false;

    ReplyToCommand(client, "[SM] Migrated %d rule(s) across %d client(s).", migrated, processed);
    return Plugin_Handled;
}

static int MigrateLegacyForClient(int client)
{
    if (!g_DbReady || g_IdRules == null || g_OutputMap == null)
    {
        DebugLog("client=%d skip db_ready=%d id_rules=%d output_rules=%d",
            client,
            g_DbReady ? 1 : 0,
            GetStringMapCount(g_IdRules),
            GetStringMapCount(g_OutputMap));
        return 0;
    }

    char currentName[MAX_NAME_LENGTH];
    GetClientName(client, currentName, sizeof(currentName));

    char lowerName[MAX_NAME_LENGTH];
    strcopy(lowerName, sizeof(lowerName), currentName);
    ToLowercaseInPlace(lowerName, sizeof(lowerName));

    char steam2[32];
    char steam64[32];
    GetClientIds(client, steam2, sizeof(steam2), steam64, sizeof(steam64));

    char migrateId[32];
    GetPreferredClientId(steam64, steam2, migrateId, sizeof(migrateId));

    if (!migrateId[0])
    {
        DebugLog("client=%d name=\"%s\" no_steamid", client, currentName);
        return 0;
    }

    char existing[MAX_RENAME];
    if (TryGetIdRule(steam64, steam2, existing, sizeof(existing)) && StrEqual(existing, currentName, false))
    {
        DebugLog("client=%d name=\"%s\" id=%s already_set", client, currentName, migrateId);
        return 0;
    }

    SaveRule(migrateId, currentName);
    SetIdRuleCache(migrateId, currentName);
    DebugLog("client=%d name=\"%s\" id=%s migrated=1", client, currentName, migrateId);
    return 1;
}

static void SaveRule(const char[] pattern, const char[] newname)
{
    if (!g_DbReady || g_Db == null)
    {
        return;
    }

    char escapedPattern[MAX_PATTERN * 2];
    char escapedNewname[MAX_RENAME * 2];
    SQL_EscapeString(g_Db, pattern, escapedPattern, sizeof(escapedPattern));
    SQL_EscapeString(g_Db, newname, escapedNewname, sizeof(escapedNewname));

    char query[256];
    Format(query, sizeof(query),
        "REPLACE INTO prename_rules (pattern, newname) VALUES ('%s', '%s')",
        escapedPattern, escapedNewname);
    g_Db.Query(SQL_GenericCallback, query);
}

static void DeleteRule(const char[] pattern)
{
    if (!g_DbReady || g_Db == null)
    {
        return;
    }

    char escapedPattern[MAX_PATTERN * 2];
    SQL_EscapeString(g_Db, pattern, escapedPattern, sizeof(escapedPattern));

    char query[256];
    Format(query, sizeof(query),
        "DELETE FROM prename_rules WHERE pattern = '%s'",
        escapedPattern);
    g_Db.Query(SQL_GenericCallback, query);
}

static void SetIdRuleCache(const char[] steamid, const char[] newname)
{
    if (g_IdRules == null)
    {
        return;
    }

    g_IdRules.SetString(steamid, newname);
}

static void RemoveIdRuleCache(const char[] steamid)
{
    if (g_IdRules == null)
    {
        return;
    }

    g_IdRules.Remove(steamid);
}

public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[Prename] DB connection failed: %s", error);
        return;
    }

    g_Db = view_as<Database>(hndl);
    g_DbReady = true;

    char query[256];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS prename_rules ("
        ... "pattern VARCHAR(64) PRIMARY KEY,"
        ... "newname VARCHAR(64) NOT NULL"
        ... ")");
    g_Db.Query(SQL_GenericCallback, query);

    g_Db.Query(SQL_LoadRulesCallback, "SELECT pattern, newname FROM prename_rules");
}

public void SQL_LoadRulesCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Prename] Failed to load rules: %s", error);
        return;
    }

    if (g_IdRules != null)
    {
        g_IdRules.Clear();
    }
    if (g_OutputMap != null)
    {
        g_OutputMap.Clear();
    }

    if (results == null)
    {
        return;
    }

    while (results.FetchRow())
    {
        char pattern[MAX_PATTERN];
        char newname[MAX_RENAME];
        results.FetchString(0, pattern, sizeof(pattern));
        results.FetchString(1, newname, sizeof(newname));

        if (IsIdString(pattern))
        {
            g_IdRules.SetString(pattern, newname);
            continue;
        }

        char lowerNew[MAX_RENAME];
        strcopy(lowerNew, sizeof(lowerNew), newname);
        ToLowercaseInPlace(lowerNew, sizeof(lowerNew));
        if (!g_OutputMap.ContainsKey(lowerNew))
        {
            g_OutputMap.SetString(lowerNew, newname);
        }
    }
}

public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Prename] SQL error: %s", error);
    }
}

static void ToLowercaseInPlace(char[] text, int maxlen)
{
    int length = strlen(text);
    if (length > maxlen - 1)
    {
        length = maxlen - 1;
    }

    for (int i = 0; i < length; i++)
    {
        text[i] = CharToLower(text[i]);
    }
}

static void GetPreferredClientId(const char[] steam64, const char[] steam2, char[] output, int maxlen)
{
    output[0] = '\0';
    if (steam64[0])
    {
        strcopy(output, maxlen, steam64);
    }
    else if (steam2[0])
    {
        strcopy(output, maxlen, steam2);
    }
}

static bool TryGetIdRule(const char[] steam64, const char[] steam2, char[] output, int maxlen)
{
    if (g_IdRules == null)
    {
        return false;
    }

    if (steam64[0] && g_IdRules.GetString(steam64, output, maxlen))
    {
        return true;
    }

    if (steam2[0] && g_IdRules.GetString(steam2, output, maxlen))
    {
        return true;
    }

    return false;
}

static bool TryGetOutputMatch(const char[] lowerName, char[] output, int maxlen)
{
    char key[MAX_RENAME];
    return FindBestOutputMatch(lowerName, output, maxlen, key, sizeof(key));
}

static bool FindBestOutputMatch(const char[] lowerName, char[] output, int outMax, char[] keyOut, int keyMax)
{
    if (g_OutputMap == null)
    {
        return false;
    }

    StringMapSnapshot snap = g_OutputMap.Snapshot();
    int count = snap.Length;
    int bestLen = -1;
    char key[MAX_RENAME];
    char bestKey[MAX_RENAME];
    bestKey[0] = '\0';

    for (int i = 0; i < count; i++)
    {
        snap.GetKey(i, key, sizeof(key));
        if (StrContains(lowerName, key) == -1)
        {
            continue;
        }

        int keyLen = strlen(key);
        if (keyLen > bestLen)
        {
            bestLen = keyLen;
            strcopy(bestKey, sizeof(bestKey), key);
        }
    }

    delete snap;

    if (bestKey[0] == '\0')
    {
        return false;
    }

    if (keyMax > 0)
    {
        strcopy(keyOut, keyMax, bestKey);
    }

    return g_OutputMap.GetString(bestKey, output, outMax);
}

static void GetClientIds(int client, char[] steam2, int steam2Max, char[] steam64, int steam64Max)
{
    steam2[0] = '\0';
    steam64[0] = '\0';
    GetClientAuthId(client, AuthId_SteamID64, steam64, steam64Max, true);
    GetClientAuthId(client, AuthId_Steam2, steam2, steam2Max, true);
}

static bool IsIdString(const char[] text)
{
    if (!text[0])
    {
        return false;
    }

    if (StrContains(text, "STEAM_", false) == 0)
    {
        return true;
    }

    int len = strlen(text);
    if (len < 15)
    {
        return false;
    }

    for (int i = 0; i < len; i++)
    {
        if (!IsCharNumeric(text[i]))
        {
            return false;
        }
    }

    return true;
}

static void DebugLog(const char[] fmt, any ...)
{
    if (!g_DebugMigrate)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_DebugLogPath, "%s", buffer);
}

static int GetStringMapCount(StringMap map)
{
    if (map == null)
    {
        return 0;
    }

    StringMapSnapshot snap = map.Snapshot();
    int count = snap.Length;
    delete snap;
    return count;
}
