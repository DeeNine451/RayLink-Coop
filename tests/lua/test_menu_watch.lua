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
local function reports()
	local count = 0
	for _, line in ipairs(LOG) do
		if line:match("^%[coop%-menu%] !") then count = count + 1 end
	end
	return count
end

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

local timers = {}
function CreateTimeEvent(group, action, seconds, callback)
	local key = group .. ":" .. action
	if not timers[key] then timers[key] = { due = NOW + seconds * 1000, callback = callback } end
end
function RemoveTimeEvent(group, action) timers[group .. ":" .. action] = nil end
local function advance(ms, force)
	NOW = NOW + ms
	for key, timer in pairs(timers) do
		if (force or NOW >= timer.due) and timer.callback() == true then timers[key] = nil end
	end
end

local w = load_module("coop_menu_watch")
w.on_game_start()

local function open_inventory(guis)
	clear()
	_GUIs = guis or {}
	_GUIs.UIInventory = { path = "ui_inventory" }
	CB.GUI_on_show("UIInventory", "ui_inventory")
end

local function close_inventory()
	_GUIs.UIInventory = nil
	if CB.GUI_on_hide then CB.GUI_on_hide("UIInventory", "ui_inventory") end
end

local function test_input_block(set_blocked, reason)
	set_blocked(true)
	open_inventory()
	check(reports() == 0, reason .. ": no report at open")
	advance(2999, true) -- stock can force its event queue before a timer is due
	check(reports() == 0, reason .. ": still no report before three seconds")
	advance(1)
	check(reports() == 1 and said(reason) and said("3.0 s"), reason .. ": one report at three seconds")
	advance(3000)
	check(reports() == 1, reason .. ": the report does not repeat")
	open_inventory()
	set_blocked(false)
	advance(3000)
	check(reports() == 0, reason .. ": cleared before the re-check")
end

print("== Co-op host inventory: FDDA and overlapping windows")
liz_fdda_input_manager = { is_input_disabled = false }
test_input_block(function(value) liz_fdda_input_manager.is_input_disabled = value end, "an animation holds the input")

open_inventory()
advance(3000)
check(#LOG == 0, "a clean inventory is quiet")
open_inventory({ Dialog = {} })
advance(3000)
check(#LOG == 0, "a talk under the inventory is the stock's own exception")

local repair = { path = "repair_ui", instance = "repair_window" }
repair_ui = { repair_window = window("repair") }
open_inventory({ UIRepair = repair })
check(reports() == 0, "a registered repair window is not a fault at open")
repair_ui.repair_window:Show(false)
advance(3270)
check(reports() == 1 and said("UIRepair") and said("shown=false") and said("3.3 s"),
	"a hidden repair window still registered at the re-check is named with its visibility and elapsed time")

print("== Co-op client inventory: a short-lived trade window")
open_inventory({ UITradingComputer = {} })
check(reports() == 0, "trade computer is quiet while opening the trade inventory")
_GUIs.UITradingComputer = nil
advance(3000)
check(reports() == 0, "the unregistered trade computer leaves no report")

print("== Server player inventory: movement-only and persistent overlapping windows")
test_input_block(function(value) MOVEKEYS = value end, "movement keys only")
repair_ui.repair_window:Show(true)
MOVEKEYS = true
open_inventory({ UIRepair = repair })
advance(3000)
check(reports() == 1 and said("movement keys only") and said("UIRepair") and said("shown=true"),
	"all reasons still present go into one report")

print("== inventory and blocker lifetimes")
open_inventory({ UITradingComputer = {} })
MOVEKEYS = false
_GUIs.UITradingComputer = nil
_GUIs.UIRepair = repair
advance(3000)
check(reports() == 0, "new reasons do not count as the original reasons")
open_inventory({ UIRepair = repair })
_GUIs.UIRepair = { path = repair.path, instance = repair.instance }
advance(3000)
check(reports() == 0, "a replacement registration with the same name is a new reason")

MOVEKEYS = true
open_inventory()
close_inventory()
advance(3000)
check(reports() == 0, "inventory closed before the re-check")
open_inventory()
advance(1500)
close_inventory()
open_inventory()
advance(1500)
check(reports() == 0, "reopening starts a fresh three-second wait")
advance(1500)
check(reports() == 1, "the reopened inventory has its own one-shot report")

open_inventory()
ACTIVE = false
advance(3000)
check(#LOG == 0, "session ended before the re-check")
open_inventory({ UIRepair = repair })
advance(3000)
check(#LOG == 0 and next(timers) == nil, "outside a session there is no diagnostic or pending re-check")
ACTIVE = true
MOVEKEYS = false
clear()
CB.GUI_on_show("UIZoom")
check(#LOG == 0, "other windows are not the inventory")

print("== a click")
_GUIs = { UIInventory = {} }
TAKES = true
check(level_input.on_key_press(DIK_keys.MOUSE_1, 30, false) == true, "the stock's answer stays")
check(reports() == 1 and said("! a click in the inventory was taken by a script (on_before_key_press, bind 30)"),
	"a click a script took while the inventory is open keeps its original report")
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
