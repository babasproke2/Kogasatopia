# TF2 Sentry NewTarget Distance

SourceMod extension + SourcePawn plugin for overriding TF2 sentry target acquisition range through server ConVars.

## Operator ConVars

```text
sm_tf2_sentry_newtarget_enable "0"
sm_tf2_sentry_newtarget_dist   "200.0"
```

`sm_tf2_sentry_newtarget_enable` defaults to `0` as requested. `sm_tf2_sentry_newtarget_dist` is used for both normal sentries and mini-sentries; there is no mini-specific ConVar.

## Behavior

When enabled, the extension detours `CObjectSentrygun::FindTarget()` and writes `CObjectSentrygun::m_flSentryRange` immediately before stock target selection runs.

This matters because TF2 resets `m_flSentryRange` to `SENTRY_MAX_RANGE` inside `CObjectSentrygun::SentryThink()` every sentry think. A SourcePawn timer that writes the range after the think will usually be overwritten before the sentry actually searches or attacks.

With this version:

```text
sm_tf2_sentry_newtarget_enable 1
sm_tf2_sentry_newtarget_dist 500.0
```

makes both normal and mini-sentries acquire and keep targets only within roughly 500 Hammer Units, subject to the normal TF2 visibility, spy, disguise, water, wrangler, ammo, and state checks.

Setting the distance above vanilla range expands acquisition range. Setting it below vanilla range shrinks acquisition range.

## Files

```text
addons/sourcemod/scripting/tf2_sentry_newtarget_dist.sp
addons/sourcemod/scripting/include/tf2_sentry_newtarget_dist.inc
addons/sourcemod/gamedata/tf2_sentry_newtarget_dist.games.txt
extension/source/*.cpp, *.h
```

## Build/install summary

1. Build the C++ extension source in `extension/source` against your SourceMod extension SDK setup.
2. Install the built binary as `addons/sourcemod/extensions/tf2_sentry_newtarget_dist.ext.so` or the platform equivalent.
3. Install `addons/sourcemod/gamedata/tf2_sentry_newtarget_dist.games.txt`.
4. Compile `addons/sourcemod/scripting/tf2_sentry_newtarget_dist.sp` with `spcomp`.
5. Install the compiled `.smx` to `addons/sourcemod/plugins/`.
6. Configure `cfg/sourcemod/tf2_sentry_newtarget_dist.cfg` after the plugin generates it.

## Gamedata notes

The package includes a Linux symbol for `CObjectSentrygun::FindTarget()`. Windows needs a current byte signature for the live TF2 `server.dll`.

The extension resolves `m_flSentryRange` by first checking the optional gamedata offset `CObjectSentrygun::m_flSentryRange`. If no explicit offset is provided, it derives the offset from the networked `m_hEnemy` sendprop plus 8 bytes, matching the public TF2 class layout around `m_hEnemy`, `m_bFireNextFrame`, `m_bFireRocketNextFrame`, and `m_flSentryRange`.

## Version history

### 1.1.0

Changed the implementation from a SourcePawn retarget timer to a native pre-detour on `CObjectSentrygun::FindTarget()`. This fixes the issue where the sentry kept using vanilla range because `SentryThink()` reset `m_flSentryRange` before target selection.

### 1.0.0

Initial package.
