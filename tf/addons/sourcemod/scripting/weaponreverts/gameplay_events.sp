GlobalForward g_OnAmbassadorHeadshotKill = null;
GlobalForward g_OnSandmanCleaverCombo = null;
GlobalForward g_OnMeatshotKill = null;
GlobalForward g_OnEnvironmentalKill = null;
GlobalForward g_OnSandmanMoonshot = null;

void WeaponRevertsEvents_Init()
{
	WeaponRevertsEvents_Shutdown();
	g_OnAmbassadorHeadshotKill = new GlobalForward("OnAmbassadorHeadshotKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnSandmanCleaverCombo = new GlobalForward("OnSandmanCleaverCombo", ET_Ignore, Param_Cell, Param_Cell);
	g_OnMeatshotKill = new GlobalForward("OnMeatshotKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnEnvironmentalKill = new GlobalForward("OnEnvironmentalKill", ET_Ignore, Param_Cell, Param_Cell);
	g_OnSandmanMoonshot = new GlobalForward("OnSandmanMoonshot", ET_Ignore, Param_Cell, Param_Cell);
}

void WeaponRevertsEvents_Shutdown()
{
	delete g_OnAmbassadorHeadshotKill;
	delete g_OnSandmanCleaverCombo;
	delete g_OnMeatshotKill;
	delete g_OnEnvironmentalKill;
	delete g_OnSandmanMoonshot;
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
