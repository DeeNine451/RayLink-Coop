-- World parity W1 and W6 (coop_world_weather.script): the script weather manager of every machine follows the host, a
-- client's wetness follows the host's. Run: tools\test_lua.cmd world_weather
dofile("tests/lua/support/harness_world.lua")

-- level_weathers as bind_stalker sees it: the class table, one manager, the stock order of update (the hour turns:
-- change_period, then select_weather). The rolls are the machine's own, as in stock.
local function stock_weathers(M, seed)
	local E = M.env
	local rolls = seed
	local function roll(what)
		rolls = rolls + 1
		return what .. "_" .. tostring(rolls)
	end
	local cls = {}
	cls.__index = cls
	function cls:change_period()
		self.cycle = roll("cycle")
		self.preset = roll("preset")
		M.periods = (M.periods or 0) + 1
	end
	function cls:select_weather(now)
		self.levelWeather = "atmosfear_" .. tostring(self.cycle)
		self.weather_file = self.preset
		self.curr_weather = self.next_weather
		self.next_weather = self.preset
		M.selects = (M.selects or 0) + 1
		M.set_weather = self.weather_file
		self:set_brightness_boosts()
	end
	function cls:set_brightness_boosts()
		M.boosts = M.boosts or {}
		M.boosts[#M.boosts + 1] = tostring(self.weather_file) .. "@" .. tostring(self.last_hour)
	end
	function cls:update()
		if self.last_hour ~= E.level.get_time_hours() then
			self.last_hour = E.level.get_time_hours()
			self:change_period()
			self:select_weather(false)
		end
	end
	function cls:get_curr_weather() return self.cycle end
	local wm = setmetatable({ cycle = "clear", preset = "p0", weather_file = "p0", curr_weather = "p0", next_weather = "p0",
		levelWeather = "atmosfear_clear", last_hour = 12 }, cls)
	E.level_weathers = { WeatherManager = cls, get_weather_manager = function() return wm end }
	M.hour, M.wet, M.rain = 12, 0, 0
	E.level.get_time_hours = function() return M.hour end
	E.level.rain_wetness = function() return M.wet end
	E.weather = { get_value_numric = function(n) return n == "rain_density" and M.rain or 0 end }
	return wm
end

local function step(H, C)
	NOW = NOW + 1100
	H.fire("actor_on_update")
	C.fire("actor_on_update")
	world_pump()
end

print("== W1: the script weather manager")
do
	local H, C = world_pair()
	local wh, wc = stock_weathers(H, 100), stock_weathers(C, 200)
	local WH, WC = load_script(H, "coop_world_weather"), load_script(C, "coop_world_weather")
	WH.on_game_start()
	WC.on_game_start()

	step(H, C)
	check(wc.cycle == "clear" and wc.preset == "p0", "the first state of the host reaches the client")

	-- the game hour turns on both: the host rolls, the client takes it
	H.hour, C.hour = 13, 13
	wh:update()
	wc:update()
	check(H.periods == 1 and H.set_weather == wh.preset, "the host rolls its period and sets its weather as in stock")
	check(C.periods == nil, "a client rolls no period of its own")
	step(H, C)
	check(wc.cycle == wh.cycle and wc.preset == wh.preset and wc.weather_file == wh.weather_file, "cycle, preset and file are the host's")
	check(wc.curr_weather == wh.curr_weather and wc.next_weather == wh.next_weather and wc.levelWeather == wh.levelWeather,
		"current and next weather and the level weather are the host's (fog, meteorites, distant storm read them)")
	check(wc:get_curr_weather() == wh:get_curr_weather(), "level_environment reads the same cycle on both")
	check(C.boosts and C.boosts[#C.boosts] == tostring(wh.weather_file) .. "@13", "night brightness is set from the host's file, at this hour")

	-- no new weather, the hour turns: brightness is keyed to the hour as well
	H.hour, C.hour = 14, 14
	local before = #C.boosts
	wc:update()
	check(#C.boosts == before + 1 and C.boosts[#C.boosts] == tostring(wc.weather_file) .. "@14", "a client's own hour turn sets its brightness again")

	-- a nothing-new tick writes nothing
	local sets = H.sync_sets
	step(H, C)
	step(H, C)
	check(H.sync_sets == sets, "the host writes the state only when it changed")
end

-- a client that has no state yet keeps the stock code
do
	local H, C = world_pair()
	local wh, wc = stock_weathers(H, 100), stock_weathers(C, 200)
	local WC = load_script(C, "coop_world_weather")
	WC.on_game_start()
	wc:select_weather(true)
	check(C.selects == 1, "no state from the host yet: select_weather runs (levelWeather must not stay empty for update)")
end

do
	reset_world()
	local S = machine("single", 0, { [0] = 0 })
	load_script(S, "coop_npc_players")
	local ws = stock_weathers(S, 300)
	local WS = load_script(S, "coop_world_weather")
	WS.on_game_start()
	S.hour = 13
	ws:update()
	check(S.periods == 1 and S.selects == 1, "single player: the stock weather manager")
end

print("== W6: wetness")
do
	local H, C = world_pair()
	stock_weathers(H, 100)
	stock_weathers(C, 200)
	local WH, WC = load_script(H, "coop_world_weather"), load_script(C, "coop_world_weather")
	WH.on_game_start()
	WC.on_game_start()
	C.console.ssfx_wetness_multiplier = "(1.000000, 0.300000, 0.000000)"

	-- a client joins a long rain: it is dry, the host is wet
	H.wet, C.wet = 0.9, 0
	H.rain, C.rain = 0.5, 0.5
	step(H, C)
	step(H, C)
	local v = C.console.ssfx_wetness_multiplier
	local x, y = v:match("%(([%d%.]+),([%d%.]+),")
	check(tonumber(x) and tonumber(x) > 10, "dry under the host's wet sky: the build-up runs fast")
	check(tonumber(y) == 0.3, "the drying rate stays")

	-- caught up: the player's own numbers are back
	C.wet = 0.89
	step(H, C)
	check(C.console.ssfx_wetness_multiplier == "(1,0.3,0)" or C.console.ssfx_wetness_multiplier:find("^%(1"), "inside the band: the player's multiplier is back")

	-- 144 fps against 40: the client ran ahead, it waits for the host
	C.wet = 0.99
	step(H, C)
	x = C.console.ssfx_wetness_multiplier:match("%(([%d%.]+),")
	check(tonumber(x) <= 0.1, "ahead of the host in the rain: the build-up is held back")

	-- the rain is over, the host dried first
	H.wet, C.wet = 0.2, 0.7
	H.rain, C.rain = 0, 0
	step(H, C)
	step(H, C)
	v = C.console.ssfx_wetness_multiplier
	x, y = v:match("%(([%d%.]+),([%d%.]+),")
	check(tonumber(y) > 5, "wetter than the host with no rain: it dries fast")
	check(tonumber(x) == 1, "the build-up rate is the player's own again")

	-- the world ends in the middle of a correction: user.ltx must not keep it
	C.fire("actor_on_net_destroy")
	check(C.console.ssfx_wetness_multiplier:find("^%(1") and C.console.ssfx_wetness_multiplier:find("0%.3"), "leaving the world puts the player's numbers back")

	H.wet = 0.2 + 0.001
	local sets = H.sync_sets
	step(H, C)
	check(H.sync_sets == sets, "a small change of the host's wetness is not sent")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
