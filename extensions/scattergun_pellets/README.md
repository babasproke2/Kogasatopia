# Scattergun Pellets

SourceMod native extension for stock Linux TF2 servers. It counts deduplicated pellets from `tf_weapon_scattergun` and weapon classes containing `tf_weapon_shotgun`, then exposes completed shot events to SourcePawn.

This package also includes the current `weaponreverts.sp` integration. The integration awards the `meatshot_kill` bonus through `PointsStore_ApplyBonusPoints` when the extension reports a full pellet kill, and uses full non-kill shotgun hits for the flame shotgun custom attribute.

## Repository Layout

```text
src/
  C++ SourceMod extension source and AMBuild files

tf/addons/sourcemod/extensions/
  scattergun_pellets.ext.2.tf2.so

tf/addons/sourcemod/gamedata/
  scattergun_pellets.games.txt
  weaponreverts.txt

tf/addons/sourcemod/scripting/
  weaponreverts.sp
  points_store.sp

tf/addons/sourcemod/scripting/include/
  scattergun_pellets.inc
  points_store_api.inc
  weaponreverts.inc
```

## Server Install

Copy the `tf/addons` tree into the server's `tf/addons` folder.

The extension binary must end up here:

```text
tf/addons/sourcemod/extensions/scattergun_pellets.ext.2.tf2.so
```

The extension gamedata must end up here:

```text
tf/addons/sourcemod/gamedata/scattergun_pellets.games.txt
```

Load or reload the extension with:

```text
sm exts load scattergun_pellets.ext.2.tf2.so
```

The SourcePawn include intentionally requires:

```sourcepawn
file = "scattergun_pellets.ext.2.tf2"
```

SourceMod strips the Linux `.so` suffix when resolving the extension key.

## SourcePawn API

```sourcepawn
forward void TF2Shotgun_OnPelletShot(int attacker, int victim, int pellets, int total, bool kill);
native int TF2Scatter_GetLastKillPellets(int attacker, int victim);
native bool TF2Scatter_WasLastKillFull(int attacker, int victim);
native bool TF2Scatter_IsCurrentShotFull(int attacker, int victim, int weapon);
native void TF2Scatter_SetWeaponPelletCount(int weapon, int pelletsFired);
```

The full-pellet check is:

```sourcepawn
pellets >= total
```

`total` is the actual pellet count registered for the weapon. The extension falls back to the stock shotgun count of 10 when no count is registered. `kill` is true when the shot produced the `player_death` event. Non-kill shots are emitted on the next game frame so the extension does not fire both a non-kill and kill event for the same shot.

## weaponreverts Integration

`weaponreverts.sp` includes:

```sourcepawn
#include <scattergun_pellets>
#include <points_store_api>
```

After applying item attributes, WeaponReverts evaluates TF2's `mult_bullets_per_shot` hook and registers the result through `TF2Scatter_SetWeaponPelletCount`. This makes full-hit checks account for custom 15- and 20-pellet weapons while preserving stock 10-pellet behavior.

When the extension fires `TF2Shotgun_OnPelletShot` with `kill=true`, the plugin checks for a full pellet kill and calls:

```sourcepawn
PointsStore_ApplyBonusPoints(attacker, 1, true, true, 1.0, "meatshot_kill");
```

The points store plugin is responsible for awarding points and printing any chat output.

The custom WeaponReverts attribute `"ignite on full pellet hit" "5"` uses `TF2Scatter_IsCurrentShotFull` in the pre-damage hook. WeaponReverts preserves bullet damage flags, suppresses the stock physics force, and defers `TF2Util_IgnitePlayer` until the corresponding post-damage hook so Dead Ringer afterburn immunity resolves first.

Useful debug commands and cvars:

```text
sm_scatterpellets_status
reverts_scattergun_pellets_debug 1
```

## Compiling SourcePawn

Compile `weaponreverts.sp` with SourceMod's `spcomp` from the scripting directory:

```bash
cd tf/addons/sourcemod/scripting
./spcomp weaponreverts.sp -i include
```

Then install the compiled plugin:

```text
tf/addons/sourcemod/plugins/weaponreverts.smx
```

`weaponreverts.sp` still depends on the same external includes/extensions it already used on the server, such as SDKHooks, TF2Items, TF2Attributes, SourceScramble, DHooks, custom attributes, and addplayerhealth.

## Compiling The Extension

The shipped `.so` is a Linux x86 build for TF2 SourceMod/Metamod. To rebuild it, use AMBuild with SourceMod, Metamod:Source, HL2SDK TF2, and the HL2SDK manifests available locally:

```bash
cd src
mkdir build
cd build
python3 ../configure.py \
  --hl2sdk-root=/path/to/hl2sdk/root \
  --hl2sdk-manifest-path=/path/to/hl2sdk-manifests \
  --sm-path=/path/to/sourcemod \
  --mms-path=/path/to/metamod-source \
  -s tf2 \
  --targets=x86 \
  --enable-optimize
ambuild
```

The output path will look like:

```text
build/scattergun_pellets.ext.2.tf2/linux-x86/scattergun_pellets.ext.2.tf2.so
```

## Implementation Notes

- Hooks `CTFPlayer::TraceAttack` on TF2 players.
- Uses SourceMod gamedata for the `TraceAttack` virtual offset.
- Counts buckshot damage from `tf_weapon_scattergun` and any weapon class containing `tf_weapon_shotgun`.
- Emits one SourcePawn forward per completed tracked shot instead of one forward per pellet.
- Exposes exact current-tick full-pellet state keyed by attacker, victim, and weapon for damage-hook consumers.
- Falls back to the attacker's active weapon when TF2 does not populate the damage-info weapon handle.
- Tracks configured pellet totals by weapon entity reference so recycled entity indexes cannot inherit stale values.
- Deduplicates repeated `TraceAttack` callbacks for the same pellet trace so a 10/10 shot is reported as `pellets=10`, not `pellets=20`.
