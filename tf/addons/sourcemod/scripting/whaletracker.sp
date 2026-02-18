#pragma semicolon 1

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <morecolors>
#include <SteamWorks>
#include <geoip>
#include <adt_array>
#include <datapack>
#include <adt_trie>
#pragma newdecls required

#define STEAMID64_LEN 32
#define MENU_TITLE "Whale Tracker Stats"
#define DB_CONFIG_DEFAULT "default"
#define SAVE_QUERY_MAXLEN 4096
#define MAX_CONCURRENT_SAVE_QUERIES 4
#define WHALE_POINTS_SQL_EXPR "CEIL((((GREATEST(damage_dealt,0) / 200.0) + (GREATEST(healing,0) / 400.0) + GREATEST(kills,0) + FLOOR(GREATEST(assists,0) * 0.5) + GREATEST(backstabs,0) + GREATEST(headshots,0)) * 10000.0) / GREATEST(GREATEST(deaths,0), 1))"
#define WHALE_POINTS_MIN_KD_SUM 1000
#define WHALE_LEADERBOARD_PAGE_SIZE 10

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("whaletracker");
    CreateNative("WhaleTracker_GetCumulativeKills", Native_WhaleTracker_GetCumulativeKills);
    CreateNative("WhaleTracker_AreStatsLoaded", Native_WhaleTracker_AreStatsLoaded);
    CreateNative("WhaleTracker_GetWhalePoints", Native_WhaleTracker_GetWhalePoints);
    return APLRes_Success;
}

enum
{
    CLASS_UNKNOWN = TFClass_Unknown,
    CLASS_SCOUT = TFClass_Scout,
    CLASS_SNIPER = TFClass_Sniper,
    CLASS_SOLDIER = TFClass_Soldier,
    CLASS_DEMOMAN = TFClass_DemoMan,
    CLASS_MEDIC = TFClass_Medic,
    CLASS_HEAVY = TFClass_Heavy,
    CLASS_PYRO = TFClass_Pyro,
    CLASS_SPY = TFClass_Spy,
    CLASS_ENGINEER = TFClass_Engineer,
    CLASS_MIN = CLASS_SCOUT,
    CLASS_MAX = CLASS_ENGINEER,
    CLASS_COUNT = CLASS_MAX + 1
};

enum WeaponCategory
{
    WeaponCategory_None = 0,
    WeaponCategory_Shotguns = 1,
    WeaponCategory_Scatterguns,
    WeaponCategory_Pistols,
    WeaponCategory_RocketLaunchers,
    WeaponCategory_GrenadeLaunchers,
    WeaponCategory_StickyLaunchers,
    WeaponCategory_Snipers,
    WeaponCategory_Revolvers,
    WeaponCategory_Count = WeaponCategory_Revolvers
};
#define WEAPON_CATEGORY_COUNT 8

public Action OnPlayerTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom);

enum struct WhaleStats
{
    bool loaded;
    char steamId[STEAMID64_LEN];
    char firstSeen[32];
    int firstSeenTimestamp;

    int kills;
    int deaths;
    int totalHealing;
    int totalUbers;
    int totalMedicDrops;
    int totalAirshots;
    int totalHeadshots;
    int totalBackstabs;
    int totalAssists;
    int totalDamage;
    int totalDamageTaken;
    int totalUberDrops;
    int weaponShots[WEAPON_CATEGORY_COUNT + 1];
    int weaponHits[WEAPON_CATEGORY_COUNT + 1];
    int lastSeen;

    int bestKillstreak;
    int bestUbersLife;

    int playtime; // seconds

    // runtime counters (not persisted directly)
    int currentKillstreak;
    int currentUbersLife;

    float connectTime;


}

WhaleStats g_Stats[MAXPLAYERS + 1];
WhaleStats g_MapStats[MAXPLAYERS + 1];
int g_KillSaveCounter[MAXPLAYERS + 1];
bool g_bStatsDirty[MAXPLAYERS + 1];
Handle g_hPeriodicSaveTimer = null;
bool g_bTrackEligible[MAXPLAYERS + 1];
int g_iDamageGate[MAXPLAYERS + 1];

Database g_hDatabase = null;
ConVar g_CvarDatabase = null;
ConVar g_hVisibleMaxPlayers = null;
ConVar g_hDebugMinimalStats = null;
bool g_bDatabaseReady = false;

enum MatchStatField
{
    MatchStat_Kills = 0,
    MatchStat_Deaths,
    MatchStat_Assists,
    MatchStat_Damage,
    MatchStat_DamageTaken,
    MatchStat_Healing,
    MatchStat_Headshots,
    MatchStat_Backstabs,
    MatchStat_Ubers,
    MatchStat_Playtime,
    MatchStat_MedicDrops,
    MatchStat_UberDrops,
    MatchStat_Airshots,

    MatchStat_BestStreak,
    MatchStat_BestUbersLife,
    MatchStat_Count
};

enum
{
    MATCH_STAT_COUNT = MatchStat_Count
};

StringMap g_DisconnectedStats = null;
StringMap g_MatchNames = null;

char g_sCurrentMap[64];
char g_sCurrentLogId[64];
char g_sLastFinalizedLogId[64];
char g_sOnlineMapName[128];
char g_sHostIp[64];
char g_sPublicHostIp[64];
char g_sHostCity[64];
char g_sHostCountry[3];
char g_sHostCountryLower[3];
char g_sServerFlags[256];
int g_iHostPort = 0;
int g_iMatchStartTime = 0;
bool g_bMatchFinalized = false;

ConVar g_hGameModeCvar = null;
ConVar g_hHostIpCvar = null;
ConVar g_hHostPortCvar = null;
ConVar g_hServerFlags = null;

char g_sDatabaseConfig[64];
ArrayList g_SaveQueue = null;
int g_PendingSaveQueries = 0;
bool g_bShuttingDown = false;
Handle g_hOnlineTimer = null;
Handle g_hReconnectTimer = null;

char g_SaveQueryBuffers[MAX_CONCURRENT_SAVE_QUERIES][SAVE_QUERY_MAXLEN];
int g_SaveQueryUserIds[MAX_CONCURRENT_SAVE_QUERIES];
bool g_SaveQuerySlotUsed[MAX_CONCURRENT_SAVE_QUERIES];

public void OnConfigsExecuted()
{
    RefreshHostAddress();
    RefreshServerFlags();
}



static void ResetRuntimeCounters(WhaleStats stats)
{
    stats.currentKillstreak = 0;
    stats.currentUbersLife = 0;
}

static void ResetStatsStruct(WhaleStats stats, bool resetIdentity)
{
    if (resetIdentity)
    {
        stats.loaded = false;
        stats.steamId[0] = '\0';
        stats.firstSeen[0] = '\0';
        stats.firstSeenTimestamp = 0;
    }

    stats.kills = 0;
    stats.deaths = 0;

    stats.totalHealing = 0;
    stats.totalUbers = 0;
    stats.totalMedicDrops = 0;
    stats.totalAirshots = 0;
    stats.totalHeadshots = 0;
    stats.totalBackstabs = 0;
    stats.totalAssists = 0;
    stats.totalDamage = 0;
    stats.totalDamageTaken = 0;
    stats.totalUberDrops = 0;
    for (int i = 0; i <= WEAPON_CATEGORY_COUNT; i++)
    {
        stats.weaponShots[i] = 0;
        stats.weaponHits[i] = 0;
    }
    stats.lastSeen = 0;
    stats.bestKillstreak = 0;
    stats.bestUbersLife = 0;
    stats.playtime = 0;
    stats.connectTime = 0.0;

    ResetRuntimeCounters(stats);
}

static void ResetAllStats(int client)
{
    ResetStatsStruct(g_Stats[client], true);
    ResetStatsStruct(g_MapStats[client], true);
    g_bStatsDirty[client] = false;
    g_bTrackEligible[client] = false;
    g_iDamageGate[client] = 0;
}

static void ResetMapStats(int client)
{
    ResetStatsStruct(g_MapStats[client], false);
    g_MapStats[client].loaded = g_Stats[client].loaded;
    if (g_Stats[client].steamId[0] != '\0')
    {
        strcopy(g_MapStats[client].steamId, sizeof(g_MapStats[client].steamId), g_Stats[client].steamId);
    }
    g_MapStats[client].connectTime = GetEngineTime();
    g_MapStats[client].lastSeen = g_Stats[client].lastSeen;
}

static void ResetRuntimeStats(int client)
{
    ResetRuntimeCounters(g_Stats[client]);
    ResetRuntimeCounters(g_MapStats[client]);
}

static void TouchClientLastSeen(int client)
{
    if (!IsClientInGame(client))
    {
        return;
    }

    int now = GetTime();
    g_Stats[client].lastSeen = now;
    g_MapStats[client].lastSeen = now;
    g_bTrackEligible[client] = (GetClientTeam(client) > 1);
}

void ClearOnlineStats()
{
    char deleteOnline[128];
    Format(deleteOnline, sizeof(deleteOnline), "DELETE FROM whaletracker_online WHERE host_port = %d", g_iHostPort);
    QueueSaveQuery(deleteOnline, 0, false);

    char deleteServer[128];
    Format(deleteServer, sizeof(deleteServer), "DELETE FROM whaletracker_servers WHERE port = %d", g_iHostPort);
    QueueSaveQuery(deleteServer, 0, false);
}

void RemoveOnlineStats(int client)
{
    char steamId[STEAMID64_LEN];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
        return;

    char query[192];
    Format(query, sizeof(query), "DELETE FROM whaletracker_online WHERE steamid = '%s' AND host_port = %d", steamId, g_iHostPort);
    QueueSaveQuery(query, 0, false);
}

public Action Timer_UpdateOnlineStats(Handle timer, any data)
{
    if (!g_bDatabaseReady || g_hDatabase == null)
        return Plugin_Continue;

    int now = GetTime();
    float engineNow = GetEngineTime();
    int playerCount = GetClientCount(true);

    int visibleMax = GetMaxHumanPlayers();
    if (g_hVisibleMaxPlayers != null)
    {
        int conVarValue = GetConVarInt(g_hVisibleMaxPlayers);
        if (conVarValue > 0 && visibleMax > conVarValue)
        {
            visibleMax = conVarValue;
        }
    }

    char steamId[STEAMID64_LEN];
    char name[MAX_NAME_LENGTH];
    char escapedName[MAX_NAME_LENGTH * 2];
    char query[SAVE_QUERY_MAXLEN];
    char escapedMapName[256];
    char mapName[128];
    if (g_sOnlineMapName[0])
    {
        strcopy(mapName, sizeof(mapName), g_sOnlineMapName);
    }
    else
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }
    SQL_EscapeString(g_hDatabase, mapName, escapedMapName, sizeof(escapedMapName));

    char escapedHostIp[64];
    char hostIp[64];
    if (g_sPublicHostIp[0])
    {
        strcopy(hostIp, sizeof(hostIp), g_sPublicHostIp);
    }
    else if (g_sHostIp[0])
    {
        strcopy(hostIp, sizeof(hostIp), g_sHostIp);
    }
    else
    {
        strcopy(hostIp, sizeof(hostIp), "0.0.0.0");
    }
    SQL_EscapeString(g_hDatabase, hostIp, escapedHostIp, sizeof(escapedHostIp));

    char hostCity[64];
    if (g_sHostCity[0])
    {
        strcopy(hostCity, sizeof(hostCity), g_sHostCity);
    }
    else
    {
        strcopy(hostCity, sizeof(hostCity), "Unknown");
    }
    char escapedHostCity[128];
    SQL_EscapeString(g_hDatabase, hostCity, escapedHostCity, sizeof(escapedHostCity));

    char hostCountry[3];
    if (g_sHostCountryLower[0])
    {
        strcopy(hostCountry, sizeof(hostCountry), g_sHostCountryLower);
    }
    else
    {
        strcopy(hostCountry, sizeof(hostCountry), "");
    }
    char escapedHostCountry[16];
    SQL_EscapeString(g_hDatabase, hostCountry, escapedHostCountry, sizeof(escapedHostCountry));

    char escapedServerFlags[512];
    SQL_EscapeString(g_hDatabase, g_sServerFlags, escapedServerFlags, sizeof(escapedServerFlags));

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
            continue;

        GetClientName(client, name, sizeof(name));
        RememberMatchPlayerName(steamId, name);
        SQL_EscapeString(g_hDatabase, name, escapedName, sizeof(escapedName));

        TouchClientLastSeen(client);

        TFClassType tfClassType = TF2_GetPlayerClass(client);
        int tfClass = view_as<int>(tfClassType);
        int team = GetClientTeam(client);
        bool alive = IsPlayerAlive(client);
        bool spectator = (team != 2 && team != 3) || tfClassType == TFClass_Unknown;

        int playtime = g_MapStats[client].playtime;
        if (g_MapStats[client].connectTime > 0.0)
        {
            playtime += RoundToFloor(engineNow - g_MapStats[client].connectTime);
        }

        char weaponValueSegment[512];
        BuildWeaponAccuracySegment(g_MapStats[client], weaponValueSegment, sizeof(weaponValueSegment));

        Format(query, sizeof(query),
            "REPLACE INTO whaletracker_online "
            ... "(steamid, personaname, class, team, alive, is_spectator, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, playtime, total_ubers, best_streak, visible_max, time_connected, shots_shotguns, hits_shotguns, shots_scatterguns, hits_scatterguns, shots_pistols, hits_pistols, shots_rocketlaunchers, hits_rocketlaunchers, shots_grenadelaunchers, hits_grenadelaunchers, shots_stickylaunchers, hits_stickylaunchers, shots_snipers, hits_snipers, shots_revolvers, hits_revolvers, host_ip, host_port, playercount, map_name, last_update) "
            ... "VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %s, '%s', %d, %d, '%s', %d)",
            steamId,
            escapedName,
            tfClass,
            team,
            alive ? 1 : 0,
            spectator ? 1 : 0,
            g_MapStats[client].kills,
            g_MapStats[client].deaths,
            g_MapStats[client].totalAssists,
            g_MapStats[client].totalDamage,
            g_MapStats[client].totalDamageTaken,
            g_MapStats[client].totalHealing,
            g_MapStats[client].totalHeadshots,
            g_MapStats[client].totalBackstabs,
            playtime,
            g_MapStats[client].totalUbers,
            g_MapStats[client].bestKillstreak,
            visibleMax,
            playtime,
            weaponValueSegment,
            escapedHostIp,
            g_iHostPort,
            playerCount,
            escapedMapName,
            now);

        QueueSaveQuery(query, 0, false);

        int snapshotData[MATCH_STAT_COUNT];
        SnapshotFromStats(g_MapStats[client], snapshotData);
        InsertPlayerLogRecord(snapshotData, steamId, name, now, false);
    }

    Format(query, sizeof(query), "DELETE FROM whaletracker_online WHERE last_update < %d", now - 20);
    QueueSaveQuery(query, 0, false);

    Format(query, sizeof(query),
        "REPLACE INTO whaletracker_servers "
        ... "(ip, port, playercount, visible_max, map, city, country, flags, last_update) "
        ... "VALUES ('%s', %d, %d, %d, '%s', '%s', '%s', '%s', %d)",
        escapedHostIp,
        g_iHostPort,
        playerCount,
        visibleMax,
        escapedMapName,
        escapedHostCity,
        escapedHostCountry,
        escapedServerFlags,
        now);
    QueueSaveQuery(query, 0, false);

    int duration = (g_iMatchStartTime > 0) ? (now - g_iMatchStartTime) : 0;
    InsertMatchLogRecord(now, duration, playerCount, false);

    return Plugin_Continue;
}

public Action Timer_GlobalSave(Handle timer, any data)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            SaveClientStats(i, true, false);
        }
    }
    return Plugin_Continue;
}

static void EscapeSqlString(const char[] input, char[] output, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    output[0] = '\0';

    if (!input[0])
    {
        return;
    }

    if (g_hDatabase != null && g_bDatabaseReady)
    {
        SQL_EscapeString(g_hDatabase, input, output, maxlen);
        return;
    }

    int written = 0;
    for (int i = 0; input[i] != '\0' && written < maxlen - 1; i++)
    {
        char c = input[i];

        if (c == '\\' || c == '\'' || c == '\"')
        {
            if (written + 2 >= maxlen)
            {
                break;
            }
            output[written++] = '\\';
            output[written++] = c;
        }
        else if (c == '\n' || c == '\r' || c == '\t')
        {
            if (written + 2 >= maxlen)
            {
                break;
            }
            output[written++] = '\\';
            output[written++] = (c == '\n') ? 'n' : ((c == '\r') ? 'r' : 't');
        }
        else
        {
            output[written++] = c;
        }
    }

    output[written] = '\0';
}

static void EnsureMatchStorage()
{
    if (g_DisconnectedStats == null)
    {
        g_DisconnectedStats = new StringMap();
    }
    if (g_MatchNames == null)
    {
        g_MatchNames = new StringMap();
    }
}

static void ResetMatchStorage()
{
    EnsureMatchStorage();
    g_DisconnectedStats.Clear();
    g_MatchNames.Clear();
}

static void CopyLowercase(const char[] source, char[] dest, int maxlen)
{
    if (maxlen <= 0)
        return;

    int i = 0;
    for (; i < maxlen - 1 && source[i] != '\0'; i++)
    {
        dest[i] = CharToLower(source[i]);
    }
    dest[i] = '\0';
}

static bool WhaleTracker_IsConnectionLostError(const char[] error)
{
    if (!error[0])
    {
        return false;
    }

    return StrContains(error, "Lost connection to MySQL server", false) != -1
        || StrContains(error, "MySQL server has gone away", false) != -1
        || StrContains(error, "Server has gone away", false) != -1;
}

static void WhaleTracker_ScheduleReconnect(float delay)
{
    if (g_bShuttingDown)
    {
        return;
    }

    if (g_hReconnectTimer != null)
    {
        return;
    }

    g_bDatabaseReady = false;

    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }

    g_hReconnectTimer = CreateTimer(delay, WhaleTracker_ReconnectTimer);
}

public Action WhaleTracker_ReconnectTimer(Handle timer, any data)
{
    if (timer == g_hReconnectTimer)
    {
        g_hReconnectTimer = null;
    }

    WhaleTracker_SQLConnect();
    return Plugin_Stop;
}

static bool WhaleTracker_IsDatabaseHealthy()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return false;
    }

    if (SQL_FastQuery(g_hDatabase, "SELECT 1"))
    {
        return true;
    }

    char error[256];
    SQL_GetError(g_hDatabase, error, sizeof(error));
    LogError("[WhaleTracker] DB health check failed: %s", error);
    WhaleTracker_ScheduleReconnect(1.0);
    return false;
}

static void RememberMatchPlayerName(const char[] steamId, const char[] name)
{
    if (!steamId[0] || !name[0])
        return;

    EnsureMatchStorage();
    g_MatchNames.SetString(steamId, name);
}

static bool GetStoredMatchPlayerName(const char[] steamId, char[] buffer, int maxlen)
{
    if (!steamId[0] || maxlen <= 0)
    {
        return false;
    }

    EnsureMatchStorage();
    return g_MatchNames.GetString(steamId, buffer, maxlen);
}

static void SnapshotFromStats(const WhaleStats stats, int data[MATCH_STAT_COUNT])
{
    data[MatchStat_Kills] = stats.kills;
    data[MatchStat_Deaths] = stats.deaths;
    data[MatchStat_Assists] = stats.totalAssists;
    data[MatchStat_Damage] = stats.totalDamage;
    data[MatchStat_DamageTaken] = stats.totalDamageTaken;
    data[MatchStat_Healing] = stats.totalHealing;
    data[MatchStat_Headshots] = stats.totalHeadshots;
    data[MatchStat_Backstabs] = stats.totalBackstabs;
    data[MatchStat_Ubers] = stats.totalUbers;
    data[MatchStat_Playtime] = stats.playtime;
    data[MatchStat_MedicDrops] = stats.totalMedicDrops;
    data[MatchStat_UberDrops] = stats.totalUberDrops;
    data[MatchStat_Airshots] = stats.totalAirshots;
    data[MatchStat_BestStreak] = stats.bestKillstreak;
    data[MatchStat_BestUbersLife] = stats.bestUbersLife;
}

static void MergeSnapshotArrays(int base[MATCH_STAT_COUNT], const int delta[MATCH_STAT_COUNT])
{
    base[MatchStat_Kills] += delta[MatchStat_Kills];
    base[MatchStat_Deaths] += delta[MatchStat_Deaths];
    base[MatchStat_Assists] += delta[MatchStat_Assists];
    base[MatchStat_Damage] += delta[MatchStat_Damage];
    base[MatchStat_DamageTaken] += delta[MatchStat_DamageTaken];
    base[MatchStat_Healing] += delta[MatchStat_Healing];
    base[MatchStat_Headshots] += delta[MatchStat_Headshots];
    base[MatchStat_Backstabs] += delta[MatchStat_Backstabs];
    base[MatchStat_Ubers] += delta[MatchStat_Ubers];
    base[MatchStat_Playtime] += delta[MatchStat_Playtime];
    base[MatchStat_MedicDrops] += delta[MatchStat_MedicDrops];
    base[MatchStat_UberDrops] += delta[MatchStat_UberDrops];
    base[MatchStat_Airshots] += delta[MatchStat_Airshots];

    if (delta[MatchStat_BestStreak] > base[MatchStat_BestStreak])
    {
        base[MatchStat_BestStreak] = delta[MatchStat_BestStreak];
    }
    if (delta[MatchStat_BestUbersLife] > base[MatchStat_BestUbersLife])
    {
        base[MatchStat_BestUbersLife] = delta[MatchStat_BestUbersLife];
    }
}

static void AppendSnapshotToStorage(const char[] steamId, const int data[MATCH_STAT_COUNT])
{
    if (!steamId[0])
        return;

    EnsureMatchStorage();

    int aggregate[MATCH_STAT_COUNT];
    bool hasExisting = g_DisconnectedStats.GetArray(steamId, aggregate, MATCH_STAT_COUNT);

    if (hasExisting)
    {
        MergeSnapshotArrays(aggregate, data);
    }
    else
    {
        for (int i = 0; i < MATCH_STAT_COUNT; i++)
        {
            aggregate[i] = data[i];
        }
    }

    g_DisconnectedStats.SetArray(steamId, aggregate, MATCH_STAT_COUNT);
}

static bool ExtractSnapshotForSteamId(const char[] steamId, int data[MATCH_STAT_COUNT])
{
    if (!steamId[0])
        return false;

    EnsureMatchStorage();
    return g_DisconnectedStats.GetArray(steamId, data, MATCH_STAT_COUNT);
}

static void RemoveSnapshotForSteamId(const char[] steamId)
{
    if (!steamId[0] || g_DisconnectedStats == null)
        return;

    g_DisconnectedStats.Remove(steamId);
}

static void ApplySnapshotToStats(WhaleStats stats, const int data[MATCH_STAT_COUNT])
{
    stats.kills = data[MatchStat_Kills];
    stats.deaths = data[MatchStat_Deaths];
    stats.totalAssists = data[MatchStat_Assists];
    stats.totalDamage = data[MatchStat_Damage];
    stats.totalDamageTaken = data[MatchStat_DamageTaken];
    stats.totalHealing = data[MatchStat_Healing];
    stats.totalHeadshots = data[MatchStat_Headshots];
    stats.totalBackstabs = data[MatchStat_Backstabs];
    stats.totalUbers = data[MatchStat_Ubers];
    stats.playtime = data[MatchStat_Playtime];
    stats.totalMedicDrops = data[MatchStat_MedicDrops];
    stats.totalUberDrops = data[MatchStat_UberDrops];
    stats.totalAirshots = data[MatchStat_Airshots];
    stats.bestKillstreak = data[MatchStat_BestStreak];
    stats.bestUbersLife = data[MatchStat_BestUbersLife];
    stats.loaded = true;
}

static void BeginMatchTracking()
{
    CleanupFinalizedLog();
    ResetMatchStorage();

    g_iMatchStartTime = GetTime();
    GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
    if (!g_sCurrentMap[0])
    {
        strcopy(g_sCurrentMap, sizeof(g_sCurrentMap), "unknown");
    }

    int randomPart = GetURandomInt() & 0xFFFF;
    Format(g_sCurrentLogId, sizeof(g_sCurrentLogId), "%d_%04X", g_iMatchStartTime, randomPart);

    g_bMatchFinalized = false;
}

static void RefreshCurrentOnlineMapName()
{
    char rawName[128];
    g_sOnlineMapName[0] = '\0';
    GetCurrentMap(rawName, sizeof(rawName));
    if (!rawName[0])
    {
        strcopy(g_sOnlineMapName, sizeof(g_sOnlineMapName), "unknown");
        return;
    }

    ReplaceStringEx(rawName, sizeof(rawName), "workshop/", "");
    int dotIndex = FindCharInString(rawName, '.');
    if (dotIndex > 0 && dotIndex < sizeof(rawName))
    {
        rawName[dotIndex] = '\0';
    }
    strcopy(g_sOnlineMapName, sizeof(g_sOnlineMapName), rawName[0] ? rawName : "unknown");
}

static void RefreshHostAddress()
{
    if (g_hHostIpCvar == null)
    {
        g_hHostIpCvar = FindConVar("ip");
        if (g_hHostIpCvar == null)
        {
            g_hHostIpCvar = FindConVar("hostip");
        }
    }

    if (g_hHostIpCvar != null)
    {
        g_hHostIpCvar.GetString(g_sHostIp, sizeof(g_sHostIp));
    }
    else
    {
        g_sHostIp[0] = '\0';
    }

    if (!g_sHostIp[0])
    {
        strcopy(g_sHostIp, sizeof(g_sHostIp), "0.0.0.0");
    }

    if (g_hHostPortCvar == null)
    {
        g_hHostPortCvar = FindConVar("hostport");
    }
    g_iHostPort = (g_hHostPortCvar != null) ? g_hHostPortCvar.IntValue : 27015;

    RefreshPublicHostIp();
}

static void RefreshPublicHostIp()
{
    int addr[4];
    if (SteamWorks_GetPublicIP(addr))
    {
        Format(g_sPublicHostIp, sizeof(g_sPublicHostIp), "%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3]);
    }
    else
    {
        g_sPublicHostIp[0] = '\0';
    }

    RefreshHostCity();
}

static void RefreshHostCity()
{
    char sourceIp[64];
    if (g_sPublicHostIp[0])
    {
        strcopy(sourceIp, sizeof(sourceIp), g_sPublicHostIp);
    }
    else if (g_sHostIp[0])
    {
        strcopy(sourceIp, sizeof(sourceIp), g_sHostIp);
    }
    else
    {
        sourceIp[0] = '\0';
    }

    if (!sourceIp[0])
    {
        strcopy(g_sHostCity, sizeof(g_sHostCity), "Unknown");
        g_sHostCountry[0] = '\0';
        g_sHostCountryLower[0] = '\0';
        return;
    }

    char city[64];
    if (!GeoipCity(sourceIp, city, sizeof(city)) || !city[0])
    {
        strcopy(g_sHostCity, sizeof(g_sHostCity), "Unknown");
    }
    else
    {
        strcopy(g_sHostCity, sizeof(g_sHostCity), city);
    }

    char countryCode[3];
    if (!GeoipCode2(sourceIp, countryCode) || !countryCode[0])
    {
        g_sHostCountry[0] = '\0';
        g_sHostCountryLower[0] = '\0';
    }
    else
    {
        strcopy(g_sHostCountry, sizeof(g_sHostCountry), countryCode);
        CopyLowercase(countryCode, g_sHostCountryLower, sizeof(g_sHostCountryLower));
    }
}

public void ConVarChanged_ServerFlags(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshServerFlags();
}

static void RefreshServerFlags()
{
    if (g_hServerFlags == null)
    {
        g_hServerFlags = CreateConVar("sm_serverflags", "", "Additional flag codes (comma-separated) appended to the server card", FCVAR_NOTIFY);
        g_hServerFlags.AddChangeHook(ConVarChanged_ServerFlags);
    }
    g_hServerFlags.GetString(g_sServerFlags, sizeof(g_sServerFlags));
    TrimString(g_sServerFlags);
}

static void InsertPlayerLogRecord(const int data[MATCH_STAT_COUNT], const char[] steamId, const char[] name, int timestamp, bool forceSync)
{
    if (!g_sCurrentLogId[0] || steamId[0] == '\0')
        return;

    if (GetConVarInt(g_hDebugMinimalStats) < 1)
        return;

    char escapedName[256];
    EscapeSqlString(name, escapedName, sizeof(escapedName));

    char query[SAVE_QUERY_MAXLEN];
    Format(query, sizeof(query),
        "INSERT INTO whaletracker_log_players "
        ... "(log_id, steamid, personaname, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, total_ubers, playtime, medic_drops, uber_drops, airshots, best_streak, best_ubers_life, last_updated) "
        ... "VALUES ('%s', '%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d,  %d, %d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "personaname = VALUES(personaname), "
        ... "kills = VALUES(kills), "
        ... "deaths = VALUES(deaths), "
        ... "assists = VALUES(assists), "
        ... "damage = VALUES(damage), "
        ... "damage_taken = VALUES(damage_taken), "
        ... "healing = VALUES(healing), "
        ... "headshots = VALUES(headshots), "
        ... "backstabs = VALUES(backstabs), "
        ... "total_ubers = VALUES(total_ubers), "
        ... "playtime = VALUES(playtime), "
        ... "medic_drops = VALUES(medic_drops), "
        ... "uber_drops = VALUES(uber_drops), "
        ... "airshots = VALUES(airshots), "
        ... "best_streak = VALUES(best_streak), "
        ... "best_ubers_life = VALUES(best_ubers_life), "
        ... "last_updated = VALUES(last_updated)",
        g_sCurrentLogId,
        steamId,
        escapedName,
        data[MatchStat_Kills],
        data[MatchStat_Deaths],
        data[MatchStat_Assists],
        data[MatchStat_Damage],
        data[MatchStat_DamageTaken],
        data[MatchStat_Healing],
        data[MatchStat_Headshots],
        data[MatchStat_Backstabs],
        data[MatchStat_Ubers],
        data[MatchStat_Playtime],
        data[MatchStat_MedicDrops],
        data[MatchStat_UberDrops],
        data[MatchStat_Airshots],
        data[MatchStat_BestStreak],
        data[MatchStat_BestUbersLife],
        timestamp);

    QueueSaveQuery(query, 0, forceSync);
}

static void NormalizeGamemodeForMap(const char[] mapName, char[] gamemode, int gamemodeLen)
{
    if (!mapName[0])
    {
        return;
    }

    if (StrContains(mapName, "ctf_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "Capture The Flag");
        return;
    }

    if (StrContains(mapName, "cp_", false) == 0)
    {
        strcopy(gamemode, gamemodeLen, "Control Point");
        return;
    }
}

static void InsertMatchLogRecord(int endTime, int duration, int participantCount, bool forceSync)
{
    if (!g_sCurrentLogId[0])
        return;

    if (GetConVarInt(g_hDebugMinimalStats) < 1)
        return;

    char mapName[128];
    strcopy(mapName, sizeof(mapName), g_sCurrentMap);
    if (!mapName[0])
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }

    char escapedMap[128];
    EscapeSqlString(mapName, escapedMap, sizeof(escapedMap));

    char gamemode[64] = "Unknown";
    if (g_hGameModeCvar == null)
    {
        g_hGameModeCvar = FindConVar("sm_gamemode");
    }
    if (g_hGameModeCvar != null)
    {
        g_hGameModeCvar.GetString(gamemode, sizeof(gamemode));
        if (!gamemode[0])
        {
            strcopy(gamemode, sizeof(gamemode), "Unknown");
        }
    }
    NormalizeGamemodeForMap(mapName, gamemode, sizeof(gamemode));

    char escapedMode[64];
    EscapeSqlString(gamemode, escapedMode, sizeof(escapedMode));

    int started = (g_iMatchStartTime > 0) ? g_iMatchStartTime : endTime;

    char query[512];
    Format(query, sizeof(query),
        "INSERT INTO whaletracker_logs "
        ... "(log_id, map, gamemode, started_at, ended_at, duration, player_count, created_at, updated_at) "
        ... "VALUES ('%s', '%s', '%s', %d, %d, %d, %d, %d, %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "map = VALUES(map), "
        ... "gamemode = VALUES(gamemode), "
        ... "started_at = VALUES(started_at), "
        ... "ended_at = VALUES(ended_at), "
        ... "duration = VALUES(duration), "
        ... "player_count = VALUES(player_count), "
        ... "updated_at = VALUES(updated_at)",
        g_sCurrentLogId,
        escapedMap,
        escapedMode,
        started,
        endTime,
        duration,
        participantCount,
        started,
        endTime);

    QueueSaveQuery(query, 0, forceSync);
}

static void FinalizeCurrentMatch(bool shuttingDown)
{
    if (g_bMatchFinalized)
        return;

    EnsureMatchStorage();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        AccumulatePlaytime(i);
        EnsureClientSteamId(i);

        if (g_MapStats[i].steamId[0] == '\0')
            continue;

        int data[MATCH_STAT_COUNT];
        SnapshotFromStats(g_MapStats[i], data);
        AppendSnapshotToStorage(g_MapStats[i].steamId, data);

        char name[MAX_NAME_LENGTH];
        GetClientName(i, name, sizeof(name));
        RememberMatchPlayerName(g_MapStats[i].steamId, name);
    }

    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        ResetMatchStorage();
        g_bMatchFinalized = true;
        return;
    }

    StringMapSnapshot snap = g_DisconnectedStats != null ? g_DisconnectedStats.Snapshot() : null;
    if (snap == null || snap.Length == 0)
    {
        if (snap != null)
        {
            delete snap;
        }
        ResetMatchStorage();
        g_bMatchFinalized = true;
        return;
    }

    int endTime = GetTime();
    int duration = (g_iMatchStartTime > 0) ? (endTime - g_iMatchStartTime) : 0;
    if (duration < 0)
    {
        duration = 0;
    }

    for (int i = 0; i < snap.Length; i++)
    {
        char steamId[STEAMID64_LEN];
        snap.GetKey(i, steamId, sizeof(steamId));

        int data[MATCH_STAT_COUNT];
        if (!ExtractSnapshotForSteamId(steamId, data))
            continue;

        char name[MAX_NAME_LENGTH];
        if (!GetStoredMatchPlayerName(steamId, name, sizeof(name)))
        {
            strcopy(name, sizeof(name), steamId);
        }

        InsertPlayerLogRecord(data, steamId, name, endTime, shuttingDown);
    }

    int participantCount = snap.Length;
    delete snap;

    InsertMatchLogRecord(endTime, duration, participantCount, shuttingDown);

    ResetMatchStorage();
    g_bMatchFinalized = true;
    if (g_sCurrentLogId[0])
    {
        strcopy(g_sLastFinalizedLogId, sizeof(g_sLastFinalizedLogId), g_sCurrentLogId);
    }
    g_sCurrentLogId[0] = '\0';
}

static void EnsureClientSteamId(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    char steamId[STEAMID64_LEN];
    if (GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        strcopy(g_Stats[client].steamId, sizeof(g_Stats[client].steamId), steamId);
        strcopy(g_MapStats[client].steamId, sizeof(g_MapStats[client].steamId), steamId);
        return;
    }

    // Keep map copy aligned if only fallback auth is currently available.
    if (g_Stats[client].steamId[0] != '\0')
    {
        strcopy(g_MapStats[client].steamId, sizeof(g_MapStats[client].steamId), g_Stats[client].steamId);
    }
}

static void CleanupFinalizedLog()
{
    if (!g_sLastFinalizedLogId[0] || !g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    char escaped[128];
    EscapeSqlString(g_sLastFinalizedLogId, escaped, sizeof(escaped));

    char query[SAVE_QUERY_MAXLEN];
    Format(query, sizeof(query),
        "DELETE FROM whaletracker_logs WHERE log_id = '%s' AND (SELECT COALESCE(SUM(damage), 0) FROM whaletracker_log_players WHERE log_id = '%s') < 500",
        escaped, escaped);
    QueueSaveQuery(query, 0, false);

    Format(query, sizeof(query),
        "DELETE FROM whaletracker_log_players WHERE log_id = '%s' AND NOT EXISTS (SELECT 1 FROM whaletracker_logs WHERE log_id = '%s')",
        escaped, escaped);
    QueueSaveQuery(query, 0, false);

    g_sLastFinalizedLogId[0] = '\0';
}

static int GetClientTfClass(int client)
{
    TFClassType tfClassType = TF2_GetPlayerClass(client);
    int classId = view_as<int>(tfClassType);
    if (classId < CLASS_MIN || classId > CLASS_MAX)
    {
        return 0;
    }
    return classId;
}

static int ResolveAccuracyWeaponCategory(int weapon)
{
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return 0;
    }

    if (!HasEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex"))
    {
        return 0;
    }

    int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
    if (defIndex <= 0)
    {
        return 0;
    }

    return GetWeaponCategoryFromDefIndex(defIndex);
}

static bool TrackAccuracyEvent(int client, int weapon, bool isHit)
{
    if (!WhaleTracker_IsTrackingEnabled(client))
    {
        return false;
    }

    int weaponCategory = ResolveAccuracyWeaponCategory(weapon);
    if (weaponCategory <= view_as<int>(WeaponCategory_None) || weaponCategory > WEAPON_CATEGORY_COUNT)
    {
        return false;
    }

    int classId = GetClientTfClass(client);
    if (classId <= 0)
    {
        return false;
    }

    if (isHit)
    {
        g_Stats[client].weaponHits[weaponCategory]++;
        g_MapStats[client].weaponHits[weaponCategory]++;
    }
    else
    {
        g_Stats[client].weaponShots[weaponCategory]++;
        g_MapStats[client].weaponShots[weaponCategory]++;
    }

    MarkClientDirty(client);
    return true;
}

static void IncrementHeadshotStats(WhaleStats stats)
{
    stats.totalHeadshots++;
}

static void RecordHeadshotEvent(int client)
{
    if (!WhaleTracker_IsTrackingEnabled(client))
    {
        return;
    }

    IncrementHeadshotStats(g_Stats[client]);
    IncrementHeadshotStats(g_MapStats[client]);
    MarkClientDirty(client);
}



static bool WhaleTracker_IsTrackingEnabled(int client)
{
    return (client > 0 && client <= MaxClients && !IsFakeClient(client) && GetClientTeam(client) > 1 && g_bTrackEligible[client]);
}

static bool WhaleTracker_CheckDamageGate(int client, int damage)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client) || GetClientTeam(client) <= 1)
    {
        return false;
    }
    g_iDamageGate[client] += damage;
    if (g_iDamageGate[client] >= 200)
    {
        g_bTrackEligible[client] = true;
        return true;
    }
    return false;
}

static void BuildWeaponAccuracySegment(const WhaleStats stats, char[] buffer, int maxlen)
{
    Format(buffer, maxlen,
        "%d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d",
        stats.weaponShots[WeaponCategory_Shotguns],
        stats.weaponHits[WeaponCategory_Shotguns],
        stats.weaponShots[WeaponCategory_Scatterguns],
        stats.weaponHits[WeaponCategory_Scatterguns],
        stats.weaponShots[WeaponCategory_Pistols],
        stats.weaponHits[WeaponCategory_Pistols],
        stats.weaponShots[WeaponCategory_RocketLaunchers],
        stats.weaponHits[WeaponCategory_RocketLaunchers],
        stats.weaponShots[WeaponCategory_GrenadeLaunchers],
        stats.weaponHits[WeaponCategory_GrenadeLaunchers],
        stats.weaponShots[WeaponCategory_StickyLaunchers],
        stats.weaponHits[WeaponCategory_StickyLaunchers],
        stats.weaponShots[WeaponCategory_Snipers],
        stats.weaponHits[WeaponCategory_Snipers],
        stats.weaponShots[WeaponCategory_Revolvers],
        stats.weaponHits[WeaponCategory_Revolvers]);
}

static void ResetLifeCounters(WhaleStats stats)
{
    stats.currentKillstreak = 0;
    stats.currentUbersLife = 0;
}

static void ApplyKillStats(WhaleStats stats, bool backstab, bool medicDrop)
{
    stats.kills++;

    stats.currentKillstreak++;


    if (stats.currentKillstreak > stats.bestKillstreak)
    {
        stats.bestKillstreak = stats.currentKillstreak;
    }
    if (backstab)
    {
        stats.totalBackstabs++;
    }
    if (medicDrop)
    {
        stats.totalMedicDrops++;
    }
}

static void ApplyAssistStats(WhaleStats stats)
{
    stats.totalAssists++;

}

static void ApplyDeathStats(WhaleStats stats)
{
    stats.deaths++;
    ResetLifeCounters(stats);
}

static void ApplyHealingStats(WhaleStats stats, int amount)
{
    stats.totalHealing += amount;
}

static void ApplyUberStats(WhaleStats stats)
{
    stats.totalUbers++;

    stats.currentUbersLife++;
    if (stats.currentUbersLife > stats.bestUbersLife)
    {
        stats.bestUbersLife = stats.currentUbersLife;
    }
}

static bool AccumulatePlaytimeStruct(WhaleStats stats)
{
    if (stats.connectTime <= 0.0)
        return false;

    float session = GetEngineTime() - stats.connectTime;
    if (session >= 1.0)
    {
        int delta = RoundToFloor(session);
        stats.playtime += delta;
        stats.connectTime = GetEngineTime();
        return delta > 0;
    }
    return false;
}

static bool AccumulatePlaytime(int client)
{
    if (client <= 0 || client > MaxClients)
        return false;

    bool changed = false;
    changed |= AccumulatePlaytimeStruct(g_Stats[client]);
    changed |= AccumulatePlaytimeStruct(g_MapStats[client]);
    return changed;
}

static void MarkClientDirty(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    g_bStatsDirty[client] = true;
}

static void RunSaveQuerySync(const char[] query, int userId)
{
    if (g_hDatabase == null)
    {
        return;
    }

    if (!SQL_FastQuery(g_hDatabase, query))
    {
        char error[256];
        SQL_GetError(g_hDatabase, error, sizeof(error));

        if (userId > 0)
        {
            LogError("[WhaleTracker] Failed to save stats synchronously (userid %d): %s", userId, error);
        }
        else
        {
            LogError("[WhaleTracker] Failed to save stats synchronously: %s", error);
        }

        if (WhaleTracker_IsConnectionLostError(error))
        {
            WhaleTracker_ScheduleReconnect(2.0);
        }
    }
}

static void PumpSaveQueue()
{
    if (g_SaveQueue == null || g_hDatabase == null || !g_bDatabaseReady || g_bShuttingDown)
    {
        return;
    }

    while (g_PendingSaveQueries < MAX_CONCURRENT_SAVE_QUERIES && g_SaveQueue.Length > 0)
    {
        DataPack pack = view_as<DataPack>(g_SaveQueue.Get(0));
        g_SaveQueue.Erase(0);

        pack.Reset();
        int userId = pack.ReadCell();

        char query[SAVE_QUERY_MAXLEN];
        pack.ReadString(query, sizeof(query));

        delete pack;

        int slot = -1;
        for (int i = 0; i < MAX_CONCURRENT_SAVE_QUERIES; i++)
        {
            if (!g_SaveQuerySlotUsed[i])
            {
                slot = i;
                break;
            }
        }

        if (slot == -1)
        {
            RunSaveQuerySync(query, userId);
            continue;
        }

        strcopy(g_SaveQueryBuffers[slot], SAVE_QUERY_MAXLEN, query);
        g_SaveQueryUserIds[slot] = userId;
        g_SaveQuerySlotUsed[slot] = true;

        g_PendingSaveQueries++;
        g_hDatabase.Query(WhaleTracker_SaveCallback, g_SaveQueryBuffers[slot], slot);
    }
}

static void FlushSaveQueueSync()
{
    if (g_SaveQueue == null)
    {
        return;
    }

    while (g_SaveQueue.Length > 0)
    {
        DataPack pack = view_as<DataPack>(g_SaveQueue.Get(0));
        g_SaveQueue.Erase(0);

        pack.Reset();
        int userId = pack.ReadCell();

        char query[SAVE_QUERY_MAXLEN];
        pack.ReadString(query, sizeof(query));

        delete pack;

        RunSaveQuerySync(query, userId);
    }
}

static void QueueSaveQuery(const char[] query, int userId, bool forceSync)
{
    if (forceSync || g_bShuttingDown)
    {
        RunSaveQuerySync(query, userId);
        return;
    }

    if (g_SaveQueue == null)
    {
        g_SaveQueue = new ArrayList();
    }

    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteString(query);
    g_SaveQueue.Push(pack);

    PumpSaveQueue();
}

public Plugin myinfo =
{
    name = "WhaleTracker",
    author = "Hombre",
    description = "Cumulative player stats system",
    version = "1.0.3",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    if (g_SaveQueue != null)
    {
        delete g_SaveQueue;
    }
    g_SaveQueue = new ArrayList();
    g_PendingSaveQueries = 0;
    g_bShuttingDown = false;
    g_hReconnectTimer = null;

    g_CvarDatabase = CreateConVar("sm_whaletracker_database", DB_CONFIG_DEFAULT, "Databases.cfg entry to use for WhaleTracker");
    g_CvarDatabase.GetString(g_sDatabaseConfig, sizeof(g_sDatabaseConfig));

    g_hDebugMinimalStats = CreateConVar(
        "sm_whaletracker_debug_minimal",
        "0",
        "Limit WhaleTracker stat tracking to core metrics for debugging crashes (0 = off, 1 = on)",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );

    if (g_hVisibleMaxPlayers == null)
    {
        g_hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    }

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_healed", Event_PlayerHealed, EventHookMode_Post);
    HookEvent("player_chargedeployed", Event_UberDeployed, EventHookMode_Post);

    RegConsoleCmd("sm_whalestats", Command_ShowStats, "Show your Whale Tracker statistics.");
    RegConsoleCmd("sm_stats", Command_ShowStats, "Show your Whale Tracker statistics.");
    RegConsoleCmd("sm_points", Command_ShowPoints, "Show your WhalePoints total.");
    RegConsoleCmd("sm_pos", Command_ShowPoints, "Show your WhalePoints total.");
    RegConsoleCmd("sm_pts", Command_ShowPoints, "Show your WhalePoints total.");
    RegConsoleCmd("sm_rank", Command_ShowPoints, "Show your WhalePoints total.");
    RegConsoleCmd("sm_ps", Command_ShowPoints, "Show your WhalePoints total.");
    RegConsoleCmd("sm_ranks", Command_ShowLeaderboard, "Show WhaleTracker leaderboard page.");
    RegAdminCmd("sm_savestats", Command_SaveAllStats, ADMFLAG_GENERIC, "Manually save all WhaleTracker stats");

    EnsureMatchStorage();

    if (g_hGameModeCvar == null)
    {
        g_hGameModeCvar = FindConVar("sm_gamemode");
    }

    if (GetClientCount(true) > 0 && !g_sCurrentLogId[0])
    {
        BeginMatchTracking();
    }

    RefreshCurrentOnlineMapName();
    RefreshHostAddress();
    RefreshServerFlags();

    WhaleTracker_SQLConnect();

    if (g_hOnlineTimer != null)
    {
        CloseHandle(g_hOnlineTimer);
    }
    g_hOnlineTimer = CreateTimer(10.0, Timer_UpdateOnlineStats, _, TIMER_REPEAT);
    if (g_hPeriodicSaveTimer != null)
    {
        CloseHandle(g_hPeriodicSaveTimer);
    }
    g_hPeriodicSaveTimer = CreateTimer(30.0, Timer_GlobalSave, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    ClearOnlineStats();

    for (int i = 1; i <= MaxClients; i++)
    {
        ResetAllStats(i);
        ResetMapStats(i);
        g_KillSaveCounter[i] = 0;
        g_bStatsDirty[i] = false;
        if (IsClientInGame(i))
        {
            OnClientPutInServer(i);
            if (AreClientCookiesCached(i))
            {
                LoadClientStats(i);
            }
        }
    }
}

public void OnMapStart()
{
    if (!WhaleTracker_IsDatabaseHealthy())
    {
        WhaleTracker_ScheduleReconnect(1.0);
    }

    FinalizeCurrentMatch(false);
    if (GetClientCount(true) > 1)
    {
        BeginMatchTracking();
    }
    RefreshCurrentOnlineMapName();
    RefreshHostAddress();
    ClearOnlineStats();
    for (int i = 1; i <= MaxClients; i++)
    {
        ResetMapStats(i);
        if (IsClientInGame(i))
        {
            g_MapStats[i].connectTime = GetEngineTime();
        }
        g_KillSaveCounter[i] = 0;
    }
}

public void OnMapEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            SaveClientStats(i, true, true);
        }
    }

    FlushSaveQueueSync();
    FinalizeCurrentMatch(false);
}

public void OnPluginEnd()
{
    g_bShuttingDown = true;

    FinalizeCurrentMatch(true);

    FlushSaveQueueSync();

    if (g_hOnlineTimer != null)
    {
        CloseHandle(g_hOnlineTimer);
        g_hOnlineTimer = null;
    }
    if (g_hPeriodicSaveTimer != null)
    {
        CloseHandle(g_hPeriodicSaveTimer);
        g_hPeriodicSaveTimer = null;
    }
    if (g_hReconnectTimer != null)
    {
        CloseHandle(g_hReconnectTimer);
        g_hReconnectTimer = null;
    }

    ClearOnlineStats();

    if (g_SaveQueue != null)
    {
        delete g_SaveQueue;
        g_SaveQueue = null;
    }

    g_hDatabase = null;
    g_bDatabaseReady = false;
    g_hVisibleMaxPlayers = null;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            SDKUnhook(i, SDKHook_OnTakeDamage, OnTakeDamage);
        }

    }
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
    {
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
        return;
    }

    if (GetClientCount(true) == 1 && !g_sCurrentLogId[0])
    {
        BeginMatchTracking();
    }

    ResetRuntimeStats(client);
    g_Stats[client].connectTime = GetEngineTime();
    g_MapStats[client].connectTime = GetEngineTime();
    g_KillSaveCounter[client] = 0;
    g_bStatsDirty[client] = false;

    ResetMapStats(client);
    EnsureMatchStorage();
    EnsureClientSteamId(client);

    char steamId[STEAMID64_LEN];
    strcopy(steamId, sizeof(steamId), g_MapStats[client].steamId);

    if (steamId[0])
    {
        int snapshot[MATCH_STAT_COUNT];
        if (ExtractSnapshotForSteamId(steamId, snapshot))
        {
            ApplySnapshotToStats(g_MapStats[client], snapshot);
            RemoveSnapshotForSteamId(steamId);
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        RememberMatchPlayerName(steamId, name);
    }

    if (IsValidClient(client) && IsClientInGame(client))
    {
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    }
    TouchClientLastSeen(client);

    if (AreClientCookiesCached(client))
    {
        LoadClientStats(client);
    }

    g_bTrackEligible[client] = (GetClientTeam(client) > 1);
    g_iDamageGate[client] = 0;
}

public void OnClientCookiesCached(int client)
{
    if (IsFakeClient(client))
        return;

    LoadClientStats(client);
    TouchClientLastSeen(client);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
    {
        SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
        return;
    }

        if (IsClientInGame(client))
        {
            SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
        }

    AccumulatePlaytime(client);
    SaveClientStats(client, true, true);
    RemoveOnlineStats(client);
    ResetAllStats(client);
    g_KillSaveCounter[client] = 0;
    g_bTrackEligible[client] = false;
    g_iDamageGate[client] = 0;
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] != '\0')
    {
        return;
    }

    if (!auth[0])
    {
        return;
    }

    // Fallback only; EnsureClientSteamId() will overwrite with SteamID64 when available.
    strcopy(g_Stats[client].steamId, sizeof(g_Stats[client].steamId), auth);
    strcopy(g_MapStats[client].steamId, sizeof(g_MapStats[client].steamId), auth);
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client))
        return;

    if (IsFakeClient(client))
    {
        return;
    }

    QueryPointsCacheJoinMessage(client);
}

static void AnnounceDefaultJoin(int client)
{
    if (!IsValidClient(client) || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    CPrintToChatAll("%N joined the game", client);
}

static void QueryPointsCacheJoinMessage(int client)
{
    if (!IsValidClient(client) || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        AnnounceDefaultJoin(client);
        return;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        AnnounceDefaultJoin(client);
        return;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

    char query[512];
    Format(query, sizeof(query),
        "SELECT points, name_color, name, prename, rank FROM whaletracker_points_cache WHERE steamid = '%s' LIMIT 1",
        escapedSteamId);
    g_hDatabase.Query(WhaleTracker_JoinMessageQueryCallback, query, GetClientUserId(client));
}

public void WhaleTracker_JoinMessageQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (!IsValidClient(client) || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to query points cache for join message: %s", error);
        AnnounceDefaultJoin(client);
        return;
    }

    if (results == null || !results.FetchRow())
    {
        AnnounceDefaultJoin(client);
        return;
    }

    int points = results.FetchInt(0);
    int rank = results.FetchInt(4);

    if (points < 0)
    {
        points = 0;
    }

    char colorTag[32];
    results.FetchString(1, colorTag, sizeof(colorTag));
    TrimString(colorTag);

    char cachedName[128];
    char cachedPrename[128];
    results.FetchString(2, cachedName, sizeof(cachedName));
    results.FetchString(3, cachedPrename, sizeof(cachedPrename));
    TrimString(cachedName);
    TrimString(cachedPrename);

    char displayName[128];
    if (cachedPrename[0] != '\0')
    {
        strcopy(displayName, sizeof(displayName), cachedPrename);
    }
    else if (cachedName[0] != '\0')
    {
        strcopy(displayName, sizeof(displayName), cachedName);
    }
    else
    {
        GetClientName(client, displayName, sizeof(displayName));
    }

    // Always prefer live filters DB color if available.
    GetClientFiltersNameColorTag(client, colorTag, sizeof(colorTag));

    // Keep join announcement and cached values in sync with live formula/rank.
    int livePoints = GetWhalePointsForClient(client);
    int liveRank = GetWhalePointsRankForClient(client);
    if (livePoints < 0)
    {
        livePoints = 0;
    }
    if (liveRank < 0)
    {
        liveRank = 0;
    }
    if (livePoints != points || liveRank != rank)
    {
        points = livePoints;
        rank = liveRank;
        CacheWhalePointsForClient(client, points, rank, colorTag);
    }

    if (rank > 0)
    {
        CPrintToChatAll("{%s}%s{default} (%d Points, Rank #%d) joined the game", colorTag, displayName, points, rank);
        PrintToServer("[WhaleTracker] %s (%d Points, Rank #%d, color=%s) joined the game", displayName, points, rank, colorTag);
    }
    else
    {
        CPrintToChatAll("{%s}%s{default} (Unranked) joined the game", colorTag, displayName);
        PrintToServer("[WhaleTracker] %s (Unranked, color=%s) joined the game", displayName, colorTag);
    }
}

public void WhaleTracker_SQLConnect()
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

    g_bDatabaseReady = false;
    g_CvarDatabase.GetString(g_sDatabaseConfig, sizeof(g_sDatabaseConfig));
    g_bShuttingDown = false;
    Database.Connect(T_SQLConnect, g_sDatabaseConfig);
}

public void T_SQLConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[WhaleTracker] Database connection failed: %s", error);
        g_bDatabaseReady = false;
        WhaleTracker_ScheduleReconnect(5.0);
        return;
    }

    g_hDatabase = db;
    g_bDatabaseReady = true;

    if (!g_hDatabase.SetCharset("utf8mb4"))
    {
        LogError("[WhaleTracker] Failed to set database charset to utf8mb4, names may be truncated.");
    }

    char query[4096];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker` ("
        ... "`steamid` VARCHAR(32) PRIMARY KEY,"
        ... "`first_seen` INTEGER,"
        ... "`kills` INTEGER DEFAULT 0,"
        ... "`deaths` INTEGER DEFAULT 0,"
        ... "`healing` INTEGER DEFAULT 0,"
        ... "`total_ubers` INTEGER DEFAULT 0,"
        ... "`medic_drops` INTEGER DEFAULT 0,"
        ... "`uber_drops` INTEGER DEFAULT 0,"
        ... "`airshots` INTEGER DEFAULT 0,"
        ... "`headshots` INTEGER DEFAULT 0,"
        ... "`backstabs` INTEGER DEFAULT 0,"
        ... "`best_killstreak` INTEGER DEFAULT 0,"
        ... "`assists` INTEGER DEFAULT 0,"
        ... "`playtime` INTEGER DEFAULT 0,"
        ... "`damage_dealt` INTEGER DEFAULT 0,"
        ... "`damage_taken` INTEGER DEFAULT 0,"
        ... "`shots_scatterguns` INTEGER DEFAULT 0,"
        ... "`hits_scatterguns` INTEGER DEFAULT 0,"
        ... "`shots_pistols` INTEGER DEFAULT 0,"
        ... "`hits_pistols` INTEGER DEFAULT 0,"
        ... "`shots_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`hits_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`shots_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`hits_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`shots_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`hits_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`shots_snipers` INTEGER DEFAULT 0,"
        ... "`hits_snipers` INTEGER DEFAULT 0,"
        ... "`shots_revolvers` INTEGER DEFAULT 0,"
        ... "`hits_revolvers` INTEGER DEFAULT 0"
        ... ")");
    g_hDatabase.Query(WhaleTracker_CreateTable, query);

    Format(query, sizeof(query), "CREATE INDEX IF NOT EXISTS `idx_last_seen` ON `whaletracker` (`last_seen`)");
    g_hDatabase.Query(WhaleTracker_CreateTable, query);

    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_online` ("
        ... "`steamid` VARCHAR(32) PRIMARY KEY,"
        ... "`personaname` VARCHAR(128) DEFAULT '',"
        ... "`class` TINYINT DEFAULT 0,"
        ... "`team` TINYINT DEFAULT 0,"
        ... "`alive` TINYINT DEFAULT 0,"
        ... "`is_spectator` TINYINT DEFAULT 0,"
        ... "`kills` INTEGER DEFAULT 0,"
        ... "`deaths` INTEGER DEFAULT 0,"
        ... "`assists` INTEGER DEFAULT 0,"
        ... "`damage` INTEGER DEFAULT 0,"
        ... "`damage_taken` INTEGER DEFAULT 0,"
        ... "`healing` INTEGER DEFAULT 0,"
        ... "`headshots` INTEGER DEFAULT 0,"
        ... "`backstabs` INTEGER DEFAULT 0,"
        ... "`playtime` INTEGER DEFAULT 0,"
        ... "`total_ubers` INTEGER DEFAULT 0,"
        ... "`best_streak` INTEGER DEFAULT 0,"
        ... "`visible_max` INTEGER DEFAULT 0,"
        ... "`time_connected` INTEGER DEFAULT 0,"
        ... "`classes_mask` INTEGER DEFAULT 0,"
        ... "`shots_shotguns` INTEGER DEFAULT 0,"
        ... "`hits_shotguns` INTEGER DEFAULT 0,"
        ... "`shots_scatterguns` INTEGER DEFAULT 0,"
        ... "`hits_scatterguns` INTEGER DEFAULT 0,"
        ... "`shots_pistols` INTEGER DEFAULT 0,"
        ... "`hits_pistols` INTEGER DEFAULT 0,"
        ... "`shots_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`hits_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`shots_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`hits_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`shots_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`hits_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`shots_snipers` INTEGER DEFAULT 0,"
        ... "`hits_snipers` INTEGER DEFAULT 0,"
        ... "`shots_revolvers` INTEGER DEFAULT 0,"
        ... "`hits_revolvers` INTEGER DEFAULT 0,"
        ... "`host_ip` VARCHAR(64) DEFAULT '',"
        ... "`host_port` INTEGER DEFAULT 0,"
        ... "`playercount` INTEGER DEFAULT 0,"
        ... "`map_name` VARCHAR(128) DEFAULT '',"
        ... "`last_update` INTEGER DEFAULT 0"
        ... ")");
    g_hDatabase.Query(WhaleTracker_CreateOnlineTable, query);

        Format(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS `whaletracker_servers` ("
            ... "`ip` VARCHAR(64) NOT NULL,"
            ... "`port` INTEGER NOT NULL,"
            ... "`playercount` INTEGER DEFAULT 0,"
            ... "`visible_max` INTEGER DEFAULT 0,"
            ... "`map` VARCHAR(128) DEFAULT '',"
            ... "`city` VARCHAR(128) DEFAULT '',"
            ... "`country` VARCHAR(8) DEFAULT '',"
            ... "`flags` VARCHAR(256) DEFAULT '',"
            ... "`last_update` INTEGER DEFAULT 0,"
            ... "PRIMARY KEY (`ip`, `port`)"
            ... ")");
    g_hDatabase.Query(WhaleTracker_CreateServersTable, query);

    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_logs` ("
        ... "`log_id` VARCHAR(64) PRIMARY KEY,"
        ... "`map` VARCHAR(64) DEFAULT '',"
        ... "`gamemode` VARCHAR(64) DEFAULT 'Unknown',"
        ... "`started_at` INTEGER DEFAULT 0,"
        ... "`ended_at` INTEGER DEFAULT 0,"
        ... "`duration` INTEGER DEFAULT 0,"
        ... "`player_count` INTEGER DEFAULT 0,"
        ... "`created_at` INTEGER DEFAULT 0,"
        ... "`updated_at` INTEGER DEFAULT 0"
        ... ")");
    g_hDatabase.Query(WhaleTracker_CreateLogsTable, query);

    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_log_players` ("
        ... "`log_id` VARCHAR(64) NOT NULL,"
        ... "`steamid` VARCHAR(32) NOT NULL,"
        ... "`personaname` VARCHAR(128) DEFAULT '',"
        ... "`kills` INTEGER DEFAULT 0,"
        ... "`deaths` INTEGER DEFAULT 0,"
        ... "`assists` INTEGER DEFAULT 0,"
        ... "`damage` INTEGER DEFAULT 0,"
        ... "`damage_taken` INTEGER DEFAULT 0,"
        ... "`healing` INTEGER DEFAULT 0,"
        ... "`headshots` INTEGER DEFAULT 0,"
        ... "`backstabs` INTEGER DEFAULT 0,"
        ... "`total_ubers` INTEGER DEFAULT 0,"
        ... "`playtime` INTEGER DEFAULT 0,"
        ... "`medic_drops` INTEGER DEFAULT 0,"
        ... "`uber_drops` INTEGER DEFAULT 0,"
        ... "`airshots` INTEGER DEFAULT 0,"
        ... "`shots_shotguns` INTEGER DEFAULT 0,"
        ... "`hits_shotguns` INTEGER DEFAULT 0,"
        ... "`shots_scatterguns` INTEGER DEFAULT 0,"
        ... "`hits_scatterguns` INTEGER DEFAULT 0,"
        ... "`shots_pistols` INTEGER DEFAULT 0,"
        ... "`hits_pistols` INTEGER DEFAULT 0,"
        ... "`shots_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`hits_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`shots_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`hits_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`shots_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`hits_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`shots_snipers` INTEGER DEFAULT 0,"
        ... "`hits_snipers` INTEGER DEFAULT 0,"
        ... "`shots_revolvers` INTEGER DEFAULT 0,"
        ... "`hits_revolvers` INTEGER DEFAULT 0,"
        ... "`best_streak` INTEGER DEFAULT 0,"
        ... "`best_ubers_life` INTEGER DEFAULT 0,"
        ... "`last_updated` INTEGER DEFAULT 0,"
        ... "PRIMARY KEY (`log_id`, `steamid`)"
        ... ")");
    g_hDatabase.Query(WhaleTracker_CreateLogPlayersTable, query);

    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_points_cache` ("
        ... "`steamid` VARCHAR(32) PRIMARY KEY,"
        ... "`points` INTEGER DEFAULT 0,"
        ... "`rank` INTEGER DEFAULT 0,"
        ... "`name` VARCHAR(128) DEFAULT '',"
        ... "`name_color` VARCHAR(32) DEFAULT '',"
        ... "`prename` VARCHAR(64) DEFAULT '',"
        ... "`updated_at` INTEGER DEFAULT 0"
        ... ")");
    g_hDatabase.Query(WhaleTracker_CreatePointsCacheTable, query);

    SQL_FastQuery(g_hDatabase, "DROP TABLE IF EXISTS `whaletracker_mapstats`");
}

public void WhaleTracker_CreateTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create table: %s", error);
    }

    PumpSaveQueue();

    static const char alterQueries[][256] =
    {
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS damage_dealt INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS damage_taken INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS uber_drops INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS last_seen INTEGER DEFAULT 0",

        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS shots_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS hits_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker ADD COLUMN IF NOT EXISTS sort_weight DOUBLE AS (CASE WHEN playtime >= 14400 THEN (kills + (0.5 * assists)) / GREATEST(deaths, 1) ELSE -1 END) STORED",
        "CREATE INDEX IF NOT EXISTS idx_sort_weight ON whaletracker (sort_weight DESC, kills DESC)"
    };

    for (int i = 0; i < sizeof(alterQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterQueries[i]);
    }

    static const char alterOnlineQueries[][160] =
    {
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS personaname VARCHAR(128) DEFAULT ''",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS class TINYINT DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS team TINYINT DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS alive TINYINT DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS is_spectator TINYINT DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS kills INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS deaths INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS assists INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS damage INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS damage_taken INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS healing INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS headshots INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS backstabs INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS playtime INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS total_ubers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS best_streak INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS visible_max INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS time_connected INTEGER DEFAULT 0",

        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS shots_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS hits_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS host_ip VARCHAR(64) DEFAULT ''",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS host_port INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS playercount INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS map_name VARCHAR(128) DEFAULT ''",
        "ALTER TABLE whaletracker_online ADD COLUMN IF NOT EXISTS last_update INTEGER DEFAULT 0"
    };

    for (int i = 0; i < sizeof(alterOnlineQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterOnlineQueries[i]);
    }

    static const char alterOnlineMetaQueries[][160] =
    {
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS host_ip VARCHAR(64) DEFAULT ''",
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS host_port INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS map_name VARCHAR(128) DEFAULT ''",
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS playercount INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS visible_max INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_online_meta ADD COLUMN IF NOT EXISTS updated_at INTEGER DEFAULT 0"
    };

    for (int i = 0; i < sizeof(alterOnlineMetaQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterOnlineMetaQueries[i]);
    }

    static const char alterLogsQueries[][160] =
    {
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS map VARCHAR(64) DEFAULT ''",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS gamemode VARCHAR(64) DEFAULT 'Unknown'",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS started_at INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS ended_at INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS duration INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS player_count INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS created_at INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_logs ADD COLUMN IF NOT EXISTS updated_at INTEGER DEFAULT 0"
    };

    for (int i = 0; i < sizeof(alterLogsQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterLogsQueries[i]);
    }

    static const char alterLogPlayersQueries[][192] =
    {
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS personaname VARCHAR(128) DEFAULT ''",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS kills INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS deaths INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS assists INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS damage INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS damage_taken INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS healing INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS headshots INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS backstabs INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS total_ubers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS playtime INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS medic_drops INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS uber_drops INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS airshots INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_shotguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_scatterguns INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_pistols INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_rocketlaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_grenadelaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_stickylaunchers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_snipers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS shots_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS hits_revolvers INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS best_streak INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS best_ubers_life INTEGER DEFAULT 0",
        "ALTER TABLE whaletracker_log_players ADD COLUMN IF NOT EXISTS last_updated INTEGER DEFAULT 0"
    };

    for (int i = 0; i < sizeof(alterLogPlayersQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterLogPlayersQueries[i]);
    }

    static const char alterServersQueries[][160] =
    {
        "ALTER TABLE whaletracker_servers ADD COLUMN IF NOT EXISTS city VARCHAR(128) DEFAULT ''",
        "ALTER TABLE whaletracker_servers ADD COLUMN IF NOT EXISTS country VARCHAR(8) DEFAULT ''",
        "ALTER TABLE whaletracker_servers ADD COLUMN IF NOT EXISTS flags VARCHAR(256) DEFAULT ''"
    };

    for (int i = 0; i < sizeof(alterServersQueries); i++)
    {
        g_hDatabase.Query(WhaleTracker_AlterCallback, alterServersQueries[i]);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        if (AreClientCookiesCached(i))
        {
            LoadClientStats(i);
        }
    }
}

public void WhaleTracker_CreateOnlineTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create online table: %s", error);
    }
}

public void WhaleTracker_CreateLogsTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create logs table: %s", error);
    }
}

public void WhaleTracker_CreateServersTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create servers table: %s", error);
    }
}
public void WhaleTracker_CreateLogPlayersTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create log players table: %s", error);
    }
}

public void WhaleTracker_CreatePointsCacheTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to create points cache table: %s", error);
        return;
    }

    g_hDatabase.Query(WhaleTracker_AlterCallback,
        "ALTER TABLE whaletracker_points_cache ADD COLUMN IF NOT EXISTS name_color VARCHAR(32) DEFAULT ''");
    g_hDatabase.Query(WhaleTracker_AlterCallback,
        "ALTER TABLE whaletracker_points_cache ADD COLUMN IF NOT EXISTS name VARCHAR(128) DEFAULT ''");
    g_hDatabase.Query(WhaleTracker_AlterCallback,
        "ALTER TABLE whaletracker_points_cache ADD COLUMN IF NOT EXISTS prename VARCHAR(64) DEFAULT ''");
    g_hDatabase.Query(WhaleTracker_AlterCallback,
        "ALTER TABLE whaletracker_points_cache ADD COLUMN IF NOT EXISTS rank INTEGER DEFAULT 0");
}

public void WhaleTracker_AlterCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to alter table: %s", error);
    }
}

static void LoadClientStats(int client)
{
    if (!IsClientInGame(client) || !g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    char steamId[STEAMID64_LEN];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return;
    }

    strcopy(g_Stats[client].steamId, sizeof(g_Stats[client].steamId), steamId);
    strcopy(g_MapStats[client].steamId, sizeof(g_MapStats[client].steamId), steamId);

    char query[512];
    Format(query, sizeof(query),
        "SELECT first_seen, kills, deaths, healing, total_ubers, best_ubers_life, medic_drops, uber_drops, airshots, headshots, backstabs, best_killstreak, assists, playtime, damage_dealt, damage_taken, last_seen "
        ... "FROM whaletracker WHERE steamid = '%s'", steamId);

    g_hDatabase.Query(WhaleTracker_LoadCallback, query, client);
}

public void WhaleTracker_LoadCallback(Database db, DBResultSet results, const char[] error, any client)
{
    int index = client;
    if (!IsValidClient(index))
    {
        return;
    }

    if (error[0] != '\0')
    {
        LogError("[WhaleTracker] Failed to load stats for %N: %s", index, error);
        return;
    }

    if (results != null && results.FetchRow())
    {
        g_Stats[index].firstSeenTimestamp = results.FetchInt(0);
        FormatTime(g_Stats[index].firstSeen, sizeof(g_Stats[index].firstSeen), "%Y-%m-%d", g_Stats[index].firstSeenTimestamp);
        g_Stats[index].kills = results.FetchInt(1);
        g_Stats[index].deaths = results.FetchInt(2);
        g_Stats[index].totalHealing = results.FetchInt(3);
        g_Stats[index].totalUbers = results.FetchInt(4);
        g_Stats[index].bestUbersLife = results.FetchInt(5);
        g_Stats[index].totalMedicDrops = results.FetchInt(6);
        g_Stats[index].totalUberDrops = results.FetchInt(7);
        g_Stats[index].totalAirshots = results.FetchInt(8);
        g_Stats[index].totalHeadshots = results.FetchInt(9);
        g_Stats[index].totalBackstabs = results.FetchInt(10);
        g_Stats[index].bestKillstreak = results.FetchInt(11);
        g_Stats[index].totalAssists = results.FetchInt(12);
        g_Stats[index].playtime = results.FetchInt(13);
        g_Stats[index].totalDamage = results.FetchInt(14);
        g_Stats[index].totalDamageTaken = results.FetchInt(15);
        g_Stats[index].lastSeen = results.FetchInt(16);
        g_Stats[index].loaded = true;
        g_MapStats[index].loaded = true;
        g_MapStats[index].totalUberDrops = g_Stats[index].totalUberDrops;
    }
    else
    {
        g_Stats[index].firstSeenTimestamp = GetTime();
        FormatTime(g_Stats[index].firstSeen, sizeof(g_Stats[index].firstSeen), "%Y-%m-%d", g_Stats[index].firstSeenTimestamp);
        g_Stats[index].loaded = true;
        g_MapStats[index].loaded = true;
        g_MapStats[index].loaded = true;
    }

    TouchClientLastSeen(index);
}

static bool HasMapActivity(WhaleStats stats)
{
    return stats.playtime > 0
        || stats.kills > 0
        || stats.deaths > 0
        || stats.totalAssists > 0
        || stats.totalHealing > 0
        || stats.totalDamage > 0
        || stats.totalDamageTaken > 0
        || stats.totalHeadshots > 0
        || stats.totalBackstabs > 0
        || stats.totalUberDrops > 0
        || stats.totalMedicDrops > 0;
}

static bool SaveClientMapStats(int client)
{
    if (!IsValidClient(client))
        return false;

    if (!g_MapStats[client].loaded)
        return false;

    if (g_MapStats[client].steamId[0] == '\0')
        return false;

    if (!HasMapActivity(g_MapStats[client]))
        return false;

    int snapshot[MATCH_STAT_COUNT];
    SnapshotFromStats(g_MapStats[client], snapshot);
    AppendSnapshotToStorage(g_MapStats[client].steamId, snapshot);

    EnsureMatchStorage();

    char name[MAX_NAME_LENGTH];
    if (IsClientInGame(client))
    {
        GetClientName(client, name, sizeof(name));
    }
    else if (!GetStoredMatchPlayerName(g_MapStats[client].steamId, name, sizeof(name)))
    {
        name[0] = '\0';
    }

    if (!name[0])
    {
        strcopy(name, sizeof(name), g_MapStats[client].steamId);
    }

    RememberMatchPlayerName(g_MapStats[client].steamId, name);

    return true;
}

static void QueueStatsSave(int client, int userId)
{
    char query[SAVE_QUERY_MAXLEN];
    char accuracyValueSegment[512];
    BuildWeaponAccuracySegment(g_Stats[client], accuracyValueSegment, sizeof(accuracyValueSegment));

    Format(query, sizeof(query),
        "INSERT INTO whaletracker "
        ... "(steamid, first_seen, kills, deaths, healing, total_ubers, best_ubers_life, medic_drops, uber_drops, airshots, headshots, backstabs, "
        ... "best_killstreak, assists, playtime, damage_dealt, damage_taken, last_seen, "
        ... "shots_shotguns, hits_shotguns, shots_scatterguns, hits_scatterguns, shots_pistols, hits_pistols, shots_rocketlaunchers, hits_rocketlaunchers, shots_grenadelaunchers, hits_grenadelaunchers, shots_stickylaunchers, hits_stickylaunchers, shots_snipers, hits_snipers, shots_revolvers, hits_revolvers) "
        ... "VALUES ('%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, "
        ... "%d, %d, %d, %d, %d, %d, "
        ... "%s) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "first_seen = LEAST(first_seen, VALUES(first_seen)), "
        ... "kills = GREATEST(kills, VALUES(kills)), "
        ... "deaths = GREATEST(deaths, VALUES(deaths)), "
        ... "healing = GREATEST(healing, VALUES(healing)), "
        ... "total_ubers = GREATEST(total_ubers, VALUES(total_ubers)), "
        ... "best_ubers_life = GREATEST(best_ubers_life, VALUES(best_ubers_life)), "
        ... "medic_drops = GREATEST(medic_drops, VALUES(medic_drops)), "
        ... "uber_drops = GREATEST(uber_drops, VALUES(uber_drops)), "
        ... "airshots = GREATEST(airshots, VALUES(airshots)), "
        ... "headshots = GREATEST(headshots, VALUES(headshots)), "
        ... "backstabs = GREATEST(backstabs, VALUES(backstabs)), "
        ... "best_killstreak = GREATEST(best_killstreak, VALUES(best_killstreak)), "
        ... "assists = GREATEST(assists, VALUES(assists)), "
        ... "playtime = GREATEST(playtime, VALUES(playtime)), "
        ... "damage_dealt = GREATEST(damage_dealt, VALUES(damage_dealt)), "
        ... "damage_taken = GREATEST(damage_taken, VALUES(damage_taken)), "
        ... "last_seen = GREATEST(last_seen, VALUES(last_seen)), "

        ... "shots_shotguns = GREATEST(shots_shotguns, VALUES(shots_shotguns)), "
        ... "hits_shotguns = GREATEST(hits_shotguns, VALUES(hits_shotguns)), "
        ... "shots_scatterguns = GREATEST(shots_scatterguns, VALUES(shots_scatterguns)), "
        ... "hits_scatterguns = GREATEST(hits_scatterguns, VALUES(hits_scatterguns)), "
        ... "shots_pistols = GREATEST(shots_pistols, VALUES(shots_pistols)), "
        ... "hits_pistols = GREATEST(hits_pistols, VALUES(hits_pistols)), "
        ... "shots_rocketlaunchers = GREATEST(shots_rocketlaunchers, VALUES(shots_rocketlaunchers)), "
        ... "hits_rocketlaunchers = GREATEST(hits_rocketlaunchers, VALUES(hits_rocketlaunchers)), "
        ... "shots_grenadelaunchers = GREATEST(shots_grenadelaunchers, VALUES(shots_grenadelaunchers)), "
        ... "hits_grenadelaunchers = GREATEST(hits_grenadelaunchers, VALUES(hits_grenadelaunchers)), "
        ... "shots_stickylaunchers = GREATEST(shots_stickylaunchers, VALUES(shots_stickylaunchers)), "
        ... "hits_stickylaunchers = GREATEST(hits_stickylaunchers, VALUES(hits_stickylaunchers)), "
        ... "shots_snipers = GREATEST(shots_snipers, VALUES(shots_snipers)), "
        ... "hits_snipers = GREATEST(hits_snipers, VALUES(hits_snipers)), "
        ... "shots_revolvers = GREATEST(shots_revolvers, VALUES(shots_revolvers)), "
        ... "hits_revolvers = GREATEST(hits_revolvers, VALUES(hits_revolvers))",
        g_Stats[client].steamId,
        g_Stats[client].firstSeenTimestamp,
        g_Stats[client].kills,
        g_Stats[client].deaths,
        g_Stats[client].totalHealing,
        g_Stats[client].totalUbers,
        g_Stats[client].bestUbersLife,
        g_Stats[client].totalMedicDrops,
        g_Stats[client].totalUberDrops,
        g_Stats[client].totalAirshots,
        g_Stats[client].totalHeadshots,
        g_Stats[client].totalBackstabs,
        g_Stats[client].bestKillstreak,
        g_Stats[client].totalAssists,
        g_Stats[client].playtime,
        g_Stats[client].totalDamage,
        g_Stats[client].totalDamageTaken,
        g_Stats[client].lastSeen,

        accuracyValueSegment);

    QueueSaveQuery(query, userId, false);
}

static bool SaveClientStats(int client, bool includeMapStats, bool forceSave)
{
    if (!IsValidClient(client))
        return false;

    EnsureClientSteamId(client);

    if (g_Stats[client].steamId[0] == '\0')
        return false;

    bool playtimeChanged = AccumulatePlaytime(client);

    if (!g_Stats[client].loaded)
    {
        if (g_Stats[client].firstSeenTimestamp == 0)
        {
            g_Stats[client].firstSeenTimestamp = GetTime();
            FormatTime(g_Stats[client].firstSeen, sizeof(g_Stats[client].firstSeen), "%Y-%m-%d", g_Stats[client].firstSeenTimestamp);
        }
        g_Stats[client].loaded = true;
    }

    g_MapStats[client].loaded = true;

    g_KillSaveCounter[client] = 0;

    TouchClientLastSeen(client);

    if (!forceSave && !g_bStatsDirty[client] && !playtimeChanged)
    {
        return false;
    }

    int userId = GetClientUserId(client);
    QueueStatsSave(client, userId);

    if (includeMapStats)
    {
        SaveClientMapStats(client);
    }

    g_bStatsDirty[client] = false;

    return true;
}

public void WhaleTracker_SaveCallback(Database db, DBResultSet results, const char[] error, any data)
{
    int slot = data;
    int userId = 0;

    if (slot >= 0 && slot < MAX_CONCURRENT_SAVE_QUERIES)
    {
        userId = g_SaveQueryUserIds[slot];
    }

    if (error[0] != '\0')
    {
        int client = (userId > 0) ? GetClientOfUserId(userId) : 0;
        char queryPreview[256];
        queryPreview[0] = '\0';

        if (slot >= 0 && slot < MAX_CONCURRENT_SAVE_QUERIES)
        {
            if (g_SaveQueryBuffers[slot][0] != '\0')
            {
                strcopy(queryPreview, sizeof(queryPreview), g_SaveQueryBuffers[slot]);
            }
        }

        if (client > 0 && IsValidClient(client))
        {
            if (queryPreview[0])
            {
                LogError("[WhaleTracker] Failed to save stats for %N: %s | Query: %s", client, error, queryPreview);
            }
            else
            {
                LogError("[WhaleTracker] Failed to save stats for %N: %s", client, error);
            }
        }
        else if (userId > 0)
        {
            if (queryPreview[0])
            {
                LogError("[WhaleTracker] Failed to save stats (userid %d): %s | Query: %s", userId, error, queryPreview);
            }
            else
            {
                LogError("[WhaleTracker] Failed to save stats (userid %d): %s", userId, error);
            }
        }
        else
        {
            if (queryPreview[0])
            {
                LogError("[WhaleTracker] Failed to save stats: %s | Query: %s", error, queryPreview);
            }
            else
            {
                LogError("[WhaleTracker] Failed to save stats: %s", error);
            }
        }

        if (WhaleTracker_IsConnectionLostError(error))
        {
            WhaleTracker_ScheduleReconnect(2.0);
        }
    }

    if (slot >= 0 && slot < MAX_CONCURRENT_SAVE_QUERIES)
    {
        g_SaveQuerySlotUsed[slot] = false;
        g_SaveQueryUserIds[slot] = 0;
        g_SaveQueryBuffers[slot][0] = '\0';
    }

    if (g_PendingSaveQueries > 0)
    {
        g_PendingSaveQueries--;
    }

    PumpSaveQueue();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return;

    ResetLifeCounters(g_Stats[client]);
    ResetLifeCounters(g_MapStats[client]);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int assister = GetClientOfUserId(event.GetInt("assister"));
    int deathFlags = GetUserFlagBits(victim);
    bool attackerScoredMedicDrop = false;

    if (!(deathFlags & 32))
    {
        if (IsValidClient(attacker) && attacker != victim && WhaleTracker_IsTrackingEnabled(attacker))
        {
            int custom = event.GetInt("customkill");
            bool backstab = (custom == TF_CUSTOM_BACKSTAB);
            bool medicDrop = IsMedicDrop(victim);

            ApplyKillStats(g_Stats[attacker], backstab, medicDrop);
            ApplyKillStats(g_MapStats[attacker], backstab, medicDrop);
            attackerScoredMedicDrop = medicDrop;
            MarkClientDirty(attacker);
        }

        if (IsValidClient(assister) && assister != victim && WhaleTracker_IsTrackingEnabled(assister))
        {
            ApplyAssistStats(g_Stats[assister]);
            ApplyAssistStats(g_MapStats[assister]);
            MarkClientDirty(assister);
        }

        if (IsValidClient(victim) && WhaleTracker_IsTrackingEnabled(victim))
        {
            if (attackerScoredMedicDrop)
            {
                g_Stats[victim].totalUberDrops++;
                g_MapStats[victim].totalUberDrops++;
            }
            ApplyDeathStats(g_Stats[victim]);
            ApplyDeathStats(g_MapStats[victim]);
            MarkClientDirty(victim);
        }
    }
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (attacker == victim)
        return Plugin_Continue;

    int damageInt = RoundToFloor(damage);
    if (damageInt < 0)
    {
        damageInt = 0;
    }

    // Gate expensive tracking: allow attackers to become eligible after 200 damage dealt and only if not spectator.
    if (IsValidClient(attacker) && !IsFakeClient(attacker) && GetClientTeam(attacker) > 1 && !g_bTrackEligible[attacker])
    {
        if (!WhaleTracker_CheckDamageGate(attacker, damageInt))
        {
            // Still below threshold; skip further processing for this attacker.
            return Plugin_Continue;
        }
    }
    // Victims in spectator are ignored.
    if (IsValidClient(victim) && GetClientTeam(victim) <= 1)
    {
        return Plugin_Continue;
    }

    bool isHeadshot = (damagecustom == TF_CUSTOM_HEADSHOT || damagecustom == TF_CUSTOM_HEADSHOT_DECAPITATION);
    if (isHeadshot && IsValidClient(attacker) && !IsFakeClient(attacker))
    {
        RecordHeadshotEvent(attacker);
    }

    if (CheckIfAfterburn(damagecustom) || CheckIfBleedDmg(damagetype))
        return Plugin_Continue;

    if (damage <= 0.0)
        return Plugin_Continue;

    if (IsValidClient(attacker) && !IsFakeClient(attacker) && WhaleTracker_IsTrackingEnabled(attacker))
    {
        if (IsProjectileAirshot(attacker, victim))
            g_Stats[attacker].totalAirshots += 1;

        g_Stats[attacker].totalDamage += damageInt;
        g_MapStats[attacker].totalDamage += damageInt;
        if (!TrackAccuracyEvent(attacker, weapon, true))
        {
            if (!TrackAccuracyEvent(attacker, inflictor, true))
            {
                int activeWeapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
                if (activeWeapon > MaxClients)
                {
                    TrackAccuracyEvent(attacker, activeWeapon, true);
                }
            }
        }
        MarkClientDirty(attacker);
    }

    if (IsValidClient(victim) && !IsFakeClient(victim) && WhaleTracker_IsTrackingEnabled(victim))
    {
        g_Stats[victim].totalDamageTaken += damageInt;
        g_MapStats[victim].totalDamageTaken += damageInt;
        MarkClientDirty(victim);
    }

    return Plugin_Continue;
}

public Action TF2_CalcIsAttackCritical(int client, int weapon, char[] weaponname, bool& result)
{
    if (!WhaleTracker_IsTrackingEnabled(client))
        return Plugin_Continue;

    if (CheckIfAfterburn(0) || CheckIfBleedDmg(0))
        return Plugin_Continue;

    TrackAccuracyEvent(client, weapon, false);
    return Plugin_Continue;
}

public void Event_PlayerHealed(Event event, const char[] name, bool dontBroadcast)
{
    int healer = GetClientOfUserId(event.GetInt("healer"));
    if (!WhaleTracker_IsTrackingEnabled(healer))
        return;

    int amount = event.GetInt("amount");
    if (amount > 0)
    {
        ApplyHealingStats(g_Stats[healer], amount);
        ApplyHealingStats(g_MapStats[healer], amount);
        MarkClientDirty(healer);
    }
}

public void Event_UberDeployed(Event event, const char[] name, bool dontBroadcast)
{
    int medic = GetClientOfUserId(event.GetInt("userid"));
    if (!WhaleTracker_IsTrackingEnabled(medic))
        return;

    ApplyUberStats(g_Stats[medic]);
    ApplyUberStats(g_MapStats[medic]);
    MarkClientDirty(medic);
}

static bool IsMedicDrop(int victim)
{
    if (!IsValidClient(victim) || IsFakeClient(victim))
        return false;

    if (TF2_GetPlayerClass(victim) != TFClass_Medic)
        return false;

    int medigun = GetPlayerWeaponSlot(victim, 1);
    if (medigun <= MaxClients || !IsValidEntity(medigun))
        return false;

    float charge = GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");
    return charge >= 1.0;
}

static bool IsProjectileAirshot(int attacker, int victim)
{
    if (!IsValidClient(attacker) || IsFakeClient(attacker) || !IsValidClient(victim) || IsFakeClient(victim))
        return false;

    int weapon = GetPlayerWeaponSlot(attacker, 0);
    if (weapon <= MaxClients || !IsValidEntity(weapon))
        return false;

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));

    bool projectileWeapon = StrContains(classname, "rocketlauncher", false) != -1
        || StrContains(classname, "grenadelauncher", false) != -1
        || StrContains(classname, "pipeline", false) != -1
        || StrContains(classname, "stickbomb", false) != -1;

    if (!projectileWeapon)
        return false;

    int flags = GetEntityFlags(victim);
    bool victimInAir = !(flags & FL_ONGROUND);
    return victimInAir;
}

static void FormatMatchDuration(int seconds, char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    if (seconds <= 0)
    {
        strcopy(buffer, maxlen, "0s");
        return;
    }

    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    int secs = seconds % 60;

    if (hours > 0)
    {
        Format(buffer, maxlen, "%dh %dm", hours, minutes);
    }
    else if (minutes > 0)
    {
        Format(buffer, maxlen, "%dm %ds", minutes, secs);
    }
    else
    {
        Format(buffer, maxlen, "%ds", secs);
    }
}

static int GetWeaponCategoryFromDefIndex(int defIndex)
{
    switch (defIndex)
    {
        case 9, 10, 11, 12, 199, 425, 527, 1153:
            return WeaponCategory_Shotguns;
        case 13, 200, 15029, 669, 45, 448, 772, 1103:
            return WeaponCategory_Scatterguns;
        case 22, 23, 209, 773, 449, 160, 161:
            return WeaponCategory_Pistols;
        case 18, 205, 658, 513, 414, 441, 1104, 730, 228:
            return WeaponCategory_RocketLaunchers;
        case 19, 206, 1151, 308:
            return WeaponCategory_GrenadeLaunchers;
        case 20, 207, 661, 265, 130:
            return WeaponCategory_StickyLaunchers;
        case 14, 201, 664, 402, 230, 851, 752, 526:
            return WeaponCategory_Snipers;
        case 24, 210, 224, 61, 525, 460:
            return WeaponCategory_Revolvers;
    }

    return WeaponCategory_None;
}

stock bool CheckIfAfterburn(int damagecustom)
{
    return (damagecustom == TF_CUSTOM_BURNING || damagecustom == TF_CUSTOM_BURNING_FLARE);
}

stock bool CheckIfBleedDmg(int damageType)
{
    return (damageType & DMG_SLASH) != 0;
}

static void SendMatchStatsMessage(int viewer, int target)
{
    if (!IsValidClient(viewer) || IsFakeClient(viewer))
        return;

    if (!IsValidClient(target) || IsFakeClient(target))
    {
        CPrintToChat(viewer, "{green}[WhaleTracker]{default} No valid player selected.");
        return;
    }

    bool targetInGame = IsClientInGame(target);
    if (targetInGame)
    {
        AccumulatePlaytime(target);
    }

    EnsureClientSteamId(target);
    WhaleStats matchStats;
    matchStats = g_MapStats[target];
    bool hasActivity = HasMapActivity(matchStats) || matchStats.playtime > 0;

    if (!targetInGame && !hasActivity)
    {
        CPrintToChat(viewer, "{green}[WhaleTracker]{default} %N has no current match data.", target);
        return;
    }

    char playerName[MAX_NAME_LENGTH];
    if (targetInGame)
    {
        GetClientName(target, playerName, sizeof(playerName));
        RememberMatchPlayerName(matchStats.steamId, playerName);
    }
    else if (!GetStoredMatchPlayerName(matchStats.steamId, playerName, sizeof(playerName)))
    {
        strcopy(playerName, sizeof(playerName), matchStats.steamId);
    }

    char colorTag[32];
    GetClientFiltersNameColorTag(target, colorTag, sizeof(colorTag));

    int kills = matchStats.kills;
    int deaths = matchStats.deaths;
    int assists = matchStats.totalAssists;
    int damage = matchStats.totalDamage;
    int damageTaken = matchStats.totalDamageTaken;
    int healing = matchStats.totalHealing;
    int headshots = matchStats.totalHeadshots;
    int backstabs = matchStats.totalBackstabs;
    int ubers = matchStats.totalUbers;

    int lifetimeKills = g_Stats[target].kills;
    int lifetimeDeaths = g_Stats[target].deaths;
    float lifetimeKd = (lifetimeDeaths > 0) ? float(lifetimeKills) / float(lifetimeDeaths) : float(lifetimeKills);

    float kd = (deaths > 0) ? float(kills) / float(deaths) : float(kills);
    float dpm = 0.0, dtpm = 0.0;
    float minutes = (matchStats.playtime > 0) ? float(matchStats.playtime) / 60.0 : 0.0;
    if (minutes > 1.0)
    {
        dpm = (minutes > 0.0) ? float(damage) / minutes : 0.0;
        dtpm = (minutes > 0.0) ? float(damageTaken) / minutes : 0.0;
    }

    char timeBuffer[32];
    FormatMatchDuration(matchStats.playtime, timeBuffer, sizeof(timeBuffer));

    CPrintToChat(viewer, "{green}[WhaleTracker]{default} {%s}%s{default} — Match: K %d | D %d | KD %.2f | A %d | Dmg %d | Dmg/min %.1f",
        colorTag, playerName, kills, deaths, kd, assists, damage, dpm);
    CPrintToChat(viewer, "{green}[WhaleTracker]{default} Taken %d | Taken/min %.1f | Heal %d | HS %d | BS %d | Ubers %d | Time %s",
        damageTaken, dtpm, healing, headshots, backstabs, ubers, timeBuffer);
    CPrintToChat(viewer, "{green}[WhaleTracker]{default} Lifetime Kills %d | Deaths %d | KD: %.2f", lifetimeKills, lifetimeDeaths, lifetimeKd);
    CPrintToChat(viewer, "{green}[WhaleTracker]{default} Visit kogasa.tf/stats for full");
}

public Action Command_ShowStats(int client, int args)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Handled;

    int target = client;

    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);

        if (targetArg[0])
        {
            int candidate = FindTarget(client, targetArg, true, false);
            if (candidate > 0 && IsValidClient(candidate) && !IsFakeClient(candidate))
            {
                target = candidate;
            }
            else
            {
                CPrintToChat(client, "{green}[WhaleTracker]{default} Could not find player '%s'.", targetArg);
                return Plugin_Handled;
            }
        }
    }

    SendMatchStatsMessage(client, target);
    return Plugin_Handled;
}

public Action Command_SaveAllStats(int client, int args)
{
    int saved = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (SaveClientStats(i, true, true))
        {
            saved++;
        }
    }

    if (client > 0 && IsClientInGame(client))
    {
        CPrintToChat(client, "{green}[WhaleTracker]{default} Saved stats for %d player(s).", saved);
    }
    else
    {
        PrintToServer("[WhaleTracker] Saved stats for %d player(s).", saved);
    }

    return Plugin_Handled;
}

public Action Command_ShowPoints(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    int target = client;

    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);

        if (targetArg[0])
        {
            int candidate = FindTarget(client, targetArg, true, false);
            if (candidate > 0 && IsValidClient(candidate) && !IsFakeClient(candidate))
            {
                target = candidate;
            }
            else
            {
                CPrintToChat(client, "{green}[WhaleTracker]{default} Could not find player '%s'.", targetArg);
                return Plugin_Handled;
            }
        }
    }

    EnsureClientStatsLoadedForPoints(target);

    int combined = g_Stats[target].kills + g_Stats[target].deaths;
    if (combined <= WHALE_POINTS_MIN_KD_SUM)
    {
        char colorTagUnranked[32];
        GetClientFiltersNameColorTag(target, colorTagUnranked, sizeof(colorTagUnranked));
        CacheWhalePointsForClient(target, 0, 0, colorTagUnranked);
        CPrintToChat(client, "{green}[WhaleTracker]{default} {%s}%N{default} is unranked until Kills + Deaths exceeds %d (current: %d).", colorTagUnranked, target, WHALE_POINTS_MIN_KD_SUM, combined);
        return Plugin_Handled;
    }

    int points = GetWhalePointsForClient(target);
    int rank = GetWhalePointsRankForClient(target);
    int lifetimeKills = g_Stats[target].kills;
    int lifetimeDeaths = g_Stats[target].deaths;
    float lifetimeKd = (lifetimeDeaths > 0) ? float(lifetimeKills) / float(lifetimeDeaths) : float(lifetimeKills);
    char colorTag[32];
    GetClientFiltersNameColorTag(target, colorTag, sizeof(colorTag));
    char playerName[MAX_NAME_LENGTH];
    GetClientName(target, playerName, sizeof(playerName));

    CPrintToChatAll("{gold}[Whaletracker]{default} {%s}%s{default}'s Points: %d, Rank #%d", colorTag, playerName, points, rank);
    CPrintToChat(client, "Kill/Death ratio: %.2f", lifetimeKd);
    CPrintToChat(client, "Calculation: {lightgreen}((damage / 200) + (healing / 400) + (kills + floor(assists * 0.5)) + backstabs + headshots){default} / {axis}(deaths){default} * 10000");
    CPrintToChat(client, "Use {gold}!ranks{default} to view the leaderboard!");
    CacheWhalePointsForClient(target, points, rank, colorTag);

    return Plugin_Handled;
}

public Action Command_ShowLeaderboard(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        CPrintToChat(client, "{green}[WhaleTracker]{default} Database is not ready.");
        return Plugin_Handled;
    }

    int page = 1;
    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        int parsed = StringToInt(arg);
        if (parsed > 0)
        {
            page = parsed;
        }
    }

    int offset = (page - 1) * WHALE_LEADERBOARD_PAGE_SIZE;

    char query[512];
    Format(query, sizeof(query),
        "SELECT c.rank, c.points, "
        ... "COALESCE(NULLIF(p.newname,''), NULLIF(c.prename,''), NULLIF(c.name,''), c.steamid), "
        ... "COALESCE(NULLIF(c.name_color,''), 'gold') "
        ... "FROM whaletracker_points_cache c "
        ... "LEFT JOIN prename_rules p ON p.pattern = c.steamid "
        ... "WHERE c.rank > 0 "
        ... "ORDER BY CAST(c.rank AS SIGNED) ASC, c.points DESC, c.steamid ASC "
        ... "LIMIT %d OFFSET %d",
        WHALE_LEADERBOARD_PAGE_SIZE, offset);

    DBResultSet results = SQL_Query(g_hDatabase, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_hDatabase, error, sizeof(error));
        CPrintToChat(client, "{green}[WhaleTracker]{default} Failed to load leaderboard.");
        LogError("[WhaleTracker] Failed to load leaderboard: %s", error);
        return Plugin_Handled;
    }

    int rows = 0;

    while (results.FetchRow())
    {
        int rank = results.FetchInt(0);
        int points = results.FetchInt(1);

        char displayName[128];
        char colorTag[32];
        results.FetchString(2, displayName, sizeof(displayName));
        results.FetchString(3, colorTag, sizeof(colorTag));
        TrimString(displayName);
        TrimString(colorTag);

        if (displayName[0] == '\0')
        {
            strcopy(displayName, sizeof(displayName), "Unknown");
        }
        if (colorTag[0] == '\0')
        {
            strcopy(colorTag, sizeof(colorTag), "gold");
        }

        rows++;
        CPrintToChat(client, "#%d {%s}%s{default} %d", rank, colorTag, displayName, points);
    }
    delete results;

    if (rows == 0)
    {
        CPrintToChat(client, "{green}[WhaleTracker]{default} No leaderboard entries on page %d.", page);
        return Plugin_Handled;
    }

    CPrintToChat(client, "Use !{gold}ranks %d{default} to view the next 10 ranks!", page + 1);
    return Plugin_Handled;
}

static void CacheWhalePointsForClient(int client, int points, int rank, const char[] knownColor = "")
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        return;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

    char nameColor[32];
    if (knownColor[0] != '\0')
    {
        strcopy(nameColor, sizeof(nameColor), knownColor);
    }
    else
    {
        GetClientFiltersNameColorTag(client, nameColor, sizeof(nameColor));
    }

    char escapedNameColor[64];
    EscapeSqlString(nameColor, escapedNameColor, sizeof(escapedNameColor));

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));

    char escapedName[(MAX_NAME_LENGTH * 2) + 1];
    EscapeSqlString(clientName, escapedName, sizeof(escapedName));

    if (points < 0)
    {
        points = 0;
    }

    if (rank < 0)
    {
        rank = 0;
    }

    char query[1600];
    Format(query, sizeof(query),
        "INSERT INTO whaletracker_points_cache (steamid, points, rank, name, name_color, prename, updated_at) "
        ... "VALUES ('%s', %d, %d, '%s', '%s', COALESCE((SELECT newname FROM prename_rules WHERE pattern = '%s' LIMIT 1), ''), %d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "points = VALUES(points), "
        ... "rank = VALUES(rank), "
        ... "name = VALUES(name), "
        ... "name_color = VALUES(name_color), "
        ... "prename = COALESCE((SELECT newname FROM prename_rules WHERE pattern = '%s' LIMIT 1), prename), "
        ... "updated_at = VALUES(updated_at)",
        escapedSteamId,
        points,
        rank,
        escapedName,
        escapedNameColor,
        escapedSteamId,
        GetTime(),
        escapedSteamId);
    DBResultSet results = SQL_Query(g_hDatabase, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_hDatabase, error, sizeof(error));
        LogError("[WhaleTracker] Failed to update points cache: %s | Query: %s", error, query);
        return;
    }
    delete results;
}

static bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientConnected(client);
}

static void GetClientFiltersNameColorTag(int client, char[] colorTag, int maxlen)
{
    strcopy(colorTag, maxlen, "gold");

    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        return;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

    char query[192];
    Format(query, sizeof(query),
        "SELECT color FROM filters_namecolors WHERE steamid = '%s' LIMIT 1",
        escapedSteamId);

    DBResultSet results = SQL_Query(g_hDatabase, query);
    if (results != null && SQL_HasResultSet(results) && results.FetchRow())
    {
        results.FetchString(0, colorTag, maxlen);
        TrimString(colorTag);
    }
    delete results;

    if (colorTag[0] != '\0')
    {
        return;
    }

    // Fallback: use WhaleTracker points cache color when filters table has no row.
    Format(query, sizeof(query),
        "SELECT name_color FROM whaletracker_points_cache WHERE steamid = '%s' LIMIT 1",
        escapedSteamId);

    results = SQL_Query(g_hDatabase, query);
    if (results != null && SQL_HasResultSet(results) && results.FetchRow())
    {
        results.FetchString(0, colorTag, maxlen);
        TrimString(colorTag);
    }
    delete results;

    if (colorTag[0] == '\0')
    {
        strcopy(colorTag, maxlen, "gold");
    }
}

static int GetWhalePointsForClient(int client)
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return 0;
    }

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return 0;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        return 0;
    }

    int kills;
    int deaths;
    int assists;
    int backstabs;
    int headshots;
    int damage;
    int healing;

    if (g_Stats[client].loaded)
    {
        kills = g_Stats[client].kills;
        deaths = g_Stats[client].deaths;
        assists = g_Stats[client].totalAssists;
        backstabs = g_Stats[client].totalBackstabs;
        headshots = g_Stats[client].totalHeadshots;
        damage = g_Stats[client].totalDamage;
        healing = g_Stats[client].totalHealing;
    }
    else
    {
        char escapedSteamId[STEAMID64_LEN * 2];
        EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

        char query[256];
        Format(query, sizeof(query),
            "SELECT kills, deaths, assists, backstabs, headshots, damage_dealt, healing "
            ... "FROM whaletracker WHERE steamid = '%s' LIMIT 1",
            escapedSteamId);

        DBResultSet results = SQL_Query(g_hDatabase, query);
        if (results == null)
        {
            char error[256];
            SQL_GetError(g_hDatabase, error, sizeof(error));
            LogError("[WhaleTracker] WhalePoints query failed: %s", error);
            return 0;
        }

        if (!results.FetchRow())
        {
            delete results;
            return 0;
        }

        kills = results.FetchInt(0);
        deaths = results.FetchInt(1);
        assists = results.FetchInt(2);
        backstabs = results.FetchInt(3);
        headshots = results.FetchInt(4);
        damage = results.FetchInt(5);
        healing = results.FetchInt(6);
        delete results;
    }

    int safeKills = (kills > 0) ? kills : 0;
    int safeAssists = (assists > 0) ? assists : 0;
    int safeBackstabs = (backstabs > 0) ? backstabs : 0;
    int safeHeadshots = (headshots > 0) ? headshots : 0;
    int safeDamage = (damage > 0) ? damage : 0;
    int safeDeaths = (deaths > 0) ? deaths : 0;
    int safeHealing = (healing > 0) ? healing : 0;

    if ((safeKills + safeDeaths) <= WHALE_POINTS_MIN_KD_SUM)
    {
        return 0;
    }

    float positive = 0.0;
    positive += float(safeDamage) / 200.0;
    positive += float(safeHealing) / 400.0;
    positive += float(safeKills);
    positive += float(RoundToFloor(float(safeAssists) * 0.5));
    positive += float(safeBackstabs);
    positive += float(safeHeadshots);
    if (positive < 0.0)
    {
        positive = 0.0;
    }
    if (positive > 2147483000.0)
    {
        positive = 2147483000.0;
    }

    int denominatorBase = safeDeaths;
    if (denominatorBase < 1)
    {
        denominatorBase = 1;
    }

    float pointsFloat = (positive / float(denominatorBase)) * 10000.0;
    if (pointsFloat < 0.0)
    {
        pointsFloat = 0.0;
    }
    if (pointsFloat > 2147483000.0)
    {
        pointsFloat = 2147483000.0;
    }

    int points = RoundToCeil(pointsFloat);
    if (points < 0)
    {
        points = 0;
    }
    return points;
}

static void EnsureClientStatsLoadedForPoints(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return;
    }

    if (!g_bDatabaseReady || g_hDatabase == null || g_Stats[client].loaded)
    {
        return;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        return;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

    char query[512];
    Format(query, sizeof(query),
        "SELECT first_seen, kills, deaths, healing, total_ubers, best_ubers_life, medic_drops, uber_drops, airshots, headshots, backstabs, best_killstreak, assists, playtime, damage_dealt, damage_taken, last_seen "
        ... "FROM whaletracker WHERE steamid = '%s' LIMIT 1",
        escapedSteamId);

    DBResultSet results = SQL_Query(g_hDatabase, query);
    if (results == null)
    {
        return;
    }

    if (results.FetchRow())
    {
        g_Stats[client].firstSeenTimestamp = results.FetchInt(0);
        FormatTime(g_Stats[client].firstSeen, sizeof(g_Stats[client].firstSeen), "%Y-%m-%d", g_Stats[client].firstSeenTimestamp);
        g_Stats[client].kills = results.FetchInt(1);
        g_Stats[client].deaths = results.FetchInt(2);
        g_Stats[client].totalHealing = results.FetchInt(3);
        g_Stats[client].totalUbers = results.FetchInt(4);
        g_Stats[client].bestUbersLife = results.FetchInt(5);
        g_Stats[client].totalMedicDrops = results.FetchInt(6);
        g_Stats[client].totalUberDrops = results.FetchInt(7);
        g_Stats[client].totalAirshots = results.FetchInt(8);
        g_Stats[client].totalHeadshots = results.FetchInt(9);
        g_Stats[client].totalBackstabs = results.FetchInt(10);
        g_Stats[client].bestKillstreak = results.FetchInt(11);
        g_Stats[client].totalAssists = results.FetchInt(12);
        g_Stats[client].playtime = results.FetchInt(13);
        g_Stats[client].totalDamage = results.FetchInt(14);
        g_Stats[client].totalDamageTaken = results.FetchInt(15);
        g_Stats[client].lastSeen = results.FetchInt(16);
        g_Stats[client].loaded = true;
    }

    delete results;
}

static int GetWhalePointsRankForClient(int client)
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return 0;
    }

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return 0;
    }

    EnsureClientSteamId(client);
    if (g_Stats[client].steamId[0] == '\0')
    {
        return 0;
    }

    EnsureClientStatsLoadedForPoints(client);

    int selfKills = (g_Stats[client].kills > 0) ? g_Stats[client].kills : 0;
    int selfDeaths = (g_Stats[client].deaths > 0) ? g_Stats[client].deaths : 0;
    if ((selfKills + selfDeaths) <= WHALE_POINTS_MIN_KD_SUM)
    {
        return 0;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    EscapeSqlString(g_Stats[client].steamId, escapedSteamId, sizeof(escapedSteamId));

    int selfPoints = GetWhalePointsForClient(client);
    if (selfPoints < 0)
    {
        selfPoints = 0;
    }

    char query[1600];
    Format(query, sizeof(query),
        "SELECT 1 + COUNT(*) FROM whaletracker w "
        ... "WHERE (GREATEST(w.kills,0) + GREATEST(w.deaths,0)) > %d "
        ... "AND (((%s) > %d) "
        ... "OR (((%s) = %d) AND w.steamid < '%s'))",
        WHALE_POINTS_MIN_KD_SUM,
        WHALE_POINTS_SQL_EXPR,
        selfPoints,
        WHALE_POINTS_SQL_EXPR,
        selfPoints,
        escapedSteamId);

    DBResultSet results = SQL_Query(g_hDatabase, query);
    if (results == null)
    {
        char error[256];
        SQL_GetError(g_hDatabase, error, sizeof(error));
        LogError("[WhaleTracker] WhalePoints rank query failed: %s", error);
        return 0;
    }

    if (!SQL_HasResultSet(results) || !results.FetchRow())
    {
        delete results;
        return 0;
    }

    int rank = results.FetchInt(0);
    delete results;
    if (rank < 1)
    {
        rank = 1;
    }
    return rank;
}

public any Native_WhaleTracker_GetCumulativeKills(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client <= 0 || client > MaxClients)
    {
        return 0;
    }

    return g_Stats[client].kills;
}

public any Native_WhaleTracker_AreStatsLoaded(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return (client > 0 && client <= MaxClients && g_Stats[client].loaded);
}

public any Native_WhaleTracker_GetWhalePoints(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return GetWhalePointsForClient(client);
}
