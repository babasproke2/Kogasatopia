#if defined _kogasa_server_context_helper_included
    #endinput
#endif
#define _kogasa_server_context_helper_included

stock int ServerContext_GetHostPort()
{
    ConVar hostPort = FindConVar("hostport");
    return hostPort == null ? 0 : hostPort.IntValue;
}

stock void ServerContext_GetCurrentMapName(char[] output, int maxlen)
{
    if (GetFeatureStatus(FeatureType_Native, "DGM_CurrentNormalizedMap") == FeatureStatus_Available
        && DGM_CurrentNormalizedMap(output, maxlen))
    {
        return;
    }

    GetCurrentMap(output, maxlen);
    if (GetFeatureStatus(FeatureType_Native, "DGM_NormalizeMapName") == FeatureStatus_Available)
    {
        DGM_NormalizeMapName(output, output, maxlen);
    }
}

stock void ServerContext_GetGamemodeKey(char[] output, int maxlen)
{
    strcopy(output, maxlen, "default");
    if (GetFeatureStatus(FeatureType_Native, "DGM_GetGameModeKey") == FeatureStatus_Available)
    {
        DGM_GetGameModeKey(output, maxlen);
    }
}
