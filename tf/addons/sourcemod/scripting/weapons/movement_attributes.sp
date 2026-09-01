#define ATTR_WALL_CLIMB "wall climb enabled"
#define ATTR_AIRBLAST_JUMP "airblast jump"

#define MOVEMENT_DRAGONS_FURY_CLASSNAME "tf_weapon_rocketlauncher_fireball"
#define MOVEMENT_CLIMB_SOUND "player/taunt_clip_spin.wav"

#define MOVEMENT_WEAPON_SLOT_COUNT 5
#define MOVEMENT_CLIMB_TRACE_DISTANCE 100.0
#define MOVEMENT_CLIMB_VERTICAL_VELOCITY 600.0
#define MOVEMENT_MAX_CLIMBABLE_NORMAL_Z 0.5
#define MOVEMENT_SECONDARY_ATTACK_EPSILON 0.0001
#define MOVEMENT_STATUS_MESSAGE_INTERVAL 1.0

ConVar g_WeaponsMovementEnabledCvar;
ConVar g_WeaponsMovementMaxClimbsCvar;
ConVar g_WeaponsMovementLandingCooldownCvar;
ConVar g_WeaponsMovementNextClimbCvar;
ConVar g_WeaponsMovementAirblastVelocityCvar;

bool g_WeaponsMovementEnabled;
int g_WeaponsMovementMaxClimbs;
float g_WeaponsMovementLandingCooldown;
float g_WeaponsMovementNextClimbDelay;
float g_WeaponsMovementAirblastVelocity;

bool g_WeaponsMovementWasOnGround[MAXPLAYERS + 1];
int g_WeaponsMovementClimbsSinceGround[MAXPLAYERS + 1];
bool g_WeaponsMovementClimbedSinceGround[MAXPLAYERS + 1];
float g_WeaponsMovementClimbBlockedUntil[MAXPLAYERS + 1];
float g_WeaponsMovementNextStatusMessageAt[MAXPLAYERS + 1];
int g_WeaponsMovementLastClimbTick[MAXPLAYERS + 1];

bool g_WeaponsMovementAirblastThinkHooked[MAXPLAYERS + 1];
int g_WeaponsMovementAirblastWeaponRef[MAXPLAYERS + 1];
float g_WeaponsMovementLastSecondaryAttack[MAXPLAYERS + 1];

void WeaponsMovement_OnPluginStart()
{
	CreateConVar("sm_playerclimb_version", "4.0.0", "Player climb plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

g_WeaponsMovementEnabledCvar = CreateConVar(
"sm_playerclimb_enable",
"1",
"Enable wall climbing and airblast jumping.",
_,
true,
0.0,
true,
1.0
);
g_WeaponsMovementMaxClimbsCvar = CreateConVar(
"sm_playerclimb_maxclimbs",
"0",
"Maximum airborne wall climbs before landing. 0 disables the limit.",
_,
true,
0.0
);
g_WeaponsMovementLandingCooldownCvar = CreateConVar(
"sm_playerclimb_cooldown",
"0.0",
"Seconds after landing before another wall climb is allowed.",
_,
true,
0.0
);
g_WeaponsMovementNextClimbCvar = CreateConVar(
"sm_playerclimb_nextclimb",
"1.56",
"Seconds before the climbing melee weapon may attack again.",
_,
true,
0.1
);

g_WeaponsMovementAirblastVelocityCvar =
FindConVar("tf_flamethrower_burst_zvelocity");
if (g_WeaponsMovementAirblastVelocityCvar == null)
{
SetFailState("Required convar tf_flamethrower_burst_zvelocity was not found.");
}

g_WeaponsMovementEnabledCvar.AddChangeHook(WeaponsMovement_OnConVarChanged);
g_WeaponsMovementMaxClimbsCvar.AddChangeHook(WeaponsMovement_OnConVarChanged);
g_WeaponsMovementLandingCooldownCvar.AddChangeHook(WeaponsMovement_OnConVarChanged);
g_WeaponsMovementNextClimbCvar.AddChangeHook(WeaponsMovement_OnConVarChanged);
g_WeaponsMovementAirblastVelocityCvar.AddChangeHook(WeaponsMovement_OnConVarChanged);
WeaponsMovement_CacheConVars();

PrecacheSound(MOVEMENT_CLIMB_SOUND, true);
for (int client = 1; client <= MaxClients; client++)
{
if (WeaponsMovement_IsUsableClient(client))
{
WeaponsMovement_OnClientPutInServer(client);
}
}
}

void WeaponsMovement_OnConfigsExecuted()
{
WeaponsMovement_CacheConVars();
}

void WeaponsMovement_OnMapStart()
{
PrecacheSound(MOVEMENT_CLIMB_SOUND, true);
for (int client = 1; client <= MaxClients; client++)
{
WeaponsMovement_ResetClient(client);
if (WeaponsMovement_IsUsableClient(client))
{
WeaponsMovement_ConfigureAirblastTracking(
client,
GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")
);
}
}
}

void WeaponsMovement_OnMapEnd()
{
for (int client = 1; client <= MaxClients; client++)
{
WeaponsMovement_StopAirblastTracking(client);
}
}

void WeaponsMovement_OnClientPutInServer(int client)
{
WeaponsMovement_ResetClient(client);
if (!WeaponsMovement_IsUsableClient(client))
{
return;
}

SDKHook(client, SDKHook_GroundEntChangedPost, WeaponsMovement_OnGroundEntityChangedPost);
}

void WeaponsMovement_OnClientDisconnect(int client)
{
WeaponsMovement_StopAirblastTracking(client);
WeaponsMovement_ResetClient(client);
}

void WeaponsMovement_OnPlayerSpawn(int client)
{
if (!WeaponsMovement_IsUsableClient(client))
{
return;
}

WeaponsMovement_StopAirblastTracking(client);
WeaponsMovement_ResetClimbState(client);
WeaponsMovement_ConfigureAirblastTracking(
client,
GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")
);
}

void WeaponsMovement_OnPlayerDeath(int client)
{
if (client < 1 || client > MaxClients)
{
return;
}

WeaponsMovement_StopAirblastTracking(client);
WeaponsMovement_ResetClimbState(client);
}

void WeaponsMovement_OnItemRuntimeStateReady(int client, int entity)
{
if (!WeaponsMovement_IsUsableClient(client)
|| !Weapons_IsValidWeaponEntity(entity)
|| GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != entity)
{
return;
}

WeaponsMovement_ConfigureAirblastTracking(client, entity);
}

void WeaponsMovement_OnWeaponSwitchPost(int client, int weapon)
{
if (WeaponsMovement_IsUsableClient(client))
{
WeaponsMovement_ConfigureAirblastTracking(client, weapon);
}
}

void WeaponsMovement_OnConVarChanged(
ConVar convar,
const char[] oldValue,
const char[] newValue)
{
#pragma unused convar
#pragma unused oldValue
#pragma unused newValue

bool wasEnabled = g_WeaponsMovementEnabled;
WeaponsMovement_CacheConVars();

if (wasEnabled == g_WeaponsMovementEnabled)
{
return;
}

for (int client = 1; client <= MaxClients; client++)
{
if (!WeaponsMovement_IsUsableClient(client))
{
continue;
}

if (g_WeaponsMovementEnabled)
{
WeaponsMovement_ConfigureAirblastTracking(
client,
GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")
);
}
else
{
WeaponsMovement_StopAirblastTracking(client);
}
}
}

void WeaponsMovement_CacheConVars()
{
g_WeaponsMovementEnabled = g_WeaponsMovementEnabledCvar.BoolValue;
g_WeaponsMovementMaxClimbs = g_WeaponsMovementMaxClimbsCvar.IntValue;
g_WeaponsMovementLandingCooldown =
g_WeaponsMovementLandingCooldownCvar.FloatValue;
g_WeaponsMovementNextClimbDelay =
g_WeaponsMovementNextClimbCvar.FloatValue;
g_WeaponsMovementAirblastVelocity =
g_WeaponsMovementAirblastVelocityCvar.FloatValue;
}

void WeaponsMovement_ResetClient(int client)
{
g_WeaponsMovementWasOnGround[client] = false;
g_WeaponsMovementClimbsSinceGround[client] = 0;
g_WeaponsMovementClimbedSinceGround[client] = false;
g_WeaponsMovementClimbBlockedUntil[client] = 0.0;
g_WeaponsMovementNextStatusMessageAt[client] = 0.0;
g_WeaponsMovementLastClimbTick[client] = -1;
g_WeaponsMovementAirblastThinkHooked[client] = false;
g_WeaponsMovementAirblastWeaponRef[client] = INVALID_ENT_REFERENCE;
g_WeaponsMovementLastSecondaryAttack[client] = 0.0;
}

void WeaponsMovement_ResetClimbState(int client)
{
g_WeaponsMovementWasOnGround[client] = IsClientInGame(client)
&& ((GetEntityFlags(client) & FL_ONGROUND) != 0);
g_WeaponsMovementClimbsSinceGround[client] = 0;
g_WeaponsMovementClimbedSinceGround[client] = false;
g_WeaponsMovementClimbBlockedUntil[client] = 0.0;
g_WeaponsMovementNextStatusMessageAt[client] = 0.0;
g_WeaponsMovementLastClimbTick[client] = -1;
}

public void WeaponsMovement_OnGroundEntityChangedPost(int client)
{
if (!WeaponsMovement_IsUsableClient(client))
{
return;
}

bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
if (onGround && !g_WeaponsMovementWasOnGround[client])
{
g_WeaponsMovementClimbsSinceGround[client] = 0;

if (g_WeaponsMovementClimbedSinceGround[client]
&& g_WeaponsMovementLandingCooldown > 0.0)
{
g_WeaponsMovementClimbBlockedUntil[client] =
GetGameTime() + g_WeaponsMovementLandingCooldown;
}
g_WeaponsMovementClimbedSinceGround[client] = false;
}
g_WeaponsMovementWasOnGround[client] = onGround;
}

Action WeaponsMovement_OnCalcIsAttackCritical(int client, int weapon)
{
if (!g_WeaponsMovementEnabled
|| !WeaponsMovement_IsLivingClient(client)
|| !WeaponsMovement_HasWallClimb(client)
|| !Weapons_IsValidWeaponEntity(weapon)
|| weapon != GetPlayerWeaponSlot(client, TFWeaponSlot_Melee))
{
return Plugin_Continue;
}

WeaponsMovement_TryWallClimb(client, weapon);
return Plugin_Continue;
}

bool WeaponsMovement_HasWallClimb(int client)
{
for (int slot = 0; slot < MOVEMENT_WEAPON_SLOT_COUNT; slot++)
{
int weapon = GetPlayerWeaponSlot(client, slot);
if (Weapons_IsValidWeaponEntity(weapon)
&& TF2CustAttr_GetInt(weapon, ATTR_WALL_CLIMB, 0) > 0)
{
return true;
}
}

int wearable = -1;
while ((wearable = FindEntityByClassname(wearable, "tf_wearable")) != -1)
{
if (IsValidEntity(wearable)
&& HasEntProp(wearable, Prop_Send, "m_hOwnerEntity")
&& GetEntPropEnt(wearable, Prop_Send, "m_hOwnerEntity") == client
&& TF2CustAttr_GetInt(wearable, ATTR_WALL_CLIMB, 0) > 0)
{
return true;
}
}

return false;
}

void WeaponsMovement_TryWallClimb(int client, int weapon)
{
float now = GetGameTime();
if (now < g_WeaponsMovementClimbBlockedUntil[client])
{
WeaponsMovement_ShowClimbStatus(
client,
"[SM] Climbing is on cooldown for another %.1f seconds.",
g_WeaponsMovementClimbBlockedUntil[client] - now
);
return;
}

bool airborne = (GetEntityFlags(client) & FL_ONGROUND) == 0;
if (airborne
&& g_WeaponsMovementMaxClimbs > 0
&& g_WeaponsMovementClimbsSinceGround[client] >= g_WeaponsMovementMaxClimbs)
{
WeaponsMovement_ShowClimbStatus(
client,
"[SM] Touch the ground before climbing again."
);
return;
}

float hitPosition[3];
if (!WeaponsMovement_TraceClimbableWall(client, hitPosition))
{
return;
}

int gameTick = GetGameTickCount();
if (g_WeaponsMovementLastClimbTick[client] == gameTick)
{
return;
}
g_WeaponsMovementLastClimbTick[client] = gameTick;

float velocity[3];
GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
velocity[2] = MOVEMENT_CLIMB_VERTICAL_VELOCITY;
TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
EmitAmbientSound(MOVEMENT_CLIMB_SOUND, hitPosition);

RequestFrame(
WeaponsMovement_SetNextWeaponAttack,
EntIndexToEntRef(weapon)
);
g_WeaponsMovementClimbsSinceGround[client]++;
g_WeaponsMovementClimbedSinceGround[client] = true;
}

bool WeaponsMovement_TraceClimbableWall(int client, float hitPosition[3])
{
float eyePosition[3];
float eyeAngles[3];
float direction[3];
float endPosition[3];
GetClientEyePosition(client, eyePosition);
GetClientEyeAngles(client, eyeAngles);
GetAngleVectors(eyeAngles, direction, NULL_VECTOR, NULL_VECTOR);
ScaleVector(direction, MOVEMENT_CLIMB_TRACE_DISTANCE);
AddVectors(eyePosition, direction, endPosition);

Handle trace = TR_TraceRayFilterEx(
eyePosition,
endPosition,
MASK_PLAYERSOLID,
RayType_EndPoint,
WeaponsMovement_TraceFilterIgnoreClient,
client
);
if (trace == null || !TR_DidHit(trace))
{
delete trace;
return false;
}

int hitEntity = TR_GetEntityIndex(trace);
if (!WeaponsMovement_IsClimbableEntity(hitEntity))
{
delete trace;
return false;
}

float planeNormal[3];
TR_GetPlaneNormal(trace, planeNormal);
if (FloatAbs(planeNormal[2]) > MOVEMENT_MAX_CLIMBABLE_NORMAL_Z)
{
delete trace;
return false;
}

TR_GetEndPosition(hitPosition, trace);
delete trace;
return true;
}

bool WeaponsMovement_IsClimbableEntity(int entity)
{
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
return StrEqual(className, "worldspawn", false)
|| (StrContains(className, "prop_", false) == 0 && className[5] != 'p');
}

public bool WeaponsMovement_TraceFilterIgnoreClient(
int entity,
int contentsMask,
any client)
{
#pragma unused contentsMask
return entity != client;
}

public void WeaponsMovement_SetNextWeaponAttack(any weaponRef)
{
int weapon = EntRefToEntIndex(weaponRef);
if (!Weapons_IsValidWeaponEntity(weapon))
{
return;
}

float nextAttack = GetGameTime() + g_WeaponsMovementNextClimbDelay;
SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", nextAttack);
SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", nextAttack);
}

void WeaponsMovement_ShowClimbStatus(
int client,
const char[] format,
any ...)
{
float now = GetGameTime();
if (now < g_WeaponsMovementNextStatusMessageAt[client])
{
return;
}

char message[192];
VFormat(message, sizeof(message), format, 3);
PrintToChat(client, "%s", message);
g_WeaponsMovementNextStatusMessageAt[client] =
now + MOVEMENT_STATUS_MESSAGE_INTERVAL;
}

void WeaponsMovement_ConfigureAirblastTracking(int client, int weapon)
{
if (!g_WeaponsMovementEnabled
|| !WeaponsMovement_IsLivingClient(client)
|| TF2_GetPlayerClass(client) != TFClass_Pyro
|| !WeaponsMovement_IsAirblastJumpWeapon(weapon))
{
WeaponsMovement_StopAirblastTracking(client);
return;
}

int weaponRef = EntIndexToEntRef(weapon);
if (g_WeaponsMovementAirblastWeaponRef[client] != weaponRef)
{
g_WeaponsMovementAirblastWeaponRef[client] = weaponRef;
g_WeaponsMovementLastSecondaryAttack[client] =
GetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack");
}
WeaponsMovement_SetAirblastThinkHook(client, true);
}

bool WeaponsMovement_IsAirblastJumpWeapon(int weapon)
{
if (!Weapons_IsValidWeaponEntity(weapon)
|| !HasEntProp(weapon, Prop_Send, "m_flNextSecondaryAttack")
|| TF2CustAttr_GetInt(weapon, ATTR_AIRBLAST_JUMP, 0) <= 0)
{
return false;
}

char className[64];
GetEntityClassname(weapon, className, sizeof(className));
return StrEqual(className, MOVEMENT_DRAGONS_FURY_CLASSNAME, false);
}

void WeaponsMovement_SetAirblastThinkHook(int client, bool shouldHook)
{
if (client < 1 || client > MaxClients
|| shouldHook == g_WeaponsMovementAirblastThinkHooked[client])
{
return;
}

if (!IsClientInGame(client))
{
g_WeaponsMovementAirblastThinkHooked[client] = false;
return;
}

if (shouldHook)
{
SDKHook(client, SDKHook_PostThinkPost, WeaponsMovement_OnAirblastPostThinkPost);
}
else
{
SDKUnhook(client, SDKHook_PostThinkPost, WeaponsMovement_OnAirblastPostThinkPost);
}
g_WeaponsMovementAirblastThinkHooked[client] = shouldHook;
}

void WeaponsMovement_StopAirblastTracking(int client)
{
if (client < 1 || client > MaxClients)
{
return;
}

WeaponsMovement_SetAirblastThinkHook(client, false);
g_WeaponsMovementAirblastWeaponRef[client] = INVALID_ENT_REFERENCE;
g_WeaponsMovementLastSecondaryAttack[client] = 0.0;
}

public void WeaponsMovement_OnAirblastPostThinkPost(int client)
{
if ((GetClientButtons(client) & IN_ATTACK2) == 0)
{
return;
}

if (!g_WeaponsMovementEnabled || !WeaponsMovement_IsLivingClient(client))
{
WeaponsMovement_StopAirblastTracking(client);
return;
}

int weapon = EntRefToEntIndex(g_WeaponsMovementAirblastWeaponRef[client]);
if (!WeaponsMovement_IsAirblastJumpWeapon(weapon)
|| GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon)
{
WeaponsMovement_StopAirblastTracking(client);
return;
}

float nextSecondaryAttack =
GetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack");
if (nextSecondaryAttack
<= g_WeaponsMovementLastSecondaryAttack[client]
+ MOVEMENT_SECONDARY_ATTACK_EPSILON)
{
return;
}
g_WeaponsMovementLastSecondaryAttack[client] = nextSecondaryAttack;

if (GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1
|| (GetEntityFlags(client) & FL_ONGROUND) != 0)
{
return;
}

float maxSpeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");
if (maxSpeed > 0.0 && maxSpeed < 5.0)
{
return;
}

float eyeAngles[3];
float impulse[3];
float velocity[3];
GetClientEyeAngles(client, eyeAngles);
GetAngleVectors(eyeAngles, impulse, NULL_VECTOR, NULL_VECTOR);
ScaleVector(impulse, -g_WeaponsMovementAirblastVelocity);
GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
AddVectors(velocity, impulse, velocity);
TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
}

bool WeaponsMovement_IsUsableClient(int client)
{
return client >= 1
&& client <= MaxClients
&& IsClientInGame(client)
&& !IsClientSourceTV(client)
&& !IsClientReplay(client);
}

bool WeaponsMovement_IsLivingClient(int client)
{
return WeaponsMovement_IsUsableClient(client) && IsPlayerAlive(client);
}
