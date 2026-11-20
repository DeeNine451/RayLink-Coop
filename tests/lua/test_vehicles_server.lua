-- F5-VEH-6, Server: the map server decides seats and the world server decides travel.
-- The player's machine gets the seat and runs the GAMMA callbacks for his own actor.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")

local before_change = "on_before_level_changing"
local attach = "actor_on_attach_vehicle"
local detach = "actor_on_detach_vehicle"
for _, name in ipairs({ before_change, attach, detach }) do AddScriptCallback(name) end

local function load_mod(name)
	local file = io.open("temp/review/corpus/merged/" .. name .. ".script", "r")
		or assert(io.open(assert(os.getenv("GAMMA_SCRIPTS")) .. "/" .. name .. ".script", "r"))
	local mod = setmetatable({}, { __index = _G })
	_G[name] = mod
	setfenv(assert(loadstring(file:read("*a"), "@gamedata/scripts/" .. name .. ".script")), mod)()
	file:close()
	return mod
end

function ini_file_ex(path)
	assert(path == "plugins\\vehicle_attach_sounds.ltx")
	return { r_string_ex = function(_, section, key)
		assert(section == "vehicle_test")
		return key
	end }
end
local cars = load_mod("LevelChangeCars")
local sounds = load_mod("vehicle_attach_sounds")

local use_count, exit_count = 0, 0
local use_target, last_use = "car", nil
key_bindings = { kUSE = 1 }
function bind_to_dik(action) return action end
function level.press_action(dik)
	assert(dik == key_bindings.kUSE)
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

local seat, physically_seated
local process = "player"
coop.levels = { split = function() return true end }
coop.is_map_server = function() return process == "map" end
coop.is_dedicated = function() return process == "world" end
coop.vehicle = {
	status = function() return seat, { requests = 3 + exit_count, refused = 2 } end,
	attached = function() return physically_seated == true end,
	exit = function()
		exit_count = exit_count + 1
		return seat ~= nil
	end,
}

make_actor()
local car_id = 43
local _, car = spawn("vehicle_test", nil, nil, { id = car_id })
start_all()
load_script("coop_saves").on_game_start()
local glue_file = io.open(ROOT .. "scripts/coop_vehicles.script")
if glue_file then
	glue_file:close()
	load_script("coop_vehicles").on_game_start()
end
cars.on_game_start() -- exercise the opposite startup order too
sounds.on_game_start()
check(not coop_mode.group_travels() and coop_mode.is_player_mirror(), "server client mirrors its own map without group travel")
check(coop.route.of(attach, sounds.actor_on_attach_vehicle) == "owner"
	and coop.route.of(detach, sounds.actor_on_detach_vehicle) == "owner", "door callbacks keep their local owner route")
check(coop_route.script_of(cars.on_before_level_changing) == "levelchangecars"
	and coop_route.handler_domain(cars.on_before_level_changing) == "owner", "startup before the mod retains its transition callback's route")

-- Refusal touches neither the actor nor the mod. A later grant attaches the local actor once.
SendScriptCallback(before_change)
check(exit_count == 0 and use_count == 0 and #SOUNDS == 0, "a refused enter has no attach callback, no door sound and no seat to exit")
coop_mods_core.print_status()
check(log_has("vehicles: car none seat none | requests 3 refused 2"), "coop_status reports exact totals after refusals with no seat")
seat, physically_seated = { car = car_id, seat = 1 }, true
SendScriptCallback(attach, car)
check(#SOUNDS == 1 and SOUNDS[1].name == "snd_enter" and SOUNDS[1].at == db.actor:id(), "grant plays one enter sound at the sitter")
for _, kind in ipairs({ 1, 2, 3 }) do
	local flags = { ret = false }
	SendScriptCallback("on_before_save_input", flags, kind, "manual save")
	check(flags.ret and sent_count("mods.save_req") == 0, "manual save type " .. kind .. " is vetoed without a request")
end
check(menu_close == 3, "the stock seated save guard still runs")
coop_mods_core.print_status()
check(log_has("vehicles: car 43 seat 1 | requests 3 refused 2"), "coop_status reports the passenger and exact native totals")
SendScriptCallback(before_change)
check(exit_count == 1 and use_count == 0 and #SOUNDS == 1, "individual level change asks out without injecting USE or faking a detach")
seat = nil -- release from the source map server, while the local ride has yet to end
SendScriptCallback(before_change)
check(exit_count == 1 and use_count == 0 and #SOUNDS == 1, "release before physical detach suppresses synthetic USE and plays no premature exit sound")
physically_seated = false
SendScriptCallback(detach, car)
check(#SOUNDS == 2 and SOUNDS[2].name == "snd_exit" and SOUNDS[2].at == db.actor:id(), "confirmed exit plays one exit sound at the sitter")
local post_detach_uses = use_count
SendScriptCallback(before_change)
check(use_count == post_detach_uses and #SOUNDS == 2, "a later callback after detach does not press USE or replay the exit sound")
coop_mods_core.print_status()
check(log_has("vehicles: car none seat none | requests 4 refused 2"), "coop_status clears the seat and retains exact totals after exit")

use_target = "inventory_box"
level.press_action(key_bindings.kUSE)
check(level.press_action == press_action and use_count == post_detach_uses + 1 and last_use == use_target,
	"independent USE still reaches a nearby object through the stock input function")
use_target = "deployable_mgun"
SendScriptCallback(attach, car)
SendScriptCallback(before_change)
check(use_count == post_detach_uses + 2 and last_use == use_target, "a holder outside coop.vehicle gets stock transition USE")

seat, physically_seated = { car = car_id, seat = 0 }, true
SendScriptCallback(attach, car)
local prior_exits, prior_uses = exit_count, use_count
coop_main.on_world_leaving(1)
check(exit_count == prior_exits + 1 and use_count == prior_uses, "the world-leaving fallback asks out when a grant is still present")

physically_seated = false
SendScriptCallback(detach, car)

-- INTEG-C (rv_F5-VEH-6 blocker 2): the engine holds a native LevelMove while the actor sits and asks out through this function
-- first, so the map server of this level releases the seat before the world server moves him.
local glue = rawget(_G, "coop_vehicles")
local exit_for_travel = glue and rawget(glue, "exit_for_travel")
check(type(exit_for_travel) == "function", "the engine's seated level move has a Lua ask-out to call")
if type(exit_for_travel) == "function" then
	local before_exit, before_use = exit_count, use_count
	seat, physically_seated = { car = car_id, seat = 0 }, true
	check(exit_for_travel() == true and exit_count == before_exit + 1 and use_count == before_use,
		"a held level move asks the seat's decider for an exit without pressing USE")
	seat = nil
	check(exit_for_travel() == false and exit_count == before_exit + 1,
		"no grant left: nothing more is asked while the local detach finishes")
	physically_seated = false
end

-- Leave the stub seat set to catch an accidental call from an authority's process.
MODE = "host"
for _, name in ipairs({ "map", "world" }) do
	process = name
	check(not coop_mode.actor_is_player() and not coop_mode.is_player_mirror(), name .. " server has no player of its own")
	local before = exit_count
	coop_main.on_world_leaving(1)
	check(exit_count == before, name .. " server does not ask to exit on the player's behalf")
	if type(exit_for_travel) == "function" then
		check(exit_for_travel() == false and exit_count == before, name .. " server's travel hold asks no exit for anybody")
	end
end

done("vehicle Lua glue, server")
