local overview = dofile("tests/lua/support/debug_overview.lua")

for _, role in ipairs({ "host", "client" }) do
	local rows, place = overview(role == "host", false)
	check(rows[1].text:find("Host | 0 | 22 |", 1, true) ~= nil, role .. " displays the roster's numeric map ID")
	check(rows[2].text:find("Bob | 2 | - |", 1, true) ~= nil, role .. " leaves an unknown map blank")
	check(place == "l01_escape", role .. " still displays the current map in My Place")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
