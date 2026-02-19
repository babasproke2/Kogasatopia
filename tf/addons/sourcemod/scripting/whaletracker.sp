#pragma semicolon 1
/*
 * =============================================================================
 *  WhaleTracker (modular single-source layout)
 * =============================================================================
 *  This file is the entry point and shared symbol container for WhaleTracker.
 *  The implementation is split into:
 *    - include/whaletracker.inc                 (shared helpers/utilities)
 *    - whaletracker/runtime_whaletracker.sp     (plugin lifecycle/runtime)
 *    - whaletracker/database_whaletracker.sp    (schema/load/save/migrations)
 *    - whaletracker/gameplay_whaletracker.sp    (event/game stat tracking)
 *    - whaletracker/commands_whaletracker.sp    (chat/admin commands)
 *
 *  Compatibility is controlled by convars so one codebase can run on TF2 and
 *  TF2C without maintaining separate plugins. See:
 *    sm_whaletracker_enable_sdkhooks
 *    sm_whaletracker_headshot_mode
 *    sm_whaletracker_enable_matchlogs
 *    sm_whaletracker_public_ip_mode
 *    sm_whaletracker_public_ip
 *    sm_whaletracker_medicdrop_mode
 *    sm_whaletracker_deferred_save_pump
 * =============================================================================
 */

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <morecolors>
#undef REQUIRE_EXTENSIONS
#include <SteamWorks>
#define REQUIRE_EXTENSIONS
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
#define WT_HEADSHOT_MODE_DAMAGE 0
#define WT_HEADSHOT_MODE_DEATH 1
#define WT_PUBLIC_IP_MODE_STEAMWORKS 0
#define WT_PUBLIC_IP_MODE_MANUAL 1
#define WT_MEDICDROP_MODE_SLOT 0
#define WT_MEDICDROP_MODE_SCAN 1

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("SDKHook");
    MarkNativeAsOptional("SDKUnhook");
    MarkNativeAsOptional("SteamWorks_GetPublicIP");
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
}

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
}
#define WEAPON_CATEGORY_COUNT 8

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom);

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
ConVar g_hEnableSdkHooks = null;
ConVar g_hHeadshotMode = null;
ConVar g_hEnableMatchLogs = null;
ConVar g_hPublicIpMode = null;
ConVar g_hPublicIpManual = null;
ConVar g_hMedicDropMode = null;
ConVar g_hDeferredSavePump = null;
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
Handle g_hSavePumpTimer = null;

char g_SaveQueryBuffers[MAX_CONCURRENT_SAVE_QUERIES][SAVE_QUERY_MAXLEN];
int g_SaveQueryUserIds[MAX_CONCURRENT_SAVE_QUERIES];
bool g_SaveQuerySlotUsed[MAX_CONCURRENT_SAVE_QUERIES];

#include <whaletracker>
#include "whaletracker/runtime_whaletracker.sp"
#include "whaletracker/database_whaletracker.sp"
#include "whaletracker/gameplay_whaletracker.sp"
#include "whaletracker/commands_whaletracker.sp"
