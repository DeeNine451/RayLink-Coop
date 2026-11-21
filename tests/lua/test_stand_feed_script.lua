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
local OTHER_EXIT_ID = 4243 -- a second exit, used only where a test places one

local function fixture(role)
	local f = {
		map = "l01_escape", now = 0, live = true, mirror = true, log = {}, commands = {}, callbacks = {}, stash = {},
		step = "go", -- feed_server.ps1's zz_feed_step.txt (nil: not written yet)
		others = {}, where = {}, pos = vec(0, 0, 0), exit = vec(50, 0, 0), moved_to = {}, levels = {}, trips = {},
		starts = { { id = "rookie_village", image = "l01_escape", x = 0, y = 0, z = 0 },
			{ id = "hidden_base", image = "k00_marsh", x = 0, y = 0, z = 0 } },
	}
	local actor = {
		health = 1,
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
				local at = (id == EXIT_ID and not f.no_exit and f.exit) or (id == OTHER_EXIT_ID and f.other_exit)
				if at then
					return { clsid = function() return 1 end, position = function() return at end }
				end
			end,
			vertex_id = function(p) f.probe_at = p; return 7 end,
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
				level_name = function(id) return ({ [1] = "k00_marsh", [2] = "l01_escape", [3] = "l02_garbage" })[id] end,
			},
		},
		coop_menu_char = { faction_starts = function(faction, story)
			f.starts_asked = { faction, story }
			return f.starts
		end },
		JumpToLevel = function(map)
			f.trips[#f.trips + 1] = map
			return not f.reject
		end,
		coop_mode = {
			where = function(id) return f.where[id] or "away" end,
			is_player_mirror = function() return f.mirror end,
		},
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		getFS = function()
			return { update_path = function(_, root, name) f.step_root = root; return "stand/" .. name end }
		end,
		io = { open = function(p, mode)
			if p ~= "stand/zz_feed_step.txt" or mode ~= "r" or f.step == nil then return nil end
			return { read = function() return f.step end, close = function() end }
		end },
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
local lines = #first.log - first.count("[feed] pulse:")
first.tick(30000)
check(#first.log - first.count("[feed] pulse:") == lines, "first is done after his arrival")

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

-- b57b feed_server: a Server world starts each new character at any start of its faction (stalker: three maps). The first
-- joined on k00_marsh, the second on l01_escape; the second took the first's absence for a departure and left first.
-- Now a first apart goes once to the second's map (the stock debug trip) and waits there; the second stays.
local apart = fixture("feedfirst")
apart.map = "k00_marsh"
apart.start()
apart.others = { { id = 3, nick = "feedsecond", is_self = false } }
apart.where[3] = "joining"
apart.tick()
check(#apart.trips == 0 and #apart.log == 0, "the first waits while the second is not placed")
apart.where[3], apart.levels[3] = "away", 2
apart.tick()
check(#apart.trips == 1 and apart.trips[1] == "l01_escape" and apart.stash["stand.feed_gather"] == "l01_escape"
	and apart.has("[feed] first joins the second on l01_escape (start k00_marsh)"), "a first apart goes to the second's map")
apart.tick(30000)
check(#apart.trips == 1 and not apart.has("preparing exit") and apart.stash["stand.feed_from"] == nil,
	"one setup trip, no exit of his own while it is under way")
-- After the trip (a fresh Lua state on the second's map, put where the stock debug trip puts him): he takes the exit
-- nearest to the second's start, not to where he stands.
local joined = fixture("feedfirst")
joined.stash["stand.feed_gather"] = "l01_escape"
joined.pos, joined.exit, joined.other_exit = vec(200, 0, 0), vec(50, 0, 0), vec(190, 0, 0)
joined.starts[1].x = 10 -- rookie_village: 40 m from the first exit, 180 m from the second
joined.start()
joined.others = { { id = 3, nick = "feedsecond", is_self = false } }
joined.where[3] = "here"
joined.tick()
check(#joined.trips == 0 and joined.has("[feed] feedfirst preparing exit from l01_escape")
	and joined.stash["stand.feed_from"] == "l01_escape", "after the setup trip the first leaves the second's map")
check(joined.starts_asked and joined.starts_asked[1] == "stalker" and joined.pos:distance_to(joined.exit) <= 24
	and joined.pos:distance_to(joined.other_exit) > 100, "he takes the exit nearest to the second's start")
-- Same map from the start: no trip and the exit nearest to where he stands, as before.
local common = fixture("feedfirst")
common.other_exit = vec(-40, 0, 0)
common.start()
common.others = { { id = 3, nick = "feedsecond", is_self = false } }
common.where[3] = "here"
common.tick()
check(#common.trips == 0 and common.starts_asked == nil and common.pos:distance_to(common.other_exit) <= 24,
	"a first on the second's map takes his own nearest exit")
-- A setup trip after which the second is not on his map fails once.
local stuck = fixture("feedfirst")
stuck.stash["stand.feed_gather"] = "l01_escape"
stuck.start()
stuck.others = { { id = 3, nick = "feedsecond", is_self = false } }
stuck.levels[3] = 3
stuck.tick()
check(#stuck.log == 0, "the second may still come into view after the setup trip")
stuck.tick(61000)
stuck.tick(5000)
check(stuck.count("[feed] FAIL: the first did not join the second") == 1 and #stuck.trips == 0,
	"no second on his map after the setup trip fails once")
-- No start of the faction on the map of the setup trip: said once.
local nostart = fixture("feedfirst")
nostart.stash["stand.feed_gather"] = "l05_bar"
nostart.map = "l05_bar"
nostart.start()
nostart.others = { { id = 3, nick = "feedsecond", is_self = false } }
nostart.where[3] = "here"
nostart.tick()
nostart.tick(20000)
check(nostart.count("[feed] FAIL: the first found no stalker start on l05_bar") == 1 and not nostart.has("preparing exit"),
	"a map without the faction's start fails once")
-- A refused trip request fails once.
local refused = fixture("feedfirst")
refused.map, refused.reject = "k00_marsh", true
refused.start()
refused.others = { { id = 3, nick = "feedsecond", is_self = false } }
refused.where[3], refused.levels[3] = "away", 2
refused.tick()
refused.tick(5000)
check(refused.count("[feed] FAIL: the first could not request l01_escape") == 1 and #refused.trips == 1, "a refused setup trip fails once")
-- The second never travels to the first: he stays live on his start until the first left his map.
local stays = fixture("feedsecond")
stays.start()
stays.others = { { id = 2, nick = "feedfirst", is_self = false } }
stays.where[2], stays.levels[2] = "away", 1
stays.tick()
stays.where[2] = "here" -- the first's setup trip: the world puts him on this map
stays.tick(30000)
check(#stays.trips == 0 and #stays.log == 0, "the second waits while the first comes")
stays.where[2], stays.levels[2] = "away", 3
stays.tick()
stays.tick(21000)
check(#stays.trips == 0 and stays.has("[feed] feedsecond preparing exit from l01_escape"), "the second follows after the first left")

-- b57f-b57i feed_server: the world placed the second's character on the start map ("here") while his machine still loaded; the
-- first left then, the second's feed first saw him on the other map and no "went to" came (the scenario timed out, or in b57i
-- stood 6 minutes in a bandit camp). The first goes only on the scenario's word, written once the second's log says live.
local early = fixture("feedfirst")
early.step = nil
early.start()
early.others = { { id = 3, nick = "feedsecond", is_self = false } }
early.where[3] = "here"
early.tick()
early.tick(20000)
check(not early.has("preparing exit") and early.stash["stand.feed_from"] == nil and #early.moved_to == 0,
	"the first waits for the scenario's go while the second is only placed on his map")
check(early.step_root == "$fs_root$", "the go is read at the stand's root")
early.step = "wait"
early.tick()
check(not early.has("preparing exit"), "only the word go releases him")
early.step = "go"
early.tick()
check(early.has("[feed] feedfirst preparing exit from l01_escape"), "the first goes on the scenario's go")
-- The second needs no word: he follows the first's departure.
local follower = fixture("feedsecond")
follower.step = nil
follower.start()
follower.others = { { id = 2, nick = "feedfirst", is_self = false } }
follower.where[2] = "away"
follower.tick()
follower.tick(21000)
check(follower.has("[feed] feedsecond preparing exit from l01_escape"), "the second goes without the scenario's word")

-- b57i: after his arrival a player only waits (one of the two ended there in a heap corruption; both logs lost their last
-- unflushed 4 KB). A flushed pulse every 5 s keeps the log current; nothing else moves.
local idle = fixture("feedfirst")
idle.stash["stand.feed_from"] = "l05_bar"
idle.start()
idle.tick()
check(idle.has("[feed] first arrived l05_bar -> l01_escape") and idle.count("[feed] pulse:") == 0, "the arrival, no pulse yet")
idle.tick(250)
check(idle.count("[feed] pulse:") == 1 and idle.has("[feed] pulse: feedfirst on l01_escape, health 1.000")
	and idle.commands[#idle.commands] == "flush", "a flushed pulse right after the arrival")
idle.tick(4000)
check(idle.count("[feed] pulse:") == 1, "no second pulse within 5 s")
idle.tick(1000)
check(idle.count("[feed] pulse:") == 2 and idle.commands[#idle.commands] == "flush", "the next pulse 5 s later, flushed")
idle.live = false
idle.tick(10000)
check(idle.count("[feed] pulse:") == 2, "no pulse while not live")
check(#idle.moved_to == 0 and not idle.has("preparing exit"), "a pulse moves nobody")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
