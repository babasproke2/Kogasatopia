#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2_stocks>
#include <tf_custom_attributes>

#define PLUGIN_VERSION "4.0.0"

#define ATTR_WALL_CLIMB       "wall climb enabled"
#define ATTR_AIRBLAST_JUMP     "airblast jump"
#define DRAGONS_FURY_CLASSNAME "tf_weapon_rocketlauncher_fireball"
#define CLIMB_SOUND            "player/taunt_clip_spin.wav"

#define TF_WEAPON_SLOT_COUNT       5
#define CLIMB_TRACE_DISTANCE       100.0
#define CLIMB_VERTICAL_VELOCITY    600.0
#define MAX_CLIMBABLE_NORMAL_Z     0.5
#define SECONDARY_ATTACK_EPSILON   0.0001
#define STATUS_MESSAGE_INTERVAL    1.0
#define ATTRIBUTE_RECHECK_INTERVAL 1.0
#define ATTRIBUTE_REFRESH_SHORT     0.1
#define ATTRIBUTE_REFRESH_LONG      0.5
#define AIRBLAST_RECOVERY_INTERVAL  1.0

ConVar g_CvarEnabled;
ConVar g_CvarMaxClimbs;
ConVar g_CvarLandingCooldown;
ConVar g_CvarNextClimb;
ConVar g_CvarAirblastVelocity;

bool g_Enabled;
int g_MaxClimbs;
float g_LandingCooldown;
float g_NextClimbDelay;
float g_AirblastVelocity;

bool g_ClientHooksInstalled[MAXPLAYERS + 1];
bool g_WasOnGround[MAXPLAYERS + 1];
int g_ClimbsSinceGround[MAXPLAYERS + 1];
bool g_ClimbedSinceGround[MAXPLAYERS + 1];
float g_ClimbBlockedUntil[MAXPLAYERS + 1];
float g_NextStatusMessageAt[MAXPLAYERS + 1];
int g_LastClimbTick[MAXPLAYERS + 1];

bool g_HasWallClimb[MAXPLAYERS + 1];
bool g_RefreshPending[MAXPLAYERS + 1];
bool g_RefreshFrameQueued;

bool g_AirblastThinkHooked[MAXPLAYERS + 1];
int g_AirblastWeaponRef[MAXPLAYERS + 1];
float g_LastSecondaryAttack[MAXPLAYERS + 1];
float g_NextAirblastAttributeCheck[MAXPLAYERS + 1];
float g_NextAirblastRecoveryRefresh[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "[TF2] Custom Attribute Movement",
    author = "Nanochip, Leonardo, MikeJS, Hombre",
    description = "Wall climbing and Dragon's Fury airblast jumping via TF2 custom attributes.",
    version = PLUGIN_VERSION,
    url = "https://github.com/eltanschauung/Kogasatopia"
};

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_TF2)
    {
        SetFailState("This plugin only supports Team Fortress 2.");
    }

    CreateConVar(
        "sm_playerclimb_version",
        PLUGIN_VERSION,
        "Player climb plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    g_CvarEnabled = CreateConVar(
        "sm_playerclimb_enable",
        "1",
        "Enable wall climbing and airblast jumping.",
        0,
        true,
        0.0,
        true,
        1.0
    );
    g_CvarMaxClimbs = CreateConVar(
        "sm_playerclimb_maxclimbs",
        "0",
        "Maximum airborne wall climbs before landing. 0 disables the limit.",
        0,
        true,
        0.0
    );
    g_CvarLandingCooldown = CreateConVar(
        "sm_playerclimb_cooldown",
        "0.0",
        "Seconds after landing before another wall climb is allowed.",
        0,
        true,
        0.0
    );
    g_CvarNextClimb = CreateConVar(
        "sm_playerclimb_nextclimb",
        "1.56",
        "Seconds before the climbing melee weapon may attack again.",
        0,
        true,
        0.1
    );

    g_CvarAirblastVelocity = FindConVar("tf_flamethrower_burst_zvelocity");
    if (g_CvarAirblastVelocity == null)
    {
        SetFailState("Required convar tf_flamethrower_burst_zvelocity was not found.");
    }

    HookConVarChange(g_CvarEnabled, OnMovementConVarChanged);
    HookConVarChange(g_CvarMaxClimbs, OnMovementConVarChanged);
    HookConVarChange(g_CvarLandingCooldown, OnMovementConVarChanged);
    HookConVarChange(g_CvarNextClimb, OnMovementConVarChanged);
    HookConVarChange(g_CvarAirblastVelocity, OnMovementConVarChanged);
    CacheConVars();

    PrecacheSound(CLIMB_SOUND, true);

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("post_inventory_application", Event_PostInventoryApplication, EventHookMode_Post);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsUsableClient(client))
        {
            InstallClientHooks(client);
            ResetClimbState(client);
            QueueClientRefresh(client);
        }
    }
}

public void OnConfigsExecuted()
{
    CacheConVars();
}

public void OnMapStart()
{
    g_RefreshFrameQueued = false;
    PrecacheSound(CLIMB_SOUND, true);

    for (int client = 1; client <= MaxClients; client++)
    {
        g_RefreshPending[client] = false;

        if (IsUsableClient(client))
        {
            QueueClientRefresh(client);
        }
    }
}

public void OnMapEnd()
{
    g_RefreshFrameQueued = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        g_RefreshPending[client] = false;
    }
}

public void OnClientPutInServer(int client)
{
    ResetClientState(client);
    InstallClientHooks(client);
    QueueClientRefresh(client);
}

public void OnClientDisconnect(int client)
{
    StopAirblastTracking(client);
    ResetClientState(client);
}

public void OnMovementConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    bool wasEnabled = g_Enabled;
    CacheConVars();

    if (wasEnabled == g_Enabled)
    {
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (g_Enabled)
        {
            QueueClientRefresh(client);
        }
        else
        {
            StopAirblastTracking(client);
        }
    }
}

void CacheConVars()
{
    g_Enabled = g_CvarEnabled.BoolValue;
    g_MaxClimbs = g_CvarMaxClimbs.IntValue;
    g_LandingCooldown = g_CvarLandingCooldown.FloatValue;
    g_NextClimbDelay = g_CvarNextClimb.FloatValue;
    g_AirblastVelocity = g_CvarAirblastVelocity.FloatValue;
}

void InstallClientHooks(int client)
{
    if (g_ClientHooksInstalled[client] || !IsClientInGame(client))
    {
        return;
    }

    if (IsClientSourceTV(client) || IsClientReplay(client))
    {
        return;
    }

    SDKHook(client, SDKHook_GroundEntChangedPost, OnGroundEntityChangedPost);
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
    SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDropPost);
    SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    g_ClientHooksInstalled[client] = true;
}

void ResetClientState(int client)
{
    g_ClientHooksInstalled[client] = false;
    g_WasOnGround[client] = false;
    g_ClimbsSinceGround[client] = 0;
    g_ClimbedSinceGround[client] = false;
    g_ClimbBlockedUntil[client] = 0.0;
    g_NextStatusMessageAt[client] = 0.0;
    g_LastClimbTick[client] = -1;

    g_HasWallClimb[client] = false;
    g_RefreshPending[client] = false;

    g_AirblastThinkHooked[client] = false;
    g_AirblastWeaponRef[client] = INVALID_ENT_REFERENCE;
    g_LastSecondaryAttack[client] = 0.0;
    g_NextAirblastAttributeCheck[client] = 0.0;
    g_NextAirblastRecoveryRefresh[client] = 0.0;
}

void ResetClimbState(int client)
{
    g_WasOnGround[client] = IsClientInGame(client)
        && ((GetEntityFlags(client) & FL_ONGROUND) != 0);
    g_ClimbsSinceGround[client] = 0;
    g_ClimbedSinceGround[client] = false;
    g_ClimbBlockedUntil[client] = 0.0;
    g_NextStatusMessageAt[client] = 0.0;
    g_LastClimbTick[client] = -1;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsUsableClient(client))
    {
        return;
    }

    StopAirblastTracking(client);
    ResetClimbState(client);
    QueueClientRefresh(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    StopAirblastTracking(client);
    ResetClimbState(client);
    g_HasWallClimb[client] = false;
}

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsUsableClient(client))
    {
        QueueClientRefreshWithDelays(client);
    }
}

public void OnWeaponEquipPost(int client, int weapon)
{
    if (IsUsableClient(client))
    {
        QueueClientRefreshWithDelays(client);
    }
}

public void OnWeaponDropPost(int client, int weapon)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    if (EntRefToEntIndex(g_AirblastWeaponRef[client]) == weapon)
    {
        StopAirblastTracking(client);
    }

    QueueClientRefresh(client);
}

public void OnWeaponSwitchPost(int client, int weapon)
{
    if (!IsUsableClient(client))
    {
        return;
    }
    ConfigureAirblastTracking(client, weapon);
}

public void OnGroundEntityChangedPost(int client)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;

    if (onGround && !g_WasOnGround[client])
    {
        g_ClimbsSinceGround[client] = 0;

        if (g_ClimbedSinceGround[client] && g_LandingCooldown > 0.0)
        {
            g_ClimbBlockedUntil[client] = GetGameTime() + g_LandingCooldown;
        }

        g_ClimbedSinceGround[client] = false;
    }

    g_WasOnGround[client] = onGround;

    if (onGround)
    {
        int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        ConfigureAirblastTracking(client, activeWeapon);
    }
    else
    {
        int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        ConfigureAirblastTracking(client, activeWeapon);
    }
}

public Action TF2CustAttr_OnKeyValuesAdded(int entity, KeyValues attributes)
{
    if (entity > MaxClients && IsValidEntity(entity))
    {
        RequestFrame(Frame_AttributeEntityReady, EntIndexToEntRef(entity));
    }

    return Plugin_Continue;
}

public void Frame_AttributeEntityReady(any entityRef)
{
    int entity = EntRefToEntIndex(entityRef);
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
    {
        return;
    }

    if (!HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
    {
        return;
    }

    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    if (IsUsableClient(owner))
    {
        QueueClientRefreshWithDelays(owner);
    }
}

void QueueClientRefreshWithDelays(int client)
{
    QueueClientRefresh(client);
    QueueClientRefreshDelayed(client, ATTRIBUTE_REFRESH_SHORT);
    QueueClientRefreshDelayed(client, ATTRIBUTE_REFRESH_LONG);
}

void QueueClientRefreshDelayed(int client, float delay)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    CreateTimer(delay, Timer_RefreshClient, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RefreshClient(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (IsUsableClient(client))
    {
        QueueClientRefresh(client);
    }

    return Plugin_Stop;
}

void QueueClientRefresh(int client)
{
    if (!IsUsableClient(client))
    {
        return;
    }

    if (!g_Enabled)
    {
        g_HasWallClimb[client] = false;
        StopAirblastTracking(client);
        return;
    }

    g_RefreshPending[client] = true;

    if (!g_RefreshFrameQueued)
    {
        g_RefreshFrameQueued = true;
        RequestFrame(Frame_RefreshQueuedClients);
    }
}

public void Frame_RefreshQueuedClients(any data)
{
    g_RefreshFrameQueued = false;

    bool refreshClient[MAXPLAYERS + 1];
    bool anyRefresh = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        refreshClient[client] = false;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_RefreshPending[client])
        {
            continue;
        }

        g_RefreshPending[client] = false;

        if (!IsUsableClient(client))
        {
            continue;
        }

        refreshClient[client] = true;
        anyRefresh = true;
        g_HasWallClimb[client] = HasWallClimbOnWeapon(client);
    }

    if (!anyRefresh)
    {
        return;
    }

    int wearable = -1;
    while ((wearable = FindEntityByClassname(wearable, "tf_wearable")) != -1)
    {
        if (!IsValidEntity(wearable)
            || !HasEntProp(wearable, Prop_Send, "m_hOwnerEntity"))
        {
            continue;
        }

        int owner = GetEntPropEnt(wearable, Prop_Send, "m_hOwnerEntity");
        if (!IsUsableClient(owner)
            || !refreshClient[owner]
            || g_HasWallClimb[owner])
        {
            continue;
        }

        if (TF2CustAttr_GetInt(wearable, ATTR_WALL_CLIMB, 0) > 0)
        {
            g_HasWallClimb[owner] = true;
        }
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!refreshClient[client])
        {
            continue;
        }

        int activeWeapon = -1;
        if (IsPlayerAlive(client))
        {
            activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        }

        ConfigureAirblastTracking(client, activeWeapon);
    }
}

bool HasWallClimbOnWeapon(int client)
{
    for (int slot = 0; slot < TF_WEAPON_SLOT_COUNT; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon > MaxClients
            && IsValidEntity(weapon)
            && TF2CustAttr_GetInt(weapon, ATTR_WALL_CLIMB, 0) > 0)
        {
            return true;
        }
    }

    return false;
}

public Action TF2_CalcIsAttackCritical(
    int client,
    int weapon,
    char[] weaponName,
    bool &result
)
{
    if (!g_Enabled
        || !IsLivingClient(client)
        || !g_HasWallClimb[client]
        || weapon <= MaxClients
        || !IsValidEntity(weapon)
        || weapon != GetPlayerWeaponSlot(client, TFWeaponSlot_Melee))
    {
        return Plugin_Continue;
    }

    TryWallClimb(client, weapon);
    return Plugin_Continue;
}

void TryWallClimb(int client, int weapon)
{
    float now = GetGameTime();

    if (now < g_ClimbBlockedUntil[client])
    {
        ShowClimbStatus(
            client,
            "[SM] Climbing is on cooldown for another %.1f seconds.",
            g_ClimbBlockedUntil[client] - now
        );
        return;
    }

    bool airborne = (GetEntityFlags(client) & FL_ONGROUND) == 0;
    if (airborne
        && g_MaxClimbs > 0
        && g_ClimbsSinceGround[client] >= g_MaxClimbs)
    {
        ShowClimbStatus(
            client,
            "[SM] Touch the ground before climbing again."
        );
        return;
    }

    float hitPosition[3];
    if (!TraceClimbableWall(client, hitPosition))
    {
        return;
    }

    int gameTick = GetGameTickCount();
    if (g_LastClimbTick[client] == gameTick)
    {
        return;
    }
    g_LastClimbTick[client] = gameTick;

    float velocity[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
    velocity[2] = CLIMB_VERTICAL_VELOCITY;
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);

    EmitAmbientSound(CLIMB_SOUND, hitPosition);

    RequestFrame(Frame_SetNextWeaponAttack, EntIndexToEntRef(weapon));
    g_ClimbsSinceGround[client]++;
    g_ClimbedSinceGround[client] = true;
}

bool TraceClimbableWall(int client, float hitPosition[3])
{
    float eyePosition[3];
    float eyeAngles[3];
    float direction[3];
    float endPosition[3];

    GetClientEyePosition(client, eyePosition);
    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, direction, NULL_VECTOR, NULL_VECTOR);

    ScaleVector(direction, CLIMB_TRACE_DISTANCE);
    AddVectors(eyePosition, direction, endPosition);

    Handle trace = TR_TraceRayFilterEx(
        eyePosition,
        endPosition,
        MASK_PLAYERSOLID,
        RayType_EndPoint,
        TraceFilter_IgnoreClient,
        client
    );

    if (trace == null || !TR_DidHit(trace))
    {
        delete trace;
        return false;
    }

    int hitEntity = TR_GetEntityIndex(trace);
    if (!IsClimbableEntity(hitEntity))
    {
        delete trace;
        return false;
    }

    float planeNormal[3];
    TR_GetPlaneNormal(trace, planeNormal);
    if (FloatAbs(planeNormal[2]) > MAX_CLIMBABLE_NORMAL_Z)
    {
        delete trace;
        return false;
    }

    TR_GetEndPosition(hitPosition, trace);
    delete trace;
    return true;
}

bool IsClimbableEntity(int entity)
{
    // World and static-prop traces may report a non-positive entity index.
    if (entity <= 0)
    {
        return true;
    }

    if (!IsValidEntity(entity))
    {
        return false;
    }

    char className[64];
    GetEntityClassname(entity, className, sizeof(className));

    if (StrEqual(className, "worldspawn", false))
    {
        return true;
    }

    // Preserve the legacy behavior: climb non-physics prop_* entities.
    return StrContains(className, "prop_", false) == 0
        && className[5] != 'p';
}

public bool TraceFilter_IgnoreClient(int entity, int contentsMask, any client)
{
    return entity != client;
}

public void Frame_SetNextWeaponAttack(any weaponRef)
{
    int weapon = EntRefToEntIndex(weaponRef);
    if (weapon <= MaxClients || weapon == INVALID_ENT_REFERENCE || !IsValidEntity(weapon))
    {
        return;
    }

    float nextAttack = GetGameTime() + g_NextClimbDelay;
    SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", nextAttack);
    SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", nextAttack);
}

void ShowClimbStatus(int client, const char[] format, any ...)
{
    float now = GetGameTime();
    if (now < g_NextStatusMessageAt[client])
    {
        return;
    }

    char message[192];
    VFormat(message, sizeof(message), format, 3);
    PrintToChat(client, "%s", message);
    g_NextStatusMessageAt[client] = now + STATUS_MESSAGE_INTERVAL;
}

void ConfigureAirblastTracking(int client, int weapon)
{
    if (!g_Enabled)
    {
        StopAirblastTracking(client);
        return;
    }

    if (!IsLivingClient(client))
    {
        StopAirblastTracking(client);
        return;
    }

    if (TF2_GetPlayerClass(client) != TFClass_Pyro)
    {
        StopAirblastTracking(client);
        return;
    }

    if (!IsPotentialAirblastJumpWeapon(weapon))
    {
        StopAirblastTracking(client);
        return;
    }

    bool hasAttribute = HasAirblastJumpAttribute(weapon);
    int weaponRef = EntIndexToEntRef(weapon);
    if (g_AirblastWeaponRef[client] != weaponRef)
    {
        g_AirblastWeaponRef[client] = weaponRef;
        g_LastSecondaryAttack[client] = GetEntPropFloat(
            weapon,
            Prop_Send,
            "m_flNextSecondaryAttack"
        );
        g_NextAirblastAttributeCheck[client] = 0.0;
    }

    if (hasAttribute)
    {
        g_NextAirblastRecoveryRefresh[client] = 0.0;
    }
    else
    {
        QueueAirblastRecoveryRefresh(client);
    }

    SetAirblastThinkHook(client, true);
}

void SetAirblastThinkHook(int client, bool shouldHook)
{
    if (client < 1 || client > MaxClients
        || shouldHook == g_AirblastThinkHooked[client])
    {
        return;
    }

    if (!IsClientInGame(client))
    {
        g_AirblastThinkHooked[client] = false;
        return;
    }

    if (shouldHook)
    {
        SDKHook(client, SDKHook_PostThinkPost, OnAirblastPostThinkPost);
    }
    else
    {
        SDKUnhook(client, SDKHook_PostThinkPost, OnAirblastPostThinkPost);
    }

    g_AirblastThinkHooked[client] = shouldHook;
}

void StopAirblastTracking(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    SetAirblastThinkHook(client, false);

    g_AirblastWeaponRef[client] = INVALID_ENT_REFERENCE;
    g_LastSecondaryAttack[client] = 0.0;
    g_NextAirblastAttributeCheck[client] = 0.0;
    g_NextAirblastRecoveryRefresh[client] = 0.0;
}

bool IsPotentialAirblastJumpWeapon(int weapon)
{
    if (weapon <= MaxClients
        || !IsValidEntity(weapon)
        || !HasEntProp(weapon, Prop_Send, "m_flNextSecondaryAttack"))
    {
        return false;
    }

    char className[64];
    GetEntityClassname(weapon, className, sizeof(className));
    return StrEqual(className, DRAGONS_FURY_CLASSNAME, false);
}

bool HasAirblastJumpAttribute(int weapon)
{
    return TF2CustAttr_GetInt(weapon, ATTR_AIRBLAST_JUMP, 0) > 0;
}

void QueueAirblastRecoveryRefresh(int client)
{
    float now = GetGameTime();
    if (now < g_NextAirblastRecoveryRefresh[client])
    {
        return;
    }

    // CWX can attach custom attributes after equip without firing the normal add forward.
    g_NextAirblastRecoveryRefresh[client] = now + AIRBLAST_RECOVERY_INTERVAL;
    QueueClientRefreshDelayed(client, ATTRIBUTE_REFRESH_SHORT);
    QueueClientRefreshDelayed(client, ATTRIBUTE_REFRESH_LONG);
}

public void OnAirblastPostThinkPost(int client)
{
    if ((GetClientButtons(client) & IN_ATTACK2) == 0)
    {
        return;
    }

    if (!g_Enabled || !IsLivingClient(client))
    {
        StopAirblastTracking(client);
        return;
    }

    int weapon = EntRefToEntIndex(g_AirblastWeaponRef[client]);
    if (weapon == INVALID_ENT_REFERENCE
        || !IsValidEntity(weapon)
        || GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon)
    {
        StopAirblastTracking(client);
        QueueClientRefresh(client);
        return;
    }

    float now = GetGameTime();
    if (now >= g_NextAirblastAttributeCheck[client])
    {
        g_NextAirblastAttributeCheck[client] = now
            + ATTRIBUTE_RECHECK_INTERVAL;

        if (!HasAirblastJumpAttribute(weapon))
        {
            QueueAirblastRecoveryRefresh(client);
            return;
        }

        g_NextAirblastRecoveryRefresh[client] = 0.0;
    }

    float nextSecondaryAttack = GetEntPropFloat(
        weapon,
        Prop_Send,
        "m_flNextSecondaryAttack"
    );

    if (nextSecondaryAttack <= g_LastSecondaryAttack[client]
        + SECONDARY_ATTACK_EPSILON)
    {
        return;
    }
    g_LastSecondaryAttack[client] = nextSecondaryAttack;

    if (GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
    {
        return;
    }

    float maxSpeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");
    if (maxSpeed > 0.0 && maxSpeed < 5.0)
    {
        return;
    }

    if ((GetEntityFlags(client) & FL_ONGROUND) != 0)
    {
        return;
    }
    ApplyAirblastJump(client);
}

void ApplyAirblastJump(int client)
{
    float eyeAngles[3];
    float impulse[3];
    float velocity[3];

    GetClientEyeAngles(client, eyeAngles);
    GetAngleVectors(eyeAngles, impulse, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(impulse, -g_AirblastVelocity);

    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
    AddVectors(velocity, impulse, velocity);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
}

bool IsUsableClient(int client)
{
    return client >= 1
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsClientSourceTV(client)
        && !IsClientReplay(client);
}

bool IsLivingClient(int client)
{
    return IsUsableClient(client) && IsPlayerAlive(client);
}
