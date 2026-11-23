-- R32 WP18: root-based loot guards and container protections.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

make_actor()
function level.map_add_object_spot_ser() end
function level.map_remove_object_spot() end
spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500 })
local foreign, deleted, generated, stashes = {}, {}, {}, {}
local rolls, mags, enabled = 0, 0, false
local npc_rolls, npc_rolls_enabled = {}, true
local throws, lamp_ticks, camps, drops, deployed, packed = 0, 0, 0, 0, 0, 0
local dismantled, detached, gun_placed, pba_cleaned = {}, {}, 0, {}
local function box(id, sec)
	local _, obj = spawn(sec or "inventory_box", vec3(1, 0, 0), nil, { id = id, kind = "box" })
	return obj
end
local plain, bag, bench, owned, other = box(600), box(601, "coop_death_stash"), box(602), box(603), box(604)
local _, body = spawn("stalker", vec3(1, 0, 0), nil, { id = 605, kind = "stalker", alive = false })
local _, foreign_body = spawn("stalker", vec3(1, 0, 0), nil, { id = 606, kind = "stalker", alive = false })
local distributed = name == "srv_map" or name == "srv_world"
if distributed then foreign[604], foreign[606] = true, true end
local data = alife_storage_manager.get_state()
data.workshop_stashes = { [610] = 602, [611] = 603 }
data.coop_stash_owner = { [610] = 777, [611] = 500 }
z_auto_looter = { config = { delete_misc = true }, handle_delete = function(obj) deleted[obj:id()] = true end }
death_manager = { create_release_item = function(obj) generated[obj:id()] = true end }
grok_stashes_on_corpses = { npc_on_use = function(obj) stashes[obj:id()] = true end }
smr_amain_mcm = { get_config = function(k) assert(k == "smr_enabled"); return enabled end }
smr_loot_mcm = { get_config = function(k) assert(k == "npc_spawn"); return npc_rolls_enabled end }
local function npc_on_death_callback(npc)
	local id = npc:id()
	npc_rolls[id] = (npc_rolls[id] or 0) + 1
end
local function actor_on_first_update()
	if name ~= "srv_map" then RegisterScriptCallback("npc_on_death_callback", npc_on_death_callback) end
end
smr_loot = {
	try_spawn = function() rolls = rolls + 1 end,
	try_spawn_mag = function() mags = mags + 1 end,
	on_game_start = function() RegisterScriptCallback("actor_on_first_update", actor_on_first_update) end,
}
zz_glowstick_mcm = {
	spawn_glowstick = function() throws = throws + 1 end,
	glowstick_binder = { update = function() lamp_ticks = lamp_ticks + 1 end },
}
item_backpack = { actor_on_item_use = function() end, actor_on_item_take_from_box = function() end }
ui_hud_dotmarks = {
	deploy_backpack = function() deployed = deployed + 1 end,
	remove_placed_backpack = function() packed = packed + 1 end,
}
campfire_placeable = {
	actor_on_item_use = function() camps = camps + 1 end,
	place_campfire = function() camps = camps + 1 end,
}
model_dropper_mcm = { spawn_object = function() drops = drops + 1 end }
item_parts = { disassembly_weapon = function(obj) dismantled[obj:id()] = true end }
utils_item = { detach_addon = function(obj) detached[obj:id()] = true end }
itms_manager = { use_deployable_mgun = function() gun_placed = gun_placed + 1 end }
zz_treasure_manager_pba_less_artys = {
	physic_object_on_use_callback = function(obj) pba_cleaned[obj:id()] = true end,
}
local function from_player(verb, t)
	if name == "srv_map" then t._peer = 1 end
	coop_main.on_event("mods." .. verb, coop_main.encode(t), name == "srv_map" and 0 or 1)
end

if name == "srv_map" then
	-- The enabled check must run before the opener wrapper records the roll, in either startup order.
	local items, misc
	for i, module in ipairs(MODS_FILES) do
		if module == "coop_mods_items" then items = i end
		if module == "coop_mods_misc" then misc = i end
	end
	MODS_FILES[items], MODS_FILES[misc] = MODS_FILES[misc], MODS_FILES[items]
end
AddScriptCallback("npc_on_death_callback")
start_all()
modes.install(coop_mode, name, { writes = function(id) return not foreign[id] end })
smr_loot.on_game_start()
SendScriptCallback("actor_on_first_update")

if name == "hostplay" or name == "srv_map" then
	from_player("al_del", { c = plain:id() })
	from_player("al_del", { c = bag:id() })
	from_player("al_del", { c = bench:id() })
	from_player("al_del", { c = owned:id() })
	check(deleted[600] and deleted[603], "al_del still cleans regular boxes and the requester's own workbench")
	check(not deleted[601], "V3: al_del preserves the death bag")
	check(not deleted[602], "V3: al_del preserves another player's workbench box")
end
if name == "srv_world" or name == "srv_map" then
	z_auto_looter.handle_delete(other)
	if name == "srv_map" then from_player("al_del", { c = other:id() }) end
	check(not deleted[604], "Autolooter direct and routed paths skip another writer's box")
	death_manager.create_release_item(foreign_body)
	grok_stashes_on_corpses.npc_on_use(foreign_body)
	if name == "srv_map" then
		from_player("corpse_loot", { n = foreign_body:id() })
		from_player("gso_use", { n = foreign_body:id() })
	end
	check(not generated[606], "a foreign writer owns the corpse loot roll")
	check(not stashes[606], "a foreign writer owns the corpse stash roll")
end
death_manager.create_release_item(body)
grok_stashes_on_corpses.npc_on_use(body)
check(generated[605] and stashes[605], "the corpse writer runs the direct loot adapters")

if name ~= "none" then
	coop_mods_core.on_container_opened(1, plain:id())
	smr_loot.try_spawn_mag(plain)
	check(rolls == 0 and mags == 0, "ZCP's bonus and magazine rolls honor smr_enabled")
end
enabled = true
if name ~= "none" then
	coop_mods_core.on_container_opened(1, plain:id())
	check(rolls == 1, "opening while SMR is disabled does not spend that box's one roll")
	rolls = 0
end
smr_loot.try_spawn(plain)
smr_loot.try_spawn_mag(plain)
check(rolls == 1 and mags == 1, "enabled ZCP rolls on the writer")
if name == "srv_world" or name == "srv_map" then
	smr_loot.try_spawn(other)
	smr_loot.try_spawn_mag(other)
	coop_mods_core.on_container_opened(1, other:id())
	check(rolls == 1 and mags == 1, "ZCP direct and notification paths skip a foreign box")
end

SendScriptCallback("npc_on_death_callback", body)
SendScriptCallback("npc_on_death_callback", foreign_body)
check(npc_rolls[605] == 1 and (npc_rolls[606] == nil) == distributed,
	"ZCP's corpse writer rolls once even where the stock callback is routed away")
if name ~= "none" then
	enabled = false
	SendScriptCallback("npc_on_death_callback", body)
	enabled = true
	npc_rolls_enabled = false
	SendScriptCallback("npc_on_death_callback", body)
	check(npc_rolls[605] == 1, "ZCP's corpse writer honors both SMR and NPC-loot settings")
end

INI.test_backpack = { class = "EQ_BAKPK" }
INI.test_glowstick = { light_section = "glow" }
local _, glow = spawn("test_glowstick", nil, 500, { id = 620 })
local _, lamp = spawn("lights_glowstick", nil, nil, { id = 621 })
local _, backpack = spawn("test_backpack", vec3(1, 0, 0), 500, { id = 622 })
local stash = box(623, "inv_backpack")
local _, campfire = spawn("itm_campfire", nil, 500, { id = 624 })
data.player_created_stashes = { [623] = "test_backpack" }
foreign[620], foreign[621], foreign[622], foreign[623], foreign[624] = distributed, distributed, distributed, distributed, distributed
zz_glowstick_mcm.spawn_glowstick(glow:id(), true)
zz_glowstick_mcm.glowstick_binder.update({ object = lamp })
ui_hud_dotmarks.deploy_backpack(backpack:id())
ui_hud_dotmarks.remove_placed_backpack(stash:id())
campfire_placeable.actor_on_item_use(campfire)
if name == "srv_map" or name == "hostplay" then
	from_player("stash_make", { i = backpack:id(), p = "treasure" })
	from_player("stash_free", { b = stash:id() })
	from_player("cf_place", { i = campfire:id() })
end
check(throws == (distributed and 0 or 1) and lamp_ticks == (distributed and 0 or 1),
	"only the source writer throws a glowstick and only the lamp writer burns it down")
check(deployed == (distributed and 0 or 1) and packed == (distributed and 0 or 1)
	and (not distributed or (SE[622] ~= nil and SE[623] ~= nil)),
	"backpack placement and packing follow the writer in local and routed actions")
check(camps == (name == "hostplay" and 2 or distributed and 0 or 1)
	and (not distributed or SE[624] ~= nil), "only the source writer places and consumes a campfire")
foreign[0] = distributed
model_dropper_mcm.spawn_object("test_backpack")
check(drops == (distributed and 0 or 1), "only the dropper's actor writer creates dropped models")

local _, wpn = spawn("wpn_test", nil, plain:id(), { id = 630 })
local _, foreign_wpn = spawn("wpn_test", nil, other:id(), { id = 631 })
foreign[631] = distributed
item_parts.disassembly_weapon(wpn)
item_parts.disassembly_weapon(foreign_wpn)
utils_item.detach_addon(wpn)
utils_item.detach_addon(foreign_wpn)
check(dismantled[630] and detached[630] and (dismantled[631] == nil) == distributed
	and (detached[631] == nil) == distributed, "disassembly and detach cannot act on a foreign writer's loot")

INI.deployable_mgun = {}
local _, gun = spawn("itm_deployable_mgun", nil, 500, { id = 632 })
coop_mods_core.as_player(OBJ[500], itms_manager.use_deployable_mgun, gun)
if distributed then
	foreign[500] = true
	coop_mods_core.as_player(OBJ[500], itms_manager.use_deployable_mgun, gun)
end
check(gun_placed == 1, "deployable gun follows the character writer after use consumed the item")

if name ~= "none" then
	coop_mods_core.on_container_opened(1, plain:id())
	coop_mods_core.on_container_opened(1, other:id())
	run_time_events(1200)
	check(pba_cleaned[plain:id()] and (pba_cleaned[other:id()] == nil) == distributed,
		"the container notification cleans treasure only on the writer")
end

done("mods_items_loot@" .. name)
