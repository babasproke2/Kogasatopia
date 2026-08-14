/**
 * SourceMod base ban behavior derived from AlliedModders LLC's basebans plugin.
 * Licensed under the GNU General Public License, version 3.0.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#undef REQUIRE_PLUGIN
#include <adminmenu>
#include <whaletracker_api>
#define REQUIRE_PLUGIN

public Plugin myinfo =
{
    name = "Whale Bans",
    author = "AlliedModders LLC, Hombre",
    description = "Base ban commands with WhaleTracker-aware target ordering.",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

enum struct BanSelection
{
    int targetUserId;
    int duration;
    bool waitingForReason;
}

BanSelection g_BanSelection[MAXPLAYERS + 1];
TopMenu g_AdminMenu = null;
KeyValues g_BanReasons = null;
char g_BanReasonsPath[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int maxlen)
{
    MarkNativeAsOptional("WhaleTracker_GetRankedPlaytimeSeconds");
    return APLRes_Success;
}

public void OnPluginStart()
{
    BuildPath(Path_SM, g_BanReasonsPath, sizeof(g_BanReasonsPath), "configs/banreasons.txt");
    LoadBanReasons();

    LoadTranslations("common.phrases");
    LoadTranslations("basebans.phrases");
    LoadTranslations("core.phrases");

    RegAdminCmd("sm_ban", Command_Ban, ADMFLAG_BAN, "sm_ban <#userid|name> <minutes|0> [reason]");
    RegAdminCmd("sm_banip", Command_BanIp, ADMFLAG_BAN, "sm_banip <ip|#userid|name> <time> [reason]");
    RegAdminCmd("sm_unban", Command_Unban, ADMFLAG_UNBAN, "sm_unban <steamid|ip>");
    RegConsoleCmd("sm_abortban", Command_AbortBan, "Abort a pending custom ban reason.");

    TopMenu topMenu;
    if (LibraryExists("adminmenu") && (topMenu = GetAdminTopMenu()) != null)
    {
        OnAdminMenuReady(topMenu);
    }
}

public void OnPluginEnd()
{
    delete g_BanReasons;
    g_BanReasons = null;
}

public void OnConfigsExecuted()
{
    LoadBanReasons();
}

public void OnClientDisconnect(int client)
{
    ResetBanSelection(client);
}

void ResetBanSelection(int client)
{
    g_BanSelection[client].targetUserId = 0;
    g_BanSelection[client].duration = 0;
    g_BanSelection[client].waitingForReason = false;
}

void LoadBanReasons()
{
    delete g_BanReasons;
    g_BanReasons = new KeyValues("banreasons");

    if (!g_BanReasons.ImportFromFile(g_BanReasonsPath))
    {
        SetFailState("Error in %s: File not found, corrupt or in the wrong format", g_BanReasonsPath);
        return;
    }

    char sectionName[64];
    if (!g_BanReasons.GetSectionName(sectionName, sizeof(sectionName))
        || !StrEqual(sectionName, "banreasons"))
    {
        SetFailState("Error in %s: Couldn't find 'banreasons'", g_BanReasonsPath);
        return;
    }

    g_BanReasons.Rewind();
}

bool IsWhaleTrackerRanked(int client)
{
    return GetFeatureStatus(FeatureType_Native, "WhaleTracker_GetRankedPlaytimeSeconds") == FeatureStatus_Available
        && WhaleTracker_GetRankedPlaytimeSeconds(client) > 0;
}

bool BanTargetComesBefore(
    int left,
    int right,
    bool leftRanked,
    bool rightRanked,
    float leftConnectedTime,
    float rightConnectedTime)
{
    if (leftRanked != rightRanked)
    {
        return !leftRanked;
    }

    if (leftConnectedTime != rightConnectedTime)
    {
        if (leftRanked)
        {
            return leftConnectedTime > rightConnectedTime;
        }
        return leftConnectedTime < rightConnectedTime;
    }

    char leftName[MAX_NAME_LENGTH];
    char rightName[MAX_NAME_LENGTH];
    GetClientName(left, leftName, sizeof(leftName));
    GetClientName(right, rightName, sizeof(rightName));
    return strcmp(leftName, rightName, false) < 0;
}

void FormatConnectedTime(int client, char[] output, int maxlen)
{
    int totalSeconds = RoundToFloor(GetClientTime(client));
    int seconds = totalSeconds % 60;
    int totalMinutes = totalSeconds / 60;

    if (totalMinutes >= 60)
    {
        FormatEx(output, maxlen, "%d:%02d:%02d", totalMinutes / 60, totalMinutes % 60, seconds);
        return;
    }

    FormatEx(output, maxlen, "%d:%02d", totalMinutes, seconds);
}

void DisplayBanTargetMenu(int client)
{
    int targets[MAXPLAYERS + 1];
    bool ranked[MAXPLAYERS + 1];
    float connectedTime[MAXPLAYERS + 1];
    int targetCount;

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || IsFakeClient(target) || !CanUserTarget(client, target))
        {
            continue;
        }

        ranked[target] = IsWhaleTrackerRanked(target);
        connectedTime[target] = GetClientTime(target);

        int insertAt = targetCount;
        while (insertAt > 0)
        {
            int previous = targets[insertAt - 1];
            if (!BanTargetComesBefore(
                target,
                previous,
                ranked[target],
                ranked[previous],
                connectedTime[target],
                connectedTime[previous]))
            {
                break;
            }

            targets[insertAt] = previous;
            insertAt--;
        }

        targets[insertAt] = target;
        targetCount++;
    }

    Menu menu = new Menu(MenuHandler_BanTarget);
    char title[100];
    Format(title, sizeof(title), "%T:", "Ban player", client);
    menu.SetTitle(title);
    menu.ExitBackButton = CheckCommandAccess(client, "sm_admin", ADMFLAG_GENERIC, false);

    for (int index = 0; index < targetCount; index++)
    {
        int target = targets[index];
        char userId[16];
        char connected[24];
        char display[MAX_NAME_LENGTH + 32];
        IntToString(GetClientUserId(target), userId, sizeof(userId));
        FormatConnectedTime(target, connected, sizeof(connected));
        FormatEx(display, sizeof(display), "%N (%s)", target, connected);
        menu.AddItem(userId, display);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanDurationMenu(int client)
{
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    if (target == 0)
    {
        PrintToChat(client, "[SM] %t", "Player no longer available");
        return;
    }

    Menu menu = new Menu(MenuHandler_BanDuration);
    char title[100];
    Format(title, sizeof(title), "%T: %N", "Ban player", client, target);
    menu.SetTitle(title);
    menu.ExitBackButton = true;
    menu.AddItem("0", "Permanent");
    menu.AddItem("10", "10 Minutes");
    menu.AddItem("30", "30 Minutes");
    menu.AddItem("60", "1 Hour");
    menu.AddItem("240", "4 Hours");
    menu.AddItem("1440", "1 Day");
    menu.AddItem("10080", "1 Week");
    menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayBanReasonMenu(int client)
{
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    if (target == 0)
    {
        PrintToChat(client, "[SM] %t", "Player no longer available");
        return;
    }

    Menu menu = new Menu(MenuHandler_BanReason);
    char title[100];
    Format(title, sizeof(title), "%T: %N", "Ban reason", client, target);
    menu.SetTitle(title);
    menu.ExitBackButton = true;
    menu.AddItem("", "Custom reason (type in chat)");

    g_BanReasons.Rewind();
    if (g_BanReasons.GotoFirstSubKey(false))
    {
        do
        {
            char reasonName[100];
            char reason[255];
            g_BanReasons.GetSectionName(reasonName, sizeof(reasonName));
            g_BanReasons.GetString(NULL_STRING, reason, sizeof(reason));
            menu.AddItem(reason, reasonName);
        }
        while (g_BanReasons.GotoNextKey(false));
    }
    g_BanReasons.Rewind();

    menu.Display(client, MENU_TIME_FOREVER);
}

void PerformBan(int client, int target, int duration, const char[] reason)
{
    if (target == 0 || GetClientOfUserId(g_BanSelection[client].targetUserId) != target)
    {
        if (client == 0)
        {
            PrintToServer("[SM] %t", "Player no longer available");
        }
        else
        {
            PrintToChat(client, "[SM] %t", "Player no longer available");
        }
        return;
    }

    char name[MAX_NAME_LENGTH];
    GetClientName(target, name, sizeof(name));
    if (duration == 0)
    {
        if (reason[0])
        {
            ShowActivity(client, "%t", "Permabanned player reason", name, reason);
        }
        else
        {
            ShowActivity(client, "%t", "Permabanned player", name);
        }
    }
    else if (reason[0])
    {
        ShowActivity(client, "%t", "Banned player reason", name, duration, reason);
    }
    else
    {
        ShowActivity(client, "%t", "Banned player", name, duration);
    }

    LogAction(client, target, "\"%L\" banned \"%L\" (minutes \"%d\") (reason \"%s\")", client, target, duration, reason);
    BanClient(
        target,
        duration,
        BANFLAG_AUTO,
        reason[0] ? reason : "Banned",
        reason[0] ? reason : "Banned",
        "sm_ban",
        client);
    ResetBanSelection(client);
}

public Action Command_Ban(int client, int args)
{
    if (args < 2)
    {
        if (GetCmdReplySource() == SM_REPLY_TO_CHAT && client != 0 && args == 0)
        {
            DisplayBanTargetMenu(client);
        }
        else
        {
            ReplyToCommand(client, "[SM] Usage: sm_ban <#userid|name> <minutes|0> [reason]");
        }
        return Plugin_Handled;
    }

    char arguments[256];
    char targetArgument[65];
    char durationArgument[12];
    GetCmdArgString(arguments, sizeof(arguments));

    int offset = BreakString(arguments, targetArgument, sizeof(targetArgument));
    int target = FindTarget(client, targetArgument, true);
    if (target == -1)
    {
        return Plugin_Handled;
    }

    int consumed = BreakString(arguments[offset], durationArgument, sizeof(durationArgument));
    if (consumed != -1)
    {
        offset += consumed;
    }
    else
    {
        offset = 0;
        arguments[0] = '\0';
    }

    g_BanSelection[client].targetUserId = GetClientUserId(target);
    PerformBan(client, target, StringToInt(durationArgument), arguments[offset]);
    return Plugin_Handled;
}

public Action Command_BanIp(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SM] Usage: sm_banip <ip|#userid|name> <time> [reason]");
        return Plugin_Handled;
    }

    char arguments[256];
    char targetArgument[50];
    char durationArgument[20];
    GetCmdArgString(arguments, sizeof(arguments));

    int offset = BreakString(arguments, targetArgument, sizeof(targetArgument));
    int consumed = BreakString(arguments[offset], durationArgument, sizeof(durationArgument));
    if (consumed != -1)
    {
        offset += consumed;
    }
    else
    {
        offset = 0;
        arguments[0] = '\0';
    }

    if (StrEqual(targetArgument, "0"))
    {
        ReplyToCommand(client, "[SM] %t", "Cannot ban that IP");
        return Plugin_Handled;
    }

    char targetName[MAX_TARGET_LENGTH];
    int targetList[1];
    bool targetNameIsMl;
    int target = -1;
    if (ProcessTargetString(
        targetArgument,
        client,
        targetList,
        sizeof(targetList),
        COMMAND_FILTER_CONNECTED | COMMAND_FILTER_NO_MULTI,
        targetName,
        sizeof(targetName),
        targetNameIsMl) > 0)
    {
        target = targetList[0];
    }

    bool hasRcon;
    if (client == 0 || (client == 1 && !IsDedicatedServer()))
    {
        hasRcon = true;
    }
    else
    {
        AdminId admin = GetUserAdmin(client);
        hasRcon = admin != INVALID_ADMIN_ID && GetAdminFlag(admin, Admin_RCON);
    }

    int matchedClient = -1;
    if (target != -1 && !IsFakeClient(target) && (hasRcon || CanUserTarget(client, target)))
    {
        GetClientIP(target, targetArgument, sizeof(targetArgument));
        matchedClient = target;
    }

    if (matchedClient == -1 && !hasRcon)
    {
        ReplyToCommand(client, "[SM] %t", "No Access");
        return Plugin_Handled;
    }

    int duration = StringToInt(durationArgument);
    LogAction(
        client,
        matchedClient,
        "\"%L\" added ban (minutes \"%d\") (ip \"%s\") (reason \"%s\")",
        client,
        duration,
        targetArgument,
        arguments[offset]);
    ReplyToCommand(client, "[SM] %t", "Ban added");
    BanIdentity(targetArgument, duration, BANFLAG_IP, arguments[offset], "sm_banip", client);

    if (matchedClient != -1)
    {
        KickClient(matchedClient, "Banned: %s", arguments[offset]);
    }
    return Plugin_Handled;
}

public Action Command_Unban(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_unban <steamid|ip>");
        return Plugin_Handled;
    }

    char identity[50];
    GetCmdArgString(identity, sizeof(identity));
    ReplaceString(identity, sizeof(identity), "\"", "");

    int banFlags = IsCharNumeric(identity[0]) ? BANFLAG_IP : BANFLAG_AUTHID;
    LogAction(client, -1, "\"%L\" removed ban (filter \"%s\")", client, identity);
    RemoveBan(identity, banFlags, "sm_unban", client);
    ReplyToCommand(client, "[SM] %t", "Removed bans matching", identity);
    return Plugin_Handled;
}

public Action Command_AbortBan(int client, int args)
{
    if (!CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN))
    {
        ReplyToCommand(client, "[SM] %t", "No Access");
        return Plugin_Handled;
    }

    if (!g_BanSelection[client].waitingForReason)
    {
        ReplyToCommand(client, "[SM] %t", "AbortBan not waiting for custom reason");
        return Plugin_Handled;
    }

    g_BanSelection[client].waitingForReason = false;
    ReplyToCommand(client, "[SM] %t", "AbortBan applied successfully");
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] args)
{
    if (!g_BanSelection[client].waitingForReason || IsChatTrigger())
    {
        return Plugin_Continue;
    }

    g_BanSelection[client].waitingForReason = false;
    int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
    PerformBan(client, target, g_BanSelection[client].duration, args);
    return Plugin_Stop;
}

public void OnAdminMenuReady(Handle topMenuHandle)
{
    TopMenu topMenu = TopMenu.FromHandle(topMenuHandle);
    if (topMenu == g_AdminMenu)
    {
        return;
    }

    g_AdminMenu = topMenu;
    TopMenuObject playerCommands = g_AdminMenu.FindCategory(ADMINMENU_PLAYERCOMMANDS);
    if (playerCommands != INVALID_TOPMENUOBJECT)
    {
        g_AdminMenu.AddItem("sm_ban", AdminMenu_Ban, playerCommands, "sm_ban", ADMFLAG_BAN);
    }
}

public void AdminMenu_Ban(
    TopMenu topMenu,
    TopMenuAction action,
    TopMenuObject objectId,
    int client,
    char[] buffer,
    int maxlen)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlen, "%T", "Ban player", client);
    }
    else if (action == TopMenuAction_SelectOption)
    {
        ResetBanSelection(client);
        DisplayBanTargetMenu(client);
    }
}

public int MenuHandler_BanTarget(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack && g_AdminMenu != null)
    {
        g_AdminMenu.Display(client, TopMenuPosition_LastCategory);
    }
    else if (action == MenuAction_Select)
    {
        char userId[16];
        menu.GetItem(selection, userId, sizeof(userId));
        int target = GetClientOfUserId(StringToInt(userId));
        if (target == 0)
        {
            PrintToChat(client, "[SM] %t", "Player no longer available");
        }
        else if (!CanUserTarget(client, target))
        {
            PrintToChat(client, "[SM] %t", "Unable to target");
        }
        else
        {
            g_BanSelection[client].targetUserId = GetClientUserId(target);
            DisplayBanDurationMenu(client);
        }
    }
    return 0;
}

public int MenuHandler_BanDuration(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack)
    {
        DisplayBanTargetMenu(client);
    }
    else if (action == MenuAction_Select)
    {
        char duration[16];
        menu.GetItem(selection, duration, sizeof(duration));
        g_BanSelection[client].duration = StringToInt(duration);
        DisplayBanReasonMenu(client);
    }
    return 0;
}

public int MenuHandler_BanReason(Menu menu, MenuAction action, int client, int selection)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Cancel && selection == MenuCancel_ExitBack)
    {
        DisplayBanDurationMenu(client);
    }
    else if (action == MenuAction_Select)
    {
        if (selection == 0)
        {
            g_BanSelection[client].waitingForReason = true;
            PrintToChat(client, "[SM] %t", "Custom ban reason explanation", "sm_abortban");
        }
        else
        {
            char reason[255];
            menu.GetItem(selection, reason, sizeof(reason));
            int target = GetClientOfUserId(g_BanSelection[client].targetUserId);
            PerformBan(client, target, g_BanSelection[client].duration, reason);
        }
    }
    return 0;
}
