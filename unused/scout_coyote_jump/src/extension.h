#ifndef _INCLUDE_SCOUT_COYOTE_JUMP_EXTENSION_H_
#define _INCLUDE_SCOUT_COYOTE_JUMP_EXTENSION_H_

#include "smsdk_ext.h"

#include <IBinTools.h>
#include <IGameHelpers.h>
#include <CDetour/detours.h>

class CBaseEntity;
class CGameMovement;
class CMoveData;
class CGameTrace;
class CDetour;

class ScoutCoyoteJump : public SDKExtension, public IClientListener
{
public:
	bool SDK_OnLoad(char *error, size_t maxlen, bool late) override;
	void SDK_OnAllLoaded() override;
	void SDK_OnUnload() override;
	bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late) override;
	bool QueryRunning(char *error, size_t maxlen) override;
	bool QueryInterfaceDrop(SMInterface *iface) override;
	void NotifyInterfaceDrop(SMInterface *iface) override;

	void OnClientPutInServer(int client) override;
	void OnClientDisconnecting(int client) override;

	bool TryBeginCoyoteJump(void *movementThis);
	void FinishCoyoteJump(void *movementThis, bool applied, bool jumpAccepted);
	void OnMovementSetGroundEntity(void *movementThis, CGameTrace *trace);

	cell_t Native_GetCoyoteCount(IPluginContext *context, const cell_t *params);

private:
	bool SetupOffsets(char *error, size_t maxlen);
	bool SetupGameConfig(char *error, size_t maxlen);
	bool SetupDetours(char *error, size_t maxlen);
	bool SetupCalls(char *error, size_t maxlen);

	void ResetClientState(int client);
	bool IsValidClient(int client) const;
	CBaseEntity *GetClientEntity(int client) const;
	int GetClientFromEntity(CBaseEntity *entity) const;
	int GetClientFromMovement(void *movementThis) const;
	CMoveData *GetMoveData(void *movementThis) const;
	CBaseEntity *GetPlayerFromMovement(void *movementThis) const;

	bool IsScout(CBaseEntity *entity) const;
	int GetAirDash(CBaseEntity *entity) const;
	bool IsCurrentlyGrounded(CBaseEntity *entity, int client) const;
	bool HasUsableLastGround(int client) const;
	bool ShouldUseCoyoteJump(int client, CBaseEntity *player, CMoveData *move) const;
	bool CallEntitySetGroundEntity(CBaseEntity *player, CBaseEntity *ground);

	template <typename T>
	T ReadEntityOffset(CBaseEntity *entity, int offset) const
	{
		return *reinterpret_cast<T *>(reinterpret_cast<unsigned char *>(entity) + offset);
	}

private:
	SourceMod::IGameConfig *m_gameConf = nullptr;
	SourceMod::IBinTools *m_binTools = nullptr;
	SourceMod::ICallWrapper *m_entitySetGroundCall = nullptr;
	CDetour *m_checkJumpButtonDetour = nullptr;
	CDetour *m_movementSetGroundDetour = nullptr;

	int m_classOffset = -1;
	int m_airDashOffset = -1;
	int m_flagsOffset = -1;

	bool m_grounded[SM_MAXPLAYERS + 1] = {};
	bool m_usedCoyote[SM_MAXPLAYERS + 1] = {};
	float m_lastGroundTime[SM_MAXPLAYERS + 1] = {};
	cell_t m_lastGroundRef[SM_MAXPLAYERS + 1] = {};
	int m_coyoteJumpCount[SM_MAXPLAYERS + 1] = {};

	float m_coyoteWindow = 0.12f;
};

extern ScoutCoyoteJump g_ScoutCoyoteJump;

#endif
