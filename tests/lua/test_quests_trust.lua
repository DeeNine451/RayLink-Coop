-- TZ v2 section 6.4 rows 2, 3, 4 (owner 2026-11-18, "do the weak places of phase 2"): the host's checks of a client's quest
-- actions, through coop_trust ("log" in build 57: a failed check is written and the request still runs as before).
--   quest_take            "take": only an item a running task the player sees asks for, and not more than it still lacks
--   quest_spawn_once      a quest spawn of the white list ("fx"): once per world, kept in the host's save
--   quest_scene_place     oso_decline: the asking player stands before Osoznanie (or where the decline put him)
--   quest_delivery_place  delivery: the NPC the player hands over to is the target of a running delivery task
-- Run: tools\test_lua.cmd quests_trust
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party",
	"coop_quests_story", "coop_quests_scenes", "coop_quests_missions" }

local function exists(name)
	local fh = io.open(SCRIPTS_DIR_FOR_TEST .. name .. ".script", "r")
	if fh then fh:close() end
	return fh ~= nil
end
SCRIPTS_DIR_FOR_TEST = "gamedata/scripts/"

do -- the harness keeps its vector class local: what the decline's heading needs
	local mt = getmetatable(vec())
	mt.sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
	mt.getH = function(a) return math.atan2(-a.x, a.z) end
end

local PATROLS = {
	warlab_jump_sar2_walk = vec(200, 0, 0), warlab_jump_sar2_look = vec(200, 0, 10),
}

local function setup_world(M)
	local e = M.env
	-- the task ini with the line walk of a real ini (line_count / r_line_ex)
	local tini = e.task_manager.task_ini
	tini.line_count = function(_, id)
		local n = 0
		for _ in pairs(M.ini[id] or {}) do n = n + 1 end
		return n
	end
	tini.r_line_ex = function(_, id, i)
		local keys = {}
		for k in pairs(M.ini[id] or {}) do keys[#keys + 1] = k end
		table.sort(keys)
		local k = keys[i + 1]
		return true, k, k and M.ini[id][k]
	end
	e.xr_effects.remove_item = function(actor, npc, p)
		local left = tonumber(p[2]) or 1
		e.db.actor:iterate_inventory(function(_, it)
			if left > 0 and it._sec == p[1] then e.alife_release_id(it._id) left = left - 1 end
		end)
	end
	-- quest spawns of the white list (coop_quests_story HOST_EFFECTS)
	M.spawned = {}
	-- the real effect (xr_effects pos_itms, the same in the merged G.A.M.M.A. corpus and the stand): it makes these 10 sections
	-- and only prints an error for any other, returning normally
	local POS = { drx_x8_documents = true, drx_x16_documents = true, drx_x18_documents = true, drx_x19_documents = true,
		drx_agr_u_documents = true, drx_jup_u_documents = true, lx8_history_documents = true, lx8_history_2_documents = true,
		lx8_history_3_documents = true, wpn_gauss_quest = true }
	e.xr_effects.spawn_item_at_pos = function(actor, npc, p)
		if M.spawn_raise then
			M.spawn_raise = nil
			error("no place for it")
		end
		if POS[p[1]] then M.spawned[#M.spawned + 1] = p[1] end
	end
	e.xr_effects.spawn_x8_documents = function() M.spawned[#M.spawned + 1] = "x8_documents" end
	e.mlr_utils = { spawn_item = function(name) M.spawned[#M.spawned + 1] = name end }
	-- the rest of the white list that makes things (utils_slht, xr_effects, tasks_defense, the bridge tutorial, Crossfire)
	M.made_fx = {}
	local function made(name)
		return function()
			M.made_fx[name] = (M.made_fx[name] or 0) + 1
			if M.fx_raise == name then -- what it made stays: an error after it (Crossfire: add_task_companion after create_squad)
				M.fx_raise = nil
				error("an error after " .. name .. " was made")
			end
		end
	end
	e.xr_effects.ht_init_second_task_2 = made("ht_init_second_task_2")
	e.xr_effects.ht_add_mine = made("ht_add_mine")
	e.xr_effects.jup_b219_restore_gate = made("jup_b219_restore_gate")
	e.xr_effects.barrier_defense_first_spawn = made("barrier_defense_first_spawn")
	e.xr_effects.bridge_down = made("bridge_down")
	e.dialogs_lostzone = { spawn_pass_hall_isg_companion_squad = made("isg_companion_squad") }
	-- a dialog hands an item to an NPC (itms_manager.relocate_item_from_actor): the speaker's own items go
	e.itms_manager = {
		relocate_item_from_actor = function(actor, npc, sec, n)
			local left, to = tonumber(n) or 1, M.objects[npc:id()]
			for _, it in ipairs({ unpack(actor._inv) }) do
				if left > 0 and it._sec == sec then
					actor:transfer_item(it, to)
					left = left - 1
				end
			end
		end,
	}
	-- Osoznanie
	e.level.patrol_path_exists = function(n) return PATROLS[n] ~= nil end
	e.patrol = function(n) return { point = function() local p = PATROLS[n] return vec(p.x, p.y, p.z) end } end
	M.actor.set_actor_position = function(self, v) self._pos = vec(v.x, v.y, v.z) end
	M.actor.set_actor_direction = function() end
	e.get_story_object_id = function(sid) if sid == "osoznanie" then return 800 end end
	M.relayed = {}
	e.coop_npc_logic = {
		relay_to_all = function(name, args, except) M.relayed[#M.relayed + 1] = name .. "|" .. tostring(args) end,
		user_of = function() return nil end,
	}
	e.dialogs_warlab = { osoznanie_decline = function() M.declined = (M.declined or 0) + 1 end }
	-- delivery
	e.get_object_squad = function(npc) return npc._group and { id = npc._group } or nil end
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do
		if exists(n) then load_script(M, n) end
	end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m and m.on_game_start then m.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true })
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0, nick = "host" }, { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0, nick = "anna" }, { id = 0, is_self = false, avatar_id = 500, nick = "host" } }
boot(Hm)
boot(Cm)
check(Hm.env.coop_quests_trust ~= nil, "the quest checks module is there")

local function trust_lines(M, name)
	local n = 0
	for _, l in ipairs(M.log) do
		if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end
	end
	return n
end
local function last_trust(M, name)
	for i = #M.log, 1, -1 do
		if M.log[i]:find("[coop-trust] ! " .. name .. ":", 1, true) then return M.log[i] end
	end
	return ""
end
local function ask(name, t)
	Cm.env.coop_quests_core.request_host_action(name, t)
	pump()
end
local function counted(name)
	local tr = Hm.env.coop_trust
	local c = tr and tr.status()[name]
	return c and c.checked or 0
end

-------------------------------------------------------------------------------
print("== quest_take: a fetch task asks for 2 medkits")
do
	local tm = Hm.tm
	tm.task_info.fetch_t = { id = "fetch_t", stage = 0 }
	Hm.env.save_var(Hm.actor, "fetch_t_fetch", "medkit")
	Hm.env.save_var(Hm.actor, "fetch_t_fetch_count", 2)
	for _ = 1, 4 do Hm.give_item(Hm.actor, "medkit") end
	ask("take", { s = "medkit", n = 2 })
	check(Hm.count(Hm.actor, "medkit") == 2, "the take ran: 2 medkits left the group")
	check(counted("quest_take") == 1 and trust_lines(Hm, "quest_take") == 0, "2 of the 2 the task asks for: the check holds")
	ask("take", { s = "medkit", n = 1 })
	check(trust_lines(Hm, "quest_take") == 1, "a third medkit for a task that asked for 2: logged")
	check(last_trust(Hm, "quest_take"):find("anna", 1, true) and last_trust(Hm, "quest_take"):find("medkit", 1, true)
		and last_trust(Hm, "quest_take"):find("would be refused", 1, true), "the line names the player, the item and the mode")
	check(Hm.count(Hm.actor, "medkit") == 1, "log mode: the take still ran as before")
end

print("== quest_take: an item no task asks for")
do
	Hm.actor._inv = {} -- (the harness's alife_release_id compares items with ==: the item taken is the first one)
	Hm.give_item(Hm.actor, "wpn_gauss")
	ask("take", { s = "wpn_gauss", n = 1 })
	check(trust_lines(Hm, "quest_take") == 2 and last_trust(Hm, "quest_take"):find("wpn_gauss", 1, true),
		"a rifle no running task asks for: logged")
	check(Hm.count(Hm.actor, "wpn_gauss") == 0, "log mode: taken as before")
end

print("== quest_take: the task's own lines name the item (stock on_complete = remove_item)")
do
	Hm.ini.doc_t = { on_complete = "%=remove_item(quest_doc2:2) =reward_money(10)%", title = "doc_t_title" }
	Hm.tm.task_info.doc_t = { id = "doc_t", stage = 0 }
	for _ = 1, 3 do Hm.give_item(Hm.actor, "quest_doc2") end
	local before = trust_lines(Hm, "quest_take")
	ask("take", { s = "quest_doc2", n = 2 })
	check(trust_lines(Hm, "quest_take") == before, "2 documents a task's on_complete removes: the check holds")
	ask("take", { s = "quest_doc", n = 1 })
	check(trust_lines(Hm, "quest_take") == before + 1, "quest_doc is not quest_doc2 (whole names only): logged")
end

print("== quest_take: the dialog's info ended the task a moment before the take arrived")
do
	Hm.ini.notes_t = { condlist_0 = "{=actor_has_item(strelok_notes)} complete" }
	Hm.tm.task_info.notes_t = { id = "notes_t", stage = 0 }
	tick(Hm) -- the host's update sees the task running
	Hm.tm.task_info.notes_t = nil -- stalker_strelok_doctor: the info of the phrase ended it on the host first
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "strelok_notes")
	local before = trust_lines(Hm, "quest_take")
	ask("take", { s = "strelok_notes", n = 1 })
	check(trust_lines(Hm, "quest_take") == before, "a task that ended a moment ago still asks for its item")
	NOW = NOW + 11000
	tick(Hm)
	Hm.give_item(Hm.actor, "strelok_notes")
	ask("take", { s = "strelok_notes", n = 1 })
	check(trust_lines(Hm, "quest_take") == before + 1, "10 s later it does not")
end

print("== quest_take: a delivery task's parcel")
do
	Hm.tm.task_info.parcel_t = { id = "parcel_t", stage = 1, status_functor = "delivery_task" }
	Hm.env.save_var(Hm.actor, "parcel_t", { item_1_sec = "parcel_case", item_1_id = 9001, target_id = 730 })
	Hm.give_item(Hm.actor, "parcel_case")
	local before = trust_lines(Hm, "quest_take")
	ask("take", { s = "parcel_case", n = 1 })
	check(trust_lines(Hm, "quest_take") == before, "the parcel of a running delivery: the check holds")
end

print("== quest_take: a task the player may not see")
do
	Hm.tm.task_info.secret_t = { id = "secret_t", stage = 0 }
	Hm.env.save_var(Hm.actor, "secret_t_fetch", "secret_doc")
	local dedicated = Hm.env.coop.is_dedicated
	Hm.env.coop.is_dedicated = function() return true end
	Hm.env.coop_srv_task_audience = {
		sees_character = function(id, c) if id == "secret_t" then return c == 999 end return true end,
	}
	Hm.give_item(Hm.actor, "secret_doc")
	local before = trust_lines(Hm, "quest_take")
	ask("take", { s = "secret_doc", n = 1 })
	check(trust_lines(Hm, "quest_take") == before + 1, "a task out of his audience asks for it: logged")
	Hm.env.coop.is_dedicated = dedicated
	Hm.env.coop_srv_task_audience = nil
end

print("== quest_take: refuse mode stops the take")
do
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse" })
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "wpn_gauss")
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 1, "refuse: the rifle stays with the group")
	Hm.env.coop_trust.reset_for_test(nil)
end

-------------------------------------------------------------------------------
print("== quest_spawn_once")
do
	Cm.env.xr_effects.spawn_item_at_pos(Cm.actor, nil, { "lx8_history_documents" })
	pump()
	check(#Hm.spawned == 1 and Hm.spawned[1] == "lx8_history_documents", "the first ask makes the documents")
	check(counted("quest_spawn_once") == 1 and trust_lines(Hm, "quest_spawn_once") == 0, "the first ask: the check holds")
	Cm.env.xr_effects.spawn_item_at_pos(Cm.actor, nil, { "lx8_history_2_documents" })
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 0, "another section of the same effect is another item")
	Cm.env.xr_effects.spawn_item_at_pos(Cm.actor, nil, { "lx8_history_documents" })
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 1 and last_trust(Hm, "quest_spawn_once"):find("lx8_history_documents", 1, true),
		"the same documents asked again: logged")
	check(#Hm.spawned == 3, "log mode: made again as before")
	Cm.env.xr_effects.spawn_x8_documents(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 1, "an effect without a section: its first run holds")
	-- mlr_utils.spawn_item names a set of its SPWN table, no section
	local before = trust_lines(Hm, "quest_spawn_once")
	Cm.env.mlr_utils.spawn_item("spawn_1_11_af_medusa_kmb")
	pump()
	Cm.env.mlr_utils.spawn_item("spawn_1_11_af_medusa_kmb")
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == before + 1, "the same mlr spawn twice: the second is logged")
	-- the host saves and loads: the list comes back
	local m = {}
	fire(Hm, "save_state", m)
	check(type(m.coop_quest_spawns) == "table", "the list is in the host's save (m_data.coop_quest_spawns)")
	load_script(Hm, "coop_quests_trust").on_game_start()
	fire(Hm, "load_state", m)
	Cm.env.xr_effects.spawn_x8_documents(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 3, "after the host's load: the x8 documents asked again are logged")
	local fresh = {}
	fire(Hm, "load_state", fresh)
	Cm.env.xr_effects.spawn_x8_documents(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 3, "a save without the list (an old save): nothing was made yet")
end

-------------------------------------------------------------------------------
print("== quest_scene_place: oso_decline")
do
	Hm.new_obj(800, "osoznanie", vec(50, 0, 0), { _stalker = true })
	proxy._pos = vec(52, 0, 0)
	ask("oso_decline", {})
	check(counted("quest_scene_place") == 1 and trust_lines(Hm, "quest_scene_place") == 0, "before Osoznanie: the check holds")
	check(#Hm.relayed == 1, "the others are told to follow")
	proxy._pos = vec(201, 0, 0)
	ask("oso_decline", {})
	check(trust_lines(Hm, "quest_scene_place") == 0, "where the decline put him (his own dialog moved him first): the check holds")
	proxy._pos = vec(400, 0, 0)
	ask("oso_decline", {})
	check(trust_lines(Hm, "quest_scene_place") == 1 and last_trust(Hm, "quest_scene_place"):find("anna", 1, true),
		"far from Osoznanie and from the jump point: logged")
	check(#Hm.relayed == 3, "log mode: the scene still runs")
	-- before Osoznanie, but he talked to nobody (an engine with the talk locks)
	proxy._pos = vec(52, 0, 0)
	Hm.env.coop.talk_recent = function() return false end
	ask("oso_decline", {})
	check(trust_lines(Hm, "quest_scene_place") == 2, "before Osoznanie without a talk: logged")
	Hm.env.coop.talk_recent = nil
	-- no Osoznanie and no jump point here (the world server of a Server has no level): no knowledge, no refusal
	Hm.objects[800] = nil
	proxy._pos = vec(400, 0, 0)
	local was = counted("quest_scene_place")
	local ok = Hm.env.coop_quests_trust.oso_verdict(1, "no_such_path")
	check(ok == true, "neither Osoznanie nor the point known here: the verdict is ok")
	check(counted("quest_scene_place") == was, "(the verdict alone counts nothing)")
end

-------------------------------------------------------------------------------
print("== quest_delivery_place")
do
	proxy._pos = vec(4, 0, 0)
	Hm.new_obj(730, "sim_stalker_target", vec(6, 0, 0), { _stalker = true, _group = 731 })
	Hm.new_obj(740, "sim_stalker_other", vec(7, 0, 0), { _stalker = true, _group = 741 })
	Hm.env.sim_offline_combat.task_squads[731] = true
	Hm.env.sim_offline_combat.task_squads[741] = true
	ask("delivery", { n = 730 })
	check(Hm.env.sim_offline_combat.task_squads[731] == nil, "the target's squad is let go")
	check(counted("quest_delivery_place") == 1 and trust_lines(Hm, "quest_delivery_place") == 0,
		"the target of a running delivery: the check holds")
	ask("delivery", { n = 740 })
	check(trust_lines(Hm, "quest_delivery_place") == 1 and last_trust(Hm, "quest_delivery_place"):find("740", 1, true),
		"an NPC no delivery is for: logged")
	check(Hm.env.sim_offline_combat.task_squads[741] == nil, "log mode: as before")
end

-------------------------------------------------------------------------------
-- Round 2 (the blind review of round 1): B1 give_npc, F1 dialog takes, F6 spawn keys, B2 the rest of the white list,
-- F8 a task that ended between two looks.
-------------------------------------------------------------------------------
local npc_h = Hm.new_obj(750, "sim_stalker_barman", vec(6, 0, 0), { _stalker = true })
local npc_c = Cm.new_obj(750, "sim_stalker_barman", vec(2, 0, 0), { _stalker = true })
local function give_npc(sec, c) ask("give_npc", { s = sec, n = 750, c = c or 1 }) end
-- each section counts its own lines and checks
local function fresh()
	Hm.env.coop_trust.reset_for_test(nil)
	Hm.log = {}
end

print("== quest_give_npc: a dialog hands the group's item to an NPC (B1)")
do
	fresh()
	proxy._pos = vec(4, 0, 0)
	Hm.actor._inv = {}
	Hm.tm.task_info.give_t = { id = "give_t", stage = 0 }
	Hm.env.save_var(Hm.actor, "give_t_fetch", "bread")
	Hm.env.save_var(Hm.actor, "give_t_fetch_count", 1)
	Hm.give_item(Hm.actor, "bread")
	-- the honest path: the client's dialog relocates an item its speaker lacks (patch_client_relocate -> give_to_npc)
	Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, npc_c, "bread", 1)
	pump()
	check(Hm.count(npc_h, "bread") == 1, "the NPC got the group's bread")
	check(counted("quest_give_npc") == 1 and trust_lines(Hm, "quest_give_npc") == 0,
		"the bread a running fetch task asks for: quest_give_npc holds")
	Hm.give_item(Hm.actor, "bread")
	local takes = trust_lines(Hm, "quest_take")
	ask("take", { s = "bread", n = 1 })
	check(trust_lines(Hm, "quest_take") == takes + 1, "the give is noted: a take of the same bread for that task is logged")
	Hm.give_item(Hm.actor, "bread")
	give_npc("bread")
	check(trust_lines(Hm, "quest_give_npc") == 1, "a second bread for a task that asked for one: logged")
	Hm.give_item(Hm.actor, "wpn_gauss")
	give_npc("wpn_gauss")
	local line = last_trust(Hm, "quest_give_npc")
	check(trust_lines(Hm, "quest_give_npc") == 2 and line:find("anna", 1, true) and line:find("wpn_gauss", 1, true)
		and line:find("would be refused", 1, true), "a rifle no task asks for: logged, the line names the player, the item, the mode")
	check(Hm.count(npc_h, "wpn_gauss") == 1, "log mode: handed over as before")
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_give_npc = "refuse" })
	Hm.give_item(Hm.actor, "wpn_gauss")
	give_npc("wpn_gauss")
	check(Hm.count(Hm.actor, "wpn_gauss") == 1 and Hm.count(npc_h, "wpn_gauss") == 1, "refuse: the rifle stays with the group")
	Hm.env.coop_trust.reset_for_test(nil)
	Hm.tm.task_info.give_t = nil
end

print("== quest_give_npc, Server: the NPC is a stand-in of the far view (the world server has no level of the player)")
do
	fresh()
	local far = Hm.new_obj(760, "sim_stalker_far", vec(8, 0, 0), { _stalker = true, far = true })
	Hm.actor._inv = {}
	Hm.tm.task_info.far_t = { id = "far_t", stage = 0 }
	Hm.env.save_var(Hm.actor, "far_t_fetch", "salt")
	Hm.env.save_var(Hm.actor, "far_t_fetch_count", 1)
	Hm.give_item(Hm.actor, "salt")
	ask("give_npc", { s = "salt", n = 760, c = 1 })
	check(Hm.count(far, "salt") == 1 and Hm.count(Hm.actor, "salt") == 0, "made in his record from the group's salt")
	check(counted("quest_give_npc") == 1 and trust_lines(Hm, "quest_give_npc") == 0, "the salt a running task asks for: holds")
	Hm.give_item(Hm.actor, "wpn_gauss")
	ask("give_npc", { s = "wpn_gauss", n = 760, c = 1 })
	check(trust_lines(Hm, "quest_give_npc") == 1, "a rifle no task asks for: logged as in Co-op")
	Hm.tm.task_info.far_t = nil
end

print("== quest_give_npc: the Agroprom documents to the bandit boss (a dialog no task names)")
do
	fresh()
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "main_story_1_quest_case")
	give_npc("main_story_1_quest_case")
	check(trust_lines(Hm, "quest_give_npc") == 1, "before the boss asked for them (agr_u_bandit_boss_ask): logged")
	Hm.infos.agr_u_bandit_boss_ask = true
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "main_story_1_quest_case")
	fresh()
	give_npc("main_story_1_quest_case")
	check(trust_lines(Hm, "quest_give_npc") == 0 and counted("quest_give_npc") == 1, "his dialog is open: the first case holds")
end

print("== quest_take: a stock dialog's take is counted per player (F1)")
do
	fresh()
	Hm.actor._inv = {}
	for _ = 1, 3 do Hm.give_item(Hm.actor, "drug_psy_blockade") end
	Hm.infos.stalker_rogue_dialog_oa_help_psycho = true
	ask("take", { s = "drug_psy_blockade", n = 1 })
	check(counted("quest_take") == 1 and trust_lines(Hm, "quest_take") == 0, "the rogue's psy block: the first one holds")
	ask("take", { s = "drug_psy_blockade", n = 1 })
	check(trust_lines(Hm, "quest_take") == 1 and last_trust(Hm, "quest_take"):find("drug_psy_blockade", 1, true),
		"a second psy block for the same dialog: logged (the group's pills cannot be drained)")
	ask("take", { s = "drug_psy_blockade", n = 2 })
	check(trust_lines(Hm, "quest_take") == 2, "two at once: logged")
	Hm.give_item(Hm.actor, "decryption_radio")
	ask("take", { s = "decryption_radio", n = 1 })
	check(trust_lines(Hm, "quest_take") == 3, "the radio before its dialog is open (degtyarev_rally_point_pda): logged")
	-- the count is in the host's save
	local m = {}
	fire(Hm, "save_state", m)
	load_script(Hm, "coop_quests_trust").on_game_start()
	fire(Hm, "load_state", m)
	Hm.give_item(Hm.actor, "drug_psy_blockade")
	ask("take", { s = "drug_psy_blockade", n = 1 })
	check(trust_lines(Hm, "quest_take") == 4, "after the host's load: the pill he took is still counted")
end

print("== quest_spawn_once: the parameter of a counted effect (F6)")
do
	fresh()
	ask("fx", { f = "spawn_item_at_pos" })
	check(trust_lines(Hm, "quest_spawn_once") == 1 and last_trust(Hm, "quest_spawn_once"):find("spawn_item_at_pos", 1, true),
		"spawn_item_at_pos without a section: logged")
	ask("fx", { f = "spawn_item_at_pos", p1 = string.rep("a", 65) })
	check(trust_lines(Hm, "quest_spawn_once") == 2, "a section of 65 characters: logged")
	ask("fx", { f = "mlr_spawn_item", p1 = 4242 })
	ask("fx", { f = "mlr_spawn_item", p1 = 4242 })
	check(trust_lines(Hm, "quest_spawn_once") == 3, "a number for the mlr set's name is a name too: its second ask is logged")
	Hm.spawn_raise = true
	ask("fx", { f = "spawn_item_at_pos", p1 = "lx8_history_3_documents" })
	check(Hm.spawn_raise == nil and Hm.spawned[#Hm.spawned] ~= "lx8_history_3_documents", "(the effect raised: nothing was made)")
	ask("fx", { f = "spawn_item_at_pos", p1 = "lx8_history_3_documents" })
	check(trust_lines(Hm, "quest_spawn_once") == 3 and Hm.spawned[#Hm.spawned] == "lx8_history_3_documents",
		"the effect raised the first time: the honest retry holds and makes it")
	ask("fx", { f = "spawn_item_at_pos", p1 = "lx8_history_3_documents" })
	check(trust_lines(Hm, "quest_spawn_once") == 4, "made once: a third ask is logged")
end

print("== the rest of the white list (B2)")
do
	fresh()
	local fx = Cm.env.xr_effects
	fx.ht_init_second_task_2(Cm.actor, nil, {})
	pump()
	fx.ht_init_second_task_2(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_spawn_once") == 1 and last_trust(Hm, "quest_spawn_once"):find("ht_init_second_task_2", 1, true),
		"Hidden Threat's package and courier asked twice: logged under quest_spawn_once")
	fx.ht_add_mine(Cm.actor, nil, {})
	pump()
	check(counted("quest_effect_once") == 1 and trust_lines(Hm, "quest_effect_once") == 0, "the ambush mine: the first ask holds")
	fx.ht_add_mine(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 1 and last_trust(Hm, "quest_effect_once"):find("ht_add_mine", 1, true),
		"a second ambush mine: logged under quest_effect_once")
	fx.jup_b219_restore_gate(Cm.actor, nil, {})
	pump()
	fx.jup_b219_restore_gate(Cm.actor, nil, {})
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 2, "a second Jupiter gate: logged")
	-- the barrier's attackers: once per run of its task
	fx.barrier_defense_first_spawn(Cm.actor, nil, { "monolith" })
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 3 and last_trust(Hm, "quest_effect_once"):find("barrier_defense_monolith", 1, true),
		"the barrier's attackers while its task does not run: logged")
	Hm.tm.task_info.barrier_defense_monolith = { id = "barrier_defense_monolith", stage = 0 }
	fx.barrier_defense_first_spawn(Cm.actor, nil, { "monolith" })
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 3, "the task runs: its first wave holds")
	fx.barrier_defense_first_spawn(Cm.actor, nil, { "monolith" })
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 4, "a second first wave for the same run: logged")
	Hm.tm.task_info.barrier_defense_monolith = { id = "barrier_defense_monolith", stage = 0 } -- given again later
	fx.barrier_defense_first_spawn(Cm.actor, nil, { "monolith" })
	pump()
	check(trust_lines(Hm, "quest_effect_once") == 4, "the task given again: its first wave holds again")
	Hm.tm.task_info.barrier_defense_monolith = nil
	-- the bridge of the Red Forest tutorial moves as often as the player uses the lever
	local before = counted("quest_effect_once")
	for _ = 1, 3 do
		fx.bridge_down(Cm.actor, nil, {})
		pump()
	end
	check(Hm.made_fx.bridge_down == 3 and counted("quest_effect_once") == before, "the bridge: every use runs, nothing is counted")
	-- Crossfire's companions: never twice, in "log" too (the old guard), and the host's save keeps it
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	-- round 3 (R2-S4): the hard guard refuses the second ask before the check, so no line says it was let through
	local let = 0
	for _, l in ipairs(Hm.log) do
		if l:find("isg_companion_squad", 1, true) and l:find("let through", 1, true) then let = let + 1 end
	end
	check(Hm.made_fx.isg_companion_squad == 1 and trust_lines(Hm, "quest_effect_once") == 4 and let == 0,
		"the companion squad asked twice: made once, the second refused by the hard guard with no 'let through' line (" .. let .. ")")
	local said = false
	for _, l in ipairs(Hm.log) do
		if l:find("isg_companion_squad", 1, true) and l:find("refused", 1, true) and l:find("anna", 1, true) then said = true end
	end
	check(said, "the host's log says the repeat was refused and by whom")
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_quest_spawns or {}) do listed[k] = true end
	check(listed.isg_companion_squad and listed.ht_add_mine and listed.ht_init_second_task_2,
		"the host's save lists the squad, the mine and the package")
end

print("== the window of a task that just ended (F8)")
do
	fresh()
	Hm.actor._inv = {}
	-- given and ended between two looks, and no actor update at all (a world server's console process)
	Hm.ini.radio_t = { condlist_0 = "{=actor_has_item(radio_part)} complete" }
	Hm.tm.task_info.radio_t = { id = "radio_t", stage = 0 }
	-- the engine ends it: task_manager.task_callback (the stock drops a task without a repeat timeout from task_info)
	Hm.env.task_manager.task_callback({ get_id = function() return "radio_t" end }, Hm.env.task.completed)
	check(Hm.tm.task_info.radio_t == nil, "(the stock callback ran: the task is gone from task_info)")
	Hm.give_item(Hm.actor, "radio_part")
	ask("take", { s = "radio_part", n = 1 })
	check(trust_lines(Hm, "quest_take") == 0, "the host's task callback noted the end: the take a moment later holds")
	NOW = NOW + 11000
	Hm.give_item(Hm.actor, "radio_part")
	ask("take", { s = "radio_part", n = 1 })
	check(trust_lines(Hm, "quest_take") == 1, "10 s later it does not")
	-- a repeatable task waits for its repeat timeout in task_info (stage 255): it is no running task
	Hm.ini.rep_t = { on_complete = "%=remove_item(rep_doc)%" }
	Hm.tm.task_info.rep_t = { id = "rep_t", stage = 255, status = "completed" }
	Hm.give_item(Hm.actor, "rep_doc")
	local before = trust_lines(Hm, "quest_take")
	ask("take", { s = "rep_doc", n = 1 })
	check(trust_lines(Hm, "quest_take") == before + 1, "a task that ended long ago and waits for its repeat: logged")
	local rep = { id = "rep_t", stage = 1, status = "selected" }
	Hm.tm.task_info.rep_t = rep
	Hm.env.task_manager.task_callback({ get_id = function() return "rep_t" end }, Hm.env.task.fail)
	-- the stock keeps a task with a repeat timeout: stage 255, status "fail" (the harness's stub drops it)
	rep.stage, rep.status = 255, "fail"
	Hm.tm.task_info.rep_t = rep
	Hm.give_item(Hm.actor, "rep_doc")
	before = trust_lines(Hm, "quest_take")
	ask("take", { s = "rep_doc", n = 1 })
	check(trust_lines(Hm, "quest_take") == before, "the same task a moment after it ended: the window holds")
end

-------------------------------------------------------------------------------
-- Round 3 (the blind review of round 2): R2-B1 the free keys of quest_spawn_once, R2-S4 is in the white-list section above,
-- the honest dialog relocation of uses.
-------------------------------------------------------------------------------
print("== quest_spawn_once: asks for sections spawn_item_at_pos cannot make fill nothing (R2-B1, the review's probe)")
do
	fresh()
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse" })
	local n0 = #Hm.spawned
	for i = 1, 200 do ask("fx", { f = "spawn_item_at_pos", p1 = "junk_section_" .. i }) end
	check(#Hm.spawned == n0 and counted("quest_spawn_once") == 0 and trust_lines(Hm, "quest_spawn_once") == 0,
		"200 asks for sections it does not make: nothing made, nothing counted (" .. counted("quest_spawn_once") .. ")")
	local m = {}
	fire(Hm, "save_state", m)
	check(m.coop_quest_spawns == nil, "nothing of them is kept: the host's save lists none")
	for _ = 1, 5 do ask("fx", { f = "spawn_item_at_pos", p1 = "wpn_gauss_quest" }) end
	local made = 0
	for i = n0 + 1, #Hm.spawned do if Hm.spawned[i] == "wpn_gauss_quest" then made = made + 1 end end
	check(made == 1 and trust_lines(Hm, "quest_spawn_once") == 4,
		"refuse: the Gauss rifle made once after them, the 4 repeats refused (made " .. made .. ")")
end

print("== quest_spawn_once: a full list of keys from a client's parameter refuses a new one (R2-B1)")
do
	fresh()
	local list = {}
	for i = 1, 192 do list[#list + 1] = "mlr_spawn_item:filler_" .. i end
	fire(Hm, "load_state", { coop_quest_spawns = list })
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse" })
	local n0 = #Hm.spawned
	ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x16_documents" })
	check(#Hm.spawned == n0 and trust_lines(Hm, "quest_spawn_once") == 1
		and last_trust(Hm, "quest_spawn_once"):find("full", 1, true) ~= nil,
		"192 such keys kept: a new one is refused, not let through, and the line says the list is full")
	ask("fx", { f = "mlr_spawn_item", p1 = "spawn_povars_berill" })
	check(#Hm.spawned == n0 and trust_lines(Hm, "quest_spawn_once") == 2, "an mlr set's name as well")
	ask("fx", { f = "spawn_x8_documents" })
	check(#Hm.spawned == n0 + 1 and trust_lines(Hm, "quest_spawn_once") == 2, "a fixed key has its own room: made")
	Hm.env.coop_trust.reset_for_test({ default = "log" })
	ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x16_documents" })
	ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x16_documents" })
	check(#Hm.spawned == n0 + 3 and trust_lines(Hm, "quest_spawn_once") == 4,
		"log mode: made as before, every ask logged (a key that cannot be kept is no ok)")
end

print("== the whole list full: a new fixed key and a new dialog take are refused, not let through (R2-B1)")
do
	fresh()
	local list = {}
	for i = 1, 1024 do list[#list + 1] = "dialog_take|filler|c9|" .. i end
	fire(Hm, "load_state", { coop_quest_spawns = list })
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse", quest_effect_once = "refuse",
		quest_take = "refuse" })
	local n0 = #Hm.spawned
	ask("fx", { f = "spawn_x8_documents" })
	check(#Hm.spawned == n0 and last_trust(Hm, "quest_spawn_once"):find("full", 1, true) ~= nil,
		"the x8 documents: refused, the list is full")
	local mines0 = Hm.made_fx.ht_add_mine or 0
	ask("fx", { f = "ht_add_mine" })
	check((Hm.made_fx.ht_add_mine or 0) == mines0 and last_trust(Hm, "quest_effect_once"):find("full", 1, true) ~= nil,
		"the ambush mine: refused, the list is full")
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "drug_psy_blockade")
	ask("take", { s = "drug_psy_blockade", n = 1 })
	check(Hm.count(Hm.actor, "drug_psy_blockade") == 1 and last_trust(Hm, "quest_take"):find("full", 1, true) ~= nil,
		"a stock dialog's take: refused, the list is full (its count could not be kept)")
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test(nil)
end

print("== quest_give_npc: a dialog relocating uses its speaker holds asks the group for nothing (the honest flow at risk)")
do
	fresh()
	-- dialogs_mlr: the precondition mlr_utils.have_item(sec, 5) counts uses (utils_item.get_amount mode 1), and so does
	-- itms_manager.relocate_item_from_actor; 3 bottles of 2 uses cover 5
	Cm.env.IsItem = function(kind, sec) if kind == "multiuse" and sec == "vodka2" then return 2 end end
	Cm.actor._inv = {}
	for _ = 1, 3 do Cm.give_item(Cm.actor, "vodka2", { _uses = 2 }) end
	Hm.actor._inv = {}
	for _ = 1, 2 do Hm.give_item(Hm.actor, "vodka2") end
	Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, npc_c, "vodka2", 5)
	pump()
	check(counted("quest_give_npc") == 0 and trust_lines(Hm, "quest_give_npc") == 0,
		"his own uses cover the 5: no give_npc asked, no line (" .. counted("quest_give_npc") .. ")")
	check(Hm.count(Hm.actor, "vodka2") == 2, "the group keeps its bottles")
	-- he lacks some: the rest still comes from the group (a task asks for it)
	Hm.tm.task_info.vodka_t = { id = "vodka_t", stage = 0 }
	Hm.env.save_var(Hm.actor, "vodka_t_fetch", "vodka2")
	Hm.env.save_var(Hm.actor, "vodka_t_fetch_count", 2)
	Cm.actor._inv = {}
	Cm.give_item(Cm.actor, "vodka2", { _uses = 2 })
	Cm.env.itms_manager.relocate_item_from_actor(Cm.actor, npc_c, "vodka2", 4)
	pump()
	check(counted("quest_give_npc") == 1 and trust_lines(Hm, "quest_give_npc") == 0 and Hm.count(Hm.actor, "vodka2") == 0,
		"2 uses short: the group gives 2, the task asks for them (no line)")
	Hm.tm.task_info.vodka_t = nil
	Cm.env.IsItem = function() return nil end
end

-------------------------------------------------------------------------------
-- Round 4 (blocker 3 of the round 3 review): coop_tvd lets a client write host pstor keys of the shared prefixes (drx_sl_, ...).
-- need_of and delivery_verdict read a fact only where its value is one the host itself wrote: its own logic (the offers it
-- makes, on_init, status functors) or a give it ran with the taker's vars; a client's coop_tvd write never makes one. A client's
-- write of a fetch / target key of a running task he did not take is its own check, task_var_write.
-------------------------------------------------------------------------------
local function var_from_client(k, v)
	Cm.env.save_var(Cm.actor, k, v) -- the client's own save_var: coop_tasks routes a shared key to the host (coop_tvd)
	pump()
end
local function hps() return Hm.env.db.storage[0].pstor end

print("== B3: a running DRX task's fetch written by a client does not make it ask for rifles (the review's probe)")
do
	fresh()
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse" })
	Hm.tm.task_info.drx_sl_probe_task = { id = "drx_sl_probe_task", stage = 0 } -- any running DRX task he sees
	Hm.actor._inv = {}
	for _ = 1, 5 do Hm.give_item(Hm.actor, "wpn_gauss") end
	ask("take", { s = "wpn_gauss", n = 5 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 5, "before the write: refused")
	var_from_client("drx_sl_probe_task_fetch", "wpn_gauss")
	var_from_client("drx_sl_probe_task_fetch_count", 1000)
	check(hps().drx_sl_probe_task_fetch == "wpn_gauss" and hps().drx_sl_probe_task_fetch_count == 1000,
		"(the write reached the host's pstor: task_var_write is on log, and nobody is known to have taken this task)")
	ask("take", { s = "wpn_gauss", n = 5 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 5, "refuse: a fetch a client wrote makes no task ask for the rifles (5 left)")
	Hm.tm.task_info.drx_sl_probe_task = nil
end

print("== B3: task_var_write, a client's write of a fetch key of a running task another player took")
do
	fresh()
	Hm.ini.drx_sl_host_t = {}
	Cm.ini.drx_sl_host_t = {}
	Hm.talking = true -- the host's own dialog gives it: his task
	Hm.tm:give_task("drx_sl_host_t", 750)
	Hm.talking = false
	Hm.env.save_var(Hm.actor, "drx_sl_host_t_fetch", "bread") -- what the host's own offer made
	Hm.env.save_var(Hm.actor, "drx_sl_host_t_fetch_count", 1)
	var_from_client("drx_sl_host_t_fetch", "wpn_gauss")
	local line = last_trust(Hm, "task_var_write")
	check(trust_lines(Hm, "task_var_write") == 1 and line:find("anna", 1, true) and line:find("drx_sl_host_t_fetch", 1, true)
		and line:find("would be refused", 1, true), "logged under task_var_write, names the player and the key: " .. line)
	check(hps().drx_sl_host_t_fetch == "wpn_gauss", "log mode: written as before")
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse" })
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "wpn_gauss")
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 1, "quest_take refuse: the rifle it wrote is no fact of the task")
	Hm.env.save_var(Hm.actor, "drx_sl_host_t_fetch", "bread")
	Hm.env.coop_trust.reset_for_test({ default = "log", task_var_write = "refuse" })
	var_from_client("drx_sl_host_t_fetch", "wpn_gauss")
	var_from_client("drx_sl_host_t_fetch_count", 50)
	check(hps().drx_sl_host_t_fetch == "bread" and hps().drx_sl_host_t_fetch_count == 1,
		"task_var_write refuse: the host's pstor keeps its own values")
	-- not a fact key, a key of no running task, a counter of the givers: no check
	local before = counted("task_var_write")
	var_from_client("drx_sl_host_t_note", 1)
	var_from_client("drx_sl_other_task_fetch", "salt")
	var_from_client("drx_sl_task_giver_750", 2)
	check(counted("task_var_write") == before and hps().drx_sl_other_task_fetch == "salt" and hps().drx_sl_host_t_note == 1,
		"another key of the task, a task that does not run, a giver counter: not judged, written")
	Hm.env.coop_trust.reset_for_test(nil)
	Hm.tm.task_info.drx_sl_host_t = nil
end

print("== B3: the honest writers keep their facts (a client's give with its vars, DRX local offers)")
do
	fresh()
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse", task_var_write = "refuse" })
	-- a client's give carries the vars his dialog prepared (the host's offer, or the stock local generation): the host's give writes them
	for _, id in ipairs({ "fetch_c", "drx_sl_local_t", "drx_sl_nofetch_t" }) do
		Hm.ini[id] = {}
		Cm.ini[id] = {}
	end
	Cm.env.save_var(Cm.actor, "fetch_c_fetch", "medkit")
	Cm.env.save_var(Cm.actor, "fetch_c_fetch_count", 2)
	pump()
	check(hps().fetch_c_fetch == nil, "(a key of no shared prefix stays on the client until the give)")
	Cm.tm:give_task("fetch_c", 750)
	pump()
	check(Hm.tm.task_info.fetch_c ~= nil and hps().fetch_c_fetch == "medkit", "the give ran on the host with his vars")
	Hm.actor._inv = {}
	for _ = 1, 2 do Hm.give_item(Hm.actor, "medkit") end
	ask("take", { s = "medkit", n = 2 })
	check(Hm.count(Hm.actor, "medkit") == 0 and trust_lines(Hm, "quest_take") == 0, "refuse: the medkits his give asks for are taken")
	-- DRX's local offer: the client's dialog writes the shared fetch through coop_tvd before the give, the give carries it again
	var_from_client("drx_sl_local_t_fetch", "vodka")
	var_from_client("drx_sl_local_t_fetch_count", 1)
	check(counted("task_var_write") == 0, "the offer's write of a task not running yet: not judged")
	Cm.tm:give_task("drx_sl_local_t", 750)
	pump()
	Hm.give_item(Hm.actor, "vodka")
	ask("take", { s = "vodka", n = 1 })
	check(Hm.count(Hm.actor, "vodka") == 0 and trust_lines(Hm, "quest_take") == 0, "refuse: the vodka of a DRX offer he took is taken")
	-- a fetch written only by a client's coop_tvd, then the task given by the host's own dialog with no fetch of its own
	var_from_client("drx_sl_nofetch_t_fetch", "wpn_gauss")
	var_from_client("drx_sl_nofetch_t_fetch_count", 10)
	Hm.talking = true
	Hm.tm:give_task("drx_sl_nofetch_t", 750)
	Hm.talking = false
	Hm.give_item(Hm.actor, "wpn_gauss")
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 1 and trust_lines(Hm, "quest_take") == 1,
		"refuse: a fetch that only a client's coop_tvd wrote is no fact of the host's task")
	-- the host's save keeps which values are its own: after a load the client's value is still none of its facts
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_task_facts or {}) do listed[k] = true end
	check(listed.fetch_c_fetch and listed.drx_sl_local_t_fetch and not listed.drx_sl_nofetch_t_fetch,
		"the host's save lists its own facts (m_data.coop_task_facts), not the client's")
	load_script(Hm, "coop_quests_trust").on_game_start()
	fire(Hm, "load_state", m)
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse" })
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 1, "after the host's load: the client's fetch is still no fact")
	Hm.actor._inv = {} -- (the harness's alife_release_id compares items with ==: the item taken is the first one)
	Hm.give_item(Hm.actor, "vodka")
	ask("take", { s = "vodka", n = 1 })
	check(Hm.count(Hm.actor, "vodka") == 0 and trust_lines(Hm, "quest_take") == 2,
		"after the load: the host's own fact holds, the vodka it asks for is taken (the ledger of a loaded task starts anew)")
	Hm.give_item(Hm.actor, "wpn_gauss")
	-- a save from before this build keeps no list: no knowledge, every value of its pstor counts
	fire(Hm, "load_state", {})
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 0, "an old save without the list: its values count (no refusal for lack of knowledge)")
	Hm.env.coop_trust.reset_for_test(nil)
	for _, id in ipairs({ "fetch_c", "drx_sl_local_t", "drx_sl_nofetch_t" }) do Hm.tm.task_info[id] = nil end
end

print("== B3: a delivery's target written by a client is no target")
do
	fresh()
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_delivery_place = "refuse" })
	Hm.tm.task_info.drx_sl_dlv_t = { id = "drx_sl_dlv_t", stage = 1, status_functor = "delivery_task" }
	Hm.env.save_var(Hm.actor, "drx_sl_dlv_t", { item_1_sec = "parcel_x", target_id = 760 })
	var_from_client("drx_sl_dlv_t", { item_1_sec = "parcel_x", target_id = 740 })
	proxy._pos = vec(4, 0, 0)
	Hm.env.sim_offline_combat.task_squads[741] = true
	ask("delivery", { n = 740 })
	check(Hm.env.sim_offline_combat.task_squads[741] == true and trust_lines(Hm, "quest_delivery_place") == 1,
		"refuse: a hand-over to the NPC a client wrote in as the target is refused")
	Hm.env.coop_trust.reset_for_test(nil)
	Hm.tm.task_info.drx_sl_dlv_t = nil
end

-------------------------------------------------------------------------------
-- Round 4 (S2 of the round 3 review): a counted effect the host's own logic runs (its condlists, the host player's dialog, an
-- on_init) is noted as a client's ask is: a client cannot have the same thing made a second time.
-------------------------------------------------------------------------------
print("== S2: what the host's own logic made counts once per world")
do
	fresh()
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse", quest_effect_once = "refuse" })
	local n0 = #Hm.spawned
	Hm.env.xr_effects.spawn_item_at_pos(Hm.actor, nil, { "wpn_gauss_quest" }) -- the host's own condlist runs it
	check(#Hm.spawned == n0 + 1, "(the host's own logic made the Gauss rifle)")
	ask("fx", { f = "spawn_item_at_pos", p1 = "wpn_gauss_quest" })
	check(#Hm.spawned == n0 + 1 and trust_lines(Hm, "quest_spawn_once") == 1,
		"a client's ask of the same rifle after it: refused, made once")
	-- the host's own run that raised made nothing: not noted, a client's ask holds
	Hm.spawn_raise = true
	check(not pcall(Hm.env.xr_effects.spawn_item_at_pos, Hm.actor, nil, { "drx_x19_documents" }), "(the host's own run raised)")
	ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x19_documents" })
	check(Hm.spawned[#Hm.spawned] == "drx_x19_documents" and trust_lines(Hm, "quest_spawn_once") == 1,
		"the host's own run raised: nothing noted, a client's ask makes it")
	-- an mlr set of the host player's dialog, an effect of the rest of the white list
	Hm.env.mlr_utils.spawn_item("spawn_host_set")
	ask("fx", { f = "mlr_spawn_item", p1 = "spawn_host_set" })
	check(trust_lines(Hm, "quest_spawn_once") == 2, "an mlr set the host's own dialog made: a client's ask refused")
	local mines = Hm.made_fx.ht_add_mine or 0
	Hm.env.xr_effects.ht_add_mine(Hm.actor, nil, {})
	ask("fx", { f = "ht_add_mine" })
	check((Hm.made_fx.ht_add_mine or 0) == mines + 1 and trust_lines(Hm, "quest_effect_once") == 1,
		"the ambush mine the host's own logic made: a client's ask refused")
	-- a section the effect does not make is no key
	Hm.env.xr_effects.spawn_item_at_pos(Hm.actor, nil, { "junk_of_the_host" })
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_quest_spawns or {}) do listed[k] = true end
	check(listed["spawn_item_at_pos:wpn_gauss_quest"] and listed["mlr_spawn_item:spawn_host_set"] and listed.ht_add_mine
		and not listed["spawn_item_at_pos:junk_of_the_host"], "the host's save lists what its own logic made, not a section it cannot make")
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test(nil)
end

-------------------------------------------------------------------------------
-- Round 4 (S3 of the round 3 review): Crossfire's companion squad. The guard of this Lua state (before round 1) stays hard; the
-- saved list's refusal after a load follows coop_trust (quest_effect_once): "log" lets it through and logs it, as before round 1,
-- whose guard a load reset; "refuse" refuses it. The guard closes before the squad is made: an error after it exists closes it.
-------------------------------------------------------------------------------
-- a new Lua state of the host (a load): coop_quests_story anew, its guard open
local function story_anew()
	local s = load_script(Hm, "coop_quests_story")
	s.on_game_start()
	local cbs = Hm.callbacks.actor_on_first_update
	cbs[#cbs]() -- its install
	return s
end
print("== S3: after a load the squad made before is refused by the check, in its mode")
do
	fresh()
	story_anew()
	fire(Hm, "load_state", { coop_quest_spawns = { "isg_companion_squad" } })
	local n0 = Hm.made_fx.isg_companion_squad or 0
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1 and trust_lines(Hm, "quest_effect_once") == 1
		and last_trust(Hm, "quest_effect_once"):find("let through", 1, true) ~= nil,
		"log: made again after the load, as before round 1, and logged as one the check would refuse")
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1 and trust_lines(Hm, "quest_effect_once") == 1,
		"a second ask in the same Lua state: the hard guard, no squad and no 'let through' line")
	story_anew()
	fire(Hm, "load_state", { coop_quest_spawns = { "isg_companion_squad" } })
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_effect_once = "refuse" })
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1 and trust_lines(Hm, "quest_effect_once") == 2
		and last_trust(Hm, "quest_effect_once"):find("refused", 1, true) ~= nil, "refuse: after the load, refused by the check")
	Hm.env.coop_trust.reset_for_test(nil)
end

print("== S3: an error after the squad exists still closes the guard and notes it")
do
	fresh()
	story_anew()
	fire(Hm, "load_state", {})
	local n0 = Hm.made_fx.isg_companion_squad or 0
	Hm.fx_raise = "isg_companion_squad"
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1 and Hm.fx_raise == nil, "(the squad was made, then the effect raised)")
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1, "a second ask: refused by the guard, no second squad")
	local m = {}
	fire(Hm, "save_state", m)
	local listed = {}
	for _, k in ipairs(m.coop_quest_spawns or {}) do listed[k] = true end
	check(listed.isg_companion_squad == true, "the host's save keeps it: a load does not open it either")
	fire(Hm, "load_state", {})
end

-------------------------------------------------------------------------------
-- Round 5 (blocker 1 of the round 4 review): the vars of a client's give count as the host's facts only as far as they are what
-- the host offered him (coop_quests_offer keeps, per player, task and NPC, the vars of each offer it made); check
-- task_give_offer. A give with no offer of the host (his own machine's stock generation) keeps today's facts in "log".
-------------------------------------------------------------------------------
local npc2_h = Hm.new_obj(751, "sim_stalker_trader2", vec(5, 0, 0), { _stalker = true })
local npc2_c = Cm.new_obj(751, "sim_stalker_trader2", vec(1, 0, 0), { _stalker = true })
for _, M in ipairs({ Hm, Cm }) do
	M.ini.offer_f = { fetch_descr = "offer_f_descr", fetch_func = "%=setup_fetch_task(offer_f_fetch)%", job_descr = "offer_f_job" }
	M.npc_tasks = { [750] = { "offer_f" }, [751] = { "offer_f" } }
end
-- the host's fetch setup (tasks_fetch.setup_fetch_task): one bread at the barman, one salt at the trader
Hm.env.xr_effects.setup_fetch_task = function(a, n, p)
	local spk = Hm.env.get_speaker()
	Hm.env.save_var(Hm.actor, p[1], (spk and spk:id() == 751) and "salt" or "bread")
	Hm.env.save_var(Hm.actor, p[1] .. "_count", 1)
end
-- the honest path of a client: his dialog opens, the host's offer comes, the dialog shows it (its vars go into his pstor)
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
end
local function drop_task(id)
	Hm.tm.task_info[id], Cm.tm.task_info[id], Hm.engine_tasks[id] = nil, nil, nil
end
local function cps() return Cm.env.db.storage[0].pstor end

print("== R5 B1: an honest give of the host's offer: its facts, no line")
do
	fresh()
	proxy._pos = vec(4, 0, 0)
	NOW = NOW + 11000 -- (the tasks the sections above ended are out of their window)
	tick(Hm)
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse", task_give_offer = "refuse" })
	offered_at(npc_c)
	check(cps().offer_f_fetch == "bread", "(the host's offer is in his pstor: one bread)")
	give_it("offer_f", 750)
	check(Hm.tm.task_info.offer_f ~= nil and hps().offer_f_fetch == "bread" and counted("task_give_offer") == 1
		and trust_lines(Hm, "task_give_offer") == 0, "given, the bread the host offered, checked and held")
	Hm.actor._inv = {}
	Hm.give_item(Hm.actor, "bread")
	ask("take", { s = "bread", n = 1 })
	check(Hm.count(Hm.actor, "bread") == 0, "quest_take refuse: the bread of the host's offer is a fact, taken")
	drop_task("offer_f")
	-- the PDA board shows the offers of several NPCs; the row he takes is drawn from its own NPC's offer (prepare_task), and a
	-- dialog shows its NPC's offer
	offered_at(npc_c)
	offered_at(npc2_c)
	check(cps().offer_f_fetch == "salt", "(two NPCs offer it: the trader's salt is in his pstor)")
	give_it("offer_f", 751)
	check(hps().offer_f_fetch == "salt" and trust_lines(Hm, "task_give_offer") == 0,
		"the vars of the offer of the NPC who gives it: held")
	drop_task("offer_f")
	-- round 6 (S3 of the round 5 review): only the offers of the giver t.g count
	offered_at(npc_c)
	offered_at(npc2_c)
	give_it("offer_f", 750)
	check(hps().offer_f_fetch == "bread" and trust_lines(Hm, "task_give_offer") == 1,
		"round 6: the trader's offer is no offer of the barman, who gives it: refuse writes the barman's own (bread)")
	drop_task("offer_f")
	-- the offer is spent by the give: the same vars given again need a new offer
	give_it("offer_f", 750)
	check(trust_lines(Hm, "task_give_offer") == 2 and last_trust(Hm, "task_give_offer"):find("no offer", 1, true) ~= nil,
		"an offer is spent by its give: a second give of it is no offer's")
	drop_task("offer_f")
	Hm.env.coop_trust.reset_for_test(nil)
end

print("== R5 B1, the review's probe A1: a forged fetch carried in the give of a task the host offered")
do
	fresh()
	offered_at(npc_c)
	cps().offer_f_fetch, cps().offer_f_fetch_count = "wpn_gauss", 1000 -- a modified client rewrites what the dialog put there
	give_it("offer_f", 750)
	local line = last_trust(Hm, "task_give_offer")
	check(trust_lines(Hm, "task_give_offer") == 1 and line:find("anna", 1, true) and line:find("offer_f_fetch", 1, true)
		and line:find("would be refused", 1, true), "log: the line names the player and the var: " .. line)
	check(hps().offer_f_fetch == "wpn_gauss" and hps().offer_f_fetch_count == 1000, "log: written as before")
	drop_task("offer_f")
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse", task_give_offer = "refuse" })
	offered_at(npc_c)
	cps().offer_f_fetch, cps().offer_f_fetch_count = "wpn_gauss", 1000
	give_it("offer_f", 750)
	check(Hm.tm.task_info.offer_f ~= nil and hps().offer_f_fetch == "bread" and hps().offer_f_fetch_count == 1,
		"refuse: given with what the host offered him (bread x1), not his rifles")
	Hm.actor._inv = {}
	for _ = 1, 5 do Hm.give_item(Hm.actor, "wpn_gauss") end
	ask("take", { s = "wpn_gauss", n = 5 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 5, "refuse: no task asks the group for its rifles (5 left)")
	-- a fact var the offer never made (a leftover of an older offer in his pstor: put_vars never deletes) is not written at all;
	-- round 6 (S4 of the round 5 review): and out of the judgement, no line
	drop_task("offer_f")
	offered_at(npc_c)
	cps().offer_f_target_id = 760
	give_it("offer_f", 750)
	check(hps().offer_f_target_id == nil and trust_lines(Hm, "task_give_offer") == 2,
		"refuse: a fact var the giver's offer has not is not written, and writes no line")
	cps().offer_f_target_id = nil
	drop_task("offer_f")
	Hm.env.coop_trust.reset_for_test(nil)
end

print("== R5 B1, the review's probe A2: no offer of the host (a DRX id), forged rifles handed to an NPC")
do
	fresh()
	Hm.ini.drx_sl_forge_t = {}
	Cm.ini.drx_sl_forge_t = {}
	Cm.env.save_var(Cm.actor, "drx_sl_forge_t_fetch", "wpn_gauss") -- shared prefix: coop_tvd first, then the give carries it again
	Cm.env.save_var(Cm.actor, "drx_sl_forge_t_fetch_count", 50)
	pump()
	give_it("drx_sl_forge_t", 750)
	local line = last_trust(Hm, "task_give_offer")
	check(trust_lines(Hm, "task_give_offer") == 1 and line:find("no offer", 1, true) ~= nil and line:find("drx_sl_forge_t", 1, true),
		"log: a give with fact vars and no offer of the host: logged (" .. line .. ")")
	proxy._pos = vec(4, 0, 0)
	Hm.actor._inv = {}
	for _ = 1, 3 do Hm.give_item(Hm.actor, "wpn_gauss") end
	local before = Hm.count(npc_h, "wpn_gauss")
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_give_npc = "refuse" })
	give_npc("wpn_gauss", 3)
	check(Hm.count(npc_h, "wpn_gauss") == before + 3, "log: his vars are facts as before (quest_give_npc lets them go)")
	drop_task("drx_sl_forge_t")
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_give_npc = "refuse", quest_take = "refuse", task_give_offer = "refuse" })
	give_it("drx_sl_forge_t", 750)
	check(Hm.tm.task_info.drx_sl_forge_t ~= nil and hps().drx_sl_forge_t_fetch == nil,
		"refuse, round 6: given; a fetch no generator of the task makes (it has no fetch_func) is not written")
	for _ = 1, 3 do Hm.give_item(Hm.actor, "wpn_gauss") end
	before = Hm.count(npc_h, "wpn_gauss")
	give_npc("wpn_gauss", 3)
	check(Hm.count(npc_h, "wpn_gauss") == before and Hm.count(Hm.actor, "wpn_gauss") == 3,
		"refuse: but no fact of the host's: no group rifle goes to the NPC")
	ask("take", { s = "wpn_gauss", n = 1 })
	check(Hm.count(Hm.actor, "wpn_gauss") == 3, "refuse: nor to the taker")
	drop_task("drx_sl_forge_t")
	-- a give that carries no fact var is not judged
	local n0 = counted("task_give_offer")
	Hm.ini.plain_t = {}
	Cm.ini.plain_t = {}
	Cm.env.save_var(Cm.actor, "plain_t_note", 3)
	give_it("plain_t", 750)
	check(Hm.tm.task_info.plain_t ~= nil and counted("task_give_offer") == n0, "a give with no fact var: not judged")
	drop_task("plain_t")
	Hm.env.coop_trust.reset_for_test(nil)
end

print("== R5 B1, the review's probe A6: give -> take -> cancel -> give again does not ask the group again")
do
	fresh()
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_take = "refuse" })
	Hm.ini.cyc_t = {}
	Cm.ini.cyc_t = {}
	Hm.actor._inv = {}
	for _ = 1, 10 do Hm.give_item(Hm.actor, "medkit_a6") end
	local cb = Hm.env.task_manager.task_callback
	local function engine_end(id, state) cb({ get_id = function() return id end }, state) end
	for _ = 1, 4 do
		Cm.env.save_var(Cm.actor, "cyc_t_fetch", "medkit_a6")
		Cm.env.save_var(Cm.actor, "cyc_t_fetch_count", 2)
		give_it("cyc_t", 750)
		ask("take", { s = "medkit_a6", n = 2 })
		Cm.tm:set_task_cancelled("cyc_t")
		pump()
		engine_end("cyc_t", Hm.env.task.fail) -- the engine ends it (the stub drops a task without a repeat timeout)
		drop_task("cyc_t")
	end
	check(Hm.count(Hm.actor, "medkit_a6") == 8, "4 cycles: the 2 medkits of one run, not 8 (" .. Hm.count(Hm.actor, "medkit_a6") .. " of 10 left)")
	-- honest: a run turned in (completed) gives the next run of the task its own take
	Hm.actor._inv = {}
	for _ = 1, 4 do Hm.give_item(Hm.actor, "medkit_a6") end
	Hm.ini.rep2_t = {}
	Cm.ini.rep2_t = {}
	for run = 1, 2 do
		Cm.env.save_var(Cm.actor, "rep2_t_fetch", "medkit_a6")
		Cm.env.save_var(Cm.actor, "rep2_t_fetch_count", 2)
		give_it("rep2_t", 750)
		ask("take", { s = "medkit_a6", n = 2 })
		check(Hm.count(Hm.actor, "medkit_a6") == 4 - 2 * run, "run " .. run .. " of a task done twice: its 2 medkits taken")
		engine_end("rep2_t", Hm.env.task.completed)
		drop_task("rep2_t")
	end
	Hm.env.coop_trust.reset_for_test(nil)
end

-------------------------------------------------------------------------------
-- Round 5 (S6 of the round 4 review): Crossfire's companion squad made by the host's own logic is noted even when its effect
-- raises after the squad exists (as a client's ask is).
-------------------------------------------------------------------------------
print("== R5 S6: the host's own run of the isg squad that raised after making it: noted, a client's ask refused")
do
	fresh()
	story_anew()
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_effect_once = "refuse" })
	local n0 = Hm.made_fx.isg_companion_squad or 0
	Hm.fx_raise = "isg_companion_squad"
	check(not pcall(Hm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad), "(the host's own run raised after the squad)")
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1, "(one squad exists)")
	Cm.env.dialogs_lostzone.spawn_pass_hall_isg_companion_squad()
	pump()
	check((Hm.made_fx.isg_companion_squad or 0) == n0 + 1 and trust_lines(Hm, "quest_effect_once") == 1,
		"a client's ask after it: refused, no second squad")
	-- any other effect of the host's own logic that raised is still not noted (a failed spawn can be made later)
	Hm.env.coop_trust.reset_for_test({ default = "log", quest_spawn_once = "refuse" })
	Hm.spawn_raise = true
	check(not pcall(Hm.env.xr_effects.spawn_item_at_pos, Hm.actor, nil, { "drx_x18_documents" }), "(a spawn of the host raised)")
	ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x18_documents" })
	check(Hm.spawned[#Hm.spawned] == "drx_x18_documents", "that one is not noted: a client's ask makes it")
	fire(Hm, "load_state", {})
	Hm.env.coop_trust.reset_for_test(nil)
end

-------------------------------------------------------------------------------
-- Round 7 (the review of round 6: bounds on every number from a client): the NPC of an fx ask and of an offer request is a whole
-- object id 1..65534 before any engine lookup.
-------------------------------------------------------------------------------
print("== R7: the NPC id of an fx ask and of an offer request is bounded")
do
	fresh()
	fire(Hm, "load_state", {})
	local seen = {}
	local obi = Hm.env.level.object_by_id
	Hm.env.level.object_by_id = function(x)
		if type(x) == "number" and not (x >= 0 and x < 65535 and x == math.floor(x)) then seen[#seen + 1] = tostring(x) end
		return obi(x)
	end
	for _, n in ipairs({ 1e309, -1e309, 70000.5, -3, 0.5 }) do
		ask("fx", { f = "spawn_item_at_pos", p1 = "drx_x8_documents", n = n })
		Cm.env.coop.send_event("quests.offer_req", "k=sdyn;n=n" .. tostring(n) .. ";q=n1e309", 0)
		pump()
	end
	Hm.env.level.object_by_id = obi
	check(#seen == 0, "no engine lookup gets an id that is not 0..65534: " .. table.concat(seen, ", "))
	fire(Hm, "load_state", {})
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
