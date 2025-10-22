#pragma semicolon 1

#include <voicemanager>
#include <morecolors>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION "1.0.2"
#define VOICE_MANAGER_PREFIX "{green}[VOICE MANAGER]{default}"
#define STEAM_ID_BUF_SIZE 18
#define OVERRIDE_COOKIE_SIZE 2048

#pragma newdecls required

int g_iSelection[MAXPLAYERS+1] = {0};
int g_iCookieSelection[MAXPLAYERS+1] = {-1};

// Cvars
ConVar g_Cvar_VoiceEnable;
ConVar g_Cvar_AllowSelfOverride;

// Cookies
Handle g_Cookie_GlobalOverride;
Handle g_Cookie_PlayerOverrides;

// Override cache
StringMap g_hOverrides[MAXPLAYERS + 1];

public Extension __ext_voicemanager =
{
    name = "VoiceManager",
    file = "voicemanager.ext",
    required = 1,
}

public Plugin myinfo =
{
    name = "[TF2/OF] Voice Manager",
    author = "Fraeven (Extension/Plugin) + Rowedahelicon (Plugin) + Hombre (New Version)",
    description = "Plugin for Voice Manager Extension",
    version = PLUGIN_VERSION,
    url = "https://www.scg.wtf"
};

public void OnPluginStart()
{
    g_Cvar_VoiceEnable = FindConVar("vm_enable");
    g_Cvar_AllowSelfOverride = CreateConVar("vm_allow_self", "0", "Allow players to override their own volume (recommended only for testing)");

    RegConsoleCmd("sm_vm", CommandBaseMenu);
    RegConsoleCmd("sm_voice", CommandBaseMenu);
    RegConsoleCmd("sm_voicemanager", CommandBaseMenu);
    RegConsoleCmd("sm_vmclear", Command_ClearClientOverrides);
    RegConsoleCmd("sm_v", Command_VoiceSet);

    HookConVarChange(g_Cvar_VoiceEnable, OnVoiceEnableChanged);

    g_Cookie_GlobalOverride = RegClientCookie("voicemanager_cookie", "VM Global Toggle", CookieAccess_Public);
    g_Cookie_PlayerOverrides = RegClientCookie("voicemanager_overrides", "VM Override Data", CookieAccess_Protected);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_hOverrides[i] = null;

        if (!IsClientInGame(i))
        {
            continue;
        }

        EnsureOverrideMap(i);

        if (AreClientCookiesCached(i))
        {
            LoadOverridesFromCookie(i);
            if (g_Cvar_VoiceEnable.BoolValue)
            {
                RefreshActiveOverrides();
            }
        }
    }
}

public void OnVoiceEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshActiveOverrides();
}

public void OnClientPostAdminCheck(int client)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return;
    }

    EnsureOverrideMap(client);

    if (AreClientCookiesCached(client))
    {
        LoadOverridesFromCookie(client);
        RefreshActiveOverrides();
    }
}

public void OnClientCookiesCached(int client)
{
    char sCookieValue[12];
    GetClientCookie(client, g_Cookie_GlobalOverride, sCookieValue, sizeof(sCookieValue));

    // This is because cookies default to empty and otherwise we use 0 as our lowest volume setting
    if (sCookieValue[0] != '\0')
    {
        int cookieValue = StringToInt(sCookieValue);
        g_iCookieSelection[client] = cookieValue;
        OnPlayerGlobalAdjust(client, cookieValue);
    }
    else
    {
        g_iCookieSelection[client] = -1;
    }

    LoadOverridesFromCookie(client);
    if (g_Cvar_VoiceEnable.BoolValue)
    {
        RefreshActiveOverrides();
    }
}

public void OnClientDisconnect(int client)
{
    SaveOverridesToCookie(client);

    if (g_hOverrides[client] != null)
    {
        delete g_hOverrides[client];
        g_hOverrides[client] = null;
    }
}

// Menus
public Action CommandBaseMenu(int client, int args)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return Plugin_Handled;
    }

    char playerBuffer[32];
    char stringBuffer[32];
    int playersAdjusted = 0;

    for (int otherClient = 1; otherClient <= MaxClients; otherClient++)
    {
        if (IsValidClient(otherClient) && (g_Cvar_AllowSelfOverride.BoolValue || otherClient != client) && !IsFakeClient(otherClient) && GetClientOverride(client, otherClient) >= 0)
        {
            playersAdjusted++;
        }
    }

    Format(playerBuffer, sizeof(playerBuffer), "Player Adjustment (%i active)", playersAdjusted);

    if (g_iCookieSelection[client] != -1)
    {
        char label[16];
        GetVolumeLabel(g_iCookieSelection[client], label, sizeof(label));
        Format(stringBuffer, sizeof(stringBuffer), "Global Adjustment (%s)", label);
    }
    else
    {
        Format(stringBuffer, sizeof(stringBuffer), "Global Adjustment");
    }

    Menu menu = new Menu(BaseMenuHandler);
    menu.SetTitle("Voice Manager");
    menu.AddItem("players", playerBuffer);
    menu.AddItem("global", stringBuffer);
    menu.AddItem("clear", "Clear Player Adjustments");
    menu.ExitButton = true;
    menu.Display(client, 20);

    return Plugin_Handled;
}

static bool IsValidVolumeLevel(int level)
{
    switch (level)
    {
        case -1, 0, 1, 2, 3:
        {
            return true;
        }
    }

    return false;
}

static void GetVolumeLabel(int level, char[] buffer, int length)
{
    switch (level)
    {
        case 3:
        {
            strcopy(buffer, length, "Louder");
            return;
        }
        case 2:
        {
            strcopy(buffer, length, "Loud");
            return;
        }
        case 1:
        {
            strcopy(buffer, length, "Quiet");
            return;
        }
        case 0:
        {
            strcopy(buffer, length, "Quieter");
            return;
        }
        default:
        {
            strcopy(buffer, length, "Normal");
            return;
        }
    }
}

public int BaseMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        bool found = menu.GetItem(param2, info, sizeof(info));

        if (found)
        {
            if (StrEqual(info, "players"))
            {
                Menu players = new Menu(VoiceMenuHandler);
                players.SetTitle("Player Voice Manager");

                char id[4];
                char name[32];

                for (int otherClient = 1; otherClient <= MaxClients; otherClient++)
                {
                    if (IsValidClient(otherClient) && (g_Cvar_AllowSelfOverride.BoolValue || otherClient != client) && !IsFakeClient(otherClient))
                    {
                        int override = GetClientOverride(client, otherClient);

                        if (override >= 0 && IsValidVolumeLevel(override))
                        {
                            char label[16];
                            GetVolumeLabel(override, label, sizeof(label));
                            Format(name, sizeof(name), "%N (%s)", otherClient, label);
                        }
                        else
                        {
                            Format(name, sizeof(name), "%N", otherClient);
                        }
                        IntToString(otherClient, id, sizeof(id));
                        players.AddItem(id, name);
                    }
                }

                if (players.ItemCount == 0)
                {
                    CPrintToChat(client, "%s There are no players to adjust.", VOICE_MANAGER_PREFIX);
                    return 0;
                }

                players.ExitButton = true;
                players.ExitBackButton = true;
                players.Display(client, 20);
            }
            else if (StrEqual(info, "global"))
            {
                Menu global = new Menu(GlobalVoiceVolumeHandler);

                global.SetTitle("Adjust global volume level");
                global.AddItem("3", g_iCookieSelection[client] == 3 ? "Louder *" : "Louder");
                global.AddItem("2", g_iCookieSelection[client] == 2 ? "Loud *" : "Loud");
                global.AddItem("-1", g_iCookieSelection[client] == -1 ? "Normal *" : "Normal");
                global.AddItem("1", g_iCookieSelection[client] == 1 ? "Quiet *" : "Quiet");
                global.AddItem("0", g_iCookieSelection[client] == 0 ? "Quieter *" : "Quieter");

                global.ExitButton = true;
                global.ExitBackButton = true;
                global.Display(client, 20);
            }
            else if (StrEqual(info, "clear"))
            {
                Menu clear = new Menu(ClearMenuHandler);

                clear.SetTitle("Remove all player volume adjustments?");
                clear.AddItem("1", "Yes");
                clear.AddItem("0", "No");

                clear.ExitButton = true;
                clear.Display(client, 20);
            }
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public Action Command_ClearClientOverrides(int client, int args)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return Plugin_Handled;
    }
    ClearClientOverrides(client);
    ClearOverrideData(client);
    SaveOverridesToCookie(client);

    CPrintToChat(client, "%s You have cleared all of your voice overrides!", VOICE_MANAGER_PREFIX);

    return Plugin_Handled;

}

public void OnClearClientOverrides(int client)
{
    ClearClientOverrides(client);
    ClearOverrideData(client);
    SaveOverridesToCookie(client);

    CPrintToChat(client, "%s You have cleared all of your voice overrides!", VOICE_MANAGER_PREFIX);
}

//Handlers
public int VoiceMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        bool found = menu.GetItem(param2, info, sizeof(info));
        if (found)
        {
            int otherClient = StringToInt(info);
            int override = GetClientOverride(param1, otherClient);

            g_iSelection[param1] = otherClient;

            Menu sub_menu = new Menu(VoiceVolumeHandler);

            sub_menu.SetTitle("Adjust %N's volume level", otherClient);
            sub_menu.AddItem("3", override == 3 ? "Louder *" : "Louder");
            sub_menu.AddItem("2", override == 2 ? "Loud *" : "Loud");
            sub_menu.AddItem("-1", override == -1 ? "Normal *" : "Normal");
            sub_menu.AddItem("1", override == 1 ? "Quiet *" : "Quiet");
            sub_menu.AddItem("0", override == 0 ? "Quieter *" : "Quieter");

            sub_menu.ExitButton = true;
            sub_menu.ExitBackButton = true;
            sub_menu.Display(param1, 20);
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(param1, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public int ClearMenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));
        int yes = StringToInt(info);
        if (yes)
        {
            OnClearClientOverrides(client);
        }
        else
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public int VoiceVolumeHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        char setting[32];
        bool found = menu.GetItem(param2, info, sizeof(info), _, setting, sizeof(setting));
        if (found)
        {
            int level = StringToInt(info);
            if (!OnPlayerAdjustVolume(client, g_iSelection[client], level))
            {
                CPrintToChat(client, "%s Something went wrong, please try again soon!", VOICE_MANAGER_PREFIX);
            }
            else
            {
                CPrintToChat(client, "%s %N's level is now set to %s.", VOICE_MANAGER_PREFIX, g_iSelection[client], setting);
            }

            int target = g_iSelection[client];
            if (IsValidClient(target))
            {
                char targetSteam[STEAM_ID_BUF_SIZE];
                if (GetClientAuthId(target, AuthId_SteamID64, targetSteam, sizeof(targetSteam)))
                {
                    UpdateOverrideEntry(client, targetSteam, level);
                }
            }
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

public void SQLErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE || strlen(error) > 1)
    {
        LogError("[VoiceManager] SQL Error: %s", error);
    }
}

public int GlobalVoiceVolumeHandler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        char setting[32];
        bool found = menu.GetItem(param2, info, sizeof(info), _, setting, sizeof(setting));
        if (found)
        {
            int volume = StringToInt(info);
            if (!OnPlayerGlobalAdjust(client, volume))
            {
                CPrintToChat(client, "%s Something went wrong, please try again soon!", VOICE_MANAGER_PREFIX);
            }
            else
            {
                CPrintToChat(client, "%s Global voice volume is now set to %s.", VOICE_MANAGER_PREFIX, setting);
                SetClientCookie(client, g_Cookie_GlobalOverride, info);
                g_iCookieSelection[client] = volume;
            }
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (param2 == MenuCancel_ExitBack)
        {
            CommandBaseMenu(client, 0);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void EnsureOverrideMap(int client)
{
    if (g_hOverrides[client] == null)
    {
        g_hOverrides[client] = new StringMap();
    }
}

void ClearOverrideData(int client)
{
    if (g_hOverrides[client] != null)
    {
        g_hOverrides[client].Clear();
    }
}

void LoadOverridesFromCookie(int client)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return;
    }

    if (!AreClientCookiesCached(client))
    {
        return;
    }

    EnsureOverrideMap(client);
    ClearOverrideData(client);

    ClearClientOverrides(client);

    char data[OVERRIDE_COOKIE_SIZE];
    GetClientCookie(client, g_Cookie_PlayerOverrides, data, sizeof(data));

    if (!data[0])
    {
        return;
    }

    char entries[64][64];
    int count = ExplodeString(data, ";", entries, sizeof(entries), sizeof(entries[]));

    for (int i = 0; i < count; i++)
    {
        if (!entries[i][0])
        {
            continue;
        }

        char parts[2][32];
        if (ExplodeString(entries[i], ":", parts, sizeof(parts), sizeof(parts[])) < 2)
        {
            continue;
        }

        int level = StringToInt(parts[1]);
        if (!IsValidVolumeLevel(level) || level == -1)
        {
            continue;
        }

        g_hOverrides[client].SetValue(parts[0], level);

        char targetSteamId[STEAM_ID_BUF_SIZE];
        strcopy(targetSteamId, sizeof(targetSteamId), parts[0]);
        LoadPlayerAdjustment(client, targetSteamId, level);
    }
}

void SaveOverridesToCookie(int client)
{
    if (g_hOverrides[client] == null || g_hOverrides[client].Size == 0)
    {
        SetClientCookie(client, g_Cookie_PlayerOverrides, "");
        return;
    }

    char buffer[OVERRIDE_COOKIE_SIZE];
    buffer[0] = '\0';

    StringMapSnapshot snapshot = g_hOverrides[client].Snapshot();
    for (int i = 0; i < snapshot.Length; i++)
    {
        char steamId[STEAM_ID_BUF_SIZE];
        if (!snapshot.GetKey(i, steamId, sizeof(steamId)))
        {
            continue;
        }

        int level;
        if (!g_hOverrides[client].GetValue(steamId, level))
        {
            continue;
        }

        if (!IsValidVolumeLevel(level) || level == -1)
        {
            continue;
        }

        char entry[64];
        Format(entry, sizeof(entry), "%s:%d;", steamId, level);

        if (strlen(buffer) + strlen(entry) >= sizeof(buffer))
        {
            LogError("[VoiceManager] Override cookie truncated for client %N", client);
            break;
        }

        StrCat(buffer, sizeof(buffer), entry);
    }
    delete snapshot;

    SetClientCookie(client, g_Cookie_PlayerOverrides, buffer);
}

void UpdateOverrideEntry(int client, const char[] steamId, int level)
{
    EnsureOverrideMap(client);

    if (level == -1)
    {
        g_hOverrides[client].Remove(steamId);
    }
    else if (IsValidVolumeLevel(level))
    {
        g_hOverrides[client].SetValue(steamId, level);
    }

    SaveOverridesToCookie(client);
}

stock bool IsValidClient(int client)
{
    if (!client || client > MaxClients || client < 1 || !IsClientInGame(client))
    {
        return false;
    }

    return true;
}
public Action Command_VoiceSet(int client, int args)
{
    if (!g_Cvar_VoiceEnable.BoolValue)
    {
        return Plugin_Handled;
    }

    if (args < 2)
    {
        if (client > 0 && client <= MaxClients && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Usage: !voicewhale <player> <level (-1,0,1,2,3)>", VOICE_MANAGER_PREFIX);
        }
        else
        {
            PrintToServer("[VOICE MANAGER] Usage: sm_voicewhale <player> <level (-1,0,1,2,3)>");
        }
        return Plugin_Handled;
    }

    char targetArg[64];
    char levelArg[16];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    GetCmdArg(2, levelArg, sizeof(levelArg));

    TrimString(targetArg);
    TrimString(levelArg);

    if (!targetArg[0] || !levelArg[0])
    {
        if (client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Usage: !voicewhale <player> <level (-1,0,1,2,3)>", VOICE_MANAGER_PREFIX);
        }
        else
        {
            PrintToServer("[VOICE MANAGER] Usage: sm_voicewhale <player> <level (-1,0,1,2,3)>");
        }
        return Plugin_Handled;
    }

    int desiredLevel = StringToInt(levelArg);
    if (!IsValidVolumeLevel(desiredLevel))
    {
        if (client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Invalid level. Use -1 (Normal), 0 (Quieter), 1 (Quiet), 2 (Loud), or 3 (Louder).", VOICE_MANAGER_PREFIX);
        }
        else
        {
            PrintToServer("[VOICE MANAGER] Invalid level. Use -1 (Normal), 0 (Quieter), 1 (Quiet), 2 (Loud), or 3 (Louder).");
        }
        return Plugin_Handled;
    }

    int matches[MAXPLAYERS + 1];
    int matchCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i))
        {
            continue;
        }

        char name[64];
        GetClientName(i, name, sizeof(name));

        if (StrContains(name, targetArg, false) != -1)
        {
            if (!g_Cvar_AllowSelfOverride.BoolValue && client == i)
            {
                continue;
            }

            if (matchCount < MAXPLAYERS)
            {
                matches[matchCount++] = i;
            }
        }
    }

    if (matchCount == 0)
    {
        if (client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Could not find a player matching '%s'.", VOICE_MANAGER_PREFIX, targetArg);
        }
        else
        {
            PrintToServer("[VOICE MANAGER] Could not find a player matching '%s'.", targetArg);
        }
        return Plugin_Handled;
    }

    if (matchCount > 1)
    {
        if (client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Multiple players match '%s'. Please refine your search.", VOICE_MANAGER_PREFIX, targetArg);
        }
        else
        {
            PrintToServer("[VOICE MANAGER] Multiple players match '%s'. Please refine your search.", targetArg);
        }
        return Plugin_Handled;
    }

    int target = matches[0];

    if (!OnPlayerAdjustVolume(client, target, desiredLevel))
    {
        if (client > 0 && IsClientInGame(client))
        {
            CPrintToChat(client, "%s Failed to adjust %N's volume.", VOICE_MANAGER_PREFIX, target);
        }
        else
        {
            char name[64];
            GetClientName(target, name, sizeof(name));
            PrintToServer("[VOICE MANAGER] Failed to adjust %s's volume.", name);
        }
        return Plugin_Handled;
    }

    char targetSteam[STEAM_ID_BUF_SIZE];
    if (GetClientAuthId(target, AuthId_SteamID64, targetSteam, sizeof(targetSteam)))
    {
        UpdateOverrideEntry(client, targetSteam, desiredLevel);
    }

    char label[16];
    GetVolumeLabel(desiredLevel, label, sizeof(label));

    if (client > 0 && IsClientInGame(client))
    {
        CPrintToChat(client, "%s Set %N's volume to %s.", VOICE_MANAGER_PREFIX, target, label);
    }
    else
    {
        char name[64];
        GetClientName(target, name, sizeof(name));
        PrintToServer("[VOICE MANAGER] Set %s's volume to %s.", name, label);
    }

    return Plugin_Handled;
}
