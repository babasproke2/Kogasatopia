#if defined _tags_api_included
    #endinput
#endif
#define _tags_api_included

#include <sourcemod>

/** Writes the resolved tag for a live client or SteamID64. */
native bool Tags_GetTag(int client, const char[] steamid64, char[] buffer, int maxlen);

/** Writes a live client's selected/resolved tag. */
native bool Tags_GetSelectedTag(int client, char[] buffer, int maxlen);

/** Sets a live client's selected tag. */
native bool Tags_SetSelectedTag(int client, const char[] tag);
