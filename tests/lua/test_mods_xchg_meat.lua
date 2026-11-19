-- Dev 57, G4-6. Run the merged addons through the adapter, the real exchange dispatcher and the S4 facade.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local MEAT = "meat_raw"
local DONE = "mods.xchg_meat_done"
local live = true
coop.is_live = function() return live end
coop.world_epoch = function() return 7 end
make_actor()
spawn("coop_player_avatar", nil, nil, { id = 500 })
spawn("coop_player_avatar", nil, nil, { id = 501 })
local original_peer_of_avatar = coop.peer_of_avatar
coop.peer_of_avatar = function(id)
	if id == 501 then return 2 end
	return original_peer_of_avatar(id)
end
local set_time_event = CreateTimeEvent
function CreateTimeEvent(group, action, ...)
	if not TIMEEV[tostring(group) .. ":" .. tostring(action)] then
		return set_time_event(group, action, ...)
	end
end

local clock = 1000
function game.CTime()
	return {
		set = function(self, _, _, _, _, m, s) self.s = m * 60 + s end,
		get = function(self) return 2012, 9, 1, 0, math.floor(self.s / 60), self.s % 60, 0 end,
		diffSec = function(self, other) return self.s - other.s end,
	}
end
game.get_game_time = function()
	local t = game.CTime()
	t.s = clock
	return t
end
function ini_file_ex() return { ini = {} } end
utils_data = { collect_section = function() return { [MEAT] = true } end }
function GetARGB() return 0 end
ui_item = {}
ui_inventory = { UIInventory = {} }
rax_persistent_highlight = { register = function() end }
rax_icon_layers = { register = function() end }
SYS_GetParam = function(_, sec) return sec == "af_junk" and "i_arty_junk" or "" end
perk_based_artefacts_mcm = { op = { gr = { { id = "treasure_chance", def = 0 } } } }

local base_create = alife_create_item
function alife_create_item(sec, parent, ...)
	-- The addon uses server parents, whereas the harness's helper takes an online parent.
	local item = base_create(sec, type(parent.id) == "number" and OBJ[parent.id] or parent, ...)
	function item:name() return sec .. "_" .. item.id end
	return item
end

local function load_addon(n)
	local path = "temp/review/corpus/merged/" .. n .. ".script"
	local env = setmetatable({}, { __index = _G })
	rawset(_G, n, env)
	setfenv(assert(loadfile(path)), env)()
	return env
end

AddScriptCallback("actor_on_item_use")
AddScriptCallback("physic_object_on_use_callback")
local meat = load_addon("meat_spoiling")
local pba = load_addon("zz_treasure_manager_pba_less_artys")
local function box_at(id)
	local _, obj = spawn("box", nil, nil, { id = id, kind = "box" })
	function obj:name() return "treasure_" .. id end
	obj.iterate_inventory_box = obj.iterate_inventory
	return obj
end
local function expiry(sec)
	return { duration = sec, last_update = { Y = 2012, M = 9, D = 1, h = 0, m = math.floor(clock / 60), s = clock % 60, ms = 0 } }
end
local function raw_meat(id, owner, remaining)
	local item = spawn(MEAT, nil, owner, { id = id })
	function item:name() return MEAT .. "_" .. id end
	meat.expiration_table[id] = expiry(remaining or 0)
	return item
end
local function tick(ms)
	NOW = NOW + (ms or 0)
	SendScriptCallback("actor_on_update")
end
local function request(id, op, from)
	local t = { k = "meat", i = id, o = from .. ":7:" .. op }
	if name == "srv_map" then t._peer, from = from, 0 end
	coop_main.on_event("mods.xchg", coop_main.encode(t), from)
end
local function notify(id, new_id, from)
	coop_main.on_event(DONE, coop_main.encode({ i = id, r = new_id }), from)
end
local function replacements(parent)
	local n = 0
	for _, item in pairs(SE) do
		if item.parent_id == parent and item:section_name() == "rotten_meat" then n = n + 1 end
	end
	return n
end
local function box_marks()
	local saved = {}
	pba.save_state(saved)
	return saved.pba_less_artys_boxes
end

start_all()
load_script("coop_mods_xchg").on_game_start()
local file = io.open(ROOT .. "scripts/coop_mods_xchg_meat.script", "r")
local adapter
if file then
	file:close()
	adapter = load_script("coop_mods_xchg_meat")
end
-- The item adapter captures this callback by value, before the addon registers it.
local box_open = pba.physic_object_on_use_callback
meat.on_game_start()
pba.on_game_start()
if adapter then adapter.on_game_start() end
local mode_set = modes.install(coop_mode, name)
if name == "srv_map" then
	SELF = 257
	coop.is_host = function() return false end
	coop.is_map_server = function() return true end
	coop.avatar_of = function(peer) return ({ [1] = 500, [2] = 501 })[peer] end
elseif name == "srv_world" then
	coop.is_dedicated = function() return true end
end

if name == "hostplay" or name == "srv_map" then
	-- m32:1: both clocks can fire before the replacement is online. A stock remote holder isn't AC_ID.
	raw_meat(11, 500)
	raw_meat(12, 500)
	local original_create = alife_create_item
	local delayed = {}
	alife_create_item = function(sec, parent)
		local item = original_create(sec, parent)
		delayed[item.id], OBJ[item.id] = OBJ[item.id], nil
		return item
	end
	meat.tick_expiration()
	request(11, 1, 1)
	request(11, 2, 1)
	check(SE[11] ~= nil and SE[12] ~= nil and meat.expiration_table[11] ~= nil,
		"m32:1 keeps original meat and its clock until the replacement is in the inventory")
	for id, obj in pairs(delayed) do OBJ[id] = obj end
	tick(100)
	tick(100)
	check(SE[11] == nil and SE[12] == nil and replacements(500) == 2 and #CREATED == 2,
		"m32:1 authority timer and duplicate client requests replace each item exactly once")
	check(meat.expiration_table[11] == nil and sent_count(DONE) == 2,
		"m32:1 the decider acknowledges each swap after both world changes")
	alife_create_item = original_create

	local send_event = coop.send_event
	local rejected = 0
	coop.send_event = function(verb, ...)
		if verb == DONE and rejected == 0 then rejected = rejected + 1; return false end
		return send_event(verb, ...)
	end
	raw_meat(17, 500, 10)
	meat.tick_expiration()
	check(SE[17] ~= nil and #CREATED == 2, "fresh meat cannot be replaced before the clock expires")
	clock = clock + 10
	meat.tick_expiration()
	tick(100)
	tick(100)
	tick(1000)
	local receipt, delivery = sent(DONE)
	check(rejected == 1 and receipt and receipt.i == 17 and delivery.target == 1,
		"a full outgoing queue delays and retries the confirmed swap notification")
	coop.send_event = send_event

	raw_meat(13, 500)
	raw_meat(14, 501)
	request(14, 3, 1)
	request(65535, 4, 1)
	local trust = coop_trust.status().xchg_meat
	check(trust and trust.failed >= 2 and SE[14] ~= nil and replacements(501) == 0,
		"out-of-range and foreign-item requests reach trust and cannot act")

	local original_release = alife_release
	alife_release = function(item)
		if item.id ~= 13 then return original_release(item) end
	end
	meat.tick_expiration()
	tick(100)
	tick(10100)
	tick(100)
	check(SE[13] ~= nil and meat.expiration_table[13] ~= nil and replacements(500) == 3,
		"a failed removal rolls the replacement back and retains the original clock")
	alife_release = original_release

	if name == "hostplay" then
		raw_meat(15, 0)
		meat.tick_expiration()
		tick(100)
		tick(100)
		check(SE[15] == nil and replacements(0) == 1, "the co-op host's player uses the same replacement")
	else
		local other_map = true
		modes.install(coop_mode, name, {
			decider = function(peer) return peer == 2 and other_map and "other" or mode_set.decider(peer) end,
		})
		raw_meat(16, 501)
		meat.tick_expiration()
		tick(100)
		tick(100)
		check(SE[16] ~= nil and meat.expiration_table[16] ~= nil, "spoil waits while the holder belongs to a different map")
		other_map = false
		meat.tick_expiration()
		tick(100)
		tick(100)
		check(SE[16] == nil and replacements(501) >= 1, "spoil resumes on the holder's own map")
	end

	local one, two = box_at(40), box_at(41)
	spawn("af_junk", nil, 40, { id = 42 })
	spawn("af_junk", nil, 41, { id = 43 })
	box_open(one)
	box_open(two)
	box_open(one)
	check(not box_marks()[40] and not box_marks()[41], "m27:7 queued boxes stay unmarked for save and sharing")
	run_time_events()
	check(SE[42] == nil and SE[43] == nil and box_marks()[40] and box_marks()[41],
		"m27:7 both box timers clean their own inventory and mark completion")
	spawn("af_junk", nil, 40, { id = 44 })
	box_open(one)
	run_time_events()
	check(SE[44] ~= nil, "m27:7 reopening a completed box does not reroll it")

	local three = box_at(45)
	spawn("af_junk", nil, 45, { id = 46 })
	box_open(three)
	pba.load_state({})
	box_open(three)
	run_time_events()
	check(SE[46] == nil and box_marks()[45], "an old box timer cannot displace a new load's cleanup of the same box")
end

if name == "hostplay" or name == "srv_map" then
	-- m32:3: the original first-update callback can be registered before the adapter startup or called by value.
	MODE, SELF, live = "client", 1, false
	coop.is_map_server = function() return false end
	modes.install(coop_mode, name, {
		actor_is_player = function() return true end,
		leads_here = function() return false end,
		decides_world = function() return false end,
		is_player_mirror = function() return true end,
		decider = function() return "other" end,
	})
	local old_create, old_release, old_requests = #CREATED, #RELEASED, sent_count("mods.xchg")
	raw_meat(20, 0)
	SendScriptCallback("actor_on_first_update")
	check(SE[20] ~= nil and meat.expiration_table[20] ~= nil and sent_count("mods.xchg") == old_requests,
		"m32:3 first update while loading preserves the timer and issues no request")
	live = true
	tick(10001)
	local ask = sent("mods.xchg")
	check(ask and ask.k == "meat" and ask.i == 20 and sent_count("mods.xchg") > old_requests
		and #CREATED == old_create and #RELEASED == old_release and meat.expiration_table[20] ~= nil,
		"m32:3 expiry resumes when live and asks the decider without local writes")
	notify(20, 21, 2)
	tick(100)
	check(meat.expiration_table[20] ~= nil, "a different player cannot confirm a replacement")
	notify(20, 21, 0)
	tick(100)
	check(meat.expiration_table[20] ~= nil, "m32:3 an early confirmation does not clear a still-present item")
	release_id(20)
	spawn("rotten_meat", nil, 0, { id = 21 })
	tick(100)
	check(meat.expiration_table[20] == nil, "m32:3 the timer drops after the confirmed swap reaches the mirror")
elseif name == "srv_world" then
	raw_meat(30, 500)
	meat.tick_expiration()
	request(30, 1, 1)
	tick(100)
	local _, relay = sent("mods.xchg")
	check(SE[30] ~= nil and #CREATED == 0 and #RELEASED == 0,
		"the world server leaves spoilage to the holder's map server")
	check(relay and relay.target == mode_set.bridge, "the world server relays the request to the map server")
else
	raw_meat(10, 0)
	meat.tick_expiration()
	check(SE[10] == nil and replacements(0) == 1 and meat.expiration_table[10] == nil,
		"single-player expiry still calls the original addon")
	local one = box_at(40)
	spawn("af_junk", nil, 40, { id = 42 })
	box_open(one)
	check(box_marks()[40] and TIMEEV["pba_less_artys:pba_less_artys"] ~= nil,
		"single-player PBA uses the original timer and mark")
	run_time_events()
	check(SE[42] == nil, "single-player PBA still executes the original cleanup")
end

done("mods_xchg_meat@" .. name)
