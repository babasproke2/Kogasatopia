#!/usr/bin/env python3
"""Exercise the SourcePawn guard with mocked engine APIs; not an in-game test.

Requires g++. The tested function bodies are extracted from the real module.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tf/addons/sourcemod/scripting/weapons/ammo_pickups.sp"


def function(source, name):
    match = re.search(r"^(?:static bool|public MRESReturn) " + name + r"\(", source, re.M)
    assert match, name
    start = match.start()
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("public MRESReturn", "MRESReturn") + "\n"


source = SOURCE.read_text()
defines = "\n".join(line for line in source.splitlines() if line.startswith("#define "))
stubs = r'''
#include <cassert>
#include <cstring>
#include <cstdio>
enum { Prop_Send, MRES_Ignored, MRES_Supercede };
using MRESReturn = int;
const int MaxClients = 2;
bool enabled = true;
int inventory[4] = {3, 4, -1, -1};
int owners[8] = {0, 0, 0, 1, 1, 2, 0, 0};
int custom[8], nativeHook[8], ammo[8];
bool WeaponsGameplay_IsEnabled() { return enabled; }
bool Weapons_IsClientInGame(int c) { return c == 1; }
bool IsValidEntity(int w) { return w >= 3 && w <= 5; }
int GetEntPropArraySize(int, int, const char* p) {
    assert(!std::strcmp(p, "m_hMyWeapons")); return 4;
}
int GetEntPropEnt(int e, int, const char* p, int slot = 0) {
    if (!std::strcmp(p, "m_hMyWeapons")) return inventory[slot];
    assert(!std::strcmp(p, "m_hOwnerEntity")); return owners[e];
}
int TF2CustAttr_GetInt(int w, const char* p, int) {
    assert(!std::strcmp(p, "no secondary ammo from pickups")); return custom[w];
}
int TF2Attrib_HookValueInt(int seed, const char* p, int w) {
    assert(!std::strcmp(p, "no_secondary_ammo_from_pickups"));
    return seed | nativeHook[w];
}
struct DHookReturn { int &Value; };
struct DHookParam { int count, index, source;
    int Get(int n) { assert(n == 2 || n == 4); return n == 2 ? index : source; }
};
'''
tests = r'''
int give(int count, int index, int source) {
    int result = -999;
    if (AmmoPickups_GiveAmmo_Pre(1, {result}, {count, index, source}) == MRES_Supercede)
        return result;
    ammo[index] += count; return count;
}
int main() {
    custom[4] = 1; // Inventory weapon, no dependency on the active weapon.
    for (int amount : {1, 20, 50, 100}) {
        assert(give(amount, 2, 0) == 0 && ammo[2] == 0);
    }
    // Cabinets/respawn, dispenser/cart, and resource meters all pass through.
    for (int source = 1; source <= 3; source++) assert(give(10, 2, source) == 10);
    assert(ammo[2] == 30);
    for (int index : {1, 3, 4, 5, 6}) assert(give(10, index, 0) == 10);
    custom[4] = 0; assert(give(10, 2, 0) == 10);
    custom[4] = 1; owners[4] = 2; assert(give(10, 2, 0) == 10);
    owners[4] = 1; inventory[1] = -1; assert(give(10, 2, 0) == 10);
    inventory[3] = 4; assert(give(10, 2, 0) == 0); // Nonstandard inventory slot.
    enabled = false; assert(give(10, 2, 0) == 10); enabled = true;
    assert(!AmmoPickups_DenySecondary(0, 2, 0));
    custom[4] = 0; nativeHook[4] = 1; assert(give(10, 2, 0) == 0);
    puts("PASS: pickup sizes, holstered inventory, source isolation, other ammo pools, disabled/removed attributes, ownership, native hook, and return zero");
}
'''
with tempfile.TemporaryDirectory(prefix="ammo-pickups-test-") as build:
    binary = str(Path(build) / "test")
    code = "#include <initializer_list>\n" + defines + "\n" + stubs
    code += function(source, "AmmoPickups_DenySecondary")
    code += function(source, "AmmoPickups_GiveAmmo_Pre") + tests
    subprocess.run(["g++", "-std=c++17", "-x", "c++", "-o", binary, "-"],
                   input=code, text=True, check=True)
    subprocess.run([binary], check=True)
