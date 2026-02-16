#include <sourcemod>
#include <geoip>

#define PLUGIN_VERSION "1.4"

#define ADMIN_LOG_PATH "logs/connections/admin"
#define PLAYER_LOG_PATH "logs/connections/player"

#pragma semicolon 1

char admin_filepath[PLATFORM_MAX_PATH];
char player_filepath[PLATFORM_MAX_PATH];
char g_sFilePath2[PLATFORM_MAX_PATH];
Handle g_hVisibleMaxPlayers = INVALID_HANDLE;

enum struct PlayerStats
{
    int Killstreak;
    int Score;
    int Frags;
    int Deaths;
    int Assists;
    int Damage;
    char Team[32];
    char Class[32];
    char Time[32];
}

bool clientIsAdmin[MAXPLAYERS+1] = { false, ... };
bool clientConnected[MAXPLAYERS+1] = { false, ... };

ConVar g_cvLogSensitiveData;

public Plugin myinfo =
{
    name = "analytics",
    author = "Xander, IT-KiLLER, Dosergen, Hombre",
    description = "This plugin logs players' connect and disconnect times, capturing their Name, SteamID, IP Address and Country.",
    version = PLUGIN_VERSION,
    url = "https://forums.alliedmods.net/showthread.php?t=201967"
}

public void OnPluginStart()
{
    CreateConVar("sm_log_connections_version", PLUGIN_VERSION, "Log Connections version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    
    // Create the sensitive data logging ConVar to disable these features
    g_cvLogSensitiveData = CreateConVar("sm_log_sensitive_data", "0", "Log sensitive data (IP and country). 0 = Disabled, 1 = Enabled", FCVAR_NOTIFY);

    // Initialize paths
    InitializeLogPath(admin_filepath, sizeof(admin_filepath), ADMIN_LOG_PATH);
    InitializeLogPath(player_filepath, sizeof(player_filepath), PLAYER_LOG_PATH);
    
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    
    // Initialize clients
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            clientConnected[client] = true;
            clientIsAdmin[client] = IsPlayerAdmin(client);
        }
    }
}

public void OnAllPluginsLoaded()
{
    CreateTimer(5.0, UpdateQuickStats, _, TIMER_REPEAT);
}

public Action UpdateQuickStats(Handle timer)
{
    char serverPort[10];
    Handle cvarPort = FindConVar("hostport");
    GetConVarString(cvarPort, serverPort, sizeof(serverPort));
    CloseHandle(cvarPort);

    char hostname[100];
    Handle cvarHost = FindConVar("hostname");
    GetConVarString(cvarHost, hostname, sizeof(hostname));
    CloseHandle(cvarHost);

    char mapName[100];
    GetCurrentMap(mapName, sizeof(mapName));
    ReplaceStringEx(mapName, sizeof(mapName), "workshop/", "");
    SplitString(mapName, ".", mapName, sizeof(mapName));

    int playerLimit = GetMaxPlayers();
    int playerCount = GetClientCount(false);

    char filename[64];
    Format(filename, sizeof(filename), StrEqual(serverPort, "27015") ? "quickstats.txt" : "server%s_quickstats.txt", serverPort);
    BuildPath(Path_SM, g_sFilePath2, sizeof(g_sFilePath2), "/logs/connections/%s", filename);

    char fileContent[8192];
    int pos = 0;
    pos += Format(fileContent[pos], sizeof(fileContent)-pos,
        "Hostname:%s\nPort:%s\nPlayer Count:%d/%d\nMap Name:%s\n",
        hostname, serverPort, playerCount, playerLimit, mapName
    );

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client)) continue;

        PlayerStats stats;
        if (IsClientInGame(client))
        {
            stats.Killstreak = GetEntProp(client, Prop_Send, "m_nStreaks");
            stats.Score     = GetEntProp(client, Prop_Send, "m_iPoints");
            stats.Frags     = GetClientFrags(client);
            stats.Deaths    = GetClientDeaths(client);
            stats.Assists   = GetEntProp(client, Prop_Send, "m_iKillAssists");
            stats.Damage    = GetEntProp(client, Prop_Send, "m_iDamageDone");

            int team = GetClientTeam(client);
            if (team == 2)
                strcopy(stats.Team, sizeof(stats.Team), "RedTeam");
            else if (team == 3)
                strcopy(stats.Team, sizeof(stats.Team), "BlueTeam");
            else
                strcopy(stats.Team, sizeof(stats.Team), "SpectatorTeam");

            if (IsPlayerAlive(client))
            {
                int classId = GetEntProp(client, Prop_Send, "m_iClass");
                Format(stats.Class, sizeof(stats.Class), "Class%d", classId);
            }
            else
            {
                strcopy(stats.Class, sizeof(stats.Class), "Respawning");
            }

            if (!IsFakeClient(client))
            {
                char timeStr[32];
                GetFormattedTime(RoundToCeil(GetClientTime(client)), timeStr, sizeof(timeStr));
                strcopy(stats.Time, sizeof(stats.Time), timeStr);
            }
            else
            {
                Format(stats.Time, sizeof(stats.Time), "BOT");
            }
        }
        else
        {
            strcopy(stats.Class, sizeof(stats.Class), "Respawning");
            strcopy(stats.Team, sizeof(stats.Team), "SpectatorTeam");
            Format(stats.Time, sizeof(stats.Time), "00:00:00");
            stats.Killstreak = 0;
            stats.Score = 0;
            stats.Frags = 0;
            stats.Deaths = 0;
            stats.Assists = 0;
            stats.Damage = 0;
        }

        char playerName[64];
        GetClientName(client, playerName, sizeof(playerName));

        pos += Format(fileContent[pos], sizeof(fileContent)-pos,
            "Player %d: %s[X]%s[X]%d[X]%d[X]%d[X]%d[X]%d[X]%d[X]%s[X]%s\n",
            client, playerName, stats.Class,
            stats.Killstreak, stats.Score, stats.Frags,
            stats.Deaths, stats.Assists, stats.Damage,
            stats.Team, stats.Time
        );
    }

    File file = OpenFile(g_sFilePath2, "w");
    if (file != null)
    {
        WriteFileString(file, fileContent, false);
        delete file;
    }
    else LogError("Failed to open quickstats file: %s", g_sFilePath2);

    return Plugin_Continue;
}

// Helper: Get formatted time string
void GetFormattedTime(int seconds, char[] buffer, int maxLen)
{
    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    int secs = seconds % 60;
    Format(buffer, maxLen, "%02d:%02d:%02d", hours, minutes, secs);
}

// Helper: Get maximum visible players
int GetMaxPlayers()
{
    g_hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    int visMax = GetConVarInt(g_hVisibleMaxPlayers);
    if (visMax > 0) return visMax;
    return 32;
}

void InitializeLogPath(char[] filepath, int maxlen, const char[] path)
{
	BuildPath(Path_SM, filepath, maxlen, path);
	if (!DirExists(filepath))
	{
		CreateDirectory(filepath, 511, true);
		if (!DirExists(filepath))
			LogMessage("Failed to create directory at %s - Please manually create that path and reload this plugin.", path);
	}
}

public void OnMapStart()
{
	char formatedDate[100];
	char mapName[100];
	int currentTime = GetTime();
	GetCurrentMap(mapName, sizeof(mapName));
	FormatTime(formatedDate, sizeof(formatedDate), "%d_%b_%Y", currentTime); 
	// Update log paths
	FormatLogPath(admin_filepath, sizeof(admin_filepath), ADMIN_LOG_PATH, formatedDate, "admin");
	FormatLogPath(player_filepath, sizeof(player_filepath), PLAYER_LOG_PATH, formatedDate, "player");
	LogMapChange(admin_filepath, mapName);
	LogMapChange(player_filepath, mapName);
}

void FormatLogPath(char[] filepath, int maxlen, const char[] logPath, const char[] date, const char[] type)
{
	BuildPath(Path_SM, filepath, maxlen, "%s/%s_%s.log", logPath, date, type);
}

void LogMapChange(const char[] filepath, const char[] mapName)
{
	char formatedTime[64];
	FormatTime(formatedTime, sizeof(formatedTime), "%H:%M:%S", GetTime());
	File logFile = OpenFile(filepath, "a+");
	if (logFile == null)
	{
		LogError("Could not open log file: %s", filepath);
		return;
	}
	logFile.WriteLine("");
	logFile.WriteLine("%s - ===== Map change to %s =====", formatedTime, mapName);
	logFile.WriteLine("");
	delete logFile;
}

public void OnRebuildAdminCache(AdminCachePart part)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			clientIsAdmin[client] = IsPlayerAdmin(client);
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (!client || IsFakeClient(client))
		return;
	if (clientConnected[client])
		return;
	clientConnected[client] = true;
	clientIsAdmin[client] = IsPlayerAdmin(client);
	LogClientAction(client, true);
}

public void Event_PlayerDisconnect(Event event, char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || IsFakeClient(client))
		return;
	if (!clientConnected[client])
		return;
	clientConnected[client] = false;
	LogClientAction(client, false, event);
	clientIsAdmin[client] = false;
}

void LogClientAction(int client, bool isConnecting, Event event = null)
{
    char playerName[64], authId[64], ipAddress[64] = "Hidden", country[64] = "Hidden", formatedTime[64];
    GetClientName(client, playerName, sizeof(playerName));
    if (!GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId), false))
        strcopy(authId, sizeof(authId), "Unknown");

    // Only log IP and country if the ConVar is enabled
    if (g_cvLogSensitiveData.BoolValue)
    {
        if (!GetClientIP(client, ipAddress, sizeof(ipAddress)))
            strcopy(ipAddress, sizeof(ipAddress), "Unknown");
        if (!GeoipCountry(ipAddress, country, sizeof(country)))
            strcopy(country, sizeof(country), "Unknown");
    }

    FormatTime(formatedTime, sizeof(formatedTime), "%H:%M:%S", GetTime());
    char logFilePath[PLATFORM_MAX_PATH];
    strcopy(logFilePath, sizeof(logFilePath), clientIsAdmin[client] ? admin_filepath : player_filepath);
    File logFile = OpenFile(logFilePath, "a+");
    if (logFile == null)
    {
        LogError("Could not open log file: %s", logFilePath);
        return;
    }
    if (isConnecting)
        logFile.WriteLine("%s - <%s> <%s> <%s> CONNECTED from <%s>", formatedTime, playerName, authId, ipAddress, country);
    else
    {
        int connectionTime = RoundToCeil(GetClientTime(client) / 60);
        char reason[128] = "Unknown";
        if (event != null)
            event.GetString("reason", reason, sizeof(reason));
        logFile.WriteLine("%s - <%s> <%s> <%s> DISCONNECTED after %d minutes. <%s>", formatedTime, playerName, authId, ipAddress, connectionTime, reason);
    }
    delete logFile;
}

bool IsPlayerAdmin(int client)
{
	return CheckCommandAccess(client, "Generic_admin", ADMFLAG_GENERIC, false);
}

public void ConvertSecondsToTime(int seconds, char[] result, int maxLength)
{
    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    int remainingSeconds = seconds % 60;

    Format(result, maxLength, "%02d:%02d:%02d", hours, minutes, remainingSeconds);
}
