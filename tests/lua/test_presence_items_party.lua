-- Dev 57 G8-6. Run the active GAMMA functions alongside the real adapters.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local map_mode = name == "srv_map"
local world_mode = name == "srv_world"
local maps = { [1] = 8, [2] = 8, [3] = 9 }
if map_mode or world_mode then
	coop.is_map_server = function() return map_mode end
	coop.is_dedicated = function() return world_mode end
	coop.levels = {
		split = function() return true end,
		my_level = function() return map_mode and 8 or 1 end,
		level_of_player = function(peer) return maps[peer] end,
		carried = function() return {} end,
	}
	game_graph = function()
		return { vertex = function(_, id) return { level_id = function() return id end } end }
	end
end
coop.players = function()
	if MODE == "sp" then return {} end
	return {
		{ id = 0, is_self = true, avatar_id = 0 },
		{ id = 1, avatar_id = 501 },
		{ id = 2, avatar_id = 502 },
		{ id = 3, avatar_id = 503 },
	}
end
coop.avatar_of = function(peer) return peer == 0 and 0 or 500 + peer end

local actor = make_actor(vec3(0, 0, 0))
local function player(peer, x)
	local se, obj = spawn("coop_player_avatar", vec3(x, 0, 0), nil, { id = 500 + peer, offline = world_mode })
	se.m_game_vertex_id = maps[peer]
	if obj then obj.game_vertex_id = function() return maps[peer] end end
	return se, obj
end
local first_record, first = player(1, 100)
local second_record, second = player(2, 0)
local third_record
if map_mode or world_mode then third_record = player(3, 100) end

local function load_mod(mod)
	local path = "temp/review/corpus/merged/" .. mod .. ".script"
	local file = io.open(path, "rb")
	local gamma = os.getenv("GAMMA_SCRIPTS")
	if not file and gamma then
		path = gamma .. "/" .. mod .. ".script"
		file = io.open(path, "rb")
	end
	assert(file, "active GAMMA script required: " .. path)
	local src = file:read("*a")
	file:close()
	local env = setmetatable({}, { __index = _G })
	local chunk = assert(loadstring(src, "@" .. path))
	setfenv(chunk, env)
	_G[mod] = env
	chunk()
	return env
end

load_script("coop_main").on_game_start()
local facade = load_script("coop_mode")
modes.install(facade, name, map_mode and {
	where = function(peer) return maps[peer] == 8 and "here" or "away" end,
} or nil)
load_script("coop_mods_core").on_game_start()
AddScriptCallback("server_entity_on_unregister")

-- Keep the mod's queue, variant recursion, delayed registration and stock cleanup.
demonized_time_events = { CreateTimeEvent = CreateTimeEvent }
utils_stpk = { get_physic_data = function() return {} end, set_physic_data = function() end }
INI.dropper_bread = { visual = true }
INI.dropper_bread_1 = { visual = true }
function SYS_GetParam(_, section, key) return INI[section] and INI[section][key] end
local vectors = getmetatable(vector())
function vectors:mul(n)
	self.x, self.y, self.z = self.x * n, self.y * n, self.z * n
	return self
end
local create = alife_create
alife_create = function(...)
	local se = create(...)
	OBJ[se.id].force_set_position = function(obj, pos) obj._pos = vector():set(pos) end
	return se
end
local dropper = load_mod("model_dropper_mcm")
dropper.getActorPos = function() return db.actor:position() end
local forced = 0
dropper.apply_force = function() forced = forced + 1 end
dropper.on_game_start()
load_script("coop_mods_items").on_game_start()
SendScriptCallback("actor_on_first_update")

local function cleanup_tick()
	NOW = NOW + 5100
	SendScriptCallback("actor_on_update")
end
local function request_drop(from, payload)
	deliver({ name = "mods.md_drop", payload = coop_main.encode(payload) }, from)
end
local function present(i)
	return CREATED[i] and alife_object(CREATED[i].id) ~= nil
end
local function use_bread()
	dropper.actor_on_item_use({ get_remaining_uses = function() return 0 end }, "bread")
	SendScriptCallback("actor_on_update")
end

if name == "hostplay" then
	request_drop(1, { s = "bread", a = 1 })
	local trust = coop_trust.status().md_drop_model
	check(#CREATED == 0 and trust and trust.failed == 1, "invalid client drop data goes through trust before refusal")
	-- Client drop: stock used to remove it because the host stayed 100 m away.
	request_drop(1, { s = "bread", a = false })
	run_time_events()
	check(#CREATED == 2 and forced == 2 and present(1) and present(2), "client drop and variant get their physics")
	cleanup_tick()
	check(present(1) and present(2), "client debris survives near its owner with the host far away")
	first._pos.x = 165
	coop.life_of = function(id) return id == first:id() and "downed" or "alive" end
	cleanup_tick()
	check(present(1) and present(2), "debris stays with a living downed player at exactly 65 m")
	coop.life_of = nil
	first._pos.x = 166
	cleanup_tick()
	check(not present(1) and not present(2), "client debris goes when all players are outside 65 m")

	-- Host uses the item with another player nearby, then leaves them at the drop.
	use_bread()
	run_time_events()
	actor._pos.x = -100
	cleanup_tick()
	check(present(3) and present(4), "playing host's debris survives near another player")
	second._pos.x = 100
	cleanup_tick()
	check(not present(3) and not present(4) and #RELEASED == 4, "each drop and its variant are cleaned exactly once")
elseif map_mode then
	request_drop(0, { s = "bread", a = false, _peer = 1 })
	run_time_events()
	check(#CREATED == 2 and forced == 2, "a relayed player's drop runs on the map server")
	second._pos.x = 100
	first._pos.x = 170
	cleanup_tick()
	check(present(1) and present(2), "map server keeps debris for a different player on this map")
	second._pos.x = 170
	actor._pos.x = 100
	cleanup_tick()
	check(not present(1) and not present(2) and #RELEASED == 2,
		"debris goes despite a nearby ghost and the same coordinates on another map")
elseif world_mode then
	request_drop(1, { s = "bread", a = false })
	local payload, event = sent("mods.md_drop")
	check(#CREATED == 0 and payload and payload._peer == 1 and event.target == 0x101,
		"world server relays debris creation to the player's map")
else
	use_bread()
	run_time_events()
	check(#CREATED == 2 and forced == 2 and present(1) and present(2), "single player keeps stock spawning and physics")
	actor._pos.x = 100
	cleanup_tick()
	check(not present(1) and not present(2) and #RELEASED == 2, "single player keeps stock cleanup")
end

if not map_mode then
	-- On the world server, model the quest's existing scoped view of the Swamps.
	level.name = function() return "k00_marsh" end
	dynamic_news_helper = { send_tip = function() end }
	xr_conditions, xr_effects, task_status_functor, task_functor = {}, {}, {}, {}
	local pump = load_mod("tasks_pump_station_defense")
	local starts = 0
	pump.start_message = function() starts = starts + 1 end
	local sniper = spawn("sniper", vec3(100, 0, 0), nil, { offline = true })
	local smart = spawn("smart", vec3(0, 0, 0), nil, { offline = true })
	SIMBOARD = { smarts_by_names = { mar_smart_terrain_5_8 = smart } }
	coop_tasks = {
		taker = function() return 1 end,
		with_task_owner = function(_, fn) fn() end,
	}
	task_objects = { CGeneralTask = { check_task = function(tsk)
		tsk.result = task_status_functor.gd_task_status_functor(tsk, tsk.id)
	end } }
	load_script("coop_quests_core")
	if world_mode then load_script("coop_srv_quests_core").on_game_start() end
	load_script("coop_quests_party").on_game_start()
	SendScriptCallback("actor_on_first_update")

	local function task(stage, fields)
		local state = { trigger_pos = { x = 100, y = 0, z = 0 }, trigger_id = sniper.id,
			smart_pos = { x = 0, y = 0, z = 0 }, guards = {} }
		for k, v in pairs(fields or {}) do state[k] = v end
		pump.load_state({ pump_station_def_csky = state })
		local tsk = { t = true, stage = stage, id = "pump_test", current_target = sniper.id,
			status_functor = "gd_task_status_functor" }
		task_objects.CGeneralTask.check_task(tsk)
		return tsk
	end
	actor._pos.x = 0
	first_record.position.x = 100
	second_record.position.x = 0
	if first then first._pos.x, second._pos.x = 100, 0 end

	if name == "none" then
		check(task(2).stage == 2 and starts == 0, "single player still waits for its own actor")
		actor._pos.x = 100
		check(task(2).stage == 3 and starts == 1, "single player starts the attack at the sniper")
	else
		check(task(2).stage == 3 and starts == 1, "stage 2 uses the player at the sniper while another stays at the smart")
		starts = 0
		first_record.position.x = 105
		if first then first._pos.x = 105 end
		check(task(2).stage == 2 and starts == 0, "stage 2 keeps the strict 5 m boundary")
		if world_mode then
			check(third_record.position.x == 100 and task(2).stage == 2, "a player on another map cannot trigger stage 2")
		else
			first._pos.x = 100
			first._alive = false
			check(task(2).stage == 2, "a dead player at the sniper cannot trigger stage 2")
			first._alive = true
			first._pos.x, second._pos.x, actor._pos.x = 0, 0, 100
			check(task(2).stage == 3 and starts == 1, "the playing host can trigger stage 2 while a client is at the smart")
		end
		check(task(1, { before_attack_talk = true }).stage == 2, "stage 1 still advances after the commander talk")
		check(task(3, { attackers_to_spawn = 0, attackers = {} }).stage == 6,
			"stage 3 still uses the smart and completes after the last attacker")
	end
end

done("presence_items_party@" .. name)
