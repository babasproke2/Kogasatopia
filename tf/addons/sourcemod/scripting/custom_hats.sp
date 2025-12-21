#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <sdktools>
#include <tf2_stocks>
#include <tf2attributes>

#define CONFIG_FILE "configs/custom_hats.cfg"
#define DEFAULT_SCOUT_MODEL "models/uma_musume/player/items/scout/mercenary_derby.mdl"
#define DEFAULT_SCOUT_DEFINDEX 451
#if !defined EF_BONEMERGE
#define EF_BONEMERGE 0x0010
#endif
#if !defined EF_BONEMERGE_FASTCULL
#define EF_BONEMERGE_FASTCULL 0x0800
#endif

char g_ScoutHatModel[PLATFORM_MAX_PATH];
bool g_bScoutHatEnabled = false;
bool g_bHatWanted[MAXPLAYERS + 1];
int g_iHatRef[MAXPLAYERS + 1];
int g_iHideHatRef[MAXPLAYERS + 1];
Handle g_hHatCookie = INVALID_HANDLE;
Handle g_hHatPaintCookie = INVALID_HANDLE;
Handle g_hWearableEquip = INVALID_HANDLE;
int g_iHatDefIndex = 0;
int g_iHatQuality = 6;
int g_iHatLevel = 10;
int g_iHatPaint = 0;
int g_iHatStyle = 0;
int g_iHatPaintChoice[MAXPLAYERS + 1];

static const char g_HatId[] = "mercenary_derby";
static const char g_HatName[] = "mercenary_derby";
static const int g_HideHatDefIndex = 111;

static const char g_PaintNames[][48] =
{
	"No Paint",
	"A color similar to slate",
	"A deep commitment to purple",
	"A distinctive lack of hue",
	"A mann's mint",
	"After eight",
	"Aged Moustache Grey",
	"An Extraordinary abundance of tinge",
	"Australium gold",
	"Color no 216-190-216",
	"Dark salmon injustice",
	"Drably olive",
	"Indubitably green",
	"Mann co orange",
	"Muskelmannbraun",
	"Noble hatters violet",
	"Peculiarly drab tincture",
	"Pink as hell",
	"Radigan conagher brown",
	"A bitter taste of defeat and lime",
	"The color of a gentlemanns business pants",
	"Ye olde rustic colour",
	"Zepheniahs greed",
	"An air of debonair",
	"Balaclavas are forever",
	"Cream spirit",
	"Operators overalls",
	"Team spirit",
	"The value of teamwork",
	"Waterlogged lab coat"
};

public Plugin myinfo =
{
	name = "Custom Hats",
	author = "Codex",
	description = "Equips configured custom hats for scouts.",
	version = "1.0.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	HookEvent("post_inventory_application", Event_PostInventory, EventHookMode_Post);
	RegConsoleCmd("sm_hats", Command_Hats, "Open the custom hats menu");
	g_hHatCookie = RegClientCookie("custom_hat_mercenary_derby", "Custom hat selection", CookieAccess_Protected);
	g_hHatPaintCookie = RegClientCookie("custom_hat_mercenary_derby_paint", "Custom hat paint", CookieAccess_Protected);

	GameData hTF2 = new GameData("sm-tf2.games");
	if (hTF2 == null)
	{
		SetFailState("This plugin is designed for a TF2 dedicated server only.");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetVirtual(hTF2.GetOffset("RemoveWearable") - 1);
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hWearableEquip = EndPrepSDKCall();

	if (g_hWearableEquip == null)
	{
		SetFailState("Failed to create call: CBasePlayer::EquipWearable");
	}

	delete hTF2;

	for (int i = 1; i <= MaxClients; i++)
	{
		g_iHatRef[i] = INVALID_ENT_REFERENCE;
		g_iHideHatRef[i] = INVALID_ENT_REFERENCE;
		g_bHatWanted[i] = false;
		g_iHatPaintChoice[i] = 0;
	}

	LoadConfig();
}

public void OnConfigsExecuted()
{
	LoadConfig();
	PrecacheConfiguredHat();
	if (!g_bScoutHatEnabled || !g_ScoutHatModel[0])
	{
		RemoveAllHats();
	}
}

public void OnMapStart()
{
	PrecacheConfiguredHat();
}

public void OnClientPutInServer(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	g_iHatRef[client] = INVALID_ENT_REFERENCE;
	g_iHideHatRef[client] = INVALID_ENT_REFERENCE;
	g_bHatWanted[client] = false;
	g_iHatPaintChoice[client] = g_iHatPaint;
}

public void OnClientCookiesCached(int client)
{
	if (!IsValidClient(client) || g_hHatCookie == INVALID_HANDLE)
	{
		return;
	}

	char value[8];
	GetClientCookie(client, g_hHatCookie, value, sizeof(value));
	g_bHatWanted[client] = (value[0] != '\0' && StringToInt(value) != 0);

	if (g_hHatPaintCookie != INVALID_HANDLE)
	{
		char paintValue[8];
		GetClientCookie(client, g_hHatPaintCookie, paintValue, sizeof(paintValue));
		if (paintValue[0] != '\0')
		{
			g_iHatPaintChoice[client] = StringToInt(paintValue);
		}
		else
		{
			g_iHatPaintChoice[client] = g_iHatPaint;
		}
	}
}

public void OnClientDisconnect(int client)
{
	RemoveHat(client);
}

public Action Command_Hats(int client, int args)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if (!g_bScoutHatEnabled || !g_ScoutHatModel[0])
	{
		ReplyToCommand(client, "[Hats] No hats are available right now.");
		return Plugin_Handled;
	}

	ShowHatMenu(client);
	return Plugin_Handled;
}

public void Event_PostInventory(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidClient(client))
	{
		return;
	}

	RequestFrame(ApplyHatFrame, GetClientUserId(client));
}

public void ApplyHatFrame(any userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client))
	{
		return;
	}

	UpdateHatForClient(client);
}

void UpdateHatForClient(int client)
{
	if (!g_bScoutHatEnabled || !g_ScoutHatModel[0] || !g_bHatWanted[client])
	{
		RemoveHat(client);
		return;
	}

	if (GetClientTeam(client) <= 1 || TF2_GetPlayerClass(client) != TFClass_Scout)
	{
		RemoveHat(client);
		return;
	}

	EquipScoutHat(client);
}

void ShowHatMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Hats);
	menu.SetTitle("Custom Hats");
	menu.AddItem(g_HatId, g_HatName);
	menu.ExitBackButton = false;
	menu.Display(client, 20);
}

public int MenuHandler_Hats(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		ShowHatToggleMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowHatToggleMenu(int client)
{
	Menu menu = new Menu(MenuHandler_HatToggle);
	menu.SetTitle(g_HatName);
	menu.AddItem("enable", "1. Enable");
	menu.AddItem("disable", "2. Disable");
	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int MenuHandler_HatToggle(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		bool enable = StrEqual(info, "enable");
		g_bHatWanted[client] = enable;

		if (g_hHatCookie != INVALID_HANDLE)
		{
			SetClientCookie(client, g_hHatCookie, enable ? "1" : "0");
		}

		if (enable)
		{
			ShowHatPaintMenu(client);
		}
		else
		{
			RemoveHat(client);
			PrintToChat(client, "[Hats] Disabled %s.", g_HatName);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void ShowHatPaintMenu(int client)
{
	Menu menu = new Menu(MenuHandler_HatPaint);
	menu.SetTitle("Select Paint");

	char key[8];
	for (int i = 0; i < sizeof(g_PaintNames); i++)
	{
		IntToString(i, key, sizeof(key));
		menu.AddItem(key, g_PaintNames[i]);
	}

	menu.ExitBackButton = true;
	menu.Display(client, 20);
}

public int MenuHandler_HatPaint(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		int paint = StringToInt(info);
		g_iHatPaintChoice[client] = paint;

		if (g_hHatPaintCookie != INVALID_HANDLE)
		{
			SetClientCookie(client, g_hHatPaintCookie, info);
		}

		EquipScoutHat(client);
		PrintToChat(client, "[Hats] %s applied.", g_PaintNames[paint]);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void EquipScoutHat(int client)
{
	RemoveHat(client);

	int hideWearable = CreateWearableBase(client, g_HideHatDefIndex, g_iHatLevel, g_iHatQuality);
	if (hideWearable != -1)
	{
		g_iHideHatRef[client] = EntIndexToEntRef(hideWearable);
	}

	int paint = g_iHatPaintChoice[client];
	int wearable = CreateHat(client, g_ScoutHatModel, g_iHatDefIndex, g_iHatLevel, g_iHatQuality, paint);
	if (wearable != -1)
	{
		g_iHatRef[client] = EntIndexToEntRef(wearable);
	}
}

void RemoveHat(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	int ent = EntRefToEntIndex(g_iHatRef[client]);
	if (ent != INVALID_ENT_REFERENCE && IsValidEntity(ent))
	{
		RemoveEntity(ent);
	}
	g_iHatRef[client] = INVALID_ENT_REFERENCE;

	int hideEnt = EntRefToEntIndex(g_iHideHatRef[client]);
	if (hideEnt != INVALID_ENT_REFERENCE && IsValidEntity(hideEnt))
	{
		RemoveEntity(hideEnt);
	}
	g_iHideHatRef[client] = INVALID_ENT_REFERENCE;
}

int CreateWearableBase(int client, int itemIndex, int level, int quality)
{
	int entity = CreateEntityByName("tf_wearable");
	if (entity == -1 || !IsValidEntity(entity))
	{
		return -1;
	}

	char entclass[64];
	GetEntityNetClass(entity, entclass, sizeof(entclass));
	SetEntData(entity, FindSendPropInfo(entclass, "m_iItemDefinitionIndex"), itemIndex);
	SetEntData(entity, FindSendPropInfo(entclass, "m_bInitialized"), 1);
	SetEntData(entity, FindSendPropInfo(entclass, "m_iEntityLevel"), level);
	SetEntData(entity, FindSendPropInfo(entclass, "m_iEntityQuality"), quality);
	SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
	SetEntProp(entity, Prop_Send, "m_iAccountID", GetSteamAccountID(client));
	SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", client);

	SetEntProp(entity, Prop_Send, "m_fEffects", EF_BONEMERGE | EF_BONEMERGE_FASTCULL);
	SetEntProp(entity, Prop_Send, "m_iTeamNum", GetClientTeam(client));
	SetEntProp(entity, Prop_Send, "m_nSkin", GetClientTeam(client));
	SetEntProp(entity, Prop_Send, "m_usSolidFlags", 4);
	SetEntProp(entity, Prop_Send, "m_CollisionGroup", 11);
	SetEntProp(entity, Prop_Send, "m_iItemIDLow", 2048);
	SetEntProp(entity, Prop_Send, "m_iItemIDHigh", 0);

	DispatchSpawn(entity);
	ActivateEntity(entity);
	SDKCall(g_hWearableEquip, client, entity);

	return entity;
}

int CreateHat(int client, const char[] modelPath, int itemIndex, int level, int quality, int paint)
{
	int entity = CreateWearableBase(client, itemIndex, level, quality);
	if (entity == -1)
	{
		return -1;
	}

	ApplyCustomModel(entity, modelPath);

	if (paint > 0)
	{
		ApplyPaint(entity, paint);
	}

	ApplyStyle(entity, g_iHatStyle);
	return entity;
}

void RemoveAllHats()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			RemoveHat(i);
		}
	}
}

void PrecacheConfiguredHat()
{
	if (g_bScoutHatEnabled && g_ScoutHatModel[0])
	{
		PrecacheModel(g_ScoutHatModel, true);
	}
}

void LoadConfig()
{
	g_bScoutHatEnabled = false;
	g_ScoutHatModel[0] = '\0';
	g_iHatDefIndex = 0;
	g_iHatQuality = 6;
	g_iHatLevel = 10;
	g_iHatPaint = 0;
	g_iHatStyle = 0;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);

	if (!FileExists(path))
	{
		CreateDefaultConfig(path);
	}

	KeyValues kv = new KeyValues("CustomHats");
	if (!kv.ImportFromFile(path))
	{
		LogError("[CustomHats] Failed to parse config file: %s", path);
		delete kv;
		return;
	}

	if (kv.JumpToKey("scout"))
	{
		kv.GetString("model", g_ScoutHatModel, sizeof(g_ScoutHatModel), DEFAULT_SCOUT_MODEL);
		g_bScoutHatEnabled = (kv.GetNum("enabled", 1) != 0) && g_ScoutHatModel[0];
		g_iHatDefIndex = kv.GetNum("defindex", DEFAULT_SCOUT_DEFINDEX);
		g_iHatQuality = kv.GetNum("quality", 6);
		g_iHatLevel = kv.GetNum("level", 10);
		g_iHatPaint = kv.GetNum("paint", 0);
		g_iHatStyle = kv.GetNum("style", 0);
		kv.GoBack();
	}

	delete kv;
}

void CreateDefaultConfig(const char[] path)
{
	File file = OpenFile(path, "w");
	if (file == null)
	{
		LogError("[CustomHats] Failed to create config file: %s", path);
		return;
	}

	file.WriteLine("\"CustomHats\"");
	file.WriteLine("{");
	file.WriteLine("    \"scout\"");
	file.WriteLine("    {");
	file.WriteLine("        \"enabled\" \"1\"");
	file.WriteLine("        \"model\" \"%s\"", DEFAULT_SCOUT_MODEL);
	file.WriteLine("        \"defindex\" \"%d\"", DEFAULT_SCOUT_DEFINDEX);
	file.WriteLine("        \"quality\" \"6\"");
	file.WriteLine("        \"level\" \"10\"");
	file.WriteLine("        \"paint\" \"0\"");
	file.WriteLine("        \"style\" \"0\"");
	file.WriteLine("    }");
	file.WriteLine("}");
	delete file;
}

bool IsValidClient(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void ApplyCustomModel(int entity, const char[] modelPath)
{
	if (!modelPath[0])
	{
		return;
	}

	int modelIndex = PrecacheModel(modelPath, true);
	SetEntityModel(entity, modelPath);
	SetEntProp(entity, Prop_Send, "m_nModelIndex", modelIndex);
	if (HasEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity"))
	{
		SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
	}

	if (HasEntProp(entity, Prop_Send, "m_nModelIndexOverrides"))
	{
		int count = GetEntPropArraySize(entity, Prop_Send, "m_nModelIndexOverrides");
		for (int i = 0; i < count; i++)
		{
			SetEntProp(entity, Prop_Send, "m_nModelIndexOverrides", modelIndex, .element = i);
		}
	}
}

void ApplyStyle(int entity, int style)
{
	if (style < 0)
	{
		return;
	}

	TF2Attrib_SetByDefIndex(entity, 834, float(style));
	if (HasEntProp(entity, Prop_Send, "m_nStyle"))
	{
		SetEntProp(entity, Prop_Send, "m_nStyle", style);
	}
}

void ApplyPaint(int hat, int paint)
{
	switch (paint)
	{
		case 1:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3100495.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3100495.0);
		}
		case 2:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8208497.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8208497.0);
		}
		case 3:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 1315860.0);
			TF2Attrib_SetByDefIndex(hat, 261, 1315860.0);
		}
		case 4:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12377523.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12377523.0);
		}
		case 5:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 2960676.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2960676.0);
		}
		case 6:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8289918.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8289918.0);
		}
		case 7:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15132390.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15132390.0);
		}
		case 8:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15185211.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15185211.0);
		}
		case 9:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 14204632.0);
			TF2Attrib_SetByDefIndex(hat, 261, 14204632.0);
		}
		case 10:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15308410.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15308410.0);
		}
		case 11:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8421376.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8421376.0);
		}
		case 12:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 7511618.0);
			TF2Attrib_SetByDefIndex(hat, 261, 7511618.0);
		}
		case 13:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 13595446.0);
			TF2Attrib_SetByDefIndex(hat, 261, 13595446.0);
		}
		case 14:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 10843461.0);
			TF2Attrib_SetByDefIndex(hat, 261, 10843461.0);
		}
		case 15:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 5322826.0);
			TF2Attrib_SetByDefIndex(hat, 261, 5322826.0);
		}
		case 16:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12955537.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12955537.0);
		}
		case 17:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 16738740.0);
			TF2Attrib_SetByDefIndex(hat, 261, 16738740.0);
		}
		case 18:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 6901050.0);
			TF2Attrib_SetByDefIndex(hat, 261, 6901050.0);
		}
		case 19:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3329330.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3329330.0);
		}
		case 20:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 15787660.0);
			TF2Attrib_SetByDefIndex(hat, 261, 15787660.0);
		}
		case 21:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8154199.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8154199.0);
		}
		case 22:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 4345659.0);
			TF2Attrib_SetByDefIndex(hat, 261, 4345659.0);
		}
		case 23:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 6637376.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2636109.0);
		}
		case 24:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 3874595.0);
			TF2Attrib_SetByDefIndex(hat, 261, 1581885.0);
		}
		case 25:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12807213.0);
			TF2Attrib_SetByDefIndex(hat, 261, 12091445.0);
		}
		case 26:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 4732984.0);
			TF2Attrib_SetByDefIndex(hat, 261, 3686984.0);
		}
		case 27:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 12073019.0);
			TF2Attrib_SetByDefIndex(hat, 261, 5801378.0);
		}
		case 28:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 8400928.0);
			TF2Attrib_SetByDefIndex(hat, 261, 2452877.0);
		}
		case 29:
		{
			TF2Attrib_SetByDefIndex(hat, 142, 11049612.0);
			TF2Attrib_SetByDefIndex(hat, 261, 8626083.0);
		}
	}
}
