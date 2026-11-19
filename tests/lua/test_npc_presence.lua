MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local verb = "mods.npc_presence_arrived"

local level_id = 2
local function pos(x) return vec3(x, 0, 0) end
local function vertex_map(id) return { level_id = function() return id end } end
function game_graph() return { valid_vertex_id = function(_, id) return id >= 0 end,
	vertex = function(_, id) return vertex_map(id) end } end
local function body(id, x, map)
	local se, obj = spawn("body", pos(x), nil, { id = id, kind = "stalker" })
	se.m_game_vertex_id = map
	se._kind = "stalker"
	function se:name() return "body_" .. id end
	function se:move_offline(value)
		if value == nil then return self.moves ~= false end
		self.moves = value
	end
	function se:alive() return obj:alive() end
	function obj:game_vertex_id() return map end
	return obj
end

local function run(mode)
	MODE = mode == "none" and "sp" or "host"
	SELF = mode == "srv_map" and 257 or 0
	OBJ, SE, SENT, db.storage = {}, {}, {}, {}
	local host = body(0, mode == "hostplay" and 115 or 0, level_id)
	local client = body(500, 4, level_id)
	local local_friend = body(501, 115, level_id)
	local remote = body(502, 1, 3)
	db.actor = host
	local rows = { { id = 1, avatar_id = 500 }, { id = 2, avatar_id = 501 } }
	if mode == "hostplay" then rows[#rows + 1] = { id = 0, avatar_id = 0, is_self = true } end
	if mode == "srv_map" or mode == "srv_world" then rows[#rows + 1] = { id = 3, avatar_id = 502 } end
	coop.players = function() return rows end
	coop.is_map_server = function() return mode == "srv_map" end
	coop.is_dedicated = function() return mode == "srv_world" end
	coop.avatar_of = function(id)
		for _, row in ipairs(rows) do if row.id == id then return row.avatar_id end end
	end
	coop.life_of = function(id) return OBJ[id] and OBJ[id]:alive() and "alive" or "dead" end
	coop.levels = {
		split = function() return mode == "srv_map" or mode == "srv_world" end,
		my_level = function() return level_id end,
		level_of_player = function(peer) return peer == 3 and 3 or level_id end,
	}
	local facade = load_script("coop_mode")
	modes.install(facade, mode, mode == "srv_map" and {
		where = function(peer) return (peer == 1 or peer == 2) and "here" or "away" end,
		decider = function(peer) return (peer == 1 or peer == 2) and "this" or "other" end,
	} or nil)
	load_script("coop_main").on_game_start()
	load_script("coop_mods_core")
	load_script("coop_npc_players")
	load_script("coop_trust")
	for _, callback in ipairs({ "actor_on_first_update", "actor_on_update", "on_level_changing", "save_state", "load_state" }) do
		AddScriptCallback(callback)
	end
	local story = { local_target = 10, far_target = 11 }
	function get_story_object_id(name) return story[name] end
	SE[10] = { position = pos(0), m_game_vertex_id = 2 }
	SE[11] = { position = pos(0), m_game_vertex_id = 3 }
	local original_calls = 0
	local function original() original_calls = original_calls + 1; return "stock" end
	xr_conditions = { distance_to_obj_le = original, distance_to_obj_ge = original,
		dist_to_story_obj_le = original, dist_to_story_obj_ge = original }
	sr_monster = { fake_monster = { update = function(self)
		if self.is_actor_inside == nil and self.st.monster then
			self.is_actor_inside = self.object:inside(db.actor:position())
			return
		end
		if not self.is_actor_inside and self.object:inside(db.actor:position()) then
			self.is_actor_inside = true
			self.spawned = self.spawned + 1
		end
	end } }
	local waves, flags = {}, {}
	function has_alife_info(flag) return flags[flag] == true end
	function host:give_info_portion(flag) flags[flag] = true end
	SIMBOARD = { smarts_by_names = { pri_a28_heli = { position = pos(200) } } }
	for k, x in ipairs({ 0, 60, 95 }) do
		story["pri_a28_sr_mono_add_" .. k] = 20 + k
		SE[20 + k] = { position = pos(x), m_game_vertex_id = 2 }
		OBJ[20 + k] = { inside = function(_, p) return math.abs(p.x - x) < 8 end }
		INI["pri_a28_heli_mono_add_" .. k] = { spawn_point = "wave" .. k }
	end
	INI.pri_a28_heli_mono_add_2.spawn_vid = "9:2"
	function level.vertex_position(id) return pos(id == 9 and 5 or 60) end
	function patrol(path)
		local x = ({ wave1 = 10, wave2 = 50, wave3 = 70 })[path]
		assert(x, "unexpected patrol " .. path)
		return { point = function() return pos(x) end }
	end
	xr_effects = { pri_a28_check_zones = original, create_squad = function(_, _, args) waves[#waves + 1] = args[1] end }
	safespawn = { perform_silo = original, get_config = function(key) return ({ radius = 5, duration = 10 })[key] end }
	game_object = { enemy = 2 }
	local rival = body(600, 5, 2)
	local friendly = body(601, 5, 2)
	local function prepare_npc(npc, enemies)
		local se = SE[npc:id()]
		db.storage[npc:id()] = { object = npc }
		function npc:relation(who) return enemies[who:id()] and game_object.enemy or 1 end
		function npc:set_enemy() end
		function npc:set_npc_position(p) self._pos = vector():set(p) end
		function se:can_switch_online(value) self.blocked = not value end
		function se:can_switch_offline(value) self.offline = value end
	end
	prepare_npc(rival, { [500] = true, [501] = true })
	prepare_npc(friendly, { [0] = true })
	local handle = io.open(ROOT .. "scripts/coop_npc_presence.script", "r")
	if handle then handle:close(); load_script("coop_npc_presence").on_game_start() end

	local function check_mode(result, case) check(result, mode .. " " .. case) end
	local function deliver_arrival(peer, id, map)
		local t = { id = id, map = map }
		if mode == "srv_map" then t._peer = peer; peer = 0 end
		deliver({ name = verb, payload = coop_main.encode(t) }, peer)
	end
	local function advance(ms)
		NOW = NOW + ms
		SendScriptCallback("actor_on_update")
	end
	if mode == "none" then
		xr_conditions.distance_to_obj_le(nil, nil, { "local_target", 5 })
		xr_effects.pri_a28_check_zones()
		safespawn.perform_silo()
		check_mode(original_calls == 3, "single player invokes originals")
	elseif mode == "srv_world" then
		check_mode(xr_conditions.distance_to_obj_le(nil, nil, { "far_target", 2 }) == true, "Vices uses the remote map's player record")
		deliver_arrival(1, 1, 2)
		local req, msg = sent(verb)
		check_mode(req and tonumber(req._peer) == 1 and msg.target == 257 and not SE[600].blocked, "SafeSpawn relays to the map without mutating world-server NPCs")
	else
		local function condition(name, radius, target) return xr_conditions[name](nil, nil, { target or "local_target", radius }) end
		check_mode(condition("distance_to_obj_le", 5) == true, "Vices client alone satisfies near")
		check_mode(condition("distance_to_obj_ge", 5) == false, "Vices far requires every same-map player away")
		check_mode(condition("distance_to_obj_le", 4) == false and condition("distance_to_obj_ge", 4) == true and
			condition("dist_to_story_obj_le", 4) == false and condition("dist_to_story_obj_ge", 4) == false, "Vices preserves all four boundaries")
		check_mode(condition("distance_to_obj_le", 3) == false, "Vices ignores the ghost and other-map players")
		if mode == "srv_map" then
			check_mode(condition("dist_to_story_obj_le", 2, "far_target") == true, "Vices uses the remote target's own map")
		end
		local scheme = { object = { inside = function(_, p) return p.x < 6 end }, st = { monster = "boar" },
			is_actor_inside = false, spawned = 0 }
		client._pos = pos(8)
		sr_monster.fake_monster.update(scheme)
		check_mode(scheme.spawned == 0, "sr_monster does not start for the ghost or another map")
		client._pos = pos(4)
		sr_monster.fake_monster.update(scheme)
		sr_monster.fake_monster.update(scheme)
		check_mode(scheme.spawned == 1 and rawequal(db.actor, host), "sr_monster client starts one unchanged sequence")
		xr_effects.pri_a28_check_zones()
		check_mode(#waves == 1 and waves[1] == "pri_a28_heli_mono_add_3", "pri_a28 avoids the occupied zone and scores the actual squad point")
		xr_effects.pri_a28_check_zones()
		check_mode(waves[2] == "pri_a28_heli_mono_add_2", "pri_a28 uses an unspent wave")
		deliver_arrival(1, 1, 2)
		check_mode(SE[600].blocked == true and not SE[601].blocked, "SafeSpawn uses the transport sender's hostile relation and position")
		advance(5000)
		local_friend._pos = pos(5)
		OBJ[600] = nil -- the siloed NPC has gone offline
		deliver_arrival(2, 2, 2)
		deliver_arrival(1, 1, 2) -- replay must not create another operation
		advance(5001)
		check_mode(SE[600].blocked == true, "SafeSpawn overlapping player window keeps the NPC suppressed")
		advance(5000)
		check_mode(SE[600].blocked == false and SE[600].position.y == 0, "SafeSpawn restores the original position once the windows end")
		deliver_arrival(1, 3, 3)
		check_mode(SE[600].blocked == false and log_has("npc_presence_arrival"), "SafeSpawn logs a mismatched map through trust and cannot use it")
		if mode == "hostplay" then
			host._pos = pos(5)
			coop_mods_core.on_actor_respawned()
			advance(1000)
			check_mode(SE[601].blocked == true and sent_count(verb) == 0, "SafeSpawn host respawn uses the same handler locally")
			local saved = {}
			SendScriptCallback("save_state", saved)
			check_mode(saved.coop_npc_presence_silos and saved.coop_npc_presence_silos[601] ~= nil, "SafeSpawn saves original NPC state during a silo")
			SendScriptCallback("on_level_changing")
			check_mode(SE[601].blocked == false and SE[601]:move_offline(), "SafeSpawn restores before changing maps")
			SE[601].blocked = true
			friendly._pos = vec3(5, -200, 0)
			SendScriptCallback("load_state", saved)
			advance(1)
			check_mode(SE[601].blocked == false and friendly:position().y == 0, "SafeSpawn recovers the NPC when a saved silo is loaded")
			MODE, SELF, db.actor = "client", 1, client
			modes.install(facade, "hostplay", { leads_here = function() return false end,
				is_player_mirror = function() return true end, decides_world = function() return false end })
			SendScriptCallback("actor_on_first_update")
			advance(1000)
			local request = sent(verb)
			check_mode(request and request.map == 2 and request.peer == nil, "SafeSpawn client announces a finished appearance without a claimed sender")
		end
	end
end

for _, name in ipairs(modes.names()) do run(name) end
done("npc_presence")
