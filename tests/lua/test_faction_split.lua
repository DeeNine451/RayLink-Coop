-- Anomaly Coop test (a player's own faction with split levels, owner 2026-11-16): each player joins a faction himself, at the
-- faction's leader; different players may be in different factions. The world keeps every character's true faction
-- (coop_faction.script, its own key of m_data), the finisher's machine changes only its own character (no storyline recycle,
-- nothing of the group's tasks), a join gives a returning player his own faction back, everybody gets a news line, and other
-- scripts read the faction of any character (split_mode, faction_of, faction_of_character, the callback coop_faction_changed).
-- The machines and stock stand-ins are tests/lua/support/harness_faction.lua's. Not shipped.
-- Run: tools\test_lua.cmd faction_split
dofile("tests/lua/support/harness_faction.lua")

STRINGS.st_coop_faction_split_joined = "%s joined the %s faction."
STRINGS.st_faction_csky = "Clear Sky"

local CF = "drx_sl_bar_dolg_cf_task_1"
local CF2 = "drx_sl_mil_freedom_cf_task_1"
local MEMBERS = {} -- coop.members() of the world: the characters of the save
local ALL = { { id = 501, peer = 1, in_world = true }, { id = 502, peer = 2, in_world = true } }
local DEDICATED = false

SETUP_HOOK = function(M)
	local e = M.env
	M.declared, M.changed = {}, {}
	e.AddScriptCallback = function(name) M.declared[name] = true end
	e.RegisterScriptCallback("coop_faction_changed", function(...) M.changed[#M.changed + 1] = { ... } end)
	e.coop.members = function() return MEMBERS end
	e.coop.is_dedicated = function() return M.role == "host" and DEDICATED end
	e.coop.is_map_server = function() return false end
	local ao = e.alife_object
	e.alife_object = function(id)
		local se = ao(id)
		if se then se.section_name = function() return se._o._sec end end
		return se
	end
	if M.role == "host" then M.world_faction = "stalker" end
	M.ini[CF2] = {}
	-- the stock storyline recycle on a client fails the group's drx_sl tasks through the task stubs (a request to the world)
	e.xr_effects.drx_sl_cancel_questlines = function()
		M.cancelled = M.cancelled + 1
		if M.role == "client" and M.tm.task_info.t_other then M.tm:set_task_failed("t_other") end
	end
end

local function sent_since(M, mark, names)
	local n = 0
	for i = mark + 1, #M.sent do if names[M.sent[i].name] then n = n + 1 end end
	return n
end

-- machine M turns in a cf task (the task manager is the world's); -> the length of M.sent right after his completion request
local function turn_in(M, faction, id)
	id = id or CF
	M.tm:give_task(id, 9)
	pump()
	Hm.on_complete[id] = function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { faction }) end
	M.tm:set_task_completed(id)
	pump()
	local mark = #M.sent
	engine_check(Hm)
	pump()
	return mark
end

-- a new Lua state of client M (a level change or a rejoin): it loads the WORLD's m_data, its character keeps its community
local function reload(old, community)
	for i, m in ipairs(MACHINES) do if m == old then table.remove(MACHINES, i) break end end
	local M = machine("client", old.self_peer)
	setup_world(M, old.nick)
	M.players = old.players
	M.active = true
	SETUP_HOOK(M)
	for k, v in pairs(Hm.storage_state) do M.storage_state[k] = v end
	M.actor._comm = community
	for _, n in ipairs(FACTION_SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(FACTION_SCRIPTS) do M.env[n].on_game_start() end
	-- gameplay_disguise.actor_on_first_update (gameplay_disguise.script:1014): m_data's default_faction or the community
	M.env.gameplay_disguise._test_load(M.storage_state.default_faction or community:sub(7))
	fire(M, "actor_on_first_update")
	return M
end

local function split_setup(members_at_load)
	MEMBERS = members_at_load or {}
	setup(true)
	MEMBERS = ALL
	return Hm.env.coop_faction
end

-------------------------------------------------------------------------------
section("split levels: a client turns in, only he changes, the world records it")
do
	local cf = split_setup()
	check(cf.split_mode() == true and cf.group_mode() == false, "split levels in a session: split mode, no group mode")
	check(Hm.declared.coop_faction_changed == true and A.declared.coop_faction_changed == true, "the callback is declared")
	A.tm:give_task("t_other", 9)
	pump()
	local mark = turn_in(A, "dolg")
	check(comm(A) == "actor_dolg" and A.env.get_actor_true_community() == "dolg", "the finisher is in Duty")
	check(A.storage_state.default_faction == "dolg", "his m_data says Duty")
	check(comm(Hm) == "actor_stalker" and comm(B) == "actor_stalker", "nobody else changed")
	check(cf.faction_of(1) == "dolg" and cf.faction_of_character(501) == "dolg", "the world records anna in Duty (" .. tostring(cf.faction_of(1)) .. ")")
	check(cf.faction_of(2) == "stalker" and cf.faction_of(0) == "stalker", "boris and the host are loners")
	for _, M in ipairs({ Hm, A, B }) do
		check(tips_with(M, "anna joined the Duty faction.") == 1, M.nick .. " got the news line once")
	end
	check(Hm.cancelled == 0 and Hm.setup == 0 and Hm.lttz == 0, "no storyline recycle on the world")
	check(A.cancelled == 0 and A.setup == 0 and A.lttz == 0, "no storyline recycle on the finisher's machine")
	check(B.cancelled == 0 and B.setup == 0, "nor on another client")
	check(sent_since(A, mark, { coop_tq = true, coop_tvd = true }) == 0, "no task request and no shared var write left his machine")
	check(A.tm.task_info.t_other ~= nil and A.tm.task_info.t_other.forced_status == nil, "his other task stands")
	check(#Hm.changed == 1 and Hm.changed[1][1] == 1 and Hm.changed[1][2] == 501 and Hm.changed[1][3] == "stalker"
		and Hm.changed[1][4] == "dolg", "coop_faction_changed(1, 501, stalker, dolg) on the world")
	check(#A.changed == 0 and #B.changed == 0, "and only on the world")
	check(A.env.coop_faction.faction_of(1) == nil, "a client is no authority: faction_of says nil there")
end

section("the walk: join -> change -> level change -> his faction is his")
do
	local cf = split_setup()
	Hm.storage_state.default_faction = "stalker" -- the host's own true faction is in the world's m_data
	turn_in(A, "dolg")
	check(comm(A) == "actor_dolg", "anna joined Duty")
	A = reload(A, "actor_dolg")
	check(A.env.get_actor_true_community() == "stalker", "after the level change her true faction is the host's again (the bug)")
	local tips = #A.tips
	tick(A)
	check(count_sent(A, "coop_fac_req") == 1, "she asks the world once she is in the game")
	tick(A)
	check(count_sent(A, "coop_fac_req") == 1, "and not every frame")
	pump()
	check(A.env.get_actor_true_community() == "dolg" and comm(A) == "actor_dolg", "her true faction is Duty again ("
		.. tostring(A.env.get_actor_true_community()) .. ")")
	check(A.storage_state.default_faction == "dolg", "her m_data says Duty")
	check(not has_tip(A, "While you were away") and #A.tips == tips, "no line: it is her own faction coming back")
	NOW = NOW + 20000
	tick(A)
	check(count_sent(A, "coop_fac_req") == 1, "an answered client stops asking")
	check(cf.faction_of(1) == "dolg", "the world still says Duty")
	-- a rejoin of boris: he never changed, the world's faction comes back to him
	B = reload(B, "actor_stalker")
	tick(B)
	pump()
	check(B.env.get_actor_true_community() == "stalker" and comm(B) == "actor_stalker", "boris stays a loner")
end

section("two players in two factions, a second change of the same player")
do
	local cf = split_setup()
	turn_in(A, "dolg")
	turn_in(B, "freedom", CF2)
	check(comm(A) == "actor_dolg" and comm(B) == "actor_freedom", "anna in Duty, boris in Freedom")
	check(cf.faction_of(1) == "dolg" and cf.faction_of(2) == "freedom", "faction_of says so for both")
	check(cf.faction_of_character(501) == "dolg" and cf.faction_of_character(502) == "freedom", "and by character")
	check(has_tip(A, "boris joined the Freedom faction.") and has_tip(B, "anna joined the Duty faction."), "each was told of the other")
	-- anna moves on to Freedom
	Hm.engine_tasks[CF2] = nil
	turn_in(A, "freedom", CF2)
	check(comm(A) == "actor_freedom" and cf.faction_of(1) == "freedom", "anna's second change: Freedom")
	local last = Hm.changed[#Hm.changed]
	check(#Hm.changed == 3 and last[1] == 1 and last[2] == 501 and last[3] == "dolg" and last[4] == "freedom",
		"coop_faction_changed(1, 501, dolg, freedom)")
	check(tips_with(B, "anna joined the Freedom faction.") == 1, "boris was told")
	check(Hm.cancelled == 0 and A.cancelled == 0 and B.cancelled == 0, "no storyline recycle anywhere")
end

section("a client's own call changes nothing and sends nothing")
do
	local cf = split_setup()
	local sent = #A.sent
	A.env.set_actor_true_community("freedom", true) -- the debug launcher's call
	A.env.xr_effects.drx_sl_change_factions(A.actor, nil, { "army" }) -- a dialog's effect on the client
	check(comm(A) == "actor_stalker" and A.env.get_actor_true_community() == "stalker", "the client's character did not change")
	check(#A.sent == sent, "nothing was sent (" .. (#A.sent - sent) .. ")")
	check(A.cancelled == 0 and A.setup == 0, "no storyline recycle on the client")
	check(has_tip(A, "changed by the whole group"), "the client gets the group mode's tip")
	check(has_log(A, "was not made"), "and the log line")
	pump()
	check(cf.faction_of(1) == "stalker" and #Hm.changed == 0, "the world's record did not change")
end

section("forged words from a non-host peer, a nick is never a format")
do
	local cf = split_setup()
	local tips = #B.tips
	B.handlers.coop_fac(H.encode({ k = "news", f = "army", n = "anna" }), 1, "coop_fac")
	B.handlers.coop_fac(H.encode({ k = "sync", f = "army" }), 1, "coop_fac")
	check(comm(B) == "actor_stalker" and #B.tips == tips, "a forged word from peer 1 moves nobody and says nothing")
	Hm.handlers.coop_fac(H.encode({ k = "sync", f = "army" }), 1, "coop_fac")
	Hm.handlers.coop_fac(H.encode({ k = "news", f = "army", n = "x" }), 2, "coop_fac")
	check(comm(Hm) == "actor_stalker" and cf.faction_of(1) == "stalker" and #Hm.changed == 0, "nor the world")
	B.handlers.coop_fac(H.encode({ k = "news", f = "../x", n = "x" }), 0, "coop_fac")
	check(#B.tips == tips, "an unknown faction from the world is refused")
	B.handlers.coop_fac(H.encode({ k = "news", f = "army", n = "%s%s%n\1\2" }), 0, "coop_fac")
	check(has_tip(B, "%s%s%n   joined the Army faction."), "a nick is text, never a format; control characters cut (" .. tostring(B.tips[#B.tips]) .. ")")
	check(comm(B) == "actor_stalker", "a news word moves nobody")
	-- the read-only question cannot change the record of a character the world knows
	NOW = NOW + 5000
	A.env.coop.send_event("coop_fac_req", H.encode({ b = "army" }), 0)
	pump()
	check(cf.faction_of(1) == "stalker", "a new character's claim is not taken")
end

section("an old save: the bootstrap of a character with no record")
do
	-- the save had anna and boris; the world has no record of their factions yet
	local cf = split_setup(ALL)
	A.actor._comm = "actor_freedom" -- her character, as the save had it
	B.actor._comm = "actor_csky"
	check(cf.faction_of_character(501) == nil, "anna's faction is not known yet")
	-- boris's client says nonsense first
	B.env.coop.send_event("coop_fac_req", H.encode({ b = "../../x" }), 0)
	pump()
	check(cf.faction_of_character(502) == nil, "an unknown name is refused")
	tick(A)
	NOW = NOW + 5000
	tick(B)
	pump()
	check(cf.faction_of(1) == "freedom", "anna's own word is taken once (" .. tostring(cf.faction_of(1)) .. ")")
	check(cf.faction_of(2) == "csky", "boris's honest word is taken after the refused one")
	check(comm(A) == "actor_freedom" and A.env.get_actor_true_community() == "freedom", "anna's true faction is her own")
	check(#Hm.changed == 0 and not has_tip(B, "joined"), "a bootstrap is no change: no callback, no news")
	NOW = NOW + 5000
	A.env.coop.send_event("coop_fac_req", H.encode({ b = "army" }), 0)
	pump()
	check(cf.faction_of(1) == "freedom" and comm(A) == "actor_freedom", "a second claim is ignored, the answer is the record")
end

section("a new character gets the world's faction")
do
	local cf = split_setup({}) -- a new world: nobody at the load
	A.actor._comm = "actor_army"
	tick(A)
	pump()
	check(cf.faction_of(1) == "stalker", "the world records the world's faction (" .. tostring(cf.faction_of(1)) .. ")")
	check(comm(A) == "actor_stalker" and A.env.get_actor_true_community() == "stalker", "and the client is in it")
	check(#Hm.changed == 0, "no callback")
end

section("a record of a character that no longer exists is pruned at save")
do
	local cf = split_setup()
	turn_in(A, "dolg")
	turn_in(B, "freedom", CF2)
	Hm.env.alife_release_id(502)
	local m = Hm.storage_state
	fire(Hm, "save_state", m)
	check(cf.faction_of_character(501) == "dolg", "anna's record stays")
	local rec = m.coop_faction
	check(type(rec) == "table" and type(rec.chars) == "table" and rec.chars[502] == nil and rec.chars[501] ~= nil, "boris's record is gone")
	check(cf.faction_of_character(502) == nil, "and nothing is said of him")
end

section("the world's record survives a load of its m_data")
do
	local cf = split_setup()
	turn_in(A, "dolg")
	local saved = Hm.storage_state
	split_setup(ALL)
	for k in pairs(Hm.storage_state) do Hm.storage_state[k] = nil end
	for k, v in pairs(saved) do Hm.storage_state[k] = v end
	check(Hm.env.coop_faction.faction_of(1) == "dolg", "a world loaded from the save knows anna is in Duty")
end

section("the host player's own change in split mode")
do
	local cf = split_setup()
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
	pump()
	check(comm(Hm) == "actor_dolg" and cf.faction_of(0) == "dolg", "the host is in Duty, the world records it")
	check(comm(A) == "actor_stalker" and comm(B) == "actor_stalker", "nobody else moved")
	check(Hm.cancelled == 0 and Hm.setup == 0, "no storyline recycle on the world")
	check(has_tip(A, "Host joined the Duty faction.") and has_tip(Hm, "Host joined the Duty faction."), "everybody was told")
	check(Hm.world_faction == "stalker", "the world's faction for new characters is not touched")
end

section("a dedicated world server: its actor is nobody")
do
	DEDICATED = true
	local cf = split_setup()
	Hm.env.set_actor_true_community("dolg")
	check(comm(Hm) == "actor_stalker" and Hm.cancelled == 0, "a call on the world server's ghost changes nothing")
	check(cf.faction_of(0) == nil and #Hm.changed == 0, "the ghost has no faction")
	turn_in(A, "dolg")
	check(comm(A) == "actor_dolg" and cf.faction_of(1) == "dolg", "a client's change is recorded as on a listen host")
	DEDICATED = false
end

section("group mode: the contract")
do
	setup(false)
	local cf = Hm.env.coop_faction
	check(cf.split_mode() == false, "no split mode")
	check(Hm.declared.coop_faction_changed == true, "the callback is declared in group mode too")
	Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" })
	pump()
	check(cf.faction_of(1) == "dolg" and cf.faction_of(0) == "dolg" and cf.faction_of_character(501) == "dolg", "faction_of is the group's faction")
	check(A.env.coop_faction.faction_of(1) == nil, "a client says nil")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
