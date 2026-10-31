-- LuaAPI Gameplay Framework — Task.
--
-- M14.4: a minimal multi-step action abstraction so gameplay scripts don't
-- hand-roll a state machine for every small maneuver.
--
-- A **node** is one step (a function over (unit, frame) returning a status).
-- A **task** is a runnable wrapper that owns one node and tracks its lifecycle:
--     created -> running -> completed | cancelled | failed
--
-- Node status values (strings):
--     "running"   — not finished this frame
--     "done"      — this step finished (move completed, target destroyed, wait over)
--     "failed"    — unrecoverable (unit died, cannot proceed)
--     "cancelled" — externally aborted
--
--     local task = Task.create({
--         Task.MoveTo(unit, 100, 120),
--         Task.Wait(30),
--         Task.Attack(unit, enemy),
--     })
--     local status = task:update(unit, frame)
--
-- Nodes are deliberately small and stateless outside their own counters. They
-- never capture an engine object they cannot re-validate: MoveTo captures only
-- coordinates; Attack captures the target and re-checks it via IsAlive() every
-- frame, treating a vanished target as "done". This keeps the framework from
-- pinning a stale TechnoClass*.
--
-- M14 deliberately stops here: no Behavior Trees, no GOAP, no coroutine
-- scheduler. Sequence/Loop are the only composites provided.

local util = require("framework.util")

local Task = {}

local STATUS = {
    CREATED   = "created",
    RUNNING   = "running",
    DONE      = "done",
    COMPLETED = "completed",
    FAILED    = "failed",
    CANCELLED = "cancelled",
}

-- Helpers -------------------------------------------------------------------

-- A boxed node: name + _update(unit, frame, ctx) + optional _reset().
local function node(name, update)
    return {
        __type  = name,
        _update = update,
        _reset  = function(self) end,
    }
end

-- MoveTo ------------------------------------------------------------------
-- Issue a move order once, then watch until the unit is within `threshold`
-- cells, goes idle, or a timeout passes. A rejected or un-reachable move is
-- treated as "done" so a sequence never stalls on an impossible destination.
function Task.MoveTo(x, y, opts)
    opts = opts or {}
    local threshold = opts.threshold or 1.5   -- cells from destination
    local timeout   = opts.timeout or 300     -- frames before giving up
    local reissue   = opts.reissue or 15      -- frames between re-tries
    return node("MoveTo", function(self, unit, frame)
        if not util.is_alive(unit) then
            return STATUS.FAILED
        end
        if not self.started then
            self.started = true
            self.startFrame = frame
            self.lastIssue = frame
            local ok, accepted = pcall(unit.MoveTo, unit, x, y)
            if not ok then
                util.log_error("Task.MoveTo: MoveTo raised error: %s", tostring(accepted))
                return STATUS.DONE
            end
            self.accepted = accepted
        elseif not self.accepted and (frame - self.lastIssue) >= reissue then
            -- Pathfinding was blocked; retry the move occasionally.
            self.lastIssue = frame
            local ok, accepted = pcall(unit.MoveTo, unit, x, y)
            if ok then
                self.accepted = accepted
            end
        end

        if util.near(unit, x, y, threshold) then
            return STATUS.DONE
        end
        if util.is_idle(unit) then
            return STATUS.DONE
        end
        if (frame - (self.startFrame or frame)) >= timeout then
            return STATUS.DONE
        end
        return STATUS.RUNNING
    end)
end

-- Attack ------------------------------------------------------------------
-- Order an attack on a target, then wait until combat concluded (target gone /
-- the unit no longer holds it) or a timeout. A vanished target is "done".
function Task.Attack(target, opts)
    opts = opts or {}
    local timeout = opts.timeout or 600
    return node("Attack", function(self, unit, frame)
        if not util.is_alive(unit) or not util.is_alive(target) then
            return STATUS.DONE
        end
        if not self.issued then
            self.issued = true
            self.issuedFrame = frame
            self.attempts = 0
            local ok, res = pcall(unit.Attack, unit, target)
            if not ok or not res then
                -- Rejected (unreachable, no weapon, etc.); retry a little.
                self.attempts = self.attempts + 1
                self.issued = false
                if self.attempts >= 5 then
                    return STATUS.DONE
                end
                return STATUS.RUNNING
            end
        end

        -- Small grace period so the native target assignment propagates
        -- before we conclude combat.
        local current = unit:GetTarget()
        if current == nil and frame - (self.issuedFrame or frame) > 3 then
            return STATUS.DONE
        end
        if (frame - (self.issuedFrame or frame)) >= timeout then
            return STATUS.DONE
        end
        return STATUS.RUNNING
    end)
end

-- Wait ---------------------------------------------------------------------
-- Pauses the sequence for `frames` logical frames.
function Task.Wait(frames)
    frames = math.max(0, math.floor(frames or 1))
    return node("Wait", function(self, _unit, _frame)
        if not self.started then
            self.started = true
            self.remaining = frames
            if self.remaining <= 0 then
                return STATUS.DONE
            end
            return STATUS.RUNNING
        end
        self.remaining = self.remaining - 1
        if self.remaining <= 0 then
            return STATUS.DONE
        end
        return STATUS.RUNNING
    end)
end

-- Call a custom function as a task step. fn(unit, frame) returns a status.
function Task.Fn(fn)
    if type(fn) ~= "function" then
        return node("Fn", function() return STATUS.DONE end)
    end
    return node("Fn", function(self, unit, frame)
        local ok, status = pcall(fn, unit, frame)
        if not ok then
            util.log_error("Task.Fn: error: %s", tostring(status))
            return STATUS.FAILED
        end
        if status == STATUS.DONE or status == STATUS.FAILED or status == STATUS.CANCELLED then
            return status
        end
        return STATUS.RUNNING
    end)
end

-- Sequence ------------------------------------------------------------------
-- Runs each child in order until finished. A child that returns "done" moves
-- the sequence to the next child in the same frame (so a fast chain of already
-- completed steps does not wait a frame each).
function Task.Sequence(children)
    local seq = {
        __type   = "Sequence",
        children = children or {},
        idx      = 1,
    }

    function seq:_update(unit, frame)
        while self.idx <= #self.children do
            local child = self.children[self.idx]
            local status = child:_update(unit, frame)
            if status == STATUS.DONE then
                self.idx = self.idx + 1
            elseif status ~= STATUS.RUNNING then
                return status  -- failed / cancelled propagates up
            else
                return STATUS.RUNNING
            end
        end
        return STATUS.DONE
    end

    function seq:_reset()
        self.idx = 1
        for _, child in ipairs(self.children) do
            child:_reset()
        end
    end

    return seq
end

-- Loop ----------------------------------------------------------------------
-- Repeats a sequence forever (until cancelled or a child fails). Used for
-- indefinite patrols. Returns "running" indefinitely.
function Task.Loop(children)
    return node("Loop", function(self, unit, frame)
        if not self.seq then
            self.seq = Task.Sequence(children)
        end
        local status = self.seq:_update(unit, frame)
        if status == STATUS.DONE then
            self.seq:_reset()
            return STATUS.RUNNING
        end
        return status  -- running / failed / cancelled
    end)
end

-- Runnable task object ------------------------------------------------------

local TaskMeta = {}
TaskMeta.__index = TaskMeta

function TaskMeta:__tostring()
    return "Task[" .. tostring(self.name) .. "]:" .. tostring(self.state)
end

function TaskMeta:update(unit, frame)
    if self.state == STATUS.COMPLETED or
       self.state == STATUS.CANCELLED or
       self.state == STATUS.FAILED then
        return self.state
    end

    if self.state == STATUS.CREATED then
        self.state = STATUS.RUNNING
    end

    local status = self.node:_update(unit, frame)
    if status == STATUS.DONE then
        self.state = STATUS.COMPLETED
    elseif status == STATUS.FAILED then
        self.state = STATUS.FAILED
    elseif status == STATUS.CANCELLED then
        self.state = STATUS.CANCELLED
    end
    return self.state
end

function TaskMeta:cancel()
    if self.state ~= STATUS.COMPLETED and self.state ~= STATUS.CANCELLED and self.state ~= STATUS.FAILED then
        self.state = STATUS.CANCELLED
    end
end

function TaskMeta:get_state()
    return self.state
end

function TaskMeta:is_done()
    return self.state == STATUS.COMPLETED
end

function TaskMeta:is_finished()
    return self.state == STATUS.COMPLETED or
           self.state == STATUS.CANCELLED or
           self.state == STATUS.FAILED
end

-- Create a runnable task from an array of nodes (or a single node).
--   local t = Task.create({ Task.MoveTo(...), Task.Wait(20) })
--   local t = Task.create(Task.Loop({ ... }))
function Task.create(nodes, name)
    local root
    if type(nodes) == "table" and nodes._update then
        root = nodes                       -- single node / composite
    else
        root = Task.Sequence(nodes or {})
    end

    return setmetatable({
        name  = name or (root and root.__type or "Task"),
        node  = root,
        state = STATUS.CREATED,
    }, TaskMeta)
end

return Task
