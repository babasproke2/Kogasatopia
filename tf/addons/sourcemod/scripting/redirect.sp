#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define MAXSERVERS         25
char szSever[MAXSERVERS][32];
char szSvrIP[MAXSERVERS][32];
int iMaxServers;
int iCurrentServer = -1;
char szCurrentIP[32];
Menu hServerMenu = null;
ConVar cvShowAddress = null;

#define PLUGIN_VERSION              "1.1.2"
public Plugin myinfo = {
	name = "Supreme Redirect System",
	author = "Mitchell",
	description = "Uses the new 'redirect' command to make a player join a different server.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?p=2261322"
};
/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
------Plugin Functions
<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/
public void OnPluginStart() {
	cvShowAddress = CreateConVar( "sm_supremeredirect_showaddress", "0", "Set to 1 to show the address of the server as a disabled item, 2 to let the player connect to the current server." );
	AutoExecConfig();
	CreateConVar("sm_supremeredirect_version", PLUGIN_VERSION, "Redirect Version",  FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	RegAdminCmd("sm_servers", Cmd_Redirect, 0);
	RegAdminCmd("sm_redirect", Cmd_Redirect, 0);
	RegAdminCmd("sm_direct", Cmd_Redirect, 0);
}

public void OnMapStart() {
	LoadConfig();
	SetupMenu();
}

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
------Cmd_Redirect		(type: Public Function)
	Sends the redirect menu.
<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/
public Action Cmd_Redirect(int client, int args) {
	if(client && IsClientInGame(client)) {
		if(IsRedirectMenuReady()) {
			DisplayMenu(hServerMenu, client, MENU_TIME_FOREVER);
		}
	}
	return Plugin_Handled;
}
/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
------SetupMenu		(type: Public Function)
	Setups a menu...wat
<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/
public void SetupMenu() {
	if(hServerMenu != null) {
		delete hServerMenu;
		hServerMenu = null;
	}
	hServerMenu = CreateMenu(Menu_Redirect, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(hServerMenu, "Server Redirect:");
	int iAction = GetConVarInt(cvShowAddress);
	if(iAction == 1 && iCurrentServer != -1) {
		AddMenuItem(hServerMenu, "", szSever[iCurrentServer], ITEMDRAW_DISABLED);
	}
	for(int i = 0; i < iMaxServers; i++) {
		if(iAction <= 1 && iCurrentServer == i) {
			continue;
		}
		AddMenuItem(hServerMenu, szSvrIP[i], szSever[i]);
	}
	SetMenuExitButton(hServerMenu, true);
}
public int Menu_Redirect(Menu main, MenuAction action, int client, int param2) {
	switch (action) {
		case MenuAction_Select: {
			char info[32];
			GetMenuItem(main, param2, info, sizeof(info));
			ClientCommand(client, "redirect %s", info);
			PrintToChat(client, "Attempting redirect; ensure cl_showpluginmessage is set to 1");
		}
	}
	return 0;
}
/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
------LoadConfig		(type: Public Function)
	Loads the config from 
<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<*/
public void LoadConfig() {
	iCurrentServer = -1;
	iMaxServers = 0;
	//Could probably use steam tools or something and use this as a fall back method.
	char sHostIP[32];
	char sHostPort[8];
	GetConVarString(FindConVar("ip"), sHostIP, 32);
	GetConVarString(FindConVar("hostport"), sHostPort, 8);
	Format(szCurrentIP, sizeof(szCurrentIP), "%s:%s", sHostIP, sHostPort);
	PrintToServer(szCurrentIP);
	SMCParser SMC = SMC_CreateParser();
	SMC_SetReaders(SMC, NewSection, KeyValue, EndSection); 
	char sPaths[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPaths, sizeof(sPaths),"configs/redirect.cfg");
	SMC_ParseFile(SMC, sPaths);
	CloseHandle(SMC);
}
public SMCResult NewSection(SMCParser smc, const char[] name, bool opt_quotes)
{
	return SMCParse_Continue;
}

public SMCResult EndSection(SMCParser smc)
{
	return SMCParse_Continue;
}

public SMCResult KeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes) {
	if (iMaxServers >= MAXSERVERS) {
		LogError("[SupremeRedirect] Too many servers in redirect.cfg (max %d). Skipping %s", MAXSERVERS, key);
		return SMCParse_Continue;
	}
	strcopy(szSever[iMaxServers], 32, key);
	strcopy(szSvrIP[iMaxServers], 32, value);
	if(StrEqual(value, szCurrentIP)) {
		iCurrentServer = iMaxServers;
	}
	iMaxServers++;
	return SMCParse_Continue;
}
public bool IsRedirectMenuReady() {
	return hServerMenu != null;
}
