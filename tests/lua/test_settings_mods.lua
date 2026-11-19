-- Dev 57 G2-1: real settings overlay + unchanged GAMMA functions in isolated machines.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
load_coop_main()
local ENCODE, DECODE = coop_main.encode, coop_main.decode
local modes = dofile("tests/lua/support/modes.lua")
local CORPUS = "temp/review/corpus/merged/"

local function read(path)
	local f = assert(io.open(path, "rb"), path)
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end

local function between(s, first, last)
	local a = assert(s:find(first, 1, true), first)
	local b = assert(s:find(last, a + #first, true), last)
	return s:sub(a, b - 1)
end

local function module(W, name, src)
	local header = 'local this = {}; ' .. name .. ' = this; setmetatable(this, {__index = _G}); setfenv(1, this); '
	local f = assert(loadstring(header .. src, "@" .. name .. ".script"))
	setfenv(f, W)
	f()
	return W[name]
end

local SMR = read(CORPUS .. "smr_config.script")
local DAO = read(CORPUS .. "drx_da_main.script")
local MTOP = read(CORPUS .. "ui_mod_elements.script")
local UIO = read(CORPUS .. "ui_options.script")
local NPE_MCM = read(CORPUS .. "npe_mcm.script")
local NPE = read(CORPUS .. "npe_director.script")
local OPTIONS_BUILDER = read(CORPUS .. "options_builder.script")
local EXES_PAGES = {
	{ "visual/", "3d_scopes", "sds_speed_enable", true },
	{ "visual/", "graphics", "r__ssa_discard_exp", 1.4 },
	{ "", "optimizations", "lua_gcstep", 500 },
}
local ADAPTER_PATH = "gamedata/scripts/coop_settings_mods.script"
local f = io.open(ADAPTER_PATH, "rb")
local ADAPTER = f and f:read("*a")
if f then f:close() end

local PERSONAL = {
	{ "mcm", "pawsys/pawgen/enabled", true, false },
	{ "mcm", "pawsys/pawhud/active_theme", "classic", "minimal_h" },
	{ "mcm", "pawsys/pawbinds/bind_cartmode", 53, 39 },
	{ "mcm", "pawsys/pawbinds/modk_cartmode", 1, 3 },
	{ "mcm", "npe_module/gamma_tutorial_ammo/ammo", false, true },
	{ "options", "modded_exes/visual/3d_scopes/sds_speed_enable", true, false },
	{ "options", "modded_exes/visual/graphics/r__ssa_discard_exp", 0.8, 1.4 },
	{ "options", "modded_exes/optimizations/lua_gcstep", 300, 500 },
}
local SMR_PERSONAL = { "SMR/smr_loot/send_message", "SMR/smr_amain/smr_debug_log", "SMR/smr_amain/glitched_pda" }
local NAME_PATH = "gameplay/general/player_name"
local NICK_PATH = "coop/coop_player/nick"

local function make_world(role, index, saved, stash, adapter_first)
	local W = setmetatable({}, { __index = _G })
	local mirror = role == "coop_client" or role == "srv_player"
	W._G, W.role, W.NOW = W, role, 100000
	W.cbs, W.handlers, W.commands, W.logs, W.stash, W.outbox = {}, {}, {}, {}, stash or {}, {}
	W.data = saved or { options = {}, mcm = {} }
	for _, p in ipairs(PERSONAL) do
		if not saved then W.data[p[1]][p[2]] = tostring(p[index + 2]) end
	end
	for _, p in ipairs(SMR_PERSONAL) do if not saved then W.data.mcm[p] = "false" end end
	W.DAO_WORLD, W.INFO_WRITES, W.RENAMES, W.saves = 0, 0, 0, 0
	W.printf = function(fmt, ...) W.logs[#W.logs + 1] = string.format(fmt, ...) end
	W.printe = W.printf
	W.time_global = function() return W.NOW end
	W.coop = {
		is_active = function() return W.role ~= "none" end,
		is_host = function() return W.role == "hostplay" or W.role == "srv_world" end,
		is_client = function() return W.role ~= "none" and (mirror or W.role == "srv_map") end,
		is_map_server = function() return W.role == "srv_map" end,
		is_dedicated = function() return W.role == "srv_world" end,
		is_live = function() return W.role ~= "none" end,
		stash_get = function(k) return W.stash[k] end,
		stash_set = function(k, v) W.stash[k] = v; return true end,
		send_event = function(name, payload, target)
			W.outbox[#W.outbox + 1] = { name = name, payload = payload, target = target }
			return true
		end,
		players = function() return {} end,
	}
	W.coop_main = { encode = ENCODE, decode = DECODE,
		add_event_handler = function(n, h) W.handlers[n] = h end,
		callback_registered = function(n, h) return W.cbs[n] and W.cbs[n][h] ~= nil or false end }
	W.RegisterScriptCallback = function(n, h)
		if not h then return end
		W.cbs[n] = W.cbs[n] or {}
		W.cbs[n][h] = true
	end
	W.UnregisterScriptCallback = function(n, h) if W.cbs[n] then W.cbs[n][h] = nil end end
	W.SendScriptCallback = function(n, ...)
		for h in pairs(W.cbs[n] or {}) do
			-- The real router does not run DAO's world callback on a player's mirror.
			if not (mirror and W.role ~= "none" and getfenv(h) == W.drx_da_main) then h(...) end
		end
	end
	local cls = {}
	W.ini_file_ex = cls
	local config = setmetatable({}, { __index = cls })
	function cls:r_value(sec, key, typ, def)
		local v = W.data[sec] and W.data[sec][key]
		if v == nil then return def end
		if typ == 1 then return v == "true" or v == true end
		if typ == 2 then return tonumber(v) end
		return v
	end
	function cls:w_value(sec, key, v) W.data[sec] = W.data[sec] or {}; W.data[sec][key] = tostring(v) end
	function cls:save() W.saves = W.saves + 1 end
	function cls:collect_section(sec) local t = {}; for k, v in pairs(W.data[sec] or {}) do t[k] = v end; return t end
	W.axr_main = { config = config }
	W.coop_game_settings = { locked = function() return false end }
	W.level = { present = function() return true end, name = function() return "l01_escape" end }
	W.db = { actor = { money = function() return 500 end } }
	W.alife_storage_manager = { get_state = function() return {} end }
	W.smr_amain_mcm = { get_config = function() return W.persist_override == true end }
	W.str_explode = function(s) local t = {}; for p in s:gmatch("[^/]+") do t[#t + 1] = p end; return t end
	local function typed_get(sec, key)
		local typ
		for _, p in ipairs(PERSONAL) do if p[1] == sec and p[2] == key then typ = type(p[3]) end end
		if key:find("SMR/", 1, true) == 1 then typ = "boolean" end
		if key == "drx_da/electric_field_modifier" then typ = "number" end
		return config:r_value(sec, key, typ == "boolean" and 1 or typ == "number" and 2 or 0)
	end
	W.ui_mcm = { get = function(k) return typed_get("mcm", k) end,
		set = function(k, v) config:w_value("mcm", k, v) end }
	module(W, "npe_mcm", between(NPE_MCM, "function npe_module_get_setting(", "function npe_module_installed("))
	module(W, "npe_director", [[
		local npeConfig = { decks = {} }
		local LOG = {}
		local function printlog() end
		function set_deck(deck) npeConfig.decks = { [deck.id] = deck } end
	]] .. between(NPE, "function apply_state(", "-- this queue")
		.. between(NPE, "function Update_set_played_state(", "\n-------------------------------------------------- NPE decks override")
		.. "\nfunction refresh_decks() update_decks_from_mcm() end\n")
	W.RegisterScriptCallback("on_option_change", W.npe_director.refresh_decks)
	local menu_cls = {}
	function menu_cls:CacheValue(path, opt, value) self.cached = { path .. "/" .. opt, value } end
	function menu_cls:Update() end
	function menu_cls:Reset_opt(tree, path)
		self.rows = tree.gr
		for _, v in ipairs(tree.gr) do
			if v.type == "input" and (v.id == "player_name" or v.id == "nick") then
				self:Register_Input(self.xml, nil, path, v.id, v, {})
			elseif v.type == "check" or v.type == "track" or v.type == "input" then
				local ctrl = { enabled = true, Enable = function(c, b) c.enabled = b end }
				self:Register(ctrl, path .. "/" .. v.id .. "/1")
			end
		end
	end
	W.ui_options = { UIOptions = menu_cls, get = function(k) return typed_get("options", k) end,
		set = function(k, v) config:w_value("options", k, v) end,
		get_opt_table = function() return {} end }
	W.ui_mcm.UIMCM = {}
	for k, v in pairs(menu_cls) do W.ui_mcm.UIMCM[k] = v end
	W.ui_options.opt_temp, W.ui_options.opt_backup = {}, {}
	W.cc = function(path, opt) return path .. "/" .. opt end
	W.s_gsub, W._opt_ = string.gsub, "/"
	W.exec = function(fn, ...) return fn(...) end
	W.empty_table = function(t) for k in pairs(t) do t[k] = nil end end
	W.print_dbg = function() end
	W.get_console_cmd = function(_, cmd)
		if cmd == "coop_nick" then return W.nick or "RayNick" end
		if cmd == "sds_speed_enable" then return false end
		if cmd == "r__ssa_discard_exp" then return "1" end
		if cmd == "lua_gcstep" then return "400" end
		return nil
	end
	W.get_console = function()
		return { get_variable_bounds = function() return { min = 0, max = 1000 } end }
	end
	W.clamp = function(n, lo, hi) return math.max(lo, math.min(hi, n)) end
	W.round_idp = function(n) return n end
	W.exec_console_cmd = function(cmd)
		W.commands[#W.commands + 1] = cmd
		if cmd:sub(1, 10) == "coop_nick " then W.nick = cmd:sub(11) end
	end
	W.alife = function() return { actor = function() return {
		character_name = function() return "Character" end,
		set_character_name = function(_, n) W.RENAMES = W.RENAMES + 1; W.character_name = n end } end } end
	-- Exact corpus functions; no copied/reimplemented name-apply logic.
	local opts = W.ui_options
	setfenv(assert(loadstring(between(UIO, "function func_player_name()", "function func_gameplay_diff"))), opts)()
	setfenv(assert(loadstring(between(UIO, "function curr_player_name()", "function curr_economy"))), opts)()
	opts.opt_section = "options"
	setmetatable(opts, { __index = W })
	W.name_row = { id = "player_name", type = "input", val = 0,
		curr = { opts.curr_player_name }, functor = { opts.func_player_name } }
	local nick_page = module(W, "coop_menu_options", read("gamedata/scripts/coop_menu_options.script")).build_page()
	W.nick_page = nick_page.gr[1]
	opts.options = { { id = "gameplay", gr = { { id = "general", gr = { W.name_row } } } }, nick_page }
	local cache_test_control = menu_cls.CacheValue
	setfenv(assert(loadstring(between(UIO, "function UIOptions:Register_Input(", "function UIOptions:Register_Track("))), opts)()
	setfenv(assert(loadstring(between(UIO, "function UIOptions:GetValue(", "function UIOptions:GetContent("))), opts)()
	setfenv(assert(loadstring(between(UIO, "function UIOptions:GetOption(", "function UIOptions:UpdatePending("))), opts)()
	setfenv(assert(loadstring(between(UIO, "function UIOptions:On_Accept()", "function UIOptions:On_Cancel()"))), opts)()
	local actual_cache = menu_cls.CacheValue
	function menu_cls:CacheValue(path, opt, value, v)
		if v.type == "input" or v.cmd then return actual_cache(self, path, opt, value, v) end
		return cache_test_control(self, path, opt, value)
	end
	function menu_cls:Register_Cap() return 1 end
	function menu_cls:UpdatePending() end

	module(W, "smr_config", SMR)
	W.drx_da_main_mcm = { op = { gr = { { id = "electric_field_modifier", def = 1 }, { id = "delete_dynamic_anomalies", def = false } } } }
	W.unregister_anomalies_behaviour = function() W.DAO_WORLD = W.DAO_WORLD + 1 end
	W.force_clean_dynamic_anomalies_global, W.build_anomalies_pos_tree = function() end, function() end
	W.updated_anomaly_levels = {}
	local dao_src = between(DAO, "-- MCM\n", "-- UTILS\n") ..
		between(DAO, "local function on_option_change()", "-- Patches\n") ..
		"\nfunction cache() return settings end\n"
	module(W, "drx_da_main", dao_src)

	W.ui_events = { BUTTON_CLICKED = 1, EDIT_TEXT_COMMIT = 2 }
	W.Frect = function() return { set = function(self) return self end } end
	W.CUIScriptWnd = { Update = function() end }
	local function control()
		return { SetCheck = function(c, v) c.checked = v end, GetCheck = function(c) return c.checked end,
			Show = function() end, Enable = function() end, SetText = function() end,
			TextControl = function(c) return c end }
	end
	W.CScriptXmlInit = function() return { ParseFile = function() end,
		InitStatic = control, InitCheck = control } end
	W.CUIMessageBoxEx = control
	W.has_alife_info = function() return true end -- alien save's flags must not become our defaults
	W.give_info = function() W.INFO_WRITES = W.INFO_WRITES + 1 end
	W.disable_info = W.give_info
	W.object_alive = function() return true end
	local cards = { card_game_21_point = {} }
	setmetatable(cards, { __index = W })
	setfenv(assert(loadstring(between(MTOP, "function card_game_21_point:InitControls()", "function card_game_21_point:OnKeyboard("))), cards)()
	setfenv(assert(loadstring(between(MTOP, "function info_get_boolean(", "-- '"))), cards)()
	W.ui_mod_elements = cards
	local card_cls = cards.card_game_21_point
	card_cls.SetWndRect, card_cls.Register = function() end, function() end
	card_cls.start_button = function(self, _, name) self["get_" .. name] = control() end
	card_cls.AddCallback = function(self, id, ev, cb, ctx) self.callbacks[id] = function() cb(ctx) end end
	card_cls.btn_exit_game = function() end
	W.new_card = function()
		local o = setmetatable({ callbacks = {} }, { __index = card_cls })
		o:InitControls(); o:InitCallBacks()
		return o
	end
	W.new_menu = function(store)
		return setmetatable({ controls = {}, _Cap = {}, Register = function(self, c, id) self.controls[id] = c end,
			xml = { InitEditBox = function()
				return { GetHeight = function() return 1 end, SetText = function(c, s) c.text = s end,
					GetText = function(c) return c.text end }
			end },
			AddCallback = function(self, id, event, cb, ctx)
				if event == W.ui_events.EDIT_TEXT_COMMIT then self.last_input = id; self.controls[id].commit = function() cb(ctx) end end
			end,
			On_Cancel = function() end }, { __index = store == "mcm" and W.ui_mcm.UIMCM or menu_cls })
	end
	module(W, "coop_mode", read("gamedata/scripts/coop_mode.script"))
	if mirror then
		modes.install(W.coop_mode, role == "coop_client" and "hostplay" or "srv_world", {
			actor_is_player = function() return true end,
			decider = function() return "other" end,
			is_player_mirror = function() return true end,
			decides_world = function() return false end,
			leads_here = function() return false end,
			where = function(peer) return peer == index and "here" or "away" end,
		})
	else
		modes.install(W.coop_mode, role)
	end
	module(W, "coop_mods_core", read("gamedata/scripts/coop_mods_core.script"))
	module(W, "coop_settings", read("gamedata/scripts/coop_settings.script")).on_game_start()
	local function adapter()
		if ADAPTER then module(W, "coop_settings_mods", ADAPTER).on_game_start() end
	end
	if adapter_first then adapter() end
	W.smr_config.on_game_start()
	W.drx_da_main.on_game_start()
	if not adapter_first then adapter() end
	return W
end

local function expect(W, condition, name) check(condition, W.role .. ": " .. name) end

local roles = {}
for _, role in ipairs(modes.names()) do
	roles[#roles + 1] = role
	if role == "hostplay" then roles[#roles + 1] = "coop_client" end
	if role == "srv_world" then roles[#roles + 1] = "srv_player" end
end
for _, role in ipairs(roles) do
	local W = make_world(role, 2)
	for _, p in ipairs(PERSONAL) do
		expect(W, W.coop_settings.owner_of(p[1], p[2]) == "player", "classification " .. p[2])
	end
	expect(W, W.coop_settings.owner_of("mcm", "drx_da/electric_field_modifier") == "host", "DAO remains world-owned")
	expect(W, W.coop_settings.owner_of("options", "modded_exes/optimizations/spawn_antifreeze") == "host", "exact exes rows do not unlock unrelated options")
	local data = { smr_amain = {}, smr_loot = {} }
	for _, p in ipairs(SMR_PERSONAL) do data[p:match("^SMR/([^/]+)")][p] = true end
	data.smr_amain["SMR/smr_amain/spawn_chance"] = 0.25
	W.data.mcm["SMR/smr_amain/spawn_chance"] = "0.7"
	W.SendScriptCallback("load_state", data)
	for _, p in ipairs(SMR_PERSONAL) do
		expect(W, W.ui_mcm.get(p) == (role == "none"), "SMR excludes only local key " .. p)
	end
	expect(W, data.smr_amain[SMR_PERSONAL[2]] == true, "SMR never mutates incoming save")
	if not W.coop.is_client() then
		expect(W, tonumber(W.data.mcm["SMR/smr_amain/spawn_chance"]) == 0.25, "SMR still loads world settings")
	else
		expect(W, W.data.mcm["SMR/smr_amain/spawn_chance"] == "0.7", "SMR mirror keeps the local world value untouched")
	end
	W.data.mcm["drx_da/electric_field_modifier"] = "0.4"
	W.SendScriptCallback("on_option_change")
	expect(W, W.drx_da_main.cache().electric_field_modifier == 0.4, "DAO later cache refresh")
	if W.coop_mode.is_player_mirror() then expect(W, W.DAO_WORLD == 0, "DAO cache refresh never calls world callback") end
	local o = W.new_card()
	expect(W, o.check_save_rate:GetCheck() == (role == "none"), "MTOP new window reads machine setting")
	if role ~= "none" then
		o.check_save_rate:SetCheck(true)
		if o.callbacks.coop_settings_save_rate then o.callbacks.coop_settings_save_rate() end
		local n = W.new_card()
		expect(W, n.check_save_rate:GetCheck() == true, "MTOP toggle persists before Update")
		o.check_increasing:SetCheck(true)
		if o.callbacks.coop_settings_increasing then o.callbacks.coop_settings_increasing() end
		n = W.new_card()
		expect(W, n.check_increasing:GetCheck() == true, "MTOP second toggle persists")
		o.check_save_rate:SetCheck(false)
		if o.callbacks.coop_settings_save_rate then o.callbacks.coop_settings_save_rate() end
		expect(W, W.new_card().check_save_rate:GetCheck() == false, "MTOP false is saved, not replaced by a default")
		local saves_before_click = W.saves
		-- CUICheckButton also sends BUTTON_CLICKED for right and middle clicks, without toggling.
		if n.callbacks.coop_settings_save_rate then n.callbacks.coop_settings_save_rate() end
		expect(W, W.new_card().check_save_rate:GetCheck() == false and W.saves == saves_before_click,
			"MTOP a click without a toggle cannot save a stale checkbox")
		local saved_before = W.saves
		n.check_save_rate:SetCheck(true) -- a second, stale window has a different choice
		local env = W.ui_mod_elements
		env.card_game_21_rate, env.value_card_21_max_rate, env.card_game_21_increasing_rate = 0, 500, 50
		env.card_game_21_stage, env.card_game_21_show_winner = "need_rate", "hide"
		env.st_21_point_rate_field, env.st_21_point_infoline_1, env.st_21_point_money, env.st_21_point_infoline_2 = "", "", "", ""
		n:Update()
		expect(W, W.new_card().check_save_rate:GetCheck() == false and W.saves == saved_before,
			"MTOP stale window Update cannot overwrite a choice or write local settings")
	end
	-- Execute the entire original Update: no checkbox may touch world info portions.
	local env = W.ui_mod_elements
	env.card_game_21_rate, env.value_card_21_max_rate, env.card_game_21_increasing_rate = 0, 500, 50
	env.card_game_21_stage, env.card_game_21_show_winner = "need_rate", "hide"
	env.st_21_point_rate_field, env.st_21_point_infoline_1, env.st_21_point_money, env.st_21_point_infoline_2 = "", "", "", ""
	local before = W.INFO_WRITES
	o:Update()
	expect(W, W.INFO_WRITES - before == (role == "none" and 2 or 0), "MTOP Update has no world writes in a session")
	W.ui_mod_elements.info_give_on_boolean(true, "unrelated_info")
	expect(W, W.INFO_WRITES - before == (role == "none" and 3 or 1), "MTOP unrelated infos unchanged")
	W.data.options[NAME_PATH] = "OfflineName"
	local menu, general = W.new_menu(), { gr = { W.name_row } }
	menu:Reset_opt(general, "gameplay/general")
	local first_id = menu.last_input
	expect(W, menu.controls[first_id]:GetText() == (role == "none" and "Character" or "RayNick"),
		"name field displays the current nickname only in session")
	if role ~= "none" then
		menu:Reset_opt(W.nick_page, "coop/coop_player")
		local nick = menu.controls[menu.last_input]
		nick:SetText("FirstNick")
		nick.commit()
		menu:Reset_opt(general, "gameplay/general")
		expect(W, menu.controls[menu.last_input]:GetText() == "FirstNick", "both nick fields share pending edits")
		menu:Reset_opt(general, "gameplay/general")
		expect(W, menu.last_input ~= first_id, "re-created nick input has a new callback ID")
	end
	local input = menu.controls[menu.last_input]
	input:SetText("NewNick")
	input.commit()
	menu:On_Accept()
	expect(W, W.RENAMES == (role == "none" and 1 or 0), "name apply never renames a session character locally")
	expect(W, role == "none" or W.nick == "NewNick", "name apply uses coop_nick")
	expect(W, W.data.options[NAME_PATH] == "OfflineName", "name apply preserves the offline name option")
	if role ~= "none" then
		local nick_writes = 0
		for _, cmd in ipairs(W.commands) do if cmd:match("^coop_nick ") then nick_writes = nick_writes + 1 end end
		expect(W, nick_writes == 1, "applying edits made in both nick fields runs one console command")
	end
	expect(W, W.name_row.cmd == nil and W.name_row.curr ~= nil, "shared name definition remains unchanged")
	W.persist_override = true
	W.data.mcm[SMR_PERSONAL[1]] = "false"
	W.SendScriptCallback("load_state", data)
	expect(W, W.data.mcm[SMR_PERSONAL[1]] == "false", "SMR persist override still skips loading")
	if ADAPTER then
		local count = #W.coop_mods_core.wrapped
		W.coop_settings_mods.on_game_start()
		expect(W, #W.coop_mods_core.wrapped == count, "startup is idempotent")
	end
end

-- Use real settings requests and snapshot/delta generation. Transport is stubbed at send_event.
local function settings_pair(authority, clients, mode)
	authority.data.mcm["drx_da/electric_field_modifier"] = "0"
	for peer, W in pairs(clients) do
		W.SendScriptCallback("actor_on_update")
		local request = W.outbox[1]
		expect(W, request and request.name == "coop_set_req" and request.target == 0, mode .. " requests settings from peer zero")
		authority.handlers[request.name](request.payload, peer)
		for _, msg in ipairs(authority.outbox) do
			if msg.target == peer then
				local fields = DECODE(msg.payload)
				for _, p in ipairs(PERSONAL) do
					local prefix = p[1] == "mcm" and "m|" or "o|"
					expect(W, fields[prefix .. p[2]] == nil, mode .. " snapshot excludes " .. p[2])
				end
				W.handlers[msg.name](msg.payload, 0)
			end
		end
		expect(W, W.drx_da_main.cache().electric_field_modifier == 0, mode .. " DAO join refresh")
	end
	local before = #authority.outbox
	authority.data.mcm["drx_da/electric_field_modifier"] = "0.7"
	authority.coop.players = function() return { {}, {} } end
	authority.SendScriptCallback("on_option_change")
	authority.SendScriptCallback("actor_on_update")
	expect(authority, #authority.outbox == before + 1, mode .. " authority broadcasts one settings delta")
	local delta = authority.outbox[before + 1]
	expect(authority, delta and delta.target == -1, mode .. " settings delta goes to all world clients")
	for _, W in pairs(clients) do
		if delta then W.handlers[delta.name](delta.payload, 0) end
		expect(W, W.drx_da_main.cache().electric_field_modifier == 0.7, mode .. " DAO delta refresh")
		if W.coop_mode.is_player_mirror() then
			expect(W, W.DAO_WORLD == 0, mode .. " DAO refresh does not run world behavior on mirrors")
		end
	end
end

local function player_settings(role, A, B, mode)
	for i, W in ipairs({ A, B }) do
		for _, p in ipairs(PERSONAL) do
			local getter = p[1] == "mcm" and W.ui_mcm.get or W.ui_options.get
			expect(W, getter(p[2]) == p[i + 2], mode .. " independent after join " .. p[2])
			local path, opt = p[2]:match("^(.*)/([^/]+)$")
			local menu = W.new_menu(p[1])
			menu:CacheValue(path, opt, p[i + 2], {})
			expect(W, menu.cached[2] == p[i + 2], mode .. " client menu accepts " .. p[2])
			menu:Reset_opt({ gr = { { id = opt, type = "input" } } }, path)
			local ctrl = menu.controls[path .. "/" .. opt .. "/1"]
			expect(W, ctrl and ctrl.enabled, mode .. " client control enabled " .. p[2])
			local setter = p[1] == "mcm" and W.ui_mcm.set or W.ui_options.set
			setter(p[2], p[5 - i])
			expect(W, getter(p[2]) == p[5 - i], mode .. " client can change personal option " .. p[2])
		end
		local deck_id = "gamma_tutorial_ammo"
		local set = { module = deck_id, id = "ammo", context = { event = { handler = {} } } }
		W.npe_director.set_deck({ id = deck_id, module = deck_id, sets = { ammo = set } })
		W.npe_mcm.npe_module_set_setting(deck_id, "ammo", i ~= 1)
		W.npe_director.apply_state({ [deck_id] = { ammo = { played = i == 1 } } })
		W.ui_mcm.set("drx_da/electric_field_modifier", 99)
		W.SendScriptCallback("on_option_change")
		expect(W, set.played == (i == 1), mode .. " NPE reloads each player's played flag after apply_state")
		expect(W, W.drx_da_main.cache().electric_field_modifier == 0.7 and W.DAO_WORLD == 0,
			mode .. " client cannot override world-owned DAO value")
		local card = W.new_card()
		card.check_save_rate:SetCheck(i == 1)
		if card.callbacks.coop_settings_save_rate then card.callbacks.coop_settings_save_rate() end
		card.check_increasing:SetCheck(i == 2)
		if card.callbacks.coop_settings_increasing then card.callbacks.coop_settings_increasing() end
		local L = make_world(role, i, W.data, W.stash)
		L.SendScriptCallback("actor_on_first_update")
		for _, p in ipairs(PERSONAL) do
			local getter = p[1] == "mcm" and L.ui_mcm.get or L.ui_options.get
			expect(L, getter(p[2]) == p[5 - i], mode .. " independent after level change " .. p[2])
		end
		local loaded_set = { context = { event = { handler = {} } }, id = "ammo" }
		L.npe_director.set_deck({ id = deck_id, module = deck_id, sets = { ammo = loaded_set } })
		L.SendScriptCallback("on_option_change")
		expect(L, loaded_set.played == (i == 1), mode .. " NPE loads the saved local flag in a fresh Lua state")
		expect(L, L.drx_da_main.cache().electric_field_modifier == 0.7, mode .. " DAO stash refresh on level load")
		local card_after = L.new_card()
		expect(L, card_after.check_save_rate:GetCheck() == (i == 1) and card_after.check_increasing:GetCheck() == (i == 2),
			mode .. " MTOP preferences stay independent after reload")
	end
end

local function modded_exes_menu(W)
	module(W, "options_builder", OPTIONS_BUILDER)
	local visual = { id = "visual", gr = {} }
	local exes = { id = "modded_exes", gr = { visual } }
	table.insert(W.ui_options.options, exes)
	for _, spec in ipairs(EXES_PAGES) do
		local group, page_id, id, value = unpack(spec)
		local file = "options_modded_exes_" .. page_id
		local page = module(W, file, read(CORPUS .. file .. ".script")).PAGE
		local target = group == "" and exes or visual
		table.insert(target.gr, page)
		local path = "modded_exes/" .. group .. page.id
		local menu = W.new_menu()
		menu:Reset_opt(page, path)
		local control = menu.controls[path .. "/" .. id .. "/1"]
		local row = menu:GetOption(path .. "/" .. id)
		expect(W, row.cmd == id and control and control.enabled, "modded exes menu exposes " .. id)
		menu:CacheValue(path, id, value, row)
		menu:On_Accept()
		local command = id .. " " .. (type(value) == "boolean" and "on" or tostring(value))
		expect(W, W.commands[#W.commands - 1] == command, "modded exes Apply sends " .. command)
	end
end

for _, role in ipairs(modes.names()) do
	if role == "hostplay" or role == "srv_world" then
		local mode = role == "hostplay" and "Co-op" or "Server"
		local player = role == "hostplay" and "coop_client" or "srv_player"
		local authority = make_world(role, 1)
		local A, B = make_world(player, 1, nil, nil, true), make_world(player, 2)
		settings_pair(authority, { A, B }, mode)
		player_settings(player, A, B, mode)
		modded_exes_menu(A)
	elseif role == "srv_map" then
		local authority = make_world("srv_world", 1)
		local A, B = make_world("srv_map", 1), make_world("srv_map", 2)
		settings_pair(authority, { [0x101] = A, [0x102] = B }, "Server bridges")
		local reloaded = make_world("srv_map", 1, A.data, A.stash)
		expect(reloaded, reloaded.drx_da_main.cache().electric_field_modifier == 0.7 and reloaded.DAO_WORLD == 0,
			"Server map Lua reload refreshes DAO from its settings stash without the world callback")
	end
end

-- An exception while loading must release SMR's scoped write filter; local MCM edits still work.
do
	local W = make_world("hostplay", 1)
	local collect = W.axr_main.config.collect_section
	W.axr_main.config.collect_section = function() error("test load error") end
	local ok = pcall(W.SendScriptCallback, "load_state", {})
	expect(W, not ok, "SMR original exception propagates")
	W.axr_main.config.collect_section = collect
	W.ui_mcm.set(SMR_PERSONAL[1], true)
	expect(W, W.ui_mcm.get(SMR_PERSONAL[1]) == true, "SMR exception leaves no lingering write filter")
	if ADAPTER then
		W.coop_mods_core.mod = function() return nil end
		local a = module(W, "coop_settings_mods", ADAPTER)
		expect(W, pcall(a.on_game_start), "missing mods never break startup")
		W.coop_mods_core.mod = function() error("test outdated module") end
		expect(W, pcall(a.on_game_start), "each startup step is protected")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
