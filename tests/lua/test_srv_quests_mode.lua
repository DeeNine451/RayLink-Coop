-- S6: quest actions use the map's authority only for live objects, and ceasefires accept reports from map servers.
dofile("tests/lua/support/harness_quests.lua")

local PLAYER, BRIDGE = 1, 0x101
local world = machine("host", 0)
local api = world.env.coop
api.is_dedicated = function() return true end
api.levels = {
	split = function() return true end,
	bridge_of_player = function(peer) if peer == PLAYER then return BRIDGE end end,
	map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
}
local mode = load_script(world, "coop_mode")
load_script(world, "coop_srv_mode").on_game_start()
local q = load_script(world, "coop_quests_core")
world.env.coop_trust = load_script(world, "coop_trust")
load_script(world, "coop_srv_quests_core").on_game_start()
q.on_game_start()
load_script(world, "coop_quests_missions").on_game_start()

local saves, scopes = 0, {}
world.env.coop_srv_quests_far = {
	with_level_of = function(peer, fn, ...)
		scopes[#scopes + 1] = peer
		return fn(...)
	end,
}
q.register_host_action("rly", function(from)
	if from == PLAYER then saves = saves + 1 end
end)
q.register_host_action("box", function() error("the world server has no live box") end)
local act, prior_errors = world.handlers["quests.act"], q.error_count()
act(q.encode({ a = "rly", _peer = 3 }), PLAYER)
check(saves == 1 and #scopes == 1 and scopes[1] == PLAYER, "a save action uses the transport player in the world's far view")
act(q.encode({ a = "box", b = 700, _peer = 3 }), PLAYER)
local sent = world.sent[#world.sent]
check(sent and sent.name == "quests.act" and sent.target == BRIDGE and q.decode(sent.payload)._peer == PLAYER,
	"a live box goes to the player's map server with the transport player")
check(#scopes == 1 and q.error_count() == prior_errors, "forwarding does not run the box action on the world")
local sent_before = #world.sent
for _, from in ipairs({ -1, 1.5, 17, BRIDGE, 0xffffffff }) do
	act(q.encode({ a = "box", b = 700, _peer = PLAYER }), from)
end
for _, fields in ipairs({ { a = "box", b = 65535 }, { a = "trade", n = 700, y = 2 } }) do
	act(q.encode(fields), PLAYER)
end
check(#world.sent == sent_before and #scopes == 1 and q.error_count() == prior_errors,
	"the world neither runs nor forwards malformed requests")
local world_checks = world.env.coop_trust.status()
check(world_checks.quest_act_sender and world_checks.quest_act_sender.failed == 5,
	"the world accounts for each invalid transport sender")
check(world_checks.quest_act_fields and world_checks.quest_act_fields.failed == 2,
	"the world accounts for bad fields before forwarding")

local hits = {}
world.env.xr_bribe = { npc_on_hit_callback = function(comm) hits[#hits + 1] = comm end }
local function report_hit(from, comm)
	world.handlers["quests.bribe_hit"](q.encode({ c = comm }), from)
end
report_hit(PLAYER, "stalker")
report_hit(BRIDGE + 1, "stalker")
report_hit(BRIDGE, string.rep("s", 257))
report_hit(BRIDGE, "")
check(#hits == 0, "player, unknown bridge and malformed community reports cannot break a ceasefire")
report_hit(BRIDGE, "stalker")
check(#hits == 1 and hits[1] == "stalker", "the registered map server can break a ceasefire in the world save")
check(has_log(world, "quest_bribe_hit_sender") and has_log(world, "quest_bribe_hit_community"),
	"the trust ledger accounts for both refusal reasons")

local map = machine("client", BRIDGE)
map.env.coop.is_map_server = function() return true end
local player_level = 2
map.env.coop.levels = {
	split = function() return true end,
	my_level = function() return 2 end,
	level_of_player = function() return player_level end,
	talking = function() return false end,
}
map.players = { { id = PLAYER, avatar_id = 501 } }
local avatar = map.new_obj(501, "coop_player_avatar", vec(1, 0, 0))
local box = map.new_obj(700, "quest_box", vec(2, 0, 0), { _box = true })
load_script(map, "coop_mode")
load_script(map, "coop_srv_mode").on_game_start()
local mq = load_script(map, "coop_quests_core")
local map_trust = load_script(map, "coop_trust")
load_script(map, "coop_srv_quests_core").on_game_start()
mq.on_game_start()
load_script(map, "coop_quests_pda").on_game_start()
load_script(map, "coop_quests_missions").on_game_start()
local steps = {}
map.env.treasure_manager = { try_spawn_treasure = function(opened)
	if opened:id() == box:id() then steps[#steps + 1] = "fill" end
end }
map.env.coop_srv_levels_brain = { caches_now = function() steps[#steps + 1] = "report" end }
local map_act = map.handlers["quests.act"]
map_act(mq.encode({ a = "box", b = 700, _peer = PLAYER }), PLAYER)
check(#steps == 0, "the map server ignores a direct box request from a player")
map_act(mq.encode({ a = "box", b = 700, _peer = PLAYER }), 0)
check(table.concat(steps, ",") == "fill,report", "the passed request fills the live box, then reports the caches")

for _, peer in ipairs({ 0, -1, 1.5, 17, BRIDGE, 0xffffffff, "1" }) do
	map_act(mq.encode({ a = "box", b = 700, _peer = peer }), 0)
end
map_act(mq.encode({ a = "box", b = 700 }), 0)
check(#steps == 2, "relayed boxes require a whole player slot from the world")
local relay_peer = map_trust.status().quest_act_relay_peer
check(relay_peer and relay_peer.failed == 8, "the map accounts for every rejected relayed player")

local rly_runs = 0
mq.register_host_action("rly", function() rly_runs = rly_runs + 1 end)
map_act(mq.encode({ a = "rly", _peer = PLAYER }), 0)
local relay_action = map_trust.status().quest_act_relay_action
check(rly_runs == 0 and relay_action and relay_action.failed == 1, "the map refuses and accounts for a relayed world action")

local looked_up = 0
local lookup = map.env.level.object_by_id
map.env.level.object_by_id = function(id)
	looked_up = looked_up + 1
	return lookup(id)
end
for _, id in ipairs({ 0, -1, 700.5, 65535, "700" }) do
	map_act(mq.encode({ a = "box", b = id, _peer = PLAYER }), 0)
	map_act(mq.encode({ a = "trade", n = id, y = 0, _peer = PLAYER }), 0)
end
local trades = {}
map.env.death_manager = {
	get_items_by_npc = function(id) return trades[id] end,
	set_items_by_npc = function(id, value) trades[id] = value end,
}
map.new_obj(701, "stalker", vec(2, 0, 0), { _stalker = true })
for _, answer in ipairs({ -1, 2, 0.5, "0", false }) do
	map_act(mq.encode({ a = "trade", n = 701, y = answer, _peer = PLAYER }), 0)
end
map_act(mq.encode({ a = "trade", n = 701, _peer = PLAYER }), 0)
local map_fields = map_trust.status().quest_act_fields
check(looked_up == 0 and trades[701] == nil and map_fields and map_fields.failed == 16,
	"the map checks box and trade fields before looking up objects or caching an answer")
map.env.level.object_by_id = lookup

local function trade(id)
	map.new_obj(id, "stalker", vec(2, 0, 0), { _stalker = true })
	map_act(mq.encode({ a = "trade", n = id, y = 0, _peer = PLAYER }), 0)
end
local recent_calls = 0
local recent = false
map.env.coop.talk_recent = function(peer, npc, ms)
	recent_calls = recent_calls + 1
	return recent and peer == PLAYER and npc == 704 and ms > 0
end
player_level = 3 -- The live avatar is still resolvable, but the player's placement already moved.
trade(702)
check(trades[702] == nil and recent_calls == 0, "a map server refuses trade with an avatar reported on another map")
player_level = 2
trade(703)
check(trades[703] == nil and recent_calls == 1, "local trade still needs a recent conversation")
recent = true
trade(704)
check(trades[704] == false and recent_calls == 2, "local trade with a confirmed conversation caches the decision")

api.levels.my_level = function() return 1 end
api.levels.level_of_player = function() return 2 end
api.levels.bridge_of_player = function() end
world.players = { { id = PLAYER, avatar_id = 501 } }
world.new_obj(501, "coop_player_avatar", vec(1, 0, 0))
local world_trades = {}
world.env.death_manager = {
	get_items_by_npc = function(id) return world_trades[id] end,
	set_items_by_npc = function(id, value) world_trades[id] = value end,
}
local function world_trade(id)
	world.new_obj(id, "stalker", vec(2, 0, 0), { _stalker = true })
	act(q.encode({ a = "trade", n = id, y = 0 }), PLAYER)
end
api.levels.talking = function() return false end
world_trade(705)
check(world_trades[705] == nil, "the world refuses when the map explicitly reports no conversation")
api.levels.talking = function() return true end
world_trade(706)
check(world_trades[706] == false, "the world accepts a conversation reported by the map")
api.levels.talking = nil
world_trade(707)
check(world_trades[707] == false, "the world keeps the old reach-only fallback when talk reports are unavailable")

local local_hits = 0
map.env.character_community = function() return "stalker" end
map.env.xr_bribe = { npc_on_hit_callback = function() local_hits = local_hits + 1 end }
fire(map, "npc_on_hit_callback", box, 1, nil, avatar)
local hit = map.sent[#map.sent]
check(local_hits == 1 and hit and hit.name == "quests.bribe_hit" and hit.target == 0,
	"the map server applies the hit locally and sends it to the world")
check(map.handlers["quests.bribe_hit"] == nil, "the map server leaves incoming ceasefire reports to the world")

check(type(q.shared().down.bribe) == "table", "the world server shares its ceasefire table")

-- S6 integration (questsb hand-off): these packets are dropped whatever the trust mode, so the shipped policy refuses them
-- and the log says "refused", not "would be refused: let through"
do
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	local text = fh and fh:read("*a") or ""
	if fh then fh:close() end
	for _, name in ipairs({ "quest_bribe_hit_sender", "quest_bribe_hit_community", "quest_act_sender", "quest_act_relay_peer",
		"quest_act_relay_action", "quest_act_fields", "quest_act_action", "pda_announce_sender", "pda_announce_nick",
		"pda_achv_name", "pda_ency_section", "level_request_sender", "level_request_peer" }) do
		check(text:match("\n" .. name .. "%s*=%s*(%w+)") == "refuse", "the shipped policy refuses the hard-dropped check " .. name)
	end
	check(text:match("\ndefault%s*=%s*(%w+)") == "log", "the shipped default stays log")
end
print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
