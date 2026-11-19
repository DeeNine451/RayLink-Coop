-- Anomaly Coop test, F4 G4-1, finding m30:1 (build 57): Keep Crafting Window Opened (Demonized) keeps the repair window
-- open; its UIRepair.OnRepair (zz_item_repair_keep_crafting_window_open.script:206) repairs at once, spends the support part
-- and the kit (utils_item.discharge / degrade -> alife_release) and refreshes the window from the local inventory 0.1 s later.
-- On a player's machine whose objects are copies the release is a request: the part stays here until the decider removes it,
-- the refresh lists it again, the button comes back, and a second repair is paid with the same part. coop_mods_xchg_repair
-- ignores a repair while the last one's removal is not confirmed (coop_mods_xchg.after_gone) and refreshes the lists after
-- the confirmation; no confirmation in 5 s closes the window. Single player is unchanged.
-- Runs once per answer set of the facade coop_mode (docs\MODES.md section 10):
--   hostplay   the co-op host's own player (removed here, the game object goes a frame later), then a co-op client
--   srv_map    a server player's machine (the map server of his map removes the part)
--   srv_world  a server player's machine (the same, the players on another map)
--   none       single player: the mod's own behaviour
-- The mod's file: GAMMA_SCRIPTS (the stand, read only), else temp\review\corpus\merged, else the stand-in below.
-- Not shipped. Run: tools\test_lua.cmd mods_xchg_repair
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or (name == "hostplay" and "host" or "client")
dofile("tests/lua/support/stubs_mods.lua")
print("== Keep Crafting Window repair guard, answer set " .. name)

local MOD = "zz_item_repair_keep_crafting_window_open"
local SOUNDS = "zz_item_repair_sounds_oleh"
make_actor(vec3(0, 0, 0))
local GO = getmetatable(db.actor)
function GO:get_remaining_uses() return self._uses or 1 end
function GO:set_remaining_uses(n) self._uses = n end

-------------------------------------------------------------------------------
-- stock helpers the window uses (Anomaly 1.5.3 item_repair.script / utils_item.script, the parts that matter)
-------------------------------------------------------------------------------
INI.wpn_ak = {}
INI.part_x = { repair_part_bonus = 0.1 }
INI.repair_kit = { multiuse = 3, repair_only = "wpn_ak", repair_use_parts = true, repair_parts_sections = "part_x",
	repair_min_condition = 0.1, repair_max_condition = 0.95, repair_add_condition = 0.2 }
function IsItem(kind, sec, obj)
	sec = sec or (obj and obj:section())
	if kind == "multiuse" then return INI[sec] and INI[sec].multiuse or nil end
	return nil
end
function parse_list(ini, sec, key, as_set)
	local s, t = ini:r_string_ex(sec, key), {}
	if s then for w in s:gmatch("[^,%s]+") do if as_set then t[w] = true else t[#t + 1] = w end end end
	return t
end
function empty_table(t) for k in pairs(t) do t[k] = nil end end
function random_number(a, b) return math.random(a, b) end
function Unregister_UI() end
utils_xml = { get_color = function() return "" end, get_color_con = function() return "" end }
ui_item = { get_sec_name = function(sec) return sec end }
game_statistics = { increment_statistic = function() end }
PLAYED = 0
utils_obj = { play_sound = function() end }
itms_manager = { play_use_sound = function() PLAYED = PLAYED + 1 end }
ui_options = { get = function() return false end }
utils_item = {
	discharge = function(obj, num)
		if not obj then return end
		num = num or 1
		if IsItem("multiuse", nil, obj) then
			local uses = obj:get_remaining_uses()
			if uses and uses > num then
				obj:set_remaining_uses(uses - num)
				return uses - num
			end
		end
		alife_release(obj)
		return 0
	end,
	degrade = function(obj, num)
		local cond = obj:condition()
		if cond > num then obj:set_condition(clamp(cond - num, 0.01, 0.99)) return end
		alife_release(obj)
		return 0
	end,
}

-- a cell list of utils_ui (Reinit / GetObj / GetCell_Selected / On_Select)
local function cells()
	local c = { cell = {}, objs = {}, sel = nil }
	function c:Reinit(inv, inf)
		self.objs, self.cell, self.sel = {}, {}, nil
		for i, o in ipairs(inv or {}) do
			self.objs[i] = o
			self.cell[i] = { flags = { info = inf and inf[i] or 0 }, IsShown = function() return true end,
				Add_CustomText = function() end }
		end
	end
	function c:Reset() self.objs, self.cell, self.sel = {}, {}, nil end
	function c:GetObj(idx) return idx and self.objs[idx] or nil end
	function c:GetCell_Selected() return self.sel and self.objs[self.sel] or nil end
	function c:On_Select(idx) if self.objs[idx] then self.sel = idx end end
	function c:Show() end
	function c:has(obj)
		for _, o in ipairs(self.objs) do if rawequal(o, obj) then return true end end
		return false
	end
	return c
end
local function text() return { SetText = function(self, s) self.text = s end, Show = function() end } end

item_repair = { degrade_factor = 0.2 }
local UIRepair = {}
item_repair.UIRepair = UIRepair
function UIRepair:InitControls()
	self.cap_menu = text()
	self.text_item, self.con_txt = { text(), text() }, { text(), text() }
	self.CC = { cells(), cells() }
	self.btn_repair = { enabled = false, Enable = function(b, v) b.enabled = v end }
end
-- stock InitCallBacks: AddCallback("btn_repair", BUTTON_CLICKED, self.OnRepair, self) binds the function of that moment
function UIRepair:InitCallBacks() self.click_repair = self.OnRepair end
function UIRepair:Reset(obj, section)
	self.section, self.obj = section, obj
	self.min_condition = ini_sys:r_float_ex(section, "repair_min_condition") or 0
	self.max_condition = ini_sys:r_float_ex(section, "repair_max_condition") or 0
	self.add_condition = ini_sys:r_float_ex(section, "repair_add_condition") or 0
	self.part_bonus = ini_sys:r_float_ex(section, "repair_part_bonus") or 0
	self.use_parts = ini_sys:r_bool_ex(section, "repair_use_parts") or false
	self.repair_only = parse_list(ini_sys, section, "repair_only", true)
	self.parts_multi = 1
	self.parts_sections = parse_list(ini_sys, section, "repair_parts_sections", true)
	self.con_val = {}
	self.CC[2]:Reset()
	self.btn_repair:Enable(false)
	self:InitInventory(1)
end
function UIRepair:InitInventory(n)
	local inv, inf = {}, {}
	if n == 1 then
		db.actor:iterate_inventory(function(_, obj)
			local con = math.ceil(obj:condition() * 100)
			if self.repair_only[obj:section()] and con >= self.min_condition * 100 and con <= self.max_condition * 100 then
				inv[#inv + 1] = obj
			end
		end)
		self.CC[1]:Reinit(inv)
	else
		local obj_s = self.CC[1]:GetCell_Selected(true)
		if not obj_s then return end
		local seen = {}
		db.actor:iterate_inventory(function(_, obj)
			local sec = obj:section()
			if not seen[sec] and obj:id() ~= obj_s:id() and obj:id() ~= self.obj:id() and self.parts_sections[sec] then
				seen[sec] = true
				inv[#inv + 1] = obj
				inf[#inv] = math.floor((ini_sys:r_float_ex(sec, "repair_part_bonus") or self.part_bonus) * 100)
			end
		end)
		self.CC[2]:Reinit(inv, inf)
	end
end
function UIRepair:On_CC_Mouse1(cont, idx)
	if self.CC[cont].cell[idx] then
		self:OnItemSelect(cont)
		if self.use_parts and cont == 1 then self:InitInventory(2) end
	end
end
function UIRepair:OnItemSelect(n)
	local obj_1, obj_n = self.CC[1]:GetCell_Selected(true), self.CC[n]:GetCell_Selected(true)
	if not (obj_1 and obj_n) then return end
	local con = 0
	if n == 2 then con = math.floor((ini_sys:r_float_ex(obj_n:section(), "repair_part_bonus") or self.part_bonus) * 100) end
	self.con_val[1] = math.ceil(obj_1:condition() * 100)
	self.con_val[2] = n == 2 and con or 0
	self.con_val[3] = math.floor(self.add_condition * 100)
	self.con_val[4] = clamp(self.con_val[1] + self.con_val[2] + self.con_val[3], 0, 100)
	self.btn_repair:Enable(true) -- item_repair.script:378: a selection gives the button back
end
function UIRepair:OnRepair() -- stock: repairs, spends, closes (replaced by the mod)
	local obj_1, obj_2 = self.CC[1]:GetCell_Selected(true), self.CC[2]:GetCell_Selected(true)
	if not (obj_1 and self.con_val[4]) then return end
	obj_1:set_condition(self.con_val[4] / 100)
	if obj_2 then utils_item.discharge(obj_2) end
	utils_item.discharge(self.obj)
	self:OnCancel()
end
function UIRepair:OnCancel() self:HideDialog() end
function UIRepair:HideDialog() self.shown = false end
function UIRepair:IsShown() return self.shown == true end
local STOCK_ONREPAIR = UIRepair.OnRepair

-------------------------------------------------------------------------------
-- the mod (its real file when there is one) and the sounds patch that wraps its OnRepair later
-------------------------------------------------------------------------------
-- Stand-in of the mod's OnRepair / UpdateUi (only when no real file is found): repair, spend the part and one kit use,
-- disable the button, refresh from the local inventory after 0.1 s and select the last weapon and part again.
local STAND_IN = [[
item_repair.UIRepair.OnRepair = function(self)
	local obj_1, obj_2 = self.CC[1]:GetCell_Selected(true), self.CC[2]:GetCell_Selected(true)
	if not (obj_1 and self.con_val[4]) then return end
	obj_1:set_condition(self.con_val[4] / 100)
	if obj_2 then utils_item.discharge(obj_2) end
	utils_item.discharge(self.obj)
	self.last_cont, self.last_idx, self.cont_1_last_idx = 2, 1, 1
	self.cont_2_last_idx = obj_2 and 1 or nil
	self.btn_repair:Enable(false)
	CreateTimeEvent("e" .. random_number(1, 1000000), "u" .. random_number(1, 1000000), 0.1, self.UpdateUi, self)
end
item_repair.UIRepair.UpdateUi = function(self)
	if self.obj:get_remaining_uses() <= 1 then self:OnCancel() return true end
	self:InitInventory(1)
	if not self.CC[1]:GetObj(self.cont_1_last_idx) then self:OnCancel() return true end
	self.CC[1]:On_Select(self.cont_1_last_idx)
	self:On_CC_Mouse1(1, self.cont_1_last_idx)
	if self.cont_2_last_idx and self.CC[2]:GetObj(self.cont_2_last_idx) then
		self.CC[2]:On_Select(self.cont_2_last_idx)
		self:On_CC_Mouse1(2, self.cont_2_last_idx)
	end
	return true
end
]]
local STAND_IN_SOUNDS = [[
OnRepair = item_repair.UIRepair.OnRepair
item_repair.UIRepair.OnRepair = function(self)
	OnRepair(self)
	if itms_manager.play_use_sound and not ui_options.get("video/player/animations") then itms_manager.play_use_sound(self.obj) end
end
]]
local function load_mod(module, file, stand_in)
	local src, from = nil, nil
	local dirs = {}
	local stand = os.getenv("GAMMA_SCRIPTS")
	if stand and stand ~= "" then dirs[#dirs + 1] = stand end
	dirs[#dirs + 1] = "temp/review/corpus/merged"
	for _, dir in ipairs(dirs) do
		local fh = io.open(dir .. "/" .. file, "r")
		if fh then
			src, from = fh:read("*a"), dir
			fh:close()
			break
		end
	end
	src, from = src or stand_in, from or "the test's stand-in"
	local env = setmetatable({}, { __index = _G })
	rawset(_G, module, env)
	local f = assert(loadstring(src, "@" .. file))
	setfenv(f, env)
	f()
	print("  (" .. module .. " from " .. from .. ")")
	return env
end

-------------------------------------------------------------------------------
-- the world: a weapon to repair, a support part, a kit with 3 uses; how a release goes in each role
-------------------------------------------------------------------------------
local REQUESTS, LATER, GONE_PARENT = {}, {}, {}
local REPAIRS = 0
-- the inventory of a game object: its online items, also one whose server object has just gone (until GE_DESTROY)
function GO:iterate_inventory(f, o)
	for id, obj in pairs(OBJ) do
		local se = SE[id]
		local parent = se and se.parent_id or GONE_PARENT[id]
		if parent == self._id then f(o, obj) end
	end
end
local function releases_by(role)
	alife_release = function(x)
		local id = type(x.id) == "function" and x:id() or x.id
		if role == "mirror" then
			REQUESTS[#REQUESTS + 1] = id -- a request: the decider removes it, the copy here stays until then
		elseif SE[id] then
			GONE_PARENT[id] = SE[id].parent_id
			SE[id] = nil -- removed here at once, the game object goes on the next frame (GE_DESTROY)
			LATER[#LATER + 1] = id
		end
	end
end
local function frame(ms)
	NOW = NOW + (ms or 20)
	for _, id in ipairs(LATER) do OBJ[id], GONE_PARENT[id] = nil, nil end
	LATER = {}
	for k, e in pairs(TIMEEV) do
		if TIMEEV[k] == e and e.at <= NOW then
			if e.f(unpack(e.p)) then TIMEEV[k] = nil end
		end
	end
	SendScriptCallback("actor_on_update")
end
local function frames(ms) for _ = 1, math.ceil(ms / 100) do frame(100) end end
local function kit_set()
	for id, se in pairs(SE) do if se.parent_id == 0 then SE[id], OBJ[id] = nil, nil end end
	local _, wpn = spawn("wpn_ak", vec3(0, 0, 0), 0, { cond = 0.5 })
	wpn.set_condition = function(self, c) REPAIRS = REPAIRS + 1 self._cond = c end
	local _, part = spawn("part_x", vec3(0, 0, 0), 0)
	local _, kit = spawn("repair_kit", vec3(0, 0, 0), 0)
	kit._uses = 3
	return wpn, part, kit
end
local function open(kit)
	local w = setmetatable({}, { __index = UIRepair })
	w:InitControls()
	w:InitCallBacks()
	w:Reset(kit, kit:section())
	w.shown = true
	item_repair.GUI = w
	return w
end
local function pick(w, cont, idx)
	w.CC[cont]:On_Select(idx)
	w:On_CC_Mouse1(cont, idx)
end
local function click(w) return w.click_repair(w) end

-------------------------------------------------------------------------------
start_all()
for _, n in ipairs({ "coop_mods_xchg", "coop_mods_xchg_repair" }) do
	local ok, m = pcall(load_script, n)
	if ok and type(m) == "table" then
		local started, e = pcall(m.on_game_start)
		if not started then print("  (" .. n .. ".on_game_start: " .. tostring(e) .. ")") end
	else
		print("  (" .. n .. " is not there: " .. tostring(m) .. ")")
	end
end
local G = rawget(_G, "coop_mods_xchg_repair")
modes.install(coop_mode, name)
local function stat(k) return G and G.stats and G.stats[k] or 0 end

frame(1100)
check(UIRepair.OnRepair == STOCK_ONREPAIR, "nothing is wrapped while the mod is not installed")
load_mod(MOD, MOD .. ".script", STAND_IN)
frame(1100)
local function listed(label)
	for _, l in ipairs(coop_mods_core.wrapped) do if l == label then return true end end
	return false
end
check(G ~= nil and UIRepair.OnRepair ~= STOCK_ONREPAIR and listed("item_repair.UIRepair.OnRepair")
	and listed("item_repair.UIRepair.UpdateUi"), "the guard wraps the mod's OnRepair and UpdateUi once the mod is there (coop_status)")
-- the sounds patch (zz_item_repair_sounds_oleh) wraps OnRepair after the mod: the guard is outermost again within a second
load_mod(SOUNDS, SOUNDS .. ".script", STAND_IN_SOUNDS)
frame(1100)

-- A double repair: click, click at once, the mod's refresh, the same weapon and part again, click.
local function double_repair(role, label)
	releases_by(role)
	REQUESTS, REPAIRS, PLAYED = {}, 0, 0
	local wpn, part, kit = kit_set()
	local win = open(kit)
	frame(150) -- the mod's Reset timer: the kit's uses in the title
	pick(win, 1, 1)
	pick(win, 2, 1)
	check(win.CC[2]:has(part) and win.btn_repair.enabled, label .. ": weapon and part selected, the button on")
	click(win)
	pick(win, 1, 1)
	pick(win, 2, 1)
	click(win) -- the same frame
	if role == "mirror" then
		frame(120) -- the mod's refresh timer
		pick(win, 1, 1)
		pick(win, 2, 1)
		click(win) -- the part is still here, its removal not confirmed
		frame(500)
		pick(win, 2, 1)
		click(win)
	end
	return win, wpn, part, kit
end

local function guarded(role, label)
	local ignored0, refreshed0 = stat("ignored"), stat("refreshed")
	local win, wpn, part, kit = double_repair(role, label)
	check(REPAIRS == 1, label .. ": the repairs before the part's removal is confirmed: one (" .. REPAIRS .. ")")
	check(kit._uses == 2, label .. ": one kit use spent (" .. tostring(kit._uses) .. " left)")
	if role == "mirror" then
		check(#REQUESTS == 1 and REQUESTS[1] == part:id(), label .. ": the part's removal asked once (" .. #REQUESTS .. ")")
		check(stat("ignored") - ignored0 == 3, label .. ": the repeated repairs are ignored (" .. (stat("ignored") - ignored0) .. ")")
		check(win.CC[2]:has(part), label .. ": the lists wait for the confirmation (the mod's refresh is held)")
		release_id(part:id()) -- the decider removed it: the copy here goes
		frame()
		frame()
	else
		check(SE[part:id()] == nil and stat("ignored") - ignored0 == 1, label .. ": the part released once, the repeat ignored")
		frames(300)
	end
	check(stat("refreshed") - refreshed0 <= 1 and win:IsShown() and not win.CC[2]:has(part) and win.CC[1]:GetCell_Selected(true) ~= nil
		and win.btn_repair.enabled, label .. ": after the confirmation the window is refreshed: no part, the weapon selected, the button on")
	-- the next repair, now that the part is gone, is an honest one (the kit alone)
	click(win)
	check(REPAIRS == 2 and kit._uses == 1, label .. ": the next repair after the confirmation goes through (kit " .. tostring(kit._uses) .. ")")
	frames(300)
	return win
end

if name == "none" then
	-- single player: the mod as it is, every click runs it, the mod's own refresh is not held
	local win, wpn, part, kit = double_repair("local", "single player")
	frames(300)
	check(REPAIRS == 2 and stat("ignored") == 0 and stat("deferred") == 0, "single player: the mod runs unchanged (" .. REPAIRS .. " repairs)")
	check(PLAYED == 2, "single player: the sounds patch plays for each click")
else
	if name == "hostplay" then
		local win = guarded("local", "co-op host")
		check(PLAYED == 2, "co-op host: the ignored click plays no sound (the guard is outermost over the sounds patch)")
		MODE, SELF = "client", 1
		modes.install(coop_mode, "hostplay", { leads_here = function() return false end,
			is_player_mirror = function() return true end, decides_world = function() return false end,
			decider = function() return "other" end })
		guarded("mirror", "co-op client")
	else
		-- the srv layer as a server player's machine answers it (the sets model the servers; the guard asks nothing)
		modes.install(coop_mode, name, { actor_is_player = function() return true end, leads_here = function() return false end,
			is_player_mirror = function() return true end, decides_world = function() return false end,
			where = function() return "here" end, decider = function() return "other" end })
		guarded("mirror", name == "srv_map" and "server player (map server decides)" or "server player (another map)")
	end
	-- no confirmation: the window closes after 5 s, the guard lets go
	releases_by("mirror")
	REQUESTS, REPAIRS = {}, 0
	local wpn, part, kit = kit_set()
	local win = open(kit)
	frame(150)
	pick(win, 1, 1)
	pick(win, 2, 1)
	click(win)
	frames(4000)
	check(win:IsShown() and REPAIRS == 1, "no confirmation yet after 4 s: the window waits")
	frames(1500)
	check(not win:IsShown() and stat("closed") >= 1, "no confirmation in 5 s: the window is closed")
	local again = open(kit)
	frame(150)
	pick(again, 1, 1)
	click(again)
	check(REPAIRS == 2, "after the close the guard lets the next repair through")
	frames(300)
	-- closed and opened again (the same window, item_repair.GUI) before the confirmation: the held refresh does not close it
	REQUESTS, REPAIRS = {}, 0
	wpn, part, kit = kit_set()
	local gui = open(kit)
	frame(150)
	pick(gui, 1, 1)
	pick(gui, 2, 1)
	click(gui)
	frame(120) -- the mod's refresh is held
	gui:OnCancel()
	gui:Reset(kit, kit:section())
	gui.shown = true
	frame(150)
	release_id(part:id())
	frame()
	frame()
	check(gui:IsShown() and REPAIRS == 1, "reopened before the confirmation: the window stays open (no stale refresh)")
	pick(gui, 1, 1)
	click(gui)
	check(REPAIRS == 2, "reopened: the next repair goes through after the confirmation")
	frames(300)
	-- the mod's refresh timer routed host-only (as the two other keep-window mods, coop_compat_crafting.ltx): the router
	-- drops it on a player's machine, the guard refreshes the window itself after the confirmation
	REQUESTS, REPAIRS = {}, 0
	wpn, part, kit = kit_set()
	local quiet = open(kit)
	frame(150)
	pick(quiet, 1, 1)
	pick(quiet, 2, 1)
	click(quiet)
	for k in pairs(TIMEEV) do TIMEEV[k] = nil end -- no time event of the mod runs here
	frame(500)
	check(quiet.CC[2]:has(part) and REPAIRS == 1, "host-only refresh timer: the window waits for the confirmation")
	release_id(part:id())
	frame()
	frames(400)
	check(quiet:IsShown() and not quiet.CC[2]:has(part) and quiet.btn_repair.enabled,
		"host-only refresh timer: the guard refreshes the window after the confirmation")
	frames(300)
	-- a session that ends: the guard steps aside
	MODE = "sp"
	releases_by("local")
	REPAIRS = 0
	local w2, p2, k2 = kit_set()
	local solo = open(k2)
	frame(150)
	pick(solo, 1, 1)
	pick(solo, 2, 1)
	click(solo)
	pick(solo, 1, 1)
	pick(solo, 2, 1)
	click(solo)
	check(REPAIRS == 2, "outside a session the clicks reach the mod unchanged")
end

done("mods_xchg_repair@" .. name)
