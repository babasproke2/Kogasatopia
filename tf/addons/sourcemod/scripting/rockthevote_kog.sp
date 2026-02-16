/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Rock The Vote Plugin
 * Creates a map vote when the required number of players have requested one.
 *
 * SourceMod (C)2004-2008 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <nextmap>
#undef REQUIRE_PLUGIN
#include <mapchooser>
#define REQUIRE_PLUGIN
#include <nativevotes>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "Rock The Vote",
	author = "AlliedModders LLC",
	description = "Provides RTV Map Voting",
	version = SOURCEMOD_VERSION,
	url = "http://www.sourcemod.net/"
};

ConVar g_Cvar_Needed;
ConVar g_Cvar_MinPlayers;
ConVar g_Cvar_InitialDelay;
ConVar g_Cvar_Interval;
ConVar g_Cvar_RTVPostVoteAction;
ConVar g_Cvar_MapEvalVoteDone;

bool g_RTVAllowed = false;	// True if RTV is available to players. Used to delay rtv votes.
int g_Voters = 0;				// Total voters connected. Doesn't include fake clients.
int g_Votes = 0;				// Total number of "say rtv" votes
int g_VotesNeeded = 0;			// Necessary votes before map vote begins. (voters * percent_needed)
bool g_Voted[MAXPLAYERS+1] = {false, ...};

bool g_InChange = false;
Handle g_MapEvalChangeTimer = null;

#define MAPEVAL_VOTE_TIME 8.0
#define MAPEVAL_POSTVOTE_DELAY 2.0

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("rockthevote.phrases");
	
	g_Cvar_Needed = CreateConVar("sm_rtv_needed", "0.60", "Percentage of players needed to rockthevote (Def 60%)", 0, true, 0.05, true, 1.0);
	g_Cvar_MinPlayers = CreateConVar("sm_rtv_minplayers", "0", "Number of players required before RTV will be enabled.", 0, true, 0.0, true, float(MAXPLAYERS));
	g_Cvar_InitialDelay = CreateConVar("sm_rtv_initialdelay", "30.0", "Time (in seconds) before first RTV can be held", 0, true, 0.00);
	g_Cvar_Interval = CreateConVar("sm_rtv_interval", "240.0", "Time (in seconds) after a failed RTV before another can be held", 0, true, 0.00);
	g_Cvar_RTVPostVoteAction = CreateConVar("sm_rtv_postvoteaction", "0", "What to do with RTV's after a mapvote has completed. 0 - Allow, success = instant change, 1 - Deny", _, true, 0.0, true, 1.0);
	g_Cvar_MapEvalVoteDone = FindConVar("mapeval_vote_done");
	
	RegConsoleCmd("sm_rtv", Command_RTV);
    RegConsoleCmd("sm_unrtv", Command_UnRTV);
	
	AutoExecConfig(true, "rtv");

	OnMapEnd();

	/* Handle late load */
	for (int i=1; i<=MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);	
		}	
	}
}

public void OnMapEnd()
{
	g_RTVAllowed = false;
	g_Voters = 0;
	g_Votes = 0;
	g_VotesNeeded = 0;
	g_InChange = false;
	if (g_MapEvalChangeTimer != null)
	{
		delete g_MapEvalChangeTimer;
		g_MapEvalChangeTimer = null;
	}
}

public void OnConfigsExecuted()
{
	CreateTimer(g_Cvar_InitialDelay.FloatValue, Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientConnected(int client)
{
	if (!IsFakeClient(client))
	{
		g_Voters++;
		g_VotesNeeded = RoundToCeil(float(g_Voters) * g_Cvar_Needed.FloatValue);
	}
}

public void OnClientDisconnect(int client)
{	
	if (g_Voted[client])
	{
		g_Votes--;
		g_Voted[client] = false;
	}
	
	if (!IsFakeClient(client))
	{
		g_Voters--;
		g_VotesNeeded = RoundToCeil(float(g_Voters) * g_Cvar_Needed.FloatValue);
	}
	
	if (g_Votes && 
		g_Voters && 
		g_Votes >= g_VotesNeeded && 
		g_RTVAllowed ) 
	{
		if (IsPostVoteActionBlocked())
		{
			return;
		}
		
		StartRTV();
	}	
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (!client || IsChatTrigger())
	{
		return;
	}
	
    if (strcmp(sArgs, "unrtv", false) == 0) { ReplySource old = SetCmdReplySource(SM_REPLY_TO_CHAT); AttemptUnRTV(client); SetCmdReplySource(old); }
	if (strcmp(sArgs, "rtv", false) == 0 || strcmp(sArgs, "rockthevote", false) == 0)
	{
		ReplySource old = SetCmdReplySource(SM_REPLY_TO_CHAT);
		
		AttemptRTV(client);
		
		SetCmdReplySource(old);
	}
}

public Action Command_RTV(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}
	
	AttemptRTV(client);
	
	return Plugin_Handled;
}

void AttemptRTV(int client)
{
	if (!g_RTVAllowed || IsPostVoteActionBlocked())
	{
		ReplyToCommand(client, "[Kogasa] %t", "RTV Not Allowed");
		return;
	}

	if (!LibraryExists("nativevotes") || !NativeVotes_IsVoteTypeSupported(NativeVotesType_NextLevelMult))
	{
		ReplyToCommand(client, "[Kogasa] NativeVotes is unavailable.");
		return;
	}

	if (NativeVotes_IsVoteInProgress() || IsVoteInProgress())
	{
		ReplyToCommand(client, "[Kogasa] %t", "RTV Started");
		return;
	}
	
	if (GetClientCount(true) < g_Cvar_MinPlayers.IntValue)
	{
		ReplyToCommand(client, "[Kogasa] %t", "Minimal Players Not Met");
		return;			
	}
	
	if (g_Voted[client])
	{
		ReplyToCommand(client, "[Kogasa] %t", "Already Voted", g_Votes, g_VotesNeeded);
		return;
	}	
	
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	
	g_Votes++;
	g_Voted[client] = true;
	
	PrintToChat(client, "[Kogasa] %t", "RTV Requested", name, g_Votes, g_VotesNeeded);
	
	if (g_Votes >= g_VotesNeeded)
	{
		StartRTV();
	}	
}

public Action Timer_DelayRTV(Handle timer)
{
	g_RTVAllowed = true;

	return Plugin_Continue;
}

void StartRTV()
{
	if (g_InChange)
	{
		return;	
	}

	if (IsMapEvalVoteDone() && IsNextMapSet())
	{
		char map[PLATFORM_MAX_PATH];
		if (GetNextMap(map, sizeof(map)))
		{
			GetMapDisplayName(map, map, sizeof(map));
			PrintToChatAll("[Kogasa] %t", "Changing Maps", map);
			CreateTimer(MAPEVAL_POSTVOTE_DELAY, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
			g_InChange = true;
		}

		ResetRTV();
		g_RTVAllowed = false;
		CreateTimer(g_Cvar_Interval.FloatValue, Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	if (!StartMapEvalVote())
	{
		return;
	}

	ResetRTV();
	g_RTVAllowed = false;
	CreateTimer(g_Cvar_Interval.FloatValue, Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ResetRTV()
{
	g_Votes = 0;
			
	for (int i=1; i<=MAXPLAYERS; i++)
	{
		g_Voted[i] = false;
	}
}

public Action Timer_ChangeMap(Handle hTimer)
{
	g_InChange = false;

	LogMessage("RTV changing map manually");

	char map[PLATFORM_MAX_PATH];
	if (GetNextMap(map, sizeof(map)))
	{
		ForceChangeLevel(map, "RTV after mapvote");
	}

	return Plugin_Stop;
}

public Action Timer_MapEvalChange(Handle hTimer)
{
	g_MapEvalChangeTimer = null;

	char map[PLATFORM_MAX_PATH];
	if (GetNextMap(map, sizeof(map)))
	{
		GetMapDisplayName(map, map, sizeof(map));
		PrintToChatAll("[Kogasa] %t", "Changing Maps", map);
		CreateTimer(MAPEVAL_POSTVOTE_DELAY, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}

	LogMessage("RTV mapvote did not set nextmap.");
	g_InChange = false;
	return Plugin_Stop;
}

public Action Command_UnRTV(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}
	
	AttemptUnRTV(client);
	
	return Plugin_Handled;
}

void AttemptUnRTV(int client)
{
	if (!g_RTVAllowed || IsPostVoteActionBlocked())
	{
		ReplyToCommand(client, "[Kogasa] %t", "RTV Not Allowed");
		return;
	}
	
	if (!g_Voted[client])
	{
		ReplyToCommand(client, "[Kogasa] You haven't voted to rock the vote.");
		return;
	}
	
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	
	g_Votes--;
	g_Voted[client] = false;
	
	PrintToChatAll("[Kogasa] %s has removed their RTV. (%d/%d needed)", name, g_Votes, g_VotesNeeded);
}

bool StartMapEvalVote()
{
	if (NativeVotes_IsVoteInProgress() || IsVoteInProgress())
	{
		return false;
	}

	ServerCommand("sm_mapvote2 rtv");
	ServerExecute();

	if (g_MapEvalChangeTimer != null)
	{
		delete g_MapEvalChangeTimer;
		g_MapEvalChangeTimer = null;
	}

	if (NativeVotes_IsVoteInProgress() || IsVoteInProgress())
	{
		g_MapEvalChangeTimer = CreateTimer(MAPEVAL_VOTE_TIME + 0.2, Timer_MapEvalChange, _, TIMER_FLAG_NO_MAPCHANGE);
		g_InChange = true;
		return true;
	}

	if (IsMapEvalVoteDone() && IsNextMapSet())
	{
		char map[PLATFORM_MAX_PATH];
		if (GetNextMap(map, sizeof(map)))
		{
			GetMapDisplayName(map, map, sizeof(map));
			PrintToChatAll("[Kogasa] %t", "Changing Maps", map);
		}
		CreateTimer(MAPEVAL_POSTVOTE_DELAY, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
		g_InChange = true;
		return true;
	}

	return false;
}

bool IsPostVoteActionBlocked()
{
	if (g_Cvar_RTVPostVoteAction == null || g_Cvar_RTVPostVoteAction.IntValue != 1)
	{
		return false;
	}

	if (IsMapEvalVoteDone())
	{
		return true;
	}

	if (GetFeatureStatus(FeatureType_Native, "HasEndOfMapVoteFinished") == FeatureStatus_Available
		&& HasEndOfMapVoteFinished())
	{
		return true;
	}

	return false;
}

bool IsNextMapSet()
{
	char map[PLATFORM_MAX_PATH];
	map[0] = '\0';
	return GetNextMap(map, sizeof(map)) && map[0] != '\0';
}

bool IsMapEvalVoteDone()
{
	if (g_Cvar_MapEvalVoteDone == null)
	{
		g_Cvar_MapEvalVoteDone = FindConVar("mapeval_vote_done");
		if (g_Cvar_MapEvalVoteDone == null)
		{
			return false;
		}
	}

	return g_Cvar_MapEvalVoteDone.BoolValue;
}
