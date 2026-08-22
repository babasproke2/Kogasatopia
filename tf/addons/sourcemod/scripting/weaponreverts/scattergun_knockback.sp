#define SCATTERGUN_KNOCKBACK_MIN_DAMAGE 30.0
#define SCATTERGUN_KNOCKBACK_MAX_DISTANCE_SQ 160000.0
#define SCATTERGUN_KNOCKBACK_DEFAULT_MULTIPLIER 3.0
#define SCATTERGUN_KNOCKBACK_MAX_FORCE 1000.0
#define SCATTERGUN_KNOCKBACK_JUMP_SPEED 268.3281573
#define SCATTERGUN_KNOCKBACK_STUN_TIME 0.3
#define SCATTERGUN_REFERENCE_HULL_VOLUME (48.0 * 48.0 * 82.0)

// These constants and force calculations mirror Valve's CTFScatterGun path.
float g_fScattergunPendingDamage[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_iScattergunPendingTick[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_iScattergunPendingWeaponRef[MAXPLAYERS + 1][MAXPLAYERS + 1];
bool g_bScattergunFrameQueued[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_iScattergunKnockbackUserId[MAXPLAYERS + 1];

static void ScattergunKnockback_ResetPair(int victim, int attacker)
{
	g_fScattergunPendingDamage[victim][attacker] = 0.0;
	g_iScattergunPendingTick[victim][attacker] = 0;
	g_iScattergunPendingWeaponRef[victim][attacker] = INVALID_ENT_REFERENCE;
	g_bScattergunFrameQueued[victim][attacker] = false;
}

void ScattergunKnockback_ResetClient(int client)
{
	if (client < 1 || client > MaxClients)
		return;

	g_iScattergunKnockbackUserId[client] = 0;
	for (int other = 1; other <= MaxClients; other++)
	{
		ScattergunKnockback_ResetPair(client, other);
		ScattergunKnockback_ResetPair(other, client);
	}
}

static bool ScattergunKnockback_IsPushImmune(int victim)
{
	if (TF2_IsPlayerInCondition(victim, TFCond_MegaHeal)
		|| TF2_IsPlayerInCondition(victim, TFCond_ImmuneToPushback)
		|| TF2_IsPlayerInCondition(victim, TFCond_RuneKnockout))
	{
		return true;
	}

	return TF2_GetPlayerClass(victim) == TFClass_Heavy
		&& TF2_IsPlayerInCondition(victim, TFCond_Slowed)
		&& TF2Attrib_HookValueInt(0, "spunup_push_force_immunity", victim) != 0;
}

static void ScattergunKnockback_GetWorldCenter(int client, float center[3])
{
	float mins[3];
	float maxs[3];
	GetClientAbsOrigin(client, center);
	GetClientMins(client, mins);
	GetClientMaxs(client, maxs);

	for (int axis = 0; axis < 3; axis++)
	{
		center[axis] += (mins[axis] + maxs[axis]) * 0.5;
	}
}

static float ScattergunKnockback_GetHullScale(int victim)
{
	float mins[3];
	float maxs[3];
	GetClientMins(victim, mins);
	GetClientMaxs(victim, maxs);

	float volume = (maxs[0] - mins[0])
		* (maxs[1] - mins[1])
		* (maxs[2] - mins[2]);
	if (volume <= 0.0)
		return 1.0;

	return SCATTERGUN_REFERENCE_HULL_VOLUME / volume;
}

static bool ScattergunKnockback_CanApply(int victim, int attacker, int weapon, float damage)
{
	if (ScattergunKnockback_IsPushImmune(victim))
		return false;

	int flags = GetEntityFlags(victim);
	if ((flags & FL_ONGROUND) != 0)
	{
		g_iScattergunKnockbackUserId[victim] = 0;
	}
	else if (g_iScattergunKnockbackUserId[victim] != 0)
	{
		return false;
	}

	float attackerCenter[3];
	float victimCenter[3];
	ScattergunKnockback_GetWorldCenter(attacker, attackerCenter);
	ScattergunKnockback_GetWorldCenter(victim, victimCenter);

	float distanceSq = GetVectorDistance(attackerCenter, victimCenter, true);
	float eligibilityMultiplier = TF2Attrib_HookValueFloat(
		1.0, "scattergun_knockback_mult", weapon);
	return (damage > SCATTERGUN_KNOCKBACK_MIN_DAMAGE
		&& distanceSq < SCATTERGUN_KNOCKBACK_MAX_DISTANCE_SQ)
		|| eligibilityMultiplier > 1.0;
}

static void ScattergunKnockback_Apply(int victim, int attacker, int weapon, float damage)
{
	if (!ScattergunKnockback_CanApply(victim, attacker, weapon, damage))
		return;

	float attackerCenter[3];
	float victimCenter[3];
	float impulse[3];
	ScattergunKnockback_GetWorldCenter(attacker, attackerCenter);
	ScattergunKnockback_GetWorldCenter(victim, victimCenter);
	MakeVectorFromPoints(attackerCenter, victimCenter, impulse);
	if (NormalizeVector(impulse, impulse) <= 0.0)
		return;

	float forceMultiplier = TF2Attrib_HookValueFloat(
		SCATTERGUN_KNOCKBACK_DEFAULT_MULTIPLIER,
		"scattergun_knockback_mult",
		weapon);
	float force = damage * ScattergunKnockback_GetHullScale(victim) * forceMultiplier;
	if (force <= 0.0)
		return;
	if (force > SCATTERGUN_KNOCKBACK_MAX_FORCE)
		force = SCATTERGUN_KNOCKBACK_MAX_FORCE;

	ScaleVector(impulse, force);
	impulse[2] += SCATTERGUN_KNOCKBACK_JUMP_SPEED;

	float vulnerability = TF2Attrib_HookValueFloat(
		1.0, "airblast_vulnerability_multiplier", victim);
	ScaleVector(impulse, vulnerability);
	if (TF2_IsPlayerInCondition(victim, TFCond_HalloweenTiny))
		ScaleVector(impulse, 2.0);
	if (TF2_IsPlayerInCondition(victim, TFCond_Parachute))
	{
		impulse[0] *= 1.5;
		impulse[1] *= 1.5;
	}

	int flags = GetEntityFlags(victim);
	if ((flags & FL_ONGROUND) != 0 && impulse[2] < SCATTERGUN_KNOCKBACK_JUMP_SPEED)
		impulse[2] = SCATTERGUN_KNOCKBACK_JUMP_SPEED;
	impulse[2] = TF2Attrib_HookValueFloat(
		impulse[2], "airblast_vertical_vulnerability_multiplier", victim);

	float velocity[3];
	GetEntPropVector(victim, Prop_Data, "m_vecVelocity", velocity);
	AddVectors(velocity, impulse, velocity);
	SetEntityFlags(victim, flags & ~FL_ONGROUND);
	TF2_AddCondition(victim, TFCond_KnockedIntoAir, -1.0, attacker);
	TeleportEntity(victim, NULL_VECTOR, NULL_VECTOR, velocity);
	TF2_StunPlayer(victim, SCATTERGUN_KNOCKBACK_STUN_TIME, 1.0,
		TF_STUNFLAG_SLOWDOWN | TF_STUNFLAG_LIMITMOVEMENT, attacker);
	g_iScattergunKnockbackUserId[victim] = GetClientUserId(attacker);
}

static void ScattergunKnockback_ApplyFrame(any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int victimSlot = pack.ReadCell();
	int attackerSlot = pack.ReadCell();
	int victimUserId = pack.ReadCell();
	int attackerUserId = pack.ReadCell();
	int expectedTick = pack.ReadCell();
	delete pack;

	if (victimSlot < 1 || victimSlot > MaxClients
		|| attackerSlot < 1 || attackerSlot > MaxClients
		|| g_iScattergunPendingTick[victimSlot][attackerSlot] != expectedTick)
	{
		return;
	}

	float damage = g_fScattergunPendingDamage[victimSlot][attackerSlot];
	int weaponRef = g_iScattergunPendingWeaponRef[victimSlot][attackerSlot];
	ScattergunKnockback_ResetPair(victimSlot, attackerSlot);

	int victim = GetClientOfUserId(victimUserId);
	int attacker = GetClientOfUserId(attackerUserId);
	int weapon = EntRefToEntIndex(weaponRef);
	if (victim != victimSlot || attacker != attackerSlot
		|| !WR_IsClientInGame(victim) || !WR_IsClientInGame(attacker)
		|| !IsPlayerAlive(victim) || !IsPlayerAlive(attacker)
		|| victim == attacker || GetClientTeam(victim) == GetClientTeam(attacker)
		|| !WR_IsValidWeaponEntity(weapon)
		|| TF2CustAttr_GetInt(weapon, ATTR_SCATTERGUN_HAS_KNOCKBACK, 0) == 0)
	{
		return;
	}

	ScattergunKnockback_Apply(victim, attacker, weapon, damage);
}

void ScattergunKnockback_OnDamage(
	int victim, int attacker, int weapon, float damage, int damageType)
{
	if (damage <= 0.0 || (damageType & DMG_BUCKSHOT) == 0
		|| !WR_IsClientInGame(victim) || !WR_IsClientInGame(attacker)
		|| victim == attacker || GetClientTeam(victim) == GetClientTeam(attacker)
		|| !WR_IsValidWeaponEntity(weapon)
		|| TF2CustAttr_GetInt(weapon, ATTR_SCATTERGUN_HAS_KNOCKBACK, 0) == 0)
	{
		return;
	}

	int tick = GetGameTickCount();
	int weaponRef = EntIndexToEntRef(weapon);
	// Combine pellet callbacks and apply one impulse after normal damage momentum.
	if (!g_bScattergunFrameQueued[victim][attacker]
		|| g_iScattergunPendingTick[victim][attacker] != tick
		|| g_iScattergunPendingWeaponRef[victim][attacker] != weaponRef)
	{
		ScattergunKnockback_ResetPair(victim, attacker);
		g_iScattergunPendingTick[victim][attacker] = tick;
		g_iScattergunPendingWeaponRef[victim][attacker] = weaponRef;
		g_bScattergunFrameQueued[victim][attacker] = true;

		DataPack pack = new DataPack();
		pack.WriteCell(victim);
		pack.WriteCell(attacker);
		pack.WriteCell(GetClientUserId(victim));
		pack.WriteCell(GetClientUserId(attacker));
		pack.WriteCell(tick);
		RequestFrame(ScattergunKnockback_ApplyFrame, pack);
	}

	g_fScattergunPendingDamage[victim][attacker] += damage;
}
