-- Dev 57 G15-1, findings m09:8 (G.A.M.M.A. Quests Rebalance xr_effects.script:2686, actor_punch) and s39:3 (stock
-- state_mgr_animation_list.script:336, state_mgr_animation.script:518): the robber's punch lands on the player he robs.
-- Both ways the stock calls xr_effects.actor_punch are covered: a condlist effect (actor, npc, p) and the special action of the
-- "punch" animation (npc), whose list keeps the function itself from the moment it loaded. coop_quests_punch keeps the victim
-- chosen when the NPC is put in the "punch" state, checks the reach to him (2 m) and runs the consequences on HIS machine
-- (mods.qpunch, side "player"), once per order.
-- Each S4 answer set (tests\lua\support\modes.lua):
--   hostplay   the co-op host leads the NPC: a client's punch goes to the client, the host's own to the host
--   srv_map    the map server leads the NPC; its actor is a ghost: the victim is the player near the robber
--   srv_world  no map: a punch is nothing here
--   none       single player: the stock function on db.actor
-- plus the player's own machine (the order) in every run.
-- The real actor_punch of the merged GAMMA file, the real stock animation list and process_special_action are used when the
-- review corpus and temp\stock_scripts are there, else shapes of them.
-- Run: tools\test_lua.cmd quests_punch
local modes = dofile("tests/lua/support/modes.lua")

local PROXY, OTHER = 500, 501 -- the characters of peer 1 and peer 2 in host numbering

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return (s:gsub("\r\n", "\n"))
end

local function cut(text, header)
	local a = text and text:find(header, 1, true)
	if not a then return nil end
	local b = text:find("\nend", a, true)
	if not b then return nil end
	return text:sub(a, b + 3)
end

local PUNCH_SHAPE = [[
function actor_punch(npc)
	if db.actor:position():distance_to_sqr(npc:position()) > 4 then return end
	set_inactivate_input_time(30)
	level.add_cam_effector("camera_effects\\fusker.anm", 999, false, "")
	local slot = db.actor:active_slot()
	if slot ~= 2 and slot ~= 3 then return end
	local item = db.actor:active_item()
	if item and string.find(item:section(), "wpn_") then db.actor:drop_item(item) end
end
]]
local LIST_SHAPE = [[
animations = {
	punch = { prop = { maxidle = 5, sumidle = 2, rnd = 100 },
		into = { [0] = { "norm_facer_0_0", {f=xr_effects.actor_punch}, "norm_facer_0_1", {f=xr_effects.clearAbuse} },
			[2] = { "norm_facer_2_0", {f=xr_effects.actor_punch}, "norm_facer_2_1", {f=xr_effects.clearAbuse} } },
		out = nil, idle = nil, rnd = nil },
}
]]
local SPECIAL_SHAPE = [[
function animation:process_special_action(action_table)
	if action_table.f ~= nil then
		action_table.f(self.npc)
	end
end
]]
local PUNCH_SRC = cut(read("temp/review/corpus/merged/xr_effects.script"), "function actor_punch(") or PUNCH_SHAPE
local LIST_SRC = read("temp/stock_scripts/scripts/state_mgr_animation_list.script") or LIST_SHAPE
local SPECIAL_SRC = cut(read("temp/stock_scripts/scripts/state_mgr_animation.script"), "function animation:process_special_action(")
	or SPECIAL_SHAPE
print(string.format("== sources: actor_punch %s, animation list %s, process_special_action %s",
	PUNCH_SRC == PUNCH_SHAPE and "shape" or "merged GAMMA", LIST_SRC == LIST_SHAPE and "shape" or "stock",
	SPECIAL_SRC == SPECIAL_SHAPE and "shape" or "stock"))

-------------------------------------------------------------------------------
-- One process. kind: an S4 set name, or "client" (a player's machine)
-------------------------------------------------------------------------------
local STOCK -- the function the stock animation list keeps
local SPECIAL -- state_mgr_animation's animation class with the stock process_special_action

local function world(kind, prewrap)
	MODE = kind == "none" and "sp" or (kind == "client" and "client" or "host")
	local passes, fails = PASSES or 0, FAILS or 0 -- the stubs start the counters again: a run has several worlds
	dofile("tests/lua/support/stubs_mods.lua")
	PASSES, FAILS = passes, fails
	if kind == "srv_map" then coop.is_map_server = function() return true end end
	if kind == "srv_world" then coop.is_dedicated = function() return true end end
	coop.players = function()
		if MODE == "sp" then return {} end
		return {
			{ id = 0, nick = "hoster", is_self = MODE == "host", avatar_id = MODE == "host" and 0 or PROXY },
			{ id = 1, nick = "joiner", is_self = MODE == "client", avatar_id = MODE == "client" and 0 or PROXY },
			{ id = 2, nick = "second", is_self = false, avatar_id = OTHER },
		}
	end
	coop.avatar_of = function(peer)
		if peer == SELF then return 0 end
		if peer == 1 then return PROXY elseif peer == 2 then return OTHER end
	end
	coop.peer_of_avatar = function(id)
		if id == 0 then return SELF end
		if id == PROXY then return MODE == "host" and 1 or 0 elseif id == OTHER then return 2 end
	end

	local actor = make_actor(vec3(0, 0, 0))
	local GO = getmetatable(actor)
	GO.active_slot = function(self) return self._slot or 0 end
	GO.active_item = function(self) return self._item end
	DROPPED = {}
	GO.drop_item = function(self, item) DROPPED[#DROPPED + 1] = { by = self._id, item = item:id() } end
	INPUT = {}
	function set_inactivate_input_time(s) INPUT[#INPUT + 1] = s end
	CAMS = 0

	-- xr_effects with the real actor_punch
	local xe = setmetatable({ clearAbuse = function() end }, { __index = _G })
	xr_effects = xe
	local f = assert(loadstring(PUNCH_SRC, "@xr_effects.script"))
	setfenv(f, xe)
	f()
	STOCK = xe.actor_punch
	-- the stock animation list loads before any wrapper: its punch entries keep that function
	xr_help_wounded, xr_corpse_detection, xr_gather_items, sr_camp, axr_turn_on_campfire = {}, {}, {}, {}, {}
	local none = { add_animation_list = function() return {} end }
	state_mgr_animation_list_animpoint, state_mgr_scenario, state_mgr_pri_a15 = none, none, none
	function copy_table(dst, src) for k, v in pairs(src or {}) do dst[k] = v end end
	local list = setmetatable({}, { __index = _G })
	state_mgr_animation_list = list
	local lf = assert(loadstring(LIST_SRC, "@state_mgr_animation_list.script"))
	setfenv(lf, list)
	lf()
	-- state_mgr_animation: the animation class as far as the special action goes
	SPECIAL = setmetatable({}, { __index = _G })
	SPECIAL.animation = {}
	local sf = assert(loadstring(SPECIAL_SRC, "@state_mgr_animation.script"))
	setfenv(sf, SPECIAL)
	sf()
	STATES = {}
	state_mgr = { set_state = function(npc, name, cb, timeout, target, extra) STATES[#STATES + 1] = { npc = npc:id(), name = name } end }
	if prewrap then
		-- another script wraps xr_effects.actor_punch before coop_quests_punch installs (G15-5 may): the list still holds STOCK
		local inner = xe.actor_punch
		xe.actor_punch = function(...)
			PREWRAPPED = (PREWRAPPED or 0) + 1
			return inner(...)
		end
	end

	load_script("coop_main")
	load_script("coop_mode")
	if kind == "client" then
		modes.install(coop_mode, "hostplay", { leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end })
	else
		modes.install(coop_mode, kind)
	end
	load_script("coop_mods_core")
	local ok, err = pcall(load_script, "coop_quests_punch")
	if ok and rawget(_G, "coop_quests_punch") then
		coop_quests_punch.on_game_start()
	else
		print("  (coop_quests_punch did not load: " .. tostring(err) .. ")")
	end
	SendScriptCallback("actor_on_first_update")
	SENT = {}
	return actor
end

local function npc_at(id, x)
	local _, o = spawn("stalker", vec3(x, 0, 0), nil, { id = id, kind = "stalker" })
	return o
end

-- The special action of the punch animation, as state_mgr_animation runs it with the entry of the stock list.
local function punch_anim(npc)
	local entry = state_mgr_animation_list.animations.punch.into[0][2]
	SPECIAL.animation.process_special_action({ npc = npc }, entry)
end

local function orders(target)
	local n = 0
	for _, s in ipairs(SENT) do
		if s.name == "mods.qpunch" and (target == nil or s.target == target) then n = n + 1 end
	end
	return n
end

local function host_untouched(label)
	check(CAMS == 0 and #INPUT == 0 and #DROPPED == 0, label .. ": this process's own actor gets no punch (cam " .. CAMS .. ", input " ..
		#INPUT .. ", dropped " .. #DROPPED .. ")")
end

local function api() return rawget(_G, "coop_quests_punch") end

-------------------------------------------------------------------------------
local function run_hostplay()
	print("== hostplay: a robber punches a client")
	world("hostplay")
	local _, proxy = spawn("coop_player_avatar", vec3(11, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local npc = npc_at(700, 12)
	db.actor._slot, db.actor._item = 2, select(2, spawn("wpn_ak74", vec3(0, 0, 0), 0))

	-- s39:3: the punch is assigned with its victim (xr_remark / xr_abuse: the state's look_object)
	state_mgr.set_state(npc, "punch", nil, 0, { look_object = proxy })
	check(#STATES == 1, "co-op: the stock set_state still runs")
	check(api() and api().victim_of(700) == PROXY, "co-op: the victim is kept when the punch is assigned")
	local entry = state_mgr_animation_list.animations.punch.into[0][2]
	check(entry.f ~= STOCK, "co-op: the animation list's punch entry no longer holds the stock function")
	punch_anim(npc)
	check(orders(1) == 1 and orders() == 1, "co-op, animation: one order, to the machine of the client who is robbed")
	host_untouched("co-op, animation")
	local o = sent("mods.qpunch")
	check(o and o.n == 700 and o.k == "anim" and type(o.o) == "string", "co-op, animation: the order names the NPC and the way")

	-- m09:8: the condlist's call (actor, npc, p)
	xr_effects.actor_punch(db.actor, npc, nil)
	check(orders(1) == 2 and orders() == 2, "co-op, condlist: one more order, to the same client")
	host_untouched("co-op, condlist")
	local q = sent("mods.qpunch")
	check(q and q.k == "condlist", "co-op, condlist: the order says it came from a condlist")

	-- a far victim: nothing (the stock's 2 m)
	proxy._pos = vec3(20, 0, 0)
	punch_anim(npc)
	xr_effects.actor_punch(db.actor, npc, nil)
	check(orders() == 2, "co-op: a victim more than 2 m away gets no punch, by either way")
	host_untouched("co-op, far")
	proxy._pos = vec3(11, 0, 0)

	-- G15-5's entry: punch(victim, npc, kind)
	check(api() and api().punch(PROXY, 700, "condlist") == true and orders(1) == 3, "co-op: punch(victim, npc, kind) lands on him")
	check(api() and api().punch(OTHER, 700, "condlist") == false and orders() == 3, "co-op: a player who is not here gets nothing")
	check(api() and api().punch(700, 700, "condlist") == false and orders() == 3, "co-op: an NPC is no victim")

	-- no player in the state (a target that is no player): the player nearest to the robber
	local npc2 = npc_at(702, 10)
	state_mgr.set_state(npc2, "punch", nil, 0, { look_object = npc })
	check(api() and api().victim_of(702) == PROXY, "co-op: no player in the state: the nearest player is kept")

	print("== hostplay: another script wrapped actor_punch first")
	world("hostplay", true)
	local _, proxy3 = spawn("coop_player_avatar", vec3(11, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local npc3 = npc_at(700, 12)
	state_mgr.set_state(npc3, "punch", nil, 0, { look_object = proxy3 })
	check(state_mgr_animation_list.animations.punch.into[0][2].f ~= STOCK, "co-op: the stock under the other wrapper is found in the list")
	punch_anim(npc3)
	check(orders(1) == 1, "co-op: the animation's punch still goes to the robbed client")
	host_untouched("co-op, wrapped first")

	print("== hostplay: a robber punches the host himself")
	world("hostplay")
	spawn("coop_player_avatar", vec3(11, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local near_host = npc_at(701, 1)
	db.actor._slot, db.actor._item = 2, select(2, spawn("wpn_ak74", vec3(0, 0, 0), 0))
	state_mgr.set_state(near_host, "punch", nil, nil, { look_object = db.actor }, { animation = true }) -- xr_abuse
	punch_anim(near_host)
	check(orders() == 0, "co-op: the host's own punch sends nothing")
	check(CAMS == 1 and INPUT[1] == 30 and #DROPPED == 1, "co-op: the host's own punch: his camera, input lock and weapon, as in stock")
	punch_anim(near_host)
	check(CAMS == 2, "co-op: each punch is its own (the order ids differ)")
end

-------------------------------------------------------------------------------
local function run_srv_map()
	print("== srv_map: a robber on the map server punches a player")
	world("srv_map")
	local _, proxy = spawn("coop_player_avatar", vec3(11, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local npc = npc_at(700, 12)
	-- xr_abuse's stock target is db.actor: on a map server that is the ghost, no player
	state_mgr.set_state(npc, "punch", nil, nil, { look_object = db.actor }, { animation = true })
	check(api() and api().victim_of(700) == PROXY, "server, map: the ghost is no victim: the player near the robber is kept")
	punch_anim(npc)
	check(orders(1) == 1, "server, map, animation: the order goes to the player's machine")
	xr_effects.actor_punch(db.actor, npc, nil)
	check(orders(1) == 2 and orders() == 2, "server, map, condlist: the order goes to the player's machine")
	host_untouched("server, map")
	-- the second player stands on another map: not here, nothing
	check(api() and api().punch(OTHER, 700, "condlist") == false and orders() == 2, "server, map: a player on another map gets nothing")
	proxy._pos = vec3(30, 0, 0)
	punch_anim(npc)
	check(orders() == 2, "server, map: a far victim gets nothing")
end

-------------------------------------------------------------------------------
local function run_srv_world()
	print("== srv_world: no map here")
	world("srv_world")
	local npc = npc_at(700, 1)
	state_mgr.set_state(npc, "punch", nil, nil, { look_object = db.actor })
	check(api() and api().victim_of(700) == nil, "server, world: no victim is kept without a map")
	punch_anim(npc)
	xr_effects.actor_punch(db.actor, npc, nil)
	check(orders() == 0, "server, world: a punch sends nothing")
	host_untouched("server, world")
	check(#STATES == 1, "server, world: the stock set_state still runs")
end

-------------------------------------------------------------------------------
local function run_none()
	print("== none: single player, the stock punch")
	world("none")
	local npc = npc_at(700, 1)
	db.actor._slot, db.actor._item = 2, select(2, spawn("wpn_ak74", vec3(0, 0, 0), 0))
	state_mgr.set_state(npc, "punch", nil, nil, { look_object = db.actor })
	check(#STATES == 1, "single player: set_state is the stock one")
	punch_anim(npc)
	check(CAMS == 1 and INPUT[1] == 30 and #DROPPED == 1, "single player: the animation's punch is the stock one")
	xr_effects.actor_punch(db.actor, npc, nil)
	check(CAMS == 2 and #INPUT == 2, "single player: the condlist's punch is the stock one")
	local far = npc_at(701, 9)
	punch_anim(far)
	check(CAMS == 2, "single player: a far NPC's animation punches nothing, as in stock")
	check(#SENT == 0, "single player: nothing on the wire")
end

-------------------------------------------------------------------------------
-- The victim's own machine (any mode)
-------------------------------------------------------------------------------
local function run_player()
	print("== a player's machine")
	world("client")
	db.actor._slot, db.actor._item = 3, select(2, spawn("wpn_svd", vec3(0, 0, 0), 0))
	local npc = npc_at(700, 30) -- his copy of the robber; the reach was judged where the map is led
	local order = coop_main.encode({ o = "100-1", n = 700, k = "anim" })
	deliver({ name = "mods.qpunch", payload = order }, 2)
	check(CAMS == 0 and #INPUT == 0, "player: an order from another player is refused")
	deliver({ name = "mods.qpunch", payload = order }, 0)
	check(CAMS == 1 and INPUT[1] == 30 and #DROPPED == 1, "player: the order runs the stock punch on his own actor")
	deliver({ name = "mods.qpunch", payload = order }, 0)
	check(CAMS == 1 and #INPUT == 1, "player: the same order again punches nothing (once)")
	deliver({ name = "mods.qpunch", payload = coop_main.encode({ o = "100-2", n = 700, k = "condlist" }) }, 0)
	check(CAMS == 2, "player: the next order is the next punch")
	-- his copy of the NPC plays the animation too: the decider orders the punch, the copy does not punch him itself
	punch_anim(npc_at(701, 1))
	xr_effects.actor_punch(db.actor, npc_at(702, 1), nil)
	check(CAMS == 2 and #SENT == 0, "player: his copy of a robber neither punches nor orders")
end

for _, name in ipairs(modes.names()) do
	if name == "hostplay" then run_hostplay()
	elseif name == "srv_map" then run_srv_map()
	elseif name == "srv_world" then run_srv_world()
	elseif name == "none" then run_none() end
	run_player()
end

done("quests_punch")
