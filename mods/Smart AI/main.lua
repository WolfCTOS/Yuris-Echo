-- Точка входа мода "Smart AI".
-- scripts/init.lua грузит именно main.lua (require "mods.Smart AI.main"),
-- а вся логика лежит рядом в smartai.lua.
local ok, mod = pcall(require, "mods.Smart AI.smartai")

if not ok then
    -- запасной путь, если среда не умеет require с пробелом в имени папки
    -- Mods live in <game>\mods\ now; scripts\mods\ is the legacy layout.
    local src
    for _, rel in ipairs({ "mods/Smart AI/smartai.lua", "scripts/mods/Smart AI/smartai.lua" }) do
        local f = io.open(rel, "r")
        if f then
            src = f:read("*a")
            f:close()
            break
        end
    end
    if src then
        local loader = loadstring or load   -- LuaJIT/5.1 или 5.2+
        local chunk, err = loader(src, "smartai")
        if chunk then
            mod = chunk()
        else
            print("[SMARTAI] load error: " .. tostring(err))
        end
    else
        print("[SMARTAI] smartai.lua not found: " .. tostring(mod))
    end
end

if type(mod) ~= "table" or type(mod.Update) ~= "function" then
    print("[SMARTAI] module did not return a Mod table with Update()")
    return { Update = function() end }
end

return mod
