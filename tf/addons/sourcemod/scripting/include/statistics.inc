#if defined _kogasa_statistics_helper_included
    #endinput
#endif
#define _kogasa_statistics_helper_included

#if defined REQUIRE_EXTENSIONS
    #define PLUGIN_STATS_RESTORE_REQUIRE_EXTENSIONS
    #undef REQUIRE_EXTENSIONS
#endif
#include <socket>
#include "database.inc"
#include "server_context.inc"
#include "timestamps.inc"
#if defined PLUGIN_STATS_RESTORE_REQUIRE_EXTENSIONS
    #define REQUIRE_EXTENSIONS
    #undef PLUGIN_STATS_RESTORE_REQUIRE_EXTENSIONS
#endif

#define PLUGIN_STATS_DB_CONFIG_DEFAULT "default"
#define PLUGIN_STATS_FLUSH_INTERVAL 30.0
#define PLUGIN_STATS_FLUSH_INTERVAL_CVAR "sm_mapsdb_plugin_statistics_flush_interval"
#define PLUGIN_STATS_QUERY_MAX 8192
#define PLUGIN_STATS_EVENT_NAME_MAX 64
#define PLUGIN_STATS_MESSAGE_MAX 512
#define PLUGIN_STATS_EVENT_ID_MAX 96
#define PLUGIN_STATS_RUST_MAX_BATCH_JSON 32768
#define PLUGIN_STATS_RUST_MAX_RECV_BUFFER 32768
#define PLUGIN_STATS_RUST_MAX_LINE 2048

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
    char EventId[PLUGIN_STATS_EVENT_ID_MAX];
}

static Database g_PluginStatsDb = null;
static ArrayList g_PluginStatsQueue = null;
static ArrayList g_PluginStatsInflight = null;
static Handle g_PluginStatsFlushTimer = null;
static Handle g_PluginStatsRustReconnectTimer = null;
static Socket g_PluginStatsRustSocket = null;
static bool g_PluginStatsDbReady = false;
static bool g_PluginStatsRustConnecting = false;
static bool g_PluginStatsRustConnected = false;
static bool g_PluginStatsRustAwaitingAck = false;
static int g_PluginStatsMapStartedAt = 0;
static int g_PluginStatsDropped = 0;
static int g_PluginStatsRustNextBatchId = 1;
static int g_PluginStatsNextEventId = 1;
static int g_PluginStatsRustPendingBatchId = 0;
static int g_PluginStatsRustRecvBufferLen = 0;
static char g_PluginStatsDbConfig[64] = PLUGIN_STATS_DB_CONFIG_DEFAULT;
static char g_PluginStatsTable[64];
static char g_PluginStatsRustRecvBuffer[PLUGIN_STATS_RUST_MAX_RECV_BUFFER];
static ConVar g_PluginStatsRustEnabled = null;
static ConVar g_PluginStatsRustHost = null;
static ConVar g_PluginStatsRustPort = null;
static ConVar g_PluginStatsRustQueueMax = null;
static ConVar g_PluginStatsRustBatchMax = null;
static ConVar g_PluginStatsRustServerId = null;
static ConVar g_PluginStatsRustAuthToken = null;
static ConVar g_PluginStatsRustFallbackSql = null;
static ConVar g_PluginStatsRustDebug = null;

stock void PluginStats_Init(const char[] tableName, const char[] dbConfig = PLUGIN_STATS_DB_CONFIG_DEFAULT)
{
    strcopy(g_PluginStatsTable, sizeof(g_PluginStatsTable), tableName);
    strcopy(g_PluginStatsDbConfig, sizeof(g_PluginStatsDbConfig), dbConfig);

	    if (g_PluginStatsQueue == null)
	    {
	        g_PluginStatsQueue = new ArrayList(sizeof(PluginStatsEvent));
	    }
	    if (g_PluginStatsInflight == null)
	    {
	        g_PluginStatsInflight = new ArrayList(sizeof(PluginStatsEvent));
	    }

	    PluginStats_InitConVars();

	    if (g_PluginStatsFlushTimer == null)
    {
        PluginStats_ScheduleFlushTimer();
    }

	    PluginStats_OnMapStart();
	    PluginStats_ConnectDatabase();
	    PluginStats_RustConnectSocket();
	}

stock void PluginStats_Shutdown()
{
    PluginStats_Flush();

    KogasaSql_CancelTimer(g_PluginStatsFlushTimer);

	    delete g_PluginStatsQueue;
	    g_PluginStatsQueue = null;

	    delete g_PluginStatsInflight;
	    g_PluginStatsInflight = null;

	    PluginStats_RustDisconnectSocket();
	    KogasaSql_CancelTimer(g_PluginStatsRustReconnectTimer);

	    KogasaSql_Close(g_PluginStatsDb, g_PluginStatsDbReady);
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

	    int queueMax = PluginStats_GetQueueMax();
	    if (g_PluginStatsQueue.Length >= queueMax)
	    {
	        g_PluginStatsDropped++;
	        return;
    }

    PluginStatsEvent event;
    event.OccurredAt = GetTime();
    event.HostPort = ServerContext_GetHostPort();
    Timestamps_GetWeekdayHour(event.OccurredAt, event.Weekday, event.HourOfDay);
    ServerContext_GetCurrentMapName(event.MapName, sizeof(event.MapName));
    ServerContext_GetGamemodeKey(event.Gamemode, sizeof(event.Gamemode));
    PluginStats_GetMapSessionId(event.MapSessionId, sizeof(event.MapSessionId));
    PluginStats_DeriveEventName(message, event.EventName, sizeof(event.EventName));
    strcopy(event.Message, sizeof(event.Message), message);
    PluginStats_BuildEventId(event.EventId, sizeof(event.EventId), event.OccurredAt);
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

stock void PluginStats_InitConVars()
{
    g_PluginStatsRustEnabled = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_rust", "1", "Send plugin statistics events to kogasa-statistics-rust when available.");
    g_PluginStatsRustHost = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_rust_host", "127.0.0.1", "kogasa-statistics-rust TCP host.");
    g_PluginStatsRustPort = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_rust_port", "28019", "kogasa-statistics-rust TCP port.");
    g_PluginStatsRustQueueMax = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_queue_max", "5000", "Maximum queued plugin statistics events before dropping oldest events.");
    g_PluginStatsRustBatchMax = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_batch_max", "128", "Maximum plugin statistics events sent per Rust batch.");
    g_PluginStatsRustServerId = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_server_id", "", "Optional server identifier sent to kogasa-statistics-rust.");
    g_PluginStatsRustAuthToken = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_rust_auth_token", "", "Optional auth token sent to kogasa-statistics-rust.");
    g_PluginStatsRustFallbackSql = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_fallback_sql", "1", "Use SourceMod SQL writes when kogasa-statistics-rust is unavailable.");
    g_PluginStatsRustDebug = PluginStats_FindOrCreateConVar("sm_kogasa_statistics_debug", "0", "Enable verbose kogasa-statistics-rust bridge logging.");
}

stock ConVar PluginStats_FindOrCreateConVar(const char[] name, const char[] defaultValue, const char[] description)
{
    ConVar cvar = FindConVar(name);
    if (cvar != null)
    {
        return cvar;
    }

    return CreateConVar(name, defaultValue, description);
}

stock int PluginStats_GetQueueMax()
{
    int queueMax = g_PluginStatsRustQueueMax == null ? 5000 : g_PluginStatsRustQueueMax.IntValue;
    return queueMax < 1 ? 1 : queueMax;
}

stock bool PluginStats_RustSocketApiAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "Socket.Connect") == FeatureStatus_Available;
}

stock bool PluginStats_UseRust()
{
    return g_PluginStatsRustEnabled != null && g_PluginStatsRustEnabled.BoolValue && PluginStats_RustSocketApiAvailable();
}

stock bool PluginStats_RustFallbackSqlEnabled()
{
    return g_PluginStatsRustFallbackSql == null || g_PluginStatsRustFallbackSql.BoolValue;
}

stock bool PluginStats_RustDebugEnabled()
{
    return g_PluginStatsRustDebug != null && g_PluginStatsRustDebug.BoolValue;
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
	        Format(droppedMessage, sizeof(droppedMessage), "event=statistics_dropped|dropped=%d|queue_limit=%d", g_PluginStatsDropped, PluginStats_GetQueueMax());
	        g_PluginStatsDropped = 0;
	        PluginStats_LogMessage(droppedMessage);
    }

    if (g_PluginStatsQueue.Length == 0)
    {
        return;
    }

	    if (PluginStats_UseRust())
	    {
	        PluginStats_RustConnectSocket();
	        if (PluginStats_RustFlushBatch())
	        {
	            return;
	        }

	        if (g_PluginStatsRustConnecting || !PluginStats_RustFallbackSqlEnabled())
	        {
	            return;
	        }
	    }

	    PluginStats_FlushLocal();
	}

	stock void PluginStats_FlushLocal()
	{
	    if (g_PluginStatsQueue == null || g_PluginStatsQueue.Length == 0)
	    {
	        return;
	    }

	    if (!KogasaSql_IsReady(g_PluginStatsDb, g_PluginStatsDbReady))
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

    KogasaSql_Escape(g_PluginStatsDb, event.MapSessionId, mapSessionId, sizeof(mapSessionId), "plugin_statistics");
    KogasaSql_Escape(g_PluginStatsDb, event.MapName, mapName, sizeof(mapName), "plugin_statistics");
    KogasaSql_Escape(g_PluginStatsDb, event.Gamemode, gamemode, sizeof(gamemode), "plugin_statistics");
    KogasaSql_Escape(g_PluginStatsDb, event.EventName, eventName, sizeof(eventName), "plugin_statistics");
    KogasaSql_Escape(g_PluginStatsDb, event.Message, message, sizeof(message), "plugin_statistics");

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
    KogasaSql_Close(g_PluginStatsDb, g_PluginStatsDbReady);
    if (!KogasaSql_CheckConfigOrLog("plugin_statistics", g_PluginStatsDbConfig))
    {
        return;
    }

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

    KogasaSql_Close(g_PluginStatsDb, g_PluginStatsDbReady);

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
        if (KogasaSql_IsTransientError(error))
        {
            g_PluginStatsDbReady = false;
            PluginStats_ConnectDatabase();
        }
    }
}

stock void PluginStats_OnWriteComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    LogError("[plugin_statistics] Write failed for %s: %s", g_PluginStatsTable, error);
    if (KogasaSql_IsTransientError(error))
    {
        g_PluginStatsDbReady = false;
        PluginStats_ConnectDatabase();
	    }
	}

stock void PluginStats_RustJsonEscape(const char[] input, char[] output, int maxlen)
{
    int outPos = 0;
    for (int i = 0; input[i] != '\0' && outPos < maxlen - 1; i++)
    {
        char c = input[i];
        int ci = c;
        if (ci < 0)
        {
            ci += 256;
        }

        if (ci == '"' || ci == '\\')
        {
            if (outPos + 2 >= maxlen)
            {
                break;
            }
            output[outPos++] = '\\';
            output[outPos++] = c;
            continue;
        }

        if (c == '\n' || c == '\r' || c == '\t')
        {
            if (outPos + 2 >= maxlen)
            {
                break;
            }
            output[outPos++] = '\\';
            output[outPos++] = (c == '\n') ? 'n' : ((c == '\r') ? 'r' : 't');
            continue;
        }

        if (ci < 32)
        {
            continue;
        }

        if (ci > 127)
        {
            output[outPos++] = '?';
            continue;
        }

        output[outPos++] = c;
    }
    output[outPos] = '\0';
}

stock void PluginStats_RustBuildServerId(char[] buffer, int maxlen)
{
    if (g_PluginStatsRustServerId != null)
    {
        g_PluginStatsRustServerId.GetString(buffer, maxlen);
        TrimString(buffer);
        if (buffer[0] != '\0')
        {
            return;
        }
    }

    char hostname[128];
    ConVar hostnameCvar = FindConVar("hostname");
    if (hostnameCvar != null)
    {
        hostnameCvar.GetString(hostname, sizeof(hostname));
    }
    else
    {
        strcopy(hostname, sizeof(hostname), "unknown");
    }

    FormatEx(buffer, maxlen, "%s:%d", hostname, ServerContext_GetHostPort());
}

stock void PluginStats_BuildEventId(char[] buffer, int maxlen, int occurredAt)
{
    int mapStartedAt = g_PluginStatsMapStartedAt;
    if (mapStartedAt <= 0)
    {
        mapStartedAt = GetTime();
    }

    int sequence = g_PluginStatsNextEventId++;
    if (g_PluginStatsNextEventId <= 0)
    {
        g_PluginStatsNextEventId = 1;
    }

    FormatEx(buffer, maxlen, "%d-%d-%d-%d", ServerContext_GetHostPort(), mapStartedAt, occurredAt, sequence);
}

stock bool PluginStats_RustExtractJsonInt(const char[] line, const char[] key, int &value)
{
    int pos = StrContains(line, key, false);
    if (pos == -1)
    {
        return false;
    }

    pos += strlen(key);
    while (line[pos] == ' ')
    {
        pos++;
    }

    bool negative = false;
    if (line[pos] == '-')
    {
        negative = true;
        pos++;
    }

    if (line[pos] < '0' || line[pos] > '9')
    {
        return false;
    }

    int parsed = 0;
    while (line[pos] >= '0' && line[pos] <= '9')
    {
        parsed = (parsed * 10) + (line[pos] - '0');
        pos++;
    }

    value = negative ? -parsed : parsed;
    return true;
}

stock void PluginStats_RustHandleFailedInflight(const char[] reason, const char[] line = "")
{
    g_PluginStatsRustAwaitingAck = false;
    if (line[0] != '\0')
    {
        LogError("[plugin_statistics] %s for %s: %s", reason, g_PluginStatsTable, line);
    }
    else
    {
        LogError("[plugin_statistics] %s for %s", reason, g_PluginStatsTable);
    }

    PluginStats_RustRequeueInflight();
    if (PluginStats_RustFallbackSqlEnabled())
    {
        PluginStats_FlushLocal();
    }
}

stock void PluginStats_RustClearInflight()
{
    if (g_PluginStatsInflight != null)
    {
        g_PluginStatsInflight.Clear();
    }
    g_PluginStatsRustPendingBatchId = 0;
}

stock void PluginStats_RustRequeueInflight()
{
    if (g_PluginStatsInflight == null || g_PluginStatsInflight.Length == 0 || g_PluginStatsQueue == null)
    {
        return;
    }

    PluginStatsEvent event;
    for (int i = 0; i < g_PluginStatsInflight.Length; i++)
    {
        if (g_PluginStatsQueue.Length >= PluginStats_GetQueueMax())
        {
            g_PluginStatsQueue.Erase(0);
            g_PluginStatsDropped++;
        }
        g_PluginStatsInflight.GetArray(i, event);
        g_PluginStatsQueue.PushArray(event);
    }

    PluginStats_RustClearInflight();
}

stock void PluginStats_RustScheduleReconnect()
{
    if (!PluginStats_UseRust() || g_PluginStatsRustReconnectTimer != null)
    {
        return;
    }

    g_PluginStatsRustReconnectTimer = CreateTimer(2.0, PluginStats_RustReconnectTimer);
}

stock Action PluginStats_RustReconnectTimer(Handle timer, any data)
{
    g_PluginStatsRustReconnectTimer = null;
    PluginStats_RustConnectSocket();
    return Plugin_Stop;
}

stock void PluginStats_RustDisconnectSocket()
{
    g_PluginStatsRustConnecting = false;
    g_PluginStatsRustConnected = false;
    g_PluginStatsRustAwaitingAck = false;
    g_PluginStatsRustPendingBatchId = 0;
    g_PluginStatsRustRecvBufferLen = 0;
    g_PluginStatsRustRecvBuffer[0] = '\0';

    if (g_PluginStatsRustSocket != null)
    {
        CloseHandle(g_PluginStatsRustSocket);
        g_PluginStatsRustSocket = null;
    }
}

stock void PluginStats_RustConnectSocket()
{
    if (!PluginStats_UseRust() || g_PluginStatsRustConnected || g_PluginStatsRustConnecting)
    {
        return;
    }

    if (g_PluginStatsRustReconnectTimer != null)
    {
        KogasaSql_CancelTimer(g_PluginStatsRustReconnectTimer);
    }

    PluginStats_RustDisconnectSocket();

    char host[128];
    g_PluginStatsRustHost.GetString(host, sizeof(host));
    int port = g_PluginStatsRustPort.IntValue;
    if (port <= 0)
    {
        port = 28019;
    }

    g_PluginStatsRustSocket = new Socket(SOCKET_TCP, PluginStats_RustOnSocketError);
    if (g_PluginStatsRustSocket == null)
    {
        LogError("[plugin_statistics] Failed to create Rust statistics socket for %s", g_PluginStatsTable);
        PluginStats_RustScheduleReconnect();
        return;
    }

    g_PluginStatsRustSocket.SetOption(SocketKeepAlive, 1);
    g_PluginStatsRustSocket.SetOption(SocketSendBuffer, 65536);
    g_PluginStatsRustSocket.SetOption(SocketReceiveBuffer, 65536);
    g_PluginStatsRustConnecting = true;

    if (PluginStats_RustDebugEnabled())
    {
        LogMessage("[plugin_statistics] connecting %s to kogasa-statistics-rust at %s:%d", g_PluginStatsTable, host, port);
    }

    g_PluginStatsRustSocket.Connect(PluginStats_RustOnSocketConnected, PluginStats_RustOnSocketReceive, PluginStats_RustOnSocketDisconnected, host, port);
}

stock bool PluginStats_RustFlushBatch()
{
    if (!PluginStats_UseRust() || !g_PluginStatsRustConnected || g_PluginStatsRustSocket == null)
    {
        return false;
    }

    if (g_PluginStatsRustAwaitingAck)
    {
        return true;
    }

    if (g_PluginStatsQueue == null || g_PluginStatsQueue.Length == 0)
    {
        return true;
    }

    char out[PLUGIN_STATS_RUST_MAX_BATCH_JSON];
    char escapedTable[128];
    PluginStats_RustJsonEscape(g_PluginStatsTable, escapedTable, sizeof(escapedTable));

    int pos = 0;
    int batchId = g_PluginStatsRustNextBatchId++;
    pos += FormatEx(out[pos], sizeof(out) - pos, "{\"type\":\"stats_batch\",\"batch_id\":%d,\"table\":\"%s\",\"sent_at\":%d,\"events\":[", batchId, escapedTable, GetTime());

    int batchMax = g_PluginStatsRustBatchMax == null ? 128 : g_PluginStatsRustBatchMax.IntValue;
    if (batchMax < 1)
    {
        batchMax = 1;
    }

    PluginStats_RustClearInflight();
    PluginStatsEvent event;
    int sentCount = 0;

    for (int i = 0; i < g_PluginStatsQueue.Length && sentCount < batchMax; i++)
    {
        if (pos + 1900 >= sizeof(out))
        {
            break;
        }

        g_PluginStatsQueue.GetArray(i, event);

        char mapSessionId[128], mapName[256], gamemode[96], eventName[128], message[1024], eventId[192];
        PluginStats_RustJsonEscape(event.EventId, eventId, sizeof(eventId));
        PluginStats_RustJsonEscape(event.MapSessionId, mapSessionId, sizeof(mapSessionId));
        PluginStats_RustJsonEscape(event.MapName, mapName, sizeof(mapName));
        PluginStats_RustJsonEscape(event.Gamemode, gamemode, sizeof(gamemode));
        PluginStats_RustJsonEscape(event.EventName, eventName, sizeof(eventName));
        PluginStats_RustJsonEscape(event.Message, message, sizeof(message));

        if (sentCount > 0)
        {
            out[pos++] = ',';
            out[pos] = '\0';
        }

        pos += FormatEx(out[pos], sizeof(out) - pos,
            "{\"event_id\":\"%s\",\"occurred_at\":%d,\"host_port\":%d,\"map_session_id\":\"%s\",\"map_name\":\"%s\",\"gamemode\":\"%s\",\"event_name\":\"%s\",\"message\":\"%s\",\"weekday\":%d,\"hour_of_day\":%d}",
            eventId,
            event.OccurredAt,
            event.HostPort,
            mapSessionId,
            mapName,
            gamemode,
            eventName,
            message,
            event.Weekday,
            event.HourOfDay);

        g_PluginStatsInflight.PushArray(event);
        sentCount++;
    }

    if (sentCount <= 0)
    {
        PluginStats_RustClearInflight();
        return false;
    }

    pos += FormatEx(out[pos], sizeof(out) - pos, "]}\n");
    g_PluginStatsRustSocket.Send(out, pos);
    g_PluginStatsRustSocket.SetSendqueueEmptyCallback(PluginStats_RustOnSocketSendqueueEmpty);
    g_PluginStatsRustAwaitingAck = true;
    g_PluginStatsRustPendingBatchId = batchId;

    for (int i = 0; i < sentCount; i++)
    {
        g_PluginStatsQueue.Erase(0);
    }

    if (PluginStats_RustDebugEnabled())
    {
        LogMessage("[plugin_statistics] sent Rust stats batch table=%s id=%d rows=%d bytes=%d remaining=%d", g_PluginStatsTable, batchId, sentCount, pos, g_PluginStatsQueue.Length);
    }

    return true;
}

public void PluginStats_RustOnSocketConnected(Socket socket, any arg)
{
    g_PluginStatsRustConnecting = false;
    g_PluginStatsRustConnected = true;
    g_PluginStatsRustAwaitingAck = false;
    g_PluginStatsRustRecvBufferLen = 0;
    g_PluginStatsRustRecvBuffer[0] = '\0';

    char serverId[128], escapedServerId[256], authToken[256], escapedAuthToken[512], authJson[640], hello[1024];
    PluginStats_RustBuildServerId(serverId, sizeof(serverId));
    PluginStats_RustJsonEscape(serverId, escapedServerId, sizeof(escapedServerId));
    authJson[0] = '\0';
    if (g_PluginStatsRustAuthToken != null)
    {
        g_PluginStatsRustAuthToken.GetString(authToken, sizeof(authToken));
        TrimString(authToken);
        if (authToken[0] != '\0')
        {
            PluginStats_RustJsonEscape(authToken, escapedAuthToken, sizeof(escapedAuthToken));
            FormatEx(authJson, sizeof(authJson), ",\"auth\":\"%s\"", escapedAuthToken);
        }
    }

    int len = FormatEx(hello, sizeof(hello), "{\"type\":\"hello\",\"service\":\"kogasa_plugin_statistics\",\"proto\":1,\"server_id\":\"%s\",\"ts\":%d%s}\n", escapedServerId, GetTime(), authJson);
    socket.Send(hello, len);
    socket.SetSendqueueEmptyCallback(PluginStats_RustOnSocketSendqueueEmpty);

    if (PluginStats_RustDebugEnabled())
    {
        LogMessage("[plugin_statistics] connected %s to kogasa-statistics-rust", g_PluginStatsTable);
    }

    PluginStats_RustFlushBatch();
}

public void PluginStats_RustOnSocketDisconnected(Socket socket, any arg)
{
    if (PluginStats_RustDebugEnabled())
    {
        LogMessage("[plugin_statistics] Rust statistics socket disconnected for %s", g_PluginStatsTable);
    }

    PluginStats_RustRequeueInflight();
    PluginStats_RustDisconnectSocket();
    if (PluginStats_RustFallbackSqlEnabled())
    {
        PluginStats_FlushLocal();
    }
    PluginStats_RustScheduleReconnect();
}

public void PluginStats_RustOnSocketError(Socket socket, const int errorType, const int errorNum, any arg)
{
    LogError("[plugin_statistics] Rust statistics socket error for %s type=%d errno=%d", g_PluginStatsTable, errorType, errorNum);
    PluginStats_RustRequeueInflight();
    PluginStats_RustDisconnectSocket();
    if (PluginStats_RustFallbackSqlEnabled())
    {
        PluginStats_FlushLocal();
    }
    PluginStats_RustScheduleReconnect();
}

public void PluginStats_RustOnSocketSendqueueEmpty(Socket socket, any arg) {}

public void PluginStats_RustOnSocketReceive(Socket socket, const char[] receiveData, const int dataSize, any arg)
{
    if (dataSize <= 0)
    {
        return;
    }

    if (g_PluginStatsRustRecvBufferLen + dataSize >= sizeof(g_PluginStatsRustRecvBuffer))
    {
        LogError("[plugin_statistics] Rust statistics receive buffer overflow for %s", g_PluginStatsTable);
        g_PluginStatsRustRecvBufferLen = 0;
        g_PluginStatsRustRecvBuffer[0] = '\0';
        return;
    }

    for (int i = 0; i < dataSize && g_PluginStatsRustRecvBufferLen < sizeof(g_PluginStatsRustRecvBuffer) - 1; i++)
    {
        g_PluginStatsRustRecvBuffer[g_PluginStatsRustRecvBufferLen++] = receiveData[i];
    }
    g_PluginStatsRustRecvBuffer[g_PluginStatsRustRecvBufferLen] = '\0';
    PluginStats_RustParseIncomingLines();
}

stock void PluginStats_RustParseIncomingLines()
{
    int start = 0;
    for (int i = 0; i < g_PluginStatsRustRecvBufferLen; i++)
    {
        if (g_PluginStatsRustRecvBuffer[i] != '\n')
        {
            continue;
        }

        int lineLen = i - start;
        if (lineLen > 0)
        {
            char line[PLUGIN_STATS_RUST_MAX_LINE];
            if (lineLen >= sizeof(line))
            {
                lineLen = sizeof(line) - 1;
            }
            for (int j = 0; j < lineLen; j++)
            {
                line[j] = g_PluginStatsRustRecvBuffer[start + j];
            }
            line[lineLen] = '\0';
            PluginStats_RustHandleBackendLine(line);
        }
        start = i + 1;
    }

    if (start > 0)
    {
        int remaining = g_PluginStatsRustRecvBufferLen - start;
        for (int k = 0; k < remaining; k++)
        {
            g_PluginStatsRustRecvBuffer[k] = g_PluginStatsRustRecvBuffer[start + k];
        }
        g_PluginStatsRustRecvBufferLen = remaining;
        g_PluginStatsRustRecvBuffer[g_PluginStatsRustRecvBufferLen] = '\0';
    }
}

stock void PluginStats_RustHandleBackendLine(const char[] line)
{
    if (line[0] == '\0')
    {
        return;
    }

    if (PluginStats_RustDebugEnabled())
    {
        LogMessage("[plugin_statistics] Rust statistics recv for %s: %s", g_PluginStatsTable, line);
    }

    if (StrContains(line, "\"type\":\"ack\"") != -1)
    {
        int ackBatchId;
        if (!PluginStats_RustExtractJsonInt(line, "\"batch_id\":", ackBatchId))
        {
            PluginStats_RustHandleFailedInflight("Rust statistics ACK missing batch_id", line);
            return;
        }

        if (ackBatchId != g_PluginStatsRustPendingBatchId)
        {
            PluginStats_RustHandleFailedInflight("Rust statistics ACK batch mismatch", line);
            return;
        }

        int dbErrors = 0;
        if (PluginStats_RustExtractJsonInt(line, "\"db_errors\":", dbErrors) && dbErrors > 0)
        {
            PluginStats_RustHandleFailedInflight("Rust statistics ACK reported DB errors", line);
            return;
        }

        g_PluginStatsRustAwaitingAck = false;
        PluginStats_RustClearInflight();
        PluginStats_RustFlushBatch();
        return;
    }

    if (StrContains(line, "\"type\":\"error\"") != -1)
    {
        PluginStats_RustHandleFailedInflight("Rust statistics backend error", line);
        return;
    }
}

stock void PluginStats_GetMapSessionId(char[] output, int maxlen)
{
    int startedAt = g_PluginStatsMapStartedAt;
    if (startedAt <= 0)
    {
        startedAt = GetTime();
    }
    Format(output, maxlen, "%d-%d", ServerContext_GetHostPort(), startedAt);
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
    if (strncmp(message[start], "Skip balance", 12, false) == 0)
    {
        strcopy(output, maxlen, "balance_skipped");
        return true;
    }

    return false;
}
