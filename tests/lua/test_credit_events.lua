-- Dev 57 G9-2. Real adapters, mod handlers and map judge. The test transports events between isolated Lua roles.
local modes = dofile("tests/lua/support/modes.lua")
local merged = "temp/review/corpus/merged/"
local stock = "temp/stock_scripts/scripts/"
local npe_event = "mods.credit_npe_kill"
local silent_event = "mods.credit_silent_kill"
local hit_event = "mods.credit_enemy_hit"
local heli_event = "mods.credit_heli_hit"
local loot_event = "mods.credit_zcp_loot"
local total_pass, total_fail = 0, 0
local function nop() end

local function mod_file(dir, name)
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	setfenv(assert(loadfile(dir .. name .. ".script")), env)()
	return env
end

local function object(id, kind)
	local _, obj = spawn(kind, vec3(0, 0, 0), nil, { id = id, kind = kind })
	db.storage[id] = { object = obj }
	return obj
end

local function fresh(set, self, map, other_here)
	for _, name in ipairs({ "coop_main", "coop_mode", "coop_route", "coop_mods_core", "coop_mods_items",
		"coop_mods_misc", "coop_npc_players", "coop_npc_world", "coop_credit", "coop_credit_events" }) do
		rawset(_G, name, nil)
	end
	MODE = set == "none" and "sp" or self > 0 and "client" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	SELF = self
	coop.is_map_server = function() return set == "srv_map" and self == 0 end
	coop.is_dedicated = function() return set == "srv_world" end
	local seats = { [1] = 500, [2] = 501 }
	if set == "hostplay" then seats[0] = 0 end
	coop.players = function()
		local list = {}
		for peer, id in pairs(seats) do
			list[#list + 1] = { id = peer, avatar_id = peer == self and 0 or id, is_self = peer == self }
		end
		return list
	end
	coop.avatar_of = function(peer) return peer == self and 0 or seats[peer] end
	coop.peer_of_avatar = function(id)
		for peer, avatar in pairs(seats) do
			if id == (peer == self and 0 or avatar) then return peer end
		end
	end
	local names = self > 0 and {
		[0] = seats[self], [78] = 777, [79] = 779, [80] = 780, [81] = 800, [89] = 888, [31] = 300, [32] = 301,
	} or {}
	coop.to_host_id = function(id) return names[id] or id end
	coop.to_local_id = function(id)
		for lid, hid in pairs(names) do if hid == id then return lid end end
		return id
	end
	level.name = function() return map end
	local w = { actor = make_actor(), npc = object(coop.to_local_id(777), "stalker"),
		dog = object(coop.to_local_id(800), "monster"), heli = object(coop.to_local_id(888), "heli"),
		box = object(900, "box"), notifications = {}, bars = {}, kills = {}, sounds = 0, stats = 0 }
	w.player = self == 1 and w.actor or object(500, "stalker")
	w.weapon = object(coop.to_local_id(300), "weapon")
	w.firearm = object(coop.to_local_id(301), "weapon")
	w.player._weapon = w.weapon
	db.actor._weapon = w.weapon
	db.storage[0] = { object = w.actor }
	db.OnlineStalkers = {}
	local methods = getmetatable(w.actor)
	methods.active_item = function(o) return o._weapon end
	methods.best_enemy = nop
	methods.name = methods.section
	methods.weapon_is_silencer = function(o) return o:id() == coop.to_local_id(301) end
	methods.hit = function(o, h)
		o._alive = false
		o._draftsman = h.draftsman
	end
	methods.give_game_news = function(o, title) w.notifications[#w.notifications + 1] = { o:id(), title } end
	level.get_start_time = nop
	level.rain_factor = function() return 0 end
	hit = setmetatable({
		wound = 13, fire_wound = 14, light_burn = 1, burn = 2, strike = 3, shock = 4,
		radiation = 5, telepatic = 6, chemical_burn = 7, explosion = 8,
	}, { __call = function(_, h)
		return { draftsman = h and h.draftsman, type = h and h.type, power = h and h.power }
	end })
	coop_npc_compat = { credit_silent_kill = function() w.stats = w.stats + 1 end }
	ui_options = { get = function(key)
		if key == "video/hud/show_enemy_health" then return w.show_health end
		return true
	end }
	get_hud = function() return {} end
	game_statistics = { actor_statistics = {}, increment_statistic = function() w.stats = w.stats + 1 end }
	strformat = string.format
	AC_ID = 0
	xr_sound = { set_sound_play = function() w.sounds = w.sounds + 1 end }
	smr_debug = { get_log = function() return { info = nop } end }
	smr_amain_mcm = { get_config = function() return true end }
	smr_loot_mcm = { get_config = function(k)
		if k == "send_message" then return w.send_message end
		if k == "repair_minor_spawn" then return true end
		if k == "repair_minor_chance" then return 100 end
		if k == "npc_chance" then return 0 end
	end }
	smr_zzintegration_mcm = { get_config = function() return false end }
	alife_process_item = nop
	ini_sys.r_float_ex = function() return 1 end
	npe_logging = setmetatable({}, { __index = function(_, key)
		return key:match("npe$") and nop or {}
	end })
	for _, name in ipairs({ "npc_on_death_callback", "monster_on_death_callback", "npc_on_hit_callback",
		"monster_on_hit_callback", "heli_on_hit_callback", "npc_on_update", "monster_on_update",
		"physic_object_on_use_callback", "npe_on_log_init", "actor_on_net_destroy", "actor_on_before_death",
		"npe_execution_manager_started" }) do AddScriptCallback(name) end
	mod_file(merged, "npe")
	mod_file(merged, "npe_director")
	mod_file(stock, "gameplay_silent_kills")
	mod_file(merged, "stealth_kill_detection")
	mod_file(merged, "smr_loot")
	mod_file(stock, "ui_enemy_health")
	load_script("coop_main")
	local hbar = ui_enemy_health.hbar
	local timer = CreateTimeEvent
	CreateTimeEvent = function(ev, act, sec, f, ...)
		if f == hbar then
			local bone, id = ...
			w.bars[#w.bars + 1] = { bone, id }
		else
			return timer(ev, act, sec, f, ...)
		end
	end
	load_script("coop_mode")
	modes.live(coop_mode)
	local answers = {}
	if set == "srv_map" and self == 0 and not other_here then
		answers.where = function(peer) return peer == 1 and "here" or "away" end
		answers.decider = function(peer) return peer == 1 and "this" or "other" end
	end
	if self > 0 then
		answers.decides_world = function() return false end
		answers.leads_here = function() return false end
		answers.is_player_mirror = function() return true end
		answers.actor_is_player = function() return true end
		answers.where = function(peer) return peer == self and "here" or "away" end
		answers.decider = function() return "other" end
	end
	modes.install(coop_mode, set, answers)
	coop_mods_core.on_game_start()
	-- The new module sorts before coop_npc_world in the engine's startup scan.
	if coop_credit_events then coop_credit_events.on_game_start() end
	coop_npc_world.on_game_start()
	coop_mods_items.on_game_start()
	coop_mods_misc.on_game_start()
	gameplay_silent_kills.on_game_start()
	ui_enemy_health.on_game_start()
	smr_loot.on_game_start()
	RegisterScriptCallback("npc_on_silent_kill_callback", from_script("ish_kill_tracker", [[
		return function(victim, killer, weapon, melee) record_silent(victim, killer, weapon, melee) end
	]]))
	record_silent = function(v, c, weapon, melee)
		w.kills[#w.kills + 1] = { v:id(), c:id(), weapon:id(), melee }
	end
	-- Give NPE two queued lessons, then use the stock registration and activation functions.
	local function queue_lesson(name)
		local config = coop_mods_core.upvalue(npe_director.get_state, "npeConfig")
		local queue = coop_mods_core.upvalue(npe_director.Register_npe_callbacks, "npeSetsActivationQueue")
		local event = npe.EVENT[name]
		if name == "NPC_KILLED" then
			event = { name = event.name, handler = event.handler, module = event.module }
		end
		config.decks.fixture = config.decks.fixture or { sets = {} }
		config.decks.fixture.sets[name] = { context = { event = event } }
		queue.contexts["fixture/" .. name] = { event = event }
	end
	queue_lesson("NPC_KILLED")
	queue_lesson("MUTANT_KILLED")
	npe_director.Register_npe_callbacks()
	SendScriptCallback("actor_on_first_update")
	return w
end

local function done_role()
	total_pass, total_fail = total_pass + PASSES, total_fail + FAILS
end

local function send_only(name, target, count, label)
	local list = {}
	for _, e in ipairs(SENT) do
		if e.name == name then list[#list + 1] = e end
	end
	local sides = true
	for _, e in ipairs(list) do sides = sides and e.target == target end
	check(#list == count and sides, label)
	return list
end

local function repeat_event(event, from)
	if event then deliver(event, from); deliver(event, from) end
end

local function remote_action(set, separated)
	local label = set .. (separated and " different maps: " or ": ")
	local map = set == "hostplay" and "l01_escape" or "l02_garbage"
	local w = fresh(set, 0, map, not separated)
	SendScriptCallback("npc_on_death_callback", w.npc, w.dog)
	check(#npe_director.get_playableQueue() == 0, label .. "NPE ignores NPC kills on the authority")
	SendScriptCallback("monster_on_death_callback", w.dog, nil)
	SendScriptCallback("npc_on_death_callback", w.npc, w.player)
	SendScriptCallback("npc_on_death_callback", w.npc, w.player)
	SendScriptCallback("monster_on_death_callback", w.dog, w.player)
	local deaths = send_only(npe_event, 1, 2, label .. "NPE sends one event per confirmed player kill")
	check(#npe_director.get_playableQueue() == 0, label .. "remote and environment kills leave the authority's lesson queue alone")

	local stabbed = object(779, "stalker")
	local flags = { ret_value = true }
	SendScriptCallback("npc_on_before_hit", stabbed, { draftsman = w.player, type = hit.wound, power = 1 }, 15, flags)
	check(flags.ret_value == false and not stabbed:alive() and w.stats == 1, label .. "real map judge applies and counts the silent stab")
	SendScriptCallback("npc_on_before_hit", stabbed, { draftsman = w.player, type = hit.wound, power = 1 }, 15, { ret_value = true })
	local shot = object(780, "stalker")
	w.player._weapon = w.firearm
	SendScriptCallback("npc_on_before_hit", shot, { draftsman = w.player, type = hit.fire_wound, power = 1 }, 15, { ret_value = true })
	local missed = object(781, "stalker")
	SendScriptCallback("npc_on_before_hit", missed, { draftsman = w.player, type = hit.fire_wound, power = 1 }, 2, { ret_value = true })
	local stealth = send_only(silent_event, 1, 2, label .. "silent shot or stab produces one packet per confirmed victim")
	check(missed:alive() and w.stats == 2, label .. "a shot the judge declined adds no silent kill")
	check(sent_count(npe_event) == 4, label .. "NPE credits confirmed silent kills without the ordinary death callback")
	check(#w.kills == 0, label .. "authority leaves the remote Kill Tracker entry to the shooter")

	w.show_health = true
	SendScriptCallback("npc_on_hit_callback", w.npc, 0.4, nil, w.player, 4)
	SendScriptCallback("npc_on_hit_callback", w.npc, 0.4, nil, w.player, 4)
	SendScriptCallback("monster_on_hit_callback", w.dog, 0.6, nil, w.player, 5)
	SendScriptCallback("heli_on_hit_callback", w.heli, 0.8, nil, w.player, nil)
	SendScriptCallback("npc_on_hit_callback", w.npc, 0, nil, w.player, 4)
	SendScriptCallback("npc_on_hit_callback", w.npc, 0.4, nil, w.dog, 4)
	local hits = send_only(hit_event, 1, 3, label .. "confirmed humanoid and mutant hits remain distinct")
	local helis = send_only(heli_event, 1, 1, label .. "helicopter hit has its own delivery")
	check(#w.bars == 0, label .. "remote hits leave the authority's bar alone")

	w.send_message = false
	SendScriptCallback("physic_object_on_use_callback", w.box, w.player)
	SendScriptCallback("coop_on_container_opened", 1, w.box:id())
	SendScriptCallback("coop_on_container_opened", 1, w.box:id())
	local loot = send_only(loot_event, 1, 1, label .. "first ZCP bonus roll notifies the opener despite the authority's setting")
	check(#CREATED == 1 and CREATED[1].parent == w.box:id() and #w.notifications == 0,
		label .. "confirmed box is filled once without local news")
	done_role()

	local client = fresh(set, 1, map, true)
	object(80, "stalker")
	client.actor._weapon = client.weapon -- changed since the firearm kill
	client.show_health = false
	db.storage[78].show_health = true
	client.send_message = true
	repeat_event(deaths[1], 2)
	repeat_event(stealth[1], 2)
	repeat_event(hits[1], 2)
	repeat_event(helis[1], 2)
	repeat_event(loot[1], 2)
	check(#npe_director.get_playableQueue() == 0 and #client.kills == 0 and #client.bars == 0 and #client.notifications == 0,
		label .. "transport rejects fabricated notices from a player")
	if separated then
		local current_map = level.name
		level.name = function() return "l03_agroprom" end
		repeat_event(stealth[2], 0)
		repeat_event(hits[1], 0)
		repeat_event(helis[1], 0)
		check(#client.kills == 0 and #client.bars == 0, label .. "old-map targets are not used after the shooter moves")
		level.name = current_map
	end
	for _, e in ipairs(deaths) do repeat_event(e, 0) end
	check(#npe_director.get_playableQueue() == 2, label .. "only the killer activates the two NPE lessons")
	repeat_event(stealth[1], 0)
	check(#client.kills == 0, label .. "silent callback waits for the translated victim")
	object(79, "stalker")
	run_time_events(100)
	repeat_event(stealth[2], 0)
	check(#client.kills == 2 and client.kills[1][1] == 79 and client.kills[1][2] == 0
		and client.kills[1][3] == 31 and client.kills[1][4] == true and client.kills[2][1] == 80
		and client.kills[2][3] == 32 and client.kills[2][4] == false,
		label .. "silent callback receives the local killer, confirmed weapon and melee flag once")
	for i = 1, 2 do repeat_event(hits[i], 0) end
	repeat_event(hits[3], 0)
	check(#client.bars == 2 and client.bars[1][1] == 4 and client.bars[1][2] == 78 and client.bars[2][2] == 78,
		label .. "stock bar gets the translated NPC and respects per-object and HUD settings")
	client.show_health = true
	local storage = db.storage[89]
	db.storage[89] = nil
	repeat_event(helis[1], 0)
	check(#client.bars == 2, label .. "missing helicopter storage cannot display a bar")
	db.storage[89] = storage
	repeat_event(helis[1], 0)
	check(#client.bars == 3 and client.bars[3][2] == 89, label .. "helicopter confirmation displays once with a local ID")
	repeat_event(loot[1], 0)
	check(#client.notifications == 1 and client.notifications[1][1] == 0 and client.sounds == 1
		and client.notifications[1][2] == "st_smr_loot_found_repair", label .. "ZCP checks the opener's own setting and plays one notice")
	done_role()

	local other = fresh(set, 2, separated and "l03_agroprom" or map, true)
	other.show_health, other.send_message = true, true
	for _, events in ipairs({ deaths, stealth, hits, helis, loot }) do
		for _, e in ipairs(events) do repeat_event(e, 0) end
	end
	check(#npe_director.get_playableQueue() == 0 and #other.kills == 0 and #other.bars == 0 and #other.notifications == 0,
		label .. "a second player cannot apply events addressed to the first character")
	done_role()

	local disabled = fresh(set, 1, map, true)
	disabled.send_message = false
	npe_director.Settings.enable = false
	repeat_event(loot[1], 0)
	repeat_event(deaths[1], 0)
	check(#disabled.notifications == 0 and disabled.sounds == 0 and #npe_director.get_playableQueue() == 0,
		label .. "personal ZCP and NPE settings disable the corresponding local effects")
	done_role()
end

for _, set in ipairs(modes.names()) do
	if set == "hostplay" or set == "srv_map" then
		remote_action(set, false)
		if set == "srv_map" then remote_action(set, true) end
	end
	if set == "srv_world" then
		local w = fresh(set, 0, "fake_start", false)
		SendScriptCallback("npc_on_death_callback", w.npc, w.actor)
		SendScriptCallback("heli_on_hit_callback", w.heli, 1, nil, w.actor)
		SendScriptCallback("physic_object_on_use_callback", w.box, w.actor)
		check(sent_count(npe_event) + sent_count(heli_event) + sent_count(loot_event) == 0
			and #npe_director.get_playableQueue() == 0, "world process does not decide any player's map events")
		done_role()
	end
	if set == "hostplay" or set == "none" then
		local w = fresh(set, 0, "l01_escape", true)
		w.show_health, w.send_message = true, true
		SendScriptCallback("npc_on_death_callback", w.npc, w.actor)
		SendScriptCallback("heli_on_hit_callback", w.heli, 1, nil, w.actor)
		SendScriptCallback("physic_object_on_use_callback", w.box, w.actor)
		local expected = set == "hostplay" and 0 or nil
		for _, name in ipairs({ npe_event, loot_event }) do
			local _, event = sent(name)
			if event then
				check(event.target == expected, set .. " self event is addressed to the local player")
				repeat_event(event, 0)
			end
		end
		check(#npe_director.get_playableQueue() == 1, set .. " local player keeps one NPE lesson")
		check(#w.bars == 1, set .. " local player keeps one stock bar")
		check(#w.notifications == 1 and #CREATED == 1,
			set .. " local player keeps one ZCP bonus and notice (items " .. #CREATED .. ", notices " .. #w.notifications .. ")")
		local victim = object(779, "stalker")
		SendScriptCallback("npc_on_before_hit", victim, { draftsman = w.actor, power = 1, type = hit.wound },
			15, { ret_value = true })
		check(not victim:alive() and #w.kills == 1 and w.kills[1][2] == 0 and w.kills[1][4]
			and w.stats == 1 and sent_count(silent_event) == 0, set .. " local silent kill stays on the stock callback and stat path")
		if set == "none" then
			check(sent_count(npe_event) + sent_count(hit_event) + sent_count(heli_event) + sent_count(loot_event) == 0,
				"single player fires no co-op events")
		end
		done_role()
	end
end

PASSES, FAILS = total_pass, total_fail
done("credit_events")
