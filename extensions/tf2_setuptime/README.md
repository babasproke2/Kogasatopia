# TF2 SetupTime SourceMod Extension

This SourceMod C++ extension exposes one SourcePawn native:

```sourcepawn
native bool TF2_IsSetupTimeActive();
```

It returns `true` while TF2 setup time is active by reading the TF2 game-rules sendprop `CTFGameRulesProxy::m_bInSetup`.

## Files

- `src/extension.cpp` - extension implementation.
- `src/extension.h` - extension header.
- `src/smsdk_config.h` - SourceMod extension metadata and interface config.
- `scripting/include/tf2_setuptime.inc` - SourcePawn include for plugin authors.
- `scripting/examples/test_tf2_setuptime.sp` - simple test command: `sm_setupactive`.

## Build notes

This package contains source code, not a compiled binary. SourceMod extensions must be compiled against your local SourceMod, Metamod:Source, and HL2SDK-TF2 setup.

The simplest path is to copy SourceMod's `public/sample_ext` project, replace its `extension.cpp`, `extension.h`, and `smsdk_config.h` with the files in `src/`, rename the output to `tf2_setuptime`, and build the sample extension for the TF2 SDK.

Typical Linux layout:

```bash
git clone https://github.com/alliedmodders/sourcemod.git
git clone https://github.com/alliedmodders/metamod-source.git
git clone https://github.com/alliedmodders/hl2sdk.git -b tf2 hl2sdk-tf2

cp -r sourcemod/public/sample_ext tf2_setuptime
cp src/extension.cpp src/extension.h src/smsdk_config.h tf2_setuptime/

cd tf2_setuptime
mkdir build && cd build
python3 ../configure.py --sdks=tf2
ambuild
```

Depending on your local SDK paths, you may need to export the same environment variables expected by the sample extension build files.

## Install

Copy the compiled extension binary to:

```text
tf/addons/sourcemod/extensions/
```

Copy the include file to:

```text
tf/addons/sourcemod/scripting/include/tf2_setuptime.inc
```

Then plugins can do:

```sourcepawn
#include <tf2_setuptime>

if (TF2_IsSetupTimeActive())
{
    // setup time is active
}
```

For a quick runtime test, compile `scripting/examples/test_tf2_setuptime.sp`, place the `.smx` in `addons/sourcemod/plugins/`, and run `sm_setupactive`.
