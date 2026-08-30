/**
 * Functions related to item entities.
 */

#define Weapons_VALIDATE_DELAY_SHORT 0.1
#define Weapons_VALIDATE_DELAY_LONG 0.5

stock void Weapons_MarkValidatedAttachedEntity(int entity, int client = 0,
		const char[] context = "unknown", bool scheduleChecks = true,
		int sourceEntity = INVALID_ENT_REFERENCE) {
	if (!IsValidEntity(entity)) {
		return;
	}

	if (!HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity")) {
		Weapons_LogValidatedAttachedEntityState("missing_prop", entity, client, sourceEntity, context,
				-1, -1, false);
		return;
	}

	int before = GetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity");
	SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
	int after = GetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity");
	Weapons_LogValidatedAttachedEntityState("set", entity, client, sourceEntity, context,
		before, after, false);

	if (scheduleChecks && (Weapons_ValidateDebugEnabled() || Weapons_ValidationRepairEnabled())) {
		Weapons_QueueValidatedAttachedEntityCheck(entity, client, sourceEntity, context,
			Weapons_VALIDATE_DELAY_SHORT);
		Weapons_QueueValidatedAttachedEntityCheck(entity, client, sourceEntity, context,
			Weapons_VALIDATE_DELAY_LONG);
	}
}

void Weapons_QueueValidatedAttachedEntityCheck(int entity, int client, int sourceEntity,
		const char[] context, float delay) {
	if (!IsValidEntity(entity)) {
		return;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(EntIndexToEntRef(entity));
	pack.WriteCell(Weapons_IsValidClient(client) ? GetClientUserId(client) : 0);
	pack.WriteCell(IsValidEntity(sourceEntity)
		? EntIndexToEntRef(sourceEntity) : INVALID_ENT_REFERENCE);
	pack.WriteString(context);
	CreateTimer(delay, Timer_Weapons_CheckValidatedAttachedEntity, pack, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Weapons_CheckValidatedAttachedEntity(Handle timer, any data) {
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int entityRef = pack.ReadCell();
	int userid = pack.ReadCell();
	int sourceRef = pack.ReadCell();
	char context[64];
	pack.ReadString(context, sizeof(context));
	delete pack;

	int entity = EntRefToEntIndex(entityRef);
	int client = userid ? GetClientOfUserId(userid) : 0;
	int sourceEntity = EntRefToEntIndex(sourceRef);
	if (!IsValidEntity(entity)) {
		if (Weapons_ValidateDebugEnabled()) {
			LogMessage("[Weapons][Validate] phase=entity_gone context=%s ref=%d client=%d",
				context, entityRef, client);
		}
		return Plugin_Stop;
	}

	if (!HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity")) {
		Weapons_LogValidatedAttachedEntityState("missing_prop_delayed", entity, client,
				sourceEntity,
				context, -1, -1, false);
		return Plugin_Stop;
	}

	int before = GetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity");
	int after = before;
	bool repaired = false;
	if (!before && Weapons_ValidationRepairEnabled()) {
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", true);
		after = GetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity");
		repaired = after != 0;
	}

	if (!before) {
		Weapons_LogValidatedAttachedEntityState("dropped", entity, client, sourceEntity, context,
				before, after, repaired);
	} else if (Weapons_ValidateDebugEnabled()) {
		Weapons_LogValidatedAttachedEntityState("retained", entity, client, sourceEntity, context,
				before, after, false);
	}
	return Plugin_Stop;
}

bool Weapons_ValidateDebugEnabled() {
	return sm_weapons_validate_debug != null && sm_weapons_validate_debug.BoolValue;
}

bool Weapons_ValidationRepairEnabled() {
	return sm_weapons_validate_repair == null || sm_weapons_validate_repair.BoolValue;
}

void Weapons_LogValidatedAttachedEntityState(const char[] phase, int entity, int client,
		int sourceEntity, const char[] context, int before, int after, bool repaired) {
	if (!Weapons_ValidateDebugEnabled() && !StrEqual(phase, "dropped")) {
		return;
	}

	char entityClass[64];
	char entityModel[PLATFORM_MAX_PATH];
	int entityDef;
	int owner;
	Weapons_GetEntityDebugInfo(entity, entityClass, sizeof(entityClass), entityModel,
		sizeof(entityModel), entityDef, owner);

	char sourceClass[64];
	char sourceModel[PLATFORM_MAX_PATH];
	int sourceDef;
	int sourceOwner;
	Weapons_GetEntityDebugInfo(sourceEntity, sourceClass, sizeof(sourceClass), sourceModel,
		sizeof(sourceModel), sourceDef, sourceOwner);

	char clientLabel[96];
	Weapons_FormatClientLabel(client, clientLabel, sizeof(clientLabel));
	char ownerLabel[96];
	Weapons_FormatClientLabel(owner, ownerLabel, sizeof(ownerLabel));
	char sourceOwnerLabel[96];
	Weapons_FormatClientLabel(sourceOwner, sourceOwnerLabel, sizeof(sourceOwnerLabel));

	LogMessage("[Weapons][Validate] phase=%s context=%s before=%d after=%d repaired=%d entity=%d class=%s def=%d owner=%s model=\"%s\" client=%s source=%d source_class=%s source_def=%d source_owner=%s source_model=\"%s\" free_edicts=%d",
			phase, context, before, after, repaired ? 1 : 0, entity, entityClass,
			entityDef, ownerLabel, entityModel, clientLabel, sourceEntity, sourceClass,
			sourceDef, sourceOwnerLabel, sourceModel, GetMaxEntities() - GetEntityCount());
}

void Weapons_GetEntityDebugInfo(int entity, char[] className, int classLen,
		char[] model, int modelLen, int &defIndex, int &owner) {
	strcopy(className, classLen, "invalid");
	model[0] = '\0';
	defIndex = -1;
	owner = 0;
	if (!IsValidEntity(entity)) {
		return;
	}

	GetEntityClassname(entity, className, classLen);
	if (HasEntProp(entity, Prop_Data, "m_ModelName")) {
		GetEntPropString(entity, Prop_Data, "m_ModelName", model, modelLen);
	}
	if (HasEntProp(entity, Prop_Send, "m_iItemDefinitionIndex")) {
		defIndex = GetEntProp(entity, Prop_Send, "m_iItemDefinitionIndex");
	}
	if (HasEntProp(entity, Prop_Send, "m_hOwnerEntity")) {
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	}
}

bool Weapons_IsValidClient(int client) {
	return client > 0 && client <= MaxClients && IsClientInGame(client)
			&& !IsClientSourceTV(client)
			&& !IsClientReplay(client)
			&& !GetEntProp(client, Prop_Send, "m_bIsCoaching");
}

void Weapons_FormatClientLabel(int client, char[] buffer, int maxlen) {
	if (Weapons_IsValidClient(client)) {
		Format(buffer, maxlen, "%N(%d)", client, client);
		return;
	}
	Format(buffer, maxlen, "%d", client);
}

/**
 * Creates a weapon for the specified player.
 */
stock int TF2_CreateItem(int defindex, const char[] itemClass) {
	int weapon = CreateEntityByName(itemClass);
	
	if (IsValidEntity(weapon)) {
		SetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex", defindex);
		SetEntProp(weapon, Prop_Send, "m_bInitialized", 1);
		
		// allow quality / level override by updating through the offset
		// for some reason I've never been able to figure out, this just doesn't render
		// correctly without setting the memory
		char netClass[64];
		GetEntityNetClass(weapon, netClass, sizeof(netClass));
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityQuality"), 6);
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityLevel"), 1);
		
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", 6);
		SetEntProp(weapon, Prop_Send, "m_iEntityLevel", 1);
		
		DispatchSpawn(weapon);
		Weapons_MarkValidatedAttachedEntity(weapon, 0, "create_post_spawn", false);
	}
	return weapon;
}

/**
 * Removes the given item based on its loadout slot.
 */
bool TF2_RemoveItemByLoadoutSlot(int client, int loadoutSlot) {
	int item = TF2Util_GetPlayerLoadoutEntity(client, loadoutSlot);
	
	if (!IsValidEntity(item)) {
		// try harder -- check if any off-class wearable matches, since GPLE only handles native
		for (int i, n = TF2Util_GetPlayerWearableCount(client); i < n; i++) {
			int wearable = TF2Util_GetPlayerWearable(client, i);
			int itemdef = TF2_GetItemDefinitionIndex(wearable);
			if (TF2Econ_GetItemDefaultLoadoutSlot(itemdef) == loadoutSlot) {
				item = wearable;
			}
		}
	}
	
	if (!IsValidEntity(item)) {
		return false;
	}
	
	if (TF2Util_IsEntityWearable(item)) {
		TF2_RemoveWearable(client, item);
	} else {
		TF2_RemoveWeaponSlot(client, TF2Util_GetWeaponSlot(item));
	}
	return true;
}

/**
 * Equips the given econ item.  If the item is a weapon, the ammo and clip are reset to their
 * correct starting capacity.
 */
void TF2_EquipPlayerEconItem(int client, int item) {
	char weaponClass[64];
	GetEntityClassname(item, weaponClass, sizeof(weaponClass));
	
	if (StrContains(weaponClass, "tf_wearable", false) == 0) {
		TF2Util_EquipPlayerWearable(client, item);
		Weapons_MarkValidatedAttachedEntity(item, client, "equip_wearable");
	} else {
		EquipPlayerWeapon(client, item);
		Weapons_MarkValidatedAttachedEntity(item, client, "equip_weapon", false);
		TF2_ResetWeaponAmmo(item);
		
		/**
		 * This calls CBaseCombatWeapon::GiveDefaultAmmo(), which sets up the appropriate clip
		 * count.  This mainly handles the case when the `auto_fires_full_clip` attribute class
		 * is present on the item.
		 * 
		 * Hope there aren't any further side effects from calling ActivateEntity; otherwise
		 * we'll have to add support for CBaseCombatWeapon::GiveDefaultAmmo() somewhere.
		 * Probably in TF2 Utils.
		 */
		ActivateEntity(item);
		Weapons_MarkValidatedAttachedEntity(item, client, "activate_weapon");
	}
}
