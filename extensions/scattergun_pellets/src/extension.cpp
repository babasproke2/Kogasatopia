#include "extension.h"

#include <string.h>

#include <edict.h>
#include <eiface.h>
#include <isaverestore.h>
#include <ehandle.h>
#include <shareddefs.h>
#include <takedamageinfo.h>

static constexpr int kScattergunPelletsPerShot = 10;
static constexpr int kPelletKillTickWindow = 8;
ScattergunPellets g_ScattergunPellets;
SMEXT_LINK(&g_ScattergunPellets);

CGlobalVars *gpGlobals = nullptr;

SH_DECL_MANUALHOOK4_void(TraceAttack, 0, 0, 0, const CTakeDamageInfo &, const Vector &, CGameTrace *, CDmgAccumulator *);

class CTakeDamageInfoPelletView : public CTakeDamageInfo
{
public:
	int GetAttackerIndex() const
	{
		return m_hAttacker.IsValid() ? m_hAttacker.GetEntryIndex() : -1;
	}

	int GetWeaponIndex() const
	{
		return m_hWeapon.IsValid() ? m_hWeapon.GetEntryIndex() : -1;
	}
};

static cell_t Native_GetLastKillPellets(IPluginContext *context, const cell_t *params)
{
	return g_ScattergunPellets.GetLastKillPellets(params[1], params[2]);
}

static cell_t Native_WasLastKillFull(IPluginContext *context, const cell_t *params)
{
	return g_ScattergunPellets.WasLastKillFull(params[1], params[2]) ? 1 : 0;
}

static sp_nativeinfo_t g_Natives[] =
{
	{"TF2Scatter_GetLastKillPellets", Native_GetLastKillPellets},
	{"TF2Scatter_WasLastKillFull", Native_WasLastKillFull},
	{nullptr, nullptr},
};

bool ScattergunPellets::SDK_OnLoad(char *error, size_t maxlen, bool late)
{
	if (strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
	{
		g_pSM->Format(error, maxlen, "Scattergun Pellets only supports Team Fortress 2.");
		return false;
	}

	if (!SetupTraceAttackHook(error, maxlen))
	{
		return false;
	}

	sm_sendprop_info_t activeWeaponProp;
	if (!gamehelpers->FindSendPropInfo("CTFPlayer", "m_hActiveWeapon", &activeWeaponProp))
	{
		g_pSM->Format(error, maxlen, "Could not find CTFPlayer::m_hActiveWeapon sendprop.");
		return false;
	}
	m_activeWeaponOffset = activeWeaponProp.actual_offset;

	sharesys->AddNatives(myself, g_Natives);
	sharesys->RegisterLibrary(myself, "scattergun_pellets");

	playerhelpers->AddClientListener(this);
	m_pelletKillForward = forwards->CreateForward("TF2Scatter_OnPelletKill",
		ET_Ignore, 4, nullptr, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

	ClearPelletState();

	if (late)
	{
		HookExistingClients();
	}

	return true;
}

void ScattergunPellets::SDK_OnUnload()
{
	for (int client = 1; client <= SM_MAXPLAYERS; ++client)
	{
		UnhookClient(client);
	}

	if (m_gameEvents)
	{
		m_gameEvents->RemoveListener(this);
		m_gameEvents = nullptr;
	}

	playerhelpers->RemoveClientListener(this);

	if (m_pelletKillForward)
	{
		forwards->ReleaseForward(m_pelletKillForward);
		m_pelletKillForward = nullptr;
	}

	if (m_gameConf)
	{
		gameconfs->CloseGameConfigFile(m_gameConf);
		m_gameConf = nullptr;
	}
}

bool ScattergunPellets::SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late)
{
	(void)error;
	(void)maxlen;
	(void)late;

	gpGlobals = ismm->GetCGlobals();

	GET_V_IFACE_CURRENT(GetEngineFactory, m_gameEvents, IGameEventManager2, INTERFACEVERSION_GAMEEVENTSMANAGER2);
	m_gameEvents->AddListener(this, "player_death", true);

	return true;
}

bool ScattergunPellets::SetupTraceAttackHook(char *error, size_t maxlen)
{
	char confError[255] = "";
	if (!gameconfs->LoadGameConfigFile("scattergun_pellets.games", &m_gameConf, confError, sizeof(confError)))
	{
		if (confError[0])
		{
			g_pSM->Format(error, maxlen, "Could not read scattergun_pellets.games.txt: %s", confError);
		}
		else
		{
			g_pSM->Format(error, maxlen, "Could not read scattergun_pellets.games.txt.");
		}
		return false;
	}

	int offset = -1;
	if (!m_gameConf->GetOffset("TraceAttack", &offset) || offset < 0)
	{
		g_pSM->Format(error, maxlen, "Could not find TraceAttack offset in scattergun_pellets.games.txt.");
		return false;
	}

	SH_MANUALHOOK_RECONFIGURE(TraceAttack, offset, 0, 0);
	return true;
}

void ScattergunPellets::OnClientPutInServer(int client)
{
	HookClient(client);
}

void ScattergunPellets::OnClientDisconnecting(int client)
{
	UnhookClient(client);

	for (int other = 1; other <= SM_MAXPLAYERS; ++other)
	{
		m_pelletTick[client][other] = 0;
		m_pelletCount[client][other] = 0;
		m_lastTraceTick[client][other] = 0;
		m_lastKillTick[client][other] = 0;
		m_lastKillPellets[client][other] = 0;

		m_pelletTick[other][client] = 0;
		m_pelletCount[other][client] = 0;
		m_lastTraceTick[other][client] = 0;
		m_lastKillTick[other][client] = 0;
		m_lastKillPellets[other][client] = 0;
	}
}

void ScattergunPellets::HookExistingClients()
{
	int maxClients = playerhelpers->GetMaxClients();
	for (int client = 1; client <= maxClients; ++client)
	{
		HookClient(client);
	}
}

void ScattergunPellets::HookClient(int client)
{
	if (!IsValidClientIndex(client) || m_clientTraceHooks[client] != 0)
	{
		return;
	}

	IGamePlayer *player = playerhelpers->GetGamePlayer(client);
	if (!player || !player->IsInGame())
	{
		return;
	}

	edict_t *edict = player->GetEdict();
	if (!edict || edict->IsFree() || !edict->GetUnknown())
	{
		return;
	}

	CBaseEntity *entity = edict->GetUnknown()->GetBaseEntity();
	if (!entity)
	{
		return;
	}

	m_clientTraceHooks[client] = SH_ADD_MANUALVPHOOK(TraceAttack, entity,
		SH_MEMBER(this, &ScattergunPellets::Hook_TraceAttack), false);
}

void ScattergunPellets::UnhookClient(int client)
{
	if (!IsValidClientIndex(client) || m_clientTraceHooks[client] == 0)
	{
		return;
	}

	SH_REMOVE_HOOK_ID(m_clientTraceHooks[client]);
	m_clientTraceHooks[client] = 0;
}

bool ScattergunPellets::IsValidClientIndex(int client) const
{
	return client >= 1 && client <= SM_MAXPLAYERS;
}

bool ScattergunPellets::IsScattergunWeapon(CBaseEntity *weapon) const
{
	if (!weapon)
	{
		return false;
	}

	const char *classname = gamehelpers->GetEntityClassname(weapon);
	return classname && strcmp(classname, "tf_weapon_scattergun") == 0;
}

CBaseEntity *ScattergunPellets::GetActiveWeapon(int client) const
{
	if (!IsValidClientIndex(client) || m_activeWeaponOffset < 0)
	{
		return nullptr;
	}

	CBaseEntity *player = gamehelpers->ReferenceToEntity(client);
	if (!player)
	{
		return nullptr;
	}

	CBaseHandle activeWeapon = *reinterpret_cast<CBaseHandle *>(reinterpret_cast<char *>(player) + m_activeWeaponOffset);
	edict_t *weaponEdict = gamehelpers->GetHandleEntity(activeWeapon);
	if (!weaponEdict || weaponEdict->IsFree() || !weaponEdict->GetUnknown())
	{
		return nullptr;
	}

	return weaponEdict->GetUnknown()->GetBaseEntity();
}

bool ScattergunPellets::IsScattergunDamage(const CTakeDamageInfo &info, int attacker, int &weaponIndex) const
{
	if ((info.GetDamageType() & DMG_BUCKSHOT) == 0)
	{
		return false;
	}

	const CTakeDamageInfoPelletView &view = reinterpret_cast<const CTakeDamageInfoPelletView &>(info);
	weaponIndex = view.GetWeaponIndex();

	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(weaponIndex);
	if (IsScattergunWeapon(weapon))
	{
		return true;
	}

	weapon = GetActiveWeapon(attacker);
	if (!IsScattergunWeapon(weapon))
	{
		return false;
	}

	weaponIndex = gamehelpers->EntityToBCompatRef(weapon);
	return true;
}

void ScattergunPellets::Hook_TraceAttack(const CTakeDamageInfo &info, const Vector &vecDir, CGameTrace *trace, CDmgAccumulator *accumulator)
{
	(void)vecDir;
	(void)trace;
	(void)accumulator;

	const CTakeDamageInfoPelletView &view = reinterpret_cast<const CTakeDamageInfoPelletView &>(info);
	int attacker = view.GetAttackerIndex();

	int weapon = -1;
	if (!IsScattergunDamage(info, attacker, weapon))
	{
		RETURN_META(MRES_IGNORED);
	}

	CBaseEntity *victimEntity = META_IFACEPTR(CBaseEntity);
	if (!victimEntity)
	{
		RETURN_META(MRES_IGNORED);
	}

	int victim = gamehelpers->EntityToBCompatRef(victimEntity);
	if (!IsValidClientIndex(attacker) || !IsValidClientIndex(victim) || attacker == victim)
	{
		RETURN_META(MRES_IGNORED);
	}

	RecordPelletHit(attacker, victim, trace);
	RETURN_META(MRES_IGNORED);
}

bool ScattergunPellets::IsDuplicatePelletTrace(int attacker, int victim, CGameTrace *trace, int tick) const
{
	if (!trace || m_lastTraceTick[attacker][victim] != tick)
	{
		return false;
	}

	return m_lastTraceHitbox[attacker][victim] == trace->hitbox
		&& m_lastTraceHitgroup[attacker][victim] == trace->hitgroup
		&& m_lastTraceEnd[attacker][victim][0] == trace->endpos.x
		&& m_lastTraceEnd[attacker][victim][1] == trace->endpos.y
		&& m_lastTraceEnd[attacker][victim][2] == trace->endpos.z;
}

void ScattergunPellets::RecordPelletHit(int attacker, int victim, CGameTrace *trace)
{
	int tick = gpGlobals ? gpGlobals->tickcount : 0;
	if (m_pelletTick[attacker][victim] != tick)
	{
		m_pelletTick[attacker][victim] = tick;
		m_pelletCount[attacker][victim] = 0;
		m_lastTraceTick[attacker][victim] = 0;
	}

	if (IsDuplicatePelletTrace(attacker, victim, trace, tick))
	{
		return;
	}

	++m_pelletCount[attacker][victim];

	if (trace)
	{
		m_lastTraceTick[attacker][victim] = tick;
		m_lastTraceHitbox[attacker][victim] = trace->hitbox;
		m_lastTraceHitgroup[attacker][victim] = trace->hitgroup;
		m_lastTraceEnd[attacker][victim][0] = trace->endpos.x;
		m_lastTraceEnd[attacker][victim][1] = trace->endpos.y;
		m_lastTraceEnd[attacker][victim][2] = trace->endpos.z;
	}
}

void ScattergunPellets::FireGameEvent(IGameEvent *event)
{
	if (!event || strcmp(event->GetName(), "player_death") != 0)
	{
		return;
	}

	int attacker = playerhelpers->GetClientOfUserId(event->GetInt("attacker"));
	int victim = playerhelpers->GetClientOfUserId(event->GetInt("userid"));
	if (!IsValidClientIndex(attacker) || !IsValidClientIndex(victim) || attacker == victim)
	{
		return;
	}

	int tick = gpGlobals ? gpGlobals->tickcount : 0;
	int pellets = 0;
	int pelletTick = m_pelletTick[attacker][victim];
	if (pelletTick > 0 && tick >= pelletTick && tick - pelletTick <= kPelletKillTickWindow)
	{
		pellets = m_pelletCount[attacker][victim];
	}

	if (pellets <= 0)
	{
		return;
	}

	m_lastKillTick[attacker][victim] = tick;
	m_lastKillPellets[attacker][victim] = pellets;

	DispatchPelletKillForward(attacker, victim, pellets);

	m_pelletCount[attacker][victim] = 0;
}

void ScattergunPellets::DispatchPelletKillForward(int attacker, int victim, int pellets)
{
	if (!m_pelletKillForward)
	{
		return;
	}

	m_pelletKillForward->PushCell(attacker);
	m_pelletKillForward->PushCell(victim);
	m_pelletKillForward->PushCell(pellets);
	m_pelletKillForward->PushCell(kScattergunPelletsPerShot);
	m_pelletKillForward->Execute(nullptr);
}

int ScattergunPellets::GetLastKillPellets(int attacker, int victim) const
{
	if (!IsValidClientIndex(attacker) || !IsValidClientIndex(victim))
	{
		return 0;
	}

	return m_lastKillPellets[attacker][victim];
}

bool ScattergunPellets::WasLastKillFull(int attacker, int victim) const
{
	return GetLastKillPellets(attacker, victim) >= kScattergunPelletsPerShot;
}

void ScattergunPellets::ClearPelletState()
{
	memset(m_clientTraceHooks, 0, sizeof(m_clientTraceHooks));
	memset(m_pelletTick, 0, sizeof(m_pelletTick));
	memset(m_pelletCount, 0, sizeof(m_pelletCount));
	memset(m_lastTraceTick, 0, sizeof(m_lastTraceTick));
	memset(m_lastTraceHitbox, 0, sizeof(m_lastTraceHitbox));
	memset(m_lastTraceHitgroup, 0, sizeof(m_lastTraceHitgroup));
	memset(m_lastTraceEnd, 0, sizeof(m_lastTraceEnd));
	memset(m_lastKillTick, 0, sizeof(m_lastKillTick));
	memset(m_lastKillPellets, 0, sizeof(m_lastKillPellets));
}
