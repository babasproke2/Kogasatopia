/**
 * TF2 Setup Uber SourceMod extension.
 *
 * v1.1 fix: the setup-time UberCharge multiplier is applied in
 * CWeaponMedigun::FindAndHealTargets(), not HealTargetThink().  This detour
 * lets TF2's normal charge logic run, then rescales the charge delta during
 * setup time.
 */
#include "extension.h"

#include <CDetour/detours.h>
#include <ISDKTools.h>

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

using namespace SourceMod;

TF2SetupUberExt g_TF2SetupUberExt;
SMEXT_LINK(&g_TF2SetupUberExt)

static IGameConfig *g_pGameConf = NULL;
static ISDKTools *g_pSDKTools = NULL;
static CDetour *g_pFindAndHealTargetsDetour = NULL;

static int g_iMedigunChargeLevelOffset = -1;
static int g_iGameRulesInSetupOffset = -1;
static int g_iGameRulesWaitingForPlayersOffset = -1;

static const float kDefaultSetupMultiplier = 3.0f;
static const float kMaxReasonableMultiplier = 64.0f;

static float g_flSetupMultiplier = kDefaultSetupMultiplier;
static bool g_bDetourReady = false;

/* Lightweight diagnostics exposed through natives and the example command. */
static unsigned int g_nDetourCalls = 0;
static unsigned int g_nAdjustmentCalls = 0;
static bool g_bLastSetupActive = false;
static float g_flLastBefore = 0.0f;
static float g_flLastAfter = 0.0f;
static float g_flLastNew = 0.0f;
static float g_flLastStockDelta = 0.0f;

static bool IsFiniteFloat(float value)
{
#if defined(_MSC_VER)
    return _finite(value) != 0;
#else
    return isfinite(value) != 0;
#endif
}

static float ClampFloat(float value, float lo, float hi)
{
    if (value < lo)
        return lo;
    if (value > hi)
        return hi;
    return value;
}

static float ReadFloatField(void *base, int offset)
{
    return *reinterpret_cast<float *>(reinterpret_cast<uintptr_t>(base) + static_cast<uintptr_t>(offset));
}

static void WriteFloatField(void *base, int offset, float value)
{
    *reinterpret_cast<float *>(reinterpret_cast<uintptr_t>(base) + static_cast<uintptr_t>(offset)) = value;
}

static bool ReadBoolField(void *base, int offset)
{
    return *reinterpret_cast<unsigned char *>(reinterpret_cast<uintptr_t>(base) + static_cast<uintptr_t>(offset)) != 0;
}

static bool IsSetupActive()
{
    g_bLastSetupActive = false;

    if (g_pSDKTools == NULL || g_iGameRulesInSetupOffset < 0)
        return false;

    void *pGameRules = g_pSDKTools->GetGameRules();
    if (pGameRules == NULL)
        return false;

    const bool bInSetup = ReadBoolField(pGameRules, g_iGameRulesInSetupOffset);
    bool bWaitingForPlayers = false;

    if (g_iGameRulesWaitingForPlayersOffset >= 0)
        bWaitingForPlayers = ReadBoolField(pGameRules, g_iGameRulesWaitingForPlayersOffset);

    g_bLastSetupActive = (bInSetup && !bWaitingForPlayers);
    return g_bLastSetupActive;
}

static bool ShouldAdjustSetupMultiplier()
{
    if (!g_bDetourReady)
        return false;

    if (g_iMedigunChargeLevelOffset < 0)
        return false;

    if (fabs(g_flSetupMultiplier - kDefaultSetupMultiplier) <= 0.0001f)
        return false;

    return IsSetupActive();
}

DETOUR_DECL_MEMBER0(CWeaponMedigun_FindAndHealTargets, bool)
{
    void *pMedigun = reinterpret_cast<void *>(this);

    ++g_nDetourCalls;

    const bool bAdjust = ShouldAdjustSetupMultiplier();
    const float flBefore = bAdjust ? ReadFloatField(pMedigun, g_iMedigunChargeLevelOffset) : 0.0f;

    const bool bResult = DETOUR_MEMBER_CALL(CWeaponMedigun_FindAndHealTargets)();

    if (!bAdjust)
        return bResult;

    const float flAfter = ReadFloatField(pMedigun, g_iMedigunChargeLevelOffset);
    const float flStockDelta = flAfter - flBefore;

    g_flLastBefore = flBefore;
    g_flLastAfter = flAfter;
    g_flLastNew = flAfter;
    g_flLastStockDelta = flStockDelta;

    if (flStockDelta <= 0.0f)
        return bResult;

    /*
     * Stock regular setup time is x3.  Rescale the actual stock delta by
     * requested_multiplier / 3.0.  For example, 9.0 makes the setup delta 3x
     * larger than stock setup, i.e. 9x the normal non-setup gain.
     *
     * For multipliers >= 3.0, a stock charge that already capped at 100% is
     * already as high as it can go.
     */
    if (flAfter >= 1.0f && g_flSetupMultiplier >= kDefaultSetupMultiplier)
        return bResult;

    const float flScale = g_flSetupMultiplier / kDefaultSetupMultiplier;
    const float flNewCharge = ClampFloat(flBefore + flStockDelta * flScale, 0.0f, 1.0f);

    if (fabs(flNewCharge - flAfter) > 0.000001f)
    {
        WriteFloatField(pMedigun, g_iMedigunChargeLevelOffset, flNewCharge);
        g_flLastNew = flNewCharge;
        ++g_nAdjustmentCalls;
    }

    return bResult;
}

static cell_t Native_SetMultiplier(IPluginContext *pContext, const cell_t *params)
{
    float value = sp_ctof(params[1]);

    if (!IsFiniteFloat(value) || value < 0.0f || value > kMaxReasonableMultiplier)
    {
        return pContext->ThrowNativeError("Multiplier must be finite and between 0.0 and %.1f", static_cast<double>(kMaxReasonableMultiplier));
    }

    g_flSetupMultiplier = value;
    return 0;
}

static cell_t Native_GetMultiplier(IPluginContext *pContext, const cell_t *params)
{
    return sp_ftoc(g_flSetupMultiplier);
}

static cell_t Native_IsAvailable(IPluginContext *pContext, const cell_t *params)
{
    return (g_bDetourReady && g_pSDKTools != NULL && g_iMedigunChargeLevelOffset >= 0 && g_iGameRulesInSetupOffset >= 0) ? 1 : 0;
}

static cell_t Native_GetDetourCallCount(IPluginContext *pContext, const cell_t *params)
{
    return static_cast<cell_t>(g_nDetourCalls);
}

static cell_t Native_GetAdjustmentCount(IPluginContext *pContext, const cell_t *params)
{
    return static_cast<cell_t>(g_nAdjustmentCalls);
}

static cell_t Native_WasLastSetupActive(IPluginContext *pContext, const cell_t *params)
{
    return g_bLastSetupActive ? 1 : 0;
}

static cell_t Native_GetLastBefore(IPluginContext *pContext, const cell_t *params)
{
    return sp_ftoc(g_flLastBefore);
}

static cell_t Native_GetLastAfter(IPluginContext *pContext, const cell_t *params)
{
    return sp_ftoc(g_flLastAfter);
}

static cell_t Native_GetLastNew(IPluginContext *pContext, const cell_t *params)
{
    return sp_ftoc(g_flLastNew);
}

static cell_t Native_GetLastStockDelta(IPluginContext *pContext, const cell_t *params)
{
    return sp_ftoc(g_flLastStockDelta);
}

static sp_nativeinfo_t g_Natives[] =
{
    {"TF2SetupUber_SetMultiplier", Native_SetMultiplier},
    {"TF2SetupUber_GetMultiplier", Native_GetMultiplier},
    {"TF2SetupUber_IsAvailable", Native_IsAvailable},
    {"TF2SetupUber_GetDetourCallCount", Native_GetDetourCallCount},
    {"TF2SetupUber_GetAdjustmentCount", Native_GetAdjustmentCount},
    {"TF2SetupUber_WasLastSetupActive", Native_WasLastSetupActive},
    {"TF2SetupUber_GetLastBefore", Native_GetLastBefore},
    {"TF2SetupUber_GetLastAfter", Native_GetLastAfter},
    {"TF2SetupUber_GetLastNew", Native_GetLastNew},
    {"TF2SetupUber_GetLastStockDelta", Native_GetLastStockDelta},
    {NULL, NULL}
};

bool TF2SetupUberExt::SDK_OnLoad(char *error, size_t maxlength, bool late)
{
    if (strcmp(g_pSM->GetGameFolderName(), "tf") != 0)
    {
        snprintf(error, maxlength, "TF2 Setup Uber only supports Team Fortress 2 (tf), not '%s'", g_pSM->GetGameFolderName());
        return false;
    }

    sharesys->AddDependency(myself, "sdktools.ext", true, true);

    char confError[255];
    confError[0] = '\0';
    if (!gameconfs->LoadGameConfigFile("tf2.setupuber", &g_pGameConf, confError, sizeof(confError)))
    {
        snprintf(error, maxlength, "Could not load gamedata/tf2.setupuber.txt: %s", confError);
        return false;
    }

    sm_sendprop_info_t info;
    if (!gamehelpers->FindSendPropInfo("CWeaponMedigun", "m_flChargeLevel", &info))
    {
        snprintf(error, maxlength, "Could not find CWeaponMedigun::m_flChargeLevel sendprop");
        return false;
    }
    g_iMedigunChargeLevelOffset = static_cast<int>(info.actual_offset);

    if (!gamehelpers->FindSendPropInfo("CTFGameRulesProxy", "m_bInSetup", &info))
    {
        snprintf(error, maxlength, "Could not find CTFGameRulesProxy::m_bInSetup sendprop");
        return false;
    }
    g_iGameRulesInSetupOffset = static_cast<int>(info.actual_offset);

    if (gamehelpers->FindSendPropInfo("CTFGameRulesProxy", "m_bInWaitingForPlayers", &info))
        g_iGameRulesWaitingForPlayersOffset = static_cast<int>(info.actual_offset);

    CDetourManager::Init(g_pSM->GetScriptingEngine(), g_pGameConf);

    g_pFindAndHealTargetsDetour = DETOUR_CREATE_MEMBER(CWeaponMedigun_FindAndHealTargets, "CWeaponMedigun::FindAndHealTargets");
    if (g_pFindAndHealTargetsDetour == NULL)
    {
        snprintf(error, maxlength, "Could not create detour for CWeaponMedigun::FindAndHealTargets; update gamedata signature");
        return false;
    }

    g_pFindAndHealTargetsDetour->EnableDetour();
    g_bDetourReady = true;

    sharesys->AddNatives(myself, g_Natives);
    sharesys->RegisterLibrary(myself, "tf2setupuber");

    return true;
}

void TF2SetupUberExt::SDK_OnAllLoaded()
{
    SM_GET_LATE_IFACE(SDKTOOLS, g_pSDKTools);

    if (g_pSDKTools == NULL)
        smutils->LogError(myself, "SDKTools interface not found; setup multiplier adjustment is unavailable.");
}

void TF2SetupUberExt::SDK_OnUnload()
{
    g_bDetourReady = false;

    if (g_pFindAndHealTargetsDetour != NULL)
    {
        if (g_pFindAndHealTargetsDetour->IsEnabled())
            g_pFindAndHealTargetsDetour->DisableDetour();

        g_pFindAndHealTargetsDetour->Destroy();
        g_pFindAndHealTargetsDetour = NULL;
    }

    if (g_pGameConf != NULL)
    {
        gameconfs->CloseGameConfigFile(g_pGameConf);
        g_pGameConf = NULL;
    }
}

bool TF2SetupUberExt::QueryRunning(char *error, size_t maxlength)
{
    if (!g_bDetourReady)
    {
        snprintf(error, maxlength, "CWeaponMedigun::FindAndHealTargets detour is not ready");
        return false;
    }

    if (g_pSDKTools == NULL)
    {
        snprintf(error, maxlength, "SDKTools interface is not ready");
        return false;
    }

    return true;
}
