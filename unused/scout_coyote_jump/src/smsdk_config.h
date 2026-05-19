#ifndef _INCLUDE_SCOUT_COYOTE_JUMP_CONFIG_H_
#define _INCLUDE_SCOUT_COYOTE_JUMP_CONFIG_H_

#define SMEXT_CONF_NAME         "Scout Coyote Jump"
#define SMEXT_CONF_DESCRIPTION  "Adds a small coyote-time ground jump window for TF2 Scout"
#define SMEXT_CONF_VERSION      "1.0.0"
#define SMEXT_CONF_AUTHOR       "Scout Coyote Jump contributors"
#define SMEXT_CONF_URL          ""
#define SMEXT_CONF_LOGTAG       "SCOUTCOYOTE"
#define SMEXT_CONF_LICENSE      "GPL"
#define SMEXT_CONF_DATESTRING   __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD

#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_PLAYERHELPERS
#define SMEXT_ENABLE_GAMEHELPERS

#endif
