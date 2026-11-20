-- A map server must use stock selection while its weather renderer is unavailable.
MODE = "client"
dofile("tests/lua/support/stubs.lua")
coop.is_map_server = function() return true end
coop.is_mirror = function() return false end
local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_script_file("coop_mode"))
load_coop_main()
load_script_file("coop_npc_players")

local selected, rolled, view = 0, 0
local cls = {}
function cls:change_period() rolled = rolled + 1 end
function cls:select_weather()
	selected = selected + 1
	view = { self.cycle, self.preset, self.transition_period, self.pre_blowout_period }
end
local wm = setmetatable({ cycle = "clear", preset = "first" }, { __index = cls })
level_weathers = { WeatherManager = cls, get_weather_manager = function() return wm end }
local state
coop.sync = {
	get = function() return state end,
	set = function() error("a map must not write the world forecast") end,
}
load_script_file("coop_world_weather").on_game_start()
local function step()
	NOW = NOW + 1100
	SendScriptCallback("actor_on_update")
end
step()
check(selected == 0, "no snapshot yet: no tick-driven selection")
wm:change_period()
check(rolled == 0, "the map server never rolls its own period")

state = { c = "rain", p = "outdoor_1", lw = "atmosfear_transition" }
step()
check(selected == 1 and view[1] == "rain" and view[2] == "outdoor_1" and view[3] and not view[4],
	"stock selection uses the world cycle, preset and transition")
step()
check(selected == 1, "an unchanged cycle does not select again")
state.lw = "atmosfear_pre_blowout"
step()
check(selected == 2 and not view[3] and view[4], "the world pre-blowout change also uses stock selection")

-- With no diagnostic hook, map leadership still determines whether task IDs are read.
modes.install(coop_mode, "srv_map")
local reads = 0
task_manager = { get_task_manager = function()
	reads = reads + 1
	return { task_info = { copied_task = true } }
end }
coop_main.on_game_start()
step()
check(reads == 0, "a map has only copies of tasks even when the launcher context hook is absent")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
