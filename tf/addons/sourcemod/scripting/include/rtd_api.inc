#if defined _rtd_api_included
    #endinput
#endif
#define _rtd_api_included

#include <sourcemod>

/**
 * Applies a gifted RTD roll without charging the recipient.
 *
 * Normal round, alive, cooldown, limit, and eligibility checks still apply.
 */
native bool RTD_ApplyGiftedRoll(int client);

public SharedPlugin __pl_rtd_gifts =
{
    name = "RollTheDice2",
    file = "rtd.smx",
    required = 0,
};

public void __pl_rtd_gifts_SetNTVOptional()
{
    MarkNativeAsOptional("RTD_ApplyGiftedRoll");
}
