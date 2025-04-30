#include <sourcemod>
#include <tf2_stocks>

stock bool:hasBeenWelcomed[MAXPLAYERS+1] = false;
TFClassType LastClass[MAXPLAYERS+1];

char info[][] = {
	"\x07FF80C0This server improves the stats of some weapons; use !reverts to read about your class.\n",
	"\x07FFFF00Use !commands to read about other commands available.\n",
	"\x07DDA0DDSprays and other features like soundsprays are enabled.\n",
	"\x07EEE8A\nThe mapcycle becomes larger after 9PM EST.\n",
	"\x0787CEFAMelee random crits are enabled and random bullet spread is disabled;\n",
	"\x03Google 'Kogasatopia' to locate our website easily and check when people are playing.\n",
	"\x0780D0A0When do people play here? Usually after 9PM EST."
};

char infoclass[][] = {
	"\x03Back Scatter: +10% more accurate instead of -20% less\n",
	"\x03Baby Face's: Boost kept on damage taken\n",
	"\x0770C070Flying Guillotine: Deals +100% damage to stunned targets\n",
	"\x0770C070Crit-a-Cola: No mark for death visual, damage vuln. reduced to 25%\n",
	"\x0780D0A0The Sandman: stuns, 512 unit min range\n",
	"\x0780D0A0Candy Cane: +40% more health from medkits\n",
	"\x0780D0A0Fan-o-War: +20% deploy and holster speed\n",
	"\x03 ----- default weapons -----\n",
	"\x03Air Strike: +15% reload speed\n",
	"\x03Liberty Launcher: +10% firing speed\n",
	"\x0770C070Righteous Bison: Fires 60% faster, 50% less damage falloff\n",
	"\x0770C070Base Jumper: Can be redeployed mid-air\n",
	"\x0780D0A0Equalizer: -20% damage from ranged sources while active\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases\n",
	"\x07EEE8A [Secondary] The Family Business\n",
	"\x07EEE8A [Secondary] TF2C Twin Barrel: Reloads on holster, knockback on user and target\n",
	"\x07EEE8A [Melee] TF2C Harvester: Afterburn is returned as health while held, enemies are extinguished on your death\n",
	"\x03 ----- default weapons -----\n",
	"\x03Dragon's Fury: Airblast jump, original projectile size\n",
	"\x03Degreaser: +40% bonus to all switch speeds\n",
	"\x0770C070Detonator: Self damage penalty reduced from 50% to 25%\n",
	"\x0770C070Thermal Thruster: Re-launch while midair\n",
	"\x0780D0A0Axtinguisher: Crits burning targets\n",
	"\x03 ----- default weapons -----\n",
	"\x03Loch n' Load: Deals 110 damage\n",
	"\x03Booties: Provide speed even without a shield\n",
	"\x0770C070Sticky Jumper: Max stickies 3 -> 8\n",
	"\x0770C070Shields: Provide 65% blast jump damage resistance\n",
	"\x0780D0A0Caber: Explosion deals 125 damage, deals 175 damage while blast jumping\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Primary] Grenade Launcher (straight grenades)\n",
	"\x07EEE8A [Primary] Demoman Gunboats\n",
	"\x03 ----- default weapons -----\n",
	"\x03Huo Long Heater: No damage penalty\n",
	"\x0770C070Shotguns: +10% movement speed while held\n",
	"\x0780D0A0Gloves of Running: No health drain, marks for death\n",
	"\x0780D0A0Eviction Notice: No health drain, fires 60% faster instead of 40%\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Secondary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Primary] Old Panic Attack: Hold fire to load up to 4 shells, fires faster as HP decreases\n",
	"\x07EEE8A [Primary] The Family Business\n",
	"\x07EEE8A [Secondary] The Winger\n",
	"\x07EEE8A [Secondary] Pretty Boy's Pocket Pistol\n",	
	"\x07EEE8A [PDA1] Boost/Jump pads (Or use !pads for convenience)\n",
	"\x03 ----- default weapons -----\n",
	"\x03Pomson: Penetrates targets, +20% firing rate\n",
	"\x0780D0A0Southern Hospitality: +10% damage, +100% dispenser range\n",
	"\x03 ----- default weapons -----\n",
	"\x03Syringe guns provide +1.25% uber on hit, reload on holster\n",
	"\x0780D0A0The Vita-Saw: Retain up to 20% uber after death regardless of organs\n", 
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Melee] TF2C Shock Therapy: Hit an ally at full charge to fully overheal them, recharge time is 30s, enemies take charge as damage, -15% healing\n",
	"\x03The Huntsman: +15hp on wearer, enables melee wall climbing\n",
	"\x03The Classic: +15% charge rate\n",
	"\x0770C070The Cleaner's Carbine: Critboost on kill (2s)\n",
	"\x0780D0A0The Tribalman's Shiv: -25% damage instead of -50% damage\n",
	"\x03 ----- default weapons -----\n",
	"\x03The Ambassador: Headshots deal 102 damage\n",
	"\x03The Enforcer: +10% damage, no firing rate penalty, +33% cloak drain increase, +0.5s time to cloak\n",
	"\x03The Big Earner: +5hp\n",
	"\x0780D0A0Your Eternal Reward: 0% cloak drain penalty, +15% swing speed\n",
	"\x07EEE8A ----- !cwx weapons -----\n",
	"\x07EEE8A [Building] TF2C L'escampette: Move 30% faster while cloaked, 50% less cloak, 10% cloak lost on hit\n"
};

char g_sClassNames[TFClassType][16] = { "Unknown", "Scout", "Sniper", "Soldier", "Demoman", "Medic", "Heavy", "Pyro", "Spy", "Engineer"};

public Plugin:myinfo =
{
	name = "Welcome Message",
	author = "bahombr",
	description = "Welcome message & server info plugin",
	version = "1.00",
	url = "https://gyate.net"
}

public OnPluginStart()
{
	HookEvent("player_spawn", Event_PlayerSpawn);
        HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	LoadTranslations("welcomemsg.phrases.txt");
	RegConsoleCmd("sm_info", Command_ListInfo, "Displays an brief message to the client about the server.");
	RegConsoleCmd("sm_c", Command_InfoC, "Lists custom class weapon data to the client");
	RegConsoleCmd("sm_reverts", Command_InfoC, "Lists custom class weapon data to the client");
	RegConsoleCmd("sm_cmds", Command_cmds, "Lists highlighted server commands to the client");
	RegConsoleCmd("sm_commands", Command_cmds, "Lists highlighted server commands to the client");
        RegConsoleCmd("sm_rules", Command_Rules, "Lists the rules to the client");
        RegConsoleCmd("sm_steam", Command_Steam, "Prints the steam group URL to the client");
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
		PrintToChat(client, "\x03Welcome to Kogasatopia %N! \nThis server improves the stats of some weapons; \nRead more at tf2.gyate.net or use: \x0787CEFA!info\n\x07EEE8A New feature: join our steam group at \x03!steam", client);
	}
}  

public Action:Command_cmds(int client, int args)
{
	char deez[256] = "\x03Server Commands:\x07EEE8A \nVoting: !rtv !nominate !scramble !nextmap \nServer: !reverts !steam !info !rules \nGameplay: !cwx !center !pads !bots !togglehat\nQuirky: !hug !rape !thirdperson !firstperson";
	PrintToChat(client, "%s", deez);
	return Plugin_Handled;
}

public Action:Command_Rules(int client, int args)
{
        char deez[128] = "\x03Server Rules: \n\x07EEE8A No Hacking/Friendlies \nNo Pronoun Names/Disgusting Sprays";
        PrintToChat(client, "%s", deez);
        return Plugin_Handled;
}

public Action:Command_Steam(int client, int args)
{
        char deez[64] = "\x03Steam Group: \x07EEE8A tf2.gyate.net/steam";
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

public Action:Command_InfoC(int client, int args)
{
	char playerClassContext[64];
	LastClass[client] = TF2_GetPlayerClass(client);
	TFClassType Class = LastClass[client];
	Format(playerClassContext, sizeof playerClassContext, "%s", g_sClassNames[Class]);

	if (StrEqual(playerClassContext, "Scout"))
	{
		for (int i = 0; i < 7; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Soldier"))
	{
		for (int i = 7; i < 15; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Pyro"))
	{
		for (int i = 15; i < 26; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Demoman"))
	{
		for (int i = 26; i < 35; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Heavy"))
	{
		for (int i = 35; i < 42; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Engineer"))
	{
		for (int i = 42; i < 51; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Medic"))
	{
		for (int i = 51; i < 56; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Sniper"))
	{
		for (int i = 56; i < 60; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
	if (StrEqual(playerClassContext, "Spy"))
	{
		for (int i = 60; i < 68 ; i++) {
			PrintToChat(client, "%s", infoclass[i]);
		}
	}
}
