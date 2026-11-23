-- Anomaly Coop test (TZ v2 6.4, round 2, 2026-11-18): Hideout Furniture's lamps on the host. A client's lamp light names the
-- tool, a refuel names the fuel item; the host checks it is this player's and of the kind the lamp needs (coop_trust
-- "hf_lamp_tool", "hf_refuel_item"), spends what the mod spends (a plain item, the last use, the last step: the host removes it,
-- "took"; a use of a multi-use item or a step of condition: the host spends it itself through the stock setters, "spent": R32
-- W8.1, the decider's write is the item's new state and reaches his machine; a check that failed in "log": "left", his machine
-- spends its own copy) and answers mods.hf_item_r. A build 56 request without the id goes through as before (logged: "hf_refuel_item_id"; a lamp's tool is
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
	-- R32 W8.1: the host (the item's writer) spends through the stock setters; the engine makes it the item's state
	degrade = function(o, n) HOST_SPENT[#HOST_SPENT + 1] = o:id(); o._cond = math.max((o._cond or 1) - n, 0.01) end,
	discharge = function(o)
		HOST_SPENT[#HOST_SPENT + 1] = o:id()
		assert(IsItem("multiuse", nil, o) and o:get_remaining_uses() > 1, "the host releases a plain item and the last use itself")
		o:set_remaining_uses(o:get_remaining_uses() - 1)
	end,
}
HOST_SPENT = {}
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

print("== a box of matches (5 uses): the host spends a use itself (R32 W8.1), nothing is left to his machine")
off(l1)
check(HF_DATA[l1:id()].is_on == false and counter("hf_lamp_tool").checked == 1, "off: no tool, no check")
local bm = held("box_matches", 500, { _uses = 5 })
light(l1, bm)
r = last_answer()
check(HF_DATA[l1:id()].is_on == true and r == "spent" and bm._uses == 4 and not released(bm:id()),
	"lit, the host spent one use (5 -> 4) and answered 'spent'")
off(l1)
light(l1, bm)
check(counter("hf_lamp_tool").failed == 0 and HF_DATA[l1:id()].is_on == true and bm._uses == 3 and last_answer() == "spent",
	"the next light: the host spends the next use, no check of his machine's report")
off(l1)
bm._uses = 1
light(l1, bm)
check(released(bm:id()) and last_answer() == "took", "the last use: the host removes the box")

print("== a lighter (condition): the host spends the mod's step of its condition itself")
local l2 = lamp("hf_lamp_tools")
local lt = held("hf_lighter", 500, { _cond = 0.5 })
light(l2, lt)
check(HF_DATA[l2:id()].is_on == true and last_answer() == "spent" and math.abs(lt._cond - 0.45) < 1e-9 and not released(lt:id()),
	"lit, the host degraded it by the mod's step (0.5 -> 0.45)")
off(l2)
lt._cond = 0.04 -- spent below one step
light(l2, lt)
check(released(lt:id()) and last_answer() == "took", "under one step of condition: the host removes it (the mod's degrade)")

print("== the wrong tool, another player's matches, an unknown item")
off(l1)
local bread = held("bread")
light(l1, bread)
check(counter("hf_lamp_tool").failed == 1 and (trust_line("hf_lamp_tool") or ""):find("bread", 1, true) ~= nil, "bread is no tool")
check(HF_DATA[l1:id()].is_on == true and last_answer() == "left" and not released(bread:id()),
	"log mode: lit as today, the host keeps its hands off, his machine spends its own copy")
off(l1)
local foreign = held("matches", 600)
light(l1, foreign)
check(counter("hf_lamp_tool").failed == 2 and not released(foreign:id()), "another player's matches: logged, not removed")
off(l1)
light(l1, { id = function() return 4321 end })
check(counter("hf_lamp_tool").failed == 3, "an item the host does not know: logged")

print("== refuse mode: nothing lit, nothing spent")
T.reset_for_test({ default = "log", hf_lamp_tool = "refuse" })
off(l1)
light(l1, foreign)
check(HF_DATA[l1:id()].is_on == false and last_answer() == "no" and not released(foreign:id()), "refused: not lit, answered 'no'")
local m2 = held("matches")
light(l1, m2)
check(HF_DATA[l1:id()].is_on == true and released(m2:id()), "an honest light still goes")

-- Round 6 (review 5, H1): the stock utils_item.degrade clamps the new condition to 0.01, so a lighter at 0.055 drops only to
-- 0.01 (a step of 0.045). The host takes that as spent and removes it at the next light, as the mod does.
print("== a lighter at the end of its life: degrade clamps to 0.01, still spent")
off(l2)
local le = held("hf_lighter", 500, { _cond = 0.155 })
light(l2, le) -- 0.155: the host spends a step
local fails = counter("hf_lamp_tool").failed
for _, c in ipairs({ 0.105, 0.055 }) do
	off(l2); le._cond = c; light(l2, le)
end
check(counter("hf_lamp_tool").failed == fails and HF_DATA[l2:id()].is_on == true, "0.155 -> 0.105 -> 0.055: each step passes")
off(l2); le._cond = 0.01; light(l2, le)
check(counter("hf_lamp_tool").failed == fails and HF_DATA[l2:id()].is_on == true,
	"0.055 -> 0.01 (degrade's clamp): passes in refuse mode: " .. tostring(trust_line("hf_lamp_tool")))
check(released(le:id()) and last_answer() == "took", "at 0.01 the host removes the lighter, as the mod does")

-- Round 4 (blocker 2 of the round 3 review): a light without the tool's id is its own check, hf_lamp_tool_id, that always
-- fails (as hf_refuel_item_id and mine_item_id): "log" lights it as today, "refuse" lights nothing. Mixed builds cannot connect
-- (the content manifest), so no honest client sends one; the build 56 branch passed hf_lamp_tool and spent nothing anywhere.
print("== a light without the tool's id (a client of build 56): its own check hf_lamp_tool_id")
T.reset_for_test({ default = "log" })
off(l1)
local before = answers()
local m3 = held("matches")
light(l1, nil)
check(HF_DATA[l1:id()].is_on == true and answers() == before,
	"log mode: lit as today, nothing answered (his machine spent them, as build 56 did)")
check(counter("hf_lamp_tool_id").failed == 1 and counter("hf_lamp_tool").checked == 0
	and (trust_line("hf_lamp_tool_id") or ""):find("without", 1, true) ~= nil,
	"logged under hf_lamp_tool_id (not passed through hf_lamp_tool): " .. tostring(trust_line("hf_lamp_tool_id")))
check(not released(m3:id()), "the host removes nothing for a request without an id")
release_id(m3:id())
off(l1)
light(l1, nil)
check(counter("hf_lamp_tool_id").failed == 2 and HF_DATA[l1:id()].is_on == true, "no tool among his items either: logged, lit as today")
off(l1)
from_client("hf_lamp", { o = l1:id(), on = true, i = "a match" })
check(counter("hf_lamp_tool_id").failed == 3 and counter("hf_lamp_tool").checked == 0 and HF_DATA[l1:id()].is_on == true,
	"an id that is no number: the same check, log mode lights it")
-- the review's probe: one box of matches with 2 uses, ten lights without the id, refuse
T.reset_for_test({ default = "log", hf_lamp_tool_id = "refuse" })
local bm2 = held("box_matches", 500, { _uses = 2 })
local lit = 0
for _ = 1, 10 do
	off(l1)
	light(l1, nil)
	if HF_DATA[l1:id()].is_on == true then lit = lit + 1 end
end
check(lit == 0 and counter("hf_lamp_tool_id").refused == 10 and bm2._uses == 2 and not released(bm2:id()),
	"refuse: ten lights without the id light nothing (lit " .. lit .. ", refused " .. counter("hf_lamp_tool_id").refused .. ")")
off(l1)
from_client("hf_lamp", { o = l1:id(), on = true, i = "a match" })
check(HF_DATA[l1:id()].is_on == false and counter("hf_lamp_tool_id").refused == 11, "refuse: an id that is no number lights nothing")
light(l1, bm2)
check(HF_DATA[l1:id()].is_on == true and last_answer() == "spent" and bm2._uses == 1, "refuse: an honest light with the id still goes")
release_id(bm2:id())

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
print("== refuel with his charcoal (3 uses): refuelled, the host spends the use itself (R32 W8.1)")
T.reset_for_test({ default = "log" })
local l4 = lamp()
local c1 = held("charcoal", 500, { _uses = 3 })
refuel(l4, c1)
check(WRAPPERS[l4:id()].fuel == 1.0 and last_answer() == "spent" and c1._uses == 2 and not released(c1:id()),
	"refuelled, the host spent one use (3 -> 2)")
check(counter("hf_refuel_item").checked == 1 and counter("hf_refuel_item").failed == 0, "hf_refuel_item checked, passed")
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, c1)
check(WRAPPERS[l4:id()].fuel == 1.0 and c1._uses == 1 and counter("hf_refuel_item").failed == 0,
	"one charcoal, one use a refuel: no endless fuel, nothing to check of his machine")
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, c1)
check(WRAPPERS[l4:id()].fuel == 1.0 and released(c1:id()) and last_answer() == "took", "the last use: the host removes it")

print("== refuel with the wrong item, another player's, refuse mode")
WRAPPERS[l4:id()].fuel = 0.1
local b2 = held("bread")
refuel(l4, b2)
check(counter("hf_refuel_item").failed == 1 and WRAPPERS[l4:id()].fuel == 1.0 and last_answer() == "left"
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

-------------------------------------------------------------------------------
-- Round 5 (blocker 3 of the round 4 review) asked the host to check that his machine spent the mod's own step. R32 W8.1 makes
-- that check moot: the host is the item's writer and spends the step itself (utils_item.degrade(obj, 0.05) for a degradable tool,
-- utils_item.discharge for the rest: one use); a report of his machine made on an older version is refused by the engine
-- (coop_items field versions), so a machine that reports 0.0001 a light changes nothing.
-------------------------------------------------------------------------------
print("== R32 W8.1: a lighter gives the mod's number of lights, whatever his machine reports")
do
	T.reset_for_test({ default = "log", hf_lamp_tool = "refuse" })
	local lp = lamp("hf_lamp_tools")
	local honest = held("hf_lighter", 500, { _cond = 0.9 })
	local lights = 0
	for _ = 1, 40 do
		if released(honest:id()) then break end
		off(lp)
		light(lp, honest)
		if HF_DATA[lp:id()].is_on == true then lights = lights + 1 end
		honest._cond = math.floor(honest._cond * 1000 + 0.5) / 1000 -- (the item state travels in steps of 1/65535 anyway)
	end
	check(lights == 18 and released(honest:id()) and counter("hf_lamp_tool").failed == 0,
		"18 lights from 0.9 by the mod's steps, spent by the host (the last at 0.05 removes it), none refused (" .. lights .. ")")
end

print("== R32 W8.1: a multi-use tool goes down by one use a light, on the host")
do
	T.reset_for_test({ default = "log", hf_lamp_tool = "refuse" })
	local lq = lamp()
	local box = held("box_matches", 500, { _uses = 5 })
	local before_spent = #HOST_SPENT
	for _ = 1, 4 do off(lq); light(lq, box) end
	check(HF_DATA[lq:id()].is_on == true and box._uses == 1 and #HOST_SPENT == before_spent + 4 and last_answer() == "spent",
		"four lights: four uses spent on the host (5 -> 1)")
	off(lq)
	light(lq, box)
	check(released(box:id()) and last_answer() == "took" and counter("hf_lamp_tool").refused == 0, "the fifth: the host removes it")
	T.reset_for_test({ default = "log" })
end

print("== a request over the rate limit is answered 'no' (never silence: the player's item is not left waiting)")
do
	T.reset_for_test({ default = "log" })
	local lr = lamp()
	local boxes = {}
	for k = 1, 10 do boxes[k] = held("box_matches", 500, { _uses = 5 }) end
	SENT = {}
	for k = 1, 10 do from_client("hf_lamp", { o = lr:id(), on = k % 2 == 1, i = boxes[k]:id() }) end
	local answered = {}
	for _, m in ipairs(SENT) do
		if m.name == "mods.hf_item_r" then
			local t = coop_main.decode(m.payload)
			answered[t.i] = t.r
		end
	end
	local all, limited = true, 0
	for k = 1, 10 do
		local a = answered[boxes[k]:id()]
		if k % 2 == 1 and a == nil then all = false end
		if a == "no" then limited = limited + 1 end
	end
	check(all and limited >= 4, "every light with an item has an answer; the limited ones 'no' (" .. limited .. ")")
end

print("== a network text never becomes a format")
T.reset_for_test({ default = "log" })
INI["%s%n"] = {}
local odd = held("%s%n")
WRAPPERS[l4:id()].fuel = 0.1
refuel(l4, odd)
check((trust_line("hf_refuel_item") or ""):find("%s%n", 1, true) ~= nil, "a section with % signs is logged as it is")

done("HF TRUST HOST")
