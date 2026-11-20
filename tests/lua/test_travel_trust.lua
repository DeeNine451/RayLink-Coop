-- TZ v2 section 6.4 row 7 (owner 2026-11-18): a client's "story teleport" (economy.tp without an offer) moves the players
-- around him unasked. The host's check (coop_trust "story_teleport_point", "log" in build 57): the target is one of the
-- points the story scripts teleport to (coop_economy_travel STORY_POINTS) or within a few metres of one. A trip offered to
-- every player (q = 1) is no forced move and is not checked. coop_economy_core / _group / _travel on a host and two
-- clients with stub engines. Run: tools\test_lua.cmd travel_trust
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

-- story points of this level (real names of STORY_POINTS) and a path no story teleport uses
local PATHS = {
	lx8_actor_walk = { x = 100, y = 0, z = 100 },
	oso_actor_walk = { x = -50, y = 2, z = 30 },
	some_npc_walk = { x = 900, y = 0, z = 900 },
}
local HAS_PATHS = true

local function stubs(W)
	W.patrol = function(name)
		local p = PATHS[name]
		return { point = function() return vec(p.x, p.y, p.z) end }
	end
	W.level.patrol_path_exists = function(name)
		if not HAS_PATHS then return false end
		return PATHS[name] ~= nil
	end
	W.coop_npc_companions = { bring_mine = function() end }
end

local function setup(nclients)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = { x = p * 2, y = 0, z = 0 } end
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		stubs(W)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
	end
	local mods = { "coop_trust", "coop_economy_core", "coop_economy_group", "coop_economy_travel" }
	for _, W in pairs(WORLDS) do
		modes.live(load_script(W, "coop_mode"), function(name) return load_script(W, name) end)
		for _, n in ipairs(mods) do load_script(W, n) end
		for _, n in ipairs(mods) do
			if W[n].on_game_start then W[n].on_game_start() end
		end
	end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

local function trust_lines(W)
	local n = 0
	for _, l in ipairs(W.LOG) do
		if l:find("[coop-trust] ! story_teleport_point:", 1, true) then n = n + 1 end
	end
	return n
end
local function last_line(W)
	for i = #W.LOG, 1, -1 do
		if W.LOG[i]:find("[coop-trust] ! story_teleport_point:", 1, true) then return W.LOG[i] end
	end
	return ""
end
local function checked(W)
	local c = W.coop_trust.status().story_teleport_point
	return c and c.checked or 0
end
-- anna (peer 1) says she was teleported from where she stands to `dest`
local function tp_from_anna(A, dest, extra)
	local t = { x = dest.x, y = dest.y, z = dest.z, ox = POS[1].x, oy = POS[1].y, oz = POS[1].z, r = 50, l = LEVEL, k = "story", n = "anna" }
	for k, v in pairs(extra or {}) do t[k] = v end
	A.coop_economy_core.send("tp", t, 0)
	deliver_all()
end

-------------------------------------------------------------------------------
section("story teleport to a point the story uses")
do
	local H, A, B = setup(2)
	POS[1] = { x = 100, y = 0, z = 100 } -- her own teleport put her there already
	tp_from_anna(A, PATHS.lx8_actor_walk)
	check(checked(H) == 1 and trust_lines(H) == 0, "the lx8 lift's point: the check holds")
	check(math.abs(POS[0].x - 100) > 1, "(the host stood far from her start: he stays)")
	POS[1] = { x = -50, y = 2, z = 33 }
	tp_from_anna(A, { x = -50, y = 2, z = 33 }) -- read from her position a moment later: a few metres off the point
	check(trust_lines(H) == 0, "3 m from the Osoznanie room's point: the check holds")
end

section("story teleport to a point no story teleport uses")
do
	local H, A, B = setup(2)
	POS[1] = { x = 0, y = 0, z = 0 }
	POS[0] = { x = 3, y = 0, z = 0 }
	tp_from_anna(A, PATHS.some_npc_walk)
	check(trust_lines(H) == 1, "a forced move to an NPC's walk: logged")
	local line = last_line(H)
	check(line:find("anna", 1, true) and line:find("900", 1, true) and line:find("would be refused", 1, true),
		"the line names the player, the point and the mode")
	check(math.abs(POS[0].x - 900) < 2, "log mode: the host near her still follows as before")
	POS[2] = { x = 1, y = 0, z = 0 }
	tp_from_anna(A, { x = 4000, y = 0, z = -4000 })
	check(trust_lines(H) == 2, "a point in the middle of nowhere: logged")
end

section("refuse mode")
do
	local H, A = setup(1)
	H.coop_trust.reset_for_test({ default = "log", story_teleport_point = "refuse" })
	POS[1] = { x = 0, y = 0, z = 0 }
	POS[0] = { x = 3, y = 0, z = 0 }
	tp_from_anna(A, PATHS.some_npc_walk)
	check(math.abs(POS[0].x - 3) < 0.01, "refuse: the host does not move")
	check(#H.SENT == 0, "refuse: nobody else is told")
end

section("what is not checked here")
do
	local H, A = setup(1)
	POS[1] = { x = 0, y = 0, z = 0 }
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0 })
	check(checked(H) == 0, "a trip offered to everybody (q = 1) is no forced move: not checked")
	tp_from_anna(A, PATHS.some_npc_walk, { l = "l02" })
	check(checked(H) == 1 and trust_lines(H) == 0, "a teleport of another level than the host's: not known here, ok")
	HAS_PATHS = false
	tp_from_anna(A, PATHS.some_npc_walk)
	check(trust_lines(H) == 0, "no story point can be read here (a world server without the level): ok")
	HAS_PATHS = true
end

-------------------------------------------------------------------------------
-- Round 2 (F7): an honest client never sends a forced move while the NPC group routes the story teleports, and in Server mode a
-- move named for another level than the one the engine has the player on is a lie.
-------------------------------------------------------------------------------
local function lines_of(W, name)
	local n = 0
	for _, l in ipairs(W.LOG) do
		if l:find("[coop-trust] ! " .. name .. ":", 1, true) then n = n + 1 end
	end
	return n
end

section("the NPC group routes the story teleports: a client's forced move is no honest one")
do
	local H, A = setup(1)
	H.coop_npc_logic = { deliver = function() return nil end, is_replicated = function() return false end }
	POS[1] = { x = 100, y = 0, z = 100 }
	POS[0] = { x = 130, y = 0, z = 100 }
	tp_from_anna(A, PATHS.lx8_actor_walk)
	check(trust_lines(H) == 1 and last_line(H):find("NPC group", 1, true),
		"even to a story point: logged, the line says why (routed by the NPC group)")
	check(math.abs(POS[0].x - 100) < 2, "log mode: the host 30 m from her still follows as before")
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0 })
	check(trust_lines(H) == 1 and checked(H) == 1, "a trip offered to everybody is still no forced move")
	H.coop_npc_logic = nil
	POS[1] = { x = 100, y = 0, z = 100 }
	tp_from_anna(A, PATHS.lx8_actor_walk)
	check(trust_lines(H) == 1, "an install without coop_npc_logic: the story points decide as before")
end

-- The session's list of the players (coop.players) says where each one stands: `level` (the engine gives a game graph id; a
-- name here, so no ALife is needed). where = nil: the list says nothing of levels.
local function set_levels(H, where)
	local base = H.coop._players_base or H.coop.players
	H.coop._players_base = base
	H.coop.players = function()
		local out = base()
		for _, e in ipairs(out) do e.level = where and where[e.id] or nil end
		return out
	end
end

section("Server mode: the level of the move is the level the engine has her on")
do
	local H, A = setup(1)
	set_levels(H, { [0] = LEVEL, [1] = "l02_garbage" })
	POS[1] = { x = 100, y = 0, z = 100 }
	tp_from_anna(A, PATHS.lx8_actor_walk) -- names the host's level l01
	check(trust_lines(H) == 1 and last_line(H):find("l02_garbage", 1, true),
		"a forced move named for l01 while she stands on l02: logged, the line names her level")
	tp_from_anna(A, PATHS.some_npc_walk, { l = "l02_garbage" })
	check(trust_lines(H) == 1, "a forced move on her own level, which this process cannot read: ok")
	-- offers: the yes / no window opens for the players of the level the move names
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0 })
	check(lines_of(H, "travel_offer_level") == 1, "a trip offered on l01 while she stands on l02: logged (travel_offer_level)")
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0, l = "l02_garbage" })
	check(lines_of(H, "travel_offer_level") == 1 and (H.coop_trust.status().travel_offer_level or {}).checked == 2,
		"a trip offered on her own level: holds")
	set_levels(H, nil)
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0 })
	check(lines_of(H, "travel_offer_level") == 1, "her level not known here: no refusal for lack of knowledge")
	-- Co-op: one level for everybody, the engine lists the host's level for each player
	set_levels(H, { [0] = LEVEL, [1] = LEVEL })
	tp_from_anna(A, PATHS.some_npc_walk, { q = 1, r = 0 })
	check(lines_of(H, "travel_offer_level") == 1, "Co-op: an offer on the one level holds")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
