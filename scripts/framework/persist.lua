-- LuaAPI Gameplay Framework — Persist (cross-match lightweight memory).
--
-- M15: the "remaining 5%" of the agent-illusion stack that looked like it needed
-- new C++ (io/os file I/O). It does NOT: `luaL_openlibs` enables the standard
-- `io`/`os` libraries, and the script dir is resolvable from Lua via
-- `debug.getinfo`, exactly like `scripts/init.lua` does. So this whole module is
-- pure Lua with zero bindings.
--
-- Purpose: remember a few scalar facts about the player across matches (player
-- name, "they rushed at minute X", "they favor armor/big-army", win counts), so
-- the opponent on the next match already behaves a little differently. This is
-- the strongest "not a scripted AI" tell that survives restarts.
--
-- Storage: a flat text file in the SAME directory as this module (the module
-- dir), so CnCNet / Syringe changing the process CWD does not break it.
-- SAFETY: this file is read/written OUTSIDE the simulation frame, never used for
-- in-match determinism, so it cannot cause OOS. Keep writes throttled (see usage)
-- and keep values as scalars (string/number/boolean).
--
-- Using it:
--     local persist = require("framework.persist")
--     local memory = persist.load()                 -- table (empty on first run)
--     memory.rushed = true
--     persist.remember("player_rushed", true)       -- cache + lazy save
--     if persist.recall("player_rushed") then ... end
--     persist.flush()                               -- write once, not per frame

local M = {}

-- Directory of this very file (scripts/framework/), anchored to the module dir.
-- This is stable across process-CWD changes.
local function thisDir()
    local src = debug.getinfo(1, "S").source
    if src and src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    return src:match("^(.*)/[^/]*$") or "."
end

local FILE = thisDir() .. "/ai_memory.dat"

-- In-memory cache: we only touch the disk on flush(), not every frame.
local cache = nil

---------------------------------------------------------------
-- Escaping (key/value must never contain a literal tab/newline)
---------------------------------------------------------------

local function esc(v)
    v = tostring(v)
    return v:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "\\r")
end

local function unesc(v)
    if not v then return nil end
    v = v:gsub("\\\\", "\1"):gsub("\\t", "\t"):gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\1", "\\")
    return v
end

---------------------------------------------------------------
-- Load / Save / Flush
---------------------------------------------------------------

function M.load()
    if cache then return cache end

    local t = {}
    local f = io.open(FILE, "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^([^\t]*)\t(.*)$")
            if k and v ~= nil then
                t[unesc(k)] = unesc(v)
            end
        end
        f:close()
    end
    cache = t
    return t
end

function M.flush()
    local t = cache
    if not t then return end

    local ok, lines = pcall(function()
        local out = {}
        for k, v in pairs(t) do
            out[#out + 1] = esc(k) .. "\t" .. esc(v)
        end
        return table.concat(out, "\n")
    end)
    if not ok then return end

    pcall(function()
        local f = io.open(FILE, "w")
        if not f then return end
        f:write(lines)
        if #lines > 0 then f:write("\n") end
        f:close()
    end)
end

---------------------------------------------------------------
-- Convenience accessors (lazy-load, cache, mark dirty)
---------------------------------------------------------------

function M.recall(key)
    local t = M.load()
    return t[key]
end

function M.remember(key, value)
    local t = M.load()
    t[key] = value
    return value
end

-- Forget a key and rewrite the file.
function M.forget(key)
    local t = M.load()
    t[key] = nil
    M.flush()
end

function M.clear()
    cache = {}
    M.flush()
end

function M.filePath()
    return FILE
end

return M
