#ifndef _INCLUDE_TF2_SPREAD_PATTERNS_EXTENSION_H_
#define _INCLUDE_TF2_SPREAD_PATTERNS_EXTENSION_H_

#include "smsdk_ext.h"

#include <CDetour/detours.h>
#include <mathlib/vector.h>

class CBaseEntity;
class CDetour;

enum class SpreadPattern : int
{
	Default = 0,
	Circular15 = 1,
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

	bool ShouldUseCircular15(CBaseEntity *weapon);
	bool ShouldUseAmbassadorAccuracy(CBaseEntity *weapon);
	bool IsAmbassadorAccuracyRecovered(CBaseEntity *weapon);
	float ApplyAmbassadorAccuracy(CBaseEntity *weapon, float spread) const;
	void BeginCircular15();
	void EndCircular15();

private:
	static constexpr int kPelletCount = 15;
	static constexpr int kMaxTrackedEntities = 2048;

	bool SetupGameConfig(char *error, size_t maxlen);
	bool SetupSendProps(char *error, size_t maxlen);
	bool SetupSpreadTable(char *error, size_t maxlen);
	bool SetupDetours(char *error, size_t maxlen);
	float GetTimeSinceLastFire(CBaseEntity *weapon) const;
	void RestoreStockPattern();

	SourceMod::IGameConfig *m_gameConf = nullptr;
	CDetour *m_fireBulletsDetour = nullptr;
	CDetour *m_getWeaponSpreadDetour = nullptr;
	Vector *m_fixedSpreadTable = nullptr;
	Vector m_stockPattern[kPelletCount] = {};
	cell_t m_patternWeaponRefs[kMaxTrackedEntities] = {};
	cell_t m_accuracyWeaponRefs[kMaxTrackedEntities] = {};
	SpreadPattern m_patterns[kMaxTrackedEntities] = {};
	int m_lastFireTimeOffset = -1;
	int m_swapDepth = 0;
};

extern TF2SpreadPatterns g_TF2SpreadPatterns;

#endif
