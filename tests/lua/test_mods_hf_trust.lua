-- Anomaly Coop test (TZ v2 6.4, round 2, 2026-11-18): Hideout Furniture's lamps on the host. A client's lamp light names the
-- tool, a refuel names the fuel item; the host checks it is this player's and of the kind the lamp needs (coop_trust
-- "hf_lamp_tool", "hf_refuel_item"), spends what the mod spends (a plain item, the last use: the host removes it; a use of a
-- multi-use item or a step of condition: his machine, whose state it is, and the host checks it went at the next request) and
-- answers mods.hf_item_r. A build 56 request without the id goes through as before (logged: "hf_refuel_item_id"; a lamp's tool is
-- still looked for among his items). Not shipped. Run: tools\test_lua.cmd mods_hf_trust
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== Hideout Furniture lamps: tools and fuel (host)")
make_actor(vec3(0, 0, 0))
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local _, other = spawn("coop_player_avatar", vec3(22, 0, 0), nil, { id = 600 })
other._kind = "stalker"
local function from_client(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 1) end

-------------------------------------------------------------------------------
-- the mod's shapes (ui_furniture_light.toggle_light / UIFurnitureLight:Refuel, bind_hf_base wrappers, hf_obj_manager)
-------------------------------------------------------------------------------
INI.hf_lamp = { require_matches = true, fuel_section = "charcoal" }
INI.hf_lamp_tools = { require_tool = "hf_lighter" }
INI.hf_lamp_free = {}
INI.matches = {}
INI.box_matches = { multiuse = 5, use_condition = true }
INI.hf_lighter = { use_condition = true }
INI.charcoal = { multiuse = 3, use_condition = true }
INI.bread = {}
function parse_list(ini, sec, key)
	local s = ini:r_string_ex(sec, key)
	local t = {}
	if s then for w in s:gmatch("[^,%s]+") do t[#t + 1] = w end end
	return t
end
function IsItem(kind, sec, obj)
	sec = sec or (obj and obj:section())
	if kind == "multiuse" then return INI[sec] and INI[sec].multiuse or nil end
	return nil
end
local GO = getmetatable(avatar)
function GO:get_remaining_uses() return self._uses or 1 end
function GO:set_remaining_uses(n) self._uses = n end
utils_item = {
	is_degradable = function(o) local i = INI[o:section()]; return i ~= nil and i.use_condition == true and not i.multiuse end,
	degrade = function() error("the host never degrades a player's item: its condition is his machine's") end,
	discharge = function() error("the host never discharges a player's item: its uses are his machine's") end,
}
HF_DATA = {}
hf_obj_manager = {
	get_data = function(id) return HF_DATA[id] or {} end,
	update_data = function(id, t) HF_DATA[id] = HF_DATA[id] or {}; for k, v in pairs(t) do HF_DATA[id][k] = v end end,
	delete_data = function(id) HF_DATA[id] = nil end,
}
WRAPPERS = {}
bind_hf_base = { hf_binder_wrapper = {}, get_wrapper = function(id) return WRAPPERS[id] end }
placeable_furniture = {
	create_object = function(section, loc, rot, lv, gv) local se = alife_create(section, loc, lv, gv); return se.id end,
	func_place_item = function() end, start_placing_item = function() end, pickup_obj = function() end }
INI.hf_lamp_item = { placeable_section = "hf_lamp" }
ui_furniture_light = { toggle_light = function() end, UIFurnitureLight = { Pickup = function() end, Refuel = function() end } }

start_all()
local T = coop_trust

local function lamp(sec, pos)
	local _, o = spawn(sec or "hf_lamp", pos or vec3(21, 0, 0))
	WRAPPERS[o:id()] = { fuel = 0.2 }
	return o
end
local function held(sec, owner, opts)
	local _, o = spawn(sec, vec3(20, 0, 0), owner or 500)
	if opts then for k, v in pairs(opts) do o[k] = v end end
	return o
end
local function counter(name) return T.status()[name] or { checked = 0, failed = 0, refused = 0 } end
local function answers() return sent_count("mods.hf_item_r") end
local function last_answer()
	local t, raw = sent("mods.hf_item_r")
	return t and t.r, t and t.i, raw and raw.target
end
local function released(id)
	for _, r in ipairs(RELEASED) do if r.id == id then return true end end
	return false
end
local function light(l, item)
	NOW = NOW + 1000
	from_client("hf_lamp", { o = l:id(), on = true, i = item and item:id() or nil })
end
local function off(l)
	NOW = NOW + 1000
	from_client("hf_lamp", { o = l:id(), on = false })
end
local function refuel(l, item, no_id)
	NOW = NOW + 1000
	from_client("hf_refuel", { o = l:id(), i = (item and not no_id) and item:id() or nil })
end
local function trust_line(name)
	for i = #LOG, 1, -1 do if LOG[i]:find("[coop-trust] ! " .. name .. ":", 1, true) then return LOG[i] end end
	return nil
end

-------------------------------------------------------------------------------
print("== a lamp lit with his own matches (a plain item): the host removes them and says so")
T.reset_for_test({ default = "log" })
local l1 = lamp()
local m1 = held("matches")
light(l1, m1)
check(HF_DATA[l1:id()] and HF_DATA[l1:id()].is_on == true, "lit")
check(released(m1:id()), "the host removed the matches (the mod's discharge of a plain item)")
local r, i, to = last_answer()
check(r == "took" and i == m1:id() and to == 1, "answered 'took' to the player")
check(counter("hf_lamp_tool").checked == 1 and counter("hf_lamp_tool").failed == 0, "hf_lamp_tool checked, passed")

print("== a box of matches (5 uses): his machine spends a use, the host checks it went at the next light")
off(l1)
check(HF_DATA[l1:id()].is_on == false and counter("hf_lamp_tool").checked == 1, "off: no tool, no check")
local bm = held("box_matches", 500, { _uses = 5 })
light(l1, bm)
r = last_answer()
check(HF_DATA[l1:id()].is_on == true and r == "left" and not released(bm:id()), "lit, the use left to his machine")
off(l1)
light(l1, bm) -- his machine never spent it: still 5
check(counter("hf_lamp_tool").failed == 1 and (trust_line("hf_lamp_tool") or ""):find("not spent", 1, true) ~= nil,
	"the use left last time was not spent: logged")
check(HF_DATA[l1:id()].is_on == true and last_answer() == "left", "log mode: lit anyway, his machine told to spend it")
off(l1)
bm._uses = 4 -- his machine spent it (his item state reached the host)
light(l1, bm)
check(counter("hf_lamp_tool").failed == 1 and HF_DATA[l1:id()].is_on == true, "spent meanwhile: ok")
off(l1)
bm._uses = 1
light(l1, bm) -- (4 -> 1: lower, the last use)
check(released(bm:id()) and last_answer() == "took", "the last use: the host removes the box")

print("== a lighter (condition): a step of its condition is his machine's")
local l2 = lamp("hf_lamp_tools")
local lt = held("hf_lighter", 500, { _cond = 0.5 })
light(l2, lt)
check(HF_DATA[l2:id()].is_on == true and last_answer() == "left" and not released(lt:id()), "lit, the step left to his machine")
off(l2)
lt._cond = 0.04 -- spent below one step
light(l2, lt)
check(released(lt:id()) and last_answer() == "took", "under one step of condition: the host removes it (the mod's degrade)")

print("== the wrong tool, another player's matches, an unknown item")
off(l1)
local bread = held("bread")
light(l1, bread)
check(counter("hf_lamp_tool").failed == 2 and (trust_line("hf_lamp_tool") or ""):find("bread", 1, true) ~= nil, "bread is no tool")
check(HF_DATA[l1:id()].is_on == true and last_answer() == "left" and not released(bread:id()),
	"log mode: lit as today, the host keeps its hands off, his machine spends its own copy")
off(l1)
local foreign = held("matches", 600)
light(l1, foreign)
check(counter("hf_lamp_tool").failed == 3 and not released(foreign:id()), "another player's matches: logged, not removed")
off(l1)
light(l1, { id = function() return 4321 end })
check(counter("hf_lamp_tool").failed == 4, "an item the host does not know: logged")

print("== refuse mode: nothing lit, nothing spent")
T.reset_for_test({ default = "log", hf_lamp_tool = "refuse" })
off(l1)
light(l1, foreign)
check(HF_DATA[l1:id()].is_on == false and last_answer() == "no" and not released(foreign:id()), "refused: not lit, answered 'no'")
local m2 = held("matches")
light(l1, m2)
check(HF_DATA[l1:id()].is_on == true and released(m2:id()), "an honest light still goes")

print("== a client of build 56 (no id): his matches are looked for among his items")
T.reset_for_test({ default = "log" })
off(l1)
local before = answers()
local m3 = held("matches")
light(l1, nil)
check(HF_DATA[l1:id()].is_on == true and counter("hf_lamp_tool").failed == 0 and answers() == before,
	"he holds matches: lit, nothing answered (his machine spent them, as build 56 did)")
check(not released(m3:id()), "the host removes nothing for a build 56 client")
release_id(m3:id())
off(l1)
light(l1, nil)
check(counter("hf_lamp_tool").failed == 1 and HF_DATA[l1:id()].is_on == true, "no tool among his items: logged, lit as today")

print("== a lamp that needs no tool, a far lamp")
T.reset_for_test({ default = "log" })
local l3 = lamp("hf_lamp_free")
light(l3, nil)
check(HF_DATA[l3:id()].is_on == true and counter("hf_lamp_tool").checked == 0, "no tool needed: no check")
local far = lamp("hf_lamp", vec3(200, 0, 0))
local m4 = held("matches")
light(far, m4)
check(last_answer() == "no" and not released(m4:id()) and not (HF_DATA[far:id()] and HF_DATA[far:id()].is_on),
	"a far lamp: refused as before, answered 'no' (nothing spent)")

-------------------------------------------------------------------------------
print("== refuel with his charcoal (3 uses): refuelled, the use left to his machine, checked at the next refuel")
T.reset_for_test({ default = "log" })
local l4 = lamp()
local c1 = held("charcoal", 500, { _uses = 3 })
refuel(l4, c1)
check(WRAPPERS[l4:id()].fuel == 1.0 and last_answer() == "left" and not released(c1:id()), "refuelled, one use left to him")
check(counter("hf_refuel_item").checked == 1 and counter("hf_refuel_item").failed == 0, "hf_refuel_item checked, passed")
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, c1) -- still 3 uses: his machine did not spend it
check(counter("hf_refuel_item").failed == 1 and (trust_line("hf_refuel_item") or ""):find("not spent", 1, true) ~= nil,
	"endless fuel from one charcoal: logged")
check(WRAPPERS[l4:id()].fuel == 1.0, "log mode: refuelled as today")
WRAPPERS[l4:id()].fuel = 0.1
c1._uses = 1
refuel(l4, c1)
check(WRAPPERS[l4:id()].fuel == 1.0 and released(c1:id()) and last_answer() == "took", "the last use: the host removes it")

print("== refuel with the wrong item, another player's, refuse mode")
WRAPPERS[l4:id()].fuel = 0.1
local b2 = held("bread")
refuel(l4, b2)
check(counter("hf_refuel_item").failed == 2 and WRAPPERS[l4:id()].fuel == 1.0 and last_answer() == "left"
	and not released(b2:id()), "bread: logged, refuelled as today, his machine spends its own copy")
T.reset_for_test({ default = "log", hf_refuel_item = "refuse" })
WRAPPERS[l4:id()].fuel = 0.1
local c2 = held("charcoal", 600, { _uses = 3 })
refuel(l4, c2)
check(WRAPPERS[l4:id()].fuel == 0.1 and last_answer() == "no" and not released(c2:id()), "refused: no fuel, answered 'no'")
local c3 = held("charcoal", 500, { _uses = 1 })
refuel(l4, c3)
check(WRAPPERS[l4:id()].fuel == 1.0 and released(c3:id()), "refuse mode: an honest refuel still goes")

print("== a client of build 56: no fuel id")
T.reset_for_test({ default = "log" })
WRAPPERS[l4:id()].fuel = 0.1
before = answers()
refuel(l4, nil)
check(WRAPPERS[l4:id()].fuel == 1.0 and counter("hf_refuel_item_id").failed == 1 and answers() == before,
	"let through as today, logged as a refuel without the fuel's id")
T.reset_for_test({ default = "log", hf_refuel_item_id = "refuse" })
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, nil)
check(WRAPPERS[l4:id()].fuel == 0.1, "refuse mode: an id-less refuel is dropped")

-------------------------------------------------------------------------------
-- Round 3 (R2-B3): placing builds the furniture's data on the host. bind_light_furniture reads data.condition as the fuel,
-- data.is_world_obj as endless fuel and data.is_on as lit: a modified client that picks its lamp up and places it again with
-- forged data would get a lit lamp with endless fuel, past hf_lamp_tool and hf_refuel_item.
print("== a lamp placed again with forged data: the data is the host's (R2-B3)")
T.reset_for_test({ default = "log", hf_lamp_tool = "refuse", hf_refuel_item = "refuse" })
local li = held("hf_lamp_item", 500, { _cond = 0.2 }) -- picked up with a fifth of its fuel (the mod: cond = fuel)
HF_DATA[li:id()] = { note = "the mod's own data of the item" }
local n0 = #CREATED
from_client("hf_place", { i = li:id(), s = "hf_lamp", x = 21, y = 0, z = 0, ax = 0, ay = 0, az = 0,
	d = coop_mods_core.ser({ condition = 1, is_world_obj = true, is_on = true }) })
local pl = CREATED[n0 + 1]
check(pl ~= nil and pl.sec == "hf_lamp" and SE[li:id()] == nil, "placed, the lamp item spent")
local pd = pl and HF_DATA[pl.id] or {}
check(pd.condition == 0.2, "the fuel is the host's item's condition (0.2), not the client's 1: " .. tostring(pd.condition))
check(pd.is_world_obj == nil, "is_world_obj never from a client: no endless fuel")
check(pd.is_on ~= true, "is_on never from a client: not lit without hf_lamp and its tool")
check(pd.note == "the mod's own data of the item" and HF_DATA[li:id()] == nil,
	"the host's own data of the item goes with it (placeable_furniture.transfer_item_data)")
-- an item the host holds no object of: no condition taken from the client either
local li2 = held("hf_lamp_item", 500)
OBJ[li2:id()] = nil
n0 = #CREATED
from_client("hf_place", { i = li2:id(), s = "hf_lamp", x = 21, y = 0, z = 0, d = coop_mods_core.ser({ condition = 1 }) })
pl = CREATED[n0 + 1]
check(pl ~= nil and (HF_DATA[pl.id] or {}).condition == nil, "item not online here: no condition at all (the mod's own rule)")

print("== a network text never becomes a format")
T.reset_for_test({ default = "log" })
INI["%s%n"] = {}
local odd = held("%s%n")
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, odd)
check((trust_line("hf_refuel_item") or ""):find("%s%n", 1, true) ~= nil, "a section with % signs is logged as it is")

done("HF TRUST HOST")
