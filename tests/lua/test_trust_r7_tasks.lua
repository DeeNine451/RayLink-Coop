-- TZ v2 section 6.4, phase 2 weak places, round 7: the review of round 6 (temp\f2_r7\review6.md), its task findings.
--   P1    a turn-in judged by facts the host has no record of (a load whose list lacks the key) or a client rewrote: "log" goes as
--         build 56 did (the live pstor) with a task_var_write line; only "refuse" reads the host's record (host.fact_of / fact_line)
--   P-SEC an id a client names (t.g, t.sp, t.bt) is a whole number 1..65534 before any engine lookup; a counter delta is bounded
--   P-ESC the escorts' end: warfare_escort_task_smart and the pending anomaly as the host's own logic wrote them (a client's coop_tvd
--         write moves nothing), a smart not known here is no end, the companions alive (Server: the only check of them)
--   P-PSI the psi helmet upgrade: stage 2, or its give and turn-in in one dialog action (the paid good helmet)
--   P-INFO the barrier: the host's own record of its attackers too (an info a client gives the engine applies)
--   talk  a turn-in outside any dialog (bind_heli, a client's condlist) when the host's own check says done
--   Server limits that stay open (P-OWL, P-BANDIT): recorded as such
-- Each in Co-op (the host's objects and talk locks) and Server (the world server: the partner is not reported; its records, the far
-- bodies). Run: tools\test_lua.cmd trust_r7_tasks
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party" }
local SE, STORY, SQUADS = {}, {}, {}

local function setup(M)
	local e = M.env
	e.task_manager.task_ini.r_float_ex = function(_, id, key) return tonumber(M.ini[id] and M.ini[id][key]) end
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
local TALK = {}
Hm.env.coop.talk_recent = function(peer, npc) return peer == 1 and TALK[npc] == true end
Hm.env.coop.talk_lock_of = function() return nil end
Hm.new_obj(777, "sim_default_stalker_trader", vec(2, 0, 0), { _stalker = true })
TALK[777] = true

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
local function task(id, ini) Hm.ini[id], Cm.ini[id] = ini or {}, ini or {} end
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
local function hps() return Hm.env.db.storage[0].pstor end
local function take_all(sec)
	for i = #proxy._inv, 1, -1 do
		if proxy._inv[i]._sec == sec then
			Hm.objects[proxy._inv[i]._id] = nil
			table.remove(proxy._inv, i)
		end
	end
end
local function server(on, talking)
	if on then
		Hm.env.coop_quests_core.is_far_peer = function(p) return p == 1 end
		Hm.env.coop.levels = { talking = function(p) return p == 1 and (talking == nil or talking()) end }
	else
		Hm.env.coop_quests_core.is_far_peer = function() return false end
		Hm.env.coop.levels = nil
	end
end
local MODES = { "coop", "server" }
local NEXT_ID = 900
local function story_obj(sid, is_squad)
	if STORY[sid] then return STORY[sid] end
	NEXT_ID = NEXT_ID + 1
	STORY[sid] = NEXT_ID
	if is_squad then
		NEXT_ID = NEXT_ID + 1
		SQUADS[STORY[sid]] = { NEXT_ID }
		SE[NEXT_ID] = { alive = true, group = STORY[sid] }
		Hm.new_obj(NEXT_ID, "member_of_" .. sid, vec(4, 0, 0), { _stalker = true })
	else
		Hm.new_obj(NEXT_ID, sid, vec(4, 0, 0), { _stalker = true })
	end
	return STORY[sid]
end
-- the host's save without `key` in its list of own facts, loaded again: the host has no record of that value
local function forget_record(key)
	local m = {}
	fire(Hm, "save_state", m)
	local kept = {}
	for _, k in ipairs(m.coop_task_facts or {}) do if k ~= key then kept[#kept + 1] = k end end
	m.coop_task_facts = kept
	fire(Hm, "load_state", m)
end

-------------------------------------------------------------------------------
print("== R7 P1: a fetch turn-in whose item the host has no record of (a load whose list lacks the key)")
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "log" })
	server(mode == "server")
	local id = "drx_sl_nr_" .. mode
	task(id, { fetch_func = "%=setup_fetch_task(" .. id .. "_fetch:artefacts:1:1)%", status_functor = "actor_has_fetch_item" })
	Cm.env.save_var(Cm.actor, id .. "_fetch", "af_gold_fish")
	Cm.env.save_var(Cm.actor, id .. "_fetch_count", 1)
	pump()
	local tsk = give(id, 777)
	check(tsk ~= nil and hps()[id .. "_fetch"] == "af_gold_fish", mode .. ": (given, the artefact is the host's fact)")
	forget_record(id .. "_fetch")
	Hm.give_item(proxy, "af_gold_fish")
	local n0 = lines("task_var_write")
	req("complete", id, ";sp=n777")
	check(turned(tsk) and lines("task_var_write") == n0 + 1 and last_line("task_var_write"):find("nothing", 1, true) ~= nil,
		mode .. ", log: the artefact with the group: turned in as in build 56 (the live value), one task_var_write line: "
		.. last_line("task_var_write"))
	-- the engine path (host_state_verdict) says the same in "log"
	tsk.last_check_task = "complete"
	n0 = lines("task_complete")
	check(Hm.env.coop_tasks.host_state_verdict(id, 2, 1, false, false, true) == true and lines("task_complete") == n0,
		mode .. ", log: the engine path takes it with no task_complete line")
	tsk.last_check_task = nil
	trust.reset_for_test({ default = "log", task_var_write = "refuse" })
	req("complete", id, ";sp=n777")
	check(not turned(tsk) and failed("task_var_write") == 1, mode .. ", task_var_write refuse: the item is a client's word: refused, a line")
	take_all("af_gold_fish")
	drop(id)
	hps()[id .. "_fetch"], hps()[id .. "_fetch_count"] = nil, nil
end
server(false)

print("== R7 P1: a DRX money task whose price the host has no record of")
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "log" })
	server(mode == "server")
	local id = "drx_sl_mn_" .. mode
	task(id, { status_functor = "drx_sl_money_task_status", on_init = "%=pstor_set(" .. id .. "_fetch:5000)%" })
	Hm.init_fx = { [id] = function() Hm.env.save_var(Hm.actor, id .. "_fetch", 5000) end }
	local tsk = give(id, 777)
	Hm.init_fx = nil
	local balance = 6000
	Hm.env.coop.money_of = function(p) return p == 1 and balance or nil end
	forget_record(id .. "_fetch")
	local n0 = lines("task_var_write")
	req("complete", id, ";sp=n777")
	check(turned(tsk) and lines("task_var_write") == n0 + 1,
		mode .. ", log: 6000 against the live price 5000: turned in as in build 56, one task_var_write line")
	balance = 100
	req("complete", id, ";sp=n777")
	check(not turned(tsk), mode .. ", log: 100 against the live price 5000: refused as in build 56")
	balance = 6000
	trust.reset_for_test({ default = "log", task_var_write = "refuse" })
	req("complete", id, ";sp=n777")
	check(not turned(tsk), mode .. ", task_var_write refuse: a price that is a client's word: refused")
	drop(id)
	hps()[id .. "_fetch"] = nil
	Hm.env.coop.money_of = nil
end
server(false)
trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
print("== R7 P-SEC: an id a client names is a whole number 1..65534 before any engine lookup")
do
	trust.reset_for_test({ default = "refuse" })
	local id = "sec_g_t"
	task(id, { fetch_func = "%=setup_fetch_task(" .. id .. "_fetch:artefacts:1:1)%", status_functor = "actor_has_fetch_item",
		on_job_descr = "%=setup_bounty_task(" .. id .. ":true:false:monolith)%" })
	local seen = {}
	local function bad(x) return type(x) == "number" and not (x >= 0 and x < 65535 and x == math.floor(x)) end
	local obi, al = Hm.env.level.object_by_id, Hm.env.alife_object
	Hm.env.level.object_by_id = function(x)
		if bad(x) then seen[#seen + 1] = tostring(x) end
		return obi(x)
	end
	Hm.env.alife_object = function(x)
		if bad(x) then seen[#seen + 1] = "alife " .. tostring(x) end
		return al(x)
	end
	local gave = 0
	for _, g in ipairs({ "n1e309", "n-1e309", "n70000.5", "n-3", "n0.25", "snan" }) do
		for _, extra in ipairs({ ";g=" .. g, ";g=n777;sp=" .. g, ";g=n777;bt=" .. g }) do
			Cm.env.coop.send_event("coop_tq", "op=sgive;i=s" .. id .. extra .. ";v=s" .. id .. "_fetch%3Dsbread", 0)
			pump()
			if Hm.tm.task_info[id] then gave = gave + 1 end
			drop(id)
			hps()[id .. "_fetch"], hps()[id .. "_fetch_count"], hps()[id] = nil, nil, nil
		end
		for _, op in ipairs({ "complete", "stage", "fail" }) do req(op, id, ";st=n1;sp=" .. g) end
	end
	Hm.env.level.object_by_id, Hm.env.alife_object = obi, al
	check(#seen == 0, "no engine lookup gets an id that is not 0..65534: " .. table.concat(seen, ", "))
	check(gave == 18, "a bad id is no id: the gives still run, as gives naming none (" .. gave .. " of 18)")
	-- a counter's delta through coop_tvd
	hps().drx_sl_task_giver_x = 2
	for _, d in ipairs({ "n1e309", "n-1e309", "n0.5", "n5000" }) do
		Cm.env.coop.send_event("coop_tvd", "k=sdrx_sl_task_giver_x;op=sadd;d=" .. d, 0)
		pump()
	end
	check(hps().drx_sl_task_giver_x == 2, "an unbounded or fractional counter delta changes nothing")
	Cm.env.coop.send_event("coop_tvd", "k=sdrx_sl_task_giver_x;op=sadd;d=n1", 0)
	pump()
	check(hps().drx_sl_task_giver_x == 3, "a delta of one step goes as before")
	hps().drx_sl_task_giver_x = nil
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
print("== R7 P-ESC: the escort's end as the host's own logic wrote it")
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "refuse" })
	server(mode == "server")
	local id = "jup_b6_scientist_tech_task_1"
	task(id, {})
	local tsk = give(id, 777)
	tsk.status_functor = nil
	story_obj("ecolog_companion_task_2", true)
	local member = SQUADS[STORY.ecolog_companion_task_2][1]
	TALK[member] = true
	Hm.env.SIMBOARD.smarts_by_names.jup_b41 = { position = vec(100, 0, 0) }
	Hm.env.SIMBOARD.smarts_by_names.here_smart = { position = vec(410, 0, 0) }
	proxy._pos = vec(400, 0, 0) -- 300 m from jup_b41
	req("complete", id, ";sp=n" .. member)
	check(not turned(tsk), mode .. ": 300 m from jup_b41: refused")
	-- the review's probe: a client writes the warfare smart (shared prefix "warfare_escort_") through coop_tvd
	for _, name in ipairs({ "no_such_smart", "here_smart" }) do
		for _, warfare in ipairs({ false, true }) do
			Hm.env.WARFARE = warfare or nil
			Cm.env.save_var(Cm.actor, "warfare_escort_task_smart", name)
			pump()
			req("complete", id, ";sp=n" .. member)
			check(hps().warfare_escort_task_smart == name and not turned(tsk),
				mode .. ": a client's coop_tvd write of the warfare smart (" .. name .. ", warfare " .. tostring(warfare)
				.. ") does not move the end: refused")
			Cm.env.save_var(Cm.actor, "warfare_escort_task_smart", nil)
			pump()
		end
	end
	-- honest warfare: the host's own setup_companion_task (Co-op), a map server's (Server) writes the smart next to him
	Hm.env.WARFARE = true
	if mode == "coop" then
		Hm.env.save_var(Hm.actor, "warfare_escort_task_smart", "here_smart")
	else
		Hm.handlers.coop_tvd("k=swarfare_escort_task_smart;op=sset;v=shere_smart", 0x101)
	end
	req("complete", id, ";sp=n" .. member)
	check(turned(tsk), mode .. ": the warfare smart its own logic wrote, he stands at it: ok")
	-- a smart not known here is no end
	Hm.env.save_var(Hm.actor, "warfare_escort_task_smart", "gone_smart")
	req("complete", id, ";sp=n" .. member)
	check(not turned(tsk) and last_line("task_complete_state"):find("no smart known", 1, true) ~= nil,
		mode .. ": an end smart not known here: refused, " .. last_line("task_complete_state"))
	Hm.env.save_var(Hm.actor, "warfare_escort_task_smart", nil)
	Hm.env.WARFARE = nil
	-- the pending anomaly (has_task_target_anomaly): the host's own on_init writes it, the companion's logic resets it
	proxy._pos = vec(110, 0, 0)
	Hm.env.save_var(Hm.actor, "task_target_anomaly", "jup_anomaly_x")
	req("complete", id, ";sp=n" .. member)
	check(not turned(tsk), mode .. ": at jup_b41, the anomaly still to be analyzed: refused")
	Cm.env.save_var(Cm.actor, "task_target_anomaly", nil) -- a client deletes it through coop_tvd
	pump()
	req("complete", id, ";sp=n" .. member)
	check(hps().task_target_anomaly == nil and not turned(tsk), mode .. ": a client's delete of task_target_anomaly: still refused")
	if mode == "coop" then
		Hm.env.save_var(Hm.actor, "task_target_anomaly", nil) -- the companion's logic on the host
	else
		Hm.handlers.coop_tvd("k=stask_target_anomaly;op=sdel", 0x101) -- the companion's logic on the map server
	end
	req("complete", id, ";sp=n" .. member)
	check(turned(tsk), mode .. ": the companion's logic reset it: ok")
	-- the companions dead: no escort to turn in
	trust.reset_for_test({ default = "refuse" })
	SE[member].alive = false
	req("complete", id, ";sp=n" .. member)
	check(not turned(tsk) and last_line("task_complete_state"):find("dead", 1, true) ~= nil,
		mode .. ": at the end with the companion dead: refused, " .. last_line("task_complete_state"))
	SE[member].alive = true
	-- "log" (build 57): every one of these goes through, with a line
	trust.reset_for_test({ default = "log" })
	proxy._pos = vec(400, 0, 0)
	req("complete", id, ";sp=n" .. member)
	check(turned(tsk) and lines("task_complete_state") >= 1, mode .. ", log: 300 m away: through as before, logged")
	proxy._pos = vec(4, 0, 0)
	drop(id)
end
server(false)
trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
print("== R7 P-PSI: the psi helmet upgrade at Sakharov")
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "refuse" })
	server(mode == "server")
	local id = "yan_stalker_sakharov_psi_helmet_upgrade"
	local sak = story_obj("yan_stalker_sakharov")
	TALK[sak] = true
	task(id, { status_functor = "check_if_enough_time_passed" })
	local tsk = give(id, sak)
	req("complete", id, ";sp=n" .. sak)
	check(turned(tsk), mode .. ": the paid good helmet (its phrase gives the task and completes it in one action): ok")
	NOW = NOW + 20000
	req("complete", id, ";sp=n" .. sak)
	check(not turned(tsk) and last_line("task_complete_state"):find("stage", 1, true) ~= nil,
		mode .. ": 20 s after the give, at stage 0: refused (its dialog asks stage 2)")
	tsk.stage = 2
	req("complete", id, ";sp=n" .. sak)
	check(turned(tsk), mode .. ": stage 2 (the wait is over): ok")
	drop(id)
end
server(false)
trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
print("== R7 P-INFO: the barrier asks the host's own record of its attackers")
local ATTACKERS_DEAD = false
Hm.env.xr_conditions.all_attackers_dead = function(a, b, c) return c and c[1] and ATTACKERS_DEAD end
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "refuse" })
	server(mode == "server")
	local id = "barrier_defense_zombie"
	task(id, {})
	local tsk = give(id, 777)
	tsk.status_functor = nil
	Hm.infos.barrier_defense_zombie_finished = true -- what a client's InfoPortion request makes the engine give
	ATTACKERS_DEAD = false
	req("complete", id, ";sp=n777")
	check(not turned(tsk) and last_line("task_complete_state"):find("attackers", 1, true) ~= nil,
		mode .. ": the info, its attackers alive here: refused")
	ATTACKERS_DEAD = true
	req("complete", id, ";sp=n777")
	check(turned(tsk), mode .. ": the info and its attackers dead here: ok")
	Hm.infos.barrier_defense_zombie_finished = nil
	drop(id)
end
Hm.env.xr_conditions.all_attackers_dead = nil
server(false)
trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
print("== R7 task_complete_talk: a turn-in outside any dialog (bind_heli, a client's condlist)")
for _, mode in ipairs(MODES) do
	trust.reset_for_test({ default = "log", task_complete_talk = "refuse" })
	server(mode == "server", function() return false end)
	local id = "mar_base_owl_stalker_trader_task_2"
	task(id, {})
	local tsk = give(id, 777)
	tsk.status_functor = nil
	NOW = NOW + 30000 -- no dialog for a while
	req("complete", id)
	check(not turned(tsk) and failed("task_complete_talk") == 1, mode .. ": no talk, the host's own check says running: refused")
	tsk.forced_status = nil
	tsk.last_check_task = "complete" -- the host's own logic found it done (its helicopter fell)
	req("complete", id)
	check(turned(tsk) and failed("task_complete_talk") == 1, mode .. ": no talk, the host's own check says done: ok, no line")
	drop(id)
end
server(false)
trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
print("== R7 Server limits that stay open (recorded in TZ 6.4): P-OWL, P-BANDIT")
do
	trust.reset_for_test({ default = "refuse" })
	server(true)
	local id = "mar_base_owl_stalker_trader_task_1"
	task(id, {})
	STORY.esc_2_12_stalker_nimble = STORY.esc_2_12_stalker_nimble or 790
	if not Hm.objects[790] then Hm.new_obj(790, "esc_2_12_stalker_nimble", vec(3, 0, 0), { _stalker = true }) end
	Hm.init_fx = { [id] = function() Hm.give_item(proxy, "mar_base_owl_stalker_trader_task_1_pda") end }
	local tsk = give(id, 777)
	Hm.init_fx = nil
	tsk.status_functor = nil
	req("complete", id, ";sp=n777")
	check(turned(tsk), "Server, known limit: the owl's PDA (its on_init gives it) turned in at the owl: the talk is not reported")
	take_all("mar_base_owl_stalker_trader_task_1_pda")
	drop(id)
	server(false)
	tsk = give(id, 777)
	tsk.status_functor = nil
	req("complete", id, ";sp=n777")
	check(not turned(tsk), "Co-op: the same at the owl: refused (the talk with Nimble is asked)")
	drop(id)
	server(true)
	id = "sim_default_bandit_trader_task_4"
	task(id, {})
	tsk = give(id, 777)
	tsk.status_functor = nil
	story_obj("bandit_companion_task_1", true)
	req("complete", id, ";sp=n777")
	check(turned(tsk), "Server, known limit: the bandit escort's loot is not seen (its companions are on a map server)")
	drop(id)
	server(false)
	trust.reset_for_test({ default = "log" })
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
