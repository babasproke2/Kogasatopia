/**
 * [TF2] Custom Weapons X
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <sdkhooks>
#include <sdktools_sound>

#include <tf2utils>
#include <tf_econ_data>
#include <tf2attributes>
#include <tf2_stocks>

#include <morecolors>
#include <tf_custom_attributes>
#include <dhooks>
#include <stocksoup/convars>
#include <stocksoup/handles>
#include <stocksoup/math>
#include <stocksoup/tf/econ>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/weapon>

#undef REQUIRE_EXTENSIONS
#include <tf2_spread_patterns>
#define REQUIRE_EXTENSIONS

#undef REQUIRE_EXTENSIONS
#include <scattergun_pellets>
#define REQUIRE_EXTENSIONS

#undef REQUIRE_PLUGIN
#include <dgm_api>
#include <points_store_api>
#define REQUIRE_PLUGIN
#include <plugin_statistics>

#define CWX_INCLUDE_SHAREDDEFS_ONLY
#include <cwx>

#include "include/database.inc"
#include "include/steam_identity.inc"
#include "include/tf2_classes.inc"

#tryinclude <autoversioning/version>
#if defined __ninjabuild_auto_version_included
	#define VERSION_SUFFIX "-" ... GIT_COMMIT_SHORT_HASH
#else
	#define VERSION_SUFFIX ""
#endif

public Plugin myinfo = {
	name = "[TF2] Custom Weapons X",
	author = "nosoop, Hombre, tsuza, Mir",
	description = "Allows server operators to design their own weapons.",
	version = "X.0.10" ... VERSION_SUFFIX,
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// 29/08/2026: Combined ca_replace_sound and viewmodel_override into cwx to reduce number of plugins + less concern about order conflicts

// this is the maximum expected length of our UID; it is intentional that this is *not* shared
// to dependent plugins, as we may change this at any time
#define MAX_ITEM_IDENTIFIER_LENGTH 64

// this is the maximum length of the item name displayed to players
#define MAX_ITEM_NAME_LENGTH 128

// this is the maximum length of the per-weapon description printed by sm_c
#define MAX_ITEM_DESCRIPTION_LENGTH 512

#define CWX_CONFIG_PATH "configs/weapons.cfg"
#define CWX_CONFIG_ROOT "WeaponReverts"
#define CWX_CONFIG_ITEM_SECTION "CWX"
#define CWX_CONFIG_SOUND_SECTION "SoundGroup"

// this is the number of slots allocated to our thing
#define NUM_ITEMS 7

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

#define CWX_STATS_DB_CONFIG_DEFAULT "default"
#define CWX_STATS_STATE_TABLE "cwx_weapon_popularity"
#define ATTR_CIRCULAR_BULLET_SPREAD "circular bullet spread"
#define ATTR_WIDE_HORIZONTAL_BULLET_SPREAD "wide horizontal bullet spread"
#define ATTR_AMBASSADOR_ACCURACY_RECOVERY "ambassador accuracy recovery"
#define ATTR_PUNCH_ANGLE_IS_CONSISTENT "punch angle is consistent"
#define ATTR_PUNCH_ANGLE_MOD "punch angle mod"
#define ATTR_HUNTING_REVOLVER "hunting revolver attributes"
#define TF_AMMO_PRIMARY_INDEX 1

// we're recycling the following attribute to ensure that the item UID persists across dropped
// weapons - it's kinda icky and if anyone else happened to get the same idea it'd be bad, but
// it's the best we've got without trying TOO hard
// TODO: rework this in the future to optionally use an injected attribute?
#define ATTRIB_NAME_CUSTOM_UID "random drop line item unusual list"
#define POINTS_STORE_HAS_PURCHASE_NATIVE "PointsStore_HasPurchase"

bool g_bRetrievedLoadout[MAXPLAYERS + 1];

Cookie g_ItemPersistCookies[NUM_PLAYER_CLASSES][NUM_ITEMS];

bool g_bForceReequipItems[MAXPLAYERS + 1];

ConVar sm_cwx_enable_loadout;
ConVar sm_cwx_statistics;
ConVar sm_cwx_statistics_database;
ConVar sm_cwx_validate_debug;
ConVar sm_cwx_validate_repair;
ConVar sm_cwx_hide_reskin_only;

ConVar mp_stalemate_meleeonly;

Database g_CwxStatsDb = null;
bool g_CwxStatsDbReady = false;
bool g_CwxStatsIsMySql = false;
Handle g_hCwxStatsDbReconnectTimer = null;
Handle g_hOnItemRuntimeStateReady = null;

void CWX_ApplyEngineOverrides(int weapon)
{
	if (!IsValidEntity(weapon))
	{
		return;
	}

	if (TF2CustAttr_GetInt(weapon, ATTR_HUNTING_REVOLVER, 0) != 0)
	{
		SetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", TF_AMMO_PRIMARY_INDEX);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Spread_SetPattern") == FeatureStatus_Available)
	{
		TF2SpreadPattern pattern = TF2Spread_Default;
		if (TF2CustAttr_GetInt(weapon, ATTR_WIDE_HORIZONTAL_BULLET_SPREAD, 0) != 0)
		{
			pattern = TF2Spread_WideHorizontal20;
		}
		else if (TF2CustAttr_GetInt(weapon, ATTR_CIRCULAR_BULLET_SPREAD, 0) != 0)
		{
			pattern = TF2Spread_Circular15;
		}
		TF2Spread_SetPattern(weapon, pattern);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Scatter_SetWeaponPelletCount") == FeatureStatus_Available)
	{
		float pelletCount = TF2Attrib_HookValueFloat(10.0, "mult_bullets_per_shot", weapon);
		int pelletsFired = RoundToNearest(pelletCount);
		if (pelletsFired < 1)
		{
			pelletsFired = 1;
		}
		TF2Scatter_SetWeaponPelletCount(weapon, pelletsFired);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Spread_SetAmbassadorAccuracy") == FeatureStatus_Available)
	{
		bool enabled = TF2CustAttr_GetInt(weapon, ATTR_AMBASSADOR_ACCURACY_RECOVERY, 0) != 0;
		TF2Spread_SetAmbassadorAccuracy(weapon, enabled);
	}

	if (GetFeatureStatus(FeatureType_Native, "TF2Weapon_SetPunchAngle") == FeatureStatus_Available)
	{
		char amountValue[16];
		TF2CustAttr_GetString(weapon, ATTR_PUNCH_ANGLE_MOD, amountValue, sizeof(amountValue));
		bool enabled = amountValue[0] != '\0';
		int amount = enabled ? StringToInt(amountValue) : 0;
		bool consistent = TF2CustAttr_GetInt(weapon, ATTR_PUNCH_ANGLE_IS_CONSISTENT, 0) != 0;
		TF2Weapon_SetPunchAngle(weapon, enabled, amount, consistent);
	}

}

#include "cwx/item_config.sp"
#include "cwx/item_entity.sp"
#include "cwx/item_export.sp"
#include "cwx/loadout_entries.sp"
#include "cwx/loadout_radio_menu.sp"
#include "cwx/sound_overrides.sp"
#include "cwx/model_overrides.sp"

int g_attrdef_AllowedInMedievalMode;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int maxlen) {
	MarkNativeAsOptional("DGM_CurrentNormalizedMap");
	MarkNativeAsOptional("DGM_NormalizeMapName");
	MarkNativeAsOptional("DGM_GetGameModeKey");

	RegPluginLibrary("cwx");
	
	CreateNative("CWX_SetPlayerLoadoutItem", Native_SetPlayerLoadoutItem);
	CreateNative("CWX_RemovePlayerLoadoutItem", Native_RemovePlayerLoadoutItem);
	CreateNative("CWX_GetPlayerLoadoutItem", Native_GetPlayerLoadoutItem);
	CreateNative("CWX_EquipPlayerItem", Native_EquipPlayerItem);
	CreateNative("CWX_CanPlayerAccessItem", Native_CanPlayerAccessItem);
	CreateNative("CWX_GetItemList", Native_GetItemList);
	CreateNative("CWX_IsItemUIDValid", Native_IsItemUIDValid);
	CreateNative("CWX_GetItemUIDFromEntity", Native_GetItemUIDFromEntity);
	CreateNative("CWX_GetItemDisplayName", Native_GetItemDisplayName);
	CreateNative("CWX_GetItemExtData", Native_GetItemExtData);
	CreateNative("CWX_GetItemLoadoutSlot", Native_GetItemLoadoutSlot);
	
	return APLRes_Success;
}

public void OnPluginStart() {
	LoadTranslations("cwx.phrases");
	LoadTranslations("common.phrases");
	LoadTranslations("core.phrases");
	
	Handle hGameConf = LoadGameConfigFile("tf2.custom_weapons_x");
	if (!hGameConf) {
		SetFailState("Failed to load gamedata (tf2.custom_weapons_x).");
	}
	
	Handle dtGetLoadoutItem = DHookCreateFromConf(hGameConf, "CTFPlayer::GetLoadoutItem()");
	DHookEnableDetour(dtGetLoadoutItem, true, OnGetLoadoutItemPost);
	
	Handle dtManageRegularWeapons = DHookCreateFromConf(hGameConf, "CTFPlayer::ManageRegularWeapons()");
	if (!dtManageRegularWeapons) {
		SetFailState("Failed to create detour %s", "CTFPlayer::ManageRegularWeapons()");
	}
	DHookEnableDetour(dtManageRegularWeapons, false, OnManageRegularWeaponsPre);
	DHookEnableDetour(dtManageRegularWeapons, true, OnManageRegularWeaponsPost);
	
	delete hGameConf;
	
	HookUserMessage(GetUserMessageId("PlayerLoadoutUpdated"), OnPlayerLoadoutUpdated,
			.post = OnPlayerLoadoutUpdatedPost);
	
	CreateVersionConVar("cwx_version", "Custom Weapons X version.");
	
	sm_cwx_enable_loadout = CreateConVar("sm_cwx_enable_loadout", "1",
			"Allows players to receive custom items they have selected.");
	sm_cwx_statistics = CreateConVar("sm_cwx_statistics", "1",
			"Record Custom Weapons X equip/unequip popularity statistics.", _, true, 0.0, true, 1.0);
	sm_cwx_statistics_database = CreateConVar("sm_cwx_statistics_database",
			CWX_STATS_DB_CONFIG_DEFAULT,
			"Database config used for Custom Weapons X popularity statistics.");
	sm_cwx_validate_debug = CreateConVar("sm_cwx_validate_debug", "0",
			"Log CWX m_bValidatedAttachedEntity state after custom item creation and equip.",
			_, true, 0.0, true, 1.0);
	sm_cwx_validate_repair = CreateConVar("sm_cwx_validate_repair", "1",
			"Re-assert m_bValidatedAttachedEntity if TF2 clears it after attachment.",
			_, true, 0.0, true, 1.0);
	sm_cwx_hide_reskin_only = CreateConVar("sm_cwx_hide_reskin_only", "1",
			"Hide reskin-only weapons from sm_c descriptions.", _, true, 0.0, true, 1.0);
	sm_cwx_statistics.AddChangeHook(OnCwxStatisticsEnabledChanged);
	sm_cwx_statistics_database.AddChangeHook(OnCwxStatisticsDatabaseChanged);
	ConnectCwxStatisticsDatabase();
	g_hOnItemRuntimeStateReady = CreateGlobalForward("CWX_OnItemRuntimeStateReady",
		ET_Ignore, Param_Cell, Param_Cell);
	
	RegAdminCmd("sm_cwx_export", ExportActiveWeapon, ADMFLAG_ROOT);
	
	// player commands
	RegAdminCmd("sm_cwx", DisplayItems, 0);
	RegAdminCmd("sm_cw", DisplayItems, 0);
	RegAdminCmd("sm_items", DisplayItems, 0);
	RegAdminCmd("sm_weapons", DisplayItems, 0);
	RegAdminCmd("sm_weapon", DisplayItems, 0);
	RegAdminCmd("sm_custom", DisplayItems, 0);
	RegAdminCmd("sm_customweapons", DisplayItems, 0);
	RegAdminCmd("sm_cwc", DisplayItems, 0);
	RegAdminCmd("sm_weps", DisplayItems, 0);
	RegAdminCmd("sm_equip", DisplayItems, 0);
	RegAdminCmd("sm_c", DisplayItemDescriptions, 0);
	RegAdminCmd("sm_cp", DisplayItemDescriptions, 0);
	RegAdminCmd("sm_c2", DisplayItemDescriptions, 0);
	AddCommandListener(DisplayItemsCompat, "sm_cus");
	
	mp_stalemate_meleeonly = FindConVar("mp_stalemate_meleeonly");
	
	// TODO: I'd like to use a separate, independent database for this
	// but leveraging the cookie system is easier for now
	char cookieName[64], cookieDesc[128];
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			FormatEx(cookieName, sizeof(cookieName), "cwx_loadout_%d_%d", c, i);
			FormatEx(cookieDesc, sizeof(cookieDesc),
					"CWX loadout entry for class %d in slot %d", c, i);
			g_ItemPersistCookies[c][i] = new Cookie(cookieName, cookieDesc,
					CookieAccess_Private);
		}
	}
	
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientConnected(i)) {
			continue;
		}
		OnClientConnected(i);
		
		if (IsClientAuthorized(i)) {
			FetchLoadoutItems(i);
		}
	}

	CwxSound_OnPluginStart();
	CwxModels_OnPluginStart();
}

public void OnPluginEnd() {
	CwxModels_OnPluginEnd();
	CwxSound_OnPluginEnd();
	Db_CancelTimer(g_hCwxStatsDbReconnectTimer);
	Db_Close(g_CwxStatsDb, g_CwxStatsDbReady);
	delete g_hOnItemRuntimeStateReady;
}

void CWX_NotifyItemRuntimeStateReady(int client, int entity) {
	if (!IsClientInGame(client) || !IsValidEntity(entity)) {
		return;
	}

	CwxModels_OnItemRuntimeStateReady(client, entity);
	CwxSound_OnItemRuntimeStateReady(client, entity);

	if (g_hOnItemRuntimeStateReady == null) {
		return;
	}

	Call_StartForward(g_hOnItemRuntimeStateReady);
	Call_PushCell(client);
	Call_PushCell(entity);
	Call_Finish();
}

public void OnAllPluginsLoaded() {
	BuildLoadoutSlotMenu();
	
	g_attrdef_AllowedInMedievalMode =
			TF2Econ_TranslateAttributeNameToDefinitionIndex("allowed in medieval mode");
}

public void OnLibraryAdded(const char[] name) {
	if (!StrEqual(name, "tf2custattr") || !CustomItemsLoaded()) {
		return;
	}

	/*
	 * Reloading the custom-attribute provider removes its entity storage.
	 * Rehydrate active persisted items as soon as the provider returns.
	 */
	for (int client = 1; client <= MaxClients; client++) {
		if (IsClientInGame(client) && IsPlayerAlive(client)
				&& g_bRetrievedLoadout[client]) {
			RequestFrame(Frame_ApplyRetrievedLoadout, GetClientUserId(client));
		}
	}
}

Action DisplayItemDescriptions(int client, int argc) {
	if (!client || !IsClientInGame(client)) {
		return Plugin_Handled;
	}

	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	if (!playerClass) {
		return Plugin_Handled;
	}

	StringMap printedDescriptions = new StringMap();
	StringMapSnapshot itemList = GetCustomItemList();

	for (int i; i < itemList.Length; i++) {
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		itemList.GetKey(i, uid, sizeof(uid));

		CustomItemDefinition item;
		if (!GetCustomItemDefinition(uid, item)) {
			continue;
		}

		if (item.loadoutPosition[playerClass] == -1) {
			continue;
		}

		if (sm_cwx_hide_reskin_only.BoolValue && item.reskinOnly) {
			continue;
		}

		char description[MAX_ITEM_DESCRIPTION_LENGTH * 3];
		bool hasDescription = FormatItemDescription(item, description, sizeof(description));

		char dedupeKey[MAX_ITEM_DESCRIPTION_LENGTH * 3];
		strcopy(dedupeKey, sizeof(dedupeKey), description);
		if (!hasDescription) {
			strcopy(dedupeKey, sizeof(dedupeKey), uid);
		}

		if (printedDescriptions.ContainsKey(dedupeKey)) {
			continue;
		}
		printedDescriptions.SetValue(dedupeKey, 1);

		if (hasDescription) {
			CPrintToChat(client, "%s", description);
		} else {
			CPrintToChat(client, "{gold}[CWX]{default} This weapon has no set description.");
		}
	}

	delete itemList;
	delete printedDescriptions;
	return Plugin_Handled;
}

bool FormatItemDescription(const CustomItemDefinition item, char[] buffer, int maxlen) {
	buffer[0] = '\0';

	bool hasPositive = item.descriptionPositive[0] != '\0';
	bool hasNeutral = item.descriptionNeutral[0] != '\0';
	bool hasNegative = item.descriptionNegative[0] != '\0';
	if (!hasPositive && !hasNeutral && !hasNegative) {
		return false;
	}

	Format(buffer, maxlen, "{gold}%s{default}:", item.displayName);
	bool needsComma = false;

	if (hasPositive) {
		AppendItemDescriptionPart(buffer, maxlen, "{green}", item.descriptionPositive, needsComma);
	}
	if (hasNeutral) {
		AppendItemDescriptionPart(buffer, maxlen, "{default}", item.descriptionNeutral, needsComma);
	}
	if (hasNegative) {
		AppendItemDescriptionPart(buffer, maxlen, "{red}", item.descriptionNegative, needsComma);
	}
	return true;
}

void AppendItemDescriptionPart(char[] buffer, int maxlen, const char[] color, const char[] text, bool &needsComma) {
	if (needsComma) {
		StrCat(buffer, maxlen, ",");
	}
	StrCat(buffer, maxlen, " ");
	StrCat(buffer, maxlen, color);
	StrCat(buffer, maxlen, text);
	needsComma = true;
}

public void OnMapStart() {
	CwxModels_OnMapStart();
	LoadCustomItemConfig();
	PrecacheMenuResources();
}

public void OnMapEnd() {
	CwxSound_Clear();
}

public void OnClientPutInServer(int client) {
	CwxSound_ResetClient(client);
	CwxModels_OnClientPutInServer(client);
}

public void OnClientDisconnect(int client) {
	CwxSound_ResetClient(client);
	CwxModels_OnClientDisconnect(client);
}

void CWX_OnWeaponSwitchPost(int client, int weapon) {
	CwxSound_OnWeaponSwitchPost(client, weapon);
	CwxModels_OnWeaponSwitchPost(client, weapon);
}

public void OnEntityCreated(int entity, const char[] className) {
	CwxModels_OnEntityCreated(entity, className);
}

public void TF2_OnConditionRemoved(int client, TFCond condition) {
	CwxModels_OnConditionRemoved(client, condition);
}

/**
 * Clear out per-client inventory from previous player.
 */
public void OnClientConnected(int client) {
	g_bRetrievedLoadout[client] = false;
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_CurrentLoadout[client][c][i].Clear(.initialize = true);
		}
	}
}

public void OnClientAuthorized(int client, const char[] auth) {
	FetchLoadoutItems(client);
}

/**
 * Called when we know our client is valid.  Retrieve our loadout from our storage backend.
 * 
 * `g_bRetrievedLoadout[client]` should be set once our loadout is retrieved, which may happen
 * asynchronously.
 */
void FetchLoadoutItems(int client) {
	if (AreClientCookiesCached(client)) {
		OnClientCookiesCached(client);
	}
}

public void OnClientCookiesCached(int client) {
	bool wasRetrieved = g_bRetrievedLoadout[client];

	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_ItemPersistCookies[c][i].Get(client, g_CurrentLoadout[client][c][i].uid,
					sizeof(g_CurrentLoadout[][][].uid));
		}
	}
	g_bRetrievedLoadout[client] = true;
	CwxStats_MirrorClientSavedLoadout(client);

	/*
	 * Clientprefs can finish after the first PlayerLoadoutUpdated message.  In that
	 * case the initial equip pass saw an empty loadout and no later pass occurs until
	 * a class change / regeneration.  Apply the newly retrieved loadout next frame.
	 */
	if (!wasRetrieved && IsClientInGame(client)) {
		RequestFrame(Frame_ApplyRetrievedLoadout, GetClientUserId(client));
	}
}

void Frame_ApplyRetrievedLoadout(any userid) {
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client)
			|| !g_bRetrievedLoadout[client]) {
		return;
	}

	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	if (playerClass <= 0 || playerClass >= NUM_PLAYER_CLASSES) {
		return;
	}

	ApplyClientCustomLoadout(client);
}

// int CWX_EquipPlayerItem(int client, const char[] uid);
int Native_EquipPlayerItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(2, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return INVALID_ENT_REFERENCE;
	}
	
	int itemEntity = EquipCustomItem(client, item);
	return IsValidEntity(itemEntity)? EntIndexToEntRef(itemEntity) : INVALID_ENT_REFERENCE;
}

// bool CWX_CanPlayerAccessItem(int client, const char[] uid);
int Native_CanPlayerAccessItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(2, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return false;
	}
	return CanPlayerAccessItem(client, item);
}

// ArrayList CWX_GetItemList(CWXItemFilterCriteria func = INVALID_FUNCTION, any data = 0);
int Native_GetItemList(Handle plugin, int argc) {
	Function func = GetNativeFunction(1);
	any data = GetNativeCell(2);
	
	StringMapSnapshot itemSnapshot = GetCustomItemList();
	
	ArrayList itemList = new ArrayList(ByteCountToCells(MAX_ITEM_IDENTIFIER_LENGTH));
	for (int i, n = itemSnapshot.Length; i < n; i++) {
		char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
		itemSnapshot.GetKey(i, itemuid, sizeof(itemuid));
		
		if (func == INVALID_FUNCTION) {
			itemList.PushString(itemuid);
			continue;
		}
		
		bool result;
		Call_StartFunction(plugin, func);
		Call_PushString(itemuid);
		Call_PushCell(data);
		Call_Finish(result);
		
		if (result) {
			itemList.PushString(itemuid);
		}
	}
	delete itemSnapshot;
	
	return MoveHandle(itemList, plugin);
}

// bool CWX_IsItemUIDValid(const char[] uid);
int Native_IsItemUIDValid(Handle plugin, int argc) {
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(1, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	return GetCustomItemDefinition(itemuid, item);
}

// bool CWX_GetItemUIDFromEntity(int entity, char[] buffer, int maxlen);
int Native_GetItemUIDFromEntity(Handle plugin, int argc) {
	int entity = GetNativeCell(1);
	
	if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is invalid or not an item", entity);
		return false;
	}
	
	// only pull the value from the runtime attribute list
	Address result = TF2Attrib_GetByName(entity, ATTRIB_NAME_CUSTOM_UID);
	if (!result) {
		return false;
	}
	
	any rawValue = TF2Attrib_GetValue(result);
	
	int maxlen = GetNativeCell(3);
	char[] buffer = new char[maxlen];
	
	TF2Attrib_UnsafeGetStringValue(rawValue, buffer, maxlen);
	
	if (strcmp(buffer, "") == 0) {
		return false;
	}
	
	SetNativeString(2, buffer, maxlen);
	return true;
}

// int CWX_GetItemLoadoutSlot(const char[] uid, TFClassType playerClass);
int Native_GetItemLoadoutSlot(Handle plugin, int argc) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(1, uid, sizeof(uid));
	int playerClass = GetNativeCell(2);
	
	CustomItemDefinition customItem;
	if (!GetCustomItemDefinition(uid, customItem)) {
		return -1;
	}
	return customItem.loadoutPosition[playerClass];
}

// bool CWX_GetItemDisplayName(const char[] uid, char[] buffer, int maxlen);
int Native_GetItemDisplayName(Handle plugin, int argc) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(1, uid, sizeof(uid));

	CustomItemDefinition customItem;
	if (!GetCustomItemDefinition(uid, customItem) || !customItem.displayName[0]) {
		return false;
	}

	SetNativeString(2, customItem.displayName, GetNativeCell(3), true);
	return true;
}

// optional<KeyValues> CWX_GetItemExtData(const char[] uid, const char[] section);
int Native_GetItemExtData(Handle plugin, int argc) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	char sectionName[64];
	
	GetNativeString(1, uid, sizeof(uid));
	GetNativeString(2, sectionName, sizeof(sectionName));
	
	CustomItemDefinition customItem;
	if (!GetCustomItemDefinition(uid, customItem)) {
		return 0;
	}
	
	KeyValues result = customItem.GetExtData(sectionName);
	return result? MoveHandle(result, plugin) : 0;
}

int s_LastUpdatedClient;

/**
 * Called once the game has updated the player's loadout with all the weapons it wanted, but
 * before the post_inventory_application event is fired.
 * 
 * As other plugins may send usermessages in response to our equip events, we have to wait until
 * after the usermessage is sent before we can run our own logic.  We don't have access to the
 * usermessage itself in post, so this function simply grabs the info it needs.
 */
Action OnPlayerLoadoutUpdated(UserMsg msg_id, BfRead msg, const int[] players,
		int playersNum, bool reliable, bool init) {
	int client = msg.ReadByte();
	s_LastUpdatedClient = GetClientSerial(client);
	return Plugin_Continue;
}

/**
 * Called once the game has updated the player's loadout with all the weapons it wanted, but
 * before the post_inventory_application event is fired.
 * 
 * This is the point where we check our custom loadout settings, then create our items if
 * necessary (because persistence is implemented, the player may already have our custom items,
 * and we keep track of them so we don't unnecessarily reequip them).
 */
void OnPlayerLoadoutUpdatedPost(UserMsg msg_id, bool sent) {
	int client = GetClientFromSerial(s_LastUpdatedClient);
	ApplyClientCustomLoadout(client);
}

/**
 * Equips the configured custom loadout for the client's current class.
 * Called both after the normal TF2 loadout update and after an asynchronous
 * clientprefs load completes too late for that update.
 */
void ApplyClientCustomLoadout(int client) {
	if (!sm_cwx_enable_loadout.BoolValue || client <= 0 || client > MaxClients
			|| !IsClientInGame(client)) {
		return;
	}

	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	if (playerClass <= 0 || playerClass >= NUM_PLAYER_CLASSES) {
		return;
	}

	for (int i; i < NUM_ITEMS; i++) {
		if (g_CurrentLoadout[client][playerClass][i].IsEmpty()) {
			// no item specified, use default
			continue;
		}
		
		CustomItemDefinition item;
		if (!g_CurrentLoadout[client][playerClass][i].GetItemDefinition(item)) {
			continue;
		}

		// equip our item if it isn't already equipped, or if it's being killed
		// the latter applies to items that are normally invalid for the class
		int currentLoadoutItem = EntRefToEntIndex(g_CurrentLoadout[client][playerClass][i].entity);
		if (g_bForceReequipItems[client]
				|| currentLoadoutItem == INVALID_ENT_REFERENCE
				|| !IsValidEntity(currentLoadoutItem)
				|| GetEntityFlags(currentLoadoutItem) & FL_KILLME) {
			if (!CanPlayerEquipItem(client, item)) {
				continue;
			}
			
			if (!IsCustomItemAllowed(client, item)) {
				continue;
			}
			
			int entity = EquipCustomItem(client, item);
			CWX_MarkValidatedAttachedEntity(entity, client, "loadout_apply");
			
			g_CurrentLoadout[client][playerClass][i].entity = EntIndexToEntRef(entity);
		} else {
			/*
			 * TF2 can retain the entity through regeneration while clearing part of
			 * its runtime attribute list. Entref validity alone is not a sufficient
			 * loadout health check.
			 */
			EnsureCustomItemRuntimeAttributes(currentLoadoutItem, item, client,
				"persisted_loadout");
			CWX_MarkValidatedAttachedEntity(currentLoadoutItem, client,
				"persisted_loadout");
			CWX_NotifyItemRuntimeStateReady(client, currentLoadoutItem);
		}
	}
	
	// TODO: switch to the correct slot if we're not holding anything
	// as is the case again, this happens on non-valid-for-class items
}

/**
 * Called when the game wants to know what item the player has in a specific class / slot.  This
 * only happens when the game is regenerating the player (resupply, spawn).  This hook
 * intercepts the result and returns one of the following:
 * 
 * - the player's inventory item view, if we are not overriding it ourselves (no change)
 * - the spawned entity's item view, if our override item exists; this will prevent our custom
 *   item from being invalidated when we touch resupply
 * - an uninitialized item view, if our override item does not exist; the game will skip adding
 *   a weapon in that slot, and we can then spawn our own item later
 * 
 * The game expects there to be a valid CEconItemView pointer in certain areas of the code, so
 * avoid returning a nullptr.
 */
MRESReturn OnGetLoadoutItemPost(int client, Handle hReturn, Handle hParams) {
	if (!sm_cwx_enable_loadout.BoolValue) {
		return MRES_Ignored;
	}
	
	int playerClass = DHookGetParam(hParams, 1);
	int loadoutSlot = DHookGetParam(hParams, 2);
	
	if (loadoutSlot < 0 || loadoutSlot >= NUM_ITEMS) {
		return MRES_Ignored;
	}
	
	int storedItemRef = g_CurrentLoadout[client][playerClass][loadoutSlot].entity;
	int storedItem = EntRefToEntIndex(storedItemRef);
	
	if (!g_CurrentLoadout[client][playerClass][loadoutSlot].IsEmpty()) {
		CustomItemDefinition item;
		if (!g_CurrentLoadout[client][playerClass][loadoutSlot].GetItemDefinition(item)
				|| !CanPlayerEquipItemForClass(client, playerClass, item)) {
			if (storedItem != INVALID_ENT_REFERENCE && IsValidEntity(storedItem)) {
				RemoveEntity(storedItem);
				g_CurrentLoadout[client][playerClass][loadoutSlot].entity = INVALID_ENT_REFERENCE;
			}
			return MRES_Ignored;
		}
	}
	
	if (storedItem == INVALID_ENT_REFERENCE || !IsValidEntity(storedItem) || GetEntityFlags(storedItem) & FL_KILLME
			|| !HasEntProp(storedItem, Prop_Send, "m_Item")) {
		// the loadout entity we keep track of isn't valid, so we may need to make one
		// we expect to have to equip something new at this point
		
		if (g_CurrentLoadout[client][playerClass][loadoutSlot].IsEmpty()) {
			// we don't have nor want a custom item; let the game process it
			return MRES_Ignored;
		}
		
		/**
		 * We have a custom item we'd like to spawn in; don't return a loadout item, otherwise
		 * we may equip / unequip a user's inventory weapon that has side effects
		 * (e.g. Gunslinger).
		 * 
		 * We'll initialize our custom item later in `OnPlayerLoadoutUpdated`.
		 */
		static int s_DefaultItem = INVALID_ENT_REFERENCE;
		storedItem = EntRefToEntIndex(s_DefaultItem);
		if (storedItem == INVALID_ENT_REFERENCE || !IsValidEntity(storedItem)) {
			storedItem = TF2_SpawnWearable();
			s_DefaultItem = EntIndexToEntRef(storedItem);
			RemoveEntity(storedItem); // (this is OK, RemoveEntity doesn't act immediately)
		}
	}
	
	Address pStoredItemView = GetEntityAddress(storedItem)
			+ view_as<Address>(GetEntSendPropOffs(storedItem, "m_Item", true));
	
	DHookSetReturn(hReturn, pStoredItemView);
	return MRES_Supercede;
}

/**
 * Intercept ManageRegularWeapons to trick the game into thinking the weapons we have are valid
 * for that class, so they don't get removed.
 */
MRESReturn OnManageRegularWeaponsPre(int client, Handle hParams) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	for (int s; s < NUM_ITEMS; s++) {
		int storedItem = EntRefToEntIndex(g_CurrentLoadout[client][playerClass][s].entity);
		if (storedItem == INVALID_ENT_REFERENCE || !IsValidEntity(storedItem)) {
			continue;
		}
		
		int validitemdef = FindBaseItem(playerClass, s);
		if (validitemdef == TF_ITEMDEF_DEFAULT) {
			continue;
		}
		
		int currentitemdef = GetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex");
		if (TF2Econ_GetItemLoadoutSlot(currentitemdef, playerClass) != -1) {
			// only replace the itemdef if the existing one is not valid for the class
			// this is because something something static attribute retention
			
			// we should probably just drop support for invalid weapons at this point;
			// it's starting to be a headache to manage
			continue;
		}
		
		// replace the itemdef and classname with ones actually valid for that class to skirt
		// around the ValidateWeapons checks
		char classname[64];
		TF2Econ_GetItemClassName(validitemdef, classname, sizeof(classname));
		
		// we need to translate the item class because base shotguns use 'tf_weapon_shotgun'
		TF2Econ_TranslateWeaponEntForClass(classname, sizeof(classname), playerClass);
		
		SetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex", validitemdef);
		SetEntPropString(storedItem, Prop_Data, "m_iClassname", classname);
	}
	return MRES_Ignored;
}

/**
 * For every custom item in our loadout, reapply the correct defindex / classname.
 */
MRESReturn OnManageRegularWeaponsPost(int client, Handle hParams) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	for (int s; s < NUM_ITEMS; s++) {
		int storedItem = EntRefToEntIndex(g_CurrentLoadout[client][playerClass][s].entity);
		if (storedItem == INVALID_ENT_REFERENCE || !IsValidEntity(storedItem)) {
			continue;
		}
		
		CustomItemDefinition item;
		if (!g_CurrentLoadout[client][playerClass][s].GetItemDefinition(item)) {
			continue;
		}
		
		// have to resolve the classname since, y'know, multiclass.
		char realClassName[64];
		strcopy(realClassName, sizeof(realClassName), item.className);
		TF2Econ_TranslateWeaponEntForClass(realClassName, sizeof(realClassName), playerClass);
		
		SetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex", item.defindex);
		SetEntPropString(storedItem, Prop_Data, "m_iClassname", realClassName);
		CWX_MarkValidatedAttachedEntity(storedItem, client, "manage_regular_weapons");
	}
	return MRES_Ignored;
}

/**
 * Handles a special case where the player is refunding all of their upgrades, which may stomp
 * on any existing runtime attributes applied to our weapon.
 */
public Action OnClientCommandKeyValues(int client, KeyValues kv) {
	char cmd[64];
	kv.GetSectionName(cmd, sizeof(cmd));
	
	/**
	 * Mark the player to always invalidate our items so they get reequipped during respawn --
	 * this is fine since TF2 manages to reapply upgrades to plugin-granted items.
	 * 
	 * The player gets their loadout changed multiple times during respec so we can't just
	 * invalidate the reference in LoadoutEntry.entity (since it'll be valid after the first
	 * change).
	 * 
	 * Hopefully nobody's blocking "MVM_Respec", because that would leave this flag set.
	 * Otherwise we should be able to hook CUpgrades::GrantOrRemoveAllUpgrades() directly,
	 * though that incurs a gamedata burden.
	 */
	if (StrEqual(cmd, "MVM_Respec")) {
		g_bForceReequipItems[client] = true;
	}
}

public void OnClientCommandKeyValues_Post(int client, KeyValues kv) {
	char cmd[64];
	kv.GetSectionName(cmd, sizeof(cmd));
	
	if (StrEqual(cmd, "MVM_Respec")) {
		g_bForceReequipItems[client] = false;
	}
}

/**
 * Returns the base item associated with the given playerClass and loadoutSlot combination, or
 * TF_ITEMDEF_DEFAULT if no match is found.
 */
int FindBaseItem(TFClassType playerClass, int loadoutSlot) {
	static ArrayList s_BaseItems;
	if (!s_BaseItems) {
		s_BaseItems = TF2Econ_GetItemList(FilterBaseItems);
	}
	
	for (int i, n = s_BaseItems.Length; i < n; i++) {
		int itemdef = s_BaseItems.Get(i);
		if (TF2Econ_GetItemLoadoutSlot(itemdef, playerClass) == loadoutSlot) {
			return itemdef;
		}
	}
	return TF_ITEMDEF_DEFAULT;
}

bool FilterBaseItems(int itemdef, any __) {
	return TF2Econ_IsItemInBaseSet(itemdef);
}

// bool CWX_SetPlayerLoadoutItem(int client, TFClassType playerClass, const char[] uid, int flags = 0);
int Native_SetPlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(3, uid, sizeof(uid));
	
	int flags = GetNativeCell(4);
	
	return SetClientCustomLoadoutItem(client, playerClass, uid, flags);
}

/**
 * Saves the current item into the loadout for the specified class.
 */
bool SetClientCustomLoadoutItem(int client, int playerClass, const char[] itemuid, int flags) {
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return false;
	}
	
	if ((flags & LOADOUT_FLAG_UPDATE_BACKEND)
			&& !CanPlayerEquipItemForClass(client, playerClass, item)) {
		return false;
	}
	
	int itemSlot = item.loadoutPosition[playerClass];
	if (0 <= itemSlot < NUM_ITEMS) {
		if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
			char previousUid[MAX_ITEM_IDENTIFIER_LENGTH];
			strcopy(previousUid, sizeof(previousUid),
					g_CurrentLoadout[client][playerClass][itemSlot].uid);
			bool changed = !StrEqual(previousUid, itemuid, false);

			// item being set as user preference; update backend and set permanent UID slot
			g_ItemPersistCookies[playerClass][itemSlot].Set(client, itemuid);
			g_CurrentLoadout[client][playerClass][itemSlot].SetItemUID(itemuid);

			if (changed) {
				if (previousUid[0]) {
					CwxStats_RecordUnequip(client, playerClass, itemSlot, previousUid);
				}
				CwxStats_RecordEquip(client, playerClass, itemSlot, itemuid, item);
			}
		} else {
			// item being set temporarily; set as overload
			g_CurrentLoadout[client][playerClass][itemSlot].SetOverloadItemUID(itemuid);
		}
		
		g_CurrentLoadout[client][playerClass][itemSlot].entity = INVALID_ENT_REFERENCE;
	} else {
		return false;
	}
	
	if (flags & LOADOUT_FLAG_ATTEMPT_REGEN) {
		OnClientCustomLoadoutItemModified(client, playerClass);
	}
	return true;
}

// void CWX_RemovePlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot, int flags = 0);
int Native_RemovePlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	int itemSlot = GetNativeCell(3);
	int flags = GetNativeCell(4);
	
	UnsetClientCustomLoadoutItem(client, playerClass, itemSlot, flags);
	return 0;
}

/**
 * Unsets any existing item in the given loadout slot for the specified class.
 */
void UnsetClientCustomLoadoutItem(int client, int playerClass, int itemSlot, int flags) {
	if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
		char previousUid[MAX_ITEM_IDENTIFIER_LENGTH];
		strcopy(previousUid, sizeof(previousUid),
				g_CurrentLoadout[client][playerClass][itemSlot].uid);

		g_CurrentLoadout[client][playerClass][itemSlot].Clear();
		g_ItemPersistCookies[playerClass][itemSlot].Set(client, "");

		if (previousUid[0]) {
			CwxStats_RecordUnequip(client, playerClass, itemSlot, previousUid);
		}
	} else {
		g_CurrentLoadout[client][playerClass][itemSlot].SetOverloadItemUID("");
	}
	
	if (flags & LOADOUT_FLAG_ATTEMPT_REGEN) {
		OnClientCustomLoadoutItemModified(client, playerClass);
	}
}

void OnCwxStatisticsEnabledChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StringToInt(newValue)) {
		ConnectCwxStatisticsDatabase();
	} else {
		Db_CancelTimer(g_hCwxStatsDbReconnectTimer);
		Db_Close(g_CwxStatsDb, g_CwxStatsDbReady);
	}
}

void OnCwxStatisticsDatabaseChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	ConnectCwxStatisticsDatabase();
}

bool CwxStats_IsEnabled() {
	return sm_cwx_statistics == null || sm_cwx_statistics.BoolValue;
}

bool CwxStats_CanWriteState() {
	return CwxStats_IsEnabled() && Db_IsReady(g_CwxStatsDb, g_CwxStatsDbReady);
}

void ConnectCwxStatisticsDatabase() {
	Db_CancelTimer(g_hCwxStatsDbReconnectTimer);
	Db_Close(g_CwxStatsDb, g_CwxStatsDbReady);

	if (!CwxStats_IsEnabled()) {
		return;
	}

	char dbConfig[64];
	sm_cwx_statistics_database.GetString(dbConfig, sizeof(dbConfig));
	TrimString(dbConfig);
	if (!dbConfig[0]) {
		strcopy(dbConfig, sizeof(dbConfig), CWX_STATS_DB_CONFIG_DEFAULT);
	}

	if (!Db_CheckConfigOrLog("cwx", dbConfig)) {
		return;
	}

	SQL_TConnect(CwxStats_OnDatabaseConnected, dbConfig);
}

public void CwxStats_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data) {
	if (hndl == null) {
		LogError("[CWX] Statistics database connection failed: %s",
				error[0] ? error : "unknown error");
		ScheduleCwxStatsDatabaseReconnect();
		return;
	}

	Db_Close(g_CwxStatsDb, g_CwxStatsDbReady);
	g_CwxStatsDb = view_as<Database>(hndl);

	char driverIdent[32];
	DBDriver driver = g_CwxStatsDb.Driver;
	driver.GetIdentifier(driverIdent, sizeof(driverIdent));
	g_CwxStatsIsMySql = StrEqual(driverIdent, "mysql", false);
	if (g_CwxStatsIsMySql && !g_CwxStatsDb.SetCharset("utf8mb4")) {
		LogError("[CWX] Failed to set statistics database charset to utf8mb4.");
	}

	EnsureCwxStatsSchema();
}

void ScheduleCwxStatsDatabaseReconnect(float delay = DB_RECONNECT_DELAY) {
	g_CwxStatsDbReady = false;
	if (g_hCwxStatsDbReconnectTimer == null) {
		g_hCwxStatsDbReconnectTimer = CreateTimer(delay, Timer_ReconnectCwxStatsDatabase,
				_, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_ReconnectCwxStatsDatabase(Handle timer, any data) {
	g_hCwxStatsDbReconnectTimer = null;
	ConnectCwxStatisticsDatabase();
	return Plugin_Stop;
}

void EnsureCwxStatsSchema() {
	if (g_CwxStatsDb == null) {
		return;
	}

	char query[2048];
	if (g_CwxStatsIsMySql) {
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS %s ("
			... "steamid64 VARCHAR(32) NOT NULL, "
			... "player_name VARCHAR(128) NOT NULL DEFAULT '', "
			... "class_index TINYINT NOT NULL, "
			... "class_name VARCHAR(16) NOT NULL DEFAULT '', "
			... "loadout_slot TINYINT NOT NULL, "
			... "weapon_uid VARCHAR(64) NOT NULL, "
			... "weapon_name VARCHAR(128) NOT NULL DEFAULT '', "
			... "equipped TINYINT(1) NOT NULL DEFAULT 0, "
			... "first_equipped_at INT NOT NULL DEFAULT 0, "
			... "last_equipped_at INT NOT NULL DEFAULT 0, "
			... "last_unequipped_at INT NOT NULL DEFAULT 0, "
			... "equip_count INT NOT NULL DEFAULT 0, "
			... "unequip_count INT NOT NULL DEFAULT 0, "
			... "updated_at INT NOT NULL DEFAULT 0, "
			... "PRIMARY KEY (steamid64, class_index, loadout_slot, weapon_uid), "
			... "KEY idx_cwx_weapon_equipped (weapon_uid, equipped), "
			... "KEY idx_cwx_weapon_unique (weapon_uid, steamid64), "
			... "KEY idx_cwx_class_weapon (class_name, weapon_uid)) "
			... "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
			CWX_STATS_STATE_TABLE);
	} else {
		Format(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS %s ("
			... "steamid64 VARCHAR(32) NOT NULL, "
			... "player_name VARCHAR(128) NOT NULL DEFAULT '', "
			... "class_index INTEGER NOT NULL, "
			... "class_name VARCHAR(16) NOT NULL DEFAULT '', "
			... "loadout_slot INTEGER NOT NULL, "
			... "weapon_uid VARCHAR(64) NOT NULL, "
			... "weapon_name VARCHAR(128) NOT NULL DEFAULT '', "
			... "equipped INTEGER NOT NULL DEFAULT 0, "
			... "first_equipped_at INTEGER NOT NULL DEFAULT 0, "
			... "last_equipped_at INTEGER NOT NULL DEFAULT 0, "
			... "last_unequipped_at INTEGER NOT NULL DEFAULT 0, "
			... "equip_count INTEGER NOT NULL DEFAULT 0, "
			... "unequip_count INTEGER NOT NULL DEFAULT 0, "
			... "updated_at INTEGER NOT NULL DEFAULT 0, "
			... "PRIMARY KEY (steamid64, class_index, loadout_slot, weapon_uid))",
			CWX_STATS_STATE_TABLE);
	}

	g_CwxStatsDb.Query(CwxStats_OnSchemaReady, query);
}

public void CwxStats_OnSchemaReady(Database db, DBResultSet results, const char[] error, any data) {
	if (error[0]) {
		LogError("[CWX] Failed to create statistics schema: %s", error);
		if (Db_IsTransientError(error)) {
			ScheduleCwxStatsDatabaseReconnect();
		}
		return;
	}

	g_CwxStatsDbReady = true;
	Db_CancelTimer(g_hCwxStatsDbReconnectTimer);
	if (!g_CwxStatsIsMySql) {
		g_CwxStatsDb.Query(CwxStats_OnQueryComplete,
				"CREATE INDEX IF NOT EXISTS idx_cwx_weapon_equipped "
				... "ON cwx_weapon_popularity (weapon_uid, equipped)");
		g_CwxStatsDb.Query(CwxStats_OnQueryComplete,
				"CREATE INDEX IF NOT EXISTS idx_cwx_weapon_unique "
				... "ON cwx_weapon_popularity (weapon_uid, steamid64)");
		g_CwxStatsDb.Query(CwxStats_OnQueryComplete,
				"CREATE INDEX IF NOT EXISTS idx_cwx_class_weapon "
				... "ON cwx_weapon_popularity (class_name, weapon_uid)");
	}
	CwxStats_MirrorLoadedClients();
}

public void CwxStats_OnQueryComplete(Database db, DBResultSet results, const char[] error, any data) {
	if (!error[0]) {
		return;
	}

	LogError("[CWX] Statistics query failed: %s", error);
	if (Db_IsTransientError(error)) {
		ScheduleCwxStatsDatabaseReconnect(DB_RECONNECT_FAST_DELAY);
	}
}

void CwxStats_RecordEquip(int client, int playerClass, int itemSlot, const char[] itemUid,
		const CustomItemDefinition item) {
	if (!CwxStats_IsEnabled()) {
		return;
	}

	char weaponName[MAX_ITEM_NAME_LENGTH];
	if (item.displayName[0]) {
		strcopy(weaponName, sizeof(weaponName), item.displayName);
	} else {
		strcopy(weaponName, sizeof(weaponName), itemUid);
	}
	CwxStats_LogTransition("cwx_weapon_equip", client, playerClass, itemSlot, itemUid, weaponName);

	char steamId64[KOGASA_STEAMID_MAX], playerName[MAX_NAME_LENGTH];
	if (!CwxStats_GetClientStateIdentity(client, steamId64, sizeof(steamId64),
			playerName, sizeof(playerName))) {
		return;
	}

	CwxStats_ClearSlotState(steamId64, playerClass, itemSlot, true);
	CwxStats_UpsertEquipState(steamId64, playerName, playerClass, itemSlot, itemUid,
			weaponName, true);
}

void CwxStats_RecordUnequip(int client, int playerClass, int itemSlot, const char[] itemUid) {
	if (!CwxStats_IsEnabled()) {
		return;
	}

	char weaponName[MAX_ITEM_NAME_LENGTH];
	CwxStats_GetWeaponName(itemUid, weaponName, sizeof(weaponName));
	CwxStats_LogTransition("cwx_weapon_unequip", client, playerClass, itemSlot, itemUid,
			weaponName);

	char steamId64[KOGASA_STEAMID_MAX], playerName[MAX_NAME_LENGTH];
	if (!CwxStats_GetClientStateIdentity(client, steamId64, sizeof(steamId64),
			playerName, sizeof(playerName))) {
		return;
	}

	CwxStats_ClearSlotState(steamId64, playerClass, itemSlot, true);
}

void CwxStats_MirrorLoadedClients() {
	for (int client = 1; client <= MaxClients; client++) {
		if (IsClientConnected(client) && g_bRetrievedLoadout[client]) {
			CwxStats_MirrorClientSavedLoadout(client);
		}
	}
}

void CwxStats_MirrorClientSavedLoadout(int client) {
	if (!CwxStats_CanWriteState()) {
		return;
	}

	char steamId64[KOGASA_STEAMID_MAX], playerName[MAX_NAME_LENGTH];
	if (!CwxStats_GetClientStateIdentity(client, steamId64, sizeof(steamId64),
			playerName, sizeof(playerName))) {
		return;
	}

	for (int playerClass = 1; playerClass < NUM_PLAYER_CLASSES; playerClass++) {
		for (int itemSlot = 0; itemSlot < NUM_ITEMS; itemSlot++) {
			char itemUid[MAX_ITEM_IDENTIFIER_LENGTH];
			strcopy(itemUid, sizeof(itemUid), g_CurrentLoadout[client][playerClass][itemSlot].uid);
			if (!itemUid[0]) {
				continue;
			}

			char weaponName[MAX_ITEM_NAME_LENGTH];
			CwxStats_GetWeaponName(itemUid, weaponName, sizeof(weaponName));
			CwxStats_UpsertEquipState(steamId64, playerName, playerClass, itemSlot,
					itemUid, weaponName, false);
		}
	}
}

bool CwxStats_GetClientStateIdentity(int client, char[] steamId64, int steamLen,
		char[] playerName, int nameLen) {
	if (!CwxStats_CanWriteState()) {
		return false;
	}

	if (!Kogasa_GetClientSteamId64(client, steamId64, steamLen, true)) {
		return false;
	}

	if (!GetClientName(client, playerName, nameLen) || !playerName[0]) {
		strcopy(playerName, nameLen, steamId64);
	}
	return true;
}

void CwxStats_LogTransition(const char[] eventName, int client, int playerClass, int itemSlot,
		const char[] itemUid, const char[] weaponName) {
	char steamId64[KOGASA_STEAMID_MAX] = "unknown";
	char playerName[MAX_NAME_LENGTH] = "unknown";
	char className[16];
	char safeEvent[64];
	char safeUid[MAX_ITEM_IDENTIFIER_LENGTH];
	char safeWeaponName[MAX_ITEM_NAME_LENGTH];

	if (client > 0 && client <= MaxClients && IsClientConnected(client)) {
		Kogasa_GetClientSteamId64(client, steamId64, sizeof(steamId64), true);
		GetClientName(client, playerName, sizeof(playerName));
	}
	CwxStats_GetClassName(playerClass, className, sizeof(className));
	strcopy(safeEvent, sizeof(safeEvent), eventName);
	strcopy(safeUid, sizeof(safeUid), itemUid);
	strcopy(safeWeaponName, sizeof(safeWeaponName), weaponName);
	CwxStats_SanitizeField(steamId64, sizeof(steamId64));
	CwxStats_SanitizeField(playerName, sizeof(playerName));
	CwxStats_SanitizeField(className, sizeof(className));
	CwxStats_SanitizeField(safeEvent, sizeof(safeEvent));
	CwxStats_SanitizeField(safeUid, sizeof(safeUid));
	CwxStats_SanitizeField(safeWeaponName, sizeof(safeWeaponName));

	int userid = (client > 0 && client <= MaxClients && IsClientConnected(client))
			? GetClientUserId(client) : 0;
	char message[512];
	Format(message, sizeof(message),
			"event=%s|client=%d|userid=%d|steamid64=%s|name=%s|class=%s|class_index=%d|slot=%d|weapon_uid=%s|weapon_name=%s",
			safeEvent,
			client,
			userid,
			steamId64,
			playerName,
			className,
			playerClass,
			itemSlot,
			safeUid,
			safeWeaponName);
	PluginStats_Record(safeEvent, message);
}

void CwxStats_ClearSlotState(const char[] steamId64, int playerClass, int itemSlot,
		bool incrementUnequipCount) {
	if (!CwxStats_CanWriteState()) {
		return;
	}

	char escapedSteam[64];
	Db_Escape(g_CwxStatsDb, steamId64, escapedSteam, sizeof(escapedSteam), "cwx");

	int now = GetTime();
	char query[1024];
	if (incrementUnequipCount) {
		Format(query, sizeof(query),
			"UPDATE %s SET equipped = 0, "
			... "last_unequipped_at = CASE WHEN equipped != 0 THEN %d ELSE last_unequipped_at END, "
			... "unequip_count = unequip_count + CASE WHEN equipped != 0 THEN 1 ELSE 0 END, "
			... "updated_at = %d "
			... "WHERE steamid64 = '%s' AND class_index = %d AND loadout_slot = %d AND equipped != 0",
			CWX_STATS_STATE_TABLE,
			now,
			now,
			escapedSteam,
			playerClass,
			itemSlot);
	} else {
		Format(query, sizeof(query),
			"UPDATE %s SET equipped = 0, updated_at = %d "
			... "WHERE steamid64 = '%s' AND class_index = %d AND loadout_slot = %d AND equipped != 0",
			CWX_STATS_STATE_TABLE,
			now,
			escapedSteam,
			playerClass,
			itemSlot);
	}
	g_CwxStatsDb.Query(CwxStats_OnQueryComplete, query);
}

void CwxStats_UpsertEquipState(const char[] steamId64, const char[] playerName,
		int playerClass, int itemSlot, const char[] itemUid, const char[] weaponName,
		bool incrementEquipCount) {
	if (!CwxStats_CanWriteState()) {
		return;
	}

	char className[16];
	CwxStats_GetClassName(playerClass, className, sizeof(className));

	char escapedSteam[64], escapedName[256], escapedClass[64], escapedUid[128], escapedWeapon[256];
	Db_Escape(g_CwxStatsDb, steamId64, escapedSteam, sizeof(escapedSteam), "cwx");
	Db_Escape(g_CwxStatsDb, playerName, escapedName, sizeof(escapedName), "cwx");
	Db_Escape(g_CwxStatsDb, className, escapedClass, sizeof(escapedClass), "cwx");
	Db_Escape(g_CwxStatsDb, itemUid, escapedUid, sizeof(escapedUid), "cwx");
	Db_Escape(g_CwxStatsDb, weaponName, escapedWeapon, sizeof(escapedWeapon), "cwx");

	int now = GetTime();
	int updateIncrement = incrementEquipCount ? 1 : 0;
	char query[2048];
	if (g_CwxStatsIsMySql) {
		Format(query, sizeof(query),
			"INSERT INTO %s (steamid64, player_name, class_index, class_name, loadout_slot, "
			... "weapon_uid, weapon_name, equipped, first_equipped_at, last_equipped_at, "
			... "last_unequipped_at, equip_count, unequip_count, updated_at) "
			... "VALUES ('%s', '%s', %d, '%s', %d, '%s', '%s', 1, %d, %d, 0, 1, 0, %d) "
			... "ON DUPLICATE KEY UPDATE player_name = VALUES(player_name), "
			... "class_name = VALUES(class_name), weapon_name = VALUES(weapon_name), "
			... "equipped = 1, last_equipped_at = VALUES(last_equipped_at), "
			... "equip_count = equip_count + %d, updated_at = VALUES(updated_at)",
			CWX_STATS_STATE_TABLE,
			escapedSteam,
			escapedName,
			playerClass,
			escapedClass,
			itemSlot,
			escapedUid,
			escapedWeapon,
			now,
			now,
			now,
			updateIncrement);
	} else {
		Format(query, sizeof(query),
			"INSERT INTO %s (steamid64, player_name, class_index, class_name, loadout_slot, "
			... "weapon_uid, weapon_name, equipped, first_equipped_at, last_equipped_at, "
			... "last_unequipped_at, equip_count, unequip_count, updated_at) "
			... "VALUES ('%s', '%s', %d, '%s', %d, '%s', '%s', 1, %d, %d, 0, 1, 0, %d) "
			... "ON CONFLICT(steamid64, class_index, loadout_slot, weapon_uid) DO UPDATE SET "
			... "player_name = excluded.player_name, class_name = excluded.class_name, "
			... "weapon_name = excluded.weapon_name, equipped = 1, "
			... "last_equipped_at = excluded.last_equipped_at, "
			... "equip_count = %s.equip_count + %d, updated_at = excluded.updated_at",
			CWX_STATS_STATE_TABLE,
			escapedSteam,
			escapedName,
			playerClass,
			escapedClass,
			itemSlot,
			escapedUid,
			escapedWeapon,
			now,
			now,
			now,
			CWX_STATS_STATE_TABLE,
			updateIncrement);
	}
	g_CwxStatsDb.Query(CwxStats_OnQueryComplete, query);
}

void CwxStats_GetWeaponName(const char[] itemUid, char[] buffer, int maxlen) {
	CustomItemDefinition item;
	if (GetCustomItemDefinition(itemUid, item) && item.displayName[0]) {
		strcopy(buffer, maxlen, item.displayName);
		return;
	}
	strcopy(buffer, maxlen, itemUid);
}

void CwxStats_GetClassName(int playerClass, char[] buffer, int maxlen) {
	TF2Classes_GetKey(view_as<TFClassType>(playerClass), buffer, maxlen, "unknown");
}

void CwxStats_SanitizeField(char[] value, int maxlen) {
	ReplaceString(value, maxlen, "|", "/", false);
	ReplaceString(value, maxlen, "\r", " ", false);
	ReplaceString(value, maxlen, "\n", " ", false);
	ReplaceString(value, maxlen, "\t", " ", false);
	ReplaceString(value, maxlen, "\"", "'", false);
	TrimString(value);
}

// bool CWX_GetPlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot, char[] uid, int uidLen, int flags = 0);
int Native_GetPlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	int itemSlot = GetNativeCell(3);
	int uidLen = GetNativeCell(5);
	int flags = GetNativeCell(6);
	
	if (g_CurrentLoadout[client][playerClass][itemSlot].IsEmpty()) {
		return false;
	}
	
	char[] uid = new char[uidLen];
	if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
		strcopy(uid, uidLen, g_CurrentLoadout[client][playerClass][itemSlot].uid);
	} else {
		strcopy(uid, uidLen, g_CurrentLoadout[client][playerClass][itemSlot].override_uid);
	}
	SetNativeString(4, uid, uidLen);
	return true;
}

/**
 * Called when a player's custom inventory has changed.  Decide if we should act on it.
 */
void OnClientCustomLoadoutItemModified(int client, int modifiedClass) {
	if (view_as<int>(TF2_GetPlayerClass(client)) != modifiedClass) {
		// do nothing if the loadout for the current class wasn't modified
		return;
	}
	
	if (!sm_cwx_enable_loadout.BoolValue) {
		// do nothing if user selections are disabled
		return;
	}
	
	if (IsPlayerAllowedToRespawnOnLoadoutChange(client)) {
		// see if the player is into being respawned on loadout changes
		QueryClientConVar(client, "tf_respawn_on_loadoutchanges", OnLoadoutRespawnPreference);
	} else {
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
	}
}

/**
 * Called after inventory change and we have the client's tf_respawn_on_loadoutchanges convar
 * value.  Respawn them if desired.
 */
void OnLoadoutRespawnPreference(QueryCookie cookie, int client, ConVarQueryResult result,
		const char[] cvarName, const char[] cvarValue) {
	if (result != ConVarQuery_Okay) {
		return;
	} else if (!StringToInt(cvarValue) || !IsPlayerAllowedToRespawnOnLoadoutChange(client)) {
		// the second check for respawn room is in case we're somehow not in one between
		// the query and the callback
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
		return;
	}
	
	// mark player as regenerating during respawn -- this prevents stickies from despawning
	// this matches the game's internal behavior during GC loadout changes
	SetEntProp(client, Prop_Send, "m_bRegenerating", true);
	TF2_RespawnPlayer(client);
	SetEntProp(client, Prop_Send, "m_bRegenerating", false);
}

/**
 * Returns whether or not the player can actually equip this item normally.
 * (This does not prevent admins from forcibly applying the item to the player.)
 */
bool CanPlayerEquipItem(int client, const CustomItemDefinition item) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	return CanPlayerEquipItemForClass(client, view_as<int>(playerClass), item);
}

/**
 * Returns whether or not the player can equip this item for the given class.
 */
bool CanPlayerEquipItemForClass(int client, int playerClass, const CustomItemDefinition item) {
	if (playerClass <= 0 || playerClass >= NUM_PLAYER_CLASSES) {
		return false;
	}
	
	if (item.loadoutPosition[playerClass] == -1) {
		return false;
	}
	
	return CanPlayerAccessItem(client, item);
}

/**
 * Returns whether the item should be visible to the client. Store-gated items
 * remain visible so the loadout menu can direct players to !shop.
 */
bool CanPlayerViewItem(int client, const CustomItemDefinition item) {
	return !item.access[0] || CheckCommandAccess(client, item.access, 0, true);
}

bool ItemRequiresPointsStorePurchase(int client, const CustomItemDefinition item) {
	if (!item.pointsStorePurchase[0]) {
		return false;
	}

	return client <= 0 || client > MaxClients || !IsClientInGame(client)
		|| GetFeatureStatus(FeatureType_Native, POINTS_STORE_HAS_PURCHASE_NATIVE)
			!= FeatureStatus_Available
		|| !PointsStore_HasPurchase(client, item.pointsStorePurchase);
}

/**
 * Returns whether or not the player has access to this item.
 */
bool CanPlayerAccessItem(int client, const CustomItemDefinition item) {
	if (!CanPlayerViewItem(client, item)) {
		// this item requires access
		return false;
	}
	
	if (ItemRequiresPointsStorePurchase(client, item)) {
		return false;
	}
	
	return true;
}

/**
 * Returns whether or not the player is in a respawn room that their team owns, for the purpose
 * of repsawning on loadout change.
 */
static bool IsPlayerInRespawnRoom(int client) {
	float vecMins[3], vecMaxs[3], vecCenter[3], vecOrigin[3];
	GetClientMins(client, vecMins);
	GetClientMaxs(client, vecMaxs);
	GetClientAbsOrigin(client, vecOrigin);
	
	GetCenterFromPoints(vecMins, vecMaxs, vecCenter);
	AddVectors(vecOrigin, vecCenter, vecCenter);
	return TF2Util_IsPointInRespawnRoom(vecCenter, client, true);
}

/**
 * Returns whether or not the player is allowed to respawn on loadout changes.
 */
static bool IsPlayerAllowedToRespawnOnLoadoutChange(int client) {
	if (!IsClientInGame(client) || !IsPlayerInRespawnRoom(client) || !IsPlayerAlive(client)) {
		return false;
	}
	
	// prevent respawns on sudden death
	// ideally we'd base this off of CTFGameRules::CanChangeClassInStalemate(), but that
	// requires either gamedata or keeping track of the stalemate time ourselves
	if (GameRules_GetRoundState() == RoundState_Stalemate) {
		return false;
	}
	
	return true;
}

/**
 * Returns whether or not the custom item is currently allowed.  This is specifically for
 * instances where the item may be temporarily restricted (Medieval, melee-only Sudden Death).
 * 
 * sm_cwx_enable_loadout is checked earlier, during OnPlayerLoadoutUpdatedPost and
 * OnGetLoadoutItemPost.
 */
static bool IsCustomItemAllowed(int client, const CustomItemDefinition item) {
	if (!IsClientInGame(client)) {
		return false;
	}
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	int slot = item.loadoutPosition[playerClass];
	
	// TODO work out other restrictions?
	
	if (GameRules_GetRoundState() == RoundState_Stalemate && mp_stalemate_meleeonly.BoolValue) {
		bool bMelee = slot == 2 || (playerClass == TFClass_Spy && (slot == 5 || slot == 6));
		if (!bMelee) {
			return false;
		}
	}
	
	if (GameRules_GetProp("m_bPlayingMedieval")) {
		bool bMedievalAllowed;
		if (slot == 2) {
			bMedievalAllowed = true;
		}
		
		if (!bMedievalAllowed) {
			// non-melee item; time to check the schema...
			bool bMedievalAllowedInSchema;
			
			bool bNativeAttributeOverride;
			if (item.nativeAttributes) {
				char configValue[8];
				item.nativeAttributes.GetString("allowed in medieval mode",
						configValue, sizeof(configValue));
				
				if (configValue[0]) {
					// don't fallback to static attributes if override in config
					bNativeAttributeOverride = true;
					bMedievalAllowedInSchema = !!StringToInt(configValue);
				}
			}
			if (!bNativeAttributeOverride && item.bKeepStaticAttributes) {
				// TODO we should cache this...
				ArrayList attribList = TF2Econ_GetItemStaticAttributes(item.defindex);
				bMedievalAllowedInSchema =
						attribList.FindValue(g_attrdef_AllowedInMedievalMode) != -1;
				delete attribList;
			}
			
			if (!bMedievalAllowedInSchema) {
				return false;
			}
		}
	}
	return true;
}
