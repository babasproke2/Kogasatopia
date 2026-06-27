#if defined _adminsdb_api_included
    #endinput
#endif
#define _adminsdb_api_included

#include <sourcemod>

/** Returns whitelist level for a connected client. Positive is whitelist, negative is blacklist, zero is neutral. */
native int AdminsDB_GetClientWhitelistLevel(int client);

/** Returns whitelist level for a Steam2, Steam3, or SteamID64 string. */
native int AdminsDB_GetSteamWhitelistLevel(const char[] steamId);
