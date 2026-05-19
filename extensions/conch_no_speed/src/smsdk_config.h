#ifndef _INCLUDE_CONCH_NO_SPEED_CONFIG_H_
#define _INCLUDE_CONCH_NO_SPEED_CONFIG_H_

#define SMEXT_CONF_NAME         "Conch No Speed"
#define SMEXT_CONF_DESCRIPTION  "Adds TF2 Concheror regen buff without the speed boost"
#define SMEXT_CONF_VERSION      "1.0.0"
#define SMEXT_CONF_AUTHOR       "Hombre"
#define SMEXT_CONF_URL          ""
#define SMEXT_CONF_LOGTAG       "CONCHNOSPEED"
#define SMEXT_CONF_LICENSE      "GPL"
#define SMEXT_CONF_DATESTRING   __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD

#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_PLAYERHELPERS

#endif
