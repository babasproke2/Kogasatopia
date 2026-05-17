#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>
#include <adt_array>
#include <points_store_api>

// Configuration locations
#define VOTEMENU_CONFIG      "configs/votemenu.cfg"
#define VOTEMENU_CFG_PREFIX  ""          // Files are expected to be relative to tf/cfg

#define VOTE_DURATION 20

enum struct VoteOption
{
    char id[64];
    char name[128];
    char announcer[128];
    char message[256];
    char winFile[128];
    char loseFile[128];
    float ratio;
}

ArrayList g_VoteOptions = null;
VoteOption g_CurrentVote;
bool g_VoteInProgress = false;
ConVar g_CvarShop = null;
ConVar g_CvarShopCost = null;

public Plugin myinfo =
{
    name = "Vote Menu",
    author = "Codex",
    description = "Config-driven yes/no vote executor",
    version = "1.0.0"
};

public void OnPluginStart()
{
    RegAdminCmd("sm_votemenu", Command_VoteMenu, ADMFLAG_GENERIC, "Open the vote menu");
    g_CvarShop = CreateConVar("sm_votemenu_shop", "1", "Require points_store currency to start a votemenu vote when points_store is available.", _, true, 0.0, true, 1.0);
    g_CvarShopCost = CreateConVar("sm_votemenu_shop_cost", "25", "points_store currency cost to start a votemenu vote.", _, true, 0.0);
    g_VoteOptions = new ArrayList(sizeof(VoteOption));
    LoadVoteMenuConfig();
}

public void OnMapStart()
{
    LoadVoteMenuConfig();
}

public Action Command_VoteMenu(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Handled;
    }

    if (g_VoteInProgress || !IsNewVoteAllowed())
    {
        CPrintToChat(client, "{red}[Vote]{default} A vote is already running or cooling down.");
        return Plugin_Handled;
    }

    if (g_VoteOptions.Length == 0)
    {
        CPrintToChat(client, "{red}[Vote]{default} No vote options are configured.");
        return Plugin_Handled;
    }

    Menu menu = new Menu(VoteMenuHandler);
    menu.SetTitle("Start a vote");
    char label[256];
    VoteOption opt;
    for (int i = 0; i < g_VoteOptions.Length; i++)
    {
        g_VoteOptions.GetArray(i, opt);
        char display[256];
        if (opt.name[0])
        {
            strcopy(display, sizeof(display), opt.name);
        }
        else if (opt.message[0])
        {
            strcopy(display, sizeof(display), opt.message);
        }
        else
        {
            strcopy(display, sizeof(display), opt.id);
        }

        Format(label, sizeof(label), "%s", display);
        menu.AddItem(opt.id, label);
    }
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int VoteMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char itemId[64];
        menu.GetItem(param2, itemId, sizeof(itemId));
        int index = FindVoteIndex(itemId);
        if (index == -1)
        {
            CPrintToChat(param1, "{red}[Vote]{default} Invalid vote option.");
            return 0;
        }

        if (g_VoteInProgress || !IsNewVoteAllowed())
        {
            CPrintToChat(param1, "{red}[Vote]{default} A vote is already running or cooling down.");
            return 0;
        }

        if (!ChargeVoteMenuCost(param1))
        {
            return 0;
        }

        g_VoteOptions.GetArray(index, g_CurrentVote);
        StartYesNoVote(param1);
    }
    return 0;
}

static bool IsPointsStoreAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available;
}

static int GetVoteMenuCost()
{
    if (g_CvarShopCost == null)
    {
        return 0;
    }

    int cost = g_CvarShopCost.IntValue;
    return cost > 0 ? cost : 0;
}

static bool ChargeVoteMenuCost(int client)
{
    if (g_CvarShop == null || !g_CvarShop.BoolValue || !IsPointsStoreAvailable())
    {
        return true;
    }

    int cost = GetVoteMenuCost();
    if (cost <= 0)
    {
        return true;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && !PointsStore_AreBonusPointsLoaded(client))
    {
        CPrintToChat(client, "{red}[Vote]{default} Your store balance is still loading.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available)
    {
        int balance = PointsStore_GetBonusPoints(client);
        if (balance < cost)
        {
            CPrintToChat(client, "{red}[Vote]{default} Starting a vote costs {gold}%d{default}; your balance is {lightgreen}%d{default}.", cost, balance);
            return false;
        }
    }

    if (!PointsStore_SpendBonusPoints(client, cost))
    {
        CPrintToChat(client, "{red}[Vote]{default} Could not spend the vote cost.");
        return false;
    }

    CPrintToChat(client, "{green}[Vote]{default} Spent {gold}%d{default} to start the vote.", cost);
    return true;
}

static void StartYesNoVote(int initiator)
{
    if (g_VoteInProgress || !IsNewVoteAllowed())
    {
        CPrintToChat(initiator, "{red}[Vote]{default} A vote is already running or cooling down.");
        return;
    }

    char startMsg[384];
    char announcer[128];
    char detail[256];
    if (g_CurrentVote.announcer[0] != '\0')
    {
        strcopy(announcer, sizeof(announcer), g_CurrentVote.announcer);
    }
    else
    {
        strcopy(announcer, sizeof(announcer), "{green}Someone");
    }
    if (g_CurrentVote.message[0] != '\0')
    {
        strcopy(detail, sizeof(detail), g_CurrentVote.message);
    }
    else
    {
        strcopy(detail, sizeof(detail), g_CurrentVote.id);
    }

    Format(startMsg, sizeof(startMsg), "%s {default}%s", announcer, detail);
    CPrintToChatAll("%s", startMsg);

    Menu vote = new Menu(YesNoVoteHandler, MENU_ACTIONS_ALL);
    char title[256];
    if (g_CurrentVote.name[0])
    {
        strcopy(title, sizeof(title), g_CurrentVote.name);
    }
    else
    {
        strcopy(title, sizeof(title), detail);
    }
    vote.SetTitle("Vote: %s", title);
    vote.AddItem("yes", "Yes");
    vote.AddItem("no", "No");
    vote.ExitButton = false;
    vote.ExitBackButton = false;

    g_VoteInProgress = true;
    vote.DisplayVoteToAll(VOTE_DURATION);
}

public int YesNoVoteHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        g_VoteInProgress = false;
        delete menu;
    }
    else if (action == MenuAction_VoteEnd)
    {
        int winningVotes, totalVotes;
        GetMenuVoteInfo(param2, winningVotes, totalVotes);

        char info[8];
        menu.GetItem(param1, info, sizeof(info));

        int yesVotes = 0;
        int noVotes = 0;
        if (StrEqual(info, "yes"))
        {
            yesVotes = winningVotes;
            noVotes = totalVotes - winningVotes;
        }
        else
        {
            noVotes = winningVotes;
            yesVotes = totalVotes - winningVotes;
        }

        float ratio = (totalVotes > 0) ? float(yesVotes) / float(totalVotes) : 0.0;
        bool passed = (totalVotes > 0) && (ratio >= g_CurrentVote.ratio);

        AnnounceVoteResult(yesVotes, noVotes, ratio, passed);
        ExecuteVoteOutcome(passed);
    }
    else if (action == MenuAction_VoteCancel)
    {
        g_VoteInProgress = false;
        int reason = param1;
        if (reason == VoteCancel_NoVotes)
        {
            CPrintToChatAll("{red}[Vote]{default} Vote failed: no votes received.");
        }
        else
        {
            CPrintToChatAll("{red}[Vote]{default} Vote cancelled.");
        }
    }
    return 0;
}

static void AnnounceVoteResult(int yesVotes, int noVotes, float ratio, bool passed)
{
    char buffer[192];
    Format(buffer, sizeof(buffer), "{green}Yes{default}: %d  {red}No{default}: %d  ({gold}%.0f%% yes{default})", yesVotes, noVotes, ratio * 100.0);
    CPrintToChatAll("%s", buffer);

    if (passed)
    {
        CPrintToChatAll("{green}[Vote]{default} Vote passed.");
    }
    else
    {
        CPrintToChatAll("{red}[Vote]{default} Vote failed.");
    }
}

static void ExecuteVoteOutcome(bool passed)
{
    char script[128];
    if (passed)
    {
        strcopy(script, sizeof(script), g_CurrentVote.winFile);
    }
    else
    {
        strcopy(script, sizeof(script), g_CurrentVote.loseFile);
    }

    if (!script[0])
    {
        return;
    }

    char cmd[192];
    Format(cmd, sizeof(cmd), "exec %s%s", VOTEMENU_CFG_PREFIX, script);
    ServerCommand("%s", cmd);
}

static int FindVoteIndex(const char[] id)
{
    VoteOption opt;
    for (int i = 0; i < g_VoteOptions.Length; i++)
    {
        g_VoteOptions.GetArray(i, opt);
        if (StrEqual(opt.id, id, false))
        {
            return i;
        }
    }
    return -1;
}

static void LoadVoteMenuConfig()
{
    g_VoteOptions.Clear();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s", VOTEMENU_CONFIG);

    KeyValues kv = new KeyValues("votemenu");
    if (!kv.ImportFromFile(path))
    {
        LogError("[votemenu] Failed to read config: %s", path);
        delete kv;
        return;
    }

    if (!kv.GotoFirstSubKey(false))
    {
        delete kv;
        return;
    }

    char section[64];
    do
    {
        kv.GetSectionName(section, sizeof(section));

        VoteOption opt;
        strcopy(opt.id, sizeof(opt.id), section);
        kv.GetString("name", opt.name, sizeof(opt.name), "");
        kv.GetString("announcer", opt.announcer, sizeof(opt.announcer), "");
        kv.GetString("message", opt.message, sizeof(opt.message), section);
        opt.ratio = kv.GetFloat("ratio", 0.6);
        kv.GetString("win", opt.winFile, sizeof(opt.winFile), "");
        // Accept a stray key name if the config has a typo like lose'
        kv.GetString("lose", opt.loseFile, sizeof(opt.loseFile), "");
        if (!opt.loseFile[0])
        {
            kv.GetString("lose'", opt.loseFile, sizeof(opt.loseFile), "");
        }

        g_VoteOptions.PushArray(opt);
    }
    while (kv.GotoNextKey(false));

    delete kv;
}
