#if defined _points_store_bonus_labels_included
    #endinput
#endif
#define _points_store_bonus_labels_included

void GetBonusPointsTypeLabel(const char[] type, char[] label, int maxlen)
{
    label[0] = '\0';

    if (StrEqual(type, "airshot", false))
    {
        strcopy(label, maxlen, "Airshot");
    }
    else if (StrEqual(type, "medic_drop", false))
    {
        strcopy(label, maxlen, "Medic drop");
    }
    else if (StrEqual(type, "medic_uber_drop_kill", false))
    {
        strcopy(label, maxlen, "Medic Uber drop Kill");
    }
    else if (StrEqual(type, "airshot_kill", false))
    {
        strcopy(label, maxlen, "Airshot Kill");
    }
    else if (StrEqual(type, "dropshot_kill", false))
    {
        strcopy(label, maxlen, "Dropshot kill");
    }
    else if (StrEqual(type, "meatshot_kill", false))
    {
        strcopy(label, maxlen, "Meatshot kill");
    }
    else if (StrEqual(type, "ambassador_headshot_kill", false))
    {
        strcopy(label, maxlen, "Ambassador headshot kill");
    }
    else if (StrEqual(type, "sandman_cleaver_combo", false))
    {
        strcopy(label, maxlen, "Sandman-Cleaver combo");
    }
    else if (StrEqual(type, "uber_deployed", false))
    {
        strcopy(label, maxlen, "UberCharge");
    }
    else if (StrEqual(type, "market_garden", false) || StrEqual(type, "market_garden_kill", false))
    {
        strcopy(label, maxlen, "Market Garden Kill");
    }
    else if (StrEqual(type, "market_garden_kill_demoman", false))
    {
        strcopy(label, maxlen, "Market Garden Kill (Demoman)");
    }
    else if (StrEqual(type, "demo_sync_kill", false))
    {
        strcopy(label, maxlen, "Demo sync kill");
    }
    else if (StrEqual(type, "soldier_sync_kill", false))
    {
        strcopy(label, maxlen, "Soldier sync kill");
    }
    else if (StrEqual(type, "reflect", false))
    {
        strcopy(label, maxlen, "Reflect");
    }
    else if (StrEqual(type, "reflect_direct_hit", false))
    {
        strcopy(label, maxlen, "Reflect direct hit");
    }
    else if (StrEqual(type, "player_dom", false))
    {
        strcopy(label, maxlen, "Dominating");
    }
    else if (StrEqual(type, "multiple_dominations", false))
    {
        strcopy(label, maxlen, "Multiple dominations");
    }
    else if (StrEqual(type, "player_revenge", false))
    {
        strcopy(label, maxlen, "Revenge");
    }
    else if (StrEqual(type, "killstreak_end", false))
    {
        strcopy(label, maxlen, "Killstreak shut down");
    }
    else if (StrEqual(type, "medic_assists_life", false))
    {
        strcopy(label, maxlen, "Medic assists life");
    }
    else if (StrEqual(type, "top_scoring_player", false))
    {
        strcopy(label, maxlen, "Top-scoring player");
    }
    else if (StrEqual(type, "autobalance_volunteer", false))
    {
        strcopy(label, maxlen, "Autobalance volunteer");
    }
    else if (StrEqual(type, "completion_bonus", false))
    {
        strcopy(label, maxlen, "Completion bonus");
    }
}

void GetMultikillBonusPointsLabel(int kills, char[] label, int maxlen)
{
    label[0] = '\0';

    switch (kills)
    {
        case 3: strcopy(label, maxlen, "Triple Kill");
        case 4: strcopy(label, maxlen, "Quadra Kill");
        case 5: strcopy(label, maxlen, "Penta Kill");
    }
}

void GetBonusPointsFallbackLabel(const char[] type, char[] label, int maxlen)
{
    label[0] = '\0';

    strcopy(label, maxlen, type);
    TrimString(label);
    if (label[0] == '\0')
    {
        return;
    }

    ReplaceString(label, maxlen, "\r", " ", false);
    ReplaceString(label, maxlen, "\n", " ", false);
    ReplaceString(label, maxlen, "\t", " ", false);
    ReplaceString(label, maxlen, "{", "", false);
    ReplaceString(label, maxlen, "}", "", false);
}
