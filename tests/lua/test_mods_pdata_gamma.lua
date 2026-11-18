-- Dev 57 G1-1. Core contract, exercised separately on both player mirrors,
-- the co-op owner, both server processes and outside a session.
-- Co-op: the owner has the map; Server: world owns records, map reports facts.
-- This adapter only restores personal mod state; neither needs new world facts.
local total_pass, total_fail = 0, 0
local roles = { "hostplay_client", "srv_client", "hostplay_owner", "srv_map", "srv_world", "none",
    "absent", "broken_install", "fixture_client" }

-- Exact save/load/accessor fixtures from the reviewed merged corpus. Keep the
-- test runnable in a clean checkout; when the corpus is present, exercise it.
local fixtures = {
    z_3dss_gamma_camo_system = [=[
function save_state(mdata)
    mdata.z_3dss_gamma_camo_system = {
        selections = selected_by_weapon,
        unlocked_sections = unlocked_sections,
        unlocked_ids = unlocked_ids,
        unlocked_named_ids = unlocked_named_ids,
        starting_faction = starting_faction,
    }
end
function load_state(mdata)
    local data = mdata.z_3dss_gamma_camo_system or {}
    if data.selections then
        selected_by_weapon = data.selections or {}
        unlocked_sections = data.unlocked_sections or {}
        unlocked_ids = data.unlocked_ids or {}
        unlocked_named_ids = data.unlocked_named_ids or {}
        starting_faction = normalize_faction(data.starting_faction)
    else
        selected_by_weapon = data
        unlocked_sections = {}
        unlocked_ids = {}
        unlocked_named_ids = {}
        starting_faction = nil
    end
end
]=],
    z_3dss_hide_bones = [=[
function save_state(mdata)
	mdata.z_3dss_hide_bones = {
		laser_hidden = laser_hidden,
		laser_mount_hidden = laser_mount_hidden,
		rail_cover_hidden = rail_cover_hidden,
		rail_cover_l_hidden = rail_cover_l_hidden,
		rail_cover_r_hidden = rail_cover_r_hidden,
		irons_off_hidden = irons_off_hidden,
	}
end
function load_state(mdata)
	local data = mdata.z_3dss_hide_bones or {}
	laser_hidden = data.laser_hidden or {}
	laser_mount_hidden = data.laser_mount_hidden or {}
	rail_cover_hidden = data.rail_cover_hidden or {}
	rail_cover_l_hidden = data.rail_cover_l_hidden or {}
	rail_cover_r_hidden = data.rail_cover_r_hidden or {}
	irons_off_hidden = data.irons_off_hidden or {}
end
]=],
    z_3dss_reticle_profiles = [=[
function save_state(mdata)
	mdata.z_3dss_reticle_profiles = {
		selected_profiles = selected_profiles,
		selected_profile_families = selected_profile_families,
	}
end
function load_state(mdata)
	local data = mdata.z_3dss_reticle_profiles or {}
	selected_profiles = type(data.selected_profiles) == "table" and data.selected_profiles or {}
	selected_profile_families = type(data.selected_profile_families) == "table"
		and data.selected_profile_families
		or {}
	migrate_saved_profile_families()
	applied_weapons = {}
end
]=],
    TB_RF_Receiver_Packages = [=[
function load_state(m_data)
	local m_data = alife_storage_manager.get_state()
	if m_data.tb_radio_has_run_once then
		tb_target_item = m_data.tb_target_item
		tb_sufficient_passed = m_data.tb_sufficient_passed
		tb_package_active = m_data.tb_package_active
		tb_reminder = m_data.tb_reminder
		tb_package_in_level = m_data.tb_package_in_level
		tb_freq = m_data.tb_freq
		tb_sender_icon = m_data.tb_sender_icon
		tb_relations = m_data.tb_relations
		tb_package_queue = m_data.tb_package_queue
	end
	if m_data.tb_radio_1_3_has_run_once then
		tb_target_lvid = m_data.tb_target_lvid
		tb_target_gvid = m_data.tb_target_gvid
		tb_bonus_items = m_data.tb_bonus_items
		tb_badguy_spawned = m_data.tb_badguy_spawned
	end
	if m_data.tb_radio_1_6_has_run_once then
		tb_previous_level = m_data.tb_previous_level
	end
	if m_data.cb_radio_1_4_has_run_once then
		cb_note_given = m_data.cb_note_given
	end
end
]=],
    drx_da_main = [=[

]=],
    zzz_bas_laser_control = [=[
function save_state(m_data)
	flush_user_cfg()
	m_data.saved_lasers_id = saved_lasers
end
function load_state(m_data)
	saved_lasers = m_data.saved_lasers_id or m_data.saved_lasers or {}
	pending_cfg = {}
	load_user_cache()
end
]=],
    campfires_on_map_mcm = [=[
function save_state(m_data)
    m_data.visited_campfires = visited_campfires
end
function load_state(m_data)
    visited_campfires = m_data.visited_campfires or {}
end
]=],
    bind_trading_computer = [=[
local function get_data(obj_id)
    if not obj_id or not hf_obj_manager then
        return {}
    end
    return hf_obj_manager.get_data(obj_id) or {}
end
local function set_data(obj_id, fields)
    if not obj_id or not hf_obj_manager then
        return
    end
    hf_obj_manager.update_data(obj_id, fields)
end
function get_last_selected_trader(obj_id)
    local d = get_data(obj_id)
    local id = tonumber(d.last_trader_id)
    if id and id > 0 then
        return id
    end
    return nil
end
function set_last_selected_trader(obj_id, trader_id)
    if not obj_id then
        return
    end
    trader_id = tonumber(trader_id)
    if trader_id and trader_id > 0 then
        set_data(obj_id, { last_trader_id = trader_id })
    end
end
]=],
}

local function run_role(role)
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env._G = env
    env.loadstring = function(source, name)
        local f, why = loadstring(source, name)
        if f then setfenv(f, env) end
        return f, why
    end
    local f = assert(loadfile("tests/lua/support/stubs_mods.lua"))
    setfenv(f, env)
    env.MODE = role:find("client") and "client" or (role == "none" and "sp" or "host")
    f()
    local function check(ok, name) env.check(ok, role .. ": " .. name) end
    local mirror = env.MODE == "client"
    env.coop.is_map_server = function() return role == "srv_map" end
    env.coop.is_dedicated = function() return role == "srv_world" end
    env.coop.world_epoch = function() return env.EPOCH or 1 end
    env.coop.levels = setmetatable({}, { __index = function() error("personal data asked for world facts") end })
    env.coop_mode = {
        actor_is_player = function() return role ~= "srv_map" and role ~= "srv_world" end,
        is_player_mirror = function() return mirror end,
    }
    env.make_actor()
    env.load_script("coop_main")
    env.load_script("coop_mods_core")
    env.load_script("coop_mods_pdata")
    env.coop_main.on_game_start()
    env.coop_mods_core.on_game_start()
    env.coop_mods_pdata.on_game_start()
    local C, P = env.coop_mods_core, env.coop_mods_pdata

    -- Compile WHOLE save/load/accessor functions from the merged corpus; only
    -- their unrelated engine/UI dependencies are stubbed. No installed game reads.
    local function corpus(name, prelude, headers, tail)
        local fh
        if role ~= "fixture_client" then fh = io.open("temp/review/corpus/merged/" .. name .. ".script", "rb") end
        local text = fh and fh:read("*a") or assert(fixtures[name], name)
        if fh then fh:close() end
        text = text:gsub("\r\n", "\n")
        local parts = { prelude }
        for _, header in ipairs(headers) do
            local start = assert(text:find(header, 1, true), header)
            local finish = assert(text:find("\nend", start, true), header .. " end")
            parts[#parts + 1] = text:sub(start, finish + 3)
        end
        parts[#parts + 1] = tail or ""
        local module = setmetatable({}, { __index = env })
        env[name] = module
        local chunk = assert(env.loadstring(table.concat(parts, "\n"), "@corpus/" .. name .. ".script"))
        setfenv(chunk, module)
        chunk()
        return module
    end
    local camo = corpus("z_3dss_gamma_camo_system", [[
        local selected_by_weapon, unlocked_sections, unlocked_ids, unlocked_named_ids, starting_faction = {}, {}, {}, {}, nil
        local function normalize_faction(v) return v end
    ]], { "function save_state(", "function load_state(" })
    local bones = corpus("z_3dss_hide_bones", [[
        local laser_hidden, laser_mount_hidden, rail_cover_hidden, rail_cover_l_hidden, rail_cover_r_hidden, irons_off_hidden
    ]], { "function save_state(", "function load_state(" })
    local reticles = corpus("z_3dss_reticle_profiles", [[
        local selected_profiles, selected_profile_families, applied_weapons = {}, {}, {}
        local function migrate_saved_profile_families() end
    ]], { "function save_state(", "function load_state(" })
    local rf = corpus("TB_RF_Receiver_Packages", "tb_bonus_items = 0", { "function load_state(" })
    local dao = corpus("drx_da_main", "opened_articles = { encyclopedia_anomalies = {} }", {})
    local laser = corpus("zzz_bas_laser_control", [[
        local saved_lasers, pending_cfg = {}, {}
        local function load_user_cache() end
        flushes = 0
        function flush_user_cfg() flushes = flushes + 1 end
        function test_set(v) saved_lasers = v end
    ]], { "function save_state(", "function load_state(" })
    local fires = corpus("campfires_on_map_mcm", "local visited_campfires = {}", { "function save_state(", "function load_state(" })
    local furniture = { [40] = { last_trader_id = 900, battery = 80 }, [41] = { last_trader_id = 901 } }
    env.hf_obj_manager = {
        get_data = function(id) return furniture[id] end,
        update_data = function(id, data) for k, v in pairs(data) do furniture[id][k] = v end end,
    }
    local computer = corpus("bind_trading_computer", "", {
        "local function get_data(", "local function set_data(",
        "function get_last_selected_trader(", "function set_last_selected_trader(",
    })
    local modules = { camo, bones, reticles, rf, laser, fires }
    -- Register stock callbacks BEFORE the adapter, to catch restoration which
    -- incorrectly depends on load_state callback order. DAO has no load callback.
    for _, m in ipairs(modules) do env.RegisterScriptCallback("load_state", m.load_state) end
    local seen_dao
    env.RegisterScriptCallback("load_state", function() seen_dao = dao.opened_articles end)

    local real_mod, wraps_before = C.mod, #C.wrapped
    if role == "absent" then
        C.mod = function(name) if env[name] and name ~= "alife_storage_manager" then return nil end return real_mod(name) end
    elseif role == "broken_install" then
        C.mod = function(name) if name == "z_3dss_gamma_camo_system" then error("broken camo addon") end return real_mod(name) end
    end
    local adapter
    local path = "gamedata/scripts/coop_mods_pdata_gamma.script"
    local exists = io.open(path, "r")
    if exists then exists:close(); adapter = env.load_script("coop_mods_pdata_gamma"); adapter.on_game_start() end
    local keys = { "z_3dss_gamma_camo_system", "z_3dss_hide_bones", "z_3dss_reticle_profiles", "tb_bonus_items",
        "drx_da_opened_articles", "saved_lasers_id", "saved_lasers", "visited_campfires", "coop_gamma_trading_choices" }
    if role == "absent" then
        check(#P.registered() == 0 and #C.wrapped == wraps_before, "missing mods install no declarations or wrappers")
        return env.PASSES, env.FAILS
    elseif role == "broken_install" then
        check(not P.owns(keys[1]) and P.owns(keys[2]) and P.owns(keys[#keys]), "one broken mod does not skip the later install steps")
        check(env.log_has("broken camo addon") ~= nil, "broken mod installation is reported")
        return env.PASSES, env.FAILS
    end
    for _, key in ipairs(keys) do check(P.owns(key), "register " .. key) end

    local function state(tag)
        return {
            z_3dss_gamma_camo_system = { selections = { [50] = "world" }, unlocked_sections = { [tag] = true },
                unlocked_ids = { [tag] = true }, unlocked_named_ids = { [tag] = true }, starting_faction = tag },
            z_3dss_hide_bones = { laser_hidden = { [tag] = true }, rail_cover_hidden = { [tag] = true } },
            z_3dss_reticle_profiles = { selected_profiles = { optic = tag }, selected_profile_families = { family = tag } },
            tb_bonus_items = tag == "host" and 99 or 3,
            tb_radio_1_3_has_run_once = true,
            drx_da_opened_articles = { encyclopedia_anomalies = { [tag] = true } },
            drx_da_effects = { world = true },
            saved_lasers_id = { [tag == "host" and 90 or 51] = true },
            saved_lasers = { [91] = true }, visited_campfires = { [tag == "host" and 92 or 52] = true },
            coop_gamma_trading_choices = { [40] = tag == "host" and 900 or 800 },
        }
    end
    local function load(data, own)
        env.STASH.coop_mods_pdata = nil
        if own then data.coop_mods_pdata = { ["500"] = { t = "mine", d = own } } end
        env.alife_storage_manager.CALifeStorageManager_load(data)
        return env.alife_storage_manager.get_state()
    end
    local function snapshot()
        local m = {}
        camo.save_state(m); bones.save_state(m); reticles.save_state(m); fires.save_state(m)
        m.tb_bonus_items = rf.tb_bonus_items
        m.drx_da_opened_articles = dao.opened_articles
        m.saved_lasers_id = C.find_local(laser, "saved_lasers")
        m.coop_gamma_trading_choices = { [40] = computer.get_last_selected_trader(40) }
        return m
    end
    if mirror then
        dao.opened_articles = { encyclopedia_anomalies = { stale = true } }
        local fresh = load(state("host"))
        local live = snapshot()
        local ca = live.z_3dss_gamma_camo_system
        check(not ca.unlocked_sections.host and not ca.unlocked_ids.host and not ca.unlocked_named_ids.host and ca.starting_faction == nil,
            "m01:1 new player clears all four camo subs")
        check(ca.selections[50] == "world", "m01:1 world/item selections stay intact")
        check(next(live.z_3dss_hide_bones.laser_hidden) == nil, "m01:3 new player clears section-keyed bones")
        check(next(live.z_3dss_reticle_profiles.selected_profiles) == nil, "m02:5 new player clears reticle choices")
        check(rf.tb_bonus_items == 0 and fresh.tb_bonus_items == 0, "m16:2 new player RF defaults to zero before mod load")
        check(seen_dao and seen_dao.encyclopedia_anomalies and next(seen_dao.encyclopedia_anomalies) == nil,
            "m19:7 new DAO table restored before load callbacks/binders")
        check(next(live.saved_lasers_id) == nil, "m29:2 neither current nor legacy host lasers leak")
        check(next(live.visited_campfires) == nil, "m32:10 new player clears visited fires")
        check(computer.get_last_selected_trader(40) == nil, "m23:8 new player never reads world last trader")

        local returning = load(state("host"), state("mine"))
        live = snapshot(); ca = live.z_3dss_gamma_camo_system
        check(ca.unlocked_sections.mine and ca.unlocked_ids.mine and ca.unlocked_named_ids.mine and ca.starting_faction == "mine"
            and not ca.unlocked_sections.host, "m01:1 returning player restores own unlocks/faction")
        check(ca.selections[50] == "world" and returning.drx_da_effects.world, "mixed/world parts never imported from player record")
        check(live.z_3dss_hide_bones.laser_hidden.mine and not live.z_3dss_hide_bones.laser_hidden.host, "m01:3 returning bones")
        check(live.z_3dss_reticle_profiles.selected_profiles.optic == "mine"
            and live.z_3dss_reticle_profiles.selected_profile_families.family == "mine", "m02:5 returning reticles")
        check(rf.tb_bonus_items == 3, "m16:2 returning RF bonus")
        check(seen_dao.encyclopedia_anomalies.mine and not seen_dao.encyclopedia_anomalies.stale, "m19:7 returning DAO is live before binders")
        check(live.saved_lasers_id[51] and not live.saved_lasers_id[90], "m29:2 returning laser state")
        check(live.visited_campfires[52] and not live.visited_campfires[92], "m32:10 returning visited fires")
        check(computer.get_last_selected_trader(40) == 800, "m23:8 returning computer choice")
        check(computer.get_last_selected_trader(41) == nil, "m23:8 no fallback for another computer")
        rf.tb_bonus_items = 4
        P.report_now()
        local report = env.sent("mods.pd")
        local reported = report and C.deser(report.d)
        check(reported and reported.tb_bonus_items == 4 and reported.z_3dss_gamma_camo_system.unlocked_ids.mine
            and reported.z_3dss_hide_bones.laser_hidden.mine and reported.z_3dss_reticle_profiles.selected_profiles.optic == "mine"
            and reported.drx_da_opened_articles.encyclopedia_anomalies.mine and reported.saved_lasers_id[51]
            and reported.visited_campfires[52] and reported.coop_gamma_trading_choices[40] == 800,
            "periodic report collects each live personal key")
        local old_hid, old_lid = C.hid, C.lid
        C.hid = function(id) return id == 42 and 142 or (id == 805 and 1805 or old_hid(id)) end
        C.lid = function(id) return id == 1805 and 805 or old_lid(id) end
        computer.set_last_selected_trader(42, 805)
        check(computer.get_last_selected_trader(42) == 805, "m23:8 device/trader ids translated across personal storage")
        for _, bad in ipairs({ -1, 0, 65535, 1.5, math.huge, 0/0 }) do
            computer.set_last_selected_trader(40, bad)
            computer.set_last_selected_trader(bad, 808)
            check(computer.get_last_selected_trader(40) == 800 and computer.get_last_selected_trader(bad) == nil,
                "m23:8 invalid local UI ids do not replace choices")
        end
        C.hid, C.lid = old_hid, old_lid
        computer.set_last_selected_trader(40, 801)
        computer.set_last_selected_trader(41, 802)
        check(furniture[40].last_trader_id == 900 and furniture[40].battery == 80, "m23:8 personal setter never mutates furniture world data")

        -- Changes in the last seconds, never written into m_data by a game save.
        local latest = state("latest")
        latest.visited_campfires = { [54] = true }
        camo.load_state(latest); bones.load_state(latest); reticles.load_state(latest); fires.load_state(latest)
        rf.tb_bonus_items = 7
        dao.opened_articles = latest.drx_da_opened_articles
        laser.test_set({ [53] = false })
        check(P.keep_for_load(2), "keep_for_load succeeds")
        local body = (env.STASH.coop_mods_pdata or ""):match("^[^|]*|(.*)$")
        local kept = body and C.deser(body) or {}
        check(kept.z_3dss_gamma_camo_system and kept.z_3dss_gamma_camo_system.unlocked_sections.latest
            and kept.z_3dss_gamma_camo_system.unlocked_ids.latest and kept.z_3dss_gamma_camo_system.unlocked_named_ids.latest
            and kept.z_3dss_gamma_camo_system.starting_faction == "latest" and kept.z_3dss_gamma_camo_system.selections == nil,
            "m01:1 keep_for_load primes only camo subs")
        check(kept.z_3dss_hide_bones and kept.z_3dss_hide_bones.laser_hidden.latest, "m01:3 keep_for_load primes bones")
        check(kept.z_3dss_reticle_profiles and kept.z_3dss_reticle_profiles.selected_profiles.optic == "latest", "m02:5 keep_for_load primes reticles")
        check(kept.tb_bonus_items == 7, "m16:2 keep_for_load reads live RF")
        check(kept.drx_da_opened_articles and kept.drx_da_opened_articles.encyclopedia_anomalies.latest, "m19:7 keep_for_load reads live DAO")
        check(kept.saved_lasers_id and kept.saved_lasers_id[53] == false, "m29:2 keep_for_load reads laser upvalue including false")
        check(kept.visited_campfires and kept.visited_campfires[54] and not kept.visited_campfires[52],
            "m32:10 keep_for_load uses latest campfire save on scratch")
        check(kept.coop_gamma_trading_choices and kept.coop_gamma_trading_choices[40] == 801
            and kept.coop_gamma_trading_choices[41] == 802, "m23:8 keep_for_load carries device choices")
        check(kept.coop_gamma_trading_choices and kept.coop_gamma_trading_choices[142] == 1805,
            "m23:8 saved ids stay in host numbering")
        check(laser.flushes == 0, "m29:2 polling/transition never flush laser user config")
        env.EPOCH = 2
        env.alife_storage_manager.CALifeStorageManager_load(state("host"))
        live = snapshot()
        check(live.z_3dss_gamma_camo_system.unlocked_sections.latest and live.z_3dss_hide_bones.laser_hidden.latest
            and live.z_3dss_reticle_profiles.selected_profiles.optic == "latest" and rf.tb_bonus_items == 7
            and live.drx_da_opened_articles.encyclopedia_anomalies.latest and live.visited_campfires[54]
            and live.saved_lasers_id[53] == false and computer.get_last_selected_trader(41) == 802,
            "latest personal state survives transition load")
        local no_flags = state("host")
        no_flags.tb_radio_1_3_has_run_once = nil
        load(no_flags, { tb_bonus_items = 8 })
        check(rf.tb_bonus_items == 8, "m16:2 restore RF even when the shared save has no RF version flag")
        local legacy_lasers = state("host")
        legacy_lasers.saved_lasers_id = nil
        load(legacy_lasers)
        check(next((C.find_local(laser, "saved_lasers"))) == nil, "m29:2 legacy-only host save cannot restore foreign lasers")
        local no_selections = state("host")
        no_selections.z_3dss_gamma_camo_system = nil
        load(no_selections, state("mine"))
        check(snapshot().z_3dss_gamma_camo_system.unlocked_sections.mine,
            "m01:1 own unlocks restored when world save has no camo selections/version sentinel")
        local old_camo = state("host")
        old_camo.z_3dss_gamma_camo_system = { [60] = "legacy world item" }
        load(old_camo, state("mine"))
        local migrated = snapshot().z_3dss_gamma_camo_system
        check(migrated.selections[60] == "legacy world item" and migrated.unlocked_sections.mine
            and migrated.selections.unlocked_sections == nil, "m01:1 legacy item selections kept separate from personal camo subs")
        -- A second new character in the same Lua state must also reset live variables.
        load(state("host"))
        check(rf.tb_bonus_items == 0 and next(dao.opened_articles.encyclopedia_anomalies) == nil
            and computer.get_last_selected_trader(40) == nil, "new character cannot inherit previous player's live state")
    else
        local original = state("host")
        load(original)
        check(rf.tb_bonus_items == 99, "authority/single player RF untouched")
        local untouched = snapshot()
        check(untouched.z_3dss_gamma_camo_system.unlocked_sections.host and untouched.z_3dss_hide_bones.laser_hidden.host
            and untouched.z_3dss_reticle_profiles.selected_profiles.optic == "host" and untouched.saved_lasers_id[90]
            and untouched.visited_campfires[92], "authority/single player mod state untouched")
        check(next(dao.opened_articles.encyclopedia_anomalies) == nil, "authority/single player DAO retains its stock load timing")
        computer.set_last_selected_trader(40, 803)
        local saved = {}
        env.SendScriptCallback("save_state", saved)
        if role == "none" then
            check(furniture[40].last_trader_id == 803 and computer.get_last_selected_trader(40) == 803,
                "single player getter/setter call original unchanged")
            check(saved.coop_gamma_trading_choices == nil, "single player adds no personal storage")
        elseif role == "hostplay_owner" then
            check(computer.get_last_selected_trader(40) == 803 and furniture[40].last_trader_id == 900,
                "co-op owner's computer choice is private too")
            check(saved.coop_gamma_trading_choices and saved.coop_gamma_trading_choices[40] == 803, "owner choice saved without client reports")
            load({ coop_gamma_trading_choices = { [40] = 804 } })
            check(computer.get_last_selected_trader(40) == 804, "owner choice restored from normal save")
        else
            check(saved.coop_gamma_trading_choices == nil, "server ghost does not save personal computer state")
        end
    end
    if adapter then
        local n = #C.wrapped
        adapter.on_game_start()
        check(#C.wrapped == n, "installation is idempotent")
    end
    return env.PASSES, env.FAILS
end

for _, role in ipairs(roles) do
    local ok, p, f = pcall(run_role, role)
    if ok then total_pass, total_fail = total_pass + p, total_fail + f
    else print("  FAIL " .. role .. " runtime: " .. tostring(p)); total_fail = total_fail + 1 end
end
print(string.format("GAMMA PDATA: %d passed, %d failed", total_pass, total_fail))
if total_fail > 0 then error("GAMMA PDATA FAILED") end
