#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clans_api>

#define PLUGIN_NAME "Tags"
#define PLUGIN_AUTHOR "Codex"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_URL "https://kogasa.tf"

#define TAG_VALUE_MAXLEN 128
#define TAG_JOINED_MAXLEN 4096
#define TAG_STEAMID64_MAXLEN 32
#define TAG_SQL_STEAMID64_MAXLEN ((TAG_STEAMID64_MAXLEN * 2) + 1)
#define TAG_SQL_VALUE_MAXLEN ((TAG_VALUE_MAXLEN * 2) + 1)

native bool CustomHats_GetPrefix(int client, char[] buffer, int maxlen);

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "Tag selection menu and storage.",
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

Database g_Database = null;
bool g_bDatabaseReady = false;
ConVar g_cvDatabaseConfig = null;

char g_SelectedTags[MAXPLAYERS + 1][TAG_VALUE_MAXLEN];
bool g_bTagLoaded[MAXPLAYERS + 1];
bool g_bTagLoadPending[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("tags");
    CreateNative("Tags_GetTag", Native_Tags_GetTag);
    CreateNative("Tags_GetSelectedTag", Native_Tags_GetSelectedTag);
    CreateNative("Tags_SetSelectedTag", Native_Tags_SetSelectedTag);
    MarkNativeAsOptional("CustomHats_GetPrefix");
    MarkNativeAsOptional("Clans_GetTags");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvDatabaseConfig = CreateConVar("sm_tags_database", "default", "Database config name from databases.cfg to use for tags.");
    AutoExecConfig(true, "tags");

    RegConsoleCmd("sm_tag", Command_TagMenu, "Open the chat tag selection menu.");
    RegConsoleCmd("sm_tags", Command_TagMenu, "Open the chat tag selection menu.");

    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClientTagState(client);
    }

    ConnectDatabase();
}

public void OnPluginEnd()
{
    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }
}

public void OnClientPostAdminCheck(int client)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client))
    {
        return;
    }

    if (g_bDatabaseReady)
    {
        LoadClientSelectedTag(client);
    }
}

public void OnClientDisconnect(int client)
{
    ResetClientTagState(client);
}

void ResetClientTagState(int client)
{
    g_SelectedTags[client][0] = '\0';
    g_bTagLoaded[client] = false;
    g_bTagLoadPending[client] = false;
}

void ConnectDatabase()
{
    char configName[64];
    g_cvDatabaseConfig.GetString(configName, sizeof(configName));
    Database.Connect(SQL_OnDatabaseConnected, configName);
}

public void SQL_OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[Tags] Database connection failed: %s", error);
        return;
    }

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    g_Database = db;
    g_bDatabaseReady = false;

    if (!g_Database.SetCharset("utf8mb4"))
    {
        LogError("[Tags] Failed to set utf8mb4 charset");
    }

    char query[384];
    FormatEx(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS tags_selected ("
        ... "steamid64 VARCHAR(32) PRIMARY KEY, "
        ... "tag VARCHAR(128) NOT NULL DEFAULT '', "
        ... "updated_at INT NOT NULL DEFAULT 0)");
    g_Database.Query(SQL_OnSchemaCreated, query);
}

public void SQL_OnSchemaCreated(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Tags] Schema creation failed: %s", error);
        return;
    }

    g_bDatabaseReady = true;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        LoadClientSelectedTag(client);
    }
}

bool EnsureDatabaseReady(int client = 0)
{
    if (g_Database != null && g_bDatabaseReady)
    {
        return true;
    }

    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        PrintToChat(client, "[Tags] Database is not ready yet. Please try again in a moment.");
    }

    return false;
}

bool GetClientSteam64(int client, char[] steamid64, int maxlen)
{
    steamid64[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    return GetClientAuthId(client, AuthId_SteamID64, steamid64, maxlen, true);
}

void EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';

    if (g_Database == null)
    {
        strcopy(output, maxlen, input);
        return;
    }

    int written = 0;
    if (!g_Database.Escape(input, output, maxlen, written))
    {
        LogError("[Tags] Failed to escape SQL string of length %d.", strlen(input));
        strcopy(output, maxlen, input);
    }
}

void LoadClientSelectedTag(int client)
{
    if (client <= 0 || client > MaxClients || g_bTagLoadPending[client])
    {
        return;
    }

    g_SelectedTags[client][0] = '\0';
    g_bTagLoaded[client] = false;

    if (!EnsureDatabaseReady() || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamid64[TAG_STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        return;
    }

    char escapedSteam[TAG_SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT tag FROM tags_selected WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);
    g_bTagLoadPending[client] = true;
    g_Database.Query(SQL_OnClientTagLoaded, query, GetClientUserId(client));
}

public void SQL_OnClientTagLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    g_bTagLoadPending[client] = false;
    g_SelectedTags[client][0] = '\0';
    g_bTagLoaded[client] = true;

    if (error[0] != '\0')
    {
        LogError("[Tags] Failed to load selected tag: %s", error);
        return;
    }

    if (results == null || !results.FetchRow())
    {
        return;
    }

    results.FetchString(0, g_SelectedTags[client], sizeof(g_SelectedTags[]));
    TrimString(g_SelectedTags[client]);
}

void SaveClientSelectedTag(int client)
{
    if (!EnsureDatabaseReady() || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char steamid64[TAG_STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        return;
    }

    char escapedSteam[TAG_SQL_STEAMID64_MAXLEN];
    char escapedTag[TAG_SQL_VALUE_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(g_SelectedTags[client], escapedTag, sizeof(escapedTag));

    char query[512];
    FormatEx(query, sizeof(query),
        "REPLACE INTO tags_selected (steamid64, tag, updated_at) VALUES ('%s', '%s', %d)",
        escapedSteam,
        escapedTag,
        GetTime());
    g_Database.Query(SQL_OnSaveCompleted, query);
}

public void SQL_OnSaveCompleted(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Tags] Failed to save selected tag: %s", error);
    }
}

static void AddUniqueTag(ArrayList tags, const char[] tag)
{
    char cleaned[TAG_VALUE_MAXLEN];
    strcopy(cleaned, sizeof(cleaned), tag);
    TrimString(cleaned);

    if (!cleaned[0])
    {
        return;
    }

    char existing[TAG_VALUE_MAXLEN];
    for (int i = 0; i < tags.Length; i++)
    {
        tags.GetString(i, existing, sizeof(existing));
        if (StrEqual(existing, cleaned, false))
        {
            return;
        }
    }

    tags.PushString(cleaned);
}

static void AddJoinedTags(ArrayList tags, const char[] joined)
{
    char current[TAG_VALUE_MAXLEN];
    int currentIndex = 0;

    for (int i = 0;; i++)
    {
        char ch = joined[i];
        if (ch == '|' || ch == '\0')
        {
            current[currentIndex] = '\0';
            AddUniqueTag(tags, current);
            currentIndex = 0;

            if (ch == '\0')
            {
                break;
            }

            continue;
        }

        if (currentIndex >= sizeof(current) - 1)
        {
            continue;
        }

        current[currentIndex++] = ch;
    }
}

static bool CollectAvailableClientTags(int client, ArrayList tags)
{
    char joined[TAG_JOINED_MAXLEN];

    if (GetFeatureStatus(FeatureType_Native, "CustomHats_GetPrefix") == FeatureStatus_Available)
    {
        joined[0] = '\0';
        if (CustomHats_GetPrefix(client, joined, sizeof(joined)) && joined[0])
        {
            AddJoinedTags(tags, joined);
        }
    }

    if (GetFeatureStatus(FeatureType_Native, "Clans_GetTags") == FeatureStatus_Available)
    {
        joined[0] = '\0';
        if (Clans_GetTags(client, joined, sizeof(joined)) && joined[0])
        {
            AddJoinedTags(tags, joined);
        }
    }

    return tags.Length > 0;
}

static bool QueryStoredTagBySteam64(const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!steamid64[0] || !EnsureDatabaseReady())
    {
        return false;
    }

    char escapedSteam[TAG_SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT tag FROM tags_selected WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DBResultSet results = SQL_Query(g_Database, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Tags] Failed to query stored tag for %s: %s", steamid64, error);
        return false;
    }

    bool found = false;
    if (results.FetchRow())
    {
        results.FetchString(0, buffer, maxlen);
        TrimString(buffer);
        found = (buffer[0] != '\0');
    }

    delete results;
    return found;
}

static void RequestClientTagLoadIfNeeded(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || g_bTagLoaded[client])
    {
        return;
    }

    if (g_bTagLoadPending[client] || !EnsureDatabaseReady())
    {
        return;
    }

    LoadClientSelectedTag(client);
}

static bool GetResolvedClientTag(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    RequestClientTagLoadIfNeeded(client);
    if (!g_bTagLoaded[client] || !g_SelectedTags[client][0])
    {
        return false;
    }

    ArrayList tags = new ArrayList(ByteCountToCells(TAG_VALUE_MAXLEN));
    CollectAvailableClientTags(client, tags);

    char available[TAG_VALUE_MAXLEN];
    bool found = false;
    for (int i = 0; i < tags.Length; i++)
    {
        tags.GetString(i, available, sizeof(available));
        if (!StrEqual(available, g_SelectedTags[client], false))
        {
            continue;
        }

        strcopy(buffer, maxlen, available);
        found = true;
        break;
    }

    delete tags;
    return found;
}

void SetClientSelectedTag(int client, const char[] tag)
{
    strcopy(g_SelectedTags[client], sizeof(g_SelectedTags[]), tag);
    g_bTagLoaded[client] = true;
    SaveClientSelectedTag(client);
}

void ClearClientSelectedTag(int client)
{
    g_SelectedTags[client][0] = '\0';
    g_bTagLoaded[client] = true;
    SaveClientSelectedTag(client);
}

public Action Command_TagMenu(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        ReplyToCommand(client, "[Tags] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    ArrayList tags = new ArrayList(ByteCountToCells(TAG_VALUE_MAXLEN));
    CollectAvailableClientTags(client, tags);

    Menu menu = new Menu(MenuHandler_TagMenu);
    menu.SetTitle("Select Chat Tag");

    char tag[TAG_VALUE_MAXLEN];
    for (int i = 0; i < tags.Length; i++)
    {
        tags.GetString(i, tag, sizeof(tag));
        menu.AddItem(tag, tag);
    }

    if (tags.Length == 0)
    {
        menu.AddItem("action:unavailable", "No tags available", ITEMDRAW_DISABLED);
    }

    menu.AddItem("action:clear", "Clear Tag");
    menu.Display(client, MENU_TIME_FOREVER);

    delete tags;
    return Plugin_Handled;
}

public int MenuHandler_TagMenu(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
    {
        return 0;
    }

    int client = param1;
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return 0;
    }

    char selectedTag[TAG_VALUE_MAXLEN];
    menu.GetItem(param2, selectedTag, sizeof(selectedTag));

    if (StrEqual(selectedTag, "action:clear", false))
    {
        ClearClientSelectedTag(client);
        PrintToChat(client, "[Tags] Your chat tag has been cleared.");
        return 0;
    }

    if (StrEqual(selectedTag, "action:unavailable", false))
    {
        return 0;
    }

    ArrayList tags = new ArrayList(ByteCountToCells(TAG_VALUE_MAXLEN));
    CollectAvailableClientTags(client, tags);

    char availableTag[TAG_VALUE_MAXLEN];
    bool found = false;
    for (int i = 0; i < tags.Length; i++)
    {
        tags.GetString(i, availableTag, sizeof(availableTag));
        if (StrEqual(availableTag, selectedTag, false))
        {
            found = true;
            break;
        }
    }

    delete tags;

    if (!found)
    {
        PrintToChat(client, "[Tags] That tag is no longer available.");
        return 0;
    }

    SetClientSelectedTag(client, selectedTag);
    PrintToChat(client, "[Tags] Your chat tag is now %s.", selectedTag);
    return 0;
}

public any Native_Tags_GetTag(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int maxlen = GetNativeCell(4);

    char steamid64[TAG_STEAMID64_MAXLEN];
    char buffer[TAG_VALUE_MAXLEN];
    steamid64[0] = '\0';
    buffer[0] = '\0';

    GetNativeString(2, steamid64, sizeof(steamid64));

    bool found = false;
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
    {
        found = GetResolvedClientTag(client, buffer, sizeof(buffer));
    }
    else if (steamid64[0])
    {
        found = QueryStoredTagBySteam64(steamid64, buffer, sizeof(buffer));
    }

    SetNativeString(3, buffer, maxlen, true);
    return found;
}

public any Native_Tags_GetSelectedTag(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int maxlen = GetNativeCell(3);

    char buffer[TAG_VALUE_MAXLEN];
    buffer[0] = '\0';

    bool found = false;
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
    {
        found = GetResolvedClientTag(client, buffer, sizeof(buffer));
    }

    SetNativeString(2, buffer, maxlen, true);
    return found;
}

public any Native_Tags_SetSelectedTag(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);

    char tag[TAG_VALUE_MAXLEN];
    tag[0] = '\0';
    GetNativeString(2, tag, sizeof(tag));
    TrimString(tag);

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || !tag[0])
    {
        return false;
    }

    SetClientSelectedTag(client, tag);
    return true;
}
