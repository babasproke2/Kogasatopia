#if defined _kogasa_clients_helper_included
    #endinput
#endif
#define _kogasa_clients_helper_included

stock bool Client_IsInGame(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

stock bool Client_IsHumanInGame(int client)
{
    return Client_IsInGame(client) && !IsFakeClient(client);
}
