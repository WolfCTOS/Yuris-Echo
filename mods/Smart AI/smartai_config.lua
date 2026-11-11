-- Smart AI configuration (extracted for tuning/extension, P0-P2 audit).
-- This file is data-only: presets, feature flags, tunables, and extensible type lists.
-- Extend TYPE lists to support custom/modded units/buildings without changing core logic.

local C = {}

-- Difficulty: "auto" | "easy" | "medium" | "hard"
-- "auto" maps each AI house to its lobby difficulty (engine GetAIDifficulty when available).
C.DIFFICULTY = "auto"
C.DIFFICULTY_FALLBACK = "medium"

-- Engine defeat transition on surrender (default false = decision-only, safer).
C.SURRENDER_ENGINE_CALL = false

-- Presets scale observation/tempo only (no production/credits/spawn cheats).
C.PRESETS = {
    easy = {
        scan = 60,
        rallyEvery = 300,
        guard = false, escort = false, garrison = false,
        recall = false, defense = false, raid = false,
        hero = true, heroLeash = 8, heroEvery = 900, heroRetreat = false,
        radevac = false, buildlaw = false, miner = false,
        intruderR = 18, assignR = 35, defendersN = 2, defenseEvery = 150,
        confirmN = 2, clearN = 4, marchRecall = false, redirectEvery = 300,
        raidN = 0, raidMin = 0, raidQuiet = 600, raidEvery = 600,
        raidRange = 60, raidRetreatMult = 2,
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

-- Feature flags / behavior toggles
C.CAPTURE_BUILD_DEFENSES_NATIVE = false -- opt-in native production for capture-asset defense

-- Surrender / base anchors
C.SURRENDER_FUTILITY_RATIO = 0.25
C.ANCHOR_BARRACKS = { NAHAND = true, NABRCK = true, GAPILE = true, YABRCK = true }
C.ANCHOR_WF       = { NAWEAP = true, GAWEAP = true, YAWEAP = true, YWEAP = true }
C.ANCHOR_MCV      = { AMCV = true, SMCV = true, YMCV = true, NACNST = true, GACNST = true, YACNST = true }

-- Valuable/capture guard
C.VALUABLE_TYPES  = { APOC = true, HTNK = true }
C.CAPTURE_THREATS = { MIND = true, YURIPR = true, YURI = true }
C.THREAT_RADIUS   = 9
C.HOLD_RADIUS     = 4
C.REORDER_EVERY   = 600

-- Unit/type categories (extend for custom content)
C.ARTILLERY_TYPES = { V3 = true }
C.HERO_TYPES      = { TANYA = true, BORIS = true, YURIPR = true }
C.T3_TYPES        = { APOC = true, BFRT = true, SREF = true, MGTK = true }
C.DEFENSE_TYPES   = { BUNKER = true, NAPILL = true, GAPILL = true }
C.HARVESTER_TYPES = { SMIN = true, HARV = true, CMIN = true }
C.MCV_TYPES       = { AMCV = true, SMCV = true, YMCV = true }
C.SUICIDE_TYPES   = { DTRUCK = true }
C.AA_TYPES        = { HTK = true, FLAKT = true, FV = true, YTNK = true }
C.AIR_RAIDERS     = { ZEP = true, KIROV = true }
C.RECALL_TYPES    = { V3 = true, KIROV = true }
C.DEFENSE_KINDS   = { unit = true, infantry = true, aircraft = true }

-- Economy/raid target categories
C.RAID_REFINERY   = { NAREFN = true, GAREFN = true }
C.RAID_POWER      = { NAPOWR = true, GAPOWR = true }
C.RAID_TECH       = { NATECH = true, GATECH = true }
C.RAID_AA_BUILDING = { NAFLAK = true }

-- Valor / hero tuning
C.HERO_FOCUS_GAP  = 1.0
C.HERO_RETREAT_HP = 0.30
C.VALOR_VET       = 1.0
C.VALOR_ELITE     = 2.0
C.VALOR_HERO      = 1.5
C.VALOR_T3        = 1.0
C.VALOR_KEEP      = 0.5

-- Escort / garrison / V3 behavior
C.ESCORT_N = 3
C.ESCORT_RADIUS = 6
C.ESCORT_EVERY = 300
C.ESCORT_DRAFT_RADIUS = 25
C.ESCORT_COMBAT_R = 15
C.ESCORT_COMBAT_EVERY = 150
C.V3_KITE_R = 12
C.V3_KITE_EVERY = 300
C.V3_KITE_DIST = 8
C.GARRISON_N = 3
C.GARRISON_RADIUS = 12
C.GARRISON_EVERY = 600
C.GARRISON_REACHED_R2 = 4

-- Recall / wave shepherd / rally
C.RECALL_THREAT_RADIUS = 20
C.RECALL_THREAT_N = 3
C.RECALL_FAR = 30
C.RECALL_EVERY = 300
C.WAVE_FAR = 25
C.WAVE_R = 12
C.WAVE_MIN = 3
C.WAVE_THREAT_R = 15
C.WAVE_DOOM_MULT = 3
C.RALLY_THREAT_R = 10

-- Grudge / retaliation / severity
C.GRUDGE_W = 0.5
C.GRUDGE_CAP = 4
C.GRUDGE_ATTRIB_R = 12
C.ECON_EVENT_EVERY = 300
C.SEV_SUICIDE = 4.0
C.SEV_INFANTRY = 0.5
C.SEV_LOW_BELOW = 2.0
C.SEV_HIGH_FROM = 6.0
C.LEASE_RETRIES = 2
C.LEASE_RETRY_EVERY = 60
C.RETALIATE_R = 12
C.RETALIATE_EVERY = 300

-- Capture-asset layer (subset of key tunables; extend as needed)
C.CAPTURE_ASSET_TYPES = {
    CAAIRP = true, CAOILD = true, OILDERRECK = true, CAHOSP = true, CATHOSP = true,
    CAMACH = true, CAPOWR = true, CASLAB = true, CAOUTP = true,
}
C.ENGINEER_TYPES = { ENGINEER = true, SENGINEER = true, YENGINEER = true }
C.CAPTURE_DEFENSE_R = 16
C.CAPTURE_GUARD_R = 10
C.CAPTURE_DEFENSE_N = 3
C.CAPTURE_GUARD_N = 2
C.CAPTURE_DEFENSE_EVERY = 240
C.CAPTURE_GUARD_EVERY = 300
C.CAPTURE_BUILD_EVERY = 900
C.CAPTURE_RECAPTURE_VALUE = 6.0
C.CAPTURE_RECAPTURE_R = 120
C.CAPTURE_RECAPTURE_ENGINEER_EVERY = 360

-- Order priority arbitration (P0): higher value wins when competing for the same unit.
-- Layers may consult these priorities; core wrappers enforce "do not downgrade" within window.
C.ORDER_PRIORITY = {
    SURVIVAL = 100,   -- retreat, kite, evac, mind-control guard
    DEFENSE  = 80,    -- base defense / intruder response
    ESCORT   = 70,    -- bodyguard/combat escort
    OBJECTIVE= 60,    -- raid/attack/capture objectives
    SUPPORT  = 40,    -- garrison, rally, shepherding
    IDLE     = 10,    -- opportunistic/background
}
C.ORDER_PRIORITY_WINDOW = 120 -- frames: do not let a lower-priority layer override a higher-priority recent order

return C
