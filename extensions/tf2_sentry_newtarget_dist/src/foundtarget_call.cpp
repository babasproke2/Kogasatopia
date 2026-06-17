#include "foundtarget_call.h"

#include <cstring>

namespace
{
    class CObjectSentrygunThunk {};
    using FoundTargetFn = void (CObjectSentrygunThunk::*)(CBaseEntity *, const Vector &, bool);

    FoundTargetFn gFoundTarget = nullptr;

    template <typename T>
    T MemberFnFromAddress(void *address)
    {
        T fn;
        std::memset(&fn, 0, sizeof(fn));
        std::memcpy(&fn, &address, sizeof(address));
        return fn;
    }
}

bool SentryFoundTarget::Init(IGameConfig *gameconf, char *error, size_t maxlength)
{
    void *address = nullptr;
    if (!gameconf->GetMemSig("CObjectSentrygun::FoundTarget", &address) || !address)
    {
        if (error && maxlength)
        {
            ke::SafeSprintf(error, maxlength,
                "Could not resolve CObjectSentrygun::FoundTarget from tf2_sentry_newtarget_dist.games.txt");
        }
        return false;
    }

    gFoundTarget = MemberFnFromAddress<FoundTargetFn>(address);
    return true;
}

void SentryFoundTarget::Shutdown()
{
    gFoundTarget = nullptr;
}

bool SentryFoundTarget::IsReady()
{
    return gFoundTarget != nullptr;
}

void SentryFoundTarget::Call(CBaseEntity *sentry, CBaseEntity *target, const Vector &soundCenter, bool noSound)
{
    CObjectSentrygunThunk *obj = reinterpret_cast<CObjectSentrygunThunk *>(sentry);
    (obj->*gFoundTarget)(target, soundCenter, noSound);
}
