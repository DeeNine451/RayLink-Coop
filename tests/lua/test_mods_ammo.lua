-- Complaint 5 (build 54, a client at the workbench): "22/20" bullets in red, Создать does nothing. G.A.M.M.A.'s
-- game_setup.actor_on_item_take ends with item_weapon.ammo_aggregation(obj): in single player and on the host every pack
-- taken is merged into full boxes. game_setup is routed host-only, so a client's bag filled with small packs, and the
-- workbench counts full boxes only. coop_mods_ammo merges a live client's own packs the same way, through confirmed paths
-- only: a pack is released first, its rounds go into the other packs once the host has taken it.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== ammo packs of a client are merged like the host's")
make_actor()

-------------------------------------------------------------------------------
-- ammo packs and the host's answers
-------------------------------------------------------------------------------
local GO = getmetatable(db.actor)
SETS = 0
function GO:ammo_get_count() return self._count end
function GO:ammo_box_size() return self._box end
function GO:ammo_set_count(n)
	if self._fail_set then error("the setter is not ready", 2) end
	assert(n > 0 and n <= self._box, "a count out of the box: " .. tostring(n))
	if n ~= self._count then SETS = SETS + 1 end
	self._count = n
end
INI.ammo_9x18_fmj = { box_size = 20 }
INI.ammo_9x18_fmj_bad = { box_size = 20 }
INI.ammo_545x39_fmj = { box_size = 30 }
_NO_DAMAGED_AMMO = true
function IsItem(kind, sec) return kind == "ammo" and type(sec) == "string" and sec:find("^ammo_") ~= nil end

-- on a client a release only asks the host (the pack stays here until the host's destroy)
DESTROY = {}
function alife_release(x)
	local id = type(x.id) == "function" and x:id() or x.id
	DESTROY[#DESTROY + 1] = id
	return true
end
function alife_release_id(id) return alife_release(alife_object(id)) end -- as _g: through the global
local function host_answers()
	for _, id in ipairs(DESTROY) do release_id(id) end
	DESTROY = {}
end
local function asked(id)
	for _, d in ipairs(DESTROY) do if d == id then return true end end
	return false
end
-- leased creates wait for the host's answer
WAITING = {}
coop.lease_waiting = function(id) return WAITING[id] == true end
local function pack(sec, n, opts)
	local _, o = spawn(sec, vec3(0, 0, 0), 0, opts)
	o._kind, o._count, o._box = "ammo", n, INI[sec].box_size
	return o
end
function alife_create_item(sec, obj, t)
	local o = pack(sec, t and t.ammo or INI[sec].box_size)
	CREATED[#CREATED + 1] = { sec = sec, id = o:id(), parent = obj:id(), ammo = t and t.ammo }
	WAITING[o:id()] = true
	return SE[o:id()]
end
local function bag(sec)
	local list = {}
	for id, se in pairs(SE) do
		if se.parent_id == 0 and se._sec == sec and OBJ[id] then list[#list + 1] = OBJ[id]._count end
	end
	table.sort(list, function(a, b) return a > b end)
	return list, table.concat(list, ",")
end
local function rounds(sec)
	local n = 0
	for _, c in ipairs(bag(sec)) do n = n + c end
	return n
end
local function clear()
	for id, se in pairs(SE) do if se.parent_id == 0 then release_id(id) end end
	DESTROY, WAITING, CREATED, SETS = {}, {}, {}, 0
end
local function take(o) SendScriptCallback("actor_on_item_take", o) end
local function tick(ms)
	local stop = NOW + ms
	repeat
		SendScriptCallback("actor_on_update")
		NOW = NOW + 50
	until NOW > stop
end

-- game_setup's world-loot tables (coop_economy_world's client half writes a late roll from them)
game_setup = { world_itm_on = {}, world_itm_num = {}, world_itm_off = {}, world_itm_info = {}, limited_uses = {},
	try_spawn_world_item = function() end }

start_all()
AddScriptCallback("GUI_on_show")
AddScriptCallback("GUI_on_hide")
coop_economy_world.on_game_start()
local M = load_script("coop_mods_ammo")
M.on_game_start()
tick(500)

-------------------------------------------------------------------------------
-- a client: three partial packs of one kind become a full box and the rest
-------------------------------------------------------------------------------
local FMJ = "ammo_9x18_fmj"
local a, b, c, full = pack(FMJ, 8), pack(FMJ, 7), pack(FMJ, 7), pack(FMJ, 20)
for _, o in ipairs({ a, b, c, full }) do take(o) end
tick(1000)
check(#DESTROY == 0 and SETS == 0, "client: a pack just taken waits (the host's world-loot count comes first)")
tick(1500)
check(#DESTROY == 1 and (asked(b:id()) or asked(c:id())), "client: the smallest extra pack is asked to go: " .. #DESTROY)
check(SETS == 0, "client: nothing is filled before the host has taken the released pack")
tick(10000)
check(SETS == 0 and rounds(FMJ) == 42, "client: the host answers late: no round counted twice meanwhile")
host_answers()
tick(500)
local _, txt = bag(FMJ)
check(txt == "20,20,2", "client: 8+7+7 (+ a full box) become 20,20,2: " .. txt)
check(rounds(FMJ) == 42, "client: rounds before == rounds after (42): " .. rounds(FMJ))
check(#DESTROY == 0, "client: no second release")
clear()

-- two partials that fit two packs are only rebalanced (18+17 -> 20+15), nothing released
local d, e = pack(FMJ, 18), pack(FMJ, 17)
take(d) take(e)
tick(2500)
local _, txt2 = bag(FMJ)
check(#DESTROY == 0 and txt2 == "20,15", "client: 18+17 become 20+15 without a release: " .. txt2)
check(rounds(FMJ) == 35, "client: rounds kept (35)")
clear()

-- the host never takes the released pack: it keeps its rounds, nothing is filled
local f, g = pack(FMJ, 5), pack(FMJ, 4)
take(f) take(g)
tick(2500)
check(asked(g:id()), "client: the 4-round pack is asked to go")
tick(70000)
check(SETS == 0 and rounds(FMJ) == 9, "client: a release the host never answers loses and adds nothing")
clear()

-------------------------------------------------------------------------------
-- damaged packs are replaced as the stock does (_bad -> the regular section), through the same confirmed path
-------------------------------------------------------------------------------
local bad, good = pack("ammo_9x18_fmj_bad", 10), pack(FMJ, 15)
take(bad) take(good)
tick(2500)
check(asked(bad:id()) and #DESTROY == 1, "client: a _bad pack is asked to go")
check(SETS == 0 and #CREATED == 0, "client: nothing is created before the host took the _bad pack")
host_answers()
tick(500)
local _, txt3 = bag(FMJ)
check(txt3 == "20,5" and rounds(FMJ) == 25, "client: 10 _bad + 15 -> 20,5 regular: " .. txt3)
check(#CREATED == 1 and CREATED[1].sec == FMJ and CREATED[1].ammo == 5 and CREATED[1].parent == 0,
	"client: the rest goes into a new pack in the own bag")
clear()

-------------------------------------------------------------------------------
-- a pack waiting for the host (its create not answered yet) is left alone, merged after the answer
-------------------------------------------------------------------------------
local w, p, q = pack(FMJ, 12), pack(FMJ, 6), pack(FMJ, 5)
WAITING[w:id()] = true
take(w) take(p) take(q)
tick(2500)
check(not asked(w:id()) and w._count == 12, "client: a pack waiting for the host is not touched")
check(asked(q:id()) and #DESTROY == 1, "client: the other two are merged meanwhile (5 asked to go)")
host_answers()
tick(500)
check(w._count == 12 and p._count == 11, "client: 6+5 -> 11, the waiting pack still 12")
WAITING[w:id()] = nil
tick(500)
local _, txt4 = bag(FMJ)
check(txt4 == "20,3" and rounds(FMJ) == 23, "client: after the host's answer 12+11 -> 20,3: " .. txt4)
clear()

-------------------------------------------------------------------------------
-- a pack whose world-loot count has not been written yet (coop_economy_world taken_rolls) waits for it
-------------------------------------------------------------------------------
local r, s = pack(FMJ, 15), pack(FMJ, 6)
r._fail_set = true -- the roll cannot be written yet: it stays in taken_rolls
take(r) take(s)
coop_main.on_event("economy.loot_roll", coop_main.encode({ id = r:id(), s = FMJ, n = 9 }), 0)
check(coop_economy_world.roll_waiting(r:id()) == true, "economy: a late roll waits in taken_rolls")
tick(3000)
check(#DESTROY == 0 and r._count == 15 and s._count == 6, "client: a pack waiting for its world-loot count is not merged")
r._fail_set = nil
tick(1500)
check(r._count == 9, "economy: the roll is written (9)")
check(coop_economy_world.roll_waiting(r:id()) == false, "economy: no roll waits any more")
host_answers()
tick(500)
local _, txt5 = bag(FMJ)
check(txt5 == "15" and rounds(FMJ) == 15, "client: after the roll 9+6 -> 15: " .. txt5)
clear()

-------------------------------------------------------------------------------
-- a pack another action asked to release (a craft ingredient) is not merged
-------------------------------------------------------------------------------
local i1, i2, i3 = pack(FMJ, 7), pack(FMJ, 6), pack(FMJ, 5)
take(i1) take(i2) take(i3)
alife_release_id(i1:id()) -- the workbench used it up; the host has not answered yet
tick(2500)
check(#DESTROY == 2 and SETS == 0,"client: only the free packs are merged (6+5): " .. #DESTROY)
check(asked(i3:id()) and not asked(i2:id()), "client: the 5-round pack is asked to go, not the craft's")
host_answers()
tick(500)
local _, txt6 = bag(FMJ)
check(txt6 == "11", "client: the craft's pack is gone, 6+5 -> 11: " .. txt6)
clear()

-------------------------------------------------------------------------------
-- the workbench: a catch-up once per open (packs from before the fix or from a save, never taken)
-------------------------------------------------------------------------------
local k1, k2, k3 = pack(FMJ, 4), pack(FMJ, 4), pack(FMJ, 4)
tick(3000)
check(#DESTROY == 0, "client: packs not taken are left alone until the workbench opens")
local runs = M.stats.catchups
SendScriptCallback("GUI_on_show", "UIWorkshop", "ui_workshop")
check(M.stats.catchups == runs + 1 and #DESTROY == 2, "workbench: the catch-up runs at once (two of three packs go)")
SendScriptCallback("GUI_on_show", "UIWorkshop", "ui_workshop")
check(M.stats.catchups == runs + 1 and #DESTROY == 2, "workbench: once per open")
host_answers()
tick(500)
local _, txt7 = bag(FMJ)
check(txt7 == "12" and rounds(FMJ) == 12, "workbench: 4+4+4 -> 12: " .. txt7)
SendScriptCallback("GUI_on_hide", "UIWorkshop", "ui_workshop")
SendScriptCallback("GUI_on_show", "UIWorkshop", "ui_workshop")
check(M.stats.catchups == runs + 2, "workbench: the next open runs it again")
SendScriptCallback("GUI_on_hide", "UIWorkshop", "ui_workshop")
SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
check(M.stats.catchups == runs + 2, "workbench: another window does not run it")
clear()

-------------------------------------------------------------------------------
-- the host, single player, a map server, the world server: nothing (game_setup merges there, or there is no bag)
-------------------------------------------------------------------------------
local function nothing_as(mode, what, setup, undo)
	MODE = mode
	if setup then setup() end
	local x, y, z = pack(FMJ, 8), pack(FMJ, 7), pack(FMJ, 7)
	take(x) take(y) take(z)
	tick(3000)
	SendScriptCallback("GUI_on_show", "UIWorkshop", "ui_workshop")
	SendScriptCallback("GUI_on_hide", "UIWorkshop", "ui_workshop")
	tick(500)
	check(#DESTROY == 0 and SETS == 0 and #CREATED == 0 and rounds(FMJ) == 22, what .. ": nothing is merged")
	if undo then undo() end
	clear()
	MODE = "client"
end
nothing_as("host", "host")
nothing_as("sp", "single player")
nothing_as("client", "map server", function() coop.is_map_server = function() return true end end,
	function() coop.is_map_server = nil end)
nothing_as("host", "world server (dedicated)", function() coop.is_dedicated = function() return true end end,
	function() coop.is_dedicated = nil end)
nothing_as("client", "client not live yet", function() coop.is_live = function() return false end end,
	function() coop.is_live = function() return true end end)

-- and the client works again afterwards
local m1, m2 = pack(FMJ, 3), pack(FMJ, 2)
take(m1) take(m2)
tick(2500)
host_answers()
tick(500)
local _, txt8 = bag(FMJ)
check(txt8 == "5", "client again: 3+2 -> 5: " .. txt8)
clear()

done("MODS AMMO")
