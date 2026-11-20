-- A vote asked by the authority of a level that is a map server (coop_economy_group.propose): the ballots are the world server's
-- (every player answers his host), so the map server's proposal goes to the world server, which runs the vote and tells the map
-- server its end. Owner, live 2026-11-15: "no vote window at the arena when I played with the guys" - on a map server propose
-- answered nil and the arena started with no vote. Real coop_economy_core and coop_economy_group on a world server (peer 0), the
-- map server of the Bar (peer 0x100) and two players (peers 1 and 2). Not shipped.
-- Run: tools\test_lua.cmd vote_for
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local MK = 0x100
local WS, M, C1, C2
local passed, failed = 0, 0
local function check(ok, what)
	if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. what) end
end

-- ui_dyn_msg_box.msg_box_ui is a luabind class in the game: calling it makes the window (yes = func_ok, no = func_cancel)
local function boxes(P)
	local class = newproxy(true)
	getmetatable(class).__call = function(_, typ, show, text, yes, no)
		local b = { text = text, yes = function() yes() end, no = function() no() end }
		b.message_box = { HideDialog = function() if P.BOX == b then P.BOX = nil end end }
		P.BOX = b
		return b
	end
	P.env.ui_dyn_msg_box = { msg_box_ui = class }
end

local function party(role, peer, split)
	local P = machine(role, peer, { [0] = 900, [1] = 501, [2] = 502 })
	P.env.coop.is_map_server = function() return peer == MK end
	P.env.coop.is_dedicated = function() return split and peer == 0 end
	P.env.coop.levels = {
		split = function() return split end,
		map_servers = function() return split and { { bridge = MK } } or {} end,
	}
	modes.live(load_script(P, "coop_mode"), function(name) return load_script(P, name) end)
	P.tips = {}
	P.env.news_manager = { send_tip = function(_, text) P.tips[#P.tips + 1] = text end }
	boxes(P)
	P.core = load_script(P, "coop_economy_core")
	-- what the test does not model of the core: the tip on the screen
	P.core.tip = function(text) P.tips[#P.tips + 1] = tostring(text) end
	P.group = load_script(P, "coop_economy_group")
	P.group.subject("arena", {
		ask = { "st_coop_arena_vote_ask", "%s wants to start arena fight %s without the others. Agree?" },
		no = { "st_coop_arena_vote_no", "%s does not want to start the arena fight yet." },
		timeout = { "st_coop_arena_vote_timeout", "The arena fight waits: no answer from %s." },
		left = { "st_coop_arena_vote_left", "The arena vote was cancelled (%s left)." },
	})
	P.group.on_game_start()
	return P
end

local function setup(split)
	reset_world()
	NOW = (NOW or 0) + 1000000
	split = split ~= false
	WS = party("host", 0, split)
	M = split and party("client", MK, split) or nil
	C1 = party("client", 1, split)
	C2 = party("client", 2, split)
end

local function tick(P, ms)
	NOW = NOW + (ms or 1000)
	P.fire("actor_on_update")
end

print("== the map server's proposal is voted at the world server, its end comes back")
do
	setup()
	local result = nil
	local asked = M.group.propose("arena", 1, { [2] = true }, function(ok, reason, nick) result = { ok = ok, reason = reason, nick = nick } end, "4")
	check(asked == true, "the map server's propose answers that the vote is asked for")
	check(result == nil and C2.BOX == nil, "nothing is decided on the map server itself")
	pump()
	check(C2.BOX ~= nil and tostring(C2.BOX.text):find("p1", 1, true) and tostring(C2.BOX.text):find("4", 1, true), "the other player at Arnie gets the vote's window, with the asker and the fight")
	check(C1.BOX == nil and WS.BOX == nil and M.BOX == nil, "nobody else gets a window")
	check(result == nil, "the vote runs")
	C2.BOX.yes()
	pump()
	check(result ~= nil and result.ok == true, "he agreed: the map server hears yes")

	setup()
	result = nil
	M.group.propose("arena", 1, { [2] = true }, function(ok, reason, nick) result = { ok = ok, reason = reason, nick = nick } end, "4")
	pump()
	C2.BOX.no()
	pump()
	check(result ~= nil and result.ok == false and result.reason == "no" and result.nick == "p2", "he refused: the map server hears no, and who")
	local told = false
	for _, t in ipairs(C1.tips) do told = told or tostring(t):find("p2", 1, true) ~= nil end
	check(told, "the asker is told who does not want to start")
end

print("== nobody to ask, a player's forged ask, a world server that never answers")
do
	setup()
	local result = nil
	M.group.propose("arena", 1, {}, function(ok) result = ok end, "4")
	pump()
	check(result == true, "no voter: yes at once")

	setup()
	-- a player sends the map server's verb himself: the world server runs no vote for him
	C1.core.send("propose_for", { k = 1, g = "arena", f = 1, v = "2", a = "4" }, 0)
	pump()
	check(C2.BOX == nil, "a player's own propose_for is not a map server's: no vote")

	setup()
	result = nil
	M.group.propose("arena", 1, { [2] = true }, function(ok, reason) result = { ok = ok, reason = reason } end, "4")
	QUEUE = {} -- the ask is lost on its way
	for _ = 1, 70 do tick(M, 1000) end
	check(result ~= nil and result.ok == false and result.reason == "timeout", "no answer from the world server: the vote ends as a no, not for ever")
	local late = result
	-- a late answer after that changes nothing
	WS.core.send("verdict_for", { k = 1, ok = true, r = "", n = "" }, MK)
	pump()
	check(result == late, "a late answer is not a second result")
end

print("== a plain host votes as before")
do
	setup(false)
	local result = nil
	local asked = WS.group.propose("arena", 1, { [2] = true }, function(ok) result = ok end, "4")
	check(asked == true, "the host proposes itself")
	pump()
	check(C2.BOX ~= nil, "the voter gets the window")
	C2.BOX.yes()
	pump()
	check(result == true, "yes")
	check(C1.group.propose("arena", 1, { [2] = true }, function() end, "4") == nil, "a player's machine runs no vote")
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
