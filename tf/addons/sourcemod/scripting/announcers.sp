#pragma semicolon 1

#include <sourcemod>

#pragma newdecls required

#define WHALE_KILLSTREAK_BONUS_INTERVAL 5
#define WHALE_MULTIKILL_MIN_LEVEL 2
#define WHALE_MULTIKILL_MAX_LEVEL 5
#define MULTIKILL_LOG_FILE "logs/announcers_multikill.log"

native bool SaySounds_PlayCommand(int client, const char[] commandName, bool ignoreOptIn = false);
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50);

public Plugin myinfo =
{
    name = "Announcers",
    author = "Kogasatopia",
    description = "Announcement handlers for shared gameplay events.",
    version = "1.0.0",
    url = ""
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("SaySounds_PlayCommand");
    MarkNativeAsOptional("DGM_ServerCapacitycheck");
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

    // Placeholder for future killstreak-end announcements.
}

public void WhaleTracker_OnMultikill(int client, int kills)
{
    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    AnnounceMultikill(client, kills);
}

void AnnounceKillstreakMilestone(int client, const char[] clientName, int killstreak, bool playSound = true)
{
    if (killstreak < WHALE_KILLSTREAK_BONUS_INTERVAL || killstreak % WHALE_KILLSTREAK_BONUS_INTERVAL != 0)
        return;

    char label[32];
    char commandName[32];

    if (killstreak >= 30)
    {
        strcopy(label, sizeof(label), "GODLIKE");
        strcopy(commandName, sizeof(commandName), "holyshit");
    }
    else if (killstreak >= 25)
    {
        strcopy(label, sizeof(label), "godlike");
        strcopy(commandName, sizeof(commandName), "godlike");
    }
    else if (killstreak >= 20)
    {
        strcopy(label, sizeof(label), "unstoppable");
        strcopy(commandName, sizeof(commandName), "unstoppable");
    }
    else if (killstreak >= 15)
    {
        strcopy(label, sizeof(label), "dominating");
        strcopy(commandName, sizeof(commandName), "dominating");
    }
    else if (killstreak >= 10)
    {
        strcopy(label, sizeof(label), "on a rampage");
        strcopy(commandName, sizeof(commandName), "rampage");
    }
    else
    {
        strcopy(label, sizeof(label), "on a killing spree");
        strcopy(commandName, sizeof(commandName), "killingspree");
    }

    if (killstreak == WHALE_KILLSTREAK_BONUS_INTERVAL && Announcer_ServerCapacityCheck())
    {
        if (!IsValidAnnouncerClient(client) || IsFakeClient(client))
        {
            return;
        }

        if (playSound && LibraryExists("saysounds"))
        {
            if (!SaySounds_PlayCommand(client, commandName, false))
            {
                return;
            }
        }

        PrintCenterText(client, "%s is %s! (%d)", clientName, label, killstreak);
        return;
    }

    if (playSound && LibraryExists("saysounds"))
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidAnnouncerClient(i) || IsFakeClient(i))
            {
                continue;
            }

            if (!SaySounds_PlayCommand(i, commandName, false))
            {
                continue;
            }

            PrintCenterText(i, "%s is %s! (%d)", clientName, label, killstreak);
        }
        return;
    }

    PrintCenterTextAll("%s is %s! (%d)", clientName, label, killstreak);
}

void AnnounceMultikill(int client, int kills, bool playSound = true)
{
    if (kills < WHALE_MULTIKILL_MIN_LEVEL || kills > WHALE_MULTIKILL_MAX_LEVEL)
    {
        return;
    }

    if (!IsValidAnnouncerClient(client))
    {
        return;
    }

    LogMultikillEvent(client, kills);

    if (kills == WHALE_MULTIKILL_MIN_LEVEL && !Announcer_ServerCapacityCheck())
    {
        return;
    }

    if (playSound && LibraryExists("saysounds"))
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidAnnouncerClient(i) || IsFakeClient(i))
            {
                continue;
            }

            // SaySounds_PlayCommand(i, "placeholder", false);
            // PrintCenterText(i, "placeholder");
        }

        return;
    }

    // PrintCenterTextAll("placeholder");
}

bool GetMultikillLabel(int kills, char[] label, int labelLen)
{
    switch (kills)
    {
        case 2:
        {
            strcopy(label, labelLen, "double-kill");
            return true;
        }
        case 3:
        {
            strcopy(label, labelLen, "triple-kill");
            return true;
        }
        case 4:
        {
            strcopy(label, labelLen, "quadra-kill");
            return true;
        }
        case 5:
        {
            strcopy(label, labelLen, "penta-kill");
            return true;
        }
    }

    return false;
}

void LogMultikillEvent(int client, int kills)
{
    char label[32];
    if (!GetMultikillLabel(kills, label, sizeof(label)))
    {
        return;
    }

    char timestamp[32];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", GetTime());

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));

    char path[PLATFORM_MAX_PATH];
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
    if (GetFeatureStatus(FeatureType_Native, "DGM_ServerCapacitycheck") != FeatureStatus_Available)
    {
        return false;
    }

    return DGM_ServerCapacitycheck(capacityRatio);
}

bool IsValidAnnouncerClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientConnected(client);
}
