/**
 * Weapon model overrides.
 * 
 * Provides three attributes "viewmodel override", "worldmodel override",
 * and "clientmodel override".  Attribute values are full paths to models (include "models/"
 * prefix).
 * 
 * - "viewmodel override" is used exclusively for the owning player's view.
 * - "worldmodel override" is used for other players' views, dropped weapons, and attached
 * sappers.
 * - "clientmodel override" can be used in place of both if they share the same model, and will
 * take priority.
 */
#define EF_NODRAW (1 << 5)
#define EF_BONEMERGE (1 << 0)

#define MODEL_NONE_ACTIVE    0
#define MODEL_VIEW_ACTIVE    (1 << 0)
#define MODEL_ARM_ACTIVE     (1 << 1)
#define MODEL_WORLD_ACTIVE   (1 << 2)
#define MODEL_OFFHAND_ACTIVE (1 << 3)

#define TF_ITEM_DEFINDEX_GUNSLINGER 142

#define ATTR_EXTRA_WEARABLE_MODEL_OVERRIDE "extra wearable model override"
#define ATTR_NAME_KILLSTREAK_IDLEEFFECT "killstreak idleeffect"
#define ATTR_CLASS_KILLSTREAK_IDLEEFFECT "killstreak_idleeffect"

bool g_bIgnoreWeaponSwitch[MAXPLAYERS + 1];
ConVar g_cvEdictReserve;
bool g_bLoggedEdictReserve;

int g_iLastViewmodelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLastArmModelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLastWorldModelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLastHiddenWorldWeaponRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iAppliedWeaponRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

int g_iLastOffHandViewmodelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

enum ModelAvailability {
	ModelAvailability_Unknown,
	ModelAvailability_Found,
	ModelAvailability_NotFound
};

StringMap g_ModelAvailabilityCache;

void VMO_OnPluginStart() {
	g_cvEdictReserve = CreateConVar("sm_viewmodel_override_edict_reserve", "128",
		"Minimum free edicts kept before spawning cosmetic override wearables. Set to 0 to disable.",
		_, true, 0.0);
	HookEvent("player_death", VMO_OnPlayerDeath);
	HookEvent("post_inventory_application", VMO_OnInventoryAppliedPost);
	HookEvent("player_sapped_object", VMO_OnObjectSappedPost);

	ResetModelAvailabilityCache();
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			VMO_OnClientPutInServer(i);
		}
	}
}

void VMO_OnMapStart() {
	ResetModelAvailabilityCache();
	g_bLoggedEdictReserve = false;
}

void VMO_OnPluginEnd() {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			DetachVMs(i);
		}
	}
}

void VMO_OnClientPutInServer(int client) {
	ResetClientModelRefs(client);
	SDKHook(client, SDKHook_Spawn, VMO_OnPlayerSpawnPre);
	SDKHook(client, SDKHook_SpawnPost, VMO_OnPlayerSpawnPost);
	SDKHook(client, SDKHook_WeaponSwitchPost, CWX_OnWeaponSwitchPost);
}

void VMO_OnClientDisconnect(int client) {
	DetachVMs(client);
	ResetClientModelRefs(client);
}

void VMO_OnEntityCreated(int entity, const char[] className) {
	if (StrEqual(className, "tf_dropped_weapon")) {
		SDKHook(entity, SDKHook_SpawnPost, VMO_OnDroppedWeaponSpawnPost);
	} else if (StrContains(className, "tf_wearable", false) == 0
			&& !StrEqual(className, "tf_wearable_vm")) {
		SDKHook(entity, SDKHook_SpawnPost, VMO_OnWearableSpawnPost);
	}
}

/**
 * Hotfix to ensure any attached Sniper Rifle is rendered when coming out of being in scope.
 */
void VMO_OnConditionRemoved(int client, TFCond cond) {
	int weaponvm = EntRefToEntIndex(g_iLastViewmodelRef[client]);
	if (cond == TFCond_Slowed && TF2_GetPlayerClass(client) == TFClass_Sniper
			&& weaponvm != INVALID_ENT_REFERENCE && IsValidEntity(weaponvm)) {
		UpdateClientWeaponModel(client);
	}
}

/**
 * Sets the world model of a dropped weapon.
 */
void VMO_OnDroppedWeaponSpawnPost(int weapon) {
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "clientmodel override", wm, sizeof(wm))
			|| TF2CustAttr_GetString(weapon, "worldmodel override", wm, sizeof(wm))) {
		if (FileExists(wm, true)) {
			SetEntityModel(weapon, wm);
			SetWeaponWorldModel(weapon, wm);
			CWX_MarkValidatedAttachedEntity(weapon, GetEntityOwner(weapon), "dropped_weapon");
		}
	}
}

/**
 * Called when the player's loadout is applied.  Note that other plugins may not have finished
 * applying weapons by this time; however, they should implicitly invoke WeaponSwitchPost
 * (because of GiveNamedItem, etc.) so viewmodels should be correct.
 */
void VMO_OnInventoryAppliedPost(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidViewmodelClient(client)) {
		return;
	}
	UpdateClientWeaponModel(client);
	ScheduleClientModelRefresh(client);
	
	/**
	 * start processing weapon switches, since other plugins may be equipping new weapons in
	 * post_inventory_application -- and that's still within the player's spawn function call
	 */
	g_bIgnoreWeaponSwitch[client] = false;
}

Action Timer_DelayedUpdateClientWeaponModel(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if (IsValidViewmodelClient(client)
			&& ClientWeaponModelNeedsRefresh(client)) {
		UpdateClientWeaponModel(client);
	}
	return Plugin_Stop;
}

void Frame_UpdateClientWeaponModel(any userid) {
	int client = GetClientOfUserId(userid);
	if (IsValidViewmodelClient(client)
			&& ClientWeaponModelNeedsRefresh(client)) {
		UpdateClientWeaponModel(client);
	}
}

/**
 * Defers an equip / switch refresh by one frame and binds it to the exact weapon
 * that caused the callback.  This prevents callbacks from other loadout weapons
 * rebuilding models for whichever weapon happens to be active later.
 */
void QueueWeaponBoundModelUpdate(int client, int weapon) {
	if (!IsValidViewmodelClient(client) || !IsValidEntity(weapon)) {
		return;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(EntIndexToEntRef(weapon));
	RequestFrame(Frame_UpdateClientWeaponModelForWeapon, pack);
}

void Frame_UpdateClientWeaponModelForWeapon(any data) {
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int userid = pack.ReadCell();
	int weaponRef = pack.ReadCell();
	delete pack;

	int client = GetClientOfUserId(userid);
	int weapon = EntRefToEntIndex(weaponRef);
	if (!IsValidViewmodelClient(client) || !IsValidEntity(weapon)
			|| weapon != TF2_GetClientActiveWeapon(client)
			|| !ClientWeaponModelNeedsRefresh(client)) {
		return;
	}

	UpdateClientWeaponModel(client, weapon);
	ScheduleClientModelValidationRetries(client);
}

void ScheduleClientModelUpdate(int client, float delay) {
	if (IsValidViewmodelClient(client)) {
		CreateTimer(delay, Timer_DelayedUpdateClientWeaponModel, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

void ScheduleClientModelUpdateRetries(int client) {
	ScheduleClientModelUpdate(client, 0.1);
	ScheduleClientModelUpdate(client, 0.35);
	ScheduleClientModelUpdate(client, 1.0);
}

void ScheduleClientModelValidation(int client, float delay) {
	if (IsValidViewmodelClient(client)) {
		CreateTimer(delay, Timer_ValidateClientWeaponModel, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

void ScheduleClientModelValidationRetries(int client) {
	ScheduleClientModelValidation(client, 1.5);
	ScheduleClientModelValidation(client, 3.0);
	ScheduleClientModelValidation(client, 5.0);
}

void ScheduleClientModelRefresh(int client) {
	ScheduleClientModelUpdateRetries(client);
	ScheduleClientModelValidationRetries(client);
}

Action Timer_ValidateClientWeaponModel(Handle timer, any userid) {
	int client = GetClientOfUserId(userid);
	if (IsValidViewmodelClient(client) && ClientWeaponModelNeedsRefresh(client)) {
		UpdateClientWeaponModel(client);
	}
	return Plugin_Stop;
}

Action VMO_OnPlayerSpawnPre(int client) {
	g_bIgnoreWeaponSwitch[client] = true;
	return Plugin_Continue;
}

void VMO_OnPlayerSpawnPost(int client) {
	g_bIgnoreWeaponSwitch[client] = false;
	RequestFrame(Frame_UpdateClientWeaponModel, GetClientUserId(client));
	ScheduleClientModelRefresh(client);
}

void VMO_OnItemRuntimeStateReady(int client, int entity) {
	if (!IsValidViewmodelClient(client) || !IsValidEntity(entity)
			|| TF2_GetClientActiveWeapon(client) != entity) {
		return;
	}

	QueueWeaponBoundModelUpdate(client, entity);
	ScheduleClientModelValidationRetries(client);
}

void VMO_OnWeaponSwitchPost(int client, int weapon) {
	if (!g_bIgnoreWeaponSwitch[client]) {
		QueueWeaponBoundModelUpdate(client, weapon);
		ScheduleClientModelUpdate(client, 0.1);
	}
}

static void CopyKillstreakSheen(int weapon, int wearable) {
	if (!IsValidEntity(weapon) || !IsValidEntity(wearable)) {
		return;
	}

	int sheen = TF2Attrib_HookValueInt(0, ATTR_CLASS_KILLSTREAK_IDLEEFFECT, weapon);
	if (sheen <= 0) {
		return;
	}

	char value[16];
	IntToString(sheen, value, sizeof(value));

	TF2Attrib_SetFromStringValue(
		wearable,
		ATTR_NAME_KILLSTREAK_IDLEEFFECT,
		value
	);
}

/**
 * Called on weapon switch.  Detaches any old viewmodel overrides and attaches replacements.
 */
void UpdateClientWeaponModel(int client, int expectedWeapon = INVALID_ENT_REFERENCE) {
	if (!IsValidViewmodelClient(client)) {
		ResetClientModelRefs(client);
		return;
	}

	UpdateClientWearableModels(client);
	
	int weapon = TF2_GetClientActiveWeapon(client);
	if (!IsValidEntity(weapon)
			|| (expectedWeapon != INVALID_ENT_REFERENCE && weapon != expectedWeapon)) {
		return;
	}
	
	DetachVMs(client);
	// Record identity as well as model refs; otherwise valid wearables from a
	// previous weapon can make validation incorrectly report success.
	g_iAppliedWeaponRef[client] = EntIndexToEntRef(weapon);
	
	int bitsActiveModels = MODEL_NONE_ACTIVE;
	
	char cm[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(weapon, "clientmodel override", cm, sizeof(cm));
	
	char vm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "viewmodel override", vm, sizeof(vm), cm)
			&& FileExistsAndLog(vm, true)) {
		// override viewmodel by attaching arm and weapon viewmodels
		PrecacheModelAndLog(vm);
		
		int weaponvm = TF2_SpawnWearableViewmodel();
		if (IsValidEntity(weaponvm)) {
			SetEntityModel(weaponvm, vm);
			CopyKillstreakSheen(weapon, weaponvm);
			TF2Util_EquipPlayerWearable(client, weaponvm);
			CWX_MarkValidatedAttachedEntity(weaponvm, client, "viewmodel_wearable_vm", true, weapon);
			
			g_iLastViewmodelRef[client] = EntIndexToEntRef(weaponvm);
			bitsActiveModels |= MODEL_VIEW_ACTIVE;
		}
	}
	
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "worldmodel override", wm, sizeof(wm), cm)
			&& FileExistsAndLog(wm, true)) {
		// this allows other players to see the given weapon with the correct model
		SetWeaponWorldModel(weapon, wm);
		CWX_MarkValidatedAttachedEntity(weapon, client, "active_weapon_worldmodel", true, weapon);
		
		// the following shows the weapon in third-person, as m_nModelIndexOverrides is messy
		int weaponwm = CanCreateOverrideWearable() ? TF2_SpawnWearable() : -1;
		if (IsValidEntity(weaponwm)) {
			SetEntityModel(weaponwm, wm);
			CopyKillstreakSheen(weapon, weaponwm);
			
			TF2Util_EquipPlayerWearable(client, weaponwm);
			CWX_MarkValidatedAttachedEntity(weaponwm, client, "worldmodel_wearable", true, weapon);
			g_iLastWorldModelRef[client] = EntIndexToEntRef(weaponwm);
			
			SetEntityRenderMode(weapon, RENDER_TRANSCOLOR);
			SetEntityRenderColor(weapon, 0, 0, 0, 0);
			g_iLastHiddenWorldWeaponRef[client] = EntIndexToEntRef(weapon);
			
			bitsActiveModels |= MODEL_WORLD_ACTIVE;
		}
	}
	
	if (bitsActiveModels & (MODEL_VIEW_ACTIVE | MODEL_WORLD_ACTIVE)) {
		// custom view- / world- model positioning options
		KeyValues attrKv = TF2CustAttr_GetAttributeKeyValues(weapon);
		if (attrKv) {
			if (bitsActiveModels & MODEL_VIEW_ACTIVE
					&& attrKv.JumpToKey("viewmodel override offset")) {
				int weaponvm = EntRefToEntIndex(g_iLastViewmodelRef[client]);
					if (weaponvm == INVALID_ENT_REFERENCE || !IsValidEntity(weaponvm)) {
						attrKv.GoBack();
						delete attrKv;
						return;
					}
				
				int weapomvm_effects = GetEntProp(weaponvm, Prop_Send, "m_fEffects");
				weapomvm_effects &= ~EF_BONEMERGE;
				SetEntProp(weaponvm, Prop_Send, "m_fEffects", weapomvm_effects);
				
				SetVariantString("!activator");
				AcceptEntityInput(weaponvm, "SetParent", weapon);
				
				SetVariantString("weapon_bone");
				AcceptEntityInput(weaponvm, "SetParentAttachment");
				
				float posOffset[3];
				attrKv.GetVector("pos", posOffset);
				SetEntPropVector(weaponvm, Prop_Send, "m_vecOrigin", posOffset);
				
				float angOffset[3];
				attrKv.GetVector("ang", angOffset);
				SetEntPropVector(weaponvm, Prop_Send, "m_angRotation", angOffset);
				
				float modelScale = attrKv.GetFloat("scale", 1.0);
				SetEntPropFloat(weaponvm, Prop_Send, "m_flModelScale", modelScale);
				
				attrKv.GoBack();
			}
			if (bitsActiveModels & MODEL_WORLD_ACTIVE
					&& attrKv.JumpToKey("worldmodel override offset")) {
				int weaponwm = EntRefToEntIndex(g_iLastWorldModelRef[client]);
					if (weaponwm == INVALID_ENT_REFERENCE || !IsValidEntity(weaponwm)) {
						attrKv.GoBack();
						delete attrKv;
						return;
					}
				
				int weaponwm_effects = GetEntProp(weaponwm, Prop_Send, "m_fEffects");
				weaponwm_effects &= ~EF_BONEMERGE;
				SetEntProp(weaponwm, Prop_Send, "m_fEffects", weaponwm_effects);
				
				SetVariantString("!activator");
				AcceptEntityInput(weaponwm, "SetParent", weapon);
				
				SetVariantString("weapon_bone");
				AcceptEntityInput(weaponwm, "SetParentAttachment");
				
				float posOffset[3];
				attrKv.GetVector("pos", posOffset);
				SetEntPropVector(weaponwm, Prop_Send, "m_vecOrigin", posOffset);
				
				float angOffset[3];
				attrKv.GetVector("ang", angOffset);
				SetEntPropVector(weaponwm, Prop_Send, "m_angRotation", angOffset);
				
				float modelScale = attrKv.GetFloat("scale", 1.0);
				SetEntPropFloat(weaponwm, Prop_Send, "m_flModelScale", modelScale);
				
				attrKv.GoBack();
			}
			delete attrKv;
		}
	}
	
	if (TF2_GetPlayerClass(client) == TFClass_DemoMan) {
		// display shield if player has their melee weapon out on demoman
		int shield = TF2Util_GetPlayerLoadoutEntity(client, 1);
		char ohvm[PLATFORM_MAX_PATH];
		if (IsValidEntity(shield) && TF2Util_IsEntityWearable(shield)
				&& TF2CustAttr_GetString(shield, "clientmodel override", ohvm, sizeof(ohvm))
				&& FileExistsAndLog(ohvm, true)) {
			PrecacheModelAndLog(ohvm);
			SetEntityModel(shield, ohvm);
			CWX_MarkValidatedAttachedEntity(shield, client, "demoman_shield", true, weapon);
			
			if (TF2Util_IsEntityWeapon(weapon)
					&& TF2Util_GetWeaponSlot(weapon) == TFWeaponSlot_Melee) {
				int offhandwearable = TF2_SpawnWearableViewmodel();
				if (IsValidEntity(offhandwearable)) {
					SetEntityModel(offhandwearable, ohvm);
					
					TF2Util_EquipPlayerWearable(client, offhandwearable);
					CWX_MarkValidatedAttachedEntity(offhandwearable, client, "demoman_offhand_vm", true, weapon);
					g_iLastOffHandViewmodelRef[client] = EntIndexToEntRef(offhandwearable);
					
					bitsActiveModels |= MODEL_OFFHAND_ACTIVE;
				}
			}
		}
	}
	
	char armvmPath[PLATFORM_MAX_PATH];
	if (!TF2CustAttr_GetString(weapon, "arm model override", armvmPath, sizeof(armvmPath))
			&& bitsActiveModels & (MODEL_VIEW_ACTIVE | MODEL_OFFHAND_ACTIVE | MODEL_WORLD_ACTIVE) == 0) {
		// we need to attach arm viewmodels if we render a new weapon viewmodel
		// or if we have something attached to our offhand
		// ... or if we have a new worldmodel as of the 2021-06-22 update
		// ... or if we are using a custom arm model
		return;
	}
	
	if ((armvmPath[0] || GetArmViewModel(client, armvmPath, sizeof(armvmPath)))
			&& FileExistsAndLog(armvmPath, true)) {
		// armvmPath might not be precached on the server
		// mainly an issue with the gunslinger variation of the arm model for stock
		PrecacheModelAndLog(armvmPath);
		
		int armvm = TF2_SpawnWearableViewmodel();
		if (!IsValidEntity(armvm)) {
			return;
		}
		
		SetEntityModel(armvm, armvmPath);
		TF2Util_EquipPlayerWearable(client, armvm);
		CWX_MarkValidatedAttachedEntity(armvm, client, "arm_viewmodel", true, weapon);
		
		g_iLastArmModelRef[client] = EntIndexToEntRef(armvm);
		
		int clientView = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (IsValidEntity(clientView)) {
			SetEntProp(clientView, Prop_Send, "m_fEffects", EF_NODRAW);
		}
		
		bitsActiveModels |= MODEL_ARM_ACTIVE;
		
		if (bitsActiveModels & MODEL_VIEW_ACTIVE == 0) {
			// we didn't create a custom weapon viewmodel, so we need to render the original one
			// for that weapon
			int itemdef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
			
			if (!TF2Econ_GetItemDefinitionString(itemdef, "model_player", vm, sizeof(vm))) {
				return;
			}
			
			PrecacheModelAndLog(vm);
			
			int weaponvm = TF2_SpawnWearableViewmodel();
			if (IsValidEntity(weaponvm)) {
				SetEntityModel(weaponvm, vm);
				CopyKillstreakSheen(weapon, weaponvm);
				TF2Util_EquipPlayerWearable(client, weaponvm);
				CWX_MarkValidatedAttachedEntity(weaponvm, client, "fallback_weapon_viewmodel", true, weapon);
				
				g_iLastViewmodelRef[client] = EntIndexToEntRef(weaponvm);
				
				bitsActiveModels |= MODEL_VIEW_ACTIVE;
			}
		}
	}
}

void VMO_OnWearableSpawnPost(int wearable) {
	CreateTimer(0.1, Timer_DelayedWearableSpawnUpdate, EntIndexToEntRef(wearable), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_DelayedWearableSpawnUpdate(Handle timer, any wearableRef) {
	int wearable = EntRefToEntIndex(wearableRef);
	if (!IsValidEntity(wearable) || !TF2Util_IsEntityWearable(wearable)) {
		return Plugin_Stop;
	}

	char model[PLATFORM_MAX_PATH];
	if (!GetEntityClientModelOverride(wearable, model, sizeof(model))) {
		return Plugin_Stop;
	}

	ApplyWearableModelOverride(wearable, model);

	int owner = GetEntityOwner(wearable);
	if (IsValidViewmodelClient(owner)) {
		ScheduleClientModelUpdate(owner, 0.1);
	}
	return Plugin_Stop;
}

void UpdateClientWearableModels(int client) {
	int count = TF2Util_GetPlayerWearableCount(client);
	for (int i = 0; i < count; i++) {
		int wearable = TF2Util_GetPlayerWearable(client, i);
		if (!IsValidEntity(wearable)) {
			continue;
		}

		char model[PLATFORM_MAX_PATH];
		if (GetEntityClientModelOverride(wearable, model, sizeof(model))) {
			ApplyWearableModelOverride(wearable, model);
		} else if (GetExtraWearableModelOverride(client, wearable, model, sizeof(model))) {
			ApplyWearableModelOverride(wearable, model);
		}
	}
}

bool GetEntityClientModelOverride(int entity, char[] model, int maxlen) {
	return TF2CustAttr_GetString(entity, "clientmodel override", model, maxlen)
			|| TF2CustAttr_GetString(entity, "worldmodel override", model, maxlen);
}

bool GetExtraWearableModelOverride(int client, int wearable, char[] model, int maxlen) {
	int wearableDefIndex = GetEntityItemDefinitionIndex(wearable);
	if (wearableDefIndex <= 0) {
		return false;
	}

	int activeWeapon = TF2_GetClientActiveWeapon(client);
	if (TryGetExtraWearableModelOverrideFromEntity(activeWeapon, wearableDefIndex, model, maxlen)) {
		return true;
	}

	for (int slot = 0; slot < 7; slot++) {
		int loadoutEntity = TF2Util_GetPlayerLoadoutEntity(client, slot);
		if (TryGetExtraWearableModelOverrideFromEntity(loadoutEntity, wearableDefIndex, model, maxlen)) {
			return true;
		}
	}

	for (int slot = 0; slot <= 5; slot++) {
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (TryGetExtraWearableModelOverrideFromEntity(weapon, wearableDefIndex, model, maxlen)) {
			return true;
		}
	}

	return false;
}

bool TryGetExtraWearableModelOverrideFromEntity(int entity, int wearableDefIndex, char[] model, int maxlen) {
	if (!IsValidEntity(entity)) {
		return false;
	}

	char overrideModel[PLATFORM_MAX_PATH];
	if (!TF2CustAttr_GetString(entity, ATTR_EXTRA_WEARABLE_MODEL_OVERRIDE, overrideModel, sizeof(overrideModel))) {
		return false;
	}

	int entityDefIndex = GetEntityItemDefinitionIndex(entity);
	if (entityDefIndex != wearableDefIndex && !ItemDefsShareDefaultLoadoutSlot(entityDefIndex, wearableDefIndex)) {
		return false;
	}

	strcopy(model, maxlen, overrideModel);
	return true;
}

bool ItemDefsShareDefaultLoadoutSlot(int firstDefIndex, int secondDefIndex) {
	if (firstDefIndex <= 0 || secondDefIndex <= 0) {
		return false;
	}

	int firstSlot = TF2Econ_GetItemDefaultLoadoutSlot(firstDefIndex);
	int secondSlot = TF2Econ_GetItemDefaultLoadoutSlot(secondDefIndex);
	return firstSlot != -1 && firstSlot == secondSlot;
}

int GetEntityItemDefinitionIndex(int entity) {
	if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_iItemDefinitionIndex")) {
		return -1;
	}
	return GetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex");
}

bool ApplyWearableModelOverride(int wearable, const char[] model) {
	if (!IsValidEntity(wearable) || !TF2Util_IsEntityWearable(wearable)) {
		return false;
	}

	if (!FileExistsAndLog(model, true)) {
		return false;
	}

	PrecacheModelAndLog(model);
	SetEntityModel(wearable, model);
	CWX_MarkValidatedAttachedEntity(wearable, GetEntityOwner(wearable),
		"wearable_model_override", true, wearable);
	return true;
}

bool ClientWeaponModelNeedsRefresh(int client) {
	int weapon = TF2_GetClientActiveWeapon(client);
	if (!IsValidEntity(weapon)) {
		return false;
	}

	if (g_iAppliedWeaponRef[client] != EntIndexToEntRef(weapon)) {
		return true;
	}

	char vm[PLATFORM_MAX_PATH];
	char wm[PLATFORM_MAX_PATH];
	bool hasViewOverride;
	bool hasWorldOverride;
	if (!GetWeaponOverrideModels(weapon, vm, sizeof(vm), wm, sizeof(wm), hasViewOverride, hasWorldOverride)) {
		return HasValidEntRef(g_iLastViewmodelRef[client])
				|| HasValidEntRef(g_iLastArmModelRef[client])
				|| HasValidEntRef(g_iLastWorldModelRef[client])
				|| HasValidEntRef(g_iLastOffHandViewmodelRef[client]);
	}

	if ((hasViewOverride || hasWorldOverride) && !OriginalViewmodelHidden(client)) {
		return true;
	}

	if ((hasViewOverride || hasWorldOverride) && !HasValidEntRef(g_iLastArmModelRef[client])) {
		return true;
	}

	if (hasViewOverride && !EntityRefHasModel(g_iLastViewmodelRef[client], vm)) {
		return true;
	}

	if (hasWorldOverride && !EntityRefHasModel(g_iLastWorldModelRef[client], wm)) {
		return true;
	}

	return false;
}

bool GetWeaponOverrideModels(int weapon, char[] vm, int vmLen, char[] wm, int wmLen, bool &hasViewOverride, bool &hasWorldOverride) {
	hasViewOverride = false;
	hasWorldOverride = false;
	if (!IsValidEntity(weapon)) {
		return false;
	}

	char cm[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(weapon, "clientmodel override", cm, sizeof(cm));

	hasViewOverride = TF2CustAttr_GetString(weapon, "viewmodel override", vm, vmLen, cm) > 0
			&& FileExistsAndLog(vm, true);
	hasWorldOverride = TF2CustAttr_GetString(weapon, "worldmodel override", wm, wmLen, cm) > 0
			&& FileExistsAndLog(wm, true);
	return hasViewOverride || hasWorldOverride;
}

bool HasValidEntRef(int entityRef) {
	int entity = EntRefToEntIndex(entityRef);
	return entity != INVALID_ENT_REFERENCE && IsValidEntity(entity);
}

bool EntityRefHasModel(int entityRef, const char[] expectedModel) {
	int entity = EntRefToEntIndex(entityRef);
	if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity) || !expectedModel[0]) {
		return false;
	}

	if (HasEntProp(entity, Prop_Data, "m_ModelName")) {
		char currentModel[PLATFORM_MAX_PATH];
		GetEntPropString(entity, Prop_Data, "m_ModelName", currentModel, sizeof(currentModel));
		if (StrEqual(currentModel, expectedModel, false)) {
			return true;
		}
	}

	if (!HasEntProp(entity, Prop_Send, "m_nModelIndex")) {
		return false;
	}

	int expectedModelIndex = PrecacheModelAndLog(expectedModel);
	return expectedModelIndex > 0
			&& GetEntProp(entity, Prop_Send, "m_nModelIndex") == expectedModelIndex;
}

bool OriginalViewmodelHidden(int client) {
	int clientView = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (!IsValidEntity(clientView)) {
		return true;
	}
	return (GetEntProp(clientView, Prop_Send, "m_fEffects") & EF_NODRAW) != 0;
}

int GetEntityOwner(int entity) {
	if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_hOwnerEntity")) {
		return 0;
	}
	return GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
}

/**
 * Destroys wearable worldmodels on death so ragdolls aren't holding them.
 */
void VMO_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client) {
		DetachVMs(client);
	}
}

/**
 * Allows the use of custom models on sappers attached to buildings.
 */
void VMO_OnObjectSappedPost(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidEntity(client)) {
		return;
	}
	
	int sapper = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);
	if (!IsValidEntity(sapper)) {
		return;
	}
	
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(sapper, "clientmodel override", wm, sizeof(wm))
			|| TF2CustAttr_GetString(sapper, "worldmodel override", wm, sizeof(wm))) {
		int attachedSapper = event.GetInt("sapperid");
		if (SetAttachedSapperModel(attachedSapper, wm)) {
			CWX_MarkValidatedAttachedEntity(attachedSapper, client, "attached_sapper", true, sapper);
		}
	}
}

bool SetWeaponWorldModel(int weapon, const char[] worldmodel) {
	if (!FileExists(worldmodel, true)) {
		return false;
	}
	
	int model = PrecacheModelAndLog(worldmodel);
	if (HasEntProp(weapon, Prop_Send, "m_iWorldModelIndex")) {
		SetEntProp(weapon, Prop_Send, "m_iWorldModelIndex", model);
	}
	
	/**
	 * setting m_nModelIndexOverrides causes firing animations to break, but prevents the
	 * weapon from showing up with the overwritten model in taunts
	 * 
	 * to display the overwritten world model on dropped items see OnDroppedWeaponSpawnPost
	 */
	for (int i = 1; i < GetEntPropArraySize(weapon, Prop_Send, "m_nModelIndexOverrides"); i++) {
		// SetEntProp(weapon, Prop_Send, "m_nModelIndexOverrides", model, .element = i);
	}
	return true;
}

/**
 * Sets the model on the given building-attached sapper.
 */
bool SetAttachedSapperModel(int sapper, const char[] worldmodel) {
	if (!FileExists(worldmodel, true)) {
		return false;
	}
	SetEntityModel(sapper, worldmodel);
	return true;
}

/**
 * Detaches any custom viewmodels on the client and displays the original viewmodel.
 */
void DetachVMs(int client) {
	if (!IsValidViewmodelClient(client)) {
		ResetClientModelRefs(client);
		return;
	}
	g_iAppliedWeaponRef[client] = INVALID_ENT_REFERENCE;

	MaybeRemoveWearable(client, g_iLastViewmodelRef[client]);
	g_iLastViewmodelRef[client] = INVALID_ENT_REFERENCE;
	MaybeRemoveWearable(client, g_iLastArmModelRef[client]);
	g_iLastArmModelRef[client] = INVALID_ENT_REFERENCE;
	
	MaybeRemoveWearable(client, g_iLastWorldModelRef[client]);
	RestoreHiddenWorldWeapon(client);
	g_iLastWorldModelRef[client] = INVALID_ENT_REFERENCE;
	
	MaybeRemoveWearable(client, g_iLastOffHandViewmodelRef[client]);
	g_iLastOffHandViewmodelRef[client] = INVALID_ENT_REFERENCE;
	
	int clientView = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (IsValidEntity(clientView)) {
		int effects = GetEntProp(clientView, Prop_Send, "m_fEffects");
		SetEntProp(clientView, Prop_Send, "m_fEffects", effects & ~EF_NODRAW);
	}
}

void RestoreHiddenWorldWeapon(int client) {
	int hiddenWeapon = EntRefToEntIndex(g_iLastHiddenWorldWeaponRef[client]);
	if (IsValidEntity(hiddenWeapon)) {
		SetEntityRenderMode(hiddenWeapon, RENDER_NORMAL);
		SetEntityRenderColor(hiddenWeapon, 255, 255, 255, 255);
	}
	g_iLastHiddenWorldWeaponRef[client] = INVALID_ENT_REFERENCE;
}

/**
 * Returns the arm viewmodel appropriate for the given player.
 */
int GetArmViewModel(int client, char[] buffer, int maxlen) {
	static char armModels[TFClassType][] = {
		"",
		"models/weapons/c_models/c_scout_arms.mdl",
		"models/weapons/c_models/c_sniper_arms.mdl",
		"models/weapons/c_models/c_soldier_arms.mdl",
		"models/weapons/c_models/c_demo_arms.mdl",
		"models/weapons/c_models/c_medic_arms.mdl",
		"models/weapons/c_models/c_heavy_arms.mdl",
		"models/weapons/c_models/c_pyro_arms.mdl",
		"models/weapons/c_models/c_spy_arms.mdl",
		"models/weapons/c_models/c_engineer_arms.mdl"
	};
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	// special case kludge: use gunslinger vm if gunslinger is active on engineer
	if (playerClass == TFClass_Engineer) {
		int meleeWeapon = GetPlayerWeaponSlot(client, TFWeaponSlot_Melee);
		if (IsValidEntity(meleeWeapon)
				&& TF2_GetItemDefinitionIndex(meleeWeapon) == TF_ITEM_DEFINDEX_GUNSLINGER) {
			return strcopy(buffer, maxlen, "models/weapons/c_models/c_engineer_gunslinger.mdl");
		}
	}
	
	return strcopy(buffer, maxlen, armModels[ view_as<int>(playerClass) ]);
}

bool IsValidViewmodelClient(int client) {
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

void ResetClientModelRefs(int client) {
	g_iLastViewmodelRef[client] = INVALID_ENT_REFERENCE;
	g_iLastArmModelRef[client] = INVALID_ENT_REFERENCE;
	g_iLastWorldModelRef[client] = INVALID_ENT_REFERENCE;
	g_iLastHiddenWorldWeaponRef[client] = INVALID_ENT_REFERENCE;
	g_iLastOffHandViewmodelRef[client] = INVALID_ENT_REFERENCE;
	g_iAppliedWeaponRef[client] = INVALID_ENT_REFERENCE;
	g_bIgnoreWeaponSwitch[client] = false;
}

bool MaybeRemoveWearable(int client, int wearableRef) {
	int wearable = EntRefToEntIndex(wearableRef);
	if (wearable != INVALID_ENT_REFERENCE && IsValidEntity(wearable)) {
		TF2_RemoveWearable(client, wearable);
		RemoveEntity(wearable);
		return true;
	}
	return false;
}

/**
 * Creates a wearable viewmodel.
 * This sets EF_BONEMERGE | EF_BONEMERGE_FASTCULL when equipped.
 */
stock int TF2_SpawnWearableViewmodel() {
	if (!CanCreateOverrideWearable()) {
		return -1;
	}

	int wearable = CreateEntityByName("tf_wearable_vm");
	
	if (IsValidEntity(wearable)) {
		SetEntProp(wearable, Prop_Send, "m_iItemDefinitionIndex", DEFINDEX_UNDEFINED);
		DispatchSpawn(wearable);
		CWX_MarkValidatedAttachedEntity(wearable, 0, "spawn_wearable_vm");
	}
	return wearable;
}

bool CanCreateOverrideWearable() {
	if (g_cvEdictReserve == null) {
		return true;
	}

	int reserve = g_cvEdictReserve.IntValue;
	int freeEdicts = GetMaxEntities() - GetEntityCount();
	if (reserve > 0 && freeEdicts <= reserve) {
		if (!g_bLoggedEdictReserve) {
			LogError("Skipping model-override wearable: only %d free edicts (reserve %d)",
					freeEdicts, reserve);
			g_bLoggedEdictReserve = true;
		}
		return false;
	}

	return true;
}

void ResetModelAvailabilityCache() {
	delete g_ModelAvailabilityCache;
	g_ModelAvailabilityCache = new StringMap();
}

bool FileExistsAndLog(const char[] path, bool use_valve_fs = false,
		const char[] valve_path_id = "GAME") {
	ModelAvailability availability = ModelAvailability_Unknown;
	
	if (g_ModelAvailabilityCache.GetValue(path, availability)) {
		return availability == ModelAvailability_Found;
	}
	
	if (FileExists(path, use_valve_fs, valve_path_id)) {
		g_ModelAvailabilityCache.SetValue(path, ModelAvailability_Found);
		return true;
	}
	
	LogError("Missing file '%s'", path);
	g_ModelAvailabilityCache.SetValue(path, ModelAvailability_NotFound);
	return false;
}

int PrecacheModelAndLog(const char[] model, bool preload = false) {
	int modelIndex = PrecacheModel(model, preload);
	if (!modelIndex) {
		LogError("Failed to precache model '%s'", model);
	}
	return modelIndex;
}
