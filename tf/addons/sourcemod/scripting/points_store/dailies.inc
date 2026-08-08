#if defined _points_store_dailies_included
    #endinput
#endif
#define _points_store_dailies_included

#define DAILY_CLASS_ALL 0

static const char g_DailyGemLabels[][] =
{
    "Meatshot Kill",
    "Sandman-Cleaver Combo",
    "8 Meatshot Kills This Life",
    "Sandman Moonshot",
    "Market Garden Kill",
    "Soldier Sync Kill",
    "Reflected Projectile Kill",
    "Reflected Direct Hit Kill",
    "Market Garden Kill (Demo)",
    "Demoman Sync Kill",
    "Every 4 Assists",
    "Deploy UberCharge",
    "3 UberCharges This Life",
    "Every 4 Headshot Kills",
    "Headshot Kill While Falling",
    "10 Headshots This Life",
    "Ambassador Headshot Kill",
    "Airborne Backstab",
    "Every 3 Backstabs This Life",
    "6 Backstabs This Life",
    "Kill Enemy Team's Top Scorer",
    "Airshot Kill",
    "Multikill, 5+ Kills",
    "Killstreak Milestone, Above 10",
    "Multiple Dominations",
    "Revenge",
    "Juggle",
    "Multikill, 3-4 Kills",
    "Killstreak Milestone, 5 or 10",
    "End a 7-14 Killstreak",
    "Environmental Kill",
    "Kill a Positive-RTD Player",
    "Medic Uber Drop Kill",
    "Kill Medic With at Least 90% Uber",
    "Top-Scoring Player at Round End",
    "End a 15-19 Killstreak",
    "End a 20+ Killstreak"
};

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

static const int g_DailyGemLimits[] =
{
    4, 4, 1, 1,
    5, 3,
    3, 3,
    5, 3,
    4, 4, 1,
    4, 3, 1,
    5, 3, 3, 1,
    10, 5, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 1
};

static const int g_DailyGemPoints[] =
{
    1, 1, 3, 3,
    1, 2,
    1, 2,
    1, 1,
    1, 1, 2,
    1, 1, 3,
    1, 1, 1, 3,
    1, 1, 3, 2, 1, 1, 2, 2, 1, 1, 1, 2, 3, 1, 3, 2, 3
};

static const int g_DailyGemClasses[] =
{
    TFClass_Scout, TFClass_Scout, TFClass_Scout, TFClass_Scout,
    TFClass_Soldier, TFClass_Soldier,
    TFClass_Pyro, TFClass_Pyro,
    TFClass_DemoMan, TFClass_DemoMan,
    TFClass_Medic, TFClass_Medic, TFClass_Medic,
    TFClass_Sniper, TFClass_Sniper, TFClass_Sniper,
    TFClass_Spy, TFClass_Spy, TFClass_Spy, TFClass_Spy,
    DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL,
    DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL,
    DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL,
    DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL, DAILY_CLASS_ALL
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
    for (int i = 0; i < sizeof(g_DailyGemLimits); i++)
    {
        if (g_DailyGemClasses[i] != classId)
        {
            continue;
        }

        int used = GetPerMapAwardCount(client, g_DailyGemTypes[i]);
        progress += used < g_DailyGemLimits[i] ? used : g_DailyGemLimits[i];
    }
    return progress;
}

void PrintDailyClassGroup(int client, int classId)
{
    char className[32];
    GetDailyClassName(classId, className, sizeof(className));
    CPrintToChat(client, "{gold} ----- [{green}%s{gold}] -----", className);

    int entryCount = 0;
    char currencyName[BP_CURRENCY_SHORT_MAX];
    for (int i = 0; i < sizeof(g_DailyGemLimits); i++)
    {
        if (g_DailyGemClasses[i] != classId)
        {
            continue;
        }

        int used = GetPerMapAwardCount(client, g_DailyGemTypes[i]);
        if (used > g_DailyGemLimits[i])
        {
            used = g_DailyGemLimits[i];
        }
        GetCurrencyShortLabelForAmount(g_DailyGemPoints[i], currencyName, sizeof(currencyName));
        CPrintToChat(client,
            "{default}%s {gold}(%d/%d){default} - %s%d %s{default}",
            g_DailyGemLabels[i],
            used,
            g_DailyGemLimits[i],
            g_CurrencyColorTag,
            g_DailyGemPoints[i],
            currencyName);
        entryCount++;
    }

    if (entryCount == 0)
    {
        CPrintToChat(client, "{default}No class-specific Gem limits.");
    }
}

public Action Command_Dailies(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    int currentClass = view_as<int>(TF2_GetPlayerClass(client));
    if (currentClass > 0)
    {
        PrintDailyClassGroup(client, currentClass);
    }
    PrintDailyClassGroup(client, DAILY_CLASS_ALL);

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
    return Plugin_Handled;
}
