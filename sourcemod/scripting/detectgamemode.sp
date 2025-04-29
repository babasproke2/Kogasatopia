#include <sourcemod>
#include <sdktools_functions>
#include <tf2>
#define PLUGIN_VERSION "2.0"

ConVar g_sEnabled;
ConVar g_sBots;
ConVar g_sCritCheck;
ConVar g_sEnabledOverride;
ConVar g_sRespawnTime;

// List of 5CP maps
char mapKeywords[][] = {
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

bool arena;
bool koth;
bool payload;
bool ctf;
bool medieval;
bool pd;
bool pushcp;
bool sym;

public Plugin myinfo = {
	name = "Gamemode Detector",
	author = "Hombre",
	description = "Handles gamemode settings and instant respawns",
	version = "1.1",
	url = "https://tf2.gyate.net",
};

public void OnPluginStart()
{
	g_sEnabledOverride = CreateConVar("respawn_time_override", "3", "Enable/Disable respawn times");
	g_sEnabled = CreateConVar("disable_respawn_times", "0", "Override respawn times");
	g_sRespawnTime = CreateConVar("respawn_time", "1", "Respawn time length");
	g_sBots = CreateConVar("sm_bots", "0", "Allow dynamic bots at low playercounts");
    g_sCritCheck = CreateConVar("sm_critcheck", "1", "Allow the plugin to check if crits should be enabled or disabled");
	//The convar above was created in case votemenu (or any other external factor) is used for choosing the random crits value
	RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_KICK, "Toggles respawn times");
	RegConsoleCmd("sm_bots", Command_BotToggle, "Toggle lowpop bots");
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("teamplay_round_active", OnRoundFreezeEnd);
	
	arena = false;
	koth = false;
	payload = false;
	ctf = false;
	medieval = false;
	pd = false;
	pushcp = false;
	sym = false;

	CreateTimer(15.0, Timer_CritToggle, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	SetConVarInt(g_sEnabledOverride, 0);
}

public Action Timer_CritToggle(Handle timer)
{
	if (GetConVarInt(g_sCritCheck) == 0) return Plugin_Continue;
	char auth[32];
	GetClientAuthString(i, auth, sizeof(auth));
	for (new i = 1; i <= MaxClients; i++) {
                if (IsClientInGame(i) && IsValidClient(i))
                {
                        if ((StrEqual(auth, "STEAM_0:1:33166791"))) {
                                ServerCommand("exec d_crits.cfg");
				break;
                        } else {
                                 ServerCommand("exec d_nocrits.cfg");
                        }
                }
	}
	return Plugin_Continue;
}

public Action Command_RespawnToggle(int client, int args) {
	if ( GetConVarInt(g_sEnabledOverride) == 1 || GetConVarInt(g_sEnabledOverride) == 3 )
	{
		SetConVarInt(g_sEnabledOverride, 0);
		PrintToChat(client, "Respawn times forced on");
	} else {
		SetConVarInt(g_sEnabledOverride, 1);
		PrintToChat(client, "Respawn times forced off"); 
	} 
	return Plugin_Handled;
}

public Action:OnPlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (arena) return;
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (!(IsValidClient(client))) return;

	int g_sEnabled2;
	if (GetConVarInt(g_sEnabledOverride) != 3) {
		g_sEnabled2 = GetConVarInt(g_sEnabledOverride);
	} else g_sEnabled2 = GetConVarInt(g_sEnabled);

	if (g_sEnabled2 == 1) {
		float time = GetConVarFloat(g_sRespawnTime);
		CreateTimer(time, respawnClient, client);
		return;
	}
}

public Action:OnRoundFreezeEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (GetConVarInt(g_sBots) == 1 && GetClientCount(true) < 8) {
		ServerCommand("exec bots");
	}
}

public Action:respawnClient(Handle:timer, int client)
{
	RequestFrame(Respawn, GetClientSerial(client));
	return Plugin_Handled;
}

public Action:Command_BotToggle(int client, int args)
{
	if (!client) return Plugin_Continue;
	if (GetConVarInt(g_sBots) == 1) {
		SetConVarInt(g_sBots, 0);
		ServerCommand("exec nobots");
		PrintToChatAll("bots disabled! Use !bots again to return them.");
	} else {
		SetConVarInt(g_sBots, 1);
                ServerCommand("exec bots");
		PrintToChatAll("bots enabled! Use !bots again to disable them. These disappear above 7 players.");
	}
	return Plugin_Continue;
}

public Respawn(any:serial)
{
	new client = GetClientFromSerial(serial);
	if (IsValidClient(client))
	{
		new team = GetClientTeam(client);
		if(!IsPlayerAlive(client) && team != 1)
		{
			TF2_RespawnPlayer(client);
		}
	}
}

bool:IsValidClient(client)
{
	if ( !( 1 <= client <= MaxClients ) || !IsClientInGame(client) )
		return false;

	return true;
}

public void OnClientPutInServer(int client)
{
	CheckPlayercount();
}

public void OnClientDisconect(int client)
{
	CheckPlayercount();
}

public Action CheckPlayercount()
{
	int PlayerCount = GetClientCount(false);

	if (!sym) {
		// Asymmetric case
		if (PlayerCount > 11) {
			ServerCommand("exec d_highpop_pl.cfg");
		} else {
			ServerCommand("exec d_lowpop.cfg");
		}
	} else {
		// Symmetric case
		if (PlayerCount > 15) {
			ServerCommand("exec d_highpop.cfg");
		} else {
			ServerCommand("exec d_lowpop.cfg");
		}
	}
	
	return Plugin_Handled;
}

public void OnConfigsExecuted()
{
		if (IsArenaMap())
		{
				ServerCommand("exec d_arena.cfg");
				arena = IsArenaMap();
		}
		else if (IsKothMap())
		{
				ServerCommand("exec d_koth.cfg");
				koth = IsKothMap();
		}
		else if (IsPayloadMap())
		{
				ServerCommand("exec d_payload.cfg");
				payload = IsPayloadMap();
		}
		else if (IsCTFMap())
		{
				ServerCommand("exec d_ctf.cfg");
				ctf = IsCTFMap();
		}
		else if (IsMedievalMap())
		{
				ServerCommand("exec d_medieval.cfg");
				medieval = IsMedievalMap();
		}
		else if (IsPDMap())
		{
				ServerCommand("exec d_pd.cfg");
				pd = IsPDMap();	
		}
		if (Is5cpMap())
		{
				ServerCommand("exec d_5cp.cfg");
				pushcp = Is5cpMap();	
		}
		if (arena || ctf || pd || koth) sym = true;
}

public bool:IsArenaMap()
{
	new iEnt = FindEntityByClassname(-1, "tf_logic_arena");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:IsKothMap()
{
	new iEnt = FindEntityByClassname(-1, "tf_logic_koth");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:IsPayloadMap()
{
	new iEnt = FindEntityByClassname(-1, "mapobj_cart_dispenser");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:IsCTFMap()
{
	new iEnt = FindEntityByClassname(-1, "item_teamflag");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:IsMedievalMap()
{
	new iEnt = FindEntityByClassname(-1, "tf_logic_medieval");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:IsPDMap()
{
	new iEnt = FindEntityByClassname(-1, "tf_logic_player_destruction");
	
	if (iEnt == -1)
		return false;
	else
		return true;
}

public bool:Is5cpMap()
{
	char MapName[256];
	GetCurrentMap(MapName, 256);
	for (int i = 0; i < sizeof(mapKeywords); i++)
	{
		if (StrContains(MapName, mapKeywords[i], false) != -1)
		{
			return true;
		} else return false;
	}
	
}
