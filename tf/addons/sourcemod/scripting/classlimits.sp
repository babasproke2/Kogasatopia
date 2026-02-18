#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>
#include <tf2>

#pragma semicolon 1
#pragma tabsize 4
#pragma newdecls required

#define PL_VERSION "1.0.2"

#define TF_CLASS_DEMOMAN        4
#define TF_CLASS_ENGINEER       9
#define TF_CLASS_HEAVY          6
#define TF_CLASS_MEDIC          5
#define TF_CLASS_PYRO           7
#define TF_CLASS_SCOUT          1
#define TF_CLASS_SNIPER         2
#define TF_CLASS_SOLDIER        3
#define TF_CLASS_SPY            8
#define TF_CLASS_CIVILIAN       10
#define TF_CLASS_UNKNOWN        0

#define TF_TEAM_BLU             3
#define TF_TEAM_RED             2

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
ConVar g_hEnabled;
ConVar g_hFlags;
ConVar g_hImmunity;
ConVar g_hTopScore;
ConVar g_hDisplayUnlim;
ConVar g_hLimits[TF_CLASS_CIVILIAN + 1];
char g_sGameMode[32] = "Default";

static const char g_ClassNames[TF_CLASS_CIVILIAN + 1][16] = {
    "Unknown", "Scout", "Sniper", "Soldier", "Demoman",
    "Medic", "Heavy", "Pyro", "Spy", "Engineer", "Civilian"
};

static const char g_ClassSuffixes[TF_CLASS_CIVILIAN + 1][12] = {
    "unknown", "scouts", "snipers", "soldiers", "demomen",
    "medics", "heavies", "pyros", "spies", "engineers", "civilians"
};

char g_sSounds[11][24] = {"", "vo/scout_no03.mp3",   "vo/sniper_no04.mp3", "vo/soldier_no01.mp3",
                                "vo/demoman_no03.mp3", "vo/medic_no03.mp3",  "vo/heavy_no02.mp3",
                                "vo/pyro_no01.mp3",    "vo/spy_no02.mp3",    "vo/engineer_no03.mp3",
                                "vo/civilian_no01.mp3"};

public void OnPluginStart()
{
    CreateConVar("classlimits_version", PL_VERSION, "Restrict classes in TF2.", FCVAR_NOTIFY);
    g_hEnabled      = CreateConVar("restrict_enabled",     "1", "Enable or disable class limits.");
    g_hFlags        = CreateConVar("restrict_flags",       "z", "Admin flags allowed to bypass class limits.");
    g_hImmunity     = CreateConVar("restrict_immunity",    "0", "Enable/disable admin immunity for class limits.");
    g_hTopScore     = CreateConVar("classlimits_topscore", "0", "Allow top team scorers to bypass class limits.", _, true, 0.0, true, 1.0);
    g_hDisplayUnlim = CreateConVar("display_unlim",        "0", "If 1, show unlimited classes in class limit displays.", _, true, 0.0, true, 1.0);

    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_CIVILIAN; classId++)
    {
        if (classId == TF_CLASS_CIVILIAN || classId <= TF_CLASS_ENGINEER)
        {
            char cvarName[32];
            char description[64];
            Format(cvarName, sizeof(cvarName), "restrict_%s", g_ClassSuffixes[classId]);
            Format(description, sizeof(description), "Limit for %s.", g_ClassNames[classId]);
            g_hLimits[classId] = CreateConVar(cvarName, "-1", description);
        }
    }

    HookEvent("player_changeclass", Event_PlayerClass);
    HookEvent("player_spawn",       Event_PlayerSpawn);
    HookEvent("player_team",        Event_PlayerTeam);
    HookEvent("player_say",         Event_PlayerSay, EventHookMode_Post);
    RegConsoleCmd("sm_classlimits", Command_ShowClassLimits, "Show current class limits.");
    RegConsoleCmd("sm_cl",          Command_ShowClassLimits, "Show current class limits.");
}

public void OnMapStart()
{
    char sSound[32];
    for (int i = 1; i < sizeof(g_sSounds); i++)
    {
        Format(sSound, sizeof(sSound), "sound/%s", g_sSounds[i]);
        PrecacheSound(g_sSounds[i]);
        AddFileToDownloadsTable(sSound);
    }
}

public void OnClientPutInServer(int client)
{
    g_iClass[client]                 = TF_CLASS_UNKNOWN;
    g_bForcedRespawn[client]         = false;
    g_iForcedRespawnAttempts[client] = 0;
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

    char limitText[32];
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_CIVILIAN; classId++)
    {
        if (classId != TF_CLASS_CIVILIAN && classId > TF_CLASS_ENGINEER) continue;
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
    if (classId < TF_CLASS_SCOUT || (classId > TF_CLASS_ENGINEER && classId != TF_CLASS_CIVILIAN))
        return false;
    if (g_hDisplayUnlim != null && g_hDisplayUnlim.BoolValue) return true;
    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null) return false;
    return limitCvar.FloatValue >= 0.0;
}

public void OnConfigsExecuted()
{
    UpdateGameModeName();
}

public void Event_PlayerClass(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid"));
    int iClass  = event.GetInt("class");
    int iTeam   = GetClientTeam(iClient);

    int limit;
    if (!IsClassLimitImmune(iClient) && IsClassAtLimit(iTeam, iClass, limit))
    {
        if (iClass >= 0 && iClass < sizeof(g_sSounds) && g_sSounds[iClass][0])
            EmitSoundToClient(iClient, g_sSounds[iClass]);

        NotifyClassRestricted(iClient, iClass, limit);

        // Revert the class selection and reopen the class panel.
        // Never call TF2_RespawnPlayer here — the panel keeps them off the
        // field, and Event_PlayerSpawn enforces the limit when they spawn.
        TF2_SetPlayerClass(iClient, view_as<TFClassType>(g_iClass[iClient]));
        ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
    }
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
    if (!IsClassLimitImmune(iClient) && IsClassAtLimit(iTeam, g_iClass[iClient], limit))
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
    int iClient = GetClientOfUserId(event.GetInt("userid"));
    int iTeam   = event.GetInt("team");

    int limit;
    if (!IsClassLimitImmune(iClient) && IsClassAtLimit(iTeam, g_iClass[iClient], limit))
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

bool IsClassAtLimit(int iTeam, int iClass, int &limitOut)
{
    limitOut = -1;
    if (!g_hEnabled.BoolValue || iTeam < TF_TEAM_RED || iClass < TF_CLASS_SCOUT || (iClass > TF_CLASS_ENGINEER && iClass != TF_CLASS_CIVILIAN))
        return false;

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
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != iTeam || view_as<int>(TF2_GetPlayerClass(i)) != iClass) continue;
        if (haveThreshold && GetClientScore(i) >= scoreThreshold) continue;
        if (++iCount > limitOut) return true;
    }
    return false;
}

bool IsImmune(int iClient)
{
    if (!iClient || !IsClientInGame(iClient)) return false;
    char sFlags[32];
    g_hFlags.GetString(sFlags, sizeof(sFlags));
    return !StrEqual(sFlags, "") && CheckCommandAccess(iClient, "classrestrict", ReadFlagString(sFlags));
}

void PickClass(int iClient)
{
    if (iClient <= 0 || !IsClientInGame(iClient)) return;

    for (int i = GetRandomInt(TF_CLASS_SCOUT, TF_CLASS_CIVILIAN), iClass = i, iTeam = GetClientTeam(iClient);;)
    {
        if (i == TF_CLASS_ENGINEER + 1 && i != TF_CLASS_CIVILIAN)
            i = TF_CLASS_CIVILIAN;

        int limit;
        if (!IsClassAtLimit(iTeam, i, limit))
        {
            g_iForcedRespawnAttempts[iClient]++;
            g_bForcedRespawn[iClient] = true;
            TF2_SetPlayerClass(iClient, view_as<TFClassType>(i));
            TF2_RespawnPlayer(iClient);
            g_iClass[iClient] = i;
            break;
        }
        else if (++i > TF_CLASS_CIVILIAN)
            i = TF_CLASS_SCOUT;
        else if (i == iClass)
            break;
    }
}

void NotifyClassRestricted(int client, int classId, int limit)
{
    if (client <= 0 || !IsClientInGame(client)) return;
    char className[16];
    GetClassName(classId, className, sizeof(className));
    char modeName[32];
    strcopy(modeName, sizeof(modeName), g_sGameMode[0] ? g_sGameMode : "this map");
    CPrintToChat(client, "{olive}[Class Limits]{default} Class {yellow}%s{default} is restricted to {gold}%d{default} on {gold}%s{default}!", className, limit >= 0 ? limit : 0, modeName);
}

void FormatClassLimitText(int classId, char[] buffer, int maxlen)
{
    if (classId < TF_CLASS_SCOUT || (classId > TF_CLASS_ENGINEER && classId != TF_CLASS_CIVILIAN))
        { strcopy(buffer, maxlen, "Unknown"); return; }
    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null) { strcopy(buffer, maxlen, "Default"); return; }
    float value = limitCvar.FloatValue;
    if (value < 0.0)                 { strcopy(buffer, maxlen, "Unlimited"); return; }
    if (value > 0.0 && value < 1.0) { Format(buffer, maxlen, "%.0f%% of team", value * 100.0); return; }
    Format(buffer, maxlen, "%d players", RoundToNearest(value));
}

void UpdateGameModeName()
{
    strcopy(g_sGameMode, sizeof(g_sGameMode), "Default");
}

void GetClassName(int classId, char[] buffer, int maxlen)
{
    if ((classId >= TF_CLASS_SCOUT && classId <= TF_CLASS_ENGINEER) || classId == TF_CLASS_CIVILIAN)
        strcopy(buffer, maxlen, g_ClassNames[classId]);
    else
        strcopy(buffer, maxlen, "Unknown");
}
