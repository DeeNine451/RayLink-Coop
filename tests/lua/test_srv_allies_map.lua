-- Dev 57 S5: the client uses coop_mode.where for location and its offline
-- ALife copy for the PDA spot. Exercise the real HUD, codec and marker scripts.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local levels = load_script("coop_srv_levels")

local PEER, AVATAR = 2, 502
local friend = { id = PEER, nick = "Scout", avatar_id = AVATAR, level = 2 }
local rows = { { id = 1, is_self = true, avatar_id = 0, level = 1 }, friend }
local spots, moves = {}, 0
local update_hud
function RegisterScriptCallback(name, fn)
	if name == "actor_on_update" then update_hud = fn end
end
coop.players = function() return rows end
coop.spot_is_local = function() return true end
coop.levels = {
	my_level = function() return "l01_escape" end,
	level_of_player = function(peer) return peer == PEER and "l02_garbage" or nil end,
	far_place = function(id, x, y, z, node, graph)
		assert(SE[id] and not OBJ[id], "far_place needs an offline record")
		SE[id].position = vec3(x, y, z)
		SE[id].m_level_vertex_id, SE[id].m_game_vertex_id = node, graph
		moves = moves + 1
	end,
}
game.translate_string = function(id)
	if id == "st_coop_levels_elsewhere" then return "On another map: %s" end
	if id == "l02_garbage" then return "Garbage" end
	return id
end
level.present = function() return true end
level.map_has_object_spot = function(id, kind) return spots[id] and spots[id].kind == kind and 1 or 0 end
level.map_add_object_spot = function(id, kind, hint)
	assert(SE[id], "the engine needs an ALife record for an object spot")
	assert(not spots[id], "duplicate player spot")
	spots[id] = { kind = kind, hint = hint, at_graph = SE[id].m_game_vertex_id }
end
level.map_remove_object_spot = function(id) spots[id] = nil end
level.map_change_spot_hint = function(id, _, hint) spots[id].hint = hint end
CScriptXmlInit = function() return { ParseFile = function() end, NodeExist = function() return true end } end

-- The actor callback also opens a party window. The engine owns its rendering.
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base, __call = function() return {} end }) end
end
function get_hud() return { AddDialogToRender = function() end, RemoveDialogToRender = function() end } end

levels.on_game_start()
modes.each(facade, function(name, set)
	if name ~= "srv_world" and name ~= "srv_map" then return end
	rows[2], friend.elsewhere, SE[AVATAR], OBJ[AVATAR], moves = friend, nil, nil, nil, 0
	local main = load_script("coop_main")
	-- The server layer's answer for a mirror that sees its friend on another
	-- map. Keep the engine's private elsewhere field out of the HUD fixture.
	local where = "away"
	set.where = function(peer) return peer == PEER and where or "here" end
	coop.is_player = set.actor_is_player
	local map = load_script("coop_allies_map")
	local hud = load_script("coop_core_hud")
	hud.on_game_start()
	local function update()
		NOW = NOW + 250
		update_hud()
	end

	main.on_event("core.status", main.encode({ h = 1, s = "alive", x = 12, y = 3, z = -25, l = 171, g = 82 }), PEER)
	local record = spawn("stalker", vec3(0, 0, 0), nil, { id = AVATAR, offline = true })
	update()
	check(not next(spots) and moves == 0, "the headless server does not place PDA spots")
	SE[AVATAR] = nil
	coop.is_player = function() return true end
	update()
	check(spots[AVATAR] == nil and moves == 0, "away friend without an ALife record has no PDA spot")
	SE[AVATAR] = record
	update()
	local spot = spots[AVATAR]
	check(spot and spot.kind == "coop_ally_2", "away friend receives one PDA spot on his offline record")
	check(spot and spot.hint:find("Scout", 1, true) and spot.hint:find("On another map: Garbage", 1, true),
		"away friend has his nick and destination in the PDA hint")
	check(spot and spot.at_graph == 82 and record.m_level_vertex_id == 171 and record.position.x == 12
		and record.position.y == 3 and record.position.z == -25, "first spot uses the reported position on the destination graph")
	check(moves == 1, "the pending placement applies when the mirror record arrives")
	update()
	check(moves == 1 and spots[AVATAR] == spot, "unchanged status neither relocates nor duplicates the spot")

	where, friend.elsewhere = "here", true
	update()
	check(spots[AVATAR] == nil, "no far mark once the mode says here and the online avatar is still loading")
	local _, online = spawn("stalker", vec3(6, 0, 0), nil, { id = AVATAR })
	online.character_icon = function() return "" end
	update()
	spot = spots[AVATAR]
	check(spot and spot.kind == "coop_ally_2" and not spot.hint:find("On another map", 1, true) and moves == 1,
		"the online avatar gets the local mark without another far placement")
	rows[2] = nil
	update()
	check(not next(spots) and map.placed_count() == 0, "disconnect removes the friend's mark")
end)

local function verify_stand_probe()
	local path = "tools/stand/coop_zz_allymark.script"
	local file = io.open(path, "rb")
	if file then file:close() else path = "temp/stand/coop_zz_allymark.script" end
	local now, where, local_obj, marker, graph_level = 1000, "here", {}, false, 1
	local logs, update = {}, nil
	local env = setmetatable({
		command_line = function() return "-coop_probe allyobserver" end,
		printf = function(_, line) logs[#logs + 1] = line end,
		get_console = function() return { execute = function() end } end,
		time_global = function() return now end,
		db = { actor = {} },
		coop = {
			is_live = function() return true end,
			players = function() return { { id = 2, nick = "allymover", avatar_id = AVATAR } } end,
			levels = { level_of_player = function() return 2 end, level_name = function() return "l02_garbage" end },
		},
		coop_mode = { where = function() return where end, is_player_mirror = function() return true end },
		level = {
			name = function() return "l01_escape" end,
			object_by_id = function() return local_obj end,
			map_has_object_spot = function() return marker and 1 or 0 end,
			map_get_object_spot_static = function() return marker and {} or nil end,
		},
		alife_object = function() return { m_game_vertex_id = 82 } end,
		game_graph = function()
			return {
				valid_vertex_id = function() return true end,
				vertex = function() return { level_id = function() return graph_level end } end,
			}
		end,
		coop_core_hud = { views = function() return {}, { [AVATAR] = { far = true, elsewhere = "Garbage", state = "alive" } } end },
		RegisterScriptCallback = function(_, fn) update = fn end,
	}, { __index = _G })
	setfenv(assert(loadfile(path)), env)()
	env.on_game_start()
	update()
	check(logs[1] == "[allymark] both players on l01_escape", "SS observer records the shared starting map")
	where, local_obj = "away", nil
	now = now + 1500
	update()
	check(#logs == 1, "SS observer waits until the engine registers a PDA spot")
	marker, now = true, now + 1500
	update()
	check(#logs == 1, "SS observer rejects a spot whose record is still on the old map")
	graph_level, now = 2, now + 1500
	update()
	check(#logs == 1, "SS observer waits for a stable spot")
	now = now + 1500
	update()
	check(logs[2] == "[allymark] PDA spot confirmed: observer=l01_escape friend=l02_garbage id=502",
		"SS observer reports the stable spot on the friend's new map")
end

local set = os.getenv("COOP_LUA_MODE")
if set ~= "hostplay" and set ~= "none" then verify_stand_probe() end

done("SRV_ALLIES_MAP")
