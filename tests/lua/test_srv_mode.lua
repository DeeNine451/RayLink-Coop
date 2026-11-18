-- The server layer of the facade coop_mode (scripts\coop_srv_mode.script, docs\MODES.md section 4, step S4): it answers
-- on a world server, a map server and a player's machine of a split session, from the engine's predicates; the world
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

done("SRV_MODE")
