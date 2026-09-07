#if defined _team_balance_api_included
  #endinput
#endif
#define _team_balance_api_included

#include <sourcemod>

/** Returns whether the authoritative balance controller has a live operation. */
native bool TeamBalance_IsBusy();

/** Returns whether WhaleScramble's controller-owned cooldown is active. */
native bool TeamBalance_IsScrambleCooldownActive();

/** Reserves the controller while a scramble/surrender vote is displayed. */
native bool TeamBalance_BeginScrambleVote(float leaseSeconds);

/** Releases only a still-active vote reservation, never a queued scramble. */
native void TeamBalance_EndScrambleVote();

/** Upgrades an idle/vote reservation into a pending scramble operation. */
native bool TeamBalance_BeginScramble(bool bypassCooldown = false);

/** Releases a vote or pending scramble which did not move anyone. */
native void TeamBalance_CancelScramble();

/** Completes a scramble and starts its controller-owned cooldown/settle window. */
native void TeamBalance_FinishScramble(bool movedPlayers, bool countForImmunity = true);

/** Applies the controller's common validity, duel, and scramble-immunity policy. */
native bool TeamBalance_IsScrambleCandidate(int client, int expectedTeam, bool ignoreImmunity, bool allowBots);

/** Checks/consumes the store-backed scramble immunity through the controller. */
native bool TeamBalance_HasScramblePurchaseImmunity(int client);
native int TeamBalance_ConsumeScramblePurchaseImmunity(int client);

/** Atomically validates and swaps one RED/BLU pair through the controller. */
native bool TeamBalance_MoveScramblePair(int redClient, int bluClient, bool ignoreImmunity, bool allowBots, bool suppressRespawn);

/** Queues controller-owned respawn verification for setup/automatic sweeps. */
native bool TeamBalance_QueueRespawn(int client, int expectedTeam);

public SharedPlugin __pl_team_balance =
{
    name = "whalebalance",
    file = "whalebalance.smx",
    required = 1,
};
