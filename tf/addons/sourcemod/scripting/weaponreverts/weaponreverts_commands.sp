#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>

#undef REQUIRE_PLUGIN
#include <weaponreverts_api>
#define REQUIRE_PLUGIN

#include "../include/item_indexes.inc"
#include "../include/tf2_classes.inc"

#define WEAPON_REVERTS_CONFIG_PATH "configs/weapons.cfg"
#define WEAPON_REVERTS_ITEM_CLASSES_SECTION "WeaponRevertsItemClasses"

KeyValues g_hWeaponRevertsItemClassesConfig = null;
bool g_bWeaponRevertsAvailable = false;

public Plugin myinfo =
{
	name = "WeaponReverts Item Classes",
	author = "Hombre",
	description = "Player-facing weapon revert commands backed by weaponreverts_api",
	version = "1.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	LoadWeaponRevertsItemClassesConfig();
	RegConsoleCmd("sm_reverts", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_revert", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_r", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_changes", Command_InfoReverts, "Lists weapon revert data to the client");
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
	MarkNativeAsOptional("WeaponReverts_GetWeaponInfo");
	MarkNativeAsOptional("WeaponReverts_CanClassUseWeapon");
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	g_bWeaponRevertsAvailable = LibraryExists("weaponreverts");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "weaponreverts"))
	{
		g_bWeaponRevertsAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "weaponreverts"))
	{
		g_bWeaponRevertsAvailable = false;
	}
}

public void OnPluginEnd()
{
	if (g_hWeaponRevertsItemClassesConfig != null)
	{
		delete g_hWeaponRevertsItemClassesConfig;
		g_hWeaponRevertsItemClassesConfig = null;
	}
}

static bool WeaponRevertsItemClasses_IsUsableClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

static void LoadWeaponRevertsItemClassesConfig()
{
	if (g_hWeaponRevertsItemClassesConfig != null)
	{
		delete g_hWeaponRevertsItemClassesConfig;
		g_hWeaponRevertsItemClassesConfig = null;
	}

	g_hWeaponRevertsItemClassesConfig = new KeyValues("WeaponReverts");

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), WEAPON_REVERTS_CONFIG_PATH);

	if (!g_hWeaponRevertsItemClassesConfig.ImportFromFile(path))
	{
		LogError("[weaponreverts_item_classes] Failed to load %s", path);
	}
}

static void FormatRevertLine(char[] buffer, int maxlen, const char[] weaponName, const char[] positive, const char[] neutral, const char[] negative)
{
	Format(buffer, maxlen, "{default}%s:", weaponName);
	bool needsComma = false;

	if (positive[0] != '\0')
	{
		AppendRevertLinePart(buffer, maxlen, "{green}", positive, needsComma);
	}
	if (neutral[0] != '\0')
	{
		AppendRevertLinePart(buffer, maxlen, "{default}", neutral, needsComma);
	}
	if (negative[0] != '\0')
	{
		AppendRevertLinePart(buffer, maxlen, "{red}", negative, needsComma);
	}
}

static void AppendRevertLinePart(char[] buffer, int maxlen, const char[] color, const char[] text, bool &needsComma)
{
	if (needsComma)
	{
		StrCat(buffer, maxlen, ",");
	}
	StrCat(buffer, maxlen, " ");
	StrCat(buffer, maxlen, color);
	StrCat(buffer, maxlen, text);
	needsComma = true;
}

public Action Command_InfoReverts(int client, int args)
{
	if (!WeaponRevertsItemClasses_IsUsableClient(client))
		return Plugin_Handled;

	if (!g_bWeaponRevertsAvailable)
	{
		CPrintToChat(client, "{green}[Info] {default}No weapon revert data available on this server.");
		return Plugin_Handled;
	}

	char classKey[16];
	TF2Classes_GetKey(TF2_GetPlayerClass(client), classKey, sizeof(classKey));
	if (classKey[0] == '\0')
		return Plugin_Handled;

	if (g_hWeaponRevertsItemClassesConfig == null)
		LoadWeaponRevertsItemClassesConfig();

	g_hWeaponRevertsItemClassesConfig.Rewind();
	if (!g_hWeaponRevertsItemClassesConfig.JumpToKey(WEAPON_REVERTS_ITEM_CLASSES_SECTION, false) || !g_hWeaponRevertsItemClassesConfig.JumpToKey(classKey, false))
	{
		CPrintToChat(client, "{green}[Info] {default}No weapon revert data available for your class.");
		g_hWeaponRevertsItemClassesConfig.Rewind();
		return Plugin_Handled;
	}

	StringMap printed = new StringMap();
	if (g_hWeaponRevertsItemClassesConfig.GotoFirstSubKey(false))
	{
		do
		{
			char indexKey[64];
			g_hWeaponRevertsItemClassesConfig.GetSectionName(indexKey, sizeof(indexKey));
			int indexes[1];
			if (ItemIndexes_Parse(indexKey, indexes, sizeof(indexes)) == 0)
				continue;
			int weaponIndex = indexes[0];

			char weaponName[128];
			char positive[256];
			char neutral[256];
			char negative[256];
			char type[32];
			char classes[128];
			if (!WeaponReverts_GetWeaponInfo(weaponIndex, weaponName, sizeof(weaponName), positive, sizeof(positive), neutral, sizeof(neutral), negative, sizeof(negative), type, sizeof(type), classes, sizeof(classes)))
				continue;

			char dedupeKey[512];
			Format(dedupeKey, sizeof(dedupeKey), "%s|%s|%s", positive, neutral, negative);
			if (printed.ContainsKey(dedupeKey))
				continue;
			printed.SetValue(dedupeKey, 1);

			char line[512];
			FormatRevertLine(line, sizeof(line), weaponName, positive, neutral, negative);
			CPrintToChat(client, "%s", line);
		}
		while (g_hWeaponRevertsItemClassesConfig.GotoNextKey(false));

		g_hWeaponRevertsItemClassesConfig.GoBack();
	}

	delete printed;
	g_hWeaponRevertsItemClassesConfig.Rewind();
	return Plugin_Handled;
}
