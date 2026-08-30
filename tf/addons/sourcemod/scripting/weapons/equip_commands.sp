void WeaponsEquipCommands_OnPluginStart() {
	RegAdminCmd("sm_weapons_equip", EquipItemCmd, ADMFLAG_ROOT);
	RegAdminCmd("sm_weapons_equip_target", EquipItemCmdTarget, ADMFLAG_ROOT);
	RegAdminCmd("sm_weapons_set_loadout", PersistItemCmd, ADMFLAG_ROOT);
}

static bool WeaponsEquip_EquipItem(int client, const char[] itemuid) {
	CustomItemDefinition item;
	return GetCustomItemDefinition(itemuid, item)
		&& IsValidEntity(EquipCustomItem(client, item));
}

/**
 * Testing command to equip the given item uid on the player.
 * 
 * NOTE: This command immediately equips the item without respawning - this may not accurately
 * reflect weapon behavior.
 */
Action EquipItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	} else if (!WeaponsEquip_EquipItem(client, itemuid)) {
		ReplyToCommand(client, "Failed to equip custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

/**
 * Testing command to temporarily assign the given item uid on the player's loadout.
 * The item will be applied the next time the player is regenerated.
 */
Action PersistItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	} else if (!SetClientCustomLoadoutItem(client, TF2_GetPlayerClass(client), itemuid, 0)) {
		ReplyToCommand(client, "Failed to set custom item uid %s", itemuid);
	}
	
	return Plugin_Handled;
}

/**
 * Testing command to equip the given item uid on the specified target(s).
 */
Action EquipItemCmdTarget(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char targetString[64];
	GetCmdArg(1, targetString, sizeof(targetString));
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArg(2, itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
		return Plugin_Handled;
	}
	
	bool multilang;
	char targetName[MAX_NAME_LENGTH];
	int targets[MAXPLAYERS], nTargetsOrFailureReason;
	nTargetsOrFailureReason = ProcessTargetString(targetString, client,
			targets, sizeof(targets), COMMAND_FILTER_NO_IMMUNITY,
			targetName, sizeof(targetName), multilang);
	
	if (nTargetsOrFailureReason <= 0) {
		ReplyToTargetError(client, nTargetsOrFailureReason);
		return Plugin_Handled;
	}
	
	for (int i; i < nTargetsOrFailureReason; i++) {
		int target = targets[i];
		if (!WeaponsEquip_EquipItem(target, itemuid)) {
			ReplyToCommand(client, "Failed to equip custom item uid %s on %N", itemuid, target);
		}
	}
	
	return Plugin_Handled;
}
