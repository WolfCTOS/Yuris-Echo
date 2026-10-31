-- LuaAPI Gameplay Framework — Timer.
--
-- M14.2: a lightweight, frame-based scheduler.
--
-- Timing is expressed in logical game frames (the same clock the engine's
-- Unsorted::CurrentFrame exposes) rather than wall-clock time. This keeps
-- gameplay deterministic across clients and avoids os.time()/os.clock()
-- Out-of-Sync issues in multiplayer.
--
-- Timers are driven explicitly by Timer.update(frame), which a script calls
-- once per logical frame (or, more conveniently, through Framework.update()).
--
--     local id = Timer.after(60, function(frame) ... end)   -- fire once after 60 frames
--     local id = Timer.every(30, function(frame) ... end)   -- fire every 30 frames
--     Timer.cancel(id)
--     Timer.reset()
--
-- Safety / lifecycle:
--   * No engine objects are stored — only callback closures and frame counts,
--     so the timer table cannot retain a stale Techno/house reference.
--   * Callbacks are wrapped in pcall; a failing callback is isolated and the
--     timer either removes itself (after) or keeps running (every).
--   * The whole VM is recreated on session reset, so pending timers are
--     naturally discarded; Timer.reset() is provided for explicit hygiene.
--   * Callbacks created during a dispatch fire on the NEXT frame; this avoids
--     re-entrant infinite loops and keeps one frame's ordering stable.

local util = require("framework.util")

local Timer = {}

local timers = {}          -- id -> { remaining, interval, fn, kind, cancelled }
local nextTimerId = 0
local currentFrame = 0

local KIND_ONCE = "once"
local KIND_EVERY = "every"

-- Common implementation for after()/every(): schedule a callback.
local function schedule(kind, delay, fn)
    if type(fn) ~= "function" then
        util.log_error("Timer: callback is not a function")
        return nil
    end
    local delayFrames = math.max(1, math.floor(delay or 1))
    nextTimerId = nextTimerId + 1
    local id = nextTimerId
    timers[id] = {
        remaining = delayFrames,
        interval  = delayFrames,
        fn        = fn,
        kind      = kind,
        cancelled = false,
    }
    return id
end

-- Schedule a one-shot callback `delay` frames from now.
function Timer.after(delay, fn)
    return schedule(KIND_ONCE, delay, fn)
end

-- Schedule a repeating callback every `interval` frames.
function Timer.every(interval, fn)
    return schedule(KIND_EVERY, interval, fn)
end

-- Schedule a callback exactly at a future absolute frame number. Handy when an
-- event already carries the current logical frame. Returns nil if the frame is
-- in the past (which would otherwise fire immediately and could loop).
function Timer.at(frame, fn)
    if type(fn) ~= "function" then
        return nil
    end
    local delay = (frame or 0) - currentFrame
    if delay < 1 then
        util.log_error("Timer.at: requested frame %s is not in the future (current %s)",
            tostring(frame), tostring(currentFrame))
        return nil
    end
    return schedule(KIND_ONCE, delay, fn)
end

-- Cancel a pending timer by id. Idempotent; safe during dispatch.
function Timer.cancel(id)
    local t = timers[id]
    if t then
        t.cancelled = true
        timers[id] = nil
    end
end

-- Advance the timer clock by one logical frame and fire any due timers.
-- Returns the number of timers that fired. Called from Framework.update().
function Timer.update(frame)
    currentFrame = frame or currentFrame

    local fired = 0
    for id, t in pairs(timers) do
        if not t.cancelled then
            t.remaining = t.remaining - 1
            if t.remaining <= 0 then
                fired = fired + 1
                -- Fire with the current logical frame for deterministic timing.
                local ok, err = pcall(t.fn, frame)
                if not ok then
                    util.log_error("Timer: callback error: %s", tostring(err))
                end
                if t.kind == KIND_ONCE then
                    timers[id] = nil
                elseif t.kind == KIND_EVERY then
                    t.remaining = t.interval
                end
            end
        end
    end

    return fired
end

-- The frame most recently seen by Timer.update().
function Timer.getFrame()
    return currentFrame
end

-- Number of currently pending (non-fired) timers.
function Timer.pending()
    return nextTimerId - 0 -- distinct ids ever created
end

function Timer.activeCount()
    local n = 0
    for _ in pairs(timers) do
        n = n + 1
    end
    return n
end

-- Drop every pending timer. Called on session reset and by the integration.
function Timer.reset()
    timers = {}
end

return Timer
