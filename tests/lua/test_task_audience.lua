-- A task's audience in a split-levels world (docs\plans\2026-11-16-task-audience.md A, C): coop_task_audience decides who sees a
-- task when it is given, coop_tasks sends its states, lists and news only to them (and to the map servers' bridges), refuses
-- the requests of the others and shares its rewards only among them. Without split levels, or on an engine without the
-- filter, everything is as before.
-- Run: tools\test_lua.cmd task_audience
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_reward_group", "coop_tasks", "coop_task_audience" }
local BRIDGE = 0x101

local W = {
	split = true, dedicated = false,
	fac = { [0] = "stalker", [500] = "dolg", [501] = "dolg", [502] = "stalker", [503] = "dolg" },
	rel = {}, gw = {},
	eng = {}, eng_calls = 0, resent = {},
	members = { { id = 500, peer = 1, in_world = true }, { id = 501, peer = 2, in_world = true } },
}

local Hm = machine("host", 0)
local e = Hm.env

-- the world: three players, the host plays (a listen world server)
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 }, { id = 2, avatar_id = 501 } }
Hm.new_obj(500, "coop_player_avatar", vec(10, 0, 0))
Hm.new_obj(501, "coop_player_avatar", vec(20, 0, 0))
Hm.share = 0
Hm.ObjMT.money = function(self) return self._money or 0 end
e.get_console = function()
	return { get_integer = function(_, name) return name == "coop_share_rewards" and Hm.share or 0 end }
end
e.ini_sys.r_bool_ex = function(_, sec, key, def) return def end
e.coop.is_dedicated = function() return W.dedicated end
e.coop.members = function() return W.members end
e.coop.levels = { map_servers = function() return { { bridge = BRIDGE, level = 9 } } end, level_of_player = function() return nil end }
local function engine_binding(id, t)
	W.eng_calls = W.eng_calls + 1
	if t == nil then
		W.eng[id] = nil
		return true
	end
	assert(type(t) == "table", "the binding takes a table")
	if #t > 64 then return false end
	local copy = {}
	for i, c in ipairs(t) do copy[i] = c end
	W.eng[id] = copy
	return true
end
e.coop.story_task_audience = engine_binding
e.coop.story_resend_tasks = function(peer)
	W.resent[#W.resent + 1] = peer
	return true
end
e.AddScriptCallback = function() end

-- coop_faction's contract (gamedata\scripts\coop_faction.script header): split_mode, faction_of_character
e.coop_faction = {
	split_mode = function() return W.split end,
	faction_of_character = function(c) return W.fac[c] end,
}
-- stock relation_registry (engine): community_relation(faction, faction), community_goodwill(faction, character id)
e.relation_registry = {
	community_relation = function(a, b) return W.rel[a .. ">" .. b] or 0 end,
	community_goodwill = function(f, c) return W.gw[f .. ">" .. tostring(c)] or 0 end,
}
e.game_relations = { ENEMIES = -1000 } -- stock game_relations.script:36

-- givers as the server objects of the stock (luabind userdata): offline, never on the level here (level.object_by_id: nil)
local SE = {}
local function se(t) return luabind_object(t) end
local function stalker(comm, group) return se({ group_id = group or 65535, community = function() return comm end }) end
SE[700] = stalker("bandit")
SE[701] = stalker("trader", 800) -- a trader in a squad of freedom (dialogs.script:105-112)
SE[800] = se({ player_id = "freedom", commander_id = function() return 701 end })
SE[702] = stalker("trader") -- a trader with no squad: "stalker"
SE[801] = se({ player_id = "", commander_id = function() return 703 end }) -- a squad: its commander's community
SE[703] = stalker("bandit", 801)
SE[802] = se({ player_id = "army", commander_id = function() return 703 end })
SE[704] = stalker("monster")
SE[705] = stalker("freedom")
SE[706] = stalker("stalker")
local stock_alife_object = e.alife_object
e.alife_object = function(id) return SE[id] or stock_alife_object(id) end

for _, id in ipairs({ "t_side1", "t_side2", "t_side3", "t_free", "t_gated", "t_none", "t_monster", "t_off", "t_noeng", "t_thr",
	"t_gw", "drx_sl_bar_task_1", "lttz_hb_task", "drx_sl_esc_m_trader_cf_task_1", "t_money", "t_group" }) do Hm.ini[id] = {} end

for _, n in ipairs(SCRIPTS) do load_script(Hm, n) end
for _, n in ipairs(SCRIPTS) do e[n].on_game_start() end
fire(Hm, "actor_on_first_update")
local CT, AUD = e.coop_tasks, e.coop_task_audience

-- CGameTaskManager::UpdateTasks (as test_tasks_sync.lua)
local function engine_check()
	for id, t in pairs(Hm.engine_tasks) do
		if t.state == "in" then
			if e.task_manager.task_complete(id) then
				t.state = "done"
				e.task_manager.task_callback(t, e.task.completed)
			elseif e.task_manager.task_fail(id) then
				t.state = "fail"
				e.task_manager.task_callback(t, e.task.fail)
			end
		end
	end
end

local function give(peer, id, giver)
	CT.run_as(peer, function() Hm.tm:give_task(id, giver) end)
end

-- targets of the messages `name` about task `id` sent since `from`
local function targets(name, id, from)
	local out = {}
	for i = (from or 1), #Hm.sent do
		local s = Hm.sent[i]
		if s.name == name and H.decode(s.payload).i == id then out[s.target] = (out[s.target] or 0) + 1 end
	end
	return out
end

local function listed_to(peer, id, from)
	for i = (from or 1), #Hm.sent do
		local s = Hm.sent[i]
		if s.name == "coop_tl_list" and s.target == peer and s.payload:find(id, 1, true) then return true end
	end
	return false
end

local function last_to(name, peer)
	for i = #Hm.sent, 1, -1 do
		local s = Hm.sent[i]
		if s.name == name and s.target == peer then return H.decode(s.payload) end
	end
end

local function set(list)
	local t = {}
	for _, c in ipairs(list or {}) do t[c] = true end
	return t
end

local function same(list, want)
	local a = set(list)
	local n = 0
	for _ in pairs(a) do n = n + 1 end
	if n ~= #want then return false end
	for _, c in ipairs(want) do if not a[c] then return false end end
	return true
end

-- ---------------------------------------------------------------- off
print("== no split levels: no record, no engine call, everything to everybody")
do
	W.split = false
	local mark = #Hm.sent
	give(2, "t_off", 700)
	tick(Hm)
	check(AUD.record("t_off") == nil and W.eng_calls == 0, "nothing recorded, the engine is not called")
	check(targets("coop_tl", "t_off", mark + 1)[-1] == 1, "the state goes to everybody (-1)")
	W.split = true
	check(AUD.record("t_off") == nil, "turning split on later judges nothing old")
end

print("== an engine without coop.story_task_audience: everything as today")
do
	e.coop.story_task_audience = nil
	local mark = #Hm.sent
	give(2, "t_noeng", 700)
	tick(Hm)
	check(AUD.record("t_noeng") == nil and W.eng_calls == 0, "no record, no call")
	check(targets("coop_tl", "t_noeng", mark + 1)[-1] == 1, "the state goes to everybody")
	check(has_log(Hm, "has no coop.story_task_audience"), "one log line says so")
	e.coop.story_task_audience = engine_binding
end

-- ---------------------------------------------------------------- classify, givers
print("== classify by id")
do
	check(AUD.classify("drx_sl_esc_m_trader_cf_task_1") == "cf", "drx_sl_*_cf_task_* is a change-faction task")
	check(AUD.classify("drx_sl_bar_dolg_general_petrenko_stalker_cf_task_1") == "cf", "a long cf id too")
	check(AUD.classify("drx_sl_bar_task_1") == "story", "other drx_sl_* is storyline")
	check(AUD.classify("lttz_hb_task") == "story", "lttz_* is storyline")
	check(AUD.classify("coop_scorcher_on_task") == "story", "the Scorcher pair's task is its faction's alone")
	check(AUD.classify("esc_2_12_stalker_nimble_task_1") == "side", "anything else is a side task")
end

print("== the giver's faction, offline")
do
	check(AUD.giver_faction(700) == "bandit", "a stalker's community")
	check(AUD.giver_faction(701) == "freedom", "a trader: his squad's player_id")
	check(AUD.giver_faction(702) == "stalker", "a trader with no squad: stalker")
	check(AUD.giver_faction(801) == "bandit", "a squad without player_id: its commander's community")
	check(AUD.giver_faction(802) == "army", "a squad: its player_id")
	check(AUD.giver_faction(704) == nil, "a monster: nothing")
	check(AUD.giver_faction(999) == nil and AUD.giver_faction(nil) == nil, "no object, no giver: nothing")
end

-- ---------------------------------------------------------------- side task
print("== side task: an enemy giver hides it from X, its taker sees it")
local side_mark
do
	W.rel["bandit>dolg"] = -1000 -- exactly ENEMIES: out
	side_mark = #Hm.sent
	give(2, "t_side1", 700) -- B (dolg) takes it from a bandit
	local rec = AUD.record("t_side1")
	check(rec ~= nil and rec.k == "side" and rec.gf == "bandit" and rec.t == 501, "a side record with the giver's faction and the taker")
	check(rec and rec.inn[501] and rec.inn[0] and rec.out[500], "taker in, host (stalker) in, A (dolg) out")
	check(same(W.eng.t_side1, { 0, 501 }), "the engine got the audience before the first state")
	tick(Hm)
	local to = targets("coop_tl", "t_side1", side_mark + 1)
	check(to[2] == 1 and to[BRIDGE] == 1, "the state goes to the taker and to the bridge")
	check(to[1] == nil and to[-1] == nil, "not to A, not to everybody")
end

print("== the threshold is the stock's: relation + goodwill <= -1000")
do
	W.rel["bandit>dolg"] = -999
	give(0, "t_thr", 700)
	check(AUD.record("t_thr").inn[500] == true, "-999 is not an enemy")
	W.rel["bandit>dolg"] = -800
	W.gw["bandit>500"] = -200
	give(0, "t_gw", 700)
	check(AUD.record("t_gw").out[500] == true and AUD.record("t_gw").inn[501] == true, "goodwill counts: -800 - 200 is out, his own 0 is in")
	W.gw["bandit>500"] = nil
	W.rel["bandit>dolg"] = -1000
end

print("== trader, squad and no giver")
do
	give(1, "t_free", 701)
	check(AUD.record("t_free") and AUD.record("t_free").gf == "freedom", "a trader's task is judged by his squad's faction")
	give(1, "t_side3", 801)
	check(AUD.record("t_side3") and AUD.record("t_side3").gf == "bandit", "a squad's task by its commander")
	local mark = #Hm.sent
	give(1, "t_none", nil)
	give(1, "t_monster", 704)
	check(AUD.record("t_none") == nil and W.eng.t_none == nil, "no giver: no record")
	check(AUD.record("t_monster") == nil, "a giver with no faction: no record")
	tick(Hm)
	check(targets("coop_tl", "t_none", mark + 1)[-1] == 1, "a task with no record goes to everybody as before")
end

-- ---------------------------------------------------------------- storyline, cf
print("== storyline tasks by faction, change-faction tasks for the taker alone")
local CF = "drx_sl_esc_m_trader_cf_task_1"
do
	give(1, "drx_sl_bar_task_1", nil) -- A (dolg) takes it
	local r = AUD.record("drx_sl_bar_task_1")
	check(r and r.k == "story" and r.sf == "dolg", "the taker's true faction")
	check(r and r.inn[500] and r.inn[501] and r.out[0], "dolg in (A, B), the stalker host out")
	e.coop_storyline = { owner_of_task = function(id) return id == "lttz_hb_task" and "stalker" or nil end }
	give(1, "lttz_hb_task", nil)
	r = AUD.record("lttz_hb_task")
	check(r and r.sf == "stalker" and r.inn[0] and r.inn[500] and r.out[501], "coop_storyline's owner: stalkers and the taker")
	e.coop_storyline = nil
	give(1, CF, nil)
	r = AUD.record(CF)
	check(r and r.k == "cf" and r.inn[500] and r.out[501] and r.out[0], "a cf task: its taker alone")
	check(same(W.eng[CF], { 500 }), "the engine got only the taker")
end

-- ---------------------------------------------------------------- lists, news
print("== lists and news only to the audience and the bridges")
do
	local mark = #Hm.sent
	NOW = NOW + 20000
	tick(Hm)
	check(listed_to(2, "t_side1", mark + 1) and listed_to(BRIDGE, "t_side1", mark + 1), "the taker's and the bridge's lists have it")
	check(not listed_to(1, "t_side1", mark + 1), "A's list has not")
	check(listed_to(1, "t_none", mark + 1) and listed_to(2, "t_none", mark + 1), "a task without a record is in every list")
	local any_all = false
	for i = mark + 1, #Hm.sent do if Hm.sent[i].name == "coop_tl_list" and Hm.sent[i].target == -1 then any_all = true end end
	check(not any_all, "no list to everybody while a record is in use")

	mark = #Hm.sent
	local tsk = { get_id = function() return CF end, get_title = function() return "cf" end }
	local shown = e.news_manager.send_task(Hm.actor, "new", tsk)
	local to = targets("coop_tn", CF, mark + 1)
	check(to[1] == 1 and to[BRIDGE] == 1 and to[2] == nil and to[-1] == nil, "the task line goes to the taker and the bridge only")
	check(shown == true, "the host player, out of it, gets no line here")
	tsk = { get_id = function() return "t_side1" end, get_title = function() return "s" end }
	check(e.news_manager.send_task(Hm.actor, "new", tsk) ~= true, "a task the host sees: the stock line follows")
end

-- ---------------------------------------------------------------- requests
print("== a player out of a task can neither take, turn in, cancel nor stage it")
do
	local tq = Hm.handlers.coop_tq
	tq(H.encode({ op = "give", i = "t_side1" }), 1)
	local a = last_to("coop_tl", 1)
	check(a and a.i == "t_side1" and a.d == true and a.r == 1, "a give of a running id: 'not given' (r = 1)")
	-- the storyline side says who may take a task at all (a main story of another faction, a second change-faction task): the
	-- world asks it before the give, whatever the player's dialog let through
	local asked = {}
	Hm.env.coop_storyline = { may_take = function(id, peer)
		asked[#asked + 1] = { id = id, peer = peer }
		return not (id == "t_gated" and peer == 1)
	end }
	tq(H.encode({ op = "give", i = "t_gated" }), 1)
	check(Hm.tm.task_info.t_gated == nil, "a task the storyline side refuses him is not given")
	a = last_to("coop_tl", 1)
	check(a and a.i == "t_gated" and a.d == true, "and he is told it is not his")
	tq(H.encode({ op = "give", i = "t_gated" }), 2)
	check(#asked == 2 and asked[1].peer == 1 and asked[2].peer == 2 and asked[2].id == "t_gated",
		"the world asks for every give, with the sender taken from the transport")
	Hm.tm.task_info.t_gated = nil
	Hm.env.coop_storyline = nil
	tq(H.encode({ op = "complete", i = "t_side1" }), 1)
	a = last_to("coop_tl", 1)
	check(a and a.d == true and a.r == nil, "a turn-in: the task is not there for him")
	check(CT.recipient("t_side1") == 2 and Hm.tm.task_info.t_side1.forced_status == nil, "the task was not touched")
	tq(H.encode({ op = "cancel", i = "t_side1" }), 1)
	check(Hm.tm.task_info.t_side1.forced_status == nil, "a cancel is refused")
	tq(H.encode({ op = "stage", i = "t_side1", st = 3 }), 1)
	check(Hm.tm.task_info.t_side1.stage == 0, "a stage is refused")
	tq(H.encode({ op = "stage", i = "t_side1", st = 3 }), 2)
	check(Hm.tm.task_info.t_side1.stage == 3, "the taker's stage goes through")
	tq(H.encode({ op = "complete", i = CF }), 2)
	check(Hm.tm.task_info[CF].forced_status == nil, "a cf task: B cannot turn it in")
	tq(H.encode({ op = "complete", i = CF }), 1)
	check(Hm.tm.task_info[CF].forced_status == "complete", "its taker can")
	Hm.tm.task_info[CF].forced_status = nil
	-- a bad op for a task he may not see: no state of it either
	tq(H.encode({ op = "nonsense", i = "t_side1" }), 1)
	a = last_to("coop_tl", 1)
	check(a and a.d == true and a.st == nil, "a malformed request does not leak the state")
end

-- ---------------------------------------------------------------- no re-judge
print("== decided once: a later goodwill change judges nothing again")
do
	W.rel["bandit>dolg"] = 0
	local mark = #Hm.sent
	tick(Hm)
	Hm.tm.task_info.t_side1.stage = 4
	tick(Hm)
	check(AUD.record("t_side1").out[500] == true, "A stays out")
	check(targets("coop_tl", "t_side1", mark + 1)[1] == nil, "and gets nothing")
	W.rel["bandit>dolg"] = -1000
end

-- ---------------------------------------------------------------- late joiner
print("== a late joiner is judged once at his join, per character")
do
	Hm.players[#Hm.players + 1] = { id = 3, avatar_id = 502 } -- C, a stalker
	W.members[#W.members + 1] = { id = 502, peer = 3, in_world = true }
	Hm.new_obj(502, "coop_player_avatar", vec(30, 0, 0))
	local mark = #Hm.sent
	tick(Hm)
	check(targets("coop_tl", "t_side1", 1)[3] == nil and AUD.record("t_side1").inn[502] == nil, "unjudged: nothing yet")
	Hm.handlers.coop_tl_req("", 3)
	check(AUD.record("t_side1").inn[502] == true and AUD.record("drx_sl_bar_task_1").out[502] == true, "judged at his first sync")
	check(W.resent[#W.resent] == 3, "the engine sends him his task list again")
	check(same(W.eng.t_side1, { 0, 501, 502 }), "and has him in the audience")
	check(targets("coop_tl", "t_side1", mark + 1)[3] == 1, "his sync has the side task")
	check(targets("coop_tl", "drx_sl_bar_task_1", mark + 1)[3] == nil, "not the dolg storyline")
	-- a reconnect: the same character on another peer slot is not judged again
	Hm.players[#Hm.players] = { id = 4, avatar_id = 502 }
	W.members[#W.members] = { id = 502, peer = 4, in_world = true }
	W.rel["bandit>stalker"] = -2000 -- would be out now
	local n = #W.resent
	mark = #Hm.sent
	Hm.handlers.coop_tl_req("", 4)
	check(#W.resent == n, "nothing new to judge: no resend")
	check(AUD.record("t_side1").inn[502] == true and targets("coop_tl", "t_side1", mark + 1)[4] == 1, "kept over the reconnect")
	W.rel["bandit>stalker"] = nil
end

-- ---------------------------------------------------------------- faction change
print("== a faction change moves only the storyline tasks of that character")
do
	W.fac[501] = "stalker"
	local mark = #Hm.sent
	fire(Hm, "coop_faction_changed", 2, 501, "dolg", "stalker")
	check(AUD.record("drx_sl_bar_task_1").out[501] == true, "B left the dolg storyline")
	check(AUD.record("lttz_hb_task").inn[501] == true, "and joined the stalkers'")
	check(AUD.record("t_side1").inn[501] == true and AUD.record("t_gw").inn[501] == true, "side tasks stay as they were")
	check(AUD.record(CF).out[501] == true, "a cf task stays its taker's")
	check(W.resent[#W.resent] == 2, "the engine sends him his list again")
	check(listed_to(2, "lttz_hb_task", mark + 1) and not listed_to(2, "drx_sl_bar_task_1", mark + 1), "his Lua list follows")
	check(targets("coop_tl", "lttz_hb_task", mark + 1)[2] == 1, "the state of the task he gained")
	check(not set(W.eng.drx_sl_bar_task_1)[501] and set(W.eng.lttz_hb_task)[501], "the engine's entries follow")
end

-- ---------------------------------------------------------------- rewards
print("== rewards: only the audience, an outsider replaced by the taker")
do
	-- personal effects (reputation, statistics, goodwill go through each_personal): the audience only
	local seen = {}
	Hm.on_complete = Hm.on_complete or {}
	Hm.on_complete.t_side1 = function()
		CT.each_personal(function() seen[#seen + 1] = CT.personal_character() end)
		e.dialogs.relocate_money(Hm.actor, 900, "in")
	end
	Hm.share = 1 -- money split over the players in the game
	for i = #Hm.money_calls, 1, -1 do Hm.money_calls[i] = nil end
	local before = Hm.actor:money()
	Hm.handlers.coop_tq(H.encode({ op = "complete", i = "t_side1" }), 2)
	engine_check()
	local paid = {}
	for _, c in ipairs(Hm.money_calls) do if c.ok ~= false then paid[c.peer] = (paid[c.peer] or 0) + (c.n or 0) end end
	check(paid[1] == nil, "A (out) gets no money")
	check((paid[2] or 0) > 0 and (paid[4] or 0) > 0 and Hm.actor:money() > before, "B, C and the host share it")
	check(same(seen, { 0, 501, 502 }), "personal effects for the audience only (" .. table.concat(seen, ",") .. ")")

	-- coop_share_rewards 2: the reward group cut to the audience
	Hm.share = 2
	give(2, "t_group", 700)
	Hm.on_complete.t_group = function() e.dialogs.relocate_money(Hm.actor, 300, "in") end
	for i = #Hm.money_calls, 1, -1 do Hm.money_calls[i] = nil end
	Hm.handlers.coop_tq(H.encode({ op = "complete", i = "t_group" }), 2)
	engine_check()
	paid = {}
	for _, c in ipairs(Hm.money_calls) do if c.ok ~= false then paid[c.peer] = (paid[c.peer] or 0) + (c.n or 0) end end
	check(paid[1] == nil and (paid[2] or 0) > 0, "the group's money skips A")

	-- a recipient who is out (the host player turned the cf task in at the giver): the taker gets it
	Hm.share = 0
	Hm.on_complete[CF] = function() e.dialogs.relocate_money(Hm.actor, 500, "in") end
	for i = #Hm.money_calls, 1, -1 do Hm.money_calls[i] = nil end
	local hm = Hm.actor:money()
	give(1, CF, nil) -- given anew: nobody has turned it in
	Hm.talking = true -- the host player turns it in at the giver
	Hm.tm:set_task_completed(CF)
	Hm.talking = false
	engine_check()
	paid = {}
	for _, c in ipairs(Hm.money_calls) do if c.ok ~= false then paid[c.peer] = (paid[c.peer] or 0) + (c.n or 0) end end
	check(paid[1] == 500 and Hm.actor:money() == hm, "the cf task's money goes to its taker, not to the host who is out")
end

-- ---------------------------------------------------------------- prune, re-give
print("== the record goes with its task, a re-give judges anew")
do
	tick(Hm)
	-- the engine keeps a finished task in the journal for ever: its audience stays (D1)
	check(AUD.record("t_side1") ~= nil and AUD.record("t_side1").fin == true and W.eng.t_side1 ~= nil,
		"a finished task: its record stays (finished) and so does its engine entry")
	Hm.tm.task_info.t_free = nil
	local mark = #Hm.sent
	tick(Hm)
	local to = targets("coop_tl", "t_free", mark + 1)
	check(AUD.record("t_free") ~= nil and AUD.record("t_free").fin == true and W.eng.t_free ~= nil, "a removed task: kept, finished")
	check(to[2] == 1 and to[BRIDGE] == 1 and to[-1] == nil, "its removal goes to its audience and the bridge")
	Hm.tm.task_info.t_monster = nil
	tick(Hm)
	give(1, "t_side2", 700)
	check(AUD.record("t_side2").out[501] == nil, "B (now a stalker) is judged in by a new give")
	Hm.tm.task_info.t_side2 = nil
	Hm.engine_tasks.t_side2 = nil
	tick(Hm)
	W.rel["bandit>stalker"] = -1000
	give(1, "t_side2", 700)
	check(AUD.record("t_side2").out[501] == true, "the same id given again: judged again")
	W.rel["bandit>stalker"] = nil
end

-- ---------------------------------------------------------------- save, load
print("== save and load: the records come back, the engine gets them again")
do
	local md = {}
	fire(Hm, "save_state", md)
	check(type(md.coop_task_audience) == "table" and md.coop_task_audience.t_side2 ~= nil, "saved with the world")
	W.eng = {} -- story::reset
	fire(Hm, "load_state", md)
	check(next(W.eng) == nil, "nothing pushed during the load")
	local r = AUD.record("t_side2")
	check(r and r.k == "side" and r.gf == "bandit" and r.t == 500 and r.inn[500] and r.out[501] and r.out[0], "the record is whole")
	tick(Hm)
	check(W.eng.t_side2 ~= nil and W.eng.lttz_hb_task ~= nil, "pushed to the engine on the first tick after the load")
	local n = W.eng_calls
	tick(Hm)
	check(W.eng_calls == n, "once")
end

-- ---------------------------------------------------------------- dedicated
print("== a dedicated world server: peer 0 is nobody")
do
	W.dedicated = true
	local tsk = { get_id = function() return "lttz_hb_task" end, get_title = function() return "l" end }
	check(e.news_manager.send_task(Hm.actor, "new", tsk) == true, "no line on its ghost for a task with an audience")
	W.dedicated = false
end

for _, id in ipairs({ "t_fin1", "t_fin2", "t_fin3", "t_fin4", "t_run", "t_eng", "lttz_hb_d5" }) do Hm.ini[id] = {} end

local function finish_task(id)
	Hm.tm.task_info[id] = nil -- it ends: the Lua task goes, the engine keeps it in the journal
	Hm.engine_tasks[id] = nil
	tick(Hm)
end

local function count_log(pat)
	local n = 0
	for _, l in ipairs(Hm.log) do if l:find(pat, 1, true) then n = n + 1 end end
	return n
end

-- ---------------------------------------------------------------- D1: finished tasks
print("== D1: a finished hidden task stays hidden (record and engine entry kept)")
do
	W.rel["bandit>dolg"] = -1000
	give(2, "t_fin1", 700) -- B (a stalker now) takes it from a bandit: A (dolg) is out
	local r = AUD.record("t_fin1")
	check(r and r.inn[501] == true and r.out[500] == true and not r.fin, "running: B in, A out")
	finish_task("t_fin1")
	r = AUD.record("t_fin1")
	check(r ~= nil and r.fin == true and r.inn[501] == true and r.out[500] == true, "finished: the record stays, marked finished")
	check(W.eng.t_fin1 ~= nil and same(W.eng.t_fin1, { 0, 501, 502 }), "the engine's entry stays: A is not sent the finished task")
	check(AUD.sees_character("t_fin1", 500) == false and AUD.sees_character("t_fin1", 501) == true,
		"A does not see it, B does (same ids)")

	-- a late joiner: judged for the running tasks, never for a finished one (he never had it)
	give(2, "t_run", 700)
	W.fac[504] = "stalker"
	Hm.players[#Hm.players + 1] = { id = 5, avatar_id = 504 }
	W.members[#W.members + 1] = { id = 504, peer = 5, in_world = true }
	Hm.new_obj(504, "coop_player_avatar", vec(40, 0, 0))
	Hm.handlers.coop_tl_req("", 5)
	check(AUD.record("t_run").inn[504] == true and set(W.eng.t_run)[504] == true, "a running task: the late joiner is judged in")
	check(AUD.record("t_fin1") ~= nil and AUD.record("t_fin1").inn[504] == nil and W.eng.t_fin1 ~= nil and not set(W.eng.t_fin1)[504],
		"a finished task: he stays out of it")

	-- the request gate: an outsider's request about the finished task is refused there, the insider's is not
	local tq = Hm.handlers.coop_tq
	tq(H.encode({ op = "complete", i = "t_fin1" }), 1)
	check(has_log(Hm, "#1: complete 't_fin1' refused: not his task"), "A's turn-in of the finished hidden task: refused by the gate")
	tq(H.encode({ op = "complete", i = "t_fin1" }), 2)
	check(not has_log(Hm, "#2: complete 't_fin1' refused: not his task"), "B's request passes the gate (same task)")
	local a = last_to("coop_tl", 1)
	check(a and a.i == "t_fin1" and a.d == true and a.st == nil, "A learns nothing of it")
	-- a new give of that id is a new task: judged anew, whoever asks (the engine's give refuses only a running task too)
	tq(H.encode({ op = "give", i = "t_fin1", g = 700 }), 1)
	r = AUD.record("t_fin1")
	check(Hm.tm.task_info.t_fin1 ~= nil and r and not r.fin and r.t == 500 and r.inn[500] == true, "a re-give recomputes the record")
	finish_task("t_fin1")

	-- the late joiner's list does not start listing the finished task, nor the lists of the others
	local mark = #Hm.sent
	NOW = NOW + 20000
	tick(Hm)
	check(not listed_to(5, "t_fin1", mark + 1) and not listed_to(1, "t_fin1", mark + 1), "no list carries a finished task")
	check(listed_to(5, "t_run", mark + 1), "the running one is in his list")
end

print("== D1: finished records are saved and given to the engine again after a load")
do
	give(2, "t_fin2", 700)
	finish_task("t_fin2")
	local md = {}
	fire(Hm, "save_state", md)
	local s = md.coop_task_audience
	check(type(s) == "table" and type(s.t_fin2) == "table" and s.t_fin2.f == true and type(s.t_fin2.n) == "number",
		"a finished record is saved, with its mark and its number")
	check(type(s.t_run) == "table" and s.t_run.f == nil, "a running one has no mark")
	W.eng = {} -- story::reset
	fire(Hm, "load_state", md)
	tick(Hm)
	check(AUD.record("t_fin2") and AUD.record("t_fin2").fin == true, "it comes back finished")
	check(W.eng.t_fin2 ~= nil and same(W.eng.t_fin2, { 0, 501, 502, 504 }), "and the engine has its audience again")
	check(W.eng.t_run ~= nil, "the running ones as before")
end

print("== D1: at most FINISHED_MAX finished records; the oldest go first, one log line")
do
	check(AUD.FINISHED_MAX == 2000, "the bound is 2000")
	AUD.FINISHED_MAX = 2
	give(2, "t_fin3", 700)
	finish_task("t_fin3") -- finished after the load: a newer number than t_fin2's
	local before = count_log("finished task audiences dropped")
	give(2, "t_fin4", 700)
	finish_task("t_fin4")
	check(AUD.record("t_fin3") and AUD.record("t_fin4") and W.eng.t_fin3 ~= nil and W.eng.t_fin4 ~= nil, "the two newest stay")
	check(AUD.record("t_fin2") == nil and W.eng.t_fin2 == nil, "an older one is dropped and its engine entry cleared")
	check(AUD.record("t_side1") == nil and W.eng.t_side1 == nil, "every older one")
	check(AUD.record("t_run") ~= nil, "a running record is never dropped by the bound")
	check(count_log("finished task audiences dropped") == before + 1, "one log line for the batch")
	AUD.FINISHED_MAX = 2000
end

-- ---------------------------------------------------------------- D2: the engine's give
print("== D2: a give through the engine (host_on_task_give) asks coop_storyline.may_take for its player")
do
	local asked = {}
	e.coop_storyline = { may_take = function(id, peer)
		asked[#asked + 1] = { id = id, peer = peer }
		return not (id == "t_eng" and peer == 1)
	end }
	-- coop_story.cpp host_on_task_give: lua_note("taker", id, from), then tm:give_task(id, giver) on the host
	CT.host_note("t_eng", "taker", 1)
	local ok, err = pcall(function() Hm.tm:give_task("t_eng", 700) end)
	check(ok, "a refused give raises no error (" .. tostring(err) .. ")")
	check(Hm.tm.task_info.t_eng == nil and Hm.engine_tasks.t_eng == nil, "refused for A: no task")
	check(AUD.record("t_eng") == nil and W.eng.t_eng == nil, "no record, no engine entry")
	check(#asked == 1 and asked[1].peer == 1 and asked[1].id == "t_eng", "asked for the player the give is for")
	CT.host_note("t_eng", "taker", 2)
	Hm.tm:give_task("t_eng", 700)
	check(Hm.tm.task_info.t_eng ~= nil and AUD.record("t_eng") and AUD.record("t_eng").t == 501, "the same id for B: given")
	finish_task("t_eng")
	-- a script's give with nobody to attribute it to is not the storyline's to refuse
	e.coop_storyline.may_take = function() return false end
	Hm.tm:give_task("t_eng", 700)
	check(Hm.tm.task_info.t_eng ~= nil, "a script's give for nobody is not refused")
	e.coop_storyline = nil
end

-- ---------------------------------------------------------------- D5 (audience side)
print("== D5: an older character's first word re-judges the storyline tasks for him")
do
	W.fac[504] = nil -- an older save's character that has not told his faction yet
	give(2, "lttz_hb_d5", nil) -- B (stalker) takes a storyline task
	check(AUD.record("lttz_hb_d5").out[504] == true and AUD.record("lttz_hb_d5").inn[501] == true, "unknown: out (B in)")
	W.fac[504] = "stalker"
	local n = #W.resent
	fire(Hm, "coop_faction_changed", 5, 504, nil, "stalker") -- coop_faction after the bootstrap claim: old = nil
	check(AUD.record("lttz_hb_d5").inn[504] == true and set(W.eng.lttz_hb_d5)[504] == true, "now in")
	check(#W.resent == n + 1 and W.resent[#W.resent] == 5, "and his list is sent again")
end

-- ---------------------------------------------------------------- D8: a session started again
print("== D8: a session started again without a load gets every audience again")
do
	tick(Hm)
	W.split = false -- the session ends: off
	tick(Hm)
	W.eng = {} -- the engine clears its table when a session starts
	W.split = true
	tick(Hm)
	check(W.eng.t_run ~= nil and W.eng.lttz_hb_d5 ~= nil and W.eng.t_fin3 ~= nil, "every record is pushed again when it comes on")
	local n = W.eng_calls
	tick(Hm)
	check(W.eng_calls == n, "once")
end

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
