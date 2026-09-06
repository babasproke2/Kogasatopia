# Secondary ammo pickup restriction

In a custom item definition:

```text
"attributes_custom"
{
    "no secondary ammo from pickups" "1"
}
```

This is a SourcePawn custom attribute, not a new Valve schema definition. The
module also queries the native `no_secondary_ammo_from_pickups` attribute class
if a server extension supplies such a schema attribute.

The pre-detour targets **four-argument** `CTFPlayer::GiveAmmo`. Only ammo index 2
(`TF_AMMO_SECONDARY`) with source 0 (`kAmmoSource_Pickup`) is denied, returning
zero before the original function runs. All owned weapons are checked, including
holstered weapons; the restriction applies to the player's shared ammo pool.
Primary ammo, metal, cabinets/respawn, Dispensers/carts, and resource-meter sources
are untouched. Any other plugin calling GiveAmmo with the pickup source is also
subject to this restriction. No cloak attributes or active-weapon checks are used.

Deploy `weapons.ammo_pickups.txt` gamedata with `weapons.smx`. Its Linux symbol
is verified against the server binary; Windows signatures are not supplied.

Run `python3 tools/test_secondary_ammo_pickups.py` for mocked-engine regression
checks, then compile `weapons.sp`. In-game acceptance still requires testing
small/medium/large ammo boxes, dropped ammo, a cabinet, respawn, a Dispenser,
and a payload cart with depleted secondary ammo, including while holstered.
