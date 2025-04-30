ConVar g_cvEnabled;
ConVar g_cvBots;
ConVar g_cvCritCheck;
ConVar g_cvEnabledOverride;
ConVar g_cvRespawnTime;

// List of 5CP maps
static const char g_sMapKeywords[][] = {
    "cp_badlands",
    "cp_sunshine",
    "cp_granary",
    "cp_process_final",
    "cp_gullywash_final1",
    "cp_yukon_final",
    "cp_freight_final",
    "cp_coldfront",
    "cp_obscure",
    "cp_shabbytown",
    "cp_tidal",
    "cp_croissant",
    "cp_snakewater_final1"
};

bool g_bArena;
bool g_bKoth;
bool g_bPayload;
bool g_bCTF;
bool g_bMedieval;
bool g_bPD;
bool g_bPushCP;
bool g_bSymmetrical;

void DetectGameMode()
{
    g_bArena = IsArenaMap();
    g_bKoth = IsKothMap();
    g_bPayload = IsPayloadMap();
    g_bCTF = IsCTFMap();
    g_bMedieval = IsMedievalMap();
    g_bPD = IsPDMap();
    g_bPushCP = Is5cpMap();
    g_bSymmetrical = (g_bArena || g_bCTF || g_bPD || g_bKoth);

    if (g_bArena) {
        ServerCommand("exec d_arena.cfg");
    }
    else if (g_bKoth) {
        ServerCommand("exec d_koth.cfg");
    }
    else if (g_bPayload) {
        ServerCommand("exec d_payload.cfg");
    }
    else if (g_bCTF) {
        ServerCommand("exec d_ctf.cfg");
    }
    else if (g_bMedieval) {
        ServerCommand("exec d_medieval.cfg");
    }
    else if (g_bPD) {
        ServerCommand("exec d_pd.cfg");
    }
    else if (g_bPushCP) {
        ServerCommand("exec d_5cp.cfg");
    }
}

stock bool isArenaMap()
{
    return FindEntityByClassname(-1, "tf_logic_arena") != -1;
}

stock bool isKothMap()
{
    return FindEntityByClassname(-1, "tf_logic_koth") != -1;
}

stock bool isPayloadMap()
{
    return FindEntityByClassname(-1, "mapobj_cart_dispenser") != -1;
}

stock bool isCTFMap()
{
    return FindEntityByClassname(-1, "item_teamflag") != -1;
}

stock bool isMedievalMap()
{
    return FindEntityByClassname(-1, "tf_logic_medieval") != -1;
}

stock bool isPDMap()
{
    return FindEntityByClassname(-1, "tf_logic_player_destruction") != -1;
}

stock bool is5cpMap()
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));

    for (int i = 0; i < sizeof(g_sMapKeywords); i++) {
        if (StrContains(mapName, g_sMapKeywords[i], false) != -1) {
            return true;
        }
    }
    return false;
}

stock bool isValidClient(int client)
{
    return (1 <= client <= MaxClients) && IsClientInGame(client);
}
