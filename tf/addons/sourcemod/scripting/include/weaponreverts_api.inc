#if defined _weaponreverts_api_included_
	#endinput
#endif

#define _weaponreverts_api_included_

/**
 * Returns configured revert info for a TF2 item definition index.
 *
 * @param weaponIndex   TF2 item definition index.
 * @param weaponName    Weapon display name from weaponreverts.cfg.
 * @param weaponNameLen weaponName buffer length.
 * @param positive      Positive change description.
 * @param positiveLen   positive buffer length.
 * @param negative      Negative change description.
 * @param negativeLen   negative buffer length.
 * @param type          Description type. Defaults to "buff" when absent.
 * @param typeLen       type buffer length.
 * @param classes       Comma-separated class keys from weaponreverts_commands.cfg.
 * @param classesLen    classes buffer length.
 * @return              True if weaponIndex exists in weaponreverts.cfg.
 */
native bool WeaponReverts_GetWeaponInfo(int weaponIndex,
	char[] weaponName, int weaponNameLen,
	char[] positive, int positiveLen,
	char[] negative, int negativeLen,
	char[] type, int typeLen,
	char[] classes, int classesLen);

/**
 * Checks weaponreverts_commands.cfg for class access to a weapon index.
 */
native bool WeaponReverts_CanClassUseWeapon(const char[] className, int weaponIndex);

public SharedPlugin __pl_weaponreverts = {
	name = "weaponreverts",
	file = "weaponreverts.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_weaponreverts_SetNTVOptional()
{
	MarkNativeAsOptional("WeaponReverts_GetWeaponInfo");
	MarkNativeAsOptional("WeaponReverts_CanClassUseWeapon");
}
#endif
