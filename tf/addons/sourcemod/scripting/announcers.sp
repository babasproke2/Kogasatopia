#pragma semicolon 1
#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <textparse>
#include <tf2_stocks>
#undef REQUIRE_PLUGIN
#include "include/dgm_api.inc"
#define REQUIRE_PLUGIN
#include "include/plugin_statistics.inc"
#pragma newdecls required

#define WHALE_KILLSTREAK_BONUS_INTERVAL 5
#define WHALE_MULTIKILL_MIN_LEVEL 2
#define WHALE_MULTIKILL_MAX_LEVEL 5
#define ANNOUNCER_CONFIG_FILE "configs/announcers.cfg"
#define ANNOUNCER_MAX_COMMAND_NAME 64
#define ANNOUNCER_MAX_GROUP_NAME 32
#define ANNOUNCER_GROUP_PREF_VALUE 512
#define ANNOUNCER_GROUP_COOKIE "announcers_disabled_groups"
#define MULTIKILL_LOG_FILE "logs/announcers_multikill.log"
#define ANNOUNCER_SOUND_LIBRARY "saysounds"
#define ANNOUNCER_SOUND_NATIVE "SaySounds_PlayCommand"
#define ANNOUNCER_SOUND_PLAY_AS_NATIVE "SaySounds_PlayCommandAs"
#define ANNOUNCER_SOUND_CAN_USE_NATIVE "SaySounds_CanClientUseCommand"
#define ANNOUNCER_SOUND_IS_PAID_NATIVE "SaySounds_IsCommandPaid"
#define ANNOUNCER_SOUND_GET_GROUP_NATIVE "SaySounds_GetCommandGroup"
#define DGM_CAPACITY_NATIVE "DGM_ServerCapacitycheck"
#define POINTS_STORE_BONUS_NATIVE "PointsStore_ApplyBonusPoints"

native bool SaySounds_PlayCommand(int client, const char[] commandName, bool ignoreOptIn = false, bool bypassAdminOnly = true);
native bool SaySounds_PlayCommandAs(int sourceClient, int targetClient, const char[] commandName, bool ignoreOptIn = false, bool bypassAdminOnly = true);
native bool SaySounds_CanClientUseCommand(int client, const char[] commandName, bool bypassAdminOnly = true);
native bool SaySounds_IsCommandPaid(const char[] commandName);
native bool SaySounds_GetCommandGroup(const char[] commandName, char[] groupName, int groupLen);
native bool Filters_GetChatName(int client, char[] buffer, int maxlen);
native bool PointsStore_ApplyBonusPoints(int client, int points, bool playSound, bool chatAlert, float randomChance, const char[] type, int target = 0, float delay = 3.0);

static const char g_KillstreakLabels[][] =
{
    "on a killing spree", "on a rampage", "dominating",
    "unstoppable", "godlike", "GODLIKE"
};

static const char g_KillstreakCommands[][] =
{
    "killingspree", "rampage", "dominating",
    "unstoppable", "godlike", "holyshit"
};

static const char g_MultikillLabels[][] =
{
    "double-kill", "triple-kill", "megakill", "MONSTER KILL"
};

enum AnnouncerConfigMode
{
    AnnouncerConfig_None = 0,
    AnnouncerConfig_Killstreaks,
    AnnouncerConfig_Multikills,
    AnnouncerConfig_Shutdown,
    AnnouncerConfig_MedicDrops
}

ConVar g_cvMultikillsChat = null;
ConVar g_cvStreaksChat = null;
ConVar g_cvStreakEndsChat = null;
ConVar g_cvStreakEndMin = null;
ConVar g_cvShutdownMin = null;
ConVar g_cvKillstreakBroadcastMin = null;
ConVar g_cvPlayercountThreshold = null;
ConVar g_cvKillstreaksEnabled = null;
ConVar g_cvMultikillsEnabled = null;
ConVar g_cvKillstreaksSound = null;
ConVar g_cvMultikillsSound = null;
ConVar g_cvMultikillBroadcastMin = null;
ConVar g_cvMultikillRollupWindow = null;
ConVar g_cvStatisticsLogging = null;
ConVar g_cvMultikillFileLogging = null;
StringMap g_KillstreakSoundMap = null;
StringMap g_MultikillSoundMap = null;
StringMap g_ShutdownSoundMap = null;
StringMap g_MedicDropSoundMap = null;
AnnouncerConfigMode g_ConfigMode = AnnouncerConfig_None;
int g_ConfigDepth = 0;
int g_ConfigLevel = 0;
Handle g_hMultikillRollupTimer[MAXPLAYERS + 1];
int g_iPendingMultikillKills[MAXPLAYERS + 1];
int g_iPendingMultikillUserId[MAXPLAYERS + 1];
int g_iPendingMultikillSerial[MAXPLAYERS + 1];
Handle g_hAnnouncerGroupsCookie = INVALID_HANDLE;
StringMap g_DisabledAnnouncerGroups[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "Announcers",
    author = "Kogasatopia",
    description = "Announcement handlers for shared gameplay events.",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart()
{
    g_KillstreakSoundMap = new StringMap();
    g_MultikillSoundMap = new StringMap();
    g_ShutdownSoundMap = new StringMap();
    g_MedicDropSoundMap = new StringMap();
    g_hAnnouncerGroupsCookie = RegClientCookie(
        ANNOUNCER_GROUP_COOKIE,
        "Disabled paid announcer sound groups.",
        CookieAccess_Private
    );

    for (int i = 1; i <= MaxClients; i++)
    {
        g_DisabledAnnouncerGroups[i] = new StringMap();
    }

    RegConsoleCmd("sm_announcers", Command_Announcers, "Configure paid announcer sound packs.");
    RegConsoleCmd("sm_announcer", Command_Announcers, "Configure paid announcer sound packs.");

    PluginStats_Init("announcers_statistics_events");
    g_cvStatisticsLogging = CreateConVar(
        "announcers_statistics_logging",
        "1",
        "Write structured announcer events to announcers_statistics_events.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvMultikillFileLogging = CreateConVar(
        "announcers_multikill_file_logging",
        "0",
        "Also write multikill announcements to logs/announcers_multikill.log.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );

    g_cvKillstreaksEnabled = CreateConVar(
        "announcers_killstreaks_enabled",
        "1",
        "Enable killstreak announcements.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvMultikillsEnabled = CreateConVar(
        "announcers_multikills_enabled",
        "1",
        "Enable multikill announcements.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvKillstreaksSound = CreateConVar(
        "announcers_killstreaks_sound",
        "1",
        "Play SaySounds for killstreak announcements.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvMultikillsSound = CreateConVar(
        "announcers_multikills_sound",
        "1",
        "Play SaySounds for multikill announcements.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvMultikillBroadcastMin = CreateConVar(
        "announcers_multikill_broadcast_min",
        "3",
        "Minimum multikill value required to broadcast the announcement.",
        FCVAR_NONE,
        true,
        1.0
    );
    g_cvMultikillRollupWindow = CreateConVar(
        "announcers_multikill_rollup_window",
        "3.0",
        "Seconds to wait for higher multikill levels before announcing the latest one.",
        FCVAR_NONE,
        true,
        0.1
    );
    g_cvMultikillsChat = CreateConVar(
        "announcers_multikills_chat",
        "1",
        "Show multikill announcements in chat. 0 = center text, 1 = chat.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvStreaksChat = CreateConVar(
        "announcers_streaks_chat",
        "0",
        "Show killstreak announcements in chat. 0 = center text, 1 = chat.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvStreakEndsChat = CreateConVar(
        "announcers_streak_ends_chat",
        "1",
        "Show killstreak-end announcements in chat. 0 = center text, 1 = chat.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );
    g_cvStreakEndMin = CreateConVar(
        "announcers_streak_end_min",
        "7",
        "Minimum ended killstreak value required to broadcast a shutdown announcement.",
        FCVAR_NONE,
        true,
        1.0
    );
    g_cvShutdownMin = CreateConVar(
        "announcers_shutdown_min",
        "10",
        "Minimum ended killstreak value required to play the shutdown sound to everyone.",
        FCVAR_NONE,
        true,
        1.0
    );
    g_cvKillstreakBroadcastMin = CreateConVar(
        "announcers_killstreak_broadcast_min",
        "10",
        "Minimum killstreak value required to broadcast the milestone to everyone.",
        FCVAR_NONE,
        true,
        1.0
    );
    g_cvPlayercountThreshold = CreateConVar(
        "announcers_playercount_threshold",
        "0.50",
        "Capacity ratio threshold used for low/high population announcement routing.",
        FCVAR_NONE,
        true,
        0.0,
        true,
        1.0
    );

    LoadAnnouncerConfig();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && AreClientCookiesCached(client))
        {
            LoadAnnouncerGroupPreferences(client);
        }
    }
}

public void OnConfigsExecuted()
{
    LoadAnnouncerConfig();
}

public void OnPluginEnd()
{
    ClearAllMultikillRollups();
    ClearSoundMap(g_KillstreakSoundMap);
    ClearSoundMap(g_MultikillSoundMap);
    ClearSoundMap(g_ShutdownSoundMap);
    ClearSoundMap(g_MedicDropSoundMap);

    if (g_KillstreakSoundMap != null)
    {
        delete g_KillstreakSoundMap;
        g_KillstreakSoundMap = null;
    }

    if (g_MultikillSoundMap != null)
    {
        delete g_MultikillSoundMap;
        g_MultikillSoundMap = null;
    }

    if (g_ShutdownSoundMap != null)
    {
        delete g_ShutdownSoundMap;
        g_ShutdownSoundMap = null;
    }

    if (g_MedicDropSoundMap != null)
    {
        delete g_MedicDropSoundMap;
        g_MedicDropSoundMap = null;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_DisabledAnnouncerGroups[i] != null)
        {
            delete g_DisabledAnnouncerGroups[i];
            g_DisabledAnnouncerGroups[i] = null;
        }
    }

    PluginStats_Shutdown();
}

public void OnMapStart()
{
    PluginStats_OnMapStart();
}

public void OnMapEnd()
{
    ClearAllMultikillRollups();
    PluginStats_Flush();
}

public void OnClientDisconnect(int client)
{
    ClearMultikillRollup(client);
    ClearAnnouncerGroupPreferences(client);
}

public void OnClientPutInServer(int client)
{
    EnsureAnnouncerGroupPreferenceMap(client);
    ClearAnnouncerGroupPreferences(client);

    if (AreClientCookiesCached(client))
    {
        LoadAnnouncerGroupPreferences(client);
    }
}

public void OnClientCookiesCached(int client)
{
    LoadAnnouncerGroupPreferences(client);
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional(ANNOUNCER_SOUND_NATIVE);
    MarkNativeAsOptional(ANNOUNCER_SOUND_PLAY_AS_NATIVE);
    MarkNativeAsOptional(ANNOUNCER_SOUND_CAN_USE_NATIVE);
    MarkNativeAsOptional(ANNOUNCER_SOUND_IS_PAID_NATIVE);
    MarkNativeAsOptional(ANNOUNCER_SOUND_GET_GROUP_NATIVE);
    MarkNativeAsOptional(DGM_CAPACITY_NATIVE);
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional(POINTS_STORE_BONUS_NATIVE);
    MarkNativeAsOptional("Filters_GetChatName");
    return APLRes_Success;
}

public Action Command_Announcers(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (!AreClientCookiesCached(client))
    {
        PrintToChat(client, "[Announcers] Preferences are loading. Try again in a moment.");
        return Plugin_Handled;
    }

    ShowAnnouncerGroupsMenu(client);
    return Plugin_Handled;
}

void ShowAnnouncerGroupsMenu(int client)
{
    if (!CanInspectSaySoundGroups())
    {
        PrintToChat(client, "[Announcers] Saysound ownership info is not available right now.");
        return;
    }

    ArrayList groups = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_GROUP_NAME));
    AddPurchasedAnnouncerGroupsFromMap(client, groups, g_KillstreakSoundMap);
    AddPurchasedAnnouncerGroupsFromMap(client, groups, g_MultikillSoundMap);
    AddPurchasedAnnouncerGroupsFromMap(client, groups, g_ShutdownSoundMap);
    AddPurchasedAnnouncerGroupsFromMap(client, groups, g_MedicDropSoundMap);

    if (groups.Length == 0)
    {
        delete groups;
        PrintToChat(client, "[Announcers] No purchased announcer sound packs are available.");
        return;
    }

    Menu menu = new Menu(MenuHandler_AnnouncerGroups);
    menu.SetTitle("Announcers");

    char groupName[ANNOUNCER_MAX_GROUP_NAME];
    char display[96];
    for (int i = 0; i < groups.Length; i++)
    {
        groups.GetString(i, groupName, sizeof(groupName));
        Format(display, sizeof(display), "%s (%s)", groupName, IsAnnouncerGroupDisabled(client, groupName) ? "Disabled" : "Enabled");
        menu.AddItem(groupName, display);
    }

    delete groups;
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_AnnouncerGroups(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            return 0;
        }

        char groupName[ANNOUNCER_MAX_GROUP_NAME];
        menu.GetItem(item, groupName, sizeof(groupName));

        bool disabled = !IsAnnouncerGroupDisabled(client, groupName);
        SetAnnouncerGroupDisabled(client, groupName, disabled);
        SaveAnnouncerGroupPreferences(client);
        PrintToChat(client, "[Announcers] %s %s.", groupName, disabled ? "disabled" : "enabled");
        ShowAnnouncerGroupsMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public void WhaleTracker_OnKillstreak(int client, int killstreak)
{
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    LogAnnouncerEvent(client, 0, "killstreak", killstreak);
    AwardKillstreakBonusPoints(client, killstreak);

    if (!g_cvKillstreaksEnabled.BoolValue)
    {
        return;
    }

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    AnnounceKillstreakMilestone(client, clientName, killstreak);
}

public void WhaleTracker_OnKillstreakEnd(int attacker, int victim, int killstreak)
{
    if (!IsValidAnnouncerClient(victim))
    {
        return;
    }

    LogAnnouncerEvent(victim, attacker, "killstreak_end", killstreak);
    AwardKillstreakEndBonusPoints(attacker, killstreak);

    if (!g_cvKillstreaksEnabled.BoolValue)
    {
        return;
    }

    AnnounceKillstreakEnd(victim, killstreak);
}

public void WhaleTracker_OnMultikill(int client, int kills)
{
    QueueMultikillRollup(client, kills);
}

public void WhaleTracker_OnMedicDrop(int attacker, int medic)
{
    if (IsValidAnnouncerClient(medic))
    {
        LogAnnouncerEvent(medic, attacker, "medic_drop", 1);
    }

    PlayMedicDropSound(attacker, medic);
}

void AnnounceKillstreakMilestone(int client, const char[] clientName, int killstreak, bool playSound = true)
{
    char label[32], commandName[32];
    if (!GetKillstreakAnnouncement(client, killstreak, label, sizeof(label), commandName, sizeof(commandName)))
    {
        return;
    }

    char message[128];
    Format(message, sizeof(message), "%s is %s! (%d)", clientName, label, killstreak);

    int target = 0;
    int broadcastMinimum = 10;
    if (g_cvKillstreakBroadcastMin != null)
    {
        broadcastMinimum = g_cvKillstreakBroadcastMin.IntValue;
    }

    if (killstreak < broadcastMinimum)
    {
        target = client;
    }

    bool useSound = playSound && g_cvKillstreaksSound.BoolValue && commandName[0] != '\0';
    Announcer_Announce(target, client, commandName, Announcer_ShouldPlaySound(useSound), g_cvStreaksChat.BoolValue, message);
}

void AnnounceKillstreakEnd(int client, int killstreak)
{
    int minimumKillstreak = 7;
    if (g_cvStreakEndMin != null)
    {
        minimumKillstreak = g_cvStreakEndMin.IntValue;
    }

    if (killstreak < minimumKillstreak)
    {
        return;
    }

    PlayShutdownSound(client, killstreak);

    if (g_cvStreakEndsChat.BoolValue)
    {
        char displayName[256];
        GetClientChatDisplayName(client, displayName, sizeof(displayName));
        CPrintToChatAllEx(client, "%s{default}'s killstreak was shut down! (%d)", displayName, killstreak);
        return;
    }

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    PrintCenterTextAll("%s's killstreak was shut down! (%d)", clientName, killstreak);
}

void PlayShutdownSound(int client, int killstreak)
{
    if (!Announcer_ShouldPlaySound(true))
    {
        return;
    }

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    if (!GetShutdownSoundCommand(client, killstreak, commandName, sizeof(commandName)))
    {
        return;
    }

    int shutdownMinimum = 10;
    if (g_cvShutdownMin != null)
    {
        shutdownMinimum = g_cvShutdownMin.IntValue;
    }

    if (killstreak < shutdownMinimum)
    {
        if (IsHumanAnnouncerClient(client))
        {
            Announcer_PlaySound(client, client, commandName);
        }
        return;
    }

    Announcer_PlaySound(0, client, commandName);
}

void PlayMedicDropSound(int attacker, int medic)
{
    if (!IsValidAnnouncerClient(medic) || !Announcer_ShouldPlaySound(true))
    {
        return;
    }

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    int sourceClient = medic;
    if (!GetMedicDropSoundCommand(attacker, medic, commandName, sizeof(commandName), sourceClient))
    {
        return;
    }

    Announcer_PlaySound(0, sourceClient, commandName);
}

void QueueMultikillRollup(int client, int kills)
{
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    char label[32];
    if (!GetMultikillLabel(kills, label, sizeof(label)))
    {
        return;
    }

    if (g_hMultikillRollupTimer[client] != null)
    {
        delete g_hMultikillRollupTimer[client];
        g_hMultikillRollupTimer[client] = null;
    }

    g_iPendingMultikillKills[client] = kills;
    g_iPendingMultikillUserId[client] = GetClientUserId(client);
    g_iPendingMultikillSerial[client]++;

    DataPack pack = new DataPack();
    pack.WriteCell(client);
    pack.WriteCell(g_iPendingMultikillUserId[client]);
    pack.WriteCell(g_iPendingMultikillSerial[client]);

    g_hMultikillRollupTimer[client] = CreateTimer(
        GetMultikillRollupWindow(),
        Timer_FlushMultikillRollup,
        pack,
        TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE
    );
}

public Action Timer_FlushMultikillRollup(Handle timer, DataPack pack)
{
    pack.Reset();
    int originalClient = pack.ReadCell();
    int userId = pack.ReadCell();
    int serial = pack.ReadCell();
    int client = GetClientOfUserId(userId);

    if (client != originalClient || !IsValidAnnouncerClient(client) || g_iPendingMultikillSerial[client] != serial)
    {
        if (originalClient >= 1 && originalClient <= MaxClients && g_iPendingMultikillSerial[originalClient] == serial)
        {
            ClearMultikillRollup(originalClient, false);
        }
        return Plugin_Stop;
    }

    int kills = g_iPendingMultikillKills[client];
    ClearMultikillRollup(client, false);
    AnnounceMultikillNow(client, kills);
    return Plugin_Stop;
}

void AnnounceMultikillNow(int client, int kills)
{
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    char label[32];
    if (!GetMultikillLabel(kills, label, sizeof(label)))
    {
        return;
    }

    LogAnnouncerEvent(client, 0, "multikill", kills);
    LogMultikillEvent(client, kills, label);
    AwardMultikillBonusPoints(client, kills);
    if (!g_cvMultikillsEnabled.BoolValue)
    {
        return;
    }

    int broadcastMinimum = 10;
    if (g_cvMultikillBroadcastMin != null)
    {
        broadcastMinimum = g_cvMultikillBroadcastMin.IntValue;
    }

    bool broadcastToAll = kills >= broadcastMinimum;

    if (broadcastToAll && kills == WHALE_MULTIKILL_MIN_LEVEL && !Announcer_ServerCapacityCheck())
    {
        broadcastToAll = false;
    }

    char clientName[256];
    if (g_cvMultikillsChat.BoolValue)
    {
        BuildDisplayName(client, clientName, sizeof(clientName));
    }
    else
    {
        GetClientName(client, clientName, sizeof(clientName));
    }

    char message[128];
    FormatMultikillMessage(clientName, label, kills, message, sizeof(message), kills >= 4);

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    GetAnnouncerSoundCommand(g_MultikillSoundMap, kills, "", client, commandName, sizeof(commandName));

    bool useSound = g_cvMultikillsSound.BoolValue && commandName[0] != '\0';
    Announcer_Announce(broadcastToAll ? 0 : client, client, commandName, Announcer_ShouldPlaySound(useSound), g_cvMultikillsChat.BoolValue, message);
}

void AwardMultikillBonusPoints(int client, int kills)
{
    int points = 0;
    if (kills < 3)
    {
        return;
    }
    else if (kills >= WHALE_MULTIKILL_MAX_LEVEL)
    {
        points = 3;
    }
    else
    {
        points = 2;
    }

    if (GetFeatureStatus(FeatureType_Native, POINTS_STORE_BONUS_NATIVE) != FeatureStatus_Available)
    {
        return;
    }

    PointsStore_ApplyBonusPoints(client, points, true, true, 1.0, "multikill", kills, 3.0);
}

void AwardKillstreakBonusPoints(int client, int killstreak)
{
    if (killstreak < WHALE_KILLSTREAK_BONUS_INTERVAL || killstreak % WHALE_KILLSTREAK_BONUS_INTERVAL != 0)
    {
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, POINTS_STORE_BONUS_NATIVE) != FeatureStatus_Available)
    {
        return;
    }

    int points = killstreak > 10 ? 2 : 1;
    PointsStore_ApplyBonusPoints(client, points, true, true, 1.0, "killstreak", killstreak, 3.0);
}

void AwardKillstreakEndBonusPoints(int client, int killstreak)
{
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    int points = 0;
    if (killstreak > 19)
    {
        points = 3;
    }
    else if (killstreak > 14)
    {
        points = 2;
    }
    else if (killstreak > 6)
    {
        points = 1;
    }

    if (points <= 0)
    {
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, POINTS_STORE_BONUS_NATIVE) != FeatureStatus_Available)
    {
        return;
    }

    PointsStore_ApplyBonusPoints(client, points, true, true, 1.0, "killstreak_end", killstreak, 3.0);
}

float GetMultikillRollupWindow()
{
    if (g_cvMultikillRollupWindow == null)
    {
        return 1.0;
    }

    return g_cvMultikillRollupWindow.FloatValue;
}

void ClearAllMultikillRollups()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ClearMultikillRollup(client);
    }
}

void ClearMultikillRollup(int client, bool closeTimer = true)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (closeTimer && g_hMultikillRollupTimer[client] != null)
    {
        delete g_hMultikillRollupTimer[client];
    }

    g_hMultikillRollupTimer[client] = null;
    g_iPendingMultikillKills[client] = 0;
    g_iPendingMultikillUserId[client] = 0;
    g_iPendingMultikillSerial[client]++;
}

bool GetKillstreakAnnouncement(int client, int killstreak, char[] label, int labelLen, char[] commandName, int commandLen)
{
    if (killstreak < WHALE_KILLSTREAK_BONUS_INTERVAL || killstreak % WHALE_KILLSTREAK_BONUS_INTERVAL != 0)
    {
        return false;
    }

    int index = (killstreak / WHALE_KILLSTREAK_BONUS_INTERVAL) - 1;
    if (index >= sizeof(g_KillstreakLabels))
    {
        index = sizeof(g_KillstreakLabels) - 1;
    }

    char defaultCommand[ANNOUNCER_MAX_COMMAND_NAME];
    strcopy(label, labelLen, g_KillstreakLabels[index]);
    strcopy(defaultCommand, sizeof(defaultCommand), g_KillstreakCommands[index]);
    GetAnnouncerSoundCommand(g_KillstreakSoundMap, killstreak, defaultCommand, client, commandName, commandLen);
    return true;
}

bool GetMultikillLabel(int kills, char[] label, int labelLen)
{
    int index = kills - WHALE_MULTIKILL_MIN_LEVEL;
    if (kills > WHALE_MULTIKILL_MAX_LEVEL || index < 0 || index >= sizeof(g_MultikillLabels))
    {
        return false;
    }

    strcopy(label, labelLen, g_MultikillLabels[index]);
    return true;
}

void FormatMultikillMessage(const char[] clientName, const char[] label, int kills, char[] message, int messageLen, bool includeKills = true)
{
    if (includeKills)
    {
        Format(message, messageLen, "%s got a %s! (%d)", clientName, label, kills);
        return;
    }

    Format(message, messageLen, "%s got a %s!", clientName, label);
}

void Announcer_CenterText(int target, int sourceClient, const char[] commandName, bool useSound, const char[] message)
{
    if (target > 0)
    {
        if (IsHumanAnnouncerClient(target) && (!useSound || Announcer_PlaySound(target, sourceClient, commandName)))
        {
            PrintCenterText(target, "%s", message);
        }
        return;
    }

    if (!useSound)
    {
        PrintCenterTextAll("%s", message);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        Announcer_CenterText(i, sourceClient, commandName, true, message);
    }
}

void Announcer_Announce(int target, int author, const char[] commandName, bool useSound, bool useChat, const char[] message)
{
    if (!useChat)
    {
        Announcer_CenterText(target, author, commandName, useSound, message);
        return;
    }

    if (target > 0)
    {
        if (IsHumanAnnouncerClient(target) && (!useSound || Announcer_PlaySound(target, author, commandName)))
        {
            Announcer_MessageClient(target, author, message);
        }
        return;
    }

    if (useSound)
    {
        Announcer_PlaySound(0, author, commandName);
    }

    Announcer_MessageAll(author, true, message);
}

bool Announcer_PlaySound(int target, int sourceClient, const char[] commandName)
{
    if (!commandName[0])
    {
        return false;
    }

    if (IsValidAnnouncerClient(sourceClient)
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_PLAY_AS_NATIVE) == FeatureStatus_Available)
    {
        return SaySounds_PlayCommandAs(sourceClient, target, commandName, false);
    }

    if (GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_NATIVE) == FeatureStatus_Available)
    {
        return SaySounds_PlayCommand(target, commandName, false);
    }

    return false;
}

void Announcer_MessageClient(int target, int author, const char[] message)
{
    if (IsValidAnnouncerClient(author) && IsClientInGame(author))
    {
        CPrintToChatEx(target, author, "%s", message);
        return;
    }

    CPrintToChat(target, "%s", message);
}

void Announcer_MessageAll(int author, bool useChat, const char[] message)
{
    if (useChat)
    {
        if (IsValidAnnouncerClient(author) && IsClientInGame(author))
        {
            CPrintToChatAllEx(author, "%s", message);
        }
        else
        {
            CPrintToChatAll("%s", message);
        }
        return;
    }

    PrintCenterTextAll("%s", message);
}

void GetClientChatDisplayName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen)
        && buffer[0] != '\0')
    {
        TrimString(buffer);
        return;
    }

    GetClientName(client, buffer, maxlen);
    TrimString(buffer);
}

void BuildDisplayName(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';

    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen)
        && buffer[0] != '\0')
    {
        ResolveTeamColorTag(client, buffer, maxlen);
        return;
    }

    char colorTag[16];
    BuildTeamColorTag(client, colorTag, sizeof(colorTag));
    Format(buffer, maxlen, "%s%N{default}", colorTag, client);
}

void ResolveTeamColorTag(int client, char[] buffer, int maxlen)
{
    if (StrContains(buffer, "{teamcolor}", false) == -1)
    {
        return;
    }

    char colorTag[16];
    BuildTeamColorTag(client, colorTag, sizeof(colorTag));
    ReplaceString(buffer, maxlen, "{teamcolor}", colorTag, false);
}

void BuildTeamColorTag(int client, char[] colorTag, int length)
{
    switch (GetClientTeam(client))
    {
        case 2: strcopy(colorTag, length, "{red}");
        case 3: strcopy(colorTag, length, "{blue}");
        default: strcopy(colorTag, length, "{default}");
    }
}

bool Announcer_ShouldPlaySound(bool playSound)
{
    return playSound
        && LibraryExists(ANNOUNCER_SOUND_LIBRARY)
        && (GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_PLAY_AS_NATIVE) == FeatureStatus_Available
            || GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_NATIVE) == FeatureStatus_Available);
}

void LoadAnnouncerConfig()
{
    if (g_KillstreakSoundMap == null)
    {
        g_KillstreakSoundMap = new StringMap();
    }
    if (g_MultikillSoundMap == null)
    {
        g_MultikillSoundMap = new StringMap();
    }
    if (g_ShutdownSoundMap == null)
    {
        g_ShutdownSoundMap = new StringMap();
    }
    if (g_MedicDropSoundMap == null)
    {
        g_MedicDropSoundMap = new StringMap();
    }

    ClearSoundMap(g_KillstreakSoundMap);
    ClearSoundMap(g_MultikillSoundMap);
    ClearSoundMap(g_ShutdownSoundMap);
    ClearSoundMap(g_MedicDropSoundMap);

    g_ConfigDepth = 0;
    g_ConfigLevel = 0;
    g_ConfigMode = AnnouncerConfig_None;

    char filePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filePath, sizeof(filePath), ANNOUNCER_CONFIG_FILE);

    if (!FileExists(filePath))
    {
        LogError("[Announcers] Config file not found: %s", filePath);
        return;
    }

    SMCParser parser = new SMCParser();
    parser.OnEnterSection = AnnouncerConfig_EnterSection;
    parser.OnLeaveSection = AnnouncerConfig_LeaveSection;
    parser.OnKeyValue = AnnouncerConfig_KeyValue;

    int errorLine, errorColumn;
    SMCError result = parser.ParseFile(filePath, errorLine, errorColumn);
    if (result != SMCError_Okay)
    {
        char error[256];
        parser.GetErrorString(result, error, sizeof(error));
        LogError("[Announcers] Failed to parse config: %s (line %d, column %d)", error, errorLine, errorColumn);
    }

    delete parser;
}

public SMCResult AnnouncerConfig_EnterSection(SMCParser parser, const char[] name, bool optQuotes)
{
    g_ConfigDepth++;

    char sectionName[ANNOUNCER_MAX_COMMAND_NAME];
    strcopy(sectionName, sizeof(sectionName), name);
    TrimString(sectionName);
    ToLowercaseInPlace(sectionName, sizeof(sectionName));

    if (g_ConfigDepth == 2)
    {
        if (StrEqual(sectionName, "killstreaks"))
        {
            g_ConfigMode = AnnouncerConfig_Killstreaks;
        }
        else if (StrEqual(sectionName, "multikills"))
        {
            g_ConfigMode = AnnouncerConfig_Multikills;
        }
        else if (StrEqual(sectionName, "shutdown"))
        {
            g_ConfigMode = AnnouncerConfig_Shutdown;
        }
        else if (StrEqual(sectionName, "medicdrops") || StrEqual(sectionName, "medicdrop") || StrEqual(sectionName, "medic_drops") || StrEqual(sectionName, "medic_drop"))
        {
            g_ConfigMode = AnnouncerConfig_MedicDrops;
        }
        else
        {
            g_ConfigMode = AnnouncerConfig_None;
        }
    }
    else if (g_ConfigDepth == 3)
    {
        g_ConfigLevel = StringToInt(sectionName);
    }

    return SMCParse_Continue;
}

public SMCResult AnnouncerConfig_LeaveSection(SMCParser parser)
{
    if (g_ConfigDepth == 3)
    {
        g_ConfigLevel = 0;
    }
    else if (g_ConfigDepth == 2)
    {
        g_ConfigMode = AnnouncerConfig_None;
    }

    if (g_ConfigDepth > 0)
    {
        g_ConfigDepth--;
    }

    return SMCParse_Continue;
}

public SMCResult AnnouncerConfig_KeyValue(SMCParser parser, const char[] key, const char[] value, bool keyQuoted, bool valueQuoted)
{
    if (g_ConfigMode == AnnouncerConfig_Shutdown)
    {
        if (g_ConfigDepth != 2 && (g_ConfigDepth != 3 || g_ConfigLevel <= 0))
        {
            return SMCParse_Continue;
        }

        char commandName[ANNOUNCER_MAX_COMMAND_NAME];
        GetConfigCommandName(key, value, commandName, sizeof(commandName));
        if (commandName[0])
        {
            AddAnnouncerSoundCommand(g_ShutdownSoundMap, g_ConfigDepth == 3 ? g_ConfigLevel : 0, commandName);
        }
        return SMCParse_Continue;
    }

    if (g_ConfigMode == AnnouncerConfig_MedicDrops)
    {
        if (g_ConfigDepth != 2)
        {
            return SMCParse_Continue;
        }

        char commandName[ANNOUNCER_MAX_COMMAND_NAME];
        GetConfigCommandName(key, value, commandName, sizeof(commandName));
        if (commandName[0])
        {
            AddAnnouncerSoundCommand(g_MedicDropSoundMap, 0, commandName);
        }
        return SMCParse_Continue;
    }

    if (g_ConfigDepth != 3 || g_ConfigLevel <= 0 || g_ConfigMode == AnnouncerConfig_None)
    {
        return SMCParse_Continue;
    }

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    GetConfigCommandName(key, value, commandName, sizeof(commandName));
    if (!commandName[0])
    {
        return SMCParse_Continue;
    }

    if (g_ConfigMode == AnnouncerConfig_Killstreaks)
    {
        AddAnnouncerSoundCommand(g_KillstreakSoundMap, g_ConfigLevel, commandName);
    }
    else if (g_ConfigMode == AnnouncerConfig_Multikills)
    {
        AddAnnouncerSoundCommand(g_MultikillSoundMap, g_ConfigLevel, commandName);
    }

    return SMCParse_Continue;
}

void GetConfigCommandName(const char[] key, const char[] value, char[] commandName, int commandLen)
{
    strcopy(commandName, commandLen, key);
    TrimString(commandName);

    char valueText[ANNOUNCER_MAX_COMMAND_NAME];
    strcopy(valueText, sizeof(valueText), value);
    TrimString(valueText);

    if (valueText[0] && StartsWith(commandName, "sound"))
    {
        strcopy(commandName, commandLen, valueText);
        TrimString(commandName);
    }

    if (commandName[0] == '!' || commandName[0] == '/')
    {
        ShiftStringLeft(commandName, commandLen, 1);
    }

    ToLowercaseInPlace(commandName, commandLen);
}

void AddAnnouncerSoundCommand(StringMap map, int level, const char[] commandName)
{
    if (map == null || !commandName[0])
    {
        return;
    }

    char levelKey[16];
    IntToString(level, levelKey, sizeof(levelKey));

    any listValue;
    ArrayList commands = null;
    if (map.GetValue(levelKey, listValue))
    {
        commands = view_as<ArrayList>(listValue);
    }
    else
    {
        commands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));
        map.SetValue(levelKey, commands);
    }

    commands.PushString(commandName);
}

void AddPurchasedAnnouncerGroupsFromMap(int client, ArrayList groups, StringMap map)
{
    if (map == null || groups == null)
    {
        return;
    }

    StringMapSnapshot snapshot = map.Snapshot();
    if (snapshot == null)
    {
        return;
    }

    for (int i = 0; i < snapshot.Length; i++)
    {
        char key[16];
        snapshot.GetKey(i, key, sizeof(key));

        any listValue;
        if (!map.GetValue(key, listValue))
        {
            continue;
        }

        AddPurchasedAnnouncerGroupsFromCommands(client, groups, view_as<ArrayList>(listValue));
    }

    delete snapshot;
}

void AddPurchasedAnnouncerGroupsFromCommands(int client, ArrayList groups, ArrayList commands)
{
    if (commands == null)
    {
        return;
    }

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    char groupName[ANNOUNCER_MAX_GROUP_NAME];
    for (int i = 0; i < commands.Length; i++)
    {
        commands.GetString(i, commandName, sizeof(commandName));
        if (!SaySounds_IsCommandPaid(commandName)
            || !SaySounds_GetCommandGroup(commandName, groupName, sizeof(groupName))
            || !SaySounds_CanClientUseCommand(client, groupName))
        {
            continue;
        }

        AddUniqueAnnouncerGroup(groups, groupName);
    }
}

void AddUniqueAnnouncerGroup(ArrayList groups, const char[] groupName)
{
    if (groups == null || !groupName[0])
    {
        return;
    }

    char current[ANNOUNCER_MAX_GROUP_NAME];
    for (int i = 0; i < groups.Length; i++)
    {
        groups.GetString(i, current, sizeof(current));
        if (StrEqual(current, groupName, false))
        {
            return;
        }
    }

    groups.PushString(groupName);
}

bool GetAnnouncerSoundCommand(StringMap map, int level, const char[] fallbackCommand, int sourceClient, char[] commandName, int commandLen)
{
    commandName[0] = '\0';

    ArrayList commands = GetAnnouncerSoundCommandList(map, level);
    if (commands != null && commands.Length > 0)
    {
        return SelectAnnouncerSoundCommand(commands, sourceClient, commandName, commandLen);
    }

    if (!fallbackCommand[0])
    {
        return false;
    }

    if (CanUsePurchaseAwareSoundSelection(sourceClient)
        && (!SaySounds_CanClientUseCommand(sourceClient, fallbackCommand) || IsAnnouncerSoundCommandDisabled(sourceClient, fallbackCommand)))
    {
        return false;
    }

    strcopy(commandName, commandLen, fallbackCommand);
    return commandName[0] != '\0';
}

ArrayList GetAnnouncerSoundCommandList(StringMap map, int level)
{
    if (map == null)
    {
        return null;
    }

    char levelKey[16];
    IntToString(level, levelKey, sizeof(levelKey));

    any listValue;
    if (!map.GetValue(levelKey, listValue))
    {
        return null;
    }

    return view_as<ArrayList>(listValue);
}

bool SelectAnnouncerSoundCommand(ArrayList commands, int sourceClient, char[] commandName, int commandLen)
{
    commandName[0] = '\0';
    if (commands == null || commands.Length <= 0)
    {
        return false;
    }

    if (!CanUsePurchaseAwareSoundSelection(sourceClient))
    {
        commands.GetString(GetRandomInt(0, commands.Length - 1), commandName, commandLen);
        return commandName[0] != '\0';
    }

    ArrayList paidCommands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));
    ArrayList freeCommands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));

    char candidate[ANNOUNCER_MAX_COMMAND_NAME];
    for (int i = 0; i < commands.Length; i++)
    {
        commands.GetString(i, candidate, sizeof(candidate));
        if (!SaySounds_CanClientUseCommand(sourceClient, candidate))
        {
            continue;
        }

        if (SaySounds_IsCommandPaid(candidate))
        {
            if (IsAnnouncerSoundCommandDisabled(sourceClient, candidate))
            {
                continue;
            }

            paidCommands.PushString(candidate);
        }
        else
        {
            freeCommands.PushString(candidate);
        }
    }

    bool found = false;
    if (paidCommands.Length > 0)
    {
        paidCommands.GetString(GetRandomInt(0, paidCommands.Length - 1), commandName, commandLen);
        found = true;
    }
    else if (freeCommands.Length > 0)
    {
        freeCommands.GetString(GetRandomInt(0, freeCommands.Length - 1), commandName, commandLen);
        found = true;
    }

    delete paidCommands;
    delete freeCommands;
    return found && commandName[0] != '\0';
}

bool CanUsePurchaseAwareSoundSelection(int sourceClient)
{
    return IsValidAnnouncerClient(sourceClient)
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_CAN_USE_NATIVE) == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_IS_PAID_NATIVE) == FeatureStatus_Available;
}

bool CanInspectSaySoundGroups()
{
    return GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_CAN_USE_NATIVE) == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_IS_PAID_NATIVE) == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_GET_GROUP_NATIVE) == FeatureStatus_Available;
}

bool IsAnnouncerSoundCommandDisabled(int client, const char[] commandName)
{
    if (!CanInspectSaySoundGroups() || !SaySounds_IsCommandPaid(commandName))
    {
        return false;
    }

    char groupName[ANNOUNCER_MAX_GROUP_NAME];
    if (!SaySounds_GetCommandGroup(commandName, groupName, sizeof(groupName)))
    {
        return false;
    }

    return IsAnnouncerGroupDisabled(client, groupName);
}

bool GetMedicDropSoundCommand(int attacker, int medic, char[] commandName, int commandLen, int &sourceClient)
{
    commandName[0] = '\0';
    sourceClient = medic;

    ArrayList commands = GetAnnouncerSoundCommandList(g_MedicDropSoundMap, 0);
    if (commands == null || commands.Length <= 0)
    {
        return false;
    }

    ArrayList paidCommands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));
    ArrayList paidSources = new ArrayList();

    AddEligiblePaidSoundCommands(commands, medic, paidCommands, paidSources);
    if (attacker != medic)
    {
        AddEligiblePaidSoundCommands(commands, attacker, paidCommands, paidSources);
    }

    if (paidCommands.Length > 0)
    {
        int pick = GetRandomInt(0, paidCommands.Length - 1);
        paidCommands.GetString(pick, commandName, commandLen);
        sourceClient = paidSources.Get(pick);
    }

    delete paidCommands;
    delete paidSources;

    if (commandName[0] != '\0')
    {
        return true;
    }

    return GetAnnouncerSoundCommand(g_MedicDropSoundMap, 0, "", medic, commandName, commandLen);
}

void AddEligiblePaidSoundCommands(ArrayList commands, int sourceClient, ArrayList paidCommands, ArrayList paidSources)
{
    if (!CanUsePurchaseAwareSoundSelection(sourceClient))
    {
        return;
    }

    char candidate[ANNOUNCER_MAX_COMMAND_NAME];
    for (int i = 0; i < commands.Length; i++)
    {
        commands.GetString(i, candidate, sizeof(candidate));
        if (SaySounds_CanClientUseCommand(sourceClient, candidate)
            && SaySounds_IsCommandPaid(candidate)
            && !IsAnnouncerSoundCommandDisabled(sourceClient, candidate))
        {
            paidCommands.PushString(candidate);
            paidSources.Push(sourceClient);
        }
    }
}

bool GetShutdownSoundCommand(int sourceClient, int killstreak, char[] commandName, int commandLen)
{
    commandName[0] = '\0';

    if (g_ShutdownSoundMap == null)
    {
        return false;
    }

    int roundedKillstreak = killstreak - (killstreak % WHALE_KILLSTREAK_BONUS_INTERVAL);
    for (int level = roundedKillstreak; level >= WHALE_KILLSTREAK_BONUS_INTERVAL; level -= WHALE_KILLSTREAK_BONUS_INTERVAL)
    {
        if (GetAnnouncerSoundCommand(g_ShutdownSoundMap, level, "", sourceClient, commandName, commandLen))
        {
            return true;
        }
    }

    return GetAnnouncerSoundCommand(g_ShutdownSoundMap, 0, "", sourceClient, commandName, commandLen);
}

void ClearSoundMap(StringMap map)
{
    if (map == null)
    {
        return;
    }

    StringMapSnapshot snapshot = map.Snapshot();
    if (snapshot != null)
    {
        for (int i = 0; i < snapshot.Length; i++)
        {
            char key[16];
            snapshot.GetKey(i, key, sizeof(key));

            any listValue;
            if (map.GetValue(key, listValue))
            {
                ArrayList commands = view_as<ArrayList>(listValue);
                if (commands != null)
                {
                    delete commands;
                }
            }
        }
        delete snapshot;
    }

    map.Clear();
}

void EnsureAnnouncerGroupPreferenceMap(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (g_DisabledAnnouncerGroups[client] == null)
    {
        g_DisabledAnnouncerGroups[client] = new StringMap();
    }
}

void ClearAnnouncerGroupPreferences(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    EnsureAnnouncerGroupPreferenceMap(client);
    g_DisabledAnnouncerGroups[client].Clear();
}

void LoadAnnouncerGroupPreferences(int client)
{
    if (client < 1 || client > MaxClients || g_hAnnouncerGroupsCookie == INVALID_HANDLE)
    {
        return;
    }

    ClearAnnouncerGroupPreferences(client);

    char value[ANNOUNCER_GROUP_PREF_VALUE];
    GetClientCookie(client, g_hAnnouncerGroupsCookie, value, sizeof(value));
    ParseAnnouncerGroupPreferenceValue(client, value);
}

void SaveAnnouncerGroupPreferences(int client)
{
    if (client < 1 || client > MaxClients || g_hAnnouncerGroupsCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
    {
        return;
    }

    char value[ANNOUNCER_GROUP_PREF_VALUE];
    BuildAnnouncerGroupPreferenceValue(client, value, sizeof(value));
    SetClientCookie(client, g_hAnnouncerGroupsCookie, value);
}

void ParseAnnouncerGroupPreferenceValue(int client, const char[] rawValue)
{
    if (!rawValue[0])
    {
        return;
    }

    char working[ANNOUNCER_GROUP_PREF_VALUE];
    strcopy(working, sizeof(working), rawValue);
    TrimString(working);
    ToLowercaseInPlace(working, sizeof(working));

    char token[ANNOUNCER_MAX_GROUP_NAME];
    int start = 0;
    int len = strlen(working);
    while (start < len)
    {
        int commaPos = -1;
        for (int i = start; i < len; i++)
        {
            if (working[i] == ',')
            {
                commaPos = i;
                break;
            }
        }

        int end = (commaPos == -1) ? len : commaPos;
        int tokenLen = end - start;
        if (tokenLen > 0 && tokenLen < sizeof(token))
        {
            for (int i = 0; i < tokenLen; i++)
            {
                token[i] = working[start + i];
            }
            token[tokenLen] = '\0';
            TrimString(token);
            if (token[0])
            {
                SetAnnouncerGroupDisabled(client, token, true);
            }
        }

        start = end + 1;
    }
}

void BuildAnnouncerGroupPreferenceValue(int client, char[] value, int valueLen)
{
    value[0] = '\0';
    if (client < 1 || client > MaxClients || g_DisabledAnnouncerGroups[client] == null)
    {
        return;
    }

    StringMapSnapshot snapshot = g_DisabledAnnouncerGroups[client].Snapshot();
    if (snapshot == null)
    {
        return;
    }

    char groupName[ANNOUNCER_MAX_GROUP_NAME];
    for (int i = 0; i < snapshot.Length; i++)
    {
        snapshot.GetKey(i, groupName, sizeof(groupName));

        int valueLenNow = strlen(value);
        int needed = strlen(groupName) + (valueLenNow > 0 ? 1 : 0);
        if (valueLenNow + needed >= valueLen)
        {
            break;
        }

        if (valueLenNow > 0)
        {
            StrCat(value, valueLen, ",");
        }
        StrCat(value, valueLen, groupName);
    }

    delete snapshot;
}

bool IsAnnouncerGroupDisabled(int client, const char[] groupName)
{
    if (client < 1 || client > MaxClients || !groupName[0])
    {
        return false;
    }

    EnsureAnnouncerGroupPreferenceMap(client);

    char normalized[ANNOUNCER_MAX_GROUP_NAME];
    strcopy(normalized, sizeof(normalized), groupName);
    TrimString(normalized);
    ToLowercaseInPlace(normalized, sizeof(normalized));

    int disabled = 0;
    return g_DisabledAnnouncerGroups[client].GetValue(normalized, disabled) && disabled != 0;
}

void SetAnnouncerGroupDisabled(int client, const char[] groupName, bool disabled)
{
    if (client < 1 || client > MaxClients || !groupName[0])
    {
        return;
    }

    EnsureAnnouncerGroupPreferenceMap(client);

    char normalized[ANNOUNCER_MAX_GROUP_NAME];
    strcopy(normalized, sizeof(normalized), groupName);
    TrimString(normalized);
    ToLowercaseInPlace(normalized, sizeof(normalized));

    if (!normalized[0])
    {
        return;
    }

    if (disabled)
    {
        g_DisabledAnnouncerGroups[client].SetValue(normalized, 1);
    }
    else
    {
        g_DisabledAnnouncerGroups[client].Remove(normalized);
    }
}

void ShiftStringLeft(char[] buffer, int maxlen, int positions)
{
    int len = strlen(buffer);
    if (positions <= 0 || len == 0)
    {
        return;
    }

    if (positions >= len || positions >= maxlen)
    {
        buffer[0] = '\0';
        return;
    }

    for (int i = 0; i <= len - positions; i++)
    {
        buffer[i] = buffer[i + positions];
    }
}

bool StartsWith(const char[] str, const char[] prefix)
{
    int prefixLen = strlen(prefix);
    for (int i = 0; i < prefixLen; i++)
    {
        if (str[i] == '\0' || str[i] != prefix[i])
        {
            return false;
        }
    }

    return true;
}

void ToLowercaseInPlace(char[] buffer, int maxlen)
{
    for (int i = 0; i < maxlen && buffer[i] != '\0'; i++)
    {
        buffer[i] = CharToLower(buffer[i]);
    }
}

bool IsAnnouncerStatisticsLoggingEnabled()
{
    return g_cvStatisticsLogging != null && g_cvStatisticsLogging.BoolValue;
}

bool IsAnnouncerMultikillFileLoggingEnabled()
{
    return g_cvMultikillFileLogging != null && g_cvMultikillFileLogging.BoolValue;
}

void LogAnnouncerEvent(int client, int sourceClient, const char[] type, int count)
{
    if (!IsAnnouncerStatisticsLoggingEnabled())
    {
        return;
    }

    char clientSteamId[32], clientName[MAX_NAME_LENGTH], clientClass[16];
    char sourceSteamId[32], sourceName[MAX_NAME_LENGTH], sourceClass[16];
    GetAnnouncerLogIdentity(client, clientSteamId, sizeof(clientSteamId), clientName, sizeof(clientName), clientClass, sizeof(clientClass));
    GetAnnouncerLogIdentity(sourceClient, sourceSteamId, sizeof(sourceSteamId), sourceName, sizeof(sourceName), sourceClass, sizeof(sourceClass));

    char safeType[32];
    strcopy(safeType, sizeof(safeType), type);
    SanitizeAnnouncerLogField(safeType, sizeof(safeType));

    int userid = IsValidAnnouncerClient(client) ? GetClientUserId(client) : 0;
    int sourceUserid = IsValidAnnouncerClient(sourceClient) ? GetClientUserId(sourceClient) : 0;

    char message[PLUGIN_STATS_MESSAGE_MAX];
    Format(
        message,
        sizeof(message),
        "event=announcer_event|type=%s|client=%d|userid=%d|steamid64=%s|name=%s|class=%s|count=%d|playercount=%d|source_client=%d|source_userid=%d|source_steamid64=%s|source_name=%s|source_class=%s",
        safeType,
        client,
        userid,
        clientSteamId,
        clientName,
        clientClass,
        count,
        GetClientCount(false),
        sourceClient,
        sourceUserid,
        sourceSteamId,
        sourceName,
        sourceClass
    );
    PluginStats_LogMessage(message);
}

void GetAnnouncerLogIdentity(int client, char[] steamId, int steamLen, char[] name, int nameLen, char[] className, int classLen)
{
    strcopy(steamId, steamLen, "none");
    strcopy(name, nameLen, "none");
    strcopy(className, classLen, "unknown");

    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, steamLen, true))
    {
        strcopy(steamId, steamLen, "unknown");
    }

    if (!GetClientName(client, name, nameLen) || name[0] == '\0')
    {
        strcopy(name, nameLen, "unknown");
    }

    if (IsClientInGame(client))
    {
        GetClientClassName(client, className, classLen);
    }

    SanitizeAnnouncerLogField(steamId, steamLen);
    SanitizeAnnouncerLogField(name, nameLen);
    SanitizeAnnouncerLogField(className, classLen);
}

void SanitizeAnnouncerLogField(char[] value, int maxlen)
{
    ReplaceString(value, maxlen, "|", "/", false);
    ReplaceString(value, maxlen, "\r", " ", false);
    ReplaceString(value, maxlen, "\n", " ", false);
    ReplaceString(value, maxlen, "\t", " ", false);
    ReplaceString(value, maxlen, "\"", "'", false);
}

void LogMultikillEvent(int client, int kills, const char[] label)
{
    if (!IsAnnouncerMultikillFileLoggingEnabled())
    {
        return;
    }

    char timestamp[32], clientName[MAX_NAME_LENGTH], className[16], path[PLATFORM_MAX_PATH];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", GetTime());
    GetClientName(client, clientName, sizeof(clientName));
    GetClientClassName(client, className, sizeof(className));
    BuildPath(Path_SM, path, sizeof(path), MULTIKILL_LOG_FILE);

    File file = OpenFile(path, "a");
    if (file == null)
    {
        LogError("[Announcers] Failed to open multikill log file: %s", path);
        return;
    }

    file.WriteLine("[%s] %s got a %s (%d) class=%s", timestamp, clientName, label, kills, className);
    delete file;
}

void GetClientClassName(int client, char[] buffer, int maxlen)
{
    switch (TF2_GetPlayerClass(client))
    {
        case TFClass_Scout:     strcopy(buffer, maxlen, "scout");
        case TFClass_Soldier:   strcopy(buffer, maxlen, "soldier");
        case TFClass_Pyro:      strcopy(buffer, maxlen, "pyro");
        case TFClass_DemoMan:   strcopy(buffer, maxlen, "demoman");
        case TFClass_Heavy:     strcopy(buffer, maxlen, "heavy");
        case TFClass_Engineer:  strcopy(buffer, maxlen, "engineer");
        case TFClass_Medic:     strcopy(buffer, maxlen, "medic");
        case TFClass_Sniper:    strcopy(buffer, maxlen, "sniper");
        case TFClass_Spy:       strcopy(buffer, maxlen, "spy");
        default:                strcopy(buffer, maxlen, "unknown");
    }
}

bool Announcer_ServerCapacityCheck()
{
    float capacityRatio = 0.50;
    if (g_cvPlayercountThreshold != null)
    {
        capacityRatio = g_cvPlayercountThreshold.FloatValue;
    }

    return GetFeatureStatus(FeatureType_Native, DGM_CAPACITY_NATIVE) == FeatureStatus_Available
        && DGM_ServerCapacitycheck(capacityRatio);
}

bool IsHumanAnnouncerClient(int client)
{
    return IsValidAnnouncerClient(client) && !IsFakeClient(client);
}

bool IsValidAnnouncerClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientConnected(client);
}
