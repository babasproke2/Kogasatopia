#if defined _kogasa_steam_identity_included
    #endinput
#endif
#define _kogasa_steam_identity_included

#define KOGASA_STEAMID_MAX 32
#define KOGASA_STEAM64_BASE "76561197960265728"

stock bool Kogasa_IsSteamId64(const char[] steamId)
{
    int length = strlen(steamId);
    if (length < 16 || length > 20)
    {
        return false;
    }

    for (int i = 0; i < length; i++)
    {
        if (steamId[i] < '0' || steamId[i] > '9')
        {
            return false;
        }
    }
    return true;
}

stock bool Kogasa_SubtractDecimalStrings(
    const char[] value,
    const char[] base,
    char[] output,
    int maxlen)
{
    int valueLength = strlen(value);
    int baseLength = strlen(base);
    if (valueLength < baseLength
        || (valueLength == baseLength && strcmp(value, base) < 0))
    {
        output[0] = '\0';
        return false;
    }

    char reversed[32];
    int resultLength = 0;
    int borrow = 0;
    int valueIndex = valueLength - 1;
    int baseIndex = baseLength - 1;
    while (valueIndex >= 0)
    {
        int digit = (value[valueIndex] - '0') - borrow;
        int baseDigit = 0;
        if (baseIndex >= 0)
        {
            baseDigit = base[baseIndex] - '0';
        }
        if (digit < baseDigit)
        {
            digit += 10;
            borrow = 1;
        }
        else
        {
            borrow = 0;
        }

        reversed[resultLength++] = view_as<char>('0' + digit - baseDigit);
        valueIndex--;
        baseIndex--;
    }

    while (resultLength > 1 && reversed[resultLength - 1] == '0')
    {
        resultLength--;
    }
    if (resultLength + 1 > maxlen)
    {
        output[0] = '\0';
        return false;
    }

    for (int i = 0; i < resultLength; i++)
    {
        output[i] = reversed[resultLength - i - 1];
    }
    output[resultLength] = '\0';
    return true;
}

stock bool Kogasa_DivideDecimalStringByTwo(
    const char[] value,
    char[] quotient,
    int maxlen,
    int &remainder)
{
    int outputLength = 0;
    int carry = 0;
    int length = strlen(value);
    for (int i = 0; i < length; i++)
    {
        int current = carry * 10 + value[i] - '0';
        int digit = current / 2;
        carry = current % 2;
        if (digit != 0 || outputLength > 0)
        {
            if (outputLength + 1 >= maxlen)
            {
                quotient[0] = '\0';
                return false;
            }
            quotient[outputLength++] = view_as<char>('0' + digit);
        }
    }

    if (outputLength == 0)
    {
        if (maxlen < 2)
        {
            return false;
        }
        quotient[outputLength++] = '0';
    }
    quotient[outputLength] = '\0';
    remainder = carry;
    return true;
}

stock bool Kogasa_ConvertSteamId64ToSteam2(
    const char[] steamId64,
    char[] steamId2,
    int maxlen)
{
    steamId2[0] = '\0';
    if (!Kogasa_IsSteamId64(steamId64))
    {
        return false;
    }

    char accountId[32];
    char accountNumber[32];
    int accountParity;
    if (!Kogasa_SubtractDecimalStrings(
            steamId64,
            KOGASA_STEAM64_BASE,
            accountId,
            sizeof(accountId))
        || !Kogasa_DivideDecimalStringByTwo(
            accountId,
            accountNumber,
            sizeof(accountNumber),
            accountParity))
    {
        return false;
    }

    FormatEx(steamId2, maxlen, "STEAM_0:%d:%s", accountParity, accountNumber);
    return steamId2[0] != '\0';
}

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
