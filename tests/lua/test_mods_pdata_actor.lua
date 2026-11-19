-- Dev 57 G1-4. Real PBA closure slices; no live-game reads.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local function source(path)
	local f = assert(io.open(path, "rb"), path)
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end
local function module(name, s)
	local m = setmetatable({}, { __index = _G })
	_G[name] = m
	local f = assert(loadstring(s, "@" .. name .. ".script"))
	setfenv(f, m)
	f()
	return m
end
local function slice(s, first, last)
	local a = assert(s:find(first, 1, true), first)
	local b = assert(s:find(last, a + #first, true), last)
	return s:sub(a, b - 1)
end
local actor = make_actor()
local player_actor, mirror = true, true
local modes = dofile("tests/lua/support/modes.lua")
local selected = {}
for _, name in ipairs(modes.names()) do selected[name] = true end
load_script("coop_mode")
local function player_answers(name, other_map)
	modes.install(coop_mode, name, {
		actor_is_player = function() return player_actor end,
		is_player_mirror = function() return mirror end,
		leads_here = function() return not mirror end,
		decides_world = function() return not mirror and name == "hostplay" end,
		where = function(peer) return other_map and peer == 2 and "away" or "here" end,
		decider = function(peer) return (mirror or other_map and peer == 2) and "other" or "this" end,
	})
end
player_answers("hostplay")
local clock = 1000
game.get_game_time = function() return clock end
utils_data = { CTimeToSec = function(t) return t end, CTimeAddSec = function(t, s) return t + s end }
db.storage[0] = { pstor = {} }
function load_var(o, k) return db.storage[o:id()].pstor[k] end
function save_var(o, k, v) db.storage[o:id()].pstor[k] = v end
local flags, info_writes = { lucifer_active = true }, 0
function has_alife_info(k) return flags[k] == true end
function give_info(k) flags[k] = true; info_writes = info_writes + 1 end
function disable_info(k) flags[k] = nil; info_writes = info_writes + 1 end
actor.character_icon = function(self) return self._icon or "own_base" end
actor.set_character_icon = function(self, v) self._icon = v end
actor.iterate_belt = function() end
local object = get_object_by_id
function get_object_by_id(id)
	local o = object and object(id) or OBJ[id]
	if o and not o.name then o.name = function(self) return self:section() end end
	return o
end
local actor_object = actor.object
actor.object = function(self, ...)
	local o = actor_object(self, ...)
	return o and get_object_by_id(o:id())
end
actor.get_current_outfit_protection = function() return 0 end
local pba_src = source("temp/review/corpus/merged/perk_based_artefacts.script")
local pba = module("perk_based_artefacts", [[
local has_alife_info = has_alife_info
local virtual_artefacts = {}
local table_insert, table_sort = table.insert, table.sort
function trace() end
]] .. slice(pba_src, "iterate_belt = function(actor)", "refresh_artefacts = function(force)") .. [[
artefact_on_equip_functions = {
]] .. slice(pba_src, "\taf_fire_loop = function(actor, artefact_count, artefact_ids, artefact_names)", "\n}\n") .. [[
}
local artefacts = {}
local properties = {
	check_lucifer = function(self) return artefacts.af_lucifer end,
]] .. slice(pba_src, "\t\tremove_lucifer = function(self)", "\t\tset_condition = function(self") .. [[
}
function remove()
	artefacts = iterate_belt(db.actor)
	properties:remove_lucifer()
end
function unrelated() return has_alife_info("other") end
]])
function alife_release_id(id) release_id(id) end
function play_sound_on_actor() end

-- The stock's load order: pstor overwrites memory; first-update callbacks precede applying the base icon.
bind_stalker = { actor_binder = {} }
function bind_stalker.actor_binder:load_state(m)
	db.storage[0].pstor = m.foreign_pstor or {}
	self.character_icon = m.foreign_icon
end
function bind_stalker.actor_binder:load(m) self:load_state(m) end
local stock_ext = source("temp/stock_scripts/scripts/bind_stalker_ext.script")
local ext = module("bind_stalker_ext", [[
function actor_on_reinit() end
]] .. slice(stock_ext, "function actor_on_first_update(", "function actor_on_update(") ..
	slice(stock_ext, "function actor_on_item_use(", "function actor_on_trade(") ..
	slice(stock_ext, "function actor_item_to_slot(", "function actor_on_weapon_reload("))
level.get_time_factor = function() return 10 end
ui_options = { get = function(k) return k == "gameplay/general/outfit_portrait" end }
local equipped_outfit
actor.item_in_slot = function(_, slot) return slot == 7 and equipped_outfit or nil end
function IsOutfit(o) return o and o:section() == "rv_outfit" end
INI.rv_outfit = { character_portrait = "outfit_override" }
local outfit = { id = function() return 901 end, section = function() return "rv_outfit" end }
local surge_src = source("temp/stock_scripts/scripts/surge_manager.script")
surge_manager = module("surge_manager", "CSurgeManager = {}\n" ..
	slice(surge_src, "function CSurgeManager:hit_power(", "function CSurgeManager:start_wave("))
local protection = setmetatable({}, { __index = surge_manager.CSurgeManager })
INI.drug_psy_blockade = { boost_telepat_protection = 0.03, boost_time = 3 }
INI.drug_radioprotector = { boost_radiation_protection = 0.01, boost_time = 4 }
INI.drug_antidot = { boost_chemburn_protection = 0.02, boost_time = 5 }
local function binder()
	local b = setmetatable({ object = actor }, { __index = bind_stalker.actor_binder })
	db.actor_binder = b
	return b
end
load_script("coop_main").on_game_start()
load_script("coop_mods_core").on_game_start()
load_script("coop_mods_pdata").on_game_start()
local adapter
local adapter_file = io.open("gamedata/scripts/coop_mods_pdata_actor.script", "rb")
if adapter_file then
	adapter_file:close()
	adapter = load_script("coop_mods_pdata_actor")
	adapter.on_game_start()
end
local P = coop_mods_pdata
local timers = { "drug_psy_blockade_expiration", "drug_radioprotector_expiration", "drug_antidot_expiration" }
local function load_personal(d, foreign)
	STASH.coop_mods_pdata = nil
	local m = foreign or {}
	m.coop_mods_pdata = { ["500"] = { t = "T", d = d or {} } }
	alife_storage_manager.CALifeStorageManager_load(m)
	return m
end
local function first(b)
	bind_stalker_ext.actor_on_first_update(b)
	if b.character_icon then actor:set_character_icon(b.character_icon) end
end

local function player_scenario(mode, other_map)
	local layer = mode == "hostplay" and mode or "srv_map"
	local prefix = mode .. ": "
	MODE, mirror, player_actor = "client", true, true
	player_answers(layer, other_map)
	coop.is_map_server = function() return false end
	actor._icon = "own_base"
	local b = binder()
	local foreign = { foreign_icon = "host_base", foreign_pstor = {} }
	for _, k in ipairs(timers) do foreign.foreign_pstor[k] = 99999 end
	protection.drug_telepatic_protection = 1
	protection.drug_radiation_protection = 1
	protection.drug_chemical_burn_protection = 1
	local m = load_personal({}, foreign)
	b:load_state(m)
	first(b)
	check(load_var(actor, timers[1]) == nil and load_var(actor, timers[2]) == nil and load_var(actor, timers[3]) == nil,
		prefix .. "s34:3 new character clears all foreign drug timers after pstor")
	check(protection:hit_power(1, 4) == 1 and protection:hit_power(1, 3) == 1 and protection:hit_power(1, 2) == 1,
		prefix .. "s34:3 absent timers clear cached protection before calculation")
	check(b.character_icon == "own_base" and actor:character_icon() == "own_base",
		prefix .. "s34:6 new character uses own base portrait")
	local d = { coop_actor_drug_timers = { [timers[1]] = 30, [timers[2]] = 40, [timers[3]] = 50 },
		coop_actor_base_icon = "returning_base", coop_actor_lucifer = { active = false } }
	clock = 2000
	m = load_personal(d, foreign)
	b:load_state(m)
	first(b)
	check(load_var(actor, timers[1]) == 2030 and load_var(actor, timers[2]) == 2040 and load_var(actor, timers[3]) == 2050,
		prefix .. "s34:3 returning character restores remaining game seconds")
	check(b.character_icon == "returning_base", prefix .. "s34:6 returning base restored before first apply")
	equipped_outfit = outfit
	ext.actor_item_to_slot(b, outfit)
	check(actor:character_icon() == "outfit_override" and b.character_icon == "returning_base",
		prefix .. "s34:6 stock outfit portrait does not replace saved base")
	equipped_outfit = nil
	ext.actor_item_to_ruck(b, outfit)
	check(actor:character_icon() == "returning_base", prefix .. "s34:6 removing the outfit shows the own base")
	for _, drug in ipairs({ "drug_psy_blockade", "drug_radioprotector", "drug_antidot" }) do
		ext.actor_on_item_use(b, { section = function() return drug end })
	end
	clock = 2010
	NOW = NOW + 20000
	P.report_now()
	local piece = sent("mods.pd")
	local data = piece and coop_mods_core.deser(piece.d)
	check(data and data.coop_actor_drug_timers and data.coop_actor_drug_timers[timers[1]] == 20
		and data.coop_actor_base_icon == "returning_base", prefix .. "collector reads current pstor and binder base")
	local bad = binder()
	m = load_personal({ coop_actor_drug_timers = { [timers[1]] = -1, [timers[2]] = 1e8, [timers[3]] = "50" } }, foreign)
	bad:load_state(m)
	check(load_var(actor, timers[1]) == nil and load_var(actor, timers[2]) == clock + 7 * 24 * 3600
		and load_var(actor, timers[3]) == nil, prefix .. "the three loaded duration values are bounded and type-checked")
	clock = 9000
	flags.lucifer_active = true
	local arts = pba.iterate_belt(actor)
	check(arts.af_lucifer == nil, prefix .. "m08:2 foreign Lucifer flag creates no personal artefact")
	local ring = spawn("af_fire_loop", vec3(0, 0, 0), 0)
	local n = #CREATED
	pba.artefact_on_equip_functions.af_fire_loop(actor, 1, { ring.id }, {})
	check(#CREATED == n + 1 and actor:object("af_lucifer") ~= nil,
		prefix .. "m08:2 foreign Lucifer does not block own Fire Loop conversion")
	local own = actor:object("af_lucifer")
	local spare = spawn("af_fire_loop", vec3(0, 0, 0), 0)
	flags.lucifer_active = nil
	n = #CREATED
	pba.artefact_on_equip_functions.af_fire_loop(actor, 1, { spare.id }, {})
	check(#CREATED == n and OBJ[spare.id], prefix .. "m08:2 own Lucifer still blocks another conversion")
	if OBJ[spare.id] then release_id(spare.id) end
	flags.lucifer_active = true
	ext.actor_on_item_use(b, { section = function() return "drug_psy_blockade" end })
	NOW = NOW + 20000
	P.report_now()
	local pd, report = sent("mods.pd")
	local saved = pd and coop_mods_core.deser(pd.d)
	check(saved and saved.coop_actor_lucifer and saved.coop_actor_lucifer.active == true,
		prefix .. "m08:2 current Lucifer state is saved through pdata")
	pba.remove()
	check(actor:object("af_lucifer") == nil and flags.lucifer_active == true and info_writes == 0,
		prefix .. "m08:2 stock removal releases only the actor's Lucifer and leaves the world flag")
	if own and actor:object("af_lucifer") then release_id(own:id()) end
	local create = alife_create_item
	local queued = 0
	alife_create_item = function(section)
		if section == "af_lucifer" then queued = queued + 1 end
	end
	ring = spawn("af_fire_loop", vec3(0, 0, 0), 0)
	local second = spawn("af_fire_loop", vec3(0, 0, 0), 0)
	pba.artefact_on_equip_functions.af_fire_loop(actor, 1, { ring.id }, {})
	pba.artefact_on_equip_functions.af_fire_loop(actor, 1, { second.id }, {})
	check(queued == 1 and actor:object("af_fire_loop") ~= nil and pba.iterate_belt(actor).af_lucifer == nil,
		prefix .. "m08:2 a queued conversion cannot duplicate or create a phantom Lucifer")
	alife_create_item = create
	if OBJ[ring.id] then release_id(ring.id) end
	if OBJ[second.id] then release_id(second.id) end

	-- Send the captured report through the receiver under transport peer 1.
	-- Peer 2 has a separate record, including when his map is elsewhere.
	local peer2 = { t = "peer-2", d = { coop_actor_base_icon = "other_player", coop_actor_lucifer = { active = false } } }
	local authority = { coop_actor_base_icon = "authority_base", coop_mods_pdata = { ["600"] = peer2 } }
	MODE, SELF = "host", 0
	modes.install(coop_mode, layer == "hostplay" and "hostplay" or "srv_world")
	if layer ~= "hostplay" then db.actor = nil end
	alife_storage_manager.CALifeStorageManager_load(authority)
	if report then deliver(report, 1) end
	local record = authority.coop_mods_pdata["500"]
	check(record and record.d.coop_actor_base_icon == "returning_base"
		and record.d.coop_actor_drug_timers[timers[1]] == 30 and record.d.coop_actor_lucifer.active
		and authority.coop_mods_pdata["600"] == peer2,
		prefix .. "transport saves the report under its sender's character")
	MODE, SELF = "client", 1
	db.actor = actor
	player_answers(layer, other_map)
	STASH.coop_mods_pdata = nil
	clock = 3000
	actor._icon, flags.lucifer_active = "new_spawn_base", nil
	local lu = spawn("af_lucifer", vec3(0, 0, 0), 0) -- the engine separately restores the inventory
	alife_storage_manager.CALifeStorageManager_load(authority)
	local reconnect = binder()
	reconnect:load_state(foreign)
	first(reconnect)
	check(reconnect.character_icon == "returning_base" and load_var(actor, timers[1]) == 3030
		and pba.iterate_belt(actor).af_lucifer ~= nil,
		prefix .. "reconnect restores the sender's timer and portrait and sees Lucifer without a world flag")
	release_id(lu.id)
end

if selected.hostplay then player_scenario("hostplay") end
if selected.srv_map then
	player_scenario("srv_map_same")
	player_scenario("srv_map_other", true)
end

if selected.hostplay or selected.srv_map then
	player_answers(selected.hostplay and "hostplay" or "srv_map")
	-- Script storage is restored before the engine has installed db.actor.
	MODE, mirror, player_actor = "client", true, true
	actor._icon = "early_base"
	local early = binder()
	db.actor = nil
	local early_data = load_personal({ coop_actor_base_icon = "early_returning", coop_actor_drug_timers = { [timers[1]] = 19 } },
		{ foreign_icon = "foreign_early", foreign_pstor = { [timers[1]] = 99999 } })
	early:load_state(early_data)
	db.actor = actor
	check(early.character_icon == "early_returning" and load_var(actor, timers[1]) == clock + 19,
		"stock packet order: the binder restores personal data before db.actor is assigned")
	first(early)
	check(early.character_icon == "early_returning" and load_var(actor, timers[1]) == clock + 19,
		"load before actor spawn: personal data waits for binder's pstor load")
	actor._icon = "new_character_initial_base"
	local reinit = binder()
	db.actor = nil
	bind_stalker_ext.actor_on_reinit(reinit)
	actor._icon = "save_actor_icon"
	local reinit_data = load_personal({}, { foreign_icon = "save_binder_icon", foreign_pstor = {} })
	reinit:load_state(reinit_data)
	db.actor = actor
	first(reinit)
	check(reinit.character_icon == "new_character_initial_base",
		"s34:6 new character's base is captured at reinit before save data or outfit applies")
	actor._icon = ""
	local unknown = binder()
	local unknown_data = load_personal({}, { foreign_icon = "foreign_unknown", foreign_pstor = {} })
	unknown:load_state(unknown_data)
	check(unknown.character_icon == nil, "s34:6 missing own base never falls back to foreign saved portrait")
	local own_id = coop.to_host_id
	coop.to_host_id = function(id) if id ~= 0 then return own_id(id) end end
	actor._icon = "unmapped_own_base"
	local unmapped = binder()
	local unmapped_data = load_personal({}, { foreign_icon = "host_saved",
		coop_actor_base_icon = "host_base",
		coop_actor_drug_timers = { [timers[1]] = 50 },
		foreign_pstor = { [timers[1]] = 999999 } })
	coop.to_host_id = own_id
	unmapped:load_state(unmapped_data)
	first(unmapped)
	check(load_var(actor, timers[1]) == nil and unmapped.character_icon == "unmapped_own_base",
		"s34:3/s34:6 absent character mapping cannot restore host-owned top-level pdata")

	-- The existing pdata transport must collect live state at departure, not at its last poll.
	actor._icon = "transition_base"
	local transition = binder()
	local tm = load_personal({ coop_actor_base_icon = "transition_base" }, { foreign_icon = "host_base", foreign_pstor = {} })
	transition:load_state(tm)
	first(transition)
	save_var(actor, timers[1], clock + 12)
	coop.world_epoch = function() return 44 end
	P.keep_for_load(45)
	local kept = STASH.coop_mods_pdata
	check(kept and kept:sub(1, 9) == "@load:45|", "departure: pdata captures live actor state immediately")
	clock = clock + 100000
	coop.world_epoch = function() return 45 end
	local transit_data = { foreign_icon = "new_host_base", foreign_pstor = { [timers[1]] = 999999 },
		coop_mods_pdata = { ["500"] = { t = "new-token", d = {} } } }
	alife_storage_manager.CALifeStorageManager_load(transit_data)
	transition:load(transit_data)
	first(transition)
	check(load_var(actor, timers[1]) == clock + 12 and transition.character_icon == "transition_base",
		"transition packet load: own remaining seconds and base survive a new world clock and token")
end

if selected.srv_world then
	MODE, player_actor, mirror = "host", false, false
	modes.install(coop_mode, "srv_world")
	coop.is_map_server = function() return false end
	coop.is_dedicated = function() return true end
	check(pba.iterate_belt(actor).af_lucifer == nil, "srv_world: the ghost actor ignores the shared Lucifer flag")
	coop.is_dedicated = function() return false end
end

if selected.none then
	MODE, player_actor = "sp", true
	modes.install(coop_mode, "none")
	flags.lucifer_active = true
	local b = binder()
	b:load_state({ foreign_icon = "sp_base", foreign_pstor = { [timers[1]] = 12345 } })
	first(b)
	check(load_var(actor, timers[1]) == 12345 and b.character_icon == "sp_base",
		"none: stock timers and portrait remain unchanged")
	local arts = pba.iterate_belt(actor)
	check(arts.af_lucifer ~= nil, "none: original single-player Lucifer flag remains unchanged")
end

done("PDATA ACTOR")
