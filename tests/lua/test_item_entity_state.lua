-- Run the enabled G.A.M.M.A. ItemProcessor without starting the game.
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local gamma = assert(os.getenv("GAMMA_SCRIPTS"), "set GAMMA_SCRIPTS to the read-only game-dev script directory")
local file = assert(io.open(gamma .. "/itms_manager.script", "rb"))
local src = file:read("*a")
file:close()
local first = assert(src:find("local c_instance", 1, true))
local last = assert(src:find("\n-- DEBUG", first, true))

local entities, objects, seen, pending_spawns = {}, {}, {}, {}
local next_id = 4000
local function create(_, section, _, _, _, parent, ammo)
	next_id = next_id + 1
	local owner = entities[parent]
	local online = owner ~= nil and owner.online and not owner.elsewhere
	local entity = { online = online, condition = 1, uses = 3 }
	entities[next_id] = entity
	-- Process_spawn serializes the item before Create_Item queues its roll.
	if online then pending_spawns[next_id] = { cond = entity.condition, uses = entity.uses } end
	-- alife():create returns CSE_Abstract. The typed alife():object lookup exposes online.
	return { id = next_id, section = section, parent_id = parent, ammo = ammo }
end
local owner = { {}, 2, 3, 500 }
local PE = setmetatable({
	ini_sys = { section_exist = function() return true end, r_u32 = function() return 10 end },
	IsItem = function(kind, section)
		return (kind == "multiuse" and section == "kit") or (kind == "ammo" and section == "ammo")
	end,
	utils_item = { is_degradable = function(_, section) return section == "part" end },
	alife = function()
		return { create = create, create_ammo = create, object = function(_, id) return entities[id] end }
	end,
	alife_record = function() end,
	alife_object = function(id) return entities[id] end,
	level_object_by_id = function(id) return objects[id] end,
	string_find = string.find,
}, { __index = _G })
PE.class = function(name)
	local c = {}
	c.__index = c
	setmetatable(c, { __call = function(cls)
		local obj = setmetatable({}, cls)
		obj:__init()
		return obj
	end })
	PE[name] = c
end
setfenv(assert(loadstring(src:sub(first, last), "@itms_manager.script")), PE)()
itms_manager = PE
alife = PE.alife
level = { object_by_id = PE.level_object_by_id }
local frame = { frame = 1 }
device = function() return frame end
local accept = true
coop.items = { set_initial = function(id, state)
	assert(entities[id], "the creation must precede staging")
	if not accept then return false, "not written here" end
	seen[id] = state
	if state.condition ~= nil then entities[id].condition = state.condition end
	if state.uses ~= nil then entities[id].uses = state.uses end
	return true
end }

load_script_file("coop_item_entity_state").on_game_start()
local processor = PE.get_item_processor()

local kit = PE.create_item("kit", owner)
PE.process_item("kit", kit.id, { uses = 1 })
check(seen[kit.id] and seen[kit.id].uses == 1 and processor.Uses[kit.id] == nil,
	"the post-create uses are staged synchronously and the stock queue is consumed")

local defined = PE.create_item("kit__2", owner, { uses = 3 })
check(seen[defined.id] and seen[defined.id].uses == 2, "stock's section suffix wins over the supplied uses")

local part = PE.create_item("part", owner, { cond_r = { 40, 40 } })
check(seen[part.id] and seen[part.id].condition == 0.4 and processor.Cond[part.id] == nil,
	"the stock condition roll uses the engine's condition field")

local box = PE.create_item("ammo", owner)
PE.process_item("ammo", box.id, { ammo = 0 })
check(seen[box.id] and seen[box.id].ammo == 0 and processor.Ammo[box.id] == nil,
	"zero rounds survive the mapping")
local stack = PE.create_item("ammo", owner, { ammo = 13 })
check(#stack == 2 and stack[1].ammo == 10 and stack[2].ammo == 3,
	"stock creates ammo boxes with their amounts already on the entities")

local later = PE.create_item("kit", owner)
frame.frame = frame.frame + 1
PE.process_item("kit", later.id, { uses = 2 })
check(seen[later.id] == nil and processor.Uses[later.id] == 2,
	"a later update to an existing item is not its initial spawn state")

local online = PE.create_item("kit", owner)
objects[online.id] = {
	set_remaining_uses = function(self, n) self.uses = n end,
	get_remaining_uses = function(self) return self.uses end,
}
PE.process_item("kit", online.id, { uses = 2 })
processor:update()
check(seen[online.id] == nil and objects[online.id].uses == 2, "an online item uses the stock setter")

accept = false
local foreign = PE.create_item("kit", owner)
PE.process_item("kit", foreign.id, { uses = 1 })
check(seen[foreign.id] == nil and processor.Uses[foreign.id] == 1, "an engine refusal leaves the stock order pending")

local function next_frame()
	frame.frame = frame.frame + 1
	for id, spawn in pairs(pending_spawns) do
		objects[id] = {
			cond = spawn.cond,
			uses = spawn.uses,
			set_condition = function(self, value) self.cond = value end,
			condition = function(self) return self.cond end,
			set_remaining_uses = function(self, value) self.uses = value end,
			get_remaining_uses = function(self) return self.uses end,
		}
		pending_spawns[id] = nil
	end
end

local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script_file("coop_mode")
accept = true
modes.each(facade, function(name)
	coop.is_active = function() return name ~= "none" end
	if facade.leads_here() then
		-- Both local deciders see the corpse's child marked online before its game object exists.
		local corpse = { {}, 2, 3, 700 }
		entities[corpse[4]] = { online = true }
		local pda = PE.create_item("part", corpse, { cond_r = { 40, 40 } })
		local supplies = PE.create_item("kit__2", corpse)
		check(not objects[pda.id] and not objects[supplies.id], name .. ": corpse loot has only queued spawns this frame")
		check(seen[pda.id] == nil and processor.Cond[pda.id] == 0.4,
			name .. ": the corpse PDA condition stays queued for ItemProcessor")
		check(seen[supplies.id] == nil and processor.Uses[supplies.id] == 2,
			name .. ": the corpse supplies' uses stay queued for ItemProcessor")
		PE.process_item("kit", supplies.id, { uses = 1 })
		check(seen[supplies.id] == nil and processor.Uses[supplies.id] == 1,
			name .. ": a same-frame uses override stays queued too")
		next_frame()
		check(objects[pda.id]:condition() == 1 and objects[supplies.id]:get_remaining_uses() == 3,
			name .. ": queued spawn packets still carry the default values")
		processor:update()
		check(objects[pda.id]:condition() == 0.4 and processor.Cond[pda.id] == nil,
			name .. ": ItemProcessor applies the roll to the online corpse PDA")
		check(objects[supplies.id]:get_remaining_uses() == 1 and processor.Uses[supplies.id] == nil,
			name .. ": ItemProcessor applies the remaining uses to the online corpse supplies")
	end

	local parent = { {}, 2, 3, 701 }
	local elsewhere = name == "srv_world"
	entities[parent[4]] = { online = elsewhere, elsewhere = elsewhere }
	local offline = PE.create_item("part", parent, { cond_r = { 40, 40 } })
	local offline_kit = PE.create_item("kit", parent)
	PE.process_item("kit", offline_kit.id, { uses = 1 })
	if name == "none" then
		check(seen[offline.id] == nil and processor.Cond[offline.id] == 0.4 and
			seen[offline_kit.id] == nil and processor.Uses[offline_kit.id] == 1,
			"outside a co-op session, stock keeps its queue")
	else
		check(not pending_spawns[offline.id] and entities[offline.id].condition == 0.4 and processor.Cond[offline.id] == nil,
			name .. ": an offline item's condition is staged on the entity")
		check(not pending_spawns[offline_kit.id] and entities[offline_kit.id].uses == 1 and processor.Uses[offline_kit.id] == nil,
			name .. ": an offline item's uses are staged on the entity")
	end
end)

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
