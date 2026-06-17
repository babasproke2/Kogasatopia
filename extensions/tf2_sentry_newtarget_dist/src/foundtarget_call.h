#ifndef _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_FOUNDTARGET_CALL_H_
#define _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_FOUNDTARGET_CALL_H_

#include "extension.h"
#include <mathlib/vector.h>

class CBaseEntity;

namespace SentryFoundTarget
{
    bool Init(IGameConfig *gameconf, char *error, size_t maxlength);
    void Shutdown();
    bool IsReady();
    void Call(CBaseEntity *sentry, CBaseEntity *target, const Vector &soundCenter, bool noSound);
}

#endif
