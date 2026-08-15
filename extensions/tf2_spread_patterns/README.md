# TF2 Spread Patterns

Provides per-weapon bullet spread controls without replacing TF2's bullet firing logic.

## API

`TF2Spread_SetPattern(weapon, pattern)` assigns `TF2Spread_Default` or `TF2Spread_Circular15` to a weapon entity.

Overrides are stored with entity references, so recycled entity indexes do not inherit a pattern.

The circular pattern uses TF2's native 15-pellet fixed-spread path and retains its small random jitter.

`TF2Spread_SetAmbassadorAccuracy(weapon, enabled)` adds Ambassador-style spread recovery. It retains
the weapon's original spread for 0.5 seconds, recovers linearly, and reaches exact first-shot accuracy
after 1.0 second.

`TF2Spread_IsAmbassadorAccuracyRecovered(weapon)` returns true when an enabled weapon has not fired
for at least 1.0 second.
