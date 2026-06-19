#if defined _hugs_api_included
    #endinput
#endif
#define _hugs_api_included

#include <sourcemod>

/** Returns how many rapes a client has given in hugs stats. */
native int Hugs_GetRapesGiven(int client);

/** Returns whether a client's hugs stats are loaded. */
native bool Hugs_AreStatsLoaded(int client);
