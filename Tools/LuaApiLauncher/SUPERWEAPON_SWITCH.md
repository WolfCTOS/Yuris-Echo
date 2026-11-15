# Superweapons: how the game decides that a superweapon works

Short reference for the launcher option "Super weapons" (All / Strategic /
Tactical / None). Everything below was verified against the files in this
installation, not from memory.

## 1. The game's own switch

The game keeps a single flag for the whole match:

```
GameModeOptionsClass::Instance.SWAllowed   // gamemd.exe, data address 0xA8B263
```

The spawner sets it from `spawn.ini`:

```
[Settings]
Superweapons=Yes|No
```

* `debug/yrpp-spawner/src/Spawner/Spawner.Config.cpp:39`
  `SuperWeapons = pINI->ReadBool(pSettingsSection, "Superweapons", SuperWeapons);`
* `debug/yrpp-spawner/src/Spawner/Spawner.cpp:214`
  `pGameModeOptions->SWAllowed = Spawner::Config->SuperWeapons;`

`ReadBool` accepts `Yes/No` (and `1/0`), so the launcher writes `Yes`/`No`.

## 2. What the flag does

A superweapon type carries one more flag:

```
SuperWeaponTypeClass::DisableableFromShell   // offset 0xE7 in the type struct
```

The game reads it in `SuperWeaponTypeClass::ParseINI` (gamemd.exe 0x6CEAC8,
string "DisableableFromShell" at 0x8426F4) and uses it like this
(gamemd.exe 0x50B088 and 0x50B2AE):

```
mov al, byte ptr [ecx + 0xE7]   ; DisableableFromShell
test al, al
je   allow
mov al, byte ptr [0xA8B263]     ; SWAllowed
test al, al
jne  allow
; -> the superweapon is not available
```

So: **a superweapon is unavailable when `DisableableFromShell` is set and
`SWAllowed` is off.** The same combination is checked when the AI picks what to
build (gamemd.exe 0x4F7A9A, 0x505288, 0x5055D8), so the AI does not build the
structures of the superweapons that are switched off.

Phobos states the same rule in `debug/phobos/src/Ext/House/Body.cpp:236`
(`HouseExt::IsDisabledFromShell`), with the note that the switch does not apply
to campaigns.

## 3. The map may override the flag (map code)

When the game loads a scenario it parses the map file as rules "map code", so
the map can override rule values:

```
RulesClass::Read_File(mapINI)        // gamemd.exe 0x668BF0
  -> RulesClass::Read_SpecialWeapons(mapINI)   // gamemd.exe 0x668FB0, called at 0x668F5E
```

`Read_SpecialWeapons` reads the superweapon type list and re-reads the section
of every type from the map INI, which is why a map can carry

```
[NukeSpecial]
DisableableFromShell=no
```

The launcher writes exactly this into the map copy it hands to the spawner
(`spawnmap.ini`), which is the same mechanism the CnCNet client uses for its
"Super weapons" drop down (`Resources\GameLobbyBase.ini`,
`[cmbSuperWeaponsModifier] DataWriteMode=MapCode`).

## 4. What the launcher writes

| Mode       | spawn.ini `Superweapons` | map code `DisableableFromShell`                          | Result in game |
|------------|--------------------------|---------------------------------------------------------|----------------|
| All        | Yes                      | `no` for every type                                       | every superweapon works |
| Strategic  | No                       | `no` for nuke / lightning storm / psychic dominator, `yes` for the rest | only the offensive ones work |
| Tactical   | No                       | `no` for chrono sphere / iron curtain / force shield / genetic converter, `yes` for the rest | only the defensive ones work |
| None       | No                       | `yes` for every type                                      | no superweapons at all |

Notes:

* The switch is off for every mode except "All", because `DisableableFromShell`
  is only consulted while `SWAllowed` is off.
* "None" also covers the types the rules leave switched on (para drop, spy
  plane, psychic reveal), otherwise they would keep working.
* The client's own `INI\Game Options\SuperWeapons\*.ini` files are not used
  any more: they only set the flag for a part of the types and they also block
  whole buildings (`TechLevel=-1` on the weapons factory, for example), which
  would stop the player from building tanks.
* `Resources\GameOptions.ini [ForcedSpawnIniOptions]` carries the client's
  global `Superweapons=False`. The launcher skips that key and writes its own
  value, otherwise the forced value would overwrite the player's choice.
* Campaigns ignore the switch (the game does not consult `SWAllowed` there),
  so the option only has an effect in skirmish.

## 5. Tools used for the analysis

* `debug/disasm_va.py` - disassemble a virtual address range of gamemd.exe.
* `debug/find_abs_refs.py` - find the code that references an absolute address
  (used for `0xA8B263`).
* `debug/find_str_refs.py` - find a string and the code that uses it (used for
  "DisableableFromShell").
