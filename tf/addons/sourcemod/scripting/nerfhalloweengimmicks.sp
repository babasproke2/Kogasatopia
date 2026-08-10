#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <sdkhooks>

#include <tf2>
#include <tf2_stocks>
#include <tf2attributes>

#define PLUGIN_VERSION "1.1"
#define HALLOWEEN_CLEANUP_STUNS 0
#define HALLOWEEN_CLEANUP_SPELLS 1
#define HALLOWEEN_CLEANUP_PUMPKINS 2
#define HALLOWEEN_CLEANUP_COUNT 3

static const char g_HalloweenCleanupClassnames[][] =
{
    "trigger_stun",
    "tf_spell_pickup",
    "tf_pumpkin_bomb"
};

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
    g_cvNerfBosses = CreateConVar("sm_nerfbosses", "1", "Scale damage to Halloween bosses", _, true, 0.0, true, 1.0);
    g_cvBossNerfScale = CreateConVar("sm_bossnerfscale", "4", "Multiply damage to Monoculus/Horsemann/Merasmus by this value", _, true, 0.0, true, 10.0);
    g_cvHalloween = CreateConVar("sm_halloween", "0", "Reference for other plugins to check halloween status", _, true, 0.0, true, 1.0);
    AutoExecConfig(true, "nerfhalloweengimmicks");
    CheckHalloweenStatus(); // This appears 3 times total for certainty
    HookEvent("teamplay_round_active", Event_RoundActive, EventHookMode_Post);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

public void OnConfigsExecuted()
{
    CheckHalloweenStatus(); // This was missing
}

// Entity creation checks

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!IsValidEntity(entity)) return;

    if (IsHalloweenBoss(entity))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnTakeDamage);
    }

    if (!g_cvHalloween.BoolValue) return;

    int cleanupType = -1;
    if (g_cvDisableStuns.BoolValue && StrEqual(classname, g_HalloweenCleanupClassnames[HALLOWEEN_CLEANUP_STUNS], false))
    {
        cleanupType = HALLOWEEN_CLEANUP_STUNS;
    }
    else if (g_cvDisableSpells.BoolValue && StrEqual(classname, g_HalloweenCleanupClassnames[HALLOWEEN_CLEANUP_SPELLS], false))
    {
        cleanupType = HALLOWEEN_CLEANUP_SPELLS;
    }
    else if (g_cvNoPumpkins.BoolValue && StrEqual(classname, g_HalloweenCleanupClassnames[HALLOWEEN_CLEANUP_PUMPKINS], false))
    {
        cleanupType = HALLOWEEN_CLEANUP_PUMPKINS;
    }

    if (cleanupType != -1)
    {
        CreateTimer(0.1, Timer_RemoveHalloweenEntities, cleanupType, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action OnTakeDamage(int entity, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    if (!IsValidEntity(inflictor) || !IsValidEntity(attacker))
        return Plugin_Continue;

    if (!g_cvHalloween.BoolValue)
        return Plugin_Continue;

    char classname[64];
    GetEntityClassname(inflictor, classname, sizeof(classname));
    if (StrEqual(classname, "tf_pumpkin_bomb") && g_cvBetterPumpkins.BoolValue)
    {
        damage *= 0.5;
        if (attacker == entity)
        {
            int melee = GetPlayerWeaponSlot(entity, 2);
            if (melee > MaxClients && IsValidEntity(melee))
            {
                TF2Attrib_SetByName(melee, "rocket jump damage reduction HIDDEN", 0.40);
                RequestFrame(Frame_RemovePumpkinDamageReduction, EntIndexToEntRef(melee));
            }
        }
        return Plugin_Changed;
    }

    // Handle boss damage scaling
    if (g_cvNerfBosses.BoolValue && IsValidEntity(entity) && IsHalloweenBoss(entity))
    {
        damage *= g_cvBossNerfScale.FloatValue;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

void Frame_RemovePumpkinDamageReduction(any entityRef)
{
    int weapon = EntRefToEntIndex(entityRef);
    if (weapon != INVALID_ENT_REFERENCE && IsValidEntity(weapon))
    {
        TF2Attrib_RemoveByName(weapon, "rocket jump damage reduction HIDDEN");
    }
}

public void Event_RoundActive(Event event, const char[] name, bool dontBroadcast)
{
    CheckHalloweenStatus();
    if (g_cvHalloween.BoolValue)
    {
        if (g_cvDisableStuns.BoolValue)
        {
            CreateTimer(0.1, Timer_RemoveHalloweenEntities, HALLOWEEN_CLEANUP_STUNS, TIMER_FLAG_NO_MAPCHANGE);
        }

        if (g_cvDisableSpells.BoolValue)
        {
            CreateTimer(0.1, Timer_RemoveHalloweenEntities, HALLOWEEN_CLEANUP_SPELLS, TIMER_FLAG_NO_MAPCHANGE);
        }
        if (g_cvNoPumpkins.BoolValue)
        {
            CreateTimer(0.1, Timer_RemoveHalloweenEntities, HALLOWEEN_CLEANUP_PUMPKINS, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}

public void CheckHalloweenStatus()
{
    bool found = FindEntityByClassname(-1, "tf_logic_holiday") != -1
        || FindEntityByClassname(-1, "tf_halloween_gift_spawn_location") != -1;
    g_cvHalloween.SetBool(found);

    if (found)
    {
        PrintToServer("[HalloweenLimiter] Halloween map detected");
    }
}

public void TF2_OnConditionAdded(int client, TFCond condition)
{
    if (g_cvMiniCrump.BoolValue
        && g_cvHalloween.BoolValue
        && condition == TFCond_HalloweenCritCandy)
    {
        TF2_RemoveCondition(client, TFCond_HalloweenCritCandy);
        TF2_AddCondition(client, TFCond_CritCola, 4.0);
    }
}

public Action Timer_RemoveHalloweenEntities(Handle timer, any data)
{
    int cleanupType = data;
    if (cleanupType < 0 || cleanupType >= HALLOWEEN_CLEANUP_COUNT)
    {
        return Plugin_Stop;
    }

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, g_HalloweenCleanupClassnames[cleanupType])) != -1)
    {
        AcceptEntityInput(entity, "Kill");
    }
    return Plugin_Stop;
}

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
