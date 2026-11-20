-- Dev 57 G6-3 (review m23:3): remote trade through a trading computer of Gadgets for Hideout Furniture. The computer lists
-- traders up to 150 m away and opens the stock trade; a client's deal and window need a permit of the decider of his level
-- (co-op: the host; server: the map server of his level, the world server passes the request on). The decider checks a real
-- computer, the player at it and the trader it lists, then keeps a grant the engine takes when the trade window opens
-- (coop_trade.cpp take_grant). The player's machine asks first and opens the window on the answer; its engine takes
-- window_grant. Single player and the co-op host's own trade: unchanged. Runs under every answer set (tests\lua\support\modes.lua).
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local bridge = 0x101
if name == "srv_map" then
	SELF = bridge
	coop.is_map_server = function() return true end
	coop.is_host = function() return false end
elseif name == "srv_world" then
	coop.is_dedicated = function() return true end
	coop.levels = { map_servers = function() return { { bridge = bridge } } end }
end

-- classes: what the engine's IsTrader / IsStalker read (an object, or nil and a class id)
local CLS_TRADER, CLS_STALKER, CLS_PHYS = 11, 12, 13
function IsTrader(o, c)
	if c ~= nil then return c == CLS_TRADER end
	return o ~= nil and o._kind == "trader"
end
function IsStalker(o, c)
	if c ~= nil then return c == CLS_STALKER end
	return o ~= nil and o._kind == "stalker"
end

local actor = make_actor(vec3(0, 0, 0))
actor._community = "actor_monolith"
local GO = getmetatable(actor)
TRADES = {}
function GO:clsid() return self._kind == "trader" and CLS_TRADER or (self._kind == "stalker" and CLS_STALKER or CLS_PHYS) end
function GO:has_info(i) return self._infos ~= nil and self._infos[i] == true end
function GO:is_trader() return self._trades == true end
function GO:name() return self._sec end
function GO:character_name() return self._sec end
function GO:character_community() return self._community end
function GO:bind_object(b) self.binder = b end
function GO:start_trade(who) TRADES[#TRADES + 1] = { trader = self:id(), who = who and who:id() } end
function character_community(obj) return obj:character_community() end

local communities = { stalker = true, monolith = true, ecolog = true, trader = true }
game_relations = {
	is_valid = function(faction) return communities[faction] == true end,
	is_factions_enemies = function(player, trader)
		return player == "stalker" and trader == "monolith"
	end,
}

bind_hf_base = { hf_binder_wrapper = { __init = function(self, obj) self.object = obj end } }
local ui_opened = {}
ui_trading_computer = { start_dialog = function(id) ui_opened[#ui_opened + 1] = id end }

-- the mod's own binder script (the copy G.A.M.M.A. loads), with a class() like luabind's
local function load_mod(module)
	local env = setmetatable({}, { __index = _G })
	env.class = function(key)
		return function(parent)
			local cls = {}
			cls.__index = cls
			setmetatable(cls, { __index = parent })
			env[key] = cls
		end
	end
	local script = assert(loadfile("temp/review/corpus/merged/" .. module .. ".script"))
	setfenv(script, env)()
	_G[module] = env
	return env
end
local tc = load_mod("bind_trading_computer")

-- coop_trust: counts every check; "log" lets a failed check pass, as the shipped default does
TRUST = {}
coop_trust = { pass = function(check, ok)
	TRUST[#TRUST + 1] = { check = check, ok = ok }
	return true
end }
local function trusted(check, ok)
	for i = #TRUST, 1, -1 do
		if TRUST[i].check == check then return TRUST[i].ok == ok end
	end
	return false
end

INI.placeable_trading_computer = { script_binding = "bind_trading_computer.init", ui_on_interaction = "ui_trading_computer.start_dialog" }
INI.placeable_lamp = { script_binding = "bind_light_furniture.init" }

start_all()
load_script("coop_npc_players")
AddScriptCallback("npc_on_net_destroy")
load_script("coop_mods_trade_computer")
coop_mods_trade_computer.on_game_start()
modes.install(coop_mode, name)

local function player_at(x)
	local se, o = spawn("coop_player_avatar", vec3(x, 0, 0), nil, { id = 500, kind = "stalker" })
	o._community = "actor_stalker"
	return o, se
end
local _, computer = spawn("placeable_trading_computer", vec3(0, 0, 0))
local _, lamp = spawn("placeable_lamp", vec3(1, 0, 0))
local _, trader = spawn("trader_far", vec3(100, 0, 0), nil, { kind = "trader" })
local _, trader2 = spawn("trader_two", vec3(50, 0, 0), nil, { kind = "trader" })
local _, beyond = spawn("trader_beyond", vec3(200, 0, 0), nil, { kind = "trader" })
local _, dead = spawn("trader_dead", vec3(30, 0, 0), nil, { kind = "trader", alive = false })
local _, mate = spawn("stalker_mate", vec3(30, 0, 0), nil, { kind = "stalker" })
mate._trades, mate._infos = true, { npcx_is_companion = true }
local _, plain = spawn("stalker_plain", vec3(30, 0, 0), nil, { kind = "stalker" })
local _, barman = spawn("stalker_barman", vec3(30, 0, 0), nil, { kind = "stalker" })
barman._trades = true
local _, arena = spawn("bar_arena_manager", vec3(30, 0, 0), nil, { kind = "trader" })
trader._community, trader2._community = "stalker", "ecolog"
beyond._community, dead._community, barman._community, arena._community = "trader", "trader", "trader", "trader"
local _, hostile = spawn("trader_hostile", vec3(80, 0, 0), nil, { kind = "trader" })
hostile._community = "monolith"
local _, unknown = spawn("trader_unknown", vec3(80, 0, 0), nil, { kind = "trader" })
unknown._community = "unregistered"
local _, other_player = spawn("coop_player_avatar", vec3(30, 0, 0), nil, { id = 501, kind = "stalker" })
local real_peer_of = coop.peer_of_avatar
coop.peer_of_avatar = function(id)
	if id == 501 then return 2 end
	return real_peer_of(id)
end

local function request(t, sender)
	NOW = NOW + 1000
	if name == "srv_map" and not sender then t._peer, sender = 1, 0 end
	coop_main.on_event("mods.tcomp_permit", coop_main.encode(t), sender or 1)
end
local function answers() return sent_count("mods.tcomp_permit_r") end
local function last_answer() return sent("mods.tcomp_permit_r") end

print("== trade computer (" .. name .. ")")
check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": no grant before any request")

if name == "hostplay" or name == "srv_map" then
	-- 1. refused far from the computer (20 m): the answer says no, the engine finds no grant
	player_at(20)
	local before = answers()
	request({ c = computer:id(), t = trader:id() })
	local a, raw = last_answer()
	check(answers() == before + 1 and a and a.ok == false and raw.target == 1, name .. ": request refused far from the computer")
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": no grant for a refused request")
	check(trusted("tcomp_permit_near", false), name .. ": the failed reach is recorded by coop_trust")

	-- 2. at the computer: granted; the engine takes it once, for that trader only
	player_at(2)
	request({ c = computer:id(), t = trader:id() })
	a, raw = last_answer()
	check(a and a.ok == true and a.t == trader:id() and a.c == computer:id() and a.ttl == 600000 and raw.target == 1,
		name .. ": a player at the computer gets the permit for the trader 100 m away")
	check(coop_mods_trade_computer.take_grant(1, trader2:id()) == nil, name .. ": the grant does not cover another trader")
	check(coop_mods_trade_computer.take_grant(2, trader:id()) == nil, name .. ": the grant does not cover another player")
	local c, ttl, reach = coop_mods_trade_computer.take_grant(1, trader:id())
	check(c == computer:id() and ttl == 600000 and reach == 6, name .. ": the engine takes computer, time and reach")
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": a grant is taken once")

	-- 3. a grant not taken in time is gone
	request({ c = computer:id(), t = trader:id() })
	NOW = NOW + 16000
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": a grant older than 15 s is gone")
	request({ c = computer:id(), t = trader:id() })
	NOW = NOW - 500000 -- a new level: the clock went back
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": a grant from an older clock is gone")
	NOW = NOW + 500000

	-- 4. what the computer would not list, or no computer at all
	local function refused(t, what)
		local n = answers()
		request(t)
		local r = last_answer()
		check(answers() == n + 1 and r and r.ok == false and coop_mods_trade_computer.take_grant(1, tonumber(t.t) or 0) == nil,
			name .. ": " .. what)
	end
	refused({ c = computer:id(), t = beyond:id() }, "a trader beyond the mod's range of the computer is refused")
	refused({ c = lamp:id(), t = trader:id() }, "another piece of furniture is no computer")
	refused({ c = trader2:id(), t = trader:id() }, "a trader is no computer")
	refused({ c = computer:id(), t = other_player:id() }, "another player's character is no trader")
	refused({ c = computer:id(), t = 500 }, "his own character is no trader")
	refused({ c = computer:id(), t = dead:id() }, "a dead trader is refused")
	refused({ c = computer:id(), t = mate:id() }, "a companion is refused (the mod does not list it)")
	refused({ c = computer:id(), t = plain:id() }, "a stalker who does not trade is refused")
	refused({ c = computer:id(), t = arena:id() }, "the mod's black list is refused")
	refused({ c = computer:id(), t = 4321 }, "an id of nothing is refused")
	refused({ c = computer:id(), t = computer:id() }, "the computer is no trader")
	refused({ c = computer:id(), t = hostile:id() }, "a trader hostile to the requester within range is refused")
	check(trusted("tcomp_permit_trader", false), name .. ": the faction refusal is recorded by coop_trust")
	refused({ c = computer:id(), t = unknown:id() }, "a trader in an unknown faction is refused")
	local player = OBJ[500]
	player._community = "actor_none"
	refused({ c = computer:id(), t = trader:id() }, "a requester in an unknown faction is refused")
	player._community = "actor_stalker"
	request({ c = computer:id(), t = trader2:id() })
	check(last_answer().ok == true and coop_mods_trade_computer.take_grant(1, trader2:id()) == computer:id(),
		name .. ": a neutral trader within range is granted")

	request({ c = computer:id(), t = trader:id() })
	SendScriptCallback("npc_on_net_destroy", trader2)
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == computer:id(),
		name .. ": another NPC leaving the map keeps the player's grant")
	request({ c = computer:id(), t = trader:id() })
	check(last_answer().ok == true, name .. ": the peer has a fresh grant before leaving")
	SendScriptCallback("npc_on_net_destroy", player)
	release_id(player:id())
	player_at(2) -- same peer and avatar ids can return before the grant's normal expiry
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": a returning peer cannot take its old grant")

	request({ c = computer:id(), t = barman:id() })
	local b = last_answer()
	check(b and b.ok == true, name .. ": a stalker who trades is listed and granted")
	check(coop_mods_trade_computer.take_grant(1, barman:id()) == computer:id(), name .. ": its grant is taken")

	-- 5. numbers out of range and junk: refused, never an error
	local errors = coop_mods_core.stats.errors
	refused({ c = "abc", t = trader:id() }, "a computer id that is no number is refused")
	refused({ c = computer:id(), t = trader:id() + 0.5 }, "a fractional trader id is refused")
	refused({ c = 0, t = trader:id() }, "id 0 is refused")
	refused({ c = 70000, t = trader:id() }, "an id out of range is refused")
	refused({ t = trader:id() }, "a request without a computer is refused")
	check(coop_mods_core.stats.errors == errors, name .. ": junk raises no Lua error (" .. coop_mods_core.stats.errors - errors .. ")")

	-- 6. an emission or a psi storm: the computer has no connection
	xr_conditions = { surge_started = function() return true end }
	refused({ c = computer:id(), t = trader:id() }, "no permit during an emission")
	xr_conditions = nil

	-- 7. only a player's request through the mode's door
	local n = answers()
	if name == "hostplay" then
		request({ c = computer:id(), t = trader:id() }, 0)
		check(answers() == n and coop_mods_trade_computer.take_grant(0, trader:id()) == nil, name .. ": seat 0 never asks (its trade is local)")
	else
		request({ c = computer:id(), t = trader:id(), _peer = 1 }, 2)
		check(answers() == n and coop_mods_trade_computer.take_grant(1, trader:id()) == nil,
			name .. ": a request that bypassed the world server is dropped")
	end

	-- 8. a refused check fails closed even when coop_trust is in "log": no permit is handed out by a log pass
	player_at(40)
	TRUST = {}
	request({ c = computer:id(), t = trader:id() })
	check(trusted("tcomp_permit_near", false) and last_answer().ok == false, name .. ": a failed check in log mode still refuses")
	player_at(2)

	-- 8b. Review A-REV-E-2 finding 3: these checks refuse in every trust mode, so the shipped settings name them "refuse" and the
	-- real coop_trust's line says "refused", never "would be refused: let through"
	local shipped = { default = "log" }
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	local text = fh and fh:read("*a") or ""
	if fh then fh:close() end
	for key, value in (text:match("%[coop_trust%]([^%[]*)") or ""):gmatch("\n([%w_]+)%s*=%s*(%w+)") do shipped[key] = value end
	for _, check_name in ipairs({ "tcomp_permit_ids", "tcomp_permit_computer", "tcomp_permit_near", "tcomp_permit_trader",
		"tcomp_permit_range", "tcomp_permit_signal" }) do
		check(shipped[check_name] == "refuse", name .. ": the shipped policy refuses " .. check_name)
	end
	check(shipped.default == "log", name .. ": the shipped default stays log")
	local stub_trust = coop_trust
	local real_trust = load_script("coop_trust")
	real_trust.reset_for_test(shipped)
	local lines = #LOG
	player_at(40)
	request({ c = computer:id(), t = trader:id() })
	check(last_answer().ok == false, name .. ": shipped policy, far from the computer: refused as before")
	player_at(2)
	request({ c = lamp:id(), t = trader:id() })
	check(last_answer().ok == false, name .. ": shipped policy, no computer: refused as before")
	local refused_lines, let = 0, 0
	for i = lines + 1, #LOG do
		local l = tostring(LOG[i])
		if l:find("tcomp_permit_", 1, true) and l:find("(refused,", 1, true) then refused_lines = refused_lines + 1 end
		if l:find("let through", 1, true) then let = let + 1 end
	end
	check(refused_lines == 2 and let == 0, name .. ": both refusals are logged as refused, none as let through (" .. refused_lines
		.. ", " .. let .. ")")
	coop_trust = stub_trust

	-- 9. the host's own player (co-op): his trade is local, like single player
	if name == "hostplay" then
		local sent_before, trades_before = sent_count("mods.tcomp_permit"), #TRADES
		ui_trading_computer.start_dialog(computer:id())
		tc.open_trade_by_id(trader:id())
		check(#TRADES == trades_before + 1 and TRADES[#TRADES].trader == trader:id() and sent_count("mods.tcomp_permit") == sent_before,
			name .. ": the host's own player opens the trade as single player does")
	end
elseif name == "srv_world" then
	player_at(2)
	request({ c = computer:id(), t = trader:id() })
	local fwd, raw = sent("mods.tcomp_permit")
	check(fwd and fwd._peer == 1 and fwd.c == computer:id() and fwd.t == trader:id() and raw.target == bridge
		and answers() == 0, name .. ": the world server passes the request to the map server of his level")
	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. ": the world server keeps no grant")
elseif name == "none" then
	local trades_before = #TRADES
	ui_trading_computer.start_dialog(computer:id())
	tc.open_trade_by_id(trader:id())
	check(#TRADES == trades_before + 1 and TRADES[#TRADES].trader == trader:id() and #SENT == 0,
		name .. ": single player opens the trade at once, nothing is sent")
	check(ui_opened[#ui_opened] == computer:id(), name .. ": the computer's window opens as stock")
	check(coop_mods_trade_computer.window_grant(trader:id()) == nil, name .. ": single player keeps no window grant")
end

if name ~= "none" then
	-- the player's machine: a co-op client, a server player (same answers of the facade)
	MODE, SELF = "client", 1
	coop.is_map_server = function() return false end
	modes.install(coop_mode, name, {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
		where = function() return "here" end, decider = function() return "other" end,
	})
	local function answer(t) coop_main.on_event("mods.tcomp_permit_r", coop_main.encode(t), 0) end
	local asks = function() return sent_count("mods.tcomp_permit") end

	-- the actor does not stand at the computer whose window he opened (another script opens a trade): the mod's own path,
	-- the stock rules decide
	ui_trading_computer.start_dialog(computer:id())
	local trades_before, asked_before = #TRADES, asks()
	actor._pos = vec3(40, 0, 0)
	tc.open_trade_by_id(trader:id())
	check(#TRADES == trades_before + 1 and asks() == asked_before, name .. " client: away from the computer the stock path opens the trade")
	actor._pos = vec3(0, 0, 0)

	-- through the computer: ask first, open on the answer
	ui_trading_computer.start_dialog(computer:id())
	check(ui_opened[#ui_opened] == computer:id(), name .. " client: the computer's window opens as stock")
	trades_before = #TRADES
	tc.open_trade_by_id(trader:id())
	local q, raw = sent("mods.tcomp_permit")
	check(#TRADES == trades_before and q and q.c == computer:id() and q.t == trader:id() and raw.target == 0 and asks() == asked_before + 1,
		name .. " client: the trade waits for the decider's permit")
	tc.open_trade_by_id(trader:id())
	check(asks() == asked_before + 1, name .. " client: a second click while waiting asks nothing more")

	answer({ ok = true, c = computer:id(), t = trader2:id(), ttl = 600000 })
	check(#TRADES == trades_before, name .. " client: an answer for another trader opens nothing")
	answer({ ok = false, t = trader:id(), r = "near" })
	check(#TRADES == trades_before and HUD ~= nil and coop_mods_trade_computer.window_grant(trader:id()) == nil,
		name .. " client: a refusal opens nothing and says so")

	HUD = nil
	tc.open_trade_by_id(trader:id())
	check(asks() == asked_before + 2, name .. " client: after a refusal the player may ask again")
	answer({ ok = true, c = computer:id(), t = trader:id(), ttl = 600000 })
	check(#TRADES == trades_before + 1 and TRADES[#TRADES].trader == trader:id(), name .. " client: the permit opens the trade")
	local wc, left = coop_mods_trade_computer.window_grant(trader:id())
	check(wc == computer:id() and type(left) == "number" and left > 0 and left <= 600000,
		name .. " client: the engine takes the window grant (computer, ms left)")
	check(coop_mods_trade_computer.window_grant(trader:id()) == nil, name .. " client: the window grant is taken once")

	answer({ ok = true, c = computer:id(), t = trader:id(), ttl = 600000 })
	check(#TRADES == trades_before + 1, name .. " client: an answer nobody waits for opens nothing")

	tc.open_trade_by_id(trader2:id())
	NOW = NOW + 16000
	answer({ ok = true, c = computer:id(), t = trader2:id(), ttl = 600000 })
	check(#TRADES == trades_before + 1, name .. " client: an answer after 15 s opens nothing")

	tc.open_trade_by_id(trader2:id())
	local errors = coop_mods_core.stats.errors
	answer({ ok = true, c = "x", t = trader2:id(), ttl = "y" })
	answer({ ok = true, c = computer:id(), t = 0 / 0, ttl = 1e300 })
	check(#TRADES == trades_before + 1 and coop_mods_core.stats.errors == errors, name .. " client: junk answers open nothing, no error")
	answer({ ok = true, c = computer:id(), t = trader2:id(), ttl = 1e300 })
	local _, left2 = coop_mods_trade_computer.window_grant(trader2:id())
	check(#TRADES == trades_before + 2 and left2 ~= nil and left2 <= 600000, name .. " client: the window time is bounded")

	check(coop_mods_trade_computer.take_grant(1, trader:id()) == nil, name .. " client: a player's machine keeps no decider grant")
end

local labels = table.concat(coop_mods_core.wrapped, ",")
check(labels:find("bind_trading_computer.open_trade_by_id", 1, true) ~= nil
	and labels:find("ui_trading_computer.start_dialog", 1, true) ~= nil, name .. ": the wrappers show in coop_status")

done("trade computer (" .. name .. ")")
