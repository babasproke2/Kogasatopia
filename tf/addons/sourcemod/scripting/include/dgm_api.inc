#if defined _dgm_api_included
  #endinput
#endif
#define _dgm_api_included

native bool DGM_GetGameMode(char[] buffer, int maxlen);
native bool ServerCapacityCheck(float capacityRatio = 0.50);
