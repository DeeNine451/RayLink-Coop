-- F5-VEH-6, Co-op: the host decides seats. A client uses the granted seat from coop.vehicle.
-- The group board announces the move before the host releases any seats left on the old map.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")

local before_change = "on_before_level_changing"
local attach = "actor_on_attach_vehicle"
local detach = "actor_on_detach_vehicle"
for _, name in ipairs({ before_change, attach, detach }) do AddScriptCallback(name) end

local mod_file = io.open("temp/review/corpus/merged/LevelChangeCars.script", "r")
	or assert(io.open(assert(os.getenv("GAMMA_SCRIPTS")) .. "/LevelChangeCars.script", "r"))
local cars = setmetatable({}, { __index = _G })
levelchangecars = cars -- the namespace used by the VFS
setfenv(assert(loadstring(mod_file:read("*a"), "@gamedata/scripts/levelchangecars.script")), cars)()
mod_file:close()

local use_count, exit_count = 0, 0
local use_target, last_use = "car", nil
key_bindings = { kUSE = 99 }
function bind_to_dik(action) return action + 1 end
function level.press_action(dik)
	assert(dik == 100)
	use_count = use_count + 1
	last_use = use_target
end
local press_action = level.press_action
local menu_close = 0
strformat = string.format
function exec_console_cmd(cmd)
	assert(cmd == "main_menu off")
	menu_close = menu_close + 1
end
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base }) end
end
AddScriptCallback("main_menu_on_keyboard")

local seat, board, physically_seated
coop.vehicle = {
	status = function() return seat, { requests = 6 + exit_count, refused = 2 } end,
	attached = function() return physically_seated == true end,
	exit = function() exit_count = exit_count + 1; return seat ~= nil end,
}
coop.transition = function() return board end

make_actor()
start_all()
cars.on_game_start() -- exercise a mod callback already registered by value
local later_uses
RegisterScriptCallback(before_change, function() later_uses = use_count end)
local domain = coop.route.of(before_change, cars.on_before_level_changing)
load_script("coop_saves").on_game_start()
local glue_file = io.open(ROOT .. "scripts/coop_vehicles.script")
if glue_file then
	glue_file:close()
	local glue = load_script("coop_vehicles")
	glue.on_game_start()
	glue.on_game_start()
end
check(coop_mode.group_travels() and coop_mode.is_player_mirror(), "co-op client sees the group and mirrors the host")
check(domain == "owner", "LevelChangeCars transition runs on the local actor's machine")
check(coop_route.script_of(cars.on_before_level_changing) == "levelchangecars"
	and coop_route.handler_domain(cars.on_before_level_changing) == "owner", "the registered wrapper retains the mod's router source and route")
local spawner_handler = from_script("grok_vehicles_spawner", "return function() end")
check(coop.route.of("actor_on_first_update", spawner_handler) == "host", "GAMMA vehicle spawning stays on the host route")

seat, physically_seated = { car = 42, seat = 0 }, true
SendScriptCallback(attach)
for _, kind in ipairs({ 1, 2, 3 }) do
	local flags = { ret = false }
	SendScriptCallback("on_before_save_input", flags, kind, "manual save")
	check(flags.ret and sent_count("mods.save_req") == 0, "manual save type " .. kind .. " is vetoed without a request")
end
check(menu_close == 3, "the stock seated save guard still runs")
coop.saves_open = function() return true end
local rollback = { ret = false }
SendScriptCallback("on_before_save_input", rollback, 2, "rollback quicksave")
check(rollback.ret and sent_count("mods.save_req") == 1, "rollback F5 sends one production save request to the host")
coop.saves_open = nil
coop_mods_core.print_status()
check(log_has("vehicles: car 42 seat 0 | requests 6 refused 2"), "coop_status reports the driver and exact native totals")

board = { state = "waiting" }
SendScriptCallback("actor_on_update")
check(exit_count == 0, "waiting for the group leaves the player in the car")
board.state = "going"
SendScriptCallback("actor_on_update")
check(exit_count == 1, "the client requests exit as soon as the group goes")
SendScriptCallback("actor_on_update")
SendScriptCallback(before_change)
check(exit_count == 1 and use_count == 0 and seat ~= nil, "repeated Going and the mod callback neither ask again nor press USE while exit is pending")
seat = nil -- the host released the seat before the local detach frame
SendScriptCallback(before_change)
check(exit_count == 1 and use_count == 0, "release before physical detach suppresses synthetic USE without asking out again")
physically_seated = false
SendScriptCallback(detach)
local uses_before_detach = use_count
SendScriptCallback(before_change)
check(use_count == uses_before_detach, "after the detach callback the mod has no USE to press")
coop_mods_core.print_status()
check(log_has("vehicles: car none seat none | requests 7 refused 2"), "coop_status retains exact totals with no seat")

use_target = "inventory_box"
level.press_action(bind_to_dik(key_bindings.kUSE))
check(level.press_action == press_action and use_count == uses_before_detach + 1 and last_use == use_target,
	"independent USE still reaches a nearby object through the stock input function")
use_target = "deployable_mgun"
SendScriptCallback(attach)
SendScriptCallback(before_change)
check(use_count == uses_before_detach + 2 and last_use == use_target, "a holder outside coop.vehicle gets stock transition USE")

MODE, board = "host", nil
SendScriptCallback("actor_on_update")
check(coop_mode.leads_here() and not coop_mode.is_player_mirror(), "co-op host drives his own actor")
local prior_exits, prior_uses = exit_count, use_count
SendScriptCallback(attach)
SendScriptCallback(before_change)
check(exit_count == prior_exits and use_count == prior_uses + 1, "the host detaches through the mod's stock USE once")
check(later_uses == prior_uses + 1, "the host's already registered LevelChangeCars runs before the later callback")
SendScriptCallback(before_change)
check(use_count == prior_uses + 1, "the host has no synthetic USE on a second transition callback after the stock exit")

-- INTEG-C (rv_F5-VEH-6 blocker 2): the engine's ask-out for a held level move is a player mirror's only; the deciders drive by
-- the stock path and ask nobody.
local glue = rawget(_G, "coop_vehicles")
local exit_for_travel = glue and rawget(glue, "exit_for_travel")
check(type(exit_for_travel) == "function", "the engine's held travel has a Lua ask-out to call")
if type(exit_for_travel) == "function" then
	check(exit_for_travel() == false and exit_count == prior_exits, "the co-op host asks no seat's exit for a held travel")
end

MODE = "sp"
SendScriptCallback(attach)
SendScriptCallback(before_change)
check(exit_count == prior_exits and use_count == prior_uses + 2, "single player detaches through the original mod callback")
check(later_uses == prior_uses + 2, "single player's already registered LevelChangeCars keeps its priority")
if type(exit_for_travel) == "function" then
	check(exit_for_travel() == false and exit_count == prior_exits, "single player asks no seat's exit for a travel")
end

done("vehicle Lua glue, co-op")
