#pragma semicolon 1
#include <sourcemod>
#include <morecolors>
#include <textparse>
#pragma newdecls required

#define WHALE_KILLSTREAK_BONUS_INTERVAL 5
#define WHALE_MULTIKILL_MIN_LEVEL 2
#define WHALE_MULTIKILL_MAX_LEVEL 5
#define ANNOUNCER_CONFIG_FILE "configs/announcers.cfg"
#define ANNOUNCER_MAX_COMMAND_NAME 64
#define MULTIKILL_LOG_FILE "logs/announcers_multikill.log"
#define ANNOUNCER_SOUND_LIBRARY "saysounds"
#define ANNOUNCER_SOUND_NATIVE "SaySounds_PlayCommand"
#define DGM_CAPACITY_NATIVE "DGM_ServerCapacitycheck"
#define WHALETRACKER_BONUS_NATIVE "WhaleTracker_ApplyBonusPoints"

native bool SaySounds_PlayCommand(int client, const char[] commandName, bool ignoreOptIn = false);
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50);
native bool Filters_GetChatName(int client, char[] buffer, int maxlen);
native bool WhaleTracker_ApplyBonusPoints(int client, int points, bool playSound, bool chatAlert, float randomChance, const char[] type, int target = 0, float delay = 3.0);

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
    "double-kill", "triple-kill", "quadra-kill", "penta-kill"
};

enum AnnouncerConfigMode
{
    AnnouncerConfig_None = 0,
    AnnouncerConfig_Killstreaks,
    AnnouncerConfig_Multikills,
    AnnouncerConfig_Shutdown
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
StringMap g_KillstreakSoundMap = null;
StringMap g_MultikillSoundMap = null;
ArrayList g_ShutdownSoundCommands = null;
AnnouncerConfigMode g_ConfigMode = AnnouncerConfig_None;
int g_ConfigDepth = 0;
int g_ConfigLevel = 0;
Handle g_hMultikillRollupTimer[MAXPLAYERS + 1];
int g_iPendingMultikillKills[MAXPLAYERS + 1];
int g_iPendingMultikillUserId[MAXPLAYERS + 1];
int g_iPendingMultikillSerial[MAXPLAYERS + 1];

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
    g_ShutdownSoundCommands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));

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
        "0",
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
        "0",
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
        "1.0",
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
    ClearShutdownSoundCommands();

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

    if (g_ShutdownSoundCommands != null)
    {
        delete g_ShutdownSoundCommands;
        g_ShutdownSoundCommands = null;
    }
}

public void OnMapEnd()
{
    ClearAllMultikillRollups();
}

public void OnClientDisconnect(int client)
{
    ClearMultikillRollup(client);
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional(ANNOUNCER_SOUND_NATIVE);
    MarkNativeAsOptional(DGM_CAPACITY_NATIVE);
    MarkNativeAsOptional(WHALETRACKER_BONUS_NATIVE);
    MarkNativeAsOptional("Filters_GetChatName");
    return APLRes_Success;
}

public void WhaleTracker_OnKillstreak(int client, int killstreak)
{
    if (!g_cvKillstreaksEnabled.BoolValue)
    {
        return;
    }

    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    AnnounceKillstreakMilestone(client, clientName, killstreak);
}

public void WhaleTracker_OnKillstreakEnd(int client, int killstreak)
{
    if (!g_cvKillstreaksEnabled.BoolValue)
    {
        return;
    }

    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    AnnounceKillstreakEnd(client, killstreak);
}

public void WhaleTracker_OnMultikill(int client, int kills)
{
    QueueMultikillRollup(client, kills);
}

void AnnounceKillstreakMilestone(int client, const char[] clientName, int killstreak, bool playSound = true)
{
    char label[32], commandName[32];
    if (!GetKillstreakAnnouncement(killstreak, label, sizeof(label), commandName, sizeof(commandName)))
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
    if (!GetShutdownSoundCommand(commandName, sizeof(commandName)))
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
            SaySounds_PlayCommand(client, commandName, false);
        }
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsHumanAnnouncerClient(i))
        {
            SaySounds_PlayCommand(i, commandName, false);
        }
    }
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
    Format(message, sizeof(message), "%s got a %s! (%d)", clientName, label, kills);

    char commandName[ANNOUNCER_MAX_COMMAND_NAME];
    GetAnnouncerSoundCommand(g_MultikillSoundMap, kills, "", commandName, sizeof(commandName));

    bool useSound = g_cvMultikillsSound.BoolValue && commandName[0] != '\0';
    Announcer_Announce(broadcastToAll ? 0 : client, client, commandName, Announcer_ShouldPlaySound(useSound), g_cvMultikillsChat.BoolValue, message);
}

void AwardMultikillBonusPoints(int client, int kills)
{
    if (kills < 3)
    {
        return;
    }

    if (GetFeatureStatus(FeatureType_Native, WHALETRACKER_BONUS_NATIVE) != FeatureStatus_Available)
    {
        return;
    }

    WhaleTracker_ApplyBonusPoints(client, 1, true, true, 1.0, "multikill", kills, 3.0);
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

bool GetKillstreakAnnouncement(int killstreak, char[] label, int labelLen, char[] commandName, int commandLen)
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

    strcopy(label, labelLen, g_KillstreakLabels[index]);
    strcopy(commandName, commandLen, g_KillstreakCommands[index]);
    GetAnnouncerSoundCommand(g_KillstreakSoundMap, killstreak, commandName, commandName, commandLen);
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

void Announcer_CenterText(int target, const char[] commandName, bool useSound, const char[] message)
{
    if (target > 0)
    {
        if (IsHumanAnnouncerClient(target) && (!useSound || SaySounds_PlayCommand(target, commandName, false)))
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
        Announcer_CenterText(i, commandName, true, message);
    }
}

void Announcer_Announce(int target, int author, const char[] commandName, bool useSound, bool useChat, const char[] message)
{
    if (!useChat)
    {
        Announcer_CenterText(target, commandName, useSound, message);
        return;
    }

    if (target > 0)
    {
        if (IsHumanAnnouncerClient(target) && (!useSound || SaySounds_PlayCommand(target, commandName, false)))
        {
            Announcer_MessageClient(target, author, message);
        }
        return;
    }

    if (useSound)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsHumanAnnouncerClient(i))
            {
                SaySounds_PlayCommand(i, commandName, false);
            }
        }
    }

    Announcer_MessageAll(author, true, message);
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
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_NATIVE) == FeatureStatus_Available;
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
    if (g_ShutdownSoundCommands == null)
    {
        g_ShutdownSoundCommands = new ArrayList(ByteCountToCells(ANNOUNCER_MAX_COMMAND_NAME));
    }

    ClearSoundMap(g_KillstreakSoundMap);
    ClearSoundMap(g_MultikillSoundMap);
    ClearShutdownSoundCommands();

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
        if (g_ConfigDepth != 2)
        {
            return SMCParse_Continue;
        }

        char commandName[ANNOUNCER_MAX_COMMAND_NAME];
        GetConfigCommandName(key, value, commandName, sizeof(commandName));
        if (commandName[0])
        {
            AddShutdownSoundCommand(commandName);
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

void AddShutdownSoundCommand(const char[] commandName)
{
    if (g_ShutdownSoundCommands == null || !commandName[0])
    {
        return;
    }

    g_ShutdownSoundCommands.PushString(commandName);
}

bool GetAnnouncerSoundCommand(StringMap map, int level, const char[] fallbackCommand, char[] commandName, int commandLen)
{
    strcopy(commandName, commandLen, fallbackCommand);

    if (map == null)
    {
        return commandName[0] != '\0';
    }

    char levelKey[16];
    IntToString(level, levelKey, sizeof(levelKey));

    any listValue;
    if (!map.GetValue(levelKey, listValue))
    {
        return commandName[0] != '\0';
    }

    ArrayList commands = view_as<ArrayList>(listValue);
    if (commands == null || commands.Length <= 0)
    {
        return commandName[0] != '\0';
    }

    commands.GetString(GetRandomInt(0, commands.Length - 1), commandName, commandLen);
    return commandName[0] != '\0';
}

bool GetShutdownSoundCommand(char[] commandName, int commandLen)
{
    commandName[0] = '\0';

    if (g_ShutdownSoundCommands == null || g_ShutdownSoundCommands.Length <= 0)
    {
        return false;
    }

    g_ShutdownSoundCommands.GetString(GetRandomInt(0, g_ShutdownSoundCommands.Length - 1), commandName, commandLen);
    return commandName[0] != '\0';
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

void ClearShutdownSoundCommands()
{
    if (g_ShutdownSoundCommands != null)
    {
        g_ShutdownSoundCommands.Clear();
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

void LogMultikillEvent(int client, int kills, const char[] label)
{
    char timestamp[32], clientName[MAX_NAME_LENGTH], path[PLATFORM_MAX_PATH];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", GetTime());
    GetClientName(client, clientName, sizeof(clientName));
    BuildPath(Path_SM, path, sizeof(path), MULTIKILL_LOG_FILE);

    File file = OpenFile(path, "a");
    if (file == null)
    {
        LogError("[Announcers] Failed to open multikill log file: %s", path);
        return;
    }

    file.WriteLine("[%s] %s got a %s (%d)", timestamp, clientName, label, kills);
    delete file;
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
