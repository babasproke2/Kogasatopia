#ifndef _INCLUDE_CONCH_NO_SPEED_EXTENSION_H_
#define _INCLUDE_CONCH_NO_SPEED_EXTENSION_H_

#include "smsdk_ext.h"

#include <IBinTools.h>
#include <IGameHelpers.h>
#include <server_class.h>
#include <CDetour/detours.h>

class CBaseEntity;
class CDetour;

class ConchNoSpeed : public SDKExtension, public IClientListener
{
public:
	bool SDK_OnLoad(char *error, size_t maxlen, bool late) override;
	void SDK_OnAllLoaded() override;
	void SDK_OnUnload() override;
	bool QueryRunning(char *error, size_t maxlen) override;
	bool QueryInterfaceDrop(SMInterface *iface) override;
	void NotifyInterfaceDrop(SMInterface *iface) override;

	void OnClientDisconnecting(int client) override;

	cell_t Native_AddRegenBuff(IPluginContext *context, const cell_t *params);
	cell_t Native_RemoveRegenBuff(IPluginContext *context, const cell_t *params);
	cell_t Native_IsNoSpeedRegenBuff(IPluginContext *context, const cell_t *params);

	bool IsNoSpeedClient(int client) const;
	int GetClientFromShared(void *shared) const;
	bool ShouldBlockSpeedAdd(int client, int cond) const;
	bool ShouldWrapRegenAdd(int client, int cond) const;
	bool ShouldBlockSpeedRemove(int client, int cond) const;
	bool ShouldWrapRegenRemove(int client, int cond) const;
	void BeginBlockSpeedAdd(int client);
	void EndBlockSpeedAdd(int client);
	void BeginBlockSpeedRemove(int client);
	void EndBlockSpeedRemove(int client);
	void ClearNoSpeedClient(int client);

private:
	bool SetupSharedOffset(char *error, size_t maxlen);
	bool SetupGameConfig(char *error, size_t maxlen);
	bool SetupDetours(char *error, size_t maxlen);
	bool SetupCalls(IPluginContext *context);
	void CleanupNoSpeedConds();
	void ResetClientState(int client);

	CBaseEntity *GetClientEntity(int client) const;
	void *GetClientShared(int client) const;
	bool IsValidClient(int client) const;
	bool CallAddCond(void *shared, int cond, float duration, CBaseEntity *provider);
	bool CallRemoveCond(void *shared, int cond, bool ignoreDuration);

private:
	SourceMod::IGameConfig *m_gameConf = nullptr;
	SourceMod::IBinTools *m_binTools = nullptr;
	SourceMod::ICallWrapper *m_addCondCall = nullptr;
	SourceMod::ICallWrapper *m_removeCondCall = nullptr;
	CDetour *m_addCondDetour = nullptr;
	CDetour *m_removeCondDetour = nullptr;
	sm_sendprop_info_t m_playerSharedOffset = {};

	bool m_noSpeedRegen[SM_MAXPLAYERS + 1] = {};
	int m_blockSpeedAddDepth[SM_MAXPLAYERS + 1] = {};
	int m_blockSpeedRemoveDepth[SM_MAXPLAYERS + 1] = {};
};

extern ConchNoSpeed g_ConchNoSpeed;

#endif
