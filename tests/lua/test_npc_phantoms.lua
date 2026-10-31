-- Enemy audit F10 (2026-10-31): phantoms for every player. The fakes keep the shape of phantom_manager.script and
-- xcv_phantoms.script: a private callback registered by value, module globals, file locals reassigned at load_state.
dofile("tests/lua/support/harness_npc.lua")

local function boot(role, peer)
	reset_world()
	local M = machine(role or "host", peer or 0, { [0] = 0, [1] = 500, [2] = 501 })
	local E = M.env
	local proxy = M.add(make_obj(500, 100, 0, 0))
	local other = M.add(make_obj(501, 200, 0, 0))
	E.story_objects = { object_id_by_story_id = { actor = 0 } }
	E.getFS = function() return { exist = function() return false end } end
	E.UnregisterScriptCallback = function(name, f)
		local list = M.callbacks[name] or {}
		for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
	end
	E.coop_main.callback_registered = function(name, f)
		for _, v in ipairs(M.callbacks[name] or {}) do if v == f then return true end end
		return false
	end
	E.xr_combat_ignore = { fighting_with_actor_npcs = {} }
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	return M, E, proxy, other
end

local function install(M, on)
	local K = load_script(M, "coop_npc_phantoms")
	local applied = {}
	K.install(M.env.coop_npc_players, function() return on ~= false end, applied)
	return applied
end

-- As stock: the checks of phantom_manager.script:32-78, a file-local handler registered by on_game_start.
local function manager(E)
	local spawned = {}
	local function monster_on_update(npc, st)
		if not (npc and npc:alive()) then return end
		local tg = E.time_global()
		if st.__phantom_check and tg < st.__phantom_check then return end
		st.__phantom_check = tg + 5000
		if not E.xr_combat_ignore.fighting_with_actor_npcs[npc:id()] then return end
		if E.db.actor:position():distance_to_sqr(npc:position()) > 900 then return end
		spawned[#spawned + 1] = E.db.actor:id()
		if npc._fails then error("spawn failed") end
	end
	local m = { spawned = function() return spawned end }
	function m.on_game_start() E.RegisterScriptCallback("monster_on_update", monster_on_update) end
	E.phantom_manager = m
	return m
end

local function monster(M, x, enemy)
	return M.add(make_obj(20, x, 0, 0, { get_enemy = function() return enemy end }))
end

for _, started in ipairs({ false, true }) do
	local M, E, proxy = boot()
	local m = manager(E)
	if started then m.on_game_start() end
	local applied = install(M)
	if not started then m.on_game_start() end
	check(applied[1] == "native:phantoms", "the adapter reports itself; started=" .. tostring(started))
	check(#M.callbacks.monster_on_update == 1, "the handler is registered once; started=" .. tostring(started))

	local npc = monster(M, 110, proxy)
	local st = {}
	M.fire("monster_on_update", npc, st)
	check(m.spawned()[1] == 500, "a monster fighting a client near it spawns for him; started=" .. tostring(started))
	check(E.xr_combat_ignore.fighting_with_actor_npcs[20] == nil, "the host's table of fights stays as it was")
	check(E.db.actor:id() == 0 and E.story_objects.object_id_by_story_id.actor == 0, "identity restored")

	M.fire("monster_on_update", npc, st)
	check(#m.spawned() == 1, "the stock 5 s timer stands")
end

do
	local M, E, proxy = boot()
	local m = manager(E)
	m.on_game_start()
	install(M)
	M.fire("monster_on_update", monster(M, 140, proxy), {})
	check(#m.spawned() == 0, "a client 40 m from the monster is out of the stock 30 m")
end

do
	local M, E = boot()
	local m = manager(E)
	m.on_game_start()
	install(M)
	E.xr_combat_ignore.fighting_with_actor_npcs[20] = true
	M.fire("monster_on_update", monster(M, 10, E.db.actor), {})
	check(m.spawned()[1] == 0, "the host's own fight is stock")
	check(E.xr_combat_ignore.fighting_with_actor_npcs[20] == true, "and keeps its mark")
end

do
	local M, E, proxy = boot()
	local m = manager(E)
	m.on_game_start()
	install(M)
	E.xr_combat_ignore.fighting_with_actor_npcs[20] = true
	M.fire("monster_on_update", monster(M, 110, proxy), {})
	check(m.spawned()[1] == 500, "a fight the host started and a client took over counts for the client")
	check(E.xr_combat_ignore.fighting_with_actor_npcs[20] == true, "the host's mark survives the scope")
end

do
	local M, E, proxy = boot()
	local m = manager(E)
	m.on_game_start()
	install(M)
	local npc = monster(M, 110, proxy)
	npc._fails = true
	local ok = pcall(M.fire, "monster_on_update", npc, {})
	check(not ok, "a stock error is not swallowed")
	check(E.xr_combat_ignore.fighting_with_actor_npcs[20] == nil and E.db.actor:id() == 0, "and the scope is undone")
end

do
	local M, E, proxy = boot()
	local m = manager(E)
	m.on_game_start()
	install(M, false)
	M.fire("monster_on_update", monster(M, 110, proxy), {})
	check(#m.spawned() == 0, "no clients in the session: stock")
end

do
	local M, E = boot("client", 1)
	local m = manager(E)
	m.on_game_start()
	install(M)
	E.xr_combat_ignore.fighting_with_actor_npcs[20] = true
	M.fire("monster_on_update", monster(M, 10, E.db.actor), {})
	check(#m.spawned() == 0, "a direct call on a client spawns nothing")
end

-- G.A.M.M.A.'s xcv_phantoms: file locals of xcv_phantoms.script:2, :118-151, :210-223.
local function psy(E)
	local psy_table = { actor_psy_health = 0.9 }
	local m = {}
	function m.get_ppe_intensity() return (1 - psy_table.actor_psy_health) * 0.5 end
	function m.load_state(d) psy_table = d.psy_table or {} end
	E.arszi_psy = m
	return m
end

local function xcv(E)
	local spawned_phantoms = {}
	local psi_hit_power = 3
	local released = {}
	local m = { released = released }
	function m.load_state(d) spawned_phantoms = d.spawned_phantoms or {} end
	function m.add(id) spawned_phantoms[id] = true end
	function m.power() return psi_hit_power end
	function m.psi_health_hit()
		local h = E.hit()
		h.draftsman = E.db.actor
		E.db.actor:hit(h)
	end
	function m.monster_on_update(npc)
		local squad = E.get_object_squad(npc)
		if squad and not spawned_phantoms[squad.id] then return end
		if npc:position():distance_to(E.db.actor:position()) < 1.6 then
			m.psi_health_hit(true)
			released[#released + 1] = E.db.actor:id()
		end
	end
	function m.on_game_start() E.RegisterScriptCallback("monster_on_update", m.monster_on_update) end
	E.xcv_phantoms = m
	return m
end

local function stubs(E)
	E.hit = setmetatable({ telepatic = 7 }, { __call = function() return {} end })
	E.get_object_squad = function(npc) return npc._squad end
end

do
	local M, E, proxy = boot()
	stubs(E)
	local m = xcv(E)
	m.add(7)
	m.on_game_start()
	local applied = install(M)
	check(applied[1] == "native:phantom_contact", "the contact adapter reports itself")
	check(#M.callbacks.monster_on_update == 1, "its handler is registered once")

	local at_client = M.add(make_obj(30, 100.5, 0, 0, { _squad = { id = 7 } }))
	M.fire("monster_on_update", at_client)
	check(m.released[1] == 500, "a phantom touching a client goes")
	local h = proxy._hits and proxy._hits[1]
	check(h and h.draftsman == at_client and h.type == 7, "the psy hit names the phantom: a client's own hit never reaches him")
	check(h and h.power >= 0.01 and h.power <= 0.04, "at xcv's power")
	check(E.db.actor:id() == 0 and #(E.db.actor._hits or {}) == 0, "the host is not touched")

	local at_host = M.add(make_obj(31, 0.5, 0, 0, { _squad = { id = 7 } }))
	M.fire("monster_on_update", at_host)
	check(m.released[2] == 0, "a phantom touching the host goes")
	check(E.db.actor._hits[1].draftsman == E.db.actor, "his hit is stock")

	local stranger = M.add(make_obj(32, 100.5, 0, 0, { _squad = { id = 8 } }))
	M.fire("monster_on_update", stranger)
	check(#m.released == 2, "a monster of another squad is no phantom")

	m.load_state({ spawned_phantoms = { [9] = true } })
	local reloaded = M.add(make_obj(33, 100.5, 0, 0, { _squad = { id = 9 } }))
	M.fire("monster_on_update", reloaded)
	check(m.released[3] == 500, "the table xcv swaps at load_state is the one read")
end

do
	local M, E, proxy = boot()
	stubs(E)
	local m = xcv(E)
	m.add(7)
	m.on_game_start()
	install(M, false)
	local near = M.add(make_obj(30, 100.5, 0, 0, { _squad = { id = 7 } }))
	M.fire("monster_on_update", near)
	check(#m.released == 0 and not proxy._hits, "no clients in the session: contact is stock")
end

do
	local M, E, proxy = boot()
	local a = psy(E)
	local reports = { [500] = { actor_psy_health = 0.2 } }
	E.coop_economy_mdata = { player_value = function(id, key) return key == "psy_table" and reports[id] or nil end }
	local applied = install(M)
	check(applied[1] == "native:phantom_psy", "the psy adapter reports itself")
	local P = E.coop_npc_players
	local near = function(v) return math.abs(v) < 1e-6 end

	check(near(a.get_ppe_intensity() - 0.05), "outside a scope: the host's own psy health")
	check(near(P.with_identity(proxy, a.get_ppe_intensity) - 0.4), "as a client: what his machine reports")
	check(near(a.get_ppe_intensity() - 0.05), "the host's value comes back")
	reports[500] = nil
	check(near(P.with_identity(proxy, a.get_ppe_intensity)), "a client who reported nothing yet is healthy")

	reports[500] = { actor_psy_health = 0.4 }
	a.load_state({ psy_table = { actor_psy_health = 0.5 } })
	check(near(P.with_identity(proxy, a.get_ppe_intensity) - 0.3), "the table arszi swaps at load_state is the one used")
	check(near(a.get_ppe_intensity() - 0.25), "and it gets its value back")
end

do
	local M, E, proxy = boot()
	local a = psy(E)
	E.coop_economy_mdata = { player_value = function() return { actor_psy_health = 0.2 } end }
	install(M, false)
	check(math.abs(E.coop_npc_players.with_identity(proxy, a.get_ppe_intensity) - 0.05) < 1e-6, "no clients: stock psy")
end

do
	local M, E = boot()
	check(#install(M) == 0 and E.db.actor:id() == 0, "absent mods: the adapter is inert")
end

-- The wiring: coop_npc_compat installs it with the other native hooks, the route keeps the handler on the host.
do
	local M, E = boot()
	E.getFS = function() return { update_path = function() return "absent/packed.script" end, exist = function() return false end } end
	local m = manager(E)
	load_script(M, "coop_npc_phantoms")
	m.on_game_start()
	local K = load_script(M, "coop_npc_compat")
	K.on_game_start()
	local found = false
	for _, name in ipairs(K._applied()) do found = found or name == "native:phantoms" end
	check(found, "coop_npc_compat installs the adapter")
	local fh = assert(io.open("gamedata/configs/coop_route_npc.ltx", "r"))
	local route = fh:read("*a")
	fh:close()
	check(route:find("monster_on_update@coop_npc_phantoms%s*=%s*host") ~= nil, "the route keeps the wrapper on the host")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
