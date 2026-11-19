-- G18-4 (s38:5): stock timer and movement under the S4 answer sets, with real G18-3 target records.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function load_fixture(name, paths, fields)
	for _, dir in ipairs(paths) do
		local file = io.open(dir .. name .. ".script", "rb")
		if file then
			local src = file:read("*a")
			file:close()
			local m = setmetatable(fields or {}, { __index = _G })
			_G[name] = m
			setfenv(assert(loadstring(src, "@gamedata/scripts/" .. name .. ".script")), m)()
			return m
		end
	end
	error("fixture missing: " .. name)
end

local function run(mode)
	MODE = mode == "none" and "sp" or "host"
	local map_authority = mode == "srv_map"
	local world_authority = mode == "srv_world"
	local host = mode == "hostplay" or mode == "none"
	local my_map = host or map_authority
	local a_id, b_id = host and 0 or 101, 102
	local a_peer, b_peer = host and 0 or 1, 2
	local here = { [a_peer] = my_map, [b_peer] = my_map }
	local joining = {}
	local a, b = { x = 0, gv = 10, lv = 110 }, { x = 100, gv = 11, lv = 111 }
	local names = { [1] = "l01_escape", [2] = "l02_garbage", [3] = "l05_bar", [9] = "fake_start" }
	local maps = { [10] = 1, [11] = 1, [20] = 2, [30] = 3, [90] = 9 }
	local se, objects = {}, {}
	local function body(id, coords)
		local s = setmetatable({ id = id }, { __index = function(_, k)
			if k == "position" then return vec3(coords.x, 0, 0) end
			if k == "m_game_vertex_id" then return coords.gv end
			if k == "m_level_vertex_id" then return coords.lv end
		end })
		local o = {
			id = function() return id end,
			position = function() return s.position end,
			game_vertex_id = function() return coords.gv end,
			level_vertex_id = function() return coords.lv end,
		}
		se[id], objects[id] = s, o
		return o
	end
	body(a_id, a)
	body(b_id, b)
	local own = host and objects[a_id] or body(0, { x = 0, gv = world_authority and 90 or 10, lv = 900 })
	if world_authority then objects[a_id], objects[b_id] = nil, nil end
	db = { actor = own, storage = {} }
	level.object_by_id = function(id) return objects[id] end
	level.name = function() return world_authority and "fake_start" or "l01_escape" end
	alife_object = function(id) return se[id] end
	alife = function()
		return { actor = function() return se[0] end, level_name = function(_, id) return names[id] end }
	end
	game_graph = function()
		return {
			valid_vertex_id = function(_, gv) return maps[gv] ~= nil end,
			vertex = function(_, gv) return { level_id = function() return assert(maps[gv]) end } end,
		}
	end
	coop.is_host = function() return host or world_authority end
	coop.is_client = function() return map_authority end
	coop.peer_of_avatar = function(id)
		if id == a_id then return a_peer end
		if id == b_id then return b_peer end
	end
	coop.players = function()
		return { { id = a_peer, avatar_id = a_id, is_self = host }, { id = b_peer, avatar_id = b_id } }
	end
	local function where(peer)
		if joining[peer] then return "joining" end
		return here[peer] and "here" or "away"
	end

	local ini = ini_file
	ini_file = function(path)
		if path ~= "plugins\\bounty_squad.ltx" then return ini(path) end
		local rows = { safe_levels = { "fake_start", "l05_bar" }, safe_smarts = { "esc_smart_terrain_2_12" },
			faction_bounty_squads = { { "bandit", "bandit_sim_squad_alpha" } } }
		return {
			line_count = function(_, key) return #(rows[key] or {}) end,
			r_line_ex = function(_, key, i)
				local row = rows[key][i + 1]
				if type(row) == "table" then return true, unpack(row) end
				return true, row, ""
			end,
		}
	end
	SIMBOARD = { smarts_by_names = { esc_smart_terrain_2_12 = { m_game_vertex_id = 10, position = vec3(0, 0, 0) } } }
	utils_data = { CTime_to_table = function(t) return t end }
	game.get_game_time = function() return {} end
	CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
	clsid = { script_actor = 1, online_offline_group_s = 2, smart_terrain = 3 }
	local actor_target = {
		clsid = function() return clsid.script_actor end,
		position = own:position(),
		-- The stock actor on the host, or the compatibility fallback to the first player on the map server.
		get_location = function() return vec3(a.x, 0, 0), a.lv, a.gv end,
	}
	simulation_objects = {
		is_on_the_same_level = function(s1, s2) return maps[s1.m_game_vertex_id] == maps[s2.m_game_vertex_id] end,
		get_server_entity = function(id) if id == 0 then return actor_target end end,
	}

	local cls = {}
	function cls:section_name() return self.section end
	function cls:get_current_task()
		if self.assigned_target_id == 0 then return CALifeSmartTerrainTask(own:game_vertex_id(), own:level_vertex_id()) end
		return CALifeSmartTerrainTask(self.m_game_vertex_id, self.m_level_vertex_id)
	end
	function cls:update()
		-- The offline brain consumes the previous task before the stock Lua update picks an assignment.
		self.offline_step = self:get_current_task()
		if self.scripted_target == "actor" then self.assigned_target_id = 0 end
	end
	sim_squad_scripted = { sim_squad_scripted = cls }
	local section = "bandit_sim_squad_alpha"
	local function squad(id)
		local s = setmetatable({ id = id, section = section, scripted_target = "actor", rush_to_target = true,
			assigned_target_id = 0, current_target_id = 0, current_action = 0,
			m_game_vertex_id = 10, m_level_vertex_id = 710 }, { __index = cls })
		se[id] = s
		return s
	end
	local squad_a, squad_b, unrelated = squad(201), squad(202), squad(203)
	unrelated.scripted_target = "some_smart"
	local legacy = squad(204)
	local old_id = 205
	se[old_id] = { section_name = function() return "replacement" end }

	local stock = load_fixture("sim_squad_bounty", {
		"temp/review/corpus/merged/", "../anomaly-ref/unpacked/scripts/", "temp/stock_scripts/scripts/",
	})
	local reach = {}
	reach.class = function(name) return function() reach[name] = {} end end
	reach.vector = function() return { set = function(_, x, y, z) return vec3(x, y, z) end } end
	load_fixture("xr_reach_task", { "temp/review/corpus/merged/", "../anomaly-ref/unpacked/scripts/" }, reach)
	move = { stand = "stand", walk = "walk", run = "run" }
	look = { path_dir = "path" }
	anim = { free = "free", danger = "danger" }
	game_object = { level_path = "level", game_path = "game" }
	xr_conditions = { surge_started = function() return false end }
	utils_obj = { send_to_nearest_accessible_vertex = function() end }
	character_community = function() return "bandit" end
	local function commander_step(s)
		local npc = {
			id = function() return 301 end,
			is_talking = function() return false end,
			set_sight = function() end,
			game_vertex_id = function() return 10 end,
			set_path_type = function() end,
			set_dest_game_vertex_id = function(self, gv) self.dest = gv end,
			set_desired_position = function(self, pos) self.dest = pos.x end,
			position = function() return vec3(100, 0, 0) end,
			set_mental_state = function() end,
			set_movement_type = function() end,
		}
		db.storage[npc:id()] = {}
		local action = setmetatable({ object = npc, fake_target = function() end }, { __index = reach.action_reach_task_location })
		return action:commander_execute(s), npc
	end

	AddScriptCallback("on_game_load")
	AddScriptCallback("server_entity_on_unregister")
	load_script("coop_main")
	load_script("coop_mods_core")
	modes.install(load_script("coop_mode"), mode, { where = where })
	load_script("coop_route").install()
	load_script("coop_bounty").on_game_start()
	local adapter = _G.coop_bounty_orders -- absent in the red run; the harness loads it by name when present
	if adapter then adapter.on_game_start() end
	stock.on_game_start()
	if map_authority then legacy.section = "older_bounty_section" end
	local data = { bounty_squad = { active_squads = { [legacy.id] = legacy.section, [old_id] = section } } }
	if mode ~= "none" and not map_authority then
		data.coop_bounty = { c = { [a_id] = { s = { [squad_a.id] = section } }, [b_id] = { s = { [squad_b.id] = section } } } }
	end
	SendScriptCallback("load_state", data)
	SendScriptCallback("on_game_load")
	local function tick()
		local e = assert(TIMEEV["cycle:bounty_squad_state"], "missing stock state timer")
		return e.f(unpack(e.p))
	end
	local function hunting(s) return s.scripted_target == "actor" and s.rush_to_target == true end
	local function standing_down(s) return s.scripted_target == nil and s.rush_to_target == false end

	if mode == "none" then
		tick()
		check(standing_down(legacy), "single player: stock safe smart still stops the hunter")
		a.x = 100
		tick()
		check(hunting(legacy), "single player: stock restarts the hunt outside the safe smart")
		legacy:update()
		local _, npc = commander_step(legacy)
		check(npc.dest == 100, "single player: stock commander still follows the actor")
		return
	end

	if map_authority then
		check(coop_bounty.target_of(squad_b.id) == nil and stock.get_active_squads()[squad_b.id] == nil,
			"map startup: the arriving bounty squad has neither a local binding nor a stock record")
		local task = squad_a:get_current_task()
		check(task.lv == 710, "map startup: a native task queried before the first Lua update stays with the squad")
		local _, before_update = commander_step(squad_b)
		check(before_update.dest == nil, "map startup: commander before the first squad update has no player destination")
		squad_b:update()
		local _, npc = commander_step(squad_b)
		check(standing_down(squad_b) and npc.dest == nil, "map startup: the hunter never pursues the first player")
		legacy:update()
		check(standing_down(legacy), "map startup: the active-squads record also identifies a hunter")
		local other = squad(206)
		other.section = "not_a_bounty_section"
		other:update()
		local _, stock_npc = commander_step(other)
		check(hunting(other) and stock_npc.dest == a.x, "map startup: unrelated actor orders still use the stock path")
		coop_main.on_event("mods.bounty_t", coop_main.encode({ g = 1, i = 1, k = 2, n = 65 }), 0)
		squad_b:update()
		check(standing_down(squad_b), "map startup: a malformed snapshot does not end the hold")
		coop_main.on_event("mods.bounty_t", coop_main.encode({ g = 1, i = 1, k = 2, n = 1, s1 = squad_a.id, c1 = a_id }), 0)
		squad_b:update()
		legacy:update()
		local _, partial_npc = commander_step(squad_b)
		check(standing_down(squad_b) and standing_down(legacy) and partial_npc.dest == nil,
			"map startup: a partial generation cannot restore omitted orders")
		coop_main.on_event("mods.bounty_t", coop_main.encode({ g = 1, i = 2, k = 2, n = 1, s1 = squad_b.id, c1 = b_id }), 0)
		squad_b:update()
		legacy:update()
		local _, bound_npc = commander_step(squad_b)
		local _, legacy_npc = commander_step(legacy)
		check(hunting(squad_b) and bound_npc.dest == 11, "map startup: the snapshot releases the hunter to its own second player")
		check(hunting(legacy) and legacy_npc.dest == a.x, "map startup: an omitted legacy hunter resumes its prior stock order")
	end

	squad_a:update()
	squad_b:update()
	if not map_authority then tick() end
	check(standing_down(squad_a), mode .. ": entering a safe smart stops that target's hunters")
	check(hunting(squad_b), mode .. ": another player's hunters keep their pursuit on the same map")
	check(squad_a.assigned_target_id ~= 0 and squad_a.current_target_id ~= 0 and squad_a.offline_step.lv == 710,
		mode .. ": stops the cached pursuit before the simulation reads it")
	check(unrelated.scripted_target == "some_smart", mode .. ": unrelated squad retains its order")
	if not map_authority then
		check(standing_down(legacy) and stock.get_active_squads()[old_id] == nil, mode .. ": stock timer still handles legacy squads and stale ids")
	end
	if my_map then
		local _, npc = commander_step(squad_b)
		check(npc.dest == 11, mode .. ": online commander walks to the bound second player's vertex")
		check(simulation_objects.get_server_entity(0) == actor_target, mode .. ": actor lookup outside a pursuit retains stock behavior")
	end

	a.x = 40
	squad_a:update()
	check(hunting(squad_a), mode .. ": leaving the strict 40 m radius resumes the hunt")
	if not host then
		a.x, a.gv, a.lv = 0, 20, 120
		here[a_peer], objects[a_id] = false, nil
		squad_a:update()
		check(hunting(squad_a), mode .. ": safe smart at the same coordinates on another map does not stop a hunt")
		a.gv, a.lv = 30, 130
		squad_a:update()
		squad_b:update()
		check(standing_down(squad_a) and hunting(squad_b), mode .. ": only the target on a safe map stands down across two maps")
	end
	joining[b_peer] = true
	squad_b:update()
	check(standing_down(squad_b), mode .. ": a target who is still joining has no pursuit")
	joining[b_peer] = false
	here[b_peer], b_peer = nil, 3 -- the returning player can get a different transport peer
	here[b_peer] = my_map
	squad_b:update()
	check(coop_bounty.target_of(squad_b.id) == b_id and hunting(squad_b),
		mode .. ": pursuit resumes for the same character after reconnecting under a new peer")

	-- As in the prior review probe, reuse the target id while the squad still exists.
	if map_authority then
		SendScriptCallback("server_entity_on_unregister", se[b_id], "se_stalker")
		check(coop_bounty.target_of(squad_b.id) == b_id, "map handoff: removing just the local body keeps the world's binding")
		coop_main.on_event("mods.bounty_t", coop_main.encode({ g = 2, i = 1, k = 1, n = 1, s1 = squad_a.id, c1 = a_id }), 0)
	else
		SendScriptCallback("server_entity_on_unregister", se[b_id], "se_stalker")
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		local t = sent("mods.bounty_t")
		check(t and t.n == 1 and t.s1 == squad_a.id and t.c1 == a_id,
			mode .. ": authoritative character removal publishes the remaining binding")
		local saved = {}
		SendScriptCallback("save_state", saved)
		check(saved.coop_bounty and saved.coop_bounty.c[b_id] == nil,
			mode .. ": the removed character has no saved bounty record")
	end
	here[b_peer], b_peer = nil, 4
	here[b_peer] = my_map
	body(b_id, { x = 260, gv = 11, lv = 116 })
	if not map_authority then tick() end
	squad_b:update()
	check(coop_bounty.target_of(squad_b.id) == nil and standing_down(squad_b)
		and squad_b.assigned_target_id ~= 0 and squad_b.current_target_id ~= 0,
		mode .. ": reusing the character id leaves the old hunters without a player order")
	check(coop_bounty.target_of(squad_a.id) == a_id, mode .. ": revocation keeps the other player's binding")
end

for _, mode in ipairs(modes.names()) do run(mode) end
print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
