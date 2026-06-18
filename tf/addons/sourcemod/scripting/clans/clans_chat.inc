#if defined _clans_chat_included
    #endinput
#endif
#define _clans_chat_included

static void StripClanChatPrefix(const char[] input, char[] output, int maxlen)
{
    static const char plainPrefix[] = "[Clans] ";
    static const char plainPrefixNoSpace[] = "[Clans]";
    static const char defaultPrefix[] = "{default}[Clans] ";
    static const char defaultPrefixNoSpace[] = "{default}[Clans]";
    static const char goldPrefix[] = "{gold}[Clans]{default} ";
    static const char goldPrefixNoSpace[] = "{gold}[Clans]{default}";

    int offset = 0;
    if (StrContains(input, goldPrefix, false) == 0)
    {
        offset = sizeof(goldPrefix) - 1;
    }
    else if (StrContains(input, goldPrefixNoSpace, false) == 0)
    {
        offset = sizeof(goldPrefixNoSpace) - 1;
    }
    else if (StrContains(input, defaultPrefix, false) == 0)
    {
        offset = sizeof(defaultPrefix) - 1;
    }
    else if (StrContains(input, defaultPrefixNoSpace, false) == 0)
    {
        offset = sizeof(defaultPrefixNoSpace) - 1;
    }
    else if (StrContains(input, plainPrefix, false) == 0)
    {
        offset = sizeof(plainPrefix) - 1;
    }
    else if (StrContains(input, plainPrefixNoSpace, false) == 0)
    {
        offset = sizeof(plainPrefixNoSpace) - 1;
    }

    int i = 0;
    while (i < maxlen - 1 && input[offset + i] != '\0')
    {
        output[i] = input[offset + i];
        i++;
    }
    output[i] = '\0';
    TrimString(output);
}

stock void ClansPrintToChatWrapped(int client, const char[] fmt, any ...)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char buffer[512];
    char message[512];
    VFormat(buffer, sizeof(buffer), fmt, 3);
    StripClanChatPrefix(buffer, message, sizeof(message));

    if (StrContains(message, "{teamcolor}", false) != -1)
    {
        CPrintToChatEx(client, client, "{gold}[Clans]{default} %s", message);
        return;
    }

    CPrintToChat(client, "{gold}[Clans]{default} %s", message);
}

stock void ClansReplyToCommandWrapped(int client, const char[] fmt, any ...)
{
    char buffer[512];
    char message[512];
    VFormat(buffer, sizeof(buffer), fmt, 3);
    StripClanChatPrefix(buffer, message, sizeof(message));

    if (client > 0 && IsClientInGame(client))
    {
        if (StrContains(message, "{teamcolor}", false) != -1)
        {
            CPrintToChatEx(client, client, "{gold}[Clans]{default} %s", message);
            return;
        }

        CPrintToChat(client, "{gold}[Clans]{default} %s", message);
        return;
    }

    ReplyToCommand(client, "[Clans] %s", message);
}

stock void ClansCPrintToChatWrapped(int client, const char[] fmt, any ...)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char buffer[512];
    char message[512];
    VFormat(buffer, sizeof(buffer), fmt, 3);
    StripClanChatPrefix(buffer, message, sizeof(message));

    if (StrContains(message, "{teamcolor}", false) != -1)
    {
        CPrintToChatEx(client, client, "{gold}[Clans]{default} %s", message);
        return;
    }

    CPrintToChat(client, "{gold}[Clans]{default} %s", message);
}

stock void ClansCPrintToChatExWrapped(int client, int author, const char[] fmt, any ...)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    char buffer[768];
    char message[768];
    VFormat(buffer, sizeof(buffer), fmt, 4);
    StripClanChatPrefix(buffer, message, sizeof(message));

    if (author > 0 && author <= MaxClients && IsClientInGame(author))
    {
        CPrintToChatEx(client, author, "{gold}[Clans]{default} %s", message);
        return;
    }

    CPrintToChat(client, "{gold}[Clans]{default} %s", message);
}

#define PrintToChat ClansPrintToChatWrapped
#define ReplyToCommand ClansReplyToCommandWrapped
#define CPrintToChat ClansCPrintToChatWrapped
