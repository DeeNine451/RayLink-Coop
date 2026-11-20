-- Run the real Overview binding over two player rows and simple text controls.
dofile("tests/lua/support/menu_stubs.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function labels(names)
	local out = {}
	for _, name in ipairs(names) do
		out[name] = { SetText = function(self, text) self.text = text end }
	end
	return out
end

return function(host, split)
	coop = {
		is_active = function() return true end,
		is_host = function() return host end,
		is_client = function() return not host end,
		players = function()
			return { { id = 0, nick = "Host", level = 22 }, { id = 2, nick = "Bob", level = split and 22 or nil } }
		end,
		levels = {
			split = function() return split end,
			level_of_player = function(peer) if peer == 0 then return 33 end end,
		},
	}
	game = { translate_string = function(id)
		if id == "st_coop_dbg_player_line" then return "%s | %s | %s | %s | %s" end
		if id == "st_coop_dbg_v_none" then return "-" end
		return id
	end }
	db = {}
	level = { name = function() return "l01_escape" end }
	modes.live(load_module("coop_mode"), load_module)
	load_module("coop_debug_client")
	local ui = load_module("coop_debug_ui")
	local overview = {
		c_target = { vals = labels({ "name" }) },
		c_items = { lines = {} },
		c_place = { vals = labels({ "level", "pos", "lvid", "gvid", "dir" }) },
		c_near = { vals = labels({ "name", "section", "id", "dist" }) },
		c_players = { lines = labels({ 1, 2 }) },
		c_world = { vals = labels({ "time", "factor", "weather", "emission", "psi" }) },
	}
	ui.UICoopDebug.BindOverview(overview)
	return overview.c_players.lines, overview.c_place.vals.level.text
end
