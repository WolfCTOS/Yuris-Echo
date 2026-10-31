-- Точка входа мода "AI Ignore".
local ok, mod = pcall(require, "mods.AI Ignore.ignore")

if not ok then
    local src, found
    for _, rel in ipairs({ "mods/AI Ignore/ignore.lua",
                           "scripts/mods/AI Ignore/ignore.lua" }) do
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
        local chunk, err = loader(src, "@" .. found)
        if chunk then
            mod = chunk()
        else
            print("[AIIGNORE] load error: " .. tostring(err))
        end
    else
        print("[AIIGNORE] ignore.lua not found: " .. tostring(mod))
    end
end

if type(mod) ~= "table" or type(mod.Update) ~= "function" then
    print("[AIIGNORE] module did not return a Mod table with Update()")
    return { Update = function() end }
end

return mod
