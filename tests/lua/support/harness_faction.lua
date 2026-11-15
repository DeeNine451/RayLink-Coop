-- Anomaly Coop test support: the stand-ins of the faction tests (test_faction_group.lua, test_faction_split.lua): a host and
-- two clients of harness_quests.lua with coop_tasks and coop_faction; the stock functions are their own text, copied with
-- file and lines. Globals: Hm, A, B (the machines of the last setup), SPLIT, STRINGS, FACTION_SCRIPTS, SETUP_HOOK. Not shipped.
dofile("tests/lua/support/harness_quests.lua")

function section(name) print("== " .. name) end

SPLIT = false
FACTION_SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_news", "coop_faction" }

STRINGS = {
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
function setup_world(M, nick)
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

function engine_check(M)
	for id, t in pairs(M.engine_tasks) do
		if t.state == "in" then
			if M.env.task_manager.task_complete(id) then
				t.state = "done"
				M.env.task_manager.task_callback(t, M.env.task.completed)
			end
		end
	end
end

Hm, A, B = nil, nil, nil
function setup(split, active)
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
		if SETUP_HOOK then SETUP_HOOK(M) end
		for _, n in ipairs(FACTION_SCRIPTS) do load_script(M, n) end
		for _, n in ipairs(FACTION_SCRIPTS) do M.env[n].on_game_start() end
		fire(M, "actor_on_first_update")
	end
	pump()
	return Hm, A, B
end

function comm(M) return M.actor._comm end
function has_tip(M, pat)
	for _, t in ipairs(M.tips) do if t:find(pat, 1, true) then return true end end
	return false
end
function tips_with(M, pat)
	local n = 0
	for _, t in ipairs(M.tips) do if t:find(pat, 1, true) then n = n + 1 end end
	return n
end

-- a finished cf task turned in by machine M (the task manager is the host's)
function client_turns_in(M, faction)
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
function new_dialog()
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

function fn_of(M, name)
	local f = M.env
	for part in name:gmatch("[^%.]+") do f = f[part] end
	return f
end

-- walks a dialog the way the engine does: the actor picks a phrase by its text, the NPC says the first child whose
-- preconditions hold. -> the texts said in order
function talk(M, phrases, picks)
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

function phrase_texts(phrases)
	local t = {}
	for _, ph in ipairs(phrases) do t[#t + 1] = ph.text end
	return table.concat(t, ",")
end

