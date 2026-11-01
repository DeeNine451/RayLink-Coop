-- One brain of the world: the world server picks the targets of squads a map server holds, the stock squad update there gets that
-- answer from the board; an NPC's logic goes with it (docs\SPLIT_LEVELS.md, plan T15). Real coop_levels_brain.script over the stubs.
-- Not shipped. Run: tools\test_lua.cmd levels_brain
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local BODIES = { [300] = { id = 300, smart_id = 40 }, [310] = { id = 310, smart_id = 41 }, [40] = { id = 40 }, [50] = { id = 50 }, [41] = { id = 41 } }
alife_object = function(id) return BODIES[id] end
local asked = {}
sim_board = { simulation_board = {} }
function sim_board.simulation_board:get_squad_target(squad)
	asked[#asked + 1] = squad.id
	return BODIES[50]
end
SIMBOARD = setmetatable({}, { __index = sim_board.simulation_board })

local LOGIC = { game_object = {} }
alife_storage_manager = { get_state = function() return LOGIC end }
marshal = { encode = function(t) return "<" .. tostring(t.active) .. ">" end, decode = function(s) return { active = s:match("<(.*)>") } end }

local KEPT = nil
local SQUADS = { 300, 310 }
coop.levels = {
	split = function() return true end,
	map_servers = function() return { { bridge = 0x101, level = 2 } } end,
	squads_at = function() return SQUADS end,
	logic_put = function(s) KEPT = s end,
	logic_bytes = function() return KEPT end,
}
local MAP_SERVER = false
coop.is_map_server = function() return MAP_SERVER end
SENT = {}
coop.send_event = function(name, payload, target)
	SENT[#SENT + 1] = { name = name, payload = payload, to = target }
	return true
end

print("== levels_brain")
load_coop_main()
coop_main.on_game_start()
load_script_file("coop_levels_brain")
coop_levels_brain.on_game_start()

coop_levels_brain._tick()
local last = SENT[#SENT]
check(last and last.name == "coop_brain" and last.to == 0x101, "the targets go to the map server that holds the squads")
check(last and last.payload == "300:50,310:50", "every squad it holds, with the world's board's answer")
local n = #SENT
coop_levels_brain._tick()
check(#SENT == n, "a target that was just decided is not decided again")
NOW = NOW + 31000
coop_levels_brain._tick()
check(#SENT == n + 1, "it is looked at again later")

asked = {}
MODE = "client"
MAP_SERVER = true
coop.is_host = function() return false end
coop_main.on_event("coop_brain", "300:50", 0)
check(sim_board.simulation_board.get_squad_target(SIMBOARD, BODIES[300]).id == 50, "a map server's board answers the world's target")
check(sim_board.simulation_board.get_squad_target(SIMBOARD, BODIES[310]).id == 41, "nothing decided yet: the squad stays at its smart")
check(#asked == 0, "its own board decides nothing")
coop_main.on_event("coop_brain", "310:50", 7)
check(coop_levels_brain._targets()[310] == nil, "only the world server decides")

LOGIC.game_object[201] = { active = "beh@guard" }
coop_levels_brain.logic_of(201)
check(KEPT == "<beh@guard>", "an object's logic goes to the engine as bytes")
coop_levels_brain.logic_of(202)
check(KEPT == "", "an object without logic: nothing")
KEPT = "<camper@1>"
coop_levels_brain.logic_in(203)
check(LOGIC.game_object[203] and LOGIC.game_object[203].active == "camper@1", "what came is what xr_logic reads when it comes online")

print(string.format("%d passed, %d failed", PASSES, FAILS))
