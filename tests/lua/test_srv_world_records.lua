-- Dev 57 G16-4: two map authorities and a world save, using the real share transport.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function stock(M, name)
	local file = name .. ".script"
	local path = "temp/review/corpus/merged/" .. file
	local f = loadfile(path)
	if not f then f = assert(loadfile("../anomaly-ref/unpacked/scripts/" .. file)) end
	local mod = setmetatable({}, { __index = M.env })
	M.env[name] = mod
	setfenv(f, mod)()
	return mod
end

local ESCAPE, GARBAGE = "l01_escape", "l02_garbage"
local bridges = { { bridge = 256, level = 1 }, { bridge = 257, level = 2 } }
local function boot(mode, peer, map)
	local M = machine(mode == "none" and "single" or mode == "srv_map" and "client" or "host", peer,
		{ [0] = 0, [1] = 500 })
	local e = M.env
	e.xr_effects, e.xr_conditions = {}, {}
	e.debug_cmd_list = { command_get_list = function() return {} end }
	M.game_ms, M.start_ms = 100000, 90000
	local sample = e.game.get_game_time()
	local ct = getmetatable(sample)
	function ct:setHMSms(h, m, s, ms) self.ms = ((h * 60 + m) * 60 + s) * 1000 + ms end
	function ct:add(other) self.ms = self.ms + other.ms end
	function ct:sub(other) self.ms = math.max(0, self.ms - other.ms) end
	e.game.CTime = function() return setmetatable({ ms = 0 }, ct) end
	e.utils_data = {
		CTime_to_table = function(t)
			return { Y = 2012, M = 5, D = 1, h = 0, m = math.floor(t.ms / 60000),
				s = math.floor(t.ms / 1000) % 60, ms = t.ms % 1000 }
		end,
		CTime_from_table = function(t)
			local result = e.game.CTime()
			result:setHMSms(t.h, t.m, t.s, t.ms)
			return result
		end,
	}
	e.level.get_start_time = function() return setmetatable({ ms = M.start_ms }, ct) end
	e.level.name = function() return assert(map, "the world has no player's map") end
	e.coop.is_map_server = function() return mode == "srv_map" end
	e.coop.is_dedicated = function() return mode == "srv_world" end
	e.coop.is_mirror = function() return false end
	e.coop.levels = {
		split = function() return mode == "srv_map" or mode == "srv_world" end,
		map_servers = function() return bridges end,
	}
	e.alife = function() return { level_name = function(_, id) return ({ ESCAPE, GARBAGE })[id] end } end
	e.alife_object = function(id)
		local o = M.objects[id]
		return o and { id = id, position = o:position(), parent_id = 65535,
			section_name = function() return o:section() end }
	end
	e.alife_create = function(section, pos)
		M.created = (M.created or 899) + 1
		M.add(make_obj(M.created, pos.x, pos.y, pos.z, { _section = section }))
		return { id = M.created }
	end
	M.add(make_obj(500, 10, 0, 0))
	e.printdbg = function() end
	e.strformat = string.format
	e.size_table = function(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
	e.game_relations = { is_factions_enemies = function(a, b) return a == "army" and b == "stalker" end }
	e.news_manager = { send_tip = function() M.tips = (M.tips or 0) + 1 end }
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	load_script(M, "coop_mods_core")
	load_script(M, "coop_trust")
	e.coop_trust.reset_for_test({ default = "log" })
	load_script(M, "coop_quests_core")
	load_script(M, "coop_npc_players")
	stock(M, "xr_bribe")
	M.original_at_peace = e.xr_bribe.at_peace
	e.xr_bribe.on_game_start()
	load_script(M, "coop_npc_world").on_game_start()
	load_script(M, "coop_quests_missions").on_game_start()
	load_script(M, "coop_srv_levels_share").on_game_start()
	-- Establish the broken stock behavior before the new adapter exists.
	local f = io.open("gamedata/scripts/coop_srv_world_records.script", "r")
	if f then
		f:close()
		load_script(M, "coop_srv_world_records").on_game_start()
	end
	return M
end

local function cycle()
	NOW = NOW + 1001
	for _, M in pairs(MACHINES) do M.fire("actor_on_update") end
	pump()
end

local function converge()
	for _ = 1, 4 do cycle() end
end

local function save(M)
	local md = {}
	M.fire("save_state", md)
	return md
end

local function plant(M, mode)
	local msg = M.env.coop_main.encode({ _peer = 1, s = "mine_new", m = mode, d = 10, x = 10, y = 0, z = 0 })
	for _, handler in ipairs(M.handlers["npc.mine"] or {}) do handler(msg, 0) end
	return M.objects[M.created]
end

local function mirror_mine(M, id)
	return M.add(make_obj(id, 10, 0, 0, { _section = "mine_new_blow" }))
end

print("== mine_restore_after_world_load_and_map_restart")
reset_world()
local W = boot("srv_world", 0)
local A = boot("srv_map", 256, ESCAPE)
local B = boot("srv_map", 257, GARBAGE)
converge()
local timed = assert(plant(A, 1), "existing map plant route must work")
local prox = assert(plant(A, 0), "existing map plant route must work")
local removed = assert(plant(A, 0), "existing map plant route must work")
local id, prox_id = timed:id(), prox:id()
converge()
local function saved_mine(id)
	local book = save(W).coop_srv_world_mines
	return book and book.maps[ESCAPE] and book.maps[ESCAPE][id]
end
check(saved_mine(id) and saved_mine(removed:id()), "map reports live mines to the world save")

print("== malformed_snapshot_preserves_live_rows")
local codec = W.env.coop_quests_core
local malformed = codec.ser({ v = 1, mines = { [-1] = {} } })
local wire = W.env.coop_main.encode({ k = "srv_world_mines_v1", s = 99, n = 1, i = 1, d = malformed })
for _, handler in ipairs(W.handlers.coop_share) do handler(wire, 256) end
local trust = W.env.coop_trust.status().srv_world_mine_row
check(trust and trust.failed == 1, "invalid map snapshot goes through the trust check")
check(saved_mine(id), "invalid snapshot leaves the previous valid records in place")
A.objects[removed:id()] = nil
converge()
check(not saved_mine(removed:id()), "release of an undetonated charge also removes its world record")
local saved = save(W)
W = boot("srv_world", 0)
W.fire("load_state", saved)
A = boot("srv_map", 256, ESCAPE)
A.start_ms, A.game_ms = 145000, 150000
-- A share snapshot may arrive before the mine entities have finished spawning.
converge()
local timed_copy, prox_copy = mirror_mine(A, id), mirror_mine(A, prox_id)
local unrelated = mirror_mine(B, id)
converge()
local mine = A.env.coop_npc_world._mines()[id]
check(mine and mine.mode == 1 and mine.planter == 500, "world save restores timer mode and planter on the new map server")
check(B.env.coop_npc_world._mines()[id] == nil and not unrelated._exploded, "the other map never imports this charge")
check(not timed_copy._exploded and not prox_copy._exploded, "both triggers wait for the original game-time deadline")
A.game_ms = 161000
cycle()
check(timed_copy._exploded == true, "timer expires on the original game clock after the new level start")
check(prox_copy._exploded == true, "proximity mine checks the nearby player after the same deadline")

print("== mine_delete_survives_map_restart")
converge()
local deleted = save(W).coop_srv_world_mines
check(deleted and not deleted.maps[ESCAPE], "map reports the deletion of its final live mine")
A = boot("srv_map", 256, ESCAPE)
local remnant = mirror_mine(A, id)
A.game_ms = 300000
converge()
check(A.env.coop_npc_world._mines()[id] == nil and not remnant._exploded, "an exploded charge is not armed again if its entity remains")

print("== bribe_distance_cancel_propagates")
reset_world()
W, A, B = boot("srv_world", 0), boot("srv_map", 256, ESCAPE), boot("srv_map", 257, GARBAGE)
W.env.xr_bribe.set_bribe("army", 100, 86400)
converge()
check(B.env.xr_bribe.at_peace("army", "stalker", 121) == true, "existing bribe down sync reaches another map")
check(A.env.xr_bribe.at_peace("army", "stalker", 100) == false and A.tips == 1, "stock breaks the truce at the distance threshold")
converge()
check(save(W).bribe.army == nil, "distance cancel removes the world save record")
check(not B.env.xr_bribe.at_peace("army", "stalker", 121), "existing bribe down sync spreads the removal")
A = boot("srv_map", 256, ESCAPE)
converge()
check(not A.env.xr_bribe.at_peace("army", "stalker", 121), "a replacement map does not pick up the canceled bribe")

print("== late_bribe_cancel_does_not_erase_renewal")
W.env.xr_bribe.set_bribe("army", 100, 86400)
converge()
A.env.xr_bribe.at_peace("army", "stalker", 100)
W.game_ms = W.game_ms + 1000
W.env.xr_bribe.set_bribe("army", 100, 86400)
converge()
check(B.env.xr_bribe.at_peace("army", "stalker", 121) == true, "late cancel applies only to the bribe the map observed")

print("== hostplay_and_single_player_keep_stock")
for _, mode in ipairs({ "hostplay", "none" }) do
	reset_world()
	local M = boot(mode, 0, ESCAPE)
	M.env.xr_bribe.set_bribe("army", 100, 86400)
	check(M.env.xr_bribe.at_peace == M.original_at_peace, mode .. ": stock distance check is untouched")
	check(M.env.xr_bribe.at_peace("army", "stalker", 100) == false and save(M).bribe.army == nil,
		mode .. ": stock distance cancellation survives in the local save")
	check(next(M.env.coop_quests_core.shared().up) == nil and #sent_named(M, "coop_share") == 0,
		mode .. ": map-to-world transport is inactive")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
