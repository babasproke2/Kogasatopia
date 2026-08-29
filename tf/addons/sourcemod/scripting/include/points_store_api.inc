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
 * Applies a configured reward with the standard points-store sound/chat behavior.
 *
 * @param client        Client index.
 * @param rewardId      Stable key under "rewards" in points_store.cfg.
 * @param playSound     Play the reward sound through SaySounds.
 * @param chatAlert     Print currency chat line.
 * @param randomChance  Chance, clamped to 0.1..1.0.
 * @param target        Optional target client or event value.
 * @param delay         Delay in seconds. 0.0 = immediate.
 * @return              True when queued/applied; false if the reward is not configured.
 */
native bool PointsStore_ApplyBonusPoints(int client, const char[] rewardId, bool playSound = true, bool chatAlert = true, float randomChance = 1.0, int target = 0, float delay = 3.0);

/**
 * Applies a configured reward to a SteamID64, including disconnected clients.
 *
 * @param steamId64      Target SteamID64.
 * @param rewardId       Stable key under "rewards" in points_store.cfg.
 * @param playSound      Play the reward sound if the client is online.
 * @param chatAlert      Print currency chat line if the client is online.
 * @return               True when queued/applied; false if the reward is not configured.
 */
native bool PointsStore_ApplyBonusPointsSteamId(const char[] steamId64, const char[] rewardId, bool playSound = true, bool chatAlert = true);

/** Returns a configured reward amount, or 0 when the ID is unknown. */
native int PointsStore_GetRewardAmount(const char[] rewardId);

/** Returns a configured per-map limit, or -1 when the ID is unknown. */
native int PointsStore_GetRewardPerMapLimit(const char[] rewardId);

/** Writes a configured reward's long display name. */
native bool PointsStore_GetRewardLongName(const char[] rewardId, char[] buffer, int maxlen);

/** Writes a configured reward's short description. */
native bool PointsStore_GetRewardShortDescription(const char[] rewardId, char[] buffer, int maxlen);

/** Writes a configured reward's long description. */
native bool PointsStore_GetRewardLongDescription(const char[] rewardId, char[] buffer, int maxlen);

/** Refunds a dynamic amount without treating it as a configured reward. */
native bool PointsStore_RefundBonusPoints(int client, int points, const char[] type = "api_refund");

/** Refunds a dynamic amount to a SteamID64 without treating it as a configured reward. */
native bool PointsStore_RefundBonusPointsSteamId(const char[] steamId64, int points, const char[] type = "api_refund");

/**
 * Applies an offline-safe currency award exactly once for a stable key.
 *
 * The award key and balance update are committed in one database transaction.
 * Completion is reported through PointsStore_OnApplyBonusPointsSteamIdOnce.
 *
 * @param steamId64     Target SteamID64.
 * @param points        Positive currency amount.
 * @param awardKey      Globally unique idempotency key.
 * @param type          Statistics/logging reason.
 * @return              True if the asynchronous transaction was queued.
 */
native bool PointsStore_ApplyBonusPointsSteamIdOnce(const char[] steamId64, int points, const char[] awardKey, const char[] type = "api_idempotent_award");

/**
 * Fired after an idempotent currency award resolves.
 *
 * @param awardKey      Idempotency key supplied by the caller.
 * @param success       True if the award exists and matches the request.
 * @param newlyApplied  True only when this call created the award.
 */
forward void PointsStore_OnApplyBonusPointsSteamIdOnce(const char[] awardKey, bool success, bool newlyApplied);

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
 * Awards a fixed Memoman event reward by debiting the event source account.
 *
 * Supported source IDs: custom_weapon_kill, loch_n_load_kill,
 * loch_n_load_airshot, sentry_kill, sentry_level_3,
 * uber_deployed, and double_donk.
 *
 * @param client        Client receiving the reward.
 * @param sourceId      Stable Memoman event source ID.
 * @return              True when the delayed award was queued.
 */
native bool PointsStore_AwardMemomanEvent(int client, const char[] sourceId);

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
    MarkNativeAsOptional("PointsStore_GetRewardAmount");
    MarkNativeAsOptional("PointsStore_GetRewardPerMapLimit");
    MarkNativeAsOptional("PointsStore_GetRewardLongName");
    MarkNativeAsOptional("PointsStore_GetRewardShortDescription");
    MarkNativeAsOptional("PointsStore_GetRewardLongDescription");
    MarkNativeAsOptional("PointsStore_ApplyBonusPointsSteamIdOnce");
    MarkNativeAsOptional("PointsStore_RefundBonusPoints");
    MarkNativeAsOptional("PointsStore_RefundBonusPointsSteamId");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    MarkNativeAsOptional("PointsStore_StealBonusPoints");
    MarkNativeAsOptional("PointsStore_AwardMemomanEvent");
    MarkNativeAsOptional("PointsStore_HasPurchase");
    MarkNativeAsOptional("PointsStore_GetPurchasePrice");
    MarkNativeAsOptional("PointsStore_GetPurchaseExpiresAt");
    MarkNativeAsOptional("PointsStore_GetPurchaseUsesRemaining");
    MarkNativeAsOptional("PointsStore_ConsumePurchaseUse");
}
