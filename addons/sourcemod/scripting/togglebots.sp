#include <sourcemod>

public void OnPluginStart()
{
    RegConsoleCmd("sm_bots", Command_BotToggle, "Allows players to flip bots on and off with a convenient command");
}

public Action Command_BotToggle(int client, int args)
{
    if (client == 0) {
        return Plugin_Continue;
    }

    ConVar botQuota = FindConVar("tf_bot_quota");
    if (botQuota == null) {
        PrintToChat(client, "[Bots] tf_bot_quota not found!");
        return Plugin_Handled;
    }

    int quota = botQuota.IntValue;

    if (quota > 0)
    {
        ServerCommand("exec nobots.cfg");
        PrintToChat(client, "[Bots] Bots disabled (executed nobots.cfg)");
    }
    else
    {
        ServerCommand("exec bots.cfg");
        PrintToChat(client, "[Bots] Bots enabled (executed bots.cfg)");
    }

    return Plugin_Handled;
}
