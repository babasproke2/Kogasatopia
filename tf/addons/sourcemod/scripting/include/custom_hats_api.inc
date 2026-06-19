#if defined _custom_hats_api_included
    #endinput
#endif
#define _custom_hats_api_included

#include <sourcemod>

/**
 * Writes the configured chat prefix for a client's active custom hat.
 */
native bool CustomHats_GetPrefix(int client, char[] buffer, int maxlen);

/**
 * Writes the available custom hat tag choices for a client.
 */
native bool CustomHats_GetTagChoices(int client, char[] buffer, int maxlen);

/**
 * Resolves a custom hat tag key into display text.
 */
native bool CustomHats_ResolveTag(int client, const char[] key, char[] buffer, int maxlen);

/**
 * Finds the custom hat tag key that produced a display tag.
 */
native bool CustomHats_FindTagSource(int client, const char[] tag, char[] key, int maxlen);
