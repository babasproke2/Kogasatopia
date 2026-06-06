#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <string>

enum TpaRequestType
{
    TpaRequest_None = 0,
    TpaRequest_Goto,
    TpaRequest_Here
};

ConVar g_cvRequestTimeout;

int g_RequestSender[MAXPLAYERS + 1];
TpaRequestType g_RequestType[MAXPLAYERS + 1];
float g_RequestExpiresAt[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "Teleport Requests",
    author = "Chromatik Moniker, Hombre",
    description = "Allows clients to request teleporting to each other.",
    version = "1.0.0",
    url = "N/A"
};

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
    return HandleTeleportRequest(client, args, TpaRequest_Goto);
}

public Action Command_RequestHere(int client, int args)
{
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
        PrintToChat(client, requestType == TpaRequest_Goto
            ? "[TPA] Usage: !tpa <player>"
            : "[TPA] Usage: !tpahere <player>");
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

    if (target == client)
    {
        PrintToChat(client, "[TPA] You cannot send a teleport request to yourself.");
        return Plugin_Handled;
    }

    if (!IsPlayerAlive(client) || !IsPlayerAlive(target))
    {
        PrintToChat(client, "[TPA] Both players must be alive to request a teleport.");
        return Plugin_Handled;
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

    return Plugin_Handled;
}

void TeleportClientToClient(int client, int target)
{
    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    TeleportEntity(client, targetPos, NULL_VECTOR, NULL_VECTOR);
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
}
