-- G2-2: exercise the real settings snapshot, delta and overlay with distinct consoles.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
load_coop_main()
local encode, decode = coop_main.encode, coop_main.decode
local modes = dofile("tests/lua/support/modes.lua")

local CVAR = "g_progressive_stamina_cost"
local PATH = "modded_exes/gameplay/gameplay_general/" .. CVAR
local WIRE_KEY = "o|" .. PATH
local SAVE_KEY = "coop_progressive_stamina_cost"

local function load_script(w, name, optional)
	local path = "gamedata/scripts/" .. name .. ".script"
	local file = io.open(path, "r")
	if optional and not file then return end -- the regression can run against the tree before the adapter exists
	assert(file, path)
	local src = file:read("*a")
	file:close()
	local module = setmetatable({}, { __index = w })
	module.this = module
	w[name] = module
	local chunk = assert(loadstring(src, "@" .. path))
	setfenv(chunk, module)()
	return module
end

local function make_world(set, peer, cvar, saved, level_name, stash)
	local w = setmetatable({}, { __index = _G })
	w._G = w
	w.peer, w.level_name, w.cvar, w.state = peer, level_name, cvar, saved or {}
	w.active, w.now, w.sent, w.callbacks, w.handlers = set ~= "none", 100000, {}, {}, {}
	w.stash = stash or {}
	w.commands, w.config_saves, w.players = {}, {}, {}
	w.db = { actor = {} }
	w.printf = function() end
	local console = {}
	function console:get_integer(name)
		assert(name == CVAR)
		return w.cvar
	end
	function console:execute(command)
		w.commands[#w.commands + 1] = command
		local v = command:match("^" .. CVAR .. " ([01])$")
		assert(v, "unexpected console command " .. command)
		w.cvar = tonumber(v)
	end
	w.get_console = function() return console end
	w.exec_console_cmd = function(command)
		if command == "cfg_save" then
			w.config_saves[#w.config_saves + 1] = w.cvar
		else
			console:execute(command)
		end
	end
	w.coop = {
		is_active = function() return w.active end,
		is_live = function() return w.active end,
		is_host = function() return w.active and peer == 0 end,
		is_client = function() return w.active and peer ~= 0 and set ~= "srv_map" end,
		is_dedicated = function() return set == "srv_world" end,
		players = function() return w.players end,
		send_event = function(name, payload, target)
			w.sent[#w.sent + 1] = { name = name, payload = payload, target = target }
			return true
		end,
		stash_get = function(k) return w.active and w.stash[k] or nil end,
		stash_set = function(k, v) w.stash[k] = v; return true end,
		game = { set_cvars = function() error("the Lua adapter must not use the engine whitelist") end },
	}
	w.coop_main = {
		encode = encode, decode = decode,
		add_event_handler = function(name, fn)
			w.handlers[name] = w.handlers[name] or {}
			table.insert(w.handlers[name], fn)
		end,
	}
	w.time_global = function() return w.now end
	w.RegisterScriptCallback = function(name, fn)
		w.callbacks[name] = w.callbacks[name] or {}
		table.insert(w.callbacks[name], fn)
	end
	w.SendScriptCallback = function(name, ...)
		for _, fn in ipairs(w.callbacks[name] or {}) do fn(...) end
	end
	w.alife_storage_manager = { get_state = function() return w.state end }
	w.ini_file_ex = {
		collect_section = function(self, section)
			local result = {}
			for k, v in pairs(self.data[section] or {}) do result[k] = v end
			return result
		end,
		r_value = function(self, section, key) return (self.data[section] or {})[key] end,
		w_value = function(self, section, key, value) self.data[section][key] = value end,
		save = function() end,
	}
	w.axr_main = { config = setmetatable({ data = { options = {}, mcm = {} } }, { __index = w.ini_file_ex }) }

	local facade = load_script(w, "coop_mode")
	local answers = { applies = function() return w.active end }
	if w.coop.is_client() then
		answers.decides_world = function() return false end
		answers.actor_is_player = function() return true end
		answers.leads_here = function() return false end
		answers.is_player_mirror = function() return true end
	end
	modes.install(facade, set, answers)
	load_script(w, "coop_mods_core")
	load_script(w, "coop_settings").on_game_start()
	local adapter = load_script(w, "coop_settings_cvars", true)
	if adapter then adapter.on_game_start() end
	w.SendScriptCallback("load_state", w.state)
	return w
end

local function tick(w)
	w.now = w.now + 3500
	w.SendScriptCallback("actor_on_update")
end

local function receive(w, name, payload, peer)
	for _, fn in ipairs(w.handlers[name] or {}) do fn(payload, peer) end
end

local function deliver(from, ...)
	local sent = from.sent
	from.sent = {}
	for _, to in ipairs({ ... }) do
		for _, event in ipairs(sent) do
			if event.target == -1 or event.target == to.peer then
				receive(to, event.name, event.payload, from.peer)
			end
		end
	end
	return sent
end

local function wire_value(events, kind)
	for _, event in ipairs(events) do
		if event.name == "coop_set" then
			local t = decode(event.payload)
			if t._t == kind and t[WIRE_KEY] ~= nil then return t[WIRE_KEY] end
		end
	end
end

local function join(world, player)
	tick(player)
	deliver(player, world)
	return deliver(world, player)
end

local function hostplay()
	local host = make_world("hostplay", 0, 1)
	local client = make_world("hostplay", 1, 0)
	host.players = { { id = host.peer }, { id = client.peer } }
	host.axr_main.config.data.options[PATH] = "0" -- stale AXR data must not be the source
	local first = join(host, client)
	check(wire_value(first, "full") == "1" and client.cvar == 1,
		"co-op join uses effective host 1 rather than stale AXR 0 or client 0")
	check(host.axr_main.config.data.options[PATH] == "0" and client.axr_main.config.data.options[PATH] == nil,
		"the existing settings channel does not write AXR on either player")

	client.exec_console_cmd("cfg_save")
	check(client.config_saves[1] == 0 and client.cvar == 1,
		"the options menu saves the personal value while gameplay keeps the host rule")

	receive(client, "coop_set", encode({ _t = "delta", [WIRE_KEY] = "0" }), 2)
	check(client.cvar == 1, "a different player cannot send a world CVar")
	receive(client, "coop_set", encode({ _t = "delta", [WIRE_KEY] = "0;cfg_save" }), 0)
	check(client.cvar == 1, "a malformed world value cannot become a console command")

	host.cvar = 0
	tick(host)
	check(wire_value(deliver(host, client), "delta") == "0" and client.cvar == 0,
		"the next settings delta carries a live host change to 0")
	host.cvar = 1
	tick(host)
	check(wire_value(deliver(host, client), "delta") == "1" and client.cvar == 1,
		"another host delta applies 1 without recapturing the personal value")

	client.active = false
	tick(client)
	check(client.cvar == 0, "leaving co-op restores the starting CVar without waiting for a new world")
end

local function srv_world()
	local world = make_world("srv_world", 0, 0, { [SAVE_KEY] = 1 })
	local first = make_world("srv_world", 1, 0, nil, "escape")
	local second = make_world("srv_world", 2, 1, nil, "escape")
	world.players = { { id = first.peer, level = first.level_name }, { id = second.peer, level = second.level_name } }
	local snap = join(world, first)
	join(world, second)
	check(wire_value(snap, "full") == "1" and first.cvar == 1 and second.cvar == 1,
		"server uses the stored world rule over its machine default for players on one map")
	check(world.state[SAVE_KEY] == 1 and world.cvar == 1, "startup loads the stored rule into the world console")

	second.level_name = "garbage"
	world.players[2].level = second.level_name
	world.cvar = 0 -- a local administration change on the world server
	tick(world)
	check(wire_value(deliver(world, first, second), "delta") == "0" and first.cvar == 0 and second.cvar == 0,
		"server distributes the changed rule to players on two distinct maps")
	local saved = {}
	world.SendScriptCallback("save_state", saved)
	check(saved[SAVE_KEY] == 0, "the changed world rule is saved as 0")
	local restarted = make_world("srv_world", 0, 1, saved)
	check(wire_value(join(restarted, make_world("srv_world", 3, 1, nil, "garbage")), "full") == "0",
		"server restart uses the persisted 0 over a different machine default")

	-- The actor is destroyed before the old Lua state is discarded on a map load.
	second.SendScriptCallback("actor_on_net_destroy")
	check(second.cvar == 1, "actor teardown restores the player's local console before a map load")
	local reloaded = make_world("srv_world", 2, second.cvar, nil, "garbage", second.stash)
	tick(reloaded)
	check(reloaded.cvar == 0, "the real settings stash reapplies the rule before a new full snapshot")
	reloaded.active = false
	reloaded.SendScriptCallback("actor_on_net_destroy")
	check(reloaded.cvar == 1, "disconnect teardown restores personal 1 without another update")
	first.active = false
	tick(first)
	check(first.cvar == 0, "the first player keeps personal 0 after disconnect")
end

local function srv_map()
	local map = make_world("srv_map", 257, 0)
	map.axr_main.config.data.options[PATH] = "0"
	receive(map, "coop_set", encode({ _t = "full", _s = 1, _i = 1, _n = 1, [WIRE_KEY] = "1" }), 0)
	tick(map)
	local saved = {}
	map.SendScriptCallback("save_state", saved)
	check(map.cvar == 0 and #map.commands == 0, "the map server does not have a player's CVar to override")
	check(#map.sent == 0 and saved[SAVE_KEY] == nil, "the map server neither publishes nor stores the world's rule")
end

local function solo()
	local player = make_world("none", 0, 1)
	player.exec_console_cmd(CVAR .. " 0")
	player.exec_console_cmd("cfg_save")
	player.SendScriptCallback("on_option_change")
	tick(player)
	player.SendScriptCallback("actor_on_net_destroy")
	local saved = {}
	player.SendScriptCallback("save_state", saved)
	check(player.cvar == 0 and #player.commands == 1 and player.config_saves[1] == 0,
		"single player keeps the stock console, options save and actor teardown behavior")
	check(#player.sent == 0 and saved[SAVE_KEY] == nil, "single player sends no settings and adds no world rule")
end

local scenarios = { hostplay = hostplay, srv_world = srv_world, srv_map = srv_map, none = solo }
for _, name in ipairs(modes.names()) do scenarios[name]() end
print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
