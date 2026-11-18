-- G1-3: real corpus save/load functions, shared pdata transport, isolated mode cases.
local native_loadstring, native_loadfile = loadstring, loadfile
local total_passed, total_failed = 0, 0

local function scenario(which)
	MODE = (which == "hostplay_client" or which == "srv_client") and "client" or "host"
	if which == "none" then MODE = "sp" end
	dofile("tests/lua/support/stubs_mods.lua")
	dofile("tests/lua/support/mod_source.lua")
	if which == "srv_map" then coop.is_map_server = function() return true end end
	if which == "srv_world" then coop.is_dedicated = function() return true end end
	make_actor()
	local mode_files = io.open("tests/lua/support/modes.lua", "r")
	if mode_files then
		mode_files:close()
		local modes = dofile("tests/lua/support/modes.lua")
		local set = ({ hostplay_client = "hostplay", srv_client = "srv_map", hostplay = "hostplay",
			srv_world = "srv_world", srv_map = "srv_map", none = "none", srv_no_ui = "srv_world" })[which]
		local overrides
		if MODE == "client" then
			overrides = { actor_is_player = function() return true end, is_player_mirror = function() return true end,
				leads_here = function() return false end, decides_world = function() return false end,
				decider = function() return "other" end }
		end
		modes.install(load_script("coop_mode"), set, overrides)
		check(coop_mode.actor_is_player() == (set == "none" or set == "hostplay" or MODE == "client"),
			which .. ": S4 mode answer set installed")
	end
	if which == "srv_no_ui" then
		coop.is_dedicated = function() return true end
		load_script("coop_main").on_game_start()
		load_script("coop_mods_core").on_game_start()
		local P = load_script("coop_mods_pdata")
		P.on_game_start()
		local ok = pcall(function() load_script("coop_mods_pdata_pda").on_game_start() end)
		check(ok, "srv_no_ui: absent optional addon modules never abort startup")
		check(P.owns("milpda") and P.owns("coop_dotmarks_pdata"),
			"srv_no_ui: world storage knows both personal keys without loading a player HUD")
		return PASSES, FAILS
	end
	function dl() end
	function vl() end
	function clear_loot_window_flag() end
	function get_game_object(id) return OBJ[id] end
	function iterate_any_inventory(box, f) box:iterate_inventory(f, box) end
	local function object(id, name)
		local _, obj = spawn("test_object", vec3(0, 0, 0), nil, { id = id })
		obj.name = function() return name end
		return obj
	end
	local corpus = "temp/review/corpus/merged/"
	dotmarks_main = { cfg = { write_to_save = true, invboxes = {}, dropped_items = {} } }
	setmetatable(dotmarks_main, { __index = _G })
	ui_hud_dotmarks = {}
	setmetatable(ui_hud_dotmarks, { __index = dotmarks_main })
	mod_chunk(corpus .. "dotmarks_main.script", {
		"function is_invbox_found(", "function is_invbox_searched(", "function is_concealed_stash_marker(",
	}, "dotmarks_main")
	mod_chunk(corpus .. "ui_hud_dotmarks.script", {
		"function get_inventory_table(", "function validate_object_tables(", "function load_state(", "function save_state(",
	}, "ui_hud_dotmarks")
	item_milpda = { fd = { army = { req = 4, progress = 0 } }, found_npc_pda = {}, on_option_change = function() end }
	ish_kill_tracker = { tracked_bodies = {} }
	mod_chunk(corpus .. "item_milpda.script", { "function actor_on_first_update(", "function load_state(", "function save_state(" }, "item_milpda")
	mod_chunk(corpus .. "ish_kill_tracker.script", { "function invalid_body_record(", "function load_state(", "function save_state(" }, "ish_kill_tracker")
	RegisterScriptCallback("load_state", ui_hud_dotmarks.load_state)
	RegisterScriptCallback("load_state", item_milpda.load_state)
	RegisterScriptCallback("load_state", ish_kill_tracker.load_state)
	load_script("coop_main").on_game_start()
	load_script("coop_mods_core").on_game_start()
	local P = load_script("coop_mods_pdata")
	P.on_game_start()
	P.register_module("ish_kill_tracker") -- the existing misc registration with an empty table
	local fh = io.open("gamedata/scripts/coop_mods_pdata_pda.script", "r")
	if fh then
		fh:close(); load_script("coop_mods_pdata_pda").on_game_start()
		local wrappers = #coop_mods_core.wrapped
		coop_mods_pdata_pda.on_game_start()
		check(#coop_mods_core.wrapped == wrappers, which .. ": repeated startup does not stack wrappers")
	end
	local collect = coop_mods_core.upvalue(P.keep_for_load, "collect")
	local cfg = dotmarks_main.cfg
	local function gather() return collect() end
	local function load_personal(data)
		STASH.coop_mods_pdata = nil
		alife_storage_manager.CALifeStorageManager_load({
			dotmarks = { world_setting = 7, invboxes = { [1100] = {
				id = 1100, name = "box", owned = true, found = false, searched = false, items = { [999] = "stale" },
			} }, dropped_items = { [204] = "host_drop" } },
			milpda = { faction_data = { army = { progress = 999 } }, found_npc_pda = { [204] = true },
				tracked_bodies = { [204] = { id = 204, name = "host_body" } }, world_setting = 8 },
			coop_mods_pdata = { ["500"] = { t = "PDA", d = data } },
		})
	end
	check(P.owns("coop_dotmarks_pdata"), which .. ": m03:1 dedicated Dot Marks personal key")
	check(P.owns("milpda"), which .. ": m22:3 known milpda key registered with empty tracker")

	object(100, "box"); object(101, "drop"); object(102, "pda"); object(103, "body")
	local numbering = 0
	coop.to_host_id = function(id)
		if id == 0 then return MODE == "client" and 500 or 0 end
		if id >= 100 and id <= 204 then return id + (numbering == 0 and 1000 or 900) end
		return id
	end
	coop.to_local_id = function(id)
		if id == 500 then return MODE == "client" and 0 or 500 end
		if id >= 1100 and id <= 1104 then return id - (numbering == 0 and 1000 or 900) end
		return id
	end
	cfg.invboxes = { [100] = { id = 100, name = "box", found = true, searched = true, owned = true,
		items = { [998] = "old_contents" } } }
	cfg.dropped_items = { [101] = "drop" }
	item_milpda.fd = { army = { req = 4, progress = 3, reset = 7200, unlocked = 3600 } }
	item_milpda.found_npc_pda = { [102] = true }
	ish_kill_tracker.tracked_bodies = { [103] = { id = 103, killer_id = 0, name = "Display name", tod = 3500 } }
	local personal = gather()
	local encoded = coop_mods_core.ser(personal)
	check(type(encoded) == "string", which .. ": personal state fits the actual pdata codec")
	personal = encoded and coop_mods_core.deser(encoded) or personal
	local dots = personal.coop_dotmarks_pdata or {}
	local boxes = dots.invboxes or {}
	check(boxes[1100] and boxes[1100].found and boxes[1100].searched,
		which .. ": m03:1 collect live found/searched in world numbering")
	check(boxes[1100] and boxes[1100].items == nil and boxes[1100].owned == nil,
		which .. ": m04:3 world contents and ownership excluded from personal data")
	check(dots.dropped_items and dots.dropped_items[1101] == "drop",
		which .. ": m04:3 dropped items use world ids")
	local mpda = personal.milpda or {}
	check(mpda.faction_data and mpda.faction_data.army.progress == 3
		and mpda.found_npc_pda and mpda.found_npc_pda[1102], which .. ": m22:2 live fd and discovered PDAs collected")
	check(mpda.tracked_bodies and mpda.tracked_bodies[1103]
		and mpda.tracked_bodies[1103].killer_id == (MODE == "client" and 500 or 0),
		which .. ": m22:3 body and killer ids translated (including own actor)")
	check(item_milpda.fd.army.reset == 7200 and cfg.invboxes[100].items[998] == "old_contents",
		which .. ": collect does not mutate the mods' live state")
	P.register_module("ish_kill_tracker") -- coop_mods_misc can run before or after this adapter
	local repeated = gather()
	check(repeated.milpda and repeated.milpda.tracked_bodies[1103]
		and repeated.milpda.found_npc_pda[1102], which .. ": misc discovery preserves the explicit milpda provider")
	local hid = coop.to_host_id
	coop.to_host_id = function(id) if id == 100 then return nil end return hid(id) end
	local unmapped = gather()
	check(unmapped.coop_dotmarks_pdata and next(unmapped.coop_dotmarks_pdata.invboxes) == nil,
		which .. ": failed world-id conversion never falls back to local numbering")
	coop.to_host_id = hid
	local saved = {}
	local ok = pcall(item_milpda.save_state, saved)
	if MODE ~= "sp" then
		check(ok and saved.milpda and saved.milpda.faction_data == item_milpda.fd,
			which .. ": m22:2 original save_state attaches data.milpda before use")
	end

	if MODE == "client" then
		coop.world_epoch = function() return 4 end
		check(P.keep_for_load(5), which .. ": the last-second state is kept through the actual pdata stash")
		coop.world_epoch = function() return 5 end
		alife_storage_manager.CALifeStorageManager_load({ coop_mods_pdata = { ["500"] = { t = "old-report", d = {} } } })
		check(dotmarks_main.is_invbox_found(100) and item_milpda.found_npc_pda[102]
			and ish_kill_tracker.tracked_bodies[103], which .. ": kept load restores the freshest marks/PDA/tracker before callbacks")
		numbering = 1
		OBJ[100], OBJ[101], OBJ[102], OBJ[103] = nil, nil, nil, nil
		object(200, "box"); object(201, "drop"); object(202, "pda"); object(203, "body"); object(204, "host_drop")
		local content = object(205, "fresh_item")
		SE[205].parent_id = 200
		local before_load
		RegisterScriptCallback("load_state", function(m)
			before_load = item_milpda.found_npc_pda[202] and ish_kill_tracker.tracked_bodies[203]
				and cfg.invboxes[200] and cfg.invboxes[200].found
		end)
		load_personal(personal)
		check(before_load, which .. ": personal internals restored before load_state observers")
		check(dotmarks_main.is_invbox_found(200) and dotmarks_main.is_invbox_searched(200),
			which .. ": m03:1 marks survive changed local numbering")
		check(cfg.invboxes[200] and cfg.invboxes[200].owned == true,
			which .. ": world ownership is retained under translated box id")
		check(cfg.dropped_items[201] == "drop" and cfg.dropped_items[204] == nil,
			which .. ": m04:3 own dropped history replaces host history")
		check(cfg.invboxes[200] and (cfg.invboxes[200].items == nil or cfg.invboxes[200].items[999] == nil)
			and ui_hud_dotmarks.get_inventory_table(OBJ[200], 200)[205] == content:section(),
			which .. ": m04:3 contents come from the current world")
		check(item_milpda.fd.army.progress == 3 and item_milpda.fd.army.reset == 7200
			and item_milpda.found_npc_pda[202] and not item_milpda.found_npc_pda[204],
			which .. ": m22:2 access and PDA history replace host values")
		check(ish_kill_tracker.tracked_bodies[203] and ish_kill_tracker.tracked_bodies[203].id == 203
			and ish_kill_tracker.tracked_bodies[203].killer_id == 0 and not ish_kill_tracker.tracked_bodies[204],
			which .. ": m22:3 restored tracker uses current local ids and display name is not identity")
		check(alife_storage_manager.get_state().milpda.world_setting == 8,
			which .. ": unrelated world fields in mixed milpda table stay put")
		check(personal.milpda.tracked_bodies[1103] and personal.milpda.tracked_bodies[1103].id == 1103,
			which .. ": restore leaves the saved world-id snapshot unchanged")

		OBJ[200], OBJ[201], OBJ[202], OBJ[203], SE[203] = nil, nil, nil, nil, nil
		load_personal(personal)
		ui_hud_dotmarks.validate_object_tables()
		item_milpda.actor_on_first_update()
		check(cfg.invboxes[200] and cfg.invboxes[200].found and cfg.dropped_items[201] == "drop",
			which .. ": another map/offline objects retain Dot Marks history")
		check(item_milpda.found_npc_pda[202] == true,
			which .. ": another map/offline PDAs survive the original first-update validator")
		check(ish_kill_tracker.invalid_body_record(203, ish_kill_tracker.tracked_bodies[203]) == false,
			which .. ": offline body history is retained until identity can be checked")
		object(200, "late_reused_box"); object(201, "late_reused_drop")
		object(202, "late_reused_pda"); object(203, "late_reused_body")
		check(not dotmarks_main.is_invbox_found(200), which .. ": late-spawn reused box is rejected before a marker query")
		NOW = NOW + 2000
		SendScriptCallback("actor_on_update")
		check(cfg.dropped_items[201] == nil and item_milpda.found_npc_pda[202] == nil
			and ish_kill_tracker.tracked_bodies[203] == nil, which .. ": late-spawn reused item/PDA/body histories are purged")

		object(200, "reused_box"); object(201, "reused_drop"); object(202, "reused_pda"); object(203, "reused_body")
		load_personal(personal)
		check(not dotmarks_main.is_invbox_found(200) and not dotmarks_main.is_invbox_searched(200),
			which .. ": m03:1 reused object id is not marked")
		check(cfg.dropped_items[201] == nil and item_milpda.found_npc_pda[202] == nil
			and ish_kill_tracker.tracked_bodies[203] == nil, which .. ": m04:3/m22:2/m22:3 identities reject reused ids")

		ish_kill_tracker.tracked_bodies = {}
		local empty = gather()
		check(empty.milpda and type(empty.milpda.tracked_bodies) == "table" and next(empty.milpda.tracked_bodies) == nil,
			which .. ": m22:3 cleared history is explicitly collected")
		ish_kill_tracker.tracked_bodies = { [204] = { id = 204 } }
		load_personal(empty)
		check(next(ish_kill_tracker.tracked_bodies) == nil, which .. ": m22:3 empty tracked_bodies replaces host history")
		load_personal({})
		check(next(item_milpda.found_npc_pda) == nil and next(ish_kill_tracker.tracked_bodies) == nil
			and item_milpda.fd.army.progress == 0, which .. ": first join starts fresh, not from prior player's progress")
		local safe, err = pcall(load_personal, {
			coop_dotmarks_pdata = { invboxes = 3, dropped_items = false },
			milpda = { faction_data = 7, found_npc_pda = "invalid", tracked_bodies = false },
		})
		check(safe and type(item_milpda.fd) == "table" and type(ish_kill_tracker.tracked_bodies) == "table",
			which .. ": malformed personal table shapes cannot abort load_state: " .. tostring(err))
		check(coop_trust.status().pda_table and coop_trust.status().pda_table.failed > 0,
			which .. ": malformed state is reported through coop_trust before being discarded")
	else
		-- Authoritative processes never restore somebody else's personal state on a world load.
		local ordinary = { milpda = { faction_data = { army = { progress = 9 } }, found_npc_pda = { [105] = true }, tracked_bodies = {} },
			dotmarks = { invboxes = {}, dropped_items = {} } }
		if which == "none" then
			local original = item_milpda.save_state
			local s = {}; original(s)
			check(s.milpda == nil or s.milpda.faction_data ~= item_milpda.fd,
				"none: stock save_state behavior is unchanged outside session")
		end
		if which ~= "srv_map" then
			alife_storage_manager.CALifeStorageManager_load(ordinary)
			check(item_milpda.fd.army.progress == 9, which .. ": ordinary world load retains original behavior")
			if which ~= "none" then
				check(item_milpda.found_npc_pda[105] and not item_milpda.found_npc_pda[102]
					and next(ish_kill_tracker.tracked_bodies) == nil,
					which .. ": raw world save restores PDA discovery and replaces host player's tracker too")
			end
		end
	end
	return PASSES, FAILS
end

for _, which in ipairs({ "hostplay_client", "srv_client", "hostplay", "srv_world", "srv_map", "none", "srv_no_ui" }) do
	local env = {}
	for k, v in pairs(_G) do env[k] = v end
	env._G = env
	env.loadstring = function(...)
		local f, e = native_loadstring(...)
		if f then setfenv(f, env) end
		return f, e
	end
	env.dofile = function(path)
		local f = assert(native_loadfile(path)); setfenv(f, env); return f()
	end
	local p, f = setfenv(scenario, env)(which)
	total_passed, total_failed = total_passed + p, total_failed + f
end
print(string.format("PDATA PDA: %d passed, %d failed", total_passed, total_failed))
if total_failed > 0 then error("PDATA PDA FAILED") end
