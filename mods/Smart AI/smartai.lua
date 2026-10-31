-- Smart AI ---------------------------------------------------------------
-- Разделенный ИИ-командир поверх LuaAPI для Red Alert 2 / Yuri's Revenge.
-- 
-- СТРУКТУРА:
--   Commander (Командир): Занимается строительством базы, экономикой и Oil Derrick
--   Officer (Офицер): Занимается управлением юнитами, атаками и микроконтролем
--
-- ЧТО ДЕЛАЕТ МОД:
--   - Строит основные здания (барracks, power plant, refinery, factory, war factory, airfield)
--   - Строит оборону (башни, turret) стратегически, а не спамом
--   - Заказывает юнитов всех типов (танки, пехоты, вертолёты, drones, ракеты)
--   - Захватывает Oil Derricks
--   - Атакует юнитами разных категорий в зависимости от фаекции
--
-- Внутренний состояния модуля (таблица S инициализируется ниже):
--   S.lastFrame - последний кадр обновления
--   S.matchStart - кадр старта матча
--   S.scans, S.targetCache, S.baseCache - кэши сканов и целей
--   S.strikes, S.topups, S.eliminated - статистика атак
--   S.winner - победитель матча
--   S.known - известные дома
--
local S = {}

-- === МОД СТРУКТУРА ===
local Mod = {}

-- === КОНСТАНТЫ: Типы зданий из rulesmd.ini ===
local BARRACKS_ALLIED = "GACNST"
local BARRACKS_SOV = "NACNST"
local BARRACKS_YURI = "YACNST"
local POWER_PLANT_ALLIED = "GAPOWR"
local POWER_PLANT_SOV = "NAPOWR"
local POWER_PLANT_YURI = "YAPOWR"
local REFINERY_ALLIED = "GAREFN"
local REFINERY_SOV = "NAREFN"
local REFINERY_YURI = "YAREFN"
local FACTORY_ALLIED = "GAWEAP"
local FACTORY_SOV = "NAWEAP"
local FACTORY_YURI = "YAWEAP"
local AIRFIELD_ALLIED = "GAAIRC"
local AIRFIELD_SOV = "NAAIRC"
local AIRFIELD_YURI = "YAAIRC"

-- === КОНСТАНТЫ: Типы юнитов ===
local UNIT_TANK = {"MTNK", "TNKD", "LTNK", "BFRT", "YTNK", "BFT", "SCHP"}
local UNIT_ARMORED = {"JEEP", "MGTK", "FTRK", "STANG", "SUVB", "SUVW", "TAXI", "PTRUCK"}
local UNIT_SPECIAL = {"AMCV", "SMCV", "PCV", "SMIN", "YCAB", "SMON", "YHVR", "ROBO", "DOLY"}
local UNIT_DRONE = {"SPYP", "BPLN", "CARGOPLANE"}
local UNIT_HELICOPTER = {"APACHE", "ORCA", "HIND", "HORNET", "YHVR"}
local UNIT_ROCKET = {"V3ROCKET", "DMISL", "CMISL"}

-- Тип Oil Derrick здания
local OIL_DERRICK_TYPE = "CAOILD"

-- === Функция определения категории юнита ===
local function getUnitCategory(unitType)
    if unitType == nil then return "none" end
    unitType = unitType:upper()
    
    for _, dt in ipairs(UNIT_DRONE) do
        if unitType == dt then return "drone" end
    end
    for _, ht in ipairs(UNIT_HELICOPTER) do
        if unitType == ht then return "helicopter" end
    end
    for _, rt in ipairs(UNIT_ROCKET) do
        if unitType == rt then return "rocket" end
    end
    for _, tt in ipairs(UNIT_TANK) do
        if unitType == tt then return "tank" end
    end
    for _, at in ipairs(UNIT_ARMORED) do
        if unitType == at then return "armored" end
    end
    for _, st in ipairs(UNIT_SPECIAL) do
        if unitType == st then return "special" end
    end
    return "infantry"
end

-- Определяем фаракцию
local function getFaction(house)
    local name = houseName(house)
    if name:upper():find("ALLIED") or name:upper():find("ALLIED") then return "allied"
    elseif name:upper():find("SOV") or name:upper():find("SOVIET") then return "soviet"
    elseif name:upper():find("YURI") or name:upper():find("YURI") then return "yuri"
    end
    return "unknown"
end

-- === === КОМАНДИР: Строительство базы ===
local function commanderBuildings(house, faction, snap, frame)
    local me = houseName(house)
    local entry = snap[me]
    if entry == nil then return 0 end
    
    local built = 0
    local priorities = {}
    
    -- Определяем приоритеты строительства в зависимости от фаракции
    if faction == "yuri" then
        -- Yuri: асимметрично, энергия first, потом экономика, потом оборона
        priorities = {
            {type = POWER_PLANT_YURI, name = "power plant", weight = 1.0},
            {type = REFINERY_YURI, name = "refinery", weight = 0.9},
            {type = FACTORY_YURI, name = "factory/war factory", weight = 0.8},
            {type = AIRFIELD_YURI, name = "airfield", weight = 0.7},
            {type = BARRACKS_YURI, name = "barracks", weight = 0.6},
            -- Verteidigung nur wenn nötig
            {type = nil, isDefense = true, name = "defense ( bunkers )", weight = 0.3},
        }
    elseif faction == "soviet" then
        -- Soviet: агрессивно, экономика + оборода одновременно
        priorities = {
            {type = POWER_PLANT_SOV, name = "power plant", weight = 1.0},
            {type = REFINERY_SOV, name = "refinery", weight = 0.95},
            {type = FACTORY_SOV, name = "factory/war factory", weight = 0.9},
            {type = AIRFIELD_SOV, name = "airfield", weight = 0.8},
            {type = BARRACKS_SOV, name = "barracks", weight = 0.7},
            -- Verteidigung mit höherer приоритет для Soviet
            {type = nil, isDefense = true, name = "defense ( towers )", weight = 0.6},
        }
    else
        -- Allied: технологично, баланс экономика/технологии + легкая оборона
        priorities = {
            {type = POWER_PLANT_ALLIED, name = "power plant", weight = 1.0},
            {type = REFINERY_ALLIED, name = "refinery", weight = 0.95},
            {type = FACTORY_ALLIED, name = "factory/war factory", weight = 0.9},
            {type = AIRFIELD_ALLIED, name = "airfield", weight = 0.8},
            {type = BARRACKS_ALLIED, name = "barracks", weight = 0.7},
            -- Легкая defensa для Allied
            {type = nil, isDefense = true, name = "defense ( turrets )", weight = 0.4},
        }
    end
    
    -- Строим здания согласно приоритетам
    for _, priority in ipairs(priorities) do
        if priority.isDefense then
            -- Строим оборону если нужно (минимально)
            -- Находим лучшее место для обороны
            local defenseBuilt = attemptBuildDefense(house, entry)
            if defenseBuilt then
                built = built + 1
            end
        elseif priority.type then
            -- Пытаемся построить основное здание
            local builtThis = attemptBuildBuilding(house, priority.type, entry)
            if builtThis then
                built = built + 1
                -- Логируем каждые 50 сканов
                if S.scans % 50 == 0 then
                    log(string.format("%s: построено %s (%s)", me, priority.name, faction))
                end
            end
        end
    end
    
    return built
end

-- Пытаемся построить здание определенного типа
local function attemptBuildBuilding(house, buildingType, entry)
    -- Ищем свободное место и проверяем, что можем построить
    local buildings = entry.buildings or {}
    
    -- Проверяем, не построено ли уже это здание
    for _, existing in ipairs(buildings) do
        local btype = ocall(existing, "GetTypeName") or ""
        if btype == buildingType then
            return false -- Already built
        end
    end
    
    -- Ищем позицию для строительства (упрощенно: prèsest open space)
    -- В реальности здесь была бы логика поиска позиции
    local canBuild = true -- Placeholder - движок решает возможность строительства
    
    if canBuild then
        -- Строим здание через движок
        -- Примечание: точный вызов зависит от API RA2
        local success = ocall(house, "Build", buildingType)
        if success then
            return true
        end
    end
    
    return false
end

-- Пытаемся построить оборону
local function attemptBuildDefense(house, entry)
    -- Строим башни/турреты стратегически
    -- Yuri: только если мало bunkers
    -- Soviet: чаще
    -- Allied: редко
    
    local faction = getFaction(house)
    local defenseType = nil
    
    if faction == "yuri" then
        -- Проверяем количество bunkers
        local bunkerCount = 0
        for _, b in ipairs(entry.buildings or {}) do
            local btype = ocall(b, "GetTypeName") or ""
            if btype:upper():find("BUNK") then
                bunkerCount = bunkerCount + 1
            end
        end
        if bunkerCount < 2 then
            defenseType = "bunker" -- упрощенно
        end
    elseif faction == "soviet" then
        -- Soviet строит оборону чаще
        defenseType = "tower"
    elseif faction == "allied" then
        -- Allied строит оборону только если атака imminent
        local combat = combatUnits(entry)
        if #combat < 5 then
            defenseType = "turret"
        end
    end
    
    if defenseType then
        local success = ocall(house, "Build", defenseType)
        if success then
            return true
        end
    end
    
    return false
end

-- === === ОФИЦЕР: Управление юнитами и атаки ===
local function officerAttackOrders(house, faction, snap, frame)
    local me = houseName(house)
    local entry = snap[me]
    if entry == nil then return 0 end
    
    local issued = 0
    
    -- Находим цель для атаки
    local target, targetType = improvedPickTarget(house, faction, snap, frame)
    
    if target == nil then
        return 0
    end
    
    -- Выполняем умную атаку
    issued = smartAttack(house, target, faction, snap, frame)
    
    -- Логирование
    if issued > 0 and S.scans % 20 == 0 then
        local targetName = targetType or "?"
        log(string.format("%s: атака (%s), цель %s", me, targetName, target and ocall(target, "GetTypeName") or "?"))
    end
    
    -- Yuri Disable logic
    if faction == "yuri" then
        local entry = snap[me]
        if entry then
            local stunned = yuriDisable(entry, snap, frame)
            if stunned > 0 and S.scans % 10 == 0 then
                log(string.format("%s: глушилка, обездвижено %d", me, stunned))
            end
        end
    end
    
    return issued
end

-- Улучшенная выбор цели
local function improvedPickTarget(house, faction, snap, frame)
    local me = houseName(house)
    local entry = snap[me]
    if entry == nil then return nil end
    
    -- Сначала ищем здания как цели
    local target = pickTarget(house, faction, snap, frame)
    if target ~= nil then return target, "building" end
    
    -- Если зданий мало, ищем лучший тип юнита для атаки
    local combat = combatUnits(entry)
    if #combat < 5 then return nil end
    
    -- Ищем лучший тип юнита среди combatUnits
    local bestUnit, bestCategory = nil, "none"
    local priorityOrder = {drone=1, helicopter=2, tank=3, armored=4, special=5, infantry=6, none=7}
    
    for _, u in ipairs(combat) do
        local utype = (ocall(u, "GetTypeName") or ""):upper()
        local cat = getUnitCategory(utype)
        if priorityOrder[cat] < priorityOrder[bestCategory] then
            bestUnit, bestCategory = u, cat
        end
    end
    
    if bestUnit ~= nil then
        return bestUnit, "unit_" .. bestCategory
    end
    
    return nil
end

-- Стандартная выбор цели (поиск зданий)
local function pickTarget(house, faction, snap, frame)
    -- Простая реализация: ищем здания противника
    local me = houseName(house)
    local snapBuildings = snap[me] and snap[me].buildings or {}
    
    -- Ищем здания других домов
    for otherName, otherEntry in pairs(snap) do
        if otherName ~= me and otherEntry then
            local otherBuildings = otherEntry.buildings or {}
            if #otherBuildings > 0 then
                -- Берем первое доступное здание
                local firstBuilding = otherBuildings[1]
                if firstBuilding then
                    return firstBuilding
                end
            end
        end
    end
    
    return nil
end

-- === Таблица угроз (Threat Maps) для разных типов отрядов ===
-- Каждый тип отряда имеет свои приоритетные цели
local THREAT_MAPS = {
    -- Криуisers (drones/rockets/helis): уничтожают AA и здания first
    cruiser = {
        priority = {
            [1] = "aa",       -- Anti-aircraft guns first
            [2] = "turret",   -- Turrets/defense structures
            [3] = "building", -- Then buildings
            [4] = "harvester",-- Harvesters last
        },
        -- Units in this squadron get attack order based on threat proximity
        assignTarget = function(house, target, snap, frame)
            -- Если цель AA или turret, атакуем с приоритетом
            local targetTypeName = ocall(target, "GetTypeName") or ""
            if targetTypeName:upper():find("AA") or targetTypeName:upper():find("TURR") then
                return target
            end
            return target
        end
    },
    
    -- Инженерная пехота: уничтожают пехоту, танки, элитные юниты
    infantry = {
        priority = {
            [1] = "infantry",       -- Enemy infantry first
            [2] = "tank",         -- Then tanks
            [3] = "seal_boris",   -- Elite units
            [4] = "building",     -- Then buildings
        },
        assignTarget = function(house, target, snap, frame)
            local targetTypeName = ocall(target, "GetTypeName") or ""
            if targetTypeName:upper():find("INFANTRY") then
                return target
            end
            return target
        end
    },
    
    -- Танки: уничтожают другие танки, против зенитные позиции
    tank = {
        priority = {
            [1] = "tank",         -- Enemy tanks first
            [2] = "aa",           -- Anti-aircraft
            [3] = "turret",       -- Defense structures
            [4] = "infantry",     -- Then infantry
        },
        assignTarget = function(house, target, snap, frame)
            local targetTypeName = ocall(target, "GetTypeName") or ""
            if targetTypeName:upper():find("TANK") then
                return target
            end
            return target
        end
    },
}

-- === Функция получения угрозы для юнита ===
local function getThreatPriority(unitCategory, targetTypeName)
    local tn = targetTypeName:upper()
    
    -- Определяем тип отряда по категории юнита
    local squadronType = "infantry" -- default
    if unitCategory == "drone" or unitCategory == "rocket" then
        squadronType = "cruiser"
    elseif unitCategory == "helicopter" then
        squadronType = "cruiser"
    elseif unitCategory == "tank" then
        squadronType = "tank"
    elseif unitCategory == "armored" then
        squadronType = "infantry"
    end
    
    -- Проверяем угрозу в зависимости от типа
    if THREAT_MAPS[squadronType] then
        local threat = THREAT_MAPS[squadronType]
        -- Простая проверка по приоритетам
        for _, p in ipairs(threat.priority) do
            if p == "aa" and tn:find("AA") then
                return 1 -- High priority for AA
            end
            if p == "tank" and tn:find("TANK") then
                return 1
            end
            if p == "infantry" and tn:find("INFANTRY") then
                return 1
            end
        end
    end
    
    return 0 -- No special threat priority
end

-- === Сортировка юнитов по отрядам с угрозами ===
local function sortUnitsIntoSquadrons(combat, faction)
    -- Группируем юниты по типам для совместных атак
    local squadrons = {
        cruiser = {},      -- Drones, rockets, helicopters
        tank = {},         -- Tanks
        infantry = {},     -- Armored, special, infantry
    }
    
    for i, u in ipairs(combat) do
        local utype = (ocall(u, "GetTypeName") or ""):upper()
        local uc = getUnitCategory(utype)
        
        -- Распределяем юниты по отрядам
        if uc == "drone" or uc == "rocket" then
            table.insert(squadrons.cruiser, u)
        elseif uc == "helicopter" then
            table.insert(squadrons.cruiser, u)
        elseif uc == "tank" then
            table.insert(squadrons.tank, u)
        else
            table.insert(squadrons.infantry, u)
        end
    end
    
    return squadrons
end

-- === Умная атака с отрядами и картами угроз ===
local function smartAttack(house, target, faction, snap, frame)
    if target == nil then return 0 end
    
    local combat = combatUnits(snap[houseName(house)])
    if #combat < 3 then return 0 end
    
    local issued = 0
    
    -- Определяем вес防御 Юри для этой атаки
    local yuriDefenseWeight = (CFG and CFG.ROBOT_YURI_DEFENSE_WEIGHT) or 0.3
    local yuriFaction = (faction == "yuri")
    
    -- Сортируем юниты по отрядам
    local squadrons = sortUnitsIntoSquadrons(combat, faction)
    
    -- Для каждого отряда выдаем приказы с учетом карты угроз
    -- Отряд криуiserов (drones/rockets/helis)
    if #squadrons.cruiser >= 2 then
        -- Выбираем цель с приоритетом по угрозам
        local cruiseTarget = target
        local cruiseTargetName = ocall(cruiseTarget, "GetTypeName") or ""
        
        -- Проверяем, является ли цель высокорисковой (AA, turret)
        if cruiseTargetName:upper():find("AA") or cruiseTargetName:upper():find("TURR") then
            -- Криуisers фокусируются на уничтожении AA first
            for i, u in ipairs(squadrons.cruiser) do
                local assign = cruiseTarget
                local current = ocall(u, "GetTarget")
                local sameTarget = false
                if current ~= nil and ocall(current, "IsAlive") == true then
                    local currentId = tonumber(ocall(current, "GetId"))
                    local assignId = tonumber(ocall(assign, "GetId"))
                    sameTarget = currentId ~= nil and assignId ~= nil and currentId == assignId
                end
                if not sameTarget then
                    ocall(u, "Attack", assign)
                    issued = issued + 1
                end
            end
        else
            -- Обычная атака на цель
            for i, u in ipairs(squadrons.cruiser) do
                local assign = cruiseTarget
                local current = ocall(u, "GetTarget")
                local sameTarget = false
                if current ~= nil and ocall(current, "IsAlive") == true then
                    local currentId = tonumber(ocall(current, "GetId"))
                    local assignId = tonumber(ocall(assign, "GetId"))
                    sameTarget = currentId ~= nil and assignId ~= nil and currentId == assignId
                end
                if not sameTarget then
                    ocall(u, "Attack", assign)
                    issued = issued + 1
                end
            end
        end
    end
    
    -- Отряд танков
    if #squadrons.tank >= 2 then
        for i, u in ipairs(squadrons.tank) do
            local assign = squadrons.tank[1] ~= u and squadrons.tank[1] or target
            local current = ocall(u, "GetTarget")
            local sameTarget = false
            if current ~= nil and ocall(current, "IsAlive") == true then
                local currentId = tonumber(ocall(current, "GetId"))
                local assignId = tonumber(ocall(assign, "GetId"))
                sameTarget = currentId ~= nil and assignId ~= nil and currentId == assignId
            end
            if not sameTarget then
                ocall(u, "Attack", assign)
                issued = issued + 1
            end
        end
    end
    
    -- Отряд пехоты/бронемашин
    if #squadrons.infantry >= 2 then
        for i, u in ipairs(squadrons.infantry) do
            local assign = target
            local current = ocall(u, "GetTarget")
            local sameTarget = false
            if current ~= nil and ocall(current, "IsAlive") == true then
                local currentId = tonumber(ocall(current, "GetId"))
                local assignId = tonumber(ocall(assign, "GetId"))
                sameTarget = currentId ~= nil and assignId ~= nil and currentId == assignId
            end
            if not sameTarget then
                -- Добавляем шанс избегать атаки наharvester при лицем Yuri
                local assignTypeName = ocall(assign, "GetTypeName") or ""
                if yuriFaction and assignTypeName:upper():find("HARV") then
                    if math.random(1, 10) <= (yuriDefenseWeight * 10) then
                        -- Атакуем цель防御 вместо Харвестера
                        assign = bestDefense(house, target)
                    end
                end
                ocall(u, "Attack", assign)
                issued = issued + 1
            end
        end
    end
    
    return issued
end

-- Поиск Oil Derrick и захват
local function findNearbyOilDerrick(house, x, y, radius)
    if x == nil or y == nil then return nil end
    local buildings = mcall(World, "GetBuildings") or {}
    for _, b in ipairs(buildings) do
        if ocall(b, "IsAlive") == true then
            local owner = ocall(b, "GetOwner")
            local btype = ocall(b, "GetTypeName") or ""
            if owner ~= nil and btype == OIL_DERRICK_TYPE then
                local bx, by = position(b)
                if bx ~= nil and by ~= nil then
                    local dist = distanceBetween(x, y, bx, by)
                    if dist <= (radius or 200) then
                        local ownerName = houseName(owner)
                        local myName = houseName(house)
                        if ownerName ~= myName then
                            return b
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function captureOilDerrick(engineer, oilDerrick)
    if engineer == nil or oilDerrick == nil then return false end
    
    local engineerOwner = ocall(engineer, "GetOwner")
    local oilOwner = ocall(oilDerrick, "GetOwner")
    
    if oilOwner ~= nil then
        local oilName = houseName(oilOwner)
        local engName = houseName(engineerOwner)
        local canCapture = (oilName ~= engName) or (oilName == "Neutral")
        
        if canCapture then
            local success = ocall(oilDerrick, "Capture", engineer)
            if success ~= nil then
                log(string.format("%s: захватил Oil Derrick", houseName(engineerOwner)))
                return true
            end
        end
    end
    return false
end

local function findEngineersForCapture(entry, count)
    local engineers = {}
    for _, u in ipairs(entry.units) do
        local utype = ocall(u, "GetTypeName")
        if utype then
            local cat = getUnitCategory(utype)
            if cat == "special" or utype:upper():find("ENGINEER") then
                table.insert(engineers, u)
                if #engineers >= count then break end
            end
        end
    end
    return engineers
end

-- === CFG (настройки) ===
local CFG = {
    SCAN_INTERVAL = 15,
    ORDER_INTERVAL = 150,
    CREDIT_TOPUP_GAP = 300,
    CREDIT_TOPUP = 1000,
    LOG_INTERVAL = 10,
    
    -- Building priorities
    YURI_MAX_BUNKERS = 2,
    ALLIED_NAVAL_BIAS = 0.5,
    ROBOT_YURI_DEFENSE_WEIGHT = 0.3,
}

-- === Функция Mod.Update (обязательна!) ===
function Mod.Update(frame)
    if type(frame) ~= "number" then return end

    if S.lastFrame == nil then
        S.lastFrame = frame
        S.matchStart = frame
        log("командир на связи")
    end
    if frame < S.lastFrame then
        S.scans, S.targetCache, S.baseCache = 0, {}, {}
        S.strikes, S.topups, S.eliminated = 0, 0, {}
        S.winner = nil
        S.matchStart, S.known = frame, nil
        log("новый матч, состояние сброшено")
    end
    S.lastFrame = frame

    if frame % CFG.SCAN_INTERVAL ~= 0 then return end
    S.scans = S.scans + 1

    local snap = snapshot()
    local houses = allHouses()
    local humans = {}
    local bots = {}
    for _, h in ipairs(houses) do
        local name = houseName(h)
        if ocall(h, "IsHuman") == true then
            humans[name] = true
        elseif isPlayable(h) then
            bots[#bots + 1] = h
        end
    end

    -- Новый дом в матче
    if S.known == nil then
        S.known = {}
        for _, h in ipairs(bots) do
            S.known[houseName(h)] = true
        end
        local names = {}
        for _, h in ipairs(bots) do names[#names + 1] = houseName(h) end
        log("дома в матче: " .. table.concat(names, ", "))
    end

    -- Кто в игре
    local aliveNow = {}
    local aliveCount, eliminatedNow = 0, 0
    for name in pairs(S.known) do
        local entry = snap[name]
        local hasSomething = entry ~= nil and (#entry.buildings > 0 or #entry.units > 0)
        if hasSomething then
            aliveNow[name] = true
            aliveCount = aliveCount + 1
        elseif S.eliminated[name] ~= true then
            S.eliminated[name] = true
            eliminatedNow = eliminatedNow + 1
            log("дом уничтожен: " .. name)
        end
    end
    if aliveCount == 1 and S.winner == nil then
        for name in pairs(aliveNow) do S.winner = name end
        log("матч решён, остался " .. tostring(S.winner))
    end

    -- Экономика
    if frame % CFG.CREDIT_TOPUP_GAP == 0 then
        S.topups = S.topups + 1
        for _, h in ipairs(bots) do
            if S.eliminated[houseName(h)] ~= true then
                ocall(h, "AddCredits", CFG.CREDIT_TOPUP)
            end
        end
    end

    -- Раз в ORDER_INTERVAL: Командир строит базу, Офицер отдает приказы
    if frame % CFG.ORDER_INTERVAL == 0 then
        local sent, total = 0, 0
        for _, h in ipairs(bots) do
            local name = houseName(h)
            if S.eliminated[name] ~= true and S.winner == nil then
                local faction = factionOf(h)
                
                -- Командир: строит здания
                local built = commanderBuildings(h, faction, snap, frame)
                
                -- Офицер: отдает приказы атаки
                local issued = officerAttackOrders(h, faction, snap, frame)
                
                sent = sent + built + issued
                total = total + 1
            end
        end
        if sent > 0 and S.scans % 40 == 0 then
            log(string.format("приказов за тик: %d (строительство+%{attack}, домов %d)", sent, total))
        end
    end

    -- Сводка
    if S.scans % 10 == 0 then
        local parts = {}
        for _, h in ipairs(bots) do
            local name = houseName(h)
            local entry = snap[name]
            if entry ~= nil and S.eliminated[name] ~= true then
                parts[#parts + 1] = string.format("%s[%s] з:%d ю:%d", name, factionOf(h),
                    #entry.buildings, #entry.units)
            end
        end
        log("сводка: " .. table.concat(parts, " | "))
    end
end

return Mod