#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <tf2_stocks>
#include <clans_api>
#include <whaletracker_api>

native int FilterAlerts_MarkAutobalance(int client);

#define CHECK_INTERVAL      3.0
#define TEAM_RED            2
#define TEAM_BLUE           3
#define TEAM_GREEN          4
#define TEAM_YELLOW         5
#define GAME_TEAM_COUNT     4
#define MEDIC_AUTOBALANCE_UBER_FLOOR 0.05

static const int g_GameTeams[GAME_TEAM_COUNT] =
{
    TEAM_RED,
    TEAM_BLUE,
    TEAM_GREEN,
    TEAM_YELLOW
};

StringMap g_hMapImmunity = null;            // SteamID64 set for map-long immunity.
StringMap g_hPersistentImmunity = null;     // SteamID64 set for persistent admin immunity.
StringMap g_hVolunteers = null;             // SteamID64 set for persistent autobalance volunteers.
Database  g_hImmunityDb = null;
bool      g_bImmunityDbReady = false;
bool      g_bVolunteerDbReady = false;
ConVar  g_hLogEnabled;
ConVar  g_hDiffThreshold;
ConVar  g_hSimpleSelection;
ConVar  g_hDatabaseConfig;
ConVar  g_hMpAutoteamBalance;
ConVar  g_hMpTeamsUnbalanceLimit;
int     g_iSavedAutoteamBalance;
int     g_iSavedUnbalanceLimit;
char    g_sLogPath[PLATFORM_MAX_PATH];
Handle  g_hAutoBalanceTimer = INVALID_HANDLE;

public Plugin myinfo =
{
    name        = "autobalance_4teams",
    author      = "Hombre",
    description = "Moves players when 4 teams are imbalanced.",
    version     = "1.3",
    url         = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("FilterAlerts_MarkAutobalance");
    MarkNativeAsOptional("Clans_GetSameTeamClanMemberCount");
    MarkNativeAsOptional("WhaleTracker_IsCurrentRoundMvp");
    return APLRes_Success;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    g_hDiffThreshold = CreateConVar("sm_autobalance_diff", "1", "Autobalance when team size difference is above this value.", _, true, 1.0, true, 10.0);
    g_hSimpleSelection = CreateConVar("sm_autobalance_simple_selection", "1", "If enabled, autobalance prefers the most recently joined dead non-Engineer on the oversized team, then falls back to lower-priority eligible players by userID.", _, true, 0.0, true, 1.0);
    g_hDatabaseConfig = CreateConVar("sm_autobalance_database", "default", "Database config name from databases.cfg to use for persistent autobalance immunity.");
    RegAdminCmd("sm_immune", Command_Immune, ADMFLAG_GENERIC, "sm_immune <name> - Toggle persistent autobalance immunity for a player.");
    RegConsoleCmd("sm_volunteer", Command_Volunteer, "sm_volunteer [name] - Toggle autobalance volunteer status.");
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");
    LogToFileEx(g_sLogPath, "[autobalance_4teams] Plugin started.");
    g_hMapImmunity = new StringMap();
    g_hPersistentImmunity = new StringMap();
    g_hVolunteers = new StringMap();

    ApplyServerBalanceCvars(true);
    ConnectImmunityDatabase();
}

public void OnMapStart()
{
    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }

    g_hAutoBalanceTimer = CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT);

    if (g_hMapImmunity != null)
    {
        g_hMapImmunity.Clear();
    }
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);

    if (g_hAutoBalanceTimer != INVALID_HANDLE)
    {
        KillTimer(g_hAutoBalanceTimer);
        g_hAutoBalanceTimer = INVALID_HANDLE;
    }

    if (g_hImmunityDb != null)
    {
        delete g_hImmunityDb;
        g_hImmunityDb = null;
    }

    if (g_hMapImmunity != null)
    {
        delete g_hMapImmunity;
        g_hMapImmunity = null;
    }

    if (g_hPersistentImmunity != null)
    {
        delete g_hPersistentImmunity;
        g_hPersistentImmunity = null;
    }

    if (g_hVolunteers != null)
    {
        delete g_hVolunteers;
        g_hVolunteers = null;
    }
}

// ---------------------------------------------------------------------------
// Main balance timer
// ---------------------------------------------------------------------------

public Action Timer_Autobalance(Handle timer)
{
    int teamCounts[6];

    for (int i = 0; i < GAME_TEAM_COUNT; i++)
    {
        int team = g_GameTeams[i];
        teamCounts[team] = CountTeamPlayersRaw(team);
    }

    // Build the list of active teams (always RED + BLU; add GREEN/YELLOW if populated).
    int activeTeams[GAME_TEAM_COUNT];
    int activeCount = 0;
    activeTeams[activeCount++] = TEAM_RED;
    activeTeams[activeCount++] = TEAM_BLUE;

    if (teamCounts[TEAM_GREEN] > 0 || teamCounts[TEAM_YELLOW] > 0)
    {
        activeTeams[activeCount++] = TEAM_GREEN;
        activeTeams[activeCount++] = TEAM_YELLOW;
    }

    // Sort active teams by count descending (simple insertion sort; max 4 elements).
    int sortedTeams[GAME_TEAM_COUNT];
    int sortedCounts[GAME_TEAM_COUNT];
    for (int i = 0; i < activeCount; i++)
    {
        sortedTeams[i]  = activeTeams[i];
        sortedCounts[i] = teamCounts[activeTeams[i]];
    }

    for (int i = 1; i < activeCount; i++)
    {
        int keyTeam  = sortedTeams[i];
        int keyCount = sortedCounts[i];
        int j = i - 1;
        while (j >= 0 && sortedCounts[j] < keyCount)
        {
            sortedTeams[j + 1]  = sortedTeams[j];
            sortedCounts[j + 1] = sortedCounts[j];
            j--;
        }
        sortedTeams[j + 1]  = keyTeam;
        sortedCounts[j + 1] = keyCount;
    }

    int biggestTeam   = sortedTeams[0];
    int biggestCount  = sortedCounts[0];
    int smallestTeam  = sortedTeams[activeCount - 1];
    int smallestCount = sortedCounts[activeCount - 1];

    if (biggestTeam == 0 || smallestTeam == 0 || biggestTeam == smallestTeam)
    {
        return Plugin_Continue;
    }

    int diff = biggestCount - smallestCount;
    int diffThreshold = 1;
    if (g_hDiffThreshold != null)
    {
        diffThreshold = g_hDiffThreshold.IntValue;
        if (diffThreshold < 1) diffThreshold = 1;
    }

    if (diff <= diffThreshold)
    {
        return Plugin_Continue;
    }

    bool forceBalance = (diff > diffThreshold);

    char fromTeamName[16];
    char toTeamName[16];
    AB_GetTeamName(biggestTeam,  fromTeamName, sizeof(fromTeamName));
    AB_GetTeamName(smallestTeam, toTeamName,   sizeof(toTeamName));
    char fromTeamChat[24];
    char toTeamChat[24];
    AB_GetTeamChatLabel(biggestTeam,  fromTeamChat, sizeof(fromTeamChat));
    AB_GetTeamChatLabel(smallestTeam, toTeamChat,   sizeof(toTeamChat));

    LogBalance(
        "Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );
    PrintToServer(
        "[autobalance_4teams] Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );

    // ------------------------------------------------------------------
    // Candidate selection.
    //
    // If forceBalance is active (diff > threshold), switch immediately:
    // pick from any eligible human on the oversized team, regardless of
    // alive state.
    //
    // Volunteer selection runs before normal candidate filters. Volunteers
    // still keep medic uber and MVP protection.
    //
    // Otherwise keep normal two-pass selection:
    //  Pass 1 (strict)    : dead, below-average score, non-Engi/Medic
    //  Pass 2 (relax s/a) : any alive/score state, non-Engi/Medic
    // ------------------------------------------------------------------

    int totalScore   = 0;
    int totalPlayers = 0;
    float avg = 0.0;
    int pick = 0;
    int candidateCount = 0;
    bool simpleSelection = (g_hSimpleSelection != null && g_hSimpleSelection.BoolValue);
    bool volunteerSelection = false;

    int volunteerNonMedicCount = 0;
    int volunteerMedicCount = 0;
    pick = SelectVolunteerPlayer(biggestTeam, volunteerNonMedicCount, volunteerMedicCount);
    if (pick > 0)
    {
        volunteerSelection = true;
        candidateCount = (volunteerNonMedicCount > 0) ? volunteerNonMedicCount : volunteerMedicCount;

        LogBalance(
            "Volunteer priority on %s: picked %N from %d non-medic and %d medic volunteer candidates",
            fromTeamName, pick, volunteerNonMedicCount, volunteerMedicCount
        );
    }
    else
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!(forceBalance ? IsEligiblePlayerForce(i, biggestTeam) : IsEligiblePlayer(i, biggestTeam)))
            {
                continue;
            }

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

        avg = float(totalScore) / float(totalPlayers);

        if (simpleSelection)
        {
            pick = SelectPreferredRecentPlayer(biggestTeam);
            candidateCount = (pick > 0) ? 1 : 0;
            if (pick <= 0)
            {
                LogBalance(
                    "Skip balance on %s: simple selection found no eligible candidates (eligible=%d)",
                    fromTeamName, totalPlayers
                );
                return Plugin_Continue;
            }
        }
        else
        {
            int candidates[MAXPLAYERS];

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
            // Build a cumulative-weight array where each candidate's weight is
            // (maxScore - score + 1) so the lowest scorer is most likely.
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

            int roll = GetRandomInt(0, totalWeight - 1);
            pick = candidates[0];
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
        }
    }

    LogBalance(
        "Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d simple=%d volunteer=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount, simpleSelection ? 1 : 0, volunteerSelection ? 1 : 0
    );
    PrintToServer(
        "[autobalance_4teams] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d simple=%d volunteer=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount, simpleSelection ? 1 : 0, volunteerSelection ? 1 : 0
    );

    if (GetFeatureStatus(FeatureType_Native, "FilterAlerts_MarkAutobalance") == FeatureStatus_Available)
    {
        FilterAlerts_MarkAutobalance(pick);
    }

    ChangeClientTeam(pick, smallestTeam);
    TF2_RespawnPlayer(pick);
    SetClientMapImmunity(pick, true);

    CPrintToChatAllEx(
        pick,
        "{tomato}[{purple}Gap{tomato}]{default} Sending {teamcolor}%N{default} from %s to %s",
        pick, fromTeamChat, toTeamChat
    );

    char teamColorName[24];
    AB_GetTeamColorName(smallestTeam, teamColorName, sizeof(teamColorName));
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to %s{default}!", teamColorName);

    return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsMedicWithProtectedUber(client)) return false;
    if (IsClientImmune(client)) return false;
    if (HasClanTeammateProtection(client, team)) return false;
    if (IsClientCurrentRoundMvpSafe(client)) return false;

    return true;
}

static bool IsEligiblePlayerForce(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsMedicWithProtectedUber(client)) return false;
    if (IsClientImmune(client)) return false;
    if (HasClanTeammateProtection(client, team)) return false;
    if (IsClientCurrentRoundMvpSafe(client)) return false;

    return true;
}

static bool IsMedicWithProtectedUber(int client)
{
    if (TF2_GetPlayerClass(client) != TFClass_Medic)
    {
        return false;
    }

    int medigun = GetPlayerWeaponSlot(client, 1);
    if (medigun <= MaxClients || !IsValidEntity(medigun))
    {
        return false;
    }

    if (!HasEntProp(medigun, Prop_Send, "m_flChargeLevel"))
    {
        return false;
    }

    // m_flChargeLevel is normalized: 0.05 is 5% uber.
    return GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel") > MEDIC_AUTOBALANCE_UBER_FLOOR;
}

static bool IsClientCurrentRoundMvpSafe(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "WhaleTracker_IsCurrentRoundMvp") != FeatureStatus_Available)
    {
        return false;
    }

    return WhaleTracker_IsCurrentRoundMvp(client);
}

static bool HasClanTeammateProtection(int client, int team)
{
    if (GetFeatureStatus(FeatureType_Native, "Clans_GetSameTeamClanMemberCount") != FeatureStatus_Available)
    {
        return false;
    }

    int count = Clans_GetSameTeamClanMemberCount(client, team);
    return (count < 0 || count > 1);
}

static int GetSimpleSelectionPriority(int client)
{
    int priority = 0;

    if (!IsPlayerAlive(client))
    {
        priority += 2;
    }

    if (TF2_GetPlayerClass(client) != TFClass_Engineer)
    {
        priority += 1;
    }

    return priority;
}

static int SelectPreferredRecentPlayer(int team)
{
    int pick = 0;
    int bestPriority = -1;
    int highestUserId = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsEligiblePlayer(i, team)) continue;

        int priority = GetSimpleSelectionPriority(i);
        int currentUserId = GetClientUserId(i);
        if (priority > bestPriority || (priority == bestPriority && currentUserId > highestUserId))
        {
            bestPriority = priority;
            highestUserId = currentUserId;
            pick = i;
        }
    }

    return pick;
}

static bool IsVolunteerCandidate(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (!IsClientVolunteer(client)) return false;
    if (IsClientMapImmune(client)) return false;
    if (IsMedicWithProtectedUber(client)) return false;
    if (IsClientCurrentRoundMvpSafe(client)) return false;

    return true;
}

static int SelectVolunteerPlayer(int team, int &nonMedicCount, int &medicCount)
{
    int nonMedics[MAXPLAYERS];
    int medics[MAXPLAYERS];
    nonMedicCount = 0;
    medicCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsVolunteerCandidate(i, team)) continue;

        if (TF2_GetPlayerClass(i) == TFClass_Medic)
        {
            medics[medicCount++] = i;
        }
        else
        {
            nonMedics[nonMedicCount++] = i;
        }
    }

    if (nonMedicCount > 0)
    {
        return nonMedics[GetRandomInt(0, nonMedicCount - 1)];
    }

    if (medicCount > 0)
    {
        return medics[GetRandomInt(0, medicCount - 1)];
    }

    return 0;
}

static bool IsClientImmune(int client)
{
    return IsClientMapImmune(client) || IsClientPersistentlyImmune(client);
}

static bool IsClientPersistentlyImmune(int client)
{
    if (g_hPersistentImmunity == null || !IsClientInGame(client))
    {
        return false;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    int dummy = 0;
    return g_hPersistentImmunity.GetValue(steamId, dummy);
}

static bool IsClientMapImmune(int client)
{
    if (g_hMapImmunity == null || !IsClientInGame(client)) return false;

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    int dummy = 0;
    return g_hMapImmunity.GetValue(steamId, dummy);
}

static bool SetClientMapImmunity(int client, bool immune)
{
    if (g_hMapImmunity == null || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    if (immune)
    {
        g_hMapImmunity.SetValue(steamId, 1, true);
    }
    else
    {
        g_hMapImmunity.Remove(steamId);
    }
    return true;
}

static bool IsClientVolunteer(int client)
{
    if (g_hVolunteers == null || !IsClientInGame(client))
    {
        return false;
    }

    char steamId[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return false;
    }

    int dummy = 0;
    return g_hVolunteers.GetValue(steamId, dummy);
}

static void SetPersistentVolunteerCache(const char[] steamId, bool volunteer)
{
    if (g_hVolunteers == null || !steamId[0])
    {
        return;
    }

    if (volunteer)
    {
        g_hVolunteers.SetValue(steamId, 1, true);
    }
    else
    {
        g_hVolunteers.Remove(steamId);
    }
}

static void ConnectImmunityDatabase()
{
    char configName[64];
    g_hDatabaseConfig.GetString(configName, sizeof(configName));
    Database.Connect(SQL_OnImmunityDatabaseConnected, configName);
}

public void SQL_OnImmunityDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("[autobalance_4teams] Immunity DB connection failed: %s", error);
        return;
    }

    if (g_hImmunityDb != null)
    {
        delete g_hImmunityDb;
    }

    g_hImmunityDb = db;
    g_bImmunityDbReady = false;
    g_bVolunteerDbReady = false;

    if (!g_hImmunityDb.SetCharset("utf8mb4"))
    {
        LogError("[autobalance_4teams] Failed to set utf8mb4 charset");
    }

    g_hImmunityDb.Query(SQL_OnImmunitySchemaReady,
        "CREATE TABLE IF NOT EXISTS autobalance_immunity ("
        ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
        ... "immune TINYINT(1) NOT NULL DEFAULT 1)");
}

public void SQL_OnImmunitySchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[autobalance_4teams] Immunity schema creation failed: %s", error);
        return;
    }

    if (g_hPersistentImmunity != null)
    {
        g_hPersistentImmunity.Clear();
    }

    g_hImmunityDb.Query(SQL_OnPersistentImmunityLoaded,
        "SELECT steamid64 FROM autobalance_immunity WHERE immune != 0");

    g_hImmunityDb.Query(SQL_OnVolunteerSchemaReady,
        "CREATE TABLE IF NOT EXISTS autobalance_volunteers ("
        ... "steamid64 VARCHAR(32) NOT NULL PRIMARY KEY, "
        ... "volunteer TINYINT(1) NOT NULL DEFAULT 1)");
}

public void SQL_OnPersistentImmunityLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[autobalance_4teams] Persistent immunity preload failed: %s", error);
        return;
    }

    if (g_hPersistentImmunity == null)
    {
        g_hPersistentImmunity = new StringMap();
    }
    else
    {
        g_hPersistentImmunity.Clear();
    }

    if (results != null)
    {
        char steamId[32];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId, sizeof(steamId));
            TrimString(steamId);
            if (!steamId[0])
            {
                continue;
            }

            g_hPersistentImmunity.SetValue(steamId, 1, true);
        }
    }

    g_bImmunityDbReady = true;
}

public void SQL_OnVolunteerSchemaReady(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[autobalance_4teams] Volunteer schema creation failed: %s", error);
        return;
    }

    if (g_hVolunteers != null)
    {
        g_hVolunteers.Clear();
    }

    g_hImmunityDb.Query(SQL_OnPersistentVolunteersLoaded,
        "SELECT steamid64 FROM autobalance_volunteers WHERE volunteer != 0");
}

public void SQL_OnPersistentVolunteersLoaded(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[autobalance_4teams] Persistent volunteer preload failed: %s", error);
        return;
    }

    if (g_hVolunteers == null)
    {
        g_hVolunteers = new StringMap();
    }
    else
    {
        g_hVolunteers.Clear();
    }

    if (results != null)
    {
        char steamId[32];
        while (results.FetchRow())
        {
            results.FetchString(0, steamId, sizeof(steamId));
            TrimString(steamId);
            if (!steamId[0])
            {
                continue;
            }

            g_hVolunteers.SetValue(steamId, 1, true);
        }
    }

    g_bVolunteerDbReady = true;
}

static void AB_EscapeSql(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';

    if (g_hImmunityDb == null)
    {
        strcopy(output, maxlen, input);
        return;
    }

    int written = 0;
    if (!g_hImmunityDb.Escape(input, output, maxlen, written))
    {
        strcopy(output, maxlen, input);
    }
}

public Action Command_Volunteer(int client, int args)
{
    if (g_hImmunityDb == null || !g_bVolunteerDbReady)
    {
        ReplyToCommand(client, "[autobalance_4teams] Persistent volunteer database is not ready.");
        return Plugin_Handled;
    }

    int target = client;
    bool targetChangedByAdmin = false;

    if (args >= 1)
    {
        if (client > 0 && !CheckCommandAccess(client, "sm_volunteer_target", ADMFLAG_GENERIC, true))
        {
            ReplyToCommand(client, "[autobalance_4teams] Usage: sm_volunteer");
            return Plugin_Handled;
        }

        char targetArg[MAX_TARGET_LENGTH];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);

        target = FindTarget(client, targetArg, true, false);
        if (target <= 0)
        {
            return Plugin_Handled;
        }

        targetChangedByAdmin = (target != client);
    }

    if (target <= 0)
    {
        ReplyToCommand(client, "[autobalance_4teams] Usage: sm_volunteer [client name/substring]");
        return Plugin_Handled;
    }

    if (!IsClientInGame(target) || IsFakeClient(target))
    {
        ReplyToCommand(client, "[autobalance_4teams] Invalid volunteer target.");
        return Plugin_Handled;
    }

    bool wasVolunteer = IsClientVolunteer(target);

    char steamId[32];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        ReplyToCommand(client, "[autobalance_4teams] Failed to read SteamID64 for %N.", target);
        return Plugin_Handled;
    }

    char escapedSteam[64];
    AB_EscapeSql(steamId, escapedSteam, sizeof(escapedSteam));

    char query[256];
    if (wasVolunteer)
    {
        FormatEx(query, sizeof(query),
            "DELETE FROM autobalance_volunteers WHERE steamid64 = '%s'",
            escapedSteam);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "REPLACE INTO autobalance_volunteers (steamid64, volunteer) VALUES ('%s', 1)",
            escapedSteam);
    }

    DataPack pack = new DataPack();
    pack.WriteCell((client > 0) ? GetClientUserId(client) : 0);
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(wasVolunteer ? 1 : 0);
    pack.WriteCell(targetChangedByAdmin ? 1 : 0);
    pack.WriteString(steamId);

    g_hImmunityDb.Query(SQL_OnPersistentVolunteerToggled, query, pack);
    return Plugin_Handled;
}

public void SQL_OnPersistentVolunteerToggled(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    bool wasVolunteer = (pack.ReadCell() != 0);
    bool targetChangedByAdmin = (pack.ReadCell() != 0);
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    int actor = (actorUserId > 0) ? GetClientOfUserId(actorUserId) : 0;
    int target = GetClientOfUserId(targetUserId);
    bool nowVolunteer = !wasVolunteer;

    if (error[0])
    {
        if (actorUserId == 0 || (actor > 0 && IsClientInGame(actor)))
        {
            ReplyToCommand(actor, "[autobalance_4teams] Failed to toggle persistent volunteer status.");
        }

        LogError("[autobalance_4teams] Persistent volunteer toggle failed for %s: %s", steamId, error);
        return;
    }

    SetPersistentVolunteerCache(steamId, nowVolunteer);

    if (targetChangedByAdmin)
    {
        if (actorUserId == 0 || (actor > 0 && IsClientInGame(actor)))
        {
            if (target > 0 && IsClientInGame(target))
            {
                ReplyToCommand(actor,
                    nowVolunteer
                        ? "[autobalance_4teams] %N is now persistently volunteering for autobalance."
                        : "[autobalance_4teams] %N is no longer persistently volunteering for autobalance.",
                    target);
            }
            else
            {
                ReplyToCommand(actor,
                    nowVolunteer
                        ? "[autobalance_4teams] Persistent autobalance volunteer status applied."
                        : "[autobalance_4teams] Persistent autobalance volunteer status removed.");
            }
        }

        if (target > 0 && IsClientInGame(target))
        {
            PrintToChat(target,
                nowVolunteer
                    ? "[autobalance_4teams] You are now persistently volunteering for autobalance."
                    : "[autobalance_4teams] You are no longer persistently volunteering for autobalance.");
        }

        if (actor > 0 && IsClientInGame(actor) && target > 0 && IsClientInGame(target))
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied by %N to %N"
                    : "Volunteer status removed by %N from %N",
                actor, target);
        }
        else if (target > 0 && IsClientInGame(target))
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied by console to %N"
                    : "Volunteer status removed by console from %N",
                target);
        }
        else
        {
            LogBalance(
                nowVolunteer
                    ? "Volunteer status applied for %s"
                    : "Volunteer status removed for %s",
                steamId);
        }
        return;
    }

    if (target > 0 && IsClientInGame(target))
    {
        ReplyToCommand(target,
            nowVolunteer
                ? "[autobalance_4teams] You are now persistently volunteering for autobalance."
                : "[autobalance_4teams] You are no longer persistently volunteering for autobalance.");
        LogBalance(
            nowVolunteer
                ? "%N volunteered for autobalance"
                : "%N stopped volunteering for autobalance",
            target);
    }
}

public Action Command_Immune(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[autobalance_4teams] Usage: sm_immune <client name/substring>");
        return Plugin_Handled;
    }

    if (g_hImmunityDb == null || !g_bImmunityDbReady)
    {
        ReplyToCommand(client, "[autobalance_4teams] Persistent immunity database is not ready.");
        return Plugin_Handled;
    }

    char targetArg[MAX_TARGET_LENGTH];
    GetCmdArgString(targetArg, sizeof(targetArg));
    TrimString(targetArg);

    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    char steamId[32];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        ReplyToCommand(client, "[autobalance_4teams] Failed to read SteamID64 for %N.", target);
        return Plugin_Handled;
    }

    bool wasImmune = false;
    if (g_hPersistentImmunity != null)
    {
        int dummy = 0;
        wasImmune = g_hPersistentImmunity.GetValue(steamId, dummy);
    }

    char escapedSteam[64];
    AB_EscapeSql(steamId, escapedSteam, sizeof(escapedSteam));

    char query[256];
    if (wasImmune)
    {
        FormatEx(query, sizeof(query),
            "DELETE FROM autobalance_immunity WHERE steamid64 = '%s'",
            escapedSteam);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "REPLACE INTO autobalance_immunity (steamid64, immune) VALUES ('%s', 1)",
            escapedSteam);
    }

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    pack.WriteCell(wasImmune ? 1 : 0);
    pack.WriteString(steamId);

    g_hImmunityDb.Query(SQL_OnPersistentImmunityToggled, query, pack);
    return Plugin_Handled;
}

public void SQL_OnPersistentImmunityToggled(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    int actorUserId = pack.ReadCell();
    int targetUserId = pack.ReadCell();
    bool wasImmune = (pack.ReadCell() != 0);
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));
    delete pack;

    int actor = GetClientOfUserId(actorUserId);
    int target = GetClientOfUserId(targetUserId);

    if (error[0])
    {
        if (actor > 0 && IsClientInGame(actor))
        {
            ReplyToCommand(actor, "[autobalance_4teams] Failed to toggle persistent immunity.");
        }

        LogError("[autobalance_4teams] Persistent immunity toggle failed for %s: %s", steamId, error);
        return;
    }

    if (g_hPersistentImmunity != null)
    {
        if (wasImmune)
        {
            g_hPersistentImmunity.Remove(steamId);
        }
        else
        {
            g_hPersistentImmunity.SetValue(steamId, 1, true);
        }
    }

    if (target > 0 && IsClientInGame(target))
    {
        if (wasImmune)
        {
            CPrintToChatAllEx(target, "{lightgreen}[Server]{default} {teamcolor}%N{default} is no longer persistently autobalance-immune.", target);
            LogBalance("Persistent immunity removed by %N from %N", actor, target);
        }
        else
        {
            CPrintToChatAllEx(target, "{lightgreen}[Server]{default} {teamcolor}%N{default} is now persistently autobalance-immune.", target);
            LogBalance("Persistent immunity applied by %N to %N", actor, target);
        }
        return;
    }

    if (actor > 0 && IsClientInGame(actor))
    {
        ReplyToCommand(actor,
            wasImmune
                ? "[autobalance_4teams] Persistent immunity removed."
                : "[autobalance_4teams] Persistent immunity applied.");
    }
}

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

static void AB_GetTeamName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "RED");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "BLU");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "GREEN");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "YELLOW");
        default:          strcopy(buffer, maxlen, "UNKNOWN");
    }
}

static void AB_GetTeamChatLabel(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}RED{default}");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}BLU{default}");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}GREEN{default}");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}YELLOW{default}");
        default:          strcopy(buffer, maxlen, "{default}UNKNOWN");
    }
}

static void AB_GetTeamColorName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}Red");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}Blue");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}Green");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}Yellow");
        default:          strcopy(buffer, maxlen, "{default}Unknown");
    }
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
        // Save originals before we overwrite them.
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
        // Restore originals on unload.
        if (g_hMpAutoteamBalance != null)
            g_hMpAutoteamBalance.IntValue = g_iSavedAutoteamBalance;

        if (g_hMpTeamsUnbalanceLimit != null)
            g_hMpTeamsUnbalanceLimit.IntValue = g_iSavedUnbalanceLimit;
    }
}
