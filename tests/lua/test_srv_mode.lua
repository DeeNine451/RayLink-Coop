-- The server layer of the facade coop_mode (scripts\coop_srv_mode.script, docs\MODES.md section 4, step S4): it answers
-- on a world server (from the start of a -coop_dedicated process, before its session too: A-S4D), a map server and a
-- player's machine of a split session, from the engine's predicates; any other process before its session: none; the world
-- server passes a player's request to the map server of his map, the map server takes it only from the world server;
-- when_srv functions run once it answers, never in the co-op. Real scripts over the coop.* stubs. Not shipped.
-- Run: tools\test_lua.cmd srv_mode
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
local C = coop_mods_core
local cm = coop_main

local BRIDGE = 0x101
local S = {} -- what the engine says
coop.is_active = function() return S.active end
coop.is_host = function() return S.host end
coop.is_client = function() return S.client end
coop.self_id = function() return S.self end
coop.players = function() return S.rows end
coop.is_map_server = function() return S.map_server end
coop.is_dedicated = function() return S.dedicated end
coop.levels = {
	split = function() return S.split end,
	bridge_of_player = function(peer) return S.bridges[peer] end,
}
local function engine(t)
	S = { active = true, host = false, client = false, self = 0, rows = {}, map_server = false, dedicated = false,
		split = false, bridges = {} }
	for k, v in pairs(t) do S[k] = v end
end

local REQ = "test.srv"
local handled, doors = {}, 0
F.on_level_request(REQ, function(payload, from, relayed)
	handled[#handled + 1] = { t = cm.decode(payload), from = from, relayed = relayed }
end, function() doors = doors + 1; return true end)
local MH = {}
C.on("srv_req", function(t, from) MH[#MH + 1] = { t = t, from = from } end, "host")
local function fire(t, from)
	handled, doors, MH, SENT = {}, 0, {}, {}
	cm.on_event(REQ, cm.encode(t), from)
	cm.on_event("mods.srv_req", cm.encode(t), from)
	local passed = {}
	for _, s in ipairs(SENT) do passed[#passed + 1] = { name = s.name, target = s.target, t = cm.decode(s.payload) } end
	return passed
end

print("== the layer goes to the facade through when_srv, and waits")
local SV = load_script("coop_srv_mode")
check(type(SV.LAYER) == "table" and SV.LAYER.name == "srv", "LAYER is the srv layer")
engine({ host = true, self = 0, rows = { { id = 0, is_self = true, avatar_id = 0 } } }) -- a co-op host
local early = 0
F.when_srv(function() early = early + 1 end)
LOG = {}
SV.on_game_start()
check(F.decides_world() == false and F.group_travels() == false, "in the co-op it does not answer (no co-op layer here: none)")
check(early == 0 and log_has("[srv] mode") == nil, "when_srv functions wait in the co-op")
modes.live(F)
check(F.group_travels() == true and early == 0, "with the co-op layer: the co-op answers, when_srv still waits")

print("== the world server without a player (-coop_dedicated)")
engine({ host = true, dedicated = true, split = true, self = 0, bridges = { [1] = BRIDGE },
	rows = { { id = 1, level = 2, elsewhere = true }, { id = 2 } } })
check(F.where(1) == "away" and F.where(2) == "joining" and F.where(0) == "away" and F.where(9) == "away",
	"a placed player away (no player's map here), a newcomer joining, its own seat and a stranger away")
check(early == 1 and log_has("[srv] mode: world server") ~= nil, "the first question runs the waiting when_srv functions")
check(F.decider(1) == "other" and F.decider(2) == "other" and F.decider(0) == "nobody" and F.decider(9) == "nobody",
	"the map servers decide for the players; nobody for its ghost and strangers")
check(not F.actor_is_player() and F.decides_world() and not F.leads_here(), "a ghost; it decides the world, leads no map")
check(not F.is_player_mirror() and not F.group_travels(), "no mirror; no group travel")
check(not F.seat_plays(0) and F.seat_plays(1) and F.seat_plays(2), "its own seat plays nobody, the players' do")
SENT = {}
check(F.publish("w.pub", { x = 1 }) and SENT[1].target == -1, "publish: to everybody (the engine adds the bridges)")
local passed = fire({ a = 5 }, 1)
check(#handled == 0 and #MH == 0 and doors == 1, "a request of a player on a map server's map does not run here; the door ran")
check(#passed == 2 and passed[1].name == REQ and passed[1].target == BRIDGE and passed[1].t._peer == 1 and passed[1].t.a == 5,
	"it goes to the map server of his map, with him in it")
check(passed[2].name == "mods.srv_req" and passed[2].target == BRIDGE and passed[2].t._peer == 1, "coop_mods_core.on host: the same")
passed = fire({ a = 6 }, 2)
check(#handled == 1 and handled[1].from == 2 and #MH == 1 and #passed == 0, "a player under no map server: here")
early = 0
F.where(1)
check(early == 0, "when_srv functions run once")
local now = 0
F.when_srv(function() now = now + 1 end)
check(now == 1, "a when_srv function given now runs at once")

print("== a map server")
engine({ client = true, map_server = true, split = true, self = 5, rows = {
	{ id = 5, is_self = true, level = 2 }, { id = 1, level = 2, elsewhere = false, avatar_id = 700 },
	{ id = 3, level = 4, elsewhere = true }, { id = 4 } } })
check(F.where(1) == "here" and F.where(3) == "away" and F.where(4) == "joining" and F.where(5) == "away" and F.where(0) == "away",
	"a player on its map here, on another away, unplaced joining; itself and the world server's seat away")
check(F.decider(1) == "this" and F.decider(3) == "other" and F.decider(5) == "nobody" and F.decider(0) == "nobody",
	"it decides for the players on its map")
check(not F.actor_is_player() and not F.decides_world() and F.leads_here(), "a ghost; the world is not its own; it leads its map")
check(not F.is_player_mirror() and not F.group_travels(), "no mirror, no group travel")
check(not F.seat_plays(5) and F.seat_plays(1) and not F.seat_plays(0), "its own seat and the world server's play nobody")
SENT = {}
check(F.publish("m.pub", { x = 1 }) and SENT[1].target == 0, "publish: to the world server")
SENT = {}
check(C.publish("m_pub", { x = 1 }) and SENT[1].name == "mods.m_pub" and SENT[1].target == 0, "coop_mods_core.publish: to the world server")
passed = fire({ a = 7, _peer = 1 }, 0)
check(#handled == 1 and handled[1].from == 1 and handled[1].relayed == true and handled[1].t._peer == nil and doors == 0,
	"from the world server: runs as his, without _peer, no second door")
check(#MH == 1 and MH[1].from == 1 and MH[1].t._peer == nil and MH[1].t.a == 7, "coop_mods_core.on host: the same")
passed = fire({ a = 8 }, 1)
check(#handled == 0 and #MH == 0 and doors == 0 and #passed == 0, "a player's own request: dropped")
passed = fire({ a = 8, _peer = 4 }, 1)
check(#handled == 0 and #MH == 0 and #passed == 0, "a player who writes another's peer in: dropped (only the world server passes)")
passed = fire({ a = 9 }, 0)
check(#handled == 0 and #MH == 0, "from the world server without a player: dropped")

print("== a player's machine in a split session")
engine({ client = true, split = true, self = 1, rows = {
	{ id = 1, is_self = true, level = 2, avatar_id = 0 }, { id = 2, level = 2, elsewhere = false }, { id = 3, level = 4, elsewhere = true } } })
check(F.where(1) == "here" and F.where(2) == "here" and F.where(3) == "away" and F.where(0) == "away",
	"me and a player on my map here, one on another map away, the world server's seat away")
check(F.decider(1) == "other" and F.decider(2) == "other" and F.decider(9) == "nobody", "this machine decides for nobody")
check(F.actor_is_player() and not F.decides_world() and not F.leads_here(), "it plays, decides and leads nothing")
check(F.is_player_mirror() and not F.group_travels(), "a mirror; no group travel")
check(not F.seat_plays(0) and F.seat_plays(2), "the world server's seat plays nobody")
SENT = {}
check(F.publish("c.pub", { x = 1 }) and SENT[1].target == -1, "publish: as to_all")
engine({ client = true, split = false, self = 1, rows = { { id = 1, is_self = true, avatar_id = 0 } } })
check(F.group_travels() == true, "before its first level map it is answered by the co-op layer (step S3: Welcome)")

print("== no session")
engine({ active = false })
check(F.where(1) == "away" and F.decider(1) == "nobody" and F.actor_is_player() and not F.decides_world(), "none")

-- A-S4D (lead's option (a)): a process started with -coop_dedicated loads its world first and starts its session after it
-- (HostAutostart). Before that the engine has no phase, so no role (is_host false), no seat (self_id -1) and no rows. Its
-- srv scripts register inside when_srv and must do it at load (coop_srv_dedicated writes [character_creation] before the
-- stock reads it; the save's load_state comes after on_game_start), so the server layer answers on is_dedicated alone,
-- with answers that do not depend on is_host. Every other process before its session: none, as before.
-- A new Lua state at a world start: the facade with no layer and nothing waiting, then the two layer scripts.
local function fresh()
	local f = load_script("coop_mode")
	return f, load_script("coop_srv_mode"), load_script("coop_hostplay_mode")
end
-- axr_main runs on_game_start by script name: coop_hostplay_mode, coop_mode, ..., coop_srv_mode
local function start(hp, sv)
	hp.on_game_start()
	sv.on_game_start()
end

print("== the world server's process before its session (-coop_dedicated): the server layer answers from the start")
for _, host in ipairs({ false, true }) do
	local tag = "is_host " .. tostring(host) .. ": "
	engine({ active = false, host = host, dedicated = true, self = -1 })
	local F2, SV2, HP2 = fresh()
	local ran = 0
	F2.when_srv(function() ran = ran + 1 end) -- a srv script named before coop_srv_mode (coop_srv_dedicated)
	check(ran == 0 and F2.decides_world() == false, tag .. "before the layer is installed: none, the function waits")
	LOG = {}
	start(HP2, SV2)
	check(ran == 1 and log_has("[srv] mode: world server") ~= nil, tag .. "the layer's own on_game_start runs it, at load")
	check(not F2.actor_is_player() and F2.decides_world() and not F2.leads_here(),
		tag .. "a ghost that decides the world and leads no map, before its session")
	check(not F2.is_player_mirror() and not F2.group_travels(), tag .. "no mirror, no group travel")
	check(F2.where(0) == "away" and F2.where(1) == "away" and F2.decider(0) == "nobody" and F2.decider(1) == "nobody"
		and not F2.seat_plays(0) and not F2.seat_plays(1), tag .. "no seat and no player yet: away, nobody, no seat plays")
	SENT = {}
	check(F2.publish("w.early", { x = 1 }) == false and #SENT == 0, tag .. "publish before the session: not sent (as none)")
	local now = 0
	F2.when_srv(function() now = now + 1 end)
	check(now == 1, tag .. "a when_srv function given after that runs at once")
	engine({ host = true, dedicated = true, split = true, self = 0, bridges = { [1] = BRIDGE },
		rows = { { id = 1, level = 2, elsewhere = true }, { id = 2 } } })
	check(F2.where(1) == "away" and F2.where(2) == "joining" and F2.where(0) == "away" and F2.decider(1) == "other"
		and F2.decider(0) == "nobody" and not F2.actor_is_player() and F2.decides_world() and not F2.leads_here()
		and not F2.is_player_mirror() and F2.seat_plays(1) and not F2.seat_plays(0),
		tag .. "its session starts: the answers of a world server in session")
	SENT = {}
	check(F2.publish("w.live", { x = 1 }) and SENT[1].target == -1, tag .. "publish in the session: to everybody")
	check(ran == 1 and now == 1, tag .. "nothing ran twice")
end

print("== the other processes before their session: none, as before")
for _, case in ipairs({
	{ "a co-op host", { active = false, self = -1 } },
	{ "a co-op host (roles already set)", { active = false, host = true, self = -1 } },
	{ "a player's machine", { active = false, client = true, self = -1 } },
	{ "a map server", { active = false, map_server = true, self = -1 } },
	{ "a split world's machine", { active = false, split = true, self = -1 } },
}) do
	local tag = case[1] .. ": "
	engine(case[2])
	local F2, SV2, HP2 = fresh()
	local ran = 0
	F2.when_srv(function() ran = ran + 1 end)
	LOG = {}
	start(HP2, SV2)
	check(ran == 0 and log_has("[srv] mode") == nil, tag .. "when_srv functions wait")
	check(F2.where(0) == "away" and F2.where(1) == "away" and F2.decider(0) == "nobody" and F2.decider(1) == "nobody"
		and not F2.seat_plays(0) and not F2.seat_plays(1), tag .. "away, nobody, no seat plays")
	check(F2.actor_is_player() and not F2.decides_world() and not F2.leads_here() and not F2.is_player_mirror()
		and not F2.group_travels(), tag .. "a player's actor; decides, leads, mirrors nothing; no group travel")
	SENT = {}
	check(F2.publish("x.early", { x = 1 }) == false and #SENT == 0, tag .. "publish: not sent")
end
engine({ active = false, self = -1 })
local F3, SV3, HP3 = fresh()
local waited = 0
F3.when_srv(function() waited = waited + 1 end)
start(HP3, SV3)
engine({ host = true, self = 0, rows = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 700 } } })
check(F3.group_travels() and F3.decides_world() and F3.leads_here() and F3.actor_is_player() and F3.where(1) == "here"
	and F3.decider(1) == "this" and waited == 0, "a co-op host's session starts: the co-op answers, when_srv never runs")

done("SRV_MODE")
