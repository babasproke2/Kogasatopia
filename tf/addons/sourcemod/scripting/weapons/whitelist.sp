#define WEAPONS_WHITELIST_VERSION "1.1.1"

#define LOADOUT_POSITION_PRIMARY 0
#define LOADOUT_POSITION_SECONDARY 1
#define LOADOUT_POSITION_MELEE 2

ConVar g_WeaponsWhitelistTournament;

Handle g_WeaponsWhitelistReloadDetour;
Handle g_WeaponsWhitelistGetItemInLoadout;
Handle g_WeaponsWhitelistGetBaseItemForClass;
Handle g_WeaponsWhitelistGetItemDefIndex;

Address g_WeaponsWhitelistInventoryManager;
int g_WeaponsWhitelistInventoryOffset;
bool g_WeaponsWhitelistNoticePending[MAXPLAYERS + 1];


void WeaponsWhitelist_OnPluginStart()
{
	CreateConVar("sm_enablewhitelist_version", WEAPONS_WHITELIST_VERSION, "Enable Item Whitelist version. Don't touch.", FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_SPONLY | FCVAR_DONTRECORD);

	g_WeaponsWhitelistTournament = FindConVar("mp_tournament");
	g_WeaponsWhitelistTournament.Flags &= ~FCVAR_NOTIFY;

	GameData conf = LoadGameConfigFile("tf2.enablewhitelist");
	if (conf == null) SetFailState("Failed to load tf2.enablewhitelist!");

	g_WeaponsWhitelistReloadDetour = DHookCreateFromConf(conf, "ReloadWhitelist");

	if (g_WeaponsWhitelistReloadDetour == null) SetFailState("Failed to create g_WeaponsWhitelistReloadDetour");

	g_WeaponsWhitelistInventoryOffset = conf.GetOffset("CTFPlayer::m_Inventory");
	if (g_WeaponsWhitelistInventoryOffset < 0)
		SetFailState("Failed to find CTFPlayer::m_Inventory offset");

	g_WeaponsWhitelistGetItemInLoadout = WeaponsWhitelist_PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CTFPlayerInventory::GetItemInLoadout",
		2
	);
	g_WeaponsWhitelistGetBaseItemForClass = WeaponsWhitelist_PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CTFInventoryManager::GetBaseItemForClass",
		2
	);
	g_WeaponsWhitelistGetItemDefIndex = WeaponsWhitelist_PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CEconItemView::GetItemDefIndex",
		0
	);

	Handle sdkcall_TFInventoryManager = WeaponsWhitelist_PrepareSDKCall(
		conf,
		SDKCall_Static,
		"TFInventoryManager",
		0
	);
	g_WeaponsWhitelistInventoryManager = view_as<Address>(SDKCall(sdkcall_TFInventoryManager));
	delete sdkcall_TFInventoryManager;
	if (g_WeaponsWhitelistInventoryManager == Address_Null)
		SetFailState("TFInventoryManager returned a null address");

	delete conf;

	DHookEnableDetour(g_WeaponsWhitelistReloadDetour, false, WeaponsWhitelist_OnTournamentModeEnable);
	DHookEnableDetour(g_WeaponsWhitelistReloadDetour, true, WeaponsWhitelist_OnTournamentModeDisable);

	HookUserMessage(GetUserMessageId("TextMsg"), WeaponsWhitelist_OnTextMessage);
}

Handle WeaponsWhitelist_PrepareSDKCall(GameData conf, SDKCallType callType, const char[] signature, int parameterCount)
{
	StartPrepSDKCall(callType);
	if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, signature))
		SetFailState("Failed to find SDKCall signature: %s", signature);

	for (int i = 0; i < parameterCount; i++)
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByValue);

	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);

	Handle call = EndPrepSDKCall();
	if (call == null)
		SetFailState("Failed to prepare SDKCall: %s", signature);

	return call;
}

void WeaponsWhitelist_OnClientDisconnect(int client)
{
	g_WeaponsWhitelistNoticePending[client] = false;
}

public Action WeaponsWhitelist_OnTextMessage(UserMsg msgId, BfRead message, const int[] players, int playersNum, bool reliable, bool init)
{
	message.ReadByte();

	char token[64];
	message.ReadString(token, sizeof(token));
	if (!StrEqual(token, "#Item_BlacklistedInMatch") && !StrEqual(token, "Item_BlacklistedInMatch"))
		return Plugin_Continue;

	for (int i = 0; i < playersNum; i++)
	{
		int client = players[i];
		if (client > 0 && client <= MaxClients && IsClientInGame(client))
			WeaponsWhitelist_ScheduleNotice(client);
	}

	return Plugin_Continue;
}

void WeaponsWhitelist_ScheduleNotice(int client)
{
	if (g_WeaponsWhitelistNoticePending[client])
		return;

	g_WeaponsWhitelistNoticePending[client] = true;
	RequestFrame(WeaponsWhitelist_PrintNotice, GetClientUserId(client));
}

void WeaponsWhitelist_PrintNotice(any userId)
{
	int client = GetClientOfUserId(userId);
	if (client > 0 && client <= MaxClients)
		g_WeaponsWhitelistNoticePending[client] = false;

	if (client > 0 && IsClientInGame(client))
		CPrintToChat(client, "{gold}[WhiteList]{default} Demoknight has been disabled on this server.");
}

MRESReturn WeaponsWhitelist_OnTournamentModeEnable(int entity, DHookReturn hReturn)
{
	g_WeaponsWhitelistTournament.SetBool(true, true, false);
	return MRES_Ignored;
}

MRESReturn WeaponsWhitelist_OnTournamentModeDisable(int entity, DHookReturn hReturn)
{
	g_WeaponsWhitelistTournament.SetBool(false, true, false);
	return MRES_Ignored;
}

MRESReturn WeaponsWhitelist_OnGetLoadoutItemPre(int client, DHookReturn hReturn, DHookParam hParams)
{
	#pragma unused client
	#pragma unused hReturn
	#pragma unused hParams
	g_WeaponsWhitelistTournament.SetBool(true, true, false);
	return MRES_Ignored;
}

MRESReturn WeaponsWhitelist_ApplyLoadoutRule(int client, DHookReturn hReturn, DHookParam hParams)
{
	g_WeaponsWhitelistTournament.SetBool(false, true, false);

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return MRES_Ignored;

	int playerClass = hParams.Get(1);
	int loadoutSlot = hParams.Get(2);
	if (playerClass != view_as<int>(TFClass_DemoMan)
		|| (loadoutSlot != LOADOUT_POSITION_PRIMARY
			&& loadoutSlot != LOADOUT_POSITION_SECONDARY
			&& loadoutSlot != LOADOUT_POSITION_MELEE)
		|| !WeaponsWhitelist_IsForbiddenLoadoutCombo(client, playerClass))
	{
		return MRES_Ignored;
	}

	Address baseItem = view_as<Address>(SDKCall(
		g_WeaponsWhitelistGetBaseItemForClass,
		g_WeaponsWhitelistInventoryManager,
		playerClass,
		loadoutSlot
	));
	if (baseItem == Address_Null)
		return MRES_Ignored;

	hReturn.Value = baseItem;
	if (hParams.Get(3))
		WeaponsWhitelist_ScheduleNotice(client);

	return MRES_Supercede;
}

bool WeaponsWhitelist_IsForbiddenLoadoutCombo(int client, int playerClass)
{
	char itemClass[64];
	if (!WeaponsWhitelist_GetRawSelectedItemClass(
			client,
			playerClass,
			LOADOUT_POSITION_PRIMARY,
			itemClass,
			sizeof(itemClass))
		|| (!StrEqual(itemClass, "tf_wearable")
			&& !StrEqual(itemClass, "tf_weapon_wearable")))
	{
		return false;
	}

	if (!WeaponsWhitelist_GetRawSelectedItemClass(
			client,
			playerClass,
			LOADOUT_POSITION_SECONDARY,
			itemClass,
			sizeof(itemClass))
		|| !StrEqual(itemClass, "tf_wearable_demoshield"))
	{
		return false;
	}

	if (!WeaponsWhitelist_GetRawSelectedItemClass(
			client,
			playerClass,
			LOADOUT_POSITION_MELEE,
			itemClass,
			sizeof(itemClass)))
	{
		return false;
	}

	return StrEqual(itemClass, "tf_weapon_sword")
		|| StrEqual(itemClass, "tf_weapon_katana");
}

bool WeaponsWhitelist_GetRawSelectedItemClass(
	int client,
	int playerClass,
	int loadoutSlot,
	char[] itemClass,
	int itemClassLength)
{
	Address playerAddress = GetEntityAddress(client);
	if (playerAddress == Address_Null)
		return false;

	Address inventoryAddress = playerAddress + view_as<Address>(g_WeaponsWhitelistInventoryOffset);
	Address itemView = view_as<Address>(SDKCall(
		g_WeaponsWhitelistGetItemInLoadout,
		inventoryAddress,
		playerClass,
		loadoutSlot
	));
	if (itemView == Address_Null)
		return false;

	int itemDefinition = SDKCall(g_WeaponsWhitelistGetItemDefIndex, itemView);
	return TF2Econ_GetItemClassName(itemDefinition, itemClass, itemClassLength);
}
