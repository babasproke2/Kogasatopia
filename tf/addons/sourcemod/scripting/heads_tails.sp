#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <morecolors>

#undef REQUIRE_PLUGIN
#include <filters_api>
#define REQUIRE_PLUGIN

public Plugin myinfo =
{
    name = "Heads or Tails",
    author = "Hombre",
    description = "Flips a coin in chat.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int maxlen)
{
    MarkNativeAsOptional("Filters_GetChatName");
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegConsoleCmd("sm_toss", Command_Toss, "Flip a coin.");
    RegConsoleCmd("sm_coinflip", Command_Toss, "Flip a coin.");
    RegConsoleCmd("sm_flip", Command_Toss, "Flip a coin.");
}

public Action Command_Toss(int client, int args)
{
    if (client > 0 && IsClientInGame(client))
    {
        TossCoin(client);
    }
    return Plugin_Handled;
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] args)
{
    if (client <= 0 || IsChatTrigger())
    {
        return;
    }

    if (StrEqual(args, "toss", false) || StrEqual(args, "coinflip", false) || StrEqual(args, "flip", false))
    {
        TossCoin(client);
    }
}

void TossCoin(int client)
{
    char displayName[256];
    BuildCoinFlipDisplayName(client, displayName, sizeof(displayName));

    if (GetRandomInt(0, 1) == 0)
    {
        CPrintToChatAll("%s rolled {gold}Heads!", displayName);
    }
    else
    {
        CPrintToChatAll("%s rolled {grey}Tails!", displayName);
    }
}

void BuildCoinFlipDisplayName(int client, char[] buffer, int maxlen)
{
    if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
        && Filters_GetChatName(client, buffer, maxlen) && buffer[0])
    {
        char teamColor[16];
        switch (GetClientTeam(client))
        {
            case 2: strcopy(teamColor, sizeof(teamColor), "{red}");
            case 3: strcopy(teamColor, sizeof(teamColor), "{blue}");
            default: strcopy(teamColor, sizeof(teamColor), "{gold}");
        }
        ReplaceString(buffer, maxlen, "{teamcolor}", teamColor, false);
        return;
    }

    FormatEx(buffer, maxlen, "{gold}%N{default}", client);
}
