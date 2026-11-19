-- Map reports update the Server world's state only for a bridge identified by the transport.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

local bridge, player = 0x101, 1
local dedicated, connected = true, true
coop.is_dedicated = function() return dedicated end
coop.levels = { map_servers = function()
	return connected and { { bridge = bridge, level = 2 } } or {}
end }
coop_trust.reset_for_test({ default = "log" })

local furniture, death_dropped, magazines_data = {}, {}, {}
hf_obj_manager = {
	get_data = function(id) return furniture[id] end,
	update_data = function(id, data) furniture[id] = data end,
	delete_data = function(id) furniture[id] = nil end,
}
weapon_showcase = { spawn_displayed_item = function() end, remove_displayed_item = function() end }
death_manager = { create_release_item = function() end }
function se_save_var(id, _, key, value)
	if key == "death_dropped" then death_dropped[id] = value end
end
item_backpack = { actor_on_item_use = function() end, actor_on_item_take_from_box = function() end }
magazines = { eject_magazine = function() end }
magazine_binder = {
	get_data = function(id) return magazines_data[id] end,
	set_data = function(id, data) magazines_data[id] = data end,
}

make_actor(vec3(0, 0, 0))
spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500 })
local loose = spawn("mag_ak", vec3(1, 0, 0))
local carried = spawn("mag_ak", vec3(1, 0, 0), 500)
start_all()
local world = alife_storage_manager.get_state()
local function report(verb, payload, from)
	coop_main.on_event("mods." .. verb, coop_main.encode(payload), from)
end
local function magazine(id, ammo)
	return { n = 1, i1 = id, d1 = coop_mods_core.ser({ loaded = { ammo } }), _peer = bridge }
end
local cases = {
	{ "hf_data", { o = 801, d = coop_mods_core.ser({ condition = 0.5 }), _peer = bridge }, function()
		return furniture[801] and furniture[801].condition
	end, 0.5, true },
	{ "hf_show_map", { c = 802, m = "1500:1600:2:wpn_ak", _peer = bridge }, function()
		local displays = weapon_showcase.weapon_displays
		return displays and displays[802] and displays[802][1500]
	end, 1600, true },
	{ "corpse_dropped", { n = 803, s = "corpse", _peer = bridge }, function()
		return death_dropped[803]
	end, true },
	{ "stash_book", { b = 804, s = "itm_backpack", o = 500, _peer = bridge }, function()
		return world.player_created_stashes and world.player_created_stashes[804]
	end, "itm_backpack" },
	{ "mg_data", magazine(loose.id, "ammo_545"), function()
		return magazines_data[loose.id] and magazines_data[loose.id].loaded[1]
	end, "ammo_545" },
}

for _, case in ipairs(cases) do
	local verb, payload, result, expected, relays = unpack(case)
	LOG, SENT = {}, {}
	report(verb, payload, player)
	check(result() == nil and #SENT == 0, verb .. ": a player cannot forge a map report with a bridge in the payload")
	check(log_has("[coop-trust] ! " .. verb .. "_sender:") ~= nil, verb .. ": a forged report is logged through trust")
	LOG = {}
	connected = false
	report(verb, payload, bridge)
	check(result() == nil and #SENT == 0 and log_has("[coop-trust] ! " .. verb .. "_sender:"),
		verb .. ": a disconnected bridge is refused through trust")
	connected = true
	report(verb, payload, bridge)
	check(result() == expected, verb .. ": the world applies its registered bridge's report")
	if relays then
		check(#SENT == 1 and SENT[1].name == "mods." .. verb and SENT[1].target == -1,
			verb .. ": the accepted world state is relayed to observers")
	end
end

report("mg_data", magazine(carried.id, "server_carrier"), player)
check(magazines_data[carried.id] and magazines_data[carried.id].loaded[1] == "server_carrier",
	"the Server world still accepts data from the magazine's carrier")

dedicated = false
LOG, SENT = {}, {}
report("hf_data", { o = 801, x = true }, bridge)
check(furniture[801] ~= nil and #SENT == 0 and log_has("[coop-trust] ! hf_data_sender:"),
	"the Co-op host rejects a map report even if the engine registry still lists that ID")
report("mg_data", magazine(carried.id, "coop_carrier"), player)
check(magazines_data[carried.id] and magazines_data[carried.id].loaded[1] == "coop_carrier",
	"the Co-op host still accepts data from the magazine's carrier")

MODE = "client"
report("hf_data", { o = 801, x = true }, 0)
check(furniture[801] == nil, "the Co-op client still accepts furniture state from peer 0")
check(coop_mods_core.stats.errors == 0, "the report handlers ran without Lua errors")
done("SRV MODS MAP REPORTS")
