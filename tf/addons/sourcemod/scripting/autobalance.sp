#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>
#include <tf2_stocks>

native int FilterAlerts_MarkAutobalance(int client);

#define CHECK_INTERVAL      5.0
#define IMMUNITY_DURATION   300.0   // seconds a player stays immune after being balanced
#define TEAM_RED            2
#define TEAM_BLUE           3

float   g_fImmunityExpiry[MAXPLAYERS + 1];  // GetGameTime() at which immunity expires; 0.0 = not immune
ConVar  g_hLogEnabled;
ConVar  g_hMpAutoteamBalance;
ConVar  g_hMpTeamsUnbalanceLimit;
int     g_iSavedAutoteamBalance;
int     g_iSavedUnbalanceLimit;
char    g_sLogPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name        = "autobalance",
    author      = "Hombre",
    description = "Moves low-scoring players when teams are imbalanced.",
    version     = "1.2",
    url         = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("FilterAlerts_MarkAutobalance");
    return APLRes_Success;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");
    HookEvent("teamplay_round_win", Event_RoundEnd);
    HookEvent("teamplay_round_stalemate", Event_RoundEnd);

    ApplyServerBalanceCvars(true);

    CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Clear autobalance immunity every round, not just when the map changes.
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fImmunityExpiry[i] = 0.0;
    }
}

// ---------------------------------------------------------------------------
// Main balance timer
// ---------------------------------------------------------------------------

public Action Timer_Autobalance(Handle timer)
{
    // Use raw counts (all connected non-bot players) for the imbalance check
    // so that immune players still count toward their team's size.
    int redCount  = CountTeamPlayersRaw(TEAM_RED);
    int blueCount = CountTeamPlayersRaw(TEAM_BLUE);

    int diff    = redCount - blueCount;
    int absDiff = (diff < 0) ? -diff : diff;

    if (absDiff < 2)
    {
        return Plugin_Continue;
    }

    int biggestTeam  = (diff > 0) ? TEAM_RED  : TEAM_BLUE;
    int smallestTeam = (diff > 0) ? TEAM_BLUE : TEAM_RED;
    int biggestCount = (diff > 0) ? redCount   : blueCount;

    bool forceBalance = (absDiff > 2);

    char fromTeamName[8];
    char toTeamName[8];
    strcopy(fromTeamName, sizeof(fromTeamName), (biggestTeam  == TEAM_RED) ? "RED" : "BLU");
    strcopy(toTeamName,   sizeof(toTeamName),   (smallestTeam == TEAM_RED) ? "RED" : "BLU");
    char fromTeamChat[16];
    char toTeamChat[16];
    strcopy(fromTeamChat, sizeof(fromTeamChat), (biggestTeam  == TEAM_RED) ? "{red}RED{default}" : "{blue}BLU{default}");
    strcopy(toTeamChat,   sizeof(toTeamChat),   (smallestTeam == TEAM_RED) ? "{red}RED{default}" : "{blue}BLU{default}");

    LogBalance(
        "Imbalance detected: red=%d blue=%d from=%s to=%s force=%s",
        redCount, blueCount, fromTeamName, toTeamName, forceBalance ? "yes" : "no"
    );
    PrintToServer(
        "[autobalance] Imbalance detected: red=%d blue=%d from=%s to=%s force=%s",
        redCount, blueCount, fromTeamName, toTeamName, forceBalance ? "yes" : "no"
    );

    // ------------------------------------------------------------------
    // Candidate selection.
    //
    // If forceBalance is active (absDiff > 2), switch immediately:
    // pick from any human on the oversized team, regardless of alive
    // state or immunity.
    //
    // Otherwise keep normal two-pass selection:
    //  Pass 1 (strict)    : dead, below-average score, non-Engi/Medic
    //  Pass 2 (relax s/a) : any alive/score state, non-Engi/Medic
    // ------------------------------------------------------------------

    int totalScore   = 0;
    int totalPlayers = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!(forceBalance ? IsEligiblePlayerForce(i, biggestTeam) : IsEligiblePlayer(i, biggestTeam))) continue;

        totalScore += GetClientScore(i);
        totalPlayers++;
    }

    if (totalPlayers == 0)
    {
        int immuneCount = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != biggestTeam) continue;
            if (IsClientImmune(i)) immuneCount++;
        }

        LogBalance(
            "Skip balance on %s: no eligible players (force=%d, teamPlayers=%d, immune=%d)",
            fromTeamName, forceBalance ? 1 : 0, biggestCount, immuneCount
        );
        return Plugin_Continue;
    }

    float avg = float(totalScore) / float(totalPlayers);

    int candidates[MAXPLAYERS];
    int candidateCount = 0;

    if (forceBalance)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayerForce(i, biggestTeam)) continue;

            candidates[candidateCount++] = i;
        }
    }
    else
    {
        // Pass 1: strict — dead, below average, no Engi/Medic.
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayer(i, biggestTeam)) continue;

            TFClassType cls = TF2_GetPlayerClass(i);
            if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;
            if (IsPlayerAlive(i)) continue;
            if (float(GetClientScore(i)) >= avg) continue;

            candidates[candidateCount++] = i;
        }

        // Pass 2: relax score/alive, still exclude Engi/Medic.
        if (candidateCount == 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsEligiblePlayer(i, biggestTeam)) continue;

                TFClassType cls = TF2_GetPlayerClass(i);
                if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;

                candidates[candidateCount++] = i;
            }
        }
    }

    if (candidateCount == 0)
    {
        if (forceBalance)
        {
            LogBalance(
                "Skip balance on %s: force mode had zero candidates (teamPlayers=%d, eligible=%d)",
                fromTeamName, biggestCount, totalPlayers
            );
        }
        else
        {
            int classExcluded = 0;
            int aliveFiltered = 0;
            int scoreFiltered = 0;
            int strictWouldPass = 0;

            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsEligiblePlayer(i, biggestTeam)) continue;

                TFClassType cls = TF2_GetPlayerClass(i);
                if (cls == TFClass_Engineer || cls == TFClass_Medic)
                {
                    classExcluded++;
                    continue;
                }

                bool alive = IsPlayerAlive(i);
                bool highScore = float(GetClientScore(i)) >= avg;

                if (alive) aliveFiltered++;
                if (highScore) scoreFiltered++;
                if (!alive && !highScore) strictWouldPass++;
            }

            LogBalance(
                "Skip balance on %s: no candidates (avg=%.2f eligible=%d classExcluded=%d aliveFiltered=%d scoreFiltered=%d strictPass=%d)",
                fromTeamName, avg, totalPlayers, classExcluded, aliveFiltered, scoreFiltered, strictWouldPass
            );
        }
        return Plugin_Continue;
    }

    // Weight selection toward lowest-scoring candidates.
    // Each candidate's weight is (maxScore - score + 1) so the lowest
    // scorer is most likely to be picked while retaining some randomness.
    int maxScore = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        int s = GetClientScore(candidates[i]);
        if (s > maxScore) maxScore = s;
    }

    int weights[MAXPLAYERS];
    int totalWeight = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        weights[i]   = maxScore - GetClientScore(candidates[i]) + 1;
        totalWeight += weights[i];
    }

    int roll    = GetRandomInt(0, totalWeight - 1);
    int pick    = candidates[0];
    int running = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        running += weights[i];
        if (roll < running)
        {
            pick = candidates[i];
            break;
        }
    }

    LogBalance(
        "Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d biggestCount=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount, biggestCount
    );
    PrintToServer(
        "[autobalance] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount
    );

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_MarkAutobalance") == FeatureStatus_Available)
    {
        FilterAlerts_MarkAutobalance(pick);
    }

    ChangeClientTeam(pick, smallestTeam);
    SetClientImmunity(pick, true);

    CPrintToChatAllEx(
        pick,
        "{tomato}[{purple}Gap{tomato}]{default} Sending {teamcolor}%N{default} from %s to %s",
        pick, fromTeamChat, toTeamChat
    );

    CreateTimer(0.1, Timer_Respawn, GetClientUserId(pick), TIMER_FLAG_NO_MAPCHANGE);

    char teamColorName[16];
    strcopy(teamColorName, sizeof(teamColorName), (smallestTeam == TEAM_RED) ? "{red}Red" : "{blue}Blue");
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to %s{default}!", teamColorName);

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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsClientImmune(client)) return false;

    return true;
}

static bool IsEligiblePlayerForce(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;

    return true;
}

static bool IsClientImmune(int client)
{
    float expiry = g_fImmunityExpiry[client];
    if (expiry <= 0.0) return false;

    if (GetGameTime() >= expiry)
    {
        g_fImmunityExpiry[client] = 0.0;   // Expired; clear lazily.
        return false;
    }

    return true;
}

static void SetClientImmunity(int client, bool immune)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    g_fImmunityExpiry[client] = immune ? (GetGameTime() + IMMUNITY_DURATION) : 0.0;
}

// Raw count: all connected non-bot players on the team, regardless of immunity.
// Used for the imbalance check so immune players still count toward team size.
static int CountTeamPlayersRaw(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (GetClientTeam(i) != team) continue;
        count++;
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

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");

    if (g_hMpTeamsUnbalanceLimit == null)
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");

    if (pluginLoaded)
    {
        if (g_hMpAutoteamBalance != null)
        {
            g_iSavedAutoteamBalance = g_hMpAutoteamBalance.IntValue;
            g_hMpAutoteamBalance.IntValue = 0;
        }

        if (g_hMpTeamsUnbalanceLimit != null)
        {
            g_iSavedUnbalanceLimit = g_hMpTeamsUnbalanceLimit.IntValue;
            g_hMpTeamsUnbalanceLimit.IntValue = 1;
        }
    }
    else
    {
        if (g_hMpAutoteamBalance != null)
            g_hMpAutoteamBalance.IntValue = g_iSavedAutoteamBalance;

        if (g_hMpTeamsUnbalanceLimit != null)
            g_hMpTeamsUnbalanceLimit.IntValue = g_iSavedUnbalanceLimit;
    }
}
