#if defined _autobalance_4teams_api_included
  #endinput
#endif
#define _autobalance_4teams_api_included

#include <sourcemod>

/** Returns whether a client has an incoming team-swap request. */
native bool Autobalance_HasPendingTeamSwap(int client);

public SharedPlugin __pl_autobalance_4teams =
{
    name = "autobalance_4teams",
    file = "autobalance_4teams.smx",
    required = 0,
};

public void __pl_autobalance_4teams_SetNTVOptional()
{
    MarkNativeAsOptional("Autobalance_HasPendingTeamSwap");
}
