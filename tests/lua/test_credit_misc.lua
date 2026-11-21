-- Dev 57 G9-6: run the adapters through their installed mod wrappers and transport callbacks.
local modes = dofile("tests/lua/support/modes.lua")
local passed, failed = 0, 0

local function fixture(name, source, values)
	local env = setmetatable(values or {}, { __index = _G })
	_G[name] = env
	local chunk = assert(loadstring(source, "@" .. name .. ".script"))
	setfenv(chunk, env)()
	return env
end

local function setup(which)
	MODE = which == "none" and "sp" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	if which == "srv_map" then
		coop.is_map_server = function() return true end
		coop.is_client = function() return true end
	elseif which == "srv_world" then
		coop.is_dedicated = function() return true end
	end
	local function here(peer)
		if which == "srv_world" or peer == 3 or (which == "srv_map" and peer == 0) then return "away" end
		return "here"
	end
	load_script("coop_main")
	load_script("coop_mode")
	modes.install(coop_mode, which, { where = here, seat_plays = function(peer)
		return peer >= 1 and peer <= 3 or peer == 0 and which == "hostplay"
	end, decider = function(peer) return here(peer) == "here" and "this" or "other" end })
	load_script("coop_mods_core")
	load_script("coop_trust")
	load_script("coop_mods_pdata")
	coop_mods_core.on_game_start()
	local m = {}
	alife_storage_manager = { get_state = function() return m end }
	local actor = make_actor(vec3(100, 0, 0))
	local _, a = spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 500 })
	local _, b = spawn("coop_player_avatar", vec3(26, 0, 0), nil, { id = 501 })
	local _, away = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 502 })
	if which == "srv_world" then OBJ[500], OBJ[501], OBJ[502] = nil, nil, nil end
	coop.players = function()
		return { { id = 0, is_self = true, avatar_id = 0, level = 1 },
			{ id = 1, avatar_id = 500, level = 1 }, { id = 2, avatar_id = 501, level = 1 },
			{ id = 3, avatar_id = 502, level = 2 } }
	end
	coop.avatar_of = function(peer) return ({ [0] = 0, 500, 501, 502 })[peer] end
	coop.peer_of_avatar = function(id) return ({ [0] = 0, [500] = 1, [501] = 2, [502] = 3 })[id] end
	coop_npc_players = { active = coop.is_active, self_peer = coop.self_id, peer_of = coop.peer_of_avatar }
	load_script("coop_credit").on_game_start()
	local levels = { [1] = "l01_escape", [2] = "l02_garbage" }
	level.name = function() return levels[1] end
	local original_alife = alife
	alife = function()
		local sim = original_alife()
		sim.level_name = function(_, id) return levels[id] end
		return sim
	end
	local function event(verb, data, from)
		coop_main.on_event("mods." .. verb, coop_main.encode(data), from)
	end
	local function tick()
		NOW = NOW + 31000
		SendScriptCallback("actor_on_update")
	end
	return m, actor, a, b, away, event, tick
end

local function radio(which, m, tick)
	local goodwill = { [0] = 0, [500] = 260, [501] = 30, [502] = 0 }
	local stock_checks, consumed, stock_actor = 0, {}, nil
	local storm, spawn_faction, helmet = false, nil, nil
	relation_registry = { community_goodwill = function(_, id) return goodwill[id] or 0 end }
	coop_reputation = { goodwill_of = relation_registry.community_goodwill }
	item_radio = { RF_targets = {}, RF_stashes = {}, add_target = function() end }
	coop_tasks = { recipient_body = function(id)
		if id == 500 then return {
			object = function(_, section) return section == "good_psy_helmet" and {} or nil end,
			character_community = function() return "csky" end,
		} end
	end }
	local tb = fixture("tb_rf_receiver_packages", [[
		function tb_radio_thing()
			if GetEvent("surge", "state") or GetEvent("underground") then return false end
			local row = table.remove(tb_package_queue, 1)
			observe_spawn(row, get_actor_true_community(), db.actor:object("good_psy_helmet"))
			tb_package_active = true
			db.actor:give_game_news("RF", "test package", row[2])
			return true
		end
	]], {
		tb_factions = { "stalker" }, tb_relations = { stalker = { 0, "stalker_icon" } },
		tb_relation_diff = 250, tb_package_queue = {}, tb_package_active = true,
		GetEvent = function(name) return name == "underground" or storm end,
		observe_spawn = function(row, faction, has_helmet)
			consumed[#consumed + 1] = row
			spawn_faction, helmet = faction, has_helmet
		end,
		checkrelationchange = function()
			stock_checks = stock_checks + 1
			stock_actor = relation_registry.community_goodwill("stalker", 0)
		end,
	})
	load_script("coop_mods_radio").on_game_start()
	tb.tb_relations.stalker[1] = 400 -- as if the legacy host-only threshold was read from a save
	tb.checkrelationchange()
	tick()
	if which == "none" then
		check(stock_checks == 1 and stock_actor == 0 and #tb.tb_package_queue == 0, "RF SP keeps the stock goodwill check")
	elseif which == "srv_map" then
		check(stock_checks == 0 and #tb.tb_package_queue == 0, "RF map owner does not run world goodwill")
	else
		local first = tb.tb_package_queue[1]
		check(first and first[1] == "l01_escape" and first.character == 500 and first[2] == "stalker_icon",
			"RF queues the client who crossed the goodwill threshold")
		goodwill[502] = which == "srv_world" and 300 or 0
		goodwill[501] = 250
		tick()
		local by_character = {}
		for _, entry in ipairs(tb.tb_package_queue) do by_character[entry.character or -1] = entry end
		check(by_character[501] and by_character[501][1] == "l01_escape", "RF tracks the same faction separately per character")
		if which == "srv_world" then
			check(by_character[502] and by_character[502][1] == "l02_garbage", "RF world uses the remote roster map without a local actor")
		end
		SendScriptCallback("save_state", m)
		SendScriptCallback("load_state", m)
		local count = #tb.tb_package_queue
		tick()
		check(count > 0 and #tb.tb_package_queue == count, "RF does not requeue the same goodwill after load")
		tb.tb_package_active = false
		storm = true
		tick()
		check(#consumed == 0 and #tb.tb_package_queue == count, "RF keeps the waiting entry through a surge")
		storm = false
		tick()
		check(#consumed == 1 and consumed[1].character == 500, "RF drains its shared queue in order")
		local news, envelope = sent("mods.g96_rf_package")
		check(spawn_faction == "csky" and helmet and news.m == "test package" and envelope.target == 1,
			"RF uses the queued player's gear and faction, and addresses the spawn notice to that player")
	end
end

local function misc(which, m, actor, a, b, away, event, tick)
	local ranks, recipient, shared, stock_scans, fades = {}, 0, {}, 0, 0
	coop_tasks = { with_character = function(cid, fn, ...)
		local previous = recipient
		recipient = cid
		fn(...)
		recipient = previous
	end }
	game_statistics = { increment_rank = function(n) ranks[recipient] = (ranks[recipient] or 0) + n end }
	game.translate_string = function(s) return s end
	actor_menu = { set_fade_msg = function() fades = fades + 1 end }
	give_info = function(s) shared[s] = true end
	has_alife_info = function(s) return shared[s] == true end
	local target = "test_spot"
	shared[target] = true
	get_story_object_id = function(name) return name == target and 900 or nil end
	local _, point = spawn("story_point", vec3(0, 0, 0), nil, { id = 900 })
	db.storage[900] = { object = point }
	local pda = fixture("pda", [[
		local primary_objects_tbl = { { target = "test_spot", hint = "st_test_spot" } }
		local distance_tbl = { l01_escape = 20 }
		function discover_spots() original(primary_objects_tbl, distance_tbl) end
	]], { original = function() stock_scans = stock_scans + 1 end, fill_primary_objects = function() end })

	local shown, stock_medkit = 0, 0
	dynamic_news_helper = { send_tip = function() shown = shown + 1 end }
	local medkit = fixture("xr_eat_medkit", [[
		local _max_strings = 1
		function broadcast(npc) original(npc, _max_strings) end
	]], { original = function() stock_medkit = stock_medkit + 1 end })
	local _, npc = spawn("stalker", vec3(0, 0, 0), nil, { id = 910, kind = "stalker" })
	function npc:character_community() return self._comm or "stalker" end
	function npc:character_name() return "Medic" end
	function npc:character_icon() return "ui_test_medic" end

	local cleared_stock = 0
	nimbleclearinventory = { npc_whitelist = { nimble = true }, release_itms = function() cleared_stock = cleared_stock + 1 end }
	local _, corpse = spawn("nimble", vec3(5, 0, 0), nil, { id = 920 })
	corpse._kind, corpse._alive = "stalker", false
	local function loot(id)
		return (spawn("loot", vec3(5, 0, 0), corpse:id(), { id = id }))
	end
	loot(921)
	corpse.iterate_ruck = corpse.iterate_inventory

	local adapter = io.open("gamedata/scripts/coop_credit_misc.script", "r")
	if adapter then
		adapter:close()
		load_script("coop_credit_misc").on_game_start()
	end
	if which == "none" then
		pda.discover_spots() medkit.broadcast(npc) nimbleclearinventory.release_itms()
		check(stock_scans == 1 and stock_medkit == 1 and cleared_stock == 1,
			"SP delegates PDA, medkit and Nimble to the original functions")
		return
	end

	if which == "srv_world" then
		event("g96_pda_fact", { c = 500, s = target }, 1)
		check(ranks[500] == nil, "PDA rejects a playing peer posing as a map reporter")
		event("g96_pda_fact", { c = 500, s = target }, 0x100)
		event("g96_pda_fact", { c = 500, s = target }, 0x108)
		check(ranks[500] == nil, "PDA rejects attestations outside the reserved bridge range")
		event("g96_pda_fact", { c = 500, s = target }, 0x101)
		SendScriptCallback("save_state", m)
		SendScriptCallback("load_state", m)
		event("g96_pda_fact", { c = 500, s = target }, 0x101)
		event("g96_pda_fact", { c = 502, s = target }, 0x102)
		check(ranks[500] == 10 and ranks[502] == 10 and not ranks[0], "PDA world rewards each confirmed character once on different maps")
	else
		pda.discover_spots() pda.discover_spots()
		if which == "hostplay" then
			check(ranks[500] == 10 and not ranks[501] and not ranks[502], "PDA shared unlock does not steal a local character's rank")
			b._pos = vec3(4, 0, 0)
			pda.discover_spots() pda.discover_spots()
			check(ranks[500] == 10 and ranks[501] == 10 and shared[target], "PDA two personal visits give one +10 each")
			b._pos = vec3(26, 0, 0)
		else
			local t = sent("mods.g96_pda_fact")
			check(t and tonumber(t.c) == 500 and t.s == target and sent_count("mods.g96_pda_fact") == 1,
				"PDA map confirms the nearby player only")
		end
		check(coop_mods_pdata.owns("coop_credit_pda_visits"), "PDA personal visits travel with pdata")
	end

	if which == "hostplay" or which == "srv_map" then
		medkit.broadcast(npc)
		local t, row = sent("mods.g96_medkit")
		check(t and row.target == 1 and sent_count("mods.g96_medkit") == 1 and shown == 0 and stock_medkit == 0,
			"medkit notifies the nearby real player without a host, ghost, distant or other-map notice")
		if which == "hostplay" then actor._pos = vec3(25, 0, 0) end
		medkit.broadcast(npc)
		check(shown == (which == "hostplay" and 1 or 0), "medkit displays locally only to a real host within 25 m")
		npc._comm = "monolith"
		medkit.broadcast(npc)
		check(sent_count("mods.g96_medkit") == 2, "medkit preserves the excluded factions")

		local function nimble_failed()
			local row = coop_trust.status().g96_nimble_open
			return row and row.failed or 0
		end
		corpse._alive = true
		SendScriptCallback("coop_on_container_opened", 1, corpse:id())
		check(SE[921] ~= nil, "Nimble leaves a living NPC alone")
		corpse._alive = false
		corpse._sec = "ordinary"
		local before = nimble_failed()
		SendScriptCallback("coop_on_container_opened", 1, corpse:id())
		check(SE[921] ~= nil and nimble_failed() == before,
			"Nimble leaves an unlisted corpse alone: an honest search is no trust failure")
		local _, box = spawn("inventory_box", vec3(5, 0, 0), nil, { id = 925, kind = "box" })
		before = nimble_failed()
		SendScriptCallback("coop_on_container_opened", 1, box:id())
		check(nimble_failed() == before, "Nimble raises no trust failure for an opened box")
		corpse._sec = "nimble"
		before = nimble_failed()
		SendScriptCallback("coop_on_container_opened", 2, corpse:id())
		SendScriptCallback("coop_on_container_opened", 3, corpse:id())
		check(SE[921] ~= nil and nimble_failed() == before + 2,
			"Nimble leaves its corpse alone and flags the opener who is far or away")
		SendScriptCallback("coop_on_container_opened", 1, corpse:id())
		check(SE[921] == nil, "Nimble clears the listed corpse on its map owner without a GUI")
		if which == "hostplay" then
			loot(922)
			actor._pos = vec3(5, 0, 0)
			ui_inventory = { GUI = { mode = "loot", GetPartner = function() return corpse end } }
			corpse._sec = "ordinary"
			before = nimble_failed()
			nimbleclearinventory.release_itms()
			check(SE[922] ~= nil and nimble_failed() == before and cleared_stock == 0,
				"the host's own loot of an ordinary corpse is no Nimble trust case")
			corpse._sec = "nimble"
			nimbleclearinventory.release_itms()
			check(SE[922] == nil and cleared_stock == 0, "Nimble host's own loot window calls the same checks")
		end

		MODE, SELF = "client", 1
		coop.is_map_server = nil
		modes.install(coop_mode, "hostplay", { leads_here = function() return false end,
			decides_world = function() return false end, is_player_mirror = function() return true end })
		local own_shown = shown
		deliver(row, 2)
		check(shown == own_shown, "medkit ignores a forged player notice")
		deliver(row, 0)
		check(shown == own_shown + 1, "medkit renders the addressed notice on its recipient")
		level.name = function() return "l02_garbage" end
		deliver(row, 0)
		check(shown == own_shown + 1, "medkit ignores a delayed notice after a map change")

		event("g96_pda_seen", { c = 501, s = target }, 0)
		check(fades == 0, "PDA ignores another character's visit feedback")
		event("g96_pda_seen", { c = 500, s = target }, 0)
		event("g96_pda_seen", { c = 500, s = target }, 0)
		check(fades == 1 and m.coop_credit_pda_visits[target], "PDA records and displays an addressed visit once")
		m.coop_mods_pdata = { ["500"] = { d = { coop_credit_pda_visits = { [target] = true } } } }
		coop_mods_pdata.apply_loaded(m)
		event("g96_pda_seen", { c = 500, s = target }, 0)
		check(fades == 1 and m.coop_credit_pda_visits[target], "PDA restores the personal visit via pdata")
	end
end

for _, which in ipairs(modes.names()) do
	local m, actor, a, b, away, event, tick = setup(which)
	radio(which, m, tick)
	misc(which, m, actor, a, b, away, event, tick)
	passed, failed = passed + PASSES, failed + FAILS
end
print(string.format("credit_misc: %d passed, %d failed", passed, failed))
if failed > 0 then error("credit_misc FAILED") end
