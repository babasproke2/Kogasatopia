/**
 * Custom-attribute sound replacement, originally authored by Mir.
 *
 * Weapons select a configured sound group with "replace sound".
 */
#define Weapons_ATTR_REPLACE_SOUND "replace sound"
#define Weapons_ATTR_CUSTOM_DEPLOY_SOUND "custom deploy sound"
#define Weapons_ATTR_EMIT_SOUND_ON_HIT "emit sound on hit"
#define Weapons_ATTR_CUSTOM_HITSOUND "custom hitsound"
#define Weapons_ATTR_CUSTOM_MELEE_SWING_SOUND "custom melee swing sound"
#define Weapons_ATTR_CUSTOM_MELEE_HIT_SOUND "custom melee hit sound"
#define WEAPONS_SOUND_ENTRY_BATSABER_SWING "Weapon_BatSaber.Swing"
#define WEAPONS_SOUND_ENTRY_BATSABER_HIT_FLESH "Weapon_BatSaber.HitFlesh"
#define WEAPONS_CUSTOM_DEPLOY_SOUND_COOLDOWN 3.0

StringMap g_WeaponsSoundGroups;
DynamicHook g_WeaponsSoundPrimaryAttackHook;
int g_iWeaponsSoundWeaponRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
char g_sWeaponsSoundGroup[MAXPLAYERS + 1][64];
float g_flWeaponsNextDeploySoundTime[MAXPLAYERS + 1];

static const char g_WeaponsSoundBatSaberSwingSamples[][] =
{
	"weapons/batsaber_swing1.wav",
	"weapons/batsaber_swing2.wav",
	"weapons/batsaber_swing3.wav"
};

static const char g_WeaponsSoundBatSaberHitFleshSamples[][] =
{
	"weapons/batsaber_hit_flesh1.wav",
	"weapons/batsaber_hit_flesh2.wav"
};

enum struct WeaponsSoundGroup
{
	StringMap replacements;

	void Destroy()
	{
		delete this.replacements;
	}
}

void WeaponsSound_OnPluginStart(GameData gameConf)
{
	g_WeaponsSoundPrimaryAttackHook =
		DynamicHook.FromConf(gameConf, "CTFWeaponBase::PrimaryAttack");
	if (g_WeaponsSoundPrimaryAttackHook == null)
	{
		SetFailState("Failed to create melee sound PrimaryAttack hook");
	}

	RegServerCmd("sm_weapons_reload_sounds", WeaponsSound_CommandReload);
	AddNormalSoundHook(WeaponsSound_Hook);
	WeaponsSound_HookExistingWeaponEntities();
}

void WeaponsSound_OnPluginEnd()
{
	RemoveNormalSoundHook(WeaponsSound_Hook);
	delete g_WeaponsSoundPrimaryAttackHook;
	g_WeaponsSoundPrimaryAttackHook = null;
	WeaponsSound_Clear();
}

void WeaponsSound_OnEntityCreated(int entity, const char[] className)
{
	WeaponsSound_HookWeaponEntity(entity, className);
}

static void WeaponsSound_HookExistingWeaponEntities()
{
	char className[64];
	int maxEntities = GetMaxEntities();
	for (int weapon = MaxClients + 1; weapon < maxEntities; weapon++)
	{
		if (!IsValidEntity(weapon))
		{
			continue;
		}

		GetEntityClassname(weapon, className, sizeof(className));
		WeaponsSound_HookWeaponEntity(weapon, className);
	}
}

static void WeaponsSound_HookWeaponEntity(int weapon, const char[] className)
{
	if (g_WeaponsSoundPrimaryAttackHook == null
			|| weapon <= MaxClients
			|| !IsValidEntity(weapon)
			|| StrContains(className, "tf_weapon_") != 0)
	{
		return;
	}

	g_WeaponsSoundPrimaryAttackHook.HookEntity(
		Hook_Pre, weapon, WeaponsSound_PrimaryAttackPre);
}

public MRESReturn WeaponsSound_PrimaryAttackPre(int weapon)
{
	if (weapon <= MaxClients
			|| !IsValidEntity(weapon)
			|| TF2Util_GetWeaponSlot(weapon) != TFWeaponSlot_Melee)
	{
		return MRES_Ignored;
	}

	int client = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	WeaponsSound_EmitCustomMeleeAttribute(
		client, weapon, Weapons_ATTR_CUSTOM_MELEE_SWING_SOUND, "melee swing");
	return MRES_Ignored;
}

public Action WeaponsSound_CommandReload(int args)
{
	WeaponsSound_Reload();
	return Plugin_Handled;
}

public Action WeaponsSound_Hook(
	int clients[MAXPLAYERS],
	int &numClients,
	char oldSound[PLATFORM_MAX_PATH],
	int &entity,
	int &channel,
	float &volume,
	int &level,
	int &pitch,
	int &flags,
	char soundEntry[PLATFORM_MAX_PATH],
	int &seed)
{
	if (!Weapons_IsValidClient(entity) || g_WeaponsSoundGroups == null)
	{
		return Plugin_Continue;
	}

	int weapon = GetEntPropEnt(entity, Prop_Send, "m_hActiveWeapon");
	if (!IsValidEntity(weapon))
	{
		return Plugin_Continue;
	}

	int weaponRef = EntIndexToEntRef(weapon);
	if (g_iWeaponsSoundWeaponRef[entity] != weaponRef)
	{
		WeaponsSound_UpdateClientWeapon(entity, weapon);
	}

	if (!g_sWeaponsSoundGroup[entity][0])
	{
		return Plugin_Continue;
	}

	WeaponsSoundGroup group;
	if (!g_WeaponsSoundGroups.GetArray(g_sWeaponsSoundGroup[entity], group, sizeof(group)))
	{
		return Plugin_Continue;
	}

	char replacement[PLATFORM_MAX_PATH];
	if (!group.replacements.GetString(oldSound, replacement, sizeof(replacement))
			|| replacement[0] == '\0'
			|| !PrecacheSound(replacement, true))
	{
		return Plugin_Continue;
	}

	EmitSoundToAll(replacement, entity, channel, level, flags, volume, pitch);
	return Plugin_Stop;
}

void WeaponsSound_OnWeaponSwitchPost(int client, int weapon)
{
	WeaponsSound_UpdateClientWeapon(client, weapon);
	WeaponsSound_PlayCustomDeploySound(client, weapon);
}

static void WeaponsSound_PlayCustomDeploySound(int client, int weapon)
{
	if (!Weapons_IsValidClient(client) || !IsValidEntity(weapon)
			|| GetGameTime() < g_flWeaponsNextDeploySoundTime[client])
	{
		return;
	}

	if (WeaponsSound_EmitCustomAttribute(client, weapon,
			Weapons_ATTR_CUSTOM_DEPLOY_SOUND, "custom deploy"))
	{
		g_flWeaponsNextDeploySoundTime[client] =
			GetGameTime() + WEAPONS_CUSTOM_DEPLOY_SOUND_COOLDOWN;
	}
}

void WeaponsSound_PlayOnHit(int victim, int weapon)
{
	WeaponsSound_EmitCustomAttribute(victim, weapon,
		Weapons_ATTR_EMIT_SOUND_ON_HIT, "on-hit");
}

void WeaponsSound_PlayCustomHitsound(int attacker, int weapon)
{
	WeaponsSound_EmitCustomAttribute(attacker, weapon,
		Weapons_ATTR_CUSTOM_HITSOUND, "custom hitsound");
}

void WeaponsSound_PlayCustomMeleeHit(int attacker, int weapon)
{
	if (weapon <= MaxClients
			|| !IsValidEntity(weapon)
			|| TF2Util_GetWeaponSlot(weapon) != TFWeaponSlot_Melee)
	{
		return;
	}

	WeaponsSound_EmitCustomMeleeAttribute(
		attacker, weapon, Weapons_ATTR_CUSTOM_MELEE_HIT_SOUND, "melee hit");
}

static bool WeaponsSound_EmitCustomMeleeAttribute(
	int client, int weapon, const char[] attribute, const char[] context)
{
	if (!Weapons_IsValidClient(client) || !IsValidEntity(weapon))
	{
		return false;
	}

	char soundEntry[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(
		weapon, attribute, soundEntry, sizeof(soundEntry));
	TrimString(soundEntry);
	if (!soundEntry[0])
	{
		return false;
	}

	char sample[PLATFORM_MAX_PATH];
	if (!WeaponsSound_GetRandomMeleeSample(
			soundEntry, sample, sizeof(sample)))
	{
		LogError("Unsupported %s game sound '%s' for weapon %d",
			context, soundEntry, weapon);
		return false;
	}

	if (!PrecacheSound(sample, true))
	{
		LogError("Failed to precache %s sample '%s' for weapon %d",
			context, sample, weapon);
		return false;
	}

	EmitSoundToAll(sample, client, SNDCHAN_WEAPON, SNDLEVEL_NORMAL);
	return true;
}

static bool WeaponsSound_GetRandomMeleeSample(
	const char[] soundEntry, char[] sample, int sampleLength)
{
	if (StrEqual(soundEntry, WEAPONS_SOUND_ENTRY_BATSABER_SWING))
	{
		int index = GetRandomInt(
			0, sizeof(g_WeaponsSoundBatSaberSwingSamples) - 1);
		strcopy(sample, sampleLength,
			g_WeaponsSoundBatSaberSwingSamples[index]);
		return true;
	}

	if (StrEqual(soundEntry, WEAPONS_SOUND_ENTRY_BATSABER_HIT_FLESH))
	{
		int index = GetRandomInt(
			0, sizeof(g_WeaponsSoundBatSaberHitFleshSamples) - 1);
		strcopy(sample, sampleLength,
			g_WeaponsSoundBatSaberHitFleshSamples[index]);
		return true;
	}

	sample[0] = '\0';
	return false;
}

static bool WeaponsSound_EmitCustomAttribute(int client, int weapon,
		const char[] attribute, const char[] context)
{
	if (!Weapons_IsValidClient(client) || !IsValidEntity(weapon))
	{
		return false;
	}

	char sample[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(weapon, attribute, sample, sizeof(sample));
	TrimString(sample);
	if (!sample[0])
	{
		return false;
	}

	if (!PrecacheSound(sample, true))
	{
		LogError("Failed to precache %s sound '%s' for weapon %d",
			context, sample, weapon);
		return false;
	}

	EmitSoundToAll(sample, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
	return true;
}

void WeaponsSound_OnItemRuntimeStateReady(int client, int entity)
{
	if (Weapons_IsValidClient(client)
			&& GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == entity)
	{
		WeaponsSound_UpdateClientWeapon(client, entity);
	}
}

void WeaponsSound_UpdateClientWeapon(int client, int weapon)
{
	WeaponsSound_ResetClient(client);
	if (!Weapons_IsValidClient(client) || !IsValidEntity(weapon))
	{
		return;
	}

	g_iWeaponsSoundWeaponRef[client] = EntIndexToEntRef(weapon);
	TF2CustAttr_GetString(weapon, Weapons_ATTR_REPLACE_SOUND,
		g_sWeaponsSoundGroup[client], sizeof(g_sWeaponsSoundGroup[]));
}

void WeaponsSound_ResetClient(int client, bool resetDeployCooldown = false)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	g_iWeaponsSoundWeaponRef[client] = INVALID_ENT_REFERENCE;
	g_sWeaponsSoundGroup[client][0] = '\0';
	if (resetDeployCooldown)
	{
		g_flWeaponsNextDeploySoundTime[client] = 0.0;
	}
}

void WeaponsSound_ResetClients()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		WeaponsSound_ResetClient(client, true);
	}
}

void WeaponsSound_Reload()
{
	char path[PLATFORM_MAX_PATH];
	KeyValues config = WeaponsConfig_Open(path, sizeof(path));
	if (config == null)
	{
		WeaponsSound_Clear();
		return;
	}

	WeaponsSound_LoadConfig(config, path);
	delete config;
}

void WeaponsSound_LoadConfig(KeyValues config, const char[] path)
{
	WeaponsSound_Clear();
	if (config == null || !config.JumpToKey(WEAPONS_CONFIG_SOUND_SECTION, false))
	{
		LogError("Sound replacement section '%s' not found in: %s", WEAPONS_CONFIG_SOUND_SECTION, path);
		return;
	}

	g_WeaponsSoundGroups = new StringMap();
	WeaponsSound_LoadGroups(config);
	config.GoBack();
}

void WeaponsSound_ValidateItemConfig(const char[] itemUid, KeyValues attributes)
{
	if (attributes == null)
	{
		return;
	}

	char groupName[64];
	attributes.GetString(Weapons_ATTR_REPLACE_SOUND, groupName, sizeof(groupName));
	if (groupName[0])
	{
		WeaponsSoundGroup group;
		if (g_WeaponsSoundGroups == null
				|| !g_WeaponsSoundGroups.GetArray(groupName, group, sizeof(group)))
		{
			LogError("Item uid '%s' references unknown sound group '%s'",
				itemUid, groupName);
		}
	}

	WeaponsSound_ValidateCustomMeleeAttribute(
		itemUid, attributes, Weapons_ATTR_CUSTOM_MELEE_SWING_SOUND);
	WeaponsSound_ValidateCustomMeleeAttribute(
		itemUid, attributes, Weapons_ATTR_CUSTOM_MELEE_HIT_SOUND);
}

static void WeaponsSound_ValidateCustomMeleeAttribute(
	const char[] itemUid, KeyValues attributes, const char[] attribute)
{
	char soundEntry[PLATFORM_MAX_PATH];
	attributes.GetString(attribute, soundEntry, sizeof(soundEntry));
	TrimString(soundEntry);
	if (!soundEntry[0])
	{
		return;
	}

	if (!WeaponsSound_PrecacheMeleeEntry(soundEntry))
	{
		LogError(
			"Item uid '%s' could not precache game sound '%s' for attribute '%s'",
			itemUid, soundEntry, attribute);
	}
}

static bool WeaponsSound_PrecacheMeleeEntry(const char[] soundEntry)
{
	bool success = true;
	if (StrEqual(soundEntry, WEAPONS_SOUND_ENTRY_BATSABER_SWING))
	{
		for (int i = 0; i < sizeof(g_WeaponsSoundBatSaberSwingSamples); i++)
		{
			if (!PrecacheSound(g_WeaponsSoundBatSaberSwingSamples[i], true))
			{
				success = false;
			}
		}
		return success;
	}

	if (StrEqual(soundEntry, WEAPONS_SOUND_ENTRY_BATSABER_HIT_FLESH))
	{
		for (int i = 0; i < sizeof(g_WeaponsSoundBatSaberHitFleshSamples); i++)
		{
			if (!PrecacheSound(g_WeaponsSoundBatSaberHitFleshSamples[i], true))
			{
				success = false;
			}
		}
		return success;
	}

	return false;
}

void WeaponsSound_LoadGroups(KeyValues config)
{
	if (config == null || g_WeaponsSoundGroups == null || !config.GotoFirstSubKey(false))
	{
		return;
	}

		do
		{
		WeaponsSoundGroup group;
		group.replacements = new StringMap();

		char groupName[256];
		config.GetSectionName(groupName, sizeof(groupName));
		if (config.GotoFirstSubKey(false))
		{
			do
			{
				char oldSound[PLATFORM_MAX_PATH];
				char replacement[PLATFORM_MAX_PATH];
				config.GetSectionName(oldSound, sizeof(oldSound));
				config.GetString(NULL_STRING, replacement, sizeof(replacement));
				if (replacement[0] == '\0' || !PrecacheSound(replacement, true))
				{
					continue;
				}
				group.replacements.SetString(oldSound, replacement);
			} while (config.GotoNextKey(false));
			config.GoBack();
		}

		g_WeaponsSoundGroups.SetArray(groupName, group, sizeof(group));
	} while (config.GotoNextKey());
	config.GoBack();
}

void WeaponsSound_Clear()
{
	WeaponsSound_ResetClients();
	if (g_WeaponsSoundGroups == null)
	{
		return;
	}

	StringMapSnapshot groups = g_WeaponsSoundGroups.Snapshot();
	char groupName[256];
	for (int i = 0; i < groups.Length; i++)
	{
		groups.GetKey(i, groupName, sizeof(groupName));
		WeaponsSoundGroup group;
		if (g_WeaponsSoundGroups.GetArray(groupName, group, sizeof(group)))
		{
			group.Destroy();
		}
	}

	delete groups;
	delete g_WeaponsSoundGroups;
	g_WeaponsSoundGroups = null;
}
