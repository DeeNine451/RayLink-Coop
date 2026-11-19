-- F4 G8-1 (m31:2): 426- Dynamic Emission Cover (dynamic_emission_cover_mcm.script:20-53) protects a companion that
-- surge_manager.CSurgeManager.pos_in_cover asks about when "the actor" is in dynamic cover (dynamic_is_safe) and within
-- protect_companions_range of it. In a session the actor of the process that leads the map is the host (co-op) or a
-- ghost (a map server): a client's companion next to its sheltered leader was judged by the wrong body.
-- The fakes keep the shape of the mod (its on_game_start patch, word for word below, reading its module globals) and of
-- surge_manager's stock restrictor check. The adapter is started as axr_main does: every on_game_start first (the
-- adapter's name sorts before the mod's), then the actor's first update.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

load_script("coop_main")
for _, n in ipairs(MODE_FILES) do load_script(n) end
load_script("coop_mods_core")
for _, n in ipairs(MODE_FILES) do _G[n].on_game_start() end

local ADAPTER = "coop_mods_emission_cover"
local LABEL = "emission_cover.pos_in_cover"

-- dynamic_emission_cover_mcm.script:4-53 (the companion patch) and its MCM globals (:62-69, :117), as GAMMA loads it.
local MOD_SRC = [[
function on_game_start()
    local base_pos_in_cover = surge_manager.CSurgeManager.pos_in_cover
    function surge_manager.CSurgeManager.pos_in_cover(self, pos, by_name)
        local result = base_pos_in_cover(self, pos, by_name)
        if result then
            return result
        end

        if protect_companions_range == 0 or not dynamic_is_safe then
            return false
        end

        local pos = vector():set(pos)
        for id,squad in pairs(axr_companions.companion_squads) do
            if (squad and squad.commander_id) then
                for k in squad:squad_members() do
                    local member = db.storage[k.id] and db.storage[k.id].object or level.object_by_id(k.id)
                    if (member and member:alive()) then
                        local dist = pos:distance_to(vector():set(member:position()))
                        if dist == 0 then
                            local dist_to_actor = db.actor:position():distance_to(vector():set(pos))
                            if dist_to_actor <= protect_companions_range then
                                return true
                            else
                                return false
                            end
                        end
                    end
                end
            end
        end
        return false
    end
end
protect_companions_range = 15
dynamic_is_safe = false
excluded_maps = {}
]]

local function load_fake(name, src)
	local this = setmetatable({}, { __index = _G })
	rawset(_G, name, this)
	local f = assert(loadstring(src, "@" .. name .. ".script"))
	setfenv(f, this)
	f()
	return this
end

local function load_adapter()
	local fh = io.open(ROOT .. "scripts/" .. ADAPTER .. ".script", "r")
	if not fh then
		rawset(_G, ADAPTER, nil)
		return nil
	end
	fh:close()
	return load_script(ADAPTER)
end

local LEADERS, COVER, SM, DYN, A -- per boot

-- A fresh world: surge_manager's stock check (a position inside a named restrictor), the mod, the companions, the
-- players. Returns the surge manager object the stock calls pos_in_cover on.
local function boot(set, opts)
	opts = opts or {}
	SE, OBJ, NEXT_ID = {}, {}, 1000
	db = { storage = {} }
	coop.is_map_server = function() return set == "srv_map" end
	coop.is_dedicated = function() return set == "srv_world" end
	MODE = set == "none" and "sp" or "host"
	local cls = {}
	-- surge_manager.script:396-415: true (or the restrictor's name) inside one of self.covers, else false
	function cls.pos_in_cover(self, pos, by_name)
		if not self.covers then return end
		if pos.shelter and self.covers[pos.shelter] then return by_name and pos.shelter or true end
		return false
	end
	if opts.no_surge then
		rawset(_G, "surge_manager", nil)
		surge_manager = nil
	else
		rawset(_G, "surge_manager", { CSurgeManager = cls })
	end
	SM = setmetatable({ covers = { shelter = true } }, { __index = cls })
	DYN = not opts.no_mod and load_fake("dynamic_emission_cover_mcm", MOD_SRC) or nil
	if opts.no_mod then rawset(_G, "dynamic_emission_cover_mcm", nil) end
	rawset(_G, "axr_companions", { companion_squads = {} })
	LEADERS, COVER = {}, {}
	rawset(_G, "coop_npc_companions", { leader_of = function(npc)
		local id = LEADERS[npc:id()]
		return id and level.object_by_id(id) or nil
	end })
	rawset(_G, "coop_env_cover", { cover_of = function(id)
		local r = COVER[id]
		if r then return r.c, r.age, r.c and "dynamic" or "none" end
	end })
	make_actor(vec3(0, 0, 0))
	-- the client's character (peer 1), as coop.players() of stubs_mods.lua names it
	spawn("coop_player_avatar", vec3(100, 0, 0), nil, { id = PROXY, kind = "stalker" })
	coop_npc_players = nil
	rawset(_G, "coop_npc_players", nil)
	load_script("coop_npc_players")
	A = load_adapter()
	-- axr_main: every on_game_start in file order, then the actor's first update
	if A then A.on_game_start() end
	if DYN and not opts.no_surge then DYN.on_game_start() end
	if not opts.no_first_update then SendScriptCallback("actor_on_first_update") end
	return SM
end

local next_squad = 7000
-- A companion squad of one NPC standing at x; led by player character `leader` (nil: nobody's entry, the host's own).
local function companion(x, leader, alive)
	local _, npc = spawn("stalker", vec3(x, 0, 0), nil, { kind = "stalker", alive = alive })
	next_squad = next_squad + 1
	local ids = { npc:id() }
	local squad = { id = next_squad }
	function squad:commander_id() return ids[1] end
	function squad:squad_members()
		local i = 0
		return function()
			i = i + 1
			if ids[i] then return { id = ids[i] } end
		end
	end
	axr_companions.companion_squads[squad.id] = squad
	LEADERS[npc:id()] = leader
	return npc
end

-- What the stock kill (surge_manager.script:1342) and Useful Idiots' surge action ask: pos_in_cover at the NPC's place.
local function asks(npc, by_name)
	NOW = NOW + 1 -- coop_npc_players caches its lists per frame
	local pos = npc:position()
	pos.shelter = npc._shelter -- the fake restrictor's test: which one this place is inside
	return SM:pos_in_cover(pos, by_name)
end

local function wrapped()
	for _, l in ipairs(coop_mods_core.wrapped) do if l == LABEL then return true end end
	return false
end

modes.each(coop_mode, function(set)
	print("== " .. set)
	if set == "hostplay" then
		boot(set, { no_first_update = true })
		local near = companion(105, PROXY)
		COVER[PROXY] = { c = true, age = 500 }
		check(asks(near) == false, set .. ": before the first update the mod's patch is all there is (host exposed)")
		SendScriptCallback("actor_on_first_update")
		check(A ~= nil and wrapped(), set .. ": the wrapper goes on over the mod's patch at the first update")
		check(asks(near) == true, set .. ": a client's companion 5 m from its sheltered leader is protected")

		local far = companion(130, PROXY)
		check(asks(far) == false, set .. ": 30 m from its sheltered leader (range 15): exposed")
		COVER[PROXY] = { c = true, age = 3001 }
		check(asks(near) == false, set .. ": a report 3001 ms old is stale: exposed")
		COVER[PROXY] = { c = true, age = 3000 }
		check(asks(near) == true, set .. ": a report 3000 ms old is fresh")
		COVER[PROXY] = { c = false, age = 0 }
		check(asks(near) == false, set .. ": its leader outside a shelter: exposed")
		COVER[PROXY] = nil
		check(asks(near) == false, set .. ": no cover facts of its leader: exposed")

		COVER[PROXY] = { c = false, age = 0 }
		DYN.dynamic_is_safe = true
		local by_host = companion(8, PROXY)
		check(asks(by_host) == false, set .. ": the client's companion is judged by its leader, not by the sheltered host 8 m away")
		local own = companion(10, nil)
		check(asks(own) == true, set .. ": the host's own companion near the sheltered host: the mod's own rule")
		DYN.dynamic_is_safe = false
		check(asks(own) == false, set .. ": the host's own companion, the host exposed: exposed")
		local own_far = companion(20, nil)
		DYN.dynamic_is_safe = true
		check(asks(own_far) == false, set .. ": the host's own companion 20 m from him: exposed (range 15)")

		COVER[PROXY] = { c = true, age = 0 }
		DYN.protect_companions_range = 0
		check(asks(near) == false, set .. ": range 0 (the mod's MCM switch) protects nobody")
		check(DYN.protect_companions_range == 0, set .. ": the MCM value is left as it was")
		DYN.protect_companions_range = 15
		check(asks(near) == true and DYN.protect_companions_range == 15, set .. ": range restored after every call")

		local sheltered = companion(400, PROXY)
		sheltered._shelter = "shelter"
		check(asks(sheltered) == true, set .. ": a companion inside a stock restrictor stays covered")
		check(asks(sheltered, true) == "shelter", set .. ": by_name still gets the restrictor's name")
		local dead = companion(105, PROXY, false)
		OBJ[dead:id()]._pos = vec3(106, 0, 0)
		check(asks(dead) == false, set .. ": a dead NPC is no companion the rule protects")

		DYN.dynamic_is_safe = true
		local covered, age
		if A then covered, age = A.cover_of(0) end
		check(covered == true and age == 0, set .. ": cover_of(the host's actor) = the mod's dynamic_is_safe, now")
		DYN.dynamic_is_safe = false
		if A then covered, age = A.cover_of(0) end
		check(covered == false and age == 0, set .. ": cover_of(the host's actor), exposed: false, now")
		COVER[PROXY] = { c = true, age = 1200 }
		if A then covered, age = A.cover_of(PROXY) end
		check(covered == true and age == 1200, set .. ": cover_of(a client's character) = the decider's decision and its age")
		check(A and A.cover_of(4242) == nil, set .. ": cover_of(a stranger) = nothing")
		check(A and A.cover_of("500") == nil, set .. ": cover_of(a non-number) = nothing")

		-- a broken companion record does not break the stock kill: the mod's own answer
		coop_npc_companions.leader_of = function() error("boom") end
		DYN.dynamic_is_safe = true
		local r = asks(own)
		check(r == true, set .. ": an error in the co-op rule falls back to the mod's answer")
	elseif set == "srv_map" then
		boot(set)
		DYN.dynamic_is_safe = true -- the mod scans from the ghost's place
		COVER[PROXY] = { c = true, age = 200 }
		local led = companion(105, PROXY)
		check(asks(led) == true, set .. ": a companion 5 m from its sheltered leader is protected")
		local by_ghost = companion(5, nil)
		check(asks(by_ghost) == false, set .. ": the ghost's cover protects nobody (no player within 15 m)")
		local nobodys = companion(110, nil)
		check(asks(nobodys) == true, set .. ": a companion with no leader here: the nearest player of the map, sheltered, 10 m")
		COVER[PROXY] = { c = true, age = 5000 }
		check(asks(nobodys) == false, set .. ": that player's stale report: exposed")
		check(A and A.cover_of(0) == nil, set .. ": cover_of(the ghost) = nothing")
	elseif set == "srv_world" then
		boot(set)
		DYN.dynamic_is_safe = false
		COVER[PROXY] = { c = true, age = 0 }
		local led = companion(105, PROXY)
		check(asks(led) == false, set .. ": the world server leads no map: the mod's chain as it is")
		DYN.dynamic_is_safe = true
		local near = companion(5, nil)
		check(asks(near) == true, set .. ": the mod's own rule runs untouched there")
	else -- none: single player, the stock game with the mod
		boot(set)
		COVER[PROXY] = { c = true, age = 0 }
		local led = companion(105, PROXY)
		check(asks(led) == false, set .. ": single player: the mod judges by the actor, as in the stock")
		DYN.dynamic_is_safe = true
		local near = companion(10, nil)
		check(asks(near) == true, set .. ": single player: near the sheltered actor, protected")
		local far = companion(20, nil)
		check(asks(far) == false, set .. ": single player: 20 m from the actor, exposed")
		DYN.protect_companions_range = 25
		check(asks(far) == true, set .. ": single player: the MCM range is the mod's")
	end
end)

-- Absent pieces: the adapter stays out and never throws (axr_main runs on_game_start unprotected).
do
	modes.install(coop_mode, "hostplay")
	local before = #coop_mods_core.wrapped
	local ok, err = pcall(boot, "hostplay", { no_mod = true })
	check(ok and #coop_mods_core.wrapped == before, "no Dynamic Emission Cover: nothing wrapped, nothing thrown"
		.. (ok and "" or (": " .. tostring(err))))
	ok, err = pcall(boot, "hostplay", { no_surge = true })
	check(ok and #coop_mods_core.wrapped == before, "no surge_manager: nothing wrapped, nothing thrown"
		.. (ok and "" or (": " .. tostring(err))))
end

done("mods_emission_cover")
