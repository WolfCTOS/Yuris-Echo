-- Yuri's Echo - AM2 laser + 120mm cannon, plus Alliance support abilities.
--
-- AM2 (table row "AM2"):
--   1. The engine fires [AM2Paint]: a red laser designator (Damage=55,
--      IsLaser=true, LaserDuration=45), so every shot is a visible paint.
--   2. PAINT_FRAMES (45) after the beam a 120mm shell lands for 105 AP.
--      Laser 55 + shell 105 = 160 per ROF=70, about 80% of the Apocalypse's
--      2 x 100 volley. Both weapons hit the same target one after another.
--   3. The cycle repeats every ROF_FRAMES (70) frames, the same period as
--      [AM2Paint] ROF, so the shell never drifts away from the beam.
--
-- Engine limit: this build cannot spawn projectiles from Lua (FireProjectile
-- and the BulletHook were removed; World.DetonateAt only accepts radiation
-- weapons), so the shell is applied as engine damage and is not drawn in
-- flight. The visible part is the laser beam. Damage carries no attacker
-- reference, so kills from the shell are not credited to the tank.
--
-- Callbacks: only Update is defined on the returned table. OnScenarioStart is a
-- global with last-write-wins semantics shared by every loaded mod, so this mod
-- never defines it; a new match is detected from the frame counter restarting.

-- Implemented in this file:
--   AM2    - laser paint + 120mm shell (about 80% of the Apocalypse)
--   CMIN   - at <=50% HP: EMP, chrono jump to a refinery, new field (60 s)
--   MGTK   - 20 dmg/s burn for 5 s while the Mirage keeps firing
--   BFRT   - heals passengers (10 HP/s), defuses passenger bombs and
--            releases ~50% of passengers when the fortress is destroyed
--   CCOMAND- 20 s teleport recharge after every chrono warp
--   DLPH   - deploy key (D): sonic EMP pulse, 60 s recharge per dolphin
--
-- Implemented in rulesmd.ini:
--   GGI    - M60 rifle, Deploy fires GGILaser (40 dmg, range 8)
--   JUMPJET- ground-only 2-rocket volley, elite uses the same weapon
--   GHOST  - Sensors 7 (SEAL)
--   SPY    - cloak while idle, Speed 5
--   CCOMAND- ChronoMP5AT anti-tank weapon
--   CLEG   - psionic immunity (no Sensors)
--   TANYA  - Sensors 9, Speed 9, Assaulter
--   SREF   - MinimumRange 1, native ShrapnelWeapon chain (3 x 80)
--   MGTK   - Sensors 7
--   ROBO   - Sensors 9
--   DEST   - SensorsSight 8
--   AEGIS  - Tomahawk land attack, VHPScan
--   CARRIER- SpawnsNumber 5
--   BEAG   - Phobos AttachEffect target painter (+15% damage taken, slow)
--   E2     - M1Carbine +20%

local YurisEcho = {}

local UNIT_TYPE      = "AM2"
local PAINT_FRAMES   = 45    -- 3 s at 15 logic frames/s; must equal LaserDuration
local SHELL_DAMAGE   = 105   -- 105 + 55 laser = 160 = 20% under APOC's 2 x 100
local SHELL_WARHEAD  = "AP"  -- 120mm anti-armour shell
local ROF_FRAMES     = 70    -- must equal [AM2Paint] ROF
local AIM_FRAMES     = 8     -- grace frames for the turret to turn before painting
local MAX_RANGE      = 6.5   -- cells; paint is dropped if the target gets away
local WAIT_FRAMES    = ROF_FRAMES - PAINT_FRAMES
local LOG            = true

-- Per-tank state: [unitId] = { phase, t, paintUntil, target }
local state = {}
local lastFrame = nil
local firstShellLogged = false

-- Chrono Miner (table row "Chrono-miner"): at <=50% HP, no more than once per
-- minute, disable enemy vehicles/aircraft around the miner, then jump to the
-- owner's refinery and re-task the harvester on a field near the base.
local CMIN_TYPE          = "CMIN"
local CMIN_TRIGGER       = 0.50
-- Long cooldowns are wall-clock seconds: the engine frame counter follows the
-- render rate, so a frame-based "minute" would shrink on high-FPS machines.
local CMIN_COOLDOWN_SEC  = 60
local CMIN_EMP_RADIUS    = 4    -- cells (starting value; tune in game)
local CMIN_EMP_FRAMES    = 90   -- engine frames for Disable (6 s at 15 fps)
local CMIN_REFINERIES    = { GAREFN = true, NAREFN = true, YAREFN = true }
local CMIN_POST_WARP     = 30   -- frames to let the warp-in finish
-- Landing cells around the refinery: rings of increasing radius, eight
-- directions each. Cells the engine refuses (occupied/building/water) are
-- skipped by trying the next one, so a crowded base still finds a spot.
local CMIN_WARP_RADII    = { 2, 3, 4 }
local CMIN_WARP_DIRS     = {
    { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
    { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 },
}
local minerState         = {}
local minersSeen         = {}

-- Mirage burn (table row "Mirage"): a hit applies 20 damage/s for 5 s.
-- LuaAPI has no damage event, so this is approximated from IsAttacking/GetTarget.
local MGTK_TYPE          = "MGTK"
local BURN_DAMAGE        = 20
local BURN_TICK          = 15   -- 1 s
local BURN_FRAMES        = 75   -- 5 s
local BURN_REFRESH       = 60   -- re-apply cadence while the Mirage keeps firing
local mirageState        = {}
local mirageSeen         = {}
local burns              = {}
local burnWarhead        = "Fire"
local burnWarheadChecked = false
local firstBurnLogged    = false

-- Battle Fortress (BFRT): heal passengers while alive and defuse any bomb
-- attached to a passenger before it can detonate inside the transport.
local BFRT_TYPE           = "BFRT"
local BFRT_TICK           = 15   -- 1 s
local BFRT_HEAL_PER_TICK  = 10   -- HP/s per passenger (starting value)
local bfrtState           = {}
local bfrtSeen            = {}
local bfrtFirstHealLogged = false
local bfrtFirstBombLogged = false

-- Chrono Commando (CCOMAND): long teleport recharge, and the warp leaves
-- him unable to act for the same period (vulnerable after the jump).
local CCOMAND_TYPE      = "CCOMAND"
local CCOMAND_RECHARGE  = 300  -- 20 s at 15 logic frames/s
local commandoState     = {}
local commandoSeen      = {}
local commandoLogged    = false

local function log(msg)
    if LOG then
        print("[Yuri's Echo] " .. tostring(msg))
    end
end

local function resolveBurnWarhead()
    if burnWarheadChecked then
        return
    end
    burnWarheadChecked = true
    local ok, exists = pcall(function() return Engine.WarheadExists("Fire") end)
    if not (ok and exists) then
        burnWarhead = "AP"
        log("WARNING: Fire warhead missing from rules; Mirage burn uses AP")
    end
end

local function hostile(a, b)
    if not a or not b then
        return false
    end
    local ok, allied = pcall(function() return a:IsAlliedWith(b) end)
    return ok and allied == false
end

-- CMIN: emergency EMP pulse plus chrono jump home.
-- Only enemy vehicles/aircraft are disabled; infantry and buildings are left
-- alone. The jump uses the native FootClass::ChronoWarpTo path (LuaAPI
-- unit:ChronoWarpTo), the same warp the engine performs for chrono units.
local function houseName(house)
    local ok, name = pcall(function() return house:GetName() end)
    if ok then
        return name
    end
    return nil
end

-- Nearest building of `ownerName`; refineries only when `refineryOnly` is set.
local function nearestOwnBuilding(ownerName, pos, refineryOnly)
    local ok, buildings = pcall(World.GetBuildings)
    if not ok or type(buildings) ~= "table" then
        return nil
    end

    local best, bestDist = nil, nil
    for _, b in ipairs(buildings) do
        local typeOk, typeName = pcall(function() return b:GetTypeName() end)
        if typeOk and typeName and (not refineryOnly or CMIN_REFINERIES[typeName]) then
            local ownerOk, bOwner = pcall(function() return b:GetOwner() end)
            if ownerOk and bOwner then
                local nameOk, bName = pcall(function() return bOwner:GetName() end)
                if nameOk and bName == ownerName then
                    local posOk, bPos = pcall(function() return b:GetPosition() end)
                    if posOk and bPos then
                        local dx, dy = bPos.x - pos.x, bPos.y - pos.y
                        local dist = dx * dx + dy * dy
                        if not bestDist or dist < bestDist then
                            best, bestDist = bPos, dist
                        end
                    end
                end
            end
        end
    end
    return best
end

-- Try the rings around `home` until the engine accepts a landing cell.
local function warpToRings(u, home)
    for _, radius in ipairs(CMIN_WARP_RADII) do
        for _, dir in ipairs(CMIN_WARP_DIRS) do
            local cx = home.x + dir[1] * radius
            local cy = home.y + dir[2] * radius
            local ok, warped = pcall(function() return u:ChronoWarpTo(cx, cy) end)
            if ok and warped then
                return { x = cx, y = cy }
            end
        end
    end
    return nil
end

-- Jump the miner next to its nearest refinery (any own building if the
-- refinery is gone) and schedule the post-warp harvest order.
local function jumpMinerHome(u, ownerName, pos, frame, s)
    local home = nearestOwnBuilding(ownerName, pos, true)
    local homeIsRefinery = home ~= nil
    if not home then
        home = nearestOwnBuilding(ownerName, pos, false)
    end
    if not home then
        log("CMIN emergency EMP only: no own refinery to jump to")
        return false
    end

    local dest = warpToRings(u, home)
    if not dest and homeIsRefinery then
        -- Every cell around the refinery is blocked: fall back to another own
        -- building rather than leaving the miner in the field.
        local fallback = nearestOwnBuilding(ownerName, pos, false)
        if fallback and (fallback.x ~= home.x or fallback.y ~= home.y) then
            dest = warpToRings(u, fallback)
            if dest then
                homeIsRefinery = false
            end
        end
    end
    if not dest then
        log("CMIN chrono jump failed: no landing cell around the home building")
        return false
    end

    s.pendingHarvest = frame + CMIN_POST_WARP
    s.hx, s.hy = dest.x, dest.y
    log(string.format("CMIN emergency jump to %s cell %d,%d",
        homeIsRefinery and "refinery" or "base building", dest.x, dest.y))
    return true
end

local function stepChronoMiner(u, frame)
    local idOk, id = pcall(function() return u:GetId() end)
    if not idOk or not id then
        return
    end
    minersSeen[id] = true

    local s = minerState[id]

    -- After the warp the harvester must not drive back to the field where it
    -- was ambushed; re-task it at the landing cell near the base instead.
    if s and s.pendingHarvest and frame >= s.pendingHarvest then
        local hx, hy = s.hx, s.hy
        s.pendingHarvest = nil
        local ok = pcall(function() return u:HarvestAt(hx, hy) end)
        log(string.format("CMIN post-warp harvest order at %d,%d -> %s",
            hx, hy, tostring(ok)))
    end

    local hpOk, hp = pcall(function() return u:GetHealth() end)
    local maxOk, maxHp = pcall(function() return u:GetMaxHealth() end)
    if not hpOk or not maxOk or not maxHp or maxHp <= 0 then
        return
    end
    if hp / maxHp > CMIN_TRIGGER then
        return
    end

    if not s then
        s = {}
        minerState[id] = s
    end
    if s.lastEmpAt and (os.time() - s.lastEmpAt) < CMIN_COOLDOWN_SEC then
        return
    end

    local posOk, pos = pcall(function() return u:GetPosition() end)
    local ownerOk, owner = pcall(function() return u:GetOwner() end)
    if not posOk or not pos or not ownerOk or not owner then
        return
    end

    local targetsOk, targets = pcall(World.GetUnitsInRadius, pos.x, pos.y, CMIN_EMP_RADIUS)
    if not targetsOk or type(targets) ~= "table" then
        return
    end

    local hit = 0
    for _, t in ipairs(targets) do
        local kindOk, kind = pcall(function() return t:GetKind() end)
        local tOwnerOk, tOwner = pcall(function() return t:GetOwner() end)
        if kindOk and tOwnerOk and (kind == "unit" or kind == "aircraft") and
           hostile(owner, tOwner) then
            local ok = pcall(function() return t:Disable(CMIN_EMP_FRAMES) end)
            if ok then
                hit = hit + 1
            end
        end
    end

    s.lastEmpAt = os.time()
    if hit > 0 then
        log(string.format("CMIN emergency EMP: %d target(s) disabled", hit))
    end

    local ownerName = houseName(owner)
    if ownerName then
        jumpMinerHome(u, ownerName, pos, frame, s)
    end
end

-- MGTK: while the Mirage keeps firing, refresh a 5-second burn on its target.
-- No damage event is available, so this is driven by IsAttacking()/GetTarget().
local function stepMirage(u, frame)
    local idOk, id = pcall(function() return u:GetId() end)
    if not idOk or not id then
        return
    end
    mirageSeen[id] = true

    local s = mirageState[id]
    if not s then
        s = { targetId = nil, lastRefresh = -BURN_REFRESH }
        mirageState[id] = s
    end

    local attackOk, attacking = pcall(function() return u:IsAttacking() end)
    if not attackOk or not attacking then
        s.targetId = nil
        return
    end

    local targetOk, target = pcall(function() return u:GetTarget() end)
    if not targetOk or not target then
        s.targetId = nil
        return
    end
    local aliveOk, alive = pcall(function() return target:IsAlive() end)
    if not aliveOk or not alive then
        s.targetId = nil
        return
    end
    local tidOk, tid = pcall(function() return target:GetId() end)
    if not tidOk or not tid then
        return
    end

    if s.targetId ~= tid or frame - s.lastRefresh >= BURN_REFRESH then
        s.targetId = tid
        s.lastRefresh = frame
        local b = burns[tid]
        if not b then
            burns[tid] = { target = target, untilFrame = frame + BURN_FRAMES, nextTick = frame }
        else
            b.target = target
            b.untilFrame = frame + BURN_FRAMES
        end
    end
end

-- Applies the Mirage burn ticks and drops expired/dead targets.
local function tickBurns(frame)
    for id, b in pairs(burns) do
        local aliveOk, alive = pcall(function() return b.target:IsAlive() end)
        if not aliveOk or not alive or frame >= b.untilFrame then
            burns[id] = nil
        elseif frame >= b.nextTick then
            pcall(function() b.target:TakeDamage(BURN_DAMAGE, burnWarhead) end)
            b.nextTick = frame + BURN_TICK
            if not firstBurnLogged then
                firstBurnLogged = true
                log(string.format("Mirage burn: %d dmg / %d frames, %s",
                    BURN_DAMAGE, BURN_FRAMES, burnWarhead))
            end
        end
    end
end

-- BFRT: once per second, heal every passenger and defuse any attached bomb.
-- The passenger itself is in limbo, so healing uses the native passenger path
-- instead of SetHealthRatio (which refuses limboed objects).
local function stepBattleFortress(u, frame)
    local idOk, id = pcall(function() return u:GetId() end)
    if not idOk or not id then
        return
    end
    bfrtSeen[id] = true

    local s = bfrtState[id]
    if not s then
        s = { lastTick = -BFRT_TICK }
        bfrtState[id] = s
    end

    local hpOk, hp = pcall(function() return u:GetHealth() end)
    if hpOk and hp then
        s.dead = (hp <= 0)
    end

    if frame - s.lastTick < BFRT_TICK then
        return
    end
    s.lastTick = frame

    local posOk, pos = pcall(function() return u:GetPosition() end)
    if posOk and pos then
        s.x = pos.x
        s.y = pos.y
    end
    local ownerOk, owner = pcall(function() return u:GetOwner() end)
    if ownerOk and owner then
        s.owner = owner
    end

    local countOk, count = pcall(function() return u:GetPassengerCount() end)
    if countOk and count and count > 0 then
        local healedOk, healed = pcall(function() return u:HealPassengers(BFRT_HEAL_PER_TICK) end)
        if healedOk and healed and healed > 0 and not bfrtFirstHealLogged then
            bfrtFirstHealLogged = true
            log(string.format("BFRT heals %d passenger(s) by %d HP/s",
                count, BFRT_HEAL_PER_TICK))
        end
    end

    local passengersOk, passengers = pcall(function() return u:GetPassengers() end)
    if not passengersOk or type(passengers) ~= "table" then
        return
    end

    -- Remember who is inside so a destroyed fortress can release survivors.
    if not s.dead then
        s.types = {}
        for _, p in ipairs(passengers) do
            local typeOk, typeName = pcall(function() return p:GetTypeName() end)
            if typeOk and type(typeName) == "string" and typeName ~= "" then
                s.types[#s.types + 1] = typeName
            end
        end
    end

    for _, p in ipairs(passengers) do
        local bombOk, hasBomb = pcall(function() return p:HasBomb() end)
        if bombOk and hasBomb then
            local disarmOk, disarmed = pcall(function() return p:DisarmBomb() end)
            if disarmOk and disarmed and not bfrtFirstBombLogged then
                bfrtFirstBombLogged = true
                log("BFRT defused a bomb on a passenger (no explosion inside transport)")
            end
        end
    end
end

-- CCOMAND: detect a chrono warp (large position jump in one tick) and apply
-- the long recharge. The engine's own chrono delay is much shorter.
local function stepCommando(u, frame)
    local idOk, id = pcall(function() return u:GetId() end)
    if not idOk or not id then
        return
    end
    commandoSeen[id] = true

    local posOk, pos = pcall(function() return u:GetPosition() end)
    if not posOk or not pos then
        return
    end

    local s = commandoState[id]
    if not s then
        s = { x = pos.x, y = pos.y, lastJump = -CCOMAND_RECHARGE }
        commandoState[id] = s
        return
    end

    local dx = pos.x - s.x
    local dy = pos.y - s.y
    local warped = (dx * dx + dy * dy) > 9.0 -- more than 3 cells in one tick
    s.x = pos.x
    s.y = pos.y

    if warped and frame - s.lastJump > 60 then
        s.lastJump = frame
        local ok = pcall(function() return u:Disable(CCOMAND_RECHARGE) end)
        if ok and not commandoLogged then
            commandoLogged = true
            log(string.format("CCOMAND chrono warp: %d frames recharge",
                CCOMAND_RECHARGE))
        end
    end
end

-- DLPH (table row "Dolphin"): pressing the deploy key (D) while one or more
-- dolphins are selected fires a sonic EMP pulse. The pulse uses the Ares
-- EMP.Duration on [SonicPulseWH]; every enemy vehicle in range is disabled
-- for ~6 s. Recharge: 60 s per dolphin.
local DLPH_TYPE         = "DLPH"
local DLPH_RANGE        = 6    -- cells
local DLPH_COOLDOWN     = 900  -- 60 s at 15 logic frames/s
local DLPH_EMP_WARHEAD  = "SonicPulseWH"
local DLPH_DAMAGE       = 1
local DLPH_EMP_FRAMES   = 90   -- must equal [SonicPulseWH] EMP.Duration
local VK_DEPLOY         = 0x44 -- D
local dlphState         = {}
local dlphFirstLogged   = false

local function pulseDolphins(frame)
    local ok, pressed = pcall(function() return Input.WasKeyPressed(VK_DEPLOY) end)
    if not ok or not pressed then
        return
    end

    local selOk, selected = pcall(World.GetSelectedUnits)
    if not selOk or type(selected) ~= "table" then
        return
    end

    for _, u in ipairs(selected) do
        local nameOk, name = pcall(function() return u:GetTypeName() end)
        if nameOk and type(name) == "string" and name:upper() == DLPH_TYPE then
            local idOk, id = pcall(function() return u:GetId() end)
            if idOk and id then
                local s = dlphState[id]
                if not s then
                    s = { lastUse = -DLPH_COOLDOWN }
                    dlphState[id] = s
                end
                if frame - s.lastUse >= DLPH_COOLDOWN then
                    local posOk, pos = pcall(function() return u:GetPosition() end)
                    local ownerOk, owner = pcall(function() return u:GetOwner() end)
                    if posOk and pos and ownerOk and owner then
                        local targetsOk, targets = pcall(World.GetUnitsInRadius,
                            pos.x, pos.y, DLPH_RANGE)
                        if targetsOk and type(targets) == "table" then
                            local hit = 0
                            for _, t in ipairs(targets) do
                                local kindOk, kind = pcall(function() return t:GetKind() end)
                                local tOwnerOk, tOwner = pcall(function() return t:GetOwner() end)
                                if kindOk and tOwnerOk and kind == "unit" and
                                   hostile(owner, tOwner) then
                                    local okd = pcall(function()
                                        t:TakeDamage(DLPH_DAMAGE, DLPH_EMP_WARHEAD)
                                    end)
                                    if okd then
                                        hit = hit + 1
                                    end
                                end
                            end
                            s.lastUse = frame
                            if hit > 0 and not dlphFirstLogged then
                                dlphFirstLogged = true
                                log(string.format("DLPH sonic pulse: %d vehicle(s) disabled for %d frames",
                                    hit, DLPH_EMP_FRAMES))
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Returns the tank's live target, or nil when it has none or it is out of reach.
local function currentTarget(u)
    local target = u:GetTarget()
    if not target or not target:IsAlive() then
        return nil
    end
    local distance = u:GetDistanceTo(target)
    if distance and distance > MAX_RANGE then
        return nil
    end
    return target
end

-- Lands the 120mm shell. Returns false when the target is gone.
local function fireShell(s, frame)
    if not s.target or not s.target:IsAlive() then
        return false
    end
    s.target:TakeDamage(SHELL_DAMAGE, SHELL_WARHEAD)
    s.phase = "wait"
    s.t = frame
    if not firstShellLogged then
        firstShellLogged = true
        log(string.format("first 120mm shell: %d damage, %s",
            SHELL_DAMAGE, SHELL_WARHEAD))
    end
    return true
end

local function stepTank(u, frame)
    local id = u:GetId()
    if not id then
        return
    end

    local s = state[id]
    if not s then
        s = { phase = "idle", t = 0, paintUntil = 0, target = nil }
        state[id] = s
    end

    local target = currentTarget(u)
    if not target then
        -- Lost the target or it left the tank's reach: the paint is broken and the
        -- next engagement starts from a fresh aim.
        s.phase = "idle"
        s.target = nil
        return
    end

    -- The shell lands on whatever the tank is pointing at right now.
    s.target = target

    if s.phase == "idle" then
        s.phase = "aim"
        s.t = frame
    elseif s.phase == "aim" then
        if frame - s.t >= AIM_FRAMES then
            s.phase = "paint"
            s.paintUntil = frame + PAINT_FRAMES
        end
    elseif s.phase == "paint" then
        if frame >= s.paintUntil then
            -- The beam has finished designating: the 120mm shell lands now.
            if not fireShell(s, frame) then
                s.phase = "idle"
                s.target = nil
            end
        end
    elseif s.phase == "wait" then
        -- Stay on the laser's cadence: the next beam fires at ROF_FRAMES after
        -- the previous one, so the next paint starts without another aim phase.
        if frame - s.t >= WAIT_FRAMES then
            s.phase = "paint"
            s.paintUntil = frame + PAINT_FRAMES
        end
    end
end

function YurisEcho.Update(frame)
    if type(frame) ~= "number" then
        return
    end

    if lastFrame and frame < lastFrame then
        -- New match / scenario: the loader keeps the mod table, its cached state
        -- must not leak across sessions.
        state = {}
        minerState = {}
        mirageState = {}
        burns = {}
        minersSeen = {}
        mirageSeen = {}
        bfrtState = {}
        bfrtSeen = {}
        commandoState = {}
        commandoSeen = {}
        dlphState = {}
        firstShellLogged = false
        firstBurnLogged = false
        bfrtFirstHealLogged = false
        bfrtFirstBombLogged = false
        commandoLogged = false
        dlphFirstLogged = false
        log("new session")
    end
    lastFrame = frame

    resolveBurnWarhead()

    local ok, units = pcall(World.GetUnits)
    if not ok or type(units) ~= "table" then
        return
    end

    local seen = {}
    minersSeen = {}
    mirageSeen = {}
    bfrtSeen = {}
    commandoSeen = {}

    for _, u in ipairs(units) do
        local nameOk, name = pcall(function() return u:GetTypeName() end)
        if nameOk and type(name) == "string" then
            local upper = name:upper()
            if upper == UNIT_TYPE then
                local idOk, id = pcall(function() return u:GetId() end)
                if idOk and id then
                    seen[id] = true
                    local stepOk, err = pcall(stepTank, u, frame)
                    if not stepOk then
                        log("unit " .. tostring(id) .. " error: " .. tostring(err))
                        state[id] = nil
                    end
                end
            elseif upper == CMIN_TYPE then
                local stepOk, err = pcall(stepChronoMiner, u, frame)
                if not stepOk then
                    log("CMIN error: " .. tostring(err))
                end
            elseif upper == MGTK_TYPE then
                local stepOk, err = pcall(stepMirage, u, frame)
                if not stepOk then
                    log("MGTK error: " .. tostring(err))
                end
            elseif upper == "BFRT" then
                local stepOk, err = pcall(stepBattleFortress, u, frame)
                if not stepOk then
                    log("BFRT error: " .. tostring(err))
                end
            elseif upper == CCOMAND_TYPE then
                local stepOk, err = pcall(stepCommando, u, frame)
                if not stepOk then
                    log("CCOMAND error: " .. tostring(err))
                end
            end
        end
    end

    -- Forget tanks / miners / Mirages that died or were sold.
    for id in pairs(state) do
        if not seen[id] then
            state[id] = nil
        end
    end
    for id in pairs(minerState) do
        if not minersSeen[id] then
            minerState[id] = nil
        end
    end
    for id in pairs(mirageState) do
        if not mirageSeen[id] then
            mirageState[id] = nil
        end
    end
    for id in pairs(commandoState) do
        if not commandoSeen[id] then
            commandoState[id] = nil
        end
    end
    for id, s in pairs(bfrtState) do
        if not bfrtSeen[id] then
            if s and s.dead and s.types and #s.types > 0 and s.owner and s.x and s.y then
                local survivors = math.max(1, math.floor(#s.types * 0.5 + 0.5))
                local spawned = 0
                for i = 1, survivors do
                    local typeName = s.types[i]
                    if typeName then
                        local ok, n = pcall(function()
                            return s.owner:SpawnInfantry(typeName, 1, s.x, s.y)
                        end)
                        if ok and n and n > 0 then
                            spawned = spawned + n
                        end
                    end
                end
                if spawned > 0 then
                    log(string.format("BFRT destroyed: %d/%d passenger(s) survived",
                        spawned, #s.types))
                end
            end
            bfrtState[id] = nil
        end
    end

    tickBurns(frame)
    pulseDolphins(frame)
end

return YurisEcho
