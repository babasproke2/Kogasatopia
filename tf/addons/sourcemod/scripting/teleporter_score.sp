#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <dhooks>

DynamicDetour g_EventPlayerUsedTeleportDetour;

public Plugin myinfo =
{
	name = "Teleporter Score",
	author = "Hombre",
	description = "Prevents teleporter uses from awarding normal scoreboard points.",
	version = "1.0.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	GameData gameData = new GameData("teleporter_score");
	if (gameData == null)
	{
		SetFailState("Failed to load teleporter_score gamedata.");
	}

	g_EventPlayerUsedTeleportDetour =
		DynamicDetour.FromConf(gameData, "CTFGameStats::Event_PlayerUsedTeleport");
	delete gameData;

	if (g_EventPlayerUsedTeleportDetour == null)
	{
		SetFailState("Failed to create Event_PlayerUsedTeleport detour.");
	}

	if (!g_EventPlayerUsedTeleportDetour.Enable(
		Hook_Pre,
		Event_PlayerUsedTeleport_Pre))
	{
		SetFailState("Failed to enable Event_PlayerUsedTeleport detour.");
	}
}

public MRESReturn Event_PlayerUsedTeleport_Pre(Address gameStats, DHookParam parameters)
{
	return MRES_Supercede;
}
