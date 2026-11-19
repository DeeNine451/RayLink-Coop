-- Dev 57 G17-1: consume the shipped routes through the native table and Lua shim.
-- Co-op: the host owns the map and world; each player owns local timers/options.
-- Server: the map server owns binders/restock, the world server owns SLHT's queue;
-- players own their timers/options. These declarations need no additional facts.
-- The runner exposes callback routes, but not C++ binder_action: the binder case
-- validates the consumed [binder_host] declaration; live binder dispatch is a stand check.
local compat = "coop_compat_f4_routes.ltx"
local roles = {
	{ name = "hostplay", mode = "host", world = true, level = true },
	{ name = "hostplay_client", mode = "client", world = false, level = false },
	{ name = "srv_world", mode = "host", world = true, level = false },
	{ name = "srv_map", mode = "host", world = false, level = true },
	{ name = "srv_client", mode = "client", world = false, level = false },
	{ name = "none", mode = "host", world = false, level = false, inactive = true },
}

local function boot(role, skip)
	local passes, fails = PASSES or 0, FAILS or 0
	MODE = role.mode
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	ROUTE_SKIP_FILES = skip and { [compat] = true } or {}
	route_stub_load()
	coop.is_active = function() return not role.inactive end
	coop.is_map_server = function() return role.name == "srv_map" end
	coop.is_dedicated = function() return role.name == "srv_world" end
	-- Like test_map_routes.lua: the native bridge exposes Table::route, while
	-- coop_router.cpp additionally lifts host routes marked as level behaviour.
	local original_of = coop.route.of
	coop.route.of = function(callback, fn)
		local d, script = original_of(callback, fn)
		local key, explicit = script:lower(), false
		for rule in pairs(ROUTE_SCRIPT_RULES) do
			if rule == key or (rule:sub(-1) == "*" and key:sub(1, #rule - 1) == rule:sub(1, -2)) then
				explicit = true
			end
		end
		if d == "host" and (ROUTE_LEVEL_SCRIPTS[key] or (not explicit and ROUTE_LEVEL_CALLBACKS[callback:lower()])) then
			d = "level"
		end
		return d, script
	end
	-- Supply role facts to the native runs_here rule. The stock route stub only
	-- has a host/client switch; host and level have different deciders on Server.
	coop.route.runs = function(domain)
		if role.inactive then return true end
		local authority = role.world
		if domain == "level" then authority = role.world or role.level end
		return coop_native.runs_here(domain, authority)
	end
	load_script_file("coop_route")
	check(coop_route.install(), role.name .. ": shim installs")
	F4_RAN = {}
end

local function handler(script, key)
	return from_script(script, "return function() F4_RAN['" .. key
		.. "'] = (F4_RAN['" .. key .. "'] or 0) + 1; return true end")
end

local function domain(callback, script)
	return coop.route.of(callback, handler(script, "probe"))
end

-- Read binder rules in the same file order supplied by the route harness.
local function binder_methods(binding)
	local methods = {}
	for _, name in ipairs(ROUTE_FILES) do
		local file = assert(io.open("gamedata/configs/" .. name, "r"))
		local section
		for line in file:lines() do
			line = line:gsub(";.*$", "")
			section = line:match("^%s*%[([^%]]+)%]") or section
			if section == "binder_host" then
				local key, value = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
				if key and key:lower() == binding then
					for method in value:lower():gmatch("[^,%s]+") do methods[method] = "host" end
				end
			end
		end
		file:close()
	end
	return methods
end

local cases = {
	{ id = "m08:8_exo_timer_owner", callback = "time_event", script = "exo_loot", want = "owner", timer = true },
	{ id = "m12:4_var_first_update_owner", callback = "actor_on_first_update", script = "axr_companions_varefined", want = "owner" },
	{ id = "m12:4_var_option_change_owner", callback = "on_option_change", script = "axr_companions_varefined", want = "owner" },
	{ id = "m14:3_npe_remove_all_timer_owner", callback = "time_event", script = "npe_actions", want = "owner", timer = true },
	{ id = "m14:3_npe_remove_one_timer_owner", callback = "time_event", script = "npe_actions", want = "owner", timer = true },
	{ id = "m23:4_slht_load_world", callback = "on_game_load", script = "utils_slht", want = "host", world = true },
	{ id = "m23:4_slht_queue_world", callback = "time_event", script = "utils_slht", want = "host", world = true, timer = true },
	{ id = "m23:4_slht_load_state_view", callback = "load_state", script = "utils_slht", want = "view" },
}

for _, role in ipairs(roles) do
	boot(role)
	check(#ROUTE_ERRORS == 0, role.name .. ": no route parse errors")
	for _, case in ipairs(cases) do
		local label = role.name .. ": " .. case.id
		local fn = handler(case.script, case.id)
		local got, script = coop.route.of(case.callback, fn)
		check(got == case.want, label .. " domain: " .. tostring(got) .. ", want " .. case.want)
		check(script == case.script, label .. " resolves the script key")
		local should_run = role.inactive or not case.world or role.world
		check(coop.route.runs(got) == should_run, label .. " runs on the correct decider/player")
		if case.timer then
			CreateTimeEvent("f4_routes", case.id, 0, fn)
			local event = TIMEEV[#TIMEEV]
			check(event.f(unpack(event.p)) == true, label .. " timer completes even when skipped")
		else
			AddScriptCallback(case.callback)
			RegisterScriptCallback(case.callback, fn)
			SendScriptCallback(case.callback)
		end
		check((F4_RAN[case.id] or 0) == (should_run and 1 or 0), label .. " actual shim invocation count")
	end

	-- m32:2: only update is host-only; the native engine applies this binder
	-- declaration to mirrors, not to the host, map server or single player.
	local methods = binder_methods("kit_binder.bind")
	check(methods.update == "host", role.name .. ": m32:2_kit_update_host_only declaration")
	methods.update = nil
	check(next(methods) == nil, role.name .. ": m32:2_kit_other_methods_unchanged")
	check(next(binder_methods("absent_kit.bind")) == nil, role.name .. ": absent binder keeps the default")

	check(domain("trader_on_restock", "exo_loot") == "level", role.name .. ": m08:8_exo_restock_stays_level")
	check(coop.route.runs(domain("trader_on_restock", "exo_loot")) == (role.inactive or role.world or role.level),
		role.name .. ": m08:8_exo_restock_runs_on_authorities_not_mirrors")
	check(domain("actor_on_update", "npe_actions") == "host", role.name .. ": m14:3_npe_other_callbacks_unchanged")
	check(domain("actor_on_update", "axr_companions_varefined") == "host", role.name .. ": m12:4_var_other_callbacks_unchanged")
	check(domain("unique_call", "utils_slht") == "host", role.name .. ": m23:4_slht_unique_call_world")
	check(domain("save_state", "utils_slht") == "host", role.name .. ": m23:4_slht_save_world")
	check(domain("on_game_load", "utils_slht_other") == "view", role.name .. ": m23:4_slht_rule_is_exact")
	if role.inactive then
		for _, d in ipairs({ "host", "level", "owner", "view", "none" }) do
			check(coop.route.runs(d), "none: single_player_unchanged_" .. d)
		end
	end
end

print("== absent_modules_do_not_change_unrelated_routes")
local unrelated = {
	{ "actor_on_first_update", "unknown_f4_mod" },
	{ "time_event", "unknown_f4_mod" },
	{ "time_event", "exo_loot_other" },
	{ "on_option_change", "axr_companions_varefined_other" },
	{ "time_event", "npe_actions_other" },
	{ "on_game_load", "utils_slht_other" },
}
boot(roles[2], true)
local before = {}
for i, pair in ipairs(unrelated) do before[i] = domain(pair[1], pair[2]) end
boot(roles[2])
for i, pair in ipairs(unrelated) do
	check(domain(pair[1], pair[2]) == before[i], pair[1] .. "@" .. pair[2] .. ": no unrelated route changed")
end
for _, script in ipairs({ "kit_binder", "exo_loot", "npe_actions", "axr_companions_varefined", "utils_slht" }) do
	check(rawget(_G, script) == nil, script .. ": route declaration does not load an absent module")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
