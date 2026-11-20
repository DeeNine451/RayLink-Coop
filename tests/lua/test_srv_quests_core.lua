-- Build 57, S6 P-G: quest bodies and map facts provided by the server layer.
dofile("tests/lua/support/harness_quests.lua")

local function boot(M)
	load_script(M, "coop_mode")
	load_script(M, "coop_quests_core")
	local file = io.open("gamedata/scripts/coop_srv_quests_core.script", "r")
	if not file then return end -- exercise the same assertions against the old Core during the red run
	file:close()
	load_script(M, "coop_srv_quests_core").on_game_start()
end

local function map_facts(M, here)
	M.env.coop.levels = {
		split = function() return true end,
		my_level = function() return here end,
		level_of_player = function(peer) if peer == 1 then return 2 end end,
		carried = function(id)
			if id == 501 then return { { id = 777, section = "wpn_ak74", condition = 0.45 } } end
			return {}
		end,
	}
	M.env.game_graph = function()
		return { vertex = function(_, id) return { level_id = function() return id end } end }
	end
	local stock_object = M.env.alife_object
	M.env.alife_object = function(id)
		if id ~= 501 then return stock_object(id) end
		return {
			id = 501, position = vec(3, 9, 4), m_level_vertex_id = 11, m_game_vertex_id = 2,
			community = function() return "stalker" end, rank = function() return 200 end,
			alive = function() return true end,
		}
	end
	M.players = { { id = 1, avatar_id = 501, level = 2 } }
end

local target = { position = vec(0, 0, 0), m_game_vertex_id = 2, online = true }

do
	local M = machine("host", 0)
	map_facts(M, 1)
	boot(M)
	local q = M.env.coop_quests_core
	check(q.far_body(1, 501) == nil and not q.held_there(target),
		"remote quest facts wait for the server layer")
	M.env.coop.is_dedicated = function() return true end
	load_script(M, "coop_srv_mode").on_game_start()
	check(#q.characters() == 0 and not M.env.coop_mode.actor_is_player(), "world server excludes its ghost actor")
	check(q.is_far_peer(1) and not q.is_far_peer(3) and q.held_there(target),
		"world server uses the player's reported map and the held squad's map")
	local body, peer, d = q.nearest_body(target, true)
	check(body and body:id() == 501 and body:level_vertex_id() == 11 and peer == 1 and d == 25,
		"world server finds the nearest reported body on the target map")
	check(q.nearest_body({ position = target.position, m_game_vertex_id = 3 }) == nil,
		"a target on an empty map cannot use a body from another map")
	local item = body and body:object("wpn_ak74")
	check(item and item:id() == 777 and item:condition() == 0.45,
		"a distant quest reads the reported item's condition")
	local released, delivered
	M.env.alife_release_id = function(id) released = id end
	M.env.itms_manager = { create_item = function(section, to, data) delivered = { section, to, data.cond } end }
	local trader = {}
	if item then body:transfer_item(item, trader) end
	check(released == 777 and delivered and delivered[1] == "wpn_ak74" and delivered[2] == trader and delivered[3] == 0.45,
		"remote turn-in removes the original item and preserves its wear")
	M.players = {}
	local saved = q.body_for_character(501)
	check(saved and saved:character_community() == "stalker" and saved:character_rank() == 200,
		"a disconnected character still has a record for personal quest effects")
end

do
	local M = machine("client", 0x101)
	map_facts(M, 2)
	M.env.coop.is_map_server = function() return true end
	local avatar = M.new_obj(501, "coop_player_avatar", vec(3, 9, 4), { _stalker = true, _gv = 2 })
	boot(M)
	load_script(M, "coop_srv_mode").on_game_start()
	local q = M.env.coop_quests_core
	local body, peer = q.nearest_body(target, true)
	check(body == avatar and peer == 1 and #q.characters() == 1 and not M.env.coop_mode.actor_is_player(),
		"map server uses the live avatar and excludes its ghost actor")
	check(not q.is_far_peer(1) and not q.held_there(target), "a map server treats its own map as local")
end

do
	local M = machine("host", 0)
	map_facts(M, 1)
	-- Even if the unused map table has data, the active co-op layer must not expose remote quest bodies.
	M.env.coop.levels.split = function() return false end
	boot(M)
	load_script(M, "coop_hostplay_mode").on_game_start()
	local q = M.env.coop_quests_core
	M.env.coop.levels.split = function() error("co-op quest queries must not inspect split levels") end
	local ok, body, peer, d = pcall(q.nearest_body, target, true)
	check(ok and body == M.actor and peer == 0 and d == 0 and M.env.coop_mode.actor_is_player(),
		"co-op host decides quest proximity using its own live actor")
	local saved = q.body_for_character(501)
	local item = saved and saved:object("wpn_ak74")
	check(item and item:id() == 777 and item:condition() == 0.45,
		"co-op can still read a saved character's ALife inventory")
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
