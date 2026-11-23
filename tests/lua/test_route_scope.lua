-- Anomaly Coop: the code scope the callback router keeps for the engine's writer gate (TZ Р32, temp\r30\design\R32-final.md §1 W2a,
-- §6 test_route_scope.lua): every wrapper of gamedata\scripts\coop_route.script is registered with its domain and stays on the Lua
-- stack while its handler runs, so the engine reads the scope of a script write from the live stack (coop_router.cpp l_scope,
-- writer_refuses). A time event and a unique call keep the scope of the code that set them: "a timer set in host code keeps host".
-- The engine half is stood in below exactly as coop_router.cpp does it (a weak table wrapper -> domain; the innermost registered
-- frame wins). Run: tools\test_lua.cmd route_scope

local function intercepts()
	return coop_route and coop_route.intercepts()
end

-- stubs.lua from_script with arguments for the chunk (its `...`)
local function script_fn(script, body, ...)
	local f = assert(loadstring(body, "@D:\\Games\\Anomaly\\gamedata\\scripts\\" .. script .. ".script"))
	return f(...)
end

-- The engine's coop.route.scoped / coop.route.scope (coop_router.cpp): marks in a weak-keyed table, read from the stack.
local SCOPES
local function install_scope_api()
	SCOPES = setmetatable({}, { __mode = "k" })
	coop.route.scoped = function(fn, domain)
		if type(fn) ~= "function" or type(domain) ~= "string" then return end
		if domain ~= "?" and domain ~= "host" and domain ~= "owner" and domain ~= "view" and domain ~= "level"
			and domain ~= "none" then return end
		SCOPES[fn] = domain
	end
	coop.route.scope = function()
		for level = 2, 66 do -- 1 is this function (the engine's level 0, its own C frame)
			local info = debug.getinfo(level, "f")
			if not info then break end
			local d = info.func and SCOPES[info.func]
			if d then return d end
		end
		return nil
	end
end

-- What the engine's writer gate maps a domain to (coop_calls.h scope_of_domain).
local function gate_scope(d)
	if d == "host" then return "decision" end
	if d == "level" or d == "owner" or d == "view" then return "level code" end
	return "unknown"
end

-- A fresh Lua world per case (stubs: axr_main, coop + coop.route; the scope API unless `old_exe`; then coop_route.script).
local function boot(mode, old_exe)
	MODE = mode
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	RAN = {}
	coop_native.reset_counts()
	for _, name in ipairs({ "actor_on_item_use", "npc_on_death_callback" }) do AddScriptCallback(name) end
	if not old_exe then install_scope_api() end
	load_script_file("coop_route")
	check(coop_route.install() == true, mode .. ": the shim installs")
end

-- what the engine would read if the running code called alife():create now
local function engine_scope() return coop.route.scope and coop.route.scope() or nil end

print("== route_scope_handlers_run_in_their_domain")
for _, mode in ipairs({ "host", "client" }) do
	boot(mode)
	check(engine_scope() == nil, mode .. ": outside any handler no scope (the engine: unknown)")
	RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function() RAN.host = coop.route.scope() end"))
	RegisterScriptCallback("actor_on_item_use", from_script("some_unknown_mod", "return function() RAN.owner = coop.route.scope() end"))
	SendScriptCallback("actor_on_update")
	SendScriptCallback("actor_on_item_use")
	if mode == "host" then
		check(RAN.host == "host", "host: a host script's handler runs in host (got " .. tostring(RAN.host) .. ")")
		local th = coop_route.wrapper_of("actor_on_update", nil)
		check(th == nil, "host: wrapper_of without a function is nil")
		check(gate_scope(RAN.host) == "decision", "host: the writer gate takes it for a decision")
	else
		check(RAN.host == nil, "client: the host handler is skipped, as before")
	end
	check(RAN.owner == "owner", mode .. ": an unknown script's actor_on_item_use runs in owner (got " .. tostring(RAN.owner) .. ")")
	check(gate_scope(RAN.owner) == "level code", mode .. ": the writer gate takes owner code for level code")
	check(engine_scope() == nil, mode .. ": after the handlers no scope is left")
	-- the engine table knows every wrapper the shim made
	local list = intercepts().actor_on_item_use
	local marked = 0
	for k in pairs(list) do if type(k) == "function" and SCOPES[k] == "owner" then marked = marked + 1 end end
	check(marked == 1, mode .. ": the handler's wrapper is registered with its domain")
end

print("== route_scope_kept_scope")
boot("host")
local K = coop_route.kept_scope
check(K("host", "owner") == "host", "host code that sets an owner function: host")
check(K("owner", "host") == "host", "a host function set by owner code runs only where host runs: host")
check(K(nil, "host") == "host", "a host function set by unknown code: host")
check(K("owner", "owner") == "owner", "owner code that sets an owner function: owner")
check(K("level", "view") == "level", "level code that sets a view function: level")
check(K("view", "level") == "view", "view code that sets a level function: view")
check(K(nil, "owner") == "?", "set by no wrapper: unknown")
check(K("?", "owner") == "?", "set by an unknown-scoped timer: unknown")
check(K("owner", "none") == "?", "a function that runs nowhere in a session: unknown")
check(gate_scope("?") == "unknown", "the engine maps ? to unknown (a decision on the world server)")

print("== route_scope_timer_set_in_host_code_keeps_host")
-- host mode: a process where host code runs (the co-op host, and so the world server: coop.route.runs("host"))
boot("host")
local timer = script_fn("some_unknown_mod", "return function() RAN.timer = coop.route.scope() return true end")
RegisterScriptCallback("actor_on_update", script_fn("treasure_manager", [[local t = ... return function()
	CreateTimeEvent("tm", "later", 0, t)
end]], timer))
SendScriptCallback("actor_on_update")
local ev = TIMEEV[#TIMEEV]
check(ev ~= nil and ev.f ~= timer, "the timer set in host code is wrapped")
check(ev and SCOPES[ev.f] == "host", "its wrapper is registered as host (got " .. tostring(ev and SCOPES[ev.f]) .. ")")
-- the event queue fires it later, outside the handler (bind_actor's update)
RAN.timer = nil
ev.f()
check(RAN.timer == "host", "a timer set in host code keeps host when it fires (got " .. tostring(RAN.timer) .. ")")
check(gate_scope(RAN.timer) == "decision", "the writer gate takes it for a decision")
-- ... and also when the queue happens to run inside an owner handler: the innermost wrapper is the timer's
RAN.timer = nil
RegisterScriptCallback("actor_on_item_use", from_script("ui_extra_mod", "return function(f) f() end"))
SendScriptCallback("actor_on_item_use", ev.f)
check(RAN.timer == "host", "fired inside an owner handler it is still host (got " .. tostring(RAN.timer) .. ")")

print("== route_scope_timer_set_in_owner_code")
for _, mode in ipairs({ "host", "client" }) do
	boot(mode)
	local owner_fn = from_script("some_unknown_mod", "return function() RAN.t1 = coop.route.scope() end")
	local host_fn = from_script("death_manager", "return function() RAN.t2 = coop.route.scope() end")
	RegisterScriptCallback("actor_on_item_use", script_fn("other_unknown_mod", [[local a, b = ... return function()
		CreateTimeEvent("x", "owner", 0, a)
		CreateTimeEvent("x", "host", 0, b)
	end]], owner_fn, host_fn))
	SendScriptCallback("actor_on_item_use")
	check(#TIMEEV == 2, mode .. ": owner code set both timers")
	check(SCOPES[TIMEEV[1].f] == "owner", mode .. ": the owner function's timer is registered as owner")
	check(SCOPES[TIMEEV[2].f] == "host", mode .. ": a host script's timer set by owner code is registered as host")
	TIMEEV[1].f()
	TIMEEV[2].f()
	check(RAN.t1 == "owner", mode .. ": an owner function set by owner code runs in owner (got " .. tostring(RAN.t1) .. ")")
	if mode == "host" then
		check(RAN.t2 == "host", "host: a host script's timer set by owner code runs in host: only where the world is decided (got "
			.. tostring(RAN.t2) .. ")")
	else
		check(RAN.t2 == nil, "client: the host script's timer is skipped, as before")
	end
end

print("== route_scope_timer_set_outside_any_handler_is_unknown")
boot("host")
local plain = from_script("some_unknown_mod", "return function() RAN.plain = coop.route.scope() end")
CreateTimeEvent("x", "file_level", 0, plain)
local plain_w = TIMEEV[#TIMEEV].f
check(SCOPES[plain_w] == "?", "a timer set by no wrapper is registered as unknown (got " .. tostring(SCOPES[plain_w]) .. ")")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function(f) f() end"))
SendScriptCallback("actor_on_update", plain_w)
check(RAN.plain == "?", "fired inside a host handler it stays unknown: it does not borrow the outer scope (got "
	.. tostring(RAN.plain) .. ")")

print("== route_scope_one_wrapper_per_function_and_scope")
boot("host")
local f = from_script("some_unknown_mod", "return function() end")
CreateTimeEvent("x", "a", 0, f)
CreateTimeEvent("x", "b", 0, f)
check(TIMEEV[1].f == TIMEEV[2].f, "the same function set twice from the same scope: one wrapper")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function(g) CreateTimeEvent('x', 'c', 0, g) end"))
SendScriptCallback("actor_on_update", f)
check(TIMEEV[3].f ~= TIMEEV[1].f, "set from host code: its own wrapper (another scope)")
check(SCOPES[TIMEEV[3].f] == "host" and SCOPES[TIMEEV[1].f] == "?", "each wrapper keeps its own scope")

print("== route_scope_unique_call_keeps_the_latest_setter")
boot("host")
local uc = from_script("some_unknown_mod", "return function() RAN.uc = coop.route.scope() return false end")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function(g) AddUniqueCall(g) end"))
SendScriptCallback("actor_on_update", uc)
local uw = UNIQUE[#UNIQUE]
check(uw ~= uc and uw() == false, "the unique call is wrapped and runs")
check(RAN.uc == "host", "a unique call added by host code runs in host (got " .. tostring(RAN.uc) .. ")")
RemoveUniqueCall(uc)
AddUniqueCall(uc) -- added again, by no wrapper
check(UNIQUE[#UNIQUE] == uw, "one wrapper per function (a unique call is unique by its function)")
RAN.uc = nil
uw()
check(RAN.uc == "?", "added again by unknown code: the latest setter's scope (got " .. tostring(RAN.uc) .. ")")

print("== route_scope_host_error_leaves_nothing_stale")
boot("host")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function() error('broken host handler') end"))
local ok = pcall(SendScriptCallback, "actor_on_update")
check(not ok, "host: a handler's error still goes up (no pcall on the host: the stock behaviour)")
check(engine_scope() == nil, "host: after the error no scope is left: the scope is the stack, nothing to reset")

print("== route_scope_host_wrapper_stays_on_the_stack")
boot("host")
local multi = from_script("treasure_manager", "return function() RAN.depth_scope = coop.route.scope() return 1, nil, 3, nil end")
RegisterScriptCallback("actor_on_update", multi)
local hw = coop_route.wrapper_of("actor_on_update", multi)
check(type(hw) == "function", "host: the handler's wrapper")
local n = select("#", hw())
check(n == 4, "host: the wrapper hands back every value of the handler, nils included (got " .. tostring(n) .. ")")
check(RAN.depth_scope == "host", "host: while the handler runs its wrapper is on the stack (no tail call)")
local a, b, c3, d = hw()
check(a == 1 and b == nil and c3 == 3 and d == nil, "host: the values in order")

print("== route_scope_old_exe_without_the_scope_api")
boot("host", true)
check(coop_route.scope_now() == nil, "an exe without coop.route.scope: no scope (the gate sees unknown)")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function() RAN.ran = true end"))
CreateTimeEvent("x", "y", 0, from_script("death_manager", "return function() RAN.te = true end"))
SendScriptCallback("actor_on_update")
TIMEEV[#TIMEEV].f()
check(RAN.ran == true and RAN.te == true, "handlers and time events run as before")

print(string.format("%d passed, %d failed", PASSES, FAILS))
