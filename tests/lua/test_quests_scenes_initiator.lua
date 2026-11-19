-- Dev 57 G15-1, finding m09:1 (G.A.M.M.A. Quests Rebalance xr_effects.script:5586, the Wish Granter): the wish a player makes is
-- his. coop_quests_scenes keeps the CHARACTER of the player who pressed, from the press to the answer and on to the delayed
-- backpack removal: the riches go into his inventory, his backpack goes (not the host's), the immortality's own consequences
-- (the profile, the level change) are his, and the faction change and the world's infos stay shared.
-- Each S4 answer set (tests\lua\support\modes.lua):
--   hostplay   the co-op host leads the press, keeps the window and runs the answer
--   srv_map    a map server leads the press and tells the world server (mods.qsc_offer); it keeps nothing itself
--   srv_world  the world server takes the offer of a map server (never of a playing seat), opens the window, runs the answer
--              for his character's record: the same code path as the co-op host's
--   none       single player: the stock function, untouched
-- plus the player's own machine (the window, the level change of mods.qsc_go) in every run.
-- The real make_a_wish of the merged GAMMA file is used when the review corpus is there, else a shape of it.
-- Run: tools\test_lua.cmd quests_scenes_initiator
local modes = dofile("tests/lua/support/modes.lua")

local BRIDGE = 0x101 -- the map server's peer at the world server (mode_srv_world.lua)
local PROXY, OTHER = 500, 501 -- the characters of peer 1 and peer 2 in host numbering

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return (s:gsub("\r\n", "\n"))
end

-- One function of a script, as the file has it: from its header to the first "end" at the start of a line.
local function cut(text, header)
	local a = text and text:find(header, 1, true)
	if not a then return nil end
	local b = text:find("\nend", a, true)
	if not b then return nil end
	return text:sub(a, b + 3)
end

-- The parts of the GAMMA function this unit is about, for a tree without the review corpus.
local WISH_SHAPE = [[
function make_a_wish(actor, npc, p)
	disable_info("drx_sl_on_find_wish_granter")
	local list = {}
	list[1] = function() error(game.translate_string("st_zone_disappeared"), 2) end
	list[2] = function() give_info("actor_made_wish") give_info("actor_made_wish_for_control") end
	list[4] = function()
		local sim = alife()
		local pos, lid, gid = db.actor:position(), db.actor:level_vertex_id(), db.actor:game_vertex_id()
		ini_sys:section_for_each(function(section)
			local cost = ini_sys:r_float_ex(section, "cost")
			if cost and cost > 0 and ini_sys:r_float_ex(section, "inv_grid_x") then sim:create(section, pos, lid, gid, AC_ID) end
		end)
		local function remove_backpack()
			db.actor:iterate_inventory(function(_, itm)
				if itm:section() == "itm_actor_backpack" or itm:section() == "itm_backpack" then alife_release_id(itm:id()) end
			end, db.actor)
		end
		CreateTimeEvent(0, "remove_backpack", 1, remove_backpack, 0)
		give_info("actor_made_wish_for_riches")
		give_info("actor_made_wish")
	end
	list[5] = function()
		local se = alife():actor()
		local data = utils_stpk.get_actor_data(se)
		if data then
			data.specific_character = "actor_zombied"
			utils_stpk.set_actor_data(data, se)
		end
		set_actor_true_community("zombied")
		give_info("actor_made_wish_immortal")
		give_info("actor_made_wish")
		inc_faction_goodwill_to_actor(db.actor, nil, { "monolith", 5000 })
		inc_faction_goodwill_to_actor(db.actor, nil, { "zombied", 5000 })
		ChangeLevel(vector():set(266.99, 0.00, -131.07), 310937, 181, VEC_ZERO)
	end
	if character_community(db.actor) == "actor_zombied" or character_community(db.actor) == "actor_monolith" then
		list[5] = nil
		ui_dyn_msg_box.multi_choice(list, "st_wish_1", "st_wish_2", "st_wish_3", "st_wish_4", "st_wish_99")
	else
		ui_dyn_msg_box.multi_choice(list, "st_wish_1", "st_wish_2", "st_wish_3", "st_wish_4", "st_wish_5", "st_wish_99")
	end
end
]]
local WISH_SRC = cut(read("temp/review/corpus/merged/xr_effects.script"), "function make_a_wish(") or WISH_SHAPE
print(WISH_SRC == WISH_SHAPE and "== make_a_wish: the shape (no review corpus)" or "== make_a_wish: the merged GAMMA file")

-------------------------------------------------------------------------------
-- One process. kind: an S4 set name, or "client" (a player's machine: a copy of the world)
-------------------------------------------------------------------------------
local function world(kind, overrides)
	MODE = kind == "none" and "sp" or (kind == "client" and "client" or "host")
	local passes, fails = PASSES or 0, FAILS or 0 -- the stubs start the counters again: a run has several worlds
	dofile("tests/lua/support/stubs_mods.lua")
	PASSES, FAILS = passes, fails
	if kind == "srv_map" then coop.is_map_server = function() return true end end
	if kind == "srv_world" then
		coop.is_dedicated = function() return true end
		-- a record carries what its character holds (the map server of his level reports it)
		coop.levels = { carried = function(id)
			local out = {}
			for cid, se in pairs(SE) do
				if se.parent_id == id then out[#out + 1] = { id = cid, section = se._sec, condition = 1 } end
			end
			table.sort(out, function(a, b) return a.id < b.id end)
			return out
		end }
	end
	-- two players: peer 1 plays character 500, peer 2 character 501
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
	GO.has_info = function(self, i) return self._info ~= nil and self._info[i] == true end
	GO.give_info_portion = function(self, i) self._info = self._info or {}; self._info[i] = true end
	GO.disable_info_portion = function(self, i) if self._info then self._info[i] = nil end end
	GO.character_community = function(self) return self._comm or "stalker" end
	actor._comm = "actor_stalker"
	function give_info(i) db.actor:give_info_portion(i) end
	function disable_info(i) db.actor:disable_info_portion(i) end
	has_alife_info = function(i) return db.actor ~= nil and db.actor:has_info(i) end
	function character_community(o) return o and o:character_community() end
	clsid = { online_offline_group_s = 77 }
	SIMBOARD = { assign_squad_to_smart = function() end }
	function IsItem() return false end
	VEC_ZERO = vector():set(0, 0, 0)
	function ini_sys:section_for_each(f)
		local names = {}
		for k in pairs(INI) do names[#names + 1] = k end
		table.sort(names)
		for _, n in ipairs(names) do if f(n) then return end end
	end
	INI.wpn_gift = { cost = 900, inv_grid_x = 1, inv_grid_y = 2 }
	INI.af_gift = { cost = 300, inv_grid_x = 1, inv_grid_y = 1 }
	INI.junk = { cost = 0 }
	PROFILES = {} -- utils_stpk.set_actor_data: whose specific_character was written
	utils_stpk = {
		get_actor_data = function(se) if not se then return nil end return { specific_character = "actor_stalker" } end,
		set_actor_data = function(data, se) PROFILES[#PROFILES + 1] = { id = se.id, sc = data.specific_character } end,
	}
	FACTIONS = {}
	function set_actor_true_community(c) FACTIONS[#FACTIONS + 1] = c end
	TRAVELS = {}
	function ChangeLevel(pos, lvid, gvid, dir) TRAVELS[#TRAVELS + 1] = { x = pos.x, z = pos.z, l = lvid, g = gvid } end
	WINDOWS = {}
	ui_dyn_msg_box = { multi_choice = function(list, ...) WINDOWS[#WINDOWS + 1] = { list = list, names = { ... } } end }
	alife = function()
		return {
			object = function(_, id) return SE[id] end,
			release = function(_, se) release_id(se.id) end,
			level_name = function() return "l01_escape" end,
			actor = function() return SE[0] end,
			create = function(_, sec, pos, lv, gv, parent)
				local se = spawn(sec, pos, parent)
				CREATED[#CREATED + 1] = { sec = sec, id = se.id, parent = parent }
				return se
			end,
		}
	end
	-- the parts of other coop scripts the wish passes through
	coop_npc_logic = { user_of = function(o) return o._user end }
	coop_npc_players = { peer_of = function(id) return coop.peer_of_avatar(id) end }
	coop_tasks = { run_as = function(peer, fn, ...) return fn(...) end }
	coop_quests_far = { with_level_of = function(peer, fn, ...) return fn(...) end }

	-- xr_effects: the wish as the merged GAMMA file has it; goodwill recorded by character
	GOODWILL = {}
	local xe = setmetatable({}, { __index = _G })
	xr_effects = xe
	local f = assert(loadstring(WISH_SRC, "@xr_effects.script"))
	setfenv(f, xe)
	f()
	xe.inc_faction_goodwill_to_actor = function(a, npc, p) GOODWILL[#GOODWILL + 1] = { id = a:id(), c = p[1], d = p[2] } end

	load_script("coop_main")
	load_script("coop_mode")
	if kind == "client" then
		-- a player's machine: its objects are copies, it leads nothing and keeps no world
		modes.install(coop_mode, "hostplay", { leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end })
	else
		modes.install(coop_mode, kind, overrides)
	end
	load_script("coop_trust")
	load_script("coop_mods_core")
	load_script("coop_quests_core")
	coop_quests_core.on_game_start()
	load_script("coop_quests_scenes")
	coop_quests_scenes.on_game_start()
	SendScriptCallback("actor_on_first_update")
	SENT = {}
	return actor
end

-- The Granter, pressed by `user` (a character id here; 0 = this process's own actor).
local function granter(user)
	local _, o = spawn("sar_monolith", vec3(3, 0, 0))
	o._user = user
	return o
end

local function count_sent(name, target)
	local n = 0
	for _, s in ipairs(SENT) do
		if s.name == name and (target == nil or s.target == target) then n = n + 1 end
	end
	return n
end

local function created_for(parent)
	local n = 0
	for _, c in ipairs(CREATED) do if c.parent == parent then n = n + 1 end end
	return n
end

local function released(id)
	for _, r in ipairs(RELEASED) do if r.id == id then return true end end
	return false
end

-- the player's answer as his machine sends it (coop_quests_core.request_host_action: quests.act, a = "wish")
local function answer(from, c)
	deliver({ name = "quests.act", payload = coop_main.encode({ a = "wish", c = c }) }, from)
end

local function goodwill_of(id)
	local n = 0
	for _, g in ipairs(GOODWILL) do if g.id == id then n = n + 1 end end
	return n
end

-------------------------------------------------------------------------------
-- The map server's half: the press of player 1 (character 500) on its map. Returns the offer it sends to the world server.
-------------------------------------------------------------------------------
local function map_server_press(label)
	world("srv_map")
	spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = PROXY, kind = "stalker" })
	xr_effects.make_a_wish(db.actor, granter(PROXY), {})
	local offer, raw = sent("mods.qsc_offer")
	if label then
		check(#WINDOWS == 0, label .. ": the press opens no window on the map server")
		check(count_sent("quests.wish") == 0, label .. ": the map server sends no window itself")
		check(offer ~= nil and raw.target == 0, label .. ": the press goes to the world server (mods.qsc_offer to 0)")
		check(offer and offer.p == 1 and offer.c == PROXY and offer.n == 6 and offer.s4 == "st_wish_4",
			label .. ": the offer names the player, his character and the window's choices")
	end
	return raw and raw.payload
end

-------------------------------------------------------------------------------
local function run_hostplay()
	print("== hostplay: a client's wish at the Monolith, the co-op host decides")
	world("hostplay")
	local _, proxy = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local host_pack = spawn("itm_actor_backpack", vec3(0, 0, 0), 0)
	local his_pack = spawn("itm_actor_backpack", vec3(2, 0, 0), PROXY)

	xr_effects.make_a_wish(db.actor, granter(PROXY), {})
	check(#WINDOWS == 0, "co-op: a client's press opens no window on the host")
	local w = sent("quests.wish")
	check(w and count_sent("quests.wish", 1) == 1 and w.n == 6 and w.s5 == "st_wish_5",
		"co-op: the window goes to the player who pressed, with the stock choices")
	check(count_sent("mods.qsc_offer") == 0, "co-op: the host keeps the offer itself, nothing goes to a world server")

	-- riches: into HIS inventory, and the delayed removal of HIS backpack
	answer(2, 4)
	check(#CREATED == 0, "co-op: a player who was not offered the window gets nothing")
	answer(1, 4)
	check(created_for(PROXY) == 2, "co-op: riches: the items are made in the inventory of the client who wished (" .. created_for(PROXY) .. ")")
	check(created_for(0) == 0, "co-op: riches: nothing is made in the host's inventory (" .. created_for(0) .. ")")
	check(db.actor:has_info("actor_made_wish_for_riches") and db.actor:has_info("actor_made_wish"),
		"co-op: the wish's infos are the world's (shared)")
	run_time_events(2000)
	check(released(his_pack.id), "co-op: the delayed backpack removal takes the wisher's backpack")
	check(not released(host_pack.id), "co-op: the host's backpack stays")
	local made = #CREATED
	answer(1, 4)
	check(#CREATED == made, "co-op: the wish is spent: a second answer makes nothing")
	-- a client cannot make up an offer for himself: a playing seat is never the leader of a press
	SENT = {}
	deliver({ name = "mods.qsc_offer", payload = coop_main.encode({ p = 1, c = PROXY, n = 1, s1 = "st_wish_4" }) }, 1)
	check(count_sent("quests.wish") == 0, "co-op: an offer sent by a client opens no window")

	print("== hostplay: immortality wished by a client")
	world("hostplay")
	spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = PROXY, kind = "stalker" })
	xr_effects.make_a_wish(db.actor, granter(PROXY), {})
	answer(1, 5)
	check(#PROFILES == 0, "co-op: immortality: the host's specific_character is not rewritten")
	check(#TRAVELS == 0, "co-op: immortality: the host does not travel")
	local go, raw = sent("mods.qsc_go")
	check(go and raw.target == 1 and go.l == 310937 and go.g == 181 and math.abs(go.x - 266.99) < 0.01,
		"co-op: immortality: the level change goes to the machine of the client who wished")
	check(goodwill_of(PROXY) == 2 and goodwill_of(0) == 0, "co-op: immortality: the goodwill is the wisher's character's")
	check(#FACTIONS == 1 and FACTIONS[1] == "zombied", "co-op: immortality: the faction change stays the shared call")
	check(db.actor:has_info("actor_made_wish_immortal"), "co-op: immortality: the world's info")

	print("== hostplay: the host's own press")
	world("hostplay")
	local own_pack = spawn("itm_actor_backpack", vec3(0, 0, 0), 0)
	xr_effects.make_a_wish(db.actor, granter(0), {})
	check(#WINDOWS == 1 and #WINDOWS[1].names == 6, "co-op: the host's own press opens his window")
	check(pcall(WINDOWS[1].list[1]), "co-op: choice 1 of the host is no Lua error")
	db.actor._info = {}
	WINDOWS[1].list[4]()
	check(created_for(0) == 2, "co-op: the host's own riches are his, as in stock")
	run_time_events(2000)
	check(released(own_pack.id), "co-op: the host's own backpack goes, as in stock")

	print("== hostplay: the window follows the wisher's own faction")
	world("hostplay")
	local _, mono = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = PROXY, kind = "stalker" })
	mono._comm = "monolith"
	xr_effects.make_a_wish(db.actor, granter(PROXY), {})
	local w2 = sent("quests.wish")
	check(w2 and w2.n == 5 and w2.s5 == "st_wish_99", "co-op: a Monolith client is not offered immortality (the host is not Monolith)")
	answer(1, 5)
	check(#CREATED == 0 and #FACTIONS == 0 and not db.actor:has_info("actor_made_wish"), "co-op: his \"say nothing\" makes no wish")
end

-------------------------------------------------------------------------------
local function run_srv_map()
	print("== srv_map: a player's press on the map server")
	map_server_press("server, map")
	check(#CREATED == 0 and not db.actor:has_info("actor_made_wish"), "server, map: the map server makes no wish itself")
end

-------------------------------------------------------------------------------
local function srv_world(label)
	local payload = map_server_press(nil)
	world("srv_world", { seat_plays = function(peer) return peer ~= 0 and peer ~= BRIDGE end })
	-- the players stand on map servers: their characters are records here
	spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = PROXY, offline = true })
	spawn("coop_player_avatar", vec3(900, 0, 0), nil, { id = OTHER, offline = true })
	SE[PROXY].community = function() return "stalker" end
	SE[PROXY].m_level_vertex_id = 7
	SE[OTHER].community = function() return "stalker" end
	check(payload ~= nil, label .. ": the map server's offer was captured")
	return payload
end

local function run_srv_world()
	print("== srv_world: the world server takes the press of the map server")
	local payload = srv_world("server, world")
	local ghost_pack = spawn("itm_actor_backpack", vec3(0, 0, 0), 0)
	local his_pack = spawn("itm_actor_backpack", vec3(2, 0, 0), PROXY)
	deliver({ name = "mods.qsc_offer", payload = payload }, 1)
	check(count_sent("quests.wish") == 0, "server, world: a playing seat cannot offer a wish")
	deliver({ name = "mods.qsc_offer", payload = payload }, BRIDGE)
	local w = sent("quests.wish")
	check(w and count_sent("quests.wish", 1) == 1 and w.n == 6, "server, world: the window goes from the world server to the player")
	-- two maps: player 2 stands on another map and was offered nothing
	answer(2, 4)
	check(#CREATED == 0, "server, world: a player on another map was not offered the window: nothing")
	answer(1, 4)
	check(created_for(PROXY) == 2 and created_for(0) == 0,
		"server, world: riches: into the record of the wisher's character, not the ghost's (" .. created_for(PROXY) .. "/" .. created_for(0) .. ")")
	check(created_for(OTHER) == 0, "server, world: the player on the other map gets nothing")
	run_time_events(2000)
	check(released(his_pack.id) and not released(ghost_pack.id), "server, world: the delayed removal takes his backpack, through his record")

	print("== srv_world: immortality")
	payload = srv_world("server, world")
	deliver({ name = "mods.qsc_offer", payload = payload }, BRIDGE)
	answer(1, 5)
	check(#PROFILES == 0, "server, world: immortality: the ghost's profile is not rewritten")
	check(#TRAVELS == 0, "server, world: immortality: the world server does not travel")
	local go, raw = sent("mods.qsc_go")
	check(go and raw.target == 1 and go.g == 181, "server, world: immortality: the level change goes to the wisher's machine")
	check(goodwill_of(PROXY) == 2 and goodwill_of(0) == 0, "server, world: immortality: the goodwill is his character's")

	print("== srv_world: offers out of bounds")
	srv_world("server, world")
	local bad = {
		{ p = 1, c = PROXY, n = 99, s1 = "st_wish_1" },
		{ p = 0, c = PROXY, n = 1, s1 = "st_wish_1" },
		{ p = 1, c = -5, n = 1, s1 = "st_wish_1" },
		{ p = 1.5, c = PROXY, n = 1, s1 = "st_wish_1" },
		{ p = 1, c = PROXY, n = 1, s1 = string.rep("x", 300) },
		{ p = 1, c = PROXY, n = 2, s1 = "st_wish_1" },
	}
	for i, t in ipairs(bad) do
		deliver({ name = "mods.qsc_offer", payload = coop_main.encode(t) }, BRIDGE)
		check(count_sent("quests.wish") == 0, "server, world: a bad offer opens no window (" .. i .. ")")
	end
end

-------------------------------------------------------------------------------
local function run_none()
	print("== none: single player, the stock wish")
	world("none")
	xr_effects.make_a_wish(db.actor, granter(0), {})
	check(#WINDOWS == 1 and #WINDOWS[1].names == 6, "single player: the stock window")
	check(not pcall(WINDOWS[1].list[1]), "single player: choice 1 is the stock error")
	WINDOWS[1].list[4]()
	check(created_for(0) == 2 and #SENT == 0, "single player: the stock riches, nothing on the wire")
end

-------------------------------------------------------------------------------
-- The player's own machine (any mode): the window and the level change of immortality.
-------------------------------------------------------------------------------
local function run_player()
	print("== a player's machine")
	world("client")
	deliver({ name = "quests.wish", payload = coop_main.encode({ n = 2, s1 = "st_wish_2", s2 = "st_wish_99" }) }, 0)
	check(#WINDOWS == 1 and WINDOWS[1].names[1] == "st_wish_2", "player: the window opens on his machine")
	WINDOWS[1].list[1]()
	local act, raw = sent("quests.act")
	check(act and act.a == "wish" and act.c == 1 and raw.target == 0, "player: his choice goes to the keeper of the world")

	local go = { x = 266.99, y = 0, z = -131.07, l = 310937, g = 181 }
	deliver({ name = "mods.qsc_go", payload = coop_main.encode(go) }, 2)
	check(#TRAVELS == 0, "player: a level change sent by another player is refused")
	deliver({ name = "mods.qsc_go", payload = coop_main.encode({ x = 1, y = 0, z = 0, l = 5, g = 1e9 }) }, 0)
	check(#TRAVELS == 0, "player: a level change with a game vertex out of bounds is not made")
	deliver({ name = "mods.qsc_go", payload = coop_main.encode(go) }, 0)
	check(#TRAVELS == 1 and TRAVELS[1].l == 310937 and TRAVELS[1].g == 181, "player: the level change of his immortality is made here")

	-- his machine's own copy of the Granter does not lead a press: the stock, as before
	world("client")
	xr_effects.make_a_wish(db.actor, granter(0), {})
	check(#WINDOWS == 1 and not pcall(WINDOWS[1].list[1]), "player: a local run of the effect is the stock one")
	check(count_sent("mods.qsc_offer") == 0 and count_sent("quests.wish") == 0, "player: his copy sends no offer")
end

for _, name in ipairs(modes.names()) do
	if name == "hostplay" then run_hostplay()
	elseif name == "srv_map" then run_srv_map()
	elseif name == "srv_world" then run_srv_world()
	elseif name == "none" then run_none() end
	run_player()
end

done("quests_scenes_initiator")
