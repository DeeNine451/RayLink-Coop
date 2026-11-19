-- The map counts the NPC and reports to the world, which owns the saved state and the published hint.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local M = machine("client", 0x101, { [1] = 500 })
local W = machine("host", 0, { [1] = 500 })
local C = machine("client", 1, { [1] = 0 })
local published, writes, map_writes = nil, 0, 0

local function start(machine, dedicated, map)
	local e = machine.env
	e.coop.is_dedicated = function() return dedicated end
	e.coop.is_map_server = function() return map end
	e.coop.levels = {
		split = function() return true end,
		map_servers = function() return { { bridge = M.peer } } end,
	}
	local states = {}
	e.alife_object = function(id) if id == 501 then return { id = id } end end
	e.alife_storage_manager = {
		get_se_obj_state = function(se, create)
			if create and not states[se.id] then states[se.id] = {} end
			return states[se.id]
		end,
	}
	e.game_statistics = {
		increment_npc_statistic = function(npc, name)
			local state = e.alife_storage_manager.get_se_obj_state(e.alife_object(npc:id()), true)
			state[name] = (state[name] or 0) + 1
		end,
	}
	e.coop.sync = {
		set = function(scope, key, value)
			if map then map_writes = map_writes + 1; return false end
			published, writes = { scope, key, value }, writes + 1
			return true
		end,
		on_change = function(scope, key, fn) machine.on_change = fn end,
	}
	modes.live(load_script(machine, "coop_mode"), function(name) return load_script(machine, name) end)
	load_script(machine, "coop_trust")
	load_script(machine, "coop_npc_stats").on_game_start()
	return states
end

local world = start(W, true, false)
local map = start(M, false, true)
local client = start(C, false, false)
M.env.game_statistics.increment_npc_statistic(make_obj(501, 0), "killed_monsters")
local up = M.sent[1]
check(map[501] and map[501].killed_monsters == 1, "the map counts through the stock wrapper")
check(map_writes == 0, "only the world writes the shared object hint")
check(up and up.name == "npc_stats_up" and up.target == 0, "map publishes the existing event to the world")
pump()
check(world[501] and world[501].killed_monsters == 1, "the world keeps the counter for its save")
check(published and published[1] == "object:501" and published[2] == "npc_stats", "the world writes the existing object key")
if published then C.on_change(nil, published[3], nil, nil, 501) end
check(client[501] and client[501].killed_monsters == 1, "the client reads the live hint")

local function report(from, data)
	for _, f in ipairs(W.handlers.npc_stats_up or {}) do f(W.env.coop_main.encode(data), from) end
end
report(2, { id = 501, killed_monsters = 99 })
check(writes == 1, "a player cannot change the saved count")
report(0x102, { id = 501, killed_monsters = 99 })
check(writes == 1, "an unregistered bridge cannot change the saved count")
report(M.peer, { id = 501, killed_monsters = 2, items_sold = -1 })
check(writes == 1 and world[501] and world[501].killed_monsters == 1, "bad numbers cannot partially overwrite a report")
local trust = W.env.coop_trust.status()
check(trust.npc_stats_sender and trust.npc_stats_sender.failed == 2, "sender checks pass through coop_trust")
check(trust.npc_stats_values and trust.npc_stats_values.failed == 1, "numeric bounds pass through coop_trust")

print(("%d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
