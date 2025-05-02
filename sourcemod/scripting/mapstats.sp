public Plugin myinfo = {
        name = "Map Popularity Stats",
        author = "Hombre",
        description = "Collects map frequency data",
        version = "1.1",
        url = "https://gyate.net",
};

new String:g_sFilePath[PLATFORM_MAX_PATH];
String:MapName[256];

public OnPluginStart()
{
        BuildPath(Path_SM, g_sFilePath, sizeof(g_sFilePath), "logs/");

        if (!DirExists(g_sFilePath))
        {
                CreateDirectory(g_sFilePath, 511);
                if (!DirExists(g_sFilePath))
                SetFailState("Failed to create directory at /sourcemod/logs/ - Please manually create that path and reload this plugin.");
        }

}

public OnMapStart()
{
	GetCurrentMap(MapName, 256);
	CreateTimer(180.0, LogTime, TIMER_REPEAT);
}

public Action LogTime(Handle Timer)
{
	int PlayerCount = GetClientCount(true);
	if (PlayerCount >= 4) {
		LogMap(PlayerCount);
	}
	return Plugin_Handled;
}

public void LogMap(int PlayerCount)
{
	BuildPath(Path_SM, g_sFilePath, sizeof(g_sFilePath), "/logs/mapstats.txt");
	new Handle:FileHandle = OpenFile(g_sFilePath, "a+");
	char Time[32];
	FormatTime(Time, sizeof(Time), "%I-%M-%S", GetTime()); 
	WriteFileLine(FileHandle, "%s | %i | %s", MapName, PlayerCount, Time);
	CloseHandle(FileHandle);
}
