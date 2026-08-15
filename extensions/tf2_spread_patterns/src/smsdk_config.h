#ifndef _INCLUDE_TF2_SPREAD_PATTERNS_CONFIG_H_
#define _INCLUDE_TF2_SPREAD_PATTERNS_CONFIG_H_

#define SMEXT_CONF_NAME         "TF2 Spread Patterns"
#define SMEXT_CONF_DESCRIPTION  "Per-weapon bullet spread controls for TF2"
#define SMEXT_CONF_VERSION      "1.2.0"
#define SMEXT_CONF_AUTHOR       "Hombre"
#define SMEXT_CONF_URL          ""
#define SMEXT_CONF_LOGTAG       "TF2SPREAD"
#define SMEXT_CONF_LICENSE      "GPL"
#define SMEXT_CONF_DATESTRING   __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD

#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#endif
