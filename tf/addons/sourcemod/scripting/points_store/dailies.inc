#if defined _points_store_dailies_included
    #endinput
#endif
#define _points_store_dailies_included

static const char g_DailyGemLabels[][] =
{
    "2 Meatshot Kills",
    "Kill Enemy Team's Top Scorer",
    "Airshot Kill",
    "Market Garden Kill",
    "Market Garden Kill (Demo)",
    "Ambassador Headshot Kill",
    "4 Headshots",
    "Medic Assists, Every 4",
    "Deploy UberCharge",
    "Multikill, 5+ Kills",
    "Killstreak Milestone, Above 10",
    "Sandman-Cleaver Combo",
    "Dropshot Kill",
    "Airborne Backstab",
    "Demoman Sync Kill",
    "Soldier Sync Kill",
    "Multiple Dominations",
    "Revenge",
    "Reflected Projectile Kill",
    "Reflected Direct Hit Kill",
    "3 UberCharges This Life",
    "Juggle",
    "Multikill, 3-4 Kills",
    "Killstreak Milestone, 5 or 10",
    "End a 7-14 Killstreak",
    "Environmental Kill",
    "Kill a Positive-RTD Player",
    "4 Backstabs",
    "Medic Uber Drop Kill",
    "Kill Medic With at Least 90% Uber",
    "Top-Scoring Player at Round End",
    "End a 15-19 Killstreak",
    "10 Backstabs This Life",
    "10 Headshots This Life",
    "End a 20+ Killstreak",
    "Sandman Moonshot"
};

static const char g_DailyGemTypes[][] =
{
    "meatshot_kills_2",
    "top_score_kill",
    "airshot_kill",
    "market_garden_kill",
    "market_garden_kill_demoman",
    "ambassador_headshot_kill",
    "headshot_kills_life_4",
    "medic_assists",
    "uber_deployed",
    "multikill_5_plus",
    "killstreak_above_10",
    "sandman_cleaver_combo",
    "dropshot_kill",
    "Airborne backstab",
    "demo_sync_kill",
    "soldier_sync_kill",
    "multiple_dominations",
    "player_revenge",
    "reflect",
    "reflect_direct_hit",
    "ubers_life_3",
    "Juggle",
    "multikill_3_4",
    "killstreak_5_10",
    "killstreak_end_7_14",
    "Environmental kill",
    "Killed positive RTD player",
    "backstabs_life_4",
    "medic_uber_drop_kill",
    "medic_high_uber_kill",
    "top_scoring_player",
    "killstreak_end_15_19",
    "backstabs_life_10",
    "headshot_kills_life_10",
    "killstreak_end_20_plus",
    "Sandman moonshot"
};

static const int g_DailyGemLimits[] =
{
    10, 10,
    5, 5, 5, 5,
    4, 4, 4, 4, 4, 4,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    2, 2, 2, 2,
    1, 1, 1, 1
};

void Dailies_OnPluginStart()
{
    RegConsoleCmd("sm_dailies", Command_Dailies, "Show gameplay Gem limits for this map.");
    RegConsoleCmd("sm_limits", Command_Dailies, "Show gameplay Gem limits for this map.");
    AddCommandListener(CommandListener_DailiesAlias, "dailies");
    AddCommandListener(CommandListener_DailiesAlias, "limits");
}

public Action CommandListener_DailiesAlias(int client, const char[] command, int argc)
{
    return Command_Dailies(client, 0);
}

public Action Command_Dailies(int client, int args)
{
    if (!IsClientInGameHuman(client))
    {
        return Plugin_Handled;
    }

    Menu menu = new Menu(MenuHandler_Dailies);
    menu.SetTitle("Gameplay Gem Limits");

    char display[128];
    for (int i = 0; i < sizeof(g_DailyGemLimits); i++)
    {
        int used = GetPerMapAwardCount(client, g_DailyGemTypes[i]);
        if (used > g_DailyGemLimits[i])
        {
            used = g_DailyGemLimits[i];
        }

        FormatEx(display, sizeof(display), "%s (%d/%d)", g_DailyGemLabels[i], used, g_DailyGemLimits[i]);
        menu.AddItem("", display, ITEMDRAW_DISABLED);
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Dailies(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}
