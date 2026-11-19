-- Anomaly Coop test (TZ v2 6.4 row 6, 2026-11-18): world m_data keys of coop_economy_mdata (Hideout Furniture's stash and
-- workbench lists, Slight's rewards, the traders' reputation ...) over 12 000 bytes go to the clients in pieces
-- (coop_mods_core.send_big) instead of not at all, a change after a big value still arrives, and a value that cannot be sent
-- is logged with its key and size and tried again (its signature is kept only for a value that went). Not shipped.
-- Run: tools\test_lua.cmd mdata_world_big
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function setup(nclients, with_mods_core)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = { x = p * 2, y = 0, z = 0 } end
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
		if with_mods_core ~= false then
			local facade = load_script(W, "coop_mode")
			modes.live(facade, function(name) return load_script(W, name) end)
			load_script(W, "coop_mods_core")
		end
	end
	for p, W in pairs(WORLDS) do start_world(W) end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

-- a stash list of about `bytes` packed bytes: id -> section name, as Hideout Furniture keeps it
local function big_list(bytes, tag)
	local t, n = {}, 0
	local name = string.rep("x", 40) .. (tag or "")
	for i = 1, math.ceil(bytes / 50) do
		t[1000 + i] = name
		n = n + 1
	end
	return t, n
end

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function logged(W, pattern)
	for _, s in ipairs(W.LOG) do
		if s:find(pattern) then return s end
	end
	return nil
end

-------------------------------------------------------------------------------
section("a list of 30 000 bytes arrives whole, and a change after it arrives")
do
	local H, A, B = setup(2)
	tick(H, 2100) deliver_all() -- baseline
	local list, n = big_list(30000)
	H.MDATA.player_created_stashes = list
	local packed = H.coop_economy_core.pack(list)
	check(#packed > 30000, "the list is over 30 000 bytes packed (" .. #packed .. ")")
	tick(H, 2100) deliver_all()
	check(count(A.MDATA.player_created_stashes) == n and A.MDATA.player_created_stashes[1001] == list[1001],
		"client A got the whole list (" .. count(A.MDATA.player_created_stashes) .. " of " .. n .. " entries)")
	check(count(B.MDATA.player_created_stashes) == n, "client B got the whole list")
	-- a change after it: one more stash
	H.MDATA.player_created_stashes[99] = "stash_new"
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes and A.MDATA.player_created_stashes[99] == "stash_new"
		and count(A.MDATA.player_created_stashes) == n + 1, "a change after the big value arrives")
	-- it shrinks under the limit: the one-event path, still arriving
	H.MDATA.player_created_stashes = { [7] = "stash_small" }
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes and A.MDATA.player_created_stashes[7] == "stash_small"
		and count(A.MDATA.player_created_stashes) == 1, "a small value after the big one arrives")
	check(H.coop_economy_mdata._stats().oversize == 0, "nothing counted as not sent")
	-- a client cannot write a world key through the pieces either
	A.coop_mods_core.send_big("economy_wmd", "player_created_stashes\n{n1;s1:x}", 0)
	deliver_all()
	check(H.MDATA.player_created_stashes[7] == "stash_small" and count(H.MDATA.player_created_stashes) == 1,
		"clients cannot write world keys in pieces")
	-- a key nobody registered is not written on a client
	H.coop_mods_core.send_big("economy_wmd", "not_a_world_key\n{n1;s1:x}", 1)
	deliver_all()
	check(A.MDATA.not_a_world_key == nil, "an unknown key is not written")
end

-------------------------------------------------------------------------------
section("a value that cannot be sent is logged with its key and size, and goes when it can")
do
	local H, A = setup(1, false) -- no coop_mods_core: the pieces cannot go
	tick(H, 2100) deliver_all()
	local list = big_list(20000)
	H.MDATA.workshop_stashes = list
	tick(H, 2100) deliver_all()
	check(A.MDATA.workshop_stashes == nil, "without the chunker the big value does not arrive")
	local line = logged(H, "workshop_stashes")
	check(line ~= nil and line:find("%d%d%d%d%d bytes") ~= nil, "logged with the key and the size: " .. tostring(line))
	check(H.coop_economy_mdata._stats().oversize == 1, "counted once")
	local lines = #H.LOG
	tick(H, 2100) deliver_all()
	check(#H.LOG == lines and H.coop_economy_mdata._stats().oversize == 1, "the same value is not logged again")
	-- it shrinks: it goes (the signature of the unsent value was not kept)
	H.MDATA.workshop_stashes = { [3] = "wb" }
	tick(H, 2100) deliver_all()
	check(A.MDATA.workshop_stashes and A.MDATA.workshop_stashes[3] == "wb", "the smaller value arrives")
end

-------------------------------------------------------------------------------
section("a send that failed is tried again on the next look")
do
	local H, A = setup(1)
	tick(H, 2100) deliver_all()
	H.MDATA.player_created_stashes = { [5] = "stash_a" }
	H.ACTIVE_SEND_FAIL = true
	local real = H.coop.send_event
	H.coop.send_event = function() return false, "queue full" end
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes == nil, "the send failed: nothing arrived")
	H.coop.send_event = real
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes and A.MDATA.player_created_stashes[5] == "stash_a", "the next look sends it")
end

-------------------------------------------------------------------------------
-- Round 2, F4 (the shipped mode): a value one client did not get goes again to that client only, with a growing wait, and
-- the "not sent" line is written once per key and value, not at every try (a client loading for minutes made a 2 s loop of
-- the whole value to every client and a log line each time).
section("a failed client is sent the value again alone, with a backoff, and logged once")
do
	local H, A, B = setup(2)
	tick(H, 2100) deliver_all()
	local real = H.coop.send_event
	local tries_a, to_b = 0, 0
	H.coop.send_event = function(name, payload, target)
		if name == "economy.wmd" and target == 1 then tries_a = tries_a + 1; return false, "loading" end
		if name == "economy.wmd" and target == 2 then to_b = to_b + 1 end
		return real(name, payload, target)
	end
	H.MDATA.player_created_stashes = { [5] = "stash_a" }
	local lines0 = #H.LOG
	tick(H, 2100) deliver_all()
	check(B.MDATA.player_created_stashes and B.MDATA.player_created_stashes[5] == "stash_a", "the client that can take it got it")
	check(A.MDATA.player_created_stashes == nil and tries_a == 1, "the loading client did not")
	for _ = 1, 30 do tick(H, 2100) deliver_all() end -- a minute of looks
	check(to_b == 1, "the client that got it is not sent it again (" .. to_b .. " sends)")
	check(tries_a >= 2 and tries_a <= 7, "the loading client is tried with a growing wait, not every 2 s (" .. tries_a .. " tries in 63 s)")
	local not_sent = 0
	for i = lines0 + 1, #H.LOG do
		if H.LOG[i]:find("not sent", 1, true) then not_sent = not_sent + 1 end
	end
	check(not_sent == 1, "one 'not sent' line for the key and value (" .. not_sent .. ")")
	-- he finished loading: the next try brings it
	H.coop.send_event = real
	for _ = 1, 30 do tick(H, 2100) deliver_all() end
	check(A.MDATA.player_created_stashes and A.MDATA.player_created_stashes[5] == "stash_a", "after loading he gets it")
	-- a new value goes to both at once, the old wait forgotten
	local n_b = 0
	H.coop.send_event = function(name, payload, target)
		if name == "economy.wmd" and target == 2 then n_b = n_b + 1 end
		return real(name, payload, target)
	end
	H.MDATA.player_created_stashes = { [6] = "stash_b" }
	tick(H, 2100) deliver_all()
	check(A.MDATA.player_created_stashes[6] == "stash_b" and B.MDATA.player_created_stashes[6] == "stash_b" and n_b == 1,
		"a new value reaches both at the next look")
	H.coop.send_event = real
end

section("a client that left is not owed anything")
do
	local H, A = setup(1)
	tick(H, 2100) deliver_all()
	local real = H.coop.send_event
	local tries = 0
	H.coop.send_event = function(name, payload, target)
		if name == "economy.wmd" then tries = tries + 1; return false, "loading" end
		return real(name, payload, target)
	end
	H.MDATA.workshop_stashes = { [9] = "wb" }
	tick(H, 2100) deliver_all()
	PLAYERS[1] = nil -- he left
	for _ = 1, 30 do tick(H, 2100) deliver_all() end
	check(tries == 1, "no tries for a player who left (" .. tries .. ")")
	H.coop.send_event = real
end

-------------------------------------------------------------------------------
section("a client's per-player key over the limit is logged with its key and size, and a smaller one still goes")
do
	local H, A = setup(1)
	local drink = { last_drink = 100 }
	A.actor_status_thirst = { save_state = function(m) m.drink = drink end }
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "drink").last_drink == 100, "the first look told the host")
	drink = { last_drink = 200, junk = string.rep("y", 13000) }
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "drink").last_drink == 100, "the big value is not sent")
	local line = logged(A, "player key drink")
	check(line ~= nil and line:find("%d%d%d%d%d bytes") ~= nil, "logged with the key and the size: " .. tostring(line))
	local lines = #A.LOG
	tick(A, 16000) deliver_all()
	check(#A.LOG == lines and A.coop_economy_mdata._stats().oversize == 1, "the same value is logged once")
	drink = { last_drink = 300 }
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "drink").last_drink == 300, "a smaller value after it goes")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
