-- Tactical Patrol (Milestone 14 / Gate 14.7)
--
-- Demonstrates the M14 Lua Gameplay Framework:
--
--     Tactical Patrol
--          ↓
--     UnitController
--          ↓
--     Task
--          ↓
--     Query
--          ↓
--     LuaAPI primitives
--
-- Gameplay:
--   1. Find one player combat unit.
--   2. Patrol between two points around the player's base.
--   3. Periodically scan for an enemy.
--   4. Interrupt patrol when an enemy is detected.
--   5. Attack the target.
--   6. Resume patrol when combat ends.
--
-- The showcase contains no hand-written task/state machine.
-- Decisions stay here. Execution stays in the framework.

-- NOTE: never require("framework.init") here — init requires THIS file, which
-- recurses into a C stack overflow for every mod that touches the framework.
-- Leaf requires only. (Gate 14.5 honesty note: the real UnitController module
-- does not exist in this file — this file is the TacticalPatrol demo, so
-- UnitControl stays nil until 14.5 is actually implemented.)
local Query    = require("framework.query")
local EventBus = require("framework.event_bus")
local UnitControl = nil

local TacticalPatrol = {}

local PATROL_OFFSET = 6
local ENEMY_RADIUS  = 35
local DECIDE_EVERY  = 10

local MCV_TYPES = {
    AMCV = true,
    SMCV = true,
    YMCV = true,
}

local controller = nil
local anchor = nil

local spawned = false
local warnedNoUnit = false
local eventsWired = false

local lastTargetId = nil
local lastScanFrame = -1


local function msg(text)
    if Engine and Engine.PrintMessage then
        Engine.PrintMessage(text)
    end
end


local function isOwnedBy(player, unit)
    if not unit or not unit.IsAlive then
        return false
    end

    local owner = unit:GetOwner()

    return owner ~= nil
        and (owner == player or owner:IsAlliedWith(player))
end


local function isMcv(unit)
    if not unit or not unit.GetTypeName then
        return false
    end

    local typeName = unit:GetTypeName()

    return typeName ~= nil and MCV_TYPES[typeName] == true
end


local function firstPlayerUnit(player)
    local ok, units = pcall(World.GetUnits)

    if not ok or not units then
        return nil
    end

    for _, unit in ipairs(units) do
        if unit:IsAlive()
            and not isMcv(unit)
            and isOwnedBy(player, unit)
        then
            return unit
        end
    end

    return nil
end


local function playerBase(player)
    local ok, buildings = pcall(World.GetBuildings)

    if not ok or not buildings then
        return nil
    end

    for _, building in ipairs(buildings) do
        if building:IsAlive() and isOwnedBy(player, building) then
            local pos = building:GetPosition()

            if pos then
                return {
                    x = math.floor(pos.x),
                    y = math.floor(pos.y),
                }
            end
        end
    end

    return nil
end


local function makePatrolPoints(a)
    return {
        {
            x = a.x - PATROL_OFFSET,
            y = a.y,
        },
        {
            x = a.x + PATROL_OFFSET,
            y = a.y,
        },
    }
end


local function onTaskDone(task, status, mode)
    if mode ~= "attack" then
        return
    end

    msg(string.format(
        "[TACTICAL] combat task finished: status=%s",
        tostring(status)
    ))

    lastTargetId = nil

    if not controller or not controller:is_alive() then
        msg("[TACTICAL] controller no longer valid")
        return
    end

    if not anchor then
        msg("[TACTICAL] no patrol anchor available")
        return
    end

    msg("[TACTICAL] resuming patrol")

    controller:patrol(makePatrolPoints(anchor))
end


local function ensureController(unit)
    if controller
        and controller:is_alive()
        and controller.id == unit:GetId()
    then
        return controller
    end

    controller = UnitControl.new(unit, {
        onTaskDone = onTaskDone,
    })

    return controller
end


local function scanForEnemy(unit, frame)
    local enemy = Query.nearest_enemy(unit, ENEMY_RADIUS)

    lastScanFrame = frame

    if not enemy then
        return nil
    end

    if not enemy:IsAlive() then
        return nil
    end

    local id = enemy:GetId()

    if id ~= lastTargetId then
        msg(string.format(
            "[TACTICAL] enemy detected: %s #%d",
            tostring(enemy:GetTypeName()),
            id
        ))

        lastTargetId = id
    end

    return enemy
end


local function decide(player, frame)
    if not controller then
        return
    end

    local unit = controller:unit()

    if not unit then
        msg("[TACTICAL] controlled unit no longer exists")
        controller = nil
        lastTargetId = nil
        return
    end

    local enemy = scanForEnemy(unit, frame)

    local hasTask = controller:has_task()
    local mode = controller:get_mode()

    -- If already attacking, let the current Attack task finish.
    if hasTask and mode == "attack" then
        if enemy then
            local targetId = enemy:GetId()

            if targetId ~= lastTargetId then
                msg(string.format(
                    "[TACTICAL] new enemy detected while attacking: #%d",
                    targetId
                ))
            end
        end

        return
    end

    -- Enemy found while patrolling/idle.
    if enemy then
        msg(string.format(
            "[TACTICAL] engaging %s #%d",
            tostring(enemy:GetTypeName()),
            enemy:GetId()
        ))

        controller:attack(enemy, {
            timeout = 900,
        })

        return
    end

    -- Nothing to attack and no task is running.
    if not hasTask and anchor then
        msg("[TACTICAL] controller idle, starting patrol")
        controller:patrol(makePatrolPoints(anchor))
    end
end


function TacticalPatrol.Update(frame)
    -- Lazy: safe here (never during init's own load), keeps the top level free
    -- of the init cycle.
    local Framework = require("framework.init")
    Framework.update(frame)

    -- The loader only calls Update(), so framework event wiring happens here.
    if not eventsWired then
        eventsWired = true

        Framework.enableUnitEvents(30)

        EventBus.on("unit_destroyed", function(id, snapshot)
            msg(string.format(
                "[TACTICAL] unit #%d (%s) destroyed",
                id,
                snapshot and snapshot.typeName or "?"
            ))
        end)
    end

    local player = House.GetPlayer()

    if not player then
        return
    end

    -- Find the unit once.
    if not controller then
        local unit = firstPlayerUnit(player)

        if not unit then
            if not spawned then
                spawned = true

                local base = playerBase(player) or {
                    x = 26,
                    y = 26,
                }

                local result = player:SpawnUnit(
                    "LTNK",
                    1,
                    base.x + 2,
                    base.y + 2,
                    0,
                    false,
                    "guard"
                )

                msg(string.format(
                    "[TACTICAL] spawned combat unit (LTNK), ret=%d",
                    result
                ))

            elseif not warnedNoUnit then
                warnedNoUnit = true
                msg("[TACTICAL] no player combat unit found, waiting...")
            end

            return
        end

        warnedNoUnit = false

        anchor = playerBase(player)

        if not anchor then
            local pos = unit:GetPosition()

            if pos then
                anchor = {
                    x = math.floor(pos.x),
                    y = math.floor(pos.y),
                }
            else
                anchor = {
                    x = 26,
                    y = 26,
                }
            end
        end

        ensureController(unit)

        msg(string.format(
            "[TACTICAL] controlling %s #%d",
            tostring(unit:GetTypeName()),
            unit:GetId()
        ))

        msg(string.format(
            "[TACTICAL] patrol anchor: (%d,%d)",
            anchor.x,
            anchor.y
        ))

        controller:patrol(makePatrolPoints(anchor))

        msg("[TACTICAL] patrol started")
    end

    -- Execute the current Task every logical frame.
    if controller then
        controller:update(frame)
    end

    -- Tactical decisions are throttled.
    if frame % DECIDE_EVERY ~= 0 then
        return
    end

    decide(player, frame)
end


return TacticalPatrol