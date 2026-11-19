-- Dev 57 G7-3: PBA bleeding, heal and weaken on the decider (review m08:5 Thistle / Chain / Ball, m24:2 Momopate's Thistle).
-- The real merged PBA functions (temp\review\corpus\merged\perk_based_artefacts.script, identical to the stand's copy), loaded
-- by slices at their own line numbers, and the real merged momopate_pba_tweaks.script (G.A.M.M.A. Actor Damage Balancer) as a
-- module; every S4 answer set. No game, no network, no live-game reads. One Lua state plays both machines: the player's (a
-- co-op client / a server player: MODE "client", peer 1, his character is local id 0 = host id 500) and the decider (co-op
-- host / the map server of his level: MODE "host"). The engine's gate is stubbed: on a client, health changes and kills of
-- another's creature are refused (coop_calls.h:308,738: class Owner), and a hit waits for the frame's end, where the client's
-- before-hit chain may cancel it (coop_requests.cpp client_hit_perks).
local modes = dofile("tests/lua/support/modes.lua")

local function source(name)
	local f = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "rb"))
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end
local SRC = source("perk_based_artefacts")
local MOMO = source("momopate_pba_tweaks")

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
	"local table_insert, dump, unpack, string_find = table.insert, string.dump, unpack, string.find",
	"local min, max, floor = math.min, math.max, math.floor",
	"local random = TEST_RANDOM",
	"local random_float = function(a) return a end",
	"local get_random_array_element = function(t) return t[1] end",
	"local get_safe_sound_object = function(n) return sound_object(n) end",
	"local CreateTimeEvent, RemoveTimeEvent = CreateTimeEvent, RemoveTimeEvent",
	"local get_object_by_id = function(id) if id == AC_ID then return db.actor end return level.object_by_id(id) end",
	"local play_sound_on_actor = function() end",
	"local particles_object = particles_object",
	"local manage_psy_health = function() end",
	"local refresh_health_bar = function() end",
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

local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-9 end

for _, set in ipairs(modes.names()) do
	print("== G7-3 " .. set)
	MODE = set == "none" and "sp" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	for _, name in ipairs({ "on_enemy_eval", "actor_on_weapon_fired", "actor_on_before_hit", "monster_on_before_hit",
		"npc_on_before_hit" }) do AddScriptCallback(name) end
	hit = setmetatable({ fire_wound = 8, wound = 9, strike = 3, explosion = 5, telepatic = 4, shock = 1 }, { __call = function(_, original)
		local copy = {}
		for k, v in pairs(original or {}) do copy[k] = v end
		return copy
	end })
	-- every class id the Ball's tiers name gets its own number on first use (an absent one would end the mod's ipairs)
	local next_cls = 200
	clsid = setmetatable({}, { __index = function(t, k)
		next_cls = next_cls + 1
		rawset(t, k, next_cls)
		return next_cls
	end })
	function normalize(v, lo, hi) return (v - lo) / (hi - lo) end
	function SYS_GetParam(_, _, _, def) return def end
	function random_float(a) return a end
	function empty_table(t) for k in pairs(t) do t[k] = nil end end
	function particles_object() return { play_at_pos = function() end, playing = function() return false end } end
	function dik_to_bind(k) return k end
	key_bindings = { kUSE = 77 }
	TEST_RANDOM = function(a, b) if b then return a end return 1 end
	TEST_ROLL = function(a, b) if b then return a end return 1 end -- Momopate's dice: 1 is a proc at every count
	demonized_time_events = { CreateTimeEvent = CreateTimeEvent, RemoveTimeEvent = RemoveTimeEvent }
	utils_item = { get_ammo = function() return { "ammo_9x39_pab9" } end }
	utils_obj = { safe_bone_pos = function(o) return o:position() end }
	demonized_geometry_ray = { geometry_ray = function() return { get = function()
		return { result = { object = db.actor } }
	end } end }
	function device() return { cam_dir = vec3(0, 0, 1) } end
	do
		local V = getmetatable(vector())
		function V:sub(o) self.x, self.y, self.z = self.x - o.x, self.y - o.y, self.z - o.z return self end
		function V:normalize()
			local l = math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
			if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end
			return self
		end
	end
	INI.dog_weak = { Health = 100 }
	INI.boar_strong = { Health = 250 }

	-- objects: id 0 = this process's own actor (the client's on the player's machine, the host's on the co-op host),
	-- 500 = the client's character on the decider
	local actor = make_actor(vec3(0, 0, 0))
	local _, remote = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local _, wpn = spawn("wpn_vintorez", vec3(0, 0, 0), 0, { kind = "weapon" })
	local GO = getmetatable(remote)
	-- the engine's gate on a client: another's creature keeps its health (coop_calls.h:308,738; script_game_object.cpp:153)
	REFUSED = 0
	local function gated(self) return MODE == "client" and self._id ~= 0 end
	local function rec(self, what) self._log = self._log or {}; self._log[#self._log + 1] = what end
	function GO:change_health(v)
		if gated(self) then REFUSED = REFUSED + 1 return end
		self._dh = (self._dh or 0) + 1
		self._last_dh = v
		self.health = (self.health or 1) + v
		rec(self, "change")
		if self.health <= 0 and self._alive ~= false then
			self._alive = false
			self._killed_by = "last hitter" -- the engine's own choice (entity_alive.cpp:229-237)
		end
	end
	function GO:set_health_ex(v)
		if gated(self) then REFUSED = REFUSED + 1 return end
		self.health = v
		rec(self, "weaken")
	end
	function GO:kill(who)
		if gated(self) then REFUSED = REFUSED + 1 return end
		self._alive = false
		self.health = 0
		self._killed_by = who and who:id()
		rec(self, "kill")
	end
	PENDING, FORWARDED = {}, {}
	function GO:hit(h)
		if gated(self) then
			PENDING[#PENDING + 1] = { victim = self, h = h } -- sent at the frame's end, after the client's before-hit chain
			return
		end
		self._hits = self._hits or {}
		local who = h.draftsman and h.draftsman:id()
		self._hits[#self._hits + 1] = { who = who, power = h.power, type = h.type, impulse = h.impulse, weapon = h.weapon_id,
			before = self.health }
		rec(self, "hit")
		if self._alive ~= false and (h.power or 0) >= (self.health or 1) then
			self._alive = false
			self._killed_by = who
		end
	end
	function GO:character_community() return self._comm or "stalker" end
	function GO:change_power() end
	function GO:invulnerable() return self._inv == true end
	function GO:clsid() return self._cls or clsid.dog_s end
	function GO:get_ammo_type() return 0 end
	function GO:alive() return self._alive ~= false end
	-- the client's frame ends: his before-hit chain runs on each queued hit, false keeps it from the host (client_hit_perks)
	local function frame_end()
		while PENDING[1] do
			local p = table.remove(PENDING, 1)
			local flags = { ret_value = true }
			SendScriptCallback(IsMonster(p.victim) and "monster_on_before_hit" or "npc_on_before_hit", p.victim, p.h, 0, flags)
			if flags.ret_value then FORWARDED[#FORWARDED + 1] = p end
		end
	end

	actor._comm, remote._comm = "actor_greh", "greh"
	local function creature(sec, pos, kind, extra)
		local _, o = spawn(sec, pos, nil, { kind = kind })
		for k, v in pairs(extra or {}) do o[k] = v end
		return o
	end
	local dog = creature("dog_weak", vec3(1.5, 0, 0), "monster")
	local boar = creature("boar_strong", vec3(2, 0, 0), "monster", { _cls = clsid.boar_s })
	local bandit = creature("stalker", vec3(5, 0, 0), "stalker")
	local far = creature("dog_weak", vec3(3000, 0, 0), "monster")
	-- companions: his (greh), the host player's (greh, weaker), his of another community
	local mate = creature("greh_mate", vec3(4, 0, 0), "stalker", { _comm = "greh", health = 0.5 })
	local host_mate = creature("greh_host", vec3(4, 0, 1), "stalker", { _comm = "greh", health = 0.3 })
	local loner = creature("loner", vec3(4, 0, 2), "stalker", { _comm = "stalker", health = 0.2 })
	LEADERS = { [mate:id()] = PROXY, [host_mate:id()] = 0, [loner:id()] = PROXY }
	coop_npc_companions = { owner_character = function(npc) return LEADERS[npc:id()] end }
	axr_companions = { non_task_companions = { [mate:id()] = true, [host_mate:id()] = true, [loner:id()] = true } }
	-- the client's artefacts are in his character on the decider (500); his machine passes their ids as PBA does
	local function item(sec, parent) local _, o = spawn(sec, vec3(0, 0, 0), parent) return o end
	local repei, chelust, ball = item("af_repei", PROXY), item("af_chelust", PROXY), item("af_ball", PROXY)
	local host_repei, host_chelust, host_ball = item("af_repei", 0), item("af_chelust", 0), item("af_ball", 0)
	actor.iterate_belt = function() end
	actor.active_item = function() return nil end

	-- the module perk_based_artefacts out of real slices
	local pba = setmetatable({}, { __index = _G })
	perk_based_artefacts = pba
	pba.set_psy_health, pba.change_psy_health = function() end, function() end
	pba.get_artefact_from_container = function(sec) return sec end
	local mach, mach_at = between("-- Callbacks\ncallbacks = {}", "speed_boosts = {")
	load_slice(pba, mach, mach_at, "\nfunction TEST_TIME(t) time_elapsed = t end\nfunction TEST_PROCESS() process_timed_effects() end")
	pba.artefact_props = { af_lighthouse = {}, af_kogot = {} }
	for _, s in ipairs({ { "\taf_ball = {", "\taf_spaika = {" }, { "\taf_repei = {", "\taf_cocoon = {" },
		{ "\taf_chelust = {", "\taf_zhelch = {" } }) do
		local text, at = between(s[1], s[2])
		for k, v in pairs(load_slice(pba, "return {" .. text .. "}", at)) do pba.artefact_props[k] = v end
	end
	local PBA_REPEI = pba.artefact_props.af_repei
	local function entry(tbl, header, last)
		local text, at = between(header, last, assert(SRC:find(tbl, 1, true)))
		return load_slice(pba, "return {" .. text .. "}", at)
	end
	pba.artefact_on_npc_before_hit_functions = entry("artefact_on_npc_before_hit_functions = {", "\taf_repei = function(", "\n}\n")
	pba.artefact_on_monster_before_hit_functions = entry("artefact_on_monster_before_hit_functions = {", "\taf_repei = function(", "\n}\n")
	pba.artefact_on_update_functions = entry("artefact_on_update_functions = {", "\taf_chelust = function(", "\t-- Scar, Perk:")
	pba.artefact_on_equip_functions = entry("artefact_on_equip_functions = {", "\taf_ball = function(", "\t-- Seraphim, Perk")
	pba.artefact_on_key_press_functions = entry("artefact_on_key_press_functions = {", "\taf_ball = function(", "\n}\n")
	for _, k in ipairs({ "artefact_on_before_hit_functions", "artefact_on_hit_functions", "artefact_on_weapon_fired_functions",
		"artefact_on_item_drag_dropped_functions", "artefact_on_npc_death_functions", "artefact_on_monster_death_functions",
		"artefact_on_before_death_functions", "artefact_on_item_use_functions" }) do pba[k] = pba[k] or {} end
	pba.artefact_on_equip_functions.af_ball(actor, 1, { ball:id() }, { "af_ball" }) -- the Ball's monsters for one copy

	-- G.A.M.M.A. Actor Damage Balancer, loaded as the game loads a script (its own module table); its dice through TEST_ROLL
	local function load_momopate()
		local real_random = math.random
		math.random = function(...) return TEST_ROLL(...) end
		local header = "local this = {} momopate_pba_tweaks = this setmetatable(this, {__index = _G}) setfenv(1, this) "
		local f = assert(loadstring(header .. MOMO, "@momopate_pba_tweaks.script"))
		local ok, e = pcall(f)
		math.random = real_random
		assert(ok, e)
		return momopate_pba_tweaks
	end

	load_script("coop_main")
	for _, n in ipairs(MODE_FILES) do load_script(n) end
	load_script("coop_mods_core")
	coop_main.on_game_start()
	coop_mods_core.on_game_start()
	local ab = load_script("coop_mods_perk_abilities")
	ab.on_game_start()
	local path = io.open("gamedata/scripts/coop_mods_perk_dots.script", "r")
	local dots = nil
	if path then
		path:close()
		dots = load_script("coop_mods_perk_dots")
		dots.on_game_start()
	end
	check(dots ~= nil, "the adapter coop_mods_perk_dots is loaded")
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
	local function last_cmd(kind)
		for i = #SENT, 1, -1 do
			local e = SENT[i]
			if e.name == "mods.pba_cmd" and e.target == 0 then
				local t = coop_main.decode(e.payload)
				if kind == nil or t.k == kind then return t, e end
			end
		end
	end
	local function sent_count()
		local n = 0
		for _, e in ipairs(SENT) do if e.name == "mods.pba_cmd" and e.target == 0 then n = n + 1 end end
		return n
	end
	local function tick(ms)
		NOW = NOW + (ms or 600)
		SendScriptCallback("actor_on_update")
	end
	-- the decider's 100 ms steps
	local function run(ms)
		for _ = 1, math.floor(ms / 100) do tick(100) end
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
	local function fresh(o, health)
		o._alive, o.health, o._dh, o._last_dh, o._killed_by, o._log, o._hits = nil, health or 1, nil, nil, nil, nil, nil
	end
	local function n_effects()
		local n = 0
		for _ in pairs(pba.timed_effects) do n = n + 1 end
		return n
	end
	local function shot(power) return hit({ power = power, type = hit.fire_wound, draftsman = actor, weapon_id = wpn:id() }) end
	local function trust_failed(name)
		local c = coop_trust.status()[name]
		return c and c.failed or 0
	end
	local function n_dots() return dots and dots._state and dots._state().dots or -1 end
	local thistle_mon = pba.artefact_on_monster_before_hit_functions
	local thistle_npc = pba.artefact_on_npc_before_hit_functions

	if set ~= "none" then
		---------------------------------------------------------------------------------------------------------------
		-- m08:5 / m24:2  Thistle's bleeding: the mod's own first (no Momopate)
		---------------------------------------------------------------------------------------------------------------
		as_owner()
		fresh(dog)
		local s_hit = shot(1.0)
		local refused0, sent0 = REFUSED, sent_count()
		thistle_mon.af_repei(actor, 2, { repei:id() }, { "af_repei" }, dog, s_hit, 0, {})
		check(near(s_hit.power, 0.5), "m08:5: PBA's Thistle still halves the client's hit")
		check(n_effects() == 0, "m08:5: no bleeding effect is kept on the client (his copy of the creature is not his)")
		local b1, raw1 = last_cmd("bleed")
		check(sent_count() == sent0 + 1 and b1 and b1.t == dog:id() and b1.i1 == repei:id() and b1.n == 2 and near(b1.b, 0.0028)
			and b1.d == 7 and b1.s == 1, "m08:5: the bleeding is a request with its target, artefact and the mod's own amount (7 s)")
		pba.TEST_PROCESS()
		check(REFUSED == refused0 and near(dog.health, 1), "m08:5: nothing touches the client's copy of the creature")
		if raw1 then deliver(raw1) end
		run(8000)
		check(dog._dh == 71 and near(dog.health, 1 - 71 * 0.0028),
			"m08:5: the decider ticks the bleeding every 100 ms for the mod's 7 s (71 ticks)")
		if raw1 then deliver(raw1) end
		run(1000)
		check(dog._dh == 71, "m08:5: the same request again ticks nothing more (once)")

		---------------------------------------------------------------------------------------------------------------
		-- m24:2  Momopate's Thistle (the Actor Damage Balancer replaces artefact_props.af_repei at load)
		---------------------------------------------------------------------------------------------------------------
		local momo = load_momopate()
		check(pba.artefact_props.af_repei ~= PBA_REPEI and momo.s_event ~= nil, "m24:2: Momopate's Thistle is the active one")
		as_owner()
		fresh(dog)
		SOUNDS = {}
		s_hit = shot(0.8)
		sent0 = sent_count()
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog, s_hit, 0, {})
		check(near(s_hit.power, 0.4), "m24:2: the immediate multiplier still applies to the client's hit")
		check(#SOUNDS == 1 and SOUNDS[1].name:find("GIBLET", 1, true) ~= nil, "m24:2: the proc's sound plays on the client")
		check(n_effects() == 0, "m24:2: no local bleeding effect on the client")
		local b2, raw2 = last_cmd("bleed")
		check(sent_count() == sent0 + 1 and b2 and b2.t == dog:id() and near(b2.b, 0.4 * 0.0045 * 0.75) and b2.d == 3.5,
			"m24:2: the confirmed bleeding goes to the decider (Momopate's amount and 3.5 s)")
		if raw2 then deliver(raw2) end
		local ticks0 = dog._dh or 0
		run(1000)
		check((dog._dh or 0) > ticks0, "m24:2: the decider's ticks hurt the creature")
		run(4000)
		check(dog._dh == 36 and near(dog.health, 1 - 36 * 0.4 * 0.0045 * 0.75),
			"m24:2: bleed ticks run once on the decider and stop at the bound (3.5 s: 36 ticks)")
		-- a hit without the proc sends nothing
		TEST_ROLL = function(a, b) if b then return a end return 100 end
		as_owner()
		sent0 = sent_count()
		NOW = NOW + 600
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog, shot(0.8), 0, {})
		check(sent_count() == sent0, "m24:2: no proc, no request")
		TEST_ROLL = function(a, b) if b then return a end return 1 end

		-- credit: the bleeding's last tick kills the creature for the shooter
		local dog2 = creature("dog_weak", vec3(2, 0, 2), "monster", { health = 0.003 })
		as_owner()
		NOW = NOW + 600
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog2, shot(0.8), 0, {})
		local _, raw3 = last_cmd("bleed")
		if raw3 then deliver(raw3) end
		run(1000)
		check(dog2._alive == false and dog2._killed_by == PROXY,
			"m24:2: the bleeding's lethal tick kills the creature for his character (the damage source kept)")
		check(dog2._dh == 2, "m24:2: ... after two ordinary ticks, and nothing more after the death")
		-- an invulnerable creature takes the change as the engine gives it, never a kill
		local inv = creature("dog_weak", vec3(2, 0, 3), "monster", { health = 0.001, _inv = true })
		as_owner()
		NOW = NOW + 600
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, inv, shot(0.8), 0, {})
		local _, raw4 = last_cmd("bleed")
		if raw4 then deliver(raw4) end
		run(300)
		check(inv._killed_by ~= PROXY, "m24:2: an invulnerable creature is never killed by the request")

		if set == "hostplay" then
			-- The host's own hit, calling the PBA table directly. This does not exercise grok_bo's routing for remote shooters.
			as_decider()
			fresh(bandit)
			NOW = NOW + 600
			sent0 = sent_count()
			thistle_npc.af_repei(actor, 1, { host_repei:id() }, { "af_repei" }, bandit, shot(0.8), 0, {})
			run(3600)
			check(sent_count() == sent0 and bandit._dh == 36 and near(bandit.health, 1 - 36 * 0.4 * 0.0045 * 0.75),
				"co-op: the host's own direct PBA stalker hit bleeds locally (36 ticks)")
		end

		-- several procs within the pacing gap go as one request (the shared verb's budget), the same total
		as_owner()
		fresh(dog)
		NOW = NOW + 600
		sent0 = sent_count()
		for _ = 1, 3 do thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog, shot(0.8), 0, {}) end
		local merged = sent_count() - sent0
		tick(600)
		local b6 = last_cmd("bleed")
		check(merged == 1 and sent_count() == sent0 + 2 and b6 and b6.s == 2 and near(b6.b, 2 * 0.4 * 0.0045 * 0.75),
			"m24:2: procs within 0.5 s of a request are merged into the next one (stacks and amount summed)")

		do
			local ids, names = { repei:id() }, { "af_repei" }
			local function proc(target) thistle_mon.af_repei(actor, 1, ids, names, target, shot(0.8), 0, {}) end
			fresh(boar)
			proc(boar) -- older target already waiting behind the last request
			NOW = NOW + 200
			sent0 = sent_count()
			for _ = 1, 17 do proc(dog) end
			check(sent_count() == sent0, "m24:2: a full bleed batch waits out the 250 ms minimum")
			tick(50)
			local full = last_cmd("bleed")
			check(sent_count() == sent0 + 1 and full and full.t == dog:id() and full.s == 16
				and near(full.b, 16 * 0.4 * 0.0045 * 0.75), "m24:2: the full batch goes at 250 ms before the older partial batch")
			tick(500)
			local older = last_cmd("bleed")
			check(sent_count() == sent0 + 2 and older and older.t == boar:id() and older.s == 1,
				"m24:2: the older partial batch still goes on the normal interval")
			tick(500)
			local excess = last_cmd("bleed")
			check(sent_count() == sent0 + 3 and excess and excess.t == dog:id() and excess.s == 1
				and near(excess.b, 0.4 * 0.0045 * 0.75), "m24:2: the seventeenth proc is sent separately with its full amount")
			NOW = NOW + 250
			for _ = 1, 15 do proc(dog) end
			check(sent_count() == sent0 + 3, "m24:2: a partial batch still waits for the normal interval")
			proc(dog)
			local at_cap = last_cmd("bleed")
			check(sent_count() == sent0 + 4 and at_cap and at_cap.t == dog:id() and at_cap.s == 16,
				"m24:2: the sixteenth proc sends immediately when the 250 ms minimum has elapsed")
		end

		---------------------------------------------------------------------------------------------------------------
		-- forged bleedings
		---------------------------------------------------------------------------------------------------------------
		forget()
		local function bleed_of(target, extra, wait)
			NOW = NOW + (wait or 500)
			local t = { k = "bleed", q = next_q(), t = target, n = 1, i1 = repei:id(), b = 0.001, d = 3.5, s = 1 }
			for k, v in pairs(extra or {}) do t[k] = v end
			deliver(forged(t))
		end
		fresh(boar)
		boar.health = 100
		bleed_of(boar:id(), { d = 1e9 })
		run(10000)
		check(boar._dh == 36 and trust_failed("pba_bleed_duration") >= 1,
			"m24:2: a forged duration is cut to the mod's (36 ticks) and counted")
		fresh(boar)
		boar.health = 100
		bleed_of(boar:id(), { b = 10 })
		run(200)
		local cap = 50 * 0.5 * 0.0045 * 0.75
		check(near(boar._last_dh, -cap) and trust_failed("pba_bleed_amount") >= 1,
			"m24:2: a forged amount is cut to the mod's formula for his artefacts and a hit of 50, counted")
		run(5000)
		local before = n_dots()
		bleed_of(boar:id(), { b = 0 / 0 })
		bleed_of(boar:id(), { b = -1 })
		bleed_of(boar:id(), { b = "x" })
		check(n_dots() == before, "m24:2: a malformed amount is dropped in every mode")
		bleed_of(PROXY)
		bleed_of(0)
		bleed_of(65000)
		check(n_dots() == before, "m24:2: a player or a missing object is never a bleeding's target")
		coop_trust.reset_for_test({ default = "refuse" })
		bleed_of(boar:id(), { i1 = host_repei:id() })
		bleed_of(boar:id(), { b = 10 })
		bleed_of(far:id())
		check(n_dots() == before, "m24:2: refuse mode: another's Thistle, an amount over the bound, a target out of range")
		coop_trust.reset_for_test({ default = "log" })
		for _ = 1, 40 do bleed_of(boar:id()) end
		check(n_dots() == 24 and trust_failed("pba_bleed_dots") >= 1, "m24:2: at most 24 bleedings of one player at once (always on)")
		run(5000)
		check(n_dots() == 0, "m24:2: every bleeding ends at its bound")
		coop_trust.reset_for_test({ default = "refuse" })
		bleed_of(boar:id())
		local rate0 = trust_failed("pba_bleed_rate")
		bleed_of(boar:id(), nil, 249)
		check(n_dots() == 1 and trust_failed("pba_bleed_rate") == rate0 + 1,
			"m24:2: refuse mode: an interval of 249 ms counts as too soon")
		bleed_of(boar:id(), nil, 1)
		check(n_dots() == 2 and trust_failed("pba_bleed_rate") == rate0 + 1,
			"m24:2: refuse mode: an interval of 250 ms is accepted")
		run(4000)
		coop_trust.reset_for_test({ default = "log" })

		-- a bleeding outlives its shooter on the map: its kill falls to the engine's last hitter
		forget()
		local dog3 = creature("dog_weak", vec3(1, 0, 2), "monster", { health = 0.0015 })
		bleed_of(dog3:id(), { b = 0.001 })
		local avatar_of = coop.avatar_of
		local peer_of = coop.peer_of_avatar
		coop.peer_of_avatar = function(id) if id == PROXY then return nil end return peer_of(id) end
		run(300)
		coop.peer_of_avatar = peer_of
		coop.avatar_of = avatar_of
		check(dog3._alive == false and dog3._killed_by == "last hitter",
			"m24:2: his character gone: the lethal tick is the mod's own change (the engine credits the last hitter)")

		if set ~= "hostplay" then
			-- two maps: each player's request goes to the map server of his own level
			local bridges = { [1] = 0x101, [2] = 0x102 }
			as_world({ level_request = function(_, payload, from)
				local tt = coop_main.decode(payload)
				tt._peer = from
				return "pass", bridges[from], coop_main.encode(tt)
			end })
			local before_w = n_dots()
			for peer = 1, 2 do
				local r = forged({ k = "bleed", q = next_q(), t = dog:id(), n = 1, b = 0.001, d = 3.5, s = 1 })
				coop_main.on_event(r.name, r.payload, peer)
				local passed = SENT[#SENT]
				check(passed.target == bridges[peer] and coop_main.decode(passed.payload)._peer == peer,
					"server, two maps: the bleeding of player " .. peer .. " goes to his own map server")
			end
			check(n_dots() == before_w, "server: the world server, which has no map, ticks nothing")
		else
			-- the host's own player: the same decider function, called directly (no event), his kill
			as_decider()
			local dog4 = creature("dog_weak", vec3(1, 0, 1), "monster", { health = 0.0007 })
			sent0 = sent_count()
			NOW = NOW + 600
			thistle_mon.af_repei(actor, 1, { host_repei:id() }, { "af_repei" }, dog4, shot(0.8), 0, {})
			check(sent_count() == sent0 and n_effects() == 0, "co-op: the host's own bleeding goes to the decider function directly")
			run(300)
			check(dog4._alive == false and dog4._killed_by == 0, "co-op: ... and its lethal tick is the host player's kill")
		end

		---------------------------------------------------------------------------------------------------------------
		-- m08:5  Chain: the companion's heal on the decider
		---------------------------------------------------------------------------------------------------------------
		forget()
		as_owner()
		mate.health, host_mate.health, loner.health = 0.5, 0.3, 0.2
		local chain = pba.artefact_on_update_functions.af_chelust
		local refused1, own0 = REFUSED, actor.health
		sent0 = sent_count()
		local first, healed_first, ms = nil, nil, {}
		-- the decider gets each request as it is sent
		local function pass_on()
			local c, raw = last_cmd("chain")
			if c and sent_count() > sent0 + #ms then
				ms[#ms + 1] = c.m
				deliver(raw)
				as_owner()
			end
			return c
		end
		for i = 1, 21 do
			chain(actor, 1, { chelust:id() }, { "af_chelust" })
			if i == 1 then
				check(REFUSED == refused1 and near(mate.health, 0.5),
					"m08:5: the Chain does not touch the client's copy of a companion")
				first = pass_on()
				healed_first = mate.health
			end
			tick(100)
			pass_on()
		end
		-- a client's stock companion table may be false: the Chain's call gives it back as it was
		local list = axr_companions.non_task_companions
		axr_companions.non_task_companions = false
		chain(actor, 1, { chelust:id() }, { "af_chelust" })
		check(axr_companions.non_task_companions == false, "m08:5: the stock companion table comes back as it was")
		axr_companions.non_task_companions = list
		tick(2000) -- the rest of the ticks once the Chain stops
		pass_on()
		check(near(actor.health, own0 + 22 * 0.0004), "m08:5: the Chain's own heal stays his (22 ticks)")
		check(first and first.m == 1 and first.i1 == chelust:id() and near(healed_first, 0.5 + 0.0015),
			"m08:5: the first Chain tick is told at once and heals his companion")
		check(#ms == 3 and ms[2] == 19 and ms[3] == 2, "m08:5: then the ticks of every 2 s go as one request, the rest after")
		check(near(mate.health, 0.5 + 22 * 0.0015), "m08:5: heal reaches his companion on the decider (0.0015 a tick)")
		check(trust_failed("pba_chain_community") == 0, "m08:5: the remote greh stalker passes the Chain's actor_greh check")
		check(near(host_mate.health, 0.3) and near(loner.health, 0.2),
			"m08:5: another player's weaker companion and his companion of another community are not healed")

		-- forged ticks, a missing Chain, the wrong community, no companion here
		forget()
		local function chain_of(extra, wait)
			NOW = NOW + (wait or 2000)
			local t = { k = "chain", q = next_q(), n = 1, i1 = chelust:id(), m = 20 }
			for k, v in pairs(extra or {}) do t[k] = v end
			deliver(forged(t))
		end
		mate.health = 0.5
		chain_of({ m = 1000 })
		check(near(mate.health, 0.5 + 25 * 0.0015) and trust_failed("pba_chain_ticks") >= 1,
			"m08:5: a forged tick count is cut to 2.5 s of the mod's ticks, counted")
		mate.health = 0.5
		chain_of({ m = 1000 }, 700)
		check(near(mate.health, 0.5 + 9 * 0.0015), "m08:5: ... and to the time since his last heal")
		mate.health = 0.5
		chain_of(nil, 100)
		check(near(mate.health, 0.5), "m08:5: a heal 0.1 s after the last is dropped (always on)")
		coop_trust.reset_for_test({ default = "refuse" })
		chain_of({ i1 = host_chelust:id() })
		check(near(mate.health, 0.5), "m08:5: refuse mode: a heal without his own Chain is refused")
		remote._comm = "stalker"
		chain_of()
		check(near(mate.health, 0.5), "m08:5: refuse mode: a character outside the Chain's community heals nobody")
		coop_trust.reset_for_test({ default = "log" })
		chain_of()
		check(near(mate.health, 0.5 + 20 * 0.0015) and trust_failed("pba_chain_community") >= 1,
			"m08:5: log mode: counted, let through (build 57)")
		remote._comm = "greh"
		local mate_obj = OBJ[mate:id()]
		OBJ[mate:id()] = nil
		local ok_off = pcall(chain_of)
		OBJ[mate:id()] = mate_obj
		check(ok_off and near(host_mate.health, 0.3) and near(loner.health, 0.2),
			"m08:5: his companion not on this map: nobody else is healed in his place")
		mate.health = 1
		chain_of()
		check(near(mate.health, 1) and near(host_mate.health, 0.3), "m08:5: a companion at full health takes no heal")

		if set ~= "hostplay" then
			local adopted = creature("greh_adopted", vec3(4, 0, 0), "stalker", { _comm = "greh", health = 0.5 })
			local task = creature("greh_task", vec3(4, 0, 1), "stalker", { _comm = "greh", health = 0.1 })
			LEADERS[adopted:id()], LEADERS[task:id()] = PROXY, PROXY
			local squad = spawn("greh_squad", vec3(4, 0, 0), nil, { offline = true })
			function squad:squad_members()
				local i, members = 0, { { id = task:id() }, { id = adopted:id() } }
				return function()
					i = i + 1
					return members[i]
				end
			end
			local marks = {
				[adopted:id()] = { companion = true },
				[task:id()] = { companion = true, companion_cannot_dismiss = true },
			}
			for id in pairs(marks) do SE[id].name = SE[id].section_name end
			local load_var = se_load_var
			se_load_var = function(id, name, key)
				return marks[id] and name == SE[id]:name() and marks[id][key]
			end
			axr_companions.companion_squads = { [squad.id] = squad }
			mate.health = 0.4
			chain_of()
			check(near(mate.health, 0.4 + 20 * 0.0015) and near(adopted.health, 0.5),
				"server: the weakest ordinary companion is chosen across the stock list and adopted squad")
			mate.health = 0.6
			chain_of()
			check(near(adopted.health, 0.5 + 20 * 0.0015) and near(mate.health, 0.6),
				"server: the adopted companion is considered even with an eligible companion in the stock list")
			axr_companions.non_task_companions = false
			chain_of()
			check(near(adopted.health, 0.5 + 40 * 0.0015), "server: a marked companion adopted from another map is healed without the stock list")
			check(near(task.health, 0.1), "server: a weaker member marked companion_cannot_dismiss is never healed")
			axr_companions.non_task_companions, axr_companions.companion_squads = list, nil
			se_load_var = load_var
		end

		if set == "hostplay" then
			-- the host's own Chain heals his companion, never a client's weaker one
			as_decider()
			mate.health, host_mate.health = 0.2, 0.6
			sent0 = sent_count()
			NOW = NOW + 3000
			chain(actor, 1, { host_chelust:id() }, { "af_chelust" })
			tick(100)
			check(sent_count() == sent0 and near(host_mate.health, 0.6 + 0.0015) and near(mate.health, 0.2),
				"co-op: the host's own Chain goes to the decider function directly and heals only his companion")
		end

		---------------------------------------------------------------------------------------------------------------
		-- m08:5  Ball: the target weakened and kicked on the decider
		---------------------------------------------------------------------------------------------------------------
		forget()
		as_owner()
		fresh(dog)
		level.get_target_obj = function() return dog end
		pba.remove_cooldown("af_ball")
		PENDING, FORWARDED = {}, {}
		local refused2 = REFUSED
		sent0 = sent_count()
		pba.artefact_on_key_press_functions.af_ball(actor, 1, { ball:id() }, { "af_ball" }, key_bindings.kUSE)
		local k1, rawk1 = last_cmd("ball")
		check(sent_count() == sent0 + 1 and k1 and k1.t == dog:id() and k1.i1 == ball:id() and k1.n == 1,
			"m08:5: the Ball's kick is a request with its target and artefact")
		check(REFUSED == refused2 + 1 and near(dog.health, 1), "m08:5: the client's own weakening is refused there (as before)")
		check(not pba.check_cooldown("af_ball"), "m08:5: the Ball's cooldown stays the client's")
		frame_end()
		check(#FORWARDED == 0, "m08:5: the client's own kick is not sent (the decider kicks)")
		if rawk1 then deliver(rawk1) end
		local h1 = dog._hits and dog._hits[1]
		check(dog._log and dog._log[1] == "weaken" and dog._log[2] == "hit" and h1 and near(h1.before, 0.01),
			"m08:5: the decider weakens the target to 0.01 before its hit")
		check(h1 and h1.who == PROXY and h1.weapon == PROXY and near(h1.power, 1) and h1.type == hit.wound and h1.impulse == 10000,
			"m08:5: ... the mod's hit: his character, the creature's own health as power, wound, impulse 10000")
		check(dog._alive == false and dog._killed_by == PROXY, "m08:5: the Ball kills for him")
		if rawk1 then deliver(rawk1) end
		check(#(dog._hits or {}) == 1, "m08:5: the same request again kicks nothing")
		-- a bullet of his on the same creature in that frame is not taken for the kick
		as_owner()
		fresh(boar)
		pba.remove_cooldown("af_ball")
		NOW = NOW + 3000
		level.get_target_obj = function() return dog end
		fresh(dog)
		PENDING, FORWARDED = {}, {}
		dog:hit(shot(0.3))
		pba.artefact_on_key_press_functions.af_ball(actor, 1, { ball:id() }, { "af_ball" }, key_bindings.kUSE)
		frame_end()
		check(#FORWARDED == 1 and FORWARDED[1].h.type == hit.fire_wound, "m08:5: only the kick is held back, his bullet goes")

		-- forged kicks
		forget()
		local function kick_of(target, extra, wait)
			NOW = NOW + (wait or 2500)
			local t = { k = "ball", q = next_q(), t = target, n = 1, i1 = ball:id() }
			for k, v in pairs(extra or {}) do t[k] = v end
			deliver(forged(t))
		end
		fresh(dog)
		kick_of(dog:id())
		check(dog._alive == false, "m08:5: (a kick)")
		fresh(dog)
		kick_of(dog:id(), nil, 500)
		check(dog._log == nil, "m08:5: a second kick within 1.5 s is dropped (always on)")
		coop_trust.reset_for_test({ default = "refuse" })
		kick_of(dog:id(), nil, 1000) -- 1500 ms since the accepted kick
		check(dog._killed_by == PROXY and trust_failed("pba_ball_rate") == 0,
			"m08:5: refuse mode: a Ball interval of 1500 ms is accepted")
		fresh(boar)
		kick_of(boar:id())
		check(boar._log == nil, "m08:5: refuse mode: a creature above his Ball's tier is refused")
		fresh(bandit)
		kick_of(bandit:id())
		check(bandit._log == nil, "m08:5: refuse mode: the Ball kicks no stalker")
		fresh(far)
		kick_of(far:id())
		check(far._log == nil, "m08:5: refuse mode: a target out of reach is refused")
		fresh(dog)
		kick_of(dog:id(), { i1 = host_ball:id() })
		check(dog._log == nil, "m08:5: refuse mode: a kick without his own Ball is refused")
		coop_trust.reset_for_test({ default = "log" })
		fresh(boar)
		kick_of(boar:id())
		check(boar._alive == false and trust_failed("pba_ball_kind") >= 1, "m08:5: log mode: counted, let through (build 57)")
		fresh(bandit)
		local kind0 = trust_failed("pba_ball_kind")
		kick_of(bandit:id())
		check(bandit._log == nil and trust_failed("pba_ball_kind") == kind0 + 1,
			"m08:5: log mode: a stalker is counted but never touched by the Ball")
		fresh(dog, 0)
		dog._alive = false
		kick_of(dog:id())
		check(dog._log == nil and dog.health == 0, "m08:5: log mode: a dead monster is never touched by the Ball")
		fresh(dog)
		dog._inv = true
		kick_of(dog:id())
		check(dog._log == nil and dog:alive() and dog.health == 1, "m08:5: log mode: an invulnerable monster is never touched by the Ball")
		dog._inv = nil
		remote._log, actor._log = nil, nil
		kick_of(PROXY)
		kick_of(0)
		check(remote._log == nil and actor._log == nil, "m08:5: a player is never kicked (always on)")

		if set == "hostplay" then
			-- the host's own Ball: the creature is the host's, the mod's own call already acts on it
			as_decider()
			fresh(dog)
			pba.remove_cooldown("af_ball")
			NOW = NOW + 3000
			level.get_target_obj = function() return dog end
			sent0 = sent_count()
			pba.artefact_on_key_press_functions.af_ball(actor, 1, { host_ball:id() }, { "af_ball" }, key_bindings.kUSE)
			check(sent_count() == sent0 and dog._log and dog._log[1] == "weaken" and dog._killed_by == 0,
				"co-op: the host's own Ball weakens and kicks its own creature as the mod does")
		end
	else
		---------------------------------------------------------------------------------------------------------------
		-- single player: every perk is the stock one
		---------------------------------------------------------------------------------------------------------------
		modes.install(coop_mode, "none")
		fresh(dog)
		local s_hit = shot(1.0)
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog, s_hit, 0, {})
		pba.TEST_TIME(1)
		pba.TEST_PROCESS()
		check(near(s_hit.power, 0.5) and n_effects() == 1 and dog._dh == 1 and near(dog.health, 1 - 0.0014),
			"single player: PBA's Thistle bleeds through the mod's own effect")
		pba.TEST_TIME(100)
		pba.TEST_PROCESS()
		load_momopate()
		fresh(dog)
		thistle_mon.af_repei(actor, 1, { repei:id() }, { "af_repei" }, dog, shot(0.8), 0, {})
		pba.TEST_TIME(101)
		pba.TEST_PROCESS()
		check(dog._dh == 1 and near(dog.health, 1 - 0.4 * 0.0045 * 0.75), "single player: Momopate's Thistle, as stock")
		pba.TEST_TIME(200)
		pba.TEST_PROCESS()
		mate.health, host_mate.health, loner.health = 0.5, 0.3, 0.2
		pba.artefact_on_update_functions.af_chelust(actor, 1, { chelust:id() }, { "af_chelust" })
		check(near(host_mate.health, 0.3 + 0.0015) and near(mate.health, 0.5), "single player: the Chain heals the weakest, as stock")
		fresh(dog)
		level.get_target_obj = function() return dog end
		pba.artefact_on_key_press_functions.af_ball(actor, 1, { ball:id() }, { "af_ball" }, key_bindings.kUSE)
		check(dog._log and dog._log[1] == "weaken" and dog._killed_by == 0, "single player: the Ball, as stock")
		check(sent_count() == 0, "single player: nothing is sent")
	end

	if dots then
		-- startup never throws and registers once; an absent PBA installs nothing
		local count = axr_main.count("actor_on_update")
		dots.on_game_start()
		check(axr_main.count("actor_on_update") == count, "repeated startup registers nothing twice")
		perk_based_artefacts = nil
		local fresh_dots = load_script("coop_mods_perk_dots")
		check(pcall(fresh_dots.on_game_start), "without PBA the startup does not throw")
	end
	done("mods perk dots " .. set)
end
