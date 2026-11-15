-- Anomaly Coop test (stage 4 of docs/plans/2026-11-16-storylines-per-faction.md): with split levels and story mode a main
-- story (Living Legend, Mortal Sin, Operation Afterglow) belongs to the faction that started it; Hollow Boundaries is ISG's.
-- coop_storyline.owner_of_task answers for every lttz_* task, the middle dialogs are gated (DXML over the REAL stock
-- dialogs_lostzone_*.xml), the players outside the owner's faction get one news line per world-changing step.
-- Not shipped. Run: tools\test_lua.cmd storyline_lttz
dofile("tests/lua/support/harness_storyline.lua")

local LL1, LL2, MS1 = "lttz_ll_find_doctor", "lttz_ll_turn_off_brain_scorcher", "lttz_ms_greh_envoy"
local FACTIONS_OF = { [501] = "dolg", [502] = "bandit" }
local OWN = { [1] = "dolg", [2] = "bandit" }
local OLD_INFOS = nil -- infos of the host's world at load (a save of before)

STORYLINE_HOOK = function(M)
	for _, id in ipairs({ LL1, LL2, MS1, "lttz_hb_x" }) do M.ini[id] = M.ini[id] or {} end
	if M.role ~= "host" then
		M.env.gameplay_disguise._test_load(OWN[M.self_peer])
		return
	end
	local chars = {}
	for id, f in pairs(FACTIONS_OF) do chars[id] = { f = f } end
	M.storage_state.coop_faction = { chars = chars, old = {} }
	for i in pairs(OLD_INFOS or {}) do M.infos[i] = true end
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
	OLD_INFOS = opts.infos
	math.randomseed(1)
	setup(split, opts.active)
	if opts.active ~= false then
		ticks(Hm)
		ticks(A, 2)
		ticks(B, 2)
		ticks(Hm, 2)
	end
	return Hm.env.coop_storyline
end

local function give(peer, id) Hm.env.coop_tasks.run_as(peer, function() Hm.tm:give_task(id, 9) end) end
local function news_to(M, step)
	local n = 0
	for _, t in ipairs(M.tips) do if t == "st_coop_news_sl_" .. step then n = n + 1 end end
	return n
end

-------------------------------------------------------------------------------
section("DXML: the middle dialogs of the real dialogs_lostzone_ll / _ms / _oa.xml")
do
	world(true)
	local mx = load_script(Hm, "modxml_coop_storyline")
	Hm.callbacks.on_xml_read = nil
	mx.on_xml_read()
	local cb = Hm.callbacks.on_xml_read[1]
	local gated = {}
	for _, k in ipairs({ "ll", "ms", "oa" }) do
		local path = "temp/stock_configs/configs/gameplay/dialogs_lostzone_" .. k .. ".xml"
		local xo = dxml_over(path)
		cb("gameplay\\dialogs_lostzone_" .. k .. ".xml", xo)
		local n, wrong, faction_gated = 0, 0, 0
		for _, ins in ipairs(xo.inserted) do
			local id = ins.where.attr.id
			if ins.xml ~= "<precondition>coop_storyline.dlg_story_" .. k .. "</precondition>" or gated[id] then wrong = wrong + 1 end
			gated[id] = k
			n = n + 1
			for _, p in ipairs(xo:query("dialog[id=" .. id .. "] > precondition")) do
				if (xo:getText(p) or ""):find("dialogs.actor_true_", 1, true) then faction_gated = faction_gated + 1 end
			end
		end
		check(n > 0 and wrong == 0 and faction_gated == 0, k .. ": " .. n .. " middle dialogs gated with dlg_story_" .. k
			.. ", none of a faction leader")
		check(table.concat(dxml_dump(xo.root, true), "\n") == table.concat(dxml_dump(dxml_over(path).root), "\n") and xo.mutations == 0,
			k .. ": otherwise the stock XML, element for element")
		local again = #xo.inserted
		cb("gameplay\\dialogs_lostzone_" .. k .. ".xml", xo)
		check(#xo.inserted == again, k .. ": a second read adds nothing")
	end
	check(gated.doctor_living_legend == "ll" and gated.barkeep_living_legend == "ll" and gated.aslan_living_legend == "ll"
		and gated.beard_living_legend == "ll" and gated.living_legend_strelok_start == "ll" and gated.living_legend_strelok_answers == "ll",
		"LL: the Doctor, the Barkeep, Aslan, Beard, Strelok")
	check(gated.voronin_living_legend == nil and gated.sidorovich_mortal_sin == nil and gated.lukash_operation_afterglow == nil,
		"the faction leaders' start dialogs are not (they have their faction condition)")
	check(gated.greh_envoy_dialog == "ms" and gated.strelok_finale_dialogue == "oa", "MS: the Sin envoy; OA: Strelok's finale")
end

-------------------------------------------------------------------------------
section("Living Legend started by a Duty player: its tasks are Duty's, kept over save / load")
do
	local sl = world(true)
	check(sl.owner_of_task(LL1) == nil and sl.owner_of_task("lttz_hb_x") == "isg", "before: no owner; Hollow Boundaries is ISG's")
	-- anna's start dialog (dialogs_lostzone_ll.xml: lukash / voronin / ... _living_legend) gives the first task through the world
	Hm.infos.living_legend = true
	give(1, LL1)
	ticks(Hm, 4)
	check(sl.owner_of_task(LL1) == "dolg" and sl.owner_of_task(LL2) == "dolg" and sl.owner_of_task("lttz_ll_anything") == "dolg",
		"every lttz_ll_* task is Duty's")
	check(sl.owner_of_task(MS1) == nil and sl.owner_of_task("lttz_hb_y") == "isg", "MS: nobody yet; HB: isg")
	-- a later task of the story given to boris (a bandit) does not change the owner
	give(2, LL2)
	ticks(Hm, 4)
	check(sl.owner_of_task(LL2) == "dolg", "the owner stays Duty")
	check(sl.may_take(LL2, 2) == false and sl.may_take(LL2, 1) == true and sl.may_take(MS1, 2) == true and sl.may_take("lttz_hb_z", 1) == false,
		"authority twin may_take: an LL task for a bandit no, for Duty yes; MS (no owner) yes; HB for Duty no")
	-- the clients read the owner from the world's mirror
	ticks(Hm, 4)
	check(pstor(A).drx_sl_coop_story_ll == "dolg" and pstor(B).drx_sl_coop_story_ll == "dolg", "mirrored to the clients")
	check(A.env.coop_storyline.dlg_story_ll(A.actor) == true, "anna (Duty): the Doctor, Barkeep, ... talk to her")
	check(B.env.coop_storyline.dlg_story_ll(B.actor) == false, "boris (bandit): closed")
	check(sl.dlg_story_ll(Hm.actor) == false, "the host player (loner): closed")
	check(A.env.coop_storyline.dlg_story_ms(B.actor) == true and B.env.coop_storyline.dlg_story_oa(B.actor) == true,
		"MS and OA (no owner): open")
	check(Hm.env.coop_storyline.client_may_write("drx_sl_coop_story_ll") == false, "a client cannot write the mirror (coop_tvd)")
	-- save / load
	Hm.env.SendScriptCallback("save_state", Hm.storage_state)
	local fresh = load_script(Hm, "coop_storyline")
	fresh.on_game_start()
	for _, f in ipairs(Hm.callbacks.actor_on_first_update) do f() end
	check(fresh.owner_of_task(LL1) == "dolg" and fresh.owner_of_task("lttz_ll_other") == "dolg", "a new Lua state knows the owner")
end

-------------------------------------------------------------------------------
section("a save of before: a running main story with no owner is the world faction's")
do
	local sl = world(true, { infos = { living_legend = true } })
	check(sl.owner_of_task(LL1) == "stalker" and sl.owner_of_task(MS1) == nil, "LL runs: the world's faction (loners); MS: nobody")
	give(1, MS1)
	ticks(Hm, 4)
	check(sl.owner_of_task(MS1) == "dolg" and sl.owner_of_task(LL1) == "stalker", "MS started later by anna: Duty's; LL stays")
end

-------------------------------------------------------------------------------
section("news: the players outside the owner's faction get one line per step")
do
	local sl = world(true)
	Hm.infos.living_legend = true
	give(1, LL1)
	ticks(Hm, 4)
	local sent0 = count_sent(Hm, "coop_sl_news")
	Hm.infos.bar_deactivate_radar_done = true
	ticks(Hm, 4)
	ticks(Hm, 4)
	local targets = {}
	for _, ev in ipairs(Hm.sent) do if ev.name == "coop_sl_news" then targets[#targets + 1] = tostring(ev.target) end end
	check(count_sent(Hm, "coop_sl_news") == sent0 + 1 and last_sent(Hm, "coop_sl_news").n == "scorcher_off"
		and table.concat(targets, ",") == "2", "one event, to boris only")
	check(news_to(B, "scorcher_off") == 1 and news_to(A, "scorcher_off") == 0, "boris (bandit) reads it once, anna (Duty, the owner) not")
	check(news_to(Hm, "scorcher_off") == 1, "the host player (loner) reads it on his machine")
	Hm.infos.yan_labx16_switcher_primary_off = true
	ticks(Hm, 4)
	check(news_to(B, "mm_off") == 1 and news_to(A, "mm_off") == 0 and news_to(Hm, "mm_off") == 1, "the Miracle Machine off: the same")
	Hm.infos.bar_deactivate_radar_done = nil
	ticks(Hm, 4)
	check(news_to(B, "scorcher_on") == 1 and news_to(A, "scorcher_on") == 0, "the Scorcher on again: once")
	-- forged or unknown lines
	B.env.coop.send_event("coop_sl_news", H.encode({ n = "scorcher_off" }), 1)
	Hm.env.coop.send_event("coop_sl_news", H.encode({ n = "%s%s" }), 1)
	pump()
	check(news_to(A, "scorcher_off") == 0 and #A.tips == 0, "anna: a line from another client or an unknown step is dropped")
	-- a reload does not repeat a step
	local before = count_sent(Hm, "coop_sl_news")
	Hm.env.SendScriptCallback("save_state", Hm.storage_state)
	local fresh = load_script(Hm, "coop_storyline")
	fresh.on_game_start()
	for _, f in ipairs(Hm.callbacks.actor_on_first_update) do f() end
	ticks(Hm, 8)
	check(count_sent(Hm, "coop_sl_news") == before, "after a reload: no line repeated")
end

section("a step with no main story running: no line")
do
	world(true)
	Hm.infos.bar_deactivate_radar_done = true
	ticks(Hm, 8)
	check(count_sent(Hm, "coop_sl_news") == 0 and news_to(Hm, "scorcher_off") == 0, "Sakharov's side task: nobody owns it, nobody is told")
end

-------------------------------------------------------------------------------
section("group mode and sandbox: no owners, every gate true, no news")
do
	local sl = world(false)
	Hm.infos.living_legend = true
	give(1, LL1)
	Hm.infos.bar_deactivate_radar_done = true
	ticks(Hm, 8)
	check(sl.owner_of_task(LL1) == nil and sl.owner_of_task("lttz_hb_x") == nil, "no owner")
	check(A.env.coop_storyline.dlg_story_ll(A.actor) == true and B.env.coop_storyline.dlg_story_ll(B.actor) == true
		and sl.dlg_story_ll(Hm.actor) == true, "every middle dialog open")
	check(count_sent(Hm, "coop_sl_news") == 0 and (Hm.storage_state.coop_storyline == nil), "no news, no record")
	sl = world(true, { story = false })
	Hm.infos.living_legend = true
	give(1, LL1)
	ticks(Hm, 8)
	check(sl.owner_of_task(LL1) == nil and B.env.coop_storyline.dlg_story_ll(B.actor) == true, "sandbox: the same")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
