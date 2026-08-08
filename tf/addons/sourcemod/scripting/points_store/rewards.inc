#if defined _points_store_rewards_included
    #endinput
#endif
#define _points_store_rewards_included

#define BP_REWARD_ID_MAX 64
#define BP_REWARD_NAME_MAX 96
#define BP_REWARD_SHORT_DESCRIPTION_MAX 160
#define BP_REWARD_LONG_DESCRIPTION_MAX 384

enum struct RewardDefinition
{
    char id[BP_REWARD_ID_MAX];
    int amount;
    int perMapLimit;
    char longName[BP_REWARD_NAME_MAX];
    char shortDescription[BP_REWARD_SHORT_DESCRIPTION_MAX];
    char longDescription[BP_REWARD_LONG_DESCRIPTION_MAX];
}

ArrayList g_RewardDefinitions = null;
StringMap g_RewardIndexes = null;
int g_RewardConfigDepth = 0;
int g_RewardSectionDepth = -1;
int g_RewardEntryDepth = -1;
bool g_RewardConfigInSection = false;
RewardDefinition g_RewardConfigEntry;

void Rewards_OnPluginStart()
{
    g_RewardDefinitions = new ArrayList(sizeof(RewardDefinition));
    g_RewardIndexes = new StringMap();
    LoadRewardDefinitions();
}

void Rewards_OnPluginEnd()
{
    delete g_RewardDefinitions;
    delete g_RewardIndexes;
}

void ResetRewardConfigEntry()
{
    g_RewardConfigEntry.id[0] = '\0';
    g_RewardConfigEntry.amount = 0;
    g_RewardConfigEntry.perMapLimit = 0;
    g_RewardConfigEntry.longName[0] = '\0';
    g_RewardConfigEntry.shortDescription[0] = '\0';
    g_RewardConfigEntry.longDescription[0] = '\0';
}

void LoadRewardDefinitions()
{
    g_RewardDefinitions.Clear();
    g_RewardIndexes.Clear();
    g_RewardConfigDepth = 0;
    g_RewardSectionDepth = -1;
    g_RewardEntryDepth = -1;
    g_RewardConfigInSection = false;
    ResetRewardConfigEntry();

    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/points_store.cfg");

    SMCParser parser = new SMCParser();
    parser.OnEnterSection = RewardConfig_EnterSection;
    parser.OnLeaveSection = RewardConfig_LeaveSection;
    parser.OnKeyValue = RewardConfig_KeyValue;

    int errorLine;
    int errorColumn;
    SMCError result = parser.ParseFile(configPath, errorLine, errorColumn);
    if (result != SMCError_Okay)
    {
        char error[256];
        parser.GetErrorString(result, error, sizeof(error));
        LogError("[points_store] Failed to parse rewards in %s: %s (line %d, column %d)",
            configPath,
            error,
            errorLine,
            errorColumn);
    }
    delete parser;

    LogMessage("[points_store] Loaded %d configured reward(s).", g_RewardDefinitions.Length);
}

public SMCResult RewardConfig_EnterSection(SMCParser parser, const char[] name, bool optQuotes)
{
    g_RewardConfigDepth++;

    if (!g_RewardConfigInSection && StrEqual(name, "rewards", false))
    {
        g_RewardConfigInSection = true;
        g_RewardSectionDepth = g_RewardConfigDepth;
        return SMCParse_Continue;
    }

    if (g_RewardConfigInSection && g_RewardConfigDepth == g_RewardSectionDepth + 1)
    {
        ResetRewardConfigEntry();
        strcopy(g_RewardConfigEntry.id, sizeof(g_RewardConfigEntry.id), name);
        TrimString(g_RewardConfigEntry.id);
        g_RewardEntryDepth = g_RewardConfigDepth;
    }

    return SMCParse_Continue;
}

void StoreParsedRewardDefinition()
{
    if (g_RewardConfigEntry.id[0] == '\0'
        || g_RewardConfigEntry.amount <= 0
        || g_RewardConfigEntry.perMapLimit < 0
        || g_RewardConfigEntry.longName[0] == '\0'
        || g_RewardConfigEntry.shortDescription[0] == '\0'
        || g_RewardConfigEntry.longDescription[0] == '\0')
    {
        LogError("[points_store] Ignoring incomplete reward definition '%s'.", g_RewardConfigEntry.id);
        return;
    }

    int existingIndex;
    if (g_RewardIndexes.GetValue(g_RewardConfigEntry.id, existingIndex))
    {
        LogError("[points_store] Ignoring duplicate reward definition '%s'.", g_RewardConfigEntry.id);
        return;
    }

    int index = g_RewardDefinitions.PushArray(g_RewardConfigEntry, sizeof(g_RewardConfigEntry));
    g_RewardIndexes.SetValue(g_RewardConfigEntry.id, index + 1);
}

public SMCResult RewardConfig_LeaveSection(SMCParser parser)
{
    if (g_RewardConfigInSection && g_RewardConfigDepth == g_RewardEntryDepth)
    {
        StoreParsedRewardDefinition();
        ResetRewardConfigEntry();
        g_RewardEntryDepth = -1;
    }
    else if (g_RewardConfigInSection && g_RewardConfigDepth == g_RewardSectionDepth)
    {
        g_RewardConfigInSection = false;
        g_RewardSectionDepth = -1;
    }

    if (g_RewardConfigDepth > 0)
    {
        g_RewardConfigDepth--;
    }
    return SMCParse_Continue;
}

public SMCResult RewardConfig_KeyValue(
    SMCParser parser,
    const char[] key,
    const char[] value,
    bool keyQuoted,
    bool valueQuoted)
{
    if (!g_RewardConfigInSection || g_RewardConfigDepth != g_RewardEntryDepth)
    {
        return SMCParse_Continue;
    }

    if (StrEqual(key, "reward", false))
    {
        g_RewardConfigEntry.amount = StringToInt(value);
    }
    else if (StrEqual(key, "per_map_limit", false))
    {
        g_RewardConfigEntry.perMapLimit = StringToInt(value);
    }
    else if (StrEqual(key, "long_name", false))
    {
        strcopy(g_RewardConfigEntry.longName, sizeof(g_RewardConfigEntry.longName), value);
        TrimString(g_RewardConfigEntry.longName);
    }
    else if (StrEqual(key, "short_description", false))
    {
        strcopy(g_RewardConfigEntry.shortDescription, sizeof(g_RewardConfigEntry.shortDescription), value);
        TrimString(g_RewardConfigEntry.shortDescription);
    }
    else if (StrEqual(key, "long_description", false))
    {
        strcopy(g_RewardConfigEntry.longDescription, sizeof(g_RewardConfigEntry.longDescription), value);
        TrimString(g_RewardConfigEntry.longDescription);
    }
    return SMCParse_Continue;
}

bool GetRewardDefinition(const char[] rewardId, RewardDefinition definition)
{
    if (g_RewardDefinitions == null || g_RewardIndexes == null || rewardId[0] == '\0')
    {
        return false;
    }

    int storedIndex;
    if (!g_RewardIndexes.GetValue(rewardId, storedIndex) || storedIndex <= 0)
    {
        return false;
    }

    g_RewardDefinitions.GetArray(storedIndex - 1, definition, sizeof(definition));
    return true;
}
