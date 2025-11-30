#pragma semicolon 1
#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <sdktools>

#define PLUGIN_VERSION			"1.0"

public Plugin:myinfo =
{
	name = "[TF2] Rename bots",
	author = "Pelipoika",
	description = "Rename bots based by class",
	version = PLUGIN_VERSION,
	url = "http://www.sourcemod.net/"
}

public OnPluginStart()
{
	HookEvent("player_changename", OnPlayerSpawn, EventHookMode_Post);
}

public OnPlayerSpawn(Handle:hEvent, const String:strEventName[], bool:bDontBroadcast)
{
	new iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	
	if (IsClientInGame(iClient) && IsFakeClient(iClient))
	{
		new TFClassType:class = TF2_GetPlayerClass(iClient);
		if (GetClientTeam(iClient) == 3) // Blue
		{
			switch(class)
			{
				case TFClass_Scout:		SetClientInfo(iClient, "name", "Shameimaru Aya");
				case TFClass_Soldier:	SetClientInfo(iClient, "name", "Hakurei Reimu");
				case TFClass_DemoMan:	SetClientInfo(iClient, "name", "Ibuki Suika");
				case TFClass_Medic:		SetClientInfo(iClient, "name", "Yagokoro Eirin");
				case TFClass_Pyro:		SetClientInfo(iClient, "name", "Fujiwara no Mokou");
				case TFClass_Spy:		SetClientInfo(iClient, "name", "Komeiji Koishi");
				case TFClass_Engineer:	SetClientInfo(iClient, "name", "Kawashiro Nitori");
				case TFClass_Sniper:	SetClientInfo(iClient, "name", "Alice Margatroid");
				case TFClass_Heavy:		SetClientInfo(iClient, "name", "Kirisame Marisa");
			}
		} else {
                        switch(class)
                        {
                                case TFClass_Scout:             SetClientInfo(iClient, "name", "Himekaidou Hatate");
                                case TFClass_Soldier:   SetClientInfo(iClient, "name", "Kochiya Sanae");
                                case TFClass_DemoMan:   SetClientInfo(iClient, "name", "Okunoda Miyoi");
                                case TFClass_Medic:             SetClientInfo(iClient, "name", "Reisen Udongein Inaba");
                                case TFClass_Pyro:              SetClientInfo(iClient, "name", "Flandre Scarlet");
                                case TFClass_Spy:               SetClientInfo(iClient, "name", "Hata no Kokoro");
                                case TFClass_Engineer:  SetClientInfo(iClient, "name", "Yamashiro Takane");
                                case TFClass_Sniper:    SetClientInfo(iClient, "name", "Patchouli Knowledge");
                                case TFClass_Heavy:             SetClientInfo(iClient, "name", "Kazami Yuuka");
                        }
		}
	}
}
