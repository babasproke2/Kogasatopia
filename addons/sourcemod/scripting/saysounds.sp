#pragma semicolon 1

#include <sourcemod>
#include <clientprefs>
#include <sdktools_sound>
#include <textparse>

#define CONFIG_FILE "configs/cow_sounds.cfg"
#define MAX_COMMAND_NAME 64

public Plugin myinfo =
{
    name = "SaySounds",
    author = "Codex",
    description = "Chat-triggered say sounds with opt-out support",
    version = "2.0.1",
    url = "https://kogasa.tf"
};

StringMap gSoundMap;
ArrayList gCommandNames;
bool gConfigLoaded = false;
float g_fClientVolume[MAXPLAYERS + 1];
Handle g_hVolumeCookie = INVALID_HANDLE;
ConVar g_hForce;
float g_fNextAllowedSound[MAXPLAYERS + 1];
bool g_bCookiesLoaded[MAXPLAYERS + 1];

const float DEFAULT_VOLUME = 0.0;
const float MIN_VOLUME = 0.0;
const float MAX_VOLUME = 1.0;
const float DEFAULT_COOLDOWN = 5.0;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
    RegPluginLibrary("saysounds");
    CreateNative("SaySounds_ShouldPlay", Native_ShouldPlay);
    return APLRes_Success;
}

public void OnPluginStart()
{
    gSoundMap = new StringMap();
    gCommandNames = new ArrayList(ByteCountToCells(MAX_COMMAND_NAME));

	g_hForce = CreateConVar("saysounds_force", "0", "Force everyone to hear saysounds");
    g_hVolumeCookie = RegClientCookie("saysounds_volume", "Preferred say sound volume", CookieAccess_Public);

    RegConsoleCmd("sm_opt", Command_ToggleSoundOpt);
    RegConsoleCmd("sm_sounds", Command_ListSounds);
    RegConsoleCmd("sm_vol", Command_SetVolume);

    LoadCowSoundConfig();

    AddCommandListener(ChatCommandListener, "say");
    AddCommandListener(ChatCommandListener, "say_team");

    // Handle late-loading: load cookies for already-connected clients
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fClientVolume[i] = DEFAULT_VOLUME;
        g_fNextAllowedSound[i] = 0.0;
        g_bCookiesLoaded[i] = false;

        if (IsClientInGame(i) && AreClientCookiesCached(i))
        {
            OnClientCookiesCached(i);
        }
    }
}

public void OnClientPutInServer(int client)
{
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_fNextAllowedSound[client] = 0.0;
    g_bCookiesLoaded[client] = false;
}

public void OnClientCookiesCached(int client)
{
    LoadVolumePreference(client);
    g_bCookiesLoaded[client] = true;
}

public void OnClientDisconnect(int client)
{
    g_fNextAllowedSound[client] = 0.0;
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_bCookiesLoaded[client] = false;
}

public void OnConfigsExecuted()
{
    LoadCowSoundConfig();
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
    if (!gSoundMap.GetString(commandName, soundPath, sizeof(soundPath)))
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
        g_fNextAllowedSound[initiator] = now + DEFAULT_COOLDOWN;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        float volume = GetClientVolume(i);
        if (volume <= 0.0)
        {
            continue;
        }
		if ((GetConVarInt(g_hForce)) || volume > 0.0)
        	EmitSoundToClient(i, soundPath, i, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, volume, SNDPITCH_NORMAL);
    }

    return Plugin_Continue;
}

void LoadCowSoundConfig()
{
    gSoundMap.Clear();
    gCommandNames.Clear();
    gConfigLoaded = false;

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
    strcopy(soundPath, sizeof(soundPath), value);
    TrimString(soundPath);

    NormalizeSoundPath(soundPath, sizeof(soundPath));

    if (!soundPath[0])
    {
        LogError("[SaySounds] Command '%s' has an empty sound path.", commandName);
        return SMCParse_Continue;
    }

    int existingIndex = FindCommandIndex(commandName);
    if (existingIndex == -1)
    {
        gCommandNames.PushString(commandName);
    }

    gSoundMap.SetString(commandName, soundPath);
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

public Action Command_ToggleSoundOpt(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    // Wait for cookies to load before allowing changes
    if (!g_bCookiesLoaded[client])
    {
        PrintToChat(client, "[SaySounds] Please wait for your settings to load...");
        return Plugin_Handled;
    }

    if (GetClientVolume(client) <= 0.0)
    {
        g_fClientVolume[client] = 1.0;
        SaveVolumePreference(client);
        PrintToChat(client, "[SaySounds] Say sounds enabled. Type !opt to mute them.");
    }
    else
    {
        g_fClientVolume[client] = 0.0;
        SaveVolumePreference(client);
        PrintToChat(client, "[SaySounds] Say sounds disabled. Type !opt to re-enable them.");
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
            gCommandNames.GetString(i, command, sizeof(command));
            if (!gSoundMap.GetString(command, sound, sizeof(sound)))
                continue;
            PrintToServer("[SaySounds] !%s -> %s", command, sound);
        }
        return Plugin_Handled;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    PrintToChat(client, "[SaySounds] Available commands:");
    PrintToChat(client, "[SaySounds] (Use !opt to enable sound playback; !vol <0.0-1.0> for custom volume)");
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        char command[MAX_COMMAND_NAME];
        char sound[PLATFORM_MAX_PATH];
        gCommandNames.GetString(i, command, sizeof(command));
        if (!gSoundMap.GetString(command, sound, sizeof(sound)))
            continue;
        PrintToChat(client, "!%s -> %s", command, sound);
    }
    PrintToChat(client, "[SaySounds] Use !opt to toggle your say sounds.");

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

public Action Command_SetVolume(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        PrintToServer("[SaySounds] This command can only be used by players.");
        return Plugin_Handled;
    }

    // Wait for cookies to load before allowing changes
    if (!g_bCookiesLoaded[client])
    {
        PrintToChat(client, "[SaySounds] Please wait for your settings to load...");
        return Plugin_Handled;
    }

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
    if (g_hVolumeCookie == INVALID_HANDLE)
    {
        g_fClientVolume[client] = DEFAULT_VOLUME;
        return;
    }

    char value[16];
    GetClientCookie(client, g_hVolumeCookie, value, sizeof(value));
    
    if (!value[0])
    {
        // No saved preference, use default
        g_fClientVolume[client] = DEFAULT_VOLUME;
        return;
    }

    float parsed = StringToFloat(value);
    if (parsed < 0.0)
    {
        parsed = 0.0;
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

    if (!g_bCookiesLoaded[client])
        return;

    char value[16];
    float volume = GetClientVolume(client);
    Format(value, sizeof(value), "%.2f", volume);
    SetClientCookie(client, g_hVolumeCookie, value);
}