#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>

#include <whaletracker_api>

#include "include/client_validation.inc"

#define PLUGIN_VERSION "1.26"

ConVar g_hCVarsEnabled;
ConVar g_hCVarsKills;
ConVar g_hCVarsReason;
ConVar g_hCVarsWarn;

public Plugin myinfo =
{
	name = "Admin Sprays Only",
	description = "Only players with enough WhaleTracker kills are allowed to spray.",
	author = "luki1412",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/member.php?u=43109"
}

public void OnPluginStart()
{
	CreateConVar("sm_aso_version", PLUGIN_VERSION, "Admin Sprays Only plugin version", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	g_hCVarsEnabled = CreateConVar("sm_aso_enabled", "1", "Enables/disables Admin Sprays Only", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCVarsKills = CreateConVar("sm_aso_kills", "50", "Minimum WhaleTracker cumulative kills needed to be able to spray", FCVAR_NONE, true, 0.0);
	g_hCVarsWarn = CreateConVar("sm_aso_warn", "1", "Enables/disables chat warning messages", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCVarsReason = CreateConVar("sm_aso_warning", "You are not allowed to spray", "Warning displayed when a player below the kill requirement tries to spray", FCVAR_NONE);
	EnabledChanged(g_hCVarsEnabled, "", "");
	HookConVarChange(g_hCVarsEnabled, EnabledChanged);
	AutoExecConfig(true, "Admin_Sprays_Only");
}

public void EnabledChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (GetConVarBool(g_hCVarsEnabled))
	{
		AddTempEntHook("Player Decal", Player_Decal);
	}
	else
	{
		RemoveTempEntHook("Player Decal", Player_Decal);
	}
}

public Action Player_Decal(const char[] name, const int[] clients, int count, float delay)
{
	if (!GetConVarBool(g_hCVarsEnabled))
	{
		return Plugin_Continue;
	}

	int client = TE_ReadNum("m_nPlayer");

	if (Client_IsInGame(client) && !IsClientReplay(client) && !IsClientSourceTV(client))
	{
		int requiredKills = GetConVarInt(g_hCVarsKills);
		bool statsLoaded = WhaleTracker_AreStatsLoaded(client);
		int clientKills = statsLoaded ? WhaleTracker_GetCumulativeKills(client) : 0;

	    if (statsLoaded && clientKills >= requiredKills)
		{
		    return Plugin_Continue;
		}
		else
		{
			if (GetConVarBool(g_hCVarsWarn))
			{
				char CharReason[255];
				GetConVarString(g_hCVarsReason, CharReason, sizeof(CharReason));
				PrintToChat(client, "%s", CharReason);
			}

			return Plugin_Handled;
		}
	}

	return Plugin_Handled;
}
