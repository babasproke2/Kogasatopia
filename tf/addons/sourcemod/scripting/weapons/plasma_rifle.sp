// Pistol battery uses one round per shot from a configured 100-round clip.
#define ATTR_PLASMA_RIFLE "plasma rifle attributes"
#define PLASMA_HEAT_PER_SHOT 8.0
#define PLASMA_COOL_RATE 30.0
#define PLASMA_OVERHEAT_SECONDS 2.33
#define PLASMA_NO_ATTACK_ATTRIBUTE 821

bool g_bPlasmaHooked[MAX_TRACKED_ENTITIES];
int g_iPlasmaRef[MAX_TRACKED_ENTITIES];
int g_iPlasmaClipBefore[MAX_TRACKED_ENTITIES];
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
	g_iPlasmaClipBefore[weapon] = -1;
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

void Plasma_ClearAll()
{
	for (int weapon = MaxClients + 1; weapon < MAX_TRACKED_ENTITIES; weapon++)
	{
		if (g_bPlasmaHooked[weapon] && EntRefToEntIndex(g_iPlasmaRef[weapon]) == weapon)
		{
			Plasma_UnlockAttack(weapon);
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
		}
		else
		{
			g_fPlasmaHeat[weapon] = 100.0 * remaining / PLASMA_OVERHEAT_SECONDS;
		}
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

public MRESReturn Plasma_PrimaryAttack_Pre(int weapon)
{
	g_iPlasmaClipBefore[weapon] = -1;
	if (!WeaponsGameplay_IsEnabled() || !Plasma_IsWeapon(weapon))
		return MRES_Ignored;

	Plasma_UpdateHeat(weapon);
	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if (g_fPlasmaLockedUntil[weapon] > GetEngineTime() || clip < 1)
		return MRES_Supercede;

	g_iPlasmaClipBefore[weapon] = clip;
	return MRES_Ignored;
}

public MRESReturn Plasma_PrimaryAttack_Post(int weapon)
{
	int before = g_iPlasmaClipBefore[weapon];
	g_iPlasmaClipBefore[weapon] = -1;
	if (!WeaponsGameplay_IsEnabled() || !Plasma_IsWeapon(weapon) || before < 1)
		return MRES_Ignored;

	int after = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if (after >= before)
		return MRES_Ignored; // No actual shot (cooldown, dry fire, etc.).

	// The pistol's normal one-round consumption is the complete battery cost.
	g_fPlasmaHeat[weapon] += PLASMA_HEAT_PER_SHOT;
	g_fPlasmaUpdated[weapon] = GetEngineTime();
	if (g_fPlasmaHeat[weapon] >= 100.0)
	{
		g_fPlasmaHeat[weapon] = 100.0;
		g_fPlasmaLockedUntil[weapon] = GetEngineTime() + PLASMA_OVERHEAT_SECONDS;
		Plasma_LockAttack(weapon);
	}
	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (Weapons_IsClientInGame(owner))
		Plasma_ShowHeat(owner, weapon);
	return MRES_Ignored;
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
			Plasma_UpdateHeat(weapon);
		else
		{
			// Removing the custom attribute must also remove our firing restriction.
			Plasma_UnlockAttack(weapon);
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
