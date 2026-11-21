-- Dev 57 SS. The mover of allymark_server.ps1 (coop_zz_allymark.script) in a process-shaped Lua scope: when he looks for his
-- level exit and when he gives up. A client of a map server goes live before that server's online set (its level changers)
-- reaches it (join::server_player_in_world -> entities::host_send_online_to); the stand b57h mover looked once, on his
-- first live update in the Bar, and failed. The PDA spot itself is the engine's (test_srv_allies_map.lua).
local path = "tools/stand/coop_zz_allymark.script"
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
local OBSERVER_ID = 3

local function fixture(role)
	local f = {
		map = "l05_bar", now = 0, live = true, mirror = true, log = {}, commands = {}, callbacks = {}, stash = {},
		others = {}, where = {}, pos = vec(0, 0, 0), exit = vec(50, 0, 0), moved_to = {}, levels = {}, trips = {},
		no_exit = false, no_ground = false,
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
			vertex_id = function(p)
				f.probe_at = p
				return f.no_ground and 0xffffffff or 7
			end,
			vertex_position = function() return vec(f.probe_at.x, f.probe_at.y, f.probe_at.z) end,
		},
		db = { actor = actor },
		coop = {
			is_live = function() return f.live end,
			players = function() return f.others end,
			stash_get = function(k) return f.stash[k] end,
			stash_set = function(k, v) f.stash[k] = v; return true end,
			levels = {
				level_of_player = function(id) return f.levels[id] end,
				level_name = function(id) return ({ [1] = "k00_marsh", [2] = "l05_bar" })[id] end,
			},
		},
		JumpToLevel = function(map)
			f.trips[#f.trips + 1] = map
			return true
		end,
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
	function f.count(fragment)
		local n = 0
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then n = n + 1 end
		end
		return n
	end
	function f.has(fragment) return f.count(fragment) > 0 end
	-- the observer stands on the mover's map: the Duty world's one start, the Bar
	function f.together()
		f.others = { { id = OBSERVER_ID, nick = "allyobserver", is_self = false }, { id = 2, nick = "allymover", is_self = true } }
		f.where[OBSERVER_ID] = "here"
	end
	-- every tick of `ms` in steps of 500 ms (the probe polls every 250 ms)
	function f.run(ms)
		for _ = 1, math.floor(ms / 500) do f.tick(500) end
	end
	return f
end

-- Only the mover moves; other roles of other probes register nothing.
for _, role in ipairs({ "feedfirst", "s7move" }) do
	local f = fixture(role)
	f.start()
	check(next(f.callbacks) == nil, "other probe role " .. tostring(role))
end

-- The exit is there on the first live update: he prepares it at once (Co-op, or a map server that was quick).
local quick = fixture("allymover")
quick.start()
check(quick.callbacks.actor_on_update ~= nil, "mover registers its update")
quick.tick()
check(#quick.log == 0, "mover waits for the observer")
quick.together()
quick.tick()
check(quick.has("[allymark] mover preparing exit from l05_bar"), "mover prepares the exit he finds at once")
check(quick.stash["stand.allymark_from"] == "l05_bar", "mover keeps the map he leaves")
check(#quick.moved_to == 1 and quick.pos:distance_to(quick.exit) >= 8, "mover stands beside the exit")
quick.tick(10500)
check(#quick.moved_to == 2 and quick.pos:distance_to(quick.exit) < 1, "mover steps into the exit after 10 s")
quick.tick(2500)
check(quick.commands[#quick.commands] == "coop_transition_confirm", "mover confirms the transition")

-- b57h: live in the Bar before the map server's online set: no level changer yet. He waits for it, then takes it.
local early = fixture("allymover")
early.start()
early.together()
early.no_exit = true
early.tick()
check(not early.has("FAIL"), "no level changer on the first live update is not a failure yet")
check(#early.moved_to == 0 and early.stash["stand.allymark_from"] == nil, "mover does nothing before his exit is online")
early.run(30000)
check(not early.has("FAIL") and not early.has("preparing"), "mover still waits 30 s on")
early.no_exit = false -- the online set arrives
early.tick()
check(early.has("[allymark] mover preparing exit from l05_bar"), "mover prepares the exit once it is online")
check(early.stash["stand.allymark_from"] == "l05_bar", "mover keeps the map he leaves after the wait")
check(not early.has("FAIL"), "no failure after a late online set")

-- The online set never brings a level changer: one FAIL after the wait, which says why, and nothing more.
local never = fixture("allymover")
never.start()
never.together()
never.no_exit = true
never.tick()
never.run(44000)
check(not never.has("FAIL"), "mover waits up to 45 s for a level changer")
never.run(2000)
check(never.count("[allymark] FAIL: mover could not prepare a level exit from l05_bar (no level changer online)") == 1,
	"mover fails once the wait is over, naming the missing level changer")
never.run(5000)
check(never.count("FAIL") == 1 and #never.moved_to == 0, "the failure is final")
check(never.stash["stand.allymark_from"] == nil, "a failed mover keeps no start map")

-- A level changer without AI ground beside it: the same wait, then a failure that says so.
local bare = fixture("allymover")
bare.start()
bare.together()
bare.no_ground = true
bare.tick()
bare.run(44000)
check(not bare.has("FAIL"), "mover waits for ground beside the exit too")
bare.run(2000)
check(bare.count("FAIL: mover could not prepare a level exit from l05_bar (no AI ground beside the nearest level changer)") == 1,
	"mover fails naming the missing ground")

-- Not live, or not a player mirror: nothing runs, and the wait does not start.
local idle = fixture("allymover")
idle.start()
idle.together()
idle.no_exit = true
idle.live = false
idle.run(60000)
check(#idle.log == 0, "nothing while not live")
idle.live = true
idle.tick()
check(not idle.has("FAIL"), "the wait starts on the first live update, not before")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
