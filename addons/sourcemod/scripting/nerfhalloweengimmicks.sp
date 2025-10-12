#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <tf2>
#include <tf2items>
#include <tf2attributes>

#define PLUGIN_VERSION "1.1"
ConVar g_cvDisableStuns;
ConVar g_cvDisableSpells;
ConVar g_cvMiniCrump;
ConVar g_cvNerfBosses;
ConVar g_cvBossNerfScale;
ConVar g_cvBetterPumpkins;
ConVar g_cvNoPumpkins;
ConVar g_cvHalloween;

public Plugin myinfo = {
    name = "Halloween Gimmick Limiter",
    author = "Hombre",
    description = "Nerf or disable features such as pumpkin bombs, crit pumpkins, etc",
    version = PLUGIN_VERSION,
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    g_cvDisableSpells = CreateConVar("sm_nospells", "1", "Disable spells", _, true, 0.0, true, 1.0);
    g_cvDisableStuns = CreateConVar("sm_noghoststuns", "1", "Attempt to disable trigger_stuns (halloween ghost stun), doesn't work on Viaduct Event", _, true, 0.0, true, 1.0);
    g_cvMiniCrump = CreateConVar("sm_minicrumps", "1", "Replace crit pumpkin boost with mini crits", _, true, 0.0, true, 1.0);
    g_cvBetterPumpkins = CreateConVar("sm_betterpumpkins", "1", "Limit pumpkin bomb damage while maintaining launch velocity", _, true, 0.0, true, 1.0);
    g_cvNoPumpkins = CreateConVar("sm_nopumpkins", "0", "Disable exploding pumpkins", _, true, 0.0, true, 1.0);
    g_cvNerfBosses = CreateConVar("sm_nerfbosses", "1", "Multiply damage to Monoculus/Horsemann by 10", _, true, 0.0, true, 1.0);
    g_cvBossNerfScale = CreateConVar("sm_bossnerfscale", "4", "Multiply damage to Monoculus/Horsemann/Merasmus by this value", _, true, 0.0, true, 10.0);
    g_cvHalloween = CreateConVar("sm_halloween", "0", "Reference for other plugins to check halloween status", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "nerfhalloweengimmicks");
    CheckHalloweenStatus(); // This appears 3 times total for certainty
    HookEvent("teamplay_round_active", Event_RoundActive, EventHookMode_Post);
}

public void OnClientPutInServer(int client) {
if (IsClientInGame(client) && (GetConVarInt(g_cvHalloween))) {
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
  }
}

// Entity creation checks

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!GetConVarInt(g_cvHalloween)) return;
    if (!IsValidEntity(entity)) return;

    // Hook the bosses too
    if (IsHalloweenBoss(entity))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }

    if (GetConVarInt(g_cvDisableStuns))
    {
        if (StrEqual(classname, "trigger_stun", false))
        {
            CreateTimer(0.1, Timer_DisableStuns, _, TIMER_FLAG_NO_MAPCHANGE);
            return;
        }
    }

    if (GetConVarInt(g_cvDisableSpells))
    {
        if (StrEqual(classname, "tf_spell_pickup", false))
        {
            CreateTimer(0.1, Timer_KillSpellPickups, _, TIMER_FLAG_NO_MAPCHANGE);
            return;
        }
    }
    if (GetConVarInt(g_cvNoPumpkins))
    {
        if (StrEqual(classname, "tf_pumpkin_bomb", false))
        {
            CreateTimer(0.1, Timer_KillPumpkinBombs, _, TIMER_FLAG_NO_MAPCHANGE);
            return;
        }
    }

}

public Action OnTakeDamage(int entity, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (attacker < 1 || inflictor < 1)
        return Plugin_Continue;

    if (!GetConVarInt(g_cvHalloween))
        return Plugin_Continue;

    // Handle pumpkin bomb damage modification
    if (IsValidEntity(inflictor))
    {
        char classname[64];
        GetEntityClassname(inflictor, classname, sizeof(classname));

        if (StrEqual(classname, "tf_pumpkin_bomb"))
        {
            if (GetConVarInt(g_cvBetterPumpkins))
            {
                damage *= 0.5; // Base damage and therefore velocity reduced by 50% regardless
                if (attacker == entity) // If the player shot the pumpkin himself
                {
                    int weapon3 = GetPlayerWeaponSlot(entity, 2); // We're gonna give the client a gunboats bonus on their melee weapon for this frame
                    if (!IsValidEntity(weapon3)) return Plugin_Continue;
                    TF2Attrib_SetByName(weapon3, "rocket jump damage reduction HIDDEN", 0.40); // Gunboats bonus
                }
                return Plugin_Changed;
            }
        }
    }

    // Handle boss damage scaling
    if (GetConVarInt(g_cvNerfBosses) && IsValidEntity(entity) && IsHalloweenBoss(entity))
    {
        damage *= GetConVarFloat(g_cvBossNerfScale);
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    CheckHalloweenStatus();
    if (GetConVarInt(g_cvHalloween))
    {
        if (GetConVarInt(g_cvDisableStuns))
        {
            // Timer to disable trigger_stun entities
            CreateTimer(0.1, Timer_DisableStuns, _, TIMER_FLAG_NO_MAPCHANGE);
        }

        if (GetConVarInt(g_cvDisableSpells))
        {
            // Timer to kill tf_spell_pickup entities
            CreateTimer(0.1, Timer_KillSpellPickups, _, TIMER_FLAG_NO_MAPCHANGE);
        }
        if (GetConVarInt(g_cvNoPumpkins))
        {
            // Timer to kill tf_spell_pickup entities
            CreateTimer(0.1, Timer_KillPumpkinBombs, _, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}

public void CheckHalloweenStatus()
{
    int entity = -1;
    bool found = false;

    // Check for any of these Halloween-related entities
    entity = FindEntityByClassname(entity, "tf_logic_holiday");
    if (entity != -1) found = true;
    entity = FindEntityByClassname(entity, "tf_halloween_gift_spawn_location");
    if (entity != -1) found = true;

    if (found)
    {
        PrintToServer("[HalloweenLimiter] Halloween map detected");
        SetConVarInt(g_cvHalloween, 1);
    }
}


// Crit pumpkins aka crumpkins

public void TF2_OnConditionAdded(int client, TFCond condition) {      
    if (GetConVarInt(g_cvMiniCrump))
    {
        if (g_cvHalloween)
        {
            if (condition == TFCond_HalloweenCritCandy) //If gas is applied
            {
                TF2_RemoveCondition(client, TFCond_HalloweenCritCandy); //Remove it
                TF2_AddCondition(client, TFCond_CritCola, 4.0); //Replace it with this
            }
        }
    }
}

// Timers

public Action Timer_DisableStuns(Handle timer, any data)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_stun")) != -1)
    {
        AcceptEntityInput(entity, "Kill");
    }
    return Plugin_Stop;
}

public Action Timer_KillSpellPickups(Handle timer, any data)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "tf_spell_pickup")) != -1)
    {
        AcceptEntityInput(entity, "Kill");
    }
    return Plugin_Stop;
}

public Action Timer_KillPumpkinBombs(Handle timer, any data)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "tf_pumpkin_bomb")) != -1)
    {
        AcceptEntityInput(entity, "Kill");
    }
    return Plugin_Stop;
}

// Self explanatory

bool IsHalloweenBoss(int entity)
{
    if (!IsValidEntity(entity))
        return false;

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    return (StrEqual(classname, "eyeball_boss") 
         || StrEqual(classname, "headless_hatman") 
         || StrEqual(classname, "merasmus"));
}
