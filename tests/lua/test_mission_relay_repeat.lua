-- coop_quests_missions, RELAY map: every relayed dialog action refuses a second call (a repeat must change nothing).
-- For each entry of RELAY: put the world where the action is due, run it through the host relay once (it must run), let the
-- pacing window (1 s) pass, call it again (it must be refused by the entry's guard, because the first call changed the state),
-- then put the state back and call a third time (it must run: the refusal was the guard's, not the NPC check or the pacing).
-- An entry whose guard cannot refuse (function() return true end) is listed in KNOWN_REPEATS with the reason, and the test
-- asserts what really happens: the repeat runs and leaves the state as it was. A key of RELAY in neither table fails the test:
-- a new entry needs a repeat guard and a case here (or an explicit exception).
-- The stock functions are stubs that do the state change of the real ones (stock file and line in each case).
-- Run: tools\test_lua.cmd mission_relay_repeat
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story",
	"coop_quests_missions" }
local PACE_WAIT_MS = 1500 -- the module paces one action from one player to one a second (PACE_MS = 1000)

-- the debug upvalue `name` of a function or of any function it references (RELAY is a local of the module)
local function find_upvalue(root, name)
	local seen, queue = {}, { root }
	while #queue > 0 do
		local f = table.remove(queue, 1)
		if not seen[f] then
			seen[f] = true
			local i = 1
			while true do
				local n, v = debug.getupvalue(f, i)
				if not n then break end
				if n == name then return v end
				if type(v) == "function" then queue[#queue + 1] = v end
				i = i + 1
			end
		end
	end
end

-- The host's memory of its own relayed runs ("module.function" -> time): the guards of actions with no state of their own.
local function ran_at_of(M) return find_upvalue(M.env.coop_quests_missions.on_game_start, "ran_at") end
local function forget_runs(M) for k in pairs(ran_at_of(M)) do ran_at_of(M)[k] = nil end end

-- ---------------------------------------------------------------- the cases
-- stock: what the real function does to the host's state. reset: puts the world where the action is due.
local function starts(tid) -- a dialog that creates squads and calls give_task(tid) (tasks_defense.script:295, :318; GAMMA tasks_mystery_of_the_swamps.script:15)
	return {
		task = tid,
		stock = function(M, a, b) M.tm:give_task(tid, b and b:id()) end,
		reset = function(M) M.tm.task_info[tid] = nil end,
	}
end

local function completes(tid) -- set_task_completed(tid) and the reward (tasks_defense.script:343, :379); due while the task is open
	return {
		task = tid,
		stock = function(M) M.tm:set_task_completed(tid) M.rewards = (M.rewards or 0) + 1 end,
		reset = function(M) M.tm.task_info[tid] = nil M.tm:give_task(tid) end,
	}
end

local function guide_of(M) return M.guide.offer, M.guide.job end

local CASES = {
	-- activate moves the offer into the running job, complete pays and clears it (GAMMA tasks_guide.script:393, :405)
	["tasks_guide.activate"] = {
		stock = function(M) local offer, job = guide_of(M) job.squad_id, offer.squad_id = offer.squad_id, nil end,
		reset = function(M) local offer, job = guide_of(M) offer.squad_id, job.squad_id = 5, nil end,
	},
	["tasks_guide.complete"] = {
		stock = function(M) local _, job = guide_of(M) job.squad_id = nil M.rewards = (M.rewards or 0) + 1 end,
		reset = function(M) local _, job = guide_of(M) job.squad_id = 5 end,
	},
	["tasks_mystery_of_the_swamps.start_task"] = starts("task_mystery_of_the_swamps"),
	["tasks_defense.barrier_defense_monolith_start"] = starts("barrier_defense_monolith"),
	["tasks_defense.barrier_defense_zombie_start"] = starts("barrier_defense_zombie"),
	["tasks_defense.barrier_defense_monolith_complete"] = completes("barrier_defense_monolith"),
	["tasks_defense.barrier_defense_zombie_complete"] = completes("barrier_defense_zombie"),
	["dialogs_lostzone.set_impending_doom_timer"] = { -- save_ctime(db.actor, "impending_doom_timer", game.get_game_time()) (dialogs_lostzone.script:419)
		stock = function(M) M.env.save_ctime(M.env.db.actor, "impending_doom_timer", M.env.game.get_game_time()) end,
		reset = function(M) local st = M.env.db.storage[0] if st.pstor then st.pstor.impending_doom_timer = nil end end,
	},
}

-- Actions that give a task and make the world its target (documents, a device, artefacts, PDAs): a dialog action runs on a
-- client, where a world spawn is refused. The host runs it; the task is the guard.
local START_TASKS = {
	["operacia_monolith.give_task_esc_military_docs_poisk"] = "esc_military_docs_task", -- alife():create(military_escape_docs)
	["operacia_monolith.cs_story_task0"] = "cs_story_task0", -- alife():create(cs_anom_pribor)
	["dialogs_agr_u.give_agr_u_bandit_boss_task_1"] = "agr_u_bandit_boss_task_1", -- alife_create_item(af_blood_af_iam, npc)
	["ah_dialogs.pirogov_give_quest1"] = "ah_pirogov_quest1", ["ah_dialogs.pirogov_give_quest3"] = "ah_pirogov_quest3",
	["ah_dialogs.chernov_give_quest1"] = "ah_chernov_quest1", ["ah_dialogs.chernov_give_quest4"] = "ah_chernov_quest4",
	["ah_dialogs.chernov_give_quest5"] = "ah_chernov_quest5",
	["ah_dialogs.juk_give_quest1"] = "ah_juk_quest1", ["ah_dialogs.juk_give_quest2"] = "ah_juk_quest2",
	["ah_dialogs.juk_give_quest3"] = "ah_juk_quest3",
	["ah_dialogs.vorobushkin_give_quest1"] = "ah_vorobushkin_quest1", ["ah_dialogs.vorobushkin_give_quest2"] = "ah_vorobushkin_quest2",
}
for full, tid in pairs(START_TASKS) do CASES[full] = starts(tid) end

-- The story checkpoints: scenario_autosave(...) and nothing else (dialogs.script, GAMMA): no state to read, the host remembers.
local function stateless() return { stock = function() end, reset = forget_runs } end
for _, fn in ipairs({ "leave_zone_save", "save_uni_travel_zat_to_jup", "save_uni_travel_zat_to_pri", "save_uni_travel_jup_to_zat",
	"save_uni_travel_jup_to_pri", "save_uni_travel_pri_to_zat", "save_uni_travel_pri_to_jup", "save_jup_b218_travel_jup_to_pas",
	"save_pri_a17_hospital_start", "save_jup_a10_gonna_return_debt", "save_jup_b6_arrived_to_fen", "save_jup_b6_arrived_to_ash_heap",
	"save_jup_b19_arrived_to_kopachy", "save_zat_b106_arrived_to_chimera_lair", "save_zat_b5_met_with_others" }) do
	CASES["dialogs." .. fn] = stateless()
end
-- alife():create("af_medusa", point): once, the dialog's own info (fanat_training_anomaly_reached_done) is given with the phrase
CASES["dialogs_mlr.spawn_1_11_af_medusa_kmb"] = stateless()
-- give_info jup_b202_bandit_hited(_by_actor) and set_squad_goodwill(jup_b202_bandit_squad, enemy): one bandit squad, one time
CASES["dialogs_jupiter.jup_b202_hit_bandit_from_actor"] = stateless()

-- Agroprom underground's bandit boss (dialogs_agr_u.script): axr_companions.dismiss_special_squad clears the companion table,
-- release_special_squad dismisses and releases the story squad after a fade-out, remove_squad releases the escort squad
CASES["dialogs_agr_u.dimiss_agr_u_bandit_boss"] = {
	stock = function(M) M.env.axr_companions.companion_squads[9] = nil end,
	reset = function(M) M.env.axr_companions.companion_squads[9] = true end,
}
CASES["dialogs_agr_u.remove_agr_u_bandit_boss"] = {
	stock = function(M) M.story_squads.agr_u_bandits_boss_squad = nil end,
	reset = function(M) M.story_squads.agr_u_bandits_boss_squad = { id = 9 } forget_runs(M) end,
}
CASES["dialogs_agr_u.remove_agr_u_bandit_squad"] = {
	stock = function(M) M.story_squads.agr_u_bandits_squad = nil end,
	reset = function(M) M.story_squads.agr_u_bandits_squad = { id = 10 } end,
}
-- npc.health = 1; npc.radiation = 0 (dialogs.script, GAMMA): a healthy NPC needs nothing
CASES["dialogs.give_hip_medic_potion"] = {
	stock = function(M) M.npc.health, M.npc.radiation = 1, 0 end,
	reset = function(M) M.npc.health, M.npc.radiation = 0.4, 0.2 end,
}
-- axr_task_manager.hostages_by_id[id] = nil (dialogs.script rescue_hostage)
CASES["dialogs.rescue_hostage"] = {
	stock = function(M) M.env.axr_task_manager.hostages_by_id[M.npc:id()] = nil end,
	reset = function(M) M.env.axr_task_manager.hostages_by_id[M.npc:id()] = true end,
}
-- hidden_threat.sl_hidden_threat_task_3: give_task, give_info(hidden_threat_task_3_start), create_reward
CASES["hidden_threat.sl_hidden_threat_task_3"] = {
	stock = function(M) M.infos.hidden_threat_task_3_start = true M.rolled = (M.rolled or 0) + 1 end,
	reset = function(M) M.infos.hidden_threat_task_3_start = nil end,
}
-- xr_bribe.set_bribe(faction, 25, days * 86400): M_DATA[faction] = { distance, duration, start }
local BRIBE_FACTIONS = { "army", "bandit", "csky", "dolg", "ecolog", "freedom", "killer", "stalker" }
local function bribe(faction, seconds, distance)
	return {
		stock = function(M) M.bribes[faction] = { distance = distance or 25, duration = seconds, start = NOW } end,
		reset = function(M) M.bribes[faction] = nil end,
	}
end
for _, faction in ipairs(BRIBE_FACTIONS) do
	for _, days in ipairs({ 2, 4 }) do
		CASES["xr_bribe.bribe_" .. days .. "_days_" .. faction] = bribe(faction, days * 86400)
	end
end
-- utils_slht.bribe_exclusive_2_hours_stalker: set_bribe("stalker", 0, 12000)
CASES["dialogs_hidden_threat.postcond_dialog_jurov_4"] = bribe("stalker", 12000, 0)

-- Entries that cannot refuse a repeat. Each one says why that is harmless; snapshot() is what a repeat must leave unchanged.
local KNOWN_REPEATS = {
	-- RELAY guard is function() return true end. The stock function is `M.before_attack_talk = true` (tasks_pump_station_defense.script:47):
	-- a flag that nothing clears while the task lives (:131/:134/:379 only read it; cleanup() empties M at :185), so a second
	-- call writes the value that is already there. The pacing, the NPC reach and the talk window still apply to it. The one
	-- stray effect is a call when no task runs (the flag lands on the emptied M and survives into the next run, which then
	-- skips the commander's first talk): only a modified client sends that, the dialog is offered once.
	["tasks_pump_station_defense.give_before_attack_talk"] = {
		why = "sets one boolean that is already true (M.before_attack_talk); only a call outside the task has an effect",
		stock = function(M) M.pump_flag = true end,
		reset = function(M) M.pump_flag = nil end,
		snapshot = function(M) return tostring(M.pump_flag) end,
	},
}

-- ---------------------------------------------------------------- the world
local function setup_world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.on_complete = {}
	M.npc = M.new_obj(700, "esc_m_trader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	M.calls = {}
	M.guide = { offer = {}, job = {} }
	M.bribes = {}
	e.coop_mods_core = {
		find_local = function(_, name)
			if name == "M_DATA" then return M.bribes end
			return name == "guid" and M.guide.offer or M.guide.job
		end,
	}
	e.axr_task_manager.hostages_by_id = {}
	M.story_squads = { agr_u_bandits_boss_squad = { id = 9 }, agr_u_bandits_squad = { id = 10 } }
	e.get_story_squad = function(sid) return M.story_squads[sid] end
	e.axr_companions = { companion_squads = { [9] = true } }
	e.utils_data = { CTime_from_table = function(t) return t end }
	e.game.get_game_time = function() return { diffSec = function(_, t0) return (NOW - t0) / 1000 end } end
	e.get_object_squad = function() return { id = 5 } end
	e.tasks_guide = { prec_5 = function() return true end }
	e.save_ctime = function(obj, k, v) e.save_var(obj, k, v) end -- the host's save/load pair, over the same storage
	e.load_ctime = function(obj, k) return e.load_var(obj, k) end
end

local function split(full) return full:match("^([%w_]+)%.([%w_]+)$") end

-- the stock function of `full` on machine M: records the call, then does the state change of the real one
local function install_stock(M, full)
	local mod, fn = split(full)
	local case = CASES[full] or KNOWN_REPEATS[full]
	local tbl = rawget(M.env, mod) or {}
	M.env[mod] = tbl
	tbl[fn] = function(a, b)
		M.calls[#M.calls + 1] = full
		if case then case.stock(M, a, b) end
	end
	if case and case.task then M.ini[case.task] = M.ini[case.task] or {} end
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- the client's avatar on the host
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
for _, M in ipairs({ Hm, Cm }) do
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
end

local RELAY = find_upvalue(Hm.env.coop_quests_missions.on_game_start, "RELAY")
check(type(RELAY) == "table", "RELAY is reachable through the upvalues of coop_quests_missions.on_game_start"
	.. " (renamed or moved? then expose relay_names() in the module and read the keys from there)")
if type(RELAY) ~= "table" then
	print(string.format("%d passed, %d failed", PASSES, FAILS))
	os.exit(1)
end
local names = {}
for full, guard in pairs(RELAY) do
	names[#names + 1] = full
	check(type(guard) == "function", full .. ": the guard is a function")
end
table.sort(names)
check(#names > 0, "RELAY lists " .. #names .. " actions")

for _, full in ipairs(names) do
	for _, M in ipairs({ Hm, Cm }) do install_stock(M, full) end
end
for _, M in ipairs({ Hm, Cm }) do
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
end
check(Hm.handlers["quests.act"] ~= nil, "the host handles quests.act")

-- the dialog action as a client's player triggers it; the host handles the request once the pacing window is over
local function client_calls(full)
	local mod, fn = split(full)
	NOW = NOW + PACE_WAIT_MS
	Cm.env[mod][fn](Cm.actor, Cm.npc)
	pump()
end

local function fresh_world()
	Hm.tm.task_info = {}
	Hm.engine_tasks = {}
	Hm.calls, Cm.calls = {}, {}
	Hm.rewards, Hm.pump_flag = nil, nil
	Hm.log = {}
end

-- ---------------------------------------------------------------- every key has a case
print("== every RELAY entry has a repeat case")
for _, full in ipairs(names) do
	local covered = CASES[full] ~= nil or KNOWN_REPEATS[full] ~= nil
	check(covered, full .. ": a repeat case in CASES, or an explicit KNOWN_REPEATS entry with the reason"
		.. " (a new RELAY entry needs a guard that a first call turns off)")
	check(not (CASES[full] and KNOWN_REPEATS[full]), full .. ": in one table only")
end
for _, tbl in ipairs({ CASES, KNOWN_REPEATS }) do
	for full in pairs(tbl) do check(RELAY[full] ~= nil, full .. ": the case belongs to an entry that is still in RELAY") end
end

-- ---------------------------------------------------------------- the repeat
for _, full in ipairs(names) do
	local case = CASES[full]
	if case then
		print("== " .. full .. ": the second call is refused")
		fresh_world()
		case.reset(Hm)
		check(RELAY[full](Hm.npc) == true, full .. ": the action is due before the first call")
		client_calls(full)
		check(#Hm.calls == 1 and Hm.calls[1] == full, full .. ": the first call runs on the host, once")
		check(#Cm.calls == 0, full .. ": ...and does not run on the client")
		check(RELAY[full](Hm.npc) == false, full .. ": the guard says 'not due' after it")
		Hm.log = {}
		client_calls(full)
		check(#Hm.calls == 1, full .. ": the second call, after the pacing window, is refused")
		check(has_log(Hm, "relay '" .. full .. "' from #1 refused: not due now"),
			full .. ": ...by the guard (logged 'not due now'), not by the NPC check")
		case.reset(Hm)
		client_calls(full)
		check(#Hm.calls == 2, full .. ": control: with the state put back the same call runs again (the refusal was the guard's)")
	end
end

print("== entries that repeat (KNOWN_REPEATS)")
for _, full in ipairs(names) do
	local case = KNOWN_REPEATS[full]
	if case then
		fresh_world()
		case.reset(Hm)
		check(RELAY[full](Hm.npc) == true, full .. ": due before the first call")
		client_calls(full)
		check(#Hm.calls == 1 and Hm.calls[1] == full, full .. ": the first call runs on the host, once")
		local after_first = case.snapshot(Hm)
		check(RELAY[full](Hm.npc) == true, full .. ": the guard still says 'due' (it cannot refuse)")
		client_calls(full)
		check(#Hm.calls == 2, full .. ": the second call runs again; if this FAILS the guard was fixed:"
			.. " move the entry from KNOWN_REPEATS to CASES")
		check(case.snapshot(Hm) == after_first, full .. ": ...and the repeat leaves the state as it was")
		print("  note KNOWN REPEAT " .. full .. ": a second call runs (harmless: " .. case.why .. ")")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
