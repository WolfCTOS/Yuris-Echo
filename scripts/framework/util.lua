-- LuaAPI Gameplay Framework — shared helpers.
--
-- These are small, dependency-free utilities used across the framework modules
-- (event_bus, timer, query, task, unit_controller). They wrap the native
-- LuaAPI primitives with safe, reusable predicates and logging so gameplay
-- scripts don't repeat the same engine-guarding boilerplate.
--
-- IMPORTANT SAFETY RULES (mirror the C++ side):
--   * Never assume a TechnoClass* stays valid. Always re-validate with
--     unit:IsAlive() before use, and prefer re-resolving a unit by its id from
--     a fresh World scan rather than keeping a long-lived userdata.
--   * Never treat a neutral/civilian house as an enemy.
--   * Framework logs go to LuaAPI.log via the redirected print(), not the HUD,
--     so per-frame framework diagnostics do not spam the message list.

local M = {}

-- Engine-global categories that are never legitimate combat targets.
M.NEUTRAL_HOUSES = {
    Neutral  = true,
    Civilian = true,
    Special  = true,
}

-- Civilian vehicles that are not meaningful combat targets regardless of owner.
M.CIVIL_TYPES = {
    CAR   = true,
    PCV   = true,
    BUS   = true,
    TRUCK = true,
}

-- Mobile kind values returned by unit:GetKind(). Buildings are excluded from
-- the default "mobile" set so generic queries target units/infantry/aircraft.
M.MOBILE_KINDS = {
    unit     = true,
    infantry = true,
    aircraft = true,
}

-- Safe invocation of an arbitrary callback, so a failing handler or task step
-- never unwinds the whole framework tick. Returns true and whatever the fn
-- produced on success, or false + the error message on failure.
function M.safe_call(fn, ...)
    if type(fn) ~= "function" then
        return false, "callback is not a function"
    end
    return pcall(fn, ...)
end

-- Framework diagnostic logging. Routes to print(), which LuaAPI redirects to
-- LuaAPI.log — so framework diagnostics never spam the in-game HUD.
-- Supports printf-style formatting when extra args are supplied.
function M.log(tag, fmt, ...)
    local body
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, tostring(fmt), ...)
        body = ok and formatted or (tostring(fmt) .. " " .. table.concat({...}, " "))
    else
        body = tostring(fmt)
    end
    print("[" .. tag .. "] " .. body)
end

function M.log_error(fmt, ...)
    M.log("FRAMEWORK-ERR", fmt, ...)
end

function M.log_info(fmt, ...)
    M.log("FRAMEWORK", fmt, ...)
end

-- Return a human-safe boolean indicating whether an object is alive.
-- Guards against non-techno / nil first so it is safe to call on anything.
function M.is_alive(unit)
    if not unit then
        return false
    end
    local ok, alive = M.safe_call(unit.IsAlive, unit)
    return ok and alive == true
end

-- Kind of the object, or nil when unavailable.
function M.kind_of(unit)
    if not unit then
        return nil
    end
    local ok, kind = M.safe_call(unit.GetKind, unit)
    return ok and kind or nil
end

-- Mobile unit / infantry / aircraft? Buildings and nil are not.
function M.is_mobile(unit)
    local kind = M.kind_of(unit)
    return kind ~= nil and M.MOBILE_KINDS[kind] == true
end

-- Is the unit in an idle mission (Guard/Stop/Sleep, per the native binding)?
function M.is_idle(unit)
    if not unit then
        return false
    end
    local ok, idle = M.safe_call(unit.IsIdle, unit)
    return ok and idle == true
end

-- Is this house a neutral / civilian / special room? Skips game nulls.
function M.is_neutral_house(house)
    if not house then
        return false
    end
    local ok, name = M.safe_call(house.GetName, house)
    if not ok then
        return true
    end
    return M.NEUTRAL_HOUSES[name] == true
end

-- Is `unit` a legitimate enemy of `refHouse`?
--   refHouse  — the recognising house (usually the player or a unit's owner)
--   unit      — the candidate object
-- Neutrals, civilians, and civilian vehicles are never enemies.
function M.is_enemy(refHouse, unit)
    if not M.is_alive(unit) or not refHouse then
        return false
    end
    local owner = unit:GetOwner()
    if not owner then
        return false
    end
    if M.is_neutral_house(owner) then
        return false
    end
    if M.CIVIL_TYPES[unit:GetTypeName()] then
        return false
    end
    if owner == refHouse then
        return false
    end
    local ok, allied = M.safe_call(owner.IsAlliedWith, owner, refHouse)
    return ok and allied == false
end

-- Is `unit` an ally of `refHouse` (including the house itself)?
function M.is_ally(refHouse, unit)
    if not M.is_alive(unit) or not refHouse then
        return false
    end
    local owner = unit:GetOwner()
    if not owner then
        return false
    end
    if owner == refHouse then
        return true
    end
    local ok, allied = M.safe_call(owner.IsAlliedWith, owner, refHouse)
    return ok and allied == true
end

-- Euclidean distance in map cells between two x/y cell positions.
function M.distance(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- Distance from a unit to an x/y cell position. Nil when the unit has no pos.
function M.distance_to(unit, bx, by)
    local pos = unit:GetPosition()
    if not pos then
        return nil
    end
    return M.distance(pos.x, pos.y, bx, by)
end

-- Does the unit own / stand within `cells` cells of the given cell point?
-- Avoids allocating and keeps integer math in floating point to dodge 32-bit
-- overflows when coordinates are large.
function M.near(unit, bx, by, cells)
    local pos = unit:GetPosition()
    if not pos then
        return false
    end
    local dx = pos.x - bx
    local dy = pos.y - by
    return (dx * dx + dy * dy) <= (cells * cells)
end

return M
