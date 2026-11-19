-- Anomaly Coop test (stage 2 of docs/plans/2026-11-16-storylines-per-faction.md): with split levels and story mode each
-- faction that has players runs its own DRX questlines chain (coop_srv_storyline.script). The fixture uses the real mode
-- layers over a dedicated world and its clients, or a co-op host and its clients. Not shipped.
-- Run: tools\test_lua.cmd srv_storyline_chains
dofile("tests/lua/support/harness_storyline.lua")

local SULTAN, DUSHMAN, SID, PETRENKO, NOAH = "zat_b7_bandit_boss_sultan", "cit_killers_merc_trader_stalker", "esc_m_trader",
	"bar_dolg_general_petrenko_stalker", "zat_b18_noah"
local KEYS = { "drx_sl_total_task_number", "drx_sl_current_task_number", "drx_sl_current_honcho", "drx_sl_current_task",
	"drx_sl_start_task" }
local FACTIONS_OF = { [501] = "dolg", [502] = "bandit" }
local OLD_KEYS = nil -- bare keys of an older save in the host's pstor at load
local OLD_TASKS = nil -- open tasks of an older save in the host's task manager at load
local DELAY_SESSION = false

STORYLINE_HOOK = function(M)
	if M.role ~= "host" then return end
	if DELAY_SESSION then
		M.active = false
		M.env.coop.is_host = M.env.coop.is_active
	end
	local chars = {}
	for id, f in pairs(FACTIONS_OF) do chars[id] = { f = f } end
	M.storage_state.coop_faction = { chars = chars, old = {} }
	for k, v in pairs(OLD_KEYS or {}) do pstor(M)[k] = v end
	for _, id in ipairs(OLD_TASKS or {}) do M.tm:give_task(id, 9) end -- open tasks of the older save (no co-op script yet)
end

local function ticks(M, n)
	for _ = 1, n or 8 do
		tick(M)
		pump()
	end
end

-- a world with split levels (or not), chains set up by the authority's first ticks
local function world(split, opts)
	opts = opts or {}
	STORY = opts.story ~= false
	ALIVE = opts.alive
	REL = {}
	OLD_KEYS = opts.old
	OLD_TASKS = opts.tasks
	DELAY_SESSION = opts.delay_session
	math.randomseed(1)
	setup_storyline(split, opts.active, opts.load)
	if opts.active ~= false and not DELAY_SESSION then
		ticks(Hm)
		ticks(A, 2)
		ticks(B, 2)
		if L then ticks(L, 2) end
		ticks(Hm, 2)
	end
	return Hm.env.coop_srv_storyline
end

local function chain(M, f, k) return pstor(M)[k .. "@" .. f] end
local function snapshot(M, f)
	local t = {}
	for _, k in ipairs(KEYS) do t[k] = pstor(M)[f and (k .. "@" .. f) or k] end
	return t
end
local function same(a, b)
	for _, k in ipairs(KEYS) do if a[k] ~= b[k] then return false end end
	return true
end
local function bare_keys(M)
	for _, k in ipairs(KEYS) do if pstor(M)[k] ~= nil then return true end end
	return false
end
local function suffixed(M)
	for k in pairs(pstor(M)) do if type(k) == "string" and k:find("@", 1, true) then return true end end
	return false
end
local function infos(M, prefix)
	local n = 0
	for i in pairs(M.infos) do if i:sub(1, #prefix) == prefix then n = n + 1 end end
	return n
end
local function sent_reqs(M) return count_sent(M, "coop_sl_req") end
local function chain_tvd(M, mark)
	local n = 0
	for i = mark + 1, #M.sent do
		local s = M.sent[i]
		if s.name == "coop_tvd" then
			for _, k in ipairs(KEYS) do if s.payload:find(k, 1, true) then n = n + 1 end end
		end
	end
	return n
end
local function refusals(M)
	local n = 0
	for _, l in ipairs(M.log) do if l:find("chain request", 1, true) and l:find("refused", 1, true) then n = n + 1 end end
	return n
end
local function last_refusal(M)
	for i = #M.log, 1, -1 do
		local l = M.log[i]
		if l:find("chain request", 1, true) and l:find("refused", 1, true) then return l end
	end
	return ""
end
local function npc(M, h) return M.leader[h] end

-- the client's mirror of the world's task state and shared vars
local function mirror() ticks(Hm, 2) end

-------------------------------------------------------------------------------
section("split levels, story mode: one chain per faction that has players")
do
	local sl = world(true, { old = { drx_sl_total_task_number = 9, drx_sl_current_task_number = 1, drx_sl_current_honcho = SID,
		drx_sl_start_task = "drx_sl_esc_m_trader_start_game_1" } })
	check(sl.chains_on() == true, "chains on (split levels, story mode)")
	check(not bare_keys(Hm), "the bare keys of the older save are gone")
	check(chain(Hm, "stalker", "drx_sl_total_task_number") == 9 and chain(Hm, "stalker", "drx_sl_current_honcho") == SID,
		"they are the world faction's (stalker) chain")
	check(sl.has_chain("stalker") and sl.has_chain("dolg") and sl.has_chain("bandit"), "chains: stalker, dolg (anna), bandit (boris)")
	check(chain(Hm, "dolg", "drx_sl_current_honcho") == PETRENKO and Hm.infos["drx_sl_start_game_" .. PETRENKO] == true,
		"Duty's chain starts at Petrenko")
	check(chain(Hm, "bandit", "drx_sl_current_honcho") == SULTAN and Hm.infos["drx_sl_start_game_" .. SULTAN] == true,
		"the bandits' chain starts at Sultan")
	local n = chain(Hm, "dolg", "drx_sl_total_task_number")
	check(type(n) == "number" and n >= 8 and n <= 12 and chain(Hm, "dolg", "drx_sl_current_task_number") == 1, "Duty: 8-12 tasks, at 1")
	check(sl.claim_of(SID) == "stalker" and sl.claim_of(PETRENKO) == "dolg" and sl.claim_of(SULTAN) == "bandit", "the leaders are claimed")
	check(sl.client_may_write("drx_sl_current_honcho@dolg") == false and sl.client_may_write("drx_sl_current_task") == false
		and sl.client_may_write("drx_sl_task_giver_77") == true, "client_may_write: no chain key, other drx_sl keys yes")
	check(Hm.storage_state.coop_storyline.migrated == true, "the migration is recorded")
	-- a stray bare key later (a stock writer outside a chain) is not migrated again
	pstor(Hm).drx_sl_current_honcho = "zat_a2_stalker_barmen"
	ticks(Hm, 4)
	check(chain(Hm, "stalker", "drx_sl_current_honcho") == SID and pstor(Hm).drx_sl_current_honcho == "zat_a2_stalker_barmen",
		"the bare keys become the world faction's chain exactly once")
	local tot = chain(Hm, "dolg", "drx_sl_total_task_number")
	Hm.env.SendScriptCallback("coop_faction_changed", 1, 501, "stalker", "dolg")
	ticks(Hm, 4)
	check(chain(Hm, "dolg", "drx_sl_total_task_number") == tot, "a known faction's chain is not set up again")
	-- the mirror carries the suffixed keys to every client
	mirror()
	check(chain(A, "dolg", "drx_sl_current_honcho") == PETRENKO and chain(B, "stalker", "drx_sl_current_honcho") == SID,
		"the clients mirror every chain's keys")
end

section("a new world (no bare keys): the world faction's chain is set up by the authority")
do
	local sl = world(true)
	check(sl.has_chain("stalker") and chain(Hm, "stalker", "drx_sl_current_honcho") == SID, "stalker chain at Sidorovich")
	check(Hm.infos["drx_sl_start_game_" .. SID] == true, "his start info is given")
end

section("dedicated world retries chain installation after a refused session start")
do
	local sl = world(true, { delay_session = true })
	local e = Hm.env
	local first_frame = NOW
	check(e.coop_mode.decides_world() and not e.coop.is_active(), "the world server layer answered before the session")
	check(e.load_var == Hm.stock_fn.load_var, "the actor's first update left the stock wrappers in place")

	local function frame(ms)
		NOW = first_frame + ms
		fire(Hm, "actor_on_update")
	end
	frame(0)
	frame(2000)
	frame(4000)
	Hm.active = true -- HostAutostart succeeds five seconds after the first frame.
	frame(5000)
	check(e.load_var == Hm.stock_fn.load_var, "the install retry waits for the next two-second tick")
	frame(6000)
	check(e.load_var ~= Hm.stock_fn.load_var, "the next retry installs the chain wrappers")
	local wrapped = e.load_var
	frame(8999)
	check(not sl.has_chain("stalker"), "chain setup preserves the delay for stock questline initialization")
	frame(9000)
	check(sl.has_chain("stalker") and sl.has_chain("dolg") and sl.has_chain("bandit"),
		"the running session has a chain for the world and both player factions")
	frame(11000)
	check(e.load_var == wrapped, "later ticks keep the installed wrapper")
end

section("the shared start leaders: renegade after bandit, isg after killer")
do
	FACTIONS_OF = { [501] = "killer", [502] = "bandit" }
	local sl = world(true, { alive = { [NOAH] = true, [SULTAN] = true, [DUSHMAN] = true } })
	check(chain(Hm, "killer", "drx_sl_current_honcho") == DUSHMAN and sl.claim_of(DUSHMAN) == "killer", "the killers hold Dushman")
	-- boris joins the Renegades: Sultan is the bandits'
	Hm.storage_state.coop_faction.chars[502] = { f = "renegade" }
	Hm.env.SendScriptCallback("coop_faction_changed", 2, 502, "bandit", "renegade")
	check(sl.has_chain("renegade"), "the Renegades' chain is set up when their first player appears")
	local h = chain(Hm, "renegade", "drx_sl_current_honcho")
	check(h ~= SULTAN and sl.claim_of(SULTAN) == "bandit", "the Renegades do not take Sultan (" .. tostring(h) .. ")")
	local t = chain(Hm, "renegade", "drx_sl_current_task")
	check(t == "drx_sl_" .. tostring(h) .. "_meet_task_1" and Hm.tm.task_info[t] ~= nil and sl.owner_of_task(t) == "renegade",
		"they go straight to a meet task, theirs")
	check(chain(Hm, "renegade", "drx_sl_current_task_number") == 2, "counted as the stock start dialog counts (decrease + meet)")
	check(chain(Hm, "bandit", "drx_sl_current_honcho") == SULTAN and Hm.infos["drx_sl_start_game_" .. SULTAN] == true,
		"the bandits keep Sultan and his start info")
	Hm.storage_state.coop_faction.chars[501] = { f = "isg" }
	Hm.env.SendScriptCallback("coop_faction_changed", 1, 501, "killer", "isg")
	check(chain(Hm, "isg", "drx_sl_current_honcho") ~= DUSHMAN and sl.claim_of(DUSHMAN) == "killer", "ISG does not take Dushman")
	FACTIONS_OF = { [501] = "dolg", [502] = "bandit" }
end

section("two factions advance at once; claimed leaders are skipped")
do
	-- alive: Sultan (the bandits') and Noah; Sidorovich counts as alive in the stock
	local sl = world(true, { alive = { [SULTAN] = true, [NOAH] = true } })
	mirror()
	local stalker0, bandit0 = snapshot(Hm, "stalker"), snapshot(Hm, "bandit")
	local a_before = snapshot(A, "dolg")
	local mark = #A.sent
	-- anna's start dialog at Petrenko on her machine (gamma dialogs.xml:91-93: disable_info, decrease, meet)
	A.env.xr_effects.drx_sl_decrease_sl_tasks_count(A.actor, npc(A, PETRENKO))
	A.env.xr_effects.drx_sl_meet_random_honcho(A.actor, npc(A, PETRENKO))
	check(same(snapshot(A, "dolg"), a_before) and not bare_keys(A), "her machine changed no chain key")
	check(chain_tvd(A, mark) == 0 and sent_reqs(A) == 1, "one request, no chain var routed")
	pump()
	check(chain(Hm, "dolg", "drx_sl_current_honcho") == NOAH, "the world moved Duty's chain to Noah (Sultan is claimed)")
	local meet = chain(Hm, "dolg", "drx_sl_current_task")
	check(meet == "drx_sl_" .. NOAH .. "_meet_task_1" and sl.owner_of_task(meet) == "dolg", "the meet task is Duty's")
	check(Hm.infos["drx_sl_meet_honcho_" .. NOAH] == true and Hm.infos["drx_sl_start_game_" .. PETRENKO] == nil,
		"Noah's meet info is on, Petrenko's start info off")
	check(chain(Hm, "dolg", "drx_sl_current_task_number") == 2, "Duty at task 2")
	check(Hm.env.coop_tasks.taker(meet) == 1, "the meet task is anna's")
	check(same(snapshot(Hm, "stalker"), stalker0) and same(snapshot(Hm, "bandit"), bandit0), "nobody else's keys moved")
	-- the loner's start dialog at Sidorovich: Noah and Sultan are claimed, he is the current one: kept
	local dolg1 = snapshot(Hm, "dolg")
	L.env.xr_effects.drx_sl_decrease_sl_tasks_count(L.actor, npc(L, SID))
	L.env.xr_effects.drx_sl_meet_random_honcho(L.actor, npc(L, SID))
	pump()
	check(chain(Hm, "stalker", "drx_sl_current_honcho") == SID, "nobody free: the loners keep Sidorovich (as the stock)")
	check(chain(Hm, "stalker", "drx_sl_current_task") == "drx_sl_" .. SID .. "_meet_task_1"
		and sl.owner_of_task("drx_sl_" .. SID .. "_meet_task_1") == "stalker", "their meet task is theirs")
	check(same(snapshot(Hm, "dolg"), dolg1) and same(snapshot(Hm, "bandit"), bandit0), "Duty's and the bandits' keys untouched")
	check(not bare_keys(Hm), "no bare chain key written")

	-------------------------------------------------------------------------
	-- anna at Noah: the meet dialog gives her a storyline task
	mirror()
	local T1 = "drx_sl_" .. NOAH .. "_task_1"
	local T2 = "drx_sl_" .. NOAH .. "_task_2"
	-- the dialog's text function chose the task (dialogs.last_task_id); the stock give keeps to it through its loop
	A.env.dialogs.last_task_id = T1
	local mark2 = #A.sent
	local a2 = snapshot(A, "dolg")
	local a_info = A.infos["drx_sl_meet_honcho_" .. NOAH]
	A.env.dialogs.drx_sl_give_sl_task(A.actor, npc(A, NOAH))
	check(same(snapshot(A, "dolg"), a2) and A.infos["drx_sl_meet_honcho_" .. NOAH] == a_info,
		"her machine changed no chain key and no leader info")
	check(chain_tvd(A, mark2) == 0, "the give dialog routed no chain var")
	check(count_sent(A, "coop_tq") >= 1 and sent_reqs(A) == 2, "the give went the old way, the chain part as one request")
	pump()
	local given = Hm.tm.task_info[T1] and T1 or nil
	check(given ~= nil and sl.owner_of_task(given) == "dolg", "the task is given and Duty's (" .. tostring(given) .. ")")
	check(chain(Hm, "dolg", "drx_sl_current_task") == given, "Duty's current task is it")
	check(Hm.infos["drx_sl_meet_honcho_" .. NOAH] == nil, "Noah's meet info is off on the world")
	check(chain(Hm, "stalker", "drx_sl_current_task") == "drx_sl_" .. SID .. "_meet_task_1", "the loners' current task stands")

	-------------------------------------------------------------------------
	-- forged requests
	local before = snapshot(Hm, "dolg")
	local stalker_now = snapshot(Hm, "stalker")
	local r0 = refusals(Hm)
	local function forge(M, t)
		NOW = NOW + 1500
		M.env.coop.send_event("coop_sl_req", H.encode(t), 0)
		pump()
	end
	forge(B, { k = "fin", h = NOAH, t = given })
	check(refusals(Hm) == r0 + 1 and last_refusal(Hm):find("from #2 refused: not his faction's task", 1, true) ~= nil,
		"boris (bandit) cannot turn in Duty's task: his own faction is asked, not anna's")
	forge(B, { k = "give", h = NOAH, t = T2 })
	check(refusals(Hm) == r0 + 2 and last_refusal(Hm):find("from #2 refused: the leader is another faction's", 1, true) ~= nil,
		"nor take a task at Duty's leader")
	forge(A, { k = "fin", h = NOAH, t = "drx_sl_zat_b18_noah_task_99" })
	check(refusals(Hm) == r0 + 3 and last_refusal(Hm):find("not his faction's task", 1, true) ~= nil, "a made-up task id is refused")
	forge(A, { k = "give", h = SID, t = "drx_sl_esc_m_trader_task_1" })
	check(refusals(Hm) == r0 + 4, "anna cannot take a task at the loners' leader")
	forge(A, { k = "fin", h = NOAH, t = given })
	check(refusals(Hm) == r0 + 5, "a task that is not turned in does not advance the chain")
	forge(A, { k = "start", h = PETRENKO })
	check(refusals(Hm) == r0 + 6, "a started chain cannot be started again")
	forge(A, { k = "run", h = "x;y", t = "%s%s" })
	check(refusals(Hm) == r0 + 7, "an unknown request is refused")
	NOW = NOW + 1500
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "give", h = NOAH, t = T2 }), 0)
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "give", h = NOAH, t = T2 }), 0)
	pump()
	check(refusals(Hm) == r0 + 9 and has_log(Hm, "too often") and has_log(Hm, "the task was not given to him"),
		"a task that was not given is refused, and so is a burst")
	check(sl.owner_of_task(T2) == nil, "no owner recorded for a task nobody was given")
	check(same(snapshot(Hm, "stalker"), stalker_now), "the forged requests changed no other chain")
	check(chain(Hm, "dolg", "drx_sl_current_honcho") == NOAH and chain(Hm, "dolg", "drx_sl_current_task_number") == before.drx_sl_current_task_number,
		"nor Duty's leader or count")

	-------------------------------------------------------------------------
	-- anna turns the task in at Noah: the turn-in goes the old way, the next step on the world under Duty
	Hm.tm.task_info[given].stage = 254
	mirror()
	A.engine_tasks[given] = { state = "in", get_id = function() return given end }
	local a3 = snapshot(A, "dolg")
	local mark3 = #A.sent
	ALIVE = { [SULTAN] = true, [NOAH] = true, ["zat_a2_stalker_barmen"] = true }
	NOW = NOW + 1500
	A.env.dialogs.drx_sl_set_finished_task_complete(A.actor, npc(A, NOAH))
	check(same(snapshot(A, "dolg"), a3) and chain_tvd(A, mark3) == 0, "her machine changed and routed no chain key")
	check(A.tm.task_info[given] ~= nil, "her mirror still has the task until the world answers")
	pump()
	check(Hm.tm.task_info[given].forced_status == "complete", "the world turned the task in (the old path)")
	check(chain(Hm, "dolg", "drx_sl_current_honcho") == "zat_a2_stalker_barmen", "Duty's chain moved on to Beard")
	check(chain(Hm, "dolg", "drx_sl_current_task_number") == 3, "Duty at task 3")
	local meet2 = chain(Hm, "dolg", "drx_sl_current_task")
	check(meet2 == "drx_sl_zat_a2_stalker_barmen_meet_task_1" and sl.owner_of_task(meet2) == "dolg", "the next meet task is Duty's")
	check(same(snapshot(Hm, "stalker"), stalker_now) and same(snapshot(Hm, "bandit"), bandit0), "the other chains did not move")
	NOW = NOW + 1500
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "fin", h = NOAH, t = given }), 0)
	pump()
	check(has_log(Hm, "advanced the chain already"), "the same turn-in cannot advance the chain twice")
	engine_check(Hm)
	pump()
	ticks(Hm, 2)
	check(Hm.tm.task_info[given] == nil and sl.owner_of_task(given) == nil, "the task is gone: no owner any more")

	-------------------------------------------------------------------------
	-- save / load: the owners are the world's m_data
	Hm.env.SendScriptCallback("save_state", Hm.storage_state)
	local fresh = load_script(Hm, "coop_srv_storyline")
	fresh.on_game_start()
	for _, f in ipairs(Hm.callbacks.actor_on_first_update) do f() end
	check(fresh.owner_of_task(meet2) == "dolg" and fresh.owner_of_task("drx_sl_" .. SID .. "_meet_task_1") == "stalker",
		"a new Lua state of the world knows every owner")

	-------------------------------------------------------------------------
	-- the host's own task callback: the stock on_fail of a storyline task (gamma tm_bar.ltx:68) runs under the task's owner
	local d4 = snapshot(Hm, "dolg")
	local s4 = snapshot(Hm, "stalker")
	Hm.on_fail = Hm.on_fail or {}
	Hm.on_fail[meet2] = function()
		Hm.env.xr_effects.drx_sl_meet_random_honcho(Hm.actor, nil, {})
		Hm.env.xr_effects.drx_sl_decrease_sl_tasks_count(Hm.actor, nil, {})
	end
	Hm.tm:set_task_failed(meet2)
	Hm.engine_tasks[meet2].state = "in"
	Hm.env.task_manager.task_callback(Hm.engine_tasks[meet2], Hm.env.task.fail)
	check(chain(Hm, "dolg", "drx_sl_current_task_number") == d4.drx_sl_current_task_number, "Duty's fail: +1 -1 under Duty")
	check(chain(Hm, "dolg", "drx_sl_current_task") ~= d4.drx_sl_current_task, "Duty got its next meet task")
	check(same(snapshot(Hm, "stalker"), s4), "the loners' chain did not move")

	-------------------------------------------------------------------------
	-- cancel_chain(dolg): only Duty's
	local dtask = chain(Hm, "dolg", "drx_sl_current_task")
	local stask = chain(Hm, "stalker", "drx_sl_current_task")
	local dh = chain(Hm, "dolg", "drx_sl_current_honcho")
	check(sl.cancel_chain("dolg") == true, "cancel_chain(dolg)")
	check(Hm.tm.task_info[dtask].forced_status == "fail" and Hm.tm.task_info[dtask].cancelled_by_actor == true, "Duty's task fails")
	check(Hm.tm.task_info[stask].forced_status == nil, "the loners' task stands")
	check(snapshot(Hm, "dolg").drx_sl_current_honcho == nil and snapshot(Hm, "dolg").drx_sl_total_task_number == nil, "Duty's keys are gone")
	check(same(snapshot(Hm, "stalker"), s4) or chain(Hm, "stalker", "drx_sl_current_honcho") == SID, "the loners' keys stand")
	check(Hm.infos["drx_sl_meet_honcho_" .. dh] == nil and Hm.infos["drx_sl_meet_honcho_" .. SID] == true, "only Duty's leader info is off")
	check(not sl.has_chain("dolg") and sl.has_chain("stalker"), "Duty has no chain, the loners keep theirs")
	check(sl.claim_of(dh) == nil and sl.claim_of(SID) == "stalker", "Duty's claim is gone")
end

section("the Wish Granter: an endgame turn-in asks the world, the task is the sender's chain's")
do
	local sl = world(true, { alive = { [NOAH] = true } })
	-- Duty's chain at Noah with a finished task (made on the world as the chain would)
	local T1 = "drx_sl_" .. NOAH .. "_task_1"
	sl.with_chain("dolg", function()
		Hm.env.save_var(Hm.actor, "drx_sl_current_honcho", NOAH)
		Hm.env.save_var(Hm.actor, "drx_sl_current_task", T1)
	end)
	Hm.env.coop_tasks.run_as(1, function() Hm.tm:give_task(T1, 9) end)
	-- record the owner as a give request does
	NOW = NOW + 1500
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "give", h = NOAH, t = T1 }), 0)
	pump()
	check(sl.owner_of_task(T1) == "dolg", "the task is Duty's")
	Hm.tm.task_info[T1].stage = 254
	mirror()
	A.engine_tasks[T1] = { state = "in", get_id = function() return T1 end }
	NOW = NOW + 1500
	A.env.dialogs.drx_sl_set_finished_task_complete_endgame(A.actor, npc(A, NOAH))
	check(A.tm.task_info["drx_sl_find_wish_granter_task"] == nil and A.infos.drx_sl_on_find_wish_granter == nil,
		"nothing of the ending on her machine")
	pump()
	check(Hm.tm.task_info["drx_sl_find_wish_granter_task"] ~= nil and sl.owner_of_task("drx_sl_find_wish_granter_task") == "dolg",
		"the world gave the Wish Granter task, Duty's")
	check(chain(Hm, "dolg", "drx_sl_current_task") == "drx_sl_find_wish_granter_task" and not bare_keys(Hm), "in Duty's keys")

	-- D3: the bandits reach their ending after Duty: the one Wish Granter task stays Duty's (the first chain that reaches it)
	local WISH = "drx_sl_find_wish_granter_task"
	local TB = "drx_sl_" .. SULTAN .. "_task_1"
	sl.with_chain("bandit", function()
		Hm.env.save_var(Hm.actor, "drx_sl_current_honcho", SULTAN)
		Hm.env.save_var(Hm.actor, "drx_sl_current_task", TB)
	end)
	Hm.env.coop_tasks.run_as(2, function() Hm.tm:give_task(TB, 9) end)
	NOW = NOW + 1500
	B.env.coop.send_event("coop_sl_req", H.encode({ k = "give", h = SULTAN, t = TB }), 0)
	pump()
	check(sl.owner_of_task(TB) == "bandit", "the bandits' task is theirs")
	Hm.tm.task_info[TB].forced_status = "complete" -- turned in
	local btask = chain(Hm, "bandit", "drx_sl_current_task")
	local adv = #Hm.log
	NOW = NOW + 1500
	B.env.coop.send_event("coop_sl_req", H.encode({ k = "end", h = SULTAN, t = TB }), 0)
	pump()
	check(sl.owner_of_task(WISH) == "dolg", "the Wish Granter task stays Duty's")
	check(Hm.env.coop_tasks.taker(WISH) == 1, "its taker stays anna")
	check(chain(Hm, "bandit", "drx_sl_current_task") == btask, "the stock wish effect did not run for the bandits")
	local said = 0
	for i = adv + 1, #Hm.log do if Hm.log[i]:find("Wish Granter", 1, true) then said = said + 1 end end
	check(said == 1, "one log line says why")
	-- a stock effect on the authority, scoped to the world's faction: the same rule
	sl.with_chain("stalker", Hm.env.xr_effects.drx_sl_find_wish_granter, Hm.actor, nil, {})
	check(sl.owner_of_task(WISH) == "dolg" and Hm.env.coop_tasks.taker(WISH) == 1, "the world effect: still Duty's, anna's")
	check(chain(Hm, "stalker", "drx_sl_current_task") ~= WISH, "the loners' chain did not take it")
end

section("D3: the first chain to reach the Wish Granter owns it (the wrapper's positive path)")
do
	local sl = world(true)
	local WISH = "drx_sl_find_wish_granter_task"
	sl.with_chain("stalker", Hm.env.xr_effects.drx_sl_find_wish_granter, Hm.actor, nil, {})
	check(Hm.tm.task_info[WISH] ~= nil and sl.owner_of_task(WISH) == "stalker", "nobody had it: the world's faction owns it")
	check(chain(Hm, "stalker", "drx_sl_current_task") == WISH, "in the loners' keys")
end

section("D4: an older save's open chain tasks are the world faction's: their turn-in moves the chain")
do
	FACTIONS_OF = { [501] = "stalker", [502] = "bandit" }
	local T = "drx_sl_" .. SID .. "_task_1"
	local CFT = "drx_sl_" .. SID .. "_cf_task_1"
	local sl = world(true, { old = { drx_sl_total_task_number = 9, drx_sl_current_task_number = 2, drx_sl_current_honcho = SID,
		drx_sl_current_task = T, drx_sl_start_task = "drx_sl_esc_m_trader_start_game_1" }, tasks = { T, CFT } })
	check(Hm.tm.task_info[T] ~= nil and Hm.tm.task_info[CFT] ~= nil, "the older save's tasks are open")
	check(sl.owner_of_task(T) == "stalker", "the open chain task is the world faction's chain's")
	check(sl.owner_of_task(CFT) == nil, "a change-faction task is no chain's")
	Hm.tm.task_info[T].forced_status = "complete" -- turned in
	local r0 = refusals(Hm)
	NOW = NOW + 1500
	B.env.coop.send_event("coop_sl_req", H.encode({ k = "fin", h = SID, t = T }), 0)
	pump()
	check(refusals(Hm) == r0 + 1 and last_refusal(Hm):find("from #2 refused: not his faction's task", 1, true) ~= nil,
		"boris (bandit) cannot move the loners' chain with it")
	NOW = NOW + 1500
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "fin", h = SID, t = T }), 0)
	pump()
	check(refusals(Hm) == r0 + 1 and has_log(Hm, "#1 advanced the stalker chain (fin)"), "anna (stalker): the same task moves it")
	check(chain(Hm, "stalker", "drx_sl_current_task_number") == 3, "the loners at task 3")
	FACTIONS_OF = { [501] = "dolg", [502] = "bandit" }
end

section("D6: the stock keys restored from a per-faction save keep their progress on reimport")
do
	local sl = world(true, { old = { drx_sl_total_task_number = 9, drx_sl_current_task_number = 1, drx_sl_current_honcho = SID,
		drx_sl_start_task = "drx_sl_esc_m_trader_start_game_1" } })
	check(chain(Hm, "stalker", "drx_sl_current_task_number") == 1 and not bare_keys(Hm), "migrated")
	local server_pstor, server_storyline = pstor(Hm), Hm.storage_state.coop_storyline
	world(false, { load = function(M)
		M.env.db.storage[0].pstor = server_pstor
		M.storage_state.coop_storyline = server_storyline
	end })
	check(pstor(Hm).drx_sl_current_task_number == 1 and pstor(Hm).drx_sl_current_honcho == SID, "the bare keys are back")
	check(chain(Hm, "stalker", "drx_sl_current_task_number") == nil and chain(Hm, "stalker", "drx_sl_current_honcho") == nil,
		"and the suffixed copies are gone")
	pstor(Hm).drx_sl_current_task_number = 5 -- the shared world plays on (the stock writes the bare keys)
	local co_op_pstor, co_op_storyline = pstor(Hm), Hm.storage_state.coop_storyline
	sl = world(true, { load = function(M)
		M.env.db.storage[0].pstor = co_op_pstor
		M.storage_state.coop_storyline = co_op_storyline
	end })
	check(chain(Hm, "stalker", "drx_sl_current_task_number") == 5, "the progress of the shared world is the world faction's chain")
	check(not bare_keys(Hm) and sl.has_chain("stalker"), "migrated again")
end

section("group mode (no split levels): every key name and stock call as today")
do
	local sl = world(false, { alive = { [NOAH] = true } })
	check(sl.chains_on() == false, "chains off")
	for _, M in ipairs({ Hm, A, B }) do
		local e = M.env
		check(e.xr_effects.drx_sl_meet_random_honcho == M.stock_fn.meet and e.xr_effects.drx_sl_decrease_sl_tasks_count == M.stock_fn.decrease
			and e.xr_effects.drx_sl_find_wish_granter == M.stock_fn.wish, M.nick .. ": the stock effects, not wrapped")
		check(e.dialogs.drx_sl_set_finished_task_complete == M.stock_fn.fin and e.dialogs.drx_sl_give_sl_task == M.stock_fn.give,
			M.nick .. ": the stock dialogs")
		check(e.load_var == M.stock_fn.load_var, M.nick .. ": load_var is the stock one")
	end
	Hm.env.xr_effects.drx_sl_setup_questlines(nil, nil, { "stalker" })
	Hm.env.xr_effects.drx_sl_meet_random_honcho()
	check(pstor(Hm).drx_sl_current_honcho == NOAH and pstor(Hm).drx_sl_current_task == "drx_sl_" .. NOAH .. "_meet_task_1",
		"the stock writes the bare keys")
	check(not suffixed(Hm) and Hm.storage_state.coop_storyline == nil, "no suffixed key, no chain record")
	check(sl.owner_of_task("drx_sl_" .. NOAH .. "_meet_task_1") == nil, "owner_of_task says nil")
end

section("no session: stock")
do
	local sl = world(true, { active = false })
	check(sl.chains_on() == false and sl.owner_of_task("x") == nil, "chains off, no owners")
	check(Hm.env.xr_effects.drx_sl_meet_random_honcho == Hm.stock_fn.meet and Hm.env.save_var ~= nil
		and Hm.env.load_var == Hm.stock_fn.load_var, "nothing wrapped")
	local ran = false
	sl.with_chain("dolg", function() ran = true; Hm.env.save_var(Hm.actor, "drx_sl_current_honcho", SID) end)
	check(ran and pstor(Hm).drx_sl_current_honcho == SID, "with_chain runs fn on the bare keys")
end

section("sandbox (not story mode): nothing installed for chains")
do
	local sl = world(true, { story = false })
	check(sl.chains_on() == false, "chains off")
	check(Hm.env.xr_effects.drx_sl_meet_random_honcho == Hm.stock_fn.meet and A.env.dialogs.drx_sl_give_sl_task == A.stock_fn.give
		and Hm.env.load_var == Hm.stock_fn.load_var, "nothing wrapped")
	check(Hm.storage_state.coop_storyline == nil and not suffixed(Hm), "no chain set up, no suffixed key")
end

section("S4: the server's storyline starts from coop_mode.when_srv; the co-op asks coop_conditions_stock")
do
	world(true)
	local cs, sl = Hm.env.coop_conditions_stock, Hm.env.coop_srv_storyline
	check(Hm.env.coop_mode.decides_world() and not Hm.env.coop_mode.seat_plays(0)
		and Hm.env.coop_faction.split_mode() and cs.dlg_leader == sl.dlg_leader and cs.dlg_cf_free == sl.dlg_cf_free
		and cs.dlg_story_ll == sl.dlg_story_ll and cs.client_may_write == sl.client_may_write and cs.may_take == sl.may_take,
		"split levels: the server's answers stand in coop_conditions_stock (the dialog gates, coop_tasks' questions)")
	world(false)
	for _, M in ipairs({ Hm, A, B }) do
		local c, s = M.env.coop_conditions_stock, M.env.coop_srv_storyline
		check(M.env.coop_faction.group_mode() and not M.env.coop_faction.split_mode()
			and c.dlg_leader ~= s.dlg_leader and c.may_take ~= s.may_take,
			M.nick .. ": the co-op: the stock answers stand")
		check(c.dlg_leader(M.actor, nil, "drx_sl_" .. SID .. "_meet_dialog") == true and c.dlg_cf_free(M.actor) == true
			and c.dlg_story_ll(M.actor) == true and c.dlg_story_ms(M.actor) == true and c.dlg_story_oa(M.actor) == true
			and c.may_take("lttz_ll_task_1", 1) == true, M.nick .. ": every gate open, every task takeable, as the stock")
		check(c.client_may_write("drx_sl_coop_story_ll") == false and c.client_may_write("drx_sl_current_task") == true
			and c.client_may_write("drx_sl_current_task@dolg") == true,
			M.nick .. ": a client never writes the world's story record; every other key as the stock")
		local regs = 0
		for _, list in pairs(M.callbacks) do
			for _, f in ipairs(list) do
				local info = debug.getinfo(f, "S")
				if info and info.source and info.source:find("coop_srv_storyline", 1, true) then regs = regs + 1 end
			end
		end
		check(regs == 0 and M.handlers.coop_sl_req == nil and M.handlers.coop_sl_news == nil,
			M.nick .. ": no callback, no event of the server's storyline")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
