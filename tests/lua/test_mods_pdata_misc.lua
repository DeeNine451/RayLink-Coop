-- Dev 57 G1-2. Real mod functions, isolated Lua environments for each mode/seat.
local function read(path)
	local f = assert(io.open(path, "rb"), path)
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end
local corpus = "temp/review/corpus/merged/"
local function func(src, name)
	return assert(src:match("(function " .. name:gsub("([%.:])", "%%%1") .. "%b().-\nend)"), name)
end
local helmet_src = read(corpus .. "liz_fdda_redone_headgear_animations_hotkey.script")
local outfit_src = read(corpus .. "liz_fdda_redone_outfit.script")
local nvg_src = read(corpus .. "z_beefs_nvgs.script")
local exo_src = read(corpus .. "exo_powers.script")
local wheel_src = read(corpus .. "haru_quick_action_wheel_mcm.script")
local rain_src = read("temp/stock_scripts/scripts/level_environment.script")
local modes = dofile("tests/lua/support/modes.lua")

local function scenario(seat, restart, transition, peer, same_map)
	dofile("tests/lua/support/stubs_mods.lua")
	MODE = seat == "none" and "sp" or (seat == "hostplay_owner" or seat == "srv_map" or seat == "srv_world") and "host" or "client"
	SELF = MODE == "client" and peer or 0
	if SELF == 2 then PROXY = 501 end
	if seat == "srv_map" then
		coop.is_map_server = function() return true end
		coop.is_host = function() return false end
		coop.is_client = function() return true end
	end
	if seat == "srv_world" then coop.is_dedicated = function() return true end end
	if seat == "srv_client" then
		coop.levels = { split = function() return true end }
		coop.players = function()
			return { { id = 1, level = "map_a", elsewhere = not same_map and SELF == 2 },
				{ id = 2, level = same_map and "map_a" or "map_b", elsewhere = not same_map and SELF == 1 } }
		end
	end
	local function fixture(name, src)
		local m = setmetatable({}, { __index = _G })
		_G[name] = m
		local f = assert(loadstring(src, "@" .. name .. ".script"))
		setfenv(f, m); f()
		return m
	end
	local actor = make_actor()
	local worn, ruck, equipped = nil, {}, nil
	actor.item_in_slot = function(_, slot)
		if slot ~= 12 or not worn then return nil end
		-- Luabind returns a fresh userdata for each lookup of the same item.
		local ref = newproxy(true)
		getmetatable(ref).__index = worn
		return ref
	end
	actor.iterate_ruck = function(_, f, arg) for _, item in pairs(ruck) do f(arg, item) end end
	actor.iterate_inventory = actor.iterate_ruck
	actor.object_id = function(_, id) return ruck[id] end
	liz_fdda_redone_mcm = { get_config = function(k)
		if k == "outfit_anm/memory_size" then return 3 end
		return k ~= "outfit_anm/always_short"
	end }
	lam2 = { is_running = function() return false end }
	liz_fdda_redone_headgear_animations = {
		on_toggle_unequip = function(item) worn = nil end,
		on_toggle_equip = function(item) equipped = item end,
	}
	zzzz_liz_fdda_redone_ui_inventory = { Add_Handler = function() end }
	actor_effects = { play_item_fx = function() end, is_mask_on = function() return true end }
	local H = fixture("liz_fdda_redone_headgear_animations_hotkey", helmet_src)
	local O = fixture("liz_fdda_redone_outfit", outfit_src)
	local N = fixture("z_beefs_nvgs", nvg_src:match("^(.-)function on_game_load") ..
		"function update_nvgs() end\n" .. func(nvg_src, "brightness_adjust"))
	item_device = { nv_state = true }
	local X = fixture("exo_powers", [[
local on_cooldown = false
local power_active = "test"
local current_outfit, start_time
local DURATION, COOLDOWN = 8000, 20
local st = { test = { {}, { playing = function() return false end }, { play = function() end } } }
local ini_powers = { r_string_ex = function() end }
local send_tip = function() end
local gc = function(s) return s end
function exec() end
function prepare() power_active = "test" end
]] .. func(exo_src, "activate_powers") .. "\n" .. func(exo_src, "deactivate_powers") .. "\n" .. func(exo_src, "reset_cooldown"))
	local W = fixture("haru_quick_action_wheel_mcm", [[
TabManager = {}
local function get_empty_tab() return { __sections = {}, __ids = {} } end
local ini_sys = { section_exist = function(_, section) return section == "mine" end }
TAB_MANAGER = setmetatable({ tabs = {}, current_tab = 1, tab_count = 4,
 classes = { QConsumableWheelOption = {}, QGrenadeWheelOption = {}, QDetectorWheelOption = {},
 QMagazineWheelOption = { is_obj = true }, QEquipWheelOption = { is_obj = true } } }, { __index = TabManager })
]] .. func(wheel_src, "TabManager:save_state") .. "\n" .. func(wheel_src, "TabManager:RemoveItem") .. "\n"
		.. func(wheel_src, "TabManager:load_state") .. [[

function on_game_start()
 RegisterScriptCallback("load_state", TAB_MANAGER)
 RegisterScriptCallback("save_state", TAB_MANAGER)
end
]])
	strformat = string.format
	local console = {}
	exec_console_cmd = function(s) console[#console + 1] = s end
	level_weathers = { bLevelUnderground = false }
	local R = fixture("level_environment", rain_src:match("^(.-)\nlocal tiny_particles") .. [[
function update_settings() effects_droplets_enabled = true end
function actor_on_first_update() end
function actor_on_update() end
]] .. func(rain_src, "on_game_start"))
	MODS_FILES = { "coop_mods_core", "coop_mods_misc", "coop_mods_pdata" }
	start_all()
	if MODE ~= "client" then modes.install(coop_mode, seat == "hostplay_owner" and "hostplay" or seat) end
	W.on_game_start(); H.on_game_start(); O.on_game_start(); O.initialize()
	axr_main.callback_add("on_game_load")
	R.on_game_start()
	local C, P = coop_mods_core, coop_mods_pdata
	local function local_value(m, name) return C.find_local(m, name) end
	local function set_local(m, name, v)
		local _, f, i = C.find_local(m, name)
		assert(f, name); debug.setupvalue(f, i, v)
	end
	local function load(data)
		alife_storage_manager.CALifeStorageManager_load(data)
		SendScriptCallback("on_game_load")
	end
	local function host_save(own)
		return { haru_qaw = { tabs = { { __sections = {}, __ids = {} } }, current_tab = 9 }, lastHelmetId = 9003,
			coop_misc_nvg_state = { gain = 0.5, direction = true },
			coop_misc_outfit_history = { "host_outfit" }, coop_misc_exo_cooldown_ms = 99000,
			r2_drops_control = { 0.9, 1 }, beltMemory = { host = true },
			coop_mods_pdata = { [tostring(PROXY)] = { t = "mine", d = own or {} } } }
	end
	local function snapshot()
		P.report_now()
		local s = STASH.coop_mods_pdata
		return s and C.deser(s:match("^[^|]*|(.*)$")) or {}
	end
	local function capture_report()
		local first = #SENT + 1
		snapshot()
		local packets = {}
		for i = first, #SENT do
			local msg = SENT[i]
			if msg.name == "mods.pd" and msg.target == 0 then packets[#packets + 1] = msg end
		end
		check(#packets > 0, seat .. ": personal report addressed to the world owner")
		return { packets = packets }
	end
	local function helmet(id)
		local alive = true
		return { id = function() assert(alive, "released helmet id read"); return id end,
			section = function() return "helmet_mine" end,
			free = function() alive = false end }
	end
	local function store_reports(reports)
		spawn("coop_player_avatar", nil, nil, { id = 500 })
		spawn("coop_player_avatar", nil, nil, { id = 501 })
		local avatar_of = coop.avatar_of
		coop.avatar_of = function(p) return p == 2 and 501 or avatar_of(p) end
		for p, report in ipairs(reports) do
			for _, packet in ipairs(report.packets) do deliver(packet, p) end
		end
		local m = alife_storage_manager.get_state()
		SendScriptCallback("save_state", m)
		local records = m.coop_mods_pdata
		check(records and records["500"] and records["501"] and not records["0"],
			seat .. ": records saved against the transport senders' character ids")
		return records
	end
	if seat == "srv_map" or seat == "srv_world" then
		check(P.owns("haru_qaw") and P.owns("lastHelmetId") and P.owns("coop_misc_nvg_state") and
			P.owns("coop_misc_outfit_history") and P.owns("coop_misc_exo_cooldown_ms") and P.owns("r2_drops_control"),
			seat .. ": all personal keys registered without a player inventory")
		check(next(TIMEEV) == nil, seat .. ": registration creates no player timers")
		local saved = {}; SendScriptCallback("save_state", saved)
		check(saved.coop_misc_nvg_state == nil and saved.coop_misc_outfit_history == nil and saved.coop_misc_exo_cooldown_ms == nil,
			seat .. ": a process without a player saves no personal UI state")
		if seat == "srv_world" then return store_reports(restart) end
		return
	end
	if seat == "none" then
		local h = helmet(4003); worn = h; ruck[4003] = h
		H.toggle_helmet(); H.on_save_state(alife_storage_manager.get_state())
		check(alife_storage_manager.get_state().lastHelmetId == 4003, "none: original helmet hotkey/save unchanged")
		N.brightness_adjust(); O.remember_outfit("sp_outfit"); X.deactivate_powers(20)
		local sp = {}; SendScriptCallback("save_state", sp)
		check(sp.coop_misc_nvg_state == nil and sp.coop_misc_outfit_history == nil and sp.coop_misc_exo_cooldown_ms == nil,
			"none: no new state saved outside a session")
		check(TIMEEV["exo_powers:deactivate_power"].at == NOW + 20000, "none: original exo timer unchanged")
		local stock_tab = { __sections = {}, __ids = {} }
		load({ haru_qaw = { tabs = { stock_tab }, current_tab = 1 } })
		check(rawequal(W.TAB_MANAGER.tabs[1], stock_tab), "none: wheel load uses the original tab unchanged")
		return
	end
	if seat == "hostplay_owner" then
		N.brightness_adjust(); O.remember_outfit("own_outfit"); X.deactivate_powers(20)
		local h = helmet(4007)
		H.set_last_helmet(h); h.free()
		NOW = NOW + 3000
		local saved = {}; SendScriptCallback("save_state", saved)
		check(saved.lastHelmetId == 4007, "hostplay: registered save callbacks read only the numeric helmet id")
		check(saved.coop_misc_nvg_state and saved.coop_misc_nvg_state.gain == 1.5, "hostplay: own NVG state saved")
		check(saved.coop_misc_outfit_history and saved.coop_misc_outfit_history[1] == "own_outfit", "hostplay: own outfit history saved")
		check(saved.coop_misc_exo_cooldown_ms == 17000, "hostplay: own cooldown remainder saved")
		return store_reports(restart)
	end
	if peer == 2 then
		if seat == "srv_client" then
			check(coop_mode.where(1) == (same_map and "here" or "away") and coop_mode.where(2) == "here",
				same_map and "srv_client: both players on the same map" or "srv_client: players on different maps")
		end
		if restart then
			local save = host_save()
			save.coop_mods_pdata = restart.records
			load(save)
			check(local_value(R, "droplet_pwr") == 0.7 and local_value(R, "droplet_speed") == 1,
				seat .. ": second client restores its own rain from the shared world save")
			return
		end
		load(host_save())
		set_local(R, "droplet_pwr", 0.7); set_local(R, "droplet_speed", 1)
		return capture_report()
	end
	if restart then
		NOW = 17
		coop.world_epoch = function() return 9 end
		if transition then STASH.coop_mods_pdata = restart.stash end
		local save = host_save()
		if not transition then save.coop_mods_pdata = restart.records end
		load(save)
		local label = seat .. (transition and " new Lua/session stash: " or " new Lua/personal record: ")
		local tab = W.TAB_MANAGER.tabs[4]
		check(W.TAB_MANAGER.current_tab == 4 and tab and tab[1] and tab[1].section == "mine", label .. "wheel restored")
		SendScriptCallback("actor_on_first_update")
		local own = helmet(4003); ruck[4003] = own; SendScriptCallback("actor_on_update"); H.toggle_helmet()
		check(rawequal(equipped, own), label .. "own helmet restored after inventory")
		N.brightness_adjust()
		check(local_value(N, "nvg_gain_current") == 1.5 and local_value(N, "gain_directionality") == false, label .. "NVG restored before use")
		check(O.select_animation("restart") == "outfit_animation_fast_hud", label .. "known outfit takes the short animation")
		local timer = TIMEEV["exo_powers:deactivate_power"]
		check(local_value(X, "on_cooldown") == true and timer and timer.at == 13017, label .. "cooldown remainder restored")
		check(local_value(R, "droplet_pwr") == 0.4 and local_value(R, "droplet_speed") == 0.1, label .. "own rain restored")
		return
	end
	load(host_save())
	check(alife_storage_manager.get_state().haru_qaw == nil, seat .. ": wheel never inherits host layout")
	check(alife_storage_manager.get_state().lastHelmetId == nil, seat .. ": helmet never inherits host id")
	check(local_value(N, "nvg_gain_current") == 1 and local_value(N, "gain_directionality") == true,
		seat .. ": new NVG state never inherits host settings")
	check(not O.memory_contain("host_outfit"), seat .. ": outfit history never inherits host sections")
	check(not local_value(X, "on_cooldown"), seat .. ": cooldown never inherits host remainder")
	check(local_value(R, "droplet_pwr") == 0 and local_value(R, "droplet_speed") == 0,
		seat .. ": rain never inherits host drops")

	-- m26:1: first client configuration, including tab changes after an earlier restore.
	local function wheel_entry(class, id, arg2, arg3)
		return { class = class, section = "mine", id = id, args = { "mine", arg2, arg3 } }
	end
	local function wheel_tab()
		return { __sections = { mine = true }, __ids = {}, wheel_entry("QConsumableWheelOption") }
	end
	local function empty_tab() return { __sections = {}, __ids = {} } end
	W.TAB_MANAGER.tabs = { wheel_tab(), empty_tab(), empty_tab(), empty_tab() }
	W.TAB_MANAGER.current_tab = 2
	local d = snapshot()
	check(d.haru_qaw and d.haru_qaw.tabs[1][1].section == "mine" and d.haru_qaw.current_tab == 2,
		seat .. ": m26 first wheel configuration collected")
	STASH.coop_mods_pdata = nil; W.TAB_MANAGER.tabs = {}; W.TAB_MANAGER.current_tab = 1; load(host_save(d))
	local first = W.TAB_MANAGER.tabs[1]
	check(W.TAB_MANAGER.current_tab == 2 and first and first[1] and first[1].section == "mine", seat .. ": m26 own wheel restored")
	W.TAB_MANAGER.current_tab = 3; d = snapshot()
	STASH.coop_mods_pdata = nil; W.TAB_MANAGER.current_tab = 1; load(host_save(d))
	check(W.TAB_MANAGER.current_tab == 3, seat .. ": m26 selected tab survives repeated load")

	-- Saved wheel records can contain values the stock loader and GUI assume are safe.
	local tm = W.TAB_MANAGER
	local function restore_wheel(data)
		STASH.coop_mods_pdata = nil
		tm.tabs = { empty_tab(), empty_tab(), empty_tab(), empty_tab() }; tm.current_tab = 1
		return pcall(load, host_save({ haru_qaw = data }))
	end
	check(restore_wheel({ tabs = false, current_tab = 1 }) and type(tm.tabs) == "table",
		seat .. ": m26 malformed tabs envelope cannot reach GAMMA")
	local malformed_tabs = { wheel_tab(), false, empty_tab(), wheel_tab(), wheel_tab(), [10] = wheel_tab(), stray = true }
	local wheel_loaded = restore_wheel({ tabs = malformed_tabs, current_tab = 5 })
	check(wheel_loaded and type(tm.tabs[2]) == "table" and tm.tabs[4][1] and tm.tabs[5] == nil
		and tm.tabs[10] == nil and tm.tabs.stray == nil,
		seat .. ": m26 restore keeps usable tabs within the local tab count")
	check(wheel_loaded and tm.current_tab == 1, seat .. ": m26 selection outside available tabs falls back to tab one")
	for _, invalid in ipairs({ 0, 2, 2.5, "3", 5, math.huge }) do
		check(restore_wheel({ tabs = { wheel_tab() }, current_tab = invalid }) and tm.current_tab == 1,
			seat .. ": m26 non-index selection falls back to tab one (" .. tostring(invalid) .. ")")
	end
	local entries = {
		__sections = true, __ids = "not a lookup table",
		wheel_entry("QMagazineWheelOption", 65535, 65535), -- reserved object id
		wheel_entry("QMagazineWheelOption", 11, 12), -- inconsistent object id
		wheel_entry("QEquipWheelOption", 13, 13, 1.5), -- fractional inventory slot
		wheel_entry("QEquipWheelOption", 14, 14, 65534), -- out-of-range inventory slot
		wheel_entry("QGrenadeWheelOption", nil, 9), -- detector slot does not belong to a grenade
		wheel_entry("QDetectorWheelOption", nil, -1),
		wheel_entry("QConsumableWheelOption", -7), -- the optional object id is also bounded
		{ class = "QConsumableWheelOption", section = "mine", args = true },
		true, -- the loader must never index a scalar entry
		wheel_entry("QEquipWheelOption", 4005, 4005, 9),
		wheel_entry("QMagazineWheelOption", 4006, 4006),
	}
	local legacy_slots = { __sections = { mine = true }, wheel_entry("QGrenadeWheelOption", nil, 4) }
	wheel_loaded = restore_wheel({ tabs = { entries, legacy_slots, wheel_tab() }, current_tab = 2 })
	local objects, slots = tm.tabs[1], tm.tabs[2]
	check(wheel_loaded and #objects == 2 and objects[1].id == 4005 and objects[1].args[3] == 9
		and objects[2].id == 4006 and objects[2].args[2] == 4006,
		seat .. ": m26 malformed entries are dropped before GAMMA reads them, valid object args survive")
	check(wheel_loaded and objects.__ids[4005] == true and objects.__ids[4006] == true
		and slots.__sections.mine == true and slots[1].args[2] == 4 and tm.current_tab == 2,
		seat .. ": m26 lookup tables rebuilt and legacy grenade slot and selected tab survive")

	-- Each slot lookup returns a different userdata. FDDA's hotkey alone must persist its choice.
	local h = helmet(4003); worn = h; ruck[4003] = h
	H.toggle_helmet()
	check(snapshot().lastHelmetId == 4003, seat .. ": m10 hotkey captures the helmet id across distinct userdata")
	H.toggle_helmet()
	check(rawequal(equipped, h), seat .. ": m10 immediately re-equips the helmet removed by the hotkey")
	worn = h
	local unequip = liz_fdda_redone_headgear_animations.on_toggle_unequip
	liz_fdda_redone_headgear_animations.on_toggle_unequip = function(item)
		unequip(item); h.free(); ruck[4003] = nil
	end
	local capture_safe = pcall(H.toggle_helmet)
	liz_fdda_redone_headgear_animations.on_toggle_unequip = unequip
	check(capture_safe, seat .. ": m10 hotkey ID is read before release in the original call")
	local safe, captured = pcall(snapshot)
	check(safe and captured.lastHelmetId == 4003, seat .. ": m10 helmet numeric id captured before release")
	local save = {}
	local saved_safe = pcall(H.on_save_state, save)
	check(saved_safe and save.lastHelmetId == 4003, seat .. ": m10 wrapped save function uses only the numeric id")
	ruck[4004] = helmet(4004) -- make the original loop encounter a different, live item
	local toggle_safe = pcall(H.toggle_helmet)
	check(toggle_safe, seat .. ": m10 hotkey does not read released helmet")
	ruck[4004] = nil
	H.set_last_helmet(nil)
	STASH.coop_mods_pdata = nil; load(host_save({ lastHelmetId = 4003 }))
	SendScriptCallback("actor_on_first_update") -- own inventory has not arrived yet
	local fresh = helmet(4003); ruck[4003] = fresh
	SendScriptCallback("actor_on_update"); H.toggle_helmet()
	check(rawequal(equipped, fresh), seat .. ": m10 helmet restored after own inventory appears")

	-- m10:6: both values before the next brightness press, personal record and session stash.
	set_local(N, "nvg_gain_current", 2); set_local(N, "gain_directionality", false)
	d = snapshot()
	check(d.coop_misc_nvg_state and d.coop_misc_nvg_state.gain == 2 and d.coop_misc_nvg_state.direction == false,
		seat .. ": m10 NVG gain and direction collected")
	STASH.coop_mods_pdata = nil; set_local(N, "nvg_gain_current", 1); set_local(N, "gain_directionality", true)
	load(host_save(d)); N.brightness_adjust()
	check(local_value(N, "nvg_gain_current") == 1.5, seat .. ": m10 NVG restored before first use")
	coop.world_epoch = function() return 8 end; P.keep_for_load(8)
	set_local(N, "nvg_gain_current", 1); set_local(N, "gain_directionality", true)
	load(host_save())
	check(local_value(N, "nvg_gain_current") == 1.5 and local_value(N, "gain_directionality") == false,
		seat .. ": m10 NVG survives transition stash")

	-- m10:7: queue advances from zero; persist order, rebase indexes, evict oldest.
	STASH.coop_mods_pdata = nil; load(host_save())
	for _, sec in ipairs({ "old", "a", "b", "c" }) do O.remember_outfit(sec) end
	d = snapshot()
	check(d.coop_misc_outfit_history and table.concat(d.coop_misc_outfit_history, ",") == "a,b,c",
		seat .. ": m10 bounded outfit history collected in queue order")
	STASH.coop_mods_pdata = nil; set_local(O, "memory", {}); load(host_save(d)); O.remember_outfit("d")
	check(not O.memory_contain("a") and O.memory_contain("b") and O.memory_contain("c") and O.memory_contain("d")
		and O.memory_size() == 3, seat .. ": m10 outfit queue indexes restored, oldest evicted")
	check(alife_storage_manager.get_state().beltMemory.host == true, seat .. ": outfit history does not copy belt/world data")

	-- m31:8: restart the clock, not the elapsed countdown; expired state is zero.
	X.prepare(); X.deactivate_powers(20); NOW = NOW + 7000; d = snapshot()
	check(d.coop_misc_exo_cooldown_ms == 13000, seat .. ": m31 saves remaining cooldown, not absolute time")
	STASH.coop_mods_pdata = nil; TIMEEV = {}; NOW = 100; set_local(X, "on_cooldown", false); load(host_save(d))
	check(local_value(X, "on_cooldown") == true, seat .. ": m31 Lua restart keeps cooldown active")
	local event = TIMEEV["exo_powers:deactivate_power"]
	check(event and event.at == 13100, seat .. ": m31 reset scheduled relative to new clock")
	run_time_events(12900); check(local_value(X, "on_cooldown") == true, seat .. ": m31 no early reset")
	run_time_events(200); check(local_value(X, "on_cooldown") == false, seat .. ": m31 reset after remainder")
	check(snapshot().coop_misc_exo_cooldown_ms == 0, seat .. ": m31 expired cooldown reports zero")

	-- s36:6: each player's current power AND speed, even if the m_data copy is stale.
	set_local(R, "droplet_pwr", 0.4); set_local(R, "droplet_speed", 0.1)
	d = snapshot()
	check(d.r2_drops_control and d.r2_drops_control[1] == 0.4 and d.r2_drops_control[2] == 0.1,
		seat .. ": s36 live rain values collected")
	STASH.coop_mods_pdata = nil; load(host_save(d))
	check(local_value(R, "droplet_pwr") == 0.4 and local_value(R, "droplet_speed") == 0.1,
		seat .. ": s36 own drops restored before stock on_game_load")
	STASH.coop_mods_pdata = nil
	local before_console = #console
	local safe_load = pcall(load, host_save({ r2_drops_control = { "0;bad_console_command", {} } }))
	check(safe_load and #console == before_console + 1 and console[#console] == "r2_drops_control 0,0,0",
		seat .. ": malformed saved rain never reaches stock console formatting")
	STASH.coop_mods_pdata = nil; load(host_save({ lastHelmetId = 65535 }))
	check(snapshot().lastHelmetId == 0, seat .. ": invalid helmet id is cleared, never clamped to a different item")
	-- Carry the report/session stash into a completely new environment below.
	W.TAB_MANAGER.tabs = { empty_tab(), empty_tab(), empty_tab(), wheel_tab() }; W.TAB_MANAGER.current_tab = 4
	worn = fresh; H.toggle_helmet()
	set_local(N, "nvg_gain_current", 2); set_local(N, "gain_directionality", false)
	O.remember_outfit("restart"); X.prepare(); X.deactivate_powers(20); NOW = NOW + 7000
	set_local(R, "droplet_pwr", 0.4); set_local(R, "droplet_speed", 0.1)
	local carry = capture_report()
	P.keep_for_load(9); carry.stash = STASH.coop_mods_pdata
	return carry
end

local passed, failed = 0, 0
local function run(seat, restart, transition, peer, same_map)
	local env = {}; for k, v in pairs(_G) do env[k] = v end; env._G = env
	env.loadstring = function(...)
		local f, err = loadstring(...); if f then setfenv(f, env) end; return f, err
	end
	env.dofile = function(path) local f = assert(loadfile(path)); setfenv(f, env); return f() end
	setfenv(scenario, env)
	local ok, carry = pcall(scenario, seat, restart, transition, peer or 1, same_map)
	passed = passed + (env.PASSES or 0); failed = failed + (env.FAILS or 0)
	if not ok then
		failed = failed + 1
		print("FAIL " .. seat .. ": " .. tostring(carry))
		return nil
	end
	return carry
end
local function run_players(mode, same_map)
	local player = mode == "hostplay" and "hostplay_client" or "srv_client"
	local owner = mode == "hostplay" and "hostplay_owner" or "srv_world"
	local first, second = run(player, nil, nil, 1, same_map), run(player, nil, nil, 2, same_map)
	if first and second then
		first.records = run(owner, { first, second })
		run(player, first, false, 1, same_map)
		run(player, first, true, 1, same_map)
		run(player, first, false, 2, same_map)
	end
end
for _, mode in ipairs(modes.names()) do
	if mode == "hostplay" or mode == "srv_world" then
		run_players(mode)
		if mode == "srv_world" then run_players(mode, true) end
	else
		run(mode)
	end
end
print(string.format("MODS PDATA MISC: %d passed, %d failed", passed, failed))
if failed > 0 then error("MODS PDATA MISC FAILED") end
