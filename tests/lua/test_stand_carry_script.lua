-- Stand probe coop_zz_carry.script (Co-op carry_group). b57j: the client started its steps when it saw two players, asked
-- the debug for the gun 25 ms before its own switch to live and 5 s before the server's debug state reached it, and the
-- answer was "debug_off": no gun, the scenario failed. The client starts only when it is live and the debug is on.
local path = "tools/stand/coop_zz_carry.script"
local passed, failed = 0, 0

local function check(ok, label)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. label)
	end
end

local function fixture(role)
	local f = { now = 0, live = false, debug_on = false, log = {}, callbacks = {}, stash = {}, asks = {} }
	local e = setmetatable({
		command_line = function() return "-coop_probe " .. role end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		time_global = function() return f.now end,
		get_console = function() return { execute = function() end } end,
		level = { name = function() return "l01_escape" end },
		db = { actor = { cast_Actor = function() return nil end } },
		coop = {
			is_active = function() return true end,
			is_live = function() return f.live end,
			players = function() return { {}, {} } end,
			world_epoch = function() return 0 end,
			stash_get = function(k) return f.stash[k] end,
			stash_set = function(k, v) f.stash[k] = v end,
			debug = { state = function() return { on = f.debug_on, source = f.debug_on and "key" or "off" } end },
		},
		coop_debug_client = { run = function(id, ctx)
			f.asks[#f.asks + 1] = ctx.sec
			return true, f.debug_on and nil or "debug_off"
		end },
	}, { __index = _G })
	setfenv(assert(loadfile(path)), e)()
	e.on_game_start()
	function f.tick(ms)
		f.now = f.now + (ms or 500)
		f.callbacks.actor_on_update()
	end
	function f.has(fragment)
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then return true end
		end
		return false
	end
	return f
end

local client = fixture("ag")
check(client.callbacks.actor_on_update ~= nil, "the client role is armed")
for _ = 1, 30 do client.tick() end
check(not client.has("the steps start") and #client.asks == 0, "two players but not live yet: no steps, no debug asks")
client.live = true
for _ = 1, 30 do client.tick() end
check(not client.has("the steps start") and #client.asks == 0, "live, the server's debug state not here yet: still waiting")
client.debug_on = true
client.tick()
check(client.has("ag two players: the steps start"), "live with the debug on: the steps start")

local host = fixture("h")
host.tick()
check(host.has("h two players: the steps start"), "the host runs the debug itself: it starts as before")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
