-- A-S5S (two modes, S5), Server: an encyclopedia article or an achievement that a map server's logic unlocks goes up to the world
-- server with the nick of a player of that map (coop_quests_pda.script announce_ency / on_earned); the world server opens it with that
-- name and tells the players of every map. The Core asks coop_mode who it is (a process that leads its map and does not decide the
-- world), never the engine's is_map_server: the map server below answers coop.is_map_server() false first, then true (live).
-- A server player's own unlock goes up with no name (the world server takes his own), the world server's logic tells everybody as
-- "World". Answer sets: srv_world (the world server), srv_map (the map server), a server player (overrides of srv_map, as
-- test_quests_pda_stub does).
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BRIDGE = 0x101
local ARTICLE, ARTICLE2, ARTICLE3, NOTE = "encyclopedia_devices_pda", "encyclopedia_mutants_boar", "encyclopedia_zone_cordon",
	"encyclopedia__notes_stash"
local ACHV = "tourist"

local PLAYER = {
	decides_world = function() return false end, leads_here = function() return false end,
	actor_is_player = function() return true end, is_player_mirror = function() return true end,
}

local function install_pda(M, set, overrides)
	local e = M.env
	modes.install(load_script(M, "coop_mode"), set, overrides)
	local unl = {}
	M.unl, M.shown, M.achv = unl, {}, {}
	e.ui_pda_encyclopedia_tab = {
		is_unlocked_article = function(s) return unl[s] == true end,
		is_unlocked_note = function(s) return unl[s] == true end,
		unlock_article = function(s) if unl[s] then return false end unl[s] = true return true end,
		unlock_note = function(s) if unl[s] then return false end unl[s] = true return true end,
	}
	e.actor_menu = { set_notification = function() end }
	e.coop_quests_news = { show_article = function(title, nick) M.shown[#M.shown + 1] = { title = title, nick = nick } end }
	e.game_statistics = { has_actor_achievement = function(n) return M.achv[n] == true end }
	e.game_achievements = { [ACHV .. "_rewards"] = function()
		M.env.SendScriptCallback("actor_on_achievement_earned", ACHV, "st_achievement_tourist")
	end }
	e.RegisterScriptCallback("actor_on_achievement_earned", function(n) M.achv[n] = true end)
	load_script(M, "coop_quests_core")
	load_script(M, "coop_trust")
	load_script(M, "coop_quests_pda").on_game_start()
	fire(M, "actor_on_first_update")
end

local function sent_to(M, name)
	local out = {}
	for _, s in ipairs(M.sent) do
		if s.name == name then out[#out + 1] = { target = s.target, t = H.decode(s.payload) } end
	end
	return out
end

-- One world: the world server (no row of its own), Ann on the map of map server 1, Bob on another map.
local function world(map_server_flag)
	QUEUE, MACHINES = {}, {}
	local W = machine("host", 0)
	W.players = { { id = 1, nick = "Ann", avatar_id = 500 }, { id = 2, nick = "Bob", avatar_id = 501 } }
	W.env.coop.is_dedicated = function() return true end
	install_pda(W, "srv_world")
	local MS = machine("client", BRIDGE)
	-- the map server's session: its own row and the player of its map
	MS.players = { { id = 0, nick = "ms1", is_self = true }, { id = 1, nick = "Ann", avatar_id = 500 } }
	MS.env.coop.is_map_server = function() return map_server_flag end
	install_pda(MS, "srv_map")
	local A = machine("client", 1)
	A.players = { { id = 1, nick = "Ann", is_self = true }, { id = 2, nick = "Bob" } }
	install_pda(A, "srv_map", PLAYER)
	local B = machine("client", 2)
	B.players = { { id = 1, nick = "Ann" }, { id = 2, nick = "Bob", is_self = true } }
	install_pda(B, "srv_map", PLAYER)
	return W, MS, A, B
end

for _, flag in ipairs({ false, true }) do
	local label = "Server (map server's coop.is_map_server " .. tostring(flag) .. ")"
	local W, MS, A, B = world(flag)

	-- a map server's logic opens an article: up to the world server only, with the name of the player on its map
	MS.env.ui_pda_encyclopedia_tab.unlock_article(ARTICLE)
	local up = sent_to(MS, "quests.ency")
	check(#up == 1 and up[1].target == 0 and up[1].t.s == ARTICLE and up[1].t.n == "Ann",
		label .. ": a map server's article goes to the world server (peer 0) with the nick of its player")
	pump()
	check(W.unl[ARTICLE] == true and #W.shown == 1 and W.shown[1].nick == "Ann",
		label .. ": the world server opens it in the name of the map's player")
	local told = sent_to(W, "quests.ency")
	local to = {}
	for _, s in ipairs(told) do to[s.target] = s.t.n end
	check(#told == 2 and to[1] == "Ann" and to[2] == "Ann", label .. ": the world server tells both players, named Ann")
	check(A.unl[ARTICLE] == true and B.unl[ARTICLE] == true and B.shown[1] and B.shown[1].nick == "Ann",
		label .. ": both players have the article, the other map's player reads Ann's name")
	check(#sent_to(A, "quests.ency") == 0 and #sent_to(B, "quests.ency") == 0, label .. ": no echo from the players")

	-- a map server's note: the same way up
	MS.env.ui_pda_encyclopedia_tab.unlock_note(NOTE)
	up = sent_to(MS, "quests.ency")
	check(#up == 2 and up[2].target == 0 and up[2].t.s == NOTE and up[2].t.n == "Ann", label .. ": a map server's note goes up named")
	pump()
	check(W.unl[NOTE] == true and A.unl[NOTE] == true and B.unl[NOTE] == true, label .. ": the note reaches every player")

	-- a map server's achievement: up with the player's nick, the world server earns it and tells the players
	MS.env.SendScriptCallback("actor_on_achievement_earned", ACHV, "msg")
	local au = sent_to(MS, "quests.achv")
	check(#au == 1 and au[1].target == 0 and au[1].t.a == ACHV and au[1].t.n == "Ann",
		label .. ": a map server's achievement goes to the world server with the nick of its player")
	pump()
	check(W.achv[ACHV] == true and A.achv[ACHV] == true and B.achv[ACHV] == true,
		label .. ": the world server and both players have the achievement")
	local at = sent_to(W, "quests.achv")
	local ato = {}
	for _, s in ipairs(at) do ato[s.target] = s.t.n end
	check(#at == 2 and ato[1] == "Ann" and ato[2] == "Ann", label .. ": the world server tells both players, named Ann")

	-- a server player opens an article himself: up with no name (the world server takes his own from his peer)
	A.env.ui_pda_encyclopedia_tab.unlock_article(ARTICLE2)
	local pu = sent_to(A, "quests.ency")
	check(#pu == 1 and pu[1].target == 0 and pu[1].t.s == ARTICLE2 and pu[1].t.n == nil,
		label .. ": a server player's own article goes up without a name of his choosing")
	pump()
	check(W.unl[ARTICLE2] == true and W.shown[#W.shown].nick == "Ann" and B.unl[ARTICLE2] == true,
		label .. ": the world server names him by his peer and tells the other player")

	-- the world server's own logic (its seat plays nobody): to everybody as "World"
	W.env.ui_pda_encyclopedia_tab.unlock_article(ARTICLE3)
	local wu = sent_to(W, "quests.ency")
	local last = wu[#wu]
	local world_name = W.env.game.translate_string("st_coop_core_chat_world") -- the harness's words: "T(<key>)"
	check(last and last.target == -1 and last.t.s == ARTICLE3 and last.t.n == world_name,
		label .. ": the world server's own article goes to everybody as World")
	pump()
	check(A.unl[ARTICLE3] == true and B.unl[ARTICLE3] == true and MS.unl[ARTICLE3] == true,
		label .. ": the players and the map server have the world server's article")
	check(#sent_to(MS, "quests.ency") == 2, label .. ": the map server does not send the world's article back")
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
