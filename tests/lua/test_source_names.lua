-- The Windows headers define `near` and `far` to nothing. A name of a variable or a parameter disappears without a word: `bool near`
-- compiles with no name, and `{x, near}` as `{x, }`. Live 2026-11-01: lead_vote always said "do not ask", a map server's level stayed
-- without NPCs, and the C++ tests, built without those headers, passed. Run: tools\\test_lua.cmd source_names
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== no near, no far among the names of the co-op code")

local BS = string.char(92)
local bad, files = 0, 0
for _, folder in ipairs({ "engine" .. BS .. "src" .. BS .. "xrCoop", "engine" .. BS .. "src" .. BS .. "xrGame" .. BS .. "coop" }) do
	local list = io.popen("dir /b " .. folder .. BS .. "*.h " .. folder .. BS .. "*.cpp 2>nul")
	for name in list:lines() do
		name = name:gsub("\r", "")
		local path = folder:gsub(BS .. BS, "/") .. "/" .. name
		local f = assert(io.open(path, "rb"))
		files = files + 1
		local n = 0
		for line in f:lines() do
			n = n + 1
			local code = line:gsub('"[^"]*"', '""'):gsub("//.*$", "")
			if code:find("%f[%w_]near%f[^%w_]") or code:find("%f[%w_]far%f[^%w_]") then
				bad = bad + 1
				print("  " .. path .. ":" .. n .. ": " .. code:sub(1, 90))
			end
		end
		f:close()
	end
	list:close()
end
check(files > 100, "the sources were found: " .. files)
check(bad == 0, "no name of a Windows macro in the code: " .. bad)

print(string.format("%d passed, %d failed", PASSES or 0, FAILS or 0))
