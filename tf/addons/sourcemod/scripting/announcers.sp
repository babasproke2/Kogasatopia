#pragma semicolon 1
#include <sourcemod>
#include <morecolors>
#pragma newdecls required

#define WHALE_KILLSTREAK_BONUS_INTERVAL 5
#define WHALE_MULTIKILL_MIN_LEVEL 2
#define WHALE_MULTIKILL_MAX_LEVEL 5
#define MULTIKILL_LOG_FILE "logs/announcers_multikill.log"
#define ANNOUNCER_SOUND_LIBRARY "saysounds"
#define ANNOUNCER_SOUND_NATIVE "SaySounds_PlayCommand"
#define DGM_CAPACITY_NATIVE "DGM_ServerCapacitycheck"

native bool SaySounds_PlayCommand(int client, const char[] commandName, bool ignoreOptIn = false);
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50);

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

ConVar g_cvMultikillsChat = null;

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
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional(ANNOUNCER_SOUND_NATIVE);
    MarkNativeAsOptional(DGM_CAPACITY_NATIVE);
    return APLRes_Success;
}

public void WhaleTracker_OnKillstreak(int client, int killstreak)
{
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
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    // Reserved for future killstreak-end announcements.
}

public void WhaleTracker_OnMultikill(int client, int kills)
{
    AnnounceMultikill(client, kills);
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
    if (killstreak == WHALE_KILLSTREAK_BONUS_INTERVAL && Announcer_ServerCapacityCheck())
    {
        target = client;
    }

    Announcer_CenterText(target, commandName, Announcer_ShouldPlaySound(playSound), message);
}

void AnnounceMultikill(int client, int kills)
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
    if (kills == WHALE_MULTIKILL_MIN_LEVEL && !Announcer_ServerCapacityCheck())
    {
        return;
    }

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));

    char message[128];
    Format(message, sizeof(message), "%s got a %s! (%d)", clientName, label, kills);

    Announcer_MessageAll(client, g_cvMultikillsChat.BoolValue, message);
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

void Announcer_MessageAll(int author, bool useChat, const char[] message)
{
    if (useChat)
    {
        if (IsValidAnnouncerClient(author) && IsClientInGame(author))
        {
            CPrintToChatAllEx(author, "{green}[Announcers]{default} %s", message);
        }
        else
        {
            CPrintToChatAll("{green}[Announcers]{default} %s", message);
        }
        return;
    }

    PrintCenterTextAll("%s", message);
}

bool Announcer_ShouldPlaySound(bool playSound)
{
    return playSound
        && LibraryExists(ANNOUNCER_SOUND_LIBRARY)
        && GetFeatureStatus(FeatureType_Native, ANNOUNCER_SOUND_NATIVE) == FeatureStatus_Available;
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

bool Announcer_ServerCapacityCheck(float capacityRatio = 0.50)
{
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
