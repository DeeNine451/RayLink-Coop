-- Dev 57 F5-COV-4. The live stand processes are represented by separate Lua environments.
local tracked = "tools/stand/coop_zz_cover.script"
local file = io.open(tracked, "r")
if file then file:close() end
local path = file and tracked or "temp/stand/coop_zz_cover.script"
local passed, failed = 0, 0

local function check(ok, name)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name)
	end
end

local function fixture(role, map)
	local zone_prefix = map == "l05_bar" and "bar_visitors_surge_hide_a" or "esc_smart_terrain_2_12_surge_hide_a"
	local name = zone_prefix .. "1"
	local f = { log = {}, sent = {}, now = 0, live = true, alive = true, step = "ready",
		position = { x = 30, y = 0, z = 2 }, starts = 0, kills = 0, skips = 0 }
	local function vec()
		return { set = function(self, x, y, z)
			if type(x) == "table" then x, y, z = x.x, x.y, x.z end
			self.x, self.y, self.z = x, y, z
			return self
		end }
	end
	local zone = {
		inside = function(_, pos) return math.abs(pos.x) <= 2 and math.abs(pos.z) <= 2 end,
		position = function() return vec():set(0, 0, 0) end,
	}
	local actor = {
		id = function() return 71 end,
		position = function() return f.position end,
		set_actor_position = function(_, pos) f.position = pos end,
		alive = function() return f.alive end,
	}
	local peer = { id = 2, nick = "cover_tester", avatar_id = 71 }
	local manager = { started = false, covers = { [name] = true },
		init_surge_covers = function() end,
		kill_actor_at_pos = function(_, z) f.kills, f.kill_z = f.kills + 1, z end,
		skip_surge = function(self) f.skips, self.started = f.skips + 1, false end,
	}
	local client, host, world, map_server = role == "coverclient", role == "coverhost", role == "coverworld", role == "map"
	local cover = {
		decide = function() return f.covered end,
		cover_of = function() return f.covered, 0, f.source end,
	}
	local geometry = {
		geometry_ray = function() return { get = function() return { in_contact = false } end } end,
	}
	local env = setmetatable({
		command_line = function()
			if map_server then return "-coop_mapserver fixture" end
			return role and "-coop_probe " .. role or "-coop_probe coverclientother"
		end,
		RegisterScriptCallback = function(event, callback)
			assert(event == "actor_on_update")
			f.update = callback
		end,
		time_global = function() return f.now end,
		printf = function(fmt, ...)
			assert(fmt == "%s")
			f.log[#f.log + 1] = string.format(fmt, ...)
		end,
		get_console = function() return { execute = function(_, line) assert(line == "flush") end } end,
		getFS = function() return { update_path = function(_, root, leaf)
			assert(root == "$fs_root$" and leaf == "zz_cover_step.txt")
			return leaf
		end } end,
		io = { open = function()
			return { read = function() return f.step end, close = function() end }
		end },
		db = { actor = actor, zone_by_name = { [name] = zone } },
		vector = vec,
		level = {
			name = function() return map end,
			object_by_id = function(id) return id == 71 and actor or nil end,
			vertex_id = function(pos) f.vertex = pos; return 1 end,
			vertex_position = function() return vec():set(f.vertex) end,
		},
		coop = {
			is_live = function() return f.live end,
			players = function() return { peer } end,
			send_event = function(verb, payload, to)
				f.sent[#f.sent + 1] = { verb, payload, to }
				return true
			end,
		},
		coop_mode = {
			decides_world = function() return host or world end,
			leads_here = function() return host or map_server end,
			actor_is_player = function() return host or client end,
			is_player_mirror = function() return client end,
			where = function(id) return id == 2 and "here" or "away" end,
		},
		coop_mods_core = {
			mod = function(module)
				if module == "coop_env_cover" then return cover end
				if module == "demonized_geometry_ray" then return geometry end
			end,
			wrap = function(tbl, key, _, make)
				tbl[key] = make(tbl[key])
				return true
			end,
		},
		coop_trust = { mode_of = function() return f.trust or "log" end },
		coop_main = { encode = function(data) return data.c and "true" or "false" end },
		surge_manager = {
			get_surge_manager = function() return manager end,
			start_surge = function() f.starts, manager.started = f.starts + 1, true end,
		},
	}, { __index = _G })
	env._G = env
	local chunk, err = loadfile(path)
	assert(chunk, "stand role script missing or invalid: " .. tostring(err))
	setfenv(chunk, env)()
	env.on_game_start()
	f.env, f.manager, f.cover, f.zone = env, manager, cover, zone
	return f
end

local function step(f, value, delay)
	f.step = value
	f.now = f.now + (delay or 500)
	f.update()
end

local function has(f, literal)
	return table.concat(f.log, "\n"):find(literal, 1, true) ~= nil
end

local function assess(f, covered, source)
	f.covered, f.source = covered, source
	return f.cover.decide(2, f.env.db.actor, nil, "cover_tester", true)
end

local function run(name, fn)
	local ok, err = pcall(fn)
	if not ok then check(false, name .. " (" .. tostring(err) .. ")") end
end

run("probe_is_inert_without_its_role", function()
	local f = fixture(nil, "l01_escape")
	check(not f.update and #f.sent == 0, "probe_is_inert_without_its_role")
end)

run("coop_host_starts_logs_checks_and_skips", function()
	local f = fixture("coverhost", "l01_escape")
	step(f, "ready")
	check(f.starts == 0 and has(f, "host ready"), "coop_host_arms_without_starting")
	step(f, "start")
	step(f, "start")
	check(f.starts == 1 and f.manager.started, "coop_host_uses_stock_start_once")
	check(assess(f, false, "none") == false and has(f, "env_cover: cover_tester open"),
		"coop_host_observes_the_real_open_decision")
	check(assess(f, true, "static") == true and has(f, "env_cover: cover_tester covered (static)"),
		"coop_host_observes_the_real_static_decision")
	step(f, "kill")
	check(f.kills == 0, "coop_kill_probe_waits_for_the_report_decision")
	assess(f, true, "report")
	step(f, "kill")
	check(f.kills == 1 and f.kill_z == f.position.z and has(f, "host kill checked"),
		"coop_host_probes_the_stock_kill_hook_without_targeting_its_own_actor")
	step(f, "skip")
	check(f.skips == 1 and not f.manager.started and has(f, "host skipped"), "coop_host_uses_stock_skip")
end)

run("server_world_runs_the_clock_map_runs_the_cover", function()
	local world = fixture("coverworld", "fake_start")
	local map = fixture("map", "l05_bar")
	world.env.start_emission()
	check(world.starts == 1 and has(world, "world started") and not world.update, "server_world_starts_without_a_map_probe")
	step(map, "start")
	check(map.starts == 0 and has(map, "map ready"), "server_map_does_not_start_the_world_clock")
	map.manager.started = true
	assess(map, false, "none")
	assess(map, true, "static")
	check(has(map, "env_cover: cover_tester open") and has(map, "env_cover: cover_tester covered (static)"),
		"server_map_observes_the_two_body_decisions")
	assess(map, true, "report")
	step(map, "kill")
	check(map.kills == 1 and has(map, "map kill checked"), "server_map_probes_the_stock_kill_hook")
	step(map, "skip")
	world.env.skip_emission()
	check(map.skips == 0 and world.skips == 1 and has(world, "world skipped"), "server_world_owns_the_skip")
end)

for _, map in ipairs({ "l01_escape", "l05_bar" }) do
	run("mirror_walkthrough_" .. map, function()
		local f = fixture("coverclient", map)
		step(f, "ready")
		check(has(f, "client ready map=" .. map) and not f.zone:inside(f.position), map .. "_client_starts_outside")
		step(f, "inside")
		check(not f.zone:inside(f.position), map .. "_client_waits_for_mirrored_emission")
		f.manager.started = true
		step(f, "inside")
		check(f.zone:inside(f.position), map .. "_client_teleports_into_the_listed_zone")
		f.env.coop.send_event("coop_env_cover", "false", 0)
		check(f.sent[1][2] == "false", map .. "_client_does_not_change_reports_before_claim")
		step(f, "outside")
		check(not f.zone:inside(f.position), map .. "_client_returns_outside")
		step(f, "claim")
		f.env.coop.send_event("coop_env_cover", "false", 0)
		f.env.coop.send_event("another_event", "unchanged", 3)
		check(f.sent[2][1] == "coop_env_cover" and f.sent[2][2] == "true" and f.sent[2][3] == 0
			and has(f, "client sent cover claim"), map .. "_client_changes_only_the_report_at_the_transport_boundary")
		check(f.sent[3][1] == "another_event" and f.sent[3][2] == "unchanged" and f.sent[3][3] == 3,
			map .. "_client_leaves_unrelated_events_untouched")
		step(f, "check")
		check(not has(f, "client alive after wave"), map .. "_client_waits_for_kill_delivery")
		step(f, "check", 3000)
		check(has(f, "client alive after wave"), map .. "_client_reports_survival_while_emission_is_active")
		step(f, "skip")
		check(not has(f, "client done"), map .. "_client_waits_for_mirrored_end")
		f.manager.started = false
		step(f, "skip")
		f.env.coop.send_event("coop_env_cover", "false", 0)
		check(has(f, "client done") and f.sent[4][2] == "false", map .. "_client_reports_end_and_stops_injecting")
	end)
end

run("mirror_cannot_pass_after_death", function()
	local f = fixture("coverclient", "l01_escape")
	step(f, "ready")
	f.manager.started = true
	step(f, "inside")
	step(f, "outside")
	step(f, "claim")
	f.env.coop.send_event("coop_env_cover", "false", 0)
	step(f, "check")
	f.alive = false
	step(f, "check", 3100)
	check(has(f, "FAIL") and not has(f, "client alive after wave"), "mirror_cannot_pass_after_death")
end)

print(string.format("%d passed, %d failed", passed, failed))
