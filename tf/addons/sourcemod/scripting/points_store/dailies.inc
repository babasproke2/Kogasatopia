#if defined _points_store_dailies_included
    #endinput
#endif
#define _points_store_dailies_included

#define DAILY_CLASS_ALL BP_REWARD_CLASS_ALL

static const char g_DailyGemTypes[][] =
{
    "meatshot_kill",
    "sandman_cleaver_combo",
    "meatshot_kills_life_8",
    "Sandman moonshot",
    "market_garden_kill",
    "soldier_sync_kill",
    "reflect",
    "reflect_direct_hit",
    "market_garden_kill_demoman",
    "demo_sync_kill",
    "medic_assists",
    "uber_deployed",
    "ubers_life_3",
    "headshot_kills_life_4",
    "dropshot_kill",
    "headshot_kills_life_10",
    "ambassador_headshot_kill",
    "Airborne backstab",
    "backstabs_life_3",
    "backstabs_life_6",
    "top_score_kill",
    "airshot_kill",
    "multikill_5_plus",
    "killstreak_above_10",
    "multiple_dominations",
    "player_revenge",
    "Juggle",
    "multikill_3_4",
    "killstreak_5_10",
    "killstreak_end_7_14",
    "Environmental kill",
    "Killed positive RTD player",
    "medic_uber_drop_kill",
    "medic_high_uber_kill",
    "top_scoring_player",
    "killstreak_end_15_19",
    "killstreak_end_20_plus"
};

void Dailies_OnPluginStart()
{
    RegConsoleCmd("sm_dailies", Command_Dailies, "Show gameplay Gem limits for this map.");
    RegConsoleCmd("sm_limits", Command_Dailies, "Show gameplay Gem limits for this map.");
    RegConsoleCmd("sm_daily", Command_Dailies, "Show gameplay Gem limits for this map.");
    RegConsoleCmd("sm_limit", Command_Dailies, "Show gameplay Gem limits for this map.");
    AddCommandListener(CommandListener_DailiesAlias, "dailies");
    AddCommandListener(CommandListener_DailiesAlias, "limits");
    AddCommandListener(CommandListener_DailiesAlias, "daily");
    AddCommandListener(CommandListener_DailiesAlias, "limit");
}

public Action CommandListener_DailiesAlias(int client, const char[] command, int argc)
{
    return Command_Dailies(client, 0);
}

void GetDailyClassName(int classId, char[] name, int maxlen)
{
    switch (classId)
    {
        case TFClass_Scout: strcopy(name, maxlen, "Scout");
        case TFClass_Soldier: strcopy(name, maxlen, "Soldier");
        case TFClass_Pyro: strcopy(name, maxlen, "Pyro");
        case TFClass_DemoMan: strcopy(name, maxlen, "Demoman");
        case TFClass_Heavy: strcopy(name, maxlen, "Heavy");
        case TFClass_Engineer: strcopy(name, maxlen, "Engineer");
        case TFClass_Medic: strcopy(name, maxlen, "Medic");
        case TFClass_Sniper: strcopy(name, maxlen, "Sniper");
        case TFClass_Spy: strcopy(name, maxlen, "Spy");
        default: strcopy(name, maxlen, "All Class");
    }
}

int GetDailyClassProgress(int client, int classId)
{
    int progress = 0;
    for (int i = 0; i < sizeof(g_DailyGemTypes); i++)
    {
        RewardDefinition reward;
        if (!GetRewardDefinition(g_DailyGemTypes[i], reward))
        {
            continue;
        }
        if (reward.classId != classId)
        {
            continue;
        }
        int used = GetPerMapAwardCount(client, g_DailyGemTypes[i]);
        progress += used < reward.perMapLimit ? used : reward.perMapLimit;
    }
    return progress;
}

void PrintDailyClassGroup(int client, int classId)
{
    char className[32];
    GetDailyClassName(classId, className, sizeof(className));
    CPrintToChat(client, "{gold} ----- [{green}%s{gold}] -----", className);

    int entryCount = 0;
    for (int i = 0; i < sizeof(g_DailyGemTypes); i++)
    {
        RewardDefinition reward;
        if (!GetRewardDefinition(g_DailyGemTypes[i], reward))
        {
            continue;
        }
        if (reward.classId != classId)
        {
            continue;
        }
        int used = GetPerMapAwardCount(client, g_DailyGemTypes[i]);
        if (used > reward.perMapLimit)
        {
            used = reward.perMapLimit;
        }
        CPrintToChat(client,
            "{default}%s {gold}(%d/%d){default} {limegreen}+%d{default}",
            reward.longName,
            used,
            reward.perMapLimit,
            reward.amount);
        entryCount++;
    }

    if (entryCount == 0)
    {
        CPrintToChat(client, "{default}No class-specific Gem limits.");
    }
}

public Action Command_Dailies(int client, int args)
{
    if (!Client_IsHumanInGame(client))
    {
        return Plugin_Handled;
    }
    if (!g_PerMapAwardsReady)
    {
        CPrintToChat(client, "%s Per-map reward progress is still loading.", g_CurrencyPrefix);
        return Plugin_Handled;
    }

    int currentClass = view_as<int>(TF2_GetPlayerClass(client));
    int classOrder[] =
    {
        TFClass_Scout,
        TFClass_Soldier,
        TFClass_Pyro,
        TFClass_DemoMan,
        TFClass_Heavy,
        TFClass_Engineer,
        TFClass_Medic,
        TFClass_Sniper,
        TFClass_Spy
    };
    bool printed[sizeof(classOrder)];
    for (int position = 0; position < sizeof(classOrder); position++)
    {
        int bestIndex = -1;
        int bestProgress = 0;
        for (int i = 0; i < sizeof(classOrder); i++)
        {
            if (printed[i] || classOrder[i] == currentClass)
            {
                continue;
            }

            int progress = GetDailyClassProgress(client, classOrder[i]);
            if (progress > bestProgress)
            {
                bestProgress = progress;
                bestIndex = i;
            }
        }

        if (bestIndex == -1)
        {
            break;
        }
        printed[bestIndex] = true;
        PrintDailyClassGroup(client, classOrder[bestIndex]);
    }

    PrintDailyClassGroup(client, DAILY_CLASS_ALL);
    if (currentClass > 0)
    {
        PrintDailyClassGroup(client, currentClass);
    }
    return Plugin_Handled;
}
