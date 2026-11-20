-- TZ v2 section 6.4, phase 2 weak places, round 6: the review of round 5 (temp\f2_r6\review5.md), its task probes.
--   T1  a bounty stepped to its stage_complete at its living target, then turned in            (task_stage, task_complete_state)
--   T4  a task pointing nowhere stepped to its stage_complete by quick talks with its giver     (task_stage)
--   T2  a task its dialog completes (host.DIALOG_TURN_INS), turned in at its giver right after the give; every one of the 20
--       entries refused when its dialog's condition does not hold, let through when it does   (task_complete_state)
--   T3a / T3b  the taker rewrites his running DRX task's fetch / money price through coop_tvd  (task_var_write, the turn-in;
--              round 7: "log" turns in by the live value as build 56 did, with a line; "refuse" reads the host's record)
--   S2  Server: a turn-in a moment after the dialog closed (the host's 15 s window over the map server's word)
-- Each mode: Co-op (the host's objects and talk locks) and Server (the world server: the talk partner is not reported, the rest
-- is its records and the far bodies). Run: tools\test_lua.cmd trust_r6_tasks
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party" }

-- The world of the host: ALife records, story ids, squads, smarts. alife_object answers these first.
local SE = {} -- id -> { alive, section, comm, group }
local STORY = {} -- story id -> object id
local SQUADS = {} -- squad id -> { member ids }

local function setup(M)
	local e = M.env
	local tini = e.task_manager.task_ini
	tini.r_float_ex = function(_, id, key) return tonumber(M.ini[id] and M.ini[id][key]) end
	local stock_alife = e.alife_object
	e.alife_object = function(id)
		local s = SE[id]
		if s then
			return { id = id, group_id = s.group or 65535,
				alive = function() return s.alive ~= false end,
				section_name = function() return s.section or "sim_default_stalker_2" end,
				clsid = function() return 1 end }
		end
		return stock_alife(id)
	end
	e.alife_character_community = function(se) return SE[se.id] and SE[se.id].comm or "stalker" end
	e.get_story_object_id = function(sid) return STORY[sid] end
	e.get_story_squad = function(sid)
		local id = STORY[sid]
		if not (id and SQUADS[id]) then return nil end
		return { id = id, squad_members = function()
			local i = 0
			return function()
				i = i + 1
				local m = SQUADS[id][i]
				return m and { id = m } or nil
			end
		end }
	end
	e.SIMBOARD.smarts_by_names = {}
	e.xr_conditions.has_task_target_anomaly = function() return false end
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m and m.on_game_start then m.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup(Hm)
setup(Cm)
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0, nick = "host" }, { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0, nick = "anna" }, { id = 0, is_self = false, avatar_id = 500, nick = "host" } }
boot(Hm)
boot(Cm)
local trust = Hm.env.coop_trust
check(trust ~= nil and Hm.env.coop_tasks ~= nil, "the host has coop_trust and coop_tasks")

-- talks the host saw (coop.talk_recent) and the lock he holds now (coop.talk_lock_of)
local TALK, LOCK = {}, nil
Hm.env.coop.talk_recent = function(peer, npc) return peer == 1 and TALK[npc] == true end
Hm.env.coop.talk_lock_of = function(peer) return peer == 1 and LOCK or nil end

local function failed(name) return (trust.status()[name] or { failed = 0 }).failed end
local function lines(name)
	local n = 0
	for _, l in ipairs(Hm.log) do if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end end
	return n
end
local function last_line(name)
	for i = #Hm.log, 1, -1 do
		if Hm.log[i]:find("[coop-trust] ! " .. name .. ":", 1, true) then return Hm.log[i] end
	end
	return ""
end
local function req(op, id, extra)
	Cm.env.coop.send_event("coop_tq", "op=s" .. op .. ";i=s" .. id .. (extra or ""), 0)
	pump()
end
local function task(id, ini)
	Hm.ini[id], Cm.ini[id] = ini or {}, ini or {}
end
local function give(id, giver)
	Cm.tm:give_task(id, giver)
	pump()
	return Hm.tm.task_info[id]
end
local function turned(tsk)
	local yes = tsk ~= nil and tsk.forced_status == "complete"
	if tsk then tsk.forced_status = nil end
	return yes
end
local function drop(id)
	Hm.tm.task_info[id], Hm.engine_tasks[id], Cm.tm.task_info[id] = nil, nil, nil
end
-- an item leaves its holder (the harness's alife_release_id compares items with ==, which a game object has not)
local function take_away(item)
	local owner = item._parent
	for i, it in ipairs(owner and owner._inv or {}) do
		if rawequal(it, item) then table.remove(owner._inv, i) break end
	end
	Hm.objects[item._id] = nil
end
local function hps() return Hm.env.db.storage[0].pstor end
local giver777 = Hm.new_obj(777, "sim_default_stalker_trader", vec(2, 0, 0), { _stalker = true })

local function server(talking)
	Hm.env.coop.is_dedicated = talking and function() return true end or nil
	Hm.env.coop_quests_core.is_far_peer = function(p) return talking ~= nil and p == 1 end
	Hm.env.coop.levels = talking and { talking = function(p) return p == 1 and talking() end } or nil
end

-------------------------------------------------------------------------------
print("== R6 blocker 1, the review's probe T1: a bounty stepped to its stage_complete at its living target")
do
	trust.reset_for_test({ default = "log", task_stage = "refuse", task_complete = "refuse", task_complete_talk = "refuse",
		task_complete_state = "refuse" })
	task("bty_t", { status_functor = "bounty_task", target_functor = "general_bounty_task", stage_complete = "1",
		on_job_descr = "%=setup_bounty_task(bty_t:true:false:monolith)%" })
	Hm.env.task_functor.general_bounty_task = function(id, field, p, tsk)
		if tsk.stage == 1 then return tsk.task_giver_id end
		return Hm.env.axr_task_manager.bounties_by_id[id]
	end
	-- a neutral target (the stock picks one in 1 of 10): he can talk to it
	SE[4242] = { alive = true, comm = "stalker", group = 4240 }
	Hm.new_obj(4242, "sim_default_stalker_2", vec(8, 0, 0), { _stalker = true })
	Cm.env.axr_task_manager.bounties_by_id.bty_t = 4242 -- his dialog's setup_bounty_task (no offer: DRX, a refused offer)
	Cm.env.save_var(Cm.actor, "bty_t", { target_id = 4242, target_comm = "stalker", lvl_task = "l01_escape" })
	local tsk = give("bty_t", 777)
	check(tsk ~= nil and Hm.env.axr_task_manager.bounties_by_id.bty_t == 4242 and lines("task_give_offer") == 0,
		"(given; his target is a living stalker of the task's factions: a pick its setup makes, no line)")
	tsk.target_functor = "general_bounty_task" -- (the stock object reads it from the ini)
	TALK[4242], TALK[777] = true, true
	LOCK = 4242
	tick(Hm)
	req("stage", "bty_t", ";st=n1;sp=n4242")
	check(tsk.stage == 0 and failed("task_stage") == 1 and last_line("task_stage"):find("alive", 1, true) ~= nil,
		"refuse: his step 0 -> 1 (its stage_complete) in a talk with the living target: refused, the line says why")
	LOCK = 777
	tick(Hm)
	req("complete", "bty_t", ";sp=n777")
	check(not turned(tsk), "refuse: the turn-in at the giver then: refused (stage 0)")
	check(Hm.env.coop_tasks.host_state_verdict("bty_t", 2, 1, false, false, true) == false, "(the engine path refuses it too)")
	-- a client's step that reached stage 1 in "log" (let through) still is no objective: the turn-in asks the target dead
	tsk.stage = 1
	req("complete", "bty_t", ";sp=n777")
	check(not turned(tsk) and last_line("task_complete_state"):find("alive", 1, true) ~= nil,
		"refuse: a bounty at its stage_complete whose target lives (a stepped stage): refused")
	tsk.stage = 0
	-- log (build 57): the step goes through as before, with a line
	trust.reset_for_test({ default = "log" })
	LOCK = 4242
	tick(Hm)
	req("stage", "bty_t", ";st=n1;sp=n4242")
	check(tsk.stage == 1 and lines("task_stage") >= 2, "log: his step goes through as before, logged")
	tsk.stage = 0
	-- honest: the target died; the host's own functor sets stage 1 and the turn-in at the giver goes through
	trust.reset_for_test({ default = "log", task_stage = "refuse", task_complete_talk = "refuse", task_complete_state = "refuse" })
	SE[4242].alive = false
	tsk.stage = 1
	LOCK = 777
	tick(Hm)
	local n0 = failed("task_complete_state")
	req("complete", "bty_t", ";sp=n777")
	check(turned(tsk) and failed("task_complete_state") == n0, "honest: the target is dead here: the turn-in goes through")
	-- (a client's step at a dead target's place is the host's own condition too)
	tsk.stage = 0
	LOCK = 4242
	tick(Hm)
	req("stage", "bty_t", ";st=n1;sp=n4242")
	check(tsk.stage == 1, "a step to stage_complete when the target is dead here: taken")
	-- Server: the world server's ALife records answer the same (a death on a map server reaches them through its report)
	tsk.stage = 1
	SE[4242].alive = true
	server(function() return true end)
	req("complete", "bty_t", ";sp=n777")
	check(not turned(tsk), "Server: the target lives in the world server's records: refused")
	SE[4242].alive = false
	req("complete", "bty_t", ";sp=n777")
	check(turned(tsk), "Server: its death is in the world server's records: the turn-in goes through")
	server()
	drop("bty_t")
	LOCK = nil
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
print("== R6 blocker 1, the review's probe T4: a task pointing nowhere, stage_complete 3, three steps with its giver")
do
	trust.reset_for_test({ default = "log", task_stage = "refuse", task_complete_state = "refuse" })
	task("st3_t", { status_functor = "fate_task", stage_complete = "3" })
	local tsk = give("st3_t", 777)
	TALK[777] = true
	local stock_lock = Hm.env.coop.talk_lock_of
	Hm.env.coop.talk_lock_of = nil -- (no talk facts: one step per talk is not what this probe looks at)
	for i = 1, 3 do req("stage", "st3_t", ";st=n" .. i .. ";sp=n777") end
	check(tsk.stage == 2 and failed("task_stage") == 1 and last_line("task_stage"):find("stage_complete", 1, true) ~= nil,
		"refuse: steps 1 and 2 taken, the step to its stage_complete 3 refused (the host's own check: still running)")
	req("complete", "st3_t", ";sp=n777")
	check(not turned(tsk), "refuse: and the turn-in at stage 2: refused")
	tsk.last_check_task = "complete" -- the host's own check found it done
	req("stage", "st3_t", ";st=n3;sp=n777")
	check(tsk.stage == 3, "the host's own check says done: the step to stage_complete is taken")
	Hm.env.coop.talk_lock_of = stock_lock
	drop("st3_t")
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
print("== R6 blocker 6, the review's probe T2: the owl's PDA task turned in at its giver right after the give")
do
	trust.reset_for_test({ default = "log", task_complete = "refuse", task_complete_talk = "refuse", task_complete_state = "refuse" })
	task("mar_base_owl_stalker_trader_task_1", {})
	local tsk = give("mar_base_owl_stalker_trader_task_1", 777)
	tsk.status_functor = nil
	TALK[777] = true
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n777")
	check(not turned(tsk) and failed("task_complete_state") == 1, "refuse: at its giver at stage 0, the PDA nobody's: refused")
	-- honest: the PDA with the group, the talk with Nimble
	STORY.esc_2_12_stalker_nimble = 790
	Hm.new_obj(790, "esc_2_12_stalker_nimble", vec(3, 0, 0), { _stalker = true })
	TALK[790] = true
	local pda = Hm.give_item(proxy, "mar_base_owl_stalker_trader_task_1_pda")
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n777")
	check(not turned(tsk) and failed("task_complete_state") == 2, "the PDA with the group, but at the owl (its giver): refused")
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n790")
	check(turned(tsk) and failed("task_complete_state") == 2 and failed("task_complete_talk") == 0,
		"at Nimble, the PDA with the group: ok (task_complete_talk takes the dialog's own NPC)")
	-- his dialog hands the PDA over in the action that completes the task: the release may reach the host first
	tick(Hm) -- the scan saw the group hold it
	take_away(pda)
	NOW = NOW + 2000
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n790")
	check(turned(tsk), "the PDA released a moment before the turn-in (held 2 s ago): ok")
	NOW = NOW + 16000
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n790")
	check(not turned(tsk), "16 s after the group last held it: refused")
	-- log (build 57): through as before, a line
	trust.reset_for_test({ default = "log" })
	req("complete", "mar_base_owl_stalker_trader_task_1", ";sp=n777")
	check(turned(tsk) and lines("task_complete_state") >= 3, "log: through as before, logged")
	drop("mar_base_owl_stalker_trader_task_1")
end

-------------------------------------------------------------------------------
print("== R6 blocker 6: every entry of host.DIALOG_TURN_INS, its dialog's condition (Co-op)")
-- the honest state of each dialog's condition: story ids of its NPC / squad, the items, the infos, the stage, the escort's
-- smart, the companions' loot
local NEXT_ID = 900
local function story_obj(sid, squad_of)
	if STORY[sid] then return STORY[sid] end
	NEXT_ID = NEXT_ID + 1
	STORY[sid] = NEXT_ID
	if squad_of then
		-- a squad: a member NPC whose record names it
		NEXT_ID = NEXT_ID + 1
		SQUADS[STORY[sid]] = { NEXT_ID }
		SE[NEXT_ID] = { alive = true, group = STORY[sid] }
		Hm.new_obj(NEXT_ID, "member_of_" .. sid, vec(4, 0, 0), { _stalker = true })
	else
		Hm.new_obj(NEXT_ID, sid, vec(4, 0, 0), { _stalker = true })
	end
	return STORY[sid]
end
local function member_of(sid) return SQUADS[STORY[sid]][1] end

local ENTRIES = {
	lttz_ll_answers = { npc = "lost_stalker_strelok", info = "lttz_ll_crucible_task_done" },
	lttz_hb_task_1_2_recruit = { npc = "jup_depo_isg_leader", items = { "hb_isg_dushman_intel" } },
	lttz_hb_task_2_1_guarded_secrets = { stage = 2, items = { "jupiter_documents" } },
	lttz_hb_task_2_2_breakthrough = { squad = "jup_depo_isg_leader_squad", items = { "main_story_6_jup_ug_documents" } },
	lttz_hb_task_3_8_handle_docs = { npc = "jup_depo_isg_leader", items = { "main_story_1_quest_case",
		"main_story_2_lab_x18_documents", "main_story_3_lab_x16_documents", "main_story_4_lab_x10_documents",
		"main_story_5_lab_x8_documents" } },
	lttz_hb_task_4_1_crossfire = { squad = "jup_depo_isg_leader_squad", items = { "strelok_pendrive" } },
	yan_stalker_sakharov_psi_helmet_upgrade = { npc = "yan_stalker_sakharov" },
	barrier_defense_monolith = { info = "barrier_defense_monolith_finished" },
	barrier_defense_zombie = { info = "barrier_defense_zombie_finished" },
	bar_informator_mlr_task_the_living_fire = { npc = "yan_stalker_sakharov", info = "the_living_fire_prometheus_killed_gg" },
	snitch_top_10_task = { stage = 10 },
	mar_base_owl_stalker_trader_task_1 = { npc = "esc_2_12_stalker_nimble", items = { "mar_base_owl_stalker_trader_task_1_pda" } },
	sim_default_csky_trader_task_1 = { npc = "esc_2_12_stalker_nimble", items = { "mar_base_owl_stalker_trader_task_1_pda" } },
	mar_base_owl_stalker_trader_task_3 = { squad = "ecolog_companion_task_1", near = "mar_smart_terrain_base" },
	sim_default_csky_trader_task_3 = { squad = "ecolog_companion_task_1", near = "mar_smart_terrain_base" },
	sim_default_ecolog_trader_task_1 = { squad = "ecolog_companion_task_2", near = "jup_b41" },
	yan_stalker_sakharov_task_2 = { squad = "ecolog_companion_task_2", near = "jup_b41" },
	jup_b6_scientist_tech_task_1 = { squad = "ecolog_companion_task_2", near = "jup_b41" },
	sim_default_bandit_trader_task_4 = { squad = "bandit_companion_task_1", loot = true },
	val_smart_terrain_7_4_bandit_trader_stalker_task_3 = { squad = "bandit_companion_task_1", loot = true },
}
local n_entries = 0
for _ in pairs(ENTRIES) do n_entries = n_entries + 1 end
check(n_entries == 20, "the 20 entries of the round 5 review")

local function honest(id, e)
	local sp = 777
	if e.npc then sp = story_obj(e.npc) end
	if e.squad then
		story_obj(e.squad, true)
		sp = member_of(e.squad)
	end
	TALK[sp] = true
	local held = {}
	for _, sec in ipairs(e.items or {}) do held[#held + 1] = Hm.give_item(proxy, sec) end
	if e.info then Hm.infos[e.info] = true end
	if e.near then
		Hm.env.SIMBOARD.smarts_by_names[e.near] = { position = vec(100, 0, 0) }
		proxy._pos = vec(110, 0, 0)
	end
	if e.loot then
		for i, m in ipairs(SQUADS[STORY[e.squad]]) do
			local o = Hm.objects[m]
			Hm.env.db.storage[m] = { object = o, pstor = { s_loot_count = 5 * i } }
		end
		-- a second member: 5 + 10 looted
		local extra = NEXT_ID + 1
		NEXT_ID = extra
		table.insert(SQUADS[STORY[e.squad]], extra)
		Hm.env.db.storage[extra] = { object = Hm.new_obj(extra, "member2", vec(4, 0, 0)), pstor = { s_loot_count = 5 } }
	end
	return sp, held
end
local function undo(e, held)
	for _, it in ipairs(held) do if Hm.objects[it._id] then take_away(it) end end
	if e.info then Hm.infos[e.info] = nil end
	proxy._pos = vec(4, 0, 0)
end

do
	trust.reset_for_test({ default = "log", task_complete = "refuse", task_complete_talk = "refuse", task_complete_state = "refuse" })
	local refused_at_giver, honest_ok, short = 0, 0, {}
	local ids = {}
	for id in pairs(ENTRIES) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local e = ENTRIES[id]
		task(id, { stage_complete = e.stage and tostring(e.stage) or nil })
		local tsk = give(id, 777)
		tsk.status_functor = nil
		TALK[777] = true
		req("complete", id, ";sp=n777")
		if not turned(tsk) then refused_at_giver = refused_at_giver + 1 else short[#short + 1] = id .. " (at its giver)" end
		local sp, held = honest(id, e)
		if e.stage then tsk.stage = e.stage end
		req("complete", id, ";sp=n" .. sp)
		if turned(tsk) then honest_ok = honest_ok + 1 else short[#short + 1] = id .. " (honest: " .. last_line("task_complete_state") .. ")" end
		undo(e, held)
		drop(id)
	end
	check(refused_at_giver == 20, "all 20: at its giver, its dialog's condition not met: refused (" .. refused_at_giver .. ")")
	check(honest_ok == 20, "all 20: its dialog's condition met: let through (" .. honest_ok .. ") " .. table.concat(short, "; "))
	-- what each condition refuses on its own
	local function one(id, spoil, what)
		local e = ENTRIES[id]
		task(id, { stage_complete = e.stage and tostring(e.stage) or nil })
		local tsk = give(id, 777)
		tsk.status_functor = nil
		local sp, held = honest(id, e)
		if e.stage then tsk.stage = e.stage end
		local restore = spoil(tsk, held)
		req("complete", id, ";sp=n" .. sp)
		check(not turned(tsk), what .. ": " .. last_line("task_complete_state"))
		if restore then restore() end
		undo(e, held)
		drop(id)
	end
	one("lttz_ll_answers", function() Hm.infos.lttz_ll_crucible_task_done = nil end, "Strelok's answers without the crucible done")
	one("lttz_hb_task_3_8_handle_docs", function(_, held) take_away(held[5]) end,
		"the handle-docs task, the fifth document missing")
	one("snitch_top_10_task", function(tsk) tsk.stage = 9 end, "the top 10 at stage 9")
	one("jup_b6_scientist_tech_task_1", function() proxy._pos = vec(400, 0, 0) end, "the ecologist's escort 300 m from jup_b41")
	-- (round 7: the pending anomaly is the host's own record of task_target_anomaly, which its on_init writes)
	one("jup_b6_scientist_tech_task_1", function()
		Hm.env.save_var(Hm.actor, "task_target_anomaly", "jup_anomaly_x")
		return function() Hm.env.save_var(Hm.actor, "task_target_anomaly", nil) end
	end, "the escort, its anomaly still to be analyzed")
	one("sim_default_bandit_trader_task_4", function()
		for _, m in ipairs(SQUADS[STORY.bandit_companion_task_1]) do Hm.env.db.storage[m].pstor.s_loot_count = 1 end
	end, "the bandit escort, its companions looted less than 9")
	-- the warfare escort's smart, when one is set (dialogs_marsh / dialogs_jupiter read it; round 7: only in warfare, where
	-- setup_companion_task writes it)
	do
		local id = "sim_default_ecolog_trader_task_1"
		task(id, {})
		local tsk = give(id, 777)
		tsk.status_functor = nil
		local sp, held = honest(id, ENTRIES[id])
		Hm.env.WARFARE = true
		Hm.env.save_var(Hm.actor, "warfare_escort_task_smart", "war_smart_x")
		Hm.env.SIMBOARD.smarts_by_names.war_smart_x = { position = vec(1000, 0, 0) }
		req("complete", id, ";sp=n" .. sp)
		check(not turned(tsk), "the warfare escort's smart is set: 890 m from it, refused")
		proxy._pos = vec(1010, 0, 0)
		req("complete", id, ";sp=n" .. sp)
		check(turned(tsk), "at the warfare escort's smart: ok")
		Hm.env.save_var(Hm.actor, "warfare_escort_task_smart", nil)
		Hm.env.WARFARE = nil
		undo(ENTRIES[id], held)
		drop(id)
	end
	trust.reset_for_test({ default = "log" })
end

print("== R6 blocker 6, Server: the partner is not reported; the world server's view of the rest decides")
do
	trust.reset_for_test({ default = "log", task_complete = "refuse", task_complete_talk = "refuse", task_complete_state = "refuse" })
	server(function() return true end)
	local id = "lttz_hb_task_4_1_crossfire"
	task(id, {})
	local tsk = give(id, 777)
	tsk.status_functor = nil
	req("complete", id, ";sp=n777")
	check(not turned(tsk), "Server: in some dialog, nobody holds the pendrive: refused")
	local pen = Hm.give_item(proxy, "strelok_pendrive")
	req("complete", id, ";sp=n777")
	check(turned(tsk), "Server: in some dialog (not known with whom), the pendrive with the group: ok (the talk is the known limit)")
	take_away(pen)
	drop(id)
	id = "barrier_defense_zombie"
	task(id, {})
	tsk = give(id, 777)
	tsk.status_functor = nil
	req("complete", id, ";sp=n777")
	check(not turned(tsk), "Server: the barrier, the world has no barrier_defense_zombie_finished: refused")
	Hm.infos.barrier_defense_zombie_finished = true
	req("complete", id, ";sp=n777")
	check(turned(tsk), "Server: the barrier, its attackers are dead (the info): ok")
	Hm.infos.barrier_defense_zombie_finished = nil
	drop(id)
	server()
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
-- the fetch list tasks_fetch reads (items\settings\fetch_list.ltx)
local FETCH = { fetch_list = { "artefacts", "supplies", "drink", "weapons", "weapons_novice" },
	artefacts = { "af_gold_fish", "af_medusa" }, supplies = { "bread", "salt" }, drink = { "vodka" },
	weapons = { "wpn_ak74" }, weapons_novice = { "wpn_pm" } }
local function fetch_ini()
	return {
		section_exist = function(_, s) return FETCH[s] ~= nil end,
		line_count = function(_, s) return #(FETCH[s] or {}) end,
		r_line_ex = function(_, s, i) local v = FETCH[s] and FETCH[s][i + 1] return true, v, "" end,
	}
end
Hm.env.ini_file = function(name) if name == "items\\settings\\fetch_list.ltx" then return fetch_ini() end end

print("== R6 blocker 3, the review's probe T3a: the taker rewrites his running DRX fetch through coop_tvd")
do
	task("drx_sl_rw_t", { fetch_descr = "drx_sl_rw_t_descr", fetch_func = "%=setup_fetch_task(drx_sl_rw_t_fetch:artefacts:1:1)%",
		status_functor = "actor_has_fetch_item" })
	-- his DRX dialog's own pick (shared prefix: coop_tvd at once, the give carries it again)
	Cm.env.save_var(Cm.actor, "drx_sl_rw_t_fetch", "af_gold_fish")
	Cm.env.save_var(Cm.actor, "drx_sl_rw_t_fetch_count", 1)
	pump()
	local tsk = give("drx_sl_rw_t", 777)
	check(tsk ~= nil and hps().drx_sl_rw_t_fetch == "af_gold_fish" and lines("task_give_offer") == 0,
		"(an honest DRX fetch, no offer: a pick of its setup_fetch_task, the host's fact, no line)")
	TALK[777] = true
	trust.reset_for_test({ default = "refuse" })
	Cm.env.save_var(Cm.actor, "drx_sl_rw_t_fetch", "bread")
	pump()
	check(hps().drx_sl_rw_t_fetch == "af_gold_fish" and last_line("task_var_write"):find("his own task", 1, true) ~= nil,
		"refuse: the taker's own write of his running task's fetch: refused, the line says it is his own task")
	Hm.actor._inv = {}
	Hm.give_item(proxy, "bread")
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(not turned(tsk), "refuse: turned in with one bread: refused")
	-- log (build 57): his write goes through as before, with a line; round 7: the turn-in reads the live pstor as build 56 did (with a
	-- line naming both values), only "refuse" of task_var_write reads the host's own record
	trust.reset_for_test({ default = "log" })
	Cm.env.save_var(Cm.actor, "drx_sl_rw_t_fetch", "bread")
	pump()
	check(hps().drx_sl_rw_t_fetch == "bread" and lines("task_var_write") >= 1, "log: written as before, logged")
	local n0 = lines("task_var_write")
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(turned(tsk) and lines("task_var_write") == n0 + 1 and last_line("task_var_write"):find("af_gold_fish", 1, true) ~= nil
		and last_line("task_var_write"):find("bread", 1, true) ~= nil,
		"log: the turn-in with one bread goes through as in build 56 (the live value), the line names both: " .. last_line("task_var_write"))
	trust.reset_for_test({ default = "log", task_var_write = "refuse" })
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(not turned(tsk), "task_var_write refuse: the turn-in with one bread asks the host's own record (af_gold_fish): refused")
	local af = Hm.give_item(proxy, "af_gold_fish")
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(turned(tsk), "the artefact the host recorded with the group: ok")
	take_away(af)
	-- the record survives the host's save and load: the client's value is no fact after it either
	local m = {}
	fire(Hm, "save_state", m)
	fire(Hm, "load_state", m)
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(not turned(tsk), "refuse, after the host's save and load: the bread he wrote is no fact, refused")
	trust.reset_for_test({ default = "log" })
	n0 = lines("task_var_write")
	req("complete", "drx_sl_rw_t", ";sp=n777")
	check(turned(tsk) and lines("task_var_write") == n0 + 1, "log, after the save and load: the live value as in build 56, logged")
	drop("drx_sl_rw_t")
end

print("== R6 blocker 3, the review's probe T3b: the taker writes his DRX money task's price to 0")
do
	trust.reset_for_test({ default = "log" })
	task("drx_sl_m_t", { status_functor = "drx_sl_money_task_status" })
	Hm.init_fx = { drx_sl_m_t = function() Hm.env.save_var(Hm.actor, "drx_sl_m_t_fetch", 50000) end } -- its on_init's pstor_set
	local tsk = give("drx_sl_m_t", 777)
	Hm.init_fx = nil
	local balance = 100
	Hm.env.coop.money_of = function(p) return p == 1 and balance or nil end
	req("complete", "drx_sl_m_t", ";sp=n777")
	check(not turned(tsk), "a price of 50000 with 100: refused")
	Cm.env.save_var(Cm.actor, "drx_sl_m_t_fetch", 0)
	pump()
	check(hps().drx_sl_m_t_fetch == 0 and lines("task_var_write") >= 1, "log: his write of the price went through, logged")
	req("complete", "drx_sl_m_t", ";sp=n777")
	check(turned(tsk) and last_line("task_var_write"):find("50000", 1, true) ~= nil,
		"log (round 7): the turn-in reads the live price as build 56 did (0), the line names the host's 50000")
	trust.reset_for_test({ default = "log", task_var_write = "refuse" })
	req("complete", "drx_sl_m_t", ";sp=n777")
	check(not turned(tsk), "task_var_write refuse: the turn-in asks the host's price (50000): refused")
	trust.reset_for_test({ default = "refuse" })
	Cm.env.save_var(Cm.actor, "drx_sl_m_t_fetch", 1)
	pump()
	check(hps().drx_sl_m_t_fetch == 0, "refuse: his next write is refused (the pstor keeps what log let through)")
	balance = 60000
	req("complete", "drx_sl_m_t", ";sp=n777")
	check(turned(tsk), "60000 against the host's 50000: ok")
	drop("drx_sl_m_t")
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
print("== R6 S2, Server: a turn-in a moment after the dialog closed (the host's window over the map server's word)")
do
	trust.reset_for_test({ default = "log", task_complete_talk = "refuse", task_fail = "refuse" })
	task("gav_t", {})
	local tsk = give("gav_t", 777)
	tsk.status_functor = nil
	tsk.last_check_task = "complete" -- its state is not what this looks at
	local in_dialog = true
	server(function() return in_dialog end)
	tick(Hm) -- the scan sees him in a dialog
	in_dialog = false
	NOW = NOW + 1000
	req("complete", "gav_t", ";sp=n777")
	check(turned(tsk) and failed("task_complete_talk") == 0, "1 s after the dialog closed (z_gavrilenko_tasks_fix): ok")
	NOW = NOW + 15000
	tick(Hm)
	req("complete", "gav_t", ";sp=n777")
	check(not turned(tsk) and failed("task_complete_talk") == 1, "16 s after: refused")
	-- the scan keeps the time even with no request in between; a player who left is forgotten
	in_dialog = true
	tick(Hm)
	in_dialog = false
	NOW = NOW + 5000
	tick(Hm)
	req("complete", "gav_t", ";sp=n777")
	check(turned(tsk), "a dialog the scan saw 5 s ago: ok")
	server()
	drop("gav_t")
	trust.reset_for_test({ default = "log" })
end

print("== R6: malformed steps and turn-ins raise no Lua error")
do
	task("mal_t", { status_functor = "bounty_task", stage_complete = "1" })
	local tsk = give("mal_t", 777)
	trust.reset_for_test({ default = "refuse" })
	local n0 = #Hm.log
	for _, extra in ipairs({ ";sp=s%25s%25n", ";sp=n1e309", ";sp=n-1", ";sp=b1", ";st=snan;sp=n777", ";st=n1e309", ";st=n1;sp=n0" }) do
		req("complete", "mal_t", extra)
		req("stage", "mal_t", extra)
		turned(tsk)
	end
	local errs = 0
	for i = n0 + 1, #Hm.log do
		if Hm.log[i]:find("rror", 1, true) and not Hm.log[i]:find("[coop-trust]", 1, true) then errs = errs + 1 end
	end
	check(errs == 0 and tsk.stage == 0, "no Lua error, no stage moved (" .. errs .. ")")
	drop("mal_t")
	trust.reset_for_test({ default = "log" })
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
