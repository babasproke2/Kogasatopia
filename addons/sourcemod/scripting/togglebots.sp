#include <sourcemod>
#include <files>

ConVar g_cvManualBotQuota;

public Plugin myinfo = {
    name = "TF2 Bot Toggle Command",
    author = "Bad Hombre",
    description = "Toggle TF2 bots on or off conveniently",
    version = "1.3",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    g_cvManualBotQuota = CreateConVar("sm_tf_bot_quota", "8",
        "Manually control bot quotas with Sourcemod, e.g. leaving an entry per-map or per-gamemode file",
        _, true, 0.0, true, 32.0);

    // Hook convar change
    HookConVarChange(g_cvManualBotQuota, OnBotQuotaChanged);

    RegConsoleCmd("sm_bots", Command_BotToggle, "Allows players to toggle bots on and off with a convenient command");

    // Build absolute paths relative to tf/cfg/
    char botsCfg[PLATFORM_MAX_PATH];
    char noBotsCfg[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, botsCfg, sizeof(botsCfg), "../../cfg/bots.cfg");
    BuildPath(Path_SM, noBotsCfg, sizeof(noBotsCfg), "../../cfg/nobots.cfg");

    // Ensure both files exist
    BotConfigFiles(botsCfg, noBotsCfg);
}

// Called whenever sm_tf_bot_quota changes
public void OnBotQuotaChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    int quota = GetConVarInt(g_cvManualBotQuota);
    ServerCommand("tf_bot_quota %i", quota);
    LogMessage("[Bots] sm_tf_bot_quota changed from %s to %s (executed tf_bot_quota %i)", oldValue, newValue, quota);
}

public Action Command_BotToggle(int client, int args)
{
    if (client == 0)
        return Plugin_Continue;

    ConVar botQuota = FindConVar("tf_bot_quota");
    int quota = botQuota.IntValue;

    if (quota > 0)
    {
        ServerCommand("exec nobots.cfg");
        PrintToChat(client, "[Bots] Bots disabled");
    }
    else
    {
        int smQuota = GetConVarInt(g_cvManualBotQuota);
        if (smQuota != 8)
        {
            ServerCommand("tf_bot_quota %i", smQuota);
            PrintToChat(client, "[Bots] Bots enabled, quota %i", smQuota);
            return Plugin_Handled;
        }
        ServerCommand("exec bots.cfg");
        PrintToChat(client, "[Bots] Bots enabled");
    }
    return Plugin_Handled;
}

void BotConfigFiles(const char[] botsCfg, const char[] noBotsCfg)
{
    // bots.cfg defaults
    if (!FileExists(botsCfg))
    {
        File botsFile = OpenFile(botsCfg, "w");
        if (botsFile != null)
        {
            botsFile.WriteLine("// Auto-generated bots.cfg");
            botsFile.WriteLine("tf_bot_difficulty 3");
            botsFile.WriteLine("tf_bot_quota 8");
            botsFile.WriteLine("tf_bot_quota_mode fill");
            botsFile.WriteLine("tf_bot_join_after_player 1");
            botsFile.Close();
            LogMessage("[Bots] Created missing bots.cfg at %s", botsCfg);
        }
    }

    // nobots.cfg defaults
    if (!FileExists(noBotsCfg))
    {
        File noBotsFile = OpenFile(noBotsCfg, "w");
        if (noBotsFile != null)
        {
            noBotsFile.WriteLine("// Auto-generated nobots.cfg");
            noBotsFile.WriteLine("tf_bot_quota 0");
            noBotsFile.Close();
            LogMessage("[Bots] Created missing nobots.cfg at %s", noBotsCfg);
        }
    }
}
