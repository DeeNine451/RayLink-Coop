-- Stand b57h (the progress keeper's case, fixed there in 75ea1c58): a Co-op host starts its session after its level is up
-- (coop_manager.cpp autostart waits for level_ready; the in-game Host comes later still), and its load_state comes before
-- that. coop_mods_misc restored its personal records (personal_state: the last helmet, the NVG gain and direction, the
-- FDDA outfit memory, the exo-powers cooldown, the rain drops) only at a load_state with a session: on a Co-op host none
-- came back, the helmet hotkey forgot the helmet taken off before the save, and the next save in the session wrote the
-- mods' defaults over the records. Real mod functions (the review corpus), as in test_mods_pdata_misc.
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
local rain_src = read("temp/stock_scripts/scripts/level_environment.script")
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]

-- The host's own save from an earlier session: its records as personal_state wrote them.
local function host_save()
	return { lastHelmetId = 4003, coop_misc_nvg_state = { gain = 1.5, direction = false },
		coop_misc_outfit_history = { "outfit_a", "outfit_b" }, coop_misc_exo_cooldown_ms = 13000,
		r2_drops_control = { 0.4, 0.1 } }
end
-- lastHelmetId is not here: the stock save writes it in single player, and the hotkey's save in a session writes the
-- helmet chosen in it (checked apart)
local KEYS = { "coop_misc_nvg_state", "coop_misc_outfit_history", "coop_misc_exo_cooldown_ms", "r2_drops_control" }

-- variant "update": the records come back at the first update once the session runs; "save": a save in the session
-- comes before that update; "save_m_data": that save as the game makes it. CALifeStorageManager_before_save hands
-- save_state the m_data the load filled, and axr_main calls its callbacks in pairs order: here the wrapped helmet save
-- comes first and writes the helmet this session has chosen so far (none) over the save's one.
local function scenario(variant)
	MODE = mode == "none" and "sp" or "host" -- "none": single player, which never has a session
	dofile("tests/lua/support/stubs_mods.lua")
	if mode == "srv_map" then
		coop.is_map_server = function() return true end
		coop.is_host = function() return false end
		coop.is_client = function() return true end
	end
	if mode == "srv_world" then coop.is_dedicated = function() return true end end
	-- The engine's phase is Off until the host starts hosting: no session while the level and the save load.
	local hosting = false
	local is_active = coop.is_active
	coop.is_active = function() return hosting and is_active() end
	local label = mode .. " (" .. variant .. "): "

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
	strformat = string.format
	exec_console_cmd = function() end
	level_weathers = { bLevelUnderground = false }
	local R = fixture("level_environment", rain_src:match("^(.-)\nlocal tiny_particles") .. [[
function update_settings() effects_droplets_enabled = true end
function actor_on_first_update() end
function actor_on_update() end
]] .. func(rain_src, "on_game_start"))
	MODS_FILES = { "coop_mods_core", "coop_mods_misc", "coop_mods_pdata" }
	start_all()
	modes.install(coop_mode, mode)
	H.on_game_start(); O.on_game_start(); O.initialize()
	axr_main.callback_add("on_game_load")
	R.on_game_start()
	local C = coop_mods_core
	local function local_value(m, name) return C.find_local(m, name) end
	local function set_local(m, name, v)
		local _, f, i = C.find_local(m, name)
		assert(f, name); debug.setupvalue(f, i, v)
	end
	local function defaults()
		return local_value(N, "nvg_gain_current") == 1 and local_value(N, "gain_directionality") == true
			and not O.memory_contain("outfit_a") and not O.memory_contain("outfit_b")
			and not local_value(X, "on_cooldown") and TIMEEV["exo_powers:deactivate_power"] == nil
	end
	local function none_saved(m)
		for _, key in ipairs(KEYS) do if m[key] ~= nil then return false end end
		if mode == "none" then return m.lastHelmetId == 4003 end -- the stock save: lastHelmet:id()
		return m.lastHelmetId == nil or m.lastHelmetId == 0 -- a server's actor chose no helmet, the save's is not restored
	end
	local function records_saved(m)
		local nvg, outfit = m.coop_misc_nvg_state, m.coop_misc_outfit_history
		return m.lastHelmetId == 4003 and type(nvg) == "table" and nvg.gain == 1.5 and nvg.direction == false
			and type(outfit) == "table" and table.concat(outfit, ",") == "outfit_a,outfit_b"
			and m.coop_misc_exo_cooldown_ms == 13000
			and type(m.r2_drops_control) == "table" and m.r2_drops_control[1] == 0.4 and m.r2_drops_control[2] == 0.1
	end
	-- the loaded save's personal records, untouched by a save in a process that restores none
	local function passed_through(m)
		local nvg, outfit = m.coop_misc_nvg_state, m.coop_misc_outfit_history
		return type(nvg) == "table" and nvg.gain == 1.5 and nvg.direction == false
			and type(outfit) == "table" and table.concat(outfit, ",") == "outfit_a,outfit_b"
			and m.coop_misc_exo_cooldown_ms == 13000
			and type(m.r2_drops_control) == "table" and m.r2_drops_control[1] == 0.4 and m.r2_drops_control[2] == 0.1
	end
	local function helmet(id)
		return { id = function() return id end, section = function() return "helmet_mine" end }
	end

	-- The helmet was taken off before the save: it is in the ruck, the slot is empty.
	local own = helmet(4003); ruck[4003] = own
	alife_storage_manager.CALifeStorageManager_load(host_save())
	SendScriptCallback("on_game_load")
	SendScriptCallback("actor_on_first_update") -- b57h host: first update 09:52:54, "phase off -> hosting" 09:53:09
	SendScriptCallback("actor_on_update")
	check(defaults(), label .. "nothing is restored while this process has no session")
	check(local_value(R, "droplet_pwr") == 0.4 and local_value(R, "droplet_speed") == 0.1,
		label .. "the stock reads its rain drops at the load")

	hosting = true -- in "none" coop.is_active stays false: single player never gets a session
	if variant == "save" or variant == "save_m_data" then
		local early = {}
		if variant == "save_m_data" then
			early = alife_storage_manager.get_state()
			H.on_save_state(early)
		end
		SendScriptCallback("save_state", early) -- a save in the session before its first update
		if mode == "hostplay" then
			check(records_saved(early), label .. "a save right after the session starts writes the save's records, not the defaults")
		elseif variant == "save" then
			check(none_saved(early), label .. "a process with no session or no player saves none of the personal records")
		else
			check(passed_through(early), label .. "a process with no session or no player writes none over the loaded records")
		end
	end
	SendScriptCallback("actor_on_update") -- the first update after hosting starts
	SendScriptCallback("actor_on_update") -- the helmet looks for its item in the ruck

	if mode ~= "hostplay" then
		check(defaults(), label .. "nothing is restored without a session or a player, also once the session runs")
		local saved = {}
		SendScriptCallback("save_state", saved)
		check(none_saved(saved), label .. "no personal record is saved (single player: the stock helmet save only)")
		if mode == "none" then
			H.toggle_helmet()
			check(rawequal(equipped, own), label .. "single player: the stock hotkey puts back the helmet taken off before the save")
		end
		return
	end

	check(local_value(N, "nvg_gain_current") == 1.5 and local_value(N, "gain_directionality") == false,
		label .. "the NVG gain and direction of the save come back once the co-op host starts its session")
	check(O.memory_contain("outfit_a") and O.memory_contain("outfit_b"),
		label .. "the FDDA outfit memory of the save comes back once the co-op host starts its session")
	local timer = TIMEEV["exo_powers:deactivate_power"]
	check(local_value(X, "on_cooldown") == true and timer and timer.at == NOW + 13000,
		label .. "the exo-powers cooldown of the save comes back once the co-op host starts its session")
	local saved = {}
	SendScriptCallback("save_state", saved)
	check(records_saved(saved), label .. "the next save in the session writes the save's records, not the mods' defaults")
	H.toggle_helmet()
	check(rawequal(equipped, own), label .. "the helmet hotkey puts back the helmet taken off before the save")

	-- Restored once: what the player sets afterwards stays.
	set_local(N, "nvg_gain_current", 2)
	SendScriptCallback("actor_on_update")
	SendScriptCallback("actor_on_update")
	check(local_value(N, "nvg_gain_current") == 2, label .. "the save's records are restored once")

	-- A level change in the session: its load_state has the session, so the records come back at the load and nothing
	-- waits; then one during which the session is down: they come back once it is up again, and only then.
	local function gain() return local_value(N, "nvg_gain_current") end
	local waiting = axr_main.count("actor_on_update")
	set_local(N, "nvg_gain_current", 2.5)
	local trip = {}
	SendScriptCallback("save_state", trip)
	set_local(N, "nvg_gain_current", 1)
	alife_storage_manager.CALifeStorageManager_load(trip)
	check(gain() == 2.5 and axr_main.count("actor_on_update") == waiting,
		label .. "a level change in the session restores the records at its load, and nothing waits for a session")
	set_local(N, "nvg_gain_current", 3)
	SendScriptCallback("actor_on_update")
	check(gain() == 3, label .. "a level change in the session restores the records once")
	hosting = false
	alife_storage_manager.CALifeStorageManager_load(trip)
	SendScriptCallback("actor_on_update")
	check(gain() == 3, label .. "a load while the session is down restores nothing yet")
	hosting = true
	SendScriptCallback("actor_on_update")
	check(gain() == 2.5, label .. "a load while the session was down: the records come back once it is up again")
	set_local(N, "nvg_gain_current", 3)
	SendScriptCallback("actor_on_update")
	check(gain() == 3 and axr_main.count("actor_on_update") == waiting,
		label .. "that load's records are restored once, and nothing waits for a session any more")
end

local passed, failed = 0, 0
local function run(variant)
	local env = {}; for k, v in pairs(_G) do env[k] = v end; env._G = env
	env.loadstring = function(...)
		local f, err = loadstring(...); if f then setfenv(f, env) end; return f, err
	end
	env.dofile = function(path) local f = assert(loadfile(path)); setfenv(f, env); return f() end
	setfenv(scenario, env)
	local ok, e = pcall(scenario, variant)
	passed = passed + (env.PASSES or 0); failed = failed + (env.FAILS or 0)
	if not ok then
		failed = failed + 1
		print("FAIL " .. mode .. " (" .. variant .. "): " .. tostring(e))
	end
end
run("update")
run("save")
run("save_m_data")
print(string.format("mods misc late session %s: %d passed, %d failed", mode, passed, failed))
if failed > 0 then error("MODS MISC LATE SESSION FAILED") end
