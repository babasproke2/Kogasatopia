// Simple scramble vote helper
#include <sourcemod>
#include <sdktools>
#include <morecolors>

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

public Plugin myinfo =
{
    name = "VoteScramble",
    author = "Cogwheel",
    description = "Player-triggered scramble vote helper",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    for (int i = 0; i < sizeof(SCRAMBLE_COMMANDS); i++)
    {
        RegConsoleCmd(SCRAMBLE_COMMANDS[i], Command_Scramble);
    }

    AddCommandListener(SayListener, "say");
    AddCommandListener(SayListener, "say_team");
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

static void HandleScrambleRequest(int client)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (g_bVoteRunning || IsVoteInProgress())
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
        StartScrambleVote();
    }
}

static void StartScrambleVote()
{
    if (g_bVoteRunning || IsVoteInProgress())
    {
        return;
    }

    if (!IsNewVoteAllowed())
    {
        return;
    }

    Menu menu = CreateMenu(ScrambleVoteHandler);
    menu.SetTitle("Scramble teams?");
    menu.AddItem("yes", "Yes");
    menu.AddItem("no", "No");
    menu.ExitButton = false;

    g_bVoteRunning = menu.DisplayVoteToAll(20);
    if (!g_bVoteRunning)
    {
        delete menu;
    }
}

public int ScrambleVoteHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_End:
        {
            delete menu;
            g_bVoteRunning = false;
            ResetVotes();
        }
        case MenuAction_VoteEnd:
        {
            int item = param1;
            char info[8];
            menu.GetItem(item, info, sizeof(info));
            bool yesWon = StrEqual(info, "yes", false);
            if (yesWon)
            {
                CPrintToChatAll("{blue}[Scramble]{default} Vote passed. Scrambling teams...");
                ServerCommand("mp_scrambleteams");
            }
            else
            {
                CPrintToChatAll("{blue}[Scramble]{default} Vote failed.");
            }
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
