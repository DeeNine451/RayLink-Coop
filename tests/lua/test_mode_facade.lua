-- The mode facade coop_mode (Core, docs\MODES.md section 4 "Lua", step S4): it answers what the layer of the mode says,
-- "none" before any layer, never reads the engine's mode predicates itself; on_level_request / publish deliver as the
-- layer says; when_srv runs once the srv layer answers. coop_mods_core.on(..., "host") / publish go through it (P-B).
-- Runs under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE). Real scripts over the stubs.
-- Not shipped. Run: tools\test_lua.cmd mode_facade
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
local tick -- the facade's actor_on_update (the other scripts' callbacks are not run here: the stubs below lie to them)
do
	local real = RegisterScriptCallback
	RegisterScriptCallback = function(name, f) if name == "actor_on_update" then tick = f end end
	F.on_game_start()
	RegisterScriptCallback = real
end
check(type(tick) == "function", "on_game_start registers the frame tick")
local C = coop_mods_core
local cm = coop_main
local PEERS = { 0, 1, 2 }

-- the coop.* stubs say "a co-op host"; the facade must not listen to them
coop.is_map_server = function() return true end
coop.is_dedicated = function() return true end
coop.levels = { split = function() return true end, bridge_of_player = function() return 0x777 end }

print("== before any layer: the answers of none")
local none = modes.set("none")
local same = true
for _, p in ipairs({ 0, 1, 7, nil, "1", -1, 1.5, 0 / 0 }) do
	same = same and F.where(p) == "away" and F.decider(p) == "nobody" and F.seat_plays(p) == false
end
check(same, "where away, decider nobody, seat_plays false for any peer, a bad one too")
check(F.actor_is_player() == true and F.decides_world() == false and F.leads_here() == false, "actor is a player, decides nothing, leads nothing")
check(F.is_player_mirror() == false and F.group_travels() == false, "no mirror, no group")
SENT = {}
check(F.publish("p.none", { a = 1 }) == false and #SENT == 0, "publish sends nothing")
check(none.where(1) == F.where(1) and none.decider(1) == F.decider(1) and none.publish_to("x") == nil, "the set none says the same")

print("== install refuses what is not a layer")
check(F.install(nil) == false and F.install({}) == false, "nil and an empty table")
local bad = modes.set("hostplay")
bad.name = "coop"
check(F.install(bad) == false, "a name that is no layer")
bad = modes.set("hostplay")
bad.where = nil
check(F.install(bad) == false, "a layer without where")
check(F.where(1) == "away", "still none")
check(F.uninstall("hostplay") and F.uninstall("srv") and not F.uninstall("none"), "uninstall knows hostplay and srv only")

-- what one request does under a set: { handled = { {t, from, relayed} }, passed = { {target, t} }, doors = n }
local REQ = "test.lvl"
local seen = { handled = {}, doors = 0 }
local door_says = true
F.on_level_request(REQ, function(payload, from, relayed)
	seen.handled[#seen.handled + 1] = { t = cm.decode(payload), from = from, relayed = relayed }
end, function(payload, from)
	seen.doors = seen.doors + 1
	return door_says
end)
local function fire(t, from)
	seen.handled, seen.doors, SENT = {}, 0, {}
	cm.on_event(REQ, cm.encode(t), from)
	local passed = {}
	for _, s in ipairs(SENT) do
		if s.name == REQ then passed[#passed + 1] = { target = s.target, t = cm.decode(s.payload) } end
	end
	return seen.handled, passed, seen.doors
end

-- coop_mods_core: a "host" request and publish
local MHANDLED = {}
C.on("mode_req", function(t, from) MHANDLED[#MHANDLED + 1] = { t = t, from = from } end, "host")
local function mods_fire(t, from)
	MHANDLED, SENT = {}, {}
	cm.on_event("mods.mode_req", cm.encode(t), from)
	local passed = {}
	for _, s in ipairs(SENT) do
		if s.name == "mods.mode_req" then passed[#passed + 1] = { target = s.target, t = cm.decode(s.payload) } end
	end
	return MHANDLED, passed
end

local srv_ran = 0
local early_ran = 0
F.when_srv(function() early_ran = early_ran + 1 end)

for _, name in ipairs(modes.names()) do
	print("== set " .. name)
	local set = modes.install(F, name)
	local tag = name .. ": "
	local ok = true
	for _, p in ipairs(PEERS) do
		ok = ok and F.where(p) == set.where(p) and F.decider(p) == set.decider(p) and F.seat_plays(p) == set.seat_plays(p)
	end
	check(ok, tag .. "where, decider, seat_plays as the set says for peers 0 1 2")
	check(F.actor_is_player() == set.actor_is_player() and F.decides_world() == set.decides_world() and
		F.leads_here() == set.leads_here() and F.is_player_mirror() == set.is_player_mirror() and
		F.group_travels() == set.group_travels(), tag .. "actor, world, map, mirror, group as the set says")

	SENT = {}
	local sent = F.publish("p." .. name, { a = 1 })
	local target = set.publish_to("p." .. name)
	if target == nil then
		check(sent == false and #SENT == 0, tag .. "publish: nothing sent")
	else
		check(sent == true and #SENT == 1 and SENT[1].target == target and cm.decode(SENT[1].payload).a == 1,
			tag .. "publish: to " .. target .. ", the table encoded")
	end
	SENT = {}
	F.publish("p.str", "k=n5")
	check(target == nil and #SENT == 0 or SENT[1] and SENT[1].payload == "k=n5", tag .. "publish: a string goes as it is")

	-- a player's request from peer 1, and one the world server passed on (from 0 with _peer 3)
	local h, passed, doors = fire({ a = 5 }, 1)
	local h0, passed0, doors0 = fire({ a = 6, _peer = 3 }, 0)
	if name == "hostplay" or name == "none" then
		check(#h == 1 and h[1].from == 1 and h[1].t.a == 5 and h[1].relayed == false and doors == 1 and #passed == 0,
			tag .. "a request runs here, through the door")
		check(#h0 == 1 and h0[1].from == 0 and doors0 == 1, tag .. "from 0 too: no world server passes anything here")
	elseif name == "srv_world" then
		check(#h == 0 and doors == 1 and #passed == 1 and passed[1].target == set.bridge and passed[1].t._peer == 1 and
			passed[1].t.a == 5, tag .. "a request goes to the map server of his map, with him in it, after the door")
	elseif name == "srv_map" then
		check(#h == 0 and doors == 0 and #passed == 0, tag .. "a player's own request is dropped: only the world server passes them")
		check(#h0 == 1 and h0[1].from == 3 and h0[1].t._peer == nil and h0[1].t.a == 6 and h0[1].relayed == true and doors0 == 0,
			tag .. "the world server's: runs as his, without _peer, the door was the world server's")
	end
	door_says = false
	h, passed = fire({ a = 7 }, 1)
	check(#h == 0 and #passed == 0, tag .. "the door says no: nothing runs, nothing is passed on")
	door_says = true

	-- coop_mods_core goes the same way
	local mh, mp = mods_fire({ b = 1 }, 1)
	local mh0 = mods_fire({ b = 2, _peer = 3 }, 0)
	if name == "hostplay" or name == "none" then
		check(#mh == 1 and mh[1].from == 1 and #mp == 0, tag .. "coop_mods_core.on host: runs here")
	elseif name == "srv_world" then
		check(#mh == 0 and #mp == 1 and mp[1].target == set.bridge and mp[1].t._peer == 1,
			tag .. "coop_mods_core.on host: passed to the map server of his map")
	elseif name == "srv_map" then
		check(#mh == 0 and #mh0 == 1 and mh0[1].from == 3 and mh0[1].t._peer == nil,
			tag .. "coop_mods_core.on host: only through the world server, as his")
	end
	SENT = {}
	local pub = C.publish("mode_pub", { c = 1 })
	if target == nil then
		check(pub == false and #SENT == 0, tag .. "coop_mods_core.publish: nothing sent")
	else
		check(pub == true and SENT[1] and SENT[1].name == "mods.mode_pub" and SENT[1].target == target,
			tag .. "coop_mods_core.publish: to " .. target)
	end

	-- when_srv: runs once the srv layer answers, once only
	local before = srv_ran
	F.when_srv(function() srv_ran = srv_ran + 1 end)
	if set.name == "srv" then
		check(srv_ran == before + 1 and early_ran == 1, tag .. "when_srv: at once, and the waiting one ran too, once")
	else
		check(srv_ran == before, tag .. "when_srv: waits")
	end
end

print("== layers: order, faults")
modes.install(F, "none")
local hp, sv = modes.set("hostplay"), modes.set("srv_map")
F.install(sv)
F.install(hp)
check(F.leads_here() == true and F.decides_world() == true and F.group_travels() == true, "both answer: the co-op layer is asked first")
hp.applies = function() return false end
check(F.decides_world() == false and F.leads_here() == true, "the co-op layer does not answer: the server's does")
hp.applies = function() error("boom") end
check(F.decides_world() == false and log_has("hostplay.applies"), "applies raises: told, the next layer answers")
sv.where = function() return "nowhere" end
sv.decider = function() error("bad decider") end
check(F.where(1) == "away" and log_has("where answer"), "a word that is no answer: none's, told")
check(F.decider(1) == "nobody" and log_has("srv.decider"), "an answer that raises: none's, told")
sv.level_request = function() return "fly" end
local h = fire({ a = 1 }, 1)
check(#h == 1 and h[1].from == 1 and log_has("level_request answer"), "a request answer that is no action: handled here, told")
F.uninstall("hostplay")
F.uninstall("srv")

print("== when_srv: the waiting functions, the frame tick, the srv layer passed with it")
modes.install(F, "none")
local order = {}
F.when_srv(function() order[#order + 1] = "a" end)
F.when_srv(function() error("a broken registration") end)
F.when_srv(function() order[#order + 1] = "b" end)
check(#order == 0, "none: nothing runs")
local srv = modes.set("srv_map")
local inner = 0
F.when_srv(function()
	order[#order + 1] = "c"
	F.when_srv(function() inner = inner + 1 end) -- a registration inside one: runs too
	F.where(1)
end, srv)
check(table.concat(order) == "abc" and inner == 1 and log_has("a broken registration"),
	"the srv layer passed with when_srv answers: all ran in order, a broken one is told and does not stop the rest")
order = {}
F.where(1)
F.where(2)
check(#order == 0 and inner == 1, "once only")
local fake_hp = modes.set("hostplay")
check(F.when_srv(nil, fake_hp) == false and F.decides_world() == false, "when_srv takes the srv layer only")
F.uninstall("srv")
local ticked = 0
F.when_srv(function() ticked = ticked + 1 end)
F.install(modes.set("srv_world"))
tick()
check(ticked == 1, "the frame tick runs the waiting ones when nobody asked")
tick()
check(ticked == 1, "and not again")

print("== status")
LOG = {}
F.print_status()
check(log_has("layers srv, answers srv, when_srv waiting 0") ~= nil, "coop_status names the layers and who answers")

done("MODE_FACADE")
