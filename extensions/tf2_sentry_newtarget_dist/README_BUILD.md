# Building the extension

This directory contains SourceMod extension source only; it is not a precompiled binary.

You need a normal SourceMod extension build environment with:

- SourceMod public headers and extension SDK wrappers
- Metamod:Source headers
- HL2SDK for TF2
- SourceMod's `CDetour` support available to the extension build

The extension uses:

```cpp
CDetourManager::Init(g_pSM->GetScriptingEngine(), g_pGameConf);
DETOUR_CREATE_MEMBER(CObjectSentrygun_FindTarget, "CObjectSentrygun::FindTarget");
```

Install the compiled binary as one of:

```text
addons/sourcemod/extensions/tf2_sentry_newtarget_dist.ext.so
addons/sourcemod/extensions/tf2_sentry_newtarget_dist.ext.dll
```

The included gamedata has a Linux symbol for `CObjectSentrygun::FindTarget()`. Windows requires a current byte signature for TF2's live `server.dll`.
