#include "extension.h"
#include "foundtarget_call.h"

#include <cstring>
#include <mathlib/vector.h>

namespace
{
    bool gEnabled = false;
    float gDistance = 200.0f;

    static cell_t Native_SetEnabled(IPluginContext *ctx, const cell_t *params)
    {
        gEnabled = params[1] != 0;
        return 0;
    }

    static cell_t Native_SetDistance(IPluginContext *ctx, const cell_t *params)
    {
        gDistance = sp_ctof(params[1]);
        if (gDistance < 0.0f)
            gDistance = 0.0f;
        return 0;
    }

    static cell_t Native_FoundTarget(IPluginContext *ctx, const cell_t *params)
    {
        if (!SentryFoundTarget::IsReady())
            return ctx->ThrowNativeError("CObjectSentrygun::FoundTarget is not available");

        CBaseEntity *sentry = gamehelpers->ReferenceToEntity(params[1]);
        if (!sentry)
            return ctx->ThrowNativeError("Invalid sentry entity/ref %d", params[1]);

        const char *classname = gamehelpers->GetEntityClassname(sentry);
        if (!classname || std::strcmp(classname, "obj_sentrygun") != 0)
            return ctx->ThrowNativeError("Entity %d is not obj_sentrygun", params[1]);

        CBaseEntity *target = gamehelpers->ReferenceToEntity(params[2]);
        if (!target)
            return ctx->ThrowNativeError("Invalid target entity/ref %d", params[2]);

        cell_t *vecCells = nullptr;
        ctx->LocalToPhysAddr(params[3], &vecCells);
        Vector soundCenter(sp_ctof(vecCells[0]), sp_ctof(vecCells[1]), sp_ctof(vecCells[2]));

        bool noSound = params[4] != 0;
        SentryFoundTarget::Call(sentry, target, soundCenter, noSound);
        return 0;
    }
}

sp_nativeinfo_t g_TF2SentryNewTargetNatives[] =
{
    {"TF2SentryNewTarget_SetEnabled", Native_SetEnabled},
    {"TF2SentryNewTarget_SetDistance", Native_SetDistance},
    {"TF2SentryNewTarget_FoundTarget", Native_FoundTarget},
    {nullptr, nullptr}
};
