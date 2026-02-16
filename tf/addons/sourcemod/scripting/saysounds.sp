#pragma semicolon 1

#include <sourcemod>
#include <clientprefs>
#include <sdktools_sound>
#include <textparse>
#include <tf_custom_attributes>

#define CONFIG_FILE "configs/saysounds.cfg"
#define MAX_COMMAND_NAME 64
#define MAX_GROUP_NAME 32
#define DEFAULT_GROUP "all"
#define DEFAULT_DEATH_COMMAND "doh"
#define TOUHOU_DEATH_SOUND_ATTR "touhou death sound"
#define TOUHOU_DEATH_SOUND_PATH "touhou/pichuun.mp3"
#define TOUHOU_DEATH_SOUND_FORCE_VOLUME 0.5

public Plugin myinfo =
{
    name = "saysounds",
    author = "Hombre",
    description = "Chat-triggered say sounds with opt-out and volume features",
    version = "2.0.1",
    url = "https://kogasa.tf"
};

StringMap gSoundMap;
StringMap gSoundGroupMap;
ArrayList gCommandNames;
ArrayList gGroupNames;
bool gConfigLoaded = false;
float g_fClientVolume[MAXPLAYERS + 1];
float g_fNextAllowedSound[MAXPLAYERS + 1];
char g_szDeathSound[MAXPLAYERS + 1][MAX_COMMAND_NAME * 4];
char g_szKillSound[MAXPLAYERS + 1][MAX_COMMAND_NAME * 4];
char g_szClientGroup[MAXPLAYERS + 1][MAX_GROUP_NAME];
Handle g_hVolumeCookie = INVALID_HANDLE;
Handle g_hDeathCookie = INVALID_HANDLE;
Handle g_hKillCookie = INVALID_HANDLE;
Handle g_hGroupCookie = INVALID_HANDLE;
ConVar g_hForce;

const float DEFAULT_VOLUME = 0.5;
const float MIN_VOLUME = 0.0;
const float MAX_VOLUME = 1.0;
const float DEFAULT_COOLDOWN = 5.0;
const float ADMIN_COOLDOWN = 1.0;
const int MAX_SOUND_OPTIONS = 16;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
    RegPluginLibrary("saysounds");
    CreateNative("SaySounds_ShouldPlay", Native_ShouldPlay);
    CreateNative("SaySounds_PlaySoundToOptedIn", Native_PlaySoundToOptedIn);
    return APLRes_Success;
}

public void OnAllPluginsLoaded() {}
public void OnLibraryAdded(const char[] name) {}
public void OnLibraryRemoved(const char[] name) {}

public void OnPluginStart()
{
    gSoundMap = new StringMap();
    gSoundGroupMap = new StringMap();
    gCommandNames = new ArrayList(ByteCountToCells(MAX_COMMAND_NAME));
    gGroupNames = new ArrayList(ByteCountToCells(MAX_GROUP_NAME));

    g_hForce = CreateConVar("saysounds_force", "0", "Force everyone to hear saysounds");
    g_hVolumeCookie = RegClientCookie("saysounds_volume", "Preferred say sound volume", CookieAccess_Public);
    g_hDeathCookie = RegClientCookie("saysounds_death", "Preferred saysound on death", CookieAccess_Public);
    g_hKillCookie = RegClientCookie("saysounds_kill", "Preferred saysound on kill", CookieAccess_Public);
    g_hGroupCookie = RegClientCookie("saysounds_group", "Preferred saysound group", CookieAccess_Public);

    RegConsoleCmd("sm_opt", Command_ToggleSoundOpt);
    RegConsoleCmd("sm_sounds", Command_ListSounds);
    RegConsoleCmd("sm_vol", Command_SetVolume);
    RegConsoleCmd("sm_diesound", Command_SetDeathSound);
    RegConsoleCmd("sm_deathsound", Command_SetDeathSound);
    RegConsoleCmd("sm_killsound", Command_SetKillSound);
    RegConsoleCmd("sm_saysound", Command_PlaySpecificSound);

    LoadSaySoundConfig();

    AddCommandListener(ChatCommandListener, "say");
    AddCommandListener(ChatCommandListener, "say_team");
    HookEvent("player_death", Event_PlayerDeathPost, EventHookMode_Post);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_fClientVolume[i] = DEFAULT_VOLUME;
        g_fNextAllowedSound[i] = 0.0;
        g_szDeathSound[i][0] = '\0';
        g_szKillSound[i][0] = '\0';
        strcopy(g_szClientGroup[i], sizeof(g_szClientGroup[]), DEFAULT_GROUP);

        if (IsClientInGame(i) && AreClientCookiesCached(i))
        {
            LoadVolumePreference(i);
            LoadDeathSoundPreference(i);
            LoadKillSoundPreference(i);
            LoadGroupPreference(i);
        }
    }
}

public void OnPluginEnd()
{
    if (gSoundMap != null)
    {
        delete gSoundMap;
        gSoundMap = null;
    }

    if (gSoundGroupMap != null)
    {
        delete gSoundGroupMap;
        gSoundGroupMap = null;
    }

    if (gCommandNames != null)
    {
        delete gCommandNames;
        gCommandNames = null;
    }

    if (gGroupNames != null)
    {
        delete gGroupNames;
        gGroupNames = null;
    }
}

public void OnClientPutInServer(int client)
{
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_fNextAllowedSound[client] = 0.0;
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';
    strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);

    if (AreClientCookiesCached(client))
    {
        LoadVolumePreference(client);
        LoadDeathSoundPreference(client);
        LoadKillSoundPreference(client);
        LoadGroupPreference(client);
    }
}

public void OnClientCookiesCached(int client)
{
    LoadVolumePreference(client);
    LoadDeathSoundPreference(client);
    LoadKillSoundPreference(client);
    LoadGroupPreference(client);
}

public void OnClientDisconnect(int client)
{
    SaveVolumePreference(client);
    SaveDeathSoundPreference(client);
    SaveKillSoundPreference(client);
    SaveGroupPreference(client);
    g_fNextAllowedSound[client] = 0.0;
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';
    strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);
}

public void OnConfigsExecuted()
{
    LoadSaySoundConfig();
    PrecacheConfiguredSounds();
}

public void OnMapStart()
{
    PrecacheConfiguredSounds();
}

Action ChatCommandListener(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    char message[256];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);
    TrimString(message);

    if (message[0] != '!' || !gConfigLoaded)
    {
        return Plugin_Continue;
    }

    char payload[256];
    strcopy(payload, sizeof(payload), message);
    ShiftStringLeft(payload, sizeof(payload), 1);
    TrimString(payload);

    if (!payload[0])
    {
        return Plugin_Continue;
    }

    char commandName[MAX_COMMAND_NAME];
    char args[256];

    strcopy(commandName, sizeof(commandName), payload);
    int spaceIndex = FindCharInString(commandName, ' ');
    if (spaceIndex != -1)
    {
        commandName[spaceIndex] = '\0';

        strcopy(args, sizeof(args), payload);
        ShiftStringLeft(args, sizeof(args), spaceIndex + 1);
        TrimString(args);
    }
    else
    {
        args[0] = '\0';
    }

    ToLowercaseInPlace(commandName, sizeof(commandName));

    if (!commandName[0])
    {
        return Plugin_Continue;
    }

    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    if (!GetCommandSoundData(commandName, soundPath, sizeof(soundPath), groupName, sizeof(groupName)))
    {
        return Plugin_Continue;
    }

    int initiator = (client > 0 && client <= MaxClients) ? client : -1;
    float now = GetGameTime();

    if (initiator != -1)
    {
        if (g_fNextAllowedSound[initiator] > now)
        {
            float remaining = g_fNextAllowedSound[initiator] - now;
            PrintToChat(initiator, "[SaySounds] Please wait %.1f seconds before triggering another sound.", remaining);
            return Plugin_Handled;
        }

		if(CheckCommandAccess(client, "sm_admin", ADMFLAG_ROOT, true))
			g_fNextAllowedSound[initiator] = now + ADMIN_COOLDOWN;
		else
			g_fNextAllowedSound[initiator] = now + DEFAULT_COOLDOWN;
        
    }

    PlaySaySound(soundPath, groupName);

    return Plugin_Continue;
}

void LoadSaySoundConfig()
{
    gSoundMap.Clear();
    gSoundGroupMap.Clear();
    gCommandNames.Clear();
    gGroupNames.Clear();
    gConfigLoaded = false;
    EnsureGroupRegistered(DEFAULT_GROUP);

    char filePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filePath, sizeof(filePath), CONFIG_FILE);

    if (!FileExists(filePath))
    {
        LogError("[SaySounds] Config file not found: %s", filePath);
        return;
    }

    SMCParser parser = new SMCParser();
    parser.OnKeyValue = Config_KeyValue;

    int errorLine, errorColumn;
    SMCError result = parser.ParseFile(filePath, errorLine, errorColumn);

    if (result != SMCError_Okay)
    {
        char error[256];
        parser.GetErrorString(result, error, sizeof(error));
        LogError("[SaySounds] Failed to parse config: %s (line %d, column %d)", error, errorLine, errorColumn);
        delete parser;
        gSoundMap.Clear();
        gCommandNames.Clear();
        return;
    }

    delete parser;

    if (gCommandNames.Length == 0)
    {
        LogError("[SaySounds] No command entries found in config.");
        return;
    }

    gConfigLoaded = true;
}

public SMCResult Config_KeyValue(SMCParser parser, const char[] key, const char[] value, bool keyQuoted, bool valueQuoted)
{
    char commandName[MAX_COMMAND_NAME];
    strcopy(commandName, sizeof(commandName), key);
    TrimString(commandName);

    if (!commandName[0])
    {
        return SMCParse_Continue;
    }

    if (commandName[0] == '!' || commandName[0] == '/')
    {
        ShiftStringLeft(commandName, sizeof(commandName), 1);
    }

    ToLowercaseInPlace(commandName, sizeof(commandName));

    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    ParseSoundConfigEntry(value, soundPath, sizeof(soundPath), groupName, sizeof(groupName));

    if (!soundPath[0])
    {
        LogError("[SaySounds] Command '%s' has an empty sound path.", commandName);
        return SMCParse_Continue;
    }

    if (!groupName[0])
    {
        strcopy(groupName, sizeof(groupName), DEFAULT_GROUP);
    }

    EnsureGroupRegistered(groupName);

    int existingIndex = FindCommandIndex(commandName);
    if (existingIndex == -1)
    {
        gCommandNames.PushString(commandName);
    }

    gSoundMap.SetString(commandName, soundPath);
    gSoundGroupMap.SetString(commandName, groupName);
    return SMCParse_Continue;
}

void PrecacheConfiguredSounds()
{
    if (!gConfigLoaded)
    {
        return;
    }

    char commandName[MAX_COMMAND_NAME];
    char soundPath[PLATFORM_MAX_PATH];

    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, commandName, sizeof(commandName));
        if (!gSoundMap.GetString(commandName, soundPath, sizeof(soundPath)))
        {
            continue;
        }

        PrecacheSound(soundPath, true);
    }
}

int FindCommandIndex(const char[] commandName)
{
    char current[MAX_COMMAND_NAME];
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, current, sizeof(current));
        if (StrEqual(current, commandName))
        {
            return i;
        }
    }

    return -1;
}

void ToLowercaseInPlace(char[] buffer, int maxlen)
{
    for (int i = 0; i < maxlen && buffer[i] != '\0'; i++)
    {
        buffer[i] = CharToLower(buffer[i]);
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

void NormalizeSoundPath(char[] soundPath, int maxlen)
{
    ReplaceString(soundPath, maxlen, "\\", "/");

    while (soundPath[0] == '/')
    {
        ShiftStringLeft(soundPath, maxlen, 1);
    }

    if (StartsWith(soundPath, "sound/"))
    {
        ShiftStringLeft(soundPath, maxlen, 6);
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

static void CopySubstring(const char[] source, int startIndex, char[] dest, int destLen)
{
    if (destLen <= 0)
    {
        return;
    }

    int length = strlen(source);
    if (startIndex >= length)
    {
        dest[0] = '\0';
        return;
    }

    int written = 0;
    for (int i = startIndex; i < length && written < destLen - 1; i++)
    {
        dest[written++] = source[i];
    }

    dest[written] = '\0';
}

static void ParseSoundConfigEntry(const char[] value, char[] soundPath, int soundLen, char[] groupName, int groupLen)
{
    if (soundLen > 0)
    {
        soundPath[0] = '\0';
    }
    if (groupLen > 0)
    {
        groupName[0] = '\0';
    }

    char raw[PLATFORM_MAX_PATH];
    strcopy(raw, sizeof(raw), value);
    TrimString(raw);

    if (!raw[0])
    {
        return;
    }

    int delim = FindCharInString(raw, '|');
    if (delim != -1)
    {
        char groupPart[MAX_GROUP_NAME];
        strcopy(groupPart, sizeof(groupPart), raw);
        groupPart[delim] = '\0';
        TrimString(groupPart);
        ToLowercaseInPlace(groupPart, sizeof(groupPart));

        char pathPart[PLATFORM_MAX_PATH];
        CopySubstring(raw, delim + 1, pathPart, sizeof(pathPart));
        TrimString(pathPart);

        if (groupLen > 0)
        {
            strcopy(groupName, groupLen, groupPart);
        }

        strcopy(soundPath, soundLen, pathPart);
    }
    else
    {
        strcopy(soundPath, soundLen, raw);
    }

    NormalizeSoundPath(soundPath, soundLen);
}

static int FindGroupIndex(const char[] groupName)
{
    if (gGroupNames == null)
    {
        return -1;
    }

    char current[MAX_GROUP_NAME];
    for (int i = 0; i < gGroupNames.Length; i++)
    {
        gGroupNames.GetString(i, current, sizeof(current));
        if (StrEqual(current, groupName))
        {
            return i;
        }
    }

    return -1;
}

static void EnsureGroupRegistered(const char[] groupName)
{
    if (gGroupNames == null)
    {
        return;
    }

    char normalized[MAX_GROUP_NAME];
    strcopy(normalized, sizeof(normalized), groupName);
    TrimString(normalized);
    ToLowercaseInPlace(normalized, sizeof(normalized));

    if (!normalized[0])
    {
        return;
    }

    if (FindGroupIndex(normalized) != -1)
    {
        return;
    }

    gGroupNames.PushString(normalized);
}

static bool IsKnownGroup(const char[] groupName)
{
    if (!groupName[0])
    {
        return false;
    }

    char normalized[MAX_GROUP_NAME];
    strcopy(normalized, sizeof(normalized), groupName);
    TrimString(normalized);
    ToLowercaseInPlace(normalized, sizeof(normalized));

    if (!normalized[0])
    {
        return false;
    }

    if (StrEqual(normalized, DEFAULT_GROUP))
    {
        return true;
    }

    return FindGroupIndex(normalized) != -1;
}

public Action Command_ToggleSoundOpt(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (args >= 1)
    {
        char arg[MAX_GROUP_NAME];
        GetCmdArg(1, arg, sizeof(arg));
        TrimString(arg);
        ToLowercaseInPlace(arg, sizeof(arg));

        if (StrEqual(arg, "off") || StrEqual(arg, "mute") || StrEqual(arg, "none"))
        {
            g_fClientVolume[client] = 0.0;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds muted.");
            return Plugin_Handled;
        }

        if (StrEqual(arg, "on"))
        {
            strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);
            SaveGroupPreference(client);
            g_fClientVolume[client] = DEFAULT_VOLUME;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
            return Plugin_Handled;
        }

        if (StrEqual(arg, DEFAULT_GROUP))
        {
            strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);
            SaveGroupPreference(client);
            g_fClientVolume[client] = DEFAULT_VOLUME;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
            return Plugin_Handled;
        }

        if (!arg[0] || !IsKnownGroup(arg))
        {
            PrintToChat(client, "[SaySounds] Unknown sound group.");
            return Plugin_Handled;
        }

        strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), arg);
        SaveGroupPreference(client);
        g_fClientVolume[client] = DEFAULT_VOLUME;
        SaveVolumePreference(client);
        PrintToChat(client, "[SaySounds] You're now only able to hear sound group \x03%s", arg);
    }
    else
    {
        if (GetClientVolume(client) > 0.0)
        {
            g_fClientVolume[client] = 0.0;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds muted.");
        }
        else
        {
            // No arguments and muted: enable all groups at default volume
            strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);
            SaveGroupPreference(client);
            g_fClientVolume[client] = DEFAULT_VOLUME;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
        }
    }

    return Plugin_Handled;
}

public Action Command_ListSounds(int client, int args)
{
    if (client <= 0)
    {
        for (int i = 0; i < gCommandNames.Length; i++)
        {
            char command[MAX_COMMAND_NAME];
            char sound[PLATFORM_MAX_PATH];
            char group[MAX_GROUP_NAME];
            gCommandNames.GetString(i, command, sizeof(command));
            if (!gSoundMap.GetString(command, sound, sizeof(sound)))
                continue;
            if (!gSoundGroupMap.GetString(command, group, sizeof(group)))
                strcopy(group, sizeof(group), DEFAULT_GROUP);
            PrintToServer("[SaySounds] !%s -> %s [%s]", command, sound, group);
        }
        return Plugin_Handled;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    PrintToChat(client, "[SaySounds] Available commands:");
    PrintToChat(client, "[SaySounds] (Use !opt to toggle sound playback; !vol <0.0-1.0> for custom volume)");
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        char command[MAX_COMMAND_NAME];
        char sound[PLATFORM_MAX_PATH];
        char group[MAX_GROUP_NAME];
        gCommandNames.GetString(i, command, sizeof(command));
        if (!gSoundMap.GetString(command, sound, sizeof(sound)))
            continue;
        if (!gSoundGroupMap.GetString(command, group, sizeof(group)))
            strcopy(group, sizeof(group), DEFAULT_GROUP);
        PrintToChat(client, "!%s -> %s [%s]", command, sound, group);
    }

    return Plugin_Handled;
}

stock bool SaySounds_ShouldPlay(int client)
{
    return GetClientVolume(client) > 0.0;
}

public int Native_ShouldPlay(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return SaySounds_ShouldPlay(client);
}

public int Native_PlaySoundToOptedIn(Handle plugin, int numParams)
{
    char soundPath[PLATFORM_MAX_PATH];
    GetNativeString(1, soundPath, sizeof(soundPath));
    TrimString(soundPath);

    if (!soundPath[0])
    {
        return 0;
    }

    char groupName[MAX_GROUP_NAME];
    if (numParams >= 2)
    {
        GetNativeString(2, groupName, sizeof(groupName));
        TrimString(groupName);
        ToLowercaseInPlace(groupName, sizeof(groupName));
    }
    else
    {
        groupName[0] = '\0';
    }

    NormalizeSoundPath(soundPath, sizeof(soundPath));

    if (!groupName[0])
    {
        strcopy(groupName, sizeof(groupName), DEFAULT_GROUP);
    }

    PrecacheSound(soundPath, true);
    PlaySaySound(soundPath, groupName);
    return 0;
}

public Action Command_SetVolume(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        PrintToServer("[SaySounds] This command can only be used by players.");
        return Plugin_Handled;
    }

    // Wait for cookies to load before allowing changes
    if (GetCmdArgs() < 1)
    {
        PrintToChat(client, "[SaySounds] Usage: !vol <0.0 - 1.0> (current %.2f)", GetClientVolume(client));
        return Plugin_Handled;
    }

    char arg[16];
    GetCmdArg(1, arg, sizeof(arg));
    HandleVolumeCommand(client, arg);
    return Plugin_Handled;
}

static bool BuildSoundPreferenceList(const char[] input, char[] aggregated, int aggregatedLen, bool &anyInvalid)
{
    aggregated[0] = '\0';
    anyInvalid = false;

    if (!input[0])
    {
        return false;
    }

    char token[MAX_COMMAND_NAME];
    int len = strlen(input);
    int start = 0;
    int validCount = 0;

    while (start < len)
    {
        // Find next comma starting from current position
        int commaPos = -1;
        for (int i = start; i < len; i++)
        {
            if (input[i] == ',')
            {
                commaPos = i;
                break;
            }
        }

        int end = (commaPos == -1) ? len : commaPos;
        int tokenLen = end - start;

        if (tokenLen > 0 && tokenLen < sizeof(token))
        {
            // Extract token
            for (int i = 0; i < tokenLen; i++)
            {
                token[i] = input[start + i];
            }
            token[tokenLen] = '\0';

            TrimString(token);
            ToLowercaseInPlace(token, sizeof(token));

            if (token[0])
            {
                char path[PLATFORM_MAX_PATH];
                if (gSoundMap.GetString(token, path, sizeof(path)))
                {
                    if (validCount < MAX_SOUND_OPTIONS)
                    {
                        int currentLen = strlen(aggregated);
                        int needed = (currentLen > 0 ? 1 : 0) + strlen(token);
                        if (currentLen + needed < aggregatedLen - 1)
                        {
                            if (currentLen > 0)
                            {
                                StrCat(aggregated, aggregatedLen, ",");
                            }
                            StrCat(aggregated, aggregatedLen, token);
                            validCount++;
                        }
                        else
                        {
                            anyInvalid = true;
                        }
                    }
                    else
                    {
                        anyInvalid = true;
                    }
                }
                else
                {
                    anyInvalid = true;
                }
            }
        }

        // Move past the comma
        start = end + 1;
        
        // Safety check: if we've moved past the end, break
        if (start > len)
        {
            break;
        }
    }

    return (validCount > 0);
}

public Action Command_SetDeathSound(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!gConfigLoaded)
    {
        PrintToChat(client, "[SaySounds] Sounds are not ready yet. Try again soon.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "[SaySounds] Usage: !diesound <command[,command...]|none> (current: %s)", g_szDeathSound[client][0] ? g_szDeathSound[client] : "none");
        return Plugin_Handled;
    }

    char buffer[256];
    GetCmdArgString(buffer, sizeof(buffer));
    TrimString(buffer);
    ToLowercaseInPlace(buffer, sizeof(buffer));

    if (!buffer[0] || StrEqual(buffer, "none") || StrEqual(buffer, "off"))
    {
        g_szDeathSound[client][0] = '\0';
        SaveDeathSoundPreference(client);
        PrintToChat(client, "[SaySounds] Death sound cleared.");
        return Plugin_Handled;
    }

    char aggregated[256];
    bool anyInvalid = false;
    if (!BuildSoundPreferenceList(buffer, aggregated, sizeof(aggregated), anyInvalid))
    {
        PrintToChat(client, "[SaySounds] No valid sounds supplied. Use !sounds to list commands.");
        return Plugin_Handled;
    }

    strcopy(g_szDeathSound[client], 256, aggregated);
    SaveDeathSoundPreference(client);
    PrintToChat(client, "[SaySounds] Death sound set to %s.", aggregated);
    if (anyInvalid)
    {
        PrintToChat(client, "[SaySounds] Some sounds were unknown and ignored.");
    }
    return Plugin_Handled;
}

public Action Command_SetKillSound(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!gConfigLoaded)
    {
        PrintToChat(client, "[SaySounds] Sounds are not ready yet. Try again soon.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "[SaySounds] Usage: !killsound <command[,command...]|none> (current: %s)", g_szKillSound[client][0] ? g_szKillSound[client] : "none");
        return Plugin_Handled;
    }

    char buffer[256];
    GetCmdArgString(buffer, sizeof(buffer));
    TrimString(buffer);
    ToLowercaseInPlace(buffer, sizeof(buffer));

    if (!buffer[0] || StrEqual(buffer, "none") || StrEqual(buffer, "off"))
    {
        g_szKillSound[client][0] = '\0';
        SaveKillSoundPreference(client);
        PrintToChat(client, "[SaySounds] Kill sound cleared.");
        return Plugin_Handled;
    }

    char aggregated[256];
    bool anyInvalid = false;
    if (!BuildSoundPreferenceList(buffer, aggregated, sizeof(aggregated), anyInvalid))
    {
        PrintToChat(client, "[SaySounds] No valid sounds supplied. Use !sounds to list commands.");
        return Plugin_Handled;
    }

    strcopy(g_szKillSound[client], 256, aggregated);  // FIXED: Changed from g_szDeathSound to g_szKillSound
    SaveKillSoundPreference(client);
    PrintToChat(client, "[SaySounds] Kill sound set to %s.", aggregated);
    if (anyInvalid)
    {
        PrintToChat(client, "[SaySounds] Some sounds were unknown and ignored.");
    }
    return Plugin_Handled;
}

public Action Command_PlaySpecificSound(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    if (!gConfigLoaded)
    {
        PrintToChat(client, "[SaySounds] Sounds are not ready yet. Try again soon.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "[SaySounds] Usage: !saysound <command>");
        return Plugin_Handled;
    }

    char arg[MAX_COMMAND_NAME];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);
    ToLowercaseInPlace(arg, sizeof(arg));

    if (!arg[0])
    {
        PrintToChat(client, "[SaySounds] Usage: !saysound <command>");
        return Plugin_Handled;
    }

    char path[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    if (!GetCommandSoundData(arg, path, sizeof(path), groupName, sizeof(groupName)))
    {
        PrintToChat(client, "[SaySounds] Unknown sound '%s'. Use !sounds to list commands.", arg);
        return Plugin_Handled;
    }

    float now = GetGameTime();
    if (g_fNextAllowedSound[client] > now)
    {
        float remaining = g_fNextAllowedSound[client] - now;
        PrintToChat(client, "[SaySounds] Please wait %.1f seconds before triggering another sound.", remaining);
        return Plugin_Handled;
    }

    PlaySaySound(path, groupName);
    g_fNextAllowedSound[client] = GetGameTime() + DEFAULT_COOLDOWN;
    return Plugin_Handled;
}

void HandleVolumeCommand(int client, const char[] arg)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (!arg[0])
    {
        PrintToChat(client, "[SaySounds] Usage: !vol <0.0 - 1.0> (current %.2f)", GetClientVolume(client));
        return;
    }

    float value = StringToFloat(arg);
    if (value < MIN_VOLUME || value > MAX_VOLUME)
    {
        PrintToChat(client, "[SaySounds] Volume must be between %.1f and %.1f.", MIN_VOLUME, MAX_VOLUME);
        return;
    }

    g_fClientVolume[client] = value;
    SaveVolumePreference(client);
    PrintToChat(client, "[SaySounds] Volume set to %.2f.", value);
}

float GetClientVolume(int client)
{
    float volume = g_fClientVolume[client];
    if (volume < 0.0)
    {
        volume = 0.0;
    }
    else if (volume > 0.0 && volume < MIN_VOLUME)
    {
        volume = MIN_VOLUME;
    }
    else if (volume > MAX_VOLUME)
    {
        volume = MAX_VOLUME;
    }
    return volume;
}

void LoadVolumePreference(int client)
{
    g_fClientVolume[client] = DEFAULT_VOLUME;

    if (g_hVolumeCookie == INVALID_HANDLE)
    {
        return;
    }

    char value[16];
    GetClientCookie(client, g_hVolumeCookie, value, sizeof(value));

    if (!value[0])
    {
        return;
    }

    float parsed = StringToFloat(value);
    if (parsed < MIN_VOLUME)
    {
        parsed = MIN_VOLUME;
    }
    else if (parsed > MAX_VOLUME)
    {
        parsed = MAX_VOLUME;
    }

    g_fClientVolume[client] = parsed;
}

void SaveVolumePreference(int client)
{
    if (g_hVolumeCookie == INVALID_HANDLE)
        return;

    if (!AreClientCookiesCached(client))
        return;

    char value[16];
    float volume = GetClientVolume(client);
    Format(value, sizeof(value), "%.2f", volume);
    SetClientCookie(client, g_hVolumeCookie, value);
}

void LoadGroupPreference(int client)
{
    strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), DEFAULT_GROUP);

    if (g_hGroupCookie == INVALID_HANDLE)
    {
        return;
    }

    char value[MAX_GROUP_NAME];
    GetClientCookie(client, g_hGroupCookie, value, sizeof(value));
    TrimString(value);
    ToLowercaseInPlace(value, sizeof(value));

    if (!value[0] || !IsKnownGroup(value))
    {
        return;
    }

    strcopy(g_szClientGroup[client], sizeof(g_szClientGroup[]), value);
}

void SaveGroupPreference(int client)
{
    if (g_hGroupCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
        return;

    SetClientCookie(client, g_hGroupCookie, g_szClientGroup[client]);
}

static bool GetCommandSoundData(const char[] commandName, char[] soundPath, int soundLen, char[] groupName, int groupLen)
{
    if (!gConfigLoaded)
    {
        return false;
    }

    char working[MAX_COMMAND_NAME * 4];
    strcopy(working, sizeof(working), commandName);
    TrimString(working);
    ToLowercaseInPlace(working, sizeof(working));

    if (!working[0])
    {
        return false;
    }

    char chosen[MAX_COMMAND_NAME];
    if (StrContains(working, ",", false) != -1)
    {
        char options[MAX_SOUND_OPTIONS][MAX_COMMAND_NAME];
        int optionCount = 0;

        char token[MAX_COMMAND_NAME];
        int start = 0;
        int len = strlen(working);
        
        while (start < len && optionCount < MAX_SOUND_OPTIONS)
        {
            // Find next comma starting from current position
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
                // Extract token
                for (int i = 0; i < tokenLen; i++)
                {
                    token[i] = working[start + i];
                }
                token[tokenLen] = '\0';

                TrimString(token);
                ToLowercaseInPlace(token, sizeof(token));

                if (token[0])
                {
                    char dummy[PLATFORM_MAX_PATH];
                    if (gSoundMap.GetString(token, dummy, sizeof(dummy)))
                    {
                        strcopy(options[optionCount], sizeof(options[]), token);
                        optionCount++;
                    }
                }
            }

            start = end + 1;
            
            // Safety check
            if (start > len)
            {
                break;
            }
        }

        if (optionCount == 0)
        {
            return false;
        }

        int pick = GetRandomInt(0, optionCount - 1);
        strcopy(chosen, sizeof(chosen), options[pick]);
    }
    else
    {
        strcopy(chosen, sizeof(chosen), working);
    }

    if (!gSoundMap.GetString(chosen, soundPath, soundLen))
    {
        return false;
    }

    if (!gSoundGroupMap.GetString(chosen, groupName, groupLen))
    {
        strcopy(groupName, groupLen, DEFAULT_GROUP);
    }

    return true;
}

static bool ClientMatchesGroup(int client, const char[] groupName)
{
    if (!groupName[0] || StrEqual(groupName, DEFAULT_GROUP))
    {
        return true;
    }

    if (!g_szClientGroup[client][0] || StrEqual(g_szClientGroup[client], DEFAULT_GROUP))
    {
        return true;
    }

    return StrEqual(g_szClientGroup[client], groupName);
}

static void PlaySaySound(const char[] soundPath, const char[] groupName)
{
    bool forceAll = (g_hForce != null && g_hForce.BoolValue);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        float emitVolume;

        if (forceAll)
        {
            emitVolume = 1.0;
        }
        else
        {
            float volume = GetClientVolume(i);
            if (volume <= 0.0)
            {
                continue;
            }

            if (!ClientMatchesGroup(i, groupName))
            {
                continue;
            }

            emitVolume = volume;
        }

        EmitSoundToClient(i, soundPath, i, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, emitVolume, SNDPITCH_NORMAL);
    }
}

void LoadDeathSoundPreference(int client)
{
    g_szDeathSound[client][0] = '\0';

    if (g_hDeathCookie == INVALID_HANDLE)
    {
        return;
    }

    char value[MAX_COMMAND_NAME * 4];
    GetClientCookie(client, g_hDeathCookie, value, sizeof(value));
    TrimString(value);
    ToLowercaseInPlace(value, sizeof(value));

    if (!value[0])
    {
        return;
    }

    strcopy(g_szDeathSound[client], sizeof(g_szDeathSound[]), value);
}

void SaveDeathSoundPreference(int client)
{
    if (g_hDeathCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
        return;

    SetClientCookie(client, g_hDeathCookie, g_szDeathSound[client]);
}

void LoadKillSoundPreference(int client)
{
    g_szKillSound[client][0] = '\0';

    if (g_hKillCookie == INVALID_HANDLE)
    {
        return;
    }

    char value[MAX_COMMAND_NAME * 4];
    GetClientCookie(client, g_hKillCookie, value, sizeof(value));
    TrimString(value);
    ToLowercaseInPlace(value, sizeof(value));

    if (!value[0])
    {
        return;
    }

    strcopy(g_szKillSound[client], sizeof(g_szKillSound[]), value);
}

void SaveKillSoundPreference(int client)
{
    if (g_hKillCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
        return;

    SetClientCookie(client, g_hKillCookie, g_szKillSound[client]);
}

public void Event_PlayerDeathPost(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (attacker > 0 && attacker != victim && HasTouhouDeathSoundWeapon(attacker))
    {
        PlayTouhouDeathSound(attacker, victim);
        return;
    }

    char victimPath[PLATFORM_MAX_PATH];
    char attackerPath[PLATFORM_MAX_PATH];
    char victimGroup[MAX_GROUP_NAME];
    char attackerGroup[MAX_GROUP_NAME];
    bool haveVictim = false;
    bool haveAttacker = false;

    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && attacker != victim && g_szKillSound[attacker][0])
    {
        haveAttacker = GetCommandSoundData(g_szKillSound[attacker], attackerPath, sizeof(attackerPath), attackerGroup, sizeof(attackerGroup));
    }

    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
    {
        if (g_szDeathSound[victim][0])
        {
            haveVictim = GetCommandSoundData(g_szDeathSound[victim], victimPath, sizeof(victimPath), victimGroup, sizeof(victimGroup));
        }
        else if (!haveAttacker)
        {
            haveVictim = GetCommandSoundData(DEFAULT_DEATH_COMMAND, victimPath, sizeof(victimPath), victimGroup, sizeof(victimGroup));
        }
    }

    if (haveVictim && haveAttacker)
    {
        if (GetRandomInt(0, 1) == 0)
        {
            PlaySaySound(victimPath, victimGroup);
        }
        else
        {
            PlaySaySound(attackerPath, attackerGroup);
        }
        return;
    }

    if (haveVictim)
    {
        PlaySaySound(victimPath, victimGroup);
    }
    else if (haveAttacker)
    {
        PlaySaySound(attackerPath, attackerGroup);
    }
}

static bool HasTouhouDeathSoundWeapon(int attacker)
{
    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return false;
    }

    int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return false;
    }

    return TF2CustAttr_GetInt(weapon, TOUHOU_DEATH_SOUND_ATTR, 0) != 0;
}

static void PlayTouhouDeathSound(int attacker, int victim)
{
    PrecacheSound(TOUHOU_DEATH_SOUND_PATH, true);
    PlaySaySound(TOUHOU_DEATH_SOUND_PATH, "");

    if (g_hForce != null && g_hForce.BoolValue)
    {
        return;
    }

    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
    {
        if (GetClientVolume(attacker) <= 0.0)
        {
            EmitSoundToClient(attacker, TOUHOU_DEATH_SOUND_PATH, attacker, SNDCHAN_AUTO,
                SNDLEVEL_NORMAL, SND_NOFLAGS, TOUHOU_DEATH_SOUND_FORCE_VOLUME, SNDPITCH_NORMAL);
        }
    }

    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim) && victim != attacker)
    {
        if (GetClientVolume(victim) <= 0.0)
        {
            EmitSoundToClient(victim, TOUHOU_DEATH_SOUND_PATH, victim, SNDCHAN_AUTO,
                SNDLEVEL_NORMAL, SND_NOFLAGS, TOUHOU_DEATH_SOUND_FORCE_VOLUME, SNDPITCH_NORMAL);
        }
    }
}
