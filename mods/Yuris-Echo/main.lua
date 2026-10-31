-- Yuri's Echo - AM2 laser paint + Guardian GI rocket volley.
--
-- Design (matches rulesmd.ini [AM2Paint]):
--   1. The AM2 fires its 105mm gun as a red laser designator beam: one weapon,
--      cannon damage 55 with IsLaser=true, drawn for LaserDuration=45 frames
--      (~3 s), so every shot is a cannon hit plus a visible paint.
--   2. PAINT_FRAMES (45) frames after the beam, three Guardian GI rocket hits
--      land, 4 frames apart, with the rocket warhead GUARDWH.
--   3. The cycle repeats every ROF_FRAMES (70) frames, the same period as the
--      gun's ROF, so each shot is followed by exactly one volley and the two
--      stay in sync instead of drifting.
--
-- Damage: 3 x 35 = 105 per volley, plus 55 from the gun = 160 per shot, i.e.
-- 20% below the Apocalypse's 2 x 100 volley: AM2 is meant to be APOC's rival,
-- not its superior. The Alliance keeps its edge through technology - the laser
-- designator, faster speed and longer sight - not through raw damage.
-- GUARDWH is the Guardian GI rocket warhead (100% vs heavy armour).
--
-- Engine limit: this build cannot spawn projectiles from Lua (FireProjectile and
-- the BulletHook were removed; World.DetonateAt only accepts radiation weapons),
-- so the rockets are applied as engine damage and are not drawn in flight. The
-- visible part of the mechanic is the laser paint itself, which is a real engine
-- IsLaser beam. Damage also carries no attacker reference, so kills from the
-- volley are not credited to the tank.
--
-- Callbacks: only Update is defined on the returned table. OnScenarioStart is a
-- global with last-write-wins semantics shared by every loaded mod, so this mod
-- never defines it; a new match is detected from the frame counter restarting.

-- Implemented in this file:
--   AM2    - laser paint + Guardian GI rocket volley
--   CMIN   - emergency EMP at <=50% HP, 60 s cooldown
--   MGTK   - 20 dmg/s burn for 5 s while the Mirage keeps firing
--   BFRT   - heals passengers (10 HP/s), defuses passenger bombs and
--            releases ~50% of passengers when the fortress is destroyed

local YurisEcho = {}

local UNIT_TYPE      = "AM2"
local PAINT_FRAMES   = 45    -- 3 s at 15 logic frames/s; must equal LaserDuration
local ROCKETS        = 3     -- rockets per volley
local ROCKET_DAMAGE  = 35    -- 3 x 35 + 55 gun = 160 = 20% under APOC's 2 x 100
local ROCKET_WARHEAD = "GUARDWH" -- Guardian GI rocket warhead
local ROCKET_GAP     = 4     -- frames between rocket impacts
local ROF_FRAMES     = 70    -- must equal [AM2Paint] ROF
local AIM_FRAMES     = 8     -- grace frames for the turret to turn before painting
local MAX_RANGE      = 6.5   -- cells; paint is dropped if the target gets away
local WAIT_FRAMES    = ROF_FRAMES - PAINT_FRAMES - (ROCKETS - 1) * ROCKET_GAP
local LOG            = true

-- Per-tank state: [unitId] = { phase, t, paintUntil, target, sent, nextHit }
local state = {}
local lastFrame = nil
local warhead = ROCKET_WARHEAD
local warheadChecked = false
local firstVolleyLogged = false

-- Chrono Miner emergency EMP (table row "Chrono-miner"): at <=50% HP, no more
-- than once per minute, disable enemy vehicles/aircraft around the miner.
local CMIN_TYPE          = "CMIN"
local CMIN_TRIGGER       = 0.50
local CMIN_COOLDOWN      = 900  -- 60 s at 15 logic frames/s
local CMIN_EMP_RADIUS    = 4    -- cells (starting value; tune in game)
local CMIN_EMP_FRAMES    = 90   -- 6 s disable
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

local function log(msg)
    if LOG then
        print("[Yuri's Echo] " .. tostring(msg))
    end
end

local function resolveWarhead()
    if warheadChecked then
        return
    end
    warheadChecked = true
    local ok, exists = pcall(function() return Engine.WarheadExists(ROCKET_WARHEAD) end)
    if ok and exists then
        log("volley warhead " .. ROCKET_WARHEAD .. " (Guardian GI rocket)")
    else
        -- TakeDamage would otherwise fall back silently to TerrorBombWH, which is
        -- nearly useless against armour and gives burning-infantry deaths.
        warhead = "AP"
        log("WARNING: warhead " .. ROCKET_WARHEAD .. " missing from rules, using AP")
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

-- CMIN: one emergency EMP pulse when the miner drops to <=50% HP, then a
-- 60-second cooldown. Only enemy vehicles/aircraft are disabled; infantry and
-- buildings are left alone.
local function stepChronoMiner(u, frame)
    local idOk, id = pcall(function() return u:GetId() end)
    if not idOk or not id then
        return
    end
    minersSeen[id] = true

    local hpOk, hp = pcall(function() return u:GetHealth() end)
    local maxOk, maxHp = pcall(function() return u:GetMaxHealth() end)
    if not hpOk or not maxOk or not maxHp or maxHp <= 0 then
        return
    end
    if hp / maxHp > CMIN_TRIGGER then
        return
    end

    local s = minerState[id]
    if not s then
        s = { lastEmp = -CMIN_COOLDOWN }
        minerState[id] = s
    end
    if frame - s.lastEmp < CMIN_COOLDOWN then
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

    s.lastEmp = frame
    if hit > 0 then
        log(string.format("CMIN emergency EMP: %d target(s) disabled", hit))
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

-- Lands one rocket of the volley. Returns false when the target is gone.
local function fireRocket(s, frame)
    if not s.target or not s.target:IsAlive() then
        return false
    end
    s.target:TakeDamage(ROCKET_DAMAGE, warhead)
    s.sent = s.sent + 1
    s.nextHit = frame + ROCKET_GAP
    if s.sent >= ROCKETS then
        s.phase = "wait"
        s.t = frame
        if not firstVolleyLogged then
            firstVolleyLogged = true
            log(string.format("first volley: %d rockets x %d, %s",
                ROCKETS, ROCKET_DAMAGE, warhead))
        end
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
        s = { phase = "idle", t = 0, paintUntil = 0, target = nil, sent = 0, nextHit = 0 }
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

    -- The rockets home on whatever the tank is pointing at right now.
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
            -- The beam has finished designating: the first rocket lands now, the
            -- rest follow one ROCKET_GAP apart.
            s.phase = "volley"
            s.sent = 0
            if not fireRocket(s, frame) then
                s.phase = "idle"
                s.target = nil
            end
        end
    elseif s.phase == "volley" then
        if frame >= s.nextHit then
            if not fireRocket(s, frame) then
                s.phase = "idle"
                s.target = nil
                return
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
        firstVolleyLogged = false
        firstBurnLogged = false
        bfrtFirstHealLogged = false
        bfrtFirstBombLogged = false
        log("new session")
    end
    lastFrame = frame

    resolveWarhead()
    resolveBurnWarhead()

    local ok, units = pcall(World.GetUnits)
    if not ok or type(units) ~= "table" then
        return
    end

    local seen = {}
    minersSeen = {}
    mirageSeen = {}
    bfrtSeen = {}

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
end

return YurisEcho
