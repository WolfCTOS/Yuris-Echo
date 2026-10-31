-- LuaAPI Gameplay Framework — ForceGroup.
--
-- M14 Gate 3: a reusable multi-force / group manager.
--
-- It coordinates SEVERAL independent attack-force groups (squads), each with its
-- own CombatStateTracker (Gate 1) and TacticalDecision evaluator (Gate 2), all
-- driven from ONE per-frame update. Each group independently runs the full
-- OBSERVE → EVALUATE → DECIDE → ACT → REASSESS loop, so two groups in different
-- places can reach different decisions on the same frame.
--
-- Generic, NOT unit-specific:
--   * No `if typeName == "SOME_UNIT"`. The decision comes entirely from the
--     Gate 2 evaluator's threat/target scoring; the ACT step here only maps a
--     decision to engine commands (MoveTo / Attack / Stop).
--   * Units are tracked by id ONLY (via CombatStateTracker); the manager never
--     retains a Techno or House userdata. Every action re-resolves members from
--     a fresh World scan for the duration of that ACT.
--   * The house used for enemy detection is resolved through a `getHouse`
--     callback (default: House.GetPlayer) on every pulse, so no House userdata
--     is held as persistent state.
--
-- This is the minimum manager. It does NOT do platoons, commanders, morale,
-- reinforcement, economy, production, or strategic-map AI — those belong to
-- later milestones. Each group is a self-contained tactical unit.
--
-- Using it:
--     local ForceGroup = require("framework.force_group")
--
--     local mgr = ForceGroup.new({ radius = 18, pulseEvery = 15 })
--     local g = mgr:add_group({ id = "alpha", getHouse = function() return House.GetPlayer() end })
--     g:add_member(unit)          -- track a unit by id
--     g:add_member_by_id(1234)
--
--     function MyMod.Update(frame)
--         mgr:update(frame)        -- advance every group's Observe/Eval/Decide/Act/Reassess
--         local d = g:decision()    -- current decision ("continue" | ... )
--     end
--
-- Configurable: a group can override the ACT step with `set_handler("onAct", fn)`
-- for custom behavior; otherwise the manager provides a sensible generic handler.

local CombatState = require("framework.combat_state")
local Tactical = require("framework.tactical")
local util = require("framework.util")

local ForceGroup = {}

-- Default tuning shared by a manager's groups.
local DEFAULTS = {
    radius       = 18,   -- local battlefield radius (cells) for evaluation
    pulseEvery   = 15,   -- frames between reassessment pulses
    rangeRadius  = 14,   -- how far an enemy must be to be attackable
    retreatDist  = 12,   -- retreat vector length (cells)
    retreatHold  = 90,   -- frames a retreat stays in effect before release
    clampLo      = 2,    -- on-map cell clamp lower bound
    clampHi      = 254,  -- on-map cell clamp upper bound
}

-- ---------------------------------------------------------------------------
-- Small pure helpers (no engine state)
-- ---------------------------------------------------------------------------

local function clampCell(v, lo, hi)
    return math.max(lo, math.min(hi, math.floor(v + 0.5)))
end

-- Weighted centroid of the hostile force in a snapshot (cells). Returns x, y, n.
local function hostileCentroid(snap)
    local hx, hy, n = 0.0, 0.0, 0
    for _, e in ipairs(snap.enemies or {}) do
        if e and e.x and e.y then
            hx, hy, n = hx + e.x, hy + e.y, n + 1
        end
    end
    if n == 0 then return nil, nil, 0 end
    return hx / n, hy / n, n
end

-- Retreat destination for a unit position, away from the hostile centroid.
local function retreatDestination(pos, hx, hy, dist, lo, hi)
    local dx = (pos.x or 0) - hx
    local dy = (pos.y or 0) - hy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then
        dx, dy, len = 1, 0, 1   -- standing on the centroid: pick a fixed heading
    end
    return clampCell((pos.x or 0) + (dx / len) * dist, lo, hi),
           clampCell((pos.y or 0) + (dy / len) * dist, lo, hi)
end

-- ---------------------------------------------------------------------------
-- Group object
-- ---------------------------------------------------------------------------

local GroupMT = {}
GroupMT.__index = GroupMT

-- Create one group. opts:
--   id       - unique group key (string / number)
--   getHouse - function returning the owning house (default House.GetPlayer)
--   radius/pulseEvery/rangeRadius/retreatDist/retreatHold - tuning overrides
function ForceGroup.newGroup(opts)
    opts = opts or {}
    local cfg = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    for k, v in pairs(opts) do
        if k ~= "id" and k ~= "getHouse" and k ~= "members" then cfg[k] = v end
    end

    return setmetatable({
        id       = opts.id or ("group_" .. tostring(ForceGroup._nextId)),
        getHouse = opts.getHouse or function() return House.GetPlayer() end,
        cfg      = cfg,
        tracker  = CombatState.new({
            keepDead   = true,
            invalidTtl = cfg.retreatHold or 90,
            pulseEvery = math.min(10, cfg.pulseEvery or 15),
        }),
        tactical = Tactical.new({
            pulseEvery = cfg.pulseEvery,
            radius     = cfg.radius,
        }),
        _targetId    = nil,
        _retreat     = false,
        _retreatUntil = 0,
        _retreatCell = nil,
        _lastRes     = nil,
        _nextId      = 0,
        _handlers    = {},
        _tag         = opts.tag,
    }, GroupMT)
end

-- Emit a group event via an optional handler (pcall-isolated).
function GroupMT:_fire(name, ...)
    local fn = self._handlers[name]
    if fn then
        pcall(fn, self, ...)
    end
end

-- Manage members.
function GroupMT:add_member(unit)
    return self.tracker:track(unit)
end

function GroupMT:add_member_by_id(id)
    return self.tracker:trackById(id)
end

function GroupMT:remove_member(id)
    self.tracker:untrack(id)
end

-- Query hooks (delegate to the tracker).
function GroupMT:has(id)            return self.tracker:has(id) end
function GroupMT:is_alive(id)       return self.tracker:is_alive(id) end
function GroupMT:get(id)            return self.tracker:get(id) end
function GroupMT:count()            return self.tracker:count() end
function GroupMT:ids()              return self.tracker:ids() end
function GroupMT:target_id()        return self._targetId end

-- Register a handler: "onAct"  (group, res, snap, frame)  -> optional custom action
--                       "onDecision" (group, res)         -> observe decisions
function GroupMT:set_handler(name, fn)
    if type(fn) == "function" then
        self._handlers[name] = fn
    end
end

-- The most recent decision result.
function GroupMT:decision()
    return self._lastRes or {
        decision = "continue", tier = "neutral", reason = "fresh",
        metrics = {}, changed = false,
    }
end

-- The group's centroid (cells) from its alive members. Floored to integer
-- cells: consumers pass it to the native radius scan, which rejects floats
-- ("number has no integer representation").
function GroupMT:centroid()
    local cx, cy, n = 0.0, 0.0, 0
    for _, id in ipairs(self:ids()) do
        local rec = self:get(id)
        if rec and rec.x and rec.y then
            cx, cy, n = cx + rec.x, cy + rec.y, n + 1
        end
    end
    if n == 0 then return nil, nil end
    return math.floor(cx / n), math.floor(cy / n)
end

-- Current target object (re-resolved fresh, or nil).
function GroupMT:_currentTarget()
    if not self._targetId then return nil end
    local ok, units = pcall(World.GetUnits)
    if not ok or not units then return nil end
    for _, u in ipairs(units) do
        local okId, id = pcall(u.GetId, u)
        if okId and id == self._targetId and util.is_alive(u) then
            return u
        end
    end
    return nil
end

-- Resolve a single member by id.
function GroupMT:_memberById(id)
    local ok, units = pcall(World.GetUnits)
    if not ok or not units then return nil end
    for _, u in ipairs(units) do
        local okId, uid = pcall(u.GetId, u)
        if okId and uid == id then
            return u
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Generic ACT handler (default). Maps a decision to engine commands.
-- This is deliberately generic: it reads only `res.decision`, `snap`, and the
-- group's members by id. It never looks at a unit type name to decide anything.
-- ---------------------------------------------------------------------------
function GroupMT:_actDefault(res, snap, frame)
    local cfg = self.cfg

    -- RETREAT: high priority, lasting order. Move every surviving member away
    -- from the hostile centroid (a real MoveTo, never just Stop).
    if res.decision == "retreat" then
        if not self._retreat then
            self._retreatUntil = frame + (cfg.retreatHold or 90)
        end
        self._retreat = true
        self._targetId = nil

        local hx, hy, n = hostileCentroid(snap)
        for _, id in ipairs(self:ids()) do
            local u = self:_memberById(id)
            if not u then
                -- member not resolvable; nothing to order
            elseif n <= 0 then
                -- No hostile coords: hold position rather than attack.
                pcall(u.Stop, u)
            else
                local okP, pos = pcall(u.GetPosition, u)
                if okP and pos then
                    local tx, ty = retreatDestination(pos, hx, hy, cfg.retreatDist, cfg.clampLo, cfg.clampHi)
                    local okM, acc = pcall(u.MoveTo, u, tx, ty)
                    if okM and acc then
                        self._retreatCell = { x = tx, y = ty }
                    else
                        pcall(u.Stop, u)
                    end
                else
                    pcall(u.Stop, u)
                end
            end
        end
        return
    end

    -- Non-retreat: release the retreat only after the hold window.
    if self._retreat then
        if frame < self._retreatUntil then
            return
        end
        self._retreat = false
        self._retreatCell = nil
        self._fire("retreatReleased")
    end

    -- DISENGAGE: nothing to fight with / command says so.
    if res.decision == "disengage" then
        for _, id in ipairs(self:ids()) do
            local u = self:_memberById(id)
            if u then pcall(u.Stop, u) end
        end
        return
    end

    -- TARGET SELECTION: continue uses the current target; changetarget /
    -- find_target pick the highest-threat legitimate enemy nearby.
    local centerX, centerY = self:centroid()
    if not centerX then return end

    local ok, found = pcall(World.GetUnitsInRadius, centerX, centerY, cfg.rangeRadius or 14)
    if not ok or not found then found = {} end

    local house = self:getHouse() and self:getHouse() or nil
    local best, bestThreat = nil, -1
    local wantTarget = self._targetId
    for _, u in ipairs(found) do
        if util.is_alive(u) and house and util.is_enemy(house, u) then
            local okT, tn = pcall(u.GetTypeName, u)
            local okH, hp = pcall(u.GetHealth, u)
            local okM, mh = pcall(u.GetMaxHealth, u)
            local th = Tactical.enemy_threat({
                kind     = util.kind_of(u),
                typeName = okT and tn or nil,
                hp       = okH and hp or 0,
                maxHp    = okM and mh or 0,
                dist     = 0,
            }, cfg.radius or 18)
            if th > bestThreat then
                bestThreat = th
                best = u
            end
        end
    end

    if res.decision == "continue" then
        -- Keep attacking the current target if it is still valid.
        local t = self:_currentTarget()
        if t then
            for _, id in ipairs(self:ids()) do
                local u = self:_memberById(id)
                if u then pcall(u.Attack, u, t) end
            end
            return
        end
        -- No current target: fall through to a fresh pickup.
    end

    -- (changetarget / find_target / continue-with-no-target) attack the best.
    if best then
        local okId, bid = pcall(best.GetId, best)
        if okId then self._targetId = bid end
        for _, id in ipairs(self:ids()) do
            local u = self:_memberById(id)
            if u then pcall(u.Attack, u, best) end
        end
    end
end

-- Run one full Observe → Evaluate → Decide → Act → Reassess step for this group.
function GroupMT:update(frame)
    -- OBSERVE: refresh the tracker (Gate 1) — re-resolves every member by id.
    self.tracker:update(frame)

    -- EVALUATE + DECIDE (Gate 2): build a pure snapshot and reassess.
    local snap = Tactical.buildSnapshot(self.tracker, self:getHouse(), { radius = self.cfg.radius })
    local res = self.tactical:reassess(snap, frame)

    local prev = self._lastRes
    self._lastRes = res
    self:_fire("onDecision", res)

    -- ACT: delegate to a custom handler or the generic one.
    local custom = self._handlers.onAct
    pcall(custom or self._actDefault, self, res, snap, frame)

    -- REASSESS is inherently the next pulse's evaluate(); nothing more to do.
    return res
end

function GroupMT:reset()
    self._targetId = nil
    self._retreat = false
    self._retreatUntil = 0
    self._retreatCell = nil
    self._lastRes = nil
    self.tracker:clear()
end

-- ---------------------------------------------------------------------------
-- Manager: owns many groups and drives them all from one update.
-- ---------------------------------------------------------------------------

local ManagerMT = {}
ManagerMT.__index = ManagerMT

-- opts: shared defaults (radius / pulseEvery / ...) applied to every group.
function ForceGroup.new(opts)
    opts = opts or {}
    -- Manager defaults merge into each group's per-group defaults.
    return setmetatable({
        _groups = {},
        _opts   = opts,
    }, ManagerMT)
end

-- Add a new group. Returns the group object.
function ManagerMT:add_group(opts)
    opts = opts or {}
    -- Merge manager-level tuning defaults into the group options.
    for k, v in pairs(self._opts) do
        if opts[k] == nil then opts[k] = v end
    end
    local g = ForceGroup.newGroup(opts)
    self._groups[g.id] = g
    return g
end

function ManagerMT:group(id)
    return self._groups[id]
end

function ManagerMT:remove_group(id)
    local g = self._groups[id]
    if g then g:reset() end
    self._groups[id] = nil
end

-- Every group's id.
function ManagerMT:group_ids()
    local out = {}
    for id in pairs(self._groups) do out[#out + 1] = id end
    return out
end

-- Advance every group's tactical loop for this frame.
function ManagerMT:update(frame)
    local results = {}
    for id, g in pairs(self._groups) do
        local ok, res = pcall(g.update, g, frame)
        if ok then results[#results + 1] = { id = id, res = res }
        else
            -- A failing group must not break the others (handler is isolated).
            util.log_error("ForceGroup %s update error: %s", tostring(id), tostring(res))
            results[#results + 1] = { id = id, res = g:decision() }
        end
    end
    return results
end

function ManagerMT:reset()
    for _, g in pairs(self._groups) do g:reset() end
end

return ForceGroup
