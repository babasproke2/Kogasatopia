#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools_gamerules>

#include <tf2_stocks>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <filters_api>
#include <points_store_api>
#include <tags_api>
#define REQUIRE_PLUGIN


#include "include/kogasa_sql.inc"
#include "include/kogasa_steam_identity.inc"

#define PLUGIN_NAME               "Clans"
#define PLUGIN_AUTHOR             "Draggy"
#define PLUGIN_VERSION            "1.0.0"
#define PLUGIN_URL                "https://kogasa.tf"

#define CLAN_CREATE_GEM_COST      650
#define INVITE_EXPIRE_SECONDS     604800
#define CLAN_WAR_EXPIRE_SECONDS   604800
#define CLAN_WAR_REDECLARE_COOLDOWN_SECONDS 3600
#define CLAN_WAR_FLUSH_INTERVAL   3.0
#define CLAN_DB_RECONNECT_INITIAL_INTERVAL 5.0
#define CLAN_DB_RECONNECT_MAX_INTERVAL 60.0
#define CLAN_DB_KEEPALIVE_INTERVAL 300.0
#define CLAN_WAR_POINT_GOAL       50
#define CLAN_WAR_GEMS_STOLEN_PER_KILL 3
#define CLAN_NAME_MAXLEN          48
#define CLAN_DESC_MAXLEN          128
#define CLAN_TAG_MAXLEN           64
#define CLAN_TAG_STORE_MAXLEN     (CLAN_TAG_MAXLEN + 1)
#define STEAMID64_MAXLEN          32
#define SQL_STEAMID64_MAXLEN      ((STEAMID64_MAXLEN * 2) + 1)
#define SQL_CLAN_NAME_MAXLEN      ((CLAN_NAME_MAXLEN * 2) + 1)
#define SQL_CLAN_DESC_MAXLEN      ((CLAN_DESC_MAXLEN * 2) + 1)
#define SQL_CLAN_TAG_MAXLEN       ((CLAN_TAG_MAXLEN * 2) + 1)
#define CLAN_SUB_TAG_MAXLEN       64
#define CLAN_SUB_TAG_STORE_MAXLEN (CLAN_SUB_TAG_MAXLEN + 1)
#define SQL_CLAN_SUB_TAG_MAXLEN   ((CLAN_SUB_TAG_MAXLEN * 2) + 1)
#define CLAN_HISTORY_SUMMARY_MAXLEN 255
#define SQL_CLAN_HISTORY_SUMMARY_MAXLEN ((CLAN_HISTORY_SUMMARY_MAXLEN * 2) + 1)
#define CLAN_TAG_FORMAT_OVERHEAD  17 // Stored tag format: "[{gold}" + raw tag + "{default}]"
#define CLAN_TAG_PLAYER_MAXLEN    32
#define CLAN_TAG_ADMIN_MAXLEN     64
#define CLAN_TAGS_JOINED_MAXLEN   4096
#define INVITE_CLEANUP_INTERVAL   300.0
#define CLAN_MENU_TIME            MENU_TIME_FOREVER

enum ClanRank
{
    ClanRank_Member = 0,
    ClanRank_Officer,
    ClanRank_Owner
};

enum PromptState
{
    Prompt_None = 0,
    Prompt_ClanCreateName,
    Prompt_ClanRenameName,
    Prompt_ClanLeaveConfirm,
    Prompt_ClanTagChoice,
    Prompt_ClanTagInput,
    Prompt_ClanSubTagInput,
    Prompt_ClanDescInput,
    Prompt_ClanAdminDescInput
};

enum InviteMenuMode
{
    InviteMenu_Accept = 0,
    InviteMenu_Deny
};

enum ClanByPlayerCols
{
    ClanByPlayerCol_Id = 0,
    ClanByPlayerCol_Name,
    ClanByPlayerCol_Tag,
    ClanByPlayerCol_Owner,
    ClanByPlayerCol_IsOpen,
    ClanByPlayerCol_CreatedAt,
    ClanByPlayerCol_Rank,
    ClanByPlayerCol_JoinedAt
};

enum PendingInviteCols
{
    PendingInviteCol_Id = 0,
    PendingInviteCol_ClanId,
    PendingInviteCol_ClanName,
    PendingInviteCol_ClanTag,
    PendingInviteCol_InvitedBy,
    PendingInviteCol_ExpiresAt
};

enum ClanMenuContextCols
{
    ClanMenuCol_ClanId = 0,
    ClanMenuCol_Rank,
    ClanMenuCol_ClanName,
    ClanMenuCol_ClanTag,
    ClanMenuCol_IsOpen,
    ClanMenuCol_InviteCount
};

enum ClanMemberListCols
{
    ClanMemberListCol_SteamId64 = 0,
    ClanMemberListCol_Rank,
    ClanMemberListCol_JoinedAt,
    ClanMemberListCol_SubTag
};

enum ClanWarStatus
{
    ClanWarStatus_Active = 0,
    ClanWarStatus_Finished,
    ClanWarStatus_Expired,
    ClanWarStatus_Surrendered
};

enum struct ActiveClanWar
{
    int warId;
    int instanceId;
    int clanIdA;
    int clanIdB;
    int scoreA;
    int scoreB;
    int createdAt;
    int expiresAt;
    bool writeDirty;
    bool writePending;
    bool finalizePending;
    bool finalizeWritePending;
    int finalizeWinnerClanId;
    ClanWarStatus finalizeStatus;
    int finalizeFinishedAt;
    char announceLabelA[96];
    char announceLabelB[96];
    char historyLabelA[96];
    char historyLabelB[96];
}

enum struct PendingClanWarKillDelta
{
    int warInstanceId;
    int clanId;
    int kills;
    int currencyStolen;
    char steamid64[STEAMID64_MAXLEN];
}

#include "clans/clans_chat.inc"

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "Minecraft-style clans/factions scaffold backed by SQL",
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("clans");
    CreateNative("Clans_GetTags", Native_Clans_GetTags);
    CreateNative("Clans_GetSameTeamClanMemberCount", Native_Clans_GetSameTeamClanMemberCount);
    MarkNativeAsOptional("Filters_GetChatName");
    MarkNativeAsOptional("Filters_GetLastRecordedSteamName");
    MarkNativeAsOptional("PointsStore_RefundBonusPoints");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("PointsStore_StealBonusPoints");
    MarkNativeAsOptional("DGM_IsRoundRunning");
    MarkNativeAsOptional("Tags_GetTag");
    MarkNativeAsOptional("Tags_SetSelectedTag");
    return APLRes_Success;
}

bool IsClanGemStoreAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_RefundBonusPoints") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available;
}

bool GiveClanGems(int client, int gems)
{
    if (!IsClanGemStoreAvailable())
    {
        return false;
    }

    return PointsStore_RefundBonusPoints(client, gems, "clan_gems");
}

bool SpendClanGems(int client, int gems)
{
    if (!IsClanGemStoreAvailable())
    {
        return false;
    }

    return PointsStore_SpendBonusPoints(client, gems);
}

bool IsClanGemStealAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_StealBonusPoints") == FeatureStatus_Available;
}

int StealClanWarGems(int attacker, int victim, int gems)
{
    if (!IsClanGemStealAvailable())
    {
        return 0;
    }

    return PointsStore_StealBonusPoints(victim, attacker, gems, "clan_war_steal");
}

Database g_Database = null;
bool g_bDatabaseReady = false;
char g_sDbDriver[16];
ConVar g_cvDatabaseConfig = null;
ConVar g_cvClanWarsEnabled = null;
Handle g_hInviteCleanupTimer = null;
Handle g_hClanWarFlushTimer = null;
Handle g_hDbReconnectTimer = null;
Handle g_hDbKeepaliveTimer = null;
Handle g_hDbInitTimer = null;
StringMap g_hClanIdCache = null;
bool g_bClanIdCacheReady = false;
ArrayList g_hActiveWars = null;
bool g_bActiveWarCacheReady = false;
ArrayList g_hPendingClanWarKillDeltas = null;
bool g_bClanWarKillFlushInFlight = false;
float g_flDbReconnectDelay = CLAN_DB_RECONNECT_INITIAL_INTERVAL;

PromptState g_PromptState[MAXPLAYERS + 1];
int g_PendingAdminClanDescId[MAXPLAYERS + 1];
char g_PendingAdminClanDescName[MAXPLAYERS + 1][CLAN_NAME_MAXLEN + 1];
int g_iClientClanId[MAXPLAYERS + 1];
bool g_bClientClanLoaded[MAXPLAYERS + 1];
bool g_bClientClanLoadPending[MAXPLAYERS + 1];
ClanRank g_ClientClanRank[MAXPLAYERS + 1];
char g_sClientClanName[MAXPLAYERS + 1][CLAN_NAME_MAXLEN + 1];
char g_sClientClanTag[MAXPLAYERS + 1][CLAN_TAG_STORE_MAXLEN];
char g_sClientClanTags[MAXPLAYERS + 1][CLAN_TAGS_JOINED_MAXLEN];
bool g_bClientClanTagsLoaded[MAXPLAYERS + 1];
bool g_bClientClanTagsPending[MAXPLAYERS + 1];
int g_iClanMembersMenuClanId[MAXPLAYERS + 1];
char g_sClanMembersMenuClanName[MAXPLAYERS + 1][CLAN_NAME_MAXLEN + 1];
int g_iClanHistoryMenuClanId[MAXPLAYERS + 1];
char g_sClanHistoryMenuClanName[MAXPLAYERS + 1][CLAN_NAME_MAXLEN + 1];

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    g_cvDatabaseConfig = CreateConVar("sm_clans_database", "default", "Database config name from databases.cfg to use for clans.");
    g_cvClanWarsEnabled = CreateConVar("sm_clans_wars_enabled", "1", "Enable clan wars. Disable this to fail closed during database instability.", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "clans");

    RegConsoleCmd("sm_clan", Command_ClanMenu, "Open the clan menu.");
    RegConsoleCmd("sm_clans", Command_ClansList, "Browse clans.");
    RegConsoleCmd("sm_clanhelp", Command_ClanHelp, "Show a clan command summary.");
    RegConsoleCmd("sm_clancreate", Command_ClanCreate, "Create a clan.");
    RegConsoleCmd("sm_clanleave", Command_ClanLeave, "Leave your clan or delete it if you are the owner.");
    RegConsoleCmd("sm_claninvite", Command_ClanInvite, "Invite a player to your clan.");
    RegConsoleCmd("sm_clankick", Command_ClanKick, "Kick a player from your clan.");
    RegConsoleCmd("sm_clantag", Command_ClanTag, "Set your clan tag or personal sub-tag.");
    RegConsoleCmd("sm_clanjoin", Command_ClanJoin, "Join an open clan.");
    RegConsoleCmd("sm_clanparent", Command_ClanParent, "Set or clear your clan's parent relation.");
    RegConsoleCmd("sm_clanmembers", Command_ClanMembers, "Show clan members.");
    RegConsoleCmd("sm_claninfo", Command_ClanInfo, "Show clan info.");
    RegConsoleCmd("sm_clangems", Command_ClanGems, "Show clan Gems.");
    RegConsoleCmd("sm_clangem", Command_ClanGems, "Show clan Gems.");
    RegConsoleCmd("sm_clanpts", Command_ClanGems, "Show clan Gems.");
    RegConsoleCmd("sm_clanpoints", Command_ClanGems, "Show clan Gems.");
    RegConsoleCmd("sm_claninvites", Command_ClanInvites, "Show pending clan invites.");
    RegConsoleCmd("sm_clandesc", Command_ClanDesc, "Set your clan description.");
    RegConsoleCmd("sm_clanrename", Command_ClanRename, "Rename your clan.");
    RegConsoleCmd("sm_cc", Command_ClanChat, "Send a message to your clan.");
    RegConsoleCmd("sm_clanwar", Command_ClanWar, "Declare war on another clan or surrender an active war.");
    RegConsoleCmd("sm_clanhistory", Command_ClanHistory, "Show recent clan history.");
    RegAdminCmd("sm_clansetdesc", Command_ClanSetDesc, ADMFLAG_GENERIC, "Set any clan description.");

    /* Extra owner utility so open-clan menus are actually usable. */
    RegConsoleCmd("sm_clanopen", Command_ClanOpen, "Toggle whether your clan is open to direct joins.");

    /* Chat trigger aliases for invites. */
    RegConsoleCmd("sm_accept", Command_ClanAcceptInvite, "Accept a pending clan invite.");
    RegConsoleCmd("sm_yes", Command_ClanAcceptInvite, "Accept a pending clan invite.");
    RegConsoleCmd("sm_deny", Command_ClanDenyInvite, "Deny a pending clan invite.");

    AddCommandListener(CommandListener_Say, "say");
    AddCommandListener(CommandListener_Say, "say_team");
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    ConnectDatabase();
}

public void OnPluginEnd()
{
    if (g_hDbKeepaliveTimer != null)
    {
        delete g_hDbKeepaliveTimer;
        g_hDbKeepaliveTimer = null;
    }

    if (g_hDbInitTimer != null)
    {
        delete g_hDbInitTimer;
        g_hDbInitTimer = null;
    }

    if (g_hInviteCleanupTimer != null)
    {
        delete g_hInviteCleanupTimer;
        g_hInviteCleanupTimer = null;
    }

    FlushPendingClanWarPersistenceSync();

    if (g_hClanWarFlushTimer != null)
    {
        delete g_hClanWarFlushTimer;
        g_hClanWarFlushTimer = null;
    }

    if (g_hDbReconnectTimer != null)
    {
        delete g_hDbReconnectTimer;
        g_hDbReconnectTimer = null;
    }

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    if (g_hClanIdCache != null)
    {
        delete g_hClanIdCache;
        g_hClanIdCache = null;
    }

    if (g_hActiveWars != null)
    {
        delete g_hActiveWars;
        g_hActiveWars = null;
    }

    if (g_hPendingClanWarKillDeltas != null)
    {
        delete g_hPendingClanWarKillDeltas;
        g_hPendingClanWarKillDeltas = null;
    }
}

public void OnClientDisconnect(int client)
{
    ResetClientState(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsPlayableClient(client))
    {
        return;
    }

    RequestClientClanIdLoad(client);
    RequestClientClanTagsLoad(client);
}

void ResetClientState(int client)
{
    g_PromptState[client] = Prompt_None;
    g_PendingAdminClanDescId[client] = 0;
    g_PendingAdminClanDescName[client][0] = '\0';
    g_iClientClanId[client] = 0;
    g_bClientClanLoaded[client] = false;
    g_bClientClanLoadPending[client] = false;
    g_ClientClanRank[client] = ClanRank_Member;
    g_sClientClanName[client][0] = '\0';
    g_sClientClanTag[client][0] = '\0';
    g_sClientClanTags[client][0] = '\0';
    g_bClientClanTagsLoaded[client] = false;
    g_bClientClanTagsPending[client] = false;
    g_iClanMembersMenuClanId[client] = 0;
    g_sClanMembersMenuClanName[client][0] = '\0';
    g_iClanHistoryMenuClanId[client] = 0;
    g_sClanHistoryMenuClanName[client][0] = '\0';
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
        LogError("[Clans] Database connection failed: %s", error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    if (!ValidateDatabaseHandle(db))
    {
        delete db;
        ScheduleDatabaseReconnect(1.0);
        return;
    }

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }

    g_Database = db;
    g_Database.Driver.GetIdentifier(g_sDbDriver, sizeof(g_sDbDriver));
    g_bDatabaseReady = false;
    g_bClanIdCacheReady = false;
    g_flDbReconnectDelay = CLAN_DB_RECONNECT_INITIAL_INTERVAL;
    ResetActiveWarCache();

    if (!g_Database.SetCharset("utf8mb4"))
    {
        LogError("[Clans] Failed to set utf8mb4 charset");
    }

    ScheduleDatabaseInitialization();
}

void ScheduleDatabaseInitialization()
{
    if (g_hDbInitTimer != null)
    {
        delete g_hDbInitTimer;
        g_hDbInitTimer = null;
    }

    g_hDbInitTimer = CreateTimer(0.5, Timer_FinishDatabaseInitialization);
}

public Action Timer_FinishDatabaseInitialization(Handle timer, any data)
{
    if (timer == g_hDbInitTimer)
    {
        g_hDbInitTimer = null;
    }

    FinishDatabaseInitialization();
    return Plugin_Stop;
}

void FinishDatabaseInitialization()
{
    if (g_Database == null)
    {
        return;
    }

    g_bDatabaseReady = true;
    EnsureClanWarMemberKillsSchema();

    if (!g_bActiveWarCacheReady || g_hActiveWars == null)
    {
        if (!LoadActiveClanWarsCacheSync() && !EnsureDatabaseReady())
        {
            return;
        }
    }
    if (!EnsureDatabaseReady())
    {
        return;
    }

    CleanupExpiredWars();
    if (!EnsureDatabaseReady())
    {
        return;
    }

    RebuildClanIdCache();
    if (!EnsureDatabaseReady())
    {
        return;
    }

    FlushPendingClanWarPersistenceSync();
    if (!EnsureDatabaseReady())
    {
        return;
    }

    if (g_hInviteCleanupTimer == null)
    {
        g_hInviteCleanupTimer = CreateTimer(INVITE_CLEANUP_INTERVAL, Timer_CleanupExpiredInvites, 0, TIMER_REPEAT);
    }

    if (g_hClanWarFlushTimer == null)
    {
        g_hClanWarFlushTimer = CreateTimer(CLAN_WAR_FLUSH_INTERVAL, Timer_FlushClanWarDeltas, 0, TIMER_REPEAT);
    }

    StartDatabaseKeepaliveTimer();
    PrintToServer("[Clans] Database ready using driver '%s'.", g_sDbDriver);

    CleanupExpiredInvites();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            RequestClientClanIdLoad(i);
            RequestClientClanTagsLoad(i);
        }
    }
}

bool IsMySql()
{
    return StrEqual(g_sDbDriver, "mysql", false);
}

void EnsureClanWarMemberKillsSchema()
{
    if (g_Database == null)
    {
        return;
    }

    if (IsMySql())
    {
        SQL_FastQuery(g_Database, "ALTER TABLE clan_war_member_kills ADD COLUMN IF NOT EXISTS currency_stolen INT NOT NULL DEFAULT 0");
    }
}

bool IsDatabaseConnectionLostError(const char[] error)
{
    return KogasaSql_IsTransientError(error);
}

bool ValidateDatabaseHandle(Database db)
{
    if (db == null)
    {
        return false;
    }

    if (SQL_FastQuery(db, "SELECT 1"))
    {
        return true;
    }

    char error[256];
    SQL_GetError(db, error, sizeof(error));
    if (!IsDatabaseConnectionLostError(error))
    {
        LogError("[Clans] Database validation failed: %s", error);
    }

    return false;
}

void StopDatabaseKeepaliveTimer()
{
    if (g_hDbKeepaliveTimer != null)
    {
        delete g_hDbKeepaliveTimer;
        g_hDbKeepaliveTimer = null;
    }
}

void StartDatabaseKeepaliveTimer()
{
    if (g_hDbKeepaliveTimer != null)
    {
        return;
    }

    g_hDbKeepaliveTimer = CreateTimer(CLAN_DB_KEEPALIVE_INTERVAL, Timer_DatabaseKeepalive, 0, TIMER_REPEAT);
}

void DropDatabaseConnection()
{
    StopDatabaseKeepaliveTimer();
    if (g_hDbInitTimer != null)
    {
        delete g_hDbInitTimer;
        g_hDbInitTimer = null;
    }

    g_bDatabaseReady = false;
    g_bClanIdCacheReady = false;

    if (g_Database != null)
    {
        delete g_Database;
        g_Database = null;
    }
}

bool HasUsableResultSet(DBResultSet results)
{
    return (results != null && SQL_HasResultSet(results));
}

void ScheduleDatabaseReconnect(float delay = -1.0)
{
    if (g_hDbReconnectTimer != null)
    {
        return;
    }

    if (delay < 0.0)
    {
        delay = g_flDbReconnectDelay;
    }

    if (delay < CLAN_DB_RECONNECT_INITIAL_INTERVAL)
    {
        delay = CLAN_DB_RECONNECT_INITIAL_INTERVAL;
    }

    g_hDbReconnectTimer = CreateTimer(delay, Timer_ReconnectDatabase);

    g_flDbReconnectDelay *= 2.0;
    if (g_flDbReconnectDelay > CLAN_DB_RECONNECT_MAX_INTERVAL)
    {
        g_flDbReconnectDelay = CLAN_DB_RECONNECT_MAX_INTERVAL;
    }
}

public Action Timer_ReconnectDatabase(Handle timer, any data)
{
    if (timer == g_hDbReconnectTimer)
    {
        g_hDbReconnectTimer = null;
    }

    ConnectDatabase();
    return Plugin_Stop;
}

public Action Timer_DatabaseKeepalive(Handle timer, any data)
{
    if (timer != g_hDbKeepaliveTimer)
    {
        return Plugin_Stop;
    }

    if (g_Database == null || !g_bDatabaseReady)
    {
        return Plugin_Continue;
    }

    g_Database.Query(SQL_OnDatabaseKeepalive, "SELECT 1");
    return Plugin_Continue;
}

public void SQL_OnDatabaseKeepalive(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Clans] Database keepalive failed: %s", error);
        HandleDatabaseConnectionLoss(error);
    }
}

void HandleDatabaseConnectionLoss(const char[] error)
{
    if (!IsDatabaseConnectionLostError(error))
    {
        return;
    }

    DropDatabaseConnection();
    ScheduleDatabaseReconnect();
}

bool EnsureDatabaseReady(int client = 0)
{
    if (g_Database != null && g_bDatabaseReady)
    {
        return true;
    }

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Database is not ready yet. Please try again in a moment.");
    }

    return false;
}


bool Clans_IsRoundRunning()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_IsRoundRunning") == FeatureStatus_Available)
    {
        return DGM_IsRoundRunning();
    }

    return GameRules_GetRoundState() == RoundState_RoundRunning;
}

bool IsPlayableClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client));
}

bool GetClientSteam64(int client, char[] steamid64, int maxlen)
{
    steamid64[0] = '\0';

    if (!IsPlayableClient(client))
    {
        return false;
    }

    return Kogasa_GetClientSteamId64(client, steamid64, maxlen, true);
}

int FindClientBySteam64(const char[] steamid64)
{
    return Kogasa_FindClientBySteamId64(steamid64, true);
}

void ResolvePlayerDisplayName(const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    int client = FindClientBySteam64(steamid64);
    if (client > 0)
    {
        GetClientName(client, buffer, maxlen);
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetLastRecordedSteamName") == FeatureStatus_Available
        && Filters_GetLastRecordedSteamName(steamid64, buffer, maxlen) && buffer[0] != '\0')
    {
        return;
    }

    strcopy(buffer, maxlen, steamid64);
}

int FindClientByNameQuery(const char[] query)
{
    int partialClient = 0;
    int partialCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsPlayableClient(client))
        {
            continue;
        }

        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));

        if (StrEqual(name, query, false))
        {
            return client;
        }

        if (StrContains(name, query, false) != -1)
        {
            partialClient = client;
            partialCount++;
        }
    }

    return (partialCount == 1) ? partialClient : 0;
}

void EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    KogasaSql_Escape(g_Database, input, output, maxlen, "Clans");
}

void GetClanRankLabel(ClanRank rank, char[] buffer, int maxlen)
{
    if (rank >= ClanRank_Owner)
    {
        strcopy(buffer, maxlen, "Hokage");
        return;
    }

    if (rank >= ClanRank_Officer)
    {
        strcopy(buffer, maxlen, "Officer");
        return;
    }

    strcopy(buffer, maxlen, "Member");
}

static bool TryGetSelectedTag(int client, const char[] steamid64, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Tags_GetTag") != FeatureStatus_Available)
    {
        return false;
    }

    if (client > 0 && IsClientInGame(client))
    {
        return Tags_GetTag(client, "", buffer, maxlen) && buffer[0] != '\0';
    }

    return Tags_GetTag(0, steamid64, buffer, maxlen) && buffer[0] != '\0';
}

static void TrySetClanJoinSelectedTag(int client, const char[] clanTag)
{
    if (!IsPlayableClient(client))
    {
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, "Tags_SetSelectedTag") != FeatureStatus_Available)
    {
        return;
    }

    char selectedTag[CLAN_TAG_STORE_MAXLEN];
    ExtractRawClanTag(clanTag, selectedTag, sizeof(selectedTag));
    TrimString(selectedTag);
    if (!selectedTag[0] || !IsExportableClanTagText(selectedTag))
    {
        return;
    }

    Tags_SetSelectedTag(client, selectedTag);
}

static void BuildClanDisplayTag(const char[] rawTag, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!rawTag[0])
    {
        return;
    }

    if (rawTag[0] == '[')
    {
        strcopy(buffer, maxlen, rawTag);
        return;
    }

    FormatEx(buffer, maxlen, "[{gold}%s{default}]", rawTag);
}

static void BuildClanChatSenderName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available)
    {
        if (Filters_GetChatName(client, buffer, maxlen) && buffer[0] != '\0')
        {
            return;
        }
    }

    GetClientName(client, buffer, maxlen);
}

static void ResolveClientTeamColorTag(int client, char[] buffer, int maxlen)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    if (StrContains(buffer, "{teamcolor}", false) == -1)
    {
        return;
    }

    char replacement[16];
    switch (GetClientTeam(client))
    {
        case 2:
        {
            strcopy(replacement, sizeof(replacement), "{red}");
        }
        case 3:
        {
            strcopy(replacement, sizeof(replacement), "{blue}");
        }
        default:
        {
            strcopy(replacement, sizeof(replacement), "{default}");
        }
    }

    ReplaceString(buffer, maxlen, "{teamcolor}", replacement, false);
}

static bool IsConnectedClientInClan(int client, int clanId)
{
    if (!IsPlayableClient(client))
    {
        return false;
    }

    if (g_bClientClanLoaded[client] && g_iClientClanId[client] == clanId)
    {
        return true;
    }

    char steamid64[STEAMID64_MAXLEN];
    int cachedClanId = 0;
    return GetClientSteam64(client, steamid64, sizeof(steamid64))
        && GetCachedClanIdForSteam64(steamid64, cachedClanId)
        && cachedClanId == clanId;
}

static void BuildClanMemberMenuLabel(const char[] viewerSteamId64, const char[] memberSteamId64, ClanRank rank, char[] buffer, int maxlen)
{
    char name[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(memberSteamId64, name, sizeof(name));

    char rankLabel[16];
    GetClanRankLabel(rank, rankLabel, sizeof(rankLabel));

    if (viewerSteamId64[0] != '\0' && StrEqual(viewerSteamId64, memberSteamId64, false))
    {
        FormatEx(buffer, maxlen, "%s (You)", name);
        return;
    }

    FormatEx(buffer, maxlen, "%s (%s)", name, rankLabel);
}

static void FormatClanTimestamp(int timestamp, char[] buffer, int maxlen)
{
    if (timestamp > 0)
    {
        FormatTime(buffer, maxlen, "%Y-%m-%d %H:%M:%S", timestamp);
        return;
    }

    strcopy(buffer, maxlen, "Unknown");
}

void QueryClanMemberDetailsForClient(int userId, int clanId, const char[] clanName, const char[] steamid64)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT cm.rank, cm.joined_at, COALESCE(cst.tag, ''), "
        ... "COALESCE((SELECT SUM(cwmk.kills) FROM clan_war_member_kills cwmk WHERE cwmk.steamid64 = cm.steamid64), 0) "
        ... "FROM clan_members cm "
        ... "LEFT JOIN clan_sub_tags cst ON cst.clan_id = cm.clan_id AND cst.steamid64 = cm.steamid64 "
        ... "WHERE cm.clan_id = %d AND cm.steamid64 = '%s' "
        ... "LIMIT 1",
        clanId,
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteCell(clanId);
    pack.WriteString(clanName);
    pack.WriteString(steamid64);

    g_Database.Query(SQL_OnClanMemberDetails, query, pack);
}

bool GetClanWarInstanceIdSync(int warId, int createdAt, int &instanceId)
{
    instanceId = 0;

    if (!EnsureDatabaseReady() || warId <= 0 || createdAt <= 0)
    {
        return false;
    }

    char query[192];
    FormatEx(query, sizeof(query),
        "SELECT id FROM clan_war_instances WHERE war_id = %d AND created_at = %d LIMIT 1",
        warId,
        createdAt);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch war instance %d/%d: %s", warId, createdAt, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (results.FetchRow())
    {
        instanceId = results.FetchInt(0);
    }

    delete results;
    return (instanceId > 0);
}

bool EnsureClanWarInstanceSync(int warId, int clanIdA, int clanIdB, int createdAt, int &instanceId)
{
    instanceId = 0;

    if (!EnsureDatabaseReady() || warId <= 0 || clanIdA <= 0 || clanIdB <= 0 || createdAt <= 0)
    {
        return false;
    }

    if (GetClanWarInstanceIdSync(warId, createdAt, instanceId))
    {
        return true;
    }

    if (!EnsureDatabaseReady() || g_Database == null)
    {
        return false;
    }

    char query[384];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_war_instances (war_id, clan_id_a, clan_id_b, score_a, score_b, winner_clan_id, status, created_at, finished_at) "
        ... "VALUES (%d, %d, %d, 0, 0, NULL, %d, %d, NULL)",
        warId,
        clanIdA,
        clanIdB,
        view_as<int>(ClanWarStatus_Active),
        createdAt);

    if (!SQL_FastQuery(g_Database, query))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to create war instance for %d/%d: %s", warId, createdAt, error);
        HandleDatabaseConnectionLoss(error);
        return false;
    }

    return GetClanWarInstanceIdSync(warId, createdAt, instanceId);
}

void UpdateClanWarInstanceFinalState(int instanceId, int scoreA, int scoreB, int winnerClanId, ClanWarStatus status, int finishedAt)
{
    if (instanceId <= 0 || !EnsureDatabaseReady())
    {
        return;
    }

    char winnerValue[16];
    if (winnerClanId > 0)
    {
        IntToString(winnerClanId, winnerValue, sizeof(winnerValue));
    }
    else
    {
        strcopy(winnerValue, sizeof(winnerValue), "NULL");
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "UPDATE clan_war_instances SET score_a = %d, score_b = %d, winner_clan_id = %s, status = %d, finished_at = %d "
        ... "WHERE id = %d",
        scoreA,
        scoreB,
        winnerValue,
        view_as<int>(status),
        finishedAt,
        instanceId);

    g_Database.Query(SQL_GenericQueryCallback, query);
}

void QueueClanWarKillDelta(int warInstanceId, int clanId, const char[] steamid64, int kills = 1, int currencyStolen = 0)
{
    if (warInstanceId <= 0 || clanId <= 0 || !steamid64[0] || kills <= 0)
    {
        return;
    }

    if (g_hPendingClanWarKillDeltas == null)
    {
        g_hPendingClanWarKillDeltas = new ArrayList(sizeof(PendingClanWarKillDelta));
    }

    PendingClanWarKillDelta delta;
    for (int i = 0; i < g_hPendingClanWarKillDeltas.Length; i++)
    {
        g_hPendingClanWarKillDeltas.GetArray(i, delta);
        if (delta.warInstanceId != warInstanceId || delta.clanId != clanId || !StrEqual(delta.steamid64, steamid64, false))
        {
            continue;
        }

        delta.kills += kills;
        delta.currencyStolen += currencyStolen;
        g_hPendingClanWarKillDeltas.SetArray(i, delta);
        return;
    }

    delta.warInstanceId = warInstanceId;
    delta.clanId = clanId;
    delta.kills = kills;
    delta.currencyStolen = currencyStolen;
    strcopy(delta.steamid64, sizeof(delta.steamid64), steamid64);
    g_hPendingClanWarKillDeltas.PushArray(delta);
}

void RecordClanWarKill(int warInstanceId, int clanId, const char[] steamid64, int currencyStolen = 0)
{
    QueueClanWarKillDelta(warInstanceId, clanId, steamid64, 1, currencyStolen);
}

bool FlushPendingClanWarKillWritesSync()
{
    if (!EnsureDatabaseReady() || g_hPendingClanWarKillDeltas == null || g_bClanWarKillFlushInFlight)
    {
        return false;
    }

    if (g_hPendingClanWarKillDeltas.Length <= 0)
    {
        return true;
    }

    ArrayList batch = g_hPendingClanWarKillDeltas;
    g_hPendingClanWarKillDeltas = new ArrayList(sizeof(PendingClanWarKillDelta));
    g_bClanWarKillFlushInFlight = true;
    FlushNextClanWarKillDelta(batch, 0);
    return true;
}

void RequeueClanWarKillBatch(ArrayList batch, int startIndex)
{
    if (batch == null)
    {
        return;
    }

    PendingClanWarKillDelta delta;
    for (int i = startIndex; i < batch.Length; i++)
    {
        batch.GetArray(i, delta);
        QueueClanWarKillDelta(delta.warInstanceId, delta.clanId, delta.steamid64, delta.kills, delta.currencyStolen);
    }
}

void FlushNextClanWarKillDelta(ArrayList batch, int index)
{
    if (batch == null)
    {
        g_bClanWarKillFlushInFlight = false;
        return;
    }

    if (!EnsureDatabaseReady())
    {
        RequeueClanWarKillBatch(batch, index);
        delete batch;
        g_bClanWarKillFlushInFlight = false;
        return;
    }

    if (index >= batch.Length)
    {
        delete batch;
        g_bClanWarKillFlushInFlight = false;
        return;
    }

    PendingClanWarKillDelta delta;
    batch.GetArray(index, delta);

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(delta.steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    if (IsMySql())
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO clan_war_member_kills (war_instance_id, clan_id, steamid64, kills, currency_stolen) "
            ... "VALUES (%d, %d, '%s', %d, %d) "
            ... "ON DUPLICATE KEY UPDATE kills = kills + %d, currency_stolen = currency_stolen + %d, clan_id = VALUES(clan_id)",
            delta.warInstanceId,
            delta.clanId,
            escapedSteam,
            delta.kills,
            delta.currencyStolen,
            delta.kills,
            delta.currencyStolen);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO clan_war_member_kills (war_instance_id, clan_id, steamid64, kills, currency_stolen) "
            ... "VALUES (%d, %d, '%s', %d, %d) "
            ... "ON CONFLICT(war_instance_id, steamid64) DO UPDATE SET kills = clan_war_member_kills.kills + %d, currency_stolen = clan_war_member_kills.currency_stolen + %d, clan_id = excluded.clan_id",
            delta.warInstanceId,
            delta.clanId,
            escapedSteam,
            delta.kills,
            delta.currencyStolen,
            delta.kills,
            delta.currencyStolen);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(batch);
    pack.WriteCell(index);
    g_Database.Query(SQL_OnClanWarKillDeltaWritten, query, pack);
}

public void SQL_OnClanWarKillDeltaWritten(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    ArrayList batch = view_as<ArrayList>(pack.ReadCell());
    int index = pack.ReadCell();
    delete pack;

    PendingClanWarKillDelta delta;
    batch.GetArray(index, delta);

    if (error[0])
    {
        LogError("[Clans] Failed to persist war kill delta for instance %d/%s: %s", delta.warInstanceId, delta.steamid64, error);
        HandleDatabaseConnectionLoss(error);
        RequeueClanWarKillBatch(batch, index);
        delete batch;
        g_bClanWarKillFlushInFlight = false;
        return;
    }

    FlushNextClanWarKillDelta(batch, index + 1);
}

static void AnnounceClanInviteToMembers(int clanId, const char[] clanName, const char[] inviterSteam, const char[] targetSteam)
{
    DataPack pack = new DataPack();
    pack.WriteString(clanName);
    pack.WriteString(inviterSteam);
    pack.WriteString(targetSteam);

    GetClanMembers(clanId, SQL_OnAnnounceClanInviteToMembers, pack);
}

static void AnnounceClanInviteAcceptedToMembers(int clanId, const char[] clanName, const char[] accepterSteam)
{
    DataPack pack = new DataPack();
    pack.WriteString(clanName);
    pack.WriteString(accepterSteam);

    GetClanMembers(clanId, SQL_OnAnnounceClanInviteAcceptedToMembers, pack);
}

static int GetAllowedMainClanTagLength(int client)
{
    int allowed = CheckCommandAccess(client, "clans_long_tag", ADMFLAG_GENERIC, true) ? CLAN_TAG_ADMIN_MAXLEN : CLAN_TAG_PLAYER_MAXLEN;
    int storageSafe = CLAN_TAG_MAXLEN - CLAN_TAG_FORMAT_OVERHEAD;

    if (allowed > storageSafe)
    {
        allowed = storageSafe;
    }

    return allowed;
}

static int GetAllowedSubClanTagLength(int client)
{
    return CheckCommandAccess(client, "clans_long_tag", ADMFLAG_GENERIC, true) ? CLAN_TAG_ADMIN_MAXLEN : CLAN_TAG_PLAYER_MAXLEN;
}

static bool ValidateClanTagText(const char[] text, bool allowFormatting)
{
    if (!text[0])
    {
        return false;
    }

    int len = strlen(text);
    for (int i = 0; i < len;)
    {
        int ch = view_as<int>(text[i]) & 0xFF;

        if (ch < 0x20 || ch == 0x7F)
        {
            return false;
        }

        if (ch == '|')
        {
            return false;
        }

        if (!allowFormatting && (ch == '[' || ch == ']'))
        {
            return false;
        }

        if (ch < 0x80)
        {
            i++;
            continue;
        }

        int needed = 0;
        int codepoint = 0;
        int minimum = 0;

        if ((ch & 0xE0) == 0xC0)
        {
            needed = 2;
            codepoint = ch & 0x1F;
            minimum = 0x80;
        }
        else if ((ch & 0xF0) == 0xE0)
        {
            needed = 3;
            codepoint = ch & 0x0F;
            minimum = 0x800;
        }
        else if ((ch & 0xF8) == 0xF0)
        {
            needed = 4;
            codepoint = ch & 0x07;
            minimum = 0x10000;
        }
        else
        {
            return false;
        }

        if ((i + needed) > len)
        {
            return false;
        }

        for (int j = 1; j < needed; j++)
        {
            int continuation = view_as<int>(text[i + j]) & 0xFF;
            if ((continuation & 0xC0) != 0x80)
            {
                return false;
            }

            codepoint = (codepoint << 6) | (continuation & 0x3F);
        }

        if (codepoint < minimum || codepoint > 0x10FFFF)
        {
            return false;
        }

        if (codepoint >= 0xD800 && codepoint <= 0xDFFF)
        {
            return false;
        }

        i += needed;
    }

    return true;
}

static bool IsSafeClanTagText(const char[] text)
{
    return ValidateClanTagText(text, false);
}

static bool IsExportableClanTagText(const char[] text)
{
    return ValidateClanTagText(text, true);
}

static bool IsClanTagColorTokenAt(const char[] text, int start, int &end)
{
    end = start;

    if (text[start] != '{')
    {
        return false;
    }

    for (int i = start + 1; text[i] != '\0'; i++)
    {
        if (text[i] == '}')
        {
            end = i + 1;
            return i > start + 1;
        }

        if (text[i] == '{' || text[i] == '[' || text[i] == ']' || text[i] == '|')
        {
            return false;
        }
    }

    return false;
}

static void RemoveClanTagTextRange(char[] text, int start, int stop)
{
    int write = start;
    for (int read = stop; ; read++)
    {
        text[write++] = text[read];
        if (text[read] == '\0')
        {
            break;
        }
    }
}

static void NormalizeClanTagText(char[] text)
{
    TrimString(text);

    int tokenStart = 0;
    int tokenEnd = 0;
    while (IsClanTagColorTokenAt(text, tokenStart, tokenEnd))
    {
        int visibleStart = tokenEnd;
        while (text[visibleStart] == ' ')
        {
            visibleStart++;
        }

        if (visibleStart > tokenEnd)
        {
            RemoveClanTagTextRange(text, tokenEnd, visibleStart);
        }

        tokenStart = tokenEnd;
    }
}

static void FormatStoredClanTag(const char[] rawTag, char[] buffer, int maxlen)
{
    char normalized[CLAN_TAG_STORE_MAXLEN];
    strcopy(normalized, sizeof(normalized), rawTag);
    NormalizeClanTagText(normalized);

    FormatEx(buffer, maxlen, "[{gold}%s{default}]", normalized);
}

static void ExtractRawClanTag(const char[] storedTag, char[] buffer, int maxlen)
{
    static const char prefix[] = "[{gold}";
    static const char suffix[] = "{default}]";

    buffer[0] = '\0';

    if (!storedTag[0])
    {
        return;
    }

    int len = strlen(storedTag);
    int prefixLen = sizeof(prefix) - 1;
    int suffixLen = sizeof(suffix) - 1;

    if (len > (prefixLen + suffixLen))
    {
        bool prefixMatch = true;
        for (int i = 0; i < prefixLen; i++)
        {
            if (storedTag[i] != prefix[i])
            {
                prefixMatch = false;
                break;
            }
        }

        bool suffixMatch = true;
        for (int i = 0; i < suffixLen; i++)
        {
            if (storedTag[(len - suffixLen) + i] != suffix[i])
            {
                suffixMatch = false;
                break;
            }
        }

        if (prefixMatch && suffixMatch)
        {
            int rawLen = len - prefixLen - suffixLen;
            int copyLen = (rawLen < (maxlen - 1)) ? rawLen : (maxlen - 1);

            for (int i = 0; i < copyLen; i++)
            {
                buffer[i] = storedTag[prefixLen + i];
            }

            buffer[copyLen] = '\0';
            NormalizeClanTagText(buffer);
            return;
        }
    }

    strcopy(buffer, maxlen, storedTag);
    NormalizeClanTagText(buffer);
}

static bool AppendJoinedClanTag(char[] buffer, int maxlen, const char[] tag)
{
    if (!tag[0])
    {
        return false;
    }

    if (buffer[0])
    {
        StrCat(buffer, maxlen, "|");
    }

    StrCat(buffer, maxlen, tag);
    return true;
}

void ClearClientClanTagsCache(int client, bool loaded = false)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_sClientClanTags[client][0] = '\0';
    g_bClientClanTagsLoaded[client] = loaded;
    g_bClientClanTagsPending[client] = false;
}

void RequestClientClanTagsLoad(int client, bool force = false)
{
    if (!IsPlayableClient(client))
    {
        return;
    }

    if (!EnsureDatabaseReady())
    {
        return;
    }

    if (g_bClientClanTagsPending[client])
    {
        return;
    }

    if (!force && g_bClientClanTagsLoaded[client])
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        ClearClientClanTagsCache(client, true);
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT 0 AS sort_order, 0 AS created_at, c.tag "
        ... "FROM clan_members cm "
        ... "INNER JOIN clans c ON c.id = cm.clan_id "
        ... "WHERE cm.steamid64 = '%s' AND c.tag IS NOT NULL AND LENGTH(c.tag) > 0 "
        ... "UNION ALL "
        ... "SELECT 1 AS sort_order, cst.created_at, cst.tag "
        ... "FROM clan_members self_cm "
        ... "INNER JOIN clan_sub_tags cst ON cst.clan_id = self_cm.clan_id "
        ... "WHERE self_cm.steamid64 = '%s' AND cst.tag IS NOT NULL AND LENGTH(cst.tag) > 0 "
        ... "ORDER BY sort_order ASC, created_at ASC",
        escapedSteam,
        escapedSteam);

    g_sClientClanTags[client][0] = '\0';
    g_bClientClanTagsLoaded[client] = false;
    g_bClientClanTagsPending[client] = true;
    g_Database.Query(SQL_OnClientClanTagsLoaded, query, GetClientUserId(client));
}

public void SQL_OnClientClanTagsLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bClientClanTagsPending[client] = false;

    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Failed to load clan tags for %N: %s", client, error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    g_sClientClanTags[client][0] = '\0';

    char storedTag[CLAN_TAG_STORE_MAXLEN];
    char rawTag[CLAN_SUB_TAG_STORE_MAXLEN];
    while (results != null && results.FetchRow())
    {
        int sortOrder = results.FetchInt(0);
        results.FetchString(2, storedTag, sizeof(storedTag));
        TrimString(storedTag);

        if (!storedTag[0])
        {
            continue;
        }

        if (sortOrder == 0)
        {
            ExtractRawClanTag(storedTag, rawTag, sizeof(rawTag));
        }
        else
        {
            strcopy(rawTag, sizeof(rawTag), storedTag);
        }

        TrimString(rawTag);
        if (IsExportableClanTagText(rawTag))
        {
            AppendJoinedClanTag(g_sClientClanTags[client], sizeof(g_sClientClanTags[]), rawTag);
        }
    }

    g_bClientClanTagsLoaded[client] = true;
}

void RefreshConnectedClanTagsForClan(int clanId)
{
    if (clanId <= 0)
    {
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || g_iClientClanId[client] != clanId)
        {
            continue;
        }

        RequestClientClanTagsLoad(client, true);
    }
}

public any Native_Clans_GetTags(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int maxlen = GetNativeCell(3);

    char buffer[4096];
    buffer[0] = '\0';

    bool found = false;
    if (IsPlayableClient(client))
    {
        if (g_bClientClanTagsLoaded[client] && g_sClientClanTags[client][0])
        {
            strcopy(buffer, sizeof(buffer), g_sClientClanTags[client]);
            found = true;
        }
        else if (!g_bClientClanTagsPending[client])
        {
            RequestClientClanTagsLoad(client);
        }
    }

    SetNativeString(2, buffer, maxlen, true);
    return found;
}

public any Native_Clans_GetSameTeamClanMemberCount(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int team = (numParams >= 2) ? GetNativeCell(2) : 0;
    return GetSameTeamClanMemberCount(client, team);
}

void RebuildClanIdCache()
{
    g_bClanIdCacheReady = false;

    if (!EnsureDatabaseReady() || g_Database == null)
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query), "SELECT steamid64, clan_id FROM clan_members");
    g_Database.Query(SQL_OnClanIdCacheRebuilt, query);
}

public void SQL_OnClanIdCacheRebuilt(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Clans] Failed to rebuild clan id cache: %s", error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    if (!HasUsableResultSet(results))
    {
        LogError("[Clans] Failed to rebuild clan id cache: query returned no result set.");
        return;
    }

    if (g_hClanIdCache != null)
    {
        delete g_hClanIdCache;
    }

    g_hClanIdCache = new StringMap();

    char steamid64[STEAMID64_MAXLEN];
    while (results.FetchRow())
    {
        results.FetchString(0, steamid64, sizeof(steamid64));
        TrimString(steamid64);
        if (!steamid64[0])
        {
            continue;
        }

        g_hClanIdCache.SetValue(steamid64, results.FetchInt(1), true);
    }

    g_bClanIdCacheReady = true;
}

bool GetCachedClanIdForSteam64(const char[] steamid64, int &clanId)
{
    clanId = 0;
    return (g_hClanIdCache != null && steamid64[0] != '\0' && g_hClanIdCache.GetValue(steamid64, clanId));
}

bool GetLoadedClientClanId(int client, int &clanId)
{
    clanId = 0;

    if (!IsPlayableClient(client))
    {
        return false;
    }

    if (!g_bClientClanLoaded[client])
    {
        return false;
    }

    clanId = g_iClientClanId[client];
    return true;
}

bool ResolveClientClanIdForWarScoring(int client, int &clanId)
{
    clanId = 0;

    if (GetLoadedClientClanId(client, clanId))
    {
        return true;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        return false;
    }

    if (GetCachedClanIdForSteam64(steamid64, clanId))
    {
        return true;
    }

    if (!EnsureDatabaseReady() || g_Database == null)
    {
        return false;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[160];
    FormatEx(query, sizeof(query), "SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1", escapedSteam);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to resolve scoring clan id for %N: %s", client, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (results.FetchRow())
    {
        clanId = results.FetchInt(0);
        UpdateClanIdCacheEntry(steamid64, clanId);
    }

    delete results;
    return true;
}

void UpdateClanIdCacheEntry(const char[] steamid64, int clanId)
{
    if (steamid64[0] == '\0')
    {
        return;
    }

    if (g_hClanIdCache == null)
    {
        g_hClanIdCache = new StringMap();
    }

    if (clanId > 0)
    {
        g_hClanIdCache.SetValue(steamid64, clanId, true);
    }
    else
    {
        g_hClanIdCache.Remove(steamid64);
    }
}

void RemoveClanIdCacheMembers(int clanId)
{
    if (clanId <= 0 || g_hClanIdCache == null)
    {
        return;
    }

    StringMapSnapshot snap = g_hClanIdCache.Snapshot();
    if (snap == null)
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    int cachedClanId = 0;
    for (int i = 0; i < snap.Length; i++)
    {
        snap.GetKey(i, steamid64, sizeof(steamid64));
        if (!g_hClanIdCache.GetValue(steamid64, cachedClanId) || cachedClanId != clanId)
        {
            continue;
        }

        g_hClanIdCache.Remove(steamid64);
    }

    delete snap;
}

int GetSameTeamClanMemberCount(int client, int team = 0)
{
    if (!IsPlayableClient(client))
    {
        return 0;
    }

    if (team <= 1)
    {
        team = GetClientTeam(client);
    }

    if (team <= 1)
    {
        return 0;
    }

    int clanId = 0;
    if (!ResolveClientClanIdForTeamGuard(client, clanId))
    {
        return 0;
    }

    if (clanId <= 0)
    {
        return 0;
    }

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsPlayableClient(i) || GetClientTeam(i) != team)
        {
            continue;
        }

        int currentClanId = 0;
        if (!ResolveClientClanIdForTeamGuard(i, currentClanId))
        {
            continue;
        }

        if (currentClanId == clanId)
        {
            count++;
        }
    }

    return count;
}

bool ResolveClientClanIdForTeamGuard(int client, int &clanId)
{
    clanId = 0;

    if (!IsPlayableClient(client))
    {
        return false;
    }

    if (GetLoadedClientClanId(client, clanId))
    {
        return true;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        return false;
    }

    if (GetCachedClanIdForSteam64(steamid64, clanId))
    {
        return true;
    }

    if (g_bClanIdCacheReady)
    {
        return true;
    }

    if (!g_bClientClanLoadPending[client])
    {
        RequestClientClanIdLoad(client);
    }

    return false;
}

void RequestClientClanIdLoad(int client)
{
    if (!EnsureDatabaseReady() || !IsPlayableClient(client))
    {
        return;
    }

    if (g_bClientClanLoadPending[client])
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT cm.clan_id, cm.rank, c.name, COALESCE(c.tag, '') "
        ... "FROM clan_members cm "
        ... "INNER JOIN clans c ON c.id = cm.clan_id "
        ... "WHERE cm.steamid64 = '%s' LIMIT 1",
        escapedSteam);

    g_bClientClanLoadPending[client] = true;
    g_Database.Query(SQL_OnClientClanIdLoaded, query, GetClientUserId(client));
}

public void SQL_OnClientClanIdLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_bClientClanLoadPending[client] = false;

    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Failed to load clan id for %N: %s", client, error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    g_iClientClanId[client] = 0;
    g_ClientClanRank[client] = ClanRank_Member;
    g_sClientClanName[client][0] = '\0';
    g_sClientClanTag[client][0] = '\0';

    if (HasUsableResultSet(results) && results.FetchRow())
    {
        g_iClientClanId[client] = results.FetchInt(0);
        g_ClientClanRank[client] = view_as<ClanRank>(results.FetchInt(1));
        results.FetchString(2, g_sClientClanName[client], sizeof(g_sClientClanName[]));
        results.FetchString(3, g_sClientClanTag[client], sizeof(g_sClientClanTag[]));
    }
    g_bClientClanLoaded[client] = true;

    char steamid64[STEAMID64_MAXLEN];
    if (GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        UpdateClanIdCacheEntry(steamid64, g_iClientClanId[client]);
    }
}

bool GetLoadedClientClanContext(int client, char[] steamid64, int steamidLen, int &clanId, ClanRank &rank, char[] clanName, int clanNameLen, char[] clanTag, int clanTagLen)
{
    steamid64[0] = '\0';
    clanId = 0;
    rank = ClanRank_Member;
    clanName[0] = '\0';
    clanTag[0] = '\0';

    if (!IsPlayableClient(client) || !g_bClientClanLoaded[client] || !GetClientSteam64(client, steamid64, steamidLen))
    {
        return false;
    }

    clanId = g_iClientClanId[client];
    rank = g_ClientClanRank[client];
    strcopy(clanName, clanNameLen, g_sClientClanName[client]);
    strcopy(clanTag, clanTagLen, g_sClientClanTag[client]);
    return (clanId <= 0 || clanName[0] != '\0');
}

bool GetCachedOnlineClanSummary(int clanId, char[] clanName, int clanNameLen, char[] clanTag, int clanTagLen, char[] representativeName, int representativeNameLen, int &onlineCount)
{
    clanName[0] = '\0';
    clanTag[0] = '\0';
    representativeName[0] = '\0';
    onlineCount = 0;

    ClanRank bestRank = ClanRank_Member;
    bool hasRepresentative = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsPlayableClient(client) || !g_bClientClanLoaded[client] || g_iClientClanId[client] != clanId)
        {
            continue;
        }

        onlineCount++;
        if (!clanName[0])
        {
            strcopy(clanName, clanNameLen, g_sClientClanName[client]);
            strcopy(clanTag, clanTagLen, g_sClientClanTag[client]);
        }

        if (!hasRepresentative || g_ClientClanRank[client] > bestRank)
        {
            GetClientName(client, representativeName, representativeNameLen);
            bestRank = g_ClientClanRank[client];
            hasRepresentative = true;
        }
    }

    return clanName[0] != '\0';
}

void SetClientClanIdBySteam64(const char[] steamid64, int clanId)
{
    UpdateClanIdCacheEntry(steamid64, clanId);

    char currentSteam[STEAMID64_MAXLEN];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsPlayableClient(client))
        {
            continue;
        }

        if (!GetClientSteam64(client, currentSteam, sizeof(currentSteam)))
        {
            continue;
        }

        if (!StrEqual(currentSteam, steamid64, false))
        {
            continue;
        }

        g_iClientClanId[client] = clanId;
        g_bClientClanLoaded[client] = true;
        g_bClientClanLoadPending[client] = false;
        g_ClientClanRank[client] = ClanRank_Member;
        g_sClientClanName[client][0] = '\0';
        g_sClientClanTag[client][0] = '\0';

        if (clanId > 0)
        {
            /* Refresh the extended context cache asynchronously. */
            g_bClientClanLoaded[client] = false;
            RequestClientClanIdLoad(client);
            RequestClientClanTagsLoad(client, true);
        }
        else
        {
            ClearClientClanTagsCache(client, true);
        }
    }
}

void ClearConnectedClanId(int clanId)
{
    if (clanId <= 0)
    {
        return;
    }

    RemoveClanIdCacheMembers(clanId);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsPlayableClient(client))
        {
            continue;
        }

        if (g_iClientClanId[client] != clanId)
        {
            continue;
        }

        g_iClientClanId[client] = 0;
        g_bClientClanLoaded[client] = true;
        g_bClientClanLoadPending[client] = false;
        g_ClientClanRank[client] = ClanRank_Member;
        g_sClientClanName[client][0] = '\0';
        g_sClientClanTag[client][0] = '\0';
        ClearClientClanTagsCache(client, true);
    }
}

void CleanupExpiredInvites()
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    int now = GetTime();
    char query[256];
    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE expires_at <= %d", now);
    g_Database.Query(SQL_GenericQueryCallback, query);
}

public Action Timer_CleanupExpiredInvites(Handle timer, any data)
{
    CleanupExpiredInvites();
    CleanupExpiredWars();
    return Plugin_Continue;
}

public Action Timer_FlushClanWarDeltas(Handle timer, any data)
{
    FlushPendingClanWarPersistenceSync();
    return Plugin_Continue;
}

stock void GetClanById(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, name, tag, owner, is_open, created_at FROM clans WHERE id = %d LIMIT 1",
        clanId);
    g_Database.Query(callback, query, data);
}

void GetClanInfoById(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, c.owner, COALESCE(c.`desc`, ''), ("
        ... "SELECT COUNT(1) FROM clan_members cm WHERE cm.clan_id = c.id"
        ... ") + ("
        ... "SELECT COUNT(1) "
        ... "FROM clan_members cm_child "
        ... "INNER JOIN clan_relations cr ON cr.clan_id_a = cm_child.clan_id "
        ... "WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id"
        ... ") AS member_count, "
        ... "(SELECT COALESCE(SUM(COALESCE(pb.balance, 0)), 0) "
        ... "FROM clan_members cm "
        ... "LEFT JOIN points_store_balances pb ON pb.steamid64 = cm.steamid64 "
        ... "WHERE cm.clan_id = c.id "
        ... "OR cm.clan_id IN (SELECT cr.clan_id_a FROM clan_relations cr WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id)) AS cached_gems "
        ... "FROM clans c "
        ... "WHERE c.id = %d "
        ... "LIMIT 1",
        clanId);
    g_Database.Query(callback, query, data);
}

void QueryClanGemsById(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, "
        ... "COALESCE(SUM(COALESCE(pb.balance, 0)), 0) "
        ... "FROM clans c "
        ... "LEFT JOIN clan_members cm "
        ... "ON (cm.clan_id = c.id "
        ... "OR cm.clan_id IN (SELECT cr.clan_id_a FROM clan_relations cr WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id)) "
        ... "LEFT JOIN points_store_balances pb ON pb.steamid64 = cm.steamid64 "
        ... "WHERE c.id = %d "
        ... "GROUP BY c.id, c.name "
        ... "LIMIT 1",
        clanId);
    g_Database.Query(callback, query, data);
}

void QueryClanMembersListForClient(int userId, int clanId, const char[] clanName)
{
    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT cm.steamid64, cm.rank, cm.joined_at, COALESCE(cst.tag, '') "
        ... "FROM clan_members cm "
        ... "LEFT JOIN clan_sub_tags cst ON cst.clan_id = cm.clan_id AND cst.steamid64 = cm.steamid64 "
        ... "WHERE cm.clan_id = %d "
        ... "ORDER BY cm.joined_at ASC, cm.rank DESC, cm.steamid64 ASC",
        clanId);

    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteCell(clanId);
    pack.WriteString(clanName);

    g_Database.Query(SQL_OnClanMembersList, query, pack);
}

void GetClanByPlayer(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, c.owner, c.is_open, c.created_at, cm.rank, cm.joined_at "
        ... "FROM clans c "
        ... "INNER JOIN clan_members cm ON cm.clan_id = c.id "
        ... "WHERE cm.steamid64 = '%s' "
        ... "LIMIT 1",
        escapedSteam);

    g_Database.Query(callback, query, data);
}

void IsPlayerInClan(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);
    g_Database.Query(callback, query, data);
}

stock void GetClanMembers(int clanId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT steamid64, rank, joined_at FROM clan_members WHERE clan_id = %d ORDER BY rank DESC, joined_at ASC",
        clanId);
    g_Database.Query(callback, query, data);
}

public void SQL_OnAnnounceClanInviteToMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char clanName[CLAN_NAME_MAXLEN + 1];
    char inviterSteam[STEAMID64_MAXLEN];
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(inviterSteam, sizeof(inviterSteam));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    if (error[0])
    {
        LogError("[Clans] Invite announcement member query failed: %s", error);
        return;
    }

    if (results == null)
    {
        return;
    }

    char inviterName[MAX_NAME_LENGTH * 2];
    char targetName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));
    ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));

    while (results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        int member = FindClientBySteam64(memberSteam);
        if (member <= 0 || !IsClientInGame(member))
        {
            continue;
        }

        PrintToChat(member, "[Clans] %s invited %s to '%s'.", inviterName, targetName, clanName);
    }
}

public void SQL_OnAnnounceClanInviteAcceptedToMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char clanName[CLAN_NAME_MAXLEN + 1];
    char accepterSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(accepterSteam, sizeof(accepterSteam));
    delete pack;

    if (error[0])
    {
        LogError("[Clans] Invite accept announcement member query failed: %s", error);
        return;
    }

    if (results == null)
    {
        return;
    }

    char accepterName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(accepterSteam, accepterName, sizeof(accepterName));

    while (results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        int member = FindClientBySteam64(memberSteam);
        if (member <= 0 || !IsClientInGame(member))
        {
            continue;
        }

        PrintToChat(member, "[Clans] %s accepted an invite to '%s'.", accepterName, clanName);
    }
}

void CreateClan(const char[] ownerSteamId64, const char[] name, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedOwner[SQL_STEAMID64_MAXLEN];
    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(ownerSteamId64, escapedOwner, sizeof(escapedOwner));
    EscapeSql(name, escapedName, sizeof(escapedName));

    char lastInsertExpr[32];
    if (IsMySql())
    {
        strcopy(lastInsertExpr, sizeof(lastInsertExpr), "LAST_INSERT_ID()");
    }
    else
    {
        strcopy(lastInsertExpr, sizeof(lastInsertExpr), "last_insert_rowid()");
    }
    int now = GetTime();

    Transaction txn = new Transaction();

    char query[512];
    FormatEx(query, sizeof(query),
        "INSERT INTO clans (name, tag, owner, is_open, created_at) VALUES ('%s', NULL, '%s', 0, %d)",
        escapedName,
        escapedOwner,
        now);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) VALUES (%s, '%s', %d, %d)",
        lastInsertExpr,
        escapedOwner,
        view_as<int>(ClanRank_Owner),
        now);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteString(name);
    pack.WriteString(ownerSteamId64);

    g_Database.Execute(txn, SQLTxn_OnCreateClanSuccess, SQLTxn_OnCreateClanFailure, pack);
}

void DeleteClan(int clanId, int requesterUserId = 0, bool refundOwner = false)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    ResolveActiveWarsForDeletedClan(clanId);

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d OR clan_id_b = %d", clanId, clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_sub_tags WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clan_members WHERE clan_id = %d", clanId);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query), "DELETE FROM clans WHERE id = %d", clanId);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteCell(refundOwner ? 1 : 0);
    pack.WriteCell(clanId);

    g_Database.Execute(txn, SQLTxn_OnDeleteClanSuccess, SQLTxn_OnDeleteClanFailure, pack);
}

void AddClanMember(int clanId, const char[] steamid64, SQLQueryCallback callback, any data = 0, ClanRank rank = ClanRank_Member)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) VALUES (%d, '%s', %d, %d)",
        clanId,
        escapedSteam,
        view_as<int>(rank),
        GetTime());
    g_Database.Query(callback, query, data);
}

void SetClanTag(int clanId, const char[] tag, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedTag[SQL_CLAN_TAG_MAXLEN];
    EscapeSql(tag, escapedTag, sizeof(escapedTag));

    char query[384];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET tag = '%s' WHERE id = %d",
        escapedTag,
        clanId);
    g_Database.Query(callback, query, data);
}

void SetClanDescription(int clanId, const char[] description, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedDescription[SQL_CLAN_DESC_MAXLEN];
    EscapeSql(description, escapedDescription, sizeof(escapedDescription));

    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET `desc` = '%s' WHERE id = %d",
        escapedDescription,
        clanId);
    g_Database.Query(callback, query, data);
}

void SetClanName(int clanId, const char[] name, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(name, escapedName, sizeof(escapedName));

    char query[384];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET name = '%s' WHERE id = %d",
        escapedName,
        clanId);
    g_Database.Query(callback, query, data);
}

void SetClanSubTag(int clanId, const char[] steamid64, const char[] tag, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedTag[SQL_CLAN_SUB_TAG_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(tag, escapedTag, sizeof(escapedTag));

    char query[384];
    FormatEx(query, sizeof(query),
        "REPLACE INTO clan_sub_tags (clan_id, steamid64, tag, created_at) VALUES (%d, '%s', '%s', %d)",
        clanId,
        escapedSteam,
        escapedTag,
        GetTime());
    g_Database.Query(callback, query, data);
}

void SetClanOpen(int clanId, bool isOpen, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query),
        "UPDATE clans SET is_open = %d WHERE id = %d",
        isOpen ? 1 : 0,
        clanId);
    g_Database.Query(callback, query, data);
}

void CreateInvite(int clanId, const char[] steamid64, const char[] inviter, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedInviter[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(inviter, escapedInviter, sizeof(escapedInviter));

    char query[384];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_invites (clan_id, steamid64, invited_by, expires_at) VALUES (%d, '%s', '%s', %d)",
        clanId,
        escapedSteam,
        escapedInviter,
        GetTime() + INVITE_EXPIRE_SECONDS);
    g_Database.Query(callback, query, data);
}

void DeleteInvite(int inviteId, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[128];
    FormatEx(query, sizeof(query), "DELETE FROM clan_invites WHERE id = %d", inviteId);
    g_Database.Query(callback, query, data);
}

void GetPendingInvites(const char[] steamid64, SQLQueryCallback callback, any data = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT i.id, i.clan_id, c.name, c.tag, i.invited_by, i.expires_at "
        ... "FROM clan_invites i "
        ... "INNER JOIN clans c ON c.id = i.clan_id "
        ... "WHERE i.steamid64 = '%s' AND i.expires_at > %d "
        ... "ORDER BY i.expires_at ASC",
        escapedSteam,
        GetTime());
    g_Database.Query(callback, query, data);
}

void NormalizeClanWarPair(int firstClanId, int secondClanId, int &clanIdA, int &clanIdB)
{
    if (firstClanId <= secondClanId)
    {
        clanIdA = firstClanId;
        clanIdB = secondClanId;
        return;
    }

    clanIdA = secondClanId;
    clanIdB = firstClanId;
}

void ResetActiveWarCache()
{
    g_bActiveWarCacheReady = false;

    if (g_hActiveWars == null)
    {
        g_hActiveWars = new ArrayList(sizeof(ActiveClanWar));
        return;
    }

    g_hActiveWars.Clear();
}

int FindActiveWarIndexByWarId(int warId)
{
    if (g_hActiveWars == null || warId <= 0)
    {
        return -1;
    }

    ActiveClanWar war;
    for (int i = 0; i < g_hActiveWars.Length; i++)
    {
        g_hActiveWars.GetArray(i, war);
        if (war.warId == warId)
        {
            return i;
        }
    }

    return -1;
}

int FindActiveWarIndexByClan(int clanId)
{
    if (g_hActiveWars == null || clanId <= 0)
    {
        return -1;
    }

    ActiveClanWar war;
    for (int i = 0; i < g_hActiveWars.Length; i++)
    {
        g_hActiveWars.GetArray(i, war);
        if (war.finalizePending)
        {
            continue;
        }

        if (war.clanIdA == clanId || war.clanIdB == clanId)
        {
            return i;
        }
    }

    return -1;
}

int FindActiveWarIndexByPair(int firstClanId, int secondClanId)
{
    if (g_hActiveWars == null || firstClanId <= 0 || secondClanId <= 0 || firstClanId == secondClanId)
    {
        return -1;
    }

    int clanIdA = 0;
    int clanIdB = 0;
    NormalizeClanWarPair(firstClanId, secondClanId, clanIdA, clanIdB);

    ActiveClanWar war;
    for (int i = 0; i < g_hActiveWars.Length; i++)
    {
        g_hActiveWars.GetArray(i, war);
        if (war.finalizePending)
        {
            continue;
        }

        if (war.clanIdA == clanIdA && war.clanIdB == clanIdB)
        {
            return i;
        }
    }

    return -1;
}

bool GetActiveClanWarForClanCached(int clanId, int &warId, int &clanIdA, int &clanIdB, int &scoreA, int &scoreB)
{
    warId = 0;
    clanIdA = 0;
    clanIdB = 0;
    scoreA = 0;
    scoreB = 0;

    if (!g_bActiveWarCacheReady)
    {
        return false;
    }

    int index = FindActiveWarIndexByClan(clanId);
    if (index == -1)
    {
        return false;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(index, war);
    warId = war.warId;
    clanIdA = war.clanIdA;
    clanIdB = war.clanIdB;
    scoreA = war.scoreA;
    scoreB = war.scoreB;
    return true;
}

bool GetActiveClanWarByPairCached(int firstClanId, int secondClanId, int &warId, int &clanIdA, int &clanIdB, int &scoreA, int &scoreB)
{
    warId = 0;
    clanIdA = 0;
    clanIdB = 0;
    scoreA = 0;
    scoreB = 0;

    if (!g_bActiveWarCacheReady)
    {
        return false;
    }

    int index = FindActiveWarIndexByPair(firstClanId, secondClanId);
    if (index == -1)
    {
        return false;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(index, war);
    warId = war.warId;
    clanIdA = war.clanIdA;
    clanIdB = war.clanIdB;
    scoreA = war.scoreA;
    scoreB = war.scoreB;
    return true;
}

bool ClanWarsRuntimeReady()
{
    return g_cvClanWarsEnabled != null
        && g_cvClanWarsEnabled.BoolValue
        && g_Database != null
        && g_bDatabaseReady
        && g_bActiveWarCacheReady
        && g_hActiveWars != null;
}

bool EnsureClanWarsAvailable(int client = 0)
{
    if (ClanWarsRuntimeReady())
    {
        return true;
    }

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Clan wars are temporarily unavailable.");
    }
    return false;
}

bool PopulateActiveWarLabels(ActiveClanWar war)
{
    char clanNameA[CLAN_NAME_MAXLEN + 1];
    char clanTagA[CLAN_TAG_STORE_MAXLEN];
    char ownerNameA[MAX_NAME_LENGTH * 2];
    char clanNameB[CLAN_NAME_MAXLEN + 1];
    char clanTagB[CLAN_TAG_STORE_MAXLEN];
    char ownerNameB[MAX_NAME_LENGTH * 2];
    int memberCount = 0;

    war.announceLabelA[0] = '\0';
    war.announceLabelB[0] = '\0';
    war.historyLabelA[0] = '\0';
    war.historyLabelB[0] = '\0';

    if (!GetClanInfoSummarySync(war.clanIdA, clanNameA, sizeof(clanNameA), clanTagA, sizeof(clanTagA), ownerNameA, sizeof(ownerNameA), memberCount))
    {
        FormatEx(war.announceLabelA, sizeof(war.announceLabelA), "[%d]", war.clanIdA);
        FormatEx(war.historyLabelA, sizeof(war.historyLabelA), "[%d]", war.clanIdA);
        return false;
    }

    if (!GetClanInfoSummarySync(war.clanIdB, clanNameB, sizeof(clanNameB), clanTagB, sizeof(clanTagB), ownerNameB, sizeof(ownerNameB), memberCount))
    {
        BuildClanWarTagLabel(clanTagA, clanNameA, war.announceLabelA, sizeof(war.announceLabelA));
        BuildClanHistoryTagLabel(clanTagA, clanNameA, war.historyLabelA, sizeof(war.historyLabelA));
        FormatEx(war.announceLabelB, sizeof(war.announceLabelB), "[%d]", war.clanIdB);
        FormatEx(war.historyLabelB, sizeof(war.historyLabelB), "[%d]", war.clanIdB);
        return false;
    }

    BuildClanWarTagLabel(clanTagA, clanNameA, war.announceLabelA, sizeof(war.announceLabelA));
    BuildClanWarTagLabel(clanTagB, clanNameB, war.announceLabelB, sizeof(war.announceLabelB));
    BuildClanHistoryTagLabel(clanTagA, clanNameA, war.historyLabelA, sizeof(war.historyLabelA));
    BuildClanHistoryTagLabel(clanTagB, clanNameB, war.historyLabelB, sizeof(war.historyLabelB));
    return true;
}

void UpsertActiveWarCacheEntry(int warId, int clanIdA, int clanIdB, int scoreA, int scoreB, int createdAt, int expiresAt, int instanceId = 0)
{
    if (warId <= 0 || clanIdA <= 0 || clanIdB <= 0)
    {
        return;
    }

    if (g_hActiveWars == null)
    {
        g_hActiveWars = new ArrayList(sizeof(ActiveClanWar));
    }

    int index = FindActiveWarIndexByWarId(warId);
    if (index == -1)
    {
        index = FindActiveWarIndexByPair(clanIdA, clanIdB);
    }

    ActiveClanWar war;
    if (index != -1)
    {
        g_hActiveWars.GetArray(index, war);
    }

    war.warId = warId;
    if (instanceId > 0)
    {
        war.instanceId = instanceId;
    }
    war.clanIdA = clanIdA;
    war.clanIdB = clanIdB;
    war.scoreA = scoreA;
    war.scoreB = scoreB;
    war.createdAt = createdAt;
    war.expiresAt = expiresAt;
    war.writeDirty = false;
    war.writePending = false;
    war.finalizePending = false;
    war.finalizeWritePending = false;
    war.finalizeWinnerClanId = 0;
    war.finalizeStatus = ClanWarStatus_Active;
    war.finalizeFinishedAt = 0;
    PopulateActiveWarLabels(war);

    if (index == -1)
    {
        g_hActiveWars.PushArray(war);
    }
    else
    {
        g_hActiveWars.SetArray(index, war);
    }
}

void RemoveActiveWarCacheIndex(int index)
{
    if (g_hActiveWars == null || index < 0 || index >= g_hActiveWars.Length)
    {
        return;
    }

    g_hActiveWars.Erase(index);
}

bool DispatchActiveWarScoreWrite(int index)
{
    if (!EnsureDatabaseReady() || g_hActiveWars == null || index < 0 || index >= g_hActiveWars.Length)
    {
        return false;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(index, war);

    if (war.finalizePending || !war.writeDirty || war.writePending)
    {
        return true;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "UPDATE clan_wars SET score_a = %d, score_b = %d, expires_at = %d "
        ... "WHERE id = %d AND created_at = %d AND status = %d",
        war.scoreA,
        war.scoreB,
        war.expiresAt,
        war.warId,
        war.createdAt,
        view_as<int>(ClanWarStatus_Active));

    DataPack pack = new DataPack();
    pack.WriteCell(war.warId);
    pack.WriteCell(war.createdAt);
    pack.WriteCell(war.scoreA);
    pack.WriteCell(war.scoreB);
    pack.WriteCell(war.expiresAt);
    pack.WriteCell(war.instanceId);

    war.writePending = true;
    g_hActiveWars.SetArray(index, war);
    g_Database.Query(SQL_OnActiveWarScoreWrite, query, pack);
    return true;
}

public void SQL_OnActiveWarScoreWrite(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int warId = pack.ReadCell();
    int createdAt = pack.ReadCell();
    int scoreA = pack.ReadCell();
    int scoreB = pack.ReadCell();
    int expiresAt = pack.ReadCell();
    int instanceId = pack.ReadCell();
    delete pack;

    bool saved = (!error[0] && results != null && results.AffectedRows > 0);

    int index = FindActiveWarIndexByWarId(warId);
    if (index != -1)
    {
        ActiveClanWar war;
        g_hActiveWars.GetArray(index, war);
        if (war.createdAt == createdAt)
        {
            war.writePending = false;
            if (saved && war.scoreA == scoreA && war.scoreB == scoreB && war.expiresAt == expiresAt)
            {
                war.writeDirty = false;
            }
            else
            {
                war.writeDirty = true;
            }
            g_hActiveWars.SetArray(index, war);
        }
    }

    if (error[0])
    {
        LogError("[Clans] Failed to persist war %d score snapshot: %s", warId, error);
        HandleDatabaseConnectionLoss(error);
    }
    else if (!saved)
    {
        LogError("[Clans] Failed to persist war %d score snapshot: no active row matched id=%d created_at=%d", warId, warId, createdAt);
    }
    else
    {
        DispatchClanWarInstanceScoreWrite(instanceId, createdAt, scoreA, scoreB);
    }
}

void DispatchClanWarInstanceScoreWrite(int instanceId, int createdAt, int scoreA, int scoreB)
{
    if (!EnsureDatabaseReady() || g_Database == null || instanceId <= 0)
    {
        return;
    }

    char query[192];
    FormatEx(query, sizeof(query),
        "UPDATE clan_war_instances SET score_a = %d, score_b = %d WHERE id = %d AND created_at = %d AND status = %d",
        scoreA,
        scoreB,
        instanceId,
        createdAt,
        view_as<int>(ClanWarStatus_Active));

    g_Database.Query(SQL_OnClanWarInstanceScoreWrite, query, instanceId);
}

public void SQL_OnClanWarInstanceScoreWrite(Database db, DBResultSet results, const char[] error, any data)
{
    int instanceId = data;

    if (error[0])
    {
        LogError("[Clans] Failed to persist war instance %d score snapshot: %s", instanceId, error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    if (results == null || results.AffectedRows <= 0)
    {
        LogError("[Clans] Failed to persist war instance %d score snapshot: no active instance row matched", instanceId);
    }
}

void FlushPendingActiveWarWrites()
{
    if (!EnsureDatabaseReady() || g_hActiveWars == null)
    {
        return;
    }

    for (int i = g_hActiveWars.Length - 1; i >= 0; i--)
    {
        ActiveClanWar war;
        g_hActiveWars.GetArray(i, war);

        if (war.finalizePending)
        {
            DispatchFinalizeActiveWarWrite(i);
            continue;
        }

        DispatchActiveWarScoreWrite(i);
    }
}

bool DispatchFinalizeActiveWarWrite(int index)
{
    if (!EnsureDatabaseReady() || g_hActiveWars == null || index < 0 || index >= g_hActiveWars.Length)
    {
        return false;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(index, war);

    if (!war.finalizePending || war.finalizeWritePending)
    {
        return true;
    }

    char winnerValue[16];
    if (war.finalizeWinnerClanId > 0)
    {
        IntToString(war.finalizeWinnerClanId, winnerValue, sizeof(winnerValue));
    }
    else
    {
        strcopy(winnerValue, sizeof(winnerValue), "NULL");
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "UPDATE clan_wars SET score_a = %d, score_b = %d, winner_clan_id = %s, status = %d, finished_at = %d "
        ... "WHERE id = %d AND created_at = %d",
        war.scoreA,
        war.scoreB,
        winnerValue,
        view_as<int>(war.finalizeStatus),
        war.finalizeFinishedAt,
        war.warId,
        war.createdAt);

    DataPack pack = new DataPack();
    pack.WriteCell(war.warId);
    pack.WriteCell(war.createdAt);

    war.finalizeWritePending = true;
    g_hActiveWars.SetArray(index, war);
    g_Database.Query(SQL_OnFinalizeActiveWarWrite, query, pack);
    return true;
}

public void SQL_OnFinalizeActiveWarWrite(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int warId = pack.ReadCell();
    int createdAt = pack.ReadCell();
    delete pack;

    int index = FindActiveWarIndexByWarId(warId);

    if (error[0])
    {
        LogError("[Clans] Failed to finalize war %d: %s", warId, error);
        HandleDatabaseConnectionLoss(error);
        if (index != -1)
        {
            ActiveClanWar war;
            g_hActiveWars.GetArray(index, war);
            if (war.createdAt == createdAt)
            {
                war.finalizeWritePending = false;
                war.finalizePending = true;
                g_hActiveWars.SetArray(index, war);
            }
        }
        return;
    }

    if (index != -1)
    {
        ActiveClanWar war;
        g_hActiveWars.GetArray(index, war);
        if (war.createdAt == createdAt)
        {
            RemoveActiveWarCacheIndex(index);
        }
    }
}

void FlushPendingClanWarPersistenceSync()
{
    FlushPendingActiveWarWrites();
    FlushPendingClanWarKillWritesSync();
}

bool LoadActiveClanWarsCacheSync()
{
    ResetActiveWarCache();

    if (!EnsureDatabaseReady() || g_Database == null)
    {
        return false;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, clan_id_a, clan_id_b, score_a, score_b, created_at, expires_at "
        ... "FROM clan_wars WHERE status = %d",
        view_as<int>(ClanWarStatus_Active));

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to load active war cache: %s", error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    ArrayList pendingWars = new ArrayList(sizeof(ActiveClanWar));
    ActiveClanWar loadedWar;
    while (results.FetchRow())
    {
        loadedWar.warId = results.FetchInt(0);
        loadedWar.instanceId = 0;
        loadedWar.clanIdA = results.FetchInt(1);
        loadedWar.clanIdB = results.FetchInt(2);
        loadedWar.scoreA = results.FetchInt(3);
        loadedWar.scoreB = results.FetchInt(4);
        loadedWar.createdAt = results.FetchInt(5);
        loadedWar.expiresAt = results.FetchInt(6);
        loadedWar.writeDirty = false;
        loadedWar.writePending = false;
        loadedWar.finalizePending = false;
        loadedWar.finalizeWritePending = false;
        loadedWar.finalizeWinnerClanId = 0;
        loadedWar.finalizeStatus = ClanWarStatus_Active;
        loadedWar.finalizeFinishedAt = 0;
        loadedWar.announceLabelA[0] = '\0';
        loadedWar.announceLabelB[0] = '\0';
        loadedWar.historyLabelA[0] = '\0';
        loadedWar.historyLabelB[0] = '\0';
        pendingWars.PushArray(loadedWar);
    }

    delete results;

    for (int i = 0; i < pendingWars.Length; i++)
    {
        pendingWars.GetArray(i, loadedWar);
        int instanceId = 0;
        if (!EnsureClanWarInstanceSync(loadedWar.warId, loadedWar.clanIdA, loadedWar.clanIdB, loadedWar.createdAt, instanceId)
            && (!EnsureDatabaseReady() || g_Database == null))
        {
            delete pendingWars;
            ResetActiveWarCache();
            return false;
        }
        UpsertActiveWarCacheEntry(loadedWar.warId, loadedWar.clanIdA, loadedWar.clanIdB, loadedWar.scoreA, loadedWar.scoreB, loadedWar.createdAt, loadedWar.expiresAt, instanceId);
    }

    delete pendingWars;
    g_bActiveWarCacheReady = true;
    return true;
}

bool EnsureActiveWarCacheEntryForWarIdSync(int warId, int &index)
{
    index = FindActiveWarIndexByWarId(warId);
    if (index != -1)
    {
        return true;
    }

    if (!EnsureDatabaseReady() || warId <= 0)
    {
        return false;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, clan_id_a, clan_id_b, score_a, score_b, created_at, expires_at "
        ... "FROM clan_wars WHERE id = %d AND status = %d LIMIT 1",
        warId,
        view_as<int>(ClanWarStatus_Active));

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to hydrate active war cache for id %d: %s", warId, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (!results.FetchRow())
    {
        delete results;
        return false;
    }

    int loadedWarId = results.FetchInt(0);
    int clanIdA = results.FetchInt(1);
    int clanIdB = results.FetchInt(2);
    int scoreA = results.FetchInt(3);
    int scoreB = results.FetchInt(4);
    int createdAt = results.FetchInt(5);
    int expiresAt = results.FetchInt(6);
    int instanceId = 0;
    EnsureClanWarInstanceSync(loadedWarId, clanIdA, clanIdB, createdAt, instanceId);

    UpsertActiveWarCacheEntry(
        loadedWarId,
        clanIdA,
        clanIdB,
        scoreA,
        scoreB,
        createdAt,
        expiresAt,
        instanceId);

    delete results;
    index = FindActiveWarIndexByWarId(warId);
    return (index != -1);
}

void BuildPlainClanTag(const char[] storedTag, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (!storedTag[0])
    {
        return;
    }

    char rawTag[CLAN_TAG_STORE_MAXLEN];
    ExtractRawClanTag(storedTag, rawTag, sizeof(rawTag));
    CRemoveTags(rawTag, sizeof(rawTag));
    TrimString(rawTag);

    if (!rawTag[0])
    {
        return;
    }

    FormatEx(buffer, maxlen, "[%s]", rawTag);
}

void BuildClanWarTagLabel(const char[] storedTag, const char[] clanName, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (storedTag[0])
    {
        BuildClanDisplayTag(storedTag, buffer, maxlen);
        return;
    }

    strcopy(buffer, maxlen, clanName);
}

void BuildClanHistoryTagLabel(const char[] storedTag, const char[] clanName, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (storedTag[0])
    {
        BuildPlainClanTag(storedTag, buffer, maxlen);
        if (buffer[0])
        {
            return;
        }
    }

    strcopy(buffer, maxlen, clanName);
    CRemoveTags(buffer, maxlen);
    TrimString(buffer);
}

void BuildClanWarHistorySummary(int viewerClanId, int clanIdA, int scoreA, int scoreB, int winnerClanId, ClanWarStatus status, const char[] clanNameA, const char[] clanTagA, const char[] clanNameB, const char[] clanTagB, char[] buffer, int maxlen)
{
    char labelA[96];
    char labelB[96];
    BuildClanHistoryTagLabel(clanTagA, clanNameA, labelA, sizeof(labelA));
    BuildClanHistoryTagLabel(clanTagB, clanNameB, labelB, sizeof(labelB));

    bool viewerIsClanA = (viewerClanId == clanIdA);
    int ownScore = viewerIsClanA ? scoreA : scoreB;
    int otherScore = viewerIsClanA ? scoreB : scoreA;

    char opponentLabel[96];
    if (viewerIsClanA)
    {
        strcopy(opponentLabel, sizeof(opponentLabel), labelB);
    }
    else
    {
        strcopy(opponentLabel, sizeof(opponentLabel), labelA);
    }

    if (status == ClanWarStatus_Active)
    {
        FormatEx(buffer, maxlen, "Active vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
        return;
    }

    if (status == ClanWarStatus_Expired)
    {
        FormatEx(buffer, maxlen, "Expired vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
        return;
    }

    if (status == ClanWarStatus_Surrendered)
    {
        if (winnerClanId == viewerClanId)
        {
            FormatEx(buffer, maxlen, "Won by surrender vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
        }
        else
        {
            FormatEx(buffer, maxlen, "Surrendered to %s (%d-%d)", opponentLabel, ownScore, otherScore);
        }
        return;
    }

    if (winnerClanId == viewerClanId)
    {
        FormatEx(buffer, maxlen, "Won vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
        return;
    }

    if (winnerClanId > 0)
    {
        FormatEx(buffer, maxlen, "Lost vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
        return;
    }

    FormatEx(buffer, maxlen, "War vs %s (%d-%d)", opponentLabel, ownScore, otherScore);
}

void ShowClanWarHistoryDetailsMenu(int client, int clanId, const char[] clanName, int warInstanceId)
{
    if (client <= 0 || !IsClientInGame(client) || warInstanceId <= 0 || !EnsureDatabaseReady(client))
    {
        return;
    }

    g_iClanHistoryMenuClanId[client] = clanId;
    strcopy(g_sClanHistoryMenuClanName[client], sizeof(g_sClanHistoryMenuClanName[]), clanName);

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT i.id, i.clan_id_a, i.clan_id_b, "
        ... "COALESCE(w.score_a, i.score_a), COALESCE(w.score_b, i.score_b), "
        ... "COALESCE(w.winner_clan_id, COALESCE(i.winner_clan_id, 0)), "
        ... "COALESCE(w.status, i.status), i.created_at, COALESCE(w.finished_at, COALESCE(i.finished_at, 0)), "
        ... "COALESCE(ca.name, ''), COALESCE(ca.tag, ''), COALESCE(cb.name, ''), COALESCE(cb.tag, '') "
        ... "FROM clan_war_instances i "
        ... "LEFT JOIN clan_wars w ON w.id = i.war_id AND w.created_at = i.created_at AND w.status = %d "
        ... "LEFT JOIN clans ca ON ca.id = i.clan_id_a "
        ... "LEFT JOIN clans cb ON cb.id = i.clan_id_b "
        ... "WHERE i.id = %d AND (i.clan_id_a = %d OR i.clan_id_b = %d) "
        ... "LIMIT 1",
        view_as<int>(ClanWarStatus_Active),
        warInstanceId,
        clanId,
        clanId);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Clan war detail query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load war details.");
        delete results;
        return;
    }

    if (!results.FetchRow())
    {
        PrintToChat(client, "[Clans] That war could not be found.");
        delete results;
        return;
    }

    int clanIdA = results.FetchInt(1);
    int scoreA = results.FetchInt(3);
    int scoreB = results.FetchInt(4);
    int winnerClanId = results.FetchInt(5);
    ClanWarStatus status = view_as<ClanWarStatus>(results.FetchInt(6));
    int createdAt = results.FetchInt(7);
    int finishedAt = results.FetchInt(8);

    char clanNameA[CLAN_NAME_MAXLEN + 1];
    char clanTagA[CLAN_TAG_STORE_MAXLEN];
    char clanNameB[CLAN_NAME_MAXLEN + 1];
    char clanTagB[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(9, clanNameA, sizeof(clanNameA));
    results.FetchString(10, clanTagA, sizeof(clanTagA));
    results.FetchString(11, clanNameB, sizeof(clanNameB));
    results.FetchString(12, clanTagB, sizeof(clanTagB));
    delete results;

    char summary[192];
    char startedText[32];
    char finishedText[32];
    BuildClanWarHistorySummary(clanId, clanIdA, scoreA, scoreB, winnerClanId, status, clanNameA, clanTagA, clanNameB, clanTagB, summary, sizeof(summary));
    FormatTime(startedText, sizeof(startedText), "%Y-%m-%d %H:%M", createdAt);
    if (finishedAt > 0)
    {
        FormatTime(finishedText, sizeof(finishedText), "%Y-%m-%d %H:%M", finishedAt);
    }
    else
    {
        strcopy(finishedText, sizeof(finishedText), "Ongoing");
    }

    Menu menu = new Menu(MenuHandler_ClanWarHistoryDetails);
    char title[192];
    char line[192];
    FormatEx(title, sizeof(title), "War Details\n%s", clanName);
    menu.SetTitle(title);

    FormatEx(line, sizeof(line), "Summary: %s", summary);
    menu.AddItem("summary", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Started: %s", startedText);
    menu.AddItem("started", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Finished: %s", finishedText);
    menu.AddItem("finished", line, ITEMDRAW_DISABLED);

    menu.AddItem("top5", "Top 5 Kills", ITEMDRAW_DISABLED);

    FormatEx(query, sizeof(query),
        "SELECT wk.steamid64, wk.clan_id, wk.kills, COALESCE(wk.currency_stolen, 0), COALESCE(c.name, ''), COALESCE(c.tag, '') "
        ... "FROM clan_war_member_kills wk "
        ... "LEFT JOIN clans c ON c.id = wk.clan_id "
        ... "WHERE wk.war_instance_id = %d "
        ... "ORDER BY wk.kills DESC, wk.clan_id ASC, wk.steamid64 ASC "
        ... "LIMIT 5",
        warInstanceId);

    results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Clan war leader query failed: %s", error);
        delete results;
        menu.AddItem("leaders_error", "Failed to load kill leaders", ITEMDRAW_DISABLED);
    }
    else
    {
        bool addedLeaders = false;
        int place = 1;
        while (results.FetchRow())
        {
            char steamid64[STEAMID64_MAXLEN];
            char leaderClanName[CLAN_NAME_MAXLEN + 1];
            char leaderClanTag[CLAN_TAG_STORE_MAXLEN];
            char clanLabel[96];
            char playerName[MAX_NAME_LENGTH * 2];

            results.FetchString(0, steamid64, sizeof(steamid64));
            results.FetchString(4, leaderClanName, sizeof(leaderClanName));
            results.FetchString(5, leaderClanTag, sizeof(leaderClanTag));
            BuildClanHistoryTagLabel(leaderClanTag, leaderClanName, clanLabel, sizeof(clanLabel));
            ResolvePlayerDisplayName(steamid64, playerName, sizeof(playerName));

            if (clanLabel[0])
            {
                FormatEx(line, sizeof(line), "%d. %s %s - %d kills, %d Gems stolen", place, clanLabel, playerName, results.FetchInt(2), results.FetchInt(3));
            }
            else
            {
                FormatEx(line, sizeof(line), "%d. %s - %d kills, %d Gems stolen", place, playerName, results.FetchInt(2), results.FetchInt(3));
            }

            menu.AddItem("leader", line, ITEMDRAW_DISABLED);
            place++;
            addedLeaders = true;
        }
        delete results;

        if (!addedLeaders)
        {
            menu.AddItem("leaders_none", "No tracked kills yet", ITEMDRAW_DISABLED);
        }
    }

    menu.ExitBackButton = true;
    menu.Display(client, CLAN_MENU_TIME);
}

void ShowClanHistoryMenu(int client, int clanId, const char[] clanName)
{
    if (client <= 0 || !IsClientInGame(client) || clanId <= 0 || !EnsureDatabaseReady(client))
    {
        return;
    }

    g_iClanHistoryMenuClanId[client] = clanId;
    strcopy(g_sClanHistoryMenuClanName[client], sizeof(g_sClanHistoryMenuClanName[]), clanName);

    Menu menu = new Menu(MenuHandler_ClanHistory);
    char title[192];
    char line[320];
    char query[1024];
    char timestamp[32];
    FormatEx(title, sizeof(title), "Clan History\n%s", clanName);
    menu.SetTitle(title);
    menu.ExitBackButton = true;

    bool added = false;

    FormatEx(query, sizeof(query),
        "SELECT i.id, i.clan_id_a, i.clan_id_b, "
        ... "COALESCE(w.score_a, i.score_a), COALESCE(w.score_b, i.score_b), "
        ... "COALESCE(w.winner_clan_id, COALESCE(i.winner_clan_id, 0)), "
        ... "COALESCE(w.status, i.status), i.created_at, COALESCE(w.finished_at, COALESCE(i.finished_at, 0)), "
        ... "COALESCE(ca.name, ''), COALESCE(ca.tag, ''), COALESCE(cb.name, ''), COALESCE(cb.tag, '') "
        ... "FROM clan_war_instances i "
        ... "LEFT JOIN clan_wars w ON w.id = i.war_id AND w.created_at = i.created_at AND w.status = %d "
        ... "LEFT JOIN clans ca ON ca.id = i.clan_id_a "
        ... "LEFT JOIN clans cb ON cb.id = i.clan_id_b "
        ... "WHERE i.clan_id_a = %d OR i.clan_id_b = %d "
        ... "ORDER BY CASE WHEN w.id IS NOT NULL THEN i.created_at ELSE COALESCE(i.finished_at, i.created_at) END DESC, i.id DESC "
        ... "LIMIT 100",
        view_as<int>(ClanWarStatus_Active),
        clanId,
        clanId);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Clan war history query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan history.");
        delete results;
        delete menu;
        return;
    }

    bool addedWars = false;
    while (results.FetchRow())
    {
        if (!addedWars)
        {
            menu.AddItem("wars_header", "Wars", ITEMDRAW_DISABLED);
            addedWars = true;
        }

        char clanNameA[CLAN_NAME_MAXLEN + 1];
        char clanTagA[CLAN_TAG_STORE_MAXLEN];
        char clanNameB[CLAN_NAME_MAXLEN + 1];
        char clanTagB[CLAN_TAG_STORE_MAXLEN];
        char summary[192];
        char info[32];

        results.FetchString(9, clanNameA, sizeof(clanNameA));
        results.FetchString(10, clanTagA, sizeof(clanTagA));
        results.FetchString(11, clanNameB, sizeof(clanNameB));
        results.FetchString(12, clanTagB, sizeof(clanTagB));
        BuildClanWarHistorySummary(
            clanId,
            results.FetchInt(1),
            results.FetchInt(3),
            results.FetchInt(4),
            results.FetchInt(5),
            view_as<ClanWarStatus>(results.FetchInt(6)),
            clanNameA,
            clanTagA,
            clanNameB,
            clanTagB,
            summary,
            sizeof(summary));

        int displayTime = results.FetchInt(8);
        if (displayTime <= 0)
        {
            displayTime = results.FetchInt(7);
        }
        FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d", displayTime);
        FormatEx(line, sizeof(line), "%s - %s", timestamp, summary);
        FormatEx(info, sizeof(info), "war:%d", results.FetchInt(0));
        menu.AddItem(info, line);
        added = true;
    }
    delete results;

    FormatEx(query, sizeof(query),
        "SELECT summary, created_at FROM clan_history WHERE clan_id = %d ORDER BY created_at DESC, id DESC LIMIT 100",
        clanId);

    results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Clan history query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan history.");
        delete results;
        delete menu;
        return;
    }

    bool addedActivity = false;
    char summary[CLAN_HISTORY_SUMMARY_MAXLEN + 1];
    while (results.FetchRow())
    {
        if (!addedActivity)
        {
            menu.AddItem("activity_header", "Activity", ITEMDRAW_DISABLED);
            addedActivity = true;
        }

        results.FetchString(0, summary, sizeof(summary));
        FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d", results.FetchInt(1));
        FormatEx(line, sizeof(line), "%s - %s", timestamp, summary);
        menu.AddItem("history", line, ITEMDRAW_DISABLED);
        added = true;
    }
    delete results;

    if (!added)
    {
        menu.AddItem("none", "No clan history yet", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

void BuildWarPlayerLabel(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    char displayName[384];
    BuildClanChatSenderName(client, displayName, sizeof(displayName));

    char steamid64[STEAMID64_MAXLEN];
    char selectedTag[256];
    char displayTag[256];
    if (GetClientSteam64(client, steamid64, sizeof(steamid64))
        && TryGetSelectedTag(client, steamid64, selectedTag, sizeof(selectedTag)))
    {
        BuildClanDisplayTag(selectedTag, displayTag, sizeof(displayTag));
        if (displayTag[0])
        {
            FormatEx(buffer, maxlen, "%s %s", displayTag, displayName);
            ResolveClientTeamColorTag(client, buffer, maxlen);
            return;
        }
    }

    strcopy(buffer, maxlen, displayName);
    ResolveClientTeamColorTag(client, buffer, maxlen);
}

bool GetClanInfoSummarySync(int clanId, char[] clanName, int clanNameLen, char[] clanTag, int clanTagLen, char[] ownerName, int ownerNameLen, int &memberCount)
{
    clanName[0] = '\0';
    clanTag[0] = '\0';
    ownerName[0] = '\0';
    memberCount = 0;

    if (!EnsureDatabaseReady() || clanId <= 0)
    {
        return false;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.name, COALESCE(c.tag, ''), c.owner, ("
        ... "SELECT COUNT(1) FROM clan_members cm WHERE cm.clan_id = c.id"
        ... ") + ("
        ... "SELECT COUNT(1) "
        ... "FROM clan_members cm_child "
        ... "INNER JOIN clan_relations cr ON cr.clan_id_a = cm_child.clan_id "
        ... "WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id"
        ... ") AS member_count "
        ... "FROM clans c "
        ... "WHERE c.id = %d "
        ... "LIMIT 1",
        clanId);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch clan summary for %d: %s", clanId, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (!results.FetchRow())
    {
        delete results;
        return false;
    }

    char ownerSteam[STEAMID64_MAXLEN];
    results.FetchString(0, clanName, clanNameLen);
    results.FetchString(1, clanTag, clanTagLen);
    results.FetchString(2, ownerSteam, sizeof(ownerSteam));
    memberCount = results.FetchInt(3);
    delete results;

    ResolvePlayerDisplayName(ownerSteam, ownerName, ownerNameLen);
    return true;
}

bool GetClientClanContextSync(int client, char[] steamid64, int steamidLen, int &clanId, ClanRank &rank, char[] clanName, int clanNameLen, char[] clanTag, int clanTagLen)
{
    steamid64[0] = '\0';
    clanId = 0;
    rank = ClanRank_Member;
    clanName[0] = '\0';
    clanTag[0] = '\0';

    if (!EnsureDatabaseReady() || !GetClientSteam64(client, steamid64, steamidLen))
    {
        return false;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, COALESCE(c.tag, ''), cm.rank "
        ... "FROM clans c "
        ... "INNER JOIN clan_members cm ON cm.clan_id = c.id "
        ... "WHERE cm.steamid64 = '%s' "
        ... "LIMIT 1",
        escapedSteam);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch client clan context for %N: %s", client, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (!results.FetchRow())
    {
        delete results;
        return true;
    }

    clanId = results.FetchInt(0);
    results.FetchString(1, clanName, clanNameLen);
    results.FetchString(2, clanTag, clanTagLen);
    rank = view_as<ClanRank>(results.FetchInt(3));
    delete results;
    return true;
}

bool GetActiveClanWarForClanSync(int clanId, int &warId, int &clanIdA, int &clanIdB, int &scoreA, int &scoreB)
{
    if (GetActiveClanWarForClanCached(clanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        return true;
    }

    if (g_bActiveWarCacheReady)
    {
        return false;
    }

    warId = 0;
    clanIdA = 0;
    clanIdB = 0;
    scoreA = 0;
    scoreB = 0;

    if (!EnsureDatabaseReady() || clanId <= 0)
    {
        return false;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, clan_id_a, clan_id_b, score_a, score_b "
        ... "FROM clan_wars "
        ... "WHERE status = %d AND expires_at > %d AND (clan_id_a = %d OR clan_id_b = %d) "
        ... "LIMIT 1",
        view_as<int>(ClanWarStatus_Active),
        GetTime(),
        clanId,
        clanId);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch active war for clan %d: %s", clanId, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (!results.FetchRow())
    {
        delete results;
        return false;
    }

    warId = results.FetchInt(0);
    clanIdA = results.FetchInt(1);
    clanIdB = results.FetchInt(2);
    scoreA = results.FetchInt(3);
    scoreB = results.FetchInt(4);
    delete results;
    return (warId > 0);
}

int GetPendingClanWarStolenTotal(int warInstanceId, int clanId)
{
    if (g_hPendingClanWarKillDeltas == null || warInstanceId <= 0 || clanId <= 0)
    {
        return 0;
    }

    int total = 0;
    PendingClanWarKillDelta delta;
    for (int i = 0; i < g_hPendingClanWarKillDeltas.Length; i++)
    {
        g_hPendingClanWarKillDeltas.GetArray(i, delta);
        if (delta.warInstanceId == warInstanceId && delta.clanId == clanId)
        {
            total += delta.currencyStolen;
        }
    }

    return total;
}

int GetClanWarStolenTotalSync(int warInstanceId, int clanId)
{
    int total = GetPendingClanWarStolenTotal(warInstanceId, clanId);
    if (!EnsureDatabaseReady() || warInstanceId <= 0 || clanId <= 0)
    {
        return total;
    }

    char query[192];
    FormatEx(query, sizeof(query),
        "SELECT COALESCE(SUM(currency_stolen), 0) FROM clan_war_member_kills WHERE war_instance_id = %d AND clan_id = %d",
        warInstanceId,
        clanId);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch clan war stolen total: %s", error);
        delete results;
        return total;
    }

    if (results.FetchRow())
    {
        total += results.FetchInt(0);
    }
    delete results;
    return total;
}

bool GetClanWarRedeclareCooldownSync(int declaringClanId, int targetClanId, int &secondsLeft)
{
    secondsLeft = 0;
    if (!EnsureDatabaseReady() || declaringClanId <= 0 || targetClanId <= 0 || declaringClanId == targetClanId)
    {
        return false;
    }

    int clanIdA = 0;
    int clanIdB = 0;
    NormalizeClanWarPair(declaringClanId, targetClanId, clanIdA, clanIdB);

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT COALESCE(finished_at, 0) FROM clan_wars WHERE clan_id_a = %d AND clan_id_b = %d LIMIT 1",
        clanIdA,
        clanIdB);

    DBResultSet results = SQL_Query(g_Database, query);
    if (!HasUsableResultSet(results))
    {
        char error[256];
        SQL_GetError(g_Database, error, sizeof(error));
        LogError("[Clans] Failed to fetch clan war redeclare cooldown for pair %d/%d: %s", clanIdA, clanIdB, error);
        HandleDatabaseConnectionLoss(error);
        delete results;
        return false;
    }

    if (!results.FetchRow())
    {
        delete results;
        return false;
    }

    int finishedAt = results.FetchInt(0);
    delete results;

    if (finishedAt <= 0)
    {
        return false;
    }

    secondsLeft = (finishedAt + CLAN_WAR_REDECLARE_COOLDOWN_SECONDS) - GetTime();
    return secondsLeft > 0;
}

void GetClanWarTargetCooldownLabel(int targetClanId, char[] buffer, int maxlen)
{
    if (targetClanId <= 0 || maxlen <= 0)
    {
        return;
    }

    buffer[0] = '\0';

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char representativeName[MAX_NAME_LENGTH * 2];
    int onlineCount = 0;
    if (GetCachedOnlineClanSummary(targetClanId, clanName, sizeof(clanName), clanTag, sizeof(clanTag), representativeName, sizeof(representativeName), onlineCount))
    {
        BuildClanDisplayTag(clanTag, buffer, maxlen);
        if (!buffer[0])
        {
            strcopy(buffer, maxlen, clanName);
        }
        return;
    }

    FormatEx(clanName, sizeof(clanName), "%d", targetClanId);
    clanTag[0] = '\0';

    if (EnsureDatabaseReady())
    {
        char query[128];
        FormatEx(query, sizeof(query), "SELECT name, COALESCE(tag, '') FROM clans WHERE id = %d LIMIT 1", targetClanId);

        DBResultSet results = SQL_Query(g_Database, query);
        if (HasUsableResultSet(results) && results.FetchRow())
        {
            results.FetchString(0, clanName, sizeof(clanName));
            results.FetchString(1, clanTag, sizeof(clanTag));
        }
        delete results;
    }

    BuildClanDisplayTag(clanTag, buffer, maxlen);
    if (!buffer[0])
    {
        strcopy(buffer, maxlen, clanName);
    }
}

void AddClanHistoryEntry(int clanId, const char[] fmt, any ...)
{
    if (clanId <= 0 || !EnsureDatabaseReady())
    {
        return;
    }

    char summary[CLAN_HISTORY_SUMMARY_MAXLEN + 1];
    char escapedSummary[SQL_CLAN_HISTORY_SUMMARY_MAXLEN];
    VFormat(summary, sizeof(summary), fmt, 3);
    CRemoveTags(summary, sizeof(summary));
    TrimString(summary);

    if (!summary[0])
    {
        return;
    }

    EscapeSql(summary, escapedSummary, sizeof(escapedSummary));

    char query[768];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_history (clan_id, summary, created_at) VALUES (%d, '%s', %d)",
        clanId,
        escapedSummary,
        GetTime());

    g_Database.Query(SQL_GenericQueryCallback, query);
}

bool FinalizeClanWarSync(int warId, int clanIdA, int clanIdB, int scoreA, int scoreB, int winnerClanId, ClanWarStatus status)
{
    if (warId <= 0 || clanIdA <= 0 || clanIdB <= 0)
    {
        return false;
    }

    int warIndex = FindActiveWarIndexByWarId(warId);
    if (warIndex == -1 && !EnsureActiveWarCacheEntryForWarIdSync(warId, warIndex))
    {
        return false;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(warIndex, war);

    if (war.finalizePending)
    {
        return true;
    }

    char historyLabelA[96];
    char historyLabelB[96];
    char announceLabelA[96];
    char announceLabelB[96];

    clanIdA = war.clanIdA;
    clanIdB = war.clanIdB;
    scoreA = war.scoreA;
    scoreB = war.scoreB;

    strcopy(historyLabelA, sizeof(historyLabelA), war.historyLabelA);
    strcopy(historyLabelB, sizeof(historyLabelB), war.historyLabelB);
    strcopy(announceLabelA, sizeof(announceLabelA), war.announceLabelA);
    strcopy(announceLabelB, sizeof(announceLabelB), war.announceLabelB);

    if (!historyLabelA[0])
    {
        FormatEx(historyLabelA, sizeof(historyLabelA), "[%d]", clanIdA);
    }
    if (!historyLabelB[0])
    {
        FormatEx(historyLabelB, sizeof(historyLabelB), "[%d]", clanIdB);
    }
    if (!announceLabelA[0])
    {
        FormatEx(announceLabelA, sizeof(announceLabelA), "[%d]", clanIdA);
    }
    if (!announceLabelB[0])
    {
        FormatEx(announceLabelB, sizeof(announceLabelB), "[%d]", clanIdB);
    }

    war.writeDirty = false;
    war.finalizePending = true;
    war.finalizeWritePending = false;
    war.finalizeWinnerClanId = winnerClanId;
    war.finalizeStatus = status;
    war.finalizeFinishedAt = GetTime();
    g_hActiveWars.SetArray(warIndex, war);

    int stolenA = (war.instanceId > 0) ? GetClanWarStolenTotalSync(war.instanceId, clanIdA) : 0;
    int stolenB = (war.instanceId > 0) ? GetClanWarStolenTotalSync(war.instanceId, clanIdB) : 0;

    if (status == ClanWarStatus_Expired)
    {
        AddClanHistoryEntry(clanIdA, "War with %s expired at %d-%d", historyLabelB, scoreA, scoreB);
        AddClanHistoryEntry(clanIdB, "War with %s expired at %d-%d", historyLabelA, scoreB, scoreA);
    }
    else if (winnerClanId == clanIdA)
    {
        AddClanHistoryEntry(clanIdA, "Won war vs %s (%d-%d, %d Gems stolen)", historyLabelB, scoreA, scoreB, stolenA);
        AddClanHistoryEntry(clanIdB, "Lost war vs %s (%d-%d, %d Gems stolen)", historyLabelA, scoreB, scoreA, stolenB);
    }
    else if (winnerClanId == clanIdB)
    {
        AddClanHistoryEntry(clanIdA, "Lost war vs %s (%d-%d, %d Gems stolen)", historyLabelB, scoreA, scoreB, stolenA);
        AddClanHistoryEntry(clanIdB, "Won war vs %s (%d-%d, %d Gems stolen)", historyLabelA, scoreB, scoreA, stolenB);
    }

    if (status == ClanWarStatus_Expired)
    {
        CPrintToChatAll("{gold}[Clans]{default} War between %s and %s expired. Final score: %d-%d", announceLabelA, announceLabelB, scoreA, scoreB);
    }
    else if (winnerClanId == clanIdA)
    {
        CPrintToChatAll("{gold}[Clans]{default} %s won the war against %s! Final score: %d-%d. %s stole {lightgreen}%d Gems{default}!", announceLabelA, announceLabelB, scoreA, scoreB, announceLabelA, stolenA);
    }
    else if (winnerClanId == clanIdB)
    {
        CPrintToChatAll("{gold}[Clans]{default} %s won the war against %s! Final score: %d-%d. %s stole {lightgreen}%d Gems{default}!", announceLabelB, announceLabelA, scoreB, scoreA, announceLabelB, stolenB);
    }

    if (war.instanceId > 0)
    {
        UpdateClanWarInstanceFinalState(war.instanceId, war.scoreA, war.scoreB, winnerClanId, status, war.finalizeFinishedAt);
    }

    if (g_bDatabaseReady)
    {
        FlushPendingClanWarPersistenceSync();
    }

    return true;
}

void BroadcastClanWarScoreUpdate(const char[] scoringLabel, const char[] otherLabel, int scoringClanId, int otherClanId, int scoringScore, int otherScore, int warInstanceId, int attacker, int victim)
{
    if ((scoringScore % 5) != 0)
    {
        return;
    }

    char attackerLabel[512];
    char victimLabel[512];
    BuildWarPlayerLabel(attacker, attackerLabel, sizeof(attackerLabel));
    BuildWarPlayerLabel(victim, victimLabel, sizeof(victimLabel));

    bool stolenAlert = ((scoringScore % 10) == 0);
    bool broadcastOutsiders = stolenAlert;

    int leaderScore = (scoringScore >= otherScore) ? scoringScore : otherScore;
    int trailingScore = (scoringScore >= otherScore) ? otherScore : scoringScore;
    int leaderClanId = (scoringScore >= otherScore) ? scoringClanId : otherClanId;
    int leaderStolen = 0;
    if (stolenAlert && warInstanceId > 0)
    {
        leaderStolen = GetClanWarStolenTotalSync(warInstanceId, leaderClanId);
    }
    char leaderLabel[96];
    char trailingLabel[96];
    strcopy(leaderLabel, sizeof(leaderLabel), (scoringScore >= otherScore) ? scoringLabel : otherLabel);
    strcopy(trailingLabel, sizeof(trailingLabel), (scoringScore >= otherScore) ? otherLabel : scoringLabel);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        bool isParticipant = IsConnectedClientInClan(i, scoringClanId) || IsConnectedClientInClan(i, otherClanId);
        if (!isParticipant && !broadcastOutsiders)
        {
            continue;
        }

        ClansCPrintToChatExWrapped(i, attacker, "%s killed %s!", attackerLabel, victimLabel);
        if (stolenAlert)
        {
            CPrintToChat(i, "{gold}[Clans]{default} %s is beating %s %d-%d and has stolen {lightgreen}%d Gems{default} so far!!!", leaderLabel, trailingLabel, leaderScore, trailingScore, leaderStolen);
        }
        else
        {
            CPrintToChat(i, "{gold}[Clans]{default} %s's score: %d | %s's score: %d", scoringLabel, scoringScore, otherLabel, otherScore);
        }
    }
}

void CleanupExpiredWars()
{
    if (!g_bActiveWarCacheReady || g_hActiveWars == null)
    {
        return;
    }

    int now = GetTime();
    for (int i = g_hActiveWars.Length - 1; i >= 0; i--)
    {
        ActiveClanWar war;
        g_hActiveWars.GetArray(i, war);
        if (war.finalizePending || war.expiresAt > now)
        {
            continue;
        }

        FinalizeClanWarSync(
            war.warId,
            war.clanIdA,
            war.clanIdB,
            war.scoreA,
            war.scoreB,
            0,
            ClanWarStatus_Expired);
    }
}

bool StartClanWarAsync(int client, int declaringClanId, int targetClanId, const char[] declarerSteam)
{
    if (!EnsureClanWarsAvailable(client) || declaringClanId <= 0 || targetClanId <= 0 || declaringClanId == targetClanId)
    {
        return false;
    }

    int clanIdA = 0;
    int clanIdB = 0;
    NormalizeClanWarPair(declaringClanId, targetClanId, clanIdA, clanIdB);

    int existingWarId = 0;
    int existingClanIdA = 0;
    int existingClanIdB = 0;
    int existingScoreA = 0;
    int existingScoreB = 0;
    if (GetActiveClanWarByPairCached(declaringClanId, targetClanId, existingWarId, existingClanIdA, existingClanIdB, existingScoreA, existingScoreB))
    {
        return false;
    }

    char escapedDeclarer[SQL_STEAMID64_MAXLEN];
    EscapeSql(declarerSteam, escapedDeclarer, sizeof(escapedDeclarer));

    int now = GetTime();
    char query[2048];
    if (IsMySql())
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO clan_wars (clan_id_a, clan_id_b, declared_by, score_a, score_b, winner_clan_id, status, created_at, expires_at, finished_at) "
            ... "VALUES (%d, %d, '%s', 0, 0, NULL, %d, %d, %d, NULL) "
            ... "ON DUPLICATE KEY UPDATE declared_by = IF(status = %d, declared_by, VALUES(declared_by)), score_a = IF(status = %d, score_a, 0), score_b = IF(status = %d, score_b, 0), winner_clan_id = IF(status = %d, winner_clan_id, NULL), created_at = IF(status = %d, created_at, VALUES(created_at)), expires_at = IF(status = %d, expires_at, VALUES(expires_at)), finished_at = IF(status = %d, finished_at, NULL), status = IF(status = %d, status, VALUES(status))",
            clanIdA,
            clanIdB,
            escapedDeclarer,
            view_as<int>(ClanWarStatus_Active),
            now,
            now + CLAN_WAR_EXPIRE_SECONDS,
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active));
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO clan_wars (clan_id_a, clan_id_b, declared_by, score_a, score_b, winner_clan_id, status, created_at, expires_at, finished_at) "
            ... "VALUES (%d, %d, '%s', 0, 0, NULL, %d, %d, %d, NULL) "
            ... "ON CONFLICT(clan_id_a, clan_id_b) DO UPDATE SET declared_by = CASE WHEN status = %d THEN declared_by ELSE excluded.declared_by END, score_a = CASE WHEN status = %d THEN score_a ELSE 0 END, score_b = CASE WHEN status = %d THEN score_b ELSE 0 END, winner_clan_id = CASE WHEN status = %d THEN winner_clan_id ELSE NULL END, created_at = CASE WHEN status = %d THEN created_at ELSE excluded.created_at END, expires_at = CASE WHEN status = %d THEN expires_at ELSE excluded.expires_at END, finished_at = CASE WHEN status = %d THEN finished_at ELSE NULL END, status = CASE WHEN status = %d THEN status ELSE excluded.status END",
            clanIdA,
            clanIdB,
            escapedDeclarer,
            view_as<int>(ClanWarStatus_Active),
            now,
            now + CLAN_WAR_EXPIRE_SECONDS,
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active),
            view_as<int>(ClanWarStatus_Active));
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(declaringClanId);
    pack.WriteCell(targetClanId);
    pack.WriteCell(clanIdA);
    pack.WriteCell(clanIdB);
    pack.WriteCell(now);
    g_Database.Query(SQL_OnStartClanWarUpsert, query, pack);
    return true;
}

public void SQL_OnStartClanWarUpsert(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int declaringClanId = pack.ReadCell();
    int targetClanId = pack.ReadCell();
    int clanIdA = pack.ReadCell();
    int clanIdB = pack.ReadCell();
    int createdAt = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (error[0])
    {
        LogError("[Clans] Failed to start war between %d and %d: %s", clanIdA, clanIdB, error);
        HandleDatabaseConnectionLoss(error);
        if (client > 0 && IsClientInGame(client))
        {
            PrintToChat(client, "[Clans] Failed to declare war.");
        }
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, score_a, score_b, created_at, expires_at, status FROM clan_wars WHERE clan_id_a = %d AND clan_id_b = %d LIMIT 1",
        clanIdA,
        clanIdB);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(declaringClanId);
    next.WriteCell(targetClanId);
    next.WriteCell(clanIdA);
    next.WriteCell(clanIdB);
    next.WriteCell(createdAt);
    db.Query(SQL_OnStartClanWarSelected, query, next);
}

public void SQL_OnStartClanWarSelected(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int declaringClanId = pack.ReadCell();
    int targetClanId = pack.ReadCell();
    int clanIdA = pack.ReadCell();
    int clanIdB = pack.ReadCell();
    int createdAt = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (error[0] || results == null || !results.FetchRow())
    {
        if (error[0])
        {
            LogError("[Clans] Failed to fetch newly started war for pair %d/%d: %s", clanIdA, clanIdB, error);
            HandleDatabaseConnectionLoss(error);
        }
        if (client > 0 && IsClientInGame(client))
        {
            PrintToChat(client, "[Clans] Failed to declare war.");
        }
        return;
    }

    int warId = results.FetchInt(0);
    int scoreA = results.FetchInt(1);
    int scoreB = results.FetchInt(2);
    int rowCreatedAt = results.FetchInt(3);
    int expiresAt = results.FetchInt(4);
    ClanWarStatus status = view_as<ClanWarStatus>(results.FetchInt(5));

    if (status == ClanWarStatus_Active && rowCreatedAt != createdAt)
    {
        int instanceId = 0;
        EnsureClanWarInstanceSync(warId, clanIdA, clanIdB, rowCreatedAt, instanceId);
        UpsertActiveWarCacheEntry(warId, clanIdA, clanIdB, scoreA, scoreB, rowCreatedAt, expiresAt, instanceId);

        if (client > 0 && IsClientInGame(client))
        {
            PrintToChat(client, "[Clans] These clans are already at war.");
        }
        return;
    }

    if (status != ClanWarStatus_Active || rowCreatedAt != createdAt)
    {
        LogError("[Clans] Unexpected war row state after declaring pair %d/%d: status=%d created_at=%d expected_created_at=%d", clanIdA, clanIdB, view_as<int>(status), rowCreatedAt, createdAt);
        if (client > 0 && IsClientInGame(client))
        {
            PrintToChat(client, "[Clans] Failed to declare war.");
        }
        return;
    }

    UpsertActiveWarCacheEntry(warId, clanIdA, clanIdB, 0, 0, createdAt, expiresAt, 0);

    char declaringClanName[CLAN_NAME_MAXLEN + 1];
    char declaringClanTag[CLAN_TAG_STORE_MAXLEN];
    char declaringRepresentative[MAX_NAME_LENGTH * 2];
    char targetClanName[CLAN_NAME_MAXLEN + 1];
    char targetClanTag[CLAN_TAG_STORE_MAXLEN];
    char targetRepresentative[MAX_NAME_LENGTH * 2];
    int onlineCount = 0;

    if (!GetCachedOnlineClanSummary(declaringClanId, declaringClanName, sizeof(declaringClanName), declaringClanTag, sizeof(declaringClanTag), declaringRepresentative, sizeof(declaringRepresentative), onlineCount))
    {
        FormatEx(declaringClanName, sizeof(declaringClanName), "%d", declaringClanId);
        declaringClanTag[0] = '\0';
    }
    if (!GetCachedOnlineClanSummary(targetClanId, targetClanName, sizeof(targetClanName), targetClanTag, sizeof(targetClanTag), targetRepresentative, sizeof(targetRepresentative), onlineCount))
    {
        FormatEx(targetClanName, sizeof(targetClanName), "%d", targetClanId);
        targetClanTag[0] = '\0';
    }

    char declaringHistoryLabel[96];
    char targetHistoryLabel[96];
    char declaringAnnounceLabel[96];
    char targetAnnounceLabel[96];
    BuildClanHistoryTagLabel(declaringClanTag, declaringClanName, declaringHistoryLabel, sizeof(declaringHistoryLabel));
    BuildClanHistoryTagLabel(targetClanTag, targetClanName, targetHistoryLabel, sizeof(targetHistoryLabel));
    BuildClanWarTagLabel(declaringClanTag, declaringClanName, declaringAnnounceLabel, sizeof(declaringAnnounceLabel));
    BuildClanWarTagLabel(targetClanTag, targetClanName, targetAnnounceLabel, sizeof(targetAnnounceLabel));

    AddClanHistoryEntry(declaringClanId, "Declared war on %s", targetHistoryLabel);
    AddClanHistoryEntry(targetClanId, "War declared by %s", declaringHistoryLabel);
    CPrintToChatAll("{gold}[Clans]{default} %s has declared war on %s!", declaringAnnounceLabel, targetAnnounceLabel);

    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] War declared.");
    }

    char query[384];
    FormatEx(query, sizeof(query),
        "INSERT INTO clan_war_instances (war_id, clan_id_a, clan_id_b, score_a, score_b, winner_clan_id, status, created_at, finished_at) "
        ... "VALUES (%d, %d, %d, 0, 0, NULL, %d, %d, NULL)",
        warId,
        clanIdA,
        clanIdB,
        view_as<int>(ClanWarStatus_Active),
        createdAt);

    DataPack next = new DataPack();
    next.WriteCell(warId);
    next.WriteCell(createdAt);
    db.Query(SQL_OnStartClanWarInstanceInserted, query, next);
}

public void SQL_OnStartClanWarInstanceInserted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int warId = pack.ReadCell();
    int createdAt = pack.ReadCell();
    delete pack;

    if (error[0])
    {
        LogError("[Clans] Failed to create war instance for %d/%d: %s", warId, createdAt, error);
        HandleDatabaseConnectionLoss(error);
        return;
    }

    char query[192];
    FormatEx(query, sizeof(query), "SELECT id FROM clan_war_instances WHERE war_id = %d AND created_at = %d LIMIT 1", warId, createdAt);

    DataPack next = new DataPack();
    next.WriteCell(warId);
    next.WriteCell(createdAt);
    db.Query(SQL_OnStartClanWarInstanceSelected, query, next);
}

public void SQL_OnStartClanWarInstanceSelected(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int warId = pack.ReadCell();
    int createdAt = pack.ReadCell();
    delete pack;

    if (error[0] || results == null || !results.FetchRow())
    {
        if (error[0])
        {
            LogError("[Clans] Failed to fetch war instance for %d/%d: %s", warId, createdAt, error);
            HandleDatabaseConnectionLoss(error);
        }
        return;
    }

    int index = FindActiveWarIndexByWarId(warId);
    if (index == -1)
    {
        return;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(index, war);
    if (war.createdAt == createdAt)
    {
        war.instanceId = results.FetchInt(0);
        g_hActiveWars.SetArray(index, war);
    }
}

void ResolveActiveWarsForDeletedClan(int clanId)
{
    if (g_bActiveWarCacheReady)
    {
        int warIndex = FindActiveWarIndexByClan(clanId);
        while (warIndex != -1)
        {
            ActiveClanWar war;
            g_hActiveWars.GetArray(warIndex, war);

            int winnerClanId = (war.clanIdA == clanId) ? war.clanIdB : war.clanIdA;
            if (!FinalizeClanWarSync(war.warId, war.clanIdA, war.clanIdB, war.scoreA, war.scoreB, winnerClanId, ClanWarStatus_Surrendered))
            {
                break;
            }

            warIndex = FindActiveWarIndexByClan(clanId);
        }
        return;
    }

    int warId = 0;
    int clanIdA = 0;
    int clanIdB = 0;
    int scoreA = 0;
    int scoreB = 0;

    while (GetActiveClanWarForClanSync(clanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        int winnerClanId = (clanIdA == clanId) ? clanIdB : clanIdA;
        if (!FinalizeClanWarSync(warId, clanIdA, clanIdB, scoreA, scoreB, winnerClanId, ClanWarStatus_Surrendered))
        {
            break;
        }
    }
}

void SetParentRelation(int clanIdA, int clanIdB, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d AND relation_type = 3", clanIdA);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_relations (clan_id_a, clan_id_b, relation_type, created_at) VALUES (%d, %d, 3, %d)",
        clanIdA,
        clanIdB,
        GetTime());
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(requesterUserId);
    pack.WriteCell(clanIdA);
    pack.WriteCell(clanIdB);

    g_Database.Execute(txn, SQLTxn_OnSetParentSuccess, SQLTxn_OnSetParentFailure, pack);
}

void ClearParentRelation(int clanIdA, int requesterUserId = 0)
{
    if (!EnsureDatabaseReady())
    {
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query), "DELETE FROM clan_relations WHERE clan_id_a = %d AND relation_type = 3", clanIdA);
    g_Database.Query(SQL_OnClearParentRelation, query, requesterUserId);
}

public void SQL_GenericQueryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[Clans] SQL query failed: %s", error);
        HandleDatabaseConnectionLoss(error);
    }
}

public Action CommandListener_Say(int client, const char[] command, int argc)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    StripQuotes(text);
    TrimString(text);

    if (!text[0])
    {
        return Plugin_Continue;
    }

    if (g_PromptState[client] == Prompt_ClanCreateName)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan creation cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        HandleClanCreateInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanRenameName)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan rename cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        HandleClanRenameInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanLeaveConfirm)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan deletion cancelled.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/yes", false))
        {
            g_PromptState[client] = Prompt_None;
            StartOwnerDeleteClan(client);
            return Plugin_Handled;
        }

        PrintToChat(client, "[Clans] Type /yes to confirm clan deletion or /cancel to abort.");
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanTagChoice)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan tag action cancelled.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/change", false))
        {
            g_PromptState[client] = Prompt_ClanTagInput;
            PrintToChat(client, "[Clans] Type the new clan tag in chat. Type /cancel to abort.");
            return Plugin_Handled;
        }

        if (StrEqual(text, "/sub", false))
        {
            g_PromptState[client] = Prompt_ClanSubTagInput;
            PrintToChat(client, "[Clans] Type your clan sub-tag in chat. If you already have one, this will replace it. Type /cancel to abort.");
            return Plugin_Handled;
        }

        PrintToChat(client, "[Clans] Use /cancel, /change, or /sub.");
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanTagInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan tag update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetMainClanTagFromInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanSubTagInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan sub-tag update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetClanSubTagFromInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanDescInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            g_PromptState[client] = Prompt_None;
            PrintToChat(client, "[Clans] Clan description update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetClanDescFromInput(client, text);
        return Plugin_Handled;
    }
    else if (g_PromptState[client] == Prompt_ClanAdminDescInput)
    {
        if (StrEqual(text, "/cancel", false))
        {
            ResetClientState(client);
            PrintToChat(client, "[Clans] Clan description update cancelled.");
            return Plugin_Handled;
        }

        g_PromptState[client] = Prompt_None;
        StartSetAdminClanDescFromInput(client, text);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool ValidateClanName(const char[] name)
{
    int len = strlen(name);
    return (len > 0 && len <= CLAN_NAME_MAXLEN);
}

void StartClanTagPrompt(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnClanTagPromptContext, GetClientUserId(client));
}

void StartSetMainClanTagFromInput(int client, const char[] input)
{
    char rawTag[CLAN_TAG_MAXLEN + 1];
    strcopy(rawTag, sizeof(rawTag), input);
    StripQuotes(rawTag);
    TrimString(rawTag);
    NormalizeClanTagText(rawTag);

    if (!rawTag[0])
    {
        PrintToChat(client, "[Clans] Tag cannot be empty.");
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(rawTag);

    GetClanByPlayer(steamid64, SQL_OnClanTagContext, pack);
}

void StartSetClanDescFromInput(int client, const char[] input)
{
    char description[CLAN_DESC_MAXLEN + 1];
    strcopy(description, sizeof(description), input);
    StripQuotes(description);
    TrimString(description);

    if (!description[0])
    {
        PrintToChat(client, "[Clans] Description cannot be empty.");
        return;
    }

    if (strlen(description) > CLAN_DESC_MAXLEN)
    {
        PrintToChat(client, "[Clans] Description is too long. Max length: %d.", CLAN_DESC_MAXLEN);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(description);

    GetClanByPlayer(steamid64, SQL_OnClanDescContext, pack);
}

void StartSetAdminClanDescFromInput(int client, const char[] input)
{
    int clanId = g_PendingAdminClanDescId[client];

    char clanName[CLAN_NAME_MAXLEN + 1];
    strcopy(clanName, sizeof(clanName), g_PendingAdminClanDescName[client]);
    g_PendingAdminClanDescId[client] = 0;
    g_PendingAdminClanDescName[client][0] = '\0';

    if (clanId <= 0)
    {
        PrintToChat(client, "[Clans] No clan selected.");
        return;
    }

    char description[CLAN_DESC_MAXLEN + 1];
    strcopy(description, sizeof(description), input);
    StripQuotes(description);
    TrimString(description);

    if (!description[0])
    {
        PrintToChat(client, "[Clans] Description cannot be empty.");
        return;
    }

    if (strlen(description) > CLAN_DESC_MAXLEN)
    {
        PrintToChat(client, "[Clans] Description is too long. Max length: %d.", CLAN_DESC_MAXLEN);
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(clanId);
    pack.WriteString(description);
    pack.WriteString(clanName);

    GetClanById(clanId, SQL_OnAdminClanDescContext, pack);
}

void ShowClanMainMenu(int client, int clanId, ClanRank rank, const char[] clanName, const char[] clanTag, bool isOpen, int inviteCount)
{
    Menu menu = new Menu(MenuHandler_ClanMain);

    char title[256];
    if (clanId > 0)
    {
        char rankName[16];
        GetClanRankLabel(rank, rankName, sizeof(rankName));

        if (clanTag[0])
        {
            FormatEx(title, sizeof(title), "Clan Menu\n%s %s\nRank: %s\nJoining: %s", clanName, clanTag, rankName, isOpen ? "Open" : "Closed");
        }
        else
        {
            FormatEx(title, sizeof(title), "Clan Menu\n%s\nRank: %s\nJoining: %s", clanName, rankName, isOpen ? "Open" : "Closed");
        }

        menu.SetTitle(title);

        if (rank >= ClanRank_Owner)
        {
            char deleteLabel[64];
            FormatEx(deleteLabel, sizeof(deleteLabel), "Delete clan (+%d Gems refund)", CLAN_CREATE_GEM_COST);
            menu.AddItem("leave", deleteLabel);
        }
        else
        {
            menu.AddItem("leave", "Leave clan");
        }

        menu.AddItem("members", "Members");
        menu.AddItem("history", "Clan history");
        menu.AddItem("invite", "Invite player");

        if (rank >= ClanRank_Officer)
        {
            menu.AddItem("kick", "Kick player");
            menu.AddItem("war", "Declare war");
        }

        if (rank >= ClanRank_Owner)
        {
            menu.AddItem("rename", "Rename clan");
            menu.AddItem("tag", "Clan tag");
            menu.AddItem("desc", "Clan description");
            menu.AddItem("open", isOpen ? "Close clan joining" : "Open clan joining");
            menu.AddItem("parent", "Parent clan");
        }
    }
    else
    {
        if (inviteCount > 0)
        {
            FormatEx(title, sizeof(title), "Clan Menu\nYou are not in a clan\nPending invites: %d", inviteCount);
        }
        else
        {
            strcopy(title, sizeof(title), "Clan Menu\nYou are not in a clan");
        }

        menu.SetTitle(title);

        char createLabel[96];
        if (IsClanGemStoreAvailable())
        {
            FormatEx(createLabel, sizeof(createLabel), "Create clan (-%d Gems)", CLAN_CREATE_GEM_COST);
            menu.AddItem("create", createLabel);
        }
        else
        {
            FormatEx(createLabel, sizeof(createLabel), "Create clan (Gems unavailable)");
            menu.AddItem("create_disabled", createLabel, ITEMDRAW_DISABLED);
        }
        menu.AddItem("join", "Join open clan");

        if (inviteCount > 0)
        {
            char invitesLabel[64];
            FormatEx(invitesLabel, sizeof(invitesLabel), "Invites (%d)", inviteCount);
            menu.AddItem("invites", invitesLabel);
        }
        else
        {
            menu.AddItem("noop_invites", "Invites (0)", ITEMDRAW_DISABLED);
        }

        if (inviteCount > 0)
        {
            char acceptLabel[64];
            char denyLabel[64];

            FormatEx(acceptLabel, sizeof(acceptLabel), "Accept invite%s (%d)", (inviteCount == 1) ? "" : "s", inviteCount);
            FormatEx(denyLabel, sizeof(denyLabel), "Deny invite%s (%d)", (inviteCount == 1) ? "" : "s", inviteCount);

            menu.AddItem("accept", acceptLabel);
            menu.AddItem("deny", denyLabel);
        }
    }

    menu.AddItem("refresh", "Refresh");
    menu.Display(client, CLAN_MENU_TIME);
}

public Action Command_ClanMenu(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) AS clan_id, "
        ... "(SELECT rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1) AS rank, "
        ... "(SELECT name FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS clan_name, "
        ... "(SELECT tag FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS clan_tag, "
        ... "(SELECT is_open FROM clans WHERE id = (SELECT clan_id FROM clan_members WHERE steamid64 = '%s' LIMIT 1) LIMIT 1) AS is_open, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE steamid64 = '%s' AND expires_at > %d) AS invite_count",
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        escapedSteam,
        GetTime());

    g_Database.Query(SQL_OnClanMenuContext, query, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClansList(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, ("
        ... "SELECT COUNT(1) FROM clan_members cm WHERE cm.clan_id = c.id"
        ... ") + ("
        ... "SELECT COUNT(1) "
        ... "FROM clan_members cm_child "
        ... "INNER JOIN clan_relations cr ON cr.clan_id_a = cm_child.clan_id "
        ... "WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id"
        ... ") AS member_count, "
        ... "(SELECT COALESCE(SUM(COALESCE(pb.balance, 0)), 0) "
        ... "FROM clan_members cm "
        ... "LEFT JOIN points_store_balances pb ON pb.steamid64 = cm.steamid64 "
        ... "WHERE cm.clan_id = c.id "
        ... "OR cm.clan_id IN (SELECT cr.clan_id_a FROM clan_relations cr WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id)) AS cached_gems "
        ... "FROM clans c "
        ... "ORDER BY member_count DESC, c.name ASC");

    g_Database.Query(SQL_OnClansListMenu, query, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClanHelp(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    CPrintToChat(client, "{green}[Clans]{default} !clan: open the clan menu.");
    CPrintToChat(client, "{green}[Clans]{default} !clans: browse existing clans.");
    CPrintToChat(client, "{green}[Clans]{default} !claninvite <player>: invite a player.");
    CPrintToChat(client, "{green}[Clans]{default} !claninfo <player|name|tag>: show clan info.");
    CPrintToChat(client, "{green}[Clans]{default} !clanmembers: show your clan members.");
    CPrintToChat(client, "{green}[Clans]{default} !clanwar: declare war or surrender.");
    CPrintToChat(client, "{green}[Clans]{default} !clankick <player>: kick a member.");
    CPrintToChat(client, "{green}[Clans]{default} !clantag: set main tag or your sub-tag.");
    return Plugin_Handled;
}

public Action Command_ClanChat(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "[Clans] Usage: sm_cc <message>");
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char message[192];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);
    TrimString(message);

    if (!message[0])
    {
        PrintToChat(client, "[Clans] Usage: sm_cc <message>");
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(message);

    GetClanByPlayer(steamid64, SQL_OnClanChatContext, pack);
    return Plugin_Handled;
}

public void SQL_OnClanChatContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char message[192];
    pack.ReadString(message, sizeof(message));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan chat context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char clanDisplayTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanByPlayerCol_Tag, clanTag, sizeof(clanTag));
    BuildClanDisplayTag(clanTag, clanDisplayTag, sizeof(clanDisplayTag));

    char senderName[384];
    BuildClanChatSenderName(client, senderName, sizeof(senderName));

    char output[768];
    if (clanDisplayTag[0])
    {
        FormatEx(output, sizeof(output), "%s %s: %s", clanDisplayTag, senderName, message);
    }
    else
    {
        FormatEx(output, sizeof(output), "%s: %s", senderName, message);
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsConnectedClientInClan(i, clanId))
        {
            continue;
        }

        ClansCPrintToChatExWrapped(i, client, "%s", output);
    }
}

public Action Command_ClanWar(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureClanWarsAvailable(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    int clanId = 0;
    ClanRank rank = ClanRank_Member;
    if (!GetLoadedClientClanContext(client, steamid64, sizeof(steamid64), clanId, rank, clanName, sizeof(clanName), clanTag, sizeof(clanTag)))
    {
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return Plugin_Handled;
    }

    if (clanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return Plugin_Handled;
    }

    if (rank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can declare war.");
        return Plugin_Handled;
    }

    int warId = 0;
    int clanIdA = 0;
    int clanIdB = 0;
    int scoreA = 0;
    int scoreB = 0;
    if (GetActiveClanWarForClanCached(clanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        ShowClanWarDecisionMenu(client, (clanIdA == clanId) ? clanIdB : clanIdA, true);
        return Plugin_Handled;
    }

    ShowClanWarTargetMenu(client, clanId);
    return Plugin_Handled;
}

public Action Command_ClanHistory(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    int clanId = 0;
    ClanRank rank = ClanRank_Member;
    if (!GetClientClanContextSync(client, steamid64, sizeof(steamid64), clanId, rank, clanName, sizeof(clanName), clanTag, sizeof(clanTag)))
    {
        PrintToChat(client, "[Clans] Failed to load your clan history.");
        return Plugin_Handled;
    }

    if (clanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return Plugin_Handled;
    }

    ShowClanHistoryMenu(client, clanId, clanName);
    return Plugin_Handled;
}

void ShowClanWarTargetMenu(int client, int actorClanId)
{
    if (!EnsureClanWarsAvailable(client))
    {
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanWarTarget);
    menu.SetTitle("Declare War");
    menu.ExitBackButton = true;

    int seenClanIds[MAXPLAYERS + 1];
    int seenCount = 0;
    bool added = false;

    for (int pass = 0; pass < 2; pass++)
    {
        ClanRank desiredRank = (pass == 0) ? ClanRank_Owner : ClanRank_Officer;

        for (int target = 1; target <= MaxClients; target++)
        {
            if (!IsPlayableClient(target) || target == client)
            {
                continue;
            }

            char targetSteam[STEAMID64_MAXLEN];
            char targetClanName[CLAN_NAME_MAXLEN + 1];
            char targetClanTag[CLAN_TAG_STORE_MAXLEN];
            int targetClanId = 0;
            ClanRank targetRank = ClanRank_Member;
            if (!GetLoadedClientClanContext(target, targetSteam, sizeof(targetSteam), targetClanId, targetRank, targetClanName, sizeof(targetClanName), targetClanTag, sizeof(targetClanTag)))
            {
                continue;
            }

            if (targetClanId <= 0 || targetClanId == actorClanId || targetRank != desiredRank)
            {
                continue;
            }

            bool alreadySeen = false;
            for (int i = 0; i < seenCount; i++)
            {
                if (seenClanIds[i] == targetClanId)
                {
                    alreadySeen = true;
                    break;
                }
            }

            if (alreadySeen)
            {
                continue;
            }

            int warId = 0;
            int clanIdA = 0;
            int clanIdB = 0;
            int scoreA = 0;
            int scoreB = 0;
            if (GetActiveClanWarForClanCached(targetClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
            {
                continue;
            }

            seenClanIds[seenCount++] = targetClanId;

            char displayTag[CLAN_TAG_STORE_MAXLEN];
            char targetName[MAX_NAME_LENGTH];
            char display[192];
            char info[16];
            BuildClanDisplayTag(targetClanTag, displayTag, sizeof(displayTag));
            GetClientName(target, targetName, sizeof(targetName));
            IntToString(targetClanId, info, sizeof(info));

            if (displayTag[0])
            {
                FormatEx(display, sizeof(display), "%s %s - %s", displayTag, targetClanName, targetName);
            }
            else
            {
                FormatEx(display, sizeof(display), "%s - %s", targetClanName, targetName);
            }

            CRemoveTags(display, sizeof(display));
            menu.AddItem(info, display);
            added = true;
        }
    }

    if (!added)
    {
        menu.AddItem("none", "No eligible clan owners/officers are online", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

void ShowClanWarDecisionMenu(int client, int targetClanId, bool surrender)
{
    if (!EnsureClanWarsAvailable(client))
    {
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    char actorClanName[CLAN_NAME_MAXLEN + 1];
    char actorClanTag[CLAN_TAG_STORE_MAXLEN];
    int actorClanId = 0;
    ClanRank actorRank = ClanRank_Member;
    if (!GetLoadedClientClanContext(client, actorSteam, sizeof(actorSteam), actorClanId, actorRank, actorClanName, sizeof(actorClanName), actorClanTag, sizeof(actorClanTag)) || actorClanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanWarDecision);
    char title[512];

    if (surrender)
    {
        int warId = 0;
        int clanIdA = 0;
        int clanIdB = 0;
        int scoreA = 0;
        int scoreB = 0;
        if (!GetActiveClanWarByPairCached(actorClanId, targetClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
        {
            PrintToChat(client, "[Clans] You are not currently at war with that clan.");
            delete menu;
            return;
        }

        int actorScore = (actorClanId == clanIdA) ? scoreA : scoreB;
        int targetScore = (targetClanId == clanIdA) ? scoreA : scoreB;

        char targetLabel[96];
        int warIndex = FindActiveWarIndexByPair(actorClanId, targetClanId);
        if (warIndex != -1)
        {
            ActiveClanWar war;
            g_hActiveWars.GetArray(warIndex, war);
            strcopy(targetLabel, sizeof(targetLabel), (targetClanId == war.clanIdA) ? war.announceLabelA : war.announceLabelB);
        }
        if (!targetLabel[0])
        {
            FormatEx(targetLabel, sizeof(targetLabel), "%d", targetClanId);
        }
        CRemoveTags(targetLabel, sizeof(targetLabel));
        TrimString(targetLabel);
        FormatEx(title, sizeof(title), "Clan War\nOpponent: %s\nCurrent score: %d - %d", targetLabel, actorScore, targetScore);
    }
    else
    {
        char targetClanName[CLAN_NAME_MAXLEN + 1];
        char targetClanTag[CLAN_TAG_STORE_MAXLEN];
        char representativeName[MAX_NAME_LENGTH * 2];
        int onlineCount = 0;
        if (!GetCachedOnlineClanSummary(targetClanId, targetClanName, sizeof(targetClanName), targetClanTag, sizeof(targetClanTag), representativeName, sizeof(representativeName), onlineCount))
        {
            PrintToChat(client, "[Clans] That clan is not available.");
            delete menu;
            return;
        }

        char plainTag[CLAN_TAG_STORE_MAXLEN];
        BuildPlainClanTag(targetClanTag, plainTag, sizeof(plainTag));
        FormatEx(title, sizeof(title),
            "Clan War\n%s\nTag: %s\nRepresented by: %s\nOnline members: %d",
            targetClanName,
            plainTag[0] ? plainTag : "(none)",
            representativeName[0] ? representativeName : "online member",
            onlineCount);
    }

    menu.SetTitle(title);
    menu.ExitBackButton = true;

    char info[32];
    FormatEx(info, sizeof(info), "%s:%d", surrender ? "surrender" : "declare", targetClanId);
    menu.AddItem(info, surrender ? "Surrender" : "Go to war");
    menu.AddItem("cancel", "Cancel");
    menu.Display(client, CLAN_MENU_TIME);
}

void ShowClanWarSurrenderConfirmMenu(int client, int targetClanId)
{
    if (!EnsureClanWarsAvailable(client))
    {
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    char actorClanName[CLAN_NAME_MAXLEN + 1];
    char actorClanTag[CLAN_TAG_STORE_MAXLEN];
    int actorClanId = 0;
    ClanRank actorRank = ClanRank_Member;
    if (!GetLoadedClientClanContext(client, actorSteam, sizeof(actorSteam), actorClanId, actorRank, actorClanName, sizeof(actorClanName), actorClanTag, sizeof(actorClanTag)) || actorClanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can surrender a war.");
        return;
    }

    int warId = 0;
    int clanIdA = 0;
    int clanIdB = 0;
    int scoreA = 0;
    int scoreB = 0;
    if (!GetActiveClanWarByPairCached(actorClanId, targetClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        PrintToChat(client, "[Clans] You are not currently at war with that clan.");
        return;
    }

    int actorScore = (actorClanId == clanIdA) ? scoreA : scoreB;
    int targetScore = (targetClanId == clanIdA) ? scoreA : scoreB;

    char targetLabel[96];
    targetLabel[0] = '\0';
    int warIndex = FindActiveWarIndexByPair(actorClanId, targetClanId);
    if (warIndex != -1)
    {
        ActiveClanWar war;
        g_hActiveWars.GetArray(warIndex, war);
        strcopy(targetLabel, sizeof(targetLabel), (targetClanId == war.clanIdA) ? war.announceLabelA : war.announceLabelB);
    }
    if (!targetLabel[0])
    {
        FormatEx(targetLabel, sizeof(targetLabel), "%d", targetClanId);
    }
    CRemoveTags(targetLabel, sizeof(targetLabel));
    TrimString(targetLabel);

    Menu menu = new Menu(MenuHandler_ClanWarSurrenderConfirm);
    char title[512];
    FormatEx(title, sizeof(title), "Confirm Surrender\nOpponent: %s\nCurrent score: %d - %d\nThis will end the war.", targetLabel, actorScore, targetScore);
    menu.SetTitle(title);
    menu.ExitBackButton = true;

    char info[16];
    IntToString(targetClanId, info, sizeof(info));
    menu.AddItem("cancel", "Cancel");
    menu.AddItem(info, "Confirm surrender");
    menu.Display(client, CLAN_MENU_TIME);
}

void HandleClanWarDeclare(int client, int targetClanId)
{
    if (!EnsureClanWarsAvailable(client))
    {
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    char actorClanName[CLAN_NAME_MAXLEN + 1];
    char actorClanTag[CLAN_TAG_STORE_MAXLEN];
    int actorClanId = 0;
    ClanRank actorRank = ClanRank_Member;
    if (!GetLoadedClientClanContext(client, actorSteam, sizeof(actorSteam), actorClanId, actorRank, actorClanName, sizeof(actorClanName), actorClanTag, sizeof(actorClanTag)))
    {
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (actorClanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can declare war.");
        return;
    }

    int warId = 0;
    int clanIdA = 0;
    int clanIdB = 0;
    int scoreA = 0;
    int scoreB = 0;
    if (GetActiveClanWarForClanCached(actorClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        ShowClanWarDecisionMenu(client, (clanIdA == actorClanId) ? clanIdB : clanIdA, true);
        return;
    }

    if (targetClanId == actorClanId)
    {
        PrintToChat(client, "[Clans] You cannot declare war on your own clan.");
        return;
    }

    if (GetActiveClanWarForClanCached(targetClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        PrintToChat(client, "[Clans] That clan is already at war.");
        return;
    }

    int cooldownSeconds = 0;
    if (GetClanWarRedeclareCooldownSync(actorClanId, targetClanId, cooldownSeconds))
    {
        char targetLabel[96];
        GetClanWarTargetCooldownLabel(targetClanId, targetLabel, sizeof(targetLabel));
        int cooldownMinutes = (cooldownSeconds + 59) / 60;
        CPrintToChat(client, "{green}[Clans]{default} You can't declare war on %s until %d minutes from now.", targetLabel, cooldownMinutes);
        return;
    }

    if (!StartClanWarAsync(client, actorClanId, targetClanId, actorSteam))
    {
        PrintToChat(client, "[Clans] Failed to declare war.");
        return;
    }

    PrintToChat(client, "[Clans] War declaration queued.");
}

void HandleClanWarSurrender(int client, int targetClanId)
{
    if (!EnsureClanWarsAvailable(client))
    {
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    char actorClanName[CLAN_NAME_MAXLEN + 1];
    char actorClanTag[CLAN_TAG_STORE_MAXLEN];
    int actorClanId = 0;
    ClanRank actorRank = ClanRank_Member;
    if (!GetLoadedClientClanContext(client, actorSteam, sizeof(actorSteam), actorClanId, actorRank, actorClanName, sizeof(actorClanName), actorClanTag, sizeof(actorClanTag)))
    {
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (actorClanId <= 0)
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can surrender a war.");
        return;
    }

    int warId = 0;
    int clanIdA = 0;
    int clanIdB = 0;
    int scoreA = 0;
    int scoreB = 0;
    if (!GetActiveClanWarByPairCached(actorClanId, targetClanId, warId, clanIdA, clanIdB, scoreA, scoreB))
    {
        PrintToChat(client, "[Clans] You are not currently at war with that clan.");
        return;
    }

    if (!FinalizeClanWarSync(warId, clanIdA, clanIdB, scoreA, scoreB, targetClanId, ClanWarStatus_Surrendered))
    {
        PrintToChat(client, "[Clans] Failed to surrender the war.");
        return;
    }

    PrintToChat(client, "[Clans] You surrendered the war.");
}

public int MenuHandler_ClanWarTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        int targetClanId = StringToInt(info);
        if (targetClanId > 0)
        {
            ShowClanWarDecisionMenu(param1, targetClanId, false);
        }
    }

    return 0;
}

public int MenuHandler_ClanWarDecision(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanWar(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "cancel", false))
        {
            Command_ClanMenu(param1, 0);
            return 0;
        }

        char pieces[2][16];
        int count = ExplodeString(info, ":", pieces, sizeof(pieces), sizeof(pieces[]));
        if (count != 2)
        {
            return 0;
        }

        int targetClanId = StringToInt(pieces[1]);
        if (targetClanId <= 0)
        {
            return 0;
        }

        if (StrEqual(pieces[0], "declare", false))
        {
            HandleClanWarDeclare(param1, targetClanId);
        }
        else if (StrEqual(pieces[0], "surrender", false))
        {
            ShowClanWarSurrenderConfirmMenu(param1, targetClanId);
        }
    }

    return 0;
}

public int MenuHandler_ClanWarSurrenderConfirm(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanWar(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "cancel", false))
        {
            Command_ClanWar(param1, 0);
            return 0;
        }

        int targetClanId = StringToInt(info);
        if (targetClanId > 0)
        {
            HandleClanWarSurrender(param1, targetClanId);
        }
    }

    return 0;
}

public int MenuHandler_ClanHistory(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        if (client <= 0 || !IsClientInGame(client))
        {
            return 0;
        }

        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        char pieces[2][16];
        if (ExplodeString(info, ":", pieces, sizeof(pieces), sizeof(pieces[])) == 2 && StrEqual(pieces[0], "war", false))
        {
            int warInstanceId = StringToInt(pieces[1]);
            if (warInstanceId > 0)
            {
                ShowClanWarHistoryDetailsMenu(client, g_iClanHistoryMenuClanId[client], g_sClanHistoryMenuClanName[client], warInstanceId);
            }
        }
    }

    return 0;
}

public int MenuHandler_ClanWarHistoryDetails(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            ShowClanHistoryMenu(param1, g_iClanHistoryMenuClanId[param1], g_sClanHistoryMenuClanName[param1]);
        }
    }

    return 0;
}

void PrintClanWarGemStealMessages(int attacker, int victim, int stolen)
{
    if (stolen <= 0)
    {
        return;
    }

    char attackerName[384];
    char victimName[384];
    BuildClanChatSenderName(attacker, attackerName, sizeof(attackerName));
    BuildClanChatSenderName(victim, victimName, sizeof(victimName));

    CPrintToChatEx(victim, attacker, "{cyan}[Gems]{default} %s stole {red}%d {cyan}Gems{default} from you!", attackerName, stolen);
    CPrintToChatEx(attacker, victim, "{cyan}[Gems]{default} You stole {green}+%d {cyan}Gems {default}from %s!", stolen, victimName);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int deathFlags = event.GetInt("death_flags");

    if (!ClanWarsRuntimeReady() || !Clans_IsRoundRunning())
    {
        return;
    }

    if (victim <= 0 || victim > MaxClients || attacker <= 0 || attacker > MaxClients || attacker == victim)
    {
        return;
    }

    if (deathFlags & TF_DEATHFLAG_DEADRINGER)
    {
        return;
    }

    if (!IsClientInGame(victim) || !IsClientInGame(attacker) || IsFakeClient(victim) || IsFakeClient(attacker))
    {
        return;
    }

    if (GetClientTeam(victim) <= 1 || GetClientTeam(attacker) <= 1 || GetClientTeam(victim) == GetClientTeam(attacker))
    {
        return;
    }

    int attackerClanId = 0;
    int victimClanId = 0;
    if (!ResolveClientClanIdForWarScoring(attacker, attackerClanId) || !ResolveClientClanIdForWarScoring(victim, victimClanId))
    {
        return;
    }

    if (attackerClanId <= 0 || victimClanId <= 0 || attackerClanId == victimClanId)
    {
        return;
    }

    int warIndex = FindActiveWarIndexByPair(attackerClanId, victimClanId);
    if (warIndex == -1)
    {
        return;
    }

    ActiveClanWar war;
    g_hActiveWars.GetArray(warIndex, war);

    bool attackerIsClanA = (attackerClanId == war.clanIdA);
    if (attackerIsClanA)
    {
        war.scoreA++;
    }
    else
    {
        war.scoreB++;
    }

    war.writeDirty = true;

    g_hActiveWars.SetArray(warIndex, war);

    int stolen = StealClanWarGems(attacker, victim, CLAN_WAR_GEMS_STOLEN_PER_KILL);
    if (stolen > 0)
    {
        PrintClanWarGemStealMessages(attacker, victim, stolen);
    }

    char attackerSteam[STEAMID64_MAXLEN];
    if (war.instanceId > 0 && GetClientSteam64(attacker, attackerSteam, sizeof(attackerSteam)))
    {
        RecordClanWarKill(war.instanceId, attackerClanId, attackerSteam, stolen);
    }

    int attackerScore = attackerIsClanA ? war.scoreA : war.scoreB;
    int victimScore = attackerIsClanA ? war.scoreB : war.scoreA;

    BroadcastClanWarScoreUpdate(
        attackerIsClanA ? war.announceLabelA : war.announceLabelB,
        attackerIsClanA ? war.announceLabelB : war.announceLabelA,
        attackerClanId,
        victimClanId,
        attackerScore,
        victimScore,
        war.instanceId,
        attacker,
        victim);

    if (attackerScore >= CLAN_WAR_POINT_GOAL)
    {
        FinalizeClanWarSync(war.warId, war.clanIdA, war.clanIdB, war.scoreA, war.scoreB, attackerClanId, ClanWarStatus_Finished);
    }
}

public void SQL_OnClansListMenu(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan list query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load the clan list.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClansList);
    menu.SetTitle("Clans");
    menu.ExitButton = true;

    bool added = false;
    if (results != null)
    {
        while (results.FetchRow())
        {
            int clanId = results.FetchInt(0);
            int memberCount = results.FetchInt(3);
            int cachedGems = results.FetchInt(4);

            char name[CLAN_NAME_MAXLEN + 1];
            char tag[CLAN_TAG_STORE_MAXLEN];
            char info[96];
            char display[192];

            results.FetchString(1, name, sizeof(name));
            results.FetchString(2, tag, sizeof(tag));
            FormatEx(info, sizeof(info), "%d|%s", clanId, name);

            if (tag[0])
            {
                FormatEx(display, sizeof(display), "%s %s (%d, %d Gems)", name, tag, memberCount, cachedGems);
            }
            else
            {
                FormatEx(display, sizeof(display), "%s (%d, %d Gems)", name, memberCount, cachedGems);
            }

            CRemoveTags(display, sizeof(display));
            menu.AddItem(info, display);
            added = true;
        }
    }

    if (!added)
    {
        menu.AddItem("none", "No clans found", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClansList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        int clanId = StringToInt(info);
        if (clanId > 0)
        {
            GetClanInfoById(clanId, SQL_OnClanInfoMenu, GetClientUserId(param1));
        }
    }

    return 0;
}

public void SQL_OnClanInfoMenu(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info menu query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Clan not found.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char ownerSteam[STEAMID64_MAXLEN];
    char description[CLAN_DESC_MAXLEN + 1];
    char ownerName[MAX_NAME_LENGTH * 2];
    char title[192];
    char line[256];

    results.FetchString(1, clanName, sizeof(clanName));
    results.FetchString(2, clanTag, sizeof(clanTag));
    results.FetchString(3, ownerSteam, sizeof(ownerSteam));
    results.FetchString(4, description, sizeof(description));
    ResolvePlayerDisplayName(ownerSteam, ownerName, sizeof(ownerName));

    Menu menu = new Menu(MenuHandler_ClanInfoMenu);
    FormatEx(title, sizeof(title), "Clan Info\n%s", clanName);
    menu.SetTitle(title);

    FormatEx(line, sizeof(line), "Hokage: %s", ownerName);
    menu.AddItem("owner", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Clan tag: %s", clanTag[0] ? clanTag : "(none)");
    menu.AddItem("tag", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Desc: %s", description[0] ? description : "(none)");
    menu.AddItem("desc", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Member count: %d", results.FetchInt(5));
    menu.AddItem("members", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Gems: %d", results.FetchInt(6));
    menu.AddItem("gems", line, ITEMDRAW_DISABLED);

    menu.ExitButton = true;
    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanInfoMenu(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public void SQL_OnClanMenuContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan menu context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan menu.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        ShowClanMainMenu(client, 0, ClanRank_Member, "", "", false, 0);
        return;
    }

    int clanId = results.FetchInt(ClanMenuCol_ClanId);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanMenuCol_Rank));
    int inviteCount = results.FetchInt(ClanMenuCol_InviteCount);
    bool isOpen = (results.FetchInt(ClanMenuCol_IsOpen) != 0);

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanMenuCol_ClanName, clanName, sizeof(clanName));
    results.FetchString(ClanMenuCol_ClanTag, clanTag, sizeof(clanTag));

    ShowClanMainMenu(client, clanId, rank, clanName, clanTag, isOpen, inviteCount);
}

public int MenuHandler_ClanMain(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "create", false))
        {
            Command_ClanCreate(client, 0);
        }
        else if (StrEqual(info, "join", false))
        {
            Command_ClanJoin(client, 0);
        }
        else if (StrEqual(info, "invites", false))
        {
            Command_ClanInvites(client, 0);
        }
        else if (StrEqual(info, "accept", false))
        {
            Command_ClanAcceptInvite(client, 0);
        }
        else if (StrEqual(info, "deny", false))
        {
            Command_ClanDenyInvite(client, 0);
        }
        else if (StrEqual(info, "leave", false))
        {
            Command_ClanLeave(client, 0);
        }
        else if (StrEqual(info, "members", false))
        {
            Command_ClanMembers(client, 0);
        }
        else if (StrEqual(info, "history", false))
        {
            Command_ClanHistory(client, 0);
        }
        else if (StrEqual(info, "tag", false))
        {
            StartClanTagPrompt(client);
        }
        else if (StrEqual(info, "rename", false))
        {
            Command_ClanRename(client, 0);
        }
        else if (StrEqual(info, "desc", false))
        {
            Command_ClanDesc(client, 0);
        }
        else if (StrEqual(info, "invite", false))
        {
            ShowClanInviteTargetMenu(client);
        }
        else if (StrEqual(info, "kick", false))
        {
            ShowClanKickTargetMenu(client);
        }
        else if (StrEqual(info, "war", false))
        {
            Command_ClanWar(client, 0);
        }
        else if (StrEqual(info, "open", false))
        {
            Command_ClanOpen(client, 0);
        }
        else if (StrEqual(info, "parent", false))
        {
            Command_ClanParent(client, 0);
        }
        else if (StrEqual(info, "refresh", false))
        {
            Command_ClanMenu(client, 0);
        }
    }

    return 0;
}

public Action Command_ClanMembers(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanMembersContext, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClanDesc(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanDescPromptContext, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClanRename(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanRenamePromptContext, GetClientUserId(client));
    return Plugin_Handled;
}

public Action Command_ClanSetDesc(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name, c.tag, ("
        ... "SELECT COUNT(1) FROM clan_members cm WHERE cm.clan_id = c.id"
        ... ") + ("
        ... "SELECT COUNT(1) "
        ... "FROM clan_members cm_child "
        ... "INNER JOIN clan_relations cr ON cr.clan_id_a = cm_child.clan_id "
        ... "WHERE cr.relation_type = 3 AND cr.clan_id_b = c.id"
        ... ") AS member_count "
        ... "FROM clans c "
        ... "ORDER BY member_count DESC, c.name ASC");

    g_Database.Query(SQL_OnClanSetDescMenu, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanSetDescMenu(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan setdesc list query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load the clan list.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanSetDescList);
    menu.SetTitle("Set Clan Desc");
    menu.ExitButton = true;

    bool added = false;
    if (results != null)
    {
        while (results.FetchRow())
        {
            int clanId = results.FetchInt(0);
            int memberCount = results.FetchInt(3);

            char name[CLAN_NAME_MAXLEN + 1];
            char tag[CLAN_TAG_STORE_MAXLEN];
            char info[96];
            char display[192];

            results.FetchString(1, name, sizeof(name));
            results.FetchString(2, tag, sizeof(tag));
            FormatEx(info, sizeof(info), "%d|%s", clanId, name);

            if (tag[0])
            {
                FormatEx(display, sizeof(display), "%s %s (%d)", name, tag, memberCount);
            }
            else
            {
                FormatEx(display, sizeof(display), "%s (%d)", name, memberCount);
            }

            menu.AddItem(info, display);
            added = true;
        }
    }

    if (!added)
    {
        menu.AddItem("none", "No clans found", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanSetDescList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[96];
        menu.GetItem(param2, info, sizeof(info));

        int sep = StrContains(info, "|");
        if (sep == -1)
        {
            return 0;
        }

        char clanIdText[16];
        char clanName[CLAN_NAME_MAXLEN + 1];
        strcopy(clanIdText, sizeof(clanIdText), info);
        clanIdText[sep] = '\0';
        strcopy(clanName, sizeof(clanName), info[sep + 1]);

        int clanId = StringToInt(clanIdText);
        if (clanId <= 0)
        {
            return 0;
        }

        g_PendingAdminClanDescId[param1] = clanId;
        strcopy(g_PendingAdminClanDescName[param1], sizeof(g_PendingAdminClanDescName[]), clanName);
        g_PromptState[param1] = Prompt_ClanAdminDescInput;

        PrintToChat(param1, "[Clans] Type the new description for '%s' in chat. Max length: %d. Type /cancel to abort.", clanName, CLAN_DESC_MAXLEN);
    }

    return 0;
}

public void SQL_OnClanDescPromptContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan description prompt context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank)) < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can set the clan description.");
        return;
    }

    g_PromptState[client] = Prompt_ClanDescInput;
    PrintToChat(client, "[Clans] Type your clan description in chat. Max length: %d. Type /cancel to abort.", CLAN_DESC_MAXLEN);
}

public void SQL_OnClanRenamePromptContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan rename prompt context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank)) < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can rename the clan.");
        return;
    }

    g_PromptState[client] = Prompt_ClanRenameName;
    PrintToChat(client, "[Clans] Type the new clan name in chat. Type /cancel to abort.");
}

public void SQL_OnClanDescContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char description[CLAN_DESC_MAXLEN + 1];
    pack.ReadString(description, sizeof(description));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan description context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank)) < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can set the clan description.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(description);

    SetClanDescription(clanId, description, SQL_OnClanDescSet, next);
}

public void SQL_OnAdminClanDescContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char description[CLAN_DESC_MAXLEN + 1];
    char fallbackClanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(description, sizeof(description));
    pack.ReadString(fallbackClanName, sizeof(fallbackClanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Admin clan description context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up that clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That clan no longer exists.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(1, clanName, sizeof(clanName));
    if (!clanName[0])
    {
        strcopy(clanName, sizeof(clanName), fallbackClanName);
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(clanName);
    next.WriteString(description);

    SetClanDescription(clanId, description, SQL_OnAdminClanDescSet, next);
}

public void SQL_OnClanDescSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char description[CLAN_DESC_MAXLEN + 1];
    pack.ReadString(description, sizeof(description));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set description failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set the clan description.");
        return;
    }

    PrintToChat(client, "[Clans] Clan description updated.");
}

public void SQL_OnAdminClanDescSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char description[CLAN_DESC_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(description, sizeof(description));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Admin set description failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set that clan description.");
        return;
    }

    PrintToChat(client, "[Clans] Clan description updated for '%s'.", clanName);
}

public Action Command_ClanInfo(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninfo <player|clan name|clan tag|sub-tag>");
        return Plugin_Handled;
    }

    char input[192];
    GetCmdArgString(input, sizeof(input));
    StripQuotes(input);
    TrimString(input);

    if (!input[0])
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninfo <player|clan name|clan tag|sub-tag>");
        return Plugin_Handled;
    }

    int target = FindClientByNameQuery(input);
    if (target > 0)
    {
        char steamid64[STEAMID64_MAXLEN];
        if (!GetClientSteam64(target, steamid64, sizeof(steamid64)))
        {
            PrintToChat(client, "[Clans] Could not read that player's SteamID64.");
            return Plugin_Handled;
        }

        GetClanByPlayer(steamid64, SQL_OnClanInfoPlayerLookup, GetClientUserId(client));
        return Plugin_Handled;
    }

    char escapedInput[256];
    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    char escapedFormatted[256];
    EscapeSql(input, escapedInput, sizeof(escapedInput));
    FormatStoredClanTag(input, formattedTag, sizeof(formattedTag));
    EscapeSql(formattedTag, escapedFormatted, sizeof(escapedFormatted));

    char query[1400];
    FormatEx(query, sizeof(query),
        "SELECT DISTINCT c.id "
        ... "FROM clans c "
        ... "LEFT JOIN clan_sub_tags cst ON cst.clan_id = c.id "
        ... "WHERE LOWER(c.name) = LOWER('%s') "
        ... "OR LOWER(c.tag) = LOWER('%s') "
        ... "OR LOWER(c.tag) = LOWER('%s') "
        ... "OR LOWER(cst.tag) = LOWER('%s') "
        ... "OR LOWER(c.name) LIKE LOWER('%%%s%%') "
        ... "OR LOWER(c.tag) LIKE LOWER('%%%s%%') "
        ... "OR LOWER(cst.tag) LIKE LOWER('%%%s%%') "
        ... "ORDER BY CASE "
        ... "WHEN LOWER(c.name) = LOWER('%s') THEN 0 "
        ... "WHEN LOWER(c.tag) = LOWER('%s') THEN 1 "
        ... "WHEN LOWER(c.tag) = LOWER('%s') THEN 2 "
        ... "WHEN LOWER(cst.tag) = LOWER('%s') THEN 3 "
        ... "WHEN LOWER(c.name) LIKE LOWER('%%%s%%') THEN 4 "
        ... "WHEN LOWER(c.tag) LIKE LOWER('%%%s%%') THEN 5 "
        ... "WHEN LOWER(cst.tag) LIKE LOWER('%%%s%%') THEN 6 "
        ... "ELSE 7 END, c.id ASC "
        ... "LIMIT 1",
        escapedInput,
        escapedInput,
        escapedFormatted,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedFormatted,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput);

    g_Database.Query(SQL_OnClanInfoSearchLookup, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanInfoPlayerLookup(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info player lookup failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That player is not in a clan.");
        return;
    }

    GetClanInfoById(results.FetchInt(ClanByPlayerCol_Id), SQL_OnClanInfoById, GetClientUserId(client));
}

public void SQL_OnClanInfoSearchLookup(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info search lookup failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] No clan matched that query.");
        return;
    }

    GetClanInfoById(results.FetchInt(0), SQL_OnClanInfoById, GetClientUserId(client));
}

public void SQL_OnClanInfoById(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan info query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan info.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Clan not found.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char ownerSteam[STEAMID64_MAXLEN];
    char description[CLAN_DESC_MAXLEN + 1];
    char ownerName[MAX_NAME_LENGTH * 2];

    results.FetchString(1, clanName, sizeof(clanName));
    results.FetchString(2, clanTag, sizeof(clanTag));
    results.FetchString(3, ownerSteam, sizeof(ownerSteam));
    results.FetchString(4, description, sizeof(description));
    ResolvePlayerDisplayName(ownerSteam, ownerName, sizeof(ownerName));

    CPrintToChat(client, "{default}[Clans] %s", clanName);
    CPrintToChat(client, "{default}[Clans] Hokage: %s", ownerName);
    CPrintToChat(client, "{default}[Clans] Clan tag: %s", clanTag[0] ? clanTag : "(none)");
    CPrintToChat(client, "{default}[Clans] Desc: %s", description[0] ? description : "(none)");
    CPrintToChat(client, "{default}[Clans] Member count: %d", results.FetchInt(5));
    CPrintToChat(client, "{default}[Clans] Gems: %d", results.FetchInt(6));
}

public Action Command_ClanGems(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_clangems <clan name or online player>");
        return Plugin_Handled;
    }

    char input[192];
    GetCmdArgString(input, sizeof(input));
    StripQuotes(input);
    TrimString(input);

    if (!input[0])
    {
        ReplyToCommand(client, "[Clans] Usage: sm_clangems <clan name or online player>");
        return Plugin_Handled;
    }

    char escapedInput[256];
    EscapeSql(input, escapedInput, sizeof(escapedInput));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT c.id, c.name "
        ... "FROM clans c "
        ... "WHERE LOWER(c.name) = LOWER('%s') "
        ... "OR LOWER(c.name) LIKE LOWER('%s%%') "
        ... "OR LOWER(c.name) LIKE LOWER('%%%s%%') "
        ... "ORDER BY CASE "
        ... "WHEN LOWER(c.name) = LOWER('%s') THEN 0 "
        ... "WHEN LOWER(c.name) LIKE LOWER('%s%%') THEN 1 "
        ... "ELSE 2 END, c.name ASC "
        ... "LIMIT 2",
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput,
        escapedInput);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(input);

    g_Database.Query(SQL_OnClanGemsSearchLookup, query, pack);
    return Plugin_Handled;
}

public void SQL_OnClanGemsSearchLookup(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char input[192];
    pack.ReadString(input, sizeof(input));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan Gems search failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up clan Gems.");
        return;
    }

    if (results != null && results.FetchRow())
    {
        int clanId = results.FetchInt(0);
        char matchedName[CLAN_NAME_MAXLEN + 1];
        results.FetchString(1, matchedName, sizeof(matchedName));

        if (!StrEqual(matchedName, input, false) && results.FetchRow())
        {
            PrintToChat(client, "[Clans] Multiple clans matched that query.");
            return;
        }

        QueryClanGemsById(clanId, SQL_OnClanGemsById, userId);
        return;
    }

    int target = FindClientByNameQuery(input);
    if (target <= 0)
    {
        PrintToChat(client, "[Clans] No clan or online player matched that query.");
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(target, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read that player's SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnClanGemsPlayerLookup, userId);
}

public void SQL_OnClanGemsPlayerLookup(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan Gems player lookup failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up clan Gems.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That player is not in a clan.");
        return;
    }

    QueryClanGemsById(results.FetchInt(ClanByPlayerCol_Id), SQL_OnClanGemsById, data);
}

public void SQL_OnClanGemsById(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan Gems aggregate query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to calculate clan Gems.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Clan not found.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(1, clanName, sizeof(clanName));

    CPrintToChat(client, "{default}[Clans] %s Gems: %d", clanName, results.FetchInt(2));
}

public void SQL_OnClanMembersContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan members context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan members.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    QueryClanMembersListForClient(GetClientUserId(client), clanId, clanName);
}

public void SQL_OnClanMembersList(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan members list query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan members.");
        return;
    }

    g_iClanMembersMenuClanId[client] = clanId;
    strcopy(g_sClanMembersMenuClanName[client], sizeof(g_sClanMembersMenuClanName[]), clanName);

    char clientSteamId[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, clientSteamId, sizeof(clientSteamId)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanMembersList);

    char title[192];
    FormatEx(title, sizeof(title), "Clan Members\n%s", clanName);
    menu.SetTitle(title);

    if (results != null)
    {
        while (results.FetchRow())
        {
            char steamid64[STEAMID64_MAXLEN];
            results.FetchString(ClanMemberListCol_SteamId64, steamid64, sizeof(steamid64));
            char label[192];
            BuildClanMemberMenuLabel(clientSteamId, steamid64, view_as<ClanRank>(results.FetchInt(ClanMemberListCol_Rank)), label, sizeof(label));
            menu.AddItem(steamid64, label);
        }
    }
    
    if (menu.ItemCount <= 0)
    {
        menu.AddItem("none", "No members found", ITEMDRAW_DISABLED);
    }

    menu.ExitBackButton = true;
    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanMembersList(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        if (client <= 0 || !IsClientInGame(client))
        {
            return 0;
        }

        char steamid64[STEAMID64_MAXLEN];
        menu.GetItem(param2, steamid64, sizeof(steamid64));

        if (!steamid64[0] || StrEqual(steamid64, "none", false))
        {
            return 0;
        }

        QueryClanMemberDetailsForClient(
            GetClientUserId(client),
            g_iClanMembersMenuClanId[client],
            g_sClanMembersMenuClanName[client],
            steamid64);
    }

    return 0;
}

public void SQL_OnClanMemberDetails(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan member details query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load clan member details.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to load that clan member.");
        return;
    }

    g_iClanMembersMenuClanId[client] = clanId;
    strcopy(g_sClanMembersMenuClanName[client], sizeof(g_sClanMembersMenuClanName[]), clanName);

    char playerName[MAX_NAME_LENGTH * 2];
    char rankLabel[16];
    char joinedAtText[64];
    char subTag[CLAN_SUB_TAG_STORE_MAXLEN];
    char title[192];
    char line[192];
    int totalWarKills = results.FetchInt(3);

    ResolvePlayerDisplayName(steamid64, playerName, sizeof(playerName));
    GetClanRankLabel(view_as<ClanRank>(results.FetchInt(0)), rankLabel, sizeof(rankLabel));
    FormatClanTimestamp(results.FetchInt(1), joinedAtText, sizeof(joinedAtText));
    results.FetchString(2, subTag, sizeof(subTag));
    TrimString(subTag);

    Menu menu = new Menu(MenuHandler_ClanMemberDetails);
    FormatEx(title, sizeof(title), "Clan Member\n%s", clanName);
    menu.SetTitle(title);

    FormatEx(line, sizeof(line), "Player Name: %s", playerName);
    menu.AddItem("name", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Rank: %s", rankLabel);
    menu.AddItem("rank", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Join Date: %s", joinedAtText);
    menu.AddItem("joined", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "Sub-Tag: %s", subTag[0] ? subTag : "None");
    menu.AddItem("subtag", line, ITEMDRAW_DISABLED);

    FormatEx(line, sizeof(line), "War Kills: %d", totalWarKills);
    menu.AddItem("warkills", line, ITEMDRAW_DISABLED);

    menu.ExitBackButton = true;
    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanMemberDetails(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            QueryClanMembersListForClient(
                GetClientUserId(param1),
                g_iClanMembersMenuClanId[param1],
                g_sClanMembersMenuClanName[param1]);
        }
    }

    return 0;
}

void StartSetClanSubTagFromInput(int client, const char[] input)
{
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    strcopy(rawTag, sizeof(rawTag), input);
    StripQuotes(rawTag);
    TrimString(rawTag);
    NormalizeClanTagText(rawTag);

    if (!rawTag[0])
    {
        PrintToChat(client, "[Clans] Sub-tag cannot be empty.");
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(rawTag);
    pack.WriteString(steamid64);

    GetClanByPlayer(steamid64, SQL_OnClanSubTagContext, pack);
}

void HandleClanCreateInput(int client, const char[] name)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    strcopy(clanName, sizeof(clanName), name);
    TrimString(clanName);

    if (!ValidateClanName(clanName))
    {
        PrintToChat(client, "[Clans] Clan names must be between 1 and %d characters.", CLAN_NAME_MAXLEN);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(clanName, escapedName, sizeof(escapedName));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clans WHERE name = '%s') AS name_taken",
        escapedSteam,
        escapedName);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(clanName);

    g_Database.Query(SQL_OnClanCreateValidate, query, pack);
}

void HandleClanRenameInput(int client, const char[] name)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    strcopy(clanName, sizeof(clanName), name);
    TrimString(clanName);

    if (!ValidateClanName(clanName))
    {
        PrintToChat(client, "[Clans] Clan names must be between 1 and %d characters.", CLAN_NAME_MAXLEN);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedName[SQL_CLAN_NAME_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(clanName, escapedName, sizeof(escapedName));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.id, cm.rank, "
        ... "(SELECT COUNT(1) FROM clans WHERE name = '%s' AND id != c.id) AS name_taken "
        ... "FROM clan_members cm "
        ... "INNER JOIN clans c ON c.id = cm.clan_id "
        ... "WHERE cm.steamid64 = '%s' LIMIT 1",
        escapedName,
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(clanName);

    g_Database.Query(SQL_OnClanRenameValidate, query, pack);
}

public void SQL_OnClanTagPromptContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan tag prompt context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    char currentTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanByPlayerCol_Tag, currentTag, sizeof(currentTag));
    TrimString(currentTag);

    if (!currentTag[0])
    {
        if (rank < ClanRank_Owner)
        {
            PrintToChat(client, "[Clans] Your clan owner must set a main clan tag before members can add sub-tags.");
            return;
        }

        g_PromptState[client] = Prompt_ClanTagInput;
        PrintToChat(client, "[Clans] Type your clan tag in chat. Type /cancel to abort.");
        return;
    }

    g_PromptState[client] = Prompt_ClanTagChoice;
    PrintToChat(client, "[Clans] Your clan already has a tag; use /cancel to cancel, /change to change the tag, and /sub to add an additional tag to your clan");
}

public Action Command_ClanCreate(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!IsClanGemStoreAvailable())
    {
        PrintToChat(client, "[Clans] Clan creation requires Gems.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    IsPlayerInClan(steamid64, SQL_OnClanCreateInitialCheck, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanCreateInitialCheck(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Create initial check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to check your clan state.");
        return;
    }

    if (results != null && results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    g_PromptState[client] = Prompt_ClanCreateName;
    PrintToChat(client, "[Clans] Type your clan name in chat. Type /cancel to abort.");
}

public void SQL_OnClanCreateValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Create validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate clan creation.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate clan creation.");
        return;
    }

    int inClan = results.FetchInt(0);
    int nameTaken = results.FetchInt(1);

    if (inClan > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (nameTaken > 0)
    {
        PrintToChat(client, "[Clans] That clan name is already taken.");
        return;
    }

    if (!SpendClanGems(client, CLAN_CREATE_GEM_COST))
    {
        PrintToChat(client, "[Clans] You need %d Gems to create a clan.", CLAN_CREATE_GEM_COST);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        GiveClanGems(client, CLAN_CREATE_GEM_COST);
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    CreateClan(steamid64, clanName, userId);
}

public void SQL_OnClanRenameValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Rename validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate the clan rename.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    if (view_as<ClanRank>(results.FetchInt(1)) < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can rename the clan.");
        return;
    }

    if (results.FetchInt(2) > 0)
    {
        PrintToChat(client, "[Clans] That clan name is already taken.");
        return;
    }

    int clanId = results.FetchInt(0);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(clanName);

    SetClanName(clanId, clanName, SQL_OnClanRenameSet, next);
}

public void SQLTxn_OnCreateClanSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char ownerSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(ownerSteam, sizeof(ownerSteam));
    delete pack;

    int clanId = 0;
    if (numQueries > 0)
    {
        clanId = results[0].InsertId;
    }

    if (ownerSteam[0] != '\0' && clanId > 0)
    {
        SetClientClanIdBySteam64(ownerSteam, clanId);
    }

    char ownerName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(ownerSteam, ownerName, sizeof(ownerName));
    if (clanId > 0)
    {
        AddClanHistoryEntry(clanId, "Clan created by %s", ownerName);
    }

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Clan '%s' created successfully. (ID %d)", clanName, clanId);
    }
}

public void SQL_OnClanRenameSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    pack.ReadString(clanName, sizeof(clanName));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Rename set failed: %s", error);

        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] That clan name is already taken.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to rename the clan.");
        }
        return;
    }

    PrintToChat(client, "[Clans] Clan renamed to '%s'.", clanName);
}

public void SQLTxn_OnCreateClanFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char ownerSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(ownerSteam, sizeof(ownerSteam));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        GiveClanGems(client, CLAN_CREATE_GEM_COST);

        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] That clan name is already taken.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to create clan '%s'.", clanName);
        }
    }

    LogError("[Clans] CreateClan transaction failed (query %d): %s", failIndex, error);
}

public Action Command_ClanLeave(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanLeaveContext, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanLeaveContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Leave context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (rank >= ClanRank_Owner)
    {
        g_PromptState[client] = Prompt_ClanLeaveConfirm;
        PrintToChat(client, "[Clans] You are the clan owner. Type /yes to delete the clan and refund %d Gems, or /cancel to abort.", CLAN_CREATE_GEM_COST);
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_sub_tags WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_members WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedSteam);
    txn.AddQuery(query);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(clanId);
    pack.WriteString(clanName);
    pack.WriteString(steamid64);

    g_Database.Execute(txn, SQL_OnClanLeaveSuccess, SQL_OnClanLeaveFailure, pack);
}

void StartOwnerDeleteClan(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnOwnerDeleteClanContext, GetClientUserId(client));
}

public void SQL_OnOwnerDeleteClanContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Owner delete context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] You are no longer the clan owner.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    DeleteClan(clanId, GetClientUserId(client), true);
}

public void SQL_OnClanLeaveSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    if (steamid64[0] != '\0')
    {
        SetClientClanIdBySteam64(steamid64, 0);
    }
    RefreshConnectedClanTagsForClan(clanId);

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    PrintToChat(client, "[Clans] You left '%s'.", clanName);
}

public void SQL_OnClanLeaveFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to leave your clan.");
    }

    LogError("[Clans] Leave clan transaction failed while leaving '%s' (query %d): %s", clanName, failIndex, error);
}

public void SQLTxn_OnDeleteClanSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    bool refundOwner = (pack.ReadCell() != 0);
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        if (refundOwner)
        {
            GiveClanGems(client, CLAN_CREATE_GEM_COST);
        }

        PrintToChat(client, "[Clans] Clan %d deleted.", clanId);
    }

    ClearConnectedClanId(clanId);
}

public void SQLTxn_OnDeleteClanFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to delete clan %d.", clanId);
    }

    LogError("[Clans] DeleteClan transaction failed (query %d): %s", failIndex, error);
}

void StartClanInviteToTarget(int client, int target)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    if (target <= 0 || target > MaxClients || !IsClientInGame(target) || IsFakeClient(target))
    {
        PrintToChat(client, "[Clans] That player is not available.");
        return;
    }

    if (target == client)
    {
        PrintToChat(client, "[Clans] You cannot invite yourself.");
        return;
    }

    char inviterSteam[STEAMID64_MAXLEN];
    char targetSteam[STEAMID64_MAXLEN];

    if (!GetClientSteam64(client, inviterSteam, sizeof(inviterSteam)) || !GetClientSteam64(target, targetSteam, sizeof(targetSteam)))
    {
        PrintToChat(client, "[Clans] Failed to read a SteamID64.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteString(targetSteam);

    GetClanByPlayer(inviterSteam, SQL_OnClanInviteInviterContext, pack);
}

void ShowClanInviteTargetMenu(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanInviteTarget);
    menu.SetTitle("Invite player to clan");
    menu.ExitBackButton = true;

    bool added = false;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (target == client || !IsClientInGame(target) || IsFakeClient(target))
        {
            continue;
        }

        char steamid64[STEAMID64_MAXLEN];
        if (!GetClientSteam64(target, steamid64, sizeof(steamid64)))
        {
            continue;
        }

        char targetName[MAX_NAME_LENGTH];
        GetClientName(target, targetName, sizeof(targetName));

        menu.AddItem(steamid64, targetName);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("none", "No valid players online", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanInviteTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char steamid64[STEAMID64_MAXLEN];
        menu.GetItem(param2, steamid64, sizeof(steamid64));

        int target = FindClientBySteam64(steamid64);
        if (target <= 0)
        {
            PrintToChat(param1, "[Clans] That player is no longer available.");
            ShowClanInviteTargetMenu(param1);
            return 0;
        }

        StartClanInviteToTarget(param1, target);
    }

    return 0;
}

public Action Command_ClanInvite(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_claninvite <target>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    StartClanInviteToTarget(client, target);
    return Plugin_Handled;
}

public void SQL_OnClanInviteInviterContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    if (inviter <= 0 || !IsClientInGame(inviter))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Invite clan lookup failed: %s", error);
        PrintToChat(inviter, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(inviter, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(ClanByPlayerCol_Name, clanName, sizeof(clanName));

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE clan_id = %d AND steamid64 = '%s' AND expires_at > %d) AS invite_exists",
        escapedTarget,
        clanId,
        escapedTarget,
        GetTime());

    DataPack next = new DataPack();
    next.WriteCell(inviterUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteString(clanName);
    next.WriteString(targetSteam);

    g_Database.Query(SQL_OnClanInviteTargetValidate, query, next);
}

public void SQL_OnClanInviteTargetValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    if (inviter <= 0 || !IsClientInGame(inviter))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Invite target validation failed: %s", error);
        PrintToChat(inviter, "[Clans] Failed to validate the invite target.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(inviter, "[Clans] Failed to validate the invite target.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(inviter, "[Clans] That player is already in a clan.");
        return;
    }

    if (results.FetchInt(1) > 0)
    {
        PrintToChat(inviter, "[Clans] That player already has a pending invite from your clan.");
        return;
    }

    char inviterSteam[STEAMID64_MAXLEN];
    if (!GetClientSteam64(inviter, inviterSteam, sizeof(inviterSteam)))
    {
        PrintToChat(inviter, "[Clans] Could not read your SteamID64.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(inviterUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteString(clanName);
    next.WriteString(targetSteam);
    next.WriteString(inviterSteam);

    CreateInvite(clanId, targetSteam, inviterSteam, SQL_OnClanInviteCreated, next);
}

public void SQL_OnClanInviteCreated(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int inviterUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char targetSteam[STEAMID64_MAXLEN];
    char inviterSteam[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(targetSteam, sizeof(targetSteam));
    pack.ReadString(inviterSteam, sizeof(inviterSteam));
    delete pack;

    int inviter = GetClientOfUserId(inviterUserId);
    int target = GetClientOfUserId(targetUserId);

    if (error[0])
    {
        if (inviter > 0 && IsClientInGame(inviter))
        {
            PrintToChat(inviter, "[Clans] Failed to create the invite.");
        }
        LogError("[Clans] CreateInvite failed: %s", error);
        return;
    }

    if (inviter > 0 && IsClientInGame(inviter))
    {
        char targetName[MAX_NAME_LENGTH];
        ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));
        PrintToChat(inviter, "[Clans] Invite sent to %s for '%s'.", targetName, clanName);
    }

    if (target > 0 && IsClientInGame(target))
    {
        char inviterName[MAX_NAME_LENGTH];
        ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));
        PrintToChat(target, "[Clans] %s has invited you to clan %s! Type !accept to accept the invite.", inviterName, clanName);
    }

    char inviterName[MAX_NAME_LENGTH * 2];
    char targetName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));
    ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));
    AddClanHistoryEntry(clanId, "%s invited %s", inviterName, targetName);

    AnnounceClanInviteToMembers(clanId, clanName, inviterSteam, targetSteam);
}

void StartClanKickSteam64(int client, const char[] targetSteam)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    if (!targetSteam[0])
    {
        PrintToChat(client, "[Clans] That player is not available.");
        return;
    }

    char actorSteam[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, actorSteam, sizeof(actorSteam)))
    {
        PrintToChat(client, "[Clans] Failed to read a SteamID64.");
        return;
    }

    if (StrEqual(actorSteam, targetSteam, false))
    {
        PrintToChat(client, "[Clans] Use sm_clanleave to leave your clan.");
        return;
    }

    int target = FindClientBySteam64(targetSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(target > 0 ? GetClientUserId(target) : 0);
    pack.WriteString(targetSteam);

    GetClanByPlayer(actorSteam, SQL_OnClanKickActorContext, pack);
}

void ShowClanKickTargetMenu(int client)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    GetClanByPlayer(steamid64, SQL_OnClanKickMenuContext, GetClientUserId(client));
}

public void SQL_OnClanKickMenuContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick menu context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load kick targets.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank actorRank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can kick members.");
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(view_as<int>(actorRank));

    GetClanMembers(clanId, SQL_OnClanKickMenuMembers, pack);
}

public void SQL_OnClanKickMenuMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    ClanRank actorRank = view_as<ClanRank>(pack.ReadCell());
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick menu member query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load kick targets.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanKickTarget);
    menu.SetTitle("Kick clan member");
    menu.ExitBackButton = true;

    bool added = false;
    while (results != null && results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        if (FindClientBySteam64(memberSteam) == client)
        {
            continue;
        }

        ClanRank targetRank = view_as<ClanRank>(results.FetchInt(1));
        if (targetRank >= ClanRank_Owner)
        {
            continue;
        }

        if (actorRank == ClanRank_Officer && targetRank >= ClanRank_Officer)
        {
            continue;
        }

        char targetName[MAX_NAME_LENGTH];
        char targetRankName[16];
        char display[128];

        ResolvePlayerDisplayName(memberSteam, targetName, sizeof(targetName));
        GetClanRankLabel(targetRank, targetRankName, sizeof(targetRankName));
        FormatEx(display, sizeof(display), "%s (%s)", targetName, targetRankName);

        menu.AddItem(memberSteam, display);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("none", "No kickable members", ITEMDRAW_DISABLED);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_ClanKickTarget(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanMenu(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char steamid64[STEAMID64_MAXLEN];
        menu.GetItem(param2, steamid64, sizeof(steamid64));

        StartClanKickSteam64(param1, steamid64);
    }

    return 0;
}

public Action Command_ClanKick(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Clans] Usage: sm_clankick <target>");
        return Plugin_Handled;
    }

    char actorSteam[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, actorSteam, sizeof(actorSteam)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char query[64];
    GetCmdArgString(query, sizeof(query));
    StripQuotes(query);
    TrimString(query);

    if (!query[0])
    {
        ReplyToCommand(client, "[Clans] Usage: sm_clankick <target>");
        return Plugin_Handled;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(actorSteam);
    pack.WriteString(query);

    GetClanByPlayer(actorSteam, SQL_OnClanKickCommandContext, pack);
    return Plugin_Handled;
}

public void SQL_OnClanKickCommandContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char actorSteam[STEAMID64_MAXLEN];
    char query[64];
    pack.ReadString(actorSteam, sizeof(actorSteam));
    pack.ReadString(query, sizeof(query));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick command context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank actorRank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(client, "[Clans] Only officers and owners can kick members.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(view_as<int>(actorRank));
    next.WriteString(actorSteam);
    next.WriteString(query);

    GetClanMembers(clanId, SQL_OnClanKickCommandMembers, next);
}

public void SQL_OnClanKickCommandMembers(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    ClanRank actorRank = view_as<ClanRank>(pack.ReadCell());
    char actorSteam[STEAMID64_MAXLEN];
    char query[64];
    pack.ReadString(actorSteam, sizeof(actorSteam));
    pack.ReadString(query, sizeof(query));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick command member query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load kick targets.");
        return;
    }

    char exactSteam[STEAMID64_MAXLEN];
    char partialSteam[STEAMID64_MAXLEN];
    exactSteam[0] = '\0';
    partialSteam[0] = '\0';

    int exactCount = 0;
    int partialCount = 0;

    while (results != null && results.FetchRow())
    {
        char memberSteam[STEAMID64_MAXLEN];
        results.FetchString(0, memberSteam, sizeof(memberSteam));

        if (StrEqual(memberSteam, actorSteam, false))
        {
            continue;
        }

        ClanRank targetRank = view_as<ClanRank>(results.FetchInt(1));
        if (targetRank >= ClanRank_Owner)
        {
            continue;
        }

        if (actorRank == ClanRank_Officer && targetRank >= ClanRank_Officer)
        {
            continue;
        }

        char targetName[MAX_NAME_LENGTH];
        ResolvePlayerDisplayName(memberSteam, targetName, sizeof(targetName));

        if (StrEqual(memberSteam, query, false) || StrEqual(targetName, query, false))
        {
            exactCount++;
            if (exactCount == 1)
            {
                strcopy(exactSteam, sizeof(exactSteam), memberSteam);
            }
            continue;
        }

        if (StrContains(memberSteam, query, false) != -1 || StrContains(targetName, query, false) != -1)
        {
            partialCount++;
            if (partialCount == 1)
            {
                strcopy(partialSteam, sizeof(partialSteam), memberSteam);
            }
        }
    }

    if (exactCount > 1 || (exactCount == 0 && partialCount > 1))
    {
        PrintToChat(client, "[Clans] Multiple clan members matched that query.");
        return;
    }

    if (exactCount == 1)
    {
        StartClanKickSteam64(client, exactSteam);
        return;
    }

    if (partialCount == 1)
    {
        StartClanKickSteam64(client, partialSteam);
        return;
    }

    PrintToChat(client, "[Clans] No clan member matched that query.");
}

public void SQL_OnClanKickActorContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor <= 0 || !IsClientInGame(actor))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick actor context failed: %s", error);
        PrintToChat(actor, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(actor, "[Clans] You are not in a clan.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);
    ClanRank actorRank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));

    if (actorRank < ClanRank_Officer)
    {
        PrintToChat(actor, "[Clans] Only officers and owners can kick members.");
        return;
    }

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT rank FROM clan_members WHERE clan_id = %d AND steamid64 = '%s' LIMIT 1",
        clanId,
        escapedTarget);

    DataPack next = new DataPack();
    next.WriteCell(actorUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteCell(view_as<int>(actorRank));
    next.WriteString(targetSteam);

    g_Database.Query(SQL_OnClanKickTargetValidate, query, next);
}

public void SQL_OnClanKickTargetValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    ClanRank actorRank = view_as<ClanRank>(pack.ReadCell());
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor <= 0 || !IsClientInGame(actor))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Kick target validation failed: %s", error);
        PrintToChat(actor, "[Clans] Failed to validate the kick target.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(actor, "[Clans] That player is not in your clan.");
        return;
    }

    ClanRank targetRank = view_as<ClanRank>(results.FetchInt(0));

    if (targetRank >= ClanRank_Owner)
    {
        PrintToChat(actor, "[Clans] You cannot kick the clan owner.");
        return;
    }

    if (actorRank == ClanRank_Officer && targetRank >= ClanRank_Officer)
    {
        PrintToChat(actor, "[Clans] Officers can only kick regular members.");
        return;
    }

    char escapedTarget[SQL_STEAMID64_MAXLEN];
    EscapeSql(targetSteam, escapedTarget, sizeof(escapedTarget));

    Transaction txn = new Transaction();
    char query[256];

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_sub_tags WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedTarget);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_members WHERE clan_id = %d AND steamid64 = '%s'",
        clanId,
        escapedTarget);
    txn.AddQuery(query);

    DataPack next = new DataPack();
    next.WriteCell(actorUserId);
    next.WriteCell(targetUserId);
    next.WriteCell(clanId);
    next.WriteString(targetSteam);

    g_Database.Execute(txn, SQL_OnClanKickSuccess, SQL_OnClanKickFailure, next);
}

public void SQL_OnClanKickSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    if (targetSteam[0] != '\0')
    {
        SetClientClanIdBySteam64(targetSteam, 0);
    }
    RefreshConnectedClanTagsForClan(clanId);

    int actor = GetClientOfUserId(actorUserId);
    int target = GetClientOfUserId(targetUserId);
    if (target <= 0 || !IsClientInGame(target))
    {
        target = FindClientBySteam64(targetSteam);
    }

    char targetName[MAX_NAME_LENGTH];
    ResolvePlayerDisplayName(targetSteam, targetName, sizeof(targetName));

    if (actor > 0 && IsClientInGame(actor))
    {
        PrintToChat(actor, "[Clans] You kicked %s from the clan.", targetName);
    }

    if (target > 0 && IsClientInGame(target))
    {
        PrintToChat(target, "[Clans] You were kicked from your clan.");
    }
}

public void SQL_OnClanKickFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    char targetSteam[STEAMID64_MAXLEN];
    pack.ReadString(targetSteam, sizeof(targetSteam));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    if (actor > 0 && IsClientInGame(actor))
    {
        PrintToChat(actor, "[Clans] Failed to kick that player.");
    }

    LogError("[Clans] Kick transaction failed for %s (query %d): %s", targetSteam, failIndex, error);
}

public Action Command_ClanTag(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        StartClanTagPrompt(client);
        return Plugin_Handled;
    }

    char rawTag[CLAN_TAG_MAXLEN + 1];
    GetCmdArgString(rawTag, sizeof(rawTag));
    StartSetMainClanTagFromInput(client, rawTag);
    return Plugin_Handled;
}

public void SQL_OnClanTagContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char rawTag[CLAN_TAG_MAXLEN + 1];
    pack.ReadString(rawTag, sizeof(rawTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Tag context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can set or change the main clan tag.");
        return;
    }

    int allowed = GetAllowedMainClanTagLength(client);
    if (strlen(rawTag) > allowed)
    {
        PrintToChat(client, "[Clans] Tag is too long. Max length: %d.", allowed);
        return;
    }

    if (!IsSafeClanTagText(rawTag))
    {
        PrintToChat(client, "[Clans] Tags may not contain control characters, pipes, or square brackets.");
        return;
    }

    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    FormatStoredClanTag(rawTag, formattedTag, sizeof(formattedTag));

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char escapedTag[SQL_CLAN_TAG_MAXLEN];
    EscapeSql(formattedTag, escapedTag, sizeof(escapedTag));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT COUNT(1) FROM clans WHERE tag = '%s' AND id != %d",
        escapedTag,
        clanId);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(formattedTag);

    g_Database.Query(SQL_OnClanTagUniqueCheck, query, next);
}

public void SQL_OnClanTagUniqueCheck(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char formattedTag[CLAN_TAG_STORE_MAXLEN];
    pack.ReadString(formattedTag, sizeof(formattedTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Tag uniqueness check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate the clan tag.");
        return;
    }

    if (results != null && results.FetchRow() && results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] That clan tag is already taken.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(formattedTag);

    SetClanTag(clanId, formattedTag, SQL_OnClanTagSet, next);
}

public void SQL_OnClanTagSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char formattedTag[CLAN_TAG_MAXLEN + 1];
    pack.ReadString(formattedTag, sizeof(formattedTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set tag failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set the clan tag.");
        return;
    }

    RefreshConnectedClanTagsForClan(clanId);
    PrintToChat(client, "[Clans] Clan tag updated to %s", formattedTag);
}

public void SQL_OnClanSubTagContext(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(rawTag, sizeof(rawTag));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Sub-tag context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    char currentClanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(ClanByPlayerCol_Tag, currentClanTag, sizeof(currentClanTag));
    TrimString(currentClanTag);

    if (!currentClanTag[0])
    {
        PrintToChat(client, "[Clans] Your clan must have a main clan tag before members can use sub-tags.");
        return;
    }

    int allowed = GetAllowedSubClanTagLength(client);
    if (strlen(rawTag) > allowed)
    {
        PrintToChat(client, "[Clans] Sub-tag is too long. Max length: %d.", allowed);
        return;
    }

    if (!IsSafeClanTagText(rawTag))
    {
        PrintToChat(client, "[Clans] Tags may not contain control characters, pipes, or square brackets.");
        return;
    }

    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    char escapedTag[SQL_CLAN_SUB_TAG_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));
    EscapeSql(rawTag, escapedTag, sizeof(escapedTag));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT COUNT(1) FROM clan_sub_tags WHERE tag = '%s' AND steamid64 != '%s'",
        escapedTag,
        escapedSteam);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(rawTag);
    next.WriteString(steamid64);

    g_Database.Query(SQL_OnClanSubTagUniqueCheck, query, next);
}

public void SQL_OnClanSubTagUniqueCheck(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(rawTag, sizeof(rawTag));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Sub-tag uniqueness check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate your clan sub-tag.");
        return;
    }

    if (results != null && results.FetchRow() && results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] That clan sub-tag is already taken.");
        return;
    }

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(rawTag);

    SetClanSubTag(clanId, steamid64, rawTag, SQL_OnClanSubTagSet, next);
}

public void SQL_OnClanSubTagSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char rawTag[CLAN_SUB_TAG_MAXLEN + 1];
    pack.ReadString(rawTag, sizeof(rawTag));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set sub-tag failed: %s", error);
        PrintToChat(client, "[Clans] Failed to set your clan sub-tag.");
        return;
    }

    RefreshConnectedClanTagsForClan(clanId);
    PrintToChat(client, "[Clans] Clan sub-tag updated to '%s'.", rawTag);
}

public Action Command_ClanOpen(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    int requestedState = -1;
    if (args >= 1)
    {
        char arg[8];
        GetCmdArg(1, arg, sizeof(arg));
        requestedState = (StringToInt(arg) != 0) ? 1 : 0;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetClanByPlayer(steamid64, SQL_OnClanOpenContext, requestedState == -1 ? (GetClientUserId(client) * 10) + 9 : (GetClientUserId(client) * 10) + requestedState);
    return Plugin_Handled;
}

public void SQL_OnClanOpenContext(Database db, DBResultSet results, const char[] error, any data)
{
    int userId = data / 10;
    int encoded = data % 10;
    int requestedState = (encoded == 9) ? -1 : encoded;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clan open context failed: %s", error);
        PrintToChat(client, "[Clans] Failed to look up your clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    ClanRank rank = view_as<ClanRank>(results.FetchInt(ClanByPlayerCol_Rank));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only the clan owner can change join settings.");
        return;
    }

    bool newOpen = (requestedState == -1) ? (results.FetchInt(ClanByPlayerCol_IsOpen) == 0) : (requestedState != 0);
    int clanId = results.FetchInt(ClanByPlayerCol_Id);

    DataPack pack = new DataPack();
    pack.WriteCell(userId);
    pack.WriteCell(newOpen ? 1 : 0);

    SetClanOpen(clanId, newOpen, SQL_OnClanOpenSet, pack);
}

public void SQL_OnClanOpenSet(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    bool isOpen = (pack.ReadCell() != 0);
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Set clan open failed: %s", error);
        PrintToChat(client, "[Clans] Failed to update open-clan settings.");
        return;
    }

    PrintToChat(client, "[Clans] Clan join setting updated: %s.", isOpen ? "open" : "closed");
}

public Action Command_ClanJoin(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    IsPlayerInClan(steamid64, SQL_OnClanJoinMembershipCheck, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanJoinMembershipCheck(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join membership check failed: %s", error);
        PrintToChat(client, "[Clans] Failed to check your clan state.");
        return;
    }

    if (results != null && results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query), "SELECT id, name, tag FROM clans WHERE is_open = 1 ORDER BY name ASC");
    g_Database.Query(SQL_OnClanJoinOpenList, query, GetClientUserId(client));
}

public void SQL_OnClanJoinOpenList(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join open list failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load open clans.");
        return;
    }

    Menu menu = new Menu(MenuHandler_JoinOpenClan);
    menu.SetTitle("Join Open Clan");

    if (results == null || results.RowCount <= 0)
    {
        menu.AddItem("none", "No open clans available", ITEMDRAW_DISABLED);
        menu.Display(client, CLAN_MENU_TIME);
        return;
    }

    char info[16];
    char name[CLAN_NAME_MAXLEN + 1];
    while (results.FetchRow())
    {
        int clanId = results.FetchInt(0);
        results.FetchString(1, name, sizeof(name));
        IntToString(clanId, info, sizeof(info));
        menu.AddItem(info, name);
    }

    menu.Display(client, CLAN_MENU_TIME);
}

public int MenuHandler_JoinOpenClan(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        int clanId = StringToInt(info);
        if (clanId > 0)
        {
            StartJoinOpenClan(param1, clanId);
        }
    }

    return 0;
}

void StartJoinOpenClan(int client, int clanId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[768];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clans WHERE id = %d AND is_open = 1) AS clan_open, "
        ... "(SELECT name FROM clans WHERE id = %d LIMIT 1) AS clan_name, "
        ... "(SELECT COALESCE(tag, '') FROM clans WHERE id = %d LIMIT 1) AS clan_tag",
        escapedSteam,
        clanId,
        clanId,
        clanId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(clanId);
    pack.WriteString(steamid64);

    g_Database.Query(SQL_OnJoinOpenClanValidate, query, pack);
}

public void SQL_OnJoinOpenClanValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Join validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that clan.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (results.FetchInt(1) <= 0)
    {
        PrintToChat(client, "[Clans] That clan is no longer open.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(2, clanName, sizeof(clanName));
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(3, clanTag, sizeof(clanTag));

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(clanId);
    next.WriteString(clanName);
    next.WriteString(clanTag);
    next.WriteString(steamid64);

    AddClanMember(clanId, steamid64, SQL_OnJoinOpenClanSuccess, next, ClanRank_Member);
}

public void SQL_OnJoinOpenClanSuccess(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int clanId = pack.ReadCell();
    char clanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(clanName, sizeof(clanName));
    pack.ReadString(clanTag, sizeof(clanTag));
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] You are already in a clan.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to join '%s'.", clanName);
        }
        LogError("[Clans] Join open clan failed: %s", error);
        return;
    }

    if (steamid64[0] != '\0' && clanId > 0)
    {
        SetClientClanIdBySteam64(steamid64, clanId);
    }
    TrySetClanJoinSelectedTag(client, clanTag);

    char memberName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(steamid64, memberName, sizeof(memberName));
    if (clanId > 0)
    {
        AddClanHistoryEntry(clanId, "%s joined the clan", memberName);
    }

    PrintToChat(client, "[Clans] You joined '%s'.", clanName);
}

public Action Command_ClanParent(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    g_Database.Query(SQL_OnClanParentContext, query, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnClanParentContext(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent context query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load parent-clan data.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int ownerClanId = results.FetchInt(0);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(1));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only clan owners can manage parent relations.");
        return;
    }

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT id, name, tag FROM clans WHERE is_open = 1 AND id <> %d ORDER BY name ASC",
        ownerClanId);

    g_Database.Query(SQL_OnClanParentMenuList, query, GetClientUserId(client));
}

public void SQL_OnClanParentMenuList(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent menu query failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load open clans.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanParent);
    menu.SetTitle("Choose parent clan");
    menu.AddItem("clear", "Clear parent relation");

    bool added = false;
    while (results != null && results.FetchRow())
    {
        int clanId = results.FetchInt(0);

        char info[16];
        IntToString(clanId, info, sizeof(info));

        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        char display[160];

        results.FetchString(1, clanName, sizeof(clanName));
        results.FetchString(2, clanTag, sizeof(clanTag));

        if (clanTag[0])
        {
            FormatEx(display, sizeof(display), "%s %s", clanName, clanTag);
        }
        else
        {
            strcopy(display, sizeof(display), clanName);
        }

        menu.AddItem(info, display);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("noop", "No open clans available", ITEMDRAW_DISABLED);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClanParent(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "clear", false))
        {
            StartClanParentSelection(client, 0);
        }
        else
        {
            StartClanParentSelection(client, StringToInt(info));
        }
    }

    return 0;
}

void StartClanParentSelection(int client, int selectedParentClanId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[256];
    FormatEx(query, sizeof(query),
        "SELECT clan_id, rank FROM clan_members WHERE steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(selectedParentClanId);

    g_Database.Query(SQL_OnClanParentRevalidateOwner, query, pack);
}

public void SQL_OnClanParentRevalidateOwner(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int selectedParentClanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent owner revalidation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate your clan state.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You are not in a clan.");
        return;
    }

    int ownerClanId = results.FetchInt(0);
    ClanRank rank = view_as<ClanRank>(results.FetchInt(1));
    if (rank < ClanRank_Owner)
    {
        PrintToChat(client, "[Clans] Only clan owners can manage parent relations.");
        return;
    }

    if (selectedParentClanId <= 0)
    {
        ClearParentRelation(ownerClanId, userId);
        return;
    }

    if (selectedParentClanId == ownerClanId)
    {
        PrintToChat(client, "[Clans] Your clan cannot be its own parent.");
        return;
    }

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clans WHERE id = %d AND is_open = 1) AS parent_ok, "
        ... "(SELECT name FROM clans WHERE id = %d LIMIT 1) AS parent_name",
        selectedParentClanId,
        selectedParentClanId);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteCell(ownerClanId);
    next.WriteCell(selectedParentClanId);

    g_Database.Query(SQL_OnClanParentValidateTarget, query, next);
}

public void SQL_OnClanParentValidateTarget(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int ownerClanId = pack.ReadCell();
    int selectedParentClanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Parent target validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that parent clan.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that parent clan.");
        return;
    }

    if (results.FetchInt(0) <= 0)
    {
        PrintToChat(client, "[Clans] That clan is not open or no longer exists.");
        return;
    }

    SetParentRelation(ownerClanId, selectedParentClanId, userId);
}

public void SQLTxn_OnSetParentSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    PrintToChat(client, "[Clans] Parent clan relation saved.");
}

public void SQLTxn_OnSetParentFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    pack.ReadCell();
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[Clans] Failed to save the parent clan relation.");
    }

    LogError("[Clans] Parent relation transaction failed at query %d: %s", failIndex, error);
}

public void SQL_OnClearParentRelation(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Clear parent relation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to clear the parent relation.");
        return;
    }

    PrintToChat(client, "[Clans] Parent clan relation cleared.");
}

void AddInviteMenuItem(Menu menu, int inviteId, const char[] clanName, const char[] clanTag, int expiresAt)
{
    char info[16];
    IntToString(inviteId, info, sizeof(info));

    int secondsLeft = expiresAt - GetTime();
    if (secondsLeft < 0)
    {
        secondsLeft = 0;
    }

    int daysLeft = (secondsLeft + 86399) / 86400;
    if (daysLeft < 1)
    {
        daysLeft = 1;
    }

    char display[192];
    if (clanTag[0])
    {
        FormatEx(display, sizeof(display), "%s %s (%d day%s left)", clanName, clanTag, daysLeft, (daysLeft == 1) ? "" : "s");
    }
    else
    {
        FormatEx(display, sizeof(display), "%s (%d day%s left)", clanName, daysLeft, (daysLeft == 1) ? "" : "s");
    }

    menu.AddItem(info, display);
}

void AddInviteBrowseMenuItem(Menu menu, int inviteId, const char[] clanName, const char[] clanTag, const char[] inviterName, int expiresAt)
{
    int secondsLeft = expiresAt - GetTime();
    if (secondsLeft < 0)
    {
        secondsLeft = 0;
    }

    int daysLeft = (secondsLeft + 86399) / 86400;
    if (daysLeft < 1)
    {
        daysLeft = 1;
    }

    char display[256];
    if (clanTag[0])
    {
        FormatEx(display, sizeof(display), "From %s: %s %s (%d day%s left)", inviterName, clanName, clanTag, daysLeft, (daysLeft == 1) ? "" : "s");
    }
    else
    {
        FormatEx(display, sizeof(display), "From %s: %s (%d day%s left)", inviterName, clanName, daysLeft, (daysLeft == 1) ? "" : "s");
    }

    char info[16];
    IntToString(inviteId, info, sizeof(info));
    menu.AddItem(info, display);
}

void ShowInviteActionMenu(int client, int inviteId, const char[] summary)
{
    Menu menu = new Menu(MenuHandler_ClanInviteAction);

    char title[256];
    FormatEx(title, sizeof(title), "Invite Actions\n%s", summary);
    menu.SetTitle(title);
    menu.ExitBackButton = true;

    char info[16];
    IntToString(inviteId, info, sizeof(info));
    menu.AddItem(info, "Accept");
    menu.AddItem(info, "Deny");
    menu.Display(client, MENU_TIME_FOREVER);
}

public Action Command_ClanInvites(int client, int args)
{
    if (client <= 0)
    {
        ReplyToCommand(client, "[Clans] This command can only be used by players.");
        return Plugin_Handled;
    }

    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetPendingInvites(steamid64, SQL_OnPendingInvitesForBrowse, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnPendingInvitesForBrowse(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Pending invite query (browse) failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan invites.");
        return;
    }

    Menu menu = new Menu(MenuHandler_ClanInvites);
    menu.SetTitle("Clan Invites");
    menu.ExitButton = true;

    bool added = false;
    while (results != null && results.FetchRow())
    {
        int inviteId = results.FetchInt(PendingInviteCol_Id);
        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        char inviterSteam[STEAMID64_MAXLEN];
        char inviterName[MAX_NAME_LENGTH * 2];
        int expiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

        results.FetchString(PendingInviteCol_ClanName, clanName, sizeof(clanName));
        results.FetchString(PendingInviteCol_ClanTag, clanTag, sizeof(clanTag));
        results.FetchString(PendingInviteCol_InvitedBy, inviterSteam, sizeof(inviterSteam));
        ResolvePlayerDisplayName(inviterSteam, inviterName, sizeof(inviterName));

        AddInviteBrowseMenuItem(menu, inviteId, clanName, clanTag, inviterName, expiresAt);
        added = true;
    }

    if (!added)
    {
        menu.AddItem("none", "No pending clan invites", ITEMDRAW_DISABLED);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ClanInvites(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        char display[256];
        menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));

        int inviteId = StringToInt(info);
        if (inviteId > 0)
        {
            ShowInviteActionMenu(param1, inviteId, display);
        }
    }

    return 0;
}

public int MenuHandler_ClanInviteAction(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            Command_ClanInvites(param1, 0);
        }
    }
    else if (action == MenuAction_Select)
    {
        char info[16];
        char display[32];
        menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display));

        int inviteId = StringToInt(info);
        if (inviteId <= 0)
        {
            return 0;
        }

        if (StrEqual(display, "Accept", false))
        {
            StartAcceptInvite(param1, inviteId);
        }
        else
        {
            StartDenyInvite(param1, inviteId);
        }
    }

    return 0;
}

public Action Command_ClanAcceptInvite(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetPendingInvites(steamid64, SQL_OnPendingInvitesForAccept, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnPendingInvitesForAccept(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Pending invite query (accept) failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan invites.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        return;
    }

    int firstInviteId = results.FetchInt(PendingInviteCol_Id);
    char firstClanName[CLAN_NAME_MAXLEN + 1];
    char firstClanTag[CLAN_TAG_STORE_MAXLEN];
    int firstExpiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

    results.FetchString(PendingInviteCol_ClanName, firstClanName, sizeof(firstClanName));
    results.FetchString(PendingInviteCol_ClanTag, firstClanTag, sizeof(firstClanTag));

    if (!results.FetchRow())
    {
        StartAcceptInvite(client, firstInviteId);
        return;
    }

    Menu menu = new Menu(MenuHandler_AcceptInvite);
    menu.SetTitle("Select a clan invite to accept");

    AddInviteMenuItem(menu, firstInviteId, firstClanName, firstClanTag, firstExpiresAt);

    do
    {
        int inviteId = results.FetchInt(PendingInviteCol_Id);
        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        int expiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

        results.FetchString(PendingInviteCol_ClanName, clanName, sizeof(clanName));
        results.FetchString(PendingInviteCol_ClanTag, clanTag, sizeof(clanTag));

        AddInviteMenuItem(menu, inviteId, clanName, clanTag, expiresAt);
    }
    while (results.FetchRow());

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AcceptInvite(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        StartAcceptInvite(client, StringToInt(info));
    }

    return 0;
}

void StartAcceptInvite(int client, int inviteId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return;
    }

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    int now = GetTime();

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT "
        ... "(SELECT COUNT(1) FROM clan_members WHERE steamid64 = '%s') AS in_clan, "
        ... "(SELECT COUNT(1) FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d) AS invite_ok, "
        ... "(SELECT clan_id FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d LIMIT 1) AS clan_id, "
        ... "(SELECT name FROM clans WHERE id = (SELECT clan_id FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d LIMIT 1) LIMIT 1) AS clan_name, "
        ... "(SELECT COALESCE(tag, '') FROM clans WHERE id = (SELECT clan_id FROM clan_invites WHERE id = %d AND steamid64 = '%s' AND expires_at > %d LIMIT 1) LIMIT 1) AS clan_tag",
        escapedSteam,
        inviteId,
        escapedSteam,
        now,
        inviteId,
        escapedSteam,
        now,
        inviteId,
        escapedSteam,
        now,
        inviteId,
        escapedSteam,
        now);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(inviteId);
    pack.WriteString(steamid64);

    g_Database.Query(SQL_OnAcceptInviteValidate, query, pack);
}

public void SQL_OnAcceptInviteValidate(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int inviteId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(steamid64, sizeof(steamid64));
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Accept invite validation failed: %s", error);
        PrintToChat(client, "[Clans] Failed to validate that invite.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] Failed to validate that invite.");
        return;
    }

    if (results.FetchInt(0) > 0)
    {
        PrintToChat(client, "[Clans] You are already in a clan.");
        return;
    }

    if (results.FetchInt(1) <= 0)
    {
        PrintToChat(client, "[Clans] That invite is no longer valid.");
        return;
    }

    int clanId = results.FetchInt(2);
    if (clanId <= 0)
    {
        PrintToChat(client, "[Clans] That invite is no longer valid.");
        return;
    }

    char clanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(3, clanName, sizeof(clanName));
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    results.FetchString(4, clanTag, sizeof(clanTag));

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    int now = GetTime();

    Transaction txn = new Transaction();
    char query[1024];

    FormatEx(query, sizeof(query),
        "INSERT INTO clan_members (clan_id, steamid64, rank, joined_at) "
        ... "SELECT i.clan_id, '%s', %d, %d "
        ... "FROM clan_invites i "
        ... "INNER JOIN clans c ON c.id = i.clan_id "
        ... "WHERE i.id = %d AND i.steamid64 = '%s' AND i.expires_at > %d LIMIT 1",
        escapedSteam,
        view_as<int>(ClanRank_Member),
        now,
        inviteId,
        escapedSteam,
        now);
    txn.AddQuery(query);

    FormatEx(query, sizeof(query),
        "DELETE FROM clan_invites WHERE steamid64 = '%s' "
        ... "AND EXISTS (SELECT 1 FROM clan_members WHERE steamid64 = '%s')",
        escapedSteam,
        escapedSteam);
    txn.AddQuery(query);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(steamid64);
    next.WriteString(clanName);
    next.WriteString(clanTag);
    next.WriteCell(clanId);

    g_Database.Execute(txn, SQLTxn_OnAcceptInviteSuccess, SQLTxn_OnAcceptInviteFailure, next);
}

public void SQLTxn_OnAcceptInviteSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char steamid64[STEAMID64_MAXLEN];
    char fallbackClanName[CLAN_NAME_MAXLEN + 1];
    char clanTag[CLAN_TAG_STORE_MAXLEN];
    pack.ReadString(steamid64, sizeof(steamid64));
    pack.ReadString(fallbackClanName, sizeof(fallbackClanName));
    pack.ReadString(clanTag, sizeof(clanTag));
    int clanId = pack.ReadCell();
    delete pack;

    if (steamid64[0] != '\0' && clanId > 0)
    {
        SetClientClanIdBySteam64(steamid64, clanId);
    }

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    TrySetClanJoinSelectedTag(client, clanTag);

    char escapedSteam[SQL_STEAMID64_MAXLEN];
    EscapeSql(steamid64, escapedSteam, sizeof(escapedSteam));

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT c.name FROM clan_members m INNER JOIN clans c ON c.id = m.clan_id WHERE m.steamid64 = '%s' LIMIT 1",
        escapedSteam);

    DataPack next = new DataPack();
    next.WriteCell(userId);
    next.WriteString(fallbackClanName);
    next.WriteString(steamid64);
    next.WriteCell(clanId);

    g_Database.Query(SQL_OnAcceptInviteVerify, query, next);
}

public void SQLTxn_OnAcceptInviteFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char ignoredSteam[STEAMID64_MAXLEN];
    char ignoredClan[CLAN_NAME_MAXLEN + 1];
    char ignoredTag[CLAN_TAG_STORE_MAXLEN];
    pack.ReadString(ignoredSteam, sizeof(ignoredSteam));
    pack.ReadString(ignoredClan, sizeof(ignoredClan));
    pack.ReadString(ignoredTag, sizeof(ignoredTag));
    pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client))
    {
        if (StrContains(error, "Duplicate", false) != -1 || StrContains(error, "UNIQUE", false) != -1)
        {
            PrintToChat(client, "[Clans] You are already in a clan.");
        }
        else
        {
            PrintToChat(client, "[Clans] Failed to accept that invite.");
        }
    }

    LogError("[Clans] Accept invite transaction failed at query %d: %s", failIndex, error);
}

public void SQL_OnAcceptInviteVerify(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    char fallbackClanName[CLAN_NAME_MAXLEN + 1];
    char steamid64[STEAMID64_MAXLEN];
    pack.ReadString(fallbackClanName, sizeof(fallbackClanName));
    pack.ReadString(steamid64, sizeof(steamid64));
    int clanId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Accept invite verify query failed: %s", error);
        PrintToChat(client, "[Clans] Invite processed, but verification failed.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] That invite was no longer valid.");
        return;
    }

    char actualClanName[CLAN_NAME_MAXLEN + 1];
    results.FetchString(0, actualClanName, sizeof(actualClanName));
    if (!actualClanName[0])
    {
        strcopy(actualClanName, sizeof(actualClanName), fallbackClanName);
    }

    char memberName[MAX_NAME_LENGTH * 2];
    ResolvePlayerDisplayName(steamid64, memberName, sizeof(memberName));
    if (clanId > 0)
    {
        AddClanHistoryEntry(clanId, "%s joined the clan", memberName);
    }

    PrintToChat(client, "[Clans] You joined '%s'.", actualClanName);
    AnnounceClanInviteAcceptedToMembers(clanId, actualClanName, steamid64);
}

public Action Command_ClanDenyInvite(int client, int args)
{
    if (!EnsureDatabaseReady(client))
    {
        return Plugin_Handled;
    }

    char steamid64[STEAMID64_MAXLEN];
    if (!GetClientSteam64(client, steamid64, sizeof(steamid64)))
    {
        PrintToChat(client, "[Clans] Could not read your SteamID64.");
        return Plugin_Handled;
    }

    GetPendingInvites(steamid64, SQL_OnPendingInvitesForDeny, GetClientUserId(client));
    return Plugin_Handled;
}

public void SQL_OnPendingInvitesForDeny(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Pending invite query (deny) failed: %s", error);
        PrintToChat(client, "[Clans] Failed to load your clan invites.");
        return;
    }

    if (results == null || !results.FetchRow())
    {
        PrintToChat(client, "[Clans] You have no pending clan invites.");
        return;
    }

    int firstInviteId = results.FetchInt(PendingInviteCol_Id);
    char firstClanName[CLAN_NAME_MAXLEN + 1];
    char firstClanTag[CLAN_TAG_STORE_MAXLEN];
    int firstExpiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

    results.FetchString(PendingInviteCol_ClanName, firstClanName, sizeof(firstClanName));
    results.FetchString(PendingInviteCol_ClanTag, firstClanTag, sizeof(firstClanTag));

    if (!results.FetchRow())
    {
        StartDenyInvite(client, firstInviteId);
        return;
    }

    Menu menu = new Menu(MenuHandler_DenyInvite);
    menu.SetTitle("Select a clan invite to deny");

    AddInviteMenuItem(menu, firstInviteId, firstClanName, firstClanTag, firstExpiresAt);

    do
    {
        int inviteId = results.FetchInt(PendingInviteCol_Id);
        char clanName[CLAN_NAME_MAXLEN + 1];
        char clanTag[CLAN_TAG_STORE_MAXLEN];
        int expiresAt = results.FetchInt(PendingInviteCol_ExpiresAt);

        results.FetchString(PendingInviteCol_ClanName, clanName, sizeof(clanName));
        results.FetchString(PendingInviteCol_ClanTag, clanTag, sizeof(clanTag));

        AddInviteMenuItem(menu, inviteId, clanName, clanTag, expiresAt);
    }
    while (results.FetchRow());

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_DenyInvite(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));
        StartDenyInvite(client, StringToInt(info));
    }

    return 0;
}

void StartDenyInvite(int client, int inviteId)
{
    if (!EnsureDatabaseReady(client))
    {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(inviteId);

    DeleteInvite(inviteId, SQL_OnDenyInviteDeleted, pack);
}

public void SQL_OnDenyInviteDeleted(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int userId = pack.ReadCell();
    int inviteId = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (error[0])
    {
        LogError("[Clans] Deny invite delete failed: %s", error);
        PrintToChat(client, "[Clans] Failed to deny that invite.");
        return;
    }

    PrintToChat(client, "[Clans] Invite #%d denied.", inviteId);
}
