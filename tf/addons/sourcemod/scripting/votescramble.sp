// Simple scramble vote helper (NativeVotes)
#include <sourcemod>
#include <multicolors>
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

    for (int i = 0; i < sizeof(SCRAMBLE_COMMANDS); i++)
    {
        RegConsoleCmd(SCRAMBLE_COMMANDS[i], Command_Scramble);
    }

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
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
}

public void OnMapEnd()
{
    ResetVotes();
}

public void OnPluginEnd()
{
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
        StartScrambleVote(client);
    }
}

static void StartScrambleVote(int client)
{
    if (!g_bNativeVotes)
    {
        CPrintToChat(client, "{blue}[Scramble]{default} NativeVotes is unavailable.");
        return;
    }

    if (g_bVoteRunning || NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        CPrintToChat(client, "{blue}[Scramble]{default} A vote is already running.");
        return;
    }

    int delay = NativeVotes_CheckVoteDelay();
    if (delay > 0)
    {
        NativeVotes_DisplayCallVoteFail(client, NativeVotesCallFail_Recent, delay);
        return;
    }

    if (!NativeVotes_IsNewVoteAllowed())
    {
        CPrintToChat(client, "{blue}[Scramble]{default} A vote is not allowed right now.");
        return;
    }

    if (g_hVote != null)
    {
        g_hVote.Close();
        g_hVote = null;
    }

    g_hVote = new NativeVote(ScrambleVoteHandler, NativeVotesType_Custom_YesNo, MENU_ACTIONS_ALL);
    NativeVotes_SetTitle(g_hVote, "Scramble teams?");

    g_bVoteRunning = NativeVotes_DisplayToAll(g_hVote, 8);
    if (!g_bVoteRunning)
    {
        g_hVote.Close();
        g_hVote = null;
    }
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
