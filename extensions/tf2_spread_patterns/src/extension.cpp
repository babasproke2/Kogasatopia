#include "extension.h"

#include <cstdint>
#include <cstring>

#include <eiface.h>
#include <IGameHelpers.h>

#define DETOUR_DECL_STATIC10(name, ret, p1type, p1name, p2type, p2name, p3type, p3name, p4type, p4name, p5type, p5name, p6type, p6name, p7type, p7name, p8type, p8name, p9type, p9name, p10type, p10name) \
ret (*name##_Actual)(p1type, p2type, p3type, p4type, p5type, p6type, p7type, p8type, p9type, p10type) = nullptr; \
ret name(p1type p1name, p2type p2name, p3type p3name, p4type p4name, p5type p5name, p6type p6name, p7type p7name, p8type p8name, p9type p9name, p10type p10name)

static const Vector kCircular15[] =
{
	Vector( 0.000f,  0.000f, 0.0f),
	Vector( 0.160f, -0.080f, 0.0f),
	Vector(-0.180f,  0.040f, 0.0f),
	Vector( 0.080f,  0.220f, 0.0f),
	Vector(-0.060f, -0.200f, 0.0f),
	Vector( 0.340f,  0.120f, 0.0f),
	Vector(-0.300f, -0.140f, 0.0f),
	Vector( 0.180f, -0.360f, 0.0f),
	Vector(-0.240f,  0.320f, 0.0f),
	Vector( 0.500f, -0.060f, 0.0f),
	Vector(-0.420f,  0.180f, 0.0f),
	Vector( 0.280f,  0.420f, 0.0f),
	Vector(-0.160f, -0.480f, 0.0f),
	Vector( 0.660f,  0.300f, 0.0f),
	Vector(-0.620f, -0.240f, 0.0f),
};

TF2SpreadPatterns g_TF2SpreadPatterns;
SMEXT_LINK(&g_TF2SpreadPatterns);

CGlobalVars *gpGlobals = nullptr;

DETOUR_DECL_MEMBER0(Detour_GetWeaponSpread, float)
{
	CBaseEntity *weapon = reinterpret_cast<CBaseEntity *>(this);
	const float spread = DETOUR_MEMBER_CALL(Detour_GetWeaponSpread)();
	return g_TF2SpreadPatterns.ShouldUseAmbassadorAccuracy(weapon)
		? g_TF2SpreadPatterns.ApplyAmbassadorAccuracy(weapon, spread)
		: spread;
}

DETOUR_DECL_STATIC10(Detour_FXFireBullets, void,
	CBaseEntity *, weapon,
	int, player,
	const Vector &, origin,
	const QAngle &, angles,
	int, weaponId,
	int, mode,
	int, seed,
	float, spread,
	float, damage,
	bool, critical)
{
	const bool useCircular15 = g_TF2SpreadPatterns.ShouldUseCircular15(weapon);
	if (useCircular15)
	{
		g_TF2SpreadPatterns.BeginCircular15();
	}

	DETOUR_STATIC_CALL(Detour_FXFireBullets)(
		weapon, player, origin, angles, weaponId, mode, seed, spread, damage, critical);

	if (useCircular15)
	{
		g_TF2SpreadPatterns.EndCircular15();
	}
}

static cell_t Native_SetPattern(IPluginContext *context, const cell_t *params)
{
	return g_TF2SpreadPatterns.Native_SetPattern(context, params);
}

static cell_t Native_SetAmbassadorAccuracy(IPluginContext *context, const cell_t *params)
{
	return g_TF2SpreadPatterns.Native_SetAmbassadorAccuracy(context, params);
}

static sp_nativeinfo_t g_Natives[] =
{
	{"TF2Spread_SetPattern", Native_SetPattern},
	{"TF2Spread_SetAmbassadorAccuracy", Native_SetAmbassadorAccuracy},
	{nullptr, nullptr},
};

bool TF2SpreadPatterns::SDK_OnLoad(char *error, size_t maxlen, bool late)
{
	if (std::strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
	{
		g_pSM->Format(error, maxlen, "TF2 Spread Patterns only supports Team Fortress 2.");
		return false;
	}

	if (!SetupGameConfig(error, maxlen)
		|| !SetupSendProps(error, maxlen)
		|| !SetupSpreadTable(error, maxlen)
		|| !SetupDetours(error, maxlen))
	{
		return false;
	}

	sharesys->AddNatives(myself, g_Natives);
	sharesys->RegisterLibrary(myself, "tf2_spread_patterns");

	(void)late;
	return true;
}

void TF2SpreadPatterns::SDK_OnUnload()
{
	RestoreStockPattern();

	if (m_getWeaponSpreadDetour)
	{
		m_getWeaponSpreadDetour->DisableDetour();
		m_getWeaponSpreadDetour->Destroy();
		m_getWeaponSpreadDetour = nullptr;
	}

	if (m_fireBulletsDetour)
	{
		m_fireBulletsDetour->DisableDetour();
		m_fireBulletsDetour->Destroy();
		m_fireBulletsDetour = nullptr;
	}

	if (m_gameConf)
	{
		gameconfs->CloseGameConfigFile(m_gameConf);
		m_gameConf = nullptr;
	}
}

bool TF2SpreadPatterns::SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late)
{
	(void)error;
	(void)maxlen;
	(void)late;

	gpGlobals = ismm->GetCGlobals();
	return true;
}

cell_t TF2SpreadPatterns::Native_SetPattern(IPluginContext *context, const cell_t *params)
{
	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(params[1]);
	if (!weapon)
	{
		return context->ThrowNativeError("Weapon entity %d is invalid.", params[1]);
	}

	const int entity = gamehelpers->EntityToBCompatRef(weapon);
	if (entity <= 0 || entity >= kMaxTrackedEntities)
	{
		return context->ThrowNativeError("Weapon entity %d cannot be tracked.", params[1]);
	}

	const int requestedPattern = params[2];
	if (requestedPattern < static_cast<int>(SpreadPattern::Default)
		|| requestedPattern > static_cast<int>(SpreadPattern::Circular15))
	{
		return context->ThrowNativeError("Spread pattern %d is invalid.", requestedPattern);
	}

	const SpreadPattern pattern = static_cast<SpreadPattern>(requestedPattern);
	m_patterns[entity] = pattern;
	m_patternWeaponRefs[entity] = pattern == SpreadPattern::Default
		? 0
		: gamehelpers->EntityToReference(weapon);
	return 0;
}

cell_t TF2SpreadPatterns::Native_SetAmbassadorAccuracy(IPluginContext *context, const cell_t *params)
{
	CBaseEntity *weapon = gamehelpers->ReferenceToEntity(params[1]);
	if (!weapon)
	{
		return context->ThrowNativeError("Weapon entity %d is invalid.", params[1]);
	}

	const int entity = gamehelpers->EntityToBCompatRef(weapon);
	if (entity <= 0 || entity >= kMaxTrackedEntities)
	{
		return context->ThrowNativeError("Weapon entity %d cannot be tracked.", params[1]);
	}

	m_accuracyWeaponRefs[entity] = params[2]
		? gamehelpers->EntityToReference(weapon)
		: 0;
	return 0;
}

bool TF2SpreadPatterns::ShouldUseCircular15(CBaseEntity *weapon)
{
	if (!weapon)
	{
		return false;
	}

	const int entity = gamehelpers->EntityToBCompatRef(weapon);
	if (entity <= 0 || entity >= kMaxTrackedEntities)
	{
		return false;
	}
	if (m_patternWeaponRefs[entity] == 0)
	{
		return false;
	}

	const cell_t currentRef = gamehelpers->EntityToReference(weapon);
	if (m_patternWeaponRefs[entity] != currentRef)
	{
		m_patternWeaponRefs[entity] = 0;
		m_patterns[entity] = SpreadPattern::Default;
		return false;
	}

	return m_patterns[entity] == SpreadPattern::Circular15;
}

bool TF2SpreadPatterns::ShouldUseAmbassadorAccuracy(CBaseEntity *weapon)
{
	if (!weapon)
	{
		return false;
	}

	const int entity = gamehelpers->EntityToBCompatRef(weapon);
	if (entity <= 0 || entity >= kMaxTrackedEntities)
	{
		return false;
	}
	if (m_accuracyWeaponRefs[entity] == 0)
	{
		return false;
	}

	const cell_t currentRef = gamehelpers->EntityToReference(weapon);
	if (m_accuracyWeaponRefs[entity] != currentRef)
	{
		m_accuracyWeaponRefs[entity] = 0;
		return false;
	}

	return true;
}

float TF2SpreadPatterns::ApplyAmbassadorAccuracy(CBaseEntity *weapon, float spread) const
{
	if (!gpGlobals || m_lastFireTimeOffset < 0 || spread <= 0.0f)
	{
		return spread;
	}

	const float lastFireTime = *reinterpret_cast<const float *>(
		reinterpret_cast<const char *>(weapon) + m_lastFireTimeOffset);
	const float elapsed = gpGlobals->curtime - lastFireTime;

	if (elapsed <= 0.5f)
	{
		return spread;
	}
	if (elapsed >= 1.0f)
	{
		return 0.0f;
	}

	return spread * ((1.0f - elapsed) / 0.5f);
}

void TF2SpreadPatterns::BeginCircular15()
{
	if (m_swapDepth++ == 0)
	{
		std::memcpy(m_fixedSpreadTable, kCircular15, sizeof(kCircular15));
	}
}

void TF2SpreadPatterns::EndCircular15()
{
	if (m_swapDepth <= 0)
	{
		return;
	}

	if (--m_swapDepth == 0)
	{
		RestoreStockPattern();
	}
}

bool TF2SpreadPatterns::SetupGameConfig(char *error, size_t maxlen)
{
	char confError[255] = "";
	if (!gameconfs->LoadGameConfigFile(
		"tf2_spread_patterns.games", &m_gameConf, confError, sizeof(confError)))
	{
		g_pSM->Format(error, maxlen, "Could not read tf2_spread_patterns.games.txt: %s", confError);
		return false;
	}

	CDetourManager::Init(g_pSM->GetScriptingEngine(), m_gameConf);
	return true;
}

bool TF2SpreadPatterns::SetupSendProps(char *error, size_t maxlen)
{
	sm_sendprop_info_t lastFireTimeProp;
	if (!gamehelpers->FindSendPropInfo("CTFWeaponBase", "m_flLastFireTime", &lastFireTimeProp))
	{
		g_pSM->Format(error, maxlen, "Could not find CTFWeaponBase::m_flLastFireTime sendprop.");
		return false;
	}

	m_lastFireTimeOffset = lastFireTimeProp.actual_offset;
	return true;
}

bool TF2SpreadPatterns::SetupSpreadTable(char *error, size_t maxlen)
{
	void *reference = nullptr;
	if (!m_gameConf->GetMemSig("FixedSpreadWideLargeReference", &reference) || !reference)
	{
		g_pSM->Format(error, maxlen, "Could not locate the fixed 15-pellet spread table reference.");
		return false;
	}

	const uint8_t *instruction = static_cast<const uint8_t *>(reference);
	static constexpr uint8_t kExpectedPrefix[] = {0xF3, 0x0F, 0x10, 0x3C, 0x85};
	if (std::memcmp(instruction, kExpectedPrefix, sizeof(kExpectedPrefix)) != 0)
	{
		g_pSM->Format(error, maxlen, "Fixed spread table reference did not match expected code.");
		return false;
	}

	uint32_t tableAddress = 0;
	std::memcpy(&tableAddress, instruction + sizeof(kExpectedPrefix), sizeof(tableAddress));
	m_fixedSpreadTable = reinterpret_cast<Vector *>(static_cast<uintptr_t>(tableAddress));
	if (!m_fixedSpreadTable)
	{
		g_pSM->Format(error, maxlen, "Fixed spread table address was null.");
		return false;
	}

	std::memcpy(m_stockPattern, m_fixedSpreadTable, sizeof(m_stockPattern));
	return true;
}

bool TF2SpreadPatterns::SetupDetours(char *error, size_t maxlen)
{
	m_fireBulletsDetour = DETOUR_CREATE_STATIC(Detour_FXFireBullets, "FX_FireBullets");
	if (!m_fireBulletsDetour)
	{
		g_pSM->Format(error, maxlen, "Could not create FX_FireBullets detour.");
		return false;
	}

	m_getWeaponSpreadDetour = DETOUR_CREATE_MEMBER(
		Detour_GetWeaponSpread, "CTFWeaponBaseGun::GetWeaponSpread");
	if (!m_getWeaponSpreadDetour)
	{
		m_fireBulletsDetour->Destroy();
		m_fireBulletsDetour = nullptr;
		g_pSM->Format(error, maxlen, "Could not create CTFWeaponBaseGun::GetWeaponSpread detour.");
		return false;
	}

	m_fireBulletsDetour->EnableDetour();
	m_getWeaponSpreadDetour->EnableDetour();
	return true;
}

void TF2SpreadPatterns::RestoreStockPattern()
{
	if (m_fixedSpreadTable)
	{
		std::memcpy(m_fixedSpreadTable, m_stockPattern, sizeof(m_stockPattern));
	}
	m_swapDepth = 0;
}
