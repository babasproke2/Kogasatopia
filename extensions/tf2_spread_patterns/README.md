# TF2 Spread Patterns

Provides per-weapon fixed bullet spread patterns without replacing TF2's bullet firing logic.

## API

TF2Spread_SetPattern(weapon, pattern) assigns TF2Spread_Default or TF2Spread_Circular15 to a weapon entity.

Overrides are stored with entity references, so recycled entity indexes do not inherit a pattern.

The circular pattern uses TF2's native 15-pellet fixed-spread path and retains its small random jitter.
