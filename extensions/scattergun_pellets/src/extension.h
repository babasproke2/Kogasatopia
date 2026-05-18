#ifndef _INCLUDE_SCATTERGUN_PELLETS_EXTENSION_H_
#define _INCLUDE_SCATTERGUN_PELLETS_EXTENSION_H_

#include "smsdk_ext.h"

#include <igameevents.h>

class CBaseEntity;
class CDmgAccumulator;
class CGameTrace;
class CTakeDamageInfo;

class ScattergunPellets : public SDKExtension, public IClientListener, public IGameEventListener2
{
public:
	bool SDK_OnLoad(char *error, size_t maxlen, bool late) override;
	void SDK_OnUnload() override;
	bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late) override;

	void OnClientPutInServer(int client) override;
	void OnClientDisconnecting(int client) override;
	void FireGameEvent(IGameEvent *event) override;

	void Hook_TraceAttack(const CTakeDamageInfo &info, const Vector &vecDir, CGameTrace *trace, CDmgAccumulator *accumulator);

	int GetLastKillPellets(int attacker, int victim) const;
	bool WasLastKillFull(int attacker, int victim) const;

private:
	bool SetupTraceAttackHook(char *error, size_t maxlen);
	void HookClient(int client);
	void UnhookClient(int client);
	void HookExistingClients();
	bool IsValidClientIndex(int client) const;
	bool IsDamageFromWeaponClass(const CTakeDamageInfo &info, int attacker, const char *classname, int &weapon) const;
	bool IsScattergunDamage(const CTakeDamageInfo &info, int attacker, int &weapon) const;
	bool IsShotgunDamage(const CTakeDamageInfo &info, int attacker, int &weapon) const;
	bool IsWeaponClass(CBaseEntity *weapon, const char *classname) const;
	CBaseEntity *GetActiveWeapon(int client) const;
	bool IsDuplicatePelletTrace(int attacker, int victim, CGameTrace *trace, int tick) const;
	bool RememberPelletTrace(int attacker, int victim, CGameTrace *trace, int tick);
	void RecordPelletHit(int attacker, int victim, CGameTrace *trace);
	void ClearPelletState();
	void DispatchPelletKillForward(int attacker, int victim, int pellets);
	void DispatchShotgunPelletHitForward(int attacker, int victim, int weapon);

private:
	IGameEventManager2 *m_gameEvents = nullptr;
	IGameConfig *m_gameConf = nullptr;
	IForward *m_pelletKillForward = nullptr;
	IForward *m_shotgunPelletHitForward = nullptr;
	int m_activeWeaponOffset = -1;

	int m_clientTraceHooks[SM_MAXPLAYERS + 1] = {};
	int m_pelletTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_pelletCount[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceHitbox[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceHitgroup[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	float m_lastTraceEnd[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1][3] = {};
	int m_lastKillTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastKillPellets[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
};

extern ScattergunPellets g_ScattergunPellets;

#endif
