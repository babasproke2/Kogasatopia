/**
 * TF2 Setup Uber SourceMod extension configuration.
 */
#ifndef _INCLUDE_TF2_SETUP_UBER_CONFIG_H_
#define _INCLUDE_TF2_SETUP_UBER_CONFIG_H_

#define SMEXT_CONF_NAME          "TF2 Setup Uber"
#define SMEXT_CONF_DESCRIPTION   "Lets SourceMod plugins change the TF2 setup-time Medigun UberCharge multiplier"
#define SMEXT_CONF_VERSION       "1.0.0.0"
#define SMEXT_CONF_AUTHOR        "Hombre"
#define SMEXT_CONF_URL           "https://www.sourcemod.net/"
#define SMEXT_CONF_LOGTAG        "TF2SETUPUBER"
#define SMEXT_CONF_LICENSE       "GPLv3"
#define SMEXT_CONF_DATESTRING    __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

/* We do not need Metamod interfaces; CDetour and SDKTools are enough. */
//#define SMEXT_CONF_METAMOD

#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#endif /* _INCLUDE_TF2_SETUP_UBER_CONFIG_H_ */
