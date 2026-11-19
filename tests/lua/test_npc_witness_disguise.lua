-- Dev 57 G13-4: only NPCs witness silent kills, and Tosox companions ignore RayLink disguises.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local merged = "temp/review/corpus/merged/"
local stock = "temp/stock_scripts/scripts/"
local avatars = { [0] = 0, [1] = 500, [2] = 501 }

local function load_mod(E, dir, name)
	local mod = setmetatable({}, { __index = E })
	E[name] = mod
	setfenv(assert(loadfile(dir .. name .. ".script")), mod)()
	return mod
end

local function boot(set, peer, occupant)
	local M = machine(set == "none" and "single" or "host", peer or 0, avatars)
	local E = M.env
	E.coop.is_map_server = function() return set == "srv_map" end
	E.coop.is_dedicated = function() return set == "srv_world" end
	local players = E.coop.players
	E.coop.players = function()
		local rows = players()
		for _, row in ipairs(rows) do
			row.level = row.id
			row.elsewhere = occupant ~= nil and row.id ~= occupant
		end
		return rows
	end
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	load_script(M, "coop_trust")
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	E.getFS = function() return { exist = function() return false end } end
	E.IsStalker = function(o) return o._is_stalker ~= false end
	E.character_community = function(o) return o:character_community() end
	E.game_relations = { is_factions_enemies = function() return false end,
		change_factions_community_num = function() end }
	return M, E
end

local function stalker(M, id, x, extra)
	local npc = M.add(make_obj(id, x, 0, 0, extra))
	npc.clsid = function() return 1 end
	npc.dont_has_info = function(self, key) return not self:has_info(key) end
	local ids = M.env.db.OnlineStalkers
	ids[#ids + 1] = id
	return npc
end

local function silent_case(set, killer_peer, bystander, occupant)
	reset_world()
	local M, E = boot(set, nil, occupant)
	E.coop_route = { inherit_source = function() end }
	E.UnregisterScriptCallback = function(name, f)
		local list = M.callbacks[name] or {}
		for i = #list, 1, -1 do
			if list[i] == f then table.remove(list, i) end
		end
	end
	E.strformat = string.format
	E.level.rain_factor = function() return 0 end
	E.hit = setmetatable({ light_burn = 1, burn = 2, strike = 3, shock = 4, wound = 5,
		radiation = 6, telepatic = 7, chemical_burn = 8, explosion = 9, fire_wound = 10 },
		{ __call = function(_, original) return { type = original and original.type } end })
	M.options = { ["gameplay/silent_kills/sk_enabled"] = true,
		["gameplay/silent_kills/sk_melee_enabled"] = true, ["gameplay/silent_kills/sk_all_melee_ok"] = true,
		["gameplay/silent_kills/sk_gun_enabled"] = true }
	local sk = load_mod(E, stock, "gameplay_silent_kills")
	sk.on_game_start()
	load_script(M, "coop_npc_world").on_game_start()
	local killer = killer_peer == 0 and E.db.actor or stalker(M, avatars[killer_peer], 100)
	killer._pos = vec(100, 0, 0)
	killer._active = make_obj(700, 0, 0, 0, { weapon_is_silencer = function() return true end })
	local other = stalker(M, bystander, 102)
	local label = set .. "/attacker " .. killer_peer .. (occupant and "/split maps" or "")
	local function strike(id, lethal, description, damage_type, see)
		local victim = stalker(M, id, 101)
		if see then see(victim) end
		local flags = { ret_value = true }
		M.fire("npc_on_before_hit", victim, { draftsman = killer, type = damage_type, power = 10 }, 15, flags)
		check(flags.ret_value == not lethal and #(victim._hits or {}) == (lethal and 1 or 0), label .. ": " .. description)
		victim._alive = false
	end
	if set == "srv_world" then
		strike(600, false, "world has no level action", E.hit.wound)
		return
	end
	local session = set ~= "none"
	strike(600, session, session and "nearby player does not hear the strike" or "stock nearby NPC still hears", E.hit.wound)
	other._pos = vec(130, 0, 0)
	other._sees[killer:id()] = true
	strike(601, session, session and "player seeing the attacker does not witness the shot" or "stock NPC still sees the attacker", E.hit.fire_wound)
	other._sees[killer:id()] = nil
	strike(602, session, session and "player seeing the victim does not witness the strike" or "stock NPC still sees the victim", E.hit.wound,
		function(v) other._sees[v:id()] = true end)
	local npc = stalker(M, 610, 98)
	strike(603, false, "nearby NPC hears the strike and normal damage stays enabled", E.hit.wound)
	npc._pos = vec(130, 0, 0)
	strike(604, false, "distant NPC seeing the victim still blocks the shot", E.hit.fire_wound,
		function(v) npc._sees[v:id()] = true end)
	strike(605, true, "unobserved strike still registers one lethal hit", E.hit.wound)
end

local function install_disguise(M, with_tosox)
	local E = M.env
	M.options = { ["gameplay/disguise/distance"] = false, ["gameplay/disguise/stay_time"] = false }
	E.gameplay_disguise = { anybody_see = function() return "stock sight" end,
		anybody_remember = function() return "stock memory" end, npc_on_update = function() end,
		is_actor_disguised = function() return true end, get_default_comm = function() return "stalker" end,
		get_npc_awareness = function(section) return section == "veteran" and 2 or 1 end }
	if with_tosox then load_mod(E, merged, "z_companions_dont_blow_disguises") end
	local disguise = load_script(M, "coop_npc_disguise")
	disguise.on_game_start()
	return disguise
end

local function disguise_case(set, with_tosox, occupant)
	reset_world()
	NOW = NOW + 3000
	local map = set == "srv_map"
	local M, E = boot(set, map and 101 or 0, occupant)
	local D = install_disguise(M, with_tosox)
	local clients = { machine("client", 1, avatars), machine("client", 2, avatars) }
	local killer_peer = occupant or 1
	local proxy = stalker(M, avatars[killer_peer], 100, { _comm = "dolg" })
	local mate = stalker(M, 610, 101, { _section = "veteran" })
	mate._sees[proxy:id()] = true
	local name = set .. (occupant and "/split maps" or "") .. (with_tosox and "/Tosox" or "/without Tosox")

	if set == "none" then
		mate._sees[0] = true
		M.fire("actor_on_update")
		M.fire("npc_on_update", mate)
		check(E.gameplay_disguise.anybody_see() == (with_tosox and true or "stock sight") and
			E.gameplay_disguise.anybody_remember() == "stock memory" and not next(D._players_state()), name .. ": original sight and memory stay in use")
		if with_tosox then
			mate:give_info_portion("npcx_is_companion")
			check(E.gameplay_disguise.anybody_see() == false, name .. ": the original Tosox sight filter stays in use")
		end
		return
	end

	local world, other_level
	if map then
		world = boot("srv_world")
		local WD = install_disguise(world, with_tosox)
		if occupant then
			other_level = boot("srv_map", 102, 2)
			install_disguise(other_level, with_tosox)
			stalker(other_level, 501, 100, { _comm = "dolg" })
		end
		world.env.coop.levels = { split = function() return true end,
			bridge_of_player = function(peer) return peer == 2 and other_level and 102 or 101 end }
		check(not next(WD._players_state()), name .. ": world starts without level observations")
	end
	local function report(peer, disguised, item)
		local C = clients[peer]
		C.env.coop.send_event("npc.disg", C.env.coop_main.encode({ d = disguised, c = "dolg", def = "stalker", itm = item }), 0)
		pump()
	end
	local function tick()
		NOW = NOW + 2100
		M.fire("actor_on_update")
		local sent = sent_named(M, "npc.disg_meter")
		local last = sent[#sent]
		return last and E.coop_main.decode(last.payload) or {}
	end

	if occupant then
		report(2, true, 90)
		check(D._players_state()[2] == nil and other_level.env.coop_npc_disguise._players_state()[2] ~= nil and
			not next(world.env.coop_npc_disguise._players_state()), name .. ": world forwards only to that player's map")
	end
	report(killer_peer, true, 80)
	M.fire("actor_on_update")
	local s = assert(D._players_state()[killer_peer])
	mate:give_info_portion("npcx_is_companion")
	M.fire("npc_on_update", mate)
	if not with_tosox then
		local meter = tick()
		check(not s.d and #sent_named(M, "npc.disg_expose") == 1, name .. ": companion can expose a player without the fix")
		check(meter.s and meter.m and s.mem[610], name .. ": companion still counts for sight and memory")
		return
	end
	local meter = tick()
	check(s.d and #sent_named(M, "npc.disg_expose") == 0, name .. ": companion cannot expose a disguised client")
	check(meter.v == 0 and meter.s == false and meter.m == false and not s.mem[610], name .. ": companion adds no sight, memory or suspicion")

	-- The NPC saw the client before becoming a companion. Discard its record even if it has not updated again.
	mate:disable_info_portion("npcx_is_companion")
	local witness = stalker(M, 611, 102)
	witness._sees[proxy:id()] = true
	report(killer_peer, true, 40)
	M.fire("npc_on_update", witness)
	M.fire("npc_on_update", mate)
	check(s.high.id == 610 and s.high.v == 80, name .. ": future companion initially owns the highest suspicion")
	mate:give_info_portion("npcx_is_companion")
	meter = tick()
	check(s.mem[610] == nil and s.high.id == 611 and meter.v == 40 and meter.s and meter.m,
		name .. ": removes stale companion memory and keeps the real NPC's suspicion, sight and memory")
	report(killer_peer, false, 0)
	witness:give_info_portion("npcx_is_companion")
	M.fire("npc_on_update", witness)
	local calls = #sent_named(M, "npc.disg_meter")
	meter = tick()
	check(not next(s.mem) and s.high.id == false and meter.v == 0 and meter.s == false and meter.m == false and
		#sent_named(M, "npc.disg_meter") == calls + 1, name .. ": clears previous sight and memory before an outfit change")

	-- A dismissed companion can witness again. Its memory can then expire ahead of the suspicion meter.
	witness:disable_info_portion("npcx_is_companion")
	report(killer_peer, true, 40)
	M.fire("npc_on_update", witness)
	witness._sees[proxy:id()] = nil
	M.game_ms = 120000
	M.fire("npc_on_update", witness)
	check(s.mem[611] == nil and s.high.id == 611, name .. ": expired memory leaves the previous highest suspicion until the next meter tick")
	witness._sees[proxy:id()] = true
	witness:give_info_portion("npcx_is_companion")
	meter = tick()
	check(s.high.id == false and meter.v == 0, name .. ": joining as a companion clears suspicion left after memory expired")
end

for _, set in ipairs(modes.names()) do
	if set == "hostplay" then
		silent_case(set, 0, 500)
		silent_case(set, 1, 501)
		silent_case(set, 2, 500)
	elseif set == "srv_map" then
		silent_case(set, 1, 501)
		silent_case(set, 2, 500)
		silent_case(set, 1, 501, 1)
		disguise_case(set, true, 1)
	elseif set == "srv_world" then
		silent_case(set, 1, 501)
	else
		silent_case(set, 0, 6100)
	end
	if set ~= "srv_world" then
		disguise_case(set, true)
		disguise_case(set, false)
	end
end

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
