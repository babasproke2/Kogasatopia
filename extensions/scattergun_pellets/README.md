# Scattergun Pellets

SourceMod native extension for stock Linux TF2 servers. It counts how many scattergun pellets hit the victim on the killing shot, exposes that result to SourcePawn, and also forwards Pyro shotgun pellet hits from `tf_weapon_shotgun_pyro`.

This package also includes the current `weaponreverts.sp` integration. The integration awards the `meatshot_kill` bonus through `PointsStore_ApplyBonusPoints` when the extension reports a full pellet kill.

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
forward void TF2Scatter_OnPelletKill(int attacker, int victim, int pellets, int total);
forward void TF2Shotgun_OnPelletHit(int attacker, int victim, int weapon);
native int TF2Scatter_GetLastKillPellets(int attacker, int victim);
native bool TF2Scatter_WasLastKillFull(int attacker, int victim);
```

The full-pellet check is:

```sourcepawn
pellets == total
```

For stock scattergun kills, `total` is currently `10`.
`TF2Shotgun_OnPelletHit` fires for deduplicated pellet traces from exact class `tf_weapon_shotgun_pyro`.

## weaponreverts Integration

`weaponreverts.sp` includes:

```sourcepawn
#include <scattergun_pellets>
#include <points_store_api>
```

When the extension fires `TF2Scatter_OnPelletKill`, the plugin checks for a full pellet kill and calls:

```sourcepawn
PointsStore_ApplyBonusPoints(attacker, 1, true, true, 1.0, "meatshot_kill");
```

The points store plugin is responsible for awarding points and printing any chat output.

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
- Counts scattergun damage from `tf_weapon_scattergun` and forwards pellet hits from exact class `tf_weapon_shotgun_pyro`.
- Falls back to the attacker's active weapon when TF2 does not populate the damage-info weapon handle.
- Deduplicates repeated `TraceAttack` callbacks for the same pellet trace so a 10/10 shot is reported as `pellets=10`, not `pellets=20`.
