-- Fixtures for the debug command handlers, over the real Lua mode facade.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local MK = 0x101
local LEVEL_HOST, LEVEL_MK = 1, 2

local function spy(M, key)
	M[key] = {}
	return function(...)
		local list = M[key]
		list[#list + 1] = { ... }
		return true
	end
end

local ITEMS = {
	wpn_ak74 = { { "class", "WP_AK74" } },
	medkit = { { "class", "II_MEDKI" } },
	sim_squad_bandit = { { "class", "ON_OFF_S" } },
	zone_mosquito_bald = { { "class", "ZS_MBALD" } },
}

-- The engine stand-ins every process of a session has, by the contract of the design (package 1) and the engine as it is.
local function engine(M, o)
	local E = M.env
	E.vector = vector
	E.ini_sys = make_ini(ITEMS)
	E.IsStalker = function(obj) return obj and obj._stalker == true end
	E.IsMonster = function(obj) return obj and obj._monster == true end
	E.coop.is_world_server = function() return o.ws == true and E.coop.is_active() end
	E.coop.is_map_server = function() return o.mk == true end
	E.coop.is_dedicated = function() return o.dedicated == true end
	E.coop.is_player = function() return not o.dedicated and not o.mk and o.player ~= false end
	M.life = {}
	E.coop.life_of = function(id) return M.life[id] or "alive" end
	M.dbg = { on = o.debug ~= false, flags = {}, said = {} }
	E.coop.debug = {
		state = function() return { on = M.dbg.on, source = M.dbg.on and 2 or 0, serial = 1 } end,
		is_operator = function() return o.ws == true end,
		flags = function(peer) return M.dbg.flags[peer] or 0 end,
		set_flags = function(peer, t)
			M.dbg.set = M.dbg.set or {}
			M.dbg.set[#M.dbg.set + 1] = { peer = peer, t = t }
			return true
		end,
		say = function(line) M.dbg.said[#M.dbg.said + 1] = line end,
	}
	M.sync_handlers, M.sync_limits = {}, {}
	E.coop.sync = {
		handler = function(name, f)
			if o.ws ~= true and not o.single then return false, "host only" end
			if name == o.rejected_handler then return false, "registration failed" end
			M.sync_handlers[name] = f
			return true
		end,
		limit = function(name, burst, per_sec)
			M.sync_limits[name] = { burst, per_sec }
			return true
		end,
	}
	M.verts = {}
	E.level.vertex_position = function(lv) return M.verts[lv] or vector() end
	E.level.change_game_time = spy(M, "time_jumps")
	E.level.set_weather = spy(M, "weathers")
	E.level.set_time_factor = spy(M, "factors")
	E.level.get_time_hours = function() return 10 end
	E.level.get_time_minutes = function() return 0 end
	M.forced = 0
	E.level_weathers = { get_weather_manager = function() return { forced_weather_change = function() M.forced = M.forced + 1 end } end }
	M.next_id = 9000
	M.created = {}
	E.alife_create_item = function(sec, t, props)
		M.next_id = M.next_id + 1
		M.created[#M.created + 1] = { sec = sec, t = t, id = M.next_id }
		return { id = M.next_id }
	end
	E.alife_create = function(sec, pos, lv, gv)
		M.next_id = M.next_id + 1
		M.created[#M.created + 1] = { sec = sec, pos = pos, lv = lv, gv = gv, id = M.next_id, object = true }
		return { id = M.next_id, squad_members = function() return function() return nil end end, create_npc = function() end }
	end
	E.alife_object = function(id) return M.objects[id] and { id = id, position = M.objects[id]._pos } or nil end
	E.alife_release_id = spy(M, "released")
	M.infos = {}
	E.has_alife_info = function(i) return M.infos[i] == true end
	E.give_info = function(i) M.infos[i] = true end
	E.disable_info = function(i) M.infos[i] = nil end
	E.coop.money_grant = spy(M, "grants")
	E.coop.money_of = function() return 100 end
	E.coop_mods_core = { teleport = spy(M, "teleports") }
	M.orders = {}
	-- The engine-independent stand-in for the server's ALife far view.
	local far = {
		level_of_id = function(id) return (M.obj_level or {})[id] or LEVEL_HOST end,
		order = function(id, verb, a, b, c)
			M.orders[#M.orders + 1] = { id = id, verb = verb, a = a, b = b, c = c }
			return true
		end,
	}
	E.coop_srv_quests_far = far
	E.coop.levels = {
		split = function() return o.dedicated == true or o.split == true end,
		my_level = function() return o.my_level or (not o.dedicated and LEVEL_HOST or nil) end,
		level_of_player = function(peer)
			if peer == 0 and (o.dedicated or o.mk) then return nil end
			return (o.levels or {})[peer] or (o.dedicated and LEVEL_MK or LEVEL_HOST)
		end,
		bridge_of_player = function(peer)
			local l = (o.levels or {})[peer] or (o.dedicated and LEVEL_MK or LEVEL_HOST)
			return ((o.dedicated or o.split) and l == LEVEL_MK and o.ws) and MK or nil
		end,
		map_servers = function() return M.bridges or { { bridge = MK, level = LEVEL_MK } } end,
		players_on = function() return M.level_players or 1 end,
	}
	local players = E.coop.players
	E.coop.players = function()
		local rows = players()
		for _, p in ipairs(rows) do
			p.level = E.coop.levels.level_of_player(p.id)
			p.elsewhere = p.level ~= nil and p.level ~= E.coop.levels.my_level()
		end
		return rows
	end
end

-- The world decider: co-op host peer 0 and client peer 3, or a dedicated server without a player.
local function world(o)
	o = o or {}
	reset_world()
	local avatars = o.dedicated and { [3] = 503 } or { [0] = 0, [3] = 503 }
	local H = machine(o.single and "single" or "host", 0, avatars)
	if o.before_session then
		H.set_session(false)
		H.env.coop.is_host = H.env.coop.is_active
	end
	o.ws = true
	o.player = not o.dedicated
	engine(H, o)
	if not o.dedicated then H.add(make_obj(503, 10, 0, 0, { _stalker = true })) end
	H.add(make_obj(700, 20, 0, 0, { _stalker = true, _name = "bandit_1" }))
	load_script(H, "coop_mode")
	if not o.delayed_modes then modes.live(H.env.coop_mode, function(name) return load_script(H, name) end) end
	if not H.env.coop_trust then load_script(H, "coop_trust") end
	load_script(H, "coop_npc_players")
	load_script(H, "coop_debug_cmds")
	local S = load_script(H, "coop_debug_server")
	S.on_game_start()
	if o.dedicated then load_script(H, "coop_srv_debug").on_game_start() end
	return H, S
end

local function map_authority()
	local K = machine("client", MK, { [3] = 900 })
	engine(K, { mk = true, split = true, my_level = LEVEL_MK, levels = { [3] = LEVEL_MK } })
	K.add(make_obj(900, 10, 0, 5, { _stalker = true }))
	if not K.env.coop_mode then
		modes.live(load_script(K, "coop_mode"), function(name) return load_script(K, name) end)
	end
	if not K.env.coop_trust then load_script(K, "coop_trust") end
	load_script(K, "coop_npc_players")
	load_script(K, "coop_debug_cmds")
	load_script(K, "coop_debug_server").on_game_start()
	load_script(K, "coop_srv_debug").on_game_start()
	return K
end

local function ask(H, name, peer, args)
	local f = H.sync_handlers[name]
	if not f then return nil, "no handler" end
	return f(peer, args)
end

local function sent(M, name)
	local list = {}
	for _, s in ipairs(M.sent) do
		if s.name == name then list[#list + 1] = { target = s.target, t = M.env.coop_main.decode(s.payload) } end
	end
	return list
end

local function trust_failures(M)
	local total = 0
	for _, c in pairs(M.env.coop_trust.status()) do total = total + c.failed end
	return total
end

return { MK = MK, LEVEL_HOST = LEVEL_HOST, LEVEL_MK = LEVEL_MK, world = world,
	map_authority = map_authority, engine = engine, ask = ask, sent = sent, modes = modes, trust_failures = trust_failures }
