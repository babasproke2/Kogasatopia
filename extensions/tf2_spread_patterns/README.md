# TF2 Spread Patterns

Provides per-weapon bullet spread controls without replacing TF2's bullet firing logic.

## API

`TF2Spread_SetPattern(weapon, pattern)` assigns `TF2Spread_Default`, `TF2Spread_Circular15`, or
`TF2Spread_WideHorizontal20` to a weapon entity.

Overrides are stored with entity references, so recycled entity indexes do not inherit a pattern.

The circular pattern uses TF2's native 15-pellet fixed-spread path and retains its small random jitter.

The wide-horizontal pattern assigns 20 deterministic directions in two rows of 10 at 150% of the
weapon's stock horizontal spread without changing TF2's fixed-spread table. CWX and WeaponReverts
enable it with the custom attribute
`"wide horizontal bullet spread" "1"`; it takes priority over the circular pattern.

`TF2Spread_SetAmbassadorAccuracy(weapon, enabled)` adds Ambassador-style spread recovery. It retains
the weapon's original spread for 0.5 seconds, recovers linearly, and reaches exact first-shot accuracy
after 1.0 second.

`TF2Spread_IsAmbassadorAccuracyRecovered(weapon)` returns true when an enabled weapon has not fired
for at least 1.0 second.

`TF2Weapon_SetPunchAngle(weapon, amount, consistent)` replaces a weapon's stock punch-angle recoil.
Consistent mode applies the exact integer amount. Non-consistent mode calls TF2's own
`SharedRandomInt("ShotgunPunchAngle", amount - 1, amount + 1)` path. Passing zero clears the
override.

## Building

The default build target is 32-bit x86, matching TF2's SourceMod runtime. Pass an explicit
`--targets` value only when building for a different runtime architecture.
