-- Anomaly Coop: NPC statistics of the PDA contacts hint (parity audit F4). The host counts them in the Lua state of its
-- NPCs (m_data.se_object[id]), which a client gets once, in its join save. coop_npc_stats.script publishes them over coop.sync.
local PASS, FAIL = 0, 0
local function check(ok, what)
	if ok then PASS = PASS + 1 else FAIL = FAIL + 1; print("FAIL " .. what) end
end

dofile("tests/lua/support/fake_sync.lua")
local F = fake_sync

local STATE = {} -- id -> m_data.se_object[id] of the machine that runs
local CALLS = 0
local CALLBACKS = {}

alife_object = function(id) return { id = id } end
alife_storage_manager = {
	get_se_obj_state = function(se, create)
		if not STATE[se.id] and create then STATE[se.id] = {} end
		return STATE[se.id]
	end,
}
game_statistics = {
	increment_npc_statistic = function(npc, value)
		CALLS = CALLS + 1
		local m = alife_storage_manager.get_se_obj_state(alife_object(npc:id()), true)
		if m then m[value] = (m[value] or 0) + 1 end
	end,
}
RegisterScriptCallback = function(name, fn) CALLBACKS[name] = fn end
printf = function() end

local function load_script()
	local env = setmetatable({}, { __index = _G })
	local fn = assert(loadfile("gamedata/scripts/coop_npc_stats.script"))
	setfenv(fn, env)
	fn()
	return env
end

local function npc(id) return { id = function() return id end } end

F.reset()
local host, client = F.machines(2)
local orig_inc = game_statistics.increment_npc_statistic
coop = coop or {}
coop.is_active = function() return true end
F.spawn(500)

-- the host
F.as(host, function()
	local m = load_script()
	m.on_game_start()
	check(game_statistics.increment_npc_statistic ~= orig_inc, "the host counts through the wrapper")
end)
local wrapped = game_statistics.increment_npc_statistic

-- a client: the wrapper has nothing to do on the host's numbers, the store writes the hint's table
local CLIENT_STATE = {}
F.as(client, function()
	game_statistics.increment_npc_statistic = orig_inc
	local saved = STATE
	STATE = CLIENT_STATE
	local m = load_script()
	m.on_game_start()
	check(game_statistics.increment_npc_statistic == orig_inc, "a client leaves the stock counter alone")
	STATE = saved
end)
game_statistics.increment_npc_statistic = wrapped

-- a kill on the host
F.as(host, function() game_statistics.increment_npc_statistic(npc(500), "killed_stalkers") end)
check(CALLS == 1, "the stock counter ran")
check(STATE[500].killed_stalkers == 1, "the host's own table")
do
	local saved = STATE
	STATE = CLIENT_STATE
	F.pump()
	STATE = saved
end
check(CLIENT_STATE[500] and CLIENT_STATE[500].killed_stalkers == 1, "the client's hint table follows")

-- not a statistic of the hint
F.as(host, function() game_statistics.increment_npc_statistic(npc(500), "something_else") end)
do
	local saved = STATE
	STATE = CLIENT_STATE
	F.pump()
	STATE = saved
end
check(CLIENT_STATE[500].something_else == nil, "only the hint's statistics travel")

-- the next one counts on
F.as(host, function() game_statistics.increment_npc_statistic(npc(500), "killed_stalkers") end)
do
	local saved = STATE
	STATE = CLIENT_STATE
	F.pump()
	STATE = saved
end
check(CLIENT_STATE[500].killed_stalkers == 2, "a later value replaces the old one")

-- a stat of a dead NPC is no error
F.as(host, function()
	local dead = { id = function() return 777 end }
	local saved = alife_storage_manager.get_se_obj_state
	alife_storage_manager.get_se_obj_state = function() return nil end
	game_statistics.increment_npc_statistic(dead, "killed_stalkers")
	alife_storage_manager.get_se_obj_state = saved
end)
check(true, "no table, no error")

print(("%d passed, %d failed"):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
