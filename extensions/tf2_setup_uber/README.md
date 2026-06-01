# TF2 Setup Uber SourceMod Extension

This extension exposes a small SourceMod native API so a plugin can change TF2's regular setup-time Medigun UberCharge build multiplier.

Stock TF2 uses a `3.0` multiplier for normal setup time. Setting the extension multiplier to `9.0` makes setup-time Medigun charge gain `9x` the normal non-setup rate.

## Important v1.1 fix

The original v1.0 package detoured `CWeaponMedigun::HealTargetThink()`. That was the wrong function for this job. TF2 applies the actual Medigun charge gain, including the setup-time `* 3.f` multiplier, in `CWeaponMedigun::FindAndHealTargets()`.

v1.1 detours `CWeaponMedigun::FindAndHealTargets()` instead, lets stock TF2 calculate the normal charge delta, then rescales the delta while GameRules reports setup time.

## Native API

```sourcepawn
native void TF2SetupUber_SetMultiplier(float multiplier);
native float TF2SetupUber_GetMultiplier();
native bool TF2SetupUber_IsAvailable();
```

Additional diagnostics are available for testing:

```sourcepawn
native int TF2SetupUber_GetDetourCallCount();
native int TF2SetupUber_GetAdjustmentCount();
native bool TF2SetupUber_WasLastSetupActive();
native float TF2SetupUber_GetLastBefore();
native float TF2SetupUber_GetLastAfter();
native float TF2SetupUber_GetLastNew();
native float TF2SetupUber_GetLastStockDelta();
```

## Example plugin

The included plugin creates:

```text
sm_tf2_setup_uber_multiplier "9.0"
```

It also registers this server-console status command:

```text
sm_tf2_setupuber_status
```

After a Medic heals someone during setup, a working build should show a non-zero `detour_calls` value. If the multiplier is not `3.0` and setup is active, `adjustments` should increase and `new` should differ from `after`.

## Build notes

This is source code for a SourceMod extension. Build it from a normal SourceMod extension/sample-ext environment with the TF2 HL2SDK and SourceMod public headers available.

Typical source layout:

```text
extension.cpp
extension.h
smsdk_config.h
gamedata/tf2.setupuber.txt
scripting/include/tf2setupuber.inc
scripting/tf2setupuber_example.sp
```

Then copy the built extension binary to:

```text
addons/sourcemod/extensions/
```

Copy the gamedata file to:

```text
addons/sourcemod/gamedata/tf2.setupuber.txt
```

Compile the example plugin and place it in:

```text
addons/sourcemod/plugins/
```

## Gamedata/platform notes

The included gamedata has Linux and Linux64 symbols for:

```text
CWeaponMedigun::FindAndHealTargets()
```

The previous v1.0 Windows signature targeted `HealTargetThink()`, which was the wrong function. Windows and Windows64 therefore need a fresh byte signature for `FindAndHealTargets()` from the current TF2 server binary.

If the extension fails to load on Windows with a missing signature error, update `addons/sourcemod/gamedata/tf2.setupuber.txt` with a valid Windows signature for `CWeaponMedigun::FindAndHealTargets()`.
