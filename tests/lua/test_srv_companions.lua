-- Dev 57 P-G: exercise the live mode boundary over the NPC harness's transport and ALife stubs.
dofile("tests/lua/support/harness_npc.lua")

local SOURCE, DESTINATION = 0x101, 0x102
local SQUAD, MEMBER, LEADER, PEER = 300, 301, 500, 1
local FOLLOW, ADOPT, DROP, RECALL = "npc.comp_follow", "npc.comp_adopt", "npc.comp_drop", "npc.comp_recall"
local NAMES = { "l01_escape", "l02_garbage" }

local function start(M, W, role, map)
	local E = M.env
	local api = E.coop
	api.is_dedicated = function() return role == "world" end
	api.is_map_server = function() return role == "map" end
	api.is_mirror = function() return false end
	api.session_info = function() return { max_players = 16 } end
	api.levels = {
		split = function() return W.split end,
		level_of_player = function(peer) return peer == PEER and W.player_level or nil end,
		level_name = function(id) return NAMES[id] end,
		map_servers = function() return { { level = 1, bridge = SOURCE }, { level = 2, bridge = DESTINATION } } end,
		bridge_of_player = function(peer) return peer == PEER and DESTINATION or nil end,
		online_at_server = function(id) return id == MEMBER and W.holder ~= nil end,
		holder_of = function(id) return id == MEMBER and W.holder or nil end,
		recall = function(id, pin)
			if id ~= SQUAD then return false end
			M.pin = pin == nil
			if M.pin then W.holder = nil end
			return true
		end,
	}
	E.level.name = function() return NAMES[map] or "fake_start" end
	E.game_graph = function()
		return { vertex = function(_, id) return { level_id = function() return id end } end }
	end
	E.alife = function() return { level_name = function(_, id) return NAMES[id] end } end
	E.alife_object = function(id)
		if M.waiting_for_squad and id == SQUAD then return nil end
		return W.objects[id]
	end
	E.TeleportSquad = function(squad, pos, lvid, gvid)
		squad.m_game_vertex_id = gvid
		M.arrival = { pos = pos, lvid = lvid }
	end
	local marks = {}
	E.se_save_var = function(id, _, key, value)
		marks[id] = marks[id] or {}
		marks[id][key] = value
	end
	E.se_load_var = function(id, _, key) return marks[id] and marks[id][key] end
	E.axr_companions = {
		companion_squads = {},
		companion_squad_can_teleport = function() return not M.stay end,
		dismiss_special_squad = function(squad)
			M.dismissed = squad.id
			E.axr_companions.companion_squads[squad.id] = nil
		end,
		setup_companion_logic = function(npc) npc:give_info_portion("npcx_is_companion") end,
	}
	E.coop_quests_core = {
		share_up = function(key, get, set) M.share_up_key, M.share_up, M.hear = key, get, set end,
		share_down = function(key, get, set) M.share_down_key, M.share_down, M.give = key, get, set end,
	}
	load_script(M, "coop_npc_players")
	load_script(M, "coop_trust").reset_for_test({ default = "log" })
	local mode = load_script(M, "coop_mode")
	mode.on_game_start()
	load_script(M, "coop_hostplay_mode").on_game_start()
	local init_srv = load_script(M, "coop_srv_mode").on_game_start
	local core = load_script(M, "coop_npc_companions")
	core.on_game_start()
	local set_transfer_hooks = core.set_transfer_hooks
	core.set_transfer_hooks = function(hooks)
		M.transfer_installs = (M.transfer_installs or 0) + 1
		return set_transfer_hooks(hooks)
	end
	load_script(M, "coop_srv_companions").on_game_start()
	init_srv()
	return core
end

local function stand()
	reset_world()
	local W = { split = true, player_level = 1, objects = {} }
	W.squad = { id = SQUAD, m_game_vertex_id = 1 }
	function W.squad:commander_id() return MEMBER end
	-- The engine iterator returns a member as its first result.
	function W.squad:squad_members()
		local member = { id = MEMBER }
		return function()
			local next_member = member
			member = nil
			return next_member
		end
	end
	W.objects[SQUAD] = W.squad
	W.objects[MEMBER] = make_obj(MEMBER, 0, 0, 0)
	W.objects[LEADER] = { position = vec(6, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = 2 }
	return W
end

local function tick(M, ms)
	NOW = NOW + (ms or 3000)
	M.env.coop_npc_players.invalidate()
	M.fire("actor_on_update")
end

local function send(M, target, name, payload)
	M.env.coop_npc_players.send(name, payload, target)
	pump()
end

local function saved(M, key)
	local data = {}
	M.fire("save_state", data)
	return data[key or "coop_npc_leaders"] or {}
end

local function test_coop_does_not_subscribe_to_transfers()
	local W = stand()
	W.split = false
	local H = machine("host", 0, { [0] = 0, [PEER] = LEADER })
	start(H, W, "hostplay", 1)
	check(not (H.handlers[FOLLOW] or H.handlers[ADOPT] or H.handlers[DROP] or H.handlers[RECALL]),
		"Co-op has no subscriptions to server transfers")
	check(not H.share_up and not H.share_down, "Co-op does not register map-server leader sharing")
	H.env.axr_companions.companion_squads[SQUAD] = W.squad
	H.fire("load_state", { coop_npc_leaders = { [SQUAD] = LEADER } })
	tick(H)
	check(saved(H)[SQUAD] == LEADER and H.env.axr_companions.companion_squad_can_teleport(W.squad),
		"Co-op keeps the leader in its save and the stock teleport rule")
end

local function test_world_installs_transfers_before_session()
	local W = stand()
	W.split = false
	local H = machine("host", 0, { [PEER] = LEADER })
	local session = false
	local api = H.env.coop
	local players = api.players
	api.is_active = function() return session end
	api.is_host = api.is_active
	api.self_id = function() return session and 0 or -1 end
	api.players = function() return session and players() or {} end
	start(H, W, "world")
	check(H.env.coop_mode.decides_world() and not H.env.coop_npc_players.is_world_server(),
		"the facade recognizes the dedicated world before the engine gives it a session")
	check(H.transfer_installs == 1, "the world installs its transfer hooks at load")
	for _, verb in ipairs({ FOLLOW, ADOPT, DROP, RECALL }) do
		check(#(H.handlers[verb] or {}) == 1, "the world registers " .. verb .. " at load")
	end
	check(H.share_up_key == "comp_leaders" and H.share_down_key == "comp_leaders",
		"the world registers comp_leaders for share up and down at load")

	session, W.split = true, true
	H.env.coop_mode.decides_world()
	check(H.transfer_installs == 1, "starting the session does not reinstall the transfer hooks")
end

local function test_follow_recall_drop_and_deferred_adoption()
	local W = stand()
	local H = machine("host", 0, { [PEER] = LEADER })
	local A = machine("client", SOURCE, {})
	local B = machine("client", DESTINATION, { [PEER] = LEADER })
	start(H, W, "world")
	start(A, W, "map", 1)
	start(B, W, "map", 2)
	A.add(make_obj(MEMBER, 2, 0, 0))
	local npc = B.add(make_obj(MEMBER, 2, 0, 0))
	send(H, SOURCE, ADOPT, { s = SQUAD, l = LEADER, p = PEER, d = true })
	check(saved(A)[SQUAD] == LEADER, "source map accepts the world server's leader")
	H.env.se_save_var(MEMBER, nil, "companion_cannot_dismiss", true)
	W.player_level, W.holder = 2, SOURCE
	B.waiting_for_squad = true
	tick(A)
	pump()
	check(#sent_named(A, FOLLOW) == 1, "source map reports follow after the player has left its peer list")
	check(saved(H)[SQUAD] == LEADER, "world save retains the owner while the squad is in transit")
	check(A.share_up and A.share_up().l[SQUAD] == nil, "source map excludes the outgoing squad from its share")
	tick(H)
	pump()
	check(A.pin and not H.arrival, "world server recalls the held squad before moving it")
	tick(H)
	pump()
	check(H.arrival and H.arrival.pos == W.objects[LEADER].position and H.arrival.lvid == 7,
		"world server teleports to its authoritative record of the leader's body")
	check(A.pin == false and not A.dismissed and saved(A)[SQUAD] == nil,
		"transfer drop clears the source ownership and pin without dismissing the NPC")
	check(B.share_up and B.share_up().l[SQUAD] == LEADER and saved(B)[SQUAD] == nil,
		"destination reports the pending owner before its copy of the squad arrives")
	B.waiting_for_squad = false
	tick(B)
	check(saved(B)[SQUAD] == LEADER and npc:has_info("npcx_is_companion")
		and B.env.se_load_var(MEMBER, nil, "companion_cannot_dismiss") == true,
		"destination sets up the late squad with the stock marks")
	send(H, DESTINATION, DROP, { s = SQUAD })
	check(B.dismissed == SQUAD and saved(B)[SQUAD] == nil, "task drop dismisses on the owning map")
end

local function test_transport_sender_and_number_bounds()
	local W = stand()
	local H = machine("host", 0, { [PEER] = LEADER })
	local A = machine("client", SOURCE, {})
	local C = machine("client", PEER, { [PEER] = 0 })
	start(H, W, "world")
	start(A, W, "map", 1)
	start(C, W, "player", 1)
	send(C, 0, FOLLOW, { s = SQUAD, l = LEADER, p = PEER, _peer = SOURCE })
	send(A, 0, FOLLOW, { s = 65535, l = LEADER, p = PEER })
	send(A, 0, FOLLOW, { s = SQUAD, l = -1, p = PEER })
	send(A, 0, FOLLOW, { s = SQUAD, l = LEADER, p = 1.5 })
	send(A, 0, FOLLOW, { s = SQUAD, l = LEADER, p = 17 })
	local follow = H.env.coop_trust.status().comp_follow
	check(follow and follow.checked == 5 and follow.failed == 5 and follow.refused == 0,
		"world counts the sender and numeric bounds via coop_trust in log mode")
	check(next(saved(H)) == nil, "malformed transfers cannot create saved owners in log mode")
	send(C, SOURCE, ADOPT, { s = SQUAD, l = LEADER, p = PEER, _peer = 0 })
	send(H, SOURCE, ADOPT, { s = SQUAD, l = LEADER, p = 17 })
	send(C, SOURCE, DROP, { s = SQUAD, _peer = 0 })
	send(C, SOURCE, RECALL, { s = SQUAD, _peer = 0 })
	local status = A.env.coop_trust.status()
	check(status.comp_adopt and status.comp_adopt.failed == 2 and status.comp_drop and status.comp_drop.failed == 1
		and status.comp_recall and status.comp_recall.failed == 1, "map validates all three world-only verbs with coop_trust")
	check(saved(A)[SQUAD] == nil and not A.dismissed and not A.pin, "spoofed world orders leave the map unchanged")
end

test_coop_does_not_subscribe_to_transfers()
test_world_installs_transfers_before_session()
test_follow_recall_drop_and_deferred_adoption()
test_transport_sender_and_number_bounds()
print(string.format("\n%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
