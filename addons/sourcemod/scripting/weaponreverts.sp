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
// Addplayerhealth was made by chdata, I'm not able to find it online anymore so I'll rehost it in this repo

#define ACC_MAX_DIST        768.0
#define ACC_THRESH_NEAR       38.0
#define ACC_THRESH_FAR        10.0
#define ACC_STREAK_TARGET      2

#define ACC_EXPLODE_DAMAGE   50.0
#define ACC_EXPLODE_RADIUS   180.0
#define ACC_EXPLODE_SOUND   "ambient/fire/gascan_ignite1.wav"
#define ACC_NOTIFY_SOUND "vo/taunts/pyro/pyro_taunt_rps_exert_21.mp3"
#define ACC_NOTIFY_2 "vo/taunts/pyro/pyro_taunt_rps_exert_23.mp3"
#define SOUND_ARROW_HEAL "weapons/fx/rics/arrow_impact_crossbow_heal.wav"
#define SOUND_NEON_SIGN "weapons/neon_sign_hit_world_02.wav"
#define SOUND_DISPENSER_METAL "weapons/dispenser_generate_metal.wav"
#define SOUND_POMSON_DRAIN "weapons/drg_pomson_drain_01.wav"
#define SOUND_FLAME_OUT "player/flame_out.wav"

#define SPROKE_ATTR_NAME        "sproke attribute"
#define SPROKE_PRIMARY_ATTR		"mod max primary clip override"
#define SPROKE_ALT_ATTR		"Reload time decreased"
#define SPROKE_PRIMARY_FACTOR     -1.0
#define SPROKE_ALT_FACTOR     0.75
#define SPROKE_PARTICLE_RED      "soldierbuff_red_buffed"
#define SPROKE_PARTICLE_BLUE     "soldierbuff_blue_buffed"
#define BURP_SOUND      "vo/burp02.mp3"

#define TF2_JUMP_NONE 0
#define TF2_JUMP_ROCKET_START 1
#define TF2_JUMP_ROCKET 2
#define TF2_JUMP_STICKY 3

tf2_player tf2_players[MAXPLAYERS + 1];

enum struct tf2_player
{
	int jump_status;
	int lastAfterburnDamage;
	int scytheWeapon;
	int shockCharge;
	int healCount;
	float lastUber;
	int engiMetal;
	int accuracyStreak;
	Handle sprokeTimer;
	int sprokePrimaryRef;
	int sprokeParticleRef;
	int sprokeClipRecord;
	bool holdingJump;
}

Handle g_SDKGetMaxClip1 = null;
int g_iMetalOffset = -1;
bool g_bWarnedMetalOffset = false;

#include <weaponreverts>
 
ConVar g_sEnabled;
MemoryPatch patch_RevertCozyCamper_FlinchNerf;
Handle g_hHealTimer = INVALID_HANDLE;

MemoryPatch patch_Wrangler_CustomShieldRepair;
MemoryPatch patch_Wrangler_CustomShieldShellRefill;
MemoryPatch patch_Wrangler_CustomShieldRocketRefill;
MemoryPatch patch_Wrangler_CustomShieldDamageTaken;
MemoryPatch patch_Wrangler_RescueRanger_CustomShieldRepair;
float g_flWranglerCustomShieldValue = 0.75;

DynamicDetour dhook_CTFPlayer_CalculateMaxSpeed;

public Plugin myinfo =
{
	name = "WeaponReverts",
	author = "Hombre, Huutti, Utsuho",
	description = "Weapon changes plugin for Kogasatopia, very specific, this includes custom attribute code such as recoil jumping",
	version = "5.0",
	url = "https://kogasa.tf"
};

stock void ResetClientArrays(int client)
{
    if (client <= 0 || client > MaxClients) return;
    tf2_players[client].lastAfterburnDamage = 0;
    tf2_players[client].scytheWeapon = 0;
    tf2_players[client].shockCharge = 30;
    tf2_players[client].healCount = 0;
    tf2_players[client].lastUber = 0.0;
    tf2_players[client].engiMetal = 0;
	tf2_players[client].accuracyStreak = 0;
	tf2_players[client].jump_status = TF2_JUMP_NONE;
	tf2_players[client].holdingJump = false;
    if (tf2_players[client].sprokeTimer != null)
    {
        KillTimer(tf2_players[client].sprokeTimer);
        tf2_players[client].sprokeTimer = null;
    }
    Sproke_ClearEffect(client, true, false);
}

public void OnPluginStart() {
	g_sEnabled = CreateConVar("reverts_enabled", "1", "Enable/Disable the plugin");
	if (GetConVarInt(g_sEnabled)) {
		g_iMetalOffset = FindSendPropInfo("CTFPlayer", "m_iAmmo");
	// This is used to ignore clients without the m_iAmmo netprop

		PrecacheSound(SOUND_ARROW_HEAL, true);
		PrecacheSound(SOUND_NEON_SIGN, true);
		PrecacheSound(ACC_EXPLODE_SOUND, true);
		PrecacheSound(ACC_NOTIFY_SOUND, true);
		PrecacheSound(ACC_NOTIFY_2, true);
		PrecacheSound(BURP_SOUND, true);

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
				SDKHook(i, SDKHook_OnTakeDamagePost, Accuracy_OnTakeDamagePost);
			}
		}

		HookAllBuildings();
		HookEvent("player_builtobject", Event_PlayerBuiltObject);

		HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
		HookEvent("post_inventory_application", Event_Resupply, EventHookMode_Post);
		HookEvent("player_spawn", OnPlayerSpawn);

		// Blast jumping hooks

		HookEvent("rocket_jump", 				Event_TF2RocketJump);
		HookEvent("rocket_jump_landed", 	 	Event_TF2JumpLanded);
		HookEvent("sticky_jump", 				Event_TF2StickyJump);
		HookEvent("sticky_jump_landed", 	 	Event_TF2JumpLanded);

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
		if (dhook_CTFPlayer_CalculateMaxSpeed == null) SetFailState("Failed to create dhook_CTFPlayer_CalculateMaxSpeed");
		dhook_CTFPlayer_CalculateMaxSpeed.Enable(Hook_Post, CalculateMaxSpeed);

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

public void OnMapStart() {
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
		SDKHook(client, SDKHook_OnTakeDamagePost, Accuracy_OnTakeDamagePost);
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

	if (StrEqual(class, "tf_projectile_energy_ring")) {
		SDKHook(entity, SDKHook_SpawnPost, OnEnergyRingSpawnPost);
	}
}

static bool Accuracy_IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static bool Accuracy_IsValidShotgun(int weapon)
{
    return (weapon != -1 && IsValidEntity(weapon) && TF2CustAttr_GetInt(weapon, "flame shotgun attributes") != 0);
}

static Action OnBuildingDamaged(int entity, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!IsValidEntity(entity) || attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker))
		return Plugin_Continue;

	int weapon = GetEntPropEnt(attacker, Prop_Data, "m_hActiveWeapon");
	if (weapon <= 0 || !IsValidEntity(weapon))
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

static float Accuracy_RequiredDamageForDistance(float dist)
{
    if (dist < 0.0) dist = 0.0;
    if (dist > ACC_MAX_DIST) dist = ACC_MAX_DIST;

    float t = dist / ACC_MAX_DIST;
    return ACC_THRESH_NEAR + (ACC_THRESH_FAR - ACC_THRESH_NEAR) * t;
}

static bool Accuracy_IsAccurateHit(float damage, float dist)
{
	return (damage >= Accuracy_RequiredDamageForDistance(dist));
}

static void Accuracy_Explode(int attacker, int victim, float position[3], float damage, float radius)
{
    int bomb = CreateEntityByName("tf_generic_bomb");
    if (bomb == -1)
        return;

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

public Action Accuracy_Timer_RemoveChargeCount(Handle timer, int client)
{
    if (!Accuracy_IsValidClient(client))
        return Plugin_Stop;

	if (tf2_players[client].accuracyStreak > 0)
		tf2_players[client].accuracyStreak -= 1;

    return Plugin_Stop;
}

public void Accuracy_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage,
                                      int damagetype, int weapon, const float damageForce[3],
                                      const float damagePosition[3])
{
    if (!Accuracy_IsValidClient(attacker) || !Accuracy_IsValidClient(victim) || attacker == victim)
        return;
    if (!Accuracy_IsValidShotgun(weapon))
        return;

    float eye[3], pos[3];
    GetClientEyePosition(attacker, eye);
    GetClientAbsOrigin(victim, pos);
	pos[2] += Accuracy_GetClassSubtractionValue(victim);

    float dist = GetVectorDistance(eye, pos);
	if (dist > ACC_MAX_DIST) return;

    bool accurate = Accuracy_IsAccurateHit(damage, dist);
    int remainingHealth = IsPlayerAlive(victim) ? GetClientHealth(victim) : 0;
    if (remainingHealth > 0 && remainingHealth <= RoundToCeil(damage))
        remainingHealth = 0; // treat as lethal if the incoming damage equals remaining HP
    bool lethal = (remainingHealth <= 0);

    if (accurate || lethal)
    {
        if (lethal)
        {
			tf2_players[victim].accuracyStreak = ACC_STREAK_TARGET;
        }
        else
        {
			tf2_players[victim].accuracyStreak++;
        }
        CreateTimer(4.0, Accuracy_Timer_RemoveChargeCount, victim, TIMER_FLAG_NO_MAPCHANGE);
	if (tf2_players[victim].accuracyStreak >= ACC_STREAK_TARGET || lethal)
        {
            float boomPos[3];
            GetClientAbsOrigin(victim, boomPos);
            boomPos[2] -= Accuracy_GetClassSubtractionValue(victim);

            TF2_IgnitePlayer(victim, attacker, 4.0);
            Accuracy_Explode(attacker, victim, boomPos, ACC_EXPLODE_DAMAGE, ACC_EXPLODE_RADIUS);
			EmitAmbientSound(ACC_NOTIFY_2, eye, attacker, SNDLEVEL_NORMAL);

			tf2_players[victim].accuracyStreak = 0;
        } else EmitAmbientSound(ACC_NOTIFY_SOUND, eye, attacker, SNDLEVEL_NORMAL);
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
	if (client > 0) {
		tf2_players[client].jump_status = TF2_JUMP_NONE;
	}
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int userId = event.GetInt("userid");
    int client = GetClientOfUserId(userId);

	if (tf2_players[client].sprokeTimer != null)
	{
		Sproke_ClearEffect(client, false, true);
		return Plugin_Changed;
	}

	int attackerId = event.GetInt("attacker");
	int attacker = GetClientOfUserId(attackerId);
	if (attacker == 0 || client == 0) return Plugin_Continue;

	if (tf2_players[client].shockCharge != 30) 
	tf2_players[client].shockCharge = 30;
	if (TF2_GetPlayerClass(client) == TFClassType:TFClass_Medic) {
		if (GetEntProp(GetPlayerWeaponSlot(client, 2), Prop_Send, "m_iItemDefinitionIndex") == 173) {
			tf2_players[client].lastUber = GetEntPropFloat(GetPlayerWeaponSlot(client, 1), Prop_Send, "m_flChargeLevel");
		}
	}
	if (tf2_players[attacker].scytheWeapon != 0 && (TF2_IsPlayerInCondition(client, TFCond_OnFire))) {
		tf2_players[attacker].healCount += 4;
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

public Action Event_Resupply(Event event, const char[] name, bool dontBroadcast) {
	int userId = event.GetInt("userid");
	int client = GetClientOfUserId(userId);

	if (tf2_players[client].shockCharge != 30)
	{
		tf2_players[client].shockCharge = 29; // The 29 is for visual effect
		return Plugin_Changed;
	}

	int watch = GetPlayerWeaponSlot(client, 4);
	if ((watch > -1) && TF2CustAttr_GetInt(watch, "escampette attributes") != 1.0)
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

    int medigun = GetPlayerWeaponSlot(client, 1);
    int melee = GetPlayerWeaponSlot(client, 2);

    // Validate weapon entities before using them
    if (medigun == -1 || melee == -1)
        return Plugin_Continue;

    // Check if melee weapon index is 173
    if (GetEntProp(melee, Prop_Send, "m_iItemDefinitionIndex") == 173)
    {
        float charge = GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel");

        if (charge < 0.2)
        {
		if (tf2_players[client].lastUber > 0.2)
			tf2_players[client].lastUber = 0.2;

		SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", tf2_players[client].lastUber);
		tf2_players[client].lastUber = 0.0;
            return Plugin_Changed;
        }
    }

    return Plugin_Continue;
}

#define FSOLID_USE_TRIGGER_BOUNDS 0x80
void OnEnergyRingSpawnPost(int entity) {
	float maxs[3] = { 2.0, 2.0, 10.0 };
	float mins[3] = { -2.0, -2.0, -10.0 };

	SetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
	SetEntPropVector(entity, Prop_Send, "m_vecMins", mins);

	SetEntProp(entity, Prop_Send, "m_usSolidFlags", (GetEntProp(entity, Prop_Send, "m_usSolidFlags") | FSOLID_USE_TRIGGER_BOUNDS));
	SetEntProp(entity, Prop_Send, "m_triggerBloat", 24);
}

public Action TF2_CalcIsAttackCritical(client, weapon, String:weaponname[], &bool:result) {
    if (!IsClientInGame(client) || !IsValidEntity(weapon))
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

	int health = GetClientHealth(client);
	float rounded = float(RoundFloat(float(health) * 0.10));
	SDKHooks_TakeDamage(client, client, client, rounded, DMG_CLUB, 0);

    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
    return Plugin_Changed;
}

// Attribute timer
public Action Timer_HealTimer(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
			// Handle afterburn heal
		if (tf2_players[client].healCount > 0 && IsPlayerAlive(client) && 
			GetClientHealth(client) < TF2_GetPlayerMaxHealth(client) && 
			CheckScythe(client) == 2) {
			tf2_players[client].healCount--;
				AddPlayerHealth(client, tf2_players[client].lastAfterburnDamage, 1.0, false, true);
				EmitSoundToClient(client, SOUND_DISPENSER_METAL);
			}
			// Handle shock charge refill
		else if (tf2_players[client].shockCharge < 30) {
			tf2_players[client].shockCharge++;
			if (tf2_players[client].shockCharge % 2 == 0 || tf2_players[client].shockCharge == 1) {
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
    float rampup = (distance - 300.0) * 0.001; // scaling factor
    rampup = clamp(rampup, 0.0, 1.0);          // cap at +100%

    float calculated = 1.0 + rampup;           // final multiplier

    return calculated;
}*/

// Holster reload code, hard coded for clip size 40 and 2, can be rewritten as an attribute in the future
public Action OnWeaponSwitch(client, weapon)
{	
	if (!GetConVarInt(g_sEnabled)) return Plugin_Continue;
	// only do anything if the player is a medic or pyro
	TFClassType playerClass = TF2_GetPlayerClass(client);
        if (playerClass == TFClassType:TFClass_Medic)
        {
			char classname[64];
			GetEntityClassname(weapon, classname, sizeof(classname));
			if (StrEqual(classname, "tf_weapon_syringegun_medic", false))
            {
                int clip = GetClip(weapon);
                int reserve = GetAmmo_Weapon(weapon);
                int missing = 40 - clip;

                int toReload = (missing < reserve) ? missing : reserve;

                if (toReload > 0)
                {
                    SetClip_Weapon(weapon, clip + toReload);
                    SetAmmo_Weapon(weapon, reserve - toReload);
                    return Plugin_Changed;
                }
	    }
	} else if (playerClass == TFClassType:TFClass_Pyro) {
		if ((weapon != -1) && (TF2CustAttr_GetInt(weapon, "twin barrel attributes") != 0))  {
			int clip = GetClip(weapon);
			int reserve = GetAmmo_Weapon(weapon);
			int missing = 2 - clip;

			int toReload = (missing < reserve) ? missing : reserve;
			if (toReload > 0)
			{
				SetClip_Weapon(weapon, clip + toReload);
				SetAmmo_Weapon(weapon, reserve - toReload);
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}


public Action OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype, &weapon, Float:damageForce[3], Float:damagePosition[3], damagecustom)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client)) return Plugin_Continue;
	if (attacker < 1 || weapon < 1) return Plugin_Continue;

	bool attackerIsPlayer = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker));

	if (attackerIsPlayer && IsValidEntity(weapon) && weapon > MaxClients)
	{
        int duelAttr = TF2CustAttr_GetInt(weapon, "duel declared");
        if (duelAttr != 0)
        {
            int victimWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
            if (IsValidEntity(victimWeapon) && TF2CustAttr_GetInt(victimWeapon, "duel declared") != 0)
			{
				if (GetClip(weapon) == 6)
				{
					damage = 100.0;
					damagetype |= DMG_CRIT;
					return Plugin_Changed;
				}
			}
		}
	}

	new wepindex = (IsValidEntity(weapon) && weapon > MaxClients ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1);
	if (wepindex == 442 || wepindex == 588)  // Pomson, bison
	{
		// Remove bullet damage type (ignores Vaccinator bullet resist) and restore knockback
		damagetype &= ~(DMG_BULLET | DMG_PREVENT_PHYSICS_FORCE);
		// Enable sonic flag so ranged resist attrib still works
		damagetype |= DMG_SONIC;
		return Plugin_Changed;
	}
	int watch = GetPlayerWeaponSlot(client, 4);
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
	} else if ((watch != -1) && (TF2CustAttr_GetInt(watch, "escampette attributes") != 0)) { // TF2C Custom Attribute for Spy
		if (TF2_IsPlayerInCondition(client, TFCond_Cloaked)) { // if cloaked
			float flCloakMeter = GetEntPropFloat(client, Prop_Send, "m_flCloakMeter");
			flCloakMeter -= 10;
			SetEntPropFloat(client, Prop_Send, "m_flCloakMeter", flCloakMeter);
			EmitAmbientSound(SOUND_POMSON_DRAIN, damagePosition, client, SNDLEVEL_NORMAL);
			return Plugin_Changed;
		}
	} else if (CheckIfAfterburn(damagecustom)) {
	tf2_players[attacker].scytheWeapon = CheckScythe(attacker);
	if (tf2_players[attacker].scytheWeapon != 0) {
			int heal = RoundToNearest(damage);
		tf2_players[attacker].lastAfterburnDamage = heal;
			if (!IsPlayerAlive(attacker)) {
				TF2_RemoveCondition(client, TFCond_OnFire);
				EmitAmbientSound(SOUND_FLAME_OUT, damagePosition, client, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.2, SNDPITCH_NORMAL);
				return Plugin_Changed;
		} else if (tf2_players[attacker].scytheWeapon == 2) {
				AddPlayerHealth(attacker, heal, 1.0, false, true);
				return Plugin_Changed;
			}
		}
	} else if ((weapon != -1) && (TF2CustAttr_GetInt(weapon, "twin barrel attributes") != 0)) {
		// This code is to launch targets, velocity needs to be >250 for any effect to occur
		// Hopefully a better way to lift a target with damage can be located in the future, this feels fine for now
		float vecAngles[3];
		float vecVelocity[3];

		// Get the attacker's aim direction
		GetClientEyeAngles(attacker, vecAngles);

		// Get the client's (target's) current velocity
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vecVelocity);

		// Convert angles to radians
		vecAngles[0] = DegToRad(-1.0 * vecAngles[0]);
		vecAngles[1] = DegToRad(vecAngles[1]);

                if (damage >= 40.0) vecVelocity[2] = 251.0;

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vecVelocity);
		return Plugin_Changed;
	} else if ((weapon != -1) && (TF2CustAttr_GetInt(weapon, "shock therapy attributes") != 0)) {
		damage = float(tf2_players[attacker].shockCharge * 100 / 30);
		tf2_players[attacker].shockCharge = 0;
		EmitAmbientSound(SOUND_NEON_SIGN, damagePosition, client, SNDLEVEL_NORMAL);
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

public Action OnTraceAttack(victim, &attacker, &inflictor, &Float:damage, &damagetype, &ammotype, hitbox, hitgroup)
{
	// We use this function to check if you've hit an ally with the TF2C Shock Therapy
	if (!IsValidEdict(attacker) || !IsValidClient(attacker) || !IsPlayerAlive(attacker) || attacker <= 0)
	{
		return Plugin_Continue;
	}

	if (GetClientTeam(victim) == GetClientTeam(attacker)) {
		if (CheckShock(attacker) == 2)
		{	
			int buff = OverhealStruct(victim);
			int health = GetClientHealth(victim);
			if (health < buff) {
				int medigun = GetPlayerWeaponSlot(attacker, 1);
				float pos[3];
				GetClientAbsAngles(victim, pos);
				TF2_SetHealth(victim, buff);
				tf2_players[attacker].shockCharge = 0;
				EmitAmbientSound(SOUND_ARROW_HEAL, pos, victim, SNDLEVEL_NORMAL);
				float uber = (float((buff - health) / 5000) + (GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel")));
				SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", uber);
			}
		}
	}
	return Plugin_Continue;
} 

public Action OnPlayerRunCmd(
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
}

MRESReturn CalculateMaxSpeed(int entity, DHookReturn returnValue) {
	if (
		entity >= 1 &&
		entity <= MaxClients &&
		IsValidEntity(entity) &&
		IsClientInGame(entity)
	) {
		int primary = GetPlayerWeaponSlot(entity, TFWeaponSlot_Primary);

		if (primary != -1 && TF2CustAttr_GetInt(primary, "original babyface attributes") == 1) {
			// Original BFB proper speed application
			float boost = GetEntPropFloat(entity, Prop_Send, "m_flHypeMeter");
			returnValue.Value = view_as<float>(returnValue.Value) * ValveRemapVal(boost, 0.0, 99.0, 1.0, 1.383);
			return MRES_Override;
		}
	}
	return MRES_Ignored;
}

// Gas passer buff
public TF2_OnConditionAdded(int client, TFCond condition)
{
	if (condition == TFCond_Gas) //If gas is applied
	{
		TF2_AddCondition(client, TFCond_Jarated, 6.0); //Apply Jarate for 6 seconds
	}

	if (condition == TFCond_Cloaked)
	{
		int weapon = GetPlayerWeaponSlot(client, 4);
		if ( (weapon > -1) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
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
}

public TF2_OnConditionRemoved(int client, TFCond condition)
{
	if (condition == TFCond_Cloaked)
	{
		int weapon = GetPlayerWeaponSlot(client, 4);
		if ((weapon > -1) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
				TF2_RemoveCondition(client, TFCond_SpeedBuffAlly);
		}
	}
}

public TF2Items_OnGiveNamedItem_Post(client, String:classname[], index, level, quality, entity)
{
	if (GetConVarInt(g_sEnabled)) {
	tf2_players[client].shockCharge = 30;
		// Attach the `m_bValidatedAttachedEntity` property to every weapon/cosmetic.
		// ^ This allows custom weapons/weapons with changed models to be seen.
		//if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
		//{
			//SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
		//}
		// This was moved to my fork of CWX

		// I disable random melee crits for Sniper here, tf_weapon_criticals 0 is default for me
		if (TF2_GetPlayerClass(client) == TFClassType:TFClass_Sniper)
		{
			TF2Attrib_SetByName(entity, "crit mod disabled hidden", 0.0);
		}

		// I add the falling stomp to all players; this is an exception for someone who hates the SFX
		char auth[32];
		if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)))
		{
			if (!(StrEqual(auth, "STEAM_0:1:101494818")))
			{
				TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property
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
				TF2Attrib_SetByName(entity, "damage force increase", 1.40); // Increased 20% -> 80%
				TF2Attrib_SetByName(entity, "airblast vulnerability multiplier hidden", 1.40); // Increased 20% -> 80%
			} 
			case 317: //The Candy Cane
			{
				TF2Attrib_SetByName(entity, "health from packs increased", 1.40); // Add the backscratcher
			}
	    	case 355: //Fan-o-War
	        {
	            TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 0.80);
	            TF2Attrib_SetByName(entity, "single wep deploy time decreased", 0.80);
	        }
			case 772: //Baby Face's Blaster index
			{
				TF2Attrib_SetByName(entity, "lose hype on take damage", 0.0); // Removed
				TF2Attrib_SetByName(entity, "move speed penalty", 0.80); // Increased to 15%
			}
			case 1103: //The Back Scatter
			{
				TF2Attrib_SetByName(entity, "weapon spread bonus", 0.90); // Self explanatory
				TF2Attrib_SetByName(entity, "spread penalty", 1.00); // Remove this attribute
			}
			case 348: //The Sharpened Volcano Fragment
			{
				TF2Attrib_SetByName(entity, "minicrit vs burning player", 1.00); //Add this attribute for lossy
			}
			case 265: //The Sticky Jumper
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
			case 1101: //The K.E.Y.E. Jumper
			{
				//TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.75); // Half of the gunboats protection
			}
			case 1104: //The Air Strike
			{
				TF2Attrib_SetByName(entity, "Reload time decreased", 0.85); // Increase reload speed
			}
			case 730: //The Beggars
			{
				TF2Attrib_SetByName(entity, "Blast radius decreased", 1.00); // Set explosion radius debuff to 0
			}
	    	case 128: //The Equalizer
	        {
	            TF2Attrib_SetByName(entity, "dmg from ranged reduced", 0.80); // Less damage from ranged while held
	        }
			case 588: //The Pomson 6000
			{
				TF2Attrib_SetByName(entity, "energy weapon penetration", 1.00); // Penetrate targets
			}
			case 405, 608: //Demoman boots
			{
				TF2Attrib_SetByName(entity, "move speed bonus shield required", 1.00); // Remove this attribute
				TF2Attrib_SetByName(entity, "move speed bonus", 1.10); // Add this attribute
				//TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property	
			}
			case 327: //The Claidheahm Mohr
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
				TF2Attrib_SetByName(entity, "dmg taken increased", 1.00); // Remove vuln
				TF2Attrib_SetByName(entity, "heal on hit for slowfire", 20.00); // 20 health on hit
				TF2Attrib_SetByName(entity, "provide on active", 0.0); // Provide on active 0
				TF2Attrib_SetByName(entity, "max health additive penalty", -20.00); // 20 less max health
				TF2Attrib_SetByName(entity, "heal on kill", 0.0);
			}
			case 426: //The Eviction Notice
			{
				TF2Attrib_SetByName(entity, "mod_maxhealth_drain_rate", 0.0); // Disable max health drain
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.40); // Fire 60% faster
			}
			case 811, 832: //The Huo Long Heater
			{
				TF2Attrib_SetByName(entity, "damage penalty", 1.00); // Remove the damage penalty
			}
			case 41: // The Natascha
			{
				TF2Attrib_SetByName(entity, "slow enemy on hit", 0.0);
				TF2Attrib_SetByName(entity, "speed_boost_on_hit_enemy", 1.00);
			}
			// These are the secret nerfs for the vaccinator, shields and short circuit
			// Sometimes I delete these but I feel they'll soon be official
			// The usual policy is to only buff things but because the Zesty server bans weapons I feel like I can do this + people would like it
			case 998: //The Vaccinator
			{
				TF2Attrib_SetByName(entity, "mult_dmgtaken_active", 1.20);
			}
			case 1144, 131, 1099, 406: //Demoshields
			{
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.35); // Reduce self inflicted damage by 65%, this is a listed buff
				TF2Attrib_SetByName(entity, "dmg taken from fire reduced", 0.90); // Reduce this attribute
				TF2Attrib_SetByName(entity, "dmg taken from blast reduced", 0.90); // Reduce this attribute
			}
			case 528: // Short Circuit
			{
				TF2Attrib_SetByName(entity, "no metal from dispensers while active", 1.00); // No hugging the cart
			}
			// Nerf section ends here
            case 609: //Scottish Handshake
            {
                TF2Attrib_SetByName(entity, "fire rate penalty", 1.20);
                TF2Attrib_SetByName(entity, "crit mod disabled", 0.00);
				TF2Attrib_SetByName(entity, "mod crit while airborne", 1.00);
            }
			case 442: //The Righteous Bison
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.55); // Increase firing rate by 40%
			}
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
			case 1179: //The Thermal Thruster
			{
				TF2Attrib_SetByName(entity, "thermal_thruster_air_launch", 1.0); // Able to re-launch while already in-flight 
			}
			case 351: //The Detonator
			{
				TF2Attrib_SetByName(entity, "blast dmg to self increased", 0.75); // Halve the blast damage penalty
			}
			case 215: //The Degreaser
			{
				TF2Attrib_SetByName(entity, "deploy time decreased", 0.65); // Modify all swap speeds
				TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 1.00); // Remove the holster bonus
				TF2Attrib_SetByName(entity, "single wep deploy time decreased", 1.00); // Remove the deploy bonus
			}
			case 1178: // The Dragon's Fury
			{
				TF2CustAttr_SetInt(entity, "airblast jump", 1);
			}
			case 17, 204, 36, 412: // Syringe guns
			{
				TF2Attrib_SetByName(entity, "add uber charge on hit", 0.0125); // 1.25% uber per projectile hit
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
			case 460: // The Enforcer
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
			case 461: // The Big Earner
			{
				TF2Attrib_SetByName(entity, "add cloak on kill", 50.0); // Increase the cloak gain from 30 to 50
				TF2Attrib_SetByName(entity, "max health additive penalty", -20.0); // Change the penalty from -25 to 20
			}
			case 810, 831: // Red-Tape sappers
			{
				TF2Attrib_SetByName(entity, "sapper damage penalty", 0.30); // Change this from 100% to 30%
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
