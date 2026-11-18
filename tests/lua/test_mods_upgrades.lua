-- Dev 57 G14-3: repair dialogue availability belongs to this player's live mechanic queue.
-- The stock functions below retain their private RepairItemList; only engine services are stubbed.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

local stock_path = "temp/stock_scripts/scripts/inventory_upgrades.script"
local fh = assert(io.open(stock_path, "rb"))
local source = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local first = assert(source:find("local RepairItemList = {}", 1, true))
local last = assert(source:find("function dm_repair_not_done", first, true))
local repair_source = source:sub(first, last - 1)

local flags = {}
function give_info(name) flags[name] = true end
function disable_info(name) flags[name] = nil end
function has_alife_info(name) return flags[name] == true end
utils_data = { CTime_to_table = function(t) return t end, CTime_from_table = function(t) return t end }
game = { get_game_time = function() return { diffSec = function(_, t) return 100 - t end } end }
news_manager.relocate_item = function() end
dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
make_actor()
local _, mechanic = spawn("mechanic_a", vec3(0, 0, 0))
local _, another = spawn("mechanic_b", vec3(0, 0, 0))
load_script("coop_mods_core")

local function install(mod)

	inventory_upgrades = mod
	-- Before the implementation exists, run the stock behaviour so RED proves the queue/flag bug.
	local file = io.open("gamedata/scripts/coop_mods_upgrades.script", "rb")
	if not file then return nil end
	file:close()
	local adapter = load_script("coop_mods_upgrades")
	adapter.on_game_start()
	return adapter
end

local function player(queues)
	local mod = { delayed_upgrades_fix = function() end }
	setmetatable(mod, { __index = _G })
	local chunk = assert(loadstring(repair_source, "@" .. stock_path))
	setfenv(chunk, mod)
	chunk()
	mod.load_state({ RepairItemList = queues })
	install(mod)
	return mod
end

local function saved(mod)
	local scratch = {}
	mod.save_state(scratch)
	return scratch.RepairItemList
end

-- Both modes use the same local dialogue, independently of the deciding process's role.
local roles = {
	{ name = "Co-op host", mode = "host" },
	{ name = "Co-op client", mode = "client" },
	{ name = "Server map", mode = "host", map = true },
	{ name = "Server world", mode = "host", world = true },
	{ name = "Server player", mode = "client" },
}
for _, role in ipairs(roles) do
	MODE = role.mode
	coop.is_map_server = function() return role.map == true end
	coop.is_dedicated = function() return role.world == true end
	flags = {}
	local _, gun1 = spawn("gun_a", vec3(0, 0, 0), mechanic:id())
	local _, gun2 = spawn("gun_b", vec3(0, 0, 0), mechanic:id())
	local q1 = { mechanic_a = { [gun1:id()] = { gt = 0, rt = 10 } } }
	local q2 = { mechanic_a = { [gun2:id()] = { gt = 0, rt = 10 } } }
	local p1, p2 = player(q1), player(q2)
	give_info("mechanic_a_is_repairing")
	check(p1.has_repair_info(db.actor, mechanic) and p2.has_repair_info(mechanic, db.actor),
		role.name .. ": two personal queues at one mechanic are available")
	check(p1.give_repaired_items(db.actor, mechanic) == true and not has_alife_info("mechanic_a_is_repairing"),
		role.name .. ": collecting the first player's last order clears the shared flag")
	check(p1.has_repair_info(db.actor, mechanic) == false,
		role.name .. ": collected personal queue is unavailable")
	check(p2.has_repair_info(db.actor, mechanic) == true,
		role.name .. ": other player's remaining order survives the cleared shared flag (s36:1)")
	check(saved(p2) == q2 and q2.mechanic_a[gun2:id()] ~= nil and gun2:parent():id() == mechanic:id(),
		role.name .. ": availability neither changes the queue nor takes an item")
	check(p2.give_repaired_items(db.actor, mechanic) == true and gun2:parent():id() == 0,
		role.name .. ": the second player's order can still be collected")

	-- Another player's flag, another mechanic's queue and an empty queue must not unlock this dialogue.
	give_info("mechanic_a_is_repairing")
	check(p1.has_repair_info(db.actor, mechanic) == false,
		role.name .. ": shared true flag does not unlock an empty personal queue")
	local pending = player({ mechanic_b = { [9001] = { gt = 100, rt = 500 } } })
	check(pending.has_repair_info(db.actor, mechanic) == false,
		role.name .. ": orders at another mechanic do not unlock this mechanic")
	check(pending.has_repair_info(db.actor, another) == true and pending.has_repaired_items(db.actor, another) == false,
		role.name .. ": pending own order opens its dialogue without declaring the repair complete")
	-- load_state removes the m_data key: this stale table must never substitute for the live module queue.
	alife_storage_manager = { get_state = function() return { RepairItemList = q2 } end }
	pending.load_state({ RepairItemList = { mechanic_a = {} } })
	check(pending.has_repair_info(db.actor, mechanic) == false,
		role.name .. ": query rereads current queue after load, ignoring stale saved data")
end

MODE = "sp"
local sp = player({ mechanic_a = { [123] = { gt = 0, rt = 10 } } })
flags = {}
check(sp.has_repair_info(db.actor, mechanic) == false, "Single player: original false flag still decides despite a queue")
give_info("mechanic_b_is_repairing")
check(sp.has_repair_info(db.actor, another) == true, "Single player: original true flag still decides without a queue")

-- Foreign wrappers and all original arguments/returns survive outside a session.
local called, read = 0, 0
local original = {
	has_repair_info = function(a, b, extra)
		called = called + 1
		return a, b, extra, nil, "tail"
	end,
	save_state = function() read = read + 1; error("SP must not read the queue") end,
}
local adapter = install(original)
local a, b, c, d, e = original.has_repair_info("first", "second", "third")
check(a == "first" and b == "second" and c == "third" and d == nil and e == "tail" and called == 1 and read == 0,
	"Single player: original wrapper chain, varargs and multiple returns are unchanged")

MODE = "client"
local function returned_false_without_throw(mod)
	local ok, result = pcall(mod.has_repair_info, db.actor, mechanic)
	return ok and result == false
end
local broken = player({})
broken.save_state = function() error("foreign save failed: %s %n") end
check(returned_false_without_throw(broken), "Foreign save failure: no shared-flag fallback and no thrown dialogue error")
for _, value in ipairs({ false, 7, "not a queue", { mechanic_a = false }, { mechanic_a = 42 } }) do
	broken.save_state = function(t) t.RepairItemList = value end
	check(returned_false_without_throw(broken), "Malformed live queue is unavailable: " .. tostring(value))
end

local missing_save = { has_repair_info = function() return "original" end }
install(missing_save)
check(missing_save.has_repair_info() == "original", "Missing save API: original function stays installed")
adapter = install(false)
check(adapter ~= nil and pcall(adapter.on_game_start), "Missing mod: startup does not throw")

local p = player({ mechanic_a = { [1] = { gt = 0, rt = 1 } } })
adapter = rawget(_G, "coop_mods_upgrades")
local wraps = #coop_mods_core.wrapped
if adapter then adapter.on_game_start() end
check(#coop_mods_core.wrapped == wraps and p.has_repair_info(db.actor, mechanic) == true,
	"Repeated startup: wrapper installs once and remains functional")

local wrap = coop_mods_core.wrap
coop_mods_core.wrap = function() error("foreign install failed") end
local ok = pcall(function() install({ has_repair_info = function() end, save_state = function() end }) end)
coop_mods_core.wrap = wrap
check(ok, "Foreign install failure: on_game_start does not throw")

done("mods upgrades personal repair queues (Dev 57)")
