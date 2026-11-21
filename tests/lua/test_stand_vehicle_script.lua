-- Dev 57 F5-VEH-7. Each fixture represents a separate stand process.
local stand_dir = "tools/stand/"
local path = stand_dir .. "coop_zz_vehicle.script"
local passed, failed = 0, 0

local function case(name, test)
	local ok, err = pcall(test)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function fixture(role, wrong_authority)
	local f = { now = 0, commands = {}, lines = {}, online = true, step = "ready",
		actor_pos = {x = 0, y = 0, z = 0}, car_pos = {x = 6, y = 0, z = 0}, body_present = true,
		body_pos = {x = 0, y = 0, z = 0}, car_dir = {x = 1, y = 0, z = 0} }
	local function vec()
		return { set = function(self, x, y, z) self.x, self.y, self.z = x, y, z; return self end }
	end
	local function record(value) f.commands[#f.commands + 1] = value end
	local actor = {
		id = function() return 0 end, alive = function() return true end,
		position = function() return f.actor_pos end,
		attach_vehicle = function(_, car, force) assert(force == true); f.holder = car; record("attach") end,
		get_attached_vehicle = function() return f.holder end,
		set_actor_position = function(_, p) f.actor_pos = {x = p.x, y = p.y - 0.3, z = p.z}; record("teleport") end,
	}
	local physics = {
		IsActiveEngine = function() return f.engine end,
		StartEngine = function() f.engine = true; record("start engine") end,
		GetfFuel = function() return 10 end,
		SetThrottle = function(_, value) record("throttle " .. value) end,
		HandBreak = function() record("brake") end,
	}
	local car = {
		id = function() return 40 end, section = function() return "veh_niva" end,
		position = function() return f.car_pos end, get_car = function() return physics end,
		direction = function() return f.car_dir end,
	}
	local body = {
		id = function() return 71 end, position = function() return f.body_pos end,
		alive = function() return true end, game_vertex_id = function() return 2 end,
	}
	local env = setmetatable({
		command_line = function() return ({h = "-coop_probe vehicle_h", ag = "-coop_probe vehicle_ag",
			map = "-coop_mapserver stand", world = "-coop_probe vehicle_world", other = "-coop_probe ag"})[role] end,
		RegisterScriptCallback = function(event, callback) assert(event == "actor_on_update"); f.update = callback end,
		time_global = function() return f.now end,
		printf = function(fmt, msg) assert(fmt == "%s"); f.lines[#f.lines + 1] = msg end,
		get_console = function() return {execute = function(_, line) if line ~= "flush" then record(line) end end} end,
		getFS = function() return {update_path = function(_, root, leaf)
			assert(root == "$fs_root$" and leaf == "zz_vehicle_step.txt"); return leaf
		end} end,
		io = {open = function() return {read = function() return f.step end, close = function() end} end},
		db = {actor = actor}, vector = vec, rq_result = function() return {} end, rq_target = {rqtStatic = 1},
		key_bindings = {kFWD = 1, kBACK = 2},
		bind_to_dik = function(action, index) assert(index == -1); return ({17, 31})[action] end,
		level = {
			name = function() return "l01_escape" end,
			object_by_id = function(id)
				if id == 71 and f.body_present then return body end
				if id == (role == "ag" and 140 or 40) and f.online then return car end
			end,
			vertex_id = function(pos) f.vertex = pos; return 1 end,
			vertex_position = function() return f.vertex end,
			vertex_game_vertex_id = function() return 2 end,
			ray_pick = function(pos, dir, _, _, result)
				if dir.y == -1 then result.range = pos.y; return true end
				return f.wall and f.wall(pos, dir) or false
			end,
			press_action = function(key) record(assert(({[17] = "forward", [31] = "back"})[key])) end,
			release_action = function(key) record("stop " .. assert(({[17] = "forward", [31] = "back"})[key])) end,
		},
		alife_create = function(section, pos, lv, gv)
			assert(section == "veh_niva" and math.abs(pos.x - (f.spawn_x or 6)) < 0.01 and lv == 1 and gv == 2)
			record("spawn"); return {id = 40}
		end,
		coop = {
			is_live = function() return true end,
			players = function() return f.body_present and {{id = 2, avatar_id = 71, nick = "vehicle_tester"}} or {} end,
			to_host_id = function(id) return id end,
			to_local_id = function(id) return id == 40 and 140 or id end,
			vehicle = {status = function() return f.seat and {car = f.seat_car or 140, seat = f.seat} end,
				attached = function() return f.attached end},
		},
		coop_mode = {
			leads_here = function() return role == "h" or role == "map" or wrong_authority end,
			where = function(id) return id == 2 and "here" or "away" end,
			actor_is_player = function() return not wrong_authority and (role == "h" or role == "ag") end,
			is_player_mirror = function() return role == "ag" end,
		},
	}, {__index = _G})
	local chunk, err = loadfile(path)
	assert(chunk, "vehicle stand probe missing or invalid: " .. tostring(err))
	setfenv(chunk, env)()
	env.on_game_start()
	function f:tick(step, ms)
		self.step = step or self.step
		self.now = self.now + (ms or 250)
		self.update()
	end
	function f:has(value)
		return table.concat(self.lines, "\n"):find(value, 1, true) ~= nil
	end
	return f
end

local function authority(role)
	local f = fixture(role)
	f:tick("drive_sample")
	assert(#f.commands == 0)
	f:tick("ready")
	assert(f:has((role == "h" and "host" or "map") .. " ready map=l01_escape"))
	f:tick("spawn 0.000 0.000 0.000")
	assert(f.commands[1] == "spawn" and f:has("spawned car=40 body=71"))
	f:tick("prepare")
	f:tick(nil, 1000)
	assert(f.commands[2] == "start engine" and f.commands[3] == "coop_status")
	f.car_pos = {x = 12, y = 0, z = 0}
	f:tick("drive_sample")
	assert(f:has("drive moved=6.000") and f:has("along=6.000"))
	f:tick("replica_sample")
	assert(f:has("authority pos=12.000 0.000 0.000"))
	f:tick("driver_clear")
	f:tick("passenger_prepare")
	return f
end

case("Co-op authority spawns, measures and drives with its actor", function()
	local f = authority("h")
	assert(f.holder and f:has("host seated car=40"))
	f:tick("passenger_status")
	f:tick("host_drive")
	-- b57d: the client's drive ends against whatever stands past its lane; the host backs down the lane just driven.
	assert(table.concat(f.commands, "|"):find("throttle 1|back", 1, true) and not f:has("FAIL"))
	f.car_pos = {x = 9, y = 0, z = 0}
	f:tick(nil, 1000)
	assert(not f:has("host moved"))
	-- Released once the car has gone 5 m, before the 3 s are up: it stays on the lane it drove.
	f.car_pos = {x = 6, y = 0, z = 0}
	f:tick(nil, 250)
	assert(f:has("host moved=6.000 pos=6.000 0.000 0.000 along=6.000"))
	assert(table.concat(f.commands, "|"):find("back|stop back|throttle 0|brake", 1, true))
	f:tick("passenger_clear")
	f:tick("reboard_status")
	f.body_present = false
	f:tick("quit")
	assert(f:has("disconnect status") and f.commands[#f.commands] == "coop_status")
end)

case("Server map authority prepares an empty passenger seat and observes disconnect", function()
	local f = authority("map")
	assert(not f.holder and f:has("map passenger ready car=40"))
	f:tick("passenger_status")
	f:tick("host_drive")
	assert(not f:has("host moved"))
	f:tick("passenger_clear")
	f:tick("reboard_status")
	f.body_present = false
	f:tick("disconnect")
	assert(f:has("disconnect status") and f.commands[#f.commands] == "coop_status")
end)

local function host_driving(f)
	f:tick("passenger_status")
	f:tick("host_drive")
end

case("A host drive that pushes the car aside instead of down its lane fails", function()
	-- b57d: the car stood against a face ahead and slid 0.6 m sideways; a 4 m slide must not pass either.
	local f = authority("h")
	host_driving(f)
	f.car_pos = {x = 12, y = 0, z = 4}
	f:tick(nil, 3000)
	assert(f:has("FAIL host_drive") and f:has("host moved=4.000"))
	assert(table.concat(f.commands, "|"):find("stop back|throttle 0|brake", 1, true))
end)

case("A wall in the lane behind the car fails the host drive before any input", function()
	local f = authority("h")
	f.wall = function(_, dir) return dir.x < -0.5 end
	host_driving(f)
	assert(f:has("FAIL host_drive") and f:has("no clear lane"))
	local commands = table.concat(f.commands, "|")
	assert(not commands:find("back", 1, true) and not commands:find("throttle", 1, true))
end)

local function driver()
	local f = fixture("ag")
	f:tick("ready")
	assert(f:has("client placed pos=0.000 0.000 0.000") and #f.commands == 0)
	f.online = false
	f:tick("online 40")
	assert(not f:has("client online"))
	f.online = true
	f:tick()
	assert(f:has("client online car=40 local=140"))
	f:tick("drive")
	assert(#f.commands == 0)
	f:tick("driver")
	assert(f.commands[1] == "coop_vehicle_enter nearest")
	f.seat = 0
	f:tick()
	assert(not f:has("client seated seat=0"))
	f.attached = true
	f:tick()
	assert(f:has("client seated seat=0"))
	f:tick("drive")
	assert(f.commands[2] == "coop_vehicle_drive 0x1 3000")
	return f
end

local function passenger(f)
	f:tick("replica 6.500 0.000 0.000")
	assert(f:has("replica pos=6.000 0.000 0.000 delta=0.500"))
	f:tick("driver_exit")
	f.seat, f.attached = nil, false
	f.actor_pos = {x = 7, y = 0, z = 0}
	f:tick()
	assert(f:has("client exited seat=0 distance=1.000 ground=0.000"))
	f:tick("passenger")
	assert(f.commands[4] == "coop_vehicle_enter 40 1")
	f.seat, f.attached = 1, true
	f:tick()
	assert(f:has("client seated seat=1"))
end

case("Co-op client follows the car then quits while seated", function()
	local f = driver()
	passenger(f)
	f:tick("follow_start")
	f.car_pos, f.actor_pos = {x = 12, y = 0, z = 0}, {x = 13, y = 0, z = 0}
	f:tick("follow_sample")
	assert(f:has("client followed car=6.000 actor=6.000 drift=0.000"))
	f:tick("passenger_exit")
	f.seat, f.attached = nil, false
	f:tick()
	f:tick("reboard")
	f.seat, f.attached = 1, true
	f:tick()
	f:tick("quit")
	assert(f:has("client quit seat=1") and f.commands[#f.commands] == "quit")
end)

case("Server client exits seat 1 without a host ride", function()
	local f = driver()
	passenger(f)
	f:tick("passenger_exit")
	f.seat, f.attached = nil, false
	f:tick()
	assert(f:has("client exited seat=1"))
end)

case("Unrelated roles and the world server never act on a stand instruction", function()
	assert(not fixture("other").update)
	assert(not fixture("world").update)
	local f = fixture("h", true)
	f:tick("ready")
	f:tick("spawn")
	assert(#f.commands == 0 and not f:has("host ready"))
end)

case("A missing driver grant stops after five seconds", function()
	local f = fixture("ag")
	f:tick("ready")
	f:tick("online 40")
	f:tick("driver")
	f:tick(nil, 5001)
	assert(f:has("FAIL driver"))
	f:tick("drive")
	assert(#f.commands == 1)
end)

case("A grant for another car fails without sending drive input", function()
	local f = fixture("ag")
	f:tick("ready")
	f:tick("online 40")
	f:tick("driver")
	f.seat, f.attached, f.seat_car = 0, true, 141
	f:tick()
	assert(f:has("FAIL driver") and #f.commands == 1)
end)

case("A replica more than two metres away fails", function()
	local f = driver()
	f:tick("replica 8.100 0.000 0.000")
	assert(f:has("FAIL replica") and not f:has("] replica pos="))
end)

case("An airborne exit fails even within three metres of the car", function()
	local f = driver()
	f:tick("replica 6.000 0.000 0.000")
	f:tick("driver_exit")
	f.seat, f.attached = nil, false
	f.actor_pos = {x = 6, y = 1.5, z = 0}
	f:tick(nil, 5001)
	assert(f:has("FAIL driver_exit"))
end)

-- A house around the start: static walls within 8 m of the origin.
local function house(f)
	f.wall = function(pos) return pos.x * pos.x + pos.z * pos.z < 64 end
end

case("A client in a house moves itself to open ground before it reports ready", function()
	local f = fixture("ag")
	house(f)
	f:tick("ready")
	assert(#f.commands == 0 and not f:has("client ready"))
	f:tick()
	assert(f.commands[1] == "teleport" and not f:has("client ready"))
	assert(math.abs(f.actor_pos.x - 10) < 0.01 and math.abs(f.actor_pos.z) < 0.01)
	f:tick()
	assert(f:has("client placed pos=10.000 0.000 0.000") and f:has("client ready map=l01_escape"))
end)

case("No open ground within 50 m fails the client ready step", function()
	local f = fixture("ag")
	f.wall = function() return true end
	for _ = 1, 120 do f:tick("ready", 100) end
	assert(f:has("FAIL ready") and f:has("no open ground") and #f.commands == 0)
end)

case("The authority spawns beside the placed spot only after the body arrives", function()
	local f = fixture("h")
	f:tick("ready")
	f.body_pos = {x = 0, y = 0, z = 0}
	f:tick("spawn 10.000 0.000 0.000")
	assert(#f.commands == 0 and not f:has("FAIL"))
	-- Searched from the printed spot, not from the body 0.2 m off it.
	f.body_pos, f.car_pos, f.spawn_x = {x = 10.2, y = 0, z = 0}, {x = 16, y = 0, z = 0}, 16
	f:tick()
	assert(f.commands[1] == "spawn" and f:has("spawned car=40 body=71 distance=5.800"))
end)

case("A body that never reaches the placed spot fails the spawn after ten seconds", function()
	local f = fixture("h")
	f:tick("ready")
	f:tick("spawn 10.000 0.000 0.000")
	f:tick(nil, 10001)
	assert(f:has("FAIL spawn") and f:has("never reached") and #f.commands == 0)
end)

case("A car that does not face its checked lane fails the spawn", function()
	local f = fixture("h")
	f:tick("ready")
	f.car_dir = {x = 0, y = 0, z = 1}
	f:tick("spawn 0.000 0.000 0.000")
	assert(f:has("FAIL spawn") and f:has("car faces"))
end)

case("A drive that leaves its lane sideways fails", function()
	local f = fixture("h")
	f:tick("ready")
	f:tick("spawn 0.000 0.000 0.000")
	f:tick("prepare")
	f:tick(nil, 1000)
	f.car_pos = {x = 6, y = 0, z = 6}
	f:tick("drive_sample")
	assert(f:has("FAIL drive_sample"))
end)

for _, name in ipairs({"vehicle_group", "vehicle_server"}) do
	case(name .. " has its own PASS and step-labelled FAIL output", function()
		local file = assert(io.open(stand_dir .. name .. ".ps1", "r"))
		local source = file:read("*a")
		file:close()
		assert(source:find("Write-Host '" .. name .. ": PASS'", 1, true))
		assert(source:find("Write-Host ('" .. name .. ": FAIL {0}", 1, true))
	end)
end

print(string.format("%d passed, %d failed", passed, failed))
