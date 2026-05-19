#ifndef _INCLUDE_SCATTERGUN_PELLETS_CONFIG_H_
#define _INCLUDE_SCATTERGUN_PELLETS_CONFIG_H_

#define SMEXT_CONF_NAME         "Scattergun Pellets"
#define SMEXT_CONF_DESCRIPTION  "Reports TF2 scattergun and shotgun pellet counts to SourcePawn"
#define SMEXT_CONF_VERSION      "1.0.0"
#define SMEXT_CONF_AUTHOR       "Hombre"
#define SMEXT_CONF_URL          ""
#define SMEXT_CONF_LOGTAG       "SCATTERPELLETS"
#define SMEXT_CONF_LICENSE      "GPL"
#define SMEXT_CONF_DATESTRING   __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD

#define SMEXT_ENABLE_FORWARDSYS
#define SMEXT_ENABLE_PLAYERHELPERS
#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#endif
