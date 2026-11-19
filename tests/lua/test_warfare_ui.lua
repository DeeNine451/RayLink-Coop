-- Dev 57 G18-1 (TZ R19, phase 4): the Warfare PDA in a session (gamedata\scripts\coop_warfare_ui.script,
-- gamedata\configs\coop_compat_warfare.ltx). Run: tools\test_lua.cmd warfare_ui
-- One case or more per finding (docs\reports\2026-11-18-f4-gamma-review.md):
--   s37:1 pda_smart_terrain_warfare.script:128      the influence menu at the player, orders carried out by the world
--   s37:2 pda_actor.script:57                        manual control is the world's: a request, the menu shows the answer
--   s37:3 pda_flagger.script:56, pda_actor.script:26 the leading faction, points and influence on the player's machine
--   s41:3 ui_pda_warfare_tab.script:101              the war tab from the world's summary, refreshed by the answer
--   s42:2 warfare.script:828                         _G.WARFARE by the world's mode on every machine
-- The stock PDA scripts are the real files of temp\stock_scripts\scripts (GAMMA overrides none of them: they are not in
-- temp\review\corpus\merged); warfare itself is a table with the fields they read. Every answer set of the facade runs on its
-- own (COOP_LUA_MODE): hostplay - the co-op host and its client; srv_world - the world server and a server player; srv_map - a
-- map server (not the world) and a server player on it, the world being a world server; none - single player, the stock game.
local modes = dofile("tests/lua/support/modes.lua")
local STOCK = "temp/stock_scripts/scripts/"
local ADAPTER = "gamedata/scripts/coop_warfare_ui.script"
local passed, failed = 0, 0

local function test(name, f)
	local ok, err = pcall(f)
	if ok then
		passed = passed + 1
		print("  ok   " .. name)
	else
		failed = failed + 1
		print("  FAIL " .. name .. ": " .. tostring(err))
	end
end

local function exists(path)
	local fh = io.open(path, "r")
	if fh then fh:close() return true end
	return false
end

-------------------------------------------------------------------------------
-- The world of the tests
-------------------------------------------------------------------------------
local LEVEL_OF_GV = { [11] = 1, [21] = 2, [31] = 3 }
local GV_OF_LEVEL = { [1] = 11, [2] = 21, [3] = 31 }
-- smart terrains: id, owner, game vertex. Level 3 is not an active level (stock: not counted).
local SMARTS = {
	{ 3001, "dolg", 11 }, { 3009, "dolg", 11 }, { 3011, "dolg", 11 }, { 3002, "stalker", 11 }, { 3003, nil, 11 },
	{ 3007, "stalker", 21 }, { 3010, "stalker", 21 }, { 3012, "stalker", 21 }, { 3014, "stalker", 21 },
	{ 3004, "freedom", 21 }, { 3013, "freedom", 21 }, { 3005, "dolg", 21 }, { 3006, "monolith", 31 },
}
-- squads: id, faction, game vertex
local SQUADS = { { 2001, "stalker", 11 }, { 2002, "stalker", 11 }, { 2003, "stalker", 21 }, { 2004, "dolg", 21 },
	{ 2006, "dolg", 11 }, { 2005, "monolith", 31 } }
-- a player's copy from the save: stalker had not taken level 2 yet, squad 2003 came later
local STALE_OWNERS = { [3007] = "dolg", [3010] = "dolg", [3012] = "dolg", [3014] = "dolg" }
local STALE_SQUADS = { [2003] = true }
local FACTIONS = { "stalker", "bandit", "csky", "army", "freedom", "dolg", "ecolog", "killer", "monolith", "renegade", "greh",
	"isg", "monster", "zombied" }

local function relation(a, b)
	if a == b then return 1000 end
	local k = a < b and (a .. ":" .. b) or (b .. ":" .. a)
	local t = { ["dolg:stalker"] = -2000, ["monolith:stalker"] = -2000, ["dolg:freedom"] = -2000, ["freedom:stalker"] = 1500,
		["dolg:monolith"] = -2000, ["freedom:monolith"] = -2000 }
	return t[k] or 0
end

local MODULES = { "coop_main", "coop_route", "coop_mods_core", "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_trust",
	"coop_warfare_ui", "pda_actor", "pda_flagger", "pda_smart_terrain_warfare", "ui_pda_warfare_tab", "warfare",
	"smart_terrain_warfare", "coop_faction" }

local function widget(name, parent)
	local w = { name = name, texts = {}, frames = 0 }
	function w:SetText(t)
		self.text = t
		if parent then parent.texts[name] = tostring(t) end
	end
	function w:InitTexture(t) self.texture = t end
	function w:SetStretchTexture() end
	function w:Show() end
	function w:SetProgressPos(p)
		self.pos = p
		if parent then parent.bar = name .. "@" .. tostring(p) end
	end
	function w:SetAutoDelete() end
	function w:TextControl() return self end
	function w:Clear() self.rows = {} end
	function w:AddWindow(st) self.rows[#self.rows + 1] = st end
	return w
end

local function ui_stubs()
	function class(name)
		return function(base)
			local cls = {}
			cls.__index = cls
			setmetatable(cls, { __index = base, __call = function(c, ...)
				local o = setmetatable({}, c)
				if c.__init then c.__init(o, ...) end
				return o
			end })
			getfenv(2)[name] = cls
		end
	end
	super = function() end
	CUIScriptWnd = {
		SetWndRect = function() end, Register = function() end, AddCallback = function() end, Update = function() end,
		IsShown = function(self) return self._shown == true end,
	}
	Frect = function() return { set = function(self) return self end } end
	CScriptXmlInit = function()
		local x = {}
		function x:ParseFile() end
		function x:InitFrame(_, parent) if parent then parent.frames = (parent.frames or 0) + 1 end end
		function x:Init3tButton(name) return widget(name) end
		function x:InitScrollView(name)
			local s = widget(name)
			s.rows = {}
			return s
		end
		function x:InitStatic(name) return widget(name) end
		function x:InitTextWnd(name, parent) return widget(name, parent) end
		function x:InitProgressBar(name, parent) return widget(name, parent) end
		return x
	end
	utils_xml = { get_color = function() return "" end }
	utils_ui = { UIHint = function() return { Update = function() end } end }
	ui_events = { BUTTON_CLICKED = 17 }
	empty_table = function(t) for k in pairs(t) do t[k] = nil end end
	strformat = string.format
end

local function load_stock(name)
	local fh = assert(io.open(STOCK .. name .. ".script", "r"), "stock " .. name .. ".script (temp\\stock_scripts)")
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	assert(loadstring(header .. src, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. name .. ".script"))()
	return rawget(_G, name)
end

-- opts: peer (a mirror's own peer, 1 by default), stale (a player's copy from the save), level (where the actor stands),
-- viewer (his true faction), warfare (false: a world without Warfare), own_warfare (this machine's IsWarfare(): its own
-- axr config, stock _g.script:2807), trust ("log" | "refuse")
local function fixture(set, role, opts)
	opts = opts or {}
	MODE = set == "none" and "sp" or role == "mirror" and "client" or "host"
	VERBOSE = false
	dofile("tests/lua/support/stubs_mods.lua")
	for _, n in ipairs(MODULES) do rawset(_G, n, nil) end
	_coop_route_wrappers = nil
	SELF = role == "mirror" and (opts.peer or 1) or 0
	coop.is_map_server = function() return set == "srv_map" and role ~= "mirror" end
	coop.is_dedicated = function() return set == "srv_world" and role ~= "mirror" end
	coop.is_host = function() return MODE == "host" and set ~= "srv_map" end
	coop.is_client = function() return MODE == "client" or (set == "srv_map" and role ~= "mirror") end
	coop.players = function()
		if MODE == "sp" then return {} end
		return { { id = 0, nick = "host", is_self = SELF == 0, avatar_id = 0 },
			{ id = 1, nick = "lead", is_self = SELF == 1, avatar_id = 501 },
			{ id = 2, nick = "other", is_self = SELF == 2, avatar_id = 502 } }
	end
	ui_stubs()
	clsid = { smart_terrain = 7, online_offline_group_s = 8, script_stalker = 1, stalker = 2 }
	game_relations = { FRIENDS = 1000, ENEMIES = -1000,
		is_factions_enemies = function(a, b) return relation(a, b) <= -1000 end,
		is_factions_friends = function(a, b) return relation(a, b) >= 1000 end }
	relation_registry = { community_relation = function(a, b) return relation(a, b) end }
	VIEWER = opts.viewer or "stalker"
	get_actor_true_community = function() return VIEWER end
	INFOS, GIVEN = {}, {}
	has_alife_info = function(i) return INFOS[i] == true end
	give_info = function(i) GIVEN[#GIVEN + 1] = i end
	LOCAL_WARFARE = opts.own_warfare
	if LOCAL_WARFARE == nil then LOCAL_WARFARE = opts.warfare ~= false end
	IsWarfare = function() return LOCAL_WARFARE == true end
	level.map_add_object_spot = function() end
	level.map_remove_object_spot = function() end
	game_graph = function()
		return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF_GV[gv] or 9 end } end }
	end
	alife = function()
		return { object = function(_, id) return SE[id] end, actor = function() return SE[0] end,
			level_name = function(_, id) return "level" .. tostring(id) end, release = function() end }
	end
	level_targets = { active_levels = { 1, 2 } }
	make_actor()
	SE[0].m_game_vertex_id = GV_OF_LEVEL[opts.level or 1]
	local smart_mt = { __index = { clsid = function() return clsid.smart_terrain end } }
	local squad_mt = { __index = { clsid = function() return clsid.online_offline_group_s end,
		get_squad_community = function(self) return self.community end } }
	SIMBOARD = { smarts_by_names = {} }
	for _, s in ipairs(SMARTS) do
		local owner = s[2]
		if opts.stale and STALE_OWNERS[s[1]] then owner = STALE_OWNERS[s[1]] end
		SE[s[1]] = setmetatable({ id = s[1], owning_faction = owner, m_game_vertex_id = s[3] }, smart_mt)
		SIMBOARD.smarts_by_names["smart_" .. s[1]] = SE[s[1]]
	end
	warfare = { printd = function() end, registered_squads = {} }
	for _, f in ipairs(FACTIONS) do warfare.registered_squads[f] = {} end
	for _, q in ipairs(SQUADS) do
		SE[q[1]] = setmetatable({ id = q[1], community = q[2], m_game_vertex_id = q[3] }, squad_mt)
		if not (opts.stale and STALE_SQUADS[q[1]]) then warfare.registered_squads[q[2]][q[1]] = 3001 end
	end
	if opts.stale then
		warfare.actor_faction, warfare.actor_influence_points, warfare.influence_levels = nil, 1, {}
	else
		warfare.actor_faction, warfare.actor_influence_points, warfare.influence_levels = "stalker", 3.5, { [3001] = 2 }
	end
	smart_terrain_warfare = { hide_smarts = false }
	FACTION_OF = { [0] = set == "hostplay" and "stalker" or nil, [1] = "stalker", [2] = "dolg" }
	coop_faction = { faction_of = function(peer) return FACTION_OF[peer] end }
	alife_storage_manager.get_state().enable_warfare_mode = opts.warfare ~= false or nil

	load_script("coop_main")
	load_script("coop_route").install()
	load_script("coop_mode")
	if role == "mirror" then
		modes.install(coop_mode, set, {
			is_player_mirror = function() return true end, decides_world = function() return false end,
			leads_here = function() return false end, actor_is_player = function() return true end,
		})
	else
		modes.install(coop_mode, set)
	end
	coop_main.on_game_start()
	coop_mode.on_game_start()
	load_script("coop_mods_core").on_game_start()
	load_script("coop_trust").reset_for_test({ default = opts.trust or "log" })
	for _, n in ipairs({ "on_game_load", "map_spot_menu_add_property", "map_spot_menu_property_clicked",
		"on_localization_change" }) do AddScriptCallback(n) end
	for _, n in ipairs({ "pda_actor", "pda_flagger", "pda_smart_terrain_warfare", "ui_pda_warfare_tab" }) do load_stock(n) end
	-- axr_main.on_game_start: every script's on_game_start in file order (coop_warfare_ui comes before pda_* and warfare)
	local adapter = exists(ADAPTER) and load_script("coop_warfare_ui") or nil
	if adapter then adapter.on_game_start() end
	pda_actor.on_game_start()
	pda_flagger.on_game_start()
	pda_smart_terrain_warfare.on_game_start()
	_G.WARFARE = true -- warfare.on_game_start (warfare.script:828), on every machine
	SendScriptCallback("on_game_load")
	if not opts.loaded_only then SendScriptCallback("actor_on_first_update") end
	SENT = {}
	return { adapter = adapter }
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local function sends(verb, target)
	local out = {}
	for _, s in ipairs(SENT) do
		if s.name == "mods." .. verb and (target == nil or s.target == target) then
			out[#out + 1] = { name = s.name, payload = s.payload, target = s.target }
		end
	end
	return out
end
local function last(verb, target)
	local l = sends(verb, target)
	return l[#l]
end
local function decoded(s) return s and coop_main.decode(s.payload) or nil end
local function deliver_all(list, from)
	for _, s in ipairs(list) do coop_main.on_event(s.name, s.payload, from) end
end
local function incoming(verb, t, from) coop_main.on_event("mods." .. verb, coop_main.encode(t), from) end
local function tick(ms)
	NOW = NOW + (ms or 1500)
	SendScriptCallback("actor_on_update")
end
local function menu(id)
	local ui = { items = {} }
	function ui:AddItem(t) self.items[#self.items + 1] = t end
	SendScriptCallback("map_spot_menu_add_property", ui, id, "l01_escape")
	return ui.items
end
local function has(items, text)
	for _, t in ipairs(items) do if t == text then return true end end
	return false
end
local function click(id, prop) SendScriptCallback("map_spot_menu_property_clicked", {}, id, "l01_escape", prop) end
local function rows(tab)
	local out = {}
	for i, st in ipairs(tab.scroll.rows or {}) do
		local t = st.texts
		out[i] = table.concat({ tostring(t["faction:text_order"]), tostring(t["faction:text_faction"]),
			tostring(t["faction:info_squads"]), tostring(t["faction:info_captured_smarts"]),
			tostring(t["faction:info_major_territory"]), tostring(st.bar), tostring(st.frames) }, "|")
	end
	return table.concat(out, "\n")
end
local function world_of(set) return set == "srv_map" and "srv_world" or set end

local ADD, REM = "st_wrfr_add_influ", "st_wrfr_remove_influ"
local TAKE, RELEASE = "st_wrfr_take_control_faction", "st_wrfr_release_control_faction"

-- What the stock tab shows on the world's own data to a viewer standing on `level` (all maps, then the current map).
local function expected_rows(set, level, viewer)
	fixture(world_of(set), "world", { level = level, viewer = viewer })
	local tab = ui_pda_warfare_tab.get_ui()
	local all = rows(tab)
	tab:btn_map()
	return all, rows(tab)
end

-- The world's answers a player gets: its state broadcast and the summary of the tab.
local function world_answers(set)
	fixture(world_of(set), "world")
	tick()
	local state = last("wf_state", -1)
	incoming("wf_ask", { t = 1 }, 1)
	return state, sends("wf_sum", 1)
end

-------------------------------------------------------------------------------
-- The world: the co-op host, the world server
-------------------------------------------------------------------------------
local function world_tests(set)
	test(set .. " s37:1 world: a player's add order raises the influence as the stock menu does", function()
		fixture(set, "world")
		incoming("wf_cmd", { k = "add", s = 3001, o = 11 }, 1)
		assert(warfare.influence_levels[3001] == 3, "influence " .. tostring(warfare.influence_levels[3001]))
		assert(warfare.actor_influence_points == 3.5, "the stock add costs nothing (pda_smart_terrain_warfare.script:78-84)")
		local st = decoded(last("wf_state", -1))
		assert(st and st.w == 1 and st.i == "3001:3", "the confirmed state goes to everybody: " .. tostring(st and st.i))
	end)
	test(set .. " s37:1 world: remove takes a level back and returns the point", function()
		fixture(set, "world")
		incoming("wf_cmd", { k = "rem", s = 3001, o = 12 }, 1)
		assert(warfare.influence_levels[3001] == 1 and warfare.actor_influence_points == 4.5, "stock :86-93")
		incoming("wf_cmd", { k = "rem", s = 3001, o = 13 }, 1)
		assert(warfare.influence_levels[3001] == nil and warfare.actor_influence_points == 5.5, "level 0 is removed")
		incoming("wf_cmd", { k = "rem", s = 3001, o = 14 }, 1)
		assert(warfare.actor_influence_points == 5.5, "nothing to take back: no point")
	end)
	test(set .. " s37:1 world: forged and malformed orders are refused, the player gets the world's state", function()
		fixture(set, "world")
		incoming("wf_cmd", { k = "add", s = 2001, o = 21 }, 1) -- a squad, not a smart terrain
		incoming("wf_cmd", { k = "add", s = 9999, o = 22 }, 1) -- no such object
		assert(warfare.influence_levels[2001] == nil and warfare.influence_levels[9999] == nil, "no influence on a non-smart")
		assert(coop_trust.status().wf_order_target.failed == 2, "the target check went through coop_trust")
		local back = decoded(last("wf_state", 1))
		assert(back and back.i == "3001:2", "the refused player is told the world's state")
		for i, bad in ipairs({ { k = "add", s = 70000, o = 31 }, { k = "add", s = 1.5, o = 32 }, { k = "boom", s = 3001, o = 33 },
			{ k = "add", s = 3001 }, { k = "add", s = 3001, o = 0 }, { k = "add", s = "3001x", o = 34 },
			{ k = "ctl", m = 2, o = 35 }, { k = "add", s = -1, o = 36 } }) do
			incoming("wf_cmd", bad, 1)
			assert(warfare.influence_levels[3001] == 2 and pda_actor.manual_control == false, "malformed order " .. i .. " did something")
		end
		assert(coop_trust.status().wf_order_shape.failed == 8, "every malformed order went through coop_trust")
		incoming("wf_cmd", { k = "add", s = 3001, o = 40 }, 1)
		assert(warfare.influence_levels[3001] == 2, "the 11th order in a moment is over the rate limit (burst 10)")
		NOW = NOW + 5000
		incoming("wf_cmd", { k = "add", s = 3001, o = 41 }, 1)
		incoming("wf_cmd", { k = "add", s = 3001, o = 41 }, 1)
		assert(warfare.influence_levels[3001] == 3, "the same order id runs once: " .. tostring(warfare.influence_levels[3001]))
		assert(coop_trust.status().wf_order_once.failed == 1, "the repeat is the one-shot guard's")
	end)
	test(set .. " s37:1 world: only a player of the leading faction orders (refuse mode)", function()
		fixture(set, "world", { trust = "refuse" })
		incoming("wf_cmd", { k = "add", s = 3001, o = 51 }, 2) -- dolg
		assert(warfare.influence_levels[3001] == 2, "another faction's order refused")
		incoming("wf_cmd", { k = "add", s = 3002, o = 52 }, 1) -- own faction's point: the menu does not offer it
		assert(warfare.influence_levels[3002] == nil, "an order the menu does not offer is refused")
		warfare.actor_influence_points = 0.5
		incoming("wf_cmd", { k = "add", s = 3001, o = 53 }, 1)
		assert(warfare.influence_levels[3001] == 2, "add without a whole point is refused")
		local s = coop_trust.status()
		assert(s.wf_order_faction.refused == 1 and s.wf_order_offer.refused == 2, "refusals counted by coop_trust")
	end)
	test(set .. " s37:1 world: in log mode another faction's order is logged and let through", function()
		fixture(set, "world")
		incoming("wf_cmd", { k = "add", s = 3001, o = 61 }, 2)
		assert(warfare.influence_levels[3001] == 3, "log mode lets it through")
		local s = coop_trust.status().wf_order_faction
		assert(s and s.failed == 1 and s.refused == 0, "and says it would be refused")
	end)
	test(set .. " s37:2 world: manual control takes the wanted value", function()
		fixture(set, "world")
		incoming("wf_cmd", { k = "ctl", m = 1, o = 71 }, 1)
		assert(pda_actor.manual_control == true, "control taken")
		assert(decoded(last("wf_state", -1)).m == 1, "everybody is told")
		incoming("wf_cmd", { k = "ctl", m = 1, o = 72 }, 1) -- a second, stale click of "take"
		assert(pda_actor.manual_control == true, "a stale take does not flip it back")
		incoming("wf_cmd", { k = "ctl", m = 0, o = 73 }, 1)
		assert(pda_actor.manual_control == false, "control released")
	end)
	test(set .. " s37:3 world: faction, points, influence and who may order go out; again after a change", function()
		fixture(set, "world")
		tick()
		local st = decoded(last("wf_state", -1))
		local al = set == "hostplay" and "0,1" or "1"
		assert(st and st.w == 1 and st.f == "stalker" and st.p == 3.5 and st.m == 0 and st.i == "3001:2" and st.al == al,
			"state " .. coop_main.encode(st or {}))
		local n = #sends("wf_state", -1)
		tick()
		assert(#sends("wf_state", -1) == n, "nothing changed: nothing sent")
		warfare.actor_influence_points = 4.75 -- a kill's reward (sim_squad_warfare.script:331)
		tick()
		st = decoded(last("wf_state", -1))
		assert(#sends("wf_state", -1) == n + 1 and st.p == 4.75, "the change is sent")
	end)
	test(set .. " s41:3 world: the summary per faction and level answers a player's ask", function()
		fixture(set, "world")
		incoming("wf_ask", { t = 1 }, 1)
		assert(decoded(last("wf_state", 1)), "the asker gets the state")
		local parts = sends("wf_sum", 1)
		assert(#parts >= 1, "the summary is sent to the asker")
		local blob = {}
		for i, p in ipairs(parts) do blob[i] = coop_main.decode(p.payload).d end
		local sum = coop_mods_core.deser(table.concat(blob))
		assert(sum and sum.q.stalker[1] == 2 and sum.q.stalker[2] == 1 and sum.q.dolg[1] == 1 and sum.q.dolg[2] == 1,
			"squads per faction and level")
		assert(sum.s[1].dolg == 3 and sum.s[1].stalker == 1 and sum.s[2].stalker == 4 and sum.s[2].freedom == 2,
			"captured points per level and faction")
		assert(sum.t[1] == 5 and sum.t[2] == 7 and sum.t[3] == nil and sum.s[3] == nil, "points of active levels only")
	end)
	test(set .. " s41:3 world: a world without Warfare answers w=0 and no summary", function()
		fixture(set, "world", { warfare = false })
		incoming("wf_ask", { t = 1 }, 1)
		local st = decoded(last("wf_state", 1))
		assert(st and st.w == 0 and #sends("wf_sum") == 0, "no war, no summary")
		incoming("wf_cmd", { k = "add", s = 3001, o = 81 }, 1)
		assert(warfare.influence_levels[3001] == 2, "no orders in a world without Warfare")
		tick()
		assert(#sends("wf_state", -1) == 0, "a world without Warfare broadcasts nothing")
	end)
	if set == "hostplay" then
		test(set .. " s37:1/s37:2 the co-op host's own clicks run the world's function", function()
			fixture(set, "world")
			assert(has(menu(3001), ADD .. " (2)"), "the host's own menu")
			click(3001, ADD .. " (2)")
			assert(warfare.influence_levels[3001] == 3 and #sends("wf_cmd") == 0, "applied at once, nothing sent")
			click(0, TAKE)
			assert(pda_actor.manual_control == true and #sends("wf_cmd") == 0, "the host's own control")
			click(0, RELEASE)
			assert(pda_actor.manual_control == false, "released")
		end)
	end
end

-------------------------------------------------------------------------------
-- A player's machine: the co-op client, a server player
-------------------------------------------------------------------------------
local function mirror_tests(set)
	local state, sum = world_answers(set)
	local all1, map1 = expected_rows(set, 1, "stalker")
	local _, map2 = expected_rows(set, 2, "stalker")
	local all_dolg = expected_rows(set, 1, "dolg")
	test(set .. " s37:1 player: the smart terrain menu is there, a click is an order to the world", function()
		assert(state, "the world sent its state")
		fixture(set, "mirror", { stale = true })
		coop_main.on_event(state.name, state.payload, 0)
		local items = menu(3001)
		assert(has(items, ADD .. " (2)") and has(items, REM .. " (2)"), "menu: " .. table.concat(items, ", "))
		click(3001, ADD .. " (2)")
		local o = decoded(last("wf_cmd", 0))
		assert(o and o.k == "add" and o.s == 3001 and type(o.o) == "number", "the order goes to the world")
		assert(warfare.influence_levels[3001] == 2, "the player's copy waits for the world")
		click(3001, REM .. " (2)")
		local o2 = decoded(last("wf_cmd", 0))
		assert(o2.k == "rem" and o2.o ~= o.o, "remove is an order with its own id")
	end)
	test(set .. " s37:2 player: take control is a request; the menu follows the world's answer", function()
		fixture(set, "mirror", { stale = true })
		coop_main.on_event(state.name, state.payload, 0)
		assert(has(menu(0), TAKE), "take control offered")
		click(0, TAKE)
		local o = decoded(last("wf_cmd", 0))
		assert(o and o.k == "ctl" and o.m == 1, "the wanted value goes to the world")
		assert(pda_actor.manual_control == false, "no local toggle")
		local t = coop_main.decode(state.payload)
		t.m = 1
		incoming("wf_state", t, 0)
		assert(pda_actor.manual_control == true and has(menu(0), RELEASE), "the confirmed state shows release")
	end)
	test(set .. " s37:3 player: faction, points and influence from the world; asked on join", function()
		fixture(set, "mirror", { stale = true })
		tick()
		local ask = decoded(last("wf_ask", 0))
		assert(ask and ask.t == 0, "asked on the first update")
		assert(warfare.actor_faction == nil and not has(menu(2001), "st_wrfr_select_squad"), "nothing before the answer")
		coop_main.on_event(state.name, state.payload, 0)
		assert(warfare.actor_faction == "stalker" and warfare.actor_influence_points == 3.5
			and warfare.influence_levels[3001] == 2, "the world's values")
		assert(has(menu(0), "st_wrfr_influnence_points: 3.50"), "points: " .. table.concat(menu(0), ", "))
		assert(has(menu(2001), "st_wrfr_select_squad") and has(menu(3002), "st_wrfr_select_point"), "own squad and point")
		local n = #sends("wf_ask")
		tick(11000)
		assert(#sends("wf_ask") == n, "no new ask once answered")
	end)
	test(set .. " s37:3 player of another faction sees the war but gets no orders", function()
		fixture(set, "mirror", { stale = true, peer = 2, viewer = "dolg" })
		coop_main.on_event(state.name, state.payload, 0)
		local items = menu(3001)
		assert(not has(items, ADD .. " (2)") and not has(items, REM .. " (2)"), "no influence orders")
		local actor = menu(0)
		assert(has(actor, "st_wrfr_influnence_points: 3.50") and not has(actor, TAKE) and not has(actor, RELEASE),
			"points yes, control no: " .. table.concat(actor, ", "))
	end)
	test(set .. " s37:3 player: a state with bad values is dropped", function()
		fixture(set, "mirror", { stale = true })
		local t = coop_main.decode(state.payload)
		for _, bad in ipairs({ { p = 0 / 0 }, { p = -1 }, { i = "3001:x" }, { f = "hacker" }, { al = "1,a" }, { m = 3 },
			{ i = string.rep("1:1,", 3000) } }) do
			local b = {}
			for k, v in pairs(t) do b[k] = v end
			for k, v in pairs(bad) do b[k] = v end
			incoming("wf_state", b, 0)
		end
		incoming("wf_state", t, 1) -- not from the world
		assert(warfare.actor_faction == nil and warfare.actor_influence_points == 1, "nothing applied")
	end)
	test(set .. " s41:3 player: the war tab shows the world's numbers once its answer comes", function()
		fixture(set, "mirror", { stale = true })
		local tab = ui_pda_warfare_tab.get_ui()
		tab._shown = true
		local ask = decoded(last("wf_ask", 0))
		assert(ask and ask.t == 1, "opening the tab asks the world")
		assert(rows(tab) == "", "no stale rows before the answer: " .. rows(tab))
		deliver_all(sum, 0)
		assert(rows(tab) == all1, "all maps:\n" .. rows(tab) .. "\nexpected:\n" .. all1)
		tab:btn_map()
		assert(rows(tab) == map1, "current map:\n" .. rows(tab) .. "\nexpected:\n" .. map1)
	end)
	test(set .. " s41:3 players on two maps: each sees his own map", function()
		fixture(set, "mirror", { stale = true, level = 2 })
		local tab = ui_pda_warfare_tab.get_ui()
		tab._shown = true
		deliver_all(sum, 0)
		tab:btn_map()
		assert(rows(tab) == map2, "level 2:\n" .. rows(tab) .. "\nexpected:\n" .. map2)
		fixture(set, "mirror", { stale = true, peer = 2, viewer = "dolg" })
		tab = ui_pda_warfare_tab.get_ui()
		tab._shown = true
		deliver_all(sum, 0)
		assert(rows(tab) == all_dolg, "another faction's view:\n" .. rows(tab) .. "\nexpected:\n" .. all_dolg)
	end)
	test(set .. " s41:3 player: a bad summary is dropped", function()
		fixture(set, "mirror", { stale = true })
		local tab = ui_pda_warfare_tab.get_ui()
		tab._shown = true
		deliver_all(sum, 0)
		local good = rows(tab)
		for _, bad in ipairs({ { q = { ["x;y"] = { [1] = 1 } }, s = {}, t = {} }, { q = {}, s = { [1] = { dolg = -1 } }, t = {} },
			{ q = {}, s = {}, t = { [1] = 1.5 } }, { q = {}, s = {} }, { q = {}, s = {}, t = { ["1"] = 5 } } }) do
			coop_mods_core.send_big("wf_sum", coop_mods_core.ser(bad), 1)
			deliver_all({ table.remove(SENT) }, 0)
		end
		assert(rows(tab) == good, "rows kept")
	end)
end

-------------------------------------------------------------------------------
-- A map server: not the world
-------------------------------------------------------------------------------
local function map_server_tests()
	test("srv_map map server: no orders, no world state, no broadcast", function()
		fixture("srv_map", "world")
		incoming("wf_cmd", { k = "add", s = 3001, o = 91 }, 1)
		assert(warfare.influence_levels[3001] == 2, "an order is the world server's")
		incoming("wf_state", { w = 1, f = "stalker", p = 99, m = 1, i = "", al = "" }, 0)
		assert(warfare.actor_influence_points == 3.5 and pda_actor.manual_control == false, "a map server applies nothing")
		tick()
		assert(#sends("wf_state") == 0 and #sends("wf_ask") == 0, "it sends nothing")
	end)
end

-------------------------------------------------------------------------------
-- s42:2 _G.WARFARE
-------------------------------------------------------------------------------
local function flag_tests(set)
	if set == "none" then
		test("none s42:2 single player: the flag is the stock's business", function()
			fixture("none", "world", { warfare = false, own_warfare = false })
			assert(_G.WARFARE == true, "untouched (the stock warfare.actor_on_update clears it)")
		end)
		return
	end
	test(set .. " s42:2 this process: the flag follows the world's mode before the PDA opens", function()
		fixture(set, "world", { warfare = false, own_warfare = false })
		assert(_G.WARFARE == false, "a normal world: the contacts tab")
		fixture(set, "world")
		assert(_G.WARFARE == true, "a Warfare world: the war tab")
	end)
	test(set .. " s42:2 player: the world's mode, not this machine's own config", function()
		fixture(set, "mirror", { warfare = false, own_warfare = true, loaded_only = true })
		assert(_G.WARFARE == false, "set on on_game_load already")
		_G.WARFARE = true
		SendScriptCallback("actor_on_first_update")
		assert(_G.WARFARE == false, "and again on the first update")
		fixture(set, "mirror", { warfare = false, own_warfare = true })
		assert(_G.WARFARE == false, "a normal world on a machine whose own config says Warfare")
		fixture(set, "mirror")
		assert(_G.WARFARE == true, "the world's save says Warfare")
		incoming("wf_state", { w = 0 }, 0)
		assert(_G.WARFARE == false, "the world's answer wins")
		local t = { w = 1, f = "stalker", p = 1, m = 0, i = "", al = "1" }
		incoming("wf_state", t, 0)
		assert(_G.WARFARE == true, "and back")
	end)
end

-------------------------------------------------------------------------------
-- Single player: the stock game
-------------------------------------------------------------------------------
local function single_player_tests()
	test("none: the stock menus and tab work as without co-op", function()
		fixture("none", "world")
		assert(has(menu(3001), ADD .. " (2)"), "stock menu")
		click(3001, ADD .. " (2)")
		assert(warfare.influence_levels[3001] == 3, "stock add")
		click(0, TAKE)
		assert(pda_actor.manual_control == true, "stock toggle")
		local tab = ui_pda_warfare_tab.get_ui()
		assert(rows(tab) ~= "" and #SENT == 0, "stock tab, nothing sent")
	end)
end

assert(exists(STOCK .. "pda_actor.script"), "the stock scripts (temp\\stock_scripts\\scripts) are needed")
for _, set in ipairs(modes.names()) do
	if set == "none" then
		single_player_tests()
	else
		if set ~= "srv_map" then world_tests(set) end
		mirror_tests(set)
		if set == "srv_map" then map_server_tests() end
	end
	flag_tests(set)
end

print(string.format("warfare_ui: %d passed, %d failed", passed, failed))
if failed > 0 then error("warfare_ui FAILED") end
