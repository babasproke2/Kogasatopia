#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <basecomm>
#include <morecolors>

#pragma semicolon 1
#pragma newdecls required

#define MAX_FILTERS 128
#define MAX_BLACKLIST 128
#define MAX_WORD_LENGTH 64
#define MAX_FORCED_STATUS 128
#define MAX_COMMANDS 64

// Player state structure
enum struct PlayerState
{
    bool isWhitelisted;        // Player bypasses all filters and blacklist
    bool isFilterWhitelisted;  // Player bypasses word filters only
    bool isBlacklisted;        // Player cannot send any messages
}

PlayerState g_PlayerState[MAXPLAYERS + 1];

// Cookie handles
Handle g_hCookieWhitelist;
Handle g_hCookieFilterWhitelist;
Handle g_hCookieBlacklist;

// Truthtext handles
Handle g_sEnabled = INVALID_HANDLE;
Handle g_sChatMode2 = INVALID_HANDLE;

// Global arrays for word filtering
char g_FilterWords[MAX_FILTERS][MAX_WORD_LENGTH];
char g_ReplacementWords[MAX_FILTERS][MAX_WORD_LENGTH];
int g_FilterCount = 0;

// Global array for blacklisted words
char g_BlacklistWords[MAX_BLACKLIST][MAX_WORD_LENGTH];
int g_BlacklistCount = 0;

// Global arrays for forced status
char g_ForcedStatusSteamIDs[MAX_FORCED_STATUS][32];
char g_ForcedStatusTypes[MAX_FORCED_STATUS][32]; // "whitelist", "blacklist", or "filter_whitelist"
int g_ForcedStatusCount = 0;

// Global array for whitelisted/immunue commands
char g_AllowedCommands[MAX_COMMANDS][MAX_WORD_LENGTH];
int g_AllowedCommandsCount = 0;

public Plugin myinfo = 
{
    name = "Chat Manager",
    author = "Hombre",
    description = "Chat Management + Filtered/Blacklisted Words",
    version = "1.0.0",
    url = "https://kogasa.tf"
};

public void OnPluginStart()
{
    LoadFilterConfig();

    // Truthtext Convars
    g_sEnabled = CreateConVar("nobroly", "1", "If 0, filter chat to one word");
    g_sChatMode2 = CreateConVar("filtermode", "0", "Enable/Disable the quarantined filter mode");
    
    // Initialize cookies
    g_hCookieWhitelist = RegClientCookie("filter_whitelist", "Player is whitelisted from all filters", CookieAccess_Protected);
    g_hCookieFilterWhitelist = RegClientCookie("filter_filterwhitelist", "Player is whitelisted from word filters only", CookieAccess_Protected);
    g_hCookieBlacklist = RegClientCookie("filter_blacklist", "Player is blacklisted from sending messages", CookieAccess_Protected);
    
    // Register admin commands for managing player states
    RegAdminCmd("sm_whitelist", Command_Whitelist, ADMFLAG_CHAT, "sm_whitelist <player> - Whitelists a player from all filters");
    RegAdminCmd("sm_unwhitelist", Command_UnWhitelist, ADMFLAG_CHAT, "sm_unwhitelist <player> - Removes whitelist from a player");
    
    RegAdminCmd("sm_filterwhitelist", Command_FilterWhitelist, ADMFLAG_CHAT, "sm_filterwhitelist <player> - Whitelists a player from word filters only");
    RegAdminCmd("sm_unfilterwhitelist", Command_UnFilterWhitelist, ADMFLAG_CHAT, "sm_unfilterwhitelist <player> - Removes filter whitelist from a player");
    
    RegAdminCmd("sm_blacklist", Command_Blacklist, ADMFLAG_CHAT, "sm_blacklist <player> - Blacklists a player from sending messages");
    RegAdminCmd("sm_unblacklist", Command_UnBlacklist, ADMFLAG_CHAT, "sm_unblacklist <player> - Removes blacklist from a player");
}

enum struct ChatContext
{
    bool pluginEnabled;
    bool cordMode;
    bool isBlacklisted;
    bool isWhitelisted;
    bool isFilterWhitelisted;
    bool hasBlacklistedTerm;
    bool isGagged;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (!client) 
        return Plugin_Continue;

    char dead[64];
    BuildDeathPrefix(client, dead, sizeof(dead));

    if (CheckCommands(sArgs))
    {
        PrintToServer("%s", sArgs);
        return Plugin_Continue;
    }

    if (TryHandleTeamChat(client, command, sArgs, dead))
    {
        return Plugin_Stop;
    }

    ChatContext context;
    BuildChatContext(client, sArgs, context);

    char output[256];
    Format(output, sizeof(output), "{default}%s{teamcolor}%N{default}: %s", dead, client, sArgs);

    ApplyFiltersIfNeeded(output, sizeof(output), context);

    if (HandleCordModeBlacklistedChat(client, output, context))
    {
        return Plugin_Stop;
    }

    if (HandleRestrictedMessage(client, output, context))
    {
        return Plugin_Stop;
    }

    if (HandleEnabledChat(client, output, context))
    {
        return Plugin_Stop;
    }

    SendFallbackMessage(client);
    return Plugin_Stop;
}

void BuildChatContext(int client, const char[] sArgs, ChatContext context)
{
    context.pluginEnabled = GetConVarInt(g_sEnabled) != 0;
    context.cordMode = GetConVarInt(g_sChatMode2) != 0;
    context.isBlacklisted = g_PlayerState[client].isBlacklisted;
    context.isWhitelisted = g_PlayerState[client].isWhitelisted;
    context.isFilterWhitelisted = g_PlayerState[client].isFilterWhitelisted;
    context.hasBlacklistedTerm = CheckBlacklistedTerms(sArgs);
    context.isGagged = BaseComm_IsClientGagged(client);
}

void BuildDeathPrefix(int client, char[] deadPrefix, int length)
{
    if (!IsPlayerAlive(client))
    {
        Format(deadPrefix, length, "*負け犬* ");
        return;
    }

    deadPrefix[0] = '\0';
}

bool TryHandleTeamChat(int client, const char[] command, const char[] sArgs, const char[] deadPrefix)
{
    if (!StrEqual(command, "say_team"))
    {
        return false;
    }

    char tag[16];
    BuildTeamTag(GetClientTeam(client), tag, sizeof(tag));

    char output[256];
    Format(output, sizeof(output), "{default}%s%s {teamcolor}%N{default}: %s", deadPrefix, tag, client, sArgs);
    CPrintToChatTeam(GetClientTeam(client), output);
    PrintToServer("%s", output);
    return true;
}

void BuildTeamTag(int team, char[] tag, int length)
{
    switch (team)
    {
        case 3: strcopy(tag, length, "(輝夜)");
        case 2: strcopy(tag, length, "(妹紅)");
        default: strcopy(tag, length, "(永琳)");
    }
}

void ApplyFiltersIfNeeded(char[] message, int maxlen, const ChatContext context)
{
    if (context.isFilterWhitelisted)
    {
        return;
    }

    FilterString(message, maxlen);
}

bool HandleCordModeBlacklistedChat(int client, const char[] message, const ChatContext context)
{
    if (!context.isBlacklisted || !context.cordMode)
    {
        return false;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && g_PlayerState[i].isBlacklisted)
        {
            CPrintToChatEx(i, client, "%s", message);
        }
    }

    SendToWhitelistedAdmins(client, message, "x:");
    PrintToServer("x: %s", message);
    return true;
}

bool HandleRestrictedMessage(int client, const char[] message, const ChatContext context)
{
    if ((context.hasBlacklistedTerm && !context.isWhitelisted) || context.isGagged)
    {
        CPrintToChatEx(client, client, "%s", message);
        PrintToServer("x: %s", message);
        SendToWhitelistedAdmins(client, message, "x:");
        return true;
    }

    return false;
}

bool HandleEnabledChat(int client, const char[] message, const ChatContext context)
{
    if (!context.pluginEnabled)
    {
        return false;
    }

    if (!context.cordMode)
    {
        CPrintToChatAllEx(client, "%s", message);
    }
    else
    {
        int randomChance = GetRandomInt(1, 20);
        if (randomChance == 1)
        {
            CPrintToChatAll(message);
        }
        else
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (IsClientInGame(i) && !g_PlayerState[i].isBlacklisted)
                {
                    CPrintToChatEx(i, client, "%s", message);
                }
            }
        }
    }

    PrintToServer("%s", message);
    return true;
}

void SendFallbackMessage(int client)
{
    char output[256];
    Format(output, sizeof(output), "{teamcolor}%N{default}: {greenyellow}BROLY", client);
    CPrintToChatAllEx(client, "%s", output);
}

// Helper function to send message to whitelisted admins
void SendToWhitelistedAdmins(int sender, const char[] message, const char[] prefix = "")
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
            continue;
            
        if (g_PlayerState[i].isWhitelisted)
        {
            if (prefix[0] != '\0')
                CPrintToChatEx(i, sender, "%s %s", prefix, message);
            else
                CPrintToChatEx(i, sender, "%s", message);
        }
    }
}

void LoadFilterConfig()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configPath, sizeof(configPath), "configs/filters.cfg");
    
    if (!FileExists(configPath))
    {
        LogMessage("Config file not found, creating default: %s", configPath);
        CreateDefaultConfig(configPath);
    }
    
    KeyValues kv = new KeyValues("filters");
    
    if (!kv.ImportFromFile(configPath))
    {
        LogError("Failed to parse config file: %s", configPath);
        delete kv;
        SetFailState("Failed to parse filters.cfg");
        return;
    }
    
    // Reset counts
    g_FilterCount = 0;
    g_BlacklistCount = 0;
    g_ForcedStatusCount = 0;
    g_AllowedCommandsCount = 0;
    
    // Load filter_words section
    if (kv.JumpToKey("filter_words"))
    {
        if (kv.GotoFirstSubKey(false)) // false = values, not sections
        {
            do
            {
                if (g_FilterCount >= MAX_FILTERS)
                {
                    LogError("Maximum filter limit reached (%d)", MAX_FILTERS);
                    break;
                }
                
                char original[MAX_WORD_LENGTH];
                char filtered[MAX_WORD_LENGTH];
                
                kv.GetSectionName(original, sizeof(original));
                kv.GetString(NULL_STRING, filtered, sizeof(filtered));
                
                strcopy(g_FilterWords[g_FilterCount], MAX_WORD_LENGTH, original);
                strcopy(g_ReplacementWords[g_FilterCount], MAX_WORD_LENGTH, filtered);
                
                g_FilterCount++;
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load blacklist_words section
    if (kv.JumpToKey("blacklist_words"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_BlacklistCount >= MAX_BLACKLIST)
                {
                    LogError("Maximum blacklist limit reached (%d)", MAX_BLACKLIST);
                    break;
                }
                
                char word[MAX_WORD_LENGTH];
                kv.GetSectionName(word, sizeof(word));
                
                strcopy(g_BlacklistWords[g_BlacklistCount], MAX_WORD_LENGTH, word);
                
                g_BlacklistCount++;
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load force_status section
    if (kv.JumpToKey("force_status"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_ForcedStatusCount >= MAX_FORCED_STATUS)
                {
                    LogError("Maximum forced status limit reached (%d)", MAX_FORCED_STATUS);
                    break;
                }
                
                char steamid[32];
                char status[32];
                
                kv.GetSectionName(steamid, sizeof(steamid));
                kv.GetString(NULL_STRING, status, sizeof(status));
                
                // Validate status type
                if (StrEqual(status, "whitelist") || StrEqual(status, "blacklist") || StrEqual(status, "filter_whitelist"))
                {
                    strcopy(g_ForcedStatusSteamIDs[g_ForcedStatusCount], 32, steamid);
                    strcopy(g_ForcedStatusTypes[g_ForcedStatusCount], 32, status);
                    g_ForcedStatusCount++;
                }
                else
                {
                    LogError("Invalid status type '%s' for SteamID '%s'", status, steamid);
                }
            }
            while (kv.GotoNextKey(false));
            
            kv.GoBack();
        }
        kv.GoBack();
    }
    
    // Load commands section
    if (kv.JumpToKey("commands"))
    {
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                if (g_AllowedCommandsCount >= MAX_COMMANDS)
                {
                    LogError("Maximum commands limit reached (%d)", MAX_COMMANDS);
                    break;
                }
                
                char command[MAX_WORD_LENGTH];
                kv.GetSectionName(command, sizeof(command));
                
                strcopy(g_AllowedCommands[g_AllowedCommandsCount], MAX_WORD_LENGTH, command);
                
                g_AllowedCommandsCount++;
            }
            while (kv.GotoNextKey(false));
        }
    }
    
    delete kv;
    
    PrintToServer("[Word Filter] Loaded %d filter words, %d blacklist words, %d forced status entries, and %d commands", 
                  g_FilterCount, g_BlacklistCount, g_ForcedStatusCount, g_AllowedCommandsCount);
}

// Example usage function - filters a string
public void FilterString(char[] input, int maxlen)
{
    // Apply word filters
    for (int i = 0; i < g_FilterCount; i++)
    {
        ReplaceString(input, maxlen, g_FilterWords[i], g_ReplacementWords[i], false);
    }
}

// Example usage function - checks if string contains blacklisted word
public bool ContainsBlacklistedWord(const char[] input)
{
    char lowerInput[256];
    strcopy(lowerInput, sizeof(lowerInput), input);
    StringToLower(lowerInput);
    
    for (int i = 0; i < g_BlacklistCount; i++)
    {
        char lowerBlacklist[MAX_WORD_LENGTH];
        strcopy(lowerBlacklist, sizeof(lowerBlacklist), g_BlacklistWords[i]);
        StringToLower(lowerBlacklist);
        
        if (StrContains(lowerInput, lowerBlacklist) != -1)
        {
            return true;
        }
    }
    
    return false;
}

// Helper function to convert string to lowercase
void StringToLower(char[] input)
{
    int len = strlen(input);
    for (int i = 0; i < len; i++)
    {
        input[i] = CharToLower(input[i]);
    }
}

// Creates default config file
void CreateDefaultConfig(const char[] path)
{
    File file = OpenFile(path, "w");
    
    if (file == null)
    {
        LogError("Failed to create config file: %s", path);
        SetFailState("Could not create filters.cfg");
        return;
    }
    
    // Write default config structure
    file.WriteLine("\"filters\"");
    file.WriteLine("{");
    file.WriteLine("    \"filter_words\"");
    file.WriteLine("    {");
    file.WriteLine("        \"badword1\"    \"filtered\"");
    file.WriteLine("        \"badword2\"    \"filtered\"");
    file.WriteLine("    }");
    file.WriteLine("    \"blacklist_words\"");
    file.WriteLine("    {");
    file.WriteLine("        \"blockedword1\"    \"\"");
    file.WriteLine("        \"blockedword2\"    \"\"");
    file.WriteLine("        \"blockedword3\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("    \"force_status\"");
    file.WriteLine("    {");
    file.WriteLine("        \"STEAM_0:0:12345678\"    \"whitelist\"");
    file.WriteLine("        \"STEAM_0:1:87654321\"    \"blacklist\"");
    file.WriteLine("        \"STEAM_0:0:11223344\"    \"filter_whitelist\"");
    file.WriteLine("    }");
    file.WriteLine("    \"commands\"");
    file.WriteLine("    {");
    file.WriteLine("        \"rtv\"    \"\"");
    file.WriteLine("        \"nominate\"    \"\"");
    file.WriteLine("        \"nextmap\"    \"\"");
    file.WriteLine("        \"motd\"    \"\"");
    file.WriteLine("    }");
    file.WriteLine("}");
    
    delete file;
    
    LogMessage("Default config file created: %s", path);
}

// Process client cookies on connect/cache
void ProcessCookies(int client)
{
    char cookie[32];
    
    // Check if client has forced status from config
    char steamid[32];
    if (GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        for (int i = 0; i < g_ForcedStatusCount; i++)
        {
            if (StrEqual(steamid, g_ForcedStatusSteamIDs[i]))
            {
                if (StrEqual(g_ForcedStatusTypes[i], "whitelist"))
                {
                    PrintToServer("[FILTERS] %N is force whitelisted (from config)", client);
                    g_PlayerState[client].isWhitelisted = true;
                    return; // Skip cookie processing for forced status
                }
                else if (StrEqual(g_ForcedStatusTypes[i], "blacklist"))
                {
                    PrintToServer("[FILTERS] %N is force blacklisted (from config)", client);
                    g_PlayerState[client].isBlacklisted = true;
                    return;
                }
                else if (StrEqual(g_ForcedStatusTypes[i], "filter_whitelist"))
                {
                    PrintToServer("[FILTERS] %N is force filter whitelisted (from config)", client);
                    g_PlayerState[client].isFilterWhitelisted = true;
                    return;
                }
            }
        }
    }
    
    // Process cookies normally if no forced status
    GetClientCookie(client, g_hCookieWhitelist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is whitelisted", client);
        g_PlayerState[client].isWhitelisted = true;
    }
    else
    {
        g_PlayerState[client].isWhitelisted = false;
    }
    
    GetClientCookie(client, g_hCookieFilterWhitelist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is filter whitelisted", client);
        g_PlayerState[client].isFilterWhitelisted = true;
    }
    else
    {
        g_PlayerState[client].isFilterWhitelisted = false;
    }
    
    GetClientCookie(client, g_hCookieBlacklist, cookie, sizeof(cookie));
    if (StrEqual(cookie, "1"))
    {
        PrintToServer("[FILTERS] %N is blacklisted", client);
        g_PlayerState[client].isBlacklisted = true;
    }
    else
    {
        g_PlayerState[client].isBlacklisted = false;
    }
}

public void OnClientPostAdminCheck(int client)
{
    if (AreClientCookiesCached(client))
    {
        ProcessCookies(client);
    }
}

public void OnClientCookiesCached(int client)
{
    ProcessCookies(client);
}

// ==================== WHITELIST COMMANDS ====================

public Action Command_Whitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_whitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed whitelist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = true;
    SetClientCookie(target, g_hCookieWhitelist, "1");
    LogAction(client, target, "\"%L\" whitelisted \"%L\"", client, target);
}

void PerformUnWhitelist(int client, int target)
{
    g_PlayerState[target].isWhitelisted = false;
    SetClientCookie(target, g_hCookieWhitelist, "0");
    LogAction(client, target, "\"%L\" removed whitelist from \"%L\"", client, target);
}

// ==================== FILTER WHITELIST COMMANDS ====================

public Action Command_FilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_filterwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformFilterWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Filter whitelisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Filter whitelisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnFilterWhitelist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unfilterwhitelist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnFilterWhitelist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed filter whitelist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed filter whitelist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformFilterWhitelist(int client, int target)
{
    g_PlayerState[target].isFilterWhitelisted = true;
    SetClientCookie(target, g_hCookieFilterWhitelist, "1");
    LogAction(client, target, "\"%L\" filter whitelisted \"%L\"", client, target);
}

void PerformUnFilterWhitelist(int client, int target)
{
    g_PlayerState[target].isFilterWhitelisted = false;
    SetClientCookie(target, g_hCookieFilterWhitelist, "0");
    LogAction(client, target, "\"%L\" removed filter whitelist from \"%L\"", client, target);
}

// ==================== BLACKLIST COMMANDS ====================

public Action Command_Blacklist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_blacklist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformBlacklist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Blacklisted %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Blacklisted %s", target_name);
    }
    
    return Plugin_Handled;
}

public Action Command_UnBlacklist(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Kogasa] Usage: sm_unblacklist <player>");
        return Plugin_Handled;
    }
    
    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));
    
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;
    
    if ((target_count = ProcessTargetString(
            arg,
            client,
            target_list,
            MAXPLAYERS,
            0,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }
    
    for (int i = 0; i < target_count; i++)
    {
        int target = target_list[i];
        PerformUnBlacklist(client, target);
    }
    
    if (tn_is_ml)
    {
        ShowActivity2(client, "[Kogasa] ", "Removed blacklist from %s", target_name);
    }
    else
    {
        ShowActivity2(client, "[Kogasa] ", "Removed blacklist from %s", target_name);
    }
    
    return Plugin_Handled;
}

void PerformBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = true;
    SetClientCookie(target, g_hCookieBlacklist, "1");
    LogAction(client, target, "\"%L\" blacklisted \"%L\"", client, target);
}

void PerformUnBlacklist(int client, int target)
{
    g_PlayerState[target].isBlacklisted = false;
    SetClientCookie(target, g_hCookieBlacklist, "0");
    LogAction(client, target, "\"%L\" removed blacklist from \"%L\"", client, target);
}

void CPrintToChatTeam(int team, const char[] message)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && GetClientTeam(client) == team)
        {
            CPrintToChatEx(client, client, "%s", message);
        }
    }
}

bool CheckCommands(const char[] sArgs)
{
    // Allow any message starting with !
    if (strncmp(sArgs, "!", 1) == 0) {
        return true;
    }
    
    // Allow any message containing %
    if (StrContains(sArgs, "%", false) != -1) {
        return true;
    }
    
    // Check against allowed commands list from config
    for (int i = 0; i < g_AllowedCommandsCount; i++) {
        if (StrEqual(sArgs, g_AllowedCommands[i], false)) {
            return true;
        }
    }
    return false;
}

bool CheckBlacklistedTerms(const char[] sArgs)
{
    for (int i = 0; i < MAX_BLACKLIST; i++)
    {
        // skip empty entries
        if (g_BlacklistWords[i][0] == '\0')
            continue;

        if (StrContains(sArgs, g_BlacklistWords[i], false) != -1)
        {
            PrintToServer("Blacklisted term: %s", g_BlacklistWords[i]);
            return true;
        }
    }
    return false;
}
