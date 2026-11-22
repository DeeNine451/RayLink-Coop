-- R38: no Lua handle to a freed HUD window survives a HUD rebuild (gamedata/scripts/coop_hud_lifecycle.script), Ядро.
--
-- The fake game UI (tests/lua/support/hud_fake.lua) frees what CHUDManager::OnScreenResolutionChanged frees; a use of a
-- freed window raises, like the AV of 2026-11-21 20:46. Each adapter: the addon takes its windows, the HUD is rebuilt and
-- on_screen_resolution_changed sent, then the addon uses them (a prompt, a marker, a timer). A control run of the same
-- steps without the registry shows the fake does fail the old way. Runs under every answer set: hostplay (the co-op host
-- player), srv_world / srv_map (a client of the server mode: a player's mirror) and none (single player).
-- Real files: ui_circular_progress, ui_timed_prompt (G.A.M.M.A., the stand), actor_effects' HUD_fog piece, the stock
-- sr_timer. Interaction Dot Marks (6578 lines) and modxml_tutorial_hooks are models of the code the adapters rely on; the
-- contract checks below compare every relied-on line and every window field with the real files.
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua") -- GAMMA_DIR
local HUD = dofile("tests/lua/support/hud_fake.lua")
local BS = string.char(92)

local function gamma(name) return GAMMA_DIR .. BS .. name .. ".script" end
local function first_file(...)
	for i = 1, select("#", ...) do
		local p = select(i, ...)
		if p and have_file(p) then return p end
	end
end
local SR_TIMER = first_file(os.getenv("STOCK_SCRIPTS") and (os.getenv("STOCK_SCRIPTS") .. BS .. "sr_timer.script"),
	".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts" .. BS .. "sr_timer.script",
	"temp" .. BS .. "stock_scripts" .. BS .. "scripts" .. BS .. "sr_timer.script")
local G_SCRIPT = first_file(os.getenv("STOCK_SCRIPTS") and (os.getenv("STOCK_SCRIPTS") .. BS .. "_g.script"),
	".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts" .. BS .. "_g.script",
	"temp" .. BS .. "stock_scripts" .. BS .. "scripts" .. BS .. "_g.script")
local REAL = {
	g = G_SCRIPT and HUD.read(G_SCRIPT),
	dotmarks = HUD.read(gamma("ui_hud_dotmarks")),
	hooks = HUD.read(gamma("modxml_tutorial_hooks")),
	timed = HUD.read(gamma("ui_timed_prompt")),
	progress = HUD.read(gamma("ui_circular_progress")),
	effects = HUD.read(gamma("actor_effects")),
	sr_timer = SR_TIMER and HUD.read(SR_TIMER),
	hudmarks = HUD.read(gamma("utils_catspaw_hudmarks")),
}
for k, v in pairs(REAL) do check(v ~= nil, "real script readable: " .. k) end

local MIRROR = { -- a client's process in either mode: its actor is the player, a copy of the world
	actor_is_player = function() return true end,
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
}

-------------------------------------------------------------------------------
-- models (the lines they copy are checked against the real files below)
-------------------------------------------------------------------------------
-- modxml_tutorial_hooks.script:95-103 (its locals and globals), 252-258 (actor_on_first_update, taken from the real file)
local HOOKS_HEAD = [[
local xml_table, maingameui
static_xmlfile = "maingame.xml"
static_xmlnode = "quick_info"
UIStaticTutorials = nil
]]

-- ui_hud_dotmarks.script, the parts coop_hud_lifecycle relies on: 151 (the file local), 6295-6303 (check_for_main_ui),
-- 6448-6480 (validate_object_tables: a container that is not online loses its record), 1758-1767 (quick help),
-- 1783-1853 (__init: the anchor rule of 1810), 2154-2310 (BuildUI: elements cleared at 2156-2160, wnd made under the anchor
-- at 2166, the line at 2139, the long-press indicator at 2219, SetupItemCard at 2400-2411 shows its old card first),
-- 2831-2850 (on_option_change), 3055-3057, 3190-3211 (ShowPrompt), 3394-3440 (its update), 3443-3464 (Destroy),
-- 3775-3783 (actor_on_first_update), 3935-3987 (setup_pri_interact_prompt), 5512-5520 (setup_tutorial_prompt),
-- 5620-5628 (actor_on_update and the quick help)
local DOTMARKS = [[
local maingameui = nil
cfg = { markers = {}, monitors = {}, main_ui_drawn = false, hide_van_interact_ui = true, hide_drop_shadow = false,
	hide_action_text = false, show_item_card = true, fixed_screen_pos = false, invboxes = {} }
function validate_object_tables()
	for k, v in pairs(cfg.invboxes) do
		local obj = level.object_by_id(k)
		if not (obj and obj:name() == v.name) then cfg.invboxes[k] = nil end
	end
end
function actor_on_first_update()
	maingameui = ActorMenu.get_maingame()
	cfg.main_ui_drawn = not not maingameui
	validate_object_tables()
end
function check_for_main_ui()
	if not maingameui then
		maingameui = ActorMenu.get_maingame()
	end
	cfg.main_ui_drawn = not not (maingameui and maingameui.UIStaticQuickHelp and maingameui.UIStaticQuickHelp.Show)
	if cfg.main_ui_drawn then
		UnregisterScriptCallback("actor_on_update", check_for_main_ui)
	end
end
function actor_on_update()
	if cfg.main_ui_drawn and cfg.hide_van_interact_ui then
		maingameui.UIStaticQuickHelp:Show(false)
	end
end
function get_quickhelp_text()
	local text = maingameui and maingameui.UIStaticQuickHelp and maingameui.UIStaticQuickHelp:GetText()
	return text and (text ~= "") and (text ~= " ") and text or nil
end
class "InteractPrompt" (CUIScriptWnd)
function InteractPrompt:__init(anchor, args) super()
	self:SetAutoDelete(true)
	self.elements = { ["wnd"] = true, ["drop"] = true, ["prompt"] = false, ["prompt_l"] = false, ["prompt_c"] = false,
		["prompt_r"] = false, ["bind"] = true, ["bind_sh"] = true, ["label"] = true, ["label_sh"] = true, ["line"] = false,
		["longpress"] = false }
	self.xml = CScriptXmlInit()
	self.uid = "dotmarks_" .. (args.id or "no_id").."_"..(args.event or "").."_"..(args.tutorial or "")
	args.fixed = ((args.fixed ~= nil) and args.fixed) or cfg.fixed_screen_pos
	self.args = args
	self.mark = args.mark
	self.anchor = self.args.fixed and maingameui or anchor or maingameui
	self.last_state = false
	self:on_option_change()
	self:ShowPrompt(args.begin_active, "init")
	RegisterScriptCallback("actor_on_net_destroy", self)
	RegisterScriptCallback("on_option_change", self)
	RegisterScriptCallback("actor_on_update", self)
end
function InteractPrompt:SetupConnectingLine()
	if not self.line then
		self.line = self.xml:InitProgressBar("prog_dotpointer", self.wnd)
	end
end
function InteractPrompt:SetupItemCard(anchor)
	if (not cfg.show_item_card) or (not self.args.is_pickup) then return end
	if self.itemcard then self.itemcard:Show(false) end
	self.itemcard = self.xml:InitStatic("box", anchor or self.wnd)
	self.card_wgt = self.xml:InitStatic("box", self.itemcard)
end
function InteractPrompt:BuildUI()
	if self.wnd then
		for k,_ in pairs(self.elements) do
			self[k] = nil
		end
	end
	self.wnd = self.xml:InitStatic("alt_interact", self.anchor)
	self.drop = self.xml:InitStatic("box", self.wnd)
	self:SetupConnectingLine()
	self.prompt = self.xml:InitStatic("box", self.wnd)
	if self.args.long then
		self.longpress = ui_circular_progress.init_new_indicator({ width = 20 }, nil, self.prompt)
	end
	self.bind_sh = self.xml:InitStatic("box", self.prompt)
	self.label_sh = self.xml:InitStatic("alt_interact:label", self.wnd)
	self.bind = self.xml:InitStatic("box", self.prompt)
	self.lref = self.xml:InitStatic("box", self.wnd)
	self.label = self.xml:InitStatic("alt_interact:label", self.wnd)
	self.label:TextControl():SetText(self.args.text or "")
	if self.args.pri then
		self:SetupItemCard(self.wnd)
	end
	self.init_done = self.init_done or time_global()
	self:actor_on_update()
end
function InteractPrompt:on_option_change()
	if self.args.tutorial and self.init_done then
		self:Destroy()
		return
	end
	self:BuildUI()
	self.bind_sh:Show((not self.dark_text) and (not cfg.hide_drop_shadow))
	self.label_sh:Show(not (cfg.hide_action_text or cfg.hide_drop_shadow))
end
function InteractPrompt:UpdatePromptVisibility(tf)
	self.wnd:Show(tf)
end
function InteractPrompt:SetHoldProgress(progress)
	self.longpress:SetProgressPos(progress)
end
function InteractPrompt:ShowPrompt(tf, reason)
	if (tf and self.destroyed) then return end
	tf = (not not tf) and not self.args.never_show
	self.line:SetProgressPos(tf and 1 or 0)
	if self.longpress and not tf then
		self:SetHoldProgress(0)
	end
	self.disabled = not tf
	if self.last_state ~= self.disabled then
		self.last_state = self.disabled
	end
	if not self.fading_out then
		self:UpdatePromptVisibility(tf)
	end
end
function InteractPrompt:actor_on_update()
	if self.destroyed then
		UnregisterScriptCallback("actor_on_update", self)
		return
	end
	self.label:TextControl():SetText(self.args.text or "")
	self.wnd:SetWndPos(vector2():set(10, 10))
	if self.longpress and not self.disabled then self:SetHoldProgress(0.25) end
end
function InteractPrompt:actor_on_net_destroy() self:Destroy() end
function InteractPrompt:Destroy(reason)
	if self.destroyed then return end
	self.destroyed = true
	self:ShowPrompt(false)
	self:HideDialog()
	get_hud():RemoveDialogToRender(self)
end
function setup_pri_interact_prompt(mark, args)
	if not mark then return end
	if mark.use_pri then
		mark.use_pri:Destroy("re-init of existing prompt")
		mark.use_pri = nil
	end
	args = args or {}
	args.mark = mark
	args.event = "pri_interact"
	args.pri = true
	mark.use_pri = InteractPrompt(args.anchor or mark.marker or maingameui, args)
	return mark.use_pri
end
function setup_tutorial_prompt(tutorial)
	local args = {}
	args.tutorial = tutorial
	args.fixed = (not args.is_campfire)
	args.anchor = maingameui
	args.text = "tutorial " .. tutorial
	cfg.markers[tutorial] = setup_pri_interact_prompt(maingameui, args)
end
-- utils_catspaw_hudmarks.script:708-1122: a marker is a dialog to render, its window made under itself
class "UIHUDMarker" (CUIScriptWnd)
function UIHUDMarker:__init(id) super()
	self.id = id
	self.mark_id = "marker_" .. id
	local xml = CScriptXmlInit()
	self.marker = xml:InitStatic("marker", self)
	get_hud():AddDialogToRender(self)
end
function add_marker(id)
	cfg.markers[id] = UIHUDMarker(id)
	return cfg.markers[id]
end
]]

-------------------------------------------------------------------------------
-- a machine of the set
-------------------------------------------------------------------------------
local function new_machine(set)
	reset_world()
	local role = set == "none" and "single" or (set == "hostplay" and "host" or "client")
	local M = machine(role, role == "client" and 1 or 0, role == "single" and {} or { [0] = 0, [1] = 501 })
	local E = M.env
	local ui = HUD.install(E)
	E.coop_mode = load_script(M, "coop_mode")
	modes.install(E.coop_mode, set, role == "client" and MIRROR or nil)
	E.coop_mods_core = load_script(M, "coop_mods_core")
	E.bind_to_dik = function() return 25 end
	E.key_bindings = setmetatable({}, { __index = function() return 1 end })
	E.ui_mcm = { get = function() return nil end, key_hold = function() return false end, simple_press = function() end,
		get_mod_key = function() return true end, hold = {} }
	E.xr_sound = { get_safe_sound_object = function() return nil end }
	E.utils_data = { collect_section = function() return nil end }
	E.normalize = function(v, a, b) if b == a then return 1 end return (v - a) / (b - a) end
	E.ini_file = function() return nil end
	return M, E, ui
end

local function with_registry(M, E)
	E.coop_hud_lifecycle = load_script(M, "coop_hud_lifecycle")
	E.coop_hud_lifecycle.on_game_start()
	return E.coop_hud_lifecycle
end

local function rebuild(M, ui, w, h)
	ui.rebuild(w or 2560, h or 1440)
	M.fire("on_screen_resolution_changed")
end

local function use(f, ...)
	local ok, err = pcall(f, ...)
	return ok, err
end

local function no_freed(ui) return #ui.freed == 0 end

-------------------------------------------------------------------------------
-- scenarios: run(set, registry) -> results
-------------------------------------------------------------------------------
local S = {}

-- modxml_tutorial_hooks.UIStaticTutorials (a child of the main HUD); the adapter moved from coop_npc_logic (bd13fa88)
function S.tutorial(set, registry)
	local M, E, ui = new_machine(set)
	local piece = HUD.piece(REAL.hooks, "function actor_on_first_update()")
	local hooks = HUD.load_text(M, HOOKS_HEAD .. piece, "modxml_tutorial_hooks", "@" .. gamma("modxml_tutorial_hooks"))
	E.RegisterScriptCallback("actor_on_first_update", hooks.actor_on_first_update)
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	rebuild(M, ui)
	-- a prompt starts and stops (modxml_tutorial_hooks.script:228-229, 239-241)
	local ok = use(function()
		hooks.UIStaticTutorials:SetText("Sleep")
		hooks.UIStaticTutorials:Show(true)
		hooks.UIStaticTutorials:SetText(hooks.UIStaticTutorials:GetText() and "")
	end)
	local o = HUD.obj_of(hooks.UIStaticTutorials)
	return { ok = ok and no_freed(ui), on_new = o and o.alive and HUD.under(o, ui.main_obj()) }
end

-- ui_circular_progress: the default anchor (its file local maingameui) is the main HUD of now
function S.progress(set, registry)
	local M, E, ui = new_machine(set)
	local m = HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress")
	m.on_game_start()
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	rebuild(M, ui)
	local ind
	local ok = use(function()
		ind = m.init_new_indicator({ width = 16 }, "probe") -- no anchor: the default one
		ind:SetProgressPos(0.5)
	end)
	local o = ind and HUD.obj_of(ind.wnd)
	return { ok = ok and no_freed(ui), on_new = o ~= nil and o.alive and HUD.under(o, ui.main_obj()) }
end

-- Catspaw's Timed Tutorial Prompts (ui_timed_prompt): an offer that waits, one that is closing; their circular timers
function S.timed(set, registry)
	local M, E, ui = new_machine(set)
	HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress").on_game_start()
	local m = HUD.load_file(M, gamma("ui_timed_prompt"), "ui_timed_prompt")
	m.on_game_start()
	local life = registry and with_registry(M, E)
	M.fire("actor_on_first_update")
	local r = { executed = false }
	-- one that closes on its own before the rebuild: it is sliding out when the HUD goes
	local closing = m.show_tutorial_prompt("t_closing", "Closing", nil, { wait_time = 300 })
	ui.pump(350)
	local start = NOW
	local waiting = m.show_tutorial_prompt("t_wait", "Waiting", function() r.executed = true end, { wait_time = 5000 })
	local old_key = waiting.prompts and waiting.prompts[1]
	ui.pump(100) -- its slide-in (200 ms) is half done
	rebuild(M, ui)
	local ok = use(function()
		ui.pump(1000) -- its timer ring and both slides go on
	end)
	r.progress_ok = ok
	local expected = 1 - (NOW - start) / 5000
	r.ring = waiting.timer and waiting.timer.last_progress
	r.ring_ok = r.ring ~= nil and math.abs(r.ring - expected) < 0.02
	local wo = HUD.obj_of(waiting.wnd)
	r.on_new = wo ~= nil and wo.alive and HUD.under(wo, ui.main_obj())
	local to = waiting.timer and HUD.obj_of(waiting.timer.wnd)
	r.timer_on_new = to ~= nil and to.alive and HUD.under(to, ui.main_obj())
	r.timeout_kept = waiting.timeout == start + 5000
	r.closing_gone = closing.wnd == nil and closing.prompts == nil and closing.timer == nil
	r.wnds = rawequal(m.wnds[waiting.uid], waiting.wnd)
	r.old_key_off = old_key ~= nil and not ui.registered("on_key_release", old_key)
	-- the player takes the offer: the view key (ui_timed_prompt.script:749-757), then the prompt closes
	local ok2 = use(function()
		E.SendScriptCallback("on_key_release", 25)
		ui.pump(1200)
	end)
	r.ok = ok and ok2 and no_freed(ui)
	r.life = life
	return r
end

-- Interaction Dot Marks: its main HUD and quick help, prompts on a marker, fixed prompts, a long press, a tutorial prompt
function S.dotmarks(set, registry)
	local M, E, ui = new_machine(set)
	HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress").on_game_start()
	local m = HUD.load_text(M, DOTMARKS, "ui_hud_dotmarks", "=ui_hud_dotmarks (model)")
	E.RegisterScriptCallback("actor_on_first_update", m.actor_on_first_update)
	E.RegisterScriptCallback("actor_on_update", m.actor_on_update)
	if registry then with_registry(M, E) end
	local box = M.add(make_obj(801, 5, 0, 0, { _name = "stash_box" }))
	m.cfg.invboxes[801] = { name = "stash_box", found = true, searched = true }
	M.fire("actor_on_first_update")
	M.objects[801] = nil -- the player walks away: the box goes offline, its record stays
	local a, b, c = m.add_marker(701), m.add_marker(702), m.add_marker(703)
	local on_marker = m.setup_pri_interact_prompt(a, { id = 701, text = "Take", begin_active = true })
	local fixed = m.setup_pri_interact_prompt(b, { id = 702, text = "Take", begin_active = true, fixed = true, is_pickup = true })
	c.alt_interact = m.InteractPrompt(c.marker, { id = 703, event = "alt", text = "Hold", long = true, fixed = true })
	m.setup_tutorial_prompt("tutorial_sleep")
	local tutorial = m.cfg.markers.tutorial_sleep
	tutorial:ShowPrompt(true)
	local tutorial_built = tutorial.init_done
	local marker_wnd = on_marker.wnd
	NOW = NOW + 1000
	rebuild(M, ui)
	local r = {}
	-- shown and hidden as before the rebuild (the long-press prompt was made hidden)
	r.shown = HUD.obj_of(fixed.wnd).shown == true and HUD.obj_of(tutorial.wnd).shown == true
		and HUD.obj_of(c.alt_interact.wnd).shown == false
	local ok = use(function()
		M.fire("actor_on_update") -- its own update (quick help) and every prompt's update
		r.quickhelp = m.get_quickhelp_text()
		fixed:ShowPrompt(false)
		fixed:ShowPrompt(true)
		c.alt_interact:ShowPrompt(true)
		c.alt_interact:SetHoldProgress(0.5)
		tutorial:ShowPrompt(false)
		tutorial:ShowPrompt(true)
	end)
	local main = ui.main_obj()
	local function on_new(p) local o = HUD.obj_of(p.wnd) return o ~= nil and o.alive and HUD.under(o, main) end
	r.ok = ok and no_freed(ui)
	r.marker_kept = rawequal(on_marker.wnd, marker_wnd) and HUD.under(HUD.obj_of(on_marker.wnd), HUD.obj_of(a))
	r.fixed_new = on_new(fixed)
	local card = fixed.itemcard and HUD.obj_of(fixed.itemcard)
	r.card_new = card ~= nil and card.alive and HUD.under(card, main)
	r.long_new = on_new(c.alt_interact) and c.alt_interact.longpress ~= nil
		and HUD.under(HUD.obj_of(c.alt_interact.longpress.wnd), HUD.obj_of(c.alt_interact.prompt))
	r.tutorial_new = on_new(tutorial) and m.cfg.markers.tutorial_sleep == tutorial and not tutorial.destroyed
		and tutorial.init_done == tutorial_built
	r.drawn = m.cfg.main_ui_drawn == true
	r.records = m.cfg.invboxes[801] ~= nil and box ~= nil
	return r
end

-- Interaction Dot Marks: a destroyed prompt its mark still holds. end_mark_wounded_state destroys the mark's alt_interact
-- and keeps it (ui_hud_dotmarks.script:1288-1290), and so does InteractPrompt:UpdateMark on an invalid prompt (3128-3133);
-- the mark's update then calls mark.alt_interact:ShowPrompt(false) every time (409), which ShowPrompt passes on to its line
-- and window (3190-3211). A fixed one (the MCM option "fixed screen position") was made under the main HUD.
function S.dotmarks_destroyed(set, registry)
	local M, E, ui = new_machine(set)
	HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress").on_game_start()
	local m = HUD.load_text(M, DOTMARKS, "ui_hud_dotmarks", "=ui_hud_dotmarks (model)")
	E.RegisterScriptCallback("actor_on_first_update", m.actor_on_first_update)
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	local d = m.add_marker(704)
	d.alt_interact = m.InteractPrompt(d.marker, { id = 704, event = "alt", text = "Help", fixed = true, begin_active = true })
	local healed = d.alt_interact
	healed:Destroy("NPC is no longer wounded")
	M.fire("actor_on_update") -- its next update unregisters it (3394-3398)
	rebuild(M, ui)
	local ok = use(function()
		d.alt_interact:ShowPrompt(false) -- the mark's update (409)
		d.alt_interact:ShowPrompt(true) -- a destroyed prompt is never shown again (3191)
	end)
	local o = HUD.obj_of(healed.wnd)
	return { ok = ok and no_freed(ui), freed = ui.freed[1], same = rawequal(d.alt_interact, healed) and healed.destroyed == true,
		hidden = o ~= nil and o.alive and HUD.under(o, ui.main_obj()) and o.shown == false,
		quiet = not ui.registered("actor_on_update", healed) }
end

-- The stock _G.CHUDManager_OnScreenResolutionChanged (_g.script:1304-1307) calls DestroyAll_UI() before it sends
-- on_screen_resolution_changed: hide_hud_all() closes every script GUI that is open (176-242), and its Close unregisters it,
-- which sends GUI_on_hide (154-172). A Catspaw HUD marker updates itself on GUI_on_hide (utils_catspaw_hudmarks.script:
-- 929-931, 1267, 1451-1477) and its func_on_update is Dot Marks' main_marker_update_loop (ui_hud_dotmarks.script:206), which
-- shows or hides the mark's prompts (387). With a script GUI open (the inventory) when the HUD is rebuilt, a fixed prompt is
-- used before the event reaches any script.
local MARKER_UPDATE = [[
function UIHUDMarker:GUI_on_hide() main_marker_update_loop(self) end
function main_marker_update_loop(mark)
	if mark.use_pri then mark.use_pri:ShowPrompt(mark.show_pri) end
end
]]
function S.gui_open(set, registry)
	local M, E, ui = new_machine(set)
	local open = {}
	E.CHUDManager_OnScreenResolutionChanged = function()
		for name, gui in pairs(open) do gui:Close(name) end -- DestroyAll_UI -> hide_hud_all
		E.SendScriptCallback("on_screen_resolution_changed")
	end
	HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress").on_game_start()
	local m = HUD.load_text(M, DOTMARKS, "ui_hud_dotmarks", "=ui_hud_dotmarks (model)")
	HUD.load_text(M, MARKER_UPDATE, "ui_hud_dotmarks", "=ui_hud_dotmarks (model: the marker update)")
	E.RegisterScriptCallback("actor_on_first_update", m.actor_on_first_update)
	local life = registry and with_registry(M, E) or nil
	if life then life.on_game_start() end -- a second game start in the same Lua state wraps nothing twice
	M.fire("actor_on_first_update")
	local b = m.add_marker(702)
	E.RegisterScriptCallback("GUI_on_hide", b)
	local fixed = m.setup_pri_interact_prompt(b, { id = 702, text = "Take", begin_active = true, fixed = true })
	b.show_pri = true
	open.UIInventory = { Close = function(_, name) open[name] = nil E.SendScriptCallback("GUI_on_hide", name) end }
	local before = life and life.stats.rebuilds or 0
	ui.rebuild(2560, 1440)
	local ok = use(E.CHUDManager_OnScreenResolutionChanged)
	local o = HUD.obj_of(fixed.wnd)
	return { ok = ok and no_freed(ui), freed = ui.freed[1],
		on_new = o ~= nil and o.alive and HUD.under(o, ui.main_obj()) and o.shown == true,
		once = life == nil or (life.stats.rebuilds - before == 1) }
end

-- Catspaw's Timed Tutorial Prompts: an offer whose slide-in is running when the HUD goes. do_timed_anim's time event moves
-- the window it was given and finds its record by the offer's uid (ui_timed_prompt.script:1072-1145), so when the offer
-- closes in the first update after the rebuild (the view key, or its timeout) slide_window_out makes a new record under the
-- same uid (929-948) before the old event's last run, and that run reads the new record (active) and moves the old window.
function S.timed_slide(set, registry)
	local M, E, ui = new_machine(set)
	HUD.load_file(M, gamma("ui_circular_progress"), "ui_circular_progress").on_game_start()
	local m = HUD.load_file(M, gamma("ui_timed_prompt"), "ui_timed_prompt")
	m.on_game_start()
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	local r = { executed = false }
	local offer = m.show_tutorial_prompt("t_slide", "Sliding", function() r.executed = true end, { wait_time = 5000 })
	ui.pump(100) -- its slide-in (200 ms) is half done
	rebuild(M, ui)
	local ok = use(function()
		E.SendScriptCallback("on_key_release", 25) -- the view key, before the next update
		ui.pump(1200) -- the offer slides out
	end)
	r.ok = ok and no_freed(ui)
	r.freed = ui.freed[1]
	return r
end

-- 3D PDA (actor_effects): the breath fog keeps 40 CustomStatic windows in its file local `fogs`
function S.fogs(set, registry)
	local M, E, ui = new_machine(set)
	local piece = HUD.piece(REAL.effects, "local fogs")
	local fx = HUD.load_text(M, "local helm_fog = 1\n" .. piece, "actor_effects", "@" .. gamma("actor_effects"))
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	local actor = { power = 0.5 }
	local rect = { x = 0, y = 0, w = 100, h = 100 }
	fx.HUD_fog(true, actor, rect)
	rebuild(M, ui)
	local ok = use(function()
		NOW = NOW + 400
		fx.HUD_fog(true, actor, rect)
		fx.HUD_fog(false, actor, rect)
	end)
	local fogs = E.coop_mods_core.find_local(fx, "fogs")
	local fresh, count = true, 0
	for _, row in ipairs(fogs or {}) do
		for _, w in ipairs(row) do
			local o = HUD.obj_of(w)
			count = count + 1
			fresh = fresh and o.alive and o.gen == ui.gen
		end
	end
	local single = true
	for i = 1, 4 do for ii = 1, 10 do single = single and ui.static_count("hud_blur" .. i .. "_" .. ii) == 1 end end
	return { ok = ok and no_freed(ui), fresh = fresh and count == 40, single = single }
end

-- stock sr_timer: st.timer keeps the hud_timer CustomStatic window between its updates
function S.sr_timer(set, registry)
	local M, E, ui = new_machine(set)
	E.xr_logic = {
		assign_storage_and_bind = function(obj, ini, scheme)
			local st = E.db.storage[obj:id()]
			st[scheme] = st[scheme] or {}
			return st[scheme]
		end,
		cfg_get_switch_conditions = function() return {} end,
		subscribe_action_for_events = function(obj, st, action) st.action = action end,
		try_switch_to_another_section = function() return false end,
		parse_condlist = function() return {} end,
	}
	local m = HUD.load_file(M, SR_TIMER, "sr_timer")
	if registry then with_registry(M, E) end
	M.fire("actor_on_first_update")
	local obj = M.add(make_obj(900, 0, 0, 0))
	E.db.storage[900] = { activation_time = NOW }
	local ini = make_ini({ timer = { { "type", "dec" }, { "start_value", "60000" }, { "string", "st_timer_title" } } })
	m.set_scheme(obj, ini, "sr_timer", "timer")
	local st = E.db.storage[900].sr_timer
	m.add_to_binder(obj, ini, "sr_timer", "timer", st)
	E.db.storage[900].active_scheme = "sr_timer"
	st.action:update(0)
	rebuild(M, ui)
	local ok = use(function()
		NOW = NOW + 1000
		st.action:update(0)
	end)
	local o = HUD.obj_of(st.timer)
	local text = E.get_hud():GetCustomStatic("hud_timer_text")
	local to = text and HUD.obj_of(text:wnd())
	return { ok = ok and no_freed(ui), fresh = o.alive and o.gen == ui.gen and o.text == "0:00:59",
		single = ui.static_count("hud_timer") == 1 and ui.static_count("hud_timer_text") == 1,
		title = to ~= nil and to.gen == ui.gen and to.text == "st_timer_title" }
end

-------------------------------------------------------------------------------
-- the registry itself: phases, order, errors, a later adapter
-------------------------------------------------------------------------------
local function registry_rules(set)
	local M, E, ui = new_machine(set)
	local life = with_registry(M, E)
	local trace = {}
	check(type(life.register) == "function", set .. ": the registry takes a later mod's adapter")
	life.register("zz_later", {
		scripts = { zz_later_mod = { "main" } },
		drop = function() trace[#trace + 1] = "zz.drop" end,
		rebuild = function(main) trace[#trace + 1] = "zz.rebuild:" .. tostring(HUD.obj_of(main) == ui.main_obj()) end,
	})
	life.register("aa_broken", { drop = function() error("boom") end, rebuild = function() trace[#trace + 1] = "aa.rebuild" end })
	M.fire("actor_on_first_update")
	rebuild(M, ui)
	check(trace[1] == "zz.drop" and trace[2] == "aa.rebuild" and trace[3] == "zz.rebuild:true" and #trace == 3,
		set .. ": every drop runs before any rebuild, later adapters by name after the built-in ones, a failing one stops none ("
		.. table.concat(trace, " ") .. ")")
	local cov = life.covered()
	check(cov.zz_later_mod and cov.zz_later_mod.main == "zz_later" and cov.ui_hud_dotmarks and cov.sr_timer,
		set .. ": covered() lists the built-in and the registered adapters' scripts")
	-- no main HUD (a process without a game UI): the drops run, nothing is rebuilt
	trace = {}
	ui.main = nil
	M.fire("on_screen_resolution_changed")
	check(trace[1] == "zz.drop" and #trace == 1, set .. ": without a main HUD only the drops run")
end

-------------------------------------------------------------------------------
-- contract: what the adapters rely on is still in the real files
-------------------------------------------------------------------------------
local function has(src, line) return src ~= nil and HUD.flat(src):find(HUD.flat(line), 1, true) ~= nil end

local function fields_made(src, from, to, pattern)
	local out, seen = {}, {}
	local lines, on = {}, false
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		if line:find(from, 1, true) then on = true end
		if on then lines[#lines + 1] = line end
		if on and to and line:find(to, 1, true) then break end
	end
	local text = table.concat(lines, "\n")
	for f in text:gmatch(pattern) do
		if not seen[f] then
			seen[f] = true
			out[#out + 1] = f
		end
	end
	table.sort(out)
	return out
end

local function same_set(a, b)
	local sa, sb = {}, {}
	for _, x in ipairs(a or {}) do sa[x] = true end
	for _, x in ipairs(b or {}) do sb[x] = true end
	for x in pairs(sa) do if not sb[x] then return false, "not in the adapter: " .. x end end
	for x in pairs(sb) do if not sa[x] then return false, "not in the addon: " .. x end end
	return true
end

local function contract()
	reset_world()
	local M = machine("single", 0, {})
	HUD.install(M.env)
	M.env.coop_mode = load_script(M, "coop_mode")
	M.env.coop_mods_core = load_script(M, "coop_mods_core")
	local life = load_script(M, "coop_hud_lifecycle")
	local c = life._contract()
	local d, h, t, p, e, s = REAL.dotmarks, REAL.hooks, REAL.timed, REAL.progress, REAL.effects, REAL.sr_timer
	local WIN = "self%.([%w_]+)%s*=%s*[%w_%.]*xml:Init"
	local function cmp(label, made, list)
		local ok, why = same_set(made, list)
		check(ok, "contract: " .. label .. " window fields are the adapter's list" .. (why and (" (" .. why .. ")") or ""))
	end
	-- Dot Marks
	for _, line in ipairs({
		"local maingameui        = nil",
		"function actor_on_first_update()\n\thmm = utils_catspaw_hudmarks and utils_catspaw_hudmarks.get_hud_mark_manager()\n\tmaingameui = ActorMenu.get_maingame()",
		"if cfg.main_ui_drawn and cfg.hide_van_interact_ui then\n\t\tmaingameui.UIStaticQuickHelp:Show(false)",
		"self.uid    = \"dotmarks_\" .. (args.id or \"no_id\")",
		"self.anchor \t= self.args.fixed and maingameui or anchor or maingameui",
		"args.fixed  \t= ((args.fixed ~= nil) and args.fixed) or cfg.fixed_screen_pos",
		"self.wnd            = self.xml:InitStatic(\"alt_interact\", self.anchor)",
		"function InteractPrompt:on_option_change()\n\tif self.args.tutorial and self.init_done then\n\t\tself:Destroy()",
		"self:BuildUI()\n\tself.bind_sh:Show((not self.dark_text) and (not cfg.hide_drop_shadow))",
		"self.init_done = self.init_done or time_global()",
		"if self.itemcard then self.itemcard:Show(false) end",
		"mark.use_pri \t= InteractPrompt(args.anchor or mark.marker or maingameui, args)",
		"mark.alt_interact = InteractPrompt(args.anchor or mark.marker or maingameui, args)",
		"cfg.markers[tutorial]   = setup_pri_interact_prompt(maingameui, args)",
		"function InteractPrompt:ShowPrompt(tf, reason)",
		"function check_for_main_ui()\n\tif not maingameui then\n\t\tmaingameui = ActorMenu.get_maingame()\n\tend",
		"cfg.main_ui_drawn = not not (maingameui and maingameui.UIStaticQuickHelp and maingameui.UIStaticQuickHelp.Show)",
		"cfg.main_ui_drawn = not not maingameui\n\tif not cfg.main_ui_drawn then\n\t\tRegisterScriptCallback(\"actor_on_update\", check_for_main_ui)\n\tend\n\tvalidate_object_tables()",
	}) do check(has(d, line), "contract: ui_hud_dotmarks has: " .. HUD.flat(line):sub(1, 90)) end
	local dm = fields_made(d, "class \"InteractPrompt\" (CUIScriptWnd)", "function init_target_metadata(",
		"self%.([%w_]+)%s*=%s*[%w_%.]*xml:Init")
	for _, f in ipairs(fields_made(d, "class \"InteractPrompt\" (CUIScriptWnd)", "function init_target_metadata(",
		"self%.([%w_]+)%[[^%]]*%]%s*=%s*[%w_%.]*xml:Init")) do dm[#dm + 1] = f end
	dm[#dm + 1] = "longpress" -- self.longpress = ui_circular_progress.init_new_indicator (2219)
	check(has(d, "self.longpress = ui_circular_progress.init_new_indicator({"), "contract: ui_hud_dotmarks makes its long press indicator")
	check(has(d, "if mark.alt_interact then\n\t\tmark.alt_interact:Destroy(\"NPC is no longer wounded\")\n\tend")
		and has(d, "mark.alt_interact:ShowPrompt(show_sec or sec_forced)"),
		"contract: a mark keeps its destroyed alt_interact and hides it on its update")
	check(has(d, "func_on_update = main_marker_update_loop,") and has(d, "mark.use_pri:ShowPrompt(mark.show_pri)"),
		"contract: a marker's update is Dot Marks' loop, which shows or hides the mark's prompts")
	-- the stock entry the engine calls after a rebuild, and the marker update its DestroyAll_UI reaches
	local g = REAL.g
	check(has(g, "function CHUDManager_OnScreenResolutionChanged()\n\tDestroyAll_UI()\n\tSendScriptCallback(\"on_screen_resolution_changed\")"),
		"contract: _g.script's CHUDManager_OnScreenResolutionChanged runs DestroyAll_UI before the event")
	check(has(g, "function DestroyAll_UI()\n\thide_hud_all()") and has(g, "_G[path][ui]:Close()")
		and has(g, "SendScriptCallback(\"GUI_on_hide\", name, path)"), "contract: DestroyAll_UI closes the open script GUIs (GUI_on_hide)")
	local hm = REAL.hudmarks
	check(has(hm, "RegisterScriptCallback(\"GUI_on_hide\", self)") and has(hm, "function UIHUDMarker:GUI_on_hide() self:Update() end")
		and has(hm, "self.func_on_update(self, args)"), "contract: a Catspaw HUD marker runs its func_on_update on GUI_on_hide")
	cmp("InteractPrompt", dm, c.dotmarks)
	-- modxml_tutorial_hooks
	check(has(h, "UIStaticTutorials \t\t= nil"), "contract: modxml_tutorial_hooks keeps UIStaticTutorials as a module global")
	check(has(h, "UIStaticTutorials \t= xml:InitTextWnd(static_xmlnode, maingameui)"), "contract: its window is made under the main HUD")
	-- ui_circular_progress
	check(has(p, "function actor_on_first_update()\n\tmaingameui = ActorMenu.get_maingame()"), "contract: ui_circular_progress takes its default anchor at its first update")
	check(has(p, "anchor = anchor or maingameui"), "contract: ui_circular_progress anchors to it by default")
	cmp("UICircularProgress", fields_made(p, "function UICircularProgress:InitIndicator()", "function UICircularProgress:SetSize(", WIN), c.indicator)
	-- ui_timed_prompt
	check(has(t, "return UITimedPrompt(ActorMenu.get_maingame(), args)"), "contract: ui_timed_prompt makes its prompts under the main HUD")
	check(has(t, "local active_anims \t\t= {}"), "contract: ui_timed_prompt keeps its slides in the file local active_anims")
	check(has(t, "local anim = active_anims[wnd_id][anim_type]\n\t\t\t\tif anim and anim.active then"), "contract: a slide stops when its record is inactive")
	check(has(t, "wnds[self.uid] = self.wnd"), "contract: ui_timed_prompt lists its windows in wnds")
	check(has(t, "local start_time= time_global()") and has(t, "start_time  = start_time,")
		and has(t, "CreateTimeEvent(\"animate_\" .. anim_type .. \"_\" .. wnd_id, time_global(), 0,"),
		"contract: a slide's time event is \"animate_<type>_<uid>\" with its record's start_time as the action id")
	check(has(t, "if not self.timer_set then"), "contract: SetTimer makes the indicator only when no timer is set")
	check(has(t, "function update_unsquish_ratio()"), "contract: ui_timed_prompt has update_unsquish_ratio")
	cmp("UITimedPrompt", fields_made(t, "function UITimedPrompt:BuildUI(anchor)", "function UITimedPrompt:SetTimer(", WIN), c.timed)
	local key = fields_made(t, "class \"UIKeyPrompt\" (CUIScriptWnd)", "function get_icon_for_dik(", WIN)
	cmp("UIKeyPrompt", key, c.key)
	-- actor_effects
	check(has(e, "local fogs\n"), "contract: actor_effects keeps the fog windows in the file local fogs")
	check(has(e, "local static = \"hud_blur\" .. i .. \"_\" .. ii"), "contract: the fog statics are named hud_blur<i>_<ii>")
	check(has(e, "pht[ii] = hud:GetCustomStatic(static):wnd()"), "contract: the fog windows are CustomStatics")
	-- sr_timer
	check(has(s, "hud:AddCustomStatic(st.timer_id, true)\n\tst.timer = hud:GetCustomStatic(st.timer_id):wnd()"), "contract: sr_timer keeps its timer static window in st.timer")
	check(has(s, "hud:AddCustomStatic(\"hud_timer_text\", true)"), "contract: sr_timer's title static")
	check(has(s, "self.st.timer:TextControl():SetTextST(str)"), "contract: sr_timer writes the time into st.timer each update")
end

-------------------------------------------------------------------------------
local ORDER = { "tutorial", "progress", "timed", "dotmarks", "fogs", "sr_timer", "dotmarks_destroyed", "gui_open",
	"timed_slide" }

local function judge(name, set, r)
	local p = set .. ": " .. name .. ": "
	if name == "tutorial" then
		check(r.ok, p .. "a prompt after the HUD rebuild uses no freed window")
		check(r.on_new, p .. "UIStaticTutorials is a window of the new main HUD")
	elseif name == "progress" then
		check(r.ok, p .. "an indicator with the default anchor after the rebuild uses no freed window")
		check(r.on_new, p .. "the default anchor is the new main HUD")
	elseif name == "timed" then
		check(r.ok, p .. "the timer ring, both slides and the key after the rebuild use no freed window")
		check(r.on_new and r.timer_on_new, p .. "the waiting offer and its ring are windows of the new main HUD")
		check(r.ring_ok, p .. "the ring goes on where it was (" .. tostring(r.ring) .. ")")
		check(r.timeout_kept, p .. "the offer keeps its timeout")
		check(r.closing_gone, p .. "the offer that was closing is left without windows (its own end finds none to slide)")
		check(r.wnds, p .. "ui_timed_prompt.wnds names the new window")
		check(r.old_key_off, p .. "the old key prompts no longer listen")
		check(r.executed, p .. "the view key still runs the offer's action")
	elseif name == "dotmarks" then
		check(r.ok, p .. "its update, the quick help, prompts and the long press after the rebuild use no freed window")
		check(r.marker_kept, p .. "a prompt on its marker's window keeps its windows")
		check(r.fixed_new and r.card_new, p .. "a fixed prompt and its item card are built again on the new main HUD")
		check(r.long_new, p .. "a fixed long-press prompt gets a new indicator under its new key box")
		check(r.tutorial_new, p .. "the tutorial prompt stays the same prompt, built again on the new main HUD")
		check(r.shown, p .. "shown prompts stay shown, a hidden one stays hidden")
		check(r.drawn, p .. "the main HUD counts as drawn again")
		check(r.records, p .. "the record of a container that went offline stays (no validate_object_tables)")
	elseif name == "dotmarks_destroyed" then
		check(r.ok, p .. "a destroyed fixed prompt its mark still holds uses no freed window when the mark hides it ("
			.. tostring(r.freed) .. ")")
		check(r.same, p .. "it stays the same destroyed prompt")
		check(r.hidden, p .. "its windows are on the new main HUD and hidden, as Destroy left the old ones")
		check(r.quiet, p .. "it does not listen to updates again")
	elseif name == "gui_open" then
		check(r.ok, p .. "a script GUI open at the rebuild: its GUI_on_hide (before the event) uses no freed window ("
			.. tostring(r.freed) .. ")")
		check(r.on_new, p .. "the fixed prompt is shown on the new main HUD")
		check(r.once, p .. "the adapters run once per rebuild")
	elseif name == "timed_slide" then
		check(r.ok, p .. "an offer closed right after a rebuild during its slide-in moves no freed window ("
			.. tostring(r.freed) .. ")")
		check(r.executed, p .. "the view key still runs the offer's action")
	elseif name == "fogs" then
		check(r.ok, p .. "the breath fog after the rebuild uses no freed window")
		check(r.fresh, p .. "all 40 fog windows are CustomStatics made for the new size")
		check(r.single, p .. "no fog static is left twice")
	elseif name == "sr_timer" then
		check(r.ok, p .. "the timer update after the rebuild uses no freed window")
		check(r.fresh, p .. "the time goes into a hud_timer made for the new size")
		check(r.single, p .. "one hud_timer and one title static")
		check(r.title, p .. "the title static is made again with its text")
	end
end

local function control(name, set, r)
	local p = set .. ": control without the registry: " .. name .. ": "
	if name == "fogs" then
		check(r.ok and not r.fresh, p .. "the fog windows keep the old size's statics (the fake keeps CustomStatics)")
	elseif name == "sr_timer" then
		check(r.ok and not r.fresh, p .. "st.timer keeps the old size's static")
	else
		check(not r.ok, p .. "the old window is used (the fake frees what the engine frees)")
	end
end

contract()
for _, set in ipairs(modes.names()) do
	registry_rules(set)
	for _, name in ipairs(ORDER) do
		control(name, set, S[name](set, false))
		judge(name, set, S[name](set, true))
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
