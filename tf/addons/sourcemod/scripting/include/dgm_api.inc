#if defined _dgm_api_included
  #endinput
#endif
#define _dgm_api_included

native bool DGM_GetGameMode(char[] buffer, int maxlen);
native int DGM_RealPlayerCount();
native int DGM_RealTeamPlayerCount(int team);
native bool DGM_GetGameModeKey(char[] buffer, int maxlen);
native bool DGM_GetGameModeKeyForMap(const char[] mapName, char[] buffer, int maxlen);
native bool DGM_IsSmallFormatGamemode();
native bool DGM_NormalizeMapName(const char[] input, char[] output, int maxlen);
native bool DGM_CurrentNormalizedMap(char[] buffer, int maxlen);
native int DGM_GetServerCapacity();
native float DGM_GetPopulationRatio();
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50);
native bool DGM_IsRoundRunning();
native int DGM_GetLastRoundDurationSeconds();
native int DGM_GetRoundDurationSeconds(int firstTimestamp, int secondTimestamp);
