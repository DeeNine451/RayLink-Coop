-- G12-3: real VAR functions, local HUD callbacks, level-owned recovery/inventories.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local function corpus(name)
    local f = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "r"))
    local s = f:read("*a"); f:close(); return s
end
local function real_function(src, name, env)
    local a = assert(src:find("function " .. name .. "(", 1, true))
    local b = src:find("\nfunction ", a + 1, true) or (#src + 1)
    local class_at = src:find("\nclass ", a + 1, true)
    if class_at and class_at < b then b = class_at end
    local f = assert(loadstring(src:sub(a, b - 1), "@corpus/" .. name))
    setfenv(f, env); f()
end
for _, name in ipairs(modes.names()) do
    local ac = { companion_squads = {}, list_actor_squad_by_id = function() return { 101 } end }
    axr_companions = ac
    agdd_voiced_actor = {}
    local env = setmetatable({ axr_companions = ac }, { __index = _G })
    for _, fn in ipairs({ "squad_near", "squad_can_hear", "squad_out" }) do
        real_function(corpus("agdd_voiced_actor"), fn, agdd_voiced_actor)
    end
    setmetatable(agdd_voiced_actor, { __index = _G })
    for _, fn in ipairs({ "squad_close", "squad_near", "squad_mid", "squad_far", "squad_too_far", "actors_command" }) do
        real_function(corpus("axr_companions_varefined"), "axr_companions." .. fn, env)
    end
    local quick = { commands_with_lang_muffle = function(s) return s end }
    setmetatable(quick, { __index = _G })
    real_function(corpus("ui_addon_companion_quick_menu"), "on_key_press", quick)
    ui_addon_companion_quick_menu = quick
    grok_companions_no_ammo = setmetatable({}, { __index = _G })
    real_function(corpus("grok_companions_no_ammo"), "unload_ammo", grok_companions_no_ammo)
    start_all()
    modes.install(coop_mode, name)
    coop_trust.reset_for_test({ default = "refuse" })
    local actor = make_actor(vec3(0, 0, 0))
    local _, leader = spawn("leader", vec3(40, 0, 0), nil, { id = 500 })
    local _, npc = spawn("companion", vec3(2, 0, 0), nil, { id = 101, kind = "stalker" })
    local _, weapon = spawn("rifle", nil, 101, { id = 102, kind = "weapon" })
    local held, lead, owner = true, leader, leader:id()
    local flags = { npcx_is_companion = true }
    npc.has_info = function(_, k) return flags[k] == true end
    npc.dont_has_info = function(_, k) return not flags[k] end
    npc.best_enemy = function() return nil end
    weapon._ammo = 12
    weapon.set_ammo_elapsed = function(self, n) self._ammo = n end
    coop_npc_companions = {
        held_here = function() return held end,
        leader_of = function() return lead end,
        owner_character = function() return owner end,
    }
    db.storage[101] = { object = npc }
    local non_entity_probes = 0
    local _, anomaly = spawn("anomaly", nil, nil, { id = 103, kind = "anomaly" })
    anomaly.has_info = function() return false end
    anomaly.alive = function() non_entity_probes = non_entity_probes + 1; return false end
    db.storage[103] = { object = anomaly }
    db.offline_objects, db.spawned_vertex_by_id = { [101] = { level_vertex_id = 7 } }, { [101] = 7 }
    state_mgr = { get_state = function() return "panic" end }
    local teleports = 0
    local sim = alife()
    sim.teleport_object = function(_, id, gv, lv, pos)
        check(id == 101 and gv == 8 and lv == 7 and pos.x == npc:position().x, name .. ": recovery stays in place")
        teleports = teleports + 1
    end
    alife = function() return sim end
    local renders, removes, updates, listed = 0, 0, 0, nil
    get_hud = function() return {
        AddDialogToRender = function() renders = renders + 1 end,
        RemoveDialogToRender = function() removes = removes + 1 end,
    } end
    ac.UICompanionList = function() return { Update = function()
        updates = updates + 1; listed = ac.list_actor_squad_by_id()
    end } end
    local stock_calls = 0
    ac.activate_hud = function() stock_calls = stock_calls + 1 end
    ac.deactivate_hud = function() stock_calls = stock_calls + 1 end
    agdd_voiced_actor.actor_speak = function() stock_calls = stock_calls + 1 end
    agdd_voiced_actor.is_actor_in_combat = function() return true end
    dik_to_bind = function(k) return k end
    key_bindings = { kCUSTOM18 = 18 }
    ui_inventory = { GUI = { GetPartner = function() return npc end } }
    for _, cb in ipairs({ "GUI_on_show", "GUI_on_hide", "on_console_execute", "actor_on_net_destroy", "on_game_load" }) do
        AddScriptCallback(cb)
    end
    -- Registered by value before the adapter, as happens for optional mods.
    RegisterScriptCallback("GUI_on_show", grok_companions_no_ammo.unload_ammo)
    RegisterScriptCallback("on_key_press", quick.on_key_press)
    local module_file = io.open("gamedata/scripts/coop_npc_companions_ui.script", "r")
    local ui = {}
    if module_file then module_file:close(); ui = load_script("coop_npc_companions_ui") end
    if ui.on_game_start then ui.on_game_start(); ui.on_game_start() end
    local function fire(cb, ...) SendScriptCallback(cb, ...) end
    local function tick() NOW = NOW + 30001; fire("actor_on_update") end
    if name == "none" then
        MODE = "sp"
        check(not ac.squad_close(), "none: original VAR still uses empty stock list")
        ac.activate_hud()
        check(stock_calls == 1, "none: original HUD unchanged")
        fire("GUI_on_show", "UIInventory")
        check(weapon._ammo == 0, "none: original no-ammo unchanged")
        tick(); tick()
        check(teleports == 0, "none: no adapter recovery")
    else
        -- A player mirror in either mode; the facade supplies player/map answers.
        MODE, SELF = "client", 1
        modes.install(coop_mode, name, {
            actor_is_player = function() return true end,
            is_player_mirror = function() return true end,
            leads_here = function() return false end,
        })
        fire("actor_on_first_update")
        fire("actor_on_first_update")
        check(renders == 1, name .. ": m13:4 client panel created once")
        fire("GUI_on_show", "other")
        check(updates > 0 and listed and listed[1] == 101, name .. ": local callbacks use adapted list")
        check(agdd_voiced_actor.squad_near(), name .. ": m12:1 synchronized living companion near local player")
        check(ac.squad_close(), name .. ": personal close voice uses synchronized flag")
        held = false
        check(not ac.squad_close() and agdd_voiced_actor.squad_near(), name .. ": personal command excludes foreign squad")
        held = true; flags.npcx_is_companion = nil
        check(not agdd_voiced_actor.squad_near(), name .. ": non-companion excluded")
        flags.npcx_is_companion = true; npc._alive = false
        check(not agdd_voiced_actor.squad_near(), name .. ": dead companion excluded")
        check(agdd_voiced_actor.squad_out(), name .. ": no living companions retains solitary voice")
        check(non_entity_probes == 0, name .. ": VAR never calls alive on a non-entity in db.storage")
        npc._alive = true
        for _, band in ipairs({ { 12, "squad_close" }, { 24, "squad_near" }, { 40, "squad_mid" }, { 60, "squad_far" }, { 61, "squad_too_far" } }) do
            npc._pos.x = band[1]
            check(ac[band[2]](), name .. ": voice distance boundary " .. band[1])
        end
        npc._pos.x = 2
        local random = math.random; math.random = function() return 99 end
        local before = stock_calls
        fire("on_key_press", 18); math.random = random
        check(stock_calls == before + 1, name .. ": kCUSTOM18 voice not suppressed by empty stock list")
        fire("GUI_on_show", "UIInventory")
        check(weapon._ammo == 12, name .. ": m16:7 mirror never clears magazine before confirmation")
        local req = sent("mods.compui_no_ammo")
        check(req and req.i == 101, name .. ": opening inventory requests map owner with host id")
        local function confirm(t, from)
            coop_main.on_event("mods.compui_ammo_state", coop_main.encode(t), from)
        end
        confirm({ i = 101, w = 102, a = 0 }, 2)
        check(weapon._ammo == 12, name .. ": forged magazine confirmation ignored")
        confirm({ i = 101, w = 102, a = -1 }, 0)
        check(weapon._ammo == 12, name .. ": invalid confirmation amount ignored")
        SE[102].parent_id = 0
        confirm({ i = 101, w = 102, a = 0 }, 0)
        check(weapon._ammo == 12, name .. ": late confirmation cannot clear transferred weapon")
        SE[102].parent_id = 101
        confirm({ i = 101, w = 102, a = 0 }, 0)
        check(weapon._ammo == 0, name .. ": confirmed authoritative magazine reaches client")
        weapon._ammo = 12
        CreateTimeEvent("cycle", "companion_unstuck", 30, function() error("mirror stock timer survived") end)
        tick(); tick()
        check(teleports == 0, name .. ": mirror cannot unstuck")
        check(TIMEEV["cycle:companion_unstuck"] == nil, name .. ": mirror retires stock recovery timer")
        MODE = "sp" -- The session can end before the actor binder is destroyed.
        fire("actor_on_net_destroy")
        check(removes == 1 and ac.HUD == nil, name .. ": panel removed after session teardown")
        MODE = "client"
        fire("actor_on_first_update")
        check(renders == 2, name .. ": panel recreated after load")
        local callback_count = axr_main.count("GUI_on_show")
        fire("on_game_load"); fire("actor_on_first_update"); fire("actor_on_first_update")
        check(renders == 3 and removes == 2 and axr_main.count("GUI_on_show") == callback_count,
            name .. ": load removes panel without duplicate registrations")

        MODE, SELF = "host", 0
        modes.install(coop_mode, name)
        local function request(t, from)
            if name == "srv_map" then t._peer = from; from = 0 end
            coop_main.on_event("mods.compui_no_ammo", coop_main.encode(t), from)
        end
        if name == "srv_world" then
            request({ i = 101 }, 1)
            check(weapon._ammo == 12, "srv_world: no inventory mutation without player's map")
            local forwarded = sent("mods.compui_no_ammo")
            check(forwarded and forwarded._peer == 1 and SENT[#SENT].target == 0x101,
                "srv_world: authenticated request forwarded to player's map")
            CreateTimeEvent("cycle", "companion_unstuck", 30, function() error("world stock timer survived") end)
            tick(); tick()
            check(teleports == 0, "srv_world: no recovery on ghost map")
            check(TIMEEV["cycle:companion_unstuck"] == nil, "srv_world: ghost never runs stock recovery timer")
            coop_trust.reset_for_test({ default = "log" })
            modes.install(coop_mode, name, { level_request = function(_, payload, from)
                return "here", payload, from, false -- no bridge for the player yet
            end })
            request({ i = 101 }, 1)
            local check_distance = coop_trust.status().compui_ammo_distance
            check(check_distance and check_distance.failed == 1 and weapon._ammo == 12,
                "srv_world: fallback dispatch logs the failed check and cannot mutate without a map")
        else
            -- Host is 2m away, real leader is 38m away: stock distance was wrong.
            CreateTimeEvent("cycle", "companion_unstuck", 30, function() error("stock timer survived") end)
            tick(); tick()
            check(teleports == 1, name .. ": m13:1 recovery measured to real leader")
            check(TIMEEV["cycle:companion_unstuck"] == nil, name .. ": old timer disabled")
            lead = nil; tick(); tick()
            check(teleports == 1, name .. ": no leader means no recovery")
            lead, leader._pos.x, actor._pos.x = leader, 4, 40
            tick(); tick()
            check(teleports == 1, name .. ": near real leader does not recover even when local actor is far")
            actor._pos.x = 0
            lead, owner = actor, nil
            request({ i = 101, from = 0 }, 1)
            check(weapon._ammo == 12, name .. ": m16:7 a companion of no player is refused (transport sender)")
            local c = coop_trust.status().compui_ammo_owner
            check(c and c.refused == 1, name .. ": ownership goes through trust")
            -- Ruling F2-32b (coop_requests.cpp, moves::check): every companion of the group shares its inventory, so
            -- another player's companion is honest (review RV-G12-3).
            lead, owner = actor, actor:id()
            request({ i = 101 }, 1)
            check(weapon._ammo == 0 and coop_trust.status().compui_ammo_owner.refused == 1,
                name .. ": another player's companion: the group's shared inventory, cleared, no refusal")
            weapon._ammo = 12
            lead, owner = leader, leader:id()
            request({ i = 101 }, 1)
            check(weapon._ammo == 0, name .. ": map owner clears authorized magazine")
            check(sent("mods.compui_ammo_state") ~= nil, name .. ": confirmed magazine state published")
            local reply = sent("mods.compui_no_ammo_r")
            check(reply and reply.i == 101 and reply.n == 1 and SENT[#SENT].target == 1,
                name .. ": confirmation answered to transport requester")
            weapon._ammo = 9; leader._pos.x = 100
            request({ i = 101 }, 1)
            check(weapon._ammo == 9, name .. ": far request refused")
            leader._pos.x = 4
            if name == "srv_map" then
                modes.install(coop_mode, name, { where = function() return "away" end,
                    decider = function() return "other" end })
                request({ i = 101 }, 1)
                check(weapon._ammo == 9, "srv_map: player on another map cannot clear local companion")
                modes.install(coop_mode, name)
            end
            local setter = weapon.set_ammo_elapsed
            weapon.set_ammo_elapsed = function() end
            local states = sent_count("mods.compui_ammo_state")
            request({ i = 101 }, 1)
            local incomplete = sent("mods.compui_no_ammo_r")
            check(sent_count("mods.compui_ammo_state") == states and incomplete and incomplete.n == 0,
                name .. ": failed authoritative setter never claims confirmed state")
            weapon.set_ammo_elapsed = setter
            for _, bad in ipairs({ -1, 65535, 1.5, "101", "x%s" }) do request({ i = bad }, 1) end
            check(weapon._ammo == 9, name .. ": invalid ids cannot target inventory")
            coop_trust.reset_for_test({ default = "log" })
            lead, owner = actor, nil
            NOW = NOW + 10000
            request({ i = 101 }, 1)
            c = coop_trust.status().compui_ammo_owner
            check(c and c.failed == 1 and c.refused == 0 and weapon._ammo == 0, name .. ": new trust check logs and permits in log mode")
            flags.npcx_is_companion = nil
            weapon._ammo = 9
            request({ i = 101 }, 1)
            local check_companion = coop_trust.status().compui_ammo_companion
            check(check_companion and check_companion.failed == 1 and weapon._ammo == 9,
                name .. ": stale companion id logs the failed check and leaves a non-companion alone")
            flags.npcx_is_companion = true
            if name == "hostplay" then
                lead, owner = nil, 0 -- real leader_of only resolves proxies; the unassigned squad is the host’s
                npc._pos.x = 20
                fire("on_game_load"); tick(); tick()
                check(teleports == 2, "hostplay: a host-owned squad uses the local player as its real leader")
                npc._pos.x = 2
                weapon._ammo = 11
                fire("GUI_on_show", "UIInventory")
                check(weapon._ammo == 0, "hostplay: own player takes same direct authority path")
            end
        end
    end
end
done("companions_ui")
