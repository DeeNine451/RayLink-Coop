-- Weapon Parts Overhaul on split levels: the dots of a weapon in a body or a box, its strip, and who knows its parts.
-- Owner, live 2026-11-15 (build 50, a world server and split levels, he was a client), a dead NPC with three weapons:
--   1. "When I opened it, the condition of the parts was not shown as dots at all."
--   2. "Then I took all the other items, and it began to show."
--   3. "I took all the parts off; in the end some parts were still shown as dots, as if they still hang there."
--   4. "I dragged the weapon into my inventory, put everything on, threw it back into the NPC, and the parts cannot be taken
--       off in it at all any more."
-- and in his log "arti_jamming.script:384: bad argument #1 to 'pairs' (table expected, got nil)" every second.
-- Three parties where the bug needs them: the world server (peer 0), the map server of the level (bridge 0x100, the authority
-- of the body and of the players' characters standing there), two clients (1, 2) on that level. The real G.A.M.M.A. code runs:
-- item_parts (whole file), WPO's evaluate patch and act_fieldstrip (zzzz_arti_jamming_repairs), arti_jamming (whole file),
-- the dots (z_item_icon_info, whole file) over the real utils_ui cell methods (UICellItem:Update, UICellContainer:UpdateItem,
-- GetID, GetCell_ID). The G.A.M.M.A. scripts come from GAMMA_SCRIPTS, else temp/gamma_ref/scripts.
dofile("tests/lua/support/harness_economy.lua")

local function read_ref(name)
	for _, dir in ipairs({ os.getenv("GAMMA_SCRIPTS") or false, "temp/gamma_ref/scripts" }) do
		if dir then
			local f = io.open(dir .. "/" .. name .. ".script", "r")
			if f then
				local s = f:read("*a")
				f:close()
				return s
			end
		end
	end
end
local SRC = {}
for _, n in ipairs({ "item_parts", "zzzz_arti_jamming_repairs", "arti_jamming", "z_item_icon_info", "utils_ui" }) do
	SRC[n] = read_ref(n)
	if not SRC[n] then
		print("SKIP mods_wpo_split requires the G.A.M.M.A. script " .. n .. " (GAMMA_SCRIPTS or temp/gamma_ref/scripts)")
		print("0 passed, 0 failed")
		return
	end
end
local function slice(src, from, to)
	local a = assert(src:find(from, 1, true), "slice start " .. from)
	local b = assert(src:find(to, a, true), "slice end " .. to)
	return src:sub(a, b - 1)
end
local function run_in(module, source, label)
	setfenv(assert(loadstring(source, "@" .. label)), module)()
end
local function load_module(W, name, source)
	local module = rawget(W, name) or setmetatable({}, { __index = W })
	W[name] = module
	run_in(module, source, name .. ".script")
	return module
end

local GUN, BODY = "wpn_ak74", "stalker_dead"
local PARTS = { "prt_w_trigger_1", "prt_w_spring_1", "prt_w_barrel_1" }
local MK = 0x100
local SPLIT = true
local CLR_MISSING = "argb(255,70,60,60)"

-------------------------------------------------------------------------------
-- engine and G.A.M.M.A. stand-ins of one machine
-------------------------------------------------------------------------------
local function configure(W)
	W.STRINGS = W.STRINGS or {}
	W.game = { translate_string = function(s) return W.STRINGS[s] or s end, actor_lower_weapon = function() end,
		get_game_time = function() return { ms = 0 } end }
	W.sound_object = function() return { playing = function() return false end } end
	W.AC_ID = 0
	W.key_bindings = setmetatable({}, { __index = function(_, k) return k end })
	W.ini_sys = { r_string_ex = function() return nil end }
	W.itms_manager = { ini_parts = {
		r_string_ex = function(_, sec, key)
			if sec == "con_parts_list" and key == GUN then return table.concat(PARTS, ",") end
		end,
		r_float_ex = function() return nil end,
	} }
	W.utils_data = { collect_section = function() return {} end, CTime_to_table = function(t) return t end }
	W.a_arti_jamming_mcm = { get_config = function(key)
		if key == "newdrops" then return true end
		if key == "newdropschance" then return 50 end
		if key == "jamchance" then return 1 end
		if key == "verbosity" then return 0 end
		return false
	end }
	W.SYS_GetParam = function(kind, sec, key, default)
		if key == "cond_part" then return sec:sub(1, 4) == "prt_" end
		if key == "inv_grid_width" then return 5 end
		local values = { condition_shot_dec = 0.0008, misfire_start_prob = 0.003, fire_modes = "1" }
		local v = values[key]
		if v == nil then return default end
		return v
	end
	W.IsWeapon = function(o, clsid) if o then return o:section() == GUN end return clsid == "wpn" end
	W.IsMelee = function() return false end
	W.IsOutfit = function() return false end
	W.IsHeadgear = function() return false end
	W.IsAmmo = function() return false end
	W.IsItem = function(kind, sec) return kind == "part" and type(sec) == "string" and sec:sub(1, 4) == "prt_" end
	W.IsStalker = function(o) return o and o._kind == "stalker" end
	W.IsMonster = function() return false end
	W.IsInvbox = function(o) return o and o._kind == "box" end
	W.empty_table = function(t) for k in pairs(t or {}) do t[k] = nil end end
	W.is_empty = function(t) return t == nil or next(t) == nil end
	W.dup_table = function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
	W.size_table = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
	W.random_key_table = function(t) for k in pairs(t) do return k end end
	W.str_explode = function(s) local out = {} for v in s:gmatch("[^,]+") do out[#out + 1] = v end return out end
	W.invert_table = function(t) local o = {} for k, v in pairs(t) do o[v] = k end return o end
	W.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
	W.spairs = function(t, order)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local i = 0
		return function() i = i + 1 local k = keys[i] if k ~= nil then return k, t[k] end end
	end
	W.GetARGB = function(a, r, g, b) return string.format("argb(%d,%d,%d,%d)", a, r, g, b) end
	W.utils_xml = { get_color = function(name) return "clr(" .. name .. ")" end, lerp_color = function() return "lerp" end,
		get_color_con = function() return "" end }
	W.ui_item = { get_sec_name = function(s) return s end }
	W.utils_obj = { play_sound = function() end }
	W.mag_support = { using_mags = function() return false end }
	W.utils_stpk = { get_item_data = function() return {} end, set_item_data = function() end }
	W.CREATED = {}
	W.alife_create = function(sec, pos, lv, gv, parent)
		W.CREATED[#W.CREATED + 1] = { sec = sec, parent = parent }
		return { id = 9000 + #W.CREATED }
	end
	local sim = W.alife
	W.alife = function()
		local s = sim()
		s.register = function() end
		return s
	end
	W.Frect = function() return { set = function(self) return self end } end
	W.vector2 = function() return { set = function(self, x, y) self.x, self.y = x, y return self end } end
	W.ui_mcm = nil
	W.db.actor.active_item = function() return W.ACTIVE_WEAPON end
	W.db.actor.level_vertex_id = function() return 7 end
	W.db.actor.game_vertex_id = function() return 8 end
end

-- the dots: z_item_icon_info over the real cell methods of utils_ui
local function load_ui(W)
	local U = setmetatable({}, { __index = W })
	W.utils_ui = U
	U.UICellItem, U.UICellContainer = {}, {}
	local CI = U.UICellItem
	-- the stock methods UICellItem:Update calls that draw nothing of the parts
	function CI:Print() end
	function CI:GetXML() return {} end
	function CI:InitControls() end
	function CI:Add_ProgressBar() end
	function CI:Add_Attachements() end
	function CI:Add_Counter() end
	function CI:Add_Upgrade() end
	function CI:Check_TradeMode() return false end
	function CI:Colorize() end
	function CI:Reset() end
	function CI:ResetToChild() return true end
	local src = SRC.utils_ui
	local env = setmetatable({ UICellItem = U.UICellItem, UICellContainer = U.UICellContainer }, { __index = W })
	run_in(env, slice(src, "function UICellItem:Update(obj)", "function UICellItem:Add_Icon("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:GetCell_ID(", "function UICellContainer:GetCell_SEC("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:GetID(", "function UICellContainer:AddItemInCell("), "utils_ui.script")
	run_in(env, slice(src, "function UICellContainer:UpdateItem(", "function UICellContainer:FindFreeCell("), "utils_ui.script")
	-- the menu defaults of Item Icon Info (item_icon_info_mcm is not among the reference scripts: the parts' own options)
	W.item_icon_info_mcm = { op = { gr = {
		{ id = "part_dots", gr = {
			{ id = "enable", def = true }, { id = "show_on_equipped", def = true }, { id = "show_on_wpn", def = true },
			{ id = "show_on_armor", def = true }, { id = "size_mult", def = 1 }, { id = "separator_width", def = 1 },
			{ id = "position", def = 1 }, { id = "wpo_mode", def = true }, { id = "wpo_green", def = 80 },
			{ id = "wpo_yellow", def = 60 }, { id = "wpo_orange", def = 40 },
		} },
		{ id = "cond_text", gr = { { id = "hide_bar", def = false } } },
		{ id = "mag_info", gr = { { id = "hide_bar", def = false } } },
	} } }
	W.CScriptXmlInit = function()
		return {
			ParseFile = function() end,
			InitStatic = function(_, name)
				local d = { name = name, shown = false }
				function d:Show(s) self.shown = s end
				function d:SetWndRect() end
				function d:SetWndPos() end
				function d:SetTextureColor(c) self.color = c end
				return d
			end,
		}
	end
	local z = load_module(W, "z_item_icon_info", SRC.z_item_icon_info)
	z.on_game_start()
	for _, f in ipairs({ "Add_Mag_Icon_Text", "Add_Condition_Text", "Add_Ammo_Short_Name_Text", "Add_Money_Text",
		"Add_Recipe_Icon_Text", "Add_Weapon_Name", "Add_Repair_Icon" }) do
		z[f] = function() end
	end
	-- ui_inventory.GUI: a window with its containers (UIInventory.CC); shown or not
	local gui = { CC = {}, shown = false }
	function gui:IsShown() return self.shown end
	W.ui_inventory = { GUI = gui }
	W.UPDATES = {} -- id -> how many times its cell was drawn again
end

-- a window on a body: one cell per item, built the way UICellItem:Set ends (self:Update(obj))
local function open(W, cont_id, ids)
	local U = W.utils_ui
	local cc = setmetatable({ cell = {}, indx_id = {}, indx_sec = {}, showcase = false, path = "npc:cont_bag" },
		{ __index = U.UICellContainer })
	for i, id in ipairs(ids) do
		local obj = W.level.object_by_id(id)
		local ci = setmetatable({ ID = id, section = obj:section(), showcase = 0, path = cc.path, indx = i, flags = {},
			container = cc, cell = { GetHeight = function() return 50 end } }, { __index = U.UICellItem })
		local upd = ci.Update
		ci.Update = function(self, o)
			W.UPDATES[id] = (W.UPDATES[id] or 0) + 1
			return upd(self, o)
		end
		cc.cell[i] = ci
		cc.indx_id[id] = i
		ci:Update(obj)
	end
	W.ui_inventory.GUI.CC = { npc_bag = cc }
	W.ui_inventory.GUI.shown = true
	W.ui_inventory.GUI.npc_id = cont_id
	return cc
end
local function close(W) W.ui_inventory.GUI.shown = false end

-- the dots a cell shows now: part -> colour (only shown dots)
local function dots(W, id)
	local cc = W.ui_inventory.GUI.CC.npc_bag
	local ci = cc and cc:GetCell_ID(id)
	local out, n = {}, 0
	for part, d in pairs(ci and ci.parts_indicators or {}) do
		if d.shown then
			out[part] = d.color
			n = n + 1
		end
	end
	return out, n
end

-------------------------------------------------------------------------------
-- the session
-------------------------------------------------------------------------------
local function item(W, id, sec, parent, cond, kind)
	local o = add_item(W, id, sec, parent)
	o.cond = cond or 1
	o._kind = kind
	function o:condition() return self.cond end
	function o:clsid() return self._section == GUN and "wpn" or "other" end
	function o:position() return vec(21, 0, 0) end
	function o:alive() return false end
	function o:get_ammo_in_magazine() return 0 end
	function o:force_unload_magazine() end
	function o:parent()
		local p = self._parent
		if p == nil or p == 65535 then return nil end
		return W.OBJ[p] or W.level.object_by_id(p) or (p == 0 and W.db.actor) or nil
	end
	return o
end

-- where an item is: in the body, or carried by peer `who` (his character's local id differs on his own machine)
local function place(id, where)
	for peer, W in pairs(WORLDS) do
		local pid = where
		if type(where) == "table" then
			pid = (peer == where.peer) and 0 or PLAYERS[where.peer].proxy
		end
		if W.OBJ[id] then W.OBJ[id]._parent = pid end
		if W.SE[id] then W.SE[id].parent_id = pid end
	end
end

local function settle(rounds)
	for _ = 1, rounds or 6 do
		for _, W in pairs(WORLDS) do
			W.NOW = W.NOW + 400
			fire(W, "actor_on_update")
			run_time_events(W)
		end
		deliver_all()
	end
end

local function setup(split)
	SPLIT = split
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "anna", proxy = 501 }, [2] = { nick = "boris", proxy = 502 } }
	POS = { [0] = { x = 900, y = 0, z = 0 }, [1] = { x = 20, y = 0, z = 0 }, [2] = { x = 22, y = 0, z = 0 } }
	BRIDGES = split and { [MK] = { nick = "map server", players = { 1, 2 } } } or {}
	QUEUE, WORLDS = {}, {}
	local peers = { 0, 1, 2 }
	if split then peers[#peers + 1] = MK end
	for _, peer in ipairs(peers) do
		local W = make_world(peer)
		configure(W)
		if peer == MK then
			W.coop.is_host = function() return false end
			W.coop.is_client = function() return true end
			W.coop.is_map_server = function() return true end
			W.coop.players = function()
				local out = {}
				for _, p in ipairs(BRIDGES[MK].players) do
					out[#out + 1] = { id = p, nick = PLAYERS[p].nick, rtt = 0, is_self = false, avatar_id = PLAYERS[p].proxy }
				end
				return out
			end
			W.coop.levels = { split = function() return SPLIT end }
		elseif peer == 0 then
			W.coop.levels = {
				split = function() return SPLIT end,
				map_servers = function() return split and { { bridge = MK, level = 2 } } or {} end,
				bridge_of_player = function(p) if split and (p == 1 or p == 2) then return MK end end,
			}
		else
			W.coop.levels = { split = function() return SPLIT end }
		end
		-- the characters of the players, as entities
		for q, info in pairs(PLAYERS) do
			local lid = info.proxy
			if peer == q then lid = 0 elseif peer ~= 0 and peer ~= MK and info.proxy == 0 then lid = PLAYERS[peer].proxy end
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
		-- the body on the map server's level
		item(W, 700, BODY, nil, 1, "stalker")
		-- the scripts, loaded first, started after (axr_main)
		local jam = load_module(W, "arti_jamming", SRC.arti_jamming)
		load_module(W, "item_parts", SRC.item_parts)
		local z = W.zzzz_arti_jamming_repairs or setmetatable({}, { __index = W })
		W.zzzz_arti_jamming_repairs = z
		z.has_parts, z.is_part, z.print_dbg, z.get_config = jam.has_parts, jam.is_part, jam.print_dbg, W.a_arti_jamming_mcm.get_config
		z.reset_cgd, z.current_id, z.gc = jam.reset_cgd, jam.current_id, W.game.translate_string
		z.sort_parts = function() return false end
		run_in(z, "local ini_parts = itms_manager.ini_parts\n" ..
			slice(SRC.zzzz_arti_jamming_repairs, "local good_breakpoint", "local temp_con = {}"), "zzzz_arti_jamming_repairs.script")
		run_in(z, slice(SRC.zzzz_arti_jamming_repairs, "function act_fieldstrip(", "function on_game_start()"),
			"zzzz_arti_jamming_repairs.script")
		if peer ~= 0 and peer ~= MK then load_ui(W) end
		load_script(W, "coop_economy_core")
		load_script(W, "coop_economy_mdata")
		load_script(W, "coop_mods_core")
		load_script(W, "coop_mods_mags")
		W.coop_economy_mdata.on_game_start()
		W.coop_mods_mags.on_game_start()
		W.JAM_REFRESH = W.coop_mods_core.upvalue(jam.on_game_start, "actor_on_update")
	end
	return WORLDS[0], WORLDS[1], WORLDS[2], WORLDS[MK]
end

local function parts(W, id) return W.se_load_var(id, nil, "parts") end
local function gun_everywhere(id, mk_cond, client_cond)
	for peer, W in pairs(WORLDS) do
		item(W, id, GUN, 700, (peer == MK or peer == 0) and mk_cond or client_cond)
	end
end
local function received(W, name, peer)
	local out = {}
	for _, m in ipairs(QUEUE) do
		if m.to == peer and m.name == name then out[#out + 1] = CM_DECODE(m.payload) end
	end
	return out
end
local function tips_of(W) return table.concat(W.TIPS, "|") end
local function no_errors(W, label)
	check(not W.HANDLER_ERRORS and W.coop_mods_core.stats.errors == 0,
		label .. ": no handler or mod errors (" .. tostring(W.HANDLER_ERRORS) .. "/" .. W.coop_mods_core.stats.errors .. ")")
end

-------------------------------------------------------------------------------
section("1. the dots of a fresh weapon in a body come as soon as the authority's parts are here (symptoms 1, 2)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.31, 1.0) -- the map server gave the gun its wear; the client's copy still has the spawn's 1.0
	item(A, 881, "bread", 700) item(M, 881, "bread", 700)
	open(A, 700, { 880, 881 })
	local _, n = dots(A, 880)
	check(n == 0 and parts(A, 880) == nil, "opened: no parts yet, no dots (not rolled from the copy's 1.0)")
	local upd_bread = A.UPDATES[881]
	settle()
	check(parts(M, 880) ~= nil and parts(M, 880)[GUN] == 31, "the map server rolled the parts from its own condition (31)")
	check(parts(A, 880) ~= nil and parts(A, 880)[GUN] == 31, "the client has the map server's parts")
	local d, n2 = dots(A, 880)
	check(n2 == 3, "the open window draws the gun's dots once its parts are here, nothing taken (" .. n2 .. ")")
	check(A.UPDATES[881] == upd_bread, "only the cell of that item was drawn again")
	-- a window that is not shown is not touched
	close(A)
	local before = A.UPDATES[880]
	M.item_parts.set_parts_con(880, { [GUN] = 31, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	check(parts(A, 880).prt_w_trigger_1 == 77 and A.UPDATES[880] == before, "closed window: the parts arrive, no cell is drawn")
	-- the world server's own process with no window: nothing to draw, no error
	no_errors(A, "client") no_errors(M, "map server") no_errors(H, "world server")
end

-------------------------------------------------------------------------------
section("2. a strip in a body: the dots follow the authority's new table (symptom 3)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	open(A, 700, { 880 })
	local d = dots(A, 880)
	check(d.prt_w_trigger_1 ~= nil and d.prt_w_trigger_1 ~= CLR_MISSING, "before: the trigger is on the gun")
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(parts(M, 880).prt_w_trigger_1 == -1 and #M.CREATED == 1 and M.CREATED[1].parent == 501,
		"the map server stripped the trigger into the requester's character")
	check(parts(A, 880).prt_w_trigger_1 == -1, "the client has the new table")
	d = dots(A, 880)
	check(d.prt_w_trigger_1 == CLR_MISSING, "the open window shows the trigger as missing (" .. tostring(d.prt_w_trigger_1) .. ")")
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, nil) -- everything else but the barrel
	settle()
	d = dots(A, 880)
	check(d.prt_w_spring_1 == CLR_MISSING and d.prt_w_barrel_1 ~= CLR_MISSING, "strip all: the spring is missing, the barrel stays")
	no_errors(A, "client") no_errors(M, "map server")
end

-------------------------------------------------------------------------------
section("3. the map server knows what a client wrote on his own weapon (symptom 4)")
do
	local H, A, B, M = setup(true)
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = -1, prt_w_spring_1 = -1, prt_w_barrel_1 = 55 })
	settle()
	-- he takes the stripped gun into his bag and puts the parts back on there (his own items: WPO's own code on his machine)
	place(880, { peer = 1 })
	A.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 81, prt_w_spring_1 = 72, prt_w_barrel_1 = 55 })
	settle()
	check(parts(H, 880).prt_w_trigger_1 == 81, "the world server stored the owner's table")
	check(parts(B, 880).prt_w_trigger_1 == 81, "the other player has it")
	check(parts(M, 880) and parts(M, 880).prt_w_trigger_1 == 81, "the map server of his level has it too")
	-- back into the body: the trigger comes off again
	place(880, 700)
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(#M.CREATED == 1 and M.CREATED[1].sec == "prt_w_trigger_1", "the map server strips the part he put on")
	check(parts(A, 880).prt_w_trigger_1 == -1 and parts(H, 880).prt_w_trigger_1 == -1, "and everybody has the new table")

	-- the world server has a table the map server never saw (a player's own roll): the map server never rolls over it
	gun_everywhere(882, 0.4, 0.4)
	place(882, { peer = 1 })
	local T = { [GUN] = 40, prt_w_trigger_1 = 12, prt_w_spring_1 = 34, prt_w_barrel_1 = 56 }
	A.item_parts.set_parts_con(882, T)
	settle()
	place(882, 700)
	B.MDATA.se_object[882].parts = nil -- boris lost his copy of it (a value that waited for the item and timed out)
	B.item_parts.evaluate_parts(B.OBJ[882])
	settle()
	check(parts(H, 882).prt_w_trigger_1 == 12 and parts(A, 882).prt_w_trigger_1 == 12, "the owner's table stays canonical")
	check(parts(M, 882).prt_w_trigger_1 == 12, "the map server kept it, nothing rolled")
	check(parts(B, 882) and parts(B, 882).prt_w_trigger_1 == 12, "the asker gets the known table back")

	-- the other vars a player may write go there too (a looted mutant); the NPC state the authorities keep does not
	for _, W in pairs(WORLDS) do add_entity(W, 950, "dog_strong", nil) end
	A.se_save_var(950, nil, "looted", true)
	H.se_save_var(950, nil, "companion", true)
	settle()
	check(M.se_load_var(950, nil, "looted") == true and H.se_load_var(950, nil, "looted") == true, "a client's world flag reaches the map server")
	check(A.se_load_var(950, nil, "companion") == true and M.se_load_var(950, nil, "companion") == nil,
		"the world server's NPC state goes to the players as before, not to the map servers")
	no_errors(A, "client") no_errors(M, "map server") no_errors(H, "world server")
end

-------------------------------------------------------------------------------
section("4. a client's current gun never leaves arti_jamming without a table")
do
	local H, A, B, M = setup(true)
	gun_everywhere(883, 0.27, 1.0)
	place(883, { peer = 1 }) -- just taken: on his machine its condition is still the spawn's
	A.ACTIVE_WEAPON = A.OBJ[883]
	A.NOW = A.NOW + 2000
	local ok, err = pcall(A.JAM_REFRESH)
	check(ok, "arti_jamming's update reads the parts of the gun in hand (" .. tostring(err) .. ")")
	check(parts(A, 883) ~= nil, "the gun has a table on his machine at once")
	local asked = false
	for _, m in ipairs(QUEUE) do if m.name == "mods.wpo_eval" then asked = true end end
	check(asked, "and the authority is asked for the real one")
	tick(A, 400)
	local published = false
	for _, m in ipairs(QUEUE) do
		if m.name == "economy.se" and m.from == 1 and m.payload:find("883", 1, true) then published = true end
	end
	check(not published, "the stand-in table is his machine's alone, not published")
	settle()
	check(parts(A, 883)[GUN] == 27 and parts(H, 883)[GUN] == 27, "the authority's roll (27) replaced it everywhere")
	A.NOW = A.NOW + 2000
	ok, err = pcall(A.JAM_REFRESH)
	check(ok, "and arti_jamming reads it (" .. tostring(err) .. ")")

	-- the authority cannot roll it (it does not know the item): his machine rolls and publishes, as single player does
	item(A, 884, GUN, 0, 0.5)
	A.SE[884].parent_id = 0
	add_entity(H, 884, GUN, 501)
	add_entity(B, 884, GUN, 501)
	A.item_parts.evaluate_parts(A.OBJ[884])
	settle()
	check(parts(H, 884) ~= nil and parts(H, 884)[GUN] == 50, "a refused ask: his own roll reaches the world server")

	-- the ask is lost: after a while his machine rolls for good
	item(A, 886, GUN, 0, 0.45)
	A.SE[886].parent_id = 0
	add_entity(H, 886, GUN, 501)
	A.item_parts.evaluate_parts(A.OBJ[886])
	QUEUE = {}
	settle(2)
	check(parts(H, 886) == nil, "nothing published while the answer may come")
	settle(14)
	check(parts(H, 886) ~= nil and parts(H, 886)[GUN] == 45, "no answer: his own roll reaches the world server")
	no_errors(A, "client") no_errors(M, "map server")
end

-------------------------------------------------------------------------------
section("5. every strip that does nothing tells the requester why")
do
	local H, A, B, M = setup(true)
	A.STRINGS.st_coop_mods_wpo_strip_none = "NONE"
	A.STRINGS.st_coop_mods_wpo_strip_busy = "BUSY"
	gun_everywhere(880, 0.6, 0.6)
	M.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = -1, prt_w_spring_1 = -1, prt_w_barrel_1 = 55 })
	settle()
	A.TIPS = {}
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_trigger_1" })
	settle()
	check(tips_of(A):find("NONE", 1, true) ~= nil, "a part that is off already: he is told (" .. tips_of(A) .. ")")
	A.TIPS = {}
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "" })
	settle()
	check(tips_of(A):find("NONE", 1, true) ~= nil, "strip all with nothing on: he is told")
	A.TIPS = {}
	A.STRINGS.st_coop_mods_wpo_strip_none = nil
	A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_spring_1" })
	settle()
	check(tips_of(A):find("st_coop_mods_wpo_strip_refused", 1, true) ~= nil, "without the new string: the old refusal text")
	-- too many at once: the world server's limit drops some, each dropped one says so
	A.TIPS = {}
	for _ = 1, 14 do A.coop_mods_core.to_host("wpo_strip", { w = 880, p = "prt_w_spring_1" }) end
	deliver_all()
	deliver_all()
	run_time_events(A)
	check(tips_of(A):find("BUSY", 1, true) ~= nil, "requests over the limit are answered (" .. #A.TIPS .. " tips)")
end

-------------------------------------------------------------------------------
section("6. without split levels: the host strips, the client's open window follows too")
do
	local H, A = setup(false)
	item(H, 880, GUN, 700, 0.6) item(A, 880, GUN, 700, 0.6)
	H.item_parts.set_parts_con(880, { [GUN] = 60, prt_w_trigger_1 = 77, prt_w_spring_1 = 66, prt_w_barrel_1 = 55 })
	settle()
	open(A, 700, { 880 })
	POS[1] = { x = 20, y = 0, z = 0 }
	A.zzzz_arti_jamming_repairs.act_fieldstrip(880, "prt_w_trigger_1")
	settle()
	check(parts(H, 880).prt_w_trigger_1 == -1 and parts(A, 880).prt_w_trigger_1 == -1, "the host stripped, the client has it")
	local d = dots(A, 880)
	check(d.prt_w_trigger_1 == CLR_MISSING, "the client's open window shows it missing (" .. tostring(d.prt_w_trigger_1) .. ")")
	-- a fresh gun in a box is rolled by the client itself, as always
	item(H, 885, GUN, 700, 0.5) item(A, 885, GUN, 700, 0.5)
	A.item_parts.evaluate_parts(A.OBJ[885])
	check(parts(A, 885) ~= nil, "one level: the client rolls at once, nobody is asked")
	no_errors(A, "client") no_errors(H, "host")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
