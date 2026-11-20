-- Split levels: a task's release of what a map server holds, by the ways coop_srv_quests_far did not see: alife():release in the far view
-- (tasks_recover_item_on_corpse, utils_slht), safe_release_manager.release({ id = N }) (tasks_intercept_artifact, tasks_nta_stash,
-- tasks_veh_destroy), an item in a body the map server holds. Step S4: coop_srv_quests_far starts from coop_mode.when_srv only;
-- in the co-op it patches nothing, swaps nothing and gives the Core no far view. Run: tools\test_lua.cmd srv_far_release
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_srv_levels_share", "coop_srv_quests_far" }
local BRIDGE = 0x101
local LEVEL_NAMES = { "l01_escape", "jupiter" }

local records = {}

local function world(M)
	local e = M.env
	e.game_graph = function()
		return { vertex = function(_, v) return { level_id = function() return v end } end }
	end
	local sim = {}
	M.sim_released = {}
	function sim:level_name(l) return LEVEL_NAMES[l] end
	function sim:switch_distance() return 150 end
	function sim:actor() return { id = 0, m_game_vertex_id = 1, position = vec(0, 0, 0) } end
	function sim:has_info() return false end
	function sim:release(se, b) M.sim_released[#M.sim_released + 1] = se.id end
	e.alife = function() return sim end
	e.vector = function() return { set = function(_, x, y, z) return vec(x, y, z) end } end
	e.db.anomaly_by_name = {}
	e.db.zone_by_name = {}
	local stock_object = e.alife_object
	e.alife_object = function(id)
		local r = records[id]
		if r then return r end
		local se = stock_object(id)
		if se then se.m_game_vertex_id = 1 end
		return se
	end
	e.coop.levels = {
		split = function() return true end,
		my_level = function() return M.my_level end,
		level_of_player = function(peer) return peer == 1 and 2 or 1 end,
		map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
		carried = function() return {} end,
	}
	M.srm_released = {}
	e.safe_release_manager = { release = function(se) M.srm_released[#M.srm_released + 1] = se.id end }
end

local Hm = machine("host", 0)
local Ms = machine("client", BRIDGE)
Hm.my_level, Ms.my_level = 1, 2
world(Hm); world(Ms)
Ms.env.coop.is_map_server = function() return true end

local function rec(id, gv, online, parent)
	records[id] = { id = id, parent_id = parent or 65535, m_game_vertex_id = gv, m_level_vertex_id = 5, position = vec(10, 0, 10),
		online = online, section_name = function() return "x" .. id end, clsid = function() return 44 end, alive = function() return true end }
	return records[id]
end
rec(500, 2, true)        -- the player on jupiter
rec(700, 2, true)        -- a corpse there, online on the map server
rec(720, 2, false, 500)  -- a quest item in the player's backpack: its own record is not online, its body is
rec(730, 2, true)        -- an artefact there, given as { id = 730 }
rec(900, 1, false)       -- something of the world server's own level
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500 } }
for _, id in ipairs({ 500, 700, 720, 730 }) do Ms.new_obj(id, "x" .. id, vec(10, 0, 10)) end

local function boot(M)
	load_script(M, "coop_mode")
	load_script(M, "coop_hostplay_mode").on_game_start()
	load_script(M, "coop_srv_mode").on_game_start()
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
	fire(M, "actor_on_first_update")
end
boot(Hm); boot(Ms)
pump()

local qc = Hm.env.coop_quests_core
local function has(list, id)
	for _, x in ipairs(list) do if x == id then return true end end
	return false
end

print("== alife():release in the far view")
qc.with_level_of(1, function() Hm.env.alife():release(records[700], true) end)
pump()
check(has(Ms.srm_released, 700), "a corpse the map server holds: it releases it")
check(not has(Hm.sim_released, 700), "the world server's own release, which the engine refuses, is not made")
qc.with_level_of(1, function() Hm.env.alife():release(records[900], true) end)
check(has(Hm.sim_released, 900), "what the world server holds: its own release, as the stock")
Hm.env.alife():release(records[700], true)
check(has(Hm.sim_released, 700), "out of a far view nothing changes")
Hm.sim_released = {}

print("== safe_release_manager.release({ id = N })")
Hm.env.safe_release_manager.release({ id = 730 })
pump()
check(has(Ms.srm_released, 730), "the record of the id says it is held: the map server releases it")
check(not has(Hm.srm_released, 730), "not the world server")
Hm.env.safe_release_manager.release({ id = 4000 })
check(has(Hm.srm_released, 4000), "an id with no record goes as in the stock")
Hm.env.safe_release_manager.release({ id = 900 })
check(has(Hm.srm_released, 900), "an id of the world server's level goes as in the stock")

print("== an item in a body the map server holds")
Hm.env.alife_release = function(se) Hm.sim_released[#Hm.sim_released + 1] = se.id end
fire(Hm, "actor_on_first_update")
Hm.env.alife_release(records[720])
pump()
check(has(Ms.srm_released, 720), "it is held with the body: the map server releases it")
check(not has(Hm.sim_released, 720), "not the world server")

print("== S4: the death relay calls the handlers the Core keeps (coop_quests_core.add_death_listener)")
do
	local heard = {}
	Hm.env.coop_quests_core.add_death_listener("npc_on_death_callback", function(victim, killer)
		heard[#heard + 1] = { victim = victim and victim:id(), far = victim and victim.far, killer = killer }
	end)
	Hm.env.IsMonster = function() return false end
	rec(760, 2, false)
	Hm.env.coop_srv_quests_far.on_death(760, 65535)
	check(#heard == 1 and heard[1].victim == 760 and heard[1].far == true and heard[1].killer == nil,
		"a death on the map server's level: the coop script's handler hears it, with a stand-in")
	Hm.env.coop_srv_quests_far.on_death(760, 65535)
	check(#heard == 1, "the same death twice is heard once")
end

print("== S4: the co-op host: the far view's script is there and does nothing")
do
	local C = machine("host", 0)
	C.my_level = 1
	world(C)
	C.env.coop.levels.split = function() return false end
	C.env.coop.is_map_server = function() return false end
	local stock_release = function(se) end
	C.env.alife_release = stock_release
	local stock_alife = C.env.alife
	load_script(C, "coop_mode")
	load_script(C, "coop_hostplay_mode").on_game_start()
	for _, n in ipairs(SCRIPTS) do load_script(C, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = C.env[n]
		if m.on_game_start then m.on_game_start() end
	end
	fire(C, "actor_on_first_update")
	tick(C)
	local qc, far = C.env.coop_quests_core, C.env.coop_srv_quests_far
	check(qc.part("far") == nil and C.env.coop_mode.far().in_scope() == nil, "the co-op receives the far-view stub")
	check(C.env.alife_release == stock_release and C.env.alife == stock_alife and C.env.safe_release_manager.release ~= nil
		and C.callbacks.actor_on_update == nil and C.handlers["quests.far_do"] == nil,
		"nothing of the stock is wrapped, no callback, no event")
	local ran = 0
	check(qc.with_level_of(1, function(x) ran = ran + x return "same" end, 2) == "same" and ran == 2, "qc.with_level_of runs fn as it is")
	check(far.with_level_of(1, function() return "here" end) == "here" and far.in_scope() == nil,
		"and the far view itself opens no scope: it swaps no global without the server layer")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
