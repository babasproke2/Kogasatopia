#include "extension.h"

#include <string.h>

#include <edict.h>
#include <eiface.h>
#include <isaverestore.h>
#include <ehandle.h>
#include <shareddefs.h>
#include <takedamageinfo.h>

static constexpr int kDefaultPelletsPerShot = 10;
static constexpr int kPelletKillTickWindow = 8;
ScattergunPellets g_ScattergunPellets;
SMEXT_LINK(&g_ScattergunPellets);

CGlobalVars *gpGlobals = nullptr;

SH_DECL_MANUALHOOK4_void(TraceAttack, 0, 0, 0, const CTakeDamageInfo &, const Vector &, CGameTrace *, CDmgAccumulator *);

static void ScattergunPellets_GameFrameHook(bool simulating)
{
	g_ScattergunPellets.OnGameFrame(simulating);
}

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

static cell_t Native_IsCurrentShotFull(IPluginContext *context, const cell_t *params)
{
	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(params[3]);
	if (!weapon)
	{
		return 0;
	}

	return g_ScattergunPellets.IsCurrentShotFull(params[1], params[2], weapon) ? 1 : 0;
}

static cell_t Native_SetWeaponPelletCount(IPluginContext *context, const cell_t *params)
{
	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(params[1]);
	if (!weapon)
	{
		return context->ThrowNativeError("Weapon entity %d is invalid.", params[1]);
	}

	g_ScattergunPellets.SetWeaponPelletCount(weapon, params[2]);
	return 0;
}

static sp_nativeinfo_t g_Natives[] =
{
	{"TF2Scatter_GetLastKillPellets", Native_GetLastKillPellets},
	{"TF2Scatter_WasLastKillFull", Native_WasLastKillFull},
	{"TF2Scatter_IsCurrentShotFull", Native_IsCurrentShotFull},
	{"TF2Scatter_SetWeaponPelletCount", Native_SetWeaponPelletCount},
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
	m_pelletShotForward = forwards->CreateForward("TF2Shotgun_OnPelletShot",
		ET_Ignore, 5, nullptr, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	g_pSM->AddGameFrameHook(&ScattergunPellets_GameFrameHook);

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
	g_pSM->RemoveGameFrameHook(&ScattergunPellets_GameFrameHook);

	if (m_pelletShotForward)
	{
		forwards->ReleaseForward(m_pelletShotForward);
		m_pelletShotForward = nullptr;
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
		m_pelletTotal[client][other] = 0;
		m_pelletWeaponRefs[client][other] = 0;
		m_lastTraceTick[client][other] = 0;
		m_lastKillTick[client][other] = 0;
		m_lastKillPellets[client][other] = 0;
		m_lastKillTotal[client][other] = 0;

		m_pelletTick[other][client] = 0;
		m_pelletCount[other][client] = 0;
		m_pelletTotal[other][client] = 0;
		m_pelletWeaponRefs[other][client] = 0;
		m_lastTraceTick[other][client] = 0;
		m_lastKillTick[other][client] = 0;
		m_lastKillPellets[other][client] = 0;
		m_lastKillTotal[other][client] = 0;
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

bool ScattergunPellets::IsTrackedPelletWeapon(CBaseEntity *weapon) const
{
	if (!weapon)
	{
		return false;
	}

	const char *actualClassname = gamehelpers->GetEntityClassname(weapon);
	if (!actualClassname)
	{
		return false;
	}

	return strcmp(actualClassname, "tf_weapon_scattergun") == 0
		|| strstr(actualClassname, "tf_weapon_shotgun") != nullptr;
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

void ScattergunPellets::SetWeaponPelletCount(CBaseEntity *weapon, int pelletsFired)
{
	cell_t reference = gamehelpers->EntityToReference(weapon);
	int entity = gamehelpers->ReferenceToIndex(reference);
	if (entity <= 0 || entity >= kMaxTrackedEntities)
	{
		return;
	}

	if (pelletsFired > 0)
	{
		m_weaponRefs[entity] = reference;
		m_weaponPelletCounts[entity] = pelletsFired;
	}
	else
	{
		m_weaponRefs[entity] = 0;
		m_weaponPelletCounts[entity] = 0;
	}
}

int ScattergunPellets::GetWeaponPelletCount(CBaseEntity *weapon) const
{
	cell_t reference = gamehelpers->EntityToReference(weapon);
	int entity = gamehelpers->ReferenceToIndex(reference);
	if (entity > 0 && entity < kMaxTrackedEntities
		&& m_weaponRefs[entity] == reference && m_weaponPelletCounts[entity] > 0)
	{
		return m_weaponPelletCounts[entity];
	}

	return kDefaultPelletsPerShot;
}

CBaseEntity *ScattergunPellets::GetTrackedPelletWeapon(
	const CTakeDamageInfo &info, int attacker) const
{
	if ((info.GetDamageType() & DMG_BUCKSHOT) == 0)
	{
		return nullptr;
	}

	const CTakeDamageInfoPelletView &view = reinterpret_cast<const CTakeDamageInfoPelletView &>(info);
	int weaponIndex = view.GetWeaponIndex();

	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(weaponIndex);
	if (IsTrackedPelletWeapon(weapon))
	{
		return weapon;
	}

	weapon = GetActiveWeapon(attacker);
	return IsTrackedPelletWeapon(weapon) ? weapon : nullptr;
}

void ScattergunPellets::Hook_TraceAttack(const CTakeDamageInfo &info, const Vector &vecDir, CGameTrace *trace, CDmgAccumulator *accumulator)
{
	(void)vecDir;
	(void)accumulator;

	const CTakeDamageInfoPelletView &view = reinterpret_cast<const CTakeDamageInfoPelletView &>(info);
	int attacker = view.GetAttackerIndex();

	CBaseEntity *weapon = GetTrackedPelletWeapon(info, attacker);
	if (!weapon)
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

	RecordPelletHit(attacker, victim, weapon, trace, GetWeaponPelletCount(weapon));
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

bool ScattergunPellets::RememberPelletTrace(int attacker, int victim, CGameTrace *trace, int tick)
{
	if (IsDuplicatePelletTrace(attacker, victim, trace, tick))
	{
		return false;
	}

	if (trace)
	{
		m_lastTraceTick[attacker][victim] = tick;
		m_lastTraceHitbox[attacker][victim] = trace->hitbox;
		m_lastTraceHitgroup[attacker][victim] = trace->hitgroup;
		m_lastTraceEnd[attacker][victim][0] = trace->endpos.x;
		m_lastTraceEnd[attacker][victim][1] = trace->endpos.y;
		m_lastTraceEnd[attacker][victim][2] = trace->endpos.z;
	}

	return true;
}

void ScattergunPellets::RecordPelletHit(
	int attacker, int victim, CBaseEntity *weapon, CGameTrace *trace, int pelletsFired)
{
	int tick = gpGlobals ? gpGlobals->tickcount : 0;
	if (m_pelletTick[attacker][victim] != tick)
	{
		m_pelletTick[attacker][victim] = tick;
		m_pelletCount[attacker][victim] = 0;
		m_pelletTotal[attacker][victim] = pelletsFired;
		m_pelletWeaponRefs[attacker][victim] = gamehelpers->EntityToReference(weapon);
		m_lastTraceTick[attacker][victim] = 0;
	}

	if (!RememberPelletTrace(attacker, victim, trace, tick))
	{
		return;
	}

	++m_pelletCount[attacker][victim];
}

bool ScattergunPellets::IsCurrentShotFull(
	int attacker, int victim, CBaseEntity *weapon) const
{
	if (!gpGlobals || !weapon || !IsValidClientIndex(attacker) || !IsValidClientIndex(victim))
	{
		return false;
	}

	int pelletsFired = m_pelletTotal[attacker][victim];
	return m_pelletTick[attacker][victim] == gpGlobals->tickcount
		&& m_pelletWeaponRefs[attacker][victim] == gamehelpers->EntityToReference(weapon)
		&& pelletsFired > 0
		&& m_pelletCount[attacker][victim] >= pelletsFired;
}

void ScattergunPellets::OnGameFrame(bool simulating)
{
	if (!simulating)
	{
		return;
	}

	int tick = gpGlobals ? gpGlobals->tickcount : 0;
	int maxClients = playerhelpers->GetMaxClients();
	for (int attacker = 1; attacker <= maxClients; ++attacker)
	{
		for (int victim = 1; victim <= maxClients; ++victim)
		{
			int pelletTick = m_pelletTick[attacker][victim];
			int pellets = m_pelletCount[attacker][victim];
			int pelletsFired = m_pelletTotal[attacker][victim];
			if (pelletTick <= 0 || pellets <= 0 || tick <= pelletTick)
			{
				continue;
			}

			DispatchPelletShotForward(attacker, victim, pellets, pelletsFired, false);
			ClearPelletShot(attacker, victim);
		}
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
	m_lastKillTotal[attacker][victim] = m_pelletTotal[attacker][victim];

	DispatchPelletShotForward(
		attacker, victim, pellets, m_lastKillTotal[attacker][victim], true);

	ClearPelletShot(attacker, victim);
}

void ScattergunPellets::ClearPelletShot(int attacker, int victim)
{
	m_pelletTick[attacker][victim] = 0;
	m_pelletCount[attacker][victim] = 0;
	m_pelletTotal[attacker][victim] = 0;
	m_pelletWeaponRefs[attacker][victim] = 0;
}

void ScattergunPellets::DispatchPelletShotForward(
	int attacker, int victim, int pellets, int pelletsFired, bool kill)
{
	if (!m_pelletShotForward)
	{
		return;
	}

	m_pelletShotForward->PushCell(attacker);
	m_pelletShotForward->PushCell(victim);
	m_pelletShotForward->PushCell(pellets);
	m_pelletShotForward->PushCell(pelletsFired);
	m_pelletShotForward->PushCell(kill ? 1 : 0);
	m_pelletShotForward->Execute(nullptr);
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
	if (!IsValidClientIndex(attacker) || !IsValidClientIndex(victim))
	{
		return false;
	}

	int pelletsFired = m_lastKillTotal[attacker][victim];
	return pelletsFired > 0 && m_lastKillPellets[attacker][victim] >= pelletsFired;
}

void ScattergunPellets::ClearPelletState()
{
	memset(m_clientTraceHooks, 0, sizeof(m_clientTraceHooks));
	memset(m_pelletTick, 0, sizeof(m_pelletTick));
	memset(m_pelletCount, 0, sizeof(m_pelletCount));
	memset(m_pelletTotal, 0, sizeof(m_pelletTotal));
	memset(m_pelletWeaponRefs, 0, sizeof(m_pelletWeaponRefs));
	memset(m_lastTraceTick, 0, sizeof(m_lastTraceTick));
	memset(m_lastTraceHitbox, 0, sizeof(m_lastTraceHitbox));
	memset(m_lastTraceHitgroup, 0, sizeof(m_lastTraceHitgroup));
	memset(m_lastTraceEnd, 0, sizeof(m_lastTraceEnd));
	memset(m_lastKillTick, 0, sizeof(m_lastKillTick));
	memset(m_lastKillPellets, 0, sizeof(m_lastKillPellets));
	memset(m_lastKillTotal, 0, sizeof(m_lastKillTotal));
	memset(m_weaponRefs, 0, sizeof(m_weaponRefs));
	memset(m_weaponPelletCounts, 0, sizeof(m_weaponPelletCounts));
}
