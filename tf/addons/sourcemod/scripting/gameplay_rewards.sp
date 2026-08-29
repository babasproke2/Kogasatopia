#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdkhooks>

#include <tf2>
#include <tf2_stocks>

#include <points_store_api>

#undef REQUIRE_PLUGIN
#include <cwx>
#include <weaponreverts_api>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#include "include/client_validation.inc"

#define REWARD_CHANCE_ALWAYS 1.0
#define LOCH_N_LOAD_ITEM_DEFINITION 308
#define LAST_DAMAGE_MAX_AGE 1.0
#define MEMOMAN_SOURCE_CUSTOM_WEAPON_KILL "custom_weapon_kill"
#define MEMOMAN_SOURCE_LOCH_N_LOAD_KILL "loch_n_load_kill"
#define MEMOMAN_SOURCE_LOCH_N_LOAD_AIRSHOT "loch_n_load_airshot"
#define MEMOMAN_SOURCE_SENTRY_BUILT "sentry_built"
#define MEMOMAN_SOURCE_SENTRY_KILL "sentry_kill"
#define MEMOMAN_SOURCE_SENTRY_LEVEL_3 "sentry_level_3"
#define MEMOMAN_SOURCE_UBER_DEPLOYED "uber_deployed"

ConVar g_GameplayRewardDelay = null;
int g_LastDamageAttackerUserId[MAXPLAYERS + 1];
int g_LastDamageWeaponRef[MAXPLAYERS + 1];
bool g_LastDamageFromSentry[MAXPLAYERS + 1];
float g_LastDamageAt[MAXPLAYERS + 1];
StringMap g_LevelThreeSentries = null;

public Plugin myinfo =
{
	name = "Gameplay Rewards",
	author = "Hombre",
	description = "Applies Points Store rewards from gameplay event APIs.",
	version = "1.0.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	g_LevelThreeSentries = new StringMap();
	g_GameplayRewardDelay = CreateConVar(
		"sm_whaletracker_bonus_default_delay",
		"3.0",
		"Seconds to delay gameplay currency awards by default.",
		FCVAR_NONE,
		true,
		0.0);
	HookEvent("player_death", Event_MemomanPlayerDeath, EventHookMode_Post);
	HookEvent("player_builtobject", Event_MemomanPlayerBuiltObject, EventHookMode_Post);
	HookEvent("player_upgradedobject", Event_MemomanPlayerUpgradedObject, EventHookMode_Post);

	for (int client = 1; client <= MaxClients; client++)
	{
		ResetLastDamage(client);
		if (IsClientInGame(client))
		{
			SDKHook(client, SDKHook_OnTakeDamage, GameplayRewards_OnTakeDamage);
		}
	}
	AutoExecConfig(true, "gameplay_rewards");
}

public void OnPluginEnd()
{
	delete g_LevelThreeSentries;
	g_LevelThreeSentries = null;
}

public void OnMapStart()
{
	if (g_LevelThreeSentries != null)
	{
		g_LevelThreeSentries.Clear();
	}
}

public void OnClientPutInServer(int client)
{
	ResetLastDamage(client);
	SDKHook(client, SDKHook_OnTakeDamage, GameplayRewards_OnTakeDamage);
}

public void OnClientDisconnect(int client)
{
	ResetLastDamage(client);
}

float GameplayRewardDelay()
{
	return g_GameplayRewardDelay == null ? 3.0 : g_GameplayRewardDelay.FloatValue;
}

void AwardGameplayReward(int client, const char[] type, int target, float delay = -1.0)
{
	if (!Client_IsHumanInGame(client))
	{
		return;
	}

	PointsStore_ApplyBonusPoints(
		client,
		type,
		true,
		true,
		REWARD_CHANCE_ALWAYS,
		target,
		delay >= 0.0 ? delay : GameplayRewardDelay());
}

void AwardMemomanReward(int client, const char[] sourceId)
{
	if (Client_IsHumanInGame(client)
		&& GetFeatureStatus(FeatureType_Native, "PointsStore_AwardMemomanEvent") == FeatureStatus_Available)
	{
		PointsStore_AwardMemomanEvent(client, sourceId);
	}
}

void ResetLastDamage(int victim)
{
	g_LastDamageAttackerUserId[victim] = 0;
	g_LastDamageWeaponRef[victim] = INVALID_ENT_REFERENCE;
	g_LastDamageFromSentry[victim] = false;
	g_LastDamageAt[victim] = 0.0;
}

int ResolveDamageWeapon(int weapon, int inflictor)
{
	if (weapon > MaxClients && IsValidEntity(weapon))
	{
		return weapon;
	}
	if (inflictor > MaxClients
		&& IsValidEntity(inflictor)
		&& HasEntProp(inflictor, Prop_Send, "m_hLauncher"))
	{
		int launcher = GetEntPropEnt(inflictor, Prop_Send, "m_hLauncher");
		if (launcher > MaxClients && IsValidEntity(launcher))
		{
			return launcher;
		}
	}
	return -1;
}

bool IsSentryInflictor(int inflictor)
{
	if (inflictor <= MaxClients || !IsValidEntity(inflictor))
	{
		return false;
	}

	char classname[32];
	GetEntityClassname(inflictor, classname, sizeof(classname));
	return StrEqual(classname, "obj_sentrygun", false);
}

public Action GameplayRewards_OnTakeDamage(
	int victim,
	int &attacker,
	int &inflictor,
	float &damage,
	int &damageType,
	int &weapon,
	float damageForce[3],
	float damagePosition[3],
	int damageCustom)
{
	if (damage <= 0.0
		|| !Client_IsHumanInGame(victim)
		|| !Client_IsHumanInGame(attacker)
		|| attacker == victim
		|| GetClientTeam(victim) <= 1
		|| GetClientTeam(attacker) <= 1
		|| GetClientTeam(victim) == GetClientTeam(attacker))
	{
		return Plugin_Continue;
	}

	g_LastDamageAttackerUserId[victim] = GetClientUserId(attacker);
	int damageWeapon = ResolveDamageWeapon(weapon, inflictor);
	g_LastDamageWeaponRef[victim] = damageWeapon > MaxClients
		? EntIndexToEntRef(damageWeapon)
		: INVALID_ENT_REFERENCE;
	g_LastDamageFromSentry[victim] = IsSentryInflictor(inflictor);
	g_LastDamageAt[victim] = GetGameTime();
	return Plugin_Continue;
}

bool GetRecentDamageWeapon(int attacker, int victim, int &weapon, bool &fromSentry)
{
	weapon = -1;
	fromSentry = false;
	if (!Client_IsHumanInGame(attacker)
		|| !Client_IsHumanInGame(victim)
		|| g_LastDamageAttackerUserId[victim] != GetClientUserId(attacker)
		|| GetGameTime() - g_LastDamageAt[victim] > LAST_DAMAGE_MAX_AGE)
	{
		return false;
	}

	weapon = EntRefToEntIndex(g_LastDamageWeaponRef[victim]);
	fromSentry = g_LastDamageFromSentry[victim];
	return weapon > MaxClients || fromSentry;
}

int GetWeaponItemDefinition(int weapon)
{
	if (weapon <= MaxClients
		|| !IsValidEntity(weapon)
		|| !HasEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex"))
	{
		return -1;
	}
	return GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
}

bool IsCustomWeapon(int weapon)
{
	if (weapon <= MaxClients
		|| !IsValidEntity(weapon)
		|| GetFeatureStatus(FeatureType_Native, "CWX_GetItemUIDFromEntity") != FeatureStatus_Available)
	{
		return false;
	}

	char itemUid[64];
	return CWX_GetItemUIDFromEntity(weapon, itemUid, sizeof(itemUid)) && itemUid[0] != '\0';
}

public void Event_MemomanPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if ((event.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER) != 0)
	{
		return;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!Client_IsHumanInGame(victim) || !Client_IsHumanInGame(attacker) || victim == attacker)
	{
		return;
	}

	int damageWeapon;
	bool fromSentry;
	GetRecentDamageWeapon(attacker, victim, damageWeapon, fromSentry);

	if (event.GetInt("weapon_def_index", -1) == LOCH_N_LOAD_ITEM_DEFINITION
		|| GetWeaponItemDefinition(damageWeapon) == LOCH_N_LOAD_ITEM_DEFINITION)
	{
		AwardMemomanReward(attacker, MEMOMAN_SOURCE_LOCH_N_LOAD_KILL);
	}
	if (IsCustomWeapon(damageWeapon))
	{
		AwardMemomanReward(attacker, MEMOMAN_SOURCE_CUSTOM_WEAPON_KILL);
	}
	if (fromSentry)
	{
		AwardMemomanReward(attacker, MEMOMAN_SOURCE_SENTRY_KILL);
	}
}

public void Event_MemomanPlayerBuiltObject(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int entity = event.GetInt("index");
	if (!Client_IsHumanInGame(client) || !IsSentryInflictor(entity))
	{
		return;
	}
	AwardMemomanReward(client, MEMOMAN_SOURCE_SENTRY_BUILT);
}

public void Event_MemomanPlayerUpgradedObject(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int entity = event.GetInt("index");
	if (!Client_IsHumanInGame(client) || !IsSentryInflictor(entity))
	{
		return;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(EntIndexToEntRef(entity));
	RequestFrame(Frame_CheckLevelThreeSentry, pack);
}

public void Frame_CheckLevelThreeSentry(any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int entityRef = pack.ReadCell();
	delete pack;

	int entity = EntRefToEntIndex(entityRef);
	if (!Client_IsHumanInGame(client)
		|| !IsSentryInflictor(entity)
		|| GetEntProp(entity, Prop_Send, "m_iUpgradeLevel") < 3)
	{
		return;
	}

	char key[16];
	IntToString(entityRef, key, sizeof(key));
	int alreadyAwarded;
	if (g_LevelThreeSentries.GetValue(key, alreadyAwarded))
	{
		return;
	}

	g_LevelThreeSentries.SetValue(key, 1);
	AwardMemomanReward(client, MEMOMAN_SOURCE_SENTRY_LEVEL_3);
}

public void OnAirShot(int attacker, int victim, bool killed)
{
	if (killed)
	{
		AwardGameplayReward(attacker, "airshot_kill", 0);

		int damageWeapon;
		bool fromSentry;
		if (GetRecentDamageWeapon(attacker, victim, damageWeapon, fromSentry)
			&& GetWeaponItemDefinition(damageWeapon) == LOCH_N_LOAD_ITEM_DEFINITION)
		{
			AwardMemomanReward(attacker, MEMOMAN_SOURCE_LOCH_N_LOAD_AIRSHOT);
		}
	}
}

public void OnDropShot(int attacker, int victim)
{
	if (TF2_GetPlayerClass(attacker) == TFClass_Sniper)
	{
		AwardGameplayReward(attacker, "dropshot_kill", victim);
	}
}

public void OnTelefrag(int attacker, int victim)
{
	AwardGameplayReward(attacker, "telefrag_kill", victim);
}

public void OnTopScoringPlayerRoundEnd(const char[] steamId64)
{
	if (steamId64[0] != '\0')
	{
		PointsStore_ApplyBonusPointsSteamId(steamId64, "top_scoring_player", true, true);
	}
}

public void OnAirborneBackstab(int attacker, int victim)
{
	AwardGameplayReward(attacker, "Airborne backstab", victim);
}

public void OnBackstabMilestone(int client, int backstabsThisLife)
{
	if (backstabsThisLife > 0 && backstabsThisLife % 3 == 0)
	{
		AwardGameplayReward(client, "backstabs_life_3", 0);
	}
	if (backstabsThisLife == 6)
	{
		AwardGameplayReward(client, "backstabs_life_6", 0);
	}
}

public void OnHeadshotMilestone(int client, int headshotsThisLife)
{
	if (headshotsThisLife > 0 && headshotsThisLife % 4 == 0)
	{
		AwardGameplayReward(client, "headshot_kills_life_4", 0);
	}
	if (headshotsThisLife == 10)
	{
		AwardGameplayReward(client, "headshot_kills_life_10", 0);
	}
}

public void OnTopScorerKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "top_score_kill", victim);
}

public void OnMarketGardenKill(int attacker, int victim, int attackerClass)
{
	char type[32];
	if (attackerClass == view_as<int>(TFClass_DemoMan))
	{
		strcopy(type, sizeof(type), "market_garden_kill_demoman");
	}
	else
	{
		strcopy(type, sizeof(type), "market_garden_kill");
	}
	AwardGameplayReward(attacker, type, 0);
}

public void OnDemoSyncKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "demo_sync_kill", 0);
}

public void OnSoldierSyncKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "soldier_sync_kill", 0);
}

public void OnMedicUberDropKill(int attacker, int medic)
{
	AwardGameplayReward(attacker, "medic_uber_drop_kill", 0);
}

public void OnMedicHighUberKill(int attacker, int medic, int uberPercent)
{
	AwardGameplayReward(attacker, "medic_high_uber_kill", uberPercent);
}

public void OnMultipleDominations(int client)
{
	AwardGameplayReward(client, "multiple_dominations", 0);
}

public void OnRevenge(int client, int victim)
{
	AwardGameplayReward(client, "player_revenge", victim);
}

public void OnMedicAssistMilestone(int medic, int assistsThisLife)
{
	AwardGameplayReward(medic, "medic_assists", assistsThisLife);
}

public void OnMeatshotMilestone(int client, int meatshotKillsThisLife)
{
	if (meatshotKillsThisLife == 5)
	{
		AwardGameplayReward(client, "meatshot_kills_life_5", 0);
	}
}

public void OnUberDeployed(int medic, int ubersThisLife)
{
	AwardGameplayReward(medic, "uber_deployed", 0);
	AwardMemomanReward(medic, MEMOMAN_SOURCE_UBER_DEPLOYED);
	if (ubersThisLife == 3)
	{
		AwardGameplayReward(medic, "ubers_life_3", 0);
	}
}

public void OnReflectKill(int attacker, int victim, bool directHit)
{
	AwardGameplayReward(attacker, "reflect", 0);
	if (directHit)
	{
		AwardGameplayReward(attacker, "reflect_direct_hit", 0);
	}
}

public void OnJuggle(int attacker, int victim)
{
	AwardGameplayReward(attacker, "Juggle", 0);
}

public void OnMultikill(int client, int kills)
{
	if (kills >= 5)
	{
		AwardGameplayReward(client, "multikill_5_plus", kills, 1.0);
	}
	else if (kills >= 3)
	{
		AwardGameplayReward(client, "multikill_3_4", kills, 1.0);
	}
}

public void OnKillstreak(int client, int killstreak)
{
	if (killstreak < 5 || killstreak % 5 != 0)
	{
		return;
	}

	bool high = killstreak > 10;
	if (high)
	{
		AwardGameplayReward(client, "killstreak_above_10", killstreak);
	}
	else
	{
		AwardGameplayReward(client, "killstreak_5_10", killstreak);
	}
}

public void OnKillstreakEnd(int attacker, int victim, int killstreak)
{
	if (killstreak > 19)
	{
		AwardGameplayReward(attacker, "killstreak_end_20_plus", killstreak);
	}
	else if (killstreak > 14)
	{
		AwardGameplayReward(attacker, "killstreak_end_15_19", killstreak);
	}
	else if (killstreak > 6)
	{
		AwardGameplayReward(attacker, "killstreak_end_7_14", killstreak);
	}
}

public void OnAmbassadorHeadshotKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "ambassador_headshot_kill", 0);
}

public void OnSandmanCleaverCombo(int attacker, int victim)
{
	AwardGameplayReward(attacker, "sandman_cleaver_combo", 0);
}

public void OnMeatshotKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "meatshot_kill", victim);
}

public void OnEnvironmentalKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, "Environmental kill", victim);
}

public void OnSandmanMoonshot(int attacker, int victim)
{
	AwardGameplayReward(attacker, "Sandman moonshot", victim);
}
