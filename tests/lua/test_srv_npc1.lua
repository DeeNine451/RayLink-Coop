-- The world server forwards to the map that leads the requesting player.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local W = machine("host", 0, { [1] = 500 })
local K = machine("client", 0x101, { [1] = 500, [2] = 501 })
local function attach(M, dedicated)
	local E = M.env
	E.coop.is_dedicated = function() return dedicated end
	E.coop.is_map_server = function() return not dedicated end
	E.coop.levels = {
		split = function() return true end,
		bridge_of_player = function(peer) if peer == 1 then return 0x101 end end,
	}
	local players = E.coop.players
	E.coop.players = function()
		local rows = players()
		for _, row in ipairs(rows) do
			row.level = row.id == 1 and 5 or 8
			row.elsewhere = row.id == 2
		end
		return rows
	end
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	load_script(M, "coop_trust")
	return load_script(M, "coop_npc_players")
end

local WP, KP = attach(W, true), attach(K, false)
K.add(make_obj(500, 10))
check(#WP.everyone() == 0 and #KP.everyone() == 1, "server actors never count as players")
local here, away = KP.player(1), KP.player(2)
check(here.here and here.level == 5 and not away.here and away.level == 8, "map presence and level come from player facts")
check(not WP.player(1).here and WP.player(1).level == 5, "the world knows the level without leading the map")

local world_calls, map_calls, sender = 0, 0
WP.on("test.npc1", function() world_calls = world_calls + 1 end, "host")
KP.on("test.npc1", function(_, from) map_calls, sender = map_calls + 1, from end, "host")
K.handlers["test.npc1"][1](KP.encode({ _peer = 1 }), 2)
check(map_calls == 0, "a player cannot impersonate a relayed request")
W.handlers["test.npc1"][1](WP.encode({ _peer = 2 }), 1)
pump()
check(world_calls == 0 and map_calls == 1 and sender == 1, "only the authoritative map handles the authenticated player")
K.handlers["test.npc1"][1](KP.encode({ _peer = 256 }), 0)
check(map_calls == 1, "the map checks the relayed player ID too")

print(("%d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
