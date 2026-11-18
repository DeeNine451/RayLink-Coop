-- G14-4: run the stock quest entry points and the active GAMMA assault functor.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local TOP = "snitch_top_10_task"
local QUERY, ANSWER = "mods.quest_stock_rank_req", "mods.quest_stock_rank"
local rows, owners, factions, vars, ranking, fresh, cfg, tm
local foreign_community = "actor_bandit"

local function load_quest(name)
	local path = "temp/review/corpus/merged/" .. name .. ".script"
	local source = io.open(path, "r")
	if not source then
		path = "../anomaly-ref/unpacked/scripts/" .. name .. ".script"
		source = assert(io.open(path, "r"), path)
	end
	local chunk = assert(loadstring(source:read("*a"), "@" .. path))
	source:close()
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	setfenv(chunk, env)()
end

local function install_authority(name, set)
	modes.install(coop_mode, name, {
		where = function(peer)
			if name == "hostplay" and peer == 0 then return "here" end
			return rows[peer] and rows[peer].level and set.where(peer) or "joining"
		end,
	})
end

local function fixture(name, set)
	MODE, SELF = name == "none" and "sp" or "host", 0
	coop.is_map_server = function() return name == "srv_map" end
	coop.is_dedicated = function() return name == "srv_world" end
	load_script("coop_main")
	load_script("coop_mods_core")
	load_script("coop_mode")
	load_script("coop_trust")
	local actor = make_actor()
	rows = {
		[1] = { character = 20, level = 5 },
		[2] = { character = 21, level = 5 },
	}
	coop_npc_players = {
		player = function(peer) return rows[peer] end,
		is_player_id = function(id) return id == 0 or id == 20 or id == 21 end,
	}
	owners = { assault_one = 20, assault_two = 21, smart_owner = 21 }
	factions = { [20] = "actor_dolg", [21] = "freedom" }
	coop_faction = {
		group_faction = function() return "stalker" end,
		faction_of_character = function(char)
			if name == "hostplay" then return "stalker" end
			return name == "srv_world" and factions[char] or nil
		end,
	}
	coop_storyline = {}
	actor.character_community = function() return foreign_community end
	character_community = function(who) return who:character_community() end
	IsStalker = function(o, cls) return cls == 123 or (o and o._kind == "stalker") end
	printdbg = printf
	local function ranked(id, section, squad)
		local se = spawn(section or "stalker", nil, nil, { id = id })
		se.clsid = function() return 123 end
		se.alive = function() return true end
		se.group_id = squad or 65535
	end
	ranked(0, "actor")
	ranked(20, "coop_player_avatar")
	ranked(21, "coop_player_avatar")
	ranked(22, "coop_player_avatar") -- saved/disconnected avatar
	ranked(23, "stalker") -- player id check independent of section name
	local is_player = coop_npc_players.is_player_id
	coop_npc_players.is_player_id = function(id) return id == 23 or is_player(id) end
	spawn("squad", nil, nil, { id = 200 })
	for id = 101, 112 do ranked(id, nil, id == 110 and 200 or nil) end
	sim_offline_combat = { task_squads = {} }
	ranking = { 20, 0, 22, 23, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 21 }
	fresh = ranking
	pda = {
		calculate_rankings = function() ranking = fresh end,
		get_coc_ranking_list = function() return ranking end,
		get_rankings_array_size = function() return 100 end,
	}
	xr_effects, xr_conditions, task_functor, task_status_functor = {}, {}, {}, {}
	vars, cfg = {}, {}
	load_var = function(_, key) return vars[key] end
	save_var = function(_, key, value) vars[key] = value end
	local task_class = {
		give_task = function(self, id, npc)
			if id == TOP then xr_effects.setup_top_10_task(db.actor, nil, { id }) end
			vars.given = { id, npc }
			self.task_info[id] = { id = id, stage = 0 }
		end,
	}
	tm = setmetatable({ task_info = {} }, { __index = task_class })
	actor.get_task = function(_, id) return tm.task_info[id] end
	task_manager = {
		CRandomTask = task_class,
		get_task_manager = function() return tm end,
		task_ini = {
			r_string_ex = function(_, id, key) return cfg[id] and cfg[id][key] end,
			section_exist = function(_, id) return id == TOP or id == "prior_guard" end,
		},
	}
	dialogs = { who_is_npc = function(_, npc) return npc end }
	parse_list = function(ini, id, key) return { ini:r_string_ex(id, key) } end
	SIMBOARD = { smarts = {}, squads = {} }
	is_squad_monster = { monster = true }
	simulation_objects = { available_by_id = {} }
	load_quest("tasks_top_10")
	load_quest("tasks_smart_control")
	load_quest("tasks_assault")

	install_authority(name, set)
	coop_main.on_game_start()
	coop_trust.reset_for_test({ default = "refuse" })
	load_script("coop_tasks")
	coop_tasks.on_game_start()
	local saved_owner = coop_tasks.taker_character
	coop_tasks.taker_character = function(id) return owners[id] or saved_owner(id) end
	if coop_quests_stock then
		coop_quests_stock.on_game_start()
		SendScriptCallback("actor_on_first_update")
	end
	return actor
end

local function capture(functor, id, explicit_side)
	local smart = { id = 201, faction_controlled = true, faction = "csky" }
	SIMBOARD.smarts.test_smart = { smrt = smart, squads = {} }
	simulation_objects.available_by_id[201] = true
	cfg[id] = { status_functor_params = "killer", status_functor_smarts = "test_smart",
		capture_faction = explicit_side }
	vars[id] = { is_enemy = true, smart_id = "test_smart" }
	local task = { stage = 0 }
	task_status_functor[functor](task, id)
	return smart.faction, task.stage
end

local function setup(actor)
	xr_effects.setup_top_10_task(actor, nil, { TOP })
	return vars[TOP]
end

local function request_give(peer, native, id)
	id = id or TOP
	tm.task_info[id], vars.given = nil, nil
	if native then
		coop_tasks.host_note(id, "taker", peer)
		tm:give_task(id)
	else
		deliver({ name = "coop_tq", payload = "op=sgive;i=s" .. id }, peer)
	end
	local given = tm.task_info[id] ~= nil
	tm.task_info[id], vars.given = nil, nil
	return given
end

local function check_issue(name)
	check(request_give(2), name .. ": claimant outside the top ten can take the task")
	check(vars[TOP] and vars[TOP][1] == 101 and vars[TOP][10] == 110, name .. ": client give initializes ten NPC targets")
	check(not request_give(1, true), name .. ": engine task issue checks the claimant's rank")
	fresh = { 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 20, 0, 21 }
	check(request_give(1), name .. ": Lua task issue sees a rank change after the offer")
	fresh = { 21, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 20, 0 }
	check(not request_give(2), name .. ": rising into the top ten after the offer blocks Lua issue")
	rows[1].level = nil
	check(not request_give(1), name .. ": issue rereads the claimant's placement during transfer")
	rows[1].level = 6
	check(request_give(1, true), name .. ": a placed claimant can take the engine task on the new map")
	coop_storyline.may_take = function(id) return id ~= "prior_guard" end
	check(not request_give(1, false, "prior_guard"), name .. ": earlier issue guards still apply")
	local stats = coop_trust.status().task_top_10_take
	check(stats and stats.failed == 3, name .. ": issue failures passed through trust")
	coop_trust.reset_for_test({ default = "log" })
	local took = request_give(2)
	stats = coop_trust.status().task_top_10_take
	check(took and stats and stats.failed == 1,
		name .. ": log mode counts a stale offer without refusing it")
end

local function check_world_ranking()
	local core = coop_quests_core
	local prior_home, prior_level = core.at_home, core.with_level_of
	local projected = false
	local function in_view(far, fn, ...)
		local old = projected
		projected = far
		local result = { pcall(fn, ...) }
		projected = old
		if not result[1] then error(result[2], 0) end
		return unpack(result, 2)
	end
	core.with_level_of = function(_, fn, ...) return in_view(true, fn, ...) end
	core.at_home = function(fn, ...) return in_view(false, fn, ...) end
	local calc = pda.calculate_rankings
	pda.calculate_rankings = function()
		calc()
		-- A projected ALife actor can reorder ranks at the cutoff.
		if projected then ranking = { 20, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 21 } end
	end
	coop_trust.reset_for_test({ default = "refuse" })
	check(request_give(1), "server: a far-view give uses the same world ranking as its offer")
	pda.calculate_rankings = calc
	core.at_home, core.with_level_of = prior_home, prior_level
end

local function packet(name, fields)
	return { name = name, payload = coop_main.encode(fields) }
end

local function check_dialog(name, set, actor)
	deliver(packet(QUERY, { peer = 2, rank = 0 }), 1)
	local reply, sent_reply = sent(ANSWER)
	check(reply and reply.place == 1 and sent_reply.target == 1, name .. ": world sends the current place to the transport sender")

	MODE, SELF = "client", 1
	modes.install(coop_mode, name, {
		actor_is_player = function() return true end,
		leads_here = function() return false end,
		decides_world = function() return false end,
		is_player_mirror = function() return true end,
		decider = function() return "other" end,
	})
	fresh, ranking = {}, {}
	local _, snitch = spawn("bar_informator_mlr", vec3(5, 0, 0), nil, { id = 124 })
	get_story_object_id = function(id) return id == "bar_informator_mlr" and snitch:id() or nil end
	SendScriptCallback("actor_on_update")
	local _, request = sent(QUERY)
	check(request and request.target == 0, name .. ": approaching Snitch prefetches the authority's answer")
	check(not tasks_top_10.actor_is_not_top_10(actor, nil), name .. ": an empty mirror does not grant an offer")
	if sent_reply then deliver(sent_reply, 2) end
	check(not tasks_top_10.actor_is_not_top_10(actor, nil), name .. ": a peer cannot supply the eligibility answer")
	if sent_reply then deliver(sent_reply, 0) end
	check(not tasks_top_10.actor_is_not_top_10(actor, nil), name .. ": top-ten player cannot see the offer")
	deliver(packet(ANSWER, { place = 12, map = 5 }), 0)
	check(tasks_top_10.actor_is_not_top_10(actor, nil), name .. ": dialog uses the authority's eligible place")
	rows[1].level = 6
	check(not tasks_top_10.actor_is_not_top_10(actor, nil), name .. ": moving maps invalidates the dialog answer")
	MODE, SELF = "host", 0
	install_authority(name, set)
end

for _, name in ipairs(modes.names()) do
	local actor = fixture(name, modes.set(name))
	if name == "none" then
		local list = setup(actor)
		check(list and #list == 10 and list[1] == 20, "SP: setup keeps the stock ranking")
		check(not tasks_top_10.actor_is_not_top_10(actor, nil), "SP: stock condition sees actor zero")
		tasks_top_10.start_task_top_10(actor, { id = function() return 123 end })
		check(vars.given and vars.given[2] == 123, "SP: stock dialog still gives the task")
		check(capture("assault_task_status_functor", "assault_one") == "bandit", "SP: stock assault reads the local actor")
		check(capture("smart_control_task_status_functor", "smart_owner", "actor_dolg") == "bandit",
			"SP: stock smart-control reads the local actor")
	elseif name == "srv_map" then
		deliver(packet(QUERY, {}), 1)
		check(not sent(ANSWER), "map server: the world ranking request is not answered here")
		check(not setup(actor), "map server: the world task list is not written here")
		check(capture("assault_task_status_functor", "assault_one") == "csky",
			"map server: missing owner faction leaves control unchanged")
	else
		local list = setup(actor)
		check(list and #list == 10 and list[1] == 101 and list[10] == 110,
			name .. ": top-ten setup takes ten NPCs beyond players, offline avatars and actor zero")
		check(sim_offline_combat.task_squads[200], name .. ": eligible target's squad is pinned")
		vars[TOP] = { 101, 22, 20 }
		local existing = { stage = 7 }
		task_status_functor.top_10_task_status_functor(existing, TOP)
		check(existing.stage == 9 and #vars[TOP] == 1 and vars[TOP][1] == 101,
			name .. ": an old save skips player targets without restarting completed stages")
		check_dialog(name, modes.set(name), actor)
		rows[1].level = 5
		fresh = list and { 20, 0, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 21 } or {}
		check_issue(name)
		if name == "srv_world" then check_world_ranking() end
		if name == "hostplay" then
			fresh = { 0, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110 }
			check(not tasks_top_10.actor_is_not_top_10(actor, nil), "co-op: host sees own current rank")
			tasks_top_10.start_task_top_10(actor, nil)
			check(not vars.given, "co-op: own dialog rechecks eligibility at issue")
			fresh = { 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 0 }
			tasks_top_10.start_task_top_10(actor, nil)
			check(vars.given and vars.given[1] == TOP, "co-op: eligible own dialog takes the stock path")
		end

		local side, stage = capture("smart_control_task_status_functor", "smart_explicit", "actor_dolg")
		check(side == "dolg" and stage == 1, name .. ": smart-control normalizes the explicit task side")
		side = capture("smart_control_task_status_functor", "smart_owner")
		check(side == (name == "hostplay" and "stalker" or "freedom"), name .. ": smart-control reads the saved owner")
		local expected = name == "hostplay" and "stalker" or "dolg"
		side, stage = capture("assault_task_status_functor", "assault_one")
		check(side == expected and stage == 1, name .. ": assault selects the first owner's capture side")
		expected = name == "hostplay" and "stalker" or "freedom"
		side, stage = capture("assault_task_status_functor", "assault_two")
		check(side == expected and stage == 1, name .. ": assault selects the second owner's capture side on the same map")
		-- The second owner can stand on another map. His faction still comes from the saved character.
		if name == "srv_world" then
			rows[2].level = 6
			side, stage = capture("assault_task_status_functor", "assault_two")
			check(side == expected and stage == 1, name .. ": assault selects the second owner's capture side across maps")
		end
		check(character_community(actor) == foreign_community and rawget(tasks_assault, "character_community") == nil,
			name .. ": faction substitution stays inside the stock functor call")
	end
end

done("stock quests")
