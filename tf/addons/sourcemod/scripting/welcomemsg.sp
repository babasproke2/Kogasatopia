#include <sourcemod>
#include <tf2_stocks>
#include <morecolors>

bool g_HasBeenWelcomed[MAXPLAYERS + 1];
ConVar g_hUncleCycleState;

static const char g_Info[][] = {
    "{peachpuff}Some weapons have better stats; use {yellow}!r {peachpuff}to read about your class.\n",
    "{peachpuff}We're also testing custom weapons; check {yellow}!c {peachpuff}to read and {yellow}!cw {peachpuff}to equip.\n",
    "{peachpuff}Use {yellow}!commands {peachpuff}to browse the rest of the server commands.\n",
    "{peachpuff}Random crits and bullet spread are disabled, respawn times are reduced\n",
    "{peachpuff}Some classes are limited on Payload/AD gamemodes;\n",
    "{peachpuff}Google 'kogtf2' or visit our group with {yellow}!steam {peachpuff}to learn more and see when people are playing.\n"
};

static const char g_ScoutReverts[][] = {
    "{default}Back Scatter:{green} +10% more accurate instead of -20% less\n",
    "{default}Baby Face's:{chartreuse} Boost kept on damage taken,{red} -20% base movement speed\n",
    "{default}The Shortstop:{green} +50% reload speed, +20% healing received,{red} +40% damage force taken\n",
    "{default}Flying Guillotine:{chartreuse} Deals +100% damage to stunned targets\n",
    "{default}Crit-a-Cola:{green} No mark for death on attack,{red} +25% damage taken while active\n",
    "{default}Bonk:{chartreuse} No post-effect slowdown,{red} marks for death after effect expires",
    "{default}The Sandman:{green} stuns, 512 unit min range\n",
    "{default}Candy Cane:{chartreuse} +40% more health from medkits\n",
    "{default}Fan-o-War:{green} +20% deploy and holster speed, can mark up to 3 enemies at once\n"
};

static const char g_ScoutCustom[][] = {
    "\x01 [Primary] Original Baby Face: {green}+40% accuracy, 6 clip size,\x07FF0000 -30% damage, -35% base movement speed, boost resets on any jump\n",
    "\x01 [Secondary] Lightning Pistol: {chartreuse}+35% firing rate, +200% clip size, 40% more accurate, +100% ammo,{red} -40% damage, -15% reload speed\n",
    "\x01 [Secondary] Sproke (Redbull on Blu): {green}Ammo becomes magazine for 12 seconds, {red}ammo is set to 0 when effect ends,{default} FaN/Popper receive +25% reload speed instead",
    "\x01[Secondary] Conagher's Bull: Drain 25 ammo from buildings on hit, first shot deals 300 damage to enemies holding the same weapon, 60% tighter spread\n"
};

static const char g_SoldierReverts[][] = {
    "{default}Air Strike:{green} +15% reload speed\n",
    "{default}Liberty Launcher:{green} +10% firing speed\n",
    "{default}Righteous Bison:{green} Original hitbox size, ignores bullet resistance, ignites friendly Huntsman arrows\n",
    "{default}Base Jumper:{chartreuse} Re-deploy, float upwards while on fire\n",
    "{default}Equalizer:{green} -20% damage from ranged sources while active\n",
};

static const char g_SoldierCustom[][] = {
    "\x01[Secondary] The F.U.T.A.: {green}+30% blast jump damage resistance, +15% tighter spread,{red} -50% clip size\n",
    "\x01[Secondary] Old Panic Attack: {chartreuse}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] Soldier's Pistol\n",
    "\x01[Secondary] Soldier's M16: SMG, {red}50% less accurate, {green}dealing 20 damage refills your rocket launcher clip by 1\n",
};

static const char g_PyroReverts[][] = {
    "{default}Dragon's Fury:{green} Airblast jump\n",
    "{default}Degreaser:{chartreuse} +35% bonus to all switch speeds\n",
    "{default}Detonator:{green} Self damage penalty reduced from 50% to 25%\n",
    "{default}Axtinguisher: {chartreuse} Crits burning targets, 50% less damage to non-burning targets\n",
    "{default}Volcano Fragment: {green} Mini-crits burning targets\n"
};

static const char g_PyroCustom[][] = {
    "\x01[Primary] Stock Shotgun\n",
    "\x01[Secondary] Flame Shotgun: {green}Hitting a target accurately twice or killing them creates a fiery explosion,{red} -15% clip size, -30% damage penalty\n",
    "\x01[Secondary] TF2C Twin Barrel: {chartreuse}Holster reload, +20% bullets per shot, first shot is a recoil jump,{red} 10% wider spread, 15% slower draw speed\n",
    "\x01[Secondary] Old Panic Attack: {green}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] The Family Business\n",
    "\x01[Melee] TF2C Harvester: {chartreuse}Afterburn is returned as health while held,{red} enemies are extinguished on your death\n"
};

static const char g_DemoReverts[][] = {
    "\x01Booties:{green} Provide speed even without a shield\n",
    "\x01Base Jumper:{green} Re-deploy, float upwards while on fire\n",
    "\x01Sticky Jumper:{green} Max stickies 3 -> 8\n",
    "\x01Scottish Resistance:{chartreuse} Arm time 0.8 -> 0.4\n",
    "\x01Shields:{green} Provide 65% blast jump damage resistance,{red} all resistances are changed to 10%\n",
    "\x01Caber:{green} Explosion deals 125 damage, deals 175 damage while blast jumping\n",
    "\x01Scottish Handshake:{green} Market gardener stats\n",
};

static const char g_DemoCustom[][] = {
    "\x01[Primary] Grenade Launcher (straight grenades)\n",
    "\x01[Primary] Demoman Gunboats\n",
    "\x01[Secondary] Demoman Banana: {green}Throw and eat to heal yourself!\n"
};

static const char g_HeavyReverts[][] = {
    "\x01Huo Long Heater:{green} No damage penalty\n",
    "\x01Shotguns:{green} +10% movement speed while held\n",
    "\x01Gloves of Running:{green} No health drain, marks for death\n",
    "\x01Eviction Notice:{chartreuse} No health drain, fires 60% faster instead of 40%\n",
    "\x01Warrior's Spirit:{green} No active dmg. vuln, +20 health on hit,{red} no health on kill, -20 max health\n"
};

static const char g_HeavyCustom[][] = {
    "\x01[Secondary] Old Panic Attack: {green}Hold fire to load up to 4 shells, fires faster as HP decreases\n"
};

static const char g_EngineerReverts[][] = {
    "\x01Pomson:{green} Original hitbox size, penetrates targets, ignores bullet resists, lights up friendly Huntsman arrows\n",
    "\x01The Wrangler:{red} Shield resistance 66% -> 25%\n",
    "\x01The Short Circuit:{chartreuse} Damage dealt with primary fire is returned as metal,{red} 75% less metal from carts on wearer\n",
    "\x01Southern Hospitality:{green} +10% damage, 15 metal regenerated every 5 seconds on wearer\n"
};

static const char g_EngineerCustom[][] = {
    "\x01[Primary] The Family Business\n",
    "\x01[Primary] Old Panic Attack: {chartreuse}Hold fire to load up to 4 shells, fires faster as HP decreases\n",
    "\x01[Secondary] Conagher's Bull: Drain 25 ammo from buildings on hit, first shot deals 300 damage to enemies holding the same weapon, 80% tighter spread\n",
    "\x01[Secondary] Lightning Pistol: {green}+35% firing rate, +200% clip size, 40% more accurate, +100% ammo,{red} -40% damage, -15% reload speed\n",
    "\x01[Secondary] The Winger, Pretty Boy's Pocket Pistol\n",
    "\x01[PDA1] Boost/Jump pads (Or use !pads for convenience)\n",
    "\x01[PDA2] Amplifier Dispenser Replacement (Or use !amp or !a)\n"
};

static const char g_MedicReverts[][] = {
    "\x01Syringe guns:{green} +1.25% uber on hit, reload on holster\n",
    "\x01The Vita-Saw:{chartreuse} Retain up to 20% uber after death regardless of organs, wall climbing\n",
    "\x01The Vaccinator:{red}} +20% damage taken while held\n"
};

static const char g_MedicCustom[][] = {
    "\x01[Melee] TF2C Shock Therapy: {green}Hit allies to fully overheal them, {unique} enemies take charge as damage,{red} 30s recharge time, -15% healing on medigun\n",
    "\x01[Melee] The Mantreads"
};

static const char g_SniperReverts[][] = {
    "\x01The Huntsman:{green}} +15hp on wearer, enables melee wall climbing\n",
    "\x01The Classic:{chartreuse} +20% charge rate\n",
    "\x01The Cozy Camper:{green} No aim flinch at any charge\n",
    "\x01The Cleaner's Carbine:{chartreuse} Critboost on kill (3s)\n",
    "\x01The Tribalman's Shiv:{green} -25% damage instead of -50% damage\n"
};

static const char g_SniperCustom[][] = {
    "\x01 No custom weapons detected for your class!"
};

static const char g_SpyReverts[][] = {
    "\x01The Ambassador:{green} Headshots deal 102 damage\n",
    "\x01The Enforcer:{chartreuse} 50% less bullet spread, +20% damage, no disguise bonus\n",
    "\x01The Big Earner:{green} +5hp\n",
    "\x01Your Eternal Reward:{chartreuse} 0% cloak drain penalty, +10% swing speed\n"
};

static const char g_SpyCustom[][] = {
    "\x01[Secondary] Enforcer (Alt): {green}No fire rate penalty, +10% damage,{red} -25% damage while disguised, +0.5s time to cloak\n",
    "\x01[Secondary] Wall Climbing Kit: {chartreuse}enables wall climb,{red} -10 health on wearer\n",
    "{gold}This class has additional weapons; check !c2 to read the second page."
};

static const char g_SpyCustom2[][] = {
    "{unique} ----- !cw weapons (2) -----\n",
    "\x01 [Building] The Surfboard: {chartreuse}-60% damage taken from sentries, {red} 60% less sapper damage\n",
    "\x01 [PDA] TF2C L'escampette: {chartreuse}Move 30% faster while cloaked,{red} 50% less cloak, 10% cloak lost on hit, no pickups while cloaked\n"
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
    g_hUncleCycleState = FindConVar("uncle_cycle_active");
    
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
    "{unique}New feature: check out the new saysounds system with {chartreuse}!opt"
};

static const char g_UncleWelcomeMsg[][] = {
    "{peachpuff}Welcome to {unique}Dane's Custom Weapons{peachpuff}, %N!",
    "{peachpuff}You're on an Uncletopia Custom Weapons server curated by Uncle Dane.",
    "{peachpuff}Uncle Dane added new buildings and weapons; use {lightskyblue}!info{peachpuff} to learn more.",
    "{peachpuff}Be aware of fake Uncletopia servers pretending to offer these features."
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
    if (IsUncleCycleActive())
    {
        Format(buffer, sizeof(buffer), g_UncleWelcomeMsg[0], client);
        CPrintToChat(client, "%s", buffer);
        
        for (int i = 1; i < sizeof(g_UncleWelcomeMsg); i++)
            CPrintToChat(client, "%s", g_UncleWelcomeMsg[i]);
    }
    else
    {
        Format(buffer, sizeof(buffer), g_WelcomeMsg[0], client);
        CPrintToChat(client, "%s", buffer);
        
        for (int i = 1; i < sizeof(g_WelcomeMsg); i++)
            CPrintToChat(client, "%s", g_WelcomeMsg[i]);
    }
    return Plugin_Stop;
}

public bool IsUncleCycleActive()
{
    if (g_hUncleCycleState == null)
        g_hUncleCycleState = FindConVar("uncle_cycle_active");
    
    return g_hUncleCycleState != null && g_hUncleCycleState.BoolValue;
}

// Array of command categories and their descriptions
static const char g_CommandInfo[][] = {
    "{lightgreen}Weapons:{default}\n {gold}!reverts !r !rp{default} (view weapon changes / panel)\n {gold}!c !cp{default} (custom weapons / panel)\n {gold}!cw{default} (equip custom weapons)",
    "{lightgreen}Engineer buildings:{default}\n {gold}!amp !a !pads !p !ah{default} (new engi buildings / info)",
    "{lightgreen}Voting:{default} {gold}!rtv !nominate !scramble !nextmap !next{default}",
    "{lightgreen}Server:{default} {gold}!steam !chat !info !rules !voice {default}",
    "{lightgreen}Gameplay:{default} {gold}!cw !center !duel !pads !fov !classlimits{default}",
    "{lightgreen}Fun:{default} {gold}!hug !rape !thirdperson !firstperson !name (color){default}"
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
