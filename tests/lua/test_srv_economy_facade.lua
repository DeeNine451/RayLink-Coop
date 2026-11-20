-- World decisions and map reports in the Server mode, through the production economy scripts and live Lua layers.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BRIDGE, OTHER_BRIDGE, UNKNOWN = 0x100, 0x101, 0x102
PLAYERS = { [1] = { nick = "first", proxy = 501 }, [2] = { nick = "second", proxy = 502 } }
POS = { [0] = vec(0), [1] = vec(3), [2] = vec(6) }
BRIDGES[BRIDGE] = { players = { 1, 2 } }
BRIDGES[OTHER_BRIDGE] = { players = {} }
local S, M = make_world(0), make_world(BRIDGE)

S.warfare = { distance_to_xz_sqr = function(a, b) return (a.x - b.x)^2 end }
S.smart_terrain_warfare = {
	process_manual_capture = function(smart)
		S.captured = S.warfare.distance_to_xz_sqr(smart.position, POS[0]) < 1
	end,
}
local players = S.coop.players
S.coop.players = function()
	local rows = players()
	for _, row in ipairs(rows) do row.level, row.elsewhere = 2, true end
	return rows
end

local function start(W)
	W.coop.is_dedicated = function() return W == S end
	W.coop.is_map_server = function() return W == M end
	W.coop.levels = {
		split = function() return true end,
		my_level = function() return 1 end,
		level_of_player = function() return 2 end,
		map_servers = function() return { { bridge = BRIDGE }, { bridge = OTHER_BRIDGE } } end,
	}
	local facade = load_script(W, "coop_mode")
	modes.live(facade, function(name) return load_script(W, name) end)
	load_script(W, "coop_trust").reset_for_test({ default = "log" })
	W.game_setup = {
		world_itm_on = { [701] = "spot" }, world_itm_num = { spot = 4 }, world_itm_off = {},
		world_itm_info = {}, limited_uses = {}, try_spawn_world_item = function() end,
	}
	load_script(W, "coop_economy_core").RULES.sleep_rule = "host"
	local group = load_script(W, "coop_economy_group")
	group.subject("arena", { ask = { "arena_vote", "%s %s" } })
	group.on_game_start()
	load_script(W, "coop_economy_world").on_game_start()
	load_script(W, "coop_economy_money").on_game_start()
	load_script(W, "coop_economy_mdata").on_game_start()
end

S.ACTIVE = false
start(S)
start(M)

fire(S, "load_state", { coop_world_rolls = { [710] = { s = "ammo_9x19", n = 7 } } })
check(S.coop_economy_world.roll_waiting(710), "loading before the world session retains the world's retry queue")
local save = {}
fire(S, "save_state", save)
check(save.coop_world_rolls == nil, "before the session no world rolls are written")
tick(S, 2500)
check(#S.RULE_CALLS == 0, "before the session there is no ledger rules push")
S.ACTIVE = true
fire(S, "save_state", save)
check(save.coop_world_rolls and save.coop_world_rolls[710] and save.coop_world_rolls[710].n == 7,
	"the world can save the retry as soon as it starts hosting")
tick(S, 2500)
check(#S.RULE_CALLS == 1, "the active world server pushes ledger rules")
tick(M, 2500)
check(#M.RULE_CALLS == 0, "the map server leaves rules to the world server")

local function report(event, payload, from)
	S.coop_main.on_event("economy." .. event, CM_ENCODE(payload), from)
end

report("propose", { t = 1, k = "wait", m = 15 }, 1)
local vote = last(S.SENT)
check(vote and vote.target == 2 and vote.name == "economy.vote", "the ghost's host-only rule becomes a vote among players")
S.smart_terrain_warfare.process_manual_capture({ position = POS[1] })
check(S.captured == false, "coordinates from another map do not start a capture in the world server's level")

local marked = S.game_setup.world_itm_on
report("loot_took", { p = 1, id = 701, s = "ammo_9x19" }, UNKNOWN)
check(marked[701] == "spot", "an unknown bridge does not release the spot")
report("loot_took", { p = 1.5, id = 701, s = "ammo_9x19" }, BRIDGE)
check(marked[701] == "spot", "the world rejects a fractional player seat even from a registered bridge")

local ammo = add_item(M, 701, "ammo_9x19", 501)
fire(M, "npc_on_item_take", M.level.object_by_id(501), ammo)
check(marked[701] == "spot", "the map server leaves the world spot to the world server")
local sent = last(M.SENT)
check(sent and sent.target == 0 and sent.name == "economy.loot_took", "the map server sends the pickup to the world")
deliver_all()
check(marked[701] == nil and S.game_setup.world_itm_off.spot and S.game_setup.world_itm_num.spot == nil,
	"the registered map server's report releases the world spot and detaches its roll")
M.coop_main.on_event("economy.loot_roll", CM_ENCODE({ id = 701, s = "ammo_9x19", n = 4 }), 0)
check(ammo.ammo == 4, "the map authority still receives the world's rolled value as a world client")

S.SENT = {}
add_entity(S, 701, "ammo_9x19", 501)
report("se", { n = 2, i1 = 701, k1 = "parts", d1 = "T", i2 = 701, k2 = "companion", d2 = "T" }, BRIDGE)
local peers, map = {}, nil
for _, msg in ipairs(S.SENT) do
	if msg.name == "economy.se" then
		if msg.target == OTHER_BRIDGE then map = CM_DECODE(msg.payload)
		else peers[msg.target] = CM_DECODE(msg.payload) end
	end
end
check(peers[1] and peers[1].n == 2 and peers[2] and peers[2].n == 2, "players still receive the full SE batch")
check(map and map.n == 1 and map.k1 == "parts", "the other map receives a filtered SE batch")
check(not peers[BRIDGE] and not peers[-1], "there is no SE echo to the sender or broadcast to all")

S.SENT = {}
report("propose_for", { k = 8, g = "arena", f = 1, v = "2", a = "4" }, UNKNOWN)
check(#S.SENT == 0, "an unregistered bridge cannot ask for a vote")
local trust = S.coop_trust.status()
check(trust.economy_loot_took_sender and trust.economy_loot_took_sender.failed == 1,
	"the transport sender failure is counted")
check(trust.economy_loot_took_payload and trust.economy_loot_took_payload.failed == 1,
	"the invalid seat is counted")
check(trust.economy_propose_for_sender and trust.economy_propose_for_sender.failed == 1,
	"the vote's sender failure is counted")

section("whole voter list and argument are checked before opening a vote")
for i, voters in ipairs({ "17", "2,17", "2,-1", "2,1.5", "2,1e0", "2, 1", "2,", ",2", "2,,1", "2x1", "02" }) do
	report("propose_for", { k = 10 + i, g = "arena", f = 1, v = voters, a = "4" }, BRIDGE)
	check(#S.SENT == 0, "no ballot or verdict for invalid voter list: " .. voters)
	S.SENT = {}
end
report("propose_for", { k = 22, g = "arena", f = 1, v = "", a = string.rep("x", 129) }, BRIDGE)
check(#S.SENT == 0, "an oversized vote argument cannot produce a verdict")
local vote_payload = trust.economy_propose_for_payload
check(vote_payload and vote_payload.failed == 12, "each invalid vote payload reaches coop_trust in log mode")
S.SENT = {}
report("propose_for", { k = 23, g = "arena", f = 1, v = "2,16", a = "4" }, BRIDGE)
local ballot = last(S.SENT)
check(#S.SENT == 1 and ballot.name == "economy.vote" and ballot.target == 2
	and CM_DECODE(ballot.payload).a == "4", "a valid mixed-width list asks the loaded voter")
S.SENT = {}
report("propose_for", { k = 24, g = "arena", f = 1, v = "", a = "" }, BRIDGE)
local immediate = last(S.SENT)
check(immediate and immediate.name == "economy.verdict_for" and immediate.target == BRIDGE
	and CM_DECODE(immediate.payload).ok == true, "an empty voter list still approves immediately")

section("the map authority validates a verdict before ending its pending vote")
local function hear(event, payload, from)
	M.coop_main.on_event("economy." .. event, CM_ENCODE(payload), from)
end
local result, calls = nil, 0
check(M.coop_economy_group.propose("arena", 1, { [2] = true }, function(ok)
	result, calls = ok, calls + 1
end, "4"), "the map server starts a pending vote")
local request = last(M.SENT)
local ticket = CM_DECODE(request.payload).k
local yes = { k = ticket, ok = true, r = "", n = "" }
hear("verdict_for", yes, OTHER_BRIDGE)
check(calls == 0, "another map server cannot deliver the verdict")
hear("verdict_for", { k = 9007199254740992, ok = true, r = "", n = "" }, 0)
hear("verdict_for", { k = ticket, ok = "yes", r = "", n = "" }, 0)
hear("verdict_for", { k = ticket, ok = true, r = string.rep("x", 17), n = "" }, 0)
hear("verdict_for", { k = ticket, ok = true, r = "", n = string.rep("x", 799) }, 0)
check(calls == 0, "invalid verdict fields cannot end the pending vote")
local map_trust = M.coop_trust.status()
local verdict_sender = map_trust.economy_verdict_for_sender
local verdict_payload = map_trust.economy_verdict_for_payload
check(verdict_sender and verdict_sender.failed == 1, "unexpected verdict sender reaches coop_trust")
check(verdict_payload and verdict_payload.failed == 4, "all invalid verdict fields reach coop_trust")
hear("verdict_for", yes, 0)
check(result == true and calls == 1, "the authoritative verdict still ends the vote once")

section("the map authority validates world-loot rolls before queueing or applying them")
local medkit = add_item(M, 702, "medkit", 501)
local weapon = add_item(M, 703, "wpn_ak74", 501)
M.game_setup.limited_uses.medkit = { 1, 3 }
hear("loot_roll", { id = 701, s = "ammo_9x19", n = 9 }, OTHER_BRIDGE)
check(ammo.ammo == 4, "a map peer cannot replace the world's roll")
hear("loot_roll", { id = 701, s = "ammo_9x19", n = 65536 }, 0)
hear("loot_roll", { id = 701, s = "ammo_9x19", n = 3.5 }, 0)
hear("loot_roll", { id = 702, s = "medkit", n = 256 }, 0)
hear("loot_roll", { id = 703, s = "wpn_ak74", n = 1.01 }, 0)
hear("loot_roll", { id = 704, s = "ammo_9x19", n = 65536 }, 0)
check(ammo.ammo == 4 and medkit.uses == 3 and weapon.cond == 1
	and not M.coop_economy_world.roll_waiting(704), "invalid rolls cannot change an item or queue for a future entity")
local roll_sender = map_trust.economy_loot_roll_sender
local roll_payload = map_trust.economy_loot_roll_payload
check(roll_sender and roll_sender.failed == 1, "unexpected roll sender reaches coop_trust")
check(roll_payload and roll_payload.failed == 5, "all invalid roll values reach coop_trust")
hear("loot_roll", { id = 701, s = "ammo_9x19", n = 0 }, 0)
hear("loot_roll", { id = 702, s = "medkit", n = 2 }, 0)
hear("loot_roll", { id = 703, s = "wpn_ak74", n = 0.4 }, 0)
check(ammo.ammo == 0 and medkit.uses == 2 and weapon.cond == 0.4,
	"the world can still set zero ammo, whole uses and a fractional condition")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
