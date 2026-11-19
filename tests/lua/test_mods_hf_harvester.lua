-- Dev 57 G5-2: HF adapters over the shipped Gadgets and stove Lua, with object and transport stubs.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local bridge = 0x101
if name == "srv_map" then
	SELF = bridge
	coop.is_map_server = function() return true end
	coop.is_host = function() return false end
elseif name == "srv_world" then
	coop.is_dedicated = function() return true end
	coop.levels = { map_servers = function() return { { bridge = bridge } } end }
end
local actor = make_actor(vec3(0, 0, 0))
local _, player = spawn("coop_player_avatar", vec3(4, 0, 0), nil, { id = 500, kind = "stalker" })
local _, stranger = spawn("coop_player_avatar", vec3(4, 0, 0), nil, { id = 501, kind = "stalker" })
local GO = getmetatable(actor)
GO.name = GO.section
function GO:bind_object(binder) self.binder = binder end
function GO:iterate_inventory_box(f, context) self:iterate_inventory(f, context) end
local transfer = GO.transfer_item
function GO:transfer_item(item, to)
	self.moves = (self.moves or 0) + 1
	if not self.block_move then transfer(self, item, to) end
end
local original_alife = alife
function alife()
	local a = original_alife()
	a.set_switch_online = function() end
	a.set_switch_offline = function() end
	return a
end
function IsInvbox(o, cls) return cls == 0 or (o and o._kind == "box") end
local now_sec = 0
game.get_game_time = function() return { diffSec = function() return now_sec end } end
level.get_start_time = function() return 0 end
sound_object.looped = 4
EDDListType = { iActorBag = 1, iActorSlot = 2, iActorBelt = 3 }
game_setup = { is_world_item = function() return false end }
utils_xml = { screen_ratio = function() return 1 end }
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
SOUND_DIRS["tracks/"] = { "track.ogg", "next.ogg" }
SOUND_DIRS["sessions/"] = {}

local data, writes = {}, 0
hf_obj_manager = {
	get_data = function(id) return data[id] end,
	update_data = function(id, patch)
		writes = writes + 1
		data[id] = data[id] or {}
		for k, v in pairs(patch) do data[id][k] = v end
	end,
	delete_data = function(id) data[id] = nil end,
}

local base = {}
function base:__init(obj)
	self.object, self.binder = obj, { wrapper = self }
	obj:bind_object(self.binder)
end
function base:net_destroy() self.object, self.binder.wrapper = nil, nil end
function base:update() self.base_updates = (self.base_updates or 0) + 1 end
function base:is_pickupable() return true end
function base:pickup()
	alife_create_item("harvester_item", db.actor)
	alife_release(self.object)
	return true
end
bind_hf_base = { hf_binder_wrapper = base, get_wrapper = function(id)
	local obj = level.object_by_id(id)
	return obj and obj.binder and obj.binder.wrapper
end }
placeable_furniture = { pickup_obj = function(obj) return bind_hf_base.get_wrapper(obj:id()):pickup() end }
placeable_radio = { path_radio_ch = { "tracks/" }, path_radio_session = { "sessions/" },
	radio_vol = 0.5, psi_vol = 0, safety_lock = false, placeable_radio_wrapper = { update = function() end } }

local function load_mod(module)
	local env = setmetatable({}, { __index = _G })
	env.class = function(key)
		return function(parent)
			local cls = {}
			cls.__index = cls
			setmetatable(cls, { __index = parent, __call = function(_, obj)
				local self = setmetatable({}, cls)
				env.super = function(...) parent.__init(self, ...) end
				cls.__init(self, obj)
				return self
			end })
			env[key] = cls
		end
	end
	local path = "temp/review/corpus/merged/" .. module .. ".script"
	local script = assert(loadfile(path))
	setfenv(script, env)()
	_G[module] = env
	return env
end

local bh = load_mod("bind_artifact_harvester")
local stove = load_mod("ui_stove_furniture")
dofile("tests/lua/support/mod_source.lua")
ui_inventory = { UIInventory = { Print = function() end, On_Item_Update = function() end } }
assert(mod_chunk("temp/review/corpus/merged/ui_inventory.script", {
	"function UIInventory:CheckItem(", "function UIInventory:Action_Move(", "function UIInventory:On_Item_Exchange(",
}, "ui_inventory", "return true"))
local cooked = 0
item_cooking = { start = function(obj, kind)
	assert(obj and kind == "fieldcooker")
	cooked = cooked + 1
end }
function Unregister_UI() end
INI.placeable_artifact_harvester = { item_section = "harvester_item", integrated_storage = "harvester_box" }
INI.harvester_item = {}
INI.harvester_box = {}
INI.placeable_stove1 = { integrated_storage = "stove_box" }
AddScriptCallback("ActorMenu_on_item_before_move")
AddScriptCallback("ActorMenu_on_item_after_move")
bh.on_game_start()
start_all()
modes.install(coop_mode, name)

local links = {}
local function make_harvester(actor_pos)
	local _, obj = spawn("placeable_artifact_harvester", actor_pos)
	local _, box = spawn("harvester_box", vec3(actor_pos.x, -50, actor_pos.z), nil, { kind = "box" })
	links[obj:id()] = box:id()
	bh.harvester_load_state({ harvester_stashes = links })
	return obj, box, bh.artifact_harvester_wrapper(obj)
end

local function request(verb, t, sender)
	NOW = NOW + 1000
	if name == "srv_map" and not sender then t._peer, sender = 1, 0 end
	coop_main.on_event("mods." .. verb, coop_main.encode(t), sender or 1)
end
local function configure_display()
	local v = getmetatable(vector())
	function v:add(o) return self:set(self.x + o.x, self.y + o.y, self.z + o.z) end
	function v:mul(n) return self:set(self.x * n, self.y * n, self.z * n) end
	local q = { rotate_vector = function(_, value) return value end, to_euler_angles = function() return vector() end }
	function q:multiply() return self end
	aol_rotation = { Quaternion = function() return q end }
	local create = alife_create_item
	function alife_create_item(sec, dest, opts)
		if dest[1] then return alife_create(sec, unpack(dest)) end
		return create(sec, dest, opts)
	end
end
configure_display()

if name == "srv_world" then
	local obj, box = make_harvester(player:position())
	local device_id = obj:id() + 1000 -- device on the player's map, absent here
	local created = #CREATED
	request("hf_box", { k = "harvester", o = device_id })
	local forwarded, raw = sent("mods.hf_box")
	check(forwarded and forwarded._peer == 1 and forwarded.o == device_id and forwarded.k == "harvester"
		and raw.target == bridge and sent_count("mods.hf_box") == 1 and sent_count("mods.hf_box_r") == 0
		and #CREATED == created, "world server forwards the box request once to the map server")
	local item = alife_create_item("af_gravi", player)
	request("hf_harv_insert", { o = obj:id(), i = item.id, _peer = 9 })
	forwarded, raw = sent("mods.hf_harv_insert")
	check(forwarded and forwarded._peer == 1 and raw.target == bridge and item.parent_id == player:id(),
		"world server forwards insert under the transport sender and never uses its ghost's inventory")
	request("hf_harv_demount", { o = obj:id() })
	forwarded, raw = sent("mods.hf_harv_demount")
	check(forwarded and raw.target == bridge and alife_object(box:id()) ~= nil, "world server forwards demount without touching the stash")
	local mirror_id = obj:id() + 1000
	request("hf_data", { o = mirror_id, b = box:id(), d = coop_mods_core.ser({ artifact_condition = 0.8 }) }, bridge)
	local state = {}
	bh.harvester_save_state(state)
	local published
	published, raw = sent("mods.hf_data")
	check(state.harvester_stashes[mirror_id] == box:id() and data[mirror_id].artifact_condition == 0.8
		and published and published.b == box:id() and raw.target == -1, "world server saves and relays the decider's stash link")
	request("hf_data", { o = mirror_id, b = -1, x = true }, bridge)
	check(state.harvester_stashes[mirror_id] == nil and data[mirror_id] == nil, "world server removes the packed device's mirror state")
elseif name == "none" then
	local obj, box, wrapper = make_harvester(actor:position())
	local item = alife_create_item("af_gravi", box)
	check(data[obj:id()] and data[obj:id()].last_time_sec == 0, "single player constructor stays stock")
	wrapper:net_destroy()
	check(item.parent_id == actor:id() and not alife_object(box:id()), "single player unload stays stock")
else
	local _, unopened = spawn("placeable_artifact_harvester", player:position())
	local created = #CREATED
	request("hf_box", { k = "harvester", o = unopened:id() })
	local reply, box_packet = sent("mods.hf_box_r")
	local state = {}
	bh.harvester_save_state(state)
	local opened_box_id = state.harvester_stashes[unopened:id()]
	local unopened_box = OBJ[opened_box_id]
	check(unopened_box and unopened_box:section() == "harvester_box" and #CREATED == created + 1
		and reply and reply.k == "harvester" and reply.o == unopened:id() and reply.b == opened_box_id
		and box_packet.target == 1 and sent_count("mods.hf_box_r") == 1,
		"map decider creates the stock stash and answers once to the requester")
	run_time_events(1000)
	check(unopened_box and unopened_box._used_by == nil, "map decider never opens the requester's stash window")

	local obj, box = make_harvester(player:position())
	local foreign = alife_create_item("af_gravi", stranger)
	request("hf_harv_insert", { o = obj:id(), i = foreign.id })
	local answer, raw = sent("mods.hf_harv_r")
	check(foreign.parent_id == stranger:id() and answer and raw.target == 1,
		"foreign insert is refused and explained only to its transport sender")
	local item = alife_create_item("af_gravi", player)
	local far = make_harvester(vec3(25, 0, 0))
	request("hf_harv_insert", { o = far:id(), i = item.id })
	check(item.parent_id == player:id(), "a reach check rejects a device on the same map but far from the player")
	request("hf_harv_insert", { o = obj:id(), i = item.id })
	check(item.parent_id == box:id() and data[obj:id()].artifact_item_id == item.id,
		"insert validates distance to the device and starts production despite the hidden box position")
	local extra = alife_create_item("af_gravi", player)
	request("hf_harv_insert", { o = obj:id(), i = extra.id })
	check(extra.parent_id == player:id(), "a second input cannot enter an active harvester")
	if name == "srv_map" then
		request("hf_harv_demount", { o = obj:id(), _peer = 1 }, 2)
		check(alife_object(box:id()) ~= nil, "map decider ignores a request that bypassed the world relay")
	end
	local device_id, box_id, count = obj:id(), box:id(), #CREATED
	box.block_move = true
	request("hf_harv_demount", { o = device_id })
	check(alife_object(device_id) and alife_object(box_id) and item.parent_id == box_id and #CREATED == count,
		"demount keeps the device and stash when the contents could not be returned")
	box.block_move, box.moves = false, 0
	request("hf_harv_demount", { o = device_id })
	request("hf_harv_demount", { o = device_id })
	check(item.parent_id == player:id() and box.moves == 1 and not alife_object(box_id),
		"two demount requests return the input to the initiator exactly once")
	check(not alife_object(device_id) and #CREATED == count + 1 and CREATED[#CREATED].parent == player:id(),
		"demount packs up one device for the requester while the authority has a different actor")
	local active_device, active_box, active_wrapper = make_harvester(player:position())
	local active_item = alife_create_item("af_gravi", player)
	request("hf_harv_insert", { o = active_device:id(), i = active_item.id })
	now_sec = 3700
	active_wrapper:update(10000)
	local produced = CREATED[#CREATED].sec
	check(OBJ[active_item.id]:condition() < 1 and (produced == "prt_i_scrap" or produced == "prt_i_fasteners"),
		"the map decider advances production and consumes condition")
	local active_box_id = active_box:id()
	active_wrapper:net_destroy()
	check(alife_object(active_box_id) and active_item.parent_id == active_box_id and links[active_device:id()] == active_box_id,
		"authority net_destroy on unload also keeps harvester contents and the stash link")
	if name == "hostplay" then
		local local_obj, local_box = make_harvester(actor:position())
		local local_item = alife_create_item("af_gravi", local_box)
		placeable_furniture.pickup_obj(local_obj)
		check(local_item.parent_id == actor:id() and not alife_object(local_box:id()), "co-op host's pickup takes the same demount path")
	end

	MODE, SELF = "client", 1
	coop.is_map_server = function() return false end
	modes.install(coop_mode, name, {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
	})
	local mirror, mirror_box, wrapper = make_harvester(actor:position())
	local mirror_id, mirror_box_id = mirror:id(), mirror_box:id()
	check(data[mirror_id] == nil, "mirror constructor does not initialize world state")
	local mirror_input = alife_create_item("af_gravi", mirror_box)
	request("hf_data", { o = mirror_id, d = coop_mods_core.ser({ artifact_item_id = mirror_input.id,
		artifact_section = "af_gravi", artifact_condition = 1, progress_sec = 0, last_time_sec = 0 }) }, 0)
	local was_writes, was_created = writes, #CREATED
	now_sec = 3700
	wrapper:update(10000)
	check(writes == was_writes and #CREATED == was_created and OBJ[mirror_input.id]:condition() == 1,
		"mirror update consumes neither condition nor elapsed production time and creates no decoration")
	check(wrapper.snd_hum:playing(), "mirror plays the production sound from hf_data")
	wrapper:net_destroy()
	check(mirror_input.parent_id == mirror_box_id and alife_object(mirror_box_id) and links[mirror_id] == mirror_box_id,
		"mirror net_destroy stops local effects and keeps both the contents and stash link")
	check(not wrapper.snd_hum:playing() and wrapper.object == nil, "mirror net_destroy cleans sound and binder")

	local ui_obj, ui_box = make_harvester(actor:position())
	local _, wrong = spawn("bread", actor:position(), actor:id())
	local _, valid = spawn("af_gravi", actor:position(), actor:id())
	local blocked = { ret_value = true }
	was_writes = writes
	SendScriptCallback("ActorMenu_on_item_before_move", blocked, ui_box:id(), wrong, "loot", EDDListType.iActorBag)
	check(not blocked.ret_value and sent_count("mods.hf_harv_insert") == 0 and writes == was_writes,
		"window refuses an unconfigured artifact without a write or a request")
	local accepted = { ret_value = true }
	SendScriptCallback("ActorMenu_on_item_before_move", accepted, ui_box:id(), valid, "loot", EDDListType.iActorBag)
	check(accepted.ret_value and sent_count("mods.hf_harv_insert") == 0 and writes == was_writes,
		"window's move check previews a valid insert without sending or writing")
	local inventory = setmetatable({ mode = "loot", npc_id = ui_box:id(), bag_id = { actor_bag = EDDListType.iActorBag } },
		{ __index = ui_inventory.UIInventory })
	inventory:Action_Move(valid, "actor_bag")
	local insert, raw_insert = sent("mods.hf_harv_insert")
	check(SE[valid:id()].parent_id == actor:id() and insert and insert.o == ui_obj:id() and insert.i == valid:id() and raw_insert.target == 0,
		"window turns a valid insert into a request and cancels the ordinary transfer")

	local _, radio = spawn("placeable_radio", actor:position())
	local track = sound_object("track")
	local rw = setmetatable({ object = radio, radio_ch = { { track, sound_object("next") } }, radio_session = { {} },
		radio_now = { 1 }, radio_session_now = { 1 } }, { __index = placeable_radio.placeable_radio_wrapper })
	local packet = { o = radio:id(), on = true, p = "tracks/", q = "sessions/", k = 0, c = "track", v = 0.5, n = 1 }
	request("hf_radio", packet, 0)
	rw:update(10)
	local plays = #SOUNDS
	check(track:playing() and track.volume == 0.5, "first radio packet starts the selected track")
	request("hf_radio", packet, 0)
	rw:update(10)
	check(track:playing() and #SOUNDS == plays, "identical radio packet preserves playback")
	packet.v, packet.n = 0.7, 2
	request("hf_radio", packet, 0)
	rw:update(10)
	check(track:playing() and #SOUNDS == plays and track.volume == 0.7, "volume-only packet adjusts the live sound without starting it again")

	local _, cooker = spawn("placeable_stove1", actor:position())
	local _, stove_box = spawn("stove_box", vec3(0, -50, 0), nil, { kind = "box" })
	local ingredient = alife_create_item("bread", stove_box)
	alife_storage_manager.get_state().stove_stashes = { [cooker:id()] = stove_box:id() }
	local window = setmetatable({ obj_id = cooker:id(), shown = true, IsShown = function(self) return self.shown end,
		HideDialog = function(self) self.shown = false end }, { __index = stove.UICookStove })
	stove.GUI = window
	OBJ[stove_box:id()] = nil
	window:UseCook()
	window:UseCook()
	local ok = pcall(run_time_events, 100)
	check(ok and cooked == 0 and ingredient.parent_id == stove_box:id(), "stove waits safely for a known offline box")
	OBJ[stove_box:id()] = stove_box
	check(pcall(run_time_events, 300) and cooked == 1 and stove_box.moves == 1 and ingredient.parent_id == actor:id(),
		"late stove box moves contents and opens exactly once after repeated clicks")
	local _, removed_stove = spawn("placeable_stove1", actor:position())
	local _, late_box = spawn("stove_box", vec3(0, -50, 0), nil, { kind = "box" })
	local untouched = alife_create_item("bread", late_box)
	alife_storage_manager.get_state().stove_stashes[removed_stove:id()] = late_box:id()
	window.obj_id, window.shown = removed_stove:id(), true
	OBJ[late_box:id()] = nil
	window:UseCook()
	alife_release(removed_stove)
	OBJ[late_box:id()] = late_box
	check(pcall(run_time_events, 300) and cooked == 1 and untouched.parent_id == late_box:id(),
		"a stove that vanishes before the box arrives never takes its contents or opens cooking")
	local _, closed_stove = spawn("placeable_stove1", actor:position())
	alife_storage_manager.get_state().stove_stashes[closed_stove:id()] = late_box:id()
	window.obj_id, window.shown = closed_stove:id(), true
	OBJ[late_box:id()] = nil
	window:UseCook()
	window:Close()
	window.shown = true
	OBJ[late_box:id()] = late_box
	check(pcall(run_time_events, 300) and cooked == 1 and untouched.parent_id == late_box:id(),
		"closing and reopening the stove window cancels its old wait")
end

done("mods_hf_harvester@" .. name)
