-- Dev 57 G10-4. Run the adapter through mod entry points and the real Lua event and world-data handlers.
local modes = dofile("tests/lua/support/modes.lua")
local CORPUS = "temp/review/corpus/merged/"
local FFT_EVENT = "mods.wv_fft"
local FFT_REQUEST = "mods.wv_fft_req"
local PARTS_EVENT = "mods.wv_workshop"
local PARTS = "zonekeeper_workshop_stashes"
local BRIDGE = 0x101
local passed, failed = 0, 0

local function check(ok, label)
	if ok then passed = passed + 1 else failed = failed + 1 end
	print((ok and "  ok   " or "  FAIL ") .. label)
end

local function fixture(name, source, env)
	env = setmetatable(env or {}, { __index = _G })
	local chunk = assert(loadstring(source, "@" .. name .. ".script"))
	setfenv(chunk, env)()
	_G[name] = env
	return env
end

local function use_corpus(name, headers, preamble)
	local file = io.open(CORPUS .. name .. ".script", "r")
	if not file then return end -- the review corpus is absent from a clean checkout
	local source = "\n" .. file:read("*a"):gsub("\r\n", "\n") .. "\n"
	file:close()
	local parts = { preamble or "" }
	for _, header in ipairs(headers) do
		local first = assert(source:find("\nfunction " .. header .. "(", 1, true), header)
		local last = assert(source:find("\nend%s*\n", first), header)
		parts[#parts + 1] = source:sub(first + 1, last + 3)
	end
	local chunk = assert(loadstring(table.concat(parts, "\n"), "@" .. name .. ".script"))
	setfenv(chunk, _G[name])()
end

local function setup(name, mirror)
	MODE = name == "none" and "sp" or mirror and "client" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	local actor = make_actor(vec3(10, 0, 0))
	if name == "srv_world" and not mirror then coop.is_dedicated = function() return true end end
	if name == "srv_map" and not mirror then
		coop.is_host = function() return false end
		coop.is_client = function() return true end
		coop.is_map_server = function() return true end
	end
	load_script("coop_main")
	load_script("coop_mode")
	local answers = {
		seat_plays = function(peer) return peer == 1 or peer == 2 or (name == "hostplay" and peer == 0) end,
	}
	if mirror then
		answers.leads_here = function() return false end
		answers.decides_world = function() return false end
		answers.actor_is_player = function() return true end
		answers.is_player_mirror = function() return true end
	end
	modes.install(coop_mode, name, answers)
	load_script("coop_mods_core")
	load_script("coop_economy_core")
	load_script("coop_economy_mdata").on_game_start()
	load_script("coop_trust")
	coop_mods_core.on_game_start()

	local se_name = function(self) return self._sec .. "_" .. self.id end
	local create = alife_create
	local flags, tries = {}, 0
	has_alife_info = function(key) return flags[key] end
	give_info = function(key) flags[key] = true end
	disable_info = function(key) flags[key] = nil end
	alife_create = function(sec, ...)
		tries = tries + 1
		if tries == 2 and FAIL_SECOND_ZONE then return nil end
		local se = create(sec, ...)
		se.name = se_name
		return se
	end
	FAIL_SECOND_ZONE = false
	local fft = fixture("game_fast_travel", [[
		local zone_spawn_version
		function spawn_fast_travel_zones(respawn)
			if respawn and next(spawned_travel_zones) then
				zone_spawn_version = nil
				disable_info("fft_restrictors_spawned")
				for _, entry in pairs(spawned_travel_zones) do alife_release_id(entry.id) end
				spawned_travel_zones = {}
			end
			for loc, data in pairs(fast_travel_restrictors) do
				for _, pos in ipairs(data.zones) do
					local se = alife_create(travel_zone_section, vector():set(unpack(pos)), 0, 8)
					if se then spawned_travel_zones[se:name()] = { id = se.id, loc = loc } end
				end
			end
			give_info("fft_restrictors_spawned")
			zone_spawn_version = release_date
		end
		function actor_on_first_update()
			local_inits = local_inits + 1
			local outdated = (zone_spawn_version or 0) < release_date
			if outdated or not has_alife_info("fft_restrictors_spawned") then spawn_fast_travel_zones(outdated) end
		end
		function save_state(data)
			data.fast_travel_system = {
				spawned_travel_zones = spawned_travel_zones, zone_spawn_version = zone_spawn_version,
				cooldowns = { ft = 81 },
			}
		end
		function load_state(data)
			local fts = data.fast_travel_system
			if not fts then return end
			spawned_travel_zones = fts.spawned_travel_zones or spawned_travel_zones
			zone_spawn_version = fts.zone_spawn_version or zone_spawn_version
		end
		function actor_in_travel_zone()
			for key in pairs(spawned_travel_zones) do
				if db.actor_inside_zones[key] then return true end
			end
			return false
		end
	]], {
		release_date = 20260301, travel_zone_section = "space_restrictor", spawned_travel_zones = {},
		fast_travel_restrictors = { camp = { zones = { { 1, 0, 0 }, { 2, 0, 0 } } } }, local_inits = 0,
		all_travel_types = { ft = true }, td = { ft = {} },
		dl = function() end, vl = function() end,
		get_next_travel_for_type = function() return 81 end,
		get_travel_cfg = function() return { zone_mode = 1 } end,
		campfires_are_bases = function() return false end,
		actor_has_ftzone_permission = function() return true end,
	})
	fft.update_settings = function() fft.local_inits = fft.local_inits + 1 end
	utils_stpk = {
		get_space_restrictor_data = function() return {} end,
		set_space_restrictor_data = function() end,
	}
	use_corpus("game_fast_travel", { "spawn_fast_travel_zones", "actor_on_first_update", "save_state", "load_state",
		"actor_in_travel_zone" }, "local zone_spawn_version")
	db.actor_inside_zones = {}
	RegisterScriptCallback("actor_on_first_update", fft.actor_on_first_update)

	local same_map = spawn("smart_terrain", vec3(13, 0, 0), nil, { offline = true })
	local other_map = spawn("smart_terrain", vec3(10, 0, 0), nil, { offline = true })
	local unplaced = spawn("smart_terrain", vec3(10, 0, 0), nil, { offline = true })
	same_map.m_game_vertex_id, other_map.m_game_vertex_id = 8, 9
	unplaced.m_game_vertex_id = 65535
	game_graph = function()
		return { valid_vertex_id = function(_, id) return id == 8 or id == 9 end,
			vertex = function(self, id)
				assert(self:valid_vertex_id(id), "invalid game vertex")
				return { level_id = function() return id == 9 and 2 or 1 end }
			end }
	end
	SIMBOARD = { smarts_by_names = { nearby_camp = same_map, other_camp = other_map, unplaced = unplaced } }
	smart_terrain = { nearest_to_actor_smart = {} }
	npe_events = setmetatable({ on_near_smart_terrain = function(name, distance)
		local id = smart_terrain.nearest_to_actor_smart.id
		local se = id and alife_object(id)
		return not not (se and se:name() == name and se.position:distance_to(db.actor:position()) < (distance or 50))
	end }, { __index = _G })
	use_corpus("npe_events", { "on_near_smart_terrain" }, "local default_limit_distance = 50")

	local stash, box = spawn("workshop_stash", vec3(10, 0, 0), nil, { id = 800 })
	stash.name = se_name
	box.iterate_inventory_box = box.iterate_inventory
	local part = spawn("bearing", nil, 800, { id = 810, cond = 0.51 })
	spawn("oil", nil, 800, { id = 811 })
	local data = alife_storage_manager.get_state()
	data.workshop_stashes = { [801] = 800 }
	data[PARTS] = { [800] = { { section = "older", condition = 0.2 } } }
	SYS_GetParam = function(_, section, key) return key == "kind" and section ~= "oil" and "i_part" or "i_misc" end
	zone_keeper = setmetatable({ LogItems = function(id)
		local target = level.object_by_id(id)
		if not target then return end
		local items = {}
		target:iterate_inventory_box(function(_, item)
			if SYS_GetParam(0, item:section(), "kind") == "i_part" then
				items[#items + 1] = { section = item:section(), condition = item:condition() }
			end
		end)
		data[PARTS][id] = items
	end, delete_store = function() data[PARTS] = {} end, printdebug = function() end }, { __index = _G })
	box.name = function(self) return self:section() .. "_" .. self:id() end
	use_corpus("zone_keeper", { "LogItems", "delete_store" })
	utils_ui = setmetatable({ UIInfoItem = {
		Pass = function(self, obj) return obj ~= nil end,
		Update = function(self, obj)
			if not self:Pass(obj) or self.id == obj:id() then return end
			self.id = obj:id()
			local items = data[PARTS][800]
			self.workshop_count = #items
			self.refreshes = (self.refreshes or 0) + 1
		end,
	}, get_time = time_global }, { __index = _G })
	use_corpus("utils_ui", { "UIInfoItem:Pass" })

	local reads = 0
	local invbox = { items = { [810] = "bearing" } }
	dotmarks_main = setmetatable({
		cfg = { invboxes = { [800] = invbox }, show_stash_weight = true, weight_colors = { [0] = "default" } },
		is_container_unsearched_stash = function() return invbox.unsearched end,
		get_player_stash_by_id = function() return false end,
		is_invbox_found = function() return invbox.found end,
		is_body_claimed = function(mark) return type(mark) == "table" and mark.claimed end,
		gts = function(key) return key end,
	}, { __index = _G })
	dotmarks_main.init_inventory_box = function() return invbox end
	use_corpus("dotmarks_main", { "init_inventory_box", "is_invbox_found" })
	axr_companions = { get_inventory_weight = function(items)
		local weight = 0
		for _ in pairs(items) do weight = weight + 1 end
		return weight
	end }
	local function count_items(items)
		local count = 0
		for _ in pairs(items) do count = count + 1 end
		return count
	end
	ui_hud_dotmarks = setmetatable({
		st_kg = "kg",
		get_actor_weight_class = function() return 0 end,
		size_table = count_items,
		iterate_any_inventory = function(obj, read)
			reads = reads + 1
			obj:iterate_inventory_box(read)
		end,
	}, { __index = dotmarks_main })
	local hud = ui_hud_dotmarks
	hud.get_inventory_table = function(obj)
		local items = {}
		hud.iterate_any_inventory(obj, function(_, item) items[item:id()] = item:section() end)
		return items, count_items(items)
	end
	hud.update_prompt_weight_string = function(mark)
		if mark.use_pri and mark.is_container then
			mark.use_pri:SetPrompt(nil, nil, mark.has_items and "1.00 kg" or "st_alti_empty")
		end
		mark.weight_string_set = true
		mark.update_weight_now = nil
	end
	use_corpus("ui_hud_dotmarks", { "marker_loop_container_updates", "update_prompt_weight_string", "get_inventory_table" })
	hud.marker_loop_container_updates = function(mark, obj)
		mark.body_claimed = hud.is_body_claimed(mark)
		if not mark.body_claimed then
			if not invbox.items then invbox.items = hud.get_inventory_table(obj, mark.id) end
			mark.num_items = 0
			for _ in pairs(invbox.items) do mark.num_items = mark.num_items + 1 end
			mark.has_items = mark.num_items > 0
		end
		if mark.refresh_container_now or not mark.weight_string_set then
			hud.update_prompt_weight_string(mark)
			mark.refresh_container_now = false
		end
	end

	local file = io.open("gamedata/scripts/coop_mods_world_views.script", "r")
	if file then
		file:close()
		load_script("coop_mods_world_views").on_game_start()
	end

	return {
		actor = actor, fft = fft, data = data, stash = stash, box = box, part = part,
		hud = hud, invbox = invbox, reads = function() return reads end,
	}
end

local function tick(ms)
	NOW = NOW + (ms or 3000)
	SendScriptCallback("actor_on_update")
end

local function events(event)
	local out = {}
	for _, e in ipairs(SENT) do if e.name == event then out[#out + 1] = e end end
	return out
end

local function receive(list, from)
	for _, e in ipairs(list) do deliver(e, from) end
end

local function rows(ctx)
	return ctx.data[PARTS] and ctx.data[PARTS][800] or {}
end

local function box_mark()
	return { id = 800, can_display = true, is_container = true, use_pri = {
		SetPrompt = function(self, _, _, text) self.text = text end,
	} }
end

local function fft_migration(name)
	local owner = setup(name)
	FAIL_SECOND_ZONE = true
	if name == "hostplay" then SendScriptCallback("actor_on_first_update") end
	tick()
	local save = {}
	owner.fft.save_state(save)
	check(#events(FFT_EVENT) == 0 and save.fast_travel_system.zone_spawn_version == nil
		and not next(owner.fft.spawned_travel_zones) and #RELEASED == 1,
		"m21:4 aborts a partial migration before publishing or saving its version")
	FAIL_SECOND_ZONE = false
	tick(10000)
	owner.fft.save_state(save)
	local snapshot, count = events(FFT_EVENT), 0
	for _ in pairs(owner.fft.spawned_travel_zones) do count = count + 1 end
	check(#snapshot > 0 and count == 2 and save.fast_travel_system.zone_spawn_version == 20260301,
		"m21:4 authority retries and publishes the complete versioned list")
	local client = setup(name, true)
	client.fft.load_state({ fast_travel_system = { zone_spawn_version = 20200101 } })
	SendScriptCallback("actor_on_first_update")
	tick()
	check(client.fft.local_inits == 1 and #CREATED == 0 and #RELEASED == 0,
		"m21:4 mirror keeps local initialization without migrating an old save")
	local requests = events(FFT_REQUEST)
	check(#requests == 1 and requests[1].target == 0, "m21:4 a mirror can recover a snapshot missed while joining")
	local zone = next(save.fast_travel_system.spawned_travel_zones) or "missing_zone"
	db.actor_inside_zones[zone] = true
	check(not client.fft.actor_in_travel_zone(), "m21:4 mirror waits for the authority's completed list")
	receive(snapshot, 0)
	client.fft.save_state(save)
	check(#snapshot > 0 and client.fft.actor_in_travel_zone() and save.fast_travel_system.zone_spawn_version == 20260301
		and save.fast_travel_system.cooldowns.ft == 81, "m21:4 received zones immediately feed travel checks and preserve personal state")
	tick(10000)
	check(#events(FFT_REQUEST) == 1, "m21:4 receiving the snapshot stops join queries")
	setup(name)
	local before = sent_count(FFT_EVENT)
	receive(requests, 1)
	check(sent_count(FFT_EVENT) == before, "m21:4 a join query cannot publish an incomplete world")
	tick()
	receive(requests, 1)
	local responses = events(FFT_EVENT)
	check(#responses > 0 and responses[#responses].target == 1, "m21:4 the world answers a late joiner with its completed state")
end

local function npe_local_distance(name)
	local ctx = setup(name, true)
	check(npe_events.on_near_smart_terrain("nearby_camp", 4)
		and not npe_events.on_near_smart_terrain("nearby_camp", 3),
		"m14:5 named smart uses the local actor's position and the stock strict distance limit")
	check(not npe_events.on_near_smart_terrain("other_camp", 50)
		and not npe_events.on_near_smart_terrain("missing", 50), "m14:5 off-map and unknown smarts do not trigger a lesson")
	local ok, near = pcall(npe_events.on_near_smart_terrain, "unplaced", 50)
	check(ok and not near, "m14:5 a smart missing its game graph location does not trigger a lesson")
	ctx.actor._pos = vec3(100, 0, 0)
	check(not npe_events.on_near_smart_terrain("nearby_camp"), "m14:5 proximity follows the observer, independently of the scheduler")
end

local function workshop_same_index(name)
	local map = setup(name)
	tick()
	map.part.parent_id = 0 -- a different player took the indexed part; no UI Close on the decider.
	tick()
	local after_take = events(PARTS_EVENT)
	map.part.parent_id = 800
	OBJ[810]:set_condition(0.76)
	tick()
	local after_put = events(PARTS_EVENT)
	if name == "srv_map" then
		check(#after_put > #after_take and after_put[#after_put].target == 0,
			"m31:7 map sends confirmed inventory of its workshop to the world")
		local world = setup("srv_world")
		OBJ[800] = nil -- no online box at the world owner.
		receive(after_take, 1)
		check(rows(world)[1] and rows(world)[1].section == "older",
			"m31:7 a playing peer cannot attest the map inventory")
		receive(after_take, BRIDGE)
		check(#rows(world) == 0, "m31:7 world merges the empty box reported by its map")
		receive(after_put, BRIDGE)
		check(#rows(world) == 1 and rows(world)[1].condition == 0.76,
			"m31:7 world preserves the confirmed condition without needing an online box")
		tick()
		after_put = events(PARTS_EVENT)
		check(#after_put > 0, "m31:7 reports received before the first world tick still get relayed")
	else
		check(#rows(map) == 1 and rows(map)[1].section == "bearing" and rows(map)[1].condition == 0.76,
			"m31:7 co-op host indexes the confirmed parts and skips non-parts")
		check((function()
			for _, e in ipairs(events("economy.wmd")) do
				if coop_main.decode(e.payload).k == PARTS then return true end
			end
			return false
		end)(), "m31:7 workshop index is registered as world data")
	end
	local player = setup(name, true)
	local tooltip = setmetatable({ timer = NOW - 10, delay = 0 }, { __index = utils_ui.UIInfoItem })
	local displayed = OBJ[810]
	-- The viewer is already hovering over a part while the workshop being described is empty.
	player.data[PARTS][800] = {}
	tooltip:Update(displayed)
	OBJ[800] = nil -- a reader on a different map, or a co-op client out of online range.
	receive(after_put, 0)
	check(#rows(player) == 1 and rows(player)[1].section == "bearing" and rows(player)[1].condition == 0.76,
		"m31:7 observer reads the authority's snapshot even with the box offline")
	tooltip:Update(displayed)
	tooltip:Update(displayed)
	check(tooltip.workshop_count == 1 and tooltip.refreshes == 2, "m31:7 the open part tooltip rebuilds once for the new workshop index")
	zone_keeper.LogItems(800, { "i_part" })
	zone_keeper.delete_store()
	check(rows(player)[1] and rows(player)[1].section == "bearing",
		"m31:7 local workshop callbacks cannot overwrite the authoritative index")
end

local function workshop_two_maps()
	local a = setup("srv_map")
	a.data.workshop_stashes = nil -- a replacement map server can inherit just the previously indexed box.
	tick()
	local from_a = events(PARTS_EVENT)
	check(#from_a > 0, "m31:7 a reloaded map can refresh a previously indexed workshop without the furniture link")

	local b = setup("srv_map")
	local stash, box = spawn("workshop_stash", nil, nil, { id = 900 })
	stash.name = a.stash.name
	box.iterate_inventory_box = box.iterate_inventory
	spawn("spring", nil, 900, { id = 910, cond = 0.88 })
	OBJ[800] = nil
	b.data.workshop_stashes = { [901] = 900 }
	tick()
	local from_b = events(PARTS_EVENT)
	check(#from_b > 0, "m31:7 the other map reports its own workshop")

	local world = setup("srv_world")
	local offline = spawn("workshop_stash", nil, nil, { id = 900, offline = true })
	offline.name = stash.name
	OBJ[800] = nil
	receive(from_b, BRIDGE + 1)
	receive(from_a, BRIDGE)
	tick()
	local relay = events(PARTS_EVENT)
	local reader = setup("srv_map", true)
	OBJ[800] = nil
	receive(relay, 0)
	local ledger = reader.data[PARTS]
	check(ledger[800] and ledger[800][1].section == "bearing" and ledger[900] and ledger[900][1].section == "spring"
		and ledger[900][1].condition == 0.88 and #world.data[PARTS][900] == 1,
		"m31:7 the world merges two maps and relays both indexes to a player on a different map")
end

local function dotmarks_remote_loot(name, mirror)
	local ctx = setup(name, mirror)
	local mark = box_mark()
	SE[811].parent_id = 0
	ctx.hud.marker_loop_container_updates(mark, ctx.box)
	local before = ctx.reads()
	ctx.part.parent_id = 0
	ctx.hud.marker_loop_container_updates(mark, ctx.box)
	check(mark.has_items and ctx.reads() == before, "m03:2 view respects the refresh interval")
	NOW = NOW + 2000
	ctx.hud.marker_loop_container_updates(mark, ctx.box)
	check(not next(ctx.invbox.items) and mark.num_items == 0 and mark.has_items == false
		and mark.use_pri.text:find("st_alti_empty", 1, true), "m03:2 remote loot updates contents, alternate interaction and weight prompt together")
	ctx.part.parent_id = 800
	NOW = NOW + 2000
	mark.can_display = false
	local hidden = ctx.reads()
	ctx.hud.marker_loop_container_updates(mark, ctx.box)
	check(ctx.reads() == hidden, "m03:2 hidden marker does not poll the inventory")
	mark.can_display = true
	ctx.hud.marker_loop_container_updates(mark, ctx.box)
	check(ctx.invbox.items[810] == "bearing" and mark.has_items and mark.num_items == 1
		and mark.use_pri.text:find("1.00 kg", 1, true), "m03:2 remote deposit restores the secondary interaction and weight")
end

local function run(label, f, ...)
	local ok, err = pcall(f, ...)
	if not ok then check(false, label .. ": " .. tostring(err)) end
end

for _, name in ipairs(modes.names()) do
	if name == "none" then
		run("single player", function()
			local ctx = setup(name)
			SendScriptCallback("actor_on_first_update")
			tick()
			check(ctx.fft.local_inits == 1 and #CREATED == 2 and #SENT == 0, "SP: stock zone creation stays local")
			check(not npe_events.on_near_smart_terrain("nearby_camp"), "SP: stock nearest-smart check stays in use")
			zone_keeper.LogItems(800, { "i_part" })
			check(#rows(ctx) == 1 and rows(ctx)[1].section == "bearing", "SP: stock workshop update still runs")
			local mark = box_mark()
			ctx.hud.marker_loop_container_updates(mark, ctx.box)
			NOW = NOW + 2000
			ctx.hud.marker_loop_container_updates(mark, ctx.box)
			check(ctx.reads() == 0, "SP: Dot Marks keeps its stock cache")
		end)
	elseif name == "hostplay" or name == "srv_world" then
		run("FFT " .. name, fft_migration, name)
		run("NPE " .. name, npe_local_distance, name)
		run("Dot Marks " .. name, dotmarks_remote_loot, name, name == "srv_world")
		if name == "hostplay" then run("Workshop Co-op", workshop_same_index, name) end
	else
		run("Workshop Server", workshop_same_index, name)
		run("Workshop two maps", workshop_two_maps)
	end
end

PASSES, FAILS = passed, failed
done("mods_world_views")
