-- Companion ownership and stock behavior when the host plays on the group map.
local fixture = dofile("tests/lua/support/companion_levels.lua")
local stand, logic_env, last = fixture.stand, fixture.logic_env, fixture.last

print("== co-op: hand over a companion on the group map")
do
	local W = stand({ split = false })
	local H, A = W.H, W.A
	local L = W.CH._leaders
	L()[300] = 500
	W.level_of[2] = 2 -- what it says is not read: there is one level for everybody
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == "p2", "the line is the nick")
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 501, "the hand-over goes through")
end

print("== co-op: a companion of the host stays the host's, a loaded one is no scripted enemy")
do
	local W = stand({ split = false })
	local H = W.H
	W.refresh()
	check(W.CH.follows(W.comp) == nil, "the host's own: nobody to follow but him")
	H.env.db.actor._pos = vec(1000, 0, 0)
	H.env.coop_npc_players.invalidate()
	H.env.axr_companions.companion_squads[300] = false -- a loaded squad until its first update
	H.beh_actor = nil
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "actor" } })
	check(H.beh_actor == 0, "its target 'actor' is not the nearest player")
end

print("== task_target_anomaly reads the var of the actor: it runs without the leader's identity")
do
	local W = stand({ split = false })
	local H = W.H
	W.CH._leaders()[300] = 500
	W.refresh()
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "task_target_anomaly" } })
	check(H.beh_actor == 0, "the target that reads the actor's var: no identity")
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "actor" } })
	check(H.beh_actor == 500, "any other: its leader")
end

print("== a companion of the host uses the stock dialog")
do
	-- The playing co-op host keeps the stock dialog for his own companion.
	local C = stand({ split = false, env = logic_env })
	local L = load_script(C.H, "coop_npc_logic")
	L.on_game_start()
	C.refresh()
	C.H.env.xr_effects.force_talk(C.H.env.db.actor, C.comp, { "true" })
	check(C.H.stock_talk == 0, "a companion of the co-op host: stock")
end

print("== letting go: the menu's line is the leader's, a story's line anybody's, the story's next recruit gives him back")
do
	local W = stand({ split = false })
	local H, A, B = W.H, W.A, W.B
	H.env.coop.talk_recent = function() return true end
	W.proxy_b._pos = vec(6, 0, 0)
	W.comp_b = B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	local L, cs = W.CH._leaders, H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	local da, db_ = A.env.dialogs_axr_companion, B.env.dialogs_axr_companion
	B.msgs = nil
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "dm_companion_leave", "2")
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "dm_companion_leave of another player: refused")
	check(last(B):find("st_coop_comp_refused_not_yours", 1, true) ~= nil, "he hears why")
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_anomaly_reached", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "the story lets him go by any player's line")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "fanat_training_back_to_village", "1")
	pump()
	check(L()[300] == 500, "the next recruit gives him back to who took him, whoever said the line")

	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_stash_found", "1")
	pump()
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_last_leaders and m.coop_npc_last_leaders[300] == 500, "the save remembers who it was")
	H.fire("load_state", m)
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	check(L()[300] == 500, "and a load does not forget")

	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "dm_companion_leave", "2")
	pump()
	check(L()[300] == nil and cs[300] == nil, "the leader's own dm_companion_leave goes through")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "dm_recruit", "1")
	pump()
	check(L()[300] == 501, "he let him go himself: whoever hires him next leads him")

	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "dm_companion_leave", "2")
	pump()
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()

	print("-- the host's own talk")
	local dh = H.env.dialogs_axr_companion
	W.refresh()
	H.msgs = nil
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "dm_companion_leave", "2")
	check(L()[300] == 500 and cs[300] ~= nil, "his dm_companion_leave of a client's companion: refused")
	check(last(H):find("st_coop_comp_refused_not_yours", 1, true) ~= nil, "he hears why")
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "fanat_training_anomaly_reached", "1")
	check(cs[300] == nil, "a story's line goes through")
	W.refresh()
	check(L()[300] == nil, "(the refresh drops the entry)")
	dh.become_actor_companion(H.env.db.actor, W.comp, "x", "1")
	check(L()[300] == 500, "his recruit in the story gives him back too")
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "fanat_x", "1")
	W.refresh()
	check(next(L()) == nil, "(gone)")
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	W.CH._leaders()[300] = nil -- the host took him, the stock way
	W.refresh()
	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "fanat_x", "1")
	pump()
	check(cs[300] == nil, "a client's line lets the host's companion go")
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	check(L()[300] == nil and cs[300] ~= nil, "and he comes back to the host: who took him")
end

print("== a story's line needs a talk, as a recruit does: a modified client names any dialog")
do
	local W = stand({ split = false })
	local H, A, B = W.H, W.A, W.B
	local talked = false
	H.env.coop.talk_recent = function(peer, npc_id) return talked and peer == 2 and npc_id == 201 end
	W.proxy_b._pos = vec(6, 0, 0)
	W.comp_b = B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	local L, cs = W.CH._leaders, H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	local da, db_ = A.env.dialogs_axr_companion, B.env.dialogs_axr_companion
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "no talk with it: within 15 m he does not send away a companion of somebody else")
	check(W.CH._stats().refused_talk == 1, "the refusal is counted")
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b)
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "nor with no dialog named")
	talked = true
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_anomaly_reached", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "in a talk the story's line goes through")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	talked = false
	L()[300] = 500
	W.refresh()
	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "its leader's own line asks for no talk")
end

print("== the host's own Fanatic: as before")
do
	local function fanat(M)
		local E = M.env
		E.dialogs_escape = {
			set_esc_2_12_stalker_fanat_as_companion = function(a, b)
				local npc = E.dialogs.who_is_npc(a, b)
				E.se_save_var(npc:id(), nil, "companion", true)
				E.axr_companions.setup_companion_logic(npc, nil, false, true)
			end,
		}
	end
	local W = stand({ split = false, env = fanat })
	local H = W.H
	H.env.axr_companions.companion_squads[300] = nil
	W.refresh()
	H.env.dialogs_escape.set_esc_2_12_stalker_fanat_as_companion(H.env.db.actor, W.comp)
	check(H.env.axr_companions.companion_squads[300] == nil and W.CH._leaders()[300] == nil, "the stock's own result")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
