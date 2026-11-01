-- Companions and split levels (docs\SPLIT_LEVELS.md 7a): a stand of the world server on l01_escape (peer 0), a map server of l02_garbage
-- (bridge 0x101) and two clients (peers 1, 2; proxies 500, 501). The owner's rule: control passes only between players of one level, and
-- the machine that leads the level decides, by the engine's table of who stands where (coop.levels.level_of_player).
-- Run: tools\test_lua.cmd companion_levels
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")

local BRIDGE = 0x101
local PROXY = { [1] = 500, [2] = 501 }
local LEVEL_OF_VERTEX = { [10] = 1, [20] = 2 }
local NAMES = { [1] = "l01_escape", [2] = "l02_garbage" }

local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

local function new_squad(id, vertex, ...)
	local t = { id = id, members = { ... }, m_game_vertex_id = vertex }
	function t.squad_members(self)
		local i = 0
		return function() i = i + 1; local m = t.members[i]; if m then return { id = m } end end
	end
	function t.commander_id() return t.members[1] end
	return luabind_object(t)
end

local function stock(M, W)
	local E = M.env
	E.actor_menu = { set_msg = function(_, text) M.msgs = M.msgs or {}; M.msgs[#M.msgs + 1] = text end }
	E.game.translate_string = function(s)
		if s == "st_coop_comp_gave_you" or s == "st_coop_comp_took_from_you" or s == "st_coop_comp_you_gave" then return s .. " %s %s" end
		return s .. " %s"
	end
	E.axr_task_manager = { hostages_by_id = {} }
	E.EDDListType = { iActorBag = 1, iDeadBodyBag = 2 }
	E.key_bindings = { kCUSTOM3 = 33 }
	E.dik_to_bind = function(d) return d end
	E.dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
	E.CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
	E.alife_object = function(id)
		if M == W.Mk and W.not_yet[id] then return nil end
		return W.bodies[id] or W.squads[id] or M.objects[id]
	end
	E.get_object_squad = function(o)
		for _, sq in pairs(W.squads) do
			for k in sq:squad_members() do if k.id == o:id() then return sq end end
		end
	end
	E.alife = function()
		return { level_name = function(_, id) return NAMES[id] end }
	end
	E.game_graph = function()
		return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF_VERTEX[gv] end } end }
	end
	M.se = {}
	E.se_save_var = function(id, name, var, value) M.se[id] = M.se[id] or {}; M.se[id][var] = value end
	E.se_load_var = function(id, name, var) return M.se[id] and M.se[id][var] end
	local ac = { companion_squads = {}, assigned = {}, logic = {} }
	E.axr_companions = ac
	function ac.setup_companion_logic(npc, st, loaded, cannot_dismiss)
		ac.logic[npc:id()] = { cannot_dismiss = cannot_dismiss }
		npc:give_info_portion("npcx_is_companion")
	end
	function ac.companion_squad_can_teleport(squad)
		return not E.se_load_var(squad:commander_id(), nil, "companion_cannot_teleport")
	end
	function ac.get_inventory_table() return {} end
	function ac.list_actor_squad_by_id()
		local t = {}
		for id in pairs(ac.companion_squads) do t[#t + 1] = id end
		table.sort(t)
		return t
	end
	E.dialogs_axr_companion = {
		is_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") end,
		is_not_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") ~= true end,
		dm_init_is_actor_companion = function(dialog) dialog:AddPhrase("stock", "1", "0", -10000) end,
		become_actor_companion = function(actor, npc)
			local sq = E.get_object_squad(npc)
			ac.companion_squads[sq.id] = sq
			npc:give_info_portion("npcx_is_companion")
		end,
		remove_companions_from_squad = function(actor, npc)
			ac.companion_squads[E.get_object_squad(npc).id] = nil
			npc:disable_info_portion("npcx_is_companion")
		end,
	}
	E.axr_beh = { action_beh = { execute = function(self) M.beh_actor = E.db.actor:id() end } }
	E.sim_squad_scripted = { sim_squad_scripted = { get_current_task = function(self) return "stock task" end } }
	E.TeleportSquad = function(squad, pos, lvid, gvid)
		M.teleported = { id = squad.id, pos = pos, lvid = lvid, gvid = gvid }
		local t = W.tables[squad.id]
		if t then t.m_game_vertex_id = gvid end
	end
end

-- The stand: A next to the host on l01_escape, B on l02_garbage under its map server. opts.split = false: split levels off.
local function stand(opts)
	opts = opts or {}
	reset_world()
	local W = { bodies = {}, squads = {}, tables = {}, level_of = { [0] = 1, [1] = 1, [2] = 2 }, split = opts.split ~= false, online = {},
		not_yet = {} }
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local Mk = machine("client", BRIDGE, opts.mk_knows_all and { [1] = 500, [2] = 501 } or { [2] = 501 })
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	W.H, W.Mk, W.A, W.B = H, Mk, A, B
	Mk.env.coop.is_map_server = function() return true end
	Mk.env.coop.is_mirror = function() return false end
	Mk.env.level.name = function() return NAMES[2] end
	-- what a map server says to a player of its level comes down the tunnel: the client hears the world server
	local send = Mk.env.coop.send_event
	Mk.env.coop.send_event = function(name, payload, target)
		if type(target) == "number" and target > 0 and target < 0x100 then
			Mk.sent[#Mk.sent + 1] = { name = name, payload = payload, target = target }
			QUEUE[#QUEUE + 1] = { from = 0, name = name, payload = payload, target = target }
			return true
		end
		return send(name, payload, target)
	end
	local function levels_for(M)
		return {
			split = function() return W.split end,
			level_of_player = function(peer) return W.split and W.level_of[peer] or 1 end,
			level_name = function(id) return NAMES[id] end,
			bridge_of_player = function(peer)
				if M == H and W.split and W.level_of[peer] == 2 then return BRIDGE end
				return nil
			end,
			online_at_server = function(id) return W.online[id] == true end,
			map_servers = function()
				return M == H and W.split and { { bridge = BRIDGE, level = 2 } } or {}
			end,
		}
	end
	for _, M in ipairs({ H, Mk, A, B }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W)
		M.env.coop.levels = levels_for(M)
		local players = M.env.coop.players
		M.env.coop.players = function()
			local list = players()
			for _, p in ipairs(list) do
				p.level = W.level_of[p.id]
				p.elsewhere = W.split and not p.is_self and M ~= H and M ~= Mk and p.level ~= W.level_of[M.peer] or nil
				if p.elsewhere and opts.far_no_avatar then p.avatar_id = nil end
			end
			return list
		end
		if opts.env then opts.env(M) end
	end
	W.proxy_a = H.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = Mk.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	A.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	B.add(make_obj(501, 0, 0, 0, { _name = "ms_avatar" }))
	-- squad 300 (member 201) next to the host and A; squad 400 (member 301) next to B
	function W.squad(id, vertex, member)
		local t = { id = id, members = { member }, m_game_vertex_id = vertex }
		function t.squad_members(self)
			local i = 0
			return function() i = i + 1; local m = t.members[i]; if m then return { id = m, object = W.bodies[m] } end end
		end
		function t.commander_id() return t.members[1] end
		W.tables[id] = t
		W.squads[id] = luabind_object(t)
		return W.squads[id]
	end
	W.squad(300, 10, 201)
	W.squad(400, 20, 301)
	W.comp = H.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp_a = A.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp2 = Mk.add(make_obj(301, 7, 0, 0, { _name = "comp2" }))
	W.comp2_b = B.add(make_obj(301, 7, 0, 0, { _name = "comp2" }))
	W.CH = load_script(H, "coop_npc_companions")
	W.CM = load_script(Mk, "coop_npc_companions")
	W.CA = load_script(A, "coop_npc_companions")
	W.CB = load_script(B, "coop_npc_companions")
	W.CH.on_game_start()
	W.CM.on_game_start()
	W.CA.on_game_start()
	W.CB.on_game_start()
	W.comp:give_info_portion("npcx_is_companion")
	W.comp2:give_info_portion("npcx_is_companion")
	H.env.axr_companions.companion_squads[300] = W.squads[300]
	Mk.env.axr_companions.companion_squads[400] = W.squads[400]
	function W.refresh()
		NOW = NOW + 3000
		for _, M in ipairs({ H, Mk, A, B }) do
			M.env.coop_npc_players.invalidate()
			M.fire("actor_on_update")
		end
		pump()
	end
	-- a player moves: the engine's table says so, the character leaves one process and comes to the other
	function W.move(peer, level)
		W.level_of[peer] = level
		local id = PROXY[peer]
		local obj = H.objects[id] or Mk.objects[id]
		H.objects[id], Mk.objects[id] = nil, nil
		local M = level == 1 and H or Mk
		if obj then M.objects[id] = obj end
		W.bodies[id] = { position = vec(1, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = level == 1 and 10 or 20, id = id }
		for _, each in ipairs({ H, Mk, A, B }) do each.env.coop_npc_players.invalidate() end
	end
	W.refresh()
	return W
end

local function last(M) return M.msgs and M.msgs[#M.msgs] or "" end
local function ask(M, t)
	M.env.coop_npc_players.send("npc.comp_lead", t, 0)
	pump()
end

print("== hand over: refused for a player on another level, the host decides by its table")
do
	local W = stand({ far_no_avatar = true })
	local H, A, B = W.H, W.A, W.B
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	check(W.CA.dlg_can_hand(A.env.db.actor, W.comp_a) == true, "the leader is offered the hand-over")
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "1" }) == "p0", "a player of his level: the nick")
	local text = W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	check(text:find("st_coop_comp_refused_elsewhere", 1, true) and text:find("p2", 1, true),
		"a player of another level stays in the list and says so: " .. text)
	check(W.CA.dlg_slot(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == true, "his line stays in the list")
	A.msgs = nil
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 500, "the host keeps the leader")
	check(last(A):find("st_coop_comp_refused_elsewhere", 1, true) and last(A):find("p2", 1, true), "the asker hears who and why: " .. last(A))
	check(W.CH._stats().lead_refused == 1, "the refusal is counted (coop_status)")
	NOW = NOW + 3001
	ask(A, { a = "give", i = 201, to = 2 })
	check(L()[300] == 500, "a client that skips its window gets the same answer: the host decides")

	W.move(2, 1)
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 501, "the same player on the same level: the hand-over goes through")
	check(last(B):find("st_coop_comp_gave_you", 1, true) ~= nil, "the new leader is told")
end

print("== hand over on a map server's level, to the host who is not there")
do
	local W = stand()
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 501
	W.refresh()
	check(W.CB.dlg_slot_text(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" }):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil,
		"the host stands elsewhere: the line says so")
	B.msgs = nil
	W.CB.dlg_hand(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" })
	pump()
	check(L()[400] == 501, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p0", 1, true), "he hears who: " .. last(B))
end

print("== take: not from a leader who stands on another level")
do
	local W = stand({ mk_knows_all = true })
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 500 -- A leads it from l01_escape: it could not follow him
	Mk.se[301] = { companion_cannot_teleport = true }
	W.refresh()
	B.msgs = nil
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 500, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p1", 1, true), "he hears who: " .. last(B))
	W.level_of[1] = 2
	Mk.add(W.proxy_a)
	W.H.objects[500] = nil
	W.proxy_a._pos = vec(5, 0, 0)
	W.refresh()
	NOW = NOW + 3001
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "on one level he takes it")
	check(Mk.msgs == nil, "a map server has nobody of its own to tell")
end

print("== take: a leader who left the game is no reason to wait")
do
	local W = stand()
	local B = W.B
	local L = W.CM._leaders
	L()[400] = 777 -- a character of nobody in the session
	W.refresh()
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "it is his")
end

print("== a story NPC of a task: the same rule")
do
	local W = stand()
	local H, A = W.H, W.A
	local L = W.CH._leaders
	local taker = 1
	H.env.coop_tasks = { reward_peer = function() return taker end, giving_npc = function() return nil end }
	W.CH = load_script(H, "coop_npc_companions") -- the wrappers are put once: the module again, on its stock
	H.env.xr_effects = {
		setup_companion_task = function(actor, npc, p)
			W.squad(310, 10, 211)
			H.env.axr_companions.companion_squads[310] = W.squads[310]
		end,
	}
	H.callbacks = {}
	H.handlers = {}
	W.CH.on_game_start()
	L = W.CH._leaders
	W.story = H.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	W.story_a = A.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "310", "esc_smart" })
	W.refresh()
	check(L()[310] == 500, "(the taker leads it)")
	W.CA.dlg_hand(A.env.db.actor, W.story_a, "d", "p", "", { "2" })
	pump()
	check(L()[310] == 500 and last(A):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil, "not to a player of another level")
end

print("== split levels off: as before")
do
	local W = stand({ split = false })
	local H, A = W.H, W.A
	local L = W.CH._leaders
	L()[300] = 500
	W.move(2, 1)
	W.level_of[2] = 2 -- what it says is not read: there is one level for everybody
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == "p2", "the line is the nick")
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 501, "the hand-over goes through")
end

print("== the host's level change: a squad somebody else leads stays")
do
	local W = stand()
	local H = W.H
	local ac = H.env.axr_companions
	W.CH._leaders()[300] = 500
	W.squad(310, 10, 211)
	ac.companion_squads[310] = W.squads[310]
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "a squad a client leads does not go with the host")
	check(ac.companion_squad_can_teleport(W.squads[310]) == true, "his own does")
	H.se[211] = { companion_cannot_teleport = true }
	check(ac.companion_squad_can_teleport(W.squads[310]) == false, "the stock's rule stands for his own")
	H.se[211] = nil
	local asked = 0
	ac.companion_squad_can_teleport = function(squad) asked = asked + 1; return squad.id ~= 310 end -- Useful Idiots, loaded after us
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "over a patch that came later too")
	check(ac.companion_squad_can_teleport(W.squads[310]) == false and asked == 1, "the patch still decides for the host's own")
	W.split = false
	check(ac.companion_squad_can_teleport(W.squads[300]) == true and asked == 2, "split levels off: as before")
end

print("== a client leaves the host's level: his squad goes after him, the map server of his level takes it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp" }))
	H.objects[201] = nil
	W.move(1, 2)
	W.refresh()
	check(H.teleported and H.teleported.id == 300 and H.teleported.gvid == 20, "the world server teleports it to his body")
	check(L()[300] == nil and H.env.axr_companions.companion_squads[300] == nil, "it is no companion of this level any more")
	check(W.CM._leaders()[300] == 500 and Mk.env.axr_companions.companion_squads[300] == W.squads[300], "the map server takes it")
	check(Mk.env.axr_companions.logic[201] ~= nil, "with the logic of a companion")
end

print("== a squad that may not follow stays where it is, and keeps its leader")
do
	local W = stand()
	local H = W.H
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	H.se[201] = { companion_cannot_teleport = true } -- the Fanatic (dialogs_escape), a task's squad
	W.move(1, 2)
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "not teleported")
	check(L()[300] == 500 and H.env.axr_companions.companion_squads[300] ~= nil, "his entry stays, it is his when he comes back")
	check(W.CH.leader_of(W.comp) == nil, "meanwhile it acts for the host: no leader here")
	H.se[201] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 300, "the mark gone, it goes after him")
end

print("== a client leaves a map server's level: it lets the squad go, the world server takes it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	LM()[400] = 501
	W.refresh()
	W.online[301] = true
	W.proxy_b._alive = true
	W.move(2, 1)
	W.refresh()
	check(LM()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "the map server lets it go")
	check(H.teleported == nil, "the world server waits: a member is online at the map server")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "then teleports it to his body")
	check(W.CH._leaders()[400] == 501 and H.env.axr_companions.companion_squads[400] == W.squads[400], "the host's level takes it")
end

print("== a task's squad on a map server's level: the map server takes it, with the logic and the stock's marks")
do
	local TAKER
	local W = stand({ env = function(M)
		M.env.coop_tasks = { reward_peer = function() return TAKER end, giving_npc = function() return nil end }
		M.env.xr_effects = { add_task_companion = function(actor, npc, p)
			local ac = M.env.axr_companions
			ac.companion_squads[p[1]] = W_squads[p[1]]
			M.se[301] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = true }
		end }
	end })
	W_squads = W.squads
	local H, Mk = W.H, W.Mk
	local ac = Mk.env.axr_companions
	ac.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	W.not_yet[400] = true
	W.bodies[301] = { name = function() return "comp2" end }
	TAKER = 2
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 400 })
	TAKER = nil
	pump()
	check(ac.companion_squads[400] == nil, "the squad is not on the map server yet: nothing to take")
	W.not_yet[400] = nil
	W.refresh()
	check(W.CM._leaders()[400] == 501 and ac.companion_squads[400] == W.squads[400], "it comes: the map server takes it, its leader the taker")
	check(ac.logic[301] ~= nil and ac.logic[301].cannot_dismiss == true, "the logic of a companion: he does not go back to his own walker")
	check(Mk.se[301] and Mk.se[301].companion == true and Mk.se[301].companion_cannot_dismiss == true
		and Mk.se[301].companion_cannot_teleport == true, "the stock's marks: the binder reads them when he comes online")
	check(W.CH._leaders()[400] == nil, "the world server does not lead it")
	check(H.env.axr_companions.companion_squads[400] ~= nil, "its table keeps the squad: task scripts ask it")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "the save has the leader at once")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "it does not go with the host")
	check(#H.env.axr_companions.list_actor_squad_by_id() == 1, "the host's squad list and keys are not for it")
	W.refresh()
	check(H.teleported == nil and W.CM._leaders()[400] == 501, "with its leader on its level it stays")
end

print("== a companion a status functor writes into the stock table (tasks_agent_rescue): the taker leads it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local ac = H.env.axr_companions
	local before = W.CH.squads_now()
	ac.companion_squads[310] = W.squad(310, 10, 211)
	check(W.CH.claim_since(before, 1) == 1 and W.CH._leaders()[310] == 500, "a squad of this level: its taker is its leader")
	ac.companion_squads[311] = W.squad(311, 10, 212)
	W.CH._leaders()[311] = 501
	check(W.CH.claim_since(before, 1) == 0 and W.CH._leaders()[311] == 501, "a wrapper of the stock claimed it already: it stays")
	before = W.CH.squads_now()
	W.bodies[301] = { name = function() return "comp2" end }
	Mk.env.axr_companions.companion_squads[400] = nil
	ac.companion_squads[400] = W.squads[400]
	local sent = #sent_named(H, "npc.comp_adopt")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "a squad on a map server's level goes there")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "once")
	pump()
	check(W.CM._leaders()[400] == 501, "the map server leads it")
end

print("== a member online when the map server takes the squad, a companion of it already")
do
	local W = stand()
	local Mk = W.Mk
	W.CH._leaders()[300] = 500
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp", _info = { npcx_is_companion = true } }))
	W.H.objects[201] = nil
	W.move(1, 2)
	W.refresh()
	check(Mk.env.axr_companions.logic[201] == nil, "no second setup: it would reset his orders")
end

print("== the leaders of a map server's level: into the save, onto a new map server")
do
	local function share_env(M)
		M.share = { up = {}, down = {} }
		M.env.coop_levels_share = {
			up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
	end
	local W = stand({ env = share_env })
	local H, Mk = W.H, W.Mk
	local up, down = "comp_leaders", "comp_leaders"
	check(Mk.share.up[up] ~= nil and H.share.down[down] ~= nil, "both tables are declared")
	local LM = W.CM._leaders
	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "a leader on the map server reaches the save")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "the world server knows it for somebody's")
	LM()[300] = 500 -- the save's entry of a squad of another level
	W.refresh()
	check(LM()[300] == nil, "a map server keeps only the squads of its level")
	local row = Mk.share.up[up].get()
	check(row.l[400] == 501 and row.l[300] == nil, "and reports those")
	LM()[400] = nil
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "dismissed there: gone from the save")

	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	LM()[400] = nil
	Mk.env.axr_companions.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	local given = H.share.down[down].get()
	Mk.share.down[down].set(given)
	check(LM()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "a new map server gets the leaders of its level")
	check(Mk.env.axr_companions.logic[301] ~= nil, "and sets the logic up")
	LM()[400] = 500
	Mk.share.down[down].set(given)
	check(LM()[400] == 500, "the word counts once: what the map server changed since is newer")
end

print("== a save with leaders of every level: each process keeps its own")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local saved = { coop_npc_leaders = { [300] = 500, [400] = 501 } }
	H.fire("load_state", saved)
	Mk.fire("load_state", saved)
	W.refresh()
	check(W.CH._leaders()[300] == 500 and W.CH._leaders()[400] == nil, "the world server leads the squads of its level")
	check(W.CM._leaders()[400] == 501 and W.CM._leaders()[300] == nil, "the map server those of its own")
	check(H.teleported == nil, "nobody takes a squad on another level for one left behind")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[300] == 500 and m.coop_npc_leaders[400] == 501, "the next save has them all")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
