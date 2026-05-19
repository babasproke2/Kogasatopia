# Scout Coyote Jump

SourceMod extension for stock Linux TF2 servers that gives Scout a small coyote-time ground jump window.

## What It Fixes

If Scout walks off a very thin ledge and presses jump immediately after the server has already cleared ground state, vanilla TF2 spends the air dash. That means the player only gets one jump impulse instead of a ground jump plus an air dash.

This extension detours TF2 movement. When a Scout presses a fresh jump within `0.12` seconds after leaving ground, before using any air dash, it temporarily restores the last valid ground entity and lets TF2's own `CTFGameMovement::CheckJumpButton()` perform the normal ground jump. The air dash remains available afterward.

## Install

Copy these files into the server's `tf` folder:

```text
tf/addons/sourcemod/extensions/scout_coyote_jump.ext.2.tf2.so
tf/addons/sourcemod/gamedata/scout_coyote_jump.games.txt
```

Load it with:

```text
sm exts load scout_coyote_jump.ext.2.tf2.so
```

No SourcePawn plugin is required for the fix.

## Optional SourcePawn Include

The include is only for plugins that want to require the extension or read a debug counter:

```sourcepawn
#include <scout_coyote_jump>

int count = TF2ScoutCoyote_GetCoyoteCount(client);
```

## Notes

- The fix only applies to Scout.
- It only applies before Scout has spent an air dash.
- It only applies once per airtime, then resets on real ground contact.
- The coyote window is intentionally small: `0.12` seconds.
