-- Anomaly Coop temp test (economy, travel): the smart terrains a client has visited. The host's smart_terrain.script sends
-- actor_on_interaction("smarts", smart, name) when the actor is within 50 m of a smart; a client's ALife is frozen, its
-- smarts never update, so game_statistics and Fair Fast Travel (state 1: only the places visited) saw nothing there.
-- coop_economy_travel counts it on the client, once a second, for the fast travel points of its map. Not shipped.
dofile("tests/lua/support/harness_economy.lua")
dofile("tests/lua/support/luabind_like.lua")

local SMART = 77 -- clsid.smart_terrain of the stand-in
local LEVEL_OF = { [10] = "l01", [20] = "l02" } -- game vertex -> level name

local function smart(W, id, name, gv, x)
	local se = { id = id, position = { x = x, y = 0, z = 0 }, m_game_vertex_id = gv, parent_id = 65535 }
	function se:name() return name end
	function se:clsid() return SMART end
	W.SE[id] = se
	return se
end

local function stubs(W, opts)
	W.CALLS = {}
	W.SendScriptCallback = function(name, ...) W.CALLS[#W.CALLS + 1] = { name = name, ... } end
	W.clsid = { smart_terrain = SMART }
	W.game_graph = function() return { vertex = function(_, gv) return { level_id = function() return gv end } end } end
	W.ITER = { level = 0, all = 0 }
	local sim = {
		object = function(_, id) return W.SE[id] end,
		actor = function() return { position = POS[W.PEER] } end,
		level_name = function(_, lid) return LEVEL_OF[lid] end,
	}
	if not opts or opts.level_iter ~= false then
		sim.iterate_level_objects_of_clsid = function(_, cls, f)
			W.ITER.level = W.ITER.level + 1
			for _, se in pairs(W.SE) do
				if se:clsid() == cls and LEVEL_OF[se.m_game_vertex_id] == LEVEL and f(se) then break end
			end
		end
	end
	sim.iterate_objects = function(_, f)
		W.ITER.all = W.ITER.all + 1
		for _, se in pairs(W.SE) do
			if f(se) then break end
		end
	end
	W.alife = function() return sim end
	W.game_fast_travel = { tsmarts = { esc_smart_terrain_2_12 = true, gar_smart_terrain_3_7 = true } }
end

local function setup(opts)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "anna", proxy = 501 } }
	POS = { [0] = { x = 3, y = 0, z = 0 }, [1] = { x = 0, y = 0, z = 0 } }
	QUEUE, WORLDS = {}, {}
	LEVEL = "l01"
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		stubs(W, opts)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
		smart(W, 900, "esc_smart_terrain_2_12", 10, 30) -- 30 m from anna, on this map
		smart(W, 901, "gar_smart_terrain_3_7", 20, 10) -- 10 m by the numbers, but on another map
		smart(W, 902, "esc_smart_terrain_5_5", 10, 5) -- near, no fast travel point
		smart(W, 903, "esc_smart_terrain_far", 10, 400)
	end
	for _, W in pairs(WORLDS) do
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_group")
		load_script(W, "coop_economy_travel")
		for _, n in ipairs({ "coop_economy_core", "coop_economy_group", "coop_economy_travel" }) do
			if W[n].on_game_start then W[n].on_game_start() end
		end
	end
	return WORLDS[0], WORLDS[1]
end

-- the smart terrains (by name) a world was told of
local function told(W)
	local out = {}
	for _, c in ipairs(W.CALLS) do
		check(c.name == "actor_on_interaction" and c[1] == "smarts", "only the smart terrain interaction is sent")
		out[#out + 1] = c[3]
	end
	table.sort(out)
	return out
end

local function same(list, ...)
	local want = { ... }
	if #list ~= #want then return false end
	for i = 1, #want do
		if list[i] ~= want[i] then return false end
	end
	return true
end

-------------------------------------------------------------------------------
section("a client: the fast travel points within 50 m of his map are visited")
do
	local H, A = setup()
	A.SIMBOARD = luabind_object({ smarts_by_names = {} }) -- sim_board: a script class, a userdata in the game
	for _, id in ipairs({ 900, 901, 902, 903 }) do A.SIMBOARD.smarts_by_names[A.SE[id]:name()] = A.SE[id] end
	tick(A, 1000)
	check(same(told(A), "esc_smart_terrain_2_12"), "the point within reach is visited, the one on another map and the one that is no point are not")
	local c = A.CALLS[1]
	check(c[2] == A.SE[900] and c[3] == "esc_smart_terrain_2_12", "the callback carries the server object and the name, as smart_terrain.script sends it")
	tick(A, 300)
	check(#A.CALLS == 1, "once a second at most")
	tick(A, 800)
	check(#A.CALLS == 2, "and again a second later while he stays")
	A.CALLS = {}
	POS[1] = { x = 200, y = 0, z = 0 }
	tick(A, 1000)
	check(#A.CALLS == 0, "out of reach (50 m): nothing")
	POS[1] = { x = -19, y = 0, z = 0 }
	tick(A, 1000)
	check(same(told(A), "esc_smart_terrain_2_12"), "49 m: visited")
	POS[1] = { x = -21, y = 0, z = 0 }
	A.CALLS = {}
	tick(A, 1000)
	check(#A.CALLS == 0, "51 m: not")
	check(A.ITER.all == 0 and A.ITER.level == 0, "the board had the smarts: the ALife copy is not walked")
end

-------------------------------------------------------------------------------
section("no board on the client: the smarts are found in the ALife copy of his map")
do
	local H, A = setup()
	A.SIMBOARD = nil
	tick(A, 1000)
	check(same(told(A), "esc_smart_terrain_2_12"), "found by the level objects of the smart clsid")
	check(A.ITER.level == 1 and A.ITER.all == 0, "one walk of the level's objects")
	tick(A, 1000)
	tick(A, 1000)
	check(A.ITER.level == 1, "kept: no walk again every second")
	-- the board is there but empty (nothing registered yet)
	A.SIMBOARD = luabind_object({ smarts_by_names = {} })
	A.CALLS = {}
	LEVEL = "l02"
	POS[1] = { x = 10, y = 0, z = 0 }
	tick(A, 1000)
	check(same(told(A), "gar_smart_terrain_3_7"), "another map: its points are looked for again (an empty board does not hide them)")
	check(A.ITER.level == 2, "walked again for the new level")
	LEVEL = "l01"
end

section("a map with no point: the board knows every map, its answer is final")
do
	local H, A = setup({ level_iter = false })
	A.SIMBOARD = luabind_object({ smarts_by_names = {} })
	for _, id in ipairs({ 900, 901, 902, 903 }) do A.SIMBOARD.smarts_by_names[A.SE[id]:name()] = A.SE[id] end
	A.game_fast_travel.tsmarts = { gar_smart_terrain_3_7 = true } -- a point of another map only
	tick(A, 1000)
	check(#A.CALLS == 0, "nothing to visit here")
	for _ = 1, 3 do tick(A, 31000) end
	check(A.ITER.all == 0 and A.ITER.level == 0, "the ALife copy is not walked, neither now nor every 30 s")
	LEVEL = "l02"
	POS[1] = { x = 10, y = 0, z = 0 }
	tick(A, 1000)
	check(same(told(A), "gar_smart_terrain_3_7"), "the map with the point has it from the board")
	LEVEL = "l01"
end

section("no level registry either: the whole ALife copy is walked, once")
do
	local H, A = setup({ level_iter = false })
	tick(A, 1000)
	check(same(told(A), "esc_smart_terrain_2_12") and A.ITER.all == 1, "every object, filtered by clsid, name and level")
	tick(A, 1000)
	check(A.ITER.all == 1, "once")
end

section("the table of points changes (Fair Fast Travel reads its faction again)")
do
	local H, A = setup()
	tick(A, 1000)
	A.CALLS = {}
	A.game_fast_travel.tsmarts = { esc_smart_terrain_5_5 = true }
	POS[1] = { x = 0, y = 0, z = 0 }
	tick(A, 1000)
	check(same(told(A), "esc_smart_terrain_5_5"), "the new table is used")
	A.game_fast_travel.tsmarts = nil
	A.CALLS = {}
	tick(A, 1000)
	check(#A.CALLS == 0, "no table: nothing")
end

section("nothing to do")
do
	local H, A = setup()
	tick(H, 1000)
	check(#H.CALLS == 0, "the host's smarts update by themselves: it sends nothing")
	local H2, A2 = setup()
	A2.game_fast_travel = nil
	tick(A2, 1000)
	check(#A2.CALLS == 0 and A2.HANDLER_ERRORS == nil, "no Fair Fast Travel: nothing, no error")
	local H3, A3 = setup()
	A3.ACTIVE = false
	tick(A3, 1000)
	check(#A3.CALLS == 0, "no session: nothing")
	local H4, A4 = setup()
	A4.coop.is_live = function() return false end
	tick(A4, 1000)
	check(#A4.CALLS == 0, "a client that has not loaded the host's world yet: nothing")
	local H6, A6 = setup()
	A6.coop.is_map_server = function() return true end
	tick(A6, 1000)
	check(#A6.CALLS == 0 and A6.ITER.level == 0 and A6.ITER.all == 0, "a map server: is_client is true there, its actor is a ghost, it visits nothing")
	local H5, A5 = setup()
	A5.alife = function() error("no simulator yet") end
	tick(A5, 1000)
	check(#A5.CALLS == 0, "a failing engine call does not break the update")
	check(has(A5.LOG, "visit") , "and it is logged")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
