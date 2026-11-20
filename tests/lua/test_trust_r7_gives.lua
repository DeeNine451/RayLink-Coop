-- TZ v2 section 6.4, phase 2 weak places, round 7: the review of round 6 (temp\f2_r7\review6.md), its give findings.
--   P-S3b   Server: an empty list over the far view forgets the older offers of that NPC; an honest local pick holds, no line, in
--           "log" and "refuse"; and a pick his dialog made before the host's answer came (any mode)       (task_give_offer)
--   noise   a DRX money task given while his pstor keeps the last run's price: no line (its on_init writes the host's own)
--   P-STALE a bounty give that names no target: a line in "log"; "refuse" has the host run its setup (no last-run target)
--   made    "refuse": the host's own pick replaces his dialog's; his machine gets its lines ("needs: X", the bounty's target)
--   ledger  quest_take: a failed run's take count carries over until the task's repeat_timeout passed, when it has one
-- Run: tools\test_lua.cmd trust_r7_gives
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party" }
local SE = {}
local FETCH = { fetch_list = { "artefacts", "supplies", "drink", "weapons" },
	artefacts = { "af_gold_fish", "af_medusa" }, supplies = { "bread", "salt", "medkit" }, drink = { "vodka" },
	weapons = { "wpn_ak74" } }
local BOUNTY_PICK = 4343

local function setup(M)
	local e = M.env
	e.task_manager.task_ini.r_float_ex = function(_, id, key) return tonumber(M.ini[id] and M.ini[id][key]) end
	local stock_alife = e.alife_object
	e.alife_object = function(id)
		local s = SE[id]
		if s then
			return { id = id, group_id = 65535, alive = function() return s.alive ~= false end,
				section_name = function() return s.section or "sim_default_stalker_2" end, clsid = function() return 1 end }
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
	-- the host's own generators: tasks_fetch.setup_fetch_task (its "needs" line is drawn a frame later, CreateTimeEvent 0) and
	-- tasks_bounty.setup_bounty_task (the target's talk line, CreateTimeEvent 0, as the stock)
	e.xr_effects.setup_fetch_task = function(a, n, p)
		local pick = ({ artefacts = "af_medusa", supplies = "bread", weapons = "wpn_ak74" })[p[2] or ""] or "bread"
		e.save_var(e.db.actor, p[1], pick)
		e.save_var(e.db.actor, p[1] .. "_count", tonumber(p[3]) or 1)
		e.CreateTimeEvent(0, "fetch_line", 0, e.tasks_fetch.postpone_fetch_for_next_frame, p[1], pick, tonumber(p[3]) or 1)
	end
	e.xr_effects.setup_bounty_task = function(a, n, p)
		e.axr_task_manager.bounties_by_id[p[1]] = nil
		e.axr_task_manager.bounties_by_id[p[1]] = BOUNTY_PICK
		e.save_var(e.db.actor, p[1], { target_id = BOUNTY_PICK, target_comm = "stalker", lvl_task = "l01_escape" })
		e.CreateTimeEvent(0, "setup_bounty_task", 0, function(target)
			e.db.actor:give_talk_message2("T(bounty)", "target " .. tostring(target), "icon_" .. tostring(target), "iconed_answer_item")
			return true
		end, BOUNTY_PICK)
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
local npc_c = Cm.new_obj(750, "sim_stalker_barman", vec(2, 0, 0), { _stalker = true })
Hm.new_obj(750, "sim_stalker_barman", vec(6, 0, 0), { _stalker = true })
Hm.new_obj(777, "sim_default_stalker_trader", vec(2, 0, 0), { _stalker = true })
Hm.env.coop.talk_recent = function(peer, npc) return peer == 1 and (npc == 750 or npc == 777) end
SE[4242] = { alive = true, comm = "stalker" }
SE[BOUNTY_PICK] = { alive = true, comm = "stalker" }

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
local function task(id, ini) Hm.ini[id], Cm.ini[id] = ini or {}, ini or {} end
local function hps() return Hm.env.db.storage[0].pstor end
local function cps() return Cm.env.db.storage[0].pstor end
local function hb() return Hm.env.axr_task_manager.bounties_by_id end
local function cb() return Cm.env.axr_task_manager.bounties_by_id end
local function give(id, giver)
	Cm.tm:give_task(id, giver)
	pump()
	return Hm.tm.task_info[id]
end
local function drop(id)
	Hm.tm.task_info[id], Cm.tm.task_info[id], Hm.engine_tasks[id] = nil, nil, nil
	for k in pairs(hps()) do if k == id or k:sub(1, #id + 1) == id .. "_" then hps()[k] = nil end end
	for k in pairs(cps()) do if k == id or k:sub(1, #id + 1) == id .. "_" then cps()[k] = nil end end
	hb()[id], cb()[id] = nil, nil
end
local function turn_in(id, sp)
	Cm.env.coop.send_event("coop_tq", "op=scomplete;i=s" .. id .. ";sp=n" .. tostring(sp or 777), 0)
	pump()
	local tsk = Hm.tm.task_info[id]
	local yes = tsk ~= nil and tsk.forced_status == "complete"
	if tsk then tsk.forced_status = nil end
	return yes
end
local function offered_at(npc)
	NOW = NOW + 2000
	Cm.env.coop_quests_offer.request_offer(npc, "dyn")
	pump()
	Cm.talk_npc = npc
	Cm.env.axr_task_manager.generate_available_tasks(npc, nil)
	Cm.env.dialogs.text_npc_has_task(Cm.actor, npc)
end
local function server(on)
	-- (the server's part "far" of coop_quests_core, step S4)
	if on then
		Hm.env.coop_quests_core.set_part("far", { in_scope = function() return {} end, with_level_of = function(peer, fn, ...) return fn(...) end })
	else
		Hm.env.coop_quests_core.set_part("far", nil)
	end
end
local MODES = { { default = "log" }, { default = "refuse" } }

-------------------------------------------------------------------------------
print("== R7 P-S3b, Server: an older offer of the giver, then an empty list over the far view")
for _, modes in ipairs(MODES) do
	trust.reset_for_test(modes)
	local id = "s3b_t_" .. modes.default
	task(id, { fetch_descr = id .. "_descr", fetch_func = "%=setup_fetch_task(" .. id .. "_fetch:supplies:1:1)%",
		job_descr = id .. "_job", status_functor = "actor_has_fetch_item" })
	Hm.npc_tasks = { [750] = { id } }
	Cm.npc_tasks = Hm.npc_tasks
	server(true)
	offered_at(npc_c) -- the world server offers bread
	check(cps()[id .. "_fetch"] == "bread" and Hm.env.coop_quests_offer.offers_of(1, id) ~= nil, modes.default .. ": (the offer: bread)")
	NOW = NOW + 1200000 -- 20 minutes on: the far view makes an empty list (stand, build 54)
	Hm.npc_tasks = { [750] = {} }
	offered_at(npc_c)
	check(Hm.env.coop_quests_offer.offers_of(1, id) == nil, modes.default .. ": the empty far list forgets the NPC's older offer")
	Cm.env.save_var(Cm.actor, id .. "_fetch", "salt") -- his dialog's own stock generation
	Cm.env.save_var(Cm.actor, id .. "_fetch_count", 1)
	local n0 = lines("task_give_offer")
	give(id, 750)
	check(hps()[id .. "_fetch"] == "salt" and lines("task_give_offer") == n0,
		modes.default .. ": the honest local pick (salt) is kept, no line")
	drop(id)
	server(false)
	Hm.npc_tasks, Cm.npc_tasks = nil, nil
end

print("== R7 P-S3b: his dialog made its pick before the host's answer came (Co-op too)")
for _, modes in ipairs(MODES) do
	trust.reset_for_test(modes)
	local id = "early_t_" .. modes.default
	task(id, { fetch_descr = id .. "_descr", fetch_func = "%=setup_fetch_task(" .. id .. "_fetch:supplies:1:1)%",
		job_descr = id .. "_job", status_functor = "actor_has_fetch_item" })
	Hm.npc_tasks = { [750] = { id } }
	Cm.npc_tasks = Hm.npc_tasks
	offered_at(npc_c) -- the host's offer (bread) arrived after his dialog drew its own: salt
	Cm.env.save_var(Cm.actor, id .. "_fetch", "salt")
	local n0 = lines("task_give_offer")
	give(id, 750)
	check(hps()[id .. "_fetch"] == "salt" and lines("task_give_offer") == n0,
		modes.default .. ": a pick of the task's own generator (salt, not the offer's bread): kept, no line")
	drop(id)
	offered_at(npc_c)
	Cm.env.save_var(Cm.actor, id .. "_fetch", "wpn_ak74") -- no pick of setup_fetch_task(supplies)
	give(id, 750)
	check(lines("task_give_offer") == n0 + 1 and hps()[id .. "_fetch"] == (modes.default == "log" and "wpn_ak74" or "bread"),
		modes.default .. ": a rifle for a supplies fetch, against the offer's bread: a line; log keeps his, refuse writes the offer's: "
		.. tostring(hps()[id .. "_fetch"]))
	drop(id)
	Hm.npc_tasks, Cm.npc_tasks = nil, nil
end

-------------------------------------------------------------------------------
print("== R7 honest noise: a DRX money task given while his pstor keeps the last run's price")
for _, modes in ipairs(MODES) do
	trust.reset_for_test(modes)
	local id = "drx_sl_money_n"
	task(id, { status_functor = "drx_sl_money_task_status", on_init = "%=pstor_set(" .. id .. "_fetch:12000) +drx_sl_on_cf_task%" })
	cps()[id .. "_fetch"] = 12000 -- the last run's price, still in his pstor
	local n0 = lines("task_give_offer")
	Hm.init_fx = { [id] = function() Hm.env.save_var(Hm.actor, id .. "_fetch", 12000) end }
	local tsk = give(id, 777)
	Hm.init_fx = nil
	check(tsk ~= nil and lines("task_give_offer") == n0 and hps()[id .. "_fetch"] == 12000,
		modes.default .. ": no task_give_offer line; the host's price is its on_init's")
	-- the price is the host's own record (its on_init): the turn-in in either mode reads 12000
	Hm.env.coop.money_of = function(p) return p == 1 and 15000 or nil end
	tsk.stage = 1
	check(turn_in(id), modes.default .. ": turned in with 15000 against 12000")
	Hm.env.coop.money_of = nil
	drop(id)
	-- a forged price for a task whose on_init writes none: still a line
	local id2 = "drx_sl_nofx_t"
	task(id2, { status_functor = "drx_sl_money_task_status" })
	cps()[id2 .. "_fetch"] = 1
	n0 = lines("task_give_offer")
	give(id2, 777)
	check(lines("task_give_offer") == n0 + 1, modes.default .. ": a price no on_init or generator of the task makes: a line")
	drop(id2)
end

-------------------------------------------------------------------------------
print("== R7 P-STALE: a bounty given again with no target keeps no last-run target")
local function stock_bounty_functor(tsk, id)
	if tsk.stage == 0 then -- tasks_bounty.script: the host's own status functor
		local t = Hm.env.axr_task_manager.bounties_by_id[id]
		local se = t and Hm.env.alife_object(t)
		if se and not se:alive() then tsk.stage = 1 end
	end
end
for _, modes in ipairs(MODES) do
	local id = "bty_stale_" .. modes.default
	task(id, { status_functor = "bounty_task", stage_complete = "1",
		on_job_descr = "%=setup_bounty_task(" .. id .. ":true:false:monolith)%" })
	trust.reset_for_test(modes)
	-- run 1, honest: his dialog's setup picks 4242, he kills it, turns it in
	SE[4242] = { alive = true, comm = "stalker" }
	cb()[id] = 4242
	Cm.env.save_var(Cm.actor, id, { target_id = 4242, target_comm = "stalker", lvl_task = "l01_escape" })
	local tsk = give(id, 777)
	check(hb()[id] == 4242, modes.default .. ": (run 1: the host holds his target 4242)")
	SE[4242].alive = false
	stock_bounty_functor(tsk, id)
	check(turn_in(id), modes.default .. ": (run 1, honest: turned in)")
	Hm.tm.task_info[id], Hm.engine_tasks[id], Cm.tm.task_info[id] = nil, nil, nil -- the run ended; bounties_by_id keeps 4242
	-- run 2: a modified client strips the target from his give
	cb()[id] = nil
	cps()[id] = nil
	local n0 = lines("task_give_offer")
	tsk = give(id, 777)
	stock_bounty_functor(tsk, id)
	if modes.default == "log" then
		check(lines("task_give_offer") == n0 + 1 and last_line("task_give_offer"):find("names no target", 1, true) ~= nil,
			"log: a bounty give that names no target: a line, " .. last_line("task_give_offer"))
	else
		check(hb()[id] == BOUNTY_PICK and tsk.stage == 0 and not turn_in(id),
			"refuse: the host ran the setup itself (target " .. tostring(hb()[id]) .. ", alive): not turned in at once")
	end
	drop(id)
	SE[4242] = { alive = true, comm = "stalker" }
end

-------------------------------------------------------------------------------
print("== R7: in refuse the host's own pick goes to his machine with its lines")
do
	trust.reset_for_test({ default = "refuse" })
	local id = "made_f_t"
	task(id, { fetch_descr = id .. "_descr", fetch_func = "%=setup_fetch_task(" .. id .. "_fetch:artefacts:1:1)%",
		status_functor = "actor_has_fetch_item" })
	Cm.env.save_var(Cm.actor, id .. "_fetch", "bread") -- no pick of setup_fetch_task(artefacts)
	Cm.env.save_var(Cm.actor, id .. "_fetch_count", 1)
	Cm.talking, Cm.talk_msgs = true, {}
	give(id, 750)
	run_timers(Cm)
	local said = nil
	for _, m in ipairs(Cm.talk_msgs or {}) do if tostring(m[2]):find("af_medusa", 1, true) then said = m end end
	check(hps()[id .. "_fetch"] == "af_medusa" and said ~= nil,
		"a fetch: the host made af_medusa; his open dialog shows the \"needs\" line of it")
	drop(id)
	-- his dialog closed already: a news line
	Cm.talking, Cm.talk_msgs = false, {}
	local news0 = Cm.game_news or 0
	Cm.env.save_var(Cm.actor, id .. "_fetch", "bread")
	give(id, 750)
	run_timers(Cm)
	check((Cm.game_news or 0) == news0 + 1, "the dialog closed: one news line instead")
	drop(id)
	-- a bounty: the host's setup and its target's line
	local bid = "made_b_t"
	task(bid, { status_functor = "bounty_task", stage_complete = "1", on_job_descr = "%=setup_bounty_task(" .. bid .. ":true:false:monolith)%" })
	SE[4444] = { alive = false, comm = "stalker" }
	cb()[bid] = 4444 -- a dead target his machine names
	Cm.env.save_var(Cm.actor, bid, { target_id = 4444, target_comm = "stalker" })
	Cm.talking, Cm.talk_msgs = true, {}
	give(bid, 750)
	run_timers(Cm)
	local line = nil
	for _, m in ipairs(Cm.talk_msgs or {}) do if tostring(m[2]):find(tostring(BOUNTY_PICK), 1, true) then line = m end end
	check(hb()[bid] == BOUNTY_PICK and line ~= nil, "a bounty: the host's target " .. BOUNTY_PICK .. " and its line in his dialog")
	-- the message comes only from the host
	local before = #(Cm.talk_msgs or {})
	Cm.handlers["quests.made"]("i=s" .. bid .. ";fv=s" .. bid .. "_fetch;fs=sbread;fc=n1", 1)
	run_timers(Cm)
	check(#(Cm.talk_msgs or {}) == before, "the same message from another peer is dropped")
	drop(bid)
	Cm.talking = false
	trust.reset_for_test({ default = "log" })
end

-------------------------------------------------------------------------------
print("== R7 quest_take: a failed run's take count carries over until the task's repeat_timeout passed")
do
	trust.reset_for_test({ default = "log", quest_take = "refuse" })
	local GAME = 0
	local function ctime(t) return { t = t, diffSec = function(self, o) return self.t - o.t end } end
	Hm.env.game.get_game_time = function() return ctime(GAME) end
	local id = "rep_t"
	task(id, { fetch_func = "%=setup_fetch_task(rep_t_fetch:supplies:2:2)%", repeat_timeout = "16200" })
	Hm.actor._inv = {}
	for _ = 1, 10 do Hm.give_item(Hm.actor, "medkit") end
	local cbk = Hm.env.task_manager.task_callback
	local function run()
		Cm.env.save_var(Cm.actor, "rep_t_fetch", "medkit")
		Cm.env.save_var(Cm.actor, "rep_t_fetch_count", 2)
		local tsk = give(id, 750)
		tsk.repeat_timeout = 16200 -- (the stock object reads it from the ini)
		Cm.env.coop_quests_core.request_host_action("take", { s = "medkit", n = 2 })
		pump()
		Cm.tm:set_task_cancelled(id)
		pump()
		cbk({ get_id = function() return id end }, Hm.env.task.fail)
		drop(id)
	end
	run()
	check(Hm.count(Hm.actor, "medkit") == 8, "run 1 takes its 2 (8 left)")
	NOW = NOW + 700000 -- 11.7 minutes, but only 1 game hour: inside its repeat timeout (4.5 game hours)
	GAME = GAME + 3600
	run()
	check(Hm.count(Hm.actor, "medkit") == 8, "given again inside its repeat timeout, 11 minutes later: the take is refused (8 left)")
	GAME = GAME + 16300
	run()
	check(Hm.count(Hm.actor, "medkit") == 6, "after its repeat timeout: a new run takes its 2 again (6 left)")
	-- a task without a repeat_timeout keeps the 10 minutes of round 6
	Hm.env.game.get_game_time = function() return NOW end
	trust.reset_for_test({ default = "log" })
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
