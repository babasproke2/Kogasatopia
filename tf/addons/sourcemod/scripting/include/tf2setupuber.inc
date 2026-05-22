#if defined _tf2setupuber_included
    #endinput
#endif
#define _tf2setupuber_included

#include <sourcemod>

/**
 * Sets the regular setup-time Medigun UberCharge multiplier.
 *
 * Stock TF2 is 3.0.  Use 9.0 to make setup-time charge gain 9x the normal
 * non-setup rate.
 *
 * @param multiplier  Finite value from 0.0 through 64.0.
 * @error             Throws if multiplier is outside the allowed range.
 */
native void TF2SetupUber_SetMultiplier(float multiplier);

/**
 * Returns the current setup-time multiplier.
 */
native float TF2SetupUber_GetMultiplier();

/**
 * Returns true once the extension has loaded its detour and SDKTools interface.
 */
native bool TF2SetupUber_IsAvailable();

public SharedPlugin __pl_tf2setupuber =
{
    name = "tf2setupuber",
    file = "tf2setupuber.ext",
#if defined REQUIRE_EXTENSIONS
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __pl_tf2setupuber_SetNTVOptional()
{
    MarkNativeAsOptional("TF2SetupUber_SetMultiplier");
    MarkNativeAsOptional("TF2SetupUber_GetMultiplier");
    MarkNativeAsOptional("TF2SetupUber_IsAvailable");
}
#endif
