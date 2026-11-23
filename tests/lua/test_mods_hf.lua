-- R32 WP18: exercise the real furniture request and binder entry points.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

make_actor()
spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500 })
local wrappers, foreign, data = {}, {}, {}
local created, boxes, fuel_ticks, toggles, saves, shown, removed = 0, 0, 0, 0, 0, 0, 0
local radio_ticks, radio_actions = 0, 0
local base = {}
function base:__init(obj)
	self.object = obj
	wrappers[obj:id()] = self
end
function base:update() end
function base:pickup()
	alife_create_item("furn_item", db.actor)
	-- ALife forgets the record before the online object processes GE_DESTROY.
	SE[self.object:id()] = nil
	return true
end
bind_hf_base = { hf_binder_wrapper = base, get_wrapper = function(id) return wrappers[id] end }
local inherited_pickup = base.pickup
hf_obj_manager = {
	get_data = function(id) return data[id] end,
	update_data = function(id, row)
		data[id] = data[id] or {}
		for k, v in pairs(row) do data[id][k] = v end
	end,
	delete_data = function(id) data[id] = nil end,
}
placeable_furniture = {
	create_object = function(sec, pos)
		created = created + 1
		return alife_create(sec, pos, 1, 2).id
	end,
	func_place_item = function() end,
	start_placing_item = function() end,
	pickup_obj = function(obj) return wrappers[obj:id()]:pickup() end,
}
ui_furniture_workshop = {
	GetStash = function() boxes = boxes + 1; return 650 end,
}
ui_stove_furniture = {
	access_inventory = function() boxes = boxes + 1 end,
}
ui_furniture_light = { toggle_light = function() toggles = toggles + 1 end }
ui_furniture_piano = { UIFurniturePiano = {
	Pickup = function(self) return inherited_pickup(wrappers[self.obj_id]) end,
} }
bind_light_furniture = { placeable_light_wrapper = {
	update = function(self) if not self.infinite_fuel then fuel_ticks = fuel_ticks + 1 end end,
	save_data = function() saves = saves + 1 end,
} }
placeable_radio = {
	path_radio_ch = {}, path_radio_session = {}, safety_lock = false,
	placeable_radio_wrapper = {
		update = function() radio_ticks = radio_ticks + 1 end,
		action_radio_start = function() radio_actions = radio_actions + 1 end,
	},
}
function base:set_frozen(value) self.is_frozen = value end
bind_hf_base.freeze_obj = function(id) wrappers[id].is_frozen = true; return true end
hf_monkeypatches = {}
ui_inventory = { UIInventory = { LMode_TakeAll = function() end } }
function level.map_remove_object_spot() end
game_setup = { is_world_item = function() return false end }
game.get_game_time = function() return { diffSec = function() return 10 end } end
level.get_start_time = function() return 0 end
local function load_harvester()
	local env = setmetatable({}, { __index = _G })
	env.class = function(key)
		return function(parent)
			local cls = {}
			cls.__index = cls
			env[key] = setmetatable(cls, { __index = parent, __call = function(_, obj)
				local self = setmetatable({}, cls)
				env.super = function(...) parent.__init(self, ...) end
				cls.__init(self, obj)
				return self
			end })
		end
	end
	local dir = os.getenv("GAMMA_SCRIPTS") or "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts"
	setfenv(assert(loadfile(dir .. "/bind_artifact_harvester.script")), env)()
	return env
end
bind_artifact_harvester = load_harvester()
AddScriptCallback("ActorMenu_on_item_before_move")
AddScriptCallback("ActorMenu_on_item_after_move")
weapon_showcase = {
	weapon_displays = {},
	spawn_displayed_item = function() shown = shown + 1 end,
	remove_displayed_item = function() removed = removed + 1 end,
	respawn_weapon_displays = function()
		for case_id, items in pairs(weapon_showcase.weapon_displays) do
			for item in pairs(items) do weapon_showcase.spawn_displayed_item(case_id, item) end
		end
		return true
	end,
}
INI.furn_item = { placeable_section = "furn_obj" }
local function furniture(id)
	local _, obj = spawn("furn_obj", vec3(1, 0, 0), nil, { id = id })
	wrappers[id] = setmetatable({ object = obj }, { __index = base })
	return wrappers[id]
end
local function request(verb, t)
	if name == "srv_map" then t._peer = 1 end
	coop_main.on_event("mods." .. verb, coop_main.encode(t), name == "srv_map" and 0 or 1)
end
local function pickup(id)
	request("hf_pickup", { o = id })
end

start_all()
modes.install(coop_mode, name, { writes = function(id) return not foreign[id] end })
local first = furniture(600)
if name == "hostplay" or name == "srv_map" then
	pickup(600)
	pickup(600)
	check(#CREATED == 1 and SE[600] == nil and OBJ[600] ~= nil,
		"probe_hf_same_pump: a queued destroy permits exactly one pickup")
elseif name == "srv_world" then
	first:pickup()
	first:pickup()
	check(#CREATED == 1 and SE[600] == nil, "probe_hf_same_pump: the world writer packs only once")
else
	first:pickup()
	check(#CREATED == 1 and SE[600] == nil, "single player uses the stock pickup")
end

if name == "srv_map" or name == "srv_world" then
	local other = furniture(601)
	foreign[601] = true
	other:pickup()
	if name == "srv_map" then pickup(601) end
	check(#CREATED == 1 and SE[601] ~= nil, "a non-writer does not pack another server's furniture")
end

if name ~= "none" then
	local copied = furniture(607)
	copied.pickup = inherited_pickup
	local before = #CREATED
	placeable_furniture.pickup_obj(copied.object)
	placeable_furniture.pickup_obj(copied.object)
	check(#CREATED == before + 1, "radial pickup also reserves a subclass with a copied stock method")
	local piano = furniture(608)
	before = #CREATED
	ui_furniture_piano.UIFurniturePiano.Pickup({ obj_id = piano.object:id() })
	ui_furniture_piano.UIFurniturePiano.Pickup({ obj_id = piano.object:id() })
	check(#CREATED == before + 1, "dialog pickup that bypasses the binder also runs once per object")
end

local own, other = furniture(610).object, furniture(611).object
local _, item = spawn("furn_item", vec3(1, 0, 0), 500, { id = 612 })
local distributed = name == "srv_map" or name == "srv_world"
foreign[611], foreign[612] = distributed, distributed
ui_furniture_workshop.GetStash(own:id())
ui_furniture_workshop.GetStash(other:id())
ui_stove_furniture.access_inventory(own)
ui_stove_furniture.access_inventory(other)
if name == "srv_map" then request("hf_box", { o = other:id(), k = "workshop" }) end
check(boxes == (distributed and 2 or 4), "only the furniture writer creates workbench and stove storage")

local lamp = bind_light_furniture.placeable_light_wrapper
lamp.update({ object = own })
lamp.update({ object = other })
lamp.save_data({ object = own })
lamp.save_data({ object = other })
ui_furniture_light.toggle_light(own:id())
ui_furniture_light.toggle_light(other:id())
if name == "srv_map" then request("hf_lamp", { o = other:id(), on = true }) end
check(fuel_ticks == (distributed and 1 or 2), "only the lamp writer burns its fuel")
check(saves == (distributed and 1 or 2), "only the lamp writer saves its fuel")
check(toggles == (distributed and 1 or 2) and data[other:id()] == nil,
	"only the lamp writer changes its state in local and routed actions")

-- R32 W8.1 (WP18, the lamp's 'left' reply): the process that decides for the player (the co-op host; the map server of his
-- level) spends the tool's use itself through the stock setter and answers 'spent'; a tool it does not write is refused.
if name == "hostplay" or name == "srv_map" then
	INI.furn_obj = { require_matches = true }
	INI.box_matches = { multiuse = 5 }
	local saved_is_item, saved_utils = IsItem, utils_item
	IsItem = function(kind, sec) return kind == "multiuse" and INI[sec] and INI[sec].multiuse ~= nil or nil end
	utils_item = {
		is_degradable = function() return false end,
		discharge = function(o) o._uses = (o._uses or 1) - 1 end,
	}
	local _, box = spawn("box_matches", vec3(1, 0, 0), 500, { id = 660 })
	box._uses = 5
	box.get_remaining_uses = function(self) return self._uses end
	local function lamp_answer(item_id)
		SENT = {}
		request("hf_lamp", { o = own:id(), on = true, i = item_id })
		local t = sent("mods.hf_item_r")
		return t and t.r
	end
	check(lamp_answer(660) == "spent" and box._uses == 4, name .. ": the decider spent the box's use itself and answered 'spent'")
	local _, foreign_box = spawn("box_matches", vec3(1, 0, 0), 500, { id = 661 })
	foreign_box._uses = 5
	foreign[661] = true
	check(lamp_answer(661) == "no" and foreign_box._uses == 5, name .. ": a tool another process writes: 'no', nothing spent")
	IsItem, utils_item = saved_is_item, saved_utils
	INI.furn_obj = nil
end

if distributed then
	placeable_furniture.func_place_item(item)
	placeable_furniture.create_object("furn_obj", vec3(1, 0, 0), vec3(0, 0, 0), 1, 2)
	if name == "srv_map" then
		request("hf_place", { i = item:id(), s = "furn_obj", x = 1, y = 0, z = 0 })
	end
	check(created == 0 and SE[item:id()] ~= nil, "only the carried item's writer can place that furniture")
end

weapon_showcase.spawn_displayed_item(own:id(), 620)
weapon_showcase.spawn_displayed_item(other:id(), 621)
weapon_showcase.remove_displayed_item(620, own:id(), own:id())
weapon_showcase.remove_displayed_item(621, other:id(), other:id())
check(shown == (distributed and 1 or 2) and removed == (distributed and 1 or 2),
	"display creation and removal follow the case and display writers")
weapon_showcase.weapon_displays = { [own:id()] = { [620] = 630 }, [other:id()] = { [621] = 631 } }
local before = shown
weapon_showcase.respawn_weapon_displays()
check(shown - before == (distributed and 1 or 2)
	and weapon_showcase.weapon_displays[other:id()][621] == 631,
	"load respawns displays on their writer and preserves the other case's rows")

-- R32 P4 (temp/r30/design/R32-addendum-gaps2.md): a display copy is a real weapon in the case; the mod's veto runs only on the
-- picker's machine. The decider's move rules (coop_mods_move_limits.admit, asked by the engine before it applies a move) refuse
-- any move of one, into a player's character too; any other item is not this rule's.
local admit = coop_mods_move_limits.admit
local verdict, why = admit(500, 630, 0, 0, own:id())
check(verdict == false and type(why) == "string", "a take of a display copy into a character is refused on the decider")
check(admit(650, 631, 0, 0, 65535) == false, "into a box too, the other case's copy as well")
check(admit(500, 612, 0, 0, 65535) == nil, "an ordinary item is not the display rule's")

hf_obj_manager.update_data(own:id(), { flag = true })
hf_obj_manager.update_data(other:id(), { flag = true })
check(data[own:id()].flag and ((data[other:id()] ~= nil) ~= distributed),
	"only the furniture writer changes its live row")
local ow, fw = wrappers[own:id()], wrappers[other:id()]
for _, w in ipairs({ ow, fw }) do
	w.radio_ch, w.radio_session, w.radio_now, w.radio_session_now = {}, {}, {}, {}
	placeable_radio.placeable_radio_wrapper.update(w, 1)
	placeable_radio.placeable_radio_wrapper.action_radio_start(w)
end
if name == "srv_map" then request("hf_radio_ctl", { o = other:id(), a = "action_radio_start" }) end
check(radio_ticks == (distributed and 1 or 2) and radio_actions == (distributed and 1 or 2),
	"only the radio writer advances and changes its station state")
ow:set_frozen(false)
fw:set_frozen(false)
if name == "srv_map" then request("hf_freeze", { o = other:id(), f = false }) end
check((name == "srv_world" or name == "srv_map" or ow.is_frozen == false)
	and ((fw.is_frozen == false) == (not distributed)), "freeze actions leave another writer's furniture alone")

local _, machine = spawn("placeable_artifact_harvester", nil, nil, { id = 640 })
local _, foreign_machine = spawn("placeable_artifact_harvester", nil, nil, { id = 641 })
foreign[641] = distributed
local Harvester = bind_artifact_harvester.artifact_harvester_wrapper
local local_harvester, other_harvester = Harvester(machine), Harvester(foreign_machine)
local_harvester:update(10000)
other_harvester:update(10000)
check(data[640] and data[640].last_time_sec == 10 and ((data[641] ~= nil) ~= distributed),
	"only the harvester writer initializes and advances its clock")

INI.hf_stash, INI.hf_stash_item = { placeable_type = "stash", item_section = "hf_stash_item" }, {}
local _, stash = spawn("hf_stash", vec3(1, 0, 0), nil, { id = 645, kind = "box" })
alife_storage_manager.get_state().player_created_stashes = { [645] = "hf_stash_item" }
foreign[645] = name == "srv_map"
if name == "srv_map" or name == "hostplay" then
	request("hf_takeall", { o = stash:id() })
	check((alife_object(stash:id()) ~= nil) == foreign[645], "empty Take All packs only on the stash writer")
end

done("mods_hf@" .. name)
