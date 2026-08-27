#pragma semicolon 1
#pragma newdecls required
#pragma tabsize 4

#include <sourcemod>

#include <tf2>
#include <tf2_stocks>

#include <dhooks>

#include <morecolors>


#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <whaletracker_api>
#define REQUIRE_PLUGIN
#include <plugin_statistics>

#include "include/steam_identity.inc"
#include "include/tf2_classes.inc"

#define PL_VERSION "1.0.2"
#define CLASSLIMITS_STATS_INTERVAL 180.0
#define CLASSLIMITS_CONFIG "configs/classlimits.cfg"
#define CLASS_AVAILABILITY_REQUEST_LIFETIME 240
#define DGM_PLAYERCOUNT_RELIABILITY_RATIO 0.66

#define TF_CLASS_DEMOMAN        4
#define TF_CLASS_ENGINEER       9
#define TF_CLASS_HEAVY          6
#define TF_CLASS_MEDIC          5
#define TF_CLASS_PYRO           7
#define TF_CLASS_SCOUT          1
#define TF_CLASS_SNIPER         2
#define TF_CLASS_SOLDIER        3
#define TF_CLASS_SPY            8
#define TF_CLASS_UNKNOWN        0

#define TF_TEAM_BLU             3
#define TF_TEAM_RED             2

#define POPULATION_RESTRICTION_MIN_PLAYERS 3

public Plugin myinfo =
{
    name        = "classlimits",
    author      = "Tsunami (updated by Codex)",
    description = "Restrict classes evenly across teams in TF2.",
    version     = PL_VERSION,
    url         = "https://kogasa.tf"
};

int g_iClass[MAXPLAYERS + 1];
bool g_bForcedRespawn[MAXPLAYERS + 1];
int g_iForcedRespawnAttempts[MAXPLAYERS + 1];
int g_iPendingClassAvailability[MAXPLAYERS + 1];
int g_iPendingClassAvailabilityExpiresAt[MAXPLAYERS + 1];
ConVar g_hEnabled;
ConVar g_hFlags;
ConVar g_hImmunity;
ConVar g_hTopScore;
ConVar g_hDisplayUnlim;
ConVar g_hDisableOverhealPcount;
ConVar g_hDisableOverhealMedicImbalance;
ConVar g_hRestrictHeaviesPcount;
ConVar g_hRestrictMedicsPcount;
ConVar g_hPlayerRestrictions;
ConVar g_hMaxHealthBoost;
ConVar g_hLimits[TF_CLASS_ENGINEER + 1];
char g_sGameMode[64] = "this map";
Handle g_hClassStatsTimer = null;
Handle g_hClassStateTimer = null;
StringMap g_ClassBans = null;
bool g_bOverhealDisabled = false;
bool g_bOverhealUpdateQueued = false;
bool g_bOverhealWarningShown[MAXPLAYERS + 1];
bool g_bMedicImbalanceActive = false;
bool g_bMedicImbalanceDisabledAlertShown = false;
bool g_bMedicImbalanceReturnedAlertShown = false;
float g_fEnabledMaxHealthBoost = 1.5;
DynamicDetour g_hStartHealingTarget = null;

static const char g_ClassNames[TF_CLASS_ENGINEER + 1][16] = {
    "Unknown", "Scout", "Sniper", "Soldier", "Demoman",
    "Medic", "Heavy", "Pyro", "Spy", "Engineer"
};

static const char g_ClassSuffixes[TF_CLASS_ENGINEER + 1][12] = {
    "unknown", "scouts", "snipers", "soldiers", "demomen",
    "medics", "heavies", "pyros", "spies", "engineers"
};

char g_sSounds[TF_CLASS_ENGINEER + 1][24] = {"", "vo/scout_no03.mp3",   "vo/sniper_no04.mp3", "vo/soldier_no01.mp3",
                                "vo/demoman_no03.mp3", "vo/medic_no03.mp3",  "vo/heavy_no02.mp3",
                                "vo/pyro_no01.mp3",    "vo/spy_no02.mp3",    "vo/engineer_no03.mp3"};

public void OnPluginStart()
{
    g_ClassBans = new StringMap();
    SetupOverhealWarningHook();

    CreateConVar("classlimits_version", PL_VERSION, "Restrict classes in TF2.", FCVAR_NOTIFY);
    g_hEnabled      = CreateConVar("restrict_enabled",     "1", "Enable or disable class limits.");
    g_hFlags        = CreateConVar("restrict_flags",       "z", "Admin flags allowed to bypass class limits.");
    g_hImmunity     = CreateConVar("restrict_immunity",    "0", "Enable/disable admin immunity for class limits.");
    g_hTopScore     = CreateConVar("classlimits_topscore", "0", "Allow top team scorers to bypass class limits.", _, true, 0.0, true, 1.0);
    g_hDisplayUnlim = CreateConVar("display_unlim",        "0", "If 1, show unlimited classes in class limit displays.", _, true, 0.0, true, 1.0);
    g_hDisableOverhealPcount = CreateConVar(
        "disable_overheal_pcount",
        "0",
        "If above 0, disable new overheal while human playercount is below this value.",
        _,
        true,
        0.0
    );
    g_hDisableOverhealMedicImbalance = CreateConVar(
        "disable_overheal_medic_imbalance",
        "0",
        "Disable overheal while exactly one team has a Medic.",
        _,
        true,
        0.0,
        true,
        1.0
    );
    g_hPlayerRestrictions = CreateConVar(
        "classlimits_player_restrictions",
        "1",
        "Enable per-SteamID class restrictions from classlimits.cfg.",
        _,
        true,
        0.0,
        true,
        1.0
    );
    g_hRestrictHeaviesPcount = CreateConVar(
        "restrict_heavies_pcount",
        "0",
        "If above 0, restrict Heavy to 0 while human playercount is below this value.",
        _,
        true,
        0.0
    );
    g_hRestrictMedicsPcount = CreateConVar(
        "restrict_medics_pcount",
        "0",
        "If above 0, restrict Medic to 0 while human playercount is below this value.",
        _,
        true,
        0.0
    );
    g_hMaxHealthBoost = FindConVar("tf_max_health_boost");
    if (g_hMaxHealthBoost != null)
    {
        g_fEnabledMaxHealthBoost = g_hMaxHealthBoost.FloatValue;
    }

    g_hDisableOverhealPcount.AddChangeHook(OnOverhealPopulationThresholdChanged);
    g_hDisableOverhealMedicImbalance.AddChangeHook(OnOverhealPopulationThresholdChanged);
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        char cvarName[32];
        char description[64];
        Format(cvarName, sizeof(cvarName), "restrict_%s", g_ClassSuffixes[classId]);
        Format(description, sizeof(description), "Limit for %s.", g_ClassNames[classId]);
        g_hLimits[classId] = CreateConVar(cvarName, "-1", description);
        g_hLimits[classId].AddChangeHook(OnClassLimitChanged);
    }

    HookEvent("player_changeclass", Event_PlayerClass);
    HookEvent("player_spawn",       Event_PlayerSpawn);
    HookEvent("player_team",        Event_PlayerTeam);
    HookEvent("player_say",         Event_PlayerSay, EventHookMode_Post);
    HookEvent("teamplay_round_win", Event_ClearClassAvailabilityRequests, EventHookMode_PostNoCopy);
    HookEvent("teamplay_round_stalemate", Event_ClearClassAvailabilityRequests, EventHookMode_PostNoCopy);
    RegConsoleCmd("sm_classlimits", Command_ShowClassLimits, "Show current class limits.");
    RegConsoleCmd("sm_cl",          Command_ShowClassLimits, "Show current class limits.");
    RegAdminCmd("sm_classlimits_historical", Command_RecordClassPopularityHistorical, ADMFLAG_GENERIC, "Record a daily class popularity snapshot.");

    g_hClassStatsTimer = CreateTimer(CLASSLIMITS_STATS_INTERVAL, Timer_RecordClassStats, _, TIMER_REPEAT);
    g_hClassStateTimer = CreateTimer(3.0, Timer_UpdateClassState, _, TIMER_REPEAT);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("DGM_GetGameModeKey");
    MarkNativeAsOptional("DGM_RealPlayerCount");
    MarkNativeAsOptional("DGM_CurrentNormalizedMap");
    MarkNativeAsOptional("DGM_NormalizeMapName");
    MarkNativeAsOptional("WhaleTracker_AreStatsLoaded");
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeSeconds");
    return APLRes_Success;
}

public void OnMapStart()
{
    g_bMedicImbalanceActive = false;
    g_bMedicImbalanceDisabledAlertShown = false;
    g_bMedicImbalanceReturnedAlertShown = false;
    ClearAllClassAvailabilityRequests();
    QueueOverhealStateUpdate();
    for (int client = 1; client <= MaxClients; client++)
    {
        g_bOverhealWarningShown[client] = false;
    }

    char sSound[32];
    for (int i = 1; i < sizeof(g_sSounds); i++)
    {
        Format(sSound, sizeof(sSound), "sound/%s", g_sSounds[i]);
        PrecacheSound(g_sSounds[i]);
        AddFileToDownloadsTable(sSound);
    }
}

public void OnPluginEnd()
{
    RestoreOverheal();
    if (g_hStartHealingTarget != null)
    {
        g_hStartHealingTarget.Disable(Hook_Pre, StartHealingTarget_Pre);
        delete g_hStartHealingTarget;
    }

    if (g_hClassStatsTimer != null)
    {
        KillTimer(g_hClassStatsTimer);
        g_hClassStatsTimer = null;
    }

    if (g_hClassStateTimer != null)
    {
        KillTimer(g_hClassStateTimer);
        g_hClassStateTimer = null;
    }

    delete g_ClassBans;
}

public void OnClientPutInServer(int client)
{
    g_iClass[client]                 = TF_CLASS_UNKNOWN;
    g_bForcedRespawn[client]         = false;
    g_iForcedRespawnAttempts[client] = 0;
    g_bOverhealWarningShown[client]   = false;
    ClearClassAvailabilityRequest(client);
    QueueOverhealStateUpdate();
}

public void OnClientDisconnect(int client)
{
    g_bOverhealWarningShown[client] = false;
    ClearClassAvailabilityRequest(client);
    QueueOverhealStateUpdate();
}

public Action Timer_RecordClassStats(Handle timer, any data)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        char steamId[KOGASA_STEAMID_MAX];
        if (!Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId)))
        {
            continue;
        }

        TFClassType tfClassType = TF2_GetPlayerClass(client);
        int classId = view_as<int>(tfClassType);

        char message[256];
        Format(message, sizeof(message),
            "event=class_snapshot|steamid64=%s|class=%d",
            steamId,
            classId);
        PluginStats_Record("class_snapshot", message);
    }

    return Plugin_Continue;
}

public Action Timer_UpdateClassState(Handle timer, any data)
{
    UpdateOverhealState();
    CheckPendingClassAvailability();
    return Plugin_Continue;
}

public Action Command_RecordClassPopularityHistorical(int client, int args)
{
    int counts[TF_CLASS_ENGINEER + 1];
    int total = 0;

    for (int player = 1; player <= MaxClients; player++)
    {
        if (!IsClientInGame(player) || IsFakeClient(player) || GetClientTeam(player) < TF_TEAM_RED)
        {
            continue;
        }

        int classId = view_as<int>(TF2_GetPlayerClass(player));
        if (classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
        {
            continue;
        }

        counts[classId]++;
        total++;
    }

    char message[512];
    FormatEx(message, sizeof(message),
        "event=class_popularity_daily_snapshot|clients=%d|scout=%d|soldier=%d|pyro=%d|demoman=%d|heavy=%d|engineer=%d|medic=%d|sniper=%d|spy=%d",
        total,
        counts[TF_CLASS_SCOUT],
        counts[TF_CLASS_SOLDIER],
        counts[TF_CLASS_PYRO],
        counts[TF_CLASS_DEMOMAN],
        counts[TF_CLASS_HEAVY],
        counts[TF_CLASS_ENGINEER],
        counts[TF_CLASS_MEDIC],
        counts[TF_CLASS_SNIPER],
        counts[TF_CLASS_SPY]);
    PluginStats_Record("class_popularity_daily_snapshot", message);

    if (client > 0 && IsClientInGame(client))
    {
        CPrintToChat(client, "{olive}[Class Limits]{default} Daily class popularity snapshot queued for {gold}%d{default} players.", total);
    }
    else
    {
        PrintToServer("[Class Limits] Daily class popularity snapshot queued for %d players.", total);
    }

    return Plugin_Handled;
}

public void Event_PlayerSay(Event event, const char[] name, bool dontBroadcast)
{
    int userId = event.GetInt("userid", 0);
    if (!userId) return;

    int client = GetClientOfUserId(userId);
    if (!IsClientInGame(client)) return;

    char text[64];
    event.GetString("text", text, sizeof(text));

    char lower[64];
    strcopy(lower, sizeof(lower), text);
    for (int i = 0; lower[i]; i++)
        if (lower[i] >= 'A' && lower[i] <= 'Z') lower[i] += 'a' - 'A';

    if (!StrEqual(lower, "!classrestrict") && !StrEqual(lower, "!cr")) return;
    Command_ShowClassLimits(client, 0);
}

public Action Command_ShowClassLimits(int client, int args)
{
    bool fromConsole = (client <= 0 || !IsClientInGame(client));
    UpdateGameModeName();

    if (fromConsole)
        PrintToServer("[Class Limits] Current gamemode: %s", g_sGameMode);
    else
        CPrintToChat(client, "{olive}[Class Limits]{default} Current gamemode: {yellow}%s{default}", g_sGameMode);

    char limitText[96];
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        if (!ShouldDisplayClassInList(classId)) continue;
        FormatClassLimitText(classId, limitText, sizeof(limitText));
        if (fromConsole)
            PrintToServer("  %s: %s", g_ClassNames[classId], limitText);
        else
            CPrintToChat(client, "{olive}  %s{default}: {gold}%s{default}", g_ClassNames[classId], limitText);
    }
    return Plugin_Handled;
}

bool ShouldDisplayClassInList(int classId)
{
    if (classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
        return false;
    if (IsClassPopulationRestricted(classId)) return true;
    if (g_hDisplayUnlim != null && g_hDisplayUnlim.BoolValue) return true;
    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null) return false;
    return limitCvar.FloatValue >= 0.0;
}

public void OnConfigsExecuted()
{
    LoadClassBans();
    UpdateGameModeName();
    UpdateOverhealState();
}

public void Event_PlayerClass(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid"));
    if (iClient <= 0 || !IsClientInGame(iClient))
    {
        return;
    }

    int iClass  = event.GetInt("class");
    int iTeam   = GetClientTeam(iClient);

    int limit;
    if (IsClientClassRestricted(iClient, iTeam, iClass, limit))
    {
        if (!IsClientClassBanned(iClient, iClass))
        {
            RememberClassAvailabilityRequest(iClient, iClass);
        }

        if (iClass >= 0 && iClass < sizeof(g_sSounds) && g_sSounds[iClass][0])
            EmitSoundToClient(iClient, g_sSounds[iClass]);

        NotifyClassRestricted(iClient, iClass, limit);

        // Revert the class selection and reopen the class panel.
        // Never call TF2_RespawnPlayer here — the panel keeps them off the
        // field, and Event_PlayerSpawn enforces the limit when they spawn.
        TF2_SetPlayerClass(iClient, view_as<TFClassType>(g_iClass[iClient]));
        ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
    }
    else if (g_iPendingClassAvailability[iClient] == iClass)
    {
        ClearClassAvailabilityRequest(iClient);
    }
}

public void Event_ClearClassAvailabilityRequests(Event event, const char[] name, bool dontBroadcast)
{
    ClearAllClassAvailabilityRequests();
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid"));
    int iTeam   = GetClientTeam(iClient);

    if (iClient <= 0 || !IsClientInGame(iClient)) return;

    // This spawn was triggered by our own forced class respawn; don't recurse.
    if (g_bForcedRespawn[iClient])
    {
        g_bForcedRespawn[iClient] = false;
        return;
    }

    g_iClass[iClient] = view_as<int>(TF2_GetPlayerClass(iClient));

    int limit;
    if (IsClientClassRestricted(iClient, iTeam, g_iClass[iClient], limit))
    {
        if (g_iForcedRespawnAttempts[iClient] >= 3) return;

        NotifyClassRestricted(iClient, g_iClass[iClient], limit);
        if (g_iClass[iClient] >= 0 && g_iClass[iClient] < sizeof(g_sSounds) && g_sSounds[g_iClass[iClient]][0])
            EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        PickClass(iClient);
    }
    else
    {
        g_iForcedRespawnAttempts[iClient] = 0;
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    QueueOverhealStateUpdate();

    int iClient = GetClientOfUserId(event.GetInt("userid"));
    int iTeam   = event.GetInt("team");

    int limit;
    if (IsClientClassRestricted(iClient, iTeam, g_iClass[iClient], limit))
    {
        if (g_iClass[iClient] >= 0 && g_iClass[iClient] < sizeof(g_sSounds) && g_sSounds[g_iClass[iClient]][0])
            EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        NotifyClassRestricted(iClient, g_iClass[iClient], limit);
    }
}

static int GetClientScore(int client)
{
    static int scorePropState = 0;
    if (scorePropState == 0
        || (scorePropState == 1 && !HasEntProp(client, Prop_Send, "m_iScore"))
        || (scorePropState == 2 && !HasEntProp(client, Prop_Send, "m_iFrags")))
    {
        if (HasEntProp(client, Prop_Send, "m_iScore"))      scorePropState = 1;
        else if (HasEntProp(client, Prop_Send, "m_iFrags")) scorePropState = 2;
        else                                                scorePropState = 3;
    }
    if (scorePropState == 1) return GetEntProp(client, Prop_Send, "m_iScore");
    if (scorePropState == 2) return GetEntProp(client, Prop_Send, "m_iFrags");
    return 0;
}

static bool GetTeamTopScoreThreshold(int team, int &threshold)
{
    threshold = 0;
    int topScores[3] = { -2147483647, -2147483647, -2147483647 };
    int count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != team) continue;
        int score = GetClientScore(i);
        count++;
        if (score > topScores[0])      { topScores[2] = topScores[1]; topScores[1] = topScores[0]; topScores[0] = score; }
        else if (score > topScores[1]) { topScores[2] = topScores[1]; topScores[1] = score; }
        else if (score > topScores[2]) { topScores[2] = score; }
    }

    if (count == 0) return false;
    threshold = (count < 3) ? topScores[count - 1] : topScores[2];
    return true;
}

static bool IsTopTeamScorer(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return false;
    int team = GetClientTeam(client);
    if (team < TF_TEAM_RED) return false;
    int threshold;
    if (!GetTeamTopScoreThreshold(team, threshold)) return false;
    return GetClientScore(client) >= threshold;
}

static bool IsClassLimitImmune(int client)
{
    if (g_hTopScore.BoolValue && IsTopTeamScorer(client)) return true;
    return g_hImmunity.BoolValue && IsImmune(client);
}

static bool IsClientClassRestricted(int client, int team, int classId, int &limitOut)
{
    limitOut = -1;
    if (!g_hEnabled.BoolValue)
        return false;

    if (IsClientClassBanned(client, classId))
    {
        limitOut = 0;
        return true;
    }

    return !IsClassLimitImmune(client) && IsClassAtLimit(client, team, classId, limitOut);
}

static bool IsClientClassBanned(int client, int classId)
{
    if (g_hPlayerRestrictions == null || !g_hPlayerRestrictions.BoolValue
        || g_ClassBans == null || client <= 0 || !IsClientInGame(client)
        || classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
    {
        return false;
    }

    char steamId[KOGASA_STEAMID_MAX];
    int classMask;
    return Kogasa_GetClientSteamId64(client, steamId, sizeof(steamId))
        && g_ClassBans.GetValue(steamId, classMask)
        && (classMask & (1 << classId)) != 0;
}

static int GetHumanTeamClientCount(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != team) continue;
        count++;
    }
    return count;
}

static bool GetReliableGameplayHumanClientCount(int &playerCount)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") == FeatureStatus_Available)
    {
        playerCount = DGM_RealPlayerCount();
        int connectedClients = GetClientCount(false);
        return connectedClients <= 0
            || float(playerCount) / float(connectedClients) >= DGM_PLAYERCOUNT_RELIABILITY_RATIO;
    }

    playerCount = GetHumanTeamClientCount(TF_TEAM_RED) + GetHumanTeamClientCount(TF_TEAM_BLU);
    return true;
}

static void SetupOverhealWarningHook()
{
    GameData gameData = new GameData("tf2.classlimits");
    if (gameData == null)
    {
        LogError("Unable to load tf2.classlimits gamedata; overheal warnings are unavailable.");
        return;
    }

    g_hStartHealingTarget = DynamicDetour.FromConf(gameData, "CWeaponMedigun::StartHealingTarget");
    delete gameData;

    if (g_hStartHealingTarget == null
        || !g_hStartHealingTarget.Enable(Hook_Pre, StartHealingTarget_Pre))
    {
        LogError("Unable to hook CWeaponMedigun::StartHealingTarget; overheal warnings are unavailable.");
        delete g_hStartHealingTarget;
    }
}

public MRESReturn StartHealingTarget_Pre(int weapon, DHookParam parameters)
{
    int medic = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    int target = parameters.Get(1);
    if (medic <= 0 || medic > MaxClients || !IsClientInGame(medic)
        || TF2_GetPlayerClass(medic) != TFClass_Medic
        || target <= 0 || target > MaxClients || target == medic
        || !IsClientInGame(target) || g_bOverhealWarningShown[medic])
    {
        return MRES_Ignored;
    }

    int threshold = g_hDisableOverhealPcount.IntValue;
    int playerCount;
    if (threshold <= 0
        || !GetReliableGameplayHumanClientCount(playerCount)
        || playerCount >= threshold)
    {
        return MRES_Ignored;
    }

    g_bOverhealWarningShown[medic] = true;
    CPrintToChat(medic, "{gold}[Server]{green} Overheal is disabled below %d players.", threshold);
    return MRES_Ignored;
}

public void OnOverhealPopulationThresholdChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateOverhealState();
}

public void OnClassLimitChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (StringToFloat(newValue) != 0.0 || StringToFloat(oldValue) == 0.0)
    {
        return;
    }

    int disabledClass = TF_CLASS_UNKNOWN;
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        if (convar == g_hLimits[classId])
        {
            disabledClass = classId;
            break;
        }
    }

    if (disabledClass == TF_CLASS_UNKNOWN)
    {
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)
            || GetClientTeam(client) < TF_TEAM_RED
            || view_as<int>(TF2_GetPlayerClass(client)) != disabledClass)
        {
            continue;
        }

        NotifyClassRestricted(client, disabledClass, 0);
        PickClass(client, disabledClass, true);
    }
}

static void QueueOverhealStateUpdate()
{
    if (g_bOverhealUpdateQueued)
    {
        return;
    }

    g_bOverhealUpdateQueued = true;
    RequestFrame(Frame_UpdateOverhealState);
}

public void Frame_UpdateOverhealState(any data)
{
    g_bOverhealUpdateQueued = false;
    UpdateOverhealState();
}

static void UpdateOverhealState()
{
    if (g_hDisableOverhealPcount == null
        || g_hDisableOverhealMedicImbalance == null
        || g_hMaxHealthBoost == null)
    {
        return;
    }

    int threshold = g_hDisableOverhealPcount.IntValue;
    int playerCount;
    bool populationDisabled = threshold > 0
        && GetReliableGameplayHumanClientCount(playerCount)
        && playerCount < threshold;
    bool redHasMedic;
    bool bluHasMedic;
    bool medicImbalanceDisabled = IsMedicImbalanceOverhealDisabled(redHasMedic, bluHasMedic);
    bool medicImbalanceEnded = g_bMedicImbalanceActive && !medicImbalanceDisabled;
    g_bMedicImbalanceActive = medicImbalanceDisabled;

    bool shouldDisable = populationDisabled || medicImbalanceDisabled;

    if (shouldDisable)
    {
        if (!g_bOverhealDisabled)
        {
            g_fEnabledMaxHealthBoost = g_hMaxHealthBoost.FloatValue;
            g_hMaxHealthBoost.SetFloat(1.0);
            g_bOverhealDisabled = true;
        }

        if (medicImbalanceDisabled)
        {
            AlertMedicsOverhealDisabledByImbalance();
        }
        return;
    }

    if (g_bOverhealDisabled)
    {
        RestoreOverheal();
    }
    else
    {
        g_fEnabledMaxHealthBoost = g_hMaxHealthBoost.FloatValue;
    }

    if (medicImbalanceEnded && redHasMedic && bluHasMedic)
    {
        AlertMedicsOverhealReturned();
    }
}

static bool IsMedicImbalanceOverhealDisabled(bool &redHasMedic, bool &bluHasMedic)
{
    redHasMedic = TeamHasHumanMedic(TF_TEAM_RED);
    bluHasMedic = TeamHasHumanMedic(TF_TEAM_BLU);
    return g_hDisableOverhealMedicImbalance.BoolValue && redHasMedic != bluHasMedic;
}

static bool TeamHasHumanMedic(int team)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client)
            && !IsFakeClient(client)
            && GetClientTeam(client) == team
            && TF2_GetPlayerClass(client) == TFClass_Medic)
        {
            return true;
        }
    }

    return false;
}

static void AlertMedicsOverhealDisabledByImbalance()
{
    if (g_bMedicImbalanceDisabledAlertShown)
    {
        return;
    }

    g_bMedicImbalanceDisabledAlertShown = true;
    for (int medic = 1; medic <= MaxClients; medic++)
    {
        if (IsClientInGame(medic)
            && !IsFakeClient(medic)
            && GetClientTeam(medic) >= TF_TEAM_RED
            && TF2_GetPlayerClass(medic) == TFClass_Medic)
        {
            CPrintToChat(medic, "{green}[Server]{default} Overheal is disabled when the enemy team has no Medics, sit tight!");
        }
    }
}

static void AlertMedicsOverhealReturned()
{
    if (g_bMedicImbalanceReturnedAlertShown)
    {
        return;
    }

    g_bMedicImbalanceReturnedAlertShown = true;
    for (int medic = 1; medic <= MaxClients; medic++)
    {
        if (IsClientInGame(medic)
            && !IsFakeClient(medic)
            && GetClientTeam(medic) >= TF_TEAM_RED
            && TF2_GetPlayerClass(medic) == TFClass_Medic)
        {
            CPrintToChat(medic, "{green}[Server]{default} Both teams have a Medic, overheal has returned!");
        }
    }
}

static void RestoreOverheal()
{
    if (!g_bOverhealDisabled || g_hMaxHealthBoost == null)
    {
        return;
    }

    g_hMaxHealthBoost.SetFloat(g_fEnabledMaxHealthBoost);
    g_bOverhealDisabled = false;
}

static bool IsClassPopulationRestricted(int classId)
{
    int currentPlayers, threshold;
    return GetClassPopulationRestrictionState(classId, currentPlayers, threshold);
}

static bool GetClassPopulationRestrictionState(int classId, int &currentPlayers, int &threshold)
{
    currentPlayers = 0;
    threshold = 0;

    ConVar restrictionCvar = null;
    if (classId == TF_CLASS_HEAVY)
        restrictionCvar = g_hRestrictHeaviesPcount;
    else if (classId == TF_CLASS_MEDIC)
        restrictionCvar = g_hRestrictMedicsPcount;

    if (restrictionCvar == null)
        return false;

    if (!GetReliableGameplayHumanClientCount(currentPlayers))
        return false;

    threshold = restrictionCvar.IntValue;
    return threshold > 0 && currentPlayers >= POPULATION_RESTRICTION_MIN_PLAYERS && currentPlayers < threshold;
}

bool IsClassAtLimit(int client, int iTeam, int iClass, int &limitOut)
{
    limitOut = -1;
    if (!g_hEnabled.BoolValue || iTeam < TF_TEAM_RED || iClass < TF_CLASS_SCOUT || iClass > TF_CLASS_ENGINEER)
        return false;

    if (IsClassPopulationRestricted(iClass))
    {
        limitOut = 0;
        return true;
    }

    if (iClass == TF_CLASS_MEDIC && !MedicCountsTowardClassLimit(client))
    {
        return false;
    }

    ConVar limitCvar = g_hLimits[iClass];
    if (limitCvar == null) return false;

    float flLimit = limitCvar.FloatValue;
    if (flLimit < 0.0) return false;

    if (flLimit > 0.0 && flLimit < 1.0)
        limitOut = RoundToNearest(flLimit * GetHumanTeamClientCount(iTeam));
    else
        limitOut = RoundToNearest(flLimit);

    if (limitOut <= 0) return (limitOut == 0);

    int scoreThreshold = 0;
    bool haveThreshold = g_hTopScore.BoolValue && GetTeamTopScoreThreshold(iTeam, scoreThreshold);

    for (int i = 1, iCount = 0; i <= MaxClients; i++)
    {
        if (i == client || !IsClientInGame(i) || IsFakeClient(i)
            || GetClientTeam(i) != iTeam
            || view_as<int>(TF2Classes_GetCurrentOrDesired(i)) != iClass)
        {
            continue;
        }
        if (iClass == TF_CLASS_MEDIC && !MedicCountsTowardClassLimit(i)) continue;
        if (haveThreshold && GetClientScore(i) >= scoreThreshold) continue;
        if (++iCount >= limitOut) return true;
    }
    return false;
}

static bool MedicCountsTowardClassLimit(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_AreStatsLoaded") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") != FeatureStatus_Available
        || !WhaleTracker_AreStatsLoaded(client))
    {
        return true;
    }

    return WhaleTracker_GetRankedPlaytimeSeconds(client) > 0;
}

bool IsImmune(int iClient)
{
    if (!iClient || !IsClientInGame(iClient)) return false;
    char sFlags[32];
    g_hFlags.GetString(sFlags, sizeof(sFlags));
    return !StrEqual(sFlags, "") && CheckCommandAccess(iClient, "classrestrict", ReadFlagString(sFlags));
}

bool PickClass(int iClient, int excludedClass = TF_CLASS_UNKNOWN, bool killFirst = false)
{
    if (iClient <= 0 || !IsClientInGame(iClient))
    {
        return false;
    }

    int firstClass = GetRandomInt(TF_CLASS_SCOUT, TF_CLASS_ENGINEER);
    int team = GetClientTeam(iClient);
    for (int offset = 0; offset < TF_CLASS_ENGINEER; offset++)
    {
        int classId = ((firstClass - TF_CLASS_SCOUT + offset) % TF_CLASS_ENGINEER) + TF_CLASS_SCOUT;
        if (classId == excludedClass)
        {
            continue;
        }

        int limit;
        if (!IsClientClassRestricted(iClient, team, classId, limit))
        {
            if (killFirst && IsPlayerAlive(iClient))
            {
                ForcePlayerSuicide(iClient);
            }

            g_iForcedRespawnAttempts[iClient]++;
            g_bForcedRespawn[iClient] = true;
            TF2_SetPlayerClass(iClient, view_as<TFClassType>(classId));
            TF2_RespawnPlayer(iClient);
            g_iClass[iClient] = classId;
            return true;
        }
    }

    return false;
}

void LoadClassBans()
{
    g_ClassBans.Clear();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), CLASSLIMITS_CONFIG);

    KeyValues config = new KeyValues("classBans");
    if (!config.ImportFromFile(path))
    {
        LogError("[Class Limits] Unable to read %s.", path);
        delete config;
        return;
    }

    if (config.GotoFirstSubKey(false))
    {
        do
        {
            char steamId[KOGASA_STEAMID_MAX];
            char classList[160];
            config.GetSectionName(steamId, sizeof(steamId));
            config.GetString(NULL_STRING, classList, sizeof(classList));

            int classMask = ParseClassBanList(classList);
            if (classMask != 0)
            {
                g_ClassBans.SetValue(steamId, classMask, true);
            }
        }
        while (config.GotoNextKey(false));
    }

    delete config;
}

int ParseClassBanList(const char[] classList)
{
    char entries[TF_CLASS_ENGINEER][16];
    int count = ExplodeString(classList, ",", entries, sizeof(entries), sizeof(entries[]));
    int classMask = 0;

    for (int i = 0; i < count; i++)
    {
        TrimString(entries[i]);
        int classId = FindClassIdByName(entries[i]);
        if (classId != TF_CLASS_UNKNOWN)
        {
            classMask |= (1 << classId);
        }
    }

    return classMask;
}

int FindClassIdByName(const char[] className)
{
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        if (StrEqual(className, g_ClassNames[classId], false))
        {
            return classId;
        }
    }

    return TF_CLASS_UNKNOWN;
}

void NotifyClassRestricted(int client, int classId, int limit)
{
    if (client <= 0 || !IsClientInGame(client)) return;

    int currentPlayers, threshold;
    if (GetClassPopulationRestrictionState(classId, currentPlayers, threshold))
    {
        CPrintToChat(client, "{olive}[Class Limits]{default} %s is disabled until {gold}%d{default} players are on RED/BLU ({gold}%d{default} currently).", g_ClassNames[classId], threshold, currentPlayers);
        return;
    }

    char className[16];
    GetClassName(classId, className, sizeof(className));
    UpdateGameModeName();
    char modeName[64];
    strcopy(modeName, sizeof(modeName), g_sGameMode[0] ? g_sGameMode : "this map");
    CPrintToChat(client, "{olive}[Class Limits]{default} Class {yellow}%s{default} is restricted to {gold}%d{default} on {gold}%s{default}!", className, limit >= 0 ? limit : 0, modeName);
}

static void RememberClassAvailabilityRequest(int client, int classId)
{
    if (client <= 0 || client > MaxClients
        || classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
    {
        return;
    }

    g_iPendingClassAvailability[client] = classId;
    g_iPendingClassAvailabilityExpiresAt[client] = GetTime() + CLASS_AVAILABILITY_REQUEST_LIFETIME;
}

static void ClearClassAvailabilityRequest(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_iPendingClassAvailability[client] = TF_CLASS_UNKNOWN;
    g_iPendingClassAvailabilityExpiresAt[client] = 0;
}

static void ClearAllClassAvailabilityRequests()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ClearClassAvailabilityRequest(client);
    }
}

static void CheckPendingClassAvailability()
{
    int now = GetTime();
    for (int client = 1; client <= MaxClients; client++)
    {
        int classId = g_iPendingClassAvailability[client];
        if (classId == TF_CLASS_UNKNOWN)
        {
            continue;
        }

        if (!IsClientInGame(client)
            || g_iPendingClassAvailabilityExpiresAt[client] <= now)
        {
            ClearClassAvailabilityRequest(client);
            continue;
        }

        if (!IsClassAvailableForClient(client, classId))
        {
            continue;
        }

        CPrintToChat(client,
            "{olive}[Class Limits]{default} {yellow}%s{default} is now available.",
            g_ClassNames[classId]);
        ClearClassAvailabilityRequest(client);
    }
}

static bool IsClassAvailableForClient(int client, int classId)
{
    if (g_hEnabled == null || !g_hEnabled.BoolValue || IsClassLimitImmune(client))
    {
        return true;
    }
    if (IsClientClassBanned(client, classId) || IsClassPopulationRestricted(classId))
    {
        return false;
    }

    if (classId == TF_CLASS_MEDIC && !MedicCountsTowardClassLimit(client))
    {
        return true;
    }

    int team = GetClientTeam(client);
    if (team < TF_TEAM_RED || team > TF_TEAM_BLU)
    {
        return false;
    }

    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null || limitCvar.FloatValue < 0.0)
    {
        return true;
    }

    float configuredLimit = limitCvar.FloatValue;
    int limit = configuredLimit > 0.0 && configuredLimit < 1.0
        ? RoundToNearest(configuredLimit * GetHumanTeamClientCount(team))
        : RoundToNearest(configuredLimit);
    if (limit <= 0)
    {
        return false;
    }

    int scoreThreshold = 0;
    bool haveThreshold = g_hTopScore.BoolValue && GetTeamTopScoreThreshold(team, scoreThreshold);
    int occupiedSlots = 0;
    for (int other = 1; other <= MaxClients; other++)
    {
        if (other == client || !IsClientInGame(other) || IsFakeClient(other)
            || GetClientTeam(other) != team
            || view_as<int>(TF2Classes_GetCurrentOrDesired(other)) != classId)
        {
            continue;
        }
        if (classId == TF_CLASS_MEDIC && !MedicCountsTowardClassLimit(other))
        {
            continue;
        }
        if (haveThreshold && GetClientScore(other) >= scoreThreshold)
        {
            continue;
        }

        occupiedSlots++;
    }

    return occupiedSlots < limit;
}

void FormatClassLimitText(int classId, char[] buffer, int maxlen)
{
    if (classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
        { strcopy(buffer, maxlen, "Unknown"); return; }
    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null) { strcopy(buffer, maxlen, "Default"); return; }
    if (IsClassPopulationRestricted(classId))
    {
        int currentPlayers, threshold;
        GetClassPopulationRestrictionState(classId, currentPlayers, threshold);
        Format(buffer, maxlen, "0 players (population gate: %d/%d)", currentPlayers, threshold);
        return;
    }
    float value = limitCvar.FloatValue;
    if (value < 0.0)                 { strcopy(buffer, maxlen, "Unlimited"); return; }
    if (value > 0.0 && value < 1.0) { Format(buffer, maxlen, "%.0f%% of team", value * 100.0); return; }
    Format(buffer, maxlen, "%d players", RoundToNearest(value));
}

void UpdateGameModeName()
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") != FeatureStatus_Available)
    {
        strcopy(g_sGameMode, sizeof(g_sGameMode), "this map");
        return;
    }

    DGM_GetGameModeKey(g_sGameMode, sizeof(g_sGameMode));
    TrimString(g_sGameMode);
    if (!g_sGameMode[0])
        strcopy(g_sGameMode, sizeof(g_sGameMode), "this map");
}

void GetClassName(int classId, char[] buffer, int maxlen)
{
    if (classId >= TF_CLASS_SCOUT && classId <= TF_CLASS_ENGINEER)
        strcopy(buffer, maxlen, g_ClassNames[classId]);
    else
        strcopy(buffer, maxlen, "Unknown");
}
