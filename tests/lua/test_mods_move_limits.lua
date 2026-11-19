-- Anomaly Coop test (F4 G6-1, finding m17:4, both modes): Hideout Furniture's stash capacity on the process that decides.
-- stash_capacities.script (HF, Aoldri) checks the weight only in the mover's window (ActorMenu_on_item_before_move: a view
-- callback), so two players filling one stash at once each saw the old weight and the decider applied both moves (50 kg of 60,
-- two 6 kg moves: 62 kg). The engine (coop_requests.cpp host_move for a client's request, host_transfer_item for the deciding
-- process's own script and window moves) now asks coop_mods_move_limits.admit(container, item, pending_count, pending_weight,
-- from) before it applies a move into a container; the moves it let in that the container's game inventory does not show yet
-- are held by the engine (xrCoop/coop_move_admission.h, tests/test_move_admission.cpp) and passed in as pending_*.
-- Here the engine's part is modelled by engine_move / next_frame below (the server object moves at once, the game inventory a
-- frame later); the rule itself is the real script. Core: runs once per answer set of coop_mode (hostplay, srv_world, srv_map,
-- none); the module never asks the mode, the set only decides whether this process has the stash's map at all.
-- Not shipped. Run: tools\test_lua.cmd mods_move_limits
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

-------------------------------------------------------------------------------
-- what stash_capacities.script needs of the game
-------------------------------------------------------------------------------
EDDListType = { iActorBag = 1, iActorSlot = 2, iPartnerTradeBag = 3, iDeadBodyBag = 4 }
strformat = string.format
ui_inventory = { UIInventory = { UpdateWeight = function() end, Reset = function() end } }
function ini_sys:section_for_each(f)
	local names = {}
	for s in pairs(INI) do names[#names + 1] = s end
	table.sort(names)
	for _, s in ipairs(names) do f(s) end
end
AddScriptCallback("ActorMenu_on_item_before_move")

INI.inventory_box = { capacity = 70 } -- mod_system_stash_capacities.ltx of HF
INI.inv_backpack = { capacity = 50 }
INI.hf_stash_small = { placeable_type = "stash", capacity = 60 }
INI.hf_stash_plain = { placeable_type = "stash" } -- no capacity line: 60 (stash_capacities.script:105)
INI.hf_chair = { placeable_type = "prop" }
INI.trader_box = {}
INI.part = {}

-- the mod's own file (the stand's copy when GAMMA_SCRIPTS names it, else the lines the rule mirrors)
local HF_SRC = [[
local stash_sections = {["inv_backpack"] = true, ["inventory_box"] = true}
local function itr_for_stashes(section)
	local placeable_type = ini_sys:r_string_ex(section, "placeable_type") or "prop"
	if placeable_type == "stash" then stash_sections[section] = true end
end
ini_sys:section_for_each(itr_for_stashes)
local weight_add = 0
local function getInvWeight(stash_id)
	local stash = get_object_by_id(stash_id)
	local weight = 0
	stash:iterate_inventory_box(function(owner, itm) weight = weight + itm:weight() end)
	return weight
end
local function actor_on_item_before_move(flags, npc_id, obj, mode, bag_from)
	if (bag_from ~= EDDListType.iActorBag) then return end
	if not obj then return end
	if not npc_id then return end
	if not get_object_by_id(npc_id) then return end
	local section = get_object_by_id(npc_id):section()
	if not stash_sections[section] then return end
	local capacity = ini_sys:r_float_ex(section,"capacity") or 60
	local weight = getInvWeight(npc_id) + weight_add
	if weight + obj:weight() > capacity then flags.ret_value = false end
end
function on_game_start() RegisterScriptCallback("ActorMenu_on_item_before_move", actor_on_item_before_move) end
]]
local src = HF_SRC
local real = os.getenv("GAMMA_SCRIPTS")
local real_used = false
if real then
	local fh = io.open(real .. "\\stash_capacities.script", "r")
	if fh then
		src = fh:read("*a")
		fh:close()
		real_used = true
	end
end
do
	local this = {}
	stash_capacities = this
	setmetatable(this, { __index = _G })
	local f = assert(loadstring(src, "@stash_capacities.script"))
	setfenv(f, this)
	f()
end

-------------------------------------------------------------------------------
-- objects: _w weight; _in what the GAME inventory of a box shows (the server object SE[id].parent_id moves at once)
-------------------------------------------------------------------------------
local actor = make_actor(vec3(0, 0, 0))
local GO = getmetatable(actor)
function GO:weight() return self._w or 0 end
function GO:iterate_inventory_box(f)
	local ids = {}
	for id, o in pairs(OBJ) do if o._in == self._id then ids[#ids + 1] = id end end
	table.sort(ids)
	for _, id in ipairs(ids) do f(self, OBJ[id]) end
end

local function box(sec, online)
	local se, o = spawn(sec, vec3(2, 0, 0), nil, { offline = online == false })
	if o then o._kind = "box" end
	return se.id, o
end
local function item(w, where)
	local _, o = spawn("part", vec3(1, 0, 0), where or 0)
	o._w = w
	if where and OBJ[where] and OBJ[where]._kind == "box" then o._in = where end
	return o
end

-- The engine's part (coop_requests.cpp admitted_move over coop_move_admission.h), reduced: settle the held moves of the box
-- that its game inventory shows now, ask the rules with the rest, hold what they let in, move the server object at once.
local held = {}
local function pending_of(box_id)
	local n, w = 0, 0
	for id, h in pairs(held) do
		if h.box == box_id then
			if OBJ[id] and OBJ[id]._in == box_id then held[id] = nil else n, w = n + 1, w + h.w end
		end
	end
	return n, w
end
local function engine_move(it, box_id, from)
	local n, w = pending_of(box_id)
	local ok, why = coop_mods_move_limits.admit(box_id, it:id(), n, w, from)
	if ok == false then return false, why end
	if ok == true then held[it:id()] = { box = box_id, w = it:weight() } end
	SE[it:id()].parent_id = box_id
	it._in = nil -- in flight: the game event queue runs next frame
	return true, ok
end
local function next_frame()
	for id, se in pairs(SE) do
		local o = OBJ[id]
		local p = se.parent_id ~= 65535 and OBJ[se.parent_id] or nil
		if o and o._w and p and p._kind == "box" then o._in = se.parent_id end
	end
end
local function shown(box_id)
	local w = 0
	OBJ[box_id]:iterate_inventory_box(function(_, i) w = w + i:weight() end)
	return w
end
-- HF's window check (the preview each player's machine runs on its own copy of the box)
local function window_allows(box_id, it)
	local flags = { ret_value = true }
	SendScriptCallback("ActorMenu_on_item_before_move", flags, box_id, it, "loot", EDDListType.iActorBag)
	return flags.ret_value
end

-------------------------------------------------------------------------------
start_all()
local callbacks_before = axr_main.count("ActorMenu_on_item_before_move")
local wrapped_before = #coop_mods_core.wrapped
load_script("coop_mods_move_limits")
local registered = 0
do
	local reg = RegisterScriptCallback
	RegisterScriptCallback = function(n, f) registered = registered + 1 return reg(n, f) end
	coop_mods_move_limits.on_game_start()
	RegisterScriptCallback = reg
end
stash_capacities.on_game_start()
local M = coop_mods_move_limits

print("== move limits: Hideout Furniture's stash capacity on the decider (" .. (real_used and "the stand's stash_capacities.script" or "inline copy") .. ")")
check(type(M.admit) == "function" and type(M.add_rule) == "function", "the module offers admit and add_rule")
check(M.has_rule("hf_capacity"), "the HF capacity rule is installed (stash_capacities exists)")
check(#coop_mods_core.wrapped == wrapped_before, "nothing of the mod is wrapped: its window check stays the preview")
check(registered == 0, "the module registers no callback: nothing of it runs per frame, in a window or in single player")
check(axr_main.count("ActorMenu_on_item_before_move") == callbacks_before + 1, "the only new window callback is the mod's own")

local map_seat = false
local map_player = 501 -- a second proxy on the map server, where actor 0 is a ghost
local peer_of_avatar = coop.peer_of_avatar
coop.is_map_server = function() return map_seat end
coop.peer_of_avatar = function(id)
	if map_seat and id == map_player then return 2 end
	return peer_of_avatar(id)
end

for _, set in ipairs(modes.names()) do
	modes.install(coop_mode, set)
	held = {}
	map_seat = set == "srv_map"
	local here = coop_mode.leads_here() -- this process has the map of the stash (the co-op host, a map server)
	print("-- set " .. set)
	if set == "none" then
		-- single player: the engine never asks the module (no session); the mod's window check is the stock one
		local b = box("hf_stash_small")
		for _ = 1, 5 do item(10, b) end
		check(window_allows(b, item(10, 0)) == true, set .. ": the mod's window lets 10 kg in (50 + 10 = 60)")
		check(window_allows(b, item(10.5, 0)) == false, set .. ": and refuses 10.5 kg, as without co-op")
	elseif here then
		local player = map_seat and map_player or 0
		-- 1. finding m17:4: 50 kg of 60 in the stash, two players put 6 kg each in at once
		local b = box("hf_stash_small")
		for _ = 1, 5 do item(10, b) end
		local a1, a2 = item(6, player), item(6, PROXY)
		check(shown(b) == 50, set .. ": the stash shows 50 kg")
		check(window_allows(b, a1) and window_allows(b, a2), set .. ": both windows let 6 kg in (each sees 50 kg: the preview)")
		local ok1, judged1 = engine_move(a1, b, player)
		local ok2, why2 = engine_move(a2, b, PROXY)
		check(ok1 == true and judged1 == true, set .. ": the first move is let in by the HF rule (held)")
		check(ok2 == false, set .. ": the second, in the same frame, is refused (50 + 6 held + 6 > 60)")
		check(type(why2) == "string" and why2:find("hf_stash_small", 1, true) ~= nil,
			set .. ": the refusal names the stash (" .. tostring(why2) .. ")")
		check(SE[a2:id()].parent_id == PROXY, set .. ": the refused item stays with its player")
		next_frame()
		check(shown(b) == 56, set .. ": the stash shows 56 kg, never 62 (" .. shown(b) .. ")")
		-- 2. the boundary: the capacity itself is allowed (stash_capacities.script:108 refuses only above it)
		local a3, a4 = item(4, player), item(0.01, player)
		check(engine_move(a3, b, player) == true, set .. ": 56 + 4 = 60 kg is let in")
		check(engine_move(a4, b, player) == false, set .. ": 0.01 kg more is refused while the 4 kg move is held")
		next_frame()
		check(engine_move(a4, b, player) == false, set .. ": and after it landed (60 kg shown)")
		check(shown(b) == 60, set .. ": 60 kg in the end (" .. shown(b) .. ")")

		-- 3. capacity lines: inventory_box 70 (HF's ltx), a stash without the line 60, a placed backpack 50
		local ib = box("inventory_box")
		for _ = 1, 6 do item(11, ib) end -- 66
		check(M.admit(ib, item(4, player):id(), 0, 0, player) == true, set .. ": inventory_box: 66 + 4 = 70 is let in")
		check(M.admit(ib, item(4.5, player):id(), 0, 0, player) == false, set .. ": inventory_box: 66 + 4.5 > 70 is refused")
		local pb = box("hf_stash_plain")
		item(59, pb)
		check(M.admit(pb, item(1, player):id(), 0, 0, player) == true, set .. ": a stash without a capacity line takes up to 60 kg")
		check(M.admit(pb, item(1, player):id(), 1, 0.5, player) == false, set .. ": its held moves count (59 + 0.5 held + 1 > 60)")
		local bp = box("inv_backpack")
		item(49, bp)
		check(M.admit(bp, item(2, player):id(), 0, 0, player) == false, set .. ": a placed backpack takes 50 kg (49 + 2 refused)")

		-- 4. not a stash: no rule speaks, the move goes on as in the stock game
		check(M.admit(box("hf_chair"), item(500, player):id(), 0, 0, player) == nil, set .. ": furniture that is not a stash: no rule (nil)")
		check(M.admit(box("trader_box"), item(500, player):id(), 0, 0, player) == nil, set .. ": a plain container: no rule (nil)")

		-- 5. the engine's numbers are checked: not numbers, negative or not finite -> no error, no harm
		check(M.admit("x", a1:id(), 0, 0, player) == nil, set .. ": a container id that is not a number: no rule")
		check(M.admit(b, nil, 0, 0, player) == nil, set .. ": no item: no rule")
		check(M.admit(b, 70000, 0, 0, player) == nil, set .. ": an id out of range: no rule")
		local small = box("hf_stash_small")
		local s1 = item(1, player)
		check(M.admit(small, s1:id(), -5, -100, player) == true, set .. ": negative pending counts as 0")
		check(M.admit(small, s1:id(), 1, 0 / 0, player) == true, set .. ": a pending weight that is not a number counts as 0")
		check(M.admit(small, s1:id(), 1, math.huge, player) == true, set .. ": an infinite pending weight counts as 0 (the engine bounds it)")
		check(M.admit(small, s1:id(), nil, nil, player) == true, set .. ": no pending at all")

		-- G6-1b: Soulslike transfers death items to the treasure box, then releases the hidden box.
		local treasure = box("inventory_box")
		item(70, treasure)
		local hidden, hidden_box = box("hidden_box")
		local first, second = item(3, hidden), item(4, hidden)
		check(M.admit(treasure, first:id(), 0, 0, hidden) == nil,
			set .. ": a transfer from a container into a full stash has no HF verdict")
		check(M.admit(treasure, item(3, player):id(), 0, 0, player) == false,
			set .. ": an equally heavy item from the player is refused by the same full stash")
		hidden_box:iterate_inventory_box(function(_, it) engine_move(it, treasure, hidden) end)
		-- The stub releases only one object, so explicitly release any items left in the hidden box too.
		hidden_box:iterate_inventory_box(function(_, it) alife_release(it) end)
		alife_release(hidden_box)
		next_frame()
		check(OBJ[first:id()] == first and OBJ[second:id()] == second and shown(treasure) == 77,
			set .. ": both death items survive the hidden box release and land in the full treasure box")
	else
		-- the world server has no map: no stash is online in it, nothing is judged here (the map server of that level decides)
		local b = box("hf_stash_small", false)
		local it = item(6, 0)
		check(OBJ[b] == nil, set .. ": the stash is not online in this process")
		check(M.admit(b, it:id(), 0, 0, 0) == nil, set .. ": a stash this process does not have is not judged (nil)")
	end
end

-- 6. rules: a refusal of any rule wins, an error is logged and counts as no rule, remove_rule
modes.install(coop_mode, "hostplay")
map_seat = false
local b6 = box("hf_stash_small")
local i6 = item(1, 0)
check(M.add_rule("test_raise", function() error("boom") end) == true, "a rule is added")
check(M.admit(b6, i6:id(), 0, 0, 0) == true, "a rule that raises does not stop the others")
check(log_has("test_raise") ~= nil, "its error is logged with its name")
check(M.add_rule("test_no", function(c, i, n, w, from) if from == PROXY then return false, "test says no" end end) == true, "a second rule")
local ok6, why6 = M.admit(b6, item(1, PROXY):id(), 0, 0, PROXY)
check(ok6 == false and why6 == "test says no", "a refusal of any rule wins over a let-in (" .. tostring(why6) .. ")")
check(M.admit(b6, i6:id(), 0, 0, 0) == true, "the other moves still go by the HF rule")
check(M.add_rule("test_bad", "not a function") == false, "a rule that is not a function is refused")
check(M.add_rule(nil, function() end) == false, "a rule without a name is refused")
M.remove_rule("test_raise")
M.remove_rule("test_no")
check(not M.has_rule("test_raise") and not M.has_rule("test_no"), "rules are removed by name")
check(M.has_rule("hf_capacity"), "the HF rule stays")

-- 7. without Hideout Furniture: no rule at all, every move goes on as in the stock game
M.remove_rule("hf_capacity")
stash_capacities = nil
M.on_game_start()
check(not M.has_rule("hf_capacity"), "no stash_capacities.script: the HF rule is not installed")
check(M.admit(b6, i6:id(), 0, 0, 0) == nil, "no rule: nil (the engine moves as in the stock game)")
done("mods_move_limits")
