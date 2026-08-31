#pragma semicolon 1
#pragma newdecls required

#include "new_engi_buildings/engipads.inc"
#include "new_engi_buildings/amplifier.inc"

#define NEW_ENGI_BUILDINGS_VERSION "1.0.0"

public Plugin myinfo =
{
	name = "New Engineer Buildings",
	author = "RainBolt Dash, Jumento M.D., Naris, FlaminSarge, Starblaster 64, Bad Hombre",
	description = "Adds Amplifiers, Boost Pads, and Jump Pads as Engineer building replacements.",
	version = NEW_ENGI_BUILDINGS_VERSION,
	url = "https://github.com/eltanschauung/Kogasatopia"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	Amplifier_RegisterNatives();
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar(
		"sm_new_engi_buildings_version",
		NEW_ENGI_BUILDINGS_VERSION,
		"New Engineer Buildings version.",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	// EngiPads owns the shared teleporter-mode cookie used by the Amplifier menu.
	EngiPads_OnPluginStart();
	Amplifier_OnPluginStart();
	AutoExecConfig(true, "new_engi_buildings");

	HookEvent("player_death", NewEngiBuildings_PlayerDeath, EventHookMode_Post);
	HookEvent("player_builtobject", NewEngiBuildings_ObjectBuilt, EventHookMode_Post);
	HookEvent("player_carryobject", NewEngiBuildings_ObjectCarried, EventHookMode_Post);
	HookEvent("object_destroyed", NewEngiBuildings_ObjectDestroyed, EventHookMode_Post);
}

public void OnPluginEnd()
{
	Amplifier_OnPluginEnd();
	EngiPads_OnPluginEnd();
}

public void OnConfigsExecuted()
{
	EngiPads_OnConfigsExecuted();
	Amplifier_OnConfigsExecuted();
}

public void OnMapStart()
{
	EngiPads_OnMapStart();
	Amplifier_OnMapStart();
}

public void OnMapEnd()
{
	Amplifier_OnMapEnd();
	EngiPads_OnMapEnd();
}

public void OnClientPostAdminCheck(int client)
{
	EngiPads_OnClientPostAdminCheck(client);
	Amplifier_OnClientPostAdminCheck(client);
}

public void OnClientCookiesCached(int client)
{
	Amplifier_OnClientCookiesCached(client);
}

public void OnClientDisconnect(int client)
{
	Amplifier_OnClientDisconnect(client);
	EngiPads_OnClientDisconnect(client);
}

public void NewEngiBuildings_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	PlayerDeath(event, name, dontBroadcast);
	event_player_death(event, name, dontBroadcast);
}

public void NewEngiBuildings_ObjectBuilt(Event event, const char[] name, bool dontBroadcast)
{
	ObjectBuilt(event, name, dontBroadcast);
	Event_Build(event, name, dontBroadcast);
}

public void NewEngiBuildings_ObjectCarried(Event event, const char[] name, bool dontBroadcast)
{
	ObjectDestroyed(event, name, dontBroadcast);
	Event_ObjectCarried(event, name, dontBroadcast);
}

public void NewEngiBuildings_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
	ObjectDestroyed(event, name, dontBroadcast);
	Event_ObjectDestroyed(event, name, dontBroadcast);
}
