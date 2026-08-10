#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>

#undef REQUIRE_PLUGIN
#include <weaponreverts_api>
#define REQUIRE_PLUGIN

#include "../include/item_indexes.inc"
#include "../include/client_validation.inc"
#include "../include/tf2_classes.inc"

#define WEAPON_REVERTS_CONFIG_PATH "configs/weapons.cfg"
#define WEAPON_REVERTS_ITEM_CLASSES_SECTION "WeaponRevertsItemClasses"

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
	RegConsoleCmd("sm_reverts", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_revert", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_r", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_rp", Command_InfoReverts, "Lists weapon revert data to the client");
	RegConsoleCmd("sm_changes", Command_InfoReverts, "Lists weapon revert data to the client");
}

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int errlen)
{
	MarkNativeAsOptional("WeaponReverts_GetWeaponInfo");
	return APLRes_Success;
}

static KeyValues LoadWeaponRevertsItemClassesConfig()
{
	KeyValues config = new KeyValues("WeaponReverts");

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), WEAPON_REVERTS_CONFIG_PATH);

	if (!config.ImportFromFile(path))
	{
		LogError("[weaponreverts_item_classes] Failed to load %s", path);
		delete config;
		return null;
	}
	return config;
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
	if (!Client_IsInGame(client))
		return Plugin_Handled;

	if (!LibraryExists("weaponreverts")
		|| GetFeatureStatus(FeatureType_Native, "WeaponReverts_GetWeaponInfo") != FeatureStatus_Available)
	{
		CPrintToChat(client, "{green}[Info] {default}No weapon revert data available on this server.");
		return Plugin_Handled;
	}

	char classKey[16];
	TF2Classes_GetKey(TF2_GetPlayerClass(client), classKey, sizeof(classKey));
	if (classKey[0] == '\0')
		return Plugin_Handled;

	KeyValues config = LoadWeaponRevertsItemClassesConfig();
	if (config == null
		|| !config.JumpToKey(WEAPON_REVERTS_ITEM_CLASSES_SECTION, false)
		|| !config.JumpToKey(classKey, false))
	{
		CPrintToChat(client, "{green}[Info] {default}No weapon revert data available for your class.");
		delete config;
		return Plugin_Handled;
	}

	StringMap printed = new StringMap();
	if (config.GotoFirstSubKey(false))
	{
		do
		{
			char indexKey[64];
			config.GetSectionName(indexKey, sizeof(indexKey));
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
		while (config.GotoNextKey(false));
	}

	delete printed;
	delete config;
	return Plugin_Handled;
}
