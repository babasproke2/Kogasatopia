#pragma semicolon 1

#include <sourcemod>
#include <clientprefs>
#include <sdktools_sound>
#include <textparse>

#define CONFIG_FILE "configs/saysounds.cfg"
#define MAX_COMMAND_NAME 64

public Plugin myinfo =
{
    name = "SaySounds",
    author = "Hombre",
    description = "Chat-triggered say sounds with opt-out and volume features",
    version = "2.0.1",
    url = "https://kogasa.tf"
};

StringMap gSoundMap;
ArrayList gCommandNames;
bool gConfigLoaded = false;
float g_fClientVolume[MAXPLAYERS + 1];
float g_fNextAllowedSound[MAXPLAYERS + 1];
char g_szDeathSound[MAXPLAYERS + 1][MAX_COMMAND_NAME];
char g_szKillSound[MAXPLAYERS + 1][MAX_COMMAND_NAME];
Handle g_hVolumeCookie = INVALID_HANDLE;
Handle g_hDeathCookie = INVALID_HANDLE;
Handle g_hKillCookie = INVALID_HANDLE;
ConVar g_hForce;

const float DEFAULT_VOLUME = 0.0;
const float MIN_VOLUME = 0.0;
const float MAX_VOLUME = 1.0;
const float DEFAULT_COOLDOWN = 5.0;
const float ADMIN_COOLDOWN = 0.4;

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
    g_hDeathCookie = RegClientCookie("saysounds_death", "Preferred saysound on death", CookieAccess_Public);
    g_hKillCookie = RegClientCookie("saysounds_kill", "Preferred saysound on kill", CookieAccess_Public);

    RegConsoleCmd("sm_opt", Command_ToggleSoundOpt);
    RegConsoleCmd("sm_sounds", Command_ListSounds);
    RegConsoleCmd("sm_vol", Command_SetVolume);
    RegConsoleCmd("sm_diesound", Command_SetDeathSound);
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

        if (IsClientInGame(i) && AreClientCookiesCached(i))
        {
            LoadVolumePreference(i);
            LoadDeathSoundPreference(i);
            LoadKillSoundPreference(i);
        }
    }
}

public void OnClientPutInServer(int client)
{
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_fNextAllowedSound[client] = 0.0;
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';

    if (AreClientCookiesCached(client))
    {
        LoadVolumePreference(client);
        LoadDeathSoundPreference(client);
        LoadKillSoundPreference(client);
    }
}

public void OnClientCookiesCached(int client)
{
    LoadVolumePreference(client);
    LoadDeathSoundPreference(client);
    LoadKillSoundPreference(client);
}

public void OnClientDisconnect(int client)
{
    SaveVolumePreference(client);
    SaveDeathSoundPreference(client);
    SaveKillSoundPreference(client);
    g_fNextAllowedSound[client] = 0.0;
    g_fClientVolume[client] = DEFAULT_VOLUME;
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';
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

		if(CheckCommandAccess(client, "sm_admin", ADMFLAG_ROOT, true))
			g_fNextAllowedSound[initiator] = now + ADMIN_COOLDOWN;
		else
			g_fNextAllowedSound[initiator] = now + DEFAULT_COOLDOWN;
        
    }

    PlaySaySound(soundPath);

    return Plugin_Continue;
}

void LoadSaySoundConfig()
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
    if (GetClientVolume(client) <= 0.0)
    {
        g_fClientVolume[client] = 0.5; // 50% by default
        SaveVolumePreference(client);
        PrintToChat(client, "[SaySounds] Say sounds enabled and set to 50%%%; Type !opt to mute them and !vol to control.");
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
        PrintToChat(client, "[SaySounds] Usage: !diesound <command|none> (current: %s)", g_szDeathSound[client][0] ? g_szDeathSound[client] : "none");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);
    ToLowercaseInPlace(arg, sizeof(arg));

    if (!arg[0] || StrEqual(arg, "none") || StrEqual(arg, "off"))
    {
        g_szDeathSound[client][0] = '\0';
        SaveDeathSoundPreference(client);
        PrintToChat(client, "[SaySounds] Death sound cleared.");
        return Plugin_Handled;
    }

    char path[PLATFORM_MAX_PATH];
    if (!gSoundMap.GetString(arg, path, sizeof(path)))
    {
        PrintToChat(client, "[SaySounds] Unknown sound '%s'. Use !sounds to list commands.", arg);
        return Plugin_Handled;
    }

    strcopy(g_szDeathSound[client], sizeof(g_szDeathSound[]), arg);
    SaveDeathSoundPreference(client);
    PrintToChat(client, "[SaySounds] Death sound set to '%s'.", arg);
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
        PrintToChat(client, "[SaySounds] Usage: !killsound <command|none> (current: %s)", g_szKillSound[client][0] ? g_szKillSound[client] : "none");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    TrimString(arg);
    ToLowercaseInPlace(arg, sizeof(arg));

    if (!arg[0] || StrEqual(arg, "none") || StrEqual(arg, "off"))
    {
        g_szKillSound[client][0] = '\0';
        SaveKillSoundPreference(client);
        PrintToChat(client, "[SaySounds] Kill sound cleared.");
        return Plugin_Handled;
    }

    char path[PLATFORM_MAX_PATH];
    if (!gSoundMap.GetString(arg, path, sizeof(path)))
    {
        PrintToChat(client, "[SaySounds] Unknown sound '%s'. Use !sounds to list commands.", arg);
        return Plugin_Handled;
    }

    strcopy(g_szKillSound[client], sizeof(g_szKillSound[]), arg);
    SaveKillSoundPreference(client);
    PrintToChat(client, "[SaySounds] Kill sound set to '%s'.", arg);
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
    if (!gSoundMap.GetString(arg, path, sizeof(path)))
    {
        PrintToChat(client, "[SaySounds] Unknown sound '%s'. Use !sounds to list commands.", arg);
        return Plugin_Handled;
    }

    PlaySaySound(path);
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

static void PlaySaySound(const char[] soundPath)
{
    bool forceAll = (g_hForce != null && g_hForce.BoolValue);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        float volume = GetClientVolume(i);
        if (!forceAll && volume <= 0.0)
        {
            continue;
        }

        float emitVolume = forceAll ? 1.0 : volume;
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

    char value[MAX_COMMAND_NAME];
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

    char value[MAX_COMMAND_NAME];
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

    char victimPath[PLATFORM_MAX_PATH];
    char attackerPath[PLATFORM_MAX_PATH];
    bool haveVictim = false;
    bool haveAttacker = false;

    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim) && g_szDeathSound[victim][0])
    {
        haveVictim = gSoundMap.GetString(g_szDeathSound[victim], victimPath, sizeof(victimPath));
    }

    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && attacker != victim && g_szKillSound[attacker][0])
    {
        haveAttacker = gSoundMap.GetString(g_szKillSound[attacker], attackerPath, sizeof(attackerPath));
    }

    if (haveVictim && haveAttacker)
    {
        if (GetRandomInt(0, 1) == 0)
        {
            PlaySaySound(victimPath);
        }
        else
        {
            PlaySaySound(attackerPath);
        }
        return;
    }

    if (haveVictim)
    {
        PlaySaySound(victimPath);
    }
    else if (haveAttacker)
    {
        PlaySaySound(attackerPath);
    }
}
