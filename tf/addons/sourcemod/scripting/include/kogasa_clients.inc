#if defined _kogasa_clients_included
    #endinput
#endif
#define _kogasa_clients_included

stock bool Kogasa_IsValidClientIndex(int client)
{
    return client > 0 && client <= MaxClients;
}

stock bool Kogasa_IsClientInGame(int client)
{
    return Kogasa_IsValidClientIndex(client) && IsClientInGame(client);
}

stock bool Kogasa_IsHumanClientInGame(int client)
{
    return Kogasa_IsClientInGame(client) && !IsFakeClient(client);
}

stock bool Kogasa_IsAuthorizedHuman(int client)
{
    return Kogasa_IsHumanClientInGame(client) && IsClientAuthorized(client);
}
