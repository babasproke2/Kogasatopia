#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <keyvalues>

#define PLUGIN_VERSION "1.1"
#define CONFIG_FILE "empty_server_maps.cfg"

public Plugin myinfo = 
{
    name = "Empty Server Map Changer",
    author = "Hombre",
    description = "Changes map if server is empty after 30 minutes",
    version = PLUGIN_VERSION,
    url = "https://tf2.gyate.net"
};

Handle g_hTimer = null;
ArrayList g_MapList = null;

public void OnPluginStart()
{
    // Create the map list array
    g_MapList = new ArrayList(PLATFORM_MAX_PATH);
    
    // Load the config file
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
    g_hTimer = CreateTimer(1800.0, Timer_CheckPlayers, _, TIMER_REPEAT);
    PrintToServer("Empty server check timer started. Will check in 30 minutes...");
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
        PrintToServer("Empty server check in 30 minutes...");
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
    
    PrintToServer("Server empty after 30 minutes, changing to map: %s", nextMap);
    ForceChangeLevel(nextMap, "Server was empty for 30 minutes");
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
