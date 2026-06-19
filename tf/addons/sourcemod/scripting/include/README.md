# SourceMod API Includes

Only plugin-facing natives and forwards are listed here; internal stock helper files are not part of this API list.

## amplifier.inc
- `Amplifier_WouldReplaceBuilding` - Returns whether a build request would become an amplifier instead of the requested object.

## clans_api.inc
- `Clans_GetTags` - Writes a client's display clan tags into a buffer.
- `Clans_GetSameTeamClanMemberCount` - Counts connected teammates who share the client's clan.

## conch_no_speed.inc
- `TF2ConchNoSpeed_AddRegenBuff` - Starts a Concheror-style regen buff without speed on a client.
- `TF2ConchNoSpeed_RemoveRegenBuff` - Removes the no-speed regen buff from a client.
- `TF2ConchNoSpeed_IsRegenBuffActive` - Returns whether the no-speed regen buff is active for a client.

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
- `DGM_GetObjectiveLeader` - Counts objective ownership and returns the leading side.
- `DGM_GetObjectiveLeaderTeam` - Returns the team currently leading objective ownership.

## points_store_api.inc
- `PointsStore_AreBonusPointsLoaded` - Returns whether a client's currency cache is ready.
- `PointsStore_GetBonusPoints` - Returns a client's current currency balance.
- `PointsStore_ApplyBonusPoints` - Applies a currency delta to a connected client.
- `PointsStore_ApplyBonusPointsSteamId` - Applies a currency delta to a SteamID64, including offline players.
- `PointsStore_SpendBonusPoints` - Spends a connected client's currency without chat or sound output.
- `PointsStore_HasPurchase` - Returns whether a client owns a shop item.
- `PointsStore_GetPurchasePrice` - Returns the price paid for a shop item.
- `PointsStore_GetPurchaseExpiresAt` - Returns a shop item's expiry timestamp for a client.
- `PointsStore_GetPurchaseUsesRemaining` - Returns remaining uses for a limited-use shop item.
- `PointsStore_ConsumePurchaseUse` - Consumes one use from a limited-use shop item.

## saysounds.inc
- `SaySounds_ShouldPlay` - Returns whether a client should hear say sounds.
- `SaySounds_PlaySoundToOptedIn` - Plays a sound path to opted-in clients for a group.
- `SaySounds_PlayCommand` - Runs a say-sound command for a client.
- `SaySounds_PlayCommandAs` - Runs a say-sound command with separate source and target clients.
- `SaySounds_CanClientUseCommand` - Returns whether a client can use a say-sound command.
- `SaySounds_IsCommandPaid` - Returns whether a say-sound command costs currency.
- `SaySounds_GetCommandGroup` - Writes a say-sound command's group into a buffer.

## scattergun_pellets.inc
- `TF2Shotgun_OnPelletShot` - Fires when shotgun pellet damage is recorded.
- `TF2Scatter_GetLastKillPellets` - Returns pellet count for the last matching scattergun kill.
- `TF2Scatter_WasLastKillFull` - Returns whether the last matching scattergun kill used a full pellet hit.

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
- `WeaponReverts_CanClassUseWeapon` - Returns whether a class can use an item index from weaponreverts.cfg.
