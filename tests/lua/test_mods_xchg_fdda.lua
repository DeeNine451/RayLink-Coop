-- Dev 57 G4-4. Real FDDA callbacks over the Lua object, transport and mode fixtures.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local actor = make_actor(vec3(0, 0, 0))
local _, remote = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500 })
local function item(section, owner, charge, id)
	local _, obj = spawn(section, vec3(0, 0, 0), owner, { cond = charge, id = id })
	obj.name = function(self) return self:section() .. tostring(self:id()) end
	return obj
end

for _, callback in ipairs({ "actor_on_item_before_pickup", "game_object_on_net_destroy", "GUI_on_show", "GUI_on_hide",
	"on_key_press", "on_key_release", "on_key_hold", "ActorMenu_on_trade_started", "ActorMenu_on_trade_closed",
	"actor_on_feeling_anomaly", "actor_on_info_callback", "actor_item_to_ruck", "actor_item_to_slot", "actor_on_item_drop" }) do
	AddScriptCallback(callback)
end

local options = {
	["pickup/enable"] = true, ["pickup/speed"] = 1.2, ["pickup/multipickup"] = false,
	["skinning/enable"] = true, ["skinning/every_part_pickup"] = false,
}
liz_fdda_redone_mcm = { get_config = function(key) return options[key] end }
INI.batteries_dead, INI.detector_simple, INI.meat, INI.hide = {}, {}, {}, {}
ini_file = function()
	return {
		section_exist = function() return false end, line_count = function() return 0 end,
		r_sec_ex = function(_, _, _, default) return default end, r_float_ex = function() return nil end,
	}
end
game.translate_string = function(key) return key end
device = function() return { width = 1024, height = 768 } end
actor.active_slot = function() return 0 end
actor.active_detector = function() return nil end
actor.item_in_slot = function() return nil end
actor.take_item = function(_, obj) SE[obj:id()].parent_id = 0 end
EDDListType = { iActorBag = 1, iActorSlot = 2 }
AC_ID = 0
object_binder = { update = function() end }
class = function(name)
	local env = getfenv(2)
	return function() env[name] = {} end
end
_ITM = { device = {} }
clsid = { wpn_knife_s = 1 }
local fx = 0
actor_effects = { play_item_fx = function() fx = fx + 1 end }
utils_obj = { play_sound = function() end }
actor_menu = { set_msg = function() end }

local actions = {}
lam2 = {
	states = { success = 1 },
	is_running = function() return #actions > 0 end,
	get_action_with_tag = function(tag)
		for _, action in ipairs(actions) do if action.tag == tag then return action end end
	end,
	get_template_action_play_animation = function() return {} end,
	get_template_action_wait_for_seconds = function() return { name = "close_wait" } end,
	add_action = function(action) actions[#actions + 1] = action end,
	log = function() end,
}

local queued = {}
local defer_give = false
ui_mutant_loot = { start = function() end, UIMutantLoot = {} }
function ui_mutant_loot.UIMutantLoot:Loot()
	for _, section in ipairs(self.sections) do alife_create_item(section, db.actor) end
	SendScriptCallback("GUI_on_hide", "UIMutantLoot")
end
local stock_create, stock_release, stock_alife = alife_create_item, alife_release, alife
local fail_create, fail_release, creates = false, false, 0
function alife_create_item(section, owner, props)
	if section == "batteries_dead" then
		if fail_create then return nil end
		creates = creates + 1
	end
	local se = stock_create(section, owner, props)
	if defer_give then
		queued[#queued + 1] = OBJ[se.id]
		OBJ[se.id] = nil
	end
	return se
end
function alife_release(obj)
	local id = type(obj.id) == "number" and obj.id or obj:id()
	if fail_release == id then return false end
	stock_release(obj)
	return true
end
function alife_process_item(_, id, props) OBJ[id]:set_condition(props.cond) end
-- The engine's create(false)/register path writes a condition into the spawn before publishing it.
utils_stpk = {
	get_item_data = function(se) return { condition = se.cond } end,
	set_item_data = function(data, se) se.cond = data.condition end,
}
function alife()
	local sim = stock_alife()
	function sim:create(section, _, _, _, parent)
		return INI[section] and { section = section, parent = parent }
	end
	function sim:register(se)
		return alife_create_item(se.section, OBJ[se.parent], { cond = se.cond })
	end
	return sim
end

local function deliver(obj)
	OBJ[obj:id()] = obj
	SendScriptCallback("actor_on_item_take", obj)
end
-- The engine's unlocalizer (engine\src\xrServerEntities\script_storage.cpp): a column-0 "local x = v" of a listed name
-- becomes "x = v" ("local x": "x = nil") before the script compiles, so x is a module field, not an upvalue.
local function unlocalize(src, names)
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local l = line:gsub("\r$", "")
		local rest = l:match("^local[ \t]+(.*)$")
		if rest and not rest:match("^function[ \t]") then
			local body = rest:gsub("%-%-.*$", "")
			local has_value = body:find("=", 1, true) ~= nil
			for v in (body:match("^([^=]*)") or ""):gmatch("[^,]+") do
				if names[v:match("^%s*(.-)%s*$")] then
					l = rest
					if not has_value then
						local code, comment = l:match("^(.-)(%-%-.*)$")
						l = code and (code .. "= nil " .. comment) or (l .. " = nil")
					end
					break
				end
			end
		end
		out[#out + 1] = l
	end
	return table.concat(out, "\n")
end
-- The names an unlocalizer .ltx lists under [script].
local function unlocal_names(ltx, script)
	local names, inside = {}, false
	local fh = assert(io.open(ltx, "r"))
	for line in fh:lines() do
		line = line:gsub("\r$", ""):gsub(";.*$", ""):match("^%s*(.-)%s*$")
		local section = line:match("^%[(.-)%]")
		if section then
			inside = section:lower() == script
		elseif inside and line ~= "" then
			names[line] = true
		end
	end
	fh:close()
	return names
end
local function corpus(name, unlocal)
	local path = "temp/review/corpus/merged/" .. name .. ".script"
	local file
	if unlocal then
		local fh = assert(io.open(path, "rb"))
		local src = fh:read("*a")
		fh:close()
		file = assert(loadstring(unlocalize(src, unlocal), "@" .. name .. ".script"))
	else
		file = assert(loadfile(path))
	end
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	setfenv(file, env)()
	return env
end
-- Regression: our gamedata\configs\unlocalizers\unlocalizer_coop_economy.ltx [item_device] has the engine turn
-- item_device's file local dev_condition into a module field. Load item_device in that shape, as the game does.
local D = corpus("item_device",
	unlocal_names("gamedata/configs/unlocalizers/unlocalizer_coop_economy.ltx", "item_device"))
assert(type(rawget(D, "dev_condition")) == "table", "the unlocalized item_device keeps dev_condition as a module field")
-- item_device's [id] = condition table (its load_state replaces it, so read it anew).
local function stored(id) return rawget(D, "dev_condition")[id] end
local P = corpus("liz_fdda_redone_item_pickup")
local S = corpus("liz_fdda_redone_mutant_skinning")

start_all()
local mode_set = modes.install(coop_mode, mode)
local X = load_script("coop_mods_xchg")
X.on_game_start()
D.on_game_start()
D.dev_critical.detector_simple = 0.05
D.dev_consumption.detector_simple = {}
P.on_game_start()
P.initialize()
S.on_game_start()
S.initialize()
S.get_template_action_mutant_skin = function(obj)
	return { name = "skin", target = obj }
end
S.get_template_action_mutant_loot = function(obj)
	return { name = "part", target = obj }
end
local file = io.open("gamedata/scripts/coop_mods_xchg_fdda.script", "r")
if file then
	file:close()
	load_script("coop_mods_xchg_fdda").on_game_start()
end
local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end
SendScriptCallback("actor_on_first_update")
tick()

local function request(op, dev, battery, dev_charge, battery_charge)
	local msg = { k = "fdda_battery", o = "1:7:" .. op, d = dev:id(), b = battery and battery:id(),
		dc = dev_charge or dev:condition(), bc = battery_charge or (battery and battery:condition()) }
	if mode == "srv_map" then msg._peer = 1 end
	coop_main.on_event("mods.xchg", coop_main.encode(msg), mode == "srv_map" and 0 or 1)
end
local function answer()
	local reply, wire = sent("mods.xchg_r")
	return reply or {}, wire and wire.target
end
local function close_animation()
	for _, action in ipairs(actions) do
		if action.name == "close_wait" and action.on_exit then action:on_exit() end
	end
end
local function count_actions(name)
	local n = 0
	for _, action in ipairs(actions) do if action.name == name then n = n + 1 end end
	return n
end
local function loot(corpse, sections)
	local ui = setmetatable({ id = corpse:id(), obj = corpse, sections = sections }, { __index = ui_mutant_loot.UIMutantLoot })
	ui_mutant_loot.GUI = ui
	SendScriptCallback("GUI_on_show", "UIMutantLoot")
	ui:Loot(true)
end
local function pickup(obj)
	SendScriptCallback("actor_on_item_before_pickup", obj, {})
	return actions[#actions]
end
local function mark(id)
	local marks = coop_mods_core.find_local(P, "items_in_pickup")
	return marks and marks[id]
end

if mode == "hostplay" or mode == "srv_map" then
	local dev, batt = item("detector_simple", 500, 0.3), item("batteries_dead", 500, 0.9)
	local dev_id, batt_id = dev:id(), batt:id()
	local released = #RELEASED
	request(1, dev, batt, 0.3, 0.9)
	request(1, dev, batt, 0.3, 0.9)
	local reply, target = answer()
	check(reply.ok == true and target == 1 and creates == 1 and #RELEASED == released + 1 and SE[batt_id] == nil
		and dev:condition() == 0.9 and CREATED[#CREATED].cond == 0.3, mode .. ": swap commits once and returns the extracted charge")
	check(stored(dev_id) == nil, mode .. ": R32 setter has no exchange-side charge copy")
	D.dev_condition[dev_id] = 0.3
	D.device_binder.update({ object = dev }, 0)
	check(dev:condition() == 0.9, mode .. ": stock binder cannot restore stale charge over the engine's item state")

	local d2, b2 = item("detector_simple", 500, 0.4), item("batteries_dead", 500, 0.8)
	fail_create = true
	request(2, d2, b2)
	check(answer().why == "create" and d2:condition() == 0.4 and SE[b2:id()] and X.reserved(d2:id()) == nil,
		mode .. ": failed create rolls back without spending or draining")
	fail_create = false
	fail_release = b2:id()
	request(3, d2, b2)
	local output = CREATED[#CREATED] or {}
	check(answer().why == "release" and d2:condition() == 0.4 and SE[b2:id()] and output.id and SE[output.id] == nil,
		mode .. ": failed release restores the charge and removes the output")
	check(stored(d2:id()) == nil, mode .. ": charge rollback uses the setter only")
	fail_release = false

	local other = item("detector_simple", 0, 0.4)
	local before = creates
	coop_trust.reset_for_test({ default = "log" })
	request(4, other, b2)
	local trust = coop_trust.status().xchg_fdda_battery or {}
	check(answer().why == "owner" and creates == before and trust.failed == 1 and trust.refused == 0,
		mode .. ": log mode records the claim but never reserves another player's item")
	coop_trust.reset_for_test({ default = "refuse" })
	request(14, other, b2)
	trust = coop_trust.status().xchg_fdda_battery or {}
	check(answer().why == "owner" and creates == before and other:condition() == 0.4 and trust.refused == 1,
		mode .. ": foreign owner refused through trust")
	request(5, d2, b2, 0.2, 0.8)
	check(answer().why == "charge" and creates == before, mode .. ": stale source charge refused")
	request(6, d2, nil)
	check(answer().ok == true and math.abs(d2:condition() - 0.0001) < 0.00001 and CREATED[#CREATED].cond == 0.4,
		mode .. ": extraction commits only after creating a charged battery")
	check(X.reserved(dev_id) == nil, mode .. ": device reservation is released")
	coop_trust.reset_for_test({ default = "log" })
	local stale = item("detector_simple", 500, 0.6)
	request(7, stale, nil, 0.3)
	trust = coop_trust.status().xchg_fdda_battery or {}
	check(answer().ok == true and trust.failed == 1 and trust.refused == 0 and CREATED[#CREATED].cond == 0.6,
		mode .. ": log mode uses the authoritative charge when the client's observation is stale")

	if mode == "hostplay" then
		local own = item("detector_simple", 0, 0.4)
		local count = fx
		D.func_battery(own)
		check(math.abs(own:condition() - 0.0001) < 0.00001 and fx == count + 1 and X.stats.asked == 1,
			"hostplay: own extraction uses the same operation directly")
	end
elseif mode == "srv_world" then
	local dev = item("detector_simple", 500, 0.3)
	request(1, dev)
	local relayed, wire = sent("mods.xchg")
	check(relayed and relayed._peer == 1 and wire.target == mode_set.bridge and creates == 0,
		"srv_world: world server relays the request without touching the inventory")
end

if mode == "srv_map" or mode == "hostplay" then
	MODE, SELF = "client", 1
	modes.install(coop_mode, mode, {
		actor_is_player = function() return true end, leads_here = function() return false end,
		is_player_mirror = function() return true end, decides_world = function() return false end,
	})
end
if mode == "hostplay" or mode == "srv_map" then
	local d1, d2, input = item("detector_simple", 0, 0.3), item("detector_simple", 0, 0.4), item("batteries_dead", 0, 0.9)
	local sound_before, sent_before = fx, sent_count("mods.xchg")
	local function drag(device)
		SendScriptCallback("ActorMenu_on_item_drag_drop", input, device, EDDListType.iActorBag, EDDListType.iActorSlot)
	end
	drag(d1)
	drag(d2)
	local wire_request = sent("mods.xchg")
	check(sent_count("mods.xchg") == sent_before + 1 and wire_request.d == d1:id() and wire_request.b == input:id()
		and d1:condition() == 0.3 and fx == sound_before,
		mode .. ": lagged client reserves its input across different device requests")
	if wire_request then
		coop_main.on_event("mods.xchg_r", coop_main.encode({ o = wire_request.o, ok = true, ["r.charge"] = 0.9 }), 0)
	end
	check(d1:condition() == 0.3 and d2:condition() == 0.4 and fx == sound_before + 1,
		mode .. ": receipt plays the effect once without setting a mirror's charge")
	check(stored(d1:id()) == nil and stored(d2:id()) == nil,
		mode .. ": receipt does not shadow the item's condition")
	d1:set_condition(0.9) -- simulate WP6's authoritative baseline reaching the owner

	local first, second = item("meat"), item("hide")
	local a = pickup(first)
	tick(1001)
	local b = pickup(second)
	if a then a:on_skip() end
	check(a and b and not rawequal(a, b) and not mark(first:id()) and mark(second:id()),
		mode .. ": pickup cancel clears only the cancelled action's mark")
	actions = {}
	tick(1001)
	local missing = item("hide")
	local missing_action = pickup(missing)
	release_id(missing:id())
	if missing_action then missing_action:on_take() end
	check(missing_action and not mark(missing:id()), mode .. ": missing item clears the mark at the midpoint")
	actions = {}
	tick(1001)
	local old = item("meat")
	local c = pickup(old)
	SendScriptCallback("game_object_on_net_destroy", old)
	release_id(old:id())
	local replacement = item("meat", nil, nil, old:id())
	if c then c:on_take() end
	check(SE[replacement:id()].parent_id == 65535, mode .. ": recycled id does not pick up the replacement")
	actions = {}
	tick(1001)
	local claimed = item("meat")
	local claimed_action = pickup(claimed)
	SE[claimed:id()].parent_id = remote:id()
	if claimed_action then claimed_action:on_take() end
	check(SE[claimed:id()].parent_id == remote:id() and not mark(claimed:id()),
		mode .. ": pickup refuses an item another player already owns")

	local corpse = item("dead_boar")
	defer_give = true
	actions = {}
	loot(corpse, { "meat", "meat" })
	deliver(item("meat", actor:id()))
	check(count_actions("skin") == 0 and count_actions("part") == 0,
		mode .. ": skinning ignores unrelated inventory arrivals of the same section")
	close_animation()
	tick(500)
	deliver(queued[1])
	tick()
	deliver(queued[2])
	tick()
	check(count_actions("skin") == 1 and count_actions("part") == 1,
		mode .. ": delayed loot still animates once with every_part_pickup off")

	actions, queued = {}, {}
	options["skinning/every_part_pickup"] = true
	S.initialize()
	loot(corpse, { "meat", "meat" })
	close_animation()
	tick(500)
	deliver(queued[1])
	tick()
	deliver(queued[2])
	tick()
	check(count_actions("skin") == 1 and count_actions("part") == 2,
		mode .. ": every_part_pickup animates each expected part")

	actions, queued = {}, {}
	local subscriptions = axr_main.count("actor_on_item_take")
	loot(corpse, { "meat" })
	tick(9999)
	check(axr_main.count("actor_on_item_take") == subscriptions + 1,
		mode .. ": only the concrete give remains subscribed before timeout")
	tick(1)
	deliver(queued[1])
	tick()
	check(axr_main.count("actor_on_item_take") == subscriptions and count_actions("skin") == 0 and count_actions("part") == 0,
		mode .. ": skinning subscription ends at 10 seconds and ignores late results")

	actions, queued = {}, {}
	local leases = 0
	local waiting = true
	coop.lease_ids = function() return leases end
	coop.lease_waiting = function() return waiting end
	loot(corpse, { "meat" })
	tick(200)
	check(#queued == 0, mode .. ": skinning waits for a lease to correlate the actual give")
	leases = 1
	tick()
	if queued[1] then deliver(queued[1]) end
	tick()
	check(#queued == 1 and count_actions("part") == 0,
		mode .. ": provisional leased loot is ignored until confirmed")
	waiting = false
	tick()
	check(count_actions("skin") == 1 and count_actions("part") == 1,
		mode .. ": the approved leased result animates once")

	actions, queued = {}, {}
	leases = 0
	loot(corpse, { "meat" })
	tick(10000)
	if queued[1] then deliver(queued[1]) end
	check(#queued == 1 and count_actions("part") == 0 and axr_main.count("actor_on_item_take") == subscriptions,
		mode .. ": at lease timeout the original grant is issued without an ambiguous animation")
elseif mode == "none" then
	local dev, batt = item("detector_simple", 0, 0.3), item("batteries_dead", 0, 0.9)
	SendScriptCallback("ActorMenu_on_item_drag_drop", batt, dev, EDDListType.iActorBag, EDDListType.iActorSlot)
	check(dev:condition() == 0.9 and creates == 1 and fx == 1 and X.stats.asked == 0, "single player uses original drag/drop")
	local picked = item("meat")
	local a = pickup(picked)
	if a then a:on_take() end
	check(a and SE[picked:id()].parent_id == 0, "single player uses original pickup action")
	actions = {}
	loot(item("dead_boar"), { "meat" })
	check(count_actions("close_wait") == 1, "single player uses original skinning subscription timer")
end

done("mods_xchg_fdda@" .. mode)
