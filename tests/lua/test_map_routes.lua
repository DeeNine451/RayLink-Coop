-- F3a split levels: what a map server runs, through the real route files. A handler of the domain host does not run there, one of the
-- domain level does (coop_router.cpp route_of, coop_routes.h Table::level_behaviour, runs_here). Run: tools\test_lua.cmd map_routes
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")

route_stub_load()

local function domain_on_map_server(callback, script)
	local d = coop_native.route(callback, script)
	if d ~= "host" then return d end
	local key = script:lower()
	if ROUTE_LEVEL_SCRIPTS[key] then return "level" end
	if ROUTE_SCRIPT_RULES[key] == nil and ROUTE_LEVEL_CALLBACKS[callback:lower()] then
		local has_prefix = false
		for k in pairs(ROUTE_SCRIPT_RULES) do
			if k:sub(-1) == "*" and key:sub(1, #k - 1) == k:sub(1, -2) then has_prefix = true end
		end
		if not has_prefix then return "level" end
	end
	return d
end

local function runs_on_map_server(callback, script)
	local d = domain_on_map_server(callback, script)
	return d == "level" or d == "owner" or d == "view"
end

print("== a trader's stock, 1: GAMMA's injections and who listens to the restock")
check(runs_on_map_server("time_event", "trader_autoinject"), "trader_autoinject: the timer of the restock runs")
check(runs_on_map_server("trader_on_restock", "exo_loot"), "exo_loot: the restock is heard")
check(runs_on_map_server("npc_on_item_take", "axr_trade_manager"), "axr_trade_manager: NPCs bring loot to a trader")
check(not coop_native.runs_here(domain_on_map_server("time_event", "trader_autoinject"), false), "a client does not run it")

print("== a release, 5")
check(runs_on_map_server("actor_on_reinit", "safe_release_manager"), "safe_release_manager: registers its unique call")
check(runs_on_map_server("unique_call", "safe_release_manager"), "safe_release_manager: the unique call runs")
check(runs_on_map_server("on_game_load", "release_body_manager"), "release_body_manager reads its settings")
check(runs_on_map_server("time_event", "release_item_manager"), "release_item_manager: its timer runs")
check(runs_on_map_server("actor_on_update", "logic_enforcer"), "logic_enforcer: the logic of an NPC online here")

print("== wrappers of a host-only callback, 6")
for _, cb in ipairs({ "npc_on_hit_callback", "npc_on_before_hit" }) do
	check(domain_on_map_server(cb, "coop_npc_adapters") == "level", cb .. "@coop_npc_adapters runs where it wraps")
	check(not coop_native.runs_here(domain_on_map_server(cb, "coop_npc_adapters"), false), cb .. "@coop_npc_adapters: never on a client")
end
check(domain_on_map_server("monster_on_update", "coop_npc_phantoms") == "level", "monster_on_update@coop_npc_phantoms")
for _, cb in ipairs({ "npc_on_update", "npc_on_hit_callback", "anomaly_on_before_activate", "game_object_on_net_spawn",
	"game_object_on_net_destroy", "server_object_on_register", "actor_on_update" }) do
	check(domain_on_map_server(cb, "aaaa_script_fixes_mp") == "level", cb .. "@aaaa_script_fixes_mp")
end
check(runs_on_map_server("npc_on_before_hit", "grok_no_npc_friendly_fire"), "No NPC Friendly Fire")
check(runs_on_map_server("npc_on_update", "grok_nes"), "GAMMA's exoskeleton rule")
check(runs_on_map_server("npc_on_update", "grok_no_north_faction_in_south"), "GAMMA's faction rule")
check(runs_on_map_server("actor_on_update", "grok_sniper_remover"), "GAMMA's sniper rule")
check(runs_on_map_server("monster_on_update", "xcv_phantoms"), "phantoms")
check(runs_on_map_server("time_event", "xcv_phantoms_fix"), "phantoms: the release of offline squads")

print("== a wrapper of a world handler keeps its domain")
check(coop_native.route("actor_on_interaction", "coop_levels_tables") == "host", "drx_da_main's handler in a wrapper: world server only, one roll")
check(domain_on_map_server("actor_on_interaction", "coop_levels_tables") == "host", "and not on a map server")
-- what a player's search starts runs where the body or the box is: the timers of these two stay at the authority of the level
check(domain_on_map_server("time_event", "guaranteed_loot") == "level", "the check of guaranteed_loot's search on a map server")
check(domain_on_map_server("time_event", "zz_treasure_manager_pba_less_artys") == "level", "the clean of PBA's less artefacts on a map server")
check(coop_native.route("npc_on_use", "guaranteed_loot") == "host", "their other handlers stay as they were")
check(domain_on_map_server("time_event", "coop_npc_adapters") == "level", "trader_autoinject.timed_update in its wrapper")
check(not coop_native.runs_here("level", false), "which a client does not run")

print("== with one level for everybody level is host")
check(coop_native.runs_here("level", true) and coop_native.runs_here("host", true), "the host runs both")
check(not coop_native.runs_here("level", false) and not coop_native.runs_here("host", false), "a client neither")

print("== the world stays the world's")
for _, s in ipairs({ "sim_board", "tasks_fetch", "xr_effects", "treasure_manager" }) do
	check(not runs_on_map_server("actor_on_update", s), s .. " stays on the world server")
end

print(string.format("%d passed, %d failed", PASSES, FAILS or 0))
