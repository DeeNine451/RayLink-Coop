-- Anomaly Coop test, TZ P49 (Dev 58, the owner 2026-11-22): while the co-op debug window (F7) is open, the keys also reach the
-- game and its binds fire. The window must take the keys like a stock window and give them back only when it closes.
--
-- Root cause, two holes (the checks below name them):
--   1. The engine gives the level's script callback every key BEFORE the dialogs (engine/src/xrGame/Level_input.cpp:206 press,
--      :600 release; the dialog gets the key only at :297 / :604). Stock stops those callbacks for an open script window by
--      registering it: _g.script Register_UI sets KEYS_UNLOCK = false and bind_stalker_ext.script on_key_press /
--      on_key_release (241-264) drop the callback then. Every stock script window does it (ui_debug_launcher, ui_options,
--      ui_workshop...), our chat too (coop_core_chat Open/Close). coop_debug_ui.open never registered the window: the torch,
--      night vision, quick throw, companions, coop's own binds and every G.A.M.M.A. mod bind fired under it, typing included.
--   2. The window let the player walk (AllowMovement(S.move), "walk while open" on by default): CDialogHolder hands the
--      movement keys to the actor when StopAnyMove() is false (engine/src/xrGame/UIDialogHolder.cpp:329-340 press, :369 every
--      release, :392 every hold), so W A S D, Space, Ctrl, Shift moved the player under the window.
-- Modes: the window lives on a player's machine, the same code on each: Coop (the host who plays, a client) and Server (a
-- player of the world server). The world server and the map servers have no window (no actor, no F7). Single player keeps the
-- stock F7: nothing is registered there. Not shipped.
-- Run: tools\test_lua.cmd issue_p49
dofile("tests/lua/support/menu_stubs.lua")
XML_FILES["ui_coop_debug.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_debug.xml")

local function table_of(lang)
	local T = {}
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_debug.xml", "rb"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do T[id] = text end
	fh:close()
	return T
end
local EN, RU = table_of("eng"), table_of("rus")
game = { translate_string = function(id) return EN[id] or id end }

-------------------------------------------------------------------------------
-- Engine stand-ins (the ones the window and its client read)
-------------------------------------------------------------------------------
local function vec(x, y, z)
	local v = { x = x or 0, y = y or 0, z = z or 0 }
	function v:set(a, b, c)
		if type(a) == "table" then self.x, self.y, self.z = a.x, a.y, a.z else self.x, self.y, self.z = a, b, c end
		return self
	end
	function v:add(o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z; return self end
	function v:mul(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k; return self end
	function v:distance_to(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2) end
	return v
end
function vector() return vec() end
local device0 = device
function device()
	local d = device0()
	d.cam_dir = vec(.6, -.2, .8)
	d.cam_pos = vec(100, 6.7, 200)
	return d
end

local actor = {
	id = function() return 0 end,
	alive = function() return true end,
	position = function() return vec(100, 5, 200) end,
	level_vertex_id = function() return 1234 end,
	game_vertex_id = function() return 77 end,
	name = function() return "actor" end,
}
db = { actor = actor, storage = {} }
TARGET = {
	id = function() return 42 end, name = function() return "bandit_42" end, section = function() return "stalker_bandit" end,
	clsid = function() return 7 end, character_name = function() return "Sanya" end,
	character_community = function() return "bandit" end, character_rank = function() return 1500 end,
	character_reputation = function() return 200 end, position = function() return vec(110, 5, 205) end,
	alive = function() return true end,
}
level = {
	present = function() return true end,
	name = function() return "l01_escape" end,
	get_target_obj = function() return TARGET end,
	get_target_dist = function() return 10 end,
	vertex_id = function() return 5555 end,
	vertex_position = function() return vec(100, 5, 200) end,
	object_by_id = function(id) if id == 42 then return TARGET end end,
	get_time_hours = function() return 14 end,
	get_time_minutes = function() return 5 end,
	get_time_factor = function() return 10 end,
	get_weather = function() return "w_clear1" end,
}
SECTIONS = { medkit = { class = "II_MEDKI", inv_weight = ".1", inv_name = "st_medkit", inv_grid_width = "1", inv_grid_height = "1" },
	simulation_bandit_3 = { class = "ON_OFF_S" }, sim_squad_bandit = { class = "ON_OFF_S", faction = "bandit" } }
ini_sys = {}
function ini_sys:section_exist(s) return SECTIONS[s] ~= nil end
function ini_sys:line_exist(s, k) return SECTIONS[s] ~= nil and SECTIONS[s][k] ~= nil end
function ini_sys:section_for_each(f) for s in pairs(SECTIONS) do f(s) end end
function ini_sys:r_string_ex(s, k) return SECTIONS[s] and SECTIONS[s][k] end
function game_ini() return { tag = "game" } end
utils_data = { collect_section = function(ini, sec)
	if sec == "level_maps_single" then return { "l01_escape", "l02_garbage" } end
	return {}
end }
axr_main = { config = config_stub() }
CURSOR = { x = 0, y = 0 }
function GetCursorPosition() return { x = CURSOR.x, y = CURSOR.y } end
ui_events.WINDOW_LBUTTON_DOWN, ui_events.WINDOW_LBUTTON_UP, ui_events.WINDOW_MOUSE_MOVE = 61, 62, 63
ui_events.WINDOW_LBUTTON_DB_CLICK = 64
ui_events.WINDOW_KEY_RELEASED = ui_events.WINDOW_KEY_RELEASED or 2
function get_console_cmd(typ, name) if name == "renderer" then return "renderer_r4" end end
coop_main = { add_event_handler = function() end, decode = function() return {} end }

-- The window's input flags, as CUIDialogWnd keeps them (engine/src/xrGame/ui/UIDialogWnd.h:28-32, UIDialogWnd.cpp:10: a new
-- window does not let the player walk until AllowMovement(true)).
function CUIScriptWnd.AllowMovement(self, b) self.allow_move = (b == true) end
function CUIScriptWnd.AllowCursor(self, b) self.cursor = (b == true) end

-- keys: DirectInput codes and the binds of a default user.ltx
DIK_F7, DIK_ESC, DIK_W, DIK_A, DIK_S, DIK_D, DIK_SPACE = 65, DIK_keys.DIK_ESCAPE, 17, 30, 31, 32, 57
DIK_L, DIK_N, DIK_G, DIK_LCONTROL, DIK_LSHIFT, DIK_LMENU = 38, 49, 34, 29, 42, 56
DIK_keys.DIK_F7, DIK_keys.DIK_LCONTROL, DIK_keys.DIK_LSHIFT, DIK_keys.DIK_LMENU = DIK_F7, DIK_LCONTROL, DIK_LSHIFT, DIK_LMENU
key_bindings = { kCUSTOM17 = 117, kFWD = 8, kBACK = 9, kL_STRAFE = 10, kR_STRAFE = 11, kJUMP = 4, kCROUCH = 5, kTORCH = 19,
	kNIGHT_VISION = 20, kCUSTOM19 = 119, kCONSOLE = 2 }
local BIND_OF = { [DIK_F7] = "kCUSTOM17", [DIK_W] = "kFWD", [DIK_S] = "kBACK", [DIK_A] = "kL_STRAFE", [DIK_D] = "kR_STRAFE",
	[DIK_SPACE] = "kJUMP", [DIK_LCONTROL] = "kCROUCH", [DIK_L] = "kTORCH", [DIK_N] = "kNIGHT_VISION", [DIK_G] = "kCUSTOM19" }
function dik_to_bind(k) return BIND_OF[k] and key_bindings[BIND_OF[k]] or -1 end
-- the movement actions CDialogHolder hands to the actor on a press (UIDialogHolder.cpp:337: kDOWN < action < kCAM_1)
local MOVEMENT = { kJUMP = true, kCROUCH = true, kFWD = true, kBACK = true, kL_STRAFE = true, kR_STRAFE = true }

CALLBACKS = {}
function RegisterScriptCallback(name, f) CALLBACKS[name] = CALLBACKS[name] or {}; table.insert(CALLBACKS[name], f) end
function UnregisterScriptCallback(name, f)
	for i, g in ipairs(CALLBACKS[name] or {}) do if g == f then table.remove(CALLBACKS[name], i) return end end
end
local function fire(name, ...)
	for _, f in ipairs(CALLBACKS[name] or {}) do f(...) end
end
function exec_console_cmd() end
function get_console() return { execute = function() end } end

-------------------------------------------------------------------------------
-- Stock: the script-window registration and the key gate (Anomaly 1.5 _g.script 56 and 139-174, 227-238;
-- bind_stalker_ext.script 241-264, the same in temp/stock_scripts and temp/anomaly_unpack)
-------------------------------------------------------------------------------
KEYS_UNLOCK = true
_GUIs, _GUIsInstances, _GUIs_keyfree = {}, {}, {}
function Register_UI(name, path, instance)
	if not name then return end
	_GUIs[name] = { path = path, instance = instance }
	_GUIsInstances[name] = { path = path, instance = instance }
	if not _GUIs_keyfree[name] then KEYS_UNLOCK = false end
end
function Unregister_UI(name)
	if not (name and _GUIs[name]) then return end
	_GUIs[name] = nil
	KEYS_UNLOCK = true
	for n in pairs(_GUIs) do
		if not _GUIs_keyfree[n] then KEYS_UNLOCK = false end
	end
end
-- how stock closes every registered window (cut scenes, level travel, the HUD off): the window's own Close
function hide_hud_all()
	for _, t in pairs(_GUIs) do
		local path, ui = t.path, t.instance
		if path and _G[path] then
			if ui and _G[path][ui] and _G[path][ui].Close then
				_G[path][ui]:Close()
			elseif _G[path].GUI and _G[path].GUI.Close then
				_G[path].GUI:Close()
			end
		end
	end
end
-- bind_stalker_ext.on_key_press / on_key_release: an open registered window stops the level's key callbacks (Ctrl/Shift/Alt pass)
local function level_callback(name, dik)
	if not KEYS_UNLOCK and not (dik == DIK_LCONTROL or dik == DIK_LSHIFT or dik == DIK_LMENU) then return end
	fire(name, dik)
end

-------------------------------------------------------------------------------
-- What reaches the game: script binds (every on_key_press / on_key_release subscriber but the F7 of the co-op window) and
-- the actor's actions
-------------------------------------------------------------------------------
GAME = {}
local function bind_spy(what)
	return function(dik) if dik ~= DIK_F7 then GAME[#GAME + 1] = what .. " " .. (BIND_OF[dik] or tostring(dik)) end end
end
RegisterScriptCallback("on_key_press", bind_spy("script press"))
RegisterScriptCallback("on_key_release", bind_spy("script release"))

-- One keystroke the way the engine delivers it. Press and release: the level's callback first (Level_input.cpp:206 / :600),
-- then the dialog on top (Level_input.cpp:297 / :604 -> CDialogHolder::IR_UIOnKeyboardPress / Release,
-- UIDialogHolder.cpp:308-375); a key the window does not take goes to the actor only when the window lets him walk.
-- typing: an edit box of the window has the focus and takes the key (CUICustomEdit::OnKeyboardAction returns true).
local function stroke(dik, typing)
	NOW = NOW + 400
	for _, phase in ipairs({ "press", "release" }) do
		level_callback(phase == "press" and "on_key_press" or "on_key_release", dik)
		local act = BIND_OF[dik]
		local w = dui.window()
		if w and w.shown then
			local action = phase == "press" and ui_events.WINDOW_KEY_PRESSED or ui_events.WINDOW_KEY_RELEASED
			local taken = w:OnKeyboard(dik, action) == true or typing == true
			if not taken and w.allow_move == true and act and (phase == "release" or MOVEMENT[act]) then
				GAME[#GAME + 1] = "actor " .. phase .. " " .. act
			end
		elseif act and act ~= "kCUSTOM17" then
			GAME[#GAME + 1] = "actor " .. phase .. " " .. act -- no dialog: CActor::IR_OnKeyboardPress / Release
		end
	end
end

local function reached(fn)
	GAME = {}
	fn()
	return GAME
end
local function has(list, item)
	for _, v in ipairs(list) do if v == item then return true end end
	return false
end
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-------------------------------------------------------------------------------
-- coop: the API of the co-op exe (DEBUG_DESIGN E, B.2), one player's machine
-------------------------------------------------------------------------------
SESSION = true
ROLE = "client"
PLAYS = true -- does seat 0 play: Coop yes (the host), Server no (the world server)
DEBUG = { on = false, source = 0 }
coop = {
	is_active = function() return SESSION end,
	is_host = function() return ROLE == "host" end,
	is_client = function() return ROLE == "client" end,
	self_id = function() return ROLE == "host" and 0 or 2 end,
	players = function()
		return {
			{ id = 0, nick = PLAYS and "Host" or "world", is_self = ROLE == "host", avatar_id = ROLE == "host" and 0 or 501, rtt = 0 },
			{ id = 2, nick = "Bob", is_self = ROLE == "client", avatar_id = ROLE == "client" and 0 or 502, rtt = 38 },
		}
	end,
	server_link = function() return { id = 0, nick = PLAYS and "Host" or "world", plays = PLAYS, operator = false } end,
	has_host_rights = function() return ROLE == "host" end,
	to_host_id = function(id) return ROLE == "host" and id or id + 9000 end,
	life_of = function() return "alive" end,
	debug = {
		state = function() return { on = DEBUG.on, source = DEBUG.source, serial = 1 } end,
		flags = function() return 0 end,
		is_operator = function() return false end,
	},
	sync = { request = function() return true end },
}

local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_module("coop_mode"), load_module)
local client = load_module("coop_debug_client")
dui = load_module("coop_debug_ui")
client.on_game_start()
if type(dui.on_game_start) == "function" then dui.on_game_start() end

local function reset()
	dui.close()
	dui.reset_settings_cache()
	client.reset_feed()
	GAME = {}
end

-------------------------------------------------------------------------------
print("== the harness: with no window the game has the keys")
reset()
local got = reached(function() stroke(DIK_L); stroke(DIK_W) end)
check(has(got, "script release kTORCH") and has(got, "actor press kFWD"),
	"no window: the torch bind and walking reach the game (" .. table.concat(got, ", ") .. ")")

local ROLES = {
	{ tag = "Coop, the host who plays", role = "host", plays = true },
	{ tag = "Coop, a client", role = "client", plays = true },
	{ tag = "Server, a player of the world server", role = "client", plays = false },
}
for _, R in ipairs(ROLES) do
	for _, on in ipairs({ false, true }) do
		print("== " .. R.tag .. ", server debug " .. (on and "on" or "off"))
		ROLE, PLAYS, DEBUG.on = R.role, R.plays, on
		reset()
		local tag = R.tag .. (on and " (on)" or " (off)")
		reached(function() stroke(DIK_F7) end)
		local w = dui.window()
		check(w ~= nil and w.shown == true, tag .. ": F7 opens the window")
		if w then
			check(KEYS_UNLOCK == false and _GUIs.UICoopDebug ~= nil and _GUIs.UICoopDebug.path == "coop_debug_ui",
				tag .. ": open, it is registered as a stock script window (Register_UI: the level's key binds stop)")
			got = reached(function() for _, k in ipairs({ DIK_L, DIK_N, DIK_G }) do stroke(k) end end)
			check(#got == 0, tag .. ": open, torch, night vision and quick throw do not fire (" .. table.concat(got, ", ") .. ")")
			got = reached(function() for _, k in ipairs({ DIK_W, DIK_A, DIK_S, DIK_D, DIK_SPACE }) do stroke(k) end end)
			check(#got == 0, tag .. ": open, W A S D and Space do not move the player (" .. table.concat(got, ", ") .. ")")
			-- Ctrl/Shift/Alt still reach the scripts under any stock window (bind_stalker_ext.script 243: modifiers pass)
			got = reached(function() stroke(DIK_LCONTROL) end)
			check(not has(got, "actor press kCROUCH") and not has(got, "actor release kCROUCH"),
				tag .. ": open, Ctrl does not crouch the player (" .. table.concat(got, ", ") .. ")")
			check(w.allow_move ~= true, tag .. ": the window never lets the player walk (StopAnyMove stays true)")
			got = reached(function() for _, k in ipairs({ DIK_L, DIK_N, DIK_W }) do stroke(k, true) end end)
			check(#got == 0, tag .. ": typing into its search field, the letters stay in the window (" .. table.concat(got, ", ") .. ")")
			reached(function() stroke(DIK_F7) end)
			check(dui.window() == nil and w.shown == false, tag .. ": F7 from the window closes it")
			got = reached(function() stroke(DIK_L); stroke(DIK_W) end)
			check(KEYS_UNLOCK == true and _GUIs.UICoopDebug == nil and has(got, "script release kTORCH") and has(got, "actor press kFWD"),
				tag .. ": closed, the keys are the game's again (" .. table.concat(got, ", ") .. ")")
			reached(function() stroke(DIK_F7) end)
			local w2 = dui.window()
			check(w2 ~= nil and w2.shown == true and KEYS_UNLOCK == false, tag .. ": F7 opens it again, the keys are taken again")
			reached(function() stroke(DIK_ESC) end)
			got = reached(function() stroke(DIK_N); stroke(DIK_D) end)
			check(dui.window() == nil and KEYS_UNLOCK == true and has(got, "script release kNIGHT_VISION") and has(got, "actor press kR_STRAFE"),
				tag .. ": Esc closes it and gives the keys back (" .. table.concat(got, ", ") .. ")")
		end
	end
end
ROLE, PLAYS, DEBUG.on = "client", true, false

-------------------------------------------------------------------------------
print("== no setting gives the game the keys")
reset()
axr_main.config:w_value("coop_debug_ui", "move", "true") -- "walk while open" saved by an older build
dui.reset_settings_cache()
reached(function() stroke(DIK_F7) end)
local w = dui.window()
check(w ~= nil and w.allow_move ~= true, "a 'walk while open' saved by an older build does not let the player walk")
local walk = {}
for name in pairs(w and w.callbacks or {}) do if name:find("^btn_set_move") then walk[#walk + 1] = name end end
table.sort(walk)
check(#walk == 0, "the View settings have no 'walk while open' (" .. table.concat(walk, ",") .. ")")
got = reached(function() stroke(DIK_W); stroke(DIK_L) end)
check(#got == 0, "with that old setting the window still takes W and L (" .. table.concat(got, ", ") .. ")")

-------------------------------------------------------------------------------
print("== built again (density, a new server state): still the only registration, still taking the keys")
click(w, "btn_settings")
click(w, "btn_set_dens_compact")
w:Update()
local w2 = dui.window()
check(w2 ~= nil and w2 ~= w and w2.shown == true and w.shown == false, "density: the window is built again")
check(count(_GUIs) == 1 and _GUIs.UICoopDebug ~= nil and KEYS_UNLOCK == false, "density: one registration, the keys taken")
DEBUG.on = true
fire("coop_debug_changed", true, 2)
local w3 = dui.window()
check(w3 ~= nil and w3 ~= w2 and count(_GUIs) == 1 and KEYS_UNLOCK == false, "a new server state: built again, one registration")
got = reached(function() stroke(DIK_L); stroke(DIK_W) end)
check(#got == 0, "the window built again takes the keys (" .. table.concat(got, ", ") .. ")")
DEBUG.on = false
reset()
check(KEYS_UNLOCK == true and count(_GUIs) == 0, "closed: nothing registered")
dui.get_settings().density = "normal"

-------------------------------------------------------------------------------
print("== stock scripts close it like any of their windows (cut scene, level travel: _g.script hide_hud_all)")
reached(function() stroke(DIK_F7) end)
w = dui.window()
hide_hud_all()
check(dui.window() == nil and w.shown == false and KEYS_UNLOCK == true and _GUIs.UICoopDebug == nil,
	"hide_hud_all closes the window and gives the keys back")
reached(function() stroke(DIK_F7) end)
check(dui.window() ~= nil and dui.window().shown == true, "F7 opens it after that")
reset()

-------------------------------------------------------------------------------
print("== hidden without close(): the registration does not keep the game's binds off")
reached(function() stroke(DIK_F7) end)
w = dui.window()
w:HideDialog() -- the engine hid the top dialog itself (Level_input.cpp:284, Esc when the dialog takes no input)
check(KEYS_UNLOCK == false, "right after: still registered (the window was not told)")
fire("actor_on_update")
got = reached(function() stroke(DIK_L) end)
check(KEYS_UNLOCK == true and _GUIs.UICoopDebug == nil and has(got, "script release kTORCH"),
	"the next update drops the registration: the binds work (" .. table.concat(got, ", ") .. ")")
reached(function() stroke(DIK_F7) end)
check(dui.window() ~= nil and dui.window() ~= w and dui.window().shown == true and KEYS_UNLOCK == false, "F7 opens a new window")
reset()

-------------------------------------------------------------------------------
print("== level change and the end of the client's level close it and free the keys")
for _, cb in ipairs({ "on_before_level_changing", "on_level_changing", "actor_on_net_destroy" }) do
	reached(function() stroke(DIK_F7) end)
	fire(cb)
	check(dui.window() == nil and KEYS_UNLOCK == true and _GUIs.UICoopDebug == nil, cb .. ": closed, nothing registered")
end

-------------------------------------------------------------------------------
print("== single player: the stock F7, nothing registered")
SESSION = false
reset()
got = reached(function() stroke(DIK_F7); stroke(DIK_L); stroke(DIK_W) end)
check(dui.window() == nil and KEYS_UNLOCK == true and count(_GUIs) == 0, "no session: F7 opens nothing of ours, nothing registered")
check(has(got, "script release kTORCH") and has(got, "actor press kFWD"), "no session: the game keeps every key")
fire("actor_on_update")
check(KEYS_UNLOCK == true and count(_GUIs) == 0, "no session: the update guard touches nothing")
SESSION = true

-------------------------------------------------------------------------------
print("== strings: the help names no walking")
check(not (EN.st_coop_dbg_help_window or ""):lower():find("walk", 1, true), "eng help: no 'walking while open'")
check(RU.st_coop_dbg_help_window ~= nil and not RU.st_coop_dbg_help_window:find("\245\238\228\252\225", 1, true),
	"rus help: no 'hod'ba' (walking)")

print(string.format("ISSUE_P49: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
