#if defined _kogasa_strings_helper_included
    #endinput
#endif
#define _kogasa_strings_helper_included

stock void Strings_ToLower(char[] buffer, int maxlen)
{
    for (int i = 0; i < maxlen && buffer[i] != '\0'; i++)
    {
        buffer[i] = CharToLower(buffer[i]);
    }
}

stock void Strings_ShiftLeft(char[] buffer, int maxlen, int positions)
{
    int length = strlen(buffer);
    if (positions <= 0 || length == 0)
    {
        return;
    }

    if (positions >= length || positions >= maxlen)
    {
        buffer[0] = '\0';
        return;
    }

    for (int i = 0; i <= length - positions; i++)
    {
        buffer[i] = buffer[i + positions];
    }
}

stock bool Strings_StartsWith(const char[] value, const char[] prefix)
{
    int prefixLength = strlen(prefix);
    for (int i = 0; i < prefixLength; i++)
    {
        if (value[i] == '\0' || value[i] != prefix[i])
        {
            return false;
        }
    }

    return true;
}

stock void Strings_CopyFrom(const char[] source, int startIndex, char[] output, int maxlen)
{
    if (maxlen <= 0)
    {
        return;
    }

    int length = strlen(source);
    if (startIndex >= length)
    {
        output[0] = '\0';
        return;
    }

    int written = 0;
    for (int i = startIndex; i < length && written < maxlen - 1; i++)
    {
        output[written++] = source[i];
    }
    output[written] = '\0';
}
