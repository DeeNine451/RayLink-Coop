-- Foreign loot (coop_loot_claim): a living stalker who killed something keeps the body for himself, in a session only.
-- Rules: a kill by any player / a companion / a story character / a monster / a zombie / nobody / suicide is free; another
-- stalker's kill is a claim of the host's table (saved, small, sent to clients as events and as a snapshot); a player's own
-- machine decides on USE: killer within 25 m = warning, farther = "nothing useful", dead or offline = free; no permanent flag.
-- Run: tools\test_lua.cmd loot_claim
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_loot_claim" }

local KEY_USE = 33
local STALKER, MONSTER = "stalker", "monster"

local function setup_world(M)
	local e = M.env
	e.key_bindings = { kUSE = KEY_USE }
	e.IsStalker = function(o) return type(o) == "table" and o._kind == STALKER end
	e.IsMonster = function(o) return type(o) == "table" and o._kind == MONSTER end
	M.ObjMT.has_info = function(self, i) return self._infos ~= nil and self._infos[i] == true end
	e.story = {}
	e.get_object_story_id = function(id) return e.story[id] end
	e.game.translate_string = function(id)
		if id:find("^st_npc_loot_claim_") and not M.mod_strings then return id end -- the mod's text is not installed
		return "T(" .. id .. ")"
	end
	e.rules = { ["core/loot_claim"] = true }
	e.coop_settings = { rule = function(key) return e.rules[key] end }
	M.msgs, M.tips = {}, {}
	e.actor_menu = { set_msg = function(_, text) M.msgs[#M.msgs + 1] = text end }
	e.dynamic_news_helper = {
		send_tip = function(text, head, a, b, icon, snd, by) M.tips[#M.tips + 1] = { text = text, head = head, icon = icon } return true end,
	}
	-- what the player looks at
	M.look, M.look_dist = nil, 1.5
	e.level.get_target_obj = function() return M.look end
	e.level.get_target_dist = function() return M.look and M.look_dist or 0 end
	e.alife_object = function(id) return M.objects[id] and { id = id } or nil end
	M.objects_dead = {}
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
end

local function stalker(M, id, pos, comm)
	local o = M.new_obj(id, "stalker", pos, { _kind = STALKER, _comm = comm or "stalker", _cname = "Sidor" .. id })
	M.env.db.storage[id] = { object = o }
	return o
end

local function mutant(M, id, pos) return M.new_obj(id, "dog", pos, { _kind = MONSTER }) end

local function key_press(M)
	local flags = {}
	M.fire_key = true
	fire(M, "on_before_key_press", KEY_USE, KEY_USE, false, flags)
	return flags.ret_value == false
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
for _, M in ipairs({ Hm, Cm }) do setup_world(M) end
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
-- both machines see the same world: bodies 701.., killers 801..
for _, M in ipairs({ Hm, Cm }) do
	M.victim = stalker(M, 701, vec(10, 0, 0))
	M.victim._dead = true
	M.killer = stalker(M, 801, vec(20, 0, 0), "bandit")
end
Hm.proxy = stalker(Hm, 500, vec(40, 0, 0)) -- the client's character on the host
Cm.actor._pos = vec(40, 0, 0)
boot(Hm)
boot(Cm)
local LC = Hm.env.coop_loot_claim
local LC_C = Cm.env.coop_loot_claim
check(Hm.handlers["quests.loot_ask"] and Cm.handlers["quests.loot_snap"] and Cm.handlers["quests.loot_claim"]
	and Cm.handlers["quests.loot_free"], "the four events are handled")
check((Hm.callbacks.npc_on_death_callback or {})[1] and (Hm.callbacks.monster_on_death_callback or {})[1]
	and (Hm.callbacks.on_before_key_press or {})[1], "deaths and USE are hooked")

-- the module exports no stray globals (the mod leaked obj, id, sender, dist and the tables)
do
	local stray = {}
	for name, v in pairs(LC) do
		if type(v) ~= "function" then stray[#stray + 1] = name end
	end
	check(#stray == 0, "no global variable in the module (" .. table.concat(stray, ",") .. ")")
	check(rawget(Hm.env, "obj") == nil and rawget(Hm.env, "id") == nil and rawget(Hm.env, "sender") == nil
		and rawget(Hm.env, "dist") == nil and rawget(Hm.env, "claimed") == nil and rawget(Hm.env, "looted") == nil,
		"nothing leaked into the game's globals")
end

local function die(victim_id, killer)
	fire(Hm, "npc_on_death_callback", Hm.objects[victim_id], killer)
	pump()
end

print("== whose kill is free")
local function fresh_victim(id)
	for _, M in ipairs({ Hm, Cm }) do
		M.objects[id] = nil
		local v = stalker(M, id, vec(10, 0, 0))
		v._dead = true
	end
	return Hm.objects[id]
end
do
	local n0 = LC.claim_count()
	fresh_victim(710)
	die(710, nil)
	check(LC.claim_of(710) == nil, "no killer (an anomaly): free, and no error")
	fresh_victim(711)
	die(711, Hm.objects[711])
	check(LC.claim_of(711) == nil, "a suicide: free")
	fresh_victim(712)
	die(712, Hm.actor)
	check(LC.claim_of(712) == nil, "the host's player killed it: free")
	fresh_victim(713)
	die(713, Hm.proxy)
	check(LC.claim_of(713) == nil, "a client's character killed it: free")
	fresh_victim(714)
	Hm.env.story[714] = "esc_trader"
	die(714, Hm.killer)
	check(LC.claim_of(714) == nil, "a story character's body: free")
	fresh_victim(715)
	Hm.env.story[801] = "some_story_npc"
	die(715, Hm.killer)
	check(LC.claim_of(715) == nil, "a story character killed it: free")
	Hm.env.story[801] = nil
	local comp = stalker(Hm, 810, vec(22, 0, 0))
	comp._infos = { npcx_is_companion = true }
	fresh_victim(716)
	die(716, comp)
	check(LC.claim_of(716) == nil, "a companion of a player killed it: free")
	local comp2 = stalker(Hm, 811, vec(22, 0, 0))
	Hm.env.axr_companions = { companion_squads = { [77] = true } }
	Hm.env.get_object_squad = function(o) if o:id() == 811 then return { id = 77 } end end
	fresh_victim(717)
	die(717, comp2)
	check(LC.claim_of(717) == nil, "a companion of a player (squad list, whoever leads it): free")
	Hm.env.axr_companions = nil
	Hm.env.get_object_squad = nil
	local zed = stalker(Hm, 812, vec(22, 0, 0), "zombied")
	fresh_victim(718)
	die(718, zed)
	check(LC.claim_of(718) == nil, "a zombie killed it: free")
	local dog = mutant(Hm, 813, vec(22, 0, 0))
	fresh_victim(719)
	die(719, dog)
	check(LC.claim_of(719) == nil, "a monster killed it: free")
	local broken = stalker(Hm, 814, vec(22, 0, 0))
	broken.has_info = function() error("no such method") end
	broken.character_community = function() error("no such method") end
	fresh_victim(720)
	local okc = pcall(fire, Hm, "npc_on_death_callback", Hm.objects[720], broken)
	check(okc, "a killer whose info calls fail does not raise (the mod indexed nil)")
	check(LC.claim_count() == n0 + ((LC.claim_of(720) ~= nil) and 1 or 0), "nothing else was recorded")
	check(count_sent(Hm, "quests.loot_claim") == 0 or LC.claim_of(720) ~= nil, "no claim event for a free kill")
end

print("== another stalker's kill is a claim; the client hears of it")
do
	fresh_victim(701)
	local before = count_sent(Hm, "quests.loot_claim")
	die(701, Hm.killer)
	check(LC.claim_of(701) == 801, "the host's table holds 701 -> 801")
	check(count_sent(Hm, "quests.loot_claim") == before + 1, "one claim event went out")
	check(LC_C.claim_of(701) == 801, "the client's table has it")
	-- a death callback on the client does not claim (the host owns the table)
	fresh_victim(702)
	fire(Cm, "npc_on_death_callback", Cm.objects[702], Cm.killer)
	check(LC_C.claim_of(702) == nil and LC.claim_of(702) == nil, "a client records nothing itself")
	-- a monster's body, killed by a stalker, is claimed too
	for _, M in ipairs({ Hm, Cm }) do M.new_obj(703, "dog", vec(12, 0, 0), { _kind = MONSTER, _dead = true }) end
	fire(Hm, "monster_on_death_callback", Hm.objects[703], Hm.killer)
	pump()
	check(LC.claim_of(703) == 801 and LC_C.claim_of(703) == 801, "a mutant killed by a stalker: claimed (monster_on_death)")
	Hm.env.rules["core/loot_claim"] = false
	fresh_victim(704)
	die(704, Hm.killer)
	check(LC.claim_of(704) == nil, "the setting off: no claim is made")
	Hm.env.rules["core/loot_claim"] = true
end

print("== USE on a body")
do
	Cm.look = Cm.objects[701]
	Cm.mod_strings = true
	-- the killer is 20 m from the body; the client stands at 40 m: 20 m from him -> near
	check(key_press(Cm) == true, "near killer: USE refused")
	check(#Cm.tips == 1 and Cm.tips[1].text:find("^T%(st_npc_loot_claim_last_%d%)$") ~= nil, "a warning came as a tip")
	check(Cm.tips[1] and Cm.tips[1].head:find("Sidor801", 1, true) ~= nil, "from the killer by name")
	Cm.mod_strings = false
	Cm.msgs, Cm.tips = {}, {}
	NOW = NOW + 3000
	key_press(Cm)
	check(#Cm.tips == 1 and Cm.tips[1].text:find("^T%(st_coop_news_loot_last_%d%)$") ~= nil, "without the mod's text our own string is used")
	Cm.mod_strings = true
	-- farther than 25 m: "nothing useful", not for ever
	Cm.killer._pos = vec(100, 0, 0)
	Cm.msgs, Cm.tips = {}, {}
	NOW = NOW + 3000
	check(key_press(Cm) == true and #Cm.tips == 0 and Cm.msgs[1] == "T(st_npc_loot_claim_far)", "far killer: refused, nothing useful")
	NOW = NOW + 3000
	Cm.killer._pos = vec(45, 0, 0)
	Cm.tips = {}
	check(key_press(Cm) == true and #Cm.tips == 1, "he comes back: the warning again (no permanent flag)")
	-- the engine's reach: 2 m
	Cm.look_dist = 2.5
	check(key_press(Cm) == false, "a body beyond the reach of USE is not asked about")
	Cm.look_dist = 1.5
	-- a live creature, or something else
	Cm.objects[701]._dead = false
	check(key_press(Cm) == false, "a live creature is not a body")
	Cm.objects[701]._dead = true
	Cm.look = nil
	check(key_press(Cm) == false, "looking at nothing")
	Cm.look = Cm.objects[702]
	check(key_press(Cm) == false, "a body with no row is free")
	Cm.look = Cm.objects[701]
	-- another key
	local flags = {}
	fire(Cm, "on_before_key_press", 1, 1, false, flags)
	check(flags.ret_value == nil, "other keys are not touched")
	-- the setting off on the client: free
	Cm.env.rules["core/loot_claim"] = false
	check(key_press(Cm) == false, "Foreign loot off: the body is free")
	Cm.env.rules["core/loot_claim"] = true
	-- the host's own player goes the same way
	Hm.look = Hm.objects[701]
	Hm.actor._pos = vec(21, 0, 0)
	Hm.tips = {}
	NOW = NOW + 3000
	check(key_press(Hm) == true and #Hm.tips == 1, "the host presses USE: the same answer")
	-- no session: the script is out of the way
	Hm.active = false
	Hm.tips = {}
	check(key_press(Hm) == false, "no session: nothing is refused")
	Hm.active = true
	-- the client's own machine saw the killer go offline
	local keep = Cm.objects[801]
	Cm.objects[801] = nil
	check(key_press(Cm) == false, "the killer is offline here: the body is free")
	Cm.objects[801] = keep
	Cm.killer._dead = true
	check(key_press(Cm) == false, "the killer is dead: the body is free")
	Cm.killer._dead = false
	Cm.killer._pos = vec(45, 0, 0)
end

print("== the host frees a row when it is useless")
do
	Hm.killer._dead = true
	local before = count_sent(Hm, "quests.loot_free")
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	pump()
	check(LC.claim_of(701) == nil and LC.claim_of(703) == nil, "the killer died: his rows are gone on the host")
	check(count_sent(Hm, "quests.loot_free") > before and LC_C.claim_of(701) == nil, "and on the client")
	Hm.killer._dead = false

	fresh_victim(730)
	die(730, Hm.killer)
	check(LC.claim_of(730) == 801 and LC_C.claim_of(730) == 801, "a new claim")
	local keep = Hm.objects[801]
	Hm.objects[801] = nil
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	pump()
	check(LC.claim_of(730) == nil and LC_C.claim_of(730) == nil, "the killer went offline: the body opens")
	Hm.objects[801] = keep

	fresh_victim(731)
	die(731, Hm.killer)
	Hm.objects[731] = nil -- the body is gone
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	pump()
	check(LC.claim_of(731) == nil, "the body is gone: the row goes")

	fresh_victim(732)
	die(732, Hm.killer)
	Hm.objects[732]._dead = false -- the id is a live creature now
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	pump()
	check(LC.claim_of(732) == nil, "the id of a live creature: the row goes")
	-- no scan before the period is over
	fresh_victim(733)
	die(733, Hm.killer)
	Hm.killer._dead = true
	NOW = NOW + 500
	fire(Hm, "actor_on_update")
	check(LC.claim_of(733) == 801, "the host looks every few seconds, not every tick")
	Hm.killer._dead = false
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	pump()
end

print("== the table stays small")
do
	local base = LC.claim_count()
	for i = 1, 70 do
		local id = 1000 + i
		for _, M in ipairs({ Hm, Cm }) do
			M.objects[id] = nil
			local v = stalker(M, id, vec(10, 0, 0))
			v._dead = true
		end
		die(id, Hm.killer)
	end
	check(LC.claim_count() == 48, "at most 48 rows on the host (was " .. base .. ", now " .. LC.claim_count() .. ")")
	check(LC.claim_of(1070) == 801 and LC.claim_of(1001) == nil, "the newest stay, the oldest went")
	check(LC_C.claim_count() == 48 and LC_C.claim_of(1070) == 801 and LC_C.claim_of(1001) == nil,
		"the client holds the same rows (" .. LC_C.claim_count() .. ")")
end

print("== a client that comes late gets the table")
do
	-- the client loads the host's world: its own table is empty, it asks once it is live
	local snaps = count_sent(Hm, "quests.loot_snap")
	fire(Cm, "load_state", {})
	check(LC_C.claim_count() == 0, "a client starts empty after the load")
	NOW = NOW + 600
	fire(Cm, "actor_on_update")
	pump()
	check(count_sent(Hm, "quests.loot_snap") == snaps + 1, "the host answered the ask with the table")
	check(LC_C.claim_count() == LC.claim_count() and LC_C.claim_of(1070) == 801 and LC_C.claim_of(1030) == 801,
		"the client has every row (" .. LC_C.claim_count() .. " of " .. LC.claim_count() .. ")")
	local asks = count_sent(Cm, "quests.loot_ask")
	NOW = NOW + 5000
	fire(Cm, "actor_on_update")
	check(count_sent(Cm, "quests.loot_ask") == asks, "it does not ask again once the table is there")
	-- the age order survives: the next claim drops the oldest
	fresh_victim(1100)
	die(1100, Hm.killer)
	check(LC_C.claim_of(1100) == 801 and LC_C.claim_of(1022) == nil and LC_C.claim_count() == 48,
		"the order of the snapshot is the order of age")
	-- a snapshot or event from a peer that is not the host is not taken
	Cm.handlers["quests.loot_claim"](H.encode({ v = 1200, k = 801 }), 3)
	check(LC_C.claim_of(1200) == nil, "an event from another peer is ignored")
	Cm.handlers["quests.loot_claim"](H.encode({ v = 70000, k = 801 }), 0)
	Cm.handlers["quests.loot_claim"](H.encode({ v = -1, k = 801 }), 0)
	Cm.handlers["quests.loot_claim"](H.encode({ v = "x", k = 801 }), 0)
	check(LC_C.claim_count() == 48, "bad ids are ignored")
	-- a client cannot ask as the host, the host does not answer itself
	local n = count_sent(Hm, "quests.loot_snap")
	Hm.handlers["quests.loot_ask"](H.encode({}), 0)
	check(count_sent(Hm, "quests.loot_snap") == n, "no answer to the host's own ask")
end

print("== save and load")
do
	local m_data = {}
	fire(Hm, "save_state", m_data)
	check(type(m_data.coop_loot_claims) == "table" and #m_data.coop_loot_claims == 48, "the host saves its rows (" .. tostring(m_data.coop_loot_claims and #m_data.coop_loot_claims) .. ")")
	local saved = LC.claim_count()
	fire(Hm, "load_state", m_data)
	check(LC.claim_count() == saved and LC.claim_of(1100) == 801, "load restores them")
	-- the age order is kept: the oldest saved row is the first to go
	fresh_victim(1101)
	die(1101, Hm.killer)
	check(LC.claim_of(1101) == 801 and LC.claim_count() == 48, "still 48 after a new claim")
	local cdata = {}
	fire(Cm, "save_state", cdata)
	check(cdata.coop_loot_claims == nil, "a client saves nothing")
	-- junk in a save is skipped
	fire(Hm, "load_state", { coop_loot_claims = { { v = 5, k = 6 }, { v = "a" }, 7, { v = 1e9, k = 1 } } })
	check(LC.claim_count() == 1 and LC.claim_of(5) == 6, "junk rows are skipped")
	fire(Hm, "load_state", {})
	check(LC.claim_count() == 0, "an old save has no table")
	-- a save from single player or an old session: the rows of dead killers go at the first scan
	fire(Hm, "load_state", { coop_loot_claims = { { v = 701, k = 801 } } })
	Hm.killer._dead = true
	NOW = NOW + 3500
	fire(Hm, "actor_on_update")
	check(LC.claim_count() == 0, "a stale row is dropped at the first scan")
	Hm.killer._dead = false
end

print("== single player")
do
	local S = machine("host", 0)
	setup_world(S)
	S.active = false
	boot(S)
	local SL = S.env.coop_loot_claim
	S.victim = stalker(S, 701, vec(10, 0, 0))
	S.victim._dead = true
	S.killer = stalker(S, 801, vec(20, 0, 0))
	fire(S, "npc_on_death_callback", S.victim, S.killer)
	check(SL.claim_count() == 0, "no session: a kill claims nothing (the mod works as installed)")
	S.look = S.victim
	check(key_press(S) == false, "no session: USE is not touched")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
