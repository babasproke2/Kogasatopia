// Simple scramble vote helper (NativeVotes)
#include <sourcemod>
#include <morecolors>
#include <nativevotes>

#pragma semicolon 1
#pragma newdecls required

static const char SCRAMBLE_COMMANDS[][] =
{
    "sm_scramble",
    "sm_scwamble",
    "sm_sc",
    "sm_scram",
    "sm_shitteam"
};

static const char SCRAMBLE_KEYWORDS[][] =
{
    "scramble",
    "scwamble",
    "sc",
    "scram",
    "shitteam"
};

bool g_bPlayerVoted[MAXPLAYERS + 1];
int g_iVoteRequests = 0;
bool g_bVoteRunning = false;
bool g_bNativeVotes = false;
NativeVote g_hVote = null;
ConVar g_hAutoRounds = null;
ConVar g_hVoteTime = null;
ConVar g_hRestartFreeze = null;
Handle g_hRestartFreezeTimer = null;
int g_iRestartFreezeRestore = 1;
int g_iRoundsSinceAuto = 0;

public Plugin myinfo =
{
    name = "votescramble",
    author = "Hombre",
    description = "Player-triggered scramble vote helper",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    UpdateNativeVotes();
    g_hAutoRounds = CreateConVar("votescramble_rounds", "2", "Automatically start a scramble vote every X rounds. 0/1 disables auto vote.", _, true, 0.0, true, 100.0);
    g_hVoteTime = CreateConVar("votescramble_votetime", "6", "Scramble vote duration in seconds.", _, true, 1.0, true, 30.0);
    g_hRestartFreeze = FindConVar("tf_player_movement_restart_freeze");

    for (int i = 0; i < sizeof(SCRAMBLE_COMMANDS); i++)
    {
        RegConsoleCmd(SCRAMBLE_COMMANDS[i], Command_Scramble);
    }
    RegAdminCmd("sm_forcescramble", Command_ForceScramble, ADMFLAG_GENERIC, "Immediately start a scramble vote.");

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
    HookEvent("teamplay_round_win", Event_RoundWin, EventHookMode_PostNoCopy);
}

public void OnAllPluginsLoaded()
{
    UpdateNativeVotes();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        UpdateNativeVotes();
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "nativevotes", false))
    {
        g_bNativeVotes = false;
    }
}

public void OnMapStart()
{
    ResetVotes();
    g_iRoundsSinceAuto = 0;
}

public void OnMapEnd()
{
    ResetVotes();
    g_iRoundsSinceAuto = 0;
}

public void OnPluginEnd()
{
    if (g_hRestartFreezeTimer != null)
    {
        CloseHandle(g_hRestartFreezeTimer);
        g_hRestartFreezeTimer = null;
    }

    if (g_hRestartFreeze != null)
    {
        g_hRestartFreeze.IntValue = g_iRestartFreezeRestore;
    }

    ResetVotes();
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients)
        return;
    if (g_bPlayerVoted[client])
    {
        g_bPlayerVoted[client] = false;
        if (g_iVoteRequests > 0)
        {
            g_iVoteRequests--;
        }
    }
}

public Action Command_Scramble(int client, int args)
{
    HandleScrambleRequest(client);
    return Plugin_Handled;
}

public Action Command_ForceScramble(int client, int args)
{
    StartScrambleVote(client, false);
    return Plugin_Handled;
}

public void Event_RoundWin(Event event, const char[] name, bool dontBroadcast)
{
    if (g_hAutoRounds == null)
    {
        return;
    }

    int roundsRequired = g_hAutoRounds.IntValue;
    if (roundsRequired <= 1)
    {
        return;
    }

    g_iRoundsSinceAuto++;
    if (g_iRoundsSinceAuto < roundsRequired)
    {
        return;
    }

    if (StartScrambleVote(0, true))
    {
        g_iRoundsSinceAuto = 0;
    }
}

public Action SayListener(int client, const char[] command, int argc)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));
    TrimString(text);
    StripQuotes(text);
    TrimString(text);

    if (!text[0])
    {
        return Plugin_Continue;
    }

    for (int i = 0; i < sizeof(SCRAMBLE_KEYWORDS); i++)
    {
        if (StrEqual(text, SCRAMBLE_KEYWORDS[i], false))
        {
            HandleScrambleRequest(client);
            return Plugin_Handled;
        }
    }

    return Plugin_Continue;
}

static void UpdateNativeVotes()
{
    g_bNativeVotes = LibraryExists("nativevotes") && NativeVotes_IsVoteTypeSupported(NativeVotesType_Custom_YesNo);
}

static void HandleScrambleRequest(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        CPrintToChat(client, "{blue}[Scramble]{default} A vote is already running.");
        return;
    }

    if (g_bPlayerVoted[client])
    {
        CPrintToChat(client, "{blue}[Scramble]{default} You already requested a scramble.");
        return;
    }

    g_bPlayerVoted[client] = true;
    g_iVoteRequests++;

    CPrintToChatAll("{blue}[Scramble]{default} %N requested a scramble (%d/4).", client, g_iVoteRequests);

    if (g_iVoteRequests >= 4)
    {
        StartScrambleVote(client, false);
    }
}

static bool StartScrambleVote(int client, bool suppressFeedback)
{
    if (!g_bNativeVotes)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[Scramble]{default} NativeVotes is unavailable.");
        }
        return false;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[Scramble]{default} A vote is already running.");
        }
        return false;
    }

    int delay = NativeVotes_CheckVoteDelay();
    if (delay > 0)
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            NativeVotes_DisplayCallVoteFail(client, NativeVotesCallFail_Recent, delay);
        }
        return false;
    }

    if (!NativeVotes_IsNewVoteAllowed())
    {
        if (!suppressFeedback && client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "{blue}[Scramble]{default} A vote is not allowed right now.");
        }
        return false;
    }

    if (g_hVote != null)
    {
        g_hVote.Close();
        g_hVote = null;
    }

    g_hVote = new NativeVote(ScrambleVoteHandler, NativeVotesType_Custom_YesNo, MENU_ACTIONS_ALL);
    NativeVotes_SetTitle(g_hVote, "Scramble teams?");

    int voteTime = 6;
    if (g_hVoteTime != null)
    {
        voteTime = g_hVoteTime.IntValue;
    }
    if (voteTime < 1)
    {
        voteTime = 1;
    }

    g_bVoteRunning = NativeVotes_DisplayToAll(g_hVote, voteTime);
    if (!g_bVoteRunning)
    {
        g_hVote.Close();
        g_hVote = null;
        return false;
    }

    return true;
}

public int ScrambleVoteHandler(NativeVote vote, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_End:
        {
            vote.Close();
            g_hVote = null;
            g_bVoteRunning = false;
            ResetVotes();
            return 0;
        }
        case MenuAction_VoteCancel:
        {
            if (param1 == VoteCancel_NoVotes)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
            }
            else
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
            }
            return 0;
        }
        case MenuAction_VoteEnd:
        {
            int votes = 0;
            int totalVotes = 0;
            NativeVotes_GetInfo(param2, votes, totalVotes);

            if (totalVotes <= 0)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_NotEnoughVotes);
                return 0;
            }

            int yesVotes = (param1 == NATIVEVOTES_VOTE_YES) ? votes : (totalVotes - votes);
            int noVotes = totalVotes - yesVotes;
            float noPercent = float(noVotes) / float(totalVotes);

            if (noPercent >= 0.60)
            {
                NativeVotes_DisplayFail(vote, NativeVotesFail_Loses);
                CPrintToChatAll("Vote failed (No %.0f%%).", noPercent * 100.0);
            }
            else
            {
                NativeVotes_DisplayPassCustom(vote, "Vote passed. Scrambling teams...");
                StartRestartFreezeWindow();
                ServerCommand("mp_scrambleteams");
            }
            return 0;
        }
    }
    return 0;
}

static void ResetVotes()
{
    g_iVoteRequests = 0;
    g_bVoteRunning = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bPlayerVoted[i] = false;
    }
}

static void StartRestartFreezeWindow()
{
    if (g_hRestartFreeze == null)
    {
        g_hRestartFreeze = FindConVar("tf_player_movement_restart_freeze");
    }
    if (g_hRestartFreeze == null)
    {
        return;
    }

    int current = g_hRestartFreeze.IntValue;
    if (current == 1)
    {
        return;
    }

    g_iRestartFreezeRestore = current;
    g_hRestartFreeze.IntValue = 0;

    if (g_hRestartFreezeTimer != null)
    {
        CloseHandle(g_hRestartFreezeTimer);
    }
    g_hRestartFreezeTimer = CreateTimer(15.0, Timer_RestoreRestartFreeze, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RestoreRestartFreeze(Handle timer, any data)
{
    if (timer == g_hRestartFreezeTimer)
    {
        g_hRestartFreezeTimer = null;
    }

    if (g_hRestartFreeze != null)
    {
        g_hRestartFreeze.IntValue = g_iRestartFreezeRestore;
    }

    return Plugin_Stop;
}
