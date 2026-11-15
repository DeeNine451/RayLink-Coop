-- Anomaly Coop, the fare of a level change from afar (scripts\coop_transition_fare.script).
-- Owner 2026-11-16: "in an ordinary co-op, when somebody goes to another map and the vote starts, and the others are far away, they
-- are offered to pay a sum, by the logic of the fast travel mod (1.7 RU a metre or so), to go to the other location together with the
-- one who proposes; so that nobody abuses the transitions. Offered when a world is made, on by default, can be switched off: then
-- it is as it is now."
-- The real script on stand-ins of the engine, of coop_economy_core (the rule, the players) and of Fair Fast Travel (its price).
-- Run: tools\test_lua.cmd transition_fare
local ROOT = "gamedata/"

FAILS, PASSES = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function readfile(p)
	local fh = io.open(p, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

NOW = 100000

-- A player's machine. o: money, rule (transition_fare), radius (gather_radius), fft (a price table of Fair Fast Travel or false),
-- active (a session), pos (my position), peers = { [peer] = { x, y, z } }.
local function machine(o)
	o = o or {}
	local M = { log = {}, tips = {}, money = o.money or 5000, paid = {}, rules = { transition_fare = o.rule, gather_radius = o.radius },
		peers = o.peers or {}, pos = o.pos or { x = 0, y = 0, z = 0 }, active = o.active ~= false, fft_calls = 0 }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env
	env.printf = function(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		M.log[#M.log + 1] = ok and line or tostring(fmt)
		if os.getenv("VERBOSE") then print("    " .. M.log[#M.log]) end
	end
	env.time_global = function() return NOW end
	env.game = { translate_string = function(id) return id end }
	env.level = { name = function() return "l01_escape" end }
	env.coop = { is_active = function() return M.active end }
	env.db = { actor = {
		money = function() return M.money end,
		give_money = function(_, n)
			if M.break_money then error("the actor is gone") end
			M.money = M.money + n
			M.paid[#M.paid + 1] = -n
		end,
		position = function() return M.pos end,
	} }
	env.coop_economy_core = {
		rule = function(key)
			local v = M.rules[key]
			if v == nil and key == "transition_fare" then return true end
			if v == nil and key == "gather_radius" then return 20 end
			return v
		end,
		player = function(peer)
			local p = M.peers[peer]
			return p and { id = peer, pos = p } or nil
		end,
		tip = function(text) M.tips[#M.tips + 1] = text end,
	}
	if o.fft ~= false then
		-- game_fast_travel.cost_to_travel(dist, tt, is_npc, map_coef): the mod's own coefficients (0 = that kind of travel is free),
		-- twice the base without its progressive cost, rounded to 100 and 100 at least (its nice_round_numbers)
		local coefs = o.fft or { ft = 0.85, gt = 1.5 }
		env.game_fast_travel = {
			travel_cost_coef = function(tt) return coefs[tt] or 0 end,
			get_map_hazard_coef = function(a, b) M.hazard_asked = { a, b } return 1 end,
			cost_to_travel = function(dist, tt, is_npc, map_coef)
				M.fft_calls = M.fft_calls + 1
				local base = dist * (coefs[tt] or 0)
				local cost = math.floor((base + base * (map_coef or 1)) / 100 + 0.5) * 100
				return cost < 100 and 100 or cost
			end,
		}
	end
	local src = readfile(ROOT .. "scripts/coop_transition_fare.script")
	local mod = setmetatable({}, { __index = env })
	env.coop_transition_fare = mod
	if not src then
		print("  the script is not there")
		return M
	end
	local f, err = loadstring(src, "@coop_transition_fare.script")
	if not f then
		print("  syntax error: " .. tostring(err))
		return M
	end
	setfenv(f, mod)
	local ok, e = pcall(f)
	if not ok then print("  load error: " .. tostring(e)) end
	M.F = mod
	return M
end

local function has(list, part)
	for _, s in ipairs(list) do if tostring(s):find(part, 1, true) then return true end end
	return false
end

-- a board of an exit as coop.transition() gives it: player 0 waits at the exit, I am player 1, `dist` m from it
local function exit_board(dist, o)
	o = o or {}
	return { state = o.state or "waiting", kind = "exit", level = o.level or "l05_bar", ready = 1, total = 2,
		rows = { { peer = 0, mark = "ready", dist = 2 }, { peer = 1, mark = o.consent and "ready" or "away", dist = dist, consent = o.consent or nil } },
		me = { peer = 1, host = false, in_zone = o.in_zone or false, ready = o.consent or false, dist = dist, confirm = false, consent = o.consent or false } }
end

-- a trip (a guide, a fast travel to another map): player 0 asked, I am player 1 and owe an answer
local function trip_board(o)
	o = o or {}
	local mine_ready = o.agreed or false
	return { state = o.state or "waiting", kind = "guide", level = o.level or "l05_bar", ready = mine_ready and 2 or 1, total = 2,
		rows = o.rows or { { peer = 0, mark = "ready" }, { peer = 1, mark = mine_ready and "ready" or "away" } },
		me = { peer = 1, host = false, in_zone = false, ready = mine_ready, confirm = not mine_ready, consent = false } }
end

-- ================================================================ 1. the price
print("== the price")
do
	local M = machine()
	local F = M.F
	check(F ~= nil and type(F.quote) == "function", "the script loads")
	check(F.enabled() == true, "the rule is on by default")
	local q = F.quote(exit_board(1000))
	check(q and q.cost == 1700 and q.dist == 1000, "1000 m from the exit: Fair Fast Travel's own price for that distance, 1700 RU (" .. tostring(q and q.cost) .. ")")
	check(q and q.enough == true and q.money == 5000, "he has the money")
	check(M.hazard_asked and M.hazard_asked[1] == "l01_escape" and M.hazard_asked[2] == "l05_bar", "the mod's hazard of the two maps is asked as its own trip asks it")
	check(F.quote(exit_board(20)) == nil and F.quote(exit_board(3)) == nil, "within the gather radius of the exit: free")
	NOW = NOW + 1000
	local q2 = F.quote(exit_board(21))
	check(q2 and q2.cost == 100, "a step outside it: the mod's least price, 100 RU (" .. tostring(q2 and q2.cost) .. ")")
	NOW = NOW + 1000
	check(F.quote(exit_board(nil)) == nil, "a distance this machine does not know costs nothing")
	check(F.quote(nil) == nil and F.quote({}) == nil, "no board: no price")
end
do
	local M = machine({ fft = { ft = 0, gt = 1.5 } })
	local q = M.F.quote(exit_board(1000))
	check(q and q.cost == 3000, "the fast travel is free in the mod's settings: its guide's price (" .. tostring(q and q.cost) .. ")")
end
do
	local M = machine({ fft = { ft = 0, gt = 0 } })
	local q = M.F.quote(exit_board(1000))
	check(q and q.cost == 1700, "every fare of the mod is off: 1.7 RU a metre (" .. tostring(q and q.cost) .. ")")
end
do
	local M = machine({ fft = false })
	local q = M.F.quote(exit_board(1234))
	check(q and q.cost == 2100, "without the mod: 1.7 RU a metre, rounded to 100 (" .. tostring(q and q.cost) .. ")")
	NOW = NOW + 1000
	local q2 = M.F.quote(exit_board(30))
	check(q2 and q2.cost == 100, "and 100 RU at least (" .. tostring(q2 and q2.cost) .. ")")
end
do
	local M = machine({ radius = 100 })
	check(M.F.quote(exit_board(90)) == nil, "the world's gather radius is the free distance (100 m: 90 m is free)")
	NOW = NOW + 1000
	check(M.F.quote(exit_board(150)) ~= nil, "150 m is not")
end
do
	local M = machine({ rule = false })
	check(M.F.enabled() == false and M.F.quote(exit_board(1000)) == nil, "the world's rule off: as before, no price")
	local M2 = machine({ active = false })
	check(M2.F.enabled() == false and M2.F.quote(exit_board(1000)) == nil, "no session: no price")
end
do
	-- the price is not counted anew every frame
	local M = machine()
	local t = exit_board(1000)
	for _ = 1, 60 do M.F.quote(t) NOW = NOW + 16 end
	check(M.fft_calls <= 4, "60 frames of the hint ask the mod a few times, not 60 (" .. M.fft_calls .. ")")
end

-- ================================================================ 2. the yes and the go
print("== the yes and the go")
do
	local M = machine({ money = 5000 })
	local F = M.F
	local t = exit_board(1000)
	F.step(t)
	check(F.agree(t) == true, "he holds the key with the money in his pocket: the command may go")
	check(#M.paid == 0 and M.money == 5000, "nothing is taken at the yes")
	for _ = 1, 20 do NOW = NOW + 500 F.step(exit_board(1000, { consent = true })) end
	check(#M.paid == 0, "nothing while the group waits, however long")
	NOW = NOW + 500
	F.step(exit_board(1000, { consent = true, state = "going" }))
	check(#M.paid == 1 and M.paid[1] == 1700 and M.money == 3300, "the group goes: the fare is taken, once (" .. tostring(M.paid[1]) .. ")")
	check(has(M.tips, "1700"), "and he is told what it cost (" .. tostring(M.tips[#M.tips]) .. ")")
	for _ = 1, 10 do NOW = NOW + 100 F.step(exit_board(1000, { consent = true, state = "going" })) end
	check(#M.paid == 1, "the go lasts a second: the fare is not taken again")
end
do
	local M = machine({ money = 500 })
	local F = M.F
	local t = exit_board(1000)
	F.step(t)
	check(F.agree(t) == false, "not enough money: the command does not go")
	check(has(M.tips, "1700") and has(M.tips, "500"), "he is told how much it takes and how much he has (" .. tostring(M.tips[#M.tips]) .. ")")
	NOW = NOW + 500
	F.step(exit_board(1000, { state = "going" }))
	check(#M.paid == 0 and M.money == 500, "and he pays nothing when the others go without him")
end
do
	-- taking the yes back costs nothing
	local M = machine()
	local F = M.F
	F.step(exit_board(1000))
	F.agree(exit_board(1000))
	F.withdraw()
	NOW = NOW + 500
	F.step(exit_board(1000, { state = "going" }))
	check(#M.paid == 0, "he took his yes back: the go costs him nothing")
end
do
	-- the one who waited went away: the board is gone, nothing is owed; a new wait is a new yes
	local M = machine()
	local F = M.F
	F.step(exit_board(1000))
	F.agree(exit_board(1000))
	for _ = 1, 30 do NOW = NOW + 500 F.step(nil) end
	F.step(exit_board(1000, { consent = false }))
	NOW = NOW + 500
	F.step(exit_board(1000, { consent = false, state = "going" }))
	check(#M.paid == 0, "the wait ended and another began without his yes: nothing is taken")
end
do
	-- the board blinks (the host was silent for a moment): the yes is still his
	local M = machine()
	local F = M.F
	F.step(exit_board(1000))
	F.agree(exit_board(1000))
	NOW = NOW + 500
	F.step(nil)
	NOW = NOW + 500
	F.step(exit_board(1000, { consent = true, state = "going" }))
	check(#M.paid == 1 and M.paid[1] == 1700, "a board that was gone for a second does not make the trip free")
end
do
	-- he walked on after the yes
	local M = machine()
	local F = M.F
	F.step(exit_board(1000))
	F.agree(exit_board(1000))
	NOW = NOW + 5000
	F.step(exit_board(400, { consent = true, state = "going" }))
	check(#M.paid == 1 and M.paid[1] == 700, "he came closer meanwhile: the price of where he stands at the go (" .. tostring(M.paid[1]) .. ")")
	local M2 = machine()
	M2.F.step(exit_board(400))
	M2.F.agree(exit_board(400))
	NOW = NOW + 5000
	M2.F.step(exit_board(2000, { consent = true, state = "going" }))
	check(#M2.paid == 1 and M2.paid[1] == 700, "he walked away meanwhile: never more than he agreed to (" .. tostring(M2.paid[1]) .. ")")
	local M3 = machine()
	M3.F.step(exit_board(1000))
	M3.F.agree(exit_board(1000))
	NOW = NOW + 5000
	M3.F.step(exit_board(2, { in_zone = true, consent = false, state = "going" }))
	check(#M3.paid == 0, "he walked to the exit himself: free")
	-- a route into the exit (a restrictor that leads into it) may lie far from the exit's own zone: he stands in it, that is "at the exit"
	local M5 = machine()
	M5.F.step(exit_board(1000))
	M5.F.agree(exit_board(1000))
	NOW = NOW + 5000
	M5.F.step(exit_board(300, { in_zone = true, consent = false, state = "going" }))
	check(#M5.paid == 0, "he walked into a route of the exit, 300 m from its zone: free as well")
	local M4 = machine()
	M4.F.step(exit_board(1000))
	M4.F.agree(exit_board(1000))
	NOW = NOW + 5000
	M4.F.step(exit_board(15, { consent = true, state = "going" }))
	check(#M4.paid == 0, "he is within the gather radius at the go: free")
end
do
	-- he spent the money meanwhile
	local M = machine({ money = 2000 })
	M.F.step(exit_board(1000))
	check(M.F.agree(exit_board(1000)) == true, "(he agrees with 2000 RU)")
	M.money = 300
	NOW = NOW + 5000
	M.F.step(exit_board(1000, { consent = true, state = "going" }))
	check(#M.paid == 1 and M.paid[1] == 300 and M.money == 0, "he spent it meanwhile: what he has is taken, never below zero")
end
do
	-- near the exit the yes is free and nothing is remembered
	local M = machine()
	M.F.step(exit_board(12))
	check(M.F.agree(exit_board(12)) == true, "near the exit: the key goes")
	NOW = NOW + 500
	M.F.step(exit_board(12, { consent = true, state = "going" }))
	check(#M.paid == 0, "and costs nothing")
end
do
	-- a failing actor must not break the HUD's frame
	local M = machine()
	M.F.step(exit_board(1000))
	M.F.agree(exit_board(1000))
	M.break_money = true
	NOW = NOW + 500
	local ok = pcall(M.F.step, exit_board(1000, { consent = true, state = "going" }))
	check(ok and has(M.log, "!"), "the money call fails: logged, no error out of step")
end

-- ================================================================ 3. a trip (a guide, a fast travel to another map)
print("== a trip")
do
	-- player 0 asked for a trip and stands 800 m from me
	local M = machine({ peers = { [0] = { x = 800, y = 0, z = 0 } } })
	local F = M.F
	local t = trip_board()
	F.step(t)
	local q = F.quote(t)
	check(q and q.cost == 1400 and math.abs(q.dist - 800) < 1, "a trip: the price of the way to the one who asked, 800 m = 1400 RU (" .. tostring(q and q.cost) .. ")")
	check(F.agree(t) == true and #M.paid == 0, "the yes costs nothing yet")
	NOW = NOW + 2000
	F.step(trip_board({ agreed = true, state = "going" }))
	check(#M.paid == 1 and M.paid[1] == 1400, "everybody agreed, the group goes: the fare is taken")
end
do
	local M = machine({ peers = { [0] = { x = 10, y = 0, z = 5 } } })
	local t = trip_board()
	M.F.step(t)
	check(M.F.quote(t) == nil and M.F.agree(t) == true, "next to the one who asked: free")
	NOW = NOW + 2000
	M.F.step(trip_board({ agreed = true, state = "going" }))
	check(#M.paid == 0, "nothing at the go")
end
do
	-- the one who asked is the one this machine saw ready FIRST; a friend next to me who agreed later is not him
	local M = machine({ peers = { [0] = { x = 800, y = 0, z = 0 }, [2] = { x = 3, y = 0, z = 0 } } })
	local F = M.F
	F.step(trip_board({ rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" }, { peer = 2, mark = "away" } } }))
	NOW = NOW + 1000
	local later = trip_board({ rows = { { peer = 0, mark = "ready" }, { peer = 1, mark = "away" }, { peer = 2, mark = "ready" } } })
	F.step(later)
	local q = F.quote(later)
	check(q and q.cost == 1400, "a friend beside me who said yes does not make my way free (" .. tostring(q and q.cost) .. ")")
end
do
	-- the trip did not happen (somebody did not answer): the board is gone, nothing is taken
	local M = machine({ peers = { [0] = { x = 800, y = 0, z = 0 } } })
	M.F.step(trip_board())
	M.F.agree(trip_board())
	for _ = 1, 30 do NOW = NOW + 500 M.F.step(nil) end
	check(#M.paid == 0, "a trip that lapsed costs nothing")
end
do
	local M = machine({ peers = {} })
	local t = trip_board()
	M.F.step(t)
	check(M.F.quote(t) == nil and M.F.agree(t) == true, "the one who asked is not seen from here: no price, the key goes")
end

-- ================================================================ 4. the hint
print("== the hint")
do
	local M = machine({ money = 5000 })
	local t = exit_board(1000)
	M.F.step(t)
	local s = M.F.hint("consent", t, "hold [F] - go with the group")
	check(s:find("hold [F] - go with the group", 1, true) and s:find("1700", 1, true), "the hint names the price (" .. s .. ")")
	check(M.F.hint("cancel", t, "hold [F] - cancel") == "hold [F] - cancel", "taking it back has no price")
	NOW = NOW + 1000
	check(M.F.hint("consent", exit_board(10), "hold [F] - go with the group") == "hold [F] - go with the group", "near the exit: the hint as it was")
	local P = machine({ money = 200 })
	P.F.step(t)
	local sp = P.F.hint("consent", t, "hold [F] - go with the group")
	check(sp:find("1700", 1, true) and sp:find("200", 1, true) and not sp:find("hold", 1, true), "not enough money: what it takes and what he has, no key (" .. sp .. ")")
	local O = machine({ rule = false })
	check(O.F.hint("consent", t, "hold [F] - go with the group") == "hold [F] - go with the group", "the rule off: the hint as it was")
end

print(("== %d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
