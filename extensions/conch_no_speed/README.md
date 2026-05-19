# Conch No Speed

SourceMod extension for Team Fortress 2 that exposes a Concheror-style regen-on-damage buff without the vanilla speed boost.

## Files

- `addons/sourcemod/extensions/conch_no_speed.ext.2.tf2.so`
- `addons/sourcemod/gamedata/conch_no_speed.games.txt`
- `addons/sourcemod/scripting/include/conch_no_speed.inc`

## SourcePawn

```sourcepawn
#include <conch_no_speed>

public void SomeFunction(int client)
{
	TF2ConchNoSpeed_AddRegenBuff(client, 10.0, client);
}
```

`provider` is optional. Pass the Soldier or buff owner if you want Concheror healing assist credit to behave like the vanilla condition provider.

## Natives

```sourcepawn
native void TF2ConchNoSpeed_AddRegenBuff(int client, float duration, int provider = 0);
native void TF2ConchNoSpeed_RemoveRegenBuff(int client);
native bool TF2ConchNoSpeed_IsRegenBuffActive(int client);
```

The extension applies `TF_COND_REGENONDAMAGEBUFF` and suppresses only the nested `TF_COND_SPEED_BOOST` that TF2 adds/removes as part of the vanilla Concheror condition.
