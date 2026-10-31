-- AI Ignore --------------------------------------------------------------
-- Мод LuaAPI: ИИ-дома «не замечают» игрока и перенацеливаются на его союзника.
--
-- ЧЕСТНО О ГРАНИЦАХ. Движок (gamemd.exe) сам выбирает цели, и Lua не может
-- отключить игрока как противника. Мод работает по факту: каждый скан он
-- смотрит, кто из ИИ-юнитов целится в игрока, и переводит их на другую цель —
-- по умолчанию на дом, союзный игроку. Если игрока никто не держит в цели,
-- мод ничего не делает. Единичные удары всё равно пройдут: между сканами
-- (~0.5-1 c) движок успевает выстрелить.
--
-- Ещё он снимает с игрока ванильные атакующие группы: если у ИИ-группы
-- (World.GetAITeams) цель = дом игрока, её бойцы перецеливаются туда же.
--
-- ЛОГ: <эта папка>/logs/ignore-<дата>.jsonl — по строке на перенацеливание
--      и статистика раз в 20 сканов.
-- ВЫКЛЮЧИТЬ: CFG.ENABLED = false или убрать "AI Ignore" из mods/active_mods.txt.

local Mod = {}

local CFG = {
    ENABLED = true,
    SCAN_INTERVAL = 15,        -- кадров между сканами (~0.5 c при 30 fps)
    IGNORED_HOUSE = nil,       -- nil = дом человека (House.GetPlayer())
    PREFER_PLAYER_ALLY = true, -- цель по умолчанию — союзник игрока
    HANDLE_TEAMS = true,       -- снимать с игрока ванильные ИИ-группы
    MAX_REDIRECTS_PER_SCAN = 80,
    LOG_DIR = "logs",
    TAG = "[AIIGNORE] ",
}

local S = {
    lastFrame = nil,
    scans = 0,
    redirectedTotal = 0,
    lastRedir = {},   -- unit id -> { t = id цели, f = кадр }
    file = nil,
}

local function log(msg)
    print(CFG.TAG .. tostring(msg))
end

--============================================================ утилиты ====

local function toSlash(p) return (p:gsub("\\", "/")) end

local MOD_DIR = toSlash((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""))

local function mcall(mod, name, ...)
    if type(mod) ~= "table" then return nil end
    local fn = mod[name]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function ocall(obj, name, ...)
    if obj == nil then return nil end
    local fn = obj[name]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, obj, ...)
    if ok then return res end
    return nil
end

local function esc(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[\r\n\t]", " ")
    return s
end

local function jstr(v) return '"' .. esc(v) .. '"' end

local function jnum(v)
    if type(v) ~= "number" or v ~= v then return "0" end
    return string.format("%d", math.floor(v))
end

local function openLog()
    if S.file then return true end
    local dir = MOD_DIR .. CFG.LOG_DIR .. "/"
    local path = dir .. "ignore-" .. os.date("%Y%m%d-%H%M%S") .. ".jsonl"
    local f = io.open(path, "a")
    if not f then
        pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
        f = io.open(path, "a")
    end
    if not f then
        path = MOD_DIR .. "ignore-" .. os.date("%Y%m%d-%H%M%S") .. ".jsonl"
        f = io.open(path, "a")
    end
    if not f then
        log("не удалось открыть лог, ставлю ENABLED=false")
        CFG.ENABLED = false
        return false
    end
    S.file = f
    log("лог: " .. path)
    return true
end

local function emit(line)
    if not openLog() then return end
    S.file:write(line, "\n")
    S.file:flush()
end

--=============================================================== дома ====

local function houseName(h)
    return ocall(h, "GetName") or "?"
end

local function allHouses()
    local out = {}
    local n = tonumber(mcall(House, "GetCount")) or 0
    for i = 0, n - 1 do
        local h = mcall(House, "GetByIndex", i)
        if h ~= nil then out[#out + 1] = h end
    end
    return out
end

local function ignoredHouse()
    if CFG.IGNORED_HOUSE then
        for _, h in ipairs(allHouses()) do
            if houseName(h) == CFG.IGNORED_HOUSE then return h end
        end
        return nil
    end
    return mcall(House, "GetPlayer")
end

local function isAllied(a, b)
    if a == nil or b == nil then return false end
    return ocall(a, "IsAlliedWith", b) == true
end

--============================================================= объекты ====

local function worldObjects()
    local units, buildings = {}, {}
    local u = mcall(World, "GetUnits")
    if type(u) == "table" then units = u end
    local b = mcall(World, "GetBuildings")
    if type(b) == "table" then buildings = b end
    return units, buildings
end

local function objInfo(o)
    if o == nil or ocall(o, "IsAlive") == false then return nil end
    local id = tonumber(ocall(o, "GetId"))
    if id == nil then return nil end
    return {
        obj = o,
        id = id,
        type = ocall(o, "GetTypeName") or "?",
        house = ocall(o, "GetOwner"),
        name = houseName(ocall(o, "GetOwner")),
    }
end

-- Ближайший к unit объект из списка candidates (берём первым тех, кто
-- не является союзником владельца unit).
local function nearest(unit, candidates)
    local best, bestD
    for _, c in ipairs(candidates) do
        local d = tonumber(ocall(unit, "GetDistanceTo", c.obj))
        if d ~= nil and (bestD == nil or d < bestD) then best, bestD = c, d end
    end
    return best
end

local function targetsFor(unitHouse)
    local units, buildings = worldObjects()
    local me = ignoredHouse()
    local meName = me and houseName(me) or ""
    local out = { ally = {}, other = {}, allyBuild = {}, otherBuild = {} }
    local function add(list, listB, o)
        local i = objInfo(o)
        if i and i.name ~= meName and i.house ~= unitHouse then
            if CFG.PREFER_PLAYER_ALLY and isAllied(me, i.house) then
                list[#list + 1] = i
            elseif not isAllied(unitHouse, i.house) then
                listB[#listB + 1] = i
            end
        end
    end
    for _, o in ipairs(units) do add(out.ally, out.other, o) end
    for _, o in ipairs(buildings) do add(out.allyBuild, out.otherBuild, o) end
    return out
end

-- Приоритет: союзник игрока (юниты, затем здания), потом любой враг, кроме игрока.
local function pickTarget(unit, unitHouse)
    local T = targetsFor(unitHouse)
    local c = nearest(unit, T.ally)
    if c == nil then c = nearest(unit, T.other) end
    if c == nil then c = nearest(unit, T.allyBuild) end
    if c == nil then c = nearest(unit, T.otherBuild) end
    return c
end

--======================================================== перенацеливание ====

local function targetName(t)
    if t == nil then return "" end
    return houseName(ocall(t, "GetOwner"))
end

-- Возвращает true, если юнит перецелен/отправлен.
local function redirect(u, aiHouse, f, reason, oldType, oldHouse)
    local nt = pickTarget(u, aiHouse)
    local uid = tonumber(ocall(u, "GetId")) or 0
    if nt == nil then
        ocall(u, "Scatter")
        emit(string.format('{"t":"no_target","f":%d,"id":%d,"h":%s,"why":%s}',
            f, uid, jstr(houseName(aiHouse)), jstr(reason)))
        return true
    end
    ocall(u, "Attack", nt.obj)
    -- приказ повторяем каждый скан (движок может вернуть свою цель),
    -- а в лог пишем только смену цели или раз в 300 кадров
    local prev = S.lastRedir[uid]
    if prev == nil or prev.t ~= nt.id or (f - prev.f) >= 300 then
        S.lastRedir[uid] = { t = nt.id, f = f }
        emit(string.format('{"t":"redirect","f":%d,"id":%d,"type":%s,"h":%s,"why":%s,"old":%s,"oldh":%s,"new":%s,"newh":%s}',
            f, uid, jstr(ocall(u, "GetTypeName") or "?"), jstr(houseName(aiHouse)),
            jstr(reason), jstr(oldType or ""), jstr(oldHouse or ""),
            jstr(nt.type), jstr(nt.name)))
    end
    return true
end

local function handleUnits(f, meName, units, budget)
    local seenOnPlayer, redirected = 0, 0
    local byId = {}
    for _, o in ipairs(units) do
        local info = objInfo(o)
        if info ~= nil then
            byId[info.id] = info
            if info.name ~= meName and not isAllied(ignoredHouse(), info.house) then
                local t = ocall(o, "GetTarget")
                if targetName(t) == meName then
                    seenOnPlayer = seenOnPlayer + 1
                    if redirected < budget then
                        local oldType = ocall(t, "GetTypeName") or "?"
                        if redirect(o, info.house, f, "target", oldType, meName) then
                            redirected = redirected + 1
                        end
                    end
                end
            end
        end
    end
    return seenOnPlayer, redirected, byId
end

local function handleTeams(f, meName, byId, budget)
    if not CFG.HANDLE_TEAMS then return 0, 0 end
    local teams = mcall(World, "GetAITeams")
    if type(teams) ~= "table" then return 0, 0 end
    local onPlayer, redirected = 0, 0
    for _, t in ipairs(teams) do
        if tostring(t.targetHouse or "") == meName then
            onPlayer = onPlayer + 1
            local members = t.members
            if type(members) == "table" then
                for _, mid in ipairs(members) do
                    local info = byId[tonumber(mid) or -1]
                    -- члены команд союзника игрока не трогаем
                    if info ~= nil and not isAllied(ignoredHouse(), info.house)
                       and redirected < budget then
                        if redirect(info.obj, info.house, f, "team", t.teamtype, meName) then
                            redirected = redirected + 1
                        end
                    end
                end
            end
        end
    end
    return onPlayer, redirected
end

--=============================================================== тик ====

local function newMatch(f)
    S.scans, S.redirectedTotal, S.lastRedir = 0, 0, {}
    emit(string.format('{"t":"match_start","f":%d,"ts":%s}', f, jstr(os.date("%Y-%m-%dT%H:%M:%S"))))
end

function Mod.Update(frame)
    if not CFG.ENABLED then return end
    if type(frame) ~= "number" then return end
    if S.lastFrame == nil then S.lastFrame = frame end
    if frame < S.lastFrame then newMatch(frame) end
    S.lastFrame = frame

    if frame % CFG.SCAN_INTERVAL ~= 0 then return end
    S.scans = S.scans + 1

    local me = ignoredHouse()
    if me == nil then return end
    local meName = houseName(me)

    local units = mcall(World, "GetUnits")
    if type(units) ~= "table" then units = {} end

    local budget = CFG.MAX_REDIRECTS_PER_SCAN
    local onMe, moved, byId = handleUnits(frame, meName, units, budget)
    local teamsOnMe, teamMoved = handleTeams(frame, meName, byId, budget - moved)
    S.redirectedTotal = S.redirectedTotal + moved + teamMoved

    if S.scans % 20 == 0 then
        emit(string.format('{"t":"stats","f":%d,"scans":%d,"on_me":%d,"redirected":%d,"teams_on_me":%d,"team_redirected":%d,"total":%d}',
            frame, S.scans, onMe, moved, teamsOnMe, teamMoved, S.redirectedTotal))
    end
end

function Mod.OnUnload()
    if S.file then S.file:close(); S.file = nil end
end

log("AI Ignore загружен: игрока снимают с целей, ИИ идёт на его союзника")

return Mod
