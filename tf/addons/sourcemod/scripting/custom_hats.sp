#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <sdktools>
#include <tf2_stocks>
#include <tf2attributes>
#include <tf2items>

#define CONFIG_FILE "configs/custom_hats.cfg"
#define DEFAULT_SCOUT_MODEL "models/uma_musume/player/items/scout/mercenary_derby.mdl"
#if !defined EF_BONEMERGE
#define EF_BONEMERGE 0x0010
#endif
#if !defined EF_BONEMERGE_FASTCULL
#define EF_BONEMERGE_FASTCULL 0x0800
#endif

#define MAX_HATS 32
#define HAT_COOKIE_VALUE_LEN 100
static const float HAT_COOKIE_SAVE_DELAY = 2.0;
static const float HAT_POSTINVENTORY_DELAY = 0.1;
static const int HAT_POSTINVENTORY_MAX_RETRIES = 5;

bool g_bHatEnabled[MAXPLAYERS + 1][MAX_HATS];
int g_iHatRef[MAXPLAYERS + 1][MAX_HATS];
int g_iHideHatRef[MAXPLAYERS + 1][MAX_HATS];
char g_szHatIdChoice[MAXPLAYERS + 1][64];
bool g_bHatApplyPending[MAXPLAYERS + 1];
bool g_bHatStateLoaded[MAXPLAYERS + 1];
bool g_bHatStatePending[MAXPLAYERS + 1];
bool g_bHatStatePendingAllowClear[MAXPLAYERS + 1];
Handle g_hPostInventoryTimer[MAXPLAYERS + 1];
int g_iPostInventoryUserId[MAXPLAYERS + 1];
int g_iPostInventoryRetry[MAXPLAYERS + 1];
Handle g_hHatSaveTimer[MAXPLAYERS + 1];
bool g_bHatSaveAllowClear[MAXPLAYERS + 1];
int g_iClientEnabledHatCount[MAXPLAYERS + 1];
Handle g_hHatStateCookie = INVALID_HANDLE;
Handle g_hWearableEquip = INVALID_HANDLE;
int g_iHatPaintChoice[MAXPLAYERS + 1][MAX_HATS];
ConVar g_hHatDebug = null;

enum struct HatConfig
{
	bool enabled;
	char id[64];
	char name[64];
	char model[PLATFORM_MAX_PATH];
	int quality;
	int level;
	int defaultPaint;
	bool paintable;
	int style;
	int bluSkin;
	int classMask;
	int baseDefIndex;
	int baseHideDefIndex;
	int defindexByClass[10];
	int hideDefindexByClass[10];
}

HatConfig g_Hats[MAX_HATS];
int g_iHatCount = 0;
int g_iDefaultHatIndex = -1;
enum
{
	CLASSMASK_ALL = (1 << 9) - 1,
	CLASSMASK_SCOUT = (1 << 0),
	CLASSMASK_SOLDIER = (1 << 1),
	CLASSMASK_PYRO = (1 << 2),
	CLASSMASK_DEMO = (1 << 3),
	CLASSMASK_HEAVY = (1 << 4),
	CLASSMASK_ENGINEER = (1 << 5),
	CLASSMASK_MEDIC = (1 << 6),
	CLASSMASK_SNIPER = (1 << 7),
	CLASSMASK_SPY = (1 << 8)
};
static const int g_ClassMaskByIndex[10] =
{
	0,
	CLASSMASK_SCOUT,
	CLASSMASK_SNIPER,
	CLASSMASK_SOLDIER,
	CLASSMASK_DEMO,
	CLASSMASK_MEDIC,
	CLASSMASK_HEAVY,
	CLASSMASK_PYRO,
	CLASSMASK_SPY,
	CLASSMASK_ENGINEER
};

static const char g_PaintNames[][48] =
{
	"No Paint",
	"A color similar to slate",
	"A deep commitment to purple",
	"A distinctive lack of hue",
	"A mann's mint",
	"After eight",
	"Aged Moustache Grey",
	"An Extraordinary abundance of tinge",
	"Australium gold",
	"Color no 216-190-216",
	"Dark salmon injustice",
	"Drably olive",
	"Indubitably green",
	"Mann co orange",
	"Muskelmannbraun",
	"Noble hatters violet",
	"Peculiarly drab tincture",
	"Pink as hell",
	"Radigan conagher brown",
	"A bitter taste of defeat and lime",
	"The color of a gentlemanns business pants",
	"Ye olde rustic colour",
	"Zepheniahs greed",
	"An air of debonair",
	"Balaclavas are forever",
	"Cream spirit",
	"Operators overalls",
	"Team spirit",
	"The value of teamwork",
	"Waterlogged lab coat"
};

public Plugin myinfo =
{
	name = "Custom Hats",
	author = "Hombre",
	description = "Equips configured custom hats.",
	version = "1.0.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	HookEvent("post_inventory_application", Event_PostInventory, EventHookMode_Post);
	RegConsoleCmd("sm_hats", Command_Hats, "Open the custom hats menu");
	RegConsoleCmd("sm_hat", Command_Hats, "Open the custom hats menu");
	RegConsoleCmd("sm_wear", Command_Hats, "Open the custom hats menu");
	g_hHatStateCookie = RegClientCookie("custom_hats_state", "Custom hats state (hat,paint,hat,paint)", CookieAccess_Public);
	g_hHatDebug = CreateConVar("sm_custom_hats_debug", "0", "Enable custom hats debug logging (0/1).", FCVAR_NONE, true, 0.0, true, 1.0);

	GameData hTF2 = new GameData("sm-tf2.games");
	if (hTF2 == null)
	{
		SetFailState("This plugin is designed for a TF2 dedicated server only.");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetVirtual(hTF2.GetOffset("RemoveWearable") - 1);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hWearableEquip = EndPrepSDKCall();

	if (g_hWearableEquip == null)
	{
		SetFailState("Failed to create call: CBasePlayer::EquipWearable");
	}

	delete hTF2;

	for (int i = 1; i <= MaxClients; i++)
	{
		for (int j = 0; j < MAX_HATS; j++)
		{
			g_bHatEnabled[i][j] = false;
			g_iHatRef[i][j] = INVALID_ENT_REFERENCE;
			g_iHideHatRef[i][j] = INVALID_ENT_REFERENCE;
			g_iHatPaintChoice[i][j] = 0;
		}
		g_szHatIdChoice[i][0] = '\0';
		g_bHatApplyPending[i] = false;
		g_bHatStateLoaded[i] = false;
		g_bHatStatePending[i] = false;
		g_bHatStatePendingAllowClear[i] = false;
		g_hPostInventoryTimer[i] = INVALID_HANDLE;
		g_iPostInventoryUserId[i] = 0;
		g_iPostInventoryRetry[i] = 0;
		g_hHatSaveTimer[i] = INVALID_HANDLE;
		g_bHatSaveAllowClear[i] = false;
		g_iClientEnabledHatCount[i] = 0;
	}

	LoadConfig();
	RecalculateAllClientEnabledHatCounts();
}

public void OnConfigsExecuted()
{
	LoadConfig();
	RecalculateAllClientEnabledHatCounts();
	PrecacheConfiguredHats();
	if (!HasEnabledHats())
	{
		RemoveAllHats();
	}
}

public void OnMapStart()
{
	PrecacheConfiguredHats();
}

public void OnPluginEnd()
{
	RemoveAllHats();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_hPostInventoryTimer[i] != INVALID_HANDLE)
		{
			delete g_hPostInventoryTimer[i];
			g_hPostInventoryTimer[i] = INVALID_HANDLE;
		}
		if (g_hHatSaveTimer[i] != INVALID_HANDLE)
		{
			delete g_hHatSaveTimer[i];
			g_hHatSaveTimer[i] = INVALID_HANDLE;
		}
	}
}

public void OnClientPutInServer(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	for (int i = 0; i < MAX_HATS; i++)
	{
		g_iHatRef[client][i] = INVALID_ENT_REFERENCE;
		g_iHideHatRef[client][i] = INVALID_ENT_REFERENCE;
	}
	g_bHatApplyPending[client] = false;
}

public void OnClientConnected(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	if (g_hPostInventoryTimer[client] != INVALID_HANDLE)
	{
		delete g_hPostInventoryTimer[client];
		g_hPostInventoryTimer[client] = INVALID_HANDLE;
	}
	if (g_hHatSaveTimer[client] != INVALID_HANDLE)
	{
		delete g_hHatSaveTimer[client];
		g_hHatSaveTimer[client] = INVALID_HANDLE;
	}
	g_iPostInventoryUserId[client] = 0;
	g_iPostInventoryRetry[client] = 0;
	g_bHatSaveAllowClear[client] = false;
	g_iClientEnabledHatCount[client] = 0;
	ResetClientHatSelections(client);
	SetClientDefaultHat(client);
	g_bHatStateLoaded[client] = false;
	g_bHatStatePending[client] = false;
	g_bHatStatePendingAllowClear[client] = false;
}

public void OnClientCookiesCached(int client)
{
	if (!IsValidClient(client))
	{
		return;
	}

	if (g_hHatDebug != null && g_hHatDebug.BoolValue)
	{
		LogMessage("[CustomHats] Cookies cached for %N (cached=%d).", client, AreClientCookiesCached(client));
	}

	if (g_bHatStatePending[client])
	{
		if (g_hHatDebug != null && g_hHatDebug.BoolValue)
		{
			LogMessage("[CustomHats] Pending cookie save for %N; saving now.", client);
		}
		SaveHatStateCookie(client, g_bHatStatePendingAllowClear[client]);
		g_bHatStateLoaded[client] = true;
		g_bHatStatePending[client] = false;
		g_bHatStatePendingAllowClear[client] = false;
		return;
	}

	LoadHatStateCookie(client);
	g_bHatStateLoaded[client] = true;
	MigrateLegacyHatCookieIfNeeded(client);
}

public void OnClientDisconnect(int client)
{
	if (g_hPostInventoryTimer[client] != INVALID_HANDLE)
	{
		delete g_hPostInventoryTimer[client];
		g_hPostInventoryTimer[client] = INVALID_HANDLE;
	}
	g_iPostInventoryUserId[client] = 0;
	g_iPostInventoryRetry[client] = 0;
	FlushHatStateSave(client);
	RemoveHat(client, -1, false);
	ResetClientHatSelections(client);
	SetClientDefaultHat(client);
	g_bHatStateLoaded[client] = false;
	g_bHatStatePending[client] = false;
	g_bHatStatePendingAllowClear[client] = false;
}

public Action Command_Hats(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if (!HasEnabledHats())
	{
		ReplyToCommand(client, "[Hats] No hats are available right now.");
		return Plugin_Handled;
	}

	ShowHatMenu(client);
	return Plugin_Handled;
}

public int TF2Items_OnGiveNamedItem_Post(int client, char[] classname, int itemDefinitionIndex, int itemLevel, int itemQuality, int entityIndex)
{
	if (!IsValidClient(client) || g_bHatApplyPending[client])
	{
		return 0;
	}
	if (!g_bHatStateLoaded[client] && AreClientCookiesCached(client))
	{
		LoadHatStateCookie(client);
		g_bHatStateLoaded[client] = true;
	}
	if (!HasEnabledHats())
	{
		return 0;
	}
	if (!HasClientEnabledHats(client))
	{
		return 0;
	}

	g_bHatApplyPending[client] = true;
	return 0;
}

public void Event_PostInventory(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client))
	{
		return;
	}
	if (!g_bHatStateLoaded[client] && AreClientCookiesCached(client))
	{
		LoadHatStateCookie(client);
		g_bHatStateLoaded[client] = true;
	}
	if (TF2_GetPlayerClass(client) == TFClass_Unknown)
	{
		g_bHatApplyPending[client] = false;
		SchedulePostInventoryRefresh(client);
		return;
	}
	bool shouldApply = g_bHatApplyPending[client] || ShouldRefreshHats(client);
	g_bHatApplyPending[client] = false;
	if (!shouldApply)
	{
		SchedulePostInventoryRefresh(client);
		return;
	}
	RequestFrame(ApplyHatFrame, GetClientUserId(client));
	SchedulePostInventoryRefresh(client);
}

static void SchedulePostInventoryRefresh(int client)
{
	if (!HasEnabledHats() || !HasClientEnabledHats(client))
	{
		return;
	}
	g_iPostInventoryRetry[client] = 0;
	g_iPostInventoryUserId[client] = GetClientUserId(client);
	if (g_hPostInventoryTimer[client] != INVALID_HANDLE)
	{
		delete g_hPostInventoryTimer[client];
		g_hPostInventoryTimer[client] = INVALID_HANDLE;
	}
	g_hPostInventoryTimer[client] = CreateTimer(HAT_POSTINVENTORY_DELAY, Timer_PostInventoryRefresh, client);
}

public Action Timer_PostInventoryRefresh(Handle timer, any client)
{
	int index = view_as<int>(client);
	if (index <= 0 || index > MaxClients)
	{
		return Plugin_Stop;
	}
	g_hPostInventoryTimer[index] = INVALID_HANDLE;
	if (!IsValidClient(index))
	{
		return Plugin_Stop;
	}
	if (g_iPostInventoryUserId[index] != GetClientUserId(index))
	{
		return Plugin_Stop;
	}
	if (!g_bHatStateLoaded[index] && !AreClientCookiesCached(index))
	{
		return Plugin_Stop;
	}
	if (TF2_GetPlayerClass(index) == TFClass_Unknown)
	{
		if (g_iPostInventoryRetry[index] < HAT_POSTINVENTORY_MAX_RETRIES)
		{
			g_iPostInventoryRetry[index]++;
			g_hPostInventoryTimer[index] = CreateTimer(HAT_POSTINVENTORY_DELAY, Timer_PostInventoryRefresh, index);
		}
		return Plugin_Stop;
	}
	g_iPostInventoryRetry[index] = 0;
	if (CookieMatchesEquippedHats(index))
	{
		return Plugin_Stop;
	}
	if (ShouldRefreshHats(index))
	{
		RequestFrame(ApplyHatFrame, GetClientUserId(index));
	}
	return Plugin_Stop;
}

public void ApplyHatFrame(any userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client))
	{
		return;
	}
	UpdateHatForClient(client);
}

void ResetClientHatSelections(int client)
{
	for (int i = 0; i < MAX_HATS; i++)
	{
		g_bHatEnabled[client][i] = false;
		g_iHatPaintChoice[client][i] = 0;
	}
	for (int i = 0; i < g_iHatCount; i++)
	{
		g_iHatPaintChoice[client][i] = ClampPaintIndex(g_Hats[i].defaultPaint);
	}
	g_iClientEnabledHatCount[client] = 0;
}

static void RecalculateClientEnabledHatCount(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	int count = 0;
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (g_bHatEnabled[client][i] && IsHatEnabled(i))
		{
			count++;
		}
	}
	g_iClientEnabledHatCount[client] = count;
}

static void RecalculateAllClientEnabledHatCounts()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		RecalculateClientEnabledHatCount(i);
	}
}

static void SetClientHatEnabled(int client, int hatIndex, bool enabled)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	if (!IsHatIndexValid(hatIndex))
	{
		return;
	}
	if (g_bHatEnabled[client][hatIndex] == enabled)
	{
		return;
	}
	g_bHatEnabled[client][hatIndex] = enabled;
	if (IsHatEnabled(hatIndex))
	{
		if (enabled)
		{
			g_iClientEnabledHatCount[client]++;
		}
		else if (g_iClientEnabledHatCount[client] > 0)
		{
			g_iClientEnabledHatCount[client]--;
		}
	}
}

bool HasClientEnabledHats(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return false;
	}
	return g_iClientEnabledHatCount[client] > 0;
}

void MigrateLegacyHatCookieIfNeeded(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	if (!AreClientCookiesCached(client))
	{
		return;
	}

	char stateValue[HAT_COOKIE_VALUE_LEN];
	GetClientCookie(client, g_hHatStateCookie, stateValue, sizeof(stateValue));
	if (!stateValue[0])
	{
		return;
	}
	if (StrContains(stateValue, "|") == -1 && StrContains(stateValue, ":") == -1)
	{
		return;
	}

	if (g_hHatDebug != null && g_hHatDebug.BoolValue)
	{
		LogMessage("[CustomHats] Legacy cookie detected for %N: \"%s\"", client, stateValue);
	}

	LoadHatStateCookie(client);
	g_bHatStateLoaded[client] = true;
}

bool TryParseNonNegativeInt(const char[] text, int &value)
{
	if (!text[0])
	{
		return false;
	}
	value = StringToInt(text);
	if (value == 0 && !StrEqual(text, "0"))
	{
		return false;
	}
	return value >= 0;
}

void UpdateHatForClient(int client)
{
	if (!HasEnabledHats() || !HasClientEnabledHats(client))
	{
		RemoveHat(client, -1);
		return;
	}

	if (GetClientTeam(client) <= 1)
	{
		RemoveHat(client, -1);
		return;
	}

	TFClassType playerClass = TF2_GetPlayerClass(client);
	if (playerClass == TFClass_Unknown)
	{
		return;
	}
	int classIndex = view_as<int>(playerClass);
	for (int i = 0; i < g_iHatCount; i++)
	{
		bool enabled = g_bHatEnabled[client][i] && IsHatEnabled(i) && IsClassAllowedForHat(i, playerClass);
		if (!enabled)
		{
			RemoveHatIndex(client, i);
			continue;
		}

		bool hatValid = HasValidEntRef(g_iHatRef[client][i]);
		bool hideValid = HasValidEntRef(g_iHideHatRef[client][i]);
		bool shouldHaveHide = (GetHideDefIndexForClass(i, classIndex) > 0);
		if (hatValid && ((shouldHaveHide && hideValid) || (!shouldHaveHide && !hideValid)))
		{
			continue;
		}

		EquipHat(client, i);
	}
}

static bool HasValidEntRef(int entRef)
{
	int ent = EntRefToEntIndex(entRef);
	return ent != INVALID_ENT_REFERENCE;
}

static bool ShouldRefreshHats(int client)
{
	if (!HasEnabledHats() || !HasClientEnabledHats(client))
	{
		return false;
	}

	TFClassType playerClass = TF2_GetPlayerClass(client);
	int classIndex = view_as<int>(playerClass);
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (!g_bHatEnabled[client][i] || !IsHatEnabled(i))
		{
			continue;
		}

		bool allowed = IsClassAllowedForHat(i, playerClass);
		bool hatValid = HasValidEntRef(g_iHatRef[client][i]);
		bool hideValid = HasValidEntRef(g_iHideHatRef[client][i]);
		bool shouldHaveHide = allowed && (GetHideDefIndexForClass(i, classIndex) > 0);

		if (allowed && !hatValid)
		{
			return true;
		}
		if (!allowed && hatValid)
		{
			return true;
		}
		if (shouldHaveHide && !hideValid)
		{
			return true;
		}
		if (!shouldHaveHide && hideValid)
		{
			return true;
		}
	}

	return false;
}

static bool CookieMatchesEquippedHats(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return true;
	}
	if (!g_bHatStateLoaded[client])
	{
		return false;
	}

	TFClassType playerClass = TF2_GetPlayerClass(client);
	if (playerClass == TFClass_Unknown)
	{
		return false;
	}
	int classIndex = view_as<int>(playerClass);
	for (int i = 0; i < g_iHatCount; i++)
	{
		bool enabled = g_bHatEnabled[client][i] && IsHatEnabled(i) && IsClassAllowedForHat(i, playerClass);
		bool hatValid = HasValidEntRef(g_iHatRef[client][i]);
		bool hideValid = HasValidEntRef(g_iHideHatRef[client][i]);
		bool shouldHaveHide = enabled && (GetHideDefIndexForClass(i, classIndex) > 0);

		if (enabled && !hatValid)
		{
			return false;
		}
		if (!enabled && hatValid)
		{
			return false;
		}
		if (shouldHaveHide && !hideValid)
		{
			return false;
		}
		if (!shouldHaveHide && hideValid)
		{
			return false;
		}
	}

	return true;
}

void ShowHatMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Hats);
	menu.SetTitle("Custom Hats");
	TFClassType playerClass = TF2_GetPlayerClass(client);
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (!IsHatEnabled(i))
		{
			continue;
		}
		if (!IsClassAllowedForHat(i, playerClass))
		{
			continue;
		}
		char label[128];
		Format(label, sizeof(label), "%s%s", g_Hats[i].name, g_bHatEnabled[client][i] ? " [ON]" : "");
		menu.AddItem(g_Hats[i].id, label);
	}
	menu.ExitBackButton = false;
	menu.Display(client, 20);
}

public int MenuHandler_Hats(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char itemId[64];
		menu.GetItem(item, itemId, sizeof(itemId));
		strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), itemId);
		int hatIndex = FindHatIndexById(itemId);
		if (hatIndex >= 0)
		{
			g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(g_Hats[hatIndex].defaultPaint);
		}
		ShowHatToggleMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowHatToggleMenu(int client)
{
	Menu menu = new Menu(MenuHandler_HatToggle);
	int hatIndex = GetSelectedHatIndex(client);
	if (hatIndex >= 0)
	{
		menu.SetTitle(g_Hats[hatIndex].name);
	}
	else
	{
		menu.SetTitle("Custom Hat");
	}
	menu.AddItem("enable", "1. Enable");
	menu.AddItem("disable", "2. Disable");
	if (hatIndex >= 0 && g_Hats[hatIndex].paintable)
	{
		menu.AddItem("paint", "3. Paint");
	}
	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int MenuHandler_HatToggle(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		int hatIndex = GetSelectedHatIndex(client);
		if (hatIndex < 0)
		{
			return 0;
		}

		if (StrEqual(info, "enable"))
		{
			SetClientHatEnabled(client, hatIndex, true);
			QueueHatStateSave(client);
			if (g_Hats[hatIndex].paintable)
			{
				ShowHatPaintMenu(client);
			}
			else
			{
				EquipHat(client, hatIndex);
			}
		}
		else if (StrEqual(info, "disable"))
		{
			SetClientHatEnabled(client, hatIndex, false);
			QueueHatStateSave(client, true);
			RemoveHat(client, hatIndex);
			PrintToChat(client, "[Hats] Disabled %s.", g_Hats[hatIndex].name);
		}
		else if (StrEqual(info, "paint"))
		{
			ShowHatPaintMenu(client);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowHatPaintMenu(int client)
{
	Menu menu = new Menu(MenuHandler_HatPaint);
	menu.SetTitle("Select Paint");

	char key[8];
	for (int i = 0; i < sizeof(g_PaintNames); i++)
	{
		IntToString(i, key, sizeof(key));
		menu.AddItem(key, g_PaintNames[i]);
	}

	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int MenuHandler_HatPaint(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		int paint = ClampPaintIndex(StringToInt(info));
		int hatIndex = GetSelectedHatIndex(client);
		if (hatIndex < 0)
		{
			return 0;
		}
		if (!g_Hats[hatIndex].paintable)
		{
			return 0;
		}
		g_iHatPaintChoice[client][hatIndex] = paint;
		SetClientHatEnabled(client, hatIndex, true);
		QueueHatStateSave(client);

		EquipHat(client, hatIndex);
		PrintToChat(client, "[Hats] %s applied.", g_PaintNames[paint]);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void EquipHat(int client, int hatIndex)
{
	RemoveHat(client, hatIndex, false);

	TFClassType playerClass = TF2_GetPlayerClass(client);
	if (!IsClassAllowedForHat(hatIndex, playerClass))
	{
		return;
	}

	int classIndex = view_as<int>(playerClass);
	int hideDefIndex = GetHideDefIndexForClass(hatIndex, classIndex);
	if (hideDefIndex > 0)
	{
		int hideWearable = CreateWearableBase(client, hideDefIndex, g_Hats[hatIndex].level, g_Hats[hatIndex].quality);
		if (hideWearable != -1)
		{
			g_iHideHatRef[client][hatIndex] = EntIndexToEntRef(hideWearable);
		}
	}

	int hatDefIndex = GetHatDefIndexForClass(hatIndex, classIndex);
	if (hatDefIndex <= 0)
	{
		return;
	}
	int paint = g_iHatPaintChoice[client][hatIndex];
	int wearable = CreateHat(client, g_Hats[hatIndex].model, hatDefIndex, g_Hats[hatIndex].level, g_Hats[hatIndex].quality, paint, g_Hats[hatIndex].style);
	if (wearable != -1)
	{
		if (g_Hats[hatIndex].bluSkin >= 0 && GetClientTeam(client) == view_as<int>(TFTeam_Blue))
		{
			SetEntProp(wearable, Prop_Send, "m_nSkin", g_Hats[hatIndex].bluSkin);
		}
		g_iHatRef[client][hatIndex] = EntIndexToEntRef(wearable);
	}
	QueueHatStateSave(client);
}

void RemoveHatIndex(int client, int hatIndex)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	int ent = EntRefToEntIndex(g_iHatRef[client][hatIndex]);
	if (ent != INVALID_ENT_REFERENCE)
	{
		RemoveEntity(ent);
	}
	g_iHatRef[client][hatIndex] = INVALID_ENT_REFERENCE;

	int hideEnt = EntRefToEntIndex(g_iHideHatRef[client][hatIndex]);
	if (hideEnt != INVALID_ENT_REFERENCE)
	{
		RemoveEntity(hideEnt);
	}
	g_iHideHatRef[client][hatIndex] = INVALID_ENT_REFERENCE;
}

void RemoveHat(int client, int hatIndex, bool saveState = true)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	if (hatIndex < 0)
	{
		for (int i = 0; i < MAX_HATS; i++)
		{
			RemoveHatIndex(client, i);
		}
		if (saveState)
		{
			QueueHatStateSave(client);
		}
		return;
	}

	RemoveHatIndex(client, hatIndex);
	if (saveState)
	{
		QueueHatStateSave(client);
	}
}

int CreateWearableBase(int client, int itemIndex, int level, int quality)
{
	if (itemIndex <= 0)
	{
		return -1;
	}

	int entity = CreateEntityByName("tf_wearable");
	if (entity == -1 || !IsValidEntity(entity))
	{
		return -1;
	}

	SetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex", itemIndex);
	SetEntProp(entity, Prop_Send, "m_bInitialized", 1);
	SetEntProp(entity, Prop_Send, "m_iEntityLevel", level);
	SetEntProp(entity, Prop_Send, "m_iEntityQuality", quality);
	SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
	SetEntProp(entity, Prop_Send, "m_iAccountID", GetSteamAccountID(client));
	SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", client);

	SetEntProp(entity, Prop_Send, "m_fEffects", EF_BONEMERGE | EF_BONEMERGE_FASTCULL);
	SetEntProp(entity, Prop_Send, "m_iTeamNum", GetClientTeam(client));
	SetEntProp(entity, Prop_Send, "m_nSkin", GetClientTeam(client));
	SetEntProp(entity, Prop_Send, "m_usSolidFlags", 4);
	SetEntProp(entity, Prop_Send, "m_CollisionGroup", 11);
	SetEntProp(entity, Prop_Send, "m_iItemIDLow", 2048);
	SetEntProp(entity, Prop_Send, "m_iItemIDHigh", 0);

	DispatchSpawn(entity);
	ActivateEntity(entity);
	SDKCall(g_hWearableEquip, client, entity);

	return entity;
}

int CreateHat(int client, const char[] modelPath, int itemIndex, int level, int quality, int paint, int style)
{
	int entity = CreateWearableBase(client, itemIndex, level, quality);
	if (entity == -1)
	{
		return -1;
	}

	ApplyCustomModel(entity, modelPath);

	if (paint > 0)
	{
		ApplyPaint(entity, paint);
	}

	ApplyStyle(entity, style);
	return entity;
}

int ClampPaintIndex(int paint)
{
	if (paint < 0)
	{
		return 0;
	}
	int maxPaint = sizeof(g_PaintNames) - 1;
	if (paint > maxPaint)
	{
		return maxPaint;
	}
	return paint;
}

void ResetHatConfig(HatConfig hat)
{
	hat.enabled = false;
	hat.id[0] = '\0';
	hat.name[0] = '\0';
	hat.model[0] = '\0';
	hat.quality = 6;
	hat.level = 10;
	hat.defaultPaint = 0;
	hat.paintable = false;
	hat.style = 0;
	hat.bluSkin = -1;
	hat.classMask = CLASSMASK_SCOUT;
	hat.baseDefIndex = 0;
	hat.baseHideDefIndex = 0;
	for (int i = 0; i < sizeof(hat.defindexByClass); i++)
	{
		hat.defindexByClass[i] = 0;
		hat.hideDefindexByClass[i] = 0;
	}
}

bool IsHatIndexValid(int hatIndex)
{
	return hatIndex >= 0 && hatIndex < g_iHatCount;
}

bool IsHatEnabled(int hatIndex)
{
	return IsHatIndexValid(hatIndex) && g_Hats[hatIndex].enabled && g_Hats[hatIndex].model[0];
}

bool HasEnabledHats()
{
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (IsHatEnabled(i))
		{
			return true;
		}
	}
	return false;
}

int FindHatIndexById(const char[] id)
{
	if (!id[0])
	{
		return -1;
	}
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (StrEqual(g_Hats[i].id, id, false))
		{
			return i;
		}
	}
	return -1;
}

int GetDefaultHatIndex()
{
	if (IsHatEnabled(g_iDefaultHatIndex))
	{
		return g_iDefaultHatIndex;
	}
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (IsHatEnabled(i))
		{
			return i;
		}
	}
	return -1;
}

int GetSelectedHatIndex(int client)
{
	int hatIndex = FindHatIndexById(g_szHatIdChoice[client]);
	if (IsHatEnabled(hatIndex))
	{
		return hatIndex;
	}
	int defaultIndex = GetDefaultHatIndex();
	if (defaultIndex >= 0)
	{
		strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), g_Hats[defaultIndex].id);
	}
	else
	{
		g_szHatIdChoice[client][0] = '\0';
	}
	return defaultIndex;
}

void SetClientDefaultHat(int client)
{
	int hatIndex = GetDefaultHatIndex();
	if (hatIndex >= 0)
	{
		strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), g_Hats[hatIndex].id);
		g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(g_Hats[hatIndex].defaultPaint);
	}
	else
	{
		g_szHatIdChoice[client][0] = '\0';
	}
}

bool AddHatConfig(HatConfig hat)
{
	if (!hat.id[0])
	{
		return false;
	}
	if (FindHatIndexById(hat.id) >= 0)
	{
		LogError("[CustomHats] Duplicate hat id in config: %s", hat.id);
		return false;
	}
	if (g_iHatCount >= MAX_HATS)
	{
		LogError("[CustomHats] Too many hats configured (max %d).", MAX_HATS);
		return false;
	}
	if (!hat.name[0])
	{
		strcopy(hat.name, sizeof(hat.name), hat.id);
	}
	int hatIndex = g_iHatCount;
	g_Hats[hatIndex] = hat;
	if (hat.enabled && g_iDefaultHatIndex < 0)
	{
		g_iDefaultHatIndex = hatIndex;
	}
	g_iHatCount++;
	return true;
}

int ParseClassMask(const char[] list)
{
	char buffer[128];
	strcopy(buffer, sizeof(buffer), list);
	TrimString(buffer);
	ToLowercaseInPlace(buffer, sizeof(buffer));

	if (!buffer[0])
	{
		return CLASSMASK_SCOUT;
	}
	if (StrEqual(buffer, "all"))
	{
		return CLASSMASK_ALL;
	}

	int mask = 0;
	char parts[16][32];
	int count = ExplodeString(buffer, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < count; i++)
	{
		TrimString(parts[i]);
		ToLowercaseInPlace(parts[i], sizeof(parts[i]));
		if (!parts[i][0])
		{
			continue;
		}
		if (StrEqual(parts[i], "all"))
		{
			return CLASSMASK_ALL;
		}
		if (StrEqual(parts[i], "scout"))
		{
			mask |= CLASSMASK_SCOUT;
		}
		else if (StrEqual(parts[i], "soldier"))
		{
			mask |= CLASSMASK_SOLDIER;
		}
		else if (StrEqual(parts[i], "pyro"))
		{
			mask |= CLASSMASK_PYRO;
		}
		else if (StrEqual(parts[i], "demoman") || StrEqual(parts[i], "demo"))
		{
			mask |= CLASSMASK_DEMO;
		}
		else if (StrEqual(parts[i], "heavy"))
		{
			mask |= CLASSMASK_HEAVY;
		}
		else if (StrEqual(parts[i], "engineer"))
		{
			mask |= CLASSMASK_ENGINEER;
		}
		else if (StrEqual(parts[i], "medic"))
		{
			mask |= CLASSMASK_MEDIC;
		}
		else if (StrEqual(parts[i], "sniper"))
		{
			mask |= CLASSMASK_SNIPER;
		}
		else if (StrEqual(parts[i], "spy"))
		{
			mask |= CLASSMASK_SPY;
		}
	}

	if (mask == 0)
	{
		mask = CLASSMASK_SCOUT;
	}
	return mask;
}

bool IsClassAllowedForHat(int hatIndex, TFClassType class)
{
	if (!IsHatIndexValid(hatIndex))
	{
		return false;
	}
	int classIndex = view_as<int>(class);
	if (classIndex < 1 || classIndex > 9)
	{
		return false;
	}
	return (g_Hats[hatIndex].classMask & g_ClassMaskByIndex[classIndex]) != 0;
}

void ToLowercaseInPlace(char[] str, int maxlen)
{
	for (int i = 0; i < maxlen && str[i] != '\0'; i++)
	{
		str[i] = CharToLower(str[i]);
	}
}

bool ParseBoolString(const char[] value, bool defaultValue)
{
	if (!value[0])
	{
		return defaultValue;
	}
	if (StrEqual(value, "1") || StrEqual(value, "true", false) || StrEqual(value, "yes", false) || StrEqual(value, "on", false))
	{
		return true;
	}
	if (StrEqual(value, "0") || StrEqual(value, "false", false) || StrEqual(value, "no", false) || StrEqual(value, "off", false))
	{
		return false;
	}
	return defaultValue;
}

void LoadClassOverrides(KeyValues kv, const char[] key, TFClassType class, HatConfig hat)
{
	if (!kv.JumpToKey(key))
	{
		return;
	}

	int classIndex = view_as<int>(class);
	if (classIndex < 1 || classIndex > 9)
	{
		kv.GoBack();
		return;
	}

	int defindex = kv.GetNum("defindex", 0);
	int hideDefindex = kv.GetNum("hide_defindex", 0);
	if (defindex > 0)
	{
		hat.defindexByClass[classIndex] = defindex;
	}
	if (hideDefindex > 0)
	{
		hat.hideDefindexByClass[classIndex] = hideDefindex;
	}
	kv.GoBack();
}

int GetHatDefIndexForClass(int hatIndex, int classIndex)
{
	if (!IsHatIndexValid(hatIndex) || classIndex < 1 || classIndex > 9)
	{
		return 0;
	}
	int defindex = g_Hats[hatIndex].defindexByClass[classIndex];
	if (defindex > 0)
	{
		return defindex;
	}
	return g_Hats[hatIndex].baseDefIndex;
}

int GetHideDefIndexForClass(int hatIndex, int classIndex)
{
	if (!IsHatIndexValid(hatIndex) || classIndex < 1 || classIndex > 9)
	{
		return 0;
	}
	int defindex = g_Hats[hatIndex].hideDefindexByClass[classIndex];
	if (defindex > 0)
	{
		return defindex;
	}
	return g_Hats[hatIndex].baseHideDefIndex;
}

void LoadHatStateCookie(int client)
{
	ResetClientHatSelections(client);
	g_szHatIdChoice[client][0] = '\0';

	if (g_hHatStateCookie == INVALID_HANDLE || !AreClientCookiesCached(client))
	{
		SetClientDefaultHat(client);
		return;
	}

	char stateValue[HAT_COOKIE_VALUE_LEN];
	GetClientCookie(client, g_hHatStateCookie, stateValue, sizeof(stateValue));
	if (!stateValue[0])
	{
		SetClientDefaultHat(client);
		return;
	}

	if (g_hHatDebug != null && g_hHatDebug.BoolValue)
	{
		LogMessage("[CustomHats] Load cookie for %N: \"%s\"", client, stateValue);
	}

	bool needsResave = false;
	if (StrContains(stateValue, "|") != -1)
	{
		char parts[3][64];
		int count = ExplodeString(stateValue, "|", parts, sizeof(parts), sizeof(parts[]));
		if (count > 1 && parts[1][0] != '\0' && StringToInt(parts[0]) != 0)
		{
			int hatIndex = FindHatIndexById(parts[1]);
			if (IsHatEnabled(hatIndex))
			{
				g_bHatEnabled[client][hatIndex] = true;
				if (count > 2)
				{
					g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(StringToInt(parts[2]));
				}
				if (!g_Hats[hatIndex].paintable)
				{
					g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(g_Hats[hatIndex].defaultPaint);
				}
				strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), parts[1]);
			}
		}
		needsResave = true;
		if (!g_szHatIdChoice[client][0])
		{
			SetClientDefaultHat(client);
		}
		RecalculateClientEnabledHatCount(client);
		if (needsResave)
		{
			SaveHatStateCookie(client);
		}
		return;
	}

	if (StrContains(stateValue, ":") != -1)
	{
		char entries[32][96];
		int entryCount = ExplodeString(stateValue, ",", entries, sizeof(entries), sizeof(entries[]));
		for (int i = 0; i < entryCount; i++)
		{
			TrimString(entries[i]);
			if (!entries[i][0])
			{
				continue;
			}

			char entryParts[2][64];
			int partCount = ExplodeString(entries[i], ":", entryParts, sizeof(entryParts), sizeof(entryParts[]));
			if (partCount <= 0 || !entryParts[0][0])
			{
				continue;
			}

			int hatIndex = FindHatIndexById(entryParts[0]);
			if (!IsHatEnabled(hatIndex))
			{
				continue;
			}

			g_bHatEnabled[client][hatIndex] = true;
			if (partCount > 1 && entryParts[1][0])
			{
				g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(StringToInt(entryParts[1]));
			}
			if (!g_Hats[hatIndex].paintable)
			{
				g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(g_Hats[hatIndex].defaultPaint);
			}

			if (!g_szHatIdChoice[client][0])
			{
				strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), g_Hats[hatIndex].id);
			}
		}
		needsResave = true;
	}
	else
	{
		char entries[64][12];
		int entryCount = ExplodeString(stateValue, ",", entries, sizeof(entries), sizeof(entries[]));
		for (int i = 0; i + 1 < entryCount; i += 2)
		{
			int hatIndex = 0;
			int paint = 0;
			if (!TryParseNonNegativeInt(entries[i], hatIndex))
			{
				continue;
			}
			if (!TryParseNonNegativeInt(entries[i + 1], paint))
			{
				continue;
			}
			if (!IsHatEnabled(hatIndex))
			{
				continue;
			}
			g_bHatEnabled[client][hatIndex] = true;
			g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(paint);
			if (!g_Hats[hatIndex].paintable)
			{
				g_iHatPaintChoice[client][hatIndex] = ClampPaintIndex(g_Hats[hatIndex].defaultPaint);
			}
			if (!g_szHatIdChoice[client][0])
			{
				strcopy(g_szHatIdChoice[client], sizeof(g_szHatIdChoice[]), g_Hats[hatIndex].id);
			}
		}
	}

	if (!g_szHatIdChoice[client][0])
	{
		SetClientDefaultHat(client);
	}
	RecalculateClientEnabledHatCount(client);

	if (needsResave)
	{
		SaveHatStateCookie(client);
	}
}

static void QueueHatStateSave(int client, bool allowClear = false)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	if (allowClear)
	{
		g_bHatSaveAllowClear[client] = true;
	}
	if (g_hHatSaveTimer[client] != INVALID_HANDLE)
	{
		delete g_hHatSaveTimer[client];
		g_hHatSaveTimer[client] = INVALID_HANDLE;
	}
	g_hHatSaveTimer[client] = CreateTimer(HAT_COOKIE_SAVE_DELAY, Timer_HatStateSave, client);
}

static void FlushHatStateSave(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	if (g_hHatSaveTimer[client] == INVALID_HANDLE)
	{
		return;
	}
	delete g_hHatSaveTimer[client];
	g_hHatSaveTimer[client] = INVALID_HANDLE;
	bool allowClear = g_bHatSaveAllowClear[client];
	g_bHatSaveAllowClear[client] = false;
	SaveHatStateCookie(client, allowClear);
}

public Action Timer_HatStateSave(Handle timer, any client)
{
	int index = view_as<int>(client);
	if (index <= 0 || index > MaxClients)
	{
		return Plugin_Stop;
	}
	g_hHatSaveTimer[index] = INVALID_HANDLE;
	bool allowClear = g_bHatSaveAllowClear[index];
	g_bHatSaveAllowClear[index] = false;
	SaveHatStateCookie(index, allowClear);
	return Plugin_Stop;
}

void SaveHatStateCookie(int client, bool allowClear = false)
{
	if (g_hHatStateCookie == INVALID_HANDLE || client <= 0 || client > MaxClients)
	{
		return;
	}

	if (!AreClientCookiesCached(client))
	{
		g_bHatStatePending[client] = true;
		g_bHatStatePendingAllowClear[client] = allowClear;
		if (g_hHatDebug != null && g_hHatDebug.BoolValue)
		{
			LogMessage("[CustomHats] Cookie cache not ready for %N; deferring save.", client);
		}
		return;
	}

	char state[HAT_COOKIE_VALUE_LEN];
	state[0] = '\0';

	bool first = true;
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (!g_bHatEnabled[client][i] || !IsHatEnabled(i))
		{
			continue;
		}

		int paint = g_Hats[i].paintable
			? ClampPaintIndex(g_iHatPaintChoice[client][i])
			: ClampPaintIndex(g_Hats[i].defaultPaint);
		char entry[24];
		Format(entry, sizeof(entry), "%d,%d", i, paint);

		int needed = strlen(state) + strlen(entry) + (first ? 0 : 1);
		if (needed >= sizeof(state))
		{
			break;
		}

		if (!first)
		{
			StrCat(state, sizeof(state), ",");
		}
		StrCat(state, sizeof(state), entry);
		first = false;
	}

	if (!state[0] && !allowClear)
	{
		if (g_hHatDebug != null && g_hHatDebug.BoolValue)
		{
			LogMessage("[CustomHats] Skipping empty cookie save for %N.", client);
		}
		return;
	}

	if (g_hHatDebug != null && g_hHatDebug.BoolValue)
	{
		LogMessage("[CustomHats] Save cookie for %N: \"%s\"", client, state);
	}
	SetClientCookie(client, g_hHatStateCookie, state);
}


void RemoveAllHats()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			RemoveHat(i, -1);
		}
	}
}

void PrecacheConfiguredHats()
{
	for (int i = 0; i < g_iHatCount; i++)
	{
		if (!IsHatEnabled(i))
		{
			continue;
		}
		PrecacheModel(g_Hats[i].model, true);
	}
}

void LoadConfig()
{
	g_iHatCount = 0;
	g_iDefaultHatIndex = -1;
	for (int i = 0; i < MAX_HATS; i++)
	{
		ResetHatConfig(g_Hats[i]);
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

	if (!FileExists(path))
	{
		CreateDefaultConfig(path);
	}

	KeyValues kv = new KeyValues("CustomHats");
	if (!kv.ImportFromFile(path))
	{
		LogError("[CustomHats] Failed to parse config file: %s", path);
		delete kv;
		return;
	}

	if (kv.JumpToKey("hats", false))
	{
		if (kv.GotoFirstSubKey())
		{
			do
			{
				if (g_iHatCount >= MAX_HATS)
				{
					LogError("[CustomHats] Too many hats configured (max %d).", MAX_HATS);
					break;
				}

				char hatId[64];
				kv.GetSectionName(hatId, sizeof(hatId));

				HatConfig hat;
				ResetHatConfig(hat);
				strcopy(hat.id, sizeof(hat.id), hatId);
				kv.GetString("name", hat.name, sizeof(hat.name), hatId);
				kv.GetString("model", hat.model, sizeof(hat.model), DEFAULT_SCOUT_MODEL);
				hat.enabled = (kv.GetNum("enabled", 1) != 0) && hat.model[0];
				hat.baseDefIndex = kv.GetNum("defindex", 0);
				hat.baseHideDefIndex = kv.GetNum("hide_defindex", 0);
				hat.quality = kv.GetNum("quality", 6);
				hat.level = kv.GetNum("level", 10);
				int paintIndex = kv.GetNum("paint_index", -1);
				if (paintIndex < 0)
				{
					paintIndex = kv.GetNum("paint", 0);
				}
				hat.defaultPaint = ClampPaintIndex(paintIndex);
				char paintFlag[8];
				kv.GetString("paint", paintFlag, sizeof(paintFlag), "false");
	hat.paintable = ParseBoolString(paintFlag, false);
	hat.style = kv.GetNum("style", 0);
	hat.bluSkin = kv.GetNum("blu_skin", -1);

	char classes[128];
	kv.GetString("classes", classes, sizeof(classes), "scout");
	hat.classMask = ParseClassMask(classes);

				LoadClassOverrides(kv, "soldier", TFClass_Soldier, hat);
				LoadClassOverrides(kv, "pyro", TFClass_Pyro, hat);
				LoadClassOverrides(kv, "demoman", TFClass_DemoMan, hat);
				LoadClassOverrides(kv, "heavy", TFClass_Heavy, hat);
				LoadClassOverrides(kv, "engineer", TFClass_Engineer, hat);
				LoadClassOverrides(kv, "medic", TFClass_Medic, hat);
				LoadClassOverrides(kv, "sniper", TFClass_Sniper, hat);
				LoadClassOverrides(kv, "spy", TFClass_Spy, hat);

				AddHatConfig(hat);
			}
			while (kv.GotoNextKey());
			kv.GoBack();
		}
		kv.GoBack();
	}

	delete kv;
}

void CreateDefaultConfig(const char[] path)
{
	File file = OpenFile(path, "w");
	if (file == null)
	{
		LogError("[CustomHats] Failed to create config file: %s", path);
		return;
	}

	file.WriteLine("\"CustomHats\"");
	file.WriteLine("{");
	file.WriteLine("    \"hats\"");
	file.WriteLine("    {");
	file.WriteLine("        \"mercenary_derby\"");
	file.WriteLine("        {");
	file.WriteLine("            \"name\" \"mercenary_derby\"");
	file.WriteLine("            \"enabled\" \"1\"");
	file.WriteLine("            \"model\" \"%s\"", DEFAULT_SCOUT_MODEL);
	file.WriteLine("            \"defindex\" \"451\"");
	file.WriteLine("            \"hide_defindex\" \"111\"");
	file.WriteLine("            \"quality\" \"6\"");
	file.WriteLine("            \"level\" \"10\"");
	file.WriteLine("            \"paint\" \"false\"");
	file.WriteLine("            \"paint_index\" \"0\"");
	file.WriteLine("            \"style\" \"0\"");
	file.WriteLine("            \"classes\" \"all\"");
	file.WriteLine("        }");
	file.WriteLine("    }");
	file.WriteLine("}");
	delete file;
}

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void ApplyCustomModel(int entity, const char[] modelPath)
{
	if (!modelPath[0])
	{
		return;
	}

	int modelIndex = PrecacheModel(modelPath, true);
	SetEntityModel(entity, modelPath);
	SetEntProp(entity, Prop_Send, "m_nModelIndex", modelIndex);
	if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
	{
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
	}

	if (HasEntProp(entity, Prop_Send, "m_nModelIndexOverrides"))
	{
		int count = GetEntPropArraySize(entity, Prop_Send, "m_nModelIndexOverrides");
		for (int i = 0; i < count; i++)
		{
			SetEntProp(entity, Prop_Send, "m_nModelIndexOverrides", modelIndex, .element = i);
		}
	}
}

void ApplyStyle(int entity, int style)
{
	if (style < 0)
	{
		return;
	}

	TF2Attrib_SetByDefIndex(entity, 834, float(style));
	if (HasEntProp(entity, Prop_Send, "m_nStyle"))
	{
		SetEntProp(entity, Prop_Send, "m_nStyle", style);
	}
}

void ApplyPaint(int hat, int paint)
{
	switch (paint)
	{
		case 1:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3100495.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3100495.0);
		}
		case 2:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8208497.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8208497.0);
		}
		case 3:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 1315860.0);
			TF2Attrib_SetByDefIndex(hat, 261, 1315860.0);
		}
		case 4:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12377523.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12377523.0);
		}
		case 5:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 2960676.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2960676.0);
		}
		case 6:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8289918.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8289918.0);
		}
		case 7:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15132390.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15132390.0);
		}
		case 8:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15185211.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15185211.0);
		}
		case 9:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 14204632.0);
			TF2Attrib_SetByDefIndex(hat, 261, 14204632.0);
		}
		case 10:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15308410.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15308410.0);
		}
		case 11:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8421376.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8421376.0);
		}
		case 12:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 7511618.0);
			TF2Attrib_SetByDefIndex(hat, 261, 7511618.0);
		}
		case 13:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 13595446.0);
			TF2Attrib_SetByDefIndex(hat, 261, 13595446.0);
		}
		case 14:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 10843461.0);
			TF2Attrib_SetByDefIndex(hat, 261, 10843461.0);
		}
		case 15:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 5322826.0);
			TF2Attrib_SetByDefIndex(hat, 261, 5322826.0);
		}
		case 16:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12955537.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12955537.0);
		}
		case 17:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 16738740.0);
			TF2Attrib_SetByDefIndex(hat, 261, 16738740.0);
		}
		case 18:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 6901050.0);
			TF2Attrib_SetByDefIndex(hat, 261, 6901050.0);
		}
		case 19:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3329330.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3329330.0);
		}
		case 20:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15787660.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15787660.0);
		}
		case 21:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8154199.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8154199.0);
		}
		case 22:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 4345659.0);
			TF2Attrib_SetByDefIndex(hat, 261, 4345659.0);
		}
		case 23:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 6637376.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2636109.0);
		}
		case 24:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3874595.0);
			TF2Attrib_SetByDefIndex(hat, 261, 1581885.0);
		}
		case 25:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12807213.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12091445.0);
		}
		case 26:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 4732984.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3686984.0);
		}
		case 27:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12073019.0);
			TF2Attrib_SetByDefIndex(hat, 261, 5801378.0);
		}
		case 28:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8400928.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2452877.0);
		}
		case 29:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 11049612.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8626083.0);
		}
	}
}
