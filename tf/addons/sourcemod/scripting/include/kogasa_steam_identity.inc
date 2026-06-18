#if defined _kogasa_steam_identity_included
    #endinput
#endif
#define _kogasa_steam_identity_included

#define KOGASA_STEAMID_MAX 32

stock bool Kogasa_GetClientSteamId64(int client, char[] steamId, int maxlen, bool validate = true)
{
    steamId[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return false;
    }

    return GetClientAuthId(client, AuthId_SteamID64, steamId, maxlen, validate) && steamId[0] != '\0';
}

stock bool Kogasa_GetClientSteam2(int client, char[] steamId, int maxlen, bool validate = true)
{
    steamId[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return false;
    }

    return GetClientAuthId(client, AuthId_Steam2, steamId, maxlen, validate) && steamId[0] != '\0';
}

stock bool Kogasa_GetClientSteam3(int client, char[] steamId, int maxlen, bool validate = true)
{
    steamId[0] = '\0';

    if (client <= 0 || client > MaxClients || !IsClientConnected(client))
    {
        return false;
    }

    return GetClientAuthId(client, AuthId_Steam3, steamId, maxlen, validate) && steamId[0] != '\0';
}

stock int Kogasa_FindClientBySteamId64(const char[] steamId, bool inGameOnly = true)
{
    if (steamId[0] == '\0')
    {
        return 0;
    }

    char currentSteamId[KOGASA_STEAMID_MAX];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (inGameOnly)
        {
            if (!IsClientInGame(client))
            {
                continue;
            }
        }
        else if (!IsClientConnected(client))
        {
            continue;
        }

        if (Kogasa_GetClientSteamId64(client, currentSteamId, sizeof(currentSteamId), true)
            && StrEqual(currentSteamId, steamId, false))
        {
            return client;
        }
    }

    return 0;
}
