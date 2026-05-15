#if defined _bonuspoints_transactions_included
  #endinput
#endif
#define _bonuspoints_transactions_included

#include <sourcemod>

/**
 * Returns whether a client owns a configured bonus-points shop item.
 *
 * This native only checks the in-memory client cache.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              True if owned.
 */
native bool BonusPoints_HasPurchase(int client, const char[] itemKey);

/**
 * Returns the price paid for a configured bonus-points shop item.
 *
 * This native only checks the in-memory client cache.
 *
 * @param client        Client index.
 * @param itemKey       Stable item database key.
 * @return              Price paid, or 0 if not owned.
 */
native int BonusPoints_GetPurchasePrice(int client, const char[] itemKey);
