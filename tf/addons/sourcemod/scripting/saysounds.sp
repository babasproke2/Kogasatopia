#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <textparse>

#include <sdktools_sound>

#include <tf_custom_attributes>

#undef REQUIRE_PLUGIN
#include <points_store_api>
#include <dgm_api>
#define REQUIRE_PLUGIN
#include <plugin_statistics>

#include "include/steam_identity.inc"
#include "include/strings.inc"

#define CONFIG_FILE "configs/saysounds.cfg"
#define MAX_COMMAND_NAME 64
#define MAX_GROUP_NAME 32
#define MAX_GROUP_PREF_VALUE 512
#define DEFAULT_GROUP "all"
#define ADMIN_ONLY_GROUPS_SECTION "adminonlygroups"
#define PAID_SAYSOUND_GROUPS_SECTION "paidsaysoundgroups"
#define GROUP_ALIASES_SECTION "groupaliases"
#define SOUND_PREF_GROUP_ITEM_PREFIX "group:"
#define SAYSOUND_ON_KILL_ATTR "saysound on kill"
#define POINTS_STORE_HAS_PURCHASE_NATIVE "PointsStore_HasPurchase"
#define SAYSOUNDS_STATS_SAMPLE_RATE 3

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
StringMap gAdminOnlyGroups;
StringMap gPaidSaysoundGroups;
StringMap gGroupAliases;
ArrayList gCommandNames;
ArrayList gGroupNames;
bool gConfigLoaded = false;
bool gConfigInAdminOnlyGroups = false;
bool gConfigInPaidSaysoundGroups = false;
bool gConfigInGroupAliases = false;
int gConfigSectionDepth = 0;
int gConfigAdminOnlyGroupsDepth = -1;
int gConfigPaidSaysoundGroupsDepth = -1;
int gConfigGroupAliasesDepth = -1;
float g_fClientVolume[MAXPLAYERS + 1];
float g_fNextAllowedSound[MAXPLAYERS + 1];
char g_szDeathSound[MAXPLAYERS + 1][MAX_COMMAND_NAME * 4];
char g_szKillSound[MAXPLAYERS + 1][MAX_COMMAND_NAME * 4];
StringMap g_hClientDisabledGroups[MAXPLAYERS + 1];
Handle g_hVolumeCookie = INVALID_HANDLE;
Handle g_hDeathCookie = INVALID_HANDLE;
Handle g_hKillCookie = INVALID_HANDLE;
Handle g_hDisabledGroupsCookie = INVALID_HANDLE;
ConVar g_hForce;
ConVar g_hDefaultDeathSound;
ConVar g_hDefaultVolume;
int g_iSaySoundStatsCounter = 0;

const float MIN_VOLUME = 0.0;
const float MAX_VOLUME = 1.0;
const float DEFAULT_COOLDOWN = 5.0;
const float ADMIN_COOLDOWN = 1.0;
const int MAX_SOUND_OPTIONS = 16;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
    MarkNativeAsOptional(POINTS_STORE_HAS_PURCHASE_NATIVE);
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("DGM_GetGameModeKey");
    RegPluginLibrary("saysounds");
    CreateNative("SaySounds_ShouldPlay", Native_ShouldPlay);
    CreateNative("SaySounds_PlaySoundToOptedIn", Native_PlaySoundToOptedIn);
    CreateNative("SaySounds_PlayCommand", Native_PlayCommand);
    CreateNative("SaySounds_PlayCommandAs", Native_PlayCommandAs);
    CreateNative("SaySounds_CanClientUseCommand", Native_CanClientUseCommand);
    CreateNative("SaySounds_IsCommandPaid", Native_IsCommandPaid);
    CreateNative("SaySounds_GetCommandGroup", Native_GetCommandGroup);
    return APLRes_Success;
}

public void OnAllPluginsLoaded() {}
public void OnLibraryAdded(const char[] name) {}
public void OnLibraryRemoved(const char[] name) {}

public void OnPluginStart()
{
    gSoundMap = new StringMap();
    gSoundGroupMap = new StringMap();
    gAdminOnlyGroups = new StringMap();
    gPaidSaysoundGroups = new StringMap();
    gGroupAliases = new StringMap();
    gCommandNames = new ArrayList(ByteCountToCells(MAX_COMMAND_NAME));
    gGroupNames = new ArrayList(ByteCountToCells(MAX_GROUP_NAME));

    g_hForce = CreateConVar("saysounds_force", "0", "Force everyone to hear saysounds");
    g_hDefaultDeathSound = CreateConVar("saysounds_default_death_sound", "doh", "Saysound command/group used when a victim has no death sound set and the attacker has no kill sound.");
    g_hDefaultVolume = CreateConVar("saysounds_default_volume", "0.5", "Default saysound volume for clients with no saved volume preference.", _, true, MIN_VOLUME, true, MAX_VOLUME);
    g_hVolumeCookie = RegClientCookie("saysounds_volume", "Preferred say sound volume", CookieAccess_Public);
    g_hDeathCookie = RegClientCookie("saysounds_death", "Preferred saysound on death", CookieAccess_Public);
    g_hKillCookie = RegClientCookie("saysounds_kill", "Preferred saysound on kill", CookieAccess_Public);
    g_hDisabledGroupsCookie = RegClientCookie("saysounds_disabled_groups", "Disabled saysound groups", CookieAccess_Public);

    RegConsoleCmd("sm_opt", Command_ToggleSoundOpt);
    RegConsoleCmd("sm_opts", Command_ShowGroupOptions);
    RegConsoleCmd("sm_sounds", Command_ListSounds);
    RegConsoleCmd("sm_saysounds", Command_ListSounds);
    RegConsoleCmd("sm_groups", Command_ListGroups);
    RegAdminCmd("sm_soundgroups", Command_ListGroups, 0, "Lists SaySound groups.");
    RegAdminCmd("sm_saysoundgroups", Command_ListGroups, 0, "Lists SaySound groups.");
    RegConsoleCmd("sm_vol", Command_SetVolume);
    RegConsoleCmd("sm_diesounds", Command_ShowDeathSoundsMenu);
    RegConsoleCmd("sm_deathsounds", Command_ShowDeathSoundsMenu);
    RegConsoleCmd("sm_killsounds", Command_ShowKillSoundsMenu);
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
        g_fClientVolume[i] = GetDefaultVolume();
        g_fNextAllowedSound[i] = 0.0;
        g_szDeathSound[i][0] = '\0';
        g_szKillSound[i][0] = '\0';
        ResetClientDisabledGroups(i);

        if (IsClientInGame(i) && AreClientCookiesCached(i))
        {
            LoadVolumePreference(i);
            LoadDeathSoundPreference(i);
            LoadKillSoundPreference(i);
            LoadDisabledGroupPreferences(i);
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

    if (gAdminOnlyGroups != null)
    {
        delete gAdminOnlyGroups;
        gAdminOnlyGroups = null;
    }

    if (gPaidSaysoundGroups != null)
    {
        delete gPaidSaysoundGroups;
        gPaidSaysoundGroups = null;
    }

    if (gGroupAliases != null)
    {
        delete gGroupAliases;
        gGroupAliases = null;
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

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_hClientDisabledGroups[i] != null)
        {
            delete g_hClientDisabledGroups[i];
            g_hClientDisabledGroups[i] = null;
        }
    }
}

public void OnClientPutInServer(int client)
{
    g_fClientVolume[client] = GetDefaultVolume();
    g_fNextAllowedSound[client] = 0.0;
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';
        ResetClientDisabledGroups(client);

    if (AreClientCookiesCached(client))
    {
        LoadVolumePreference(client);
        LoadDeathSoundPreference(client);
        LoadKillSoundPreference(client);
        LoadDisabledGroupPreferences(client);
    }
}

public void OnClientCookiesCached(int client)
{
    LoadVolumePreference(client);
    LoadDeathSoundPreference(client);
    LoadKillSoundPreference(client);
    LoadDisabledGroupPreferences(client);
}

public void OnClientDisconnect(int client)
{
    SaveVolumePreference(client);
    SaveDeathSoundPreference(client);
    SaveKillSoundPreference(client);
    SaveDisabledGroupPreferences(client);
    g_fNextAllowedSound[client] = 0.0;
    g_fClientVolume[client] = GetDefaultVolume();
    g_szDeathSound[client][0] = '\0';
    g_szKillSound[client][0] = '\0';
    ResetClientDisabledGroups(client);
}

public void OnConfigsExecuted()
{
    LoadSaySoundConfig();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && AreClientCookiesCached(i))
        {
            LoadDisabledGroupPreferences(i);
        }
    }
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
    Strings_ShiftLeft(payload, sizeof(payload), 1);
    TrimString(payload);

    if (!payload[0])
    {
        return Plugin_Continue;
    }

    char commandName[MAX_COMMAND_NAME * 4];
    char args[256];

    strcopy(commandName, sizeof(commandName), payload);
    int spaceIndex = FindCharInString(commandName, ' ');
    if (spaceIndex != -1)
    {
        commandName[spaceIndex] = '\0';

        strcopy(args, sizeof(args), payload);
        Strings_ShiftLeft(args, sizeof(args), spaceIndex + 1);
        TrimString(args);
    }
    else
    {
        args[0] = '\0';
    }

    Strings_ToLower(commandName, sizeof(commandName));

    if (!commandName[0])
    {
        return Plugin_Continue;
    }

    int initiator = (client > 0 && client <= MaxClients) ? client : -1;
    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    bool restricted = false;
    bool paidRestricted = false;
    if (!GetCommandSoundDataForClientEx(initiator, commandName, soundPath, sizeof(soundPath), groupName, sizeof(groupName), restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup)))
    {
        if (restricted)
        {
            PrintToChat(initiator, "[SaySounds] That sound group is admin-only.");
            return Plugin_Handled;
        }

        if (paidRestricted)
        {
            PrintToChat(initiator, "[SaySounds] That sound group requires a shop purchase. Use !shop.");
            return Plugin_Handled;
        }

        return Plugin_Continue;
    }

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

    if (PlaySaySound(soundPath, groupName))
    {
        LogSaySoundUsage("saysound_used", initiator, 0, selectedCommand, soundPath, groupName, fromGroup, sourceGroup, false, "chat");
    }

    return Plugin_Continue;
}

void LoadSaySoundConfig()
{
    gSoundMap.Clear();
    gSoundGroupMap.Clear();
    gAdminOnlyGroups.Clear();
    gPaidSaysoundGroups.Clear();
    gGroupAliases.Clear();
    gCommandNames.Clear();
    gGroupNames.Clear();
    gConfigLoaded = false;
    gConfigInAdminOnlyGroups = false;
    gConfigInPaidSaysoundGroups = false;
    gConfigInGroupAliases = false;
    gConfigSectionDepth = 0;
    gConfigAdminOnlyGroupsDepth = -1;
    gConfigPaidSaysoundGroupsDepth = -1;
    gConfigGroupAliasesDepth = -1;
    EnsureGroupRegistered(DEFAULT_GROUP);

    char filePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filePath, sizeof(filePath), CONFIG_FILE);

    if (!FileExists(filePath))
    {
        LogError("[SaySounds] Config file not found: %s", filePath);
        return;
    }

    SMCParser parser = new SMCParser();
    parser.OnEnterSection = Config_EnterSection;
    parser.OnLeaveSection = Config_LeaveSection;
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

public SMCResult Config_EnterSection(SMCParser parser, const char[] name, bool optQuotes)
{
    gConfigSectionDepth++;

    char sectionName[64];
    strcopy(sectionName, sizeof(sectionName), name);
    TrimString(sectionName);
    Strings_ToLower(sectionName, sizeof(sectionName));

    if (StrEqual(sectionName, ADMIN_ONLY_GROUPS_SECTION)
        || StrEqual(sectionName, "admin_only_groups")
        || StrEqual(sectionName, "admin-only-groups"))
    {
        gConfigInAdminOnlyGroups = true;
        gConfigAdminOnlyGroupsDepth = gConfigSectionDepth;
    }
    else if (StrEqual(sectionName, PAID_SAYSOUND_GROUPS_SECTION)
        || StrEqual(sectionName, "paid_saysound_groups")
        || StrEqual(sectionName, "paid-saysound-groups"))
    {
        gConfigInPaidSaysoundGroups = true;
        gConfigPaidSaysoundGroupsDepth = gConfigSectionDepth;
    }
    else if (StrEqual(sectionName, GROUP_ALIASES_SECTION)
        || StrEqual(sectionName, "group_aliases")
        || StrEqual(sectionName, "group-aliases"))
    {
        gConfigInGroupAliases = true;
        gConfigGroupAliasesDepth = gConfigSectionDepth;
    }

    return SMCParse_Continue;
}

public SMCResult Config_LeaveSection(SMCParser parser)
{
    if (gConfigInAdminOnlyGroups && gConfigSectionDepth == gConfigAdminOnlyGroupsDepth)
    {
        gConfigInAdminOnlyGroups = false;
        gConfigAdminOnlyGroupsDepth = -1;
    }

    if (gConfigInPaidSaysoundGroups && gConfigSectionDepth == gConfigPaidSaysoundGroupsDepth)
    {
        gConfigInPaidSaysoundGroups = false;
        gConfigPaidSaysoundGroupsDepth = -1;
    }

    if (gConfigInGroupAliases && gConfigSectionDepth == gConfigGroupAliasesDepth)
    {
        gConfigInGroupAliases = false;
        gConfigGroupAliasesDepth = -1;
    }

    if (gConfigSectionDepth > 0)
    {
        gConfigSectionDepth--;
    }

    return SMCParse_Continue;
}

public SMCResult Config_KeyValue(SMCParser parser, const char[] key, const char[] value, bool keyQuoted, bool valueQuoted)
{
    if (gConfigInAdminOnlyGroups)
    {
        Config_AdminOnlyGroup(key, value);
        return SMCParse_Continue;
    }

    if (gConfigInPaidSaysoundGroups)
    {
        Config_PaidSaysoundGroup(key, value);
        return SMCParse_Continue;
    }

    if (gConfigInGroupAliases)
    {
        Config_GroupAlias(key, value);
        return SMCParse_Continue;
    }

    char commandName[MAX_COMMAND_NAME];
    strcopy(commandName, sizeof(commandName), key);
    TrimString(commandName);

    if (!commandName[0])
    {
        return SMCParse_Continue;
    }

    if (commandName[0] == '!' || commandName[0] == '/')
    {
        Strings_ShiftLeft(commandName, sizeof(commandName), 1);
    }

    Strings_ToLower(commandName, sizeof(commandName));

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

static void Config_AdminOnlyGroup(const char[] key, const char[] value)
{
    char groupName[MAX_GROUP_NAME];
    strcopy(groupName, sizeof(groupName), key);
    TrimString(groupName);
    Strings_ToLower(groupName, sizeof(groupName));

    if (!groupName[0] || StrEqual(groupName, DEFAULT_GROUP))
    {
        return;
    }

    EnsureGroupRegistered(groupName);

    if (ConfigValueIsEnabled(value))
    {
        gAdminOnlyGroups.SetValue(groupName, 1);
    }
    else
    {
        gAdminOnlyGroups.Remove(groupName);
    }
}

static void Config_PaidSaysoundGroup(const char[] key, const char[] value)
{
    char groupName[MAX_GROUP_NAME];
    strcopy(groupName, sizeof(groupName), key);
    TrimString(groupName);
    Strings_ToLower(groupName, sizeof(groupName));

    if (!groupName[0] || StrEqual(groupName, DEFAULT_GROUP))
    {
        return;
    }

    EnsureGroupRegistered(groupName);

    if (ConfigValueIsEnabled(value))
    {
        gPaidSaysoundGroups.SetValue(groupName, 1);
    }
    else
    {
        gPaidSaysoundGroups.Remove(groupName);
    }
}

static void Config_GroupAlias(const char[] key, const char[] value)
{
    char groupName[MAX_GROUP_NAME];
    strcopy(groupName, sizeof(groupName), key);
    TrimString(groupName);
    Strings_ToLower(groupName, sizeof(groupName));

    char aliasName[MAX_COMMAND_NAME];
    strcopy(aliasName, sizeof(aliasName), value);
    TrimString(aliasName);
    Strings_ToLower(aliasName, sizeof(aliasName));

    if (!groupName[0] || !aliasName[0] || StrEqual(aliasName, DEFAULT_GROUP))
    {
        return;
    }

    if (aliasName[0] == '!' || aliasName[0] == '/')
    {
        Strings_ShiftLeft(aliasName, sizeof(aliasName), 1);
    }

    EnsureGroupRegistered(groupName);
    gGroupAliases.SetString(aliasName, groupName);
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

void NormalizeSoundPath(char[] soundPath, int maxlen)
{
    ReplaceString(soundPath, maxlen, "\\", "/");

    while (soundPath[0] == '/')
    {
        Strings_ShiftLeft(soundPath, maxlen, 1);
    }

    if (Strings_StartsWith(soundPath, "sound/"))
    {
        Strings_ShiftLeft(soundPath, maxlen, 6);
    }
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
        Strings_ToLower(groupPart, sizeof(groupPart));

        char pathPart[PLATFORM_MAX_PATH];
        Strings_CopyFrom(raw, delim + 1, pathPart, sizeof(pathPart));
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
    Strings_ToLower(normalized, sizeof(normalized));

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
    char resolved[MAX_GROUP_NAME];
    return ResolveKnownGroupName(groupName, resolved, sizeof(resolved));
}

static bool ResolveKnownGroupName(const char[] inputName, char[] groupName, int groupLen)
{
    if (groupLen > 0)
    {
        groupName[0] = '\0';
    }

    if (!inputName[0])
    {
        return false;
    }

    char normalized[MAX_GROUP_NAME];
    strcopy(normalized, sizeof(normalized), inputName);
    TrimString(normalized);
    Strings_ToLower(normalized, sizeof(normalized));

    if (!normalized[0])
    {
        return false;
    }

    if (StrEqual(normalized, DEFAULT_GROUP))
    {
        strcopy(groupName, groupLen, normalized);
        return true;
    }

    if (FindGroupIndex(normalized) != -1)
    {
        strcopy(groupName, groupLen, normalized);
        return true;
    }

    if (gGroupAliases == null || !gGroupAliases.GetString(normalized, groupName, groupLen))
    {
        return false;
    }

    TrimString(groupName);
    Strings_ToLower(groupName, groupLen);
    return groupName[0] != '\0'
        && (StrEqual(groupName, DEFAULT_GROUP) || FindGroupIndex(groupName) != -1);
}

static bool ConfigValueIsEnabled(const char[] value)
{
    char normalized[16];
    strcopy(normalized, sizeof(normalized), value);
    TrimString(normalized);
    Strings_ToLower(normalized, sizeof(normalized));

    if (!normalized[0])
    {
        return true;
    }

    return !StrEqual(normalized, "0")
        && !StrEqual(normalized, "false")
        && !StrEqual(normalized, "off")
        && !StrEqual(normalized, "no");
}

static bool IsGroupAdminOnly(const char[] groupName)
{
    if (gAdminOnlyGroups == null || !groupName[0])
    {
        return false;
    }

    char normalized[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalized, sizeof(normalized)))
    {
        return false;
    }

    int adminOnly = 0;
    return gAdminOnlyGroups.GetValue(normalized, adminOnly) && adminOnly != 0;
}

static bool IsGroupPaid(const char[] groupName)
{
    if (gPaidSaysoundGroups == null || !groupName[0])
    {
        return false;
    }

    char normalized[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalized, sizeof(normalized)))
    {
        return false;
    }

    int paid = 0;
    return gPaidSaysoundGroups.GetValue(normalized, paid) && paid != 0;
}

static bool CanClientUseAdminOnlySaySoundGroup(int client, const char[] groupName, bool bypassAdminOnly = false)
{
    if (bypassAdminOnly)
    {
        return true;
    }

    if (!IsGroupAdminOnly(groupName))
    {
        return true;
    }

    if (client <= 0)
    {
        return true;
    }

    return CheckCommandAccess(client, "sm_saysounds_admin_groups", ADMFLAG_GENERIC, true);
}

static bool CanClientUsePaidSaysoundGroup(int client, const char[] groupName)
{
    char normalized[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalized, sizeof(normalized)) || !IsGroupPaid(normalized))
    {
        return true;
    }

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, POINTS_STORE_HAS_PURCHASE_NATIVE) != FeatureStatus_Available)
    {
        return false;
    }

    return PointsStore_HasPurchase(client, normalized);
}

static bool CanClientUseSaySoundGroup(int client, const char[] groupName, bool bypassAdminOnly = false)
{
    return CanClientUseAdminOnlySaySoundGroup(client, groupName, bypassAdminOnly)
        && CanClientUsePaidSaysoundGroup(client, groupName);
}

static bool CanClientUseSaySoundCommand(int client, const char[] commandName, bool bypassAdminOnly = false)
{
    char path[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    if (!GetCommandSoundData(commandName, path, sizeof(path), groupName, sizeof(groupName)))
    {
        return false;
    }

    return CanClientUseSaySoundGroup(client, groupName, bypassAdminOnly);
}

static bool CanClientUseSaySoundInput(int client, const char[] inputName, bool bypassAdminOnly = false)
{
    bool restricted = false;
    bool paidRestricted = false;
    char chosen[MAX_COMMAND_NAME];
    return GetCommandOptionForClient(client, inputName, chosen, sizeof(chosen), restricted, paidRestricted, bypassAdminOnly);
}

static bool IsSaySoundInputPaid(const char[] inputName)
{
    char normalizedName[MAX_COMMAND_NAME];
    strcopy(normalizedName, sizeof(normalizedName), inputName);
    TrimString(normalizedName);
    Strings_ToLower(normalizedName, sizeof(normalizedName));

    if (!normalizedName[0])
    {
        return false;
    }

    char soundPath[PLATFORM_MAX_PATH];
    if (gSoundMap.GetString(normalizedName, soundPath, sizeof(soundPath)))
    {
        char groupName[MAX_GROUP_NAME];
        if (!gSoundGroupMap.GetString(normalizedName, groupName, sizeof(groupName)))
        {
            strcopy(groupName, sizeof(groupName), DEFAULT_GROUP);
        }

        return IsGroupPaid(groupName);
    }

    char groupName[MAX_GROUP_NAME];
    return ResolveKnownGroupName(normalizedName, groupName, sizeof(groupName)) && IsGroupPaid(groupName);
}

static bool GetSaySoundInputGroup(const char[] inputName, char[] groupName, int groupLen)
{
    if (groupLen > 0)
    {
        groupName[0] = '\0';
    }

    char normalizedName[MAX_COMMAND_NAME];
    strcopy(normalizedName, sizeof(normalizedName), inputName);
    TrimString(normalizedName);
    Strings_ToLower(normalizedName, sizeof(normalizedName));

    if (!normalizedName[0])
    {
        return false;
    }

    if (ResolveKnownGroupName(normalizedName, groupName, groupLen))
    {
        return true;
    }

    char soundPath[PLATFORM_MAX_PATH];
    if (!gSoundMap.GetString(normalizedName, soundPath, sizeof(soundPath)))
    {
        return false;
    }

    if (!gSoundGroupMap.GetString(normalizedName, groupName, groupLen))
    {
        strcopy(groupName, groupLen, DEFAULT_GROUP);
    }

    return groupName[0] != '\0';
}

static void EnsureClientGroupPreferenceMap(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (g_hClientDisabledGroups[client] == null)
    {
        g_hClientDisabledGroups[client] = new StringMap();
    }
}

static void ResetClientDisabledGroups(int client)
{
    EnsureClientGroupPreferenceMap(client);

    if (g_hClientDisabledGroups[client] != null)
    {
        g_hClientDisabledGroups[client].Clear();
    }
}

static bool IsClientGroupDisabled(int client, const char[] groupName)
{
    if (client <= 0 || client > MaxClients || !groupName[0] || StrEqual(groupName, DEFAULT_GROUP))
    {
        return false;
    }

    char normalizedGroup[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalizedGroup, sizeof(normalizedGroup)))
    {
        return false;
    }

    EnsureClientGroupPreferenceMap(client);

    int disabled = 0;
    return g_hClientDisabledGroups[client] != null
        && g_hClientDisabledGroups[client].GetValue(normalizedGroup, disabled)
        && disabled != 0;
}

static bool SetClientGroupDisabled(int client, const char[] groupName, bool disabled)
{
    if (client <= 0 || client > MaxClients || !groupName[0] || StrEqual(groupName, DEFAULT_GROUP))
    {
        return false;
    }

    char normalizedGroup[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalizedGroup, sizeof(normalizedGroup)) || StrEqual(normalizedGroup, DEFAULT_GROUP))
    {
        return false;
    }

    EnsureClientGroupPreferenceMap(client);

    if (g_hClientDisabledGroups[client] == null)
    {
        return false;
    }

    if (disabled)
    {
        g_hClientDisabledGroups[client].SetValue(normalizedGroup, 1);
    }
    else
    {
        g_hClientDisabledGroups[client].Remove(normalizedGroup);
    }

    return true;
}

static void BuildDisabledGroupCookieValue(int client, char[] value, int valueLen)
{
    value[0] = '\0';

    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    EnsureClientGroupPreferenceMap(client);
    if (g_hClientDisabledGroups[client] == null || gGroupNames == null)
    {
        return;
    }

    char groupName[MAX_GROUP_NAME];
    int disabled = 0;

    for (int i = 0; i < gGroupNames.Length; i++)
    {
        gGroupNames.GetString(i, groupName, sizeof(groupName));
        if (StrEqual(groupName, DEFAULT_GROUP))
        {
            continue;
        }

        if (!g_hClientDisabledGroups[client].GetValue(groupName, disabled) || disabled == 0)
        {
            continue;
        }

        if (value[0])
        {
            StrCat(value, valueLen, ",");
        }

        StrCat(value, valueLen, groupName);
    }
}

static void ParseDisabledGroupCookieValue(int client, const char[] rawValue)
{
    ResetClientDisabledGroups(client);

    if (!rawValue[0])
    {
        return;
    }

    char working[MAX_GROUP_PREF_VALUE];
    strcopy(working, sizeof(working), rawValue);
    TrimString(working);
    Strings_ToLower(working, sizeof(working));

    if (!working[0])
    {
        return;
    }

    char token[MAX_GROUP_NAME];
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
            Strings_ToLower(token, sizeof(token));

            if (token[0] && !StrEqual(token, DEFAULT_GROUP) && IsKnownGroup(token))
            {
                SetClientGroupDisabled(client, token, true);
            }
        }

        start = end + 1;
        if (start > len)
        {
            break;
        }
    }
}

static void ShowGroupOptionsMenu(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (!gConfigLoaded || gGroupNames == null)
    {
        PrintToChat(client, "[SaySounds] Sounds are not ready yet. Try again soon.");
        return;
    }

    Menu menu = new Menu(MenuHandler_GroupOptions);
    menu.SetTitle("SaySound Groups");

    char groupName[MAX_GROUP_NAME];
    char display[128];
    int itemCount = 0;

    for (int i = 0; i < gGroupNames.Length; i++)
    {
        gGroupNames.GetString(i, groupName, sizeof(groupName));
        if (StrEqual(groupName, DEFAULT_GROUP))
        {
            continue;
        }

        Format(display, sizeof(display), "%s (%s)", groupName, IsClientGroupDisabled(client, groupName) ? "disabled" : "enabled");
        menu.AddItem(groupName, display);
        itemCount++;
    }

    if (itemCount == 0)
    {
        delete menu;
        PrintToChat(client, "[SaySounds] No sound groups are configured.");
        return;
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_GroupOptions(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            return 0;
        }

        char groupName[MAX_GROUP_NAME];
        menu.GetItem(item, groupName, sizeof(groupName));

        bool disabled = !IsClientGroupDisabled(client, groupName);
        if (SetClientGroupDisabled(client, groupName, disabled))
        {
            SaveDisabledGroupPreferences(client);
            PrintToChat(client, "[SaySounds] Group %s %s.", groupName, disabled ? "disabled" : "enabled");
        }

        ShowGroupOptionsMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
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
        Strings_ToLower(arg, sizeof(arg));

        if (StrEqual(arg, "off") || StrEqual(arg, "mute") || StrEqual(arg, "none"))
        {
            g_fClientVolume[client] = 0.0;
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds muted.");
            return Plugin_Handled;
        }

        if (StrEqual(arg, "on"))
        {
            ResetClientDisabledGroups(client);
            SaveDisabledGroupPreferences(client);
            g_fClientVolume[client] = GetOptInVolume();
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
            return Plugin_Handled;
        }

        if (StrEqual(arg, DEFAULT_GROUP))
        {
            ResetClientDisabledGroups(client);
            SaveDisabledGroupPreferences(client);
            g_fClientVolume[client] = GetOptInVolume();
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
            return Plugin_Handled;
        }

        if (!arg[0] || !IsKnownGroup(arg))
        {
            PrintToChat(client, "[SaySounds] Unknown sound group.");
            return Plugin_Handled;
        }

        bool disabled = !IsClientGroupDisabled(client, arg);
        SetClientGroupDisabled(client, arg, disabled);
        SaveDisabledGroupPreferences(client);
        PrintToChat(client, "[SaySounds] Group %s %s.", arg, disabled ? "disabled" : "enabled");
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
            g_fClientVolume[client] = GetOptInVolume();
            SaveVolumePreference(client);
            PrintToChat(client, "[SaySounds] Say sounds enabled.");
        }
    }

    return Plugin_Handled;
}

public Action Command_ShowGroupOptions(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowGroupOptionsMenu(client);
    return Plugin_Handled;
}

enum SaySoundPreferenceType
{
    SaySoundPreference_Death = 0,
    SaySoundPreference_Kill
};

static void CopyStatsField(const char[] input, char[] output, int maxlen)
{
    int pos = 0;
    for (int i = 0; input[i] != '\0' && pos < maxlen - 1; i++)
    {
        char c = input[i];
        if (c == '|' || c == '\n' || c == '\r' || c == '\t')
        {
            c = ' ';
        }
        output[pos++] = c;
    }
    output[pos] = '\0';
    TrimString(output);
}

static void LogSaySoundUsage(const char[] eventName, int sourceClient, int targetClient, const char[] selectedCommand, const char[] soundPath, const char[] groupName, bool fromGroup, const char[] sourceGroup, bool fromApi, const char[] source)
{
    if (!ShouldLogSaySoundUsage())
    {
        return;
    }

    char steamId[KOGASA_STEAMID_MAX];
    if (!Kogasa_GetClientSteamId64(sourceClient, steamId, sizeof(steamId), false))
    {
        steamId[0] = '\0';
    }

    char safeCommand[MAX_COMMAND_NAME];
    char safePath[PLATFORM_MAX_PATH];
    char safeGroup[MAX_GROUP_NAME];
    char safeSourceGroup[MAX_GROUP_NAME];
    char safeSource[32];
    CopyStatsField(selectedCommand, safeCommand, sizeof(safeCommand));
    CopyStatsField(soundPath, safePath, sizeof(safePath));
    CopyStatsField(groupName, safeGroup, sizeof(safeGroup));
    CopyStatsField(sourceGroup, safeSourceGroup, sizeof(safeSourceGroup));
    CopyStatsField(source, safeSource, sizeof(safeSource));

    char message[512];
    Format(message, sizeof(message),
        "event=%s|steamid64=%s|client=%d|userid=%d|target_client=%d|sound=%s|path=%s|group=%s|from_group=%d|source_group=%s|from_api=%d|source=%s",
        eventName,
        steamId,
        sourceClient,
        (sourceClient > 0 && sourceClient <= MaxClients) ? GetClientUserId(sourceClient) : 0,
        targetClient,
        safeCommand,
        safePath,
        safeGroup,
        fromGroup ? 1 : 0,
        safeSourceGroup,
        fromApi ? 1 : 0,
        safeSource);
    PluginStats_Record(eventName, message);
}

static bool ShouldLogSaySoundUsage()
{
    g_iSaySoundStatsCounter++;
    if (g_iSaySoundStatsCounter >= SAYSOUNDS_STATS_SAMPLE_RATE)
    {
        g_iSaySoundStatsCounter = 0;
        return true;
    }

    return false;
}

static void LogSoundPreferenceChange(int client, SaySoundPreferenceType type, const char[] value)
{
    char steamId[KOGASA_STEAMID_MAX];
    if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId), false))
    {
        steamId[0] = '\0';
    }

    char safeValue[MAX_COMMAND_NAME * 4];
    CopyStatsField(value, safeValue, sizeof(safeValue));

    char message[384];
    Format(message, sizeof(message),
        "event=%s|steamid64=%s|client=%d|userid=%d|value=%s|cleared=%d",
        type == SaySoundPreference_Death ? "diesound_preference_changed" : "killsound_preference_changed",
        steamId,
        client,
        GetClientUserId(client),
        safeValue,
        safeValue[0] ? 0 : 1);
    PluginStats_Record(
        type == SaySoundPreference_Death
            ? "diesound_preference_changed"
            : "killsound_preference_changed",
        message);
}

static void GetClientSoundPreferenceValue(int client, SaySoundPreferenceType type, char[] value, int valueLen)
{
    if (type == SaySoundPreference_Death)
    {
        strcopy(value, valueLen, g_szDeathSound[client]);
        return;
    }

    strcopy(value, valueLen, g_szKillSound[client]);
}

static void SetClientSoundPreferenceValue(int client, SaySoundPreferenceType type, const char[] value)
{
    if (type == SaySoundPreference_Death)
    {
        strcopy(g_szDeathSound[client], sizeof(g_szDeathSound[]), value);
        SaveDeathSoundPreference(client);
        return;
    }

    strcopy(g_szKillSound[client], sizeof(g_szKillSound[]), value);
    SaveKillSoundPreference(client);
}

static bool PreferenceListHasCommand(const char[] preferenceValue, const char[] commandName)
{
    if (!preferenceValue[0] || !commandName[0])
    {
        return false;
    }

    char working[MAX_COMMAND_NAME * 4];
    strcopy(working, sizeof(working), preferenceValue);
    TrimString(working);
    Strings_ToLower(working, sizeof(working));

    char normalizedCommand[MAX_COMMAND_NAME];
    strcopy(normalizedCommand, sizeof(normalizedCommand), commandName);
    TrimString(normalizedCommand);
    Strings_ToLower(normalizedCommand, sizeof(normalizedCommand));

    char token[MAX_COMMAND_NAME];
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
            Strings_ToLower(token, sizeof(token));

            if (StrEqual(token, normalizedCommand))
            {
                return true;
            }
        }

        start = end + 1;
        if (start > len)
        {
            break;
        }
    }

    return false;
}

static int CountSelectedPreferenceCommands(const char[] preferenceValue)
{
    if (!preferenceValue[0])
    {
        return 0;
    }

    int count = 0;
    char token[MAX_COMMAND_NAME];
    char working[MAX_COMMAND_NAME * 4];
    strcopy(working, sizeof(working), preferenceValue);
    TrimString(working);
    Strings_ToLower(working, sizeof(working));

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
                count++;
            }
        }

        start = end + 1;
        if (start > len)
        {
            break;
        }
    }

    return count;
}

static bool ToggleClientSoundPreferenceCommand(int client, SaySoundPreferenceType type, const char[] commandName, char[] updatedValue, int updatedLen)
{
    updatedValue[0] = '\0';

    if (client <= 0 || client > MaxClients || !commandName[0] || !gConfigLoaded)
    {
        return false;
    }

    char currentValue[MAX_COMMAND_NAME * 4];
    GetClientSoundPreferenceValue(client, type, currentValue, sizeof(currentValue));

    bool currentlyEnabled = PreferenceListHasCommand(currentValue, commandName);
    int enabledCount = CountSelectedPreferenceCommands(currentValue);
    if (!currentlyEnabled && enabledCount >= MAX_SOUND_OPTIONS)
    {
        return false;
    }

    char rebuilt[MAX_COMMAND_NAME * 4];
    rebuilt[0] = '\0';

    char currentCommand[MAX_COMMAND_NAME];
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, currentCommand, sizeof(currentCommand));
        if (!CanClientUseSaySoundCommand(client, currentCommand))
        {
            continue;
        }

        bool shouldEnable = PreferenceListHasCommand(currentValue, currentCommand);
        if (StrEqual(currentCommand, commandName))
        {
            shouldEnable = !currentlyEnabled;
        }

        if (!shouldEnable)
        {
            continue;
        }

        int currentLen = strlen(rebuilt);
        int needed = strlen(currentCommand) + (currentLen > 0 ? 1 : 0);
        if (currentLen + needed >= sizeof(rebuilt))
        {
            return false;
        }

        if (currentLen > 0)
        {
            StrCat(rebuilt, sizeof(rebuilt), ",");
        }

        StrCat(rebuilt, sizeof(rebuilt), currentCommand);
    }

    SetClientSoundPreferenceValue(client, type, rebuilt);
    strcopy(updatedValue, updatedLen, rebuilt);
    return true;
}

static bool GetCommandGroupName(const char[] commandName, char[] groupName, int groupLen)
{
    if (!gSoundGroupMap.GetString(commandName, groupName, groupLen))
    {
        strcopy(groupName, groupLen, DEFAULT_GROUP);
    }

    return groupName[0] != '\0';
}

static bool IsCommandInSoundGroup(const char[] commandName, const char[] groupName)
{
    char commandGroup[MAX_GROUP_NAME];
    GetCommandGroupName(commandName, commandGroup, sizeof(commandGroup));
    return StrEqual(commandGroup, groupName);
}

static bool CanShowSoundPreferenceGroupInMenu(int client, const char[] groupName)
{
    return !IsGroupAdminOnly(groupName) && CanClientUseSaySoundGroup(client, groupName);
}

static bool CanShowSoundPreferenceCommandInMenu(int client, const char[] commandName)
{
    char groupName[MAX_GROUP_NAME];
    GetCommandGroupName(commandName, groupName, sizeof(groupName));
    return CanShowSoundPreferenceGroupInMenu(client, groupName);
}

static bool GetSoundPreferenceGroupState(int client, const char[] preferenceValue, const char[] groupName, bool &anyEnabled, bool &allEnabled)
{
    anyEnabled = false;
    allEnabled = true;

    if (!groupName[0] || StrEqual(groupName, DEFAULT_GROUP) || !IsKnownGroup(groupName) || !CanClientUseSaySoundGroup(client, groupName))
    {
        return false;
    }

    bool foundAny = false;
    char currentCommand[MAX_COMMAND_NAME];
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, currentCommand, sizeof(currentCommand));
        if (!IsCommandInSoundGroup(currentCommand, groupName) || !CanShowSoundPreferenceCommandInMenu(client, currentCommand))
        {
            continue;
        }

        foundAny = true;
        if (PreferenceListHasCommand(preferenceValue, currentCommand))
        {
            anyEnabled = true;
        }
        else
        {
            allEnabled = false;
        }
    }

    if (!foundAny)
    {
        allEnabled = false;
        return false;
    }

    return true;
}

static bool ToggleClientSoundPreferenceGroup(int client, SaySoundPreferenceType type, const char[] groupName, char[] updatedValue, int updatedLen)
{
    updatedValue[0] = '\0';

    if (client <= 0 || client > MaxClients || !groupName[0] || !gConfigLoaded)
    {
        return false;
    }

    char currentValue[MAX_COMMAND_NAME * 4];
    GetClientSoundPreferenceValue(client, type, currentValue, sizeof(currentValue));

    bool anyEnabled;
    bool allEnabled;
    if (!GetSoundPreferenceGroupState(client, currentValue, groupName, anyEnabled, allEnabled))
    {
        return false;
    }

    bool enableGroup = !allEnabled;
    char rebuilt[MAX_COMMAND_NAME * 4];
    rebuilt[0] = '\0';
    int validCount = 0;
    bool anyInvalid = false;

    char currentCommand[MAX_COMMAND_NAME];
    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, currentCommand, sizeof(currentCommand));
        if (!CanClientUseSaySoundCommand(client, currentCommand))
        {
            continue;
        }

        bool shouldEnable = PreferenceListHasCommand(currentValue, currentCommand);
        if (IsCommandInSoundGroup(currentCommand, groupName))
        {
            shouldEnable = enableGroup;
        }

        if (!shouldEnable)
        {
            continue;
        }

        if (!AppendSoundPreferenceCommand(client, currentCommand, rebuilt, sizeof(rebuilt), validCount, anyInvalid))
        {
            return false;
        }
    }

    SetClientSoundPreferenceValue(client, type, rebuilt);
    strcopy(updatedValue, updatedLen, rebuilt);
    return true;
}

static void BuildSoundPreferenceGroupMenuItem(const char[] groupName, char[] itemInfo, int itemLen)
{
    Format(itemInfo, itemLen, "%s%s", SOUND_PREF_GROUP_ITEM_PREFIX, groupName);
}

static bool GetSoundPreferenceGroupFromMenuItem(const char[] itemInfo, char[] groupName, int groupLen)
{
    groupName[0] = '\0';

    if (!Strings_StartsWith(itemInfo, SOUND_PREF_GROUP_ITEM_PREFIX))
    {
        return false;
    }

    Strings_CopyFrom(itemInfo, strlen(SOUND_PREF_GROUP_ITEM_PREFIX), groupName, groupLen);
    TrimString(groupName);
    Strings_ToLower(groupName, groupLen);
    return groupName[0] != '\0';
}

static void AddSoundPreferenceGroupMenuItems(Menu menu, int client, const char[] currentValue, bool paidOnly)
{
    char groupName[MAX_GROUP_NAME];
    char display[128];

    for (int i = 0; i < gGroupNames.Length; i++)
    {
        gGroupNames.GetString(i, groupName, sizeof(groupName));
        if (StrEqual(groupName, DEFAULT_GROUP) || IsGroupPaid(groupName) != paidOnly || !CanShowSoundPreferenceGroupInMenu(client, groupName))
        {
            continue;
        }

        bool anyEnabled;
        bool allEnabled;
        if (!GetSoundPreferenceGroupState(client, currentValue, groupName, anyEnabled, allEnabled))
        {
            continue;
        }

        char itemInfo[MAX_COMMAND_NAME];
        BuildSoundPreferenceGroupMenuItem(groupName, itemInfo, sizeof(itemInfo));
        Format(display, sizeof(display), "%s group (%s)", groupName, allEnabled ? "enabled" : (anyEnabled ? "partial" : "disabled"));
        menu.AddItem(itemInfo, display);
    }
}

static void AddSoundPreferenceCommandMenuItems(Menu menu, int client, const char[] currentValue, bool paidOnly)
{
    char commandName[MAX_COMMAND_NAME];
    char groupName[MAX_GROUP_NAME];
    char display[128];

    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, commandName, sizeof(commandName));
        if (!gSoundGroupMap.GetString(commandName, groupName, sizeof(groupName)))
        {
            strcopy(groupName, sizeof(groupName), DEFAULT_GROUP);
        }

        if (IsGroupPaid(groupName) != paidOnly || !CanShowSoundPreferenceGroupInMenu(client, groupName))
        {
            continue;
        }

        Format(display, sizeof(display), "%s (%s)", commandName, PreferenceListHasCommand(currentValue, commandName) ? "enabled" : "disabled");
        menu.AddItem(commandName, display);
    }
}

static void ShowSoundPreferenceMenu(int client, SaySoundPreferenceType type)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (!gConfigLoaded)
    {
        PrintToChat(client, "[SaySounds] Sounds are not ready yet. Try again soon.");
        return;
    }

    char currentValue[MAX_COMMAND_NAME * 4];
    GetClientSoundPreferenceValue(client, type, currentValue, sizeof(currentValue));

    Menu menu = new Menu(type == SaySoundPreference_Death ? MenuHandler_DeathSounds : MenuHandler_KillSounds);

    char title[192];
    Format(title, sizeof(title), "%s Sounds (current: %s)",
        type == SaySoundPreference_Death ? "Death" : "Kill",
        currentValue[0] ? currentValue : "none");
    menu.SetTitle(title);

    AddSoundPreferenceGroupMenuItems(menu, client, currentValue, true);
    AddSoundPreferenceCommandMenuItems(menu, client, currentValue, true);
    AddSoundPreferenceCommandMenuItems(menu, client, currentValue, false);
    AddSoundPreferenceGroupMenuItems(menu, client, currentValue, false);

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

static int HandleSoundPreferenceMenu(Menu menu, MenuAction action, int client, int item, SaySoundPreferenceType type)
{
    if (action == MenuAction_Select)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            return 0;
        }

        char itemInfo[MAX_COMMAND_NAME];
        menu.GetItem(item, itemInfo, sizeof(itemInfo));

        char updatedValue[MAX_COMMAND_NAME * 4];
        char groupName[MAX_GROUP_NAME];
        bool success;
        if (GetSoundPreferenceGroupFromMenuItem(itemInfo, groupName, sizeof(groupName)))
        {
            success = ToggleClientSoundPreferenceGroup(client, type, groupName, updatedValue, sizeof(updatedValue));
        }
        else
        {
            success = ToggleClientSoundPreferenceCommand(client, type, itemInfo, updatedValue, sizeof(updatedValue));
        }

        if (!success)
        {
            PrintToChat(client, "[SaySounds] You can only store up to %d sounds.", MAX_SOUND_OPTIONS);
        }
        else
        {
            PrintToChat(client, "[SaySounds] %s sound list updated: %s",
                type == SaySoundPreference_Death ? "Death" : "Kill",
                updatedValue[0] ? updatedValue : "none");
            LogSoundPreferenceChange(client, type, updatedValue);
        }

        ShowSoundPreferenceMenu(client, type);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public int MenuHandler_DeathSounds(Menu menu, MenuAction action, int client, int item)
{
    return HandleSoundPreferenceMenu(menu, action, client, item, SaySoundPreference_Death);
}

public int MenuHandler_KillSounds(Menu menu, MenuAction action, int client, int item)
{
    return HandleSoundPreferenceMenu(menu, action, client, item, SaySoundPreference_Kill);
}

public Action Command_ShowDeathSoundsMenu(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowSoundPreferenceMenu(client, SaySoundPreference_Death);
    return Plugin_Handled;
}

public Action Command_ShowKillSoundsMenu(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    ShowSoundPreferenceMenu(client, SaySoundPreference_Kill);
    return Plugin_Handled;
}

public Action Command_ListSounds(int client, int args)
{
    if (client <= 0)
    {
        PrintSaySoundGroups(client);
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
            PrintToServer("[SaySounds] %s!%s -> %s [%s]", IsGroupPaid(group) ? "[!shop] " : "", command, sound, group);
        }
        return Plugin_Handled;
    }

    if (!IsClientInGame(client))
        return Plugin_Handled;

    PrintSaySoundGroups(client);
    PrintToChat(client, "[SaySounds] Available commands:");
    PrintToChat(client, "[SaySounds] (Use !opt to mute/unmute, !opts for group toggles, !vol <0.0-1.0> for custom volume)");
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
        PrintToChat(client, "%s!%s -> %s [%s]", IsGroupPaid(group) ? "[!shop] " : "", command, sound, group);
    }

    return Plugin_Handled;
}

public Action Command_ListGroups(int client, int args)
{
    if (client > 0 && !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    PrintSaySoundGroups(client);
    return Plugin_Handled;
}

void PrintSaySoundGroups(int client)
{
    int displayIndex = 1;
    char groupName[MAX_GROUP_NAME];

    for (int i = 0; i < gGroupNames.Length; i++)
    {
        gGroupNames.GetString(i, groupName, sizeof(groupName));
        if (StrEqual(groupName, DEFAULT_GROUP))
        {
            continue;
        }

        if (client <= 0)
        {
            PrintToServer("%sgroup %d - %s", IsGroupPaid(groupName) ? "[!shop] " : "", displayIndex, groupName);
        }
        else
        {
            PrintToChat(client, "%sgroup %d - %s", IsGroupPaid(groupName) ? "[!shop] " : "", displayIndex, groupName);
        }

        displayIndex++;
    }

    if (displayIndex == 1)
    {
        if (client <= 0)
        {
            PrintToServer("[SaySounds] No sound groups are configured.");
        }
        else
        {
            PrintToChat(client, "[SaySounds] No sound groups are configured.");
        }
    }
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
        Strings_ToLower(groupName, sizeof(groupName));
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

    if (IsGroupPaid(groupName))
    {
        return 0;
    }

    PrecacheSound(soundPath, true);
    if (PlaySaySound(soundPath, groupName))
    {
        LogSaySoundUsage("saysound_used", 0, 0, "", soundPath, groupName, false, "", true, "api_sound");
    }
    return 0;
}

public int Native_PlayCommand(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 0 || client > MaxClients)
    {
        return 0;
    }

    bool forcePlayback = false;
    if (numParams >= 3)
    {
        forcePlayback = view_as<bool>(GetNativeCell(3));
    }

    bool bypassAdminOnly = true;
    if (numParams >= 4)
    {
        bypassAdminOnly = view_as<bool>(GetNativeCell(4));
    }

    char commandName[MAX_COMMAND_NAME * 4];
    GetNativeString(2, commandName, sizeof(commandName));
    TrimString(commandName);
    Strings_ToLower(commandName, sizeof(commandName));

    if (!commandName[0])
    {
        return 0;
    }

    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    bool restricted = false;
    bool paidRestricted = false;
    if (!GetCommandSoundDataForClientEx(client, commandName, soundPath, sizeof(soundPath), groupName, sizeof(groupName), restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup), bypassAdminOnly))
    {
        return 0;
    }

    PrecacheSound(soundPath, true);
    bool played = PlaySaySoundToTarget(client, soundPath, groupName, forcePlayback);
    if (played)
    {
        LogSaySoundUsage("saysound_used", client, client, selectedCommand, soundPath, groupName, fromGroup, sourceGroup, true, "api_command");
    }
    return played ? 1 : 0;
}

public int Native_PlayCommandAs(Handle plugin, int numParams)
{
    int sourceClient = GetNativeCell(1);
    int targetClient = GetNativeCell(2);
    if (sourceClient <= 0 || sourceClient > MaxClients || !IsClientInGame(sourceClient))
    {
        return 0;
    }
    if (targetClient < 0 || targetClient > MaxClients)
    {
        return 0;
    }

    bool forcePlayback = false;
    if (numParams >= 4)
    {
        forcePlayback = view_as<bool>(GetNativeCell(4));
    }

    bool bypassAdminOnly = true;
    if (numParams >= 5)
    {
        bypassAdminOnly = view_as<bool>(GetNativeCell(5));
    }

    char commandName[MAX_COMMAND_NAME * 4];
    GetNativeString(3, commandName, sizeof(commandName));
    TrimString(commandName);
    Strings_ToLower(commandName, sizeof(commandName));

    if (!commandName[0])
    {
        return 0;
    }

    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    bool restricted = false;
    bool paidRestricted = false;
    if (!GetCommandSoundDataForClientEx(sourceClient, commandName, soundPath, sizeof(soundPath), groupName, sizeof(groupName), restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup), bypassAdminOnly))
    {
        return 0;
    }

    PrecacheSound(soundPath, true);
    bool played = PlaySaySoundToTarget(targetClient, soundPath, groupName, forcePlayback);
    if (played)
    {
        LogSaySoundUsage("saysound_used", sourceClient, targetClient, selectedCommand, soundPath, groupName, fromGroup, sourceGroup, true, "api_command_as");
    }
    return played ? 1 : 0;
}

public int Native_CanClientUseCommand(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return 0;
    }

    char commandName[MAX_COMMAND_NAME * 4];
    GetNativeString(2, commandName, sizeof(commandName));
    TrimString(commandName);
    Strings_ToLower(commandName, sizeof(commandName));

    bool bypassAdminOnly = true;
    if (numParams >= 3)
    {
        bypassAdminOnly = view_as<bool>(GetNativeCell(3));
    }

    return CanClientUseSaySoundInput(client, commandName, bypassAdminOnly);
}

public int Native_IsCommandPaid(Handle plugin, int numParams)
{
    char commandName[MAX_COMMAND_NAME * 4];
    GetNativeString(1, commandName, sizeof(commandName));
    TrimString(commandName);
    Strings_ToLower(commandName, sizeof(commandName));

    return IsSaySoundInputPaid(commandName);
}

public int Native_GetCommandGroup(Handle plugin, int numParams)
{
    char commandName[MAX_COMMAND_NAME * 4];
    GetNativeString(1, commandName, sizeof(commandName));
    TrimString(commandName);
    Strings_ToLower(commandName, sizeof(commandName));

    char groupName[MAX_GROUP_NAME];
    bool found = GetSaySoundInputGroup(commandName, groupName, sizeof(groupName));

    int groupLen = GetNativeCell(3);
    if (groupLen > 0)
    {
        SetNativeString(2, found ? groupName : "", groupLen);
    }

    return found;
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

static bool AppendSoundPreferenceCommand(int client, const char[] commandName, char[] aggregated, int aggregatedLen, int &validCount, bool &anyInvalid)
{
    if (!CanClientUseSaySoundCommand(client, commandName))
    {
        anyInvalid = true;
        return false;
    }

    if (PreferenceListHasCommand(aggregated, commandName))
    {
        return true;
    }

    if (validCount >= MAX_SOUND_OPTIONS)
    {
        anyInvalid = true;
        return false;
    }

    int currentLen = strlen(aggregated);
    int needed = (currentLen > 0 ? 1 : 0) + strlen(commandName);
    if (currentLen + needed >= aggregatedLen - 1)
    {
        anyInvalid = true;
        return false;
    }

    if (currentLen > 0)
    {
        StrCat(aggregated, aggregatedLen, ",");
    }

    StrCat(aggregated, aggregatedLen, commandName);
    validCount++;
    return true;
}

static bool AppendSoundPreferenceGroup(int client, const char[] groupName, char[] aggregated, int aggregatedLen, int &validCount, bool &anyInvalid)
{
    char normalizedGroup[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalizedGroup, sizeof(normalizedGroup)))
    {
        anyInvalid = true;
        return false;
    }

    if (!CanClientUseSaySoundGroup(client, normalizedGroup))
    {
        anyInvalid = true;
        return false;
    }

    bool addedAny = false;
    char currentCommand[MAX_COMMAND_NAME];
    char currentGroup[MAX_GROUP_NAME];

    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, currentCommand, sizeof(currentCommand));
        if (!gSoundGroupMap.GetString(currentCommand, currentGroup, sizeof(currentGroup)))
        {
            strcopy(currentGroup, sizeof(currentGroup), DEFAULT_GROUP);
        }

        if (!StrEqual(currentGroup, normalizedGroup))
        {
            continue;
        }

        if (AppendSoundPreferenceCommand(client, currentCommand, aggregated, aggregatedLen, validCount, anyInvalid))
        {
            addedAny = true;
        }
    }

    if (!addedAny)
    {
        anyInvalid = true;
    }

    return addedAny;
}

static bool BuildSoundPreferenceList(int client, const char[] input, char[] aggregated, int aggregatedLen, bool &anyInvalid, bool allowGroups)
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
            Strings_ToLower(token, sizeof(token));

            if (token[0])
            {
                char path[PLATFORM_MAX_PATH];
                if (gSoundMap.GetString(token, path, sizeof(path)))
                {
                    AppendSoundPreferenceCommand(client, token, aggregated, aggregatedLen, validCount, anyInvalid);
                }
                else if (allowGroups)
                {
                    AppendSoundPreferenceGroup(client, token, aggregated, aggregatedLen, validCount, anyInvalid);
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
        PrintToChat(client, "[SaySounds] Usage: !diesound <command/group[,command/group...]|none> (current: %s)", g_szDeathSound[client][0] ? g_szDeathSound[client] : "none");
        return Plugin_Handled;
    }

    char buffer[256];
    GetCmdArgString(buffer, sizeof(buffer));
    TrimString(buffer);
    Strings_ToLower(buffer, sizeof(buffer));

    if (!buffer[0] || StrEqual(buffer, "none") || StrEqual(buffer, "off"))
    {
        g_szDeathSound[client][0] = '\0';
        SaveDeathSoundPreference(client);
        PrintToChat(client, "[SaySounds] Death sound cleared.");
        LogSoundPreferenceChange(client, SaySoundPreference_Death, "");
        return Plugin_Handled;
    }

    char aggregated[256];
    bool anyInvalid = false;
    if (!BuildSoundPreferenceList(client, buffer, aggregated, sizeof(aggregated), anyInvalid, true))
    {
        PrintToChat(client, "[SaySounds] No valid sounds supplied. Use !sounds to list commands.");
        return Plugin_Handled;
    }

    strcopy(g_szDeathSound[client], 256, aggregated);
    SaveDeathSoundPreference(client);
    PrintToChat(client, "[SaySounds] Death sound set to %s.", aggregated);
    LogSoundPreferenceChange(client, SaySoundPreference_Death, aggregated);
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
        PrintToChat(client, "[SaySounds] Usage: !killsound <command/group[,command/group...]|none> (current: %s)", g_szKillSound[client][0] ? g_szKillSound[client] : "none");
        return Plugin_Handled;
    }

    char buffer[256];
    GetCmdArgString(buffer, sizeof(buffer));
    TrimString(buffer);
    Strings_ToLower(buffer, sizeof(buffer));

    if (!buffer[0] || StrEqual(buffer, "none") || StrEqual(buffer, "off"))
    {
        g_szKillSound[client][0] = '\0';
        SaveKillSoundPreference(client);
        PrintToChat(client, "[SaySounds] Kill sound cleared.");
        LogSoundPreferenceChange(client, SaySoundPreference_Kill, "");
        return Plugin_Handled;
    }

    char aggregated[256];
    bool anyInvalid = false;
    if (!BuildSoundPreferenceList(client, buffer, aggregated, sizeof(aggregated), anyInvalid, true))
    {
        PrintToChat(client, "[SaySounds] No valid sounds supplied. Use !sounds to list commands.");
        return Plugin_Handled;
    }

    strcopy(g_szKillSound[client], 256, aggregated);  // FIXED: Changed from g_szDeathSound to g_szKillSound
    SaveKillSoundPreference(client);
    PrintToChat(client, "[SaySounds] Kill sound set to %s.", aggregated);
    LogSoundPreferenceChange(client, SaySoundPreference_Kill, aggregated);
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
        PrintToChat(client, "[SaySounds] Usage: !saysound <command|group>");
        return Plugin_Handled;
    }

    char arg[MAX_COMMAND_NAME * 4];
    GetCmdArgString(arg, sizeof(arg));
    StripQuotes(arg);
    TrimString(arg);
    Strings_ToLower(arg, sizeof(arg));

    if (!arg[0])
    {
        PrintToChat(client, "[SaySounds] Usage: !saysound <command|group>");
        return Plugin_Handled;
    }

    char path[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    bool restricted = false;
    bool paidRestricted = false;
    if (!GetCommandSoundDataForClientEx(client, arg, path, sizeof(path), groupName, sizeof(groupName), restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup)))
    {
        if (restricted)
        {
            PrintToChat(client, "[SaySounds] That sound group is admin-only.");
            return Plugin_Handled;
        }

        if (paidRestricted)
        {
            PrintToChat(client, "[SaySounds] That sound group requires a shop purchase. Use !shop.");
            return Plugin_Handled;
        }

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

    if (PlaySaySoundToTarget(0, path, groupName))
    {
        LogSaySoundUsage("saysound_used", client, 0, selectedCommand, path, groupName, fromGroup, sourceGroup, false, "command");
    }
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

float GetDefaultVolume()
{
    if (g_hDefaultVolume == null)
    {
        return 0.5;
    }

    float volume = g_hDefaultVolume.FloatValue;
    if (volume < MIN_VOLUME)
    {
        return MIN_VOLUME;
    }

    if (volume > MAX_VOLUME)
    {
        return MAX_VOLUME;
    }

    return volume;
}

float GetOptInVolume()
{
    float volume = GetDefaultVolume();
    if (volume <= 0.0)
    {
        return 0.5;
    }

    return volume;
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
    g_fClientVolume[client] = GetDefaultVolume();

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

void LoadDisabledGroupPreferences(int client)
{
    ResetClientDisabledGroups(client);

    if (g_hDisabledGroupsCookie == INVALID_HANDLE)
    {
        return;
    }

    char value[MAX_GROUP_PREF_VALUE];
    GetClientCookie(client, g_hDisabledGroupsCookie, value, sizeof(value));
    ParseDisabledGroupCookieValue(client, value);
}

void SaveDisabledGroupPreferences(int client)
{
    if (g_hDisabledGroupsCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
        return;

    char value[MAX_GROUP_PREF_VALUE];
    BuildDisabledGroupCookieValue(client, value, sizeof(value));
    SetClientCookie(client, g_hDisabledGroupsCookie, value);
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
    Strings_ToLower(working, sizeof(working));

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
                Strings_ToLower(token, sizeof(token));

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

static bool GetRandomCommandInGroupForClient(int client, const char[] groupName, char[] commandName, int commandLen, bool &restricted, bool &paidRestricted, bool bypassAdminOnly = false)
{
    if (commandLen > 0)
    {
        commandName[0] = '\0';
    }

    char normalizedGroup[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(groupName, normalizedGroup, sizeof(normalizedGroup)))
    {
        return false;
    }

    if (!CanClientUseAdminOnlySaySoundGroup(client, normalizedGroup, bypassAdminOnly))
    {
        restricted = true;
        return false;
    }

    if (!CanClientUsePaidSaysoundGroup(client, normalizedGroup))
    {
        paidRestricted = true;
        return false;
    }

    char currentCommand[MAX_COMMAND_NAME];
    char currentGroup[MAX_GROUP_NAME];
    int matchCount = 0;

    for (int i = 0; i < gCommandNames.Length; i++)
    {
        gCommandNames.GetString(i, currentCommand, sizeof(currentCommand));
        if (!gSoundGroupMap.GetString(currentCommand, currentGroup, sizeof(currentGroup)))
        {
            strcopy(currentGroup, sizeof(currentGroup), DEFAULT_GROUP);
        }

        if (!StrEqual(currentGroup, normalizedGroup))
        {
            continue;
        }

        matchCount++;
        if (GetRandomInt(1, matchCount) == 1)
        {
            strcopy(commandName, commandLen, currentCommand);
        }
    }

    return matchCount > 0 && commandName[0] != '\0';
}

static bool GetCommandOptionForClient(int client, const char[] inputName, char[] commandName, int commandLen, bool &restricted, bool &paidRestricted, bool bypassAdminOnly = false)
{
    bool fromGroup = false;
    char sourceGroup[MAX_GROUP_NAME];
    return GetCommandOptionForClientEx(client, inputName, commandName, commandLen, restricted, paidRestricted, fromGroup, sourceGroup, sizeof(sourceGroup), bypassAdminOnly);
}

static bool GetCommandOptionForClientEx(int client, const char[] inputName, char[] commandName, int commandLen, bool &restricted, bool &paidRestricted, bool &fromGroup, char[] sourceGroup, int sourceGroupLen, bool bypassAdminOnly = false)
{
    if (commandLen > 0)
    {
        commandName[0] = '\0';
    }
    fromGroup = false;
    if (sourceGroupLen > 0)
    {
        sourceGroup[0] = '\0';
    }

    char normalizedName[MAX_COMMAND_NAME];
    strcopy(normalizedName, sizeof(normalizedName), inputName);
    TrimString(normalizedName);
    Strings_ToLower(normalizedName, sizeof(normalizedName));

    if (!normalizedName[0])
    {
        return false;
    }

    char soundPath[PLATFORM_MAX_PATH];
    if (gSoundMap.GetString(normalizedName, soundPath, sizeof(soundPath)))
    {
        char groupName[MAX_GROUP_NAME];
        if (!gSoundGroupMap.GetString(normalizedName, groupName, sizeof(groupName)))
        {
            strcopy(groupName, sizeof(groupName), DEFAULT_GROUP);
        }

        if (!CanClientUseAdminOnlySaySoundGroup(client, groupName, bypassAdminOnly))
        {
            restricted = true;
            return false;
        }

        if (!CanClientUsePaidSaysoundGroup(client, groupName))
        {
            paidRestricted = true;
            return false;
        }

        strcopy(commandName, commandLen, normalizedName);
        return true;
    }

    char normalizedGroup[MAX_GROUP_NAME];
    if (!ResolveKnownGroupName(normalizedName, normalizedGroup, sizeof(normalizedGroup)))
    {
        return false;
    }

    if (!GetRandomCommandInGroupForClient(client, normalizedGroup, commandName, commandLen, restricted, paidRestricted, bypassAdminOnly))
    {
        return false;
    }

    fromGroup = true;
    strcopy(sourceGroup, sourceGroupLen, normalizedGroup);
    return true;
}

stock bool GetCommandSoundDataForClient(int client, const char[] commandNames, char[] soundPath, int soundLen, char[] groupName, int groupLen, bool &restricted, bool &paidRestricted, bool bypassAdminOnly = false)
{
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    return GetCommandSoundDataForClientEx(client, commandNames, soundPath, soundLen, groupName, groupLen, restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup), bypassAdminOnly);
}

static bool GetCommandSoundDataForClientEx(int client, const char[] commandNames, char[] soundPath, int soundLen, char[] groupName, int groupLen, bool &restricted, bool &paidRestricted, char[] selectedCommand, int selectedCommandLen, bool &fromGroup, char[] sourceGroup, int sourceGroupLen, bool bypassAdminOnly = false)
{
    restricted = false;
    paidRestricted = false;
    fromGroup = false;
    if (selectedCommandLen > 0)
    {
        selectedCommand[0] = '\0';
    }
    if (sourceGroupLen > 0)
    {
        sourceGroup[0] = '\0';
    }

    if (!gConfigLoaded)
    {
        return false;
    }

    char working[MAX_COMMAND_NAME * 4];
    strcopy(working, sizeof(working), commandNames);
    TrimString(working);
    Strings_ToLower(working, sizeof(working));

    if (!working[0])
    {
        return false;
    }

    if (StrContains(working, ",", false) == -1)
    {
        char chosen[MAX_COMMAND_NAME];
        if (!GetCommandOptionForClientEx(client, working, chosen, sizeof(chosen), restricted, paidRestricted, fromGroup, sourceGroup, sourceGroupLen, bypassAdminOnly))
        {
            return false;
        }

        if (!GetCommandSoundData(chosen, soundPath, soundLen, groupName, groupLen))
        {
            return false;
        }

        strcopy(selectedCommand, selectedCommandLen, chosen);
        return true;
    }

    char options[MAX_SOUND_OPTIONS][MAX_COMMAND_NAME];
    bool optionFromGroup[MAX_SOUND_OPTIONS];
    char optionSourceGroups[MAX_SOUND_OPTIONS][MAX_GROUP_NAME];
    int optionCount = 0;
    char token[MAX_COMMAND_NAME];
    int start = 0;
    int len = strlen(working);

    while (start < len && optionCount < MAX_SOUND_OPTIONS)
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
            Strings_ToLower(token, sizeof(token));

            if (token[0])
            {
                char chosen[MAX_COMMAND_NAME];
                bool currentFromGroup = false;
                char currentSourceGroup[MAX_GROUP_NAME];
                if (GetCommandOptionForClientEx(client, token, chosen, sizeof(chosen), restricted, paidRestricted, currentFromGroup, currentSourceGroup, sizeof(currentSourceGroup), bypassAdminOnly))
                {
                    strcopy(options[optionCount], sizeof(options[]), chosen);
                    optionFromGroup[optionCount] = currentFromGroup;
                    strcopy(optionSourceGroups[optionCount], sizeof(optionSourceGroups[]), currentSourceGroup);
                    optionCount++;
                }
            }
        }

        start = end + 1;
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
    if (!GetCommandSoundData(options[pick], soundPath, soundLen, groupName, groupLen))
    {
        return false;
    }

    strcopy(selectedCommand, selectedCommandLen, options[pick]);
    fromGroup = optionFromGroup[pick];
    strcopy(sourceGroup, sourceGroupLen, optionSourceGroups[pick]);
    return true;
}

static bool CanClientHearSaySoundGroup(int client, const char[] groupName)
{
    return !IsClientGroupDisabled(client, groupName);
}

static bool CanPlaySaySoundToClient(int client, const char[] groupName, float &emitVolume, bool forcePlayback = false)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return false;
    }

    if (forcePlayback || (g_hForce != null && g_hForce.BoolValue))
    {
        emitVolume = 1.0;
        return true;
    }

    emitVolume = GetClientVolume(client);
    if (emitVolume <= 0.0)
    {
        return false;
    }

    if (!CanClientHearSaySoundGroup(client, groupName))
    {
        return false;
    }

    return true;
}

static bool EmitSaySoundToClient(int client, const char[] soundPath, float emitVolume)
{
    if (emitVolume <= 0.0)
    {
        return false;
    }

    EmitSoundToClient(client, soundPath, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, emitVolume, SNDPITCH_NORMAL);
    return true;
}

static bool PlaySaySoundToTarget(int client, const char[] soundPath, const char[] groupName, bool forcePlayback = false)
{
    bool played = false;

    if (client == 0)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            float emitVolume;
            if (!CanPlaySaySoundToClient(i, groupName, emitVolume, forcePlayback))
            {
                continue;
            }

            if (EmitSaySoundToClient(i, soundPath, emitVolume))
            {
                played = true;
            }
        }

        return played;
    }

    float emitVolume;
    if (!CanPlaySaySoundToClient(client, groupName, emitVolume, forcePlayback))
    {
        return false;
    }

    return EmitSaySoundToClient(client, soundPath, emitVolume);
}

static bool PlaySaySound(const char[] soundPath, const char[] groupName)
{
    return PlaySaySoundToTarget(0, soundPath, groupName);
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
    Strings_ToLower(value, sizeof(value));

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
    Strings_ToLower(value, sizeof(value));

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

    if (attacker > 0 && attacker != victim && PlayWeaponKillSaySound(attacker))
    {
        return;
    }

    char victimPath[PLATFORM_MAX_PATH];
    char attackerPath[PLATFORM_MAX_PATH];
    char victimGroup[MAX_GROUP_NAME];
    char attackerGroup[MAX_GROUP_NAME];
    char victimCommand[MAX_COMMAND_NAME];
    char attackerCommand[MAX_COMMAND_NAME];
    char victimSourceGroup[MAX_GROUP_NAME];
    char attackerSourceGroup[MAX_GROUP_NAME];
    bool victimFromGroup = false;
    bool attackerFromGroup = false;
    bool haveVictim = false;
    bool haveAttacker = false;
    bool restricted = false;
    bool paidRestricted = false;

    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && attacker != victim && g_szKillSound[attacker][0])
    {
        haveAttacker = GetCommandSoundDataForClientEx(attacker, g_szKillSound[attacker], attackerPath, sizeof(attackerPath), attackerGroup, sizeof(attackerGroup), restricted, paidRestricted, attackerCommand, sizeof(attackerCommand), attackerFromGroup, attackerSourceGroup, sizeof(attackerSourceGroup));
    }

    if (victim > 0 && victim <= MaxClients && IsClientInGame(victim))
    {
        if (g_szDeathSound[victim][0])
        {
            haveVictim = GetCommandSoundDataForClientEx(victim, g_szDeathSound[victim], victimPath, sizeof(victimPath), victimGroup, sizeof(victimGroup), restricted, paidRestricted, victimCommand, sizeof(victimCommand), victimFromGroup, victimSourceGroup, sizeof(victimSourceGroup));
        }
        else if (!haveAttacker)
        {
            char defaultDeathCommand[MAX_COMMAND_NAME * 4];
            GetDefaultDeathSound(defaultDeathCommand, sizeof(defaultDeathCommand));
            if (defaultDeathCommand[0])
            {
                haveVictim = GetCommandSoundDataForClientEx(victim, defaultDeathCommand, victimPath, sizeof(victimPath), victimGroup, sizeof(victimGroup), restricted, paidRestricted, victimCommand, sizeof(victimCommand), victimFromGroup, victimSourceGroup, sizeof(victimSourceGroup));
            }
        }
    }

    if (haveVictim && haveAttacker)
    {
        if (GetRandomInt(0, 1) == 0)
        {
            if (PlaySaySound(victimPath, victimGroup))
            {
                LogSaySoundUsage("diesound_used", victim, 0, victimCommand, victimPath, victimGroup, victimFromGroup, victimSourceGroup, false, "diesound");
            }
        }
        else
        {
            if (PlaySaySound(attackerPath, attackerGroup))
            {
                LogSaySoundUsage("killsound_used", attacker, 0, attackerCommand, attackerPath, attackerGroup, attackerFromGroup, attackerSourceGroup, false, "killsound");
            }
        }
        return;
    }

    if (haveVictim)
    {
        if (PlaySaySound(victimPath, victimGroup))
        {
            LogSaySoundUsage("diesound_used", victim, 0, victimCommand, victimPath, victimGroup, victimFromGroup, victimSourceGroup, false, "diesound");
        }
    }
    else if (haveAttacker)
    {
        if (PlaySaySound(attackerPath, attackerGroup))
        {
            LogSaySoundUsage("killsound_used", attacker, 0, attackerCommand, attackerPath, attackerGroup, attackerFromGroup, attackerSourceGroup, false, "killsound");
        }
    }
}

void GetDefaultDeathSound(char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (g_hDefaultDeathSound != null)
    {
        g_hDefaultDeathSound.GetString(buffer, maxlen);
        TrimString(buffer);
    }
}

static bool GetWeaponKillSaySoundCommand(int attacker, char[] commandName, int maxlen)
{
    if (maxlen > 0)
    {
        commandName[0] = '\0';
    }

    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
    {
        return false;
    }

    int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
    if (weapon <= MaxClients || !IsValidEntity(weapon))
    {
        return false;
    }

    TF2CustAttr_GetString(weapon, SAYSOUND_ON_KILL_ATTR, commandName, maxlen);
    TrimString(commandName);
    Strings_ToLower(commandName, maxlen);

    return commandName[0] != '\0';
}

static bool PlayWeaponKillSaySound(int attacker)
{
    char commandName[MAX_COMMAND_NAME * 4];
    if (!GetWeaponKillSaySoundCommand(attacker, commandName, sizeof(commandName)))
    {
        return false;
    }

    char soundPath[PLATFORM_MAX_PATH];
    char groupName[MAX_GROUP_NAME];
    char selectedCommand[MAX_COMMAND_NAME];
    char sourceGroup[MAX_GROUP_NAME];
    bool fromGroup = false;
    bool restricted = false;
    bool paidRestricted = false;
    if (!GetCommandSoundDataForClientEx(attacker, commandName, soundPath, sizeof(soundPath), groupName, sizeof(groupName), restricted, paidRestricted, selectedCommand, sizeof(selectedCommand), fromGroup, sourceGroup, sizeof(sourceGroup)))
    {
        return false;
    }

    PrecacheSound(soundPath, true);
    if (!PlaySaySoundToTarget(0, soundPath, groupName))
    {
        return false;
    }

    LogSaySoundUsage("weapon_killsound_used", attacker, 0, selectedCommand, soundPath, groupName, fromGroup, sourceGroup, false, "weapon_killsound");
    return true;
}
