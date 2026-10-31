-- Anomaly Coop test: gamedata\scripts\coop_menu_watch.script, the log lines for two live bugs of 2026-10-31 no reading of the
-- code could prove (the host's inventory takes no clicks, no way back from the main menu of a session). It only speaks: a key
-- it watches behaves as it did. Not shipped. Run: tools\test_lua.cmd menu_watch
dofile("tests/lua/support/menu_stubs.lua")

local LOG = {}
function printf(fmt, ...) LOG[#LOG + 1] = string.format(fmt, ...) end
local function said(what)
	for _, line in ipairs(LOG) do
		if line:find(what, 1, true) then return true end
	end
	return false
end
local function clear() LOG = {} end

DIK_keys = { MOUSE_1 = 337, DIK_ESCAPE = 1, DIK_A = 30 }
ui_events = { WINDOW_KEY_PRESSED = 7 }
local PRESS = ui_events.WINDOW_KEY_PRESSED

MOVEKEYS = false
game = { only_movekeys_allowed = function() return MOVEKEYS end }
_GUIs = {}
TAKES = false -- what the stock on_key_press answers: true = a script took the key
level_input = { on_key_press = function() return TAKES end }
ACTIVE, LIFE = true, "alive"
coop = { is_active = function() return ACTIVE end, life_of = function() return LIFE end }
ALIVE = true
db = { actor = { alive = function() return ALIVE end } }

local CB = {}
function RegisterScriptCallback(name, f) CB[name] = f end

local w = load_module("coop_menu_watch")
w.on_game_start()

print("== the inventory opens")
CB.GUI_on_show("UIInventory", "ui_inventory")
check(#LOG == 0, "nothing in its way: not a word, the inventory opens all the time")
_GUIs = { UIInventory = {}, Dialog = {} }
CB.GUI_on_show("UIInventory", "ui_inventory")
check(#LOG == 0, "a talk under the inventory is the stock's own exception")
_GUIs = { UIInventory = {}, UICoopRest = {} }
CB.GUI_on_show("UIInventory", "ui_inventory")
check(said("UICoopRest"), "another window registered stops the window's hover (Overlapped_UI): it is named")
_GUIs = {}
clear()
MOVEKEYS = true
CB.GUI_on_show("UIInventory", "ui_inventory")
check(said("movement keys only"), "only_movekeys_allowed: no drag, no double click, no menu (Inventory Anti-Closing)")
MOVEKEYS = false
clear()
liz_fdda_input_manager = { is_input_disabled = true }
CB.GUI_on_show("UIInventory", "ui_inventory")
check(said("animation"), "the FDDA input manager takes the keys")
liz_fdda_input_manager = nil
clear()
CB.GUI_on_show("UIZoom")
check(#LOG == 0, "other windows are not the inventory")

print("== a click")
_GUIs = { UIInventory = {} }
TAKES = true
check(level_input.on_key_press(DIK_keys.MOUSE_1, 30, false) == true, "the stock's answer stays")
check(said("click"), "a click a script took while the inventory is open")
clear()
for _ = 1, 5 do level_input.on_key_press(DIK_keys.MOUSE_1, 30, false) end
check(#LOG == 2, "three lines at most, the player keeps clicking")
clear()
level_input.on_key_press(DIK_keys.DIK_A, 8, false)
check(#LOG == 0, "another key says nothing")
TAKES = false
check(level_input.on_key_press(DIK_keys.MOUSE_1, 30, false) == false, "the stock's answer stays")
_GUIs = {}
TAKES = true
check(level_input.on_key_press(DIK_keys.MOUSE_1, 30, false) == true and #LOG == 0, "no inventory: nothing to say")
TAKES = false

print("== Esc in the main menu")
clear()
CB.main_menu_on_keyboard(DIK_keys.DIK_ESCAPE, PRESS, {}, true)
check(said("Esc") and said("alive"), "Esc in a session is in the log, with what the stock line will do")
clear()
ALIVE = false
LIFE = "dead"
CB.main_menu_on_keyboard(DIK_keys.DIK_ESCAPE, PRESS, {}, true)
check(said("stays"), "the stock line keeps the menu up: said so")
ALIVE = true
db.actor = nil
clear()
CB.main_menu_on_keyboard(DIK_keys.DIK_ESCAPE, PRESS, {}, true)
check(said("stays"), "no actor here: the stock line keeps the menu up")
db.actor = { alive = function() return true end }
clear()
CB.main_menu_on_keyboard(DIK_keys.DIK_ESCAPE, PRESS, {}, false)
check(#LOG == 0, "the cold-start menu has nothing to go back to")
ACTIVE = false
CB.main_menu_on_keyboard(DIK_keys.DIK_ESCAPE, PRESS, {}, true)
check(#LOG == 0, "no session: stock")
ACTIVE = true
CB.main_menu_on_keyboard(DIK_keys.DIK_A, PRESS, {}, true)
check(#LOG == 0, "another key says nothing")

print("== an exe without co-op")
coop = nil
CB = {}
local plain = load_module("coop_menu_watch")
plain.on_game_start()
check(next(CB) == nil, "nothing is registered")

print(string.format("%d passed, %d failed", PASSES, FAILS))
