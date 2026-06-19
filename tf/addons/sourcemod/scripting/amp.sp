#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

#include <sdktools>
#include <sdkhooks>
#include <sdktools_functions>

#include <tf2>
#include <tf2_stocks>
#include <tf2attributes>

#include <morecolors>
#include <tf_custom_attributes>
#include <conch_no_speed>


#undef REQUIRE_PLUGIN
#include <dgm_api>
#define REQUIRE_PLUGIN

#define MAX_AMPLIFIER_CLIENTS (MAXPLAYERS + 1)
#define MAX_AMPLIFIER_ENTITIES 2048

// Compatibility aliases used by the existing public/native data layout.
// Keep the old names local to avoid touching external config/schema/command contracts.
#define MP MAX_AMPLIFIER_CLIENTS
#define ME MAX_AMPLIFIER_ENTITIES

#define PLUGIN_VERSION "2.5"

// Models and Sounds
#define AmplifierModel "models/buildables/amplifier_test/amplifier"
#define AmplifierTex "materials/models/buildables/amplifier_test/amplifier"
#define AMPgib "models/buildables/amplifier_test/gibs/amp_gib"
#define AMPLIFIER_SOUND "misc/rd_finale_beep01.wav"
#define AMPLIFIER_EMPTY_SOUND "hl1/fvox/beep.wav"
#define AMPLIFIER_BUFF_SOUND "weapons/dispenser_heal.wav"
#define AMPLIFIER_FILL_SOUND "weapons/dispenser_generate_metal.wav"

// Gameplay
#define ATTR_FIRE_RATE "fire rate bonus HIDDEN"
#define ATTR_RELOAD_RATE "reload time increased hidden" // Set to < 1 for more speed
#define BEGGARS_BAZOOKA 730
#define AMPLIFIER_HEALTH 150
#define AMPLIFIER_MINI_HEALTH 100
#define AMPLIFIER_MINI_MODIFIER 0.75
#define AMPLIFIER_FORCE_MIN_PLAYERS 3

// Entity classes / commands
#define BUILDING_DISPENSER "obj_dispenser"
#define BUILDING_SENTRY "obj_sentrygun"
#define BUILDING_SAPPER "obj_attachment_sapper"
#define OBJECT_DISPENSER 0
#define OBJECT_TELEPORTER 1
#define OBJECT_SENTRY 2
#define DESTROY_DISPENSER "destroy 0"
#define DESTROY_SENTRY "destroy 2"
#define TIMER_NO_MAPCHANGE TIMER_FLAG_NO_MAPCHANGE

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
int g_ActiveAmplifiers[ME];

// ConVars
ConVar cvarMetal;
ConVar cvarMetalMax;
ConVar cvarDistance;
ConVar cvarEffectLength;
ConVar cvarForceAmplifier;
ConVar cvarForcePlayercount;
ConVar cvarEnableExplosion;
ConVar cvarEnableZap;

TFCond DefaultCondition = TFCond_RuneHaste; // Formerly TFCond_Buffed

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

static bool IsValidPlayerIndex(int client)
{
    return client > 0 && client < sizeof(g_PlayerState);
}

static bool IsTrackedEntityIndex(int ent)
{
    return ent > 0 && ent < sizeof(BuildingRef);
}

static int GetTrackedEntityLimit(int maxEntities = 0)
{
    int limit = maxEntities > 0 ? maxEntities : GetMaxEntities();
    if (limit > sizeof(BuildingRef))
    {
        limit = sizeof(BuildingRef);
    }

    return limit;
}

static bool IsValidCookieHandle(Handle cookie)
{
    return cookie != null && cookie != INVALID_HANDLE;
}

static bool IsDispenserClass(const char[] classname)
{
    return StrEqual(classname, BUILDING_DISPENSER);
}

static bool IsSentryClass(const char[] classname)
{
    return StrEqual(classname, BUILDING_SENTRY);
}

static void ResetAmplifierBuildingState(int ent)
{
    if (!IsTrackedEntityIndex(ent))
    {
        return;
    }

    AmplifierOn[ent] = false;
    AmplifierMini[ent] = false;
    AmplifierSapped[ent] = false;
    AmplifierDistance[ent] = 0.0;
    AmplifierCondition[ent] = DefaultCondition;
    AmplifierFill[ent] = 0.0;
    BuildingRef[ent] = 0;
    ClearAmplifierConditionForBuilding(ent);
}

static void ResetPlayerState(int client, bool resetPreferences = true)
{
    if (client <= 0 || client >= sizeof(g_PlayerState))
        return;

    StopAmplifierEffect(client, false);

    g_PlayerState[client].nearAmplifier = false;
    g_PlayerState[client].engiAssists = 0;

    if (resetPreferences)
    {
        g_PlayerState[client].useDispenser = false;
        g_PlayerState[client].useSentry = false;
    }
}

public Plugin myinfo = {
    name = "The Amplifier (Unified)",
    author = "RainBolt Dash (plugin); Jumento M.D. (idea & model); Naris and FlaminSarge (helpers); Bad Hombre (new fork)",
    description = "Adds The Amplifier for Dispenser and/or Sentry",
    version = PLUGIN_VERSION,
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("DGM_RealPlayerCount");
	CreateNative("ControlAmplifier", Native_ControlAmplifier);
	CreateNative("SetAmplifierDisp", Native_SetAmplifierDisp);
	CreateNative("SetAmplifierSentry", Native_SetAmplifierSentry);
	CreateNative("HasAmplifier", Native_HasAmplifier);
	CreateNative("ConvertToAmplifier", Native_ConvertToAmplifier);
	CreateNative("Amplifier_WouldReplaceBuilding", Native_WouldReplaceBuilding);
	fwdOnAmplify = CreateGlobalForward("OnAmplify", ET_Hook, Param_Cell, Param_Cell, Param_Cell);
	RegPluginLibrary("Amplifier");
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("amplifier_version", PLUGIN_VERSION, "The Amplifier Version", FCVAR_REPLICATED|FCVAR_NOTIFY);
	cvarEffectLength = CreateConVar("amplifier_effect_length", "3.0", "Length in seconds for the Amplifier condition to last", FCVAR_PLUGIN);
	cvarDistance = CreateConVar("amplifier_distance", "400.0", "Distance the amplifier works.", FCVAR_PLUGIN);
	cvarMetalMax = CreateConVar("amplifier_max", "200.0", "Maximum amount of metal an amplifier can hold.", FCVAR_PLUGIN);
	cvarMetal = CreateConVar("amplifier_metal", "5.0", "Amount of metal to use to apply a condition to a player (per second).", FCVAR_PLUGIN);
	cvarForceAmplifier = CreateConVar("amplifier_force", "0", "Force amplifier mode: 0=nothing, 1=dispenser, 2=sentry, 3=both", FCVAR_PLUGIN, true, 0.0, true, 3.0);
	cvarForcePlayercount = CreateConVar("amplifier_force_playercount", "0", "If >0 and human player count is below this value, treat amplifier_force as 2 (sentry only).", FCVAR_PLUGIN, true, 0.0);
	cvarEnableExplosion = CreateConVar("amplifier_explode", "65", "Enable Amplifier death explosions? >0 for damage value.", FCVAR_PLUGIN, true, 0.0);
	SetConVarBounds(cvarEnableExplosion, ConVarBound_Upper, false);
	cvarEnableZap = CreateConVar("amplifier_zap", "0.0", "Should Amplifier pulses harm the enemy team? 0 to disable, >0 for damage.", FCVAR_PLUGIN, true, 0.0, true, 50.0);

	HookEvent("player_builtobject", Event_Build);
	HookEvent("object_destroyed", Event_ObjectDestroyed);
	HookEvent("player_death", event_player_death);

	RegConsoleCmd("sm_amplifier", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_a", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_p", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_amp", CallPanel, "Select engineer's building type");
	RegConsoleCmd("sm_amphelp", HelpPanel, "Show info about Amplifier");
	RegConsoleCmd("sm_ah", HelpPanel, "Show info about Amplifier");
	RegConsoleCmd("sm_ph", PadHelpPanel, "Show info about Jump/Speed Pads");
	RegConsoleCmd("sm_killsentries", Command_KillSentries, "Destroy all sentry guns");

	g_hPadCookie = FindClientCookie("engipads_toggle");

	AutoExecConfig(true, "amplifier");

	// Cookies
	g_hCookieDisp = RegClientCookie("amplifier_dispenser", "Dispenser Amplifier preference", CookieAccess_Public);
	g_hCookieSentry = RegClientCookie("amplifier_sentry", "Sentry Amplifier preference", CookieAccess_Public);

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetPlayerState(i);
		if (IsClientInGame(i))
		{
			OnClientPostAdminCheck(i);
		}
	}
}

public void OnPluginEnd()
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

	for (int client = 1; client <= MaxClients; client++)
	{
		StopAmplifierEffect(client);
	}

	ConvertAllAmplifiersToBuildings();
}

public void OnConfigsExecuted()
{
	if (g_hAmplifierTimer == INVALID_HANDLE)
	{
		g_hAmplifierTimer = CreateTimer(1.0, Timer_amplifier, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnMapStart()
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

public void OnMapEnd()
{
	for (int ent = 1; ent < GetTrackedEntityLimit(); ent++)
	{
		ResetAmplifierBuildingState(ent);
	}

	g_hAmplifierTimer = INVALID_HANDLE;
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	ResetPlayerState(client, false);

	if (AreClientCookiesCached(client))
	{
		LoadClientPreferences(client);
	}
}

public void OnClientCookiesCached(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	LoadClientPreferences(client);
}

public void OnClientDisconnect(int client)
{
	ResetPlayerState(client);
}

void LoadClientPreferences(int client)
{
	if (!IsValidClient(client) || !AreClientCookiesCached(client))
	{
		return;
	}

	char szValue[8];

	GetClientCookie(client, g_hCookieDisp, szValue, sizeof(szValue));
	if (szValue[0] != '\0')
	{
		g_PlayerState[client].useDispenser = view_as<bool>(StringToInt(szValue));
	}

	GetClientCookie(client, g_hCookieSentry, szValue, sizeof(szValue));
	if (szValue[0] != '\0')
	{
		g_PlayerState[client].useSentry = view_as<bool>(StringToInt(szValue));
	}
}

void SaveClientPreferences(int client)
{
	if (!IsValidClient(client) || !AreClientCookiesCached(client)) return;

	char szValue[8];

	IntToString(g_PlayerState[client].useDispenser, szValue, sizeof(szValue));
	SetClientCookie(client, g_hCookieDisp, szValue);

	IntToString(g_PlayerState[client].useSentry, szValue, sizeof(szValue));
	SetClientCookie(client, g_hCookieSentry, szValue);
}

int GetEffectiveForceAmplifier()
{
	if (IsPlayercountForceActive())
	{
		return 2;
	}

	return GetConVarInt(cvarForceAmplifier);
}

bool IsPlayercountForceActive()
{
	int forceAmplifier = GetConVarInt(cvarForceAmplifier);
	int forcePlayercount = GetConVarInt(cvarForcePlayercount);
	if (forceAmplifier == 2 || forcePlayercount <= 0)
	{
		return false;
	}

	if (GetFeatureStatus(FeatureType_Native, "DGM_RealPlayerCount") != FeatureStatus_Available)
	{
		return false;
	}

	int playerCount = DGM_RealPlayerCount();
	if (playerCount < AMPLIFIER_FORCE_MIN_PLAYERS)
	{
		return false;
	}

	return playerCount < forcePlayercount;
}

bool ShouldClientBuildAmplifier(int client, bool isDispenser, bool isSentry, bool &forcedConversion, bool &playercountForceActive, int &effectiveForceAmplifier, bool &playerRequestedAmplifier)
{
	forcedConversion = false;
	playercountForceActive = false;
	effectiveForceAmplifier = 0;
	playerRequestedAmplifier = false;

	if ((!isDispenser && !isSentry) || !IsValidClient(client))
	{
		return false;
	}

	playercountForceActive = IsPlayercountForceActive();
	effectiveForceAmplifier = GetEffectiveForceAmplifier();

	bool hasAmplifierAttribute = (isDispenser && CheckAmpAttributesDisp(client))
		|| (isSentry && CheckAmpAttributesSentry(client));
	bool hasAmplifierPreference = (isDispenser && g_PlayerState[client].useDispenser)
		|| (isSentry && g_PlayerState[client].useSentry);
	playerRequestedAmplifier = hasAmplifierAttribute || hasAmplifierPreference;

	if (effectiveForceAmplifier == 1 && isDispenser)
	{
		forcedConversion = true;
		return true;
	}
	if (effectiveForceAmplifier == 2 && isSentry)
	{
		forcedConversion = true;
		return true;
	}
	if (effectiveForceAmplifier == 3)
	{
		forcedConversion = true;
		return true;
	}

	return playerRequestedAmplifier;
}

bool WouldObjectTypeBecomeAmplifier(int client, int objectType)
{
	bool forcedConversion;
	bool playercountForceActive;
	int effectiveForceAmplifier;
	bool playerRequestedAmplifier;

	return ShouldClientBuildAmplifier(
		client,
		objectType == OBJECT_DISPENSER,
		objectType == OBJECT_SENTRY,
		forcedConversion,
		playercountForceActive,
		effectiveForceAmplifier,
		playerRequestedAmplifier);
}

public void AddToDownload()
{
	char strLine[256];
	static const char extensions[][] = {".mdl", ".dx80.vtx", ".dx90.vtx", ".sw.vtx", ".vvd", ".phy"};
	static const char textureExtensions[][] = {".vtf", ".vmt"};
	static const char textures[][] = {"", "_blue", "_anim", "_anim_blue", "_anim2", "_anim2_blue", "_holo", "_bolt", "_holo_blue", "_radar"};

	for (int i = 0; i < sizeof(extensions); i++)
	{
		Format(strLine, sizeof(strLine), "%s%s", AmplifierModel, extensions[i]);
		AddFileToDownloadsTable(strLine);
		for (int j = 1; j <= 8; j++)
		{
			Format(strLine, sizeof(strLine), "%s%i%s", AMPgib, j, extensions[i]);
			AddFileToDownloadsTable(strLine);
		}
	}

	for (int i = 0; i < sizeof(textureExtensions); i++)
	{
		for (int j = 0; j < sizeof(textures); j++)
		{
			Format(strLine, sizeof(strLine), "%s%s%s", AmplifierTex, textures[j], textureExtensions[i]);
			AddFileToDownloadsTable(strLine);
		}
	}

	Format(strLine, sizeof(strLine), "%s.mdl", AmplifierModel);
	PrecacheModel(strLine, true);
	for (int i = 1; i <= 8; i++)
	{
		Format(strLine, sizeof(strLine), "%s%i.mdl", AMPgib, i);
		PrecacheModel(strLine, true);
	}
}

bool GetDestroyCommandForBuilding(const char[] buildingClass, char[] destroyCmd, int destroyCmdSize)
{
	if (IsDispenserClass(buildingClass))
	{
		strcopy(destroyCmd, destroyCmdSize, DESTROY_DISPENSER);
		return true;
	}

	if (IsSentryClass(buildingClass))
	{
		strcopy(destroyCmd, destroyCmdSize, DESTROY_SENTRY);
		return true;
	}

	destroyCmd[0] = '\0';
	return false;
}

void RemoveBuilding(int client, const char[] buildingClass)
{
	if (!IsValidClient(client))
	{
		return;
	}

	char destroyCmd[32];
	if (!GetDestroyCommandForBuilding(buildingClass, destroyCmd, sizeof(destroyCmd)))
	{
		return;
	}

	char classname[64];

	for (int j = 1; j < GetTrackedEntityLimit(); j++)
	{
		int ent = EntRefToEntIndex(BuildingRef[j]);
		if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
		{
			if (BuildingRef[j] != 0)
			{
				BuildingRef[j] = 0;
				ClearAmplifierConditionForBuilding(j);
			}
			continue;
		}

		GetEdictClassname(ent, classname, sizeof(classname));
		if (!StrEqual(classname, buildingClass) || GetEntPropEnt(ent, Prop_Send, "m_hBuilder") != client)
		{
			continue;
		}

		char health[16];
		IntToString(GetEntProp(ent, Prop_Send, "m_iMaxHealth") + 1, health, sizeof(health));
		SetVariantString(health);
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

public int AmpHelpPanelH(Handle menu, MenuAction action, int param1, int param2) { return 0; }

public Action HelpPanel(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Continue;
	}

	Handle panel = CreatePanel();

	SetPanelTitle(panel, "Amplifier Info");
	DrawPanelText(panel, "Amplifiers buff allies with 40% faster reload speed and health on hit");
	DrawPanelText(panel, "They zap enemies within range and explode on death");
	DrawPanelText(panel, "Mini-amplifiers have less health and less potent effects");
	DrawPanelText(panel, "Ammo is fuel, hit with your wrench to refill");
	DrawPanelText(panel, "If sentries are disabled, amplifiers replace them. Otherwise, equip amplifiers with !a");
	DrawPanelItem(panel, "Close");

	SendPanelToClient(panel, client, AmpHelpPanelH, 20);
	delete panel;
	return Plugin_Continue;
}

public Action PadHelpPanel(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Continue;
	}

	Handle panel = CreatePanel();

	DrawPanelText(panel, "Jump/Speed Pad Info");
	DrawPanelText(panel, "Teleporters can be converted to Jump or Speed pads");
	DrawPanelText(panel, "Turn your pad once to place a jump pad instead of a speed pad");
	DrawPanelText(panel, "Use !pads to toggle these buildings");
	DrawPanelItem(panel, "Close");

	SendPanelToClient(panel, client, AmpHelpPanelH, 20);
	delete panel;
	return Plugin_Continue;
}

public Action CallPanel(int client, int args)
{
	if (!NativeControl && IsValidClient(client))
	{
		ShowAmplifierMenu(client);
	}
	return Plugin_Continue;
}

void ShowAmplifierMenu(int client)
{
	if (!IsValidClient(client))
		return;

	Handle menu = CreateMenu(MenuHandler_Amplifier);

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
	if (!IsValidClient(client) || !IsValidCookieHandle(cookie) || !AreClientCookiesCached(client))
	{
		return false;
	}

	char value[8];
	GetClientCookie(client, cookie, value, sizeof(value));
	return StrEqual(value, "1") || StrEqual(value, "true");
}

void SetClientCookieBool(int client, Handle cookie, bool value)
{
	if (!IsValidClient(client) || !IsValidCookieHandle(cookie) || !AreClientCookiesCached(client))
	{
		return;
	}

	char szToggle[8];
	Format(szToggle, sizeof(szToggle), "%s", value ? "1" : "0");
	SetClientCookie(client, cookie, szToggle);
}

void ToggleAmplifierBuildingPreference(int client, bool sentry)
{
	if (!IsValidClient(client))
	{
		return;
	}

	if (sentry)
	{
		g_PlayerState[client].useSentry = !g_PlayerState[client].useSentry;
		SaveClientPreferences(client);

		if (g_PlayerState[client].useSentry)
		{
			CPrintToChat(client, "{orange}[Amplifier]{default} Sentries will now be {green}Amplifiers{default}!");
			RemoveBuilding(client, BUILDING_SENTRY);
		}
		else
		{
			CPrintToChat(client, "{orange}[Amplifier]{default} Sentries will now be {lightgreen}Normal{default}!");
			RemoveBuilding(client, BUILDING_SENTRY);
		}
	}
	else
	{
		g_PlayerState[client].useDispenser = !g_PlayerState[client].useDispenser;
		SaveClientPreferences(client);

		if (g_PlayerState[client].useDispenser)
		{
			CPrintToChat(client, "{orange}[Amplifier]{default} Dispensers will now be {green}Amplifiers{default}!");
			RemoveBuilding(client, BUILDING_DISPENSER);
		}
		else
		{
			CPrintToChat(client, "{orange}[Amplifier]{default} Dispensers will now be {lightgreen}Normal{default}!");
			RemoveBuilding(client, BUILDING_DISPENSER);
		}
	}

	ShowAmplifierMenu(client);
}

public int MenuHandler_Amplifier(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		if (!IsValidClient(param1))
		{
			return 0;
		}

		char info[32];
		if (!GetMenuItem(menu, param2, info, sizeof(info)))
		{
			return 0;
		}

		if (StrEqual(info, "disp"))
		{
			ToggleAmplifierBuildingPreference(param1, false);
		}
		else if (StrEqual(info, "sentry"))
		{
			ToggleAmplifierBuildingPreference(param1, true);
		}
		else if (StrEqual(info, "info"))
		{
			HelpPanel(param1, 0);
		}
		else if (StrEqual(info, "tele"))
		{
			bool usePadSpeed = GetClientCookieBool(param1, g_hPadCookie);
			usePadSpeed = !usePadSpeed; // toggle it
			SetClientCookieBool(param1, g_hPadCookie, usePadSpeed);

			PrintToChat(param1, "[Kogasa] Teleporter mode set to: %s", usePadSpeed ? "Speed/Jump" : "Normal");
			ShowAmplifierMenu(param1);
		}
	}
	else if (action == MenuAction_End && menu != INVALID_HANDLE)
	{
		delete menu;
	}

	return 0;
}

bool IsAmplifierModel(int ent)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
		return false;

	char modelname[256];
	GetEntPropString(ent, Prop_Data, "m_ModelName", modelname, sizeof(modelname));
	return StrContains(modelname, "plifier") != -1;
}

bool IsActiveAmplifier(int ent)
{
	// AmplifierOn is the authoritative plugin state.  Do not gate this on
	// IsAmplifierModel(): TF2 can overwrite the model during late construction
	// or native upgrade handling, and requiring the model here prevents the
	// plugin from ever repairing that overwritten state.
	return IsTrackedEntityIndex(ent) && IsValidEntity(ent) && AmplifierOn[ent] && !AmplifierSapped[ent];
}

void SetAmplifierBuildModel(int ent)
{
	char modelname[128];
	Format(modelname, sizeof(modelname), "%s.mdl", AmplifierModel);
	SetEntityModel(ent, modelname);
}

bool IsAmplifierConstructionComplete(int ent)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
		return false;

	if (GetEntPropFloat(ent, Prop_Send, "m_flPercentageConstructed") < 1.0)
		return false;

	// m_flPercentageConstructed can reach 1.0 before TF2 is done with native
	// construction finalization.  Waiting for m_bBuilding to clear keeps our
	// final model/health/ammo writes from racing those native writes.
	return GetEntProp(ent, Prop_Send, "m_bBuilding") == 0;
}

void ClampAmplifierHealthToMax(int ent)
{
	int maxHealth = AmplifierMini[ent] ? AMPLIFIER_MINI_HEALTH : AMPLIFIER_HEALTH;
	SetEntProp(ent, Prop_Send, "m_iMaxHealth", maxHealth);

	int currentHealth = GetEntProp(ent, Prop_Send, "m_iHealth");
	if (currentHealth > maxHealth)
	{
		char sHealth[16];
		IntToString(maxHealth, sHealth, sizeof(sHealth));
		SetVariantString(sHealth);
		AcceptEntityInput(ent, "SetHealth");
	}
}

void ReassertAmplifierRuntimeState(int ent)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent) || !AmplifierOn[ent])
		return;

	char buildingClass[64];
	GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
	if (!IsDispenserClass(buildingClass) && !IsSentryClass(buildingClass))
		return;

	SetEntProp(ent, Prop_Send, "m_bDisabled", 1);
	SetEntProp(ent, Prop_Send, "m_iUpgradeLevel", 1);
	SetEntProp(ent, Prop_Send, "m_iHighestUpgradeLevel", 1);
	if (!IsAmplifierModel(ent))
		SetAmplifierBuildModel(ent);
	ClampAmplifierHealthToMax(ent);
}

bool GetAmplifierMetal(int ent, int &metal, char[] buildingClass, int classSize)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
	{
		metal = 0;
		buildingClass[0] = '\0';
		return false;
	}

	GetEdictClassname(ent, buildingClass, classSize);

	if (IsDispenserClass(buildingClass))
	{
		metal = GetEntProp(ent, Prop_Send, "m_iAmmoMetal");
		return true;
	}

	if (IsSentryClass(buildingClass))
	{
		metal = GetEntProp(ent, Prop_Send, "m_iAmmoShells");
		return true;
	}

	metal = 0;
	return false;
}

void SetAmplifierMetal(int ent, const char[] buildingClass, int metal)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
		return;

	if (IsDispenserClass(buildingClass))
		SetEntProp(ent, Prop_Send, "m_iAmmoMetal", metal);
	else if (IsSentryClass(buildingClass))
		SetEntProp(ent, Prop_Send, "m_iAmmoShells", metal);
}

bool AbsorbAmplifierUpgradeMetal(int ent, int metalMax)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
		return false;

	int upgradeMetal = GetEntProp(ent, Prop_Send, "m_iUpgradeMetal");
	if (upgradeMetal <= 0)
		return false;

	SetEntProp(ent, Prop_Send, "m_iUpgradeMetal", 0);
	if (metalMax <= 0)
		return false;

	char buildingClass[64];
	int oldMetal;
	if (!GetAmplifierMetal(ent, oldMetal, buildingClass, sizeof(buildingClass)))
		return false;

	if (oldMetal < 0)
		oldMetal = 0;

	int refillMetal = (upgradeMetal * metalMax) / 200;
	int newMetal = oldMetal + refillMetal;
	if (newMetal > metalMax)
		newMetal = metalMax;

	SetAmplifierMetal(ent, buildingClass, newMetal);
	UpdateAmplifierFill(ent, newMetal, metalMax);
	return refillMetal > 0;
}

void UpdateAmplifierFill(int ent, int metal, int metalMax)
{
	if (!IsTrackedEntityIndex(ent))
		return;

	if (metalMax <= 0)
	{
		AmplifierFill[ent] = 0.0;
		return;
	}

	float fill = float(metal) / float(metalMax);
	if (fill < 0.0)
		fill = 0.0;
	if (fill < 0.4)
		fill = (fill / 0.4) + 0.6; // Taking a percentage and adding a minimum
	else
		fill = 1.0;
	if (fill > 1.0)
		fill = 1.0;

	AmplifierFill[ent] = fill;
}

float GetAmplifierEffectiveRadius(int ent)
{
	// Keep the gameplay range and non-empty visual pulse range in lock-step.
	// AmplifierFill affects color/pitch only, not the wave's visible reach.
	return IsTrackedEntityIndex(ent) ? AmplifierDistance[ent] : 0.0;
}

float GetAmplifierWaveRadius(int ent)
{
	return GetAmplifierEffectiveRadius(ent);
}

float GetEmptyAmplifierWaveRadius(int ent)
{
	float radius = 144.0;
	if (ent > 0 && ent < ME && AmplifierMini[ent])
		radius *= AMPLIFIER_MINI_MODIFIER;

	return radius;
}

float GetAmplifierEffectLength(int ent)
{
	float effectLength = GetConVarFloat(cvarEffectLength);
	if (IsTrackedEntityIndex(ent) && AmplifierMini[ent])
	{
		effectLength = float(RoundToFloor(effectLength * AMPLIFIER_MINI_MODIFIER));
		if (effectLength < 1.0)
			effectLength = 1.0;
	}

	return effectLength;
}

float GetAmplifierDamage(int ent, float damage)
{
	if (IsTrackedEntityIndex(ent) && AmplifierMini[ent])
		return float(RoundToFloor(damage * AMPLIFIER_MINI_MODIFIER));

	return damage;
}

void ClearAmplifierConditionForClient(int client, int maxEntities)
{
	if (!IsValidPlayerIndex(client))
		return;

	for (int ent = 1; ent < GetTrackedEntityLimit(maxEntities); ent++)
	{
		ConditionApplied[ent][client] = false;
	}
}

void ClearAmplifierConditionForBuilding(int ent)
{
	if (!IsTrackedEntityIndex(ent))
		return;

	for (int client = 1; client <= MaxClients; client++)
	{
		ConditionApplied[ent][client] = false;
	}
}

int CollectActiveAmplifiers(int maxEntities, int activeAmps[ME])
{
	int activeCount = 0;

	for (int slot = 1; slot < GetTrackedEntityLimit(maxEntities); slot++)
	{
		int ref = BuildingRef[slot];
		if (ref == 0)
			continue;

		int ent = EntRefToEntIndex(ref);
		if (ent <= 0)
		{
			BuildingRef[slot] = 0;
			ClearAmplifierConditionForBuilding(slot);
			continue;
		}

		if (IsActiveAmplifier(ent))
		{
			ReassertAmplifierRuntimeState(ent);
			activeAmps[activeCount++] = ent;
		}
	}

	return activeCount;
}

bool TryApplyAmplifierToClient(int client, int amp, int metalPerPlayer, int metalMax, float zapDamage)
{
	if (!IsActiveAmplifier(amp))
		return false;

	char buildingClass[64];
	int metal;
	if (!GetAmplifierMetal(amp, metal, buildingClass, sizeof(buildingClass)))
		return false;

	UpdateAmplifierFill(amp, metal, metalMax);

	if (metal < metalPerPlayer && metalPerPlayer > 0)
		return false;

	float clientPos[3];
	float amplifierPos[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", clientPos);
	GetEntPropVector(amp, Prop_Send, "m_vecOrigin", amplifierPos);

	if (GetVectorDistance(clientPos, amplifierPos) > GetAmplifierEffectiveRadius(amp))
		return false;
	if (!TraceTargetIndex(amp, client, amplifierPos, clientPos))
		return false;

	TFTeam clientTeam = view_as<TFTeam>(GetClientTeam(client));
	TFTeam team = view_as<TFTeam>(GetEntProp(amp, Prop_Send, "m_iTeamNum"));

	if (TF2_GetPlayerClass(client) == TFClass_Spy && TF2_IsPlayerInCondition(client, TFCond_Disguised) && !TF2_IsPlayerInCondition(client, TFCond_Cloaked))
		team = clientTeam;

	TFCond Condition = DefaultCondition;
	Action res = Plugin_Continue;
	int builder = GetEntPropEnt(amp, Prop_Send, "m_hBuilder");
	if (fwdOnAmplify != null)
	{
		Call_StartForward(fwdOnAmplify);
		Call_PushCell(builder);
		Call_PushCell(client);
		Call_PushCell(Condition);
		Call_Finish(res);
	}
	if (res != Plugin_Continue)
		return false;

	if (clientTeam == team)
	{
		if (!AddAmplifierEffect(client, amp))
			return false;

		if (!ConditionApplied[amp][client])
		{
			EmitSoundToClient(client, AMPLIFIER_BUFF_SOUND, amp, _, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.5, SNDPITCH_HIGH);
		}
		ConditionApplied[amp][client] = true;
		g_PlayerState[client].nearAmplifier = true;
	}
	else if (zapDamage > 0.0)
	{
		DealElectricDamage(client, builder, amplifierPos, GetAmplifierDamage(amp, zapDamage), GetAmplifierEffectiveRadius(amp));
		return true;
	}
	else
	{
		return false;
	}

	if (metalPerPlayer > 0)
	{
		SetAmplifierMetal(amp, buildingClass, metal - metalPerPlayer);
	}

	return true;
}

void ApplyAmplifierEffectsToPlayers(int activeAmps[ME], int activeCount, int maxEntities, int metalPerPlayer, int metalMax, float zapDamage)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsValidClient(client))
			continue;

		g_PlayerState[client].nearAmplifier = false;

		if (!IsPlayerAlive(client) || !IsValidEdict(client))
			continue;

		for (int slot = 0; slot < activeCount; slot++)
		{
			int amp = activeAmps[slot];
			if (TryApplyAmplifierToClient(client, amp, metalPerPlayer, metalMax, zapDamage))
				break;
		}

		if (!g_PlayerState[client].nearAmplifier)
		{
			ClearAmplifierConditionForClient(client, maxEntities);
		}
	}
}

void PulseAmplifierBuilding(int ent, int metalPerPlayer, int metalMax)
{
	if (!IsActiveAmplifier(ent))
		return;

	ReassertAmplifierRuntimeState(ent);
	bool absorbedUpgradeMetal = AbsorbAmplifierUpgradeMetal(ent, metalMax);

	char buildingClass[64];
	int oldMetal;
	if (!GetAmplifierMetal(ent, oldMetal, buildingClass, sizeof(buildingClass)))
		return;
	UpdateAmplifierFill(ent, oldMetal, metalMax);

	float pos[3];
	GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
	pos[2] += 90;

	int beamColor[4];
	if (view_as<TFTeam>(GetEntProp(ent, Prop_Send, "m_iTeamNum")) == TFTeam_Red)
		beamColor = {255, 75, 75, 255};
	else
		beamColor = {75, 75, 255, 255};

	float colorScale = AmplifierFill[ent];
	beamColor[0] = RoundFloat(float(beamColor[0]) * colorScale);
	beamColor[1] = RoundFloat(float(beamColor[1]) * colorScale);
	beamColor[2] = RoundFloat(float(beamColor[2]) * colorScale);
	beamColor[3] = RoundFloat(float(beamColor[3]) * colorScale);

	if (oldMetal > metalPerPlayer)
	{
		EmitAmbientSound(AMPLIFIER_SOUND, pos, ent, SNDLEVEL_CAR, SND_NOFLAGS, 0.6, RoundToCeil(SNDPITCH_NORMAL * colorScale));
	}
	else
	{
		EmitAmbientSound(AMPLIFIER_EMPTY_SOUND, pos, ent, SNDLEVEL_CAR, SND_NOFLAGS, 0.5, SNDPITCH_NORMAL);
	}

	if (oldMetal > 0)
	{
		TE_SetupBeamRingPoint(pos, 10.0, GetAmplifierWaveRadius(ent), g_BeamSprite, g_HaloSprite, 0, 15, 3.0, 5.0, 0.0, beamColor, 3, 0);
		TE_SendToAll();
	}
	else
	{
		int emptyColor[4] = {75, 75, 75, 100};
		TE_SetupBeamRingPoint(pos, 10.0, GetEmptyAmplifierWaveRadius(ent), g_BeamSprite, g_HaloSprite, 0, 15, 3.0, 5.0, 0.0, emptyColor, 3, 0); // 144 is the final non-mini value at colorscale 0.
		TE_SendToAll();
	}

	if (absorbedUpgradeMetal)
	{
		EmitAmbientSound(AMPLIFIER_FILL_SOUND, pos);
	}
}

void PulseAmplifierBuildings(int activeAmps[ME], int activeCount, int metalPerPlayer, int metalMax)
{
	for (int slot = 0; slot < activeCount; slot++)
	{
		int ent = activeAmps[slot];
		PulseAmplifierBuilding(ent, metalPerPlayer, metalMax);
	}
}

public Action Timer_amplifier(Handle hTimer)
{
	int maxEntities = GetTrackedEntityLimit();
	int metalPerPlayer = GetConVarInt(cvarMetal);
	int metalMax = GetConVarInt(cvarMetalMax);
	float zapDamage = GetConVarFloat(cvarEnableZap);
	int activeCount = CollectActiveAmplifiers(maxEntities, g_ActiveAmplifiers);

	ApplyAmplifierEffectsToPlayers(g_ActiveAmplifiers, activeCount, maxEntities, metalPerPlayer, metalMax, zapDamage);
	PulseAmplifierBuildings(g_ActiveAmplifiers, activeCount, metalPerPlayer, metalMax);

	return Plugin_Continue;
}

public Action event_player_death(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (!IsValidPlayerIndex(attacker))
	{
		return Plugin_Continue;
	}

	int maxEntities = GetTrackedEntityLimit();
	for (int i = 1; i < maxEntities; i++)
	{
		int ent = EntRefToEntIndex(BuildingRef[i]);
		if (!IsTrackedEntityIndex(ent) || !AmplifierOn[ent] || AmplifierSapped[ent] || attacker == i)
		{
			continue;
		}

		if (ConditionApplied[ent][attacker])
		{
			int builder = GetEntPropEnt(ent, Prop_Send, "m_hBuilder");
			if (IsValidPlayerIndex(builder))
			{
				g_PlayerState[builder].engiAssists++;
				if (g_PlayerState[builder].engiAssists >= 4)
				{
					Event escortEvent = CreateEvent("player_escort_score", true);
					if (escortEvent != null)
					{
						escortEvent.SetInt("player", builder);
						escortEvent.SetInt("points", 1);
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

public Action Event_Build(Event event, const char[] name, bool dontBroadcast)
{
	int ent = GetEventInt(event, "index");
	CheckBuilding(ent);
	CheckSapper(ent);
	return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
    int entindex = event.GetInt("index"); // the destroyed entity
    if (!IsTrackedEntityIndex(entindex) || !IsValidEntity(entindex))
        return Plugin_Continue;
    char modelname[PLATFORM_MAX_PATH];
    GetEntPropString(entindex, Prop_Data, "m_ModelName", modelname, sizeof(modelname));
	if (StrContains(modelname, "plifier") == -1)
		return Plugin_Continue;

	bool wasMini = AmplifierMini[entindex];
	float amplifierDistance = GetAmplifierEffectiveRadius(entindex);
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	bool entwasbuilding = event.GetBool("was_building"); // building in progress
	float position[3];
	GetEntPropVector(entindex, Prop_Send, "m_vecOrigin", position);
	int explosionDamage = GetConVarInt(cvarEnableExplosion);
	if (explosionDamage > 0)
	{
		if (wasMini)
			explosionDamage = RoundToFloor(float(explosionDamage) * AMPLIFIER_MINI_MODIFIER);

		CreateAmplifierExplosion(position, attacker, entwasbuilding, explosionDamage, amplifierDistance);
	}

	ResetAmplifierBuildingState(entindex);
	return Plugin_Changed;
}

void CheckBuilding(int ent)
{
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent))
	{
		return;
	}

    char classname[64];
    int Client = GetEntPropEnt(ent, Prop_Send, "m_hBuilder");
    GetEdictClassname(ent, classname, sizeof(classname));

	bool isDispenser = IsDispenserClass(classname);
	bool isSentry = IsSentryClass(classname);

	if ((!isDispenser && !isSentry) || !IsValidClient(Client)) return;

	ResetAmplifierBuildingState(ent);
	BuildingRef[ent] = EntIndexToEntRef(ent);

	bool forcedConversion = false;
	bool playercountForceActive = false;
	int effectiveForceAmplifier = 0;
	bool playerRequestedAmplifier = false;
	bool shouldConvert = ShouldClientBuildAmplifier(Client, isDispenser, isSentry, forcedConversion, playercountForceActive, effectiveForceAmplifier, playerRequestedAmplifier);

    if (shouldConvert)
    {
        AmplifierOn[ent] = false;
		AmplifierMini[ent] = false;
        SetEntProp(ent, Prop_Send, "m_bDisabled", 1);
		if (GetEntPropFloat(ent, Prop_Send, "m_flModelScale") != 1.0)
		{
			SetEntPropFloat(ent, Prop_Send, "m_flModelScale", 0.85); // Minis use 0.75... too small
			AmplifierMini[ent] = true;
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
			AmplifierDistance[ent] = GetConVarFloat(cvarDistance);
			AmplifierCondition[ent] = DefaultCondition;
		}

		if (AmplifierMini[ent])
		{
			AmplifierDistance[ent] *= AMPLIFIER_MINI_MODIFIER;
		}

		char s[128];
		Format(s, sizeof(s), "%s.mdl", AmplifierModel);
		SetEntityModel(ent, s);
		SetEntProp(ent, Prop_Send, "m_nSkin", GetEntProp(ent, Prop_Send, "m_nSkin") + 2);
        // Build-rate modifiers can complete a sentry before a one-second
        // delayed check runs, so start the construction watchdog almost
        // immediately and let it continue after activation.
        CreateTimer(0.1, BuildingCheckStage2, EntIndexToEntRef(ent), TIMER_REPEAT | TIMER_NO_MAPCHANGE);

        if (forcedConversion && effectiveForceAmplifier == 2 && !playerRequestedAmplifier)
        {
            if (playercountForceActive)
            {
                CPrintToChat(Client, "{orange}[Amplifier]{default} Playercount is below %d; sentry replaced with amplifier!", GetConVarInt(cvarForcePlayercount));
            }
            else
            {
                CPrintToChat(Client, "{orange}[Amplifier]{default} Sentries have been disabled for this map; have an Amplifier instead!");
            }
        }
    }
}

public Action BuildingCheckStage1(Handle hTimer, any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (IsTrackedEntityIndex(ent) && IsValidEntity(ent))
	{
		CreateTimer(0.1, BuildingCheckStage2, ref, TIMER_REPEAT | TIMER_NO_MAPCHANGE);
	}
	return Plugin_Continue;
}

void SetAmplifierHealth(int ent, int health)
{
	SetEntProp(ent, Prop_Send, "m_iMaxHealth", health);
	char sHealth[16];
	IntToString(health, sHealth, sizeof(sHealth));
	SetVariantString(sHealth);
	AcceptEntityInput(ent, "SetHealth");
}

public Action BuildingCheckStage2(Handle hTimer, any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent)) return Plugin_Stop;
	if (BuildingRef[ent] != ref) return Plugin_Stop;

	if (!AmplifierOn[ent])
	{
		if (!IsAmplifierConstructionComplete(ent))
			return Plugin_Continue;

		AmplifierOn[ent] = true;
		SetEntProp(ent, Prop_Send, "m_iUpgradeLevel", 1);
		SetEntProp(ent, Prop_Send, "m_iHighestUpgradeLevel", 1);
		SetAmplifierBuildModel(ent);

		if (AmplifierMini[ent])
		{
			SetAmplifierHealth(ent, AMPLIFIER_MINI_HEALTH);
		}
		else
		{
			SetAmplifierHealth(ent, AMPLIFIER_HEALTH);
		}

		char buildingClass[64];
		GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
		int metalMax = GetConVarInt(cvarMetalMax);
		int startingFuel = (metalMax * 75) / 200;
		if (startingFuel < 0)
			startingFuel = 0;

		if (IsDispenserClass(buildingClass))
			SetEntProp(ent, Prop_Send, "m_iAmmoMetal", startingFuel);
		else if (IsSentryClass(buildingClass))
			SetEntProp(ent, Prop_Send, "m_iAmmoShells", startingFuel);

		UpdateAmplifierFill(ent, startingFuel, metalMax);
		SetEntProp(ent, Prop_Send, "m_iUpgradeMetal", 0);
		SetEntProp(ent, Prop_Send, "m_nSkin", GetEntProp(ent, Prop_Send, "m_nSkin") - 2);
		ReassertAmplifierRuntimeState(ent);

		return Plugin_Continue;
	}

	ReassertAmplifierRuntimeState(ent);
	AbsorbAmplifierUpgradeMetal(ent, GetConVarInt(cvarMetalMax));

	return Plugin_Continue;
}

void CheckSapper(int ent)
{
	if (IsTrackedEntityIndex(ent) && IsValidEntity(ent))
	{
		CreateTimer(0.5, SapperCheckStage1, EntIndexToEntRef(ent), TIMER_NO_MAPCHANGE);
	}
}

public Action SapperCheckStage1(Handle hTimer, any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent > 0 && IsValidEntity(ent))
	{
		char classname[64];
		GetEdictClassname(ent, classname, sizeof(classname));
		if (StrEqual(classname, BUILDING_SAPPER))
		{
			int maxEntities = GetTrackedEntityLimit();
			for (int i = 1; i < maxEntities; i++)
			{
				int ampref = BuildingRef[i];
				int ampent = EntRefToEntIndex(ampref);
				if (IsTrackedEntityIndex(ampent) && IsValidEntity(ampent) && GetEntProp(ampent, Prop_Send, "m_bHasSapper") == 1 && !AmplifierSapped[ampent])
				{
					AmplifierSapped[ampent] = true;
					CreateTimer(0.5, SapperCheckStage2, ampref, TIMER_REPEAT | TIMER_NO_MAPCHANGE);
					break;
				}
			}
		}
	}
	return Plugin_Continue;
}

public Action SapperCheckStage2(Handle hTimer, any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent <= 0 || !IsValidEntity(ent)) return Plugin_Stop;

	if (GetEntProp(ent, Prop_Send, "m_bHasSapper") == 0 && AmplifierSapped[ent])
	{
		AmplifierSapped[ent] = false;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

stock bool AddAmplifierEffect(int client, int amp)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return false;

    StopAmplifierEffect(client, false);

	float effectLength = GetAmplifierEffectLength(amp);
	TF2ConchNoSpeed_AddRegenBuff(client, effectLength, client);
    // Apply to first 3 slots
    for (int slot = 0; slot < 3; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon > MaxClients && IsValidEntity(weapon))
        {
			float factor_reloadrate = 0.60;
            int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
			if (defIndex == BEGGARS_BAZOOKA)
			{
				factor_reloadrate = 1.0;
			}
            //TF2Attrib_SetByName(weapon, ATTR_FIRE_RATE, factor_firerate);
	        TF2Attrib_SetByName(weapon, ATTR_RELOAD_RATE, factor_reloadrate);
        }
    }

    // Create a default length timer
    g_PlayerState[client].effectTimer = CreateTimer(effectLength, Timer_RemoveAmplifierEffect, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return true;
}

void RemoveAmplifierWeaponEffects(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;

	TF2ConchNoSpeed_RemoveRegenBuff(client);

	for (int slot = 0; slot < 3; slot++)
	{
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (weapon <= MaxClients || !IsValidEntity(weapon))
			continue;

		int defIndex = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
		if (defIndex == BEGGARS_BAZOOKA)
		{
			//TF2Attrib_SetByName(weapon, ATTR_FIRE_RATE, 0.30);
			TF2Attrib_SetByName(weapon, ATTR_RELOAD_RATE, 1.30);
		}
		else
		{
			//TF2Attrib_RemoveByName(weapon, ATTR_FIRE_RATE);
			TF2Attrib_RemoveByName(weapon, ATTR_RELOAD_RATE);
		}
	}
}

void StopAmplifierEffect(int client, bool removeWeaponEffects = true)
{
	if (client < 1 || client > MaxClients)
		return;

	bool hadEffect = g_PlayerState[client].effectTimer != INVALID_HANDLE;
	if (g_PlayerState[client].effectTimer != INVALID_HANDLE)
	{
		delete g_PlayerState[client].effectTimer;
		g_PlayerState[client].effectTimer = INVALID_HANDLE;
	}

	if (removeWeaponEffects && hadEffect)
	{
		RemoveAmplifierWeaponEffects(client);
	}
}

public Action Timer_RemoveAmplifierEffect(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && client <= MaxClients)
    {
		if (g_PlayerState[client].effectTimer == timer)
		{
			g_PlayerState[client].effectTimer = INVALID_HANDLE;
			RemoveAmplifierWeaponEffects(client);
		}
    }
    return Plugin_Stop;
}

stock int CheckAmpAttributesDisp(int client)
{
	if (!IsValidClient(client))
		return 0;

	int weapon = GetPlayerWeaponSlot(client, 4);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return 0;

	return (TF2CustAttr_GetInt(weapon, "amplifier attributes") != 0) ? 1 : 0;
}

stock int CheckAmpAttributesSentry(int client)
{
	if (!IsValidClient(client))
		return 0;

	int weapon = GetPlayerWeaponSlot(client, 4);
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return 0;

	return (TF2CustAttr_GetInt(weapon, "amplifier attributes sentry") != 0) ? 1 : 0;
}

void ConvertAllAmplifiersToBuildings()
{
	int maxEntities = GetTrackedEntityLimit();
	for (int i = 1; i < maxEntities; i++)
	{
		int ent = EntRefToEntIndex(BuildingRef[i]);
		if (IsTrackedEntityIndex(ent) && IsValidEntity(ent) && AmplifierOn[ent])
		{
			char buildingClass[64];
			GetEdictClassname(ent, buildingClass, sizeof(buildingClass));

			AmplifierOn[ent] = false;
			SetEntProp(ent, Prop_Send, "m_bDisabled", 0);
			AmplifierFill[ent] = 0.0;

			char modelname[128];
			if (IsDispenserClass(buildingClass))
				Format(modelname, sizeof(modelname), "models/buildables/dispenser.mdl");
			else if (IsSentryClass(buildingClass))
				Format(modelname, sizeof(modelname), "models/buildables/sentry1.mdl");
			else
				continue;

			SetEntityModel(ent, modelname);
			SetEntPropFloat(ent, Prop_Send, "m_flModelScale", 1.0);
			ResetAmplifierBuildingState(ent);
		}
	}
}

// Natives
public any Native_ControlAmplifier(Handle plugin, int numParams)
{
	NativeControl = view_as<bool>(GetNativeCell(1));
	return 0;
}

public any Native_SetAmplifierDisp(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsValidPlayerIndex(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);

	g_PlayerState[client].useDispenser = view_as<bool>(GetNativeCell(2));

	float distance = view_as<float>(GetNativeCell(3));
	NativeDistanceDisp[client] = (distance < 0.0) ? GetConVarFloat(cvarDistance) : distance;

	TFCond condition = view_as<TFCond>(GetNativeCell(4));
	NativeConditionDisp[client] = (condition < TFCond_Slowed) ? DefaultCondition : condition;
	return 0;
}

public any Native_SetAmplifierSentry(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (!IsValidPlayerIndex(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);

	g_PlayerState[client].useSentry = view_as<bool>(GetNativeCell(2));

	float distance = view_as<float>(GetNativeCell(3));
	NativeDistanceSentry[client] = (distance < 0.0) ? GetConVarFloat(cvarDistance) : distance;

	TFCond condition = view_as<TFCond>(GetNativeCell(4));
	NativeConditionSentry[client] = (condition < TFCond_Slowed) ? DefaultCondition : condition;
	return 0;
}

public any Native_HasAmplifier(Handle plugin, int numParams)
{
	int count = 0;
	int client = GetNativeCell(1);
	int maxEntities = GetTrackedEntityLimit();
	for (int i = 1; i < maxEntities; i++)
	{
		int ampref = BuildingRef[i];
		int ampent = EntRefToEntIndex(ampref);
		if (IsTrackedEntityIndex(ampent) && IsValidEntity(ampent) && GetEntPropEnt(ampent, Prop_Send, "m_hBuilder") == client)
			count++;
	}
	return count;
}

public any Native_ConvertToAmplifier(Handle plugin, int numParams)
{
	int ent = GetNativeCell(1);
	if (!IsTrackedEntityIndex(ent) || !IsValidEntity(ent)) return 0;

	int client = GetNativeCell(2);
	if (!IsValidPlayerIndex(client))
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);

	char buildingClass[64];
	GetEdictClassname(ent, buildingClass, sizeof(buildingClass));
	bool isDispenser = IsDispenserClass(buildingClass);

	bool saveDisp = g_PlayerState[client].useDispenser;
	bool saveSentry = g_PlayerState[client].useSentry;
	float saveDistDisp = NativeDistanceDisp[client];
	float saveDistSentry = NativeDistanceSentry[client];
	TFCond saveCondDisp = NativeConditionDisp[client];
	TFCond saveCondSentry = NativeConditionSentry[client];
	int savePercentDisp = NativePercentDisp[client];
	int savePercentSentry = NativePercentSentry[client];

	float distance = view_as<float>(GetNativeCell(3));
	TFCond condition = view_as<TFCond>(GetNativeCell(4));
	int percent = GetNativeCell(5);

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
	return 0;
}

public any Native_WouldReplaceBuilding(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int objectType = GetNativeCell(2);
	return WouldObjectTypeBecomeAmplifier(client, objectType);
}

// Utility Functions
stock bool IsValidClient(int client)
{
	return IsValidPlayerIndex(client) && client <= MaxClients && IsClientInGame(client);
}

void DealElectricDamage(int client, int builder, const float amplifierPos[3], float damage, float maxDistance)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client) || maxDistance <= 0.0)
        return;

    float clientPos[3];
    GetEntPropVector(client, Prop_Send, "m_vecOrigin", clientPos);

    float dist = GetVectorDistance(clientPos, amplifierPos);
    if (dist > maxDistance)
        return;

    // Damage scales inversely with distance (closer = more damage).
    float damageFinal = damage * (1.0 - (dist / maxDistance));
    if (damageFinal < 0.0) damageFinal = 0.0;

	int attacker = IsValidClient(builder) ? builder : 0;
    SDKHooks_TakeDamage(client, attacker, attacker, damageFinal, DMG_SHOCK);
}


void CreateAmplifierExplosion(float position[3], int attacker = 0, bool entwasbuilding = false, int damage = 0, float radiusUnits = 0.0)
{
	if (entwasbuilding) return;
    int explosion = CreateEntityByName("env_explosion");
    if (explosion == -1) {
        return;
    }

    if (radiusUnits <= 0.0)
        radiusUnits = GetConVarFloat(cvarDistance);
	int radius = RoundFloat(radiusUnits);
    char sDamage[16], sRadius[16];
    IntToString(damage, sDamage, sizeof(sDamage));
    IntToString(radius, sRadius, sizeof(sRadius));

    // Set explosion properties
    DispatchKeyValue(explosion, "iMagnitude", sDamage);
    DispatchKeyValue(explosion, "iRadiusOverride", sRadius);
    DispatchKeyValue(explosion, "spawnflags", "828");

    TeleportEntity(explosion, position, NULL_VECTOR, NULL_VECTOR);

    // Set attacker if valid
    bool validAttacker = IsValidClient(attacker);
    if (validAttacker)
    {
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
		int team = validAttacker ? GetClientTeam(attacker) : 0;
		TeleportEntity(particle, position, NULL_VECTOR, NULL_VECTOR);
		char storedParticle[64];
		strcopy(storedParticle, sizeof(storedParticle), "powerup_supernova_explode_red_spikes");
		if (team == 2)
		{
			strcopy(storedParticle, sizeof(storedParticle), "powerup_supernova_explode_blue_spikes");
		}
		DispatchKeyValue(particle, "effect_name", storedParticle);
		DispatchKeyValue(particle, "start_active", "0");
		DispatchSpawn(particle);
		ActivateEntity(particle);
		AcceptEntityInput(particle, "Start");
		CreateTimer(2.0, Timer_RemoveEntity, EntIndexToEntRef(particle), TIMER_NO_MAPCHANGE);
	}

	// Clean up explosion entity
	CreateTimer(0.1, Timer_RemoveEntity, EntIndexToEntRef(explosion), TIMER_NO_MAPCHANGE);
}

public Action Timer_RemoveEntity(Handle timer, int ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity != INVALID_ENT_REFERENCE && entity > MaxClients && IsValidEntity(entity))
    {
        RemoveEntity(entity);
    }
    return Plugin_Stop;
}

void KillAllSentries()
{
    int maxEnts = GetTrackedEntityLimit();
    char classname[64];
    for (int ent = MaxClients + 1; ent < maxEnts; ent++)
    {
        if (!IsValidEntity(ent))
            continue;

        GetEdictClassname(ent, classname, sizeof(classname));
        bool isSentry = IsSentryClass(classname);
        if (isSentry)
        {
            AcceptEntityInput(ent, "Kill");
        }
    }
}

public void killAllSentries()
{
    KillAllSentries();
}

public Action Command_KillSentries(int client, int args)
{
    KillAllSentries();

    if (client > 0 && IsClientInGame(client))
    {
        CPrintToChat(client, "{gold}[Amplifier]{default} All sentries have been destroyed.");
    }
    else
    {
        PrintToServer("[Amplifier] All sentries have been destroyed.");
    }

    return Plugin_Handled;
}

// Ray Trace
#tryinclude <raytrace>
#if !defined _raytrace_included
stock bool TraceTargetIndex(int client, int target, float clientLoc[3], float targetLoc[3])
{
	targetLoc[2] += 50.0;
	TR_TraceRayFilter(clientLoc, targetLoc, MASK_SOLID, RayType_EndPoint, TraceRayDontHitSelf, client);
	return (!TR_DidHit() || TR_GetEntityIndex() == target);
}

public bool TraceRayDontHitSelf(int entity, int mask, any data)
{
	return (entity != data);
}
#endif
