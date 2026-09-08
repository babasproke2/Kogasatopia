/**
 * Per-client visibility control for cosmetic wearables.
 *
 * This preserves the public commands, cookie, and convars from Hat Removal
 * while sharing the Weapons plugin's entity and client lifecycle.
 */

#define HAT_REMOVAL_VERSION "1.1a"
#define HAT_VISIBILITY_HOOK_DELAY 0.1

ConVar g_cvHatRemovalMode = null;
Cookie g_HatVisibilityCookie = null;
bool g_bHatsOff[MAXPLAYERS + 1];

void WeaponsHatVisibility_OnPluginStart()
{
	CreateConVar("sm_hatremoval_version", HAT_REMOVAL_VERSION, "Version of Hat Removal",
		FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_UNLOGGED | FCVAR_DONTRECORD | FCVAR_REPLICATED | FCVAR_NOTIFY);
	g_cvHatRemovalMode = CreateConVar("sm_hatremoval_mode", "2",
		"Mode Hat Removal is running in. 0: hats on | 1: hats off | 2: players can toggle");
	g_cvHatRemovalMode.AddChangeHook(WeaponsHatVisibility_OnModeChanged);

	g_HatVisibilityCookie = new Cookie("hatremoval_toggle",
		"Hat visibility toggle (0/1)", CookieAccess_Public);

	RegConsoleCmd("sm_togglehat", WeaponsHatVisibility_CommandToggle, "Toggles hat visibility");
	RegConsoleCmd("sm_nohats", WeaponsHatVisibility_CommandToggle, "Toggles hat visibility");
	RegConsoleCmd("sm_nohat", WeaponsHatVisibility_CommandToggle, "Toggles hat visibility");

	for (int client = 1; client <= MaxClients; client++)
	{
		g_bHatsOff[client] = false;
		if (IsClientInGame(client))
		{
			WeaponsHatVisibility_LoadCookie(client);
		}
	}

	int wearable = -1;
	while ((wearable = FindEntityByClassname(wearable, "tf_wearable")) != -1)
	{
		WeaponsHatVisibility_ScheduleHook(wearable);
	}
}

void WeaponsHatVisibility_OnClientPutInServer(int client)
{
	g_bHatsOff[client] = false;
	WeaponsHatVisibility_LoadCookie(client);
}

void WeaponsHatVisibility_OnClientCookiesCached(int client)
{
	WeaponsHatVisibility_LoadCookie(client);
}

void WeaponsHatVisibility_OnClientDisconnect(int client)
{
	g_bHatsOff[client] = false;
}

void WeaponsHatVisibility_OnEntityCreated(int entity, const char[] className)
{
	if (StrEqual(className, "tf_wearable"))
	{
		WeaponsHatVisibility_ScheduleHook(entity);
	}
}

static void WeaponsHatVisibility_ScheduleHook(int entity)
{
	CreateTimer(HAT_VISIBILITY_HOOK_DELAY, WeaponsHatVisibility_TimerHook,
		EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action WeaponsHatVisibility_TimerHook(Handle timer, any entityRef)
{
	int entity = EntRefToEntIndex(entityRef);
	if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
	{
		return Plugin_Stop;
	}

	char model[PLATFORM_MAX_PATH];
	GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
	if (StrContains(model, "croc_shield") == -1
		&& StrContains(model, "c_rocketboots_soldier") == -1
		&& StrContains(model, "knife_shield") == -1)
	{
		SDKHook(entity, SDKHook_SetTransmit, WeaponsHatVisibility_OnTransmit);
	}

	return Plugin_Stop;
}

static void WeaponsHatVisibility_LoadCookie(int client)
{
	if (g_HatVisibilityCookie == null || !AreClientCookiesCached(client))
	{
		return;
	}

	char value[4];
	g_HatVisibilityCookie.Get(client, value, sizeof(value));
	g_bHatsOff[client] = StrEqual(value, "1");
}

public Action WeaponsHatVisibility_CommandToggle(int client, int args)
{
	if (!Client_IsInGame(client))
	{
		return Plugin_Handled;
	}

	int mode = g_cvHatRemovalMode.IntValue;
	if (mode == 0)
	{
		CPrintToChat(client,
			"{axis}[HatRemoval]{default} This server is running Hat Removal, but it's turned off right now.");
		return Plugin_Handled;
	}
	if (mode == 1)
	{
		CPrintToChat(client,
			"{axis}[HatRemoval]{default} This server is running Hat Removal, all hats have been removed and can't be toggled.");
		return Plugin_Handled;
	}

	if (args > 0)
	{
		char arg[5];
		GetCmdArg(1, arg, sizeof(arg));
		g_bHatsOff[client] = StrEqual(arg, "0");
	}
	else
	{
		g_bHatsOff[client] = !g_bHatsOff[client];
	}

	g_HatVisibilityCookie.Set(client, g_bHatsOff[client] ? "1" : "0");
	CPrintToChat(client, "{axis}[HatRemoval]{default} Hats are now %s",
		g_bHatsOff[client] ? "disabled" : "enabled");
	return Plugin_Handled;
}

public void WeaponsHatVisibility_OnModeChanged(ConVar convar, const char[] oldValue,
	const char[] newValue)
{
	int mode = StringToInt(newValue);
	if (mode < 0 || mode > 2)
	{
		mode = 0;
		g_cvHatRemovalMode.IntValue = mode;
	}

	switch (mode)
	{
		case 0:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats are now enabled.");
		case 1:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats are now disabled.");
		case 2:
			CPrintToChatAll("{axis}[HatRemoval]{default} Hats can now be toggled.");
	}
}

public Action WeaponsHatVisibility_OnTransmit(int entity, int client)
{
	if (!Client_IsInGame(client))
	{
		return Plugin_Continue;
	}

	int mode = g_cvHatRemovalMode.IntValue;
	return mode == 0 || (mode == 2 && !g_bHatsOff[client])
		? Plugin_Continue
		: Plugin_Handled;
}
