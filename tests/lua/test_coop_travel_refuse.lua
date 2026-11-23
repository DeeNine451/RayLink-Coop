-- #444: the real Fair Fast Travel row handler calls the Co-op hook before spending or moving.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
local refusal = "Localized group move refusal"
local fare = 500

local filename = "temp/review/corpus/merged/game_fast_travel.script"
local file = io.open(filename, "r")
if not file then
	filename = "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/game_fast_travel.script"
	file = assert(io.open(filename, "r"))
end
local source = file:read("*a")
file:close()
local first = assert(source:find("function map_spot_menu_property_clicked(", 1, true))
local last = assert(source:find("\nend%s*\n", first))
local row_source = source:sub(first, last + 3)

local function setup(peer, role)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "client", proxy = 501 } }
	POS = { [0] = vec(0, 0, 0), [1] = vec(2, 0, 0) }
	WORLDS, QUEUE = {}, {}
	local W = make_world(peer)
	W.ACTIVE = role ~= "none"
	W.coop.levels = { split = function() return role == "srv_client" end }
	W.coop.is_dedicated = function() return role == "srv_world" end
	W.coop.is_map_server = function() return role == "srv_map" end
	modes.live(load_script(W, "coop_mode"), function(script) return load_script(W, script) end)
	W.SendScriptCallback = function(callback, ...) fire(W, callback, ...) end
	local translate = W.game.translate_string
	W.game.translate_string = function(id)
		if id == "st_coop_core_go_host_only" then return refusal end
		if id == "st_fftd_mapspot_guideto" then return "Hire guide to" end
		return translate(id)
	end

	local gear = add_item(W, 10, "wpn_test", 0)
	local local_point = add_entity(W, 11, "smart_test", nil, vec(100, 0, 0))
	local far_point = add_entity(W, 12, "smart_test", nil, vec(200, 0, 0))
	far_point.online, far_point.m_game_vertex_id = false, 20
	W.ChangeLevel = function(_, _, gid) W.CHANGED = gid end
	local trip_cfg = { loc = {}, map = {} }
	local function yes() return true end
	local function noop() end
	local fft = setmetatable({
		td = { ft = trip_cfg, gt = trip_cfg },
		basecfg = { ft = {}, gt = {} },
		dup_table = function(cfg) return cfg end,
		actor_in_travel_zone = yes, combat_travel_ok = yes, weight_travel_ok = yes,
		damage_travel_ok = yes, storm_travel_ok = yes, guide_travel_ok = yes,
		validate_dest_position = function(dest) return dest.position end,
		get_map_hazard_coef = function() return 1 end,
		get_trip_distance = function() return { dist = 100 } end,
		travel_cost_coef = function() return 1 end,
		cost_to_travel = function() return fare end,
		charge_for_travel = function(cost) W.db.actor:give_money(-cost) end,
		damage_gear_condition = function() gear:set_condition(0.8) end,
		advance_trip_time = noop, travel_cooldown_enabled = function() return false end,
		hide_pda = noop, bring_companions_to_actor = noop,
	}, { __index = W })
	fft.reset_trip_data = function() fft.trip = { ret_value = true, paid = false } end
	W.game_fast_travel = fft
	local preamble = [[
local dl, vl = function() end, function() end
local menu_options = {
	["Travel to Far"] = { valid = true, tt = "ft" },
	["Hire guide to Far"] = { valid = true, tt = "gt" },
	["Travel to Nearby"] = { valid = true, tt = "ft" },
}
]]
	setfenv(assert(loadstring(preamble .. row_source, "@" .. filename)), fft)()
	W.pda = { property_box_clicked = function(ui, id, map)
		return fft.map_spot_menu_property_clicked(ui, id, map, ui:GetSelectedItem():GetTextItem():GetText())
	end }
	for _, script in ipairs({ "coop_economy_core", "coop_economy_group", "coop_economy_travel" }) do
		local mod = load_script(W, script)
		if mod.on_game_start then mod.on_game_start() end
	end
	load_script(W, "coop_hostplay_travel").on_game_start()
	local function select_row(text, point, map)
		local item = { GetText = function() return text end }
		local row = { GetTextItem = function() return item end }
		return W.pda.property_box_clicked({ GetSelectedItem = function() return row end }, point.id, map)
	end
	return W, gear, local_point, far_point, select_row
end

if name == "hostplay" then
	local W, gear, local_point, far_point, select_row = setup(1, "client")
	check(W.coop_economy_core.others_count() == 1, "the Coop client travels with one other player in the session")
	for _, text in ipairs({ "Travel to Far", "Hire guide to Far" }) do
		local money, condition, tips = W.MONEY, gear.cond, #W.TIPS
		select_row(text, far_point, "l02")
		check(W.MONEY == money and gear.cond == condition and not W.CHANGED,
			text .. ": refused before fare, wear and ChangeLevel")
		check(#W.TIPS == tips + 1 and W.TIPS[#W.TIPS] == refusal, text .. ": shows the translated refusal")
	end
	local money, tips = W.MONEY, #W.TIPS
	check(select_row("Travel to Nearby", local_point, LEVEL) and POS[1].x == local_point.position.x,
		"the Coop client's same-map row still moves")
	check(W.MONEY == money - fare and gear.cond == 0.8 and #W.TIPS == tips,
		"the Coop client's same-map row still pays the fare and wears gear")
end

local peer = name == "srv_map" and 1 or 0
local role = name == "srv_map" and "srv_client" or name
local W, gear, _, far_point, select_row = setup(peer, role)
check(select_row("Travel to Far", far_point, "l02") and W.CHANGED == far_point.m_game_vertex_id,
	name .. ": the original row reaches the level-change API")
check(W.MONEY == 10000 - fare and gear.cond == 0.8 and #W.TIPS == 0,
	name .. ": the original row pays the fare and wears gear")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
