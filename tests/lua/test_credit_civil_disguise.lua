-- Dev 57 G9-4: personal ZCP reputation and observed disguise time.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local merged = "temp/review/corpus/merged/"
local avatars = { [1] = 500, [2] = 501 }
local bridge = 0x101

local function load_mod(E, name)
	local mod = setmetatable({}, { __index = E })
	E[name] = mod
	setfenv(assert(loadfile(merged .. name .. ".script")), mod)()
	return mod
end

local function boot(set, peer, occupant)
	local role = set == "none" and "single" or
		(avatars[peer] or set == "srv_map") and "client" or "host"
	local M = machine(role, peer, avatars)
	local E = M.env
	E.coop.is_dedicated = function() return set == "srv_world" and peer == 0 end
	E.coop.is_map_server = function() return peer >= bridge end
	E.coop.levels = {
		split = function() return set:sub(1, 3) == "srv" end,
		bridge_of_player = function(p) return p == 2 and MACHINES[bridge + 1] and bridge + 1 or bridge end,
		map_servers = function()
			local list = {}
			for id = bridge, bridge + 1 do
				if MACHINES[id] then list[#list + 1] = { bridge = id, level = id - bridge + 1 } end
			end
			return list
		end,
	}
	local players = E.coop.players
	E.coop.players = function()
		local rows = players()
		for _, p in ipairs(rows) do
			p.level = occupant and p.id ~= occupant and 2 or 1
			p.elsewhere = p.level ~= 1
		end
		return rows
	end
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)

	M.reputation, M.minutes = 0, 0
	E.db.actor._comm = "bandit"
	E.db.actor.change_character_reputation = function(_, n) M.reputation = M.reputation + n end
	E.game_statistics = {
		increment_statistic = function(name)
			if name == "minutes_disguised" then M.minutes = M.minutes + 1 end
		end,
	}
	E.xr_effects = {}
	E.character_community = function(o) return o:character_community() end
	E.game_relations = {
		is_factions_enemies = function(a, b) return a == "bandit" and b == "dolg" end,
		is_factions_friends = function(a, b) return a == b end,
	}
	E.getFS = function() return {
		exist = function(_, _, f) return f == "smr_civil_war.script" or f == "gameplay_disguise.script" end,
		update_path = function(_, _, f) return merged .. f end,
	} end
	E.smr_amain_mcm = { get_config = function() return M.zcp_enabled ~= false end }
	E.smr_stalkers_mcm = { get_config = function() return "civilwar_stalkers" end }
	E.smr_debug = { get_log = function() return { info = function() end } end }
	E.relation_registry = { set_community_relation = function() end }
	E.coop_npc_is_player_id = function(id)
		return id == 0 or E.coop.peer_of_avatar(id) ~= nil
	end
	E.axr_companions = { companion_squads = {} }
	E.get_object_squad = function(o) return o._squad end
	M.options = {
		["gameplay/disguise/state"] = true,
		["gameplay/disguise/distance"] = false,
		["gameplay/disguise/stay_time"] = false,
	}
	E.gameplay_disguise = { is_actor_disguised = function() return false end }

	load_mod(E, "smr_civil_war")
	for _, n in ipairs({ "coop_mods_core", "coop_npc_players", "coop_trust", "coop_credit", "coop_quests_core", "coop_tasks",
		"coop_npc_compat", "coop_npc_disguise" }) do load_script(M, n) end
	E.coop_npc_compat.on_game_start()
	E.smr_civil_war.on_game_start()
	M.fire("load_state", { smr_civil_war = { civil_war_stalkers = { [601] = true } } })
	E.coop_npc_disguise.on_game_start()
	E.coop_tasks.on_game_start()
	if set == "srv_world" or set == "srv_map" then load_script(M, "coop_srv_tasks").on_game_start() end
	return M
end

local function civil_kill(M, victim, killer, faction, squad_id)
	local squad = {
		id = squad_id or 601,
		get_squad_community = function() return faction or "dolg" end,
		section_name = function() return "sim_smr_default" end,
		npc_count = function() return 1 end,
	}
	M.fire("squad_on_npc_death", squad, { id = victim }, killer)
	pump()
end

local function place(M, p)
	return M.add(make_obj(avatars[p], p * 10, 0, 0, { _comm = "dolg" }))
end

local function civil_case(label, authority, C1, C2, killer)
	civil_kill(authority, 610, killer)
	check(C1.reputation == 100 and authority.reputation == 0 and C2.reputation == 0,
		label .. ": a friendly kill credits only the killer, using the killer's faction")
	civil_kill(authority, 610, killer)
	check(C1.reputation == 100, label .. ": repeated death does not repeat the reward")
	civil_kill(authority, 611, killer, "freedom")
	check(C1.reputation == 175, label .. ": a neutral kill retains the ZCP +75")
	civil_kill(authority, 612, { id = 0, community = function() return "bandit" end })
	local is_player = authority.env.coop_mode.actor_is_player()
	check(C1.reputation == 175 and authority.reputation == 0,
		label .. ": an enemy kill or a ghost kill awards nothing")
	civil_kill(authority, 613, { id = 700 })
	civil_kill(authority, 613, { id = 700 }, "bandit", 602)
	local ok = pcall(civil_kill, authority, 614, nil)
	check(ok and C1.reputation == 175 and authority.reputation == 0 and C2.reputation == 0,
		label .. ": NPC and missing killers award nobody")
	authority.zcp_enabled = false
	civil_kill(authority, 615, killer)
	check(C1.reputation == 175, label .. ": disabled ZCP awards nothing")
	authority.zcp_enabled = true
	if is_player then
		civil_kill(authority, 616, { id = 0 }, "freedom")
		check(authority.reputation == 75 and C1.reputation == 175, label .. ": host's own kill credits the host")
	end
end

local function report(C, disguised)
	local E = C.env
	E.coop.send_event("npc.disg", E.coop_main.encode({ d = disguised, c = "dolg", def = "stalker", itm = 1 }), 0)
	pump()
end

local function disguise_case(label, M1, M2, C1, C2)
	local w1 = M1.add(make_obj(710, 15, 0, 0))
	local w2 = M1.add(make_obj(711, 15, 0, 0))
	local w3 = M2.add(make_obj(712, 25, 0, 0))
	w1._sees[500], w2._sees[500], w3._sees[501] = true, true, true
	w3._squad = { id = 98 }
	M2.env.axr_companions.companion_squads[98] = true
	report(C1, true)
	report(C2, true)
	M1.fire("actor_on_update")
	if M2 ~= M1 then M2.fire("actor_on_update") end
	local function observe(M, seconds, ...)
		M.game_ms = seconds * 1000
		for _, npc in ipairs({ ... }) do M.fire("npc_on_update", npc) end
		pump()
	end
	observe(M1, 0, w1, w2)
	observe(M2, 0, w3)
	M2.env.axr_companions.companion_squads[98] = nil
	observe(M2, 30, w3)
	observe(M1, 60, w1, w2)
	check(C1.minutes == 0 and C2.minutes == 0, label .. ": observation must exceed 60 game seconds")
	if M1.peer == bridge then
		local E = C2.env
		E.coop.send_event("npc.disg", E.coop_main.encode({ _peer = 1, d = false, c = "dolg", def = "stalker" }), bridge)
		pump()
		check(M1.env.coop_npc_disguise._players_state()[1].d, label .. ": the map accepts a report only through the world")
	end
	observe(M1, 61, w1, w2)
	observe(M2, 61, w3)
	check(C1.minutes == 1 and C2.minutes == 0 and M1.minutes == 0,
		label .. ": two witnesses grant one minute only to the observed player; a companion cannot start the timer")
	observe(M2, 91, w3)
	check(C1.minutes == 1 and C2.minutes == 1 and M2.minutes == 0,
		label .. ": the other player has an independent timer")

	w1._comm = "dolg"
	w2._squad = { id = 99 }
	M1.env.axr_companions.companion_squads[99] = true
	-- A non-seeing NPC and a companion cannot credit a due minute.
	w1._sees[500] = nil
	observe(M1, 122, w1, w2)
	check(C1.minutes == 1, label .. ": loss of sight and companion squads award nothing")
	w1._sees[500], w1._comm = true, "bandit"
	M1.env.game_relations.is_factions_enemies = function(a, b) return a == "dolg" and b == "bandit" end
	observe(M1, 122, w1)
	check(C1.minutes == 1, label .. ": an enemy of the disguise awards nothing")
	w1._comm = "stalker"
	local zone = "bar_arena_surge_hide_a1"
	M1.env.db.zone_by_name[zone] = { inside = function() return true end }
	observe(M1, 122, w1)
	check(C1.minutes == 1, label .. ": arena observation awards nothing")
	M1.env.db.zone_by_name[zone] = nil
	report(C1, false)
	observe(M1, 122, w1)
	check(C1.minutes == 1, label .. ": observation without a disguise awards nothing")
	report(C1, true)
	M1.options["gameplay/disguise/state"] = false
	observe(M1, 122, w1)
	check(C1.minutes == 1, label .. ": disabled disguise awards nothing")
	M1.options["gameplay/disguise/state"] = true
	observe(M1, 122, w1)
	check(C1.minutes == 2 and C2.minutes == 1, label .. ": a later eligible interval credits exactly once")
end

for _, set in ipairs(modes.names()) do
	reset_world()
	if set == "none" then
		local M = boot(set, 0)
		civil_kill(M, 610, { id = 0 }, "bandit")
		check(M.reputation == 100, "single player: original ZCP reputation applies to the actor")
		local E = M.env
		E.utils_data = {}
		local disguise = load_mod(E, "gameplay_disguise")
		disguise.increment_disguise_statistic(E.game.get_game_time())
		M.game_ms = 61000
		disguise.increment_disguise_statistic(E.game.get_game_time())
		check(M.minutes == 1, "single player: the original disguise statistic still applies")
	elseif set == "hostplay" then
		local H, C1, C2 = boot(set, 0), boot(set, 1), boot(set, 2)
		place(H, 1)
		place(H, 2)
		civil_case(set, H, C1, C2, { id = 500 })
		disguise_case(set, H, H, C1, C2)
	elseif set == "srv_world" then
		local H, C1, C2 = boot(set, 0), boot(set, 1), boot(set, 2)
		-- The death arrives with an ALife killer record. The world has no online body.
		civil_case(set, H, C1, C2, { id = 500, community = function() return "dolg" end })
	else
		for _, split in ipairs({ false, true }) do
			reset_world()
			local label = set .. (split and "/two maps" or "/one map")
			local H = boot("srv_world", 0)
			local C1, C2 = boot("srv_world", 1), boot("srv_world", 2)
			local M1 = boot(set, bridge, split and 1 or nil)
			local M2 = split and boot(set, bridge + 1, 2) or M1
			place(M1, 1)
			place(M2, 2)
			local killer = { id = 500, community = function() return "dolg" end }
			civil_kill(M1, 610, killer)
			check(M1.reputation == 0 and C1.reputation == 0, label .. ": the world owns the ZCP squad death")
			civil_case(label, H, C1, C2, killer)
			disguise_case(label, M1, M2, C1, C2)
		end
	end
end

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
