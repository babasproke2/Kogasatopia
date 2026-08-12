# SourceMod Include Policy

Each plugin must include only the APIs it directly uses. Do not copy a universal include block between plugins.

## Include categories

1. SourceMod/core includes: `sourcemod`, `clientprefs`, `dbi`, `files`, `textparse`, `geoip`, `basecomm`.
2. SDK/TF2 includes: `sdktools`, `sdkhooks`, `sdktools_sound`, `sdktools_gamerules`, `tf2`, `tf2_stocks`, `tf2utils`.
3. Public plugin API includes: `points_store_api`, `clans_api`, `saysounds`, `dgm_api`, etc.
4. Repo-private helper includes: `database.inc`, `steam_identity.inc`.
5. Fragile/extension includes: `dhooks`, `sourcescramble`, `socket`, `nativevotes`, `tf2items`, `tf2attributes`, `tf_custom_attributes`, `scattergun_pellets`.

## Include order

Use this order at the top of every `.sp` file:

1. `#pragma semicolon 1`
2. `#pragma newdecls required`
3. SourceMod/core includes
4. SDK/engine includes
5. TF2 includes
6. Required third-party APIs
7. Optional plugin APIs
8. Optional extensions
9. Repo-private helpers
10. Local implementation fragments

## Optional dependencies

Optional plugin APIs must be wrapped narrowly:

```sourcepawn
#undef REQUIRE_PLUGIN
#include <some_api>
#define REQUIRE_PLUGIN
```

Optional extensions must be wrapped narrowly:

```sourcepawn
#undef REQUIRE_EXTENSIONS
#include <some_extension>
#define REQUIRE_EXTENSIONS
```

Every optional native that may be called must be marked with `MarkNativeAsOptional` in `AskPluginLoad2` and guarded at runtime.

## Public APIs

If one plugin exposes natives that another plugin calls, those native declarations belong in `scripting/include/<name>_api.inc`.

Do not manually declare another plugin's natives inside a `.sp` file except as a temporary migration step.

## Local helpers

Repo-private stock/helper includes should be named for their responsibility, have include guards, and avoid declaring plugin natives.

## Large plugins

Large integration plugins may have large include blocks, but only when each dependency is actually used. These files should not be copied as templates for smaller plugins.

## Statistics timestamps

The public `plugin_statistics.inc` API defers statistics writes to the Rust provider and exposes its observed and expected tickrate values. The provider stamps Unix epoch timestamps, map-session context, and tickrate fields.

## Current layout

```text
scripting/include/
  Public plugin APIs: *_api.inc, saysounds.inc, amplifier.inc, conch_no_speed.inc
  Repo-private helpers: database.inc, steam_identity.inc, client_validation.inc, buildings.inc, tf2_classes.inc, item_indexes.inc
  Public statistics API: plugin_statistics.inc
  Legacy / to migrate: addplayerhealth.inc
```

# SourceMod API Includes

Only plugin-facing natives and forwards are listed here; internal stock helper files are not part of this API list.

## autobalance_4teams_api.inc
- `Autobalance_HasPendingTeamSwap` - Returns whether a client has an incoming team-swap request.

## amplifier.inc
- `Amplifier_WouldReplaceBuilding` - Returns whether a build request would become an amplifier instead of the requested object.

## clans_api.inc
- `Clans_GetTags` - Writes a client's display clan tags into a buffer.
- `Clans_GetSameTeamClanMemberCount` - Counts connected teammates who share the client's clan.

## conch_no_speed.inc
- `TF2ConchNoSpeed_AddRegenBuff` - Starts a Concheror-style regen buff without speed on a client.
- `TF2ConchNoSpeed_RemoveRegenBuff` - Removes the no-speed regen buff from a client.
- `TF2ConchNoSpeed_IsRegenBuffActive` - Returns whether the no-speed regen buff is active for a client.

## custom_hats_api.inc
- `CustomHats_GetPrefix` - Writes the configured chat prefix for a client's active custom hat.
- `CustomHats_GetTagChoices` - Writes the available custom hat tag choices for a client.
- `CustomHats_ResolveTag` - Resolves a custom hat tag key into display text.
- `CustomHats_FindTagSource` - Finds the custom hat tag key that produced a display tag.

## cwx.inc
- `CWX_SetPlayerLoadoutItem` - Stores a custom item UID in a player's class loadout slot.
- `CWX_RemovePlayerLoadoutItem` - Removes a custom item UID from a player's class loadout slot.
- `CWX_GetPlayerLoadoutItem` - Reads a custom item UID from a player's class loadout slot.
- `CWX_EquipPlayerItem` - Equips a custom item UID on a player.
- `CWX_CanPlayerAccessItem` - Returns whether a player can use a custom item UID.
- `CWX_GetItemList` - Returns custom item UIDs filtered by an optional callback.
- `CWX_IsItemUIDValid` - Returns whether a custom item UID exists.
- `CWX_GetItemUIDFromEntity` - Writes the custom item UID attached to an entity into a buffer.
- `CWX_GetItemLoadoutSlot` - Returns the TF2 loadout slot used by a custom item for a class.
- `CWX_GetItemExtData` - Returns a copy of a custom item's extended KeyValues section.

## dgm_api.inc
- `DGM_GetGameMode` - Writes the current display gamemode into a buffer.
- `DGM_RealPlayerCount` - Counts real human players on the server.
- `DGM_RealTeamPlayerCount` - Counts real human players on a team.
- `DGM_GetGameModeKey` - Writes the current stable gamemode key into a buffer.
- `DGM_GetGameModeKeyForMap` - Resolves a map name to its stable gamemode key.
- `DGM_IsSmallFormatGamemode` - Returns whether the current gamemode is small-format.
- `DGM_NormalizeMapName` - Writes a normalized map name for config lookups.
- `DGM_CurrentNormalizedMap` - Writes the normalized current map name into a buffer.
- `DGM_GetServerCapacity` - Returns the configured server capacity.
- `DGM_GetPopulationRatio` - Returns real players divided by server capacity.
- `DGM_ServerCapacitycheck` - Returns whether population meets a capacity ratio.
- `DGM_TeamsGameplayReady` - Returns whether both teams are ready for gameplay checks.
- `DGM_IsRoundRunning` - Returns whether a round is active.
- `DGM_IsSetupActive` - Returns whether setup time is active.
- `DGM_GetLastRoundDurationSeconds` - Returns the previous round length in seconds.
- `DGM_GetRoundDurationSeconds` - Returns the seconds between two round timestamps.
- `DGM_GetRecentControlPointCaptureIntervalSeconds` - Returns the latest capture interval on maps with more than two control points.
- `DGM_GetObjectiveLeader` - Counts objective ownership and returns the leading side.
- `DGM_GetObjectiveLeaderTeam` - Returns the team currently leading objective ownership.

## filters_api.inc
- `Filters_IsRedlisted` - Returns whether a client is redlisted.
- `Filters_GetChatName` - Writes the filtered/colorized chat name for a client.
- `Filters_GetSteamIdColorTag` - Writes the color token associated with a SteamID64.
- `Filters_GetSteamIdChatName` - Resolves and renders an online or offline SteamID64 name using prenames and stored colors.
- `Filters_GetLastRecordedSteamName` - Writes the last recorded Steam name for a SteamID64.

## hugs_api.inc
- `Hugs_GetRapesGiven` - Returns how many rapes a client has given in hugs stats.
- `Hugs_AreStatsLoaded` - Returns whether a client's hugs stats are loaded.
- `Hugs_RedeemMailedHug` - Credits a mailed hug using sender and receiver SteamID64 identities.
- `Hugs_RedeemMailedFeed` - Credits a mailed feed using sender and receiver SteamID64 identities.
- `Hugs_RedeemMailedRape` - Credits a mailed rape using sender and receiver SteamID64 identities.
- `Hugs_AnnounceMailedInteraction` - Reprints a redeemed mailed interaction without changing statistics.

## mutecheck_api.inc
- `MuteCheck_GetMutedClientCount` - Returns how many connected human clients the listener has muted.

## points_store_api.inc
- `PointsStore_AreBonusPointsLoaded` - Returns whether a client's currency cache is ready.
- `PointsStore_GetBonusPoints` - Returns a client's current currency balance.
- `PointsStore_ApplyBonusPoints` - Applies a configured reward to a connected client by reward ID.
- `PointsStore_ApplyBonusPointsSteamId` - Applies a configured reward by reward ID to a SteamID64.
- `PointsStore_GetRewardAmount` - Returns a configured reward's currency amount.
- `PointsStore_GetRewardPerMapLimit` - Returns a configured reward's per-map limit.
- `PointsStore_GetRewardLongName` - Returns a configured reward's long display name.
- `PointsStore_GetRewardShortDescription` - Returns a configured reward's short description.
- `PointsStore_GetRewardLongDescription` - Returns a configured reward's long description.
- `PointsStore_ApplyBonusPointsSteamIdOnce` - Applies an offline-safe currency award once for a stable key.
- `PointsStore_OnApplyBonusPointsSteamIdOnce` - Reports the confirmed result of an idempotent currency award.
- `PointsStore_RefundBonusPoints` - Refunds a dynamic amount to a connected client.
- `PointsStore_RefundBonusPointsSteamId` - Refunds a dynamic amount to a SteamID64.
- `PointsStore_SpendBonusPoints` - Spends a connected client's currency without chat or sound output.
- `PointsStore_HasPurchase` - Returns whether a client owns a shop item.
- `PointsStore_GetPurchasePrice` - Returns the price paid for a shop item.
- `PointsStore_GetPurchaseExpiresAt` - Returns a shop item's expiry timestamp for a client.
- `PointsStore_GetPurchaseUsesRemaining` - Returns remaining uses for a limited-use shop item.
- `PointsStore_ConsumePurchaseUse` - Consumes one use from a limited-use shop item.

## rtd_api.inc
- `RTD_ApplyGiftedRoll` - Applies a no-charge gifted roll while retaining normal RTD eligibility checks.

## saysounds.inc
- `SaySounds_ShouldPlay` - Returns whether a client should hear say sounds.
- `SaySounds_PlaySoundToOptedIn` - Plays a sound path to opted-in clients for a group.
- `SaySounds_PlayCommand` - Runs a say-sound command for a client.
- `SaySounds_PlayCommandAs` - Runs a say-sound command with separate source and target clients.
- `SaySounds_CanClientUseCommand` - Returns whether a client can use a say-sound command.
- `SaySounds_IsCommandPaid` - Returns whether a say-sound command costs currency.
- `SaySounds_GetCommandGroup` - Writes a say-sound command's group into a buffer.

## server_mail.inc
- `ServerMail_Send` - Sends ordinary mail between connected clients.
- `ServerMail_SendCustom` - Sends custom-titled mail between connected clients.
- `ServerMail_SendCurrency` - Sends currency mail between connected clients.
- `ServerMail_SendSteamId` - Sends ordinary mail to an offline-capable SteamID64.
- `ServerMail_SendCustomSteamId` - Sends custom-titled mail to an offline-capable SteamID64.
- `ServerMail_SendCurrencySteamId` - Sends idempotent currency mail to an offline-capable SteamID64.
- `ServerMail_CheckPendingStimulus` - Checks a participating client for pending deployed Stimulus Checks.
- `ServerMail_OnMailSendResult` - Reports the confirmed result of an API mail insert.

## scattergun_pellets.inc
- `TF2Shotgun_OnPelletShot` - Fires when shotgun pellet damage is recorded.
- `TF2Scatter_GetLastKillPellets` - Returns pellet count for the last matching scattergun kill.
- `TF2Scatter_WasLastKillFull` - Returns whether the last matching scattergun kill used a full pellet hit.

## tags_api.inc
- `Tags_GetTag` - Writes the resolved tag for a live client or SteamID64.
- `Tags_GetSelectedTag` - Writes a live client's selected/resolved tag.
- `Tags_SetSelectedTag` - Sets a live client's selected tag.

## tf2_sentry_newtarget_dist.inc
- `TF2SentryNewTarget_SetEnabled` - Enables or disables the sentry target-distance override.
- `TF2SentryNewTarget_SetDistance` - Sets the sentry target-distance override.
- `TF2SentryNewTarget_GetRangeOffset` - Returns the sendprop offset used for sentry range changes.

## tf2_setuptime.inc
- `TF2_IsSetupTimeActive` - Returns whether TF2 setup time is active.

## tf2setupuber.inc
- `TF2SetupUber_SetMultiplier` - Sets the setup ubercharge multiplier.
- `TF2SetupUber_GetMultiplier` - Returns the current setup ubercharge multiplier.
- `TF2SetupUber_IsAvailable` - Returns whether the setup uber extension is loaded.
- `TF2SetupUber_GetDetourCallCount` - Returns how many times the setup uber detour has run.
- `TF2SetupUber_GetAdjustmentCount` - Returns how many setup uber adjustments were applied.
- `TF2SetupUber_WasLastSetupActive` - Returns whether setup was active on the last detour call.
- `TF2SetupUber_GetLastBefore` - Returns the last charge value before adjustment.
- `TF2SetupUber_GetLastAfter` - Returns the last charge value after stock logic.
- `TF2SetupUber_GetLastNew` - Returns the last charge value after custom adjustment.
- `TF2SetupUber_GetLastStockDelta` - Returns the last stock charge delta.

## weaponreverts_api.inc
- `WeaponReverts_GetWeaponInfo` - Writes configured weapon revert display data for an item index.
- `WeaponReverts_CanClassUseWeapon` - Returns whether a class can use an item index from weapons.cfg.

## whaletracker_api.inc
- `WhaleTracker_GetCumulativeKills` - Returns a client's cumulative tracked kills.
- `WhaleTracker_AreStatsLoaded` - Returns whether a client's WhaleTracker stats are loaded.
- `WhaleTracker_HasPlaytimeHours` - Returns whether a client's playtime meets an hour threshold.
- `WhaleTracker_GetRankedPlaytimeHours` - Returns whole playtime hours for a ranked client or Steam identity.
- `WhaleTracker_GetRankedPlaytimeSeconds` - Returns exact playtime seconds for a ranked client or Steam identity.
- `WhaleTracker_GetWhalePoints` - Returns a client's current Whale Points total.
- `WhaleTracker_ComputeWhalePoints` - Computes Whale Points from raw cumulative totals.
- `WhaleTracker_GetLastRecordedName` - Writes the best recorded name for a SteamID64 into a buffer.
- `WhaleTracker_GetLastSeen` - Returns the best known last-seen timestamp for a SteamID64.
- `WhaleTracker_OnAirshot` - Fires when WhaleTracker records an airshot.
- `WhaleTracker_OnProjectileDirectHit` - Fires when WhaleTracker records a projectile direct hit.
- `WhaleTracker_OnMedicDrop` - Fires when WhaleTracker records a medic drop.
- `WhaleTracker_OnKillstreak` - Fires when WhaleTracker records a killstreak milestone.
- `WhaleTracker_OnKillstreakEnd` - Fires when WhaleTracker records the end of a killstreak.
- `WhaleTracker_OnMultikill` - Fires when WhaleTracker records a multikill milestone.
