/**
 * Contains functionality for the item config.
 */

#include <stocksoup/files>

enum struct CustomItemDefinition {
	KeyValues source;
	
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	int defindex;
	char displayName[128];
	char descriptionPositive[MAX_ITEM_DESCRIPTION_LENGTH];
	char descriptionNeutral[MAX_ITEM_DESCRIPTION_LENGTH];
	char descriptionNegative[MAX_ITEM_DESCRIPTION_LENGTH];
	KeyValues localizedNames;
	char className[128];
	int loadoutPosition[NUM_PLAYER_CLASSES];
	
	char access[64];
	char pointsStorePurchase[64];
	
	KeyValues nativeAttributes;
	KeyValues customAttributes;
	
	bool bKeepStaticAttributes;
	bool reskinOnly;
	
	void Init() {
		this.defindex = TF_ITEMDEF_DEFAULT;
		this.source = new KeyValues("Item");
		for (int i; i < sizeof(CustomItemDefinition::loadoutPosition); i++) {
			this.loadoutPosition[i] = -1;
		}
	}
	
	void Destroy() {
		delete this.source;
		delete this.nativeAttributes;
		delete this.customAttributes;
		delete this.localizedNames;
	}
	
	/**
	 * If one exists, returns a copy of the contents of a named "extdata" subsection for the
	 * item.  Returns null otherwise.
	 */
	KeyValues GetExtData(const char[] name) {
		if (!this.source.JumpToKey("extdata", false)) {
			return null;
		}
		
		KeyValues result;
		if (this.source.JumpToKey(name, false)) {
			result = new KeyValues(name);
			result.Import(this.source);
			this.source.GoBack();
		}
		this.source.GoBack();
		return result;
	}
}

/**
 * Holds a uid to CustomItemDefinition mapping.
 */
static StringMap g_CustomItems;

KeyValues CwxConfig_Open(char[] configPath, int configPathLen) {
	BuildPath(Path_SM, configPath, configPathLen, CWX_CONFIG_PATH);

	KeyValues config = new KeyValues(CWX_CONFIG_ROOT);
	if (!config.ImportFromFile(configPath)) {
		LogError("Failed to load custom weapons from %s", configPath);
		delete config;
		return null;
	}
	return config;
}

void LoadCustomItemConfig() {
	KeyValues itemSchema = new KeyValues(CWX_CONFIG_ITEM_SECTION);

	char schemaPath[PLATFORM_MAX_PATH];
	KeyValues weaponsConfig = CwxConfig_Open(schemaPath, sizeof(schemaPath));
	if (weaponsConfig != null) {
		CwxSound_LoadConfig(weaponsConfig, schemaPath);

		if (!weaponsConfig.JumpToKey(CWX_CONFIG_ITEM_SECTION, false)) {
			LogError("No %s section found in %s", CWX_CONFIG_ITEM_SECTION, schemaPath);
		} else {
			itemSchema.Import(weaponsConfig);
			weaponsConfig.GoBack();
		}
	} else {
		CwxSound_Clear();
	}
	delete weaponsConfig;
	
	// clean up old items
	if (g_CustomItems) {
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		
		StringMapSnapshot itemList = GetCustomItemList();
		for (int i; i < itemList.Length; i++) {
			itemList.GetKey(i, uid, sizeof(uid));
			
			CustomItemDefinition item;
			GetCustomItemDefinition(uid, item);
			
			item.Destroy();
		}
		delete itemList;
	}
	
	delete g_CustomItems;
	g_CustomItems = new StringMap();
	
	if (itemSchema.GotoFirstSubKey()) {
		// we have items, go parse 'em
		do {
			CreateItemFromSection(itemSchema);
		} while (itemSchema.GotoNextKey());
		itemSchema.GoBack();
		
		BuildEquipMenu();
	} else {
		LogError("No custom items available.");
	}
	delete itemSchema;
	
	// TODO process other config logic here.
}

void ReadItemDescription(KeyValues config, CustomItemDefinition item) {
	item.descriptionPositive[0] = '\0';
	item.descriptionNeutral[0] = '\0';
	item.descriptionNegative[0] = '\0';

	if (config.GetDataType("description") == KvData_None
			&& config.JumpToKey("description", false)) {
		config.GetString("positive", item.descriptionPositive, sizeof(item.descriptionPositive), "");
		config.GetString("neutral", item.descriptionNeutral, sizeof(item.descriptionNeutral), "");
		config.GetString("negative", item.descriptionNegative, sizeof(item.descriptionNegative), "");
		config.GoBack();
		return;
	}

	config.GetString("description", item.descriptionPositive, sizeof(item.descriptionPositive), "");
}

bool CreateItemFromSection(KeyValues config) {
	CustomItemDefinition item;
	item.Init();
	
	item.source.Import(config);
	
	config.GetSectionName(item.uid, sizeof(item.uid));
	
	config.GetString("name", item.displayName, sizeof(item.displayName));
	ReadItemDescription(config, item);
	
	char inheritFromItem[64];
	config.GetString("inherits", inheritFromItem, sizeof(inheritFromItem));
	int inheritDef = FindItemByName(inheritFromItem);
	
	// populate values for the 'inherit' entry, if any
	if (inheritDef != TF_ITEMDEF_DEFAULT) {
		item.defindex = inheritDef;
		TF2Econ_GetItemClassName(inheritDef, item.className, sizeof(item.className));
	} else if (inheritFromItem[0]) {
		LogError("Item uid '%s' inherits from unknown item '%s'", item.uid, inheritFromItem);
		item.Destroy();
		return false;
	}
	
	// apply inherited overrides
	item.defindex = config.GetNum("defindex", item.defindex);
	config.GetString("item_class", item.className, sizeof(item.className), item.className);
	
	if (!item.className[0]) {
		LogError("Item uid '%s' has no classname", item.uid);
		item.Destroy();
		return false;
	}
	
	if (item.defindex == TF_ITEMDEF_DEFAULT) {
		LogError("Item uid '%s' has no item definition", item.uid);
		item.Destroy();
		return false;
	}
	
	// compute slots based on inherited itemdef if we have it, else defindex
	ComputeEquipSlotPosition(config,
			inheritDef == TF_ITEMDEF_DEFAULT? item.defindex : inheritDef, item.loadoutPosition);
	
	config.GetString("item_class", item.className, sizeof(item.className), item.className);
	
	item.bKeepStaticAttributes = !!config.GetNum("keep_static_attrs", true);

	char reskinOnly[8];
	config.GetString("reskin_only", reskinOnly, sizeof(reskinOnly), "false");
	item.reskinOnly = StrEqual(reskinOnly, "true", false) || StringToInt(reskinOnly) != 0;
	
	// allows restricting access to the item
	config.GetString("access", item.access, sizeof(item.access));
	config.GetString("points_store_purchase",
			item.pointsStorePurchase, sizeof(item.pointsStorePurchase));
	
	if (config.JumpToKey("attributes_game")) {
		// validate that the attributes actually exist
		// we don't throw a complete failure here since it can be injected later
		if (config.GotoFirstSubKey(false)) {
			do {
				char key[256];
				config.GetSectionName(key, sizeof(key));
				
				if (TF2Econ_TranslateAttributeNameToDefinitionIndex(key) == -1) {
					LogError("Item uid '%s' references non-existent attribute '%s'", item.uid, key);
				}
			} while (config.GotoNextKey(false));
			config.GoBack();
		}
		
		item.nativeAttributes = new KeyValues("attributes_game");
		item.nativeAttributes.Import(config);
		
		config.GoBack();
	}

	if (!item.nativeAttributes) {
		item.nativeAttributes = new KeyValues("attributes_game");
	}
	if (item.nativeAttributes.GetDataType("killstreak tier") == KvData_None) {
		item.nativeAttributes.SetString("killstreak tier", "1");
	}
	
	if (config.JumpToKey("attributes_custom")) {
		item.customAttributes = new KeyValues("attributes_custom");
		item.customAttributes.Import(config);
		config.GoBack();
	}
	CwxModels_PrecacheItemAssets(item.customAttributes);
	CwxSound_ValidateItemConfig(item.uid, item.customAttributes);
	
	if (config.JumpToKey("localized_name")) {
		item.localizedNames = new KeyValues("localized_name");
		item.localizedNames.Import(config);
		config.GoBack();
	}
	
	g_CustomItems.SetArray(item.uid, item, sizeof(item));
	return true;
}

bool GetCustomItemDefinition(const char[] uid, CustomItemDefinition item) {
	return g_CustomItems.GetArray(uid, item, sizeof(item));
}

StringMapSnapshot GetCustomItemList() {
	return g_CustomItems.Snapshot();
}

bool CustomItemsLoaded() {
	return g_CustomItems != null;
}

/**
 * Builds the loadout position array for the item, so the plugin knows which weapons can be
 * rendered in loadout menus and which loadout slot they will be stored in within the database.
 */
static bool ComputeEquipSlotPosition(KeyValues kv, int itemdef,
		int loadoutPosition[NUM_PLAYER_CLASSES]) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	kv.GetSectionName(uid, sizeof(uid));
	
	if (kv.JumpToKey("used_by_classes")) {
		char playerClassNames[][] = {
				"", "scout", "sniper", "soldier", "demoman",
				"medic", "heavy", "pyro", "spy", "engineer"
		};
		
		for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
			char slotName[16];
			kv.GetString(playerClassNames[i], slotName, sizeof(slotName));
			loadoutPosition[i] = TF2Econ_TranslateLoadoutSlotNameToIndex(slotName);
		}
		
		kv.GoBack();
		return true;
	}
	
	if (!TF2Econ_IsValidItemDefinition(itemdef)) {
		LogError("Item uid '%s' is missing a valid item definition index or 'inherits' item "
				... "name is invalid", uid);
		return false;
	}
	
	for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
		loadoutPosition[i] = TF2Econ_GetItemLoadoutSlot(itemdef, i);
	}
	return true;
}

/**
 * Equips an item from the given CustomItemDefinition instance.
 * Returns the item entity if successful.
 */
int EquipCustomItem(int client, const CustomItemDefinition item) {
	char itemClass[128];
	
	strcopy(itemClass, sizeof(itemClass), item.className);
	TF2Econ_TranslateWeaponEntForClass(itemClass, sizeof(itemClass),
			TF2_GetPlayerClass(client));
	
	// create our item
	int itemEntity = TF2_CreateItem(item.defindex, itemClass);
	
	if (!IsFakeClient(client)) {
		// prevent item from being thrown in resupply
		int accountid = GetSteamAccountID(client);
		if (accountid) {
			SetEntProp(itemEntity, Prop_Send, "m_iAccountID", accountid);
		}
	}
	
	// TODO: implement a version that nullifies runtime attributes to their defaults
	SetEntProp(itemEntity, Prop_Send, "m_bOnlyIterateItemViewAttributes",
			!item.bKeepStaticAttributes);
	
	ApplyCustomItemNativeAttributes(itemEntity, item);
	
	// add a stinky attribute that holds the item's uid
	// this value is read with CWX_GetItemUIDFromEntity
	TF2Attrib_SetFromStringValue(itemEntity, ATTRIB_NAME_CUSTOM_UID, item.uid);
	
	// apply attributes for Custom Attributes
	if (item.customAttributes) {
		TF2CustAttr_UseKeyValues(itemEntity, item.customAttributes);
	}
	CWX_ApplyEngineOverrides(itemEntity);
	
	// HACK: the stock builder and sapper needs additional fixups
	// https://github.com/ValveSoftware/source-sdk-2013/blob/0565403b153dfcde602f6f58d8f4d13483696a13/src/game/server/tf/tf_player.cpp#L4306-L4315
	// https://github.com/gemidyne/microtf2/blob/5c4355e5257c09929d1663dcf767173600cd6e1d/src/scripting/Weapons.sp#L99-L113
	if (StrEqual(itemClass, "tf_weapon_sapper")) {
		SetEntProp(itemEntity, Prop_Data, "m_iSubType", 3);
		SetEntProp(itemEntity, Prop_Send, "m_iObjectType", 3);
		SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 0);
		SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 1);
		SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 2);
		SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 1, .element = 3);
	} else if (StrEqual(itemClass, "tf_weapon_builder")) {
		if (item.defindex == 735) {
			SetEntProp(itemEntity, Prop_Data, "m_iSubType", 3);
			SetEntProp(itemEntity, Prop_Send, "m_iObjectType", 3);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 0);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 1);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 2);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 1, .element = 3);
		} else {
			// Stock engineer will be reset "m_iObjectType" to -1(OBJ_ANY)
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 1, .element = 0);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 1, .element = 1);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 1, .element = 2);
			SetEntProp(itemEntity, Prop_Send, "m_aBuildableObjectTypes", 0, .element = 3);
		}
	}
	
	// remove existing item(s) on player
	bool bRemovedWeaponInSlot;
	if (TF2Util_IsEntityWeapon(itemEntity)) {
		// replace item by slot for cross-class equip compatibility
		int weaponSlot = TF2Util_GetWeaponSlot(itemEntity);
		bRemovedWeaponInSlot = IsValidEntity(GetPlayerWeaponSlot(client, weaponSlot));
		TF2_RemoveWeaponSlot(client, weaponSlot);
		
		/**
		 * ::Spawn calls ::Precache, which is where mod_use_metal_ammo_type takes effect.
		 * 
		 * Calling this a second time (after TF2_CreateItem) may have side effects that I'm not
		 * aware of, but we'll burn that bridge when we cross it.
		 */
		DispatchSpawn(itemEntity);
		CWX_MarkValidatedAttachedEntity(itemEntity, client, "custom_weapon_second_spawn", false);
	}

	/*
	 * Weapons are spawned a second time above.  Normally the runtime custom-attribute
	 * storage survives, but make that an invariant before EquipPlayerWeapon fires so
	 * the CWX model pipeline always observes the final entity state.
	 */
	EnsureCustomItemRuntimeAttributes(itemEntity, item, client, "equip");
	
	// we didn't remove a weapon by its weapon slot; remove item based on loadout slot
	if (!bRemovedWeaponInSlot) {
		int loadoutSlot = item.loadoutPosition[TF2_GetPlayerClass(client)];
		if (loadoutSlot == -1) {
			loadoutSlot = TF2Econ_GetItemDefaultLoadoutSlot(item.defindex);
			if (loadoutSlot == -1) {
				return INVALID_ENT_REFERENCE;
			}
		}
		
		// HACK: remove the correct item for demoman when applying the revolver
		if (TF2Util_IsEntityWeapon(itemEntity)
				&& TF2Econ_GetItemLoadoutSlot(item.defindex, TF2_GetPlayerClass(client)) == -1) {
			loadoutSlot = TF2Util_GetWeaponSlot(itemEntity);
		}
		
		TF2_RemoveItemByLoadoutSlot(client, loadoutSlot);
	}
	TF2_EquipPlayerEconItem(client, itemEntity);
	CWX_NotifyItemRuntimeStateReady(client, itemEntity);
	return itemEntity;
}

static bool ApplyCustomItemNativeAttributes(int itemEntity,
		const CustomItemDefinition item) {
	if (!IsValidEntity(itemEntity) || !item.nativeAttributes) {
		return false;
	}

	bool restored;
	if (item.nativeAttributes.GotoFirstSubKey(false)) {
		do {
			char key[256], value[256];
			item.nativeAttributes.GetSectionName(key, sizeof(key));
			item.nativeAttributes.GetString(NULL_STRING, value, sizeof(value));

			if (!TF2Attrib_GetByName(itemEntity, key)) {
				restored = true;
			}
			TF2Attrib_SetFromStringValue(itemEntity, key, value);
		} while (item.nativeAttributes.GotoNextKey(false));
		item.nativeAttributes.GoBack();
	}
	return restored;
}

bool EnsureCustomItemRuntimeAttributes(int itemEntity,
		const CustomItemDefinition item, int client = 0,
		const char[] context = "unknown") {
	if (!IsValidEntity(itemEntity)) {
		return false;
	}

	bool restored = ApplyCustomItemNativeAttributes(itemEntity, item);
	if (!TF2Attrib_GetByName(itemEntity, ATTRIB_NAME_CUSTOM_UID)) {
		TF2Attrib_SetFromStringValue(itemEntity, ATTRIB_NAME_CUSTOM_UID, item.uid);
		restored = true;
	}

	if (item.customAttributes) {
		KeyValues currentAttributes = TF2CustAttr_GetAttributeKeyValues(itemEntity);
		if (!currentAttributes) {
			TF2CustAttr_UseKeyValues(itemEntity, item.customAttributes);
			restored = true;
		}
		delete currentAttributes;
	}

	CWX_ApplyEngineOverrides(itemEntity);

	if (restored) {
		LogMessage("[CWX][RuntimeRepair] context=%s client=%N entity=%d uid=%s",
			context, client, itemEntity, item.uid);
	}
	return restored;
}

/**
 * Returns the item definition index given a name, or TF_ITEMDEF_DEFAULT if not found.
 */
static int FindItemByName(const char[] name) {
	if (!name[0]) {
		return TF_ITEMDEF_DEFAULT;
	}
	
	static StringMap s_ItemDefsByName;
	if (s_ItemDefsByName) {
		int value = TF_ITEMDEF_DEFAULT;
		return s_ItemDefsByName.GetValue(name, value)? value : TF_ITEMDEF_DEFAULT;
	}
	
	s_ItemDefsByName = new StringMap();
	
	ArrayList itemList = TF2Econ_GetItemList();
	char nameBuffer[64];
	for (int i, nItems = itemList.Length; i < nItems; i++) {
		int itemdef = itemList.Get(i);
		TF2Econ_GetItemName(itemdef, nameBuffer, sizeof(nameBuffer));
		s_ItemDefsByName.SetValue(nameBuffer, itemdef);
	}
	delete itemList;
	
	return FindItemByName(name);
}
