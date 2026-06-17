#ifndef _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_EXTENSION_H_
#define _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_EXTENSION_H_

#include "smsdk_ext.h"

class TF2SentryNewTargetExt : public SDKExtension
{
public:
    bool SDK_OnLoad(char *error, size_t maxlength, bool late) override;
    void SDK_OnUnload() override;
};

extern TF2SentryNewTargetExt g_TF2SentryNewTargetExt;
extern IGameConfig *g_pGameConf;

#endif
