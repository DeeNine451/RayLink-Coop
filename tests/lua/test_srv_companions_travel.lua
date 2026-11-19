-- Dev 57, K-61 (Server). Each process runs the real facade and companions scripts.
-- Map A reports the departing leader. The world has the saved owner and the body
-- record, uses the engine's holder reports to move the squad, and tells map B to adopt.
-- Only B can measure the live NPC and choose whom it follows while the owner is away.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local A, B = 0x101, 0x102
local LEVEL, BRIDGE = { [A] = 7, [B] = 19 }, { [7] = A, [19] = B }
local MAPS = { [A] = "l01_escape", [B] = "l02_garbage" }
local WORLD, OWNER, STAY, NEAR, FAR = 0, 501, 502, 503, 504
local TRAVELLING, STAYING = 301, 302
local FOLLOW, ADOPT, DROP = "npc.comp_follow", "npc.comp_adopt", "npc.comp_drop"
local SAVE_KEY = "coop_npc_leaders"

local function new_world()
	reset_world()
	return {
		-- Peers are connection slots. Character IDs are saved in the world.
		players = { [1] = { id = OWNER, map = A }, [2] = { id = STAY, map = A },
			[3] = { id = FAR, map = B }, [4] = { id = NEAR, map = B } },
		map = { [TRAVELLING] = A, [STAYING] = A }, holder = { [401] = A },
		body = { position = vec(40, 2, 11), m_level_vertex_id = 87, m_game_vertex_id = 1901 },
		arrivals = {},
	}
end

local function squad(id, map)
	return {
		id = id, m_game_vertex_id = LEVEL[map] * 100,
		commander_id = function() return id + 100 end,
		squad_members = function()
			local member = { id = id + 100 }
			return function()
				local next_member = member
				member = nil
				return next_member
			end
		end,
	}
end

local function server(w, bridge, before_session)
	local seats = {}
	local m = machine(bridge == WORLD and "host" or "client", bridge, seats)
	if before_session then m.set_session(false) end
	local e, objects, marks = m.env, {}, {}
	m.records, m.seats = objects, seats
	for id, map in pairs(w.map) do
		if bridge == WORLD or bridge == map then
			objects[id] = squad(id, map)
			objects[id + 100] = make_obj(id + 100, 40, 2, 11)
		end
	end
	if bridge == WORLD then objects[OWNER] = w.body end
	e.coop.is_dedicated = function() return bridge == WORLD end
	e.coop.is_map_server = function() return bridge ~= WORLD end
	e.coop.is_mirror = function() return false end
	e.coop.levels = {
		split = function() return true end,
		my_level = function() return LEVEL[bridge] end,
		level_of_player = function(peer) return w.players[peer] and LEVEL[w.players[peer].map] end,
		level_name = function(id) return MAPS[BRIDGE[id]] end,
		map_servers = function() return { { level = 7, bridge = A }, { level = 19, bridge = B } } end,
		bridge_of_player = function(peer) return w.players[peer] and w.players[peer].map end,
		online_at_server = function(id) return w.holder[id] ~= nil end,
	}
	e.level.name = function() return MAPS[bridge] or "fake_start" end
	e.game_graph = function()
		return { vertex = function(_, id) return { level_id = function() return math.floor(id / 100) end } end }
	end
	e.alife = function() return { level_name = function(_, id) return MAPS[BRIDGE[id]] end } end
	e.alife_object = function(id) return objects[id] end
	e.get_object_squad = function(npc) return objects[npc:id() - 100] end
	e.se_save_var = function(id, _, key, value)
		marks[id] = marks[id] or {}
		marks[id][key] = value
	end
	e.se_load_var = function(id, _, key) return marks[id] and marks[id][key] end
	e.TeleportSquad = function(sq, pos, lvid, gvid)
		assert(bridge == WORLD, "teleport attempted outside the world server")
		assert(not w.holder[sq:commander_id()], "teleport attempted while the squad is held online")
		w.arrivals[#w.arrivals + 1] = { id = sq.id, pos = pos, lv = lvid, gv = gvid }
		sq.m_game_vertex_id, w.map[sq.id] = gvid, BRIDGE[math.floor(gvid / 100)]
	end
	e.axr_companions = {
		companion_squads = {},
		companion_squad_can_teleport = function() return true end,
		setup_companion_logic = function(npc) npc:give_info_portion("npcx_is_companion") end,
	}
	-- Capture the leader share callbacks, the engine boundary for the save's map rows.
	e.coop_quests_core = { share = function() return {
		up = function(key, get, set) if key == "comp_leaders" then m.up, m.hear = get, set end end,
		down = function(key, get, set) if key == "comp_leaders" then m.down, m.give = get, set end end,
	} end }
	load_script(m, "coop_npc_players")
	load_script(m, "coop_trust").reset_for_test({ default = "log" })
	local mode = load_script(m, "coop_mode")
	mode.on_game_start()
	m.core = load_script(m, "coop_npc_companions")
	m.core.on_game_start()
	load_script(m, "coop_srv_companions").on_game_start()
	modes.live(mode, function(name) return load_script(m, name) end)
	return m
end

local function tick(w, m)
	-- A map server lists its local bodies. The world's rows cover both maps.
	local old = {}
	for peer, id in pairs(m.seats) do old[id], m.seats[peer] = true, nil end
	for peer, p in pairs(w.players) do
		if m.peer == WORLD or m.peer == p.map then
			m.seats[peer], old[p.id] = p.id, nil
			if m.peer ~= WORLD and not m.objects[p.id] then
				local x = p.id == NEAR and 44 or p.id == FAR and 60 or 40
				m.add(make_obj(p.id, x, 2, 11))
			end
		end
	end
	for id in pairs(old) do m.objects[id] = nil end
	NOW = NOW + 2100
	m.fire("actor_on_update")
	pump()
end

local function save(m)
	local data = {}
	m.fire("save_state", data)
	return data, data[SAVE_KEY] or {}
end

local function owner(m, id)
	local _, owners = save(m)
	return owners[id]
end

local function fixture()
	local w = new_world()
	local world, source, destination = server(w, WORLD), server(w, A), server(w, B)
	-- Hand the map previously saved recruits through the ordinary leader share.
	world.fire("load_state", { [SAVE_KEY] = { [TRAVELLING] = OWNER, [STAYING] = STAY } })
	tick(w, world)
	source.add(make_obj(401, 3, 0, 0))
	source.add(make_obj(402, 5, 0, 0))
	source.give(world.down())
	tick(w, source)
	world.hear(source.up(), LEVEL[A])
	return w, world, source, destination
end

local function test_handoff_and_save()
	local w, world, source, destination = fixture()
	check(owner(source, TRAVELLING) == OWNER and owner(source, STAYING) == STAY,
		"A starts with both saved recruits and their own leaders")
	w.players[1].map = B
	tick(w, source)
	local words = sent_named(source, FOLLOW)
	local follow = words[1] and source.env.coop_main.decode(words[1].payload)
	check(#words == 1 and words[1].target == WORLD and follow.s == TRAVELLING and follow.p == 1 and follow.l == OWNER,
		"A sends comp_follow to the world for the departing player only")
	local row = source.up()
	check(row.l[TRAVELLING] == nil and row.l[STAYING] == STAY,
		"A excludes the departing squad from its ordinary leader share")
	world.hear(row, LEVEL[A])
	tick(w, world)
	check(#w.arrivals == 0 and #sent_named(world, ADOPT) == 0 and owner(source, TRAVELLING) == OWNER,
		"world waits while a member is online and A keeps the owner until drop")
	local data, owners = save(world)
	check(owners[TRAVELLING] == OWNER and owners[STAYING] == STAY,
		"world save during the handoff holds both owners after A reports its current row")

	-- Restart from the in-flight save: no pending event survives, only the saved IDs.
	world, source, destination = server(w, WORLD), server(w, A), server(w, B)
	world.fire("load_state", data)
	tick(w, world)
	source.give(world.down())
	tick(w, source)
	tick(w, world)
	check(#w.arrivals == 0 and owner(world, TRAVELLING) == OWNER,
		"restarted source resumes the trip and the world still waits for the held member")
	w.holder[401] = nil
	tick(w, world)
	local moved = w.arrivals[1]
	check(#w.arrivals == 1 and moved.id == TRAVELLING and moved.pos:distance_to_sqr(vec(40, 2, 11)) == 0
		and moved.lv == 87 and moved.gv == 1901, "world moves the offline squad to the leader's body and vertices")
	local adopts = sent_named(world, ADOPT)
	local adopt = adopts[1] and world.env.coop_main.decode(adopts[1].payload)
	check(#adopts == 1 and adopts[1].target == B and adopt.s == TRAVELLING and adopt.l == OWNER,
		"world sends comp_adopt with the original character to B")
	local drops = sent_named(world, DROP)
	local drop = drops[1] and world.env.coop_main.decode(drops[1].payload)
	check(#drops == 1 and drops[1].target == A and drop.s == TRAVELLING and drop.m == true
		and owner(source, TRAVELLING) == nil, "source drops only the moved squad after the world takes it")

	-- The destination gets the engine records after the Lua message.
	destination.records[TRAVELLING] = squad(TRAVELLING, B)
	local npc = destination.add(make_obj(401, 40, 2, 11))
	destination.records[401] = npc
	tick(w, destination)
	local leader = destination.core.leader_of(npc)
	check(leader and leader:id() == OWNER and destination.core.owner_character(npc) == OWNER
		and npc:has_info("npcx_is_companion"), "B adopts the arriving NPC and resolves its live leader")
	world.hear(destination.up(), LEVEL[B])
	check(w.map[STAYING] == A and owner(source, STAYING) == STAY and owner(world, STAYING) == STAY
		and owner(destination, STAYING) == nil, "the other player's squad stays on A with its original owner")
	check(owner(world, TRAVELLING) == OWNER, "the next world save keeps the adopted owner")

	-- Both candidates are on B. The farther candidate has the lower peer ID.
	w.players[1] = nil
	tick(w, destination)
	local target = destination.core.follows(npc)
	check(destination.core.leader_of(npc) == nil and target and target:id() == NEAR,
		"disconnected owner's squad follows the nearest player on its map")
	world.hear(destination.up(), LEVEL[B])
	check(owner(destination, TRAVELLING) == OWNER and owner(world, TRAVELLING) == OWNER,
		"temporary following keeps the owner in both saves")
	w.players[5] = { id = OWNER, map = B }
	destination.add(make_obj(OWNER, 52, 2, 11))
	tick(w, destination)
	target = destination.core.follows(npc)
	check(target and target:id() == OWNER and owner(destination, TRAVELLING) == OWNER,
		"returning character takes back the squad on a new peer slot even when another player is nearer")
end

-- F5-CMP-3 reproducer. Set COOP_CMP_3_REPRO=1 to include this additional case.
local function test_recycled_peer_during_disconnect()
	local w, world, source = fixture()
	w.players[1] = nil
	tick(w, source)
	-- A later connection can reuse the old peer slot on another map.
	w.players[1] = { id = 505, map = B }
	tick(w, source)
	world.hear(source.up(), LEVEL[A])
	tick(w, world)
	check(#sent_named(source, FOLLOW) == 0 and #w.arrivals == 0 and owner(world, TRAVELLING) == OWNER,
		"a replacement on the disconnected player's peer slot cannot take the squad to another map")
end

local function test_world_hooks_before_session()
	local w, _, source = fixture()
	-- The dedicated process loads its world and calls on_game_start before HostAutostart.
	local world = server(w, WORLD, true)
	world.set_session(true)
	tick(w, world)
	w.players[1].map = B
	tick(w, source)
	check(#sent_named(source, FOLLOW) == 1 and owner(world, TRAVELLING) == OWNER,
		"world started before its session still receives comp_follow and saves the owner")
end

local function test_stand_reads_loaded_owner()
	-- The stand must check the persisted table from load_state, before any client reconnects.
	local m = machine("host", WORLD, {})
	local e = m.env
	e.command_line = function() return "-coop_dedicated 27991 -coop_load last" end
	e.coop.is_dedicated = function() return true end
	e.coop_mode = { when_srv = function(f) f() end }
	e.getFS = function() return { update_path = function(_, _, path) return path end } end
	e.get_console = function() return { execute = function(_, cmd) assert(cmd == "flush") end } end
	e.io = { open = function(path, mode)
		assert(path == "zz_companions_srv.txt" and mode == "r")
		return { read = function() return "reload 301 401 501 l01_escape l02_garbage" end, close = function() end }
	end }
	local chunk = loadfile("temp/stand/coop_zz_companions_srv.script") or loadfile("tools/stand/coop_zz_companions_srv.script")
	check(chunk ~= nil, "stand registers a world-save observer")
	if not chunk then return end
	setfenv(chunk, e)()
	e.on_game_start()
	m.fire("load_state", { [SAVE_KEY] = { [STAYING] = STAY, [TRAVELLING] = STAY } })
	check(#m.log == 1 and m.log[1]:find("[cmp-srv] FAIL", 1, true), "stand rejects a loaded entry for the wrong owner")
	m.fire("load_state", { [SAVE_KEY] = { [TRAVELLING] = OWNER } })
	check(#m.log == 2 and m.log[2]:find("[cmp-srv] loaded squad=301 npc=401 owner=501", 1, true),
		"stand confirms the same squad and character from the world save")
end

test_handoff_and_save()
-- The stand probe lives under temp until the lead integrates the scenario.
if os.getenv("COOP_CMP_STAND_PROBE") == "1" then test_stand_reads_loaded_owner() end
if os.getenv("COOP_CMP_3_REPRO") == "1" then
	test_recycled_peer_during_disconnect()
	test_world_hooks_before_session()
end
print(string.format("\n%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
