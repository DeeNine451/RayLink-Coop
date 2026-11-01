-- Every script compiled the way the engine loads it: script_storage.cpp puts two locals of its own in front of the file, and
-- Lua allows 200 in a chunk. Live 2026-11-01: coop_tasks reached 201 in a merge, "Failed to load script coop_tasks", and every
-- task check after it was fatal. The other tests load the file without that header. Run: tools\test_lua.cmd engine_header
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== every script under the engine's header")

local list = io.popen("dir /b gamedata\\scripts\\coop_*.script")
local n, biggest = 0, 0
for name in list:lines() do
	local f = assert(io.open("gamedata/scripts/" .. name, "rb"))
	local text = f:read("*a")
	f:close()
	local module_name = name:gsub("%.script$", "")
	local header = 'local function script_name() return "' .. module_name .. '" end local this = {} this._G = _G ' ..
		module_name .. " = this setfenv(1, this) "
	local fn, err = loadstring(header .. text, "@" .. name)
	n = n + 1
	check(fn ~= nil, name .. " compiles under the engine's header: " .. tostring(err))
end
list:close()
check(n > 50, "the list of scripts is not empty: " .. n)

print(string.format("%d passed, %d failed", PASSES or 0, FAILS or 0))
