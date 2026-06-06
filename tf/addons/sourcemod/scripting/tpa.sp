#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <string>
#undef REQUIRE_PLUGIN
#include <points_store_api>
#define REQUIRE_PLUGIN

#define TPA_CURRENCY_SHORT_MAX 32

enum TpaRequestType
{
    TpaRequest_None = 0,
    TpaRequest_Goto,
    TpaRequest_Here
};

ConVar g_cvRequestTimeout;
ConVar g_cvTeleportCost;

int g_RequestSender[MAXPLAYERS + 1];
TpaRequestType g_RequestType[MAXPLAYERS + 1];
float g_RequestExpiresAt[MAXPLAYERS + 1];
TpaRequestType g_MenuRequestType[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "Teleport Requests",
    author = "Chromatik Moniker, Hombre",
    description = "Allows clients to request teleporting to each other.",
    version = "1.0.0",
    url = "N/A"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("PointsStore_AreBonusPointsLoaded");
    MarkNativeAsOptional("PointsStore_GetBonusPoints");
    MarkNativeAsOptional("PointsStore_SpendBonusPoints");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvRequestTimeout = CreateConVar(
        "sm_tpa_request_timeout",
        "30.0",
        "Seconds before a pending teleport request expires.",
        _,
        true,
        1.0,
        true,
        300.0
    );
    g_cvTeleportCost = CreateConVar(
        "sm_tpa_cost",
        "25",
        "points_store currency cost charged to the requester when a teleport request is accepted. 0 disables currency integration.",
        _,
        true,
        0.0
    );

    RegConsoleCmd("sm_tpa", Command_RequestGoto, "Request to teleport to another client.");
    RegConsoleCmd("sm_goto", Command_RequestGoto, "Request to teleport to another client.");
    RegConsoleCmd("sm_tpahere", Command_RequestHere, "Request that another client teleport to you.");
    RegConsoleCmd("sm_bring", Command_RequestHere, "Request that another client teleport to you.");
    RegConsoleCmd("sm_accept", Command_AcceptRequest, "Accept a pending teleport request.");
    RegConsoleCmd("sm_yes", Command_AcceptRequest, "Accept a pending teleport request.");
    RegConsoleCmd("sm_tpaccept", Command_AcceptRequest, "Accept a pending teleport request.");

    ClearAllRequests();
}

public void OnMapStart()
{
    ClearAllRequests();
}

public void OnClientDisconnect(int client)
{
    ClearRequestForReceiver(client);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_RequestSender[i] == client)
        {
            ClearRequestForReceiver(i);
        }
    }
}

public Action Command_RequestGoto(int client, int args)
{
    if (args < 1)
    {
        ShowTeleportModeMenu(client);
        return Plugin_Handled;
    }

    return HandleTeleportRequest(client, args, TpaRequest_Goto);
}

public Action Command_RequestHere(int client, int args)
{
    if (args < 1)
    {
        ShowClientSelectMenu(client, TpaRequest_Here);
        return Plugin_Handled;
    }

    return HandleTeleportRequest(client, args, TpaRequest_Here);
}

public Action Command_AcceptRequest(int client, int args)
{
    if (!IsUsableClient(client))
    {
        return Plugin_Handled;
    }

    int sender = g_RequestSender[client];
    TpaRequestType requestType = g_RequestType[client];
    if (sender <= 0 || requestType == TpaRequest_None)
    {
        PrintToChat(client, "[TPA] You do not have a pending teleport request.");
        return Plugin_Handled;
    }

    if (GetGameTime() > g_RequestExpiresAt[client])
    {
        ClearRequestForReceiver(client);
        PrintToChat(client, "[TPA] Your pending teleport request expired.");
        return Plugin_Handled;
    }

    if (!IsUsableClient(sender))
    {
        ClearRequestForReceiver(client);
        PrintToChat(client, "[TPA] The requester is no longer available.");
        return Plugin_Handled;
    }

    if (!IsPlayerAlive(client) || !IsPlayerAlive(sender))
    {
        ClearRequestForReceiver(client);
        PrintToChat(client, "[TPA] Both players must be alive to teleport.");
        PrintToChat(sender, "[TPA] Teleport request failed because both players must be alive.");
        return Plugin_Handled;
    }

    if (!SpendTeleportCost(sender, client))
    {
        return Plugin_Handled;
    }

    if (requestType == TpaRequest_Goto)
    {
        TeleportClientToClient(sender, client);
        PrintToChat(client, "[TPA] Accepted %N's teleport request.", sender);
        PrintToChat(sender, "[TPA] Teleported to %N.", client);
    }
    else if (requestType == TpaRequest_Here)
    {
        TeleportClientToClient(client, sender);
        PrintToChat(client, "[TPA] Accepted %N's teleport request.", sender);
        PrintToChat(sender, "[TPA] Teleported %N to you.", client);
    }

    ClearRequestForReceiver(client);
    return Plugin_Handled;
}

Action HandleTeleportRequest(int client, int args, TpaRequestType requestType)
{
    if (!IsUsableClient(client))
    {
        return Plugin_Handled;
    }

    if (args < 1)
    {
        if (requestType == TpaRequest_Goto)
        {
            ShowTeleportModeMenu(client);
        }
        else
        {
            ShowClientSelectMenu(client, requestType);
        }

        return Plugin_Handled;
    }

    char targetName[MAX_NAME_LENGTH];
    GetCmdArgString(targetName, sizeof(targetName));
    StripQuotes(targetName);
    TrimString(targetName);

    int matchCount = 0;
    int target = FindClientByNameSubstring(targetName, matchCount);
    if (target <= 0)
    {
        if (matchCount > 1)
        {
            PrintToChat(client, "[TPA] Multiple players matched; use more of the name.");
        }
        else
        {
            PrintToChat(client, "[TPA] Player not found.");
        }
        return Plugin_Handled;
    }

    SendTeleportRequest(client, target, requestType);
    return Plugin_Handled;
}

bool SendTeleportRequest(int client, int target, TpaRequestType requestType)
{
    if (!IsUsableClient(client) || !IsUsableClient(target))
    {
        return false;
    }

    if (target == client)
    {
        PrintToChat(client, "[TPA] You cannot send a teleport request to yourself.");
        return false;
    }

    if (!IsPlayerAlive(client) || !IsPlayerAlive(target))
    {
        PrintToChat(client, "[TPA] Both players must be alive to request a teleport.");
        return false;
    }

    if (!CanPayTeleportCost(client))
    {
        return false;
    }

    g_RequestSender[target] = client;
    g_RequestType[target] = requestType;
    g_RequestExpiresAt[target] = GetGameTime() + g_cvRequestTimeout.FloatValue;

    if (requestType == TpaRequest_Goto)
    {
        PrintToChat(client, "[TPA] Teleport request sent to %N.", target);
        PrintToChat(target, "[TPA] %N wants to teleport to you. Type !accept, !yes, or !tpaccept.", client);
    }
    else
    {
        PrintToChat(client, "[TPA] Teleport-here request sent to %N.", target);
        PrintToChat(target, "[TPA] %N wants to teleport you to them. Type !accept, !yes, or !tpaccept.", client);
    }

    return true;
}

void ShowTeleportModeMenu(int client)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    Menu menu = new Menu(MenuHandler_TeleportMode);

    char currency[TPA_CURRENCY_SHORT_MAX];
    GetTeleportCurrencyShort(currency, sizeof(currency));

    char title[96];
    Format(title, sizeof(title), "Teleport - %d %s", GetTeleportCost(), currency);
    menu.SetTitle(title);

    menu.AddItem("goto", "tpa");
    menu.AddItem("here", "tpahere");
    menu.AddItem("cancel", "cancel");
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_TeleportMode(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        if (!IsUsableClient(client))
        {
            return 0;
        }

        char info[16];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "goto"))
        {
            ShowClientSelectMenu(client, TpaRequest_Goto);
        }
        else if (StrEqual(info, "here"))
        {
            ShowClientSelectMenu(client, TpaRequest_Here);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void ShowClientSelectMenu(int client, TpaRequestType requestType)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    g_MenuRequestType[client] = requestType;

    Menu menu = new Menu(MenuHandler_TeleportClient);
    menu.SetTitle(requestType == TpaRequest_Goto ? "Teleport to player" : "Teleport player here");

    int itemCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsUsableClient(i) || IsFakeClient(i) || i == client)
        {
            continue;
        }

        char userId[16];
        IntToString(GetClientUserId(i), userId, sizeof(userId));

        char display[MAX_NAME_LENGTH];
        GetClientName(i, display, sizeof(display));
        menu.AddItem(userId, display);
        itemCount++;
    }

    if (itemCount == 0)
    {
        delete menu;
        PrintToChat(client, "[TPA] No players are available for teleport requests.");
        return;
    }

    menu.ExitBackButton = true;
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_TeleportClient(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        if (!IsUsableClient(client))
        {
            return 0;
        }

        char info[16];
        menu.GetItem(item, info, sizeof(info));

        int target = GetClientOfUserId(StringToInt(info));
        if (!IsUsableClient(target))
        {
            PrintToChat(client, "[TPA] That player is no longer available.");
            return 0;
        }

        SendTeleportRequest(client, target, g_MenuRequestType[client]);
        g_MenuRequestType[client] = TpaRequest_None;
    }
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        ShowTeleportModeMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void TeleportClientToClient(int client, int target)
{
    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    TeleportEntity(client, targetPos, NULL_VECTOR, NULL_VECTOR);
}

bool CanPayTeleportCost(int client)
{
    int cost = GetTeleportCost();
    if (cost <= 0)
    {
        return true;
    }

    if (!IsPointsStoreAvailable())
    {
        PrintToChat(client, "[TPA] Teleport payments are not ready.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_AreBonusPointsLoaded") == FeatureStatus_Available
        && !PointsStore_AreBonusPointsLoaded(client))
    {
        PrintToChat(client, "[TPA] Your store balance is still loading.");
        return false;
    }

    if (GetFeatureStatus(FeatureType_Native, "PointsStore_GetBonusPoints") == FeatureStatus_Available)
    {
        int balance = PointsStore_GetBonusPoints(client);
        if (balance < cost)
        {
            char currency[TPA_CURRENCY_SHORT_MAX];
            GetTeleportCurrencyShort(currency, sizeof(currency));
            PrintToChat(client, "[TPA] Teleporting costs %d %s; your balance is %d %s.", cost, currency, balance, currency);
            return false;
        }
    }

    return true;
}

bool SpendTeleportCost(int sender, int receiver)
{
    int cost = GetTeleportCost();
    if (cost <= 0)
    {
        return true;
    }

    if (!CanPayTeleportCost(sender))
    {
        PrintToChat(receiver, "[TPA] %N could not pay for the teleport.", sender);
        ClearRequestForReceiver(receiver);
        return false;
    }

    if (!PointsStore_SpendBonusPoints(sender, cost))
    {
        PrintToChat(sender, "[TPA] Teleport payment failed.");
        PrintToChat(receiver, "[TPA] %N could not pay for the teleport.", sender);
        ClearRequestForReceiver(receiver);
        return false;
    }

    char currency[TPA_CURRENCY_SHORT_MAX];
    GetTeleportCurrencyShort(currency, sizeof(currency));
    PrintToChat(sender, "[TPA] Spent %d %s for teleport.", cost, currency);
    return true;
}

int GetTeleportCost()
{
    if (g_cvTeleportCost == null)
    {
        return 0;
    }

    int cost = g_cvTeleportCost.IntValue;
    return cost > 0 ? cost : 0;
}

bool IsPointsStoreAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "PointsStore_SpendBonusPoints") == FeatureStatus_Available;
}

void GetTeleportCurrencyShort(char[] buffer, int maxlen)
{
    ConVar currency = FindConVar("sm_points_store_currency_short");
    if (currency == null)
    {
        strcopy(buffer, maxlen, "Gems");
        return;
    }

    currency.GetString(buffer, maxlen);
    TrimString(buffer);
    if (!buffer[0])
    {
        strcopy(buffer, maxlen, "Gems");
    }
}

int FindClientByNameSubstring(const char[] query, int &matchCount)
{
    matchCount = 0;

    if (!query[0])
    {
        return 0;
    }

    int firstMatch = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsUsableClient(i) || IsFakeClient(i))
        {
            continue;
        }

        char clientName[MAX_NAME_LENGTH];
        GetClientName(i, clientName, sizeof(clientName));

        if (StrEqual(clientName, query, false))
        {
            matchCount = 1;
            return i;
        }

        if (StrContains(clientName, query, false) != -1)
        {
            matchCount++;
            if (firstMatch == 0)
            {
                firstMatch = i;
            }
        }
    }

    return matchCount == 1 ? firstMatch : 0;
}

bool IsUsableClient(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientConnected(client)
        && IsClientInGame(client);
}

void ClearAllRequests()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        ClearRequestForReceiver(i);
    }
}

void ClearRequestForReceiver(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_RequestSender[client] = 0;
    g_RequestType[client] = TpaRequest_None;
    g_RequestExpiresAt[client] = 0.0;
    g_MenuRequestType[client] = TpaRequest_None;
}
