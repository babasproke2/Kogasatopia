#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

static const char g_sUncleNames[][] =
{
    "Uncletopia | Chicago | 1 | All Maps",
    "Uncletopia | Chicago | 3 | All Maps",
    "Uncletopia | Chicago | 2 | All Maps",
    "Uncletopia | New York City | 1 | All Maps",
    "Uncletopia | New York City | 2 | All Maps+"
};
#define UNCLE_NAME_COUNT 5

ConVar g_hHostname = null;
ConVar g_hDynamic = null;
ConVar g_hActiveCvar = null;

Handle g_hUncleTimer = null;
int g_iUncleIndex = 0;
bool g_bOriginalSet = false;
char g_sOriginalHostname[256];

public Plugin myinfo =
{
    name = "Uncle Hostname Cycler",
    author = "Cogwheel",
    description = "Cycles Uncletopia hostnames and restores the original on demand.",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart()
{
    g_hHostname = FindConVar("hostname");
    g_hDynamic = CreateConVar("sm_uncle_dynamic", "0", "Enable dynamic Uncletopia hostname cycling when player count is between 4 and 23.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hDynamic.AddChangeHook(ConVarChanged_Dynamic);
    g_hActiveCvar = CreateConVar("sm_uncle_active", "0", "Whether the Uncletopia hostname cycle is active.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    if (g_hActiveCvar != null)
    {
        g_hActiveCvar.SetBool(false);
    }

    RegAdminCmd("sm_uncle", Command_Uncle, ADMFLAG_GENERIC, "Toggle Uncletopia hostname cycling and store/restore original hostname.");
}

public void OnPluginEnd()
{
    StopUncleCycle(true);
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
        return;

    MaybeStartDynamic();
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
        return;

    if (GetHumanPlayerCount() == 0 && g_hUncleTimer != null)
    {
        StopUncleCycle(true);
        return;
    }

    MaybeStartDynamic();
}

public void ConVarChanged_Dynamic(ConVar convar, const char[] oldValue, const char[] newValue)
{
    MaybeStartDynamic();
}

Action Command_Uncle(int client, int args)
{
    if (g_hHostname == null)
    {
        ReplyToCommand(client, "[Uncle] Hostname convar not found.");
        return Plugin_Handled;
    }

    char current[256];
    g_hHostname.GetString(current, sizeof(current));

    if (!g_bOriginalSet)
    {
        strcopy(g_sOriginalHostname, sizeof(g_sOriginalHostname), current);
        g_bOriginalSet = true;
    }

    if (!StrEqual(current, g_sOriginalHostname))
    {
        StopUncleCycle(false);
        SetConVarString(g_hHostname, g_sOriginalHostname);
        ServerCommand("sv_visiblemaxplayers 28");
        ReplyToCommand(client, "[Uncle] Restored original hostname and visible max players to 28.");
        return Plugin_Handled;
    }

    StartUncleCycle();
    ReplyToCommand(client, "[Uncle] Cycling Uncletopia hostnames every 10 seconds.");
    return Plugin_Handled;
}

void StartUncleCycle()
{
    if (g_hUncleTimer != null)
    {
        return;
    }

    if (!g_bOriginalSet && g_hHostname != null)
    {
        g_hHostname.GetString(g_sOriginalHostname, sizeof(g_sOriginalHostname));
        g_bOriginalSet = true;
    }

    g_iUncleIndex = 0;
    ApplyNextHostname();
    g_hUncleTimer = CreateTimer(10.0, Timer_UncleCycle, _, TIMER_REPEAT);
    if (g_hActiveCvar != null)
    {
        g_hActiveCvar.SetBool(true);
    }
}

void StopUncleCycle(bool revert)
{
    if (g_hUncleTimer != null)
    {
        CloseHandle(g_hUncleTimer);
        g_hUncleTimer = null;
    }

    if (revert && g_bOriginalSet && g_hHostname != null)
    {
        SetConVarString(g_hHostname, g_sOriginalHostname);
        ServerCommand("sv_visiblemaxplayers 28");
    }

    if (g_hActiveCvar != null)
    {
        g_hActiveCvar.SetBool(false);
    }
}

public Action Timer_UncleCycle(Handle timer, any data)
{
    ApplyNextHostname();
    return Plugin_Continue;
}

void ApplyNextHostname()
{
    if (g_hHostname == null)
    {
        return;
    }

    int playerCount = GetClientCount(false);
    if (playerCount > 23)
    {
        if (!g_bOriginalSet)
        {
            g_hHostname.GetString(g_sOriginalHostname, sizeof(g_sOriginalHostname));
            g_bOriginalSet = true;
        }
        if (g_bOriginalSet)
        {
            SetConVarString(g_hHostname, g_sOriginalHostname);
        }
        ServerCommand("sv_visiblemaxplayers 28");
        return;
    }

    SetConVarString(g_hHostname, g_sUncleNames[g_iUncleIndex]);
    ServerCommand("sv_visiblemaxplayers 24");

    g_iUncleIndex = (g_iUncleIndex + 1) % UNCLE_NAME_COUNT;
}

void MaybeStartDynamic()
{
    if (g_hDynamic == null || !g_hDynamic.BoolValue)
    {
        return;
    }

    int players = GetHumanPlayerCount();
    bool withinRange = (players > 3 && players < 24);
    if (withinRange && g_hUncleTimer == null)
    {
        StartUncleCycle();
    }
    else if (!withinRange && g_hUncleTimer != null)
    {
        StopUncleCycle(true);
    }
}

int GetHumanPlayerCount()
{
    int players = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            players++;
        }
    }
    return players;
}
