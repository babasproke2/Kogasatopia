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

#include "include/client_validation.inc"

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
	if (meatshotKillsThisLife == 8)
	{
		AwardGameplayReward(client, "meatshot_kills_life_8", 0);
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
