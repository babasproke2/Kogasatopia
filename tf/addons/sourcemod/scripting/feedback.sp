#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include "include/database.inc"

#define FEEDBACK_DB_CONFIG "default"
#define FEEDBACK_TABLE "whaletracker_feedback"
#define FEEDBACK_MAX_MESSAGE 512

Database g_hDatabase = null;
bool g_bDatabaseReady = false;
Handle g_hReconnectTimer = null;

public Plugin myinfo =
{
    name = "Feedback",
    author = "Hombre",
    description = "Stores !feedback in a database",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_feedback", Command_Feedback, "Submit feedback to server admins");
    ConnectToDatabase();
}

public void OnPluginEnd()
{
    Db_CancelTimer(g_hReconnectTimer);
    Db_Close(g_hDatabase, g_bDatabaseReady);
}

void ConnectToDatabase()
{
    Db_CancelTimer(g_hReconnectTimer);
    Db_Close(g_hDatabase, g_bDatabaseReady);

    if (!Db_CheckConfigOrLog("Feedback", FEEDBACK_DB_CONFIG))
    {
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, FEEDBACK_DB_CONFIG);
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    g_hReconnectTimer = null;
    ConnectToDatabase();
    return Plugin_Stop;
}

void ScheduleDatabaseReconnect(float delay = DB_RECONNECT_DELAY)
{
    g_bDatabaseReady = false;
    if (g_hReconnectTimer == null)
    {
        g_hReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase);
    }
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[Feedback] Database connect failed: %s", error[0] ? error : "unknown error");
        ScheduleDatabaseReconnect();
        return;
    }

    g_hDatabase = view_as<Database>(hndl);
    g_bDatabaseReady = true;
    Db_CancelTimer(g_hReconnectTimer);
    EnsureFeedbackTable();
}

void EnsureFeedbackTable()
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        return;
    }

    char query[512];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS %s ("
        ... "id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, "
        ... "player_name VARCHAR(64) NOT NULL, "
        ... "message TEXT NOT NULL, "
        ... "created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP"
        ... ")",
        FEEDBACK_TABLE);

    SQL_TQuery(g_hDatabase, SQL_OnSchemaOpComplete, query);
}

public void SQL_OnSchemaOpComplete(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Feedback] Failed to ensure table: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
    }
}

// -------------------------------------------------------------------------
// Admin feedback browser
// -------------------------------------------------------------------------

// We pack (client userid << 16 | page) into the data int passed to the query
// so we can open the right page for the right client when results come back.

#define FEEDBACK_PAGE_SIZE 5

void OpenFeedbackBrowser(int client, int page)
{
    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        PrintToChat(client, "[Kogasa] Feedback database is unavailable right now.");
        return;
    }

    int offset = page * FEEDBACK_PAGE_SIZE;

    char query[256];
    Format(query, sizeof(query),
        "SELECT player_name, message, created_at FROM %s ORDER BY id DESC LIMIT %d OFFSET %d",
        FEEDBACK_TABLE, FEEDBACK_PAGE_SIZE + 1, offset);  // fetch one extra to detect next page

    any data = (GetClientUserId(client) << 16) | (page & 0xFFFF);
    SQL_TQuery(g_hDatabase, SQL_OnFeedbackBrowse, query, data);
}

public void SQL_OnFeedbackBrowse(Database db, DBResultSet results, const char[] error, any data)
{
    int userid = (data >> 16) & 0xFFFF;
    int page   = data & 0xFFFF;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Feedback] Failed to fetch feedback: %s", error);
        if (Db_IsTransientError(error))
        {
            ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
        }
        PrintToChat(client, "[Kogasa] Could not load feedback right now.");
        return;
    }

    Menu menu = new Menu(MenuHandler_FeedbackBrowser);
    menu.SetTitle("Feedback (page %d)", page + 1);
    menu.ExitButton = true;

    int count = 0;
    while (results.FetchRow() && count < FEEDBACK_PAGE_SIZE)
    {
        char name[64];
        char message[FEEDBACK_MAX_MESSAGE];
        char timestamp[32];
        results.FetchString(0, name, sizeof(name));
        results.FetchString(1, message, sizeof(message));
        results.FetchString(2, timestamp, sizeof(timestamp));

        // Truncate timestamp to date + time without fractional seconds
        // e.g. "2024-01-15 20:30:00"
        timestamp[19] = '\0';

        // Build display label: "PlayerName (date)"
        char label[128];
        Format(label, sizeof(label), "%s (%s)", name, timestamp);

        // Store message as item info so we can display it on select
        menu.AddItem(message, label);
        count++;
    }

    if (count == 0)
    {
        menu.AddItem("", "No feedback found.", ITEMDRAW_DISABLED);
    }

    bool hasNextPage = results.FetchRow();  // if we got the extra row, there's a next page

    // Prev / Next navigation as disabled display items at the bottom
    // We handle pagination by spawning a new query rather than using built-in
    // menu pagination, so we disable the native paginator and add our own items.
    menu.Pagination = MENU_NO_PAGINATION;

    if (page > 0)
    {
        char prevInfo[16];
        Format(prevInfo, sizeof(prevInfo), "page:%d", page - 1);
        menu.AddItem(prevInfo, "« Previous Page");
    }

    if (hasNextPage)
    {
        char nextInfo[16];
        Format(nextInfo, sizeof(nextInfo), "page:%d", page + 1);
        menu.AddItem(nextInfo, "Next Page »");
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_FeedbackBrowser(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        int client = param1;
        char info[FEEDBACK_MAX_MESSAGE];
        menu.GetItem(param2, info, sizeof(info));

        // Navigation items are prefixed with "page:"
        if (StrContains(info, "page:") == 0)
        {
            int targetPage = StringToInt(info[5]);
            OpenFeedbackBrowser(client, targetPage);
        }
        else
        {
            // Display the full message
            PrintToChat(client, "[Kogasa] Feedback: %s", info);
            menu.Display(client, MENU_TIME_FOREVER);  // re-show menu after reading
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

// -------------------------------------------------------------------------
// !feedback command
// -------------------------------------------------------------------------

public Action Command_Feedback(int client, int args)
{
    if (args < 1)
    {
        if (client > 0 && IsClientInGame(client) && CheckCommandAccess(client, "sm_feedback_view", ADMFLAG_GENERIC))
        {
            OpenFeedbackBrowser(client, 0);
        }
        else
        {
            ReplyToCommand(client, "[Kogasa] Format: !feedback message");
        }
        return Plugin_Handled;
    }

    if (!Db_IsReady(g_hDatabase, g_bDatabaseReady))
    {
        ReplyToCommand(client, "[Kogasa] Feedback database is unavailable right now.");
        return Plugin_Handled;
    }

    char message[FEEDBACK_MAX_MESSAGE];
    GetCmdArgString(message, sizeof(message));
    TrimString(message);
    StripQuotes(message);
    TrimString(message);

    if (message[0] == '\0')
    {
        ReplyToCommand(client, "[Kogasa] Format: !feedback message");
        return Plugin_Handled;
    }

    char name[MAX_NAME_LENGTH];
    if (client > 0 && IsClientInGame(client))
    {
        GetClientName(client, name, sizeof(name));
        TrimString(name);
        if (name[0] == '\0')
        {
            strcopy(name, sizeof(name), "unknown");
        }
    }
    else
    {
        strcopy(name, sizeof(name), "console");
    }

    char escapedName[(MAX_NAME_LENGTH * 2) + 1];
    char escapedMessage[(FEEDBACK_MAX_MESSAGE * 2) + 1];
    Db_Escape(g_hDatabase, name, escapedName, sizeof(escapedName), "Feedback");
    Db_Escape(g_hDatabase, message, escapedMessage, sizeof(escapedMessage), "Feedback");

    char query[2048];
    Format(query, sizeof(query),
        "INSERT INTO %s (player_name, message, created_at) VALUES ('%s', '%s', NOW())",
        FEEDBACK_TABLE,
        escapedName,
        escapedMessage);

    SQL_TQuery(g_hDatabase, SQL_OnFeedbackInserted, query, (client > 0 && IsClientInGame(client)) ? GetClientUserId(client) : 0);
    ReplyToCommand(client, "[Kogasa] Feedback sent.");

    return Plugin_Handled;
}

public void SQL_OnFeedbackInserted(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    int client = GetClientOfUserId(data);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Kogasa] Could not save feedback right now.");
    }

    LogError("[Feedback] Failed to save feedback: %s", error);

    if (Db_IsTransientError(error))
    {
        ScheduleDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
    }
}
