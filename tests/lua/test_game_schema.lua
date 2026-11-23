-- Anomaly Coop test (split levels, F3a task 3): the two new game rules and the new default in the catalog
-- gamedata\scripts\coop_game_schema.script (docs\GAME_SETTINGS.md 1.2, 3.6, 8.2; docs\plans\2026-10-24-f3a-split-levels.md 3):
--   c|coop_split_levels      saved flag of the old hybrid
--   c|coop_story_together    saved flag of the former story gates
--   o|coop/coop_session/join_spawn   a new player appears at the base of the world's faction by default
-- The catalog is loaded into a sealed environment (the standard library and nothing of the engine). The list of 21 console
-- variables is also held against the engine's white list in engine\src\xrCoop\coop_game_values.h when that file is there.
-- Not shipped. Run: tools\test_lua.cmd game_schema
local PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function finish()
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(FAILS == 0 and 0 or 1)
end

-- ------------------------------------------------------------------------------------------------ sealed loader
local SAFE = {}
for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math" }) do
	SAFE[n] = _G[n]
end
SAFE._G = SAFE

local function load_module(name)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	if not fh then return nil, "gamedata/scripts/" .. name .. ".script is missing" end
	local src = fh:read("*a")
	fh:close()
	local f, err = loadstring(src, "@" .. name .. ".script")
	if not f then return nil, err end
	local this = setmetatable({}, { __index = SAFE })
	setfenv(f, this)
	local ok, err2 = pcall(f)
	if not ok then return nil, err2 end
	return this
end

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function index_of(list, v)
	for i, x in ipairs(list) do
		if x == v then return i end
	end
	return nil
end

local schema, serr = load_module("coop_game_schema")
check(schema ~= nil, "coop_game_schema loads in the sealed environment" .. (serr and (": " .. tostring(serr)) or ""))
if not schema then finish() end

local SPLIT, STORY = "c|coop_split_levels", "c|coop_story_together"
local JOIN = "o|coop/coop_session/join_spawn"

-------------------------------------------------------------------------------
print("== the 21 console variables")
local FIRST_17 = { "coop_friendly_fire", "coop_max_new_characters", "coop_share_rewards", "coop_death_mode", "coop_death_drop",
	"coop_bleedout", "coop_revive_health", "coop_respawn_delay", "coop_contusion", "coop_death_money", "coop_death_wear",
	"coop_death_rank", "coop_hardcore_new_kit", "coop_checkpoints_group", "coop_autosave_interval", "coop_autosave_count",
	"coop_death_share" }
check(#schema.CVARS == 21, "CVARS holds 21 names (" .. #schema.CVARS .. ")")
local same = true
for i, n in ipairs(FIRST_17) do
	if schema.CVARS[i] ~= n then same = false end
end
check(same, "the first 17 names keep their order")
check(schema.CVARS[18] == "coop_split_levels" and schema.CVARS[19] == "coop_story_together", "rows 18 and 19 are the split-levels rules")
check(schema.CVARS[20] == "coop_npc_finish_downed", "row 20 is the NPC AI rule: stalkers finish a downed player")
check(schema.CVARS[21] == "coop_world_server", "row 21 is the new split mode: the world as a separate process (owner 2026-11-13)")
for n, def in pairs({ coop_split_levels = 0, coop_story_together = 1, coop_world_server = 0 }) do
	local c = schema.CVAR[n]
	check(c ~= nil and c.kind == "int" and c.min == 0 and c.max == 1 and c.def == def, n .. ": an on/off console flag, default " .. def)
end

-- the engine's white list (coop::game::kGameCvars) is the same list in the same order
local header = read_file("engine/src/xrCoop/coop_game_values.h")
if header then
	local body = header:match("kGameCvars%[%]%s*=%s*{(.-)};")
	local names = {}
	for n in (body or ""):gmatch('"([%w_]+)"') do names[#names + 1] = n end
	local runtime = {}
	for _, k in ipairs(schema.CVARS) do
		if k ~= "coop_split_levels" and k ~= "coop_story_together" and k ~= "coop_world_server" then
			runtime[#runtime + 1] = k
		end
	end
	local equal = #names == #runtime
	for i, n in ipairs(names) do
		if runtime[i] ~= n then equal = false end
	end
	check(#names == 18 and equal, "coop_game_values.h kGameCvars matches the live cvars (" .. #names .. " names)")
else
	print("  skip the engine sources are not checked out: kGameCvars is not compared")
end

local c_items = 0
for _, k in ipairs(schema.keys()) do
	if k:find("^c|") then c_items = c_items + 1 end
end
check(c_items == 18, "18 console variables are editable catalog items (" .. c_items .. ")")

-------------------------------------------------------------------------------
print("== legacy world flags")
for _, key in ipairs({ SPLIT, STORY, "c|coop_world_server" }) do
	check(not schema.item(key) and not schema.editable(key, false) and not schema.editable(key, true),
		key .. ": retained in the cvar schema, absent from the creation and editing menus")
	check(schema.canon(key, "1") == "1" and schema.canon(key, "0") == "0", key .. ": saved values survive canonicalization")
end

-------------------------------------------------------------------------------
print("== join_spawn: at the faction's base by default")
local join = schema.item(JOIN)
check(join ~= nil and join.def == "faction_start", "the default is faction_start (" .. tostring(join and join.def) .. ")")
check(schema.default(JOIN) == "faction_start", "default(join_spawn)")
check(join.values[1][1] == "host" and join.values[2][1] == "faction_start" and #join.values == 2, "both values stay: host and faction_start")
check(schema.normalize(JOIN, "host") == "host" and schema.normalize(JOIN, "faction_start") == "faction_start"
	and schema.normalize(JOIN, "somewhere") == nil, "normalize: the two tokens only")
check(schema.to_raw(JOIN, "faction_start") == "faction_start", "to_raw")

-------------------------------------------------------------------------------
print("== two rules of the 2026-10-31 night: foreign loot, stalkers finish a downed player")
local LOOT, FINISH = "o|coop/coop_session/loot_claim", "c|coop_npc_finish_downed"
local loot = schema.item(LOOT)
check(loot ~= nil and loot.tab == "party" and loot.kind == "check" and loot.src == "o" and loot.def == true,
	"Foreign loot: a check on the group tab, on by default")
check(loot and loot.when == "session" and schema.editable(LOOT, true) and schema.editable(LOOT, false),
	"Foreign loot: changed between sessions, editable on an existing game")
check(schema.normalize(LOOT, "false") == false and schema.normalize(LOOT, "true") == true and schema.normalize(LOOT, "maybe") == nil
	and schema.to_raw(LOOT, false) == "false", "Foreign loot: an option flag is true / false")
local downed = schema.item(FINISH)
check(downed ~= nil and downed.tab == "death" and downed.kind == "check" and downed.src == "c" and downed.cvar == "coop_npc_finish_downed"
	and downed.def == false, "finish a downed player: a check on the death tab, a console variable, off by default (owner 2026-11-02)")
check(downed and downed.range and downed.range[1] == 0 and downed.range[2] == 1 and downed.int == true
	and schema.to_raw(FINISH, false) == "0" and schema.to_raw(FINISH, true) == "1", "finish a downed player: 0..1, the console form")
check(downed and downed.shown_if == nil, "finish a downed player: always shown")

-------------------------------------------------------------------------------
print("== World population (ZCP)")
for _, name in ipairs({ "stalker", "monster" }) do
	local key = "m|SMR/smr_amain/" .. name .. "_pop_factor"
	local it = schema.item(key)
	check(it and it.tab == "world" and it.kind == "list" and it.needs_mcm == "SMR" and it.def == 0.5,
		key .. ": an SMR multiplier on World, default 0.5")
	local steps = it and #it.values == 61
	for i = 0, 60 do
		if not steps or it.values[i + 1][1] ~= i / 20 then steps = false; break end
	end
	check(steps and schema.to_raw(key, "-0.05") == nil and schema.to_raw(key, "3.05") == nil,
		key .. ": the MCM slider's 0..3 range in steps of 0.05")
end
for _, pair in ipairs({ { "stalker", "smr_mutants_mcm" }, { "mutant", "smr_stalkers_mcm" } }) do
	local key = "o|alife/general/alife_" .. pair[1] .. "_pop"
	local it = schema.item(key)
	check(it and it.hidden_by_script == pair[2], key .. ": uses the GAMMA precondition")
end

-------------------------------------------------------------------------------
print("== strings")
local ids = schema.text_ids()
local want = { "st_coop_game_join_spawn", "st_coop_game_loot_claim", "st_coop_game_npc_finish_downed",
	"st_coop_game_join_spawn_host", "st_coop_game_join_spawn_faction_start" }
for _, id in ipairs(want) do
	check(index_of(ids, id) ~= nil, "text_ids names " .. id)
end
for _, lang in ipairs({ "eng", "rus" }) do
	local have = {}
	for _, file in ipairs({ "st_coop_game.xml", "st_coop_levels.xml" }) do
		local src = read_file("gamedata/configs/text/" .. lang .. "/" .. file)
		for id in (src or ""):gmatch('<string%s+id="([^"]+)"') do have[id] = (have[id] or 0) + 1 end
	end
	local missing = {}
	for _, id in ipairs(want) do
		if not have[id] then missing[#missing + 1] = id end
	end
	check(#missing == 0, lang .. ": the strings of the current rules exist (missing: " .. table.concat(missing, ",") .. ")")
	for _, id in ipairs({ "st_coop_game_split_levels", "st_coop_game_story_together",
		"st_coop_game_world_server", "st_coop_game_world_server_hint" }) do
		check(not have[id] and not index_of(ids, id), lang .. ": removed " .. id)
	end
end

finish()
