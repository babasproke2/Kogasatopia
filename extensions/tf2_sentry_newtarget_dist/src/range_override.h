#ifndef _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_RANGE_OVERRIDE_H_
#define _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_RANGE_OVERRIDE_H_

#include "extension.h"
#include "CDetour/detours.h"

class CBaseEntity;

namespace SentryRangeOverride
{
    bool Init(IGameConfig *gameconf, char *error, size_t maxlength);
    void Shutdown();

    void SetEnabled(bool enabled);
    bool IsEnabled();

    void SetDistance(float distance);
    float GetDistance();

    int GetRangeOffset();
    void Apply(CBaseEntity *sentry);
}

#endif
