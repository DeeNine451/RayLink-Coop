-- Run the enabled G.A.M.M.A. ItemProcessor without starting the game.
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local gamma = assert(os.getenv("GAMMA_SCRIPTS"), "set GAMMA_SCRIPTS to the read-only game-dev script directory")
local file = assert(io.open(gamma .. "/itms_manager.script", "rb"))
local src = file:read("*a")
file:close()
local first = assert(src:find("local c_instance", 1, true))
local last = assert(src:find("\n-- DEBUG", first, true))

local entities, objects, seen = {}, {}, {}
local next_id = 4000
local function create(_, section, _, _, _, parent, ammo)
	next_id = next_id + 1
	local entity = { id = next_id, section = section, parent = parent, ammo = ammo }
	entities[next_id] = entity
	return entity
end
local owner = { {}, 2, 3, 500 }
local PE = setmetatable({
	ini_sys = { section_exist = function() return true end, r_u32 = function() return 10 end },
	IsItem = function(kind, section)
		return (kind == "multiuse" and section == "kit") or (kind == "ammo" and section == "ammo")
	end,
	utils_item = { is_degradable = function(_, section) return section == "part" end },
	alife = function() return { create = create, create_ammo = create } end,
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
level = { object_by_id = PE.level_object_by_id }
local frame = { frame = 1 }
device = function() return frame end
local accept = true
coop.items = { set_initial = function(id, state)
	assert(entities[id], "the creation must precede staging")
	if not accept then return false, "not written here" end
	seen[id] = state
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

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
