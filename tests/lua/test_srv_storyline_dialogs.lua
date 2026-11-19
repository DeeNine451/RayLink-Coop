-- Anomaly Coop test (stage 3 of docs/plans/2026-11-16-storylines-per-faction.md): with split levels and story mode a player
-- talks "storyline business" only with a leader his own faction's chain holds; the readers of the chain keys read the
-- talker's faction's keys; the change-faction lock is the player's own. The DXML gates (modxml_coop_storyline.script) are
-- checked against the REAL dialog files (temp/gamma_ref, temp/stock_configs) through a stand-in of the documented DXML API
-- (tests/lua/support/harness_storyline.lua). Not shipped. Run: tools\test_lua.cmd srv_storyline_dialogs
dofile("tests/lua/support/harness_storyline.lua")

local SULTAN, SID, PETRENKO, NOAH = "zat_b7_bandit_boss_sultan", "esc_m_trader", "bar_dolg_general_petrenko_stalker", "zat_b18_noah"
local GAMMA_DIALOGS = "temp/gamma_ref/configs/gameplay/dialogs.xml"
local STOCK_DIALOGS_XML = "temp/stock_configs/configs/gameplay/dialogs.xml"
local CF = "drx_sl_" .. PETRENKO .. "_cf_task_1"
local CF2 = "drx_sl_" .. SULTAN .. "_cf_task_1"
local CF3 = "drx_sl_" .. SID .. "_cf_task_1"
local FACTIONS_OF = { [501] = "dolg", [502] = "bandit" }
local OWN = { [1] = "dolg", [2] = "bandit" } -- the clients' own true faction (gameplay_disguise on their machine)

STORYLINE_HOOK = function(M)
	for _, id in ipairs({ CF, CF2, CF3 }) do M.ini[id] = M.ini[id] or {} end
	if M.role ~= "host" then
		M.env.gameplay_disguise._test_load(OWN[M.self_peer])
		return
	end
	local chars = {}
	for id, f in pairs(FACTIONS_OF) do chars[id] = { f = f } end
	M.storage_state.coop_faction = { chars = chars, old = {} }
end

local function ticks(M, n)
	for _ = 1, n or 8 do
		tick(M)
		pump()
	end
end

local function world(split, opts)
	opts = opts or {}
	STORY = opts.story ~= false
	ALIVE = opts.alive
	REL = {}
	math.randomseed(1)
	setup(split, opts.active)
	if opts.active ~= false then
		ticks(Hm)
		ticks(A, 2)
		ticks(B, 2)
		ticks(Hm, 2)
	end
	return Hm.env.coop_srv_storyline
end

local function chain(M, f, k) return pstor(M)[k .. "@" .. f] end
local function npc(M, h) return M.leader[h] end
local function mirror() ticks(Hm, 2) end
local function start_dlg(h) return "drx_sl_" .. h .. "_game_start_dialog_1" end
local function meet_dlg(h) return "drx_sl_" .. h .. "_meet_dialog" end
local function leader_ok(M, h, dlg) return M.env.coop_srv_storyline.dlg_leader(M.actor, npc(M, h), dlg) end

local function last_refusal(M)
	for i = #M.log, 1, -1 do
		local l = M.log[i]
		if l:find("chain request", 1, true) and l:find("refused", 1, true) then return l end
	end
	return ""
end

local function read(path)
	local fh = assert(io.open(path, "rb"))
	local s = fh:read("*a")
	fh:close()
	return s
end

-------------------------------------------------------------------------------
section("DXML: the gates on the real gameplay\\dialogs.xml")
do
	world(true)
	local mx = load_script(Hm, "modxml_coop_storyline")
	Hm.callbacks.on_xml_read = nil
	mx.on_xml_read()
	local cb = Hm.callbacks.on_xml_read and Hm.callbacks.on_xml_read[1]
	check(type(cb) == "function", "on_xml_read registers its callback")
	for _, path in ipairs({ GAMMA_DIALOGS, STOCK_DIALOGS_XML }) do
		local xo = dxml_over(path)
		cb([[gameplay\dialogs.xml]], xo)
		-- what the file holds, by its raw text (not by the script's own query)
		local raw = read(path):gsub("<!%-%-.-%-%->", "")
		local want = {}
		local n_meet, n_start = 0, 0
		for id in raw:gmatch('<dialog id="(drx_sl_[%w_]-_meet_dialog)"') do want[id] = "coop_conditions_stock.dlg_leader"; n_meet = n_meet + 1 end
		for id in raw:gmatch('<dialog id="(drx_sl_[%w_]-_game_start_dialog_%d+)"') do want[id] = "coop_conditions_stock.dlg_leader"; n_start = n_start + 1 end
		want.drx_sl_change_faction_dialog = "coop_conditions_stock.dlg_cf_free"
		local got, n_got = {}, 0
		for _, ins in ipairs(xo.inserted) do
			local id = ins.where.attr.id
			local fn = ins.xml:match("^<precondition>([%w_%.]+)</precondition>$")
			if ins.where.name == "dialog" and fn and got[id] == nil then got[id] = fn; n_got = n_got + 1 else got[id] = "DOUBLE" end
		end
		local same, n_want = true, 0
		for id, fn in pairs(want) do n_want = n_want + 1; if got[id] ~= fn then same = false end end
		check(same and n_got == n_want, path .. ": a gate on each of the " .. n_meet .. " meet, " .. n_start
			.. " start dialogs and the join dialog, nothing else (" .. n_got .. " inserted)")
		if path == GAMMA_DIALOGS then
			check(n_meet == 26 and n_start == 10, "G.A.M.M.A.: 26 meet dialogs, 10 start dialogs (12 factions, 10 start leaders)")
		end
		-- the Petrenko start dialog keeps its stock conditions and gets one precondition more
		local el = xo:query("dialog[id=" .. start_dlg(PETRENKO) .. "]")[1]
		local has = {}
		for _, k in ipairs(el.kids) do if k.name then has[#has + 1] = k.name .. "=" .. tostring(xo:getText(k)) end end
		check(table.concat(has, ",") == "has_info=drx_sl_start_game_" .. PETRENKO .. ",has_info=drx_questlines_about_info,phrase_list=nil,precondition=coop_conditions_stock.dlg_leader",
			"Petrenko's start dialog: its two has_info, its phrases, then the gate")
		local again = #xo.inserted
		cb([[gameplay\dialogs.xml]], xo)
		check(#xo.inserted == again, "a second read inserts nothing more")
		check(table.concat(dxml_dump(xo.root, true), "\n") == table.concat(dxml_dump(dxml_over(path).root), "\n") and xo.mutations == 0,
			"without the inserted preconditions the XML is the stock's, element for element")
	end
	local other = dxml_over(GAMMA_DIALOGS)
	cb([[gameplay\dialogs_bar.xml]], other)
	check(#other.inserted == 0, "another file is not touched")
	local saved = Hm.env.coop
	Hm.env.coop = nil
	Hm.callbacks.on_xml_read = nil
	mx.on_xml_read()
	check(Hm.callbacks.on_xml_read == nil, "an exe without co-op: nothing registered")
	Hm.env.coop = saved
end

-------------------------------------------------------------------------------
section("split levels: each player talks storyline with the leaders his faction's chain holds")
do
	local sl = world(true)
	mirror()
	check(leader_ok(A, PETRENKO, start_dlg(PETRENKO)) == true, "anna (Duty, client): Petrenko's start dialog is open (her chain holds him)")
	check(leader_ok(A, SULTAN, start_dlg(SULTAN)) == false, "anna: Sultan's start dialog is closed (the bandits' chain)")
	check(leader_ok(B, SULTAN, start_dlg(SULTAN)) == true, "boris (bandit, client): Sultan's is open")
	check(leader_ok(B, PETRENKO, start_dlg(PETRENKO)) == false, "boris: Petrenko's is closed")
	check(leader_ok(Hm, SID, start_dlg(SID)) == true and leader_ok(Hm, PETRENKO, start_dlg(PETRENKO)) == false,
		"the host player (loner): Sidorovich yes, Petrenko no (authority: claim_of)")
	check(sl.dlg_leader(Hm.actor, npc(Hm, SULTAN), nil) == false and sl.dlg_leader(Hm.actor, npc(Hm, SID), nil) == true,
		"no dialog id: the leader is told by the NPC")
	-- anna's start dialog on her machine: the phrase's actions, then its XML <disable_info> on her own actor (the engine:
	-- CDialogScriptHelper::Action runs the actions, then TransferInfo)
	A.infos["drx_sl_start_game_" .. PETRENKO] = true -- her mirror of the world's info
	local sent0 = count_sent(A, "coop_sl_req")
	A.env.xr_effects.drx_sl_decrease_sl_tasks_count(A.actor, npc(A, PETRENKO))
	A.env.xr_effects.drx_sl_meet_random_honcho(A.actor, npc(A, PETRENKO))
	A.actor:disable_info_portion("drx_sl_start_game_" .. PETRENKO)
	pump()
	local x = chain(Hm, "dolg", "drx_sl_current_honcho")
	check(count_sent(A, "coop_sl_req") == sent0 + 1 and x ~= PETRENKO and chain(Hm, "dolg", "drx_sl_current_task_number") == 2,
		"one start request; the world moved Duty's chain once (to " .. tostring(x) .. ")")
	check(Hm.infos["drx_sl_start_game_" .. PETRENKO] == nil and A.infos["drx_sl_start_game_" .. PETRENKO] == nil,
		"the start info is off on the world and on her machine: the two agree")
	-- the same dialog again (a stale mirror, a second click): refused, nothing moves, the info stays off on both
	NOW = NOW + 1500
	A.env.xr_effects.drx_sl_meet_random_honcho(A.actor, npc(A, PETRENKO))
	pump()
	check(last_refusal(Hm):find("from #1 refused", 1, true) ~= nil and chain(Hm, "dolg", "drx_sl_current_task_number") == 2
		and Hm.infos["drx_sl_start_game_" .. PETRENKO] == nil, "a second start is refused by the world; the info is not given back")
	mirror()
	check(leader_ok(A, x, meet_dlg(x)) == true, "anna: the meet dialog of her chain's new leader is open")
	-- what the audience does for boris' machine: Duty's meet task is not in his list (coop_srv_task_audience: a chain task to its faction)
	B.tm.task_info["drx_sl_" .. x .. "_meet_task_1"] = nil
	check(leader_ok(B, x, meet_dlg(x)) == false and leader_ok(Hm, x, meet_dlg(x)) == false, "boris and the host player: closed")
	check(leader_ok(A, PETRENKO, start_dlg(PETRENKO)) == false, "anna: Petrenko's start dialog is closed now (her chain moved on)")
	check(leader_ok(B, SULTAN, meet_dlg(SULTAN)) == true, "boris: Sultan, his chain's leader, still open")
end

-------------------------------------------------------------------------------
section("the finished-task lookup: another faction's chain task is not offered for turn-in")
do
	local sl = world(true, { alive = { [NOAH] = true, [SULTAN] = true } })
	-- Duty's chain at Noah with a task given to anna (as the give request records it)
	local T1 = "drx_sl_" .. NOAH .. "_task_1"
	sl.with_chain("dolg", function()
		Hm.env.save_var(Hm.actor, "drx_sl_current_honcho", NOAH)
		Hm.env.save_var(Hm.actor, "drx_sl_current_task", T1)
	end)
	Hm.env.coop_tasks.run_as(1, function() Hm.tm:give_task(T1, 9) end)
	NOW = NOW + 1500
	A.env.coop.send_event("coop_sl_req", H.encode({ k = "give", h = NOAH, t = T1 }), 0)
	pump()
	check(sl.owner_of_task(T1) == "dolg", "the task is Duty's")
	Hm.tm.task_info[T1].stage = 254
	mirror()
	A.engine_tasks[T1] = { state = "in", get_id = function() return T1 end }
	check(Hm.env.dialogs.drx_sl_actor_has_finished_task(Hm.actor, npc(Hm, NOAH)) == false,
		"the host player (loner) at Noah: Duty's finished task is not his to turn in (the host's machine holds every task)")
	check(Hm.stock_fn.finished(npc(Hm, NOAH)) == T1, "(the stock lookup alone would offer it)")
	check(A.env.dialogs.drx_sl_actor_has_finished_task(A.actor, npc(A, NOAH)) == true, "anna (Duty) at Noah: offered")
	-- the host player's own chain task at Sidorovich, given by his own dialog
	Hm.env.dialogs.last_task_id = "drx_sl_" .. SID .. "_task_1"
	Hm.talking = true
	Hm.env.dialogs.drx_sl_give_sl_task(Hm.actor, npc(Hm, SID))
	Hm.talking = false
	local T2 = "drx_sl_" .. SID .. "_task_1"
	check(Hm.tm.task_info[T2] ~= nil and sl.owner_of_task(T2) == "stalker", "the host player's task at Sidorovich is the loners'")
	Hm.tm.task_info[T2].stage = 254
	check(Hm.env.dialogs.drx_sl_actor_has_finished_task(Hm.actor, npc(Hm, SID)) == true, "he is offered his own")
	-- a client: the audience (coop_srv_task_audience) keeps another faction's chain task out of his list; given that, the stock
	-- lookup on his machine finds nothing of it
	B.tm.task_info[T1] = nil
	B.engine_tasks[T1] = nil
	check(B.env.dialogs.drx_sl_actor_has_finished_task(B.actor, npc(B, NOAH)) == false, "boris: nothing to turn in at Noah")
end

-------------------------------------------------------------------------------
section("the ending and its text read the talker's faction's keys")
do
	local sl = world(true)
	sl.with_chain("dolg", function()
		Hm.env.save_var(Hm.actor, "drx_sl_total_task_number", 9)
		Hm.env.save_var(Hm.actor, "drx_sl_current_task_number", 9)
	end)
	sl.with_chain("stalker", function()
		Hm.env.save_var(Hm.actor, "drx_sl_total_task_number", 10)
		Hm.env.save_var(Hm.actor, "drx_sl_current_task_number", 3)
	end)
	mirror()
	for _, M in ipairs({ Hm, A, B }) do M.infos.bar_deactivate_radar_done = true end
	check(A.env.dialogs.drx_sl_is_endgame(A.actor, npc(A, PETRENKO)) == true and A.env.dialogs.drx_sl_is_not_endgame(A.actor) == false,
		"anna (Duty, client): her chain is at its end (9 of 9)")
	check(B.env.dialogs.drx_sl_is_endgame(B.actor) == false, "boris (bandit, client): his is not (1 of 8-12)")
	check(Hm.env.dialogs.drx_sl_is_endgame(Hm.actor) == false, "the host player (loners, 3 of 10): not")
	sl.with_chain("stalker", function() Hm.env.save_var(Hm.actor, "drx_sl_current_task_number", 10) end)
	check(Hm.env.dialogs.drx_sl_is_endgame(Hm.actor) == true, "the loners at 10 of 10: the end")
	A.infos.bar_deactivate_radar_done = nil
	check(A.env.dialogs.drx_sl_is_endgame(A.actor) == false, "the Scorcher on: no ending (the stock rule without the pilot)")
	A.env.coop_srv_scorcher = { ending_ok = function(f) return f == "dolg" end }
	check(A.env.dialogs.drx_sl_is_endgame(A.actor) == true, "with coop_srv_scorcher: its ending_ok(her faction) decides")
	Hm.env.coop_srv_scorcher = { ending_ok = function(f) return f == "monolith" end }
	check(Hm.env.dialogs.drx_sl_is_endgame(Hm.actor) == false, "the host player: ending_ok(stalker) false, the info does not matter")
	Hm.env.coop_srv_scorcher, A.env.coop_srv_scorcher = nil, nil
	STRINGS["drx_sl_" .. PETRENKO .. "_start_game_1_endgame_1"] = "DUTY END"
	STRINGS["drx_sl_" .. SID .. "_start_game_1_endgame_1"] = "LONER END"
	check(A.env.dialogs.drx_sl_text_end_game(A.actor, npc(A, PETRENKO)) == "DUTY END", "anna's ending text is Duty's start leader's")
	check(Hm.env.dialogs.drx_sl_text_end_game(Hm.actor, npc(Hm, SID)) == "LONER END", "the host player's is the loners'")
	STRINGS["drx_sl_" .. PETRENKO .. "_start_game_1_endgame_1"] = nil
	STRINGS["drx_sl_" .. SID .. "_start_game_1_endgame_1"] = nil
	-- the default task (no task left at a leader) names the talker's chain's leader
	local nobody_a = A.new_obj(990, "nobody_here", vec(0, 0, 0), { _stalker = true })
	local nobody_h = Hm.new_obj(990, "nobody_here", vec(0, 0, 0), { _stalker = true })
	check(A.env.axr_task_manager.drx_sl_generate_random_sl_task(nobody_a) == "drx_sl_" .. PETRENKO .. "_default_task",
		"anna: the default task is her chain's leader's")
	check(Hm.env.axr_task_manager.drx_sl_generate_random_sl_task(nobody_h) == "drx_sl_" .. SID .. "_default_task",
		"the host player: the loners' leader's")
	check(A.env.load_var(A.actor, "drx_sl_current_honcho", "none") == "none" and Hm.env.load_var(Hm.actor, "drx_sl_current_honcho", "none") == "none",
		"after the call no chain is selected: the bare key reads as it is")
end

-------------------------------------------------------------------------------
section("the change-faction lock is the player's own")
do
	local sl = world(true)
	Hm.init_fx = { [CF] = function() Hm.env.give_info("drx_sl_on_cf_task") end, [CF3] = function() Hm.env.give_info("drx_sl_on_cf_task") end }
	Hm.env.coop_tasks.run_as(1, function() Hm.tm:give_task(CF, 9) end)
	check(Hm.infos.drx_sl_on_cf_task == true, "the stock on_init gave the world's lock")
	ticks(Hm, 4)
	check(Hm.infos.drx_sl_on_cf_task == nil and Hm.storage_state.coop_storyline.cf_moved == true,
		"the world keeps the info off: the XML <dont_has_info> locks nobody")
	check(A.tm.task_info[CF] ~= nil and A.env.coop_srv_storyline.dlg_cf_free(A.actor) == false, "anna (her cf task open): locked")
	-- what the audience does for boris' machine (a cf task to its taker alone, coop_srv_task_audience)
	B.tm.task_info[CF] = nil
	check(B.env.coop_srv_storyline.dlg_cf_free(B.actor) == true, "boris: anna's task does not lock him")
	check(sl.dlg_cf_free(Hm.actor) == true, "the host player: not locked by anna's task (taker #1)")
	check(sl.may_take(CF2, 1) == false and sl.may_take(CF2, 2) == true and sl.may_take(CF2, 0) == true,
		"authority twin may_take: a second cf task for anna no, for boris and the host yes")
	Hm.env.coop_tasks.run_as(0, function() Hm.tm:give_task(CF3, 9) end)
	check(sl.dlg_cf_free(Hm.actor) == false, "the host player with his own cf task: locked")
	ticks(Hm, 4)
	check(Hm.infos.drx_sl_on_cf_task == nil, "his on_init's info is taken off too")
	-- the world played without split levels again: the stock lock comes back while a cf task is open
	SPLIT = false
	fire(Hm, "actor_on_first_update")
	check(Hm.infos.drx_sl_on_cf_task == true, "no split levels: the world's lock is given back (a cf task is open)")
	check(sl.dlg_cf_free(Hm.actor) == true, "and the gate is true again (the XML locks)")
end

-------------------------------------------------------------------------------
section("group mode (no split levels): every gate true, the info lock and the readers as the stock")
do
	local sl = world(false, { alive = { [NOAH] = true } })
	Hm.init_fx = { [CF] = function() Hm.env.give_info("drx_sl_on_cf_task") end }
	Hm.env.coop_tasks.run_as(1, function() Hm.tm:give_task(CF, 9) end)
	ticks(Hm, 4)
	check(Hm.infos.drx_sl_on_cf_task == true, "the world's lock stays (stock)")
	local all = true
	for _, M in ipairs({ Hm, A, B }) do
		local g = M.env.coop_srv_storyline
		all = all and g.dlg_leader(M.actor, npc(M, SULTAN), start_dlg(SULTAN)) == true and g.dlg_leader(M.actor, npc(M, NOAH), meet_dlg(NOAH)) == true
			and g.dlg_cf_free(M.actor) == true and g.dlg_story_ll(M.actor) == true and g.dlg_story_ms(M.actor) == true and g.dlg_story_oa(M.actor) == true
		check(M.env.dialogs.drx_sl_is_endgame == M.stock_fn.is_endgame and M.env.dialogs.drx_sl_text_end_game == M.stock_fn.end_text
			and M.env.axr_task_manager.drx_sl_get_finished_task == M.stock_fn.finished
			and M.env.axr_task_manager.drx_sl_generate_random_sl_task == M.stock_fn.generate, M.nick .. ": the stock readers, not wrapped")
	end
	check(all, "every gate is true on every machine")
	check(sl.may_take(CF2, 1) == true and sl.owner_of_task("lttz_hb_x") == nil, "may_take yes, no owners")
end

section("sandbox (not story mode) and no session: every gate true")
do
	world(true, { story = false })
	check(A.env.coop_srv_storyline.dlg_leader(A.actor, npc(A, SULTAN), start_dlg(SULTAN)) == true and A.env.coop_srv_storyline.dlg_cf_free(A.actor) == true
		and A.env.dialogs.drx_sl_is_endgame == A.stock_fn.is_endgame, "sandbox: true, nothing wrapped")
	world(true, { active = false })
	check(Hm.env.coop_srv_storyline.dlg_leader(Hm.actor, npc(Hm, SULTAN), start_dlg(SULTAN)) == true and Hm.env.coop_srv_storyline.dlg_story_ll(Hm.actor) == true,
		"no session: true")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
