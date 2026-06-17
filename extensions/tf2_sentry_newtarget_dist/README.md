# TF2 Sentry New Target Distance

SourceMod extension helper + SourcePawn plugin for restoring a fixed Hammer-Unit sentry target-switch threshold.

## Operator ConVars

```text
sm_tf2_sentry_newtarget_enable "0"
sm_tf2_sentry_newtarget_dist   "200.0"
```

`sm_tf2_sentry_newtarget_enable` defaults to `0` as requested. `sm_tf2_sentry_newtarget_dist` is used for both normal and mini-sentries; there is no mini-specific ConVar.

## Behavior

When enabled, the plugin tracks each sentry's last accepted target. If a closer valid target appears, the sentry switches only when the new target is at least `sm_tf2_sentry_newtarget_dist` Hammer Units closer than the last accepted target. A value of `0.0` means always prefer the closest valid target.

The extension exposes `TF2SentryNewTarget_FoundTarget()` so the plugin can call the real `CObjectSentrygun::FoundTarget()` path instead of writing `m_viewtarget` or only setting `m_hEnemy`.

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
3. Install the gamedata file to `addons/sourcemod/gamedata/`.
4. Compile `addons/sourcemod/scripting/tf2_sentry_newtarget_dist.sp` with `spcomp`.
5. Install the compiled `.smx` to `addons/sourcemod/plugins/`.
6. Configure `cfg/sourcemod/tf2_sentry_newtarget_dist.cfg` after the plugin generates it.

## Platform note

The packaged gamedata includes a Linux symbol for `CObjectSentrygun::FoundTarget`. Windows needs a current byte signature for the live TF2 `server.dll`.
