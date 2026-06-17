#include "range_override.h"

#include <algorithm>
#include <cstdint>

namespace
{
    CDetour *gFindTargetDetour = nullptr;
    int gSentryRangeOffset = -1;
    bool gEnabled = false;
    float gDistance = 200.0f;

    // CObjectSentrygun layout around the target members in the public TF2 SDK:
    //   CNetworkHandle(CBaseEntity, m_hEnemy);  // 4-byte CBaseHandle
    //   bool m_bFireNextFrame;                  // 1 byte
    //   bool m_bFireRocketNextFrame;            // 1 byte
    //   padding                                 // 2 bytes, align float
    //   float m_flSentryRange;
    // Therefore m_flSentryRange is m_hEnemy + 8 on TF2's 32/64-bit server builds.
    constexpr int kRangeOffsetAfterEnemyHandle = 8;

    bool ResolveSentryRangeOffset(IGameConfig *gameconf, char *error, size_t maxlength)
    {
        int configuredOffset = -1;
        if (gameconf->GetOffset("CObjectSentrygun::m_flSentryRange", &configuredOffset) && configuredOffset > 0)
        {
            gSentryRangeOffset = configuredOffset;
            return true;
        }

        sm_sendprop_info_t enemyInfo;
        if (gamehelpers->FindSendPropInfo("CObjectSentrygun", "m_hEnemy", &enemyInfo))
        {
            gSentryRangeOffset = static_cast<int>(enemyInfo.actual_offset) + kRangeOffsetAfterEnemyHandle;
            return true;
        }

        if (error && maxlength)
        {
            ke::SafeSprintf(error, maxlength,
                "Could not resolve CObjectSentrygun::m_flSentryRange. Add CObjectSentrygun::m_flSentryRange to gamedata or make sure m_hEnemy is present in CObjectSentrygun sendprops.");
        }
        return false;
    }
}

DETOUR_DECL_MEMBER0(CObjectSentrygun_FindTarget, bool)
{
    SentryRangeOverride::Apply(reinterpret_cast<CBaseEntity *>(this));
    return DETOUR_MEMBER_CALL(CObjectSentrygun_FindTarget)();
}

bool SentryRangeOverride::Init(IGameConfig *gameconf, char *error, size_t maxlength)
{
    if (!ResolveSentryRangeOffset(gameconf, error, maxlength))
        return false;

    gFindTargetDetour = DETOUR_CREATE_MEMBER(CObjectSentrygun_FindTarget, "CObjectSentrygun::FindTarget");
    if (!gFindTargetDetour)
    {
        if (error && maxlength)
        {
            ke::SafeSprintf(error, maxlength,
                "Could not create detour for CObjectSentrygun::FindTarget. Check tf2_sentry_newtarget_dist.games.txt.");
        }
        return false;
    }

    gFindTargetDetour->EnableDetour();
    return true;
}

void SentryRangeOverride::Shutdown()
{
    if (gFindTargetDetour)
    {
        gFindTargetDetour->Destroy();
        gFindTargetDetour = nullptr;
    }

    gEnabled = false;
    gDistance = 200.0f;
    gSentryRangeOffset = -1;
}

void SentryRangeOverride::SetEnabled(bool enabled)
{
    gEnabled = enabled;
}

bool SentryRangeOverride::IsEnabled()
{
    return gEnabled;
}

void SentryRangeOverride::SetDistance(float distance)
{
    gDistance = std::max(0.0f, distance);
}

float SentryRangeOverride::GetDistance()
{
    return gDistance;
}

int SentryRangeOverride::GetRangeOffset()
{
    return gSentryRangeOffset;
}

void SentryRangeOverride::Apply(CBaseEntity *sentry)
{
    if (!gEnabled || !sentry || gSentryRangeOffset <= 0)
        return;

    auto *base = reinterpret_cast<std::uint8_t *>(sentry);
    *reinterpret_cast<float *>(base + gSentryRangeOffset) = gDistance;
}
