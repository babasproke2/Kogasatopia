#if defined _hugs_api_included
    #endinput
#endif
#define _hugs_api_included

#include <sourcemod>

/** Returns how many rapes a client has given in hugs stats. */
native int Hugs_GetRapesGiven(int client);

/** Returns whether a client's hugs stats are loaded. */
native bool Hugs_AreStatsLoaded(int client);

/** Redeems one mailed hug using persistent SteamID64 identities. */
native bool Hugs_RedeemMailedHug(
    const char[] senderSteamId64,
    const char[] receiverSteamId64,
    const char[] senderName);

/** Redeems one mailed rape using persistent SteamID64 identities. */
native bool Hugs_RedeemMailedRape(
    const char[] senderSteamId64,
    const char[] receiverSteamId64,
    const char[] senderName);

public SharedPlugin __pl_hugs =
{
    name = "hugs",
    file = "hugs.smx",
    required = 0,
};

public void __pl_hugs_SetNTVOptional()
{
    MarkNativeAsOptional("Hugs_GetRapesGiven");
    MarkNativeAsOptional("Hugs_AreStatsLoaded");
    MarkNativeAsOptional("Hugs_RedeemMailedHug");
    MarkNativeAsOptional("Hugs_RedeemMailedRape");
}
