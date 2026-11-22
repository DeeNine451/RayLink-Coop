-- R32 W1 / W7 / W10 (temp\r30\design\R32-final.md §8 Lua): the facade's new questions coop_mode.writes(id), presence(level, pos)
-- and op_done(op, answer), answered by the real layers (coop_hostplay_mode, coop_srv_mode) over the coop.* stubs, and by "none".
--   none (single player): writes everything, nobody to count around a place, an op is the module's own business;
--   the co-op host writes everything, a co-op client nothing;
--   a world server and a map server write what the engine's writer rule says (coop.writes = Mode::writer_of over the root);
--   a server's player machine writes nothing, whatever the engine stub says.
-- A bad id is never written. presence and op_done are filled by WP13 / WP4 and WP15; until then every layer answers none's.
-- Not shipped. Run: tools\test_lua.cmd mode_writes
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")

print("== none (no layer): single player")
modes.install(F, "none")
check(F.writes(5) == true and F.writes(0) == true, "single player writes every object, the actor too")
check(F.writes(nil) == false and F.writes(-1) == false and F.writes(1.5) == false and F.writes(65535) == false
	and F.writes("5") == false and F.writes(0 / 0) == false, "a bad id is never written")
check(F.presence(1, vec3(0, 0, 0)) == nil, "nobody to count around a place: stock code counts db.actor")
check(F.op_done({ origin = 1, seq = 2 }, "ok") == false and F.op_done(nil) == false, "an op's answer is the module's own business")

-- the real layers over the stubs, as axr_main installs them
modes.live(F)
local ENGINE_WRITES = { [5] = true, [6] = false }
local asked = {}
coop.writes = function(id)
	asked[#asked + 1] = id
	return ENGINE_WRITES[id] == true
end
local function process(t)
	coop.is_active = function() return t.active ~= false end
	coop.is_host = function() return t.host == true end
	coop.is_map_server = function() return t.map == true end
	coop.is_dedicated = function() return t.dedicated == true end
	coop.levels = { split = function() return t.split == true end, bridge_of_player = function() return 0x101 end }
	asked = {}
end

print("== the co-op host")
process({ host = true })
check(F.writes(5) == true and F.writes(6) == true and F.writes(0) == true, "the host writes every object of its world")
check(#asked == 0, "the host does not ask the engine: it writes everything")
check(F.writes(-1) == false, "a bad id: not written")
check(F.presence(1, vec3(0, 0, 0)) == nil and F.op_done({ origin = 0, seq = 1 }, "ok") == false,
	"presence and op_done answer none's until WP15 / WP4")

print("== a co-op client")
process({ host = false })
check(F.writes(5) == false and F.writes(6) == false and F.writes(0) == false, "a co-op client writes nothing")

print("== the world server")
process({ dedicated = true })
check(F.writes(5) == true and F.writes(6) == false, "the world server writes what the engine's writer rule says")
check(#asked == 2 and asked[1] == 5 and asked[2] == 6, "it asks the engine for each id")
check(F.writes(-1) == false and #asked == 2, "a bad id never reaches the engine")
check(F.presence(1, vec3(0, 0, 0)) == nil and F.op_done({ origin = 0x101, seq = 7 }, "ok") == false,
	"presence and op_done answer none's until WP13 / WP4")

print("== a map server")
process({ map = true })
check(F.writes(5) == true and F.writes(6) == false, "a map server writes what the engine's writer rule says")

print("== a server's player machine")
process({ split = true, host = false })
ENGINE_WRITES[7] = true
check(F.writes(7) == false and F.writes(5) == false, "a player's machine writes nothing, whatever the engine stub says")
check(#asked == 0, "it does not even ask the engine")

print("== a layer that raises: the facade answers none's")
process({ dedicated = true })
coop.writes = function() error("boom") end
check(F.writes(5) == false, "the srv layer's engine call failed: not written (call() swallows the error)")

done("MODE_WRITES")
