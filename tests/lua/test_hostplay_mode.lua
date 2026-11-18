-- The co-op layer of the facade coop_mode (scripts\coop_hostplay_mode.script, docs\MODES.md section 4, step S4):
-- it answers in a co-op session only (not a map server, not a world server without a player, not split into maps),
-- from the engine's predicates; the host decides and leads the one map, a client mirrors it. Real scripts over the
-- coop.* stubs. Not shipped. Run: tools\test_lua.cmd hostplay_mode
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
local C = coop_mods_core
local cm = coop_main

local S = {} -- what the engine says
coop.is_active = function() return S.active end
coop.is_host = function() return S.host end
coop.is_client = function() return S.client end
coop.self_id = function() return S.self end
coop.players = function() return S.rows end
coop.is_map_server = function() return S.map_server end
coop.is_dedicated = function() return S.dedicated end
coop.levels = { split = function() return S.split end }
local function engine(t)
	S = { active = true, host = false, client = false, self = 0, rows = {}, map_server = false, dedicated = false, split = false }
	for k, v in pairs(t) do S[k] = v end
end

-- one request through the facade and one through coop_mods_core, from `from`
local REQ = "test.hp"
local handled, doors = {}, 0
F.on_level_request(REQ, function(payload, from, relayed) handled[#handled + 1] = { from = from, relayed = relayed } end,
	function() doors = doors + 1; return true end)
local MH = {}
C.on("hp_req", function(t, from) MH[#MH + 1] = { t = t, from = from } end, "host")
local function fire(from)
	handled, doors, MH, SENT = {}, 0, {}, {}
	cm.on_event(REQ, cm.encode({ a = 1 }), from)
	cm.on_event("mods.hp_req", cm.encode({ a = 1 }), from)
end

print("== the layer installs itself")
local HP = load_script("coop_hostplay_mode")
check(type(HP.LAYER) == "table" and HP.LAYER.name == "hostplay", "LAYER is the hostplay layer")
engine({ host = true, rows = { { id = 0, is_self = true, avatar_id = 0 } } })
check(F.decides_world() == false, "before its on_game_start the facade answers none")
HP.on_game_start()
check(F.decides_world() == true, "on_game_start installs it")

print("== the co-op host")
engine({ host = true, self = 0, rows = {
	{ id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 }, { id = 2 } } })
check(F.where(0) == "here" and F.where(1) == "here", "the host and a player in the world: here")
check(F.where(2) == "joining", "a player without his character yet: joining")
check(F.where(5) == "away", "not in the session: away")
check(F.decider(0) == "this" and F.decider(1) == "this" and F.decider(2) == "this" and F.decider(5) == "nobody",
	"the host decides for every player, for nobody else")
check(F.actor_is_player() and F.decides_world() and F.leads_here(), "it plays, decides the world, leads the map")
check(not F.is_player_mirror() and F.group_travels(), "no mirror; the group travels together")
check(F.seat_plays(0) and F.seat_plays(1) and F.seat_plays(2) and not F.seat_plays(5), "every seat in the list plays")
SENT = {}
check(F.publish("hp.pub", { x = 1 }) == true and SENT[1].target == -1, "publish: to everybody")
SENT = {}
check(C.publish("hp_pub", { x = 1 }) == true and SENT[1].name == "mods.hp_pub" and SENT[1].target == -1,
	"coop_mods_core.publish: to everybody")
fire(1)
check(#handled == 1 and handled[1].from == 1 and handled[1].relayed == false and doors == 1, "a request runs here, through the door")
check(#MH == 1 and MH[1].from == 1 and #SENT == 0, "coop_mods_core.on host: here, nothing passed on")

print("== a co-op client")
engine({ client = true, self = 1, rows = {
	{ id = 0, avatar_id = 500 }, { id = 1, is_self = true, avatar_id = 0 }, { id = 2 } } })
check(F.where(1) == "here" and F.where(0) == "here" and F.where(2) == "joining" and F.where(7) == "away",
	"me and the host here, the newcomer joining, a stranger away")
check(F.decider(0) == "other" and F.decider(1) == "other" and F.decider(7) == "nobody", "the host decides, not this machine")
check(F.actor_is_player() and not F.decides_world() and not F.leads_here(), "it plays, decides and leads nothing")
check(F.is_player_mirror() and F.group_travels(), "a mirror; the group travels together")
check(F.seat_plays(0) and F.seat_plays(1), "the host's seat plays (its row is listed)")
engine({ client = true, self = 1, rows = { { id = 1, is_self = true, avatar_id = 0 } } })
check(not F.seat_plays(0), "a host seat without a row plays nobody")
fire(0)
check(#MH == 0, "coop_mods_core.on host on a client: the door refuses, as before")

print("== where it does not answer (the server layer is not installed here)")
F.uninstall("srv")
local function none_answers()
	return F.where(0) == "away" and F.decider(0) == "nobody" and not F.decides_world() and not F.leads_here() and
		F.actor_is_player() and not F.group_travels()
end
engine({ host = true, map_server = true, rows = { { id = 0, is_self = true, avatar_id = 0 } } })
check(none_answers(), "a map server")
engine({ host = true, dedicated = true })
check(none_answers(), "a world server without a player")
engine({ host = true, split = true, rows = { { id = 0, is_self = true, avatar_id = 0 } } })
check(none_answers(), "a session split into maps")
engine({ active = false, host = false })
check(none_answers(), "no session")
engine({ host = true, rows = { { id = 0, is_self = true, avatar_id = 0 } } })
coop.is_map_server = function() error("no such predicate") end
check(F.decides_world() == true, "a predicate that raises counts as false")
coop.is_map_server = nil
check(F.decides_world() == true, "an engine without the predicate: the co-op")

print("== under the live layers (modes.live)")
modes.live(F)
engine({ host = true, rows = { { id = 0, is_self = true, avatar_id = 0 } } })
check(F.group_travels() == true, "the co-op host: the co-op layer answers, the server layer does not")

done("HOSTPLAY_MODE")
