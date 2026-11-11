local util = require("framework.util")
local ForceGroup = require("framework.force_group")
local Tactical = require("framework.tactical")

-- Externalized tuning/config (P0/P2): presets, flags, tunables, extensible type lists.
-- Falls back to built-in defaults if config is unavailable.
local CFG
do
    local ok, c = pcall(require, "smartai_config")
    if not ok then ok, c = pcall(require, "mods.Smart AI.smartai_config") end
    if not ok then ok, c = pcall(require, "mods.Smart_AI.smartai_config") end
    if ok and type(c) == "table" then CFG = c end
end

local SmartAI = {}

-- CORE PRINCIPLE (M2, 2026-09-25 — read before extending this mod):
-- SmartAI does not create the battlefield situation it reacts to.
-- It exploits the battlefield situation created by the existing game AI.
--
-- Consequences for every future check:
--   * No production/spawns (AI.QueueUnit is BLOCKED live; zero SpawnUnit
--     in this file — verified by grep). We command existing units only.
--   * No order lease (vanilla re-selects eventually). We issue transition-
--     only orders + cooldowns and measure persistence via readback, never
--     assume it. Fighting units are NEVER yanked.
--   * Vanilla owns the mass (attack waves, demo-truck teams, base building).
--     SmartAI owns the point decisions on top: which economy to snipe,
--     when to retreat, whom to escort, when to stand down the base.
--   * A layer that needs vanilla to leave units idle will starve live
--     (proven 2026-09-25: idle pool=0 all match) — always add the
--     marching-not-fighting second choice.
--   * Surrender is a conjunction (no Barracks AND no WF AND no MCV/CY),
--     never a single-building trigger; anchor tables err toward DELAYING.


-- Difficulty: "auto" | "easy" | "medium" | "hard" (default "auto").
-- "auto" (2026-09-25, per-house): each AI house gets the preset matching
-- its lobby AI difficulty via house:GetAIDifficulty() (LuaAPI Beta M1,
-- normalized "easy"|"normal"|"hard"; engine stores it reversed). "normal"
-- maps to the medium preset. Old DLL (binding absent -> nil) or any
-- unexpected value falls back to SmartAI.DIFFICULTY_FALLBACK for that
-- house. A fixed value ("easy"/"medium"/"hard") still applies to every
-- AI house and remains the test override.
-- Design note (unchanged): presets scale OBSERVATION and TEMPO only —
-- scan cadence, radii, defender counts, cooldowns. No preset grants
-- production, credits, spawn or any economy cheat: the intelligence split
-- is behavioral (easy = rally only; medium = full behavior; hard = same
-- brain, faster reactions), never economic.
SmartAI.DIFFICULTY = (CFG and CFG.DIFFICULTY) or "auto"
SmartAI.DIFFICULTY_FALLBACK = (CFG and CFG.DIFFICULTY_FALLBACK) or "medium"

-- Engine defeat transition on surrender: OFF (2026-09-26).
--
-- When true, a house that satisfies the surrender DoD is additionally passed
-- to Engine.__SmartAILose -> HouseClass::Lose(false), which forces the
-- engine's internal defeat transition. Measured consequence in a 1-human +
-- 3-AI match: the engine leaves the game main loop ~90 frames later, at
-- BorrowedTime expiry, and the whole match ends and the process exits
-- (code 0) with every other house still alive and undefeated. Reproduced
-- 3/3. Control-flow counters prove Lose() returns and the detour is merely
-- never entered again.
--
-- False keeps surrender as a DECISION only: the latch, order silence, base
-- liquidation and the HUD notice. Defeat itself stays the engine's job, which
-- is what this mod's architecture says it should be. Flip to true only to
-- reproduce the old behaviour for diagnosis.
SmartAI.SURRENDER_ENGINE_CALL = (CFG and CFG.SURRENDER_ENGINE_CALL) or false

-- Preset key used when a house's difficulty is unknown (old DLL, read
-- failure, unexpected string). Defined before difficultyKey (upvalue).
local PRESET_FALLBACK_KEY = SmartAI.DIFFICULTY_FALLBACK

-- Map a house's engine difficulty string to a preset key. Unknown/nil ->
-- the fallback key. Pure function; harness-covered.
local function difficultyKey(level)
    if level == "easy" then return "easy" end
    if level == "normal" then return "medium" end
    if level == "hard" then return "hard" end
    return PRESET_FALLBACK_KEY
end

local PRESETS = (CFG and CFG.PRESETS) or {
    easy = {
        scan = 60,
        rallyEvery = 300,
        guard = false, escort = false, garrison = false,
        recall = false, defense = false, raid = false,
        hero = true, heroLeash = 8, heroEvery = 900, heroRetreat = false,
    },
    medium = {
        scan = 30,
        rallyEvery = 150,
        guard = true, escort = true, garrison = true,
        recall = true, defense = true, raid = true, radevac = true,
        buildlaw = true, miner = true, hero = true,
        heroLeash = 25, heroEvery = 600, heroRetreat = false,
        intruderR = 18, assignR = 35, defendersN = 2, defenseEvery = 150,
        confirmN = 2, clearN = 4, marchRecall = true, redirectEvery = 300,
        raidN = 4, raidMin = 3, raidQuiet = 600, raidEvery = 600,
        raidRange = 60, raidRetreatMult = 2,
    },
    hard = {
        scan = 15,
        rallyEvery = 90,
        guard = true, escort = true, garrison = true,
        recall = true, defense = true, raid = true, radevac = true,
        buildlaw = true, miner = true, hero = true,
        heroLeash = 25, heroEvery = 300, heroRetreat = true,
        intruderR = 24, assignR = 45, defendersN = 3, defenseEvery = 90,
        confirmN = 1, clearN = 6, marchRecall = true, redirectEvery = 180,
        raidN = 5, raidMin = 3, raidQuiet = 450, raidEvery = 450,
        raidRange = 80, raidRetreatMult = 2,
    },
}

-- Per-house preset cache ("auto" difficulty): house userdata -> preset
-- table. MUST stay above paramsFor: Lua binds upvalues lexically, and a
-- declaration below it would silently become a global (the same live bug
-- class the officerReset NOTE below documents). Cleared by officerReset.
local houseParamsCache = {}
-- Houses seen at the last scan (userdata keys). Lets the per-frame scan
-- gate compute the FASTEST house cadence without re-enumerating houses
-- every frame. Rebuilt each scan; cleared by officerReset on restart.
local aiHousesCache = {}

-- Global preset: fixed difficulty modes, harness override, and the
-- fallback used when per-house data is unavailable.
local function params()
    local key = SmartAI.DIFFICULTY
    if key == "auto" then key = SmartAI.DIFFICULTY_FALLBACK end
    return PRESETS[key] or PRESETS.medium
end

-- Per-house preset (Beta M1, "auto"): resolves the house's engine
-- difficulty to a preset table. Read via a pcall'd house:GetAIDifficulty()
-- when available (binding present on the current DLL); nil result, absent
-- binding, or read error all fall back to the global params(). Results are
-- cached per house for the whole match (the lobby value never changes
-- mid-match; userdata identity makes the table safe), so a hostile state
-- cannot appear per scan. Cleared by officerReset on match restart.
local function paramsFor(house)
    if SmartAI.DIFFICULTY ~= "auto" then return params() end
    if not house then return params() end
    local cached = houseParamsCache[house]
    if cached then return cached end
    local key = SmartAI.DIFFICULTY_FALLBACK
    if type(house.GetAIDifficulty) == "function" then
        local ok, level = pcall(house.GetAIDifficulty, house)
        if ok and (level == "easy" or level == "normal" or level == "hard") then
            key = difficultyKey(level)
        end
    end
    local preset = PRESETS[key] or PRESETS.medium
    houseParamsCache[house] = preset
    return preset
end

-- Per-frame scan-gate cadence: in "auto", the tick runs at the FASTEST
-- AI house's scan (a hard AI must actually see the battlefield at 15f,
-- not at the fallback's 30f); houses are the cache from the previous
-- scan (empty on the very first tick -> fallback). Fixed modes keep the
-- global preset's scan. Mixed-lobby note: slower houses therefore get
-- their layers evaluated at the faster tick too — order RATES stay
-- per-house (every layer is cooldown-gated by its own preset); what
-- moves at the tick cadence is detection granularity (confirmN counts
-- scans), which is acceptable and documented.
local function tickScanEvery()
    local base = params()
    if SmartAI.DIFFICULTY ~= "auto" then return base.scan end
    local best = base.scan
    for h in pairs(aiHousesCache) do
        local hp = paramsFor(h)
        if hp and hp.scan and hp.scan < best then best = hp.scan end
    end
    return best
end

local lastScanFrame = 0
-- Processed-scan counter this match (BUILDLAW birth rule: scan 1 is
-- load-time / pre-placed inventory). Declared here: officerReset and
-- Update both assign it, and Lua binds upvalues lexically.
local scanCounter = 0

-- ---------------------------------------------------------------------------
-- Capture-aware valuables guard (MVP): high-value own units avoid lone
-- exposure to observable vanilla mind-control threats. Vanilla capture
-- itself is untouched and unimplemented here: this only reads owner /
-- type / position via LuaAPI and issues standard MoveTo orders.
--
-- Vanilla ground truth being reasoned about (not implemented): Yuri
-- mind-control units flip a victim's owner (Yuri clone, Yuri Prime,
-- Mastermind; Hijacker ID unconfirmed and Chaos Drone causes frenzy,
-- not capture, so both are excluded). A flip is observable afterwards
-- as a GetOwner() change on a tracked id.
--
-- VALUABLE_TYPES lists high-value TypeIDs to protect. Extend with real
-- TypeIDs as needed (e.g. a custom Nuclear Truck goes here under the ID
-- of the mod that defines it; no such unit exists in this repo — verified
-- by repo-wide search). THREAT_TYPES lists observable capturer TypeIDs:
-- MIND was observed live; YURIPR/YURI are rules/wiki IDs for Yuri Prime
-- and the Yuri clone (both mind-control infantry).
-- ---------------------------------------------------------------------------

local VALUABLE_TYPES = (CFG and CFG.VALUABLE_TYPES) or {
    APOC = true,               -- Apocalypse: expensive, slow, high-value
    HTNK = true,               -- Rhino: main-line armor, capture-observed live
                               -- (HTNK#1058871 Africans -> YuriCountry,
                               -- Dannath session) - lone Rhinos are exactly
                               -- what mind-control punishes
}

local CAPTURE_THREATS = (CFG and CFG.CAPTURE_THREATS) or {
    MIND = true,               -- Mastermind: controls vehicles (live-observed)
    YURIPR = true,             -- Yuri Prime: mind control (rules/wiki ID)
    YURI = true,               -- Yuri clone: mind control (rules/wiki ID)
}

local THREAT_RADIUS = 9        -- mind-control engagement envelope class
local HOLD_RADIUS = 4          -- with-group distance: no lone exposure
local REORDER_EVERY = 600      -- refresh pullback at most every ~10 s

local guardState = {}          -- unitId -> { threatened = bool, orderedFrame = n }
local seenOwner = {}           -- unitId -> ownerName (flip observation only)
local guardLastFrame = 0

local function guardReset()
    guardState = {}
    seenOwner = {}
end

-- ---------------------------------------------------------------------------
-- Commander + Officers: AI-house coordination layer (classic split restored:
-- Commander manages the BASE, Officer manages UNITS).
-- One shared scan feeds everything below — no extra World scans. Officers
-- assign ROLES (escort / garrison-screen), never tactics: vanilla AI keeps
-- attacking, officers only attach support.
-- Deterministic (ID-ordered picks, no RNG/clock) and churn-free
-- (transition-only orders + destination memory + refresh caps).
--
-- Escort officer: own ARTILLERY_TYPES (V3, INI-confirmed [V3]) get up to
-- ESCORT_N bodyguards that follow at destination memory. Guards are
-- retained while fighting (not dropped the moment they engage), idle
-- fills first and marching-not-fighting backfills (idle pool is 0
-- live), free guards intercept threats near the V3 with focus fire,
-- and a pressured V3 kites toward its own base. Engaged bodyguards
-- are released, never yanked.
-- Garrison officer (EXPERIMENTAL): idle own infantry near own DEFENSE_TYPES
-- are ordered onto the building cell (vanilla enter-if-garrisonable, screen
-- otherwise). BUNKER id is UNCONFIRMED live (no BUNK* section in the repo's
-- INI subset); the directive log prints the acted type name so a live
-- census confirms it. NAPILL/GAPILL are INI-confirmed but screen-only
-- (not garrisonable).
-- ---------------------------------------------------------------------------

local ARTILLERY_TYPES = (CFG and CFG.ARTILLERY_TYPES) or { V3 = true }
-- Heroes (sprint 2026-10-03, all presets): Tanya eats infantry +
-- buildings (C4), Boris works vehicles/infantry (AKM; his airstrike has
-- no binding — plain Attack only), Yuri Prime mind-controls via Attack
-- (units/infantry only, never buildings). INI IDs: TANYA/BORIS/YURIPR.
local HERO_TYPES = (CFG and CFG.HERO_TYPES) or { TANYA = true, BORIS = true, YURIPR = true }
local HERO_FOCUS_GAP = 1.0 -- hard: no flip-flop below this value gain
local HERO_RETREAT_HP = 0.30 -- hard: below this fraction, back to anchor
-- T3 armor (Battle-Lab-gated, INI-verified IDs: APOC/BFRT/SREF/MGTK).
-- V3 stays its own category (escort principal, never a hunter).
local T3_TYPES = (CFG and CFG.T3_TYPES) or { APOC = true, BFRT = true, SREF = true, MGTK = true }
-- VALOR (sprint 2026-10-03): veterans/elites are force multipliers —
-- killing the enemy's first is worth more than the chassis, and
-- spending our own as bait is never allowed. Shared bonus so retarget
-- and HERO scoring agree on what a crack target is worth.
local VALOR_VET = 1.0
local VALOR_ELITE = 2.0
local VALOR_HERO = 1.5
local VALOR_T3 = 1.0
-- A veteran 0.1 from elite denies almost like an elite: progress tops up
-- the veteran bonus linearly (0.9-vet ≈ +1.9). Rookies get no top-up —
-- denying the elite transition outranks denying the veteran one.
-- VALOR_KEEP: own units at/above this progress are investment worth
-- protecting (feint/wave), even while still rookie.
local VALOR_KEEP = 0.5
local function valorBonus(u)
    if u.k ~= "unit" and u.k ~= "infantry" then return 0 end
    local b = 0
    if u.vet == "elite" then b = b + VALOR_ELITE
    elseif u.vet == "veteran" then
        b = b + VALOR_VET + (u.vetProgress or 0)
    end
    if HERO_TYPES[u.t] then b = b + VALOR_HERO end
    if T3_TYPES[u.t] then b = b + VALOR_T3 end
    return b
end
-- Own precious: veterans/elites, half-invested near-promotions, T3.
-- Feint and wave-shepherd consult this, never role code twice.
local function isPrecious(u)
    return u.vet ~= "rookie" or (u.vetProgress or 0) >= VALOR_KEEP
        or T3_TYPES[u.t] == true
end
local DEFENSE_TYPES = (CFG and CFG.DEFENSE_TYPES) or { BUNKER = true, NAPILL = true, GAPILL = true }
local HARVESTER_TYPES = (CFG and CFG.HARVESTER_TYPES) or { SMIN = true, HARV = true, CMIN = true }
local MCV_TYPES = (CFG and CFG.MCV_TYPES) or { AMCV = true, SMCV = true, YMCV = true }

-- Production anchors for strategic-defeat detection (Phase 1).
-- Source tags: [LIVE] = seen in live [SMARTAI][BASE] lines; others are
-- pre-existing/ModEnc knowledge marked [UNVERIFIED]. Fail-safe direction:
-- an extra entry can only DELAY surrender (never cause a false one), while
-- a missing entry could cause one — so uncertain IDs stay IN until live
-- BASE lines confirm or deny them. TODO: confirm unverified IDs live.
local ANCHOR_BARRACKS = (CFG and CFG.ANCHOR_BARRACKS) or {
    NAHAND = true, -- [LIVE] Soviet Barracks
    NABRCK = true, -- [UNVERIFIED]
    GAPILE = true, -- [UNVERIFIED] Allied Barracks
    YABRCK = true, -- [UNVERIFIED] Yuri Barracks
}
local ANCHOR_WF = (CFG and CFG.ANCHOR_WF) or {
    NAWEAP = true, -- [LIVE] Soviet War Factory
    GAWEAP = true, -- [LIVE] Allied War Factory
    YAWEAP = true, -- [UNVERIFIED] Yuri War Factory
    YWEAP = true,  -- [UNVERIFIED] alt Yuri War Factory id
}
local ANCHOR_MCV = (CFG and CFG.ANCHOR_MCV) or {
    AMCV = true, SMCV = true, YMCV = true, -- pre-existing MCV trio
    NACNST = true, -- [LIVE] Soviet Construction Yard (deployed MCV)
    GACNST = true, -- [LIVE] Allied Construction Yard
    YACNST = true, -- [UNVERIFIED] Yuri Construction Yard
}

-- Surrender futility (user ruling 2026-09-25): with anchors gone the
-- house cannot recover; it surrenders only when its remaining combat
-- value is below this ratio of the strongest enemy's (futility).
-- Tunable; harness uses clear-cut ratios, live feel decides the number.
local SURRENDER_FUTILITY_RATIO = (CFG and CFG.SURRENDER_FUTILITY_RATIO) or 0.25

local surrendered = {} -- house -> latch frame (Phase 1: order silence)

local ESCORT_N = 3
local ESCORT_RADIUS = 6
local ESCORT_EVERY = 300
local ESCORT_DRAFT_RADIUS = 25 -- bodyguards draft near their V3 only: a guard
                               -- trekking 100 cells across the map is not an
                               -- escort, and far V3s must not eat home
                               -- defenders / recall candidates (live T15 bug)

-- Bodyguard combat (vs tank rushes on the V3): guards engage hostiles
-- closing on their principal instead of standing next to it, and a
-- pressured V3 steps off toward its own lines instead of dying in
-- place. All transition-only + cooldown-gated, like every other order
-- in this file; vanilla may still yank — persistence is measured via
-- readback/divergence, never assumed.
local ESCORT_COMBAT_R = 15      -- guards Attack hostiles this close to the V3
local ESCORT_COMBAT_EVERY = 150 -- per-guard intercept cooldown (frames)
local V3_KITE_R = 12            -- threat this close -> the V3 itself retreats
local V3_KITE_EVERY = 300       -- V3 kite cooldown (frames)
local V3_KITE_DIST = 8          -- kite step in cells
local GARRISON_N = 3
local GARRISON_RADIUS = 12
local GARRISON_EVERY = 600
-- Within 2 cells of the ordered cell = holding (no re-issue, no slot).
local GARRISON_REACHED_R2 = 4

-- Base-threat recall: presence-based. RECALL_TYPES are committed long-range
-- attackers worth bringing home.
-- KIROV id UNCONFIRMED live (no KIROV section in the repo INI subset,
-- never seen in census) — the recall log prints the acted type name.
local RECALL_TYPES = (CFG and CFG.RECALL_TYPES) or { V3 = true, KIROV = true }
local RECALL_THREAT_RADIUS = 20
local RECALL_THREAT_N = 3
local RECALL_FAR = 30
-- Wave-shepherd tuning (M3 initiative protection): a marching AI wave
-- far from home facing overwhelming LOCAL strength is feeding, not
-- attacking (the user's "reflex" — free kills every match). Lone units
-- below WAVE_MIN are left alone (scouts/repositioning, not attacks).
local WAVE_FAR = 25 -- must be this far from home to count as attacking
local WAVE_R = 12 -- fellow marchers inside this radius form the wave
local WAVE_MIN = 3 -- smaller groups are left alone
local WAVE_THREAT_R = 15 -- enemy combat inside this radius threatens
local WAVE_DOOM_MULT = 3 -- threat >= wave x mult: call it off
local RECALL_EVERY = 300

-- RALLY threat radius (2026-09-26): an own building with a hostile combat
-- unit inside this radius is a breach. Tighter than RECALL_THREAT_RADIUS (20)
-- and much tighter than the point-defense intruderR (18) because this is
-- PER BUILDING, not per base: a raider 18 cells from building X is not
-- threatening X. 10 cells covers the firing envelope of direct-fire units
-- plus their approach, so a reserve ordered here arrives in time.
-- The old trigger was "own building below 85% max HP", which was a sampling
-- race: a building can be destroyed between two scans, and two consecutive
-- live matches logged RALLY_BREACH = 0 while a BASE line showed NAMISL at
-- 585/1000 (58.5%). Proximity is observable every scan and cannot be missed
-- between frames.
local RALLY_THREAT_R = 10
local RALLY_THREAT_R2 = RALLY_THREAT_R * RALLY_THREAT_R

-- M2-C3 raider force: economy snipe values (data, not branches).
-- Refinery/power/tech IDs INI-confirmed (NAREFN/GAREFN, NAPOWR/GAPOWR,
-- NATECH/GATECH); Yuri economy IDs unknown — omitted, never invented.
-- NAFLAK (Flak cannon) live-observed; pillbox/sentry are screen-only
-- defense types shared with the garrison table.
local RAID_REFINERY = (CFG and CFG.RAID_REFINERY) or { NAREFN = true, GAREFN = true }
local RAID_POWER = (CFG and CFG.RAID_POWER) or { NAPOWR = true, GAPOWR = true }
local RAID_TECH = (CFG and CFG.RAID_TECH) or { NATECH = true, GATECH = true }
local RAID_AA_BUILDING = (CFG and CFG.RAID_AA_BUILDING) or { NAFLAK = true }

-- Prefixed IDs (e.g. RAZER-NAREFN on modded maps): match exact or
-- "-SUFFIX" so mod namespaces never blind a layer (proven 2026-09-25:
-- belief + raid valuation missed a full-HP RAZER-NAREFN). Dash required —
-- "XNAREFN" without one does not match. Sets stay tiny; linear scan is
-- cheaper than the native calls this code already makes per tick.
local function typeIn(set, t)
    if not t or t == "" then return false end
    if set[t] then return true end
    for k in pairs(set) do
        if t:sub(-(#k + 1)) == "-" .. k then return true end
    end
    return false
end

local function raidTargetValue(e)
    if e.k == "building" then
        if typeIn(RAID_REFINERY, e.t) then return 3.0 end
        if typeIn(RAID_POWER, e.t) then return 2.5 end
        if typeIn(RAID_TECH, e.t) then return 2.0 end
        if typeIn(RAID_AA_BUILDING, e.t) then return 1.5 end
        if CAPTURE_ASSET_TYPES[e.t] then return 3.0 end -- capturable airfield/oil derrick
        return 1.0
    end
    if HARVESTER_TYPES[e.t] then return 2.0 end -- mobile economy fallback
    return 0.0 -- raiders snipe economy, not meat (C3 scope)
end

-- ---------------------------------------------------------------------------
-- M2-C1 Belief / Memory (grudge slice): repeated economic attacks change
-- future raid targeting. EVENT (HP drop or kill of own economy with an
-- enemy near) -> MEMORY (grudge[aiHouse][enemyHouse] count) -> BELIEF
-- (raid value multiplier for that owner's candidates) -> DIFFERENT
-- DECISION (BELIEF_EFFECT when the winner flips). Pure Lua, in-match
-- only (cleared by officerReset — never persist.lua: cross-match memory
-- must not drive deterministic in-match decisions). No RNG, ID-tiebreaks.
-- ---------------------------------------------------------------------------

local GRUDGE_W = 0.5            -- value multiplier per remembered attack
local GRUDGE_CAP = 4            -- max counted attacks per house pair
local GRUDGE_ATTRIB_R = 12      -- attribution radius (cells, mirrors retreat scan)
local ECON_EVENT_EVERY = 300    -- per-victim event cooldown (frames)

local function isEconAsset(e)
    if e.k == "building" then
        return typeIn(RAID_REFINERY, e.t)
            or typeIn(RAID_POWER, e.t) or typeIn(RAID_TECH, e.t)
    end
    return HARVESTER_TYPES[e.t] == true
end

-- Point defense (fixes "parked army at the base is ignored"): enemy ground
-- mobiles inside INTRUDER_RADIUS of any own building are intruders.
-- Tier 1: idle own vehicles near the intruder get Attack orders (transition-
-- only + refresh cap). Tier 2 (march recall): a CONFIRMED intrusion (seen N
-- consecutive scans) pulls marching (non-idle, non-attacking) ground units
-- back with MoveTo; units actually fighting (IsAttacking) are NEVER yanked,
-- and unknown attack state (no binding) means skip — never assume.
-- Point defense intruder kinds: ground mobiles AND aircraft that can threaten
-- own buildings. Kirov reads as kind=="unit" (see AIR_RAIDERS note below);
-- helicopters and jets read as kind=="aircraft". Both must be detected so
-- point defense can respond to air threats over the base.
local DEFENSE_KINDS = (CFG and CFG.DEFENSE_KINDS) or { unit = true, infantry = true, aircraft = true }

-- Suicide-unit types: threat != price (a DTRUCK costs little but one-shots
-- a building). Ranked before everything in intruder sort (data, not logic).
-- DTRUCK INI-confirmed ([DTRUCK] Demolitions Truck, repo INI set).
local SUICIDE_TYPES = (CFG and CFG.SUICIDE_TYPES) or { DTRUCK = true }

-- M2-C4 air defense (data): AA-capable mobile types, drafted first (and
-- exclusively from infantry) against air intruders. All INI-confirmed:
-- HTK Flak Track, FLAKT Flak Trooper, FV Allied IFV, YTNK Gattling Tank.
-- AIR_RAIDERS covers bombers that read as kind=="unit" live (ZEP Kirov —
-- engine ground truth per M1 anomaly note; KIROV kept as harmless extra).
-- kind=="aircraft" (jets etc.) is always air, no list needed.
local AA_TYPES = (CFG and CFG.AA_TYPES) or { HTK = true, FLAKT = true, FV = true, YTNK = true }
local AIR_RAIDERS = (CFG and CFG.AIR_RAIDERS) or { ZEP = true, KIROV = true }

local function isAirThreat(e)
    if e.k == "aircraft" then return true end
    return AIR_RAIDERS[e.t] == true
end

-- M2-C4 severity weights (data): suicide 4.0, vehicle 1.0 + cost/2000,
-- infantry 0.5, other 0.5. Levels: LOW < 2.0 (single scout),
-- NORMAL in between, HIGH >= 6.0 (push).
local SEV_SUICIDE = 4.0
local SEV_INFANTRY = 0.5
local SEV_LOW_BELOW = 2.0
local SEV_HIGH_FROM = 6.0

-- Lease-lite (weakness fix): advice the engine overwrote gets bounded
-- re-asserts, then a release. A native lease primitive would need C++;
-- until its separate Beta case is proven, this is the Lua-side ceiling.
-- The lease window (60f) is SHORTER than Tier-1 refresh (150f) on purpose:
-- the lease is the first responder to a yank; Tier-1 stays the steady
-- allocator. Retry only a live commanded target, max LEASE_RETRIES, then
-- let go (visible as LEASE_REASSERT / LEASE_RELEASED, live-tunable).
local LEASE_RETRIES = 2
local LEASE_RETRY_EVERY = 60

-- Retaliate (M14.1-line self-preservation): an AI combat unit taking fire
-- while holding another target turns onto its assumed attacker (nearest
-- hostile). Corrects only the TARGET via the native path (unit stays in
-- combat — never pulled off, never yanked to base); cooldown-gated, no
-- re-issue inside the window. Skips officer-assigned (roles owned
-- elsewhere) and non-combat types. Apocs CAN hit air — no special case.
local RETALIATE_R = 12
local RETALIATE_EVERY = 300

local function intruderSev(e)
    if SUICIDE_TYPES[e.t] then return SEV_SUICIDE end
    if e.k == "infantry" then return SEV_INFANTRY end
    if e.k == "unit" then return 1.0 + (e.cost or 0) / 2000.0 end
    return 0.5
end

local escortState = {}   -- v3id -> { guards = {ids}, ax, ay, orderedFrame }
local garrisonState = {} -- bldId -> { orderedFrame }
local cmdState = {}      -- house -> { x, y, frame } last breach (Commander blackboard)
local recallState = {}   -- unitId -> { orderedFrame } recalled heavies
local rallyState = {}    -- house -> { x, y, frame } last rally (same-breach cooldown)
local defenseState = {}  -- defenderId -> { targetId, orderedFrame }
local intruderSeen = {}  -- house -> { [intruderId] = { n, lastFrame } }
local defSevLevel = {}   -- M2-C4: house -> last logged severity level
-- M2-C3 raider force: per-AI-house hunter group from idle surplus.
-- raidState[house] = { members = {ids}, targetId, orderedFrame, formedFrame }
local raidState = {}       -- house -> raid group (id-tracked, re-resolved per tick)
local lastThreatFrame = {} -- house -> last frame with intruders or breach (quiet gate)
local raidCooldownUntil = {} -- house -> frame before which no re-form after STANDDOWN
-- M2-C5 execution layer: house -> ForceGroup (CombatStateTracker Observe +
-- Tactical Evaluate/Decide). SmartAI keeps Act (claims/dlog) + target
-- selection (grudge) + coordination. Groups are created on raid FORM and
-- dropped with the group (standdown/retreat keeps it while members live).
local raidGroups = {}

-- ---------------------------------------------------------------------------
-- CAPTURE-ASSET LAYER: defend capturable high-value assets the AI owns
-- (tech airport / airfield, oil derrick OILDERRECK/CAOILD, and other tech
-- buildings), send units to protect them, request/attempt defensive buildings
-- around them (native production is opt-in; default preserves the mod's
-- "command existing units only" safety posture), and repeatedly raid to
-- recapture assets that were taken by the player or another AI.
-- ---------------------------------------------------------------------------
-- Opt-in: when true, requestCaptureDefenseBuilding() may try native house
-- production APIs (pcall-guarded). Default false keeps the historical safety
-- behavior: intent is logged, no production is forced.
SmartAI.CAPTURE_BUILD_DEFENSES_NATIVE = (CFG and CFG.CAPTURE_BUILD_DEFENSES_NATIVE) or false

local CAPTURE_ASSET_TYPES = {
    CAAIRP = true,    -- Tech Airport / aerodrome (capturable)
    CAOILD = true,    -- Tech Oil Derrick (OILDERRECK), capturable economy
    OILDERRECK = true, -- Alias sometimes reported by scripts
    CAHOSP = true,    -- Tech Hospital
    CATHOSP = true,   -- Hospital variant (YR/mod maps)
    CAMACH = true,    -- Tech Machine Shop
    CAPOWR = true,    -- Tech Power Plant
    CASLAB = true,    -- Tech Secret Lab
    CAOUTP = true,    -- Tech Outpost
    -- Extend with map/mod-specific capturable TypeIDs as needed.
}

-- Engineers can capture buildings in RA2/YR. We never order non-engineer
-- combat raiders to Attack a capturable building we want to recapture, because
-- Attack may destroy it instead of capturing it.
local ENGINEER_TYPES = {
    ENGINEER = true,  -- Allied
    SENGINEER = true, -- Soviet
    YENGINEER = true, -- Yuri
}

local function isCaptureAssetType(t)
    return t and CAPTURE_ASSET_TYPES[t] == true
end

local function isEngineerType(t)
    return t and ENGINEER_TYPES[t] == true
end

-- Faction-appropriate defensive building preference for intent logging and
-- (only when CAPTURE_BUILD_DEFENSES_NATIVE is enabled) native attempts.
local function captureDefenseBuildingTypes(aiHouse)
    local types = { "GAPILL", "NASAM" }
    local ok, side = pcall(aiHouse.GetSide, aiHouse)
    if ok and side then
        local s = tostring(side):lower()
        if s:find("sov", 1, true) or s:find("russ", 1, true) or s:find("iraq", 1, true) or s:find("cuba", 1, true) or s:find("liby", 1, true) then
            types = { "NAFLAK", "TESLA" }
        elseif s:find("yuri", 1, true) then
            types = { "YAGGUN", "NATBNK" }
        end
    end
    return types
end

local CAPTURE_DEFENSE_R = 16          -- cells: hostile this close to an asset -> defend
local CAPTURE_DEFENSE_R2 = CAPTURE_DEFENSE_R * CAPTURE_DEFENSE_R
local CAPTURE_GUARD_R = 10            -- cells: desired standoff for proactive guards
local CAPTURE_GUARD_R2 = CAPTURE_GUARD_R * CAPTURE_GUARD_R
local CAPTURE_DEFENSE_N = 3           -- defenders to assign per threatened asset
local CAPTURE_GUARD_N = 2             -- proactive guards to keep near a safe owned asset
local CAPTURE_DEFENSE_EVERY = 240     -- per-asset defense re-order cooldown (frames)
local CAPTURE_GUARD_EVERY = 300       -- per-asset proactive guard re-order cooldown
local CAPTURE_BUILD_EVERY = 900       -- per-asset production-request cooldown
local CAPTURE_RECAPTURE_VALUE = 6.0   -- raid value of a lost asset (above economy)
local CAPTURE_RECAPTURE_R = 120       -- cells: recapture targeting reaches farther
local CAPTURE_RECAPTURE_R2 = CAPTURE_RECAPTURE_R * CAPTURE_RECAPTURE_R
local CAPTURE_RECAPTURE_ENGINEER_EVERY = 360 -- re-dispatch engineers to lost asset

-- captureAssetOwner[buildingId] = houseName: last-seen owner (change detection)
local captureAssetOwner = {}
-- ownedAssets[house] = { [buildingId] = { t, x, y } }: assets this house owns now
local ownedAssets = {}
-- lostAssets[house] = { [buildingId] = { t, x, y, lostFrame } }: assets this
-- house owned but no longer does (captured by enemy/player) -> recapture targets
local lostAssets = {}
-- captureBuildRequested[buildingId] = owner key: production intent emitted for
-- the current ownership cycle. Cleared on loss so recaptured assets can be
-- protected again.
local captureBuildRequested = {}
-- captureDefLast[buildingId] = frame: last tick an asset got reactive defenders
local captureDefLast = {}
-- captureGuardLast[buildingId] = frame: last proactive guard dispatch
local captureGuardLast = {}
-- captureRecaptureDispatch[buildingId] = frame: last engineer dispatch to recapture
local captureRecaptureDispatch = {}

-- M3 SEED — stance + fortunes (character + adaptation from evidence).
-- stanceCache[house] = "rusher" | "turtle": assigned once, first-seen
-- order (deterministic: engine house order — 1v1 showcase rushes, then
-- alternate so mixed lobbies show both characters). Easy preset skips
-- stance (rally-only by design). raidLevel[house] in [-1, +2]: +1 per
-- observed raid WIN (target gone, members alive), -1 per loss tick or
-- wipe; sizes the next form. lastCounter[house]: counterpunch cooldown.
-- All cleared by officerReset; all in-match only (never persist.lua).
local stanceCache = {}
local stanceCount = 0
local stanceAnnounced = {}
local raidLevel = {}
local lastCounter = {}
local feintState = {} -- house -> last feint frame (FEINT_EVERY)
-- Counterpunch tuning: a rusher whose enemy fields this few combat
-- units stops waiting for quiet and finishes. Cooldown between punches.
local PUNCH_WEAK_N = 4
local PUNCH_COOLDOWN = 1800

-- House getter factory (avoids loop-variable capture in closures).
local function houseGetter(h)
    return function() return h end
end

-- === M2-C4 ADAPTATION (Act -> Observe result -> Adapt) ====================
-- Severity re-evaluates the CURRENT threat size every tick. That is
-- re-evaluation, not adaptation: it has no memory of how the previous
-- response went. This table is that memory.
--
-- dEff[aiHouse] = { w = wins, l = losses, streak = consecutive losses,
--                   adaptUntil = frame before which no adapt-pull }
--
-- An "episode" is one point-defense assignment (defenderId -> intruderId)
-- that ENDS. It is resolved in the end-of-Update cleanup, where both
-- liveness facts are already known:
--   defender gone, intruder alive -> LOSS
--   defender alive, intruder gone -> WIN
--   both gone                      -> draw, counted as neither
--   both alive                     -> still ongoing, not counted
--
-- ADAPT_STREAK_TRIGGER consecutive losses arms the adaptation. Rationale: a
-- single loss can be a cornered unit; two in a row is a signal that the
-- current defence allocation is not winning its exchanges.
--
-- Why escalate by pulling units instead of raising `sevN`: measured live,
-- `poolIdle = 0` while `poolOwn = 1..6` -- there are no idle defenders left to
-- draft, so a larger sevN would compute a bigger number and still find zero
-- candidates. Marching units (`attacking == false`) are the pool that actually
-- exists, and march-recall already uses exactly that predicate.
local dEff = {}
local ADAPT_STREAK_TRIGGER = 2
local ADAPT_PULL_MIN_DIST = 25 -- cells from the base anchor; near units are left alone
-- M2-C4 RECOVERY: how many near-reserve units ONE response may commit. Kept at
-- 1 on purpose -- a single loss is a signal to pull in the closest usable unit,
-- not a licence to strip the map. The response is additionally rate-limited by
-- defenseEvery and, per unit, by P.redirectEvery through recallState.
local RECOVERY_MAX_UNITS = 1
local dEffStats = { w = 0, l = 0, pulls = 0, denied = 0, draw = 0, recovery = 0 } -- per-match totals (diagnostic)

-- M2-C1 belief tables (in-match only; cleared by officerReset below).
-- grudge[aiHouse][enemyHouse] = { n = count, lastFrame = frame }
-- econSeen[aiHouse][unitId] = { hp, x, y, eventFrame } prev-tick economy
-- snapshot, PER HOUSE. The outer key is mandatory: the belief loop runs once
-- per AI house with a nowSeen set built from that house alone, so a flat
-- id->snapshot store made every OTHER house's economy look "gone" on every
-- scan -- false ECON_KILLED events, mass pruning, and (because the prune
-- re-seeds eventFrame) a dead per-victim cooldown. See the 2026-09-26 fix.
local grudge = {}
local econSeen = {}
-- Retaliate prev-tick store: combatSeen[unitId] = { hp, retalFrame }.
local combatSeen = {}
-- Bomber-focus cooldowns: focusState[unitId] = { orderedFrame }.
local focusState = {}
-- NOTE: these MUST stay above officerReset: Lua binds upvalues lexically,
-- so a reset function defined before the local would silently write a
-- global instead (live bug found 2026-09-24: census cadence + divLogged
-- survived match restarts).
local divLogged = {} -- defenderId -> last divergent actual target id logged
local lastCensusFrame = 0

-- RADEVAC (radiation interplay): own infantry out of warned/burning cells.
-- Reads the radiation mod's read-only Mod.GetStatus() via package.loaded
-- (nil when radiation is inactive -> whole layer silent, zero cost).
-- WARNING (12s) evacuates preemptively with a margin; ACTIVE moves out
-- whoever is still inside. Destination is the nearest own building cell
-- (vanilla enter-if-garrisonable, screen otherwise — the player's own
-- counterplay, mirrored). MoveTo only, never Hunt; fighting and
-- unknown-state infantry are never yanked.
local RADEVAC_WARN_MARGIN = 2   -- extra cells of head-start during WARNING
local RADEVAC_EVERY = 300       -- per-unit re-order cooldown (frames)
local RADEVAC_REACHED_R2 = 4    -- within 2 cells of last dest = arrived, hold
-- Mirrors radiation CFG.exempt (units the hazard never hits — ordering them
-- out would be pure churn). Civilian types are excluded separately below.
local RADEVAC_EXEMPT = { AGENT = true, ENGR = true, THIEF = true }
local radEvacState = {} -- unitId -> { orderedFrame, bx, by } last evac dest
local minerState = {} -- unitId -> { orderedFrame, ax, ay } last harvest kick
local retargetState = {} -- unitId -> { orderedFrame } last target switch
-- (declared here: officerReset below assigns it — upvalue rule)
local heroState = {} -- heroId -> { targetId, orderedFrame, posture } HERO officer
local radEvacHud = {} -- house -> last evac HUD frame (900f throttle)
local minerHud = {} -- house -> true once announced per match
local kiteHud = {} -- v3id -> last kite HUD frame (900f throttle)
local waveHud = {} -- house -> last shepherd HUD frame (900f throttle)

-- Read-only pull of the radiation hazard state. Returns nil unless the
-- radiation mod is loaded AND in WARNING/ACTIVE with targets; otherwise
-- phase, radius (cells) and a target list. Never errors outward.
local function radiationStatus()
    if type(package) ~= "table" or type(package.loaded) ~= "table" then
        return nil
    end
    local mod = package.loaded["mods.radiation.main"]
    if type(mod) ~= "table" or type(mod.GetStatus) ~= "function" then
        return nil
    end
    local ok, st = pcall(mod.GetStatus)
    if not ok or type(st) ~= "table" then return nil end
    if st.phase ~= "WARNING" and st.phase ~= "ACTIVE" then return nil end
    if type(st.targets) ~= "table" or #st.targets == 0 then return nil end
    local r = tonumber(st.radius) or 6
    if r < 1 then r = 1 end
    return st.phase, st.targets, r
end

-- ---------------------------------------------------------------------------
-- BUILDLAW: full build-order enforcement for all 3 factions (user:
-- "no more endless debugging" — strict limiters, 2026-09-30).
-- INI ground truth: rulesmd_ref.ini is MODDED (campaign CA* rows, lamps,
-- "intentionally empty" live rulesmd.ini = stock engine rules), so it is
-- advisory only. Encoded below are STOCK-CONFIDENT rows only; anything
-- uncertain is EXCLUDED (unknown = allowed — misses, never false
-- positives). Full extracted graph lives in this header; enforced rows
-- are marked [+], studied-but-excluded [-] with reasons.
--
-- ALLIED unlock spine:
--   Power(GAPOWR) -> Barracks(GAPILE)/Refinery(GAREFN) -> WF(GAWEAP) ->
--   Radar(GAAIRC)/Yard(GAYARD) -> Lab(GATECH) -> superweapons/tech.
--   [+] GATECH <= WF + RADAR
--   [+] GAWEAT/GACSPH/GASPYSAT <= lab
--   [+] NANRCT/NAINDP(+PROC)/GAOREP(+PROC) (high tech)
-- SOVIET unlock spine:
--   Power(NAPOWR) -> Barracks(NAHAND)/Refinery(NAREFN) -> WF(NAWEAP) ->
--   Radar(NARADR)/Yard(NAYARD) -> Lab(NATECH) -> superweapons/tech.
--   [+] NATECH <= WF + RADAR
--   [+] NAMISL/NAIRON <= lab
-- YURI unlock spine:
--   Power(YAPOWR) -> Barracks(YABRCK)/Refinery(YAREFN) -> WF(YAWEAP) ->
--   Lab(YATECH) -> superweapons/tech (Yuri radar IS the Psychic Sensor).
--   [+] YATECH <= WF + RADAR
--   [+] YAGNTC/YAPPET <= lab
-- [-] everything recovery-critical (power/barracks/refineries/factories/
--     yards/depots/radars/defenses): policing recovery order punishes
--     worse than the bypass (live refinery-first: ugly, harmless,
--     self-healing; plus 11 powerless-fixture sells -> surrender
--     cascade in the shared suite). Build ORDER lives in INI Build
--     lists, not in a Lua policeman. Strict where stakes are high.
-- [-] Excluded modded/corrupt rows: GAFWLL, NASAM, NACLON (disputed lab),
-- NAPSIS (comment-corrupted line), NATBNK, NABNKR, GAGREEN, GASAND,
-- GAWALL/NAWALL (walls must never trigger), ATESLA (modded), GAAIRC
-- paradrop dummies AMRADR/NARADR-as-dummy (never AI-owned; inert anyway),
-- campaign CA*/lamps. [-] Pillboxes/flak/gattling (defenses need no
-- strict gate; order unambiguous in practice, stakes nil).
-- [-] CY token everywhere: packed-MCV edge + zero cheat-catching value
-- (AI always starts deployed; "never had CY" is near-impossible).
-- PROC IS encoded (via [General] PrerequisiteProc + SMIN alternate)
-- because NAINDP/GAOREP rows need it; POWER group was dropped with the
-- tier rows (no remaining row references it).
-- Why enforced rows are safe: normal AI order satisfies everything at
-- birth (its own lists walk prereq-consistent), so they fire ONLY on
-- bypass paths (community-confirmed "AI ignores prerequisite") — and
-- the per-type SELL_CAP (default 3, then log-and-leave) bounds even
-- those, so enforcement can tax a cheat without bricking recovery.
-- Rule: a listed building is sold IFF all hold — chain broken NOW,
-- chain broken at BIRTH (birth-legal never touched), never queue-marked
-- fresh at birth (AI.IsQueued: ordered while satisfied =
-- queue-completion; marks refresh while queued, expire QMARK_WINDOW
-- after last sighting), birth scan > 1 (load-time inventory assumed
-- legal), past BUILDLAW_GRACE, per-type sells below SELL_CAP (then
-- log-and-leave), AI house, non-surrendered, preset on.
-- ---------------------------------------------------------------------------
-- RADAR providers (Radar=yes in INI): Allied Airforce Command, SpySat
-- uplink, Soviet Radar Tower, Yuri Psychic Sensor (+AMRADR dummy, inert).
local BUILDLAW_RADAR = { "GAAIRC", "GASPYSAT", "AMRADR", "NARADR", "NAPSIS" }
-- PROC group ([General] PrerequisiteProc): any refinery ever. SMIN is
-- listed alongside (its [General] PrerequisiteProcAlternate role: an
-- undeployed Slave Miner vehicle satisfies PROC — recorded from the
-- units snapshot, see the cur-building loop).
local BUILDLAW_PROC = { "GAREFN", "NAREFN", "YAREFN", "SMIN" }
-- PROC alternate ([General] PrerequisiteProcAlternate): Slave Miner
-- VEHICLE satisfies PROC (Yuri). Recorded from the units snapshot.
local PROC_ALT_TYPES = { SMIN = true }

-- AND of ORs: every entry needs >=1 alternative ever seen.
-- SCOPE (senior cut 2026-09-30, after the tier-row experiment): HIGH
-- STAKES ONLY — labs, superweapons, high tech. Recovery infrastructure
-- (power/barracks/refineries/factories/yards/depots/radars/defenses)
-- is DELIBERATELY UNLISTED: punishing a recovering AI for its rebuild
-- order griefs recovery worse than the bypass itself (proven live:
-- refinery-first after total raze is ugly but harmless; selling it
-- stalls the AI for zero match impact). Build ORDER lives in INI
-- ([AI] BuildPower/BuildRefinery/... + ScriptTypes), not in a Lua
-- policeman — a snapshot layer cannot guide construction, only punish
-- it. BARRACKS specifically broke the shared defense suite first
-- (11 powerless-fixture sells -> surrender cascade -> 29 red).
local BUILDLAW = {
    GATECH = { { "GAWEAP" }, BUILDLAW_RADAR },
    NATECH = { { "NAWEAP" }, BUILDLAW_RADAR },
    YATECH = { { "YAWEAP" }, BUILDLAW_RADAR },
    GAWEAT = { { "GATECH" } },
    GACSPH = { { "GATECH" } },
    GASPYSAT = { { "GATECH" } },
    NAMISL = { { "NATECH" } },
    NAIRON = { { "NATECH" } },
    NANRCT = { { "NATECH" } },
    NAINDP = { { "NATECH" }, BUILDLAW_PROC },
    GAOREP = { { "GATECH" }, BUILDLAW_PROC },
    YAGNTC = { { "YATECH" } },
    YAPPET = { { "YATECH" } },
}

-- Tunable grace window (frames). Test override path; live default below.
SmartAI.BUILDLAW_GRACE = 1800 -- 30s: pre-placed inventory is never sold
-- Sell cap per (house, type) per match. Bounds rebuild loops: without
-- it, an AI stuck re-cheating one type would be taxed forever and never
-- progress. After the cap the type is left standing + logged once.
SmartAI.BUILDLAW_SELL_CAP = 3
-- Queue-mark lifetime (frames) after the last satisfied sighting.
-- A mark must survive queue->completion lag (same/next scan) but must
-- NOT spare a fresh cheat minutes later (live 2026-09-30: a mark from
-- f=29890 would otherwise grandfather a post-raze rebuild forever).
SmartAI.QMARK_WINDOW = 1800

-- birthScan[buildingId] / birthViol[buildingId]: scan number of first
-- sighting + whether the chain was broken then. Load-time and
-- pre-placed inventory (birth scan 1) is assumed legal. Cleared by
-- officerReset; never pruned (ids are never recycled; a flickering
-- building keeps its original birth).
local birthScan = {}
local birthViol = {}
-- sellCounts[house][canonType] / gaveUp[house][canonType]: per-match
-- enforcement budget + once-only give-up notice (see SELL_CAP).
local sellCounts = {}
local gaveUp = {}

-- queuedWhileSat[house][canonType] = true: type observed in production
-- (AI.IsQueued, read-only) while its chain was satisfied. Closes the
-- had-early/lost/cheat-late hole: queue-completion is grandfathered,
-- fresh post-loss orders are not. Queues persist minutes, scans run
-- every 15-30f, so a real queue cannot hide between two scans.
-- Residual: save-loaded matches (first scan sees queue + dead chain).
local queuedWhileSat = {}

-- Row lookup tolerating modded prefixed IDs ("RAZER-GAWEAT").
-- Returns row + canonical key (engine IDs are unprefixed, which is
-- also what the queue binding must be asked with).
local function buildLawRowKey(t)
    if not t or t == "" then return nil, nil end
    if BUILDLAW[t] then return BUILDLAW[t], t end
    for k, row in pairs(BUILDLAW) do
        if t:sub(-(#k + 1)) == "-" .. k then return row, k end
    end
    return nil, nil
end

local function buildLawRow(t)
    local row = buildLawRowKey(t)
    return row
end

-- True when `want` was seen exactly or as a "-SUFFIX".
local function typeSeenAs(seen, want)
    if seen[want] then return true end
    for t in pairs(seen) do
        if t:sub(-(#want + 1)) == "-" .. want then return true end
    end
    return false
end

-- First unmet AND-entry (alternatives joined), or nil when satisfied.
local function buildLawMissing(seen, row)
    for _, entry in ipairs(row) do
        local ok = false
        for _, alt in ipairs(entry) do
            if typeSeenAs(seen, alt) then ok = true break end
        end
        if not ok then return table.concat(entry, "/") end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- MCVLAW: Allied/Soviet MCVs need their War Factory + Service Depot
-- (INI: AMCV <= GAWEAP,GADEPT / SMCV <= NAWEAP,NADEPT; YMCV has NO
-- Prerequisite line — freely rebuildable, exempt by design, verified
-- 2026-10-01). Units cannot be sold, so the enforcement is destruction
-- via the native damage pipeline (no attacker, no refund, no bounty —
-- damage events are unwired). Scope is deliberately ONE unit family:
-- combat units are never policed (killing armies = griefing).
-- Rule: never-had (no depot type EVER seen for that house) + birth>1 +
-- grace + cap + MOBILE only (a deployed MCV is someone's base — skip
-- via IsDeployed; old DLLs without the binding fail open = enforced,
-- the DLL ships with the scripts so this is a non-issue in practice).
-- Queue-completion is UNSIGHTED for units (AI.IsQueued resolves
-- buildings only) — documented residual, same class as the French
-- case. Rationale for never-had over birth-strict here: a legally
-- ordered MCV whose depot then dies (the user's raze scenario) must
-- survive relocation; only systematic depot-less production is cut.
-- ---------------------------------------------------------------------------
local MCVLAW = {
    AMCV = { { "GAWEAP" }, { "GADEPT" } },
    SMCV = { { "NAWEAP" }, { "NADEPT" } },
}

-- seenBTypes[house][rawType] = true: every own BUILDING type ever
-- snapshotted (MCVLAW depot AND factory entries both read here).
-- Cleared by officerReset; never pruned (types, tiny — and pruning
-- would resurrect grandfathered cheats as "fresh" violations).
local seenBTypes = {}

-- Row + canonical key for an MCV type (exact or "-SUFFIX"), nil else.
-- YMCV (and anything unlisted) returns nil: untouched by design.
local function mcvLawRow(t)
    if not t or t == "" then return nil, nil end
    if MCVLAW[t] then return MCVLAW[t], t end
    for k, row in pairs(MCVLAW) do
        if t:sub(-(#k + 1)) == "-" .. k then return row, k end
    end
    return nil, nil
end

local function officerReset()
    unitOrderPrio = {}
    escortState = {}
    garrisonState = {}
    cmdState = {}
    recallState = {}
    rallyState = {}
    defenseState = {}
    intruderSeen = {}
    defSevLevel = {}
    raidState = {}
    lastThreatFrame = {}
    raidCooldownUntil = {}
    raidGroups = {}
    stanceCache = {}
    stanceCount = 0
    stanceAnnounced = {}
    raidLevel = {}
    lastCounter = {}
    feintState = {}
    grudge = {}
    econSeen = {}
    dEff = {}
    dEffStats = { w = 0, l = 0, pulls = 0, denied = 0, draw = 0, recovery = 0 }
    combatSeen = {}
    focusState = {}
    radEvacState = {}
    minerState = {}
    retargetState = {}
    heroState = {}
    moveTrack = {}
    moveStats = { ordered = 0, arrived = 0, yanked = 0, handoff = 0,
        stale = 0 }
    if TargetLease then TargetLease.Clear() end -- Phase 1: Lua mirror of
    -- native ClearAll (match restart): no lease outlives the reset.
    lastMoveStatsFrame = 0
    seenBTypes = {}
    radEvacHud = {}
    minerHud = {}
    kiteHud = {}
    waveHud = {}
    birthScan = {}
    birthViol = {}
    sellCounts = {}
    gaveUp = {}
    queuedWhileSat = {}
    captureAssetOwner = {}
    ownedAssets = {}
    lostAssets = {}
    captureBuildRequested = {}
    captureDefLast = {}
    captureGuardLast = {}
    captureRecaptureDispatch = {}
    scanCounter = 0
    divLogged = {}
    lastCensusFrame = 0
    surrendered = {}
    houseParamsCache = {}
    aiHousesCache = {}
end

-- Coordination: units the Officer is actively handling (escort bodyguards,
-- threatened pullbacks, active defenders). Commander rally stands off them.
-- A stood-down escort (breach owns the sector, guards released to the
-- rally per the hygiene pass) is transparent here: otherwise the
-- assignment memory blocks the very rally the stand-down released the
-- guards for, for one scan.
local function isOfficerAssigned(id)
    local gs = guardState[id]
    if gs and gs.threatened then return true end
    if defenseState[id] then return true end
    if heroState[id] then return true end -- HERO-held: every layer stands off
    for _, st in pairs(escortState) do
        if not st.standDown then
            for _, gid in ipairs(st.guards) do
                if gid == id then return true end
            end
        end
    end
    for _, rst in pairs(raidState) do
        if rst.members then
            for _, mid in ipairs(rst.members) do
                if mid == id then return true end
            end
        end
    end
    if minerState[id] then return true end -- kicked miner: rally stands off
    return false
end

-- Like isOfficerAssigned, but the miner's own assignees don't block
-- re-evaluation. Without this, a kicked miner would be officer-held
-- forever BY ITS OWN assignment, and the cooldown/arrival logic below
-- would be dead code (live-found 2026-09-30: re-kick never fired).
-- Every other layer's claim is still honored: a miner drafted by
-- point defense mid-intercept is never yanked back.
local function officerHeldElsewhere(id)
    local gs = guardState[id]
    if gs and gs.threatened then return true end
    if defenseState[id] then return true end
    for _, st in pairs(escortState) do
        if not st.standDown then
            for _, gid in ipairs(st.guards) do
                if gid == id then return true end
            end
        end
    end
    for _, rst in pairs(raidState) do
        if rst.members then
            for _, mid in ipairs(rst.members) do
                if mid == id then return true end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Snapshot: ONE World scan per tick, pcall-hardened. Every layer below reads
-- cached fields instead of re-issuing native calls (GetPosition/GetDistanceTo
-- per pair was the old O(n*m) native-call hotspot). Building userdata never
-- persists past the tick; unit userdata is used same-tick only.
-- ---------------------------------------------------------------------------

local function snapOf(u)
    local aliveOk, alive = pcall(u.IsAlive, u)
    if not aliveOk or alive ~= true then return nil end
    local e = { u = u, idle = false, attacking = nil }
    local ok, v = pcall(u.GetId, u)
    if not ok or type(v) ~= "number" then return nil end
    e.id = v
    ok, v = pcall(u.GetOwner, u)
    e.oh = (ok and v) or nil
    if e.oh then
        local onOk, on = pcall(e.oh.GetName, e.oh)
        e.on = (onOk and type(on) == "string") and on or nil
    end
    ok, v = pcall(u.GetTypeName, u)
    e.t = (ok and type(v) == "string") and v or ""
    ok, v = pcall(u.GetKind, u)
    e.k = (ok and type(v) == "string") and v or ""
    ok, v = pcall(u.GetPosition, u)
    if ok and type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" then
        e.x, e.y, e.hasPos = v.x, v.y, true
    else
        e.x, e.y, e.hasPos = 0, 0, false
    end
    ok, v = pcall(u.IsIdle, u)
    e.idle = (ok and v == true)
    ok, v = pcall(u.IsAttacking, u)
    if ok then e.attacking = (v == true) end
    ok, v = pcall(u.GetHealth, u)
    e.hp = (ok and type(v) == "number") and v or nil
    ok, v = pcall(u.GetMaxHealth, u)
    e.maxhp = (ok and type(v) == "number") and v or nil
    ok, v = pcall(u.GetCost, u)
    e.cost = (ok and type(v) == "number" and v > 0) and math.floor(v) or 0
    -- VALOR: veterancy tier for preservation + anti-valor targeting.
    -- Missing binding (old DLL, odd object) reads as rookie: promotion
    -- blindness, never a misgrade — same fail-quiet as cost above.
    ok, v = pcall(u.GetVeterancy, u)
    e.vet = (ok and (v == "veteran" or v == "elite")) and v or "rookie"
    -- Fraction to the next tier (0.0..1.0; missing binding reads 0).
    ok, v = pcall(u.GetVeterancyProgress, u)
    e.vetProgress = (ok and type(v) == "number" and v >= 0)
        and math.min(v, 1.0) or 0
    return e
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function findSnap(list, id)
    for _, e in ipairs(list) do
        if e.id == id then return e end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Command provenance tracking (observability upgrade).
-- Every SmartAI-issued command is logged through a structured SMARTAI_COMMAND
-- event so a log reader can reconstruct command provenance: which subsystem
-- issued which command to which unit, targeting what, and why.
--
-- State is stored on SmartAI.prov to avoid adding locals to the main chunk
-- (Lua limits each chunk/function to 200 local variables).
--   SmartAI.prov.counter - monotonically increasing per-match command counter
--   SmartAI.prov.log     - most recent command per unit for outcome correlation
--   SmartAI.prov.frame   - current frame, set by SmartAI.Update each tick
-- ---------------------------------------------------------------------------
SmartAI.prov = {
    counter = 0,
    log = {},   -- unitId -> { frame, command_id, command_type, target_id, target_type, reason }
    byHouse = {}, -- house -> cumulative { commands_issued, logging_errors }
    logging_errors = 0,
    frame = 0,  -- set by SmartAI.Update at the start of each tick
}

-- Log a structured command event at the point of issuance.
-- All parameters are strings/numbers; nil fields are logged as "-".
-- Returns true if the event was emitted, false on logging failure.
-- The method is defined below dlog so it captures the local logger correctly.


-- ---------------------------------------------------------------------------
-- P0: Order priority arbitration (lightweight). Prevents lower-priority layers
-- from overriding recent higher-priority orders on the same unit.
-- ---------------------------------------------------------------------------
local ORDER_PRIORITY = (CFG and CFG.ORDER_PRIORITY) or {
    SURVIVAL = 100, DEFENSE = 80, ESCORT = 70, OBJECTIVE = 60, SUPPORT = 40, IDLE = 10,
}
local ORDER_PRIORITY_WINDOW = (CFG and CFG.ORDER_PRIORITY_WINDOW) or 120
local unitOrderPrio = {} -- unitId -> { prio, frame, system }

local function systemPriority(system)
    if not system then return ORDER_PRIORITY.IDLE end
    local s = tostring(system)
    if s == "SURVIVAL" or s == "GUARD" or s == "GUARD_PULLBACK" or s == "ESCORT_KITE" or s == "V3_KITE" or s == "RECALL" or s == "RADEVAC" then
        return ORDER_PRIORITY.SURVIVAL
    end
    if s == "DEFENSE" or s == "CAPTURE_DEFENSE" or s == "RETALIATE" or s == "BASE_DEFENSE" then
        return ORDER_PRIORITY.DEFENSE
    end
    if s == "ESCORT" or s == "ESCORT_COMBAT" or s == "CAPTURE_GUARD" then
        return ORDER_PRIORITY.ESCORT
    end
    if s == "RAID" or s == "RETARGET" or s == "CAPTURE_RECAPTURE" or s == "HERO" or s == "ATTACK" then
        return ORDER_PRIORITY.OBJECTIVE
    end
    if s == "GARRISON" or s == "RALLY" or s == "SHEPHERD" or s == "MINER" then
        return ORDER_PRIORITY.SUPPORT
    end
    return ORDER_PRIORITY.IDLE
end

local function canIssueOrder(e, system)
    if not e or not e.id then return true end
    local cur = unitOrderPrio[e.id]
    if not cur then return true end
    local now = (SmartAI.prov and SmartAI.prov.frame) or 0
    if now - (cur.frame or 0) > ORDER_PRIORITY_WINDOW then return true end
    local newP = systemPriority(system)
    -- same or higher priority can take over; same system can refresh
    if newP >= cur.prio then return true end
    if system and cur.system == system then return true end
    return false
end

local function markOrderIssued(e, system)
    if not e or not e.id then return end
    local now = (SmartAI.prov and SmartAI.prov.frame) or 0
    unitOrderPrio[e.id] = { prio = systemPriority(system), frame = now, system = system }
end


-- Wrap orderMove with provenance logging.
-- issuer/system/reason/extra are optional context from the call site.
local function orderMove(e, x, y, issuer, system, reason, extra)
    if not canIssueOrder(e, system) then return false end
    local ok, res = pcall(e.u.MoveTo, e.u, x, y)
    if ok then
        markOrderIssued(e, system)
        -- Provenance log (best-effort; never blocks the command)
        pcall(SmartAI.logCommand, issuer or "UNKNOWN", system or "UNKNOWN",
            "MOVE", e.id, e.t, e.on and e.on, nil, nil, nil,
            reason or "unspecified", extra)
    end
    return ok and res == true
end

-- ---------------------------------------------------------------------------
-- Target evaluation logging (observability upgrade).
-- The logger method is defined below dlog to capture the local logger.
-- ---------------------------------------------------------------------------


-- Mission read helpers (defensive: GetMission may return a numeric code
-- or fail — both read as nil, i.e. UNREADABLE, which always means HOLD,
-- never yank: false positives would poison the measurement).
local function readMissionName(e)
    local ok, m = pcall(e.u.GetMission, e.u)
    if ok and type(m) == "string" then return m end
    return nil
end

local function unitOnMoveMission(e)
    return readMissionName(e) == "Move"
end

-- MoveTo readback (overwrite measurement): tracked orders carry a
-- first-scan memory; moveReadback() verdicts each tracked unit per
-- scan as ARRIVED (at dest), HOLDING (mission Move, closing in),
-- YANKED (mission changed away with no SmartAI owner — vanilla or
-- manual re-task), HANDOFF (a SmartAI layer owns it now — not a yank),
-- or STALE (still on MoveTo mission after MOVE_TRACK_EXPIRE_F frames
-- with no arrival — stuck, ignored, or claimed too late to matter).
-- Verdicts drop the entry; entries also drop on death/disappearance
-- (silent — the unit is gone, not the order's fault). The window is
-- deliberately LONG (probe-2 finding 2026-10-03: a 6-scan window went
-- blind to a Tier-1 draft landing 600f after the rally order — the
-- drain is real, the verdict must outlive the march).
-- Counts feed MOVE_STATS (census cadence, incl. pool sizes for the
-- availability trend) + MoveInspect (harness).
-- Today only RALLY tracks (the Hunt-fix follow-up needs exactly
-- GetMission readback here); escort refresh/recall use plain
-- orderMove until the numbers say otherwise.
local moveTrack = {} -- unitId -> { ax, ay, frame, site, scans }
local moveStats = { ordered = 0, arrived = 0, yanked = 0, handoff = 0,
    stale = 0 }
local lastMoveStatsFrame = 0
local MOVE_TRACK_EXPIRE_F = 3600 -- 2 min: a march ends or it never will
local MOVE_REACHED_R2 = 4

local function orderMoveTracked(e, x, y, site, frame, issuer, system, reason, extra)
    if not orderMove(e, x, y, issuer, system, reason, extra) then return false end
    moveTrack[e.id] = { ax = x, ay = y, frame = frame, site = site,
        scans = 0 }
    moveStats.ordered = moveStats.ordered + 1
    return true
end

local function moveReadback(frame, units, logFn)
    for id, t in pairs(moveTrack) do
        local e = findSnap(units, id)
        if e == nil then
            moveTrack[id] = nil -- gone (died/sold/left): not a verdict
        else
            t.scans = t.scans + 1

            if e.hasPos
            and dist2(e.x, e.y, t.ax, t.ay) <= MOVE_REACHED_R2 then
                moveTrack[id] = nil
                moveStats.arrived = moveStats.arrived + 1
            else
                local mission = readMissionName(e)

                if t.scans < 2 then
                    -- Order settling: mission may not have commenced yet.
                    elseif mission == nil or mission == "Move" then
                    if frame - (t.frame or 0) > MOVE_TRACK_EXPIRE_F then
                        moveTrack[id] = nil
                        moveStats.stale = moveStats.stale + 1
                        logFn("MOVE_DIVERGENCE", frame, string.format(
                            "unit=%s site=%s dest=%d,%d at=%d,%d mission=%s verdict=STALE",
                            tostring(id), tostring(t.site), t.ax, t.ay,
                            e.hasPos and e.x or -1, e.hasPos and e.y or -1,
                            tostring(mission)))
                    end
                    -- else HOLDING: keep watching silently
                elseif isOfficerAssigned(id) then
                    moveTrack[id] = nil
                    moveStats.handoff = moveStats.handoff + 1
                else
                    moveTrack[id] = nil
                    moveStats.yanked = moveStats.yanked + 1
                    logFn("MOVE_DIVERGENCE", frame, string.format(
                    "unit=%s site=%s dest=%d,%d at=%d,%d mission=%s",
                    tostring(id), tostring(t.site), t.ax, t.ay,
                    e.hasPos and e.x or -1, e.hasPos and e.y or -1,
                    tostring(mission)))
                end
            end
        end
    end
end

-- Test-only inspector (harnesses only): MoveTo readback counters.
-- Returns live table — tests must read, never write.
function SmartAI.MoveInspect()
    local tracked = 0
    for _ in pairs(moveTrack) do tracked = tracked + 1 end
    return { ordered = moveStats.ordered, arrived = moveStats.arrived,
        yanked = moveStats.yanked, handoff = moveStats.handoff,
        stale = moveStats.stale,
        tracked = tracked, idleNow = moveStats.idleNow or 0,
        marchingNow = moveStats.marchingNow or 0 }
end

local function orderAttack(e, target, issuer, system, reason, extra)
    if not canIssueOrder(e, system) then return false end
    local ok, res = pcall(e.u.Attack, e.u, target)
    if ok then
        markOrderIssued(e, system)
        -- Resolve target identity for provenance
        local tgtId, tgtType, tgtOwner = nil, nil, nil
        if target then
            local okT, tid = pcall(target.GetId, target)
            if okT then tgtId = tid end
            local okT2, ttype = pcall(target.GetTypeName, target)
            if okT2 then tgtType = ttype end
            local okT3, towner = pcall(target.GetOwner, target)
            if okT3 and towner then
                local okT4, toname = pcall(towner.GetName, towner)
                if okT4 then tgtOwner = toname end
            end
        end
        -- Provenance log (best-effort; never blocks the command)
        pcall(SmartAI.logCommand, issuer or "UNKNOWN", system or "UNKNOWN",
            "ATTACK", e.id, e.t, e.on and e.on,
            tgtId, tgtType, tgtOwner,
            reason or "unspecified", extra)
    end
    return ok and res ~= false
end

-- Hero base scoring shared by the HERO scan and its focus-keep
-- (one function, no drift): per-hero chassis value + VALOR bonus.
-- Returns nil for YuriP-vs-building (uncontrollable, never scored).
local function heroBaseValue(ht, u)
    local isBld = u.k == "building"
    local v
    if ht == "TANYA" then
        if u.k == "infantry" then v = 3.0
        elseif isBld then v = raidTargetValue(u)
        else v = 1.0 end
    elseif ht == "BORIS" then
        if u.k == "unit" then v = 2.5
        elseif u.k == "infantry" then v = 1.5
        else v = 1.0 end
    else -- YURIPR: control the expensive one
        if isBld then return nil end
        v = 1.0 + (u.cost or 0) / 2000.0
        if v > 4.0 then v = 4.0 end
    end
    return v + valorBonus(u)
end

-- Retarget value (M3 fight-smarter): what a target is WORTH shooting.
-- Buildings reuse raidTargetValue (economy-weighted); mobiles price by
-- role + cost so Apocs outrank GIs and MCVs/suicides top everything.
-- VALOR: enemy veterans/elites/heroes/T3 carry a bonus (an elite GI
-- outranks a rookie Rhino — killing multipliers first is the doctrine).
local function retargetValue(e)
    if e.k == "building" then return raidTargetValue(e) end
    if HARVESTER_TYPES[e.t] then return 2.0 end
    if MCV_TYPES[e.t] then return 3.0 end
    if ARTILLERY_TYPES[e.t] then return 2.5 end
    if SUICIDE_TYPES[e.t] then return 4.0 end
    if e.k == "aircraft" then return 1.0 end
    local base = 0.5
    if e.k == "unit" then base = 1.0 + (e.cost or 0) / 4000.0 end
    return base + valorBonus(e)
end

-- Retarget tuning: only a CLEAR upgrade (gap), never farther than the
-- current engagement (+2 cells slop, no repositioning treks), and only
-- inside REASSESS_R for attack-movers (no native target to compare).
local RETARGET_R = 15
local RETARGET_GAP = 1.0
local RETARGET_EVERY = 300

local function orderHarvest(e, x, y, issuer, system, reason, extra)
    if type(e.u.HarvestAt) ~= "function" then return false end
    local ok, res = pcall(e.u.HarvestAt, e.u, x, y)
    if ok then
        pcall(SmartAI.logCommand, issuer or "UNKNOWN", system or "UNKNOWN",
            "HARVEST", e.id, e.t, e.on and e.on,
            nil, nil, nil,
            reason or "unspecified", string.format("dest=%d,%d", x, y))
    end
    return ok and res ~= false
end

local function orderDestroy(e, amount, issuer, system, reason, extra)
    local ok, res = pcall(e.u.TakeDamage, e.u, amount)
    if ok then
        pcall(SmartAI.logCommand, issuer or "UNKNOWN", system or "UNKNOWN",
            "DESTROY", e.id, e.t, e.on and e.on,
            nil, nil, nil,
            reason or "unspecified",
            extra and (string.format("amount=%d", amount)) or string.format("amount=%d", amount))
    end
    return ok and type(res) == "number"
end

-- Miner officer types: war/chrono miners only. SMIN (slave miner)
-- excluded: its deploy-grind is its own minigame, don't touch it.
local MINER_TYPES = { HARV = true, CMIN = true }
local MINER_EVERY = 300 -- per-miner re-kick cooldown (frames)
-- Anchor within this distance of an own building = docked, not mining.
local MINER_BASE_R2 = 9
-- Within 2 cells of the kick destination = arrived, hold (no churn).
local MINER_REACHED_R2 = 4
-- minerState lives with the other officer state above officerReset
-- (upvalue rule); constants can stay here (runtime reads only).

-- ---------------------------------------------------------------------------
-- Diagnostics (attribution only — never decisions, never re-orders).
-- Every SmartAI-issued order logs frame + site + unit identity so a later
-- log reader can answer "SmartAI ordered X to unit Y at frame Z. What did
-- the game report afterward?" print() goes to LuaAPI.log only (no HUD).
-- Namespace [SMARTAI]* is ours; target_reselect uses [TARGET]/[M14.1].
-- ---------------------------------------------------------------------------

local SMARTAI_CENSUS_EVERY = 1800 -- AI-house roster dump cadence (frames)

local function dlog(tag, frame, body)
    print(string.format("[SMARTAI][%s] frame=%d %s", tostring(tag),
        math.floor(frame or 0), tostring(body)))
end

-- KEEP/QUIET/CUT (2026-10-03, user-approved): steady-state diagnostic
-- chatter collapsed to on-change + heartbeat. diagLast[key] tracks the
-- last EMITTED payload and the opportunity count. Emits when the
-- compared payload differs, or every DIAG_HEARTBEAT-th opportunity
-- (liveness proof: "running with nothing new" vs "not running" — the
-- RALLYDIAG/RECOVERY heartbeat lesson). `cmp` optionally separates the
-- compared signal from the emitted line (GROUP decision|reason without
-- the wiggling ratio; C4DIAG funnel without the position-carrying
-- samples). `force` keeps true events always visible (a RECOVERY that
-- claimed or ordered is news even when shaped like the last one).
-- Cleared on match restart next to guardReset/officerReset.
local diagLast = {}
local DIAG_HEARTBEAT = 3
local function dlogChange(tag, frame, key, msg, cmp, force)
    local k = tostring(tag) .. "|" .. tostring(key)
    local slot = diagLast[k]
    local sig = cmp or msg
    if slot == nil then
        diagLast[k] = { payload = sig, n = 1 }
        dlog(tag, frame, msg)
        return true
    end
    slot.n = slot.n + 1
    if force or sig ~= slot.payload or slot.n % DIAG_HEARTBEAT == 0 then
        slot.payload = sig
        dlog(tag, frame, msg)
        return true
    end
    return false
end

-- Log a structured command event at the point of issuance.
-- dlog is defined above, so this closure resolves the intended local logger.
SmartAI.logCommand = function(issuer, system, command_type,
    unit_id, unit_type, house, target_id, target_type, target_owner,
    reason, extra)
    local houseKey = tostring(house or "-")
    local ok = pcall(function()
        SmartAI.prov.counter = SmartAI.prov.counter + 1
        local body = string.format(
            "command_id=%d issuer=%s system=%s command_type=%s "
            .. "unit_id=%s unit_type=%s house=%s "
            .. "target_id=%s target_type=%s target_owner=%s "
            .. "reason=%s%s",
            SmartAI.prov.counter, tostring(issuer), tostring(system),
            tostring(command_type),
            tostring(unit_id or "-"), tostring(unit_type or "-"),
            houseKey,
            tostring(target_id or "-"), tostring(target_type or "-"),
            tostring(target_owner or "-"), tostring(reason),
            extra and (" " .. tostring(extra)) or "")
        dlog("COMMAND", SmartAI.prov.frame, body)
    end)
    if not ok then
        SmartAI.prov.logging_errors = (SmartAI.prov.logging_errors or 0) + 1
        local stats = SmartAI.prov.byHouse[houseKey] or
            { commands_issued = 0, logging_errors = 0 }
        stats.logging_errors = stats.logging_errors + 1
        SmartAI.prov.byHouse[houseKey] = stats
        return false
    end

    local stats = SmartAI.prov.byHouse[houseKey] or
        { commands_issued = 0, logging_errors = 0 }
    stats.commands_issued = stats.commands_issued + 1
    SmartAI.prov.byHouse[houseKey] = stats

    -- Track for outcome correlation (per unit, most recent command wins).
    if unit_id and type(unit_id) == "number" then
        SmartAI.prov.log[unit_id] = {
            frame = SmartAI.prov.frame, command_id = SmartAI.prov.counter,
            command_type = command_type, target_id = target_id,
            target_type = target_type, reason = reason,
        }
    end
    return true
end

-- Target evaluation logging. dlog is lexically visible here.
SmartAI.logTargetEval = function(evaluator_id, evaluator_type, evaluator_owner,
    target_id, target_type, target_owner, accepted, reason, score, extra)
    local ok = pcall(function()
        local body = string.format(
            "eval_id=%s eval_type=%s eval_owner=%s "
            .. "target_id=%s target_type=%s target_owner=%s "
            .. "accepted=%s reason=%s score=%s%s",
            tostring(evaluator_id), tostring(evaluator_type),
            tostring(evaluator_owner or "-"),
            tostring(target_id or "-"), tostring(target_type or "-"),
            tostring(target_owner or "-"),
            tostring(accepted), tostring(reason),
            tostring(score or "-"),
            extra and (" " .. tostring(extra)) or "")
        dlog("TARGET_EVAL", SmartAI.prov.frame, body)
    end)
    if not ok then
        SmartAI.prov.logging_errors = (SmartAI.prov.logging_errors or 0) + 1
    end
    return ok
end


-- ---------------------------------------------------------------------------
-- Audit heartbeat (observability): per-house subsystem coverage, change-gated
-- via dlogChange so a steady tick does not spam LuaAPI.log. Called from
-- SmartAI.Update; before this definition the call was nil and aborted the tick.
-- ---------------------------------------------------------------------------
SmartAI.logAuditHeartbeat = function(house, commander_status, officer_status,
    target_evaluation_status, command_issuance_status, commands_issued,
    rejected_decisions, logging_errors)
    local h = tostring(house or "-")
    local body = string.format(
        "house=%s commander_status=%s officer_status=%s " ..
        "target_evaluation_status=%s command_issuance_status=%s " ..
        "commands_issued=%s rejected_decisions=%s logging_errors=%s",
        h, tostring(commander_status or "-"), tostring(officer_status or "-"),
        tostring(target_evaluation_status or "-"),
        tostring(command_issuance_status or "-"),
        tostring(commands_issued), tostring(rejected_decisions),
        tostring(logging_errors))
    return dlogChange("AUDIT_HEARTBEAT", SmartAI.prov.frame, h, body)
end

-- Keep SmartAI.Update's local-variable count unchanged.
SmartAI.logHouseAuditHeartbeat = function(aiHouse)
    local house = tostring(aiHouse and aiHouse:GetName() or "-")
    local stats = SmartAI.prov.byHouse[house] or {}
    return SmartAI.logAuditHeartbeat(
        house, "complete", "complete", "event_logged", "instrumented",
        stats.commands_issued or 0, "not_instrumented",
        SmartAI.prov.logging_errors or 0)
end

SmartAI.resetProvenance = function()
    SmartAI.prov.counter = 0
    SmartAI.prov.log = {}
    SmartAI.prov.byHouse = {}
    SmartAI.prov.logging_errors = 0
end

local function liveId(u)
    local ok, uid = pcall(u.GetId, u)
    if ok and type(uid) == "number" then return uid end
    return nil
end

-- Immediate read-back of the engine's actual target (existing GetTarget
-- binding; read-only). Returns nil when the engine reports no target.
local function readbackTargetId(u)
    local okT, tgt = pcall(u.GetTarget, u)
    if not okT or tgt == nil then return nil end
    return liveId(tgt)
end

local function unitDesc(e)
    return string.format("unit=%s type=%s kind=%s owner=%s",
        tostring(e.id), tostring(e.t), tostring(e.k), tostring(e.on))
end

local function diagOrder(frame, site, e, order, extra)
    dlog("ORDER", frame, string.format("site=%s %s order=%s%s",
        tostring(site), unitDesc(e), tostring(order),
        extra and (" " .. tostring(extra)) or ""))
end

-- Read-only audit: did SmartAI itself order `did` after `sinceFrame`?
-- Scans SmartAI's own order memories (diagnostics only; garrison has no
-- per-unit record and is therefore NOT covered — documented gap).
-- Returns "none" or a comma list like "RALLY@1230".
local function lastSmartAIOrder(did, sinceFrame)
    local hits = {}
    local gs = guardState[did]
    if gs and gs.threatened and (gs.orderedFrame or 0) > (sinceFrame or 0) then
        hits[#hits + 1] = "GUARD_PULLBACK@" .. tostring(gs.orderedFrame)
    end
    for pid, st in pairs(escortState) do
        if st.guards then
            for _, gid in ipairs(st.guards) do
                if gid == did and (st.orderedFrame or 0) > (sinceFrame or 0) then
                    hits[#hits + 1] = "ESCORT@" .. tostring(st.orderedFrame)
                        .. "(principal " .. tostring(pid) .. ", approx)"
                    break
                end
            end
        end
    end
    local rs = recallState[did]
    if rs and (rs.orderedFrame or 0) > (sinceFrame or 0) then
        hits[#hits + 1] = "RECALL@" .. tostring(rs.orderedFrame)
    end
    local ev = radEvacState[did]
    if ev and (ev.orderedFrame or 0) > (sinceFrame or 0) then
        hits[#hits + 1] = "RADEVAC@" .. tostring(ev.orderedFrame)
    end
    local mn = minerState[did]
    if mn and (mn.orderedFrame or 0) > (sinceFrame or 0) then
        hits[#hits + 1] = "MINER@" .. tostring(mn.orderedFrame)
    end
    local rt = retargetState[did]
    if rt and (rt.orderedFrame or 0) > (sinceFrame or 0) then
        hits[#hits + 1] = "RETARGET@" .. tostring(rt.orderedFrame)
    end
    for _, rdst in pairs(raidState) do
        if rdst.members then
            for _, mid in ipairs(rdst.members) do
                if mid == did and (rdst.orderedFrame or 0) > (sinceFrame or 0) then
                    hits[#hits + 1] = "RAID_ATTACK@" .. tostring(rdst.orderedFrame)
                    break
                end
            end
        end
    end
    for _, rst in pairs(rallyState) do
        if rst.ids and rst.ids[did] and (rst.frame or 0) > (sinceFrame or 0) then
            hits[#hits + 1] = "RALLY@" .. tostring(rst.frame)
        end
    end
    if #hits == 0 then return "none" end
    return table.concat(hits, ",")
end

-- === C4 DETECTOR DIAGNOSTIC =============================================
-- DIAGNOSTIC ONLY. Changes no decision, issues no order, and leaves the real
-- detector's `if` chain byte-for-byte intact. It exists because live matches
-- logged ZERO DEFENSE_SEV / POINT_DEFENSE / MARCH_RECALL over 45 360 frames
-- while RALLY_BREACH proved own buildings were being damaged -- so the
-- detector's `intruders` table was empty against a real intrusion, and the
-- pipeline stage responsible was unknown.
--
-- c4diagScan MIRRORS the POINT DEFENSE predicate chain in the same
-- short-circuit order and attributes each unit to the FIRST failing
-- predicate, which is exactly what the `and` chain does. The mirror is
-- guarded, not trusted: the harness asserts distPass == #intruders, so any
-- future divergence between mirror and detector fails a test instead of
-- silently producing wrong diagnostics.
--
-- Rejection reasons: OWN (no owner / own house), ALLIED, NEUTRAL, CIVIL,
-- KIND (not in DEFENSE_KINDS), NOPOS (no position), DISTANCE (passed every
-- filter but no own building within intruderR).
local C4DIAG_SAMPLE_CAP = 6 -- bounded per census interval; never per frame
local C4DIAG_MAX_COORD_SAMPLES = 3

-- Preset table -> its PRESETS key (identity match; tables are distinct).
-- Used only by the C4PRESET diagnostic so a log can name the preset instead
-- of dumping the table. Unknown => "?".
local function c4PresetName(t)
    if not t then return "nil" end
    for k, v in pairs(PRESETS) do
        if v == t then return tostring(k) end
    end
    return "?"
end

-- Raw engine difficulty string for diagnostics. Mirrors the read paramsFor
-- performs, but reports the value instead of acting on it: a failed read
-- returns nil there (and falls back to DIFFICULTY_FALLBACK), which is
-- indistinguishable from a real level unless it is logged. "unbound" and
-- "error" are reported distinctly so both are visible in a log.
local function c4RawDifficulty(house)
    if type(house.GetAIDifficulty) ~= "function" then return "unbound" end
    local ok, level = pcall(house.GetAIDifficulty, house)
    if not ok then return "error" end
    if level == nil then return "nil" end
    return tostring(level)
end

-- M3 stance: per-house character for the raid layer. Returns an
-- ADJUSTED COPY (never mutates the shared preset) + the stance name
-- (nil for easy: characterless by design). Rusher raids bigger, more
-- often, farther; turtle raids smaller, rarer, closer. Announced once
-- per house per match — the readable-intent moment. Hard houses present
-- as Mastermind (the only CnCNet-lobby name we own is the one we say).
local function stanceParams(aiHouse, P, aiName, frame)
    if not P.raid then return P, nil end
    local st = stanceCache[aiHouse]
    if not st then
        -- Hard difficulty always rushes (Mastermind doctrine); everyone
        -- else alternates from the deterministic first-seen order.
        if c4RawDifficulty(aiHouse) == "hard" then
            st = "rusher"
        else
            stanceCount = stanceCount + 1
            st = (stanceCount % 2 == 1) and "rusher" or "turtle"
        end
        stanceCache[aiHouse] = st
    end
    if not stanceAnnounced[aiHouse] then
        stanceAnnounced[aiHouse] = true
        local title = "AI Commander"
        if c4RawDifficulty(aiHouse) == "hard" then title = "Mastermind" end
        local diff = c4RawDifficulty(aiHouse)
        dlog("STANCE", frame, string.format("house=%s stance=%s difficulty=%s",
            tostring(aiName), st, diff))
        local alert = string.format("[%s - %s] adopts %s stance (%s).",
            title, tostring(aiName), string.upper(st), diff)
        Engine.PrintMessage(alert)
        print("[LuaAPI] " .. alert)
    end
    local Q = {}
    for k, v in pairs(P) do Q[k] = v end
    if st == "rusher" then
        Q.raidN = (P.raidN or 4) + 1
        Q.raidEvery = math.floor((P.raidEvery or 600) * 0.66)
        Q.raidQuiet = math.floor((P.raidQuiet or 600) * 0.66)
        Q.raidRange = (P.raidRange or 60) + 10
    else
        Q.raidN = (P.raidN or 4) - 1
        Q.raidEvery = math.floor((P.raidEvery or 600) * 1.5)
        Q.raidQuiet = math.floor((P.raidQuiet or 600) * 1.5)
        Q.raidRange = math.max(30, (P.raidRange or 60) - 10)
    end
    return Q, st
end

-- Raid group size: stanced base +/- evidence level, floored at raidMin
-- (tiny groups never form) and capped at base+2 (no doomstacks).
local function raidSizeFor(aiHouse, P)
    local lv = raidLevel[aiHouse] or 0
    local base = P.raidN or 4
    local n = base + lv
    if n < (P.raidMin or 3) then n = P.raidMin or 3 end
    if n > base + 2 then n = base + 2 end
    return n
end

local function c4diagScan(units, home, aiHouse, P, allied)
    local r2 = P.intruderR * P.intruderR
    local d = {
        cands = #units, home = #home, R = P.intruderR, R2 = r2,
        own = 0, allied = 0, neutral = 0, civil = 0,
        kindIn = 0, kind = 0, nopos = 0,
        pass = 0, distRej = 0, distPass = 0,
        intr = 0, kindsRej = {}, samples = {}, coordSamples = 0,
        -- Act-side candidate selection (DIAGNOSTIC ONLY). The funnel above
        -- answers "did the base see the intruder?"; this one answers "given
        -- that it did, on which gate did Act lose the candidate?". Filled by
        -- the read-only pass in the Tier-1 block and printed on the same
        -- census line, so it adds no per-frame spam.
        --
        -- claimIds/orderIds de-duplicate a unit that Act retries against
        -- several intruders within one pass: a unit is counted once per
        -- outcome, never once per (unit, intruder) pair.
        act = {
            ran = false, ownTotal = 0, ownIdle = 0, ownOfficerHeld = 0,
            ownKindRejected = 0, ownNonGround = 0, ownNoPos = 0,
            ownEligible = 0, inAssignR = 0,
            claimDenied = 0, orderFail = 0,
            actKindRej = {}, actNonGroundRej = {},
            claimIds = {}, orderIds = {},
        },
    }
    for _, u in ipairs(units) do
        local why
        if not (u.oh and u.oh ~= aiHouse) then
            why = "OWN"
        elseif allied(aiHouse, u.oh) then
            why = "ALLIED"
        elseif util.is_neutral_house(u.oh) then
            why = "NEUTRAL"
        elseif util.CIVIL_TYPES[u.t] then
            why = "CIVIL"
        elseif not DEFENSE_KINDS[u.k] then
            why = "KIND"
        elseif not u.hasPos then
            why = "NOPOS"
        end
        if why then
            if why == "OWN" then
                d.own = d.own + 1
            elseif why == "ALLIED" then
                d.allied = d.allied + 1
            elseif why == "NEUTRAL" then
                d.neutral = d.neutral + 1
            elseif why == "CIVIL" then
                d.civil = d.civil + 1
            elseif why == "KIND" then
                d.kind = d.kind + 1
                local kk = tostring(u.k)
                d.kindsRej[kk] = (d.kindsRej[kk] or 0) + 1
            else
                d.nopos = d.nopos + 1
            end
            if why ~= "OWN" and #d.samples < C4DIAG_SAMPLE_CAP then
                d.samples[#d.samples + 1] = string.format(
                    "id=%s k=%s o=%s t=%s why=%s",
                    tostring(u.id), tostring(u.k), tostring(u.on), tostring(u.t), why)
            end
        else
            d.pass = d.pass + 1
            local bestB, bestD2
            for _, b in ipairs(home) do
                local dd = dist2(u.x, u.y, b.x, b.y)
                if not bestD2 or dd < bestD2 then bestB, bestD2 = b, dd end
            end
            if bestD2 and bestD2 <= r2 then
                d.distPass = d.distPass + 1
            else
                d.distRej = d.distRej + 1
                if d.coordSamples < C4DIAG_MAX_COORD_SAMPLES then
                    d.coordSamples = d.coordSamples + 1
                    d.samples[#d.samples + 1] = string.format(
                        "id=%s k=%s o=%s t=%s why=DISTANCE cand=(%s,%s) bld=%s bpos=(%s,%s) d2=%s R2=%s",
                        tostring(u.id), tostring(u.k), tostring(u.on), tostring(u.t),
                        tostring(u.x), tostring(u.y),
                        bestB and tostring(bestB.id) or "-",
                        bestB and tostring(bestB.x) or "-",
                        bestB and tostring(bestB.y) or "-",
                        tostring(bestD2 or -1), tostring(r2))
                end
            end
        end
    end
    d.kindIn = d.cands - d.own - d.allied - d.neutral - d.civil
    if d.home == 0 then
        d.note = "NO_HOME_BUILDINGS"
    elseif d.pass == 0 then
        d.note = "FILTER_REJECT_ALL"
    elseif d.distPass == 0 then
        d.note = "DISTANCE_REJECT_ALL"
    elseif d.distRej == 0 then
        d.note = "INTRUDERS_OK"
    else
        d.note = "MIXED"
    end
    return d
end

local function c4diagLine(frame, aiName, d)
    local kr = {}
    for k, n in pairs(d.kindsRej) do kr[#kr + 1] = tostring(k) .. "=" .. tostring(n) end
    table.sort(kr)
    -- Act-side rejection histograms. HARV/MCV/ART land in actNonGroundRej and
    -- NOT in actKindRej, because that is where the production predicate puts
    -- them: a harvester passes `kindOk` (it is k=="unit") and is excluded by
    -- the separate type gates. Merging the two buckets would misreport which
    -- gate actually rejected the unit.
    local akr = {}
    for k, n in pairs(d.act.actKindRej) do
        akr[#akr + 1] = tostring(k) .. "=" .. tostring(n)
    end
    table.sort(akr)
    local agr = {}
    for k, n in pairs(d.act.actNonGroundRej) do
        agr[#agr + 1] = tostring(k) .. "=" .. tostring(n)
    end
    table.sort(agr)
    -- Single-token verdict so a log reader does not have to re-derive the
    -- funnel. Ordered from the earliest possible blocker to the latest, and
    -- it deliberately distinguishes "Act never got a candidate" from
    -- "Act got one and was refused", which is the whole point of the pass.
    local a = d.act
    local actNote
    if not a.ran then
        actNote = "ACT_NO_INTRUDERS"
    elseif a.ownTotal == 0 then
        actNote = "ACT_NO_OWN_UNITS"
    elseif a.ownIdle == 0 then
        actNote = "ACT_NO_IDLE"
    elseif a.ownIdle > 0 and a.ownOfficerHeld >= a.ownIdle
        and a.ownKindRejected == 0 and a.ownNonGround == 0 then
        -- Only report ALL_OFFICER_HELD when every idle candidate was
        -- actually held by an Officer. A single held unit plus 22 units
        -- rejected by kind is a mixed/eligibility failure, not an
        -- Officer-ownership failure.
        actNote = "ACT_ALL_OFFICER_HELD"
    elseif a.ownEligible == 0 and (a.ownKindRejected > 0
        or a.ownNonGround > 0) then
        actNote = "ACT_CANDIDATES_REJECTED_BY_FILTER"
    elseif a.ownEligible == 0 then
        actNote = "ACT_NO_ELIGIBLE"
    elseif a.inAssignR == 0 then
        actNote = "ACT_NONE_IN_RADIUS"
    elseif a.claimDenied > 0 then
        actNote = "ACT_CLAIM_DENIED"
    elseif a.orderFail > 0 then
        actNote = "ACT_ORDER_FAIL"
    else
        actNote = "ACT_ATTEMPTED"
    end
    return string.format(
        "house=%s home=%d units=%d R=%s R2=%s cands=%d "
            .. "own=%d allied=%d neutral=%d civil=%d kindIn=%d kind=%d nopos=%d "
            .. "pass=%d distRej=%d distPass=%d intr=%d kindsRej={%s} note=%s "
            .. "mismatch=%s "
            .. "ownTotal=%d ownIdle=%d ownOfficerHeld=%d ownKindRejected=%d "
            .. "ownNonGround=%d ownNoPos=%d ownEligible=%d inAssignR=%d "
            .. "claimDenied=%d orderFail=%d actKindRej={%s} actNonGroundRej={%s} "
            .. "actRan=%s actNote=%s",
        tostring(aiName), d.home, d.cands, tostring(d.R), tostring(d.R2), d.cands,
        d.own, d.allied, d.neutral, d.civil, d.kindIn, d.kind, d.nopos,
        d.pass, d.distRej, d.distPass, d.intr, table.concat(kr, ","),
        tostring(d.note), tostring(d.distPass ~= d.intr),
        a.ownTotal, a.ownIdle, a.ownOfficerHeld, a.ownKindRejected,
        a.ownNonGround, a.ownNoPos, a.ownEligible, a.inAssignR,
        a.claimDenied, a.orderFail, table.concat(akr, ","),
        table.concat(agr, ","), tostring(a.ran), actNote)
end

-- ---------------------------------------------------------------------------
-- M2-T1 Threat Assessment & Opponent Modeling (read-only first iteration).
--
-- Purpose:
--   * observe hostile mobile composition around each AI house's buildings;
--   * track composition/count/distance changes between scans;
--   * compare a heuristic local force estimate with nearby friendly forces;
--   * publish a recommendation, but NEVER issue orders or produce units.
--
-- IMPORTANT:
--   cost is only a rough proxy, NOT combat power. Exact roles and weights
--   must be populated from verified INI weapon/armor data. Unknown types stay
--   explicitly unknown; no AM2/GHOST assumptions are embedded here.
--   Production requests are represented as data only. The current SmartAI
--   gate says AI.QueueUnit is not cleared for live use. Do not call it here.
-- ---------------------------------------------------------------------------
SmartAI.THREAT_ASSESSMENT = {
    enabled = true,
    radius = 40,             -- map cells from any owned building
    ownForceRadius = 35,     -- map cells from any owned building
    highScore = 12.0,        -- heuristic score, not DPS/combat power
    criticalScore = 22.0,
    buildupDelta = 3,
    memory = {},             -- keyed by house userdata; match-local
    lastResults = {},
}

-- Optional, verified per-type data. Keep empty until checked against the
-- active rules/INI. Example schema only:
-- SmartAI.THREAT_UNIT_PROFILES.AM2 = {
--     role = "heavy_armor", threat_weight = 3.0,
-- }
-- SmartAI.THREAT_UNIT_PROFILES.GHOST = {
--     role = "special_infantry", threat_weight = 2.0,
-- }
SmartAI.THREAT_UNIT_PROFILES = {}

-- Future counter doctrine. Values are deliberately empty: do not guess a
-- counter unit or production count before validating weapon/armor matchups.
-- Example schema: heavy_armor = { unit_type = "<verified type>", count = 5 }
SmartAI.THREAT_COUNTER_DOCTRINE = {}

SmartAI.threatRole = function(e)
    local profile = SmartAI.THREAT_UNIT_PROFILES[e.t]
    if profile and type(profile.role) == "string" then
        return profile.role
    end
    if e.k == "aircraft" then return "air" end
    if e.k == "infantry" then return "infantry" end
    if e.k == "unit" then return "vehicle_unclassified" end
    return "unknown"
end

SmartAI.threatWeight = function(e)
    local profile = SmartAI.THREAT_UNIT_PROFILES[e.t]
    if profile and type(profile.threat_weight) == "number"
        and profile.threat_weight > 0 then
        return profile.threat_weight
    end
    -- Conservative observation weight only. Cost is not a substitute for
    -- weapon effectiveness, armor interaction, range, or veterancy.
    local weight = 1.0 + ((tonumber(e.cost) or 0) / 5000.0)
    if e.k == "aircraft" then weight = weight * 1.25 end
    if e.k == "infantry" then weight = weight * 0.75 end
    return weight
end

SmartAI.nearestOwnedBuildingDistance2 = function(e, house, buildings)
    local best = nil
    for _, b in ipairs(buildings) do
        if b.oh == house and b.hasPos then
            local dx = e.x - b.x
            local dy = e.y - b.y
            local d2 = dx * dx + dy * dy
            if best == nil or d2 < best then best = d2 end
        end
    end
    return best
end

SmartAI.updateThreatAssessment = function(frame, aiHouses, units, buildings, allied)
    local config = SmartAI.THREAT_ASSESSMENT
    if not config.enabled then return end

    local radius2 = config.radius * config.radius
    local ownRadius2 = config.ownForceRadius * config.ownForceRadius
    local results = {}

    for _, aiHouse in ipairs(aiHouses) do
        local force = {
            total = 0, score = 0, types = {}, roles = {},
            nearest = nil, own_total = 0, own_score = 0,
            close_total = 0,
        }
        local hasBase = false
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.hasPos then
                hasBase = true
                break
            end
        end

        if hasBase then
            for _, e in ipairs(units) do
                if e.hasPos and e.oh then
                    local d2 = SmartAI.nearestOwnedBuildingDistance2(
                        e, aiHouse, buildings)
                    if d2 ~= nil then
                        if e.oh == aiHouse then
                            if d2 <= ownRadius2 and DEFENSE_KINDS[e.k] then
                                force.own_total = force.own_total + 1
                                force.own_score = force.own_score
                                    + SmartAI.threatWeight(e)
                            end
                        elseif not allied(aiHouse, e.oh)
                            and not util.is_neutral_house(e.oh)
                            and DEFENSE_KINDS[e.k]
                            and d2 <= radius2 then
                            force.total = force.total + 1
                            force.score = force.score + SmartAI.threatWeight(e)
                            force.types[e.t] = (force.types[e.t] or 0) + 1
                            local role = SmartAI.threatRole(e)
                            force.roles[role] = (force.roles[role] or 0) + 1
                            local distance = math.sqrt(d2)
                            if force.nearest == nil or distance < force.nearest then
                                force.nearest = distance
                            end
                            if d2 <= (config.radius * 0.5) ^ 2 then
                                force.close_total = force.close_total + 1
                            end
                        end
                    end
                end
            end

            local previous = config.memory[aiHouse]
            local growth = 0
            local typeGrowth = {}
            local distanceClosing = false
            if previous then
                growth = force.total - previous.total
                for typeName, count in pairs(force.types) do
                    local delta = count - ((previous.types and previous.types[typeName]) or 0)
                    if delta ~= 0 then typeGrowth[typeName] = delta end
                end
                if force.nearest and previous.nearest
                    and force.nearest < previous.nearest then
                    distanceClosing = true
                end
            end

            local level = "LOW"
            if force.total == 0 then
                level = "NONE"
            elseif force.score >= config.criticalScore then
                level = "CRITICAL"
            elseif force.score >= config.highScore
                or growth >= config.buildupDelta
                or force.close_total >= 5 then
                level = "HIGH"
            elseif growth > 0 or force.total >= 3 then
                level = "MODERATE"
            end

            local ratio = nil
            if force.score > 0 then
                ratio = force.own_score / force.score
            end

            local recommendation = "MONITOR"
            if level == "CRITICAL" or level == "HIGH" then
                if ratio and ratio < 0.75 then
                    recommendation = "DEFEND_AND_CONCENTRATE"
                else
                    recommendation = "HOLD_DEFENSIVE_POSTURE"
                end
            elseif level == "MODERATE" and distanceClosing then
                recommendation = "PREPARE_DEFENSE"
            end

            local productionCandidates = {}
            if recommendation == "DEFEND_AND_CONCENTRATE" then
                for role, enemyCount in pairs(force.roles) do
                    local doctrine = SmartAI.THREAT_COUNTER_DOCTRINE[role]
                    if doctrine and type(doctrine.unit_type) == "string"
                        and type(doctrine.count) == "number"
                        and doctrine.count > 0 then
                        productionCandidates[#productionCandidates + 1] = {
                            role = role,
                            enemy_count = enemyCount,
                            unit_type = doctrine.unit_type,
                            requested_count = math.floor(doctrine.count),
                            reason = "LOCAL_FORCE_DEFICIT",
                            status = "CANDIDATE_ONLY_NATIVE_QUEUE_GATE",
                        }
                    end
                end
            end

            local result = {
                frame = frame,
                level = level,
                enemy_total = force.total,
                enemy_score = force.score,
                enemy_types = force.types,
                enemy_roles = force.roles,
                own_nearby_total = force.own_total,
                own_nearby_score = force.own_score,
                force_ratio = ratio,
                growth = growth,
                type_growth = typeGrowth,
                nearest_distance = force.nearest,
                close_total = force.close_total,
                distance_closing = distanceClosing,
                recommendation = recommendation,
                production_request_candidates = productionCandidates,
                confidence = previous and "OBSERVED_TREND" or "INITIAL_OBSERVATION",
                intent = (growth >= config.buildupDelta or distanceClosing)
                    and "POTENTIAL_BUILDUP" or "UNKNOWN",
            }
            results[aiHouse] = result

            local oldLevel = previous and previous.level or "UNSEEN"
            local signature = table.concat({
                level, tostring(force.total), tostring(math.floor(force.score * 10)),
                tostring(growth), tostring(force.close_total), recommendation,
            }, "|")
            dlogChange("THREAT_ASSESSMENT", frame,
                tostring(aiHouse:GetName()),
                string.format(
                    "house=%s level=%s enemy_total=%d enemy_score=%.1f " ..
                    "own_nearby=%d own_score=%.1f ratio=%s growth=%d " ..
                    "close=%d nearest=%s intent=%s confidence=%s " ..
                    "recommendation=%s previous_level=%s",
                    tostring(aiHouse:GetName()), level, force.total, force.score,
                    force.own_total, force.own_score,
                    ratio and string.format("%.2f", ratio) or "unknown",
                    growth, force.close_total,
                    force.nearest and string.format("%.1f", force.nearest) or "none",
                    result.intent, result.confidence, recommendation, oldLevel),
                signature)

            config.memory[aiHouse] = {
                total = force.total,
                score = force.score,
                types = force.types,
                nearest = force.nearest,
                level = level,
                frame = frame,
            }
        end
    end
    config.lastResults = results
    return results
end

-- Production-request boundary. This creates an auditable request object but
-- deliberately does NOT invoke AI.QueueUnit: the live gate in this source
-- has not been cleared. A native adapter must be implemented and runtime-
-- verified before this function can submit anything to Vanilla AI.
SmartAI.requestVanillaProduction = function(aiHouse, unitType, count, reason, priority)
    SmartAI.productionRequestCounter = (SmartAI.productionRequestCounter or 0) + 1
    local request = {
        request_id = SmartAI.productionRequestCounter,
        house = aiHouse,
        unit_type = unitType,
        count = math.max(1, math.floor(tonumber(count) or 1)),
        reason = tostring(reason or "unspecified"),
        priority = tonumber(priority) or 0,
        frame = SmartAI.prov.frame,
        status = "BLOCKED_NATIVE_QUEUE_GATE",
    }
    -- Opt-in native production (default off: preserves "command existing units
    -- only"). Try plausible API shapes; failures are logged, never fatal.
    if SmartAI.CAPTURE_BUILD_DEFENSES_NATIVE and aiHouse and unitType then
        local ok, res = false, nil
        ok, res = pcall(function()
            if type(aiHouse.Produce) == "function" then
                return aiHouse:Produce(unitType, request.count)
            elseif type(aiHouse.QueueUnit) == "function" then
                return aiHouse:QueueUnit(unitType, request.count)
            elseif type(aiHouse.QueueProduction) == "function" then
                return aiHouse:QueueProduction(unitType, request.count)
            elseif type(aiHouse.Build) == "function" then
                return aiHouse:Build(unitType, request.count)
            elseif Engine and type(Engine.QueueUnit) == "function" then
                return Engine.QueueUnit(aiHouse, unitType, request.count)
            end
            return nil
        end)
        if ok and res ~= nil and res ~= false then
            request.status = "QUEUED_NATIVE"
        elseif ok then
            request.status = "NATIVE_API_NO_EFFECT"
        else
            request.status = "NATIVE_API_ERROR"
            request.error = tostring(res)
        end
    end
    SmartAI.lastProductionRequest = request
    local ev = (request.status == "QUEUED_NATIVE") and "PRODUCTION_REQUEST_QUEUED"
        or "PRODUCTION_REQUEST_BLOCKED"
    dlog(ev, SmartAI.prov.frame, string.format(
        "request_id=%d house=%s unit_type=%s count=%d priority=%s reason=%s status=%s",
        request.request_id, tostring(aiHouse and aiHouse:GetName() or "-"),
        tostring(unitType), request.count, tostring(request.priority),
        request.reason, request.status))
    return request.status == "QUEUED_NATIVE", request.status, request
end

SmartAI.resetThreatAssessment = function()
    SmartAI.THREAT_ASSESSMENT.memory = {}
    SmartAI.THREAT_ASSESSMENT.lastResults = {}
    SmartAI.productionRequestCounter = 0
    SmartAI.lastProductionRequest = nil
end

-- CAPTURE-ASSET TRACKING: watch ownership of capturable high-value assets
-- so we can defend the ones we own and re-raid the ones we lost.
local function updateCaptureAssets(frame, aiHouses, buildings, buildingsById)
    local nowOwned = {}   -- house -> { [buildingId] = true }
    local seenIds = {}    -- buildingId -> true (any capture asset seen this tick)
    for _, b in ipairs(buildings) do
        if CAPTURE_ASSET_TYPES[b.t] and b.hasPos and b.oh then
            seenIds[b.id] = true
            for _, h in ipairs(aiHouses) do
                if b.oh == h then
                    if not nowOwned[h] then nowOwned[h] = {} end
                    nowOwned[h][b.id] = true
                    local hName = tostring(h:GetName())
                    if captureAssetOwner[b.id] ~= hName then
                        captureAssetOwner[b.id] = hName
                        captureBuildRequested[b.id] = nil -- fresh ownership cycle
                        local alert = string.format(
                            "[AI Commander - %s] Asset secured: %s#%d!",
                            hName, tostring(b.t), b.id)
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                    -- Request defensive building around secured assets (opt-in;
                    -- defaults to logged intent only). Cooldown per asset.
                    if not captureBuildRequested[b.id]
                        and frame - (captureDefLast[b.id] or -CAPTURE_BUILD_EVERY) >= 0 then
                        local btypes = captureDefenseBuildingTypes(h)
                        if btypes and btypes[1] then
                            captureBuildRequested[b.id] = true
                            SmartAI.requestVanillaProduction(h, btypes[1], 1,
                                "capture asset secured: " .. tostring(b.t), 1)
                        end
                    end
                    break
                end
            end
        end
    end
    -- Losses: previously owned by an AI house, no longer owned by it,
    -- and the building still exists (captured, not destroyed) -> recapture.
    for h, assets in pairs(ownedAssets) do
        for id in pairs(assets) do
            local still = nowOwned[h] and nowOwned[h][id]
            if not still then
                local b = buildingsById[id]
                if b and b.oh ~= h and not util.is_neutral_house(b.oh) then
                    if not lostAssets[h] then lostAssets[h] = {} end
                    lostAssets[h][id] = {
                        t = b.t, x = b.x, y = b.y, lostFrame = frame,
                    }
                    captureAssetOwner[id] = nil
                    captureBuildRequested[id] = nil -- allow re-request after recapture
                    captureDefLast[id] = nil
                    captureGuardLast[id] = nil
                    captureRecaptureDispatch[id] = 0 -- dispatch immediately on next scan
                    local alert = string.format(
                        "[AI Commander - %s] Asset lost: %s#%d — recapture raid ordered!",
                        tostring(h:GetName()), tostring(b.t), id)
                    Engine.PrintMessage(alert)
                    print("[LuaAPI] " .. alert)
                else
                    captureAssetOwner[id] = nil
                    captureBuildRequested[id] = nil
                    captureDefLast[id] = nil
                    captureGuardLast[id] = nil
                    captureRecaptureDispatch[id] = nil
                end
            end
        end
    end
    -- Prune destroyed assets from lostAssets.
    for h, assets in pairs(lostAssets) do
        for id in pairs(assets) do
            if not seenIds[id] then assets[id] = nil end
        end
    end
    ownedAssets = nowOwned
end

-- CAPTURE-ASSET DEFENSE: idle defenders intercept hostiles near owned
-- capturable assets (airport/oil derrick/...). Shares the DEFENSE claim
-- site and the defenseState end-of-tick win/loss resolution so a unit is
-- never double-ordered and a resolved contact feeds the adaptation ledger.
local function captureAssetDefense(frame, aiHouses, units, buildingsById,
                                   allied, claim)
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_capdef end
        local aiName = aiHouse:GetName()
        local assets = ownedAssets[aiHouse]
        if not assets then goto next_capdef end
        local assetList = {}
        for id, _ in pairs(assets) do
            local b = buildingsById[id]
            if b and b.oh == aiHouse and b.hasPos then
                assetList[#assetList + 1] = b
            end
        end
        if #assetList == 0 then goto next_capdef end
        -- Intruders near any owned asset.
        local assetIntruders = {}
        for _, u in ipairs(units) do
            if u.oh and u.oh ~= aiHouse and not allied(aiHouse, u.oh)
                and not util.is_neutral_house(u.oh)
                and not util.CIVIL_TYPES[u.t]
                and DEFENSE_KINDS[u.k] and u.hasPos then
                for _, a in ipairs(assetList) do
                    if dist2(u.x, u.y, a.x, a.y) <= CAPTURE_DEFENSE_R2 then
                        assetIntruders[#assetIntruders + 1] = u
                        break
                    end
                end
            end
        end
        if #assetIntruders == 0 then goto next_capdef end
        local function capIntruderRank(e)
            if SUICIDE_TYPES[e.t] then return -1 end
            if e.k == "unit" then return 0 end
            if e.k == "infantry" then return 1 end
            return 2
        end
        table.sort(assetIntruders, function(a, b)
            local ra, rb = capIntruderRank(a), capIntruderRank(b)
            if ra ~= rb then return ra < rb end
            if a.cost ~= b.cost then return a.cost > b.cost end
            return a.id < b.id
        end)
        local assignR2 = P.assignR * P.assignR
        local taken = {}
        for _, it in ipairs(assetIntruders) do
            -- Nearest asset to this intruder (for logging + per-asset cooldown).
            local nearAsset, nearD2 = nil, nil
            for _, a in ipairs(assetList) do
                local d2 = dist2(it.x, it.y, a.x, a.y)
                if d2 <= CAPTURE_DEFENSE_R2 and (not nearD2 or d2 < nearD2) then
                    nearAsset, nearD2 = a, d2
                end
            end
            if not nearAsset then goto next_intruder end
            -- Per-asset cooldown: don't re-dispatch defenders every tick.
            if frame - (captureDefLast[nearAsset.id] or 0) < CAPTURE_DEFENSE_EVERY then
                goto next_intruder
            end
            local assigned = 0
            -- Holders of this intruder keep the slot (no re-issue).
            for _, ds in pairs(defenseState) do
                if ds.house == aiHouse and ds.targetId == it.id
                    and frame - (ds.orderedFrame or 0) < P.defenseEvery then
                    assigned = assigned + 1
                end
            end
            for _, u in ipairs(units) do
                if assigned >= CAPTURE_DEFENSE_N then break end
                if u.oh == aiHouse and u.idle and u.k == "unit" and u.hasPos
                    and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                    and not ARTILLERY_TYPES[u.t] and not HERO_TYPES[u.t]
                    and not isOfficerAssigned(u.id) and not taken[u.id] then
                    local d2 = dist2(u.x, u.y, it.x, it.y)
                    if d2 <= assignR2 then
                        if claim(u.id, "DEFENSE")
                            and orderAttack(u, it.u, "OFFICER", "CAPTURE_DEFENSE",
                                "asset defense",
                                string.format("asset=%s#%d intruder=%s type=%s",
                                    tostring(nearAsset.t), nearAsset.id,
                                    tostring(it.id), tostring(it.t))) then
                            defenseState[u.id] = {
                                targetId = it.id, orderedFrame = frame,
                                house = aiHouse,
                            }
                            taken[u.id] = true
                            assigned = assigned + 1
                            captureDefLast[nearAsset.id] = frame
                            diagOrder(frame, "CAPTURE_DEFENSE", u, "Attack",
                                string.format("asset=%s#%d intruder=%s",
                                    tostring(nearAsset.t), nearAsset.id,
                                    tostring(it.id)))
                            local actual = readbackTargetId(u.u)
                            dlog("READBACK", frame, string.format(
                                "unit=%s expected_target=%s actual_target=%s match=%s",
                                tostring(u.id), tostring(it.id), tostring(actual),
                                tostring(actual == it.id)))
                        end
                    end
                end
            end
            if assigned > 0 then
                local alert = string.format(
                    "[AI Commander - %s] Asset defense: %d defender(s) on %s#%d vs %s#%d!",
                    tostring(aiName), assigned,
                    tostring(nearAsset.t), nearAsset.id,
                    tostring(it.t), it.id)
                Engine.PrintMessage(alert)
                print("[LuaAPI] " .. alert)
                -- Request a defensive building around the threatened asset.
                -- Default: logged intent only (core principle). Set
                -- CAPTURE_BUILD_DEFENSES_NATIVE=true to attempt native production.
                if not captureBuildRequested[nearAsset.id] then
                    captureBuildRequested[nearAsset.id] = true
                    local btypes = captureDefenseBuildingTypes(aiHouse)
                    SmartAI.requestVanillaProduction(aiHouse,
                        (btypes and btypes[1]) or "GAPILL", 1,
                        "capture asset defense: " .. tostring(nearAsset.t), 1)
                end
            end
            ::next_intruder::
        end
        ::next_capdef::
    end
end

-- Proactive guards: keep a few defenders near owned capture assets even when
-- no threat is present. Respects claims and officer assignments.
local function captureAssetGuard(frame, aiHouses, units, buildingsById, claim)
    for _, aiHouse in ipairs(aiHouses) do
        if surrendered[aiHouse] then goto next_capguard end
        local P = paramsFor(aiHouse)
        local assets = ownedAssets[aiHouse]
        if not assets then goto next_capguard end
        local aiName = aiHouse:GetName()
        for id in pairs(assets) do
            local b = buildingsById[id]
            if not b or b.oh ~= aiHouse or not b.hasPos then goto next_asset end
            if frame - (captureGuardLast[id] or 0) < CAPTURE_GUARD_EVERY then
                goto next_asset
            end
            -- Count defenders already close; skip if enough.
            local near = 0
            for _, u in ipairs(units) do
                if u.oh == aiHouse and (u.k == "unit" or u.k == "infantry")
                    and u.hasPos and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                    and not isEngineerType(u.t) then
                    if dist2(u.x, u.y, b.x, b.y) <= CAPTURE_GUARD_R2 then
                        near = near + 1
                    end
                end
            end
            if near >= CAPTURE_GUARD_N then goto next_asset end
            local assigned = 0
            local assignR2 = P.assignR * P.assignR
            for _, u in ipairs(units) do
                if assigned + near >= CAPTURE_GUARD_N then break end
                if u.oh == aiHouse and u.idle and (u.k == "unit" or u.k == "infantry")
                    and u.hasPos and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                    and not ARTILLERY_TYPES[u.t] and not HERO_TYPES[u.t]
                    and not isEngineerType(u.t)
                    and not isOfficerAssigned(u.id) then
                    local d2 = dist2(u.x, u.y, b.x, b.y)
                    if d2 <= assignR2 and d2 > CAPTURE_GUARD_R2 then
                        if claim(u.id, "DEFENSE")
                            and orderMove(u, b.x, b.y, "OFFICER", "CAPTURE_GUARD",
                                "proactive asset guard",
                                string.format("asset=%s#%d", tostring(b.t), id)) then
                            assigned = assigned + 1
                            captureGuardLast[id] = frame
                            dlog("CAPTURE_GUARD", frame, string.format(
                                "house=%s unit=%s asset=%s#%d",
                                tostring(aiName), tostring(u.id), tostring(b.t), id))
                        end
                    end
                end
            end
            ::next_asset::
        end
        ::next_capguard::
    end
end

-- Engineer recapture: send idle engineers to capture assets this house lost.
-- Repeats on cooldown until the asset is recaptured or destroyed.
local function captureAssetRecapture(frame, aiHouses, units, buildingsById, claim)
    for _, aiHouse in ipairs(aiHouses) do
        if surrendered[aiHouse] then goto next_recap end
        local lost = lostAssets[aiHouse]
        if not lost then goto next_recap end
        local aiName = aiHouse:GetName()
        for id, info in pairs(lost) do
            local b = buildingsById[id]
            -- Lost record is pruned when destroyed; if owner is us, drop it.
            if not b or b.oh == aiHouse then
                lost[id] = nil
                goto next_lost
            end
            if not isCaptureAssetType(b.t) then goto next_lost end
            if frame - (captureRecaptureDispatch[id] or 0) < CAPTURE_RECAPTURE_ENGINEER_EVERY then
                goto next_lost
            end
            -- Find an idle engineer (prefer closest).
            local bestEng, bestD2 = nil, nil
            for _, u in ipairs(units) do
                if u.oh == aiHouse and u.k == "infantry" and u.idle
                    and isEngineerType(u.t) and u.hasPos
                    and not isOfficerAssigned(u.id) then
                    local d2 = dist2(u.x, u.y, b.x, b.y)
                    if not bestD2 or d2 < bestD2 then
                        bestEng, bestD2 = u, d2
                    end
                end
            end
            if bestEng and claim(bestEng.id, "RAID") then
                if orderAttack(bestEng, b.u, "OFFICER", "CAPTURE_RECAPTURE",
                    "recapture lost asset",
                    string.format("asset=%s#%d owner=%s", tostring(b.t), id,
                        tostring(info and info.t or b.t))) then
                    captureRecaptureDispatch[id] = frame
                    local alert = string.format(
                        "[AI Commander - %s] Recapture: engineer %d sent to %s#%d!",
                        tostring(aiName), bestEng.id, tostring(b.t), id)
                    Engine.PrintMessage(alert)
                    print("[LuaAPI] " .. alert)
                    dlog("CAPTURE_RECAPTURE", frame, string.format(
                        "house=%s engineer=%s asset=%s#%d",
                        tostring(aiName), tostring(bestEng.id), tostring(b.t), id))
                end
            end
            ::next_lost::
        end
        ::next_recap::
    end
end

function SmartAI.Update(frame)
    SmartAI.prov.frame = frame -- for command provenance logging
    local P = params()
    -- Match restart: frame counter went backwards (same pattern as
    -- Command Authority). Resets both the legacy scan gate and the
    -- capture-guard state so a new match starts clean.
    if frame < lastScanFrame then lastScanFrame = 0 end
    if frame < guardLastFrame then
        guardReset()
        officerReset()
        diagLast = {}
        SmartAI.resetProvenance()
        SmartAI.resetThreatAssessment()
    end
    guardLastFrame = frame

    if frame - lastScanFrame < tickScanEvery() then return end
    lastScanFrame = frame
    scanCounter = (scanCounter or 0) + 1

    local humanPlayer = House.GetPlayer()
    if not humanPlayer then return end

    -- One snapshot for the whole tick.
    local units, buildings = {}, {}
    do
        local okU, ul = pcall(World.GetUnits)
        if okU and type(ul) == "table" then
            for _, u in ipairs(ul) do
                local e = snapOf(u)
                if e then units[#units + 1] = e end
            end
        end
        local okB, bl = pcall(World.GetBuildings)
        if okB and type(bl) == "table" then
            for _, b in ipairs(bl) do
                local e = snapOf(b)
                if e then buildings[#buildings + 1] = e end
            end
        end
    end
    table.sort(units, function(a, b) return a.id < b.id end)
    table.sort(buildings, function(a, b) return a.id < b.id end)

    -- Per-Update id indexes: O(1) lookups instead of O(n) findSnap scans.
    -- Built from this tick's snapshot only; userdata is not stored past the tick.
    local unitsById = {}
    for _, e in ipairs(units) do unitsById[e.id] = e end
    local buildingsById = {}
    for _, e in ipairs(buildings) do buildingsById[e.id] = e end

    -- Per-scan allied cache (was: IsAlliedWith per pair, repeatedly).
    local alliedCache = {}
    local function allied(ha, hb)
        if ha == hb then return true end
        local ka = tostring(ha) .. "|" .. tostring(hb)
        local v = alliedCache[ka]
        if v == nil then
            local ok, res = pcall(ha.IsAlliedWith, ha, hb)
            v = (ok and res == true)
            alliedCache[ka] = v
        end
        return v
    end

    -- Group AI houses (identity-matched; name compare would collide on
    -- mirror-country houses sharing one GetName()).
    local aiHouses = {}
    do
        local okN, n = pcall(House.GetCount)
        if okN and type(n) == "number" then
            for idx = 0, n - 1 do
                local okH, h = pcall(House.GetByIndex, idx)
                if okH and h then
                    local okHu, isHu = pcall(h.IsHuman, h)
                    if okHu and isHu ~= true and not allied(h, humanPlayer)
                        and not util.is_neutral_house(h) then
                        aiHouses[#aiHouses + 1] = h
                    end
                end
            end
        end
    end

    if #aiHouses == 0 then return end

    -- Refresh the scan-gate cache for tickScanEvery (next frames).
    do
        local fresh = {}
        for _, h in ipairs(aiHouses) do fresh[h] = true end
        aiHousesCache = fresh
    end

    -- Read-only strategic threat picture. This runs on the existing snapshot
    -- and does not claim units or issue orders.
    SmartAI.updateThreatAssessment(frame, aiHouses, units, buildings, allied)

    -- CAPTURE-ASSET TRACKING: watch ownership of capturable high-value assets
    -- so we can defend the ones we own and re-raid the ones we lost.
    updateCaptureAssets(frame, aiHouses, buildings, buildingsById)

    -- M2-C2 ARBITER (tick-claim registry): ONE authority deciding which
    -- site owns a unit THIS tick. Priority = file order below (codified
    -- status quo, not a rebalance — severity retuning is C4):
    --   GUARD > DEFENSE(+MARCH) > ESCORT > GARRISON > RALLY > RADEVAC
    --     > MINER > RECALL > RAID.
    -- RADEVAC sits below RALLY (a live breach kills faster than attrition);
    -- MINER sits below RADEVAC (evacuees outrank ore) and above RECALL
    -- (a working miner is not a quiet-home surplus). NOTE: file order is
    -- ESCORT > GARRISON > RADEVAC > MINER, all inside the Officer loop,
    -- hence all above RALLY (Commander acts after the Officer).
    -- Every drafting site must tryClaim() before ordering and skip on
    -- conflict; the skipped site counts arbSkips for the per-tick ARBITER
    -- summary. Tick-local by construction: nothing survives the tick, so
    -- cross-match leakage is impossible and no reset entry is needed.
    -- Persistent role memory (escort/defense/guard/raid across ticks)
    -- stays in isOfficerAssigned — claims only stop SAME-tick double
    -- orders (proven gaps: RALLY↔RECALL on the idle-far pool when breach
    -- and presence coexist, GARRISON double-send across buildings).
    -- MARCH↔RAID need no arbitration: march pool and raid form both honor
    -- isOfficerAssigned and their gates (confirmed intrusion vs quiet
    -- home) are mutually exclusive — verified by audit 2026-09-25.
    local claimTick = {}
    local arbSkips = {}
    local function tryClaim(id, site)
        if claimTick[id] then
            arbSkips[site] = (arbSkips[site] or 0) + 1
            return false
        end
        claimTick[id] = site
        return true
    end

    -- STRATEGIC DEFEAT DETECTION (Phase 1: latch + order silence only).
    -- Contract: no Barracks AND no War Factory AND no MCV/CY → surrendered.
    -- Power/refinery/credits/tech/defenses/units/navy/airfield excluded.
    -- Reuses this tick's snapshot (no extra scans). Never calls engine
    -- defeat APIs (Phase 2 research pending). Latch is permanent for the
    -- match; cleared only by the restart path (officerReset).
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if not surrendered[aiHouse] then
            local nB, nW, nM = 0, 0, 0
            for _, e in ipairs(buildings) do
                if e.oh == aiHouse then
                    if typeIn(ANCHOR_BARRACKS, e.t) then nB = nB + 1 end
                    if typeIn(ANCHOR_WF, e.t) then nW = nW + 1 end
                    if typeIn(ANCHOR_MCV, e.t) then nM = nM + 1 end
                end
            end
            for _, e in ipairs(units) do
                if e.oh == aiHouse and e.k == "unit" and typeIn(ANCHOR_MCV, e.t) then
                    nM = nM + 1
                end
            end
            if nB == 0 and nW == 0 and nM == 0 then
                -- Futility gate (user ruling 2026-09-25): anchors-gone means
                -- the house CANNOT RECOVER; it surrenders only when fighting
                -- on is FUTILE too (remaining combat value < ratio of the
                -- strongest enemy's). Otherwise the house keeps full SmartAI
                -- support and the reason is logged throttled (DEFERRED).
                local ownFighters, ownValue = 0, 0
                local foeValue = {}
                for _, e in ipairs(units) do
                    if e.oh and not util.is_neutral_house(e.oh)
                        and not util.CIVIL_TYPES[e.t]
                        and (e.k == "unit" or e.k == "infantry"
                            or e.k == "aircraft")
                        and not HARVESTER_TYPES[e.t]
                        and not MCV_TYPES[e.t] and e.hasPos then
                        if e.oh == aiHouse then
                            ownFighters = ownFighters + 1
                            ownValue = ownValue + e.cost
                        else
                            local okA, al = pcall(e.oh.IsAlliedWith, e.oh, aiHouse)
                            if okA and al ~= true then
                                foeValue[e.oh] = (foeValue[e.oh] or 0) + e.cost
                            end
                        end
                    end
                end
                local topFoe = 0
                for _, v in pairs(foeValue) do
                    if v > topFoe then topFoe = v end
                end
                if ownFighters > 0 and topFoe > 0
                    and ownValue >= SURRENDER_FUTILITY_RATIO * topFoe then
                    if frame % SMARTAI_CENSUS_EVERY < P.scan then
                        dlog("SURRENDER_DEFERRED", frame, string.format(
                            "house=%s anchors=0/0/0 fighters=%d value=%d topfoe=%d",
                            tostring(aiHouse:GetName()), ownFighters,
                            ownValue, topFoe))
                    end
                    goto next_surrender
                end
                surrendered[aiHouse] = frame
                cmdState[aiHouse] = nil
                -- Phase 1: surrendered units stay alive but silent — release
                -- their native leases so the hook never vetoes for a dead
                -- house (the hook always loses to match end, without a
                -- fight). Records stay for the ledger; only the lease goes.
                if TargetLease then
                    for did, ds in pairs(defenseState) do
                        if ds.house == aiHouse then
                            local def = findSnap(units, did)
                            if def and def.u then TargetLease.Release(def.u) end
                        end
                    end
                end
                dlog("SURRENDER_DETECTED", frame, string.format(
                    "house=%s barracks=0 war_factory=0 mcv=0",
                    tostring(aiHouse:GetName())))
                -- Visible surrender: liquidate every own building through
                -- the standard engine sell path (one pass over this tick's
                -- snapshot; each call pcall-guarded). Runs while the house
                -- is fully functional, before the defeat call below.
                local sold, total = 0, 0
                for _, b in ipairs(buildings) do
                    if b.oh == aiHouse then
                        total = total + 1
                        local okS, res = pcall(b.u.Sell, b.u)
                        if okS and res == true then sold = sold + 1 end
                    end
                end
                dlog("SURRENDER_SELL", frame, string.format(
                    "house=%s sold=%d/%d", tostring(aiHouse:GetName()),
                    sold, total))
                -- Engine defeat transition: DISABLED BY DEFAULT (2026-09-26).
                --
                -- Runtime evidence (3/3 multi-house runs, probe-verified):
                -- calling HouseClass::Lose(false) on an AI house makes the
                -- engine LEAVE the hooked game main loop ~90 frames later,
                -- at BorrowedTime expiry, ending the whole match and exiting
                -- the process (code 0) even though every other house is
                -- untouched and undefeated. PRE/POST control-flow counters
                -- prove the call itself RETURNS every time and the detour is
                -- simply never entered again -- so this is the engine
                -- switching out of the game loop, not a crash and not our
                -- timer dying.
                --
                -- HouseClass::Lose() is an engine-INTERNAL defeat transition
                -- that expects the engine's own evaluator to drive it. Forcing
                -- it externally on a non-player house duplicates that
                -- transition with the wrong calling context and ends the
                -- scenario. Corroboration: in the 1v1 Phase-2 run the match
                -- also ended at expiry and IsWinner was NEVER set on the
                -- human -- not how a normal victory flow behaves.
                --
                -- The engine owns defeat. SmartAI's surrender is a DECISION
                -- (latch + order silence + base liquidation + HUD notice),
                -- which is exactly this mod's architecture: a runtime decision
                -- layer, no production/engine-state ownership.
                --
                -- Set to true only to reproduce the old behaviour for
                -- diagnosis; expect the match to end early.
                if SmartAI.SURRENDER_ENGINE_CALL then
                    local okLose, loseRes =
                        pcall(Engine.__SmartAILose, aiHouse)
                    dlog("LOSE_FALSE_CALLED", frame, string.format(
                        "house=%s result=%s", tostring(aiHouse:GetName()),
                        (okLose and loseRes == true) and "called" or "refused"))
                else
                    dlog("SURRENDER_NO_ENGINE_CALL", frame, string.format(
                        "house=%s defeated=0 reason=engine_defeat_owned_by_" ..
                        "engine; decision_only", tostring(aiHouse:GetName())))
                end
                local alert = string.format(
                    "[AI Commander - %s] Strategic defeat: production gone, standing down.",
                    tostring(aiHouse:GetName()))
                Engine.PrintMessage(alert)
                print("[LuaAPI] " .. alert)
            end
            ::next_surrender::
        end
        -- AUDIT HEARTBEAT runs for every AI house, including surrendered
        -- houses and the deferred-surrender path above.
        SmartAI.logHouseAuditHeartbeat(aiHouse)
    end

    -- BUILDLAW enforcement, FINAL rule (v3): sell IFF all hold —
    -- (a) chain broken NOW, (b) chain was broken at BIRTH (birth-legal
    -- buildings are never touched: ordered-while-stood), (c) type was
    -- NOT queue-marked fresh at birth (queued-while-satisfied =
    -- queue-completion; marks refresh while queued and expire
    -- QMARK_WINDOW after the last satisfied sighting, so a stale mark
    -- never grandfathers a post-raze rebuild), (d) birth scan > 1
    -- (load-time / pre-placed inventory assumed legal),
    -- (e) past BUILDLAW_GRACE, (f) AI house, non-surrendered, preset on.
    -- This is MM-doctrine (prereqs at order time) made measurable:
    -- birth + queue-mark separate "ordered legally" from "fresh cheat",
    -- which snapshots alone cannot (French f=31652 lesson).
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        -- Declared before the skips below: a goto may not jump over a
        -- local declaration (Lua 5.4 scope rule).
        local cur = {}
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.t ~= "" then
                cur[b.t] = true
            end
        end
        -- PROC alternate: an undeployed Slave Miner vehicle satisfies
        -- PROC ([General] PrerequisiteProcAlternate=SMIN; modded prefix
        -- tolerated like everywhere else).
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.t ~= "" then
                if PROC_ALT_TYPES[e.t] then
                    cur[e.t] = true
                else
                    for alt in pairs(PROC_ALT_TYPES) do
                        if e.t:sub(-(#alt + 1)) == "-" .. alt then
                            cur[e.t] = true
                            break
                        end
                    end
                end
            end
        end
        if surrendered[aiHouse] then goto next_buildlaw end
        if not P.buildlaw then goto next_buildlaw end
        local grace = SmartAI.BUILDLAW_GRACE or 1800
        -- Queue binding (read-only, may be absent on old DLLs): resolved
        -- per tick, never cached across ticks (a rebuilt DLL mid-process
        -- must not keep a stale nil).
        local AIQ = nil
        if type(AI) == "table" and type(AI.IsQueued) == "function" then
            AIQ = AI.IsQueued
        end
        local qmarks = queuedWhileSat[aiHouse]
        if not qmarks then
            qmarks = {}
            queuedWhileSat[aiHouse] = qmarks
        end
        local qmarkWindow = SmartAI.QMARK_WINDOW or 1800
        if AIQ then
            for canon, row in pairs(BUILDLAW) do
                if not buildLawMissing(cur, row) then
                    local ok, q = pcall(AIQ, aiHouse, canon)
                    if ok and q == true then
                        if not qmarks[canon] then
                            dlog("QUEUE_GRAND", frame, string.format(
                                "house=%s type=%s chain=satisfied",
                                tostring(aiHouse:GetName()),
                                tostring(canon)))
                        end
                        qmarks[canon] = frame -- refresh while queued
                    end
                end
            end
        end
        -- Expire stale marks: a mark outlives queue->completion lag but
        -- never a post-raze rebuild minutes later.
        for canon, mf in pairs(qmarks) do
            if frame - (mf or 0) > qmarkWindow then
                qmarks[canon] = nil
            end
        end
        if frame >= grace then
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse then
                local row, canon = buildLawRowKey(b.t)
                if row then
                    if birthScan[b.id] == nil then
                        birthScan[b.id] = scanCounter
                        -- Birth-latch: born satisfied OR born under a
                        -- fresh mark (queue-completion) = legal forever.
                        -- A standing legal building is never re-examined
                        -- when its mark later expires.
                        local bornMissing =
                            buildLawMissing(cur, row) ~= nil
                        local mf = qmarks[canon]
                        local markedFresh =
                            mf and (frame - mf <= qmarkWindow)
                        birthViol[b.id] = bornMissing and not markedFresh
                    end
                    local missing = buildLawMissing(cur, row)
                    if missing and (birthScan[b.id] or 0) > 1
                        and birthViol[b.id] then
                    -- Sell budget: an AI stuck re-cheating one type is
                    -- taxed SELL_CAP times per match, then left standing
                    -- (log-and-leave) so enforcement cannot brick the AI.
                    local cap = SmartAI.BUILDLAW_SELL_CAP or 3
                    local sc = sellCounts[aiHouse]
                    if not sc then
                        sc = {}
                        sellCounts[aiHouse] = sc
                    end
                    local n = sc[canon] or 0
                    if n >= cap then
                        local gu = gaveUp[aiHouse]
                        if not gu then
                            gu = {}
                            gaveUp[aiHouse] = gu
                        end
                        if not gu[canon] then
                            gu[canon] = true
                            dlog("BUILDLAW_GAVE_UP", frame, string.format(
                                "house=%s type=%s sells=%d cap=%d",
                                tostring(aiHouse:GetName()),
                                tostring(canon), n, cap))
                            local alert = string.format(
                                "[AI Commander - %s] Leaving illegal %s "
                                .. "standing (%d sells).",
                                tostring(aiHouse:GetName()),
                                tostring(b.t), n)
                            Engine.PrintMessage(alert)
                            print("[LuaAPI] " .. alert)
                        end
                    else
                    local okC0, c0 = pcall(aiHouse.GetCredits, aiHouse)
                    local okS, sold = pcall(b.u.Sell, b.u)
                    if okS and sold == true then
                        sc[canon] = n + 1
                        local refund = 0
                        local okC1, c1 = pcall(aiHouse.GetCredits, aiHouse)
                        if okC0 and okC1 and type(c0) == "number"
                            and type(c1) == "number" and c1 > c0 then
                            refund = c1 - c0
                            pcall(aiHouse.AddCredits, aiHouse, c0 - c1)
                        end
                        dlog("BUILDLAW_SELL", frame, string.format(
                            "house=%s sold=%s type=%s missing=%s refund=%d",
                            tostring(aiHouse:GetName()), tostring(b.id),
                            tostring(b.t), tostring(missing), refund))
                        local alert = string.format(
                            "[AI Commander - %s] Illegal %s sold (no %s).",
                            tostring(aiHouse:GetName()), tostring(b.t),
                            tostring(missing))
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                    end -- budget: sell vs leave
                    end -- missing entry: violation confirmed
                end
            end
        end
        end -- grace window
        ::next_buildlaw::
    end

    -- MCVLAW enforcement (units, never-had rule over WF+depot).
    -- Records every own building type first (same-scan unlock
    -- legalizes same-scan MCV), then destroys systematic MCVs whose
    -- whole chain was never seen. No arbiter claims: destruction is
    -- terminal, there is no order to conflict over.
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        local dep = seenBTypes[aiHouse]
        if not dep then
            dep = {}
            seenBTypes[aiHouse] = dep
        end
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.t ~= "" then
                dep[b.t] = true
            end
        end
        if surrendered[aiHouse] then goto next_mcv end
        if not P.buildlaw then goto next_mcv end
        local grace = SmartAI.BUILDLAW_GRACE or 1800
        if frame >= grace then
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "unit" and e.hasPos then
                local row, canon = mcvLawRow(e.t)
                if row then
                    -- Deployed MCVs are bases, never touched (fail-open
                    -- toward enforcement on bindings without IsDeployed).
                    local okD, isDep = pcall(e.u.IsDeployed, e.u)
                    if not (okD and isDep == true) then
                        if birthScan[e.id] == nil then
                            birthScan[e.id] = scanCounter
                        end
                        local missing = buildLawMissing(dep, row)
                        if missing and (birthScan[e.id] or 0) > 1 then
                            local cap = SmartAI.BUILDLAW_SELL_CAP or 3
                            local sc = sellCounts[aiHouse]
                            if not sc then
                                sc = {}
                                sellCounts[aiHouse] = sc
                            end
                            local n = sc[canon] or 0
                            if n >= cap then
                                local gu = gaveUp[aiHouse]
                                if not gu then
                                    gu = {}
                                    gaveUp[aiHouse] = gu
                                end
                                if not gu[canon] then
                                    gu[canon] = true
                                    dlog("MCVLAW_GAVE_UP", frame,
                                        string.format(
                                            "house=%s type=%s destroys=%d cap=%d",
                                            tostring(aiHouse:GetName()),
                                            tostring(canon), n, cap))
                                end
                            else
                                if orderDestroy(e, 100000, "COMMANDER", "MCVLAW",
                                    "illegal MCV destruction",
                                    string.format("missing=%s", tostring(missing))) then
                                    sc[canon] = n + 1
                                    dlog("MCVLAW_DESTROY", frame,
                                        string.format(
                                            "house=%s destroyed=%s type=%s "
                                            .. "missing=%s",
                                            tostring(aiHouse:GetName()),
                                            tostring(e.id), tostring(e.t),
                                            tostring(missing)))
                                    local alert = string.format(
                                        "[AI Commander - %s] Illegal %s "
                                        .. "destroyed (no %s).",
                                        tostring(aiHouse:GetName()),
                                        tostring(e.t), tostring(missing))
                                    Engine.PrintMessage(alert)
                                    print("[LuaAPI] " .. alert)
                                end
                            end
                        end
                    end
                end
            end
        end
        end -- grace window
        ::next_mcv::
    end

    -- COMMANDER recon (base): breach detection feeds the shared blackboard.
    -- pendingBreach is same-scan only (building userdata never persists).
    -- Officer runs before Commander acts, so the rally below sees fresh
    -- Officer assignments and stands off them (mutual coordination).
    --
    -- TRIGGER 2026-09-26: proximity, NOT HP. See RALLY_THREAT_R for why the
    -- old "below 85% max HP" rule was a sampling race that silently produced
    -- zero rallies in two consecutive live matches.
    --
    -- Aircraft ARE part of the threat set on purpose: the old HP rule caught
    -- bombing damage, and DEFENSE_KINDS excludes aircraft, so reusing the
    -- point-defense filter here would have silently dropped air cover.
    -- Harvesters and MCVs are excluded (economy and construction, not
    -- attackers); civilians and non-defenders never count.
    --
    -- Most-threatened building wins (smallest hostile distance, id
    -- tiebreak) so the rally goes to the flank actually being hit instead of
    -- whichever building happened to come first in snapshot order.
    --
    -- RALLYDIAG (diagnostic only) reports every stage of the rally causal
    -- chain so a missing RALLY_BREACH names the stage that stopped it.
    local pendingBreach, rallyDiag = {}, {}
    for _, aiHouse in ipairs(aiHouses) do
        local dg = {
            own = 0, threatened = 0, bestD2 = 0, bId = 0, bType = "",
            poolOwn = 0, poolIdle = 0, poolFar = 0, poolFree = 0,
            poolFresh = 0, claims = 0, orders = 0,
            sameSpot = false, capElapsed = false, since = 0,
        }
        rallyDiag[aiHouse] = dg
        local bestB
        for _, bld in ipairs(buildings) do
            if bld.oh == aiHouse and bld.hasPos then
                dg.own = dg.own + 1
                local nearD2
                for _, u in ipairs(units) do
                    if u.oh and u.oh ~= aiHouse and not allied(aiHouse, u.oh)
                        and not util.is_neutral_house(u.oh)
                        and not util.CIVIL_TYPES[u.t]
                        and not HARVESTER_TYPES[u.t]
                        and not MCV_TYPES[u.t]
                        and (u.k == "unit" or u.k == "infantry"
                            or u.k == "aircraft")
                        and u.hasPos then
                        local d2 = dist2(bld.x, bld.y, u.x, u.y)
                        if d2 <= RALLY_THREAT_R2 and (not nearD2 or d2 < nearD2) then
                            nearD2 = d2
                        end
                    end
                end
                if nearD2 then
                    dg.threatened = dg.threatened + 1
                    if not bestB or nearD2 < dg.bestD2
                        or (nearD2 == dg.bestD2 and bld.id < bestB.id) then
                        bestB, dg.bestD2 = bld, nearD2
                    end
                end
            end
        end
        if bestB then
            pendingBreach[aiHouse] = bestB
            dg.bId, dg.bType = bestB.id, tostring(bestB.t)
        end
    end

    -- OFFICER (units): maneuvers, pullbacks, observation. Never touches base.
    -- Capture-aware valuables guard (see header block). Per AI house:
    -- valuable unit + nearby observable capturer + lone exposure
    -- -> pull back toward the own group (MoveTo only, once per
    -- transition + periodic refresh). Engaged units are never yanked.
    -- Owner flips are logged as observations (possible vanilla
    -- capture/mind-control); they drive no decisions.
    local seenNow = {}
    for _, e in ipairs(units) do
        seenNow[e.id] = true
        if e.on then
            local prev = seenOwner[e.id]
            if prev and prev ~= e.on then
                local note = string.format(
                    "[AI Commander] Ownership change observed: %s#%s %s -> %s (possible vanilla capture/mind-control)",
                    tostring(e.t), tostring(e.id),
                    tostring(prev), tostring(e.on))
                Engine.PrintMessage(note)
                print("[LuaAPI] " .. note)
            end
            seenOwner[e.id] = e.on
        end
    end
    for _, e in ipairs(buildings) do
        seenNow[e.id] = true
    end
    for id in pairs(seenOwner) do
        if not seenNow[id] then seenOwner[id] = nil end
    end
    for id in pairs(guardState) do
        if not seenNow[id] then guardState[id] = nil end
    end

    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_guard end -- Phase 1: silence
        -- Own mobiles, ID-ordered (deterministic centroid). The centroid is
        -- combat-only: harvesters/MCVs/artillery staging elsewhere must not
        -- drag the "own group" anchor (old code averaged every mobile).
        local tagged = {}
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.hasPos then
                tagged[#tagged + 1] = e
            end
        end
        local cx, cy, n = 0, 0, 0
        for _, e in ipairs(tagged) do
            if not HARVESTER_TYPES[e.t] and not MCV_TYPES[e.t]
                and not ARTILLERY_TYPES[e.t] then
                cx, cy, n = cx + e.x, cy + e.y, n + 1
            end
        end
        if P.guard and n > 0 then
            cx, cy = cx / n, cy / n
            for _, e in ipairs(tagged) do
                if VALUABLE_TYPES[e.t] and e.idle then
                    -- Nearest observable hostile capturer.
                    local nearest = nil
                    for _, v in ipairs(units) do
                        if v.id ~= e.id and CAPTURE_THREATS[v.t] then
                            if v.oh and v.oh ~= aiHouse and not allied(aiHouse, v.oh)
                                and v.hasPos then
                                local d2 = dist2(e.x, e.y, v.x, v.y)
                                if not nearest or d2 < nearest then
                                    nearest = d2
                                end
                            end
                        end
                    end
                    local exposed = e.hasPos and
                        (dist2(e.x, e.y, cx, cy) > HOLD_RADIUS * HOLD_RADIUS)
                    local nearestCells = nearest and math.sqrt(nearest) or nil
                    local st = guardState[e.id]
                    if nearestCells and nearestCells <= THREAT_RADIUS and exposed then
                        if not st or not st.threatened
                            or (frame - (st.orderedFrame or 0) >= REORDER_EVERY) then
                            if tryClaim(e.id, "GUARD")
                                and orderMove(e, math.floor(cx + 0.5), math.floor(cy + 0.5),
                                    "OFFICER", "GUARD", "capture risk pullback",
                                    string.format("dest=%d,%d threat=%.1f",
                                        math.floor(cx + 0.5), math.floor(cy + 0.5),
                                        nearestCells or -1)) then
                                diagOrder(frame, "GUARD_PULLBACK", e, "MoveTo",
                                    string.format("dest=%d,%d threat=%.1f",
                                        math.floor(cx + 0.5), math.floor(cy + 0.5),
                                        nearestCells or -1))
                                guardState[e.id] = { threatened = true, orderedFrame = frame }
                                local alert = string.format(
                                    "[AI Commander - %s] %s#%s capture risk (threat %.1f cells): pulling back to group!",
                                    tostring(aiHouse:GetName()), tostring(e.t),
                                    tostring(e.id), nearestCells)
                                Engine.PrintMessage(alert)
                                print("[LuaAPI] " .. alert)
                            end
                        end
                    elseif st and st.threatened then
                        guardState[e.id] = nil
                    end
                end
            end
        end
        ::next_guard::
    end

    -- C4 PRESET/LAYER DIAGNOSTIC (DIAGNOSTIC ONLY). Emitted ABOVE the
    -- `if P.defense` gate and above the per-house `not P.intruderR` gate on
    -- purpose. The C4DIAG funnel below sits INSIDE those gates, so it can
    -- never report the case where the layer is switched off -- which is
    -- exactly the case a live 23 400-frame match hit (C4DIAG=0, no
    -- DEFENSE_SEV, no POINT_DEFENSE, player standing on the AI base).
    -- This line reports, per house: the global preset, the per-house
    -- preset, the raw engine difficulty, whether intruderR exists, and the
    -- resulting layer state, so a disabled layer is visible instead of
    -- silent. Bounded to one line per house per SMARTAI_CENSUS_EVERY.
    if (frame % SMARTAI_CENSUS_EVERY) < tickScanEvery() then
        local outerName = c4PresetName(P)
        for _, aiHouse in ipairs(aiHouses) do
            local ph = paramsFor(aiHouse)
            local innerName = c4PresetName(ph)
            local isSurr = surrendered[aiHouse] ~= nil
            local state
            if not P.defense then state = "OFF_NO_DEFENSE"
            elseif not ph.intruderR then state = "OFF_NO_INTRUDER_R"
            elseif isSurr then state = "OFF_SURRENDERED"
            else state = "ON" end
            -- QUIET (KEEP/QUIET/CUT): constant all match except on
            -- surrender/preset flip; on-change + heartbeat.
            dlogChange("C4PRESET", frame, aiHouse:GetName(), string.format(
                "aiHouses=%d house=%s outer=%s preset=%s difficulty=%s R=%s "
                    .. "def=%s r=%s surr=%s state=%s diverge=%s funnel=%s",
                #aiHouses, tostring(aiHouse:GetName()), outerName, innerName,
                c4RawDifficulty(aiHouse),
                ph.intruderR and tostring(ph.intruderR) or "nil",
                tostring(P.defense == true),
                tostring(ph.intruderR ~= nil),
                tostring(isSurr),
                state, tostring(innerName ~= outerName),
                tostring(state == "ON")))
        end
    end

    -- POINT DEFENSE (per AI house, runs FIRST so home defense outranks
    -- escort drafting): intruders are hostile ground mobiles inside
    -- intruderR of any own building. Tier 1 assigns idle defenders real
    -- Attack orders (transition-only + refresh cap). Tier 2 (march recall)
    -- pulls marching ground units home once the intrusion is CONFIRMED over
    -- consecutive scans; fighting units (IsAttacking) are never yanked,
    -- unknown attack state means skip. Defender bookkeeping feeds
    -- isOfficerAssigned, so escort and rally below stand off defenders.
    if P.defense then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if not P.intruderR then goto next_defense end -- easy preset: layer off
        if surrendered[aiHouse] then goto next_defense end -- Phase 1: silence
        local aiName = aiHouse:GetName()
        local home = {}
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.hasPos then home[#home + 1] = b end
        end
        -- C4 detector diagnostic (throttled, DIAGNOSTIC ONLY). Deliberately
        -- placed BEFORE the `#home > 0` gate: a house with no own buildings
        -- skips detection entirely and also yields zero intruders, and that
        -- cause must be distinguishable from a filter or distance failure.
        local c4diag = (frame % SMARTAI_CENSUS_EVERY) < P.scan
        local c4d
        if c4diag then c4d = c4diagScan(units, home, aiHouse, P, allied) end
        if #home > 0 then
            local bx, by = 0, 0
            for _, b in ipairs(home) do bx, by = bx + b.x, by + b.y end
            bx, by = bx / #home, by / #home

            local intruders = {}
            local airIntruders = 0
            for _, u in ipairs(units) do
                if u.oh and u.oh ~= aiHouse and not allied(aiHouse, u.oh)
                    and not util.is_neutral_house(u.oh)
                    and not util.CIVIL_TYPES[u.t]
                    and DEFENSE_KINDS[u.k] and u.hasPos then
                    for _, b in ipairs(home) do
                        if dist2(u.x, u.y, b.x, b.y) <= P.intruderR * P.intruderR then
                            intruders[#intruders + 1] = u
                            if isAirThreat(u) then
                                airIntruders = airIntruders + 1
                            end
                            break
                        end
                    end
                end
            end
            -- Log air intruder detection (diagnostic only, fires once per scan
            -- when aircraft are over the base). Kirov reads as kind=="unit"
            -- and is in AIR_RAIDERS; helicopters/jets read as kind=="aircraft".
            if airIntruders > 0 then
                dlog("AIR_INTRUDERS", frame, string.format(
                    "house=%s air_intruders=%d total_intruders=%d intruderR=%d",
                    tostring(aiName), airIntruders, #intruders, P.intruderR))
            end
            -- Threat order (live-proven need: a lone defender must take
            -- the Mammoth, not the GI): suicide units first (DTRUCK
            -- one-shots buildings — threat != price), then vehicles before
            -- infantry, then pricey before cheap, then id ascending
            -- (deterministic).
            local function intruderRank(e)
                if SUICIDE_TYPES[e.t] then return -1 end
                if e.k == "unit" then return 0 end
                if e.k == "infantry" then return 1 end
                return 2
            end
            table.sort(intruders, function(a, b)
                local ra, rb = intruderRank(a), intruderRank(b)
                if ra ~= rb then return ra < rb end
                if a.cost ~= b.cost then return a.cost > b.cost end
                return a.id < b.id
            end)

            -- Hysteresis counters for the march recall.
            local seen = intruderSeen[aiHouse] or {}
            local cur = {}
            for _, it in ipairs(intruders) do
                local prev = seen[it.id]
                cur[it.id] = {
                    n = (prev and prev.n or 0) + 1,
                    lastFrame = frame,
                }
            end
            intruderSeen[aiHouse] = cur
            if #intruders > 0 then
                lastThreatFrame[aiHouse] = frame -- M2-C3 quiet gate input
            end
            -- C4 diagnostic (CASE D probe): the aggregate every downstream
            -- stage consumes, captured as formed and BEFORE severity reads
            -- #intruders. distPass in the mirror must equal this value; a
            -- mismatch means mirror and detector have diverged.
            if c4diag then c4d.intr = #intruders end
            -- M2-C4 SEVERITY: score the intrusion, allocate by level.
            -- LOW (scout): 1 defender per intruder + keep the last idle
            -- tank in reserve. NORMAL: defendersN as before. HIGH (push):
            -- defendersN+1 per intruder + 1.5x assign radius. Recomputed
            -- every tick from live intruders (re-evaluate by construction);
            -- level line logged on change only.
            local sevScore = 0.0
            for _, it in ipairs(intruders) do
                sevScore = sevScore + intruderSev(it)
            end
            local sevLevel = "NORMAL"
            if sevScore < SEV_LOW_BELOW then sevLevel = "LOW"
            elseif sevScore >= SEV_HIGH_FROM then sevLevel = "HIGH" end
            if #intruders == 0 then sevLevel = "NONE" end
            if defSevLevel[aiHouse] ~= sevLevel then
                defSevLevel[aiHouse] = sevLevel
                if sevLevel ~= "NONE" then
                    dlog("DEFENSE_SEV", frame, string.format(
                        "house=%s level=%s score=%.1f intruders=%d",
                        tostring(aiName), sevLevel, sevScore, #intruders))
                end
            end
            local sevN = P.defendersN
            local sevAssignR = P.assignR
            if sevLevel == "LOW" then sevN = 1
            elseif sevLevel == "HIGH" then
                sevN = P.defendersN + 1
                sevAssignR = P.assignR * 1.5
            end

            -- === DIAGNOSTIC ONLY: Act-side candidate selection ============
            -- Answers "intruders > 0 but POINT_DEFENSE = 0" by naming the
            -- exact gate that dropped each own unit. Pure reads: no claim,
            -- no order, no write to defenseState / dEff / intruderSeen /
            -- C2 state / candidate order. Runs only on a census frame.
            --
            -- Instrumenting the EXISTING scan rather than adding a second
            -- population scan: the verdict below re-evaluates the very same
            -- predicate, in the same order, over the same `units` list.
            --
            -- COUNTING SEMANTICS (deliberate, and the reason this is not a
            -- naive mirror of Tier 1): Tier 1 re-evaluates every own unit once
            -- PER INTRUDER, so a naive tally would report eligible=3 for one
            -- defender standing near three intruders. Here each unit is
            -- tallied exactly ONCE, at the furthest gate it reached for AT
            -- LEAST ONE current intruder, which keeps the funnel strictly
            -- monotonic (ownTotal -> ownIdle -> officer -> kind -> nonGround
            -- -> eligible -> inAssignR). Consequence: ownEligible is a LOWER
            -- BOUND on Act's effective pool, because a unit blocked for
            -- intruder A but free for intruder B is credited to B's verdict
            -- only. This mirrors the architecture rather than correcting it.
            --
            -- `takenDef` is intentionally NOT a gate here: it is transient
            -- per-pass bookkeeping for units already drafted in this sweep,
            -- not a property of the unit.
            if c4diag and c4d and #intruders > 0 then
                local a = c4d.act
                a.ran = true
                for _, u in ipairs(units) do
                    if u.oh == aiHouse then
                        a.ownTotal = a.ownTotal + 1
                        if u.idle then
                            a.ownIdle = a.ownIdle + 1
                            -- Verdict rank, furthest reached across all
                            -- current intruders: 1 officer, 2 kind, 3 nonGround,
                            -- 4 no position, 5 eligible-out-of-radius,
                            -- 6 eligible-in-radius.
                            local rank, why = 0, nil
                            -- Hoisted: isOfficerAssigned does not depend on
                            -- the intruder, and holdingIt is only consulted
                            -- when the unit is actually held.
                            local held = isOfficerAssigned(u.id)
                            for _, it in ipairs(intruders) do
                                local v, vwhy
                                if held then
                                    local ds0 = defenseState[u.id]
                                    local holdingIt = ds0 and ds0.targetId == it.id
                                        and frame - (ds0.orderedFrame or 0) < P.defenseEvery
                                    if not holdingIt then
                                        v, vwhy = 1, "OFFICER"
                                    end
                                end
                                if not v then
                                    local airJob = isAirThreat(it)
                                    -- Production kind predicate, unchanged.
                                    local kindOk = (u.k == "unit" and not AIR_RAIDERS[u.t])
                                        or (airJob and u.k == "infantry" and AA_TYPES[u.t])
                                    if not kindOk then
                                        if u.k == "infantry" then
                                            v, vwhy = 2, "INF"
                                        elseif u.k == "aircraft" then
                                            v, vwhy = 2, "AIR"
                                        elseif AIR_RAIDERS[u.t] then
                                            v, vwhy = 2, "AIRRAID"
                                        else
                                            v, vwhy = 2, "OTHER"
                                        end
                                    elseif HARVESTER_TYPES[u.t] then
                                        v, vwhy = 3, "HARV"
                                    elseif MCV_TYPES[u.t] then
                                        v, vwhy = 3, "MCV"
                                    elseif ARTILLERY_TYPES[u.t] then
                                        v, vwhy = 3, "ART"
                                    elseif not u.hasPos then
                                        v, vwhy = 4, "NOPOS"
                                    elseif dist2(u.x, u.y, it.x, it.y)
                                        <= sevAssignR * sevAssignR then
                                        v, vwhy = 6, "RADIUS"
                                    else
                                        v, vwhy = 5, "OUT_OF_RADIUS"
                                    end
                                end
                                if v and v > rank then rank, why = v, vwhy end
                            end
                            if rank == 1 then
                                a.ownOfficerHeld = a.ownOfficerHeld + 1
                            elseif rank == 2 then
                                a.ownKindRejected = a.ownKindRejected + 1
                                a.actKindRej[why] = (a.actKindRej[why] or 0) + 1
                            elseif rank == 3 then
                                a.ownNonGround = a.ownNonGround + 1
                                a.actNonGroundRej[why] = (a.actNonGroundRej[why] or 0) + 1
                            elseif rank == 4 then
                                a.ownNoPos = a.ownNoPos + 1
                            else
                                a.ownEligible = a.ownEligible + 1
                                if rank == 6 then a.inAssignR = a.inAssignR + 1 end
                            end
                        end
                    end
                end
            end

            -- === M2-C4 ADAPT: Act -> Observe result -> Adapt =============
            -- Act (above): Tier 1 drafted sevN idle defenders onto intruders.
            -- Observe (end of Update): each finished assignment was resolved
            -- into a win or a loss for this house (dEff).
            -- Adapt (here): the defence is MEASURABLY losing its exchanges,
            -- so the response changes class -- instead of one more idle
            -- defender (there are none: measured poolIdle=0), commit the
            -- marching units that vanilla left heading somewhere else.
            --
            -- Claims as "MARCH": the documented arbiter order already folds
            -- MARCH into the DEFENSE tier (GUARD > DEFENSE(+MARCH) > ...),
            -- so this needs no priority change and correctly loses to GUARD.
            -- NOTE: `and` binds looser than `>=` in Lua, so `eff and
            -- eff.streak >= N` would parse as `(eff and eff.streak) >= N`
            -- and throw "attempt to compare nil with number" on the very
            -- first scan, before any episode has resolved. Read the streak
            -- into a local first.
            local eff = dEff[aiHouse]
            local streak = (eff and eff.streak) or 0
            if eff and #intruders > 0 and streak >= ADAPT_STREAK_TRIGGER
                and frame >= (eff.adaptUntil or 0) then
                eff.adaptUntil = frame + P.defenseEvery
                local poolFar, poolBusy, poolTaken, poolOfficer = 0, 0, 0, 0
                for _, u in ipairs(units) do
                    if u.oh == aiHouse and u.k == "unit" and u.hasPos
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t] then
                        if dist2(u.x, u.y, bx, by) > ADAPT_PULL_MIN_DIST * ADAPT_PULL_MIN_DIST then
                            poolFar = poolFar + 1
                            if not u.idle and u.attacking == false then
                                poolBusy = poolBusy + 1
                                if isOfficerAssigned(u.id) then
                                    poolOfficer = poolOfficer + 1
                                elseif tryClaim(u.id, "MARCH")
                                    and orderMove(u, math.floor(bx + 0.5), math.floor(by + 0.5)) then
                                    poolTaken = poolTaken + 1
                                    eff.pulled = (eff.pulled or 0) + 1
                                    diagOrder(frame, "ADAPT_RECALL", u, "MoveTo",
                                        string.format("reason=DEFENSE_LOSING streak=%d "
                                            .. "w=%d l=%d dest=%d,%d",
                                            eff.streak, eff.w, eff.l,
                                            math.floor(bx + 0.5), math.floor(by + 0.5)))
                                end
                            end
                        end
                    end
                end
                if poolTaken > 0 then
                    dEffStats.pulls = dEffStats.pulls + poolTaken
                else
                    dEffStats.denied = dEffStats.denied + 1
                end
                -- Success is an EVENT, not a state: never throttled, so a
                -- grep for this tag cannot conclude the adaptation is dead
                -- (the RALLYDIAG lesson).
                dlog("ADAPT", frame, string.format(
                    "house=%s streak=%d w=%d l=%d intruders=%d sev=%s "
                        .. "poolFar=%d poolBusy=%d poolOfficer=%d pulled=%d",
                    tostring(aiName), eff.streak, eff.w, eff.l, #intruders,
                    tostring(sevLevel), poolFar, poolBusy, poolOfficer, poolTaken))
            end

            -- === M2-C4 RECOVERY: the response to the FIRST loss ============
            -- Proven live 2026-09-26: the adaptation ladder could not
            -- bootstrap. The reason was an INVERSION OF PREREQUISITES, not a
            -- threshold that was merely too high:
            --     to LOSE     -> 1 idle ground defender + 1 contact
            --     to ADAPT    -> streak 2, i.e. 2 contacts, i.e. 2 idle
            --                     ground defenders over time, PLUS a distant
            --                     ground reserve
            -- Recovery therefore demanded strictly MORE than the failure it
            -- was recovering from. A house that lost one exchange and then
            -- lost its mobility could never leave streak=1.
            --
            -- This block removes the inversion: ONE measured loss is enough to
            -- get a response. It is NOT the ADAPT block with a lower
            -- threshold -- the two are separate responses with separate
            -- populations, radii, limits and cooldowns:
            --
            --   RECOVERY  streak >= 1, near reserve, <= assignR, max 1 unit,
            --             no `confirmed` requirement, cooldown defenseEvery
            --   ADAPT     streak >= ADAPT_STREAK_TRIGGER (unchanged 2), FAR
            --             reserve, > ADAPT_PULL_MIN_DIST, no count limit
            --
            -- The two responses partition on the streak, and the partition is
            -- on the STREAK BAND, not on "did ADAPT happen to run this tick".
            -- An earlier revision guarded with `not adaptFired`; that is wrong,
            -- and live in this harness: ADAPT and RECOVERY latch on SEPARATE
            -- cooldowns, so at streak 3 there are windows where ADAPT is
            -- cooling down and RECOVERY is not. RECOVERY then hijacked an
            -- escalated state and pulled a unit ADAPT deliberately leaves
            -- alone -- which broke the T59 25-cell-floor contract. With the
            -- band guard, streak >= ADAPT_STREAK_TRIGGER belongs to ADAPT
            -- unconditionally and the latches can never overlap.
            --
            -- Population: NOT idle and NOT attacking -- the units Act
            -- structurally cannot use, which is why no new ground defender
            -- appeared after the loss. Idle units are Act's business; a WIN
            -- resets the streak and stops the response on its own.
            --
            -- Radius uses P.assignR, not the severity-scaled sevAssignR, so the
            -- bound is stable regardless of the current threat level.
            --
            -- Anti-churn: the existing defenseEvery cadence plus the existing
            -- per-unit redirectEvery window through recallState -- the same
            -- mechanism Tier 2 MARCH_RECALL uses. No new lease system.
            --
            -- Claim "MARCH" reuses the documented tier
            -- (GUARD > DEFENSE(+MARCH) > ESCORT > GARRISON > RALLY > RECALL >
            -- RAID); no new priority tier, and a contested unit is resolved by
            -- the existing C2 claim, not by any logic here.
            if eff and #intruders > 0 and streak >= 1
                and streak < ADAPT_STREAK_TRIGGER
                and frame >= (eff.recoveryUntil or 0) then
                eff.recoveryUntil = frame + P.defenseEvery
                local recR2 = P.assignR * P.assignR
                local cands = {}
                local poolNear, poolBusy, poolOfficer, poolRecent = 0, 0, 0, 0
                for _, u in ipairs(units) do
                    if u.oh == aiHouse and u.k == "unit" and u.hasPos
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t] then
                        local d2 = dist2(u.x, u.y, bx, by)
                        if d2 <= recR2 then
                            poolNear = poolNear + 1
                            if not u.idle and u.attacking == false then
                                poolBusy = poolBusy + 1
                                local rs = recallState[u.id]
                                if isOfficerAssigned(u.id) then
                                    poolOfficer = poolOfficer + 1
                                elseif rs and frame - (rs.orderedFrame or 0) < P.redirectEvery then
                                    poolRecent = poolRecent + 1
                                else
                                    cands[#cands + 1] = { u = u, d2 = d2 }
                                end
                            end
                        end
                    end
                end
                -- Nearest first, id ascending on a tie: deterministic, so the
                -- reported unit is reproducible.
                table.sort(cands, function(a, b)
                    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                    return a.u.id < b.u.id
                end)
                local claimed, ordered = 0, 0
                local firstUnit, firstDist = nil, nil
                -- Single source of truth for the claim site: the same value is
                -- passed to tryClaim AND reported by the event, so the log
                -- cannot claim a tier the order did not actually use.
                local recClaim = "MARCH"
                for i = 1, math.min(RECOVERY_MAX_UNITS, #cands) do
                    local c = cands[i]
                    if tryClaim(c.u.id, recClaim) then
                        claimed = claimed + 1
                        if orderMove(c.u, math.floor(bx + 0.5), math.floor(by + 0.5),
                            "OFFICER", "DEFENSE_RECOVERY", "first loss response",
                            string.format("streak=%d w=%d l=%d", eff.streak, eff.w, eff.l)) then
                            ordered = ordered + 1
                            recallState[c.u.id] = { orderedFrame = frame }
                            if not firstUnit then firstUnit, firstDist = c.u, c.d2 end
                        end
                    end
                end
                if ordered > 0 then
                    dEffStats.recovery = dEffStats.recovery + ordered
                end
                -- QUIET (KEEP/QUIET/CUT): empty repeats collapse to
                -- on-change + heartbeat; a response that claimed or
                -- ordered is an event and always logs (force).
                local recMsg = string.format(
                    "house=%s streak=%d w=%d l=%d intruders=%d sev=%s "
                        .. "unit=%s type=%s dist=%d anchor=%d,%d "
                        .. "poolNear=%d poolBusy=%d poolOfficer=%d poolRecent=%d "
                        .. "claim=%s claimed=%s ordered=%s orderedUnits=%d",
                    tostring(aiName), eff.streak, eff.w, eff.l, #intruders,
                    tostring(sevLevel),
                    firstUnit and tostring(firstUnit.id) or "-",
                    firstUnit and tostring(firstUnit.t) or "-",
                    firstDist and math.floor(math.sqrt(firstDist) + 0.5) or -1,
                    math.floor(bx + 0.5), math.floor(by + 0.5),
                    poolNear, poolBusy, poolOfficer, poolRecent,
                    tostring(recClaim), tostring(claimed > 0),
                    tostring(ordered > 0), ordered)
                dlogChange("RECOVERY", frame, aiName, recMsg, nil,
                    claimed > 0 or ordered > 0)
            end
            eff = nil
            local confirmed = false
            for _, c in pairs(cur) do
                if c.n >= P.confirmN then confirmed = true; break end
            end

            -- Tier 1: idle defenders -> Attack (nearest first, sevN per
            -- intruder). Holders keep their slots first (deterministic
            -- exact cap); newcomers fill the rest. Units holding THIS
            -- target pass the assigned filter (they are on this job, not
            -- busy elsewhere) — other role memories still exclude.
            local takenDef = {}
            for _, it in ipairs(intruders) do
                local airJob = isAirThreat(it)
                local cands = {}
                for _, u in ipairs(units) do
                    local ds0 = defenseState[u.id]
                    local holdingIt = ds0 and ds0.targetId == it.id
                        and frame - (ds0.orderedFrame or 0) < P.defenseEvery
                    -- Infantry drafts ONLY as AA vs air (FLAKT); all other
                    -- infantry stays out of the vehicle pool as before.
                    -- Bombers (ZEP/KIROV) never intercept: they are strike
                    -- assets, and ordering a Kirov onto a tank wastes it
                    -- (proven live: POINT_DEFENSE ZEP->HTNK while the base
                    -- waited). Jets (aircraft kind) were never eligible.
                    local kindOk = (u.k == "unit" and not AIR_RAIDERS[u.t])
                        or (airJob and u.k == "infantry" and AA_TYPES[u.t])
                    if u.oh == aiHouse and u.idle
                        and (not isOfficerAssigned(u.id) or holdingIt)
                        and not takenDef[u.id] and kindOk
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t] and not HERO_TYPES[u.t]
                        and u.hasPos then
                        local d2 = dist2(u.x, u.y, it.x, it.y)
                        if d2 <= sevAssignR * sevAssignR then
                            cands[#cands + 1] = { u = u, d2 = d2 }
                        end
                    end
                end
                table.sort(cands, function(a, b)
                    if airJob then
                        -- AA guns first vs air (a Rhino cannot hit a Kirov);
                        -- no-AA fallback keeps the old nearest order.
                        local aa, ab = AA_TYPES[a.u.t], AA_TYPES[b.u.t]
                        if (aa and true or false) ~= (ab and true or false) then
                            return (aa and true or false)
                        end
                    end
                    if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                    return a.u.id < b.u.id
                end)
                local assigned = 0
                for _, c in ipairs(cands) do
                    local ds = defenseState[c.u.id]
                    if ds and ds.targetId == it.id
                        and frame - (ds.orderedFrame or 0) < P.defenseEvery then
                        takenDef[c.u.id] = true -- holding: no re-issue
                        assigned = assigned + 1 -- holder covers the slot
                    end
                end
                for _, c in ipairs(cands) do
                    if not takenDef[c.u.id] and assigned < sevN then
                        -- DIAGNOSTIC: reuse the REAL results of the calls that
                        -- were going to happen anyway. tryClaim/orderAttack
                        -- are never invoked a second time just to measure, and
                        -- the short-circuit is preserved: orderAttack runs
                        -- only when the claim succeeded, exactly as
                        -- `tryClaim(...) and orderAttack(...)` did, so an
                        -- orderFail is only ever counted for an order that was
                        -- actually attempted.
                        local claimed = tryClaim(c.u.id, "DEFENSE")
                        local ordered = claimed and orderAttack(c.u, it.u,
                            "OFFICER", "POINT_DEFENSE", "intruder response",
                            string.format("target=%s type=%s", tostring(it.id), tostring(it.t)))
                        if c4diag and c4d then
                            local a2 = c4d.act
                            if not claimed then
                                if not a2.claimIds[c.u.id] then
                                    a2.claimIds[c.u.id] = true
                                    a2.claimDenied = a2.claimDenied + 1
                                end
                            elseif not ordered then
                                if not a2.orderIds[c.u.id] then
                                    a2.orderIds[c.u.id] = true
                                    a2.orderFail = a2.orderFail + 1
                                end
                            end
                        end
                        if claimed and ordered then
                                    defenseState[c.u.id] = {
                                        targetId = it.id, orderedFrame = frame,
                                        -- M2-C4: the owning house, so the
                                        -- end-of-Update episode resolution
                                        -- can credit the win/loss to the
                                        -- right ledger.
                                        house = aiHouse,
                                    }
                                    -- Phase 1 (exclusive ownership): the
                                    -- SetTarget hook vetoes foreign re-tasks
                                    -- of this unit while leased. Nil-guarded:
                                    -- harnesses and hook-inactive builds run
                                    -- unleashed (pure vanilla + readback).
                                    if TargetLease then
                                        TargetLease.Acquire(c.u.u, it.u)
                                    end
                            takenDef[c.u.id] = true
                            assigned = assigned + 1
                            diagOrder(frame, "POINT_DEFENSE", c.u, "Attack",
                                string.format("target=%s type=%s", tostring(it.id), tostring(it.t)))
                            local actual = readbackTargetId(c.u.u)
                            dlog("READBACK", frame, string.format(
                                "unit=%s expected_target=%s actual_target=%s match=%s",
                                tostring(c.u.id), tostring(it.id), tostring(actual),
                                tostring(actual == it.id)))
                            if actual ~= nil and actual ~= it.id then
                                dlog("READBACK_MISMATCH", frame, string.format(
                                    "unit=%s expected_target=%s actual_target=%s",
                                    tostring(c.u.id), tostring(it.id), tostring(actual)))
                                divLogged[c.u.id] = actual
                            end
                        end
                    end
                end
                if assigned > 0 then
                    local alert = string.format(
                        "[AI Commander - %s] Base defense: %d defender(s) on %s#%s!",
                        tostring(aiName), assigned, tostring(it.t), tostring(it.id))
                    Engine.PrintMessage(alert)
                    print("[LuaAPI] " .. alert)
                end
            end

            -- Tier 2: confirmed intrusion pulls marching ground units home.
            if confirmed and P.marchRecall then
                for _, u in ipairs(units) do
                    -- Log naval units that ground recall would otherwise pull
                    -- home (diagnostic only, fires once per unit per scan).
                    if u.oh == aiHouse and not u.idle and u.attacking == false
                        and u.k == "unit"
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t]
                        and not typeIn({SUB=true,HYD=true,DRED=true,AEGIS=true,DLPH=true,BSUB=true,DEST=true,LCRF=true,SAPC=true,SQD=true,VLAD=true,YHVR=true,CRUISE=true,TUG=true,CDEST=true}, u.t)
                        and not isOfficerAssigned(u.id) and u.hasPos
                        and dist2(u.x, u.y, bx, by) > RECALL_FAR * RECALL_FAR then
                        dlog("RECALL_SKIP_NAVAL", frame, string.format(
                            "house=%s unit=%s type=%s reason=NAVAL_UNIT pos=%d,%d",
                            tostring(aiName), tostring(u.id), tostring(u.t),
                            u.x, u.y))
                    end
                    if u.oh == aiHouse and not u.idle and u.attacking == false
                        and u.k == "unit"
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t]
                        and not typeIn({SUB=true,HYD=true,DRED=true,AEGIS=true,DLPH=true,BSUB=true,DEST=true,LCRF=true,SAPC=true,SQD=true,VLAD=true,YHVR=true,CRUISE=true,TUG=true,CDEST=true}, u.t)
                        and not isOfficerAssigned(u.id) and u.hasPos
                        and dist2(u.x, u.y, bx, by) > RECALL_FAR * RECALL_FAR then
                        local rs = recallState[u.id]
                        if not rs or frame - rs.orderedFrame >= P.redirectEvery then
                            if tryClaim(u.id, "MARCH")
                                and orderMove(u, math.floor(bx + 0.5), math.floor(by + 0.5),
                                    "OFFICER", "DEFENSE_MARCH_RECALL", "confirmed intrusion",
                                    string.format("dest=%d,%d", math.floor(bx + 0.5), math.floor(by + 0.5))) then
                                recallState[u.id] = { orderedFrame = frame }
                                diagOrder(frame, "MARCH_RECALL", u, "MoveTo",
                                    string.format("reason=CONFIRMED_INTRUSION dest=%d,%d",
                                        math.floor(bx + 0.5), math.floor(by + 0.5)))
                                local alert = string.format(
                                    "[AI Commander - %s] Base under attack: recalling %s#%s home!",
                                    tostring(aiName), tostring(u.t), tostring(u.id))
                                Engine.PrintMessage(alert)
                                print("[LuaAPI] " .. alert)
                            end
                        end
                    end
                end
            end

            -- Divergence watch (diagnostic only: never re-orders). For each
            -- live defender, compare the commanded target against the
            -- engine's reported target; log only on new divergence.
            -- The CTX line adds cause evidence WITHOUT new behavior:
            -- expected/actual liveness (dead expected = natural completion),
            -- actual identity, defender mission (existing GetMission), and
            -- whether SmartAI itself re-issued to this unit since.
            for did, ds in pairs(defenseState) do
                local def = findSnap(units, did)
                if def and def.oh == aiHouse then
                    local actual = readbackTargetId(def.u)
                    if actual ~= nil and actual ~= ds.targetId then
                        local expE = findSnap(units, ds.targetId)
                        if divLogged[did] ~= actual then
                            divLogged[did] = actual
                            dlog("TARGET_DIVERGENCE", frame, string.format(
                                "unit=%s commanded=%s actual=%s",
                                tostring(did), tostring(ds.targetId), tostring(actual)))
                            local actE = findSnap(units, actual)
                            local okM, mission = pcall(def.u.GetMission, def.u)
                            dlog("TARGET_DIVERGENCE_CTX", frame, string.format(
                                "unit=%s owner=%s type=%s commanded=%s expAlive=%s actual=%s actAlive=%s actType=%s actKind=%s actOwner=%s mission=%s reissue=%s",
                                tostring(did), tostring(def.on), tostring(def.t),
                                tostring(ds.targetId), tostring(expE ~= nil),
                                tostring(actual), tostring(actE ~= nil),
                                tostring(actE and actE.t), tostring(actE and actE.k),
                                tostring(actE and actE.on),
                                (okM and mission ~= nil) and tostring(mission) or "nil",
                                lastSmartAIOrder(did, ds.orderedFrame)))
                        end
                        -- Lease-lite: re-assert a live commanded target the
                        -- vanilla AI yanked (bounded), then release it.
                        -- Runs EVERY diverged scan (not just newly logged).
                        if expE and (ds.retries or 0) < LEASE_RETRIES
                            and frame - (ds.orderedFrame or 0) >= LEASE_RETRY_EVERY
                            and lastSmartAIOrder(did, ds.orderedFrame) == "none"
                            and tryClaim(did, "LEASE")
                            and orderAttack(def, expE.u, "OFFICER", "DEFENSE_LEASE",
                                "target reassert",
                                string.format("commanded=%s retry=%d", tostring(ds.targetId), tostring((ds.retries or 0) + 1))) then
                            ds.orderedFrame = frame
                            ds.retries = (ds.retries or 0) + 1
                            dlog("LEASE_REASSERT", frame, string.format(
                                "unit=%s commanded=%s retry=%d",
                                tostring(did), tostring(ds.targetId), ds.retries))
                        elseif expE and (ds.retries or 0) >= LEASE_RETRIES
                            and not ds.released then
                            ds.released = true
                            dlog("LEASE_RELEASED", frame, string.format(
                                "unit=%s commanded=%s reason=RETRIES_EXHAUSTED",
                                tostring(did), tostring(ds.targetId)))
                        end
                    elseif actual == ds.targetId then
                        divLogged[did] = nil
                    end
                end
            end
        else
            intruderSeen[aiHouse] = nil
        end
        -- C4 detector diagnostic emit (DIAGNOSTIC ONLY). Single call site,
        -- after the #home branch, so NO_HOME_BUILDINGS and the ordinary
        -- funnel are reported the same way. Bounded to one line plus one
        -- sample line per house per SMARTAI_CENSUS_EVERY frames.
        if c4diag and c4d then
            -- QUIET (KEEP/QUIET/CUT): C4DIAG_SAMPLE merged into C4DIAG
            -- (user-approved CUT of the duplicate channel). Samples ride
            -- as a suffix; the on-change signal is the funnel (base)
            -- line, since samples carry positions that wiggle every gate.
            local c4base = c4diagLine(frame, aiName, c4d)
            local c4msg = c4base
            if #c4d.samples > 0 then
                c4msg = c4msg .. " samples=" .. #c4d.samples .. " | "
                    .. table.concat(c4d.samples, " | ")
            end
            dlogChange("C4DIAG", frame, aiName, c4msg, c4base)
            -- M2-C4 ADAPT: the feedback loop's own state, so Act -> Observe
            -- result -> Adapt is legible in one line: what the house has
            -- won/lost, the streak that arms the adaptation, and whether the
            -- adaptation is currently allowed to pull.
            local e3 = dEff[aiHouse]
            local st3 = (e3 and e3.streak) or 0
    dlogChange("ADAPTSTATE", frame, aiName, string.format(
        "house=%s w=%d l=%d streak=%d armed=%s adaptUntil=%d "
            .. "totW=%d totL=%d totDraw=%d totPulls=%d totDenied=%d totRecovery=%d",
        tostring(aiName),
        (e3 and e3.w) or 0, (e3 and e3.l) or 0, st3,
        tostring(st3 >= ADAPT_STREAK_TRIGGER),
        (e3 and e3.adaptUntil) or 0,
        dEffStats.w, dEffStats.l, dEffStats.draw, dEffStats.pulls,
        dEffStats.denied, dEffStats.recovery))
        end
        ::next_defense::
    end
    end -- P.defense

    -- CAPTURE-ASSET DEFENSE: idle defenders intercept hostiles near owned
    -- capturable assets (airport/oil derrick/...). Mirrors point-defense Tier 1
    -- but scoped to owned assets; shares the DEFENSE claim site and the
    -- defenseState end-of-tick win/loss resolution so a unit is never double-
    -- ordered and a resolved contact feeds the adaptation ledger.
    -- CAPTURE-ASSET DEFENSE: idle defenders intercept hostiles near owned
    -- capturable assets (airport/oil derrick/...). Shares the DEFENSE claim
    -- site and the defenseState end-of-tick win/loss resolution so a unit is
    -- never double-ordered and a resolved contact feeds the adaptation ledger.
    captureAssetDefense(frame, aiHouses, units, buildingsById, allied, tryClaim)
    captureAssetGuard(frame, aiHouses, units, buildingsById, tryClaim)
    captureAssetRecapture(frame, aiHouses, units, buildingsById, tryClaim)

    -- Commander + Officer share this scan (no extra World calls).
    -- Split: Commander takes base defense, Officer takes unit escort.
    -- Radiation interplay: one read per tick (nil unless the radiation
    -- mod is loaded and warning/active with targets).
    local radPhase, radTargets, radRadius = radiationStatus()
    local v3ids, defids = {}, {}
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_officer end -- Phase 1: silence
        local aiName = aiHouse:GetName()
        local ownUnits, ownBlds = {}, {}
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "unit" then
                ownUnits[#ownUnits + 1] = e
            end
        end
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse then
                ownBlds[#ownBlds + 1] = b
            end
        end

        if P.hero then
        -- OFFICER: heroes (all presets). A hero the vanilla AI built is
        -- irreplaceable firepower that Tier-1 would feed man-for-man, so
        -- HERO runs FIRST in the Officer loop and holds every live hero
        -- (heroState => isOfficerAssigned => all other layers stand off;
        -- garrison additionally excludes HERO_TYPES by kind filter).
        -- Easy hunts nothing: leash 8 makes it a base bodyguard reacting
        -- to adjacent threats. Medium hunts priority targets inside the
        -- leash. Hard adds retreat at low HP + focus (no flip-flop).
        -- Transition-only + per-preset cooldown; refresh re-issues the
        -- same target (cheap yank-resistance: heroes carry no lease).
        -- Never chases beyond the leash, never orders dead targets.
        local anchorX, anchorY, anchorId = nil, nil, nil
        for _, b in ipairs(ownBlds) do
            if b.hasPos and (anchorId == nil or b.id < anchorId) then
                anchorId, anchorX, anchorY = b.id, b.x, b.y
            end
        end
        if anchorX then
        local leash2 = P.heroLeash * P.heroLeash
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "infantry" and e.hasPos
                and HERO_TYPES[e.t] then
                local mem = heroState[e.id]
                local hpFrac = (e.maxhp and e.maxhp > 0)
                    and (e.hp or e.maxhp) / e.maxhp or 1.0
                -- Hard retreat: bleeding hero falls back to the anchor.
                -- Resume is threat-gated below (no medic exists to heal).
                if P.heroRetreat and hpFrac < HERO_RETREAT_HP
                    and (not mem or mem.posture ~= "retreat") then
                    if tryClaim(e.id, "HERO")
                        and orderMove(e, anchorX, anchorY, "OFFICER", "HERO",
                            "bleeding retreat",
                            string.format("dest=%d,%d hpf=%.2f", anchorX, anchorY, hpFrac)) then
                        heroState[e.id] = { targetId = nil,
                            orderedFrame = frame, posture = "retreat" }
                        diagOrder(frame, "HERO", e, "MoveTo",
                            string.format("dest=%d,%d reason=BLEEDING hpf=%.2f",
                                anchorX, anchorY, hpFrac))
                    end
                else
                    local inRetreat = mem and mem.posture == "retreat"
                    local threatNear = false
                    if inRetreat then
                        for _, u in ipairs(units) do
                            if u.oh and u.oh ~= aiHouse
                                and not allied(aiHouse, u.oh)
                                and not util.is_neutral_house(u.oh)
                                and not util.CIVIL_TYPES[u.t] and u.hasPos
                                and (u.k == "unit" or u.k == "infantry")
                                and dist2(u.x, u.y, e.x, e.y) <= 225 then
                                threatNear = true
                                break
                            end
                        end
                    end
                    if not (inRetreat and threatNear) then
                        -- Score hostiles inside the anchor leash (shared
                        -- heroBaseValue: scan and focus-keep cannot drift).
                        local scored = {}
                        for _, u in ipairs(units) do
                            if u.oh and u.oh ~= aiHouse
                                and not allied(aiHouse, u.oh)
                                and not util.is_neutral_house(u.oh)
                                and not util.CIVIL_TYPES[u.t] and u.hasPos then
                                local isBld = u.k == "building"
                                if (u.k == "unit" or u.k == "infantry"
                                        or (isBld and e.t ~= "YURIPR"))
                                    and dist2(u.x, u.y, anchorX, anchorY)
                                        <= leash2 then
                                    local v = heroBaseValue(e.t, u)
                                    if v then
                                        scored[#scored + 1] = { u = u, v = v,
                                            d2 = dist2(u.x, u.y, e.x, e.y) }
                                    end
                                end
                            end
                        end
                        table.sort(scored, function(a, b)
                            if a.v ~= b.v then return a.v > b.v end
                            if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                            return a.u.id < b.u.id
                        end)
                        local best = scored[1]
                        -- Hard focus: keep finishing the current target
                        -- unless something clearly better shows up.
                        if best and mem and mem.targetId
                            and P.heroRetreat then
                            local cur = unitsById[mem.targetId]
                                or buildingsById[mem.targetId]
                            if cur and cur.hasPos then
                                local curV = heroBaseValue(e.t, cur)
                                if curV and best.u.id ~= mem.targetId
                                    and best.v < curV + HERO_FOCUS_GAP then
                                    best = { u = cur, v = curV, d2 = 0 }
                                end
                            end
                        end
                        if best then
                            local same = mem and mem.targetId == best.u.id
                            if (not same or frame - (mem.orderedFrame or 0)
                                    >= P.heroEvery) then
                                -- best.u is a SNAPSHOT; the order needs the
                                -- engine object (convention: orderAttack
                                -- takes e.u-style userdata with GetId —
                                -- passing the snapshot silently fails).
                                if tryClaim(e.id, "HERO")
                                    and orderAttack(e, best.u.u, "OFFICER", "HERO",
                                        "priority target",
                                        string.format("target=%s type=%s value=%.1f",
                                            tostring(best.u.id), tostring(best.u.t), best.v)) then
                                    heroState[e.id] = {
                                        targetId = best.u.id,
                                        orderedFrame = frame,
                                        posture = "hunt",
                                    }
                                    diagOrder(frame, "HERO", e, "Attack",
                                        string.format(
                                            "target=%s type=%s value=%.1f%s",
                                            tostring(best.u.id),
                                            tostring(best.u.t), best.v,
                                            same and " refresh" or ""))
                                end
                            end
                        elseif not mem then
                            heroState[e.id] = { targetId = nil,
                                orderedFrame = frame, posture = "hold" }
                        end
                    end
                end
            end
        end
        end -- anchor present
        end -- P.hero

        if P.escort then
        -- OFFICER: escort for own artillery (units business).
        local taken = {}
        for _, e in ipairs(ownUnits) do
            if ARTILLERY_TYPES[e.t] then
                if e.hasPos then
                    v3ids[e.id] = true
                    local st = escortState[e.id]
                    if not st then
                        st = { guards = {}, ax = e.x, ay = e.y, orderedFrame = 0,
                               houseName = aiName, typename = e.t }
                        escortState[e.id] = st
                    end
                    -- Commander priority (blackboard, previous scan): a V3
                    -- inside an active breach sector rallies with the base;
                    -- escort stands down, hygiene releases + logs below.
                    local br = cmdState[aiHouse]
                    local standDown = br and frame - br.frame < 120
                        and dist2(e.x, e.y, br.x, br.y) <= 225
                    st.standDown = standDown or nil
                    local live = {}
                    for _, gid in ipairs(st.guards) do
                        local g = findSnap(units, gid)
                        -- Retained while alive + still ours, even when
                        -- fighting: the old `g.idle` filter forgot a guard
                        -- the moment it engaged, so a V3 under attack kept
                        -- losing its detail exactly when it needed it.
                        if g and g.oh == aiHouse then
                            live[#live + 1] = gid
                            taken[gid] = true
                        end
                    end
                    st.guards = live
                    local moved = dist2(e.x, e.y, st.ax, st.ay)
                        > ESCORT_RADIUS * ESCORT_RADIUS
                    local need = ESCORT_N - #live
                    if not st.standDown
                        and (need > 0 or moved or frame - st.orderedFrame >= ESCORT_EVERY) then
                        local cands = {}
                        for _, c in ipairs(ownUnits) do
                            -- Idle first; marching-but-not-fighting fills the
                            -- rest (same strictness as march recall and the
                            -- raid fix: live the idle pool is 0, so an
                            -- idle-only detail starves). Actually fighting
                            -- (attacking == true) is never yanked; unknown
                            -- attack state (nil, old DLL) means skip.
                            if c.id ~= e.id and not taken[c.id]
                                and (c.idle or c.attacking == false)
                                and not isOfficerAssigned(c.id)
                                and not HARVESTER_TYPES[c.t] and not MCV_TYPES[c.t]
                                and not ARTILLERY_TYPES[c.t] and c.hasPos then
                                local d2 = dist2(c.x, c.y, e.x, e.y)
                                if d2 <= ESCORT_DRAFT_RADIUS * ESCORT_DRAFT_RADIUS then
                                    cands[#cands + 1] = { c = c, d2 = d2 }
                                end
                            end
                        end
                        table.sort(cands, function(a, b)
                            if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                            return a.c.id < b.c.id
                        end)
                        local added = 0
                        for i = 1, math.min(need > 0 and need or #live, #cands) do
                            local g = cands[i].c
                            if need > 0 then
                                if tryClaim(g.id, "ESCORT") and orderMove(g, e.x, e.y,
                                    "OFFICER", "ESCORT", "bodyguard draft",
                                    string.format("principal=%s type=%s",
                                        tostring(e.id), tostring(e.t))) then
                                    st.guards[#st.guards + 1] = g.id
                                    taken[g.id] = true
                                    added = added + 1
                                    need = need - 1
                                    diagOrder(frame, "ESCORT", g, "MoveTo",
                                        string.format("principal=%s type=%s",
                                            tostring(e.id), tostring(e.t)))
                                end
                            end
                        end
                        if need <= 0 and #live > 0 and added == 0 then
                            -- Follow refresh: V3 moved or cap elapsed, guards hold.
                            -- Fighting guards are NOT pulled back here: a
                            -- refresh MoveTo on a guard mid-intercept would
                            -- yank it off its target (same rule as drafting).
                            local held = {}
                            for _, gid in ipairs(live) do
                                local g = findSnap(units, gid)
                                if g and (g.idle or g.attacking == false)
                                    and orderMove(g, e.x, e.y,
                                        "OFFICER", "ESCORT_REFRESH", "position refresh",
                                        string.format("principal=%s", tostring(e.id))) then
                                    held[#held + 1] = tostring(gid)
                                end
                            end
                            if #held > 0 then
                                dlog("ORDER", frame, string.format(
                                    "site=ESCORT_REFRESH principal=%s guards=%s",
                                    tostring(e.id), table.concat(held, ",")))
                            end
                        end
                        if added > 0 or moved then
                            st.ax, st.ay, st.orderedFrame = e.x, e.y, frame
                            -- HUD only on real change: a moved V3 with no new
                            -- guards spammed "+0 bodyguard(s)" every refresh
                            -- live (noise, no information).
                            if added > 0 then
                                local alert = string.format(
                                    "[AI Commander - %s] %s#%s escort +%d bodyguard(s).",
                                    tostring(aiName), tostring(e.t), tostring(e.id), added)
                                Engine.PrintMessage(alert)
                                print("[LuaAPI] " .. alert)
                            end
                        elseif #live > 0 then
                            st.orderedFrame = frame
                        end
                    end
                    -- BODYGUARD COMBAT + V3 KITE (same tick, same snapshot).
                    -- Guards focus the nearest threat to the principal;
                    -- the V3 steps off when the threat is inside the inner
                    -- ring. Skipped on stand-down (breach owns the units)
                    -- and when surrender silences the house (outer gate).
                    if not st.standDown then
                        local threats = {}
                        for _, u in ipairs(units) do
                            if u.oh and u.oh ~= aiHouse
                                and not allied(aiHouse, u.oh)
                                and not util.is_neutral_house(u.oh)
                                and not util.CIVIL_TYPES[u.t] and u.hasPos
                                and (u.k == "unit" or u.k == "infantry") then
                                local d2 = dist2(u.x, u.y, e.x, e.y)
                                if d2 <= ESCORT_COMBAT_R * ESCORT_COMBAT_R then
                                    threats[#threats + 1] = { u = u, d2 = d2 }
                                end
                            end
                        end
                        if #threats > 0 then
                            table.sort(threats, function(a, b)
                                if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                                return a.u.id < b.u.id
                            end)
                            local prime = threats[1]
                            st.combat = st.combat or {}
                            for _, gid in ipairs(st.guards) do
                                local g = findSnap(units, gid)
                                if g and (g.idle or g.attacking == false)
                                    and frame - (st.combat[gid] or -ESCORT_COMBAT_EVERY)
                                        >= ESCORT_COMBAT_EVERY then
                                    if tryClaim(gid, "ESCORT")
                                        and orderAttack(g, prime.u.u, "OFFICER", "ESCORT_INTERCEPT",
                                            "principal threat",
                                            string.format("principal=%s threat=%s type=%s d2=%d",
                                                tostring(e.id),
                                                tostring(prime.u.id),
                                                tostring(prime.u.t),
                                                math.floor(prime.d2))) then
                                        st.combat[gid] = frame
                                        diagOrder(frame, "ESCORT_INTERCEPT", g,
                                            "Attack", string.format(
                                                "principal=%s threat=%s type=%s d2=%d",
                                                tostring(e.id),
                                                tostring(prime.u.id),
                                                tostring(prime.u.t),
                                                math.floor(prime.d2)))
                                        -- Readback (measurement only, no
                                        -- divLogged: that table feeds the
                                        -- defense lease, which must not see
                                        -- escort targets).
                                        local actual = readbackTargetId(g.u)
                                        if actual ~= nil
                                            and actual ~= prime.u.id then
                                            dlog("READBACK_MISMATCH", frame,
                                                string.format(
                                                    "unit=%s expected_target=%s actual_target=%s",
                                                    tostring(gid),
                                                    tostring(prime.u.id),
                                                    tostring(actual)))
                                        end
                                    end
                                end
                            end
                            if prime.d2 <= V3_KITE_R * V3_KITE_R
                                and frame - (st.kiteFrame or -V3_KITE_EVERY)
                                    >= V3_KITE_EVERY then
                                local dx, dy = e.x - prime.u.x, e.y - prime.u.y
                                local L = math.sqrt(dx * dx + dy * dy)
                                if L < 0.001 then dx, dy = 1, 0
                                else dx, dy = dx / L, dy / L end
                                local kx = math.floor(e.x + dx * V3_KITE_DIST + 0.5)
                                local ky = math.floor(e.y + dy * V3_KITE_DIST + 0.5)
                                local bx, by, bn = 0, 0, 0
                                for _, b in ipairs(ownBlds) do
                                    if b.hasPos then
                                        bx, by, bn = bx + b.x, by + b.y, bn + 1
                                    end
                                end
                                if bn > 0 then
                                    -- Kite INTO the own lines: midpoint of the
                                    -- away-point and the base centroid.
                                    kx = math.floor((kx + bx / bn) / 2 + 0.5)
                                    ky = math.floor((ky + by / bn) / 2 + 0.5)
                                end
                                if tryClaim(e.id, "ESCORT")
                                    and orderMove(e, kx, ky, "OFFICER", "ESCORT_KITE",
                                        "v3 kite",
                                        string.format("dest=%d,%d threat=%s type=%s",
                                            kx, ky, tostring(prime.u.id),
                                            tostring(prime.u.t))) then
                                    st.kiteFrame = frame
                                    st.ax, st.ay = kx, ky
                                    diagOrder(frame, "ESCORT_KITE", e, "MoveTo",
                                        string.format("dest=%d,%d threat=%s type=%s",
                                            kx, ky, tostring(prime.u.id),
                                            tostring(prime.u.t)))
                                    -- HUD, throttled per principal: a kiting
                                    -- V3 is exactly the visible "AI reacts"
                                    -- moment. Intercepts stay log-only
                                    -- (150f cadence would spam).
                                    if frame - (kiteHud[e.id] or -900) >= 900 then
                                        kiteHud[e.id] = frame
                                        local alert = string.format(
                                            "[AI Commander - %s] %s#%s "
                                            .. "falling back from threat!",
                                            tostring(aiName), tostring(e.t),
                                            tostring(e.id))
                                        Engine.PrintMessage(alert)
                                        print("[LuaAPI] " .. alert)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        end -- P.escort

        if P.garrison then
        -- COMMANDER: garrison for own defenses (base business; EXPERIMENTAL).
        for _, e in ipairs(ownBlds) do
            if typeIn(DEFENSE_TYPES, e.t) then
                defids[e.id] = true
                local gs = garrisonState[e.id]
                if e.hasPos and (not gs or frame - gs.orderedFrame >= GARRISON_EVERY) then
                    -- Holders first: previously sent units still alive,
                    -- idle and on the cell hold their slots (no re-issue),
                    -- and so does any unrecorded squatter already there —
                    -- otherwise every refresh re-spams orders onto a held
                    -- cell (live: ~250 orders/match, nearly all no-ops).
                    local held, heldSet = {}, {}
                    for _, gid in ipairs((gs and gs.ids) or {}) do
                        local g = findSnap(units, gid)
                        if g and g.idle and g.hasPos
                            and dist2(g.x, g.y, e.x, e.y)
                                <= GARRISON_REACHED_R2 then
                            held[#held + 1] = gid
                            heldSet[gid] = true
                        end
                    end
                    for _, u in ipairs(units) do
                        if u.k == "infantry" and u.idle and u.oh == aiHouse
                            and u.hasPos and not heldSet[u.id]
                            and not HERO_TYPES[u.t] -- heroes never garrison
                            and dist2(u.x, u.y, e.x, e.y)
                                <= GARRISON_REACHED_R2 then
                            held[#held + 1] = u.id
                            heldSet[u.id] = true
                        end
                    end
                    local need = GARRISON_N - #held
                    local cands = {}
                    if need > 0 then
                    for _, u in ipairs(units) do
                        if u.k == "infantry" and u.idle and u.oh == aiHouse and u.hasPos
                            and not heldSet[u.id] and not HERO_TYPES[u.t] then
                            local d2 = dist2(u.x, u.y, e.x, e.y)
                            if d2 <= GARRISON_RADIUS * GARRISON_RADIUS
                                and d2 > GARRISON_REACHED_R2 then
                                cands[#cands + 1] = { u = u, d2 = d2 }
                            end
                        end
                    end
                    end
                    table.sort(cands, function(a, b)
                        if a.d2 ~= b.d2 then return a.d2 < b.d2 end
                        return a.u.id < b.u.id
                    end)
                        local sent = 0
                        local sentIds = {}
                        for _, gid in ipairs(held) do sentIds[#sentIds + 1] = gid end
                        for i = 1, math.min(math.max(need, 0), #cands) do
                            local cu = cands[i].u
                            if tryClaim(cu.id, "GARRISON") and orderMove(cu, e.x, e.y,
                                "OFFICER", "GARRISON", "garrison screen",
                                string.format("dest=%d,%d building=%s type=%s",
                                    e.x, e.y, tostring(e.id), tostring(e.t))) then
                                sent = sent + 1
                                sentIds[#sentIds + 1] = cu.id
                                diagOrder(frame, "GARRISON", cu, "MoveTo",
                                    string.format("dest=%d,%d building=%s type=%s",
                                        e.x, e.y, tostring(e.id), tostring(e.t)))
                            end
                        end
                    if sent > 0 then
                        garrisonState[e.id] = { orderedFrame = frame, ids = sentIds }
                        local alert = string.format(
                            "[AI Commander - %s] GARRISON? %s (%d inf) -> %s#%s (experimental).",
                            tostring(aiName), tostring(e.t), sent,
                            tostring(e.t), tostring(e.id))
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                end
            end
        end
        end -- P.garrison
        if P.radevac and radPhase then
        -- RADEVAC: own infantry out of radiation-warned/burning cells.
        -- WARNING evacuates preemptively (radius + margin: the warning is
        -- the head-start); ACTIVE moves out whoever is still inside.
        -- Destination: nearest own building (garrison-or-screen, the
        -- player's own counterplay). MoveTo only; transition-only +
        -- per-unit cooldown + destination memory (no churn while the
        -- cloud sits on the same cells).
        local radR = radRadius
            + ((radPhase == "WARNING") and RADEVAC_WARN_MARGIN or 0)
        local radR2 = radR * radR
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "infantry" and e.hasPos
                and not RADEVAC_EXEMPT[e.t]
                and not util.CIVIL_TYPES[e.t]
                and (e.idle or e.attacking == false)
                and not isOfficerAssigned(e.id) then
                local inside = false
                for _, t in ipairs(radTargets) do
                    if type(t.x) == "number" and type(t.y) == "number"
                        and dist2(e.x, e.y, t.x, t.y) <= radR2 then
                        inside = true
                        break
                    end
                end
                if inside then
                    local mem = radEvacState[e.id]
                    if mem and frame - (mem.orderedFrame or 0) < RADEVAC_EVERY then
                        goto next_evac
                    end
                    local bb, bestD2, bestId
                    for _, b in ipairs(ownBlds) do
                        if b.hasPos then
                            local d2 = dist2(e.x, e.y, b.x, b.y)
                            if not bestD2 or d2 < bestD2
                                or (d2 == bestD2 and b.id < bestId) then
                                bb, bestD2, bestId = b, d2, b.id
                            end
                        end
                    end
                    if bb then
                        if mem and mem.bx == bb.x and mem.by == bb.y
                            and dist2(e.x, e.y, bb.x, bb.y)
                                <= RADEVAC_REACHED_R2 then
                            goto next_evac -- arrived: hold, don't re-issue
                        end
                        if tryClaim(e.id, "RADEVAC")
                            and orderMove(e, bb.x, bb.y, "OFFICER", "RADEVAC",
                                "radiation evacuation",
                                string.format("dest=%d,%d phase=%s", bb.x, bb.y, tostring(radPhase))) then
                            radEvacState[e.id] = {
                                orderedFrame = frame, bx = bb.x, by = bb.y,
                            }
                            diagOrder(frame, "RADEVAC", e, "MoveTo",
                                string.format(
                                    "dest=%d,%d phase=%s",
                                    bb.x, bb.y, tostring(radPhase)))
                            -- HUD, throttled: the player must SEE the AI
                            -- react to the warning (log-only smarts might
                            -- as well not exist). One banner per house per
                            -- ~15s max, no per-unit spam.
                            if frame - (radEvacHud[aiHouse] or -900) >= 900 then
                                radEvacHud[aiHouse] = frame
                                local alert = string.format(
                                    "[AI Commander - %s] Radiation %s: "
                                    .. "pulling infantry to cover!",
                                    tostring(aiName),
                                    tostring(radPhase))
                                Engine.PrintMessage(alert)
                                print("[LuaAPI] " .. alert)
                            end
                        end
                    end
                end
                ::next_evac::
            end
        end
        end -- P.radevac
        if P.miner then
        -- MINER OFFICER: idle war/chrono miners go back to work.
        -- An idle harvester earns nothing by definition (harvesting is
        -- not an idle mission), so kicking one cannot interrupt real
        -- work — workers are non-idle and never touched. Two sources,
        -- in order: (1) its OWN harvest anchor (resume via
        -- GetHarvestLocation, which reads Destination), unless the
        -- anchor sits at its own base (docked, not mining); (2) the
        -- nearest ACTIVE donor's field anchor (share the field; donor
        -- anchors at base are skipped for the same reason).
        -- HarvestAt only: no MoveTo/Hunt/Attack here, ever.
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "unit" and MINER_TYPES[e.t]
                and e.idle and e.hasPos
                and not officerHeldElsewhere(e.id) then
                local mem = minerState[e.id]
                if mem and frame - (mem.orderedFrame or 0) < MINER_EVERY then
                    goto next_miner
                end
                local function anchorIsField(loc)
                    if type(loc) ~= "table" then return nil end
                    if type(loc.x) ~= "number" or type(loc.y) ~= "number" then
                        return nil
                    end
                    for _, b in ipairs(ownBlds) do
                        if b.hasPos
                            and dist2(loc.x, loc.y, b.x, b.y)
                                <= MINER_BASE_R2 then
                            return nil -- docked, not a field
                        end
                    end
                    return loc.x, loc.y
                end
                local ax, ay
                do
                    local okA, loc = pcall(e.u.GetHarvestLocation, e.u)
                    if okA then ax, ay = anchorIsField(loc) end
                end
                if not ax then
                    local best, bestD2, bestId
                    for _, d in ipairs(units) do
                        if d.oh == aiHouse and d.k == "unit"
                            and MINER_TYPES[d.t] and not d.idle
                            and d.id ~= e.id and d.hasPos then
                            local okA, loc =
                                pcall(d.u.GetHarvestLocation, d.u)
                            if okA then
                                local lx, ly = anchorIsField(loc)
                                if lx then
                                    local d2 = dist2(e.x, e.y, lx, ly)
                                    if not bestD2 or d2 < bestD2
                                        or (d2 == bestD2 and d.id < bestId) then
                                        best, bestD2, bestId =
                                            { x = lx, y = ly }, d2, d.id
                                    end
                                end
                            end
                        end
                    end
                    if best then ax, ay = best.x, best.y end
                end
                if ax then
                    if mem and mem.ax == ax and mem.ay == ay
                        and dist2(e.x, e.y, ax, ay) <= MINER_REACHED_R2 then
                        goto next_miner -- already there: hold
                    end
                    if tryClaim(e.id, "MINER")
                        and orderHarvest(e, ax, ay, "OFFICER", "MINER",
                            "idle miner kick",
                            string.format("dest=%d,%d", ax, ay)) then
                        minerState[e.id] = {
                            orderedFrame = frame, ax = ax, ay = ay,
                        }
                        diagOrder(frame, "MINER", e, "HarvestAt",
                            string.format("dest=%d,%d", ax, ay))
                        -- HUD once per house per match: miner kicks recur
                        -- every 300f while idlers persist, so per-kick
                        -- banners would spam; one notice names the
                        -- behavior, the log carries the rest.
                        if not minerHud[aiHouse] then
                            minerHud[aiHouse] = true
                            local alert = string.format(
                                "[AI Commander - %s] Idle miners ordered "
                                .. "back to the fields.",
                                tostring(aiName))
                            Engine.PrintMessage(alert)
                            print("[LuaAPI] " .. alert)
                        end
                    end
                end
                ::next_miner::
            end
        end
        end -- P.miner
        ::next_officer::
    end

    -- NOTE: point-defense layer runs BEFORE the Officer layer (see above):
    -- home defense claims idle defenders before escort drafts bodyguards.

    -- COMMANDER acts (base): rally, working around Officer assignments.
    -- Same-breach memory: a persisting breach orders only FRESH reserves
    -- (units rallied already are remembered per spot, never re-spammed);
    -- a NEW breach position rallies immediately. Full re-rally to the same
    -- spot happens at most every rallyEvery frames (stale orders die live).
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_rally end -- Phase 1: silence
        local aiName = aiHouse:GetName()
        local breachedBuilding = pendingBreach[aiHouse]
        if breachedBuilding and breachedBuilding.hp ~= nil then
            local bPos = breachedBuilding.hasPos and
                { x = breachedBuilding.x, y = breachedBuilding.y } or nil
            if bPos then
                local rs = rallyState[aiHouse]
                local sameSpot = rs and rs.x == bPos.x and rs.y == bPos.y
                local ids = (sameSpot and rs.ids) or {}
                local capElapsed = not sameSpot
                    or (frame - (rs.frame or 0) >= P.rallyEvery)
                local ralliedCount = 0
                -- RALLYDIAG counters (diagnostic only). Every condition below
                -- is the original one, unchanged; the counters just record
                -- how far each candidate unit survived the pool filter so a
                -- missing RALLY_BREACH names the stage that stopped it.
                -- Short-circuit order preserved: dist2 is evaluated only for
                -- idle units, isOfficerAssigned only for idle+far ones.
                local dg = rallyDiag[aiHouse]
                if dg then
                    dg.sameSpot = not not sameSpot
                    dg.capElapsed = not not capElapsed
                    dg.since = (rs and (frame - (rs.frame or 0))) or 0
                end
                for _, u in ipairs(units) do
                    if u.oh == aiHouse and u.k == "unit" and u.hasPos
                        -- Unarmed construction/economy never rallies (live
                        -- 2026-10-01: an AMCV ordered into a breach; every
                        -- other layer already excludes these).
                        and not HARVESTER_TYPES[u.t]
                        and not MCV_TYPES[u.t] then
                        if dg then dg.poolOwn = dg.poolOwn + 1 end
                        if u.idle then
                            if dg then dg.poolIdle = dg.poolIdle + 1 end
                            if dist2(u.x, u.y, bPos.x, bPos.y) > 36.0 then
                                if dg then dg.poolFar = dg.poolFar + 1 end
                                if not isOfficerAssigned(u.id) then
                                    if dg then dg.poolFree = dg.poolFree + 1 end
                                    if capElapsed or not ids[u.id] then
                                        if dg then dg.poolFresh = dg.poolFresh + 1 end
                                        -- Command reserve tank to reinforce the
                                        -- threatened flank!
                                        -- MoveTo ONLY, no trailing Hunt (fixed
                                        -- 2026-09-28 via OpenTS): the mission
                                        -- queue is a single slot
                                        -- (MissionClass::Assign_Mission sets
                                        -- MissionQueue; YRpp MissionClass.h
                                        -- has one QueuedMission field), so a
                                        -- back-to-back Hunt overwrote the
                                        -- queued Move and the reserve hunted
                                        -- from place instead of rallying to
                                        -- the breach. Point defense above is
                                        -- the verified home-defense path
                                        -- (Attack).
                                        if tryClaim(u.id, "RALLY") then
                                            if dg then dg.claims = dg.claims + 1 end
                                            -- Tracked: the Hunt-fix follow-up
                                            -- needs GetMission readback on
                                            -- rally orders (did Move stick?).
                                            if orderMoveTracked(u, bPos.x, bPos.y,
                                                "RALLY", frame, "COMMANDER", "RALLY",
                                                "breach response",
                                                string.format("dest=%d,%d building=%s",
                                                    bPos.x, bPos.y,
                                                    dg and tostring(dg.bId) or "-")) then
                                                ralliedCount = ralliedCount + 1
                                                if dg then dg.orders = dg.orders + 1 end
                                                ids[u.id] = true
                                                diagOrder(frame, "RALLY_BREACH", u, "MoveTo",
                                                    string.format("dest=%d,%d", bPos.x, bPos.y))
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                rallyState[aiHouse] = { x = bPos.x, y = bPos.y, frame = frame, ids = ids }
                if ralliedCount > 0 then
                    local alert = string.format("\u{1F6A8} [AI Commander - %s] Flank breach at (%d,%d)! Rallied %d reserve tanks to counter-attack!",
                        aiName, bPos.x, bPos.y, ralliedCount)
                    Engine.PrintMessage(alert)
                    print("[LuaAPI] " .. alert)
                end
            end
            local bp = breachedBuilding.hasPos and
                { x = breachedBuilding.x, y = breachedBuilding.y } or nil
            if bp then
                cmdState[aiHouse] = { x = bp.x, y = bp.y, frame = frame }
                lastThreatFrame[aiHouse] = frame -- M2-C3 quiet gate input
            end
        else
            cmdState[aiHouse] = nil
        end
        -- RALLYDIAG (diagnostic only): name the stage of the rally causal
        -- chain that stopped, or confirm the order went out. Emitted inside
        -- the per-house loop (so it covers every non-surrendered house) on the
        -- same census cadence as the C4 diagnostics. A surrendered house is
        -- covered by C4PRESET state=OFF_SURRENDERED instead.
        --
        -- EXCEPTION: an order that actually went out is an EVENT, not a
        -- state, so it is logged UNTHROTTLED. Throttling it made 6 successful
        -- rallies produce zero ORDERED lines in a live match, and a grep for
        -- this tag then reads as "rally never fires" -- the reverse of the
        -- truth. Rallies are rare (single digits per match), so the volume is
        -- bounded anyway.
        local dg = rallyDiag[aiHouse]
        if dg and (frame % SMARTAI_CENSUS_EVERY) < P.scan then
            local why
            if not breachedBuilding then
                why = "NO_THREAT"
            elseif not breachedBuilding.hasPos then
                why = "NO_BPOS"
            elseif breachedBuilding.hp == nil then
                why = "NO_HP_FIELD"
            elseif dg.orders > 0 then
                why = "ORDERED"
            elseif dg.poolFresh == 0 then
                if dg.poolOwn == 0 then why = "POOL_NO_OWN_UNITS"
                elseif dg.poolIdle == 0 then why = "POOL_NONE_IDLE"
                elseif dg.poolFar == 0 then why = "POOL_ALL_AT_SPOT"
                elseif dg.poolFree == 0 then why = "POOL_ALL_ASSIGNED"
                else why = "COOLDOWN_NO_FRESH" end
            else
                why = "ORDER_FAILED"
            end
            -- QUIET (KEEP/QUIET/CUT): on-change + heartbeat. The empty
            -- line still proves "running with no candidate" (heartbeat),
            -- without repeating it every gate.
            dlogChange("RALLYDIAG", frame, aiName, string.format(
                "house=%s why=%s own=%d threatened=%d bld=%s type=%s d2=%d R2=%d "
                    .. "poolOwn=%d poolIdle=%d poolFar=%d poolFree=%d poolFresh=%d "
                    .. "claims=%d orders=%d sameSpot=%s capElapsed=%s since=%d",
                tostring(aiName), why, dg.own, dg.threatened,
                dg.bId > 0 and tostring(dg.bId) or "-", dg.bType,
                dg.bestD2, RALLY_THREAT_R2,
                dg.poolOwn, dg.poolIdle, dg.poolFar, dg.poolFree,
                dg.poolFresh, dg.claims, dg.orders,
                tostring(dg.sameSpot), tostring(dg.capElapsed), dg.since))
        end
        if dg and dg.orders > 0 then
            dlog("RALLYORDERED", frame, string.format(
                "house=%s bld=%s type=%s d2=%d orders=%d claims=%d poolFresh=%d",
                tostring(aiName), dg.bId > 0 and tostring(dg.bId) or "-",
                dg.bType, dg.bestD2, dg.orders, dg.claims, dg.poolFresh))
        end
        ::next_rally::
    end

    -- COMMANDER: base-threat recall (presence, not damage). Vanilla fires
    -- heavies on schedule with zero threat assessment; idle combat
    -- vehicles far from a threatened base come home (broadened from
    -- V3/Kirov-only: a parked enemy army must pull home every idle tank,
    -- not just artillery). Harvesters/MCVs are never recalled. Engaged
    -- units are never yanked — holding those needs an order lease.
    if P.recall then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_recall end -- Phase 1: silence
        local aiName = aiHouse:GetName()
        local bx, by, bn = 0, 0, 0
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.hasPos then
                bx, by, bn = bx + b.x, by + b.y, bn + 1
            end
        end
        if bn > 0 then
            bx, by = bx / bn, by / bn
            local hostiles = 0
            for _, u in ipairs(units) do
                if u.oh and u.oh ~= aiHouse and not allied(aiHouse, u.oh)
                    and not util.is_neutral_house(u.oh)
                    and not util.CIVIL_TYPES[u.t] and u.hasPos
                    and dist2(u.x, u.y, bx, by)
                        <= RECALL_THREAT_RADIUS * RECALL_THREAT_RADIUS then
                    hostiles = hostiles + 1
                end
            end
            if hostiles >= RECALL_THREAT_N then
                for _, u in ipairs(units) do
                    if u.oh == aiHouse and u.idle and u.hasPos then
                        local recallable = RECALL_TYPES[u.t]
                            or (u.k == "unit"
                                and not HARVESTER_TYPES[u.t]
                                and not MCV_TYPES[u.t])
                        if recallable and not isOfficerAssigned(u.id) then
                            if dist2(u.x, u.y, bx, by) > RECALL_FAR * RECALL_FAR then
                                local rs = recallState[u.id]
                                if not rs or frame - rs.orderedFrame >= RECALL_EVERY then
                                    if tryClaim(u.id, "RECALL")
                                        and orderMove(u, math.floor(bx + 0.5), math.floor(by + 0.5),
                                            "COMMANDER", "BASE_THREAT_RECALL", "base threat",
                                            string.format("hostiles=%d dest=%d,%d",
                                                hostiles, math.floor(bx + 0.5), math.floor(by + 0.5))) then
                                        recallState[u.id] = { orderedFrame = frame }
                                        diagOrder(frame, "IDLE_RECALL", u, "MoveTo",
                                            string.format("reason=BASE_THREAT_%d dest=%d,%d",
                                                hostiles, math.floor(bx + 0.5), math.floor(by + 0.5)))
                                        local alert = string.format(
                                            "[AI Commander - %s] Base threat (%d hostiles): recalling %s#%s home!",
                                            tostring(aiName), hostiles,
                                            tostring(u.t), tostring(u.id))
                                        Engine.PrintMessage(alert)
                                        print("[LuaAPI] " .. alert)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        ::next_recall::
    end
    end -- P.recall

    -- WAVE-SHEPHERD (M3 initiative protection, same P.recall family):
    -- vanilla attack waves march into prepared counters and feed (free
    -- kills the player counters by reflex). A marching-not-fighting AI
    -- group far from home facing overwhelming LOCAL strength is called
    -- off (MoveTo home): preserve, let vanilla mass bigger later, deny
    -- the free kill — the attack either comes back larger or not at
    -- all, and the player's reflex stops working. Fighting units are
    -- never yanked (no lease); officer roles stand off; structures
    -- are NOT counted as threat in v1 (mobiles decide fights).
    -- Claims "MARCH" (defense tier, like march-recall); shares
    -- recallState memory + RECALL_EVERY cadence with base-threat
    -- recall (one memory for "we sent this one home").
    if P.recall then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_shepherd end
        local aiName = aiHouse:GetName()
        local bx, by, bn = 0, 0, 0
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.hasPos then
                bx, by, bn = bx + b.x, by + b.y, bn + 1
            end
        end
        if bn == 0 then goto next_shepherd end
        bx, by = bx / bn, by / bn
        local announced = false
        for _, e in ipairs(units) do
            -- Log naval units that ground recall would otherwise pull home
            -- (diagnostic only, fires once per unit per scan).
            if e.oh == aiHouse and e.k == "unit" and e.hasPos
                and not e.idle and e.attacking == false
                and not HARVESTER_TYPES[e.t] and not MCV_TYPES[e.t]
                and not ARTILLERY_TYPES[e.t]
                and not typeIn({SUB=true,HYD=true,DRED=true,AEGIS=true,DLPH=true,BSUB=true,DEST=true,LCRF=true,SAPC=true,SQD=true,VLAD=true,YHVR=true,CRUISE=true,TUG=true,CDEST=true}, e.t)
                and dist2(e.x, e.y, bx, by) > WAVE_FAR * WAVE_FAR
                and not isOfficerAssigned(e.id) then
                dlog("RECALL_SKIP_NAVAL", frame, string.format(
                    "house=%s unit=%s type=%s reason=NAVAL_UNIT pos=%d,%d",
                    tostring(aiName), tostring(e.id), tostring(e.t),
                    e.x, e.y))
            end
            if e.oh == aiHouse and e.k == "unit" and e.hasPos
                and not e.idle and e.attacking == false
                and not HARVESTER_TYPES[e.t] and not MCV_TYPES[e.t]
                and not ARTILLERY_TYPES[e.t]
                and not typeIn({SUB=true,HYD=true,DRED=true,AEGIS=true,DLPH=true,BSUB=true,DEST=true,LCRF=true,SAPC=true,SQD=true,VLAD=true,YHVR=true,CRUISE=true,TUG=true,CDEST=true}, e.t)
                and dist2(e.x, e.y, bx, by) > WAVE_FAR * WAVE_FAR
                and not isOfficerAssigned(e.id) then
                local waveN = 0
                local waveVetN = 0 -- veterans/elites/T3 in the group
                for _, m in ipairs(units) do
                    if m.oh == aiHouse and m.k == "unit" and m.hasPos
                        and not m.idle and m.attacking == false
                        and not HARVESTER_TYPES[m.t]
                        and not MCV_TYPES[m.t]
                        and not ARTILLERY_TYPES[m.t]
                        and not typeIn({SUB=true,HYD=true,DRED=true,AEGIS=true,DLPH=true,BSUB=true,DEST=true,LCRF=true,SAPC=true,SQD=true,VLAD=true,YHVR=true,CRUISE=true,TUG=true,CDEST=true}, m.t)
                        and dist2(m.x, m.y, e.x, e.y)
                            <= WAVE_R * WAVE_R then
                        waveN = waveN + 1
                        if isPrecious(m) then
                            waveVetN = waveVetN + 1
                        end
                    end
                end
                if waveN >= WAVE_MIN then
                    local threatN = 0
                    for _, u in ipairs(units) do
                        if u.oh and u.oh ~= aiHouse
                            and not allied(aiHouse, u.oh)
                            and not util.is_neutral_house(u.oh)
                            and not util.CIVIL_TYPES[u.t] and u.hasPos
                            and (u.k == "unit" or u.k == "infantry"
                                or u.k == "aircraft") then
                            if dist2(u.x, u.y, e.x, e.y)
                                <= WAVE_THREAT_R * WAVE_THREAT_R then
                                threatN = threatN + 1
                            end
                        end
                    end
                    -- VALOR: a precious-led group (half+ veterans /
                    -- near-promotions / T3) is recalled at 2x, not 3x —
                    -- crack troops are not spent proving the counter real.
                    local doomMult = WAVE_DOOM_MULT
                    if waveVetN * 2 >= waveN then doomMult = 2 end
                    if threatN >= waveN * doomMult then
                        local rs = recallState[e.id]
                        if not rs
                            or frame - rs.orderedFrame >= RECALL_EVERY then
                            if tryClaim(e.id, "MARCH")
                                and orderMove(e, math.floor(bx + 0.5),
                                    math.floor(by + 0.5), "COMMANDER", "WAVE_SHEPHERD",
                                    "doomed wave",
                                    string.format("wave=%d threat=%d mult=%d dest=%d,%d",
                                        waveN, threatN, doomMult,
                                        math.floor(bx + 0.5),
                                        math.floor(by + 0.5))) then
                                recallState[e.id] = { orderedFrame = frame }
                                diagOrder(frame, "WAVE_RECALL", e, "MoveTo",
                                    string.format(
                                        "reason=DOOMED wave=%d threat=%d "
                                        .. "mult=%d dest=%d,%d",
                                        waveN, threatN, doomMult,
                                        math.floor(bx + 0.5),
                                        math.floor(by + 0.5)))
                                if not announced
                                    and frame - (waveHud[aiHouse] or -900)
                                        >= 900 then
                                    announced = true
                                    waveHud[aiHouse] = frame
                                    local alert = string.format(
                                        "[AI Commander - %s] Calling off "
                                        .. "doomed attack (%d vs %d): "
                                        .. "falling back!",
                                        tostring(aiName), waveN, threatN)
                                    Engine.PrintMessage(alert)
                                    print("[LuaAPI] " .. alert)
                                end
                            end
                        end
                    end
                end
            end
        end
        ::next_shepherd::
    end
    end -- P.recall shepherd

    -- M2-C1 BELIEF UPDATE (grudge slice): HP drops and kills of own
    -- economy with an enemy near are attributed to the nearest hostile
    -- and counted per (aiHouse, enemyHouse). Gated on P.raid: memory
    -- without a consumer decision path is not kept. Event + update share
    -- one throttled line (per-victim cooldown); repairs/new sightings
    -- only refresh the prev-tick store, never count.
    if P.raid then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_belief end
        local aiName = aiHouse:GetName()
        -- Per-house snapshot store. Created on first sight of the house so
        -- the disappearance-diff below can only ever see THIS house's
        -- economy (see econSeen decl for why the flat form was a bug).
        local store = econSeen[aiHouse]
        if not store then store = {}; econSeen[aiHouse] = store end
        local nowSeen = {}
        local pool = {}
        for _, u in ipairs(units) do pool[#pool + 1] = u end
        for _, b in ipairs(buildings) do pool[#pool + 1] = b end
        for _, e in ipairs(pool) do
            if e.oh == aiHouse and e.hasPos and isEconAsset(e) then
                nowSeen[e.id] = true
                local prev = store[e.id]
                if e.hp ~= nil and prev and prev.hp ~= nil and e.hp < prev.hp
                    and frame - (prev.eventFrame or 0) >= ECON_EVENT_EVERY then
                    -- Nearest hostile to the victim: attribution, else skip.
                    local culprit, culpritD2 = nil, nil
                    for _, u in ipairs(units) do
                        if u.oh and u.oh ~= aiHouse
                            and not allied(aiHouse, u.oh)
                            and not util.is_neutral_house(u.oh)
                            and not util.CIVIL_TYPES[u.t]
                            and DEFENSE_KINDS[u.k] and u.hasPos then
                            local d2 = dist2(e.x, e.y, u.x, u.y)
                            if d2 <= GRUDGE_ATTRIB_R * GRUDGE_ATTRIB_R
                                and (not culpritD2 or d2 < culpritD2) then
                                culprit, culpritD2 = u.oh, d2
                            end
                        end
                    end
                    if culprit then
                        local gh = grudge[aiHouse]
                        if not gh then gh = {}; grudge[aiHouse] = gh end
                        local g = gh[culprit]
                        if not g then g = { n = 0, lastFrame = 0 }; gh[culprit] = g end
                        g.n = g.n + 1
                        g.lastFrame = frame
                        prev.eventFrame = frame
                        local _, con = pcall(culprit.GetName, culprit)
                        dlog("BELIEF_EVENT", frame, string.format(
                            "house=%s victim=%s type=%s hp=%s->%s culprit=%s grudge=%d",
                            tostring(aiName), tostring(e.id), tostring(e.t),
                            tostring(prev.hp), tostring(e.hp),
                            tostring(con), math.min(g.n, GRUDGE_CAP)))
                    end
                end
                if e.hp ~= nil then
                    store[e.id] = {
                        hp = e.hp, x = e.x, y = e.y,
                        -- First sighting must not eat the cooldown: a drop
                        -- on the next scan is a real first event.
                        eventFrame = (prev and prev.eventFrame)
                            or -ECON_EVENT_EVERY,
                    }
                end
            end
        end
        -- ECON_KILLED: economy object gone with a hostile near its last pos.
        -- Iterates THIS house's store only. A flat shared store made every
        -- other house's intact economy report as "killed" here, every scan.
        for id, prev in pairs(store) do
            if not nowSeen[id] and prev.hp ~= nil and prev.eventFrame ~= nil then
                local culprit, culpritD2 = nil, nil
                for _, u in ipairs(units) do
                    if u.oh and u.oh ~= aiHouse
                        and not allied(aiHouse, u.oh)
                        and not util.is_neutral_house(u.oh)
                        and not util.CIVIL_TYPES[u.t]
                        and DEFENSE_KINDS[u.k] and u.hasPos and prev.x then
                        local d2 = dist2(prev.x, prev.y, u.x, u.y)
                        if d2 <= GRUDGE_ATTRIB_R * GRUDGE_ATTRIB_R
                            and (not culpritD2 or d2 < culpritD2) then
                            culprit, culpritD2 = u.oh, d2
                        end
                    end
                end
                if culprit and frame - prev.eventFrame >= ECON_EVENT_EVERY then
                    local gh = grudge[aiHouse]
                    if not gh then gh = {}; grudge[aiHouse] = gh end
                    local g = gh[culprit]
                    if not g then g = { n = 0, lastFrame = 0 }; gh[culprit] = g end
                    g.n = g.n + 1
                    g.lastFrame = frame
                    local _, con = pcall(culprit.GetName, culprit)
                    dlog("BELIEF_EVENT", frame, string.format(
                        "house=%s victim=%s type=killed culprit=%s grudge=%d",
                        tostring(aiName), tostring(id),
                        tostring(con), math.min(g.n, GRUDGE_CAP)))
                end
                store[id] = nil -- gone: prune either way (no leak)
            end
        end
        ::next_belief::
    end
    end -- P.raid belief

-- Raid value multiplier for candidates owned by a grudged house.
-- Returns mult + count (1.0 + 0 when no memory — decision unchanged).
-- Test-only inspector (harnesses only, no gameplay use): exposes the
-- M2-C1 belief tables so tests can assert memory without log scraping.
-- econSeen is nested per house (econSeen[house][id]); a caller that needs
-- the old flat id->snapshot view must iterate the per-house subtables.
-- Returns live tables — tests must read, never write.
function SmartAI.BeliefInspect()
    return grudge, econSeen
end

-- Test-only inspector (harnesses only): per-house stance assignment.
-- Returns live table — tests must read, never write.
function SmartAI.StanceInspect()
    local out = {}
    for h, s in pairs(stanceCache) do out[h] = s end
    return out
end

local function grudgeMult(aiHouse, candOwner)
    if not aiHouse or not candOwner then return 1.0, 0 end
    local gh = grudge[aiHouse]
    if not gh then return 1.0, 0 end
    local g = gh[candOwner]
    if not g or not g.n or g.n <= 0 then return 1.0, 0 end
    local n = math.min(g.n, GRUDGE_CAP)
    return 1.0 + GRUDGE_W * n, n
end

    -- RETALIATE (M14.1-line self-preservation, point-defense family):
    -- an AI combat unit losing HP while holding another target turns onto
    -- its assumed attacker (nearest hostile). Vanilla owns positioning;
    -- SmartAI corrects only the target (native Attack + readback), so the
    -- unit stays in combat instead of chasing choppers to death.
    -- Cooldown-gated (no re-issue inside the window), skips assigned
    -- roles and non-combat types. Gated on P.defense.
    if P.defense then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_retal end
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.k == "unit" and e.hasPos
                and not HARVESTER_TYPES[e.t] and not MCV_TYPES[e.t]
                and not ARTILLERY_TYPES[e.t]
                and not isOfficerAssigned(e.id) then
                local prev = combatSeen[e.id]
                local cur = e.hp
                if prev and prev.hp and cur and cur < prev.hp
                    and frame - (prev.retalFrame or -RETALIATE_EVERY)
                        >= RETALIATE_EVERY then
                    local okT, tgt = pcall(e.u.GetTarget, e.u)
                    local curTid = nil
                    if okT and tgt then
                        local okI, tid = pcall(tgt.GetId, tgt)
                        if okI then curTid = tid end
                    end
                    local culpE = nil
                    local culpD2 = nil
                    for _, u in ipairs(units) do
                        if u.oh and u.oh ~= aiHouse
                            and not allied(aiHouse, u.oh)
                            and not util.is_neutral_house(u.oh)
                            and not util.CIVIL_TYPES[u.t]
                            and (u.k == "unit" or u.k == "infantry"
                                or u.k == "aircraft")
                            and u.hasPos then
                            local d2 = dist2(e.x, e.y, u.x, u.y)
                            if d2 <= RETALIATE_R * RETALIATE_R
                                and (not culpD2 or d2 < culpD2) then
                                culpE, culpD2 = u, d2
                            end
                        end
                    end
                    if culpE and culpE.id ~= curTid
                        and tryClaim(e.id, "RETALIATE")
                        and orderAttack(e, culpE.u, "OFFICER", "RETALIATE",
                            "self-preservation",
                            string.format("was=%s now=%s culprit=%s readback=%s",
                                tostring(curTid), tostring(culpE.id),
                                tostring(culpE.t), tostring(actual))) then
                        prev.retalFrame = frame
                        local actual = readbackTargetId(e.u)
                        dlog("RETALIATE", frame, string.format(
                            "house=%s unit=%s type=%s was=%s now=%s culprit=%s readback=%s",
                            tostring(aiHouse:GetName()), tostring(e.id),
                            tostring(e.t), tostring(curTid),
                            tostring(culpE.id), tostring(culpE.t),
                            tostring(actual)))
                    end
                end
                if cur then
                    combatSeen[e.id] = {
                        hp = cur,
                        retalFrame = (prev and prev.retalFrame)
                            or -RETALIATE_EVERY,
                    }
                end
            end
        end
        ::next_retal::
    end
    end -- P.defense retaliate

    -- BOMBER FOCUS (user case 2026-09-25): an AI bomber holding a troop
    -- target while an enemy building sits within FOCUS_R ignores the
    -- troops and goes for the base (nearest enemy building). Cooldown per
    -- bomber, readback, arbiter-claimed. Skips assigned roles (a raider
    -- already on economy keeps it). Bombers never intercept as defenders
    -- (Tier-1 filter above) — this is their only SmartAI steering.
    local BOMBER_FOCUS_R = 25
    local BOMBER_FOCUS_EVERY = 300
    if P.defense or P.raid then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if surrendered[aiHouse] then goto next_focus end
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.hasPos
                and (AIR_RAIDERS[e.t] or e.k == "aircraft")
                and e.t ~= "V3"
                and not isOfficerAssigned(e.id) then
                local fs = focusState[e.id]
                if not fs or frame - (fs.orderedFrame or 0) >= BOMBER_FOCUS_EVERY then
                    local okT, tgt = pcall(e.u.GetTarget, e.u)
                    local curKind = nil
                    if okT and tgt then
                        local okK, kk = pcall(tgt.GetKind, tgt)
                        if okK then curKind = kk end
                    end
                    if curKind == "building" then goto next_bomber end
                    local best, bestD2 = nil, nil
                    for _, b in ipairs(buildings) do
                        if b.oh and b.oh ~= aiHouse
                            and not allied(aiHouse, b.oh)
                            and not util.is_neutral_house(b.oh)
                            and not util.CIVIL_TYPES[b.t] and b.hasPos then
                            local d2 = dist2(e.x, e.y, b.x, b.y)
                            if d2 <= BOMBER_FOCUS_R * BOMBER_FOCUS_R
                                and (not bestD2 or d2 < bestD2) then
                                best, bestD2 = b, d2
                            end
                        end
                    end
                    if best
                        and tryClaim(e.id, "FOCUS")
                        and orderAttack(e, best.u, "OFFICER", "BOMBER_FOCUS",
                            "building focus",
                            string.format("target=%s type=%s was=%s",
                                tostring(best.id), tostring(best.t),
                                tostring(curKin))) then
                        SmartAI.logTargetEval(
                            tostring(aiName), "bomber_focus", tostring(aiHouse and aiHouse:GetName() or "-"),
                            tostring(best.id), tostring(best.t), tostring(best.on and best.on or "-"),
                            true, "BEST_VALUE", tostring(curKind),
                            string.format("dist=%s", tostring(dist2(e.x, e.y, best.x, best.y))))
                        focusState[e.id] = { orderedFrame = frame }
                        local actual = readbackTargetId(e.u)
                        dlog("BOMBER_FOCUS", frame, string.format(
                            "house=%s unit=%s type=%s was=%s now=%s(%s) readback=%s",
                            tostring(aiHouse:GetName()), tostring(e.id),
                            tostring(e.t), tostring(curKind),
                            tostring(best.id), tostring(best.t),
                            tostring(actual)))
                    end
                end
                ::next_bomber::
            end
        end
        ::next_focus::
    end
    end

    -- M2-C3 RAIDER FORCE (first decision-system slice): when home is quiet
    -- (no intruders/breach for raidQuiet frames), idle combat surplus forms
    -- ONE hunter group that snipes enemy economy (refinery > power > tech >
    -- AA > harvester) by value, nearest-tiebreak, id-tiebreak. Unfavourable
    -- contact (hostiles near raid centroid >= members × mult) retreats the
    -- group home instead of dying in place. Members are id-tracked and count
    -- as officer-assigned, so escort/rally/recall stand off them.
    -- Easy preset: raid off (rally only). v1 scope: economy only, no meat.
    if P.raid then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if not P.raidEvery then goto next_raid end -- easy preset: raid off
        if surrendered[aiHouse] then
            if raidGroups[aiHouse] then
                raidGroups[aiHouse]:reset()
                raidGroups[aiHouse] = nil
            end
            goto next_raid
        end -- Phase 1: silence
        local aiName = aiHouse:GetName()
        local bx, by, bn = 0, 0, 0
        for _, b in ipairs(buildings) do
            if b.oh == aiHouse and b.hasPos then
                bx, by, bn = bx + b.x, by + b.y, bn + 1
            end
        end
        if bn == 0 then goto next_raid end
        bx, by = bx / bn, by / bn
        -- M3 stance: character-adjusted raid params (a COPY — the shared
        -- preset is never mutated). rst is nil on easy (no character).
        local rst
        P, rst = stanceParams(aiHouse, P, aiName, frame)
        -- M3 counterpunch ready-state: a rusher whose enemy is bled dry
        -- does not wait for quiet — it finishes. Fired in FORM below;
        -- self-resolving (no targets -> STANDDOWN). Two shapes: a weak
        -- field army (1..N combat units), or no army but standing
        -- economy (post-wipe cleanup). Zero units AND zero economy is
        -- NOT weakness, it is absence (fresh start would raid at
        -- frame 30 otherwise) — nothing to hit, no punch.
        local playerCombat, playerEcon = 0, 0
        for _, u in ipairs(units) do
            if u.oh == humanPlayer and u.hasPos
                and (u.k == "unit" or u.k == "infantry"
                    or u.k == "aircraft")
                and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                and not util.CIVIL_TYPES[u.t] then
                playerCombat = playerCombat + 1
            end
        end
        for _, b in ipairs(buildings) do
            if b.oh == humanPlayer and b.hasPos
                and raidTargetValue(b) > 0 then
                playerEcon = playerEcon + 1
            end
        end
        local counterDue = rst == "rusher"
            and (playerCombat >= 1 and playerCombat <= PUNCH_WEAK_N
                or (playerCombat == 0 and playerEcon > 0))
            and frame - (lastCounter[aiHouse] or -PUNCH_COOLDOWN)
                >= PUNCH_COOLDOWN
        local quietSince = frame - (lastThreatFrame[aiHouse] or 0)
        local st = raidState[aiHouse]
        -- Live members, re-resolved from this tick's snapshot.
        local live = {}
        if st and st.members then
            for _, mid in ipairs(st.members) do
                local m = findSnap(units, mid)
                if m and m.oh == aiHouse and m.hasPos then
                    live[#live + 1] = m
                end
            end
        end
        local function raidCentroid(members)
            local cx, cy = 0, 0
            for _, m in ipairs(members) do cx, cy = cx + m.x, cy + m.y end
            return cx / #members, cy / #members
        end
        -- M3 wipe: had a group, none live — a lost engagement.
        if st and st.members and #st.members > 0 and #live == 0 then
            local lv = raidLevel[aiHouse] or 0
            if lv > -1 then
                raidLevel[aiHouse] = lv - 1
                dlog("RAID_WIPE", frame, string.format(
                    "house=%s members=%d level=%d",
                    tostring(aiName), #st.members, lv - 1))
                local alert = string.format(
                    "[AI Commander - %s] Hunter group wiped out!",
                    tostring(aiName))
                Engine.PrintMessage(alert)
                print("[LuaAPI] " .. alert)
            end
        end
        if #live > 0 then
            -- M3 fortunes: evidence-driven escalation. Target gone with
            -- members alive = WIN (level up, force re-pick); member
            -- losses on a tick = bad tick (level down). Capped [-1, +2].
            -- Sold/captured targets count as destroyed — acceptable.
            do
                local lv = raidLevel[aiHouse] or 0
                local tgtGone = st.targetId
                    and not unitsById[st.targetId]
                    and not buildingsById[st.targetId]
                if tgtGone then
                    st.targetId = nil
                    if lv < 2 then
                        raidLevel[aiHouse] = lv + 1
                        dlog("RAID_ESCALATE", frame, string.format(
                            "house=%s members=%d level=%d",
                            tostring(aiName), #live, lv + 1))
                        local alert = string.format(
                            "[AI Commander - %s] Raid pays off: "
                            .. "escalating (%d hunters)!",
                            tostring(aiName), #live)
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                end
                local prev = st.prevLive or #live
                if #live < prev then
                    if lv > -1 then
                        raidLevel[aiHouse] = lv - 1
                        dlog("RAID_BLOODIED", frame, string.format(
                            "house=%s members=%d lost=%d level=%d",
                            tostring(aiName), #live, prev - #live,
                            lv - 1))
                        local alert = string.format(
                            "[AI Commander - %s] Raid bloodied: "
                            .. "scaling down.",
                            tostring(aiName))
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                end
                st.prevLive = #live
            end
            -- M2-C5 Director rule #1: home under HIGH threat recalls the
            -- offense — disband to the defense pool (no orders issued;
            -- members re-enter pools by mission state). Re-form needs a
            -- quiet home again. Severity read from this tick's defense
            -- pass (runs earlier), not recomputed here.
            if defSevLevel[aiHouse] == "HIGH" then
                dlog("RAID_STANDDOWN", frame, string.format(
                    "house=%s members=%d reason=HOME_HIGH",
                    tostring(aiName), #live))
                raidState[aiHouse] = nil
                raidCooldownUntil[aiHouse] = frame + P.raidEvery
                if raidGroups[aiHouse] then
                    raidGroups[aiHouse]:reset()
                    raidGroups[aiHouse] = nil
                end
                goto next_raid
            end
            -- M2-C5 execution layer: sync the ForceGroup (Observe via its
            -- tracker) and let Tactical decide FIGHT vs FLIGHT
            -- (continue/changetarget/find_target vs retreat/disengage).
            -- SmartAI keeps Act: target selection (grudge), claims, logs.
            local grp = raidGroups[aiHouse]
            if not grp then
                grp = ForceGroup.newGroup({
                    id = "raid", radius = 18, pulseEvery = P.scan,
                    getHouse = houseGetter(aiHouse),
                })
                for _, m in ipairs(live) do grp:add_member_by_id(m.id) end
                raidGroups[aiHouse] = grp
            else
                for _, m in ipairs(live) do
                    if not grp:has(m.id) then grp:add_member_by_id(m.id) end
                end
                for _, gid in ipairs(grp:ids()) do
                    if not findSnap(units, gid) then grp:remove_member(gid) end
                end
            end
            grp.tracker:update(frame)
            local snap = Tactical.buildSnapshot(grp.tracker, aiHouse, { radius = 18 })
            -- SmartAI owns target selection (grudge): hand the raid's
            -- current target to the evaluator. Without this the group
            -- sees only its 18-cell radius and sticks at find_target
            -- whenever SmartAI aims beyond it (proven live-shape 28-cell
            -- refinery run). Shape mirrors Tactical's own target records.
            local raidTgt = st.targetId and (unitsById[st.targetId]
                or buildingsById[st.targetId])
            if raidTgt then
                snap.target = {
                    id = raidTgt.id, kind = raidTgt.k, typeName = raidTgt.t,
                    ownerName = raidTgt.on, hp = raidTgt.hp or 0,
                    maxHp = raidTgt.maxhp or 0, x = raidTgt.x, y = raidTgt.y,
                    dist = 0,
                }
            end
            local res = grp.tactical:reassess(snap, frame)
            if res.changed then
                local met = res.metrics or {}
                -- QUIET (KEEP/QUIET/CUT): transition on decision|reason;
                -- the ratio wiggles every reassessment and is context,
                -- not signal — it rides along but does not trigger.
                dlogChange("GROUP", frame, tostring(aiName) .. "|raid",
                    string.format(
                        "house=%s group=raid decision=%s reason=%s ratio=%s",
                        tostring(aiName), tostring(res.decision),
                        tostring(res.reason),
                        met.ratio and string.format("%.2f", met.ratio) or "nil"),
                    tostring(res.decision) .. "|" .. tostring(res.reason))
            end
            -- Drive the existing group: pick/refresh target, or retreat.
            local rcx, rcy = raidCentroid(live)
            local hostilesNear = 0
            for _, u in ipairs(units) do
                if u.oh and u.oh ~= aiHouse and not allied(aiHouse, u.oh)
                    and not util.is_neutral_house(u.oh)
                    and not util.CIVIL_TYPES[u.t]
                    and DEFENSE_KINDS[u.k] and u.hasPos
                    and dist2(u.x, u.y, rcx, rcy) <= 144 then -- 12 cells
                    hostilesNear = hostilesNear + 1
                end
            end
            -- Fight/flight comes from the Tactical evaluator (C5); the old
            -- headcount rule (hostiles >= members x mult) is retired —
            -- hostilesNear stays as log context only.
            local wantRetreat = (res.decision == "retreat"
                or res.decision == "disengage")
            if wantRetreat then
                if not st.retreating
                    or frame - (st.orderedFrame or 0) >= P.raidEvery then
                    local moved = 0
                    for _, m in ipairs(live) do
                        if orderMove(m, math.floor(bx + 0.5), math.floor(by + 0.5)) then
                            moved = moved + 1
                        end
                    end
                    st.retreating = true
                    st.orderedFrame = frame
                    if moved > 0 then
                        dlog("RAID_RETREAT", frame, string.format(
                            "house=%s members=%d hostiles=%d dest=%d,%d",
                            tostring(aiName), #live, hostilesNear,
                            math.floor(bx + 0.5), math.floor(by + 0.5)))
                        local alert = string.format(
                            "[AI Commander - %s] Raid outmatched (%d vs %d): falling back!",
                            tostring(aiName), #live, hostilesNear)
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                end
            else
                -- Best-value economy target within raidRange of home.
                -- M2-C1: value is belief-weighted — candidates owned by a
                -- grudged house score base × grudgeMult. bestNoMem tracks
                -- the winner WITHOUT memory so a flip is provable in-log.
                local best, bestVal, bestD2 = nil, 0, nil
                local bestNoMem, bestNoMemVal, bestNoMemD2 = nil, 0, nil
                local pool = {}
                for _, u in ipairs(units) do pool[#pool + 1] = u end
                for _, b in ipairs(buildings) do pool[#pool + 1] = b end
                local lost = lostAssets[aiHouse] -- assets we lost -> recapture
                for _, cand in ipairs(pool) do
                    if cand.oh and cand.oh ~= aiHouse
                        and not allied(aiHouse, cand.oh)
                        and not util.is_neutral_house(cand.oh)
                        and not util.CIVIL_TYPES[cand.t] and cand.hasPos then
                        local baseV = raidTargetValue(cand)
                        local isLost = lost and lost[cand.id]
                        local rangeR2 = isLost and CAPTURE_RECAPTURE_R2
                            or (P.raidRange * P.raidRange)
                        if isLost then baseV = CAPTURE_RECAPTURE_VALUE end
                        local mult, _ = grudgeMult(aiHouse, cand.oh)
                        local v = baseV * mult
                        if v > 0 and dist2(cand.x, cand.y, bx, by) <= rangeR2 then
                            local d2 = dist2(cand.x, cand.y, rcx, rcy)
                            if v > bestVal or (v == bestVal
                                and (not bestD2 or d2 < bestD2
                                    or (d2 == bestD2 and cand.id < best.id))) then
                                best, bestVal, bestD2 = cand, v, d2
                                bestIsLostCapture = isLost and isCaptureAssetType(cand.t)
                            end
                            if baseV > bestNoMemVal or (baseV == bestNoMemVal
                                and (not bestNoMemD2 or d2 < bestNoMemD2
                                    or (d2 == bestNoMemD2 and bestNoMem
                                        and cand.id < bestNoMem.id))) then
                                bestNoMem, bestNoMemVal, bestNoMemD2 =
                                    cand, baseV, d2
                            end
                        else
                            -- Candidate passed basic filter but rejected by value/range
                            local rejReason = "VALUE_ZERO"
                            if v <= 0 then rejReason = "VALUE_ZERO"
                            elseif dist2(cand.x, cand.y, bx, by) > rangeR2 then
                                rejReason = "OUT_OF_RANGE"
                            end
                            SmartAI.logTargetEval(
                                tostring(aiName), "raid", tostring(aiHouse and aiHouse:GetName() or "-"),
                                tostring(cand.id), tostring(cand.t), tostring(cand.on and cand.on or "-"),
                                false, rejReason, tostring(baseV),
                                string.format("mult=%s dist2_home=%s", tostring(mult),
                                    tostring(dist2(cand.x, cand.y, bx, by))))
                        end
                    end
                end
                if best then
                    SmartAI.logTargetEval(
                        tostring(aiName), "raid", tostring(aiHouse and aiHouse:GetName() or "-"),
                        tostring(best.id), tostring(best.t), tostring(best.on and best.on or "-"),
                        true, "BEST_VALUE", tostring(bestVal),
                        string.format("no_mem=%s no_mem_val=%s",
                            tostring(bestNoMem and bestNoMem.id or "-"),
                            tostring(bestNoMemVal or "-")))
                    if not st.retreating then
                        -- Holding same target inside refresh window: no re-issue.
                        if st.targetId == best.id
                            and frame - (st.orderedFrame or 0) < P.raidEvery then
                            -- hold: silence
                        else
                            local issued = 0
                            local bestIsLostCapture = best and best._isLostCapture
                                or (lost and lost[best.id] and isCaptureAssetType(best.t))
                            for _, m in ipairs(live) do
                                -- M2-C2: a member claimed earlier this tick
                                -- obeys the higher-priority order instead
                                -- (prevents cross-tick tug-of-war).
                                if not tryClaim(m.id, "RAID") then goto next_raider end
                                -- Recapture: only engineers may Attack a capturable
                                -- building we lost (combat units would destroy it).
                                -- Others move near to escort/protect the capture.
                                if bestIsLostCapture and not isEngineerType(m.t) then
                                    if best.hasPos then
                                        orderMove(m, best.x, best.y, "OFFICER", "RAID",
                                            "escort recapture",
                                            string.format("target=%s type=%s", tostring(best.id), tostring(best.t)))
                                        issued = issued + 1
                                    end
                                elseif orderAttack(m, best.u, "OFFICER", "RAID",
                                    bestIsLostCapture and "recapture asset" or "economy snipe",
                                    string.format("target=%s type=%s value=%.1f",
                                        tostring(best.id), tostring(best.t), bestVal)) then
                                    issued = issued + 1
                                    local actual = readbackTargetId(m.u)
                                    if actual ~= nil and actual ~= best.id then
                                        dlog("READBACK_MISMATCH", frame, string.format(
                                            "unit=%s expected_target=%s actual_target=%s",
                                            tostring(m.id), tostring(best.id),
                                            tostring(actual)))
                                    end
                                end
                                ::next_raider::
                            end
                            st.targetId = best.id
                            st.orderedFrame = frame
                            if issued > 0 then
                                dlog("RAID_TARGET", frame, string.format(
                                    "house=%s members=%d target=%s type=%s value=%.1f",
                                    tostring(aiName), issued, tostring(best.id),
                                    tostring(best.t), bestVal))
                                -- M2-C1 causal proof: memory changed the winner.
                                -- Visible memory: flips are rare, so the
                                -- player gets told who the AI is avenging.
                                if bestNoMem and bestNoMem.id ~= best.id then
                                    local _, gn = grudgeMult(aiHouse, best.oh)
                                    dlog("BELIEF_EFFECT", frame, string.format(
                                        "house=%s no_mem=%s(%s) with_mem=%s(%s) grudge=%d",
                                        tostring(aiName), tostring(bestNoMem.id),
                                        tostring(bestNoMem.t), tostring(best.id),
                                        tostring(best.t), gn))
                                    local _, ehn =
                                        pcall(best.oh.GetName, best.oh)
                                    local alert = string.format(
                                        "[AI Commander - %s] Avenging past "
                                        .. "raids: hunting %s economy!",
                                        tostring(aiName),
                                        tostring(ehn or best.oh))
                                    Engine.PrintMessage(alert)
                                    print("[LuaAPI] " .. alert)
                                end
                                local alert = string.format(
                                    "[AI Commander - %s] Raid: %d hunter(s) on %s#%s!",
                                    tostring(aiName), issued,
                                    tostring(best.t), tostring(best.id))
                                Engine.PrintMessage(alert)
                                print("[LuaAPI] " .. alert)
                            end
                        end
                    else
                        -- Was retreating, contact cleared: resume hunting.
                        -- Reset the order window: the retreat order must not
                        -- double as attack cooldown (else the group sits out
                        -- a full raidEvery after every fallback).
                        st.retreating = nil
                        st.orderedFrame = 0
                    end
                else
                    -- No economy in range: disband to the idle pool (no wander),
                    -- with a re-form cooldown so FORM/STANDDOWN cannot churn
                    -- every scan while the enemy economy stays out of reach.
                    dlog("RAID_STANDDOWN", frame, string.format(
                        "house=%s members=%d reason=NO_ECONOMY_IN_RANGE",
                        tostring(aiName), #live))
                    raidState[aiHouse] = nil
                    raidCooldownUntil[aiHouse] = frame + P.raidEvery
                    if raidGroups[aiHouse] then
                        raidGroups[aiHouse]:reset()
                        raidGroups[aiHouse] = nil
                    end
                end
            end
        elseif (quietSince >= P.raidQuiet or counterDue)
            and frame >= (raidCooldownUntil[aiHouse] or 0) then
            -- Defense-first: no NEW offensives while a breach is active
            -- this tick (live groups continue unless HIGH; re-form resumes
            -- when the breach lifts). Keeps fresh releases flowing to the
            -- rally instead of being drafted mid-handoff.
            if pendingBreach[aiHouse] then goto next_raid end
            -- Form: idle combat surplus first (ID-ordered, deterministic);
            -- vanilla AI rarely leaves armor idle, so marching-but-not-
            -- fighting units (attacking==false, same strictness as march
            -- recall; actively fighting units are NEVER yanked) fill the
            -- group as second choice. First N overall, idle preferred.
            local pool, march = {}, {}
            for _, u in ipairs(units) do
                if u.oh == aiHouse and u.k == "unit" and u.hasPos
                    and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                    and not ARTILLERY_TYPES[u.t]
                    and not isOfficerAssigned(u.id)
                    and not claimTick[u.id] then -- M2-C2: claimed earlier
                    if u.idle then pool[#pool + 1] = u
                    elseif u.attacking == false then march[#march + 1] = u end
                end
            end
            table.sort(pool, function(a, b)
                -- VALOR: T3 leads the raid (most lethal + most survivable),
                -- ID order inside the tier (deterministic as before).
                local ta = T3_TYPES[a.t] and true or false
                local tb = T3_TYPES[b.t] and true or false
                if ta ~= tb then return ta end
                return a.id < b.id
            end)
            table.sort(march, function(a, b)
                local ta = T3_TYPES[a.t] and true or false
                local tb = T3_TYPES[b.t] and true or false
                if ta ~= tb then return ta end
                return a.id < b.id
            end)
            local idleN = #pool
            -- M3 size: stanced base +/- evidence level (never tiny).
            local effN = raidSizeFor(aiHouse, P)
            for _, m in ipairs(march) do
                if #pool >= effN then break end
                pool[#pool + 1] = m
            end
            if #pool >= (P.raidMin or 3) then
                local members = {}
                for i = 1, math.min(effN, #pool) do
                    members[#members + 1] = pool[i].id
                    claimTick[pool[i].id] = "RAID" -- M2-C2: register picks
                end
                raidState[aiHouse] = {
                    members = members, targetId = nil,
                    orderedFrame = 0, formedFrame = frame,
                }
                dlog("RAID_FORM", frame, string.format(
                    "house=%s members=%s quiet=%d idle=%d march=%d size=%d",
                    tostring(aiName), table.concat(members, ","),
                    quietSince, idleN, #members - idleN, effN))
                -- Counterpunch announces itself; normal forms use the
                -- standing banner (never both — one banner per form).
                local counterFired =
                    counterDue and quietSince < P.raidQuiet
                if counterFired then lastCounter[aiHouse] = frame end
                local alert
                if counterFired then
                    alert = string.format(
                        "[AI Commander - %s] Hunter group out (%d): "
                        .. "smells blood, counter-attacking!",
                        tostring(aiName), #members)
                else
                    alert = string.format(
                        "[AI Commander - %s] Hunter group out (%d): "
                        .. "seeking enemy economy!",
                        tostring(aiName), #members)
                end
                Engine.PrintMessage(alert)
                print("[LuaAPI] " .. alert)
            end
            if #pool < (P.raidMin or 3)
                and frame % SMARTAI_CENSUS_EVERY < P.scan then
                dlog("RAID_POOL_SHORT", frame, string.format(
                    "house=%s pool=%d(idle=%d) need=%d quiet=%d",
                    tostring(aiName), #pool, idleN,
                    (P.raidMin or 3), quietSince))
            end
        else
            -- Home not quiet and no live group: throttled wait note so the
            -- next log shows which gate blocks (quiet vs pool vs range).
            if frame % SMARTAI_CENSUS_EVERY < P.scan then
                local poolN, econN = 0, 0
                for _, u in ipairs(units) do
                    if u.oh == aiHouse and u.k == "unit" and u.hasPos
                        and not HARVESTER_TYPES[u.t] and not MCV_TYPES[u.t]
                        and not ARTILLERY_TYPES[u.t]
                        and not isOfficerAssigned(u.id)
                        and (u.idle or u.attacking == false) then
                        poolN = poolN + 1
                    end
                end
                for _, b in ipairs(buildings) do
                    if b.oh and b.oh ~= aiHouse
                        and raidTargetValue(b) > 0 and b.hasPos
                        and dist2(b.x, b.y, bx, by)
                            <= P.raidRange * P.raidRange then
                        econN = econN + 1
                    end
                end
                dlog("RAID_STATUS", frame, string.format(
                    "house=%s quiet=%d/%d pool=%d econ_in_range=%d group=%s",
                    tostring(aiName), quietSince, P.raidQuiet,
                    poolN, econN, st and "yes" or "no"))
            end
            if st then raidState[aiHouse] = nil end
        end
        -- MASTERMIND FEINT (hard only): while a raid group is live, one
        -- cheap unit attacks the most visible enemy force elsewhere —
        -- noise on one axis, business on the other. The feint needs an
        -- audience (player combat); without one it is skipped, not
        -- faked. One-shot per cooldown; the feinter is expected to die
        -- (that IS the distraction). Claims RAID (family tier).
        if rst == "rusher" and c4RawDifficulty(aiHouse) == "hard"
            and raidState[aiHouse]
            and frame - (feintState[aiHouse] or -900) >= 900 then
            -- Audience: nearest player combat to the player's own base
            -- centroid (their troops = the attention to fix in place).
            local px, py, pn = 0, 0, 0
            for _, b in ipairs(buildings) do
                if b.oh == humanPlayer and b.hasPos then
                    px, py, pn = px + b.x, py + b.y, pn + 1
                end
            end
            if pn > 0 then
                px, py = px / pn, py / pn
                local tgt, tgtD2
                for _, u in ipairs(units) do
                    if u.oh == humanPlayer and u.hasPos
                        and (u.k == "unit" or u.k == "infantry")
                        and not HARVESTER_TYPES[u.t]
                        and not MCV_TYPES[u.t]
                        and not util.CIVIL_TYPES[u.t] then
                        local d2 = dist2(u.x, u.y, px, py)
                        if not tgtD2 or d2 < tgtD2 then
                            tgt, tgtD2 = u, d2
                        end
                    end
                end
                if tgt then
                    local feinter, feintCost, feintId
                    for _, u in ipairs(units) do
                        if u.oh == aiHouse and u.k == "unit" and u.hasPos
                            and not HARVESTER_TYPES[u.t]
                            and not MCV_TYPES[u.t]
                            and not ARTILLERY_TYPES[u.t]
                            -- VALOR: the feinter is expected to die — never
                            -- spend the precious (vets, half-invested
                            -- near-promotions, T3) as bait. Heroes never
                            -- reach here (infantry kind filter above).
                            and not isPrecious(u)
                            and (u.idle or u.attacking == false)
                            and not isOfficerAssigned(u.id) then
                            local c = u.cost or 0
                            if not feintCost or c < feintCost
                                or (c == feintCost and u.id < feintId) then
                                feinter, feintCost, feintId = u, c, u.id
                            end
                        end
                    end
                    if feinter
                        and tryClaim(feinter.id, "RAID")
                        and orderAttack(feinter, tgt.u, "OFFICER", "FEINT",
                            "defender fixation",
                            string.format("target=%s type=%s",
                                tostring(tgt.id), tostring(tgt.t))) then
                        feintState[aiHouse] = frame
                        diagOrder(frame, "FEINT", feinter, "Attack",
                            string.format("target=%s type=%s",
                                tostring(tgt.id), tostring(tgt.t)))
                        -- Readback (measurement only, no divLogged).
                        local actual = readbackTargetId(feinter.u)
                        if actual ~= nil and actual ~= tgt.id then
                            dlog("READBACK_MISMATCH", frame, string.format(
                                "unit=%s expected_target=%s actual_target=%s",
                                tostring(feinter.id), tostring(tgt.id),
                                tostring(actual)))
                        end
                        local alert = string.format(
                            "[AI Commander - %s] Feint at %s to fix "
                            .. "defenders while hunters work!",
                            tostring(aiName), tostring(tgt.t))
                        Engine.PrintMessage(alert)
                        print("[LuaAPI] " .. alert)
                    end
                end
            end
        end
        ::next_raid::
    end
    end -- P.raid

    -- RETARGET OFFICER (M3 fight-smarter, P.raid family): engaged AI
    -- combat redirected onto better targets WITHOUT moving anyone.
    -- This is the layer for the 100%-engaged match: vanilla owns every
    -- order, but nobody owns the TARGET choice — SmartAI takes it.
    -- SmartAI-held fighters (guard/defense/escort/raid/miner) keep
    -- SmartAI targets; only vanilla-driven fighters are re-aimed, and
    -- only at a CLEAR upgrade (gap) no farther than the current
    -- engagement (+2 slop). Attack-move (no native target) commits at
    -- infantry-grade: any real value takes it. Transition-only +
    -- per-unit cooldown; dlog only (battles are frequent, HUD would
    -- spam — the focus fire itself is the visible proof).
    if P.raid then
    for _, aiHouse in ipairs(aiHouses) do
        local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
        if not P.raid or surrendered[aiHouse] then goto next_retarget end
        for _, e in ipairs(units) do
            if e.oh == aiHouse and e.hasPos
                and (e.k == "unit" or e.k == "infantry"
                    or e.k == "aircraft")
                and e.attacking == true
                and not HARVESTER_TYPES[e.t] and not MCV_TYPES[e.t]
                and not isOfficerAssigned(e.id) then
                local mem = retargetState[e.id]
                if mem and frame - (mem.orderedFrame or 0) < RETARGET_EVERY then
                    -- cooling down: hold current target
                else
                    local curVal, curDist = 0.5, nil
                    local okT, tgt = pcall(e.u.GetTarget, e.u)
                    if okT and tgt ~= nil then
                        local tid = liveId(tgt)
                        local cs = (tid ~= nil)
                            and (unitsById[tid] or buildingsById[tid]) or nil
                        if cs ~= nil and cs.hasPos then
                            curVal = retargetValue(cs)
                            curDist = math.sqrt(dist2(e.x, e.y, cs.x, cs.y))
                        else
                            -- Target gone/positionless: vanilla re-acquires.
                            curVal = nil
                        end
                    end
                    if curVal ~= nil then
                        -- Range first: only what is already within reach
                        -- (current engagement +2 slop, or REASSESS_R for
                        -- attack-movers) can win — a far rich target must
                        -- never veto a near good switch, nor cause treks.
                        local reach2
                        if curDist ~= nil then
                            reach2 = (curDist + 2) * (curDist + 2)
                        else
                            reach2 = RETARGET_R * RETARGET_R
                        end
                        local best, bestVal, bestD2 = nil, 0, nil
                        for _, u in ipairs(units) do
                            if u.oh and u.oh ~= aiHouse
                                and not allied(aiHouse, u.oh)
                                and not util.is_neutral_house(u.oh)
                                and not util.CIVIL_TYPES[u.t] and u.hasPos
                                and (u.k == "unit" or u.k == "infantry"
                                    or u.k == "aircraft") then
                                local d2 = dist2(e.x, e.y, u.x, u.y)
                                if d2 <= reach2 then
                                    local v = retargetValue(u)
                                    if v > bestVal or (v == bestVal
                                        and ((not bestD2 or d2 < bestD2)
                                            or (d2 == bestD2 and best
                                                and u.id < best.id))) then
                                        best, bestVal, bestD2 = u, v, d2
                                    end
                                end
                            end
                        end
                        for _, b in ipairs(buildings) do
                            if b.oh and b.oh ~= aiHouse
                                and not allied(aiHouse, b.oh)
                                and not util.is_neutral_house(b.oh)
                                and not util.CIVIL_TYPES[b.t] and b.hasPos then
                                local d2 = dist2(e.x, e.y, b.x, b.y)
                                if d2 <= reach2 then
                                    local v = retargetValue(b)
                                    if v > bestVal or (v == bestVal
                                        and ((not bestD2 or d2 < bestD2)
                                            or (d2 == bestD2 and best
                                                and b.id < best.id))) then
                                        best, bestVal, bestD2 = b, v, d2
                                    end
                                end
                            end
                        end
                        if best and bestVal >= curVal + RETARGET_GAP then
                            if orderAttack(e, best.u, "OFFICER", "RETARGET",
                                "target upgrade",
                                string.format("from=%.1f to=%s(%s)=%.1f",
                                    curVal, tostring(best.id),
                                    tostring(best.t), bestVal)) then
                                retargetState[e.id] = { orderedFrame = frame }
                                diagOrder(frame, "RETARGET", e, "Attack",
                                    string.format(
                                        "from=%.1f to=%s(%s)=%.1f",
                                        curVal, tostring(best.id),
                                        tostring(best.t), bestVal))
                                -- Readback (measurement only, no divLogged).
                                local actual = readbackTargetId(e.u)
                                if actual ~= nil and actual ~= best.id then
                                    dlog("READBACK_MISMATCH", frame,
                                        string.format(
                                            "unit=%s expected_target=%s actual_target=%s",
                                            tostring(e.id),
                                            tostring(best.id),
                                            tostring(actual)))
                                end
                            end
                        end
                    end
                end
            end
        end
        ::next_retarget::
    end
    end -- P.raid retarget

    -- MoveTo readback pass (overwrite measurement): verdicts tracked
    -- orders, then emits the census line with the commandable-pool
    -- snapshot (the Phase-1 availability probe rides on idle/marching
    -- counts below — no extra scans needed).
    moveReadback(frame, units, dlog)
    if frame - lastMoveStatsFrame >= SMARTAI_CENSUS_EVERY then
        lastMoveStatsFrame = frame
        local idleN, marchN = 0, 0
        for _, aiHouse in ipairs(aiHouses) do
            for _, e in ipairs(units) do
                if e.oh == aiHouse and e.k == "unit" and e.hasPos
                    and not HARVESTER_TYPES[e.t]
                    and not MCV_TYPES[e.t]
                    and not ARTILLERY_TYPES[e.t] then
                    if e.idle then
                        idleN = idleN + 1
                    elseif e.attacking == false then
                        marchN = marchN + 1
                    end
                end
            end
        end
        moveStats.idleNow = idleN
        moveStats.marchingNow = marchN
        dlog("MOVE_STATS", frame, string.format(
            "ordered=%d arrived=%d yanked=%d handoff=%d stale=%d idle=%d marching=%d",
            moveStats.ordered, moveStats.arrived, moveStats.yanked,
            moveStats.handoff, moveStats.stale, idleN, marchN))
    end

    -- M2-C2 ARBITER summary: one line per tick that had contested picks —
    -- the visible proof that conflicts are arbitrated, not double-ordered.
    do
        local skipTotal, parts = 0, {}
        for site, c in pairs(arbSkips) do
            skipTotal = skipTotal + c
            parts[#parts + 1] = site .. "=" .. tostring(c)
        end
        if skipTotal > 0 then
            table.sort(parts)
            -- QUIET (KEEP/QUIET/CUT): same skip-set every tick is one
            -- fact; on-change + heartbeat.
            dlogChange("ARBITER", frame, "global",
                "skips " .. table.concat(parts, " "))
        end
    end

    -- [SMARTAI][CENSUS] (diagnostic only): AI-house roster with id /
    -- owner / type / kind / pos, throttled, capped — answers "who exists
    -- under which house" without touching the target_reselect [M14.1]
    -- player-side census. Built from this tick's snapshot: zero extra
    -- native calls.
    if frame - lastCensusFrame >= SMARTAI_CENSUS_EVERY then
        lastCensusFrame = frame
        local parts, total = {}, 0
        for _, aiHouse in ipairs(aiHouses) do
            local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
            for _, e in ipairs(units) do
                if e.oh == aiHouse then
                    total = total + 1
                    if #parts < 40 and e.hasPos then
                        parts[#parts + 1] = string.format("%d:%s:%s:%s@%d,%d",
                            e.id, tostring(e.on), tostring(e.t),
                            tostring(e.k), e.x, e.y)
                    end
                end
            end
        end
        -- QUIET (KEEP/QUIET/CUT): roster dumps repeat verbatim while
        -- nothing changes; on-change + heartbeat.
        dlogChange("CENSUS", frame, "global", string.format("ai_units=%d :: %s%s", total,
            table.concat(parts, " "), total > #parts and " (+" .. (total - #parts) .. " more)" or ""))
        -- [SMARTAI][BASE] (diagnostic only, same gate): per-AI-house base
        -- state — buildings with HP, unit count, power, credits. Read-only;
        -- answers "what does the base still have" for defeat analysis.
        -- No defeat flags exist in LuaAPI (see SURRENDER_CONDITIONS_RESEARCH).
        for _, aiHouse in ipairs(aiHouses) do
            local P = paramsFor(aiHouse) -- per-house preset (Beta M1)
            local bp, shown, bn = {}, 0, 0
            for _, b in ipairs(buildings) do
                if b.oh == aiHouse then
                    bn = bn + 1
                    if shown < 30 then
                        shown = shown + 1
                        local hp = (b.hp ~= nil and b.maxhp ~= nil and b.maxhp > 0)
                            and string.format("%d/%d", b.hp, b.maxhp) or "?"
                        bp[#bp + 1] = string.format("%d:%s:%s@%d,%d",
                            b.id, tostring(b.t), hp,
                            b.hasPos and b.x or -1, b.hasPos and b.y or -1)
                    end
                end
            end
            local un = 0
            for _, e in ipairs(units) do
                if e.oh == aiHouse then un = un + 1 end
            end
            local okPo, po = pcall(aiHouse.GetPowerOutput, aiHouse)
            local okPd, pd = pcall(aiHouse.GetPowerDrain, aiHouse)
            local okCr, cr = pcall(aiHouse.GetCredits, aiHouse)
            local okHn, hn = pcall(aiHouse.GetName, aiHouse)
            local hName = (okHn and type(hn) == "string") and hn or "?"
            -- QUIET (KEEP/QUIET/CUT): same gate as CENSUS; on-change +
            -- heartbeat per house. GetName isolated via pcall so a diagnostic
            -- error cannot abort the Update cycle; fetched once and reused.
            dlogChange("BASE", frame, tostring(hName), string.format(
                "house=%s blds=%d units=%d power=%s/%s credits=%s :: %s%s",
                tostring(hName), bn, un,
                (okPo and type(po) == "number") and tostring(math.floor(po)) or "?",
                (okPd and type(pd) == "number") and tostring(math.floor(pd)) or "?",
                (okCr and type(cr) == "number") and tostring(math.floor(cr)) or "?",
                table.concat(bp, " "), bn > shown and " (+" .. (bn - shown) .. " more)" or ""))
        end
    end

    -- Officer state hygiene: drop principals that vanished; release
    -- stand-down escorts (Commander breach priority) with one log line.
    for id, st in pairs(escortState) do
        if not v3ids[id] then
            escortState[id] = nil
        elseif st.standDown then
            if st.guards and #st.guards > 0 then
                local alert = string.format(
                    "[AI Commander - %s] V3#%s escort released: base breach priority.",
                    tostring(st.houseName or "?"), tostring(id))
                Engine.PrintMessage(alert)
                print("[LuaAPI] " .. alert)
            end
            escortState[id] = nil
        end
    end
    for id in pairs(garrisonState) do
        if not defids[id] then garrisonState[id] = nil end
    end
    for id in pairs(recallState) do
        if not seenNow[id] then recallState[id] = nil end
    end
    for id, ds in pairs(defenseState) do
        local tgt = findSnap(units, ds.targetId)
        local defAlive = seenNow[id]
        if not defAlive or not tgt then
            -- M2-C4 ADAPT: Observe result. An assignment that ends here is a
            -- resolved episode. Only an UNRESOLVED one counts: a live
            -- defender still fighting is not yet a win and not yet a loss.
            -- Defender gone + intruder alive = loss (we traded and lost);
            -- defender alive + intruder gone = win; both gone = draw, neither.
            if ds.house and not surrendered[ds.house] then
                local e2 = dEff[ds.house]
                if not e2 then
                    e2 = { w = 0, l = 0, streak = 0, seenWin = {},
                           seenLoss = {}, seenDraw = {} }
                    dEff[ds.house] = e2
                end
                -- ONE credit per engagement, in BOTH directions. Two defenders
                -- dying on one intruder is ONE failed contact, not two: letting
                -- it count twice would reach streak=2 inside a single fight,
                -- which contradicts the stated rationale ("a single loss can
                -- be a cornered unit; two in a row is a signal"). Unit ids are
                -- not recycled in RA2, so targetId identifies the engagement
                -- for the whole match.
                --
                -- Per HOUSE: the dedup memory lives on the house ledger
                -- (dEff[house].seen*), so one intruder fought by two houses is
                -- an independent contact for each of them, while one intruder
                -- cannot be credited twice for the same house.
                --
                -- The memory MUST be a set, not a single "last target" slot.
                -- This loop resolves every defence record in ONE pass, so
                -- records for two different intruders interleave freely in
                -- pairs() order. With a single slot, the sequence
                --     [d1 -> t1]  [d2 -> t2]  [d3 -> t1]
                -- credits t1 twice: resolving d2 overwrites the slot with t2,
                -- so d3 no longer recognises t1 as already settled. That was
                -- observed live in the harness as w=2 then w=4 for the same
                -- intruder inside a single frame.
                --
                -- KNOWN LIMIT, deliberate: a defender that dies AFTER the
                -- threat is already dead is not a defensive failure, and its
                -- record is gone by then, so it is not counted at all. Only
                -- "defender died while the intruder lived" counts against us.
                --
                -- `emit` marks the record that FIRST resolves this target.
                -- Later defenders still attached to the same intruder are
                -- duplicates of one contact: no ledger credit and no event.
                local outcome, emit
                if not defAlive and tgt then
                    outcome = "LOSE"
                    local seen = e2.seenLoss
                    if not seen then seen = {}; e2.seenLoss = seen end
                    if not seen[ds.targetId] then
                        seen[ds.targetId] = true
                        e2.l = e2.l + 1
                        e2.streak = e2.streak + 1
                        dEffStats.l = dEffStats.l + 1
                        emit = true
                    end
                elseif defAlive and not tgt then
                    outcome = "WIN"
                    local seen = e2.seenWin
                    if not seen then seen = {}; e2.seenWin = seen end
                    if not seen[ds.targetId] then
                        seen[ds.targetId] = true
                        e2.w = e2.w + 1
                        e2.streak = 0 -- adaptation stands down on a win
                        dEffStats.w = dEffStats.w + 1
                        emit = true
                    end
                else
                    outcome = "DRAW" -- both gone: no w/l credit, but visible
                    local seen = e2.seenDraw
                    if not seen then seen = {}; e2.seenDraw = seen end
                    emit = not seen[ds.targetId]
                    if emit then
                        seen[ds.targetId] = true
                        dEffStats.draw = dEffStats.draw + 1
                    end
                end
                if emit then
                    -- EVENT, not a state: unthrottled, so the Act -> Observe
                    -- chain is readable line by line. The streak travels with
                    -- the event, so the streak progression is visible without
                    -- waiting for the next census. Exactly one event per
                    -- resolved contact.
                    dlog("CONTACT", frame, string.format(
                        "house=%s outcome=%s defender=%s intruder=%s "
                            .. "w=%d l=%d streak=%d armed=%s",
                        tostring(ds.house:GetName()), outcome, tostring(id),
                        tostring(ds.targetId), e2.w, e2.l, e2.streak,
                        tostring(e2.streak >= ADAPT_STREAK_TRIGGER)))
                end
            end
            defenseState[id] = nil -- defender or target gone: release
            -- Phase 1: drop the native lease with the record (live unit:
            -- Release by userdata; dead unit: nothing to release — the
            -- hook's UID check drops the stale lease on pointer reuse).
            if defAlive and TargetLease then
                local def = findSnap(units, id)
                if def and def.u then TargetLease.Release(def.u) end
            end
        end
    end
    for id in pairs(focusState) do
        if not seenNow[id] then focusState[id] = nil end -- bomber gone
    end
    for id in pairs(radEvacState) do
        if not seenNow[id] then radEvacState[id] = nil end -- evacuee gone
    end
    for id in pairs(minerState) do
        if not seenNow[id] then minerState[id] = nil end -- miner gone
    end
    for id in pairs(retargetState) do
        if not seenNow[id] then retargetState[id] = nil end -- fighter gone
    end
    for id in pairs(kiteHud) do
        if not seenNow[id] then kiteHud[id] = nil end -- principal gone
    end
    -- NOTE: birthScan/birthViol are deliberately NOT pruned here. A
    -- building flickering out of one scan (validation hiccup) and back
    -- must keep its original birth, or a legal building would be
    -- reborn-violated. Ids are never recycled, so a true rebuild is a
    -- new id with a new birth anyway; memory is bounded by buildings
    -- ever seen (hundreds).
    for h, rst in pairs(raidState) do
        if rst.members then
            local kept = {}
            for _, mid in ipairs(rst.members) do
                if seenNow[mid] then kept[#kept + 1] = mid end
            end
            if #kept == 0 then
                raidState[h] = nil -- group wiped: release
            else
                rst.members = kept
                if rst.targetId and not unitsById[rst.targetId]
                    and not buildingsById[rst.targetId] then
                    rst.targetId = nil -- target gone: re-pick next tick
                end
            end
        else
            raidState[h] = nil
        end
    end
    local houseSet = {}
    for _, h in ipairs(aiHouses) do houseSet[h] = true end
    for h in pairs(cmdState) do
        if not houseSet[h] then cmdState[h] = nil end
    end
    for h in pairs(rallyState) do
        if not houseSet[h] then rallyState[h] = nil end
    end
    for _, rs in pairs(rallyState) do
        if rs.ids then
            for id in pairs(rs.ids) do
                if not seenNow[id] then rs.ids[id] = nil end
            end
        end
    end
    for h in pairs(intruderSeen) do
        if not houseSet[h] then intruderSeen[h] = nil end
    end
    for h in pairs(raidState) do
        if not houseSet[h] then raidState[h] = nil end
    end
    for h in pairs(lastThreatFrame) do
        if not houseSet[h] then lastThreatFrame[h] = nil end
    end
    for h in pairs(raidCooldownUntil) do
        if not houseSet[h] then raidCooldownUntil[h] = nil end
    end
    for h in pairs(raidGroups) do
        if not houseSet[h] or not raidState[h] then
            if raidGroups[h] then raidGroups[h]:reset() end
            raidGroups[h] = nil
        end
    end
end

return SmartAI