-- Dev 57 G4-7: the stock container entry point, the real exchange dispatcher and the local open timer.
local modes = dofile("tests/lua/support/modes.lua")
local role = modes.names()[1]
MODE = role == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local BOX, ITEM = "hidden_box", "artefact_container"
local KIND, LINK = "stock_box", "coop_stock_container_item"
INI[ITEM] = { use1_functor = "bind_container.access_inventory", script_binding = "bind_container.bind" }
local actor = make_actor(vec3(20, 0, 0))
local _, remote = spawn("coop_player_avatar", vec3(24, 0, 0), nil, { id = 500 })
local remote_here = true
coop.world_epoch = function() return 7 end
coop.is_map_server = function() return role == "srv_map" and MODE == "host" end
coop.is_dedicated = function() return role == "srv_world" end
if role == "srv_map" then
	coop.is_host = function() return false end
	coop.is_client = function() return true end
end

load_script("coop_main")
load_script("coop_mode")
local function install_mode(overrides)
	modes.install(coop_mode, role, overrides)
end
install_mode({ where = function(peer)
	if role == "srv_world" or peer == 1 and not remote_here then return "away" end
	return "here"
end })

local original_opens = 0
bind_container = {
	containers = {},
	access_inventory = function(obj, tag)
		original_opens = original_opens + 1
		return obj, tag
	end,
}
local original_jupiter = function() return "jupiter" end
local original_zaton = function() return "zaton" end
dialogs_jupiter = { jupiter_b200_tech_materials_relocate = original_jupiter }
dialogs_zaton = {
	zat_b33_counter_de_2 = original_zaton, zat_b33_counter_de_4 = original_zaton,
	zat_b33_counter_de_8 = original_zaton,
}

local m = alife_storage_manager.get_state()
m.se_object = {}
function se_save_var(id, _, key, value)
	m.se_object[id] = m.se_object[id] or {}
	m.se_object[id][key] = value
end
function se_load_var(id, _, key)
	return m.se_object[id] and m.se_object[id][key]
end

local graph_vertex = getmetatable(actor).__index.game_vertex_id
local graph_of = {}
getmetatable(actor).__index.game_vertex_id = function(self)
	return graph_of[self:id()] or graph_vertex(self)
end
function game_graph()
	return {
		valid_vertex_id = function(_, id) return id == 8 or id == 9 end,
		vertex = function(_, id) return { level_id = function() return id end } end,
	}
end
local moves, show = 0, 0
function hide_hud_inventory() show = show + 1 end
local sim = alife()
function alife() return sim end
function sim:set_switch_online() end
function sim:set_switch_offline() end
function sim:teleport_object(id, gv, lv, pos)
	moves = moves + 1
	SE[id].m_game_vertex_id, SE[id].m_level_vertex_id = gv, lv
	SE[id].position = vector():set(pos)
	if OBJ[id] then OBJ[id]._pos = vector():set(pos) end
end
local create = alife_create
function alife_create(section, pos, lv, gv, parent)
	local result = create(section, pos, lv, gv, parent)
	result.m_game_vertex_id, result.m_level_vertex_id = gv, lv
	return result
end

local entity_methods = getmetatable(SE[actor:id()]).__index
function entity_methods:name() return self._sec .. self.id end
if role == "srv_map" or role == "srv_world" then
	load_script("coop_economy_mdata").on_game_start()
end

local X = load_script("coop_mods_xchg")
X.on_game_start()
load_script("coop_mods_xchg_stock").on_game_start()
coop_trust.reset_for_test({ default = "refuse" })

local function item(owner, section)
	local se, obj = spawn(section or ITEM, owner:position(), owner:id())
	bind_container.containers[se.id] = {}
	return se.id, obj
end
local function box_at(owner)
	local se = spawn(BOX, owner:position())
	return se.id
end
local seq = 0
local function request(id, extra)
	seq = seq + 1
	local t = { o = "1:7:" .. seq, k = KIND, i = id }
	for k, v in pairs(extra or {}) do t[k] = v end
	if role == "srv_map" then t._peer = 1 end
	local packet = coop_main.encode(t)
	local function deliver_again()
		coop_main.on_event("mods.xchg", packet, role == "srv_map" and 0 or 1)
		local msg = sent("mods.xchg_r")
		return msg and msg.o == t.o and msg or {}
	end
	return deliver_again(), deliver_again
end
local function box_id(reply)
	return reply.ok == true and reply["r.b"] or nil
end

if role == "hostplay" or role == "srv_map" then
	local id = item(remote)
	local first, retry = request(id)
	local b = box_id(first)
	check(b and alife_object(b):section_name() == BOX and #CREATED == 1, "owned container creates one authoritative box")
	if role == "srv_map" then
		SendScriptCallback("actor_on_update")
		local data, msg = sent("economy.se")
		check(data and data.i1 == b and data.k1 == LINK and coop_economy_core.unpack(data.d1) == id and msg.target == 0,
			"the map server sends the confirmed link to the world owner through economy.se")
	end
	local replay = retry()
	local newer = request(id)
	check(b and box_id(replay) == b and box_id(newer) == b and #CREATED == 1, "replayed and fresh requests reuse the same box")
	-- A fresh Lua module and empty stock binder table model a reload with the persisted entity store still present.
	load_script("coop_mods_xchg_stock").on_game_start()
	bind_container.containers[id] = nil
	local restored = request(id)
	check(b and box_id(restored) == b and #CREATED == 1, "reload restores the existing box even without the stock binder cache")

	local other, other_obj = item(actor)
	local denied = request(other)
	check(denied.ok == false and denied.why == "stock_box_owner" and #CREATED == 1, "transport sender cannot ask for another player's item")
	local fake = box_at(remote)
	local new_item = item(remote)
	local forged = request(new_item, { b = fake })
	check(box_id(forged) ~= nil and box_id(forged) ~= fake, "client-supplied box id cannot select someone else's box")
	local bad_item = item(remote, "bread")
	check(request(bad_item).why == "stock_box_section" and request(65535).why == "stock_box_owner", "section and wire id are checked")

	local legacy = item(remote)
	local old_box = box_at(remote)
	bind_container.containers[legacy].id = old_box
	check(box_id(request(legacy)) == old_box and se_load_var(old_box, nil, LINK) == legacy,
		"the authority adopts a legacy binder link")
	local invalid = item(remote)
	bind_container.containers[invalid].id = old_box
	check(request(invalid).why == "stock_box_link", "an existing link cannot be reassigned through a legacy pointer")
	local unstored = item(remote)
	local save = se_save_var
	se_save_var = function() end
	local rejected = request(unstored)
	se_save_var = save
	local thrown_away = CREATED[#CREATED]
	check(rejected.why == "stock_box_save" and thrown_away and alife_object(thrown_away.id) == nil
		and bind_container.containers[unstored].id == nil, "an unconfirmed link releases the new empty box")
	local store = m.se_object
	m.se_object = false
	local before = #CREATED
	check(request(unstored).why == "stock_box_save" and #CREATED == before, "a missing entity store refuses before spawning")
	m.se_object = store

	if role == "hostplay" then
		check(b and se_load_var(b, nil, LINK) == id, "the host retains the link in the saved entity store")
		local content = b and spawn("bread", remote:position(), b)
		graph_of[remote:id()] = 9
		local moved = request(id)
		check(box_id(moved) == b and b and SE[b].m_game_vertex_id == 9 and content and content.parent_id == b and moves == 1,
			"co-op level change moves the same box and retains its children")
		local before = sent_count("mods.xchg")
		bind_container.access_inventory(other_obj)
		check(show == 0 and sent_count("mods.xchg") == before, "playing host uses the decider directly and waits for its timer")
		run_time_events(0)
		local local_box = bind_container.containers[other].id
		check(show == 1 and local_box and OBJ[local_box]._used_by == actor, "the host player opens the acknowledged local box")
	else
		check(b and se_load_var(b, nil, LINK) == id, "the map authority saves the link through the server entity store")
		local content = b and spawn("bread", remote:position(), b)
		graph_of[remote:id()] = 9
		local before = #CREATED
		local away = request(id)
		check(away.why == "stock_box_away" and #CREATED == before and content and content.parent_id == b and moves == 0,
			"another map leaves a remote box and its contents intact when handoff is unavailable")
		remote_here = false
		check(request(id).why == "stock_box_owner", "the previous map refuses a player whose body is no longer there")
	end
elseif role == "srv_world" then
	local id = item(remote)
	request(id)
	local forwarded, message = sent("mods.xchg")
	check(forwarded and forwarded._peer == 1 and message.target == 0x101 and #CREATED == 0,
		"the world server forwards the request and never spawns a box on its own map")
	local b = box_at(remote)
	local record = coop_main.encode({ n = 1, i1 = b, k1 = LINK, d1 = coop_economy_core.pack(id), x1 = SE[b]:name() })
	coop_main.on_event("economy.se", record, 1)
	check(se_load_var(b, nil, LINK) == nil, "the world server rejects a player trying to write a ground box's association")
	coop_main.on_event("economy.se", record, 0x101)
	check(se_load_var(b, nil, LINK) == id, "the world server saves the association reported by the map authority")
else
	local _, sp_item = item(actor)
	local a, b = bind_container.access_inventory(sp_item, "unchanged")
	check(a == sp_item and b == "unchanged" and original_opens == 1 and #SENT == 0, "single player delegates unchanged")
end

if role == "hostplay" then
	-- A player's mirror receives no Lua game object for the box until after the exchange answer.
	MODE, SELF = "client", 1
	install_mode({ actor_is_player = function() return true end, leads_here = function() return false end })
	local id, obj = item(actor)
	local hidden, online = spawn(BOX, actor:position())
	OBJ[hidden.id] = nil
	local previous_show = show
	bind_container.access_inventory(obj)
	bind_container.access_inventory(obj)
	local asked = sent("mods.xchg")
	check(asked and asked.k == KIND and asked.i == id and sent_count("mods.xchg") == 1, "mirror sends one request on a double click")
	if asked then
		local accepted = coop_main.encode({ o = asked.o, ok = true, ["r.b"] = hidden.id })
		coop_main.on_event("mods.xchg_r", accepted, 2)
		run_time_events(0)
		check(show == previous_show and next(TIMEEV) == nil, "a non-authority reply cannot enqueue a local open")
		coop_main.on_event("mods.xchg_r", accepted, 0)
		run_time_events(0)
		check(show == previous_show, "a confirmed box waits for local replication")
		OBJ[hidden.id] = online
		run_time_events(0)
		check(show == previous_show + 1 and online._used_by == actor and bind_container.curBoxID == id,
			"local timer opens the replicated box for the requesting player")
		coop_main.on_event("mods.xchg_r", accepted, 0)
		run_time_events(0)
		check(show == previous_show + 1, "replayed answer does not reopen the box")
	end
end

-- s35:4 is dormant in the checked GAMMA build. Merely loading these modules must not install a counter adapter.
check(dialogs_jupiter.jupiter_b200_tech_materials_relocate == original_jupiter
	and dialogs_zaton.zat_b33_counter_de_2 == original_zaton and dialogs_zaton.zat_b33_counter_de_4 == original_zaton
	and dialogs_zaton.zat_b33_counter_de_8 == original_zaton
	and sent_count("mods.stock_counter") == 0, "dormant Jupiter and Zaton dialogs are untouched")

done("mods_xchg_stock " .. role)
