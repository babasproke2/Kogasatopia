# TF2 Setup Uber SourceMod extension

This SourceMod extension exposes natives that let SourcePawn plugins change the regular TF2 setup-time Medigun UberCharge multiplier. Stock TF2 regular setup time is `3.0`; the example plugin sets it to `9.0`.

## How it works

The extension detours `CWeaponMedigun::HealTargetThink()`. It lets the stock TF2 function run, reads the stock charge delta from `m_flChargeLevel`, and during setup time rescales that delta by:

```text
requested_multiplier / 3.0
```

For example, `9.0 / 3.0 = 3.0`, so the stock setup gain is tripled, resulting in 9x the normal non-setup gain.

This avoids binary-patching the `3.f` literal in the server DLL.

## Files

```text
extension.cpp
extension.h
smsdk_config.h
gamedata/tf2.setupuber.txt
scripting/include/tf2setupuber.inc
scripting/tf2setupuber_example.sp
```

## Build notes

Use the SourceMod extension SDK/sample extension build layout:

1. Copy `extension.cpp`, `extension.h`, and `smsdk_config.h` into a SourceMod extension project.
2. Make sure your build includes the SourceMod public headers and the TF2 HL2SDK.
3. Make sure `public/CDetour/detours.cpp` is compiled or linked if your template does not already include it.
4. Build the extension as `tf2setupuber.ext.so` on Linux or `tf2setupuber.ext.dll` on Windows.

I did not compile the binary in this environment because the SourceMod SDK and TF2 HL2SDK are not installed here.

## Install

```text
addons/sourcemod/extensions/tf2setupuber.ext.so
addons/sourcemod/gamedata/tf2.setupuber.txt
addons/sourcemod/scripting/include/tf2setupuber.inc
addons/sourcemod/plugins/tf2setupuber_example.smx
```

Compile the example plugin with `spcomp scripting/tf2setupuber_example.sp`.

## Configure

The example plugin creates:

```text
sm_tf2_setup_uber_multiplier "9.0"
```

Set it in `cfg/sourcemod/tf2setupuber.cfg`, or use your own plugin and call:

```sourcepawn
TF2SetupUber_SetMultiplier(9.0);
```

## Natives

```sourcepawn
native void TF2SetupUber_SetMultiplier(float multiplier);
native float TF2SetupUber_GetMultiplier();
native bool TF2SetupUber_IsAvailable();
```

## Gamedata notes

The included gamedata has Linux/Linux64 symbols and a 32-bit Windows signature for `CWeaponMedigun::HealTargetThink()`. If you run a Windows64 TF2 dedicated server and SourceMod does not fall back to the 32-bit signature, re-scan the function and add a `windows64` signature.

## Limits

This is designed mainly for raising regular setup-time charging, such as from `3.0` to `9.0`. Values lower than `3.0` work in normal cases but can be slightly conservative near the exact 100% cap because the extension observes the already-clamped stock delta.
