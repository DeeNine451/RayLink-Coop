-- G5-1 exercises the HF UI entry points and the real mods event routing.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local actor = make_actor(vec3(0, 0, 0))
local _, player = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
local data, wrappers, spots = {}, {}, {}
local hidden, stock_calls, physics, saves = 0, 0, 0, 0
INI.hf_box = { placeable_type = "stash", item_section = "hf_box_item" }
INI.hf_box_item = { placeable_section = "hf_box" }
INI.hf_prop = { placeable_type = "prop" }
INI.hf_lamp = { placeable_type = "light", fuel_section = "charcoal" }
INI.charcoal = {}
function IsItem() return false end
utils_item = { discharge = function(obj) alife_release_id(obj:id()) end }
function hide_hud_inventory() hidden = hidden + 1 end
function level.map_remove_object_spot(id, spot) spots[id] = nil end
function level.map_add_object_spot_ser(id, spot, label) spots[id] = spot end

hf_obj_manager = {
	get_data = function(id) return data[id] end,
	update_data = function(id, values)
		data[id] = data[id] or {}
		for k, v in pairs(values) do data[id][k] = v end
	end,
	delete_data = function(id) data[id] = nil end,
}
local base = {}
function base:set_frozen(value)
	physics = physics + 1
	self.is_frozen = value
end
bind_hf_base = {
	hf_binder_wrapper = base,
	get_wrapper = function(id) return wrappers[id] end,
	freeze_obj = function(id) wrappers[id]:set_frozen(true); return true end,
}
local radial_target
placeable_furniture = {
	RadialGUI = { IsShown = function() return radial_target ~= nil end },
	get_wrapper_at_crosshair = function() return radial_target end,
	update_radial_gui = function(w) w.menu_frozen = w.is_frozen end,
}
-- LuaBind copies inherited members when it declares a subclass.
local light_class = { set_frozen = base.set_frozen }
function light_class:update(delta)
	local d = hf_obj_manager.get_data(self.object:id())
	self.lit = d.is_on and self.fuel > 0
	if d.is_on and not self.infinite_fuel then self.fuel = self.fuel - delta end
	self:save_data()
end
function light_class:save_data()
	saves = saves + 1
	hf_obj_manager.update_data(self.object:id(), { condition = self.fuel })
end
bind_light_furniture = { placeable_light_wrapper = light_class }
ui_furniture_light = { UIFurnitureLight = { Refuel = function(self)
	stock_calls = stock_calls + 1
	wrappers[self.light_id].fuel = 1
end } }

-- Same stock entry point as the merged HF script, including the separate give and release on an empty bag.
ui_inventory = { UIInventory = { LMode_TakeAll = function(self)
	stock_calls = stock_calls + 1
	local box = self:GetPartner()
	local bag = self.CC.npc_bag
	if next(bag.indx_id) then
		self.transferred = true
	elseif box:section() == "hf_box" and box:is_inv_box_empty() then
		local book = alife_storage_manager.get_state().player_created_stashes
		alife_release_id(box:id())
		if book[box:id()] then
			alife_create_item(book[box:id()], db.actor)
			book[box:id()] = nil
		end
	end
end } }
hf_monkeypatches = {}
-- Reuse the existing world-side stash book receiver (registered when the backpack mod is present).
item_backpack = { actor_on_item_use = function() end, actor_on_item_take_from_box = function() end }

local function make_box(pos, id)
	local _, obj = spawn("hf_box", pos, nil, { id = id, kind = "box" })
	local book = alife_storage_manager.get_state().player_created_stashes
	book[obj:id()] = "hf_box_item"
	spots[obj:id()] = "treasure"
	return obj
end

local function take_all(box, items)
	local ui = { GetPartner = function() return box end, CC = { npc_bag = { indx_id = items or {} } } }
	ui_inventory.UIInventory.LMode_TakeAll(ui)
	return ui
end

local function make_wrapper(section, pos, id, cls, fields)
	local _, obj = spawn(section, pos, nil, { id = id })
	local w = setmetatable(fields or {}, { __index = cls })
	w.object = obj
	wrappers[obj:id()] = w
	return w, obj:id()
end

local function event(verb, t, from)
	coop_main.on_event("mods." .. verb, coop_main.encode(t), from)
end

local function request(verb, t)
	NOW = NOW + 1000
	if name == "srv_map" then t._peer = 1 end
	event(verb, t, name == "srv_map" and 0 or 1)
end

local function takeall_result(id, parent, first)
	local gives = 0
	for i = first, #CREATED do
		local item = CREATED[i]
		if item.sec == "hf_box_item" and item.parent == parent then gives = gives + 1 end
	end
	return gives == 1 and SE[id] == nil and alife_storage_manager.get_state().player_created_stashes[id] == nil
end

start_all()
local mode_set = modes.install(coop_mode, name)
local book = {}
alife_storage_manager.get_state().player_created_stashes = book
local box = make_box(player:position())
local furniture, prop = make_wrapper("hf_prop", player:position(), nil, base, { is_frozen = true })
data[prop] = {}
local lamp, lamp_id = make_wrapper("hf_lamp", player:position(), nil, light_class, { fuel = 0.25 })
data[lamp_id] = { is_on = true, condition = 0.25 }

if name == "none" then
	local first = #CREATED + 1
	take_all(box)
	check(stock_calls == 1 and takeall_result(box:id(), actor:id(), first), "single player TakeAll uses the original")
	furniture:set_frozen(false)
	check(physics == 1 and furniture.is_frozen == false and data[prop].is_frozen == nil, "single player freeze uses stock physics")
	ui_furniture_light.UIFurnitureLight.Refuel({ light_id = lamp_id })
	lamp:update(0.1)
	check(stock_calls == 2 and saves == 1 and lamp.fuel == 0.9, "single player lamp spends and saves through stock")
	check(#SENT == 0, "single player sends no HF events")
elseif name == "srv_world" then
	coop.levels = { map_servers = function() return { { bridge = mode_set.bridge } } end }
	local first = #CREATED
	request("hf_takeall", { o = box:id(), _peer = 7 })
	local t, outgoing = sent("mods.hf_takeall")
	check(t and t._peer == 1 and outgoing.target == mode_set.bridge and SE[box:id()] and #CREATED == first,
		"world routes TakeAll by the transport sender without packing on its own map")
	event("stash_book", { b = box:id(), x = true }, mode_set.bridge)
	check(book[box:id()] == nil and spots[box:id()] == nil, "world forgets the packed stash in the shared registry")
	event("hf_data", { o = lamp_id, d = coop_mods_core.ser({ condition = 1, is_on = true }) }, mode_set.bridge)
	local state, broadcast = sent("mods.hf_data")
	check(state and broadcast.target == -1 and data[lamp_id].condition == 1,
		"world accepts map lamp state and distributes it to observers")
else
	if name == "srv_map" then
		coop.is_host = function() return false end
		coop.is_map_server = function() return true end
	end
	coop_trust.reset_for_test({ default = "refuse" })
	local first = #CREATED + 1
	local busy = make_box(player:position())
	spawn("charcoal", player:position(), busy:id())
	local far = make_box(vec3(100, 0, 0))
	local _, other = spawn("ordinary_box", player:position(), nil, { kind = "box" })
	book[other:id()] = "hf_box_item"
	request("hf_takeall", { o = busy:id() })
	request("hf_takeall", { o = far:id() })
	request("hf_takeall", { o = other:id() })
	request("hf_takeall", { o = 65535 })
	local counters = coop_trust.status()
	local refused = 0
	for _, counter in pairs(counters) do refused = refused + counter.refused end
	check(refused == 4 and #CREATED < first and SE[busy:id()] and SE[far:id()] and SE[other:id()],
		"TakeAll checks bounds, distance, section and occupancy through trust")
	request("hf_takeall", { o = box:id(), peer = 0 })
	request("hf_takeall", { o = box:id() })
	check(takeall_result(box:id(), player:id(), first) and spots[box:id()] == nil,
		"repeated TakeAll removes one box and gives one item to the requester")
	if name == "hostplay" then
		local own_box = make_box(actor:position())
		local stock = stock_calls
		first = #CREATED + 1
		take_all(own_box)
		check(stock_calls == stock and takeall_result(own_box:id(), actor:id(), first), "co-op host uses the same TakeAll decider")
		local local_lamp, local_id = make_wrapper("hf_lamp", actor:position(), nil, light_class, { fuel = 0 })
		local charcoal = spawn("charcoal", actor:position(), actor:id())
		ui_furniture_light.UIFurnitureLight.Refuel({ light_id = local_id, section = "hf_lamp" })
		check(local_lamp.fuel == 1 and data[local_id].condition == 1 and SE[charcoal.id] == nil,
			"co-op host refuels through the same decider and saves immediately")
	else
		local t, packet = sent("mods.stash_book")
		check(t and t.b == box:id() and t.x == true and packet.target == 0, "map reports removal to the world registry")
	end
	local retry = make_box(player:position())
	local release = alife_release_id
	alife_release_id = function(id)
		if id ~= retry:id() then release(id) end
	end
	request("hf_takeall", { o = retry:id() })
	check(SE[retry:id()] and book[retry:id()] and SE[CREATED[#CREATED].id] == nil,
		"a failed stash release rolls back the return item and leaves the registry")
	alife_release_id = release
	first = #CREATED + 1
	AddScriptCallback("actor_on_stash_remove")
	local callback_count = 0
	RegisterScriptCallback("actor_on_stash_remove", function(t)
		callback_count = callback_count + 1
		if callback_count == 1 then request("hf_takeall", { o = t.stash_id }) end
	end)
	request("hf_takeall", { o = retry:id() })
	check(callback_count == 1 and takeall_result(retry:id(), player:id(), first),
		"retry after failure succeeds once even if the removal callback repeats the request")

	radial_target = furniture
	request("hf_freeze", { o = prop, f = false })
	local frozen, packet = sent("mods.hf_data")
	local state = frozen and coop_mods_core.deser(frozen.d)
	check(physics == 1 and furniture.is_frozen == false and state and state.is_frozen == false
		and packet.target == (name == "hostplay" and -1 or 0), "decider executes and publishes Unfreeze")
	if name == "hostplay" then check(furniture.menu_frozen == false, "remote Unfreeze refreshes the host's open radial menu") end
	furniture.is_frozen = true
	bind_hf_base.freeze_obj(prop)
	check(furniture.is_frozen == false, "confirmed Unfreeze survives the binder's spawn freeze")

	local fuel = spawn("charcoal", player:position(), player:id())
	request("hf_refuel", { o = lamp_id, i = fuel.id })
	local refuelled, update = sent("mods.hf_data")
	local confirmed = refuelled and coop_mods_core.deser(refuelled.d)
	check(SE[fuel.id] == nil and lamp.fuel == 1 and data[lamp_id].condition == 1 and confirmed and confirmed.condition == 1,
		"refuel spends the fuel item and publishes the new condition immediately")
	lamp:update(0.25)
	local spent, drain = sent("mods.hf_data")
	check(lamp.fuel == 0.75 and data[lamp_id].condition == 0.75 and saves == 1, "map authority drains and saves fuel")

	-- Two clients receive the same packets in independent mirror state. Use different local ids on each.
	MODE, SELF = "client", 1
	coop.is_map_server = function() return false end
	modes.install(coop_mode, name, {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
	})
	local function observer(offset)
		coop.to_local_id = function(id) return id + offset end
		coop.to_host_id = function(id) return id - offset end
		local w, local_id = make_wrapper("hf_lamp", actor:position(), lamp_id + offset, light_class, { fuel = 0 })
		local p = make_wrapper("hf_prop", actor:position(), prop + offset, base, { is_frozen = true })
		data[local_id] = { condition = 0, is_on = true }
		local before = saves
		if update then deliver(update, 0) end
		check(w.fuel == 1, "m17:2 observer " .. offset .. " updates the existing fuel field after refuel")
		local charcoal = spawn("charcoal", actor:position(), actor:id(), { id = 700 + offset })
		ui_furniture_light.UIFurnitureLight.Refuel({ light_id = local_id, section = "hf_lamp" })
		if spent and drain then deliver(drain, 0) end
		event("hf_item_r", { i = charcoal.id - offset, r = "left" }, 0)
		w:update(0.25)
		check(w.lit and w.fuel == 0.75 and data[local_id].condition == 0.75 and saves == before,
			"m32:7 observer " .. offset .. " keeps the newer condition through the item reply and visual update")
		local count = physics
		radial_target = p
		p:set_frozen(true)
		local t = sent("mods.hf_freeze")
		if packet then deliver(packet, 0) end
		check(t and t.o == prop and t.f == true and p.is_frozen == false and p.menu_frozen == false and physics == count,
			"observer " .. offset .. " shows confirmed frozen state without changing mirror physics")
		w:set_frozen(false)
		t = sent("mods.hf_freeze")
		check(t and t.o == lamp_id and t.f == false and physics == count,
			"observer " .. offset .. " routes a preloaded LuaBind subclass's inherited Unfreeze")
	end
	observer(10000)
	observer(20000)
	local mirror_box = make_box(actor:position(), 24000)
	local original = stock_calls
	take_all(mirror_box)
	local asked = sent("mods.hf_takeall")
	check(asked and asked.o == mirror_box:id() - 20000 and SE[mirror_box:id()] and book[mirror_box:id()]
		and stock_calls == original, "empty mirror TakeAll sends one request and preserves the local box and registry")
	check(take_all(mirror_box, { [42] = 1 }).transferred == true, "non-empty UI bag still uses the stock item transfer")
end

done("mods_hf_takeall " .. name)
