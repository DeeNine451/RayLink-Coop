local fixture = assert(loadfile("tests/lua/mods_wpo_window_fixture.lua"))
local checks, failed = 0, 0
-- Run each R35 scenario with the world and map servers and again with the co-op host.
for _, scenario in ipairs({ "r35", "fix2", "residual" }) do
	for _, server in ipairs({ true, false }) do
		local c, f = fixture(server, scenario)
		checks, failed = checks + (c or 0), failed + (f or 0)
	end
end
print(("%d passed, %d failed"):format(checks - failed, failed))
if failed > 0 then os.exit(1) end
