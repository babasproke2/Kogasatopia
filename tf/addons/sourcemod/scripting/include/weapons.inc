#if defined __weapons_included
	#endinput
#endif

#define __weapons_included

/***************************************************************************************
 * Constant definitions below are shared between the core plugin and its dependencies. *
 * Values here should not be rearranged.                                               *
 ***************************************************************************************/

#define LOADOUT_FLAG_UPDATE_BACKEND (1 << 0) // update the item on the backing database, in
                                             // addition to the current session -- if this is
                                             // not set, the item will be treated as a temporary
                                             // override
#define LOADOUT_FLAG_ATTEMPT_REGEN  (1 << 1) // if the player is in a spawn room, perform
                                             // regeneration to refresh the loadout


// End of shared definitions; the core defines this to avoid declaring its own natives.
#if defined WEAPONS_INCLUDE_SHAREDDEFS_ONLY
	#endinput
#endif

/************************************************
 * Start of definitions for dependency plugins. *
 ************************************************/

#include <tf2>

/**
 * Callback for `Weapons_GetItemList`.  Return `true` if the specified custom item UID should be
 * added to the returned `ArrayList`.
 */
typedef WeaponsItemFilterCriteria = function bool(const char[] uid, any data);

/**
 * Adds the given item to the player's session loadout.  This item will be equipped on the
 * player on next regeneration (spawn / resupply) and persisted until they disconnect.
 * 
 * The loadout slot is determined based on the item definition.
 */
native bool Weapons_SetPlayerLoadoutItem(int client, TFClassType playerClass, const char[] uid,
		int flags = 0);

/**
 * Removes the item from a player's session loadout.
 */
native void Weapons_RemovePlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot,
		int flags = 0);

/**
 * Retrieves the UID active in a player's session loadout.
 */
native bool Weapons_GetPlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot,
		char[] uid, int uidLen, int flags = 0);

/**
 * Immediately equips the item onto the target player.  The item is not persisted.
 * 
 * As this happens outside of the standard loadout regeneration flow, unexpected side effects
 * may occur.  Consider using `Weapons_SetCustomLoadoutItem` instead.
 * 
 * @return    Item entity reference, or INVALID_ENT_REFERENCE on failure.
 * @error     Client is not in-game or uid is invalid.
 */
native int Weapons_EquipPlayerItem(int client, const char[] uid);

/**
 * Checks if the player has access to the given item.
 * 
 * @return    Whether or not the client can normally use the item.
 */
native bool Weapons_CanPlayerAccessItem(int client, const char[] uid);

/**
 * Returns an ArrayList containing all valid item UIDs.  If a WeaponsItemFilterCriteria callback is
 * passed in, the ArrayList only contains UIDs that the callback returned `true` on.
 * 
 * This handle is owned by the calling plugin, so it should be `delete`d when not needed
 * anymore.
 * 
 * @return    ArrayList containing strings.
 */
native ArrayList Weapons_GetItemList(WeaponsItemFilterCriteria func = INVALID_FUNCTION, any data = 0);

/**
 * Validates that the given item UID is found in the custom item list.
 */
native bool Weapons_IsItemUIDValid(const char[] uid);

/**
 * Retrieves an item's UID, if one exists.
 *
 * @return    True if the item has an associated UID, false if not.  (Note that the item UID is
 *            not tested for validity within the plugin's known items - use Weapons_IsItemUIDValid
 *            if necessary.)
 * @error     Entity is not an item.
 */
native bool Weapons_GetItemUIDFromEntity(int entity, char[] buffer, int maxlen);

/**
 * Retrieves the configured display name for a custom item UID.
 *
 * @return    True when the UID exists and has a display name.
 */
native bool Weapons_GetItemDisplayName(const char[] uid, char[] buffer, int maxlen);

/**
 * Checks whether a custom item is configured as a reskin-only item.
 *
 * @return    True when the UID exists and has `reskin_only` enabled.
 */
native bool Weapons_IsItemReskinOnly(const char[] uid);

/**
 * Called after the plugin restores runtime state on a persisted custom item.
 */
forward void Weapons_OnItemRuntimeStateReady(int client, int entity);

/**
 * Returns the item's loadout slot for the given class, or -1 if the item UID or item / class
 * combination is not valid.
 */
native int Weapons_GetItemLoadoutSlot(const char[] uid, TFClassType playerClass);

/**
 * Retrieves a copy of a custom item definition's "extended data" section by name, if one
 * exists.  This handle should be freed by the calling plugin.
 * 
 * @return    A KeyValues handle containing the custom item definition's extended data named
 *            subsection, or `null` if the custom item definition or subsection does not exist.
 */
native KeyValues Weapons_GetItemExtData(const char[] uid, const char[] section);

/**
 * Returns configured weapon information for a TF2 item definition index.
 */
native bool Weapons_GetWeaponInfo(int weaponIndex,
	char[] weaponName, int weaponNameLen,
	char[] positive, int positiveLen,
	char[] neutral, int neutralLen,
	char[] negative, int negativeLen,
	char[] type, int typeLen,
	char[] classes, int classesLen);

/**
 * Checks whether a class can use a configured TF2 item definition.
 */
native bool Weapons_CanClassUseWeapon(const char[] className, int weaponIndex);

forward void OnAmbassadorHeadshotKill(int attacker, int victim);
forward void OnSandmanCleaverCombo(int attacker, int victim);
forward void OnMeatshotKill(int attacker, int victim);
forward void OnEnvironmentalKill(int attacker, int victim);
forward void OnSandmanMoonshot(int attacker, int victim);
forward void OnDoubleDonk(int attacker, int victim);

public SharedPlugin __pl_weapons = {
	name = "weapons",
	file = "weapons.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_weapons_SetNTVOptional() {
	MarkNativeAsOptional("Weapons_SetPlayerLoadoutItem");
	MarkNativeAsOptional("Weapons_RemovePlayerLoadoutItem");
	MarkNativeAsOptional("Weapons_GetPlayerLoadoutItem");
	MarkNativeAsOptional("Weapons_EquipPlayerItem");
	MarkNativeAsOptional("Weapons_CanPlayerAccessItem");
	MarkNativeAsOptional("Weapons_GetItemList");
	MarkNativeAsOptional("Weapons_IsItemUIDValid");
	MarkNativeAsOptional("Weapons_GetItemUIDFromEntity");
	MarkNativeAsOptional("Weapons_GetItemDisplayName");
	MarkNativeAsOptional("Weapons_IsItemReskinOnly");
	MarkNativeAsOptional("Weapons_GetItemExtData");
	MarkNativeAsOptional("Weapons_GetItemLoadoutSlot");
	MarkNativeAsOptional("Weapons_GetWeaponInfo");
	MarkNativeAsOptional("Weapons_CanClassUseWeapon");
}
#endif
