// Pistol battery uses one round per shot, including clipless reserve-ammo setups.
#define ATTR_PLASMA_RIFLE "plasma rifle attributes"
#define PLASMA_HEAT_PER_SHOT 7.0
#define PLASMA_COOL_RATE 30.0
#define PLASMA_OVERHEAT_SECONDS 2.33
#define PLASMA_NO_ATTACK_ATTRIBUTE 821
#define SOUND_PLASMA_OVERHEAT "weapons/halo_ce/plasrifle_overheat_10b.wav"
#define SOUND_PLASMA_OVERHEAT_END "weapons/flaregun_tube_closefinish.wav"

bool g_bPlasmaHooked[MAX_TRACKED_ENTITIES];
int g_iPlasmaRef[MAX_TRACKED_ENTITIES];
float g_fPlasmaLastFireTime[MAX_TRACKED_ENTITIES];
int g_iPlasmaShotsSeen[MAX_TRACKED_ENTITIES];
float g_fPlasmaHeat[MAX_TRACKED_ENTITIES];
float g_fPlasmaUpdated[MAX_TRACKED_ENTITIES];
float g_fPlasmaLockedUntil[MAX_TRACKED_ENTITIES];
bool g_bPlasmaOwnsAttackLock[MAX_TRACKED_ENTITIES];
bool g_bPlasmaHadNoAttack[MAX_TRACKED_ENTITIES];
float g_fPlasmaPreviousNoAttack[MAX_TRACKED_ENTITIES];
int g_iPlasmaHudRef[MAXPLAYERS + 1];
int g_iPlasmaHudHeat[MAXPLAYERS + 1];
float g_fPlasmaHudTime[MAXPLAYERS + 1];

static bool Plasma_IsWeapon(int weapon)
{
	return weapon > MaxClients && weapon < MAX_TRACKED_ENTITIES
		&& IsValidEntity(weapon) && g_bPlasmaHooked[weapon]
		&& TF2CustAttr_GetInt(weapon, ATTR_PLASMA_RIFLE, 0) != 0;
}

void Plasma_Hook(int weapon, const char[] classname)
{
	if (weapon <= MaxClients || weapon >= MAX_TRACKED_ENTITIES
		|| dhook_CTFWeaponBase_PrimaryAttack == null
		|| (!StrEqual(classname, "tf_weapon_pistol") && !StrEqual(classname, "tf_weapon_pistol_scout"))
		|| g_bPlasmaHooked[weapon])
		return;

	dhook_CTFWeaponBase_PrimaryAttack.HookEntity(Hook_Pre, weapon, Plasma_PrimaryAttack_Pre);
	dhook_CTFWeaponBase_PrimaryAttack.HookEntity(Hook_Post, weapon, Plasma_PrimaryAttack_Post);
	g_bPlasmaHooked[weapon] = true;
	g_iPlasmaRef[weapon] = EntIndexToEntRef(weapon);
	g_fPlasmaLastFireTime[weapon] = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
	g_iPlasmaShotsSeen[weapon] = 0;
	g_fPlasmaHeat[weapon] = 0.0;
	g_fPlasmaUpdated[weapon] = GetEngineTime();
	g_fPlasmaLockedUntil[weapon] = 0.0;
	g_bPlasmaOwnsAttackLock[weapon] = false;
}

static void Plasma_LockAttack(int weapon)
{
	if (!g_bPlasmaOwnsAttackLock[weapon])
	{
		Address existing = TF2Attrib_GetByDefIndex(weapon, PLASMA_NO_ATTACK_ATTRIBUTE);
		g_bPlasmaHadNoAttack[weapon] = existing != Address_Null;
		if (existing != Address_Null)
			g_fPlasmaPreviousNoAttack[weapon] = TF2Attrib_GetValue(existing);
	}
	TF2Attrib_SetByDefIndex(weapon, PLASMA_NO_ATTACK_ATTRIBUTE, 1.0);
	g_bPlasmaOwnsAttackLock[weapon] = true;
}

static void Plasma_UnlockAttack(int weapon)
{
	if (!g_bPlasmaOwnsAttackLock[weapon])
		return;

	// Restore any pre-existing restriction instead of clearing another feature's lock.
	if (g_bPlasmaHadNoAttack[weapon])
		TF2Attrib_SetByDefIndex(weapon, PLASMA_NO_ATTACK_ATTRIBUTE, g_fPlasmaPreviousNoAttack[weapon]);
	else
		TF2Attrib_RemoveByDefIndex(weapon, PLASMA_NO_ATTACK_ATTRIBUTE);
	g_bPlasmaOwnsAttackLock[weapon] = false;
}

static void Plasma_SyncAttackLock(int weapon)
{
	// no_attack is provided to the owner, so it must not stay on a holstered rifle.
	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	bool block = g_fPlasmaLockedUntil[weapon] > GetEngineTime()
		&& Weapons_IsClientInGame(owner) && IsPlayerAlive(owner)
		&& GetEntPropEnt(owner, Prop_Send, "m_hActiveWeapon") == weapon;
	if (block)
	{
		if (!g_bPlasmaOwnsAttackLock[weapon])
			Plasma_LockAttack(weapon);
	}
	else
		Plasma_UnlockAttack(weapon);
}

void Plasma_OnWeaponSwitchPost(int client)
{
	// Sync immediately after a successful switch, not just on the next frame.
	for (int weapon = MaxClients + 1; weapon < MAX_TRACKED_ENTITIES; weapon++)
	{
		if (!g_bPlasmaHooked[weapon] || EntRefToEntIndex(g_iPlasmaRef[weapon]) != weapon
			|| GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity") != client)
			continue;
		if (WeaponsGameplay_IsEnabled() && Plasma_IsWeapon(weapon))
			Plasma_UpdateHeat(weapon);
		else
			Plasma_UnlockAttack(weapon);
	}
}

void Plasma_ClearAll()
{
	for (int weapon = MaxClients + 1; weapon < MAX_TRACKED_ENTITIES; weapon++)
	{
		if (g_bPlasmaHooked[weapon] && EntRefToEntIndex(g_iPlasmaRef[weapon]) == weapon)
		{
			Plasma_UnlockAttack(weapon);
			g_fPlasmaLastFireTime[weapon] = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
			g_fPlasmaHeat[weapon] = 0.0;
			g_fPlasmaLockedUntil[weapon] = 0.0;
			g_fPlasmaUpdated[weapon] = GetEngineTime();
		}
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_iPlasmaHudRef[client] != 0 && Weapons_IsClientInGame(client))
			PrintHintText(client, "");
		g_iPlasmaHudRef[client] = 0;
	}
}

static void Plasma_UpdateHeat(int weapon)
{
	float now = GetEngineTime();
	float elapsed = now - g_fPlasmaUpdated[weapon];
	g_fPlasmaUpdated[weapon] = now;

	if (g_fPlasmaLockedUntil[weapon] > 0.0)
	{
		float remaining = g_fPlasmaLockedUntil[weapon] - now;
		if (remaining <= 0.0)
		{
			g_fPlasmaHeat[weapon] = 0.0;
			g_fPlasmaLockedUntil[weapon] = 0.0;
			Plasma_UnlockAttack(weapon);
			int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
			if (Weapons_IsClientInGame(owner))
				EmitSoundToAll(SOUND_PLASMA_OVERHEAT_END, owner, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
		}
		else
		{
			g_fPlasmaHeat[weapon] = 100.0 * remaining / PLASMA_OVERHEAT_SECONDS;
		}
		Plasma_SyncAttackLock(weapon);
		return;
	}

	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	bool triggerHeld = Weapons_IsClientInGame(owner) && IsPlayerAlive(owner)
		&& GetEntPropEnt(owner, Prop_Send, "m_hActiveWeapon") == weapon
		&& (GetClientButtons(owner) & IN_ATTACK) != 0;
	if (!triggerHeld && elapsed > 0.0)
	{
		g_fPlasmaHeat[weapon] -= PLASMA_COOL_RATE * elapsed;
		if (g_fPlasmaHeat[weapon] < 0.0)
			g_fPlasmaHeat[weapon] = 0.0;
	}
}

static int Plasma_GetAmmo(int weapon)
{
	// Match CTFWeaponBaseGun::RemoveProjectileAmmo: -1 means use owner ammo.
	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if (clip != -1)
		return clip;

	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (!Weapons_IsClientInGame(owner))
		return -1;

	// Primary firing can use the secondary ammo pool (pistols); don't hardcode it.
	int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
	if (ammoType < 0 || ammoType >= GetEntPropArraySize(owner, Prop_Send, "m_iAmmo"))
		return -1;
	return GetEntProp(owner, Prop_Send, "m_iAmmo", _, ammoType);
}

public MRESReturn Plasma_PrimaryAttack_Pre(int weapon)
{
	if (!WeaponsGameplay_IsEnabled() || !Plasma_IsWeapon(weapon))
		return MRES_Ignored;

	Plasma_UpdateHeat(weapon);
	if (g_fPlasmaLockedUntil[weapon] > GetEngineTime())
		return MRES_Supercede;

	// Let the engine decide whether clipless / infinite-ammo weapons can fire.
	return MRES_Ignored;
}

public MRESReturn Plasma_PrimaryAttack_Post(int weapon)
{
	if (!WeaponsGameplay_IsEnabled() || !Plasma_IsWeapon(weapon))
		return MRES_Ignored;

	Plasma_CheckShot(weapon);
	return MRES_Ignored;
}

static void Plasma_CheckShot(int weapon)
{
	// FireProjectile updates this even if another plugin restores all consumed ammo.
	// Both the post hook and OnGameFrame call here; the timestamp deduplicates them.
	float fired = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
	float previous = g_fPlasmaLastFireTime[weapon];
	g_fPlasmaLastFireTime[weapon] = fired;
	if (fired <= previous)
		return; // No shot, dry fire, or a reset of the weapon's fire timestamp.

	Plasma_UpdateHeat(weapon);
	if (g_fPlasmaLockedUntil[weapon] > GetEngineTime())
		return;

	// The pistol's normal one-round consumption is the complete battery cost.
	g_iPlasmaShotsSeen[weapon]++;
	g_fPlasmaHeat[weapon] += PLASMA_HEAT_PER_SHOT;
	g_fPlasmaUpdated[weapon] = GetEngineTime();
	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (g_fPlasmaHeat[weapon] >= 100.0)
	{
		g_fPlasmaHeat[weapon] = 100.0;
		g_fPlasmaLockedUntil[weapon] = GetEngineTime() + PLASMA_OVERHEAT_SECONDS;
		Plasma_SyncAttackLock(weapon);
		if (Weapons_IsClientInGame(owner))
			EmitSoundToAll(SOUND_PLASMA_OVERHEAT, owner, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
	}
	if (Weapons_IsClientInGame(owner))
		Plasma_ShowHeat(owner, weapon);
}

public Action Command_PlasmaStatus(int client, int args)
{
	ReplyToCommand(client, "[Plasma firetime-v1] gameplay=%d", WeaponsGameplay_IsEnabled());
	int found = 0;
	for (int weapon = MaxClients + 1; weapon < MAX_TRACKED_ENTITIES; weapon++)
	{
		if (!Plasma_IsWeapon(weapon))
			continue;
		char classname[64];
		GetEntityClassname(weapon, classname, sizeof(classname));
		ReplyToCommand(client, "[Plasma] entity=%d class=%s ammo=%d heat=%.1f shots=%d lock=%d fired=%.4f seen=%.4f",
			weapon, classname, Plasma_GetAmmo(weapon), g_fPlasmaHeat[weapon], g_iPlasmaShotsSeen[weapon],
			g_bPlasmaOwnsAttackLock[weapon], GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime"),
			g_fPlasmaLastFireTime[weapon]);
		found++;
	}
	ReplyToCommand(client, "[Plasma] %d attributed pistol(s) tracked.", found);
	return Plugin_Handled;
}

static void Plasma_ShowHeat(int client, int weapon)
{
	int heat = RoundToCeil(g_fPlasmaHeat[weapon]);
	float now = GetEngineTime();
	int reference = EntIndexToEntRef(weapon);
	if (g_iPlasmaHudRef[client] != reference || g_iPlasmaHudHeat[client] != heat
		|| now - g_fPlasmaHudTime[client] >= 1.0)
	{
		PrintHintText(client, "Heat: %d%%", heat);
		g_iPlasmaHudRef[client] = reference;
		g_iPlasmaHudHeat[client] = heat;
		g_fPlasmaHudTime[client] = now;
	}
}

void Plasma_OnFrame()
{
	// Cooling continues while holstered/dropped; entity references prevent slot reuse.
	for (int weapon = MaxClients + 1; weapon < MAX_TRACKED_ENTITIES; weapon++)
	{
		if (!g_bPlasmaHooked[weapon] || EntRefToEntIndex(g_iPlasmaRef[weapon]) != weapon)
			continue;
		if (Plasma_IsWeapon(weapon))
		{
			// Also observe shots outside the virtual PrimaryAttack call path.
			Plasma_CheckShot(weapon);
			Plasma_UpdateHeat(weapon);
		}
		else
		{
			// Removing the custom attribute must also remove our firing restriction.
			Plasma_UnlockAttack(weapon);
			g_fPlasmaLastFireTime[weapon] = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
			g_fPlasmaHeat[weapon] = 0.0;
			g_fPlasmaLockedUntil[weapon] = 0.0;
			g_fPlasmaUpdated[weapon] = GetEngineTime();
		}
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!Weapons_IsClientInGame(client))
		{
			g_iPlasmaHudRef[client] = 0;
			continue;
		}
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (IsPlayerAlive(client) && Plasma_IsWeapon(weapon))
			Plasma_ShowHeat(client, weapon);
		else if (g_iPlasmaHudRef[client] != 0)
		{
			PrintHintText(client, "");
			g_iPlasmaHudRef[client] = 0;
		}
	}
}
