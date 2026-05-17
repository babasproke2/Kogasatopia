#if defined _plugin_statistics_included
    #endinput
#endif
#define _plugin_statistics_included

#define PLUGIN_STATS_DB_CONFIG_DEFAULT "default"
#define PLUGIN_STATS_FLUSH_INTERVAL 30.0
#define PLUGIN_STATS_FLUSH_INTERVAL_CVAR "sm_mapsdb_plugin_statistics_flush_interval"
#define PLUGIN_STATS_QUERY_MAX 8192
#define PLUGIN_STATS_EVENT_NAME_MAX 64
#define PLUGIN_STATS_MESSAGE_MAX 512

enum struct PluginStatsEvent
{
    int OccurredAt;
    int HostPort;
    int Weekday;
    int HourOfDay;
    char MapSessionId[64];
    char MapName[128];
    char Gamemode[32];
    char EventName[PLUGIN_STATS_EVENT_NAME_MAX];
    char Message[PLUGIN_STATS_MESSAGE_MAX];
}

static Database g_PluginStatsDb = null;
static ArrayList g_PluginStatsQueue = null;
static Handle g_PluginStatsFlushTimer = null;
static bool g_PluginStatsDbReady = false;
static int g_PluginStatsMapStartedAt = 0;
static int g_PluginStatsDropped = 0;
static char g_PluginStatsDbConfig[64] = PLUGIN_STATS_DB_CONFIG_DEFAULT;
static char g_PluginStatsTable[64];

stock void PluginStats_Init(const char[] tableName, const char[] dbConfig = PLUGIN_STATS_DB_CONFIG_DEFAULT)
{
    strcopy(g_PluginStatsTable, sizeof(g_PluginStatsTable), tableName);
    strcopy(g_PluginStatsDbConfig, sizeof(g_PluginStatsDbConfig), dbConfig);

    if (g_PluginStatsQueue == null)
    {
        g_PluginStatsQueue = new ArrayList(sizeof(PluginStatsEvent));
    }

    if (g_PluginStatsFlushTimer == null)
    {
        PluginStats_ScheduleFlushTimer();
    }

    PluginStats_OnMapStart();
    PluginStats_ConnectDatabase();
}

stock void PluginStats_Shutdown()
{
    PluginStats_Flush();

    if (g_PluginStatsFlushTimer != null)
    {
        KillTimer(g_PluginStatsFlushTimer);
        g_PluginStatsFlushTimer = null;
    }

    delete g_PluginStatsQueue;
    g_PluginStatsQueue = null;

    if (g_PluginStatsDb != null)
    {
        delete g_PluginStatsDb;
        g_PluginStatsDb = null;
    }

    g_PluginStatsDbReady = false;
}

stock void PluginStats_OnMapStart()
{
    g_PluginStatsMapStartedAt = GetTime();
}

stock void PluginStats_LogMessage(const char[] message)
{
    if (g_PluginStatsQueue == null)
    {
        return;
    }

    if (g_PluginStatsQueue.Length >= 5000)
    {
        g_PluginStatsDropped++;
        return;
    }

    PluginStatsEvent event;
    event.OccurredAt = GetTime();
    event.HostPort = PluginStats_GetHostPort();
    PluginStats_GetWeekdayHour(event.OccurredAt, event.Weekday, event.HourOfDay);
    PluginStats_GetMapName(event.MapName, sizeof(event.MapName));
    PluginStats_GetGamemode(event.Gamemode, sizeof(event.Gamemode));
    PluginStats_GetMapSessionId(event.MapSessionId, sizeof(event.MapSessionId));
    PluginStats_DeriveEventName(message, event.EventName, sizeof(event.EventName));
    strcopy(event.Message, sizeof(event.Message), message);
    g_PluginStatsQueue.PushArray(event);
}

stock Action PluginStats_TimerFlush(Handle timer)
{
    g_PluginStatsFlushTimer = null;
    PluginStats_Flush();
    if (g_PluginStatsQueue != null)
    {
        PluginStats_ScheduleFlushTimer();
    }
    return Plugin_Stop;
}

stock void PluginStats_ScheduleFlushTimer()
{
    if (g_PluginStatsFlushTimer != null)
    {
        return;
    }

    g_PluginStatsFlushTimer = CreateTimer(PluginStats_GetFlushInterval(), PluginStats_TimerFlush);
}

stock float PluginStats_GetFlushInterval()
{
    ConVar interval = FindConVar(PLUGIN_STATS_FLUSH_INTERVAL_CVAR);
    if (interval == null)
    {
        return PLUGIN_STATS_FLUSH_INTERVAL;
    }

    float value = interval.FloatValue;
    if (value < 1.0)
    {
        return 1.0;
    }

    return value;
}

stock void PluginStats_Flush()
{
    if (g_PluginStatsQueue == null)
    {
        return;
    }

    if (g_PluginStatsDropped > 0)
    {
        char droppedMessage[128];
        Format(droppedMessage, sizeof(droppedMessage), "event=statistics_dropped|dropped=%d|queue_limit=5000", g_PluginStatsDropped);
        g_PluginStatsDropped = 0;
        PluginStats_LogMessage(droppedMessage);
    }

    if (g_PluginStatsQueue.Length == 0)
    {
        return;
    }

    if (!g_PluginStatsDbReady || g_PluginStatsDb == null)
    {
        PluginStats_ConnectDatabase();
        return;
    }

    char query[PLUGIN_STATS_QUERY_MAX];
    PluginStats_BuildInsertPrefix(query, sizeof(query));

    bool hasRows = false;
    int createdAt = GetTime();
    PluginStatsEvent event;

    for (int i = 0; i < g_PluginStatsQueue.Length; i++)
    {
        g_PluginStatsQueue.GetArray(i, event);

        char values[1536];
        PluginStats_FormatValues(event, values, sizeof(values), createdAt);

        int needed = strlen(query) + strlen(values) + (hasRows ? 2 : 0) + 1;
        if (hasRows && needed >= sizeof(query))
        {
            SQL_TQuery(g_PluginStatsDb, PluginStats_OnWriteComplete, query);
            PluginStats_BuildInsertPrefix(query, sizeof(query));
            hasRows = false;
        }

        if (hasRows)
        {
            StrCat(query, sizeof(query), ", ");
        }
        StrCat(query, sizeof(query), values);
        hasRows = true;
    }

    if (hasRows)
    {
        SQL_TQuery(g_PluginStatsDb, PluginStats_OnWriteComplete, query);
    }

    g_PluginStatsQueue.Clear();
}

stock void PluginStats_BuildInsertPrefix(char[] query, int maxlen)
{
    FormatEx(query, maxlen,
        "INSERT INTO %s (occurred_at, host_port, map_session_id, map_name, gamemode, event_name, message, weekday, hour_of_day, imported, source_file, source_line, created_at) VALUES ",
        g_PluginStatsTable);
}

stock void PluginStats_FormatValues(PluginStatsEvent event, char[] output, int maxlen, int createdAt)
{
    char mapSessionId[128];
    char mapName[256];
    char gamemode[96];
    char eventName[128];
    char message[1024];

    SQL_EscapeString(g_PluginStatsDb, event.MapSessionId, mapSessionId, sizeof(mapSessionId));
    SQL_EscapeString(g_PluginStatsDb, event.MapName, mapName, sizeof(mapName));
    SQL_EscapeString(g_PluginStatsDb, event.Gamemode, gamemode, sizeof(gamemode));
    SQL_EscapeString(g_PluginStatsDb, event.EventName, eventName, sizeof(eventName));
    SQL_EscapeString(g_PluginStatsDb, event.Message, message, sizeof(message));

    FormatEx(output, maxlen,
        "(%d, %d, '%s', '%s', '%s', '%s', '%s', %d, %d, 0, NULL, NULL, %d)",
        event.OccurredAt,
        event.HostPort,
        mapSessionId,
        mapName,
        gamemode,
        eventName,
        message,
        event.Weekday,
        event.HourOfDay,
        createdAt);
}

stock void PluginStats_ConnectDatabase()
{
    SQL_TConnect(PluginStats_OnConnect, g_PluginStatsDbConfig);
}

stock void PluginStats_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        g_PluginStatsDbReady = false;
        LogError("[plugin_statistics] Database connect failed for %s: %s", g_PluginStatsTable, error);
        return;
    }

    if (g_PluginStatsDb != null)
    {
        delete g_PluginStatsDb;
    }

    g_PluginStatsDb = view_as<Database>(hndl);
    g_PluginStatsDbReady = true;
    PluginStats_EnsureSchema();
}

stock void PluginStats_EnsureSchema()
{
    if (g_PluginStatsDb == null || !g_PluginStatsTable[0])
    {
        return;
    }

    char query[4096];
    FormatEx(query, sizeof(query), "CREATE TABLE IF NOT EXISTS %s (", g_PluginStatsTable);
    StrCat(query, sizeof(query), "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,");
    StrCat(query, sizeof(query), "occurred_at INT NOT NULL,");
    StrCat(query, sizeof(query), "host_port INT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "map_session_id VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "map_name VARCHAR(128) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "gamemode VARCHAR(32) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "event_name VARCHAR(64) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "message VARCHAR(512) NOT NULL DEFAULT '',");
    StrCat(query, sizeof(query), "weekday TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "hour_of_day TINYINT NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "imported TINYINT(1) NOT NULL DEFAULT 0,");
    StrCat(query, sizeof(query), "source_file VARCHAR(255) NULL,");
    StrCat(query, sizeof(query), "source_line INT NULL,");
    StrCat(query, sizeof(query), "created_at INT NOT NULL,");
    StrCat(query, sizeof(query), "KEY idx_occurred_at (occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_host_occurred_at (host_port, occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_map_session (map_session_id),");
    StrCat(query, sizeof(query), "KEY idx_map_occurred_at (map_name, occurred_at),");
    StrCat(query, sizeof(query), "KEY idx_event_name (event_name),");
    StrCat(query, sizeof(query), "KEY idx_weekday_hour (weekday, hour_of_day),");
    StrCat(query, sizeof(query), "UNIQUE KEY uniq_import_source (source_file, source_line)");
    StrCat(query, sizeof(query), ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    SQL_TQuery(g_PluginStatsDb, PluginStats_OnSchemaComplete, query);
}

stock void PluginStats_OnSchemaComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[plugin_statistics] Schema update failed for %s: %s", g_PluginStatsTable, error);
    }
}

stock void PluginStats_OnWriteComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[plugin_statistics] Write failed for %s: %s", g_PluginStatsTable, error);
    if (StrContains(error, "Lost connection", false) != -1 || StrContains(error, "server has gone away", false) != -1)
    {
        g_PluginStatsDbReady = false;
        PluginStats_ConnectDatabase();
    }
}

stock int PluginStats_GetHostPort()
{
    ConVar hostPort = FindConVar("hostport");
    return hostPort == null ? 0 : hostPort.IntValue;
}

stock void PluginStats_GetMapSessionId(char[] output, int maxlen)
{
    int startedAt = g_PluginStatsMapStartedAt;
    if (startedAt <= 0)
    {
        startedAt = GetTime();
    }
    Format(output, maxlen, "%d-%d", PluginStats_GetHostPort(), startedAt);
}

stock void PluginStats_GetMapName(char[] output, int maxlen)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_CurrentNormalizedMap") == FeatureStatus_Available
        && DGM_CurrentNormalizedMap(output, maxlen))
    {
        return;
    }

    GetCurrentMap(output, maxlen);
    if (GetFeatureStatus(FeatureType_Native, "DGM_NormalizeMapName") == FeatureStatus_Available)
    {
        DGM_NormalizeMapName(output, output, maxlen);
    }
}

stock void PluginStats_GetGamemode(char[] output, int maxlen)
{
    strcopy(output, maxlen, "default");
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") == FeatureStatus_Available)
    {
        DGM_GetGameModeKey(output, maxlen);
    }
}

stock void PluginStats_GetWeekdayHour(int timestamp, int &weekday, int &hourOfDay)
{
    char buffer[8];
    FormatTime(buffer, sizeof(buffer), "%w", timestamp);
    weekday = StringToInt(buffer);
    FormatTime(buffer, sizeof(buffer), "%H", timestamp);
    hourOfDay = StringToInt(buffer);
}

stock void PluginStats_DeriveEventName(const char[] message, char[] output, int maxlen)
{
    if (PluginStats_KnownEventName(message, output, maxlen))
    {
        return;
    }

    int start = 0;
    if (strncmp(message, "event=", 6, false) == 0)
    {
        start = 6;
    }

    int pos = 0;
    for (int i = start; message[i] != '\0' && pos < maxlen - 1; i++)
    {
        char c = message[i];
        if (c == '|' || c == ':' || c == '.' || c == '(')
        {
            break;
        }

        if ((c >= 'A' && c <= 'Z'))
        {
            c += 32;
        }

        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
        {
            output[pos++] = c;
        }
        else if (c == ' ' || c == '-' || c == '_')
        {
            if (pos > 0 && output[pos - 1] != '_')
            {
                output[pos++] = '_';
            }
        }
    }

    while (pos > 0 && output[pos - 1] == '_')
    {
        pos--;
    }
    output[pos] = '\0';

    if (!output[0])
    {
        strcopy(output, maxlen, "event");
    }
}

stock bool PluginStats_KnownEventName(const char[] message, char[] output, int maxlen)
{
    int start = 0;
    if (strncmp(message, "[autobalance_4teams] ", 21, false) == 0)
    {
        start = 21;
    }

    if (strncmp(message[start], "Autobalancing ", 14, false) == 0)
    {
        strcopy(output, maxlen, "autobalance_move");
        return true;
    }
    if (strncmp(message[start], "Imbalance:", 10, false) == 0)
    {
        strcopy(output, maxlen, "imbalance_detected");
        return true;
    }
    if (strncmp(message[start], "Volunteer priority", 18, false) == 0)
    {
        strcopy(output, maxlen, "volunteer_priority");
        return true;
    }
    if (strncmp(message[start], "Skip balance", 12, false) == 0)
    {
        strcopy(output, maxlen, "balance_skipped");
        return true;
    }
    if (strncmp(message[start], "Persistent immunity", 19, false) == 0)
    {
        strcopy(output, maxlen, "immunity_changed");
        return true;
    }
    if (StrContains(message[start], "volunteer", false) != -1)
    {
        strcopy(output, maxlen, "volunteer_changed");
        return true;
    }

    return false;
}
