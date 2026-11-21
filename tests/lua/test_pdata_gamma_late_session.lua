-- A co-op host starts its session after its level is up (coop_manager.cpp autostart waits for level_ready; the in-game Host
-- comes later still), and its save loads before that too (load_state comes before the first update). coop_mods_pdata_gamma
-- read the host's last-selected trader of each GAMMA trading computer only in that load_state and only with a session: the
-- choices were dropped, the session fell back to the furniture's stock value (stale: in a session the stock setter is
-- bypassed) and the next save wrote the empty table, so the loss was permanent. Runs under every answer set
-- (tests\lua\support\modes.lua): the Server's processes and single player keep the stock accessors.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

-- The engine's phase is Off until the host starts hosting: no session while the level and the save load.
local hosting = false
local is_active = coop.is_active
coop.is_active = function() return hosting and is_active() end

-- The furniture's stock values: what the stock getter returns. A session bypasses the stock setter, so in a session these
-- are as old as the last choice made without one.
local furniture = { [40] = { last_trader_id = 900, battery = 80 }, [41] = { last_trader_id = 901 } }
hf_obj_manager = {
	get_data = function(id) return furniture[id] end,
	update_data = function(id, data)
		local device = furniture[id]
		if device then for k, v in pairs(data) do device[k] = v end end
	end,
}

-- The mod's own accessors (the reviewed merged corpus when it is present, else the same functions copied from it).
local FIXTURE = [=[
local function get_data(obj_id)
    if not obj_id or not hf_obj_manager then
        return {}
    end
    return hf_obj_manager.get_data(obj_id) or {}
end
local function set_data(obj_id, fields)
    if not obj_id or not hf_obj_manager then
        return
    end
    hf_obj_manager.update_data(obj_id, fields)
end
function get_last_selected_trader(obj_id)
    local d = get_data(obj_id)
    local id = tonumber(d.last_trader_id)
    if id and id > 0 then
        return id
    end
    return nil
end
function set_last_selected_trader(obj_id, trader_id)
    if not obj_id then
        return
    end
    trader_id = tonumber(trader_id)
    if trader_id and trader_id > 0 then
        set_data(obj_id, { last_trader_id = trader_id })
    end
end
]=]
local function computer_module()
	local fh = io.open("temp/review/corpus/merged/bind_trading_computer.script", "rb")
	local text = fh and fh:read("*a") or FIXTURE
	if fh then fh:close() end
	text = text:gsub("\r\n", "\n")
	local parts = {}
	for _, header in ipairs({ "local function get_data(", "local function set_data(",
		"function get_last_selected_trader(", "function set_last_selected_trader(" }) do
		local start = assert(text:find(header, 1, true), header)
		local finish = assert(text:find("\nend", start, true), header .. " end")
		parts[#parts + 1] = text:sub(start, finish + 3)
	end
	local module = setmetatable({}, { __index = _G })
	local chunk = assert(loadstring(table.concat(parts, "\n"), "@corpus/bind_trading_computer.script"))
	setfenv(chunk, module)
	chunk()
	return module
end

make_actor()
start_all()
modes.install(coop_mode, mode)
bind_trading_computer = computer_module()
local computer = bind_trading_computer
load_script("coop_mods_pdata_gamma").on_game_start()
local CHOICES = "coop_gamma_trading_choices"
local function load(m) alife_storage_manager.CALifeStorageManager_load(m) end
local function save()
	local m = {}
	SendScriptCallback("save_state", m)
	return m
end

print("== GAMMA trading computer choices, session after the save (" .. mode .. ")")
-- b57h host: the save loads, first update 09:52:54, "phase off -> hosting" 09:53:09
load({ [CHOICES] = { [40] = 950 } })
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")
check(computer.get_last_selected_trader(40) == 900 and computer.get_last_selected_trader(41) == 901,
	mode .. ": without a session the stock getter reads the furniture")
check(save()[CHOICES] == nil, mode .. ": without a session nothing is added to the save")

hosting = true
SendScriptCallback("actor_on_update") -- the first update after hosting starts

if mode == "hostplay" then
	check(computer.get_last_selected_trader(40) == 950,
		"hostplay: the host's choice from his save once the co-op host starts its session (not the furniture's stale 900)")
	check(computer.get_last_selected_trader(41) == 901,
		"hostplay: a device the save has no choice for still reads the furniture (older saves)")
	local saved = save()
	check(type(saved[CHOICES]) == "table" and saved[CHOICES][40] == 950,
		"hostplay: the next save keeps the choice the save had (the empty table made the loss permanent)")
	computer.set_last_selected_trader(41, 960)
	check(computer.get_last_selected_trader(41) == 960 and furniture[41].last_trader_id == 901,
		"hostplay: a choice in the session is private and never written into the furniture")
	saved = save()
	check(saved[CHOICES] and saved[CHOICES][40] == 950 and saved[CHOICES][41] == 960,
		"hostplay: the save has the loaded choice and the new one")

	-- a save loaded in the session is read at its load, as before
	load({ [CHOICES] = { [40] = 970 } })
	check(computer.get_last_selected_trader(40) == 970, "hostplay: a save loaded in the session restores its choices at once")

	-- the host leaves hosting, loads another save and hosts again: that save's choices, not the earlier session's, and taken
	-- up before anything in the new session reads or changes them (no update between the start and the first use)
	hosting = false
	load({ [CHOICES] = { [40] = 980 } })
	check(computer.get_last_selected_trader(40) == 900, "hostplay: without a session the stock getter is back")
	hosting = true
	computer.set_last_selected_trader(41, 990)
	check(computer.get_last_selected_trader(40) == 980 and computer.get_last_selected_trader(41) == 990,
		"hostplay: the save loaded before this session replaces the earlier session's choices, and a choice made at once stays")
	saved = save()
	check(saved[CHOICES] and saved[CHOICES][40] == 980 and saved[CHOICES][41] == 990,
		"hostplay: the next save writes this session's choices")
else
	-- the Server's processes have no player's actor (a ghost); single player has no session at all
	check(computer.get_last_selected_trader(40) == 900, mode .. ": the stock getter reads the furniture")
	computer.set_last_selected_trader(41, 960)
	check(furniture[41].last_trader_id == 960 and computer.get_last_selected_trader(41) == 960,
		mode .. ": the stock setter writes the furniture")
	check(save()[CHOICES] == nil, mode .. ": no personal computer choices in the save")
	load({ [CHOICES] = { [40] = 970 } })
	check(computer.get_last_selected_trader(40) == 900, mode .. ": a save's personal choices are not read here")
end
done("GAMMA computer choices late session " .. mode)
