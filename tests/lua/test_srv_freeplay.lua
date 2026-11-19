-- Dev 57 G15-2 / s41:1: the stock effect reports its map, and the world owns the outcome.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local CHOICE = "st_freeplay_text_yes_no"
local ACK = "st_freeplay_text_ok"
local STAY = "pri_a28_actor_in_zone_stay"
local LEAVE = "pri_a28_actor_in_zone_leave"
local ROSTER = { { id = 1, level = 4 }, { id = 2, level = 9, avatar_id = 502 }, { id = 3, level = 9, avatar_id = 503 } }

local function stock(M)
	M.shown, M.writes = {}, {}
	M.env.ui_freeplay_dialog = { show = function(kind, title) M.shown[#M.shown + 1] = { kind, title } end }
	M.env.xr_effects.show_freeplay_dialog = function(actor, npc, p)
		if p[1] and p[2] == "true" then
			M.env.ui_freeplay_dialog.show("message_box_yes_no", p[1])
		elseif p[1] then
			M.env.ui_freeplay_dialog.show("message_box_ok", p[1])
		end
	end
	M.actor.give_info_portion = function(_, flag)
		M.writes[#M.writes + 1] = flag
		M.infos[flag] = true
	end
end

local function adapter(M)
	local path = io.open("gamedata/scripts/coop_srv_freeplay.script", "r")
	if not path then return end -- red run uses the real stock effect without a server adapter
	path:close()
	load_script(M, "coop_srv_freeplay").on_game_start()
end

local function server(mode, peer)
	local M = machine(mode == "srv_map" and "client" or "host", peer)
	M.players = ROSTER
	local e = M.env
	e.coop.is_dedicated = function() return mode == "srv_world" end
	e.coop.is_map_server = function() return mode == "srv_map" end
	e.coop.peer_of_avatar = function(id)
		for _, player in ipairs(ROSTER) do if player.avatar_id == id then return player.id end end
	end
	e.game_graph = function() return { vertex = function(_, gv) return { level_id = function() return gv end } end } end
	e.coop_npc_logic = { user_of = function(npc) return npc and npc._user end }
	e.coop_npc_players = { peer_of = function(actor_or_id)
		local id = type(actor_or_id) == "table" and actor_or_id:id() or actor_or_id
		return e.coop.peer_of_avatar(id)
	end }
	modes.install(load_script(M, "coop_mode"), mode, {
		where = function(id)
			if mode == "srv_map" and (id == 2 or id == 3) then return "here" end
			return "away"
		end,
	})
	load_script(M, "coop_mods_core")
	load_script(M, "coop_trust").reset_for_test({ default = "log" })
	stock(M)
	local file = io.open("gamedata/scripts/coop_quests_freeplay.script", "r")
	if file then
		file:close()
		load_script(M, "coop_quests_freeplay").on_game_start()
	end
	adapter(M)
	return M
end

local function receive(M, name, from, data)
	local handler = M.handlers["mods." .. name]
	if handler then handler(M.env.coop_main.encode(data), from) end
end

local function ask_target(M, index)
	local sent = M.sent[index or 1]
	return sent and sent.name == "mods.fp_ask" and sent.target
end

for _, mode in ipairs({ "hostplay", "none" }) do
	local M = machine("host", 0)
	M.active = mode ~= "none"
	modes.install(load_script(M, "coop_mode"), mode)
	load_script(M, "coop_mods_core")
	stock(M)
	local original = M.env.xr_effects.show_freeplay_dialog
	adapter(M)
	M.env.xr_effects.show_freeplay_dialog(M.actor, nil, { CHOICE, "true" })
	check(M.env.xr_effects.show_freeplay_dialog == original and #M.shown == 1 and M.shown[1][2] == CHOICE and #M.sent == 0,
		mode .. ": stock show_freeplay_dialog opens on the local player")
end

MACHINES, QUEUE = {}, {}
local world = server("srv_world", 0)
local scene = world.new_obj(601, "pri_a28_sr_evac", nil, { _gv = 9 })
local trigger = world.new_obj(503, "actor", nil, { _gv = 9 })
world.env.xr_effects.show_freeplay_dialog(trigger, scene, { CHOICE, "true" })
check(ask_target(world) == 3 and #world.shown == 0, "world: triggering player chosen over earlier roster entries")
receive(world, "fp_answer", 2, { id = CHOICE, answer = "stay" })
check(#world.writes == 0, "world: other player on the same map cannot set the flag")
receive(world, "fp_answer", 3, { id = CHOICE, answer = "leave" })
receive(world, "fp_answer", 3, { id = CHOICE, answer = "stay" })
world.env.xr_effects.show_freeplay_dialog(trigger, scene, { CHOICE, "true" })
check(#world.writes == 1 and world.writes[1] == LEAVE and #world.sent == 1,
	"world: Leave applied once even across repeated effects and answers")

MACHINES, QUEUE = {}, {}
world = server("srv_world", 0)
local map = server("srv_map", 0x101)
scene = map.new_obj(601, "pri_a28_sr_evac", nil, { _gv = 9, _user = 503 })
-- The engine gives the world the transport sender. An ordinary player may never report a scene.
receive(world, "fp_offer", 1, { id = CHOICE, level = 9, peer = 1 })
local trust = world.env.coop_trust.status().fp_offer
check(#world.sent == 0 and trust and trust.failed == 1, "world: a player's forged map report is checked and ignored")
map.env.xr_effects.show_freeplay_dialog(map.actor, scene, { CHOICE, "true" })
pump()
check(ask_target(world) == 3 and #map.shown == 0 and #world.shown == 0,
	"map: recorded user receives the question through the world, which opens no window")
receive(world, "fp_answer", 3, { id = CHOICE, answer = "stay" })
check(#world.writes == 1 and world.writes[1] == STAY and #map.writes == 0,
	"map: Stay changes the world registry on the world server only")

MACHINES, QUEUE = {}, {}
world = server("srv_world", 0)
map = server("srv_map", 0x101)
scene = map.new_obj(601, "pri_a28_sr_evac", nil, { _gv = 9 })
map.env.xr_effects.show_freeplay_dialog(map.actor, scene, { ACK })
pump()
check(ask_target(world) == 2, "split maps: timer picks first seated player on the scene's map")
receive(world, "fp_answer", 2, { id = ACK, answer = "stay" })
check(#world.writes == 1 and world.writes[1] == STAY, "split maps: OK resumes the scene through the stock Stay flag")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
