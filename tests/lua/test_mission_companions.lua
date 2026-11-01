-- Mission fixes, part 1: companions a task gives follow the player who took the task (audit B finding 1) and the speaker's
-- squad joins when a client's give runs on the host (audit B section 7, add_speaker_companion).
-- Run: tools\test_lua.cmd mission_companions
dofile("tests/lua/support/harness_npc.lua")

local function pair()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	for _, M in ipairs({ H, C }) do M.env.coop_npc_players = load_script(M, "coop_npc_players") end
	local proxy = H.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
	C.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	return H, C, proxy
end

-- stock axr_companions / xr_effects / nta_utils shapes: every adder puts a squad into companion_squads
local function stock(M, squads)
	local E = M.env
	local function new_squad(id)
		local sq = { id = id, members = { id + 1 } }
		function sq:squad_members()
			local i = 0
			return function() i = i + 1; local m = self.members[i]; if m then return { id = m } end end
		end
		squads[id] = sq
		return sq
	end
	E.alife_object = function(id) return squads[id] end
	E.get_object_squad = function(o) for _, sq in pairs(squads) do if sq.members[1] == o:id() then return sq end end end
	E.axr_companions = { companion_squads = {} }
	E.axr_companions.add_special_squad = function(sq, special, cannot_teleport)
		if not sq then return end
		E.axr_companions.companion_squads[sq.id] = sq
	end
	E.xr_effects = {
		setup_companion_task = function(actor, npc, p)
			local sq = new_squad(tonumber(p[1]))
			E.axr_companions.companion_squads[sq.id] = sq
			M.set_up = (M.set_up or 0) + 1
		end,
		add_task_companion = function(actor, npc, p)
			local sq = squads[tonumber(p[1])]
			E.axr_companions.add_special_squad(sq, p[2] == "true", p[3] == "true") -- a call through the module, as in the stock file
		end,
		add_speaker_companion = function(actor, npc, p)
			if not E.db.actor:is_talking() then M.speaker_refused = true return end
			local speaker = E.mob_trade.GetTalkingNpc()
			E.axr_companions.add_special_squad(E.get_object_squad(speaker))
		end,
	}
	E.mob_trade = { GetTalkingNpc = function() return nil end }
	E.nta_utils = {
		spawn_companion_squad = function(cfg)
			local sq = new_squad(cfg.id)
			E.axr_companions.companion_squads[sq.id] = sq
			return sq.id
		end,
	}
	E.dialogs_axr_companion = {}
	E.axr_beh = { action_beh = { execute = function(self) M.beh_actor = E.db.actor:id() end } }
	E.task_manager = { get_task_manager = function() return { task_info = {} } end }
	return new_squad
end

print("== task companions follow the player who took the task")
local H, C, proxy = pair()
local squads = {}
local new_squad = stock(H, squads)
stock(C, {})
-- coop_tasks on the host: reward_peer() is the taker while the task's on_init runs; giving_npc() the giver of the request
local TAKER, GIVER = nil, nil
H.env.coop_tasks = {
	reward_peer = function() return TAKER end,
	giving_npc = function() return GIVER end,
}
local CH = load_script(H, "coop_npc_companions")
CH.on_game_start()
H.fire("actor_on_update")
local L = CH._leaders

TAKER = 1
H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "300", "esc_smart" })
check(H.set_up == 1, "setup_companion_task: the stock effect still runs")
check(L()[300] == 500, "setup_companion_task for a client's task: its proxy leads the new squad")

new_squad(310)
H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { "310" })
check(L()[310] == 500, "add_task_companion for a client's task: its proxy leads the squad")

new_squad(320)
H.env.axr_companions.add_special_squad(squads[320], true, false)
check(L()[320] == 500, "add_special_squad called by a task script (mystery of the swamps): led by the taker")

local id = H.env.nta_utils.spawn_companion_squad({ id = 330 })
check(id == 330 and L()[330] == 500, "nta_utils.spawn_companion_squad keeps its result and the taker leads the squad")

print("== no client in the scope: nothing changes")
TAKER = nil
H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "340", "esc_smart" })
check(L()[340] == nil, "the host's own task: the host keeps its companions (no leader entry)")
new_squad(350)
H.env.axr_companions.add_special_squad(squads[350])
check(L()[350] == nil, "add_special_squad outside a reward scope: no leader entry")
TAKER = 1
H.env.axr_companions.add_special_squad(nil)
check(true, "add_special_squad(nil) still returns quietly")
TAKER = 7 -- a peer that left: no character to lead
H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "360", "esc_smart" })
check(L()[360] == nil, "the taker is gone: no leader entry")
TAKER = 1

print("== split levels: the taker stands on another level, this process has no object of him")
do
	local here = H.objects[500]
	H.objects[500] = nil
	H.env.coop_npc_players.invalidate()
	check(H.env.coop_npc_players.object_of_peer(1) == nil, "(no object of his character here)")
	check(H.env.coop_npc_players.avatar_of_peer(1) == 500, "avatar_of_peer: the character's id from the list of players")
	check(H.env.coop_npc_players.avatar_of_peer(0) == 0, "avatar_of_peer: this player's own actor is 0")
	check(H.env.coop_npc_players.avatar_of_peer(7) == nil, "avatar_of_peer: nobody of the session")
	check(H.env.coop_npc_players.avatar_of_peer("1") == nil, "avatar_of_peer: not a peer")
	H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "365", "esc_smart" })
	check(L()[365] == 500, "the taker leads the squad all the same: the id comes from the list of players, no object is needed")
	H.objects[500] = here
	H.env.coop_npc_players.invalidate()
end

print("== an old companion squad stays with its leader")
-- the squad was a companion before the call: only the squads a call adds are claimed
H.env.axr_companions.companion_squads[370] = new_squad(370)
H.env.axr_companions.add_special_squad(squads[370])
check(L()[370] == nil, "a squad that was a companion already is not claimed by a later call")

print("== the squad follows the proxy (axr_beh)")
local comp = H.add(make_obj(301, 12, 0, 0, { _name = "comp" }))
H.env.axr_beh.action_beh.execute({ object = comp })
check(H.beh_actor == 500, "a task companion thinks with 'actor' = its leader's proxy")

print("== a scripted enemy walks to the nearest player on his feet (target = actor)")
local enemy = H.add(make_obj(302, 500, 0, 0, { _name = "attacker" }))
local proxy_of = H.objects[500]
local host_of = H.env.db.actor
host_of._pos, proxy_of._pos = vec(1000, 0, 0), vec(510, 0, 0)
H.env.coop_npc_players.invalidate()
H.beh_actor = nil
H.env.axr_beh.action_beh.execute({ object = enemy, st = { target = "actor" } })
check(H.beh_actor == 500, "the client next to it, not the far host")
host_of._pos = vec(501, 0, 0)
H.beh_actor = nil
H.env.axr_beh.action_beh.execute({ object = enemy, st = { target = "actor" } })
check(H.beh_actor == 0, "the host when he is the nearest")
H.env.coop.life_of = function(id) return id == 0 and "wounded" or "alive" end
H.beh_actor = nil
H.env.axr_beh.action_beh.execute({ object = enemy, st = { target = "actor" } })
check(H.beh_actor == 500, "the host is down: the one on his feet")
H.env.coop.life_of = nil
H.beh_actor = nil
H.env.axr_beh.action_beh.execute({ object = enemy, st = { target = "smart" } })
check(H.beh_actor == 0, "another target: stock")

print("== add_speaker_companion for a client's give")
H.env.axr_companions.companion_squads = {}
CH._leaders()[300] = nil
local giver = H.add(make_obj(401, 12, 0, 0, { _name = "giver" }))
local sq = new_squad(400)
sq.members = { 401 }
H.env.db.actor._talking = false
TAKER, GIVER = 1, giver
H.env.xr_effects.add_speaker_companion(H.env.db.actor, nil, { "simulation_task_66" })
check(not H.speaker_refused, "the giver counts as the speaker although the host is not talking")
check(H.env.axr_companions.companion_squads[400] ~= nil, "the speaker's squad joined")
check(L()[400] == 500, "...and the taker leads it")
check(H.env.mob_trade.GetTalkingNpc() == nil, "the talking NPC is put back")
check(H.env.db.actor:is_talking() == false, "the host's actor is not talking afterwards")

print("== add_speaker_companion: the host's own talk and a missing giver are left alone")
H.env.axr_companions.companion_squads = {}
L()[400] = nil
H.speaker_refused = nil
H.env.db.actor._talking = true
TAKER, GIVER = nil, nil
H.env.mob_trade.GetTalkingNpc = function() return giver end
H.env.xr_effects.add_speaker_companion(H.env.db.actor, nil, { "simulation_task_66" })
check(H.env.axr_companions.companion_squads[400] ~= nil and L()[400] == nil, "the host talking: stock, the host keeps the squad")
H.env.axr_companions.companion_squads = {}
H.env.db.actor._talking = false
TAKER, GIVER = 1, nil
H.env.xr_effects.add_speaker_companion(H.env.db.actor, nil, { "simulation_task_66" })
check(H.speaker_refused == true, "no giver known: the stock effect decides (it refuses without a talk)")

print("== recruits of a client: the Fanatic at Rookie Village, a hired squad")
do
	local H2, C2, proxy2 = pair()
	local sq2 = {}
	local make2 = stock(H2, sq2)
	stock(C2, {})
	for _, M in ipairs({ H2, C2 }) do
		local E = M.env
		M.ran = {}
		local recruit = function(a, b)
			M.ran[#M.ran + 1] = "recruit"
			E.axr_companions.companion_squads[E.get_object_squad(b).id] = E.get_object_squad(b)
		end
		E.dialogs_axr_companion = { become_actor_companion = recruit }
		E.dialogs_escape = { set_esc_2_12_stalker_fanat_as_companion = recruit }
		local period
		E.txr_paid_companions = {
			paid_companions = {},
			take_guard_money_1 = function() period = 86400 end,
			take_guard_money_2 = function() period = 172800 end,
			register_paid_companion = function(a, b)
				local s = E.get_object_squad(b)
				if s and E.axr_companions.companion_squads[s.id] then
					E.txr_paid_companions.paid_companions[s.id] = { guard_period = period }
				end
			end,
		}
		E.coop.talk_recent = function() return true end
	end
	local HC = load_script(H2, "coop_npc_companions")
	local CC2 = load_script(C2, "coop_npc_companions")
	HC.on_game_start()
	CC2.on_game_start()
	H2.fire("actor_on_update")
	local fanat_squad = make2(600)
	local fanat = H2.add(make_obj(601, 12, 0, 0, { _name = "fanat" }))
	local fanat_copy = C2.add(make_obj(601, 2, 0, 0, { _name = "fanat" }))
	C2.env.get_object_squad = function(o) return o:id() == 601 and fanat_squad or nil end
	C2.env.dialogs_escape.set_esc_2_12_stalker_fanat_as_companion(C2.env.db.actor, fanat_copy)
	pump()
	check(#C2.ran == 0, "the Fanatic: nothing runs on the client's copy")
	check(H2.ran[1] == "recruit" and HC._leaders()[600] == 500, "the Fanatic: the host recruits him for the client's character")

	local hired = make2(610)
	local merc = H2.add(make_obj(611, 12, 0, 0, { _name = "merc" }))
	local merc_copy = C2.add(make_obj(611, 2, 0, 0, { _name = "merc" }))
	C2.env.get_object_squad = function(o) return o:id() == 611 and hired or nil end
	C2.env.txr_paid_companions.take_guard_money_2(C2.env.db.actor, merc_copy)
	C2.env.dialogs_axr_companion.become_actor_companion(C2.env.db.actor, merc_copy)
	C2.env.txr_paid_companions.register_paid_companion(C2.env.db.actor, merc_copy)
	pump()
	local e = H2.env.txr_paid_companions.paid_companions[610]
	check(C2.env.txr_paid_companions.paid_companions[610] == nil, "a hire: not on the client's copy")
	check(e ~= nil and e.guard_period == 172800, "a hire: the host's table runs the contract, for the days the client paid")

	-- the contract ends on the host: the client's dialog menu must not keep a companion
	merc._info.npcx_is_companion = true
	merc_copy._info.npcx_is_companion = true
	H2.env.coop_tasks = nil
	NOW = NOW + 5000
	H2.fire("actor_on_update")
	pump()
	check(HC._leaders()[610] == 500, "still hired: he keeps his leader")
	H2.env.axr_companions.companion_squads[610] = nil
	merc._info.npcx_is_companion = nil
	NOW = NOW + 5000
	H2.fire("actor_on_update")
	pump()
	check(HC._leaders()[610] == nil, "the contract ended: no leader")
	check(not merc_copy:has_info("npcx_is_companion"), "...and the client's copy is told")
end

print("== a client machine is not touched")
local CC = load_script(C, "coop_npc_companions")
CC.on_game_start()
local ok = pcall(C.env.xr_effects.setup_companion_task, C.env.db.actor, nil, { "500", "esc_smart" })
check(ok and next(CC._leaders()) == nil, "a client keeps no leader table")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
