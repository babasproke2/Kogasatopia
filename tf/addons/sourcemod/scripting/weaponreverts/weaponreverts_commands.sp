#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>
#include <weaponreverts_api>

#define WEAPON_REVERTS_CONFIG_PATH "configs/weaponreverts.cfg"
#define WEAPON_REVERTS_COMMANDS_SECTION "WeaponRevertsCommands"

KeyValues g_hWeaponRevertsCommandsConfig = null;

public Plugin myinfo =
{
	name = "WeaponReverts Commands",
	author = "Hombre",
	description = "Player-facing weapon revert commands backed by weaponreverts_api",
	version = "1.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	LoadWeaponRevertsCommandsConfig();
	RegConsoleCmd("sm_reverts", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_revert", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_r", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_changes", Command_InfoReverts, "Lists weapon revert data to the client");
}

public void OnPluginEnd()
{
	if (g_hWeaponRevertsCommandsConfig != null)
	{
		delete g_hWeaponRevertsCommandsConfig;
		g_hWeaponRevertsCommandsConfig = null;
	}
}

static bool WeaponRevertsCommands_IsUsableClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

static void LoadWeaponRevertsCommandsConfig()
{
	if (g_hWeaponRevertsCommandsConfig != null)
	{
		delete g_hWeaponRevertsCommandsConfig;
		g_hWeaponRevertsCommandsConfig = null;
	}

	g_hWeaponRevertsCommandsConfig = new KeyValues("WeaponReverts");

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), WEAPON_REVERTS_CONFIG_PATH);

	if (!g_hWeaponRevertsCommandsConfig.ImportFromFile(path))
	{
		LogError("[weaponreverts_commands] Failed to load %s", path);
	}
}

static void WeaponRevertsCommands_GetClassKey(TFClassType class, char[] buffer, int maxlen)
{
	switch (class)
	{
		case TFClass_Scout: strcopy(buffer, maxlen, "scout");
		case TFClass_Soldier: strcopy(buffer, maxlen, "soldier");
		case TFClass_Pyro: strcopy(buffer, maxlen, "pyro");
		case TFClass_DemoMan: strcopy(buffer, maxlen, "demoman");
		case TFClass_Heavy: strcopy(buffer, maxlen, "heavy");
		case TFClass_Engineer: strcopy(buffer, maxlen, "engineer");
		case TFClass_Medic: strcopy(buffer, maxlen, "medic");
		case TFClass_Sniper: strcopy(buffer, maxlen, "sniper");
		case TFClass_Spy: strcopy(buffer, maxlen, "spy");
		default: strcopy(buffer, maxlen, "");
	}
}

static int WeaponRevertsCommands_GetFirstItemIndex(const char[] itemKey)
{
	char token[16];
	int tokenLen = 0;
	int keyLen = strlen(itemKey);

	for (int i = 0; i <= keyLen; i++)
	{
		if (itemKey[i] == ',' || itemKey[i] == '\0')
		{
			token[tokenLen] = '\0';
			TrimString(token);
			return StringToInt(token);
		}

		if (tokenLen < sizeof(token) - 1)
		{
			token[tokenLen++] = itemKey[i];
		}
	}

	return 0;
}

static void FormatRevertLine(char[] buffer, int maxlen, const char[] weaponName, const char[] positive, const char[] negative)
{
	if (positive[0] != '\0' && negative[0] != '\0')
	{
		Format(buffer, maxlen, "{default}%s: {green}%s, {red}%s", weaponName, positive, negative);
	}
	else if (positive[0] != '\0')
	{
		Format(buffer, maxlen, "{default}%s: {green}%s", weaponName, positive);
	}
	else
	{
		Format(buffer, maxlen, "{default}%s: {red}%s", weaponName, negative);
	}
}

public Action Command_InfoReverts(int client, int args)
{
	if (!WeaponRevertsCommands_IsUsableClient(client))
		return Plugin_Handled;

	char classKey[16];
	WeaponRevertsCommands_GetClassKey(TF2_GetPlayerClass(client), classKey, sizeof(classKey));
	if (classKey[0] == '\0')
		return Plugin_Handled;

	if (g_hWeaponRevertsCommandsConfig == null)
		LoadWeaponRevertsCommandsConfig();

	g_hWeaponRevertsCommandsConfig.Rewind();
	if (!g_hWeaponRevertsCommandsConfig.JumpToKey(WEAPON_REVERTS_COMMANDS_SECTION, false) || !g_hWeaponRevertsCommandsConfig.JumpToKey(classKey, false))
	{
		CPrintToChat(client, "{green}[Info] {default}No weapon revert data available for your class.");
		g_hWeaponRevertsCommandsConfig.Rewind();
		return Plugin_Handled;
	}

	StringMap printed = new StringMap();
	if (g_hWeaponRevertsCommandsConfig.GotoFirstSubKey(false))
	{
		do
		{
			char indexKey[64];
			g_hWeaponRevertsCommandsConfig.GetSectionName(indexKey, sizeof(indexKey));
			int weaponIndex = WeaponRevertsCommands_GetFirstItemIndex(indexKey);
			if (weaponIndex <= 0)
				continue;

			char weaponName[128];
			char positive[256];
			char negative[256];
			char type[32];
			char classes[128];
			if (!WeaponReverts_GetWeaponInfo(weaponIndex, weaponName, sizeof(weaponName), positive, sizeof(positive), negative, sizeof(negative), type, sizeof(type), classes, sizeof(classes)))
				continue;

			char dedupeKey[512];
			Format(dedupeKey, sizeof(dedupeKey), "%s|%s", positive, negative);
			if (printed.ContainsKey(dedupeKey))
				continue;
			printed.SetValue(dedupeKey, 1);

			char line[512];
			FormatRevertLine(line, sizeof(line), weaponName, positive, negative);
			CPrintToChat(client, "%s", line);
		}
		while (g_hWeaponRevertsCommandsConfig.GotoNextKey(false));

		g_hWeaponRevertsCommandsConfig.GoBack();
	}

	delete printed;
	g_hWeaponRevertsCommandsConfig.Rewind();
	return Plugin_Handled;
}
