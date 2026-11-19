-- Server (srv): coop_srv_tasks.script, the task code only a server runs (step S5, unit A-S5T; docs\MODES.md, the build 57 plan).
--   - co-op: none of it starts (coop_mode.when_srv never runs there);
--   - a world hurt by a give that died on a world server (builds 45-49): its dialog's info is taken back, once a world
--     (was coop_tasks heal_lost_gives / _heal_once, tested in test_srv_far_tasks);
--   - a map server's personal effects pass through the world server to the player's machine once; the map server sends them again
--     until the world server answers (was coop_tasks' coop_rep_map / coop_rep_map_ack, tested in test_tasks_sync);
--   - character 0 on a server is the world server's seat, which plays no character: its effects are nobody's, the map server drops
--     them at once instead of sending them up every second for good;
--   - the part "talk": the NPC a player on a map server's level talks to (coop.levels.talk_partner, protocol 33);
--   - the player's sound, truce and offer goodwill, plus delivery of the task-end surge flag clear (level logic grants no player immunity).
-- Real scripts over the quests harness: a world server (peer 0, -coop_dedicated), a player on a map server's level (peer 1, character
-- 500) and that map server (bridge 0x101). Run: tools\test_lua.cmd srv_tasks
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_story", "coop_srv_quests_core", "coop_srv_tasks" }
local BRIDGE = 0x101

-- the facade coop_mode as the live layers answer (docs\contracts\coop_mode_api.md section 2), for the Core and the server script
local function facade(M, answers)
	local f = {}
	for k, v in pairs(M.facade_stub) do f[k] = v end
	f.actor_is_player = function() return answers.player end
	f.seat_plays = function(peer)
		if peer == M.self_peer and not answers.player then return false end
		for _, p in ipairs(M.players or {}) do if p.id == peer then return true end end
		return false
	end
	f.leads_here = function() return answers.leads == true end
	M.env.coop_mode = f
	return f
end

local function world(M, answers)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.stats, M.rank, M.rept = {}, 0, 0
	e.game_statistics = {
		increment_statistic = function(name) M.stats[#M.stats + 1] = name end,
		increment_rank = function(v) M.rank = M.rank + v end,
		increment_reputation = function(v) M.rept = M.rept + v end,
	}
	-- the stock of the four effects (xr_effects.script:159, :3199, :6207, xr_conditions.script:1348 of G.A.M.M.A.)
	M.sounds, M.surge_calls, M.ceasefire = {}, {}, {}
	e.xr_effects.play_sound_on_actor = function(actor, obj, p) M.sounds[#M.sounds + 1] = p[1] end
	e.xr_effects.actor_surge_immuned = function(actor, npc, p)
		M.surge_calls[#M.surge_calls + 1] = p[1]
		e.save_var(e.db.actor, "surge_immuned", p[1] == "true" or nil)
	end
	e.xr_effects.stalker_ceasefire = function() M.ceasefire[#M.ceasefire + 1] = e.get_actor_true_community() end
	e.xr_effects.drx_sl_change_factions = function(a, n, p) M.faction = p[1] end
	e.xr_effects.decrease_rep = function(a, n, p) e.game_statistics.increment_reputation(-tonumber(p[1])) end
	e.get_actor_true_community = function() return "stalker" end -- the ghost's
	M.goodwill = { [0] = { freedom = 0 }, [500] = { freedom = 1200 } }
	e.relation_registry = { community_goodwill = function(comm, id) return (M.goodwill[id] or {})[comm] or 0 end }
	e.xr_conditions.is_faction_friend_to_actor = function(actor, npc, p)
		return e.relation_registry.community_goodwill(p[1], e.AC_ID) >= 1000
	end
	M.stock = {
		sound = e.xr_effects.play_sound_on_actor, surge = e.xr_effects.actor_surge_immuned,
		ceasefire = e.xr_effects.stalker_ceasefire, friend = e.xr_conditions.is_faction_friend_to_actor,
	}
	for _, id in ipairs({ "snd_t", "def_t", "cf_t", "talk_t", "task_fanat_training_1", "cs_task0_ambush_renegade_story",
		"cs_task0_ambush_renegade_story2" }) do M.ini[id] = {} end
	return facade(M, answers)
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		local m = M.env[n]
		if m and m.on_game_start then m.on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local function drop_machine(M)
	for i = #MACHINES, 1, -1 do if MACHINES[i] == M then table.remove(MACHINES, i) end end
end

-------------------------------------------------------------------------------
print("== co-op: the server's task code never starts")
do
	local Co = machine("host", 0)
	world(Co, { player = true, leads = true })
	Co.players = { { id = 0, is_self = true, avatar_id = 0 } }
	Co.infos.fanat_training_start_done = true -- a dialog closed by its info, in a co-op world
	boot(Co)
	fire(Co, "actor_on_update")
	check(Co.env.coop_srv_tasks ~= nil, "(the script loads in the co-op process)")
	check(Co.handlers.coop_rep_map == nil and Co.handlers.coop_rep_map_ack == nil, "no map server's effects are taken in the co-op")
	check(Co.env.xr_effects.play_sound_on_actor == Co.stock.sound and Co.env.xr_effects.actor_surge_immuned == Co.stock.surge
		and Co.env.xr_effects.stalker_ceasefire == Co.stock.ceasefire
		and Co.env.xr_conditions.is_faction_friend_to_actor == Co.stock.friend, "the four effects stay the stock's")
	check(Co.env.coop_quests_core.part("talk") == nil, "no part \"talk\"")
	check(Co.infos.fanat_training_start_done == true and Co.env.db.storage[0].pstor.coop_lost_gives == nil,
		"no world is healed of lost gives in the co-op")
	drop_machine(Co)
end

-------------------------------------------------------------------------------
print("== setup: a world server, a player on a map server's level, that map server")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
local Ms = machine("client", BRIDGE)
world(Hm, { player = false })
world(Cm, { player = true })
world(Ms, { player = false, leads = true })
local partner_of = {}
local function levels(M)
	M.env.coop.levels = {
		split = function() return true end,
		my_level = function() return M == Hm and 1 or 2 end,
		level_of_player = function(peer) return peer == 1 and 2 or nil end,
		bridge_of_player = function(peer) return peer == 1 and BRIDGE or nil end,
		map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
		talking = function(peer) return partner_of[peer] ~= nil end,
		talk_partner = function(peer) return partner_of[peer] end,
	}
end
levels(Hm); levels(Cm); levels(Ms)
Hm.env.coop.is_dedicated = function() return true end
Ms.env.coop.is_map_server = function() return true end
Hm.new_obj(500, "coop_player_avatar", vec(10, 0, 10), { _stalker = true })
Ms.new_obj(500, "coop_player_avatar", vec(10, 0, 10), { _stalker = true })
Hm.new_obj(777, "stalker_trader", vec(12, 0, 10), { _stalker = true })
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0, nick = "anna" } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500, nick = "anna" } }
Hm.env.coop_faction = { faction_of_character = function(id) return id == 500 and "freedom" or nil end }
-- the world that has to be healed: the Fanat's dialog is closed, his training never was the group's (builds 45-49)
for _, m in ipairs({ Hm, Cm, Ms }) do m.ini.task_fanat_training_1 = {} end
Hm.infos.fanat_training_start_done = true
boot(Hm); boot(Cm); boot(Ms)
check(Hm.env.coop_srv_tasks ~= nil and Hm.handlers.coop_rep_map ~= nil, "(the world server takes the map servers' effects)")
check(Ms.handlers.coop_rep_map_ack ~= nil, "(the map server takes the world server's answers)")

-------------------------------------------------------------------------------
print("== a world hurt by a give that died: the info of the dialog is taken back, once (was coop_tasks)")
do
	fire(Hm, "actor_on_update")
	local pstor = Hm.env.db.storage[0].pstor
	check(pstor.coop_lost_gives == true and Hm.infos.fanat_training_start_done == nil,
		"the world server looked when it started: the Fanat offers his training again, the world keeps that it looked")
	local T = Hm.env.coop_srv_tasks
	Hm.infos.fanat_training_start_done = true
	Hm.infos.cs_story_task0_ambush_renegade_start = true -- "The Last Dawn": asked for ...
	Hm.infos.renegade_cs_story_squad_1_death = true -- ... and it ran: its squad is dead
	Hm.infos.cs_story_task0_ambush_renegade_done = true -- its second part: the phrase was said ...
	Hm.tm.task_info.cs_task0_ambush_renegade_story2 = { id = "cs_task0_ambush_renegade_story2", stage = 0, status = "selected" } -- ... and it is on
	Hm.engine_tasks.cs_task0_ambush_renegade_story2 = { state = "in", get_id = function() return "cs_task0_ambush_renegade_story2" end }
	check(T.heal_lost_gives() == 1, "one give that was lost")
	check(Hm.infos.fanat_training_start_done == nil, "the Fanat offers his training again")
	check(Hm.infos.cs_story_task0_ambush_renegade_start == true, "a task that ran is left alone")
	check(Hm.infos.cs_story_task0_ambush_renegade_done == true, "a task that is on is left alone")
	Hm.tm.task_info.cs_task0_ambush_renegade_story2, Hm.engine_tasks.cs_task0_ambush_renegade_story2 = nil, nil
	Hm.infos.cs_story_task0_ambush_renegade_done = nil
	-- what such a give left behind: the task object in the journal that is no task of the engine
	Hm.infos.fanat_training_start_done = true
	Hm.tm.task_info.task_fanat_training_1 = { id = "task_fanat_training_1", stage = 0, status = "selected" }
	check(T.heal_lost_gives() == 1, "a half-made task is a lost give too")
	check(Hm.tm.task_info.task_fanat_training_1 == nil and Hm.infos.fanat_training_start_done == nil,
		"the half-made task leaves the journal and its dialog offers it again")
	pstor.coop_lost_gives = nil -- a world of an older build
	Hm.infos.fanat_training_start_done = true
	T._heal_once()
	check(Hm.infos.fanat_training_start_done == nil and pstor.coop_lost_gives == true, "an older world is looked at once")
	Hm.infos.fanat_training_start_done = true
	T._heal_once()
	NOW = NOW + 1000
	fire(Hm, "actor_on_update")
	check(Hm.infos.fanat_training_start_done == true, "and not again in this world")
	Hm.infos.fanat_training_start_done = nil
	fire(Ms, "actor_on_update")
	fire(Cm, "actor_on_update")
	pump()
	check(Ms.env.db.storage[0].pstor.coop_lost_gives == nil and Cm.env.db.storage[0].pstor.coop_lost_gives == nil,
		"only the world server heals: not a map server, not a player's machine")
end

-------------------------------------------------------------------------------
print("== a map server's personal effects pass through the world server (was coop_tasks)")
do
	local before = Cm.rept
	Ms.env.coop_tasks.with_character(500, function() Ms.env.game_statistics.increment_reputation(-25) end)
	pump()
	check(Cm.rept == before - 25 and Ms.rept == 0 and Hm.rept == 0, "the map server's penalty reaches the player once, through the world server")
	local packet
	for _, message in ipairs(Ms.sent) do if message.name == "coop_rep_map" then packet = message.payload end end
	local function ack_count()
		local n = 0
		for _, m in ipairs(Hm.sent) do if m.name == "coop_rep_map_ack" then n = n + 1 end end
		return n
	end
	local acks = ack_count()
	if packet then Hm.handlers.coop_rep_map(packet, BRIDGE); pump() end
	check(acks > 0 and ack_count() == acks + 1 and Cm.rept == before - 25, "a duplicate is answered without a second application")
	if packet then Hm.handlers.coop_rep_map(packet, 1); pump() end
	check(Cm.rept == before - 25, "a player's machine cannot pass for a map server")
	local saved = {}
	Hm.env.coop_tasks.save_effects(saved)
	Hm.env.coop_tasks.load_effects(saved)
	if packet then Hm.handlers.coop_rep_map(packet, BRIDGE); pump() end
	check(Cm.rept == before - 25, "the duplicate check survives the world server's save and load")
	local pending = 0
	for _, list in pairs(Ms.env.coop_tasks.fx_pending()) do pending = pending + #list end
	check(pending == 0, "the world server's answer took it off the map server's list")
	-- inside a story condlist of the map server's level (was test_quests: "not swallowed by the shared story relay")
	local r0 = Cm.rept
	Ms.env.coop_tasks.with_character(500, function()
		Ms.env.xr_logic.pick_section_from_condlist(nil, nil, { src = "%=decrease_rep(20)%" })
	end)
	pump()
	check(Cm.rept == r0 - 20 and Ms.rept == 0, "a personal effect in a story condlist of a map server is not swallowed by the story relay")
	-- a faction change on the map server's level: the player's machine runs it
	Ms.env.coop_tasks.with_character(500, function() Ms.env.xr_effects.drx_sl_change_factions(Ms.actor, nil, { "freedom" }) end)
	pump()
	check(Cm.faction == "freedom" and Ms.faction == nil and Hm.faction == nil, "a personal faction change on a map server reaches his machine")
	-- the world server does not answer: the map server sends it again, once a second, until it does
	local queue = {}
	local stock_send = Ms.env.coop.send_event
	Ms.env.coop.send_event = function(name, payload, target)
		if name == "coop_rep_map" then queue[#queue + 1] = payload return true end
		return stock_send(name, payload, target)
	end
	Ms.env.coop_tasks.with_character(500, function() Ms.env.game_statistics.increment_rank(7) end)
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	check(#queue == 2, "unanswered: sent again after a second (" .. #queue .. " sends)")
	Ms.env.coop.send_event = stock_send
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	pump()
	check(Cm.rank == 7, "the repeat that got through: his rank, once (" .. Cm.rank .. ")")
	local n = 0
	for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n = n + 1 end end
	NOW = NOW + 1100
	fire(Ms, "actor_on_update")
	local n2 = 0
	for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n2 = n2 + 1 end end
	check(n2 == n, "answered: not sent again")
end

-------------------------------------------------------------------------------
print("== character 0 on a server: the world server's seat plays no character, its effects are nobody's")
do
	local function sends()
		local n = 0
		for _, m in ipairs(Ms.sent) do if m.name == "coop_rep_map" then n = n + 1 end end
		return n
	end
	local n0, h0, c0, m0 = sends(), Hm.rept, Cm.rept, Ms.rept
	Ms.env.coop_tasks.with_character(0, function() Ms.env.game_statistics.increment_reputation(-15) end)
	Ms.env.coop_tasks.with_character(0, function() Ms.env.xr_effects.drx_sl_change_factions(Ms.actor, nil, { "dolg" }) end)
	pump()
	check(sends() == n0, "the map server sends nothing up for character 0 (it went up and was dropped there, then sent again for good)")
	check(Hm.rept == h0 and Cm.rept == c0 and Ms.rept == m0 and Ms.faction == nil and Hm.faction == nil,
		"nobody's: not the map server's ghost, not the world server's, not a player")
	for _ = 1, 3 do NOW = NOW + 1100 fire(Ms, "actor_on_update") end
	check(sends() == n0, "and nothing waits on the map server's list for it")
	Hm.env.coop_tasks.with_character(0, function() Hm.env.xr_effects.drx_sl_change_factions(Hm.actor, nil, { "dolg" }) end)
	check(Hm.faction == nil, "the world server's own logic: no faction change of its ghost either")
	-- a seat 0 that plays a character (the facade says so): its effects are his, peer 0's
	Ms.env.coop_mode.seat_plays = function(peer) return peer == 0 or peer == 1 end
	Ms.env.coop_tasks.with_character(0, function() Ms.env.game_statistics.increment_reputation(-4) end)
	check(sends() == n0 + 1, "a seat 0 that plays: its character's effect goes up to it, as before")
	Ms.env.coop_mode.seat_plays = function(peer) return peer == 1 end
	pump()
end

-------------------------------------------------------------------------------
print("== reputation and rank with no recipient on a server ghost")
do
	local map_rept, map_rank = Ms.rept, Ms.rank
	Ms.env.game_statistics.increment_reputation(-33)
	Ms.env.game_statistics.increment_rank(12)
	pump()
	check(Ms.rept == map_rept and Ms.rank == map_rank, "the map server's ghost earns nobody's reputation or rank")
	local world_rept, world_rank = Hm.rept, Hm.rank
	Hm.env.game_statistics.increment_reputation(9)
	Hm.env.game_statistics.increment_rank(4)
	-- An older map server may still send its character-0 penalty. The world answers even when nobody owns it.
	local payload = Ms.env.coop_main.encode({ k = "stat", f = "rept", e = "legacy", q = 1, i = 0, n = -15 })
	local before = #Hm.sent
	Hm.handlers.coop_rep_map(payload, BRIDGE)
	pump()
	check(Hm.rept == world_rept and Hm.rank == world_rank, "the world server's ghost earns nothing from its own logic or a map's")
	local ack = Hm.sent[before + 1]
	check(ack and ack.name == "coop_rep_map_ack" and ack.payload == "1", "the world answers a legacy character-0 penalty")
end

-------------------------------------------------------------------------------
print("== the part \"talk\": the NPC a player on a map server's level talks to (protocol 33)")
do
	local T = Hm.env.coop_tasks
	local tp = Hm.env.coop_quests_core.part("talk")
	check(type(tp) == "table" and type(tp.partner) == "function", "the world server gives the part")
	partner_of[1] = 777
	check(tp and tp.partner(1) == 777, "his partner as his map server says (coop.levels.talk_partner)")
	check(not T._talk_vague(1) and T._spoke_to(1, 777) and not T._spoke_to(1, 778), "only the reported partner was spoken to")
	partner_of[1] = nil
	check(tp and tp.partner(1) == false and not T._talk_vague(1), "nobody is a definite answer")
	check(T._spoke_to(1, 777), "a confirmed talk stays recent after the dialog closes")
	NOW = NOW + 16000
	check(not T._spoke_to(1, 777), "the recent talk expires after fifteen seconds")
	for _, id in ipairs({ 1.5, 65535 }) do
		partner_of[1] = id
		check(not T._talk_vague(1) and not T._spoke_to(1, id), "invalid partner is a definite negative: " .. id)
	end
	partner_of[1] = 65534
	check(T._spoke_to(1, 65534), "the highest valid NPC id can be a partner")
	partner_of[1] = nil
	local read_partner = tp.partner
	tp.partner = function() error("no partner report") end
	Hm.env.coop.levels.talking = function() return true end
	check(T._talk_vague(1) and T._spoke_to(1, 777), "a failed partner callback falls back to the general dialog fact")
	tp.partner = read_partner
	Hm.env.coop.levels.talking = function(peer) return partner_of[peer] ~= nil end
	check(Ms.env.coop_quests_core.part("talk") == nil and Cm.env.coop_quests_core.part("talk") == nil,
		"not on a map server, not on a player's machine")
	-- An older engine gives the general dialog fact only.
	local Old = machine("host", 0x55)
	world(Old, { player = false })
	Old.env.coop.is_dedicated = function() return true end
	Old.env.coop.levels = {
		split = function() return true end, my_level = function() return 1 end,
		level_of_player = function(peer) return peer == 1 and 2 or nil end,
		talking = function(peer) return peer == 1 end,
	}
	Old.players = { { id = 0x55, is_self = true, avatar_id = 0 } }
	boot(Old)
	local old_talk = Old.env.coop_quests_core.part("talk")
	check(old_talk and old_talk.partner(1) == nil, "an older engine registers a partner callback that reports no facts")
	check(Old.env.coop_tasks._talk_vague(1) and Old.env.coop_tasks._spoke_to(1, 777), "an older engine still accepts the general dialog fact")
	drop_machine(Old)
end

-------------------------------------------------------------------------------
print("== Server task effects and task-end surge cleanup")
do
	local function finish(id, f)
		Cm.tm:give_task(id, 777)
		pump()
		check(Hm.tm.task_info[id] ~= nil and Hm.env.coop_tasks.taker(id) == 1, "(" .. id .. ": he took it)")
		Hm.on_complete = Hm.on_complete or {}
		Hm.on_complete[id] = f
		Hm.env.task_manager.task_callback({ get_id = function() return id end }, Hm.env.task.completed)
		pump()
	end
	-- 1. play_sound_on_actor (lttz_ms: the teleport sound at a task's end): the ghost played it, nobody heard it
	finish("snd_t", function() Hm.env.xr_effects.play_sound_on_actor(Hm.actor, nil, { "gimlet_teleport" }) end)
	check(#Cm.sounds == 1 and Cm.sounds[1] == "gimlet_teleport" and #Hm.sounds == 0,
		"play_sound_on_actor: his machine plays it, not the world server's ghost")
	-- 2. Only test task-end delivery. The map's level logic does not grant the player immunity.
	Hm.env.db.storage[0].pstor.surge_immuned = true
	finish("def_t", function() Hm.env.xr_effects.actor_surge_immuned(Hm.actor, nil, { "false" }) end)
	check(#Cm.surge_calls == 1 and Cm.surge_calls[1] == "false" and Hm.env.db.storage[0].pstor.surge_immuned == true,
		"the player receives the task-end cleanup and the world server's flag stays set")
	-- 3. stalker_ceasefire (the scorcher off, lttz_ll): the truce with his faction, not the ghost's
	finish("cf_t", function() Hm.env.xr_effects.stalker_ceasefire(Hm.actor, nil, {}) end)
	check(Hm.ceasefire[1] == "freedom", "stalker_ceasefire: the world server runs it with his faction (" .. tostring(Hm.ceasefire[1]) .. ")")
	Hm.env.xr_effects.stalker_ceasefire(Hm.actor, nil, {})
	check(Hm.ceasefire[2] == "stalker" and Hm.env.get_actor_true_community() == "stalker",
		"outside a task's end: the stock's; the stock function is back")
	-- 4. is_faction_friend_to_actor in an offer the world server builds for him on his level (the far view's scope names him)
	local scope = nil
	Hm.env.coop_srv_quests_far = { in_scope = function() return scope end }
	local friend = Hm.env.xr_conditions.is_faction_friend_to_actor
	check(friend(Hm.actor, nil, { "freedom" }) == false, "outside his scope: the ghost's goodwill (0), as the stock")
	scope = { peer = 1, avatar = 500 }
	check(friend(Hm.actor, nil, { "freedom" }) == true, "in the scope of his level: his goodwill (1200)")
	check(Hm.env.AC_ID == 0, "AC_ID is back")
	scope = nil
	Hm.env.coop_srv_quests_far = nil
	-- his machine runs its own calls as the stock
	check(Cm.env.xr_effects.play_sound_on_actor == Cm.stock.sound and Cm.env.xr_effects.stalker_ceasefire == Cm.stock.ceasefire,
		"a player's machine keeps the stock effects")
	-- a forwarded name his machine did not allow (an old world server) is not run
	local s0 = #Cm.sounds
	Cm.handlers.coop_trw("k=sfx;f=sstalker_ceasefire;q=n9999", 0)
	check(#Cm.ceasefire == 0 and #Cm.sounds == s0, "a forwarded effect his machine does not allow: not run")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
