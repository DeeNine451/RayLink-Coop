-- Dev 57 G8-2: run the real stock cleanup and GAMMA squad selection over world-server records.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local corpus = "temp/review/corpus/merged/"
local stock = "../anomaly-ref/unpacked/scripts/"
local function source(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

local function load_module(name, path, contents)
	local module = setmetatable({}, { __index = _G })
	rawset(_G, name, module)
	setfenv(assert(loadstring(contents or source(path), "@" .. path)), module)()
	return module
end

local EMPTY, OCCUPIED, OTHER_PLAYER, GHOST, UNPLACED, DEAD = 1, 2, 3, 4, 5, 6
local world_actor = { id = 0, m_game_vertex_id = GHOST, props = {} }
clsid = { script_actor = 1, online_offline_group_s = 2, smart_terrain = 3 }
function world_actor:clsid() return clsid.script_actor end
function world_actor:target_precondition() return true end

local players, held, life = {}, {}, {}
coop.players = function() return players end
coop.life_of = function(id) return life[id] or "alive" end
coop.levels = { online_at_server = function(id) return held[id] == true end }
local graph = {
	valid_vertex_id = function(_, vertex) return vertex >= EMPTY and vertex <= DEAD end,
	vertex = function(_, vertex) return { level_id = function() return vertex end } end,
}
function game_graph() return graph end

local sim = {
	actor = function() return world_actor end,
	object = function(_, id) return SE[id] end,
}
-- The engine's children iterator yields the child id as its first result.
function sim:get_children(npc)
	local index = 0
	return function()
		index = index + 1
		return npc.children[index]
	end
end
function alife() return sim end
function get_object_story_id() end
function alife_on_limit() return true end
function load_var(_, _, default) return default end
function save_var() end
game = { get_game_time = function() return { diffSec = function() return 0 end } end }
level.get_start_time = function() return 0 end
trade_manager = { get_trade_profile = function() end }
death_manager = { item_by_story_id = {} }
function IsItem() return false end
function IsWeapon(_, class) return class == "weapon" end
function IsAmmo(_, class) return class == "ammo" end
function IsGrenade() return false end
function IsArtefact() return false end
function size_table(t)
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	return count
end

sim_board = { simulation_board = {} }
SIMBOARD = setmetatable({ squads = {}, smarts = {} }, { __index = sim_board.simulation_board })
is_squad_monster = { mutant = true }
simulation_objects = {
	is_on_the_same_level = function(a, b) return a.m_game_vertex_id == b.m_game_vertex_id end,
}
xr_combat_ignore = { safe_zone_npcs = {} }
utils_obj = { graph_distance = function() return 10 end }
local ammo_source = source(corpus .. "item_weapon.script")
local ammo_start = assert(ammo_source:find("function remove_extra_ammo(", 1, true))
local ammo_end = assert(ammo_source:find("\nend", ammo_start)) + 3
load_module("item_weapon", corpus .. "item_weapon.script", ammo_source:sub(ammo_start, ammo_end))
local cleaner = load_module("release_npc_inventory", stock .. "release_npc_inventory.script")
local target_prior = load_module("target_prior", corpus .. "target_prior.script")

local function squad(id, map)
	local group = { id = id, m_game_vertex_id = map, player_id = "stalker", props = {} }
	function group:clsid() return clsid.online_offline_group_s end
	function group:target_precondition() return true end
	function group:evaluate_prior(other) return simulation_objects.evaluate_prior(self, other) end
	SE[id] = group
	return group
end

local function npc_on(id, map)
	local group = squad(id + 1, map)
	local npc = { id = id, m_game_vertex_id = map, children = {}, name = function() return "npc" end }
	SE[id] = npc
	SIMBOARD.squads[group.id] = true
	function group:squad_members()
		local member = npc
		return function()
			local current = member
			member = nil
			return current
		end
	end
	local function child(section, class)
		local item = spawn(section, vec3(0, 0, 0), npc.id, { offline = true })
		function item:clsid() return class end
		function item:name() return section end
		npc.children[#npc.children + 1] = item.id
		return item.id
	end
	return {
		medkit = child("medkit", "consumable"),
		ammo = { child("ammo_9x18", "ammo"), child("ammo_9x18", "ammo"), child("ammo_9x18", "ammo") },
		weapon = child("wpn_pm", "weapon"),
	}
end

local function ammo_left(inventory)
	local count = 0
	for _, id in ipairs(inventory.ammo) do
		if SE[id] then count = count + 1 end
	end
	return count
end

local function select_target(choosing, target)
	simulation_objects.object_registry = { target }
	simulation_objects.object_registry_size = 1
	simulation_objects.available_by_id = { [target.id] = true }
	return SIMBOARD:get_squad_target(choosing)
end

load_script("coop_mods_core")
local original_cleanup = cleaner.clean_npc_inv
local original_eval = simulation_objects.evaluate_prior
local original_same_level = target_prior.is_on_the_same_level
local function start_adapter()
	local file = io.open(ROOT .. "scripts/coop_srv_world_presence.script", "rb")
	if file then
		file:close()
		load_script("coop_srv_world_presence").on_game_start()
	end
end

for _, mode in ipairs({ "none", "hostplay", "srv_map" }) do
	MODE = mode == "none" and "sp" or "host"
	modes.install(load_script("coop_mode"), mode)
	start_adapter()
	check(cleaner.clean_npc_inv == original_cleanup and simulation_objects.evaluate_prior == original_eval
		and target_prior.is_on_the_same_level == original_same_level, mode .. ": keeps original functions")
end

modes.install(load_script("coop_mode"), "srv_world")
start_adapter()
players = {
	{ id = 1, avatar_id = 501, level = OCCUPIED, elsewhere = true },
	{ id = 2, avatar_id = 502, level = OTHER_PLAYER, elsewhere = true },
	{ id = 3, level = UNPLACED, elsewhere = true },
	{ id = 4, avatar_id = 504, level = DEAD, elsewhere = true },
}
life[504] = "dead"
held[100] = true
local held_inventory = npc_on(100, EMPTY)
local offline_inventory = npc_on(200, EMPTY)
local occupied_inventory = npc_on(300, OCCUPIED)
cleaner.on_game_start()
SendScriptCallback("actor_on_update")
check(SE[held_inventory.medkit] and ammo_left(held_inventory) == 3,
	"held_npc_preserves_child_consumables_and_ammo_on_empty_map")
check(SE[occupied_inventory.medkit] and ammo_left(occupied_inventory) == 3,
	"occupied_map_preserves_offline_npc_inventory")
check(not SE[offline_inventory.medkit] and ammo_left(offline_inventory) == 1 and SE[offline_inventory.weapon],
	"empty_map_cleans_offline_npc_by_stock_rules")
check(axr_main.count("actor_on_update") == 0, "stock_cleanup_unregisters_after_its_first_update")

local choosing = squad(600, OTHER_PLAYER)
local candidate = squad(601, OTHER_PLAYER)
check(select_target(choosing, candidate) == candidate, "target_prior_selects_squad_on_second_players_map")
candidate.m_game_vertex_id = EMPTY
check(select_target(choosing, candidate) == candidate, "target_prior_uses_selecting_squads_map")
choosing.m_game_vertex_id, candidate.m_game_vertex_id = GHOST, GHOST
check(select_target(choosing, candidate) == nil, "target_prior_ignores_world_server_ghost")
choosing.m_game_vertex_id = UNPLACED
check(select_target(choosing, candidate) == nil, "target_prior_ignores_peer_without_character")
choosing.m_game_vertex_id = DEAD
check(select_target(choosing, candidate) == nil, "target_prior_ignores_dead_character")
choosing.m_game_vertex_id = EMPTY
candidate.m_game_vertex_id = OCCUPIED
check(select_target(choosing, candidate) == nil, "target_prior_rejects_occupied_target_map_without_choosing_player")
choosing.m_game_vertex_id = OCCUPIED
xr_combat_ignore.safe_zone_npcs[candidate.id] = true
check(select_target(choosing, candidate) == nil, "target_prior_preserves_safe_zone")
xr_combat_ignore.safe_zone_npcs[candidate.id] = nil
check(simulation_objects.evaluate_prior(world_actor, choosing) == 0,
	"target_prior_preserves_actor_target_level_gate")

MODE = "sp"
choosing.m_game_vertex_id, candidate.m_game_vertex_id = GHOST, GHOST
check(select_target(choosing, candidate) == candidate, "inactive_session_uses_original_target_prior")
cleaner.clean_npc_inv(SE[100])
check(not SE[held_inventory.medkit] and ammo_left(held_inventory) == 1, "inactive_session_uses_original_cleanup")

done("srv_world_presence")
