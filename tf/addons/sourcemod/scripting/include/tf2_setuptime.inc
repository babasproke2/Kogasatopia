#if defined _tf2_setuptime_included
    #endinput
#endif
#define _tf2_setuptime_included

#include <sourcemod>

/**
 * Returns true while TF2 setup time is active.
 *
 * @return true during setup time, false otherwise.
 * @error  Native unavailable if the tf2_setuptime extension is not loaded.
 */
native bool TF2_IsSetupTimeActive();

public Extension __ext_tf2_setuptime =
{
    name = "tf2_setuptime",
    file = "tf2_setuptime.ext",
    autoload = 1,
#if defined REQUIRE_EXTENSIONS
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_EXTENSIONS
public void __ext_tf2_setuptime_SetNTVOptional()
{
    MarkNativeAsOptional("TF2_IsSetupTimeActive");
}
#endif
