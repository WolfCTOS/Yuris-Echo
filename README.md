# Yuri's Echo

Gameplay mod for **Command & Conquer: Red Alert 2 — Yuri's Revenge**.
Built on Ares, Phobos and LuaAPI.

**Latest change: the skirmish setup reads its country list from
`rulesmd.ini`, the playable countries of the mod are back in the lobby, and
the rules checker knows the lobby (see below).**

## Contents

- `Ares.dll`, `Phobos.dll`, `LuaAPI.dll`, `Syringe.exe` — the engine stack
- `Yuri's Echo.exe`, `YurisEcho.dll` — the launcher (source in `Tools\`)
- `rulesmd.ini`, `artmd.ini` — Yuri's Echo rules and art
- `mods\` - Yuri's Echo, Smart AI, AI Telemetry, AI Ignore, Humvee,
  LTNK EMP nerf
- `scripts\` - LuaAPI framework
- `Tools\rules_check.ps1` - consistency check for `rulesmd.ini`

## Install

1. Copy everything in this repository into the Yuri's Revenge 1.001 game
   folder (next to `gamemd.exe`).
2. Run `Yuri's Echo.exe`.
3. Press **Launch Game**. The launcher starts `gamemd.exe` through
   `Syringe.exe` with `Ares.dll` and `Phobos.dll`, then injects
   `LuaAPI.dll` and applies `mods\active_mods.txt`.

`LMM.exe` is not required: the launcher applies `active_mods.txt` and starts
the game with LuaAPI on its own.

## Faction doctrines and rules repairs

The western roster is split into two coalitions with different play styles.
The split uses the mechanism that was already in the base rules file:
`RequiredHouses` decides which house sees the unit in the build sidebar,
`Owner` decides which house may build it. Every country keeps one signature
unit; the shared western kit (E1, guards, engineers, standard structures)
stays available to both coalitions.

| Coalition | Houses | Profile | Signature units |
|---|---|---|---|
| **Alliance** | `Americans` + `Alliance` (USA + Korea) | technological and mobile: precision fire, heavy units have **no anti-air** | AM1, AM2 (laser + 120 mm), Black Eagle, Chinook, special forces (Guardian GI, Rocketeer, Navy SEAL, Spy, Chrono Commando, Chrono Legionnaire, Tanya, Chrono Miner) |
| **EU** | `British` (= European Union) + `French` + `Germans` | technological and defensive: long-range fire and taking over enemy vehicles | Sniper, Grand Cannon, Tank Destroyer, Prism, Grizzly, Mirage, Battle Fortress, destroyer, cruiser, dolphin |

Fleet: destroyer, cruiser and dolphin belong to the EU, the aircraft carrier
to the Alliance. The EU sniper kills the driver of light vehicles (125
damage, hitscan, `HollowPoint`: 200% against flesh, 1% against armour) and can
now enter the machine itself (`Occupier=yes`); the tank destroyer uses the
sabot round `SABOT` (`UltraAP`) to strip the crew out of a tank, so infantry
can take it over.

### Playable factions

The skirmish setup offers the factions of `rulesmd.ini`: the launcher reads
the `[Factions]` section and shows one entry per faction, in the order of the
section. The value of an entry lists the houses of the faction - the first one
is the country the player gets, the rest are the other houses of the same
coalition (Korea in the Alliance, France and Germany in the EU, Cuba in the
Havana Pact). The spawner identifies a house by its index in the rules'
`[Countries]` table, so the list follows the rules instead of a hardcoded
client list - edit the rules and the launcher follows.

| Faction | Houses | Coalition |
|---|---|---|
| Альянс / Alliance | `Americans` + `Alliance` | USA + Korea |
| Евросоюз / European Union | `British` + `French` + `Germans` | Europe |
| Хаванский пакт / Havana Pact | `Africans` + `Confederation` | Libya + Cuba |
| Россия / Russia | `Russians` | Soviet Union |
| Юрий / Yuri | `YuriCountry` | outside the coalitions |

The names of the factions come from the rules as well; the launcher
translates them for the English UI (`Localization.cs`).

### Repairs in this batch

- The European Union, Korea, France, Germany and Libya are playable again
  (`Multiplay=yes`). Until now their houses were not in the lobby, and their
  units keep their `RequiredHouses` - so the sniper, Grizzly, tank destroyer,
  Prism, Mirage, Battle Fortress, destroyer, cruiser, dolphin and the Grand
  Cannon could not be built by anybody at all.
- `[LUNR]` (the Soviet sniper) had `Prerequisite=NAPILE`, a section that does
  not exist in the file, so the unit could not be built. It is `NAHAND,RADAR`
  now.
- The Robot Tank belongs to Korea as well: `Alliance` was added to its `Owner`
  and `RequiredHouses`.
- `[InfantryTypes] 25=TANY` pointed at a section that had been renamed to
  `[TANYA]`, so the Tanya infantry loaded with no data at all (game log:
  `TANYA not found`, `TANY Occupier=0`). The section is `[TANY]` again and
  the index entry matches it.
- Eighteen warheads existed as sections but were never listed in
  `[Warheads]`, so the weapons that use them fired without a warhead: Black
  Eagle missiles, carrier Hornets, destroyer ASW torpedoes, Tesla bolts,
  Rhino and Lasher elite guns and others. They are registered now
  (`108`..`125`), and the missing `[CComandoATWH]` and `[Meteorite]`
  sections were added.
- `[CCOMAND]` had `Prerequisite=BARRACKS`. That is a retail generic group
  (like `POWER`, `FACTORY`, `RADAR`, `TECH` and `PROC`), so the unit was
  buildable from the barracks; it is `GAPILE,GATECH` now (Battle Lab) and
  belongs to the Alliance.
- `[AM1]` and `[AM2]` listed `Americans` in `Owner` and in `ForbiddenHouses`
  at the same time, so the Alliance could not build them. `ForbiddenHouses`
  was dropped, `RequiredHouses=Americans,Alliance` was added, and AM2 was
  rebalanced from 800 to 640 strength (about 80% of the Apocalypse).
- Tanya's mine used `IvanBomb.*` keys in the weapon, which the engine never
  reads. The Ares Ivan-bomb keys (`Ivan.Delay=60`, `Ivan.Damage=300`,
  `Ivan.Detachable=yes`) are on the warhead where they belong, and the 200%
  light-armour spike is gone.
- `[CLEG]` no longer has psionic immunity, as the spec requires.
- Tanya and the Robot Tank got `DetectDisguise=yes`: they are supposed to
  see a disguised Spy, like the dogs and the Navy SEAL.
- The Alliance AM2 follows its doctrine now: the laser is anti-infantry
  (`SA`), the 120 mm shell is `ApocAP` (100% against concrete, steel and
  heavy armour), and the beam uses the new `[AM2BeamP]` projectile with
  `AA=no`, so like the Apocalypse the AM2 never shoots at aircraft.
- `Sidebar.MixFileIndex=3` is back on the Yuri side; it was lost when
  `[ThirdSide]` was renamed to `[YuriCountry]`.

### Checking the rules file

`Tools\rules_check.ps1` verifies exactly what breaks when a rules file is
edited by hand: every index list entry resolves to a section, every weapon
warhead is registered, every unit is reachable by a lobby country,
`RequiredHouses` is a subset of `Owner`, every prerequisite names a building
or a retail group, and the file stays UTF-8/CRLF.

The lobby is the rules' own country table - the countries of `[Countries]`
whose house section says `Multiplay=yes` - so the check fails when a unit's
`RequiredHouses` keep it away from every country a player can pick. That is
exactly how the European Union roster became unbuildable.

```powershell
.\Tools\rules_check.ps1
```

## Veterancy bar

The LuaAPI build in this repository draws a two-stage veterancy bar below
selected units. The empty dark track is visible even at 0 XP, so the scale
does not disappear before the first kill:

- first full bar → the unit becomes **veteran**;
- second full bar → the unit becomes **elite**.

Harvesters, engineers, transport planes, buildings and the listed tech
structures are excluded. Toggle with `Engine.SetVeterancyBar(true/false)`.

## XP popups

When an own unit gains experience, a gold `+N XP` label appears above it.

The number uses the same scale as the bar: **100 XP = one full rank**.
`VeteranRatio=3.0` in `rulesmd.ini`, so a unit must destroy three times its
own cost to become veteran, then another three times to become elite. For
example, a 200-cost unit killing another 200-cost unit gets about `+33 XP`;
three such kills promote it to veteran.

Toggle with `Engine.SetVeterancyXpPopups(true/false)`.

