-- AI Telemetry ------------------------------------------------------------
-- Телеметрия матча для LuaAPI: пишет JSONL-лог по каждому дому.
--
-- ЧТО ПИШЕТСЯ (одна JSON-строка на запись)
--   match_start   начало матча
--   snap          срез по всем домам: деньги, энергия, здания по типам,
--                 войска по типам, количество объектов
--   build / build_lost   новое/потерянное здание (по типу)
--   unit  / unit_lost    новый/потерянный юнит (по типу)
--   spawn / order / target / gone   по конкретному юниту: появился,
--                 сменил приказ, сменил цель, исчез со сканов
--   team_new / team_retarget / team_script / team_gone   ванильные ИИ-группы
--                 (World.GetAITeams): состав, владелец, цель, шаг скрипта
--   unit_snap     редкий подробный срез юнитов (id, тип, приказ, позиция)
--
-- ЧЕГО ЗДЕСЬ НЕТ: внутренних решений движка («что ИИ подумал»). LuaAPI
-- отдаёт только наблюдаемое состояние; выбор цели и планирование остаются
-- внутри gamemd.exe.
--
-- ФАЙЛ: <эта папка>/logs/match-<ГГГГММДД-ЧЧММСС>.jsonl
-- ВЫКЛЮЧИТЬ: CFG.ENABLED = false, или убрать "AI Telemetry" из
--            mods/active_mods.txt.

local Mod = {}

local CFG = {
    ENABLED = true,
    SCAN_INTERVAL = 30,        -- кадров между срезами (30 фпс = ~1 c)
    UNIT_SNAP_EVERY = 10,      -- каждый N-й срез пишем подробный unit_snap
    GONE_AFTER = 3,            -- сколько срезов юнита нет -> событие gone
    MAX_TRACKED_UNITS = 2000,  -- предохранитель от гигантских боёв
    MAX_TEAMS = 400,
    LOG_DIR = "logs",
    TAG = "[AITELEM] ",
}

local S = {
    lastFrame = nil,
    frame = 0,
    scans = 0,
    file = nil,
    filePath = nil,
    units = {},      -- id -> {t=type, m=mission, tid=target, miss=0, h=house}
    houses = {},     -- name -> {b={}, u={}}
    teams = {},      -- key -> {tgt=..., script=...}
}

local function log(msg)
    print(CFG.TAG .. tostring(msg))
end

--============================================================ утилиты ====

local function toSlash(p) return (p:gsub("\\", "/")) end

local function selfDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = toSlash(src:match("^@(.*[/\\])") or "")
    return dir
end

local MOD_DIR = selfDir()

-- вызов модуля API (House.GetCount и т.п.)
local function mcall(mod, name, ...)
    if type(mod) ~= "table" then return nil end
    local fn = mod[name]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- вызов метода объекта (unit:GetTypeName и т.п.)
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
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
        return "0"
    end
    return string.format("%d", math.floor(v))
end

local function jbool(v) return v and "true" or "false" end

-- { ["GAPOWR"]=2, ["GAPILL"]=1 } -> {"GAPOWR":2,"GAPILL":1}
local function jmap(tab)
    local keys = {}
    for k in pairs(tab) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = jstr(k) .. ":" .. jnum(tab[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

--============================================================== файл ====

local function openLog()
    if S.file then return true end
    local stamp = os.date("%Y%m%d-%H%M%S")
    local dir = MOD_DIR .. CFG.LOG_DIR .. "/"
    local path = dir .. "match-" .. stamp .. ".jsonl"

    local f = io.open(path, "a")
    if not f then
        -- каталога может не быть: создаём и пробуем ещё раз
        pcall(os.execute, 'mkdir "' .. dir .. '" >nul 2>nul')
        f = io.open(path, "a")
    end
    if not f then
        -- последний шанс: пишем рядом с модом
        path = MOD_DIR .. "match-" .. stamp .. ".jsonl"
        f = io.open(path, "a")
    end
    if not f then
        log("не удалось открыть лог-файл, телеметрия выключена")
        CFG.ENABLED = false
        return false
    end
    S.file, S.filePath = f, path
    log("лог матча: " .. path)
    return true
end

local function emit(line)
    if not CFG.ENABLED then return end
    if not openLog() then return end
    S.file:write(line, "\n")
    S.file:flush()
end

--=============================================================== скан ====

local function houseName(h)
    return ocall(h, "GetName") or "?"
end

local function allHouses()
    local out = {}
    local n = tonumber(mcall(House, "GetCount")) or 0
    for i = 0, n - 1 do
        local h = mcall(House, "GetByIndex", i)
        if h ~= nil then out[#out + 1] = { i = i, h = h } end
    end
    return out
end

local function listOf(worldName)
    local res = mcall(World, worldName)
    if type(res) == "table" then return res end
    return {}
end

local function bump(tab, key)
    if key == nil or key == "" then return end
    tab[key] = (tab[key] or 0) + 1
end

-- Считает здания и юниты по домам за один проход.
local function scanWorld()
    local per = {}   -- house -> {b={}, u={}, bc=0, uc=0}
    local function slot(name)
        local p = per[name]
        if not p then p = { b = {}, u = {}, bc = 0, uc = 0 }; per[name] = p end
        return p
    end

    for _, b in ipairs(listOf("GetBuildings")) do
        if ocall(b, "IsAlive") then
            local hn = houseName(ocall(b, "GetOwner"))
            local p = slot(hn)
            p.bc = p.bc + 1
            bump(p.b, ocall(b, "GetTypeName"))
        end
    end

    local units = listOf("GetUnits")
    for _, u in ipairs(units) do
        if ocall(u, "IsAlive") then
            local hn = houseName(ocall(u, "GetOwner"))
            local p = slot(hn)
            p.uc = p.uc + 1
            bump(p.u, ocall(u, "GetTypeName"))
        end
    end
    return per, units
end

local function houseLine(hid, name, h, p)
    return string.format(
        '{"i":%d,"n":%s,"human":%s,"ai":%s,"cr":%s,"po":%s,"pd":%s,"bc":%s,"uc":%s,"b":%s,"u":%s}',
        hid, jstr(name), jbool(ocall(h, "IsHuman")),
        jstr(ocall(h, "GetAIDifficulty") or ""),
        jnum(ocall(h, "GetCredits")), jnum(ocall(h, "GetPowerOutput")),
        jnum(ocall(h, "GetPowerDrain")), jnum(p.bc), jnum(p.uc),
        jmap(p.b), jmap(p.u))
end

-- Сравнение с прошлым срезом -> события build/build_lost/unit/unit_lost
local function diffCounts(name, cur, f)
    local prev = S.houses[name] or { b = {}, u = {} }
    local kinds = { { "b", "build", "build_lost" }, { "u", "unit", "unit_lost" } }
    for _, k in ipairs(kinds) do
        local key, addEv, delEv = k[1], k[2], k[3]
        local before, after = prev[key] or {}, cur[key] or {}
        local names = {}
        for t in pairs(before) do names[t] = true end
        for t in pairs(after) do names[t] = true end
        for t in pairs(names) do
            local a, b = before[t] or 0, after[t] or 0
            if b > a then
                emit(string.format('{"t":"%s","f":%d,"h":%s,"type":%s,"n":%d}',
                    addEv, f, jstr(name), jstr(t), b))
            elseif b < a then
                emit(string.format('{"t":"%s","f":%d,"h":%s,"type":%s,"n":%d}',
                    delEv, f, jstr(name), jstr(t), b))
            end
        end
    end
    S.houses[name] = { b = cur.b, u = cur.u }
end

local function targetInfo(u)
    local t = ocall(u, "GetTarget")
    if t == nil then return nil, nil, nil end
    local tid = tonumber(ocall(t, "GetId"))
    if tid == nil then return nil, nil, nil end
    return tid, ocall(t, "GetTypeName"), houseName(ocall(t, "GetOwner"))
end

local function posStr(u)
    local p = ocall(u, "GetPosition")
    if type(p) ~= "table" then return "0,0" end
    return string.format("%d,%d", math.floor(tonumber(p.x) or 0), math.floor(tonumber(p.y) or 0))
end

--============================================================== юниты ====

local function trackUnits(units, f)
    local seen = {}
    local tracked = 0
    for _, u in ipairs(units) do
        if tracked < CFG.MAX_TRACKED_UNITS then
            local id = tonumber(ocall(u, "GetId"))
            if id ~= nil and ocall(u, "IsAlive") then
                tracked = tracked + 1
                seen[id] = true
                local tn = ocall(u, "GetTypeName") or "?"
                local hn = houseName(ocall(u, "GetOwner"))
                local m = tonumber(ocall(u, "GetMission"))
                local tid, ttype, thouse = targetInfo(u)
                local rec = S.units[id]
                if rec == nil then
                    S.units[id] = { t = tn, m = m, tid = tid, h = hn, miss = 0 }
                    emit(string.format('{"t":"spawn","f":%d,"h":%s,"id":%d,"type":%s,"m":%s,"pos":%s}',
                        f, jstr(hn), id, jstr(tn), m and jnum(m) or "null", jstr(posStr(u))))
                else
                    rec.miss = 0
                    if m ~= nil and rec.m ~= m then
                        emit(string.format('{"t":"order","f":%d,"h":%s,"id":%d,"type":%s,"m":%d,"m0":%s,"pos":%s,"tid":%s,"ttype":%s}',
                            f, jstr(hn), id, jstr(tn), m, rec.m and jnum(rec.m) or "null",
                            jstr(posStr(u)), tid and jnum(tid) or "null", ttype and jstr(ttype) or "null"))
                        rec.m = m
                        rec.tid = tid
                    elseif tid ~= nil and tid ~= rec.tid then
                        emit(string.format('{"t":"target","f":%d,"h":%s,"id":%d,"type":%s,"tid":%d,"ttype":%s,"th":%s,"pos":%s}',
                            f, jstr(hn), id, jstr(tn), tid, jstr(ttype or ""), jstr(thouse or ""),
                            jstr(posStr(u))))
                        rec.tid = tid
                    else
                        rec.tid = tid
                    end
                end
            end
        end
    end

    local gone = {}
    for id, rec in pairs(S.units) do
        if not seen[id] then
            rec.miss = rec.miss + 1
            if rec.miss >= CFG.GONE_AFTER then
                gone[#gone + 1] = id
                emit(string.format('{"t":"gone","f":%d,"h":%s,"id":%d,"type":%s}',
                    f, jstr(rec.h or ""), id, jstr(rec.t or "")))
            end
        end
    end
    for _, id in ipairs(gone) do S.units[id] = nil end
end

local function unitSnapshot(units, f)
    local parts = {}
    for _, u in ipairs(units) do
        if #parts < CFG.MAX_TRACKED_UNITS and ocall(u, "IsAlive") then
            local id = tonumber(ocall(u, "GetId"))
            if id ~= nil then
                parts[#parts + 1] = string.format('{"id":%d,"type":%s,"h":%s,"m":%s,"pos":%s,"hp":%s}',
                    id, jstr(ocall(u, "GetTypeName") or "?"),
                    jstr(houseName(ocall(u, "GetOwner"))),
                    ocall(u, "GetMission") and jnum(ocall(u, "GetMission")) or "null",
                    jstr(posStr(u)), jnum(ocall(u, "GetHealth")))
            end
        end
    end
    emit(string.format('{"t":"unit_snap","f":%d,"u":[%s]}', f, table.concat(parts, ",")))
end

--=============================================================== группы ====

local function trackTeams(f)
    local teams = mcall(World, "GetAITeams")
    if type(teams) ~= "table" then return end
    local cur = {}
    local n = 0
    for _, t in ipairs(teams) do
        if n < CFG.MAX_TEAMS then
            n = n + 1
            local team = tostring(t.teamtype or "?")
            local own = tostring(t.owner or "?")
            local key = team .. "|" .. own .. "|" .. tostring(t.creationFrame or 0)
            local tgt = t.targetHouse and tostring(t.targetHouse) or ""
            local script = tonumber(t.scriptMission) or -1
            cur[key] = true
            local prev = S.teams[key]
            if prev == nil then
                local members = 0
                if type(t.members) == "table" then members = #t.members end
                S.teams[key] = { tgt = tgt, script = script }
                emit(string.format('{"t":"team_new","f":%d,"team":%s,"own":%s,"tgt":%s,"script":%d,"members":%d,"total":%s,"full":%s,"frames":%s}',
                    f, jstr(team), jstr(own), jstr(tgt), script, members,
                    jnum(t.totalObjects or 0), jbool(t.isFullStrength == true),
                    jnum(t.creationFrame or 0)))
            else
                if prev.tgt ~= tgt then
                    prev.tgt = tgt
                    emit(string.format('{"t":"team_retarget","f":%d,"team":%s,"own":%s,"tgt":%s}',
                        f, jstr(team), jstr(own), jstr(tgt)))
                end
                if prev.script ~= script then
                    prev.script = script
                    emit(string.format('{"t":"team_script","f":%d,"team":%s,"own":%s,"script":%d}',
                        f, jstr(team), jstr(own), script))
                end
            end
        end
    end
    for key, _ in pairs(S.teams) do
        if not cur[key] then
            S.teams[key] = nil
            emit(string.format('{"t":"team_gone","f":%d,"key":%s}', f, jstr(key)))
        end
    end
end

--=============================================================== тик ====

local function newMatch(f)
    if S.file then S.file:close() end
    S.file, S.filePath = nil, nil
    S.scans, S.units, S.houses, S.teams = 0, {}, {}, {}
    emit(string.format('{"t":"match_start","f":%d,"ts":%s}', f, jstr(os.date("%Y-%m-%dT%H:%M:%S"))))
    log("новый матч, начинаем лог")
end

function Mod.Update(frame)
    if not CFG.ENABLED then return end
    if type(frame) ~= "number" then return end
    if S.lastFrame == nil then S.lastFrame = frame end
    if frame < S.lastFrame then newMatch(frame) end
    S.lastFrame = frame
    S.frame = frame

    if frame % CFG.SCAN_INTERVAL ~= 0 then return end
    S.scans = S.scans + 1

    local houses = allHouses()
    local per, units = scanWorld()

    local lines = {}
    for _, H in ipairs(houses) do
        local name = houseName(H.h)
        local p = per[name]
        if p == nil then p = { b = {}, u = {}, bc = 0, uc = 0 } end
        -- служебные дома (Neutral/Civilian) без юнитов и денег не нужны
        if not (p.bc == 0 and p.uc == 0 and (tonumber(ocall(H.h, "GetCredits")) or 0) == 0) then
            lines[#lines + 1] = houseLine(H.i, name, H.h, p)
            diffCounts(name, p, frame)
        end
    end
    emit(string.format('{"t":"snap","f":%d,"n":%d,"h":[%s]}',
        frame, #houses, table.concat(lines, ",")))

    trackUnits(units, frame)
    trackTeams(frame)

    if S.scans % CFG.UNIT_SNAP_EVERY == 0 then
        unitSnapshot(units, frame)
    end
end

function Mod.OnUnload()
    if S.file then S.file:close(); S.file = nil end
end

log("телеметрия загружена (лог в " .. MOD_DIR .. CFG.LOG_DIR .. "/)")

return Mod
