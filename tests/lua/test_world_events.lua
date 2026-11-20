local expected = {
	"mods.preblowout_warning", "coop_env", "srv.news_sample", "mods.bounty_t",
	"coop.op.answer", "coop.dbg.run", "coop.dbg.note", "coop.dbg.say", "coop.dbg.order",
	"coop_scorch", "mods.rf_freq_r", "coop_rep_map_ack", "npc.comp_recall",
	"coop_set", "quests.far_do", "npc.comp_adopt", "npc.comp_drop",
	"coop_brain", "coop_orders", "coop_dao", "coop_sl_news", "coop_fac",
	-- S6 integration (A-S6-L-worldb): the player-facing news; a map server reports its news as core.news_up and only the
	-- world turns it into core.news, so a bridge's core.news is refused before the relay rewrites its sender to 0 - on
	-- every hosting, including a rehost of the same Lua state after the native session end cleared the reservations
	"core.news",
}
local path = "gamedata/scripts/coop_world_events.script"
local passed, failed = 0, 0

local function check(ok, message)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. message)
	end
end

local function load_script(api)
	local env = {}
	env._G = env
	env.coop = api
	setmetatable(env, { __index = _G })
	local chunk, err = loadfile(path)
	if not chunk then
		check(false, tostring(err))
		return
	end
	setfenv(chunk, env)()
	return env
end

-- A new Lua state in each kind of process. The API exists before a session does.
for _, process in ipairs({ "Co-op host", "Co-op player", "world", "map", "server player" }) do
	local reserved = {}
	local api = setmetatable({
		reserve_world_event = function(name)
			reserved[#reserved + 1] = name
			return true
		end,
	}, { __index = function(_, key) error("Unexpected process or session query: " .. key) end })
	local env = load_script(api)
	if env then
		check(#reserved == 0, process .. " waits for on_game_start")
		for i = 1, 2 do
			-- The second call models the same Lua state hosting again after a native session end.
			reserved = {}
			local ok, err = pcall(env.on_game_start)
			check(ok, process .. " startup " .. i .. ": " .. tostring(err))
			check(#reserved == #expected, process .. " reserves the whole list")
			local names = {}
			for _, name in ipairs(reserved) do names[name] = true end
			for _, name in ipairs(expected) do check(names[name], process .. " reserves " .. name) end
		end
	end
end

for _, api in pairs({ false, {} }) do
	local env = load_script(api or nil)
	if env then check(pcall(env.on_game_start), "startup without the native API") end
end

local attempts, warnings, warning = 0, 0, nil
local env = load_script({ reserve_world_event = function()
	attempts = attempts + 1
	return attempts ~= 1
end })
if env then
	env.printf = function(fmt, name)
		warnings = warnings + 1
		warning = string.format(fmt, name)
	end
	local ok, err = pcall(env.on_game_start)
	check(ok, "registration failure leaves startup running: " .. tostring(err))
	check(attempts == #expected, "registration continues after a refusal")
	check(warnings == 1 and warning:find(expected[1], 1, true), "the refused name is logged once")
end

print(string.format("%d passed, %d failed", passed, failed))
