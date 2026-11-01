-- World parity sound H1, M3 (coop_world_fight.script): the fighter list of each player, the hit handlers of mods on the
-- attacker's machine; routing R2, R6, R8 (coop_world_compat.script). Run: tools\test_lua.cmd world_fight
dofile("tests/lua/support/harness_world.lua")

local function stock(M)
	local E = M.env
	E.vector = vector
	E.xr_combat_ignore = { fighting_with_actor_npcs = {} }
	E.coop_mods_core = { mod = function(n) return E[n] end }
end

local function tick(H, C)
	NOW = NOW + 1100
	H.fire("actor_on_update")
	C.fire("actor_on_update")
	world_pump()
end

local function stage()
	local H, C = world_pair()
	stock(H)
	stock(C)
	local fighting = {}
	H.env.coop_npc_combat = { _state = function() return { fighting = fighting } end }
	local proxy = H.add(make_obj(500, 0, 0, 0))
	for _, id in ipairs({ 700, 701 }) do
		H.add(make_obj(id, 10, 0, 0))
		C.add(make_obj(id, 10, 0, 0))
	end
	local FH, FC = load_script(H, "coop_world_fight"), load_script(C, "coop_world_fight")
	FH.on_game_start()
	FC.on_game_start()
	H.env.coop_npc_players.invalidate()
	return H, C, fighting, proxy
end

print("== H1: who fights this player")
do
	local H, C, fighting = stage()
	local ct = C.env.xr_combat_ignore.fighting_with_actor_npcs
	tick(H, C)
	check(next(ct) == nil, "no fight: the client's table is empty")

	fighting[700] = { [500] = true } -- NPC 700 fights the client's proxy
	tick(H, C)
	check(ct[700] == true, "the NPC that fights the client's character is in the client's table: xrs_dyn_music starts")
	check(H.env.xr_combat_ignore.fighting_with_actor_npcs[700] == nil, "the host's table stays stock: it is not his fight")

	fighting[701] = { [0] = true } -- this one fights the host's actor
	tick(H, C)
	check(ct[701] == nil, "an NPC that fights only the host is not in the client's table")

	-- dead on the host, not yet here: it leaves the list
	H.objects[700]._alive = false
	tick(H, C)
	check(ct[700] == nil, "a dead NPC leaves the table")

	H.objects[700]._alive = nil
	fighting[700] = nil
	local sets = H.sync_sets
	tick(H, C)
	tick(H, C)
	check(H.sync_sets == sets, "no change, nothing written")
end

print("== M3: hit handlers on the attacker's machine")
do
	local H, C, _, proxy = stage()
	C.env.wepl_hit_effect = { npc_on_before_hit = function(npc, shit, bone, flags)
		C.wepl = { npc:id(), shit.power, shit.draftsman:id(), bone }
	end }
	C.env.agdd_voiced_actor = {
		npc_on_hit_callback = function(npc, amount, dir, attacker, bone) C.agdd = { npc:id(), amount, attacker:id(), bone } end,
		monster_on_hit_callback = function(npc, amount, dir, attacker, bone) C.agdd_m = { npc:id(), amount, attacker:id() } end,
	}
	C.env.npe_gamma_tutorial_ammo_mcm = { is_ammo_item_used = function(npc, shit, bone) C.npe = shit.weapon_id end }
	NOW = NOW + 1
	local npc = H.objects[700]

	H.fire("npc_on_hit_callback", npc, 0.4, vec(0, 0, 1), proxy, 15)
	pump()
	check(C.wepl and C.wepl[1] == 700 and C.wepl[2] == 0.4 and C.wepl[3] == 0 and C.wepl[4] == 15, "the hit sound handler runs with the local actor as the attacker")
	check(C.agdd and C.agdd[3] == 0 and C.agdd[4] == 15, "Voiced Actor's hit handler too")
	check(C.npe == 0, "and the ammo tutorial")
	check(C.agdd_m == nil, "a stalker's hit is not a mutant's")

	C.agdd = nil
	H.fire("monster_on_hit_callback", npc, 0.2, vec(0, 0, 1), proxy, 3)
	pump()
	check(C.agdd_m and C.agdd_m[1] == 700 and C.agdd == nil, "a mutant's hit goes to the mutant handler")

	H.sent = {}
	H.fire("npc_on_hit_callback", npc, 0.4, vec(0, 0, 1), H.env.db.actor, 15)
	H.fire("npc_on_hit_callback", npc, 0.4, vec(0, 0, 1), H.objects[701], 15)
	H.fire("npc_on_hit_callback", npc, 0, vec(0, 0, 1), proxy, 15)
	check(#sent_named(H, "world.hit") == 0, "the host's own hit, an NPC's hit and a zero hit are not told")

	C.wepl = nil
	for i = 1, 100 do H.fire("npc_on_hit_callback", npc, 0.1, vec(0, 0, 1), proxy, 1) end
	check(#sent_named(H, "world.hit") <= 20, "a burst of pellets stays inside the limit")
	QUEUE = {}
	C.env.wepl_hit_effect.npc_on_before_hit = function() error("a broken mod") end
	NOW = NOW + 2000
	H.fire("npc_on_hit_callback", npc, 0.4, vec(0, 0, 1), proxy, 15)
	pump()
	check(C.env.coop_npc_players.error_count("fight") == 1, "a mod's error is logged, the session goes on")
end

print("== R2, R6, R8: coop_world_compat")
do
	local H, C = world_pair()
	stock(H)
	stock(C)
	C.env.pda = { calculate_rankings = function() C.ranks = (C.ranks or 0) + 1 end }
	H.env.pda = { calculate_rankings = function() H.ranks = (H.ranks or 0) + 1 end }
	local orders = {}
	C.env.dialogs_axr_companion = {}
	for _, n in ipairs({ "set_companion_to_attack_state", "set_companion_to_ignore_combat_state", "set_companion_to_wait_state",
		"set_companion_to_follow_state", "set_companion_to_stealth_substate", "set_companion_to_default_substate" }) do
		C.env.dialogs_axr_companion[n] = function(a, b) orders[#orders + 1] = { n, b:id() } end
	end
	C.env.key_bindings = { kCUSTOM1 = 101, kCUSTOM2 = 102, kCUSTOM4 = 104, kCUSTOM5 = 105 }
	C.env.dik_to_bind = function(k) return k end
	C.env.actor_menu = { set_msg = function(_, s) C.msg = s end }
	C.env.db.OnlineStalkers = { 800, 801 }
	C.add(make_obj(800, 1, 0, 0))._info.npcx_is_companion = true
	C.add(make_obj(801, 1, 0, 0))
	-- planting
	local planted = {}
	C.env.txr_mines = { plant_bomb = function(obj, mode, delay) planted[#planted + 1] = { obj:id(), mode, delay } end }
	local marked, dropped = {}, {}
	local avatar = C.add(make_obj(820, 1, 0, 0))
	avatar.section = function() return "coop_player_avatar" end
	local stalker = C.add(make_obj(821, 1, 0, 0))
	stalker.section = function() return "stalker" end
	local stale = C.add(make_obj(822, 1, 0, 0))
	stale.section = function() return "stalker" end
	C.env.ui_hud_dotmarks = { replace_invitem_with_bomb = function() error("alife_create answers nil on a client") end,
		setup_marker_for_object = function(id) marked[#marked + 1] = id end,
		get_mark = function(id) return id == 822 and { mark_id = "dotmark_822" } or nil end,
		destroy_marker = function(id, why) dropped[#dropped + 1] = id end }
	H.env.ui_hud_dotmarks = { replace_invitem_with_bomb = function(id) H.bomb = id end }
	-- TB
	local cubes = 0
	C.env.tb_coordinate_based_safe_zones = { add_tiny_cubes_to_world = function() cubes = cubes + 1 end,
		addsafeicons = function() cubes = cubes + 1 end }
	H.env.tb_coordinate_based_safe_zones = { add_tiny_cubes_to_world = function() H.cubes = true end }

	local CH, CC = load_script(H, "coop_world_compat"), load_script(C, "coop_world_compat")
	CH.on_game_start()
	CC.on_game_start()

	C.fire("actor_on_info_callback", C.env.db.actor, "ui_pda")
	check(C.ranks == 1, "a client raises the PDA: the rankings are asked for")
	C.fire("actor_on_info_callback", C.env.db.actor, "other")
	check(C.ranks == 1, "another info is nothing to it")
	H.fire("actor_on_info_callback", H.env.db.actor, "ui_pda")
	check(H.ranks == nil, "the host keeps info_portions' own call")

	C.fire("on_key_release", 101)
	check(#orders == 1 and orders[1][1] == "set_companion_to_attack_state" and orders[1][2] == 800, "the combat hotkey orders this player's companion through the dialog action")
	check(C.msg == "st_set_companion_to_attack_state", "with the stock message")
	C.fire("on_key_release", 101)
	check(orders[2][1] == "set_companion_to_ignore_combat_state", "the next press cycles on")
	C.fire("on_key_release", 105)
	check(#orders == 2, "the loot key has no client action")
	C.env.db.OnlineStalkers = {}
	C.fire("on_key_release", 102)
	check(#orders == 2, "no companions: nothing")

	C.env.ui_hud_dotmarks.setup_marker_for_object(820, {})
	check(#marked == 0, "no mark on a player's character: no dot, no [F] Talk")
	C.env.ui_hud_dotmarks.setup_marker_for_object(821, {})
	check(marked[1] == 821, "an NPC keeps its mark")
	C.env.coop_npc_players = C.env.coop_npc_players or {}
	local others = C.env.coop_npc_players.others
	C.env.coop_npc_players.others = function() return { stale } end
	NOW = NOW + 1100
	C.fire("actor_on_update")
	check(dropped[1] == "dotmark_822", "a mark made before the character was known goes on the next tick")
	C.env.coop_npc_players.others = others

	local item = C.add(make_obj(900, 0, 0, 0))
	C.env.ui_hud_dotmarks.replace_invitem_with_bomb(900, 2, 5)
	check(planted[1] and planted[1][1] == 900 and planted[1][2] == 2 and planted[1][3] == 5, "a client's remote planting goes the way of txr_mines.plant_bomb")
	H.env.ui_hud_dotmarks.replace_invitem_with_bomb(901)
	check(H.bomb == 901, "the host's stays stock")

	C.env.tb_coordinate_based_safe_zones.add_tiny_cubes_to_world()
	C.env.tb_coordinate_based_safe_zones.addsafeicons()
	check(cubes == 0, "TB's cubes and icons stay off a client")
	H.env.tb_coordinate_based_safe_zones.add_tiny_cubes_to_world()
	check(H.cubes == true, "the host makes them")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
