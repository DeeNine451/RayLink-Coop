-- Items a client puts into the world: the backpack stash, the campfire, the deployable gun (coop_mods_items). The real item_backpack and
-- campfire_placeable of GAMMA, the real functions of ui_hud_dotmarks and itms_manager, on the answers a client's engine gives: a world
-- spawn without a parent is nil (alife_simulator_script.cpp), the rest asks the authority of the level.
-- Run: tools\test_lua.cmd mods_deploy
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")
print("== deploy (client)")
local BS = string.char(92)
if not have_file(GAMMA_DIR .. BS .. "item_backpack.script") then
	print("-- skipped: no GAMMA scripts")
	done("DEPLOY CLIENT")
	return
end

local actor = make_actor(vec3(20, 0, 0))
local GO = getmetatable(actor).__index
function GO:character_name() return "joiner" end
function GO:item_in_slot(n) return self._slots and self._slots[n] end
function GO:is_on_belt() return false end

-- the engine of a client
REFUSED = {}
local stub_create = alife_create
function alife_create(sec, pos, lv, gv, parent)
	if parent == nil then
		REFUSED[#REFUSED + 1] = sec
		return nil
	end
	return stub_create(sec, pos, lv, gv, parent)
end

-- stand-ins of the game
SPOTS, SPOTS_GONE = {}, {}
level.map_add_object_spot_ser = function(id, spot, text) SPOTS[#SPOTS + 1] = { id = id, spot = spot, text = text } end
level.map_remove_object_spot = function(id, spot) SPOTS_GONE[#SPOTS_GONE + 1] = { id = id, spot = spot } end
level.add_pp_effector = function(name) FADED = name end
level.change_game_time = function(d, h, m) TIME_ASKED = m end
level.vertex_id = function() return 7 end
function hide_hud_inventory() INV_HIDDEN = (INV_HIDDEN or 0) + 1 end
news_manager.send_tip = function(_, text) TIP = text end
function device() return { cam_pos = vec3(20, 2, 0), cam_dir = { mul = function(self) return vec3(0, 0, 3) end } } end
vector_add = nil
getmetatable(vector()).__index.add = function(self, o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z return self end
getmetatable(vector()).__index.mul = function(self, k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k return self end
utils_data = { collect_section = function() return { keep_me = true } end }
SCANNED_SLOTS = {}
function CUIScriptWnd() end
utils_item = { get_ammo = function() return {} end }
_G.class = function(name)
	local env = getfenv(2)
	env[name] = {}
	return function() end
end

local function real_script(name)
	local path = GAMMA_DIR .. BS .. name .. ".script"
	local fh = assert(io.open(path, "rb"))
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	assert(loadstring(header .. src, "@" .. path))()
end

for _, name in ipairs({ "actor_on_item_use", "actor_on_item_take_from_box", "actor_on_stash_create", "actor_on_stash_remove", "GUI_on_show",
	"GUI_on_hide" }) do
	AddScriptCallback(name)
end
RegisterScriptCallback("actor_on_stash_create", function(d) STASH_MADE = d end)
RegisterScriptCallback("actor_on_stash_remove", function(d) STASH_GONE = d; d.cancel = STASH_KEEP end)

real_script("item_backpack")
campfire_placeable_mcm = { get_config = function() return false end }
ui_inventory = { UIInventory = { Name_Custom = function() end, Action_Custom = function() end } }
trader_autoinject = { update = function() end }
real_script("campfire_placeable")
campfire_placeable.is_flat_surface = function() return FLAT end
ui_hud_dotmarks = { get_game_object = function(id) return OBJ[id] end, gts = function(s) return s end }
assert(mod_chunk(GAMMA_DIR .. BS .. "ui_hud_dotmarks.script", { "function deploy_backpack(id)", "function remove_placed_backpack(id, mapspot)" },
	"ui_hud_dotmarks", "return true"))
itms_manager = {}
assert(mod_chunk(GAMMA_DIR .. BS .. "itms_manager.script", { "function use_deployable_mgun(obj)" }, "itms_manager", "return true"))

-- campfire_placeable comes before coop_mods_* in the file list, item_backpack after
campfire_placeable.on_game_start()
local stock_use = campfire_placeable.actor_on_item_use
start_all()
item_backpack.on_game_start()
local C = coop_mods_core
local function from_host(name, t) coop_main.on_event("mods." .. name, coop_main.encode(t), 0) end
local function m_data() return alife_storage_manager.get_state() end
local function book() return m_data().player_created_stashes end

INI.itm_backpack = { class = "EQ_BAKPK", kind = "i_backpack" }
INI.itm_actor_backpack = {}
INI.st_junk, INI.keep_me = {}, {}
INI.st_med = { kind = "i_medical" }
INI.st_quest = { quest_item = true }

print("-- the stash window")
local _, pack = spawn("itm_backpack", vec3(20, 0, 0), 0)
local closed = 0
local function dialog(text)
	return { id = pack:id(), section = "itm_backpack", input = { GetText = function() return text end }, Close = function() closed = closed + 1 end }
end
SENT = {}
item_backpack.UICreateStash.OnAccept(dialog("my stash"))
local q, raw = sent("mods.stash_make")
check(q ~= nil and raw.target == 0 and q.i == pack:id() and q.t == "my stash" and q.p == "treasure_player", "OK in the window asks the authority")
check(closed == 1, "the window closes")
check(SE[pack:id()] ~= nil, "the backpack stays until the authority spends it")
check(#REFUSED == 0, "no world spawn is tried")
check(#SPOTS == 0 and book() == nil, "nothing is told before the answer")
SENT = {}
item_backpack.UICreateStash.OnAccept(dialog(""))
q = sent("mods.stash_make")
check(q ~= nil and q.t == "st_itm_stash_of_character", "an empty name: the stock's")

print("-- the answer of the authority")
HUD = nil
from_host("stash_made", { b = 7001, s = "itm_backpack", p = "treasure_player", t = "my stash" })
check(#SPOTS == 0, "the box is not here yet: nothing to show")
local _, box = spawn("inv_backpack", vec3(20, 0, 1), nil, { id = 7001 })
box._kind = "box"
run_time_events(100)
check(#SPOTS == 1 and SPOTS[1].id == 7001 and SPOTS[1].spot == "treasure_player" and SPOTS[1].text == "my stash", "the spot on the map")
check(book() and book()[7001] == "itm_backpack", "the local copy knows the stash")
check(HUD == "st_stash_created", "the player is told")
check(STASH_MADE and STASH_MADE.stash_id == 7001 and STASH_MADE.stash_name == "my stash" and STASH_MADE.stash_section == "itm_backpack",
	"actor_on_stash_create: fast travel's hint and the waypoints get it as in the stock")

print("-- the backpack in the slot: the bag goes into the stash")
local _, pack2 = spawn("itm_backpack", vec3(20, 0, 0), 0)
local _, tool = spawn("itm_actor_backpack", vec3(20, 0, 0), 0)
SENT = {}
SendScriptCallback("actor_on_item_use", tool)
check(sent("mods.stash_make") == nil, "without a backpack in the slot nothing is asked")
check(HUD == "st_stash_no_backpack_found", "the stock's word")
actor._slots = { [13] = pack2 }
SendScriptCallback("actor_on_item_use", tool)
q = sent("mods.stash_make")
check(q ~= nil and q.i == pack2:id() and q.f == true, "the backpack of the slot, for the whole bag")
check(SE[pack2:id()] ~= nil and #REFUSED == 0, "nothing is spent or spawned here")
local _, junk = spawn("st_junk", vec3(20, 0, 0), 0)
local _, kept = spawn("keep_me", vec3(20, 0, 0), 0)
local _, med = spawn("st_med", vec3(20, 0, 0), 0)
local _, quest = spawn("st_quest", vec3(20, 0, 0), 0)
local _, box2 = spawn("inv_backpack", vec3(20, 0, 1), nil, { id = 7002 })
box2._kind = "box"
from_host("stash_made", { b = 7002, i = pack2:id(), s = "itm_backpack", p = "treasure_player", t = "x", f = true })
run_time_events(100)
check(SE[junk:id()].parent_id == 7002, "the bag goes into the stash when its id came")
check(SE[pack2:id()].parent_id == 0, "not the backpack: the authority spent it")
check(SE[kept:id()].parent_id == 0 and SE[med:id()].parent_id == 0 and SE[quest:id()].parent_id == 0, "what the stock keeps stays")

print("-- a stash emptied")
spawn("st_junk", vec3(20, 0, 1), 7001)
local inside = next(SE)
for id, se in pairs(SE) do if se.parent_id == 7001 then inside = id end end
SENT, CREATED = {}, {}
SendScriptCallback("actor_on_item_take_from_box", box, OBJ[inside])
run_time_events(300)
check(sent("mods.stash_free") == nil, "something is left: nothing happens")
release_id(inside)
HUD, STASH_GONE, INV_HIDDEN = nil, nil, 0
SendScriptCallback("actor_on_item_take_from_box", box, nil)
run_time_events(300)
q = sent("mods.stash_free")
check(q ~= nil and q.b == 7001, "the last item taken: the authority is asked")
check(#CREATED == 0, "no free backpack here: a client's copy of the book gave one, the box stayed")
check(SE[7001] ~= nil, "the box stays until the authority frees it")
check(INV_HIDDEN == 1 and STASH_GONE and STASH_GONE.stash_id == 7001, "the window closes, actor_on_stash_remove as in the stock")
check(SPOTS_GONE[#SPOTS_GONE].id == 7001 and SPOTS_GONE[#SPOTS_GONE].spot == "treasure_player", "its spot goes")
SENT = {}
book()[7002] = "itm_backpack"
for id, se in pairs(SE) do if se.parent_id == 7002 then se.parent_id = 0 end end
STASH_KEEP = true
SendScriptCallback("actor_on_item_take_from_box", box2, nil)
run_time_events(300)
check(sent("mods.stash_free") == nil, "a mod that cancels keeps the stash (Soulslike)")
STASH_KEEP = false

print("-- the stock's own bag of a dead player is no stash of the book")
local _, bag = spawn("inv_backpack", vec3(20, 0, 2), nil, { id = 7003 })
bag._kind = "box"
SENT = {}
SendScriptCallback("actor_on_item_take_from_box", bag, nil)
run_time_events(300)
check(sent("mods.stash_free") == nil, "the engine frees it")

print("-- dotmarks: a backpack on the ground, a stash picked up")
local _, ground = spawn("itm_backpack", vec3(20, 0, 3))
SENT, REFUSED = {}, {}
ui_hud_dotmarks.deploy_backpack(ground:id())
q = sent("mods.stash_make")
check(q ~= nil and q.i == ground:id() and q.p == "treasure" and q.t == "st_itm_stash_of_character", "deployed: the authority is asked")
check(#REFUSED == 0 and SE[ground:id()] ~= nil, "the backpack lies there until it is spent")
SENT, CREATED = {}, {}
book()[7002] = "itm_backpack"
local _, left = spawn("st_junk", vec3(20, 0, 1), 7002) -- take_all_from_box asked for it, the answer is on its way
check(ui_hud_dotmarks.remove_placed_backpack(7002) == true, "picked up")
run_time_events(300)
check(sent("mods.stash_free") == nil and SE[7002] ~= nil, "the box waits for what is on its way")
release_id(left:id())
run_time_events(300)
check(sent("mods.stash_free") ~= nil and #CREATED == 0, "then the authority frees it, nothing is made here")

print("-- a campfire from the inventory")
local _, fire = spawn("itm_campfire", vec3(20, 0, 0), 0)
FLAT, FADED, TIP, TIME_ASKED = false, nil, nil, nil
SENT, REFUSED = {}, {}
SendScriptCallback("actor_on_item_use", fire)
run_time_events(3000)
check(TIP == "st_bad_surface" and sent("mods.cf_place") == nil, "bad ground: the stock's tip, nothing asked")
FLAT = true
SendScriptCallback("actor_on_item_use", fire)
check(FADED == "fade_nine_sec.ppe" and TIME_ASKED ~= nil, "the player sees the stock's fade, the time is asked for")
check(sent("mods.cf_place") == nil, "the request waits for the fade, as the stock's place")
run_time_events(3000)
q, raw = sent("mods.cf_place")
check(q ~= nil and raw.target == 0 and q.i == fire:id(), "then the authority is asked for the item")
check(sent_count("mods.cf_place") == 1, "once")
check(SE[fire:id()] ~= nil, "the item stays until the campfire stands: a refusal loses nothing")
check(#REFUSED == 0, "no world spawn is tried")
check(not axr_main.has("actor_on_item_use", stock_use), "the stock's handler left the list: it spends the item")

print("-- the deployable gun: GAMMA has no such object")
local _, gun = spawn("itm_deployable_mgun", vec3(20, 0, 0), 0)
INI.itm_deployable_mgun = {}
SENT, CREATED, HUD = {}, {}, nil
release_id(gun:id()) -- the engine ate it before the callback
itms_manager.use_deployable_mgun({ section = function() return "itm_deployable_mgun" end })
check(#CREATED == 1 and CREATED[1].sec == "itm_deployable_mgun" and CREATED[1].parent == 0, "the item comes back")
check(HUD ~= nil, "the player is told")
check(#REFUSED == 0, "no world spawn is tried")

print("-- the search window: a Lua dialog, the engine hears of it from here")
WINDOW = {}
coop.search_window = function(id) WINDOW[#WINDOW + 1] = id or "none" end
ui_inventory.GUI = { mode = "loot", npc_id = 7003 }
SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
check(#WINDOW == 1 and WINDOW[1] == 7003, "a search is told, what it searches")
SendScriptCallback("GUI_on_hide", "UIInventory", "ui_inventory")
check(#WINDOW == 2 and WINDOW[2] == "none", "its close too")
WINDOW = {}
ui_inventory.GUI = { mode = "inventory" }
SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
check(#WINDOW == 0, "the player's own inventory is not a search")
ui_inventory.GUI = { mode = "loot", npc_id = 7003 }
SendScriptCallback("GUI_on_show", "UIPda", "pda")
SendScriptCallback("GUI_on_hide", "UIPda", "pda")
check(#WINDOW == 0, "nor another window")
coop.search_window = nil
SendScriptCallback("GUI_on_show", "UIInventory", "ui_inventory")
check(true, "an exe without it goes on")

done("DEPLOY CLIENT")
