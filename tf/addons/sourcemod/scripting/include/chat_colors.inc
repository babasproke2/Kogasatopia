#if defined _kogasa_chat_colors_helper_included
    #endinput
#endif
#define _kogasa_chat_colors_helper_included

stock void ChatColors_GetTeamTag(int client, char[] output, int maxlen)
{
    switch (GetClientTeam(client))
    {
        case 2: strcopy(output, maxlen, "{red}");
        case 3: strcopy(output, maxlen, "{blue}");
        default: strcopy(output, maxlen, "{default}");
    }
}

stock void ChatColors_ResolveTeamTag(int client, char[] buffer, int maxlen)
{
    if (StrContains(buffer, "{teamcolor}", false) == -1)
    {
        return;
    }

    char colorTag[16];
    ChatColors_GetTeamTag(client, colorTag, sizeof(colorTag));
    ReplaceString(buffer, maxlen, "{teamcolor}", colorTag, false);
}
