#if defined _kogasa_tf2_included
    #endinput
#endif
#define _kogasa_tf2_included

#include <sdktools>
#include <tf2_stocks>

#include "kogasa_clients.inc"

stock bool Kogasa_ClientOwnsBuilding(int client, const char[] classname)
{
    if (!Kogasa_IsClientInGame(client))
    {
        return false;
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (HasEntProp(entity, Prop_Send, "m_hBuilder")
            && GetEntPropEnt(entity, Prop_Send, "m_hBuilder") == client)
        {
            return true;
        }
    }

    return false;
}

stock bool Kogasa_IsEngineerWithBuildings(int client)
{
    if (!Kogasa_IsClientInGame(client) || TF2_GetPlayerClass(client) != TFClass_Engineer)
    {
        return false;
    }

    return Kogasa_ClientOwnsBuilding(client, "obj_sentrygun")
        || Kogasa_ClientOwnsBuilding(client, "obj_dispenser")
        || Kogasa_ClientOwnsBuilding(client, "obj_teleporter");
}
