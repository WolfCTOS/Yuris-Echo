-- EMP nerf for the Yuri T3 tanks (LTNK "Lasher Light Tank").
--
-- PROBLEM
--   The Yuri Lasher Light Tank (LTNK) is a T3-grade tank: heavy armor,
--   Apocalypse-grade cannon (ATGUN), Crusher=yes, buildable at the War
--   Factory. It snowballs and becomes OP.
--
-- SOLUTION
--   Half of the Lasher tanks are held in an EMP-paralyzed state (the engine's
--   native "disabled" state for vehicles) for as long as the human player has
--   no War Factory. As soon as a War Factory exists (allied GAWEAP, soviet
--   NAWEAP, yuri YAWEAP), the paralysis is not refreshed any more, the
--   engine timer expires and every tank returns to full strength.
--
-- WHY LUAAPI AND NOT ARES/PHOBOS
--   "Half of them" is a per-unit runtime decision. No rules key can express
--   it: a rules change hits every LTNK of the type (AI included) and cannot
--   react to the factory appearing later. Ares has no primitive for this at
--   all; Phobos could only do a static variant (a second unit type with an
--   EMP weapon, swapped in the rules) which is not "half, and not until the
--   War Factory". LuaAPI does exactly what is asked: it watches the units
--   and the factory and flips the state at runtime.
--
-- INSTALL
--   1. copy mods/ltnk_emp_nerf/ to <YR>\mods\
--   2. add the line "ltnk_emp_nerf" to <YR>\scripts\active_mods.txt
--   3. start the game through injector.exe
--
-- SCOPE
--   AFFECTED_HOUSES picks whose tanks are nerfed ("YuriCountry" = Yuri).
--   The release condition is always the HUMAN player's own War Factory, so
--   the mod is correct in both directions:
--     * the player IS Yuri  -> his own tanks stay EMP-held until he builds
--       the War Factory (mission-given tanks included);
--     * the player fights Yuri -> the AI's tanks stay EMP-held until the
--       player is able to build tanks of his own.

local Mod = {}

local CFG = {
    -- units that get the nerf
    TARGET_TYPES = { "LTNK" },
    -- houses whose units are nerfed (Owner= of [LTNK] is YuriCountry)
    AFFECTED_HOUSES = { "YuriCountry" },
    -- buildings that release the nerf (Name= of the sections)
    WAR_FACTORY_TYPES = { "GAWEAP", "NAWEAP", "YAWEAP" },

    -- "PARALYZE"  : half of the tanks are EMP-held (engine disable state)
    -- "EMP_WEAPON": all tanks of the type fire the mod's EMP pulse weapon
    --               instead of the real gun until the War Factory is up
    MODE = "PARALYZE",
    EMP_WEAPON_ID = "EMPulseWeapon",
    VET_LEVEL_KEYS = { "Rookie", "Veteran", "Elite", 0, 1, 2 },

    -- logical frames between two scans of the unit list
    SCAN_INTERVAL = 15,
    -- length of one EMP hold window; refreshed on every scan, so the tanks
    -- stay paralyzed while the nerf is active and wake up ~1-2 s after the
    -- release
    DISABLE_FRAMES = 60,

    SHOW_MESSAGES = true,
    -- debug key (N) toggles the nerf by hand, to test without a factory
    DEBUG_KEY = 0x4E,
}

local S = {
    lastFrame = 0,
    decided = {},     -- [unitId] = true (EMP-held) | false (left alone)
    released = false, -- true once the War Factory was seen
    notified = false,
}

local function log(msg)
    print("[LTNK-EMP] " .. tostring(msg))
end

local function say(msg)
    if CFG.SHOW_MESSAGES and Engine and Engine.PrintMessage then
        pcall(Engine.PrintMessage, msg)
    end
end

local function houseName(h)
    if not h then return nil end
    local ok, name = pcall(h.GetName, h)
    if ok and type(name) == "string" then return name end
    return nil
end

local function playerHouse()
    if House and House.GetPlayer then
        local ok, h = pcall(House.GetPlayer)
        if ok then return h end
    end
    return nil
end

local function listContains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function isAffectedHouse(h)
    local name = houseName(h)
    if not name then return false end
    return listContains(CFG.AFFECTED_HOUSES, name)
end

local function alive(u)
    if not u then return false end
    local ok, res = pcall(u.IsAlive, u)
    return ok and res == true
end

local function typeOf(o)
    if not o then return nil end
    local ok, name = pcall(o.GetTypeName, o)
    if ok and type(name) == "string" then return name end
    return nil
end

local function ownerOf(o)
    if not o then return nil end
    local ok, h = pcall(o.GetOwner, o)
    if ok then return h end
    return nil
end

local function idOf(o)
    if not o then return nil end
    local ok, id = pcall(o.GetId, o)
    if ok and type(id) == "number" then return id end
    return nil
end

-- every War Factory of the human player
local function playerHasWarFactory(player)
    if not (World and World.GetBuildings) then return false end
    local ok, buildings = pcall(World.GetBuildings)
    if not ok or not buildings then return false end

    local playerName = houseName(player)
    if not playerName then return false end

    for _, b in ipairs(buildings) do
        if alive(b) then
            local tn = typeOf(b)
            if tn and listContains(CFG.WAR_FACTORY_TYPES, tn) then
                if houseName(ownerOf(b)) == playerName then
                    return true
                end
            end
        end
    end
    return false
end

-- every nerfed unit of the affected houses
local function collectTargets()
    local found = {}
    if not World then return found end

    local units = nil
    if World.GetUnits then
        local ok, list = pcall(World.GetUnits)
        if ok and list then units = list end
    end
    if not units and World.GetAllUnits then
        local ok, list = pcall(World.GetAllUnits)
        if ok and list then units = list end
    end
    if not units then return found end

    for _, u in ipairs(units) do
        if alive(u) then
            local tn = typeOf(u)
            if tn and listContains(CFG.TARGET_TYPES, tn) then
                if isAffectedHouse(ownerOf(u)) then
                    local id = idOf(u)
                    if id then
                        found[#found + 1] = { unit = u, id = id }
                    end
                end
            end
        end
    end
    return found
end

-- decides once per unit whether it is one of the nerfed half; the decision
-- never flips, so a tank keeps its state for the whole match
local function classify(targets)
    local total, held = 0, 0
    for _, t in ipairs(targets) do
        if S.decided[t.id] == nil then
            if held * 2 <= total then
                S.decided[t.id] = true
            else
                S.decided[t.id] = false
            end
        end
        total = total + 1
        if S.decided[t.id] then held = held + 1 end
    end
    return held, total
end

local function holdUnit(u)
    pcall(u.Disable, u, CFG.DISABLE_FRAMES)
end

local function setEmpWeapon(on)
    if not WeaponOverride then return end
    for _, ty in ipairs(CFG.TARGET_TYPES) do
        if on then
            for _, key in ipairs(CFG.VET_LEVEL_KEYS) do
                pcall(WeaponOverride.Set, ty, key, CFG.EMP_WEAPON_ID)
            end
        else
            pcall(WeaponOverride.Clear, ty)
        end
    end
end

local function releaseAll(reason)
    if S.released then return end
    S.released = true
    if CFG.MODE == "EMP_WEAPON" then
        setEmpWeapon(false)
    end
    say("EMP HOLD OFF: " .. reason)
    log("released: " .. reason)
end

local function scan()
    local targets = collectTargets()
    local held, total = classify(targets)

    if CFG.MODE == "EMP_WEAPON" then
        if total > 0 then
            setEmpWeapon(true)
        end
    else
        for _, t in ipairs(targets) do
            if S.decided[t.id] then
                holdUnit(t.unit)
            end
        end
    end

    if not S.notified and held > 0 then
        S.notified = true
        say("EMP HOLD: " .. held .. "/" .. total .. " Lasher tanks paralyzed until War Factory.")
        log("held " .. held .. " of " .. total)
    end
end

function OnScenarioStart()
    S.lastFrame = 0
    S.decided = {}
    S.released = false
    S.notified = false
end

function Mod.Update(frame)
    if type(frame) ~= "number" then return end

    -- new match (the logical frame counter restarted)
    if frame < S.lastFrame then
        S.lastFrame = frame
        S.decided = {}
        S.released = false
        S.notified = false
    end
    S.lastFrame = frame

    if Input and Input.WasKeyPressed and CFG.DEBUG_KEY then
        local ok, pressed = pcall(Input.WasKeyPressed, CFG.DEBUG_KEY)
        if ok and pressed then
            if S.released then
                S.released = false
                S.notified = false
                say("EMP HOLD ON (debug)")
            else
                releaseAll("debug key")
            end
        end
    end

    if S.released then return end

    if frame % CFG.SCAN_INTERVAL ~= 0 then return end

    local player = playerHouse()
    if not player then return end

    if playerHasWarFactory(player) then
        releaseAll("War Factory detected")
        return
    end

    scan()
end

return Mod
