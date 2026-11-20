local overview = dofile("tests/lua/support/debug_overview.lua")

local rows = overview(false, true)
check(rows[1].text:find("Host | 0 | 33 |", 1, true) ~= nil, "a server player sees the map reported by the server layer")
check(rows[2].text:find("Bob | 2 | - |", 1, true) ~= nil, "the server layer leaves a joining player's map blank")
check(rows[2].text:find("l01_escape", 1, true) == nil, "the Players card does not show the server player's current map for an unknown map")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
