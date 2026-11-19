-- Anomaly Coop test, F4 G4-5, finding m20:1 (build 57): Darkasleif's Nimble Upgrades Guns. NimbleTrade.<kind>_requested
-- (NimbleTrade.script :2360-2990) moves the gun to the trader, pays and gives the upgrade by three independent relocations
-- (:2369-2371); in a session each is a request of its own, so a refused one leaves a half exchange (the upgrade and the old
-- gun kept, or the money and the gun gone without the upgrade). coop_mods_xchg_nimble turns an upgrade into one operation:
-- the keeper of the money holds the price (mods.nim_hold), the decider of the player's map swaps the guns (coop_mods_xchg
-- kind "nimble") and reports commit or refund (here, or mods.nim_done); the world server tells the map servers the hold
-- (mods.nim_held). Runs once per answer set of the facade coop_mode (docs\MODES.md section 10):
--   hostplay   the co-op host: a client's upgrade, its own player's upgrade; the co-op client's machine; one loop end to end
--   srv_world  the world server (holds, results, timeouts, two maps) and a server player's machine (lost answers)
--   srv_map    a map server (the gun step of a player of its map, the result to the world server)
--   none       single player: the mod's own three relocations
-- The mod's file: GAMMA_SCRIPTS (the stand, read only), else temp\review\corpus\merged, else the stand-in below
-- (NIMBLE_STAND_IN=1 takes the stand-in on purpose).
-- Not shipped. Run: tools\test_lua.cmd mods_xchg_nimble
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== NimbleTrade upgrades as one exchange, answer set " .. name)

local BRIDGE, BRIDGE2 = 0x101, 0x102
local CAMO = "wpn_colt1911_camo"

coop.world_epoch = function() if MODE == "sp" then return nil end return 7 end
-- the ledger of the world's money (coop.money_of / coop.money_grant: never below 0)
BOOK, GRANTS = {}, {}
coop.money_of = function(peer) return BOOK[peer] end
coop.money_grant = function(peer, n)
	if type(BOOK[peer]) ~= "number" then return false, "no character" end
	GRANTS[#GRANTS + 1] = { peer = peer, n = n }
	BOOK[peer] = math.max(0, BOOK[peer] + n)
	return true
end

make_actor(vec3(0, 0, 0))
local GO = getmetatable(db.actor)
function GO:money() return self._money or 0 end
local _, avatar = spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
local _, trader = spawn("zat_b30_nimble", vec3(21, 0, 0), nil, { id = 600 })
trader._kind = "stalker"
for _, s in ipairs({ "wpn_colt1911", "wpn_colt1911_alt", CAMO, "wpn_desert_eagle", "wpn_desert_eagle_nimble",
	"wpn_pkm_siber", "wpn_pkm_zenit_siber" }) do INI[s] = {} end

-- item_parts: a gun's parts (0..100); the mod's has_bad_part reads the first one
item_parts = { get_parts_con = function(obj) return obj._parts or { barrel = 100 } end }
NEWS = {}
news_manager.relocate_item = function(actor, dir, sec) NEWS[#NEWS + 1] = { "item", dir, sec } end
news_manager.relocate_money = function(actor, dir, n) NEWS[#NEWS + 1] = { "money", dir, n } end
-- dialogs.script :1829-1858 (the relocations the mod calls), as they behave in single player
DIALOG = {}
dialogs = {
	relocate_item_section_from_actor = function(first, second, section)
		DIALOG[#DIALOG + 1] = { "from", section }
		local npc = first:id() == db.actor:id() and second or first
		local item = db.actor:object(section)
		if item then db.actor:transfer_item(item, npc) end
	end,
	relocate_money_from_actor = function(first, second, n)
		DIALOG[#DIALOG + 1] = { "money", n }
		db.actor._money = (db.actor._money or 0) - n
	end,
	relocate_item_section_to_actor = function(first, second, section)
		DIALOG[#DIALOG + 1] = { "to", section }
		alife_create_item(section, db.actor)
	end,
}

-------------------------------------------------------------------------------
-- the mod (its real file when there is one)
-------------------------------------------------------------------------------
local STAND_IN = [[
CoonanCost = 50000
PKMCost = 100000
local gun_val = 0.01
local part_val = 60
local function input_function(owner, item)
	if (item:section() == wpn_name) then obj = item end
end
function has_bad_part(v, obj)
	for _, value in pairs(item_parts.get_parts_con(obj)) do
		if value < v then return true else return false end
	end
end
local function good_gun(gun_val, part_val, obj)
	if not has_bad_part(part_val, obj) then return true else return false end
end
function player_has_coonan_money() return db.actor:money() >= CoonanCost end
function player_has_pkm_money() return db.actor:money() >= PKMCost end
function coonan_requested(first_speaker, second_speaker)
	if player_has_coonan_money() then
		if db.actor:object("wpn_colt1911") then
			wpn_name = "wpn_colt1911"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_colt1911")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, CoonanCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_colt1911_camo")
			end
		elseif db.actor:object("wpn_colt1911_alt") then
			wpn_name = "wpn_colt1911_alt"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_colt1911_alt")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, CoonanCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_colt1911_camo")
			end
		end
	end
end
function pkm_requested(first_speaker, second_speaker)
	if player_has_pkm_money() then
		if db.actor:object("wpn_pkm_siber") then
			wpn_name = "wpn_pkm_siber"
			db.actor:iterate_inventory(input_function)
			if not (obj) then return end
			if good_gun(gun_val, part_val, obj) then
				dialogs.relocate_item_section_from_actor(first_speaker, second_speaker, "wpn_pkm_siber")
				dialogs.relocate_money_from_actor(first_speaker, second_speaker, PKMCost)
				dialogs.relocate_item_section_to_actor(first_speaker, second_speaker, "wpn_pkm_zenit_siber")
			end
		end
	end
end
]]
local function read_mod()
	if os.getenv("NIMBLE_STAND_IN") == "1" then return STAND_IN, nil end -- the stand-in on purpose
	local dirs = {}
	local stand = os.getenv("GAMMA_SCRIPTS")
	if stand and stand ~= "" then dirs[#dirs + 1] = stand end
	dirs[#dirs + 1] = "temp/review/corpus/merged"
	for _, dir in ipairs(dirs) do
		local fh = io.open(dir .. "/NimbleTrade.script", "r")
		if fh then
			local src = fh:read("*a")
			fh:close()
			return src, dir
		end
	end
	return STAND_IN, nil
end
local MOD_SRC, MOD_FROM = read_mod()
print("   the mod: " .. (MOD_FROM and (MOD_FROM .. "\\NimbleTrade.script") or "the stand-in of this test"))
do
	local header = "local this = {} NimbleTrade = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. MOD_SRC, "@NimbleTrade.script"))
	f()
end
local ORIG_COONAN = NimbleTrade.coonan_requested

start_all()
load_script("coop_mods_xchg")
coop_mods_xchg.on_game_start()
local loaded, N = pcall(load_script, "coop_mods_xchg_nimble")
if not (loaded and type(N) == "table") then
	check(false, "coop_mods_xchg_nimble loads (" .. tostring(N) .. ")")
	N = nil
else
	local started, why_not = pcall(N.on_game_start)
	check(started, "on_game_start does not throw (" .. tostring(why_not) .. ")")
end
local OVERRIDES = nil
if name == "srv_world" then
	OVERRIDES = { seat_plays = function(peer) return peer ~= 0 and peer ~= BRIDGE and peer ~= BRIDGE2 end }
end
modes.install(coop_mode, name, OVERRIDES)
coop_trust.reset_for_test({ default = "log" })

-------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------
local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end
local function gun(owner, sec, parts)
	local _, o = spawn(sec or "wpn_colt1911", vec3(20, 0, 0), owner)
	o._kind = "weapon"
	o._parts = parts
	return o
end
local function gone(o) return SE[o:id()] == nil end
-- live items of a section in a parent
local function has(sec, parent)
	local n = 0
	for _, se in pairs(SE) do
		if se._sec == sec and se.parent_id == parent then n = n + 1 end
	end
	return n
end
local function press(kind) return NimbleTrade[(kind or "coonan") .. "_requested"](db.actor, trader) end
local function ev(verb, t, from) coop_main.on_event("mods." .. verb, coop_main.encode(t), from) end
local function last(event)
	local t, raw = sent(event)
	return t or {}, raw and raw.target, raw
end
local function counter(n) return coop_trust.status()[n] or { checked = 0, failed = 0, refused = 0 } end
-- a hold request of player `from` as it reaches the keeper of the money (6 at once, 1 a second: a second between them)
local function hold_req(op, from, kind)
	NOW = NOW + 1100
	ev("nim_hold", { o = op, g = kind or "coonan" }, from)
	return last("mods.nim_hold_r")
end
-- the gun step of player `from` as it reaches the decider of his map (a map server: from the world server with his peer)
local function apply(t, from)
	NOW = NOW + 1100
	t.k = "nimble"
	if name == "srv_map" then
		t._peer = from
		ev("xchg", t, 0)
	else
		ev("xchg", t, from)
	end
	return last("mods.xchg_r")
end
local function news_ok(from, price, to)
	return #NEWS == 3 and NEWS[1][1] == "item" and NEWS[1][2] == "out" and NEWS[1][3] == from and NEWS[2][1] == "money"
		and NEWS[2][2] == "out" and NEWS[2][3] == price and NEWS[3][1] == "item" and NEWS[3][2] == "in" and NEWS[3][3] == to
end

-------------------------------------------------------------------------------
-- the list of upgrades is the mod's (when its real file is here)
-------------------------------------------------------------------------------
if N and MOD_FROM then
	local by = {}
	for _, u in ipairs(N.UPGRADES or {}) do by[u.kind] = u end
	local src = MOD_SRC .. "\n"
	local found, bad = 0, {}
	for kind, body in src:gmatch("\nfunction ([%w_]+)_requested%(first_speaker, second_speaker%)(.-)\nend\n") do
		found = found + 1
		local u = by[kind]
		local froms, costs, tos = {}, {}, {}
		for s in body:gmatch('relocate_item_section_from_actor%(first_speaker, second_speaker, "([^"]+)"%)') do froms[#froms + 1] = s end
		for c in body:gmatch("relocate_money_from_actor%(first_speaker, second_speaker, ([%w_]+)%)") do costs[c] = true end
		for s in body:gmatch('relocate_item_section_to_actor%(first_speaker, second_speaker, "([^"]+)"%)') do tos[s] = true end
		local same = u ~= nil and #froms == #u.from and costs[u.cost] == true and next(costs, u.cost) == nil
			and next(costs) == u.cost and tos[u.to] == true and next(tos, u.to) == nil and next(tos) == u.to
		for i = 1, u and #u.from or 0 do same = same and froms[i] == u.from[i] end
		local money = src:match("\nfunction player_has_" .. kind .. "_money%(%)%s*local money = db%.actor:money%(%)%s*return %(money >= ([%w_]+)%)")
		same = same and money == (u and u.cost)
		if not same then bad[#bad + 1] = kind end
	end
	check(found == #(N.UPGRADES or {}) and #bad == 0, "UPGRADES is the mod's: " .. found .. " actions, sources, price and result of "
		.. "each (different: " .. table.concat(bad, ",") .. ")")
end

-------------------------------------------------------------------------------
if name == "none" then
	-- single player: the mod's own three relocations, nothing else
	local g = gun(0)
	db.actor._money = 60000
	press()
	check(#DIALOG == 3 and DIALOG[1][2] == "wpn_colt1911" and DIALOG[2][2] == 50000 and DIALOG[3][2] == CAMO,
		"single player: the mod's three relocations run as before")
	check(SE[g:id()].parent_id == 600 and db.actor._money == 10000 and has(CAMO, 0) == 1,
		"single player: the gun goes to the trader, the price is paid, the upgrade is made")
	check(#SENT == 0, "single player: nothing on the wire")
	check(N ~= nil and NimbleTrade.coonan_requested ~= ORIG_COONAN, "single player: the action is wrapped, and the wrapper calls the mod")

-------------------------------------------------------------------------------
elseif name == "hostplay" then
	local CLIENT = {
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		decides_world = function() return false end,
		decider = function() return "other" end,
	}
	local function as_client()
		MODE, SELF = "client", 1
		modes.install(coop_mode, "hostplay", CLIENT)
	end
	local function as_host()
		MODE, SELF = "host", 0
		modes.install(coop_mode, "hostplay")
	end

	---------------------------------------------------------------------------
	-- the co-op host decides for a client (peer 1, his character 500)
	---------------------------------------------------------------------------
	BOOK[1] = 50000
	local g1 = gun(500)
	local a, target = hold_req("1:7:1", 1)
	check(a.o == "1:7:1" and a.ok == true and a.m == 50000 and target == 1 and BOOK[1] == 0,
		"co-op host: a client's hold takes the price at once and is answered to him")
	check(sent_count("mods.nim_held") == 0, "co-op host: the hold is noted here, nothing goes to a map server")
	local grants = #GRANTS
	a = hold_req("1:7:1", 1)
	check(a.ok == true and #GRANTS == grants and BOOK[1] == 0 and sent_count("mods.nim_hold_r") == 2,
		"co-op host: a repeated hold gets its stored answer, never a second charge")
	local x, xt = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	check(x.o == "1:7:2" and x.ok == true and x["r.s"] == CAMO and x["r.m"] == 50000 and xt == 1,
		"co-op host: the gun step is answered ok, with the upgrade and its price")
	check(gone(g1) and has(CAMO, 500) == 1 and BOOK[1] == 0,
		"co-op host: the old gun is removed, the upgrade made in his character, the price stays paid")
	x = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	check(x.ok == true and has(CAMO, 500) == 1, "co-op host: a repeated gun step op gets its stored answer, nothing is made again")
	local g2 = gun(500)
	x = apply({ o = "1:7:3", h = "1:7:1", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(g2) and BOOK[1] == 0 and has(CAMO, 500) == 1,
		"co-op host: a spent hold is never applied again, and not given back")
	tick(61000)
	tick(1100)
	check(BOOK[1] == 0, "co-op host: a committed hold is not given back when its 60 s are over")

	-- a cheating client holds twice and names one gun twice: one upgrade, one charge
	BOOK[1] = 100000
	hold_req("1:7:10", 1)
	hold_req("1:7:11", 1)
	check(BOOK[1] == 0, "co-op host: two holds take the price twice ...")
	x = apply({ o = "1:7:12", h = "1:7:10", g = "coonan", w = g2:id(), n = 600 }, 1)
	local first_ok = x.ok == true
	x = apply({ o = "1:7:13", h = "1:7:11", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(first_ok and x.o == "1:7:13" and x.ok == false and x.why == "weapon" and gone(g2) and has(CAMO, 500) == 2
		and BOOK[1] == 50000, "co-op host: ... one upgrade; the second gun step on the gone gun is refused and its hold given back")
	-- the same while the removal of the old gun is still on its way (alife():release of an online object is an event)
	local real_release = alife_release_id
	local later = {}
	alife_release_id = function(id) later[#later + 1] = id; return true end
	local g3 = gun(500)
	BOOK[1] = 100000
	hold_req("1:7:14", 1)
	hold_req("1:7:15", 1)
	x = apply({ o = "1:7:16", h = "1:7:14", g = "coonan", w = g3:id(), n = 600 }, 1)
	first_ok = x.ok == true
	x = apply({ o = "1:7:17", h = "1:7:15", g = "coonan", w = g3:id(), n = 600 }, 1)
	alife_release_id = real_release
	check(first_ok and x.ok == false and x.why == "reserved" and has(CAMO, 500) == 3 and BOOK[1] == 50000,
		"co-op host: a gun whose removal is on its way stays reserved: the second gun step is refused, its hold given back")
	for _, id in ipairs(later) do release_id(id) end
	tick()

	-- not enough money
	BOOK[1] = 49999
	grants = #GRANTS
	a = hold_req("1:7:20", 1)
	check(a.ok == false and a.why == "poor" and BOOK[1] == 49999 and #GRANTS == grants,
		"co-op host: a balance short of the price is refused, nothing taken")
	-- a gun that is not his, one this upgrade does not take, an id out of bounds: refused, the hold given back
	BOOK[1] = 50000
	local hosts = gun(0)
	local weapon_failed = counter("nimble_weapon").failed
	hold_req("1:7:21", 1)
	x = apply({ o = "1:7:22", h = "1:7:21", g = "coonan", w = hosts:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "weapon" and not gone(hosts) and BOOK[1] == 50000
		and counter("nimble_weapon").failed == weapon_failed + 1, "co-op host: the host's gun named by a client is refused, the hold given back")
	release_id(hosts:id())
	local deagle = gun(500, "wpn_desert_eagle")
	hold_req("1:7:23", 1)
	x = apply({ o = "1:7:24", h = "1:7:23", g = "coonan", w = deagle:id(), n = 600 }, 1)
	check(x.why == "weapon" and not gone(deagle) and BOOK[1] == 50000,
		"co-op host: his gun of another upgrade is refused, the hold given back")
	hold_req("1:7:25", 1)
	x = apply({ o = "1:7:26", h = "1:7:25", g = "coonan", w = 70000, n = 600 }, 1)
	check(x.why == "weapon" and BOOK[1] == 50000, "co-op host: a gun id out of bounds is refused, the hold given back")

	-- the map step fails: nothing changes, the price goes back
	local g5 = gun(500)
	hold_req("1:7:30", 1)
	local real_create = alife_create_item
	alife_create_item = function() return nil end
	x = apply({ o = "1:7:31", h = "1:7:30", g = "coonan", w = g5:id(), n = 600 }, 1)
	alife_create_item = real_create
	check(x.ok == false and x.why == "make" and not gone(g5) and BOOK[1] == 50000 and has(CAMO, 500) == 3,
		"co-op host: the upgrade cannot be made: the old gun stays, the price goes back")
	hold_req("1:7:32", 1)
	alife_release_id = function(id) if id == g5:id() then error("refused") end return real_release(id) end
	x = apply({ o = "1:7:33", h = "1:7:32", g = "coonan", w = g5:id(), n = 600 }, 1)
	alife_release_id = real_release
	check(x.ok == false and x.why == "take" and not gone(g5) and BOOK[1] == 50000 and has(CAMO, 500) == 3,
		"co-op host: the old gun cannot be removed: the made upgrade is removed again, the price goes back")

	-- a hold without a gun step goes back after 60 s; a gun step after that is refused
	hold_req("1:7:40", 1)
	check(BOOK[1] == 0, "co-op host: a hold ...")
	tick(30000)
	tick(31000)
	tick(1100)
	check(BOOK[1] == 50000, "co-op host: ... with no gun step is given back after 60 s")
	x = apply({ o = "1:7:41", h = "1:7:40", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "late" and not gone(g5) and BOOK[1] == 50000,
		"co-op host: a gun step after that is refused (late), the price not given twice")
	x = apply({ o = "1:7:42", h = "1:7:999", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "unpaid" and not gone(g5) and BOOK[1] == 50000,
		"co-op host: a gun step without a hold is refused")

	-- the client's word in log mode is let through (and counted), in refuse mode refused with the hold given back
	local worn = gun(500, nil, { barrel = 10 })
	hold_req("1:7:50", 1)
	x = apply({ o = "1:7:51", h = "1:7:50", g = "coonan", w = worn:id(), n = 600 }, 1)
	check(x.ok == true and counter("nimble_parts").failed == 1 and counter("nimble_parts").refused == 0 and BOOK[1] == 0,
		"co-op host: worn parts in log mode are logged and let through")
	check(log_has("would be refused") ~= nil, "co-op host: ... the trust line says it would be refused")
	coop_trust.reset_for_test({ default = "refuse" })
	BOOK[1] = 50000
	local worn2 = gun(500, nil, { barrel = 10 })
	hold_req("1:7:52", 1)
	x = apply({ o = "1:7:53", h = "1:7:52", g = "coonan", w = worn2:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "parts" and not gone(worn2) and BOOK[1] == 50000,
		"co-op host: worn parts in refuse mode are refused, the hold given back")
	trader._pos = vec3(500, 0, 0)
	hold_req("1:7:54", 1)
	x = apply({ o = "1:7:55", h = "1:7:54", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.ok == false and x.why == "far" and not gone(g5) and BOOK[1] == 50000,
		"co-op host: no trader near him in refuse mode: refused, the hold given back")
	trader._pos = vec3(21, 0, 0)
	coop_trust.reset_for_test({ default = "log" })

	-- the envelope: a hold without a valid op is dropped, an unknown upgrade refused, three open holds at most
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "x;y", g = "coonan" }, 1)
	ev("nim_hold", { o = string.rep("1", 50), g = "coonan" }, 1)
	ev("nim_hold", { g = "coonan" }, 1)
	check(sent_count("mods.nim_hold_r") == n and counter("nimble_hold_op").failed == 3, "co-op host: a hold without a valid op id is dropped")
	a = hold_req("1:7:60", 1, "bfg9000")
	check(a.ok == false and a.why == "kind" and BOOK[1] == 50000, "co-op host: an upgrade the mod does not have is refused")
	BOOK[1] = 1000000
	hold_req("1:7:61", 1)
	hold_req("1:7:62", 1)
	hold_req("1:7:63", 1)
	a = hold_req("1:7:64", 1)
	check(a.ok == false and a.why == "busy" and BOOK[1] == 850000, "co-op host: a fourth open hold of one player is refused")
	-- a client cannot settle a hold, nor tell the map step one
	ev("nim_done", { p = 1, h = "1:7:61", c = 0 }, 1)
	check(BOOK[1] == 850000 and counter("nimble_done_sender").failed == 1,
		"co-op host: a player's nim_done is dropped: he cannot get the price of an upgrade back")
	ev("nim_held", { p = 1, h = "1:7:65", g = "coonan", m = 1 }, 1)
	x = apply({ o = "1:7:66", h = "1:7:65", g = "coonan", w = g5:id(), n = 600 }, 1)
	check(x.why == "unpaid" and not gone(g5), "co-op host: a player's nim_held is not taken: no hold of his own making")
	tick(61000)
	tick(1100)
	check(BOOK[1] == 1000000, "co-op host: the open holds went back after 60 s")
	release_id(g5:id())
	for _, o in ipairs({ deagle, worn2 }) do release_id(o:id()) end

	---------------------------------------------------------------------------
	-- the co-op host's own player (peer 0): both steps here, nothing on the wire
	---------------------------------------------------------------------------
	BOOK[0] = 60000
	db.actor._money = 60000
	local h1 = gun(0)
	local wire = { sent_count("mods.nim_hold"), sent_count("mods.nim_hold_r"), sent_count("mods.xchg"), sent_count("mods.xchg_r") }
	NEWS = {}
	press()
	press()
	check(gone(h1) and has(CAMO, 0) == 1 and BOOK[0] == 10000,
		"co-op host's own player: exactly enough money, pressed twice: one upgrade in his inventory, one charge")
	check(sent_count("mods.nim_hold") == wire[1] and sent_count("mods.nim_hold_r") == wire[2] and sent_count("mods.xchg") == wire[3]
		and sent_count("mods.xchg_r") == wire[4], "co-op host's own player: nothing goes on the wire")
	check(#DIALOG == 0, "co-op host's own player: the mod's relocations never ran")
	check(news_ok("wpn_colt1911", 50000, CAMO), "co-op host's own player: the news the mod's relocations would tell")
	BOOK[0] = 100
	local h2 = gun(0)
	HUD = nil
	press()
	check(not gone(h2) and BOOK[0] == 100 and type(HUD) == "string" and HUD:find("not enough money") ~= nil,
		"co-op host's own player: his balance short of the price: refused and told, the gun stays")
	release_id(h2:id())

	---------------------------------------------------------------------------
	-- the co-op client's machine, and one upgrade end to end
	---------------------------------------------------------------------------
	as_client()
	db.actor._money = 50000
	local c1 = gun(0) -- his gun (his actor is 0 here, 500 on the host)
	local asked = sent_count("mods.nim_hold")
	press()
	press()
	local req, hraw = sent("mods.nim_hold")
	check(sent_count("mods.nim_hold") == asked + 1 and req.g == "coonan" and type(req.o) == "string"
		and req.o:match("^1:7:%d+$") ~= nil and hraw.target == 0,
		"client: a press asks the host to hold the price; a second press while it is on its way is ignored")
	check(#DIALOG == 0 and not gone(c1) and db.actor._money == 50000, "client: the mod's relocations do not run on his machine")
	as_host()
	BOOK[1] = 50000
	deliver(hraw, 1)
	local _, ans = sent("mods.nim_hold_r")
	check(BOOK[1] == 0, "host: the client's hold is taken")
	as_client()
	deliver(ans, 0)
	local xreq, xraw = sent("mods.xchg")
	check(xreq and xreq.k == "nimble" and xreq.h == req.o and xreq.g == "coonan" and xreq.w == c1:id() and xreq.n == 600
		and xraw.target == 0, "client: the hold's ok sends the gun step with the concrete gun and the trader")
	press()
	check(sent_count("mods.nim_hold") == asked + 1, "client: no new upgrade while the gun step is on its way")
	as_host()
	SE[c1:id()].parent_id = 500 -- on the host his gun is in his character
	local camos = has(CAMO, 500)
	deliver(xraw, 1)
	deliver(xraw, 1) -- the gun step twice on the wire: its stored answer
	local _, xans = sent("mods.xchg_r")
	check(gone(c1) and has(CAMO, 500) == camos + 1 and BOOK[1] == 0, "host: the client's upgrade is made once, its price taken once")
	as_client()
	NEWS = {}
	deliver(xans, 0)
	deliver(xans, 0)
	check(news_ok("wpn_colt1911", 50000, CAMO), "client: the answer tells the news of the exchange, once")
	press()
	check(sent_count("mods.nim_hold") == asked + 1, "client: with the gun gone a press asks nothing")

	-- refused, no answer, an answer from another peer
	local c2 = gun(0)
	press()
	req = sent("mods.nim_hold")
	HUD = nil
	ev("nim_hold_r", { o = req.o, ok = false, why = "poor" }, 0)
	local xs = sent_count("mods.xchg")
	check(type(HUD) == "string" and HUD:find("not enough money") ~= nil and sent_count("mods.xchg") == xs and not gone(c2),
		"client: a refused hold is told, no gun step")
	press()
	req = sent("mods.nim_hold")
	ev("nim_hold_r", { o = req.o, ok = true, m = 50000 }, 3)
	check(sent_count("mods.xchg") == xs, "client: an answer from a peer other than the host is not taken")
	HUD = nil
	tick(10500)
	check(type(HUD) == "string" and HUD:find("no longer available") ~= nil, "client: no answer in 10 s is told")
	ev("nim_hold_r", { o = req.o, ok = true, m = 50000 }, 0)
	check(sent_count("mods.xchg") == xs, "client: a late answer starts nothing (the host gives the hold back by itself)")
	as_host()

-------------------------------------------------------------------------------
elseif name == "srv_world" then
	coop.is_dedicated = function() return true end
	BOOK[1] = 50000
	local a, target = hold_req("1:7:1", 1)
	local held, htarget = last("mods.nim_held")
	check(a.ok == true and a.m == 50000 and target == 1 and BOOK[1] == 0,
		"world server: the hold takes the price from his balance and is answered to him")
	check(held.p == 1 and held.h == "1:7:1" and held.g == "coonan" and held.m == 50000 and htarget == -1,
		"world server: it leads no map: the hold goes to the map servers")
	local grants = #GRANTS
	a = hold_req("1:7:1", 1)
	check(a.ok == true and #GRANTS == grants and sent_count("mods.nim_held") == 1, "world server: a repeated hold: its answer, no second charge")
	ev("nim_done", { p = 1, h = "1:7:1", c = 1 }, BRIDGE)
	ev("nim_done", { p = 1, h = "1:7:1", c = 0 }, BRIDGE)
	check(BOOK[1] == 0, "world server: a committed hold is spent; a refund after the commit gives nothing back")
	ev("nim_done", { p = 1, h = "1:7:1", c = 0 }, 2)
	check(BOOK[1] == 0 and counter("nimble_done_sender").failed == 1, "world server: a result from a player's seat is dropped")

	-- the map step refuses: the price goes back, once
	BOOK[1] = 50000
	hold_req("1:7:2", 1)
	ev("nim_done", { p = 1, h = "1:7:2", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: the map step's refund gives the price back")
	ev("nim_done", { p = 1, h = "1:7:2", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: ... once")

	-- two steps with a lost answer: no word from the map step in 60 s gives the price back; a commit after all takes it again
	hold_req("1:7:3", 1)
	check(BOOK[1] == 0, "world server: a hold whose answer is lost ...")
	tick(30000)
	check(BOOK[1] == 0, "world server: ... is kept 60 s ...")
	tick(31000)
	tick(1100)
	check(BOOK[1] == 50000, "world server: ... then given back")
	ev("nim_done", { p = 1, h = "1:7:3", c = 1 }, BRIDGE)
	check(BOOK[1] == 0, "world server: a commit after the refund takes the price again (the upgrade was made)")

	-- not enough money; a hold from a seat that plays nobody; malformed results
	BOOK[1] = 10
	local held_n = sent_count("mods.nim_held")
	a = hold_req("1:7:4", 1)
	check(a.ok == false and a.why == "poor" and BOOK[1] == 10 and sent_count("mods.nim_held") == held_n,
		"world server: a balance short of the price is refused, nothing goes to the map servers")
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "257:7:1", g = "coonan" }, BRIDGE)
	check(sent_count("mods.nim_hold_r") == n and counter("nimble_hold_sender").failed == 1, "world server: a hold asked by a map server is dropped")
	BOOK[1] = 50000
	hold_req("1:7:5", 1)
	ev("nim_done", { p = 1, h = "1:7:5", c = 7 }, BRIDGE)
	ev("nim_done", { p = 0 / 0, h = "1:7:5", c = 0 }, BRIDGE)
	ev("nim_done", { p = 1, h = "a:b", c = 0 }, BRIDGE)
	check(BOOK[1] == 0 and counter("nimble_done_shape").failed == 3, "world server: a result with bad fields is dropped")
	ev("nim_done", { p = 1, h = "1:7:5", c = 0 }, BRIDGE)
	check(BOOK[1] == 50000, "world server: ... the right one settles it")

	-- two players on two maps: the holds are theirs, each map server settles its own
	BOOK[1], BOOK[2] = 50000, 50000
	hold_req("1:7:9", 1)
	hold_req("1:7:9", 2)
	check(BOOK[1] == 0 and BOOK[2] == 0, "world server: two players on two maps hold, one op id each")
	ev("nim_done", { p = 2, h = "1:7:9", c = 0 }, BRIDGE2)
	ev("nim_done", { p = 1, h = "1:7:9", c = 1 }, BRIDGE)
	check(BOOK[1] == 0 and BOOK[2] == 50000, "world server: the refund of one does not touch the other")

	-- the gun step is not decided here: it goes to the map server of his map
	local g = gun(500)
	local commits = #CREATED
	ev("xchg", { k = "nimble", o = "1:7:20", h = "1:7:9", g = "coonan", w = g:id(), n = 600 }, 1)
	local fwd, ftarget = last("mods.xchg")
	check(fwd.k == "nimble" and fwd._peer == 1 and ftarget == BRIDGE and #CREATED == commits and not gone(g),
		"world server: the gun step is passed to the map server of his map, nothing is made here")

	---------------------------------------------------------------------------
	-- a server player's machine (peer 1): lost answers
	---------------------------------------------------------------------------
	local PLAYER = {
		decides_world = function() return false end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		actor_is_player = function() return true end,
		decider = function() return "other" end,
		where = function() return "here" end,
	}
	MODE, SELF = "client", 1
	modes.install(coop_mode, "srv_world", PLAYER)
	db.actor._money = 100000
	local p1 = gun(0, "wpn_pkm_siber")
	local asked = sent_count("mods.nim_hold")
	press("pkm")
	local req, raw = sent("mods.nim_hold")
	check(sent_count("mods.nim_hold") == asked + 1 and req.g == "pkm" and raw.target == 0 and #DIALOG == 0,
		"server player: a press asks the world server to hold the price, nothing moves here")
	ev("nim_hold_r", { o = req.o, ok = true, m = 100000 }, 0)
	local xreq, xraw = sent("mods.xchg")
	check(xreq.h == req.o and xreq.g == "pkm" and xreq.w == p1:id() and xraw.target == 0, "server player: the hold's ok sends the gun step")
	local xop = xreq.o
	NEWS = {}
	ev("xchg_r", { o = xop, ok = true, ["r.s"] = "wpn_pkm_zenit_siber", ["r.m"] = 100000 }, 0)
	check(news_ok("wpn_pkm_siber", 100000, "wpn_pkm_zenit_siber"), "server player: the answer tells the news of the exchange")
	-- the hold's answer is lost
	press("pkm")
	req = sent("mods.nim_hold")
	local xs = sent_count("mods.xchg")
	HUD = nil
	tick(10500)
	check(type(HUD) == "string" and HUD:find("no longer available") ~= nil and sent_count("mods.xchg") == xs,
		"server player: no answer to the hold in 10 s is told, no gun step")
	ev("nim_hold_r", { o = req.o, ok = true, m = 100000 }, 0)
	check(sent_count("mods.xchg") == xs, "server player: a late hold answer starts nothing (the world server gives it back in 60 s)")
	-- the gun step's answer is lost
	press("pkm")
	req = sent("mods.nim_hold")
	ev("nim_hold_r", { o = req.o, ok = true, m = 100000 }, 0)
	check(sent_count("mods.xchg") == xs + 1, "server player: the gun step goes ...")
	HUD = nil
	tick(10500)
	check(type(HUD) == "string" and HUD:find("no longer available") ~= nil, "server player: ... no answer in 10 s is told")
	MODE, SELF = "host", 0
	modes.install(coop_mode, "srv_world", OVERRIDES)

-------------------------------------------------------------------------------
elseif name == "srv_map" then
	coop.is_host = function() return false end
	coop.is_map_server = function() return true end
	coop.is_client = function() return true end
	local function held(p, h, kind, m, from) ev("nim_held", { p = p, h = h, g = kind or "coonan", m = m or 50000 }, from or 0) end
	local function dones() return sent_count("mods.nim_done") end

	held(1, "1:7:1")
	local g1 = gun(500)
	local x, xt = apply({ o = "1:7:2", h = "1:7:1", g = "coonan", w = g1:id(), n = 600 }, 1)
	local d, dt = last("mods.nim_done")
	check(x.ok == true and xt == 1 and x["r.s"] == CAMO and gone(g1) and has(CAMO, 500) == 1,
		"map server: the upgrade is made in his character, the old gun removed, answered to him")
	check(d.p == 1 and d.h == "1:7:1" and d.c == 1 and dt == 0, "map server: the commit goes to the world server")
	local nd = dones()
	local g2 = gun(500)
	x = apply({ o = "1:7:3", h = "1:7:1", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "unpaid" and not gone(g2) and dones() == nd, "map server: a used hold is refused and reports nothing")

	-- no hold here: refused and reported, and a hold that comes later is never applied
	x = apply({ o = "1:7:4", h = "1:7:5", g = "coonan", w = g2:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "unpaid" and d.h == "1:7:5" and d.c == 0 and dones() == nd + 1 and not gone(g2),
		"map server: a gun step without a hold is refused, the refund goes to the world server")
	held(1, "1:7:5")
	x = apply({ o = "1:7:6", h = "1:7:5", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "unpaid" and dones() == nd + 1 and not gone(g2), "map server: ... the hold that came later is not applied")

	-- not his gun; the map step fails; a stale hold; a wrong price: refused, refund reported
	local other = gun(0)
	held(1, "1:7:7")
	x = apply({ o = "1:7:8", h = "1:7:7", g = "coonan", w = other:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "weapon" and d.h == "1:7:7" and d.c == 0 and not gone(other), "map server: a gun not his: refused, refund reported")
	held(1, "1:7:9")
	local real_create = alife_create_item
	alife_create_item = function() error("no such section") end
	x = apply({ o = "1:7:10", h = "1:7:9", g = "coonan", w = g2:id(), n = 600 }, 1)
	alife_create_item = real_create
	d = last("mods.nim_done")
	check(x.ok == false and d.h == "1:7:9" and d.c == 0 and not gone(g2) and has(CAMO, 500) == 1,
		"map server: the upgrade cannot be made: nothing changes, refund reported")
	held(1, "1:7:11")
	tick(21000)
	x = apply({ o = "1:7:12", h = "1:7:11", g = "coonan", w = g2:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "late" and d.h == "1:7:11" and d.c == 0 and not gone(g2),
		"map server: a hold older than 20 s is refused (the world server's 60 s are far), refund reported")
	held(1, "1:7:13", "coonan", 1)
	x = apply({ o = "1:7:14", h = "1:7:13", g = "coonan", w = g2:id(), n = 600 }, 1)
	d = last("mods.nim_done")
	check(x.why == "price" and d.h == "1:7:13" and d.c == 0 and not gone(g2), "map server: a hold of another price: refused, refund reported")
	held(1, "1:7:15", "pkm")
	x = apply({ o = "1:7:16", h = "1:7:15", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "price" and not gone(g2), "map server: a hold of another upgrade: refused")

	-- a hold from anyone but the world server, or with bad fields, is not taken
	held(1, "1:7:17", "coonan", 50000, 3)
	x = apply({ o = "1:7:18", h = "1:7:17", g = "coonan", w = g2:id(), n = 600 }, 1)
	check(x.why == "unpaid" and not gone(g2), "map server: a hold that did not come from the world server is not taken")
	held(1, "1:7:19", "coonan", -5)
	held(1, "x;y", "coonan")
	check(counter("nimble_held_shape").failed == 2, "map server: a hold with bad fields is dropped")
	-- requests of the keeper's side are not taken here
	local n = sent_count("mods.nim_hold_r")
	ev("nim_hold", { o = "1:7:20", g = "coonan" }, 1)
	check(sent_count("mods.nim_hold_r") == n, "map server: it keeps no money: a hold is not answered here")

	-- two holds on one gun whose removal is on its way: one upgrade, the other refunded
	local real_release = alife_release_id
	local later = {}
	alife_release_id = function(id) later[#later + 1] = id; return true end
	local g3 = gun(500)
	held(1, "1:7:21")
	held(1, "1:7:22")
	local first = apply({ o = "1:7:23", h = "1:7:21", g = "coonan", w = g3:id(), n = 600 }, 1)
	x = apply({ o = "1:7:24", h = "1:7:22", g = "coonan", w = g3:id(), n = 600 }, 1)
	alife_release_id = real_release
	d = last("mods.nim_done")
	check(first.ok == true and x.why == "reserved" and d.h == "1:7:22" and d.c == 0 and has(CAMO, 500) == 2,
		"map server: one gun named by two holds: one upgrade, the other hold refunded")
	for _, id in ipairs(later) do release_id(id) end
	tick()
end

done("mods_xchg_nimble@" .. name)
