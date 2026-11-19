-- G5-3: alarm, fan and a fan action captured by the Dot Marks scan (Dev 57).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local ALARM, FAN, OTHER = 700, 701, 702
local BRIDGE_A, BRIDGE_B = 0x101, 0x102
local ALARM_EVENT, FAN_EVENT, DATA_EVENT = "mods.hft_alarm", "mods.hft_fan", "mods.hf_data"

-- Stock HF data functions and toggle entry points from the merged GAMMA binders.
local furniture = {}
hf_obj_manager = {
	get_data = function(id) return furniture[id] end,
	set_data = function(id, data) furniture[id] = data end,
	delete_data = function(id) furniture[id] = nil end,
	update_data = function(id, changes)
		local data = furniture[id] or {}
		for k, v in pairs(changes) do data[k] = v end
		furniture[id] = data
	end,
}
bind_alarm_system = {
	toggle_alarm_system = function(id)
		hf_obj_manager.update_data(id, { is_on = not (hf_obj_manager.get_data(id) or {}).is_on })
	end,
}
bind_table_fan = {
	toggle_fan = function(id)
		alife_object(id):section_name()
		hf_obj_manager.update_data(id, { is_on = not hf_obj_manager.get_data(id).is_on })
	end,
}

INI.placeable_alarm_system = { script_binding = "bind_alarm_system.init" }
INI.placeable_fan = { script_binding = "bind_table_fan.init" }
INI.placeable_chair = { script_binding = "bind_hf_static.init" }
make_actor(vec3(0, 0, 0))
spawn("placeable_alarm_system", vec3(1, 0, 0), nil, { id = ALARM })
spawn("placeable_fan", vec3(2, 0, 0), nil, { id = FAN })
spawn("placeable_chair", vec3(3, 0, 0), nil, { id = OTHER })
spawn("coop_player_avatar", vec3(3, 0, 0), nil, { id = 501 })
spawn("coop_player_avatar", vec3(4, 0, 0), nil, { id = 502 })
spawn("coop_player_avatar", vec3(100, 0, 0), nil, { id = 503 })
coop.avatar_of = function(peer) return peer >= 1 and peer <= 3 and 500 + peer or nil end
coop.levels = {
	split = function() return false end,
	bridge_of_player = function(peer) return peer == 2 and BRIDGE_B or BRIDGE_A end,
	map_servers = function() return { { bridge = BRIDGE_A }, { bridge = BRIDGE_B } } end,
}

-- Follow axr_main's game-start order. The missing adapter leaves the stock callbacks in place
-- so the red run sees the actual local toggle / missing request behavior.
local adapter = io.open("gamedata/scripts/coop_mods_hf_toggles.script", "r")
if adapter then
	adapter:close()
	for i, name in ipairs(MODS_FILES) do
		if name == "coop_mods_hf" then
			table.insert(MODS_FILES, i + 1, "coop_mods_hf_toggles")
			break
		end
	end
end
start_all()

-- Dot Marks stores this function while scanning, then invokes the saved function on key release.
local marker = { func_exec_pri = bind_table_fan.toggle_fan }
local function press_marker() marker.func_exec_pri(FAN) end

local function data_copy()
	return { [ALARM] = { is_on = false, marker = "keep" }, [FAN] = { is_on = false }, [OTHER] = { is_on = false } }
end

local function receive(verb, fields, peer)
	coop_main.on_event(verb, coop_main.encode(fields), peer)
end

local function remote_clicks(map_session)
	MODE, SELF = "client", 1
	coop.levels.split = function() return map_session end
	modes.live(coop_mode)
	furniture, SENT = data_copy(), {}
	bind_alarm_system.toggle_alarm_system(ALARM)
	local alarm, alarm_wire = sent(ALARM_EVENT)
	check(alarm and alarm.o == ALARM and alarm_wire.target == 0 and furniture[ALARM].is_on == false,
		"m23:7 alarm interaction sends the id and leaves the local alarm unchanged")
	bind_table_fan.toggle_fan(FAN)
	local fan, fan_wire = sent(FAN_EVENT)
	check(fan and fan.o == FAN and fan_wire.target == 0 and furniture[FAN].is_on == false,
		"m30:7 the fan binder sends the id and waits for the authority")
	SELF = 2
	press_marker()
	check(sent_count(FAN_EVENT) == 2 and furniture[FAN].is_on == false,
		"m03:3 the captured Dot Marks callback sends exactly one request without changing the local fan")
	bind_alarm_system.toggle_alarm_system(ALARM)
	check(sent_count(ALARM_EVENT) == 2 and furniture[ALARM].is_on == false,
		"both players can queue a toggle for the same alarm")
end

local function authority_test(name)
	remote_clicks(name == "srv_map")
	local requests = SENT
	MODE, SELF = "host", 0
	if name == "srv_map" then MODE, SELF = "map", BRIDGE_A end
	coop.is_map_server = function() return MODE == "map" end
	modes.install(coop_mode, name)
	local authority = data_copy()
	furniture, SENT = authority, {}

	for i, request in ipairs(requests) do
		local peer = i <= 2 and 1 or 2
		if name == "srv_map" then
			local data = coop_main.decode(request.payload)
			data._peer = peer
			receive(request.name, data, 0)
		else
			deliver(request, peer)
		end
	end
	local updates = SENT
	check(sent_count(DATA_EVENT) == 4 and authority[ALARM].is_on == false and authority[FAN].is_on == false,
		"the authority serializes two toggles per device and publishes each transition once")
	check(authority[ALARM].marker == "keep", "the alarm keeps its other HF data")

	local target = name == "srv_map" and 0 or -1
	local state_before_second_click = {}
	for i, update in ipairs(updates) do
		local payload = coop_main.decode(update.payload)
		local data = coop_mods_core.deser(payload.d)
		check(update.name == DATA_EVENT and update.target == target and data and data.is_on == (i <= 2),
			"hf_data carries the authoritative transition " .. i)
		if i <= 2 then state_before_second_click[payload.o] = data and data.is_on end
	end
	check(state_before_second_click[ALARM] and state_before_second_click[FAN], "both on transitions are published")

	if name == "srv_map" then
		MODE, SELF = "host", 0
		modes.install(coop_mode, "srv_world")
		local world = data_copy()
		furniture, SENT = world, {}
		for _, update in ipairs(updates) do deliver(update, BRIDGE_A) end
		check(sent_count(DATA_EVENT) == 4 and world[ALARM].is_on == false and world[FAN].is_on == false
			and world[ALARM].marker == "keep", "the world server stores and relays the map's transitions")
		updates = SENT
	end

	MODE = "client"
	modes.live(coop_mode)
	for peer = 1, 2 do
		SELF, furniture = peer, data_copy()
		furniture[ALARM].is_on, furniture[FAN].is_on = true, true
		for _, update in ipairs(updates) do deliver(update, 0) end
		check(furniture[ALARM].is_on == false and furniture[FAN].is_on == false and furniture[ALARM].marker == "keep",
			"player " .. peer .. " mirrors the authority's final state through hf_data")
	end

	if name == "hostplay" then
		MODE, SELF = "host", 0
		modes.install(coop_mode, name)
		furniture, SENT = authority, {}
		bind_alarm_system.toggle_alarm_system(ALARM)
		press_marker()
		check(authority[ALARM].is_on and authority[FAN].is_on and sent_count(DATA_EVENT) == 2
			and sent_count(ALARM_EVENT) == 0 and sent_count(FAN_EVENT) == 0, "the co-op host's own player uses the same handler locally")
	else
		MODE, SELF = "map", BRIDGE_A
		modes.install(coop_mode, name)
		furniture, SENT = authority, {}
		bind_alarm_system.toggle_alarm_system(ALARM)
		check(#SENT == 0 and not authority[ALARM].is_on, "a map server has no local player toggle")
	end

	furniture, SENT = data_copy(), {}
	coop_trust.reset_for_test({ default = "refuse" })
	local function from_player(event, payload, peer)
		NOW = NOW + 1000
		if name == "srv_map" then
			payload._peer = peer
			receive(event, payload, 0)
		else
			receive(event, payload, peer)
		end
	end
	from_player(ALARM_EVENT, { o = ALARM, from = 1 }, 3)
	from_player(FAN_EVENT, { o = FAN, from = 1 }, 3)
	local function refusals()
		local count = 0
		for _, row in pairs(coop_trust.status()) do count = count + row.refused end
		return count
	end
	check(refusals() == 2 and not furniture[ALARM].is_on and not furniture[FAN].is_on and #SENT == 0,
		"both far toggles are refused through trust, using the transport sender")
	for _, id in ipairs({ FAN, -1, 0, 65535, 65536, ALARM + 0.5, "inf" }) do
		from_player(ALARM_EVENT, { o = id }, 1)
	end
	from_player(FAN_EVENT, { o = OTHER }, 1)
	check(refusals() == 10 and not furniture[ALARM].is_on and not furniture[FAN].is_on
		and not furniture[OTHER].is_on and #SENT == 0, "wrong device types and invalid ids are checked before any write")

	if name == "srv_map" then
		local obj = OBJ[ALARM]
		OBJ[ALARM] = nil -- the other map's device is absent here
		from_player(ALARM_EVENT, { o = ALARM }, 2)
		check(refusals() == 11 and not furniture[ALARM].is_on and #SENT == 0, "a map does not toggle a device across maps")
		OBJ[ALARM] = obj
	end

	coop_trust.reset_for_test({ default = "log" })
	from_player(FAN_EVENT, { o = FAN }, 3)
	local logged = false
	for _, row in pairs(coop_trust.status()) do
		if row.failed == 1 and row.refused == 0 then logged = true end
	end
	check(logged and furniture[FAN].is_on == true and sent_count(DATA_EVENT) == 1,
		"Dev 57 log mode logs a far request and accepts it as configured")
end

for _, name in ipairs(modes.names()) do
	if name == "none" then
		MODE = "sp"
		modes.install(coop_mode, name)
		furniture, SENT = data_copy(), {}
		bind_alarm_system.toggle_alarm_system(ALARM)
		bind_table_fan.toggle_fan(FAN)
		check(furniture[ALARM].is_on and furniture[FAN].is_on, "single-player toggles still use the original binders")
		press_marker()
		check(furniture[FAN].is_on == false and #SENT == 0, "the stored marker action also stays stock in single player")
	elseif name == "srv_world" then
		MODE, SELF = "host", 0
		coop.is_dedicated = function() return true end
		modes.live(coop_mode)
		furniture, SENT = data_copy(), {}
		receive(ALARM_EVENT, { o = ALARM, _peer = 2 }, 1)
		local alarm, alarm_event = sent(ALARM_EVENT)
		receive(FAN_EVENT, { o = FAN, _peer = 1 }, 2)
		local fan, fan_event = sent(FAN_EVENT)
		check(alarm and alarm._peer == 1 and alarm_event.target == BRIDGE_A and furniture[ALARM].is_on == false,
			"the world routes the alarm request to the transport sender's map")
		check(fan and fan._peer == 2 and fan_event.target == BRIDGE_B and furniture[FAN].is_on == false,
			"the world routes a second player's fan request to the other map")
		coop.is_dedicated = nil
	else
		authority_test(name)
	end
end
done("mods_hf_toggles")
