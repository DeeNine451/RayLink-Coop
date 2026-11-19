-- F4 G8-1b (m07:2): exercise the enabled G.A.M.M.A. ZCP 1.4 Balanced Spawns seek rule and generic_update
-- (sim_squad_scripted.script:267-274,333-407) under the modded exes' wrapper. With Survival off, the stock actor
-- rejects target 0. An eligible squad in seek range leaves its stay and selects a smart again on every update.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

load_script("coop_main")
for _, n in ipairs(MODE_FILES) do load_script(n) end
load_script("coop_mods_core")
for _, n in ipairs(MODE_FILES) do _G[n].on_game_start() end

local ADAPTER = "coop_npc_sim_target"

local SQUAD_SRC = [[
local function get_help_target_id(squad)
	if (smr_amain_mcm.get_config("smr_enabled") and smr_zombies_mcm.get_config("seek_enabled") and squad.online and squad.dist_to_actor <= smr_zombies_mcm.get_config("seek_distance")) then
		if (squad.player_id == "zombied" or is_squad_monster[squad.player_id]) then
			return 0
		end
	end
	return squad.task_target_id
end

sim_squad_scripted = {}

function sim_squad_scripted:generic_update() -- This update is called for all squads with no scripted assigned target
	if (self.__lock) then
		return -- so that squad doesn't continously try to find target which lowers FPS
	end

	local forced_id = get_help_target_id(self)
	self.assigned_target_id = forced_id or self.assigned_target_id or self.current_target_id

	if (self.current_action) then

		-- in such case assigned is changed (such as get_help_target_id) but current action is 1 (reached)
		if (self.current_action == 1 and self.assigned_target_id ~= self.current_target_id) then
			self.current_action = 0
		end

		local se_target = self.assigned_target_id == self.id and self or simulation_objects.get_server_entity(self.assigned_target_id)
		-- Evaluate current assigned target; make sure it is still valid
		if (se_target and se_target:target_precondition(self,true)) then
			-- If current action is not finished, then return

			if (self.smart_id ~= self.assigned_target_id and se_target:clsid() == clsid.smart_terrain) then
				sim_board.get_sim_board():assign_squad_to_smart(self, se_target.id)
			end

			if (self.current_action == 0) then
				if (se_target:am_i_reached(self)) then
					se_target:on_after_reach(self)
					self.current_target_id = self.assigned_target_id
					self.current_action = 1
					self.stay_time = game.get_game_time()
				end
				return
			elseif (self.current_action == 1 and self.current_target_id == self.assigned_target_id) then
				if (forced_id) then
					return -- infinite stay time
				end
				if (se_target.locked == true) or (self.stay_time and game.get_game_time():diffSec(self.stay_time) < self.idle_time) then
					return
				end
			end
		end
	end

	-- Find a new target
	local target = SIMBOARD:get_squad_target(self) or SIMBOARD:get_squad_target(self,false,true)
	if not (target) then
		self:on_reach_target(self)
		self.assigned_target_id = nil
		self.current_target_id = nil
		self.task_target_id = nil
		self.current_action = nil
		self.__lock = db.actor and db.actor.afterFirstUpdate -- keep trying until first update
		return
	end

	target:on_reach_target(self)

	self.assigned_target_id = target.id
	self.current_target_id = nil
	self.task_target_id = nil
	self.current_action = 0

	local sim = alife()
	for k in self:squad_members() do
		local se_obj = alife_object(k.id)
		if (se_obj) then
			SIMBOARD:setup_squad_and_group(se_obj)
		end
	end
end

function sim_squad_scripted:get_current_task() -- called from engine
	local se_target = self.assigned_target_id and simulation_objects.get_server_entity(self.assigned_target_id)
	if (se_target) then
		local npc_info = se_target.npc_info and se_target.npc_info[self:commander_id()]
		if (npc_info and npc_info.job) then
			return npc_info.job.alife_task or se_target:get_alife_task() or self:get_alife_task()
		end
		return se_target:get_alife_task()
	end
	return self:get_alife_task()
end

function sim_squad_scripted:get_alife_task()
	return CALifeSmartTerrainTask(self.m_game_vertex_id, self.m_level_vertex_id)
end

-- engine\gamedata\scripts\aaaa_script_fixes_mp.script:554-563 (the modded exes), at load
do
	local sq = sim_squad_scripted
	local orig_generic_update = sq.generic_update
	function sq.generic_update(self, ...)
		if self:npc_count() == 0 then
			return
		end
		return orig_generic_update(self, ...)
	end
end
]]

local function load_fake(name, src)
	local this = setmetatable({}, { __index = _G })
	rawset(_G, name, this)
	local f = assert(loadstring(src, "@" .. name .. ".script"))
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

-- se_actor.script:62-113, the actor as a simulation target
local ACTOR_RULES = {}
function ACTOR_RULES:get_alife_task() return CALifeSmartTerrainTask(self.m_game_vertex_id, self.m_level_vertex_id) end
function ACTOR_RULES:target_precondition(squad) return IsSurvivalMode() end

clsid = { smart_terrain = 1 }
CALifeSmartTerrainTask = function(gvid, lvid) return { gvid = gvid, lvid = lvid } end
is_squad_monster = { monster_dog = true }
function IsSurvivalMode() return false end
smr_amain_mcm = { get_config = function(k) return k == "smr_enabled" end }
SEEK = true
smr_zombies_mcm = { get_config = function(k)
	if k == "seek_enabled" then return SEEK end
	if k == "seek_distance" then return 250 end
end }
LEVEL_OF = { [8] = 1, [21] = 1, [22] = 2, [23] = 1, [31] = 1 } -- game vertex -> level
function game_graph()
	return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF[gv] end } end }
end

local SMART = { id = 3000, locked = true }
function SMART:clsid() return clsid.smart_terrain end
function SMART:target_precondition() return true end
function SMART:am_i_reached() return false end
function SMART:on_after_reach() end
function SMART:on_reach_target(squad)
	squad.reselections = (squad.reselections or 0) + 1
	squad.reselection_distance = squad.dist_to_actor
end
function SMART:get_alife_task() return CALifeSmartTerrainTask(50, 51) end
SIMBOARD = { get_squad_target = function() return SMART end, setup_squad_and_group = function() end }
sim_board = { get_sim_board = function() return { assign_squad_to_smart = function() end } end }

local SIM, ACTOR, A, original_task, original_entity -- per boot

-- A fresh world. host_x: the place of this process's actor (the host, or a ghost on a server), also its se_actor record.
local function boot(set, host_x)
	SE, OBJ, NEXT_ID = {}, {}, 1000
	db = { storage = {} }
	coop.is_map_server = function() return set == "srv_map" end
	coop.is_dedicated = function() return set == "srv_world" end
	coop.players = function()
		if MODE == "sp" then return {} end
		return { { id = 0, nick = "hoster", is_self = true, avatar_id = 0 }, { id = 1, nick = "joiner", avatar_id = 500 } }
	end
	MODE = set == "none" and "sp" or "host"
	SEEK = true -- opt in to SMR seek, which is off in the default profile
	make_actor(vec3(host_x, 0, 0))
	ACTOR = setmetatable({ id = 0, position = vec3(host_x, 0, 0), m_game_vertex_id = 8, m_level_vertex_id = 7 },
		{ __index = ACTOR_RULES })
	local registry = { [0] = ACTOR, [SMART.id] = SMART }
	simulation_objects = { get_server_entity = function(id) return registry[id] end }
	alife = function()
		return { actor = function() return ACTOR end, object = function(_, id) return SE[id] end }
	end
	SIM = load_fake("sim_squad_scripted", SQUAD_SRC)
	original_task = SIM.sim_squad_scripted.get_current_task
	original_entity = simulation_objects.get_server_entity
	rawset(_G, "coop_npc_players", nil)
	load_script("coop_npc_players")
	A = load_adapter()
	if A then A.on_game_start() end
	return SIM
end

-- A player's character as an online body here: place x on game vertex gv (level LEVEL_OF[gv]).
local function body(id, x, gv)
	local _, o = spawn("coop_player_avatar", vec3(x, 0, 0), nil, { id = id, kind = "stalker" })
	o.game_vertex_id = function() return gv end
	return o
end

-- Only the record of a player's character (a world server: his body is on a map server's map).
local function record(id, x, gv, dead)
	local se = spawn("coop_player_avatar", vec3(x, 0, 0), nil, { id = id, offline = true })
	se.m_game_vertex_id = gv
	se.alive = function() return not dead end
	return se
end

local next_squad = 9000
local function squad(x, player_id, gv)
	next_squad = next_squad + 1
	local s = { id = next_squad, position = vec3(x, 0, 0), m_game_vertex_id = gv or 8, m_level_vertex_id = 1,
		player_id = player_id or "zombied", online = true, idle_time = 100, smart_id = SMART.id,
		current_action = 1, assigned_target_id = SMART.id, current_target_id = SMART.id }
	function s:npc_count() return 1 end
	function s:squad_members()
		local done = false
		return function() if not done then done = true return { id = s.id + 1 } end end
	end
	function s:on_reach_target() end
	return setmetatable(s, { __index = SIM.sim_squad_scripted })
end

-- ZCP update() measures to sim:actor() before calling generic_update.
local function update(s, times)
	for _ = 1, times or 1 do
		NOW = NOW + 1
		s.dist_to_actor = s.position:distance_to(alife():actor().position)
		s:generic_update()
	end
	return s:get_current_task()
end

local function stays(s)
	return not s.reselections and s.current_action == 1 and s.assigned_target_id == SMART.id
end

local function reselects(s, times, distance)
	return s.reselections == times and s.reselection_distance == distance
		and s.current_action == 0 and s.assigned_target_id == SMART.id
end

modes.each(coop_mode, function(set)
	print("== " .. set)
	if set == "hostplay" then
		boot(set, 1000)
		body(500, 10, 21)
		local z = squad(20)
		update(z, 5)
		check(reselects(z, 5, 10), set .. ": 10 m from client, 980 m from host: a settled squad reselects every update")
		check(z.dist_to_actor == 980, set .. ": distance to the host is restored")
		check(SIM.sim_squad_scripted.get_current_task == original_task
			and simulation_objects.get_server_entity == original_entity
			and simulation_objects.get_server_entity(0) == ACTOR,
			set .. ": the mod keeps its task and entity lookup")

		local near_host = squad(990)
		update(near_host, 5)
		check(reselects(near_host, 5, 10), set .. ": a squad near the host reselects in the same way")

		body(501, 30, 23)
		coop.players = function()
			return { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 }, { id = 2, avatar_id = 501 } }
		end
		local mid = squad(35)
		update(mid)
		check(reselects(mid, 1, 5), set .. ": of two clients the nearer one sets the distance")

		local mutants = squad(20, "monster_dog")
		update(mutants)
		check(reselects(mutants, 1, 10), set .. ": an online mutant squad uses the same distance")
		local task_squad = squad(20, "stalker")
		task_squad.task_target_id = SMART.id
		update(task_squad)
		check(stays(task_squad) and task_squad.task_target_id == SMART.id, set .. ": a non-seeking squad keeps its task")

		SEEK = false
		local calm = squad(20)
		update(calm)
		check(stays(calm) and calm.dist_to_actor == 980, set .. ": seek off: squad stays and keeps the stock distance")
		SEEK = true
		local offline = squad(20)
		offline.online = false
		update(offline)
		check(stays(offline), set .. ": an offline squad does not use seek")

		modes.install(coop_mode, set, { is_player_mirror = function() return true end,
			leads_here = function() return false end, decides_world = function() return false end })
		local copy = squad(20)
		update(copy)
		check(stays(copy), set .. ": the client mirror uses the stock distance")
		modes.install(coop_mode, set)

		local quiet = squad(20)
		quiet.npc_count = function() return 0 end
		update(quiet)
		check(stays(quiet), set .. ": the modded exes' wrapper still skips a squad with no members")

		local select_target = SIMBOARD.get_squad_target
		SIMBOARD.get_squad_target = function() error("target selection failed", 0) end
		local broken = squad(20)
		local ok, err = pcall(update, broken)
		SIMBOARD.get_squad_target = select_target
		check(not ok and err == "target selection failed" and broken.dist_to_actor == 980,
			set .. ": the original error propagates after the stock distance is restored")
	elseif set == "srv_map" then
		boot(set, 25) -- the ghost stands 5 m from the squad
		local player = body(500, 300, 21)
		local far = squad(20)
		update(far)
		check(stays(far) and far.dist_to_actor == 5, set .. ": the ghost cannot interrupt a stay; its distance is restored")

		player._pos = vec3(40, 0, 0)
		local near = squad(20)
		update(near, 5)
		check(reselects(near, 5, 20) and near.dist_to_actor == 5,
			set .. ": the player of this map interrupts the stay on every update")

		player.game_vertex_id = function() return 22 end
		local other = squad(20)
		update(other)
		check(stays(other), set .. ": a player of another map cannot interrupt a stay")
		player.game_vertex_id = function() return 21 end

		player._alive = false
		local dead = squad(20)
		update(dead)
		check(stays(dead), set .. ": a dead body cannot interrupt a stay")
		player._alive = true

		modes.install(coop_mode, set, { where = function(peer) return peer == 1 and "joining" or "away" end })
		local joining = squad(20)
		update(joining)
		check(stays(joining), set .. ": a joining player cannot interrupt a stay even with a local body")
	elseif set == "srv_world" then
		boot(set, 25)
		local player = record(500, 60, 21)
		local z = squad(20)
		update(z, 5)
		check(reselects(z, 5, 40) and z.dist_to_actor == 5,
			set .. ": when only the record exists, use its distance on the squad's map and restore the stock distance")

		player.m_game_vertex_id = 22
		local other = squad(20)
		update(other)
		check(stays(other), set .. ": a record on another map cannot interrupt a stay")
		player.m_game_vertex_id = 21

		player.alive = function() return false end
		local dead = squad(20)
		update(dead)
		check(stays(dead), set .. ": a dead record cannot interrupt a stay")
		player.alive = function() return true end

		modes.install(coop_mode, set, { where = function(peer) return peer == 1 and "joining" or "away" end })
		local joining = squad(20)
		update(joining)
		check(stays(joining), set .. ": a joining player's record cannot interrupt a stay")
	else -- none: single player
		boot(set, 1000)
		body(500, 10, 21)
		local far = squad(20)
		update(far, 5)
		check(stays(far) and far.dist_to_actor == 980, set .. ": a nearby NPC does not change the stock seek distance")

		local near = squad(990)
		update(near, 5)
		check(reselects(near, 5, 10) and near.dist_to_actor == 10, set .. ": close to the actor, stock ZCP reselects")
	end
end)

-- Absent pieces: start never throws (axr_main runs on_game_start unprotected).
do
	modes.install(coop_mode, "hostplay")
	rawset(_G, "sim_squad_scripted", nil)
	local saved = simulation_objects
	simulation_objects = nil
	local fresh = load_adapter()
	local ok, err = pcall(function() if fresh then fresh.on_game_start() end end)
	check(fresh ~= nil and ok, "no sim_squad_scripted / simulation_objects: start does not throw" .. (ok and "" or (": " .. tostring(err))))
	simulation_objects = saved
end

done("npc_sim_target")
