#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <tf2_stocks>

#define CHECK_INTERVAL 5.0
#define TEAM_RED 2
#define TEAM_BLUE 3

Handle g_hImmunityCookie;
bool g_bClearImmunity[MAXPLAYERS + 1];
ConVar g_hLogEnabled;
ConVar g_hMpAutoteamBalance;
ConVar g_hMpTeamsUnbalanceLimit;
char g_sLogPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name = "autobalance",
    author = "Hombre",
    description = "Moves low-scoring players when teams are imbalanced.",
    version = "1.1",
    url = ""
};

public void OnPluginStart()
{
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");

    g_hImmunityCookie = RegClientCookie(
        "autobalance_immune",
        "Autobalance immunity for current map",
        CookieAccess_Private);

    ApplyServerBalanceCvars(true);
    CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);
}

public void OnMapStart()
{
    ResetImmunityForConnectedClients();
}

public void OnClientCookiesCached(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (g_bClearImmunity[client])
    {
        SetClientCookie(client, g_hImmunityCookie, "0");
        g_bClearImmunity[client] = false;
    }
}

public Action Timer_Autobalance(Handle timer)
{
    int redCount = CountTeamPlayers(TEAM_RED);
    int blueCount = CountTeamPlayers(TEAM_BLUE);

    int diff = redCount - blueCount;
    int absDiff = (diff < 0) ? -diff : diff;
    int bigTeam = 0;
    if (absDiff >= 2)
    {
        bigTeam = (diff > 0) ? TEAM_RED : TEAM_BLUE;
    }

    if (bigTeam == 0)
    {
        return Plugin_Continue;
    }

    bool forceBalance = (absDiff > 2);
    LogBalance("Imbalance detected: red=%d blue=%d bigTeam=%s force=%s", redCount, blueCount, (bigTeam == TEAM_RED) ? "RED" : "BLU", forceBalance ? "yes" : "no");
    PrintToServer("Imbalance detected: red=%d blue=%d bigTeam=%s force=%s", redCount, blueCount, (bigTeam == TEAM_RED) ? "RED" : "BLU", forceBalance ? "yes" : "no");

    int totalScore = 0;
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsEligiblePlayer(i, bigTeam))
        {
            continue;
        }
        totalScore += GetClientScore(i);
        totalPlayers++;
    }

    if (totalPlayers == 0)
    {
        LogBalance("No eligible players on %s team.", (bigTeam == TEAM_RED) ? "RED" : "BLU");
        return Plugin_Continue;
    }

    float avg = float(totalScore) / float(totalPlayers);

    int candidates[MAXPLAYERS];
    int candidateCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsEligiblePlayer(i, bigTeam))
        {
            continue;
        }

        TFClassType cls = TF2_GetPlayerClass(i);
        if (cls == TFClass_Engineer || cls == TFClass_Medic)
        {
            continue;
        }

        if (!forceBalance)
        {
            if (GetRandomInt(0, 1)) // A 50% chance to ignore these conditions to make autobalances less infrequent
            {
                if (IsPlayerAlive(i))
                {
                    continue;
                }

                if (float(GetClientScore(i)) >= avg)
                {
                    continue;
                }
            }
        }

        candidates[candidateCount++] = i;
    }

    if (candidateCount == 0)
    {
        LogBalance("No eligible candidates%s on %s team. avg=%.2f threshhold=%.2f total=%d", forceBalance ? "" : " below threshold", (bigTeam == TEAM_RED) ? "RED" : "BLU", avg, avg, totalPlayers);
        return Plugin_Continue;
    }

    int pick = candidates[GetRandomInt(0, candidateCount - 1)];
    int newTeam = (bigTeam == TEAM_RED) ? TEAM_BLUE : TEAM_RED;
    LogBalance("Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d",
        pick,
        GetClientUserId(pick),
        (bigTeam == TEAM_RED) ? "RED" : "BLU",
        (newTeam == TEAM_RED) ? "RED" : "BLU",
        GetClientScore(pick),
        avg,
        candidateCount);
    ChangeClientTeam(pick, newTeam);
    SetClientImmunity(pick, true);

    CreateTimer(0.1, Timer_Respawn, GetClientUserId(pick), TIMER_FLAG_NO_MAPCHANGE);

    char teamName[8];
    strcopy(teamName, sizeof(teamName), (newTeam == TEAM_RED) ? "Red" : "Blue");
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to {teamcolor}%s{default}!", teamName);
    return Plugin_Continue;
}

public Action Timer_Respawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client))
    {
        TF2_RespawnPlayer(client);
    }
    return Plugin_Stop;
}

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }
    if (GetClientTeam(client) != team)
    {
        return false;
    }
    if (IsClientImmune(client))
    {
        return false;
    }
    return true;
}

static bool IsClientImmune(int client)
{
    if (!AreClientCookiesCached(client))
    {
        return false;
    }

    char value[4];
    GetClientCookie(client, g_hImmunityCookie, value, sizeof(value));
    return (value[0] == '1');
}

static void SetClientImmunity(int client, bool immune)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    SetClientCookie(client, g_hImmunityCookie, immune ? "1" : "0");
    if (!immune)
    {
        g_bClearImmunity[client] = false;
    }
}

static void ResetImmunityForConnectedClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        if (AreClientCookiesCached(i))
        {
            SetClientCookie(i, g_hImmunityCookie, "0");
            g_bClearImmunity[i] = false;
        }
        else
        {
            g_bClearImmunity[i] = true;
        }
    }
}

static int CountTeamPlayers(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsEligiblePlayer(i, team))
        {
            count++;
        }
    }
    return count;
}

static int GetClientScore(int client)
{
    return GetClientFrags(client);
}

static void LogBalance(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
    {
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");
    }

    if (g_hMpTeamsUnbalanceLimit == null)
    {
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");
    }

    if (g_hMpAutoteamBalance != null)
    {
        g_hMpAutoteamBalance.IntValue = pluginLoaded ? 0 : 1;
    }

    if (g_hMpTeamsUnbalanceLimit != null)
    {
        g_hMpTeamsUnbalanceLimit.IntValue = 1;
    }
}
