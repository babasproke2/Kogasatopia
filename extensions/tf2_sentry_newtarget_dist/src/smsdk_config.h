#ifndef _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_CONFIG_H_
#define _INCLUDE_TF2_SENTRY_NEWTARGET_DIST_CONFIG_H_

#define SMEXT_CONF_NAME            "TF2 Sentry NewTarget Dist"
#define SMEXT_CONF_DESCRIPTION     "Native helper for configurable TF2 sentry target switching."
#define SMEXT_CONF_VERSION         "1.0.0"
#define SMEXT_CONF_AUTHOR          "Hombre"
#define SMEXT_CONF_URL             ""
#define SMEXT_CONF_LOGTAG          "TF2SentryNewTarget"
#define SMEXT_CONF_LICENSE         "GPLv3"
#define SMEXT_CONF_DATESTRING      __DATE__

#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#endif
