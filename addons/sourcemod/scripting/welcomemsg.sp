#include <sourcemod>
#include <tf2_stocks>

stock bool:hasBeenWelcomed[MAXPLAYERS+1] = false;
TFClassType LastClass[MAXPLAYERS+1];

char info[][] = {
	"\x04Some weapons have better stats; use !r to read about your class.\n",
        "\x07FF80C0We're also testing custom weapons; check !c to read and !cw to equip.\n",
	"\x07FFFF00Use !commands to read about other commands available.\n",
	"\x0787CEFAMelee random crits are enabled, respawn times are reduced and random bullet spread is disabled;\n",
	"\x03Google 'kogtf2' or check our group at !steam to learn more and find out when people are playing.\n"
};

char scout[][] = {
	"\x01Back Scatter:\x04 +10% more accurate instead of -20% less\n",
	"\x01Baby Face's:\x03 Boost kept on damage taken, -20% base movement speed\n",
	"\x01The Shortstop:\x04 +25% reload speed, +20% healing received, +80% damage force taken\n",
	"\x01Flying Guillotine:\x03 Deals +100% damage to stunned targets\n",
	"\x01Crit-a-Cola:\x04 No mark for death visual, damage vuln. reduced to 25%\n",
	"\x01The Sandman:\x03 stuns, 512 unit min range\n",
	"\x01Candy Cane:\x04 +40% more health from medkits\n",
	"\x01Fan-o-War:\x03 +20% deploy and holster speed\n"
}

char scoutc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
        "\x01 [Primary] Original Baby Face: \x03+40% accuracy, 6 clip size,\x07FF0000 -30% damage, -25% base movement speed\n",
        "\x01 [Secondary] Lightning Pistol: \x03+35% firing rate, +200% clip size, 70% more accurate, +100% ammo,\x07FF0000 -40% damage, -15% reload speed\n",
}

char soldier[][] = {
	"\x01Air Strike:\x04 +15% reload speed\n",
	"\x01Liberty Launcher:\x03 +10% firing speed\n",
	"\x01Righteous Bison:\x04 Fires 55% faster, bonus damage up to +100% based on distance,\x07FF0000 -40% damage\n",
	"\x01Base Jumper:\x03 Re-deploy, float upwards while on fire\n",
	"\x01Equalizer:\x04 -20% damage from ranged sources while active\n",
}

char soldierc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
	"\x01 [Secondary] The F.U.T.A.: \x03+30% blast jump damage resistance, +20% tighter spread, +15% deploy speed,\x07FF0000 -66% clip size\n",
        "\x01 [Secondary] Old Panic Attack: \x03Hold fire to load up to 4 shells, fires faster as HP decreases\n",
	"\x01 [Secondary] Soldier's Pistol\n"
}

char pyro[][] = {
        "\x01Dragon's Fury:\x04 Airblast jump\n",
        "\x01Degreaser:\x03 +35% bonus to all switch speeds\n",
        "\x01Detonator:\x04 Self damage penalty reduced from 50% to 25%\n",
        "\x01Thermal Thruster:\x03 Re-launch while midair\n",
        "\x01Gas Passer:\x04 Gas applies jarate for 6s\n",
        "\x01Axtinguisher: \x03 Crits burning targets, 50% less damage to non-burning targets\n",
        "\x01Volcano Fragment: \x04 Mini-crits burning targets\n"
}

char pyroc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
        "\x01 [Primary] Stock Shotgun\n",
        "\x01 [Secondary] TF2C Twin Barrel: \x03Holster reload, +20% bullets per shot, first shot is a recoil jump,\x07FF2400 10% wider spread, 15% slower draw speed\n",
        "\x01 [Secondary] Old Panic Attack: \x03Hold fire to load up to 4 shells, fires faster as HP decreases\n",
        "\x01 [Secondary] The Family Business\n",
        "\x01 [Melee] TF2C Harvester: \x03Afterburn is returned as health while held,\x07FF2400 enemies are extinguished on your death\n"
}

char demoman[][] = {
	"\x01Booties:\x04 Provide speed even without a shield\n",
	"\x01Base Jumper:\x03 Re-deploy, float upwards while on fire\n",
	"\x01Sticky Jumper:\x04 Max stickies 3 -> 8\n",
	"\x01Scottish Resistance:\x03 Arm time 0.8 -> 0.4\n",
	"\x01Shields:\x04 Provide 65% blast jump damage resistance\n",
	"\x01Caber:\x03 Explosion deals 125 damage, deals 175 damage while blast jumping\n",
	"\x01Scottish Handshake:\x04 Market gardener stats\n",
}

char demomanc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
        "\x01 [Primary] Grenade Launcher (straight grenades)\n",
        "\x01 [Primary] Demoman Gunboats\n",
	"\x01 [Secondary] Demoman Banana: \x03Throw and eat to heal yourself!\n"
}

char heavy[][] = {
	"\x01Huo Long Heater:\x04 No damage penalty\n",
	"\x01Shotguns:\x03 +10% movement speed while held\n",
	"\x01Gloves of Running:\x04 No health drain, marks for death\n",
	"\x01Eviction Notice:\x03 No health drain, fires 60% faster instead of 40%\n",
	"\x01Warrior's Spirit:\x03 No active dmg. vuln, +20 health on hit,\x07FF2400 no health on kill, -20 max health\n"
}

char heavyc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
        "\x01 [Secondary] Old Panic Attack: \x03Hold fire to load up to 4 shells, fires faster as HP decreases\n"
}

char engineer[][] = {
	"\x01Pomson:\x04 Penetrates targets, +20% firing rate\n",
	"\x01Southern Hospitality:\x03 +10% damage, +100% dispenser range\n"
}

char engineerc[][] = {
        "\x07EEE8A ----- !cw weapons -----\n",
        "\x01 [Primary] Old Panic Attack: \x03Hold fire to load up to 4 shells, fires faster as HP decreases\n",
        "\x01 [Primary] The Family Business\n",
        "\x01 [Secondary] Lightning Pistol: \x03+35% firing rate, +150% clip size, 70% more accurate,\x07FF2400 -35% damage, -15% reload speed\n",
        "\x01 [Secondary] The Winger\n",
        "\x01 [Secondary] Pretty Boy's Pocket Pistol\n",
        "\x01 [PDA1] Boost/Jump pads (Or use !pads for convenience)\n"
}

char medic[][] = {
	"\x01Syringe guns:\x04 +1.25% uber on hit, reload on holster\n",
	"\x01The Vita-Saw:\x03 Retain up to 20% uber after death regardless of organs, wall climbing\n"
}

char medicc[][] = {
    "\x07EEE8A ----- !cw weapons -----\n",
    "\x01[Melee] TF2C Shock Therapy: \x03Hit allies to fully overheal them, \x07EEE8A enemies take charge as damage,\x07FF2400 30s recharge time, -15% healing on medigun\n",
    "\x01[Melee] The Mantreads"
}

char sniper[][] = {
    "\x01The Huntsman:\x04 +15hp on wearer, enables melee wall climbing\n",
    "\x01The Classic:\x03 +20% charge rate\n",
    "\x01The Cozy Camper:\x04 No aim flinch at any charge\n",
    "\x01The Cleaner's Carbine:\x03 Critboost on kill (3s)\n",
    "\x01The Tribalman's Shiv\x04 -25% damage instead of -50% damage\n"
}

char sniperc[][] = {
    "\x07EEE8A ----- !cw weapons -----\n",
	"\x01 No custom weapons detected for your class!"
}

char spy[][] = {
	"\x01The Ambassador:\x04 Headshots deal 102 damage\n",
	"\x01The Enforcer:\x03 50% less bullet spread, +20% damage, no disguise bonus\n",
	"\x01The Big Earner:\x04 +5hp\n",
	"\x01Your Eternal Reward:\x03 0% cloak drain penalty, +10% swing speed\n"
}

char spyc[][] = {
	"\x07EEE8A ----- !cw weapons -----\n",
	"\x01 [Secondary] Enforcer (Alt): \x03No fire rate penalty, +10% damage,\x07FF2400 -25% damage while disguised, +0.5s time to cloak\n",
	"\x01 [Secondary] Wall Climbing Kit: \x03+15 hp, enables wall climb,\x07FF2400 +25% damage taken from fire, +20% damage taken from explosives\n", 
	"\x07FFFF00This class has additional weapons; check !c2 to read the second page."
}

char spyc2[][] = {
        "\x07EEE8A ----- !cw weapons (2) -----\n",
        "\x01 [Building] The Surfboard: \x03-60% damage taken from sentries, \x07FF2400 60% less sapper damage\n",
        "\x01 [PDA] TF2C L'escampette: \x03Move 30% faster while cloaked,\x07FF2400 50% less cloak, 10% cloak lost on hit, no pickups while cloaked\n"
}

public Plugin:myinfo =
{
	name = "Welcome Message",
	author = "Hombre",
	description = "Welcome message & server info plugin for Kogasatopia, very specific",
	version = "2.00",
	url = "https://kogasa.tf"
}

public OnPluginStart()
{
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
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
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	CreateTimer(20.0, Delay, client); 
}

public Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
	LastClass[client] = TF2_GetPlayerClass(client);
}

public Action:Delay(Handle:timer, any:client)
{
	if(!hasBeenWelcomed[client] && IsClientInGame(client))
	{
		hasBeenWelcomed[client] = true;
		PrintToChat(client, "\x03Welcome to The Youkai Pound %N! \nThis server improves the stats of some weapons; \nRead more with \x0787CEFA!info\n\x07EEE8A New feature: join our steam group at \x03!steam", client);
	}
}  

public Action:Command_cmds(int client, int args)
{
	char deez[256] = "\x03Server Commands:\x07EEE8A \nVoting: !rtv !nominate !scramble !nextmap !next \x0787CEFA\nServer: !reverts !r !cw !c !steam !info !rules \x0780D0A0\nGameplay: !cw !center !duel !pads !fov\x07DDA0DD\nQuirky: !hug !rape !thirdperson !firstperson";
	PrintToChat(client, "%s", deez);
	return Plugin_Handled;
}

public Action:Command_Rules(int client, int args)
{
        char deez[128] = "\x03Server Rules: \n\x07EEE8A No Hacking/Friendlies \nNo Disgusting Sprays/NO FUTANARIS ALLOWED!!!";
        PrintToChat(client, "%s", deez);
        return Plugin_Handled;
}

public Action:Command_Steam(int client, int args)
{
        char deez[64] = "\x03Steam Group: \x07EEE8A steamcommunity.com/groups/kogtf2";
        PrintToChat(client, "%s", deez);
        return Plugin_Handled;
}

public Action:Command_chat(int client, int args)
{
        char deez[256] = "\x03Steam community chat: \n\x07EEE8A steamcommunity.com/chat/invite/Es09gkBm \n\x03Note: This chat is how the server is generally organized";
	PrintToChat(client, "%s", deez);
        return Plugin_Handled;
}

public Action:Command_ListInfo(int client, int args)
{
	if ((client) && IsClientInGame(client)) {
		for (int i; i < sizeof(info); i++) {
			PrintToChat(client, "%s", info[i]);
		}
	}
}

public Action Command_InfoReverts(int client, int args)
{
	TFClassType class = TF2_GetPlayerClass(client);

	switch (class)
	{
		case TFClass_Scout:
		{
			for (int i = 0; i < sizeof(scout); i++)
				PrintToChat(client, "%s", scout[i]);
		}
		case TFClass_Soldier:
		{
			for (int i = 0; i < sizeof(soldier); i++)
				PrintToChat(client, "%s", soldier[i]);
		}
		case TFClass_Pyro:
		{
			for (int i = 0; i < sizeof(pyro); i++)
				PrintToChat(client, "%s", pyro[i]);
		}
		case TFClass_DemoMan:
		{
			for (int i = 0; i < sizeof(demoman); i++)
				PrintToChat(client, "%s", demoman[i]);
		}
		case TFClass_Heavy:
		{
			for (int i = 0; i < sizeof(heavy); i++)
				PrintToChat(client, "%s", heavy[i]);
		}
		case TFClass_Engineer:
		{
			for (int i = 0; i < sizeof(engineer); i++)
				PrintToChat(client, "%s", engineer[i]);
		}
		case TFClass_Medic:
		{
			for (int i = 0; i < sizeof(medic); i++)
				PrintToChat(client, "%s", medic[i]);
		}
		case TFClass_Sniper:
		{
			for (int i = 0; i < sizeof(sniper); i++)
				PrintToChat(client, "%s", sniper[i]);
		}
		case TFClass_Spy:
		{
			for (int i = 0; i < sizeof(spy); i++)
				PrintToChat(client, "%s", spy[i]);
		}
	}
	return Plugin_Handled;
}

public Action Command_InfoC(int client, int args)
{
        TFClassType class = TF2_GetPlayerClass(client);

        switch (class)
        {
                case TFClass_Scout:
                {
                        for (int i = 0; i < sizeof(scoutc); i++)
                                PrintToChat(client, "%s", scoutc[i]);
                }
                case TFClass_Soldier:
                {
                        for (int i = 0; i < sizeof(soldierc); i++)
                                PrintToChat(client, "%s", soldierc[i]);
                }
                case TFClass_Pyro:
                {
                        for (int i = 0; i < sizeof(pyroc); i++)
                                PrintToChat(client, "%s", pyroc[i]);
                }
                case TFClass_DemoMan:
                {
                        for (int i = 0; i < sizeof(demomanc); i++)
                                PrintToChat(client, "%s", demomanc[i]);                                                                                                                                                           }
                case TFClass_Heavy:
                {
                        for (int i = 0; i < sizeof(heavyc); i++)
                                PrintToChat(client, "%s", heavyc[i]);
                }
                case TFClass_Engineer:
                {
                        for (int i = 0; i < sizeof(engineerc); i++)
                                PrintToChat(client, "%s", engineerc[i]);
                }
                case TFClass_Medic:
                {
                        for (int i = 0; i < sizeof(medicc); i++)
                                PrintToChat(client, "%s", medicc[i]);
                }
                case TFClass_Sniper:
                {
                        for (int i = 0; i < sizeof(sniperc); i++)
                                PrintToChat(client, "%s", sniperc[i]);
                }
                case TFClass_Spy:
                {
                        for (int i = 0; i < sizeof(spyc); i++)
                                PrintToChat(client, "%s", spyc[i]);
                }
        }
        return Plugin_Handled;
}

public Action Command_InfoC2(int client, int args)
{
        TFClassType class = TF2_GetPlayerClass(client);

        switch (class)
        {
                case TFClass_Spy:
                {
                        for (int i = 0; i < sizeof(spyc2); i++)
                                PrintToChat(client, "%s", spyc2[i]);
                }
	}
	return Plugin_Handled;
}
