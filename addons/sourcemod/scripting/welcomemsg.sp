#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>

bool g_HasBeenWelcomed[MAXPLAYERS + 1];

static const char g_Info[][] = {
    "{peachpuff}Some weapons have better stats; use {yellow}!r {peachpuff}to read about your class.\n",
    "{peachpuff}We're also testing custom weapons; check {yellow}!c {peachpuff}to read and {yellow}!cw {peachpuff}to equip.\n",
    "{peachpuff}Use {yellow}!commands {peachpuff}to browse the rest of the server commands.\n",
    "{peachpuff}Melee random crits are enabled, respawn times are reduced, and random bullet spread is disabled.\n",
    "{peachpuff}Google 'kogtf2' or visit our group with {yellow}!steam {peachpuff}to learn more and see when people are playing.\n"
};

static const char g_ScoutReverts[][] = {
    "{default}Back Scatter:{green} +10% more accurate instead of -20% less\n",
    "{default}Baby Face's:{chartreuse} Boost kept on damage taken, -20% base movement speed\n",
    "{default}The Shortstop:{green} +25% reload speed, +20% healing received, +80% damage force taken\n",
    "{default}Flying Guillotine:{chartreuse} Deals +100% damage to stunned targets\n",
    "{default}Crit-a-Cola:{green} No mark for death visual, damage vuln. reduced to 25%\n",
    "{default}The Sandman:{chartreuse} stuns, 512 unit min range\n",
    "{default}Candy Cane:{green} +40% more health from medkits\n",
    "{default}Fan-o-War:{chartreuse} +20% deploy and holster speed\n"
};

static const char g_ScoutCustom[][] = {
    "\x01 [Primary] Original Baby Face: {lightgreen}+40% accuracy, 6 clip size,\x07FF0000 -30% damage, -35% base movement speed, boost resets on any jump\n",
    "\x01 [Secondary] Lightning Pistol: {lightgreen}+35% firing rate, +200% clip size, 40% more accurate, +100% ammo,\x07FF0000 -40% damage, -15% reload speed\n"
};

static const char g_SoldierReverts[][] = {
    "{default}Air Strike:{green} +15% reload speed\n",
    "{default}Liberty Launcher:{chartreuse} +10% firing speed\n",
    "{default}Righteous Bison:{green} Fires 55% faster, bonus damage up to +100% based on distance,\x07FF0000 -40% damage\n",
    "{default}Base Jumper:{chartreuse} Re-deploy, float upwards while on fire\n",
    "{default}Equalizer:{green} -20% damage from ranged sources while active\n",
};

static const char g_SoldierCustom[][] = {
    "\x01[Secondary] The F.U.T.A.: {lightgreen}+30% blast jump damage resistance, +15% tighter spread,\x07FF0000 -50% clip size\n",
    "\x01[Secondary] Old Panic Attack: {lightgreen}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] Soldier's Pistol\n"
};

static const char g_PyroReverts[][] = {
    "{default}Dragon's Fury:{green} Airblast jump\n",
    "{default}Degreaser:{chartreuse} +35% bonus to all switch speeds\n",
    "{default}Detonator:{green} Self damage penalty reduced from 50% to 25%\n",
    "{default}Thermal Thruster:{chartreuse} Re-launch while midair\n",
    "{default}Gas Passer:{green} Gas applies jarate for 6s\n",
    "{default}Axtinguisher: {chartreuse} Crits burning targets, 50% less damage to non-burning targets\n",
    "{default}Volcano Fragment: {green} Mini-crits burning targets\n"
};

static const char g_PyroCustom[][] = {
    "\x01[Primary] Stock Shotgun\n",
    "\x01[Secondary] TF2C Twin Barrel: {lightgreen}Holster reload, +20% bullets per shot, first shot is a recoil jump,\x07FF2400 10% wider spread, 15% slower draw speed\n",
    "\x01[Secondary] Old Panic Attack: {lightgreen}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] The Family Business\n",
    "\x01[Melee] TF2C Harvester: {lightgreen}Afterburn is returned as health while held,\x07FF2400 enemies are extinguished on your death\n"
};

static const char g_DemoReverts[][] = {
    "\x01Booties:\x04 Provide speed even without a shield\n",
    "\x01Base Jumper:{lightgreen} Re-deploy, float upwards while on fire\n",
    "\x01Sticky Jumper:\x04 Max stickies 3 -> 8\n",
    "\x01Scottish Resistance:{lightgreen} Arm time 0.8 -> 0.4\n",
    "\x01Shields:\x04 Provide 65% blast jump damage resistance,\x07FF2400 all resistances are changed to 10%\n",
    "\x01Caber:{lightgreen} Explosion deals 125 damage, deals 175 damage while blast jumping\n",
    "\x01Scottish Handshake:\x04 Market gardener stats\n",
};

static const char g_DemoCustom[][] = {
    "\x01[Primary] Grenade Launcher (straight grenades)\n",
    "\x01[Primary] Demoman Gunboats\n",
    "\x01[Secondary] Demoman Banana: {lightgreen}Throw and eat to heal yourself!\n"
};

static const char g_HeavyReverts[][] = {
    "\x01Huo Long Heater:\x04 No damage penalty\n",
    "\x01Shotguns:{lightgreen} +10% movement speed while held\n",
    "\x01Gloves of Running:\x04 No health drain, marks for death\n",
    "\x01Eviction Notice:{lightgreen} No health drain, fires 60% faster instead of 40%\n",
    "\x01Warrior's Spirit:{lightgreen} No active dmg. vuln, +20 health on hit,\x07FF2400 no health on kill, -20 max health\n"
};

static const char g_HeavyCustom[][] = {
    "\x01[Secondary] Old Panic Attack: {lightgreen}Hold fire to load up to 4 shells, fires faster as HP decreases\n"
};

static const char g_EngineerReverts[][] = {
    "\x01Pomson:\x04 Penetrates targets, +20% firing rate, bonus damage up to +100% based on distance\n",
    "\x01The Wrangler:\x07FF2400 Shield resistance 66% -> 25%\n",
    "\x01The Short Circuit:\x07FF2400 No ammo from dispensers/carts while held\n",
    "\x01Southern Hospitality:{lightgreen} +10% damage, 15 metal regenerated every 5 seconds on wearer\n"
};

static const char g_EngineerCustom[][] = {
    "\x01[Primary] The Family Business\n",
    "\x01[Primary] Old Panic Attack: {lightgreen}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] Conagher's Bull: Drain 25 metal on hit, first shot deals 300 damage to enemies holding the same weapon, 80% tighter spread\n",
    "\x01[Secondary] Lightning Pistol: {lightgreen}+35% firing rate, +200% clip size, 40% more accurate, +100% ammo,\x07FF0000 -40% damage, -15% reload speed\n",
    "\x01[Secondary] The Winger, Pretty Boy's Pocket Pistol\n",
    "\x01[PDA1] Boost/Jump pads (Or use !pads for convenience)\n",
    "\x01[PDA2] Amplifier Dispenser Replacement (Or use !amp or !a)\n"
};

static const char g_MedicReverts[][] = {
    "\x01Syringe guns:\x04 +1.25% uber on hit, reload on holster\n",
    "\x01The Vita-Saw:{lightgreen} Retain up to 20% uber after death regardless of organs, wall climbing\n",
    "\x01The Vaccinator:\x07FF2400 +20% damage taken while held\n"
};

static const char g_MedicCustom[][] = {
    "\x01[Melee] TF2C Shock Therapy: {lightgreen}Hit allies to fully overheal them, {unique} enemies take charge as damage,\x07FF2400 30s recharge time, -15% healing on medigun\n",
    "\x01[Melee] The Mantreads"
};

static const char g_SniperReverts[][] = {
    "\x01The Huntsman:\x04 +15hp on wearer, enables melee wall climbing\n",
    "\x01The Classic:{lightgreen} +20% charge rate\n",
    "\x01The Cozy Camper:\x04 No aim flinch at any charge\n",
    "\x01The Cleaner's Carbine:{lightgreen} Critboost on kill (3s)\n",
    "\x01The Tribalman's Shiv\x04 -25% damage instead of -50% damage\n"
};

static const char g_SniperCustom[][] = {
    "\x01 No custom weapons detected for your class!"
};

static const char g_SpyReverts[][] = {
    "\x01The Ambassador:\x04 Headshots deal 102 damage\n",
    "\x01The Enforcer:{lightgreen} 50% less bullet spread, +20% damage, no disguise bonus\n",
    "\x01The Big Earner:\x04 +5hp\n",
    "\x01Your Eternal Reward:{lightgreen} 0% cloak drain penalty, +10% swing speed\n"
};

static const char g_SpyCustom[][] = {
    "\x01[Secondary] Enforcer (Alt): {lightgreen}No fire rate penalty, +10% damage,\x07FF2400 -25% damage while disguised, +0.5s time to cloak\n",
    "\x01[Secondary] Wall Climbing Kit: {lightgreen}+15 hp, enables wall climb,\x07FF2400 +25% damage taken from fire, +20% damage taken from explosives\n",
    "\x07FFFF00This class has additional weapons; check !c2 to read the second page."
};

static const char g_SpyCustom2[][] = {
    "{unique} ----- !cw weapons (2) -----\n",
    "\x01 [Building] The Surfboard: {lightgreen}-60% damage taken from sentries, \x07FF2400 60% less sapper damage\n",
    "\x01 [PDA] TF2C L'escampette: {lightgreen}Move 30% faster while cloaked,\x07FF2400 50% less cloak, 10% cloak lost on hit, no pickups while cloaked\n"
};

public Plugin:myinfo = {
    name = "Welcome Message",
    author = "Hombre",
    description = "Welcome message & server info plugin for Kogasatopia, very specific",
    version = "2.00",
    url = "https://kogasa.tf"
};

public OnPluginStart()
{
    HookEvent("player_spawn", Event_PlayerSpawn);
    LoadTranslations("welcomemsg.phrases.txt");
    
    RegConsoleCmd("sm_info", Command_ListInfo, "Displays an brief message to the client about the server.");
    RegConsoleCmd("sm_c", Command_InfoC, "Lists custom class weapon data to the client");
    RegConsoleCmd("sm_c2", Command_InfoC2, "Lists custom class weapon page 2 data to the client");
    RegConsoleCmd("sm_reverts", Command_InfoReverts, "Lists custom class weapon data to the client");
    RegConsoleCmd("sm_revert", Command_InfoReverts, "Lists custom class weapon data to the client");
    RegConsoleCmd("sm_r", Command_InfoReverts, "Lists custom class weapon data to the client");
    RegConsoleCmd("sm_cmds", Command_cmds, "Lists highlighted server commands to the client");
    RegConsoleCmd("sm_commands", Command_cmds, "Lists highlighted server commands to the client");
    RegConsoleCmd("sm_rules", Command_Rules, "Lists the rules to the client");
    RegConsoleCmd("sm_steam", Command_Steam, "Prints the steam group URL to the client");
    RegConsoleCmd("sm_chat", Command_chat, "Steam chat link");
    
    // Panel versions of weapon info
    RegConsoleCmd("sm_rp", Command_RevertsPanel, "Shows weapon changes in a panel");
    RegConsoleCmd("sm_cp", Command_CustomPanel, "Shows custom weapons in a panel");
}

// Welcome message components
static const char g_WelcomeMsg[][] = {
    "{peachpuff}Welcome to {unique}The Youkai Pound{peachpuff} %N!",
    "{peachpuff}This server improves the stats of some weapons;",
    "{peachpuff}Read more with {lightskyblue}!info{peachpuff} or see our group at {unique}!steam",
    "{unique}New feature: Manage voice volume of other players with {chartreuse}!voice"
};

public OnClientPutInServer(client)
{
    if (client > 0 && client <= MaxClients)
        g_HasBeenWelcomed[client] = false;
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client && IsClientInGame(client))
        CreateTimer(20.0, Timer_Welcome, GetClientUserId(client));
}

public Action Timer_Welcome(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || g_HasBeenWelcomed[client])
        return Plugin_Stop;
    
    g_HasBeenWelcomed[client] = true;
    
    char buffer[256];
    Format(buffer, sizeof(buffer), g_WelcomeMsg[0], client);
    CPrintToChat(client, "%s", buffer);
    
    for (int i = 1; i < sizeof(g_WelcomeMsg); i++)
        CPrintToChat(client, "%s", g_WelcomeMsg[i]);
    
    return Plugin_Stop;
}

// Array of command categories and their descriptions
static const char g_CommandInfo[][] = {
    "{lightgreen}Weapons:{default}\n {gold}!reverts !r !rp{default} (view weapon changes / panel)\n {gold}!c !cp{default} (custom weapons / panel)\n {gold}!cw{default} (equip custom weapons)",
    "{lightgreen}Engineer buildings:{default}\n {gold}!amp !a !pads !p !ah{default} (new engi buildings / info)",
    "{lightgreen}Voting:{default} {gold}!rtv !nominate !scramble !nextmap !next{default}",
    "{lightgreen}Server:{default} {gold}!steam !chat !info !rules{default}",
    "{lightgreen}Gameplay:{default} {gold}!cw !center !duel !pads !fov !voice{default}",
    "{lightgreen}Fun:{default} {gold}!hug !rape !thirdperson !firstperson{default}"
};

public Action:Command_cmds(int client, int args)
{
    for (int i = 0; i < sizeof(g_CommandInfo); i++)
    {
        CPrintToChat(client, "%s", g_CommandInfo[i]);
    }
    return Plugin_Handled;
}

public Action:Command_Rules(int client, int args)
{
    char deez[128] = "{chartreuse}Server Rules: \n{unique} No Hacking/Friendlies \nNo Disgusting Sprays/NO FUTANARIS ALLOWED!!!";
    CPrintToChat(client, "%s", deez);
    return Plugin_Handled;
}

public Action:Command_Steam(int client, int args)
{
    char deez[128] = "{chartreuse}Steam Group: {unique} steamcommunity.com/groups/kogtf2";
    CPrintToChat(client, "%s", deez);
    return Plugin_Handled;
}

public Action:Command_chat(int client, int args)
{
    char deez[256] = "{chartreuse}Steam community chat: \n{unique} steamcommunity.com/chat/invite/Es09gkBm \n{chartreuse}Note: This chat is how the server is generally organized";
    CPrintToChat(client, "%s", deez);
    return Plugin_Handled;
}

public Action Command_ListInfo(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;
    
    for (int i = 0; i < sizeof(g_Info); i++)
        CPrintToChat(client, "%s", g_Info[i]);
    
    return Plugin_Handled;
}

static void PrintClassInfo(int client, bool revert)
{
    TFClassType class = TF2_GetPlayerClass(client);
    
    switch (class)
    {
        case TFClass_Scout:
        {
            if (revert)
                PrintLines(client, g_ScoutReverts, sizeof(g_ScoutReverts));
            else
                PrintLines(client, g_ScoutCustom, sizeof(g_ScoutCustom));
        }
        case TFClass_Soldier:
        {
            if (revert)
                PrintLines(client, g_SoldierReverts, sizeof(g_SoldierReverts));
            else
                PrintLines(client, g_SoldierCustom, sizeof(g_SoldierCustom));
        }
        case TFClass_Pyro:
        {
            if (revert)
                PrintLines(client, g_PyroReverts, sizeof(g_PyroReverts));
            else
                PrintLines(client, g_PyroCustom, sizeof(g_PyroCustom));
        }
        case TFClass_DemoMan:
        {
            if (revert)
                PrintLines(client, g_DemoReverts, sizeof(g_DemoReverts));
            else
                PrintLines(client, g_DemoCustom, sizeof(g_DemoCustom));
        }
        case TFClass_Heavy:
        {
            if (revert)
                PrintLines(client, g_HeavyReverts, sizeof(g_HeavyReverts));
            else
                PrintLines(client, g_HeavyCustom, sizeof(g_HeavyCustom));
        }
        case TFClass_Engineer:
        {
            if (revert)
                PrintLines(client, g_EngineerReverts, sizeof(g_EngineerReverts));
            else
                PrintLines(client, g_EngineerCustom, sizeof(g_EngineerCustom));
        }
        case TFClass_Medic:
        {
            if (revert)
                PrintLines(client, g_MedicReverts, sizeof(g_MedicReverts));
            else
                PrintLines(client, g_MedicCustom, sizeof(g_MedicCustom));
        }
        case TFClass_Sniper:
        {
            if (revert)
                PrintLines(client, g_SniperReverts, sizeof(g_SniperReverts));
            else
                PrintLines(client, g_SniperCustom, sizeof(g_SniperCustom));
        }
        case TFClass_Spy:
        {
            if (revert)
                PrintLines(client, g_SpyReverts, sizeof(g_SpyReverts));
            else
                PrintLines(client, g_SpyCustom, sizeof(g_SpyCustom));
        }
    }
}

static void PrintLines(int client, const char[][] lines, int count)
{
    for (int i = 0; i < count; i++)
        CPrintToChat(client, "%s", lines[i]);
}

static void GetClassName(TFClassType class, char[] buffer, int maxlen)
{
    switch (class)
    {
        case TFClass_Scout:     strcopy(buffer, maxlen, "Scout");
        case TFClass_Soldier:   strcopy(buffer, maxlen, "Soldier");
        case TFClass_Pyro:      strcopy(buffer, maxlen, "Pyro");
        case TFClass_DemoMan:   strcopy(buffer, maxlen, "Demoman");
        case TFClass_Heavy:     strcopy(buffer, maxlen, "Heavy");
        case TFClass_Engineer:  strcopy(buffer, maxlen, "Engineer");
        case TFClass_Medic:     strcopy(buffer, maxlen, "Medic");
        case TFClass_Sniper:    strcopy(buffer, maxlen, "Sniper");
        case TFClass_Spy:       strcopy(buffer, maxlen, "Spy");
        default:                strcopy(buffer, maxlen, "");
    }
}

static bool IsHexDigit(char ch)
{
    return (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F') || (ch >= 'a' && ch <= 'f');
}

static void StripColors(const char[] source, char[] dest, int destLen)
{
    int length = strlen(source);
    int write = 0;
    
    for (int i = 0; i < length && write < destLen - 1; i++)
    {
        char ch = source[i];
        
        if (ch == '{')
        {
            while (i < length && source[i] != '}')
                i++;
            continue;
        }
        
        if (ch == '\x07')
        {
            i++;
            while (i < length && IsHexDigit(source[i]))
                i++;
            i--;
            continue;
        }
        
        if (ch < 0x20)
        {
            if (ch == '\n')
            {
                if (write && dest[write - 1] != ' ')
                    dest[write++] = ' ';
            }
            continue;
        }
        
        dest[write++] = ch;
    }
    
    dest[write] = '\0';
    TrimString(dest);
}

static void ShowPanelFromData(int client, const char[] title, const char[][] lines, int count)
{
    if (!client || !IsClientInGame(client))
        return;
    
    Panel panel = new Panel();
    panel.SetTitle(title);
    panel.DrawText(" ");
    
    char buffer[256];
    for (int i = 0; i < count; i++)
    {
        StripColors(lines[i], buffer, sizeof(buffer));
        if (!buffer[0])
            continue;
        panel.DrawText(buffer);
    }
    
    panel.DrawText(" ");
    panel.Send(client, PanelHandler, 7);
    delete panel;
}

static bool ShowClassPanel(int client, TFClassType class, bool revert)
{
    char className[16];
    GetClassName(class, className, sizeof(className));
    if (!className[0])
        return false;
    
    char title[64];
    Format(title, sizeof(title), "=== %s %s ===", className, revert ? "Weapon Changes" : "!cw Weapons");
    
    switch (class)
    {
        case TFClass_Scout:
        {
            if (revert)
                ShowPanelFromData(client, title, g_ScoutReverts, sizeof(g_ScoutReverts));
            else
                ShowPanelFromData(client, title, g_ScoutCustom, sizeof(g_ScoutCustom));
            return true;
        }
        case TFClass_Soldier:
        {
            if (revert)
                ShowPanelFromData(client, title, g_SoldierReverts, sizeof(g_SoldierReverts));
            else
                ShowPanelFromData(client, title, g_SoldierCustom, sizeof(g_SoldierCustom));
            return true;
        }
        case TFClass_Pyro:
        {
            if (revert)
                ShowPanelFromData(client, title, g_PyroReverts, sizeof(g_PyroReverts));
            else
                ShowPanelFromData(client, title, g_PyroCustom, sizeof(g_PyroCustom));
            return true;
        }
        case TFClass_DemoMan:
        {
            if (revert)
                ShowPanelFromData(client, title, g_DemoReverts, sizeof(g_DemoReverts));
            else
                ShowPanelFromData(client, title, g_DemoCustom, sizeof(g_DemoCustom));
            return true;
        }
        case TFClass_Heavy:
        {
            if (revert)
                ShowPanelFromData(client, title, g_HeavyReverts, sizeof(g_HeavyReverts));
            else
                ShowPanelFromData(client, title, g_HeavyCustom, sizeof(g_HeavyCustom));
            return true;
        }
        case TFClass_Engineer:
        {
            if (revert)
                ShowPanelFromData(client, title, g_EngineerReverts, sizeof(g_EngineerReverts));
            else
                ShowPanelFromData(client, title, g_EngineerCustom, sizeof(g_EngineerCustom));
            return true;
        }
        case TFClass_Medic:
        {
            if (revert)
                ShowPanelFromData(client, title, g_MedicReverts, sizeof(g_MedicReverts));
            else
                ShowPanelFromData(client, title, g_MedicCustom, sizeof(g_MedicCustom));
            return true;
        }
        case TFClass_Sniper:
        {
            if (revert)
                ShowPanelFromData(client, title, g_SniperReverts, sizeof(g_SniperReverts));
            else
                ShowPanelFromData(client, title, g_SniperCustom, sizeof(g_SniperCustom));
            return true;
        }
        case TFClass_Spy:
        {
            if (revert)
                ShowPanelFromData(client, title, g_SpyReverts, sizeof(g_SpyReverts));
            else
                ShowPanelFromData(client, title, g_SpyCustom, sizeof(g_SpyCustom));
            return true;
        }
    }
    
    return false;
}

public Action Command_InfoC(int client, int args)
{
    PrintClassInfo(client, false);
    return Plugin_Handled;
}

public Action Command_InfoReverts(int client, int args)
{
    PrintClassInfo(client, true);
    return Plugin_Handled;
}

public Action Command_InfoC2(int client, int args)
{
    TFClassType class = TF2_GetPlayerClass(client);
    
    switch (class)
    {
        case TFClass_Spy:
        {
            for (int i = 0; i < sizeof(g_SpyCustom2); i++)
                CPrintToChat(client, "%s", g_SpyCustom2[i]);
        }
    }
    return Plugin_Handled;
}

// Panel version of weapon changes
public Action Command_RevertsPanel(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;
    
    if (!ShowClassPanel(client, TF2_GetPlayerClass(client), true))
        CPrintToChat(client, "{red}No weapon change data available for your class.");
    
    return Plugin_Handled;
}

// Panel version of custom weapons
public Action Command_CustomPanel(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;
    
    if (!ShowClassPanel(client, TF2_GetPlayerClass(client), false))
        CPrintToChat(client, "{red}No custom weapon data available for your class.");
    
    return Plugin_Handled;
}

// Example panel handler
public int PanelHandler(Menu menu, MenuAction action, int param1, int param2)
{
    return 0;
}
