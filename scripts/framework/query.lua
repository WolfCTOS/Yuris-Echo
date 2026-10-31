-- LuaAPI Gameplay Framework — Query helpers.
--
-- M14.3: composable, Lua-side wrappers around the native spatial/query API
-- (World.GetUnitsInRadius / World.GetUnits / World.GetAllUnits).
--
-- The native API answers "what objects exist near a point / in the world".
-- Query answers "which of those are enemies / allies / of a house / of a
-- type". It keeps the common gameplay predicates (enemy detection, neutral
-- filtering, mobile-vs-building, nearest-distance) in one place so a modder
-- writes intent rather than a filtering loop.
--
--     local enemies = Query.enemies_in_range(unit, 300)
--     local target   = Query.nearest_enemy(unit, 500)
--     if target then unit:Attack(target) end
--
-- Every function is engine-safe: it re-validates each object with IsAlive()
-- and iterates only the native arrays. Queries never store engine references,
-- so nothing goes stale across frames.
--
-- PERFORMANCE NOTE: radius scans (GetUnitsInRadius) traverse the techno array.
-- Whole-map scans (units_by_house / units_by_type / units_matching) traverse
-- the entire map — use those sparingly (setup / throttled decision passes),
-- not on a per-frame hot path. Radius scans should be throttled by the caller
-- (e.g. every 10–20 frames) to avoid repeated full-array walks.

local util = require("framework.util")

local Query = {}

-- Position of a unit, or a pre-formed { x, y, z } table, or x,y as the first
-- two args. Returns x, y.
local function pointOf(reference)
    if type(reference) == "table" and reference.GetPosition then
        local pos = reference:GetPosition()
        return pos and pos.x, pos and pos.y
    end
    if reference and reference.x ~= nil then
        return reference.x, reference.y
    end
    return nil, nil
end

-- The recognising house for a query: an explicit opts.reference (house or a
-- unit userdata) wins; otherwise derive it from the reference argument.
local function resolveHouse(reference, opts)
    if opts and opts.reference then
        local ref = opts.reference
        if type(ref) == "table" and ref.GetOwner then
            return ref:GetOwner()
        end
        return ref
    end
    if type(reference) == "table" and reference.GetOwner then
        return reference:GetOwner()
    end
    if reference and reference.GetName then
        return reference
    end
    return nil
end

-- Scan the native radius query around (x, y) and return an array of alive
-- objects, optionally including buildings (default: mobile only).
local function scanRadius(x, y, radius, opts)
    local includeBuildings = opts and opts.includeBuildings
    local out = {}
    local ok, found = pcall(World.GetUnitsInRadius, x, y, radius)
    if not ok or not found then
        return out
    end
    for _, u in ipairs(found) do
        if util.is_alive(u) and (includeBuildings or util.is_mobile(u)) then
            out[#out + 1] = u
        end
    end
    return out
end

-- Full world scan (mobile + optionally buildings). Used by house/type/predicate
-- queries. Expense is proportional to the number of technos on the map.
local function scanWorld(opts)
    local includeBuildings = opts and opts.includeBuildings
    local out = {}
    local ok, found = pcall(World.GetAllUnits)
    if not ok or not found then
        return out
    end
    for _, u in ipairs(found) do
        if util.is_alive(u) and (includeBuildings or util.is_mobile(u)) then
            out[#out + 1] = u
        end
    end
    return out
end

-- All mobile objects (or all kinds when opts.includeBuildings) within `radius`
-- cells of the given unit/point.
function Query.all_in_range(reference, radius, opts)
    opts = opts or {}
    local x, y = pointOf(reference)
    if not x then
        return {}
    end
    return scanRadius(x, y, radius or 15, opts)
end

-- Enemies of the reference house within `radius` cells.
function Query.enemies_in_range(reference, radius, opts)
    opts = opts or {}
    local x, y = pointOf(reference)
    if not x then
        return {}
    end
    local eff = resolveHouse(reference, opts)
    local out = {}
    for _, u in ipairs(scanRadius(x, y, radius, opts)) do
        if eff and util.is_enemy(eff, u) then
            out[#out + 1] = u
        end
    end
    return out
end

-- Allies (including the house itself) of the reference house within `radius`.
function Query.friendlies_in_range(reference, radius, opts)
    opts = opts or {}
    local x, y = pointOf(reference)
    if not x then
        return {}
    end
    local eff = resolveHouse(reference, opts)
    -- A friendly query should not return the reference unit itself.
    local refId = (type(reference) == "table" and reference.GetId) and reference:GetId() or nil
    local out = {}
    for _, u in ipairs(scanRadius(x, y, radius, opts)) do
        if refId ~= nil and u:GetId() == refId then
            -- skip self
        elseif eff and util.is_ally(eff, u) then
            out[#out + 1] = u
        end
    end
    return out
end

-- The nearest object in `candidates` to (x, y). Returns the object or nil.
local function nearest(candidates, x, y)
    local best, bestDist = nil, math.huge
    for _, u in ipairs(candidates) do
        local pos = u:GetPosition()
        if pos then
            local dx, dy = pos.x - x, pos.y - y
            local d = dx * dx + dy * dy
            if d < bestDist then
                bestDist = d
                best = u
            end
        end
    end
    return best
end

-- Nearest enemy of the reference house within `radius` cells. Returns a unit
-- or nil — the most common "who should I attack" query.
function Query.nearest_enemy(reference, radius, opts)
    local x, y = pointOf(reference)
    if not x then
        return nil
    end
    return nearest(Query.enemies_in_range(reference, radius, opts), x, y)
end

-- Nearest ally of the reference house within `radius` cells. Returns a unit
-- or nil.
function Query.nearest_friendly(reference, radius, opts)
    local x, y = pointOf(reference)
    if not x then
        return nil
    end
    return nearest(Query.friendlies_in_range(reference, radius, opts), x, y)
end

-- All mobile objects owned by a house (default: exact ownership). Pass
-- opts.allied = true to include allied houses. Whole-map scan — call sparingly.
function Query.units_by_house(house, opts)
    opts = opts or {}
    if not house or not house.GetName then
        return {}
    end
    local out = {}
    for _, u in ipairs(scanWorld(opts)) do
        local owner = u:GetOwner()
        if owner and util.is_alive(u) then
            if opts.allied then
                if util.is_ally(house, u) then
                    out[#out + 1] = u
                end
            elseif owner == house then
                out[#out + 1] = u
            end
        end
    end
    return out
end

-- All mobile objects whose GetTypeName() is in `typeSet` (a set table of
-- key=true). Whole-map scan — call sparingly.
function Query.units_by_type(typeSet, opts)
    opts = opts or {}
    if not typeSet then
        return {}
    end
    local out = {}
    for _, u in ipairs(scanWorld(opts)) do
        local t = u:GetTypeName()
        if t and typeSet[t] then
            out[#out + 1] = u
        end
    end
    return out
end

-- All mobile objects for which `predicate(u)` returns truthy. Whole-map scan —
-- call sparingly. The generic escape hatch for custom filters.
function Query.units_matching(predicate, opts)
    opts = opts or {}
    if type(predicate) ~= "function" then
        return {}
    end
    local out = {}
    for _, u in ipairs(scanWorld(opts)) do
        local ok, keep = pcall(predicate, u)
        if ok and keep then
            out[#out + 1] = u
        end
    end
    return out
end

-- Convenience: is `unit` a legitimate enemy of `reference` (unit or house)?
-- The same predicate the range queries use, exposed for direct use.
function Query.is_enemy(reference, unit)
    return util.is_enemy(resolveHouse(reference, nil), unit)
end

function Query.is_ally(reference, unit)
    return util.is_ally(resolveHouse(reference, nil), unit)
end

return Query
