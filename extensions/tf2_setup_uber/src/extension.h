#ifndef _INCLUDE_TF2_SETUP_UBER_EXTENSION_H_
#define _INCLUDE_TF2_SETUP_UBER_EXTENSION_H_

#include "smsdk_ext.h"

/**
 * Main extension object.
 */
class TF2SetupUberExt : public SDKExtension
{
public:
    virtual bool SDK_OnLoad(char *error, size_t maxlength, bool late);
    virtual void SDK_OnUnload();
    virtual void SDK_OnAllLoaded();
    virtual bool QueryRunning(char *error, size_t maxlength);
};

#endif /* _INCLUDE_TF2_SETUP_UBER_EXTENSION_H_ */
