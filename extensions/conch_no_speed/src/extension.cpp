#include "extension.h"

#include <string.h>

#include <eiface.h>
#include <edict.h>
#include <dt_send.h>
#include <IGameHelpers.h>
#include <sm_argbuffer.h>

static constexpr int TF_COND_REGENONDAMAGEBUFF = 29;
static constexpr int TF_COND_SPEED_BOOST = 32;

ConchNoSpeed g_ConchNoSpeed;
SMEXT_LINK(&g_ConchNoSpeed);

static bool FindDataTable(SendTable *table, const char *name, sm_sendprop_info_t *info, unsigned int offset = 0)
{
	if (!table)
	{
		return false;
	}

	for (int i = 0; i < table->GetNumProps(); ++i)
	{
		SendProp *prop = table->GetProp(i);
		if (!prop)
		{
			continue;
		}

		SendTable *child = prop->GetDataTable();
		if (!child)
		{
			continue;
		}

		const char *childName = child->GetName();
		if (childName && strcmp(childName, name) == 0)
		{
			info->prop = prop;
			info->actual_offset = offset + prop->GetOffset();
			return true;
		}

		if (FindDataTable(child, name, info, offset + prop->GetOffset()))
		{
			return true;
		}
	}

	return false;
}

static ServerClass *FindServerClass(const char *classname)
{
	ServerClass *serverClass = gamedll->GetAllServerClasses();
	while (serverClass)
	{
		if (strcmp(serverClass->GetName(), classname) == 0)
		{
			return serverClass;
		}

		serverClass = serverClass->m_pNext;
	}

	return nullptr;
}

DETOUR_DECL_MEMBER3(Detour_AddCond, void, int, cond, float, duration, CBaseEntity *, provider)
{
	const int client = g_ConchNoSpeed.GetClientFromShared(this);
	if (g_ConchNoSpeed.ShouldBlockSpeedAdd(client, cond))
	{
		return;
	}

	if (g_ConchNoSpeed.ShouldWrapRegenAdd(client, cond))
	{
		g_ConchNoSpeed.BeginBlockSpeedAdd(client);
		DETOUR_MEMBER_CALL(Detour_AddCond)(cond, duration, provider);
		g_ConchNoSpeed.EndBlockSpeedAdd(client);
		return;
	}

	DETOUR_MEMBER_CALL(Detour_AddCond)(cond, duration, provider);
}

DETOUR_DECL_MEMBER2(Detour_RemoveCond, void, int, cond, bool, ignoreDuration)
{
	const int client = g_ConchNoSpeed.GetClientFromShared(this);
	if (g_ConchNoSpeed.ShouldBlockSpeedRemove(client, cond))
	{
		return;
	}

	if (g_ConchNoSpeed.ShouldWrapRegenRemove(client, cond))
	{
		g_ConchNoSpeed.BeginBlockSpeedRemove(client);
		DETOUR_MEMBER_CALL(Detour_RemoveCond)(cond, ignoreDuration);
		g_ConchNoSpeed.EndBlockSpeedRemove(client);
		g_ConchNoSpeed.ClearNoSpeedClient(client);
		return;
	}

	DETOUR_MEMBER_CALL(Detour_RemoveCond)(cond, ignoreDuration);
}

static cell_t Native_AddRegenBuff(IPluginContext *context, const cell_t *params)
{
	return g_ConchNoSpeed.Native_AddRegenBuff(context, params);
}

static cell_t Native_RemoveRegenBuff(IPluginContext *context, const cell_t *params)
{
	return g_ConchNoSpeed.Native_RemoveRegenBuff(context, params);
}

static cell_t Native_IsNoSpeedRegenBuff(IPluginContext *context, const cell_t *params)
{
	return g_ConchNoSpeed.Native_IsNoSpeedRegenBuff(context, params);
}

static sp_nativeinfo_t g_Natives[] =
{
	{"TF2ConchNoSpeed_AddRegenBuff", Native_AddRegenBuff},
	{"TF2ConchNoSpeed_RemoveRegenBuff", Native_RemoveRegenBuff},
	{"TF2ConchNoSpeed_IsRegenBuffActive", Native_IsNoSpeedRegenBuff},
	{nullptr, nullptr},
};

bool ConchNoSpeed::SDK_OnLoad(char *error, size_t maxlen, bool late)
{
	if (strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
	{
		g_pSM->Format(error, maxlen, "Conch No Speed only supports Team Fortress 2.");
		return false;
	}

	sharesys->AddDependency(myself, "bintools.ext", true, true);
	SM_GET_LATE_IFACE(BINTOOLS, m_binTools);

	if (!SetupSharedOffset(error, maxlen) ||
		!SetupGameConfig(error, maxlen) ||
		!SetupDetours(error, maxlen))
	{
		return false;
	}

	sharesys->AddNatives(myself, g_Natives);
	sharesys->RegisterLibrary(myself, "conch_no_speed");
	playerhelpers->AddClientListener(this);

	(void)late;
	return true;
}

void ConchNoSpeed::SDK_OnAllLoaded()
{
	SM_GET_LATE_IFACE(BINTOOLS, m_binTools);
}

void ConchNoSpeed::SDK_OnUnload()
{
	CleanupNoSpeedConds();
	playerhelpers->RemoveClientListener(this);

	if (m_addCondDetour)
	{
		m_addCondDetour->DisableDetour();
		m_addCondDetour->Destroy();
		m_addCondDetour = nullptr;
	}

	if (m_removeCondDetour)
	{
		m_removeCondDetour->DisableDetour();
		m_removeCondDetour->Destroy();
		m_removeCondDetour = nullptr;
	}

	if (m_addCondCall)
	{
		m_addCondCall->Destroy();
		m_addCondCall = nullptr;
	}

	if (m_removeCondCall)
	{
		m_removeCondCall->Destroy();
		m_removeCondCall = nullptr;
	}

	if (m_gameConf)
	{
		gameconfs->CloseGameConfigFile(m_gameConf);
		m_gameConf = nullptr;
	}
}

bool ConchNoSpeed::QueryRunning(char *error, size_t maxlen)
{
	if (!m_binTools)
	{
		g_pSM->Format(error, maxlen, "BinTools is not available.");
		return false;
	}

	return true;
}

bool ConchNoSpeed::QueryInterfaceDrop(SMInterface *iface)
{
	if (iface == m_binTools)
	{
		return false;
	}

	return IExtensionInterface::QueryInterfaceDrop(iface);
}

void ConchNoSpeed::NotifyInterfaceDrop(SMInterface *iface)
{
	if (iface == m_binTools)
	{
		m_binTools = nullptr;
	}
}

void ConchNoSpeed::OnClientDisconnecting(int client)
{
	ResetClientState(client);
}

cell_t ConchNoSpeed::Native_AddRegenBuff(IPluginContext *context, const cell_t *params)
{
	const int client = params[1];
	if (!IsValidClient(client))
	{
		return context->ThrowNativeError("Client index %d is not valid or not in game.", client);
	}

	if (!SetupCalls(context))
	{
		return 0;
	}

	CBaseEntity *provider = nullptr;
	if (params[0] >= 3 && params[3] > 0)
	{
		if (!IsValidClient(params[3]))
		{
			return context->ThrowNativeError("Provider client index %d is not valid or not in game.", params[3]);
		}

		provider = GetClientEntity(params[3]);
	}

	void *shared = GetClientShared(client);
	if (!shared)
	{
		return context->ThrowNativeError("Could not resolve CTFPlayerShared for client %d.", client);
	}

	m_noSpeedRegen[client] = true;
	if (!CallAddCond(shared, TF_COND_REGENONDAMAGEBUFF, sp_ctof(params[2]), provider))
	{
		m_noSpeedRegen[client] = false;
		return context->ThrowNativeError("Failed to call CTFPlayerShared::AddCond.");
	}

	return 1;
}

cell_t ConchNoSpeed::Native_RemoveRegenBuff(IPluginContext *context, const cell_t *params)
{
	const int client = params[1];
	if (!IsValidClient(client))
	{
		return context->ThrowNativeError("Client index %d is not valid or not in game.", client);
	}

	if (!SetupCalls(context))
	{
		return 0;
	}

	void *shared = GetClientShared(client);
	if (!shared)
	{
		return context->ThrowNativeError("Could not resolve CTFPlayerShared for client %d.", client);
	}

	CallRemoveCond(shared, TF_COND_REGENONDAMAGEBUFF, true);
	m_noSpeedRegen[client] = false;
	return 1;
}

cell_t ConchNoSpeed::Native_IsNoSpeedRegenBuff(IPluginContext *context, const cell_t *params)
{
	const int client = params[1];
	if (client < 1 || client > SM_MAXPLAYERS)
	{
		return context->ThrowNativeError("Client index %d is out of range.", client);
	}

	return m_noSpeedRegen[client] ? 1 : 0;
}

bool ConchNoSpeed::IsNoSpeedClient(int client) const
{
	return client >= 1 && client <= SM_MAXPLAYERS && m_noSpeedRegen[client];
}

bool ConchNoSpeed::ShouldBlockSpeedAdd(int client, int cond) const
{
	return client > 0 && cond == TF_COND_SPEED_BOOST && m_blockSpeedAddDepth[client] > 0;
}

bool ConchNoSpeed::ShouldWrapRegenAdd(int client, int cond) const
{
	return client > 0 && cond == TF_COND_REGENONDAMAGEBUFF && m_noSpeedRegen[client];
}

bool ConchNoSpeed::ShouldBlockSpeedRemove(int client, int cond) const
{
	return client > 0 && cond == TF_COND_SPEED_BOOST && m_blockSpeedRemoveDepth[client] > 0;
}

bool ConchNoSpeed::ShouldWrapRegenRemove(int client, int cond) const
{
	return client > 0 && cond == TF_COND_REGENONDAMAGEBUFF && m_noSpeedRegen[client];
}

void ConchNoSpeed::BeginBlockSpeedAdd(int client)
{
	if (client > 0 && client <= SM_MAXPLAYERS)
	{
		++m_blockSpeedAddDepth[client];
	}
}

void ConchNoSpeed::EndBlockSpeedAdd(int client)
{
	if (client > 0 && client <= SM_MAXPLAYERS && m_blockSpeedAddDepth[client] > 0)
	{
		--m_blockSpeedAddDepth[client];
	}
}

void ConchNoSpeed::BeginBlockSpeedRemove(int client)
{
	if (client > 0 && client <= SM_MAXPLAYERS)
	{
		++m_blockSpeedRemoveDepth[client];
	}
}

void ConchNoSpeed::EndBlockSpeedRemove(int client)
{
	if (client > 0 && client <= SM_MAXPLAYERS && m_blockSpeedRemoveDepth[client] > 0)
	{
		--m_blockSpeedRemoveDepth[client];
	}
}

void ConchNoSpeed::ClearNoSpeedClient(int client)
{
	if (client > 0 && client <= SM_MAXPLAYERS)
	{
		m_noSpeedRegen[client] = false;
	}
}

bool ConchNoSpeed::SetupSharedOffset(char *error, size_t maxlen)
{
	ServerClass *serverClass = FindServerClass("CTFPlayer");
	if (!serverClass)
	{
		g_pSM->Format(error, maxlen, "Could not find CTFPlayer server class.");
		return false;
	}

	if (!FindDataTable(serverClass->m_pTable, "DT_TFPlayerShared", &m_playerSharedOffset))
	{
		g_pSM->Format(error, maxlen, "Could not find DT_TFPlayerShared data table.");
		return false;
	}

	return true;
}

bool ConchNoSpeed::SetupGameConfig(char *error, size_t maxlen)
{
	char confError[255] = "";
	if (!gameconfs->LoadGameConfigFile("conch_no_speed.games", &m_gameConf, confError, sizeof(confError)))
	{
		if (confError[0])
		{
			g_pSM->Format(error, maxlen, "Could not read conch_no_speed.games.txt: %s", confError);
		}
		else
		{
			g_pSM->Format(error, maxlen, "Could not read conch_no_speed.games.txt.");
		}
		return false;
	}

	CDetourManager::Init(g_pSM->GetScriptingEngine(), m_gameConf);
	return true;
}

bool ConchNoSpeed::SetupDetours(char *error, size_t maxlen)
{
	m_addCondDetour = DETOUR_CREATE_MEMBER(Detour_AddCond, "AddCondition");
	if (!m_addCondDetour)
	{
		g_pSM->Format(error, maxlen, "Could not create AddCondition detour.");
		return false;
	}

	m_removeCondDetour = DETOUR_CREATE_MEMBER(Detour_RemoveCond, "RemoveCondition");
	if (!m_removeCondDetour)
	{
		g_pSM->Format(error, maxlen, "Could not create RemoveCondition detour.");
		return false;
	}

	m_addCondDetour->EnableDetour();
	m_removeCondDetour->EnableDetour();
	return true;
}

bool ConchNoSpeed::SetupCalls(IPluginContext *context)
{
	if (!m_binTools)
	{
		SM_GET_LATE_IFACE(BINTOOLS, m_binTools);
	}

	if (!m_binTools)
	{
		context->ThrowNativeError("BinTools is not available.");
		return false;
	}

	if (!m_addCondCall)
	{
		void *addr = nullptr;
		if (!m_gameConf->GetMemSig("AddCondition", &addr) || !addr)
		{
			context->ThrowNativeError("Failed to locate CTFPlayerShared::AddCond.");
			return false;
		}

		PassInfo pass[3];
		pass[0].flags = PASSFLAG_BYVAL;
		pass[0].size = sizeof(int);
		pass[0].type = PassType_Basic;
		pass[1].flags = PASSFLAG_BYVAL;
		pass[1].size = sizeof(float);
		pass[1].type = PassType_Float;
		pass[2].flags = PASSFLAG_BYVAL;
		pass[2].size = sizeof(CBaseEntity *);
		pass[2].type = PassType_Basic;

		m_addCondCall = m_binTools->CreateCall(addr, CallConv_ThisCall, nullptr, pass, 3);
		if (!m_addCondCall)
		{
			context->ThrowNativeError("Failed to create CTFPlayerShared::AddCond call wrapper.");
			return false;
		}
	}

	if (!m_removeCondCall)
	{
		void *addr = nullptr;
		if (!m_gameConf->GetMemSig("RemoveCondition", &addr) || !addr)
		{
			context->ThrowNativeError("Failed to locate CTFPlayerShared::RemoveCond.");
			return false;
		}

		PassInfo pass[2];
		pass[0].flags = PASSFLAG_BYVAL;
		pass[0].size = sizeof(int);
		pass[0].type = PassType_Basic;
		pass[1].flags = PASSFLAG_BYVAL;
		pass[1].size = sizeof(bool);
		pass[1].type = PassType_Basic;

		m_removeCondCall = m_binTools->CreateCall(addr, CallConv_ThisCall, nullptr, pass, 2);
		if (!m_removeCondCall)
		{
			context->ThrowNativeError("Failed to create CTFPlayerShared::RemoveCond call wrapper.");
			return false;
		}
	}

	return true;
}

void ConchNoSpeed::CleanupNoSpeedConds()
{
	for (int client = 1; client <= SM_MAXPLAYERS; ++client)
	{
		if (!m_noSpeedRegen[client])
		{
			continue;
		}

		void *shared = GetClientShared(client);
		if (shared && m_removeCondCall)
		{
			CallRemoveCond(shared, TF_COND_REGENONDAMAGEBUFF, true);
		}

		ResetClientState(client);
	}
}

void ConchNoSpeed::ResetClientState(int client)
{
	if (client < 1 || client > SM_MAXPLAYERS)
	{
		return;
	}

	m_noSpeedRegen[client] = false;
	m_blockSpeedAddDepth[client] = 0;
	m_blockSpeedRemoveDepth[client] = 0;
}

CBaseEntity *ConchNoSpeed::GetClientEntity(int client) const
{
	if (!IsValidClient(client))
	{
		return nullptr;
	}

	IGamePlayer *player = playerhelpers->GetGamePlayer(client);
	if (!player)
	{
		return nullptr;
	}

	edict_t *edict = player->GetEdict();
	if (!edict || edict->IsFree() || !edict->GetUnknown())
	{
		return nullptr;
	}

	return edict->GetUnknown()->GetBaseEntity();
}

void *ConchNoSpeed::GetClientShared(int client) const
{
	CBaseEntity *entity = GetClientEntity(client);
	if (!entity)
	{
		return nullptr;
	}

	return reinterpret_cast<unsigned char *>(entity) + m_playerSharedOffset.actual_offset;
}

int ConchNoSpeed::GetClientFromShared(void *shared) const
{
	if (!shared)
	{
		return 0;
	}

	const int maxClients = playerhelpers->GetMaxClients();
	for (int client = 1; client <= maxClients; ++client)
	{
		if (GetClientShared(client) == shared)
		{
			return client;
		}
	}

	return 0;
}

bool ConchNoSpeed::IsValidClient(int client) const
{
	if (client < 1 || client > playerhelpers->GetMaxClients())
	{
		return false;
	}

	IGamePlayer *player = playerhelpers->GetGamePlayer(client);
	return player && player->IsInGame();
}

bool ConchNoSpeed::CallAddCond(void *shared, int cond, float duration, CBaseEntity *provider)
{
	if (!m_addCondCall)
	{
		return false;
	}

	ArgBuffer<void *, int, float, CBaseEntity *> args(shared, cond, duration, provider);
	m_addCondCall->Execute(args, nullptr);
	return true;
}

bool ConchNoSpeed::CallRemoveCond(void *shared, int cond, bool ignoreDuration)
{
	if (!m_removeCondCall)
	{
		return false;
	}

	ArgBuffer<void *, int, bool> args(shared, cond, ignoreDuration);
	m_removeCondCall->Execute(args, nullptr);
	return true;
}
