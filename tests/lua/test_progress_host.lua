-- F5-PRG-3: authoritative observations, pdata policy and correction delivery.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local skill_names = { "endurance", "strength", "survival", "scavenging" }
local function skills(xp)
	local result = {}
	for _, name in ipairs(skill_names) do
		result[name] = { current_level = 0, experience = xp and xp[name] or 0,
			max_level = 10, base_requirement = 100, requirement = 100, prev_requirement = 0 }
	end
	return result
end

haru_skills = {
	skills_levels = skills(), options = {},
	skills_ini = { collect_section = function() return { base_requirement = 100, max_level = 10 } end },
	save_state = function(m) m.skills_levels = haru_skills.skills_levels end,
	load_state = function(m) haru_skills.skills_levels = m.skills_levels end,
}
for _, name in ipairs(skill_names) do haru_skills.options["exp_multiplier_" .. name] = 1 end

local drops = 0
local function drop(npc, marker)
	drops = drops + 1
	return npc:id(), marker
end
death_manager = { create_release_item = drop }
ranks = { get_obj_rank_name = function() return "professional" end }
function IsItem(kind, section) return kind == "fake_ammo_wpn" and section == "knife_test" end
local reward_peer
coop_tasks = { reward_peer = function() return reward_peer end }
game_statistics = { increment_rank = function(value, marker) return value, marker end }

for _, name in ipairs({ "npc_on_death_callback", "monster_on_death_callback" }) do axr_main.callback_add(name) end
make_actor()
local _, body = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = PROXY })
local _, corpse = spawn("stalker", vec3(0, 0, 0))
local _, victim = spawn("stalker", vec3(0, 0, 0))
local _, mutant = spawn("bloodsucker", vec3(0, 0, 0))
local _, knife = spawn("knife_test", vec3(0, 0, 0))
corpse._alive = false

local read_players = coop.players
local move_state
function coop.players()
	local rows = read_players()
	for _, player in ipairs(rows) do
		if player.id == 1 then player.mstate = move_state end
	end
	return rows
end

start_all()
modes.install(coop_mode, mode)
local P = coop_progress_check
local T = coop_trust
local C = coop_mods_core
T.reset_for_test({ default = "refuse" })
coop_mods_pdata.register("skills_levels", { prime = { "haru_skills" } })
SendScriptCallback("actor_on_first_update") -- let the other adapters install first
local release_item = death_manager.create_release_item

local callback_names = { "npc_on_before_hit", "monster_on_before_hit", "npc_on_death_callback", "monster_on_death_callback" }
local before = {}
for _, name in ipairs(callback_names) do before[name] = axr_main.count(name) end
local observations = {}
if P.observe then
	local observe = P.observe
	function P.observe(character, kind, amount, meta)
		observations[kind] = (observations[kind] or 0) + 1
		return observe(character, kind, amount, meta)
	end
end
if P.on_game_start then P.on_game_start() end
SendScriptCallback("actor_on_first_update")

local function report(data, seq)
	local payload = coop_main.encode({ k = seq, i = 1, n = 1, d = assert(C.ser(data)) })
	deliver({ name = "mods.pd", payload = payload }, 1)
	return (alife_storage_manager.get_state().coop_mods_pdata or {})[tostring(PROXY)]
end

if mode == "none" or mode == "srv_world" then
	local same = true
	for _, name in ipairs(callback_names) do same = same and before[name] == axr_main.count(name) end
	check(same and death_manager.create_release_item == release_item, "no body listeners or corpse wrapper without a led map")
	done("progress " .. mode)
	return
end

local extra_listener = 0
RegisterScriptCallback("npc_on_before_hit", function() extra_listener = extra_listener + 1 end)
move_state = 0
SendScriptCallback("actor_on_update")
body._pos = vec3(14, 0, 0)
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
move_state = 128 -- mcJump
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
NOW = NOW + 1000
SendScriptCallback("actor_on_update") -- holding the flag is not a second jump
SendScriptCallback("npc_on_before_hit", victim, { draftsman = body, power = 2, type = 7, weapon_id = knife:id() })
SendScriptCallback("monster_on_before_hit", mutant, { draftsman = body, power = 1, type = 7, weapon_id = knife:id() })
SendScriptCallback("npc_on_before_hit", body, { draftsman = victim, power = 1, type = 5 })
SendScriptCallback("npc_on_before_hit", body, { draftsman = victim, power = 100, type = 4 })
SendScriptCallback("npc_on_death_callback", victim, body)
SendScriptCallback("monster_on_death_callback", mutant, body)
local ok, id, marker = C.as_player(body, death_manager.create_release_item, corpse, "pass through")
check(ok and id == corpse:id() and marker == "pass through" and drops == 1 and db.actor:id() == 0,
	"corpse observation preserves the existing call and its returns")
check(extra_listener == 3, "progress keeps the other hit listeners")
check(observations.step_m == 1 and observations.jump == 1
	and observations.melee_hit == 2 and observations.hit_taken == 1,
	"movement edges and supported hit types contribute once each")
local rank, reputation = P.rank_budget(PROXY)
check(rank > 90 and reputation > 20, "both kill callbacks feed the native rank budget reader")
reward_peer = 1
local reward, result = game_statistics.increment_rank(160, "pass through")
reward_peer = nil
check(reward == 160 and result == "pass through" and P.rank_budget(PROXY) == rank + 50,
	"scoped task rank uses GAMMA's divisor and preserves the original result")

local honest = skills({ endurance = 50, strength = 97, survival = 200, scavenging = 40 })
if mode == "srv_map" then
	local accepted, reasons = P.check(PROXY, 1, "skills_levels", nil, honest)
	check(accepted == honest and #reasons == 0, "map authority tallies the remote body and the searcher")
	done("progress " .. mode)
	return
end

local record = report({ skills_levels = honest }, "honest")
check(record and record.d.skills_levels.survival.experience == 200 and P.skill_of(PROXY, "survival") == 0
	and select(2, P.skill_of(PROXY, "survival")) and not log_has("progress check failed"),
	"honest walking, combat and corpse search pass through pdata")

local inflated = skills({ endurance = 10000, survival = 10000, scavenging = 10000 })
T.reset_for_test({ default = "log" })
record = report({ skills_levels = inflated }, "inflated-log")
check(record and record.d.skills_levels.endurance.experience == 10000
	and log_has("would be refused") and sent_count("mods.pd_fix") == 0,
	"log audits inflated skills and preserves the report")
local save = alife_storage_manager.get_state()
check(record and record.progress_checked and record.progress_checked.records.skills_levels.endurance.experience == 50,
	"the keeper saves the confirmed snapshot beside the raw report")
P.clear()
alife_storage_manager.CALifeStorageManager_load(save)
check(select(2, P.skill_of(PROXY, "endurance")), "world reload restores the confirmed snapshot")

T.reset_for_test({ default = "refuse" })
record = report({ skills_levels = inflated }, "inflated-refuse")
local fix, wire = sent("mods.pd_fix")
check(record and record.d.skills_levels.endurance.experience < 10000
	and record.d.skills_levels.endurance.experience >= 50,
	"refuse clamps against the confirmed record, even after a log-only report")
local corrected = fix and C.deser(fix.v)
check(fix and fix.k == "skills_levels" and wire.target == 1 and corrected
	and corrected.endurance.experience == record.d.skills_levels.endurance.experience,
	"refuse sends the corrected key and value to the transport sender")

local body_id = corpse:id()
function corpse:name() return "tracked_corpse" end
function db.actor:name() return "local_player" end
local marker_meta = { body = { [body_id] = "tracked_corpse" }, killer = { [PROXY] = "local_player" } }
local function pda_record(marker_type)
	return { faction_data = { unrelated = 42 }, _coop_pda_ids = marker_meta,
		tracked_bodies = { [body_id] = { id = body_id, killer_id = PROXY, tod = 1, typ = marker_type, ktyp = 1 } } }
end
local tracker = { tracked_bodies = {} }
function tracker.load_state(m)
	for key, row in pairs(m.milpda.tracked_bodies) do tracker.tracked_bodies[key] = row end
end
ish_kill_tracker = tracker
coop_mods_pdata.register("milpda", { subs = { "faction_data", "tracked_bodies", "_coop_pda_ids" },
	get = function() return pda_record(4) end })
report({ milpda = pda_record(1) }, "pda-honest")
record = report({ milpda = pda_record(4) }, "pda-invalid")
local _, pda_wire = sent("mods.pd_fix")
check(record and record.d.milpda.faction_data.unrelated == 42
	and record.d.milpda.tracked_bodies[body_id].typ == 1,
	"the tracker clamp preserves other data carried in the PDA key")

-- Same event on the player's process; use the real pdata handler and codec.
MODE, SELF = "client", 1
modes.install(coop_mode, "hostplay", { is_player_mirror = function() return true end })
coop_mods_pdata.apply_loaded({})
haru_skills.skills_levels = inflated
coop_mods_pdata.report_now()
if wire then deliver(wire, 2) end
check(haru_skills.skills_levels.endurance.experience == 10000, "pd_fix ignores other senders")
if wire then deliver(wire, 0) end
local saved = STASH.coop_mods_pdata and C.deser(STASH.coop_mods_pdata:match("^[^|]*|(.*)$"))
check(corrected and saved and haru_skills.skills_levels.endurance.experience == corrected.endurance.experience
	and saved.skills_levels.endurance.experience == corrected.endurance.experience,
	"pd_fix from 0 updates the mod and the session stash")
tracker.tracked_bodies[1234] = { typ = 4 }
if pda_wire then deliver(pda_wire, 0) end
local row = tracker.tracked_bodies[body_id]
check(row and row.typ == 1 and row.killer_id == 0 and tracker.tracked_bodies[1234] == nil,
	"the PDA correction replaces live tracker markers in local numbering")
done("progress " .. mode)
