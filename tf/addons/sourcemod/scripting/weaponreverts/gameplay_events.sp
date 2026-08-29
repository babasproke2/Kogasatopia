GlobalForward g_OnAmbassadorHeadshotKill = null;
GlobalForward g_OnSandmanCleaverCombo = null;
GlobalForward g_OnMeatshotKill = null;
GlobalForward g_OnEnvironmentalKill = null;
GlobalForward g_OnSandmanMoonshot = null;
GlobalForward g_OnDoubleDonk = null;

#define BONUS_EFFECT_DOUBLE_DONK 2

void WeaponRevertsEvents_Init()
{
	WeaponRevertsEvents_Shutdown();
	g_OnAmbassadorHeadshotKill = new GlobalForward("OnAmbassadorHeadshotKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnSandmanCleaverCombo = new GlobalForward("OnSandmanCleaverCombo", ET_Ignore, Param_Cell, Param_Cell);
	g_OnMeatshotKill = new GlobalForward("OnMeatshotKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnEnvironmentalKill = new GlobalForward("OnEnvironmentalKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnSandmanMoonshot = new GlobalForward("OnSandmanMoonshot", ET_Ignore, Param_Cell, Param_Cell);
	g_OnDoubleDonk = new GlobalForward("OnDoubleDonk", ET_Ignore, Param_Cell, Param_Cell);
}

void WeaponRevertsEvents_Shutdown()
{
	delete g_OnAmbassadorHeadshotKill;
	delete g_OnSandmanCleaverCombo;
	delete g_OnMeatshotKill;
	delete g_OnEnvironmentalKill;
	delete g_OnSandmanMoonshot;
	delete g_OnDoubleDonk;
}

void WeaponRevertsEvent_Fire(GlobalForward event, int attacker, int victim)
{
	if (event == null)
	{
		return;
	}

	Call_StartForward(event);
	Call_PushCell(attacker);
	Call_PushCell(victim);
	Call_Finish();
}

void FireAmbassadorHeadshotKill(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnAmbassadorHeadshotKill, attacker, victim); }
void FireSandmanCleaverCombo(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnSandmanCleaverCombo, attacker, victim); }
void FireMeatshotKill(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnMeatshotKill, attacker, victim); }
void FireEnvironmentalKill(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnEnvironmentalKill, attacker, victim); }
void FireSandmanMoonshot(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnSandmanMoonshot, attacker, victim); }
void FireDoubleDonk(int attacker, int victim) { WeaponRevertsEvent_Fire(g_OnDoubleDonk, attacker, victim); }

public void Event_PlayerHurt_DoubleDonk(Event event, const char[] name, bool dontBroadcast)
{
	if (event.GetInt("bonuseffect") != BONUS_EFFECT_DOUBLE_DONK)
	{
		return;
	}

	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!WR_IsClientInGame(attacker)
		|| !WR_IsClientInGame(victim)
		|| attacker == victim)
	{
		return;
	}

	FireDoubleDonk(attacker, victim);
}
