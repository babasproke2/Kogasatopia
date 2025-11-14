#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <morecolors>

float g_fLastCheck;
int   g_iLastTick;
float g_fLastRealtime;
float g_fLastEnginetime;
float g_fLastGametime;
float g_fLastSysTime;

public Plugin myinfo =
{
    name        = "DDOS Check Multi",
    author      = "Hombre + ChatGPT",
    description = "Compares 5 tickrate measurement techniques",
    version     = "2.0"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_ddos", Cmd_DDos);
    RegConsoleCmd("sm_lag", Cmd_DDos);
    AddCommandListener(OnPlayerSay, "say");
    AddCommandListener(OnPlayerSay, "say_team");

    g_fLastCheck      = GetTickedTime();
    g_fLastRealtime   = GetEngineTime();
    g_fLastEnginetime = GetEngineTime();
    g_fLastGametime   = GetGameTime();
    g_fLastSysTime    = GetGameTime();
    g_iLastTick       = GetGameTickCount();
}

public Action OnPlayerSay(int client, const char[] command, int argc)
{
    char msg[256];
    GetCmdArgString(msg, sizeof(msg));
    TrimString(msg);
    StripQuotes(msg);
    if (StrContains(msg, "ddos", false) != -1 || StrContains(msg, " lag", false) != -1 || StrEqual(msg, "lag"))
        CheckServerStats(client);
    return Plugin_Continue;
}

public Action Cmd_DDos(int client, int args)
{
    CheckServerStats(client);
    return Plugin_Handled;
}

// ------------------------------------
// 5 Method Comparison
// ------------------------------------
void CheckServerStats(int client)
{
    int   currentTick = GetGameTickCount();
    float tickDiff    = float(currentTick - g_iLastTick);
    g_iLastTick       = currentTick;

    // method A: using GetTickedTime()
    float nowA = GetTickedTime();
    float diffA = nowA - g_fLastCheck;
    g_fLastCheck = nowA;
    float calcA = (diffA > 0.0) ? (tickDiff / diffA) : 66.6;

    // method B: using GetEngineTime()
    float nowB = GetEngineTime();
    float diffB = nowB - g_fLastEnginetime;
    g_fLastEnginetime = nowB;
    float calcB = (diffB > 0.0) ? (tickDiff / diffB) : 66.6;

    // method C: using GetGameTime()
    float nowC = GetGameTime();
    float diffC = nowC - g_fLastGametime;
    g_fLastGametime = nowC;
    float calcC = (diffC > 0.0) ? (tickDiff / diffC) : 66.6;

    float nowD = GetGameTime();
    float diffD = (nowD - g_fLastSysTime) / 1000.0; // convert ms → sec
    g_fLastSysTime = nowD;
    float calcD = (diffD > 0.0) ? (tickDiff / diffD) : 66.6;

    // method E: using system absolute time
    float nowE = GetEngineTime() + GetGameFrameTime(); // mixed sample
    static float lastE = 0.0;
    float diffE = nowE - lastE;
    lastE = nowE;
    float calcE = (diffE > 0.0) ? (tickDiff / diffE) : 66.6;

    float desired = (1.0 / GetTickInterval());

    // Determine health color
    char result[64];
    if (calcB >= 63.0)
        strcopy(result, sizeof(result), "\x04No server lag detected");
    else if (calcB >= 60.0)
        strcopy(result, sizeof(result), "\x03Server lag unlikely");
    else if (calcB >= 50.0)
        strcopy(result, sizeof(result), "{yellow}Server lag/DDOS possible");
    else
        strcopy(result, sizeof(result), "{crimson}Server lag/DDOS ongoing");

    if (client > 0)
    {
        CPrintToChat(client, "{green}[Tick Test]{default} Desired: %.1f", desired);
        CPrintToChat(client, "A (TickedTime): %.2f", calcA);
        CPrintToChat(client, "B (EngineTime): %.2f", calcB);
        CPrintToChat(client, "C (GameTime):   %.2f", calcC);
        CPrintToChat(client, "D (SysTick):    %.2f", calcD);
        CPrintToChat(client, "E (Hybrid):     %.2f  - %s", calcE, result);
    }

    PrintToServer("[TickTest] desired=%.2f A=%.2f B=%.2f C=%.2f D=%.2f E=%.2f", desired, calcA, calcB, calcC, calcD, calcE);
}
