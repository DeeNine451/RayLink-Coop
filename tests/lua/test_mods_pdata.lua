-- Per-player m_data: client restore at load, report, host store + ack. Run as client, then host (one state each).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")

-- fake mods (present before the start, like real scripts)
EF_LIVE = { XP = 0 }
experience_core = { save_state = function(m)
	m.experience_framework_savedata = m.experience_framework_savedata or {}
	m.experience_framework_savedata.XP = EF_LIVE.XP
end }
wd_core = {}
-- New Player Experience keeps what it has shown in the save (npe_director.save_state: m.npe.npe_state[deck][set].played),
-- Fair Fast Travel keeps the player's cooldowns beside the ids of the zones it spawned in the world (game_fast_travel.save_state)
NPE_LIVE = { gamma = { gun = { played = false }, task = { played = false } } }
NPE_SAVES = 0
npe_director = {
	get_state = function() return NPE_LIVE end,
	save_state = function(m) -- the real one prints "$ NPE Save State" and the whole table every time
		NPE_SAVES = NPE_SAVES + 1
		m.npe = m.npe or {}
		m.npe.npe_state = NPE_LIVE
	end,
}
FFT_LIVE = { cooldowns = { ft = 0 }, locations_found = 0 }
game_fast_travel = { save_state = function(m)
	m.fast_travel_system = { spawned_travel_zones = { 11, 12 }, zone_spawn_version = 3, survival_paused = false, stored_satiety = 1,
		locations_found = FFT_LIVE.locations_found, cooldowns = FFT_LIVE.cooldowns }
end }
haru_skills = { creature_on_before_hit = function() end }
perk_based_artefacts = { process_artefacts = function() end }

if which == "client" then
	print("== pdata (client)")
	make_actor()
	start_all()
	local P = coop_mods_pdata
	check(P.owns("experience_framework_savedata") and P.owns("skills_levels")
		and P.owns("perk_based_artefacts_cooldowns"), "mod keys registered (EF, skills, PBA)")
	check(not P.owns("wd_bracer_worn"), "Wearable Devices is not adapted (clean room, 2026-10-29)")
	check(not P.owns("sleep") and not P.owns("RF_freq"), "stock keys left to coop_economy_mdata")
	-- Owner 2026-11-16: "the tutorial menu starts again and again, after a level change I am taught everything anew, as if the
	-- state is not saved". It was not: a client loads the host's save at every level change, with the host's "nothing shown yet".
	check(P.owns("npe"), "New Player Experience: what was shown is a player's own")
	check(P.owns("fast_travel_system"), "Fair Fast Travel: the cooldowns and the found points are a player's own")

	-- 1. first join: no record for this character -> the host's values are dropped
	local save = {
		experience_framework_savedata = { XP = 999, nls_storage = { npc = 3 } }, -- the host's XP
		skills_levels = { strength = 9 },
		npe = { npe_state = { gamma = { gun = { played = true } } } }, -- the host's (a world server's: nobody played anything)
		fast_travel_system = { spawned_travel_zones = { 11, 12 }, zone_spawn_version = 3, locations_found = 7, cooldowns = { ft = 900 } },
		coop_mods_pdata = { ["777"] = { t = "other", d = { skills_levels = { strength = 1 } } } },
		-- Build 56 (review of 2026-11-18): Perk-Based Artefacts keeps five keys, only the cooldowns were a player's own; the
		-- host's running perk effects, statuses, virtual artefacts and Lucifer condition ran on every client after a load
		perk_based_artefacts_effects = { { time = 5, effect_function = "host" } },
		perk_based_artefacts_status_effects = { af_lucifer_overcharge = { time = 1800 } },
		perk_based_artefacts_virtual_artefacts = { af_sandstone = 1 },
		perk_based_artefacts_lucifer_condition = 0.3,
	}
	local seen_at_load
	RegisterScriptCallback("load_state", function(m) seen_at_load = { xp = m.experience_framework_savedata.XP, sk = m.skills_levels } end)
	alife_storage_manager.CALifeStorageManager_load(save)
	local m = alife_storage_manager.get_state()
	check(m.skills_levels == nil, "new player: the host's values are not taken")
	check(m.experience_framework_savedata.XP == nil and m.experience_framework_savedata.nls_storage.npc == 3,
		"sub-keys: player part cleared, world part (nls_storage) kept")
	check(seen_at_load and seen_at_load.xp == nil and seen_at_load.sk == nil, "load_state already saw the player's values")
	check(m.coop_mods_pdata == nil, "other players' records dropped on the client")
	check(P.owns("perk_based_artefacts_effects") and P.owns("perk_based_artefacts_status_effects")
		and P.owns("perk_based_artefacts_virtual_artefacts") and P.owns("perk_based_artefacts_lucifer_condition"),
		"perk artefacts: the running effects, statuses, virtual artefacts and the Lucifer's condition are a player's own")
	check(m.perk_based_artefacts_effects == nil and m.perk_based_artefacts_status_effects == nil
		and m.perk_based_artefacts_virtual_artefacts == nil and m.perk_based_artefacts_lucifer_condition == nil,
		"perk artefacts: a new player does not run the host's effects")
	check(m.npe == nil, "tutorials: a new player does not take the host's list of what was shown")
	check(m.fast_travel_system.cooldowns == nil and m.fast_travel_system.locations_found == nil, "fast travel: the host's cooldowns are not his")
	check(m.fast_travel_system.spawned_travel_zones[2] == 12 and m.fast_travel_system.zone_spawn_version == 3,
		"fast travel: the zones spawned in the world stay the host's")

	-- 2. report
	EF_LIVE.XP = 42
	m.skills_levels = { strength = 2 }
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	local piece, raw = sent("mods.pd")
	check(piece and raw.target == 0, "report sent to the host")
	local d = coop_mods_core.deser(piece.d)
	check(d and d.experience_framework_savedata.XP == 42 and d.skills_levels.strength == 2, "report carries primed values")
	check(d.experience_framework_savedata.nls_storage == nil, "report carries only the listed sub-keys")
	check(d.npe and d.npe.npe_state.gamma.gun.played == false, "the report carries the tutorials' state as the mod saves it")
	check(d.fast_travel_system and d.fast_travel_system.cooldowns.ft == 0 and d.fast_travel_system.spawned_travel_zones == nil,
		"and the player's part of the fast travel state, without the world's zones")
	check(STASH.coop_mods_pdata and STASH.coop_mods_pdata:sub(1, 1) == "|", "stash written (no token yet)")
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil, "unchanged values are not sent again")
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "TOK1" }), 0)
	check(STASH.coop_mods_pdata:sub(1, 5) == "TOK1|", "ack token stored with the data")
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "EVIL" }), 1)
	check(STASH.coop_mods_pdata:sub(1, 5) == "TOK1|", "ack from a non-host ignored")

	-- 3. level change in the same session: the stash builds on the host's record -> stash wins
	m.skills_levels = { strength = 5 } -- not reported yet
	local s5 = coop_mods_core.ser({ skills_levels = { strength = 5 }, experience_framework_savedata = { XP = 43 } })
	STASH.coop_mods_pdata = "TOK1|" .. s5
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 }, experience_framework_savedata = { XP = 999 },
		coop_mods_pdata = { ["500"] = { t = "TOK1", d = { skills_levels = { strength = 2 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 5 and m.experience_framework_savedata.XP == 43, "same lineage: the newer session data wins")

	-- 3'. perk artefacts across a level change: his own statuses and Lucifer condition, not the host's
	STASH.coop_mods_pdata = "TOK1|" .. coop_mods_core.ser({ skills_levels = { strength = 5 }, experience_framework_savedata = { XP = 43 },
		perk_based_artefacts_status_effects = { af_moh = { time = 60 } }, perk_based_artefacts_lucifer_condition = 0.8 })
	alife_storage_manager.CALifeStorageManager_load({
		perk_based_artefacts_status_effects = { af_lucifer_overcharge = { time = 1800 } }, perk_based_artefacts_lucifer_condition = 0.3,
		perk_based_artefacts_virtual_artefacts = { af_sandstone = 1 },
		coop_mods_pdata = { ["500"] = { t = "TOK1", d = {} } },
	})
	m = alife_storage_manager.get_state()
	check(m.perk_based_artefacts_status_effects and m.perk_based_artefacts_status_effects.af_moh ~= nil
		and m.perk_based_artefacts_status_effects.af_lucifer_overcharge == nil and m.perk_based_artefacts_lucifer_condition == 0.8
		and m.perk_based_artefacts_virtual_artefacts == nil, "perk artefacts: after the level change his own statuses run, the host's do not")

	-- 3a. the owner's case: a tutorial was shown and a trip put fast travel on cooldown, then he changed level
	NPE_LIVE.gamma.gun.played = true
	FFT_LIVE.cooldowns, FFT_LIVE.locations_found = { ft = 5000 }, 3
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	local piece3 = sent("mods.pd")
	local d3 = piece3 and coop_mods_core.deser(piece3.d)
	check(d3 and d3.npe.npe_state.gamma.gun.played == true and d3.fast_travel_system.cooldowns.ft == 5000, "the change is reported")
	check(NPE_SAVES == 0, "the tutorial mod's save_state is not run for a report (it writes to the log each time)")
	local seen_npe
	RegisterScriptCallback("load_state", function(mm) seen_npe = mm.npe and mm.npe.npe_state end)
	alife_storage_manager.CALifeStorageManager_load({
		npe = { npe_state = { gamma = { gun = { played = false }, task = { played = false } } } }, -- the server's save again
		fast_travel_system = { spawned_travel_zones = { 11, 12, 13 }, zone_spawn_version = 4, locations_found = 0, cooldowns = { ft = 0 } },
		coop_mods_pdata = { ["500"] = { t = "TOK1", d = {} } },
	})
	m = alife_storage_manager.get_state()
	check(seen_npe and seen_npe.gamma.gun.played == true, "after the level change the tutorial mod loads HIS list: the shown one is not shown again")
	check(seen_npe and seen_npe.gamma.task.played == false, "and one he has not seen yet is still to come")
	check(m.fast_travel_system.cooldowns.ft == 5000 and m.fast_travel_system.locations_found == 3, "his cooldown and found points came with him")
	check(m.fast_travel_system.spawned_travel_zones[3] == 13 and m.fast_travel_system.zone_spawn_version == 4, "the world's zones are the new save's")

	-- 3b. Build 56 (live 2026-11-18, "everything a client has must come through a transition exactly as in a usual game").
	-- The engine says the load starts while the old world is still up (coop_main.on_world_leaving(epoch of the new world)):
	-- the keys go into the stash as they are NOW, not as the last 15 s report had them, and the load reads them back whatever
	-- the host did with its record meanwhile.
	local world_epoch = 4
	coop.world_epoch = function() return world_epoch end
	local leaving_seen
	RegisterScriptCallback("coop_on_world_leaving", function(epoch) leaving_seen = epoch end)
	EF_LIVE.XP = 77 -- changed 3 s ago: the 15 s report has not come yet
	m.skills_levels = { strength = 6 }
	SENT = {}
	coop_main.on_world_leaving(5)
	check(leaving_seen == 5, "other scripts hear of the load too (coop_on_world_leaving)")
	check(sent("mods.pd") == nil, "nothing is sent to a host that is saving already")
	check(STASH.coop_mods_pdata:sub(1, 8) == "@load:5|", "the stash holds the state this load starts with")
	coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "TOK2" }), 0)
	check(STASH.coop_mods_pdata:sub(1, 8) == "@load:5|", "a late ack of an older report does not put the older report back")
	m.skills_levels = { strength = 1 } -- whatever the dying world still does
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil and STASH.coop_mods_pdata:sub(1, 8) == "@load:5|", "no report after it in this world")
	world_epoch = 5
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 }, experience_framework_savedata = { XP = 999 },
		-- the host stored the older report under a new token after the client's last ack: the tokens do not match
		coop_mods_pdata = { ["500"] = { t = "TOK2", d = { skills_levels = { strength = 5 }, experience_framework_savedata = { XP = 43 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 6 and m.experience_framework_savedata.XP == 77,
		"the state kept at the start of the load is what the player has after it (" .. tostring(m.skills_levels and m.skills_levels.strength) .. ")")
	check(STASH.coop_mods_pdata:sub(1, 5) == "TOK2|", "from then on the stash builds on the save's record again")
	SENT = {}
	EF_LIVE.XP = 78
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") ~= nil, "and the reports go on in the new world")
	-- kept for another world (the host loaded a save while this one was coming): not this world's
	STASH.coop_mods_pdata = "@load:9|" .. s5
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 },
		coop_mods_pdata = { ["500"] = { t = "TOK2", d = { skills_levels = { strength = 2 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 2, "a state kept for another world is not read: the host's record is")
	STASH.coop_mods_pdata = "TOK1|" .. s5
	coop.world_epoch = nil

	-- 3c. a kept state whose load never came (a transition called off): after KEPT_MS the reports go on
	EF_LIVE.XP = 90
	coop_main.on_world_leaving(6)
	SENT = {}
	NOW = NOW + 20000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") == nil, "kept: quiet while the load may still come")
	NOW = NOW + 200000
	SendScriptCallback("actor_on_update")
	check(sent("mods.pd") ~= nil, "kept, but no load came in 3 minutes: the reports go on")
	-- 3d. the own character is not known at the load: the keys stay the host's, and are not reported as this player's
	do
		local real_hid = coop_mods_core.hid
		coop_mods_core.hid = function() return 0 end
		alife_storage_manager.CALifeStorageManager_load({ skills_levels = { strength = 9 }, experience_framework_savedata = { XP = 999 } })
		coop_mods_core.hid = real_hid
		SENT = {}
		NOW = NOW + 20000
		SendScriptCallback("actor_on_update")
		check(sent("mods.pd") == nil, "the host's values left in place by a failed restore never go into this player's record")
		coop_main.on_world_leaving(7)
		check(STASH.coop_mods_pdata == nil or STASH.coop_mods_pdata:sub(1, 6) ~= "@load:", "nor into the state kept for a load")
	end
	STASH.coop_mods_pdata = "TOK1|" .. s5

	-- 4. the host loaded an older save: its record has another token -> the save wins
	alife_storage_manager.CALifeStorageManager_load({
		skills_levels = { strength = 9 },
		coop_mods_pdata = { ["500"] = { t = "OLD", d = { skills_levels = { strength = 1 } } } },
	})
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 1, "other lineage: the record from the save wins")

	-- 5. single player is untouched
	MODE = "sp"
	alife_storage_manager.CALifeStorageManager_load({ skills_levels = { strength = 9 }, coop_mods_pdata = {} })
	m = alife_storage_manager.get_state()
	check(m.skills_levels.strength == 9 and type(m.coop_mods_pdata) == "table", "sp: storage untouched")
	done("PDATA CLIENT")
else
	print("== pdata (host)")
	make_actor()
	spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 500 })
	start_all()
	local C = coop_mods_core
	local m = alife_storage_manager.get_state()
	m.skills_levels = { strength = 9 } -- the host's own
	local payload = C.ser({ skills_levels = { strength = 3 }, junk_key = { x = 1 } })
	SENT = {}
	C.send_big("pd", payload, 0)
	local parts = {}
	for _, s in ipairs(SENT) do parts[#parts + 1] = s end
	SENT = {}
	for _, s in ipairs(parts) do deliver(s, 1) end
	local rec = m.coop_mods_pdata and m.coop_mods_pdata["500"]
	check(rec and rec.d.skills_levels.strength == 3, "host stored the client's values under its character id")
	check(rec and rec.d.junk_key == nil, "unregistered keys dropped")
	check(m.skills_levels.strength == 9, "host's own values untouched")
	local ack, raw = sent("mods.pd_ack")
	check(ack and ack.t == rec.t and raw.target == 1, "ack with the stored token sent to that client")
	-- a peer without a character is refused
	for _, s in ipairs(parts) do deliver(s, 3) end
	check(m.coop_mods_pdata["nil"] == nil, "unknown peer refused")
	-- records of characters that no longer exist are dropped when the host saves
	m.coop_mods_pdata["4242"] = { t = "x", d = {} }
	SE[500]._sec = "coop_player_avatar"
	SendScriptCallback("save_state", m)
	check(m.coop_mods_pdata["4242"] == nil and m.coop_mods_pdata["500"] ~= nil, "stale records pruned at save, live kept")
	done("PDATA HOST")
end
