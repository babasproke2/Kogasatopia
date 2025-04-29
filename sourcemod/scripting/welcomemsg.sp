#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <tf2_stocks>

#define MAX_INFO_LINES 7
#define MAX_CLASS_LINES 68
#define MAX_MESSAGE_LENGTH 256

public Plugin myinfo = 
{
    name = "Welcome & Info",
    author = "Hombre",
    description = "Server information plugin",
    version = "1.2.1",
    url = "https://tf2.gyate.net"
};

enum struct PlayerData {
    bool hasBeenWelcomed;
    TFClassType lastClass;
}

PlayerData g_PlayerData[MAXPLAYERS + 1];

char g_sClassNames[TFClassType][] = {
    "Unknown", 
    "Scout", 
    "Sniper", 
    "Soldier", 
    "Demoman", 
    "Medic", 
    "Heavy", 
    "Pyro", 
    "Spy", 
    "Engineer"
};

char g_sInfoMessages[MAX_INFO_LINES][MAX_MESSAGE_LENGTH] = {
    "\x07FF80C0This server improves the stats of some weapons; use !reverts to read about your class.",
    "\x07FFFF00Use !commands to read about other commands available.",
    "\x07DDA0DDSprays and other features like soundsprays are enabled.",
    "\x07EEE8A\nThe mapcycle becomes larger after 9PM EST.",
    "\x0787CEFAMelee random crits are enabled and random bullet spread is disabled;",
    "\x03Google 'Kogasatopia' to locate our website easily and check when people are playing.",
    "\x0780D0A0When do people play here? Usually after 9PM EST."
};

char g_sClassInfo[][MAX_MESSAGE_LENGTH] = {
    "\x03Back Scatter: +10% more accurate instead of -20% less",
    "\x03Baby Face's: Boost kept on damage taken",
    "\x0770C070Flying Guillotine: Deals +100% damage to stunned targets",
    "\x0770C070Crit-a-Cola: No mark for death visual, damage vuln. reduced to 25%",
    "\x0780D0A0The Sandman: stuns, 512 unit min range",
    "\x0780D0A0Candy Cane: +40% more health from medkits",
    "\x0780D0A0Fan-o-War: +20% deploy and holster speed",
    "\x03 ----- default weapons -----",
    "\x03Air Strike: +15% reload speed",
    "\x03Liberty Launcher: +10% firing speed",
    "\x0770C070Righteous Bison: Fires 60% faster, 50% less damage falloff",
    "\x0770C070Base Jumper: Can be redeployed mid-air",
    "\x0780D0A0Equalizer: -20% damage from ranged sources while active",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases",
    "\x07EEE8A [Secondary] The Family Business",
    "\x07EEE8A [Secondary] TF2C Twin Barrel: Reloads on holster, knockback on user and target",
    "\x07EEE8A [Melee] TF2C Harvester: Afterburn is returned as health while held, enemies are extinguished on your death",
    "\x03 ----- default weapons -----",
    "\x03Dragon's Fury: Airblast jump, original projectile size",
    "\x03Degreaser: +40% bonus to all switch speeds",
    "\x0770C070Detonator: Self damage penalty reduced from 50% to 25%",
    "\x0770C070Thermal Thruster: Re-launch while midair",
    "\x0780D0A0Axtinguisher: Crits burning targets",
    "\x03 ----- default weapons -----",
    "\x03Loch n' Load: Deals 110 damage",
    "\x03Booties: Provide speed even without a shield",
    "\x0770C070Sticky Jumper: Max stickies 3 -> 8",
    "\x0770C070Shields: Provide 65% blast jump damage resistance",
    "\x0780D0A0Caber: Explosion deals 125 damage, deals 175 damage while blast jumping",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Primary] Grenade Launcher (straight grenades)",
    "\x07EEE8A [Primary] Demoman Gunboats",
    "\x03 ----- default weapons -----",
    "\x03Huo Long Heater: No damage penalty",
    "\x0770C070Shotguns: +10% movement speed while held",
    "\x0780D0A0Gloves of Running: No health drain, marks for death",
    "\x0780D0A0Eviction Notice: No health drain, fires 60% faster instead of 40%",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Primary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases",
    "\x07EEE8A [Primary] The Family Business",
    "\x07EEE8A [Secondary] The Winger",
    "\x07EEE8A [Secondary] Pretty Boy's Pocket Pistol",    
    "\x07EEE8A [PDA1] Boost/Jump pads (Or use !pads for convenience)",
    "\x03 ----- default weapons -----",
    "\x03Pomson: Penetrates targets, +20% firing rate",
    "\x0780D0A0Southern Hospitality: +10% damage, +100% dispenser range",
    "\x03 ----- default weapons -----",
    "\x03Syringe guns provide +1.25% uber on hit, reload on holster",
    "\x0780D0A0The Vita-Saw: Retain up to 20% uber after death regardless of organs", 
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Melee] TF2C Shock Therapy: Hit an ally at full charge to fully overheal them, recharge time is 30s, enemies take charge as damage, -15% healing",
    "\x03The Huntsman: +15hp on wearer, enables melee wall climbing",
    "\x03The Classic: +15% charge rate",
    "\x0770C070The Cleaner's Carbine: Critboost on kill (2s)",
    "\x0780D0A0The Tribalman's Shiv: -25% damage instead of -50% damage",
    "\x03 ----- default weapons -----",
    "\x03The Ambassador: Headshots deal 102 damage",
    "\x03The Enforcer: +10% damage, no firing rate penalty, +33% cloak drain increase, +0.5s time to cloak",
    "\x03The Big Earner: +5hp",
    "\x0780D0A0Your Eternal Reward: 0% cloak drain penalty, +20% swing speed",
    "\x07EEE8A ----- !cwx weapons -----",
    "\x07EEE8A [Building] TF2C L'escampette: Move 30% faster while cloaked, 50% less cloak, 10% cloak lost on hit"
};

public Plugin myinfo = {
    name = "Welcome Message",
    author = "bahombr",
    description = "Displays welcome messages and server information",
    version = "1.1",
    url = "https://gyate.net"
};

public void OnPluginStart() {
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    
    LoadTranslations("welcomemsg.phrases.txt");
    
    RegConsoleCmd("sm_info", Command_ListInfo, "Displays a brief message about the server");
    RegConsoleCmd("sm_c", Command_InfoC, "Lists custom class weapon data");
    RegConsoleCmd("sm_reverts", Command_InfoC, "Lists custom class weapon data");
    RegConsoleCmd("sm_cmds", Command_Commands, "Lists server commands");
    RegConsoleCmd("sm_commands", Command_Commands, "Lists server commands");
    RegConsoleCmd("sm_rules", Command_Rules, "Lists server rules");
    RegConsoleCmd("sm_steam", Command_Steam, "Prints steam group URL");
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }
}

public void OnClientPutInServer(int client) {
    g_PlayerData[client].hasBeenWelcomed = false;
    g_PlayerData[client].lastClass = TFClass_Unknown;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        CreateTimer(20.0, Timer_WelcomePlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        g_PlayerData[client].lastClass = TF2_GetPlayerClass(client);
    }
}

public Action Timer_WelcomePlayer(Handle timer, int userid) {
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client) && !g_PlayerData[client].hasBeenWelcomed) {
        g_PlayerData[client].hasBeenWelcomed = true;
        PrintToChat(client, "\x03Welcome to Kogasatopia %N! \nThis server improves the stats of some weapons; \nRead more at tf2.gyate.net or use: \x0787CEFA!info\n\x07EEE8A New feature: join our steam group at \x03!steam", client);
    }
    return Plugin_Continue;
}

public Action Command_Commands(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    char commands[256] = "\x03Server Commands:\x07EEE8A \nVoting: !rtv !nominate !scramble !nextmap \nServer: !reverts !steam !info !rules \nGameplay: !cwx !center !pads !bots !togglehat\nQuirky: !hug !rape !thirdperson !firstperson";
    PrintToChat(client, commands);
    return Plugin_Handled;
}

public Action Command_Rules(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    char rules[128] = "\x03Server Rules: \n\x07EEE8A No Hacking/Friendlies \nNo Pronoun Names/Disgusting Sprays";
    PrintToChat(client, rules);
    return Plugin_Handled;
}

public Action Command_Steam(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    char steam[64] = "\x03Steam Group: \x07EEE8A tf2.gyate.net/steam";
    PrintToChat(client, steam);
    return Plugin_Handled;
}

public Action Command_ListInfo(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    for (int i = 0; i < MAX_INFO_LINES; i++) {
        PrintToChat(client, g_sInfoMessages[i]);
    }
    return Plugin_Handled;
}

public Action Command_InfoC(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    g_PlayerData[client].lastClass = TF2_GetPlayerClass(client);
    TFClassType class = g_PlayerData[client].lastClass;
    
    int start = -1, end = -1;
    
    switch (class) {
        case TFClass_Scout: { start = 0; end = 6; }
        case TFClass_Soldier: { start = 7; end = 14; }
        case TFClass_Pyro: { start = 15; end = 25; }
        case TFClass_DemoMan: { start = 26; end = 34; }
        case TFClass_Heavy: { start = 35; end = 41; }
        case TFClass_Engineer: { start = 42; end = 50; }
        case TFClass_Medic: { start = 51; end = 55; }
        case TFClass_Sniper: { start = 56; end = 59; }
        case TFClass_Spy: { start = 60; end = 67; }
        default: {
            PrintToChat(client, "\x03No class-specific information available.");
            return Plugin_Handled;
        }
    }
    
    for (int i = start; i <= end; i++) {
        PrintToChat(client, "%s", g_sClassInfo[i]);
    }
    
    return Plugin_Handled;
}

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}
