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
	void OnGameFrame(bool simulating);

	void Hook_TraceAttack(const CTakeDamageInfo &info, const Vector &vecDir, CGameTrace *trace, CDmgAccumulator *accumulator);

	int GetLastKillPellets(int attacker, int victim) const;
	bool WasLastKillFull(int attacker, int victim) const;
	bool IsCurrentShotFull(int attacker, int victim, CBaseEntity *weapon) const;
	void SetWeaponPelletCount(CBaseEntity *weapon, int pelletsFired);

private:
	bool SetupTraceAttackHook(char *error, size_t maxlen);
	void HookClient(int client);
	void UnhookClient(int client);
	void HookExistingClients();
	bool IsValidClientIndex(int client) const;
	CBaseEntity *GetTrackedPelletWeapon(const CTakeDamageInfo &info, int attacker) const;
	bool IsTrackedPelletWeapon(CBaseEntity *weapon) const;
	CBaseEntity *GetActiveWeapon(int client) const;
	int GetWeaponPelletCount(CBaseEntity *weapon) const;
	bool IsDuplicatePelletTrace(int attacker, int victim, CGameTrace *trace, int tick) const;
	bool RememberPelletTrace(int attacker, int victim, CGameTrace *trace, int tick);
	void RecordPelletHit(
		int attacker, int victim, CBaseEntity *weapon, CGameTrace *trace, int pelletsFired);
	void ClearPelletShot(int attacker, int victim);
	void ClearPelletState();
	void DispatchPelletShotForward(
		int attacker, int victim, int pellets, int pelletsFired, bool kill);

private:
	IGameEventManager2 *m_gameEvents = nullptr;
	IGameConfig *m_gameConf = nullptr;
	IForward *m_pelletShotForward = nullptr;
	int m_activeWeaponOffset = -1;

	int m_clientTraceHooks[SM_MAXPLAYERS + 1] = {};
	int m_pelletTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_pelletCount[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_pelletTotal[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	cell_t m_pelletWeaponRefs[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceHitbox[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastTraceHitgroup[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	float m_lastTraceEnd[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1][3] = {};
	int m_lastKillTick[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastKillPellets[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};
	int m_lastKillTotal[SM_MAXPLAYERS + 1][SM_MAXPLAYERS + 1] = {};

	static constexpr int kMaxTrackedEntities = 2048;
	cell_t m_weaponRefs[kMaxTrackedEntities] = {};
	int m_weaponPelletCounts[kMaxTrackedEntities] = {};
};

extern ScattergunPellets g_ScattergunPellets;

#endif
