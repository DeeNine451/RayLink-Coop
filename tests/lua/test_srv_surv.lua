-- Server survival callbacks and story relay. Run: tools\test_lua.cmd srv_surv
dofile("tests/lua/support/stubs_mods.lua")
local log_has = log_has -- menu_stubs replaces it with a pattern matcher
dofile("tests/lua/support/item_tent_stock.lua")
dofile("tests/lua/support/menu_stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")

local bridge = 0x101
local event = "coop_cp_story"
local handlers, stories, spotted, blocks = {}, {}, {}, {}
local surge = { time_forwarded = false }

coop_main = {
	add_event_handler = function(name, fn) handlers[name] = fn end,
	encode = function(t) return t.r or "" end,
	decode = function(s) return { r = s ~= "" and s or nil } end,
}
coop_trust.reset_for_test({ default = "log" })
coop.checkpoint = {
	story = function(reason) stories[#stories + 1] = reason or false end,
	claim_tent = function() error("a server ghost must not make a claim") end,
}
coop.rest = { set_world_block = function(reason) blocks[#blocks + 1] = reason end }
surge_manager = {
	is_started = function() return true end,
	get_surge_manager = function() return surge end,
}
level.map_add_object_spot = function(id) spotted[id] = true end
level.map_has_object_spot = function() return 0 end
xr_effects = { scenario_autosave = function() error("stock save in a session") end }

make_actor(vec3(0, 0, 0))
load_mini()
load_script("coop_mode")
for _, name in ipairs({ "coop_checkpoints", "coop_death", "coop_rest", "coop_tent_guard" }) do
	load_script(name).on_game_start()
end

-- The legacy host/client bits deliberately disagree with the answer sets.
MODE = "host"
modes.install(coop_mode, "srv_map")
xr_effects.scenario_autosave(nil, nil, { "st_save_map" })
check(#stories == 0, "the map server does not set the world's story checkpoint")
check(#SENT == 1 and SENT[1].name == event and SENT[1].target == 0 and SENT[1].payload == "st_save_map",
	"the map server publishes the story reason to the world")
xr_effects.scenario_autosave(nil, nil, { string.rep("x", 300) })
check(SENT[2] and #SENT[2].payload == 128, "the relayed story reason is bounded")

MODE = "client"
spawn("coop_death_stash", vec3(5, 0, 5), nil, { id = 558 })
SendScriptCallback("coop_death_marker", 7, 558, "drop")
check(spotted[558] == true, "the map server marks the death stash it sees")
MODE = "host"
SendScriptCallback("coop_rest_skipped", 6)
SendScriptCallback("actor_on_update")
check(surge.time_forwarded == false and #blocks == 0, "the map server does not update the world's sleep state")

local _, map_tent = spawn("ph_tent", vec3(1, 0, 0))
SendScriptCallback("coop_tent_placed", map_tent:id(), 7)
check(not item_tent.get_spawned_tents()[map_tent:id()], "the map server does not register a world tent")

MODE = "host"
coop.is_dedicated = function() return true end
coop.levels = { map_servers = function() return { { bridge = bridge, level = 2 } } end }
modes.live(coop_mode)
surge.time_forwarded, blocks = false, {}
xr_effects.scenario_autosave(nil, nil, { "st_save_world" })
check(#stories == 1 and stories[1] == "st_save_world", "the world process sets its own story checkpoint")
check(#SENT == 2, "the world does not relay its own story")
handlers[event]("st_save_from_level", bridge)
check(#stories == 2 and stories[2] == "st_save_from_level", "the world accepts a report from its map server")
local sender = coop_trust.status().cp_story_sender
check(sender and sender.checked == 1 and sender.failed == 0, "the accepted transport sender was checked")
LOG = {}
handlers[event]("forged", 1)
check(#stories == 2 and log_has("[coop-trust] ! cp_story_sender: story checkpoint from unexpected peer 1"),
	"a player-sent report goes through trust and cannot change the checkpoint")
handlers[event](string.rep("x", 129), bridge)
check(#stories == 2 and log_has("[coop-trust] ! cp_story_reason:"),
	"an oversized reason goes through trust and cannot change the checkpoint")
LOG = {}
coop.levels.map_servers = function() return {} end
handlers[event]("stale_report", bridge)
check(#stories == 2 and log_has("[coop-trust] ! cp_story_sender:"),
	"the world safely rejects a report from a bridge removed from the registry")
coop.levels.map_servers = nil
handlers[event]("no_registry", bridge)
check(#stories == 2 and sender.failed == 3, "the world safely rejects a report when bridge membership is unavailable")
SendScriptCallback("coop_rest_skipped", 6)
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
check(surge.time_forwarded == true, "the world notifies the surge manager at the sleep skip")
check(#blocks == 1, "the world alone reports the current rest blocker")

local _, world_tent = spawn("ph_tent", vec3(2, 0, 0))
SendScriptCallback("coop_tent_placed", world_tent:id(), 7)
check(item_tent.get_spawned_tents()[world_tent:id()] == true, "the world records the tent placed by the engine")

-- The live dedicated layer answers before HostAutostart opens the session.
MODE = "sp"
blocks, surge.time_forwarded = {}, false
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
SendScriptCallback("coop_rest_skipped", 6)
check(#blocks == 0, "before the session the world does not report a rest blocker")
check(surge.time_forwarded == false, "before the session a rest skip does not advance surge state")

local _, pending_tent = spawn("ph_tent", vec3(3, 0, 0))
SendScriptCallback("coop_tent_placed", pending_tent:id(), 7)
check(not item_tent.get_spawned_tents()[pending_tent:id()], "before the session the world ignores tent placements")
local tent_se = SE[pending_tent:id()]
coop.checkpoint.tent_owner = function(id) return id == tent_se.id and 7 or nil end
local base_alife = alife
function alife()
	local sim = base_alife()
	sim.iterate_objects = function(_, visit) visit(tent_se) end
	return sim
end
SendScriptCallback("actor_on_first_update")
check(not item_tent.get_spawned_tents()[tent_se.id], "before the session first update does not reconcile stock tent lists")

spawn("coop_death_stash", vec3(6, 0, 0), nil, { id = 559 })
SendScriptCallback("coop_death_marker", 7, 559, "drop")
check(not spotted[559], "before the session the world ignores death markers")

MODE = "host"
coop.is_dedicated = function() return false end
coop.levels.map_servers = function() return { { bridge = bridge, level = 2 } } end
LOG = {}
handlers[event]("coop_forgery", bridge)
xr_effects.scenario_autosave(nil, nil, { "st_save_coop" })
check(#stories == 3 and stories[3] == "st_save_coop" and #SENT == 2 and log_has("[coop-trust] ! cp_story_sender:"),
	"the Co-op host rejects a network report through trust and still sets its local checkpoint")

done("SRV_SURV")
