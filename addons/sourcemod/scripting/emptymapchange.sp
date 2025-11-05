#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <keyvalues>

#define PLUGIN_VERSION "1.1"

public Plugin myinfo = 
{
    name = "Empty Server Map Changer",
    author = "Hombre",
    description = "Changes map if server is empty after X minutes",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

Handle g_hTimer = null;
ArrayList g_MapList = null;
ConVar g_cvConfigFile;
ConVar g_cvCheckTimer;
ConVar g_cvIgnoreBaseMap;
ConVar g_cvBaseMaps;
char CONFIG_FILE[128] = "";

public void OnPluginStart()
{
    // Create the map list array
    g_MapList = new ArrayList(PLATFORM_MAX_PATH);    
    g_cvConfigFile = CreateConVar("sm_emptymaps_file", "empty_server_maps.cfg", "Specifies the config file to load for map settings", FCVAR_PROTECTED);
    g_cvCheckTimer = CreateConVar("sm_emptymaps_time", "60.0", "Empty map check interval", FCVAR_PROTECTED);
    g_cvIgnoreBaseMap = CreateConVar("sm_ignore_base_map", "0", "If 1, do not change map when current map matches sm_base_maps", FCVAR_PROTECTED);
    g_cvBaseMaps = CreateConVar("sm_base_maps", "mge_eientei_v4a", "Comma-separated list of base maps to ignore when sm_ignore_base_map is enabled", FCVAR_PROTECTED);
}

public void OnConfigsExecuted()
{
    g_cvConfigFile.GetString(CONFIG_FILE, sizeof(CONFIG_FILE));
    LoadMapList();
}

void LoadMapList()
{
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", CONFIG_FILE);
    
    // Clear existing map list
    g_MapList.Clear();
    
    // Open the file for reading
    File file = OpenFile(sPath, "r");
    
    if (file == null)
    {
        LogError("Could not read map list file: %s. Creating default.", sPath);
        CreateDefaultConfig(sPath);
        return;
    }
    
    char line[PLATFORM_MAX_PATH];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        // Trim whitespace and comments
        TrimString(line);
        if (line[0] == '\0' || line[0] == '/' || line[0] == ';') continue;
        
        // Add to map list
        g_MapList.PushString(line);
    }
    
    delete file;
    
    // Check if we loaded any maps
    if (g_MapList.Length == 0)
    {
        LogError("No maps found in config file, using defaults");
        CreateDefaultConfig(sPath);
    }
    else
    {
        LogMessage("Successfully loaded %d maps from config", g_MapList.Length);
    }
}

void CreateDefaultConfig(const char[] path)
{
    // Default maps (your original list)
    char defaultMaps[][] = {
        "koth_harvest_final",
        "ctf_2fort",
        "arena_lumberyard",
        "cp_gravelpit",
        "pl_badwater"
    };
    
    // Create the directory if it doesn't exist
    char dirPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dirPath, sizeof(dirPath), "configs");
    if (!DirExists(dirPath))
    {
        CreateDirectory(dirPath, 511);
    }
    
    // Write the default config
    File file = OpenFile(path, "w");
    if (file == null)
    {
        LogError("Could not create default config file: %s", path);
        return;
    }
    
    file.WriteLine("// Empty Server Map Changer Configuration");
    file.WriteLine("// Add one map per line");
    file.WriteLine("");
    
    for (int i = 0; i < sizeof(defaultMaps); i++)
    {
        file.WriteLine(defaultMaps[i]);
        g_MapList.PushString(defaultMaps[i]);
    }
    
    delete file;
    LogMessage("Created default config file with %d maps", g_MapList.Length);
}

public void OnMapStart()
{
    // Create a 30 minute repeating timer
    float minutes = GetConVarFloat(g_cvCheckTimer);
    float seconds = (60.0 * minutes);
    g_hTimer = CreateTimer(seconds, Timer_CheckPlayers, _, TIMER_REPEAT);
    PrintToServer("Empty server check timer started. Will check in %.1f minutes...", minutes);
}

public Action Timer_CheckPlayers(Handle timer)
{    
	int playerCount = GetClientCount(true); // Count connecting players
	
	if (playerCount == 0)
	{
		g_hTimer = null;
		ChangeToRandomMap();
		return Plugin_Stop;
	}
	else
	{
        PrintToServer("Empty server check in %.1f minutes...", GetConVarFloat(g_cvCheckTimer));
	}
    
    return Plugin_Continue;
}

void ChangeToRandomMap()
{
    if (g_MapList.Length == 0)
    {
        LogError("No maps available in map list!");
        return;
    }
    
    int randomIndex = GetRandomInt(0, g_MapList.Length - 1);
    char nextMap[PLATFORM_MAX_PATH];
    g_MapList.GetString(randomIndex, nextMap, sizeof(nextMap));
    
    // If configured, skip changing maps when the current map matches a declared base map
    if (GetConVarBool(g_cvIgnoreBaseMap))
    {
        if (IsCurrentMapIgnored())
        {
            char cur[PLATFORM_MAX_PATH];
            GetCurrentMap(cur, sizeof(cur));
            PrintToServer("Empty server: current map '%s' is in ignore list; skipping map change", cur);
            return;
        }
    }

    PrintToServer("Server empty after specified time limit, changing to map: %s", nextMap);
    ForceChangeLevel(nextMap, "Server was empty for specified time");
}

// Returns true if the current map exactly matches any map listed in sm_base_maps (comma-separated)
bool IsCurrentMapIgnored()
{
    char curMap[PLATFORM_MAX_PATH];
    GetCurrentMap(curMap, sizeof(curMap));

    char list[1024];
    g_cvBaseMaps.GetString(list, sizeof(list));

    // Normalize: compare case-insensitively
    TrimString(list);
    if (list[0] == '\0') return false;

    int len = strlen(list);
    int pos = 0;
    while (pos < len)
    {
        // skip whitespace
        while (pos < len && (list[pos] == ' ' || list[pos] == '\t')) pos++;
        if (pos >= len) break;

        int end = pos;
        while (end < len && list[end] != ',') end++;

        char token[256];
        int toklen = end - pos;
        if (toklen > 0)
        {
            toklen = (toklen >= sizeof(token)) ? sizeof(token)-1 : toklen;
            for (int k = 0; k < toklen; k++)
            {
                token[k] = list[pos + k];
            }
            token[toklen] = '\0';
            TrimString(token);
            if (StrEqual(token, curMap, false))
            {
                return true;
            }
        }

        pos = end + 1; // move past comma
    }

    return false;
}

public void OnMapEnd()
{
    if (g_hTimer != null)
    {
        KillTimer(g_hTimer);
        g_hTimer = null;
    }
}

public void OnPluginEnd()
{
    delete g_MapList;
}

