-- Anomaly Coop Lua tests: a fake of the game UI that frees what the engine frees on a HUD rebuild (TZ Р38). Not shipped.
--
--   local HUD = dofile("tests/lua/support/hud_fake.lua")
--   local ui = HUD.install(E)    E: a machine environment (tests/lua/support/harness_npc.lua). Adds ActorMenu, get_hud,
--                                CScriptXmlInit, CUIScriptWnd, class, super, vector2, Frect, GetARGB, the fonts, device,
--                                CreateTimeEvent / RemoveTimeEvent (the stock queue: an id that is queued is not replaced,
--                                _g.script:339-352), Register/Unregister/SendScriptCallback (axr_main: a function, or an
--                                object whose method of the callback's name is called)
--   ui.rebuild(w, h)             CHUDManager::OnScreenResolutionChanged without the callback (engine HUDManager.cpp:
--                                664-691): UnLoad deletes the main HUD, the PDA, the actor menu and get_hud():GetWindow()
--                                with every window under them (UIGameCustom.cpp:277-283), Load makes new ones and a new
--                                MsgConfig (ui.gen + 1). CustomStatics and dialogs to render are not deleted: a CustomStatic
--                                keeps the layout (gen) of the MsgConfig it was made from.
--   ui.pump(ms)                  moves NOW in 50 ms steps and runs the time events that are due
--   ui.freed                     every use of a freed window, "<window>.<method>"; each use also raises (the game's AV)
--   ui.main_obj()                the C++ object of the current main HUD; HUD.obj_of(x) the object of a handle or a window
--   HUD.under(o, root)           o is root or a window under it
-- A handle is what luabind gives Lua for a C++ object: a new one on every push, its Lua fields kept per handle
-- (luabind class_rep::settable, the object's own Lua table). A method or a property of a freed object raises. A Lua class
-- instance (class "X" (CUIScriptWnd)) is a window of its own, never under the HUD.
local HUD = {}
local OBJ = {} -- key of the C++ object in a handle or a Lua class instance

local function obj_of(x)
	if type(x) ~= "table" then return nil end
	return rawget(x, OBJ)
end
HUD.obj_of = obj_of

function HUD.under(o, root)
	while o do
		if o == root then return true end
		o = o.parent
	end
	return false
end

function HUD.install(E)
	local ui = { gen = 1, freed = {}, statics = {}, dialogs = {}, events = {}, width = 1920, height = 1080 }
	local seq = 0

	local function new_obj(kind, name, parent)
		seq = seq + 1
		local o = { kind = kind, name = name or kind, alive = true, kids = {}, parent = parent, shown = true,
			gen = ui.gen, id = seq, text = "", x = 0, y = 0, w = 0, h = 0 }
		if parent then parent.kids[#parent.kids + 1] = o end
		return o
	end
	ui.new_obj = new_obj

	local function kill(o)
		o.alive = false
		for _, k in ipairs(o.kids) do kill(k) end
	end

	local function freed(o, what)
		local line = tostring(o.name) .. "." .. what
		ui.freed[#ui.freed + 1] = line
		error("freed window used: " .. line, 3)
	end

	local function vector2()
		return setmetatable({ x = 0, y = 0 }, { __index = { set = function(self, x, y)
			if type(x) == "table" then self.x, self.y = x.x, x.y else self.x, self.y = x or 0, y or 0 end
			return self
		end } })
	end
	E.vector2 = vector2
	E.Frect = function()
		return setmetatable({}, { __index = { set = function(self, x1, y1, x2, y2)
			self.x1, self.y1, self.x2, self.y2 = x1, y1, x2, y2
			return self
		end } })
	end
	E.GetARGB = function(a, r, g, b) return (a or 0) * 16777216 + (r or 0) * 65536 + (g or 0) * 256 + (b or 0) end
	for _, f in ipairs({ "GetFontGraffiti22Russian", "GetFontGraffiti32Russian", "GetFontLetterica16Russian",
		"GetFontLetterica18Russian", "GetFontSmall", "GetFontMedium" }) do
		E[f] = function() return f end
	end
	E.device = function() return { width = ui.width, height = ui.height, precache_frame = 0 } end
	E.time_continual = function() return NOW end

	local handle
	-- the methods of a window (CUIStatic, CUITextWnd, CUIProgressBar, ...): fn(o, ...)
	local WND = {}
	function WND.Show(o, v) o.shown = v and true or false end
	function WND.IsShown(o) return o.shown end
	function WND.Enable(o, v) o.enabled = v end
	function WND.SetWndPos(o, p) o.x, o.y = p and p.x or 0, p and p.y or 0 end
	function WND.GetWndPos(o) return vector2():set(o.x, o.y) end
	function WND.SetWndSize(o, s) o.w, o.h = s and s.x or 0, s and s.y or 0 end
	function WND.GetWndSize(o) return vector2():set(o.w, o.h) end
	function WND.SetWndRect(o, r) o.rect = r end
	function WND.SetTextureRect(o, r) o.texture_rect = r end
	function WND.GetWidth(o) return o.w end
	function WND.GetHeight(o) return o.h end
	function WND.SetWidth(o, w) o.w = w end
	function WND.SetHeight(o, h) o.h = h end
	function WND.InitTexture(o, t) o.texture = t end
	function WND.SetTextureColor(o, c) o.color = c end
	function WND.GetTextureColor(o) return o.color or 0 end
	function WND.EnableHeading(o, v) o.heading_on = v end
	function WND.SetHeading(o, v) o.heading = v end
	function WND.SetProgressPos(o, v) o.progress = v end
	function WND.SetText(o, t) o.text = t end
	function WND.SetTextST(o, t) o.text = t end
	function WND.GetText(o) return o.text end
	function WND.SetFont(o, f) o.font = f end
	function WND.SetTextColor(o, c) o.text_color = c end
	function WND.SetTextComplexMode(o, v) o.complex = v end
	function WND.AdjustWidthToText(o) o.w = #tostring(o.text or "") * 8 end
	function WND.AdjustHeightToText(o) o.h = 16 end
	function WND.SetAutoDelete(o, v) o.auto_delete = v end
	function WND.Update(o) o.updates = (o.updates or 0) + 1 end
	function WND.SetWindowName(o, n) o.window_name = n end
	function WND.GetWindowName(o) return o.window_name end
	function WND.ShowDialog(o) o.shown = true end
	function WND.HideDialog(o) o.shown = false end
	function WND.TextControl(o) return handle(o) end

	-- the game UI (CUIGameCustom): never deleted while the level lives
	local GAME = {}
	local function find_static(id)
		for i, w in ipairs(ui.statics) do
			if w.name == id then return w, i end
		end
	end
	function GAME.AddCustomStatic(_, id, single)
		if single then
			local w = find_static(id)
			if w then return handle(w) end
		end
		-- the static is built from the MsgConfig of now (UIGameCustom.cpp:121-140)
		local w = { kind = "StaticDrawableWrapper", name = id, alive = true, kids = {}, static = new_obj("CUIStatic", id) }
		ui.statics[#ui.statics + 1] = w
		return handle(w)
	end
	function GAME.GetCustomStatic(_, id)
		local w = find_static(id)
		return w and handle(w) or nil
	end
	function GAME.RemoveCustomStatic(_, id)
		local w, i = find_static(id)
		if not w then return end
		w.alive = false
		kill(w.static)
		table.remove(ui.statics, i)
	end
	function GAME.AddDialogToRender(_, d) ui.dialogs[d] = true end
	function GAME.RemoveDialogToRender(_, d) ui.dialogs[d] = nil end
	function GAME.GetWindow() return handle(ui.window) end
	local WRAPPER = {}
	function WRAPPER.wnd(w) return handle(w.static) end

	local KINDS = { CUIGameCustom = GAME, StaticDrawableWrapper = WRAPPER }
	local HANDLE_MT = {
		__index = function(t, k)
			local o = rawget(t, OBJ)
			local methods = KINDS[o.kind] or WND
			local m = methods[k]
			if m then
				return function(_, ...)
					if not o.alive then freed(o, k) end
					return m(o, ...)
				end
			end
			local p = o.props and o.props[k]
			if p ~= nil then
				if not o.alive then freed(o, k) end -- a property getter reads the object
				return handle(p)
			end
			return nil
		end,
	}
	handle = function(o) return setmetatable({ [OBJ] = o }, HANDLE_MT) end
	ui.handle = handle

	local function parent_of(x, what)
		local o = obj_of(x)
		if not o then error("CScriptXmlInit:" .. what .. ": no parent window", 3) end
		if not o.alive then freed(o, "AttachChild") end
		return o
	end
	E.CScriptXmlInit = function()
		local xml = {}
		function xml:ParseFile(path) self.file = path end
		for _, what in ipairs({ "InitStatic", "InitTextWnd", "InitProgressBar", "InitFrame", "InitCheck", "InitLabel" }) do
			xml[what] = function(_, node, parent)
				return handle(new_obj(what, node, parent_of(parent, what)))
			end
		end
		return xml
	end

	-- a window class of a script (CUIScriptWnd): window methods on its own object
	local SCRIPT_WND = {}
	for name, m in pairs(WND) do
		SCRIPT_WND[name] = function(self, ...)
			local o = rawget(self, OBJ)
			if not o.alive then freed(o, name) end
			return m(o, ...)
		end
	end
	SCRIPT_WND.__window = true
	E.CUIScriptWnd = SCRIPT_WND
	E.super = function() end
	-- luabind `class "Name" (Base)` / `class "Name"`: the class goes into the calling script's environment at once
	E.class = function(name)
		local env = getfenv(2)
		local cls = {}
		cls.__index = cls
		local meta = {}
		meta.__call = function(c, ...)
			local o = setmetatable({}, c)
			if c.__window then rawset(o, OBJ, new_obj("CUIScriptWnd", name)) end
			if c.__init then c.__init(o, ...) end
			return o
		end
		setmetatable(cls, meta)
		env[name] = cls
		return function(base) meta.__index = base end
	end

	E.get_hud = function() return handle(ui.game) end
	E.ActorMenu = {
		get_maingame = function() return ui.main and handle(ui.main) or nil end,
		get_pda_menu = function() return handle(ui.pda) end,
		get_actor_menu = function() return handle(ui.actor_menu) end,
	}

	local function build()
		ui.main = new_obj("CUIMainIngameWnd", "maingame" .. ui.gen)
		ui.main.props = { UIStaticQuickHelp = new_obj("CUITextWnd", "UIStaticQuickHelp" .. ui.gen, ui.main) }
		ui.window = new_obj("CUIWindow", "Window" .. ui.gen)
		ui.pda = new_obj("CUIPdaWnd", "pda" .. ui.gen)
		ui.actor_menu = new_obj("CUIActorMenu", "actor_menu" .. ui.gen)
	end
	ui.game = new_obj("CUIGameCustom", "game_ui")
	build()

	function ui.rebuild(w, h)
		for _, o in ipairs({ ui.main, ui.window, ui.pda, ui.actor_menu }) do kill(o) end
		ui.gen = ui.gen + 1
		ui.width, ui.height = w or ui.width, h or ui.height
		build()
	end
	function ui.main_obj() return ui.main end
	function ui.static_count(id)
		local n = 0
		for _, w in ipairs(ui.statics) do if w.name == id then n = n + 1 end end
		return n
	end

	-- script callbacks, as axr_main.script keeps them: a function, or an object called as obj[name](obj, ...)
	local callbacks = {}
	E.RegisterScriptCallback = function(name, f)
		local list = callbacks[name] or {}
		callbacks[name] = list
		for _, g in ipairs(list) do if g == f then return end end
		list[#list + 1] = f
	end
	E.UnregisterScriptCallback = function(name, f)
		local list = callbacks[name]
		if not list then return end
		for i = #list, 1, -1 do if list[i] == f then table.remove(list, i) end end
	end
	E.SendScriptCallback = function(name, ...)
		local list = {}
		for i, f in ipairs(callbacks[name] or {}) do list[i] = f end
		for _, f in ipairs(list) do
			if type(f) == "function" then f(...) else f[name](f, ...) end
		end
	end
	E.AddScriptCallback = function() end
	function ui.registered(name, f)
		for _, g in ipairs(callbacks[name] or {}) do if g == f then return true end end
		return false
	end

	-- time events (stock _g.script:339-358)
	local order = {}
	E.CreateTimeEvent = function(ev_id, act_id, timer, f, ...)
		local key = tostring(ev_id) .. "\0" .. tostring(act_id)
		if ui.events[key] then return end
		ui.events[key] = { t = NOW + (timer or 0) * 1000, f = f, p = { ... } }
		order[#order + 1] = key
	end
	E.RemoveTimeEvent = function(ev_id, act_id)
		ui.events[tostring(ev_id) .. "\0" .. tostring(act_id)] = nil
	end
	function ui.run_events()
		local keys = {}
		for i, k in ipairs(order) do keys[i] = k end
		for _, k in ipairs(keys) do
			local ev = ui.events[k]
			if ev and NOW >= ev.t then
				if ev.f(unpack(ev.p)) then ui.events[k] = nil end
			end
		end
		local live = {}
		for _, k in ipairs(order) do if ui.events[k] then live[#live + 1] = k end end
		order = live
	end
	function ui.pump(ms)
		local left = ms or 0
		repeat
			local step = math.min(50, left)
			NOW = NOW + step
			left = left - step
			ui.run_events()
		until left <= 0
	end
	function ui.has_event(ev_id, act_id) return ui.events[tostring(ev_id) .. "\0" .. tostring(act_id)] ~= nil end

	return ui
end

-- Loads a real script file (an addon on the stand) as CScriptStorage does: its module table, __index to the machine.
function HUD.load_file(M, path, name)
	local fh = assert(io.open(path, "rb"), "cannot read " .. path)
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. path))
	setfenv(f, M.env)
	f()
	return M.env[name]
end

-- Loads Lua text as the module `name` of the machine (a model, or a piece of a real file).
function HUD.load_text(M, text, name, chunkname)
	local env = rawget(M.env, name)
	if type(env) ~= "table" then
		env = setmetatable({}, { __index = M.env })
		M.env[name] = env
	end
	local f = assert(loadstring(text, chunkname or ("=" .. name)))
	setfenv(f, env)
	f()
	return env
end

function HUD.read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- The text of a real file from the line that starts with `first` to the first line that is exactly "end" after it.
function HUD.piece(src, first)
	local out, on = {}, false
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		if not on and line:sub(1, #first) == first then on = true end
		if on then
			out[#out + 1] = line
			if #out > 1 and line:match("^end%s*$") then return table.concat(out, "\n") end
		end
	end
	return nil
end

-- The code with white space collapsed (contract checks against a real file).
function HUD.flat(s)
	return (s:gsub("%s+", " "))
end

return HUD
