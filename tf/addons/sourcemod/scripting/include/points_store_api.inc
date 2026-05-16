#if defined _points_store_api_included
  #endinput
#endif
#define _points_store_api_included

#include <sourcemod>

/**
 * Returns whether a client's bonus-point balance cache is loaded.
 *
 * @param client        Client index.
 * @return              True if the balance is ready.
 */
native bool PointsStore_AreBonusPointsLoaded(int client);

/**
 * Returns a client's current Bonus Points total.
 *
 * @param client        Client index.
 * @return              Bonus Points, or 0 if unavailable.
 */
native int PointsStore_GetBonusPoints(int client);

/**
 * Applies bonus points with the standard BP sound/chat behavior.
 *
 * @param client        Client index.
 * @param points        Points delta. Negative spends.
 * @param playSound     Play the BP sound through SaySounds.
 * @param chatAlert     Print BP chat line.
 * @param randomChance  Chance, clamped to 0.1..1.0.
 * @param type          Message type key.
 * @param target        Optional target client or event value.
 * @param delay         Delay in seconds. 0.0 = immediate.
 * @return              True on success.
 */
native bool PointsStore_ApplyBonusPoints(int client, int points, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0);

/**
 * Spends bonus points immediately without sound or chat output.
 *
 * @param client        Client index.
 * @param points        Positive number of points to spend.
 * @return              True if the spend succeeded.
 */
native bool PointsStore_SpendBonusPoints(int client, int points);

/**
 * Returns whether a client owns a configured points-store shop item.
 *
 * This native only checks the in-memory client cache.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              True if owned.
 */
native bool PointsStore_HasPurchase(int client, const char[] itemKey);

/**
 * Returns the price paid for a configured points-store shop item.
 *
 * This native only checks the in-memory client cache.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              Price paid, or 0 if not owned.
 */
native int PointsStore_GetPurchasePrice(int client, const char[] itemKey);

public SharedPlugin __pl_points_store =
{
    name = "points_store",
    file = "points_store.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_points_store_SetNTVOptional()
{
    MarkNativeAsOptional("PointsStore_AreBonusPointsLoaded");
    MarkNativeAsOptional("PointsStore_GetBonusPoints");
    MarkNativeAsOptional("PointsStore_ApplyBonusPoints");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("PointsStore_GetPurchasePrice");
}
#endif
