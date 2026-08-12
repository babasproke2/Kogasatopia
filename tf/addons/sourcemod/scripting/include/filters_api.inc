#if defined _filters_api_included
    #endinput
#endif
#define _filters_api_included

#include <sourcemod>

/** Returns whether a client is redlisted. */
native bool Filters_IsRedlisted(int client);

/** Writes the filtered/colorized chat name for a client. */
native bool Filters_GetChatName(int client, char[] buffer, int maxlen);

/** Writes the color token associated with a SteamID64. */
native bool Filters_GetSteamIdColorTag(const char[] steamId64, char[] buffer, int maxlen);

/** Resolves and renders an online or offline SteamID64 name using prenames and stored color preferences. */
native bool Filters_GetSteamIdChatName(
    const char[] steamId64,
    const char[] fallbackName,
    char[] buffer,
    int maxlen);

/** Writes the last Steam persona name recorded by filters.sp for a SteamID64. */
native bool Filters_GetLastRecordedSteamName(const char[] steamId64, char[] buffer, int maxlen);
