-- F5-PRG-1: pure progress rules, real GAMMA formulas, every S4 answer set.
local modes = dofile("tests/lua/support/modes.lua")
local passed, failed = 0, 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function eq(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function read(path)
	local f = assert(io.open(path, "rb"), "required real source: " .. path)
	local s = f:read("*a"):gsub("\r", ""); f:close(); return s
end
local function load_module(name)
	local f = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	assert(f, "missing progress implementation: " .. name)
	local s = f:read("*a"); f:close()
	local env = setmetatable({}, { __index = _G })
	setfenv(assert(loadstring(s, "@" .. name)), env)(); return env
end
local script_dir = (os.getenv("GAMMA_SCRIPTS") or "temp/review/corpus/merged"):gsub("\\", "/")
-- Only the stand's configs, never the owner's game. The base includes skill_*.ltx.
local config_dir = "E:/RayLinkGames/GAMMA/game-dev/gamedata/configs/"
local base = read(config_dir .. "plugins/skills/skills_base.ltx")
assert(base:find('skill_%*%.ltx'), "real base must include the skill definitions")
local configs, section = {}, nil
for line in read(config_dir .. "plugins/skills/skill_haruka.ltx"):gmatch("[^\n]+") do
	section = line:match("^%[([^%]]+)%]") or section
	local k, v = line:match("^([%w_]+)%s*=%s*([%d%.]+)")
	if section then configs[section] = configs[section] or {}; if k then configs[section][k] = tonumber(v) end end
end
local haru_source = read(script_dir .. "/haru_skills.script")
local stats_source = read(script_dir .. "/game_statistics.script")
local tracker_source = read("temp/review/corpus/merged/ish_kill_tracker.script")
local function real_function(source, name, env)
	local body = assert(source:match("\n(function " .. name:gsub("%.", "%%.") .. "%b().-\nend)"), name)
	setfenv(assert(loadstring(body)), env)()
end
local function clone(v)
	if type(v) ~= "table" then return v end
	local out = {}; for k, x in pairs(v) do out[k] = clone(x) end; return out
end
local function gamma_tracker()
	local tracker = setmetatable({
		db = { actor = {} }, tracked_bodies = {},
		alife_object = function() return { character_name = function() return "Stalker" end } end,
		get_object_community = function() return "stalker" end, IsStalker = function() return true end,
		safename = function() return "Stalker" end, get_time_elapsed = function() return 129 end,
		get_object_by_id = function() return {} end, gts = function(id) return id end,
		show_other_victim_text = true, show_other_killer_text = true,
		level = { name = function() return "l01_escape" end, map_remove_all_object_spots = true },
		remove_all_spots = function() end, dl = function() end, vl = function() end,
		nameid = function() return "Stalker" end, is_empty = function(t) return not t or next(t) == nil end,
	}, { __index = _G })
	for _, name in ipairs({ "new_kill", "killspot_text", "save_state", "load_state", "clean_slate", "generate_kill_id" }) do
		real_function(tracker_source, name, tracker)
	end
	local function object(id)
		return { id = function() return id end, section = function() return "stalker" end,
			has_info = function() return false end }
	end
	tracker.new_kill(object(123), object(0))
	tracker.new_kill(object(456), object(901)) -- the mod tracks kills by unrelated NPCs too
	return tracker
end
local skills = { "endurance", "strength", "survival", "scavenging" }
local function initial()
	local out = {}
	for _, name in ipairs(skills) do
		out[name] = clone(configs[name]); out[name].current_level = 0; out[name].experience = 0
		out[name].requirement = out[name].base_requirement; out[name].prev_requirement = 0
	end
	return out
end
local function real_haru()
	local h = setmetatable({ skills_levels = initial(), skills_stats = {}, skills_increments = {}, options = {},
		print_dbg = function() end, parse_keys = function() return "" end, translate_string = function(x) return x end,
		db = { actor = { give_game_news = function() end } }, xr_sound = { set_sound_play = function() end },
		get_max_weight_coef = function() return 0.4 end }, { __index = _G })
	for _, name in ipairs(skills) do h.options["exp_multiplier_" .. name] = 1; h.skills_stats[name] = {}; h.skills_increments[name] = {} end
	for _, name in ipairs({ "increase_skill", "level_up_skill", "actor_on_jump", "actor_on_footstep" }) do real_function(haru_source, name, h) end
	h.skills_ini = { collect_section = function(_, name) return clone(configs[name]) end }
	return h
end
local stat_defs = assert(loadstring("return " .. assert(stats_source:match("\nactor_statistics = (%b{})"))))()
local rank_points = {}
local rank_section = read(config_dir .. "creatures/game_relations.ltx"):match("%[rank_kill_points%](.-)\n%[")
for k, n in assert(rank_section):gmatch("([%w_]+)%s*=%s*(%d+)") do rank_points[k] = tonumber(n) end
local P, T, H, now, lines
function printf(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
function time_global() return now end
local function fresh(mode)
	now, lines = 0, {}; H = real_haru(); haru_skills = H
	game_statistics = { actor_statistics = clone(stat_defs) }
	ini_sys = { r_float_ex = function(_, s, k) return s == "rank_kill_points" and rank_points[k] end }
	coop_mode = load_module("coop_mode"); modes.install(coop_mode, mode)
	T = load_module("coop_trust"); coop_trust = T; T.reset_for_test({ default = "refuse" })
	P = load_module("coop_progress_check")
end
local function reason(reasons, expected)
	for _, s in ipairs(reasons) do if s:find(expected, 1, true) then return end end
	error("missing reason " .. expected .. ": " .. table.concat(reasons, ", "))
end
local function no_failures()
	for _, c in pairs(T.status()) do eq(c.failed, 0) end
	eq(#lines, 0)
end
local function suspicious(previous, reported, expected, key)
	local value, reasons = P.check("alice", 7, key or "skills_levels", previous, reported)
	reason(reasons, expected); assert(T.status()[key == "game_statistics" and "progress_stats" or "progress_skills"].refused > 0)
	return value
end

for _, mode in ipairs(modes.names()) do
	local function case(name, fn) test(mode .. "/" .. name, function() fresh(mode); fn() end) end
	case("honest_scripted_session", function()
		local old = initial()
		P.check("alice", 7, "skills_levels", old, old)
		P.note("alice", "step_m", 1000, { weight_coef = 0.4 })
		for _ = 1, math.floor(1000 / 0.7) do H.actor_on_footstep() end
		P.note("alice", "jump", 10, { weight_coef = 0.4 })
		for _ = 1, 10 do H.actor_on_jump() end
		for _, rank in ipairs({ "novice", "veteran", "legend" }) do P.note("alice", "corpse_search", 1, { rank = rank }) end
		H.increase_skill("scavenging", 25 + 45 + 100)
		for _ = 1, 5 do P.note("alice", "hit_taken", 0.2, { type = 6 }); H.increase_skill("survival", 0.2 * 200) end
		P.note("alice", "kill", 4, { kind = "stalker", rank = "veteran" })
		P.note("alice", "task_rank", 250)
		for _, name in ipairs(skills) do
			while H.skills_levels[name].experience > H.skills_levels[name].requirement do H.level_up_skill(name) end
		end
		local accepted, reasons = P.check("alice", 7, "skills_levels", old, H.skills_levels)
		eq(#reasons, 0); eq(accepted.endurance.experience, H.skills_levels.endurance.experience)
		local level, checked = P.skill_of("alice", "endurance"); eq(level, accepted.endurance.current_level); eq(checked, true)
		local stat = { actor_statistics = { killed_stalkers = 4, tasks_completed = 1 } }
		local _, why = P.check("alice", 7, "game_statistics", {}, stat); eq(#why, 0)
		local r = P.rank_budget("alice"); assert(r >= 4 * 85 + 250); no_failures()
	end)
	case("scavenging_without_search", function()
		local old, report = initial(), initial(); report.scavenging.experience = 5000
		local accepted = suspicious(old, report, "scavenging: budget")
		assert(accepted.scavenging.experience < 5000); eq(old.scavenging.experience, 0)
	end)
	case("level_ten_without_experience", function()
		local old, report = initial(), initial(); report.strength.current_level = 10
		suspicious(old, report, "strength: level experience")
	end)
	case("changed_requirement", function()
		local old, report = initial(), initial(); report.survival.requirement = 1
		local accepted = suspicious(old, report, "survival: requirement"); eq(accepted.survival.requirement, configs.survival.base_requirement)
	end)
	case("counter_decreased", function()
		local old = { actor_statistics = { boxes_smashed = 10 } }
		local _, why = P.check("alice", 7, "game_statistics", nil, old); eq(#why, 0)
		local accepted = suspicious(old,
			{ actor_statistics = { boxes_smashed = 9 } }, "boxes_smashed: decreased", "game_statistics")
		eq(accepted.actor_statistics.boxes_smashed, 10)
	end)
	case("rank_without_event", function()
		local budget = P.rank_budget("alice"); assert(budget < 5000); assert(P.clamp(0, 5000, budget) < 5000)
	end)
	case("rank_without_event_stays_bounded_after_idle", function()
		P.rank_budget("alice"); now = 3600000
		local budget = P.rank_budget("alice")
		assert(budget < 5000)
		P.note("alice", "task_rank", 5000)
		assert(P.rank_budget("alice") >= 5000)
	end)
	case("real_rank_statistics_divisors", function()
		local h = { db = { actor = { change_character_rank = function(_, n) h_rank = h_rank + n end,
			character_rank = function() return h_rank end } }, check_for_rank_change = function() end,
			increment_reputation = function() end, actor_statistics = clone(stat_defs) }
		h_rank = 0; real_function(stats_source, "increment_rank", h); real_function(stats_source, "increment_statistic", h)
		h.increment_statistic("boxes_smashed"); P.note("alice", "statistic", 1, { name = "boxes_smashed" })
		local r = P.rank_budget("alice"); eq(r, h_rank * 1.25 + P.constants.rank_allowance)
	end)
	case("decider_multiplier", function()
		H.options.exp_multiplier_scavenging = 3
		P.note("alice", "corpse_search", 1, { rank = "legend", exp_multiplier_scavenging = 100000 })
		local report = initial(); report.scavenging.experience = 300
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0)
		report.scavenging.experience = 5000; suspicious(initial(), report, "scavenging: budget")
	end)
	case("kills_observed_and_aggregate", function()
		P.note("alice", "kill", 2, { kind = "monster", rank = "novice" })
		local _, why = P.check("alice", 7, "game_statistics", {}, { actor_statistics = { killed_monsters = 3 } }); eq(#why, 0)
		suspicious({}, { actor_statistics = { killed_monsters = 50 } }, "killed_monsters: budget", "game_statistics")
	end)
	case("visited_sets_only_grow", function()
		local old = { actor_visited_levels = { l01_escape = true } }
		local _, why = P.check("alice", 7, "game_statistics", nil, old); eq(#why, 0)
		local accepted = suspicious(old,
			{ actor_visited_levels = { l01_escape = false } }, "actor_visited_levels: removed", "game_statistics")
		eq(accepted.actor_visited_levels.l01_escape, true)
	end)
	case("finite_numbers_and_shape", function()
		for _, v in ipairs({ -1, math.huge, 0/0 }) do
			local report = initial(); report.endurance.experience = v; suspicious(initial(), report, "progress shape bounds")
		end
		for _, v in ipairs({ "5", {}, true }) do
			local report = initial(); report.endurance.experience = v; suspicious(initial(), report, "endurance: experience")
		end
		suspicious(initial(), false, "skills shape")
	end)
	case("log_preserves_report_but_not_unchecked_skill", function()
		T.reset_for_test({ default = "log" })
		P.check("alice", 7, "skills_levels", initial(), initial())
		local report = initial(); report.endurance.current_level = 30; report.endurance.experience = 1e8
		local accepted, reasons = P.check("alice", 7, "skills_levels", initial(), report)
		eq(accepted.endurance.current_level, 30); assert(#reasons > 0); eq(T.status().progress_skills.refused, 0)
		local level, checked = P.skill_of("alice", "endurance"); eq(level, 0); eq(checked, true)
	end)
	case("windows_are_per_key_and_character", function()
		P.note("alice", "corpse_search", 1, { rank = "legend" }); P.note("alice", "kill", 3, { kind = "monster" })
		local report = initial(); report.scavenging.experience = 100
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0)
		local _, stats_why = P.check("alice", 7, "game_statistics", {}, { actor_statistics = { killed_monsters = 3 } }); eq(#stats_why, 0)
		suspicious(report, (function() local t = clone(report); t.scavenging.experience = 250; return t end)(), "scavenging: budget")
		local replay_gain = clone(report); replay_gain.scavenging.experience = 200
		suspicious(initial(), replay_gain, "scavenging: budget") -- stale caller baseline cannot replay the event
		local _, bob = P.check("bob", 8, "skills_levels", initial(), report); reason(bob, "scavenging: budget")
	end)
	case("refuse_does_not_consume_window", function()
		P.note("alice", "corpse_search", 1, { rank = "legend" })
		local report = initial(); report.scavenging.experience = 5000; suspicious(initial(), report, "scavenging: budget")
		report.scavenging.experience = 100
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0)
	end)
	case("tracker_counters_and_framework_bounds", function()
		P.note("alice", "kill", 2, { kind = "stalker" })
		local _, why = P.check("alice", 7, "ish_kill_tracker", {}, { kills = 2 }); eq(#why, 0)
		local v, why2 = P.check("alice", 7, "ish_kill_tracker", { kills = 2 }, { kills = 100 }); reason(why2, "kills: budget"); eq(v.kills, 2)
		local _, why3 = P.check("alice", 7, "experience_framework_savedata", {}, { XP = -1 }); reason(why3, "bounds")
	end)
	case("gamma_tracker_saves_loads_and_clears_marker_history", function()
		local tracker, saved = gamma_tracker(), {}
		tracker.save_state(saved)
		local report = saved.milpda
		eq(report.tracked_bodies[123].tod, 129)
		eq(report.tracked_bodies[456].killer_id, 901)
		local accepted, why = P.check("alice", 7, "milpda", {}, report)
		assert(#why == 0, table.concat(why, ", "))
		local _, legacy_why = P.check("alice", 7, "ish_kill_tracker", {}, report)
		assert(#legacy_why == 0, table.concat(legacy_why, ", "))
		tracker.clean_slate()
		tracker.load_state({ milpda = accepted })
		eq(tracker.tracked_bodies[123].text, report.tracked_bodies[123].text)
		eq(tracker.tracked_bodies[456].killer_id, 901)
		tracker.clean_slate()
		local cleared = {}; tracker.save_state(cleared)
		eq(cleared.milpda, nil)
		local empty, clear_why = P.check("alice", 7, "milpda", accepted, cleared.milpda or {})
		eq(#clear_why, 0); eq(next(empty), nil); no_failures()
	end)
	case("gamma_tracker_marker_bounds_and_kill_counter_budget_are_independent", function()
		local tracker, saved = gamma_tracker(), {}; tracker.save_state(saved)
		local report = saved.milpda
		local accepted, why = P.check("alice", 7, "milpda", nil, report)
		assert(#why == 0, table.concat(why, ", "))
		local invalid = clone(report); invalid.tracked_bodies[456].killer_id = 65536
		local kept, bad_why = P.check("alice", 7, "milpda", accepted, invalid)
		reason(bad_why, "tracker: body record")
		eq(kept.tracked_bodies[456].killer_id, 901)
		local counters = clone(report); counters.kills = 2
		local clamped, counter_why = P.check("alice", 7, "ish_kill_tracker", nil, counters)
		reason(counter_why, "kills: budget"); eq(clamped.kills, 0)
	end)
	case("unknown_skill_is_unchecked", function() local level, checked = P.skill_of("nobody", "strength"); eq(level, 0); eq(checked, false) end)
	case("unobserved_jump_rate", function()
		P.check("alice", 7, "skills_levels", initial(), initial()); now = 15000
		local report = initial(); report.endurance.experience = 100
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0)
		report.endurance.experience = 1000; suspicious(initial(), report, "endurance: budget")
	end)
	case("hit_loot_melee_rules", function()
		P.note("alice", "melee_hit", 2, { alive = true }); P.note("alice", "melee_hit", 2, { alive = false })
		P.note("alice", "melee_hit", 100, { alive = true, important = true })
		P.note("alice", "hit_taken", 10, { type = 4 }); P.note("alice", "hit_taken", 1, { type = 5 })
		P.note("alice", "monster_loot", 100)
		local report = initial(); report.strength.experience = 60; report.survival.experience = 210
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0)
		report.strength.experience = 500; suspicious(initial(), report, "strength: budget")
	end)
	case("real_haru_dead_melee_earns_no_budget", function()
		H.AC_ID = 0; H.important_npcs = {}
		H.IsWeapon = function() return true end; H.IsItem = function() return true end
		H.db.actor.active_item = function() return { section = function() return "knife" end } end
		real_function(haru_source, "creature_on_before_hit", H)
		local victim = { alive = function() return false end, section = function() return "ordinary_stalker" end }
		H.creature_on_before_hit(victim, { power = 10, draftsman = { id = function() return 0 end } })
		eq(H.skills_levels.strength.experience, 0)
		P.note("alice", "melee_hit", 10, { alive = false })
		local report = initial(); report.strength.experience = 50
		suspicious(initial(), report, "strength: budget")
	end)
	case("log_followup_cannot_launder_skill", function()
		T.reset_for_test({ default = "log" })
		local report = initial(); report.scavenging.experience = 100000
		P.check("alice", 7, "skills_levels", initial(), report)
		local _, why = P.check("alice", 7, "skills_levels", report, report)
		reason(why, "scavenging: budget")
		local level, checked = P.skill_of("alice", "scavenging"); eq(level, 0); eq(checked, false)
	end)
	case("restart_without_checkpoint_does_not_trust_raw_pdata", function()
		T.reset_for_test({ default = "log" })
		local report = initial()
		H.increase_skill("endurance", 5000)
		H.level_up_skill("endurance")
		eq(H.skills_levels.endurance.current_level, 1)
		local saved, why = P.check("alice", 7, "skills_levels", report, H.skills_levels)
		reason(why, "endurance: budget"); eq(saved.endurance.current_level, 1)
		local stats, stat_why = P.check("alice", 7, "game_statistics", nil,
			{ actor_statistics = { killed_stalkers = 100 } })
		reason(stat_why, "killed_stalkers: budget")
		P = load_module("coop_progress_check")
		local _, retry_why = P.check("alice", 7, "skills_levels", clone(saved), clone(saved))
		reason(retry_why, "endurance: budget")
		local _, retry_stat = P.check("alice", 7, "game_statistics", clone(stats), clone(stats))
		reason(retry_stat, "killed_stalkers: budget")
		local level, checked = P.skill_of("alice", "endurance")
		eq(level, 0); eq(checked, false)
	end)
	case("save_load_restores_only_confirmed_skills_and_counters", function()
		T.reset_for_test({ default = "log" })
		local old = initial()
		P.note("alice", "step_m", 3500)
		H.increase_skill("endurance", 5000)
		H.level_up_skill("endurance")
		local verified, skill_why = P.check("alice", 7, "skills_levels", old, H.skills_levels)
		eq(#skill_why, 0); eq(verified.endurance.current_level, 1)
		P.note("alice", "kill", 2, { kind = "monster" })
		local stat = { actor_statistics = { killed_monsters = 2 } }
		local _, stat_why = P.check("alice", 7, "game_statistics", {}, stat); eq(#stat_why, 0)

		local inflated = clone(verified)
		inflated.endurance.experience = 10000
		inflated.endurance.current_level = 2
		inflated.endurance.prev_requirement = inflated.endurance.requirement
		inflated.endurance.requirement = inflated.endurance.base_requirement * 3.75
		local raw_skill, log_skill = P.check("alice", 7, "skills_levels", verified, inflated)
		reason(log_skill, "endurance: budget")
		local raw_stat, log_stat = P.check("alice", 7, "game_statistics", stat,
			{ actor_statistics = { killed_monsters = 100 } })
		reason(log_stat, "killed_monsters: budget")

		local codec = load_module("coop_mods_core")
		local checkpoint = P.snapshot("alice")
		local disk = assert(codec.deser(assert(codec.ser({
			d = { skills_levels = raw_skill, game_statistics = raw_stat },
			progress_checked = checkpoint,
		}))))
		checkpoint.records.skills_levels.endurance.current_level = 2
		eq(P.skill_of("alice", "endurance"), 1)
		P.clear()
		local _, before_restore = P.skill_of("alice", "endurance"); eq(before_restore, false)
		eq(P.restore("alice", disk.d), false)
		eq(P.restore("alice", disk.progress_checked), true)
		disk.progress_checked.records.skills_levels.endurance.current_level = 2
		disk.progress_checked.records.game_statistics.actor_statistics.killed_monsters = 100
		local level, checked = P.skill_of("alice", "endurance"); eq(level, 1); eq(checked, true)
		local _, retry_skill = P.check("alice", 7, "skills_levels", disk.d.skills_levels, disk.d.skills_levels)
		reason(retry_skill, "endurance: budget")
		local _, retry_stat = P.check("alice", 7, "game_statistics", disk.d.game_statistics, disk.d.game_statistics)
		reason(retry_stat, "killed_monsters: budget")
		local after, after_checked = P.skill_of("alice", "endurance"); eq(after, 1); eq(after_checked, true)
		local _, honest_stat = P.check("alice", 7, "game_statistics", disk.d.game_statistics, stat); eq(#honest_stat, 0)
		local _, honest_skill = P.check("alice", 7, "skills_levels", disk.d.skills_levels, verified); eq(#honest_skill, 0)
	end)
	case("late_report_can_use_unspent_facts_after_a_log_warning", function()
		T.reset_for_test({ default = "log" })
		P.note("alice", "corpse_search", 1, { rank = "legend" })
		local report = initial(); report.scavenging.experience = 200
		local _, why = P.check("alice", 7, "skills_levels", initial(), report); reason(why, "scavenging: budget")
		P.note("alice", "corpse_search", 1, { rank = "legend" })
		local _, retry_why = P.check("alice", 7, "skills_levels", report, report); eq(#retry_why, 0)
	end)
	case("malformed_previous_after_log_is_safe", function()
		local old = initial(); old.endurance.current_level = "bad"
		local accepted = P.check("alice", 7, "skills_levels", old, initial())
		eq(accepted.endurance.current_level, 0)
	end)
	case("refusal_counters_remain_integers", function()
		local accepted, why = P.check("alice", 7, "game_statistics", {}, { actor_statistics = { boxes_smashed = 0.5 } })
		reason(why, "boxes_smashed: bounds"); eq(accepted.actor_statistics.boxes_smashed, 0)
	end)
	case("counter_table_is_audited_and_previous_count_survives", function()
		local old = { actor_statistics = { boxes_smashed = 2 } }
		local _, setup = P.check("alice", 7, "game_statistics", nil, old); eq(#setup, 0)
		local accepted, why = P.check("alice", 7, "game_statistics", old,
			{ actor_statistics = { boxes_smashed = { count = 2 } } })
		reason(why, "boxes_smashed: bounds"); eq(accepted.actor_statistics.boxes_smashed, 2)
	end)
	case("cyclic_skill_report_is_audited_without_crashing", function()
		local old, report = initial(), initial()
		local _, setup = P.check("alice", 7, "skills_levels", nil, old); eq(#setup, 0)
		report.endurance.experience = report
		local accepted, why = P.check("alice", 7, "skills_levels", old, report)
		reason(why, "progress shape bounds"); eq(accepted.endurance.experience, old.endurance.experience)
	end)
	case("allowances_keep_running_on_long_lived_servers", function()
		now = 1000000000; P.rank_budget("alice")
		now = now + 60000
		local rank, reputation = P.rank_budget("alice")
		eq(rank, 125); eq(reputation, 35)
	end)
	case("tracker_shape_change_keeps_previous", function()
		local old = { kills = 5 }
		P.note("alice", "kill", 5, { kind = "stalker" })
		local _, setup = P.check("alice", 7, "ish_kill_tracker", nil, old); eq(#setup, 0)
		local accepted, why = P.check("alice", 7, "ish_kill_tracker", old, { kills = {} })
		reason(why, "tracker: shape"); eq(accepted.kills, 5)
	end)
	case("rank_commit_is_explicit_and_independent", function()
		P.note("alice", "task_rank", 400, { reputation = 100 }); now = 60000
		local r, rep = P.rank_budget("alice"); assert(r >= 625); assert(rep >= 160)
		P.check("alice", 7, "skills_levels", initial(), initial()); eq(P.rank_budget("alice"), r)
		eq(P.rank_budget("alice", true), r); eq(P.rank_budget("alice"), P.constants.rank_allowance)
	end)
	case("cyclic_and_oversized_reports_are_audited", function()
		local cyclic = {}; cyclic.self = cyclic
		local _, why = P.check("alice", 7, "experience_framework_savedata", {}, cyclic); reason(why, "bounds")
		local wide = {}; for i = 1, 2050 do wide[i] = 1 end
		local _, why2 = P.check("alice", 7, "experience_framework_savedata", {}, wide); reason(why2, "bounds")
	end)
	case("all_stock_statistics_have_caps", function()
		local report = { actor_statistics = {} }
		for name in pairs(stat_defs) do report.actor_statistics[name] = 0 end
		local _, why = P.check("alice", 7, "game_statistics", {}, report); eq(#why, 0); no_failures()
	end)
	case("unobserved_counter_burst_is_capped", function()
		local accepted = suspicious({}, { actor_statistics = { tasks_completed = 33 } }, "tasks_completed: budget", "game_statistics")
		eq(accepted.actor_statistics.tasks_completed, 32)
	end)
	case("clear_and_character_isolation", function()
		P.check("alice", 7, "skills_levels", initial(), initial()); P.check("bob", 8, "skills_levels", initial(), initial())
		P.clear("alice"); local _, checked = P.skill_of("alice", "endurance"); eq(checked, false)
		local _, bob = P.skill_of("bob", "endurance"); eq(bob, true)
		P.clear(); local _, empty = P.skill_of("bob", "endurance"); eq(empty, false)
	end)
	case("log_followup_cannot_launder_counters", function()
		T.reset_for_test({ default = "log" })
		local report = { actor_statistics = { killed_monsters = 1000 } }
		P.check("alice", 7, "game_statistics", {}, report)
		local _, why = P.check("alice", 7, "game_statistics", report, report)
		reason(why, "killed_monsters: budget")
	end)
	case("malformed_first_log_report_cannot_become_the_baseline", function()
		T.reset_for_test({ default = "log" })
		local skill = initial(); skill.scavenging.experience = 5000
		skill.bad = -1
		P.check("alice", 7, "skills_levels", initial(), skill)
		local corrected_skill = clone(skill); corrected_skill.bad = nil
		local _, skill_why = P.check("alice", 7, "skills_levels", skill, corrected_skill)
		reason(skill_why, "scavenging: budget")

		local stat = { actor_statistics = { killed_monsters = 100 }, bad = math.huge }
		P.check("alice", 7, "game_statistics", {}, stat)
		local corrected_stat = { actor_statistics = { killed_monsters = 100 } }
		-- Changing the malformed field to a bounded value in the caller's copy
		-- must still leave the original keeper baseline in place.
		stat.bad = nil
		local _, stat_why = P.check("alice", 7, "game_statistics", stat, corrected_stat)
		reason(stat_why, "killed_monsters: budget")
	end)
	case("missing_rules_cannot_promote_a_log_report_to_checked", function()
		T.reset_for_test({ default = "log" })
		local ini = H.skills_ini; H.skills_ini = nil
		local report = initial(); report.scavenging.experience = 5000
		P.check("alice", 7, "skills_levels", initial(), report)
		H.skills_ini = ini
		local _, why = P.check("alice", 7, "skills_levels", report, report)
		reason(why, "scavenging: budget")
	end)
	case("malformed_report_returns_the_last_checked_record_in_refuse", function()
		T.reset_for_test({ default = "log" })
		local old = initial(); P.check("alice", 7, "skills_levels", old, old)
		local unchecked = initial(); unchecked.scavenging.experience = 5000
		P.check("alice", 7, "skills_levels", old, unchecked)
		T.reset_for_test({ default = "refuse" })
		local new = initial(); new.scavenging.experience = math.huge
		local accepted = P.check("alice", 7, "skills_levels", unchecked, new)
		eq(accepted.scavenging.experience, 0)
	end)
	case("false_statistics_section_is_not_an_empty_table", function()
		local _, why = P.check("alice", 7, "game_statistics", {}, { actor_statistics = false })
		reason(why, "statistics shape")
	end)
	case("unknown_key_and_nil_key_are_audited_in_log", function()
		T.reset_for_test({ default = "log" })
		local _, why = P.check("alice", 7, nil, {}, {})
		reason(why, "progress unknown key")
	end)
	case("framework_xp_requires_a_number", function()
		local old = { XP = 10 }
		local _, setup = P.check("alice", 7, "experience_framework_savedata", nil, old); eq(#setup, 0)
		local accepted, why = P.check("alice", 7, "experience_framework_savedata", old, { XP = "1000" })
		reason(why, "framework XP bounds"); eq(accepted.XP, 10)
	end)
	case("real_haru_combat_loot_and_search_formulas", function()
		H.skills_stats.strength.melee_damage = 1; H.skills_stats.survival.resistance = 1
		H.AC_ID = 0; H.important_npcs = {}; H.allowed_hit_types = { [5] = true, [6] = true, [7] = true, [8] = true }
		H.IsWeapon = function() return true end; H.IsItem = function() return true end
		H.db.actor.active_item = function() return { section = function() return "knife" end } end
		H.ini_sys = { r_float_ex = function() return 100 end }; H.is_empty = function() return true end
		for _, name in ipairs({ "creature_on_before_hit", "actor_on_before_hit", "monster_on_loot_init" }) do real_function(haru_source, name, H) end
		local victim = { alive = function() return true end, section = function() return "ordinary_stalker" end }
		H.creature_on_before_hit(victim, { power = 2, draftsman = { id = function() return 0 end } })
		P.note("alice", "melee_hit", 2, { alive = true })
		for hit_type = 4, 9 do
			H.actor_on_before_hit({ power = 0.1, type = hit_type }); P.note("alice", "hit_taken", 0.1, { type = hit_type })
		end
		H.monster_on_loot_init(victim, {}); P.note("alice", "monster_loot", 100)
		local ranks = assert(loadstring("return " .. assert(haru_source:match("local rank_table = (%b{})"))))()
		for rank, xp in pairs(ranks) do H.increase_skill("scavenging", xp); P.note("alice", "corpse_search", 1, { rank = rank }) end
		local _, why = P.check("alice", 7, "skills_levels", initial(), H.skills_levels); eq(#why, 0); no_failures()
	end)
	case("missing_decider_rules_are_audited", function()
		H.skills_ini = nil
		local _, why = P.check("alice", 7, "skills_levels", initial(), initial()); reason(why, "rules unavailable")
	end)
	case("payload_is_never_a_console_line", function()
		local attack = "%s%s%s\nclient injected console line"
		local _, why = P.check("alice", 7, "game_statistics", {}, { actor_statistics = { [attack] = 5000 } })
		reason(why, "bounds")
		for _, line in ipairs(lines) do assert(not line:find("client injected", 1, true)); assert(not line:find("\n", 1, true)) end
	end)
	case("saved_log_misc_type_is_safe_after_restart", function()
		local accepted, why = P.check("alice", 7, "game_statistics", { actor_miscellaneous = { actual_rept = "bad" } },
			{ actor_miscellaneous = { actual_rept = 0 } })
		eq(#why, 0); eq(accepted.actor_miscellaneous.actual_rept, 0)
	end)
	case("rank_news_can_catch_up_to_existing_engine_rank", function()
		local stock = { db = { actor = { character_rank = function() return 750 end,
			character_reputation = function() return 200 end } }, rank_table = {}, rept_table = {},
			actor_miscellaneous = { actual_rank = 0, actual_rept = 0 } }
		local previous = { actor_miscellaneous = clone(stock.actor_miscellaneous) }
		real_function(stats_source, "check_for_rank_change", stock)
		real_function(stats_source, "check_for_reputation_change", stock)
		stock.check_for_rank_change(true); stock.check_for_reputation_change(true)
		local accepted, why = P.check("alice", 7, "game_statistics", previous, { actor_miscellaneous = stock.actor_miscellaneous })
		eq(#why, 0); eq(accepted.actor_miscellaneous.actual_rank, 750); eq(accepted.actor_miscellaneous.actual_rept, 200)
	end)
	if mode == "hostplay" then
		case("host_collects_and_checks_on_its_map", function()
			eq(coop_mode.where(7), "here"); eq(coop_mode.decider(7), "this")
			assert(coop_mode.leads_here() and coop_mode.decides_world())
			P.note("alice", "corpse_search", 1, { rank = "legend" })
			local report = initial(); report.scavenging.experience = 100
			local _, why = P.check("alice", 7, "skills_levels", initial(), report); eq(#why, 0); no_failures()
		end)
	elseif mode == "srv_world" then
		case("world_checks_only_after_receiving_map_facts", function()
			eq(coop_mode.where(7), "away"); eq(coop_mode.decider(7), "other")
			assert(not coop_mode.leads_here() and coop_mode.decides_world())
			local previous, report = initial(), initial(); report.scavenging.experience = 100
			suspicious(previous, report, "scavenging: budget")
			-- This call represents a fact from the map server, received by the keeper.
			P.note("alice", "corpse_search", 1, { rank = "legend" })
			local _, why = P.check("alice", 7, "skills_levels", previous, report); eq(#why, 0)
		end)
	elseif mode == "none" then
		case("loading_rules_does_not_register_single_player_handlers", function()
			eq(coop_mode.decider(7), "nobody"); eq(P.on_game_start, nil)
		end)
	end
end
print(string.format("progress_rules: %d passed, %d failed", passed, failed))
if failed > 0 then error("progress rules failed") end
