#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>
#include <sdkhooks>

#include <tf2>
#include <tf2_stocks>
#include <tf2utils>
#include <tf2attributes>
#include <tf2items>

#include <tf_custom_attributes>
#include <sourcescramble>
#include <dhooks>
#include <addplayerhealth>

#undef REQUIRE_EXTENSIONS
#include <scattergun_pellets>
#include <tf2_spread_patterns>
#define REQUIRE_EXTENSIONS

#include "include/steam_identity.inc"
#include "include/item_indexes.inc"
#include "include/tf2_classes.inc"

#define FLS_STREAK_TARGET	   2
#define FLS_STREAK_WINDOW	   4.0
#define AMBASSADOR_ITEMDEF 61
#define FESTIVE_AMBASSADOR_ITEMDEF 1006
#define ATTR_SANDMAN_PRE_JI "sandman pre_ji"
#define SANDMAN_ITEMDEF 44
#define SANDMAN_DAMAGE_CUSTOM TF_CUSTOM_BASEBALL
#define SANDMAN_PRE_JI_DAMAGE 15.0
#define SANDMAN_PRE_JI_MIN_STUN_RATIO 0.1
#define SANDMAN_PRE_JI_SLOWDOWN 0.5
#define MAX_TRACKED_ENTITIES 2049

#define FLS_EXPLODE_DAMAGE	 50.0
#define FLS_EXPLODE_RADIUS	 180.0
#define FLS_EXPLODE_SOUND	"ambient/fire/gascan_ignite1.wav"
#define FLS_NOTIFY_SOUND "vo/taunts/pyro/pyro_taunt_rps_exert_21.mp3"
#define FLS_NOTIFY_2 "vo/taunts/pyro/pyro_taunt_rps_exert_23.mp3"
#define SOUND_ARROW_HEAL "weapons/fx/rics/arrow_impact_crossbow_heal.wav"
#define SOUND_NEON_SIGN "weapons/neon_sign_hit_world_02.wav"
#define SOUND_DISPENSER_METAL "weapons/dispenser_generate_metal.wav"
#define SOUND_POMSON_DRAIN "weapons/drg_pomson_drain_01.wav"
#define SOUND_FLAME_OUT "player/flame_out.wav"
#define ATTR_PRIMARY_CLIP_SIZE_BONUS "clip size bonus primary"
#define ATTR_CLIP_SIZE_BONUS "clip size bonus"
#define ATTR_RESTORE_PRIMARY_SHOT_BY_DAMAGE "restore primary shot by damage"
#define ATTR_RESTORE_PRIMARY_SHOT_KILL "restore primary shot kill"
#define ATTR_SECONDARY_REFILL_SOUND "ui/item_metal_tiny_pickup.wav"
#define ATTR_HARVESTER_HEALING 3
#define ATTR_HARVESTER_HEALING_COUNT 6
#define ATTR_HARVESTER_AFTERBURN_HEALING_COUNT 1
#define HARVESTER_HEAL_COUNT_MAX 30
#define HARVESTER_HEAL_TIMER_INTERVAL 0.5
#define HARVESTER_DIRECT_HEAL_BLOCK_TIME 0.5
#define HARVESTER_HINT_DURATION 1.0
#define ATTR_RELOAD_ON_HIT "reload on hit"
#define ATTR_RELOAD_ON_KILL "reload on kill"
#define ATTR_AMBASSADOR_102 "ambassador 102"
#define ATTR_RANDOM_SPREAD_OVERRIDE "random spread override"
#define ATTR_RANDOM_CRITS_OVERRIDE "random crits override"
#define ATTR_RECOIL_JUMPING "recoil jumping"
#define ATTR_CIRCULAR_BULLET_SPREAD "circular bullet spread"
#define ATTR_WIDE_HORIZONTAL_BULLET_SPREAD "wide horizontal bullet spread"
#define ATTR_AMBASSADOR_ACCURACY_RECOVERY "ambassador accuracy recovery"
#define ATTR_PUNCH_ANGLE_IS_CONSISTENT "punch angle is consistent"
#define ATTR_PUNCH_ANGLE_MOD "punch angle mod"
#define ATTR_SCATTERGUN_HAS_KNOCKBACK "scattergun has knockback"
#define ATTR_IGNITE_ON_FULL_PELLET_HIT "ignite on full pellet hit"
#define ATTR_HITSCAN_NO_DAMAGE_PHYSICS "hitscan no damage physics"
#define ATTR_HEADSHOTS_ENABLED "headshots enabled"
#define ATTR_HEADSHOTS_ENABLED_WHILE_ZOOMED "headshots enabled while zoomed"
#define ATTR_HUNTING_REVOLVER "hunting revolver attributes"
#define ATTR_ESCAMPETTE "escampette attributes"
#define ATTR_MAX_PRIMARY_CLIP_OVERRIDE "mod max primary clip override"
#define ESCAMPETTE_WATCH_SLOT 4
#define HUNTING_REVOLVER_FOV 48
#define HUNTING_REVOLVER_ZOOM_TIME 0.20
#define HUNTING_REVOLVER_MAX_ZOOM_SPEED 120.0
#define TF_AMMO_PRIMARY_INDEX 1
#define SOUND_AMBASSADOR_CRIT_RECEIVED "player/crit_received1.wav"
#define SOUND_AMBASSADOR_CRIT_HIT "player/crit_hit.wav"
#define RESTORE_PRIMARY_SHOT_DAMAGE_WINDOW 5.0

#define SPROKE_ATTR_NAME		"sproke attribute"
#define SPROKE_PRIMARY_ATTR		"mod max primary clip override"
#define SPROKE_ALT_ATTR		"Reload time decreased"
#define SPROKE_PRIMARY_FACTOR	  -1.0
#define SPROKE_ALT_FACTOR	  0.75
#define SPROKE_PARTICLE_RED		 "soldierbuff_red_buffed"
#define SPROKE_PARTICLE_BLUE	 "soldierbuff_blue_buffed"
#define BURP_SOUND		"vo/burp02.mp3"

#define TF2_JUMP_NONE 0
#define TF2_JUMP_ROCKET_START 1
#define TF2_JUMP_ROCKET 2
#define TF2_JUMP_STICKY 3

#define FAN_O_WAR_MAX_MARK_COUNT 3
#define BONK_MARK_FOR_DEATH_MIN 2.0
#define BONK_MARK_FOR_DEATH_MAX 5.0

#define LUNCHBOX_CHOCOLATE_BAR 1
#define LUNCHBOX_FISHCAKE 7
#define DALOKOHS_OVERHEAL 450
#define ATTR_VITA_SAW_REVERT "vita saw revert"
#define VITASAW_MAX_PRESERVED_CHARGE 0.20
#define WEAPON_SLOT_PRIMARY 0
#define WEAPON_SLOT_LAST 5

#define WEAPON_REVERTS_CONFIG_PATH "configs/weapons.cfg"
#define WEAPON_REVERTS_ITEM_CLASSES_SECTION "WeaponRevertsItemClasses"
#define FLAME_SHOTGUN_FULL_PELLET_THRESHOLD 6

tf2_player tf2_players[MAXPLAYERS + 1];
float g_flProjectileSpawnTime[MAX_TRACKED_ENTITIES];
bool g_bProjectileSandmanPreJI[MAX_TRACKED_ENTITIES];
int g_iSandmanStunFrame[MAXPLAYERS + 1];
int g_iSandmanStunInflictorRef[MAXPLAYERS + 1];
#define ENVIRONMENTAL_KILL_CREDIT_WINDOW 10.0

int g_iEnvironmentalKillAttackerUserId[MAXPLAYERS + 1];
float g_fEnvironmentalKillTime[MAXPLAYERS + 1];

enum struct tf2_player
{
	int jump_status;
	int scytheWeapon;
	int shockCharge;
	int healCount;
	float lastHarvesterDirectHealTime;
	Handle harvesterHealTimer;
	Handle harvesterHintTimer;
	Handle shockChargeTimer;
	bool harvesterHealHintVisible;
	bool harvesterCritConsumePending;
	bool harvesterCritBoostApplied;
	float lastUber;
	int lastUberMedigunDefIndex;
	int engiMetal;
	int accuracyStreak;
	float accuracyStreakExpiresAt;
	float secondaryDamageProgress;
	float secondaryDamageProgressExpiresAt;
	Handle sprokeTimer;
	int sprokePrimaryRef;
	int sprokeParticleRef;
	int sprokeClipRecord;
	int markVictims[FAN_O_WAR_MAX_MARK_COUNT+1];
	int bonkFrame;
	int oldHealth;
	bool huntingRevolverZoomed;
	float huntingRevolverZoomReadyTime;
	bool huntingRevolverAttack2Held;
	int huntingRevolverWeaponRef;
}

Handle g_SDKGetMaxClip1 = null;
Handle g_SDKGetAfterburnRateOnHit = null;
Handle g_SDKTeamFortressSetSpeed = null;
Handle g_SDKSetFOV = null;
int g_iMetalOffset = -1;
bool g_bWarnedMetalOffset = false;
bool g_bAccuracyExploding[MAXPLAYERS + 1];
int g_iAmbassadorCritParticle = INVALID_STRING_INDEX;
bool g_bPendingFullPelletIgnite[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_iPendingFullPelletWeaponRef[MAXPLAYERS + 1][MAXPLAYERS + 1];
float g_fPendingFullPelletBurnDuration[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_iPendingFullPelletTick[MAXPLAYERS + 1][MAXPLAYERS + 1];

#include <weaponreverts>
#include "weaponreverts/gameplay_events.sp"
#include "weaponreverts/scattergun_knockback.sp"
 
ConVar g_sEnabled;
ConVar g_hPomsonDamageMult;
ConVar g_hBisonDamageMult;
ConVar g_hScattergunPelletsDebug;
ConVar g_hMeatshotDebug;
ConVar g_hFallingStompAllWeapons;
ConVar g_hSandmanBaseDuration;
ConVar g_hSandmanMaxStunFlightTime;
ConVar g_hSandmanFallbackBaseDuration;
KeyValues g_hWeaponRevertsConfig = null;
bool g_bPluginEnding = false;
MemoryPatch patch_RevertCozyCamper_FlinchNerf;
MemoryPatch patch_AllowRandomCritOverride;

MemoryPatch patch_Wrangler_CustomShieldRepair;
MemoryPatch patch_Wrangler_CustomShieldShellRefill;
MemoryPatch patch_Wrangler_CustomShieldRocketRefill;
MemoryPatch patch_Wrangler_CustomShieldDamageTaken;
MemoryPatch patch_Wrangler_RescueRanger_CustomShieldRepair;
float g_flWranglerCustomShieldValue = 0.85;

DynamicDetour dhook_CTFPlayer_CalculateMaxSpeed;
DynamicDetour dhook_CTFLunchBox_ApplyBiteEffects;
DynamicDetour dhook_CTFPlayerShared_StunPlayer;
DynamicDetour dhook_IsFixedWeaponSpreadEnabled;
DynamicHook dhook_CObjectCartDispenser_DispenseMetal;
DynamicHook dhook_CTFWeaponBase_CanFireCriticalShot;
DynamicHook dhook_CTFStunBall_ApplyBallImpactEffectOnVictim;
Handle g_SDKCalcIsAttackCriticalHelper = null;
bool g_bCalculatingRandomCritOverride = false;

static bool WeaponReverts_IsEnabled()
{
	return !g_bPluginEnding && g_sEnabled != null && GetConVarBool(g_sEnabled);
}

static bool WeaponReverts_IsEntityIndex(int entity)
{
	return entity > 0 && entity < GetMaxEntities();
}

static void WeaponReverts_ApplyEngineOverrides(int weapon)
{
	if (!IsValidWeaponEntity(weapon))
	{
		return;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_HUNTING_REVOLVER, 0) != 0)
	{
		SetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", TF_AMMO_PRIMARY_INDEX);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Spread_SetPattern") == FeatureStatus_Available)
	{
		TF2SpreadPattern pattern = TF2Spread_Default;
		if (TF2CustAttr_GetInt(weapon, ATTR_WIDE_HORIZONTAL_BULLET_SPREAD, 0) != 0)
		{
			pattern = TF2Spread_WideHorizontal20;
		}
		else if (TF2CustAttr_GetInt(weapon, ATTR_CIRCULAR_BULLET_SPREAD, 0) != 0)
		{
			pattern = TF2Spread_Circular15;
		}
		TF2Spread_SetPattern(weapon, pattern);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Scatter_SetWeaponPelletCount") == FeatureStatus_Available)
	{
		float pelletCount = TF2Attrib_HookValueFloat(10.0, "mult_bullets_per_shot", weapon);
		int pelletsFired = RoundToNearest(pelletCount);
		if (pelletsFired < 1)
		{
			pelletsFired = 1;
		}
		TF2Scatter_SetWeaponPelletCount(weapon, pelletsFired);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Spread_SetAmbassadorAccuracy") == FeatureStatus_Available)
	{
		bool enabled = TF2CustAttr_GetInt(weapon, ATTR_AMBASSADOR_ACCURACY_RECOVERY, 0) != 0;
		TF2Spread_SetAmbassadorAccuracy(weapon, enabled);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Weapon_SetPunchAngle") == FeatureStatus_Available)
	{
		char amountValue[16];
		TF2CustAttr_GetString(weapon, ATTR_PUNCH_ANGLE_MOD, amountValue, sizeof(amountValue));
		bool enabled = amountValue[0] != '\0';
		int amount = enabled ? StringToInt(amountValue) : 0;
		bool consistent = TF2CustAttr_GetInt(weapon, ATTR_PUNCH_ANGLE_IS_CONSISTENT, 0) != 0;
		TF2Weapon_SetPunchAngle(weapon, enabled, amount, consistent);
	}

}

static bool WeaponReverts_HasHeadshotFeature(int weapon)
{
	return TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED, 0) != 0
		|| TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED_WHILE_ZOOMED, 0) != 0
		|| TF2CustAttr_GetInt(weapon, ATTR_AMBASSADOR_ACCURACY_RECOVERY, 0) != 0;
}

static bool WeaponReverts_IsHeadshotZoomed(int weapon)
{
	if (!IsValidWeaponEntity(weapon))
	{
		return false;
	}

	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (!WR_IsValidPlayerIndex(client) || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return false;
	}

	return GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == weapon
		&& tf2_players[client].huntingRevolverZoomed
		&& tf2_players[client].huntingRevolverZoomReadyTime > 0.0
		&& GetGameTime() >= tf2_players[client].huntingRevolverZoomReadyTime
		&& EntRefToEntIndex(tf2_players[client].huntingRevolverWeaponRef) == weapon;
}

static bool WeaponReverts_CanHeadshotNow(int weapon)
{
	if (TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED, 0) != 0)
	{
		return true;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED_WHILE_ZOOMED, 0) != 0)
	{
		if (!WeaponReverts_IsHeadshotZoomed(weapon))
		{
			return false;
		}

		float lastFireTime = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
		return GetGameTime() - lastFireTime >= 1.0;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_AMBASSADOR_ACCURACY_RECOVERY, 0) == 0)
	{
		return false;
	}

	return GetFeatureStatus(
		FeatureType_Native, "TF2Spread_IsAmbassadorAccuracyRecovered") == FeatureStatus_Available
		&& TF2Spread_IsAmbassadorAccuracyRecovered(weapon);
}

static void WeaponReverts_DeleteConfigs()
{
	if (g_hWeaponRevertsConfig != null)
	{
		delete g_hWeaponRevertsConfig;
		g_hWeaponRevertsConfig = null;
	}

}

public Plugin myinfo =
{
	name = "WeaponReverts",
	author = "Hombre, Huutti, Utsuho",
	description = "Weapon changes plugin with custom attribute code such as recoil jumping",
	version = "6.0",
	url = "https://kogasa.tf"
};

// Addplayerhealth was made by chdata, I'm not able to find it online anymore so I'll rehost it in this repo
// Thank you Huutti/Castaway, Chaosxk, Drixevel and others for several pieces of code

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
	RegPluginLibrary("weaponreverts");
	MarkNativeAsOptional("TF2Util_GetPlayerFromSharedAddress");
	CreateNative("WeaponReverts_GetWeaponInfo", Native_GetWeaponInfo);
	CreateNative("WeaponReverts_CanClassUseWeapon", Native_CanClassUseWeapon);
	return APLRes_Success;
}

stock void ResetClientArrays(int client)
{
	if (!WR_IsValidPlayerIndex(client)) return;
	HuntingRevolver_ResetClient(client);
	FullPelletIgnite_ClearClient(client);
	Harvester_ClearState(client);
	ShockCharge_StopTimer(client);
	tf2_players[client].shockCharge = 30;
	tf2_players[client].lastUber = 0.0;
	tf2_players[client].lastUberMedigunDefIndex = 0;
	tf2_players[client].engiMetal = 0;
	tf2_players[client].accuracyStreak = 0;
	tf2_players[client].accuracyStreakExpiresAt = 0.0;
	SecondaryDamageRefill_Reset(client);
	tf2_players[client].jump_status = TF2_JUMP_NONE;
	tf2_players[client].oldHealth = 0;
	if (tf2_players[client].sprokeTimer != null)
	{
		KillTimer(tf2_players[client].sprokeTimer);
		tf2_players[client].sprokeTimer = null;
	}
	Sproke_ClearEffect(client, true, false);
	for (int i = 0; i <= FAN_O_WAR_MAX_MARK_COUNT; i++)
	{
		tf2_players[client].markVictims[i] = -1;
	}
	g_iSandmanStunFrame[client] = 0;
	g_iSandmanStunInflictorRef[client] = INVALID_ENT_REFERENCE;
	g_iEnvironmentalKillAttackerUserId[client] = 0;
	g_fEnvironmentalKillTime[client] = 0.0;
	ScattergunKnockback_ResetClient(client);
}

public void OnPluginStart() {
	g_bPluginEnding = false;
	WeaponRevertsEvents_Init();
	PreCacheWeaponSounds();
	g_sEnabled = CreateConVar("reverts_enabled", "1", "Enable/Disable the plugin");
	g_sEnabled.AddChangeHook(WeaponReverts_OnEnabledChanged);
	g_hPomsonDamageMult = CreateConVar("reverts_pomson_damage_mult", "0.50", "Damage multiplier for the Pomson 6000", FCVAR_NONE, true, 0.1, true, 2.0);
	g_hBisonDamageMult = CreateConVar("reverts_bison_damage_mult", "0.8", "Damage multiplier for the Righteous Bison", FCVAR_NONE, true, 0.1, true, 2.0);
	g_hScattergunPelletsDebug = CreateConVar("reverts_scattergun_pellets_debug", "0", "Log tracked shotgun/scattergun pellet forward diagnostics.");
	g_hMeatshotDebug = CreateConVar("meatshot_debug", "0", "Print a client debug message after a valid meatshot kill.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hFallingStompAllWeapons = CreateConVar("reverts_falling_stomp_all_weapons", "1", "Enable boots falling stomp on all player weapons.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hSandmanMaxStunFlightTime = CreateConVar("reverts_sandman_max_stun_flight_time", "1.5", "Flight time at which the reverted Sandman reaches maximum stun duration.", FCVAR_NONE, true, 0.1);
	g_hSandmanFallbackBaseDuration = CreateConVar("reverts_sandman_fallback_base_duration", "2.0", "Fallback maximum Sandman stun duration when tf_scout_stunball_base_duration is unavailable.", FCVAR_NONE, true, 0.1);
	g_hSandmanBaseDuration = FindConVar("tf_scout_stunball_base_duration");
	LoadWeaponRevertsConfig();
	RegAdminCmd("sm_scatterpellets_status", Command_ScatterPelletsStatus, ADMFLAG_GENERIC, "Print scattergun pellet integration status.");
	RegAdminCmd("sm_weaponreverts_reload", Command_ReloadWeaponRevertsConfig, ADMFLAG_CONFIG, "Reload weapon revert definitions from configs/weapons.cfg.");
	RegAdminCmd("sm_weaponreverts_refresh", Command_ReloadWeaponRevertsConfig, ADMFLAG_CONFIG, "Refresh weapon revert definitions from configs/weapons.cfg.");
	if (WeaponReverts_IsEnabled()) {
		g_iMetalOffset = FindSendPropInfo("CTFPlayer", "m_iAmmo");
	// This is used to ignore clients without the m_iAmmo netprop

		for (int i = 1; i <= MaxClients; i++)
		{
			tf2_players[i].sprokeTimer = null;
			tf2_players[i].sprokePrimaryRef = INVALID_ENT_REFERENCE;
			tf2_players[i].sprokeParticleRef = INVALID_ENT_REFERENCE;
			tf2_players[i].sprokeClipRecord = 0;
			tf2_players[i].jump_status = TF2_JUMP_NONE;

			if (IsClientInGame(i))
			{
				ResetClientArrays(i);
				// Ensure all damage/trace hooks are installed for clients that are already in-game
				SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
				SDKHook(i, SDKHook_WeaponSwitch, OnWeaponSwitch);
				SDKHook(i, SDKHook_TraceAttack, OnTraceAttack);
				SDKHook(i, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
				SDKHook(i, SDKHook_OnTakeDamageAlivePost, WeaponReverts_OnTakeDamageAlivePost);
				SDKHook(i, SDKHook_PostThinkPost, HuntingRevolver_OnPostThinkPost);
			}
		}

		HookAllBuildings();
		HookEvent("player_builtobject", Event_PlayerBuiltObject);

		HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
		HookEvent("post_inventory_application", Event_Resupply, EventHookMode_Post);
		HookEvent("player_spawn", OnPlayerSpawn);
		HookEvent("player_changeclass", Event_PlayerChangeClass, EventHookMode_Post);
		HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

		// Blast jumping hooks

		HookEvent("rocket_jump",				Event_TF2RocketJump);
		HookEvent("rocket_jump_landed",			Event_TF2JumpLanded);
		HookEvent("sticky_jump",				Event_TF2StickyJump);
		HookEvent("sticky_jump_landed",			Event_TF2JumpLanded);

		GameData conf;
		conf = new GameData("weaponreverts");
		if (conf == null) SetFailState("Failed to load weaponreverts.txt conf!");
		GameData overrideConf = new GameData("weapon_overrides.games");
		if (overrideConf == null) SetFailState("Failed to load weapon_overrides.games.txt conf!");

		// Setup SDKCall for GetMaxClip1
		StartPrepSDKCall(SDKCall_Entity);
		PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CTFWeaponBase::GetMaxClip1()");
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		g_SDKGetMaxClip1 = EndPrepSDKCall();

		if (g_SDKGetMaxClip1 == null)
		{
			SetFailState("Failed to create SDKCall for GetMaxClip1");
		}

		StartPrepSDKCall(SDKCall_Entity);
		PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CTFWeaponBase::GetAfterburnRateOnHit()");
		PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
		g_SDKGetAfterburnRateOnHit = EndPrepSDKCall();

		if (g_SDKGetAfterburnRateOnHit == null)
		{
			SetFailState("Failed to create SDKCall for GetAfterburnRateOnHit");
		}

		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CTFPlayer::TeamFortress_SetSpeed()");
		g_SDKTeamFortressSetSpeed = EndPrepSDKCall();

		if (g_SDKTeamFortressSetSpeed == null)
		{
			SetFailState("Failed to create SDKCall for TeamFortress_SetSpeed");
		}

		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CBasePlayer::SetFOV");
		PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
		g_SDKSetFOV = EndPrepSDKCall();

		if (g_SDKSetFOV == null)
		{
			SetFailState("Failed to create SDKCall for CBasePlayer::SetFOV");
		}

		// Virtual dispatch preserves TF2's native ranged/melee crit algorithms.
		StartPrepSDKCall(SDKCall_Entity);
		PrepSDKCall_SetFromConf(overrideConf, SDKConf_Virtual, "CTFWeaponBase::CalcIsAttackCriticalHelper()");
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		g_SDKCalcIsAttackCriticalHelper = EndPrepSDKCall();

		if (g_SDKCalcIsAttackCriticalHelper == null)
		{
			SetFailState("Failed to create SDKCall for CalcIsAttackCriticalHelper");
		}

		dhook_CTFPlayer_CalculateMaxSpeed = DynamicDetour.FromConf(conf, "CTFPlayer::TeamFortress_CalculateMaxSpeed");
		dhook_CTFLunchBox_ApplyBiteEffects = DynamicDetour.FromConf(conf, "CTFLunchBox::ApplyBiteEffects");
		dhook_CTFPlayerShared_StunPlayer = DynamicDetour.FromConf(conf, "CTFPlayerShared::StunPlayer");
		dhook_IsFixedWeaponSpreadEnabled = DynamicDetour.FromConf(overrideConf, "IsFixedWeaponSpreadEnabled");
		dhook_CObjectCartDispenser_DispenseMetal = DynamicHook.FromConf(conf, "CObjectCartDispenser::DispenseMetal");
		dhook_CTFWeaponBase_CanFireCriticalShot = DynamicHook.FromConf(conf, "CTFWeaponBase::CanFireCriticalShot");
		dhook_CTFStunBall_ApplyBallImpactEffectOnVictim = DynamicHook.FromConf(conf, "CTFStunBall::ApplyBallImpactEffectOnVictim");

		if (dhook_CTFPlayer_CalculateMaxSpeed == null) SetFailState("Failed to create dhook_CTFPlayer_CalculateMaxSpeed");
		if (dhook_CTFLunchBox_ApplyBiteEffects == null) SetFailState("Failed to create dhook_CTFLunchBox_ApplyBiteEffects");
		if (dhook_CTFPlayerShared_StunPlayer == null) SetFailState("Failed to create dhook_CTFPlayerShared_StunPlayer");
		if (dhook_IsFixedWeaponSpreadEnabled == null) SetFailState("Failed to create dhook_IsFixedWeaponSpreadEnabled");
		if (dhook_CObjectCartDispenser_DispenseMetal == null) SetFailState("Failed to create dhook_CObjectCartDispenser_DispenseMetal");
		if (dhook_CTFWeaponBase_CanFireCriticalShot == null) SetFailState("Failed to create dhook_CTFWeaponBase_CanFireCriticalShot");
		if (dhook_CTFStunBall_ApplyBallImpactEffectOnVictim == null) SetFailState("Failed to create dhook_CTFStunBall_ApplyBallImpactEffectOnVictim");

		dhook_CTFPlayer_CalculateMaxSpeed.Enable(Hook_Post, CalculateMaxSpeed);
		Escampette_RecalculateAllSpeeds();
		dhook_CTFLunchBox_ApplyBiteEffects.Enable(Hook_Pre, ApplyBiteEffects_Pre);
		dhook_CTFLunchBox_ApplyBiteEffects.Enable(Hook_Post, ApplyBiteEffects_Post);
		dhook_CTFPlayerShared_StunPlayer.Enable(Hook_Pre, SandmanPreJI_StunPlayer_Pre);
		dhook_IsFixedWeaponSpreadEnabled.Enable(Hook_Pre, IsFixedWeaponSpreadEnabled_Pre);
		WeaponReverts_HookExistingCriticalShotWeapons();

		// Create the patches
		patch_RevertCozyCamper_FlinchNerf = MemoryPatch.CreateFromConf(conf, "CTFPlayer::ApplyPunchImpulseX_FakeFullyChargedCondition");
		patch_AllowRandomCritOverride = MemoryPatch.CreateFromConf(overrideConf, "CTFWeaponBaseMelee::CalcIsAttackCriticalHelper_AllowOverride");
		patch_Wrangler_CustomShieldRepair = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldRepair");
		patch_Wrangler_CustomShieldShellRefill = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldShellRefill");
		patch_Wrangler_CustomShieldRocketRefill = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldRocketRefill");
		patch_Wrangler_CustomShieldDamageTaken = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnTakeDamage_CustomShieldDamageTaken");
		patch_Wrangler_RescueRanger_CustomShieldRepair = MemoryPatch.CreateFromConf(conf, "CTFProjectile_Arrow::BuildingHealingArrow_CustomShieldRepair");

		if (!ValidateAndNullCheck(patch_RevertCozyCamper_FlinchNerf)) SetFailState("Failed to create patch_RevertCozyCamper_FlinchNerf");
		if (!ValidateAndNullCheck(patch_AllowRandomCritOverride)) SetFailState("Failed to create patch_AllowRandomCritOverride");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldRepair)) SetFailState("Failed to create patch_Wrangler_CustomShieldRepair");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldShellRefill)) SetFailState("Failed to create patch_Wrangler_CustomShieldShellRefill");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldRocketRefill)) SetFailState("Failed to create patch_Wrangler_CustomShieldRocketRefill");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldDamageTaken)) SetFailState("Failed to create patch_Wrangler_CustomShieldDamageTaken");
		if (!ValidateAndNullCheck(patch_Wrangler_RescueRanger_CustomShieldRepair)) SetFailState("Failed to create patch_Wrangler_RescueRanger_CustomShieldRepair");

		patch_RevertCozyCamper_FlinchNerf.Enable();
		patch_AllowRandomCritOverride.Enable();
		patch_Wrangler_CustomShieldRepair.Enable();
		patch_Wrangler_CustomShieldShellRefill.Enable();
		patch_Wrangler_CustomShieldRocketRefill.Enable();
		patch_Wrangler_CustomShieldDamageTaken.Enable();
		patch_Wrangler_RescueRanger_CustomShieldRepair.Enable();

		StoreToAddress(patch_Wrangler_CustomShieldRepair.Address + view_as<Address>(0x04), view_as<int>(GetAddressOfCell(g_flWranglerCustomShieldValue)), NumberType_Int32);
		StoreToAddress(patch_Wrangler_CustomShieldShellRefill.Address + view_as<Address>(0x04), view_as<int>(GetAddressOfCell(g_flWranglerCustomShieldValue)), NumberType_Int32);
		StoreToAddress(patch_Wrangler_CustomShieldRocketRefill.Address + view_as<Address>(0x04), view_as<int>(GetAddressOfCell(g_flWranglerCustomShieldValue)), NumberType_Int32);
		StoreToAddress(patch_Wrangler_CustomShieldDamageTaken.Address + view_as<Address>(0x04), view_as<int>(GetAddressOfCell(g_flWranglerCustomShieldValue)), NumberType_Int32);
		StoreToAddress(patch_Wrangler_RescueRanger_CustomShieldRepair.Address + view_as<Address>(0x04), view_as<int>(GetAddressOfCell(g_flWranglerCustomShieldValue)), NumberType_Int32);
		delete overrideConf;
		delete conf;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
			{
				Harvester_SyncHealTimer(i);
			}
		}
	}
}

public void PreCacheWeaponSounds() {
	PrecacheSound(SOUND_ARROW_HEAL, true);
	PrecacheSound(SOUND_NEON_SIGN, true);
	PrecacheSound(SOUND_FLAME_OUT, true);
	PrecacheSound(SOUND_AMBASSADOR_CRIT_RECEIVED, true);
	PrecacheSound(SOUND_AMBASSADOR_CRIT_HIT, true);
	PrecacheSound(FLS_EXPLODE_SOUND, true);
	PrecacheSound(FLS_NOTIFY_SOUND, true);
	PrecacheSound(FLS_NOTIFY_2, true);
	PrecacheSound(BURP_SOUND, true);
	PrecacheSound(ATTR_SECONDARY_REFILL_SOUND, true);
}

static void Ambassador102_CacheCritParticle()
{
	g_iAmbassadorCritParticle = INVALID_STRING_INDEX;

	int table = FindStringTable("ParticleEffectNames");
	if (table == INVALID_STRING_TABLE)
		return;

	char particle[128];
	int count = GetStringTableNumStrings(table);
	for (int i = 0; i < count; i++)
	{
		ReadStringTable(table, i, particle, sizeof(particle));
		if (StrEqual(particle, "crit_text", false))
		{
			g_iAmbassadorCritParticle = i;
			return;
		}
	}
}

public void OnMapStart() {
	FullPelletIgnite_ClearAll();
	LoadWeaponRevertsConfig();
	Escampette_RecalculateAllSpeeds();
	PreCacheWeaponSounds();
	Ambassador102_CacheCritParticle();
}

public void OnMapEnd()
{
	FullPelletIgnite_ClearAll();
	for (int client = 1; client <= MaxClients; client++)
	{
		HuntingRevolver_ResetClient(client);
		Harvester_ClearState(client);
		ShockCharge_StopTimer(client);
	}
}

public void OnPluginEnd()
{
	g_bPluginEnding = true;
	Escampette_RecalculateAllSpeeds();
	WeaponRevertsEvents_Shutdown();
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClientArrays(i);
	}
	DestroyPatch(patch_RevertCozyCamper_FlinchNerf); patch_RevertCozyCamper_FlinchNerf = null;
	DestroyPatch(patch_AllowRandomCritOverride); patch_AllowRandomCritOverride = null;
	DestroyPatch(patch_Wrangler_CustomShieldRepair); patch_Wrangler_CustomShieldRepair = null;
	DestroyPatch(patch_Wrangler_CustomShieldShellRefill); patch_Wrangler_CustomShieldShellRefill = null;
	DestroyPatch(patch_Wrangler_CustomShieldRocketRefill); patch_Wrangler_CustomShieldRocketRefill = null;
	DestroyPatch(patch_Wrangler_CustomShieldDamageTaken); patch_Wrangler_CustomShieldDamageTaken = null;
	DestroyPatch(patch_Wrangler_RescueRanger_CustomShieldRepair); patch_Wrangler_RescueRanger_CustomShieldRepair = null;
	WeaponReverts_DeleteConfigs();
}

// I added functions like these while I was worried about memory safety... I assume they're redundant

public void OnClientPutInServer(int client)
{
	if (IsClientInGame(client) && WeaponReverts_IsEnabled())
	{
		SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
		SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
		SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
		SDKHook(client, SDKHook_OnTakeDamageAlivePost, WeaponReverts_OnTakeDamageAlivePost);
		SDKHook(client, SDKHook_PostThinkPost, HuntingRevolver_OnPostThinkPost);
		ResetClientArrays(client);
	}
}

// Potentially important for memory safety
public void OnClientDisconnect(int client)
{
	ResetClientArrays(client);
}

public void OnEntityCreated(int entity, const char[] class) {
	if (!WeaponReverts_IsEntityIndex(entity) || !WeaponReverts_IsEnabled()) return;

	if (entity > 0 && entity < MAX_TRACKED_ENTITIES)
	{
		g_flProjectileSpawnTime[entity] = 0.0;
		g_bProjectileSandmanPreJI[entity] = false;
	}

	if (entity > 0 && entity < MAX_TRACKED_ENTITIES && StrContains(class, "tf_projectile_") == 0)
	{
		g_flProjectileSpawnTime[entity] = GetGameTime();
	}

	if (StrEqual(class, "tf_projectile_stun_ball"))
	{
		SDKHook(entity, SDKHook_SpawnPost, SandmanPreJI_OnStunBallSpawnPost);
		if (dhook_CTFStunBall_ApplyBallImpactEffectOnVictim != null)
		{
			dhook_CTFStunBall_ApplyBallImpactEffectOnVictim.HookEntity(Hook_Pre, entity, SandmanPreJI_ApplyBallImpactEffectOnVictim_Pre);
		}
	}

	if (StrEqual(class, "tf_projectile_energy_ring"))
	{
		SDKHook(entity, SDKHook_SpawnPost, OnEnergyRingSpawnPost);
		SDKHook(entity, SDKHook_Touch, OnEnergyRingTouch);
	}

	if (StrEqual(class, "mapobj_cart_dispenser") && dhook_CObjectCartDispenser_DispenseMetal != null)
	{
		dhook_CObjectCartDispenser_DispenseMetal.HookEntity(Hook_Pre, entity, CartDispenseMetal);
	}

	WeaponReverts_HookCriticalShotEntity(entity, class);
}

public void OnEntityDestroyed(int entity)
{
	if (entity > 0 && entity < MAX_TRACKED_ENTITIES)
	{
		g_flProjectileSpawnTime[entity] = 0.0;
		g_bProjectileSandmanPreJI[entity] = false;
	}
}

public void OnGameFrame()
{
	static int frame;

	frame++;

	// run every frame
	if (frame % 1 == 0)
	{
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsClientInGame(client) && IsPlayerAlive(client))
			{
				VitaSaw_CacheCharge(client);

				if (TF2_IsPlayerInCondition(client, TFCond_Bonked)) {
					tf2_players[client].bonkFrame = GetGameTickCount();
				}
			}
		}
	}
}

static bool Accuracy_IsValidClient(int client)
{
	return WR_IsClientInGame(client);
}

static bool IsValidWeaponEntity(int weapon)
{
	return WR_IsValidWeaponEntity(weapon);
}

static bool IsAmbassadorHeadshotWeapon(int weapon)
{
	if (!IsValidWeaponEntity(weapon))
		return false;

	int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
	return (defIndex == AMBASSADOR_ITEMDEF || defIndex == FESTIVE_AMBASSADOR_ITEMDEF);
}

static bool Ambassador102_IsEnabledWeapon(int weapon)
{
	return IsAmbassadorHeadshotWeapon(weapon) && TF2CustAttr_GetInt(weapon, ATTR_AMBASSADOR_102, 0) != 0;
}

static bool WeaponReverts_IsCriticalShotHookClass(const char[] classname)
{
	return StrEqual(classname, "tf_weapon_pistol") || StrEqual(classname, "tf_weapon_revolver");
}

static void WeaponReverts_HookCriticalShotEntity(int weapon, const char[] classname)
{
	if (dhook_CTFWeaponBase_CanFireCriticalShot == null
		|| !WeaponReverts_IsEntityIndex(weapon)
		|| !IsValidEntity(weapon)
		|| !WeaponReverts_IsCriticalShotHookClass(classname))
	{
		return;
	}

	dhook_CTFWeaponBase_CanFireCriticalShot.HookEntity(Hook_Post, weapon, CanFireCriticalShot_Post);
}

static void WeaponReverts_HookExistingCriticalShotWeapons()
{
	char classname[64];
	int maxEntities = GetMaxEntities();
	for (int weapon = MaxClients + 1; weapon < maxEntities; weapon++)
	{
		if (!IsValidEntity(weapon))
			continue;

		GetEntityClassname(weapon, classname, sizeof(classname));
		WeaponReverts_HookCriticalShotEntity(weapon, classname);
	}
}

static Action Ambassador102_OnHeadshotDamage(int victim, int attacker, int weapon, float &damage, int damagetype, int damagecustom)
{
	if (damagecustom != TF_CUSTOM_HEADSHOT || !Ambassador102_IsEnabledWeapon(weapon))
		return Plugin_Continue;

	if (!WR_IsClientInGame(victim) || !WR_IsClientInGame(attacker))
		return Plugin_Continue;

	if ((damagetype & DMG_ACID) != DMG_ACID)
	{
		EmitSoundToClient(victim, SOUND_AMBASSADOR_CRIT_RECEIVED, SOUND_FROM_PLAYER, SNDCHAN_AUTO, 95);
		EmitSoundToClient(attacker, SOUND_AMBASSADOR_CRIT_HIT, SOUND_FROM_PLAYER, SNDCHAN_AUTO, 85);

		if (g_iAmbassadorCritParticle != INVALID_STRING_INDEX)
		{
			float origin[3];
			GetEntPropVector(victim, Prop_Send, "m_vecOrigin", origin);

			TE_Start("TFParticleEffect");
			TE_WriteFloat("m_vecOrigin[0]", origin[0]);
			TE_WriteFloat("m_vecOrigin[1]", origin[1]);
			TE_WriteFloat("m_vecOrigin[2]", origin[2] + 56.0);
			TE_WriteNum("m_iParticleSystemIndex", g_iAmbassadorCritParticle);
			TE_SendToClient(attacker);
		}
	}

	damage = 102.0;
	return Plugin_Changed;
}

static void TryAwardAmbassadorHeadshotKill(Event event, int attacker, int victim)
{
	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
		return;
	if (IsFakeClient(attacker) || IsFakeClient(victim))
		return;
	if (GetClientTeam(attacker) <= 1 || GetClientTeam(attacker) == GetClientTeam(victim))
		return;
	if (event.GetInt("customkill") != TF_CUSTOM_HEADSHOT)
		return;
	if (event.GetInt("death_flags") & TF_DEATHFLAG_DEADRINGER)
		return;

	int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
	if (!IsAmbassadorHeadshotWeapon(weapon))
		return;

	FireAmbassadorHeadshotKill(attacker, victim);
}

static void TryAwardSandmanCleaverCombo(int attacker, int victim)
{
	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
		return;
	if (IsFakeClient(attacker) || IsFakeClient(victim))
		return;
	if (GetClientTeam(attacker) <= 1 || GetClientTeam(attacker) == GetClientTeam(victim))
		return;

	FireSandmanCleaverCombo(attacker, victim);
}

static void VitaSaw_ClearStoredCharge(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	tf2_players[client].lastUber = 0.0;
	tf2_players[client].lastUberMedigunDefIndex = 0;
}

static bool VitaSaw_IsEquipped(int client)
{
	int melee = GetPlayerWeaponSlot(client, TFWeaponSlot_Melee);
	return IsValidWeaponEntity(melee) && TF2CustAttr_GetInt(melee, ATTR_VITA_SAW_REVERT, 0) != 0;
}

static bool VitaSaw_GetMedigun(int client, int &medigun)
{
	medigun = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);
	return IsValidWeaponEntity(medigun);
}

static void VitaSaw_CacheCharge(int client, bool requireAlive = true)
{
	if (!Accuracy_IsValidClient(client) || TF2_GetPlayerClass(client) != TFClass_Medic)
	{
		VitaSaw_ClearStoredCharge(client);
		return;
	}

	if (requireAlive && !IsPlayerAlive(client))
		return;

	int medigun;
	if (!VitaSaw_IsEquipped(client) || !VitaSaw_GetMedigun(client, medigun))
	{
		if (requireAlive)
		{
			VitaSaw_ClearStoredCharge(client);
		}
		return;
	}

	tf2_players[client].lastUber = GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");
	tf2_players[client].lastUberMedigunDefIndex = GetEntProp(medigun, Prop_Send, "m_iItemDefinitionIndex");
}

static void VitaSaw_ApplyStoredCharge(int client)
{
	if (!Accuracy_IsValidClient(client) || !IsPlayerAlive(client) || TF2_GetPlayerClass(client) != TFClass_Medic)
		return;

	int medigun;
	if (!VitaSaw_IsEquipped(client) || !VitaSaw_GetMedigun(client, medigun))
		return;

	int storedDefIndex = tf2_players[client].lastUberMedigunDefIndex;
	if (storedDefIndex <= 0)
		return;

	if (GetEntProp(medigun, Prop_Send, "m_iItemDefinitionIndex") != storedDefIndex)
	{
		VitaSaw_ClearStoredCharge(client);
		return;
	}

	float preservedCharge = tf2_players[client].lastUber;
	if (preservedCharge > VITASAW_MAX_PRESERVED_CHARGE)
	{
		preservedCharge = VITASAW_MAX_PRESERVED_CHARGE;
	}

	float currentCharge = GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");
	if (preservedCharge > currentCharge)
	{
		SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", preservedCharge);
	}

	VitaSaw_ClearStoredCharge(client);
}

static bool Accuracy_IsValidFlameShotgun(int weapon)
{
	return (IsValidWeaponEntity(weapon) && TF2CustAttr_GetInt(weapon, "flame shotgun attributes") != 0);
}

static Action OnBuildingDamaged(int entity, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!IsValidEntity(entity) || attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
		return Plugin_Continue;

	int weapon = GetEntPropEnt(attacker, Prop_Data, "m_hActiveWeapon");
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Continue;

	int drainAttr = TF2CustAttr_GetInt(weapon, "drain ammo on hit building");
	if (drainAttr <= 0)
		return Plugin_Continue;

	char classname[64];
	GetEntityClassname(entity, classname, sizeof(classname));
	bool isDispenser = StrEqual(classname, "obj_dispenser");
	bool isSentry = StrEqual(classname, "obj_sentrygun");

	if (!isDispenser && !isSentry)
		return Plugin_Continue;

	int drained = 0;

	if (isDispenser)
	{
		int currentMetal = GetEntProp(entity, Prop_Send, "m_iAmmoMetal");
		int newMetal = currentMetal - drainAttr;
		if (newMetal < 0)
			newMetal = 0;
		SetEntProp(entity, Prop_Send, "m_iAmmoMetal", newMetal);
		drained = currentMetal - newMetal;
	}
	else
	{
		int currentShells = GetEntProp(entity, Prop_Send, "m_iAmmoShells");
		int newShells = currentShells - drainAttr;
		if (newShells < 0)
			newShells = 0;
		SetEntProp(entity, Prop_Send, "m_iAmmoShells", newShells);
		drained = currentShells - newShells;
	}

	if (drained > 0 && TF2_GetPlayerClass(attacker) == TFClass_Engineer && g_iMetalOffset != -1)
	{
		int attackerMetal = TF_GetMetalAmount(attacker);
		int credit = drained;
		if (attackerMetal + credit > 200)
			credit = 200 - attackerMetal;
		if (credit > 0)
		{
			TF_SetMetalAmount(attacker, attackerMetal + credit);
		}
	}

	return Plugin_Continue;
}

public void Event_PlayerBuiltObject(Event event, const char[] name, bool dontBroadcast)
{
	int ent = event.GetInt("index");
	HookBuildingEntity(ent);
}

static void FlameShotgun_Explode(int attacker, int victim, float position[3], float damage, float radius)
{
	if (!Accuracy_IsValidClient(attacker) || g_bAccuracyExploding[attacker])
		return;

	g_bAccuracyExploding[attacker] = true;

	int bomb = CreateEntityByName("tf_generic_bomb");
	if (bomb == -1)
	{
		g_bAccuracyExploding[attacker] = false;
		return;
	}

	DispatchKeyValueVector(bomb, "origin", position);
	DispatchKeyValueFloat(bomb, "damage", damage);
	DispatchKeyValueFloat(bomb, "radius", radius);
	DispatchKeyValue(bomb, "health", "1");
	DispatchSpawn(bomb);

	EmitAmbientSound(FLS_EXPLODE_SOUND, position, victim, SNDLEVEL_NORMAL);

	int particle = CreateEntityByName("info_particle_system");
	if (particle != -1)
	{
		float particlePos[3];
		particlePos = position;
		particlePos[2] += Accuracy_GetClassSubtractionValue(attacker);
		TeleportEntity(particle, particlePos, NULL_VECTOR, NULL_VECTOR);
		DispatchKeyValue(particle, "effect_name", "mvm_cash_explosion");
		DispatchKeyValue(particle, "start_active", "0");
		DispatchSpawn(particle);
		ActivateEntity(particle);
		AcceptEntityInput(particle, "Start");
		CreateTimer(1.0, Accuracy_Timer_RemoveEntity, EntIndexToEntRef(particle), TIMER_FLAG_NO_MAPCHANGE);
	}

	int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
	SDKHooks_TakeDamage(bomb, attacker, attacker, 9001.0, DMG_BULLET, weapon);

	int targetTeam = GetClientTeam(victim);
	if (targetTeam > 1)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!Accuracy_IsValidClient(i) || !IsPlayerAlive(i))
				continue;
			if (GetClientTeam(i) != targetTeam)
				continue;

			float clientPos[3];
			GetClientAbsOrigin(i, clientPos);
			if (GetVectorDistance(position, clientPos) <= radius)
			{
				TF2_IgnitePlayer(i, attacker, 2.0);
			}
		}
	}

	g_bAccuracyExploding[attacker] = false;
}

public Action Accuracy_Timer_RemoveEntity(Handle timer, int ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity != INVALID_ENT_REFERENCE)
	{
		RemoveEntity(entity);
	}
	return Plugin_Stop;
}

static void Accuracy_OnFlameShotgunStack(int attacker, int victim, int weapon = -1)
{
	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
		return;
	if (g_bAccuracyExploding[attacker])
		return;

	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
	}
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		ScatterPellets_Debug("meatshot ignored: no valid active weapon");
		return;
	}
	if (!Accuracy_IsValidFlameShotgun(weapon))
	{
		ScatterPellets_Debug("meatshot ignored: weapon lacks flame shotgun attributes");
		return;
	}

	float eye[3];
	GetClientEyePosition(attacker, eye);

	float now = GetGameTime();
	if (tf2_players[victim].accuracyStreakExpiresAt <= now)
	{
		tf2_players[victim].accuracyStreak = 0;
	}

	tf2_players[victim].accuracyStreak++;
	tf2_players[victim].accuracyStreakExpiresAt = now + FLS_STREAK_WINDOW;
	if (tf2_players[victim].accuracyStreak >= FLS_STREAK_TARGET)
	{
		float boomPos[3];
		GetClientAbsOrigin(victim, boomPos);
		boomPos[2] -= Accuracy_GetClassSubtractionValue(victim);

		if (IsPlayerAlive(victim))
		{
			TF2_IgnitePlayer(victim, attacker, 4.0);
		}
		FlameShotgun_Explode(attacker, victim, boomPos, FLS_EXPLODE_DAMAGE, FLS_EXPLODE_RADIUS);
		EmitAmbientSound(FLS_NOTIFY_2, eye, attacker, SNDLEVEL_NORMAL);

		int maxClip = GetWeaponMaxClip(weapon);
		if (maxClip > 0)
		{
			int clip = GetClip(weapon);
			if (clip >= 0 && clip < maxClip)
			{
				SetClip_Weapon(weapon, maxClip);
			}
		}

		tf2_players[victim].accuracyStreak = 0;
		tf2_players[victim].accuracyStreakExpiresAt = 0.0;
	}
	else
	{
		EmitAmbientSound(FLS_NOTIFY_SOUND, eye, attacker, SNDLEVEL_NORMAL);
	}
}

static void ScatterPellets_Debug(const char[] format, any ...)
{
	if (g_hScattergunPelletsDebug == null || !GetConVarBool(g_hScattergunPelletsDebug))
		return;

	char message[256];
	VFormat(message, sizeof(message), format, 2);
	LogMessage("[scattergun_pellets] %s", message);
}

public Action Command_ScatterPelletsStatus(int client, int args)
{
	ReplyToCommand(client, "[WeaponReverts] scattergun_pellets extension: %s", LibraryExists("scattergun_pellets") ? "available" : "unavailable");

	if (Accuracy_IsValidClient(client))
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		char classname[64];
		classname[0] = '\0';
		if (weapon > MaxClients && IsValidEntity(weapon))
		{
			GetEntityClassname(weapon, classname, sizeof(classname));
		}
		ReplyToCommand(client, "[WeaponReverts] active weapon: ent=%d class=%s", weapon, classname);
	}

	return Plugin_Handled;
}

public void TF2Shotgun_OnPelletShot(int attacker, int victim, int pellets, int total, bool kill)
{
	ScatterPellets_Debug("pellet shot: attacker=%d victim=%d pellets=%d total=%d kill=%d", attacker, victim, pellets, total, kill ? 1 : 0);

	if (!WeaponReverts_IsEnabled())
	{
		ScatterPellets_Debug("ignored: reverts_enabled is 0");
		return;
	}

	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
	{
		ScatterPellets_Debug("ignored: invalid attacker/victim");
		return;
	}
	if (GetClientTeam(attacker) <= 1
		|| GetClientTeam(victim) <= 1
		|| GetClientTeam(attacker) == GetClientTeam(victim))
	{
		ScatterPellets_Debug("ignored: friendly/noncombat target");
		return;
	}
	if (g_bAccuracyExploding[attacker])
	{
		ScatterPellets_Debug("ignored: accuracy explosion in progress");
		return;
	}

	if (total < 1)
		return;
			

	if (pellets > FLAME_SHOTGUN_FULL_PELLET_THRESHOLD) // 7/10, this is only for the flame shotgun, virtually 7/9
			Accuracy_OnFlameShotgunStack(attacker, victim);

	if (pellets < total)
	{
		ScatterPellets_Debug("ignored: not a full pellet shot");
		return;
	}

	if (g_hMeatshotDebug.BoolValue && !IsFakeClient(attacker))
	{
		PrintToChat(attacker, "[debug] You got a meatshot!");
	}

	if (!kill || IsFakeClient(attacker) || IsFakeClient(victim))
	{
		return;
	}

	FireMeatshotKill(attacker, victim);

}

static int Accuracy_GetClassSubtractionValue(int client)
{
	TFClassType cls = TF2_GetPlayerClass(client);
	switch (cls)
	{
		case TFClass_Scout:
			return 65;
		case TFClass_Soldier, TFClass_Pyro, TFClass_DemoMan, TFClass_Engineer:
			return 68;
		case TFClass_Heavy, TFClass_Medic, TFClass_Sniper, TFClass_Spy:
			return 75;
		default:
			return 0;
	}
}

public void Event_TF2RocketJump(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0) {
		if (tf2_players[client].jump_status == TF2_JUMP_ROCKET_START) {
			tf2_players[client].jump_status = TF2_JUMP_ROCKET;
		} else if (tf2_players[client].jump_status != TF2_JUMP_ROCKET) {
			tf2_players[client].jump_status = TF2_JUMP_ROCKET_START;
		}
	}
}

public void Event_TF2StickyJump(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0) {
		if (tf2_players[client].jump_status != TF2_JUMP_STICKY) {
			tf2_players[client].jump_status = TF2_JUMP_STICKY;
		}
	}
}

public void Event_TF2JumpLanded(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0)
	{
		tf2_players[client].jump_status = TF2_JUMP_NONE;
	}
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int userId = event.GetInt("userid");
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;

	Sproke_ClearEffect(client, false, true);
	HuntingRevolver_ResetClient(client);
	Harvester_ClearState(client);
	ShockCharge_StopTimer(client);
	tf2_players[client].shockCharge = 30;
	tf2_players[client].accuracyStreak = 0;
	tf2_players[client].accuracyStreakExpiresAt = 0.0;
	SecondaryDamageRefill_Reset(client);

	VitaSaw_CacheCharge(client, false);

	int attackerId = event.GetInt("attacker");
	int attacker = GetClientOfUserId(attackerId);
	bool worldDeath = IsWorldInflictedDeath(event);
	int environmentalAttacker = GetClientOfUserId(g_iEnvironmentalKillAttackerUserId[client]);
	if (worldDeath
		&& environmentalAttacker > 0
		&& IsClientInGame(environmentalAttacker)
		&& !IsFakeClient(environmentalAttacker)
		&& GetClientTeam(environmentalAttacker) != GetClientTeam(client)
		&& GetGameTime() - g_fEnvironmentalKillTime[client] <= ENVIRONMENTAL_KILL_CREDIT_WINDOW)
	{
		FireEnvironmentalKill(environmentalAttacker, client);
	}
	g_iEnvironmentalKillAttackerUserId[client] = 0;
	g_fEnvironmentalKillTime[client] = 0.0;

	if (attacker == 0)
	{
		return Plugin_Continue;
	}

	TryAwardAmbassadorHeadshotKill(event, attacker, client);

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		int activeWeapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
		if (!(activeWeapon > MaxClients && IsValidEntity(activeWeapon)))
			return Plugin_Continue;

		ReloadOnKill_OnKill(activeWeapon);

		int restoreAmount = TF2CustAttr_GetInt(activeWeapon, ATTR_RESTORE_PRIMARY_SHOT_KILL, 0);
		if (restoreAmount > 0)
		{
			int primary = GetPlayerWeaponSlot(attacker, 0);
			if (primary > MaxClients && IsValidEntity(primary))
			{
				int maxClip = GetWeaponMaxClip(primary);
				int clip = GetClip(primary);
				if (maxClip > 0 && clip >= 0 && clip < maxClip)
				{
					int missing = maxClip - clip;
					int restored = (restoreAmount < missing) ? restoreAmount : missing;
					SetClip_Weapon(primary, clip + restored);
				}
			}
		}
	}

	if (tf2_players[attacker].scytheWeapon != 0
		&& GetEntProp(attacker, Prop_Send, "m_iRevengeCrits") <= 0
		&& TF2_IsPlayerInCondition(client, TFCond_OnFire))
	{
		Harvester_AddHealCount(attacker, ATTR_HARVESTER_HEALING_COUNT);
	}

	if (tf2_players[client].scytheWeapon != 0 && TF2_IsPlayerInCondition(attacker, TFCond_OnFire))
	{
		if (TF2_IsPlayerInCondition(attacker, TFCond_OnFire))
		{
			TF2_RemoveCondition(attacker, TFCond_OnFire);
			int targets[2];
			targets[0] = client;
			targets[1] = attacker;
			for (int i = 0; i < 2; i++)
			{
				EmitSoundToClient(
					targets[i],
					SOUND_FLAME_OUT,
					SOUND_FROM_PLAYER,
					SNDCHAN_AUTO,
					SNDLEVEL_NORMAL,
					SND_NOFLAGS,
					0.4,
					SNDPITCH_NORMAL
				);
			}
		}
	}
	return Plugin_Continue;
}

static bool Escampette_IsEquipped(int client)
{
	if (!WeaponReverts_IsEnabled()
		|| !WR_IsClientInGame(client)
		|| !IsPlayerAlive(client)
		|| TF2_GetPlayerClass(client) != TFClass_Spy)
	{
		return false;
	}

	int watch = GetPlayerWeaponSlot(client, ESCAMPETTE_WATCH_SLOT);
	return watch > MaxClients
		&& IsValidEntity(watch)
		&& TF2CustAttr_GetInt(watch, ATTR_ESCAMPETTE, 0) != 0;
}

static bool Escampette_HasSpeedBonus(int client)
{
	return Escampette_IsEquipped(client)
		&& TF2_IsPlayerInCondition(client, TFCond_Cloaked);
}

static void Escampette_RecalculateSpeed(int client)
{
	if (g_SDKTeamFortressSetSpeed != null
		&& WR_IsClientInGame(client)
		&& IsPlayerAlive(client))
	{
		SDKCall(g_SDKTeamFortressSetSpeed, client);
	}
}

static void Escampette_RecalculateAllSpeeds()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		Escampette_RecalculateSpeed(client);
	}
}

static void Escampette_FrameRecalculateSpeed(any userId)
{
	Escampette_RecalculateSpeed(GetClientOfUserId(userId));
}

static void Escampette_QueueSpeedRecalculation(int client)
{
	if (WR_IsValidPlayerIndex(client))
	{
		RequestFrame(Escampette_FrameRecalculateSpeed, GetClientUserId(client));
	}
}

public void WeaponReverts_OnEnabledChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Escampette_RecalculateAllSpeeds();
}

static void Escampette_OnDamageTaken(int victim, int attacker, float damage, const float damagePosition[3])
{
	// Preserve the prior behavior: positive damage from any non-world source counts.
	if (damage <= 0.0 || attacker <= 0 || !Escampette_HasSpeedBonus(victim))
	{
		return;
	}

	float cloakMeter = GetEntPropFloat(victim, Prop_Send, "m_flCloakMeter") - 10.0;
	if (cloakMeter < 0.0)
	{
		cloakMeter = 0.0;
	}

	SetEntPropFloat(victim, Prop_Send, "m_flCloakMeter", cloakMeter);
	EmitAmbientSound(SOUND_POMSON_DRAIN, damagePosition, victim, SNDLEVEL_NORMAL);
}

public Action Event_Resupply(Event event, const char[] name, bool dontBroadcast)
{
	int userId = event.GetInt("userid");
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;
	Escampette_QueueSpeedRecalculation(client);
	HuntingRevolver_ResetClient(client);
	if (!Harvester_IsEligibleClient(client))
	{
		Harvester_ClearState(client);
	}

	VitaSaw_ApplyStoredCharge(client);
	RequestFrame(Harvester_FrameSyncHealTimer, GetClientUserId(client));

	if (tf2_players[client].shockCharge != 30)
	{
		tf2_players[client].shockCharge = 29; // The 29 is for visual effect
		ShockCharge_StartTimer(client);
		return Plugin_Changed;
	}

	if (tf2_players[client].sprokeTimer != null)
	{
		Sproke_ClearEffect(client, false, true);
	}
	return Plugin_Continue;

}

public Action OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userId = event.GetInt("userid");
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;
	Escampette_QueueSpeedRecalculation(client);
	HuntingRevolver_ResetClient(client);
	if (!Harvester_IsEligibleClient(client))
	{
		Harvester_ClearState(client);
	}

	ScattergunKnockback_ResetClient(client);
	VitaSaw_ApplyStoredCharge(client);
	RequestFrame(Harvester_FrameSyncHealTimer, GetClientUserId(client));

	return Plugin_Continue;
}

public void Event_PlayerChangeClass(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0)
	{
		Escampette_QueueSpeedRecalculation(client);
		HuntingRevolver_ResetClient(client);
		Harvester_ClearState(client);
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0)
	{
		Escampette_QueueSpeedRecalculation(client);
		HuntingRevolver_ResetClient(client);
		Harvester_ClearState(client);
	}
}

#define FSOLID_USE_TRIGGER_BOUNDS 0x80
void OnEnergyRingSpawnPost(int entity) {
	// Pomson & Bison hitboxes
	float maxs[3] = { 2.0, 2.0, 10.0 };
	float mins[3] = { -2.0, -2.0, -10.0 };

	SetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
	SetEntPropVector(entity, Prop_Send, "m_vecMins", mins);

	SetEntProp(entity, Prop_Send, "m_usSolidFlags", (GetEntProp(entity, Prop_Send, "m_usSolidFlags") | FSOLID_USE_TRIGGER_BOUNDS));
	SetEntProp(entity, Prop_Send, "m_triggerBloat", 24);
}

Action OnEnergyRingTouch(int entity, int other) {
	// Pomson & Bison light up friendly Huntsman arrows
	if (other >= 1 && other <= MaxClients) {
		int weapon = GetEntPropEnt(other, Prop_Send, "m_hActiveWeapon");
		if (IsValidEntity(weapon)) {
			if (
				HasEntProp(weapon, Prop_Send, "m_bArrowAlight") &&
				GetEntProp(entity, Prop_Send, "m_iTeamNum") == GetEntProp(other, Prop_Send, "m_iTeamNum")
			) {
				SetEntProp(weapon, Prop_Send, "m_bArrowAlight", true);
			}
		}
	} else if (other > MaxClients) {
		char class[64];
		GetEntityClassname(other, class, sizeof(class));
		// Don't collide with projectiles
		if (StrContains(class, "tf_projectile_") == 0) {
			return Plugin_Handled;
		}
	}
	return Plugin_Continue;
}

public Action TF2_CalcIsAttackCritical(int client, int weapon, char[] weaponname, bool &result) {
	if (!IsClientInGame(client) || weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Continue;

	// The SDKCall re-enters this forward through SourceMod's crit hook.
	if (g_bCalculatingRandomCritOverride)
		return Plugin_Continue;

	float recoil = TF2CustAttr_GetFloat(weapon, ATTR_RECOIL_JUMPING, 0.0);
	if (recoil > 0.0)
	{
		float angles[3];
		float aimForward[3];
		float velocity[3];

		GetClientEyeAngles(client, angles);
		GetAngleVectors(angles, aimForward, NULL_VECTOR, NULL_VECTOR);
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);

		ScaleVector(aimForward, -recoil);
		AddVectors(velocity, aimForward, velocity);
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);

		if (!(GetEntityFlags(client) & FL_ONGROUND))
		{
			TF2_StunPlayer(client, 0.3, 1.0, TF_STUNFLAG_SLOWDOWN | TF_STUNFLAG_LIMITMOVEMENT);
		}
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_RANDOM_CRITS_OVERRIDE, 0) != 0)
	{
		g_bCalculatingRandomCritOverride = true;
		result = view_as<bool>(SDKCall(g_SDKCalcIsAttackCriticalHelper, weapon));
		g_bCalculatingRandomCritOverride = false;
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

public MRESReturn IsFixedWeaponSpreadEnabled_Pre(DHookReturn returnValue, DHookParam parameters)
{
	int weapon = parameters.Get(1);
	if (!IsValidWeaponEntity(weapon))
	{
		return MRES_Ignored;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_CIRCULAR_BULLET_SPREAD, 0) != 0
		|| TF2CustAttr_GetInt(weapon, ATTR_WIDE_HORIZONTAL_BULLET_SPREAD, 0) != 0)
	{
		returnValue.Value = true;
		return MRES_Supercede;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_RANDOM_SPREAD_OVERRIDE, 0) == 0)
	{
		return MRES_Ignored;
	}

	returnValue.Value = false;
	return MRES_Supercede;
}

public Action Timer_HealTimer(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client)
		|| tf2_players[client].harvesterHealTimer != timer)
	{
		return Plugin_Stop;
	}
	if (!WeaponReverts_IsEnabled())
	{
		tf2_players[client].harvesterHealTimer = null;
		return Plugin_Stop;
	}

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!IsPlayerAlive(client) || !Harvester_IsWeapon(activeWeapon))
	{
		tf2_players[client].harvesterHealTimer = null;
		return Plugin_Stop;
	}

	bool directHealBlocked = tf2_players[client].lastHarvesterDirectHealTime >= 0.0
		&& GetGameTime() - tf2_players[client].lastHarvesterDirectHealTime < HARVESTER_DIRECT_HEAL_BLOCK_TIME;
	if (!directHealBlocked
		&& tf2_players[client].healCount > 0
		&& GetClientHealth(client) < TF2_GetPlayerMaxHealth(client))
	{
		tf2_players[client].healCount--;
		AddPlayerHealth(client, ATTR_HARVESTER_HEALING, 1.0, false, true);
		ClientCommand(client, "playgamesound ui/item_metal_tiny_pickup.wav");
		Harvester_ShowHealHint(client);
	}

	return Plugin_Continue;
}

public Action Timer_ClearHarvesterHint(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client)
		|| tf2_players[client].harvesterHintTimer != timer)
	{
		return Plugin_Stop;
	}

	tf2_players[client].harvesterHintTimer = null;
	Harvester_ClearHealHint(client);
	return Plugin_Stop;
}

public Action Timer_ShockCharge(Handle timer, any userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client)
		|| tf2_players[client].shockChargeTimer != timer)
	{
		return Plugin_Stop;
	}
	if (!WeaponReverts_IsEnabled())
	{
		tf2_players[client].shockChargeTimer = null;
		return Plugin_Stop;
	}

	if (tf2_players[client].shockCharge >= 30)
	{
		tf2_players[client].shockChargeTimer = null;
		return Plugin_Stop;
	}

	tf2_players[client].shockCharge++;
	if (tf2_players[client].shockCharge % 2 == 0 || tf2_players[client].shockCharge == 1)
	{
		PrintHintText(client, "Shock Charge: %i%%%", (tf2_players[client].shockCharge * 100 / 30));
	}

	if (tf2_players[client].shockCharge >= 30)
	{
		tf2_players[client].shockChargeTimer = null;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

static bool TryApplyHolsterReload(int weapon)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon))
	{
		return false;
	}

	int maxClip = TF2CustAttr_GetInt(weapon, "holster reload");
	if (maxClip <= 0)
	{
		return false;
	}

	int clip = GetClip(weapon);
	if (clip < 0 || clip >= maxClip)
	{
		return false;
	}

	int reserve = GetAmmo_Weapon(weapon);
	if (reserve <= 0)
	{
		return false;
	}

	int missing = maxClip - clip;
	int toReload = (missing < reserve) ? missing : reserve;
	if (toReload <= 0)
	{
		return false;
	}

	SetClip_Weapon(weapon, clip + toReload);
	SetAmmo_Weapon(weapon, reserve - toReload);
	return true;
}

public Action OnWeaponSwitch(int client, int weapon)
{
	if (!WeaponReverts_IsEnabled())
	{
		return Plugin_Continue;
	}

	int previousWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon != previousWeapon)
	{
		if (tf2_players[client].huntingRevolverWeaponRef != INVALID_ENT_REFERENCE
			|| HuntingRevolver_IsWeapon(previousWeapon))
		{
			HuntingRevolver_ResetClient(client, previousWeapon);
		}

		if (HuntingRevolver_IsWeapon(weapon))
		{
			HuntingRevolver_RecognizeWeapon(client, weapon);
		}
	}
	if (weapon != previousWeapon)
	{
		if (Harvester_IsWeapon(weapon))
		{
			Harvester_StartHealTimer(client);
		}
		else if (Harvester_IsWeapon(previousWeapon))
		{
			Harvester_StopHealTimer(client);
		}
	}
	if (weapon != previousWeapon && GetEntProp(client, Prop_Send, "m_iRevengeCrits") > 0)
	{
		if (Harvester_IsWeapon(previousWeapon) && !Harvester_IsWeapon(weapon))
		{
			Harvester_SetCritBoost(client, false);
		}
		else if (Harvester_IsWeapon(weapon))
		{
			Harvester_SetCritBoost(client, true);
		}
	}
	TryApplyHolsterReload(previousWeapon);

	if (weapon != previousWeapon)
	{
		TryApplyHolsterReload(weapon);
	}

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(
	int client,
	int &buttons,
	int &impulse,
	float velocity[3],
	float angles[3],
	int &weapon,
	int &subtype,
	int &commandNumber,
	int &tickCount,
	int &randomSeed,
	int mouse[2])
{
	if (!WeaponReverts_IsEnabled() || !WR_IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return Plugin_Continue;
	}

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	bool trackedActiveWeapon = tf2_players[client].huntingRevolverWeaponRef != INVALID_ENT_REFERENCE
		&& tf2_players[client].huntingRevolverWeaponRef != 0
		&& EntRefToEntIndex(tf2_players[client].huntingRevolverWeaponRef) == activeWeapon;
	if (!trackedActiveWeapon && !HuntingRevolver_IsWeapon(activeWeapon))
	{
		if (tf2_players[client].huntingRevolverWeaponRef != INVALID_ENT_REFERENCE)
		{
			HuntingRevolver_ResetClient(client);
		}
		return Plugin_Continue;
	}

	if (!trackedActiveWeapon)
	{
		HuntingRevolver_RecognizeWeapon(client, activeWeapon);
	}

	bool attack2 = (buttons & IN_ATTACK2) != 0;
	bool jumping = GetEntProp(client, Prop_Send, "m_bJumping") != 0;
	if (attack2 && !tf2_players[client].huntingRevolverAttack2Held)
	{
		if (tf2_players[client].huntingRevolverZoomed)
		{
			HuntingRevolver_SetZoom(client, false);
		}
		else if (!jumping)
		{
			HuntingRevolver_SetZoom(client, true);
		}
	}
	tf2_players[client].huntingRevolverAttack2Held = attack2;

	bool commandChanged = false;
	if (attack2)
	{
		buttons &= ~IN_ATTACK2;
		commandChanged = true;
	}

	return commandChanged ? Plugin_Changed : Plugin_Continue;
}

public void HuntingRevolver_OnPostThinkPost(int client)
{
	if (!WeaponReverts_IsEnabled()
		|| !WR_IsClientInGame(client)
		|| !IsPlayerAlive(client)
		|| !tf2_players[client].huntingRevolverZoomed
		|| GetEntProp(client, Prop_Send, "m_bJumping") == 0)
	{
		return;
	}

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (HuntingRevolver_IsWeapon(weapon)
		&& EntRefToEntIndex(tf2_players[client].huntingRevolverWeaponRef) == weapon)
	{
		HuntingRevolver_SetZoom(client, false);
	}
}

static bool HuntingRevolver_IsWeapon(int weapon)
{
	if (!IsValidWeaponEntity(weapon))
	{
		return false;
	}

	char classname[64];
	GetEntityClassname(weapon, classname, sizeof(classname));
	return StrEqual(classname, "tf_weapon_revolver")
		&& TF2CustAttr_GetInt(weapon, ATTR_HUNTING_REVOLVER, 0) != 0;
}

static void HuntingRevolver_RecognizeWeapon(int client, int weapon)
{
	int weaponRef = EntIndexToEntRef(weapon);
	if (tf2_players[client].huntingRevolverWeaponRef == weaponRef)
	{
		return;
	}

	HuntingRevolver_ResetClient(client);
	tf2_players[client].huntingRevolverWeaponRef = weaponRef;
}

static void HuntingRevolver_RecalculateSpeed(int client)
{
	if (g_SDKTeamFortressSetSpeed == null || !WR_IsValidPlayerIndex(client) || !IsClientInGame(client))
	{
		return;
	}

	SDKCall(g_SDKTeamFortressSetSpeed, client);
}

static void HuntingRevolver_SetFOV(int client, int fov)
{
	if (g_SDKSetFOV == null || !WR_IsValidPlayerIndex(client) || !IsClientInGame(client))
	{
		return;
	}

	SDKCall(g_SDKSetFOV, client, client, fov, HUNTING_REVOLVER_ZOOM_TIME, 0);
}

static int HuntingRevolver_GetWeapon(int client, int knownWeapon = -1)
{
	int weapon = EntRefToEntIndex(tf2_players[client].huntingRevolverWeaponRef);
	if (IsValidWeaponEntity(weapon))
	{
		return weapon;
	}

	if (HuntingRevolver_IsWeapon(knownWeapon))
	{
		return knownWeapon;
	}

	if (IsClientInGame(client))
	{
		weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (HuntingRevolver_IsWeapon(weapon))
		{
			return weapon;
		}
	}

	return INVALID_ENT_REFERENCE;
}

static void HuntingRevolver_SetReloadLock(int client, bool enabled, int knownWeapon = -1)
{
	int weapon = HuntingRevolver_GetWeapon(client, knownWeapon);
	if (!IsValidWeaponEntity(weapon))
	{
		return;
	}

	if (enabled
		&& TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED_WHILE_ZOOMED, 0) != 0)
	{
		TF2Attrib_SetByName(weapon, ATTR_MAX_PRIMARY_CLIP_OVERRIDE, -1.0);
	}
	else
	{
		TF2Attrib_RemoveByName(weapon, ATTR_MAX_PRIMARY_CLIP_OVERRIDE);
	}
}

static void HuntingRevolver_SetZoom(int client, bool enabled)
{
	tf2_players[client].huntingRevolverZoomed = enabled;
	tf2_players[client].huntingRevolverZoomReadyTime = enabled
		? GetGameTime() + HUNTING_REVOLVER_ZOOM_TIME
		: 0.0;
	HuntingRevolver_SetFOV(client, enabled ? HUNTING_REVOLVER_FOV : 0);
	HuntingRevolver_SetReloadLock(client, enabled);
	HuntingRevolver_RecalculateSpeed(client);
}

static void HuntingRevolver_ResetClient(int client, int knownWeapon = -1)
{
	if (!WR_IsValidPlayerIndex(client))
	{
		return;
	}

	bool hasTrackedWeapon = tf2_players[client].huntingRevolverWeaponRef != INVALID_ENT_REFERENCE
		&& tf2_players[client].huntingRevolverWeaponRef != 0;
	bool customContext = hasTrackedWeapon
		|| tf2_players[client].huntingRevolverZoomed
		|| tf2_players[client].huntingRevolverAttack2Held
		|| HuntingRevolver_IsWeapon(knownWeapon);

	tf2_players[client].huntingRevolverZoomed = false;
	tf2_players[client].huntingRevolverZoomReadyTime = 0.0;
	HuntingRevolver_SetReloadLock(client, false, knownWeapon);
	if (customContext && IsClientInGame(client))
	{
		HuntingRevolver_SetFOV(client, 0);
		HuntingRevolver_RecalculateSpeed(client);
	}

	tf2_players[client].huntingRevolverAttack2Held = false;
	tf2_players[client].huntingRevolverWeaponRef = INVALID_ENT_REFERENCE;
}

static bool Harvester_IsEligibleClient(int client)
{
	return IsClientInGame(client) && TF2_GetPlayerClass(client) == TFClass_Pyro;
}

static void Harvester_ClearState(int client)
{
	if (!WR_IsValidPlayerIndex(client))
	{
		return;
	}

	Harvester_StopHealTimer(client);
	Harvester_StopHintTimer(client);
	Harvester_ClearRevengeCrit(client);
	tf2_players[client].scytheWeapon = 0;
	tf2_players[client].healCount = 0;
	tf2_players[client].lastHarvesterDirectHealTime = -1.0;
}

static bool Harvester_IsWeapon(int weapon)
{
	return IsValidWeaponEntity(weapon)
		&& TF2CustAttr_GetInt(weapon, "harvester attributes", 0) == 1;
}

static void Harvester_AddHealCount(int client, int amount)
{
	if (!Harvester_IsEligibleClient(client) || amount <= 0
		|| GetEntProp(client, Prop_Send, "m_iRevengeCrits") > 0)
	{
		return;
	}

	tf2_players[client].healCount += amount;
	if (tf2_players[client].healCount >= HARVESTER_HEAL_COUNT_MAX)
	{
		Harvester_SetRevengeCrit(client);
		tf2_players[client].healCount = 0;
	}
	Harvester_ShowHealHint(client);
}

static void Harvester_OnAfterburnDamage(int client)
{
	if (!Harvester_IsEligibleClient(client) || !IsPlayerAlive(client))
	{
		return;
	}

	tf2_players[client].scytheWeapon = CheckScythe(client);
	if (tf2_players[client].scytheWeapon == 0)
	{
		return;
	}

	Harvester_AddHealCount(client, ATTR_HARVESTER_AFTERBURN_HEALING_COUNT);
	if (tf2_players[client].scytheWeapon != 2)
	{
		return;
	}

	int healthBefore = GetClientHealth(client);
	AddPlayerHealth(client, 4, 1.0, false, true);
	if (GetClientHealth(client) > healthBefore)
	{
		tf2_players[client].lastHarvesterDirectHealTime = GetGameTime();
	}
}

static void Harvester_StartHealTimer(int client)
{
	if (!Harvester_IsEligibleClient(client) || !IsPlayerAlive(client) || !WeaponReverts_IsEnabled()
		|| tf2_players[client].harvesterHealTimer != null)
	{
		return;
	}

	tf2_players[client].harvesterHealTimer = CreateTimer(
		HARVESTER_HEAL_TIMER_INTERVAL,
		Timer_HealTimer,
		GetClientUserId(client),
		TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

static void Harvester_StopHealTimer(int client)
{
	if (!WR_IsValidPlayerIndex(client))
	{
		return;
	}

	if (tf2_players[client].harvesterHealTimer != null)
	{
		KillTimer(tf2_players[client].harvesterHealTimer);
		tf2_players[client].harvesterHealTimer = null;
	}
}

static void Harvester_ShowHealHint(int client)
{
	if (!Harvester_IsEligibleClient(client) || !WeaponReverts_IsEnabled())
	{
		return;
	}

	if (tf2_players[client].harvesterHintTimer != null)
	{
		KillTimer(tf2_players[client].harvesterHintTimer);
		tf2_players[client].harvesterHintTimer = null;
	}

	if (GetEntProp(client, Prop_Send, "m_iRevengeCrits") > 0)
	{
		PrintHintText(client, "Heal count: revenge");
	}
	else
	{
		PrintHintText(client, "Heal count: %d/%d",
			tf2_players[client].healCount, HARVESTER_HEAL_COUNT_MAX);
	}
	tf2_players[client].harvesterHealHintVisible = true;
	tf2_players[client].harvesterHintTimer = CreateTimer(
		HARVESTER_HINT_DURATION,
		Timer_ClearHarvesterHint,
		GetClientUserId(client),
		TIMER_FLAG_NO_MAPCHANGE);
}

static void Harvester_ClearHealHint(int client)
{
	if (tf2_players[client].harvesterHealHintVisible)
	{
		if (IsClientInGame(client))
		{
			PrintHintText(client, "");
		}
		tf2_players[client].harvesterHealHintVisible = false;
	}
}

static void Harvester_StopHintTimer(int client)
{
	if (!WR_IsValidPlayerIndex(client))
	{
		return;
	}

	if (tf2_players[client].harvesterHintTimer != null)
	{
		KillTimer(tf2_players[client].harvesterHintTimer);
		tf2_players[client].harvesterHintTimer = null;
	}
	Harvester_ClearHealHint(client);
}

static void Harvester_SyncHealTimer(int client)
{
	if (!Harvester_IsEligibleClient(client))
	{
		Harvester_ClearState(client);
		return;
	}
	if (!IsPlayerAlive(client) || !WeaponReverts_IsEnabled())
	{
		Harvester_StopHealTimer(client);
		return;
	}

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (Harvester_IsWeapon(activeWeapon))
	{
		Harvester_StartHealTimer(client);
	}
	else
	{
		Harvester_StopHealTimer(client);
	}
}

public void Harvester_FrameSyncHealTimer(any userId)
{
	int client = GetClientOfUserId(userId);
	if (client > 0)
	{
		if (!Harvester_IsEligibleClient(client) || CheckScythe(client) == 0)
		{
			Harvester_ClearState(client);
			return;
		}
		Harvester_SyncHealTimer(client);
	}
}

static void ShockCharge_StartTimer(int client)
{
	if (!IsClientInGame(client) || !WeaponReverts_IsEnabled() || tf2_players[client].shockCharge >= 30
		|| tf2_players[client].shockChargeTimer != null)
	{
		return;
	}

	tf2_players[client].shockChargeTimer = CreateTimer(
		0.5,
		Timer_ShockCharge,
		GetClientUserId(client),
		TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

static void ShockCharge_StopTimer(int client)
{
	if (!WR_IsValidPlayerIndex(client) || tf2_players[client].shockChargeTimer == null)
	{
		return;
	}

	KillTimer(tf2_players[client].shockChargeTimer);
	tf2_players[client].shockChargeTimer = null;
}

static void Harvester_SetCritBoost(int client, bool enabled)
{
	if (enabled)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client)
			|| TF2_IsPlayerInCondition(client, TFCond_Kritzkrieged))
		{
			return;
		}

		TF2_AddCondition(client, TFCond_Kritzkrieged, TFCondDuration_Infinite);
		tf2_players[client].harvesterCritBoostApplied = true;
		return;
	}

	if (tf2_players[client].harvesterCritBoostApplied)
	{
		if (IsClientInGame(client))
		{
			TF2_RemoveCondition(client, TFCond_Kritzkrieged);
		}
		tf2_players[client].harvesterCritBoostApplied = false;
	}
}

static void Harvester_SetRevengeCrit(int client)
{
	SetEntProp(client, Prop_Send, "m_iRevengeCrits", 1);
	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	Harvester_SetCritBoost(client, Harvester_IsWeapon(activeWeapon));
}

static void Harvester_ClearRevengeCrit(int client)
{
	tf2_players[client].harvesterCritConsumePending = false;
	if (IsClientInGame(client))
	{
		SetEntProp(client, Prop_Send, "m_iRevengeCrits", 0);
	}
	Harvester_SetCritBoost(client, false);
}

public void Harvester_ConsumeRevengeCrit(any userId)
{
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client))
	{
		return;
	}

	tf2_players[client].harvesterCritConsumePending = false;
	SetEntProp(client, Prop_Send, "m_iRevengeCrits", 0);
	Harvester_SetCritBoost(client, false);
	Harvester_ShowHealHint(client);
}

static void SecondaryDamageRefill_Reset(int client)
{
	if (!WR_IsValidPlayerIndex(client))
		return;

	tf2_players[client].secondaryDamageProgress = 0.0;
	tf2_players[client].secondaryDamageProgressExpiresAt = 0.0;
}

static void SecondaryDamageRefill_OnDamage(int attacker, int weapon, float damage)
{
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return;

	if (weapon <= MaxClients || !IsValidEntity(weapon) || damage <= 0.0)
		return;

	int requirement = TF2CustAttr_GetInt(weapon, ATTR_RESTORE_PRIMARY_SHOT_BY_DAMAGE, 0);
	if (requirement <= 0)
		return;

	float now = GetGameTime();
	if (tf2_players[attacker].secondaryDamageProgressExpiresAt <= now)
	{
		tf2_players[attacker].secondaryDamageProgress = 0.0;
	}

	tf2_players[attacker].secondaryDamageProgress += damage;
	tf2_players[attacker].secondaryDamageProgressExpiresAt = now + RESTORE_PRIMARY_SHOT_DAMAGE_WINDOW;

	int primary = GetPlayerWeaponSlot(attacker, 0);
	if (primary <= MaxClients || !IsValidEntity(primary))
		return;

	int maxClip = GetWeaponMaxClip(primary);
	if (maxClip <= 0)
		return;

	int clip = GetClip(primary);
	if (clip < 0)
		return;

	bool updated = false;
	float requirementFloat = float(requirement);
	while (tf2_players[attacker].secondaryDamageProgress >= requirementFloat)
	{
		if (clip >= maxClip)
		{
			float cap = requirementFloat * 2.0;
			if (tf2_players[attacker].secondaryDamageProgress > cap)
			{
				tf2_players[attacker].secondaryDamageProgress = cap;
			}
			break;
		}

		clip++;
		tf2_players[attacker].secondaryDamageProgress -= requirementFloat;
		updated = true;
	}

	if (updated)
	{
		SetClip_Weapon(primary, clip);
		PrintToChat(attacker, "cobson");
	}
}

static bool ReloadWeaponClip(int weapon, int reloadAmount)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return false;

	if (reloadAmount <= 0)
		return false;

	int maxClip = GetWeaponMaxClip(weapon);
	if (maxClip <= 0)
		return false;

	int clip = GetClip(weapon);
	if (clip < 0 || clip >= maxClip)
		return false;

	clip += reloadAmount;
	if (clip > maxClip)
	{
		clip = maxClip;
	}

	SetClip_Weapon(weapon, clip);
	return true;
}

static void ReloadOnHit_OnDamage(int weapon)
{
	ReloadWeaponClip(weapon, TF2CustAttr_GetInt(weapon, ATTR_RELOAD_ON_HIT));
}

static void ReloadOnKill_OnKill(int weapon)
{
	ReloadWeaponClip(weapon, TF2CustAttr_GetInt(weapon, ATTR_RELOAD_ON_KILL));
}

static int GetDamageSourceWeapon(int attacker, int weapon, int inflictor)
{
	if (weapon > MaxClients && IsValidEntity(weapon))
	{
		return weapon;
	}

	if (inflictor > MaxClients && IsValidEntity(inflictor))
	{
		if (HasEntProp(inflictor, Prop_Send, "m_hLauncher"))
		{
			int launcher = GetEntPropEnt(inflictor, Prop_Send, "m_hLauncher");
			if (launcher > MaxClients && IsValidEntity(launcher))
			{
				return launcher;
			}
		}

		if (HasEntProp(inflictor, Prop_Send, "m_hOriginalLauncher"))
		{
			int launcher = GetEntPropEnt(inflictor, Prop_Send, "m_hOriginalLauncher");
			if (launcher > MaxClients && IsValidEntity(launcher))
			{
				return launcher;
			}
		}
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		int activeWeapon = GetEntPropEnt(attacker, Prop_Data, "m_hActiveWeapon");
		if (activeWeapon > MaxClients && IsValidEntity(activeWeapon))
		{
			return activeWeapon;
		}
	}

	return -1;
}

static void FullPelletIgnite_ClearPair(int attacker, int victim)
{
	if (!WR_IsValidPlayerIndex(attacker) || !WR_IsValidPlayerIndex(victim))
	{
		return;
	}

	g_bPendingFullPelletIgnite[attacker][victim] = false;
	g_iPendingFullPelletWeaponRef[attacker][victim] = INVALID_ENT_REFERENCE;
	g_fPendingFullPelletBurnDuration[attacker][victim] = 0.0;
	g_iPendingFullPelletTick[attacker][victim] = 0;
}

static void FullPelletIgnite_ClearClient(int client)
{
	if (!WR_IsValidPlayerIndex(client))
	{
		return;
	}

	for (int other = 1; other <= MaxClients; other++)
	{
		FullPelletIgnite_ClearPair(client, other);
		FullPelletIgnite_ClearPair(other, client);
	}
}

static void FullPelletIgnite_ClearAll()
{
	for (int attacker = 1; attacker <= MaxClients; attacker++)
	{
		for (int victim = 1; victim <= MaxClients; victim++)
		{
			FullPelletIgnite_ClearPair(attacker, victim);
		}
	}
}

static void FullPelletIgnite_TryMark(int attacker, int victim, int weapon)
{
	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
	{
		return;
	}

	FullPelletIgnite_ClearPair(attacker, victim);
	if (!WeaponReverts_IsEnabled()
		|| !IsPlayerAlive(victim)
		|| GetClientTeam(attacker) <= 1
		|| GetClientTeam(victim) <= 1
		|| GetClientTeam(attacker) == GetClientTeam(victim)
		|| g_bAccuracyExploding[attacker]
		|| !IsValidWeaponEntity(weapon)
		|| GetFeatureStatus(FeatureType_Native, "TF2Scatter_IsCurrentShotFull") != FeatureStatus_Available)
	{
		return;
	}

	float burnDuration = TF2CustAttr_GetFloat(weapon, ATTR_IGNITE_ON_FULL_PELLET_HIT, 0.0);
	if (burnDuration <= 0.0 || !TF2Scatter_IsCurrentShotFull(attacker, victim, weapon))
	{
		return;
	}

	g_bPendingFullPelletIgnite[attacker][victim] = true;
	g_iPendingFullPelletWeaponRef[attacker][victim] = EntIndexToEntRef(weapon);
	g_fPendingFullPelletBurnDuration[attacker][victim] = burnDuration;
	g_iPendingFullPelletTick[attacker][victim] = GetGameTickCount();
}

static void FullPelletIgnite_TryConsumePost(int victim, int attacker, int weapon, int inflictor)
{
	if (!WR_IsValidPlayerIndex(attacker) || !WR_IsValidPlayerIndex(victim)
		|| !g_bPendingFullPelletIgnite[attacker][victim])
	{
		return;
	}

	int damageWeapon = GetDamageSourceWeapon(attacker, weapon, inflictor);
	bool matches = g_iPendingFullPelletTick[attacker][victim] == GetGameTickCount()
		&& IsValidWeaponEntity(damageWeapon)
		&& EntIndexToEntRef(damageWeapon) == g_iPendingFullPelletWeaponRef[attacker][victim];
	float burnDuration = g_fPendingFullPelletBurnDuration[attacker][victim];
	FullPelletIgnite_ClearPair(attacker, victim);

	if (!matches || burnDuration <= 0.0 || !IsPlayerAlive(victim)
		|| TF2_IsPlayerInCondition(victim, TFCond_Disguised)
		|| TF2_IsPlayerInCondition(victim, TFCond_Cloaked)
		|| TF2_IsPlayerInCondition(victim, TFCond_AfterburnImmune))
	{
		return;
	}

	TF2Util_IgnitePlayer(victim, attacker, burnDuration, damageWeapon);
}

static int GetProjectileOwner(int projectile)
{
	if (projectile <= MaxClients || !IsValidEntity(projectile))
		return 0;

	if (HasEntProp(projectile, Prop_Send, "m_hThrower"))
	{
		int owner = GetEntPropEnt(projectile, Prop_Send, "m_hThrower");
		if (WR_IsClientInGame(owner))
		{
			return owner;
		}
	}

	if (HasEntProp(projectile, Prop_Send, "m_hOwnerEntity"))
	{
		int owner = GetEntPropEnt(projectile, Prop_Send, "m_hOwnerEntity");
		if (WR_IsClientInGame(owner))
		{
			return owner;
		}
	}

	return 0;
}

static bool SandmanPreJI_IsEnabledWeapon(int weapon)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return false;

	if (GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") != SANDMAN_ITEMDEF)
		return false;

	return TF2CustAttr_GetInt(weapon, ATTR_SANDMAN_PRE_JI) != 0;
}

static float SandmanPreJI_GetBaseStunDuration()
{
	if (g_hSandmanBaseDuration != null)
	{
		return g_hSandmanBaseDuration.FloatValue;
	}

	return g_hSandmanFallbackBaseDuration != null ? g_hSandmanFallbackBaseDuration.FloatValue : 2.0;
}

static float SandmanPreJI_GetMaxStunFlightTime()
{
	return g_hSandmanMaxStunFlightTime != null ? g_hSandmanMaxStunFlightTime.FloatValue : 1.5;
}

static bool SandmanPreJI_IsStunBall(int entity)
{
	if (entity <= MaxClients || !IsValidEntity(entity))
		return false;

	char class[64];
	GetEntityClassname(entity, class, sizeof(class));
	return StrEqual(class, "tf_projectile_stun_ball");
}

public void SandmanPreJI_OnStunBallSpawnPost(int entity)
{
	if (entity <= 0 || entity >= MAX_TRACKED_ENTITIES || !IsValidEntity(entity))
		return;

	int owner = GetProjectileOwner(entity);
	int sandman = GetDamageSourceWeapon(owner, -1, entity);
	g_bProjectileSandmanPreJI[entity] = SandmanPreJI_IsEnabledWeapon(sandman);
}

static bool SandmanPreJI_IsEnabledProjectile(int projectile)
{
	if (!SandmanPreJI_IsStunBall(projectile))
		return false;

	if (projectile > 0 && projectile < MAX_TRACKED_ENTITIES && g_bProjectileSandmanPreJI[projectile])
	{
		return true;
	}

	int owner = GetProjectileOwner(projectile);
	int sandman = GetDamageSourceWeapon(owner, -1, projectile);
	bool enabled = SandmanPreJI_IsEnabledWeapon(sandman);
	if (enabled && projectile > 0 && projectile < MAX_TRACKED_ENTITIES)
	{
		g_bProjectileSandmanPreJI[projectile] = true;
	}
	return enabled;
}

static bool SandmanPreJI_IsEnabledForDamage(int attacker, int weapon, int inflictor)
{
	if (SandmanPreJI_IsEnabledProjectile(inflictor))
	{
		return true;
	}

	int sandman = GetDamageSourceWeapon(attacker, weapon, inflictor);
	return SandmanPreJI_IsEnabledWeapon(sandman);
}

static Action SandmanPreJI_OnBaseballDamage(int victim, int attacker, int weapon, int inflictor, float &damage)
{
	if (!WR_IsClientInGame(victim) || !WR_IsClientInGame(attacker) || victim == attacker)
		return Plugin_Continue;

	if (!SandmanPreJI_IsEnabledForDamage(attacker, weapon, inflictor))
		return Plugin_Continue;

	damage = SANDMAN_PRE_JI_DAMAGE;
	return Plugin_Changed;
}

public MRESReturn SandmanPreJI_ApplyBallImpactEffectOnVictim_Pre(int entity, DHookParam parameters)
{
	int victim = parameters.Get(1);
	if (!WR_IsClientInGame(victim) || !SandmanPreJI_IsEnabledProjectile(entity))
	{
		return MRES_Ignored;
	}

	g_iSandmanStunFrame[victim] = GetGameTickCount();
	g_iSandmanStunInflictorRef[victim] = EntIndexToEntRef(entity);
	return MRES_Ignored;
}

static int SandmanPreJI_FindPendingStunVictim()
{
	int frame = GetGameTickCount();
	int victim = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!WR_IsClientInGame(i) || g_iSandmanStunFrame[i] != frame)
		{
			continue;
		}

		if (victim != 0)
		{
			return 0;
		}
		victim = i;
	}
	return victim;
}

static int SandmanPreJI_GetStunVictim(Address sharedAddress)
{
	if (GetFeatureStatus(FeatureType_Native, "TF2Util_GetPlayerFromSharedAddress") == FeatureStatus_Available)
	{
		int victim = TF2Util_GetPlayerFromSharedAddress(sharedAddress);
		if (WR_IsClientInGame(victim))
		{
			return victim;
		}
	}

	return SandmanPreJI_FindPendingStunVictim();
}

public MRESReturn SandmanPreJI_StunPlayer_Pre(Address sharedAddress, DHookParam parameters)
{
	int victim = SandmanPreJI_GetStunVictim(sharedAddress);
	if (!WR_IsClientInGame(victim) || g_iSandmanStunFrame[victim] != GetGameTickCount())
	{
		return MRES_Ignored;
	}

	int inflictor = EntRefToEntIndex(g_iSandmanStunInflictorRef[victim]);
	g_iSandmanStunFrame[victim] = 0;
	g_iSandmanStunInflictorRef[victim] = INVALID_ENT_REFERENCE;
	if (!SandmanPreJI_IsEnabledProjectile(inflictor))
	{
		return MRES_Ignored;
	}

	float spawnTime = (inflictor > 0 && inflictor < MAX_TRACKED_ENTITIES) ? g_flProjectileSpawnTime[inflictor] : 0.0;
	float maxFlightTime = SandmanPreJI_GetMaxStunFlightTime();
	float flightTime = spawnTime > 0.0 ? GetGameTime() - spawnTime : maxFlightTime;
	float cappedFlightTime = flightTime < maxFlightTime ? flightTime : maxFlightTime;
	float lifetimeRatio = cappedFlightTime / maxFlightTime;
	if (lifetimeRatio <= SANDMAN_PRE_JI_MIN_STUN_RATIO)
	{
		return MRES_Supercede;
	}

	float stunDuration = lifetimeRatio * SandmanPreJI_GetBaseStunDuration();
	if (HasEntProp(inflictor, Prop_Send, "m_bCritical") && GetEntProp(inflictor, Prop_Send, "m_bCritical") != 0)
	{
		stunDuration += 2.0;
	}

	int stunFlags = TF_STUNFLAGS_SMALLBONK;
	if (lifetimeRatio >= 1.0)
	{
		stunDuration += 1.0;
		stunFlags = TF_STUNFLAGS_BIGBONK;

		int attacker = GetEntPropEnt(inflictor, Prop_Send, "m_hOwnerEntity");
		if (WR_IsClientInGame(attacker) && !IsFakeClient(attacker) && !IsFakeClient(victim)
			&& attacker != victim && GetClientTeam(attacker) != GetClientTeam(victim))
		{
			FireSandmanMoonshot(attacker, victim);
			PrintCenterTextAll("%N moonshot %N!", attacker, victim);
		}
	}

	parameters.Set(1, stunDuration);
	parameters.Set(2, SANDMAN_PRE_JI_SLOWDOWN);
	parameters.Set(3, stunFlags);
	return MRES_ChangedHandled;
}


public Action OnTakeDamage(int client, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client)) return Plugin_Continue;
	bool damageChanged = false;
	if (inflictor > MaxClients && IsValidEntity(inflictor) && (damagetype & DMG_BULLET))
	{
		char classname[32];
		GetEntityClassname(inflictor, classname, sizeof(classname));
		if (StrEqual(classname, "obj_sentrygun"))
		{
			damagetype |= DMG_PREVENT_PHYSICS_FORCE;
			damageChanged = true;
		}
	}

	if (damage > 0.0
		&& attacker >= 1 && attacker <= MaxClients
		&& IsClientInGame(attacker)
		&& !IsFakeClient(client) && !IsFakeClient(attacker)
		&& client != attacker
		&& GetClientTeam(client) != GetClientTeam(attacker))
	{
		g_iEnvironmentalKillAttackerUserId[client] = GetClientUserId(attacker);
		g_fEnvironmentalKillTime[client] = GetGameTime();
	}
	if (attacker < 1) return damageChanged ? Plugin_Changed : Plugin_Continue;

	bool attackerIsPlayer = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker));
	if (attackerIsPlayer && inflictor == attacker && CheckIfAfterburn(damagecustom))
	{
		Harvester_OnAfterburnDamage(attacker);
	}

	int damageWeapon = GetDamageSourceWeapon(attacker, weapon, inflictor);
	int directDamageWeapon = GetDamageSourceWeapon(0, weapon, inflictor);
	if (attackerIsPlayer
		&& damageWeapon > MaxClients
		&& IsValidEntity(damageWeapon)
		&& inflictor == attacker
		&& (damagetype & (DMG_BULLET | DMG_BUCKSHOT))
		&& TF2CustAttr_GetInt(damageWeapon, ATTR_HITSCAN_NO_DAMAGE_PHYSICS, 0) != 0)
	{
		damagetype |= DMG_PREVENT_PHYSICS_FORCE;
		damageChanged = true;
	}

	FullPelletIgnite_TryMark(attacker, client, damageWeapon);
	if (attackerIsPlayer
		&& damage > 0.0
		&& client != attacker
		&& GetClientTeam(client) != GetClientTeam(attacker)
		&& directDamageWeapon > MaxClients
		&& IsValidEntity(directDamageWeapon)
		&& Harvester_IsWeapon(directDamageWeapon)
		&& GetEntProp(attacker, Prop_Send, "m_iRevengeCrits") > 0
		&& !tf2_players[attacker].harvesterCritConsumePending)
	{
		tf2_players[attacker].harvesterCritConsumePending = true;
		RequestFrame(Harvester_ConsumeRevengeCrit, GetClientUserId(attacker));
	}

	if (attackerIsPlayer && damageWeapon > MaxClients && IsValidEntity(damageWeapon))
	{
		SecondaryDamageRefill_OnDamage(attacker, damageWeapon, damage);
		ReloadOnHit_OnDamage(damageWeapon);

		// Resolve duel damage without falling back to the attacker's active weapon.
		int duelWeapon = GetDamageSourceWeapon(0, weapon, inflictor);
		if (duelWeapon > MaxClients && IsValidEntity(duelWeapon)
			&& TF2CustAttr_GetInt(duelWeapon, "duel declared") != 0)
		{
			int victimWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
			if (victimWeapon > MaxClients && IsValidEntity(victimWeapon) && TF2CustAttr_GetInt(victimWeapon, "duel declared") != 0)
			{
				if (GetClip(duelWeapon) == 6)
				{
					damage = 100.0;
					damagetype |= DMG_CRIT;
					return Plugin_Changed;
				}
			}
		}
	}

	bool validWeapon = (weapon > MaxClients && IsValidEntity(weapon));
	int wepindex = (validWeapon ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1);

	if (damagecustom == SANDMAN_DAMAGE_CUSTOM)
	{
		Action sandmanAction = SandmanPreJI_OnBaseballDamage(client, attacker, weapon, inflictor, damage);
		return damageChanged && sandmanAction == Plugin_Continue ? Plugin_Changed : sandmanAction;
	}

	if (wepindex == 442 || wepindex == 588)	 // Pomson, bison
	{
		float mult = 1.0;
		if (wepindex == 442)
		{
			mult = GetConVarFloat(g_hBisonDamageMult);
		}
		else
		{
			mult = GetConVarFloat(g_hPomsonDamageMult);
		}
		damage *= mult;
		// Remove bullet damage type (ignores bullet resist from e.g. Vaccinator) and restore knockback
		damagetype &= ~(DMG_BULLET | DMG_PREVENT_PHYSICS_FORCE);
		// Enable sonic flag so ranged resist attrib still works
		damagetype |= DMG_SONIC;
		return Plugin_Changed;
	}

	if (wepindex == 307) { //Ullapool Caber weapon index
		if (client == attacker) {
			damage = 50.0;
			return Plugin_Changed;
		} else if (damagecustom == 0) {
			damage = 35.00;
			return Plugin_Changed;
		} else if (damagecustom == 42) {
			damagetype|=TF_WEAPON_GRENADE_DEMOMAN;
			if (CheckRocketJumping(attacker)) {
				damage = 175.00;
				damagetype|=DMG_CRIT;
				return Plugin_Changed;
			} else {
				damage = 90.00;
				return Plugin_Changed;
			}
		}
	} else if ((wepindex == 812 || wepindex == 833) && damage > 40.0) { // Cleavers
		if (TF2_IsPlayerInCondition(client, TFCond_Dazed) && !(damagetype & DMG_CRIT)) { // if stunned
			damage = 33.3;
			damagetype|=DMG_CRIT;
			TryAwardSandmanCleaverCombo(attacker, client);
			return Plugin_Changed;
		}
	} else {
		if (!validWeapon) {
			return damageChanged ? Plugin_Changed : Plugin_Continue;
		}

		if (TF2CustAttr_GetInt(weapon, "shock therapy attributes") != 0) {
			damage = float(tf2_players[attacker].shockCharge * 100 / 30);
			tf2_players[attacker].shockCharge = 0;
			ShockCharge_StartTimer(attacker);
			EmitAmbientSound(SOUND_NEON_SIGN, damagePosition, client, SNDLEVEL_NORMAL);
			return Plugin_Changed;
		} else if (TF2CustAttr_GetInt(weapon, "hitscan ignite targets") != 0) {
			float victimPos[3];
			float attackerPos[3];
			GetClientAbsOrigin(client, victimPos);
			GetClientAbsOrigin(attacker, attackerPos);
			if (GetVectorDistance(victimPos, attackerPos) <= 1024.0) {
				TF2_IgnitePlayer(client, attacker, 4.0);
				return Plugin_Changed;
			}
		return damageChanged ? Plugin_Changed : Plugin_Continue;
		}
	}
		
	return damageChanged ? Plugin_Changed : Plugin_Continue;
}

bool IsWorldInflictedDeath(Event event)
{
	char weapon[64];
	char weaponLogClassname[64];
	event.GetString("weapon", weapon, sizeof(weapon));
	event.GetString("weapon_logclassname", weaponLogClassname, sizeof(weaponLogClassname));
	if (StrEqual(weapon, "world", false) || StrEqual(weaponLogClassname, "world", false))
	{
		return true;
	}

	if (event.GetInt("attacker") != 0)
	{
		return false;
	}

	int inflictor = event.GetInt("inflictor_entindex");
	if (inflictor == 0)
	{
		return true;
	}

	if (inflictor > MaxClients && IsValidEntity(inflictor))
	{
		char classname[64];
		GetEntityClassname(inflictor, classname, sizeof(classname));
		if (StrEqual(classname, "worldspawn", false) || StrEqual(classname, "trigger_hurt", false))
		{
			return true;
		}
	}

	return false;
}

public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!Accuracy_IsValidClient(attacker) || !IsPlayerAlive(attacker))
        return Plugin_Continue;

	if (damagetype & DMG_BULLET)
	{
		int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
		if (weapon > MaxClients && IsValidEntity(weapon))
		{
			if (TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED_WHILE_ZOOMED, 0) != 0)
			{
				if (WeaponReverts_CanHeadshotNow(weapon))
				{
					damagetype |= DMG_USE_HITLOCATIONS;
				}
				else
				{
					damagetype &= ~DMG_USE_HITLOCATIONS;
				}
				return Plugin_Changed;
			}

			if (WeaponReverts_CanHeadshotNow(weapon))
			{
				damagetype |= DMG_USE_HITLOCATIONS;
				return Plugin_Changed;
			}
		}
	}

    if (GetClientTeam(victim) != GetClientTeam(attacker))
        return Plugin_Continue;

    if (CheckShock(attacker) != 2)
        return Plugin_Continue;

    int buff = OverhealStruct(victim);
    int health = GetClientHealth(victim);
    if (health >= buff)
        return Plugin_Continue;

    int medigun = GetPlayerWeaponSlot(attacker, 1);
    if (!IsValidEntity(medigun))
        return Plugin_Continue;

    float pos[3];
    GetClientAbsOrigin(victim, pos);  // was GetClientAbsAngles — wrong data
    TF2_SetHealth(victim, buff);
    tf2_players[attacker].shockCharge = 0;
    ShockCharge_StartTimer(attacker);
    EmitAmbientSound(SOUND_ARROW_HEAL, pos, victim, SNDLEVEL_NORMAL);

    float uber = (float(buff - health) / 5000.0) + GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");
    SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", uber);

    return Plugin_Continue;
}

public Action OnTakeDamageAlive(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {

	if (!Accuracy_IsValidClient(attacker) || weapon < 1) return Plugin_Continue;
	bool validWeapon = (weapon > MaxClients && IsValidEntity(weapon));
	Action ambassador102Action = Ambassador102_OnHeadshotDamage(victim, attacker, weapon, damage, damage_type, damage_custom);
	if (ambassador102Action != Plugin_Continue)
		return ambassador102Action;

	ScattergunKnockback_OnDamage(victim, attacker, weapon, damage, damage_type);

	if (
		validWeapon &&
		damage > 0 &&
		victim != attacker &&
		inflictor == attacker &&
		TF2CustAttr_GetInt(weapon, "taser damage becomes metal") == 1
	) {
		if (TF2_GetPlayerClass(attacker) == TFClass_Engineer && g_iMetalOffset != -1)
		{
			int attackerMetal = TF_GetMetalAmount(attacker);
			int credit = RoundFloat(damage);
			if (attackerMetal + credit > 200)
				credit = 200 - attackerMetal;
			if (credit > 0)
			{
				TF_SetMetalAmount(attacker, attackerMetal + credit);
			}
		}
	}
	
	if (validWeapon && TF2CustAttr_GetInt(weapon, "mark for death multiple") != 0)
	{
		bool shift_array = true;

		// Do not shift the mark victim array if the current victim is present there already
		for (int i = 0; i < FAN_O_WAR_MAX_MARK_COUNT; i++)
		{
			if (tf2_players[attacker].markVictims[i] == victim)
			{
				shift_array = false;
				break;
			}
		}

		if (shift_array)
		{
			// Shift mark victim array by one
			for (int i = FAN_O_WAR_MAX_MARK_COUNT; i > 0; i--)
			{
				tf2_players[attacker].markVictims[i] = tf2_players[attacker].markVictims[i-1];
			}

			tf2_players[attacker].markVictims[0] = victim;

			// If last victim in the array has the mark condition, remove it
			int lastvictim = tf2_players[attacker].markVictims[FAN_O_WAR_MAX_MARK_COUNT];
			if (lastvictim >= 1 && lastvictim <= MaxClients && IsClientInGame(lastvictim))
			{
				TF2_RemoveCondition(lastvictim, TFCond_MarkedForDeath);
			}
		}
		
		// Mark the player we attacked
		TF2_AddCondition(victim, TFCond_MarkedForDeath, 15.0, attacker);
	}

	if (damage_custom == TF_CUSTOM_CANNONBALL_PUSH)
	{
		// This should prevent loose cannon causing a stun
		TF2_AddCondition(victim, TFCond_KnockedIntoAir, 0.001);
	}

	return Plugin_Continue;
}

static float WeaponReverts_GetAfterburnRateOnHit(int weapon)
{
	return SDKCall(g_SDKGetAfterburnRateOnHit, weapon);
}

// Set DamageType Ignite compatibility based on nosoop's SM-TFAttributeSupport:
// https://github.com/nosoop/SM-TFAttributeSupport
static void WeaponReverts_ApplyDamageTypeIgniteDuration(int weapon, int victim, int attacker)
{
	if (WeaponReverts_GetAfterburnRateOnHit(weapon) > 0.0
		|| !TF2_IsPlayerInCondition(victim, TFCond_OnFire))
	{
		return;
	}

	float desiredDuration = TF2Attrib_HookValueFloat(0.0, "set_dmgtype_ignite", weapon);
	if (desiredDuration <= 0.0)
	{
		return;
	}

	float additionalDuration = desiredDuration - TF2Util_GetPlayerBurnDuration(victim);
	if (additionalDuration > 0.0)
	{
		TF2Util_IgnitePlayer(victim, attacker, additionalDuration, weapon);
	}
}

public void WeaponReverts_OnTakeDamageAlivePost(
	int victim, int attacker, int inflictor, float damage, int damageType,
	int weapon, const float damageForce[3], const float damagePosition[3], int damageCustom)
{
	if (!WeaponReverts_IsEnabled() || !WR_IsClientInGame(victim))
	{
		return;
	}

	Escampette_OnDamageTaken(victim, attacker, damage, damagePosition);
	if (!WR_IsClientInGame(attacker))
	{
		return;
	}

	FullPelletIgnite_TryConsumePost(victim, attacker, weapon, inflictor);

	if (damageCustom == TF_CUSTOM_BURNING
		|| weapon <= MaxClients || !IsValidEntity(weapon) || !TF2Util_IsEntityWeapon(weapon))
	{
		return;
	}

	WeaponReverts_ApplyDamageTypeIgniteDuration(weapon, victim, attacker);
}

MRESReturn CalculateMaxSpeed(int client, DHookReturn returnValue) {
	if (
		client >= 1 &&
		client <= MaxClients &&
		IsValidEntity(client) &&
		IsClientInGame(client)
	) {
		int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (tf2_players[client].huntingRevolverZoomed
			&& HuntingRevolver_IsWeapon(activeWeapon))
		{
			float speed = view_as<float>(returnValue.Value);
			if (speed > HUNTING_REVOLVER_MAX_ZOOM_SPEED)
			{
				returnValue.Value = HUNTING_REVOLVER_MAX_ZOOM_SPEED;
				return MRES_Override;
			}
		}

		switch (TF2_GetPlayerClass(client))
		{
			case TFClass_Scout:
			{
				int primary = GetPlayerWeaponSlot(client, TFWeaponSlot_Primary);

				if (primary > MaxClients && IsValidEntity(primary) && TF2CustAttr_GetInt(primary, "original babyface attributes") == 1) {
					// Original BFB proper speed application
					float boost = GetEntPropFloat(client, Prop_Send, "m_flHypeMeter");
					returnValue.Value = view_as<float>(returnValue.Value) * ValveRemapVal(boost, 0.0, 99.0, 1.0, 1.383);
					return MRES_Override;
				}
			}
			case TFClass_Heavy:
			{
				// Steak boosts speed by 35% instead of 30%
				if (
					TF2_IsPlayerInCondition(client, TFCond_CritCola) &&
					view_as<float>(returnValue.Value) < 230.0 * 1.35
				) {
					returnValue.Value = view_as<float>(returnValue.Value) * 1.35 / 1.30;
					return MRES_Override;
				}
			}
			case TFClass_Spy:
			{
				if (Escampette_HasSpeedBonus(client))
				{
					returnValue.Value = view_as<float>(returnValue.Value) * 1.30;
					return MRES_Override;
				}
			}
		}
	}
	return MRES_Ignored;
}

MRESReturn ApplyBiteEffects_Pre(int entity, DHookParam parameters) {
	int client = parameters.Get(1);
	if (
		client >= 1 &&
		client <= MaxClients
	) {
		tf2_players[client].oldHealth = GetClientHealth(client);
	}
	return MRES_Ignored;
}

MRESReturn ApplyBiteEffects_Post(int entity, DHookParam parameters) {
	int lunchbox_type = TF2Attrib_HookValueInt(0, "set_weapon_mode", entity);
	int client = parameters.Get(1);
	if (
		client >= 1 &&
		client <= MaxClients &&
		(lunchbox_type == LUNCHBOX_CHOCOLATE_BAR || lunchbox_type == LUNCHBOX_FISHCAKE)
	) {
		int health_cur = GetClientHealth(client);
		int health_gained = health_cur - tf2_players[client].oldHealth;
		if (health_gained < 25) {
			int heal_amt = min(25 - health_gained, DALOKOHS_OVERHEAL - health_cur);
			if (heal_amt > 0) {
				AddPlayerHealth(client, heal_amt);
			}
		}
	}
	return MRES_Ignored;
}

MRESReturn CartDispenseMetal(int entity, DHookReturn returnValue, DHookParam parameters) {
	int client = parameters.Get(1);
	if (
		client > 0 &&
		client <= MaxClients
	) {
		int secondary = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);

		if (secondary > MaxClients && IsValidEntity(secondary)) {
			// Reduced metal yields from Payload carts
			float ammo_mult = TF2CustAttr_GetFloat(secondary, "mult metal from carts", 1.0);

			if (ammo_mult != 1.0) {
				TF2Attrib_AddCustomPlayerAttribute(client, "metal_pickup_decreased", ammo_mult, 0.001);
			}
		}
	}
	return MRES_Ignored;
}

public MRESReturn CanFireCriticalShot_Post(int weapon, DHookReturn hReturn, DHookParam parameters)
{
    if (weapon <= MaxClients || !IsValidEntity(weapon))
        return MRES_Ignored;

    int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    if (client <= 0 || client > MaxClients)
        return MRES_Ignored;

	bool isHeadshot = parameters.Get(1);
	if (isHeadshot && Ambassador102_IsEnabledWeapon(weapon))
	{
		hReturn.Value = true;
		return MRES_Override;
	}

	if (!WeaponReverts_HasHeadshotFeature(weapon))
		return MRES_Ignored;

	if (!isHeadshot)
	{
		// Preserve the legacy headshot attribute's existing non-headshot behavior.
		if (TF2CustAttr_GetInt(weapon, ATTR_HEADSHOTS_ENABLED, 0) != 0)
		{
			hReturn.Value = true;
			return MRES_Override;
		}
		return MRES_Ignored;
	}

	hReturn.Value = WeaponReverts_CanHeadshotNow(weapon);
	return MRES_Override;
}

// Gas passer buff is a candidate for removal, it's uninspired and could be more creative
public void TF2_OnConditionAdded(int client, TFCond condition)
{
	if (condition == TFCond_Gas) //If gas is applied
	{
		TF2_AddCondition(client, TFCond_Jarated, 6.0); //Apply Jarate for 6 seconds
	}

	if (condition == TFCond_Cloaked)
	{
		Escampette_RecalculateSpeed(client);
	}

	if (condition == TFCond_Taunting) {
		int secondary = GetPlayerWeaponSlot(client, 1);
		int active = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

		if (active == secondary) {
			float duration = Sproke_GetAttributeDuration(secondary);
			Sproke_TryActivate(client, duration);
		}
	}

	if (
		condition == TFCond_Dazed &&
		abs(GetGameTickCount() - tf2_players[client].bonkFrame) <= 2 &&
		tf2_players[client].bonkFrame > 0
	) {
		// bonk mark for death
		int stun_amt = GetEntProp(client, Prop_Send, "m_iMovementStunAmount");
		float mark_dur = ValveRemapVal(float(stun_amt), 63.0, 127.0, BONK_MARK_FOR_DEATH_MIN, BONK_MARK_FOR_DEATH_MAX);
		TF2_AddCondition(client, TFCond_MarkedForDeathSilent, mark_dur);

		// remove the slowdown
		TF2_RemoveCondition(client, TFCond_Dazed);
	}
}

public void TF2_OnConditionRemoved(int client, TFCond condition)
{
	if (condition == TFCond_Cloaked)
	{
		Escampette_RecalculateSpeed(client);
	}
}

static KeyValues WeaponReverts_LoadConfigFile(KeyValues current, const char[] rootName, const char[] configPath)
{
	if (current != null)
	{
		delete current;
		current = null;
	}

	KeyValues kv = new KeyValues(rootName);

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), configPath);

	if (!kv.ImportFromFile(path))
	{
		LogError("[weaponreverts] Failed to load %s", path);
	}

	return kv;
}

static void LoadWeaponRevertsConfig()
{
	g_hWeaponRevertsConfig = WeaponReverts_LoadConfigFile(
		g_hWeaponRevertsConfig,
		"WeaponReverts",
		WEAPON_REVERTS_CONFIG_PATH
	);
}

public Action Command_ReloadWeaponRevertsConfig(int client, int args)
{
	LoadWeaponRevertsConfig();
	for (int target = 1; target <= MaxClients; target++)
	{
		if (IsClientInGame(target))
		{
			HuntingRevolver_ResetClient(target);
			Harvester_SyncHealTimer(target);
			Escampette_RecalculateSpeed(target);
		}
	}
	ReplyToCommand(client, "[WeaponReverts] Reloaded configs/weapons.cfg");
	return Plugin_Handled;
}

static bool WeaponReverts_ItemKeyContainsIndex(const char[] itemKey, int index)
{
	int indexes[32];
	int count = ItemIndexes_Parse(itemKey, indexes, sizeof(indexes));
	for (int i = 0; i < count; i++)
	{
		if (indexes[i] == index)
		{
			return true;
		}
	}

	return false;
}

static bool WeaponReverts_JumpToConfiguredWeapon(int index)
{
	if (g_hWeaponRevertsConfig == null)
		return false;

	g_hWeaponRevertsConfig.Rewind();
	if (!g_hWeaponRevertsConfig.GotoFirstSubKey(true))
		return false;

	do
	{
		char itemKey[64];
		g_hWeaponRevertsConfig.GetSectionName(itemKey, sizeof(itemKey));
		if (WeaponReverts_ItemKeyContainsIndex(itemKey, index))
		{
			return true;
		}
	}
	while (g_hWeaponRevertsConfig.GotoNextKey(true));

	g_hWeaponRevertsConfig.Rewind();
	return false;
}

static bool WeaponReverts_CurrentSectionContainsItemIndex(KeyValues kv, int index)
{
	if (kv == null)
		return false;

	bool found = false;
	if (kv.GotoFirstSubKey(false))
	{
		do
		{
			char itemKey[64];
			kv.GetSectionName(itemKey, sizeof(itemKey));
			if (WeaponReverts_ItemKeyContainsIndex(itemKey, index))
			{
				found = true;
				break;
			}
		}
		while (kv.GotoNextKey(false));

		kv.GoBack();
	}

	return found;
}

static bool WeaponReverts_IsAllowedForClient(int client)
{
	if (g_hWeaponRevertsConfig == null || !WR_IsClientInGame(client))
		return true;

	if (!g_hWeaponRevertsConfig.JumpToKey("classes", false))
		return true;

	char classKey[16];
	TF2Classes_GetKey(TF2_GetPlayerClass(client), classKey, sizeof(classKey));

	bool allowed = false;
	if (classKey[0] != '\0')
	{
		char value[8];
		g_hWeaponRevertsConfig.GetString(classKey, value, sizeof(value));
		allowed = (value[0] != '\0' && StringToInt(value) != 0);
	}

	g_hWeaponRevertsConfig.GoBack();
	return allowed;
}

static void WeaponReverts_GetWeaponClasses(int index, char[] buffer, int maxlen)
{
	buffer[0] = '\0';

	if (g_hWeaponRevertsConfig == null)
		return;

	g_hWeaponRevertsConfig.Rewind();
	if (!g_hWeaponRevertsConfig.JumpToKey(WEAPON_REVERTS_ITEM_CLASSES_SECTION, false))
		return;

	if (!g_hWeaponRevertsConfig.GotoFirstSubKey(true))
	{
		g_hWeaponRevertsConfig.Rewind();
		return;
	}

	do
	{
		char className[32];
		g_hWeaponRevertsConfig.GetSectionName(className, sizeof(className));

		if (WeaponReverts_CurrentSectionContainsItemIndex(g_hWeaponRevertsConfig, index))
		{
			if (buffer[0] != '\0')
				StrCat(buffer, maxlen, ",");
			StrCat(buffer, maxlen, className);
		}
	}
	while (g_hWeaponRevertsConfig.GotoNextKey(true));

	g_hWeaponRevertsConfig.Rewind();
}

static bool WeaponReverts_ClassCanUseWeapon(const char[] className, int index)
{
	if (g_hWeaponRevertsConfig == null)
		return false;

	g_hWeaponRevertsConfig.Rewind();
	if (!g_hWeaponRevertsConfig.JumpToKey(WEAPON_REVERTS_ITEM_CLASSES_SECTION, false))
		return false;

	if (!g_hWeaponRevertsConfig.JumpToKey(className, false))
	{
		g_hWeaponRevertsConfig.Rewind();
		return false;
	}

	bool found = WeaponReverts_CurrentSectionContainsItemIndex(g_hWeaponRevertsConfig, index);
	g_hWeaponRevertsConfig.Rewind();
	return found;
}

static bool WeaponReverts_GetConfiguredInfo(int index, char[] weaponName, int weaponNameLen, char[] positive, int positiveLen, char[] neutral, int neutralLen, char[] negative, int negativeLen, char[] type, int typeLen, char[] classes, int classesLen)
{
	if (g_hWeaponRevertsConfig == null)
		return false;

	if (!WeaponReverts_JumpToConfiguredWeapon(index))
		return false;

	g_hWeaponRevertsConfig.GetString("name", weaponName, weaponNameLen, "Unknown Weapon");
	positive[0] = '\0';
	neutral[0] = '\0';
	negative[0] = '\0';
	strcopy(type, typeLen, "buff");

	if (g_hWeaponRevertsConfig.JumpToKey("description", false))
	{
		g_hWeaponRevertsConfig.GetString("positive", positive, positiveLen, "");
		g_hWeaponRevertsConfig.GetString("neutral", neutral, neutralLen, "");
		g_hWeaponRevertsConfig.GetString("negative", negative, negativeLen, "");
		g_hWeaponRevertsConfig.GetString("type", type, typeLen, "buff");
		g_hWeaponRevertsConfig.GoBack();
	}

	g_hWeaponRevertsConfig.Rewind();
	WeaponReverts_GetWeaponClasses(index, classes, classesLen);
	return true;
}

public int Native_GetWeaponInfo(Handle plugin, int numParams)
{
	int index = GetNativeCell(1);

	char weaponName[128];
	char positive[256];
	char neutral[256];
	char negative[256];
	char type[32];
	char classes[128];
	bool found = WeaponReverts_GetConfiguredInfo(index, weaponName, sizeof(weaponName), positive, sizeof(positive), neutral, sizeof(neutral), negative, sizeof(negative), type, sizeof(type), classes, sizeof(classes));

	SetNativeString(2, found ? weaponName : "", GetNativeCell(3), true);
	SetNativeString(4, found ? positive : "", GetNativeCell(5), true);
	if (numParams >= 13)
	{
		SetNativeString(6, found ? neutral : "", GetNativeCell(7), true);
		SetNativeString(8, found ? negative : "", GetNativeCell(9), true);
		SetNativeString(10, found ? type : "buff", GetNativeCell(11), true);
		SetNativeString(12, found ? classes : "", GetNativeCell(13), true);
	}
	else
	{
		SetNativeString(6, found ? negative : "", GetNativeCell(7), true);
		SetNativeString(8, found ? type : "buff", GetNativeCell(9), true);
		SetNativeString(10, found ? classes : "", GetNativeCell(11), true);
	}
	return found;
}

public int Native_CanClassUseWeapon(Handle plugin, int numParams)
{
	char className[32];
	GetNativeString(1, className, sizeof(className));
	return WeaponReverts_ClassCanUseWeapon(className, GetNativeCell(2));
}

static void WeaponReverts_ApplyAttributeSection(int entity, const char[] sectionName, bool customAttributes)
{
	if (!g_hWeaponRevertsConfig.JumpToKey(sectionName, false))
		return;

	if (g_hWeaponRevertsConfig.GotoFirstSubKey(false))
	{
		do
		{
			char attr[128];
			char value[128];
			g_hWeaponRevertsConfig.GetSectionName(attr, sizeof(attr));
			g_hWeaponRevertsConfig.GetString(NULL_STRING, value, sizeof(value));

			if (attr[0] != '\0' && value[0] != '\0')
			{
				if (customAttributes)
				{
					TF2CustAttr_SetString(entity, attr, value);
				}
				else
				{
					TF2Attrib_SetByName(entity, attr, StringToFloat(value));
				}
			}
		}
		while (g_hWeaponRevertsConfig.GotoNextKey(false));

		g_hWeaponRevertsConfig.GoBack();
	}

	g_hWeaponRevertsConfig.GoBack();
}

static void WeaponReverts_ApplyGameAttributeSection(int entity)
{
	WeaponReverts_ApplyAttributeSection(entity, "attributes_game", false);
}

static void WeaponReverts_ApplyCustomAttributeSection(int entity)
{
	WeaponReverts_ApplyAttributeSection(entity, "attributes_custom", true);
}

static void WeaponReverts_ApplyConfiguredAttributes(int client, int index, int entity)
{
	if (g_hWeaponRevertsConfig == null || !WR_IsClientInGame(client) || !WR_IsValidWeaponEntity(entity))
		return;

	if (!WeaponReverts_JumpToConfiguredWeapon(index))
		return;

	if (WeaponReverts_IsAllowedForClient(client))
	{
		WeaponReverts_ApplyGameAttributeSection(entity);
		WeaponReverts_ApplyCustomAttributeSection(entity);
		WeaponReverts_ApplyEngineOverrides(entity);
	}

	g_hWeaponRevertsConfig.Rewind();
}

static float WeaponReverts_GetPrimaryClipBonusFromLoadout(int client)
{
	float bestBonus = 0.0;

	for (int slot = 0; slot <= WEAPON_SLOT_LAST; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (!WR_IsValidWeaponEntity(weapon))
			continue;

		float bonus = TF2CustAttr_GetFloat(weapon, ATTR_PRIMARY_CLIP_SIZE_BONUS, 0.0);
		if (bonus > bestBonus)
		{
			bestBonus = bonus;
		}
	}

	return bestBonus;
}

static void WeaponReverts_ApplyPrimaryClipBonusFromLoadout(int client)
{
	if (!WR_IsClientInGame(client))
		return;

	int primary = GetPlayerWeaponSlot(client, WEAPON_SLOT_PRIMARY);
	if (!WR_IsValidWeaponEntity(primary))
		return;

	float bonus = WeaponReverts_GetPrimaryClipBonusFromLoadout(client);
	if (bonus <= 0.0)
		return;

	TF2Attrib_SetByName(primary, ATTR_CLIP_SIZE_BONUS, bonus);
}

public void WeaponReverts_FrameApplyPrimaryClipBonus(any userId)
{
	int client = GetClientOfUserId(userId);
	WeaponReverts_ApplyPrimaryClipBonusFromLoadout(client);
}

static void WeaponReverts_QueuePrimaryClipBonusRefresh(int client)
{
	if (!WR_IsClientInGame(client))
		return;

	RequestFrame(WeaponReverts_FrameApplyPrimaryClipBonus, GetClientUserId(client));
}

public int TF2Items_OnGiveNamedItem_Post(int client, char[] classname, int itemDefinitionIndex, int itemLevel, int itemQuality, int entityIndex)
{
	if (WeaponReverts_IsEnabled()) {
		ShockCharge_StopTimer(client);
		tf2_players[client].shockCharge = 30;
		TF2Attrib_SetByName(entityIndex, "crit mod disabled hidden", 0.00);

		char auth[32];
		if (g_hFallingStompAllWeapons != null
			&& GetConVarBool(g_hFallingStompAllWeapons)
			&& Kogasa_GetClientSteam2(client, auth, sizeof(auth), true))
		{
			if (!(StrEqual(auth, "STEAM_0:1:101494818")))
			{
				TF2Attrib_SetByName(entityIndex, "boots falling stomp", 1.00);
			}
		}

		int oldMax = GetWeaponMaxClip(entityIndex);
		int oldClip = GetClip(entityIndex);

		WeaponReverts_ApplyConfiguredAttributes(client, itemDefinitionIndex, entityIndex);

		int newMax = GetWeaponMaxClip(entityIndex);
		if (oldMax > 0 && oldClip == oldMax && newMax > oldMax)
		{
			SetClip_Weapon(entityIndex, newMax);
		}

		WeaponReverts_QueuePrimaryClipBonusRefresh(client);
	}

	return 0;
}

bool ValidateAndNullCheck(MemoryPatch patch) {
		return patch != null && patch.Validate();
}

static void DestroyPatch(MemoryPatch patch)
{
	if (patch != null)
	{
		patch.Disable();
		delete patch;
	}
}

public float clamp(float a, float b, float c)
{
	return (a > c ? c : (a < b ? b : a));
}

static void HookAllBuildings()
{
	static const char classes[][] = { "obj_sentrygun", "obj_dispenser" };

	for (int i = 0; i < sizeof(classes); i++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[i])) != -1)
		{
			HookBuildingEntity(ent);
		}
	}
}

static void HookBuildingEntity(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return;

	SDKHook(entity, SDKHook_OnTakeDamage, OnBuildingDamaged);
}

float ValveRemapVal(float val, float a, float b, float c, float d) {
	// https://github.com/ValveSoftware/source-sdk-2013/blob/master/sp/src/public/mathlib/mathlib.h#L648

	float tmp;

	if (a == b) {
		return (val >= b ? d : c);
	}

	tmp = ((val - a) / (b - a));

	if (tmp < 0.0) tmp = 0.0;
	if (tmp > 1.0) tmp = 1.0;

	return (c + ((d - c) * tmp));
}

int abs(int x)
{
	int mask = x >> 31;
	return (x + mask) ^ mask;
}
