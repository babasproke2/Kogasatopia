// Source-aware guard for CTFPlayer::GiveAmmo(int, int, bool, EAmmoSource).
#define ATTR_NO_SECONDARY_AMMO_PICKUPS "no secondary ammo from pickups"
#define HOOK_NO_SECONDARY_AMMO_PICKUPS "no_secondary_ammo_from_pickups"
#define AMMO_PICKUPS_SECONDARY_INDEX 2
#define AMMO_SOURCE_PICKUP 0

DynamicDetour g_AmmoPickupsGiveAmmo;

void AmmoPickups_Init()
{
	GameData data = new GameData("weapons.ammo_pickups");
	if (data == null)
	{
		SetFailState("Missing weapons.ammo_pickups gamedata");
		return;
	}
	g_AmmoPickupsGiveAmmo = DynamicDetour.FromConf(data, "CTFPlayer::GiveAmmoWithSource");
	delete data;
	if (g_AmmoPickupsGiveAmmo == null
		|| !g_AmmoPickupsGiveAmmo.Enable(Hook_Pre, AmmoPickups_GiveAmmo_Pre))
		SetFailState("Failed to detour four-argument CTFPlayer::GiveAmmo");
}

void AmmoPickups_Shutdown()
{
	if (g_AmmoPickupsGiveAmmo != null)
	{
		g_AmmoPickupsGiveAmmo.Disable(Hook_Pre, AmmoPickups_GiveAmmo_Pre);
		delete g_AmmoPickupsGiveAmmo;
	}
}

static bool AmmoPickups_DenySecondary(int client, int ammoIndex, int ammoSource)
{
	if (ammoIndex != AMMO_PICKUPS_SECONDARY_INDEX || ammoSource != AMMO_SOURCE_PICKUP
		|| !WeaponsGameplay_IsEnabled() || !Weapons_IsClientInGame(client))
		return false;

	// Secondary ammo belongs to the player. An attributed holstered weapon must
	// restrict the same pool; do not inspect only m_hActiveWeapon or slot 1.
	int count = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int slot = 0; slot < count; slot++)
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", slot);
		if (weapon <= MaxClients || !IsValidEntity(weapon)
			|| GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity") != client)
			continue;

		int denied = TF2CustAttr_GetInt(weapon, ATTR_NO_SECONDARY_AMMO_PICKUPS, 0);
		// SourcePawn equivalent of CALL_ATTRIB_HOOK_INT_ON_OTHER. The custom
		// value is the default; a schema-provided hook is also supported.
		denied = TF2Attrib_HookValueInt(denied, HOOK_NO_SECONDARY_AMMO_PICKUPS, weapon);
		if (denied != 0)
			return true;
	}
	return false;
}

public MRESReturn AmmoPickups_GiveAmmo_Pre(int client, DHookReturn result, DHookParam params)
{
	if (!AmmoPickups_DenySecondary(client, params.Get(2), params.Get(4)))
		return MRES_Ignored;

	// Return before GiveAmmo changes the pool, consumes the pickup, or plays sound.
	result.Value = 0;
	return MRES_Supercede;
}
