-- LuaAPI Gameplay Framework — CombatStateTracker.
--
-- M14 Gate 1: a reliable, state-based observation layer for combat units.
--
-- It answers the questions a future tactical AI will need to ask, WITHOUT
-- making any decision:
--     * is this unit still alive?
--     * how much HP does it have / what's its max?
--     * who owns it?
--     * what is it currently targeting?
--     * where is it?
--     * is it attacking / moving / idle (what mission)?
--     * did its target disappear?
--     * did the unit itself disappear?
--
-- SAFETY MODEL (mirrors the C++ side and the rest of the framework):
--   * Units are tracked by their native engine-wide id only. The tracker never
--     stores a Techno or House userdata.
--   * Every update re-resolves tracked units from a FRESH World scan, exactly
--     like the M12/M14 showcases. Engine userdata live only for the duration of
--     one scan; nothing long-lived is retained.
--   * Only primitive snapshots (number / string / boolean) are kept, so a dead
--     unit is reported by value, never by a stale pointer.
--   * Targets are tracked by id and re-validated against an authoritative
--     all-techno scan, so a destroyed target does not remain silently valid.
--   * Destruction/invalidation is detected during the scan and cleanup is
--     DEFERRED until after the iteration is complete.
--
-- Using it:
--     local CombatState = require("framework.combat_state")
--     local tracker = CombatState.new({ eventBus = Framework.EventBus })
--
--     local id = tracker:track(someUnit)          -- add a live unit
--     tracker:update(frame)                        -- refresh every logical frame
--
--     local s = tracker:get(id)                    -- current snapshot (or nil)
--     print(s.hp, s.maxHp, s.ownerName, s.mission, s.targetId)
--     if tracker:target_is_alive(id) == false then ... end  -- target vanished
--     local invalid = tracker:drain_invalidated()  -- units that died this frame
--
-- No native hook or engine pointer is held. State lives in the tracker table
-- and is recreated with the VM on every session reset.

local util = require("framework.util")

local CombatStateTracker = {}
local CombatStateMT = {}
CombatStateMT.__index = CombatStateTracker

-- Minimum guaranteed fields so a freshly-created (not yet scanned) record still
-- has a stable shape. All of these are primitives; there is never a userdata.
local function blankRecord(id)
    return {
        id                = id,
        typeName          = nil,   -- string
        kind              = nil,   -- string
        ownerName         = nil,   -- string
        hp                = nil,   -- number
        maxHp             = nil,   -- number
        x                 = nil,   -- number (map cells)
        y                 = nil,   -- number
        z                 = nil,   -- number
        mission           = nil,   -- string | number
        isIdle            = nil,   -- boolean
        isAttacking       = nil,   -- boolean
        targetId          = nil,   -- number | nil (current target)
        lastTargetId      = nil,   -- number | nil (survives target death)
        targetTypeName    = nil,   -- string | nil
        targetKind        = nil,   -- string | nil
        alive             = false, -- boolean
        invalid           = false, -- boolean (detected destroyed / unreadable)
        version           = 0,     -- bumped on any observed change
        changes           = {},    -- per-update delta flags
        lastSeenFrame     = nil,   -- last frame the unit was confirmed alive
        invalidSinceFrame = nil,   -- first frame it was detected invalid
        lastValid         = nil,   -- deepest copy of the last known-good snapshot
    }
end

-- Snapshot one live unit into a pure-primitive table. Returns nil when the unit
-- cannot be safely read (it was destroyed mid-scan). Every engine call is
-- guarded, so a failure degrades to "invalid" rather than throwing.
local function snapshot(unit)
    if not util.is_alive(unit) then
        return nil
    end

    -- id is the tracking key; if we cannot read it we cannot keep the unit.
    local okId, id = pcall(unit.GetId, unit)
    if not okId or not id then
        return nil
    end

    local ok, typeName = pcall(unit.GetTypeName, unit)
    local okKind, kind = pcall(unit.GetKind, unit)
    local okHp, hp = pcall(unit.GetHealth, unit)
    local okMax, maxHp = pcall(unit.GetMaxHealth, unit)
    local okPos, pos = pcall(unit.GetPosition, unit)
    local okMission, mission = pcall(unit.GetMission, unit)
    local okIdle, isIdle = pcall(unit.IsIdle, unit)
    local okAtk, isAttacking = pcall(unit.IsAttacking, unit)

    -- Owner is a House userdata; we capture only its display name (a string) and
    -- never retain the userdata itself.
    local ownerName
    local okOwner, owner = pcall(unit.GetOwner, unit)
    if okOwner and owner and owner.GetName then
        local okName, name = pcall(owner.GetName, owner)
        if okName then ownerName = name end
    end

    -- Target is a Techno userdata; capture only id / type / kind. No reference
    -- to the target object is kept after this frame.
    local targetId, targetTypeName, targetKind
    local okTarget, target = pcall(unit.GetTarget, unit)
    if okTarget and target and util.is_alive(target) then
        local okTId, tid = pcall(target.GetId, target)
        if okTId and tid then targetId = tid end
        local okTType, ttype = pcall(target.GetTypeName, target)
        if okTType then targetTypeName = ttype end
        local okTKind, tkind = pcall(target.GetKind, target)
        if okTKind then targetKind = tkind end
    end

    return {
        id           = id,
        typeName     = ok and typeName or nil,
        kind         = okKind and kind or nil,
        ownerName    = ownerName,
        hp           = okHp and hp or nil,
        maxHp        = okMax and maxHp or nil,
        x            = okPos and pos and pos.x or nil,
        y            = okPos and pos and pos.y or nil,
        z            = okPos and pos and pos.z or nil,
        mission      = okMission and mission or nil,
        isIdle       = okIdle and isIdle or false,
        isAttacking  = okAtk and isAttacking or false,
        targetId     = targetId,
        targetTypeName = targetTypeName,
        targetKind   = targetKind,
    }
end

-- Compare the previous record state against a fresh snapshot and fold the
-- differences into rec.changes. Only scalar/primitive fields are compared.
local function diffToChanges(rec, snap)
    local changes = {}

    if rec.hp ~= snap.hp then changes.hp = true end
    if rec.maxHp ~= snap.maxHp then changes.maxHp = true end
    if rec.ownerName ~= snap.ownerName then changes.ownerName = true end
    if rec.typeName ~= snap.typeName then changes.typeName = true end
    if rec.kind ~= snap.kind then changes.kind = true end
    if rec.x ~= snap.x or rec.y ~= snap.y or rec.z ~= snap.z then
        changes.position = true
    end
    if rec.mission ~= snap.mission then changes.mission = true end
    if rec.isIdle ~= snap.isIdle then changes.isIdle = true end
    if rec.isAttacking ~= snap.isAttacking then changes.isAttacking = true end
    if rec.targetId ~= snap.targetId then changes.target = true end

    if rec.lastTargetId and rec.lastTargetId ~= snap.targetId then
        -- We still hold a previous target that is no longer current; flag it.
        changes.targetLost = true
    end

    return changes
end

-- Apply a fresh snapshot onto rec, updating lastValid and change bookkeeping.
local function applySnapshot(rec, snap, frame)
    local changes = diffToChanges(rec, snap)
    local changed = next(changes) ~= nil

    -- Preserve the last known-good target id when the target vanished.
    if rec.targetId and rec.targetId ~= snap.targetId then
        rec.lastTargetId = rec.targetId
    end

    rec.typeName       = snap.typeName
    rec.kind           = snap.kind
    rec.ownerName      = snap.ownerName
    rec.hp             = snap.hp
    rec.maxHp          = snap.maxHp
    rec.x              = snap.x
    rec.y              = snap.y
    rec.z              = snap.z
    rec.mission        = snap.mission
    rec.isIdle         = snap.isIdle
    rec.isAttacking    = snap.isAttacking
    rec.targetId       = snap.targetId
    rec.targetTypeName = snap.targetTypeName
    rec.targetKind     = snap.targetKind
    rec.alive          = true
    rec.invalid        = false

    if snapshot then
        rec.lastValid = {}
        for k, v in pairs(snap) do
            rec.lastValid[k] = v
        end
    end

    rec.lastSeenFrame = frame

    if changed then
        rec.changes = changes
        rec.version = (rec.version or 0) + 1
    else
        rec.changes = {}
    end
end

-- Mark a record invalid (destroyed / unreadable) exactly once. Deferred cleanup
-- (physical removal) is handled by the caller after iteration.
local function markInvalid(rec, frame, invalidatedList)
    if rec.invalid then
        return
    end
    rec.alive = false
    rec.invalid = true
    rec.invalidSinceFrame = frame
    rec.changes = { invalid = true }
    rec.version = (rec.version or 0) + 1
    invalidatedList[#invalidatedList + 1] = rec
end

-- ----------------------------------------------------------------------------
-- Constructor
-- ----------------------------------------------------------------------------

-- Create a tracker. opts:
--   eventBus   - optional EventBus; if provided the tracker emits
--                "combat_state_changed" and "combat_unit_invalidated".
--   keepDead   - keep invalidated records so lastValid stays queryable
--                (default true; prune() / untrack() remove them explicitly).
--   invalidTtl - how many frames an invalid record is kept before deferred
--                removal (default 60, used only when keepDead is true).
--   pulseEvery - frames between the authoritative all-techno target-liveness
--                scan (default 10; the whole-map scan is comparatively costly).
function CombatStateTracker.new(opts)
    opts = opts or {}
    return setmetatable({
        _units       = {},      -- id -> record
        _scan        = {},      -- id -> userdata; valid only within update()
        _targetAlive = {},      -- id -> true|false, authoritative target set
        _pulse       = opts.pulseEvery or 10,
        _pulseNext   = 0,
        _frame       = 0,
        _keepDead    = opts.keepDead ~= false,
        _invalidTtl  = opts.invalidTtl or 60,
        _eventBus    = opts.eventBus,
        _invalidated = {},      -- drained via drain_invalidated()
    }, CombatStateMT)
end

-- Convenience accessors on the prototype keep the public surface small.

-- Emit an EventBus event if one was supplied. Never throws.
function CombatStateTracker:_emit(event, ...)
    local bus = self._eventBus
    if bus and bus.emit then
        pcall(bus.emit, bus, event, ...)
    end
end

function CombatStateTracker:_refreshTargetLiveness(frame)
    if frame < self._pulseNext then
        return
    end
    self._pulseNext = frame + self._pulse

    -- Only scan when some tracked unit currently holds a target; avoids the
    -- whole-map cost when there is nothing to validate.
    local need = false
    for _, rec in pairs(self._units) do
        if rec.targetId or rec.lastTargetId then need = true; break end
    end
    if not need then
        return
    end

    -- Authoritative set of every valid techno (buildings, units, infantry,
    -- aircraft). A target id absent from this set is gone.
    local alive = {}
    local ok, all = pcall(World.GetAllUnits)
    if ok and all then
        for _, u in ipairs(all) do
            if util.is_alive(u) then
                local okId, id = pcall(u.GetId, u)
                if okId and id then alive[id] = true end
            end
        end
    end
    self._targetAlive = alive

    for _, rec in pairs(self._units) do
        local tid = rec.targetId or rec.lastTargetId
        if tid and not alive[tid] then
            -- The target we were holding is no longer a valid techno. The
            -- primary target (rec.targetId) is cleared so a following frame
            -- does not repeatedly report the loss; lastTargetId remembers it.
            if rec.targetId then
                rec.changes.targetLost = true
            end
            rec.lastTargetId = tid
            rec.targetId = nil
            rec.targetTypeName = nil
            rec.targetKind = nil
            rec.version = (rec.version or 0) + 1
        end
    end
end

-- ----------------------------------------------------------------------------
-- Tracking API
-- ----------------------------------------------------------------------------

-- Track a live unit. Returns its id, or nil if the unit is invalid and cannot
-- be tracked. Does not hold the userdata.
function CombatStateTracker:track(unit)
    if not unit or not util.is_alive(unit) then
        return nil
    end
    local okId, id = pcall(unit.GetId, unit)
    if not okId or not id then
        return nil
    end
    if self._units[id] then
        return id
    end
    local rec = blankRecord(id)
    self._units[id] = rec
    -- Seed immediately so state is queryable even if the unit dies before the
    -- next update().
    local snap = snapshot(unit)
    if snap then
        applySnapshot(rec, snap, self._frame)
    end
    return id
end

-- Track a unit known only by id (filled on the next update). Registration by
-- numeric id is safe: it never dereferences anything.
function CombatStateTracker:trackById(id)
    if not id or self._units[id] then
        return id
    end
    self._units[id] = blankRecord(id)
    return id
end

-- Stop tracking a unit by id.
function CombatStateTracker:untrack(id)
    self._units[id] = nil
end

-- Drop every invalidated record (and any recently-pruned-by-TTL ones). Deferred
-- removal may run here safely. Returns the number removed.
function CombatStateTracker:prune()
    local removed = 0
    for id, rec in pairs(self._units) do
        if rec and rec.invalid and not self._keepDead then
            self._units[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- ----------------------------------------------------------------------------
-- Per-frame refresh
-- ----------------------------------------------------------------------------

-- Refreshes every tracked unit from a fresh World scan; detects destruction,
-- target loss, and state changes. Returns a list of records invalidated this
-- frame (also available through drain_invalidated()).
function CombatStateTracker:update(frame)
    self._frame = frame

    -- 1) Fresh scan of mobile units (vehicles/infantry/aircraft). This is the
    --    source set for tracked combat units. userdata in `scan` expire at the
    --    end of this function; nothing is retained.
    local found = {}
    local okUnits, units = pcall(World.GetUnits)
    if okUnits and units then
        for _, u in ipairs(units) do
            if util.is_alive(u) then
                local okId, id = pcall(u.GetId, u)
                if okId and id then
                    found[id] = u
                end
            end
        end
    end
    self._scan = found

    -- 2) Refresh / invalidate each record (snapshots applied first so target
    --    liveness below sees the freshest rec.targetId).
    local invalidated = {}
    for id, rec in pairs(self._units) do
        if rec.invalid then
            -- Already gone: let TTL-based deferred removal finish it, and do not
            -- re-report it.
            rec.invalidSinceFrame = rec.invalidSinceFrame or frame
        else
            local live = found[id]
            if live and util.is_alive(live) then
                local snap = snapshot(live)
                if snap then
                    applySnapshot(rec, snap, frame)
                else
                    markInvalid(rec, frame, invalidated)
                end
            else
                markInvalid(rec, frame, invalidated)
            end
        end
    end

    -- 3) Validate target liveness against the authoritative all-techno set,
    --    using the current (just-refreshed) targets.
    self:_refreshTargetLiveness(frame)

    -- 4) Emit events for this frame (after all reads are done).
    for _, rec in ipairs(invalidated) do
        self:_emit("combat_unit_invalidated", rec.id, rec.lastValid)
    end
    for id, rec in pairs(self._units) do
        if rec.changes and not rec.invalid then
            self:_emit("combat_state_changed", id, rec.changes, rec.version)
        end
    end

    -- 5) Deferred removal of expired invalid records.
    if self._keepDead then
        for id, rec in pairs(self._units) do
            if rec.invalid
                and rec.invalidSinceFrame
                and (frame - rec.invalidSinceFrame) >= self._invalidTtl
            then
                self._units[id] = nil
            end
        end
    end

    self._invalidated = invalidated
    return invalidated
end

-- ----------------------------------------------------------------------------
-- Query API (all read-only, no engine access)
-- ----------------------------------------------------------------------------

-- Does the tracker currently manage this id at all?
function CombatStateTracker:has(id)
    return self._units[id] ~= nil
end

-- Is the tracked unit currently alive? Returns false for invalid, unknown, or
-- not-yet-scanned ids.
function CombatStateTracker:is_alive(id)
    local rec = self._units[id]
    return rec ~= nil and rec.alive == true
end

-- Return a copy of the current known-good snapshot for a LIVE unit, or nil.
-- The snapshot is primitives only (no userdata).
function CombatStateTracker:get(id)
    local rec = self._units[id]
    if not rec or rec.invalid or not rec.alive then
        return nil
    end
    local out = {}
    for k, v in pairs(rec) do
        if k ~= "changes" and k ~= "lastValid" then
            out[k] = v
        end
    end
    return out
end

-- Return the last known-valid snapshot even after the unit was destroyed, or
-- nil for never-valid / unknown ids. Useful for post-mortem reports.
function CombatStateTracker:get_last_valid(id)
    local rec = self._units[id]
    if not rec then
        return nil
    end
    local out = {}
    for k, v in pairs(rec.lastValid or {}) do
        out[k] = v
    end
    return out
end

-- Target liveness for a tracked unit:
--   nil  -> unit unknown, or it had no target
--   true -> its current/last target is a live techno
--   false-> its target is no longer valid (destroyed / gone)
function CombatStateTracker:target_is_alive(id)
    local rec = self._units[id]
    if not rec then
        return nil
    end
    local tid = rec.targetId or rec.lastTargetId
    if not tid then
        return nil
    end
    return self._targetAlive[tid] == true
end

-- The current target id of a tracked unit, or nil.
function CombatStateTracker:target_id(id)
    local rec = self._units[id]
    return rec and rec.targetId or nil
end

-- Number of tracked units.
function CombatStateTracker:count()
    local n = 0
    for _ in pairs(self._units) do n = n + 1 end
    return n
end

-- Iterate all tracked ids.
function CombatStateTracker:ids()
    local out = {}
    for id in pairs(self._units) do out[#out + 1] = id end
    return out
end

-- Drain and clear the per-update invalidation report.
function CombatStateTracker:drain_invalidated()
    local out = self._invalidated or {}
    self._invalidated = {}
    return out
end

-- Clear all state (session reset).
function CombatStateTracker:clear()
    self._units = {}
    self._scan = {}
    self._targetAlive = {}
    self._invalidated = {}
    self._frame = 0
    self._pulseNext = 0
end

-- The last frame update() saw.
function CombatStateTracker:frame()
    return self._frame
end

return CombatStateTracker
