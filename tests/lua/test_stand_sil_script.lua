-- Stand probe coop_zz_sil.script (Co-op sil_group). It waited for the client's switch to live, then asked the debug for the
-- gun 6 s later; the server's debug state reaches a client at the end of its join, 4.7 s after live in b57j carry_group
-- (the carry probe asked before it and got "debug_off"). The client starts only once the server's debug is on here too.
local path = "tools/stand/coop_zz_sil.script"
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
	local f = { now = 0, live = false, debug_on = false, log = {}, callbacks = {}, asks = {} }
	local e = setmetatable({
		command_line = function() return "-coop_probe " .. role end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		time_global = function() return f.now end,
		get_console = function() return { execute = function() end } end,
		level = { name = function() return "l01_escape" end, object_by_id = function() return nil end },
		alife_object = function() return nil end,
		db = { actor = { object = function() return nil end } },
		coop = {
			is_active = function() return true end,
			is_live = function() return f.live end,
			players = function() return { {}, {} } end,
			debug = { state = function() return { on = f.debug_on, source = f.debug_on and "key" or "off" } end },
		},
		coop_mods_core = { live_client = function() return f.live end },
		coop_debug_client = { run = function(id, ctx)
			f.asks[#f.asks + 1] = ctx.sec
			return true, f.debug_on and nil or "debug_off"
		end },
	}, { __index = _G })
	setfenv(assert(loadfile(path)), e)()
	e.on_game_start()
	function f.tick(ms)
		f.now = f.now + (ms or 500)
		for name, fn in pairs(f.callbacks) do if name == "actor_on_update" then fn() end end
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
client.live = true
for _ = 1, 30 do client.tick() end -- 15 s live, the debug state not here
check(not client.has("the steps start") and #client.asks == 0, "live, the server's debug state not here yet: no steps, no asks")
client.debug_on = true
client.tick()
check(client.has("the steps start"), "live with the debug on: the steps start")
for _ = 1, 14 do client.tick() end
check(client.asks[1] == "wpn_vihr", "and the gun is asked of a debug that is on")

local host = fixture("h")
host.tick()
check(host.has("h two players, live: the steps start"), "the host runs the debug itself: it starts as before")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
