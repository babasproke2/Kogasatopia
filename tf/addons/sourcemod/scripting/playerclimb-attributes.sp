#pragma semicolon 1

#include <sourcemod>
#include <tf2_stocks>
#include <tf_custom_attributes>
#include <sdkhooks>
#include <clientprefs>

#define PLUGIN_VERSION "3.0"

new Handle:cvarEnable, Handle:cvarMaxClimbs, Handle:cvarCooldown, Handle:cvarNextClimb;
new maxClimbs[MAXPLAYERS+1] = {0, ...};
new bool:gClimb[MAXPLAYERS+1][9];
new bool:justClimbed[MAXPLAYERS+1] = {false, ...};
new bool:blockClimb[MAXPLAYERS+1] = {false, ...};

//Pyro airblast jump code begins here

new Handle:tf_flamethrower_burst_zvelocity = INVALID_HANDLE;
new bool:bPluginEnabled = true;
new Float:flZVelocity = 0.0;
new Float:flNextSecondaryAttack[MAXPLAYERS+1];
new Handle:fwOnPyroAirBlast = INVALID_HANDLE;

public Plugin:myinfo = {
	name		= "New Player Movement",
	author		= "Nanochip + Leonardo + MikeJS + Hombre",
	description = "Cust attrs for airblast jump and melee wall climb",
	version		= PLUGIN_VERSION,
	url			= "http://thecubeserver.org/"
};

// This fork of the plugin is designed to be used with tf2custattr for cwx
// It's a combination of an airblast jumping plugin and a wall climb plugin
// Since I don't want to hook OnGameFrame often.

public OnConfigsExecuted()
{
    flZVelocity = GetConVarFloat( tf_flamethrower_burst_zvelocity );
}

public OnClientPutInServer( iClient )
{
    flNextSecondaryAttack[iClient] = GetGameTime();
    SDKHook( iClient, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost );
}

public OnPluginStart()
{
	CreateConVar("sm_playerclimb_version", PLUGIN_VERSION, "Player Climb Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_UNLOGGED|FCVAR_DONTRECORD|FCVAR_REPLICATED|FCVAR_NOTIFY);
	cvarEnable = CreateConVar("sm_playerclimb_enable", "1", "Enable the plugin? 1 = Yes, 0 = No.", _, true, 0.0, true, 1.0);
	cvarMaxClimbs = CreateConVar("sm_playerclimb_maxclimbs", "0.0", "The maximum amount of times the player can melee the wall (climb) while being in the air before they have to touch the ground again. 0 = Disabled, 1 = 1 Climb... 23 = 23 Climbs.");
	cvarCooldown = CreateConVar("sm_playerclimb_cooldown", "0.0", "Time in seconds before the player may climb the wall again, this cooldown starts when the player touches the ground after climbing.");
	cvarNextClimb = CreateConVar("sm_playerclimb_nextclimb", "1.56", "Time in seconds in between melee climbs", _, true, 0.1);
	
	for (new i = 1; i <= MaxClients; i++)
	{
		for (new col = 0; col < 9; col++)
		{
			gClimb[i][col] = true;
		}
	}
	//Pyro airblast jump code begins here
    
    decl String:strGameDir[8];
    GetGameFolderName( strGameDir, sizeof(strGameDir) );
    if( !StrEqual( strGameDir, "tf", false ) && !StrEqual( strGameDir, "tf_beta", false ) )
        SetFailState( "THIS PLUGIN IS FOR TEAM FORTRESS 2 ONLY!" );
    
    tf_flamethrower_burst_zvelocity = FindConVar( "tf_flamethrower_burst_zvelocity" );
    
    fwOnPyroAirBlast = CreateGlobalForward( "TF2_OnPyroAirBlast", ET_Event, Param_Cell );
    
    for( new i = 0; i <= MAXPLAYERS; i++ )
    {
        flNextSecondaryAttack[i] = GetGameTime();
        if( IsValidClient(i) )
        {
            SDKHook( i, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost );
        }
    }
}

public OnClientDisconnect(client)
{
	justClimbed[client] = false;
	blockClimb[client] = false;
	maxClimbs[client] = 0;
}

public OnWeaponSwitchPost( iClient, iWeapon )
{
    if( !IsValidClient(iClient) || !IsPlayerAlive(iClient) || !IsValidEntity(iWeapon) )
        return;
    
	if (!TF2CustAttr_GetInt(iWeapon, "airblast jump", 1))
		return;
    
    flNextSecondaryAttack[iClient] = GetEntPropFloat( iWeapon, Prop_Send, "m_flNextSecondaryAttack" );
}

public OnClientAuthorized(client, const String:auth[])
{
	if (!GetConVarBool(cvarEnable)) return;
	for (new i = 1; i <= MaxClients; i++)
	{
		for (new col = 0; col < 9; col++)
		{
			gClimb[i][col] = true;
		}
	}
}

public Action:TF2_CalcIsAttackCritical(client, weapon, String:weaponname[], &bool:result)
{
	if (!GetConVarBool(cvarEnable) || !IsValidClient(client))
		return Plugin_Continue;

	if (TF2_GetPlayerClass(client) != TFClass_Spy &&
        TF2_GetPlayerClass(client) != TFClass_Sniper &&
        TF2_GetPlayerClass(client) != TFClass_Medic)
		return Plugin_Continue;

	if (IsValidEntity(weapon))
	{
		if (weapon == GetPlayerWeaponSlot(client, TFWeaponSlot_Melee))
		{
			if (HasWallClimbAttribute(client))
			{
				SickleClimbWalls(client, weapon);
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}

bool HasWallClimbAttribute(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return false;
    
    // Check all weapon slots
    for (int slot = 0; slot < 5; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon != -1 && IsValidEntity(weapon))
        {
            if (TF2CustAttr_GetInt(weapon, "wall climb enabled") > 0)
                return true;
        }
    }
    
    // Check all wearables
    int wearable = -1;
    while ((wearable = FindEntityByClassname(wearable, "tf_wearable")) != -1)
    {
        if (GetEntPropEnt(wearable, Prop_Send, "m_hOwnerEntity") == client)
        {
            if (TF2CustAttr_GetInt(wearable, "wall climb enabled") > 0)
                return true;
        }
    }
    
    return false;
}

public Timer_NoAttacking(any:ref)
{
	new weapon = EntRefToEntIndex(ref);
	SetNextAttack(weapon, GetConVarFloat(cvarNextClimb));
}

public void OnGameFrame()
{
    float cooldown = GetConVarFloat(cvarCooldown); // Cache convar value once per frame
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
			
		if (IsValidClient(i))
			OnPreThink( i );

        if ((GetEntityFlags(i) & FL_ONGROUND) == 0)
            continue;

        maxClimbs[i] = 0;

        if (cooldown > 0.0 && justClimbed[i])
        {
            justClimbed[i] = false;
            blockClimb[i] = true;
            CreateTimer(cooldown, Timer_ClimbCooldown, i, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}

public OnPreThink( iClient )
{
    if( !IsPlayerAlive(iClient) )
        return;
    
    if( TF2_GetPlayerClass(iClient) != TFClass_Pyro )
        return;
    
    // This schedules the entity's next think function to execute 5 server ticks from now
	// which would be roughly 0.075 seconds in the future on a standard 66-tick server
    
    //new iNextTickTime = RoundToNearest( FloatDiv( GetGameTime() , GetTickInterval() ) ) + 5;
    //SetEntProp( iClient, Prop_Data, "m_nNextThinkTick", iNextTickTime );
    
    new Float:flSpeed = GetEntPropFloat( iClient, Prop_Send, "m_flMaxspeed" );
    if( flSpeed > 0.0 && flSpeed < 5.0 )
        return;
    
    if( GetEntProp( iClient, Prop_Data, "m_nWaterLevel" ) > 1 )
        return;
    
    if(!(GetClientButtons(iClient) & IN_ATTACK2))
    {
        return;
    }

    new iWeapon = GetEntPropEnt( iClient, Prop_Send, "m_hActiveWeapon" );
    if( !IsValidEntity(iWeapon) )
        return;
    
    decl String:strClassname[64];
    GetEntityClassname( iWeapon, strClassname, sizeof(strClassname) );
    
    if( !StrEqual( strClassname, "tf_weapon_rocketlauncher_fireball", false ))
        return;

    if( ( GetEntPropFloat( iWeapon, Prop_Send, "m_flNextSecondaryAttack" ) - flNextSecondaryAttack[iClient] ) <= 0.0 )
        return;
    flNextSecondaryAttack[iClient] = GetEntPropFloat( iWeapon, Prop_Send, "m_flNextSecondaryAttack" );
    
    //PrintToChat( iClient, "%0.1f", GetEntPropFloat( iWeapon, Prop_Send, "m_flNextSecondaryAttack" ) - flNextSecondaryAttack[iClient] );
    //PrintToChat( iClient, "%0.1f %0.1f %0.1f", GetEntPropFloat( iWeapon, Prop_Send, "m_flNextSecondaryAttack" ), flNextSecondaryAttack[iClient], GetGameTime() );
    
    decl Action:result;
    Call_StartForward(fwOnPyroAirBlast);
    Call_PushCell( iClient );
    Call_Finish( result );
    if( result == Plugin_Handled || result == Plugin_Stop )
        return;
    
    if( (GetEntityFlags(iClient) & FL_ONGROUND) == FL_ONGROUND )
        return;
    
    if( !bPluginEnabled )
        return;
    
    decl Float:vecAngles[3], Float:vecVelocity[3];
    GetClientEyeAngles( iClient, vecAngles );
    GetEntPropVector( iClient, Prop_Data, "m_vecVelocity", vecVelocity );
    vecAngles[0] = DegToRad( -1.0 * vecAngles[0] );
    vecAngles[1] = DegToRad( vecAngles[1] );
    vecVelocity[0] -= flZVelocity * Cosine( vecAngles[0] ) * Cosine( vecAngles[1] );
    vecVelocity[1] -= flZVelocity * Cosine( vecAngles[0] ) * Sine( vecAngles[1] );
    vecVelocity[2] -= flZVelocity * Sine( vecAngles[0] );
    TeleportEntity( iClient, NULL_VECTOR, NULL_VECTOR, vecVelocity );
}

public Action:Timer_ClimbCooldown(Handle:timer, any:client)
{
	blockClimb[client] = false;
}

SickleClimbWalls(int client, int weapon)	 //Credit to Mecha the Slag
{
	if (!IsValidClient(client)) return;
	
	decl String:classname[64];
	decl Float:vecClientEyePos[3], Float:vecClientEyeAng[3];
	GetClientEyePosition(client, vecClientEyePos);	 // Get the position of the player's eyes
	GetClientEyeAngles(client, vecClientEyeAng);	   // Get the angle the player is looking
	
	//Check for colliding entities
	TR_TraceRayFilter(vecClientEyePos, vecClientEyeAng, MASK_PLAYERSOLID, RayType_Infinite, TraceRayDontHitSelf, client);
	
	if (!TR_DidHit(INVALID_HANDLE)) return;
	
	new TRIndex = TR_GetEntityIndex(INVALID_HANDLE);
	GetEdictClassname(TRIndex, classname, sizeof(classname));
	if (!((StrStarts(classname, "prop_") && classname[5] != 'p') || StrEqual(classname, "worldspawn"))) return;
	
	decl Float:fNormal[3];
	TR_GetPlaneNormal(INVALID_HANDLE, fNormal);
	GetVectorAngles(fNormal, fNormal);
	
	if (fNormal[0] >= 30.0 && fNormal[0] <= 330.0) return;
	if (fNormal[0] <= -30.0) return;
	
	decl Float:pos[3];
	TR_GetEndPosition(pos);
	new Float:distance = GetVectorDistance(vecClientEyePos, pos);
	
	if (distance >= 100.0) return;
	
	if (blockClimb[client])
	{
		PrintToChat(client, "[SM] Climbing is currently on cool-down, please wait.");
		return;
	}
	
	new maxNumClimbs = GetConVarInt(cvarMaxClimbs);
	
	if (maxNumClimbs != 0 && maxClimbs[client] >= maxNumClimbs && !(GetEntityFlags(client) & FL_ONGROUND))
	{
		PrintToChat(client, "[SM] You need to touch the ground before you can climb again.");
		return;
	}
	
	new Float:fVelocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", fVelocity);
	
	fVelocity[2] = 600.0;
	
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fVelocity);
	
	EmitAmbientSound("player/taunt_clip_spin.wav", vecClientEyePos);
	//if (level > 1) SDKHooks_TakeDamage(client, client, client, GetConVarFloat(cvarDamageAmount), DMG_CLUB, 0);
	
	RequestFrame(Timer_NoAttacking, EntIndexToEntRef(weapon));
	maxClimbs[client]++;
	justClimbed[client] = true;
}

public bool:TraceRayDontHitSelf(entity, mask, any:data)
{
	return (entity != data);
}

stock SetNextAttack(weapon, Float:duration = 0.0)
{
	if (weapon <= MaxClients || !IsValidEntity(weapon)) return;
	new Float:next = GetGameTime() + duration;
	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", next);
	SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", next);
}

stock bool:IsValidClient(iClient)
{
	return (0 < iClient && iClient <= MaxClients && IsClientInGame(iClient));
}

stock bool:StrStarts(const String:szStr[], const String:szSubStr[], bool:bCaseSensitive = true) 
{
	return !StrContains(szStr, szSubStr, bCaseSensitive);
}

stock int TF2_GetPlayerMaxHealth(int client) {
	return GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iMaxHealth", _, client);
}
