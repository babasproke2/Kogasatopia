#if defined _clans_api_included
  #endinput
#endif
#define _clans_api_included

#include <sourcemod>

/**
 * Returns the formatted clan tag string(s) for a client.
 *
 * The returned string is suitable for direct display and may include the
 * main clan tag plus a selected sub-tag joined together.
 *
 * @param client        Client index to inspect.
 * @param buffer        Destination buffer.
 * @param maxlen        Destination buffer size.
 * @return              True on success with a non-empty result, false otherwise.
 */
native bool Clans_GetTags(int client, char[] buffer, int maxlen);

/**
 * Returns how many connected players on a team share the caller's clan_id.
 *
 * Return values:
 *  > 0  count of known same-clan players on the team, including the caller
 *  0    caller is not in a clan, is invalid, or clan state is temporarily unavailable
 *
 * @param client        Client index whose clan_id is used.
 * @param team          Team to inspect. 0 = client's current team.
 * @return              Same-team same-clan count, or 0.
 */
native int Clans_GetSameTeamClanMemberCount(int client, int team = 0);
