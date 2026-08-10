#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>

#include <tf2>
#include <tf2_stocks>

#include <morecolors>

#define PLUGIN_VERSION			"1.0"

public Plugin myinfo =
{
	name = "[TF2] Rename bots",
	author = "Hombre",
	description = "Rename bots based by class",
	version = PLUGIN_VERSION,
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	HookEvent("player_changename", Event_OnNameChange, EventHookMode_Pre);
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
	{
		return;
	}

	bool blue = GetClientTeam(client) == 3;
	char botName[MAX_NAME_LENGTH];
	switch (TF2_GetPlayerClass(client))
	{
		case TFClass_Scout:     strcopy(botName, sizeof(botName), blue ? "Shameimaru Aya" : "Himekaidou Hatate");
		case TFClass_Soldier:   strcopy(botName, sizeof(botName), blue ? "Hakurei Reimu" : "Kochiya Sanae");
		case TFClass_DemoMan:   strcopy(botName, sizeof(botName), blue ? "Ibuki Suika" : "Okunoda Miyoi");
		case TFClass_Medic:     strcopy(botName, sizeof(botName), blue ? "Yagokoro Eirin" : "Reisen Udongein Inaba");
		case TFClass_Pyro:      strcopy(botName, sizeof(botName), blue ? "Fujiwara no Mokou" : "Flandre Scarlet");
		case TFClass_Spy:       strcopy(botName, sizeof(botName), blue ? "Komeiji Koishi" : "Hata no Kokoro");
		case TFClass_Engineer:  strcopy(botName, sizeof(botName), blue ? "Kawashiro Nitori" : "Yamashiro Takane");
		case TFClass_Sniper:    strcopy(botName, sizeof(botName), blue ? "Alice Margatroid" : "Patchouli Knowledge");
		case TFClass_Heavy:     strcopy(botName, sizeof(botName), blue ? "Kirisame Marisa" : "Kazami Yuuka");
	}

	if (botName[0])
	{
		SetClientInfo(client, "name", botName);
	}
}

public Action Event_OnNameChange(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	// Block the default broadcast
	SetEventBroadcast(event, true);

	char newName[MAX_NAME_LENGTH];
	GetEventString(event, "newname", newName, sizeof(newName));

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		CPrintToChatEx(i, client, "{greenyellow}[Bots]{default} {teamcolor}%s{default} has joined the game", newName);
	}

	return Plugin_Handled;
}
