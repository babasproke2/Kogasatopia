#if defined _scattergun_pellets_included
 #endinput
#endif
#define _scattergun_pellets_included

/**
 * Called once for a completed buckshot hit from tf_weapon_scattergun or any
 * weapon class containing tf_weapon_shotgun.
 *
 * @param attacker  Client index of the shooter.
 * @param victim    Client index of the player hit or killed.
 * @param pellets   Number of deduplicated pellets that hit this victim.
 * @param total     Actual number of pellets fired by this shot.
 * @param kill      True if this shot produced the player_death event.
 */
forward void TF2Shotgun_OnPelletShot(int attacker, int victim, int pellets, int total, bool kill);

/**
 * Returns the stored pellet count for the last tracked buckshot kill from attacker to victim.
 */
native int TF2Scatter_GetLastKillPellets(int attacker, int victim);

/**
 * Returns true when every pellet fired by the stored last tracked buckshot kill
 * hit the victim.
 */
native bool TF2Scatter_WasLastKillFull(int attacker, int victim);

/**
 * Returns true when every pellet in the current game-tick shot from attacker
 * hit victim with the specified weapon.
 */
native bool TF2Scatter_IsCurrentShotFull(int attacker, int victim, int weapon);

/**
 * Registers the actual pellet count for a weapon. Passing zero or less clears
 * the override and restores the stock 10-pellet fallback.
 */
native void TF2Scatter_SetWeaponPelletCount(int weapon, int pelletsFired);

public Extension __ext_scattergun_pellets =
{
	name = "Scattergun Pellets",
	file = "scattergun_pellets.ext.2.tf2",
	autoload = 1,
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __ext_scattergun_pellets_SetNTVOptional()
{
	MarkNativeAsOptional("TF2Scatter_GetLastKillPellets");
	MarkNativeAsOptional("TF2Scatter_WasLastKillFull");
	MarkNativeAsOptional("TF2Scatter_IsCurrentShotFull");
	MarkNativeAsOptional("TF2Scatter_SetWeaponPelletCount");
}
#endif
