#if defined _mutecheck_api_included
    #endinput
#endif
#define _mutecheck_api_included

#include <sourcemod>

/** Returns how many connected human clients the listener has muted. */
native int MuteCheck_GetMutedClientCount(int listener);

public SharedPlugin __pl_mutecheck =
{
    name = "mutecheck",
    file = "mutecheck.smx",
    required = 0,
};

public void __pl_mutecheck_SetNTVOptional()
{
    MarkNativeAsOptional("MuteCheck_GetMutedClientCount");
}
