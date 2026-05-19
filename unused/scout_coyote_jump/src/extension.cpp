#include "extension.h"

#include <string.h>

#include <edict.h>
#include <eiface.h>
#include <gametrace.h>
#include <in_buttons.h>
#include <const.h>
#include <sm_argbuffer.h>

static constexpr int TF_CLASS_SCOUT = 1;
static constexpr cell_t INVALID_ENTITY_REFERENCE = -1;
static constexpr int MOVE_DATA_BUTTONS_OFFSET = 36;
static constexpr int MOVE_DATA_OLD_BUTTONS_OFFSET = 40;

struct GameMovementView
{
	void *vtable;
	CBaseEntity *player;
	CMoveData *move;
};

ScoutCoyoteJump g_ScoutCoyoteJump;
SMEXT_LINK(&g_ScoutCoyoteJump);

CGlobalVars *gpGlobals = nullptr;

DETOUR_DECL_MEMBER0(Detour_CheckJumpButton, bool)
{
	const bool applied = g_ScoutCoyoteJump.TryBeginCoyoteJump(this);
	const bool accepted = DETOUR_MEMBER_CALL(Detour_CheckJumpButton)();
	g_ScoutCoyoteJump.FinishCoyoteJump(this, applied, accepted);
	return accepted;
}

DETOUR_DECL_MEMBER1(Detour_MovementSetGroundEntity, void, CGameTrace *, trace)
{
	DETOUR_MEMBER_CALL(Detour_MovementSetGroundEntity)(trace);
	g_ScoutCoyoteJump.OnMovementSetGroundEntity(this, trace);
}

static cell_t Native_GetCoyoteCount(IPluginContext *context, const cell_t *params)
{
	return g_ScoutCoyoteJump.Native_GetCoyoteCount(context, params);
}

static sp_nativeinfo_t g_Natives[] =
{
	{"TF2ScoutCoyote_GetCoyoteCount", Native_GetCoyoteCount},
	{nullptr, nullptr},
};

bool ScoutCoyoteJump::SDK_OnLoad(char *error, size_t maxlen, bool late)
{
	if (strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
	{
		g_pSM->Format(error, maxlen, "Scout Coyote Jump only supports Team Fortress 2.");
		return false;
	}

	sharesys->AddDependency(myself, "bintools.ext", true, true);
	SM_GET_LATE_IFACE(BINTOOLS, m_binTools);

	if (!SetupOffsets(error, maxlen) ||
		!SetupGameConfig(error, maxlen) ||
		!SetupCalls(error, maxlen) ||
		!SetupDetours(error, maxlen))
	{
		return false;
	}

	sharesys->AddNatives(myself, g_Natives);
	sharesys->RegisterLibrary(myself, "scout_coyote_jump");
	playerhelpers->AddClientListener(this);

	for (int client = 1; client <= SM_MAXPLAYERS; ++client)
	{
		ResetClientState(client);
	}

	if (late)
	{
		for (int client = 1; client <= playerhelpers->GetMaxClients(); ++client)
		{
			OnClientPutInServer(client);
		}
	}

	return true;
}

void ScoutCoyoteJump::SDK_OnAllLoaded()
{
	SM_GET_LATE_IFACE(BINTOOLS, m_binTools);
}

void ScoutCoyoteJump::SDK_OnUnload()
{
	playerhelpers->RemoveClientListener(this);

	if (m_checkJumpButtonDetour)
	{
		m_checkJumpButtonDetour->DisableDetour();
		m_checkJumpButtonDetour->Destroy();
		m_checkJumpButtonDetour = nullptr;
	}

	if (m_movementSetGroundDetour)
	{
		m_movementSetGroundDetour->DisableDetour();
		m_movementSetGroundDetour->Destroy();
		m_movementSetGroundDetour = nullptr;
	}

	if (m_entitySetGroundCall)
	{
		m_entitySetGroundCall->Destroy();
		m_entitySetGroundCall = nullptr;
	}

	if (m_gameConf)
	{
		gameconfs->CloseGameConfigFile(m_gameConf);
		m_gameConf = nullptr;
	}
}

bool ScoutCoyoteJump::SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late)
{
	(void)error;
	(void)maxlen;
	(void)late;

	gpGlobals = ismm->GetCGlobals();
	return true;
}

bool ScoutCoyoteJump::QueryRunning(char *error, size_t maxlen)
{
	if (!m_binTools)
	{
		g_pSM->Format(error, maxlen, "BinTools is not available.");
		return false;
	}

	return true;
}

bool ScoutCoyoteJump::QueryInterfaceDrop(SMInterface *iface)
{
	if (iface == m_binTools)
	{
		return false;
	}

	return IExtensionInterface::QueryInterfaceDrop(iface);
}

void ScoutCoyoteJump::NotifyInterfaceDrop(SMInterface *iface)
{
	if (iface == m_binTools)
	{
		m_binTools = nullptr;
	}
}

void ScoutCoyoteJump::OnClientPutInServer(int client)
{
	ResetClientState(client);
}

void ScoutCoyoteJump::OnClientDisconnecting(int client)
{
	ResetClientState(client);
}

bool ScoutCoyoteJump::TryBeginCoyoteJump(void *movementThis)
{
	CBaseEntity *player = GetPlayerFromMovement(movementThis);
	CMoveData *move = GetMoveData(movementThis);
	const int client = GetClientFromEntity(player);

	if (!ShouldUseCoyoteJump(client, player, move))
	{
		return false;
	}

	CBaseEntity *ground = gamehelpers->ReferenceToEntity(m_lastGroundRef[client]);
	if (!ground)
	{
		ground = gamehelpers->ReferenceToEntity(0);
	}

	if (!ground || !CallEntitySetGroundEntity(player, ground))
	{
		return false;
	}

	m_grounded[client] = true;
	return true;
}

void ScoutCoyoteJump::FinishCoyoteJump(void *movementThis, bool applied, bool jumpAccepted)
{
	if (!applied)
	{
		return;
	}

	CBaseEntity *player = GetPlayerFromMovement(movementThis);
	const int client = GetClientFromEntity(player);
	if (!IsValidClient(client))
	{
		return;
	}

	if (jumpAccepted)
	{
		m_usedCoyote[client] = true;
		m_lastGroundTime[client] = 0.0f;
		++m_coyoteJumpCount[client];
	}

	if (!jumpAccepted || IsCurrentlyGrounded(player, client))
	{
		CallEntitySetGroundEntity(player, nullptr);
		m_grounded[client] = false;
	}
}

void ScoutCoyoteJump::OnMovementSetGroundEntity(void *movementThis, CGameTrace *trace)
{
	CBaseEntity *player = GetPlayerFromMovement(movementThis);
	const int client = GetClientFromEntity(player);
	if (!IsValidClient(client))
	{
		return;
	}

	CBaseEntity *ground = (trace != nullptr) ? trace->m_pEnt : nullptr;
	if (ground)
	{
		m_grounded[client] = true;
		m_usedCoyote[client] = false;
		m_lastGroundTime[client] = gpGlobals ? gpGlobals->curtime : 0.0f;
		m_lastGroundRef[client] = gamehelpers->EntityToReference(ground);
	}
	else
	{
		m_grounded[client] = false;
	}
}

cell_t ScoutCoyoteJump::Native_GetCoyoteCount(IPluginContext *context, const cell_t *params)
{
	const int client = params[1];
	if (client < 1 || client > SM_MAXPLAYERS)
	{
		return context->ThrowNativeError("Client index %d is out of range.", client);
	}

	return m_coyoteJumpCount[client];
}

bool ScoutCoyoteJump::SetupOffsets(char *error, size_t maxlen)
{
	sm_sendprop_info_t info;
	if (!gamehelpers->FindSendPropInfo("CTFPlayer", "m_iClass", &info))
	{
		g_pSM->Format(error, maxlen, "Could not find CTFPlayer::m_iClass sendprop.");
		return false;
	}
	m_classOffset = info.actual_offset;

	if (!gamehelpers->FindSendPropInfo("CTFPlayer", "m_iAirDash", &info))
	{
		g_pSM->Format(error, maxlen, "Could not find CTFPlayer::m_iAirDash sendprop.");
		return false;
	}
	m_airDashOffset = info.actual_offset;

	if (!gamehelpers->FindSendPropInfo("CTFPlayer", "m_fFlags", &info))
	{
		g_pSM->Format(error, maxlen, "Could not find CTFPlayer::m_fFlags sendprop.");
		return false;
	}
	m_flagsOffset = info.actual_offset;

	return true;
}

bool ScoutCoyoteJump::SetupGameConfig(char *error, size_t maxlen)
{
	char confError[255] = "";
	if (!gameconfs->LoadGameConfigFile("scout_coyote_jump.games", &m_gameConf, confError, sizeof(confError)))
	{
		if (confError[0])
		{
			g_pSM->Format(error, maxlen, "Could not read scout_coyote_jump.games.txt: %s", confError);
		}
		else
		{
			g_pSM->Format(error, maxlen, "Could not read scout_coyote_jump.games.txt.");
		}
		return false;
	}

	CDetourManager::Init(g_pSM->GetScriptingEngine(), m_gameConf);
	return true;
}

bool ScoutCoyoteJump::SetupDetours(char *error, size_t maxlen)
{
	m_checkJumpButtonDetour = DETOUR_CREATE_MEMBER(Detour_CheckJumpButton, "CheckJumpButton");
	if (!m_checkJumpButtonDetour)
	{
		g_pSM->Format(error, maxlen, "Could not create CTFGameMovement::CheckJumpButton detour.");
		return false;
	}

	m_movementSetGroundDetour = DETOUR_CREATE_MEMBER(Detour_MovementSetGroundEntity, "MovementSetGroundEntity");
	if (!m_movementSetGroundDetour)
	{
		g_pSM->Format(error, maxlen, "Could not create CTFGameMovement::SetGroundEntity detour.");
		return false;
	}

	m_checkJumpButtonDetour->EnableDetour();
	m_movementSetGroundDetour->EnableDetour();
	return true;
}

bool ScoutCoyoteJump::SetupCalls(char *error, size_t maxlen)
{
	if (!m_binTools)
	{
		SM_GET_LATE_IFACE(BINTOOLS, m_binTools);
	}

	if (!m_binTools)
	{
		g_pSM->Format(error, maxlen, "BinTools is not available.");
		return false;
	}

	void *addr = nullptr;
	if (!m_gameConf->GetMemSig("EntitySetGroundEntity", &addr) || !addr)
	{
		g_pSM->Format(error, maxlen, "Failed to locate CBaseEntity::SetGroundEntity.");
		return false;
	}

	PassInfo pass[1];
	pass[0].flags = PASSFLAG_BYVAL;
	pass[0].size = sizeof(CBaseEntity *);
	pass[0].type = PassType_Basic;

	m_entitySetGroundCall = m_binTools->CreateCall(addr, CallConv_ThisCall, nullptr, pass, 1);
	if (!m_entitySetGroundCall)
	{
		g_pSM->Format(error, maxlen, "Failed to create CBaseEntity::SetGroundEntity call wrapper.");
		return false;
	}

	return true;
}

void ScoutCoyoteJump::ResetClientState(int client)
{
	if (client < 1 || client > SM_MAXPLAYERS)
	{
		return;
	}

	m_grounded[client] = false;
	m_usedCoyote[client] = false;
	m_lastGroundTime[client] = 0.0f;
	m_lastGroundRef[client] = INVALID_ENTITY_REFERENCE;
	m_coyoteJumpCount[client] = 0;
}

bool ScoutCoyoteJump::IsValidClient(int client) const
{
	if (client < 1 || client > playerhelpers->GetMaxClients())
	{
		return false;
	}

	IGamePlayer *player = playerhelpers->GetGamePlayer(client);
	return player && player->IsInGame();
}

CBaseEntity *ScoutCoyoteJump::GetClientEntity(int client) const
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

int ScoutCoyoteJump::GetClientFromEntity(CBaseEntity *entity) const
{
	if (!entity)
	{
		return 0;
	}

	const int maxClients = playerhelpers->GetMaxClients();
	for (int client = 1; client <= maxClients; ++client)
	{
		if (GetClientEntity(client) == entity)
		{
			return client;
		}
	}

	return 0;
}

int ScoutCoyoteJump::GetClientFromMovement(void *movementThis) const
{
	return GetClientFromEntity(GetPlayerFromMovement(movementThis));
}

CMoveData *ScoutCoyoteJump::GetMoveData(void *movementThis) const
{
	if (!movementThis)
	{
		return nullptr;
	}

	GameMovementView *movement = reinterpret_cast<GameMovementView *>(movementThis);
	return movement->move;
}

CBaseEntity *ScoutCoyoteJump::GetPlayerFromMovement(void *movementThis) const
{
	if (!movementThis)
	{
		return nullptr;
	}

	GameMovementView *movement = reinterpret_cast<GameMovementView *>(movementThis);
	return movement->player;
}

bool ScoutCoyoteJump::IsScout(CBaseEntity *entity) const
{
	return entity && m_classOffset >= 0 && ReadEntityOffset<int>(entity, m_classOffset) == TF_CLASS_SCOUT;
}

int ScoutCoyoteJump::GetAirDash(CBaseEntity *entity) const
{
	if (!entity || m_airDashOffset < 0)
	{
		return -1;
	}

	return ReadEntityOffset<int>(entity, m_airDashOffset);
}

bool ScoutCoyoteJump::IsCurrentlyGrounded(CBaseEntity *entity, int client) const
{
	if (entity && m_flagsOffset >= 0)
	{
		const int flags = ReadEntityOffset<int>(entity, m_flagsOffset);
		return (flags & FL_ONGROUND) != 0;
	}

	return client >= 1 && client <= SM_MAXPLAYERS && m_grounded[client];
}

bool ScoutCoyoteJump::HasUsableLastGround(int client) const
{
	return client >= 1 &&
		client <= SM_MAXPLAYERS &&
		m_lastGroundTime[client] > 0.0f &&
		m_lastGroundRef[client] != INVALID_ENTITY_REFERENCE;
}

bool ScoutCoyoteJump::ShouldUseCoyoteJump(int client, CBaseEntity *player, CMoveData *move) const
{
	if (!gpGlobals || !IsValidClient(client) || !player || !move)
	{
		return false;
	}

	const int buttons = *reinterpret_cast<int *>(reinterpret_cast<unsigned char *>(move) + MOVE_DATA_BUTTONS_OFFSET);
	const int oldButtons = *reinterpret_cast<int *>(reinterpret_cast<unsigned char *>(move) + MOVE_DATA_OLD_BUTTONS_OFFSET);
	if (!(buttons & IN_JUMP) || (oldButtons & IN_JUMP))
	{
		return false;
	}

	if (m_usedCoyote[client] || IsCurrentlyGrounded(player, client))
	{
		return false;
	}

	if (!IsScout(player) || GetAirDash(player) != 0 || !HasUsableLastGround(client))
	{
		return false;
	}

	const float elapsed = gpGlobals->curtime - m_lastGroundTime[client];
	return elapsed >= 0.0f && elapsed <= m_coyoteWindow;
}

bool ScoutCoyoteJump::CallEntitySetGroundEntity(CBaseEntity *player, CBaseEntity *ground)
{
	if (!m_entitySetGroundCall || !player)
	{
		return false;
	}

	ArgBuffer<CBaseEntity *, CBaseEntity *> args(player, ground);
	m_entitySetGroundCall->Execute(args, nullptr);
	return true;
}
