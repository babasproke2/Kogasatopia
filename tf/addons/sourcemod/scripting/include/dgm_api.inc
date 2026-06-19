#if defined _dgm_api_included
  #endinput
#endif
#define _dgm_api_included

#include <sourcemod>

enum DGMObjectiveLeader
{
    DGMObjectiveLeader_None = 0,
    DGMObjectiveLeader_Tie,
    DGMObjectiveLeader_Red,
    DGMObjectiveLeader_Blue
};

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
native bool DGM_ServerCapacitycheck(float capacityRatio = 0.50, bool inGameOnly = true);
native bool DGM_TeamsGameplayReady();
native bool DGM_IsRoundRunning();
native bool DGM_IsSetupActive();
native int DGM_GetLastRoundDurationSeconds();
native int DGM_GetRoundDurationSeconds(int firstTimestamp, int secondTimestamp);
native DGMObjectiveLeader DGM_GetObjectiveLeader(int &redOwned, int &blueOwned, int &neutralOwned, int &total);
native int DGM_GetObjectiveLeaderTeam();
