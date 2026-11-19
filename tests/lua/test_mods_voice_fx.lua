-- G11-3. Exercise the winning GAMMA callbacks through the real mod/event helpers.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local ORDER, WOUND = "mods.voice_fx_order", "mods.voice_fx_wound"

local function corpus(name, env, extract)
    local file = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "r"))
    local source = file:read("*a")
    file:close()
    if extract then
        local first = assert(source:find("\nfunction " .. extract .. "(", 1, true))
        local last = assert(source:find("\nend", first, true))
        source = source:sub(first, last + 3)
    end
    local chunk = assert(loadstring(source, "@gamedata/scripts/" .. name .. ".script"))
    setfenv(chunk, setmetatable(env, { __index = _G }))
    chunk()
    return env
end

local function npc(section, id, x)
    local _, obj = spawn(section, vec3(x, 0, 0), nil, { id = id, kind = "stalker" })
    local flags = {}
    function obj:give_info_portion(key) flags[key] = true end
    function obj:disable_info_portion(key) flags[key] = nil end
    function obj:has_info(key) return flags[key] == true end
    function obj:get_visual_name() return section end
    return obj
end

local function case(name)
    MODE, SELF = name == "none" and "sp" or "host", name == "srv_map" and 128 or 0
    coop.is_map_server = function() return name == "srv_map" and MODE == "host" end
    coop.is_dedicated = function() return name == "srv_world" end
    coop.players = function()
        if name == "srv_map" then
            return { { id = 1, avatar_id = 501 }, { id = 2, avatar_id = 502 }, { id = 3, avatar_id = 503 } }
        end
        return { { id = 0, avatar_id = 0 }, { id = 1, avatar_id = 501 }, { id = 2, avatar_id = 502 } }
    end
    coop.avatar_of = function(peer)
        if peer == SELF then return 0 end
        if peer >= 1 and peer <= 3 then return 500 + peer end
    end
    local actor = make_actor()
    npc("initiator", 501, 30)
    npc("observer", 502, 32)
    npc("other_map", 503, 34)
    local companion = npc("companion", 45, 35)
    companion:give_info_portion("npcx_is_companion")
    local recruit = npc("recruit", 46, 36)
    local enemy = npc("enemy", 47, 38)
    local lines, intensity, prefix, shouts = {}, 0, "authority/", true
    local function speak(line)
        if line then lines[#lines + 1] = line end
    end
    agdd_voiced_actor = corpus("agdd_voiced_actor", {
        actor_speak = speak,
        actor_speak_default = speak,
        actor_speak_with_priority_ignore_conditionals = speak,
        commands_with_lang_muffle_random = function(line) return prefix .. line end,
        squad_with_lang_muffle = function(line) return prefix .. line end,
        is_actor_in_combat = function() return false end,
        outer_combat_checker = function() return false end,
        add_action_intensity = function() intensity = intensity + 1 end,
    }, "npc_on_hit_callback")
    axr_companions = {
        add_to_actor_squad = function(obj) obj:give_info_portion("npcx_is_companion") end,
        remove_from_actor_squad = function() end,
        companion_squads = { { commander_id = function() return 45 end } },
    }
    dialogs_axr_companion = {
        is_actor_companion = function(_, obj) return obj:has_info("npcx_is_companion") end,
        become_actor_companion = function(_, obj)
            if rawequal(obj, recruit) then axr_companions.add_to_actor_squad(obj) end
        end,
    }
    save_var = function() end
    varefined_mcm = { get_config = function() return shouts end }
    ui_mcm = {}
    axr_companions_varefined = corpus("axr_companions_varefined", {})
    xr_motivator = { motivator_binder = {} }
    death_manager = { get_outfit_by_npc_visual = function(visual) return { visual } end }
    SYS_GetParam = function(_, outfit) return outfit == "heavy_exo" and "outfit_exo" or "" end
    z_npc_footsteps = corpus("z_npc_footsteps", {})

    local steps = {}
    local constructor = sound_object
    sound_object = setmetatable({ s3d = constructor.s3d }, { __call = function(_, filename)
        return { play_at_pos = function(_, owner, position, delay, flags)
            steps[#steps + 1] = { filename = filename, owner = owner, position = position, delay = delay, flags = flags }
        end }
    end })
    local heavy, light = npc("heavy_exo", 55, 10), npc("light_proto", 56, 11)
    local step = z_npc_footsteps.npc_on_foot_step -- net_spawn holds the callback by value.
    step(nil, heavy) -- exercise a handle already cached at install.
    steps = {}

    AddScriptCallback("npc_on_hit_callback")
    RegisterScriptCallback("npc_on_hit_callback", agdd_voiced_actor.npc_on_hit_callback)
    MODS_FILES[#MODS_FILES + 1] = "coop_mods_voice_fx"
    local file = io.open("gamedata/scripts/coop_mods_voice_fx.script", "r")
    if file then file:close() else MODS_FILES[#MODS_FILES] = nil end
    start_all()
    modes.install(coop_mode, name, {
        where = function(peer)
            return (peer == 1 or peer == 2 or (peer == 0 and name == "hostplay")) and "here" or "away"
        end,
    })
    if file then MODS_FILES[#MODS_FILES] = nil end

    local accepted = false
    -- It is the existing companion router's handler that decides whether the VAR setter runs.
    coop_npc_players.on("npc.comp", function(t)
        if t.k == "wait" then
            axr_companions.set_companion_to_wait_state(companion)
            axr_companions.set_companion_to_wait_state(companion)
        elseif t.k == "follow" then
            axr_companions.set_companion_to_follow_state(companion)
        elseif t.k == "attack" then
            axr_companions.set_companion_to_attack_state(companion)
        elseif t.k == "hire" then
            dialogs_axr_companion.become_actor_companion(actor, recruit)
        elseif t.k == "no_squad" then
            dialogs_axr_companion.become_actor_companion(actor, enemy)
        else
            return
        end
        accepted = true
    end, "host", "companions")
    local function request(action, id, source)
        local peer = name == "srv_map" and 1 or 2
        local target = action == "hire" and 46 or action == "no_squad" and 47 or 45
        deliver({ name = "npc.comp", payload = coop_main.encode({ i = id or target, k = action, _peer = peer }) },
            source or (name == "srv_map" and 0 or 1))
    end
    local function hit()
        SendScriptCallback("npc_on_hit_callback", companion, 0.2, vector(), enemy, 1)
    end
    local function expect(condition, what) check(condition, name .. " " .. what) end
    local function check_servos(process, keep_owner)
        steps = {}
        step(nil, heavy)
        step(nil, light)
        step(nil, companion)
        expect(#steps == 2 and steps[1].filename:find("heavy_servo", 1, true) and steps[2].filename:find("light_servo", 1, true)
            and steps[1].position.x == 10 and steps[2].position.x == 11 and steps[1].delay == 0 and steps[2].flags == sound_object.s3d,
            "m25:4 " .. process .. " plays once at each exo NPC position and skips ordinary outfits")
        local expected_heavy, expected_light
        if keep_owner then expected_heavy, expected_light = heavy, light end
        expect(steps[1] and steps[2] and rawequal(steps[1].owner, expected_heavy) and rawequal(steps[2].owner, expected_light),
            "m25:4 " .. process .. " omits the servo owner only in session")
    end
    check_servos("authority or single player", name == "none")

    if name == "hostplay" or name == "srv_map" then
        request("refused")
        request("no_squad")
        expect(sent_count(ORDER) == 0 and #lines == 0, "refused and no-op offers stay silent")
        request("wait", 65535)
        expect(not companion:has_info("npcx_beh_wait") and log_has("invalid companion id"),
            "an out-of-range request reaches trust without calling the setter")
        if name == "srv_map" then
            request("wait", 45, 2)
            expect(not companion:has_info("npcx_beh_wait") and sent_count(ORDER) == 0,
                "a map request must arrive through the world relay")
        else
            axr_companions.set_companion_to_wait_state(companion)
            expect(#lines == 1 and lines[1] == "authority/wait_com_mid" and sent_count(ORDER) == 0,
                "host's own command plays locally")
            lines = {}
        end
        shouts = false
        axr_companions_varefined.on_option_change()
        request("wait")
        request("follow")
        request("attack")
        request("hire")
        local orders = {}
        for _, event in ipairs(SENT) do
            if event.name == ORDER then orders[#orders + 1] = event end
        end
        expect(accepted and recruit:has_info("npcx_is_companion"), "authority still changes companion state")
        expect(#orders == 4 and #lines == 0, "m12:2 accepted orders and a hire each send one line without authority speech")
        local private = #orders > 0
        for _, event in ipairs(orders) do private = private and event.target == 1 end
        expect(private, "m12:2 only the transport initiator receives the order voice")

        lines = {}
        hit()
        local wounds, same_map = {}, true
        for _, event in ipairs(SENT) do
            if event.name == WOUND then wounds[#wounds + 1] = event; same_map = same_map and event.target <= 2 end
        end
        expect(#wounds == 2 and same_map and wounds[1].target ~= wounds[2].target, "m12:3 one hit notification per same-map remote player")
        expect(#lines == (name == "hostplay" and 1 or 0) and intensity == 0, "m12:3 only a playing authority reacts locally to the wound")

        MODE, SELF, prefix = "client", 1, "initiator/"
        modes.install(coop_mode, name, {
            actor_is_player = function() return true end,
            leads_here = function() return false end,
            is_player_mirror = function() return true end,
        })
        lines, shouts = {}, true
        axr_companions_varefined.on_option_change()
        for _, event in ipairs(orders) do deliver(event, 0) end
        expect(table.concat(lines, ",") == "initiator/wait_com_close,initiator/follow_com_close,initiator/fire_at_will_com_close,initiator/squadmate_joined",
            "m12:2 the initiator picks the lines with local MCM and the ordered companion's range")
        lines, shouts = {}, false
        axr_companions_varefined.on_option_change()
        if orders[1] then deliver(orders[1], 0) end
        expect(#lines == 0, "initiator MCM can mute accepted commands")
        shouts = true
        axr_companions_varefined.on_option_change()
        if orders[1] then deliver(orders[1], 2) end
        expect(#lines == 0, "client cannot send a voice acknowledgement")
        for _, event in ipairs(wounds) do
            if event.target == SELF then deliver(event, 0) end
        end
        expect(#lines == 1 and lines[1] == "initiator/squadmate_hit" and intensity == 0,
            "m12:3 NPC attack speaks on the observer through the wound notification alone")
        agdd_voiced_actor.npc_on_hit_callback(companion, 0.2, vector(), db.actor, 1) -- existing attacker replay
        expect(#lines == 1 and lines[1] == "initiator/squadmate_hit" and intensity == 1,
            "m12:3 notification voices once without replaying hit intensity")
        local original_level_name = level.name
        level.name = function() return "l02_garbage" end
        for _, event in ipairs(wounds) do
            if event.target == SELF then deliver(event, 0) end
        end
        expect(#lines == 1, "a wound that arrives after travel does not play on another map")
        level.name = original_level_name
        check_servos("mirror", false)
    elseif name == "srv_world" then
        request("wait")
        local relayed, event = sent("npc.comp")
        expect(not accepted and sent_count(ORDER) == 0 and event and event.target == modes.set(name).bridge and relayed._peer == 1,
            "world relays to the map and supplies the transport peer")
        hit()
        expect(sent_count(WOUND) == 0 and #lines == 0, "world console neither speaks nor fans out a map wound")
    else
        axr_companions.set_companion_to_wait_state(companion)
        hit()
        expect(table.concat(lines, ",") == "authority/wait_com_mid,authority/squadmate_hit" and #SENT == 0,
            "single-player VAR commands and wound callback keep their stock behavior")
    end

    sound_object = constructor
end

for _, name in ipairs(modes.names()) do case(name) end
done("mods_voice_fx")
