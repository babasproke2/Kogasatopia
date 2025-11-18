#include <sourcemod>
#include <tf2_stocks>
#include <controlpoints>
#include <morecolors>
#include <tf2>

#pragma semicolon 1
#pragma tabsize 4
#pragma newdecls required

#define PL_VERSION "1.0.0"

#define TF_CLASS_DEMOMAN        4
#define TF_CLASS_ENGINEER       9
#define TF_CLASS_HEAVY          6
#define TF_CLASS_MEDIC          5
#define TF_CLASS_PYRO               7
#define TF_CLASS_SCOUT          1
#define TF_CLASS_SNIPER         2
#define TF_CLASS_SOLDIER        3
#define TF_CLASS_SPY                8
#define TF_CLASS_UNKNOWN        0

#define TF_TEAM_BLU                 3
#define TF_TEAM_RED                 2

public Plugin myinfo =
{
    name        = "TF2 Class Limits",
    author      = "Tsunami (updated by Codex)",
    description = "Restrict classes evenly across teams in TF2.",
    version     = PL_VERSION,
    url         = "https://kogasa.tf"
};

int g_iClass[MAXPLAYERS + 1];
ConVar g_hEnabled;
ConVar g_hFlags;
ConVar g_hImmunity;
ConVar g_hBanConfig;
ConVar g_hLimits[TF_CLASS_ENGINEER + 1];
char g_sGameMode[32] = "Default";
StringMap g_ClassBanMap = null;

static const char g_ClassNames[TF_CLASS_ENGINEER + 1][16] = {
    "Unknown",
    "Scout",
    "Sniper",
    "Soldier",
    "Demoman",
    "Medic",
    "Heavy",
    "Pyro",
    "Spy",
    "Engineer"
};

static const char g_ClassSuffixes[TF_CLASS_ENGINEER + 1][12] = {
    "unknown",
    "scouts",
    "snipers",
    "soldiers",
    "demomen",
    "medics",
    "heavies",
    "pyros",
    "spies",
    "engineers"
};

char g_sSounds[10][24] = {"", "vo/scout_no03.mp3",   "vo/sniper_no04.mp3", "vo/soldier_no01.mp3",
                                "vo/demoman_no03.mp3", "vo/medic_no03.mp3",  "vo/heavy_no02.mp3",
                                "vo/pyro_no01.mp3",    "vo/spy_no02.mp3",    "vo/engineer_no03.mp3"};

public void OnPluginStart()
{
    CreateConVar("classlimits_version", PL_VERSION, "Restrict classes in TF2.", FCVAR_NOTIFY);
    g_hEnabled  = CreateConVar("restrict_enabled",  "1",  "Enable or disable class limits.");
    g_hFlags    = CreateConVar("restrict_flags",    "z",  "Admin flags allowed to bypass class limits.");
    g_hImmunity = CreateConVar("restrict_immunity", "0",  "Enable/disable admin immunity for class limits.");
    g_hBanConfig = CreateConVar("sm_classlimits_bans", "", "Semicolon separated Steam3=class list entries (e.g. [U:1:123]=pyro,spy;[U:1:456]=scout)");
    g_hBanConfig.AddChangeHook(OnClassBanChanged);

    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        char cvarName[32];
        char description[64];
        Format(cvarName, sizeof(cvarName), "restrict_%s", g_ClassSuffixes[classId]);
        Format(description, sizeof(description), "Limit for %s.", g_ClassNames[classId]);
        g_hLimits[classId] = CreateConVar(cvarName, "-1", description);
    }

    HookEvent("player_changeclass", Event_PlayerClass);
    HookEvent("player_spawn",       Event_PlayerSpawn);
    HookEvent("player_team",        Event_PlayerTeam);
    RegConsoleCmd("sm_classlimits", Command_ShowClassLimits, "Show current class limits.");
    RegConsoleCmd("sm_classrestrict", Command_ShowClassLimits, "Show current class limits.");
    RegConsoleCmd("sm_cl", Command_ShowClassLimits, "Show current class limits.");
    RegConsoleCmd("sm_cr", Command_ShowClassLimits, "Show current class limits.");
    LoadClassBanConfig();
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
    g_iClass[client] = TF_CLASS_UNKNOWN;
}

public Action Command_ShowClassLimits(int client, int args)
{
    bool fromConsole = (client <= 0 || !IsClientInGame(client));

    UpdateGameModeName();

    if (fromConsole)
    {
        PrintToServer("[Class Limits] Current gamemode: %s", g_sGameMode);
    }
    else
    {
        CPrintToChat(client, "{olive}[Class Limits]{default} Current gamemode: {yellow}%s{default}", g_sGameMode);
    }

    char limitText[32];
    for (int classId = TF_CLASS_SCOUT; classId <= TF_CLASS_ENGINEER; classId++)
    {
        FormatClassLimitText(classId, limitText, sizeof(limitText));

        if (fromConsole)
        {
            PrintToServer("  %s: %s", g_ClassNames[classId], limitText);
        }
        else
        {
            CPrintToChat(client, "{olive}  %s{default}: {gold}%s{default}", g_ClassNames[classId], limitText);
        }
    }

    return Plugin_Handled;
}

public void OnConfigsExecuted()
{
    UpdateGameModeName();
    LoadClassBanConfig();
}

public void Event_PlayerClass(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid")),
        iClass  = event.GetInt("class"),
        iTeam   = GetClientTeam(iClient);

    int limit;
    if (!(g_hImmunity.BoolValue && IsImmune(iClient)) && IsClassAtLimit(iTeam, iClass, limit))
    {
        //ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
        EmitSoundToClient(iClient, g_sSounds[iClass]);
        NotifyClassRestricted(iClient, iClass, limit);
        TF2_SetPlayerClass(iClient, view_as<TFClassType>(g_iClass[iClient]));
    }
    else if (IsClassBanned(iClient, iClass))
    {
        EmitSoundToClient(iClient, g_sSounds[iClass]);
        NotifyClassBanned(iClient, iClass);
        TF2_SetPlayerClass(iClient, view_as<TFClassType>(g_iClass[iClient]));
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid")),
        iTeam   = GetClientTeam(iClient);

    g_iClass[iClient] = view_as<int>(TF2_GetPlayerClass(iClient));

    int limit;
    if (!(g_hImmunity.BoolValue && IsImmune(iClient)) && IsClassAtLimit(iTeam, g_iClass[iClient], limit))
    {
        //ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
        NotifyClassRestricted(iClient, g_iClass[iClient], limit);
        EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        PickClass(iClient);
    }
    else if (IsClassBanned(iClient, g_iClass[iClient]))
    {
        NotifyClassBanned(iClient, g_iClass[iClient]);
        EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        PickClass(iClient);
    }
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid")),
        iTeam   = event.GetInt("team");

    int limit;
    if (!(g_hImmunity.BoolValue && IsImmune(iClient)) && IsClassAtLimit(iTeam, g_iClass[iClient], limit))
    {
        //ShowVGUIPanel(iClient, iTeam == TF_TEAM_BLU ? "class_blue" : "class_red");
        EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        NotifyClassRestricted(iClient, g_iClass[iClient], limit);
    }
    else if (IsClassBanned(iClient, g_iClass[iClient]))
    {
        EmitSoundToClient(iClient, g_sSounds[g_iClass[iClient]]);
        NotifyClassBanned(iClient, g_iClass[iClient]);
    }
}

bool ClientCountsForSniper(int client)
{
    if (client <= 0)
    {
        return false;
    }

    if (view_as<int>(TF2_GetPlayerClass(client)) != TF_CLASS_SNIPER)
    {
        return false;
    }

    int weapon = GetPlayerWeaponSlot(client, TFWeaponSlot_Primary);
    if (weapon <= 0)
    {
        return true;
    }

    int itemDef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
    if (itemDef == 56 || itemDef == 1092 || itemDef == 1005)
    {
        return false;
    }

    return true;
}

bool IsClassAtLimit(int iTeam, int iClass, int &limitOut)
{
    limitOut = -1;

    if (!g_hEnabled.BoolValue || iTeam < TF_TEAM_RED || iClass < TF_CLASS_SCOUT || iClass > TF_CLASS_ENGINEER)
    {
        return false;
    }

    ConVar limitCvar = g_hLimits[iClass];
    if (limitCvar == null)
    {
        return false;
    }

    float flLimit = limitCvar.FloatValue;
    if (flLimit < 0.0)
    {
        return false;
    }

    if (flLimit > 0.0 && flLimit < 1.0)
    {
        limitOut = RoundToNearest(flLimit * GetTeamClientCount(iTeam));
    }
    else
    {
        limitOut = RoundToNearest(flLimit);
    }

    if (limitOut <= 0)
    {
        return (limitOut == 0);
    }

    for (int i = 1, iCount = 0; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != iTeam)
        {
            continue;
        }

        if (view_as<int>(TF2_GetPlayerClass(i)) != iClass)
        {
            continue;
        }

        if (iClass == TF_CLASS_SNIPER && !ClientCountsForSniper(i))
        {
            continue;
        }

        if (++iCount > limitOut)
        {
            return true;
        }
    }

    return false;
}

bool IsImmune(int iClient)
{
    if (!iClient || !IsClientInGame(iClient))
        return false;

    char sFlags[32];
    g_hFlags.GetString(sFlags, sizeof(sFlags));

    // If flags are specified and client has generic or root flag, client is immune
    return !StrEqual(sFlags, "") && CheckCommandAccess(iClient, "classrestrict", ReadFlagString(sFlags));
}

void PickClass(int iClient)
{
    // Loop through all classes, starting at random class
    for (int i = GetRandomInt(TF_CLASS_SCOUT, TF_CLASS_ENGINEER), iClass = i, iTeam = GetClientTeam(iClient);;)
    {
        // If team's class is not full, set client's class
        int limit;
        if (!IsClassAtLimit(iTeam, i, limit))
        {
            TF2_SetPlayerClass(iClient, view_as<TFClassType>(i));
            TF2_RespawnPlayer(iClient);
            g_iClass[iClient] = i;
            break;
        }
        // If next class index is invalid, start at first class
        else if (++i > TF_CLASS_ENGINEER)
            i = TF_CLASS_SCOUT;
        // If loop has finished, stop searching
        else if (i == iClass)
            break;
    }
}

void NotifyClassRestricted(int client, int classId, int limit)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char className[16];
    GetClassName(classId, className, sizeof(className));

    char modeName[32];
    if (g_sGameMode[0])
    {
        strcopy(modeName, sizeof(modeName), g_sGameMode);
    }
    else
    {
        strcopy(modeName, sizeof(modeName), "this map");
    }

    int displayLimit = limit >= 0 ? limit : 0;

    CPrintToChat(client, "{olive}[Class Limits]{default} Class {yellow}%s{default} is restricted to {gold}%d{default} on {gold}%s{default}!", className, displayLimit, modeName);
}

void FormatClassLimitText(int classId, char[] buffer, int maxlen)
{
    if (classId < TF_CLASS_SCOUT || classId > TF_CLASS_ENGINEER)
    {
        strcopy(buffer, maxlen, "Unknown");
        return;
    }

    ConVar limitCvar = g_hLimits[classId];
    if (limitCvar == null)
    {
        strcopy(buffer, maxlen, "Default");
        return;
    }

    float value = limitCvar.FloatValue;
    if (value < 0.0)
    {
        strcopy(buffer, maxlen, "Unlimited");
        return;
    }

    if (value > 0.0 && value < 1.0)
    {
        Format(buffer, maxlen, "%.0f%% of team", value * 100.0);
        return;
    }

    Format(buffer, maxlen, "%d players", RoundToNearest(value));
}

void UpdateGameModeName()
{
    TF2_GameMode gameMode = TF2_DetectGameMode();

    switch (gameMode)
    {
        case TF2_GameMode_Arena:      strcopy(g_sGameMode, sizeof(g_sGameMode), "Arena");
        case TF2_GameMode_Medieval:   strcopy(g_sGameMode, sizeof(g_sGameMode), "Medieval");
        case TF2_GameMode_PD:         strcopy(g_sGameMode, sizeof(g_sGameMode), "Player Destruction");
        case TF2_GameMode_KOTH:       strcopy(g_sGameMode, sizeof(g_sGameMode), "King of the Hill");
        case TF2_GameMode_PL:         strcopy(g_sGameMode, sizeof(g_sGameMode), "Payload");
        case TF2_GameMode_PLR:        strcopy(g_sGameMode, sizeof(g_sGameMode), "Payload Race");
        case TF2_GameMode_CTF:        strcopy(g_sGameMode, sizeof(g_sGameMode), "Capture the Flag");
        case TF2_GameMode_5CP:        strcopy(g_sGameMode, sizeof(g_sGameMode), "Control Point");
        case TF2_GameMode_ADCP:       strcopy(g_sGameMode, sizeof(g_sGameMode), "Attack/Defend CP");
        case TF2_GameMode_TC:         strcopy(g_sGameMode, sizeof(g_sGameMode), "Territorial Control");
        default:                      strcopy(g_sGameMode, sizeof(g_sGameMode), "Default");
    }
}

void GetClassName(int classId, char[] buffer, int maxlen)
{
    if (classId >= TF_CLASS_SCOUT && classId <= TF_CLASS_ENGINEER)
    {
        strcopy(buffer, maxlen, g_ClassNames[classId]);
    }
    else
    {
        strcopy(buffer, maxlen, "Unknown");
    }
}

void LoadClassBanConfig()
{
    if (g_ClassBanMap != null)
    {
        delete g_ClassBanMap;
    }
    g_ClassBanMap = new StringMap();

    char raw[2048];
    if (g_hBanConfig != null)
    {
        g_hBanConfig.GetString(raw, sizeof(raw));
    }
    TrimString(raw);
    if (!raw[0])
    {
        LogMessage("[ClassLimits] No class ban entries configured.");
        return;
    }

    int entryCount = 0;
    char entries[64][128];
    int total = ExplodeString(raw, ";", entries, sizeof(entries), sizeof(entries[]));
    if (total <= 0)
    {
        total = 1;
        strcopy(entries[0], sizeof(entries[]), raw);
    }

    for (int i = 0; i < total; i++)
    {
        TrimString(entries[i]);
        if (!entries[i][0])
        {
            continue;
        }
        char steam[64];
        char classList[256];
        char pieces[2][256];
        if (ExplodeString(entries[i], "=", pieces, sizeof(pieces), sizeof(pieces[])) < 2)
        {
            continue;
        }
        strcopy(steam, sizeof(steam), pieces[0]);
        strcopy(classList, sizeof(classList), pieces[1]);
        TrimString(steam);
        TrimString(classList);
        if (!steam[0] || !classList[0])
        {
            continue;
        }
        int mask = 0;
        char classes[16][32];
        int classCount = ExplodeString(classList, ",", classes, sizeof(classes), sizeof(classes[]));
        if (classCount <= 0)
        {
            classCount = 1;
            strcopy(classes[0], sizeof(classes[]), classList);
        }
        for (int j = 0; j < classCount; j++)
        {
            TrimString(classes[j]);
            int classId = ClassNameToId(classes[j]);
            if (classId != TF_CLASS_UNKNOWN)
            {
                mask |= (1 << classId);
            }
        }
        if (mask != 0)
        {
            g_ClassBanMap.SetValue(steam, mask);
            entryCount++;
        }
    }

    LogMessage("[ClassLimits] Loaded %d class ban entries from sm_classlimits_bans", entryCount);
}

int ClassNameToId(const char[] input)
{
    char name[32];
    strcopy(name, sizeof(name), input);
    TrimString(name);
    for (int i = 0; name[i] != '\0'; i++)
    {
        name[i] = CharToLower(name[i]);
    }
    if (StrEqual(name, "scout")) return TF_CLASS_SCOUT;
    if (StrEqual(name, "sniper")) return TF_CLASS_SNIPER;
    if (StrEqual(name, "soldier")) return TF_CLASS_SOLDIER;
    if (StrEqual(name, "demoman") || StrEqual(name, "demo")) return TF_CLASS_DEMOMAN;
    if (StrEqual(name, "medic")) return TF_CLASS_MEDIC;
    if (StrEqual(name, "heavy") || StrEqual(name, "heavyweapons")) return TF_CLASS_HEAVY;
    if (StrEqual(name, "pyro")) return TF_CLASS_PYRO;
    if (StrEqual(name, "spy")) return TF_CLASS_SPY;
    if (StrEqual(name, "engineer") || StrEqual(name, "engi")) return TF_CLASS_ENGINEER;
    return TF_CLASS_UNKNOWN;
}

bool IsClassBanned(int client, int classId)
{
    if (g_ClassBanMap == null || client <= 0 || !IsClientInGame(client))
    {
        return false;
    }
    char steam[64];
    if (!GetClientAuthId(client, AuthId_Steam3, steam, sizeof(steam)))
    {
        return false;
    }
    int mask;
    if (!g_ClassBanMap.GetValue(steam, mask))
    {
        return false;
    }
    return (mask & (1 << classId)) != 0;
}

public void OnClassBanChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    LoadClassBanConfig();
}

void NotifyClassBanned(int client, int classId)
{
    if (!IsClientInGame(client))
    {
        return;
    }
    char name[32];
    GetClassName(classId, name, sizeof(name));
    CPrintToChat(client, "{olive}[Class Limits]{default} You are banned from playing {red}%s{default}.", name);
}
