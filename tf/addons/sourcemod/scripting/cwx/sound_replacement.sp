/**
 * Custom-attribute sound replacement, originally authored by Mir.
 *
 * Weapons select a configured sound group with "replace sound".
 */
#define CWX_ATTR_REPLACE_SOUND "replace sound"

StringMap g_CwxSoundGroups;

enum struct CwxSoundGroup
{
	StringMap replacements;

	void Destroy()
	{
		delete this.replacements;
	}
}

void CwxSound_OnPluginStart()
{
	RegServerCmd("sm_cwx_reload_sounds", CwxSound_CommandReload);
	RegServerCmd("ca_sound_replace_reload", CwxSound_CommandReload);
	AddNormalSoundHook(CwxSound_Hook);
}

void CwxSound_OnPluginEnd()
{
	RemoveNormalSoundHook(CwxSound_Hook);
	CwxSound_Clear();
}

public Action CwxSound_CommandReload(int args)
{
	CwxSound_Reload();
	return Plugin_Handled;
}

public Action CwxSound_Hook(
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
	if (!CwxSound_IsValidClient(entity) || g_CwxSoundGroups == null)
	{
		return Plugin_Continue;
	}

	int weapon = GetEntPropEnt(entity, Prop_Send, "m_hActiveWeapon");
	if (!IsValidEntity(weapon))
	{
		return Plugin_Continue;
	}

	char groupName[256];
	if (!TF2CustAttr_GetString(weapon, CWX_ATTR_REPLACE_SOUND, groupName, sizeof(groupName)))
	{
		return Plugin_Continue;
	}

	CwxSoundGroup group;
	if (!g_CwxSoundGroups.GetArray(groupName, group, sizeof(group)))
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

void CwxSound_Reload()
{
	char path[PLATFORM_MAX_PATH];
	KeyValues config = CwxConfig_Open(path, sizeof(path));
	if (config == null)
	{
		CwxSound_Clear();
		return;
	}

	CwxSound_LoadConfig(config, path);
	delete config;
}

void CwxSound_LoadConfig(KeyValues config, const char[] path)
{
	CwxSound_Clear();
	if (config == null || !config.JumpToKey(CWX_CONFIG_SOUND_SECTION, false))
	{
		LogError("Sound replacement section '%s' not found in: %s", CWX_CONFIG_SOUND_SECTION, path);
		return;
	}

	g_CwxSoundGroups = new StringMap();
	CwxSound_LoadGroups(config);
	config.GoBack();
}

void CwxSound_LoadGroups(KeyValues config)
{
	if (config == null || g_CwxSoundGroups == null || !config.GotoFirstSubKey(false))
	{
		return;
	}

		do
		{
		CwxSoundGroup group;
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

		g_CwxSoundGroups.SetArray(groupName, group, sizeof(group));
	} while (config.GotoNextKey());
	config.GoBack();
}

void CwxSound_Clear()
{
	if (g_CwxSoundGroups == null)
	{
		return;
	}

	StringMapSnapshot groups = g_CwxSoundGroups.Snapshot();
	char groupName[256];
	for (int i = 0; i < groups.Length; i++)
	{
		groups.GetKey(i, groupName, sizeof(groupName));
		CwxSoundGroup group;
		if (g_CwxSoundGroups.GetArray(groupName, group, sizeof(group)))
		{
			group.Destroy();
		}
	}

	delete groups;
	delete g_CwxSoundGroups;
	g_CwxSoundGroups = null;
}

bool CwxSound_IsValidClient(int client)
{
	return client > 0
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& !GetEntProp(client, Prop_Send, "m_bIsCoaching")
		&& !IsClientSourceTV(client)
		&& !IsClientReplay(client);
}
