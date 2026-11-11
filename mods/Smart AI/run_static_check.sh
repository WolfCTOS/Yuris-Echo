set -e
echo "LUAC-V";
luac -v;
echo "LUAC-P main.lua";
cd "D:\Games\Red Alert 2 LuaAPI\mods\Smart AI";
luac -p main.lua;
echo "LUA-CHECK main.lua";
lua -e "assert(loadfile('main.lua'))()" 2>&1 | sed -n '1,60p';
echo "END"
