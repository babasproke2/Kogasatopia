#if defined _tf2_spread_patterns_included
	#endinput
#endif
#define _tf2_spread_patterns_included

enum TF2SpreadPattern
{
	TF2Spread_Default = 0,
	TF2Spread_Circular15,
};

/**
 * Assigns an engine fixed-spread pattern to a weapon entity.
 */
native void TF2Spread_SetPattern(int weapon, TF2SpreadPattern pattern);

/**
 * Gives a weapon Ambassador-style spread recovery from 0.5 to 1.0 seconds
 * after its previous shot.
 */
native void TF2Spread_SetAmbassadorAccuracy(int weapon, bool enabled);

public Extension __ext_tf2_spread_patterns =
{
	name = "TF2 Spread Patterns",
	file = "tf2_spread_patterns.ext.2.tf2",
	autoload = 1,
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __ext_tf2_spread_patterns_SetNTVOptional()
{
	MarkNativeAsOptional("TF2Spread_SetPattern");
	MarkNativeAsOptional("TF2Spread_SetAmbassadorAccuracy");
}
#endif
