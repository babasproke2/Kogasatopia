#if defined _kogasa_item_indexes_helper_included
    #endinput
#endif
#define _kogasa_item_indexes_helper_included

#include <sourcemod>

stock int ItemIndexes_Parse(const char[] itemKey, int[] indexes, int maxIndexes)
{
    if (maxIndexes <= 0)
    {
        return 0;
    }

    char token[16];
    int count;
    int tokenLength;

    for (int i = 0; ; i++)
    {
        int character = itemKey[i];
        if (character != ',' && character != '\0')
        {
            if (tokenLength < sizeof(token) - 1)
            {
                token[tokenLength++] = character;
            }
            continue;
        }

        token[tokenLength] = '\0';
        TrimString(token);

        bool valid = token[0] != '\0';
        for (int position = 0; valid && token[position] != '\0'; position++)
        {
            valid = IsCharNumeric(token[position]);
        }

        if (valid)
        {
            int index = StringToInt(token);
            if (index > 0)
            {
                indexes[count++] = index;
                if (count >= maxIndexes)
                {
                    return count;
                }
            }
        }

        tokenLength = 0;
        if (character == '\0')
        {
            return count;
        }
    }
}
