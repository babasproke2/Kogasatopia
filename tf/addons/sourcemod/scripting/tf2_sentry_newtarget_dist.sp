#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#include <tf2_sentry_newtarget_dist>

#define PLUGIN_VERSION "1.1.0"

ConVar gCvarEnable;
ConVar gCvarDistance;

public Plugin myinfo =
{
    name = "[TF2] Sentry NewTarget Distance",
    author = "Hombre",
    description = "Overrides sentry target acquisition range for normal and mini sentries.",
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
        "Enable configurable sentry target acquisition range. 0 = stock TF2 behavior, 1 = enabled.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0
    );

    gCvarDistance = CreateConVar(
        "sm_tf2_sentry_newtarget_dist",
        "200.0",
        "Sentry target acquisition range in Hammer Units. Applies to normal and mini sentries.",
        FCVAR_NOTIFY,
        true,
        0.0
    );

    HookConVarChange(gCvarEnable, OnControlCvarChanged);
    HookConVarChange(gCvarDistance, OnControlCvarChanged);

    AutoExecConfig(true, "tf2_sentry_newtarget_dist");
    ApplySettings();

    int offset = TF2SentryNewTarget_GetRangeOffset();
    LogMessage("tf2_sentry_newtarget_dist loaded. m_flSentryRange offset = %d", offset);
}

public void OnConfigsExecuted()
{
    ApplySettings();
}

public void OnPluginEnd()
{
    // The extension's detour remains installed while the extension is loaded, but
    // disabling the override immediately returns future FindTarget() calls to stock.
    TF2SentryNewTarget_SetEnabled(false);
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ApplySettings();
}

void ApplySettings()
{
    bool enabled = gCvarEnable.BoolValue;
    float distance = gCvarDistance.FloatValue;

    if (distance < 0.0)
        distance = 0.0;

    TF2SentryNewTarget_SetDistance(distance);
    TF2SentryNewTarget_SetEnabled(enabled);
}
