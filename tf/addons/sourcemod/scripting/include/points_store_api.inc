#if defined _points_store_api_included
  #endinput
#endif
#define _points_store_api_included

#include <sourcemod>

/**
 * Returns whether a client's currency balance cache is loaded.
 *
 * @param client        Client index.
 * @return              True if the balance is ready.
 */
native bool PointsStore_AreBonusPointsLoaded(int client);

/**
 * Returns a client's current currency balance.
 *
 * @param client        Client index.
 * @return              Currency balance, or 0 if unavailable.
 */
native int PointsStore_GetBonusPoints(int client);

/**
 * Applies currency with the standard points-store sound/chat behavior.
 *
 * @param client        Client index.
 * @param points        Points delta. Negative spends.
 * @param playSound     Play the reward sound through SaySounds.
 * @param chatAlert     Print currency chat line.
 * @param randomChance  Chance, clamped to 0.1..1.0.
 * @param type          Message type key.
 * @param target        Optional target client or event value.
 * @param delay         Delay in seconds. 0.0 = immediate.
 * @param perMap        Positive cap for successful awards of this type per map. 0 = unlimited.
 * @return              True on success.
 */
native bool PointsStore_ApplyBonusPoints(int client, int points, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, const char[] type = "", int target = 0, float delay = 3.0, int perMap = 0);

/**
 * Applies currency to a SteamID64, including disconnected clients.
 *
 * @param steamId64      Target SteamID64.
 * @param points         Points delta.
 * @param playSound      Play the reward sound if the client is online.
 * @param chatAlert      Print currency chat line if the client is online.
 * @param type           Message type key.
 * @param perMap         Positive cap for successful awards of this type per map. 0 = unlimited.
 * @return               True on success.
 */
native bool PointsStore_ApplyBonusPointsSteamId(const char[] steamId64, int points, bool playSound = true, bool chatAlert = true, const char[] type = "", int perMap = 0);

/**
 * Spends currency immediately without sound or chat output.
 *
 * @param client        Client index.
 * @param points        Positive number of points to spend.
 * @return              True if the spend succeeded.
 */
native bool PointsStore_SpendBonusPoints(int client, int points);

/**
 * Transfers currency from one loaded client balance to another.
 *
 * @param victim        Client index to debit.
 * @param recipient     Client index to credit.
 * @param points        Requested positive transfer amount.
 * @param type          Message type key for statistics/logging.
 * @return              Actual amount transferred, or 0 if unavailable.
 */
native int PointsStore_StealBonusPoints(int victim, int recipient, int points, const char[] type = "api_steal");

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

/**
 * Returns when a configured shop item expires for a client.
 *
 * This native only checks the in-memory client cache.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              Unix expiry timestamp, 0 for permanent, or -1 if not owned.
 */
native int PointsStore_GetPurchaseExpiresAt(int client, const char[] itemKey);

/**
 * Returns how many uses remain for a use-limited shop item.
 *
 * Permanent/non-use-limited purchases return -1. Missing purchases return 0.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              Remaining uses, -1 for unlimited, or 0 if not owned.
 */
native int PointsStore_GetPurchaseUsesRemaining(int client, const char[] itemKey);

/**
 * Consumes one use from a use-limited shop item and saves the new count.
 *
 * Permanent/non-use-limited purchases and missing purchases are not changed.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              Remaining uses after consume, or -1 if no use was consumed.
 */
native int PointsStore_ConsumePurchaseUse(int client, const char[] itemKey);

public SharedPlugin __pl_points_store =
{
    name = "points_store",
    file = "points_store.smx",
    required = 0,
};

public void __pl_points_store_SetNTVOptional()
{
    MarkNativeAsOptional("PointsStore_AreBonusPointsLoaded");
    MarkNativeAsOptional("PointsStore_GetBonusPoints");
    MarkNativeAsOptional("PointsStore_ApplyBonusPoints");
    MarkNativeAsOptional("PointsStore_ApplyBonusPointsSteamId");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("PointsStore_GetPurchasePrice");
    MarkNativeAsOptional("PointsStore_GetPurchaseExpiresAt");
    MarkNativeAsOptional("PointsStore_GetPurchaseUsesRemaining");
    MarkNativeAsOptional("PointsStore_ConsumePurchaseUse");
}
