-- The authority of a level for what a client puts into the world (coop_mods_items): the client is not trusted, its item, the distance and
-- the limit are checked here. The world server leading its own level, then a map server (the book and the spot go to the world server).
-- The real campfire_placeable and guaranteed_loot; what a client's window starts when the engine hears of it.
-- Run: tools\test_lua.cmd mods_deploy_host
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")
print("== deploy (authority)")
local BS = string.char(92)
local GAMMA = have_file(GAMMA_DIR .. BS .. "campfire_placeable.script")

make_actor(vec3(0, 0, 0))
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local _, other = spawn("coop_player_avatar", vec3(25, 0, 0), nil, { id = 501 })
other._kind = "stalker"
local GO = getmetatable(avatar).__index
function GO:name() return "obj_" .. self._id end

SPOTS, SPOTS_GONE = {}, {}
level.map_add_object_spot_ser = function(id, spot, text) SPOTS[#SPOTS + 1] = { id = id, spot = spot, text = text } end
level.map_remove_object_spot = function(id, spot) SPOTS_GONE[id] = (SPOTS_GONE[id] or 0) + 1 end
function hide_hud_inventory() end
getmetatable(vector()).__index.add = function(self, o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z return self end
getmetatable(vector()).__index.mul = function(self, k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k return self end
function get_object_by_id(id) return OBJ[id] end
utils_stpk = { get_anom_zone_data = function() return { shapes = {} } end, set_anom_zone_data = function() end }

-- what the stock has, as the mods use it
item_backpack = {
	keep = {}, actor_on_item_use = function() end, actor_on_item_take_from_box = function() end,
	UICreateStash = { OnAccept = function() end },
}
do
	local boxes = {}
	smr_loot = { try_spawn = function(box) ROLLS = (ROLLS or 0) + 1; ROLL_ACTOR = db.actor:id() end, on_game_start = function() return boxes end }
	function smr_boxes() return boxes end
end
LESS_ARTYS = {}
zz_treasure_manager_pba_less_artys = { physic_object_on_use_callback = function(box) LESS_ARTYS[box:id()] = true end }
death_manager = { create_release_item = function() end }
if GAMMA then
	_G.class = function(name) getfenv(2)[name] = {} return function() end end
	campfire_placeable_mcm = { get_config = function() return false end }
	ui_inventory = { UIInventory = { Name_Custom = function() end, Action_Custom = function() end } }
	trader_autoinject = { update = function() end }
	local path = GAMMA_DIR .. BS .. "campfire_placeable.script"
	local fh = assert(io.open(path, "rb"))
	local src = fh:read("*a")
	fh:close()
	local header = "local this = {} campfire_placeable = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	assert(loadstring(header .. src, "@" .. path))()
	AddScriptCallback("actor_on_item_use")
	campfire_placeable.on_game_start()
end

start_all()
SendScriptCallback("actor_on_first_update")
local C = coop_mods_core
local function from_client(name, t, peer) coop_main.on_event("mods." .. name, coop_main.encode(t), peer or 1) end
local function m_data() return alife_storage_manager.get_state() end
local function book() return m_data().player_created_stashes end
local function created(sec)
	for _, c in ipairs(CREATED) do if c.sec == sec then return c end end
end
local function count_created(sec)
	local n = 0
	for _, c in ipairs(CREATED) do if c.sec == sec then n = n + 1 end end
	return n
end
local function pack(parent, pos)
	local _, o = spawn("itm_backpack", pos or vec3(20, 0, 0), parent)
	return o
end

INI.itm_backpack = { class = "EQ_BAKPK" }
INI.inv_backpack = {}
INI.st_junk = { class = "II_FOOD" }

print("-- stash_make: what is checked")
local mine = pack(500)
local _, junk = spawn("st_junk", vec3(20, 0, 0), 500)
local foreign = pack(501)
local far = pack(nil, vec3(40, 0, 0))
CREATED = {}
from_client("stash_make", { i = 9999 })
from_client("stash_make", { i = "x" })
from_client("stash_make", { i = junk:id() })
from_client("stash_make", { i = foreign:id() })
from_client("stash_make", { i = far:id() })
check(#CREATED == 0, "nothing for an unknown id, another item, another player's or one out of reach")
NOW = NOW + 10000

print("-- a backpack of the player")
SENT = {}
from_client("stash_make", { i = mine:id(), t = "my\nstash" .. string.rep("x", 200), p = "treasure_player" })
local box_made = created("inv_backpack")
check(box_made ~= nil and box_made.parent == nil, "the box is made")
local box_id = box_made and box_made.id
local box = box_id and OBJ[box_id]
check(box and box:position():distance_to(avatar:position()) < 0.01, "where the player stands, whatever he said")
check(SE[mine:id()] == nil, "the backpack is spent")
check(book() and book()[box_id] == "itm_backpack", "the world's book has it")
local q, raw = sent("mods.stash_made")
check(q ~= nil and raw.target == 1 and q.b == box_id and q.s == "itm_backpack" and q.i == mine:id(), "the player is answered with the id")
check(q and #q.t == 64 and not q.t:find("\n", 1, true), "a name of a client is cut and cleaned")
run_time_events(100)
check(#SPOTS == 1 and SPOTS[1].id == box_id and SPOTS[1].spot == "treasure_player", "the spot goes with the save")
CREATED = {}
NOW = NOW + 10000
local again = pack(500)
local real_release = alife_release_id
alife_release_id = function() end -- an online release is GE_DESTROY in a queue: the item is here for a moment
from_client("stash_make", { i = again:id() })
NOW = NOW + 10000
from_client("stash_make", { i = again:id() })
alife_release_id = real_release
check(count_created("inv_backpack") == 1, "a repeat before the release went through makes nothing")

print("-- the limit")
CREATED = {}
NOW = NOW + 30000
for _ = 1, 8 do from_client("stash_make", { i = pack(500):id() }) end
check(count_created("inv_backpack") == 3, "a burst is cut")

print("-- a backpack on the ground")
NOW = NOW + 30000
local ground = pack(nil, vec3(21, 0, 0))
CREATED, SENT = {}, {}
from_client("stash_make", { i = ground:id(), p = "treasure" })
box_made = created("inv_backpack")
check(box_made and OBJ[box_made.id]:position().x == 21, "the box stands where it lay")
check(sent("mods.stash_made").p == "treasure", "dotmarks' spot")

print("-- stash_free")
box._kind = "box"
local inside = spawn("st_junk", vec3(20, 0, 1), box_id)
CREATED = {}
NOW = NOW + 30000
from_client("stash_free", { b = box_id })
check(SE[box_id] ~= nil and #CREATED == 0, "not empty: nothing happens")
release_id(inside.id)
local _, far_box = spawn("inv_backpack", vec3(100, 0, 0))
book()[far_box:id()] = "itm_backpack"
from_client("stash_free", { b = far_box:id() })
check(SE[far_box:id()] ~= nil, "too far: nothing happens")
local _, bag = spawn("inv_backpack", vec3(21, 0, 0))
from_client("stash_free", { b = bag:id() })
check(SE[bag:id()] ~= nil, "a bag that is no player's stash: the engine's")
local _, furniture = spawn("workbench_stash", vec3(21, 0, 0))
book()[furniture:id()] = "itm_furniture"
from_client("stash_free", { b = furniture:id() })
check(SE[furniture:id()] ~= nil, "another stash of the book: not by this door")
CREATED = {}
NOW = NOW + 30000
from_client("stash_free", { b = box_id })
check(SE[box_id] == nil, "emptied: the box goes")
local given = created("itm_backpack")
check(given and given.parent == 500, "the backpack goes to the player who took the last item")
check(book()[box_id] == nil, "out of the book")
check(SPOTS_GONE[box_id] ~= nil, "the spot goes")
CREATED = {}
NOW = NOW + 30000
from_client("stash_free", { b = box_id })
check(#CREATED == 0, "twice: nothing more")

print("-- a map server")
local real_active_host = coop.is_host
coop.is_host, coop.is_client = function() return false end, function() return true end
coop.is_map_server = function() return true end
local function from_world(name, t, peer)
	t._peer = peer or 1
	coop_main.on_event("mods." .. name, coop_main.encode(t), 0)
end
NOW = NOW + 30000
local on_map = pack(500)
run_time_events(100)
SENT, CREATED, SPOTS = {}, {}, {}
from_world("stash_make", { i = on_map:id(), t = "n" })
local made = created("inv_backpack")
check(made ~= nil and SE[on_map:id()] == nil, "the box is made here, where the level is")
q, raw = sent("mods.stash_book")
check(q ~= nil and raw.target == 0 and q.b == made.id and q.s == "itm_backpack" and q.t == "n", "the world server gets the book")
check(book()[made.id] == "itm_backpack", "and this process knows its level's stash")
check(sent("mods.stash_made") ~= nil and select(2, sent("mods.stash_made")).target == 1, "the player gets the id from here")
run_time_events(100)
check(#SPOTS == 0, "no spot on a map server: its map is nobody's")
local mbox = OBJ[made.id]
mbox._kind = "box"
SENT, CREATED = {}, {}
NOW = NOW + 30000
from_world("stash_free", { b = made.id })
check(SE[made.id] == nil and created("itm_backpack") and created("itm_backpack").parent == 500, "it frees the box too")
q = sent("mods.stash_book")
check(q ~= nil and q.b == made.id and q.x == true, "and tells the world server")
SENT, CREATED = {}, {}
coop_main.on_event("mods.stash_make", coop_main.encode({ i = 1 }), 3)
check(#CREATED == 0, "a map server hears a player only through the world server")

print("-- the world server takes the book only from a bridge")
coop.is_host, coop.is_client = real_active_host, function() return false end
coop.is_map_server = function() return false end
coop.levels = { map_servers = function() return { { bridge = 0x101, level = 2 } } end, split = function() return true end,
	bridge_of_player = function() return nil end }
SPOTS = {}
local _, far_stash = spawn("inv_backpack", vec3(0, 0, 0))
from_client("stash_book", { b = far_stash:id(), s = "itm_backpack", p = "treasure", t = "n" }, 1)
check(book()[far_stash:id()] == nil, "a player is not heard")
from_client("stash_book", { b = 8123, s = "itm_backpack", p = "bad", t = "n" }, 0x101)
check(book()[8123] == "itm_backpack", "a bridge is")
run_time_events(100)
check(#SPOTS == 0, "its box is on its way here: no spot yet")
spawn("inv_backpack", vec3(0, 0, 0), nil, { id = 8123, offline = true })
run_time_events(100)
check(#SPOTS == 1 and SPOTS[1].id == 8123 and SPOTS[1].spot == "treasure_player", "then the spot, of a known kind")
from_client("stash_book", { b = 8123, x = true }, 0x101)
check(book()[8123] == nil and SPOTS_GONE[8123] ~= nil, "and it goes the same way")
coop.levels = nil

print("-- a campfire")
if GAMMA then
	local _, item = spawn("itm_campfire", vec3(20, 0, 0), 500)
	local _, stranger = spawn("itm_campfire", vec3(25, 0, 0), 501)
	local _, not_it = spawn("st_junk", vec3(20, 0, 0), 500)
	INI.ph_campfiremod, INI.campfire = {}, {}
	CREATED = {}
	NOW = NOW + 30000
	from_client("cf_place", { i = stranger:id() })
	from_client("cf_place", { i = not_it:id() })
	from_client("cf_place", { i = 9999 })
	check(#CREATED == 0, "only a campfire of the player")
	NOW = NOW + 30000
	from_client("cf_place", { i = item:id() })
	local cf = created("ph_campfiremod")
	check(cf ~= nil and cf.parent == nil, "the campfire stands")
	check(cf and OBJ[cf.id]:position():distance_to(avatar:position()) <= 2.01, "2 m ahead of the client's character, the stock's own place")
	check(SE[item:id()] == nil, "the item is spent then")
	check(db.actor:id() == 0, "db.actor is this process's again")
	run_time_events(2000)
	local zone = created("campfire")
	check(zone ~= nil, "the fire of it by the stock's own timers")
	CREATED = {}
	NOW = NOW + 30000
	local _, item2 = spawn("itm_campfire", vec3(20, 0, 0), 500)
	local real_create = alife_create
	alife_create = function() error("no create") end
	from_client("cf_place", { i = item2:id() })
	alife_create = real_create
	check(SE[item2:id()] ~= nil, "a campfire that was not made spends nothing")
else
	print("-- skipped: no GAMMA scripts")
end

print("-- a client's window on a box")
local function fresh_box(pos)
	local _, b = spawn("box", pos or vec3(20, 0, 1))
	b._kind = "box"
	return b
end
local zb = fresh_box()
ROLLS = 0
coop_mods_core.on_container_opened(1, zb:id())
check(ROLLS == 1 and ROLL_ACTOR == 500, "the first window rolls, for that player")
coop_mods_core.on_container_opened(1, zb:id())
check(ROLLS == 1, "every window after it does not")
local seen = fresh_box()
smr_boxes()[seen:id()] = true
coop_mods_core.on_container_opened(1, seen:id())
check(ROLLS == 1, "a box the stock rolled for the host does not")
local stash_box = fresh_box()
book()[stash_box:id()] = "itm_backpack"
coop_mods_core.on_container_opened(1, stash_box:id())
check(ROLLS == 1, "a player's stash does not")
local _, body = spawn("bandit", vec3(20, 0, 1), nil, { alive = false })
body._kind = "stalker"
coop_mods_core.on_container_opened(1, body:id())
check(ROLLS == 1, "a body does not: the stock rolls boxes")
smr_loot.try_spawn(fresh_box())
check(ROLLS == 2, "the stock's own call is not touched")
run_time_events(1500)
LESS_ARTYS = {}
coop_mods_core.on_container_opened(1, zb:id())
check(LESS_ARTYS[zb:id()] == nil, "less artefacts waits for the treasure of that box")
run_time_events(1500)
check(LESS_ARTYS[zb:id()] == true, "then it runs for a client's box")

print("-- guaranteed drops on a client's search")
GUARANTEED = {}
guaranteed_loot = { npc_on_use = function(obj, who) GUARANTEED[#GUARANTEED + 1] = { obj = obj:id(), who = who:id() } end }
local _, corpse = spawn("bandit", vec3(21, 0, 0), nil, { alive = false })
corpse._kind = "stalker"
NOW = NOW + 30000
from_client("corpse_loot", { n = corpse:id() })
check(#GUARANTEED == 1 and GUARANTEED[1].obj == corpse:id() and GUARANTEED[1].who == 0, "counted with the id the mod takes for the player")

done("DEPLOY AUTHORITY")
