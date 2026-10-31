-- Anomaly Coop lane L3 test support (not shipped): harness_npc's two machines, plus what the coop_world_* scripts use:
-- a coop.sync of one session (session scope, effects with a radius), module tables like CScriptStorage's, a console.
dofile("tests/lua/support/harness_npc.lua")

local SYNC = { store = {} }
local casts = {}

local function clone(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = x end
	return t
end

local function install_sync(M)
	local E = M.env
	M.effects = {}
	E.coop.sync = {
		set = function(scope, key, value)
			if M.role ~= "host" then return false, "not allowed" end
			SYNC.store[scope .. "/" .. key] = clone(value)
			M.sync_sets = (M.sync_sets or 0) + 1
			return true
		end,
		get = function(scope, key) return clone(SYNC.store[scope .. "/" .. key]) end,
		on = function(name, fn) M.effects[name] = fn return true end,
		broadcast = function(name, args, opts)
			if M.role ~= "host" then return false, "host only" end
			casts[#casts + 1] = { name = name, args = clone(args), opts = opts }
			M.casts = (M.casts or 0) + 1
			return true, 1
		end,
	}
end

-- A host and one client, numbered like test_npc_a (client proxy 500, the pair 0 / 500 swapped on the client).
function world_pair()
	reset_world()
	SYNC.store, casts = {}, {}
	local H = machine("host", 0, { [0] = 0, [1] = 500 })
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	local function swap(id) if id == 0 then return 500 elseif id == 500 then return 0 end return id end
	C.to_host, C.to_local = swap, swap
	for _, M in ipairs({ H, C }) do
		install_sync(M)
		M.console = {}
		M.env.get_console_cmd = function(typ, name) return M.console[name] end
		M.env.exec_console_cmd = function(cmd)
			M.cmds = M.cmds or {}
			M.cmds[#M.cmds + 1] = cmd
			local name, value = cmd:match("^(%S+)%s+(.*)$")
			if name then M.console[name] = value end
		end
		M.env.P_stub = nil
		load_script(M, "coop_npc_players")
	end
	return H, C
end

-- Delivers the coop.sync effects to every client whose character is inside the radius, the way l_broadcast does (the host
-- gets nothing here: no script of this lane listens on it), then the events.
function world_pump()
	local list = casts
	casts = {}
	for _, c in ipairs(list) do
		for _, M in pairs(MACHINES) do
			local fn = M.effects[c.name]
			local near = true
			if c.opts and c.opts.pos and M.role == "client" then
				near = M.env.db.actor:position():distance_to(c.opts.pos) <= c.opts.radius
			end
			if fn and M.role == "client" and near then fn(c.args, 0) end
		end
	end
	return pump()
end

function run_timers(M)
	local list = M.timers or {}
	M.timers = {}
	for _, t in ipairs(list) do t.f(unpack(t.p)) end
end
