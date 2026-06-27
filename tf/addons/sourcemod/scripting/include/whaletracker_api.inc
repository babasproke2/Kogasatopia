#if defined _whaletracker_api_included
  #endinput
#endif
#define _whaletracker_api_included

#include <sourcemod>

/**
 * Returns a client's cumulative tracked kills.
 *
 * @param client        Client index.
 * @return              Cumulative kills, or 0 if unavailable.
 */
native int WhaleTracker_GetCumulativeKills(int client);

/**
 * Returns whether a client's WhaleTracker stats are loaded and ready.
 *
 * @param client        Client index.
 * @return              True if ready.
 */
native bool WhaleTracker_AreStatsLoaded(int client);

/**
 * Returns whether a client's loaded cumulative playtime meets an hour threshold.
 *
 * @param client        Client index.
 * @param hours         Required cumulative playtime in whole hours.
 * @return              True if loaded playtime is at least hours.
 */
native bool WhaleTracker_HasPlaytimeHours(int client, int hours);

/**
 * Returns a client's current Whale Points total.
 *
 * @param client        Client index.
 * @return              Whale Points, or 0 if unavailable.
 */
native int WhaleTracker_GetWhalePoints(int client);

/**
 * Computes Whale Points from raw cumulative totals.
 *
 * @param kills         Total kills.
 * @param deaths        Total deaths.
 * @param assists       Total assists.
 * @param totalUbers    Total ubers.
 * @param damageDealt   Total damage dealt.
 * @param healing       Total healing.
 * @param playtime      Total playtime in seconds.
 * @return              Whale Points for the merged totals.
 */
native int WhaleTracker_ComputeWhalePoints(int kills, int deaths, int assists, int totalUbers, int damageDealt, int healing, int playtime);

/**
 * Resolves the best recorded name for a SteamID64.
 *
 * Lookup order:
 * 1. Connected live client name
 * 2. filters_steam_names.last_name
 * 3. whaletracker.cached_personaname
 *
 * @param steamId64     SteamID64 to look up.
 * @param buffer        Output buffer.
 * @param maxlen        Output buffer size.
 * @return              True if a non-empty name was found.
 */
native bool WhaleTracker_GetLastRecordedName(const char[] steamId64, char[] buffer, int maxlen);

/**
 * Returns the best known last_seen timestamp for a SteamID64.
 *
 * Lookup order:
 * 1. Connected live client's in-memory lastSeen
 * 2. whaletracker.last_seen
 *
 * @param steamId64     SteamID64 to look up.
 * @return              Unix timestamp, or 0 if unavailable.
 */
native int WhaleTracker_GetLastSeen(const char[] steamId64);

/**
 * Fired when WhaleTracker records an airshot.
 *
 * @param attacker      Attacker client index.
 * @param victim        Victim client index.
 */
forward void WhaleTracker_OnAirshot(int attacker, int victim);

/**
 * Fired when WhaleTracker records a valid enemy projectile direct hit.
 *
 * This fires after the projectile touch is confirmed by damage processing.
 *
 * @param attacker      Attacker client index.
 * @param victim        Victim client index.
 * @param weapon        Weapon entity index that caused the hit.
 */
forward void WhaleTracker_OnProjectileDirectHit(int attacker, int victim, int weapon);

/**
 * Fired when WhaleTracker records a medic dropping a full uber.
 *
 * @param attacker      Attacker client index, or 0 if no valid attacker.
 * @param medic         Medic client index.
 */
forward void WhaleTracker_OnMedicDrop(int attacker, int medic);

/**
 * Fired when WhaleTracker records a killstreak milestone.
 *
 * Milestones fire in increments of 5: 5, 10, 15, and so on.
 *
 * @param client        Client index.
 * @param killstreak    Current killstreak value.
 */
forward void WhaleTracker_OnKillstreak(int client, int killstreak);

/**
 * Fired when WhaleTracker records the end of a killstreak.
 *
 * This fires when a client with a killstreak of 5 or higher is killed.
 *
 * @param attacker      Client index that ended the killstreak.
 * @param victim        Client index whose killstreak ended.
 * @param killstreak    Final killstreak value before it was reset.
 */
forward void WhaleTracker_OnKillstreakEnd(int attacker, int victim, int killstreak);

/**
 * Fired when WhaleTracker records a multikill milestone.
 *
 * Multikills fire for 2, 3, 4, and 5 kills within the configured window.
 *
 * @param client        Client index.
 * @param kills         Number of kills in the current multikill chain.
 */
forward void WhaleTracker_OnMultikill(int client, int kills);
