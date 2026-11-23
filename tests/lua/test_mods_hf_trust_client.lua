-- Anomaly Coop test (TZ v2 6.4, round 2, 2026-11-18): Hideout Furniture's lamps on a client. A light names the tool and a refuel
-- the fuel item; nothing is spent before the host answers (mods.hf_item_r): "took" = the host removed it, "spent" = the host
-- spent a use or a step itself (R32 W8.1: the decider's write, its new state reaches this machine), "left" = spend it here as the
-- mod does (only a check that failed in "log": the host could not see the item), "no" = refused, nothing spent. No answer is no
-- answer: the request is held, nothing is spent here on a timer (R32 W7; the build 56 fallback is gone). A second request with an
-- item that waits for its answer sends nothing. Not shipped. Run: tools\test_lua.cmd mods_hf_trust_client
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== Hideout Furniture lamps: tools and fuel (client)")
make_actor(vec3(20, 0, 0))
local _, hostchar = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500 })
hostchar._kind = "stalker"
local function from_host(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 0) end

INI.hf_lamp = { require_matches = true, fuel_section = "charcoal" }
INI.hf_lamp_free = {}
INI.matches = {}
INI.box_matches = { multiuse = 5, use_condition = true }
INI.charcoal = { multiuse = 3, use_condition = true }
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
local GO = getmetatable(hostchar)
function GO:get_remaining_uses() return self._uses or 1 end
function GO:set_remaining_uses(n) self._uses = n end
SPENT = {}
utils_item = {
	is_degradable = function(o) local i = INI[o:section()]; return i ~= nil and i.use_condition == true and not i.multiuse end,
	degrade = function(o, n) SPENT[#SPENT + 1] = "degrade " .. o:id(); o._cond = (o._cond or 1) - n end,
	discharge = function(o)
		SPENT[#SPENT + 1] = "discharge " .. o:id()
		if IsItem("multiuse", nil, o) and o:get_remaining_uses() > 1 then o:set_remaining_uses(o:get_remaining_uses() - 1)
		else alife_release(o) end
	end,
}
HF_DATA = {}
hf_obj_manager = {
	get_data = function(id) return HF_DATA[id] end,
	update_data = function(id, t) HF_DATA[id] = HF_DATA[id] or {}; for k, v in pairs(t) do HF_DATA[id][k] = v end end,
	delete_data = function(id) HF_DATA[id] = nil end,
}
WRAPPERS = {}
bind_hf_base = { hf_binder_wrapper = { pickup = function() end }, get_wrapper = function(id) return WRAPPERS[id] end }
placeable_furniture = { create_object = function() end, func_place_item = function() end, start_placing_item = function() end,
	pickup_obj = function() end }
ui_furniture_light = { toggle_light = function() ORIG_TOGGLE = true end,
	UIFurnitureLight = { Pickup = function() end, Refuel = function() ORIG_REFUEL = true end } }

start_all()
SendScriptCallback("actor_on_first_update")

local function lamp(sec)
	local _, o = spawn(sec or "hf_lamp", vec3(21, 0, 0))
	WRAPPERS[o:id()] = { fuel = 0.2 }
	return o
end
local function own(sec, opts)
	local _, o = spawn(sec, vec3(20, 0, 0), 0)
	if opts then for k, v in pairs(opts) do o[k] = v end end
	return o
end
local function light(l) ui_furniture_light.toggle_light(l:id()) end
local function refuel(l) ui_furniture_light.UIFurnitureLight.Refuel({ section = l:section(), light_id = l:id(), Close = function() end }) end
local function spent(id)
	for _, s in ipairs(SPENT) do if s:find(" " .. id, 1, true) and s:sub(-#tostring(id)) == tostring(id) then return true end end
	return false
end

-------------------------------------------------------------------------------
print("== a light names the tool and spends nothing before the host's answer")
local l1 = lamp()
local m1 = own("matches")
SENT = {}
light(l1)
local req = sent("mods.hf_lamp")
check(req and req.on == true and req.i == m1:id() and req.o == l1:id(), "the request names the lamp and the matches")
check(#SPENT == 0 and SE[m1:id()] ~= nil and not ORIG_TOGGLE, "nothing spent, the mod's own toggle not run")
light(l1)
check(sent_count("mods.hf_lamp") == 1, "a second light while the answer is awaited sends nothing")
from_host("hf_item_r", { i = m1:id(), r = "took" })
check(#SPENT == 0, "'took': the host removed it, nothing spent here")
-- round 3 (R2-S1): the host's removal (an entity release) and its answer (a Lua event) take separate channels: until the
-- removal is here the spent matches are not named again
SENT = {}
HUD = nil
light(l1)
check(sent("mods.hf_lamp") == nil and HUD == nil, "'took', the removal not here yet: a second light sends nothing, says nothing")
local m1b = own("matches")
light(l1)
local req2 = sent("mods.hf_lamp")
check(req2 and req2.i == m1b:id(), "another box of matches he holds: that one is named")
from_host("hf_item_r", { i = m1b:id(), r = "took" })
release_id(m1:id()) -- the host's removals arrive
release_id(m1b:id())
SendScriptCallback("actor_on_update")
NOW = NOW + 20000
SendScriptCallback("actor_on_update")
check(#SPENT == 0, "and nothing later either")

print("== 'left': spent here as the mod does; 'no': nothing spent")
HF_DATA[l1:id()] = { is_on = false }
release_id(m1:id())
local bm = own("box_matches", { _uses = 5 })
SENT = {}
light(l1)
check(sent("mods.hf_lamp").i == bm:id(), "the box of matches named")
from_host("hf_item_r", { i = bm:id(), r = "left" })
check(spent(bm:id()) and bm._uses == 4, "'left': one use spent here (the mod's discharge)")
SENT = {}
light(l1)
from_host("hf_item_r", { i = bm:id(), r = "no" })
check(bm._uses == 4 and #SPENT == 1, "'no': nothing spent")
SENT = {}
light(l1)
check(sent_count("mods.hf_lamp") == 1, "after a refusal the tool may be asked again")

print("== 'spent': the host spent the use itself (R32 W8.1): nothing spent here")
from_host("hf_item_r", { i = bm:id(), r = "spent" })
check(bm._uses == 4 and #SPENT == 1, "'spent': nothing spent here (the host's write brings the new count)")
SENT = {}
light(l1)
check(sent_count("mods.hf_lamp") == 1 and sent("mods.hf_lamp").i == bm:id(), "answered: the box may be named again")

print("== no answer: the request is held, nothing is spent on a timer (R32 W7)")
NOW = NOW + 5000
SendScriptCallback("actor_on_update")
NOW = NOW + 60000
SendScriptCallback("actor_on_update")
check(bm._uses == 4 and #SPENT == 1, "a minute without an answer: nothing spent here (no build 56 fallback)")
SENT = {}
light(l1)
check(sent("mods.hf_lamp") == nil, "the box still waits for its answer: a second light sends nothing")
from_host("hf_item_r", { i = bm:id(), r = "spent" })
check(bm._uses == 4 and #SPENT == 1, "the late answer is applied: the host spent it, nothing spent here")
from_host("hf_item_r", { i = bm:id(), r = "left" }) -- (an answer nobody waits for)
check(bm._uses == 4, "an answer nobody waits for spends nothing")
SENT = {}
HUD = nil
release_id(bm:id())
light(l1)
check(sent("mods.hf_lamp") == nil and HUD ~= nil, "no tool: the mod's line, nothing asked")

print("== a lamp that needs no tool, and off: no item named")
local l2 = lamp("hf_lamp_free")
SENT = {}
light(l2)
local q = sent("mods.hf_lamp")
check(q and q.on == true and q.i == nil, "no tool needed: on, no item")
HF_DATA[l2:id()] = { is_on = true }
SENT = {}
light(l2)
q = sent("mods.hf_lamp")
check(q and q.on == false and q.i == nil, "off: no item")

-------------------------------------------------------------------------------
print("== refuel names the fuel item; nothing spent and no fuel before the answer")
local l3 = lamp()
local c1 = own("charcoal", { _uses = 3 })
SENT = {}
SPENT = {}
refuel(l3)
local rq = sent("mods.hf_refuel")
check(rq and rq.o == l3:id() and rq.i == c1:id(), "the request names the lamp and the charcoal")
check(#SPENT == 0 and SE[c1:id()] ~= nil and WRAPPERS[l3:id()].fuel == 0.2 and not ORIG_REFUEL, "nothing spent, no fuel yet")
refuel(l3)
check(sent_count("mods.hf_refuel") == 1, "a second refuel while the answer is awaited sends nothing")
from_host("hf_item_r", { i = c1:id(), r = "left" })
check(c1._uses == 2 and WRAPPERS[l3:id()].fuel == 1.0, "'left': one use spent here, the lamp is full")
WRAPPERS[l3:id()].fuel = 0.2
SENT = {}
refuel(l3)
from_host("hf_item_r", { i = c1:id(), r = "took" })
check(c1._uses == 2 and #SPENT == 1 and WRAPPERS[l3:id()].fuel == 1.0, "'took': nothing spent here, the lamp is full")
-- round 3 (R2-S1): until the host's removal of that charcoal arrives, it is not sent again (one charcoal, one refuel)
WRAPPERS[l3:id()].fuel = 0.2
SENT = {}
refuel(l3)
check(sent("mods.hf_refuel") == nil and WRAPPERS[l3:id()].fuel == 0.2,
	"'took', the removal not here yet: a second refuel sends nothing")
local c4 = own("charcoal", { _uses = 3 })
refuel(l3)
local rq4 = sent("mods.hf_refuel")
check(rq4 and rq4.i == c4:id(), "a second honest refuel with another charcoal: that one is named")
from_host("hf_item_r", { i = c4:id(), r = "left" })
check(c4._uses == 2 and WRAPPERS[l3:id()].fuel == 1.0, "and the lamp is full")
release_id(c1:id()) -- the host's removal arrives
release_id(c4:id())
SendScriptCallback("actor_on_update")
c1 = own("charcoal", { _uses = 2 })
WRAPPERS[l3:id()].fuel = 0.2
SENT = {}
NOW = NOW + 1000
refuel(l3)
from_host("hf_item_r", { i = c1:id(), r = "no" })
check(c1._uses == 2 and WRAPPERS[l3:id()].fuel == 0.2, "'no': nothing spent, no fuel")
SENT = {}
refuel(l3)
NOW = NOW + 60000
SendScriptCallback("actor_on_update")
check(c1._uses == 2 and WRAPPERS[l3:id()].fuel == 0.2, "no answer: nothing spent here, no fuel (the request is held)")
from_host("hf_item_r", { i = c1:id(), r = "spent" })
check(c1._uses == 2 and WRAPPERS[l3:id()].fuel == 1.0, "'spent': the host spent the use, the lamp is full, nothing spent here")
c1._uses = 1 -- the host's write arrives
SENT = {}
refuel(l3)
local rq5 = sent("mods.hf_refuel")
check(rq5 and rq5.i == c1:id(), "the charcoal may be named again")
from_host("hf_item_r", { i = c1:id(), r = "took" })
release_id(c1:id())
SendScriptCallback("actor_on_update")
c1 = own("charcoal", { _uses = 1 })
local others = 0
for _ in pairs(SE) do others = others + 1 end
check(others > 0, "(the world is still here)")

print("== an answer is the host's only")
SENT = {}
WRAPPERS[l3:id()].fuel = 0.2
refuel(l3)
coop_main.on_event("mods.hf_item_r", coop_main.encode({ i = c1:id(), r = "left" }), 2) -- another client
check(c1._uses == 1 and WRAPPERS[l3:id()].fuel == 0.2, "an answer from a client is ignored")

done("HF TRUST CLIENT")
