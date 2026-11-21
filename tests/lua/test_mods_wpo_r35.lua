local fixture = assert(loadfile("tests/lua/mods_wpo_window_fixture.lua"))
local checks, failed = 0, 0
-- R35 (every container, both modes) and its round 2 (the authority gives a player's item its parts with the item, the
-- readers wait, the gun in hand, lost asks): the server mode and the co-op, each its own run.
for _, scenario in ipairs({ "r35", "fix2" }) do
	for _, server in ipairs({ true, false }) do
		local c, f = fixture(server, scenario)
		checks, failed = checks + (c or 0), failed + (f or 0)
	end
end
print(("%d passed, %d failed"):format(checks - failed, failed))
if failed > 0 then os.exit(1) end
