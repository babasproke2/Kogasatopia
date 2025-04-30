#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <tf_custom_attributes>
#include <tf2items>
#include <tf2attributes>
#include <addplayerhealth>
#include <clientprefs>

int LastDamage[MAXPLAYERS+1];
int Scythe[MAXPLAYERS+1];
int ShockCharge[MAXPLAYERS+1] = 30;
int HealCount[MAXPLAYERS+1];
float LastUber[MAXPLAYERS+1];

new Handle:g_sEnabled = INVALID_HANDLE;

public Plugin myinfo =
{
	name = "WeaponReverts",
	author = "bre and kuu",
	description = "Personalized weapon stat changes/custom attributes plugin",
	version = "1.7",
	url = "https://tf2.gyate.net"
};

public void OnPluginStart() {
	g_sEnabled = CreateConVar("reverts_enabled", "1", "Enable/Disable the plugin");
	if (GetConVarInt(g_sEnabled)) {
		CreateTimer(1.0, Timer_HealTimer, _, TIMER_REPEAT);
		HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
		HookEvent("post_inventory_application", Event_Resupply, EventHookMode_Post);
		PrecacheSound("weapons/fx/rics/arrow_impact_crossbow_heal.wav");
		PrecacheSound("weapons/neon_sign_hit_world_02.wav");
	}
}

public OnClientPutInServer(client) {
if (IsClientInGame(client) && (GetConVarInt(g_sEnabled))) {
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	SDKHook(client, SDKHook_WeaponSwitch, OnWeaponSwitch);
	SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
	ShockCharge[client] = 30;
	LastUber[client] = 0.0;
  }
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
        int userId = event.GetInt("userid");
        int client = GetClientOfUserId(userId);
	int attackerId = event.GetInt("attacker");
	int attacker = GetClientOfUserId(attackerId);
	if (attacker == 0 || client == 0) return Plugin_Continue;
	if (ShockCharge[client] != 30) ShockCharge[client] = 30;
	if (TF2_GetPlayerClass(client) == TFClassType:TFClass_Medic) {
		if (GetEntProp(GetPlayerWeaponSlot(client, 2), Prop_Send, "m_iItemDefinitionIndex") == 173) {
			LastUber[client] = GetEntPropFloat(GetPlayerWeaponSlot(client, 1), Prop_Send, "m_flChargeLevel");
		}
	}
	if (Scythe[attacker] != 0 && (TF2_IsPlayerInCondition(client, TFCond_OnFire))) {
	HealCount[attacker] = 4;
	return Plugin_Changed;
	}
	return Plugin_Continue;
}

public Action Event_Resupply(Event event, const char[] name, bool dontBroadcast) {
        int userId = event.GetInt("userid");
        int client = GetClientOfUserId(userId);
	if (ShockCharge[client] != 30) ShockCharge[client] = 29;
        int watch = GetPlayerWeaponSlot(client, 4);
	int medigun = GetPlayerWeaponSlot(client, 1);
	if (GetEntProp(GetPlayerWeaponSlot(client, 2), Prop_Send, "m_iItemDefinitionIndex") == 173) {
		if (LastUber[client] > 0.2) LastUber[client] = 0.2;
		SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", LastUber[client]);
		return Plugin_Changed;
	}
        if ( (watch > -1) && TF2CustAttr_GetInt(watch, "escampette attributes") != 1.0) {
                TF2_RemoveCondition(client, TFCond_SpeedBuffAlly);
		return Plugin_Changed;
        }
	return Plugin_Continue;
}

public Action TF2_CalcIsAttackCritical(client, weapon, String:weaponname[], &bool:result) {
    if (!IsClientInGame(client) || !IsValidEntity(weapon))
        return Plugin_Continue;

    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(active) || TF2CustAttr_GetInt(active, "twin barrel attributes") == 0)
        return Plugin_Continue;

    if (GetEntityFlags(client) & FL_ONGROUND)
        return Plugin_Continue;

    float velocity[3], angles[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
    GetClientEyeAngles(client, angles);

    float pitch = DegToRad(-angles[0]);
    float yaw = DegToRad(angles[1]);
    float push = 280.0 * Cosine(pitch);

    velocity[0] -= push * Cosine(yaw);
    velocity[1] -= push * Sine(yaw);
    velocity[2] -= 280.0 * Sine(pitch);

    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
    return Plugin_Changed;
}

public Action Timer_HealTimer(Handle timer) {
        for(int iClient = 0; iClient <= MaxClients; iClient++) {
                if (HealCount[iClient] != 0) {
                        if (GetClientHealth(iClient) < TF2_GetPlayerMaxHealth(iClient)) {
                                if (IsClientInGame(iClient) && IsPlayerAlive(iClient) && (CheckScythe(iClient) == 2)) {
                                        AddPlayerHealth(iClient, LastDamage[iClient], 1.0, false, true);
                                        ClientCommand(iClient, "playgamesound weapons/dispenser_generate_metal.wav");
                                }
                        }
                        HealCount[iClient]--;
                } else if (ShockCharge[iClient] < 30 && IsClientInGame(iClient)) {
                        ShockCharge[iClient]++;
                        if (ShockCharge[iClient] % 2 == 0 || ShockCharge[iClient] == 1) {
                                PrintHintText(iClient, "Shock Charge: %i%%%", (ShockCharge[iClient] * 100 / 30));
                        }
                }
        }
        return Plugin_Continue;
}

// Syringe gun passive reload
public Action OnWeaponSwitch(client, weapon)
{	
	if (!GetConVarInt(g_sEnabled)) return Plugin_Continue;
	// only do anything if the player is a medic or pyro
	TFClassType playerClass = TF2_GetPlayerClass(client);
	if(playerClass == TFClassType:TFClass_Medic) {
		int weaponindex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
		if (weaponindex != 305 && weaponindex != 1079) {
			SetAmmo_Weapon(weapon, GetAmmo_Weapon(weapon) - (40 - GetClip(client, weapon)));
			SetClip_Weapon(weapon, 40);
			return Plugin_Changed;
		}
	} else if (playerClass == TFClassType:TFClass_Pyro) {
		new weaponindex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
		if (weaponindex == 39) {
			char szClassname[36];
			GetEntityClassname(weapon, szClassname, sizeof szClassname);
			if (strcmp("tf_weapon_shotgun_pyro", szClassname) == 0) {
				SetAmmo_Weapon(weapon, GetAmmo_Weapon(weapon) - (1 - GetClip(client, weapon)));
				SetClip_Weapon(weapon, 1);
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}

// Reminder: client is the victim, attacker is the player, inflictor is the projectile/bullet/whatever
public Action OnTakeDamage(client, &attacker, &inflictor, &Float:damage, &damagetype, &weapon, Float:damageForce[3], Float:damagePosition[3], damagecustom) {
	if (attacker == 0) return Plugin_Continue;
	new wepindex = (IsValidEntity(weapon) && weapon > MaxClients ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1);
	int watch = GetPlayerWeaponSlot(client, 4);
	if (wepindex == 307) { //Ullapool Caber weapon index
		if (client == attacker) {
			damage = 50.0;
			return Plugin_Changed;
		} else if (damagecustom == 0) {
			damage = 35.00;
			return Plugin_Changed;
		} else if (damagecustom == 42) {
			damagetype|=TF_WEAPON_GRENADE_DEMOMAN;
			if (CheckRocketJumping(attacker)) {
				damage = 175.00;
				damagetype|=DMG_CRIT;
				return Plugin_Changed;
			} else {
				damage = 90.00
				return Plugin_Changed;
			}
		}
	} else if ((wepindex == 812 || wepindex == 833) && damage > 40.0) { // Cleavers
		if (TF2_IsPlayerInCondition(client, TFCond_Dazed)) { // if stunned
			damage = 33.3;
			damagetype|=DMG_CRIT;
			return Plugin_Changed;
		}
	} else if ((watch != -1) && (TF2CustAttr_GetInt(watch, "escampette attributes") != 0)) { // TF2C Custom Attribute for Spy
		if (TF2_IsPlayerInCondition(client, TFCond_Cloaked)) { // if cloaked
			float flCloakMeter = GetEntPropFloat(client, Prop_Send, "m_flCloakMeter");
			flCloakMeter -= 10;
			SetEntPropFloat(client, Prop_Send, "m_flCloakMeter", flCloakMeter);
			EmitAmbientSound("weapons/drg_pomson_drain_01.wav", damagePosition);
			return Plugin_Changed;
		}
	} else if (damagetype & DMG_BURN) {
		if ((damage < 7) && TF2_IsPlayerInCondition(client, TFCond_OnFire)) {
			Scythe[attacker] = CheckScythe(attacker);
			if (Scythe[attacker] != 0) {
				int heal = RoundToNearest(damage);
				LastDamage[attacker] = heal;
				if (!IsPlayerAlive(attacker)) {
					TF2_RemoveCondition(client, TFCond_OnFire);
					ClientCommand(attacker, "playgamesound player/flame_out.wav");
					ClientCommand(client, "playgamesound player/flame_out.wav");
					return Plugin_Changed;
				} else if (Scythe[attacker] == 2) {
					AddPlayerHealth(attacker, heal, 1.0, false, true);
					return Plugin_Changed;
				}
			}
		}
	} else if ((weapon != -1) && (TF2CustAttr_GetInt(weapon, "twin barrel attributes") != 0)) {
		float vecAngles[3];
		float vecVelocity[3];

		// Get the attacker's aim direction
		GetClientEyeAngles(attacker, vecAngles);

		// Get the client's (target's) current velocity
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vecVelocity);

		// Convert angles to radians
		vecAngles[0] = DegToRad(-1.0 * vecAngles[0]);
		vecAngles[1] = DegToRad(vecAngles[1]);

                if (damage >= 40.0) vecVelocity[2] = 251.0;

		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vecVelocity);
	} else if ((weapon != -1) && (TF2CustAttr_GetInt(weapon, "shock therapy attributes") != 0)) {
		damage = float(ShockCharge[attacker] * 100 / 30);
		ShockCharge[attacker] = 0;
		EmitAmbientSound("weapons/neon_sign_hit_world_02.wav", damagePosition);
		ClientCommand(attacker, "weapons/neon_sign_hit_world_02.wav");
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

// Reminder: client is the victim, attacker is the player, inflictor is the projectile/bullet/whatever
public Action:OnTakeDamageAlive(client, &attacker, &inflictor, &Float:damage, &damagetype, &weapon, Float:damageForce[3], Float:damagePosition[3], damagecustom) {
	new wepindex = (IsValidEntity(weapon) && weapon > MaxClients ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1);
	if (wepindex == 442 || wepindex == 588) { // Pomson, bison
		// Get distance between client and attacker
		new Float:posVic[3]; // victim position vector
		GetEntPropVector(client, Prop_Send, "m_vecOrigin", posVic);
		new Float:posAtt[3]; // attacker position vector
		GetEntPropVector(attacker, Prop_Send, "m_vecOrigin", posAtt);
    
		// Create additional damage rampup due to distance
		float rampup = ((GetVectorDistance(posVic, posAtt)-300.0) * 0.01); // Within 300 hammer units have no buff
		if ((GetVectorDistance(posVic, posAtt) < 80)) rampup += 3;// if less than 80 hammer units add 3 damage
		if(rampup < 0.00) rampup = 0.00; // rampup can never be negative
		if(rampup > 10.00) rampup = 10.00; // max damage is capped effectively at 25/30
		
		if(wepindex == 442) damage = 15.0 + rampup; // bison
		else damage = 20.0 + rampup; //pomson
		
		// Manually add crit damage
		if(damagetype & DMG_CRIT) damage *= 3.0;
		return Plugin_Changed;
	} return Plugin_Continue;
}

public Action OnTraceAttack(victim, &attacker, &inflictor, &Float:damage, &damagetype, &ammotype, hitbox, hitgroup)
{
	if (!IsValidEdict(attacker) || !IsValidClient(attacker) || !IsPlayerAlive(attacker) || attacker <= 0)
	{
		return Plugin_Continue;
	}

	if (GetClientTeam(victim) == GetClientTeam(attacker)) {
		if (CheckShock(attacker) == 2)
		{	
			int buff = OverhealStruct(victim);
			int health = GetClientHealth(victim)
			if (health < buff) {
				int medigun = GetPlayerWeaponSlot(attacker, 1);
				float pos[3];
				GetClientAbsAngles(victim, pos);
				TF2_SetHealth(victim, buff);
				ShockCharge[attacker] = 0;
				EmitAmbientSound("weapons/fx/rics/arrow_impact_crossbow_heal.wav", pos);
				ClientCommand(attacker, "playgamesound weapons/fx/rics/arrow_impact_crossbow_heal.wav");
				float uber = (float((buff - health) / 5000) + (GetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel")));
				SetEntPropFloat(medigun, Prop_Send, "m_flChargeLevel", uber);
			}
		}
	}
	return Plugin_Continue;
} 

stock int CheckScythe(int client) {
	int tally = 0;
	int scythe = GetPlayerWeaponSlot(client, 2);
	
	if (TF2CustAttr_GetInt(scythe, "harvester attributes") != 0) tally++;
	if (scythe == GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon")) tally++;
	
	if (tally > 0) Scythe[client] = scythe;
	
	return tally; 
	// 0 = not a scythe, 1 = has a scythe, 2 = scythe is active
}

stock int CheckShock(int client) {
        int tally = 0;
        int shock = GetPlayerWeaponSlot(client, 2);

        if (TF2CustAttr_GetInt(shock, "shock therapy attributes") != 0) tally++;
        if (shock == GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon")) tally++;
	if (ShockCharge[client] != 30) tally = 1;

        return tally;
}

stock bool CheckRocketJumping(int client) {
	//This is fairly primitive
	if (!(GetEntityFlags(client) & FL_ONGROUND)) {
		float flVel[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", flVel);
		if (GetVectorLength(flVel) > 300) return true;
	}
	return false;
}

stock GetAmmo_Weapon(weapon)
{
	if (weapon == -1) return 0;
	new owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (owner == -1) return 0;
	new iOffset = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
	new iAmmoTable = FindSendPropInfo("CTFPlayer", "m_iAmmo");
	return GetEntData(owner, iAmmoTable+iOffset, 4);
}

stock SetAmmo_Weapon(weapon, newAmmo)
{
	new owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (owner == -1) return;
	new iOffset = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", 1)*4;
	new iAmmoTable = FindSendPropInfo("CTFPlayer", "m_iAmmo");
	SetEntData(owner, iAmmoTable+iOffset, newAmmo, 4, true);
}

stock GetClip(client, weapon)
{
	new clip = -1;
	if (IsValidEntity(weapon))
	{
		new iAmmoTable = FindSendPropInfo("CTFWeaponBase", "m_iClip1");
		clip = GetEntData(weapon, iAmmoTable, 4);
	}
	return clip;
}

stock SetClip_Weapon(weapon, newClip)
{
	new iAmmoTable = FindSendPropInfo("CTFWeaponBase", "m_iClip1");
	SetEntData(weapon, iAmmoTable, newClip, 4, true);
}

stock int TF2_GetPlayerMaxHealth(int client) {
	return GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iMaxHealth", _, client);
}

stock int OverhealStruct(int client)
{
    // Get the player's maximum health
    int maxHealth = TF2_GetPlayerMaxHealth(client);

    // Check if the health is NOT divisible by 100
    if (maxHealth % 100 != 0)
    {
        // Multiply health by 1.5
        float modifiedHealth = maxHealth * 1.5;

        // Round down to the nearest multiple of 5
        int roundedHealth = RoundToFloor(modifiedHealth / 5.0) * 5;

        return roundedHealth;
    }

    // Return maxHealth multiplied by 1.5
    return RoundToNearest(maxHealth * 1.5);

}

// Gas passer buff
public TF2_OnConditionAdded(int client, TFCond condition)
{
	if (condition == TFCond_Gas) //If gas is applied
	{
		TF2_AddCondition(client, TFCond_Jarated, 6.0); //Apply Jarate for 6 seconds
	} else if (condition == TFCond_Cloaked) {
		new weapon = GetPlayerWeaponSlot(client, 4);
		if ( (weapon > -1) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
			TF2_AddCondition(client, TFCond_SpeedBuffAlly, 120.0);
		} 
	}
}

public TF2_OnConditionRemoved(int client, TFCond condition)
{
	if (condition == TFCond_Cloaked)
	{
		new weapon = GetPlayerWeaponSlot(client, 4);
		if ( (weapon > -1) && TF2CustAttr_GetInt(weapon, "escampette attributes") != 0) {
			TF2_RemoveCondition(client, TFCond_SpeedBuffAlly);
		}
	}
}

public TF2Items_OnGiveNamedItem_Post(client, String:classname[], index, level, quality, entity)
{
        if (index == 56 || index == 1092 || index == 1005) // The Huntsman, Fortified Compound and Festive Huntsman
        {
                TF2Attrib_SetByName(entity, "max health additive bonus", 15.00); // Self explanatory
        }

	if (GetConVarInt(g_sEnabled)) {
		// Attach the `m_bValidatedAttachedEntity` property to every weapon/cosmetic for custom weapon visibility.
		if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity")) {
			SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
			TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property
		}
		//TF2Attrib_SetByName(entity, "crit mod disabled HIDDEN", 0.25);
		switch (index)
		{
			case 163: //The Crit-a-Cola 
			{	
				TF2Attrib_SetByName(entity, "energy buff dmg taken multiplier", 1.25); // Changes the damage taken from +35% to +20%
				TF2Attrib_SetByName(entity, "mod_mark_attacker_for_death", 0.00); // Disable this attribute 
			}
			case 220: //The Shortstop
			{
				TF2Attrib_SetByName(entity, "Reload time decreased", 0.75);
				TF2Attrib_SetByName(entity, "healing received bonus", 1.20); // Self explanatory
				TF2Attrib_SetByName(entity, "damage force increase", 1.80); // Increased 20% -> 80%
				TF2Attrib_SetByName(entity, "airblast vulnerability multiplier hidden", 1.80); // Increased 20% -> 80%
			} 
			case 317: //The Candy Cane
			{
				TF2Attrib_SetByName(entity, "health from packs increased", 1.40); // Add the backscratcher
			}
	                case 355: //Fan-o-War
	                {
	                        TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 0.80);
	                        TF2Attrib_SetByName(entity, "single wep deploy time decreased", 0.80);
	                }
			case 772: //Baby Face's Blaster index
			{
				TF2Attrib_SetByName(entity, "lose hype on take damage", 0.0); // Removed
				TF2Attrib_SetByName(entity, "move speed penalty", 0.81); // Increased to 15%
				TF2Attrib_SetByName(entity, "damage penalty", 0.90); //Decrease damage by 10%
			}
			case 1103: //The Back Scatter
			{
				TF2Attrib_SetByName(entity, "weapon spread bonus", 0.90); // Self explanatory
				TF2Attrib_SetByName(entity, "spread penalty", 1.00); // Remove this attribute
			}
			case 348: //The Sharpened Volcano Fragment
			{
				TF2Attrib_SetByName(entity, "minicrit vs burning player", 1.00); //Add this attribute for lossy
			}
			case 265: //The Sticky Jumper
			{
				TF2Attrib_SetByName(entity, "max pipebombs decreased", 0.0); // Remove pipebomb restriction
			}
			case 308: //The loch n' Load
			{
				TF2Attrib_SetByName(entity, "damage bonus", 1.10); // Increase damage to 110
			}
			case 414: //Liberty Launcher index
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.90); // Increase RoF
			}
			case 1101: //The Base Jumper
			{
				//TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.75); // Half of the gunboats protection
			}
			case 1104: //The Air Strike
			{
				TF2Attrib_SetByName(entity, "Reload time decreased", 0.85); // Increase reload speed
			}
			case 730: //The Beggars
			{
				TF2Attrib_SetByName(entity, "Blast radius decreased", 1.00); // Set explosion radius debuff to 0
			}
	                case 128: //The Equalizer
	                {
	                        TF2Attrib_SetByName(entity, "dmg from ranged reduced", 0.80); // Less damage from ranged while held
	                }
			case 588: //The Pomson 6000
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.80); // Increase firing rate
				TF2Attrib_SetByName(entity, "energy weapon penetration", 1.00); // Penetrate targets
			}
			case 405, 608: //Demoman boots
			{
				TF2Attrib_SetByName(entity, "move speed bonus shield required", 1.00); // Remove this attribute
				TF2Attrib_SetByName(entity, "move speed bonus", 1.10); // Add this attribute
				//TF2Attrib_SetByName(entity, "boots falling stomp", 1.00); // Add this property	
			}
			case 327: //The Claidheahm Mohr
			{
				TF2Attrib_SetByName(entity, "heal on kill", 25.00); // Re-add this attribute
			}
			case 11, 425, 199: //Heavy's Shotguns
			{
				if(TF2_GetPlayerClass(client) == TFClass_Heavy) {
					TF2Attrib_SetByName(entity, "mult_player_movespeed_active", 1.10);
				}
			}
			case 239, 1084, 1100: //The Gloves of Running Urgently
			{
				TF2Attrib_SetByName(entity, "mod_maxhealth_drain_rate", 0.0); //Disable max health drain
				TF2Attrib_SetByName(entity, "damage penalty", 0.70); //Decrease damage by 30%
				TF2Attrib_SetByName(entity, "self mark for death", 1.00); //Mark for death
			}
			case 426: //The Eviction Notice
			{
				TF2Attrib_SetByName(entity, "mod_maxhealth_drain_rate", 0.0); // Disable max health drain
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.40); // Fire 60% faster
			}
			case 811, 832: //The Huo Long Heater
			{
				TF2Attrib_SetByName(entity, "damage penalty", 1.00); // Remove the damage penalty
			}
			case 998: //The Vaccinator
			{
					TF2Attrib_SetByName(entity, "mult_dmgtaken_active", 1.20);
			}
			case 1144, 131, 1099, 406: //Demoshields
			{
				TF2Attrib_SetByName(entity, "rocket jump damage reduction", 0.35); // Reduce self inflicted damage by 60%
				TF2Attrib_SetByName(entity, "dmg taken from fire reduced", 0.90); // Disable this attribute
				TF2Attrib_SetByName(entity, "dmg taken from blast reduced", 0.90); // Disable this attribute
			}
			case 442: //The Righteous Bison
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.40); // Increase firing rate
				TF2Attrib_SetByName(entity, "dmg falloff decreased", 0.50); // Remove damage falloff
			}
			case 38, 457, 1000: //Axtinguisher, Plummeter, Festive Axtinguisher indexes
			{
				TF2Attrib_SetByName(entity, "attack_minicrits_and_consumes_burning", 0.0); // Remove the base properties
				TF2Attrib_SetByName(entity, "crit vs burning players", 1.0); // Self explanatory
				TF2Attrib_SetByName(entity, "dmg penalty vs nonburning", 0.50); // Self explanatory
				TF2Attrib_SetByName(entity, "damage penalty", 1.00); // Sets the damage penalty to 0%
			}
			case 1181: //The Hot Hand
			{
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.50); // Increase firing rate
			}
			case 1179: //The Thermal Thruster
			{
				TF2Attrib_SetByName(entity, "thermal_thruster_air_launch", 1.0); // Able to re-launch while already in-flight 
			}
			case 351: //The Detonator
			{
				TF2Attrib_SetByName(entity, "blast dmg to self increased", 0.75); // Halve the blast damage penalty
			}
			case 215: //The Degreaser
			{
				TF2Attrib_SetByName(entity, "deploy time decreased", 0.60); // Modify all swap speeds
				TF2Attrib_SetByName(entity, "switch from wep deploy time decreased", 1.00); // Remove the holster bonus
				TF2Attrib_SetByName(entity, "single wep deploy time decreased", 1.00); // Remove the deploy bonus
			}
			case 17, 204, 36, 412: // Syringe guns
			{
				TF2Attrib_SetByName(entity, "add uber charge on hit", 0.0125); // 1.25% uber per projectile hit
			}
			case 171: // The Tribalman's Shiv
			{
				TF2Attrib_SetByName(entity, "damage penalty", 0.75);
			}
			case 751: // The Cleaner's Carbine
			{
				TF2Attrib_SetByName(entity, "critboost on kill", 2.0); // Self explanatory
			}
			case 1098: // The Classic
			{
				TF2Attrib_SetByName(entity, "sniper charge per sec", 1.15) // Increased by 15%
			}
			case 460: // The Enforcer
			{
				TF2Attrib_SetByName(entity, "damage bonus", 1.10); // Return the original damage bonus
				TF2Attrib_SetByName(entity, "mult cloak rate", 0.5); // Return the 0.5s cloak time penalty
				TF2Attrib_SetByName(entity, "damage bonus while disguised", 0.00); // Remove this bonus
				TF2Attrib_SetByName(entity, "fire rate penalty", 1.00); // Remove the firing rate penalty
				TF2Attrib_SetByName(entity, "mult cloak meter consume rate", 1.33); // move the YER's penalty here
			}
			case 225, 574: // Your Eternal Reward
			{
				TF2Attrib_SetByName(entity, "mult cloak meter consume rate", 1.00); // Self explanatory
				TF2Attrib_SetByName(entity, "fire rate bonus", 0.85); // Increase RoF
			}
			case 461: // The Big Earner
			{
				TF2Attrib_SetByName(entity, "add cloak on kill", 50.0); // Increase the cloak gain from 30 to 50
				TF2Attrib_SetByName(entity, "max health additive penalty", -20.0); // Change the penalty from -25 to 20
			}
			case 810, 831: // Red-Tape sappers
			{
				TF2Attrib_SetByName(entity, "sapper damage penalty", 0.30); // Change this from 100% to 30%
			}
			case 155: // Southern Hospitality
			{
				TF2Attrib_SetByName(entity, "engy dispenser radius increased", 2.00); // Increase dispenser radius
				TF2Attrib_SetByName(entity, "damage bonus", 1.10);
			}
		}
	}
}
