-- F4 G18-3 (s38:3, s38:6): the stock bounty squads (sim_squad_bounty.script of Anomaly 1.5.3; G.A.M.M.A.'s two providers
-- of the file are off in the profile, so the stock copy runs) per character in a session.
--   s38:3  rank, reputation, the cooldown, the squads and the target are each player's, not db.actor's (the co-op host's
--          character or the world server's ghost); the faction is coop_faction.faction_of_character's; a squad sent at
--          "the actor" goes for its own character (sim_squad_scripted:get_current_task), also on a map server.
--   s38:6  a squad never appears within the stock's spawn_distance (200 m) of any player on the chosen smart's map; on a
--          world server the map is chosen from the target's record, never from the ghost at fake_start.
-- Runs once per answer set (COOP_LUA_MODE): hostplay = the co-op host (and a co-op client's mirror), srv_world = the world
-- server (players on one map, then on two maps), srv_map = a map server, none = single player (the stock as it is).
-- The stock body is the real file (../anomaly-ref/unpacked or temp/stock_scripts), never the live game.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

load_script("coop_main")
for _, n in ipairs(MODE_FILES) do load_script(n) end
load_script("coop_mods_core")
for _, n in ipairs(MODE_FILES) do _G[n].on_game_start() end

local ADAPTER = "coop_bounty"
local EVENT = "mods.bounty_t"
local REQUEST = "mods.bounty_req"
local BRIDGE = 0x101
local DAY = 60 * 60 * 24

local function snapshot(g, entries)
	entries.g, entries.i, entries.k = g, 1, 1
	return coop_main.encode(entries)
end

-------------------------------------------------------------------------------
-- The stock script, read from a corpus copy
-------------------------------------------------------------------------------
local STOCK_PATHS = { "../anomaly-ref/unpacked/scripts/sim_squad_bounty.script", "temp/stock_scripts/scripts/sim_squad_bounty.script" }
local STOCK_SRC
for _, p in ipairs(STOCK_PATHS) do
	local fh = io.open(p, "rb")
	if fh then
		STOCK_SRC = fh:read("*a")
		fh:close()
		break
	end
end
assert(STOCK_SRC, "stock copy of sim_squad_bounty.script missing (" .. table.concat(STOCK_PATHS, ", ") .. ")")

local function load_stock()
	local this = setmetatable({}, { __index = _G })
	rawset(_G, "sim_squad_bounty", this)
	local f = assert(loadstring(STOCK_SRC, "@sim_squad_bounty.script"))
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

-------------------------------------------------------------------------------
-- The world the stock reads
-------------------------------------------------------------------------------
printdbg = function() end
AddScriptCallback("on_game_load")
AddScriptCallback("server_entity_on_unregister")
-- every boot starts with the callbacks of the facade only: what the stock and the adapter registered goes at the next boot
local REG = {}
local base_register = RegisterScriptCallback
RegisterScriptCallback = function(n, f)
	REG[#REG + 1] = { n, f }
	return base_register(n, f)
end
local function clear_callbacks()
	for _, r in ipairs(REG) do UnregisterScriptCallback(r[1], r[2]) end
	REG = {}
end
local DEFAULT_PLAYERS, DEFAULT_PEER_OF = coop.players, coop.peer_of_avatar

-- game time: a CTime is { s = seconds }
GAME_T = 1000000
local CT = {}
CT.__index = CT
function CT:diffSec(o) return self.s - o.s end
local function ctime(s) return setmetatable({ s = s }, CT) end
game.get_game_time = function() return ctime(GAME_T) end
utils_data = {
	CTime_to_table = function(t) return { s = t.s } end,
	CTime_from_table = function(t) return ctime(t.s) end,
}

-- plugins\bounty_squad.ltx (the stock's sections, trimmed)
local BOUNTY_INI = {
	faction_list = { "stalker", "dolg", "freedom", "bandit" },
	safe_levels = { "fake_start" },
	safe_smarts = {},
	faction_bounty_squads = { { "stalker", "stalker_sim_squad_alpha" }, { "dolg", "dolg_sim_squad_alpha" },
		{ "freedom", "freedom_sim_squad_alpha" }, { "bandit", "bandit_sim_squad_alpha" } },
	danger_ranks = { { "novice", "0" }, { "veteran", "1" } },
	danger_reputations = { { "neutral", "0" }, { "terrible", "1" } },
}
local base_ini_file = ini_file
ini_file = function(name)
	if name ~= "plugins\\bounty_squad.ltx" then return base_ini_file(name) end
	local o = {}
	function o:line_count(s) return #(BOUNTY_INI[s] or {}) end
	function o:r_line_ex(s, i)
		local row = BOUNTY_INI[s][i + 1]
		if type(row) == "table" then return true, row[1], row[2] end
		return true, row, ""
	end
	return o
end

RANK, REP = {}, {} -- character id -> rank / reputation number
ranks = { get_obj_rank_name = function(o)
	local r = o.character_rank and o:character_rank() or o.rank and o:rank()
	if type(r) ~= "number" then return "" end
	return r >= 5000 and "veteran" or "novice"
end }
utils_obj = { get_reputation_name = function(v) return type(v) == "number" and v <= -1000 and "terrible" or "neutral" end }
local ENEMIES = {
	bandit = { actor_stalker = true, actor_dolg = true, actor_freedom = true },
	dolg = { actor_freedom = true },
	freedom = { actor_dolg = true },
	stalker = { actor_bandit = true },
}
game_relations = { is_factions_enemies = function(f, to) return ENEMIES[f] ~= nil and ENEMIES[f][to] == true end }
FACTION_OF = {} -- character id -> faction (coop_faction.faction_of_character, the world's decider)
coop_faction = { faction_of_character = function(id) return FACTION_OF[id] end }

-- maps: game vertex -> level; level 1 and 2 are linked, fake_start (9) is linked to nothing
LEVEL_OF = { [10] = 1, [11] = 1, [12] = 1, [13] = 1, [20] = 2, [21] = 2, [22] = 2, [90] = 9 }
local LEVEL_NAME = { [1] = "l01_escape", [2] = "l02_garbage", [9] = "fake_start" }
local LINKED = { [1] = { [2] = true }, [2] = { [1] = true } }
function game_graph()
	return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF[gv] end } end }
end
simulation_objects = {
	is_on_the_same_level = function(a, b)
		return a ~= nil and b ~= nil and LEVEL_OF[a.m_game_vertex_id] == LEVEL_OF[b.m_game_vertex_id]
	end,
	is_on_the_linked_level = function(a, b)
		if not (a and b) then return false end
		local la, lb = LEVEL_OF[a.m_game_vertex_id], LEVEL_OF[b.m_game_vertex_id]
		return LINKED[la] ~= nil and LINKED[la][lb] == true
	end,
}
CALifeSmartTerrainTask = function(gvid, lvid) return { gvid = gvid, lvid = lvid } end

-- sim_squad_scripted (the stock's methods this needs): get_current_task at "the actor" is the se_actor's task
local CLS
local function fresh_squad_class()
	CLS = {}
	function CLS:get_current_task()
		if self.assigned_target_id == 0 then
			local a = alife():actor()
			return CALifeSmartTerrainTask(a.m_game_vertex_id, a.m_level_vertex_id)
		end
		return CALifeSmartTerrainTask(self.m_game_vertex_id, self.m_level_vertex_id)
	end
	function CLS:get_script_target() return self.scripted_target end
	function CLS:section_name() return self._sec end
	sim_squad_scripted = { sim_squad_scripted = CLS }
end
local SQ_MT = { __index = function(_, k) return CLS[k] end }

SPAWNED = {} -- { id, section, smart }
local function create_squad(smart, section)
	local id = NEXT_ID
	NEXT_ID = NEXT_ID + 1
	local sq = setmetatable({ id = id, _sec = section, position = vector():set(smart.position),
		m_game_vertex_id = smart.m_game_vertex_id, m_level_vertex_id = 1, _smart = smart.name }, SQ_MT)
	SE[id] = sq
	SPAWNED[#SPAWNED + 1] = { id = id, section = section, smart = smart.name }
	return sq
end
sim_board = { get_sim_board = function() return { create_squad = function(_, smart, section) return create_squad(smart, section) end } end }

local SMARTS = {
	s_near_host = { 30, 0, 0, 10 }, s_near_client = { 420, 0, 0, 11 }, s_far = { 220, 0, 1000, 13 },
	s_fake = { 0, 0, 0, 90 }, s_fake_far = { 300, 0, 0, 90 },
	s_l2_near_b = { 1010, 0, 0, 21 }, s_l2_far = { 0, 0, 3000, 22 },
}
local function board(names)
	SIMBOARD = { smarts_by_names = {}, smarts = {} }
	local id = 3000
	for _, name in ipairs(names) do
		local s = SMARTS[name]
		id = id + 1
		SIMBOARD.smarts_by_names[name] = { id = id, name = name, position = vec3(s[1], s[2], s[3]), m_game_vertex_id = s[4] }
		SIMBOARD.smarts[id] = { squads = {} }
	end
end
local function smart_pos(name) local s = SMARTS[name] return vec3(s[1], s[2], s[3]) end

-------------------------------------------------------------------------------
-- Boot: a fresh world for one set
-------------------------------------------------------------------------------
local SET
local CHAR -- character id -> { pos, gv, lv, online }
local ORIG_SPAWN
-- math.random: a test picks the k-th candidate (clamped)
local PICK = 1
math.random = function(n) if n == nil then return 0.5 end return math.min(PICK, n) end

local function character(id, x, z, gv, lv, online, community)
	local se, o = spawn("coop_player_avatar", vec3(x, 0, z), nil, { id = id, offline = not online })
	se.m_game_vertex_id, se.m_level_vertex_id = gv, lv
	se.rank = function() return RANK[id] end
	se.reputation = function() return REP[id] end
	se.community = function() return community end
	se.clsid = function() return 1 end
	if o then
		o.game_vertex_id = function() return gv end
		o.level_vertex_id = function() return lv end
		o.character_rank = function() return RANK[id] end
		o.character_reputation = function() return REP[id] end
		o.character_community = function() return community end
		o.clsid = function() return 1 end
		o._kind = "stalker"
	end
	CHAR[id] = { pos = vec3(x, 0, z), gv = gv, lv = lv }
	return se, o
end

-- opts: set, mode (stub MODE), players (rows of coop.players), overrides (answers), keep (keep SE / OBJ), map (map server)
local function boot(opts)
	SET = opts.set
	MODE = opts.mode or "host"
	SELF = MODE == "client" and 1 or 0
	if not opts.keep then
		SE, OBJ, NEXT_ID, CHAR, SPAWNED = {}, {}, 1000, {}, {}
		RANK, REP, FACTION_OF = {}, {}, {}
		db = { storage = {} }
	end
	SENT, TIMEEV = {}, {}
	PICK = 1
	clear_callbacks()
	load_script("coop_main") -- a new world has a new event bus as well as new script callbacks
	coop.is_client = function() return MODE == "client" or opts.map == true end
	coop.is_map_server = function() return opts.map == true end
	coop.is_dedicated = function() return SET == "srv_world" end
	coop.players = DEFAULT_PLAYERS
	coop.peer_of_avatar = DEFAULT_PEER_OF
	if opts.players then coop.players = function() return opts.players end end
	if opts.peer_of_avatar then coop.peer_of_avatar = opts.peer_of_avatar end
	modes.install(coop_mode, opts.answers or SET, opts.overrides)
	alife = function()
		return {
			actor = function() return SE[0] end,
			object = function(_, id) return SE[id] end,
			release = function(_, se) release_id(se.id) end,
			level_name = function(_, lid) return LEVEL_NAME[lid] end,
		}
	end
	fresh_squad_class()
end

-- the stock and the adapter, started in axr_main's order (coop_bounty before sim_squad_bounty), then the game's load
local function start(m_data)
	local adapter = load_adapter()
	load_stock()
	ORIG_SPAWN = sim_squad_bounty.spawn_timer
	if adapter then adapter.on_game_start() end
	sim_squad_bounty.on_game_start()
	if m_data then SendScriptCallback("load_state", m_data) end
	SendScriptCallback("on_game_load")
	return adapter
end

local function spawn_tick()
	local e = TIMEEV["cycle:bounty_squad_spawn"]
	assert(e, "the stock's spawn timer was not created")
	return e.f(unpack(e.p))
end

local function target(id)
	local a = rawget(_G, ADAPTER)
	if not (a and a.target_of) then return nil end
	return a.target_of(id)
end

-- every squad made is farther than 200 m from every player character on its smart's map
local function none_near(tag)
	for _, s in ipairs(SPAWNED) do
		local sp = smart_pos(s.smart)
		local slid = LEVEL_OF[SMARTS[s.smart][4]]
		for id, c in pairs(CHAR) do
			if LEVEL_OF[c.gv] == slid then
				local d = sp:distance_to(c.pos)
				check(d > 200, string.format("%s: squad %s at %s is %.0f m from character %d (> 200)", tag, s.section, s.smart, d, id))
			end
		end
	end
end

local function squads_of_char(id)
	local n = 0
	for _, s in ipairs(SPAWNED) do if target(s.id) == id then n = n + 1 end end
	return n
end

-------------------------------------------------------------------------------
-- Co-op (hostplay): the host's process decides; its character is 0, the client's character is the proxy 500 (peer 1)
-------------------------------------------------------------------------------
local function coop_world()
	boot({ set = "hostplay" })
	make_actor(vec3(0, 0, 0))
	SE[0].m_game_vertex_id, SE[0].m_level_vertex_id = 10, 100
	db.actor.game_vertex_id = function() return 10 end
	db.actor.level_vertex_id = function() return 100 end
	db.actor.character_rank = function() return RANK[0] end
	db.actor.character_reputation = function() return REP[0] end
	db.actor.character_community = function() return "actor_stalker" end
	CHAR[0] = { pos = vec3(0, 0, 0), gv = 10, lv = 100 }
	character(500, 400, 0, 11, 111, true, "actor_stalker")
	FACTION_OF[0], FACTION_OF[500] = "stalker", "stalker"
	board({ "s_near_host", "s_near_client", "s_far", "s_fake" })
end

local function coop_tests()
	print("== co-op host")
	-- s38:3: a veteran client with a novice host has his own bounty; the host has none
	coop_world()
	RANK[0], REP[0] = 100, 0
	RANK[500], REP[500] = 6000, 0
	start()
	spawn_tick() -- his cooldown starts
	check(#SPAWNED == 0, "s38:3 co-op: no squad before the client's cooldown ran out (" .. #SPAWNED .. ")")
	GAME_T = GAME_T + DAY + 1
	spawn_tick()
	check(#SPAWNED == 1, "s38:3 co-op: a veteran client with a novice host gets one bounty squad (" .. #SPAWNED .. ")")
	local sq = SPAWNED[1] and SE[SPAWNED[1].id]
	check(sq ~= nil and sq.scripted_target == "actor" and sq.rush_to_target == true,
		"s38:3 co-op: the squad is sent at the actor with a rush, as the stock does")
	check(sq ~= nil and target(sq.id) == 500, "s38:3 co-op: its target is the client's character 500 (" .. tostring(sq and target(sq.id)) .. ")")
	local cid, peer = nil, nil
	if sq and rawget(_G, ADAPTER) then cid, peer = coop_bounty.target_of(sq.id) end
	check(peer == 1, "s38:3 co-op: target_of names his peer 1 (" .. tostring(peer) .. ")")
	check(SPAWNED[1] ~= nil and SPAWNED[1].section == "bandit_sim_squad_alpha",
		"s38:3 co-op: the faction is an enemy of his faction (" .. tostring(SPAWNED[1] and SPAWNED[1].section) .. ")")
	-- the squad goes for him, not for the host's actor
	if sq then
		sq.assigned_target_id = 0
		local t = sq:get_current_task()
		check(t.gvid == 11 and t.lvid == 111, "s38:3 co-op: the client's squad goes to the client (" .. t.gvid .. "/" .. t.lvid .. ")")
	end
	-- the stock table keeps it (dynamic_news_manager's gossip, the stock state timer)
	check(sq ~= nil and sim_squad_bounty.get_active_squads()[sq.id] == "bandit_sim_squad_alpha",
		"s38:3 co-op: the squad is in the stock's active_squads")
	-- the decider published the target (host numbering)
	local t = sent(EVENT)
	check(t ~= nil and tonumber(t.n) == 1 and tonumber(t.s1) == (sq and sq.id) and tonumber(t.c1) == 500,
		"s38:3 co-op: the target goes out as " .. EVENT)
	local before = sent_count(EVENT)
	NOW = NOW + 31000
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) == before + 1, "co-op: the targets go out again after 30 s (a late joiner, a new map server)")
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) == before + 1, "co-op: not at every update")

	-- separate cooldowns: the host turns veteran a day later; his cooldown starts then, not at the client's spawn
	GAME_T = GAME_T + 3600
	RANK[0] = 6000
	spawn_tick()
	check(#SPAWNED == 1, "s38:3 co-op: the host's cooldown starts when he turns veteran (" .. #SPAWNED .. ")")
	GAME_T = GAME_T + DAY - 60
	spawn_tick()
	check(#SPAWNED == 1, "s38:3 co-op: a minute before the host's day nothing; the client has his one squad (" .. #SPAWNED .. ")")
	GAME_T = GAME_T + 61
	spawn_tick()
	check(#SPAWNED == 2, "s38:3 co-op: the host gets his own squad a day after his cooldown started (" .. #SPAWNED .. ")")
	local hsq = SPAWNED[2] and SE[SPAWNED[2].id]
	check(hsq ~= nil and target(hsq.id) == 0, "s38:3 co-op: the second squad hunts the host's character 0")
	if hsq then
		hsq.assigned_target_id = 0
		local ht = hsq:get_current_task()
		check(ht.gvid == 10 and ht.lvid == 100, "s38:3 co-op: the host's squad goes to the actor as the stock does")
	end
	none_near("s38:6 co-op")

	-- records survive a save and a load (a new Lua state of the host)
	local m = {}
	SendScriptCallback("save_state", m)
	check(type(m.coop_bounty) == "table", "s38:3 co-op: the records are saved under coop_bounty")
	boot({ set = "hostplay", keep = true })
	start(m)
	check(sq ~= nil and target(sq.id) == 500 and hsq ~= nil and target(hsq.id) == 0, "s38:3 co-op: targets survive the load")
	check(sq ~= nil and sim_squad_bounty.get_active_squads()[sq.id] ~= nil, "s38:3 co-op: the loaded squads are in the stock's table")
	GAME_T = GAME_T + 3 * DAY
	spawn_tick()
	check(#SPAWNED == 2, "s38:3 co-op: each still has his one squad after the load, nothing more (" .. #SPAWNED .. ")")
	-- a squad that is gone leaves the records; its character gets a new one at his next tick
	if sq then release_id(sq.id) end
	spawn_tick()
	check(#SPAWNED == 3 and target(SPAWNED[3].id) == 500, "s38:3 co-op: the client's lost squad is replaced for him")
	none_near("s38:6 co-op after the load")

	-- s38:6: both veterans; whichever candidate the random pick takes, no squad is within 200 m of a player
	for k = 1, 3 do
		coop_world()
		RANK[0], RANK[500] = 6000, 6000
		start()
		PICK = k
		spawn_tick()
		GAME_T = GAME_T + DAY + 1
		spawn_tick()
		check(#SPAWNED >= 1, "s38:6 co-op pick " .. k .. ": a squad was made (" .. #SPAWNED .. ")")
		none_near("s38:6 co-op pick " .. k)
		for _, s in ipairs(SPAWNED) do
			check(s.smart == "s_far", "s38:6 co-op pick " .. k .. ": only the smart far from both players (" .. s.smart .. ")")
		end
	end
	-- no smart far enough from everybody: no squad, the cooldown stays due
	coop_world()
	RANK[500] = 6000
	board({ "s_near_host", "s_near_client" })
	start()
	spawn_tick()
	GAME_T = GAME_T + DAY + 1
	spawn_tick()
	check(#SPAWNED == 0, "s38:6 co-op: no squad when every smart is near a player (" .. #SPAWNED .. ")")
	board({ "s_near_host", "s_near_client", "s_far" })
	spawn_tick()
	check(#SPAWNED == 1 and SPAWNED[1].smart == "s_far", "s38:6 co-op: the squad comes at the next tick once a far smart exists")

	local lost = SPAWNED[1] and SE[SPAWNED[1].id]
	check(lost ~= nil and target(lost.id) == 500, "co-op unregister: the released squad was targeting the client")
	if lost then
		local sid, section = lost.id, lost:section_name()
		alife():release(lost)
		SendScriptCallback("server_entity_on_unregister", lost, "sim")
		local reused = setmetatable({ id = sid, _sec = section, scripted_target = "actor", assigned_target_id = 0 }, SQ_MT)
		SE[sid] = reused
		local task = reused:get_current_task()
		check(task.gvid == 10 and task.lvid == 100, "co-op unregister: reused id gets the stock task (" .. task.gvid .. "/" .. task.lvid .. ")")
		check(target(sid) == nil, "co-op unregister: reused id has no bounty target (" .. tostring(target(sid)) .. ")")
		if rawget(_G, ADAPTER) then
			check(coop_bounty.squads_of(500)[sid] == nil, "co-op unregister: the client's record loses the released squad immediately")
		end
	end
end

-- A co-op client's machine: frozen copies of the squads, the host decides
local function client_tests()
	print("== co-op client")
	boot({ set = "hostplay", mode = "client",
		overrides = { decides_world = function() return false end, leads_here = function() return false end,
			is_player_mirror = function() return true end } })
	make_actor(vec3(400, 0, 0))
	RANK[0] = 6000
	db.actor.character_rank = function() return 6000 end
	db.actor.character_reputation = function() return 0 end
	db.actor.character_community = function() return "actor_stalker" end
	SE[0].m_game_vertex_id = 11
	board({ "s_near_host", "s_far" })
	start()
	-- the router (installed by coop_main at load) keeps the stock's on_game_load ("host") off a client: no timer here
	check(TIMEEV["cycle:bounty_squad_spawn"] == nil, "co-op client: the router keeps the stock's timer off the client")
	-- the timer itself, called where nothing routes it, makes nothing either
	local r1 = sim_squad_bounty.spawn_timer()
	GAME_T = GAME_T + DAY + 1
	local r2 = sim_squad_bounty.spawn_timer()
	check(#SPAWNED == 0, "co-op client: the client makes no bounty squad (" .. #SPAWNED .. ")")
	check(r1 == true and r2 == true, "co-op client: the spawn timer is dropped here, as the router drops a host timer")
	-- the host's word: squad 4000 hunts the client's character (500 in host numbering, 0 here)
	coop_main.on_event(EVENT, snapshot(1, { n = 1, s1 = 4000, c1 = 500 }), 0)
	local cid, peer = nil, nil
	if rawget(_G, ADAPTER) then cid, peer = coop_bounty.target_of(4000) end
	check(cid == 0 and peer == 1, "co-op client: the published target is his own character here (" .. tostring(cid) .. ", " .. tostring(peer) .. ")")
	-- only peer 0 (the host) is listened to; a bad list is dropped whole
	coop_main.on_event(EVENT, snapshot(2, { n = 1, s1 = 4000, c1 = 0 }), 2)
	check(target(4000) == 0, "co-op client: a target list from another peer is ignored")
	coop_main.on_event(EVENT, snapshot(2, { n = 999, s1 = 4000, c1 = 0 }), 0)
	check(target(4000) == 0, "co-op client: a list longer than the limit is dropped")
	coop_main.on_event(EVENT, snapshot(2, { n = 1, s1 = "x", c1 = 0 }), 0)
	check(target(4000) == 0, "co-op client: a list with a bad id is dropped")
end

-------------------------------------------------------------------------------
-- Server (srv_world): the world server decides, has no player's map; its actor is a ghost at fake_start
-------------------------------------------------------------------------------
local SRV_PLAYERS = {
	{ id = 0, nick = "world", is_self = true, avatar_id = 0 },
	{ id = 1, nick = "a", avatar_id = 501 },
	{ id = 2, nick = "b", avatar_id = 502 },
}
local function srv_peer_of(id)
	if id == 501 then return 1 elseif id == 502 then return 2 elseif id == 0 then return 0 end
	return nil
end

local function srv_world(b_gv, b_x, overrides)
	boot({ set = "srv_world", players = SRV_PLAYERS, peer_of_avatar = srv_peer_of, overrides = overrides })
	make_actor(vec3(0, 0, 0)) -- the ghost
	SE[0].m_game_vertex_id, SE[0].m_level_vertex_id = 90, 900
	db.actor.game_vertex_id = function() return 90 end
	db.actor.level_vertex_id = function() return 900 end
	db.actor.character_rank = function() return RANK[0] or 100 end
	db.actor.character_reputation = function() return 0 end
	db.actor.character_community = function() return "actor_stalker" end
	character(501, 400, 0, 11, 111, false, "actor_dolg")
	character(502, b_x, 0, b_gv, 122, false, "actor_freedom")
	FACTION_OF[501], FACTION_OF[502] = "dolg", "freedom"
end

local function request_tests()
	print("== world server, bridge request audit and cooldown")
	local second_bridge = BRIDGE + 1
	for _, trust_mode in ipairs({ "log", "refuse", "off" }) do
		srv_world(12, 0, { from_level = function(from) return from == BRIDGE or from == second_bridge end })
		board({ "s_far" })
		local trust = load_script("coop_trust")
		local audit, bad = trust.pass, {}
		trust.mode_of = function() return trust_mode end
		trust.pass = function(name, ok, fmt, ...)
			if not ok then bad[name] = (bad[name] or 0) + 1 end
			return audit(name, ok, fmt, ...)
		end
		start()
		coop_main.on_event(REQUEST, "", 1)
		coop_main.on_event(REQUEST, "", 0)
		coop_main.on_event(REQUEST, "from=n257", BRIDGE)
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		check(sent_count(EVENT) == 0 and bad.bounty_request_sender == 2 and bad.bounty_request_payload == 1,
			trust_mode .. ": invalid senders and a nonempty payload are audited and refused")
		coop_main.on_event(REQUEST, "", BRIDGE)
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		for _ = 1, 30 do coop_main.on_event(REQUEST, "", BRIDGE) end
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		check(sent_count(EVENT) == 1 and bad.bounty_request_rate == 30,
			trust_mode .. ": a burst on a later update is audited and does not queue another reply")
		coop_main.on_event(REQUEST, "", second_bridge)
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		check(sent_count(EVENT) == 2, trust_mode .. ": the first bridge cannot spend another bridge's cooldown")
		NOW = NOW + 5000
		coop_main.on_event(REQUEST, "", BRIDGE)
		SendScriptCallback("actor_on_update")
		check(sent_count(EVENT) == 3, trust_mode .. ": the bridge can request after its cooldown")
	end
end

local function large_snapshot_tests()
	print("== world server, 65 retained bindings")
	srv_world(12, 0)
	board({ "s_far" })
	local retained = {}
	for sid = 3001, 3064 do retained[sid] = "bandit_sim_squad_alpha" end
	start({ coop_bounty = { c = {
		[650] = { s = retained }, [502] = { s = { [3065] = "bandit_sim_squad_alpha" } },
	} } })
	for round = 1, 2 do
		local before = #SENT
		NOW = NOW + 31000
		SendScriptCallback("actor_on_update")
		local first, second = SENT[before + 1], SENT[before + 2]
		local a = first and coop_main.decode(first.payload) or {}
		local b = second and coop_main.decode(second.payload) or {}
		check(#SENT == before + 2 and first and second and first.name == EVENT and second.name == EVENT
			and a.g ~= nil and a.g == b.g and a.i == 1 and b.i == 2 and a.k == 2 and b.k == 2 and a.n == 64 and b.n == 1,
			"large snapshot " .. round .. ": all 65 bindings use two bounded, numbered chunks in one generation")
		local received = {}
		for _, part in ipairs({ a, b }) do
			for i = 1, part.n or 0 do received[part["s" .. i]] = part["c" .. i] end
		end
		local complete = received[3065] == 502
		for sid = 3001, 3064 do complete = complete and received[sid] == 650 end
		check(complete, "large snapshot " .. round .. ": the connected player's binding and all retained bindings go out")
	end
end

local function server_tests()
	print("== world server, both players on one map")
	srv_world(12, 0)
	RANK[0], RANK[501] = 6000, 6000 -- the veteran ghost also has an eligible smart on fake_start
	REP[502] = -2000 -- a terrible reputation: one squad for him
	board({ "s_near_host", "s_near_client", "s_far", "s_fake", "s_fake_far" }) -- s_near_host is 30 m from b at (0, 0, 0)
	start()
	SendScriptCallback("actor_on_update")
	coop_main.on_event(REQUEST, "", 1)
	coop_main.on_event(REQUEST, "", 0)
	coop_main.on_event(REQUEST, "n=n0", BRIDGE)
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) == 0, "world server: a player, the world seat and a malformed bridge request get no snapshot")
	for _ = 1, 3 do coop_main.on_event(REQUEST, "", BRIDGE) end
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) <= 1, "world server: bridge requests cannot cause a burst of replies")
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	local empty, reply = sent(EVENT)
	check(sent_count(EVENT) == 1 and empty.n == 0 and reply.target == -1,
		"world server: a valid bridge request publishes one authoritative empty snapshot")
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) == 1, "world server: the fulfilled request does not cause another publication")
	spawn_tick()
	GAME_T = GAME_T + DAY + 1
	spawn_tick()
	check(#SPAWNED == 2, "s38:3 server: each player with a bounty gets his own squad, the veteran ghost none (" .. #SPAWNED .. ")")
	local by = {}
	for _, s in ipairs(SPAWNED) do by[target(s.id) or -1] = s end
	check(by[0] == nil, "s38:3 server: no squad targets the veteran ghost")
	check(by[501] ~= nil and by[501].section == "freedom_sim_squad_alpha",
		"s38:3 server: a's squad is of a faction hostile to his (dolg): " .. tostring(by[501] and by[501].section))
	check(by[502] ~= nil and by[502].section == "dolg_sim_squad_alpha",
		"s38:3 server: b's squad is of a faction hostile to his (freedom): " .. tostring(by[502] and by[502].section))
	for _, s in ipairs(SPAWNED) do
		check(s.smart == "s_far", "s38:6 server one map: the map is the target's, the smart far from both (" .. s.smart .. ")")
	end
	none_near("s38:6 server one map")
	if by[501] then
		local sq = SE[by[501].id]
		sq.assigned_target_id = 0
		local t = sq:get_current_task()
		check(t.gvid == 11 and t.lvid == 111, "s38:3 server: a's squad goes to a's record, not to the ghost (" .. t.gvid .. ")")
	end
	local t = sent(EVENT)
	check(t ~= nil and tonumber(t.n) == 2, "s38:3 server: the world server publishes both targets")
	-- separate cooldowns: a's squad is gone at once; he waits his own day, counted from his spawn
	if by[501] then release_id(by[501].id) end
	GAME_T = GAME_T + 60
	spawn_tick()
	check(#SPAWNED == 2, "s38:3 server: a's next squad waits for his own cooldown (" .. #SPAWNED .. ")")
	t = sent(EVENT)
	check(t ~= nil and tonumber(t.n) == 1 and tonumber(t.c1) == 502, "s38:3 server: the list without a's lost squad goes out")
	GAME_T = GAME_T + DAY
	spawn_tick()
	check(#SPAWNED == 3 and target(SPAWNED[3].id) == 501, "s38:3 server: a gets a new squad after his day; b keeps his one")

	print("== world server, the players on two maps")
	srv_world(20, 1000) -- b on level 2 at (1000, 0, 0)
	RANK[501], RANK[502] = 6000, 6000
	board({ "s_near_client", "s_l2_near_b", "s_l2_far", "s_fake" })
	for k = 1, 3 do
		if k > 1 then
			srv_world(20, 1000)
			RANK[501], RANK[502] = 6000, 6000
			board({ "s_near_client", "s_l2_near_b", "s_l2_far", "s_fake" })
		end
		start()
		PICK = k
		spawn_tick()
		GAME_T = GAME_T + DAY + 1
		spawn_tick()
		check(#SPAWNED == 2, "s38:3 server two maps pick " .. k .. ": a squad for each (" .. #SPAWNED .. ")")
		none_near("s38:6 server two maps pick " .. k)
		for _, s in ipairs(SPAWNED) do
			check(s.smart ~= "s_fake", "s38:6 server two maps pick " .. k .. ": never on the ghost's fake_start")
			check(s.smart == "s_l2_far", "s38:6 server two maps pick " .. k .. ": only the smart far from the player of its map ("
				.. s.smart .. ")")
		end
	end

	print("== world server, a veteran player still joining")
	srv_world(12, 0, { where = function(peer)
		if peer == 2 then return "joining" end
		return "away"
	end })
	RANK[501], RANK[502] = 6000, 6000
	board({ "s_far" })
	start()
	spawn_tick()
	GAME_T = GAME_T + DAY + 1
	spawn_tick()
	check(#SPAWNED == 1 and target(SPAWNED[1].id) == 501, "s38:3 server: only the placed veteran gets a squad while the other is joining")
	check(squads_of_char(502) == 0, "s38:3 server: no squad targets the veteran who is still joining")
end

-------------------------------------------------------------------------------
-- A map server (srv_map): it holds the squad online; the world server published its target
-------------------------------------------------------------------------------
local function map_tests()
	print("== map server")
	boot({ set = "srv_map", map = true, players = SRV_PLAYERS, peer_of_avatar = srv_peer_of })
	make_actor(vec3(0, 0, 0)) -- the ghost
	SE[0].m_game_vertex_id, SE[0].m_level_vertex_id = 90, 900
	db.actor.character_rank = function() return 100 end
	db.actor.character_reputation = function() return 0 end
	db.actor.character_community = function() return "actor_stalker" end
	character(501, 400, 0, 11, 111, true, "actor_dolg")
	character(502, 0, 0, 12, 122, true, "actor_freedom")
	RANK[501], RANK[502] = 6000, 6000
	board({ "s_far" })
	local live = false
	local old_live = coop.is_live
	coop.is_live = function() return live end
	start()
	SendScriptCallback("actor_on_update")
	check(sent_count(REQUEST) == 0, "map server: no startup request before the bridge can send")
	live = true
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	local _, request = sent(REQUEST)
	check(sent_count(REQUEST) == 1 and request.target == 0 and request.payload == "",
		"map server: the first live update requests the list from the world without a player payload")
	NOW = NOW + 5000
	SendScriptCallback("actor_on_update")
	check(sent_count(REQUEST) == 1, "map server: no periodic requests while a snapshot is pending")
	local r1 = spawn_tick()
	GAME_T = GAME_T + DAY + 1
	local r2 = spawn_tick() or r1
	check(#SPAWNED == 0 and r2 == true, "map server: it makes no bounty squad, the world server does (" .. #SPAWNED .. ")")
	local sq = create_squad(SIMBOARD.smarts_by_names.s_far, "dolg_sim_squad_alpha")
	SPAWNED = {}
	sq.scripted_target, sq.assigned_target_id = "actor", 0
	-- Carry the actual request and reply across the two facade answers in this single Lua fixture.
	modes.install(coop_mode, "srv_world")
	SendScriptCallback("load_state", { coop_bounty = { c = { [502] = { s = { [sq.id] = sq:section_name() } } } } })
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update") -- settle the load publication before delivering the request
	local before = sent_count(EVENT)
	coop_main.on_event(REQUEST, request and request.payload or "", BRIDGE)
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	local list, response = sent(EVENT)
	check(sent_count(EVENT) == before + 1 and list.n == 1 and list.s1 == sq.id and list.c1 == 502,
		"round trip: the world replies to the map's request with its current squad binding")
	modes.install(coop_mode, "srv_map")
	if response then coop_main.on_event(response.name, response.payload, 0) end
	check(target(sq.id) == 502, "s38:3 map server: the world server's target of the squad is known here")
	local t = sq:get_current_task()
	check(t.gvid == 12 and t.lvid == 122, "s38:3 map server: the squad goes to its own target b, not the first player or the ghost ("
		.. t.gvid .. ")")
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(REQUEST) == 1, "map server: receiving the reply does not send another request")
	live = false
	SendScriptCallback("actor_on_update")
	check(target(sq.id) == nil, "map server: losing the bridge discards stale target bindings")
	live = true
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(REQUEST) == 2, "map server: reconnect requests a fresh snapshot once")
	if response then coop_main.on_event(response.name, response.payload, 0) end
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(REQUEST) == 2 and target(sq.id) == 502, "map server: the reconnect snapshot restores the binding")
	coop.is_live = old_live
	-- a squad with no published target stays the stock's (the ghost here; coop_npc_compat sends it to a player)
	local other = create_squad(SIMBOARD.smarts_by_names.s_far, "dolg_sim_squad_alpha")
	other.assigned_target_id = 0
	local o = other:get_current_task()
	check(o.gvid == 90, "map server: a squad that is no bounty of ours keeps the stock's task")
	-- unregister clears the local copy before the world server sends another list
	alife():release(sq)
	SendScriptCallback("server_entity_on_unregister", sq, "sim")
	check(target(sq.id) == nil, "map server unregister: the released squad has no mirrored target")
	-- the target list is replaced by the next one: an empty list clears it
	coop_main.on_event(EVENT, snapshot(20, { n = 1, s1 = other.id, c1 = 502 }), 0)
	check(target(other.id) == 502, "map server: the next list supplies another target")
	coop_main.on_event(EVENT, snapshot(21, { n = 0 }), 0)
	check(target(other.id) == nil, "map server: an empty list clears the targets")
end

-------------------------------------------------------------------------------
-- Single player: the stock as it is
-------------------------------------------------------------------------------
local function missed_empty_tests()
	print("== map server, missed empty bootstrap reply")
	boot({ set = "srv_map", map = true })
	start()
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	local _, request = sent(REQUEST)
	srv_world(12, 0)
	start()
	if request then deliver(request, BRIDGE) end
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(sent_count(EVENT) == 1, "empty recovery: the initial reply was queued but is lost in transport")
	local _, first_reply = sent(EVENT)
	NOW = NOW + 31000
	SendScriptCallback("actor_on_update")
	local empty, repair = sent(EVENT)
	check(sent_count(EVENT) == 2 and empty.n == 0 and repair ~= first_reply,
		"empty recovery: the world re-publishes even with zero bindings")

	boot({ set = "srv_map", map = true })
	start()
	SendScriptCallback("actor_on_update")
	NOW = NOW + 31000
	SendScriptCallback("actor_on_update")
	check(coop_bounty.targets_pending(), "empty recovery: startup is still pending after the loss")
	if repair and repair ~= first_reply then deliver(repair, 0) end
	check(not coop_bounty.targets_pending(), "empty recovery: the next empty generation ends the startup hold")
	check(sent_count(REQUEST) == 1, "empty recovery: the map does not retry the request on the same connection")
end

local function snapshot_receive_tests()
	print("== map server, snapshot assembly")
	boot({ set = "srv_map", map = true })
	start()
	local function receive(g, i, k, n, sid, cid, from)
		coop_main.on_event(EVENT, coop_main.encode({ g = g, i = i, k = k, n = n, s1 = sid, c1 = cid }), from or 0)
	end
	receive(1, 2, 2, 1, 4002, 502)
	check(coop_bounty.targets_pending() and target(4002) == nil, "assembly: a last chunk arriving first cannot release the hold")
	receive(1, 2, 2, 1, 4002, 502)
	receive(1, 1, 2, 1, 4001, 501, BRIDGE)
	receive(1, 1, 1025, 1, 4001, 501)
	receive(1, 0, 2, 1, 4001, 501)
	receive(1, 1, 2, 1, 4001, 65535)
	receive(1, 1, 2, 1, 4002, 501)
	check(coop_bounty.targets_pending() and target(4001) == nil, "assembly: invalid, cross-chunk duplicate and wrong-sender chunks do not commit")
	receive(1, 1, 2, 1, 4001, 501)
	check(not coop_bounty.targets_pending() and target(4001) == 501 and target(4002) == 502,
		"assembly: both bindings become visible together after the complete out-of-order generation")
	receive(2, 1, 2, 1, 4001, 502)
	check(target(4001) == 501 and target(4002) == 502, "assembly: a partial refresh keeps the last complete generation")
	receive(3, 1, 2, 1, 4003, 501)
	receive(2, 2, 2, 1, 4002, 501)
	check(target(4001) == 501 and target(4003) == nil, "assembly: late pieces cannot replace a newer in-flight generation")
	receive(3, 2, 2, 1, 4004, 502)
	receive(1, 1, 1, 0)
	check(target(4001) == nil and target(4003) == 501 and target(4004) == 502,
		"assembly: the complete refresh replaces the old snapshot and a stale empty cannot clear it")
	receive(4, 1, 1, 1, 0, 502)
	check(target(0) == nil and target(4003) == 501, "assembly: actor id zero cannot occupy a squad slot")
end

local function sp_tests()
	print("== single player")
	boot({ set = "none", mode = "sp", answers = "none" })
	make_actor(vec3(0, 0, 0))
	SE[0].m_game_vertex_id, SE[0].m_level_vertex_id = 10, 100
	db.actor.character_rank = function() return 6000 end
	db.actor.character_reputation = function() return 0 end
	db.actor.character_community = function() return "actor_stalker" end
	board({ "s_near_host", "s_far" })
	start()
	spawn_tick()
	GAME_T = GAME_T + DAY + 1
	spawn_tick()
	check(#SPAWNED == 1 and SPAWNED[1].smart == "s_far", "single player: the stock makes its squad 200 m away from the actor")
	local sq = SPAWNED[1] and SE[SPAWNED[1].id]
	check(sq ~= nil and sq.scripted_target == "actor", "single player: sent at the actor")
	check(sent_count(EVENT) == 0, "single player: nothing is published")
	check(target(sq and sq.id or -1) == nil, "single player: no per-character target")
	if sq then
		sq.assigned_target_id = 0
		local t = sq:get_current_task()
		check(t.gvid == 10, "single player: the squad goes to the actor")
	end
	local m = {}
	SendScriptCallback("save_state", m)
	check(m.coop_bounty == nil and type(m.bounty_squad) == "table", "single player: the stock saves its own record and nothing else")
end

-- The router (coop_route) runs the stock's timer only where the "host" domain runs (configs\coop_route_stock.ltx:75): the
-- adapter's wrapper is routed as the stock function it replaces, not as a coop_* script (view: every machine).
local function route_tests()
	print("== routing")
	coop_world()
	start()
	local r = rawget(_G, "coop_route")
	check(r ~= nil and r.install() == true, "routing: the router installs over the stubs")
	local key = r and r.script_of(sim_squad_bounty.spawn_timer)
	check(key == "sim_squad_bounty", "routing: the spawn timer is routed as sim_squad_bounty's (" .. tostring(key) .. ")")
end

for _, name in ipairs(modes.names()) do
	if name == "hostplay" then
		coop_tests()
		client_tests()
		route_tests()
	elseif name == "srv_world" then
		server_tests()
		request_tests()
		large_snapshot_tests()
	elseif name == "srv_map" then
		map_tests()
		missed_empty_tests()
		snapshot_receive_tests()
	elseif name == "none" then
		sp_tests()
	end
end

done("bounty per character (" .. (os.getenv("COOP_LUA_MODE") or "all") .. ")")
