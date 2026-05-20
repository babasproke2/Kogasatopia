#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <sdktools_gamerules>
#include <tf2_stocks>
#include <tf2>
#include <controlpoints>
// I forked the controlpoints file from powerlord to add new gamemodes, you can get it at https://github.com/babasproke2/sourcemod-snippets

#define PLUGIN_VERSION "4.3"

#include "include/dgm_api.inc"
#define DGM_MAX_CONTROL_POINTS 8

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

int g_PointCaptures;
bool g_InternalOverride; // For disabling this plugin's respawn time management in any case

ConVar g_cvGameMode;

// Add a ConVar to hook the value of mp_disable_respawn_times
Handle g_cvMpDisableRespawnTimes = INVALID_HANDLE;
Handle g_hSetupStateTimer = INVALID_HANDLE;
bool g_bSetupActive = false;
int g_iRoundStartTimestamp = 0;
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

DGMObjectiveLeader DGM_GetObjectiveLeaderValue(
    int &redOwned,
    int &blueOwned,
    int &neutralOwned,
    int &total)
{
    redOwned = 0;
    blueOwned = 0;
    neutralOwned = 0;
    total = 0;

    if (!DGM_CountObjectiveResourcePoints(redOwned, blueOwned, neutralOwned, total))
    {
        DGM_CountTeamControlPointEntities(redOwned, blueOwned, neutralOwned, total);
    }

    if (total <= 0)
    {
        return DGMObjectiveLeader_None;
    }

    if (redOwned > blueOwned)
    {
        return DGMObjectiveLeader_Red;
    }

    if (blueOwned > redOwned)
    {
        return DGMObjectiveLeader_Blue;
    }

    return DGMObjectiveLeader_Tie;
}

int DGM_GetObjectiveLeaderTeamValue()
{
    int redOwned, blueOwned, neutralOwned, total;
    DGMObjectiveLeader leader = DGM_GetObjectiveLeaderValue(redOwned, blueOwned, neutralOwned, total);

    if (leader == DGMObjectiveLeader_Red)
    {
        return view_as<int>(TFTeam_Red);
    }

    if (leader == DGMObjectiveLeader_Blue)
    {
        return view_as<int>(TFTeam_Blue);
    }

    return view_as<int>(TFTeam_Unassigned);
}

bool DGM_CountObjectiveResourcePoints(
    int &redOwned,
    int &blueOwned,
    int &neutralOwned,
    int &total)
{
    int objRes = FindEntityByClassname(-1, "tf_objective_resource");

    if (objRes == -1 || !IsValidEntity(objRes))
    {
        return false;
    }

    if (!HasEntProp(objRes, Prop_Send, "m_iNumControlPoints")
        || !HasEntProp(objRes, Prop_Send, "m_iOwner"))
    {
        return false;
    }

    int cpCount = GetEntProp(objRes, Prop_Send, "m_iNumControlPoints");

    if (cpCount <= 0)
    {
        return false;
    }

    if (cpCount > DGM_MAX_CONTROL_POINTS)
    {
        cpCount = DGM_MAX_CONTROL_POINTS;
    }

    bool haveVisibleProp = HasEntProp(objRes, Prop_Send, "m_bCPIsVisible");

    for (int pass = 0; pass < 2; pass++)
    {
        redOwned = 0;
        blueOwned = 0;
        neutralOwned = 0;
        total = 0;

        bool visibleOnly = (pass == 0 && haveVisibleProp);

        for (int i = 0; i < cpCount; i++)
        {
            if (visibleOnly)
            {
                int visible = GetEntProp(objRes, Prop_Send, "m_bCPIsVisible", 4, i);

                if (visible == 0)
                {
                    continue;
                }
            }

            int owner = GetEntProp(objRes, Prop_Send, "m_iOwner", 4, i);
            DGM_AddObjectiveOwnerToCounts(owner, redOwned, blueOwned, neutralOwned, total);
        }

        if (total > 0 || !haveVisibleProp)
        {
            return total > 0;
        }
    }

    return false;
}

void DGM_CountTeamControlPointEntities(
    int &redOwned,
    int &blueOwned,
    int &neutralOwned,
    int &total)
{
    redOwned = 0;
    blueOwned = 0;
    neutralOwned = 0;
    total = 0;

    int point = -1;

    while ((point = FindEntityByClassname(point, "team_control_point")) != -1)
    {
        if (!IsValidEntity(point))
        {
            continue;
        }

        int owner = DGM_GetControlPointEntityOwner(point);
        DGM_AddObjectiveOwnerToCounts(owner, redOwned, blueOwned, neutralOwned, total);
    }
}

int DGM_GetControlPointEntityOwner(int point)
{
    if (HasEntProp(point, Prop_Send, "m_iTeamNum"))
    {
        return GetEntProp(point, Prop_Send, "m_iTeamNum");
    }

    if (HasEntProp(point, Prop_Data, "m_iTeamNum"))
    {
        return GetEntProp(point, Prop_Data, "m_iTeamNum");
    }

    return view_as<int>(TFTeam_Unassigned);
}

void DGM_AddObjectiveOwnerToCounts(
    int owner,
    int &redOwned,
    int &blueOwned,
    int &neutralOwned,
    int &total)
{
    total++;

    if (owner == view_as<int>(TFTeam_Red))
    {
        redOwned++;
    }
    else if (owner == view_as<int>(TFTeam_Blue))
    {
        blueOwned++;
    }
    else
    {
        neutralOwned++;
    }
}

void DGM_ObjectiveLeaderToString(DGMObjectiveLeader leader, char[] buffer, int maxlen)
{
    switch (leader)
    {
        case DGMObjectiveLeader_Red:
        {
            strcopy(buffer, maxlen, "RED is leading by objective ownership");
        }
        case DGMObjectiveLeader_Blue:
        {
            strcopy(buffer, maxlen, "BLU is leading by objective ownership");
        }
        case DGMObjectiveLeader_Tie:
        {
            strcopy(buffer, maxlen, "Objective ownership is tied");
        }
        default:
        {
            strcopy(buffer, maxlen, "No objective leader");
        }
    }
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

public any Native_DGM_GetObjectiveLeader(Handle plugin, int numParams)
{
    int redOwned, blueOwned, neutralOwned, total;
    DGMObjectiveLeader leader = DGM_GetObjectiveLeaderValue(redOwned, blueOwned, neutralOwned, total);

    SetNativeCellRef(1, redOwned);
    SetNativeCellRef(2, blueOwned);
    SetNativeCellRef(3, neutralOwned);
    SetNativeCellRef(4, total);

    return view_as<any>(leader);
}

public any Native_DGM_GetObjectiveLeaderTeam(Handle plugin, int numParams)
{
    return DGM_GetObjectiveLeaderTeamValue();
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
    CreateNative("DGM_GetObjectiveLeader", Native_DGM_GetObjectiveLeader);
    CreateNative("DGM_GetObjectiveLeaderTeam", Native_DGM_GetObjectiveLeaderTeam);
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


public void OnPluginStart()
{
    // The respawn time
    g_cvRespawnTime = CreateConVar("respawn_time", "3.0", "Respawn time length", _, true, 0.0, true, 30.0);
    // See description
    g_cvThreshold = CreateConVar("sm_highpop_threshhold", "18.0", "Threshhold for executing the highpop config", _, true, 0.0, true, 100.0);
    // For micromanagement, if this convar isn't 0, it'll use the given time
    g_cvTimeOverride = CreateConVar("respawn_otime", "0", "Override respawn time with this", _, true, 0.0, true, 30.0);
    // Respawn times for individual teams (beta)
    g_cvRedTime = CreateConVar("respawn_redtime", "3.0", "Red respawn time length", _, true, 0.0, true, 16.0);
    g_cvBluTime = CreateConVar("respawn_blutime", "3.0", "Blu respawn time length", _, true, 0.0, true, 16.0);
    // Auto add time to king of the hill timers?
    g_cvAutoAddTime = CreateConVar("sm_autoaddtime", "300", "Automatically extend koth times? > 0 for the time in seconds");
    // Always respawn red team on control point capture in asymmetrical gamemodes?
    g_cvAsymCapRespawn = CreateConVar("respawn_red_on_cap", "0", "Override respawn times", _, true, 0.0, true, 1.0);
    // Change the setup time to this in asymmetrical gamemodes
    g_cvSetSetupTime = CreateConVar("sm_setuptime", "40", "Set setup time to X - 0 to disable management - only enable this per-map or in gamemode configs", _, true, 0.0, true,60.0);
    // Stores the executed gamemode
    g_cvGameMode = CreateConVar("sm_gamemode", "unknown", "Stores the executed gamemode", FCVAR_NONE);
    // Hook the value of mp_disable_respawn_times
    g_cvMpDisableRespawnTimes = FindConVar("mp_disable_respawn_times");
    HookConVarChange(g_cvRespawnTime, ConVarChange_RespawnSetting);
    HookConVarChange(g_cvTimeOverride, ConVarChange_RespawnSetting);
    HookConVarChange(g_cvRedTime, ConVarChange_RespawnSetting);
    HookConVarChange(g_cvBluTime, ConVarChange_RespawnSetting);

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("teamplay_round_start", Event_RoundActive);
    HookEvent("teamplay_setup_finished", Event_SetupFinished);
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_Pre);
    HookEvent("teamplay_point_captured", Event_PointCaptured, EventHookMode_PostNoCopy);

    RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_KICK, "Toggles respawn times");
    RegAdminCmd("sm_noset", Command_ResetSetup, ADMFLAG_KICK, "Set round setup time to 10 seconds");
    RegConsoleCmd("sm_extend", Command_ExtendTimer, "Increase round timer by 10 seconds");

    g_cHostname = FindConVar("hostname");
    RegConsoleCmd("sm_st", Command_Stats, "Show player count, map and hostname");
    RegConsoleCmd("sm_objectiveleader", Command_ObjectiveLeader, "Show which team leads by objective ownership");
    RegConsoleCmd("sm_cpleader", Command_ObjectiveLeader, "Show which team leads by control-point ownership");
    RegConsoleCmd("sm_manual", Command_CvarHelp, "Displays information about plugin ConVars.");
}

public void OnMapStart()
{
    if (g_hSetupStateTimer != INVALID_HANDLE)
    {
        KillTimer(g_hSetupStateTimer);
        g_hSetupStateTimer = INVALID_HANDLE;
    }

    g_bSetupActive = false;
    DGM_RefreshRespawnVisualState();
    DGM_UpdateSetupState();
}

public void ConVarChange_RespawnSetting(ConVar convar, const char[] oldValue, const char[] newValue)
{
    DGM_RefreshRespawnVisualState();
}

public Action Timer_SetupStateMonitor(Handle timer)
{
    if (DGM_InternalIsRoundRunning())
    {
        DGM_SetSetupActive(false);
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

// We can be sure entities are loaded by this point
public void OnConfigsExecuted()
{
    DetectGameMode();
    g_InternalOverride = false; // Reset this on map change
    g_bRoundStartedOnce = false;
    g_iRoundStartTimestamp = 0;
    g_iLastRoundDuration = 0;
}

// Fires when a control point is captured
public void Event_PointCaptured(Event event, const char[] name, bool dontBroadcast)
{
    if (DGM_ShouldDisableInstantRespawn())
    {
        return;
    }

    //This stuff is mostly WIP for dynamic changes on maps in the future
	// For now, all of these  features are from asymmetrical gamemode types
	if (!g_bSymmetrical)
	{
		g_PointCaptures++;
		if (g_PointCaptures >= 3)
		{
			g_InternalOverride = true; // Stop managing respawn times if approaching last
            DGM_RefreshRespawnVisualState();
		}
		// Asymmetrical: respawn all dead RED players
		if (GetConVarBool(g_cvAsymCapRespawn) && !g_bSymmetrical)
		{
			for (int i = 1; i <= MaxClients; i++)
				if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsPlayerAlive(i))
					TF2_RespawnPlayer(i);
		}
		return;
	}
}

public void OnClientPutInServer(int client)
{
    if (g_bRoundStartedOnce)
    {
        RequestFrame(AdjustByPlayerCount);
    }
}

public void OnClientDisconnect(int client)
{
    if (g_bRoundStartedOnce)
    {
        RequestFrame(AdjustByPlayerCount);
    }
}

// This command lets me see everything this plugin is doing at a given moment among other things
public Action Command_Stats(int client, int args)
{
    bool fromConsole = (client <= 0 || !IsClientInGame(client));

    // Connected clients, matching SourceMod's raw client count.
    int playerCount = GetClientCount(false);

    // Current map name
    char map[64];
    DGM_CopyCurrentNormalizedMapName(map, sizeof(map));

    // Hostname string
    char hostname[128];
    if (g_cHostname != null)
    {
        g_cHostname.GetString(hostname, sizeof(hostname));
    }
    else
    {
        strcopy(hostname, sizeof(hostname), "Unknown");
    }

    int visMax = DGM_GetServerCapacityValue();

    // Respawn-related ConVars
    float respawnTime = GetConVarFloat(g_cvRespawnTime);
    float timeOverride = GetConVarFloat(g_cvTimeOverride);
    float redTime = GetConVarFloat(g_cvRedTime);
    float bluTime = GetConVarFloat(g_cvBluTime);
    int asymCapRespawn = GetConVarInt(g_cvAsymCapRespawn);

    // Output function (chooses chat or console)
    if (fromConsole)
    {
        PrintToServer("[DGM] Players: %d", playerCount);
        PrintToServer("Map: %s | Server: %s | Max Players: %d", map, hostname, visMax);
        PrintToServer("  respawn_time: %.2f", respawnTime);
        PrintToServer("  red: %.2f | blu: %.2f | otime:%.2f", redTime, bluTime, timeOverride);
        PrintToServer("  last_round_duration: %d seconds", g_iLastRoundDuration);
        PrintToServer("  respawn_red_on_cap: %d",
                      asymCapRespawn);
    }
    else
    {
        PrintToChat(client, "\x04[DGM]\x01 Players: \x04%d\x01 | Map: \x04%s\x01 | Server: \x04%s\x01 | Max: \x04%d",
                    playerCount, map, hostname, visMax);

        PrintToChat(client, "\x04[Respawn]\x01 respawn_time: \x04%.2f\x01 | respawn_otime: \x04%.2f",
                    respawnTime, timeOverride);

        PrintToChat(client, "\x04[Respawn]\x01 red: \x04%.2f\x01 | blu: \x04%.2f", redTime, bluTime);

        PrintToChat(client, "\x04[DGM]\x01 Last round duration: \x04%d\x01 seconds", g_iLastRoundDuration);

        PrintToChat(client, "\x04[Respawn]\x01 respawn_red_on_cap: \x04%d",
                    asymCapRespawn);
    }

    return Plugin_Handled;
}

public Action Command_ObjectiveLeader(int client, int args)
{
    int redOwned, blueOwned, neutralOwned, total;
    DGMObjectiveLeader leader = DGM_GetObjectiveLeaderValue(redOwned, blueOwned, neutralOwned, total);

    if (leader == DGMObjectiveLeader_None)
    {
        if (client <= 0 || !IsClientInGame(client))
        {
            PrintToServer("[DGM] No control points were found or counted on this map.");
        }
        else
        {
            PrintToChat(client, "\x04[DGM]\x01 No control points were found or counted on this map.");
        }

        return Plugin_Handled;
    }

    char status[96];
    DGM_ObjectiveLeaderToString(leader, status, sizeof(status));

    if (client <= 0 || !IsClientInGame(client))
    {
        PrintToServer("[DGM] %s | RED=%d BLU=%d Neutral=%d TotalCounted=%d",
            status, redOwned, blueOwned, neutralOwned, total);
    }
    else
    {
        PrintToChat(client, "\x04[DGM]\x01 %s | RED=\x04%d\x01 BLU=\x04%d\x01 Neutral=\x04%d\x01 Total=\x04%d",
            status, redOwned, blueOwned, neutralOwned, total);
    }

    return Plugin_Handled;
}

public Action Command_CvarHelp(int client, int args)
{
    char lines[][] = {
        "respawn_time: float - Default respawn delay (seconds). Set to 30 to disable plugin handling.",
        "sm_highpop_threshhold: int - Player count threshold to execute high-pop configs",
        "respawn_otime: float - If >0, forces this respawn delay for all players",
        "respawn_redtime: float - Respawn time (seconds) specifically for Red team (beta)",
        "respawn_blutime: float - Respawn time (seconds) specifically for Blu team (beta)",
        "sm_autoaddtime: int - Seconds to add to KOTH timers when enabled (0 disables)",
        "respawn_red_on_cap: 0/1 - In asymmetrical modes, when 1, respawns Red instantly on cap",
        "sm_setuptime: int - Forces round setup time to this value (0 = disabled)",
        "sm_gamemode: string - Read-only; stores the detected gamemode name",
        "mp_disable_respawn_times: 0/1 - Server cvar hooked by this plugin to toggle visual respawn behavior"
    };

    bool fromConsole = (client <= 0 || !IsClientInGame(client));

    if (fromConsole)
    {
        PrintToServer("[DGM ConVar Help]");
        for (int i = 0; i < sizeof(lines); i++)
        {
            PrintToServer("  %s", lines[i]);
        }
    }
    else
    {
        PrintToChat(client, "\x04[DGM ConVar Help]\x01");
        for (int i = 0; i < sizeof(lines); i++)
        {
            PrintToChat(client, "\x01%s", lines[i]);
        }
    }

    return Plugin_Handled;
}

public Action Command_RespawnToggle(int client, int args)
{
    if (DGM_ShouldDisableInstantRespawn())
    {
        ReplyToCommand(client, "DGM respawn management is disabled on small-format maps.");
        return Plugin_Handled;
    }

    g_InternalOverride = !g_InternalOverride; // toggles between true and false
    DGM_RefreshRespawnVisualState();
    PrintToChat(client, "Respawn times %s", g_InternalOverride ? "forced on" : "forced off");
    return Plugin_Handled;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
        if (DGM_ShouldDisableInstantRespawn())
        {
            return;
        }

        if (g_InternalOverride)
        {
            SetConVarInt(g_cvMpDisableRespawnTimes, 0);
            return;
        }
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (!(IsValidClient(client))) return;

        float baseRespawn = GetConVarFloat(g_cvRespawnTime);
        if (FloatCompare(baseRespawn, 30.0) == 0)
        {
            return;
        }

        float override = GetConVarFloat(g_cvTimeOverride);
        if (override > 0)
        {
            CreateTimer(override, Timer_RespawnClient, client);
            return;
        }

        float time = baseRespawn;
        int team = GetClientTeam(client);
        float redTime = GetConVarFloat(g_cvRedTime);
        float bluTime = GetConVarFloat(g_cvBluTime);
        if (redTime != bluTime)
        {
        if (team == 2) time = redTime;
        else if (team == 3) time = bluTime;
        }
        CreateTimer(time, Timer_RespawnClient, client);
        return;
}

public Action Timer_RespawnClient(Handle timer, int client)
{
    if (DGM_ShouldDisableInstantRespawn())
    {
        return Plugin_Stop;
    }

    if (IsValidClient(client) && !IsPlayerAlive(client) && GetClientTeam(client) > 1) {
        TF2_RespawnPlayer(client);
    }
    return Plugin_Stop;
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    g_iRoundStartTimestamp = GetTime();
    g_iLastRoundDuration = 0;

    if (g_cvTimeOverride != null)    g_cvTimeOverride.RestoreDefault();
    g_InternalOverride = false; // This is set to true when a round is won, it changes back to false now
    DGM_RefreshRespawnVisualState();
    g_PointCaptures = 0;
    DGM_UpdateSetupState();
    if (!g_bRoundStartedOnce)
    {
        g_bRoundStartedOnce = true;
        RequestFrame(AdjustByPlayerCount);
    }
    if (GetConVarInt(g_cvSetSetupTime) != 0)
    {
        SetSetupTime();
    }
	if (GetConVarInt(g_cvAutoAddTime)) {
        int addTime = GetConVarInt(g_cvAutoAddTime);
		int entityTimer = FindEntityByClassname(-1, "tf_logic_koth");
		if (entityTimer > -1)
		{
			SetVariantInt(addTime);
			AcceptEntityInput(entityTimer, "SetBlueTimer");
			SetVariantInt(addTime);
			AcceptEntityInput(entityTimer, "SetRedTimer");
		}
	}
}

public void Event_SetupFinished(Event event, const char[] name, bool dontBroadcast)
{
    DGM_SetSetupActive(false);
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    int roundEndTimestamp = GetTime();
    g_iLastRoundDuration = DGM_CalculateRoundDurationSeconds(g_iRoundStartTimestamp, roundEndTimestamp);

    SetConVarInt(g_cvTimeOverride, 30);
    g_PointCaptures = 0;
    g_InternalOverride = true; // We're gonna stop clients from getting insta-respawned with this
    DGM_RefreshRespawnVisualState();
}

public Action Command_ResetSetup(int client , int args)
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt == -1)
    {
        if (client > 0) PrintToChat(client, "No team_round_timer entity found.");
        else PrintToServer("[Kogasa] No team_round_timer entity found.");
        return Plugin_Handled;
    }

    int time = 10;
    if (args > 0)
    {
        if (!GetCmdArgIntEx( 1, args))
        {
            ReplyToCommand(client, "Given time must be a number!" );
            return Plugin_Continue;
        }
    }
	char temp[ 4 ];
	GetCmdArg( 1, temp, 4 );
	time = StringToInt(temp) + 1;
    SetVariantInt(time);
    AcceptEntityInput(timerEnt, "SetTime");

    if (client > 0) PrintToChatAll("Setup time reduced to %i seconds.", time);
    PrintToServer("[Kogasa] Setup time set to %i seconds.", time);
    return Plugin_Handled;
}

public Action Command_ExtendTimer(int client , int args)
{
    int timerEnt = FindEntityByClassname(-1, "team_round_timer");
    if (timerEnt == -1)
    {
        if (client > 0) PrintToChat(client, "No team_round_timer entity found.");
        else PrintToServer("[Kogasa] No team_round_timer entity found.");
        return Plugin_Handled;
    }

    int time = 10;
    if (args > 0)
    {
        if (!GetCmdArgIntEx( 1, args))
        {
            ReplyToCommand(client, "Given time must be a number!" );
            return Plugin_Continue;
        }
    }
	char temp[ 4 ];
	GetCmdArg( 1, temp, 4 );
	time = StringToInt(temp) + 1;
    SetVariantInt(time);
    AcceptEntityInput(timerEnt, "SetTime");

    if (client > 0) PrintToChatAll("Setup time reduced to %i seconds.", time);
    PrintToServer("[Kogasa] Setup time set to %i seconds.", time);
    return Plugin_Handled;
}
