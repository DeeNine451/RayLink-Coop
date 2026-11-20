-- Dev 57 A-S6J (S5 feed lines). The stand probe of feed_server.ps1 (coop_zz_feed.script) in process-shaped Lua scopes: who moves,
-- when, and what it prints. The feed lines themselves are the engine's (srv/coop_srv_join.cpp; native tests/test_srv_join_feed.cpp).
local path = "temp/stand/coop_zz_feed.script"
local tracked = io.open("tools/stand/coop_zz_feed.script", "r")
if tracked then
	tracked:close()
	path = "tools/stand/coop_zz_feed.script"
end
local passed, failed = 0, 0

local function check(ok, label)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. label)
	end
end

local function vec(x, y, z)
	local v = { x = x or 0, y = y or 0, z = z or 0 }
	function v:set(a, b, c) self.x, self.y, self.z = a, b, c; return self end
	function v:distance_to(o)
		local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	return v
end

local EXIT_ID = 4242

local function fixture(role)
	local f = {
		map = "l01_escape", now = 0, live = true, mirror = true, log = {}, commands = {}, callbacks = {}, stash = {},
		others = {}, where = {}, pos = vec(0, 0, 0), exit = vec(50, 0, 0), moved_to = {},
	}
	local actor = {
		position = function() return f.pos end,
		set_actor_position = function(_, p) f.pos = vec(p.x, p.y, p.z); f.moved_to[#f.moved_to + 1] = p end,
	}
	local e = setmetatable({
		command_line = function() return role and "-coop_probe " .. role or "" end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		time_global = function() return f.now end,
		clsid = { level_changer = 1, level_changer_s = 2 },
		vector = function() return vec() end,
		level = {
			name = function() return f.map end,
			object_by_id = function(id)
				if id == EXIT_ID and not f.no_exit then
					return { clsid = function() return 1 end, position = function() return f.exit end }
				end
			end,
			vertex_id = function() return 7 end,
			vertex_position = function() return vec(f.exit.x + 12, f.exit.y, f.exit.z) end,
		},
		db = { actor = actor },
		coop = {
			is_live = function() return f.live end,
			players = function() return f.others end,
			stash_get = function(k) return f.stash[k] end,
			stash_set = function(k, v) f.stash[k] = v; return true end,
		},
		coop_mode = {
			where = function(id) return f.where[id] or "away" end,
			is_player_mirror = function() return f.mirror end,
		},
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		get_console = function() return { execute = function(_, cmd) f.commands[#f.commands + 1] = cmd end } end,
	}, { __index = _G })
	setfenv(assert(loadfile(path)), e)()
	function f.start() e.on_game_start() end
	function f.tick(ms)
		f.now = f.now + (ms or 500)
		if f.callbacks.actor_on_update then f.callbacks.actor_on_update() end
	end
	function f.has(fragment)
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then return true end
		end
		return false
	end
	function f.count(fragment)
		local n = 0
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then n = n + 1 end
		end
		return n
	end
	return f
end

-- Only its two roles run.
for _, role in ipairs({ "feedx", "allymover", "s7move" }) do
	local f = fixture(role)
	f.start()
	check(next(f.callbacks) == nil, "other probe role " .. tostring(role))
end
local none = fixture(nil)
none.start()
check(next(none.callbacks) == nil, "no role")

-- The first: nothing before the second stands on his map, then the nearest exit, then into it.
local first = fixture("feedfirst")
first.start()
check(first.callbacks.actor_on_update ~= nil, "first registers its update")
first.tick()
check(#first.log == 0, "first waits for the second")
first.others = { { id = 3, nick = "feedsecond", is_self = false }, { id = 2, nick = "feedfirst", is_self = true } }
first.where[3] = "away"
first.tick()
check(#first.log == 0, "first waits until the second is on his map")
first.live = false
first.where[3] = "here"
first.tick()
check(#first.log == 0, "first does nothing while not live")
first.live = true
first.tick()
check(first.has("[feed] feedfirst preparing exit from l01_escape"), "first prepares the nearest exit")
check(first.stash["stand.feed_from"] == "l01_escape", "first keeps the map he leaves")
check(#first.moved_to == 1 and first.pos:distance_to(first.exit) >= 8, "first stands beside the exit")
first.tick(5000)
check(#first.moved_to == 1, "first waits beside the exit")
first.tick(6000)
check(#first.moved_to == 2 and first.pos:distance_to(first.exit) < 1, "first steps into the exit")
first.tick(2500)
check(first.commands[#first.commands] == "coop_transition_confirm", "first confirms")
first.map = "l02_garbage"
first.tick()
check(first.has("[feed] first arrived l01_escape -> l02_garbage"), "first arrives")
local lines = #first.log
first.tick(30000)
check(#first.log == lines, "first is done after his arrival")

-- The second: he goes only FOLLOW_MS after the first left his map, through the nearest exit.
local second = fixture("feedsecond")
second.start()
second.others = { { id = 2, nick = "feedfirst", is_self = false } }
second.where[2] = "here"
second.tick()
check(#second.log == 0, "second waits while the first is on his map")
second.where[2] = "away"
second.tick()
check(#second.log == 0, "second does not go at once")
second.tick(10000)
check(#second.log == 0, "second waits the follow time")
second.where[2] = "here" -- the first came back: the clock starts again
second.tick()
second.where[2] = "away"
second.tick() -- the clock starts here
second.tick(15000)
check(#second.log == 0, "the follow time counts from the last departure")
second.tick(6000)
check(second.has("[feed] feedsecond preparing exit from l01_escape"), "second follows")
second.tick(11000)
second.tick(2500)
second.map = "l02_garbage"
second.tick()
check(second.has("[feed] second arrived l01_escape -> l02_garbage"), "second arrives")

-- No exit on the map: the probe says so and stops.
local lost = fixture("feedfirst")
lost.no_exit = true
lost.start()
lost.others = { { id = 3, nick = "feedsecond", is_self = false } }
lost.where[3] = "here"
lost.tick()
check(lost.has("[feed] FAIL: feedfirst could not prepare a level exit from l01_escape"), "no exit is a failure")
lost.tick(20000)
check(lost.count("FAIL") == 1, "it says it once")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
