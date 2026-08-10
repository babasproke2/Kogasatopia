#if defined _kogasa_duel_detection_helper_included
    #endinput
#endif
#define _kogasa_duel_detection_helper_included

static Handle g_DuelDetectionGameConf = null;
static Handle g_DuelDetectionCall = null;
static bool g_DuelDetectionAvailable = false;

stock void DuelDetection_Initialize()
{
    // Credit to AW 'Swixel' Stanley for duel detection.
    g_DuelDetectionGameConf = LoadGameConfigFile("duel.tf2");
    if (g_DuelDetectionGameConf == null)
    {
        SetFailState("Missing duel.tf2 gamedata; refusing to run without duel protection.");
        return;
    }

    StartPrepSDKCall(SDKCall_Static);
    if (!PrepSDKCall_SetFromConf(g_DuelDetectionGameConf, SDKConf_Signature, "IsInDuel"))
    {
        SetFailState("Missing IsInDuel signature in duel.tf2; refusing to run without duel protection.");
        return;
    }

    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
    g_DuelDetectionCall = EndPrepSDKCall();
    if (g_DuelDetectionCall == null)
    {
        SetFailState("Failed to create IsInDuel SDKCall; refusing to run without duel protection.");
        return;
    }

    g_DuelDetectionAvailable = true;
}

stock void DuelDetection_Shutdown()
{
    g_DuelDetectionAvailable = false;
    delete g_DuelDetectionCall;
    g_DuelDetectionCall = null;
    delete g_DuelDetectionGameConf;
    g_DuelDetectionGameConf = null;
}

stock bool DuelDetection_IsClientInDuel(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }

    if (!g_DuelDetectionAvailable || g_DuelDetectionCall == null)
    {
        return true;
    }

    return SDKCall(g_DuelDetectionCall, client) != 0;
}
