-- Dev 57 G1-4. Real ALQ functions and PBA closure slices; no live-game reads.
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
local mode_sets = dofile("tests/lua/support/modes.lua")
load_script("coop_mode")
local function player_answers(name)
	-- S4's authority set, with the player-mirror answers for its player's machine.
	mode_sets.install(coop_mode, name, {
		actor_is_player = function() return player_actor end,
		is_player_mirror = function() return mirror end,
	})
end
player_answers("hostplay")
local clock = 1000
game.get_game_time = function() return clock end
utils_data = { CTimeToSec = function(t) return t end }
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
actor.active_item = function() return nil end
actor.money = function() return 10000 end
actor.get_current_outfit_protection = function() return 0 end
actor.item_in_slot = function() return nil end
local pba_src = source("temp/review/corpus/merged/perk_based_artefacts.script")
local pba = module("perk_based_artefacts", [[
local has_alife_info = has_alife_info
local virtual_artefacts = {}
local table_insert, table_sort = table.insert, table.sort
function trace() end
]] .. slice(pba_src, "iterate_belt = function(actor)", "refresh_artefacts = function(force)") .. [[
equip = {
]] .. slice(pba_src, "\taf_fire_loop = function(actor, artefact_count, artefact_ids, artefact_names)", "\n}\n") .. [[
}
function remove() disable_info("lucifer_active") end
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
bind_stalker_ext = {}
function bind_stalker_ext.actor_on_reinit() end
function bind_stalker_ext.actor_on_first_update(b)
	SendScriptCallback("actor_on_first_update", b)
end
local surge_src = source("temp/review/corpus/merged/surge_manager.script")
surge_manager = module("surge_manager", "CSurgeManager = {}\n" ..
	slice(surge_src, "function CSurgeManager:hit_power(", "function CSurgeManager:start_wave("))
local protection = setmetatable({}, { __index = surge_manager.CSurgeManager })
INI.drug_psy_blockade = { boost_telepat_protection = 0.03 }
INI.drug_radioprotector = { boost_radiation_protection = 0.01 }
INI.drug_antidot = { boost_chemburn_protection = 0.02 }
local function binder()
	local b = setmetatable({ object = actor }, { __index = bind_stalker.actor_binder })
	db.actor_binder = b
	return b
end
local squad = { id = 20, player_id = "stalker", commander_id = function() return 21 end,
	npc_count = function() return 1 end }
local _, npc = spawn("stalker", vec3(0, 0, 0), nil, { id = 21 })
local quest
function get_object_squad() return squad end
mob_trade = { GetTalkingNpc = function() return npc end }
dialogs = { who_is_npc = function() return npc end }
local goodwill = { [0] = -2000, [500] = 2000, [600] = -2000 }
coop_compat_alq = {
	is_client = function() return false end,
	goodwill_of = function(cid) return goodwill[cid] or 0 end,
	faction_of = function(cid) return cid == 500 and "stalker" or "bandit" end,
}
alq_core = { get_quest = function() return quest end, quests = {}, courier_packages = {}, QT_DELIVERY = "delivery",
	is_at_target = function() return false end, package_in_hands = function() return true end }
alq_mcm = { get_config = function(k) return k == "enabled" and true or k == "join_chance" and 50 or 0 end }
local ap = module("alq_player", source("temp/review/corpus/merged/alq_player.script"))
local ad = module("alq_dialogs", source("temp/review/corpus/merged/alq_dialogs.script"))
local real_random = math.random
math.random = function(a, b) return b and a or 50 end
local function new_quest(t)
	quest = t or { type = "delivery", target_id = 32, package_id = 33 }
	alq_core.quests[20] = quest
	return quest
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

for _, mode in ipairs({ "hostplay", "srv_map_same", "srv_map_other" }) do
	local prefix = mode .. ": "
	MODE, mirror, player_actor = "client", true, true
	player_answers(mode == "hostplay" and "hostplay" or "srv_map")
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
	actor:set_character_icon("outfit_override")
	check(b.character_icon == "returning_base", prefix .. "s34:6 outfit portrait does not replace saved base")
	clock = 2010
	NOW = NOW + 20000
	P.report_now()
	local piece = sent("mods.pd")
	local data = piece and coop_mods_core.deser(piece.d)
	check(data and data.coop_actor_drug_timers and data.coop_actor_drug_timers[timers[1]] == 20
		and data.coop_actor_base_icon == "returning_base", prefix .. "collector reads current pstor and binder base")
	clock = 9000
	MODE = "host" -- local host player and the map's quest authority use the same wrapped ALQ functions.
	mirror = false
	player_actor = mode == "hostplay"
	coop.is_map_server = function() return mode ~= "hostplay" end
	local q = new_quest({ type = "patrol", target_id = 32 })
	local before = ap.join_decision(squad, q, 500)
	check(before == true and ap.join_decision(squad, q, 0) == false,
		prefix .. "m18:4 join answers use each character's goodwill and faction")
	q = new_quest({ type = "patrol", target_id = 32, join = false, sell = true, price = 2300, trust = false, rob = true })
	check(ap.join_decision(squad, q, 500) == true and ap.join_decision(squad, q, 0) == false,
		prefix .. "m18:4 old scalar decisions migrate to cid 0 only")
	q = new_quest()
	ad.host_snapshot(npc, 500)
	check(q.join == nil and q.sell == nil and q.trust == nil and q.refuse == nil
		and q.coop_actor_decisions == nil, prefix .. "m18:4 proximity snapshot commits no decisions")
	ad.host_action("heard", npc, 500)
	local rich = ad.host_snapshot(npc, 500)
	ad.host_action("heard", npc, 600)
	local poor = ad.host_snapshot(npc, 600)
	check(rich.sell == true and rich.trust == true and poor.sell == false and poor.trust == false,
		prefix .. "m18:4 courier sell and trust decisions are per character")
	check(q.coop_actor_decisions and q.coop_actor_decisions[500] and q.coop_actor_decisions[600],
		prefix .. "m18:4 decisions live in saved quest keyed by cid")
	goodwill[600] = 4000
	poor = ad.host_snapshot(npc, 600)
	check(poor.sell == false and poor.trust == false,
		prefix .. "m18:4 a committed refusal remains false after goodwill changes")
	goodwill[600] = -2000
	q = new_quest({ type = "patrol", target_id = 32, join = false, sell = false, trust = false })
	ad.host_snapshot(npc, 500)
	check(q.join == false and q.sell == false and q.trust == false,
		prefix .. "m18:4 read-only snapshot preserves legacy false fields")
	MODE, mirror, player_actor = "client", true, true
	coop.is_map_server = function() return false end
	flags.lucifer_active = true
	local arts = pba.iterate_belt(actor)
	check(arts.af_lucifer == nil, prefix .. "m08:2 foreign Lucifer flag creates no personal artefact")
	local ring = spawn("af_fire_loop", vec3(0, 0, 0), 0)
	local n = #CREATED
	pba.equip.af_fire_loop(actor, 1, { ring.id }, {})
	check(#CREATED == n + 1 and actor:object("af_lucifer") ~= nil,
		prefix .. "m08:2 foreign Lucifer does not block own Fire Loop conversion")
	local own = actor:object("af_lucifer")
	NOW = NOW + 20000
	P.report_now()
	local pd = sent("mods.pd")
	local saved = pd and coop_mods_core.deser(pd.d)
	check(saved and saved.coop_actor_lucifer and saved.coop_actor_lucifer.active == true,
		prefix .. "m08:2 current Lucifer state is saved through pdata")
	if own then release_id(own:id()) end
	pba.remove()
	check(flags.lucifer_active == true and info_writes == 0,
		prefix .. "m08:2 removal never changes another player's world flag")
end

-- Script storage is restored before the engine has installed db.actor.
MODE, mirror, player_actor = "client", true, true
actor._icon = "early_base"
local early = binder()
db.actor = nil
local early_data = load_personal({ coop_actor_base_icon = "early_returning", coop_actor_drug_timers = { [timers[1]] = 19 } },
	{ foreign_icon = "foreign_early", foreign_pstor = { [timers[1]] = 99999 } })
db.actor = actor
early:load_state(early_data)
first(early)
check(early.character_icon == "early_returning" and load_var(actor, timers[1]) == clock + 19,
	"load before actor spawn: personal data waits for binder's pstor load")
actor._icon = "new_character_initial_base"
local reinit = binder()
bind_stalker_ext.actor_on_reinit(reinit)
actor._icon = "save_actor_icon"
local reinit_data = load_personal({}, { foreign_icon = "save_binder_icon", foreign_pstor = {} })
reinit:load_state(reinit_data)
first(reinit)
check(reinit.character_icon == "new_character_initial_base",
	"s34:6 new character's base is captured at reinit before save data or outfit applies")
actor._icon = ""
local unknown = binder()
local unknown_data = load_personal({}, { foreign_icon = "foreign_unknown", foreign_pstor = {} })
unknown:load_state(unknown_data)
check(unknown.character_icon == nil, "s34:6 missing own base never falls back to foreign saved portrait")

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

MODE, player_actor, mirror = "host", false, false
mode_sets.install(coop_mode, "srv_world")
coop.is_map_server = function() return false end
coop.is_dedicated = function() return true end
db.actor = nil
local q = new_quest({ type = "patrol", target_id = 32 })
check(ap.join_decision(squad, q, 500) == true and ap.join_decision(squad, q, 600) == false,
	"srv_world: ALQ decision path needs no local actor or map")
db.actor = actor
coop.is_dedicated = function() return false end
player_actor = true
mode_sets.install(coop_mode, "hostplay")
goodwill[0] = 4000
q = new_quest()
ad.reply_text()
check(ad.pre_sell_ok() and ad.pre_can_pay(), "hostplay own dialog: personal price is visible to payment precondition")
local refusal = new_quest({ type = "patrol", target_id = 32, join = false })
ap.join_decision(squad, refusal, 500)
check(ap.join_decision(squad, refusal, 0) == false, "hostplay own dialog: old false survives another character's migration")

MODE, player_actor = "sp", true
mode_sets.install(coop_mode, "none")
local b = binder()
b:load_state({ foreign_icon = "sp_base", foreign_pstor = { [timers[1]] = 12345 } })
first(b)
q = new_quest({ type = "patrol", join = true })
check(load_var(actor, timers[1]) == 12345 and b.character_icon == "sp_base",
	"none: stock timers and portrait remain unchanged")
check(ap.join_decision(squad, q, 600) == true and q.coop_actor_decisions == nil,
	"none: original single-player ALQ scalar decision remains unchanged")
local arts = pba.iterate_belt(actor)
check(arts.af_lucifer ~= nil, "none: original single-player Lucifer flag remains unchanged")
math.random = real_random
done("PDATA ACTOR")
