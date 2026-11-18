-- Anomaly Coop Lua tests: the facade coop_mode under the test answer sets (docs\MODES.md sections 4 and 10). Not shipped.
--
-- A Core script behaves the same in both modes: its test runs under every set, and the facade answers what the set
-- says, whatever the coop.* stubs say. Sets: tests\lua\support\mode_<set>.lua
--   hostplay   the co-op host's process
--   srv_world  the world server of the server mode (no player's map; requests go to the map server BRIDGE)
--   srv_map    a map server (requests only through the world server, with the player's peer)
--   none       no session: every layer is taken out of the facade, which answers its own "none"
-- COOP_LUA_MODE names the set(s) to run (one name, or several separated by blanks or commas); unset or "all": every
-- set. tools\test_lua.cmd runs a test that uses this file once per set with COOP_LUA_MODE set.
--
--   local modes = dofile("tests/lua/support/modes.lua")
--   for _, name in ipairs(modes.names()) do
--       modes.install(coop_mode, name)            -- the facade answers as the set
--       ...
--   end
--   modes.each(coop_mode, function(name, set) ... end)   -- the same loop
--   modes.live(coop_mode, load)   -- the real layers (coop_hostplay_mode, coop_srv_mode) over the coop.* stubs, as
--                                 -- axr_main installs them in the game; load(name) -> the loaded script module
local M = {}
M.SETS = { "hostplay", "srv_world", "srv_map", "none" }
local KNOWN = { hostplay = true, srv_world = true, srv_map = true, none = true }
local DIR = "tests/lua/support/"
local LAYERS = { "coop_hostplay_mode", "coop_srv_mode" }

-- The sets COOP_LUA_MODE names, in the order of M.SETS; every set when it is unset, empty or "all".
function M.names(value)
	local env = value
	if env == nil then env = os.getenv("COOP_LUA_MODE") end
	local want = {}
	local any = false
	for word in tostring(env or ""):gmatch("[^%s,]+") do
		word = word:lower()
		if word == "all" then
			any = false
			want = {}
			break
		end
		if not KNOWN[word] then error("COOP_LUA_MODE: no answer set '" .. word .. "' (hostplay, srv_world, srv_map, none, all)") end
		want[word] = true
		any = true
	end
	local out = {}
	for _, name in ipairs(M.SETS) do
		if not any or want[name] then out[#out + 1] = name end
	end
	return out
end

-- A fresh copy of a set; `overrides` (optional) replaces answers: { where = function(peer) ... end, ... }.
function M.set(name, overrides)
	if not KNOWN[name] then error("no answer set '" .. tostring(name) .. "'") end
	local set = dofile(DIR .. "mode_" .. name .. ".lua")
	for k, v in pairs(overrides or {}) do set[k] = v end
	return set
end

-- The facade answers as the set: both layers out, then the set's layer in ("none" puts none in). Returns the set.
function M.install(facade, name, overrides)
	assert(type(facade) == "table" and facade.install and facade.uninstall, "modes.install: not the coop_mode facade")
	local set = M.set(name, overrides)
	facade.uninstall("hostplay")
	facade.uninstall("srv")
	if name ~= "none" then assert(facade.install(set), "modes.install: the facade refused the set " .. name) end
	return set
end

-- fn(name, set) under every set COOP_LUA_MODE names.
function M.each(facade, fn, overrides)
	for _, name in ipairs(M.names()) do fn(name, M.install(facade, name, overrides)) end
end

-- The real layers, installed by their own on_game_start as axr_main does in the game. load(name) -> module; by default
-- the harness's loader (load_script of stubs_mods.lua, load_script_file of stubs.lua).
function M.live(facade, load)
	load = load or rawget(_G, "load_script") or rawget(_G, "load_script_file")
	assert(type(load) == "function", "modes.live: no script loader")
	facade.uninstall("hostplay")
	facade.uninstall("srv")
	for _, name in ipairs(LAYERS) do
		local m = load(name)
		assert(type(m) == "table" and type(m.on_game_start) == "function", "modes.live: " .. name .. " did not load")
		m.on_game_start()
	end
end

return M
