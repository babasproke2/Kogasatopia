#if defined _dgm_api_included
  #endinput
#endif
#define _dgm_api_included

native bool DGM_GetGameMode(char[] buffer, int maxlen);
native int DGM_RealPlayerCount();
native bool DGM_GetGameModeKey(char[] buffer, int maxlen);
native bool DGM_NormalizeMapName(const char[] input, char[] output, int maxlen);
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50);
