ConVar g_cvSetSetupTime;
ConVar g_cvAsymCapRespawn;
ConVar g_cvThreshold;
ConVar g_cvRedTime;
ConVar g_cvBluTime;
ConVar g_cvAutoAddTime;
ConVar g_cvTimeOverride;
ConVar g_cvRespawnTime;
bool g_bSymmetrical;
bool g_bRoundStartedOnce;

ConVar g_cHostname;
ConVar g_hVisibleMaxPlayers;

int g_PointCaptures;
bool g_InternalOverride; // For disabling this plugin's respawn time management in any case

ConVar g_cvGameMode;

// Add a ConVar to hook the value of mp_disable_respawn_times
Handle g_cvMpDisableRespawnTimes = INVALID_HANDLE;
Handle g_hSetupStateTimer = INVALID_HANDLE;
bool g_bSetupActive = false;
int g_iRoundStartTimestamp = 0;
int g_iRoundEndTimestamp = 0;
int g_iLastRoundDuration = 0;

public Plugin myinfo = {
    name = "Gamemode Detector",
    author = "Hombre",
    description = "Handles gamemode settings and instant respawns",
    version = PLUGIN_VERSION,
    url = "https://kogasa.tf"
};

int DGM_CountRealPlayers()
{
    return DGM_CountRealTeamPlayers(2) + DGM_CountRealTeamPlayers(3);
}

int DGM_CountRealTeamPlayers(int team)
{
    if (team != 2 && team != 3)
    {
        return 0;
    }

    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || IsFakeClient(client) || GetClientTeam(client) != team)
        {
            continue;
        }

        count++;
    }

    return count;
}

int DGM_GetServerCapacityValue()
{
    ConVar visibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
    int capacity = 0;
    if (visibleMaxPlayers != null)
    {
        capacity = visibleMaxPlayers.IntValue;
    }

    if (capacity <= 0)
    {
        capacity = MaxClients;
    }

    return capacity;
}

float DGM_GetPopulationRatioValue()
{
    int capacity = DGM_GetServerCapacityValue();
    if (capacity <= 0)
    {
        return 0.0;
    }

    return float(DGM_CountRealPlayers()) / float(capacity);
}

bool DGM_CheckServerCapacity(float capacityRatio = 0.50)
{
    if (capacityRatio < 0.0)
    {
        capacityRatio = 0.0;
    }
    else if (capacityRatio > 1.0)
    {
        capacityRatio = 1.0;
    }

    if (DGM_GetServerCapacityValue() <= 0)
    {
        return false;
    }

    return DGM_GetPopulationRatioValue() >= capacityRatio;
}

void DGM_CopyGameModeKeyForMap(const char[] mapName, char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, "default");

    if (StrContains(mapName, "ctf_", false) == 0)
    {
        strcopy(buffer, maxlen, "ctf");
        return;
    }
    if (StrContains(mapName, "cp_", false) == 0)
    {
        strcopy(buffer, maxlen, "cp");
        return;
    }
    if (StrContains(mapName, "pl_", false) == 0)
    {
        strcopy(buffer, maxlen, "pl");
        return;
    }
    if (StrContains(mapName, "plr_", false) == 0)
    {
        strcopy(buffer, maxlen, "plr");
        return;
    }
    if (StrContains(mapName, "koth_", false) == 0)
    {
        strcopy(buffer, maxlen, "koth");
        return;
    }
    if (StrContains(mapName, "pd_", false) == 0)
    {
        strcopy(buffer, maxlen, "pd");
        return;
    }
    if (StrContains(mapName, "sd_", false) == 0)
    {
        strcopy(buffer, maxlen, "sd");
        return;
    }
    if (StrContains(mapName, "arena_", false) == 0)
    {
        strcopy(buffer, maxlen, "arena");
        return;
    }
    if (StrContains(mapName, "vsh_", false) == 0)
    {
        strcopy(buffer, maxlen, "vsh");
        return;
    }
    if (StrContains(mapName, "ultiduo_", false) == 0)
    {
        strcopy(buffer, maxlen, "ultiduo");
        return;
    }
    if (StrContains(mapName, "mge_", false) == 0)
    {
        strcopy(buffer, maxlen, "mge");
        return;
    }
    if (StrContains(mapName, "mvm_", false) == 0)
    {
        strcopy(buffer, maxlen, "mvm");
        return;
    }
}

bool DGM_CopyNormalizedMapName(const char[] input, char[] output, int outputLen)
{
    if (outputLen <= 0)
    {
        return false;
    }

    strcopy(output, outputLen, input);
    ReplaceStringEx(output, outputLen, "workshop\\", "");
    ReplaceStringEx(output, outputLen, "workshop/", "");

    int slash = FindCharInString(output, '/', true);
    if (slash != -1 && output[slash + 1] != '\0')
    {
        strcopy(output, outputLen, output[slash + 1]);
    }

    int backslash = FindCharInString(output, '\\', true);
    if (backslash != -1 && output[backslash + 1] != '\0')
    {
        strcopy(output, outputLen, output[backslash + 1]);
    }

    int dot = FindCharInString(output, '.');
    if (dot > 0)
    {
        output[dot] = '\0';
    }

    TrimString(output);
    return output[0] != '\0';
}

bool DGM_CopyCurrentNormalizedMapName(char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return false;
    }

    char rawMapName[PLATFORM_MAX_PATH];
    GetCurrentMap(rawMapName, sizeof(rawMapName));
    return DGM_CopyNormalizedMapName(rawMapName, buffer, maxlen);
}

bool DGM_CopyCurrentGameModeKey(char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return false;
    }

    char mapName[PLATFORM_MAX_PATH];
    char normalizedMapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));
    DGM_CopyNormalizedMapName(mapName, normalizedMapName, sizeof(normalizedMapName));
    DGM_CopyGameModeKeyForMap(normalizedMapName, buffer, maxlen);
    return buffer[0] != '\0';
}

bool DGM_CopyCurrentGameMode(char[] buffer, int maxlen)
{
    if (maxlen <= 0)
    {
        return false;
    }

    buffer[0] = '\0';
    if (g_cvGameMode != null)
    {
        g_cvGameMode.GetString(buffer, maxlen);
    }

    if (!buffer[0])
    {
        strcopy(buffer, maxlen, "unknown");
    }

    return buffer[0] != '\0';
}

bool DGM_CheckSmallFormatGamemode()
{
    char gamemodeKey[32];
    if (DGM_CopyCurrentGameModeKey(gamemodeKey, sizeof(gamemodeKey)))
    {
        if (StrEqual(gamemodeKey, "arena", false)
            || StrEqual(gamemodeKey, "vsh", false)
            || StrEqual(gamemodeKey, "ultiduo", false)
            || StrEqual(gamemodeKey, "mge", false))
        {
            return true;
        }
    }

    if (g_cvGameMode == null)
    {
        return false;
    }

    char gamemode[64];
    g_cvGameMode.GetString(gamemode, sizeof(gamemode));
    return StrEqual(gamemode, "Arena", false)
        || StrEqual(gamemode, "vsh", false)
        || StrEqual(gamemode, "ultiduo", false)
        || StrEqual(gamemode, "mge", false);
}

bool DGM_ShouldDisableInstantRespawn()
{
    return DGM_CheckSmallFormatGamemode();
}

public any Native_DGM_GetGameMode(Handle plugin, int numParams)
{
    char gamemode[64];
    bool hasGamemode = DGM_CopyCurrentGameMode(gamemode, sizeof(gamemode));
    SetNativeString(1, gamemode, GetNativeCell(2), true);
    return hasGamemode;
}

public any Native_DGM_RealPlayerCount(Handle plugin, int numParams)
{
    return DGM_CountRealPlayers();
}

public any Native_DGM_GetGameModeKey(Handle plugin, int numParams)
{
    char gamemodeKey[32];
    bool hasGamemodeKey = DGM_CopyCurrentGameModeKey(gamemodeKey, sizeof(gamemodeKey));
    SetNativeString(1, gamemodeKey, GetNativeCell(2), true);
    return hasGamemodeKey;
}

public any Native_DGM_IsSmallFormatGamemode(Handle plugin, int numParams)
{
    return DGM_CheckSmallFormatGamemode();
}

public any Native_DGM_NormalizeMapName(Handle plugin, int numParams)
{
    char input[PLATFORM_MAX_PATH];
    char output[PLATFORM_MAX_PATH];
    GetNativeString(1, input, sizeof(input));
    bool hasMapName = DGM_CopyNormalizedMapName(input, output, sizeof(output));
    SetNativeString(2, output, GetNativeCell(3), true);
    return hasMapName;
}

public any Native_DGM_ServerCapacitycheck(Handle plugin, int numParams)
{
    float capacityRatio = 0.50;
    if (numParams >= 1)
    {
        capacityRatio = view_as<float>(GetNativeCell(1));
    }

    return DGM_CheckServerCapacity(capacityRatio);
}

public any Native_DGM_RealTeamPlayerCount(Handle plugin, int numParams)
{
    int team = GetNativeCell(1);
    return DGM_CountRealTeamPlayers(team);
}

public any Native_DGM_GetGameModeKeyForMap(Handle plugin, int numParams)
{
    char input[PLATFORM_MAX_PATH];
    char normalized[PLATFORM_MAX_PATH];
    char gamemodeKey[32];
    GetNativeString(1, input, sizeof(input));
    bool hasMapName = DGM_CopyNormalizedMapName(input, normalized, sizeof(normalized));
    if (hasMapName)
    {
        DGM_CopyGameModeKeyForMap(normalized, gamemodeKey, sizeof(gamemodeKey));
    }
    else
    {
        DGM_CopyGameModeKeyForMap(input, gamemodeKey, sizeof(gamemodeKey));
    }
    SetNativeString(2, gamemodeKey, GetNativeCell(3), true);
    return gamemodeKey[0] != '\0';
}

public any Native_DGM_CurrentNormalizedMap(Handle plugin, int numParams)
{
    char mapName[PLATFORM_MAX_PATH];
    bool hasMapName = DGM_CopyCurrentNormalizedMapName(mapName, sizeof(mapName));
    SetNativeString(1, mapName, GetNativeCell(2), true);
    return hasMapName;
}

public any Native_DGM_GetServerCapacity(Handle plugin, int numParams)
{
    return DGM_GetServerCapacityValue();
}

public any Native_DGM_GetPopulationRatio(Handle plugin, int numParams)
{
    return view_as<any>(DGM_GetPopulationRatioValue());
}

public any Native_DGM_IsRoundRunning(Handle plugin, int numParams)
{
    return DGM_InternalIsRoundRunning();
}

public any Native_DGM_GetLastRoundDurationSeconds(Handle plugin, int numParams)
{
    return g_iLastRoundDuration;
}

public any Native_DGM_GetRoundDurationSeconds(Handle plugin, int numParams)
{
    int firstTimestamp = GetNativeCell(1);
    int secondTimestamp = GetNativeCell(2);
    return DGM_CalculateRoundDurationSeconds(firstTimestamp, secondTimestamp);
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errMax)
{
    RegPluginLibrary("dgm");
    CreateNative("DGM_GetGameMode", Native_DGM_GetGameMode);
    CreateNative("DGM_RealPlayerCount", Native_DGM_RealPlayerCount);
    CreateNative("DGM_RealTeamPlayerCount", Native_DGM_RealTeamPlayerCount);
    CreateNative("DGM_GetGameModeKey", Native_DGM_GetGameModeKey);
    CreateNative("DGM_GetGameModeKeyForMap", Native_DGM_GetGameModeKeyForMap);
    CreateNative("DGM_IsSmallFormatGamemode", Native_DGM_IsSmallFormatGamemode);
    CreateNative("DGM_NormalizeMapName", Native_DGM_NormalizeMapName);
    CreateNative("DGM_CurrentNormalizedMap", Native_DGM_CurrentNormalizedMap);
    CreateNative("DGM_GetServerCapacity", Native_DGM_GetServerCapacity);
    CreateNative("DGM_GetPopulationRatio", Native_DGM_GetPopulationRatio);
    CreateNative("DGM_ServerCapacitycheck", Native_DGM_ServerCapacitycheck);
    CreateNative("DGM_IsRoundRunning", Native_DGM_IsRoundRunning);
    CreateNative("DGM_GetLastRoundDurationSeconds", Native_DGM_GetLastRoundDurationSeconds);
    CreateNative("DGM_GetRoundDurationSeconds", Native_DGM_GetRoundDurationSeconds);
    return APLRes_Success;
}

// I prefer the visual effect when TF2's mp_disable_respawn_times cvar is true but dislike that it can be exploited
// Also takes about 5~ seconds for the respawn to occur
void DGM_RefreshRespawnVisualState()
{
    if (g_cvMpDisableRespawnTimes == null)
    {
        return;
    }

    if (DGM_ShouldDisableInstantRespawn())
    {
        SetConVarInt(g_cvMpDisableRespawnTimes, 0);
        return;
    }

    float maxRespawn = GetConVarFloat(g_cvRespawnTime);
    float override = GetConVarFloat(g_cvTimeOverride);
    float redTime = GetConVarFloat(g_cvRedTime);
    float bluTime = GetConVarFloat(g_cvBluTime);

    if (override > maxRespawn)
    {
        maxRespawn = override;
    }
    if (redTime > maxRespawn)
    {
        maxRespawn = redTime;
    }
    if (bluTime > maxRespawn)
    {
        maxRespawn = bluTime;
    }

    if (maxRespawn > 5.0 || g_InternalOverride)
    {
        SetConVarInt(g_cvMpDisableRespawnTimes, 0);
    }
    else
    {
        SetConVarInt(g_cvMpDisableRespawnTimes, 1);
    }
}

bool DGM_InternalIsRoundRunning()
{
    return (GameRules_GetRoundState() == RoundState_RoundRunning);
}

int DGM_CalculateRoundDurationSeconds(int firstTimestamp, int secondTimestamp)
{
    if (firstTimestamp <= 0 || secondTimestamp <= firstTimestamp)
    {
        return 0;
    }

    return secondTimestamp - firstTimestamp;
}

void DGM_SetSetupActive(bool setupActive)
{
    if (g_bSetupActive == setupActive)
    {
        return;
    }

    g_bSetupActive = setupActive;
    if (setupActive)
    {
        PrintToChatAll("Setup detected, bhop enabled");
        ServerCommand("exec d_setup.cfg");
        if (g_hSetupStateTimer == INVALID_HANDLE)
        {
            g_hSetupStateTimer = CreateTimer(2.0, Timer_SetupStateMonitor, _, TIMER_REPEAT);
        }
    }
    else
    {
        ServerCommand("exec d_endsetup.cfg");
        if (g_hSetupStateTimer != INVALID_HANDLE)
        {
            KillTimer(g_hSetupStateTimer);
            g_hSetupStateTimer = INVALID_HANDLE;
        }
    }
}

void DGM_UpdateSetupState()
{
    DGM_SetSetupActive(!DGM_InternalIsRoundRunning());
}

public void SetSetupTime()
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt != -1)
    {
        int time = GetConVarInt(g_cvSetSetupTime);
        SetVariantInt(time);
        AcceptEntityInput(timerEnt, "SetTime");
        PrintToServer("[Kogasa] Setup time set to %i seconds.", time);
    }
}

public void AdjustByPlayerCount(any data)
{
    if (!g_bRoundStartedOnce)
    {
        return;
    }
    int playerCount = DGM_CountRealPlayers();
    int threshhold = GetConVarInt(g_cvThreshold);
    if (!g_bSymmetrical) {
        ServerCommand(playerCount > threshhold ? "exec d_highpop_a.cfg" : "exec d_lowpop_a.cfg");
    } else {
        ServerCommand(playerCount > threshhold ? "exec d_highpop.cfg" : "exec d_lowpop.cfg");
    }
}

bool IsValidClient(int client)
{
    return (client >= 1 && client <= MaxClients) && IsClientInGame(client);
}

void DetectGameMode()
{
    TF2_GameMode gameMode = TF2_DetectGameMode();
    CreateDefaultConfigs();
    bool sym = false;
    char modeName[32] = "unknown";
    char mapName[64];

    switch (gameMode)
    {
        case TF2_GameMode_Arena:
        {
            ServerCommand("exec d_arena.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "Arena");
        }
        case TF2_GameMode_Medieval:
        {
            ServerCommand("exec d_medieval.cfg");
            sym = false;
            strcopy(modeName, sizeof(modeName), "Medieval");
        }
        case TF2_GameMode_PD:
        {
            ServerCommand("exec d_pd.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "Player Destruction");
            // Issue: many of the modern Arena maps are using player destruction logic, I can try checking for both later
        }
        case TF2_GameMode_KOTH:
        {
            ServerCommand("exec d_koth.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "King of the Hill");
        }
        case TF2_GameMode_PL:
        {
            ServerCommand("exec d_payload.cfg");
            strcopy(modeName, sizeof(modeName), "Payload");
        }
        case TF2_GameMode_PLR:
        {
            ServerCommand("exec d_payloadrace.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "Payload Race");
        }
        case TF2_GameMode_CTF:
        {
            ServerCommand("exec d_ctf.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "Capture the Flag");
        }
        case TF2_GameMode_5CP:
        {
            ServerCommand("exec d_5cp.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "5 Control Points");
        }
        case TF2_GameMode_ADCP:
        {
            ServerCommand("exec d_adcp.cfg");
            strcopy(modeName, sizeof(modeName), "Attack/Defend CP");
        }
        case TF2_GameMode_TC:
        {
            ServerCommand("exec d_tc.cfg");
            strcopy(modeName, sizeof(modeName), "Territorial Control");
        }
        default:
        {
            ServerCommand("exec d_default.cfg");
            sym = true;
            strcopy(modeName, sizeof(modeName), "Default");
        }
    }

    GetCurrentMap(mapName, sizeof(mapName));
    if (StrContains(mapName, "vsh_", false) != -1)
    {
        strcopy(modeName, sizeof(modeName), "vsh");
    }
    else if (StrContains(mapName, "ultiduo_", false) != -1)
    {
        strcopy(modeName, sizeof(modeName), "ultiduo");
    }
    else if (StrContains(mapName, "mge_", false) != -1)
    {
        strcopy(modeName, sizeof(modeName), "mge");
    }

    g_bSymmetrical = sym;
    g_cvGameMode.SetString(modeName);
}

void CreateDefaultConfigs()
{
    char configNames[][] = {
        "d_arena.cfg",
        "d_koth.cfg", 
        "d_payload.cfg",
        "d_payloadrace.cfg",
        "d_ctf.cfg",
        "d_5cp.cfg",
        "d_adcp.cfg",
        "d_tc.cfg",
        "d_medieval.cfg",
        "d_pd.cfg",
        "d_default.cfg",
        "d_highpop_a.cfg",
        "d_highpop.cfg",
        "d_lowpop_a.cfg",
        "d_lowpop.cfg",
    };
    
    char configPath[PLATFORM_MAX_PATH];
    
    for (int i = 0; i < sizeof(configNames); i++)
    {
        BuildPath(Path_SM, configPath, sizeof(configPath), "../../cfg/%s", configNames[i]);
        if (!FileExists(configPath))
        {
            File file = OpenFile(configPath, "w");
            if (file != null)
            {
                file.WriteLine("// %s configuration", configNames[i]);
                file.WriteLine("// This file is auto-generated");
                file.WriteLine("");
                file.WriteLine("echo \"Executing %s\"", configNames[i]);
                file.Close();
                LogMessage("Created config file: %s", configPath);
            }
        }
    }
}
