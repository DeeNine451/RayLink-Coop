-- Anomaly Coop test (the group's faction, owner 2026-11-16): in a world WITHOUT split levels every player is in one faction.
-- A faction change is made once, on the host, for everybody (coop_faction.script); the dialogs say so first. With split
-- levels a change stays personal (coop_tasks forwards drx_sl_change_factions to the finisher, as before). A host and two
-- clients of tests/lua/support/harness_quests.lua with coop_tasks; the stock functions are their own text, copied below
-- with file and lines. Not shipped.
-- Run: tools\test_lua.cmd faction_group
dofile("tests/lua/support/harness_faction.lua")

-------------------------------------------------------------------------------
section("group mode: the host turns in, everybody is moved")
do
	setup(false)
	check(Hm.env.coop_faction.group_mode() == true and A.env.coop_faction.group_mode() == true, "no split levels in a session: group mode")
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
	pump()
	check(comm(Hm) == "actor_dolg" and Hm.env.get_actor_true_community() == "dolg", "the host's character is in Duty")
	check(comm(A) == "actor_dolg" and comm(B) == "actor_dolg", "both clients are in Duty (" .. comm(A) .. ", " .. comm(B) .. ")")
	check(A.env.get_actor_true_community() == "dolg" and A.storage_state.default_faction == "dolg", "a client's true faction is Duty")
	check(Hm.world_faction == "dolg", "the world's faction is Duty (" .. tostring(Hm.world_faction) .. ")")
	for _, M in ipairs({ Hm, A, B }) do
		check(has_tip(M, "Host joined the Duty faction. The whole group is in it now."), M.nick .. " got the news line")
	end
	check(Hm.cancelled == 1 and Hm.setup == 1 and A.cancelled == 0 and B.cancelled == 0, "the storyline recycle ran on the host only, once")
	-- a script sets the faction the group is in already (warfare, a game mode's own bookkeeping): nobody joined anything
	local tips_h, tips_a, sent_h = #Hm.tips, #A.tips, #Hm.sent
	Hm.env.set_actor_true_community("dolg")
	pump()
	check(#Hm.tips == tips_h and #A.tips == tips_a, "the same faction set again: no news line for anybody")
	local words = 0
	for i = sent_h + 1, #Hm.sent do if Hm.sent[i].name == "coop_fac" then words = words + 1 end end
	check(words == 0, "and no word to the clients (" .. words .. ")")
	check(Hm.world_faction == "dolg", "the world's faction stays Duty")
end

section("group mode: a CLIENT turns in, the effect runs on the host")
do
	setup(false)
	client_turns_in(A, "dolg")
	local fwd = 0
	for _, s in ipairs(Hm.sent) do if s.name == "coop_trw" and s.payload:find("drx_sl_change_factions", 1, true) then fwd = fwd + 1 end end
	check(fwd == 0, "no coop_trw carries the faction effect (" .. fwd .. ")")
	check(comm(Hm) == "actor_dolg" and comm(A) == "actor_dolg" and comm(B) == "actor_dolg", "everybody is in Duty")
	check(Hm.cancelled == 1 and Hm.setup == 1 and Hm.setup_faction == "dolg", "the storyline recycle ran once, on the host")
	check(A.cancelled == 0 and A.setup == 0 and B.cancelled == 0 and A.lttz == 0, "and nowhere else")
	check(Hm.world_faction == "dolg", "the world's faction is Duty")
	check(has_tip(B, "anna joined the Duty faction"), "the news names the finisher (" .. tostring(B.tips[#B.tips]) .. ")")
	check(has_tip(Hm, "anna joined the Duty faction"), "on the host too")
end

section("group mode: a client's own call changes nothing and sends nothing")
do
	setup(false)
	local sent = #A.sent
	A.env.set_actor_true_community("freedom", true) -- the debug launcher's call
	A.env.xr_effects.drx_sl_change_factions(A.actor, nil, { "army" }) -- a dialog's effect on the client
	check(comm(A) == "actor_stalker" and A.env.get_actor_true_community() == "stalker", "the client's character did not change")
	check(#A.sent == sent, "nothing was sent to the host (" .. (#A.sent - sent) .. ")")
	pump()
	check(comm(Hm) == "actor_stalker" and Hm.world_faction == nil, "the host and the world did not change")
	check(A.cancelled == 0, "no storyline recycle on the client")
	check(has_tip(A, "changed by the whole group"), "the client is told how it is done")
end

section("group mode: a word from a non-host peer is ignored")
do
	setup(false)
	local forged = H.encode({ k = "set", f = "army", n = "anna" })
	B.handlers.coop_fac(forged, 1, "coop_fac")
	check(comm(B) == "actor_stalker", "a forged word from peer 1 moves nobody")
	Hm.handlers.coop_fac(forged, 1, "coop_fac")
	check(comm(Hm) == "actor_stalker" and Hm.world_faction == nil, "nor the host")
	B.handlers.coop_fac(H.encode({ k = "set", f = "../../x", n = "x" }), 0, "coop_fac")
	check(comm(B) == "actor_stalker", "an unknown faction from the host is refused")
	B.handlers.coop_fac(H.encode({ k = "set", f = "army", n = "%s%s%n" }), 0, "coop_fac")
	check(comm(B) == "actor_army" and has_tip(B, "%s%s%n joined the Army"), "a nick is text, never a format")
end

section("late joiner / returning player: the group's faction, once")
do
	setup(false)
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
	-- boris was away: his event is lost
	for i = #QUEUE, 1, -1 do if QUEUE[i].to == B then table.remove(QUEUE, i) end end
	pump()
	check(comm(B) == "actor_stalker", "boris was away and is still a loner")
	-- he comes back: a new Lua state of his machine
	MACHINES[3] = nil
	B = machine("client", 2)
	setup_world(B, "boris")
	B.players = A.players
	B.storage_state.default_faction = "dolg" -- the host's m_data came with the join
	for _, n in ipairs(FACTION_SCRIPTS) do load_script(B, n) end
	for _, n in ipairs(FACTION_SCRIPTS) do B.env[n].on_game_start() end
	B.env.gameplay_disguise._test_load("dolg")
	fire(B, "actor_on_first_update")
	tick(B)
	check(count_sent(B, "coop_fac_req") == 1, "the client asks the host once it is in the game")
	tick(B)
	check(count_sent(B, "coop_fac_req") == 1, "and not every frame")
	pump()
	check(comm(B) == "actor_dolg", "boris is in Duty now (" .. comm(B) .. ")")
	check(has_tip(B, "While you were away the group joined the Duty faction."), "and is told why")
	NOW = NOW + 20000
	tick(B)
	check(count_sent(B, "coop_fac_req") == 1, "an answered client stops asking")
	-- anna already has it: nothing
	local tips = #A.tips
	A.env.coop.send_event("coop_fac_req", "", 0)
	pump()
	check(comm(A) == "actor_dolg" and #A.tips == tips, "one who has the faction already gets no line")
	-- the read-only question is rate limited
	local answers = count_sent(Hm, "coop_fac")
	for _ = 1, 5 do A.env.coop.send_event("coop_fac_req", "", 0) end
	pump()
	check(count_sent(Hm, "coop_fac") == answers, "questions in a burst get no answer (" .. (count_sent(Hm, "coop_fac") - answers) .. ")")
	check(Hm.world_faction == "dolg" and comm(Hm) == "actor_dolg", "a question changes nothing on the host")
end

section("split levels: forwarding as today, only the finisher changes")
do
	setup(true)
	check(Hm.env.coop_faction.group_mode() == false, "split levels: no group mode")
	client_turns_in(A, "dolg")
	local fwd = 0
	for _, s in ipairs(Hm.sent) do if s.name == "coop_trw" and s.payload:find("drx_sl_change_factions", 1, true) then fwd = fwd + 1 end end
	check(fwd == 1, "the effect went to the finisher's machine (" .. fwd .. ")")
	check(comm(A) == "actor_dolg", "the finisher is in Duty")
	check(comm(Hm) == "actor_stalker" and comm(B) == "actor_stalker", "nobody else changed")
	local group_words = 0
	for _, s in ipairs(Hm.sent) do if s.name == "coop_fac" and H.decode(s.payload).k == "set" then group_words = group_words + 1 end end
	check(Hm.world_faction == nil and group_words == 0, "no group word (only the news of split mode), the world's faction stays")
	check(Hm.cancelled == 0, "the host ran no storyline recycle")
	A.env.set_actor_true_community("freedom", true)
	-- split mode (test_faction_split.lua): a client's own call changes nothing, only the world's forwarded effect does
	check(comm(A) == "actor_dolg" and A.cancelled == 0, "a client's own call changes nothing")
	local d, ph = new_dialog()
	A.cf_offer = "drx_sl_bar_dolg_cf_task_1"
	A.env.dialog_manager.drx_sl_init_change_faction_dialog(d)
	local said = talk(A, ph, {})
	check(said[2] == "Pay 10000 and you are one of us.", "the join dialog says no warning (" .. tostring(said[2]) .. ")")
	local d2, ph2 = new_dialog()
	A.env.dialog_manager.drx_sl_cf_task_completed_dialog(d2)
	A.cf_ready = "t_other"
	said = talk(A, ph2, {})
	check(table.concat(said, "|") == "st_ordered_task_query_finished|cf_done_text|dm_universal_actor_exit_thanks",
		"the turn-in dialog is the stock one (" .. table.concat(said, "|") .. ")")
	check(A.cf_completions == 1, "and completes once")
end

section("no session: stock")
do
	setup(false, false)
	check(Hm.env.coop_faction.group_mode() == false, "no session: no group mode")
	A.env.set_actor_true_community("army", true)
	check(comm(A) == "actor_army" and A.cancelled == 1, "a client machine without a session runs the stock function")
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
	pump()
	check(comm(Hm) == "actor_dolg" and comm(B) == "actor_stalker" and Hm.world_faction == nil, "only the host changed, no world faction")
	check(#Hm.sent == 0 or count_sent(Hm, "coop_fac") == 0, "nothing was sent")
	local d, ph = new_dialog()
	Hm.cf_offer = "x"
	Hm.env.dialog_manager.drx_sl_init_change_faction_dialog(d)
	check(talk(Hm, ph, {})[2] == "Pay 10000 and you are one of us.", "no warning outside a session")
end

section("the join dialog warns in group mode only")
do
	setup(false)
	local d, ph = new_dialog()
	A.cf_offer = "drx_sl_bar_dolg_cf_task_1"
	A.env.dialog_manager.drx_sl_init_change_faction_dialog(d)
	local said = talk(A, ph, {})
	check(said[2]:find("Pay 10000 and you are one of us.", 1, true) == 1, "the stock explanation comes first")
	check(said[2]:find("Mind this: all your comrades come over with you.", 1, true) ~= nil, "and ends with the warning (" .. said[2] .. ")")
	A.cf_offer = nil
	local d2, ph2 = new_dialog()
	A.env.dialog_manager.drx_sl_init_change_faction_dialog(d2)
	said = talk(A, ph2, {})
	check(said[2] == "st_no_available_task", "no task to give: no warning (" .. said[2] .. ")")
end

section("the turn-in dialog asks first in group mode")
do
	setup(false)
	A.tm:give_task("drx_sl_bar_dolg_cf_task_1", 9)
	pump()
	Hm.on_complete.drx_sl_bar_dolg_cf_task_1 = function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" }) end
	local d, ph = new_dialog()
	A.env.dialog_manager.drx_sl_cf_task_completed_dialog(d) -- built once (the engine keeps a dialog's phrases)
	A.cf_ready = "drx_sl_bar_dolg_cf_task_1"
	local said = talk(A, ph, { "st_coop_faction_think" })
	check(said[2] == "st_coop_faction_confirm" and said[3] == "st_coop_faction_think",
		"job done -> the last question -> think it over (" .. table.concat(said, "|") .. ")")
	check(#said == 3 and A.cf_completions == 0, "nothing was completed")
	check(A.cf_ready ~= nil and A.env.dialogs.drx_sl_actor_has_finished_cf_task(A.actor, {}) == true, "the task is still ready to be turned in")
	pump() engine_check(Hm) pump()
	check(comm(A) == "actor_stalker" and comm(Hm) == "actor_stalker", "nobody moved")
	said = talk(A, ph, { "st_coop_faction_yes" })
	check(table.concat(said, "|") == "st_ordered_task_query_finished|st_coop_faction_confirm|st_coop_faction_yes|cf_done_text|dm_universal_actor_exit_thanks",
		"yes -> the stock finish text -> leave (" .. table.concat(said, "|") .. ")")
	check(A.cf_completions == 1, "the stock completion ran once")
	pump() engine_check(Hm) pump()
	check(comm(Hm) == "actor_dolg" and comm(A) == "actor_dolg" and comm(B) == "actor_dolg", "and the whole group is in Duty")
	-- the same dialog object with split levels: the stock branch (the engine built it once for the process)
	SPLIT = true
	A.cf_ready = "t_other"
	said = talk(A, ph, {})
	check(table.concat(said, "|") == "st_ordered_task_query_finished|cf_done_text|dm_universal_actor_exit_thanks",
		"the same dialog with split levels is the stock one (" .. table.concat(said, "|") .. ")")
	SPLIT = false
end

section("the world's faction survives a save and a load of the record")
do
	-- coop_game_settings + coop_game_record in an environment of their own: a host with a record in force
	local function gs_env(m_data_actor)
		local env = setmetatable({}, { __index = _G })
		env._G = env
		local logs = {}
		env.printf = function(fmt, ...) local ok, l = pcall(string.format, fmt, ...) logs[#logs + 1] = ok and l or fmt end
		local function ser(v)
			local t = type(v)
			if t == "table" then
				local parts = {}
				for k, x in pairs(v) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
				table.sort(parts)
				return "{" .. table.concat(parts, ",") .. "}"
			elseif t == "string" then return string.format("%q", v) end
			return tostring(v)
		end
		env.marshal = { encode = function(t) return "M1" .. ser(t) end,
			decode = function(s) return assert(loadstring("return " .. s:sub(3)))() end }
		env.GAME = { faction = "" }
		env.coop = {
			is_client = function() return false end, is_active = function() return true end,
			game = { set_world_faction = function(f) env.GAME.faction = f return true end, world_faction = function() return env.GAME.faction end },
		}
		env.getFS = function() error("no file system in this test") end
		env.RegisterScriptCallback = function() end
		env.db = { actor = { character_community = function() return "actor_stalker" end, character_name = function() return "Strelok" end } }
		env.level = { present = function() return true end }
		for _, name in ipairs({ "coop_game_schema", "coop_game_record", "coop_game_settings" }) do
			local fh = assert(io.open("gamedata/scripts/" .. name .. ".script", "r"))
			local src = fh:read("*a")
			fh:close()
			local f = assert(loadstring(src, "@" .. name .. ".script"))
			local mod = setmetatable({}, { __index = env })
			env[name] = mod
			setfenv(f, mod)
			f()
		end
		return env
	end
	local e1 = gs_env()
	local rc = e1.coop_game_record
	local rec = rc.new({}, { name = "Strelok", faction = "stalker", world = { story = true } })
	e1.coop_game_settings.load_state({ coop_game = rc.clone(rec) })
	check(e1.coop_game_settings.world_faction() == "stalker", "a world of loners")
	check(type(e1.coop_game_settings.set_world_faction) == "function" and e1.coop_game_settings.set_world_faction("dolg") == true, "the setter takes Duty")
	check(e1.coop_game_settings.world_faction() == "dolg", "world_faction() says Duty")
	check(e1.GAME.faction == "dolg", "the engine got it for new characters")
	check(e1.coop_game_settings.set_world_faction("a b/../c") == false and e1.coop_game_settings.world_faction() == "dolg", "a name that is no faction is refused")
	local saved = {}
	e1.coop_game_settings.save_state(saved)
	check(type(saved.coop_game) == "table" and saved.coop_game.faction == "dolg", "the save's record holds Duty")
	local e2 = gs_env()
	e2.coop_game_settings.load_state(saved)
	check(e2.coop_game_settings.world_faction() == "dolg", "after a load the world is in Duty (" .. tostring(e2.coop_game_settings.world_faction()) .. ")")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
