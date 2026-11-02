-- Split levels, docs\SPLIT_LEVELS.md 7a: what a map server (Mk) tells the players of its level. For the world it is a client, so
-- coop.sync.set of the session is refused there; for its level it is the host, so coop.sync.broadcast reaches them. Real
-- coop_world_fight, coop_npc_effects, coop_world_fx on a fake world server, Mk and client. Run: tools\test_lua.cmd mk_relay
dofile("tests/lua/support/harness_world.lua")

local MK = 0x101
local LEVEL_HOST, LEVEL_MK = 1, 2

-- A client of the map server's level, as the engine tells it (coop.levels).
local function stands_on_mk(C)
	C.env.coop.levels = {
		split = function() return true end,
		my_level = function() return LEVEL_MK end,
		led_by_host_process = function(level) return level == LEVEL_HOST end,
	}
end

-- The map server as the engine has it: l_set refuses the session, l_broadcast takes the players of its level.
local function map_server()
	local K = machine("client", MK, { [MK] = 0, [1] = 500 })
	local E = K.env
	E.coop.is_map_server = function() return true end
	E.coop.is_mirror = function() return false end
	K.refused, K.casts = 0, {}
	E.coop.sync = {
		set = function()
			K.refused = K.refused + 1
			return false, "not allowed"
		end,
		get = function() return nil end,
		on = function() return true end,
		broadcast = function(name, args, opts)
			if K.cast_refusal then return false, K.cast_refusal end
			for _, v in pairs(args) do
				if type(v) == "table" then return false, "bad value" end -- to_value: no table in a table
			end
			K.casts[#K.casts + 1] = { name = name, args = args, opts = opts }
			return true, 1
		end,
	}
	load_script(K, "coop_npc_players")
	return K
end

-- What Mk casts comes out on the client with from = 0, its events too: the world relays them, the player knows no other process.
local function deliver(K, C)
	local list = K.casts
	K.casts = {}
	for _, c in ipairs(list) do
		local fn = C.effects[c.name]
		if fn and (c.opts == nil or c.opts.to == nil or c.opts.to == C.peer) then fn(c.args, 0) end
	end
	for _, q in ipairs(QUEUE) do
		if q.from == MK then q.from = 0 end
	end
	pump()
	world_pump()
end

local function fired(M) M.fire("actor_on_update") end

print("== who fights a player on a map server's level")
do
	local function stage()
		local H, C = world_pair()
		stands_on_mk(C)
		local K = map_server()
		for _, M in ipairs({ H, C, K }) do
			M.env.vector = vector
			M.env.xr_combat_ignore = { fighting_with_actor_npcs = {} }
		end
		local fighting = {}
		K.env.coop_npc_combat = { _state = function() return { fighting = fighting } end }
		K.add(make_obj(500, 0, 0, 0))
		for _, id in ipairs({ 700, 701 }) do
			K.add(make_obj(id, 10, 0, 0))
			C.add(make_obj(id, 10, 0, 0))
		end
		load_script(K, "coop_world_fight").on_game_start()
		local FC = load_script(C, "coop_world_fight")
		FC.on_game_start()
		K.env.coop_npc_players.invalidate()
		return H, C, K, fighting, FC
	end
	local function tick(K, C)
		NOW = NOW + 1100
		K.env.coop_npc_players.invalidate()
		fired(K)
		deliver(K, C)
		fired(C)
	end

	local H, C, K, fighting = stage()
	local ct = C.env.xr_combat_ignore.fighting_with_actor_npcs
	fighting[700] = { [500] = true }
	tick(K, C)
	check(ct[700] == true, "the NPC that fights him is in his table: the combat music starts")
	check(K.refused == 0, "the map server writes nothing the engine refuses")
	fighting[700], fighting[701] = nil, { [500] = true }
	tick(K, C)
	check(ct[700] == nil and ct[701] == true, "the table follows the map server's list")
	fighting[701] = nil
	tick(K, C)
	check(ct[701] == nil, "the fight is over: the table is empty")

	-- the world server's key of this player is from the level he left
	H.env.coop.sync.set("session", "world.fight.1", { 700 })
	tick(K, C)
	check(ct[700] == nil, "a key left on the world server by the level he came from is not read here")

	-- he left the level and came back with a new Lua state: he is told again
	fighting[700] = { [500] = true }
	tick(K, C)
	local player = K.objects[500]
	K.objects[500] = nil
	tick(K, C)
	K.objects[500] = player
	C.env.xr_combat_ignore.fighting_with_actor_npcs = {}
	local FC2 = load_script(C, "coop_world_fight")
	FC2.on_game_start()
	tick(K, C)
	check(C.env.xr_combat_ignore.fighting_with_actor_npcs[700] == true, "a player who came back hears the fight that goes on")

	-- a refusal is said, not swallowed
	K.cast_refusal = "too many"
	fighting[701] = { [500] = true }
	tick(K, C)
	local said = false
	for _, line in ipairs(K.log) do
		if line:find("too many", 1, true) then said = true end
	end
	check(said, "a list the engine refused is in the log")
	K.cast_refusal = nil

	-- a player on the world server's level goes on reading the key
	local H2, C2 = world_pair()
	C2.env.vector = vector
	C2.env.xr_combat_ignore = { fighting_with_actor_npcs = {} }
	C2.env.coop.levels = { split = function() return true end, my_level = function() return LEVEL_HOST end,
		led_by_host_process = function(level) return level == LEVEL_HOST end }
	C2.add(make_obj(700, 10, 0, 0))
	load_script(C2, "coop_world_fight").on_game_start()
	H2.env.coop.sync.set("session", "world.fight.1", { 700 })
	NOW = NOW + 1100
	fired(C2)
	check(C2.env.xr_combat_ignore.fighting_with_actor_npcs[700] == true, "on the host's level the world server's key is the list")
end

print("== looped sounds on a map server's level")
do
	local function voices(M)
		local E = M.env
		E.sound_theme = { theme = { gen_hum = { class_id = "looped_sound" }, radio_hum = { class_id = "looped_sound" } } }
		local xs = { sound_table = {}, looped_sound = {} }
		E.xr_sound = xs
		M.loops, M.stopped = {}, {}
		function xs.set_sound_play() end
		function xs.update() end
		function xs.play_sound_looped(id, snd)
			xs.looped_sound[id] = xs.looped_sound[id] or {}
			xs.looped_sound[id][snd] = true
			M.loops[#M.loops + 1] = { id, snd }
		end
		function xs.stop_sound_looped(id, snd)
			if not xs.looped_sound[id] then return end
			M.stopped[#M.stopped + 1] = { id, snd }
			if snd then xs.looped_sound[id][snd] = nil else xs.looped_sound[id] = nil end
		end
		E.xr_effects = {}
		E.surge_manager = { is_started = function() return false end }
		E.psi_storm_manager = { is_started = function() return false end }
		E.has_alife_info = function() return false end
		E.news_manager = {}
	end
	local function online(M, id)
		local o = M.add(make_obj(id, 10, 0, 0))
		M.env.db.storage[id] = { object = o }
	end
	local function stage()
		local H, C = world_pair()
		stands_on_mk(C)
		local K = map_server()
		for _, M in ipairs({ H, C, K }) do voices(M) end
		K.add(make_obj(500, 0, 0, 0))
		load_script(H, "coop_npc_effects").on_game_start()
		load_script(K, "coop_npc_effects").on_game_start()
		load_script(C, "coop_npc_effects").on_game_start()
		K.env.coop_npc_players.invalidate()
		return H, C, K
	end
	local function tick(H, K, C)
		NOW = NOW + 2100
		K.env.coop_npc_players.invalidate()
		fired(H)
		fired(K)
		deliver(K, C)
		fired(C)
		deliver(K, C)
	end

	local H, C, K = stage()
	online(K, 300)
	online(C, 300)
	tick(H, K, C)
	K.env.xr_sound.play_sound_looped(300, "gen_hum")
	tick(H, K, C)
	check(#C.loops == 1 and C.loops[1][1] == 300, "the loop of the map server's object plays on the client")
	tick(H, K, C)
	tick(H, K, C)
	check(#C.stopped == 0, "the session key of the world server, which does not list it, does not stop it")
	check(K.refused == 0, "the map server writes nothing the engine refuses")
	K.env.xr_sound.looped_sound[300] = nil
	tick(H, K, C)
	check(#C.stopped == 1 and C.stopped[1][1] == 300, "gone from the map server's table: stopped here")

	-- no event, only the state: an object that came online later
	K.env.xr_sound.looped_sound[301] = { radio_hum = true }
	online(K, 301)
	tick(H, K, C)
	check(#C.loops == 1, "not online here yet: nothing plays")
	online(C, 301)
	tick(H, K, C)
	check(#C.loops == 2 and C.loops[2][1] == 301, "the list brings it when the object comes")

	-- a client that lost the list (a load on the spot) gets it again without a change
	local before = 0
	for _ = 1, 15 do
		NOW = NOW + 2100
		K.env.coop_npc_players.invalidate()
		K.casts = {}
		fired(K)
		before = before + #K.casts
	end
	check(before >= 1 and before <= 3, "the list is told again now and then, not every tick (" .. before .. ")")
end

print("== the world's anabiotic is no business of a map server")
do
	local H, C = world_pair()
	local K = map_server()
	for _, M in ipairs({ H, K }) do
		local E = M.env
		E.surge_manager = { is_started = function() return false end }
		E.psi_storm_manager = { is_started = function() return false end }
		E.has_alife_info = function(info) return info == "anabiotic_in_process" end
		E.disable_info = function(info) M.disabled = info end
		E.xr_sound = { sound_table = {}, looped_sound = {} }
		E.xr_effects = {}
		load_script(M, "coop_npc_effects").on_game_start()
	end
	for _ = 1, 3 do
		NOW = NOW + 11000
		fired(H)
		fired(K)
	end
	check(H.disabled == "anabiotic_in_process", "a save with the hold: the world server clears it")
	check(K.disabled == nil, "the map server leaves the info of the world alone")
end

print("== effects on a map server's level, and on nobody else's")
do
	local function stage()
		local H, C = world_pair()
		local K = map_server()
		for _, M in ipairs({ H, K }) do
			local E = M.env
			E.vector = vector
			E.particles_object = function() return { play_at_pos = function() end, set_direction = function() end } end
			E.coop_mods_core = { mod = function(n) return E[n] end }
			E.coop.levels = { my_level = function() return M == H and LEVEL_HOST or LEVEL_MK end }
			local real = E.coop.sync.broadcast
			E.coop.sync.broadcast = function(name, args, opts)
				M.seen = { name = name, opts = opts }
				return real(name, args, opts)
			end
			local cls = { launch = function() return true end, slow_fly = function() end, stop_light = function() end }
			E.bind_signal_light = { signal_light_binder = cls }
			M.flare = cls
		end
		local FH, FK = load_script(H, "coop_world_fx"), load_script(K, "coop_world_fx")
		FH.on_game_start()
		FK.on_game_start()
		FH._set_host_on(true)
		FK._set_host_on(true)
		return H, C, K, FH, FK
	end

	local H, C, K, FH, FK = stage()
	FK.play("hit_fx\\hit_metal_01", vec(1, 2, 3))
	check(K.seen and K.seen.opts and K.seen.opts.radius ~= nil, "a particle of the map server goes out with its radius")
	check(K.seen.opts.level == nil, "no far view: the point is on this process's level")

	FH.play("hit_fx\\hit_metal_01", vec(1, 2, 3))
	check(H.seen.opts.level == nil, "the same on the world server")

	-- a task's functor in a far view: the point is on the level it looks at
	H.env.coop_quests_far = { in_scope = function() return { id = LEVEL_MK } end }
	H.seen = nil
	FH.play("hit_fx\\hit_metal_01", vec(1, 2, 3))
	check(H.seen and H.seen.opts.level == LEVEL_MK, "in a far view the cast names the level the point is on")
	H.env.coop_quests_far = nil

	-- a flare is an object of one level
	K.seen = nil
	K.flare.launch({ object = make_obj(800, 0, 0, 0) })
	check(K.seen and K.seen.name == "world.flare", "the smoke of a flare is told on the map server")
	check(K.seen.opts and K.seen.opts.level == LEVEL_MK, "to the players of that level")
	H.seen = nil
	H.flare.launch({ object = make_obj(801, 0, 0, 0) })
	check(H.seen and H.seen.opts and H.seen.opts.level == LEVEL_HOST, "on the world server to the players of its level")

	-- a refusal is said
	K.cast_refusal = "host only"
	FK.play("hit_fx\\hit_metal_01", vec(1, 2, 3))
	local said = false
	for _, line in ipairs(K.log) do
		if line:find("host only", 1, true) then said = true end
	end
	check(said, "a cast the engine refused is in the log")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
