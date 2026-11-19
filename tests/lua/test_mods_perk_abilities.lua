-- Dev 57 G7-2: PBA active abilities as verified commands (review m08:4 ability state, m08:6 Tapeworm stun, m08:7 the death
-- lamp's reaction). The real merged PBA functions (temp\review\corpus\merged\perk_based_artefacts.script, identical to the
-- stand's copy), loaded by slices at their own line numbers; every S4 answer set. No game, no network, no live-game reads.
-- One Lua state plays both machines: the player's (a co-op client / a server player: MODE "client", peer 1, his character
-- is local id 0 = host id 500) and the decider (co-op host / the map server of his level: MODE "host").
local modes = dofile("tests/lua/support/modes.lua")

local function source(name)
	local f = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "rb"))
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end
local SRC = source("perk_based_artefacts")

local function between(first, last, after)
	local a = assert(SRC:find(first, after or 1, true), first)
	local b = assert(SRC:find(last, a + #first, true), last)
	return SRC:sub(a, b - 1), a
end

local function lines_before(pos)
	local _, n = SRC:sub(1, pos - 1):gsub("\n", "")
	return n
end

-- The file locals of perk_based_artefacts.script the slices use (one line: the slice keeps its own line numbers).
local LOCALS = table.concat({
	"local trace = function() end",
	"local time_elapsed = 0",
	"local actor_is_dying = false",
	"local table_insert, dump, unpack, string_find = table.insert, string.dump, unpack, string.find",
	"local min, max, floor = math.min, math.max, math.floor",
	"local random = TEST_RANDOM",
	"local random_float = function(a) return a end",
	"local get_random_array_element = function(t) return t[1] end",
	"local get_safe_sound_object = function(n) return sound_object(n) end",
	"local CreateTimeEvent, RemoveTimeEvent = CreateTimeEvent, RemoveTimeEvent",
	"local get_object_by_id = function(id) if id == AC_ID then return db.actor end return level.object_by_id(id) end",
	"local get_monster_clsid_and_kind = function(o) return o:clsid(), 'dog' end",
	"local add_speed, remove_speed = function() end, function() end",
	"local play_sound_on_actor = function() return TEST_SND end",
	"local refresh_artefacts_time_event_func = function() return true end",
	"local iterate_nearest = level.iterate_nearest",
	"local disable_input, add_cam_effector, add_pp_effector, remove_pp_effector = function() end, function() end, function() end, function() end",
	"local c_id_ppe = { black_infinite = 1, actor_death = 2, rcom_actor_death_quick = 3, blur = 4, snd_shock = 5 }",
	"local play_snd = function() end",
	"local get_console = function() return { get_bool = function() return true end, get_float = function() return 1 end, execute = function() end } end",
	"local normalize, is_empty = normalize, is_empty",
}, "; ") .. "; "

local function load_slice(pba, text, pos, suffix)
	local chunk = assert(loadstring(LOCALS .. string.rep("\n", lines_before(pos)) .. text .. (suffix or ""),
		"@perk_based_artefacts.script"))
	setfenv(chunk, pba)
	return chunk()
end

local MIRROR = { actor_is_player = function() return true end, is_player_mirror = function() return true end,
	leads_here = function() return false end, decides_world = function() return false end }

for _, set in ipairs(modes.names()) do
	print("== G7-2 " .. set)
	MODE = set == "none" and "sp" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	for _, name in ipairs({ "on_enemy_eval", "actor_on_weapon_fired", "actor_on_before_hit", "monster_on_before_hit",
		"npc_on_before_hit" }) do AddScriptCallback(name) end
	hit = setmetatable({ fire_wound = 8, wound = 9, strike = 3, explosion = 5, telepatic = 4, shock = 1 }, { __call = function(_, original)
		local copy = {}
		for k, v in pairs(original or {}) do copy[k] = v end
		return copy
	end })
	VEC_Z, VEC_Y = vec3(0, 0, 1), vec3(0, 1, 0)
	move, anim = { stand = 1, standing = 2 }, { panic = 3 }
	clsid = { zombie_s = 11, dog_s = 12 }
	function normalize(v, lo, hi) return (v - lo) / (hi - lo) end
	function SYS_GetParam(_, _, _, def) return def end
	function IsAnomaly() return false end
	bind_stalker_ext = {}
	ui_inventory = { GUI = { UpdateWeight = function() end } }
	TEST_SND = sound_object("lamp")
	TEST_RANDOM = function(a, b) if b then return a end return 10 end -- the death lamp's 50% roll comes out "die"

	-- GAMMA's alife_create_item (ItemProcessor): a location tuple is a world spawn, which the engine refuses on a client
	-- (alife_simulator_script.cpp:264-269 returns nil).
	local create_item = alife_create_item
	function alife_create_item(sec, owner, t)
		if type(owner) == "table" and owner[1] ~= nil then
			if MODE == "client" then return nil end
			return alife_create(sec, owner[1], owner[2], owner[3])
		end
		return create_item(sec, owner, t)
	end

	-- objects: id 0 = this process's own actor (the client's on the player's machine, the host's on the co-op host),
	-- 500 = the client's character on the decider
	local actor = make_actor(vec3(0, 0, 0))
	local _, remote = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local _, npc = spawn("stalker", vec3(3, 0, 0), nil, { kind = "stalker" })
	local _, dog = spawn("dog", vec3(1, 0, 1), nil, { kind = "monster" })
	local _, far = spawn("stalker", vec3(100, 0, 0), nil, { kind = "stalker" })
	local _, corpse = spawn("stalker", vec3(2, 0, 0), nil, { kind = "stalker", alive = false })
	local GO = getmetatable(npc)
	local function rec(name) return function(self) self._log = self._log or {}; self._log[#self._log + 1] = name end end
	GO.set_movement_type, GO.set_body_state, GO.set_mental_state, GO.play_cycle = rec("move"), rec("body"), rec("mental"), rec("anim")
	GO.hit = function(self, h) self._hits = (self._hits or 0) + 1 end
	GO.clsid = function() return 12 end
	GO.name = function(self) return self._sec end
	local function calls(o, name)
		local n = 0
		for _, c in ipairs(o._log or {}) do if c == name then n = n + 1 end end
		return n
	end
	-- the client's artefacts are in his character on the decider (500); his machine sees them on its belt
	local function item(sec, parent) local _, o = spawn(sec, vec3(0, 0, 0), parent) return o end
	local tapeworm, phantom, moss = item("af_tapeworm", PROXY), item("af_star_phantom", PROXY), item("af_moh", PROXY)
	local seraphim, lucifer = item("af_serofim", PROXY), item("af_lucifer", PROXY)
	local host_tapeworm, host_lucifer = item("af_tapeworm", 0), item("af_lucifer", 0)
	local BELT = { tapeworm, phantom, moss, seraphim }
	local CARRIED = { lucifer }
	local self_hits = 0
	actor.hit = function() self_hits = self_hits + 1 end
	actor.iterate_belt = function(self, f) for _, o in ipairs(BELT) do f(self, o) end end
	actor.object = function(_, sec)
		for _, o in ipairs(CARRIED) do if o:section() == sec then return o end end
	end
	local weapon_hidden = 0
	actor.hide_weapon = function() weapon_hidden = weapon_hidden + 1 end
	actor.restore_weapon = function() weapon_hidden = weapon_hidden - 1 end
	actor.is_talking = function() return false end
	actor.active_item = function() return nil end
	actor.set_health_ex = function() end
	actor.change_satiety = function() end
	actor.cast_Actor = function() return { conditions = function() return { GetSatiety = function() return 0.5 end } end } end

	-- the module perk_based_artefacts out of real slices
	local pba = setmetatable({}, { __index = _G })
	perk_based_artefacts = pba
	pba.set_psy_health, pba.change_psy_health = function() end, function() end
	pba.get_artefact_from_container = function(sec) return sec end
	local mach, mach_at = between("-- Callbacks\ncallbacks = {}", "speed_boosts = {")
	load_slice(pba, mach, mach_at, "\nfunction TEST_TIME(t) time_elapsed = t end\nfunction TEST_PROCESS() process_timed_effects() end")
	pba.artefact_props = {}
	for _, s in ipairs({ { "\taf_tapeworm = {", "\taf_sun = {" }, { "\taf_serofim = {", "\taf_dragon_eye = {" },
		{ "\taf_moh = { -- Mutant parts bonuses", "\taf_chelust = {" } }) do
		local text, at = between(s[1], s[2])
		for k, v in pairs(load_slice(pba, "return {" .. text .. "}", at)) do pba.artefact_props[k] = v end
	end
	local sac, sac_at = between("\t\tsacrifice_artefact = function(self, obj, id)", "\n\t}\n}\n\n-- Alias for Lucifer Check")
	pba.artefact_props.af_lucifer = { condition = 1, ignore_tiers = {}, add_overcharge = function() end,
		sacrifice_tiers = { af_death_lamp = { sound = { "lamp" }, min = 1, max = 2 } },
		change_condition = function(_, n) return n end,
		sacrifice_artefact = load_slice(pba, "return {" .. sac .. "}", sac_at).sacrifice_artefact }
	local function entry(tbl, header, last)
		local text, at = between(header, last, assert(SRC:find(tbl, 1, true)))
		return load_slice(pba, "return {" .. text .. "}", at)
	end
	pba.artefact_on_hit_functions = entry("artefact_on_hit_functions = {", "\taf_tapeworm = function(", "\t-- Sandstone, perk: Zone Infusion")
	pba.artefact_on_update_functions = entry("artefact_on_update_functions = {", "\taf_tapeworm = function(", "\t-- Heart, Perk: Will to Live")
	pba.artefact_on_before_death_functions = entry("artefact_on_before_death_functions = {", "\taf_serofim = function(", "\n}\n")
	pba.artefact_on_equip_functions = entry("artefact_on_equip_functions = {", "\taf_star_phantom = function(", "\t-- Generator, Perk")
	pba.artefact_on_item_use_functions = entry("artefact_on_item_use_functions = {", "\taf_moh = function(", "\n}\n")

	load_script("coop_main")
	for _, n in ipairs(MODE_FILES) do load_script(n) end
	load_script("coop_mods_core")
	coop_main.on_game_start()
	coop_mods_core.on_game_start()
	local path = io.open("gamedata/scripts/coop_mods_perk_abilities.script", "r")
	local ab = nil
	if path then
		path:close()
		ab = load_script("coop_mods_perk_abilities")
		ab.on_game_start()
	end
	coop_trust.reset_for_test({ default = "log" })

	local function as_owner()
		MODE, SELF = "client", 1
		modes.install(coop_mode, set, MIRROR)
	end
	local function as_decider(overrides)
		MODE, SELF = "host", 0
		modes.install(coop_mode, set == "hostplay" and "hostplay" or "srv_map", overrides)
	end
	local function as_world(overrides)
		MODE, SELF = "host", 0
		modes.install(coop_mode, "srv_world", overrides)
	end
	-- A player's request reaches the process that leads his map: the co-op host; in the server mode the world server
	-- passes it to the map server of his level, with his peer in it.
	local function deliver(raw, peer)
		peer = peer or 1
		if set == "srv_world" then
			as_world()
			local before = #SENT
			coop_main.on_event(raw.name, raw.payload, peer)
			local passed = SENT[#SENT]
			check(#SENT == before + 1 and passed.name == raw.name and passed.target == 0x101,
				"server: the world server passes the request to the map server of his level")
			as_decider()
			coop_main.on_event(passed.name, passed.payload, 0)
		elseif set == "srv_map" then
			as_decider()
			local t = coop_main.decode(raw.payload)
			t._peer = peer
			coop_main.on_event(raw.name, coop_main.encode(t), 0)
		else
			as_decider()
			coop_main.on_event(raw.name, raw.payload, peer)
		end
	end
	local function forged(t) return { name = "mods.pba_cmd", payload = coop_main.encode(t) } end
	-- what the player's machine sent to the decider of his level (peer 0); a world server's pass goes to a bridge
	local function last_cmd()
		for i = #SENT, 1, -1 do
			local e = SENT[i]
			if e.name == "mods.pba_cmd" and e.target == 0 then return coop_main.decode(e.payload), e end
		end
	end
	local function sent_count(name)
		local n = 0
		for _, e in ipairs(SENT) do if e.name == name and e.target == 0 then n = n + 1 end end
		return n
	end
	local function ignored(by, whom)
		local flags = { override = false, result = true }
		SendScriptCallback("on_enemy_eval", by, whom, flags)
		return flags.override == true and flags.result == false
	end
	local function tick(ms)
		NOW = NOW + (ms or 600)
		SendScriptCallback("actor_on_update")
	end
	local q = 1000 -- operation ids of forged requests
	local function next_q() q = q + 1 return q end
	-- The client's own operation counter is below the forged ids: the decider forgets him (he left), as a reconnect does.
	local function forget()
		as_decider()
		local roster = coop.players
		coop.players = function() return { { id = 0, nick = "hoster", is_self = true, avatar_id = 0 } } end
		tick(1100)
		coop.players = roster
	end
	local function blows()
		local n = 0
		for _, c in ipairs(CREATED) do if c.sec == "ied_new_blow" then n = n + 1 end end
		return n
	end

	if set ~= "none" then
		---------------------------------------------------------------------------------------------------------------
		-- m08:4  ability state (Phantom Star, Moss food, Seraphim's revival) on the decider
		---------------------------------------------------------------------------------------------------------------
		as_owner()
		local before = sent_count("mods.pba_cmd")
		pba.artefact_on_equip_functions.af_star_phantom(actor, 1, { phantom:id() }, { "af_star_phantom" })
		tick()
		local t, raw = last_cmd()
		check(sent_count("mods.pba_cmd") == before + 1 and t and t.k == "phantom" and t.d == 10 and t.i1 == phantom:id(),
			"m08:4: Phantom Star on the client's belt is told to the decider (10 s lease, the artefact named)")
		as_decider()
		check(not ignored(npc, remote), "m08:4: without the request the decider's NPC sees the client")
		if raw then deliver(raw) end
		check(ignored(npc, remote), "m08:4: the decider's NPC ignores the client with Phantom Star (his id, not AC_ID)")
		check(not ignored(npc, far), "m08:4: the state belongs to his character only")
		as_owner()
		tick(4100)
		local renewed, raw2 = last_cmd()
		check(sent_count("mods.pba_cmd") == before + 2 and renewed and renewed.k == "phantom",
			"m08:4: the client renews the lease while the star stays on his belt")
		as_decider()
		NOW = NOW + 10100
		check(not ignored(npc, remote), "m08:4: a lease that is not renewed ends on the decider by itself")
		if raw2 then deliver(raw2) end
		check(ignored(npc, remote), "m08:4: a renewal brings the state back")
		as_owner()
		pba.unregister_on_equip_callbacks()
		tick()
		local off, raw3 = last_cmd()
		check(off and off.k == "phantom" and off.o == true, "m08:4: taking the star off is told to the decider")
		if raw3 then deliver(raw3) end
		check(not ignored(npc, remote), "m08:4: the state is cleared on the decider when the ability ends")

		-- Moss: food with Moss on the belt makes him invisible up to 60 s, his attack ends it
		as_owner()
		pba.artefact_on_item_use_functions.af_moh(actor, 1, { moss:id() }, { "af_moh" }, item("mutant_part_krovosos_meat", 0))
		tick()
		local m, rawm = last_cmd()
		check(m and m.k == "moss" and m.d and m.d > 59 and m.d <= 60 and m.i1 == moss:id(),
			"m08:4: Moss invisibility is told to the decider with its remaining time")
		if rawm then deliver(rawm) end
		check(ignored(npc, remote), "m08:4: the decider's NPC ignores the invisible client")
		SendScriptCallback("npc_on_before_hit", npc, { draftsman = remote, type = hit.fire_wound, power = 1 }, 0, {})
		check(not ignored(npc, remote), "m08:4: the client's attack on a creature ends the invisibility on the decider")
		as_owner()
		SendScriptCallback("actor_on_weapon_fired", actor)
		tick()
		local moff = last_cmd()
		check(moff and moff.k == "moss" and moff.o == true, "m08:4: the mod's own end of the invisibility is told too")
		pba.artefact_props.af_moh:reset()

		-- forged: a duration over the bound is cut; without the artefact (refuse mode) nothing; malformed numbers
		local lookups, lookup = 0, level.object_by_id
		deliver(forged({ k = "moss", q = next_q(), d = 1e9, n = 1, i1 = moss:id() }))
		check(ignored(npc, remote), "m08:4: a forged long duration is accepted only up to its bound")
		NOW = NOW + 60100
		check(not ignored(npc, remote), "m08:4: ... and ends at 60 s")
		coop_trust.reset_for_test({ default = "refuse" })
		deliver(forged({ k = "phantom", q = next_q(), d = 10, n = 1 }))
		check(not ignored(npc, remote), "m08:4: refuse mode: a state without the artefact he carries is refused")
		deliver(forged({ k = "phantom", q = next_q(), d = 10, n = 1, i1 = host_tapeworm:id() }))
		check(not ignored(npc, remote), "m08:4: refuse mode: another player's (or the wrong) artefact does not count")
		coop_trust.reset_for_test({ default = "log" })
		deliver(forged({ k = "phantom", q = next_q(), d = 10, n = 1 }))
		local c = coop_trust.status().pba_phantom_item
		check(c and c.failed >= 1 and ignored(npc, remote), "m08:4: log mode: counted and logged, let through (build 57)")
		check(log_has("[coop-trust] ! pba_phantom_item") ~= nil, "m08:4: the trust line names the check")
		level.object_by_id = function(id) lookups = lookups + 1 return lookup(id) end
		deliver(forged({ k = "phantom", q = 0 / 0, d = 10 }))
		deliver(forged({ k = "phantom", q = next_q(), d = -1, i1 = 70000 }))
		level.object_by_id = lookup
		check(lookups == 0, "m08:4: malformed numbers are dropped before any object lookup")

		-- exit: the player leaves the session (his peer is gone) or his level
		local roster = coop.players
		coop.players = function() return { { id = 0, nick = "hoster", is_self = true, avatar_id = 0 } } end
		tick(1100)
		coop.players = roster
		check(not ignored(npc, remote), "m08:4: a player who left the session loses his state on the decider")
		deliver(forged({ k = "phantom", q = next_q(), d = 10, n = 1, i1 = phantom:id() }))
		check(ignored(npc, remote), "m08:4: (a state again)")
		MODE = "sp"
		tick(1100)
		as_decider()
		check(not ignored(npc, remote), "m08:4: the end of the session clears every state")
		if set ~= "hostplay" then
			deliver(forged({ k = "phantom", q = next_q(), d = 10, n = 1, i1 = phantom:id() }))
			check(ignored(npc, remote), "server: the map server of his level keeps his state")
			as_decider({ where = function(p) return p == 1 and "away" or "here" end })
			tick(1100)
			as_decider()
			check(not ignored(npc, remote), "server: when he goes to another map, the map server he left drops his state")
			-- two maps: each player's request goes to the map server of his own level
			local bridges = { [1] = 0x101, [2] = 0x102 }
			as_world({ level_request = function(_, payload, from)
				local tt = coop_main.decode(payload)
				tt._peer = from
				return "pass", bridges[from], coop_main.encode(tt)
			end })
			for peer = 1, 2 do
				local r = forged({ k = "phantom", q = next_q(), d = 10, n = 1 })
				coop_main.on_event(r.name, r.payload, peer)
				local passed = SENT[#SENT]
				check(passed.target == bridges[peer] and coop_main.decode(passed.payload)._peer == peer,
					"server, two maps: the request of player " .. peer .. " goes to his own map server")
			end
			check(not ignored(npc, remote), "server: the world server, which has no map, applies nothing")
		end

		-- Seraphim: the 2 s of "down" go to the decider BEFORE the mod spends the artefact
		forget()
		as_owner()
		local alive_at_send = nil
		local send = coop.send_event
		coop.send_event = function(name, payload, target)
			if name == "mods.pba_cmd" and coop_main.decode(payload).k == "down" then alive_at_send = SE[seraphim:id()] ~= nil end
			return send(name, payload, target)
		end
		pba.artefact_on_before_death_functions.af_serofim(actor, 1, { seraphim:id() }, { "af_serofim" }, 1000, {})
		coop.send_event = send
		local dn, rawd = last_cmd()
		check(dn and dn.k == "down" and dn.d == 2 and alive_at_send == true,
			"m08:4: Seraphim's revival is told before the artefact is released")
		if rawd then
			-- one Lua state plays both machines: the release already happened here; on the decider the request, sent
			-- first, arrives before it
			spawn("af_serofim", vec3(0, 0, 0), PROXY, { id = seraphim:id() })
			deliver(rawd)
		end
		check(ignored(npc, remote), "m08:4: the decider's NPCs ignore the downed client")
		NOW = NOW + 2100
		check(not ignored(npc, remote), "m08:4: ... for 2 s only")
		pba.artefact_on_before_death_functions.af_serofim(actor, 1, { seraphim:id() }, { "af_serofim" }, 1000, {})
		check(dn and last_cmd().q == dn.q, "m08:4: a second call while still dying sends nothing")
		run_time_events(2500) -- the mod's own 2 s callback on this (shared) state ends

		if set == "hostplay" then
			-- the host's own player: the same decider function, called directly (no event)
			as_decider()
			local host_phantom = item("af_star_phantom", 0)
			BELT = { host_phantom }
			pba.artefact_on_equip_functions.af_star_phantom(actor, 1, { host_phantom:id() }, { "af_star_phantom" })
			local n = sent_count("mods.pba_cmd")
			local checked = (coop_trust.status().pba_phantom_item or { checked = 0 }).checked
			tick()
			local now_checked = (coop_trust.status().pba_phantom_item or { checked = 0 }).checked
			check(sent_count("mods.pba_cmd") == n and now_checked == checked + 1 and ignored(npc, actor),
				"co-op: the host's own Phantom Star goes through the decider function directly")
			pba.unregister_on_equip_callbacks()
			tick()
			check(not ignored(npc, actor), "co-op: ... and ends there")
			BELT = { tapeworm, phantom, moss, seraphim }
		end

		---------------------------------------------------------------------------------------------------------------
		-- m08:6  Tapeworm stun: target and duration on the decider
		---------------------------------------------------------------------------------------------------------------
		forget()
		as_owner()
		pba.remove_cooldown("af_tapeworm")
		npc._log, npc._hits = nil, nil
		pba.artefact_on_hit_functions.af_tapeworm(actor, 1, { tapeworm:id() }, { "af_tapeworm" }, actor, 0.3, npc,
			{ type = hit.wound, power = 0.3 })
		run_time_events(0)
		local s, raws = last_cmd()
		check(s and s.k == "stun" and s.t == npc:id() and s.i1 == tapeworm:id() and s.n == 1,
			"m08:6: the client's stun is a request with its target and artefact")
		check(npc._log == nil and npc._hits == nil and not ignored(npc, remote),
			"m08:6: nothing is applied to the client's copy of the NPC (no state, animation, hit or enemy choice)")
		check(not pba.check_cooldown("af_tapeworm"), "m08:6: the client keeps his own cooldown")
		pba.remove_cooldown("af_tapeworm") -- from here: the decider's own (the host player's) cooldown
		if raws then deliver(raws) end
		run_time_events(0)
		check(calls(npc, "move") == 1 and calls(npc, "mental") == 1 and npc._hits == 1,
			"m08:6: the decider stuns the NPC (state and hit where the AI is)")
		check(ignored(npc, remote) and ignored(npc, actor), "m08:6: the stunned NPC chooses no enemy on the decider")
		check(pba.check_cooldown("af_tapeworm"), "m08:6: a client's stun does not move the host player's cooldown")

		-- the next request at once (a monster near him): the always-on floor drops it
		as_owner()
		pba.remove_cooldown("af_tapeworm")
		pba.artefact_props.af_tapeworm:iterate_func(actor, 1, { tapeworm:id() }, { "af_tapeworm" }, dog)
		local sd, rawdog = last_cmd()
		check(sd and sd.k == "stun" and sd.t == dog:id(), "m08:6: the stun of a nearby monster is a request too")
		check(dog._hits == nil, "m08:6: ... and not applied on the client's copy")
		if rawdog then deliver(rawdog) end
		check(dog._hits == nil, "m08:6: a second stun within 3 s is dropped (always on)")

		run_time_events(3200)
		check(calls(npc, "anim") > 1, "m08:6: the stun animation plays on the decider")
		local after = npc._hits
		run_time_events(1000)
		check(not ignored(npc, remote) and npc._hits == after, "m08:6: the stun ends after 1 + 2 * count seconds")
		if raws then deliver(raws) end
		run_time_events(0)
		check(npc._hits == after, "m08:6: the same request again is not applied twice")
		NOW = NOW + 6000
		deliver(forged({ k = "stun", q = next_q(), t = dog:id(), n = 1, i1 = tapeworm:id() }))
		check(dog._hits == 1, "m08:6: after the cooldown the monster is stunned once")

		-- forged targets and counts
		local function stun_of(target, extra)
			NOW = NOW + 7000
			local t = { k = "stun", q = next_q(), t = target, n = 1, i1 = tapeworm:id() }
			for k, v in pairs(extra or {}) do t[k] = v end
			deliver(forged(t))
			run_time_events(0)
		end
		remote._log = nil
		stun_of(PROXY)
		stun_of(0)
		check(remote._log == nil and calls(actor, "move") == 0, "m08:6: a player is never stunned (always on)")
		far._log = nil
		coop_trust.reset_for_test({ default = "refuse" })
		stun_of(far:id())
		check(far._log == nil, "m08:6: refuse mode: a target out of range is refused")
		local cnt = npc._hits
		stun_of(npc:id(), { i1 = host_tapeworm:id() })
		check(npc._hits == cnt, "m08:6: refuse mode: a stun without his own Tapeworm is refused")
		corpse._log = nil
		stun_of(corpse:id())
		check(corpse._log == nil and corpse._force == nil, "m08:6: refuse mode: a dead target is refused")
		coop_trust.reset_for_test({ default = "log" })
		stun_of(npc:id(), { i1 = host_tapeworm:id() })
		check(npc._hits == cnt + 1 and coop_trust.status().pba_stun_item and coop_trust.status().pba_stun_item.failed >= 1,
			"m08:6: log mode: an artefact he does not carry is counted, the stun let through")
		stun_of(far:id())
		check(far._log ~= nil and coop_trust.status().pba_stun_range and coop_trust.status().pba_stun_range.failed >= 1,
			"m08:6: log mode: out of range counted, let through")
		run_time_events(12000)
		local eval = "af_tapeworm" .. npc:id() .. ":af_tapeworm" .. npc:id() .. "eval"
		NOW = NOW + 7000
		local at0 = NOW
		deliver(forged({ k = "stun", q = next_q(), t = npc:id(), n = 99, i1 = tapeworm:id(), i2 = 1, i3 = 2, i4 = 3, i5 = 4 }))
		local ev = TIMEEV[eval]
		check(ev and math.abs(ev.at - at0 - 3100) < 1, "m08:6: a forged count does not lengthen the stun (his verified artefacts decide)")
		run_time_events(12000)
		NOW = NOW + 7000
		at0 = NOW
		deliver(forged({ k = "stun", q = next_q(), t = npc:id(), n = 99 }))
		ev = TIMEEV[eval]
		check(ev and math.abs(ev.at - at0 - 11100) < 1, "m08:6: log mode, no artefact verified: the count is cut to 5")
		run_time_events(12000)
		lookups = 0
		level.object_by_id = function(id) lookups = lookups + 1 return lookup(id) end
		deliver(forged({ k = "stun", q = next_q(), t = 65536, i1 = tapeworm:id() }))
		deliver(forged({ k = "stun", q = next_q(), t = 0 / 0 }))
		deliver(forged({ k = "nuke", q = next_q(), t = npc:id() }))
		level.object_by_id = lookup
		check(lookups == 0, "m08:6: malformed ids and unknown kinds are dropped before any lookup")

		if set == "hostplay" then
			as_decider()
			pba.remove_cooldown("af_tapeworm")
			NOW = NOW + 7000
			npc._log = nil
			local n = sent_count("mods.pba_cmd")
			pba.artefact_on_hit_functions.af_tapeworm(actor, 1, { host_tapeworm:id() }, { "af_tapeworm" }, actor, 0.3, npc,
				{ type = hit.wound, power = 0.3 })
			run_time_events(0)
			check(sent_count("mods.pba_cmd") == n and calls(npc, "move") == 1 and not pba.check_cooldown("af_tapeworm"),
				"co-op: the host's own stun goes through the decider function directly and keeps his cooldown")
			run_time_events(12000)
		end

		---------------------------------------------------------------------------------------------------------------
		-- m08:7  the death lamp's reaction: one explosion on the decider, the personal effect finished once
		---------------------------------------------------------------------------------------------------------------
		forget()
		as_owner()
		pba.TEST_TIME(100)
		self_hits = 0
		local lamp = item("af_death_lamp", 0)
		pba.artefact_props.af_lucifer:sacrifice_artefact(lamp)
		check(pba.timed_effects.af_death_lamp_die ~= nil, "m08:7: the sacrifice armed the mod's death effect")
		pba.TEST_TIME(102)
		local n = sent_count("mods.pba_cmd")
		local ok, err = pcall(pba.TEST_PROCESS)
		check(ok, "m08:7: the client's death effect does not throw (" .. tostring(err) .. ")")
		check(pba.timed_effects.af_death_lamp_die == nil, "m08:7: the effect is finished and removed")
		local b, rawb = last_cmd()
		check(sent_count("mods.pba_cmd") == n + 1 and b and b.k == "blow" and b.i1 == lucifer:id() and b.t == nil,
			"m08:7: one reaction request (Lucifer named, no position from the client)")
		check(self_hits == 1, "m08:7: the self hit stays the player's own, once")
		check(blows() == 0, "m08:7: no world object is created on the client")
		local stray = 0
		for k in pairs(TIMEEV) do if k:find("^table:") or k:find("^nil:") then stray = stray + 1 end end
		check(stray == 0, "m08:7: no explode timer waits for an object that does not exist")
		pba.TEST_TIME(110)
		pcall(pba.TEST_PROCESS)
		check(sent_count("mods.pba_cmd") == n + 1 and self_hits == 1, "m08:7: nothing runs a second time")
		remote._pos = vec3(7, 0, 7)
		if rawb then deliver(rawb) end
		local made = nil
		for _, c in ipairs(CREATED) do if c.sec == "ied_new_blow" then made = OBJ[c.id] or made end end
		check(made ~= nil and made:position().x == 7 and made:position().z == 7,
			"m08:7: the decider creates the charge at the client's character")
		run_time_events(200)
		check(made and made._exploded == true, "m08:7: ... and explodes it")
		if rawb then deliver(rawb) end
		check(blows() == 1, "m08:7: the same request again makes no second explosion")
		deliver(forged({ k = "blow", q = next_q(), i1 = lucifer:id() }))
		check(blows() == 1, "m08:7: a new request within 5 s makes no second explosion (always on)")
		coop_trust.reset_for_test({ default = "refuse" })
		NOW = NOW + 11000
		deliver(forged({ k = "blow", q = next_q() }))
		check(blows() == 1, "m08:7: refuse mode: a reaction without Lucifer is refused")
		coop_trust.reset_for_test({ default = "log" })
		deliver(forged({ k = "blow", q = next_q() }))
		check(blows() == 2 and coop_trust.status().pba_blow_item and coop_trust.status().pba_blow_item.failed >= 1,
			"m08:7: log mode: counted, let through (at his own character, once)")
		run_time_events(200)
		coop_trust.reset_for_test({ default = "log" })
		remote._pos = vec3(0, 0, 0)

		-- an effect a load brought back (the mod rebuilds it from its saved string) is finished the same way
		as_owner()
		pba.timed_effects.af_death_lamp_die = { timer = 0, on_end = function()
			db.actor:hit({})
			local o = _G.alife_create_item("ied_new_blow", { db.actor:position(), 1, 2, nil })
			_G.CreateTimeEvent(o.id, o.id, 0, function() return true end)
		end }
		tick()
		n = sent_count("mods.pba_cmd")
		ok = pcall(pba.TEST_PROCESS)
		check(ok and sent_count("mods.pba_cmd") == n + 1 and pba.timed_effects.af_death_lamp_die == nil,
			"m08:7: an effect restored by a load is finished once as well")

		if set == "hostplay" then
			as_decider()
			CARRIED = { host_lucifer }
			NOW = NOW + 11000
			self_hits = 0
			pba.TEST_TIME(200)
			pba.artefact_props.af_lucifer:sacrifice_artefact(item("af_death_lamp", 0))
			pba.TEST_TIME(203)
			local before_blows = blows()
			local m0 = sent_count("mods.pba_cmd")
			ok = pcall(pba.TEST_PROCESS)
			check(ok and self_hits == 1 and blows() == before_blows + 1 and sent_count("mods.pba_cmd") == m0,
				"co-op: the host's own reaction makes exactly one explosion, through the decider directly")
			run_time_events(200)
			CARRIED = { lucifer }
		end
		check(ab ~= nil, "the adapter coop_mods_perk_abilities is loaded")
	else
		---------------------------------------------------------------------------------------------------------------
		-- single player: every ability is the stock one
		---------------------------------------------------------------------------------------------------------------
		modes.install(coop_mode, "none")
		pba.artefact_on_equip_functions.af_star_phantom(actor, 1, { phantom:id() }, { "af_star_phantom" })
		tick()
		check(sent_count("mods.pba_cmd") == 0 and weapon_hidden == 1, "single player: Phantom Star unchanged, nothing sent")
		pba.unregister_on_equip_callbacks()
		npc._log = nil
		pba.artefact_on_hit_functions.af_tapeworm(actor, 1, { tapeworm:id() }, { "af_tapeworm" }, actor, 0.3, npc,
			{ type = hit.wound, power = 0.3 })
		run_time_events(0)
		check(sent_count("mods.pba_cmd") == 0 and calls(npc, "move") == 1 and ignored(npc, actor), "single player: the stock stun")
		run_time_events(4000)
		pba.TEST_TIME(100)
		pba.artefact_props.af_lucifer:sacrifice_artefact(item("af_death_lamp", 0))
		pba.TEST_TIME(102)
		local ok = pcall(pba.TEST_PROCESS)
		local made = nil
		for _, c in ipairs(CREATED) do if c.sec == "ied_new_blow" then made = OBJ[c.id] end end
		run_time_events(200)
		check(ok and self_hits == 1 and made and made._exploded == true and sent_count("mods.pba_cmd") == 0,
			"single player: the death lamp's own explosion, as stock")
		pba.artefact_on_before_death_functions.af_serofim(actor, 1, { seraphim:id() }, { "af_serofim" }, 1000, {})
		check(sent_count("mods.pba_cmd") == 0, "single player: Seraphim unchanged, nothing sent")
	end

	if ab then
		-- startup never throws and registers once; an absent PBA installs nothing
		local count = axr_main.count("on_enemy_eval")
		ab.on_game_start()
		check(axr_main.count("on_enemy_eval") == count, "repeated startup registers nothing twice")
		perk_based_artefacts = nil
		local fresh = load_script("coop_mods_perk_abilities")
		check(pcall(fresh.on_game_start), "without PBA the startup does not throw")
	end
	done("mods perk abilities " .. set)
end
