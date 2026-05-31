#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <tf_custom_attributes>
#include <tf2items>
#include <tf2attributes>
#include <addplayerhealth>
#include <sourcescramble>
#include <dhooks>
#undef REQUIRE_EXTENSIONS
#include <scattergun_pellets>
#define REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
#include <points_store_api>
#define REQUIRE_PLUGIN
// Addplayerhealth was made by chdata, I'm not able to find it online anymore so I'll rehost it in this repo

#define ACC_MAX_DIST		768.0
#define ACC_THRESH_NEAR		  32.0
#define ACC_THRESH_FAR		  12.0
#define ACC_STREAK_TARGET	   2
#define ACC_STREAK_WINDOW	   4.0
#define MEATSHOT_KILL_BONUS_TYPE "meatshot_kill"

#define ACC_EXPLODE_DAMAGE	 50.0
#define ACC_EXPLODE_RADIUS	 180.0
#define ACC_EXPLODE_SOUND	"ambient/fire/gascan_ignite1.wav"
#define ACC_NOTIFY_SOUND "vo/taunts/pyro/pyro_taunt_rps_exert_21.mp3"
#define ACC_NOTIFY_2 "vo/taunts/pyro/pyro_taunt_rps_exert_23.mp3"
#define SOUND_ARROW_HEAL "weapons/fx/rics/arrow_impact_crossbow_heal.wav"
#define SOUND_NEON_SIGN "weapons/neon_sign_hit_world_02.wav"
#define SOUND_DISPENSER_METAL "weapons/dispenser_generate_metal.wav"
#define SOUND_POMSON_DRAIN "weapons/drg_pomson_drain_01.wav"
#define SOUND_FLAME_OUT "player/flame_out.wav"
#define ATTR_SECONDARY_AMMO_REFILL "secondary damage ammo refill"
#define ATTR_SECONDARY_REFILL_SOUND "tools/ifm/beep.wav"
#define ATTR_RELOAD_ON_HIT "reload on hit"

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
#define VITASAW_ITEMDEF 173
#define VITASAW_MAX_PRESERVED_CHARGE 0.20

tf2_player tf2_players[MAXPLAYERS + 1];

enum struct tf2_player
{
	int jump_status;
	int scytheWeapon;
	int shockCharge;
	int healCount;
	float lastUber;
	int lastUberMedigunDefIndex;
	int engiMetal;
	int accuracyStreak;
	float accuracyStreakExpiresAt;
	float secondaryDamageProgress;
	Handle sprokeTimer;
	int sprokePrimaryRef;
	int sprokeParticleRef;
	int sprokeClipRecord;
	bool holdingJump;
	int markVictims[FAN_O_WAR_MAX_MARK_COUNT+1];
	int bonkFrame;
	int oldHealth;
}

Handle g_SDKGetMaxClip1 = null;
int g_iMetalOffset = -1;
bool g_bWarnedMetalOffset = false;
bool g_bAccuracyExploding[MAXPLAYERS + 1];

#include <weaponreverts>
 
ConVar g_sEnabled;
ConVar g_hPomsonDamageMult;
ConVar g_hBisonDamageMult;
ConVar g_hScattergunPelletsDebug;
MemoryPatch patch_RevertCozyCamper_FlinchNerf;
Handle g_hHealTimer = INVALID_HANDLE;

MemoryPatch patch_Wrangler_CustomShieldRepair;
MemoryPatch patch_Wrangler_CustomShieldShellRefill;
MemoryPatch patch_Wrangler_CustomShieldRocketRefill;
MemoryPatch patch_Wrangler_CustomShieldDamageTaken;
MemoryPatch patch_Wrangler_RescueRanger_CustomShieldRepair;
float g_flWranglerCustomShieldValue = 0.75;

DynamicDetour dhook_CTFPlayer_CalculateMaxSpeed;
DynamicDetour dhook_CTFLunchBox_ApplyBiteEffects;
DynamicHook dhook_CObjectCartDispenser_DispenseMetal;
DynamicHook dhook_CTFWeaponBase_CanFireCriticalShot;

public Plugin myinfo =
{
	name = "WeaponReverts",
	author = "Hombre",
	description = "Weapon changes plugin with custom attribute code such as recoil jumping",
	version = "6.0",
	url = "https://kogasa.tf"
};

stock void ResetClientArrays(int client)
{
	if (client <= 0 || client > MaxClients) return;
	tf2_players[client].scytheWeapon = 0;
	tf2_players[client].shockCharge = 30;
	tf2_players[client].healCount = 0;
	tf2_players[client].lastUber = 0.0;
	tf2_players[client].lastUberMedigunDefIndex = 0;
	tf2_players[client].engiMetal = 0;
	tf2_players[client].accuracyStreak = 0;
	tf2_players[client].accuracyStreakExpiresAt = 0.0;
	tf2_players[client].secondaryDamageProgress = 0.0;
	tf2_players[client].jump_status = TF2_JUMP_NONE;
	tf2_players[client].holdingJump = false;
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
}

public void OnPluginStart() {
	PreCacheWeaponSounds();
	g_sEnabled = CreateConVar("reverts_enabled", "1", "Enable/Disable the plugin");
	g_hPomsonDamageMult = CreateConVar("reverts_pomson_damage_mult", "0.50", "Damage multiplier for the Pomson 6000", FCVAR_NONE, true, 0.1, true, 2.0);
	g_hBisonDamageMult = CreateConVar("reverts_bison_damage_mult", "0.8", "Damage multiplier for the Righteous Bison", FCVAR_NONE, true, 0.1, true, 2.0);
	g_hScattergunPelletsDebug = CreateConVar("reverts_scattergun_pellets_debug", "0", "Log tracked shotgun/scattergun pellet forward diagnostics.");
	RegAdminCmd("sm_scatterpellets_status", Command_ScatterPelletsStatus, ADMFLAG_GENERIC, "Print scattergun pellet integration status.");
	if (GetConVarInt(g_sEnabled)) {
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
			}
		}

		HookAllBuildings();
		HookEvent("player_builtobject", Event_PlayerBuiltObject);

		HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
		HookEvent("post_inventory_application", Event_Resupply, EventHookMode_Post);
		HookEvent("player_spawn", OnPlayerSpawn);

		// Blast jumping hooks

		HookEvent("rocket_jump",				Event_TF2RocketJump);
		HookEvent("rocket_jump_landed",			Event_TF2JumpLanded);
		HookEvent("sticky_jump",				Event_TF2StickyJump);
		HookEvent("sticky_jump_landed",			Event_TF2JumpLanded);

		GameData conf;
		conf = new GameData("weaponreverts");
		if (conf == null) SetFailState("Failed to load weaponreverts.txt conf!");

		// Setup SDKCall for GetMaxClip1
		StartPrepSDKCall(SDKCall_Entity);
		PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CTFWeaponBase::GetMaxClip1()");
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		g_SDKGetMaxClip1 = EndPrepSDKCall();

		if (g_SDKGetMaxClip1 == null)
		{
			SetFailState("Failed to create SDKCall for GetMaxClip1");
		}

		dhook_CTFPlayer_CalculateMaxSpeed = DynamicDetour.FromConf(conf, "CTFPlayer::TeamFortress_CalculateMaxSpeed");
		dhook_CTFLunchBox_ApplyBiteEffects = DynamicDetour.FromConf(conf, "CTFLunchBox::ApplyBiteEffects");
		dhook_CObjectCartDispenser_DispenseMetal = DynamicHook.FromConf(conf, "CObjectCartDispenser::DispenseMetal");
		dhook_CTFWeaponBase_CanFireCriticalShot = DynamicHook.FromConf(conf, "CTFWeaponBase::CanFireCriticalShot");

		if (dhook_CTFPlayer_CalculateMaxSpeed == null) SetFailState("Failed to create dhook_CTFPlayer_CalculateMaxSpeed");
		if (dhook_CTFLunchBox_ApplyBiteEffects == null) SetFailState("Failed to create dhook_CTFLunchBox_ApplyBiteEffects");
		if (dhook_CObjectCartDispenser_DispenseMetal == null) SetFailState("Failed to create dhook_CObjectCartDispenser_DispenseMetal");
		if (dhook_CTFWeaponBase_CanFireCriticalShot == null) SetFailState("Failed to create dhook_CTFWeaponBase_CanFireCriticalShot");

		dhook_CTFPlayer_CalculateMaxSpeed.Enable(Hook_Post, CalculateMaxSpeed);
		dhook_CTFLunchBox_ApplyBiteEffects.Enable(Hook_Pre, ApplyBiteEffects_Pre);
		dhook_CTFLunchBox_ApplyBiteEffects.Enable(Hook_Post, ApplyBiteEffects_Post);

		// Create the patches
		patch_RevertCozyCamper_FlinchNerf = MemoryPatch.CreateFromConf(conf, "CTFPlayer::ApplyPunchImpulseX_FakeFullyChargedCondition");
		patch_Wrangler_CustomShieldRepair = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldRepair");
		patch_Wrangler_CustomShieldShellRefill = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldShellRefill");
		patch_Wrangler_CustomShieldRocketRefill = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnWrenchHit_CustomShieldRocketRefill");
		patch_Wrangler_CustomShieldDamageTaken = MemoryPatch.CreateFromConf(conf, "CObjectSentrygun::OnTakeDamage_CustomShieldDamageTaken");
		patch_Wrangler_RescueRanger_CustomShieldRepair = MemoryPatch.CreateFromConf(conf, "CTFProjectile_Arrow::BuildingHealingArrow_CustomShieldRepair");

		if (!ValidateAndNullCheck(patch_RevertCozyCamper_FlinchNerf)) SetFailState("Failed to create patch_RevertCozyCamper_FlinchNerf");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldRepair)) SetFailState("Failed to create patch_Wrangler_CustomShieldRepair");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldShellRefill)) SetFailState("Failed to create patch_Wrangler_CustomShieldShellRefill");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldRocketRefill)) SetFailState("Failed to create patch_Wrangler_CustomShieldRocketRefill");
		if (!ValidateAndNullCheck(patch_Wrangler_CustomShieldDamageTaken)) SetFailState("Failed to create patch_Wrangler_CustomShieldDamageTaken");
		if (!ValidateAndNullCheck(patch_Wrangler_RescueRanger_CustomShieldRepair)) SetFailState("Failed to create patch_Wrangler_RescueRanger_CustomShieldRepair");

		patch_RevertCozyCamper_FlinchNerf.Enable();
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
		delete conf;

		StartHealTimer();
	}
}

public void PreCacheWeaponSounds() {
	PrecacheSound(SOUND_ARROW_HEAL, true);
	PrecacheSound(SOUND_NEON_SIGN, true);
	PrecacheSound(SOUND_FLAME_OUT, true);
	PrecacheSound(ACC_EXPLODE_SOUND, true);
	PrecacheSound(ACC_NOTIFY_SOUND, true);
	PrecacheSound(ACC_NOTIFY_2, true);
	PrecacheSound(BURP_SOUND, true);
	PrecacheSound(ATTR_SECONDARY_REFILL_SOUND, true);
}

public void OnMapStart() {
	PreCacheWeaponSounds();
	StartHealTimer();
}

public void OnMapEnd()
{
	StopHealTimer();
}

public void OnPluginEnd()
{
	StopHealTimer();
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClientArrays(i);
	}

	DestroyPatch(patch_RevertCozyCamper_FlinchNerf); patch_RevertCozyCamper_FlinchNerf = null;
	DestroyPatch(patch_Wrangler_CustomShieldRepair); patch_Wrangler_CustomShieldRepair = null;
	DestroyPatch(patch_Wrangler_CustomShieldShellRefill); patch_Wrangler_CustomShieldShellRefill = null;
	DestroyPatch(patch_Wrangler_CustomShieldRocketRefill); patch_Wrangler_CustomShieldRocketRefill = null;
	DestroyPatch(patch_Wrangler_CustomShieldDamageTaken); patch_Wrangler_CustomShieldDamageTaken = null;
	DestroyPatch(patch_Wrangler_RescueRanger_CustomShieldRepair); patch_Wrangler_RescueRanger_CustomShieldRepair = null;
}

// I added functions like these while I was worried about memory safety... I assume they're redundant

public OnClientPutInServer(client)
{
	if (IsClientInGame(client) && GetConVarInt(g_sEnabled))
	{
		SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
		SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
		SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
		ResetClientArrays(client);
	}
}

// Potentially important for memory safety
public void OnClientDisconnect(int client)
{
	ResetClientArrays(client);
}

public void OnEntityCreated(int entity, const char[] class) {
	if (entity < 0 || entity >= 2048) return;

	if (GetConVarInt(g_sEnabled))
	{
		if (StrEqual(class, "tf_projectile_energy_ring"))
		{
			SDKHook(entity, SDKHook_SpawnPost, OnEnergyRingSpawnPost);
			SDKHook(entity, SDKHook_Touch, OnEnergyRingTouch);
		}

		if (StrEqual(class, "mapobj_cart_dispenser"))
		{
			dhook_CObjectCartDispenser_DispenseMetal.HookEntity(Hook_Pre, entity, CartDispenseMetal);
		}

		if (StrEqual(class, "tf_weapon_pistol"))
		{
			dhook_CTFWeaponBase_CanFireCriticalShot.HookEntity(Hook_Post, entity, CanFireCriticalShot_Post);
		}
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
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static bool IsValidWeaponEntity(int weapon)
{
	return (weapon > MaxClients && IsValidEntity(weapon));
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
	return IsValidWeaponEntity(melee) && GetEntProp(melee, Prop_Send, "m_iItemDefinitionIndex") == VITASAW_ITEMDEF;
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

	int drainAttr = TF2CustAttr_GetInt(weapon, "drain ammo on hit sentry");
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

	if (drained > 0 && TF2_GetPlayerClass(attacker) == TFClassType:TFClass_Engineer && g_iMetalOffset != -1)
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

static void Accuracy_Explode(int attacker, int victim, float position[3], float damage, float radius)
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

	EmitAmbientSound(ACC_EXPLODE_SOUND, position, victim, SNDLEVEL_NORMAL);

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

static void Accuracy_OnMeatshot(int attacker, int victim, int weapon = -1)
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
		char classname[64];
		GetEntityClassname(weapon, classname, sizeof(classname));
		ScatterPellets_Debug("meatshot ignored: weapon lacks flame shotgun attributes weapon=%d class=%s", weapon, classname);
		return;
	}

	int maxClip = GetWeaponMaxClip(weapon);
	if (maxClip > 0)
	{
		int clip = GetClip(weapon);
		if (clip >= 0 && clip < maxClip)
		{
			SetClip_Weapon(weapon, clip + 1);
		}
	}

	float eye[3];
	GetClientEyePosition(attacker, eye);

	float now = GetGameTime();
	if (tf2_players[victim].accuracyStreakExpiresAt <= now)
	{
		tf2_players[victim].accuracyStreak = 0;
	}

	tf2_players[victim].accuracyStreak++;
	tf2_players[victim].accuracyStreakExpiresAt = now + ACC_STREAK_WINDOW;
	if (tf2_players[victim].accuracyStreak >= ACC_STREAK_TARGET)
	{
		float boomPos[3];
		GetClientAbsOrigin(victim, boomPos);
		boomPos[2] -= Accuracy_GetClassSubtractionValue(victim);

		if (IsPlayerAlive(victim))
		{
			TF2_IgnitePlayer(victim, attacker, 4.0);
		}
		Accuracy_Explode(attacker, victim, boomPos, ACC_EXPLODE_DAMAGE, ACC_EXPLODE_RADIUS);
		EmitAmbientSound(ACC_NOTIFY_2, eye, attacker, SNDLEVEL_NORMAL);

		tf2_players[victim].accuracyStreak = 0;
		tf2_players[victim].accuracyStreakExpiresAt = 0.0;
	}
	else
	{
		EmitAmbientSound(ACC_NOTIFY_SOUND, eye, attacker, SNDLEVEL_NORMAL);
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

static void ScatterPellets_GetFeatureStatusName(FeatureStatus status, char[] buffer, int maxlen)
{
	switch (status)
	{
		case FeatureStatus_Available:
		{
			strcopy(buffer, maxlen, "available");
		}
		case FeatureStatus_Unavailable:
		{
			strcopy(buffer, maxlen, "unavailable");
		}
		case FeatureStatus_Unknown:
		{
			strcopy(buffer, maxlen, "unknown");
		}
		default:
		{
			strcopy(buffer, maxlen, "invalid");
		}
	}
}

public Action Command_ScatterPelletsStatus(int client, int args)
{
	FeatureStatus pointsNative = GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints");
	char pointsStatus[16];
	ScatterPellets_GetFeatureStatusName(pointsNative, pointsStatus, sizeof(pointsStatus));

	ReplyToCommand(client, "[WeaponReverts] scattergun_pellets extension: %s", LibraryExists("scattergun_pellets") ? "available" : "unavailable");
	ReplyToCommand(client, "[WeaponReverts] points_store native: %s", pointsStatus);

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

	if (!GetConVarBool(g_sEnabled))
	{
		ScatterPellets_Debug("ignored: reverts_enabled is 0");
		return;
	}

	if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
	{
		ScatterPellets_Debug("ignored: invalid attacker/victim");
		return;
	}
	if (g_bAccuracyExploding[attacker])
	{
		ScatterPellets_Debug("ignored: accuracy explosion in progress");
		return;
	}

	if (total <= 0 || pellets < total)
	{
		ScatterPellets_Debug("ignored: not a full pellet shot");
		return;
	}

	Accuracy_OnMeatshot(attacker, victim); // This is only for the flame shotgun

	if (!kill)
	{
		return;
	}

	if (IsFakeClient(attacker) || IsFakeClient(victim))
	{
		ScatterPellets_Debug("points ignored: bots do not award meatshot currency");
		return;
	}

	if (GetFeatureStatus(FeatureType_Native, "PointsStore_ApplyBonusPoints") == FeatureStatus_Available)
	{
		bool awarded = PointsStore_ApplyBonusPoints(attacker, 1, true, true, 1.0, MEATSHOT_KILL_BONUS_TYPE, 0, 3.0, 15);
		ScatterPellets_Debug("points_store award result: %d", awarded ? 1 : 0);
	}
	else
	{
		ScatterPellets_Debug("ignored: PointsStore_ApplyBonusPoints native unavailable");
	}
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

public Event_TF2RocketJump(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0) {
		if (tf2_players[client].jump_status == TF2_JUMP_ROCKET_START) {
			tf2_players[client].jump_status = TF2_JUMP_ROCKET;
		} else if (tf2_players[client].jump_status != TF2_JUMP_ROCKET) {
			tf2_players[client].jump_status = TF2_JUMP_ROCKET_START;
		}
	}
}

public Event_TF2StickyJump(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0) {
		if (tf2_players[client].jump_status != TF2_JUMP_STICKY) {
			tf2_players[client].jump_status = TF2_JUMP_STICKY;
		}
	}
}

public Event_TF2JumpLanded(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
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
	tf2_players[client].healCount = 0;
	tf2_players[client].shockCharge = 30;
	tf2_players[client].accuracyStreak = 0;
	tf2_players[client].accuracyStreakExpiresAt = 0.0;

	VitaSaw_CacheCharge(client, false);

	int attackerId = event.GetInt("attacker");
	int attacker = GetClientOfUserId(attackerId);
	if (attacker == 0 || client == 0)
	{
		return Plugin_Continue;
	}

	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
	{
		int activeWeapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
		if (!(activeWeapon > MaxClients && IsValidEntity(activeWeapon)))
			return Plugin_Continue;
		if (TF2CustAttr_GetFloat(activeWeapon, ATTR_SECONDARY_AMMO_REFILL, 0.0) > 0.0)
		{
			int primary = GetPlayerWeaponSlot(attacker, 0);
			if (primary > MaxClients && IsValidEntity(primary))
			{
				int maxClip = GetWeaponMaxClip(primary);
				if (maxClip > 0)
				{
					SetClip_Weapon(primary, maxClip);
				}
			}
		}
	}

	if (tf2_players[attacker].scytheWeapon != 0 && TF2_IsPlayerInCondition(client, TFCond_OnFire))
		tf2_players[attacker].healCount += 4;

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

public Action Event_Resupply(Event event, const char[] name, bool dontBroadcast)
{
	int userId = event.GetInt("userid");
	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Continue;

	VitaSaw_ApplyStoredCharge(client);

	if (tf2_players[client].shockCharge != 30)
	{
		tf2_players[client].shockCharge = 29; // The 29 is for visual effect
		return Plugin_Changed;
	}

	int watch = GetPlayerWeaponSlot(client, 4);
	if (watch > MaxClients && IsValidEntity(watch) && TF2CustAttr_GetInt(watch, "escampette attributes") != 1)
	{
		TF2_RemoveCondition(client, TFCond_SpeedBuffAlly);
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

	VitaSaw_ApplyStoredCharge(client);

	return Plugin_Continue;
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

public Action TF2_CalcIsAttackCritical(client, weapon, String:weaponname[], &bool:result) {
	if (!IsClientInGame(client) || weapon <= MaxClients || !IsValidEntity(weapon))
		return Plugin_Continue;

	if (GetEntityFlags(client) & FL_ONGROUND)
		return Plugin_Continue;

	if (TF2CustAttr_GetInt(weapon, "twin barrel attributes") == 0)
		return Plugin_Continue;

	if (GetClip(weapon) != 2)
		return Plugin_Continue;

	float velocity[3], angles[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
	GetClientEyeAngles(client, angles);

	float pitch = DegToRad(-angles[0]);
	float yaw = DegToRad(angles[1]);
	float push = 280.0 * Cosine(pitch);

	velocity[0] -= push * Cosine(yaw);
	velocity[1] -= push * Sine(yaw);
	velocity[2] -= 280.0 * Sine(pitch);

	//int health = GetClientHealth(client);
	//float rounded = float(RoundFloat(float(health) * 0.10));
	//SDKHooks_TakeDamage(client, client, client, rounded, DMG_CLUB, 0);

	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
	return Plugin_Changed;
}

public Action Timer_HealTimer(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client)) continue;

        if (tf2_players[client].healCount > 0 && IsPlayerAlive(client) &&
            GetClientHealth(client) < TF2_GetPlayerMaxHealth(client) &&
				CheckScythe(client) == 2)
        {
            tf2_players[client].healCount--;
            AddPlayerHealth(client, 4, 1.0, false, true);
			//EmitAmbientSound(SOUND_DISPENSER_METAL, damagePosition, client, SNDLEVEL_NORMAL);
        }

        // Shock charge refill runs independently
        if (tf2_players[client].shockCharge < 30)
        {
            tf2_players[client].shockCharge++;
            if (tf2_players[client].shockCharge % 2 == 0 || tf2_players[client].shockCharge == 1)
            {
                PrintHintText(client, "Shock Charge: %i%%%", (tf2_players[client].shockCharge * 100 / 30));
            }
        }
    }
    return Plugin_Continue;
}

// Damage distance multiplier attribute, now unused since we're giving Pom/Bison a larger hitbox
/*float GetDistanceMultiplier(float posVic[3], float posAtt[3])
{
	float distance = GetVectorDistance(posVic, posAtt);

	// Distance-based rampup
	// Example: base at 300 units, scales linearly, capped at +100% (2.0) or adjust as needed
	float rampup = (distance - 300.0) * 0.001; // scaling facto
	rampup = clamp(rampup, 0.0, 1.0);		   // cap at +100%

	float calculated = 1.0 + rampup;		   // final multiplie

	return calculated;
}*/

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

public Action OnWeaponSwitch(client, weapon)
{
	if (!GetConVarInt(g_sEnabled))
	{
		return Plugin_Continue;
	}

	int previousWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	TryApplyHolsterReload(previousWeapon);

	if (weapon != previousWeapon)
	{
		TryApplyHolsterReload(weapon);
	}

	return Plugin_Continue;
}

static void SecondaryDamageRefill_OnDamage(int attacker, int weapon, float damage)
{
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
		return;

	if (weapon <= MaxClients || !IsValidEntity(weapon) || damage <= 0.0)
		return;

	float requirement = TF2CustAttr_GetFloat(weapon, ATTR_SECONDARY_AMMO_REFILL, 0.0);
	if (requirement <= 0.0)
		return;

	tf2_players[attacker].secondaryDamageProgress += damage;

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
	while (tf2_players[attacker].secondaryDamageProgress >= requirement)
	{
		if (clip >= maxClip)
		{
			float cap = requirement * 2.0;
			if (tf2_players[attacker].secondaryDamageProgress > cap)
			{
				tf2_players[attacker].secondaryDamageProgress = cap;
			}
			break;
		}

		clip++;
		tf2_players[attacker].secondaryDamageProgress -= requirement;
		updated = true;
	}

	if (updated)
	{
		SetClip_Weapon(primary, clip);
		PrintToChat(attacker, "cobson");
	}
}

static void ReloadOnHit_OnDamage(int weapon)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return;

	int reloadAmount = TF2CustAttr_GetInt(weapon, ATTR_RELOAD_ON_HIT);
	if (reloadAmount <= 0)
		return;

	int maxClip = GetWeaponMaxClip(weapon);
	if (maxClip <= 0)
		return;

	int clip = GetClip(weapon);
	if (clip < 0 || clip >= maxClip)
		return;

	clip += reloadAmount;
	if (clip > maxClip)
	{
		clip = maxClip;
	}

	SetClip_Weapon(weapon, clip);
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


public Action OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype, &weapon, Float:damageForce[3], Float:damagePosition[3], damagecustom)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client)) return Plugin_Continue;
	if (attacker < 1) return Plugin_Continue;

	bool attackerIsPlayer = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker));
	int damageWeapon = GetDamageSourceWeapon(attacker, weapon, inflictor);

	if (attackerIsPlayer && damageWeapon > MaxClients && IsValidEntity(damageWeapon))
	{
		SecondaryDamageRefill_OnDamage(attacker, damageWeapon, damage);
		ReloadOnHit_OnDamage(damageWeapon);

		int duelAttr = TF2CustAttr_GetInt(damageWeapon, "duel declared");
		if (duelAttr != 0)
		{
			int victimWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
			if (victimWeapon > MaxClients && IsValidEntity(victimWeapon) && TF2CustAttr_GetInt(victimWeapon, "duel declared") != 0)
			{
				if (GetClip(damageWeapon) == 6)
				{
					damage = 100.0;
					damagetype |= DMG_CRIT;
					return Plugin_Changed;
				}
			}
		}
	}

	bool validWeapon = (weapon > MaxClients && IsValidEntity(weapon));
	new wepindex = (validWeapon ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1);
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
			return Plugin_Changed;
		}
	} else {
		// Moved watch lookup here so it's only called when actually needed
		int watch = GetPlayerWeaponSlot(client, 4);
		if (watch > MaxClients && IsValidEntity(watch) && TF2CustAttr_GetInt(watch, "escampette attributes") != 0) { // TF2C Custom Attribute for Spy
			if (TF2_IsPlayerInCondition(client, TFCond_Cloaked)) { // if cloaked
				float flCloakMeter = GetEntPropFloat(client, Prop_Send, "m_flCloakMeter");
				flCloakMeter -= 10;
				SetEntPropFloat(client, Prop_Send, "m_flCloakMeter", flCloakMeter);
				EmitAmbientSound(SOUND_POMSON_DRAIN, damagePosition, client, SNDLEVEL_NORMAL);
				return Plugin_Changed;
			}
		} else if (CheckIfAfterburn(damagecustom)) {
			if (!IsPlayerAlive(attacker)) return Plugin_Continue;
			tf2_players[attacker].scytheWeapon = CheckScythe(attacker);
			if (tf2_players[attacker].scytheWeapon != 0) {
				if (tf2_players[attacker].scytheWeapon == 2) {
					AddPlayerHealth(attacker, 4, 1.0, false, true);
					//EmitAmbientSound(SOUND_DISPENSER_METAL, damagePosition, attacker, SNDLEVEL_NORMAL);
					return Plugin_Changed;
				} else {
					// Queue the heal for the timer instead of extinguishing
					tf2_players[attacker].healCount++;
					return Plugin_Changed;
				}
			}
		}

		if (!validWeapon) {
			return Plugin_Continue;
		}

		if (TF2CustAttr_GetInt(weapon, "twin barrel attributes") != 0) {
			float vecAngles[3];
			float vecVelocity[3];

			GetClientEyeAngles(attacker, vecAngles);
			GetEntPropVector(client, Prop_Data, "m_vecVelocity", vecVelocity);

			vecAngles[0] = DegToRad(-1.0 * vecAngles[0]);
			vecAngles[1] = DegToRad(vecAngles[1]);

			if (damage >= 40.0) vecVelocity[2] = 251.0;

			TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vecVelocity);
			return Plugin_Changed;
		} else if (TF2CustAttr_GetInt(weapon, "shock therapy attributes") != 0) {
			damage = float(tf2_players[attacker].shockCharge * 100 / 30);
			tf2_players[attacker].shockCharge = 0;
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
		return Plugin_Continue;
		}
	}
		
	return Plugin_Continue;
}

public Action OnTraceAttack(victim, &attacker, &inflictor, &Float:damage, &damagetype, &ammotype, hitbox, hitgroup)
{
    if (attacker <= 0 || !IsValidEdict(attacker) || !IsValidClient(attacker) || !IsPlayerAlive(attacker))
        return Plugin_Continue;

	if (damagetype & DMG_BULLET)
	{
		int weapon = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
		if (weapon > MaxClients && IsValidEntity(weapon) && TF2CustAttr_GetInt(weapon, "headshots enabled", 0))
		{
			damagetype |= DMG_USE_HITLOCATIONS;
			return Plugin_Changed;
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
    EmitAmbientSound(SOUND_ARROW_HEAL, pos, victim, SNDLEVEL_NORMAL);

    float uber = (float(buff - health) / 5000.0) + GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");
    SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", uber);

    return Plugin_Continue;
}

/*public Action OnPlayerRunCmd(
	int client, int& buttons, int& impulse, float vel[3], float angles[3],
	int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2]
) {
	int primary = GetPlayerWeaponSlot(client, TFWeaponSlot_Primary);

	if (primary != -1 && TF2CustAttr_GetInt(primary, "original babyface attributes") == 1) {
		// Original babyface boost reset on jump
		if (buttons & IN_JUMP != 0)
		{
			if (!tf2_players[client].holdingJump)
			{
				if (
					GetEntPropFloat(client, Prop_Send, "m_flHypeMeter") > 0.0 && 
					GetEntProp(client, Prop_Data, "m_nWaterLevel") <= 1 && // don't reset if swimming 
					buttons & IN_DUCK == 0 && // don't reset if crouching
					(GetEntityFlags(client) & FL_ONGROUND) != 0 // don't reset if airborne, the attribute will handle air jumps
				) {
					SetEntPropFloat(client, Prop_Send, "m_flHypeMeter", 0.0);
					// apply the following so movespeed gets reset immediately
					TF2Attrib_AddCustomPlayerAttribute(client, "move speed penalty", 0.99, 0.001);
				}
				tf2_players[client].holdingJump = true;
			}
		}
		else
		{
			tf2_players[client].holdingJump = false;
		}
	}
	
	return Plugin_Continue;
}*/

public Action OnTakeDamageAlive(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {

	if (attacker < 1 || weapon < 1) return Plugin_Continue;
	bool validWeapon = (weapon > MaxClients && IsValidEntity(weapon));

	if (
		validWeapon &&
		damage > 0 &&
		victim != attacker &&
		inflictor == attacker &&
		TF2CustAttr_GetInt(weapon, "taser damage becomes metal") == 1
	) {
		if (TF2_GetPlayerClass(attacker) == TFClassType:TFClass_Engineer && g_iMetalOffset != -1)
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

MRESReturn CalculateMaxSpeed(int client, DHookReturn returnValue) {
	if (
		client >= 1 &&
		client <= MaxClients &&
		IsValidEntity(client) &&
		IsClientInGame(client)
	) {
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

    // Check the firing weapon directly, not assumed secondary slot
    if (TF2CustAttr_GetInt(weapon, "headshots enabled", 0)) {
        hReturn.Value = true;
        return MRES_Override;
    }
    return MRES_Ignored;
}

// Gas passer buff is a candidate for removal, it's uninspired and could be more creative
public TF2_OnConditionAdded(int client, TFCond condition)
{
	if (condition == TFCond_Gas) //If gas is applied
	{
		TF2_AddCondition(client, TFCond_Jarated, 6.0); //Apply Jarate for 6 seconds
	}

	if (condition == TFCond_Cloaked)
	{
		int weapon = GetPlayerWeaponSlot(client, 4);
		if (weapon > MaxClients && IsValidEntity(weapon) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
				TF2_AddCondition(client, TFCond_SpeedBuffAlly, 120.0);
		}
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

public TF2_OnConditionRemoved(int client, TFCond condition)
{
	if (condition == TFCond_Cloaked)
	{
		int weapon = GetPlayerWeaponSlot(client, 4);
		if (weapon > MaxClients && IsValidEntity(weapon) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
				TF2_RemoveCondition(client, TFCond_SpeedBuffAlly);
		}
	}
}

public TF2Items_OnGiveNamedItem_Post(client, String:classname[], index, level, quality, entity)
{
	if (GetConVarInt(g_sEnabled)) {
		tf2_players[client].shockCharge = 30;
		TF2Attrib_SetByName(entity, "crit mod disabled hidden", 0.00);

		char auth[32];
		if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
		{
			if (!(StrEqual(auth, "STEAM_0:1:101494818")))
			{
				TF2Attrib_SetByName(entity, "boots falling stomp", 1.00);
			}
		}

		switch (index)
		{
			case 163: //The Crit-a-Cola 
			{	
				TF2Attrib_SetByName(entity, "energy buff dmg taken multiplier", 1.25); // Changes the damage taken from +35% to +20%
				TF2Attrib_SetByName(entity, "mod_mark_attacker_for_death", 0.00); // Disable this attribute 
			}
			case 220: //The Shortstop
			{
				TF2Attrib_SetByName(entity, "reload time increased hidden", 1.0);
				TF2Attrib_SetByName(entity, "healing received bonus", 1.20); // Self explanatory
				TF2Attrib_SetByName(entity, "damage force increase", 1.40); // Increased 20% -> 40%
				TF2Attrib_SetByName(entity, "airblast vulnerability multiplier hidden", 1.40); // Increased 20% -> 40%
			} 
			case 317: //The Candy Cane
			{
				TF2Attrib_SetByName(entity, "health from packs increased", 1.40); // Add the backscratche
			}
			case 355: //Fan-o-Wa
			{
				TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 0.80);
				TF2Attrib_SetByName(entity, "single wep deploy time decreased", 0.80);
				TF2Attrib_SetByName(entity, "mark for death", 0.0); // Remove this and handle it ourselves
				TF2CustAttr_SetInt(entity, "mark for death multiple", 1);
			}
			case 772: //Baby Face's Blaster index
			{
				TF2Attrib_SetByName(entity, "lose hype on take damage", 0.0); // Removed
				TF2Attrib_SetByName(entity, "move speed penalty", 0.80); // Increased to 20%
			}
			case 1103: //The Back Scatte
			{
				TF2Attrib_SetByName(entity, "weapon spread bonus", 0.90); // Self explanatory
				TF2Attrib_SetByName(entity, "spread penalty", 1.00); // Remove this attribute
			}
			case 348: //The Sharpened Volcano Fragment
			{
				TF2Attrib_SetByName(entity, "minicrit vs burning player", 1.00); //Add this attribute for lossy
			}
			case 265: //The Sticky Jumpe
			{
				TF2Attrib_SetByName(entity, "max pipebombs decreased", 0.0); // Remove pipebomb restriction
			}
			case 130: //The Scottish Resistance
			{
				TF2Attrib_SetByName(entity, "sticky arm time penalty", 0.4); // Reduce this from 0.8 to 0.4
			}
			case 414: //Liberty Launcher index
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.90); // Increase RoF
			}
			case 1101: //The K.E.Y.E. Jumpe
			{
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.75); // Half of the gunboats protection
			}
			case 133: //The Gunboats
			{
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.25); // Reverted to release
			}
			case 1104: //The Air Strike
			{
				TF2Attrib_SetByName(entity, "Reload time decreased", 0.85); // Increase reload speed
			}
			case 730: //The Beggars
			{
				TF2Attrib_SetByName(entity, "Blast radius decreased", 1.00); // Set explosion radius debuff to 0
			}
			case 128: //The Equalize
			{
				TF2Attrib_SetByName(entity, "dmg from ranged reduced", 0.80); // Less damage from ranged while held
			}
			case 588: //The Pomson 6000
			{
				TF2Attrib_SetByName(entity, "energy weapon penetration", 1.00); // Penetrate targets
				TF2Attrib_SetByName(entity, "subtract victim medigun charge on hit", 1.00);
				TF2Attrib_SetByName(entity, "subtract victim cloak on hit", 1.00);
			}
			case 405, 608: //Demoman boots
			{
				TF2Attrib_SetByName(entity, "move speed bonus shield required", 1.00); // Remove this attribute
				TF2Attrib_SetByName(entity, "move speed bonus", 1.10); // Add this attribute
				//TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property	
			}
			case 327: //The Claidheahm Moh
			{
				TF2Attrib_SetByName(entity, "heal on kill", 25.00); // Re-add this attribute
			}
			case 11, 425, 199: //Heavy's Shotguns
			{
				if(TF2_GetPlayerClass(client) == TFClass_Heavy) {
					TF2Attrib_SetByName(entity, "mult_player_movespeed_active", 1.10);
				}
			}
			case 239, 1084, 1100: //The Gloves of Running Urgently
			{
				TF2Attrib_SetByName(entity, "mod_maxhealth_drain_rate", 0.0); //Disable max health drain
				TF2Attrib_SetByName(entity, "damage penalty", 0.70); //Decrease damage by 30%
				TF2Attrib_SetByName(entity, "self mark for death", 1.00); //Mark for death
			}
			case 310: // The Warrior's Spirit
			{
				TF2Attrib_SetByName(entity, "dmg taken increased", 1.00); // Remove overall vuln
				TF2Attrib_SetByName(entity, "dmg from melee increased", 1.30); // Replace with melee vuln
				TF2Attrib_SetByName(entity, "single wep holster time increased", 1.50); // Increase holster time
			}
			case 426: //The Eviction Notice
			{
				TF2Attrib_SetByName(entity, "mod_maxhealth_drain_rate", 0.0); // Disable max health drain
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.40); // Fire 60% faste
			}
			case 811, 832: //The Huo Long Heate
			{
				TF2Attrib_SetByName(entity, "damage penalty", 1.00); // Remove the damage penalty
			}
			case 41: // The Natascha
			{
				TF2Attrib_SetByName(entity, "slow enemy on hit", 0.0); // Remove slowdown
				TF2Attrib_SetByName(entity, "aiming movespeed increased", 1.15); // Increased move speed when revved
			}
			case 998: //The Vaccinato
			{
				TF2Attrib_SetByName(entity, "ubercharge rate penalty", 0.05);
			}
			case 1144, 131, 1099, 406: //Demoshields
			{
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.35); // Reduce self inflicted damage by 65%, this is a listed buff
				TF2Attrib_SetByName(entity, "dmg taken from fire reduced", 0.90); // Reduce this attribute
				TF2Attrib_SetByName(entity, "dmg taken from blast reduced", 0.90); // Reduce this attribute
			}
			case 528: // Short Circuit
			{
				TF2CustAttr_SetInt(entity, "taser damage becomes metal", 1); // Damage dealt with primary fire becomes metal
				TF2CustAttr_SetFloat(entity, "mult metal from carts", 0.25); // Reduced metal from carts
			}
			// Nerf section ends here
			case 609: //Scottish Handshake
			{
				TF2Attrib_SetByName(entity, "fire rate penalty", 1.20);
				TF2Attrib_SetByName(entity, "crit mod disabled", 0.00);
				TF2Attrib_SetByName(entity, "mod crit while airborne", 1.00);
			}
			/*case 442: //The Righteous Bison
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.55); // Increase firing rate by 45%
			}*/ // Removal candidate
			case 38, 457, 1000: //Axtinguisher, Plummeter, Festive Axtinguisher indexes
			{
				TF2Attrib_SetByName(entity, "attack_minicrits_and_consumes_burning", 0.0); // Remove the base properties
				TF2Attrib_SetByName(entity, "crit vs burning players", 1.0); // Self explanatory
				TF2Attrib_SetByName(entity, "dmg penalty vs nonburning", 0.50); // Self explanatory
				TF2Attrib_SetByName(entity, "damage penalty", 1.00); // Sets the damage penalty to 0%
			}
			case 1181: //The Hot Hand
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.50); // Increase firing rate
			}
			case 1179: //The Thermal Thruste
			{
				TF2Attrib_SetByName(entity, "thermal_thruster_air_launch", 1.0); // Able to re-launch while already in-flight 
				TF2Attrib_SetByName(entity, "dmg taken increased", 1.15); // Take 15% more damage
			}
			case 351: //The Detonato
			{
				TF2Attrib_SetByName(entity, "blast dmg to self increased", 0.75); // Halve the blast damage penalty
			}
			case 215: // The Degrease
			{
				TF2Attrib_SetByName(entity, "deploy time decreased", 0.65); // Modify all swap speeds
				TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 1.00); // Remove the holster bonus
				TF2Attrib_SetByName(entity, "single wep deploy time decreased", 1.00); // Remove the deploy bonus
			}
			case 595: // The Manmelte
			{
				TF2Attrib_SetByName(entity, "damage bonus", 1.20);
			}
			case 1178: // The Dragon's Fury
			{
				TF2CustAttr_SetInt(entity, "airblast jump", 1);
			}
			case 17, 204, 36, 412: // Syringe guns
			{
				TF2Attrib_SetByName(entity, "add uber charge on hit", 0.0125); // 1.25% uber per projectile hit
				TF2CustAttr_SetInt(entity, "holster reload", 40);
			}
			case 171: // The Tribalman's Shiv
			{
				TF2Attrib_SetByName(entity, "damage penalty", 0.75);
			}
			case 751: // The Cleaner's Carbine
			{
				TF2Attrib_SetByName(entity, "critboost on kill", 2.0); // Self explanatory
			}
			case 1098: // The Classic
			{
				TF2Attrib_SetByName(entity, "sniper charge per sec", 1.20) // Increased by 20%
			}
			case 460: // The Enforce
			{
				TF2Attrib_SetByName(entity, "weapon spread bonus", 0.60); // 40% more accurate
				TF2Attrib_SetByName(entity, "damage bonus while disguised", 1.00); // Remove this bonus
				TF2Attrib_SetByName(entity, "damage bonus", 1.20);
			}
			case 225, 574: // Your Eternal Reward
			{
				TF2Attrib_SetByName(entity, "mult cloak meter consume rate", 1.00); // Self explanatory
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.90); // Increase RoF
			}
			case 461: // The Big Earne
			{
				TF2Attrib_SetByName(entity, "add cloak on kill", 50.0); // Increase the cloak gain from 30 to 50
				TF2Attrib_SetByName(entity, "max health additive penalty", -20.0); // Change the penalty from -25 to 20
			}
			case 810, 831: // Red-Tape sappers
			{
				TF2Attrib_SetByName(entity, "sapper damage penalty", 0.30); // Change this from 100% to 70%
			}
			case 155: // Southern Hospitality
			{
				TF2Attrib_SetByName(entity, "metal regen", 15.00); // This activates every 5 seconds, so let's use 15
				TF2Attrib_SetByName(entity, "damage bonus", 1.10);
			}
			case 56, 1092, 1005: // Bow & Arrows / Huntsman
			{
				TF2Attrib_SetByName(entity, "max health additive bonus", 15.00); // Self explanatory
				TF2CustAttr_SetInt(entity, "wall climb enabled", 1);
			}
		}
	}
}

bool ValidateAndNullCheck(MemoryPatch patch) {
		return patch.Validate() && patch != null;
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

static void StartHealTimer()
{
	if (g_hHealTimer == INVALID_HANDLE)
	{
		g_hHealTimer = CreateTimer(1.0, Timer_HealTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

static void StopHealTimer()
{
	if (g_hHealTimer != INVALID_HANDLE)
	{
		KillTimer(g_hHealTimer);
		g_hHealTimer = INVALID_HANDLE;
	}
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
