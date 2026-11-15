-- Anomaly Coop test (the group's faction, owner 2026-11-16): in a world WITHOUT split levels every player is in one faction.
-- A faction change is made once, on the host, for everybody (coop_faction.script); the dialogs say so first. With split
-- levels a change stays personal (coop_tasks forwards drx_sl_change_factions to the finisher, as before). A host and two
-- clients of tests/lua/support/harness_quests.lua with coop_tasks; the stock functions are their own text, copied below
-- with file and lines. Not shipped.
-- Run: tools\test_lua.cmd faction_group
dofile("tests/lua/support/harness_quests.lua")

local function section(name) print("== " .. name) end

local SPLIT = false
local SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_news", "coop_faction" }

local STRINGS = {
	st_coop_faction_group_joined = "%s joined the %s faction. The whole group is in it now.",
	st_coop_faction_away = "While you were away the group joined the %s faction.",
	st_coop_faction_by_group = "The faction is changed by the whole group at once: this is done at the faction's leader.",
	st_coop_faction_warning = "Mind this: all your comrades come over with you.",
	st_faction_dolg = "Duty", st_faction_army = "Army", st_faction_stalker = "Loners", st_faction_freedom = "Freedom",
	cf_about = "Pay 10000 and you are one of us.",
}

-------------------------------------------------------------------------------
-- Stock code, copied as it is
-------------------------------------------------------------------------------
-- temp/stock_scripts/scripts/_g.script:2425-2453
local STOCK_G = [[
function character_community(obj)
	if not (obj) then
		return
	end
	if IsStalker(obj) then
		return obj:character_community()
	end
	return "monster"
end

function get_actor_true_community() -- no "actor_"
	return gameplay_disguise.get_default_comm()
end

function set_actor_true_community(new_comm, now) -- no "actor_"
	local curr_comm = get_actor_true_community()

	-- Update disguise default faction
	gameplay_disguise.update_default(new_comm, now)

	if IsStoryMode() then
		-- Change LTTZ info portion if needed first
		dialogs_lostzone.update_lttz_faction_info(curr_comm, new_comm)

		-- Recycle DRX availability to the new faction
		xr_effects.drx_sl_cancel_questlines(nil,nil,{})
		xr_effects.drx_sl_setup_questlines(nil,nil,{new_comm})
	end
end
]]

-- temp/gamma_ref/scripts/xr_effects.script:781-821 (the commented companion block left out)
local STOCK_XR = [[
function drx_sl_change_factions( actor, npc, p ) -- Change actor faction:
	if ( p and p[1] ~= nil and p[1] ~= ("actor_" .. character_community( db.actor )) ) then

		-- Set actor faction:
		set_actor_true_community(p[1])

		local communities = utils_obj.get_communities_list()
		printf( ("DRX SL: Actor faction changed to " .. p[1]) )

		-- Send dynamic news alert:
		news_manager.send_tip( db.actor, (game.translate_string( "st_drx_questlines_joined" ) .. " " .. game.translate_string( p[1] ) .. " " .. game.translate_string( "st_drx_questlines_faction" )), nil, "completionist", nil, nil )

	end

end
]]

-- temp/gamma_ref/scripts/gameplay_disguise.script:38, 181-193, 259, 262-265, possible_factions of 166-179
local STOCK_DISGUISE = [[
local default_comm
local is_disguised = false
local possible_factions = {
	["army"] = true,
	["bandit"] = true,
	["csky"] = true,
	["dolg"] = true,
	["ecolog"] = true,
	["freedom"] = true,
	["killer"] = true,
	["monolith"] = true,
	["stalker"] = true,
	["renegade"] = true,
	["greh"] = true,
	["isg"] = true,
}
function update_default(comm, now)
	if not (comm and possible_factions[comm]) then
		printe("! ERROR update default community | community (%s) doesn't exist", tostring(comm))
		callstack()
		return
	end
	default_comm = comm
	alife_storage_manager.get_state().default_faction = comm

	if now or (not is_disguised) then
		db.actor:set_character_community("actor_"..comm, 0, 0)
	end
end
function get_default_comm()
	local def = default_comm or alife_storage_manager.get_state().default_faction or character_community(db.actor):sub(7) or "stalker"
	return def
end
function is_actor_disguised()
	return is_disguised
end
function _test_load(comm) default_comm = comm end -- the test's stand-in for actor_on_first_update (1012-1014)
]]

-- temp/gamma_ref/scripts/dialogs.script:80, 142-153, 206-213, 237-244, 297-303
local STOCK_DIALOGS = [[
last_task_id = nil
function drx_sl_actor_has_finished_cf_task( a, b )

	local npc = who_is_npc( a, b )

	local tsk = axr_task_manager and axr_task_manager.drx_sl_get_finished_cf_task( npc )
	if ( tsk == nil ) then
		return false
	end

	return true

end
function drx_sl_text_npc_has_change_factions_task_to_give( a, b )

	local npc = who_is_npc( a, b )
	local task_section = axr_task_manager and axr_task_manager.drx_sl_generate_change_factions_task( npc )
	last_task_id = task_section
	return game.translate_string( task_section and axr_task_manager.get_task_job_description( task_section ) or "st_no_available_task" )

end
function drx_sl_text_cf_task_finish( a, b )

	local npc = who_is_npc( a, b )

	local task_section = axr_task_manager and axr_task_manager.drx_sl_get_finished_cf_task( npc )
	return game.translate_string( task_section and axr_task_manager.get_task_complete_text( task_section ) or ("st_default_task_finished_" .. math.random( 1, 3 )) )

end
function drx_sl_set_finished_cf_task_complete( a, b )

	-- Set current task to complete:
	local npc = who_is_npc( a, b )
	axr_task_manager.drx_sl_set_finished_cf_task_complete( npc )

end
]]

-- temp/stock_scripts/scripts/dialog_manager.script:43-104, 138-171, 225-240 (utils_data.findfunction: utils_data.script:731-747)
local STOCK_DM = [[
local saved_dialog
function add_dialog(p_id,id,phrase_id,cond,act)
	if not ( saved_dialog ) then
		return
	end

	local phrase = saved_dialog:AddPhrase(phrase_id,tostring(id),tostring(p_id),-10000)
	if not ( phrase ) then
		return
	end

	local phrase_script = phrase:GetPhraseScript()
	if ( cond ) then
		if ( type(cond) == "table" ) then
			for key, value in pairs(cond) do
				if (utils_data.findfunction(value,_G)) then
					phrase_script:AddPrecondition(value)
				else
					printe("!ERROR dialog_manager | No such function exists '%s'",value)
				end
			end
		else
			if (utils_data.findfunction(cond,_G)) then
				phrase_script:AddPrecondition(cond)
			else
				printe("!ERROR dialog_manager | No such function exists '%s'",cond)
			end
		end
	end

	if ( act ) then
		if ( type(act) == "table" ) then
			for key, value in pairs(act) do
				if (utils_data.findfunction(value,_G)) then
					phrase_script:AddAction(value)
				else
					printe("!ERROR dialog_manager | No such function exists '%s'",value)
				end
			end
		else
			if (utils_data.findfunction(act,_G)) then
				phrase_script:AddAction(act)
			else
				printe("!ERROR dialog_manager | No such function exists '%s'",act)
			end
		end
	end
	return phrase_script
end

function add_script_dialog(p_id,id,phrase_id,cond,act)
	local d = add_dialog(p_id,id,phrase_id,cond,act)
	if (d) then
		d:SetScriptText(phrase_id)
	end
end

function drx_sl_init_change_faction_dialog( dialog )

	saved_dialog = dialog
	local base_id = 0

	add_dialog( "", (base_id + 0), "st_drx_sl_change_factions_request" )  -- Actor
		add_script_dialog( (base_id + 0), (base_id + 1), "dialogs.drx_sl_text_npc_has_change_factions_task_to_give" )  -- NPC
			add_dialog( (base_id + 1), (base_id + 2), "st_drx_sl_accept_change_factions_task", {"dialogs.not_task_is_fetch_task", "dialogs.npc_has_ordered_task_to_give"}, "dialogs.drx_sl_give_cf_task" )  -- Actor
				add_dialog( (base_id + 2), (base_id + 3), "st_drx_sl_change_factions_task_accepted" )  -- NPC
					add_dialog( (base_id + 3), (base_id + 4), "st_drx_sl_change_factions_actor_exit", nil, "dialogs.npc_clear_skipped_tasks" )  -- Actor
			add_dialog( (base_id + 1), (base_id + 5), "st_drx_sl_accept_change_factions_task", {"dialogs.task_is_fetch_task", "dialogs.npc_has_ordered_task_to_give"} )  -- Actor
				add_script_dialog( (base_id + 5), (base_id + 6), "dialogs.drx_sl_text_fetch_task", nil, "dialogs.drx_sl_give_cf_task" )  -- NPC
					add_dialog( (base_id + 6), (base_id + 7), "st_drx_sl_change_factions_actor_exit", nil, "dialogs.npc_clear_skipped_tasks" )  -- Actor
			add_dialog( (base_id + 1), (base_id + 8), "dm_universal_actor_exit", nil, "dialogs.npc_clear_skipped_tasks" )  -- Actor

end

function drx_sl_cf_task_completed_dialog( dialog )

	saved_dialog = dialog

	add_dialog( "", 0, "st_ordered_task_query_finished" )  -- Actor
		add_script_dialog( 0, 1, "dialogs.drx_sl_text_cf_task_finish", {"dialogs.drx_sl_actor_has_finished_cf_task"}, "dialogs.drx_sl_set_finished_cf_task_complete" )  -- NPC
			add_dialog( 1, 3, "dm_universal_actor_exit_thanks" )  -- Actor

end
]]

local STOCK_FINDFUNCTION = [[
function findfunction(x,tbl)
	assert(type(x) == "string")
	local f=tbl
	for v in x:gmatch("[^%.]+") do
		if type(f) ~= "table" then
			printf("looking for '%s' expected table, not %s",v,type(f))
			return
		end
		f=f[v]
	end
	if type(f) == "function" then
		return f
	else
		printf("expected function, not %s",type(f))
		return nil
	end
end
]]

-- runs `src` as the module `name` of machine M (into an existing table if there is one)
local function stock_module(M, name, src)
	local mod = M.env[name] or {}
	setmetatable(mod, { __index = M.env })
	M.env[name] = mod
	local f = assert(loadstring(src, "=stock " .. name))
	setfenv(f, mod)
	f()
	return mod
end

-------------------------------------------------------------------------------
-- A world of three machines
-------------------------------------------------------------------------------
local function setup_world(M, nick)
	local e = M.env
	M.nick = nick
	e.get_console = function() return { get_integer = function() return 0 end } end
	M.ObjMT.money = function(self) return self._money or 0 end
	M.ObjMT.set_character_community = function(self, c) self._comm = c end
	M.actor._comm = "actor_stalker"
	M.actor._stalker = true
	M.on_complete = {}
	for _, id in ipairs({ "drx_sl_bar_dolg_cf_task_1", "t_other" }) do M.ini[id] = {} end
	e.task_manager.task_ini.r_bool_ex = function(_, id, key, def) return def end
	e.task_manager.task_ini.line_exist = function(_, id, key) return M.ini[id] ~= nil and M.ini[id][key] ~= nil end
	M.storage_state = {}
	e.alife_storage_manager = { get_state = function() return M.storage_state end }
	e.coop.levels = { split = function() return SPLIT end }
	M.world_faction = nil
	e.coop.game = { set_world_faction = function(f) M.world_faction = f return true end, world_faction = function() return M.world_faction or "" end }
	e.coop.session_info = function() return { nick = nick } end
	e.game.translate_string = function(id) return STRINGS[id] or id end
	e.printe = function() end
	e.callstack = function() end
	e.IsStoryMode = function() return true end
	M.lttz, M.cancelled, M.setup = 0, 0, 0
	e.dialogs_lostzone = { update_lttz_faction_info = function() M.lttz = M.lttz + 1 end }
	e.utils_obj = { get_communities_list = function() return {} end }
	M.tips = {}
	e.news_manager.send_tip = function(actor, text) M.tips[#M.tips + 1] = tostring(text) return true end
	e.actor_menu = { set_msg = function(_, text) M.tips[#M.tips + 1] = tostring(text) end }
	e.utils_data = stock_module(M, "utils_data", STOCK_FINDFUNCTION)
	setfenv(assert(loadstring(STOCK_G, "=stock _g")), e)()
	stock_module(M, "xr_effects", STOCK_XR)
	e.xr_effects.drx_sl_cancel_questlines = function() M.cancelled = M.cancelled + 1 end
	e.xr_effects.drx_sl_setup_questlines = function(_, _, p) M.setup = M.setup + 1 M.setup_faction = p[1] end
	stock_module(M, "gameplay_disguise", STOCK_DISGUISE)
	stock_module(M, "dialogs", STOCK_DIALOGS)
	e.dialogs.who_is_npc = function() return { id = function() return 77 end } end
	-- the other stock dialog functions the join dialog names (what they do does not matter here)
	e.dialogs.not_task_is_fetch_task = function() return true end
	e.dialogs.task_is_fetch_task = function() return false end
	e.dialogs.npc_has_ordered_task_to_give = function() return e.dialogs.last_task_id ~= nil end
	e.dialogs.drx_sl_give_cf_task = function() M.cf_given = (M.cf_given or 0) + 1 end
	e.dialogs.npc_clear_skipped_tasks = function() end
	e.dialogs.drx_sl_text_fetch_task = function() return "fetch" end
	-- the stock axr_task_manager: what the dialogs ask of it
	M.cf_ready, M.cf_completions = nil, 0
	e.axr_task_manager.drx_sl_generate_change_factions_task = function() return M.cf_offer end
	e.axr_task_manager.get_task_job_description = function(id) return "cf_about" end
	e.axr_task_manager.drx_sl_get_finished_cf_task = function() return M.cf_ready end
	e.axr_task_manager.get_task_complete_text = function() return "cf_done_text" end
	e.axr_task_manager.drx_sl_set_finished_cf_task_complete = function()
		M.cf_completions = M.cf_completions + 1
		if M.cf_ready then M.tm:set_task_completed(M.cf_ready) end
		M.cf_ready = nil
	end
	stock_module(M, "dialog_manager", STOCK_DM)
end

local function engine_check(M)
	for id, t in pairs(M.engine_tasks) do
		if t.state == "in" then
			if M.env.task_manager.task_complete(id) then
				t.state = "done"
				M.env.task_manager.task_callback(t, M.env.task.completed)
			end
		end
	end
end

local Hm, A, B
local function setup(split, active)
	SPLIT = split
	MACHINES, QUEUE = {}, {}
	Hm, A, B = machine("host", 0), machine("client", 1), machine("client", 2)
	setup_world(Hm, "Host")
	setup_world(A, "anna")
	setup_world(B, "boris")
	local plist = { { id = 0, nick = "Host", avatar_id = 0 }, { id = 1, nick = "anna", avatar_id = 501 }, { id = 2, nick = "boris", avatar_id = 502 } }
	for _, M in ipairs({ Hm, A, B }) do
		M.players = {}
		for _, p in ipairs(plist) do
			M.players[#M.players + 1] = { id = p.id, nick = p.nick, avatar_id = p.avatar_id, is_self = p.id == M.self_peer }
		end
		M.active = active ~= false
	end
	Hm.new_obj(501, "coop_player_avatar", vec(1, 0, 0), { _stalker = true })
	Hm.new_obj(502, "coop_player_avatar", vec(2, 0, 0), { _stalker = true })
	for _, M in ipairs({ Hm, A, B }) do
		for _, n in ipairs(SCRIPTS) do load_script(M, n) end
		for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
		fire(M, "actor_on_first_update")
	end
	pump()
	return Hm, A, B
end

local function comm(M) return M.actor._comm end
local function has_tip(M, pat)
	for _, t in ipairs(M.tips) do if t:find(pat, 1, true) then return true end end
	return false
end
local function tips_with(M, pat)
	local n = 0
	for _, t in ipairs(M.tips) do if t:find(pat, 1, true) then n = n + 1 end end
	return n
end

-- a finished cf task turned in by machine M (the task manager is the host's)
local function client_turns_in(M, faction)
	local id = "drx_sl_bar_dolg_cf_task_1"
	M.tm:give_task(id, 9)
	pump()
	Hm.on_complete[id] = function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { faction }) end
	M.tm:set_task_completed(id)
	pump()
	engine_check(Hm)
	pump()
end

-------------------------------------------------------------------------------
-- A dialog: a userdata with AddPhrase (CPhraseDialog), its phrase scripts hold names of functions
-------------------------------------------------------------------------------
local function new_dialog()
	local phrases = {}
	local d = newproxy(true)
	getmetatable(d).__index = {
		AddPhrase = function(_, text, id, parent)
			local ph = { text = text, id = id, parent = parent, conds = {}, acts = {} }
			phrases[#phrases + 1] = ph
			local script = newproxy(true)
			getmetatable(script).__index = {
				AddPrecondition = function(_, f) ph.conds[#ph.conds + 1] = f end,
				AddAction = function(_, f) ph.acts[#ph.acts + 1] = f end,
				SetScriptText = function(_, f) ph.script = f end,
			}
			local phrase = newproxy(true)
			getmetatable(phrase).__index = { GetPhraseScript = function() return script end }
			return phrase
		end,
	}
	return d, phrases
end

local function fn_of(M, name)
	local f = M.env
	for part in name:gmatch("[^%.]+") do f = f[part] end
	return f
end

-- walks a dialog the way the engine does: the actor picks a phrase by its text, the NPC says the first child whose
-- preconditions hold. -> the texts said in order
local function talk(M, phrases, picks)
	local said = {}
	local function children(pid)
		local out = {}
		for _, ph in ipairs(phrases) do if ph.parent == pid then out[#out + 1] = ph end end
		return out
	end
	local function ok(ph)
		for _, c in ipairs(ph.conds) do if not fn_of(M, c)(M.actor, {}) then return false end end
		return true
	end
	local function say(ph)
		said[#said + 1] = ph.script and fn_of(M, ph.script)(M.actor, {}) or ph.text
		for _, a in ipairs(ph.acts) do fn_of(M, a)(M.actor, {}) end
	end
	local cur = children("")[1]
	say(cur)
	local i = 1
	while true do
		local npc
		for _, ph in ipairs(children(cur.id)) do
			if ok(ph) then npc = ph break end
		end
		if not npc then break end
		say(npc)
		local choices = children(npc.id)
		if #choices == 0 then break end
		local want = picks[i]
		i = i + 1
		local pick
		for _, ph in ipairs(choices) do
			if ok(ph) and (want == nil or ph.text == want) then pick = ph break end
		end
		if not pick then break end
		say(pick)
		cur = pick
	end
	return said
end

local function phrase_texts(phrases)
	local t = {}
	for _, ph in ipairs(phrases) do t[#t + 1] = ph.text end
	return table.concat(t, ",")
end

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
	for _, n in ipairs(SCRIPTS) do load_script(B, n) end
	for _, n in ipairs(SCRIPTS) do B.env[n].on_game_start() end
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
	check(Hm.world_faction == nil and count_sent(Hm, "coop_fac") == 0, "no group word, the world's faction stays")
	check(Hm.cancelled == 0, "the host ran no storyline recycle")
	A.env.set_actor_true_community("freedom", true)
	check(comm(A) == "actor_freedom", "a client's own call is the stock one")
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
