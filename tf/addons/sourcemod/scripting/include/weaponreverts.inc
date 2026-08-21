#if defined _weaponreverts_included_
    #endinput
#endif
#define _weaponreverts_included_

/**
 * Helper utilities shared by the WeaponReverts plugin.
 * Functions defined here rely on globals declared in weaponreverts.sp.
 */

#define WR_PLAYER_AMMO_METAL_SLOT 3
#define WR_AMMO_CELL_BYTES 4
#define WR_ENGINEER_METAL_MAX 200

stock bool WR_IsValidPlayerIndex(int client)
{
    return (client > 0 && client <= MaxClients);
}

stock bool WR_IsClientInGame(int client)
{
    return (WR_IsValidPlayerIndex(client) && IsClientInGame(client));
}

stock bool WR_IsValidWeaponEntity(int weapon)
{
    return (weapon > MaxClients && IsValidEntity(weapon));
}

stock bool WR_IsClipWeaponEntity(int weapon)
{
    if (!WR_IsValidWeaponEntity(weapon)
        || !HasEntProp(weapon, Prop_Send, "m_iClip1"))
    {
        return false;
    }

    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    return StrContains(classname, "tf_weapon_", false) == 0;
}

stock int WR_GetPlayerAmmoOffset()
{
    static bool resolved = false;
    static int offset = -1;

    if (!resolved)
    {
        offset = FindSendPropInfo("CTFPlayer", "m_iAmmo");
        resolved = true;
    }

    return offset;
}

stock int WR_GetWeaponClipOffset()
{
    static bool resolved = false;
    static int offset = -1;

    if (!resolved)
    {
        offset = FindSendPropInfo("CTFWeaponBase", "m_iClip1");
        resolved = true;
    }

    return offset;
}

stock int TF_GetMetalAmount(int client)
{
    if (!WR_IsClientInGame(client))
    {
        return 0;
    }

    if (g_iMetalOffset == -1)
    {
        if (!g_bWarnedMetalOffset)
        {
            LogError("[weaponreverts] Metal offset unresolved when reading metal.");
            g_bWarnedMetalOffset = true;
        }
        return 0;
    }

    int metal = GetEntData(client, g_iMetalOffset + (WR_PLAYER_AMMO_METAL_SLOT * WR_AMMO_CELL_BYTES), WR_AMMO_CELL_BYTES);
    tf2_players[client].engiMetal = metal;
    return metal;
}

stock void TF_SetMetalAmount(int client, int metal)
{
    if (!WR_IsClientInGame(client))
    {
        return;
    }

    if (metal < 0)
    {
        metal = 0;
    }
    else if (metal > WR_ENGINEER_METAL_MAX)
    {
        metal = WR_ENGINEER_METAL_MAX;
    }

    if (g_iMetalOffset == -1)
    {
        if (!g_bWarnedMetalOffset)
        {
            LogError("[weaponreverts] Metal offset unresolved when writing metal.");
            g_bWarnedMetalOffset = true;
        }
        return;
    }

    tf2_players[client].engiMetal = metal;
    SetEntData(client, g_iMetalOffset + (WR_PLAYER_AMMO_METAL_SLOT * WR_AMMO_CELL_BYTES), metal, WR_AMMO_CELL_BYTES, true);
}

stock int CheckScythe(int client)
{
    if (!WR_IsClientInGame(client))
        return 0;

    int scythe = GetPlayerWeaponSlot(client, 2);
    if (!WR_IsValidWeaponEntity(scythe))
        return 0;

    if (TF2CustAttr_GetInt(scythe, "harvester attributes") != 1)
        return 0;

    int tally = 1;
    if (scythe == GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon"))
        tally++;

    return tally;
}

stock int CheckShock(int client)
{
    if (!WR_IsClientInGame(client))
        return 0;

    int shock = GetPlayerWeaponSlot(client, 2);
    int tally = (tf2_players[client].shockCharge != 30) ? 1 : 0;
    if (!WR_IsValidWeaponEntity(shock))
        return tally;

    if (TF2CustAttr_GetInt(shock, "shock therapy attributes") != 0)
        tally++;
    if (shock == GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon"))
        tally++;
    return tally;
}

stock int CheckDesertEagle(int client)
{
    if (!WR_IsClientInGame(client))
        return 0;

    int deagle = GetPlayerWeaponSlot(client, 1);
    if (!WR_IsValidWeaponEntity(deagle))
        return 0;

    int tally = 0;
    if (TF2CustAttr_GetInt(deagle, "can headshot sm") != 0)
        tally++;
    if (deagle == GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon"))
        tally++;
    return tally;
}

stock bool CheckRocketJumping(int client)
{
    if (!WR_IsClientInGame(client))
        return false;

    if (!(GetEntityFlags(client) & FL_ONGROUND))
    {
        float velocity[3];
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
        if (GetVectorLength(velocity) > 300.0)
        {
            return true;
        }
    }
    return false;
}

stock int GetAmmo_Weapon(int weapon)
{
    if (!WR_IsValidWeaponEntity(weapon))
        return 0;

    int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    if (!WR_IsClientInGame(owner))
        return 0;

    int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", 1);
    if (ammoType < 0)
        return 0;

    int ammoTable = WR_GetPlayerAmmoOffset();
    if (ammoTable < 0)
        return 0;

    return GetEntData(owner, ammoTable + (ammoType * WR_AMMO_CELL_BYTES), WR_AMMO_CELL_BYTES);
}

stock void SetAmmo_Weapon(int weapon, int newAmmo)
{
    if (!WR_IsValidWeaponEntity(weapon))
        return;

    int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
    if (!WR_IsClientInGame(owner))
        return;

    int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType", 1);
    if (ammoType < 0)
        return;

    int ammoTable = WR_GetPlayerAmmoOffset();
    if (ammoTable < 0)
        return;

    SetEntData(owner, ammoTable + (ammoType * WR_AMMO_CELL_BYTES), newAmmo, WR_AMMO_CELL_BYTES, true);
}

stock int GetClip(int weapon)
{
    if (!WR_IsClipWeaponEntity(weapon))
        return -1;

    int clipOffset = WR_GetWeaponClipOffset();
    if (clipOffset < 0)
        return -1;

    return GetEntData(weapon, clipOffset, WR_AMMO_CELL_BYTES);
}

int GetWeaponMaxClip(int weapon)
{
    if (!WR_IsClipWeaponEntity(weapon))
        return -1;

    if (g_SDKGetMaxClip1 == null)
        return -1;

    return SDKCall(g_SDKGetMaxClip1, weapon);
}

stock void SetClip_Weapon(int weapon, int newClip)
{
    if (!WR_IsClipWeaponEntity(weapon))
        return;

    int clipOffset = WR_GetWeaponClipOffset();
    if (clipOffset < 0)
        return;

    SetEntData(weapon, clipOffset, newClip, WR_AMMO_CELL_BYTES, true);
}

stock int TF2_GetPlayerMaxHealth(int client)
{
    return GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iMaxHealth", _, client);
}

stock int OverhealStruct(int client)
{
    int maxHealth = TF2_GetPlayerMaxHealth(client);

    if (maxHealth % 100 != 0)
    {
        float modifiedHealth = maxHealth * 1.5;
        int roundedHealth = RoundToFloor(modifiedHealth / 5.0) * 5;
        return roundedHealth;
    }

    return RoundToNearest(float(maxHealth) * 1.5);
}

public bool CheckIfAfterburn(int damagecustom)
{
    return (damagecustom == TF_CUSTOM_BURNING || damagecustom == TF_CUSTOM_BURNING_FLARE);
}

public bool CheckIfBleedDmg(int damageType)
{
    return (damageType & DMG_SLASH) != 0;
}

stock float Sproke_GetAttributeDuration(int weapon)
{
    if (!WR_IsValidWeaponEntity(weapon))
        return 0.0;

    return TF2CustAttr_GetFloat(weapon, SPROKE_ATTR_NAME, 0.0);
}

stock bool Sproke_ClientHasAttribute(int client)
{
    int secondary = GetPlayerWeaponSlot(client, 1);
    return Sproke_GetAttributeDuration(secondary) > 0.0;
}

stock void Sproke_RemoveParticle(int client)
{
    if (!WR_IsValidPlayerIndex(client))
        return;

    int particle = EntRefToEntIndex(tf2_players[client].sprokeParticleRef);
    if (particle > MaxClients && IsValidEntity(particle))
    {
        AcceptEntityInput(particle, "Stop");
        AcceptEntityInput(particle, "Kill");
    }

    tf2_players[client].sprokeParticleRef = INVALID_ENT_REFERENCE;
}

stock void Sproke_AttachParticle(int client)
{
    if (!WR_IsClientInGame(client))
        return;

    int particle = CreateEntityByName("info_particle_system");
    if (particle == -1)
        return;

    char effectName[64];
    TFTeam team = view_as<TFTeam>(GetClientTeam(client));
    strcopy(effectName, sizeof(effectName), (team == TFTeam_Red) ? SPROKE_PARTICLE_RED : SPROKE_PARTICLE_BLUE);

    float origin[3];
    GetClientAbsOrigin(client, origin);

    TeleportEntity(particle, origin, NULL_VECTOR, NULL_VECTOR);
    DispatchKeyValue(particle, "effect_name", effectName);
    DispatchKeyValue(particle, "start_active", "0");
    DispatchKeyValue(particle, "flag_as_weather", "1");
    DispatchSpawn(particle);

    SetVariantString("!activator");
    AcceptEntityInput(particle, "SetParent", client, client);

    ActivateEntity(particle);
    AcceptEntityInput(particle, "Start");

    tf2_players[client].sprokeParticleRef = EntIndexToEntRef(particle);
}

stock void Sproke_ClearEffect(int client, bool restoreClip, bool playSound)
{
    if (!WR_IsValidPlayerIndex(client))
        return;

    int weapon = EntRefToEntIndex(tf2_players[client].sprokePrimaryRef);
    if (weapon > MaxClients && IsValidEntity(weapon))
    {
        if (restoreClip && tf2_players[client].sprokeClipRecord > 0)
        {
            SetClip_Weapon(weapon, tf2_players[client].sprokeClipRecord);
            SetAmmo_Weapon(weapon, 0);
        }

        TF2Attrib_RemoveByName(weapon, SPROKE_PRIMARY_ATTR);
        TF2Attrib_RemoveByName(weapon, SPROKE_ALT_ATTR);
        tf2_players[client].sprokeClipRecord = GetWeaponMaxClip(weapon);

        if (playSound && IsClientInGame(client) && IsPlayerAlive(client))
        {
            float eyePos[3];
            GetClientEyePosition(client, eyePos);
            EmitAmbientSound(BURP_SOUND, eyePos, client, SNDLEVEL_NORMAL);
        }
    }

    tf2_players[client].sprokePrimaryRef = INVALID_ENT_REFERENCE;
    Sproke_RemoveParticle(client);
}

public void Sproke_TryActivate(int client, float duration)
{
    if (!WR_IsValidPlayerIndex(client))
    {
        return;
    }

    // Always kill existing timer (if any) before proceeding
    if (tf2_players[client].sprokeTimer != null)
    {
        delete tf2_players[client].sprokeTimer;
        tf2_players[client].sprokeTimer = null;
    }

    // If duration is invalid or player isn't valid, clear and stop
    if (duration <= 0.0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        Sproke_ClearEffect(client, true, false);
        return;
    }

    if (!Sproke_ClientHasAttribute(client))
    {
        Sproke_ClearEffect(client, true, false);
        return;
    }

    int primary = GetPlayerWeaponSlot(client, 0);
    if (!WR_IsValidWeaponEntity(primary))
    {
        Sproke_ClearEffect(client, true, false);
        return;
    }

    CreateTimer(1.2, Sproke_ClearColaEffect, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    int maxClip = GetWeaponMaxClip(primary);
    tf2_players[client].sprokeClipRecord = maxClip;

    if (maxClip > 2)
    {
        TF2Attrib_SetByName(primary, SPROKE_PRIMARY_ATTR, SPROKE_PRIMARY_FACTOR);
        SetClip_Weapon(primary, GetAmmo_Weapon(primary));
    }

    TF2Attrib_SetByName(primary, SPROKE_ALT_ATTR, SPROKE_ALT_FACTOR);
    tf2_players[client].sprokePrimaryRef = EntIndexToEntRef(primary);

    // Refresh visual FX
    Sproke_RemoveParticle(client);
    Sproke_AttachParticle(client);

    // Start fresh timer
    tf2_players[client].sprokeTimer = CreateTimer(
        duration, 
        Sproke_TimerFinished, 
        GetClientUserId(client), 
        TIMER_FLAG_NO_MAPCHANGE
    );
}

public Action Sproke_ClearColaEffect(Handle timer, int client)
{
    client = GetClientOfUserId(client);
    if (!WR_IsClientInGame(client))
        return Plugin_Stop;

    TF2_RemoveCondition(client, TFCond_CritCola);
    return Plugin_Stop;
}

public Action Sproke_TimerFinished(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (client <= 0 || client > MaxClients)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (tf2_players[i].sprokeTimer == timer)
            {
                tf2_players[i].sprokeTimer = null;
                Sproke_ClearEffect(i, true, false);
                break;
            }
        }
        return Plugin_Stop;
    }

    if (tf2_players[client].sprokeTimer == timer)
    {
        tf2_players[client].sprokeTimer = null;
    }

    bool playSound = IsClientInGame(client) && IsPlayerAlive(client);
    Sproke_ClearEffect(client, true, playSound);
    return Plugin_Stop;
}
