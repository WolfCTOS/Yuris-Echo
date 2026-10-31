-- Точка входа мода "AI Telemetry".
-- scripts/init.lua грузит именно main.lua (require "mods.AI Telemetry.main"),
-- вся логика — рядом в telemetry.lua.
local ok, mod = pcall(require, "mods.AI Telemetry.telemetry")

if not ok then
    -- запасной путь: окружение без require с пробелом в имени папки
    local src, found
    for _, rel in ipairs({ "mods/AI Telemetry/telemetry.lua",
                           "scripts/mods/AI Telemetry/telemetry.lua" }) do
        local f = io.open(rel, "r")
        if f then
            src = f:read("*a")
            found = rel
            f:close()
            break
        end
    end
    if src then
        local loader = loadstring or load
        -- "@путь" в имени чанка, чтобы telemetry.lua вычислил свой каталог
        -- и писал лог рядом с модом, а не в CWD
        local chunk, err = loader(src, "@" .. found)
        if chunk then
            mod = chunk()
        else
            print("[AITELEM] load error: " .. tostring(err))
        end
    else
        print("[AITELEM] telemetry.lua not found: " .. tostring(mod))
    end
end

if type(mod) ~= "table" or type(mod.Update) ~= "function" then
    print("[AITELEM] module did not return a Mod table with Update()")
    return { Update = function() end }
end

return mod
