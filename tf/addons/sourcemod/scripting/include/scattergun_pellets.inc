#if defined _scattergun_pellets_included
 #endinput
#endif
#define _scattergun_pellets_included

/**
 * Called after a player_death caused by tf_weapon_scattergun.
 *
 * @param attacker  Client index of the killer.
 * @param victim    Client index of the killed player.
 * @param pellets   Number of scattergun pellets that hit this victim on the killing shot.
 * @param total     Full pellet count for the stock scattergun, currently 10.
 */
forward void TF2Scatter_OnPelletKill(int attacker, int victim, int pellets, int total);

/**
 * Returns the stored pellet count for the last scattergun kill from attacker to victim.
 */
native int TF2Scatter_GetLastKillPellets(int attacker, int victim);

/**
 * Returns true when the stored last scattergun kill from attacker to victim was 10/10.
 */
native bool TF2Scatter_WasLastKillFull(int attacker, int victim);

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
}
#endif
