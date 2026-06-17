#include "extension.h"
#include "range_override.h"

namespace
{
    static cell_t Native_SetEnabled(IPluginContext *ctx, const cell_t *params)
    {
        SentryRangeOverride::SetEnabled(params[1] != 0);
        return 0;
    }

    static cell_t Native_SetDistance(IPluginContext *ctx, const cell_t *params)
    {
        SentryRangeOverride::SetDistance(sp_ctof(params[1]));
        return 0;
    }

    static cell_t Native_GetRangeOffset(IPluginContext *ctx, const cell_t *params)
    {
        return SentryRangeOverride::GetRangeOffset();
    }
}

sp_nativeinfo_t g_TF2SentryNewTargetNatives[] =
{
    {"TF2SentryNewTarget_SetEnabled", Native_SetEnabled},
    {"TF2SentryNewTarget_SetDistance", Native_SetDistance},
    {"TF2SentryNewTarget_GetRangeOffset", Native_GetRangeOffset},
    {nullptr, nullptr}
};
