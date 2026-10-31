-- World parity W4f, sound M1, M7 (coop_npc_effects.script): particles of logic scenes, looped sounds that began before a
-- client could hear them, sounds that carry further than the voice radius, a puppet's voice table. Run: tools\test_lua.cmd world_voices
dofile("tests/lua/support/harness_world.lua")

local function stock(M)
	local E = M.env
	E.sound_theme = { theme = {
		meet_hello = { class_id = "npc_sound" },
		door_open = { class_id = "object_sound" },
		gen_hum = { class_id = "looped_sound" },
		radio_hum = { class_id = "looped_sound" },
	} }
	local xs = { sound_table = {}, looped_sound = {} }
	E.xr_sound = xs
	M.played, M.loops, M.stopped = {}, {}, {}
	function xs.set_sound_play(id, snd, faction, point)
		local th = E.sound_theme.theme[snd]
		if xs.sound_table[id] == nil then
			xs.sound_table[id] = th
			M.played[#M.played + 1] = { id, snd }
		end
		return xs.sound_table[id] and xs.sound_table[id].snd_obj
	end
	function xs.update(id)
		local t = xs.sound_table[id]
		if t and not t.busy then xs.sound_table[id] = nil end
	end
	function xs.play_sound_looped(id, snd)
		assert(E.db.storage[id] and E.db.storage[id].object, "stock looped_sound:play indexes db.storage[id].object")
		xs.looped_sound[id] = xs.looped_sound[id] or {}
		xs.looped_sound[id][snd] = true
		M.loops[#M.loops + 1] = { id, snd }
	end
	function xs.stop_sound_looped(id, snd)
		if not xs.looped_sound[id] then return end
		M.stopped[#M.stopped + 1] = { id, snd }
		if snd then xs.looped_sound[id][snd] = nil else xs.looped_sound[id] = nil end
	end
	E.xr_effects = { play_particle_on_path = function(actor, npc, p) M.path_fx = { p[1], p[2], p[3] } end }
	E.xr_logic = { parse_func_params = function(s)
		local t = {}
		for w in s:gmatch("[^:]+") do t[#t + 1] = tonumber(w) or w end
		return t
	end }
	E.ini_sys = { section_exist = function() return true end }
	E.surge_manager = { is_started = function() return false end }
	E.psi_storm_manager = { is_started = function() return false end }
	E.has_alife_info = function() return false end
	E.news_manager = {}
end

local function online(M, id, x)
	local o = M.add(make_obj(id, x or 20, 0, 0))
	M.env.db.storage[id] = { object = o }
	return o
end

local function stage()
	local H, C = world_pair()
	stock(H)
	stock(C)
	local FH, FC = load_script(H, "coop_npc_effects"), load_script(C, "coop_npc_effects")
	FH.on_game_start()
	FC.on_game_start()
	-- the proxy stands where the client stands
	H.add(make_obj(500, 25, 0, 0, { _name = "proxy" }))
	C.add(make_obj(500, 0, 0, 0))
	return H, C, FH, FC
end

local function tick(H, C)
	NOW = NOW + 2100
	H.fire("actor_on_update")
	C.fire("actor_on_update")
	world_pump()
end

print("== W4f: particles along a path")
do
	local H, C = stage()
	tick(H, C)
	H.env.xr_effects.play_particle_on_path(H.env.db.actor, nil, { "steam\\vent", "jup_b41_path", 75 })
	pump()
	check(H.path_fx and H.path_fx[1] == "steam\\vent", "the scene plays on the host")
	check(C.path_fx and C.path_fx[1] == "steam\\vent" and C.path_fx[2] == "jup_b41_path" and tostring(C.path_fx[3]) == "75", "and on the client, by name, with its parameters")
end

print("== M1: looped sounds")
do
	local H, C, FH, FC = stage()
	online(H, 300)
	tick(H, C)

	-- a client has no such object yet: the event must not fail, the loop must come when the object does
	H.env.xr_sound.play_sound_looped(300, "gen_hum")
	tick(H, C)
	check(#C.loops == 0 and C.env.coop_npc_players.error_count("effects") == 0, "object not online here: nothing plays, no error")
	online(C, 300)
	tick(H, C)
	check(#C.loops == 1 and C.loops[1][1] == 300 and C.loops[1][2] == "gen_hum", "the object comes online: the loop plays")
	tick(H, C)
	check(#C.loops == 1, "and only once")

	-- it goes offline here and comes back
	C.objects[300] = nil
	C.env.db.storage[300] = nil
	tick(H, C)
	online(C, 300)
	tick(H, C)
	check(#C.loops == 2, "back online: the loop plays again")

	-- the stop is an event; a lost one is repaired by the state as well
	H.env.xr_sound.looped_sound[300] = nil
	tick(H, C)
	check(#C.stopped == 1 and C.stopped[1][1] == 300, "gone from the host's table: stopped here")

	-- a joiner gets what is playing
	H.env.xr_sound.play_sound_looped(300, "radio_hum")
	tick(H, C)
	check(#C.loops == 3 and C.loops[3][2] == "radio_hum", "a loop that was playing when the state was read starts here")

	-- the host's own loops stay out, by its actor id
	H.env.db.storage[0] = { object = H.env.db.actor }
	H.env.xr_sound.play_sound_looped(0, "gen_hum")
	tick(H, C)
	check(#C.loops == 3, "the host's actor's loops are not relayed")
end

print("== M7: range and the puppet's table")
do
	local H, C = stage()
	tick(H, C)
	local door = online(H, 400, 170)
	online(C, 400, 170)
	H.env.sound_theme.theme.door_open.snd_obj = { max_distance = 250 }
	C.env.sound_theme.theme.door_open.snd_obj = { max_distance = 250 }
	H.env.xr_sound.set_sound_play(400, "door_open")
	pump()
	check(#C.played == 1 and C.played[1][2] == "door_open", "an object sound carries as far as the sound does: 145 m from the client, heard")

	local npc = online(H, 401, 170)
	online(C, 401, 170)
	H.env.xr_sound.set_sound_play(401, "meet_hello")
	pump()
	check(#C.played == 1, "a voice keeps its radius: the engine relays the voice itself")

	-- a puppet's voice: xr_sound.update runs from the binder, suspended for puppets; here the tick does it
	H.env.xr_sound.sound_table[401] = nil
	H.objects[500]._pos = vec(165, 0, 0)
	H.env.xr_sound.set_sound_play(401, "meet_hello")
	pump()
	check(#C.played == 2, "(a voice close by)")
	C.env.sound_theme.theme.meet_hello.busy = true
	tick(H, C)
	check(C.env.xr_sound.sound_table[401] ~= nil, "the line plays: the table keeps it")
	C.env.sound_theme.theme.meet_hello.busy = nil
	tick(H, C)
	check(C.env.xr_sound.sound_table[401] == nil, "the line is over: the next theme of this NPC plays its Lua part too")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
