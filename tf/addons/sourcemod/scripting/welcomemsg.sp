#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <morecolors>

bool g_HasBeenWelcomed[MAXPLAYERS + 1];
ConVar g_hUncleCycleState;
ConVar g_hNewsMode;
ConVar g_hNewsText;
ConVar g_hNewsGitFormat;
ConVar g_hWelcome[2];
ConVar g_hInfo[5];
ConVar g_hRules[5];
ConVar g_hGitRepoName;
ConVar g_hGitRepoBranch;
ConVar g_hGitRepoCommitShort;
ConVar g_hGitRepoCommitMessage;
ConVar g_hGitRepoCommitDate;

public Plugin myinfo = {
    name = "Welcome Message",
    author = "Hombre",
    description = "Welcome message & server info plugin for Kogasatopia, very specific",
    version = "2.00",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    HookEvent("player_spawn", Event_PlayerSpawn);
    g_hUncleCycleState = FindConVar("uncle_cycle_active");
    g_hNewsMode = CreateConVar("sm_wsmg_newsmode", "0", "Use g_WelcomeMsgGit instead of g_WelcomeMsg for welcome/news output.", _, true, 0.0, true, 1.0);
    g_hNewsText = CreateConVar("sm_wsmg_news", "", "News line used by the welcome message and !news.");
    g_hNewsGitFormat = CreateConVar("sm_wsmg_news_git", "{green}Git info: {default}%s, %s, %s, %s, %s{default}", "Git news format used by !news and git welcome mode.");
    g_hWelcome[0] = CreateConVar("sm_welcomemsg_welcome1", "{peachpuff}Welcome to {unique}Kogasatopia{peachpuff} %N!", "First normal welcome line. Supports SourceMod format tokens such as %N for the client.");
    g_hWelcome[1] = CreateConVar("sm_welcomemsg_welcome2", "{peachpuff}This server has new weapons and other cool stuff; use {lightskyblue}!info", "Second normal welcome line.");
    g_hInfo[0] = CreateConVar("sm_welcomemsg_info1", "", "First optional info line printed by !info.");
    g_hInfo[1] = CreateConVar("sm_welcomemsg_info2", "", "Second optional info line printed by !info.");
    g_hInfo[2] = CreateConVar("sm_welcomemsg_info3", "", "Third optional info line printed by !info.");
    g_hInfo[3] = CreateConVar("sm_welcomemsg_info4", "", "Fourth optional info line printed by !info.");
    g_hInfo[4] = CreateConVar("sm_welcomemsg_info5", "", "Fifth optional info line printed by !info.");
    g_hRules[0] = CreateConVar("sm_welcomemsg_rules1", "", "First optional rule line printed by !rules.");
    g_hRules[1] = CreateConVar("sm_welcomemsg_rules2", "", "Second optional rule line printed by !rules.");
    g_hRules[2] = CreateConVar("sm_welcomemsg_rules3", "", "Third optional rule line printed by !rules.");
    g_hRules[3] = CreateConVar("sm_welcomemsg_rules4", "", "Fourth optional rule line printed by !rules.");
    g_hRules[4] = CreateConVar("sm_welcomemsg_rules5", "", "Fifth optional rule line printed by !rules.");
    
    RegConsoleCmd("sm_info", Command_ListInfo, "Displays an brief message to the client about the server.");
    RegConsoleCmd("sm_cmds", Command_cmds, "Lists highlighted server commands to the client");
    RegConsoleCmd("sm_news", Command_news, "Read the server news");
    RegConsoleCmd("sm_commands", Command_cmds, "Lists highlighted server commands to the client");
	RegConsoleCmd("sm_rules", Command_Rules, "Lists the rules to the client");
	RegConsoleCmd("sm_steam", Command_Steam, "Prints the steam group URL to the client");
    RegConsoleCmd("sm_steamchat", Command_chat, "Steam chat link");
    RegConsoleCmd("sm_chatlink", Command_chat, "Steam chat link");
    RegConsoleCmd("sm_discord", Command_chat, "Steam chat link");
    RegConsoleCmd("sm_welcome", Command_Welcome, "Reprints the welcome message.");
    RegConsoleCmd("sm_diamond", Command_DiamondPickaxe, "Prints Diamond Pickaxe info.");
    RegConsoleCmd("sm_diamondpickaxe", Command_DiamondPickaxe, "Prints Diamond Pickaxe info.");
    RegConsoleCmd("sm_pickaxe", Command_DiamondPickaxe, "Prints Diamond Pickaxe info.");
}
static const char g_UncleWelcomeMsg[][] = {
    "{peachpuff}Welcome to {unique}Dane's Custom Weapons{peachpuff}, %N!",
    "{peachpuff}You're on an Uncletopia Custom Weapons server curated by Uncle Dane.",
    "{peachpuff}Uncle Dane added new buildings and weapons; use {lightskyblue}!info{peachpuff} to learn more.",
    "{peachpuff}Be aware of fake Uncletopia servers pretending to offer these features."
};

public void OnClientPutInServer(int client)
{
    if (client > 0 && client <= MaxClients)
        g_HasBeenWelcomed[client] = false;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client && IsClientInGame(client))
        CreateTimer(20.0, Timer_Welcome, GetClientUserId(client));
}

public Action Timer_Welcome(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || g_HasBeenWelcomed[client])
		return Plugin_Stop;
	
	g_HasBeenWelcomed[client] = true;

	SendWelcomeNow(client);
	return Plugin_Stop;
}

public Action Command_Welcome(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	SendWelcomeNow(client);
	return Plugin_Handled;
}

static void SendWelcomeNow(int client)
{
	char buffer[256];
	if (IsUncleCycleActive())
	{
		Format(buffer, sizeof(buffer), g_UncleWelcomeMsg[0], client);
		CPrintToChat(client, "%s", buffer);
        
        for (int i = 1; i < sizeof(g_UncleWelcomeMsg); i++)
            CPrintToChat(client, "%s", g_UncleWelcomeMsg[i]);
    }
    else
    {
        PrintSelectedWelcomeMessage(client);
	}
}

static void PrintSelectedWelcomeMessage(int client)
{
    bool useGitMessage = (g_hNewsMode != null && g_hNewsMode.BoolValue);

    if (useGitMessage)
    {
        PrintGitWelcomeMessage(client);
        return;
    }

    PrintConfiguredWelcomeLines(client, g_hWelcome, sizeof(g_hWelcome));

    PrintConfiguredNewsLine(client);
}

static void PrintConfiguredWelcomeLines(int client, ConVar[] lines, int count)
{
    char line[256];
    char buffer[256];

    for (int i = 0; i < count; i++)
    {
        if (lines[i] == null)
        {
            continue;
        }

        lines[i].GetString(line, sizeof(line));
        TrimString(line);
        if (!line[0])
        {
            continue;
        }

        Format(buffer, sizeof(buffer), line, client);
        CPrintToChat(client, "%s", buffer);
    }
}

static void RefreshGitDisplayConVars()
{
    if (g_hGitRepoName == null)
        g_hGitRepoName = FindConVar("sm_gitrepo_name");
    if (g_hGitRepoBranch == null)
        g_hGitRepoBranch = FindConVar("sm_gitrepo_branch");
    if (g_hGitRepoCommitShort == null)
        g_hGitRepoCommitShort = FindConVar("sm_gitrepo_commit_short");
    if (g_hGitRepoCommitMessage == null)
        g_hGitRepoCommitMessage = FindConVar("sm_gitrepo_commit_message");
    if (g_hGitRepoCommitDate == null)
        g_hGitRepoCommitDate = FindConVar("sm_gitrepo_commit_date");
}

static void GetGitDisplayString(ConVar cvar, const char[] fallback, char[] buffer, int maxlen)
{
    if (cvar != null)
    {
        GetConVarString(cvar, buffer, maxlen);
        if (buffer[0] != '\0')
            return;
    }

    strcopy(buffer, maxlen, fallback);
}

static void GetConfiguredNewsLine(char[] buffer, int maxlen)
{
    if (g_hNewsText != null)
    {
        GetConVarString(g_hNewsText, buffer, maxlen);
        return;
    }

    buffer[0] = '\0';
}

static void FormatConfiguredGitNewsLine(char[] buffer, int maxlen)
{
    char formatString[256];
    char repoName[128];
    char branch[64];
    char commitShort[32];
    char commitMessage[257];
    char commitDate[64];

    RefreshGitDisplayConVars();

    if (g_hNewsGitFormat != null)
        GetConVarString(g_hNewsGitFormat, formatString, sizeof(formatString));
    else {
        GetConVarString(g_hNewsGitFormat, formatString, sizeof(formatString));
        strcopy(formatString, sizeof(formatString), "{green}Git info: {default}%s, %s, %s, %s, %s{default}");
    }

    GetGitDisplayString(g_hGitRepoName, "unknown repo", repoName, sizeof(repoName));
    GetGitDisplayString(g_hGitRepoBranch, "unknown branch", branch, sizeof(branch));
    GetGitDisplayString(g_hGitRepoCommitShort, "unknown head", commitShort, sizeof(commitShort));
    GetGitDisplayString(g_hGitRepoCommitMessage, "no commit message", commitMessage, sizeof(commitMessage));
    GetGitDisplayString(g_hGitRepoCommitDate, "unknown date", commitDate, sizeof(commitDate));

    Format(buffer, maxlen, formatString, repoName, branch, commitShort, commitMessage, commitDate);
}

static void PrintConfiguredNewsLine(int client)
{
    char buffer[512];
    GetConfiguredNewsLine(buffer, sizeof(buffer));
    CPrintToChat(client, "%s", buffer);
}

static void PrintGitWelcomeMessage(int client)
{
    char buffer[512];

    PrintConfiguredWelcomeLines(client, g_hWelcome, sizeof(g_hWelcome));

    FormatConfiguredGitNewsLine(buffer, sizeof(buffer));
    CPrintToChat(client, "%s", buffer);
}

public bool IsUncleCycleActive()
{
    if (g_hUncleCycleState == null)
        g_hUncleCycleState = FindConVar("uncle_cycle_active");
    
    return g_hUncleCycleState != null && g_hUncleCycleState.BoolValue;
}

// Array of command categories and their descriptions
static const char g_CommandInfo[][] = {
    "{lightgreen}Weapons:{default} {gold}!reverts !rp !cp !cw{default}",
    "{lightgreen}WhaleTracker:{default} {gold}!pts !ptsme !bp !sendbp !ranks !stats{default}",
    "{lightgreen}Tags/Clans:{default} {gold}!tags !clan !clans !clanhelp !claninfo !clanmembers{default}",
    "{lightgreen}Clan tools:{default} {gold}!clantag !claninvite !clankick !clanwar{default}",
    "{lightgreen}Sounds:{default} {gold}!sounds !saysound !vol !opt !opts !killsounds !diesounds{default}",
    "{lightgreen}Engineer:{default} {gold}!amp !a !pads !p !ah{default}",
    "{lightgreen}Voting:{default} {gold}!rtv !nominate !whalescramble !surrender{default}",
    "{lightgreen}Social:{default} {gold}!hug !rape !feed !leaderboard !duel{default}",
    "{lightgreen}Server:{default} {gold}!steam !chatlink !info !rules !voice !git !repo !feedback{default}"
};

public Action Command_cmds(int client, int args)
{
    for (int i = 0; i < sizeof(g_CommandInfo); i++)
    {
        CPrintToChat(client, "%s", g_CommandInfo[i]);
    }
    return Plugin_Handled;
}

public Action Command_news(int client, int args)
{
    char buffer[512];

    GetConfiguredNewsLine(buffer, sizeof(buffer));
    CPrintToChat(client, "%s", buffer);

    FormatConfiguredGitNewsLine(buffer, sizeof(buffer));
    CPrintToChat(client, "%s", buffer);
    return Plugin_Handled;
}

public Action Command_Rules(int client, int args)
{
    char rule[256];

    for (int i = 0; i < sizeof(g_hRules); i++)
    {
        if (g_hRules[i] == null)
        {
            continue;
        }

        g_hRules[i].GetString(rule, sizeof(rule));
        TrimString(rule);
        if (!rule[0])
        {
            continue;
        }

        CPrintToChat(client, "%s", rule);
    }

    return Plugin_Handled;
}

public Action Command_Steam(int client, int args)
{
    char deez[128] = "{chartreuse}Steam Group: {unique} steamcommunity.com/groups/kogtf2";
    CPrintToChat(client, "%s", deez);
    return Plugin_Handled;
}

public Action Command_chat(int client, int args)
{
    char deez[256] = "{chartreuse}Steam community chat: \n{unique} steamcommunity.com/chat/invite/Es09gkBm \n{chartreuse}Note: This chat is how the server is generally organized";
    CPrintToChat(client, "%s", deez);
    return Plugin_Handled;
}

public Action Command_DiamondPickaxe(int client, int args)
{
    if (!client || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    CPrintToChat(client, "{mediumspringgreen}Diamond Pickaxe");
    CPrintToChat(client, "{default}Diamond Pickaxe: A prinny machete reskin which can random crit");
    CPrintToChat(client, "{default}Super Diamond Pickaxe: A combination of the Equalizer and Escape Plan for Soldier");
    return Plugin_Handled;
}

public Action Command_ListInfo(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;

    char info[256];

    for (int i = 0; i < sizeof(g_hInfo); i++)
    {
        if (g_hInfo[i] == null)
        {
            continue;
        }

        g_hInfo[i].GetString(info, sizeof(info));
        TrimString(info);
        if (!info[0])
        {
            continue;
        }

        CPrintToChat(client, "%s", info);
    }
    
    return Plugin_Handled;
}
