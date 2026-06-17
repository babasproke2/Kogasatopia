#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_trace>
#include <tf2_stocks>
#include <tf2_sentry_newtarget_dist>

#define PLUGIN_VERSION "1.0.0"
#define MAX_EDICTS_TRACKED 2048

#if !defined FL_NOTARGET
    #define FL_NOTARGET (1 << 15)
#endif

#if !defined CONTENTS_GRATE
    #define CONTENTS_GRATE 0x8
#endif

#define SENTRY_STATE_INACTIVE  0
#define SENTRY_STATE_SEARCHING 1
#define SENTRY_STATE_ATTACKING 2
#define SENTRY_STATE_UPGRADING 3

ConVar gCvarEnable;
ConVar gCvarDistance;
Handle gTimer = null;

bool gEnabled = false;
float gDistance = 200.0;

int gSentryRef[MAX_EDICTS_TRACKED + 1];
int gLastAcceptedTargetRef[MAX_EDICTS_TRACKED + 1];

public Plugin myinfo =
{
    name = "[TF2] Sentry New Target Distance",
    author = "Hombre",
    description = "Restores configurable sentry target-switch distance for normal and mini sentries.",
    version = PLUGIN_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    if (GetEngineVersion() != Engine_TF2)
    {
        strcopy(error, errMax, "This plugin only supports Team Fortress 2.");
        return APLRes_Failure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    gCvarEnable = CreateConVar(
        "sm_tf2_sentry_newtarget_enable",
        "0",
        "Enable configurable sentry target switching distance. 0 = stock TF2 behavior, 1 = enabled.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    gCvarDistance = CreateConVar(
        "sm_tf2_sentry_newtarget_dist",
        "200.0",
        "Required distance advantage, in Hammer Units, before a sentry switches targets. Applies to normal and mini sentries.",
        FCVAR_NOTIFY,
        true,
        0.0
    );

    HookConVarChange(gCvarEnable, OnControlCvarChanged);
    HookConVarChange(gCvarDistance, OnControlCvarChanged);

    AutoExecConfig(true, "tf2_sentry_newtarget_dist");
    ResetTracking();
    ApplySettings();
}

public void OnConfigsExecuted()
{
    ApplySettings();
}

public void OnMapStart()
{
    ResetTracking();
}

public void OnMapEnd()
{
    StopRetargetTimer();
    ResetTracking();
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplySettings();
}

void ApplySettings()
{
    gEnabled = gCvarEnable.BoolValue;
    gDistance = gCvarDistance.FloatValue;

    if (gDistance < 0.0)
        gDistance = 0.0;

    TF2SentryNewTarget_SetEnabled(gEnabled);
    TF2SentryNewTarget_SetDistance(gDistance);

    if (gEnabled)
    {
        StartRetargetTimer();
    }
    else
    {
        StopRetargetTimer();
        ResetTracking();
    }
}

void StartRetargetTimer()
{
    if (gTimer != null)
        return;

    gTimer = CreateTimer(0.05, Timer_RetargetSentries, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopRetargetTimer()
{
    if (gTimer == null)
        return;

    CloseHandle(gTimer);
    gTimer = null;
}

void ResetTracking()
{
    for (int i = 0; i <= MAX_EDICTS_TRACKED; i++)
    {
        gSentryRef[i] = INVALID_ENT_REFERENCE;
        gLastAcceptedTargetRef[i] = INVALID_ENT_REFERENCE;
    }
}

public Action Timer_RetargetSentries(Handle timer)
{
    if (!gEnabled)
        return Plugin_Continue;

    int sentry = -1;
    while ((sentry = FindEntityByClassname(sentry, "obj_sentrygun")) != -1)
    {
        ProcessSentry(sentry);
    }

    return Plugin_Continue;
}

void ProcessSentry(int sentry)
{
    if (!IsUsableSentry(sentry))
        return;

    int sentryRef = EntIndexToEntRef(sentry);
    if (sentry <= MAX_EDICTS_TRACKED && gSentryRef[sentry] != sentryRef)
    {
        gSentryRef[sentry] = sentryRef;
        gLastAcceptedTargetRef[sentry] = INVALID_ENT_REFERENCE;
    }

    float sentryEye[3];
    GetSentryEyePosition(sentry, sentryEye);

    int currentTarget = GetEntPropEnt(sentry, Prop_Send, "m_hEnemy");
    if (!IsKnownTargetValidForSentry(sentry, currentTarget))
        currentTarget = -1;

    int oldTarget = -1;
    if (sentry <= MAX_EDICTS_TRACKED)
        oldTarget = ResolveEntityRef(gLastAcceptedTargetRef[sentry]);

    if (!IsKnownTargetValidForSentry(sentry, oldTarget))
    {
        oldTarget = currentTarget;
        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = (oldTarget > 0) ? EntIndexToEntRef(oldTarget) : INVALID_ENT_REFERENCE;
    }

    float newDistSq = 0.0;
    int bestTarget = FindBestTargetForSentry(sentry, sentryEye, newDistSq);
    if (bestTarget <= 0)
    {
        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = INVALID_ENT_REFERENCE;
        return;
    }

    if (oldTarget <= 0)
    {
        ForceSentryTarget(sentry, bestTarget, sentryEye, false);
        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = EntIndexToEntRef(bestTarget);
        return;
    }

    if (bestTarget == oldTarget)
    {
        if (currentTarget > 0 && currentTarget != oldTarget)
            ForceSentryTarget(sentry, oldTarget, sentryEye, true);

        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = EntIndexToEntRef(oldTarget);
        return;
    }

    float oldPoint[3];
    GetTargetAimPoint(oldTarget, oldPoint);
    float oldDist = GetVectorDistance(sentryEye, oldPoint);
    float newDist = SquareRoot(newDistSq);

    bool shouldSwitch = (gDistance <= 0.0 || (oldDist - newDist) >= gDistance);

    if (shouldSwitch)
    {
        if (currentTarget != bestTarget)
            ForceSentryTarget(sentry, bestTarget, sentryEye, false);

        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = EntIndexToEntRef(bestTarget);
    }
    else
    {
        // Stock TF2 may have switched because of the hardcoded 0.75 squared-distance
        // ratio. Restore the last accepted target until the fixed HU threshold is met.
        if (currentTarget > 0 && currentTarget != oldTarget)
            ForceSentryTarget(sentry, oldTarget, sentryEye, true);

        if (sentry <= MAX_EDICTS_TRACKED)
            gLastAcceptedTargetRef[sentry] = EntIndexToEntRef(oldTarget);
    }
}

bool IsUsableSentry(int sentry)
{
    if (!IsValidEntityIndex(sentry))
        return false;

    int state = GetEntProp(sentry, Prop_Send, "m_iState");
    if (state != SENTRY_STATE_SEARCHING && state != SENTRY_STATE_ATTACKING)
        return false;

    if (HasEntProp(sentry, Prop_Send, "m_bDisabled") && GetEntProp(sentry, Prop_Send, "m_bDisabled") != 0)
        return false;

    if (HasEntProp(sentry, Prop_Send, "m_bCarried") && GetEntProp(sentry, Prop_Send, "m_bCarried") != 0)
        return false;

    if (HasEntProp(sentry, Prop_Send, "m_bPlacing") && GetEntProp(sentry, Prop_Send, "m_bPlacing") != 0)
        return false;

    return true;
}

int FindBestTargetForSentry(int sentry, const float sentryEye[3], float &bestDistSq)
{
    int best = -1;
    bestDistSq = GetSentryRange(sentry) * GetSentryRange(sentry);

    // Match Valve's priority order closely enough for this fix: players first.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidTargetPlayer(sentry, client))
            continue;

        float targetPoint[3];
        GetTargetAimPoint(client, targetPoint);
        float distSq = GetVectorDistanceSquared(sentryEye, targetPoint);
        if (distSq <= bestDistSq)
        {
            bestDistSq = distSq;
            best = client;
        }
    }

    if (best > 0)
        return best;

    // If no player target is valid, consider enemy buildings.
    static const char objectClasses[][] =
    {
        "obj_sentrygun",
        "obj_dispenser",
        "obj_teleporter"
    };

    for (int i = 0; i < sizeof(objectClasses); i++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, objectClasses[i])) != -1)
        {
            if (!IsValidTargetObject(sentry, ent))
                continue;

            float targetPoint[3];
            GetTargetAimPoint(ent, targetPoint);
            float distSq = GetVectorDistanceSquared(sentryEye, targetPoint);
            if (distSq <= bestDistSq)
            {
                bestDistSq = distSq;
                best = ent;
            }
        }
    }

    return best;
}

bool IsKnownTargetValidForSentry(int sentry, int target)
{
    if (!IsValidEntityIndex(target))
        return false;

    if (target <= MaxClients)
        return IsValidTargetPlayer(sentry, target);

    return IsValidTargetObject(sentry, target);
}

bool IsValidTargetPlayer(int sentry, int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
        return false;

    int sentryTeam = GetEntProp(sentry, Prop_Send, "m_iTeamNum");
    int targetTeam = GetClientTeam(client);
    if (targetTeam <= 1 || targetTeam == sentryTeam)
        return false;

    if ((GetEntityFlags(client) & FL_NOTARGET) != 0)
        return false;

    // The stock code uses GetPercentInvisible() > 0.5. SourcePawn does not expose
    // that directly, so reject fully cloaked targets and friendly disguises.
    if (TF2_IsPlayerInCondition(client, TFCond_Cloaked))
        return false;

    if ((TF2_IsPlayerInCondition(client, TFCond_Disguised) || TF2_IsPlayerInCondition(client, TFCond_Disguising))
        && HasEntProp(client, Prop_Send, "m_nDisguiseTeam")
        && GetEntProp(client, Prop_Send, "m_nDisguiseTeam") == sentryTeam)
    {
        return false;
    }

    if (AcrossWaterBoundary(sentry, client))
        return false;

    float start[3];
    float end[3];
    GetSentryEyePosition(sentry, start);
    GetTargetAimPoint(client, end);

    return IsVisibleToSentry(sentry, client, start, end);
}

bool IsValidTargetObject(int sentry, int targetObject)
{
    if (!IsValidEntityIndex(targetObject) || targetObject == sentry)
        return false;

    char cls[64];
    GetEntityClassname(targetObject, cls, sizeof(cls));
    if (!StrEqual(cls, "obj_sentrygun") && !StrEqual(cls, "obj_dispenser") && !StrEqual(cls, "obj_teleporter"))
        return false;

    int sentryTeam = GetEntProp(sentry, Prop_Send, "m_iTeamNum");
    int objectTeam = GetEntProp(targetObject, Prop_Send, "m_iTeamNum");
    if (objectTeam <= 1 || objectTeam == sentryTeam)
        return false;

    if (HasEntProp(targetObject, Prop_Send, "m_bPlacing") && GetEntProp(targetObject, Prop_Send, "m_bPlacing") != 0)
        return false;

    if (HasEntProp(targetObject, Prop_Send, "m_bCarried") && GetEntProp(targetObject, Prop_Send, "m_bCarried") != 0)
        return false;

    if (AcrossWaterBoundary(sentry, targetObject))
        return false;

    float start[3];
    float end[3];
    GetSentryEyePosition(sentry, start);
    GetTargetAimPoint(targetObject, end);

    return IsVisibleToSentry(sentry, targetObject, start, end);
}

bool AcrossWaterBoundary(int sentry, int target)
{
    int sentryWater = 0;
    int targetWater = 0;

    if (HasEntProp(sentry, Prop_Data, "m_nWaterLevel"))
        sentryWater = GetEntProp(sentry, Prop_Data, "m_nWaterLevel");
    else if (HasEntProp(sentry, Prop_Send, "m_nWaterLevel"))
        sentryWater = GetEntProp(sentry, Prop_Send, "m_nWaterLevel");

    if (HasEntProp(target, Prop_Data, "m_nWaterLevel"))
        targetWater = GetEntProp(target, Prop_Data, "m_nWaterLevel");
    else if (HasEntProp(target, Prop_Send, "m_nWaterLevel"))
        targetWater = GetEntProp(target, Prop_Send, "m_nWaterLevel");

    return ((sentryWater == 0 && targetWater >= 3) || (sentryWater >= 3 && targetWater <= 0));
}

bool IsVisibleToSentry(int sentry, int target, const float start[3], const float end[3])
{
    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT | CONTENTS_GRATE, RayType_EndPoint, TraceFilter_IgnoreSentry, sentry);
    int hit = TR_GetEntityIndex(trace);
    bool didHit = TR_DidHit(trace);
    CloseHandle(trace);

    if (!didHit)
        return true;

    return hit == target;
}

public bool TraceFilter_IgnoreSentry(int entity, int contentsMask, any data)
{
    int sentry = data;
    return entity != sentry;
}

void ForceSentryTarget(int sentry, int target, const float soundCenter[3], bool noSound)
{
    if (!IsUsableSentry(sentry) || !IsKnownTargetValidForSentry(sentry, target))
        return;

    TF2SentryNewTarget_FoundTarget(sentry, target, soundCenter, noSound);
}

void GetSentryEyePosition(int sentry, float out[3])
{
    GetEntPropVector(sentry, Prop_Send, "m_vecOrigin", out);

    float viewOffset[3];
    if (TryGetEntPropVector(sentry, Prop_Data, "m_vecViewOffset", viewOffset)
        || TryGetEntPropVector(sentry, Prop_Send, "m_vecViewOffset", viewOffset))
    {
        AddVectors(out, viewOffset, out);
        return;
    }

    // Safe fallback for obj_sentrygun if the view offset prop name changes.
    out[2] += 45.0;
}

void GetTargetAimPoint(int target, float out[3])
{
    if (target >= 1 && target <= MaxClients)
    {
        GetClientEyePosition(target, out);
        return;
    }

    GetEntPropVector(target, Prop_Send, "m_vecOrigin", out);

    float viewOffset[3];
    if (TryGetEntPropVector(target, Prop_Data, "m_vecViewOffset", viewOffset)
        || TryGetEntPropVector(target, Prop_Send, "m_vecViewOffset", viewOffset))
    {
        AddVectors(out, viewOffset, out);
        return;
    }

    out[2] += 32.0;
}

bool TryGetEntPropVector(int entity, PropType type, const char[] prop, float out[3])
{
    if (!HasEntProp(entity, type, prop))
        return false;

    GetEntPropVector(entity, type, prop, out);
    return true;
}

float GetSentryRange(int sentry)
{
    if (HasEntProp(sentry, Prop_Send, "m_flSentryRange"))
        return GetEntPropFloat(sentry, Prop_Send, "m_flSentryRange");

    if (HasEntProp(sentry, Prop_Data, "m_flSentryRange"))
        return GetEntPropFloat(sentry, Prop_Data, "m_flSentryRange");

    return 1100.0;
}

float GetVectorDistanceSquared(const float a[3], const float b[3])
{
    float dx = a[0] - b[0];
    float dy = a[1] - b[1];
    float dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

int ResolveEntityRef(int ref)
{
    if (ref == INVALID_ENT_REFERENCE)
        return -1;

    int entity = EntRefToEntIndex(ref);
    if (entity <= 0 || !IsValidEntityIndex(entity))
        return -1;

    return entity;
}

bool IsValidEntityIndex(int entity)
{
    return entity > 0 && entity <= MAX_EDICTS_TRACKED && IsValidEntity(entity);
}
