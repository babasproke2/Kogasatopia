/*
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see http://www.gnu.org/licenses/.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdktools>

#include <dhooks>
#include <tf_econ_data>
#include <morecolors>

#define PLUGIN_VERSION "1.1.1"

#define LOADOUT_POSITION_PRIMARY 0
#define LOADOUT_POSITION_SECONDARY 1
#define LOADOUT_POSITION_MELEE 2

ConVar convar_mpTournament;

Handle dhook_CEconItemSystem_ReloadWhitelist;
Handle dhook_CTFPlayer_GetLoadoutItem;
Handle sdkcall_CTFPlayerInventory_GetItemInLoadout;
Handle sdkcall_CTFInventoryManager_GetBaseItemForClass;
Handle sdkcall_CEconItemView_GetItemDefIndex;

Address address_TFInventoryManager;
int offset_CTFPlayer_Inventory;
bool whitelistNoticePending[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "Enable Item Whitelist outside of Tournament Mode",
	author = "Sappykun",
	description = "Force-enables tournament mode only when loading and applying the item whitelist.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?p=2819339"
};

public void OnPluginStart()
{
	CreateConVar("sm_enablewhitelist_version", PLUGIN_VERSION, "Enable Item Whitelist version. Don't touch.", FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_SPONLY | FCVAR_DONTRECORD);

	convar_mpTournament = FindConVar("mp_tournament");
	convar_mpTournament.Flags &= ~FCVAR_NOTIFY;

	GameData conf = LoadGameConfigFile("tf2.enablewhitelist");
	if (conf == null) SetFailState("Failed to load tf2.enablewhitelist!");

	dhook_CEconItemSystem_ReloadWhitelist = DHookCreateFromConf(conf, "ReloadWhitelist");
	dhook_CTFPlayer_GetLoadoutItem = DHookCreateFromConf(conf, "GetLoadoutItem");

	if (dhook_CEconItemSystem_ReloadWhitelist == null) SetFailState("Failed to create dhook_CEconItemSystem_ReloadWhitelist");
	if (dhook_CTFPlayer_GetLoadoutItem == null) SetFailState("Failed to create dhook_CTFPlayer_GetLoadoutItem");

	offset_CTFPlayer_Inventory = conf.GetOffset("CTFPlayer::m_Inventory");
	if (offset_CTFPlayer_Inventory < 0)
		SetFailState("Failed to find CTFPlayer::m_Inventory offset");

	sdkcall_CTFPlayerInventory_GetItemInLoadout = PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CTFPlayerInventory::GetItemInLoadout",
		2
	);
	sdkcall_CTFInventoryManager_GetBaseItemForClass = PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CTFInventoryManager::GetBaseItemForClass",
		2
	);
	sdkcall_CEconItemView_GetItemDefIndex = PrepareSDKCall(
		conf,
		SDKCall_Raw,
		"CEconItemView::GetItemDefIndex",
		0
	);

	Handle sdkcall_TFInventoryManager = PrepareSDKCall(
		conf,
		SDKCall_Static,
		"TFInventoryManager",
		0
	);
	address_TFInventoryManager = view_as<Address>(SDKCall(sdkcall_TFInventoryManager));
	delete sdkcall_TFInventoryManager;
	if (address_TFInventoryManager == Address_Null)
		SetFailState("TFInventoryManager returned a null address");

	delete conf;

	DHookEnableDetour(dhook_CEconItemSystem_ReloadWhitelist, false, DHookCallback_TournamentModeEnable);
	DHookEnableDetour(dhook_CEconItemSystem_ReloadWhitelist, true, DHookCallback_TournamentModeDisable);
	DHookEnableDetour(dhook_CTFPlayer_GetLoadoutItem, false, DHookCallback_GetLoadoutItemPre);
	DHookEnableDetour(dhook_CTFPlayer_GetLoadoutItem, true, DHookCallback_GetLoadoutItemPost);

	HookUserMessage(GetUserMessageId("TextMsg"), UserMessage_TextMsg);
}

Handle PrepareSDKCall(GameData conf, SDKCallType callType, const char[] signature, int parameterCount)
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

public void OnClientDisconnect(int client)
{
	whitelistNoticePending[client] = false;
}

public Action UserMessage_TextMsg(UserMsg msgId, BfRead message, const int[] players, int playersNum, bool reliable, bool init)
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
			ScheduleWhitelistNotice(client);
	}

	return Plugin_Continue;
}

void ScheduleWhitelistNotice(int client)
{
	if (whitelistNoticePending[client])
		return;

	whitelistNoticePending[client] = true;
	RequestFrame(Frame_PrintWhitelistNotice, GetClientUserId(client));
}

void Frame_PrintWhitelistNotice(any userId)
{
	int client = GetClientOfUserId(userId);
	if (client > 0 && client <= MaxClients)
		whitelistNoticePending[client] = false;

	if (client > 0 && IsClientInGame(client))
		CPrintToChat(client, "{gold}[WhiteList]{default} Demoknight has been disabled on this server.");
}

MRESReturn DHookCallback_TournamentModeEnable(int entity, DHookReturn hReturn)
{
	convar_mpTournament.SetBool(true, true, false);
	return MRES_Ignored;
}

MRESReturn DHookCallback_TournamentModeDisable(int entity, DHookReturn hReturn)
{
	convar_mpTournament.SetBool(false, true, false);
	return MRES_Ignored;
}

MRESReturn DHookCallback_GetLoadoutItemPre(int client, DHookReturn hReturn, DHookParam hParams)
{
	convar_mpTournament.SetBool(true, true, false);
	return MRES_Ignored;
}

MRESReturn DHookCallback_GetLoadoutItemPost(int client, DHookReturn hReturn, DHookParam hParams)
{
	convar_mpTournament.SetBool(false, true, false);

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return MRES_Ignored;

	int playerClass = hParams.Get(1);
	int loadoutSlot = hParams.Get(2);
	if (playerClass != view_as<int>(TFClass_DemoMan)
		|| (loadoutSlot != LOADOUT_POSITION_PRIMARY
			&& loadoutSlot != LOADOUT_POSITION_SECONDARY
			&& loadoutSlot != LOADOUT_POSITION_MELEE)
		|| !IsForbiddenLoadoutCombo(client, playerClass))
	{
		return MRES_Ignored;
	}

	Address baseItem = view_as<Address>(SDKCall(
		sdkcall_CTFInventoryManager_GetBaseItemForClass,
		address_TFInventoryManager,
		playerClass,
		loadoutSlot
	));
	if (baseItem == Address_Null)
		return MRES_Ignored;

	hReturn.Value = baseItem;
	if (hParams.Get(3))
		ScheduleWhitelistNotice(client);

	return MRES_Supercede;
}

bool IsForbiddenLoadoutCombo(int client, int playerClass)
{
	char itemClass[64];
	if (!GetRawSelectedItemClass(
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

	if (!GetRawSelectedItemClass(
			client,
			playerClass,
			LOADOUT_POSITION_SECONDARY,
			itemClass,
			sizeof(itemClass))
		|| !StrEqual(itemClass, "tf_wearable_demoshield"))
	{
		return false;
	}

	if (!GetRawSelectedItemClass(
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

bool GetRawSelectedItemClass(
	int client,
	int playerClass,
	int loadoutSlot,
	char[] itemClass,
	int itemClassLength)
{
	Address playerAddress = GetEntityAddress(client);
	if (playerAddress == Address_Null)
		return false;

	Address inventoryAddress = playerAddress + view_as<Address>(offset_CTFPlayer_Inventory);
	Address itemView = view_as<Address>(SDKCall(
		sdkcall_CTFPlayerInventory_GetItemInLoadout,
		inventoryAddress,
		playerClass,
		loadoutSlot
	));
	if (itemView == Address_Null)
		return false;

	int itemDefinition = SDKCall(sdkcall_CEconItemView_GetItemDefIndex, itemView);
	return TF2Econ_GetItemClassName(itemDefinition, itemClass, itemClassLength);
}
