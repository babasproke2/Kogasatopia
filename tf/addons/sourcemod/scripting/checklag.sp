#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <multicolors>
#include <plugin_statistics>

#define CHECKLAG_HEALTHY_TICKRATE 65.0

public Plugin myinfo =
{
    name = "CheckLag",
    author = "Hombre",
    description = "Reports the server's current and expected tickrate.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_lag", Command_CheckLag, "Broadcast the server tickrate.");
    RegConsoleCmd("sm_checklag", Command_CheckLag, "Broadcast the server tickrate.");
    RegConsoleCmd("sm_ddos", Command_CheckLag, "Broadcast the server tickrate.");
    AddCommandListener(Listener_Chat, "say");
    AddCommandListener(Listener_Chat, "say_team");
}

bool IsWordCharacter(char value)
{
    return (value >= 'a' && value <= 'z')
        || (value >= 'A' && value <= 'Z')
        || (value >= '0' && value <= '9')
        || value == '_';
}

bool ContainsKeyword(const char[] message, const char[] keyword)
{
    int messageLength = strlen(message);
    int keywordLength = strlen(keyword);
    for (int start = 0; start + keywordLength <= messageLength; start++)
    {
        bool matches = true;
        for (int offset = 0; offset < keywordLength; offset++)
        {
            if (CharToLower(message[start + offset]) != CharToLower(keyword[offset]))
            {
                matches = false;
                break;
            }
        }

        if (matches
            && (start == 0 || !IsWordCharacter(message[start - 1]))
            && (start + keywordLength == messageLength || !IsWordCharacter(message[start + keywordLength])))
        {
            return true;
        }
    }
    return false;
}

bool IsBroadcastCommand(const char[] message)
{
    if (message[0] != '!' && message[0] != '/')
    {
        return false;
    }

    char command[32];
    int write = 0;
    for (int read = 1; message[read] != '\0' && message[read] != ' ' && write < sizeof(command) - 1; read++)
    {
        command[write++] = message[read];
    }
    command[write] = '\0';

    return StrEqual(command, "lag", false)
        || StrEqual(command, "checklag", false)
        || StrEqual(command, "ddos", false);
}

void FormatTickrateMessage(char[] message, int maxlen)
{
    float current = PluginStats_GetObservedTickrate();
    float maximum = PluginStats_GetExpectedTickrate();
    char color[16];
    strcopy(color, sizeof(color), current >= CHECKLAG_HEALTHY_TICKRATE ? "{green}" : "{salmon}");
    Format(message, maxlen, "{gold}[CheckLag]{default} Server tickrate: %s%.1f/%.1f", color, current, maximum);
}

void PrintTickrateToClient(int client)
{
    char message[128];
    FormatTickrateMessage(message, sizeof(message));
    CPrintToChat(client, "%s", message);
}

public Action Listener_Chat(int client, const char[] command, int argc)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    char message[256];
    GetCmdArgString(message, sizeof(message));
    StripQuotes(message);
    TrimString(message);
    if (!IsBroadcastCommand(message)
        && (ContainsKeyword(message, "lag") || ContainsKeyword(message, "ddos")))
    {
        PrintTickrateToClient(client);
    }
    return Plugin_Continue;
}

public Action Command_CheckLag(int client, int args)
{
    char message[128];
    FormatTickrateMessage(message, sizeof(message));
    CPrintToChatAll("%s", message);
    return Plugin_Handled;
}
