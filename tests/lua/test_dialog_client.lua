-- A client alone at an NPC gets what the host would (dialog audit 2026-11-01, coop_quests_missions / coop_quests_party):
--   a reward's stash (treasure_manager.create_random_stash) is made by the host for the one who asked,
--   "wanna trade?" of a stalker (dialogs.is_trade_accept): the host makes the stock and keeps the answer,
--   a bought ceasefire (xr_bribe) holds for a client's character and breaks when he hits,
--   dialogs.update_npc_dialog does nothing on a client, the food and the trust are the player's, not the host's,
--   the data keys of the economy script (mlr debts, the Hidden Threat reward table) and the shared task vars.
-- Run: tools\test_lua.cmd dialog_client
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story",
	"coop_quests_missions" }
local PACE_WAIT_MS = 1500

local function setup_world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	M.npc = M.new_obj(700, "esc_m_stalker", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	for id = 701, 703 do
		local o = M.new_obj(id, "esc_m_stalker", vec(5, 0, 0), { _stalker = true })
		e.db.storage[id] = { object = o }
	end
	M.far = M.new_obj(704, "esc_m_stalker", vec(90, 0, 0), { _stalker = true })
	M.talked = true
	e.coop.talk_recent = function() return M.talked end
	e.character_community = function(o) return o._comm or "stalker" end
	e.ranks = { get_obj_rank_name = function() return "novice" end }
	e.ini_sys.section_exist = function(_, s) return type(s) == "string" and s ~= "no_such_section" end

	-- treasure_manager: the stock call, with whose scope it ran in
	M.stashes = {}
	e.treasure_manager = {
		create_random_stash = function(no_spot, hint, bonus, spawn_local, inv_box)
			M.stashes[#M.stashes + 1] = { no_spot = no_spot, hint = hint, bonus = bonus, spawn_local = spawn_local, inv_box = inv_box,
				peer = e.coop_tasks.reward_peer and e.coop_tasks.reward_peer() }
		end,
	}

	-- death_manager and the trade dialog
	M.items_by_npc = {}
	M.stocked = {}
	e.death_manager = {
		get_items_by_npc = function(id) return M.items_by_npc[id] end,
		set_items_by_npc = function(id, v) M.items_by_npc[id] = v end,
		create_item_list = function(npc, comm, rank, is_private, to_save)
			M.stocked[#M.stocked + 1] = { id = npc:id(), comm = comm, rank = rank, is_private = is_private, to_save = to_save }
			M.items_by_npc[npc:id()] = { [9000 + npc:id()] = true } -- the stock records the items it made
		end,
	}
	M.talk_npc = M.npc
	e.dialogs.is_trade_accept = function() M.stock_trade = (M.stock_trade or 0) + 1 return true end
	e.dialogs.update_npc_dialog = function() M.updated = (M.updated or 0) + 1 end
	e.dialogs.complete_simulation_task = function() M.completed = (M.completed or 0) + 1 end

	-- xr_bribe
	M.peace = {}
	M.bribe_asks, M.bribe_breaks = {}, {}
	e.xr_bribe = {
		at_peace = function(npc_comm, player_comm, dist)
			M.bribe_asks[#M.bribe_asks + 1] = { npc_comm, player_comm, dist }
			return M.peace[npc_comm] == true
		end,
		npc_on_hit_callback = function(comm) M.bribe_breaks[#M.bribe_breaks + 1] = comm end,
	}
	e.SendScriptCallback = function(name, ...)
		for _, f in ipairs(M.callbacks[name] or {}) do f(...) end
	end

	-- the host's actor is the story object "actor"; goodwill is read by id
	M.story_actor = M.actor
	e.get_story_object = function(sid) if sid == "actor" then return M.story_actor end end
	e.dialogs_zaton = {
		zat_b103_actor_has_needed_food = function() -- dialogs_zaton.script: counts the story actor's bread
			local n = 0
			e.get_story_object("actor"):iterate_inventory(function(_, item) if item:section() == "bread" then n = n + 1 end end, nil)
			return n >= 6
		end,
	}
	M.goodwill = { [0] = -500 }
	e.relation_registry = { community_goodwill = function(comm, id) return M.goodwill[id] or 0 end }
	e.dialogs.is_actor_trustworthy = function() return e.relation_registry.community_goodwill("stalker", e.AC_ID) > 200 end

	-- data only the host's logic fills: an anomaly zone's spawned count, the loot of the bandit companions
	M.zone = { spawned_count = 0 }
	e.db.anomaly_by_name = { jup_b32_anomal_zone = M.zone }
	e.dialogs_jupiter = {
		jup_b32_anomaly_has_af = function() -- the first branch of the stock function (dialogs_jupiter.script)
			if not e.has_alife_info("jup_b32_anomaly_1") then return false end
			local z = e.db.anomaly_by_name["jup_b32_anomal_zone"]
			if z == nil then return false end
			if z.spawned_count > 0 then
				M.infos.jup_b32_anomaly_1, M.infos.jup_b32_anomaly_true = nil, true
				return true
			end
			return false
		end,
	}
	M.squad_members = {}
	e.get_story_squad = function(sid)
		if sid ~= "bandit_companion_task_1" then return nil end
		return { squad_members = function()
			local i = 0
			return function() i = i + 1 return M.squad_members[i] end
		end }
	end
	e.dialogs_darkvalley = {}
	e.dialogs_darkvalley.bandit_companion_task_1_complete = function() -- the stock one reads the host's storage
		local n = 0
		for _, m in ipairs(M.squad_members) do n = n + (e.load_var(e.db.storage[m.id].object, "s_loot_count") or 0) end
		return n >= 9
	end
	e.dialogs_darkvalley.bandit_companion_task_1_not_complete = function(a, b)
		return not e.dialogs_darkvalley.bandit_companion_task_1_complete(a, b)
	end

	-- coop_economy_mdata: which keys were declared
	M.keys = {}
	e.coop_economy_mdata = {
		register_player_key = function(k) M.keys[#M.keys + 1] = "player:" .. k end,
		register_world_key = function(k) M.keys[#M.keys + 1] = "world:" .. k end,
	}

	-- Hidden Threat: the table the reward dialogs read, and the live copy in m_data
	M.m_data = {}
	e.alife_storage_manager = { get_state = function() return M.m_data end }
	e.utils_slht = { reward_table = {} }
	e.dialogs_hidden_threat = {
		postcond_dialog_kuznetsov_d4_1 = function() M.paid = e.utils_slht.reward_table.Task3Reward end,
		postcond_dialog_kuznetsov_d5_3 = function() end,
		postcond_dialog_degtyarev_d2 = function() end,
	}
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- the client's character on the host
local host_av = Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
for id = 700, 704 do Cm.new_obj(id, "esc_m_stalker", Cm.objects[id] and Cm.objects[id]._pos or vec(5, 0, 0), { _stalker = true }) end
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
Cm.story_actor = host_av
Cm.talk_npc = Cm.objects[700]
Cm.env.dialogs.who_is_npc = function() return Cm.talk_npc end
Hm.env.dialogs.who_is_npc = function() return Hm.talk_npc end
check(Hm.env.coop_economy_mdata ~= nil, "the economy script stub is in")
boot(Hm)
boot(Cm)
check(Hm.handlers["quests.act"] ~= nil and Cm.handlers["quests.trade"] ~= nil, "the host handles quests.act, the client quests.trade")
local function wait() NOW = NOW + PACE_WAIT_MS end

print("== the data keys are declared before the world loads")
for _, M in ipairs({ Hm, Cm }) do
	local joined = table.concat(M.keys, ",")
	check(joined:find("player:mlr", 1, true) ~= nil, M.role .. ": mlr debts are the player's own data")
	check(joined:find("world:slht_reward_table", 1, true) ~= nil, M.role .. ": the Hidden Threat reward table is the host's")
end

-- ---------------------------------------------------------------- stash
print("== a reward's stash is made by the host for the one who asked")
do
	Cm.env.treasure_manager.create_random_stash(nil, "Stash of Bob", { "bonus_a", "no_such_section", "bonus_b" }, true)
	check(#Cm.stashes == 0, "not made on the client (no caches there)")
	check(Cm.env.treasure_manager.last_secret == true, "the client knows there is a stash (a victim's answer reads it)")
	check(count_sent(Cm, "quests.act") == 1, "one request to the host")
	pump()
	check(#Hm.stashes == 1, "the host made it")
	local s = Hm.stashes[1] or {}
	check(s.hint == "Stash of Bob" and s.spawn_local == true and s.no_spot == nil and s.inv_box == nil, "with the arguments of the call")
	check(s.bonus and #s.bonus == 2 and s.bonus[1] == "bonus_a" and s.bonus[2] == "bonus_b", "the bonus sections that exist")
	check(s.peer == 1, "in the scope of the player who asked (the stash line is his)")

	Hm.stashes = {}
	Cm.env.treasure_manager.create_random_stash()
	pump()
	check(#Hm.stashes == 0, "the same request within a second: paced")
	wait()
	Cm.env.treasure_manager.create_random_stash()
	pump()
	check(#Hm.stashes == 1 and Hm.stashes[1].bonus == nil and Hm.stashes[1].hint == nil, "a bare call is a bare call")

	Hm.stashes = {}
	wait()
	Hm.talked = false
	Hm.log = {}
	Cm.env.treasure_manager.create_random_stash()
	pump()
	check(#Hm.stashes == 0 and has_log(Hm, "stash from #1 refused"), "nobody he talked to: refused")
	Hm.talked = true
	wait()
	Hm.objects[700]._pos, Hm.objects[701]._pos, Hm.objects[702]._pos, Hm.objects[703]._pos = vec(90, 0, 0), vec(90, 0, 0), vec(90, 0, 0), vec(90, 0, 0)
	Cm.env.treasure_manager.create_random_stash()
	pump()
	check(#Hm.stashes == 0, "no NPC within reach: refused")
	for id = 700, 703 do Hm.objects[id]._pos = vec(5, 0, 0) end

	wait()
	Hm.env.treasure_manager.create_random_stash(nil, "host's own", nil, true)
	check(#Hm.stashes == 1 and count_sent(Hm, "quests.act") == 0, "the host's own call is the stock one")

	Cm.stashes = {}
	Hm.stashes = {}
	local sent = count_sent(Cm, "quests.act")
	-- a condlist (the host's own logic makes the stash)
	Cm.env.xr_effects.make_stash = function() Cm.env.treasure_manager.create_random_stash(nil, nil, nil, true) end
	Cm.env.xr_logic.pick_section_from_condlist(Cm.actor, Cm.npc, { src = "%=make_stash%" })
	check(count_sent(Cm, "quests.act") == sent, "inside a condlist the client sends nothing")
end

-- ---------------------------------------------------------------- trade
print("== \"wanna trade?\": the client rolls once, the host makes the stock and keeps the answer")
do
	local real_random = math.random
	local roll = 10
	math.random = function(a, b) if b == nil and a == 100 then return roll end return real_random(a, b) end
	local function ask(npc_id)
		Cm.talk_npc = Cm.objects[npc_id]
		wait()
		local r = Cm.env.dialogs.is_trade_accept(Cm.actor, Cm.talk_npc)
		pump()
		return r
	end

	local acts0 = count_sent(Cm, "quests.act")
	check(ask(700) == true, "a roll of 10: agrees")
	check(Hm.stock_trade == nil and Cm.stock_trade == nil, "the stock roll (a host table the client does not have) did not run")
	check(#Hm.stocked == 1 and Hm.stocked[1].id == 700 and Hm.stocked[1].comm == "stalker" and Hm.stocked[1].rank == "novice"
		and Hm.stocked[1].is_private == false and Hm.stocked[1].to_save == true, "the host made the stock into the NPC, as the stock dialog does")
	check(type(Hm.items_by_npc[700]) == "table", "...and keeps the answer")
	check(type(Cm.items_by_npc[700]) == "table", "the client keeps it too (a second ask is the same answer)")
	roll = 90
	check(ask(700) == true and #Hm.stocked == 1, "asked again with a bad roll: still agrees, no second stock")
	check(count_sent(Cm, "quests.act") == acts0 + 1, "...and no second request")

	check(ask(701) == false, "a roll of 90: refuses")
	check(Hm.items_by_npc[701] == false and Cm.items_by_npc[701] == false, "both keep the refusal")
	roll = 10
	check(ask(701) == false and #Hm.stocked == 1, "he cannot ask again until he wins")

	-- the host decided before: its answer wins from the next dialog
	Hm.items_by_npc[702] = false
	check(ask(702) == true, "the client rolled yes (the host had said no)")
	check(Cm.items_by_npc[702] == false, "...the host's answer reached him")
	check(ask(702) == false, "...and the next dialog follows it")
	check(#Hm.stocked == 1, "the host made no stock for a refused NPC")

	Hm.items_by_npc[703] = { [1] = true }
	roll = 90
	check(ask(703) == false and type(Cm.items_by_npc[703]) == "table", "the client rolled no, the host had a stock: his next dialog follows the host")
	check(ask(703) == true, "...agrees")

	-- an NPC too far away
	Cm.talk_npc = Cm.objects[704]
	Hm.stocked = {}
	roll = 10
	wait()
	Cm.env.dialogs.is_trade_accept(Cm.actor, Cm.talk_npc)
	pump()
	check(#Hm.stocked == 0 and Hm.items_by_npc[704] == nil, "an NPC out of reach: the host makes nothing")

	-- the host's own dialog is the stock one
	Hm.env.dialogs.is_trade_accept(Hm.actor, Hm.npc)
	check(Hm.stock_trade == 1, "the host's own question is the stock function")
	math.random = real_random
end

-- ---------------------------------------------------------------- bribe
print("== a bought ceasefire holds for a client's character, a hit of his breaks it")
do
	local bandit = Hm.new_obj(710, "bandit", vec(8, 0, 0), { _stalker = true, _comm = "bandit" })
	local flags = { override = false, result = true }
	Hm.peace.bandit = true
	Hm.env.SendScriptCallback("on_enemy_eval", bandit, Hm.objects[500], flags)
	check(flags.override == true and flags.result == false, "the bandit does not see the client's character as an enemy")
	check(Hm.bribe_asks[1] and Hm.bribe_asks[1][3] == 16, "at_peace measured from the client's character (distance squared)")

	flags = { override = false, result = true }
	Hm.bribe_asks = {}
	Hm.env.SendScriptCallback("on_enemy_eval", bandit, Hm.actor, flags)
	check(flags.override == false and #Hm.bribe_asks == 0, "the host's actor is left to the stock rule (it asks at_peace itself)")

	flags = { override = false, result = true }
	Hm.env.SendScriptCallback("on_enemy_eval", bandit, Hm.objects[701], flags)
	check(flags.override == false and #Hm.bribe_asks == 0, "a stalker is nobody's player")

	Hm.peace.bandit = false
	flags = { override = false, result = true }
	Hm.env.SendScriptCallback("on_enemy_eval", bandit, Hm.objects[500], flags)
	check(flags.override == false and flags.result == true, "no ceasefire: the flags are as the stock rule left them")

	flags = { override = true, result = true }
	Hm.peace.bandit = true
	Hm.bribe_asks = {}
	Hm.env.SendScriptCallback("on_enemy_eval", bandit, Hm.objects[500], flags)
	check(flags.result == true and #Hm.bribe_asks == 0, "a verdict another script already gave stays")

	Hm.env.SendScriptCallback("npc_on_hit_callback", bandit, 10, vec(), Hm.objects[500], 0)
	check(#Hm.bribe_breaks == 1 and Hm.bribe_breaks[1] == "bandit", "a hit by the client's character breaks the ceasefire with the bandits")
	Hm.env.SendScriptCallback("npc_on_hit_callback", bandit, 10, vec(), Hm.actor, 0)
	check(#Hm.bribe_breaks == 1, "the host's own hit is the stock callback's (not counted twice)")
	Hm.env.SendScriptCallback("npc_on_hit_callback", bandit, 10, vec(), Hm.objects[701], 0)
	check(#Hm.bribe_breaks == 1, "a hit by a stalker breaks nothing")

	local before = #Cm.bribe_asks
	Cm.env.SendScriptCallback("on_enemy_eval", bandit, host_av, { override = false })
	check(#Cm.bribe_asks == before, "a client does not judge (the NPCs are the host's)")
end

-- ---------------------------------------------------------------- the rest of the dialog functions
print("== the NPC's logic is the host's")
do
	Cm.env.dialogs.update_npc_dialog(Cm.actor, Cm.npc)
	check(Cm.updated == nil, "update_npc_dialog does nothing on a client")
	Hm.env.dialogs.update_npc_dialog(Hm.actor, Hm.npc)
	check(Hm.updated == 1, "...and is the stock function on the host")
end

print("== a delivery ends on the client: the host stops keeping the target's squad out of offline combat")
do
	local squad = { id = 950 }
	Hm.env.get_object_squad = function(o) return o == Hm.npc and squad or nil end
	Hm.env.sim_offline_combat.task_squads[950] = true
	Hm.talked = true
	Cm.completed = 0
	Cm.env.dialogs.complete_simulation_task(Cm.actor, Cm.npc)
	pump()
	check(Cm.completed == 1, "the stock function runs on the client: the task, his pstor")
	check(Hm.env.sim_offline_combat.task_squads[950] == nil, "the host's protection of the squad is gone")
	Hm.env.sim_offline_combat.task_squads[950] = true
	Hm.talked = false
	NOW = NOW + PACE_WAIT_MS
	Cm.env.dialogs.complete_simulation_task(Cm.actor, Cm.npc)
	pump()
	check(Hm.env.sim_offline_combat.task_squads[950] == true, "without a talk with that NPC nothing changes")
	Hm.talked = true
	Hm.completed = 0
	Hm.env.dialogs.complete_simulation_task(Hm.actor, Hm.npc)
	check(Hm.completed == 1, "the host's own call is the stock one")
end

print("== the food and the trust are the player's")
do
	for i = 1, 6 do Cm.give_item(Cm.actor, "bread") end
	check(Cm.env.dialogs_zaton.zat_b103_actor_has_needed_food(Cm.actor, Cm.npc) == true, "a client with 6 bread has it, whatever the host carries")
	check(Cm.env.get_story_object("actor") == host_av, "...the story object is the host's again after the call")
	for i = 1, 6 do Hm.give_item(Hm.actor, "bread") end
	for _, o in ipairs(Cm.actor._inv) do o._sec = "pistol" end
	check(Cm.env.dialogs_zaton.zat_b103_actor_has_needed_food(Cm.actor, Cm.npc) == false, "a client without food does not have it because the host has")
	check(Hm.env.dialogs_zaton.zat_b103_actor_has_needed_food(Hm.actor, Hm.npc) == true, "the host's own count is the stock one")

	Cm.actor._id = 77
	Cm.goodwill[77] = 500
	check(Cm.env.dialogs.is_actor_trustworthy(Cm.actor, Cm.npc) == true, "his own goodwill decides (the host's is negative)")
	check(Cm.env.AC_ID == 0, "AC_ID is the host's again after the call")
	Cm.goodwill[77] = -10
	check(Cm.env.dialogs.is_actor_trustworthy(Cm.actor, Cm.npc) == false, "...and so does a bad one")
	Cm.actor._id = 0
	Hm.goodwill[0] = 300
	check(Hm.env.dialogs.is_actor_trustworthy(Hm.actor, Hm.npc) == true, "the host's own question is the stock one")
end

print("== conditions on the host's data reach the client")
do
	Cm.infos.jup_b32_anomaly_1 = true
	check(Cm.env.dialogs_jupiter.jup_b32_anomaly_has_af(Cm.actor, Cm.npc) == false, "nothing spawned in the zone: no artefact")
	Hm.zone.spawned_count = 2 -- the host's binder spawned artefacts (the client's own zone object never learns it)
	tick(Hm)
	tick(Hm)
	pump()
	check(Cm.zone.spawned_count == 0, "the client's own zone object is untouched")
	check(Cm.env.dialogs_jupiter.jup_b32_anomaly_has_af(Cm.actor, Cm.npc) == true, "the client's dialog sees the host's artefact")
	check(Cm.infos.jup_b32_anomaly_true == true and Cm.infos.jup_b32_anomaly_1 == nil, "...with the stock function's own effects")
	check(Cm.env.db.anomaly_by_name.jup_b32_anomal_zone == Cm.zone, "...and the zone table is the client's again after the call")
	Hm.zone.spawned_count = 0
	tick(Hm)
	tick(Hm)
	pump()
	Cm.infos.jup_b32_anomaly_1 = true
	check(Cm.env.dialogs_jupiter.jup_b32_anomaly_has_af(Cm.actor, Cm.npc) == false, "the zone emptied: no artefact")
	check(Hm.env.dialogs_jupiter.jup_b32_anomaly_has_af(Hm.actor, Hm.npc) == false, "the host's own question is the stock one")

	for i, id in ipairs({ 720, 721 }) do
		local npc = Hm.new_obj(id, "bandit", vec(0, 0, 0), { _stalker = true })
		Hm.env.db.storage[id] = { object = npc, pstor = { s_loot_count = i == 1 and 5 or 3 } }
		Hm.squad_members[i] = { id = id }
	end
	tick(Hm)
	tick(Hm)
	pump()
	check(Cm.env.dialogs_darkvalley.bandit_companion_task_1_complete(Cm.actor, Cm.npc) == false, "8 of 9 loot: not complete")
	check(Cm.env.dialogs_darkvalley.bandit_companion_task_1_not_complete(Cm.actor, Cm.npc) == true, "...and the other phrase is offered")
	Hm.env.db.storage[721].pstor.s_loot_count = 4
	tick(Hm)
	tick(Hm)
	pump()
	check(Cm.env.dialogs_darkvalley.bandit_companion_task_1_complete(Cm.actor, Cm.npc) == true, "9 of 9: complete")
	check(Cm.env.dialogs_darkvalley.bandit_companion_task_1_not_complete(Cm.actor, Cm.npc) == false, "...and the other phrase is not")

	local sent = count_sent(Hm, "quests.mirror")
	tick(Hm)
	tick(Hm)
	check(count_sent(Hm, "quests.mirror") == sent, "unchanged values are not sent again")
	Hm.players[#Hm.players + 1] = { id = 2, is_self = false, avatar_id = 501 }
	tick(Hm)
	tick(Hm)
	check(count_sent(Hm, "quests.mirror") > sent, "a player who comes in gets all of it")
	Hm.players[#Hm.players] = nil
end

print("== Hidden Threat: the reward table is the host's")
do
	check(Hm.m_data.slht_reward_table == Hm.env.utils_slht.reward_table, "host: the live table is where the world key reads it")
	Cm.m_data.slht_reward_table = { Task3Reward = "af_from_host" } -- what the world key brought
	Cm.env.dialogs_hidden_threat.postcond_dialog_kuznetsov_d4_1()
	check(Cm.paid == "af_from_host", "client: the dialog reads the host's roll")
	Hm.env.utils_slht.reward_table.Task3Reward = "host_roll"
	Hm.env.dialogs_hidden_threat.postcond_dialog_kuznetsov_d4_1()
	check(Hm.paid == "host_roll", "host: its own table")
end

print("== shared task vars: the counters of the dialog quests, the Warfare escort target")
do
	local HP = Hm.env.db.storage[0].pstor
	local CP = Cm.env.db.storage[0].pstor
	for _, k in ipairs({ "zat_b33_items", "jup_b200_tech_materials_found_counter", "warfare_escort_task_smart" }) do
		HP[k] = 4
		tick(Hm)
		pump()
		check(CP[k] == 4, k .. ": the host's value reaches the client")
	end
	-- a client's write goes to the host
	Cm.env.save_var(Cm.actor, "jup_b200_tech_materials_brought_counter", 3)
	pump()
	tick(Hm)
	pump()
	check(HP.jup_b200_tech_materials_brought_counter == 3, "a client's counter is the host's")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
