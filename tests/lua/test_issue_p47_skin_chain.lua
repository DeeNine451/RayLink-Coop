-- TZ P47 (Dev 58, owner 2026-11-22: "the butchering animations broke"). In a session the FDDA skinning animation is
-- started by coop_mods_xchg_fdda for the parts the loot window's own Loot call gives (Dev 57 G4-4, review m10:5).
-- G.A.M.M.A. wraps ui_mutant_loot.UIMutantLoot.Loot before co-op does: Immersive Skinning at its on_game_start (and
-- Momopate's savescummer at load, our coop_world_fx_mods for Immersive Skinning). The function that calls
-- alife_create_item is then the stock Loot at the bottom of that chain, not the function co-op wrapped.
-- Real code: ui_mutant_loot's Loot / SetMutantState / Close, immersive_skinning, liz_fdda_redone_mutant_skinning (from
-- the G.A.M.M.A. scripts, GAMMA_SCRIPTS), coop_mods_xchg_fdda from the tree.
--   Coop:   the host player skins; a client skins.
--   Server: the player's machine skins; the map server's and the world server's own actors never animate.
--   Single player: FDDA's own subscription, as the mod made it.
-- P47_FDDA_SCRIPT=<path> runs a candidate coop_mods_xchg_fdda.script instead of the tree's (a patch before it is applied).
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")

local BS = string.char(92)
local actor = make_actor(vec3(0, 0, 0))
for _, callback in ipairs({ "GUI_on_show", "GUI_on_hide", "game_object_on_net_destroy", "actor_on_net_destroy",
	"actor_on_item_before_pickup", "ActorMenu_on_item_drag_drop" }) do
	AddScriptCallback(callback)
end

local options = { ["skinning/enable"] = true, ["skinning/auto_loot_all"] = false, ["skinning/every_part_pickup"] = false }
liz_fdda_redone_mcm = { get_config = function(key) return options[key] end }
local config_ini = ini_file
ini_file = function(name)
	if type(name) == "string" and name:find("items" .. BS, 1, true) == 1 then
		return {
			section_exist = function() return false end, line_count = function() return 0 end,
			r_string_ex = function() return nil end, r_float_ex = function() return nil end,
		}
	end
	return config_ini(name)
end
local next_cls = 100
clsid = setmetatable({ wpn_knife_s = 1, boar_s = 2, crow = 3 }, { __index = function(t, k)
	next_cls = next_cls + 1
	rawset(t, k, next_cls)
	return next_cls
end })
INI.meat, INI.hide, INI.dead_boar = {}, {}, {}

-- engine and stock helpers the real scripts call
local SVAR, OVAR = {}, {}
function se_save_var(id, _, key, value) SVAR[id] = SVAR[id] or {}; SVAR[id][key] = value end
function se_load_var(id, _, key) return SVAR[id] and SVAR[id][key] end
function save_var(obj, key, value) local id = obj:id(); OVAR[id] = OVAR[id] or {}; OVAR[id][key] = value end
function load_var(obj, key, default)
	local v = OVAR[obj:id()] and OVAR[obj:id()][key]
	if v == nil then return default end
	return v
end
function dup_table(t)
	local out = {}
	for k, v in pairs(t) do out[k] = type(v) == "table" and dup_table(v) or v end
	return out
end
function is_not_empty(t) return t ~= nil and next(t) ~= nil end
function SYS_GetParam(_, _, _, default) return default end
alife_storage_manager = { get_state = function() return { se_object = {} } end }
ui_options = { get = function() return false end }
local nested_give -- a section an unrelated callback inside Loot gives the actor (knife wear as a stand-in)
item_knife = { knifes = {}, degradate = function()
	if nested_give then alife_create_item(nested_give, db.actor) end
end }
game_achievements = { has_achievement = function() return false end }
game_statistics = { increment_statistic = function() end }
xr_sound.set_sound_play = function() end
xr_corpse_detection = { set_valuable_loot = function() end }
function Register_UI(name) SendScriptCallback("GUI_on_show", name) end
function Unregister_UI(name) SendScriptCallback("GUI_on_hide", name) end
actor_effects = { play_item_fx = function() end, is_animations_on = function() return true end }
actor.item_in_slot = function() return nil end
actor.active_item = function() return nil end

local actions = {}
lam2 = {
	states = { success = 1 },
	is_running = function() return #actions > 0 end,
	get_template_action_play_animation = function() return {} end,
	get_template_action_wait_for_seconds = function() return { name = "close_wait" } end,
	add_action = function(action) actions[#actions + 1] = action end,
	log = function() end,
}

-- The engine gives a created part to the inventory later (a client: with the host's answer): hold it until arrive().
local queued = {}
local stock_create = alife_create_item
function alife_create_item(section, owner, props)
	local se = stock_create(section, owner, props)
	queued[#queued + 1] = OBJ[se.id]
	OBJ[se.id] = nil
	return se
end
local function arrive(obj)
	OBJ[obj:id()] = obj
	SendScriptCallback("actor_on_item_take", obj)
end

-- A G.A.M.M.A. script as CScriptStorage loads it: its own module table over _G, the real file as the chunk name.
local function gamma_path(name)
	local path = GAMMA_DIR .. BS .. name .. ".script"
	assert(have_file(path), "real G.A.M.M.A. script required (GAMMA_SCRIPTS): " .. path)
	return path
end
local function gamma_module(name)
	local path = gamma_path(name)
	local fh = assert(io.open(path, "rb"))
	local src = fh:read("*a")
	fh:close()
	local f = assert(loadstring(src, "@" .. path))
	local env = rawget(_G, name)
	if type(env) ~= "table" then
		env = {}
		rawset(_G, name, env)
	end
	setmetatable(env, { __index = _G })
	setfenv(f, env)()
	return env
end

-- ui_mutant_loot: the stock class methods that run in a loot (the window itself is a CUIScriptWnd of the engine).
ui_mutant_loot = { UIMutantLoot = {}, start = function() end }
setmetatable(ui_mutant_loot, { __index = _G })
assert(mod_chunk(gamma_path("ui_mutant_loot"), { "function UIMutantLoot:Loot(loot_all)",
	"function UIMutantLoot:SetMutantState(is_more_loot, obj_mutant)", "function UIMutantLoot:Close()" }, "ui_mutant_loot",
	"return true"))
local stock_loot = ui_mutant_loot.UIMutantLoot.Loot

-- Load order of the game: the addons' files and on_game_start, then co-op's scripts, then the first actor update.
local IS = gamma_module("immersive_skinning")
local S = gamma_module("liz_fdda_redone_mutant_skinning")
start_all()
local mode_set = modes.install(coop_mode, mode)
local X = load_script("coop_mods_xchg")
X.on_game_start()
IS.on_game_start()
S.on_game_start()
S.initialize()
check(ui_mutant_loot.UIMutantLoot.Loot ~= stock_loot,
	mode .. ": G.A.M.M.A.'s Immersive Skinning wraps UIMutantLoot.Loot at its on_game_start")
-- The animation templates read the HUD sections of the game; the test sees which ones FDDA asks for and on what.
S.get_template_action_mutant_skin = function(obj) return { name = "skin", target = obj } end
S.get_template_action_mutant_loot = function(obj) return { name = "part", target = obj } end

local candidate = os.getenv("P47_FDDA_SCRIPT")
local function load_fdda()
	if not (candidate and candidate ~= "") then return load_script("coop_mods_xchg_fdda") end
	local fh = assert(io.open(candidate, "r"), candidate)
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} coop_mods_xchg_fdda = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	assert(loadstring(header .. src, "@D:" .. BS .. "Games" .. BS .. "Anomaly" .. BS .. "gamedata" .. BS .. "scripts" .. BS
		.. "coop_mods_xchg_fdda.script"))()
	return rawget(_G, "coop_mods_xchg_fdda")
end
load_fdda().on_game_start()
local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end
SendScriptCallback("actor_on_first_update")
tick()

local function count_actions(name, target)
	local n = 0
	for _, action in ipairs(actions) do
		if action.name == name and (target == nil or rawequal(action.target, target)) then n = n + 1 end
	end
	return n
end
local function corpse()
	local _, obj = spawn("dead_boar", vec3(1, 0, 1), nil, { alive = false, kind = "monster" })
	obj.name = function(self) return "dead_boar" .. tostring(self:id()) end
	obj.clsid = function() return clsid.boar_s end
	obj.set_bone_visible = function() end
	return obj
end
-- The player opens the window on a body (the host granted it in a session) and presses "loot all".
local function open_and_loot(body, sections)
	actions, queued = {}, {}
	local loot = {}
	for _, section in ipairs(sections) do loot[section] = { count = (loot[section] and loot[section].count or 0) + 1 } end
	local gui = setmetatable({ id = body:id(), obj = body, section = body:section(), clsid = body:clsid(), loot = loot,
		ShowDialog = function() end, HideDialog = function() end, IsShown = function() return true end },
		{ __index = ui_mutant_loot.UIMutantLoot })
	ui_mutant_loot.GUI = gui
	SendScriptCallback("GUI_on_show", "UIMutantLoot")
	gui:Loot(true)
	return gui
end
local function arrive_all(from)
	for i = from or 1, #queued do
		arrive(queued[i])
		tick()
	end
end

local function skins(who)
	local body = corpse()
	open_and_loot(body, { "meat", "meat" })
	local made = #queued
	arrive_all()
	check(made == 2 and count_actions("skin", body) == 1 and count_actions("part") == 1,
		mode .. ": " .. who .. " - the FDDA skinning animation plays on the body and the first part animates")

	-- An item an unrelated callback gives the actor inside the same Loot call is not one of this window's parts.
	body = corpse()
	nested_give = "meat"
	open_and_loot(body, { "meat" })
	nested_give = nil
	local nested = queued[1]
	local own = queued[2]
	if nested then arrive(nested) end
	tick()
	check(#queued == 2 and count_actions("skin") == 0 and count_actions("part") == 0,
		mode .. ": " .. who .. " - an item a nested callback gave during Loot does not start the animation")
	if own then arrive(own) end
	tick()
	check(count_actions("skin", body) == 1 and count_actions("part") == 1,
		mode .. ": " .. who .. " - the window's own part still animates once")
end

local function never_animates(who)
	local body = corpse()
	open_and_loot(body, { "meat" })
	arrive_all()
	check(#queued == 1 and count_actions("skin") == 0 and count_actions("part") == 0,
		mode .. ": " .. who .. " - gives the part and never animates")
end

if mode == "hostplay" then
	skins("Coop host player")
elseif mode == "srv_map" then
	never_animates("Server, the map server's own actor")
elseif mode == "srv_world" then
	never_animates("Server, the world server's own actor")
end

if mode == "hostplay" or mode == "srv_map" then
	-- The player's machine: a Coop client, or a player's game in Server mode (a mirror of the map server's level).
	MODE, SELF = "client", 1
	modes.install(coop_mode, mode, {
		actor_is_player = function() return true end, leads_here = function() return false end,
		is_player_mirror = function() return true end, decides_world = function() return false end,
	})
	skins(mode == "hostplay" and "Coop client" or "Server player's machine")
elseif mode == "none" then
	local body = corpse()
	open_and_loot(body, { "meat", "meat" })
	arrive_all()
	check(count_actions("skin", body) == 1 and count_actions("part") == 1 and count_actions("close_wait") == 1,
		"single player: FDDA's own subscription animates through the wrapped Loot, as the mod made it")
end

done("issue_p47_skin_chain@" .. mode)
