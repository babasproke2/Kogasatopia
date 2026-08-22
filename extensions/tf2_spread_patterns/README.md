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

`TF2Weapon_SetPunchAngle(weapon, enabled, amount, consistent)` replaces a weapon's stock
punch-angle recoil. Consistent mode applies the exact integer amount. Non-consistent mode calls
TF2's own `SharedRandomInt("ShotgunPunchAngle", amount - 1, amount + 1)` path. An enabled override
with amount `0` suppresses stock recoil without adding punch angle. Pass `enabled = false` to clear
the override.

```sourcepawn
TF2Weapon_SetPunchAngle(weapon, true, 0, true);  // No recoil.
TF2Weapon_SetPunchAngle(weapon, true, 4, true);  // Consistent 4-degree recoil.
TF2Weapon_SetPunchAngle(weapon, false, 0, false); // Restore stock recoil.
```

CWX and WeaponReverts derive `enabled` from whether `"punch angle mod"` exists, so
`"punch angle mod" "0"` is distinct from an item with no such custom attribute.

## Building

The default build target is 32-bit x86, matching TF2's SourceMod runtime. Pass an explicit
`--targets` value only when building for a different runtime architecture.
