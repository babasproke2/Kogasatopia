#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <tf2>
#include <tf2_stocks>

#include <points_store_api>

#undef REQUIRE_PLUGIN
#include <weaponreverts_api>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

#define REWARD_CHANCE_ALWAYS 1.0

ConVar g_GameplayRewardDelay = null;

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
	g_GameplayRewardDelay = CreateConVar(
		"sm_whaletracker_bonus_default_delay",
		"3.0",
		"Seconds to delay gameplay currency awards by default.",
		FCVAR_NONE,
		true,
		0.0);
	AutoExecConfig(true, "gameplay_rewards");
}

float GameplayRewardDelay()
{
	return g_GameplayRewardDelay == null ? 3.0 : g_GameplayRewardDelay.FloatValue;
}

void AwardGameplayReward(int client, int points, const char[] type, int target, int perMap, float delay = -1.0)
{
	if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	PointsStore_ApplyBonusPoints(
		client,
		points,
		true,
		true,
		REWARD_CHANCE_ALWAYS,
		type,
		target,
		delay >= 0.0 ? delay : GameplayRewardDelay(),
		perMap);
}

public void OnAirShot(int attacker, int victim, bool killed)
{
	if (killed)
	{
		AwardGameplayReward(attacker, 1, "airshot_kill", 0, 5);
	}
}

public void OnDropShot(int attacker, int victim)
{
	if (TF2_GetPlayerClass(attacker) == TFClass_Sniper)
	{
		AwardGameplayReward(attacker, 1, "dropshot_kill", victim, 3);
	}
}

public void OnTopScoringPlayerRoundEnd(const char[] steamId64)
{
	if (steamId64[0] != '\0')
	{
		PointsStore_ApplyBonusPointsSteamId(steamId64, 3, true, true, "top_scoring_player", 2);
	}
}

public void OnAirborneBackstab(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "Airborne backstab", victim, 3);
}

public void OnBackstabMilestone(int client, int backstabsThisLife)
{
	if (backstabsThisLife > 0 && backstabsThisLife % 3 == 0)
	{
		AwardGameplayReward(client, 1, "backstabs_life_3", 0, 3);
	}
	if (backstabsThisLife == 6)
	{
		AwardGameplayReward(client, 3, "backstabs_life_6", 0, 1);
	}
}

public void OnHeadshotMilestone(int client, int headshotsThisLife)
{
	if (headshotsThisLife > 0 && headshotsThisLife % 4 == 0)
	{
		AwardGameplayReward(client, 1, "headshot_kills_life_4", 0, 4);
	}
	if (headshotsThisLife == 10)
	{
		AwardGameplayReward(client, 3, "headshot_kills_life_10", 0, 1);
	}
}

public void OnTopScorerKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "top_score_kill", victim, 10);
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
	AwardGameplayReward(attacker, 1, type, 0, 5);
}

public void OnDemoSyncKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "demo_sync_kill", 0, 3);
}

public void OnSoldierSyncKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 2, "soldier_sync_kill", 0, 3);
}

public void OnMedicUberDropKill(int attacker, int medic)
{
	AwardGameplayReward(attacker, 3, "medic_uber_drop_kill", 0, 2);
}

public void OnMedicHighUberKill(int attacker, int medic, int uberPercent)
{
	char reason[64];
	FormatEx(reason, sizeof(reason), "Medic high Übercharge kill (%d%%)", uberPercent);
	AwardGameplayReward(attacker, 1, reason, medic, 2);
}

public void OnMultipleDominations(int client)
{
	AwardGameplayReward(client, 1, "multiple_dominations", 0, 3);
}

public void OnRevenge(int client, int victim)
{
	AwardGameplayReward(client, 1, "player_revenge", victim, 3);
}

public void OnMedicAssistMilestone(int medic, int assistsThisLife)
{
	char reason[32];
	FormatEx(reason, sizeof(reason), "Assists: %d", assistsThisLife);
	AwardGameplayReward(medic, 1, reason, 0, 4);
}

public void OnMeatshotMilestone(int client, int meatshotKillsThisLife)
{
	if (meatshotKillsThisLife == 8)
	{
		AwardGameplayReward(client, 3, "meatshot_kills_life_8", 0, 1);
	}
}

public void OnUberDeployed(int medic, int ubersThisLife)
{
	AwardGameplayReward(medic, 1, "uber_deployed", 0, 4);
	if (ubersThisLife == 3)
	{
		AwardGameplayReward(medic, 2, "3 Übercharges this life", 0, 1);
	}
}

public void OnReflectKill(int attacker, int victim, bool directHit)
{
	AwardGameplayReward(attacker, 1, "reflect", 0, 3);
	if (directHit)
	{
		AwardGameplayReward(attacker, 2, "reflect_direct_hit", 0, 3);
	}
}

public void OnJuggle(int attacker, int victim)
{
	AwardGameplayReward(attacker, 2, "Juggle", 0, 3);
}

public void OnMultikill(int client, int kills)
{
	if (kills >= 5)
	{
		AwardGameplayReward(client, 3, "multikill_5_plus", kills, 4, 1.0);
	}
	else if (kills >= 3)
	{
		AwardGameplayReward(client, 2, "multikill_3_4", kills, 3, 1.0);
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
		AwardGameplayReward(client, 2, "killstreak_above_10", killstreak, 4);
	}
	else
	{
		AwardGameplayReward(client, 1, "killstreak_5_10", killstreak, 3);
	}
}

public void OnKillstreakEnd(int attacker, int victim, int killstreak)
{
	if (killstreak > 19)
	{
		AwardGameplayReward(attacker, 3, "killstreak_end_20_plus", killstreak, 1);
	}
	else if (killstreak > 14)
	{
		AwardGameplayReward(attacker, 2, "killstreak_end_15_19", killstreak, 2);
	}
	else if (killstreak > 6)
	{
		AwardGameplayReward(attacker, 1, "killstreak_end_7_14", killstreak, 3);
	}
}

public void OnAmbassadorHeadshotKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "ambassador_headshot_kill", 0, 5);
}

public void OnSandmanCleaverCombo(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "sandman_cleaver_combo", 0, 4);
}

public void OnMeatshotKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "meatshot_kill", victim, 4);
}

public void OnEnvironmentalKill(int attacker, int victim)
{
	AwardGameplayReward(attacker, 1, "Environmental kill", victim, 3);
}

public void OnSandmanMoonshot(int attacker, int victim)
{
	AwardGameplayReward(attacker, 3, "Sandman moonshot", victim, 1);
}
