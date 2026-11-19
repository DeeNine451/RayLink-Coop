-- G10-1: real PDA adapter, routing facade and entity store, with stock-shaped UI stubs.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local ITEM, LOCAL_ITEM = 420, 1420
local OTHER_ITEM = 421
local SECTION = "itm_pda_common"
local ARTICLE = "encyclopedia_devices_"
local NOTE = "encyclopedia__notes_"
local ENTRY_COUNT = 520 -- more than the engine can queue as individual events in one frame
local CLIENT = 1
local BRIDGE_A, BRIDGE_B = 0x101, 0x102

local function info(owner, text)
	return { state = "default", contact = { name = owner }, msg = {
		{ topic_title = "first" }, { topic_title = text },
	} }
end

local function install_npc_tab(M)
	local e = M.env
	local list = { items = {} }
	function list:GetSelectedItem() return self.items[self.selection] end
	function list:SetSelectedIndex(index) self.selection = index + 1 end
	local tab = { message_list = list }
	function tab:Reset(value)
		self.info, self.msg, self.detail = value, value and value.msg, nil
		M.resets = (M.resets or 0) + 1
		list.items, list.selection = {}, nil
		for i, msg in ipairs(value and value.msg or {}) do
			list.items[i] = { indx = i, title = msg.topic_title }
		end
	end
	function tab:OnSelectMessage()
		local item = list:GetSelectedItem()
		self.detail = item and self.info.msg[item.indx].topic_title
	end
	e.ActorMenu = { get_pda_menu = function()
		return {
			IsShown = function() return M.shown end,
			GetActiveSection = function() return M.section end,
		}
	end }
	M.actor.active_item = function() return M.active_item end
	M.actor.item_in_slot = function() return M.slotted_item end
	e.item_device = { device_npc_pda = { [SECTION] = true } }
	e.ui_pda_npc_tab = {
		pda_npc_tab = tab,
		get_ui = function(value) tab:Reset(value) return tab end,
		use_view = function(item)
			M.shown, M.section, M.slotted_item = true, "eptNPC", item
			return e.ui_pda_npc_tab.get_ui(e.se_load_var(item:id(), item:name(), "info"))
		end,
		register_pda = function(_, _, id) e.se_save_var(id, nil, "info", M.generated) end,
	}
	return tab
end

local function install_encyclopedia(M)
	local locked_articles, locked_notes = {}, {}
	local articles, notes = {}, {}
	for i = 1, ENTRY_COUNT do
		locked_articles[ARTICLE .. i], locked_notes[NOTE .. i] = true, true
	end
	local function count(list)
		local n = 0
		for _ in pairs(list) do n = n + 1 end
		return n
	end
	local function open(locked, unlocked, s)
		if not locked[s] then return false end
		locked[s], unlocked[s] = nil, true
		return true
	end
	local function open_all(locked, unlocked)
		local n = count(locked)
		for s in pairs(locked) do open(locked, unlocked, s) end
		return n > 0 and n or false
	end
	local enc = {
		get_articles_locked_count = function() return count(locked_articles) end,
		get_notes_locked_count = function() return count(locked_notes) end,
		is_unlocked_article = function(s) return articles[s] == true and not locked_articles[s] end,
		is_unlocked_note = function(s) return notes[s] == true and not locked_notes[s] end,
		unlock_article = function(s) return open(locked_articles, articles, s) end,
		unlock_note = function(s) return open(locked_notes, notes, s) end,
		unlock_all_articles = function() return open_all(locked_articles, articles) end,
		unlock_all_notes = function() return open_all(locked_notes, notes) end,
	}
	M.env.ui_pda_encyclopedia_tab = enc
	return enc
end

local function prepare(M, mode, overrides)
	local e = M.env
	M.players = { { id = 0, nick = "Host", is_self = M.self_peer == 0 },
		{ id = CLIENT, nick = "Reader", is_self = M.self_peer == CLIENT },
		{ id = 2, nick = "Observer", is_self = M.self_peer == 2 } }
	e.coop.is_map_server = function() return M.self_peer >= BRIDGE_A end
	e.coop.is_dedicated = function() return mode == "srv_world" end
	local mirror = M.role == "client" and M.self_peer < BRIDGE_A
	if mirror then
		overrides = {
			decides_world = function() return false end, leads_here = function() return false end,
			actor_is_player = function() return true end, is_player_mirror = function() return true end,
		}
		e.coop.to_host_id = function(id) return id == LOCAL_ITEM and ITEM or id end
		e.coop.to_local_id = function(id) return id == ITEM and LOCAL_ITEM or id end
	elseif mode == "srv_map" then
		local map = setfenv(assert(loadfile("tests/lua/support/mode_srv_map.lua")), e)()
		overrides = { level_request = map.level_request }
	end
	modes.install(load_script(M, "coop_mode"), mode, overrides)
	local alife_object = e.alife_object
	e.alife_object = function(id)
		local se = alife_object(id)
		if se then se.name = function() return se._o:name() end end
		return se
	end
	local state = { se_object = M.se_vars }
	e.alife_storage_manager = { get_state = function() return state end }
	if mirror then
		load_script(M, "coop_economy_core")
		load_script(M, "coop_economy_mdata").on_game_start()
		e.coop_economy_mdata.on_se_value(function(id, key)
			if id == LOCAL_ITEM and key == "info" then M.applied = (M.applied or 0) + 1 end
		end)
	end
	load_script(M, "coop_quests_core")
	load_script(M, "coop_mods_core")
	load_script(M, "coop_trust")
	M.tab = install_npc_tab(M)
	M.ency = install_encyclopedia(M)
	load_script(M, "coop_quests_pda").on_game_start()
	fire(M, "actor_on_first_update")
end

-- The engine relays a map server's messages to a player as peer zero.
local function bridge(bridge_peer, player)
	local map = machine("client", bridge_peer)
	local send = map.env.coop.send_event
	map.env.coop.send_event = function(name, payload, target)
		local before = #QUEUE
		local sent = send(name, payload, target)
		for i = #QUEUE, before + 1, -1 do
			local event = QUEUE[i]
			if event.to.self_peer < BRIDGE_A and event.to.self_peer ~= 0 then
				if (target == -1 or target == nil) and player and event.to.self_peer ~= player then
					table.remove(QUEUE, i)
				else
					event.from = 0
				end
			end
		end
		return sent
	end
	prepare(map, "srv_map")
	return map
end

local function multiplayer(set)
	QUEUE, MACHINES = {}, {}
	local host = machine("host", 0)
	local reader, observer = machine("client", CLIENT), machine("client", 2)
	local owner = host
	local split = set == "srv_world"
	if set ~= "hostplay" then
		local route = setfenv(assert(loadfile("tests/lua/support/mode_srv_world.lua")), host.env)().level_request
		prepare(host, "srv_world", { level_request = function(name, body, from)
			local action, target, payload, relayed = route(name, body, from)
			if split and action == "pass" and from == 2 then target = BRIDGE_B end
			return action, target, payload, relayed
		end })
		owner = bridge(BRIDGE_A, split and CLIENT or nil)
		if split then bridge(BRIDGE_B, 2) end
	else
		prepare(host, "hostplay")
	end
	prepare(reader, set == "hostplay" and "hostplay" or "srv_map")
	prepare(observer, set == "hostplay" and "hostplay" or "srv_map")
	local label = set == "hostplay" and "Co-op" or split and "Server, two maps" or "Server, one map"

	local npc = owner.new_obj(430, "stalker", nil, { _dead = true })
	owner.new_obj(ITEM, SECTION)
	owner.generated = info("Dead NPC", "second")
	owner.env.ui_pda_npc_tab.register_pda(npc, SECTION, ITEM)
	-- Model a client that missed the registration broadcast and asks when it opens the PDA.
	QUEUE = {}
	tick(reader) -- let the entity store observe its initial state before exercising the queue
	local item = reader.new_obj(LOCAL_ITEM, SECTION, nil, { _parent = reader.actor })
	reader.generated = info("Client-side roll", "wrong")
	reader.env.ui_pda_npc_tab.register_pda(npc, SECTION, LOCAL_ITEM)
	check(reader.env.se_load_var(LOCAL_ITEM, nil, "info") == nil, label .. " — client does not roll NPC messages")
	local tab = reader.env.ui_pda_npc_tab.use_view(item)
	check(tab.info and #tab.info.msg == 0, label .. " — shows placeholder before the answer")
	tick(reader)
	check(count_sent(reader, "economy.se") == 0, label .. " — opening a PDA emits no entity write")

	local request
	for _, sent in ipairs(reader.sent) do
		if sent.name == "quests.pda_req" or sent.name == "mods.pda_req" then request = sent break end
	end
	local wire = request and H.decode(request.payload)
	check(wire and wire.i == ITEM and request.target == 0, label .. " — uses host numbering for the request")
	pump()
	local stored = reader.env.se_load_var(LOCAL_ITEM, nil, "info")
	check(stored and stored.contact.name == "Dead NPC", label .. " — gets the dead NPC PDA from the level authority")
	check(tab.info and tab.info.contact.name == "Dead NPC", label .. " — refreshes the open placeholder in place")
	tick(reader)
	check(reader.applied == 1 and count_sent(reader, "economy.se") == 0,
		label .. " — applies the reply once without echo")
	check(observer.env.se_load_var(LOCAL_ITEM, nil, "info") == nil, label .. " — reply only goes to the requester")
	local replies = #owner.sent
	reader.env.coop.send_event("mods.pda_req", H.encode({ i = 65535 }), 0)
	pump()
	check(#owner.sent == replies and has_log(owner, "pda_req_id"),
		label .. " — out-of-range request reaches trust and cannot look up an entity")

	-- The existing unsolicited channel uses the same apply and refresh path.
	local receive = reader.handlers["quests.pda"]
	local function pda_update(host_id, value)
		local body = reader.env.coop_quests_core.ser(value)
		local packet = H.encode({ i = host_id, d = body })
		receive(packet, 0)
		return packet
	end
	reader.env.ui_pda_npc_tab.use_view(item)
	tab.message_list:SetSelectedIndex(1)
	tab:OnSelectMessage()
	local updated = pda_update(ITEM, info("Dead NPC", "updated second"))
	check(tab.message_list:GetSelectedItem() and tab.message_list:GetSelectedItem().indx == 2
		and tab.detail == "updated second", label .. " — keeps the selected message when the open list is rebuilt")
	local resets, applied = reader.resets, reader.applied
	receive(updated, 0)
	check(reader.resets == resets and reader.applied == applied, label .. " — repeated data does not reapply or redraw")
	pda_update(OTHER_ITEM, info("Other NPC", "other"))
	check(reader.resets == resets, label .. " — ignores other PDAs for the open view")
	local other_item = reader.new_obj(OTHER_ITEM, SECTION, nil, { _parent = reader.actor })
	local request_count = count_sent(reader, "mods.pda_req")
	reader.env.ui_pda_npc_tab.use_view(other_item)
	check(tab.info.contact.name == "Other NPC" and count_sent(reader, "mods.pda_req") == request_count,
		label .. " — uses the cached answer when the PDA entity spawns later")
	reader.env.ui_pda_npc_tab.use_view(item)
	resets = reader.resets
	reader.shown = false
	pda_update(ITEM, info("Dead NPC", "closed"))
	check(reader.resets == resets, label .. " — closed PDA does not redraw")

	-- A stored item with a large contents packet still uses the normal requester-only route.
	local large_title = string.rep("long;=", 12000)
	owner.env.se_save_var(ITEM, nil, "info", info("Dead NPC", large_title))
	reader.env.coop.send_event("mods.pda_req", H.encode({ i = ITEM }), 0)
	pump()
	stored = reader.env.se_load_var(LOCAL_ITEM, nil, "info")
	check(stored.msg[2].topic_title == large_title and count_sent(owner, "mods.pda_big") > 1,
		label .. " — oversized reply is chunked, reassembled and applied")

	local forged = H.encode({ k = "article", d = reader.env.coop_quests_core.ser({ ARTICLE .. 1 }) })
	reader.env.coop.send_event("quests.ency", forged, 0)
	pump()
	check(host.ency.get_articles_locked_count() == ENTRY_COUNT and has_log(host, "pda_ency_section"),
		label .. " — a client's forged batch reaches trust and cannot unlock world entries")
	check(host.ency.unlock_all_articles() == ENTRY_COUNT, label .. " — mass articles keeps the original count")
	check(host.ency.unlock_all_notes() == ENTRY_COUNT, label .. " — mass notes keeps the original count")
	pump()
	check(reader.ency.get_articles_locked_count() == 0 and observer.ency.is_unlocked_article(ARTICLE .. ENTRY_COUNT),
		label .. " — mass articles clear locks for connected clients")
	check(reader.ency.get_notes_locked_count() == 0 and observer.ency.is_unlocked_note(NOTE .. ENTRY_COUNT),
		label .. " — mass notes clear locks for connected clients")
	local packets = count_sent(host, "quests.ency")
	local bounded = true
	for _, sent in ipairs(host.sent) do
		if sent.name == "quests.ency" and #sent.payload >= 15000 then bounded = false end
	end
	check(packets > 0 and packets < 512 and bounded, label .. " — mass unlock fits the event queue and payload limit")
	check(host.ency.unlock_all_articles() == false and count_sent(host, "quests.ency") == packets,
		label .. " — already-open mass unlock sends nothing")
end

for _, set in ipairs(modes.names()) do
	if set == "none" then
		local solo = machine("host", 0)
		solo.active = false
		prepare(solo, set)
		local item = solo.new_obj(ITEM, SECTION)
		local value = info("Stock owner", "unchanged")
		solo.env.se_save_var(ITEM, nil, "info", value)
		check(solo.env.ui_pda_npc_tab.use_view(item).info == value and solo.resets == 1,
			"Single player — stock PDA view and return value")
		check(solo.ency.unlock_all_articles() == ENTRY_COUNT and solo.ency.unlock_all_notes() == ENTRY_COUNT,
			"Single player — stock mass unlocks and return values")
		check(#solo.sent == 0, "Single player — no network events")
	else
		multiplayer(set)
	end
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
