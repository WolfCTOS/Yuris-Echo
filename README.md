# Yuri's Echo

Gameplay mod for **Command & Conquer: Red Alert 2 — Yuri's Revenge**.
Built on Ares, Phobos and LuaAPI.

**Latest change: Added veterancy bar and XP popups.**

## Contents

- `Ares.dll`, `Phobos.dll`, `LuaAPI.dll`, `Syringe.exe`, `LMM.exe`
- `rulesmd.ini`, `artmd.ini` — Yuri's Echo rules and art
- `mods\` — Yuri's Echo, Smart AI, AI Telemetry, AI Ignore, Humvee,
  LTNK EMP nerf
- `scripts\` — LuaAPI framework

## Install

1. Copy everything in this repository into the Yuri's Revenge 1.001 game
   folder (next to `gamemd.exe`).
2. Run `LMM.exe`.
3. Press **Launch Game**. LMM starts `gamemd.exe` through `Syringe.exe`
   with `Ares.dll` and `Phobos.dll`, then injects `LuaAPI.dll`.

## Veterancy bar

The LuaAPI build in this repository draws a two-stage veterancy bar below
selected units:

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

