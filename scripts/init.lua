print("[LuaAPI] Universal ModLoader Online!")

-- Read enabled mod IDs from scripts/active_mods.txt (one per line, '#' comments).
-- Uses debug.getinfo to anchor the path to this script's directory,
-- avoiding CWD issues when CnCNet/Syringe sets CWD to the client directory.
-- Layout: <game>\mods\<id>\main.lua is the current location; the older
-- <game>\scripts\mods\<id>\main.lua is still accepted. The engine loads this
-- file as <game>\scripts\init.lua and puts <game>\scripts\?.lua on package.path;
-- the entries added below let require("mods.<id>.main") work in both layouts.

local function toSlash(p) return (p:gsub("\\", "/")) end

local SCRIPT_DIR = toSlash((debug.getinfo(1, "S").source:match("@?(.*[/\\])") or ""))
local GAME_ROOT = SCRIPT_DIR:match("^(.*)scripts/$") or SCRIPT_DIR

local MOD_DIRS = {}
local function addModDir(dir)
    if dir == "" then return end
    for _, d in ipairs(MOD_DIRS) do
        if d == dir then return end
    end
    MOD_DIRS[#MOD_DIRS + 1] = dir
end
addModDir(GAME_ROOT .. "mods")
addModDir(SCRIPT_DIR .. "mods")

local function addPackagePath(entry)
    if entry == "" then return end
    if not package.path:find(entry, 1, true) then
        package.path = entry .. ";" .. package.path
    end
end

-- The newest layout must win, so prepend in reverse order: the loop ends with
-- GAME_ROOT's entry at the front of package.path.
for i = #MOD_DIRS, 1, -1 do
    local root = MOD_DIRS[i]
    local parent = root:match("^(.*)mods/?$")
    if parent then addPackagePath(parent .. "?.lua") end   -- mods.<id>.<module>
    addPackagePath(root .. "/?.lua")                      -- sibling modules
end

local function findModMain(id)
    for _, root in ipairs(MOD_DIRS) do
        local path = root .. "/" .. id .. "/main.lua"
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
end

local function loadActiveModList()
    local active = {}
    local candidates = {
        GAME_ROOT .. "mods/active_mods.txt",
        SCRIPT_DIR .. "active_mods.txt",
        "scripts/active_mods.txt",
        "active_mods.txt",
    }
    local f
    for _, path in ipairs(candidates) do
        f = io.open(path, "r")
        if f then break end
    end

    if f then
        for line in f:lines() do
            local clean = line:match("^%s*(.-)%s*$")
            if clean and clean ~= "" and not clean:match("^#") then
                table.insert(active, clean)
            end
        end
        f:close()
    else
        -- Fallback defaults if file doesn't exist
        -- NOTE 2026-09-21: delayed_explosion no longer exists in the tree;
        -- fall back to mods present on disk.
        active = { "target_reselect", "smart_ai" }
    end
    return active
end

local ACTIVE_MODS = loadActiveModList()
local loadedMods = {}

-- Per-mod timing state: total_ms, max_ms, call_count indexed by mod name.
local modTiming = {}
local lastStatsReport = os.clock()

-- Per-mod last reported Update error (E1): dedup key so a permanently
-- broken mod logs once per distinct error instead of every frame.
local modLastError = {}

-- [[ДЕТЕРМИНИСТИЧНОЕ СИДИРОВАНИЕ RNG]]
-- Критически важно для CnCNet мультиплеера: использование os.clock() или os.time()
-- вызывает Out-of-Sync (OOS) рассинхронизацию между клиентами.
-- 
-- Базовый сид фиксирован и синхронизирован на всех клиентах.
-- Если модам требуется пересидирование во время игры, должно использоваться
-- только следящее за текущим кадром: math.randomseed(current_frame + 12345)
math.randomseed(12345)

-- [[Событийные шины]]
-- Моды могут подписаться на эти события в main.lua:
--   function OnScenarioStart()  -- вызывается 1 раз при логическом кадре 1
--   function OnUnitDestroyed(victim, killer) -- НЕ ВЫЗЫВАЕТСЯ в текущей сборке
--      (контракт без диспетча, см. API.md) — для детекта смертей используйте
--      ID-diff сканов (паттерн Command Authority).
-- Глобальные колбэки — last-write-wins: их должен определять только один мод.
--
-- Пустые значения ПО УМОЛЧАНИЮ определены ДО загрузки модов (M1 fix):
-- мод, объявляющий свой глобальный обработчик на уровне файла, перезаписывает
-- значение по умолчанию своим. Раньше было наоборот (значения по умолчанию
-- после require затирали обработчики модов, и C++ вызывал пустую функцию).

function OnScenarioStart()
    -- Базовый пустой обработчик. Переопределите в main.lua своего мода.
end

function OnUnitDestroyed(victim, killer)
    -- Базовый пустой обработчик. Переопределите в main.lua своего мода.
    -- victim = TechnoClass pointer (или nil), killer = TechnoClass pointer (или nil)
end

for _, modName in ipairs(ACTIVE_MODS) do
    -- Resolve the folder in either layout, then load it. require() is tried
    -- first (it keeps package.loaded semantics); loadfile() covers folder
    -- names that are not valid Lua module names.
    local mainPath = findModMain(modName)
    local ok, mod
    if mainPath then
        ok, mod = pcall(require, "mods." .. modName .. ".main")
        if not ok or type(mod) ~= "table" then
            local chunk, loadErr = loadfile(mainPath)
            if chunk then
                ok, mod = pcall(chunk)
            else
                ok, mod = false, loadErr
            end
        end
    else
        ok, mod = false, "main.lua not found in mods/ or scripts/mods/"
    end
    if ok and mod then
        -- Keep the id next to the module: a mod that fails to load must
        -- not shift the ids of the ones after it (timing/error labels
        -- used to be attributed to the wrong mod).
        table.insert(loadedMods, { name = modName, mod = mod })
        modTiming[modName] = modTiming[modName] or { total_ms = 0.0, max_ms = 0.0, calls = 0 }
        print(string.format("[LuaAPI] [+] Mod active: '%s'", modName))
    else
        print(string.format("[LuaAPI] [-] Failed to load mod: '%s' (%s)", modName, tostring(mod)))
    end
end

local welcomed = false

function OnTick(frame)
    if not welcomed then
        local player = House.GetPlayer()
        if player then
            Engine.PrintMessage(string.format("Commander: %s | Active Mods: %d loaded",
                player:GetName(), #loadedMods))
            welcomed = true
        end
    end

    -- Report per-mod stats every 5 seconds
    local now = os.clock()
    if now - lastStatsReport >= 5.0 then
        lastStatsReport = now
        for name, t in pairs(modTiming) do
            local avg_ms = t.calls > 0 and (t.total_ms / t.calls) or 0.0
            print(string.format("[LuaAPI] Mod timing [%s]: Avg %.2f ms | Max %.2f ms | Calls %d",
                name, avg_ms, t.max_ms, t.calls))
        end
        -- Reset counters after reporting
        for name in pairs(modTiming) do
            modTiming[name] = { total_ms = 0.0, max_ms = 0.0, calls = 0 }
        end
    end

    -- Wrap each mod.Update in wall-clock timing. Failures are ISOLATED
    -- per mod and REPORTED (E1): one broken mod neither stops the loader
    -- nor fails silently. Dedup by message (see modLastError) so the log
    -- gets one line per distinct error, not one per frame.
    for _, entry in ipairs(loadedMods) do
        local mod, modName = entry.mod, entry.name
        if mod and type(mod.Update) == "function" then
            local start = os.clock()
            local ok, err = pcall(mod.Update, frame)
            if not ok then
                local msg = tostring(err)
                if modLastError[modName] ~= msg then
                    modLastError[modName] = msg
                    print(string.format("[LuaAPI] Mod '%s' Update error: %s",
                        tostring(modName), msg))
                end
            end
            local elapsed_ms = (os.clock() - start) * 1000.0
            -- Accumulate timing for this mod
            if modTiming[modName] then
                modTiming[modName].total_ms = modTiming[modName].total_ms + elapsed_ms
                modTiming[modName].calls = modTiming[modName].calls + 1
                if elapsed_ms > modTiming[modName].max_ms then
                    modTiming[modName].max_ms = elapsed_ms
                end
            end
        end
    end
end