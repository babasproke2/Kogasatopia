/**
 * vim: set ts=4 :
 * =============================================================================
 * TF2 SetupTime SourceMod Extension
 * =============================================================================
 */

#ifndef _INCLUDE_TF2_SETUPTIME_EXTENSION_H_
#define _INCLUDE_TF2_SETUPTIME_EXTENSION_H_

#include "smsdk_ext.h"

#include <IGameHelpers.h>
#include <server_class.h>
#include <dt_send.h>

class TF2SetupTimeExtension : public SDKExtension
{
public:
    bool SDK_OnLoad(char *error, size_t maxlength, bool late) override;
};

extern TF2SetupTimeExtension g_TF2SetupTimeExtension;

#endif // _INCLUDE_TF2_SETUPTIME_EXTENSION_H_
