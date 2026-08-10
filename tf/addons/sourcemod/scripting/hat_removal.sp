#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

#include <sdktools>
#include <sdkhooks>

#include <morecolors>

#include "include/client_validation.inc"

#define VERSION "1.1a"

static int currMode;
static bool bHatsOff[MAXPLAYERS+1] = { false, ... };
static Handle g_hHatToggleCookie = INVALID_HANDLE;

public Plugin myinfo =
{
	name = "Hat Removal",
	author = "Jaro 'Monkeys' Vanderheijden",
	description = "Gives players the choice to toggle hat visibility",
	version = VERSION,
	url = "http://www.sourcemod.net/"
};
 
public void OnPluginStart()
{
	CreateConVar("sm_hatremoval_version", VERSION, "Version of Hat Removal", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_UNLOGGED|FCVAR_DONTRECORD|FCVAR_REPLICATED|FCVAR_NOTIFY);
	ConVar hMode = CreateConVar("sm_hatremoval_mode", "2", "Mode Hat Removal is running in. 0: hats on | 1: hats off | 2: players can toggle");
	currMode = GetConVarInt(hMode);
	HookConVarChange(hMode, cbCvarChange);

	g_hHatToggleCookie = RegClientCookie("hatremoval_toggle", "Hat visibility toggle (0/1)", CookieAccess_Public);
	
	RegConsoleCmd("sm_togglehat", cbToggleHat, "Toggles hat visibility");
	RegConsoleCmd("sm_nohats", cbToggleHat, "Toggles hat visibility");
	RegConsoleCmd("sm_nohat", cbToggleHat, "Toggles hat visibility");
}

public void OnClientPutInServer(int Client)
{
	bHatsOff[Client] = false;
	LoadHatToggleCookie(Client);
}

public void OnClientCookiesCached(int Client)
{
	LoadHatToggleCookie(Client);
}

public void OnClientDisconnect(int Client)
{
	bHatsOff[Client] = false;
}

public void OnEntityCreated(int entity, const char[] Classname)
{
	if (StrEqual(Classname, "tf_wearable"))
	{
		CreateTimer(0.1, timerHookDelay, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action timerHookDelay(Handle Timer, any entityRef)
{
	int entity = EntRefToEntIndex(entityRef);
	if (entity != INVALID_ENT_REFERENCE && IsValidEdict(entity))
	{
		//Hook transmit
		//Unless it's a The Razorback, Darwin's Danger Shield or Gunboats
		char sModel[256];
		GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
		if(!( StrContains(sModel, "croc_shield") != -1 
		|| StrContains(sModel, "c_rocketboots_soldier") != -1
		|| StrContains(sModel, "knife_shield") != -1 ) )
			SDKHook(entity, SDKHook_SetTransmit, cbTransmit);
	}

	return Plugin_Stop;
}

static void LoadHatToggleCookie(int Client)
{
	if (g_hHatToggleCookie == INVALID_HANDLE)
	{
		return;
	}

	if (!AreClientCookiesCached(Client))
	{
		return;
	}

	char value[4];
	GetClientCookie(Client, g_hHatToggleCookie, value, sizeof(value));
	if (value[0] == '\0')
	{
		bHatsOff[Client] = false;
		return;
	}

	bHatsOff[Client] = StrEqual(value, "1");
}

public Action cbToggleHat(int Client, int Args)
{
	if (!Client_IsInGame(Client))
	{
		return Plugin_Handled;
	}

	//Plugin isn't on
	if(currMode == 0)
	{
		CPrintToChat(Client, "{axis}[HatRemoval]{default} This server is running Hat Removal, but it's turned off right now.");
		return Plugin_Handled;
	}
	//Plugin is on forced mode
	if(currMode == 1)
	{
		CPrintToChat(Client, "{axis}[HatRemoval]{default} This server is running Hat Removal, all hats have been removed and can't be toggled.");
		return Plugin_Handled;
	}
	//Toggle, but if the client gives a 0/other as argument, turn it off/on.
	if(Args > 0)
	{
		char arg[5];
		GetCmdArg(1, arg, sizeof(arg));
		bHatsOff[Client] = StrEqual(arg, "0");
	} else
		bHatsOff[Client] = !bHatsOff[Client];

	if (g_hHatToggleCookie != INVALID_HANDLE)
	{
		SetClientCookie(Client, g_hHatToggleCookie, bHatsOff[Client] ? "1" : "0");
	}

	CPrintToChat(Client, "{axis}[HatRemoval]{default} Hats are now %s", bHatsOff[Client] ? "disabled" : "enabled");
	return Plugin_Handled;
}

public void cbCvarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	currMode = StringToInt(newValue);
	if(currMode < 0 || currMode > 2)
		currMode = 0;
	switch(currMode)
	{
		case 0:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats are now enabled.");
		case 1:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats are now disabled.");
		case 2:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats can now be toggled.");
	}
}

public Action cbTransmit(int Entity, int Client)
{
	if (!Client_IsInGame(Client))
	{
		return Plugin_Continue;
	}

	//Transmit when plugin's off OR if the player didn't turn it on
	if(currMode == 0 || (currMode == 2 && !bHatsOff[Client]) )
		return Plugin_Continue;
	else
		return Plugin_Handled;
}
