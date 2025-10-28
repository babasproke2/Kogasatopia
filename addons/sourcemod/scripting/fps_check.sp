#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <morecolors>

public Plugin myinfo = 
{
    name = "DDOS Check",
    author = "Hombre",
    description = "Informs clients of potential lag with chat listeners",
    version = "1.0"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_ddos", Cmd_DDos);
    RegConsoleCmd("sm_lag", Cmd_DDos);
    AddCommandListener(OnPlayerSay, "say");
    AddCommandListener(OnPlayerSay, "say_team");
}

// Listen for keywords in chat
public Action OnPlayerSay(int client, const char[] command, int argc)
{
    char msg[256];
    GetCmdArgString(msg, sizeof(msg));
    TrimString(msg);
    StripQuotes(msg);

    if (StrContains(msg, "ddos", false) != -1 || StrContains(msg, "lag", false) != -1)
    {
        CheckServerStats(client);
    }
    return Plugin_Continue;
}

// Command handler
public Action Cmd_DDos(int client, int args)
{
    CheckServerStats(client);
    return Plugin_Handled;
}

void CheckServerStats(int client)
{
    float gft = GetGameFrameTime(); // The actual time between frames
    float gti = GetTickInterval(); // Get Tick Interval is the desired interval for the game to run at
    float basis = 200.0 / 3.0; // This is why we get 66.66 in game
    float scalar = CalculateServerFPS(gft, gti);
    float calculated = basis * scalar;
    char result[32];

    if (calculated >= 63.0)
    {
        strcopy(result, sizeof(result), "\x04No server lag detected");
    }
    else if (calculated >= 60.0)
    {
        strcopy(result, sizeof(result), "\x03Server lag unlikely");
    }
    else if (calculated >= 50.0)
    {
        strcopy(result, sizeof(result), "{yellow}Server lag/DDOS possible");
    }
    else
    {
        strcopy(result, sizeof(result), "{lightred}Server lag/DDOS ongoing");
    }

    if (client > 0)
        CPrintToChat(client, "Tickrate: %.1f / %.1f Result: %s", calculated, basis, result);
    PrintToServer("Tickrate: %.1f Desired: %.1f", calculated, basis);
}

public float CalculateServerFPS(float gft, float gti)
{
    return (gft / gti);
}