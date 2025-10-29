#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdktools_functions>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#include <tf_custom_attributes>
#include <clientprefs>
#include <tf2attributes>

#define MP 34
#define ME 2048
#define PLUGIN_VERSION "2.5"

// Models and Sounds
#define AmplifierModel "models/buildables/amplifier_test/amplifier"
#define AmplifierTex "materials/models/buildables/amplifier_test/amplifier"
#define AMPgib "models/buildables/amplifier_test/gibs/amp_gib"
#define AMPLIFIER_SOUND "misc/rd_finale_beep01.wav"
#define AMPLIFIER_EMPTY_SOUND "hl1/fvox/beep.wav"
#define AMPLIFIER_BUFF_SOUND "weapons/dispenser_heal.wav"
#define AMPLIFIER_FILL_SOUND "weapons/dispenser_generate_metal.wav"

#define ATTR_FIRE_RATE "fire rate bonus HIDDEN"
#define ATTR_RELOAD_RATE "reload time increased hidden" // Set to < 1 for more speed
#define BEGGARS_BAZOOKA 730

// Sprites
int g_BeamSprite;
int g_HaloSprite;

// Player State
enum struct AmplifierPlayerState
{
    bool useDispenser;
    bool useSentry;
    bool nearAmplifier;
    int engiAssists;
    Handle effectTimer;
}

AmplifierPlayerState g_PlayerState[MP];

Handle g_hAmplifierTimer = INVALID_HANDLE;
// Building States
bool AmplifierOn[ME];
bool AmplifierMini[ME];
bool AmplifierSapped[ME];
bool ConditionApplied[ME][MP];
float AmplifierDistance[ME];
TFCond AmplifierCondition[ME];
int BuildingRef[ME];
float AmplifierFill[ME];

// ConVars
ConVar cvarMetal;
ConVar cvarMetalMax;
ConVar cvarDistance;
ConVar cvarEffectLength;
ConVar cvarForceAmplifier;
ConVar cvarEnableExplosion;
ConVar cvarEnableZap;

// Cached ConVar Values
int MetalPerPlayer = 5;
int MetalMax = 200;
TFCond DefaultCondition = TFCond_RuneHaste; // Formerly TFCond_Buffed
float DefaultDistance = 225.0;
float DefaultEffectLength = 4.0;
int ForceAmplifier = 0; // 0=nothing, 1=dispenser, 2=sentry, 3=both
int EnableExplosion = 65;
int EnableZap = 0; // I prefer 20

// Forward
Handle fwdOnAmplify;
Handle g_hPadCookie;

// Native Control
bool NativeControl;
TFCond NativeConditionDisp[MP];
TFCond NativeConditionSentry[MP];
float NativeDistanceDisp[MP];
float NativeDistanceSentry[MP];
int NativePercentDisp[MP];
int NativePercentSentry[MP];

// Client Preferences
Handle g_hCookieDisp;
Handle g_hCookieSentry;

#tryinclude <tf2_player>
#if !defined _tf2_player_included
    #define TF2_IsDisguised(%1) (((%1) & TF_CONDFLAG_DISGUISED) != TF_CONDFLAG_NONE)
    #define TF2_IsCloaked(%1) (((%1) & TF_CONDFLAG_CLOAKED) != TF_CONDFLAG_NONE)
#endif

static void ResetPlayerState(int client, bool resetPreferences = true)
{
    if (client <= 0 || client >= sizeof(g_PlayerState))
        return;

    if (g_PlayerState[client].effectTimer != INVALID_HANDLE)
    {
        delete g_PlayerState[client].effectTimer;
    }

    g_PlayerState[client].effectTimer = INVALID_HANDLE;

    g_PlayerState[client].nearAmplifier = false;
    g_PlayerState[client].engiAssists = 0;

    if (resetPreferences)
    {
        g_PlayerState[client].useDispenser = false;
        g_PlayerState[client].useSentry = false;
    }
}

public Plugin:myinfo = {
	name = "The Amplifier (Unified)",
	author = "RainBolt Dash (plugin); Jumento M.D. (idea & model); Naris and FlaminSarge (helpers); Bad Hombre (new fork)",
	description = "Adds The Amplifier for Dispenser and/or Sentry",
	version = PLUGIN_VERSION,
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("ControlAmplifier", Native_ControlAmplifier);
	CreateNative("SetAmplifierDisp", Native_SetAmplifierDisp);
	CreateNative("SetAmplifierSentry", Native_SetAmplifierSentry);
	CreateNative("HasAmplifier", Native_HasAmplifier);
	CreateNative("ConvertToAmplifier", Native_ConvertToAmplifier);
	fwdOnAmplify = CreateGlobalForward("OnAmplify", ET_Hook, Param_Cell, Param_Cell, Param_Cell);
	RegPluginLibrary("Amplifier");
	return APLRes_Success;
}

public OnPluginStart()
{
	CreateConVar("amplifier_version", PLUGIN_VERSION, "The Amplifier Version", FCVAR_REPLICATED|FCVAR_NOTIFY);
	cvarEffectLength = CreateConVar("amplifier_effect_length", "2.5", "Length in seconds for the Amplifier condition to last", FCVAR_PLUGIN);
	cvarDistance = CreateConVar("amplifier_distance", "240.0", "Distance the amplifier works.", FCVAR_PLUGIN);
	cvarMetalMax = CreateConVar("amplifier_max", "200.0", "Maximum amount of metal an amplifier can hold.", FCVAR_PLUGIN);
	cvarMetal = CreateConVar("amplifier_metal", "5.0", "Amount of metal to use to apply a condition to a player (per second).", FCVAR_PLUGIN);
	cvarForceAmplifier = CreateConVar("amplifier_force", "0", "Force amplifier mode: 0=nothing, 1=dispenser, 2=sentry, 3=both", FCVAR_PLUGIN, true, 0.0, true, 3.0);
	cvarEnableExplosion = CreateConVar("amplifier_explode", "65", "Enable Amplifier death explosions? >0 for damage value.", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	cvarEnableZap = CreateConVar("amplifier_zap", "0", "Should Amplifier pulses harm the enemy team? 0 to disable, >0 for damage.", FCVAR_PLUGIN, true, 0.0, true, 50.0);

	HookEvent("player_builtobject", Event_Build);
    HookEvent("object_destroyed", Event_ObjectDestroyed);
	HookEvent("player_death", event_player_death);
	
	RegConsoleCmd("sm_amplifier", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_a", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_p", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_amp", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_amphelp", HelpPanel, "Show info about Amplifier");
	RegConsoleCmd("sm_amphelp", HelpPanel, "Show info about Amplifier");
	RegConsoleCmd("sm_ah", HelpPanel, "Show info about Amplifier");
	RegConsoleCmd("sm_ph", HelpPanel, "Show info about Amplifier");

	g_hPadCookie = FindClientCookie("engipads_toggle");

	AutoExecConfig(true, "amplifier");
	
	// Cookies
	g_hCookieDisp = RegClientCookie("amplifier_dispenser", "Dispenser Amplifier preference", CookieAccess_Public);
	g_hCookieSentry = RegClientCookie("amplifier_sentry", "Sentry Amplifier preference", CookieAccess_Public);
	
	HookConVarChange(cvarMetal, CvarChange);
	HookConVarChange(cvarMetalMax, CvarChange);
	HookConVarChange(cvarEffectLength, CvarChange);
	HookConVarChange(cvarDistance, CvarChange);
	HookConVarChange(cvarForceAmplifier, CvarChange);
	
	for (new i = 1; i <= MaxClients; i++)
	{
		ResetPlayerState(i);
		if (IsClientInGame(i))
			OnClientPostAdminCheck(i);
	}
}

public OnPluginEnd()
{
	if (g_hAmplifierTimer != INVALID_HANDLE)
	{
		KillTimer(g_hAmplifierTimer);
		g_hAmplifierTimer = INVALID_HANDLE;
	}

	if (fwdOnAmplify != null)
	{
		delete fwdOnAmplify;
		fwdOnAmplify = null;
	}

	ConvertAllAmplifiersToBuildings();
}

public CvarChange(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvarMetal) MetalPerPlayer = StringToInt(newValue);
	else if (convar == cvarMetalMax) MetalMax = StringToInt(newValue);
	else if (convar == cvarDistance) DefaultDistance = StringToFloat(newValue);
	else if (convar == cvarEffectLength) DefaultEffectLength = StringToFloat(newValue);
	else if (convar == cvarEnableExplosion) EnableExplosion = StringToInt(newValue);
	else if (convar == cvarEnableZap) EnableZap = StringToInt(newValue);
	else if (convar == cvarForceAmplifier) ForceAmplifier = StringToInt(newValue);
}

public OnConfigsExecuted()
{
	DefaultDistance = GetConVarFloat(cvarDistance);
	DefaultEffectLength = GetConVarFloat(cvarEffectLength);
	EnableExplosion = GetConVarInt(cvarEnableExplosion);
	EnableZap = GetConVarInt(cvarEnableZap);
	MetalPerPlayer = GetConVarInt(cvarMetal);
	MetalMax = GetConVarInt(cvarMetalMax);
	ForceAmplifier = GetConVarInt(cvarForceAmplifier);
	g_hAmplifierTimer = CreateTimer(1.0, Timer_amplifier, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public OnMapStart()
{
	AddToDownload();
	PrecacheSound(AMPLIFIER_SOUND, true);
	PrecacheSound(AMPLIFIER_EMPTY_SOUND, true);
	//PrecacheSound("AMPLIFIER_BUFF_SOUND", true);
	//PrecacheSound("AMPLIFIER_FILL_SOUND", true);
	g_BeamSprite = PrecacheModel("materials/sprites/laser.vmt");
	g_HaloSprite = PrecacheModel("materials/sprites/halo01.vmt");
	PrecacheGeneric("particles/powerups.pcf", true);
}

public OnClientPostAdminCheck(client)
{
	if (IsFakeClient(client)) return;
	ResetPlayerState(client, false);
	
	if (AreClientCookiesCached(client))
	{
		LoadClientPreferences(client);
	}
}

public OnClientCookiesCached(client)
{
	LoadClientPreferences(client);
}

public OnClientDisconnect(client)
{
	ResetPlayerState(client);
}

void LoadClientPreferences(client)
{
	new String:szValue[8];
	
	GetClientCookie(client, g_hCookieDisp, szValue, sizeof(szValue));
	if (szValue[0] != '\0')
		g_PlayerState[client].useDispenser = bool:StringToInt(szValue);

	GetClientCookie(client, g_hCookieSentry, szValue, sizeof(szValue));
	if (szValue[0] != '\0')
		g_PlayerState[client].useSentry = bool:StringToInt(szValue);
}

void SaveClientPreferences(client)
{
	if (!AreClientCookiesCached(client)) return;
	
	new String:szValue[8];
	
	IntToString(g_PlayerState[client].useDispenser, szValue, sizeof(szValue));
	SetClientCookie(client, g_hCookieDisp, szValue);
	
	IntToString(g_PlayerState[client].useSentry, szValue, sizeof(szValue));
	SetClientCookie(client, g_hCookieSentry, szValue);
}

public AddToDownload()
{
	new String:strLine[256];
	new String:extensions[][] = {".mdl", ".dx80.vtx", ".dx90.vtx", ".sw.vtx", ".vvd", ".phy"};
	new String:extensionsb[][] = {".vtf", ".vmt"};
	
	for (new i = 0; i < sizeof(extensions); i++)
	{
		Format(strLine, 256, "%s%s", AmplifierModel, extensions[i]);
		AddFileToDownloadsTable(strLine);
		for (new j = 1; j <= 8; j++)
		{
			Format(strLine, 256, "%s%i%s", AMPgib, j, extensions[i]);
			AddFileToDownloadsTable(strLine);
		}
	}
	
	for (new i = 0; i < sizeof(extensionsb); i++)
	{
		new String:textures[][] = {"", "_blue", "_anim", "_anim_blue", "_anim2", "_anim2_blue", "_holo", "_bolt", "_holo_blue", "_radar"};
		for (new j = 0; j < sizeof(textures); j++)
		{
			Format(strLine, 256, "%s%s%s", AmplifierTex, textures[j], extensionsb[i]);
			AddFileToDownloadsTable(strLine);
		}
	}
	
	Format(strLine, 256, "%s.mdl", AmplifierModel);
	PrecacheModel(strLine, true);
	for (new i = 1; i <= 8; i++)
	{
		Format(strLine, 256, "%s%i.mdl", AMPgib, i);
		PrecacheModel(strLine, true);
	}
}

RemoveBuilding(client, const String:buildingClass[])
{
	new String:classname[64];
	new String:destroyCmd[32];
	
	if (!strcmp(buildingClass, "obj_dispenser"))
		Format(destroyCmd, 32, "destroy 0");
	else if (!strcmp(buildingClass, "obj_sentrygun"))
		Format(destroyCmd, 32, "destroy 2");
	else
		return;
	
	for (new j = 1; j < ME; j++)
	{
		new ent = EntRefToEntIndex(BuildingRef[j]);
		if (ent > 0)
		{
			GetEdictClassname(ent, classname, sizeof(classname));
			if (!strcmp(classname, buildingClass) && GetEntPropEnt(ent, Prop_Send, "m_hBuilder") == client)
			{
				Format(classname, 64, "%i", GetEntPropEnt(ent, Prop_Send, "m_iMaxHealth") + 1);
				SetVariantString(classname);
				AcceptEntityInput(ent, "RemoveHealth");
				FakeClientCommand(client, destroyCmd);
				
				Event event = CreateEvent("object_removed", true);
				if (event != null)
				{
					SetEventInt(event, "userid", GetClientUserId(client));
					SetEventInt(event, "index", ent);
					event.Fire();
				}
				AcceptEntityInput(ent, "kill");
				AmplifierFill[ent] = 0.0;
		}
	}
}
}

public AmpHelpPanelH(Handle:menu, MenuAction:action, param1, param2) { }

public Action:HelpPanel(client, Args)
{
	new Handle:panel = CreatePanel();
	
	SetPanelTitle(panel, "=== Amplifier Info ===");
	DrawPanelText(panel, "Amplifiers can replace Sentries or Dispensers");
	DrawPanelText(panel, "They consume metal to provide a fire rate and reload speed bonus to nearby teammates");
	DrawPanelText(panel, "Hit with wrench to refill");
	DrawPanelText(panel, "=== Jump/Speed Pad Info ===");
	DrawPanelText(panel, "Teleporters can be converted to Jump or Speed pads");
	DrawPanelText(panel, "Turn your pad once to place a jump pad instead of a speed pad");
	DrawPanelText(panel, "=== How To Use? ===");
	DrawPanelText(panel, "Use !a or !p to toggle these buildings");
	DrawPanelItem(panel, "Close");
	
	SendPanelToClient(panel, client, AmpHelpPanelH, 20);
	CloseHandle(panel);
}

public Action HelpPanel_Chat(int client, int Args)
{
    CPrintToChat(client, "{green}=== Amplifier Info ===");
    CPrintToChat(client, "{default}Amplifiers can replace Sentries or Dispensers");
    CPrintToChat(client, "{default}They consume metal to provide a fire rate & reload speed bonus to nearby teammates");
    CPrintToChat(client, "{default}Hit with wrench to refill");

    CPrintToChat(client, "{lightgreen}=== Jump/Speed Pad Info ===");
    CPrintToChat(client, "{default}Teleporters can be converted to Jump or Speed pads");
    CPrintToChat(client, "{default}Turn your pad once to place a jump pad instead of a speed pad");

    CPrintToChat(client, "{blue}=== How To Use? ===");
    CPrintToChat(client, "{default}Use {green}!a{default} or {green}!p{default} to toggle these buildings");

    return Plugin_Handled;
}

public Action:CallPanel(client, Args)
{
	if (!NativeControl && IsValidClient(client))
		ShowAmplifierMenu(client);
	return Plugin_Continue;
}

void ShowAmplifierMenu(client)
{
	if (!IsValidClient(client))
		return;
	
	new Handle:menu = CreateMenu(MenuHandler_Amplifier);
	
	SetMenuTitle(menu, "Amplifier Settings");
	
	char szItem[128];
	Format(szItem, sizeof(szItem), "Sentry Gun: %s", g_PlayerState[client].useSentry ? "[✓] Amplifier" : "[  ] Normal");
	AddMenuItem(menu, "sentry", szItem);
	
	Format(szItem, sizeof(szItem), "Dispenser: %s", g_PlayerState[client].useDispenser ? "[✓] Amplifier" : "[  ] Normal");
	AddMenuItem(menu, "disp", szItem);

	// I've added Engipads to this nice menu
	bool usePadSpeed = GetClientCookieBool(client, g_hPadCookie);

	Format(szItem, sizeof(szItem), "Teleporters: %s", usePadSpeed ? "[✓] Speed/Jump" : "[  ] Normal");
	AddMenuItem(menu, "tele", szItem);
	
	AddMenuItem(menu, "info", "── Help & Info ──");
	
	SetMenuExitButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

// Engipads attachment
bool GetClientCookieBool(int client, Handle cookie)
{
    char value[8];
    GetClientCookie(client, cookie, value, sizeof(value));
    return (StrEqual(value, "1") || StrEqual(value, "true"));
}

public MenuHandler_Amplifier(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		new String:info[32];
		GetMenuItem(menu, param2, info, sizeof(info));
		
		if (StrEqual(info, "disp"))
		{
			g_PlayerState[param1].useDispenser = !g_PlayerState[param1].useDispenser;
			SaveClientPreferences(param1);
			
			if (g_PlayerState[param1].useDispenser)
			{
				CPrintToChat(param1, "{orange}[Amplifier]{default} Dispensers will now be {green}Amplifiers{default}!");
				RemoveBuilding(param1, "obj_dispenser");
			}
			else
			{
				CPrintToChat(param1, "{orange}[Amplifier]{default} Dispensers will now be {lightgreen}Normal{default}!");
				RemoveBuilding(param1, "obj_dispenser");
			}
			
			ShowAmplifierMenu(param1);
		}
		else if (StrEqual(info, "sentry"))
		{
			g_PlayerState[param1].useSentry = !g_PlayerState[param1].useSentry;
			SaveClientPreferences(param1);
			
			if (g_PlayerState[param1].useSentry)
			{
				CPrintToChat(param1, "{orange}[Amplifier]{default} Sentries will now be {green}Amplifiers{default}!");
				RemoveBuilding(param1, "obj_sentrygun");
			}
			else
			{
				CPrintToChat(param1, "{orange}[Amplifier]{default} Sentries will now be {lightgreen}Normal{default}!");
				RemoveBuilding(param1, "obj_sentrygun");
			}
			
			ShowAmplifierMenu(param1);
		}
		else if (StrEqual(info, "info"))
		{
			HelpPanel(param1, 0);
		} 
		else if (StrEqual(info, "tele"))
		{
			bool usePadSpeed = GetClientCookieBool(param1, g_hPadCookie);
			usePadSpeed = !usePadSpeed; // toggle it

			char szToggle[8];
			Format(szToggle, sizeof(szToggle), "%s", usePadSpeed ? "1" : "0");

			SetClientCookie(param1, g_hPadCookie, szToggle);

			PrintToChat(param1, "[SM] Teleporter mode set to: %s", usePadSpeed ? "Speed/Jump" : "Normal");
			ShowAmplifierMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

public Action:Timer_amplifier(Handle hTimer)
{
	float Pos[3];
	float AmplifierPos[3];
	new TFTeam:clientTeam;
	new TFTeam:team;
	new maxEntities = GetMaxEntities();
	new String:modelname[256];
	
	for (new client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client)) continue;
		
	g_PlayerState[client].nearAmplifier = false;
		
		if (IsPlayerAlive(client) && IsValidEdict(client))
		{
			GetEntPropVector(client, Prop_Send, "m_vecOrigin", Pos);
			clientTeam = TFTeam:GetClientTeam(client);
			
			for (new i = 1; i < maxEntities; i++)
			{
				new amp = EntRefToEntIndex(BuildingRef[i]);
				if (amp <= 0) continue;
				
				GetEntPropString(i, Prop_Data, "m_ModelName", modelname, 128);
				if (StrContains(modelname, "plifier") == -1) continue;
				if (!AmplifierOn[amp] || AmplifierSapped[amp]) continue;
				
				new String:buildingClass[64];
				GetEdictClassname(amp, buildingClass, sizeof(buildingClass));
				new metal;
		if (!strcmp(buildingClass, "obj_dispenser"))
			metal = GetEntProp(amp, Prop_Send, "m_iAmmoMetal");
		else if (!strcmp(buildingClass, "obj_sentrygun"))
			metal = GetEntProp(amp, Prop_Send, "m_iAmmoShells");
		else
			continue;
		
		if (MetalMax > 0)
		{
			float fill = float(metal) / float(MetalMax); 
			if (fill < 0.0)
				fill = 0.0;
			if (fill < 0.4)
				fill = (fill / 0.4) + 0.6; // Taking a percentage and adding a minimum
			else fill = 1.0;
			if (fill > 1.0)
				fill = 1.0;
			AmplifierFill[amp] = fill;
		}
		
		if (metal < MetalPerPlayer && MetalPerPlayer > 0) continue;
				
		TFCond Condition = DefaultCondition;
		team = TFTeam:GetEntProp(amp, Prop_Send, "m_iTeamNum");
		
		if (TF2_GetPlayerClass(client) == TFClass_Spy && TF2_IsPlayerInCondition(client, TFCond_Disguised) && !TF2_IsPlayerInCondition(client, TFCond_Cloaked))
			team = clientTeam;
				
		GetEntPropVector(amp, Prop_Send, "m_vecOrigin", AmplifierPos);
				
		if (GetVectorDistance(Pos, AmplifierPos) <= AmplifierDistance[amp] && (TraceTargetIndex(amp, client, AmplifierPos, Pos)))
		{
			new Action:res = Plugin_Continue;
			new builder = GetEntPropEnt(amp, Prop_Send, "m_hBuilder");
			Call_StartForward(fwdOnAmplify);
			Call_PushCell(builder);
			Call_PushCell(client);
			Call_PushCell(Condition);
			Call_Finish(res);
			if (res != Plugin_Continue) continue;
			if (clientTeam == team)
			{
				AddAmplifierEffect(client);
				if (!ConditionApplied[amp][client])
				{
					EmitSoundToClient(client, AMPLIFIER_BUFF_SOUND, amp, _, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.5, SNDPITCH_HIGH);
				}
				ConditionApplied[amp][client] = true;
			} else if (EnableZap > 0) {
				DealElectricDamage(client, builder, Pos, float(EnableZap));
			}
			g_PlayerState[client].nearAmplifier = true;
			if (MetalPerPlayer > 0)
			{
				metal -= MetalPerPlayer;
				if (!strcmp(buildingClass, "obj_dispenser"))
					SetEntProp(amp, Prop_Send, "m_iAmmoMetal", metal);
				else if (!strcmp(buildingClass, "obj_sentrygun"))
					SetEntProp(amp, Prop_Send, "m_iAmmoShells", metal);
			}
			break;
		}
			}
			
		if (!g_PlayerState[client].nearAmplifier)
			{
				for (new i = 1; i < maxEntities; i++)
				{
					if (ConditionApplied[i][client])
					{
						ConditionApplied[i][client] = false;
					}
				}
			}
		}
	}
	
	for (new i = 1; i < maxEntities; i++)
	{
		new ref = BuildingRef[i];
		if (ref == 0) continue;
		
		new ent = EntRefToEntIndex(ref);
		if (ent <= 0)
		{
			BuildingRef[i] = 0;
			for (new client = 1; client <= MaxClients; client++)
			{
				if (ConditionApplied[i][client])
				{
					ConditionApplied[i][client] = false;
				}
			}
			continue;
		}
		
		GetEntPropString(ent, Prop_Data, "m_ModelName", modelname, 128);
		if (!AmplifierOn[ent] || AmplifierSapped[ent] || StrContains(modelname, "plifier") == -1) continue;
		
		if (GetEntProp(ent, Prop_Send, "m_bDisabled") == 0)
			SetEntProp(ent, Prop_Send, "m_bDisabled", 1);

		new String:buildingClass[64];
		GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
		
		new metal = GetEntProp(ent, Prop_Send, "m_iUpgradeMetal") * (MetalMax / 200);
		new oldMetal;
		if (!strcmp(buildingClass, "obj_dispenser"))
			oldMetal = GetEntProp(ent, Prop_Send, "m_iAmmoMetal");
		else if (!strcmp(buildingClass, "obj_sentrygun"))
			oldMetal = GetEntProp(ent, Prop_Send, "m_iAmmoShells");
		
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", Pos);
		Pos[2] += 90;
		
		new beamColor[4];
		if (TFTeam:GetEntProp(ent, Prop_Send, "m_iTeamNum") == TFTeam_Red)
			beamColor = {255, 75, 75, 255};
		else
			beamColor = {75, 75, 255, 255};

		float colorScale = AmplifierFill[ent];
		beamColor[0] = RoundFloat(float(beamColor[0]) * colorScale);
		beamColor[1] = RoundFloat(float(beamColor[1]) * colorScale);
		beamColor[2] = RoundFloat(float(beamColor[2]) * colorScale);
		beamColor[3] = RoundFloat(float(beamColor[3]) * colorScale);

		if (oldMetal > MetalPerPlayer)
		{
			float clampedFill = AmplifierFill[ent];
			EmitAmbientSound(AMPLIFIER_SOUND, Pos, ent, SNDLEVEL_CAR, SND_NOFLAGS, 0.6, RoundToCeil(SNDPITCH_NORMAL * clampedFill));
		} else
			EmitAmbientSound(AMPLIFIER_EMPTY_SOUND, Pos, ent, SNDLEVEL_CAR, SND_NOFLAGS, 0.5, SNDPITCH_NORMAL);
		
		if (oldMetal > 0)
		{
			TE_SetupBeamRingPoint(Pos, 10.0, colorScale * (AmplifierDistance[ent]*0.8), g_BeamSprite, g_HaloSprite, 0, 15, 3.0, 5.0, 0.0, beamColor, 3, 0);
			TE_SendToAll();
		}
		else
		{
			new emptyColor[4] = {75, 75, 75, 100};
			TE_SetupBeamRingPoint(Pos, 10.0, 144.0, g_BeamSprite, g_HaloSprite, 0, 15, 3.0, 5.0, 0.0, emptyColor, 3, 0); // 144 is the final value at colorscale 0
			TE_SendToAll();
		}
		
		if (metal > 0)
		{
			if (!strcmp(buildingClass, "obj_dispenser"))
			{
				if (GetEntProp(ent, Prop_Send, "m_iAmmoMetal") < MetalMax - metal)
					SetEntProp(ent, Prop_Send, "m_iAmmoMetal", GetEntProp(ent, Prop_Send, "m_iAmmoMetal") + metal);
				else
					SetEntProp(ent, Prop_Send, "m_iAmmoMetal", MetalMax);
			}
			else if (!strcmp(buildingClass, "obj_sentrygun"))
			{
				if (GetEntProp(ent, Prop_Send, "m_iAmmoShells") < MetalMax - metal)
					SetEntProp(ent, Prop_Send, "m_iAmmoShells", GetEntProp(ent, Prop_Send, "m_iAmmoShells") + metal);
				else
					SetEntProp(ent, Prop_Send, "m_iAmmoShells", MetalMax);
			}
			SetEntProp(ent, Prop_Send, "m_iUpgradeMetal", 0);
			EmitAmbientSound(AMPLIFIER_FILL_SOUND, AmplifierPos);
		}
	}
	return Plugin_Continue;
}

public Action:event_player_death(Handle:event, const String:name[], bool:dontBroadcast)
{
	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	
	new maxEntities = GetMaxEntities();
	for (new i = 1; i < maxEntities; i++)
	{
		new ent = EntRefToEntIndex(BuildingRef[i]);
		if (ent <= 0 || !AmplifierOn[ent] || AmplifierSapped[ent] || Attacker == i) continue;
		
		if (ConditionApplied[ent][Attacker])
		{
			new builder = GetEntPropEnt(ent, Prop_Send, "m_hBuilder");
			if (builder > 0)
			{
			g_PlayerState[builder].engiAssists++;
			if (g_PlayerState[builder].engiAssists >= 4)
				{
					Event escortEvent = CreateEvent("player_escort_score", true);
					if (escortEvent != null)
					{
						SetEventInt(escortEvent, "player", builder);
						SetEventInt(escortEvent, "points", 1);
						escortEvent.Fire();
					}
				g_PlayerState[builder].engiAssists = 0;
				}
			}
			break;
		}
	}
	return Plugin_Continue;
}

public Action:Event_Build(Handle:event, const String:name[], bool:dontBroadcast)
{
	new ent = GetEventInt(event, "index");
	CheckBuilding(ent);
	CheckSapper(ent);
	return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    int entindex = event.GetInt("index"); // the destroyed entity
    if (!IsValidEntity(entindex))
        return Plugin_Continue;
    char modelname[PLATFORM_MAX_PATH];
    GetEntPropString(entindex, Prop_Data, "m_ModelName", modelname, sizeof(modelname));
	if (StrContains(modelname, "plifier") == -1)
		return Plugin_Continue;

	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	bool entwasbuilding = event.GetBool("was_building"); // building in progress
	float position[3];
	GetEntPropVector(entindex, Prop_Send, "m_vecOrigin", position);
	if (EnableExplosion)
		CreateAmplifierExplosion(position, attacker, entwasbuilding, EnableExplosion);
	return Plugin_Changed;
}

CheckBuilding(ent)
{
	new String:classname[64];
	new Client = GetEntPropEnt(ent, Prop_Send, "m_hBuilder");
	GetEdictClassname(ent, classname, sizeof(classname));
	
	bool isDispenser = !strcmp(classname, "obj_dispenser");
	bool isSentry = !strcmp(classname, "obj_sentrygun");
	
	if ((!isDispenser && !isSentry) || Client <= 0) return;
	
	BuildingRef[ent] = EntIndexToEntRef(ent);
	
	bool shouldConvert = false;
	
	// Check force mode
	if (ForceAmplifier == 1 && isDispenser) shouldConvert = true;
	else if (ForceAmplifier == 2 && isSentry) shouldConvert = true;
	else if (ForceAmplifier == 3) shouldConvert = true;
	// Check custom attributes
	else if (isDispenser && CheckAmpAttributesDisp(Client)) shouldConvert = true;
	else if (isSentry && CheckAmpAttributesSentry(Client)) shouldConvert = true;
	// Check player preference
	else if (isDispenser && g_PlayerState[Client].useDispenser) shouldConvert = true;
	else if (isSentry && g_PlayerState[Client].useSentry) shouldConvert = true;
	
	if (shouldConvert)
	{
		AmplifierOn[ent] = false;
		SetEntProp(ent, Prop_Send, "m_bDisabled", 1);
		if (GetEntPropFloat(ent, Prop_Send, "m_flModelScale") != 1.0)
		{
			AmplifierMini[ent] = true;
			SetEntPropFloat(ent, Prop_Send, "m_flModelScale", 0.85); // Minis use 0.75... too small
		}
			
		AmplifierSapped[ent] = false;
		AmplifierFill[ent] = 0.0;
		
		if (NativeControl)
		{
			AmplifierDistance[ent] = isDispenser ? NativeDistanceDisp[Client] : NativeDistanceSentry[Client];
			AmplifierCondition[ent] = isDispenser ? NativeConditionDisp[Client] : NativeConditionSentry[Client];
		}
		else
		{
			AmplifierDistance[ent] = DefaultDistance;
			AmplifierCondition[ent] = DefaultCondition;
		}
		
		new String:s[128];
		Format(s, 128, "%s.mdl", AmplifierModel);
		SetEntityModel(ent, s);
		SetEntProp(ent, Prop_Send, "m_nSkin", GetEntProp(ent, Prop_Send, "m_nSkin") + 2);
		CreateTimer(1.0, BuildingCheckStage1, EntIndexToEntRef(ent));
	}
}

public Action:BuildingCheckStage1(Handle hTimer, any:ref)
{
	if (EntRefToEntIndex(ref) > 0)
		CreateTimer(0.1, BuildingCheckStage2, ref, TIMER_REPEAT);
	return Plugin_Continue;
}

public Action:BuildingCheckStage2(Handle hTimer, any:ref)
{
	new ent = EntRefToEntIndex(ref);
	if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Stop;
	
	if (GetEntPropFloat(ent, Prop_Send, "m_flPercentageConstructed") < 1.0)
		return Plugin_Continue;
	
	AmplifierOn[ent] = true;
	new String:modelname[128];
	int health = 150;
	char sHealth[16];
	Format(sHealth, sizeof(sHealth), "%d", health);
	Format(modelname, 128, "%s.mdl", AmplifierModel);
	SetEntProp(ent, Prop_Send, "m_iUpgradeLevel", 1);
	SetEntityModel(ent, modelname);
	if (AmplifierMini[ent])
		health = 100;
	SetEntProp(ent, Prop_Send, "m_iMaxHealth", health);
	SetVariantString(sHealth);
	AcceptEntityInput(ent, "SetHealth");
	
	new String:buildingClass[64];
	GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
	if (!strcmp(buildingClass, "obj_dispenser"))
		SetEntProp(ent, Prop_Send, "m_iAmmoMetal", 0);
	else if (!strcmp(buildingClass, "obj_sentrygun"))
		SetEntProp(ent, Prop_Send, "m_iAmmoShells", 0);
	AmplifierFill[ent] = 0.0;
	
	SetEntProp(ent, Prop_Send, "m_iUpgradeMetal", 75);
	SetEntProp(ent, Prop_Send, "m_nSkin", GetEntProp(ent, Prop_Send, "m_nSkin") - 2);
	
	return Plugin_Stop;
}

CheckSapper(ent)
{
	CreateTimer(0.5, SapperCheckStage1, EntIndexToEntRef(ent));
}

public Action:SapperCheckStage1(Handle:hTimer, any:ref)
{
	new ent = EntRefToEntIndex(ref);
	if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Continue;
	
	new String:classname[64];
	GetEdictClassname(ent, classname, sizeof(classname));
	if (strcmp(classname, "obj_attachment_sapper")) return Plugin_Continue;
	
	new maxEntities = GetMaxEntities();
	for (new i = 1; i < maxEntities; i++)
	{
		new ampref = BuildingRef[i];
		new ampent = EntRefToEntIndex(ampref);
		if (ampent > 0 && GetEntProp(ampent, Prop_Send, "m_bHasSapper") == 1 && !AmplifierSapped[ampent])
		{
			AmplifierSapped[ampent] = true;
			CreateTimer(0.5, SapperCheckStage2, ampref, TIMER_REPEAT);
			break;
		}
	}
	return Plugin_Continue;
}

public Action:SapperCheckStage2(Handle:hTimer, any:ref)
{
	new ent = EntRefToEntIndex(ref);
	if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Stop;
	
	if (GetEntProp(ent, Prop_Send, "m_bHasSapper") == 0 && AmplifierSapped[ent])
	{
		AmplifierSapped[ent] = false;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

stock void AddAmplifierEffect(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;
    
    // Kill existing timer
    if (g_PlayerState[client].effectTimer != INVALID_HANDLE)
    {
        delete g_PlayerState[client].effectTimer;
        g_PlayerState[client].effectTimer = INVALID_HANDLE;
    }
    
    // Apply to first 3 slots
    for (int slot = 0; slot < 3; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon > MaxClients && IsValidEntity(weapon))
        {
			float factor_firerate = 0.85;
			float factor_reloadrate = 0.75;
            int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
			if (defIndex == BEGGARS_BAZOOKA)
			{
				factor_firerate = 0.10;
				factor_reloadrate = 1.0;
			}
            TF2Attrib_SetByName(weapon, ATTR_FIRE_RATE, factor_firerate);
	        TF2Attrib_SetByName(weapon, ATTR_RELOAD_RATE, factor_reloadrate);
        }
    }
    
    // Create a default length timer
    g_PlayerState[client].effectTimer = CreateTimer(DefaultEffectLength, Timer_RemoveAmplifierEffect, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RemoveAmplifierEffect(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && client <= MaxClients)
    {
        g_PlayerState[client].effectTimer = INVALID_HANDLE;
        if (IsClientInGame(client))
        {
            for (int slot = 0; slot < 3; slot++)
            {
                int weapon = GetPlayerWeaponSlot(client, slot);
                if (weapon > MaxClients && IsValidEntity(weapon))
                {
                    int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
                    if (defIndex == BEGGARS_BAZOOKA)
                    {
                        TF2Attrib_SetByName(weapon, ATTR_FIRE_RATE, 0.30);
						TF2Attrib_SetByName(weapon, ATTR_RELOAD_RATE, 1.30);
                    }
                    else
                    {
                        TF2Attrib_RemoveByName(weapon, ATTR_FIRE_RATE);
                        TF2Attrib_RemoveByName(weapon, ATTR_RELOAD_RATE);
                    }
                }
            }
        }
    }
    return Plugin_Stop;
}

stock int CheckAmpAttributesDisp(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 4);
	if (weapon == -1) return 0;
	if (TF2CustAttr_GetInt(weapon, "amplifier attributes") != 0) return 1;
	return 0;
}

stock int CheckAmpAttributesSentry(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 4);
	if (weapon == -1) return 0;
	if (TF2CustAttr_GetInt(weapon, "amplifier attributes sentry") != 0) return 1;
	return 0;
}

void ConvertAllAmplifiersToBuildings()
{
	new maxEntities = GetMaxEntities();
	for (new i = 1; i < maxEntities; i++)
	{
		new ent = EntRefToEntIndex(BuildingRef[i]);
		if (ent > 0 && AmplifierOn[ent])
		{
			new String:buildingClass[64];
			GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
			
			AmplifierOn[ent] = false;
			SetEntProp(ent, Prop_Send, "m_bDisabled", 0);
			AmplifierFill[ent] = 0.0;
			
			new String:modelname[128];
			if (!strcmp(buildingClass, "obj_dispenser"))
				Format(modelname, sizeof(modelname), "models/buildables/dispenser.mdl");
			else if (!strcmp(buildingClass, "obj_sentrygun"))
				Format(modelname, sizeof(modelname), "models/buildables/sentry1.mdl");
			
			SetEntityModel(ent, modelname);
			SetEntPropFloat(ent, Prop_Send, "m_flModelScale", 1.0);
		}
	}
}

// Natives
public Native_ControlAmplifier(Handle:plugin, numParams)
{
	NativeControl = GetNativeCell(1);
}

public Native_SetAmplifierDisp(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	g_PlayerState[client].useDispenser = bool:GetNativeCell(2);
	
	float distance = Float:GetNativeCell(3);
	NativeDistanceDisp[client] = (distance < 0.0) ? DefaultDistance : distance;
	
	TFCond condition = TFCond:GetNativeCell(4);
	NativeConditionDisp[client] = (condition < TFCond_Slowed) ? DefaultCondition : condition;
}

public Native_SetAmplifierSentry(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	g_PlayerState[client].useSentry = bool:GetNativeCell(2);
	
	float distance = Float:GetNativeCell(3);
	NativeDistanceSentry[client] = (distance < 0.0) ? DefaultDistance : distance;
	
	TFCond condition = TFCond:GetNativeCell(4);
	NativeConditionSentry[client] = (condition < TFCond_Slowed) ? DefaultCondition : condition;
}

public Native_HasAmplifier(Handle:plugin, numParams)
{
	new count = 0;
	new client = GetNativeCell(1);
	new maxEntities = GetMaxEntities();
	for (new i = 1; i < maxEntities; i++)
	{
		new ampref = BuildingRef[i];
		new ampent = EntRefToEntIndex(ampref);
		if (ampent > 0 && GetEntPropEnt(ampent, Prop_Send, "m_hBuilder") == client)
			count++;
	}
	return count;
}

public Native_ConvertToAmplifier(Handle:plugin, numParams)
{
	new ent = GetNativeCell(1);
	if (ent <= 0 || !IsValidEntity(ent)) return;
	
	new client = GetNativeCell(2);
	
	new String:buildingClass[64];
	GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
	bool isDispenser = !strcmp(buildingClass, "obj_dispenser");
	
	bool saveDisp = g_PlayerState[client].useDispenser;
	bool saveSentry = g_PlayerState[client].useSentry;
	float saveDistDisp = NativeDistanceDisp[client];
	float saveDistSentry = NativeDistanceSentry[client];
	new TFCond:saveCondDisp = NativeConditionDisp[client];
	new TFCond:saveCondSentry = NativeConditionSentry[client];
	new savePercentDisp = NativePercentDisp[client];
	new savePercentSentry = NativePercentSentry[client];
	
	float distance = Float:GetNativeCell(3);
	new TFCond:condition = TFCond:GetNativeCell(4);
	new percent = GetNativeCell(5);
	
	if (isDispenser)
	{
		if (distance >= 0.0) NativeDistanceDisp[client] = distance;
		if (condition >= TFCond_Slowed) NativeConditionDisp[client] = condition;
		if (percent >= 0) NativePercentDisp[client] = percent;
		g_PlayerState[client].useDispenser = true;
	}
	else
	{
		if (distance >= 0.0) NativeDistanceSentry[client] = distance;
		if (condition >= TFCond_Slowed) NativeConditionSentry[client] = condition;
		if (percent >= 0) NativePercentSentry[client] = percent;
		g_PlayerState[client].useSentry = true;
	}
	
	CheckBuilding(ent);
	
	NativeConditionDisp[client] = saveCondDisp;
	NativeConditionSentry[client] = saveCondSentry;
	NativeDistanceDisp[client] = saveDistDisp;
	NativeDistanceSentry[client] = saveDistSentry;
	NativePercentDisp[client] = savePercentDisp;
	NativePercentSentry[client] = savePercentSentry;
	g_PlayerState[client].useDispenser = saveDisp;
	g_PlayerState[client].useSentry = saveSentry;
}

// Utility Functions
stock bool:IsValidClient(client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

stock void ClearTimer(Handle hTimer)
{
	if (hTimer != INVALID_HANDLE)
	{
		KillTimer(hTimer);
		hTimer = INVALID_HANDLE;
	}
}

void DealElectricDamage(int client, int builder, const float pos[3], float damage)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    float Pos[3];
    GetEntPropVector(client, Prop_Send, "m_vecOrigin", Pos);

    float dist = GetVectorDistance(Pos, pos);
    if (dist > DefaultDistance) // beyond these units: no damage
        return;

    // Damage scales inversely with distance (closer = more damage)
    float damageFinal = damage * (1.0 - (dist / DefaultDistance));
    if (damageFinal < 0.0) damageFinal = 0.0;

    // Apply electric-type damage
    SDKHooks_TakeDamage(client, builder, builder, damageFinal, 256); // 256 = DMG_SHOCK
}


void CreateAmplifierExplosion(float position[3], int attacker = 0, bool entwasbuilding = false, int damage)
{
	if (entwasbuilding) return;
    int explosion = CreateEntityByName("env_explosion");    
    if (explosion == -1) {
        return;
    }

	int radius = RoundFloat(DefaultDistance);
    char sDamage[16], sRadius[16];
    IntToString(damage, sDamage, sizeof(sDamage));
    IntToString(radius, sRadius, sizeof(sRadius));
    
    // Set explosion properties
    DispatchKeyValue(explosion, "iMagnitude", sDamage);
    DispatchKeyValue(explosion, "iRadiusOverride", sRadius);
    DispatchKeyValue(explosion, "spawnflags", "828");
    
    TeleportEntity(explosion, position, NULL_VECTOR, NULL_VECTOR);
    
    // Set attacker if valid
    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)) {
        SetEntPropEnt(explosion, Prop_Send, "m_hOwnerEntity", attacker);
    }
    
    DispatchSpawn(explosion);
    AcceptEntityInput(explosion, "Explode");
    
	// Create visual explosion effect
	TE_SetupExplosion(position, 0, 10.0, 1, 0, radius, 5000);
	TE_SendToAll();

	int particle = CreateEntityByName("info_particle_system");
	if (particle != -1)
	{
		int team = GetClientTeam(attacker);
		TeleportEntity(particle, position, NULL_VECTOR, NULL_VECTOR);
		char storedParticle[64] = "powerup_supernova_explode_red_spikes";
		if (team == 2) storedParticle = "powerup_supernova_explode_blue_spikes";
		DispatchKeyValue(particle, "effect_name", storedParticle);
		DispatchKeyValue(particle, "start_active", "0");
		DispatchSpawn(particle);
		ActivateEntity(particle);
		AcceptEntityInput(particle, "Start");
		CreateTimer(2.0, Timer_RemoveEntity, EntIndexToEntRef(particle));
	}
	
	// Clean up explosion entity
	CreateTimer(0.1, Timer_RemoveEntity, EntIndexToEntRef(explosion));
}

public Action Timer_RemoveEntity(Handle timer, int ref) {
    int entity = EntRefToEntIndex(ref);
    if (entity != INVALID_ENT_REFERENCE) {
        RemoveEntity(entity);
    }
    return Plugin_Stop;
}

// Ray Trace
#tryinclude <raytrace>
#if !defined _raytrace_included
stock bool:TraceTargetIndex(client, target, Float:clientLoc[3], Float:targetLoc[3])
{
	targetLoc[2] += 50.0;
	TR_TraceRayFilter(clientLoc, targetLoc, MASK_SOLID, RayType_EndPoint, TraceRayDontHitSelf, client);
	return (!TR_DidHit() || TR_GetEntityIndex() == target);
}

public bool:TraceRayDontHitSelf(entity, mask, any:data)
{
	return (entity != data);
}
#endif
