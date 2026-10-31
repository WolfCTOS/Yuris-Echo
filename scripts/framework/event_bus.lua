-- LuaAPI Gameplay Framework — EventBus.
--
-- M14.1: a small, callback-safe event abstraction for gameplay scripts.
--
-- The native LuaAPI engine exposes a handful of engine-level callbacks
-- (OnTick / OnScenarioStart / OnUnitDestroyed / OnPreDamage), but those are
-- global, last-write-wins, and not guaranteed to be wired up in every build.
-- EventBus is a Lua-side subscription layer that any script can own and drive.
--
-- Design goals:
--   * callback registration + removal
--   * multiple listeners per event
--   * deterministic, insertion-ordered dispatch
--   * error isolation between handlers (a failing handler never kills others)
--   * safe mutation during dispatch (handlers may add/remove listeners)
--   * no engine-object retention: emits carry whatever values the emitter
--     provided; the bus itself never stores a Techno/house reference, so it
--     cannot go stale when a session resets.
--
-- Session lifecycle: the entire Lua VM is recreated on session reset, so the
-- listener tables below are naturally cleared. EventBus.reset() is provided
-- for explicit hygiene (and is called by the framework integration).
--
-- Using it:
--     local EventBus = require("framework.event_bus")
--     local sub = EventBus.on("unit_created", function(unit) ... end)
--     EventBus.off("unit_created", sub)         -- by subscription id
--     EventBus.off("unit_created", handler)     -- by the original function
--     EventBus.emit("unit_created", someUnit)

local util = require("framework.util")

local EventBus = {}

local MAX_LISTENERS_PER_EVENT = 128

-- listeners[event] = array of { id, fn, removed }
local listeners = {}
local nextListenerId = 0

-- Reused dispatch buffer: holds references to the listener entries for the
-- event being dispatched. Reused (length-adjusted, never reallocated) so
-- per-frame emits don't churn the allocator.
local dispatchBuffer = {}

local function isFunction(v)
    return type(v) == "function"
end

function EventBus.on(event, handler)
    if type(event) ~= "string" or not isFunction(handler) then
        return nil
    end

    nextListenerId = nextListenerId + 1
    local id = nextListenerId

    local list = listeners[event]
    if not list then
        list = {}
        listeners[event] = list
    end

    if #list >= MAX_LISTENERS_PER_EVENT then
        util.log_error("EventBus: ignoring listener for '%s' (cap %d reached)", event, MAX_LISTENERS_PER_EVENT)
        return nil
    end

    list[#list + 1] = { id = id, fn = handler }
    return id
end

-- Alias kept for readability: subscribers often express intent as "subscribe".
EventBus.subscribe = EventBus.on

-- Remove a listener for `event`, either by the subscription id returned by
-- on(), or by the exact function that was registered. Returns how many
-- listeners were removed.
function EventBus.off(event, handler)
    local list = listeners[event]
    if not list then
        return 0
    end

    local removed = 0
    -- Mark removed so an in-flight dispatch skips them, then compact in place
    -- preserving subscription order for the survivors.
    for i = #list, 1, -1 do
        local entry = list[i]
        if entry.id == handler or entry.fn == handler then
            entry.removed = true
            table.remove(list, i)
            removed = removed + 1
        end
    end

    if #list == 0 then
        listeners[event] = nil
    end

    return removed
end

-- Fire `event`, passing the given arguments to every listener in subscription
-- order. Each handler is wrapped in pcall so an error is isolated and logged;
-- a failing handler never prevents the remaining handlers from running.
-- Handlers registered or removed during dispatch take effect on the next emit.
function EventBus.emit(event, ...)
    local list = listeners[event]
    if not list or #list == 0 then
        return 0
    end

    local n = #list
    for i = 1, n do
        dispatchBuffer[i] = list[i]
    end
    for i = n + 1, #dispatchBuffer do
        dispatchBuffer[i] = nil
    end

    local fired = 0
    for i = 1, n do
        local entry = dispatchBuffer[i]
        if entry and not entry.removed then
            fired = fired + 1
            local ok, err = pcall(entry.fn, ...)
            if not ok then
                util.log_error("EventBus: handler for '%s' error: %s", event, tostring(err))
            end
        end
    end
    return fired
end

-- Number of currently subscribed listeners for an event.
function EventBus.listenerCount(event)
    local list = listeners[event]
    return list and #list or 0
end

-- Remove every listener for a single event.
function EventBus.clearEvent(event)
    listeners[event] = nil
end

-- Remove every listener across all events. Called on session reset.
function EventBus.reset()
    listeners = {}
    dispatchBuffer = {}
end

-- Diagnostic: the set of registered event names.
function EventBus.events()
    local out = {}
    for name in pairs(listeners) do
        out[#out + 1] = name
    end
    return out
end

return EventBus
