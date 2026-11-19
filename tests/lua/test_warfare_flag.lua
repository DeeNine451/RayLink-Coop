-- G18-1 s42:2: the PDA's Warfare flag follows the loaded world in a session.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

AddScriptCallback("on_game_load") -- built in by the game's axr_main
local flag = load_script("coop_warfare_flag")
flag.on_game_start()

local function check_world(label, own_mode, saved_mode, expected)
	IsWarfare = function() return own_mode end
	alife_storage_manager.CALifeStorageManager_load({ enable_warfare_mode = saved_mode })
	_G.WARFARE = true -- stock warfare.on_game_start
	SendScriptCallback("on_game_load")
	check(_G.WARFARE == expected, label .. ": on_game_load")

	_G.WARFARE = MODE == "sp" or not expected
	SendScriptCallback("actor_on_first_update")
	check(_G.WARFARE == expected, label .. ": actor_on_first_update")
end

for _, name in ipairs(modes.names()) do
	MODE = name == "none" and "sp" or "host"
	modes.install(coop_mode, name)
	if name == "none" then
		check_world(name .. " leaves the stock flag alone", false, false, true)
	elseif name == "srv_map" then
		check_world(name .. " normal world uses the save", true, false, false)
		check_world(name .. " Warfare world uses the save", false, true, true)
	else
		check_world(name .. " normal world uses its own mode", false, true, false)
		check_world(name .. " Warfare world uses its own mode", true, false, true)
	end
	if name ~= "none" then
		MODE = "client"
		modes.install(coop_mode, name, {
			decides_world = function() return false end,
			leads_here = function() return false end,
			is_player_mirror = function() return true end,
			actor_is_player = function() return true end,
		})
		check_world(name .. " client ignores its local Warfare setting", true, false, false)
		check_world(name .. " client follows a Warfare save", false, true, true)
	end
end

print(string.format("warfare_flag: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
