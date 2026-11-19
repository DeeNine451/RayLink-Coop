-- Anomaly Coop Lua test, Dev 57 G9-1 (TZ R19): the credit helper coop_credit (who / once / to_owner / on_owner) and the
-- two credit fixes of coop_reputation, each on the S4 answer sets of the facade coop_mode (docs\MODES.md section 10):
--   u01:1  a mutant's death on a player's MIRROR does not count killed_monsters a second time (the decider's credit of
--          his kill already reaches him): exactly one credit per kill in the host, client and map-server roles
--   s34:1  the decider drops a helicopter's black box for a player's lethal hit too, once per helicopter
-- The stock bodies are the real ones, read from the corpus copies (not the live game): bind_monster.script
-- (temp/review/corpus/merged: the file GAMMA loads), bind_heli.script, mlr_utils.script
-- (temp/stock_scripts/scripts: GAMMA does not override them).
-- Roles per answer set: hostplay = the co-op host and a co-op client (a mirror); srv_world = the world server; srv_map =
-- a map server and a server player's machine (a mirror); none = single player (must stay the stock game).
local modes = dofile("tests/lua/support/modes.lua")

local TOTAL_PASS, TOTAL_FAIL = 0, 0

local function stock_text(path)
	local f = assert(io.open(path, "rb"), "stock copy missing: " .. path)
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end

-- The real top-level function that starts with `header` (it ends at the first "end" at the start of a line), compiled
-- with its own line numbers in `env`. A method (a:b(...)) becomes function(self, ...).
local function real_function(path, header, env)
	local text = stock_text(path)
	local at = assert(text:find(header, 1, true), header)
	local stop = assert(text:find("\nend\n", at, true), "end of " .. header)
	local body = text:sub(at, stop + 3)
	local name, params = body:match("^function%s+([%w_%.:]+)%s*%(([^)]*)%)")
	assert(name, "header of " .. header)
	local args = params
	if name:find(":", 1, true) then args = "self" .. (params:find("%S") and ", " .. params or "") end
	local rest = body:gsub("^function%s+[%w_%.:]+%s*%b()", "", 1)
	local _, lines = text:sub(1, at - 1):gsub("\n", "")
	local chunk = assert(loadstring(string.rep("\n", lines) .. "return function(" .. args .. ")" .. rest,
		"@" .. path:match("[^/]+$")))
	setfenv(chunk, env)
	return chunk()
end

local MONSTER = "temp/review/corpus/merged/bind_monster.script"
local HELI = "temp/stock_scripts/scripts/bind_heli.script"
local MLR = "temp/stock_scripts/scripts/mlr_utils.script"

-- The roles of each answer set: coop.* stubs (MODE of stubs_mods.lua, self peer, the seats), and the facade's answers.
local function client_answers(set)
	return { decides_world = function() return false end, leads_here = function() return false end,
		is_player_mirror = function() return true end, actor_is_player = function() return true end,
		decider = function() return "other" end, where = function() return "here" end, set = set }
end
local ROLES = {
	hostplay = {
		{ label = "co-op host", mode = "host", set = "hostplay", self = 0,
			seats = { { id = 0, avatar = 0 }, { id = 1, avatar = 500 }, { id = 2, avatar = 501 } } },
		{ label = "co-op client", mode = "client", set = "hostplay", self = 1, mirror = true, over = client_answers("hostplay"),
			seats = { { id = 0, avatar = 500 }, { id = 1, avatar = 0 }, { id = 2, avatar = 501 } } },
	},
	srv_world = {
		{ label = "world server", mode = "host", set = "srv_world", self = 0, dedicated = true,
			seats = { { id = 1, avatar = 500 }, { id = 2, avatar = 501 } } },
	},
	srv_map = {
		{ label = "map server", mode = "host", set = "srv_map", self = 0, map_server = true,
			seats = { { id = 1, avatar = 500 }, { id = 2, avatar = 501 } } },
		{ label = "server player", mode = "client", set = "srv_map", self = 1, mirror = true, over = client_answers("srv_map"),
			seats = { { id = 1, avatar = 0 }, { id = 2, avatar = 501 } } },
	},
	none = {
		{ label = "single player", mode = "sp", set = "none", self = -1, seats = {} },
	},
}

local MODULES = { "coop_main", "coop_route", "coop_mode", "coop_hostplay_mode", "coop_srv_mode", "coop_mods_core",
	"coop_npc_players", "coop_credit", "coop_reputation", "coop_trust" }

-- A fresh world for one role (every script reloaded, every stub new).
local W
local function fresh(role, opts)
	opts = opts or {}
	TOTAL_PASS, TOTAL_FAIL = TOTAL_PASS + (PASSES or 0), TOTAL_FAIL + (FAILS or 0)
	for _, n in ipairs(MODULES) do rawset(_G, n, nil) end
	MODE = role.mode
	dofile("tests/lua/support/stubs_mods.lua")
	SELF = role.self
	local seats = {}
	for _, s in ipairs(role.seats) do seats[#seats + 1] = { id = s.id, avatar = s.avatar } end
	W = { role = role, seats = seats }
	coop.self_id = function() return role.self end
	coop.players = function()
		if MODE == "sp" then return {} end
		local out = {}
		for _, s in ipairs(seats) do
			out[#out + 1] = { id = s.id, nick = "p" .. s.id, avatar_id = s.avatar, is_self = s.id == role.self, rtt = 0 }
		end
		return out
	end
	coop.peer_of_avatar = function(id)
		for _, s in ipairs(seats) do if s.avatar == id then return s.id end end
		return nil
	end
	coop.avatar_of = function(peer)
		for _, s in ipairs(seats) do if s.id == peer then return s.avatar end end
		return nil
	end
	coop.to_host_id = function(id) return id end
	coop.to_local_id = function(id) return id end
	if role.map_server then coop.is_map_server = function() return true end end
	if role.dedicated then coop.is_dedicated = function() return true end end

	-- the world: this process's actor (a ghost on a server), the players' characters, an NPC, a mutant, two helicopters
	local actor = make_actor(vec3(0, 0, 0))
	local GOm = getmetatable(actor)
	GOm.set_callback = function() end
	GOm.clsid = function() return 1 end
	GOm.active_item = function() return nil end
	local _, p500 = spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500, kind = "stalker" })
	local _, p501 = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = 501, kind = "stalker" })
	local _, npc = spawn("stalker", vec3(3, 0, 0), nil, { id = 777, kind = "stalker" })
	local _, dog = spawn("dog_weak", vec3(4, 0, 0), nil, { id = 800, kind = "monster" })
	W.actor, W.p500, W.p501, W.npc, W.dog = actor, p500, p501, npc, dog
	for _, o in ipairs({ actor, p500, p501, npc }) do db.storage[o:id()] = { object = o } end

	-- reward context (coop_tasks is not under test: its recipient scope is recorded)
	CREDIT_TO = nil
	coop_tasks = {
		character_of = function(peer)
			if peer == 0 and role.mode ~= "host" then return 0 end
			for _, s in ipairs(seats) do if s.id == peer then return s.avatar end end
			return peer == 0 and 0 or nil
		end,
		with_character = function(id, f, ...)
			local before = CREDIT_TO
			CREDIT_TO = id
			local r = { pcall(f, ...) }
			CREDIT_TO = before
			if not r[1] then error(r[2], 0) end
			return unpack(r, 2)
		end,
		personal_character = function() return CREDIT_TO end,
		each_personal = function() return false end,
		with_participants = function(_, _, f, ...) return f(...) end,
	}
	coop_npc_companions = { owner_character = function() return nil end }
	coop_quests_core = { body_for_character = function(id) return { far = true, id = function() return id end } end }

	-- statistics: "<recipient>:<name>" (self = this process's actor), "npc<id>:<name>" for an NPC's own
	COUNTS = {}
	local function bump(k) COUNTS[k] = (COUNTS[k] or 0) + 1 end
	game_statistics = {
		increment_statistic = function(name) bump((CREDIT_TO ~= nil and tostring(CREDIT_TO) or "self") .. ":" .. name) end,
		increment_npc_statistic = function(n, name) bump("npc" .. n:id() .. ":" .. name) end,
	}

	-- stock: bind_monster's death handler, bind_heli's hit handler, and mlr_utils's box
	local env = setmetatable({}, { __index = _G })
	VEC_ZERO = vector()
	clsid = { poltergeist_s = 99 }
	callback = { death = 1, patrol_path_in_point = 2, hit = 3, sound = 4 }
	xr_combat_ignore = { fighting_with_actor_npcs = {} }
	db.delete_enemy = function() end
	ISSUED = 0
	xr_logic = { issue_event = function()
		ISSUED = ISSUED + 1
		if W.fail_issue then error("issue failed") end
	end }
	release_body_manager = { get_release_body_manager = function() return { moving_dead_body = function() end } end }
	bind_monster = { generic_object_binder = {
		death_callback = real_function(MONSTER, "function generic_object_binder:death_callback(", env),
		hit_callback = function() end,
	} }
	if opts.broken_monster then
		bind_monster = setmetatable({}, { __index = function() error("a broken binder module") end })
	end
	IsLauncher = function() return false end
	env.get_heli_health = real_function(HELI, "function get_heli_health(", env)
	bind_heli = { heli_binder = { on_hit = real_function(HELI, "function heli_binder:on_hit(", env) } }
	mlr_utils = { death_heli = real_function(MLR, "function death_heli(", env) }
	AddScriptCallback("monster_on_death_callback")
	MONSTER_DEATHS = 0
	-- a probe of a coop_* script (route view): it sees the callback on every machine, a mirror included
	RegisterScriptCallback("monster_on_death_callback",
		from_script("coop_credit_probe", "return function() MONSTER_DEATHS = MONSTER_DEATHS + 1 end"))

	-- the facade answers as the role, the scripts start as axr_main starts them
	load_script("coop_main")
	load_script("coop_mode")
	modes.install(coop_mode, role.set, role.over)
	local cr = rawget(_G, "coop_credit") or coop_credit
	if cr and cr.on_game_start then cr.on_game_start() end
	coop_reputation.on_game_start()
	return W
end

-- A check group that keeps going when the code under test is missing or raises (the red run names every failure).
local function section(label, fn)
	local ok, err = pcall(fn)
	if not ok then check(false, label .. " raised: " .. tostring(err)) end
end

local function binder_of(obj)
	return setmetatable({ object = obj, st = {} }, { __index = function(_, k) return bind_monster.generic_object_binder[k] end })
end
local function kill_mutant(who)
	return bind_monster.generic_object_binder.death_callback(binder_of(W.dog), W.dog, who)
end

local HELI_ID = 900
local function new_heli()
	HELI_ID = HELI_ID + 1
	local _, h = spawn("helicopter", vec3(0, 50, 0), nil, { id = HELI_ID })
	h.health = 1
	h.GetfHealth = function(s) return s.health end
	h.SetfHealth = function(s, v) s.health = v end
	return setmetatable({ object = h, st = { heliObject = h }, heli_fire = {}, last_hit_snd_timeout = math.huge },
		{ __index = function(_, k) return bind_heli.heli_binder[k] end })
end
local function hit_heli(binder, enemy_id, health)
	binder.object.health = health
	return bind_heli.heli_binder.on_hit(binder, 1, 1, 1, enemy_id)
end
local function boxes()
	local n = 0
	for _, c in ipairs(CREATED) do if c.sec == "blackbox_mlr" then n = n + 1 end end
	return n
end

local function test_who(role)
	section(role.label .. ": who", function()
		local C = coop_credit
		local c, p = C.who(0)
		if role.set == "srv_world" or role.set == "srv_map" and not role.mirror then
			check(c == nil, role.label .. ": who(own actor) is nobody (a ghost)")
		elseif role.set == "none" then
			check(c == 0 and p == 0, role.label .. ": who(actor) is character 0, peer 0")
		else
			check(c == 0 and p == role.self, role.label .. ": who(own actor) is character 0 and this machine's peer")
		end
		if role.set ~= "none" then
			local other = role.mirror and 501 or 500
			local want = role.mirror and 2 or 1
			c, p = C.who(OBJ[other])
			check(c == other and p == want, role.label .. ": who(a player's character object) -> its id and peer")
			c, p = C.who(other)
			check(c == other and p == want, role.label .. ": who(id) of a player's character")
			c, p = C.who({ id = other })
			check(c == other and p == want, role.label .. ": who(server object) reads its id field")
		else
			check(C.who(500) == nil, role.label .. ": no session: only the actor is a player")
		end
		check(C.who(W.npc) == nil and C.who(777) == nil, role.label .. ": an NPC is nobody's character")
		check(C.who(nil) == nil and C.who(-1) == nil and C.who(1.5) == nil and C.who(0 / 0) == nil and C.who(70000) == nil
			and C.who("500") == nil and C.who({}) == nil, role.label .. ": invalid ids are nobody")
	end)
end

local function test_once(role)
	section(role.label .. ": once", function()
		local C = coop_credit
		check(C.once(800, "kill") == true and C.once(800, "kill") == false, role.label .. ": once: true the first time only")
		check(C.once(W.dog, "kill") == false, role.label .. ": once: an object and its id are one key")
		check(C.once(800, "box") == true, role.label .. ": once: another kind of the same victim is its own event")
		check(C.once("task:esc_1") == true and C.once("task:esc_1") == false, role.label .. ": once: a string key")
		check(C.once(nil) == false and C.once(0 / 0, "k") == false and C.once(-3, "k") == false and C.once({}, "k") == false
			and C.once(801, 5) == false and C.once(string.rep("x", 200)) == false,
			role.label .. ": once: an invalid key credits nothing")
		check(C.once(802, "t", 1000) == true, role.label .. ": once with a ttl")
		NOW = NOW + 999
		check(C.once(802, "t", 1000) == false, role.label .. ": once: still guarded before the ttl")
		NOW = NOW + 2
		check(C.once(802, "t", 1000) == true, role.label .. ": once: an id is free again after the ttl (released ids come back)")
		for i = 1, 1100 do C.once(10000 + i, "bound") end
		check(C.once(10001, "bound") == true, role.label .. ": once: the ledger is bounded, the oldest key goes first")
		check(C.once(11100, "bound") == false, role.label .. ": once: the newest keys stay")
	end)
end

local function test_owner(role)
	section(role.label .. ": to_owner / on_owner", function()
		local C = coop_credit
		if role.set == "none" then
			check(C.to_owner(0, "g9t", { a = 1 }) == false and #SENT == 0, role.label .. ": to_owner sends nothing without a session")
			return
		end
		if role.mirror then
			local got = {}
			check(C.on_owner("g9t", function(t, from) got[#got + 1] = { t = t, from = from } end) == true,
				role.label .. ": on_owner registers")
			coop_main.on_event("mods.g9t", coop_main.encode({ a = 5 }), 0)
			check(#got == 1 and got[1].t.a == 5 and got[1].from == 0, role.label .. ": on_owner: the world's message arrives")
			coop_main.on_event("mods.g9t", coop_main.encode({ a = 6 }), 2)
			check(#got == 1, role.label .. ": on_owner: another player's message is refused")
			check(C.on_owner("bad verb!", function() end) == false and C.on_owner("g9u", nil) == false,
				role.label .. ": on_owner refuses a bad verb or handler")
			local before = #SENT
			check(C.to_owner(0, "g9t", { a = 7 }) == false and #SENT == before and C.held_count() == 0,
				role.label .. ": a player's machine sends nothing to itself (and holds nothing)")
			return
		end
		local before = #SENT
		check(C.to_owner(500, "g9t", { a = 1 }) == true, role.label .. ": to_owner a player's character")
		local s = SENT[#SENT]
		check(#SENT == before + 1 and s.name == "mods.g9t" and s.target == 1 and coop_main.decode(s.payload).a == 1,
			role.label .. ": to_owner goes to his peer as mods.<verb>")
		if role.set == "hostplay" then
			check(C.to_owner(0, "g9t", { a = 2 }) == true and SENT[#SENT].target == 0,
				role.label .. ": the host's own player: to peer 0 (the engine hands it back to this Lua)")
			local got = {}
			C.on_owner("g9h", function(t, from) got[#got + 1] = from end)
			coop_main.on_event("mods.g9h", coop_main.encode({ a = 1 }), 0)
			check(#got == 1 and got[1] == 0, role.label .. ": on_owner runs on the host's process for its own player")
		else
			check(C.to_owner(0, "g9t", { a = 2 }) == false, role.label .. ": a ghost has no owner")
		end
		-- away: no peer for the character yet; he comes, the message follows on the next update
		before = #SENT
		check(C.to_owner(600, "g9t", { a = 3 }) == true and #SENT == before, role.label .. ": an absent player's message is held")
		W.seats[#W.seats + 1] = { id = 3, avatar = 600 }
		coop_npc_players.invalidate()
		NOW = NOW + 1500
		SendScriptCallback("actor_on_update")
		s = SENT[#SENT]
		check(#SENT == before + 1 and s.target == 3 and coop_main.decode(s.payload).a == 3,
			role.label .. ": a held message goes out when he is back")
		-- joining: held until the facade says he is in the world
		modes.install(coop_mode, role.set, { where = function(peer) return peer == 1 and "joining" or "here" end })
		before = #SENT
		check(C.to_owner(500, "g9t", { a = 4 }) == true and #SENT == before, role.label .. ": a joining player's message is held")
		modes.install(coop_mode, role.set, role.over)
		NOW = NOW + 1500
		SendScriptCallback("actor_on_update")
		check(#SENT == before + 1 and SENT[#SENT].target == 1, role.label .. ": ... and sent once he is in the world")
		-- dropped after the timeout, bounded per character
		before = #SENT
		for i = 1, 40 do C.to_owner(700, "g9t", { a = i }) end
		check(C.held_count(700) == 32, role.label .. ": at most 32 messages wait for one character")
		NOW = NOW + 600001
		SendScriptCallback("actor_on_update")
		W.seats[#W.seats + 1] = { id = 4, avatar = 700 }
		coop_npc_players.invalidate()
		NOW = NOW + 1500
		SendScriptCallback("actor_on_update")
		check(#SENT == before and C.held_count(700) == 0, role.label .. ": held messages are dropped after the timeout")
		check(C.to_owner(-1, "g9t", {}) == false and C.to_owner(1.5, "g9t", {}) == false and C.to_owner(70000, "g9t", {}) == false
			and C.to_owner("500", "g9t", {}) == false and C.to_owner(500, "bad verb", {}) == false
			and C.to_owner(500, "g9t", "x") == false and C.to_owner(500, "g9t", { s = string.rep("x", 16000) }) == false,
			role.label .. ": to_owner refuses invalid ids, verbs, payloads and a payload over one event")
	end)
end

-------------------------------------------------------------------------------
-- u01:1 a mutant's death: exactly one killed_monsters credit per kill
-------------------------------------------------------------------------------
local function test_monster(role)
	section(role.label .. ": u01 mutant death", function()
		if role.set == "srv_world" then return end -- the world server has no player's map: no mutant dies there
		if role.mirror then
			-- the engine mirrors the death: the killer is this machine's own player (his proxy is the actor here)
			kill_mutant(W.actor)
			check((COUNTS["self:killed_monsters"] or 0) == 0,
				role.label .. ": u01: the mirror of my own kill counts nothing (the decider's credit reaches me): one credit in all")
			check(MONSTER_DEATHS == 1 and ISSUED == 0, role.label .. ": u01: the rest of the stock death handler still runs ("
				.. tostring(MONSTER_DEATHS) .. " death callbacks, " .. tostring(ISSUED) .. " logic events)")
			kill_mutant(W.p501)
			check((COUNTS["npc501:killed_monsters"] or 0) == 0, role.label .. ": u01: another player's kill is not counted on a mirror")
			kill_mutant(W.npc)
			check((COUNTS["npc777:killed_monsters"] or 0) == 0, role.label .. ": u01: an NPC's kill is the decider's statistic")
			local inc, inc_npc = game_statistics.increment_statistic, game_statistics.increment_npc_statistic
			W.fail_issue = true
			local binder = binder_of(W.dog)
			binder.st.mob_death = {}
			local ok = pcall(bind_monster.generic_object_binder.death_callback, binder, W.dog, W.actor)
			W.fail_issue = false
			check(not ok and game_statistics.increment_statistic == inc and game_statistics.increment_npc_statistic == inc_npc,
				role.label .. ": u01: a failing handler still restores the statistic functions")
			return
		end
		if role.set == "none" then
			kill_mutant(W.actor)
			kill_mutant(W.npc)
			check(COUNTS["self:killed_monsters"] == 1 and COUNTS["npc777:killed_monsters"] == 1,
				role.label .. ": u01: single player counts as the stock does")
			return
		end
		-- a decider: the co-op host, a map server
		kill_mutant(W.p500)
		check(COUNTS["500:killed_monsters"] == 1 and not COUNTS["self:killed_monsters"] and not COUNTS["npc500:killed_monsters"],
			role.label .. ": u01: a player's kill is credited once, to his character")
		kill_mutant(W.npc)
		check(COUNTS["npc777:killed_monsters"] == 1, role.label .. ": u01: an NPC's kill stays its own statistic")
		if role.set == "hostplay" then
			kill_mutant(W.actor)
			check(COUNTS["self:killed_monsters"] == 1, role.label .. ": u01: the host's own kill counts once, as before")
		end
		check(MONSTER_DEATHS >= 2, role.label .. ": u01: the stock death handler runs whole on the decider")
	end)
end

-------------------------------------------------------------------------------
-- s34:1 the helicopter's black box
-------------------------------------------------------------------------------
local function test_heli(role)
	section(role.label .. ": s34 heli box", function()
		if role.set == "srv_world" then return end -- no helicopter flies on the world server
		if role.mirror then
			local h = new_heli()
			hit_heli(h, 0, 0) -- this machine's own player brings it down; the decider drops the box
			check(boxes() == 0, role.label .. ": s34: a mirror creates no box (it is the decider's world object)")
			check(not COUNTS["self:helicopters_downed"], role.label .. ": s34: a mirror counts no award (as before)")
			return
		end
		if role.set == "none" then
			local h = new_heli()
			hit_heli(h, 0, 0)
			hit_heli(h, 0, 0)
			check(boxes() == 2 and COUNTS["self:helicopters_downed"] == 2, role.label .. ": s34: single player is the stock (a box per lethal hit)")
			return
		end
		local h = new_heli()
		hit_heli(h, 500, 0.5)
		check(boxes() == 0, role.label .. ": s34: no box before the lethal hit")
		hit_heli(h, 500, 0)
		check(boxes() == 1, role.label .. ": s34: a player's lethal hit drops the box")
		check(COUNTS["500:helicopters_downed"] == 1, role.label .. ": s34: the award still goes to that player")
		hit_heli(h, 501, 0)
		hit_heli(h, 500, 0)
		check(boxes() == 1, role.label .. ": s34: once per helicopter, whoever hits the wreck again")
		local n = new_heli()
		hit_heli(n, 777, 0)
		check(boxes() == 1, role.label .. ": s34: an NPC's lethal hit drops nothing (stock)")
		if role.set == "hostplay" then
			local own = new_heli()
			hit_heli(own, 0, 0)
			hit_heli(own, 500, 0)
			hit_heli(own, 0, 0)
			check(boxes() == 2, role.label .. ": s34: the host's own drop and a player's share one guard")
		end
		local box = CREATED[#CREATED]
		check(box and box.sec == "blackbox_mlr" and box.parent == nil, role.label .. ": s34: the stock box, on the ground")
	end)
end

-------------------------------------------------------------------------------
for _, set in ipairs(modes.names()) do
	print("== set " .. set)
	for _, role in ipairs(ROLES[set]) do
		print("-- " .. role.label)
		fresh(role); test_who(role)
		fresh(role); test_once(role)
		fresh(role); test_owner(role)
		fresh(role); test_monster(role)
		fresh(role); test_heli(role)
		if set == "hostplay" and not role.mirror then
			-- a step of G9-1 that fails at game start is logged and does not stop coop_reputation's statistic redirect
			fresh(role, { broken_monster = true })
			section(role.label .. ": failed install step", function()
				game_statistics.increment_npc_statistic(W.p500, "wounded_helped")
				check(COUNTS["500:wounded_helped"] == 1 and log_has("[coop-credit] ! install") ~= nil,
					role.label .. ": a failed install step is logged, the player's statistics still reach him")
			end)
		end
	end
end
TOTAL_PASS, TOTAL_FAIL = TOTAL_PASS + PASSES, TOTAL_FAIL + FAILS
PASSES, FAILS = TOTAL_PASS, TOTAL_FAIL
print(string.format("credit: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("credit FAILED") end
