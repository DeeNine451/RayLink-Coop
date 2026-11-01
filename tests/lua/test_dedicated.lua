-- Anomaly Coop test: the dedicated host's half in Lua (gamedata\scripts\coop_dedicated.script, docs\DEDICATED_HOST.md). A new world gets what the
-- faction-select screen would write, except the start map (the actor stays on fake_start) and what is for a character; a world that is
-- loaded gets nothing; stock IsTestMode no longer takes the service level for a test map. A window host is left alone.
-- The audit's fixes in other scripts: the rule "the host decides", the reward group, the choice of a start, the window's new game.
-- Not shipped. Run: tools\test_lua.cmd dedicated
PASSES, FAILS = 0, 0
function check(cond, what)
	if cond then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. tostring(what))
	end
end

local function read(path)
	local fh = assert(io.open(path, "rb"), "no " .. path)
	local text = fh:read("*a")
	fh:close()
	return text
end

local function fresh(dedicated, new_world)
	local written = {}
	IsTestMode = function() return true end
	printf = function() end
	axr_main = {
		config = {
			w_value = function(_, section, key, value)
				check(section == "character_creation", "only the section of a new game: " .. tostring(section))
				written[key] = value == nil and "removed" or value
			end,
		},
	}
	coop = dedicated == nil and nil or { is_dedicated = function() return dedicated end, dedicated_new_world = function() return new_world end }
	local chunk = assert(loadstring(read("gamedata/scripts/coop_dedicated.script"), "coop_dedicated"))
	local env = setmetatable({}, { __index = _G })
	setfenv(chunk, env)
	chunk()
	env.on_game_start()
	return written
end

-- ------------------------------------------------------------------------------------------------ a new world
do
	local w = fresh(true, true)
	check(w.new_game_faction == "stalker", "a new world has a faction: the storyline hangs on it")
	check(w.new_game_story_mode == true, "story mode is on")
	check(w.new_game_difficulty == 1 and w.new_game_economy == 1, "the screen's defaults")
	check(w.new_game_map == "removed", "no start map: the actor stays on fake_start")
	check(w.new_game_test == "removed", "no test map: it would create a world with no population")
	check(w.new_game_money == "removed" and w.new_game_loadout == "removed", "nothing for a character")
	check(IsTestMode() == false, "the service level is no test map")
end

-- ------------------------------------------------------------------------------------------------ a loaded world
do
	local w = fresh(true, false)
	check(next(w) == nil, "a loaded world: the keys would give the ghost a new start on every load")
	check(IsTestMode() == false, "the service level is no test map after a load either")
end

-- ------------------------------------------------------------------------------------------------ a window host, an exe without co-op
do
	local w = fresh(false, true)
	check(next(w) == nil, "a window host chooses in its own screen")
	check(IsTestMode() == true, "stock IsTestMode stays on a window host")
	w = fresh(nil)
	check(next(w) == nil, "no coop table: nothing happens")
	check(IsTestMode() == true, "no coop table: stock IsTestMode")
end

-- ------------------------------------------------------------------------------------------------ the audit's fixes, by their text
do
	local group = read("gamedata/scripts/coop_economy_group.script")
	check(group:find('rule == "host" and api and api.is_dedicated', 1, true) ~= nil, "no host to decide: the players vote")
	local modes = read("gamedata/scripts/coop_newgame_modes.script")
	check(modes:find("%-coop_dedicated", 1, true) ~= nil, "a dedicated host's new game is a co-op host's")
	local char = read("gamedata/scripts/coop_menu_char.script")
	check(char:find('level == ""', 1, true) ~= nil, "an offer with no level: every start of the faction")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
