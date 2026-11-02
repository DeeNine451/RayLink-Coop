-- Companion control (owner's request 2026-11-01): every companion squad has one leader, a player; he hands control to another
-- player, any other player takes it, and the companion walks after whoever holds control. Three machines: the host (peer 0)
-- and two clients (peers 1, 2; proxies 500, 501 in host numbering). Squads are luabind stand-ins (tests\lua\support\luabind_like.lua).
-- Run: tools\test_lua.cmd companion_lead
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")

local PROXY = { [1] = 500, [2] = 501 }

local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

-- The stock names the script touches. Host: the real tables. Client: stock's empty companion_squads, the same module shapes.
local function stock(M, squads)
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
	E.alife_object = function(id) return squads[id] end
	E.get_object_squad = function(o)
		for _, sq in pairs(squads) do
			for k in sq:squad_members() do if k.id == o:id() then return sq end end
		end
	end
	local ac = { companion_squads = {}, cycled = {}, assigned = {} }
	E.axr_companions = ac
	function ac.cycle_state()
		if M.boom then error("boom", 0) end
		ac.cycled = {}
		for id in pairs(ac.companion_squads) do ac.cycled[id] = true end
	end
	function ac.list_actor_squad_by_id()
		local t = {}
		for id in pairs(ac.companion_squads) do t[#t + 1] = id end
		table.sort(t)
		return t
	end
	function ac.move_to_point() M.moved = (M.moved or 0) + 1 end
	function ac.get_nearby_companion() return M.aimed or next(ac.companion_squads) ~= nil end
	function ac.is_assigned_item(npc_id, item_id) return ac.assigned[npc_id] ~= nil and ac.assigned[npc_id][item_id] == true end
	function ac.is_assigned_companion(a, b)
		local npc = a:id() > 0 and a or b
		return ac.assigned[npc:id()] ~= nil
	end
	function ac.get_inventory_table(npc, id, mode)
		local t = {}
		for item in pairs(ac.assigned[id] or {}) do t[item] = "sec" end
		return t
	end
	function ac.OnItemAfterMove(npc_id, obj, mode, bag)
		ac.assigned[npc_id] = ac.assigned[npc_id] or {}
		ac.assigned[npc_id][obj:id()] = bag == E.EDDListType.iActorBag and true or nil
	end
	function ac.transfer_item(item_id, from, to) M.stock_transfer = (M.stock_transfer or 0) + 1 end
	function ac.set_companion_to_follow_state(o) o:disable_info_portion("npcx_beh_wait") end
	E.dialogs_axr_companion = {
		is_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") end,
		is_not_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") ~= true end,
		dm_init_is_actor_companion = function(dialog) dialog:AddPhrase("stock", "1", "0", -10000) end,
		become_actor_companion = function(actor, npc)
			M.became = true
			for _, sq in ipairs(M.split or { E.get_object_squad(npc) }) do ac.companion_squads[sq.id] = sq end
			npc:give_info_portion("npcx_is_companion")
		end,
		remove_companions_from_squad = function(actor, npc)
			ac.companion_squads[E.get_object_squad(npc).id] = nil
			npc:disable_info_portion("npcx_is_companion")
		end,
		set_companion_to_wait_state = function(actor, npc) npc:give_info_portion("npcx_beh_wait") end,
	}
	E.axr_beh = { action_beh = { execute = function(self) M.beh_actor = E.db.actor:id() end } }
	E.sim_squad_scripted = { sim_squad_scripted = { get_current_task = function(self) return "stock task" end } }
	E.TeleportSquad = function(squad, pos, lvid, gvid) M.teleported = { id = squad.id, pos = pos, lvid = lvid, gvid = gvid } end
end

local function new_squad(id, ...)
	local t = { id = id, members = { ... } }
	function t.squad_members(self)
		local i = 0
		return function() i = i + 1; local m = t.members[i]; if m then return { id = m } end end
	end
	function t.commander_id() return t.members[1] end
	return luabind_object(t)
end

-- A full stand: squads 300 (member 201) and 310 (member 211), both near everybody, the host's companions until claimed.
local function stand(opts)
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	local W = { H = H, A = A, B = B, squads = { [300] = new_squad(300, 201), [310] = new_squad(310, 211) } }
	for _, M in ipairs({ H, A, B }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W.squads)
		if opts and opts.env then opts.env(M) end
	end
	W.proxy_a = H.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = H.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	A.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	A.add(make_obj(501, 6, 0, 0, { _name = "b_avatar" }))
	B.add(make_obj(501, 0, 0, 0, { _name = "host_avatar" }))
	B.add(make_obj(500, 5, 0, 0, { _name = "a_avatar" }))
	W.comp = H.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp2 = H.add(make_obj(211, 8, 0, 0, { _name = "comp2" }))
	W.comp_a = A.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp_b = B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp2_a = A.add(make_obj(211, 8, 0, 0, { _name = "comp2" }))
	W.CH = load_script(H, "coop_npc_companions")
	W.CA = load_script(A, "coop_npc_companions")
	W.CB = load_script(B, "coop_npc_companions")
	W.CH.on_game_start()
	W.CA.on_game_start()
	W.CB.on_game_start()
	W.comp:give_info_portion("npcx_is_companion")
	W.comp2:give_info_portion("npcx_is_companion")
	H.env.axr_companions.companion_squads[300] = W.squads[300]
	H.env.axr_companions.companion_squads[310] = W.squads[310]
	function W.refresh()
		NOW = NOW + 3000
		H.fire("actor_on_update")
		A.fire("actor_on_update")
		B.fire("actor_on_update")
		pump()
	end
	W.refresh()
	return W
end

local function ctext(M) return M.msgs and M.msgs[#M.msgs] or "" end

print("== a client hands his companion to another client, by the host's decision")
local W = stand()
local H, A, B = W.H, W.A, W.B
local L = W.CH._leaders
L()[300] = 500
W.comp:give_info_portion("npcx_beh_wait")
W.refresh()
check(W.comp_a:has_info("npcx_is_companion") and W.comp_a:has_info("npcx_beh_wait"), "the leader's machine has the flags")
check(W.comp_b:has_info("npcx_is_companion") and W.comp_b:has_info("npcx_beh_wait"), "another client too: a companion is the group's")
check(W.CA.dlg_can_hand(A.env.db.actor, W.comp_a) == true, "the leader is offered the hand-over")
check(W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == false, "the leader is not offered to take his own")
check(W.CB.dlg_can_hand(B.env.db.actor, W.comp_b) == false, "a non-leader cannot hand it over")
check(W.CB.dlg_can_take(B.env.db.actor, W.comp_b) == true, "a non-leader is offered to take it")
check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "1" }) == "p0", "the choice: first the host")
check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == "p2", "the choice: then the other client")
check(W.CA.dlg_slot(A.env.db.actor, W.comp_a, "d", "p", "", { "3" }) == false, "no third slot, the asker is not in his own list")
A.msgs, B.msgs = nil, nil
W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
check(L()[300] == 500, "nothing changes before the host decides")
pump()
check(L()[300] == 501, "the new leader's character")
check(ctext(A):find("st_coop_comp_you_gave", 1, true) and ctext(A):find("p2", 1, true), "the old leader is told")
check(ctext(B):find("st_coop_comp_gave_you", 1, true) and ctext(B):find("p1", 1, true), "the new leader is told")
check(W.comp_a:has_info("npcx_is_companion"), "the flags stay on the old leader's machine: he still gives orders")
check(W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == false, "a line just used stays away while the answer travels")
NOW = NOW + 3001
check(W.comp_b:has_info("npcx_is_companion") and W.comp_b:has_info("npcx_beh_wait"), "the new leader sees the flags: waiting stays")
check(W.CB.dlg_can_hand(B.env.db.actor, W.comp_b) == true and W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == true,
	"the roles swapped in the dialogs")
NOW = NOW + 1
H.env.axr_beh.action_beh.execute({ object = W.comp })
check(H.beh_actor == 501, "it walks after the new leader")
check(W.CH.leader_of(W.comp):id() == 501, "leader_of (inventory access, Ruling F2-32b) answers the new leader")

print("== orders follow the control")
W.proxy_a._pos, W.proxy_b._pos = vec(1000, 0, 0), vec(2000, 0, 0)
W.comp:disable_info_portion("npcx_beh_wait")
A.env.dialogs_axr_companion.set_companion_to_wait_state(A.env.db.actor, W.comp_a)
pump()
check(not W.comp:has_info("npcx_beh_wait"), "from afar a non-leader's order is refused: the dialog is face to face")
W.proxy_a._pos = vec(5, 0, 0)
A.env.dialogs_axr_companion.set_companion_to_wait_state(A.env.db.actor, W.comp_a)
pump()
check(W.comp:has_info("npcx_beh_wait"), "next to it the former leader's order goes through: orders are everybody's")
W.comp:disable_info_portion("npcx_beh_wait")
W.proxy_a._pos = vec(1000, 0, 0)
B.env.dialogs_axr_companion.set_companion_to_wait_state(B.env.db.actor, W.comp_b)
pump()
check(W.comp:has_info("npcx_beh_wait"), "the leader's order reaches his companion from any distance (hotkeys)")
W.proxy_a._pos, W.proxy_b._pos = vec(5, 0, 0), vec(6, 0, 0)

print("== take control: a client from a client, the host from a client, a client from the host")
A.msgs, B.msgs = nil, nil
W.CA.dlg_take(A.env.db.actor, W.comp_a)
pump()
check(L()[300] == 500, "the first client took it back")
check(ctext(A):find("st_coop_comp_you_took", 1, true) ~= nil, "the taker is told")
check(ctext(B):find("st_coop_comp_took_from_you", 1, true) and ctext(B):find("p1", 1, true), "the former leader is told")
check(W.CH.dlg_can_take(H.env.db.actor, W.comp) == true, "the host, not the leader, is offered to take it")
check(W.CH.dlg_can_hand(H.env.db.actor, W.comp) == false, "the host, not the leader, cannot hand it over")
check(H.env.dialogs_axr_companion.is_actor_companion(H.env.db.actor, W.comp) == true,
	"the host's stock command list stays open for a companion another player leads")
check(H.env.dialogs_axr_companion.is_actor_companion(H.env.db.actor, W.comp2) == true, "and open for his own")
check(H.env.dialogs_axr_companion.is_not_actor_companion(H.env.db.actor, W.comp) == false, "nobody recruits it")
check(B.env.dialogs_axr_companion.is_not_actor_companion(B.env.db.actor, W.comp_b) == false,
	"a client without the flag is not offered to recruit a companion of the group")
A.msgs, H.msgs = nil, nil
W.CH.dlg_take(H.env.db.actor, W.comp)
check(L()[300] == nil, "the host took it: no entry, the stock way")
check(ctext(H):find("st_coop_comp_you_took", 1, true) ~= nil, "the host is told at once")
pump()
check(ctext(A):find("st_coop_comp_took_from_you", 1, true) and ctext(A):find("p0", 1, true), "the client is told")
check(W.comp_a:has_info("npcx_is_companion"), "the flags stay on the client")
NOW = NOW + 3001
H.beh_actor = nil
NOW = NOW + 1
H.env.axr_beh.action_beh.execute({ object = W.comp })
check(H.beh_actor == 0, "it walks after the host")
check(W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == true, "a client may take a companion of the host")
W.CA.dlg_take(A.env.db.actor, W.comp_a)
check(W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == false, "one press: the line goes before the host's answer comes")
pump()
check(L()[300] == 500 and W.comp_a:has_info("npcx_is_companion"), "and it is his")
check(W.CA.dlg_can_take(A.env.db.actor, W.comp_a) == false, "it stays gone: he leads it now")

print("== the host hands over")
check(W.CH.dlg_can_hand(H.env.db.actor, W.comp2) == true, "the host hands over his own")
check(W.CH.dlg_slot_text(H.env.db.actor, W.comp2, "d", "p", "", { "1" }) == "p1", "his choice: first client")
W.CH.dlg_hand(H.env.db.actor, W.comp2, "d", "p", "", { "2" })
check(L()[310] == 501, "second client leads it")
pump()
check(ctext(B):find("st_coop_comp_gave_you", 1, true) ~= nil, "the new leader is told")

print("== the host refuses")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
local function ask(M, t)
	M.env.coop_npc_players.send("npc.comp_lead", t, 0)
	pump()
end
local stranger = H.add(make_obj(230, 7, 0, 0, { _name = "stranger" }))
ask(B, { a = "take", i = 230 })
check(L()[300] == 500 and next(L(), next(L())) == nil, "an NPC of no player: refused")
check(ctext(B):find("st_coop_comp_refused", 1, true) ~= nil, "the asker hears why")
ask(B, { a = "give", i = 201, to = 2 })
check(L()[300] == 500, "a non-leader cannot give")
ask(A, { a = "give", i = 201, to = 1 })
check(L()[300] == 500, "a hand-over to oneself: refused")
ask(A, { a = "give", i = 201, to = 7 })
check(L()[300] == 500, "a hand-over to a peer who is not here: refused")
ask(A, { a = "give", i = 201 })
check(L()[300] == 500, "a hand-over to nobody: refused")
W.proxy_b._pos = vec(500, 0, 0)
ask(B, { a = "take", i = 201 })
check(L()[300] == 500, "from afar: refused (the dialog is face to face)")
W.proxy_b._pos = vec(6, 0, 0)
W.comp._alive = false
ask(B, { a = "take", i = 201 })
check(L()[300] == 500, "a dead NPC: refused")
W.comp._alive = true
check(W.CH._stats().lead_refused == 7, "every refusal counted (coop_status): " .. tostring(W.CH._stats().lead_refused))

print("== a message in a talk goes to the talk window")
W = stand()
H, A, B = W.H, W.A, W.B
A.env.db.actor._talking = true
local talk_lines = {}
A.env.db.actor.give_talk_message2 = function(self, caption, text) talk_lines[#talk_lines + 1] = text end
W.CA.dlg_take(A.env.db.actor, W.comp_a)
pump()
check(#talk_lines == 1 and talk_lines[1]:find("st_coop_comp_you_took", 1, true) ~= nil, "the asker reads it in the talk")
check(A.msgs == nil, "not on the covered HUD")
A.env.db.actor._talking = false
print("-- the dialog's conditions answer booleans, whatever they get")
check(W.CA.dlg_can_take(nil, nil) == false, "no speakers: false, no error")
check(W.CA.dlg_slot(A.env.db.actor, W.comp_a, "d", "p", "", nil) == false, "no params: false")
check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "9" }) == "", "no such slot: an empty string")
check(H.env.dialogs_axr_companion.is_not_actor_companion(nil, W.comp) == false, "stock's debug call with no actor")

print("== the commands are in the companion's list; the dialog of a non-leader")
W = stand()
H, A, B = W.H, W.A, W.B
local added = {}
local function fake_dialog()
	local d = {}
	function d:AddPhrase(text, id, prev, goodwill)
		local s = { id = id, prev = prev, text = text, cond = {}, act = {} }
		added[id] = s
		function s:AddPrecondition(f) self.cond[#self.cond + 1] = f end
		function s:AddAction(f) self.act[#self.act + 1] = f end
		function s:SetScriptText(f) self.script_text = f end
		return { GetPhraseScript = function() return s end }
	end
	return d
end
A.env.dialogs_axr_companion.dm_init_is_actor_companion(fake_dialog())
check(added["1"] ~= nil, "the stock list is built first")
check(added["7000"] and added["7000"].prev == "1" and added["7000"].cond[1] == "coop_npc_companions.dlg_can_hand",
	"hand over: a line of the list of commands, for the leader")
check(added["7001"] and added["7001"].prev == "7000", "the companion asks who")
local slots = 0
for id, s in pairs(added) do
	if s.prev == "7001" and s.script_text then
		slots = slots + 1
		local n = s.script_text:match("dlg_slot_text%((%d)%)")
		check(n ~= nil and s.cond[1] == "coop_npc_companions.dlg_slot(" .. n .. ")"
			and s.act[1] == "coop_npc_companions.dlg_hand(" .. n .. ")", "slot " .. tostring(n) .. ": its text, condition and action")
	end
end
check(slots == 7, "a line per other player of a full session: " .. slots)
check(added["7002"] and added["7002"].prev == "7001" and #added["7002"].cond == 0,
	"an unconditional way out: the engine asserts on an empty list")
local X = load_script(H, "modxml_coop_companions")
local inserted = {}
local hooks = {}
H.env.RegisterScriptCallback = function(name, f) hooks[name] = f end
X.on_xml_read()
local xml = { query = function() return {} end, insertFromXMLString = function(self, s) inserted[#inserted + 1] = s end }
hooks.on_xml_read([[gameplay\dialogs.xml]], xml)
check(#inserted == 2 and inserted[1]:find('id="dm_coop_companion_take"', 1, true)
	and inserted[1]:find("coop_npc_companions.dlg_can_take", 1, true) and inserted[1]:find("coop_npc_companions.dlg_take", 1, true),
	"the take dialog goes into dialogs.xml")
check(inserted[2]:find('id="dm_coop_companion_hand"', 1, true) and inserted[2]:find("coop_npc_companions.dlg_can_hand", 1, true)
	and inserted[2]:find("<init_func>coop_npc_companions.dm_init_hand</init_func>", 1, true), "and the hand-over of a character with no list of commands")
hooks.on_xml_read([[gameplay\dialogs_bar.xml]], xml)
check(#inserted == 2, "only there")
local function char_list(has)
	local t = { added = {}, first = {} }
	t.has = function(self, d) return has[d] ~= nil end
	t.add = function(self, d) self.added[d] = true end
	t.add_first = function(self, d) self.first[d] = true end
	return t
end
local list = char_list({ dm_is_actor_companion_dialog = true })
hooks.on_specific_character_dialog_list("sim_default_stalker_0", list)
check(list.added.dm_coop_companion_take and not list.first.dm_coop_companion_hand and not list.added.dm_coop_companion_hand,
	"a character with the list of commands: take; the hand-over is a line of that list")
local list2 = char_list({ fanat_training_start = true })
hooks.on_specific_character_dialog_list("esc_2_12_stalker_fanat", list2)
check(list2.added.dm_coop_companion_take, "the Fanatic has no list of commands: take is a dialog of every character")
check(list2.first.dm_coop_companion_hand, "and the hand-over, the top line of the talk")
print("-- the hand-over of a character with no list of commands")
added = {}
W.CH.dm_init_hand(fake_dialog())
check(added["0"] and added["0"].prev == "" and added["0"].text == "st_coop_comp_cmd_hand" and added["0"].cond[1] == "coop_npc_companions.dlg_can_hand",
	"the first line, for the leader")
check(added["7001"] and added["7001"].prev == "0", "the companion asks who")
local top_slots = 0
for id, s in pairs(added) do
	if s.prev == "7001" and s.script_text then top_slots = top_slots + 1 end
end
check(top_slots == 7, "a line per other player of a full session")
check(added["7002"] and added["7002"].prev == "7001" and #added["7002"].cond == 0, "and the way out")
do
	local dead = { AddPhrase = function() error("no such phrase") end }
	check(pcall(W.CH.dm_init_hand, dead) == true, "an error here does not stop the game's dialog load")
end

print("== a leader who leaves: control passes to the host for the time, the save keeps it, he gets it back")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
W.refresh()
local proxy = W.proxy_a
H.objects[500] = nil -- take_offline: the character is out of the world
H.env.coop_npc_players.invalidate()
NOW = NOW + 1
H.beh_actor = nil
H.env.axr_beh.action_beh.execute({ object = W.comp })
check(H.beh_actor == 0, "while he is away it walks after the host")
check(W.CH.leader_of(W.comp) == nil, "and leader_of answers nobody")
check(L()[300] == 500, "his entry stays")
check(H.env.dialogs_axr_companion.is_actor_companion(H.env.db.actor, W.comp) == true, "the host commands it meanwhile")
W.refresh()
check(L()[300] == 500, "a refresh does not forget him")
local m = {}
H.fire("save_state", m)
check(m.coop_npc_leaders and m.coop_npc_leaders[300] == 500, "the save keeps the character")
H.objects[500] = proxy
H.env.coop_npc_players.invalidate()
NOW = NOW + 1
H.env.axr_beh.action_beh.execute({ object = W.comp })
check(H.beh_actor == 500, "he is back: it walks after him again")
H.objects[500] = nil
H.env.coop_npc_players.invalidate()
W.CB.dlg_take(B.env.db.actor, W.comp_b)
pump()
check(L()[300] == 501, "taken while he is away: the other player keeps it")
H.objects[500] = proxy
H.env.coop_npc_players.invalidate()
NOW = NOW + 1
H.env.axr_beh.action_beh.execute({ object = W.comp })
check(H.beh_actor == 501, "and it does not go back to the absent one")

print("== a loaded squad is false in companion_squads until its first update: it keeps its leader")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
H.env.axr_companions.companion_squads[300] = false
W.refresh()
check(L()[300] == 500, "the refresh does not take it for a dismissal")
check(W.comp_a:has_info("npcx_is_companion"), "its leader keeps the flags")

print("== save, load, level change")
local saved = {}
H.fire("save_state", saved)
local CH2 = load_script(H, "coop_npc_companions") -- a new Lua state after a load or a level change
H.callbacks = {}
CH2.on_game_start()
H.fire("load_state", saved)
check(CH2._leaders()[300] == 500, "the leader comes back from the save")
check(CH2.leader_of(W.comp):id() == 500, "with its character")

print("== a late joiner gets the right state")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 501
W.refresh()
-- the joiner's fresh Lua state: the world came from the host's save, so his copy still carries the save's flags
local fresh = load_script(A, "coop_npc_companions")
A.handlers = {}
A.callbacks = {}
A.env.coop_npc_players = load_script(A, "coop_npc_players")
fresh.on_game_start()
W.comp_a:give_info_portion("npcx_is_companion")
QUEUE = {}
check(fresh.dlg_can_take(A.env.db.actor, W.comp_a) == false, "before the host's word he knows nothing")
A.fire("actor_on_update")
check(#sent_named(A, "npc.comp_req") >= 1, "he asks the host")
pump()
check(fresh.dlg_can_take(A.env.db.actor, W.comp_a) == true, "the host's word: somebody else leads it")
check(W.comp_a:has_info("npcx_is_companion"), "the flags come with the host's word")
check(fresh.dlg_can_take(A.env.db.actor, W.comp2_a) == true, "a companion of the host is known too")
print("-- an NPC that is not here yet when the word comes")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
A.objects[201] = nil
L()[300] = 500
W.refresh()
check(W.CA.dlg_can_hand ~= nil, "(stand)")
A.objects[201] = W.comp_a
W.refresh()
check(W.comp_a:has_info("npcx_is_companion"), "the flags wait for the NPC and are applied when it comes online")

print("== the last word: a companion of nobody now")
W = stand()
H, A, B = W.H, W.A, W.B
check(W.CB.dlg_can_take(B.env.db.actor, W.comp_b) == true, "a companion of the host")
H.env.axr_companions.companion_squads[300] = nil
W.refresh()
check(W.CB.dlg_can_take(B.env.db.actor, W.comp_b) == false, "the host dismissed it: nothing to take")

print("== offline travel goes to the leader")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
W.refresh()
W.proxy_a.game_vertex_id = function() return 111 end
W.proxy_a.level_vertex_id = function() return 222 end
local cls = H.env.sim_squad_scripted.sim_squad_scripted
local sq = new_squad(300, 201)
local function task_of(id, assigned)
	local t = { id = id, assigned_target_id = assigned, get_current_task = cls.get_current_task }
	return cls.get_current_task(luabind_object(t))
end
local task = task_of(300, 0)
check(type(task) == "table" and task.gv == 111 and task.lv == 222, "assigned to 'the actor': the leader's vertices")
check(task_of(310, 0) == "stock task", "a squad of the host: stock")
check(task_of(300, 300) == "stock task", "Useful Idiots keeps an offline companion where it is: as for the host's")
check(task_of(300, 77) == "stock task", "a scripted target of its own: stock")
H.objects[500] = nil
H.env.coop_npc_players.invalidate()
check(task_of(300, 0) == "stock task", "the leader is out of the world: stock, the host")

print("== stock code that teleports a companion squad to the actor")
H.objects[500] = W.proxy_a
H.env.coop_npc_players.invalidate()
W.proxy_a._pos = vec(70, 0, 0)
H.env.db.actor._pos = vec(1, 0, 0)
H.env.TeleportSquad(W.squads[300], H.env.db.actor:position(), 1, 2)
check(H.teleported.pos.x == 70 and H.teleported.lvid == 222 and H.teleported.gvid == 111, "an offline spy goes to its leader")
H.env.TeleportSquad(W.squads[310], H.env.db.actor:position(), 1, 2)
check(H.teleported.pos.x == 1 and H.teleported.lvid == 1, "a squad of the host: to the host")
H.env.TeleportSquad(W.squads[300], vec(900, 0, 0), 3, 4)
check(H.teleported.pos.x == 900 and H.teleported.gvid == 4, "a place of its own (level change, a task's point): as asked")

print("== the host's keys, the wheel and the squad list are his own")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
W.refresh()
local ac = H.env.axr_companions
ac.cycle_state()
check(ac.cycled[310] and not ac.cycled[300], "a cycle key orders only the host's squads")
check(ac.companion_squads[300] ~= nil, "the table is back after the call")
local ids = ac.list_actor_squad_by_id()
check(#ids == 1 and ids[1] == 310, "the squad list shows the host's own")
ac.move_to_point(1)
check(H.moved == 1, "go-to goes through")
H.aimed = W.comp
check(ac.get_nearby_companion() == true, "the wheel does not pick a companion another player leads")
H.aimed = W.comp2
check(ac.get_nearby_companion():id() == 211, "it picks his own")
H.aimed = nil
H.aimed = nil
do
	local real = ac.companion_squads
	H.boom = true
	check(pcall(ac.cycle_state) == false, "(the stock call fails)")
	H.boom = nil
	check(ac.companion_squads == real, "the table is back after an error too")
end
print("== the same with no client's companion: stock")
W = stand()
H = W.H
H.env.axr_companions.cycle_state()
check(H.env.axr_companions.cycled[300] and H.env.axr_companions.cycled[310], "no leaders: every squad")

print("== Useful Idiots: formations and the panel per leader, surge for everybody")
local LOADED
local function idiots_env(M)
	LOADED = {}
	local NPC = {}
	function NPC.getCompanions()
		local list = {}
		for id, sq in pairs(M.env.axr_companions.companion_squads) do
			for k in sq:squad_members() do list[#list + 1] = M.objects[k.id] end
		end
		table.sort(list, function(a, b) return a:id() < b:id() end)
		return list
	end
	function NPC.getTargetCompanion() return M.aimed end
	function NPC.moveToPoint(npc, pos) M.go = M.go or {}; M.go[npc:id()] = pos end
	function NPC.setState(npc, g, a, v) M.state = { npc:id(), g, a, v } end
	local surge = {
		obfuscateCompanions = function() M.surge = #NPC.getCompanions() end,
		addCompanionStoryIds = function() M.surge2 = #NPC.getCompanions() end,
		removeCompanionStoryIds = function() M.surge3 = #NPC.getCompanions() end,
	}
	local ignore = { onEvalEnemy = function(npc, enemy, flags) M.eval_actor = M.env.db.actor:id() end }
	M.env.package = { loaded = { ["illish.lib.npc"] = NPC, ["illish.patches.surge_manager"] = surge,
		["illish.patches.xr_combat_ignore"] = ignore } }
	M.env.ui_mcm = {
		get = function(k)
			if k == "idiots/keybinds/point/move_key" then return 81 end
			return nil
		end,
		get_mod_key = function() return true end,
	}
	M.env.he_is_with_me = { escorteval = ignore.onEvalEnemy }
	M.env.idiots_combat_support = { action_combat_support = {
		execute = function(self) M.fight_actor = M.env.db.actor:id() end,
		initialize = function(self) M.fight_init = M.env.db.actor:id() end,
	} }
	M.npc_lib, M.surge_lib, M.ignore_lib = NPC, surge, ignore
end
W = stand({ env = idiots_env })
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
W.refresh()
local NPC = H.npc_lib
local function ids_of(list)
	local t = {}
	for _, o in ipairs(list) do t[#t + 1] = o:id() end
	return table.concat(t, ",")
end
check(ids_of(NPC.getCompanions()) == "211", "the host's panel and keys: his own")
check(H.env.coop_npc_players.with_identity(W.proxy_a, function() return ids_of(NPC.getCompanions()) end) == "201",
	"under the leader's identity (formations): the leader's followers")
check(H.env.coop_npc_players.with_identity(W.proxy_b, function() return ids_of(NPC.getCompanions()) end) == "",
	"a player without companions: nobody")
H.aimed = W.comp
check(NPC.getTargetCompanion() == nil, "the panel does not open on a companion another player leads")
H.aimed = W.comp2
check(NPC.getTargetCompanion():id() == 211, "it opens on his own")
H.surge_lib.obfuscateCompanions()
H.surge_lib.addCompanionStoryIds()
H.surge_lib.removeCompanionStoryIds()
check(H.surge == 2 and H.surge2 == 2 and H.surge3 == 2, "the surge code still sees every companion")
check(ids_of(NPC.getCompanions()) == "211", "and only for that call")
local action = H.env.idiots_combat_support.action_combat_support
action.execute({ object = W.comp })
action.initialize({ object = W.comp })
check(H.fight_actor == 500 and H.fight_init == 500, "Useful Idiots' combat keeps to the leader")
action.execute({ object = W.comp2 })
check(H.fight_actor == 0, "and for a companion of the host to the host")
H.ignore_lib.onEvalEnemy(W.comp, W.comp2, {})
check(H.eval_actor == 500, "who is an enemy: judged for the companion's leader")
H.ignore_lib.onEvalEnemy(W.comp2, W.comp, {})
check(H.eval_actor == 500, "also when the companion is the enemy in question")
H.env.he_is_with_me.escorteval(W.comp, W.comp2, {})
check(H.eval_actor == 500 and H.env.he_is_with_me.escorteval == H.ignore_lib.onEvalEnemy, "'He is with me' got the wrapped rule")

print("== go-to: a client's key, the host walks the squads he leads")
A.env.level.get_target_pos = function() return vec(40, 1, 2) end
A.fire("on_key_press", 5)
pump()
check(H.go == nil, "another key: nothing")
A.fire("on_key_press", 81)
pump()
check(H.go and H.go[201] and H.go[201].x == 40, "the companion he leads goes to the spot")
check(H.go[211] == nil, "a companion of the host does not")
check(ctext(A):find("st_move_to_point", 1, true) ~= nil, "the order is confirmed")
H.go = nil
B.env.level.get_target_pos = function() return vec(1, 1, 1) end
B.fire("on_key_press", 81)
pump()
check(H.go == nil, "a player without companions orders nobody")
A.env.coop_npc_players.send("npc.comp_go", { x = 0 / 0, y = 1, z = 1 }, 0)
pump()
check(H.go == nil, "nan: dropped")

print("== go-to without Useful Idiots: stock key, stock order")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
W.refresh()
H.env.level.vertex_id = function(pos) return 4242 end
H.env.db.storage[201] = { beh = {} }
A.env.level.get_target_pos = function() return vec(40, 1, 2) end
W.comp:give_info_portion("npcx_beh_wait")
A.fire("on_key_press", 33)
pump()
check(not W.comp:has_info("npcx_beh_wait"), "stock follow state")
check(H.env.db.storage[201].beh.rally_lvid == 4242, "the commander takes the rally point")
check(W.comp._pstor and W.comp._pstor.fight_from_point == 4242, "the fight point")

print("== inventory access: one backpack for the group")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
L()[300] = 500
H.env.axr_companions.assigned[201] = { [9001] = true, [9002] = true }
W.refresh()
local AA, AB = A.env.axr_companions, B.env.axr_companions
check(AA.is_assigned_item(201, 9001) == true, "the leader's machine knows what he may take back")
check(AB.is_assigned_item(201, 9001) == true, "and every other player's: one backpack")
check(AA.is_assigned_companion(A.env.db.actor, W.comp_a) == true, "the 'give me back' line shows")
W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
pump()
check(AB.is_assigned_item(201, 9002) == true, "the new leader gets the list with the control")
check(AA.is_assigned_item(201, 9002) == true, "the former leader keeps it")
L()[300] = 501
local item = make_obj(9100, 0, 0, 0)
A.add(item); B.add(item); H.add(item)
B.fire("ActorMenu_on_item_after_move", 201, item, "loot", 1)
pump()
check(H.env.axr_companions.assigned[201][9100] == true, "a client's item move: the host's table, the stock's save and weight")
check(AB.is_assigned_item(201, 9100) == true, "shown at once")
B.fire("ActorMenu_on_item_after_move", 201, item, "loot", 2)
pump()
check(H.env.axr_companions.assigned[201][9100] == nil, "and taken back")
check(not AB.is_assigned_item(201, 9100), "gone from the list")
A.fire("ActorMenu_on_item_after_move", 201, item, "loot", 1)
pump()
check(H.env.axr_companions.assigned[201][9100] == true, "not the leader: his gift goes in, one backpack")
check(AB.is_assigned_item(201, 9100) == true, "the other player sees it at once")
A.fire("ActorMenu_on_item_after_move", 201, item, "loot", 2)
pump()
check(H.env.axr_companions.assigned[201][9100] == nil, "and any player takes it out")
B.fire("ActorMenu_on_item_after_move", 201, item, "trade", 1)
pump()
check(H.env.axr_companions.assigned[201][9100] == nil, "a trade move is no gift")
W.CA.dlg_take(A.env.db.actor, W.comp_a)
pump()
check(AA.is_assigned_item(201, 9001) == true, "a leader who took it back has the list again, unchanged as it is")
W.CB.dlg_take(B.env.db.actor, W.comp_b)
pump()
print("-- the dialog's take-all on a client (stock transfer_item reads its own table)")
local moved = {}
W.comp_b.transfer_item = function(self, it, to) moved[#moved + 1] = it:id() end
B.add(make_obj(9001, 0, 0, 0))
H.add(make_obj(9001, 0, 0, 0))
AB.transfer_item(9001, W.comp_b, B.env.db.actor, true)
check(moved[1] == 9001, "an item of the list moves")
check(B.stock_transfer == nil, "without the stock's refusal")
pump()
check(H.env.axr_companions.assigned[201][9001] == nil, "the host's table follows")
B.add(make_obj(9500, 0, 0, 0))
AB.transfer_item(9500, W.comp_b, B.env.db.actor, true)
check(#moved == 1 and B.stock_transfer == 1, "an item off the list: the stock decides")

print("== a recruit whose squad Useful Idiots splits: every new squad follows the recruiter")
W = stand()
H, A, B = W.H, W.A, W.B
L = W.CH._leaders
H.env.axr_companions.companion_squads[300] = nil
H.env.axr_companions.companion_squads[310] = nil
W.squads[320] = new_squad(320, 221)
W.squads[321] = new_squad(321, 222)
local rec = H.add(make_obj(221, 7, 0, 0, { _name = "rec" }))
H.add(make_obj(222, 7, 0, 0, { _name = "rec2" }))
local rec_a = A.add(make_obj(221, 7, 0, 0, { _name = "rec" }))
H.split = { W.squads[320], W.squads[321] }
H.env.coop.talk_recent = function() return true end
A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, rec_a)
pump()
check(H.became and L()[320] == 500 and L()[321] == 500, "both split squads")

print("== split levels: an order to a companion on a map server's level, a leader who left it")
do
	local W = stand()
	local H, A = W.H, W.A
	local sent = {}
	local real = H.env.coop.send_event
	H.env.coop.send_event = function(name, payload, target)
		if type(target) == "number" and target >= 0x100 then
			sent[#sent + 1] = { name = name, t = H.env.coop_npc_players.decode(payload), to = target }
			return true
		end
		return real(name, payload, target)
	end
	local level_of = { [1] = 1, [2] = 1 }
	H.env.level.name = function() return "l01_escape" end
	H.env.coop.levels = {
		split = function() return true end,
		bridge_of_player = function(peer) return level_of[peer] == 2 and 0x101 or nil end,
		level_of_player = function(peer) return level_of[peer] end,
		level_name = function(id) return id == 2 and "l02_garbage" or "l01_escape" end,
		online_at_server = function(id) return false end,
		map_servers = function() return { { bridge = 0x101, level = 2 } } end,
	}
	W.CH._leaders()[300] = 500
	W.refresh()
	local bodies = { [500] = { position = "there", m_level_vertex_id = 7, m_game_vertex_id = 9 } }
	local plain = H.env.alife_object
	H.env.alife_object = function(id) return bodies[id] or plain(id) end

	level_of[1] = 2
	H.env.coop_npc_players.send("npc.comp_go", { x = 1 }, 0)
	H.env.coop_npc_players.invalidate()
	W.CH._follow_tick()
	check(H.teleported and H.teleported.id == 300 and H.teleported.gvid == 9, "his squad is teleported to where he stands")
	check(W.CH._leaders()[300] == nil and H.env.axr_companions.companion_squads[300] == nil, "it is no companion of this level any more")
	local adopt = sent[#sent]
	check(adopt and adopt.name == "npc.comp_adopt" and adopt.to == 0x101 and adopt.t.s == 300 and adopt.t.l == 500,
		"the authority of his level takes it")

	-- a player of that level asks: the world server passes it on, whoever he is there
	sent = {}
	H.event = H.event or nil
	A.env.coop_npc_players.send("npc.comp_req", {}, 0)
	pump()
	local passed = sent[#sent]
	check(passed and passed.name == "npc.comp_req" and passed.to == 0x101 and passed.t._peer == 1, "the world server passes a request on with his peer")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
