-- World parity routing R1, R3, R4, R5, W4b: rules of the coop_compat_*.ltx files of lane L3, through the engine's router (stood in by
-- tests\lua\support\stubs.d\route.lua over the real coop_routes.h). Run: tools\test_lua.cmd world_routes
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== routes of a client")
make_actor()
load_script("coop_main")
coop_main.on_game_start()

local function domain_of(callback, script)
	return (coop.route.of(callback, from_script(script, "return function() end")))
end
local function runs(callback, script)
	return coop.route.runs(domain_of(callback, script))
end

-- R1: the safe zones tell this player he is safe, the cubes stay the host's
check(runs("actor_on_update", "TB_Coordinate_Based_Safe_Zones"), "TB safe zones: actor_on_update runs on a client (its cover report needs it)")
check(runs("physic_object_on_use_callback", "tb_coordinate_based_safe_zones"), "TB safe zones: a sleeping bag answers on a client")
check(runs("time_event", "tb_coordinate_based_safe_zones"), "TB safe zones: the sleep dialog's timer stays")
check(not runs("on_game_load", "tb_coordinate_based_safe_zones"), "TB safe zones: on_game_load (cube cleanup) stays on the host")
check(not runs("save_state", "tb_coordinate_based_safe_zones"), "TB safe zones: its save stays on the host")

-- R3: the timers of the player's own menu action; the campfire itself stays the host's
check(runs("time_event", "campfire_placeable"), "campfire_placeable: gathering wood gets its timers back")
check(not runs("actor_on_item_use", "campfire_placeable"), "campfire_placeable: the campfire item stays on the host")
check(not runs("actor_on_first_update", "campfire_placeable"), "campfire_placeable: the first update stays on the host")

-- R4: Voiced Actor is the player's own voice
for _, cb in ipairs({ "npc_on_death_callback", "monster_on_death_callback", "actor_on_update", "on_key_press" }) do
	check(runs(cb, "agdd_voiced_actor"), "agdd_voiced_actor: " .. cb .. " runs on a client")
end

-- R5: the label of a dead target
check(runs("npc_on_death_callback", "factionID_hud_mcm"), "faction label: a dead target is cleared on a client")
check(runs("npc_on_net_destroy", "factionid_hud_mcm"), "faction label: a gone target too")

-- W4b: blood pools are drawn where the corpse is seen
check(runs("npc_on_death_callback", "blood_pool"), "blood_pool: a corpse's pool is drawn on a client")
check(runs("monster_on_death_callback", "blood_pool"), "blood_pool: a mutant's too")

-- the new scripts run everywhere by coop_*
for _, n in ipairs({ "coop_world_weather", "coop_world_fx", "coop_world_fight", "coop_world_compat" }) do
	check(runs("actor_on_update", n), n .. " runs on a client")
end

-- what must not have moved
check(not runs("actor_on_update", "bind_artifact_harvester"), "the other host mechanics stay")

print(string.format("%d passed, %d failed", PASSES, FAILS or 0))
