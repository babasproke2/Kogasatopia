#ifndef _INCLUDE_TF2_SPREAD_PATTERNS_EXTENSION_H_
#define _INCLUDE_TF2_SPREAD_PATTERNS_EXTENSION_H_

#include "smsdk_ext.h"

#include <CDetour/detours.h>
#include <mathlib/vector.h>

class CBaseEntity;
class CDetour;
struct FireBulletsInfo_t;

enum class SpreadPattern : int
{
	Default = 0,
	Circular15 = 1,
	WideHorizontal20 = 2,
};

class TF2SpreadPatterns : public SDKExtension
{
public:
	bool SDK_OnLoad(char *error, size_t maxlen, bool late) override;
	void SDK_OnUnload() override;
	bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool late) override;

	cell_t Native_SetPattern(IPluginContext *context, const cell_t *params);
	cell_t Native_SetAmbassadorAccuracy(IPluginContext *context, const cell_t *params);
	cell_t Native_IsAmbassadorAccuracyRecovered(IPluginContext *context, const cell_t *params);
	cell_t Native_SetPunchAngle(IPluginContext *context, const cell_t *params);

	bool ShouldUseCircular15(CBaseEntity *weapon);
	bool ShouldUseWideHorizontal20(CBaseEntity *weapon);
	bool ShouldUseAmbassadorAccuracy(CBaseEntity *weapon);
	bool IsAmbassadorAccuracyRecovered(CBaseEntity *weapon);
	float ApplyAmbassadorAccuracy(CBaseEntity *weapon, float spread) const;
	bool ApplyPunchAngleOverride(CBaseEntity *weapon, CBaseEntity *player);
	void BeginCircular15();
	void EndCircular15();
	void BeginWideHorizontal20(CBaseEntity *weapon, const QAngle &angles, float spread);
	void EndWideHorizontal20();
	bool ApplyWideHorizontal20(
		CBaseEntity *weapon, const FireBulletsInfo_t &source, FireBulletsInfo_t &result);
private:
	using SetPunchAngleFn = void (*)(CBaseEntity *, const QAngle &);
	using SharedRandomIntFn = int (*)(const char *, int, int, int);

	static constexpr int kPelletCount = 15;
	static constexpr int kWideHorizontalPelletCount = 20;
	static constexpr int kMaxTrackedEntities = 2048;
	bool SetupGameConfig(char *error, size_t maxlen);
	bool SetupSendProps(char *error, size_t maxlen);
	bool SetupFunctions(char *error, size_t maxlen);
	bool SetupSpreadTable(char *error, size_t maxlen);
	bool SetupDetours(char *error, size_t maxlen);
	float GetTimeSinceLastFire(CBaseEntity *weapon) const;
	SpreadPattern GetPattern(CBaseEntity *weapon);
	void RestoreStockPattern();

	SourceMod::IGameConfig *m_gameConf = nullptr;
	CDetour *m_fireBulletsDetour = nullptr;
	CDetour *m_playerFireBulletDetour = nullptr;
	CDetour *m_getWeaponSpreadDetour = nullptr;
	CDetour *m_updatePunchAnglesDetour = nullptr;
	Vector *m_fixedSpreadTable = nullptr;
	Vector m_stockPattern[kPelletCount] = {};
	cell_t m_patternWeaponRefs[kMaxTrackedEntities] = {};
	cell_t m_accuracyWeaponRefs[kMaxTrackedEntities] = {};
	cell_t m_punchWeaponRefs[kMaxTrackedEntities] = {};
	SpreadPattern m_patterns[kMaxTrackedEntities] = {};
	int m_punchAmounts[kMaxTrackedEntities] = {};
	bool m_punchConsistent[kMaxTrackedEntities] = {};
	int m_lastFireTimeOffset = -1;
	int m_punchAngleOffset = -1;
	SetPunchAngleFn m_setPunchAngle = nullptr;
	SharedRandomIntFn m_sharedRandomInt = nullptr;
	int m_swapDepth = 0;
	CBaseEntity *m_wideHorizontalWeapon = nullptr;
	Vector m_wideHorizontalForward = {};
	Vector m_wideHorizontalRight = {};
	Vector m_wideHorizontalUp = {};
	float m_wideHorizontalSpread = 0.0f;
	int m_wideHorizontalPellet = 0;
	bool m_wideHorizontalActive = false;
};

extern TF2SpreadPatterns g_TF2SpreadPatterns;

#endif
