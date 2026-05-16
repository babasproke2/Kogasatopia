#if defined _bonuspoints_transactions_included
  #endinput
#endif
#define _bonuspoints_transactions_included

#include <points_store_api>

/**
 * Compatibility wrapper for the old bonuspoints_transactions API.
 */
stock bool BonusPoints_HasPurchase(int client, const char[] itemKey)
{
    return PointsStore_HasPurchase(client, itemKey);
}

/**
 * Compatibility wrapper for the old bonuspoints_transactions API.
 */
stock int BonusPoints_GetPurchasePrice(int client, const char[] itemKey)
{
    return PointsStore_GetPurchasePrice(client, itemKey);
}
