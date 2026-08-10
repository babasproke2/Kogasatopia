#if defined _kogasa_database_helper_included
    #endinput
#endif
#define _kogasa_database_helper_included

#define KOGASA_SQL_DEFAULT_CONFIG "default"
#define KOGASA_SQL_RECONNECT_DELAY 10.0
#define KOGASA_SQL_RECONNECT_FAST_DELAY 2.0

stock bool KogasaSql_CheckConfigOrLog(const char[] pluginName, const char[] configName)
{
    if (SQL_CheckConfig(configName))
    {
        return true;
    }

    LogError("[%s] Database config \"%s\" is not configured.", pluginName, configName);
    return false;
}

stock bool KogasaSql_IsReady(Database db, bool ready)
{
    return db != null && ready;
}

stock void KogasaSql_Close(Database &db, bool &ready)
{
    ready = false;

    if (db != null)
    {
        delete db;
        db = null;
    }
}

stock void KogasaSql_CancelTimer(Handle &timer)
{
    if (timer != null && timer != INVALID_HANDLE)
    {
        KillTimer(timer);
        timer = null;
    }
}

stock bool KogasaSql_IsTransientError(const char[] error)
{
    return StrContains(error, "Lost connection", false) != -1
        || StrContains(error, "server has gone away", false) != -1
        || StrContains(error, "Server has gone away", false) != -1
        || StrContains(error, "Can't connect", false) != -1
        || StrContains(error, "Connection refused", false) != -1
        || StrContains(error, "Connection timed out", false) != -1
        || StrContains(error, "timeout", false) != -1
        || StrContains(error, "Too many connections", false) != -1
        || StrContains(error, "1040", false) != -1;
}

stock bool KogasaSql_IsDuplicateColumnError(const char[] error)
{
    return StrContains(error, "Duplicate column", false) != -1
        || StrContains(error, "duplicate column", false) != -1
        || StrContains(error, "1060", false) != -1;
}

stock bool KogasaSql_Escape(Database db, const char[] input, char[] output, int maxlen, const char[] pluginName)
{
    output[0] = '\0';

    if (db == null)
    {
        strcopy(output, maxlen, input);
        return false;
    }

    int written = 0;
    if (!db.Escape(input, output, maxlen, written))
    {
        LogError("[%s] Failed to escape SQL string of length %d.", pluginName, strlen(input));
        strcopy(output, maxlen, input);
        return false;
    }

    return true;
}
