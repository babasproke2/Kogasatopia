#if defined _amplifier_included
	#endinput
#endif
#define _amplifier_included

enum AmplifierObjectType
{
	AmplifierObject_Dispenser = 0,
	AmplifierObject_Teleporter = 1,
	AmplifierObject_Sentry = 2
};

/**
 * Returns true when amplifier's current force, playercount, attribute, or
 * player preference logic would convert this object into an amplifier.
 */
native bool Amplifier_WouldReplaceBuilding(int client, int objectType);

public SharedPlugin __pl_amplifier =
{
	name = "Amplifier",
	file = "amp.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};
