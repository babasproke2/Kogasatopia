#include <sourcemod>
#include <clientprefs>
#include <tf2>
#include <tf2_stocks>

#pragma semicolon 1
#define PLUGIN_VERSION  "1.3"

public Plugin:myinfo = {
  name = "No MOTD",
  author = "Original by MasterOfTheXP, modified by GC and Hombre",
  description = "Removes the MOTD, autojoin random team, and autojoins classes.",
  version = PLUGIN_VERSION,
  url = "http://mstr.ca/"
};

bool clientMOTDBlocked[MAXPLAYERS + 1];

public OnPluginStart()
{
  CreateConVar("sm_nomotd_version", PLUGIN_VERSION, "No MOTD version", FCVAR_NOTIFY|FCVAR_SPONLY);

  for (new i = 1; i <= MaxClients; i++) {
    clientMOTDBlocked[i] = IsClientInGame(i);
  }

  HookUserMessage(GetUserMessageId("Train"), UserMessageHook, true);
}

public void OnClientDisconnect(client) {
  clientMOTDBlocked[client] = false;
}

public Action UserMessageHook(UserMsg msg_id, Handle bf, const players[], playersNum, bool reliable, bool init)
{
  if (playersNum == 1 && IsClientConnected(players[0]) && !clientMOTDBlocked[players[0]] && !IsFakeClient(players[0]))
  {
    clientMOTDBlocked[players[0]] = true;
    CreateTimer(0.0, KillMOTD, GetClientUserId(players[0]), TIMER_FLAG_NO_MAPCHANGE);
  }

  return Plugin_Continue;
}

public Action KillMOTD(Handle timer, any uid)
{
  int client = GetClientOfUserId(uid);
  if (!client) return Plugin_Handled;

  // Forced behavior: always skip MOTD and autojoin a random/least-pop team.
  ShowVGUIPanel(client, "info", _, false);
  FakeClientCommand(client, "jointeam auto");

  return Plugin_Handled;
}
