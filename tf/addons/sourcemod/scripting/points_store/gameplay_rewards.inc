#define REWARD_CHANCE_ALWAYS 1.0
#define LAST_DAMAGE_MAX_AGE 1.0
#define MEMOMAN_SOURCE_CUSTOM_WEAPON_KILL "custom_weapon_kill"

ConVar g_GameplayRewardDelay = null;
int g_LastDamageAttackerUserId[MAXPLAYERS + 1];
int g_LastDamageWeaponRef[MAXPLAYERS + 1];
float g_LastDamageAt[MAXPLAYERS + 1];

void GameplayRewards_OnPluginStart()
{
	g_GameplayRewardDelay = CreateConVar(
		"sm_whaletracker_bonus_default_delay",
		"3.0",
		"Seconds to delay gameplay currency awards by default.",
		FCVAR_NONE,
		true,
		0.0);
	HookEvent("player_death", Event_MemomanPlayerDeath, EventHookMode_Post);

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

void GameplayRewards_OnClientPutInServer(int client)
{
	ResetLastDamage(client);
	SDKHook(client, SDKHook_OnTakeDamage, GameplayRewards_OnTakeDamage);
}

void GameplayRewards_OnClientDisconnect(int client)
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

	RewardDefinition reward;
	if (!GetRewardDefinition(type, reward))
	{
		return;
	}

	ApplyBonusPoints(
		client,
		reward.amount,
		true,
		true,
		REWARD_CHANCE_ALWAYS,
		reward.id,
		target,
		delay >= 0.0 ? delay : GameplayRewardDelay(),
		reward.perMapLimit,
		true);
}

void AwardGameplayRewardSteamId(const char[] steamId64, const char[] type)
{
	RewardDefinition reward;
	if (steamId64[0] == 0 || !GetRewardDefinition(type, reward))
	{
		return;
	}

	ApplyBonusPointsSteamId(
		steamId64,
		reward.amount,
		true,
		true,
		reward.id,
		reward.perMapLimit,
		true);
}

bool AwardMemomanReward(
	int client,
	const char[] sourceId,
	const char[] detailId = "",
	const char[] detailName = "")
{
	return Client_IsHumanInGame(client)
		&& MemomanEvent_QueueReward(client, sourceId, detailId, detailName);
}

void ResetLastDamage(int victim)
{
	g_LastDamageAttackerUserId[victim] = 0;
	g_LastDamageWeaponRef[victim] = INVALID_ENT_REFERENCE;
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
	g_LastDamageAt[victim] = GetGameTime();
	return Plugin_Continue;
}

bool GetRecentDamageWeapon(int attacker, int victim, int &weapon)
{
	weapon = -1;
	if (!Client_IsHumanInGame(attacker)
		|| !Client_IsHumanInGame(victim)
		|| g_LastDamageAttackerUserId[victim] != GetClientUserId(attacker)
		|| GetGameTime() - g_LastDamageAt[victim] > LAST_DAMAGE_MAX_AGE)
	{
		return false;
	}

	weapon = EntRefToEntIndex(g_LastDamageWeaponRef[victim]);
	return weapon > MaxClients;
}

bool GetCustomWeaponDetails(
	int weapon,
	char[] itemUid,
	int itemUidLength,
	char[] displayName,
	int displayNameLength)
{
	itemUid[0] = '\0';
	displayName[0] = '\0';
	if (weapon <= MaxClients
		|| !IsValidEntity(weapon)
		|| GetFeatureStatus(FeatureType_Native, "Weapons_GetItemUIDFromEntity") != FeatureStatus_Available)
	{
		return false;
	}

	if (!Weapons_GetItemUIDFromEntity(weapon, itemUid, itemUidLength) || itemUid[0] == '\0')
	{
		return false;
	}

	if (GetFeatureStatus(FeatureType_Native, "Weapons_IsItemReskinOnly") == FeatureStatus_Available
		&& Weapons_IsItemReskinOnly(itemUid))
	{
		return false;
	}

	if (GetFeatureStatus(FeatureType_Native, "Weapons_GetItemDisplayName") != FeatureStatus_Available
		|| !Weapons_GetItemDisplayName(itemUid, displayName, displayNameLength))
	{
		strcopy(displayName, displayNameLength, itemUid);
	}
	return true;
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
	char itemUid[64];
	char displayName[128];
	if (GetRecentDamageWeapon(attacker, victim, damageWeapon)
		&& GetCustomWeaponDetails(
			damageWeapon,
			itemUid,
			sizeof(itemUid),
			displayName,
			sizeof(displayName)))
	{
		AwardMemomanReward(
			attacker,
			MEMOMAN_SOURCE_CUSTOM_WEAPON_KILL,
			itemUid,
			displayName);
	}
}

public void OnAirShot(int attacker, int victim, bool killed)
{
	if (killed)
	{
		AwardGameplayReward(attacker, "airshot_kill", 0);
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
		AwardGameplayRewardSteamId(steamId64, "top_scoring_player");
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
