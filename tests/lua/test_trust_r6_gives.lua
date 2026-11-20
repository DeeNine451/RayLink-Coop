-- TZ v2 section 6.4, phase 2 weak places, round 6: the review of round 5 (temp\f2_r6\review5.md), its give probes.
--   Q1  the bounty target a give carries (t.bt) against the one the host's offer named; with no offer, a target its setup can
--       pick (a living stalker of its factions), else, in "refuse", the host's own setup            (task_give_offer)
--   Q2  no offer asked at all: a fetch his machine forged; "refuse": the host makes its own        (task_give_offer, the turn-in)
--   Q3  an honest DRX storyline fetch (no host offer exists): its take from the group in "refuse"  (task_give_offer, quest_take)
--       Server: the same after an empty list over the far view
--   S3  only the offers of the giver t.g count; S4 a fact key no offer of his giver has: out of the judgement, no line
--   S1  the take count of a failed / cancelled run carries over for 10 minutes only                (quest_take)
-- Run: tools\test_lua.cmd trust_r6_gives
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party" }
local SE = {} -- id -> { alive, comm, section }

local FETCH = { fetch_list = { "artefacts", "supplies", "drink", "weapons", "weapons_novice" },
	artefacts = { "af_gold_fish", "af_medusa" }, supplies = { "bread", "salt", "medkit" }, drink = { "vodka" },
	weapons = { "wpn_ak74" }, weapons_novice = { "wpn_pm" } }

local function setup(M)
	local e = M.env
	e.task_manager.task_ini.r_float_ex = function(_, id, key) return tonumber(M.ini[id] and M.ini[id][key]) end
	local stock_alife = e.alife_object
	e.alife_object = function(id)
		local s = SE[id]
		if s then
			return { id = id, group_id = 65535, alive = function() return s.alive ~= false end,
				section_name = function() return s.section or "sim_default_stalker_2" end }
		end
		return stock_alife(id)
	end
	e.alife_character_community = function(se) return SE[se.id] and SE[se.id].comm or "stalker" end
	e.ini_file = function(name)
		if name ~= "items\\settings\\fetch_list.ltx" then return nil end
		return {
			section_exist = function(_, s) return FETCH[s] ~= nil end,
			line_count = function(_, s) return #(FETCH[s] or {}) end,
			r_line_ex = function(_, s, i) return true, FETCH[s] and FETCH[s][i + 1], "" end,
		}
	end
	-- the host's own generators (tasks_fetch.setup_fetch_task, tasks_bounty.setup_bounty_task) pick their first candidate here
	e.xr_effects.setup_fetch_task = function(a, n, p)
		local pick = ({ artefacts = "af_medusa", supplies = "bread", weapons = "wpn_ak74" })[p[2] or ""] or "bread"
		local spk = e.get_speaker()
		if spk and spk:id() == 751 and p[2] == "supplies" then pick = "salt" end
		e.save_var(e.db.actor, p[1], pick)
		e.save_var(e.db.actor, p[1] .. "_count", tonumber(p[3]) or 1)
	end
	e.xr_effects.setup_bounty_task = function(a, n, p)
		e.axr_task_manager.bounties_by_id[p[1]] = 4242
		e.save_var(e.db.actor, p[1], { target_id = 4242, target_comm = "stalker", lvl_task = "l01_escape" })
	end
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
local npc_h = Hm.new_obj(750, "sim_stalker_barman", vec(6, 0, 0), { _stalker = true })
local npc_c = Cm.new_obj(750, "sim_stalker_barman", vec(2, 0, 0), { _stalker = true })
local npc2_h = Hm.new_obj(751, "sim_stalker_trader2", vec(5, 0, 0), { _stalker = true })
local npc2_c = Cm.new_obj(751, "sim_stalker_trader2", vec(1, 0, 0), { _stalker = true })
SE[4242] = { alive = true, comm = "stalker" }
SE[4343] = { alive = true, comm = "stalker" }
SE[4444] = { alive = false, comm = "stalker" }
SE[4545] = { alive = true, comm = "monolith" }
Hm.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 750 or npc == 751) end

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
local function counted(name) return (trust.status()[name] or { checked = 0 }).checked end
local function task(id, ini) Hm.ini[id], Cm.ini[id] = ini or {}, ini or {} end
local function hps() return Hm.env.db.storage[0].pstor end
local function cps() return Cm.env.db.storage[0].pstor end
local function hb() return Hm.env.axr_task_manager.bounties_by_id end
local function cb() return Cm.env.axr_task_manager.bounties_by_id end
-- the honest path of a client's dialog: the host's offer comes, the dialog shows it (vars and bounty into his pstor)
local function offered_at(npc)
	NOW = NOW + 2000
	Cm.env.coop_quests_offer.request_offer(npc, "dyn")
	pump()
	Cm.talk_npc = npc
	Cm.env.axr_task_manager.generate_available_tasks(npc, nil)
	Cm.env.dialogs.text_npc_has_task(Cm.actor, npc)
end
local function give_it(id, giver)
	Cm.tm:give_task(id, giver)
	pump()
	return Hm.tm.task_info[id]
end
local function drop_task(id)
	Hm.tm.task_info[id], Cm.tm.task_info[id], Hm.engine_tasks[id] = nil, nil, nil
	for k in pairs(hps()) do if k == id or k:sub(1, #id + 1) == id .. "_" then hps()[k] = nil end end
	for k in pairs(cps()) do if k == id or k:sub(1, #id + 1) == id .. "_" then cps()[k] = nil end end
	hb()[id], cb()[id] = nil, nil
end
local function ask(name, t)
	Cm.env.coop_quests_core.request_host_action(name, t)
	pump()
end
local function turn_in(id)
	Cm.env.coop.send_event("coop_tq", "op=scomplete;i=s" .. id .. ";sp=n750", 0)
	pump()
	local tsk = Hm.tm.task_info[id]
	local yes = tsk ~= nil and tsk.forced_status == "complete"
	if tsk then tsk.forced_status = nil end
	return yes
end
local function fresh(modes)
	trust.reset_for_test(modes)
	Hm.log = {}
end

-------------------------------------------------------------------------------
print("== R6 blocker 2, the review's probe Q1: the bounty target a give carries against the host's offer")
do
	fresh({ default = "log" })
	task("bty_o", { on_job_descr = "%=setup_bounty_task(bty_o:true:false:monolith)%", job_descr = "bty_o_job",
		status_functor = "bounty_task", stage_complete = "1" })
	Hm.npc_tasks = { [750] = { "bty_o" } }
	Cm.npc_tasks = Hm.npc_tasks
	offered_at(npc_c)
	check(cb().bty_o == 4242, "(the host's offer named target 4242 and his dialog shows it)")
	give_it("bty_o", 750)
	check(hb().bty_o == 4242 and lines("task_give_offer") == 0 and counted("task_give_offer") == 1,
		"honest: the offer's target: judged and held, no line")
	drop_task("bty_o")
	-- a modified client names a target of its choice (a corpse makes the bounty's functor set stage 1 at once)
	offered_at(npc_c)
	cb().bty_o = 9999
	give_it("bty_o", 750)
	local line = last_line("task_give_offer")
	check(hb().bty_o == 9999 and lines("task_give_offer") == 1 and line:find("9999", 1, true) ~= nil
		and line:find("4242", 1, true) ~= nil and line:find("would be refused", 1, true) ~= nil,
		"log: his 9999 written as before, the line names both targets: " .. line)
	drop_task("bty_o")
	fresh({ default = "log", task_give_offer = "refuse" })
	offered_at(npc_c)
	cb().bty_o = 9999
	give_it("bty_o", 750)
	check(hb().bty_o == 4242 and lines("task_give_offer") == 1, "refuse: the host keeps the target its offer named (4242)")
	tick(Hm)
	pump()
	check(cb().bty_o == 4242, "his machine gets the host's target back with the task's state")
	drop_task("bty_o")
	Hm.npc_tasks, Cm.npc_tasks = nil, nil
end

print("== R6 blocker 2: a bounty with no offer (DRX: its dialog runs the setup on his machine)")
do
	fresh({ default = "log" })
	task("drx_sl_bty_t", { on_job_descr = "%=setup_bounty_task(drx_sl_bty_t:false:false:stalker:dolg)%",
		status_functor = "bounty_task", stage_complete = "1" })
	local function local_setup(target)
		cb().drx_sl_bty_t = target
		Cm.env.save_var(Cm.actor, "drx_sl_bty_t", { target_id = target, target_comm = "stalker", lvl_task = "l01_escape" })
		pump()
	end
	local_setup(4343)
	give_it("drx_sl_bty_t", 750)
	check(hb().drx_sl_bty_t == 4343 and lines("task_give_offer") == 0,
		"honest: a living stalker of the task's factions: a pick its setup makes, kept, no line")
	drop_task("drx_sl_bty_t")
	for _, bad in ipairs({ { 4444, "dead" }, { 4545, "monolith" }, { 500, "a player" }, { 31337, "no object" } }) do
		fresh({ default = "log" })
		local_setup(bad[1])
		give_it("drx_sl_bty_t", 750)
		check(hb().drx_sl_bty_t == bad[1] and lines("task_give_offer") == 1 and last_line("task_give_offer"):find(bad[2], 1, true),
			"log: target " .. bad[1] .. " (" .. bad[2] .. "): kept as before, logged: " .. last_line("task_give_offer"))
		drop_task("drx_sl_bty_t")
	end
	fresh({ default = "log", task_give_offer = "refuse" })
	local_setup(4444)
	give_it("drx_sl_bty_t", 750)
	check(hb().drx_sl_bty_t == 4242 and type(hps().drx_sl_bty_t) == "table" and hps().drx_sl_bty_t.target_id == 4242,
		"refuse: the host runs the task's setup itself (setup_bounty_task, the giver as the speaker): target 4242")
	tick(Hm)
	pump()
	check(cb().drx_sl_bty_t == 4242 and type(cps().drx_sl_bty_t) == "table" and cps().drx_sl_bty_t.target_id == 4242,
		"his machine uses the host's target (the task's state)")
	drop_task("drx_sl_bty_t")
	-- a target named for a task that is no bounty
	fresh({ default = "log", task_give_offer = "refuse" })
	task("plain_b", {})
	cb().plain_b = 4343
	give_it("plain_b", 750)
	check(hb().plain_b == nil and lines("task_give_offer") == 1, "refuse: a target for a task that is no bounty: not kept")
	drop_task("plain_b")
end

-------------------------------------------------------------------------------
print("== R6 blockers 4, 5, the review's probe Q2: no offer asked, a forged fetch decides the turn-in")
do
	fresh({ default = "refuse" })
	task("nooffer_t", { fetch_descr = "nooffer_t_descr", fetch_func = "%=setup_fetch_task(nooffer_t_fetch:artefacts:1:1)%",
		status_functor = "actor_has_fetch_item" })
	-- his machine skips the host's offer and writes a cheap fetch (the task asks for an artefact)
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch", "bread")
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch_count", 1)
	local tsk = give_it("nooffer_t", 750)
	check(tsk ~= nil and hps().nooffer_t_fetch == "af_medusa" and lines("task_give_offer") == 1
		and last_line("task_give_offer"):find("bread", 1, true) ~= nil,
		"refuse: given; bread is no pick of its setup_fetch_task(artefacts): the host made its own (af_medusa)")
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "bread")
	check(not turn_in("nooffer_t"), "refuse: turned in with one bread: refused")
	tick(Hm)
	pump()
	check(cps().nooffer_t_fetch == "af_medusa", "his machine uses the host's fetch (the task's state)")
	Hm.give_item(Hm.actor, "af_medusa")
	check(turn_in("nooffer_t"), "the artefact the host asked for with the group: turned in")
	drop_task("nooffer_t")
	-- log (build 57): his vars as before, with a line
	fresh({ default = "log" })
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch", "bread")
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch_count", 1)
	give_it("nooffer_t", 750)
	check(hps().nooffer_t_fetch == "bread" and lines("task_give_offer") == 1, "log: written as before, logged")
	drop_task("nooffer_t")
	-- a count out of the setup's range
	fresh({ default = "log" })
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch", "af_gold_fish")
	Cm.env.save_var(Cm.actor, "nooffer_t_fetch_count", 0)
	give_it("nooffer_t", 750)
	check(lines("task_give_offer") == 1, "log: an artefact x 0 (the setup asks 1..1): logged")
	drop_task("nooffer_t")
	-- the giver's other generators: setup_generic_fetch_task, the lostzone patch fetch
	fresh({ default = "log" })
	task("gen_t", { fetch_func = "%=setup_generic_fetch_task(gen_t_fetch:2:medkit:bandage)%" })
	Cm.env.save_var(Cm.actor, "gen_t_fetch", "bandage")
	Cm.env.save_var(Cm.actor, "gen_t_fetch_count", 2)
	give_it("gen_t", 750)
	check(lines("task_give_offer") == 0, "setup_generic_fetch_task: one of its sections, its count: no line")
	drop_task("gen_t")
	Cm.env.save_var(Cm.actor, "gen_t_fetch", "af_medusa")
	Cm.env.save_var(Cm.actor, "gen_t_fetch_count", 2)
	give_it("gen_t", 750)
	check(lines("task_give_offer") == 1, "setup_generic_fetch_task: a section it does not name: logged")
	drop_task("gen_t")
	task("lz_t", { fetch_func = "%=setup_supplies_fetch_task_lostzone_patch(lz_t_fetch:2:4)%" })
	Cm.env.save_var(Cm.actor, "lz_t_fetch", "dolg_patch")
	Cm.env.save_var(Cm.actor, "lz_t_fetch_count", 3)
	give_it("lz_t", 750)
	check(lines("task_give_offer") == 1, "the lostzone patch fetch: a patch x 3 (2..4): no new line")
	drop_task("lz_t")
end

print("== R6 blockers 4, 5, the review's probe Q3: an honest DRX storyline fetch, its take from the group, all on refuse")
do
	fresh({ default = "log", quest_take = "refuse", task_give_offer = "refuse" })
	task("drx_sl_honest_t", { fetch_descr = "drx_sl_honest_t_descr",
		fetch_func = "%=setup_fetch_task(drx_sl_honest_t_fetch:weapons:1:1)%", status_functor = "actor_has_fetch_item" })
	-- the stock DRX storyline dialog on his machine ran setup_fetch_task: a novice's pistol (weapons_novice)
	Cm.env.save_var(Cm.actor, "drx_sl_honest_t_fetch", "wpn_pm")
	Cm.env.save_var(Cm.actor, "drx_sl_honest_t_fetch_count", 1)
	pump()
	give_it("drx_sl_honest_t", 750)
	check(hps().drx_sl_honest_t_fetch == "wpn_pm" and lines("task_give_offer") == 0,
		"given as his dialog showed it (wpn_pm: a pick of its setup), the host's fact, no line")
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "wpn_pm") -- a group member holds the pistol
	ask("take", { s = "wpn_pm", n = 1 })
	check(Hm.count(Hm.actor, "wpn_pm") == 0 and lines("quest_take") == 0, "refuse: the group's pistol goes to the taker")
	drop_task("drx_sl_honest_t")
end

print("== R6 Q3, Server: a give after an empty list over the far view")
do
	fresh({ default = "log", quest_take = "refuse", task_give_offer = "refuse" })
	-- the world server makes the offers over stand-ins: no task of this NPC there (stand, build 54)
	-- (the server's part "far" of coop_quests_core, step S4)
	Hm.env.coop_quests_core.set_part("far", { in_scope = function() return {} end, with_level_of = function(peer, fn, ...) return fn(...) end })
	Hm.npc_tasks = { [750] = {} }
	offered_at(npc_c)
	check(Cm.local_text == nil or Cm.local_text >= 1, "(his dialog falls back to the stock local generation)")
	task("srv_t", { fetch_descr = "srv_t_descr", fetch_func = "%=setup_fetch_task(srv_t_fetch:supplies:1:1)%",
		status_functor = "actor_has_fetch_item" })
	Cm.env.save_var(Cm.actor, "srv_t_fetch", "salt")
	Cm.env.save_var(Cm.actor, "srv_t_fetch_count", 1)
	give_it("srv_t", 750)
	check(hps().srv_t_fetch == "salt" and lines("task_give_offer") == 0, "Server: his own pick (salt) of its setup: kept, no line")
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "salt")
	ask("take", { s = "salt", n = 1 })
	check(Hm.count(Hm.actor, "salt") == 0, "Server: the group's salt goes to the taker")
	drop_task("srv_t")
	Hm.env.coop_quests_core.set_part("far", nil)
	Hm.npc_tasks = nil
end

-------------------------------------------------------------------------------
print("== R6 S3: only the offers of the giver t.g count; S4: a fact key his giver's offer has not")
do
	fresh({ default = "log" })
	task("sup_t", { fetch_descr = "sup_t_descr", fetch_func = "%=setup_fetch_task(sup_t_fetch:supplies:1:1)%",
		job_descr = "sup_t_job" })
	Hm.npc_tasks = { [750] = { "sup_t" }, [751] = { "sup_t" } }
	Cm.npc_tasks = Hm.npc_tasks
	offered_at(npc2_c) -- the trader offers salt
	check(cps().sup_t_fetch == "salt", "(the trader's offer: salt)")
	give_it("sup_t", 750) -- given by the barman, who offered nothing
	check(hps().sup_t_fetch == "salt" and lines("task_give_offer") == 0,
		"another NPC's offer is no offer of the giver: judged as his own pick (salt: one of its setup), no line")
	drop_task("sup_t")
	offered_at(npc2_c)
	cps().sup_t_fetch = "wpn_ak74"
	give_it("sup_t", 750)
	check(lines("task_give_offer") == 1, "a rifle for a supplies fetch, no offer of the giver: logged")
	drop_task("sup_t")
	-- S4: a fact key the giver's offer has not, a leftover in his pstor
	offered_at(npc_c)
	cps().sup_t_target_id = 760
	give_it("sup_t", 750)
	check(lines("task_give_offer") == 1 and hps().sup_t_target_id == nil and hps().sup_t_fetch == "bread",
		"a leftover fact key: out of the judgement (no line), not written; the offer's bread held")
	drop_task("sup_t")
	Hm.npc_tasks, Cm.npc_tasks = nil, nil
end

print("== R6 S3: an offer request the host refuses drops the older offers of that NPC kept for him")
do
	fresh({ default = "log", task_give_offer = "refuse" })
	task("sup2_t", { fetch_descr = "sup2_t_descr", fetch_func = "%=setup_fetch_task(sup2_t_fetch:supplies:1:1)%",
		job_descr = "sup2_t_job" })
	Hm.npc_tasks = { [750] = { "sup2_t" } }
	Cm.npc_tasks = Hm.npc_tasks
	offered_at(npc_c) -- the host's offer: bread
	proxy._pos = vec(100, 0, 0) -- he walked off: his next request is refused ("far"), his machine makes the offer itself
	NOW = NOW + 2000
	Cm.env.coop_quests_offer.request_offer(npc_c, "dyn")
	pump()
	proxy._pos = vec(4, 0, 0)
	Cm.env.save_var(Cm.actor, "sup2_t_fetch", "salt")
	give_it("sup2_t", 750)
	check(hps().sup2_t_fetch == "salt" and lines("task_give_offer") == 0,
		"refuse: the older offer (bread) is forgotten; his own pick of its setup (salt) holds, no line")
	drop_task("sup2_t")
	Hm.npc_tasks, Cm.npc_tasks = nil, nil
end

-------------------------------------------------------------------------------
print("== R6 S1: the take count of a failed or cancelled run carries over for 10 minutes")
do
	fresh({ default = "log", quest_take = "refuse" })
	task("cyc_t", { fetch_func = "%=setup_fetch_task(cyc_t_fetch:supplies:2:2)%" })
	Hm.actor._inv = {}
	for _ = 1, 10 do Hm.give_item(Hm.actor, "medkit") end
	local cbk = Hm.env.task_manager.task_callback
	local function engine_end(id, state) cbk({ get_id = function() return id end }, state) end
	local function run()
		Cm.env.save_var(Cm.actor, "cyc_t_fetch", "medkit")
		Cm.env.save_var(Cm.actor, "cyc_t_fetch_count", 2)
		give_it("cyc_t", 750)
		ask("take", { s = "medkit", n = 2 })
		Cm.tm:set_task_cancelled("cyc_t")
		pump()
		engine_end("cyc_t", Hm.env.task.fail)
		drop_task("cyc_t")
	end
	run()
	run()
	check(Hm.count(Hm.actor, "medkit") == 8, "give, take, cancel, give again at once: the second run's take is refused (8 left)")
	NOW = NOW + 601000
	run()
	check(Hm.count(Hm.actor, "medkit") == 6, "10 minutes after the last run ended: a new run takes its 2 again (6 left)")
	run()
	check(Hm.count(Hm.actor, "medkit") == 6, "and right after that run: refused again (6 left)")
end

-------------------------------------------------------------------------------
print("== R6: malformed gives raise no Lua error and write nothing that is no task var")
do
	fresh({ default = "refuse" })
	task("mal_t", { on_job_descr = "%=setup_bounty_task(mal_t:true:false:monolith)%",
		fetch_func = "%=setup_fetch_task(mal_t_fetch:artefacts:1:1)%" })
	local bad = {
		"op=sgive;i=smal_t;g=n750;v=s",
		"op=sgive;i=smal_t;g=n750;v=n5;bt=sxx",
		"op=sgive;i=smal_t;g=n750;bt=n1e309",
		"op=sgive;i=smal_t;g=n750;bt=n-5",
		"op=sgive;i=smal_t;g=n750;bt=n42.5",
		"op=sgive;i=smal_t;g=snan;sp=s%25s",
		"op=sgive;i=smal_t;g=n750;v=smal_t_fetch%3Dn1e309%3Bmal_t_fetch_count%3Dsnan",
		"op=sgive;i=smal_t;g=n750;v=s%25s%25n_fetch%3Ds%25s%25n%3Bmal_t_%25s_fetch%3Ds%25n",
	}
	for _, p in ipairs(bad) do
		Cm.env.coop.send_event("coop_tq", p, 0)
		pump()
		check(hb().mal_t == nil or hb().mal_t == 4242, "a malformed bounty target is no target: " .. p)
		drop_task("mal_t")
	end
	local errs = 0
	for _, l in ipairs(Hm.log) do if l:find("rror", 1, true) and not l:find("[coop-trust]", 1, true) then errs = errs + 1 end end
	check(errs == 0, "no Lua error (" .. errs .. ")")
	trust.reset_for_test({ default = "log" })
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
