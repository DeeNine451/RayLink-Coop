-- Dev 57 G9-3. Real GAMMA effects and validators over the mod/engine fixtures.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")

local corpus = "temp/review/corpus/merged/"
local function mod_path(name)
	local path = corpus .. name .. ".script"
	return have_file(path) and path or GAMMA_DIR .. "/" .. name .. ".script"
end
local distributed = mode == "srv_map" or mode == "srv_world"
local on_map = mode == "hostplay" or mode == "srv_map"
local fdda = mode ~= "srv_map"
local away = {}
coop.is_map_server = function() return mode == "srv_map" end
coop.is_dedicated = function() return mode == "srv_world" end
coop.avatar_of = function(peer) return ({ [0] = 0, [1] = 500, [2] = 502 })[peer] end
coop.peer_of_avatar = function(id) return ({ [0] = 0, [500] = 1, [502] = 2 })[id] end

local actor = make_actor()
local _, first = spawn("coop_player_npc", vec3(1, 0, 0), nil, { id = 500, kind = "stalker" })
local _, second = spawn("coop_player_npc", vec3(2, 0, 0), nil, { id = 502, kind = "stalker" })
actor.character_rank = function() return 0 end
first.character_rank = function() return 1000 end
second.character_rank = function() return 0 end

local function body(id)
	local _, corpse = spawn("stalker", vec3(1, 0, 0), nil, { id = id, kind = "stalker", alive = false })
	corpse.name = function() return "corpse_" .. id end
	local inventory = corpse.iterate_inventory
	corpse.iterate_inventory = function(self, f, o)
		local items = {}
		inventory(self, function(_, item) items[#items + 1] = item end, o)
		for _, item in ipairs(items) do f(o, item) end
	end
	spawn("bandage", corpse:position(), id)
	spawn("story_item", corpse:position(), id)
	return corpse
end

local dropped = {}
function se_load_var(id, _, key) if key == "death_dropped" then return dropped[id] end end
function se_save_var(id, _, key, value) if key == "death_dropped" then dropped[id] = value end end
ranks = { get_obj_rank_name = function() return "veteran" end }
IsOutfit = function() return false end
IsHeadgear = function() return false end
ui_inventory = {}
lam2 = { log = function() end }
coop_progress_check = { skill_of = function(character, skill)
	assert(skill == "scavenging")
	return character == 500 and 10 or 0, character == 500 or character == 502
end }

local eco_mode, chance, roll = 2, 100, 40
local mod_math = setmetatable({ random = function() return roll end }, { __index = math })
local harness_alife = alife
local function stock_sim()
	local sim = harness_alife()
	sim.actor = function() return { rank = function() return actor:character_rank() end } end
	return sim
end
INI.test_armour = { cost = 35000 }
INI.army_nosorog_outfit = { cost = 35000 }
game_difficulties = { get_eco_factor = function() return eco_mode end }
death_manager = {
	alife = stock_sim, math = mod_math,
	o_cost_start = 25000, o_rank_multi = 20, o_helm_multi = 3,
	create_release_item = function(npc) se_save_var(npc:id(), npc:name(), "death_dropped", true) end,
}
assert(mod_chunk(mod_path("death_manager"), { "function validate_drop(" }, "death_manager",
	'rare_armors = { army_nosorog_outfit = true }; return true'))
outfit_drop_mcm = {
	math = mod_math, ValidateDrop = death_manager.validate_drop,
	get_config = function() return chance end, print_dbg = function() end,
	SYS_GetParam = function() return "outfit_medium" end,
}
assert(mod_chunk(mod_path("outfit_drop_mcm"), { "function death_manager.validate_drop(" },
	"outfit_drop_mcm", "return true"))

haru_skills = setmetatable({
	math = mod_math, utils_data = {}, haru_skills_mcm = {},
	ini_file_ex = function() return { collect_section = function(_, name)
		assert(name == "scavenging_stats")
		return { scavenging_skill = "-20", scavenging_skill_increment = "10" }
	end } end,
}, { __index = _G })
local haru_chunk = assert(loadfile(mod_path("haru_skills")))
setfenv(haru_chunk, haru_skills)()
haru_skills.skills_levels.scavenging = { experience = 0 }
haru_skills.skills_stats.scavenging = { scavenging_skill = 80 }
haru_skills.options.exp_multiplier_scavenging = 2
if fdda then
	assert(mod_chunk(mod_path("liz_fdda_redone_body_search"), { "if haru_skills then" },
		"liz_fdda_redone_body_search", "return true"))
end

load_script("coop_main").on_game_start()
modes.install(load_script("coop_mode"), mode, distributed and {
	where = function(peer) return (peer == 0 or away[peer]) and "away" or "here" end,
	decider = function(peer)
		if peer == 0 then return "nobody" end
		return mode == "srv_map" and not away[peer] and "this" or "other"
	end,
} or nil)
load_script("coop_mods_core").on_game_start()
local keep = coop_mods_core.upvalue(haru_skills.scavanger_effect, "always_keep_item")
keep.story_item = true
AddScriptCallback("GUI_on_show")
AddScriptCallback("server_entity_on_unregister")
if have_file(ROOT .. "scripts/coop_credit_loot.script") then load_script("coop_credit_loot").on_game_start() end
SendScriptCallback("actor_on_first_update")

local function generate(npc, who)
	local ok, err = coop_mods_core.as_player(who, death_manager.create_release_item, npc)
	assert(ok, err)
end

local function opened(npc, peer)
	SendScriptCallback("coop_on_container_opened", peer, npc:id())
end

local function show(npc)
	ui_inventory.GUI = { mode = "loot", npc_id = npc:id() }
	SendScriptCallback("GUI_on_show", "UIInventory")
end

local function xp()
	return haru_skills.skills_levels.scavenging.experience
end

local event = "mods.g93_search_xp"
local function bonus(npc, section)
	local count = 0
	for _, item in ipairs(CREATED) do
		if item.parent == npc:id() and item.sec == section then count = count + 1 end
	end
	return count
end

local a, b = body(600), body(601)
if on_map then
	generate(a, first)
	run_time_events(150)
	check(sent_count(event) == 0 and bonus(a, "bandage") == 0, "generation before a window gives no credit")
	opened(b, 2)
	opened(a, 1)
	generate(b, second)
	run_time_events(150)
	local _, award = sent(event)
	local first_award = SENT[#SENT - 1]
	check(sent_count(event) == 2 and first_award.target == 1 and award.target == 2,
		(fdda and "m10:2 FDDA" or "m30:3 Haru") .. " routes two interleaved searches to their two owners")
	check(bonus(a, "bandage") == 1 and bonus(b, "bandage") == 0 and bonus(a, "story_item") == 0,
		"m30:3 world bonus uses the searcher's checked skill and respects keep_items")
	check(xp() == 0, "a map decision does not increase its local Haru XP")
	generate(a, second)
	opened(a, 2)
	opened(a, 1)
	run_time_events(150)
	check(sent_count(event) == 2 and bonus(a, "bandage") == 1, "two players searching one corpse credit it once")

	if mode == "hostplay" then
		local own = body(602)
		death_manager.create_release_item(own)
		show(own)
		run_time_events(150)
		liz_fdda_redone_body_search.haruka_scavanger_effect()
		local _, own_award = sent(event)
		if own_award and own_award.target == 0 then deliver(own_award, 0); deliver(own_award, 0) end
		check(xp() == 90 and bonus(own, "bandage") == 1, "FDDA host earns XP once, including a replayed owner event")

		MODE, SELF = "client", 1
		local client = {
			leads_here = function() return false end,
			decides_world = function() return false end,
			is_player_mirror = function() return true end,
		}
		modes.install(coop_mode, "hostplay", client)
		haru_skills.skills_levels.scavenging.experience = 0
		if first_award then deliver(first_award, 2); deliver(first_award, 0); deliver(first_award, 0) end
		if award then deliver(award, 0) end
		check(xp() == 90, "Haru XP reaches the searching client once and ignores other characters")
		MODE, SELF = "host", 0
		modes.install(coop_mode, mode)
	else
		local wrong_map = body(603)
		away[1] = true
		generate(wrong_map, second)
		opened(wrong_map, 1)
		check(sent_count(event) == 2 and bonus(wrong_map, "bandage") == 0,
			"a player on another map cannot credit this map's corpse")
		opened(wrong_map, 2)
		check(sent_count(event) == 3 and bonus(wrong_map, "bandage") == 0,
			"the local searcher can still credit the corpse")
	end

	local function drop(who, section)
		local ok, result = coop_mods_core.as_player(who, death_manager.validate_drop, section)
		assert(ok, result)
		return result
	end
	check(drop(first, "test_armour") and not drop(second, "test_armour") and not death_manager.validate_drop("test_armour"),
		"m16:1 progressive drops use the context player's rank")
	check(not drop(first, "army_nosorog_outfit"), "m16:1 rare armour still uses its rarity roll")
	chance = 0
	check(not drop(first, "test_armour"), "m16:1 the MCM veto still applies")
	chance, eco_mode = 100, 3
	check(drop(second, "test_armour"), "m16:1 full drops are independent of rank")
elseif mode == "srv_world" then
	opened(a, 1)
	show(a)
	check(sent_count(event) == 0 and xp() == 0 and #CREATED == 0, "the world keeper performs no object actions")
else
	generate(a, actor)
	show(a)
	run_time_events(150)
	liz_fdda_redone_body_search.haruka_scavanger_effect()
	check(xp() == 90 and bonus(a, "bandage") == 1 and sent_count(event) == 0,
		"single player retains FDDA's original delayed search")
	check(not death_manager.validate_drop("test_armour"), "single player retains the original rank threshold")
end

done("credit_loot@" .. mode)
