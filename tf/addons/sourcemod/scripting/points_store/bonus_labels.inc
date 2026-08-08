#if defined _points_store_bonus_labels_included
    #endinput
#endif
#define _points_store_bonus_labels_included

void GetBonusPointsTypeLabel(const char[] type, char[] label, int maxlen)
{
    label[0] = '\0';
    RewardDefinition reward;
    if (GetRewardDefinition(type, reward))
    {
        strcopy(label, maxlen, reward.longName);
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
