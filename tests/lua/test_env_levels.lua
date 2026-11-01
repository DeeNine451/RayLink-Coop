-- Anomaly Coop (split levels, docs\SPLIT_LEVELS.md 7b): the emission and the psi storm on every level at once. One schedule on the
-- world server; the phase goes to every map server and every client; a map server is the authority of its level, so the consequences
-- run there for real: the wave, the NPCs, the verdict on a player without a shelter. A process on a level the emission does not reach
-- (under ground) plays nothing, and a host down there does not stop the world's emission.
-- Real coop_main.script; the stock managers are stand-ins of the calls that matter.
-- Not shipped. Run: tools\test_lua.cmd env_levels
MODE = "host"
dofile("tests/lua/support/stubs.lua")

OPTS = { ["alife/event/emission_fate"] = "kill_at_wave", ["alife/event/psi_storm_fate"] = "kill_at_vortex" }
ui_options = { get = function(name) return OPTS[name] end }
vector = function()
	return { set = function(self, x, y, z) self.x, self.y, self.z = x, y, z; return self end }
end

local LEVEL_NAME = "l01_escape"
level.name = function() return LEVEL_NAME end
level_weathers = { valid_levels = { l01_escape = true, l02_garbage = true, l13_generators = true } }

-- two players elsewhere: 1 on the host's level, 2 on the Garbage of map server 1
local SERVERS = { { bridge = 0x101, level = 2 } }
coop.is_map_server = function() return MODE == "mapserver" end
coop.is_mirror = function() return MODE == "client" end
coop.levels = {
	split = function() return true end,
	map_servers = function() return SERVERS end,
	on_host_level = function(peer) return peer ~= 2 end,
	bridge_of_player = function(peer) return peer == 2 and 0x101 or nil end,
	level_of_player = function(peer) return peer == 2 and 2 or 1 end,
	level_name = function(id) return ({ "l01_escape", "l02_garbage", "l03u_agr_underground" })[id] end,
}
local LIST = {
	{ id = 0, nick = "host", is_self = true, avatar_id = 0 },
	{ id = 1, nick = "near", is_self = false, avatar_id = 500 },
	{ id = 2, nick = "far", is_self = false, avatar_id = 501 },
}
coop.players = function() return LIST end
SENT = {}
coop.send_event = function(name, payload, target)
	SENT[#SENT + 1] = { name = name, t = coop_main.decode(payload), to = target }
	return true
end
local function sent(name, to)
	for i = #SENT, 1, -1 do
		if SENT[i].name == name and SENT[i].to == to then return SENT[i].t end
	end
end

OBJECTS = { [500] = { position = function() return { x = 0, y = 0, z = 0, cover = false } end, alive = function() return true end } }
level.object_by_id = function(id) return OBJECTS[id] end

print("== env_levels")
load_coop_main()
coop_main.on_game_start()
local sm = surge_manager.get_surge_manager()
local pm = psi_storm_manager.get_psi_storm_manager()
local function tick()
	NOW = NOW + 2000
	SendScriptCallback("actor_on_update")
end

-- 1. the phase goes to every player and every map server
sm.started = true
sm.inited_time = game.get_game_time()
tick()
local near, far, ms = sent("coop_env", 1), sent("coop_env", 2), sent("coop_env", 0x101)
check(near and near.s == true, "a player on the host's level gets the phase")
check(far and far.s == true, "a player on a map server's level gets the phase from the world server")
check(ms and ms.s == true and ms.c == true, "the map server gets the phase, its ghost in a shelter")
check(far and far.own == true and not (near and near.own), "who is on another level judges his shelter on his machine")
check(near and near.c == false, "on the host's level the host's verdict stands")
check(sent("coop_env_kill", 2) == nil, "the world server sends no kill for a character it has no object of")

-- 2. what a client of a map server's level reports goes to its map server
coop_main.on_event("coop_env_cover", coop_main.encode({ c = true }), 2)
local cover = sent("coop_env_cover", 0x101)
check(cover and cover.c == true and cover.peer == 2, "his shelter goes on to the map server of his level")
coop_main.on_event("coop_env_npc_kill", coop_main.encode({ k = "s", z = 5 }), 2)
local wave = sent("coop_env_npc_kill", 0x101)
check(wave and wave.k == "s" and wave.z == 5 and wave.peer == 2, "his wave goes on to the map server of his level")
sm.started = false
tick()

-- 3. the schedule: a host under ground does not stop the world's emission
STARTS = {}
local levels_seen = {}
function CSurge:start() levels_seen[#levels_seen + 1] = level.name(); self.started = true end
function CPsi:start() levels_seen[#levels_seen + 1] = level.name() end
coop_main.install_env_schedule()
LEVEL_NAME = "l03u_agr_underground"
sm:start()
check(levels_seen[1] == "l01_escape", "the stock's level check sees a level a player stands on")
check(level.name() == "l03u_agr_underground", "and the host's level is his own again")
LIST[2].id = 3
LIST[3].id = 4
coop.levels.level_of_player = function() return 3 end
sm.started = false
sm:start()
check(levels_seen[2] == "l03u_agr_underground", "everybody under ground: the stock skips it")
coop.levels.level_of_player = function(peer) return peer == 4 and 2 or 3 end
pm:start()
check(levels_seen[3] == "l02_garbage", "the psi storm's schedule is the same")
LIST[2].id, LIST[3].id = 1, 2
coop.levels.level_of_player = function(peer) return peer == 2 and 2 or 1 end

-- 4. a host under ground keeps the clock, not the effects
local updates, ends = 0, 0
function CSurge:update() updates = updates + 1 end
function CSurge:end_surge() ends = ends + 1; self:kill_all_unhided(); self.started = false end
ORIG_KILL_ALL = 0
coop_main.install_env_schedule()
sm.started = true
sm.surge_time = 222
sm.inited_time = game.get_game_time()
sm:update()
check(updates == 0, "under ground the host plays nothing of an emission that runs elsewhere")
check(sm.started == true, "and it goes on")
GAME_SECONDS = (GAME_SECONDS or 0)
sm.surge_time = -1
sm:update()
check(ends == 1, "its clock still ends it")
check(ORIG_KILL_ALL == 0, "and the end kills nobody down here")
LEVEL_NAME = "l01_escape"

print(string.format("%d passed, %d failed", PASSES, FAILS))
