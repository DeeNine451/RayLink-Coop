-- Stand probe coop_zz_companions_srv.script (Server companions_server), the client's talk with the fixture. The map server
-- judges the talk distance (coop_dialog.cpp host_try_lock, kTalkReach 6 m) on its copy of the body, drawn 100 ms behind the
-- client's states and moved once a frame. b57l: the probe teleported beside the NPC and asked 250 ms later, the map server
-- still saw the body where it stood ("talk lock ... too far"), and the probe never asked again: "the actual talk did not
-- open" 10 s later. The probe asks once its body has stood still, asks again as a player presses F again, and still fails
-- (never hangs) when no talk opens.
local path = "tools/stand/coop_zz_companions_srv.script"
local passed, failed = 0, 0

local function check(ok, label)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. label)
	end
end

local Vec = {}
Vec.__index = Vec
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
function Vec:set(x, y, z) self.x, self.y, self.z = x, y, z; return self end
function Vec:distance_to(o)
	local dx, dy, dz = self.x - o.x, self.y - o.y, self.z - o.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts.lag_ms: how far behind the map server's copy of the body is; opts.grant(try, server_distance) -> the map server's
-- answer; opts.walk: metres the NPC moves away on every tick.
local function fixture(opts)
	local f = { now = 0, log = {}, callbacks = {}, talking = false, tries = 0, server_distances = {} }
	f.npc_pos = vec(6.5, 0, 0)
	f.track = { { at = -100000, pos = vec(0, 0, 0) } }
	local lag = opts.lag_ms or 400
	local function body_now() return f.track[#f.track].pos end
	local function body_on_server()
		local pos = f.track[1].pos
		for _, s in ipairs(f.track) do
			if s.at <= f.now - lag then pos = s.pos end
		end
		return pos
	end
	local npc = {
		alive = function() return true end,
		position = function() return vec(f.npc_pos.x, f.npc_pos.y, f.npc_pos.z) end,
		is_talk_enabled = function() return true end,
		is_talking = function() return f.talking end,
		id = function() return 2 end,
	}
	local actor = {
		position = function() local p = body_now(); return vec(p.x, p.y, p.z) end,
		set_actor_position = function(_, v) f.track[#f.track + 1] = { at = f.now, pos = vec(v.x, v.y, v.z) } end,
		run_talk_dialog = function()
			f.tries = f.tries + 1
			local d = body_on_server():distance_to(f.npc_pos)
			f.server_distances[#f.server_distances + 1] = d
			if (opts.grant or function(_, dist) return dist <= 6 end)(f.tries, d) then f.talking = true end
		end,
		is_talking = function() return f.talking end,
		stop_talk = function() f.talking = false end,
	}
	local vertices = {}
	local e = setmetatable({
		command_line = function() return "bin\\AnomalyCoopDX11AVX.exe -coop_probe cmp_srv -coop_connect 127.0.0.1:27991" end,
		RegisterScriptCallback = function(name, fn) f.callbacks[name] = fn end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		time_global = function() return f.now end,
		get_console = function() return { execute = function() end } end,
		getFS = function() return { update_path = function(_, _, name) return name end } end,
		io = { open = function() return { read = function() return "travel 1 2 3 l01_escape" end, close = function() end } end },
		vector = function() return vec() end,
		level = {
			name = function() return "l01_escape" end,
			object_by_id = function(id) return id == 2 and npc or nil end,
			vertex_id = function(at) vertices[#vertices + 1] = vec(at.x, at.y, at.z); return #vertices end,
			vertex_position = function(id) local v = vertices[id]; return vec(v.x, v.y, v.z) end,
		},
		db = { actor = actor },
		coop = {
			is_live = function() return true end,
			is_dedicated = function() return false end,
			is_map_server = function() return false end,
			to_local_id = function(id) return id end,
		},
		coop_mode = { when_srv = function(fn) fn() end },
		dialogs_axr_companion = { become_actor_companion = function() f.hired = true end },
		coop_npc_companions = { held_here = function() return false end },
	}, { __index = _G })
	e._G = e
	setfenv(assert(loadfile(path)), e)()
	e.on_game_start()
	function f.tick(ms)
		f.now = f.now + (ms or 50)
		if opts.walk and f.now % 250 == 0 then f.npc_pos.z = f.npc_pos.z + opts.walk end
		f.callbacks.actor_on_update()
	end
	function f.run(ms) for _ = 1, ms / 50 do f.tick() end end
	function f.has(fragment)
		for _, line in ipairs(f.log) do
			if line:find(fragment, 1, true) then return true end
		end
		return false
	end
	return f
end

-- 1. b57l: the map server's copy of the body is 400 ms behind (100 ms of interpolation and a slow frame); the NPC stands
-- 6.5 m from where the body was.
local late = fixture({ lag_ms = 400 })
check(late.callbacks.actor_on_update ~= nil, "the client role is armed")
late.run(30000)
check(late.track[2] ~= nil and late.track[2].pos:distance_to(late.npc_pos) <= 2.5, "the client steps beside the NPC")
check(late.server_distances[1] ~= nil and late.server_distances[1] <= 6,
	"the first ask comes when the map server's copy of the body stands beside the NPC (it saw "
		.. tostring(late.server_distances[1]) .. " m)")
check(late.has("client requested recruit npc=2") and late.hired, "the talk opens and the recruit is asked")
check(not late.has("FAIL"), "no failure")

-- 2. The map server refuses the first ask anyway (a lost or refused answer): the client asks again, as a player would.
local again = fixture({ lag_ms = 150, grant = function(try) return try >= 2 end })
again.run(30000)
check(again.tries == 2, "a refused ask is asked again once (" .. again.tries .. " asks)")
check(again.has("client requested recruit npc=2") and not again.has("FAIL"), "the second ask opens the talk")

-- 3. The map server never grants: the probe still fails with the same words, within the cap, after several asks.
local never = fixture({ lag_ms = 150, grant = function() return false end })
never.run(30000)
check(never.has("the actual talk did not open"), "no talk at all still fails the probe")
check(never.tries >= 3, "after several asks (" .. never.tries .. ")")
check(not never.hired, "and asks no recruit")

-- 4. An NPC that walks away for good (the client steps after it every tick, never stands still): a failure, no hang.
local walker = fixture({ lag_ms = 150, walk = 3 })
walker.run(30000)
check(walker.has("the actual talk did not open"), "an NPC that never stands still fails the probe within its cap")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
