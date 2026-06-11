#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <clientprefs>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#undef REQUIRE_PLUGIN
#include <saysounds>
#include <points_store_api>
#define REQUIRE_PLUGIN

native bool Filters_GetChatName(int client, char[] buffer, int maxlen);

#define HEADSHOT_SUPPRESS_WINDOW 0.5
#define AIRSHOT_MIN_HEIGHT 50.0
#define MEDIC_CROSSBOW_AIRSHOT_MIN_HEIGHT 100.0 // Supstats2 uses a height of 170.0
#define SOUND_AIRSHOT "misc/taps_02.wav"
#define SOUND_AIRSHOT_DOWNLOAD "sound/misc/taps_02.wav"
#define SAYSOUND_AIRSHOT_COMMAND "airshot"

bool g_bSaySoundsAvailable = false;
int g_iPendingAirshotAttacker[MAXPLAYERS + 1];
float g_fLastHeadshotTime[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errMax)
{
	MarkNativeAsOptional("Filters_GetChatName");
	MarkNativeAsOptional("PointsStore_ApplyBonusPoints");
	return APLRes_Success;
}

public Plugin myinfo =
{
	name = "[TF2] Airshot",
	author = "Jerry",
	description = "Detects projectile airshots.",
	version = "1.0",
	url = ""
};
public void OnPluginStart()
{
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	g_bSaySoundsAvailable = LibraryExists("saysounds");

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		}
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "saysounds"))
	{
		g_bSaySoundsAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "saysounds"))
	{
		g_bSaySoundsAvailable = false;
	}
}

public void OnMapStart()
{
	PrecacheSound(SOUND_AIRSHOT, true);
	AddFileToDownloadsTable(SOUND_AIRSHOT_DOWNLOAD);
}
public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	ResetAirshotState(client);
}
public void OnClientDisconnect(int client)
{
	SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	ResetAirshotState(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "tf_projectile_healing_bolt", false))
	{
		SDKHook(entity, SDKHook_Touch, OnCrossbowBoltTouch);
	}
}

public void OnCrossbowBoltTouch(int entity, int other)
{
	if (other <= 0 || other > MaxClients)
		return;

	int attacker = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	int weapon = -1;
	if (HasEntProp(entity, Prop_Send, "m_hLauncher"))
	{
		weapon = GetEntPropEnt(entity, Prop_Send, "m_hLauncher");
	}

	if (IsMedicCrossbowAirshot(attacker, other, weapon, entity, 1.0))
	{
		QueueAirshotBroadcast(attacker, other);
	}
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (IsMedicCrossbowAirshot(attacker, victim, weapon, inflictor, damage))
	{
		QueueAirshotBroadcast(attacker, victim);
	}

	return Plugin_Continue;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidClient(victim) || !IsValidClient(attacker) || attacker == victim)
	{
		if (IsValidClient(victim))
			ResetAirshotState(victim);
		return;
	}
	if (IsFakeClient(attacker) || IsFakeClient(victim))
	{
		ResetAirshotState(victim);
		return;
	}
	int customkill = event.GetInt("customkill");
	bool isHeadshot = (customkill == TF_CUSTOM_HEADSHOT
		|| customkill == TF_CUSTOM_HEADSHOT_DECAPITATION
		|| customkill == TF_CUSTOM_PENETRATE_HEADSHOT);
	bool isMidairHeadshot = isHeadshot
		&& !(GetEntityFlags(attacker) & FL_ONGROUND)
		&& (DistanceAboveGround(attacker) > AIRSHOT_MIN_HEIGHT);

	if (!isMidairHeadshot)
	{
		g_fLastHeadshotTime[victim] = 0.0;
		return;
	}
	g_fLastHeadshotTime[victim] = GetGameTime();
	g_iPendingAirshotAttacker[victim] = 0;
	char attackerName[256];
	char victimName[256];
	BuildDisplayName(attacker, attackerName, sizeof(attackerName));
	BuildDisplayName(victim, victimName, sizeof(victimName));
	CPrintToChatAll("%s dropshot %s!", attackerName, victimName);
	if (g_bSaySoundsAvailable)
	{
		SaySounds_PlayCommand(0, SAYSOUND_AIRSHOT_COMMAND);
	}
	else
	{
		EmitSoundToClient(attacker, SOUND_AIRSHOT);
		EmitSoundToClient(victim, SOUND_AIRSHOT);
	}
	ResetAirshotState(victim);
}

public void WhaleTracker_OnAirshot(int attacker, int victim)
{
	if (!IsValidClient(attacker) || !IsValidClient(victim) || attacker == victim)
		return;
	if (IsFakeClient(attacker) || IsFakeClient(victim))
		return;

	QueueAirshotBroadcast(attacker, victim);
}

static void QueueAirshotBroadcast(int attacker, int victim)
{
	if (g_iPendingAirshotAttacker[victim] == attacker)
	{
		return;
	}

	g_iPendingAirshotAttacker[victim] = attacker;
	CreateTimer(0.0, Timer_BroadcastAirshot, GetClientUserId(victim));
}

public Action Timer_BroadcastAirshot(Handle timer, any userid)
{
	int victim = GetClientOfUserId(userid);
	if (!IsValidClient(victim))
		return Plugin_Stop;

	int attacker = g_iPendingAirshotAttacker[victim];
	if (!IsValidClient(attacker) || attacker == victim)
	{
		ResetAirshotState(victim);
		return Plugin_Stop;
	}

	if (g_fLastHeadshotTime[victim] > 0.0
		&& (GetGameTime() - g_fLastHeadshotTime[victim]) <= HEADSHOT_SUPPRESS_WINDOW)
	{
		ResetAirshotState(victim);
		return Plugin_Stop;
	}

	char attackerName[256];
	char victimName[256];
	BuildDisplayName(attacker, attackerName, sizeof(attackerName));
	BuildDisplayName(victim, victimName, sizeof(victimName));
	CPrintToChatAll("%s airshot %s!", attackerName, victimName);
	if (!IsPlayerAlive(victim))
	{
		if (GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints") == FeatureStatus_Available)
		{
			PointsStore_ApplyBonusPoints(attacker, 1, true, true, 1.0, "airshot_kill", 0, 3.0, 10);
		}
		if (g_bSaySoundsAvailable)
		{
			SaySounds_PlayCommand(0, SAYSOUND_AIRSHOT_COMMAND);
		}
		else
		{
			EmitSoundToClient(attacker, SOUND_AIRSHOT);
			EmitSoundToClient(victim, SOUND_AIRSHOT);
		}
	}
	ResetAirshotState(victim);
	return Plugin_Stop;
}
static bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static void BuildDisplayName(int client, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
		&& Filters_GetChatName(client, buffer, maxlen)
		&& buffer[0] != '\0')
	{
		ResolveTeamColorTag(client, buffer, maxlen);
		return;
	}

	char colorTag[16];
	BuildTeamColorTag(client, colorTag, sizeof(colorTag));
	Format(buffer, maxlen, "%s%N{default}", colorTag, client);
}

static void ResolveTeamColorTag(int client, char[] buffer, int maxlen)
{
	if (StrContains(buffer, "{teamcolor}", false) == -1)
	{
		return;
	}

	char colorTag[16];
	BuildTeamColorTag(client, colorTag, sizeof(colorTag));
	ReplaceString(buffer, maxlen, "{teamcolor}", colorTag, false);
}

static void BuildTeamColorTag(int client, char[] colorTag, int length)
{
	switch (GetClientTeam(client))
	{
		case 2: strcopy(colorTag, length, "{red}");
		case 3: strcopy(colorTag, length, "{blue}");
		default: strcopy(colorTag, length, "{default}");
	}
}

static bool IsMedicCrossbowAirshot(int attacker, int victim, int weapon, int inflictor, float damage)
{
	if (damage <= 0.0)
		return false;
	if (!IsValidClient(attacker) || !IsValidClient(victim) || attacker == victim)
		return false;
	if (IsFakeClient(attacker) || IsFakeClient(victim))
		return false;
	if (TF2_GetPlayerClass(attacker) != TFClass_Medic)
		return false;

	int primary = GetPlayerWeaponSlot(attacker, 0);
	if (primary <= MaxClients || !IsValidEntity(primary))
		return false;

	char classname[64];
	GetEntityClassname(primary, classname, sizeof(classname));
	if (!StrEqual(classname, "tf_weapon_crossbow", false))
		return false;
	if (weapon != primary && !IsCrossbowProjectileFromWeapon(inflictor, primary))
		return false;

	return IsMedicCrossbowAirshotVictim(victim);
}

static bool IsCrossbowProjectileFromWeapon(int inflictor, int weapon)
{
	if (inflictor <= MaxClients || !IsValidEntity(inflictor))
		return false;

	if (HasEntProp(inflictor, Prop_Send, "m_hLauncher")
		&& GetEntPropEnt(inflictor, Prop_Send, "m_hLauncher") == weapon)
	{
		return true;
	}

	char classname[64];
	GetEntityClassname(inflictor, classname, sizeof(classname));
	return StrEqual(classname, "tf_projectile_healing_bolt", false);
}

static bool IsMedicCrossbowAirshotVictim(int victim)
{
	int flags = GetEntityFlags(victim);
	if ((flags & (FL_ONGROUND | FL_INWATER)) != 0)
		return false;

	return DistanceAboveGroundBox(victim) >= MEDIC_CROSSBOW_AIRSHOT_MIN_HEIGHT;
}

static float DistanceAboveGround(int client)
{
	float start[3];
	float end[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", start);
	end[0] = start[0];
	end[1] = start[1];
	end[2] = start[2] - 8192.0;
	Handle trace = TR_TraceRayFilterEx(start, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceEntityFilterPlayers, client);
	if (trace == INVALID_HANDLE)
		return 0.0;
	float hitPos[3];
	TR_GetEndPosition(hitPos, trace);
	CloseHandle(trace);
	return GetVectorDistance(start, hitPos);
}

static float DistanceAboveGroundBox(int client)
{
	float start[3];
	float end[3];
	float direction[3] = { 0.0, 0.0, -16384.0 };
	float hullMins[3] = { -24.0, -24.0, 0.0 };
	float hullMaxs[3] = { 24.0, 24.0, 0.0 };
	GetClientAbsOrigin(client, start);
	AddVectors(direction, start, end);

	Handle trace = TR_TraceHullFilterEx(start, end, hullMins, hullMaxs, MASK_PLAYERSOLID, TraceEntityFilterPlayers, client);
	if (trace == INVALID_HANDLE)
		return 0.0;

	float hitPos[3];
	TR_GetEndPosition(hitPos, trace);
	CloseHandle(trace);
	return GetVectorDistance(start, hitPos, false);
}

public bool TraceEntityFilterPlayers(int entity, int contentsMask, any data)
{
	if (entity == data)
		return false;
	return true;
}
static void ResetAirshotState(int client)
{
	g_iPendingAirshotAttacker[client] = 0;
	g_fLastHeadshotTime[client] = 0.0;
}
