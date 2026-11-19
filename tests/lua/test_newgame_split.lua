-- Dev 57 co-op entry points: stock new game, build 56 save compatibility, and launcher auto-load.
dofile("tests/lua/support/menu_stubs.lua")

STRINGS = {}
for _, f in ipairs({ "st_coop_menu.xml", "st_coop_newgame.xml", "st_coop_game.xml" }) do
	local fh = assert(io.open(ROOT .. "configs/text/eng/" .. f, "r"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	fh:close()
end
game = { translate_string = function(id) return STRINGS[id] or id end }
local function T(id) return STRINGS[id] or id end

INFO = { phase = "off", active = false, host = false, client = false, players = {}, pending_host = 27961 }
CALLS = {}
coop = {
	is_active = function() return INFO.active end,
	is_host = function() return INFO.host end,
	is_client = function() return INFO.client end,
	session_info = function() return INFO end,
	host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end,
	connect = function(a) CALLS[#CALLS + 1] = "connect " .. a; return true end,
}
local server_starts = 0
coop.world_server = { start = function() server_starts = server_starts + 1; return false end }
function command_line() return "x.exe" end
function get_console_cmd() return nil end
function exec_console_cmd() end
axr_main = { config = config_stub() }
CFG = axr_main.config.data
level = { present = function() return false end }
function RegisterScriptCallback() end

STAGED = {}
coop_game_settings = {
	defaults = function() return { ["c|coop_death_mode"] = "checkpoint" } end,
	stage_new = function(record) STAGED[#STAGED + 1] = record; return true end,
}
load_module("coop_game_schema")
load_module("coop_game_record")
load_module("coop_game_settings_view")

XML_FILES["ui_coop_newgame.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_newgame.xml")
XML_FILES["ui_coop_chronicle.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_chronicle.xml")
XML_FILES["stock.xml"] = setmetatable({}, { __index = function() return true end })
local base_xml = CScriptXmlInit
function CScriptXmlInit()
	local x = base_xml()
	local function init(self, path, parent)
		local wnd = window(path)
		wnd.checked = false
		wnd.items = {}
		function wnd:SetCheck(b) self.checked = b and true or false end
		function wnd:GetCheck() return self.checked end
		function wnd:ClearList() self.items = {} end
		function wnd:AddItem(text, id) self.items[#self.items + 1] = { text = text, id = id } end
		function wnd:CurrentID() return self.cur or -1 end
		return wnd
	end
	for _, n in ipairs({ "InitStatic", "InitTextWnd", "Init3tButton", "InitEditBox", "InitScrollView", "InitCheck", "InitComboBox" }) do
		x[n] = init
	end
	return x
end

-- the stock screen: OnStartGame writes what ui_mm_faction_select.script UINewGame:OnStartGame writes, then owner:StartGame()
class "UINewGame" (CUIScriptWnd)
function UINewGame:__init(owner)
	self.owner = owner
	self.access = true
	self.selected_faction = "bandit"
	self.selected_difficulty, self.selected_economy = "st_diff_2", "st_econ_1"
	self.selected_icon, self.selected_map, self.selected_money = "ui_inGame2_bandit_1", "esc_bandit_start", 1500
	self.kit = { "wpn_pm", "ammo_9x18_fmj", "ammo_9x18_fmj" }
	local xml = CScriptXmlInit()
	xml:ParseFile("stock.xml")
	self.character_name = xml:InitEditBox("input_name", self)
	self.character_name:SetText("Big Boss")
	self.templ_options = xml:InitStatic("templ_options", nil)
	self.ck_story = xml:InitCheck("check_story", self.templ_options)
	self.ck_story:SetCheck(true)
	self.ck_routes = xml:InitCheck("check_routes", self.templ_options)
	self:AddCallback("btn_start", ui_events.BUTTON_CLICKED, self.OnStartGame, self)
end
function UINewGame:OnStartGame()
	if not self.access then return end
	local name = self.character_name:GetText()
	if name == "" then return end
	local c = axr_main.config
	c:w_value("character_creation", "new_game_difficulty", 2)
	c:w_value("character_creation", "new_game_economy", 1)
	c:w_value("character_creation", "new_game_economy_treasure", 1)
	c:w_value("character_creation", "new_game_story_mode", self.ck_story:GetCheck() and true or nil)
	c:w_value("character_creation", "new_game_opened_routes", self.ck_routes:GetCheck() and true or nil)
	c:w_value("character_creation", "new_game_character_name", (name:gsub(" ", "_")))
	c:w_value("character_creation", "new_game_faction", self.selected_faction)
	c:w_value("character_creation", "new_game_icon", self.selected_icon)
	c:w_value("character_creation", "new_game_loadout", #self.kit > 0 and table.concat(self.kit, ",") or nil)
	c:w_value("character_creation", "new_game_map", self.selected_map)
	c:w_value("character_creation", "new_game_money", self.selected_money)
	c:save()
	self.owner:StartGame()
end

local MM = {} -- the class ui_main_menu.main_menu; MENU is its instance
function MM:StartGame() self.starts = self.starts + 1 end
function MM:ShowDialog() self.shown = true end
function MM:HideDialog() self.shown = false end
function MM:Show(b) self.visible = b end
MENU = setmetatable({ starts = 0, shown = false }, { __index = MM })

local m = load_module("coop_newgame_modes")

local function screen()
	local dlg = UINewGame(MENU)
	dlg.shown = true
	m.apply(dlg)
	return dlg
end

local dlg = screen()
check(coop_game_schema.item("c|coop_world_server") == nil, "new co-op games have no server creation switch")
click(dlg, "btn_start")
check(MENU.starts == 1 and #STAGED == 1, "starting from the game stages co-op and calls stock StartGame once")
check(server_starts == 0 and INFO.pending_host == 27961, "stock start keeps the pending co-op host and never starts a server")

MENU.starts, STAGED = 0, {}
dlg = screen()
dlg.character_name:SetText("")
click(dlg, "btn_start")
check(MENU.starts == 0 and #STAGED == 0, "empty character name starts and stages nothing")

local cm = load_module("coop_menu")
local function menu_for(id)
	return setmetatable({
		sel_id = id, PrepareHost = function() return 27961 end,
		Refresh = function(self) self.refreshed = true end, Close = function(self) self.closed = true end,
	}, { __index = cm.UICoopMenu })
end
local legacy = {
	v = 1, id = "65190f3a-9c41", name = "Strelok", faction = "stalker",
	values = { ["c|coop_split_levels"] = "1", ["c|coop_story_together"] = "1", ["c|coop_world_server"] = "0" },
}
local old = assert(coop_game_record.decode("build 56 save block", { decode = function() return legacy end }))
local dedicated = { id = "ded", values = { ["c|coop_world_server"] = "1" } }
local plain = { id = "plain", values = { ["c|coop_split_levels"] = "0" } }
local cards = { [old.id] = old, [dedicated.id] = dedicated, [plain.id] = plain }
coop_game_settings.load_card = function(id) return cards[id] end
coop_game_settings.autosave_game = function(id) CALLS[#CALLS + 1] = "ring " .. tostring(id) end
function exec_console_cmd(cmd) CALLS[#CALLS + 1] = cmd end

check(STRINGS.st_coop_world_err_old_split == nil, "the refusal text for an old hybrid world is gone")
local menu = menu_for(old.id)
CALLS = {}
menu:HostAfter("save", "legacy_b56")
check(menu.closed and menu.local_error == nil and server_starts == 0 and CALLS[1] == "ring " .. old.id and CALLS[2] == "pending 27961"
	and CALLS[4] == "start server(legacy_b56/single/alife/load) client(localhost)",
	"a decoded build 56 hybrid save opens through the co-op host path")

for _, id in ipairs({ plain.id, "no_card" }) do
	menu = menu_for(id)
	CALLS = {}
	menu:HostAfter("save", "normal_save")
	check(menu.closed and menu.local_error == nil and server_starts == 0 and CALLS[1] == "ring " .. id and CALLS[2] == "pending 27961"
		and CALLS[4] == "start server(normal_save/single/alife/load) client(localhost)",
		id .. ": Play opens the save through the normal co-op host path")
end

menu = menu_for(dedicated.id)
CALLS = {}
menu:HostAfter("save", "dedicated_save")
check(menu.local_error == T("st_srv_world_from_launcher") and menu.refreshed and not menu.closed and #CALLS == 0 and server_starts == 0,
	"the world_server flag alone directs Play to the launcher before preparing a host or loading the save")

local stem = "coop_auto_65190f3a-9c41_3"
function command_line() return "x.exe -coop_world_auto " .. stem end
coop_game_settings.game_of_save = function(s) if s == stem then return old.id, old end end
function MM:Update() self.updates = (self.updates or 0) + 1 end
ui_main_menu = { main_menu = MM }
coop_games = { map_texture = function() return nil end }
CALLS = {}
cm.on_main_menu_init(MENU)
check(#CALLS == 0, "launcher auto-load waits until the menu is built")
MENU:Update()
MENU:Update()
check(#CALLS == 4 and CALLS[1] == "ring " .. old.id and CALLS[2] == "pending 27960"
	and CALLS[4] == "start server(" .. stem .. "/single/alife/load) client(localhost)" and MENU.updates == 2,
	"the first menu frame hosts the requested co-op save exactly once")
check(table.concat(LOG, "\n"):find("will host on port 27960 after " .. stem, 1, true) ~= nil,
	"the automatic co-op host logs which save and port it uses")

local function auto_at_start(argument, record)
	function command_line() return "x.exe -coop_world_auto " .. argument end
	coop_game_settings.game_of_save = function() return record.id, record end
	MM.Update = function() end
	CALLS = {}
	load_module("coop_menu").on_main_menu_init(MENU)
	MENU:Update()
	return #CALLS
end
check(auto_at_start("dedicated_save", dedicated) == 0, "auto-load leaves server worlds to the launcher")
check(auto_at_start("new", old) == 0, "the retired automatic new-server command launches nothing")
check(auto_at_start("\209\229\233\226", old) == 4, "a save name in the game's code page can still be hosted")
check(auto_at_start("a)quit(", old) == 0, "only a save stem can enter the co-op load command")

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
