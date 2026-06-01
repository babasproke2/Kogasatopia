/**
 * vim: set ts=4 :
 * =============================================================================
 * TF2 SetupTime SourceMod Extension
 * =============================================================================
 */

#ifndef _INCLUDE_TF2_SETUPTIME_EXTENSION_CONFIG_H_
#define _INCLUDE_TF2_SETUPTIME_EXTENSION_CONFIG_H_

/** Basic information exposed publicly. */
#define SMEXT_CONF_NAME        "TF2 SetupTime"
#define SMEXT_CONF_DESCRIPTION "Exposes TF2 setup-time state to SourcePawn"
#define SMEXT_CONF_VERSION     "1.0.0"
#define SMEXT_CONF_AUTHOR      "Hombre"
#define SMEXT_CONF_URL         "https://www.sourcemod.net/"
#define SMEXT_CONF_LOGTAG      "TF2SETUP"
#define SMEXT_CONF_LICENSE     "GPL"
#define SMEXT_CONF_DATESTRING  __DATE__

/** Exposes extension's main interface. */
#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

/** Needed because this extension reads TF2 server classes via IServerGameDLL. */
#define SMEXT_CONF_METAMOD

/** Needed for gamehelpers->FindSendPropInfo(). */
#define SMEXT_ENABLE_GAMEHELPERS

#endif // _INCLUDE_TF2_SETUPTIME_EXTENSION_CONFIG_H_
