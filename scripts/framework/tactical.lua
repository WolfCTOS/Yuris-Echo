-- LuaAPI Gameplay Framework — TacticalDecision.
--
-- M14 Gate 2: a minimal, generic reactive-tactical decision layer.
--
-- It answers one question on a periodic reassessment pulse:
--   "Has the battlefield changed enough that my current attack should be
--    reconsidered?"
--
-- It does NOT run the whole AI. It is a small, data-driven evaluator that turns
-- an observed local battlefield snapshot into one of a few coarse actions:
--     continue  - keep attacking the current target
--     retreat   - the local fight is unfavourable; disengage / pull back
--     changetarget - the current target is irrelevant or a better one exists
--     find_target  - we have no target to attack
--     disengage - we have no effective combat force left
--
-- DESIGN (why this is not "if Boris then retreat"):
--   * The snapshot is built from generic primitives the engine already exposes
--     (id, kind, typeName, hp, maxHp, owner, target, distance). Nothing Boris /
--     Kirov / Apocalypse specific lives in the control flow.
--   * Units whose special treatment is unavoidable (an AA threat, a heavy tank,
--     a hero) are scored through a single DATA table (`THREAT_VALUES`) keyed by
--     typeName. This isolates special-casing as data, not scattered branches.
--   * The decision is a function of an OWN-force score versus an ENEMY-threat
--     score, plus the desirability of the current target. It is explainable in
--     one ratio, not a pile of rules.
--
-- SAFETY: `evaluate()` is pure and owns NO engine objects. It operates only on
-- the primitive fields copied into the snapshot, so it can never hold a stale
-- or unsafe native pointer. The engine-facing `buildSnapshot()` resolves every
-- object by id from a fresh CombatStateTracker read / a fresh radius scan, and
-- only keeps primitives, exactly like Gate 1.
--
-- Using it:
--     local Tactical = require("framework.tactical")
--     local decision = Tactical.new({ pulseEvery = 15 })
--
--     -- every logical frame:
--     local snap = Tactical.buildSnapshot(tracker, house, opts)
--     local res  = decision:reassess(snap, frame)   -- throttled internally
--     if res.changed then
--         -- res.decision, res.reason, res.tier are authoritative this pulse
--     end

local util = require("framework.util")

local Tactical = {}

-- ---------------------------------------------------------------------------
-- Data tables (single source of truth; NO branching in the control flow)
-- ---------------------------------------------------------------------------

-- Own-force contribution per kind. A damaged unit contributes less. Buildings
-- are not an attack "force" (they are static), so they score 0 as own units.
local OWN_KIND_WEIGHT = {
    unit      = 1.0,
    infantry  = 0.6,
    aircraft  = 0.9,
    building  = 0.0,
    other     = 0.5,
}

-- Generic threat weight per kind (how dangerous a given enemy class is).
-- Aircraft are high because the local battle includes ground-based threats
-- that AA covers; buildings (flak turrets, tesla, etc.) can be dangerous too.
local THREAT_KIND_WEIGHT = {
    unit      = 1.0,
    infantry  = 0.35,
    aircraft  = 1.2,
    building  = 0.85,
    other     = 0.6,
}

-- Per-type threat multiplier for the handful of units that genuinely matter.
-- This is DATA, deliberately isolated so the control flow stays generic. A
-- missing key = neutral 1.0 (no special treatment).
local THREAT_VALUES = {
    -- Hero / super infantry
    BORIS = 3.0,
    -- Heavy / dangerous ground
    APOC  = 2.6,   -- Apocalypse tank
    TTNK  = 2.2,   -- Tesla tank
    HTNK  = 1.8,   -- Rhino / heavy tank
    -- Anti-air (the classic "Kirov killer")
    FLAKT = 2.4,   -- Flak track
    FLAK  = 2.4,   -- Flak cannon (building)
    -- Strategic aircraft
    KIROV = 1.6,   -- Kirov airship (slow, brutal to lose)
    DRED  = 1.4,   -- Dreadnought
    -- Cheap / weak
    E1    = 0.6,   -- GI
    DOG   = 0.5,   -- Attack dog
}

-- Civilian / neutral houses that are never legitimate attack targets.
local NEUTRAL_HOUSES = {
    Neutral  = true,
    Civilian = true,
    Special  = true,
}

-- Civilian vehicles that are not meaningful targets.
local CIVIL_TYPES = {
    CAR   = true,
    PCV   = true,
    BUS   = true,
    TRUCK = true,
}

-- Mobile Construction Vehicles: strategic but not a "strike" target.
local MCV_TYPES = {
    AMCV = true,
    SMCV = true,
    YMCV = true,
    SMV  = true,
}

-- Buildings that remain valid (often lucrative) attack objectives even though
-- they are static.
local STRATEGIC_BUILDINGS = {
    CAOILD = true, -- Oil Derrick
    CAHOSP = true, -- Hospital
    CAAIRP = true, -- Air Force Command HQ
    NAAIRC = true, -- Soviet Air Force Command HQ
    YAAIRC = true, -- Yuri Airforce Command HQ
}

-- ---------------------------------------------------------------------------
-- Scoring primitives (pure; engine-free)
-- ---------------------------------------------------------------------------

local function clamp(v, lo, hi)
    return v < lo and lo or (v > hi and hi or v)
end

local function hpRatio(unit)
    local max = unit and unit.maxHp or 0
    if not max or max <= 0 then
        return 1.0
    end
    return clamp((unit.hp or 0) / max, 0.0, 1.0)
end

-- Own contribution of a single combat unit.
function Tactical.own_power(unit)
    if not unit then
        return 0.0
    end
    local base = OWN_KIND_WEIGHT[unit.kind] and OWN_KIND_WEIGHT[unit.kind] or 0
    return base * (0.4 + 0.6 * hpRatio(unit))
end

-- Threat contribution of a single enemy. Includes proximity, so a unit standing
-- right in the local fight is more threatening than one at the scan edge.
function Tactical.enemy_threat(enemy, scanRadius)
    if not enemy then
        return 0.0
    end
    local kindW = THREAT_KIND_WEIGHT[enemy.kind] or 0.6
    local typeW = THREAT_VALUES[enemy.typeName] or 1.0
    local prox = 1.0
    if enemy.dist and scanRadius and scanRadius > 0 then
        prox = clamp(1.0 - (enemy.dist / scanRadius) * 0.5, 0.5, 1.0)
    end
    return kindW * typeW * (0.4 + 0.6 * hpRatio(enemy)) * prox
end

-- Desirability of a target. Returns a value in [0,1] plus a short label.
-- Neutral/civilian buildings and civilian vehicles are "irrelevant" (0).
function Tactical.target_value(target)
    if not target then
        return 0.0, "irrelevant"
    end
    if target.kind == "building" then
        local owner = target.ownerName
        if owner and NEUTRAL_HOUSES[owner] then
            -- Neutral civilian building: not a desirable objective.
            if STRATEGIC_BUILDINGS[target.typeName] then
                return 0.6, "strategic"
            end
            return 0.0, "irrelevant"
        end
        -- A hostile military building is a legitimate objective.
        return 0.7, "building"
    end
    if CIVIL_TYPES[target.typeName] then
        return 0.1, "civilian"
    end
    if MCV_TYPES[target.typeName] then
        return 0.4, "mcv"
    end
    -- A mobile combat unit is the most relevant target.
    return 1.0, "combat"
end

-- A stable signature of the local battlefield, used to detect meaningful change
-- between reassessment pulses. Only primitives/changes matter.
function Tactical.signature(snap)
    local ownAlive = 0
    local ownHp = 0
    for _, u in ipairs(snap.own or {}) do
        if u and u.alive ~= false then
            ownAlive = ownAlive + 1
            ownHp = ownHp + (u.hp or 0)
        end
    end
    local enemyNames = {}
    for _, e in ipairs(snap.enemies or {}) do
        if e then
            enemyNames[#enemyNames + 1] = tostring(e.typeName)
        end
    end
    table.sort(enemyNames)
    local targetDesc = snap.target and tostring(snap.target.typeName) or "-"
    return {
        ownAlive = ownAlive,
        ownHp    = ownHp,
        enemies  = table.concat(enemyNames, ","),
        target   = targetDesc,
    }
end

function Tactical.signature_equals(a, b)
    if not a or not b then
        return false
    end
    return a.ownAlive == b.ownAlive
        and a.ownHp == b.ownHp
        and a.enemies == b.enemies
        and a.target == b.target
end

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

local EvaluatorMT = {}
EvaluatorMT.__index = EvaluatorMT

function Tactical.new(opts)
    opts = opts or {}
    return setmetatable({
        pulseEvery    = opts.pulseEvery or 15,   -- frames between reassessment
        radius        = opts.radius or 18,       -- local observation radius (cells)
        continueRatio = opts.continueRatio or 1.5,  -- own/enemy >= this => favourable
        retreatRatio  = opts.retreatRatio or 0.7,   -- own/enemy <  this => retreat
        minForceRatio = opts.minForceRatio or 0.05, -- own power / initial < this => force gone
        _lastSig      = nil,    -- signature at the previous pulse
        _lastRes      = nil,    -- clamped decision of the previous pulse
        _pulseNext    = 0,
        _settings     = opts,
    }, EvaluatorMT)
end

-- Clamp the decided action for change-detection so we only report a change when
-- the *category* of the decision flips (continue <-> retreat <-> changetarget),
-- not on every minor score wiggle.
local function clampTier(action)
    if action == "retreat" or action == "disengage" then
        return "retreat"
    elseif action == "changetarget" or action == "find_target" then
        return "changetarget"
    else
        return "continue"
    end
end

-- Pure decision from a snapshot. Returns a result table (no state mutation).
function EvaluatorMT:_evaluate(snap)
    local own = snap.own or {}
    local enemies = snap.enemies or {}
    local target = snap.target

    -- 0 combat force left: there is nothing to fight with.
    local ownPower = 0.0
    local ownAlive = 0
    for _, u in ipairs(own) do
        if u and u.alive ~= false then
            ownAlive = ownAlive + 1
            ownPower = ownPower + Tactical.own_power(u)
        end
    end
    if ownAlive == 0 or ownPower <= Tactical.own_power({ kind = "infantry" }) * self.minForceRatio then
        return {
            decision = "disengage",
            tier = "unfavourable",
            reason = "force_gone",
            metrics = { ownPower = ownPower, enemyThreat = 0.0, ratio = 0.0 },
            suggestedTargetId = nil,
        }
    end

    -- No target: we cannot blindly keep an "attack" with nothing to hit.
    if not target then
        return {
            decision = "find_target",
            tier = "neutral",
            reason = "no_target",
            metrics = { ownPower = ownPower, enemyThreat = 0.0, ratio = nil },
            suggestedTargetId = nil,
        }
    end

    -- Irrelevant target (neutral civilian building): reject it. This is the
    -- minimum target-priority concept the Gate requires.
    local tval, tlabel = Tactical.target_value(target)
    if tval <= 0.0 then
        return {
            decision = "changetarget",
            tier = "marginal",
            reason = "irrelevant_target",
            metrics = { ownPower = ownPower, enemyThreat = 0.0, ratio = nil },
            suggestedTargetId = nil,
        }
    end

    -- Enemy threat in the local area.
    local enemyThreat = 0.0
    for _, e in ipairs(enemies) do
        enemyThreat = enemyThreat + Tactical.enemy_threat(e, self.radius)
    end

    -- If there are no local enemies, the decision reduces to target value.
    if enemyThreat <= 0.0 then
        if tval >= 0.5 then
            return {
                decision = "continue",
                tier = "favourable",
                reason = "clear_target",
                metrics = { ownPower = ownPower, enemyThreat = 0.0, ratio = nil },
                suggestedTargetId = nil,
            }
        end
        return {
            decision = "changetarget",
            tier = "marginal",
            reason = "weak_target",
            metrics = { ownPower = ownPower, enemyThreat = 0.0, ratio = nil },
            suggestedTargetId = nil,
        }
    end

    local ratio = ownPower / enemyThreat
    local tier
    if ratio >= self.continueRatio then
        tier = "favourable"
    elseif ratio <= self.retreatRatio then
        tier = "unfavourable"
    else
        tier = "marginal"
    end

    local decision, reason, suggested
    if tier == "unfavourable" then
        decision = "retreat"
        reason = "local_threat_exceeds_force"
    elseif tier == "marginal" then
        -- Closer to unfavourable than favourable: consider a safer target.
        decision = "changetarget"
        reason = "tactical_mismatch"
    else
        decision = "continue"
        reason = "viable"
    end

    return {
        decision = decision,
        tier = tier,
        reason = reason,
        metrics = { ownPower = ownPower, enemyThreat = enemyThreat, ratio = ratio },
        suggestedTargetId = suggested,
    }
end

-- Periodic reassessment pulse. Returns the decision result; `.changed` is true
-- only when the clamped category (or an enemy composition change) flipped since
-- the previous pulse. Throttled to pulseEvery frames.
function EvaluatorMT:reassess(snap, frame)
    frame = frame or 0
    if frame < self._pulseNext then
        -- Not a pulse frame: return the last decision (unchanged) so callers can
        -- keep executing it without re-logging.
        local last = self._lastRes or {}
        return {
            decision = last.decision or "continue",
            tier     = last.tier or "neutral",
            reason   = last.reason or "no_pulse",
            metrics  = last.metrics or {},
            changed  = false,
            clamped  = true,   -- this is a "no new pulse" readout
        }
    end
    self._pulseNext = frame + self.pulseEvery

    local res = self:_evaluate(snap)

    local sig = Tactical.signature(snap)
    local lastSig = self._lastSig
    local sigChanged = not Tactical.signature_equals(lastSig, sig)
    local lastTier = self._lastRes and clampTier(self._lastRes.decision) or nil
    local newTier = clampTier(res.decision)
    local tierChanged = (lastTier and newTier ~= lastTier)

    res.changed = sigChanged or tierChanged
    res.clamped = false
    self._lastSig = sig
    self._lastRes = res
    return res
end

-- The decision that governs the current pulse (used between pulses if the caller
-- wants a stable readout).
function EvaluatorMT:current()
    return self._lastRes or {
        decision = "continue",
        tier     = "neutral",
        reason   = "fresh",
        metrics  = {},
        changed  = false,
    }
end

function EvaluatorMT:reset()
    self._lastSig = nil
    self._lastRes = nil
    self._pulseNext = 0
end

-- ---------------------------------------------------------------------------
-- Engine-facing snapshot builder (never retains engine objects)
-- ---------------------------------------------------------------------------

-- Build a snapshot from a live CombatStateTracker + a fresh local radius scan.
--   tracker - a framework.combat_state tracker that already holds the AI's own
--             attack force.
--   house   - the house doing the evaluating (enemy detection reference).
--   opts    - { radius = cells } (default 18).
-- Returns a pure snapshot: { own = {...}, enemies = {...}, target = {...} }.
-- Every field is a primitive (id / kind / typeName / ownerName / hp / maxHp /
-- x / y / dist / alive). No Techno or House userdata is returned.
function Tactical.buildSnapshot(tracker, house, opts)
    opts = opts or {}
    local radius = opts.radius or 18

    local own = {}
    local cx, cy, n = 0.0, 0.0, 0
    for _, id in ipairs(tracker and tracker:ids() or {}) do
        local rec = tracker:get(id)
        if rec and rec.alive ~= false then
            own[#own + 1] = rec
            if rec.x and rec.y then
                cx, cy, n = cx + rec.x, cy + rec.y, n + 1
            end
        end
    end
    if n > 0 then
        cx, cy = cx / n, cy / n
    end
    -- Integer cells from here on: the native radius scan rejects fractional
    -- coords ("number has no integer representation"), and a multi-unit
    -- centroid is always fractional. Applies to every scan below.
    cx, cy = math.floor(cx), math.floor(cy)

    -- Fresh local scan. Validate / filter via util.is_enemy. Includes buildings
    -- so AA towers / flak guns are visible threats.
    local enemies = {}
    for _, u in ipairs(World.GetUnitsInRadius(cx, cy, radius) or {}) do
        if util.is_alive(u) and util.is_enemy(house, u) then
            local okId, uid = pcall(u.GetId, u)
            local okHp, hp = pcall(u.GetHealth, u)
            local okMax, maxHp = pcall(u.GetMaxHealth, u)
            local okPos, pos = pcall(u.GetPosition, u)
            local okType, typeName = pcall(u.GetTypeName, u)
            local ex, ey = (okPos and pos and pos.x) or cx, (okPos and pos and pos.y) or cy
            local dx, dy = ex - cx, ey - cy
            enemies[#enemies + 1] = {
                id       = okId and uid or nil,
                kind     = util.kind_of(u),
                typeName = okType and typeName or nil,
                ownerName = nil,   -- enemy list is already enemy-filtered; owner not needed
                hp       = okHp and hp or 0,
                maxHp    = okMax and maxHp or 0,
                x        = ex,     -- map cells, primitives only; used for retreat vectors
                y        = ey,
                dist     = math.sqrt(dx * dx + dy * dy),
            }
        end
    end

    -- Resolve the current target. Use the force's active target id (first alive
    -- own unit that holds one) and look it up in the fresh radius set, so a
    -- neutral-civilian building can still be seen and rejected.
    local targetId
    for _, u in ipairs(own) do
        if u.targetId then
            targetId = u.targetId
            break
        end
    end

    local target
    if targetId then
        for _, e in ipairs(enemies) do
            if e.id == targetId then
                target = e
                break
            end
        end
        if not target then
            -- The target id may refer to a non-enemy (e.g. a neutral building) or
            -- reside just outside the enemy list. Do a guarded extras lookup over
            -- the same radius set to classify it without retaining anything.
            for _, u in ipairs(World.GetUnitsInRadius(cx, cy, radius) or {}) do
                local okId, uid = pcall(u.GetId, u)
                if okId and uid == targetId then
                    local okOwn, owner = pcall(u.GetOwner, u)
                    local ownerName
                    if okOwn and owner and owner.GetName then
                        local okN, nm = pcall(owner.GetName, owner)
                        if okN then ownerName = nm end
                    end
                    local okT2, t2 = pcall(u.GetTypeName, u)
                    target = {
                        id        = uid,
                        kind      = util.kind_of(u),
                        typeName  = okT2 and t2 or nil,
                        ownerName = ownerName,
                        dist      = 0,
                    }
                    break
                end
            end
        end
    end

    return {
        own     = own,
        enemies = enemies,
        target  = target,
    }
end

return Tactical
