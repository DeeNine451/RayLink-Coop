-- Server debug: world decisions, execution on the selected map and console routing.
local debug_fixture = dofile("tests/lua/support/debug_server.lua")
local world, ask, sent = debug_fixture.world, debug_fixture.ask, debug_fixture.sent
local LEVEL_MK, MK, map_authority = debug_fixture.LEVEL_MK, debug_fixture.MK, debug_fixture.map_authority

print("== the dedicated process waits for its world session")
do
	local H, S = world({ dedicated = true, before_session = true })
	local restored = 0
	H.env.alife_storage_manager = { get_state = function() return { stop_respawns = true } end }
	H.env.coop_debug_cmds.respawns_hook = function() restored = restored + 1 end
	check(H.env.coop_mode.decides_world(), "the dedicated layer decides even before the session")
	H.fire("coop_debug_changed", true, 2)
	check(H.infos.debug_mode_flag_on == nil, "debug changed cannot mark the world until the session")
	H.infos.debug_mode_flag_on = nil
	H.fire("actor_on_first_update")
	check(H.infos.debug_mode_flag_on == nil, "first update cannot mark the world until the session")
	check(restored == 0, "first update cannot restore respawns until the session")
	local out = S.console("time_add h=6")
	check(out:find("the world server's console only", 1, true) ~= nil and #H.time_jumps == 0,
		"console help is available, but world actions wait for the session")
	check(S.console("help"):find("time_add", 1, true) ~= nil, "console help works before the session")
	local previous_restores, previous_jumps = restored, #H.time_jumps
	H.infos.debug_mode_flag_on = nil
	H.set_session(true)
	H.fire("actor_on_first_update")
	check(H.infos.debug_mode_flag_on == true and restored == previous_restores + 1, "active world marks debug and restores saved respawns")
	S.console("time_add h=6")
	check(#H.time_jumps == previous_jumps + 1, "active world runs a debug console action")
end

print("== another level: coop.dbg.run to its map server (B.6, B.10)")
do
	local H = world({ dedicated = true, levels = { [3] = LEVEL_MK } })
	local ok, r = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == true and r == "forwarded", "the answer is forwarded")
	check(#H.created == 0, "the world server made nothing itself")
	local runs = sent(H, "coop.dbg.run")
	check(#runs == 1 and runs[1].target == MK, "one coop.dbg.run to the bridge of his level")
	check(runs[1] and runs[1].t._peer == 3 and type(runs[1].t._rid) == "number" and runs[1].t._c == "spawn_item", "with _peer, _rid, the command")
	check(runs[1] and runs[1].t.sec == "wpn_ak74" and runs[1].t.at == "inv", "and its checked arguments")

	local K = map_authority()
	check(next(K.sync_handlers) == nil and next(K.sync_limits) == nil, "the map server's native sync gate rejects debug registration")
	pump()
	local c = K.created[1]
	check(c and c.sec == "wpn_ak74" and c.t[4] == 900, "the map server makes it, the parent is his character there")
	local notes = sent(H, "coop.dbg.note")
	check(#notes == 1 and notes[1].target == 3 and notes[1].t.ok == true, "the world server tells him how it ended (coop.dbg.note)")
	check(#sent(H, "coop.dbg.say") == 1, "and announces it to everybody")

	-- live 2026-11-08 (10 medkits asked, 20 in the client's inventory): every machine says what it did with the request number
	local function logged(M, pat)
		for _, l in ipairs(M.log) do if l:find(pat) then return l end end
		return nil
	end
	local fwd = logged(H, "spawn_item from p3 %(peer 3%) forwarded to #257 %(rid %d+%): sec wpn_ak74 n 1 at inv")
	check(fwd ~= nil, "the world server logs the forward: requester, bridge, rid, section, n", tostring(fwd))
	local rid = runs[1] and runs[1].t._rid
	check(logged(K, "spawn_item rid " .. tostring(rid) .. " for peer 3 taken from the world server") ~= nil,
		"the map server logs the request it took, with its rid")
	local made = logged(K, "spawn_item rid " .. tostring(rid) .. " for #3 %(peer 3, character 900%): wpn_ak74 x1 at inv, 1 made by a map server: ids 9001")
	check(made ~= nil, "the map server logs what it made: rid, requester, section, n, the ids", tostring(made))
	check(logged(H, "spawn_item rid " .. tostring(rid) .. " done by #257: ok") ~= nil, "the world server logs the end with the rid")
	-- n = 3 on the map server: one line with the three ids
	QUEUE[#QUEUE + 1] = { from = 0, target = MK, name = "coop.dbg.run",
		payload = H.env.coop_main.encode({ _c = "spawn_item", _peer = 3, _rid = 41, sec = "medkit", at = "inv", n = 3 }) }
	pump()
	check(#K.created == 4 and logged(K, "spawn_item rid 41 for #3 .*medkit x3 at inv, 3 made by a map server: ids 9002%-9004") ~= nil,
		"n = 3: three ids in one line (9002-9004)")
	check(K.env.coop_debug_server.ids_text({ 1, 2, 3, 7, 9, 10 }) == "1-3,7,9-10", "ids as ranges")

	-- a coop.dbg.run that does not come from the world server is not taken
	local before = #K.created
	QUEUE[#QUEUE + 1] = { from = 3, target = MK, name = "coop.dbg.run",
		payload = H.env.coop_main.encode({ _c = "spawn_item", _peer = 3, _rid = 99, sec = "wpn_ak74", at = "inv", n = 1 }) }
	pump()
	check(#K.created == before, "a map server takes coop.dbg.run only from the world (from 0)")
end

print("== a map counts requests dropped before debug command dispatch")
do
	local H = world({ dedicated = true })
	local K = map_authority()
	local cases = {
		{ from = 3, peer = 3, name = "an untrusted transport sender" },
		{ from = 0, name = "a missing player field" },
	}
	for i, c in ipairs(cases) do
		QUEUE[#QUEUE + 1] = { from = c.from, target = MK, name = "coop.dbg.run",
			payload = H.env.coop_main.encode({ _c = "spawn_item", _peer = c.peer, _rid = i, sec = "medkit", at = "inv" }) }
		pump()
		check(#K.created == 0, "drops a debug request with " .. c.name)
		check(debug_fixture.trust_failures(K) == i, "counts a debug request with " .. c.name)
	end
end

print("== target commands on another map")
do
	local H2 = world({ dedicated = true })
	H2.obj_level = { [700] = LEVEL_MK }
	local ok = ask(H2, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 700 })
	check(ok == true and H2.orders[1] and H2.orders[1].verb == "kill" and H2.orders[1].id == 700,
		"kill of a map server's object: the far order (quests.far_do)")
	ok = ask(H2, "coop.dbg.target", 3, { v = 1, cmd = "wound", t = 700 })
	local runs = sent(H2, "coop.dbg.run")
	check(ok == true and #runs == 1 and runs[1].target == MK and runs[1].t._c == "wound", "wound there: coop.dbg.run to its bridge")
end

print("== the dedicated world has no player seat")
do
	local D = world({ dedicated = true })
	local PD = D.env.coop_npc_players
	check(PD.player(0) == nil, "dedicated: player(0) is nil, the ghost is nobody")
	local ev = PD.everyone()
	local ghost = false
	for _, o in ipairs(ev) do if o:id() == 0 then ghost = true end end
	check(not ghost, "dedicated: everyone() leaves the ghost out")
end

print("== the server console coop_dbg (B.7)")
do
	local D, S = world({ dedicated = true, debug = false })
	local out = S.console("spawn_item @p3 sec=medkit n=5 at=near")
	check(type(out) == "string" and out:find("debug_off", 1, true) ~= nil, "debug off: the console refuses too (like sv_cheats)")
	check(#D.created == 0, "nothing made")
	D.dbg.on = true
	local K = map_authority()
	out = S.console("spawn_item @p3 sec=medkit n=5 at=near")
	pump()
	check(#D.created == 0 and #K.created == 5 and K.created[1].t[4] == nil and K.created[1].t[1].x == 10,
		"@p3 at=near: five medkits by his character on his map server")
	out = S.console("money @P3 a=500")
	check(D.grants[1] and D.grants[1][1] == 3 and D.grants[1][2] == 500, "money @P3 a=500")
	out = S.console("money a=500")
	check(type(out) == "string" and out:find("no_player", 1, true) ~= nil, "a personal command without @player: no_player")
	out = S.console("surge start")
	check(type(out) == "string", "surge start: a stock word as the argument")
	out = S.console("time_to h=6 m=30")
	check(D.time_jumps[1] and D.time_jumps[1][2] == 20 and D.time_jumps[1][3] == 30, "time_to h=6 m=30")
	out = S.console("help")
	check(type(out) == "string" and out:find("spawn_item", 1, true) ~= nil, "help lists the commands")
	out = S.console("help spawn_item")
	check(type(out) == "string" and out:find("sec=", 1, true) ~= nil, "help spawn_item gives its keys")
	S.console("lua coop_dbg_test_value = 41 + 1")
	check(D.env.coop_dbg_test_value == 42 or rawget(_G, "coop_dbg_test_value") == 42, "lua: the operator runs Lua")
	check(#D.dbg.said >= 6, "every answer goes to coop.debug.say")

	local p = S.parse('spawn_item @Bob sec=wpn_ak74 at=inv')
	check(p and p.cmd == "spawn_item" and p.player == "@Bob" and p.args.sec == "wpn_ak74" and p.args.at == "inv", "parse: cmd, @player, key=value")
	p = S.parse('weather w="w_storm1"')
	check(p and p.args.w == "w_storm1", "parse: a quoted value")
	p = S.parse('lua printf("a b")')
	check(p and p.cmd == "lua" and p.args.code == 'printf("a b")', "parse: lua keeps the rest of the line")
end

print("== the operator's coop_dbg (plan 2026-11-12 §2.3): operator_console(line, parsed, peer)")
do
	local D, S = world({ dedicated = true })
	check(type(S.operator_console) == "function", "coop_debug_server.operator_console exists (the engine refuses every coop_dbg without it)")
	if type(S.operator_console) == "function" then
		-- the class "operator" (Lua on the server's PC) is refused in any case, before anything runs
		local said0 = #D.dbg.said
		local out = S.operator_console("lua coop_dbg_op_value = 7", { cmd = "lua", rest = "coop_dbg_op_value = 7" }, 3)
		check(D.env.coop_dbg_op_value == nil and rawget(_G, "coop_dbg_op_value") == nil, "lua from the operator: nothing ran")
		check(type(out) == "string" and out:find("lua", 1, true) ~= nil and out:find("refused", 1, true) ~= nil,
			"lua from the operator: refused, said so", tostring(out))
		check(#D.dbg.said > said0, "the refusal goes through coop.debug.say (the engine sends it to the operator)")
		S.operator_console("LUA coop_dbg_op_value = 8", { cmd = "LUA" }, 3)
		S.operator_console("Lua coop_dbg_op_value = 9", { cmd = "lua" }, 3)
		S.operator_console("lua coop_dbg_op_value = 10", { cmd = "LuA" }, 3)
		check(D.env.coop_dbg_op_value == nil and rawget(_G, "coop_dbg_op_value") == nil, "LUA / Lua / any letter case: refused")
		S.operator_console("lua coop_dbg_op_value = 11", nil, 3)
		check(D.env.coop_dbg_op_value == nil and rawget(_G, "coop_dbg_op_value") == nil, "lua without the parsed table: refused")

		-- an ordinary command runs as a request of the operator's peer: his own character by default
		out = S.operator_console("money a=500", { cmd = "money", keys = { a = "500" } }, 3)
		check(D.grants and D.grants[1] and D.grants[1][1] == 3 and D.grants[1][2] == 500, "money a=500: granted to the operator's peer 3",
			tostring(out))
		local by_op = false
		for _, l in ipairs(D.dbg.said) do if l:find("p3", 1, true) and l:find("[debug]", 1, true) then by_op = true end end
		check(by_op, "the announcement names the operator, not the console")
		local by_console = false
		for _, l in ipairs(D.dbg.said) do if l:find("[debug] console", 1, true) then by_console = true end end
		check(not by_console, "nothing said as 'console'")
		local K = map_authority()
		out = S.operator_console("spawn_item sec=medkit n=2 at=near", { cmd = "spawn_item" }, 3)
		pump()
		check(#D.created == 0 and #K.created == 2 and K.created[1].t[1].x == 10,
			"spawn_item at=near: on the operator's map server", tostring(out))
		out = S.operator_console("help", { cmd = "help" }, 3)
		check(type(out) == "string" and out:find("spawn_item", 1, true) ~= nil, "help works for the operator")
		out = S.operator_console("money a=1", { cmd = "money" }, 99)
		check(type(out) == "string" and out:find("no_player", 1, true) ~= nil, "a requester who is no player: no_player", tostring(out))
		D.dbg.on = false
		out = S.operator_console("money a=1", { cmd = "money" }, 3)
		check(type(out) == "string" and out:find("debug_off", 1, true) ~= nil and #D.grants == 1, "debug off: refused")
	end
end


print("== bridge completions are tied to the dispatched command and transport sender")
do
	local H = world({ dedicated = true })
	H.bridges = { { bridge = MK, level = LEVEL_MK }, { bridge = MK + 1, level = 3 } }
	local K = map_authority()
	local ok, r = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "medkit", at = "inv" })
	check(ok == true and r == "forwarded", "the world has a pending spawn")
	local run = table.remove(QUEUE, 1)
	local rid = sent(H, "coop.dbg.run")[1].t._rid
	local forged = H.env.coop_main.encode({ rid = rid, ok = true, msg = "spoofed", from = MK })
	for _, sender in ipairs({ 3, MK + 9, MK + 1 }) do
		QUEUE[#QUEUE + 1] = { from = sender, target = 0, name = "coop.dbg.done", payload = forged }
		pump()
		check(#sent(H, "coop.dbg.note") == 0, "a completion from peer " .. sender .. " cannot consume the pending request")
	end
	QUEUE[#QUEUE + 1] = run
	pump()
	check(#K.created == 1 and #sent(H, "coop.dbg.note") == 1, "the dispatched bridge can still finish the request")

	QUEUE[#QUEUE + 1] = { from = 0, target = MK, name = "coop.dbg.run",
		payload = H.env.coop_main.encode({ _c = "spawn_item", _peer = 3, _rid = 0.5, sec = "medkit", at = "inv" }) }
	pump()
	check(#K.created == 1, "a malformed request id cannot run a map command")
end

print("== a late result is accepted until a new forward sweeps the pending request")
do
	local H = world({ dedicated = true })
	map_authority()
	local args = { v = 1, cmd = "spawn_item", sec = "medkit", at = "inv" }
	ask(H, "coop.dbg.spawn", 3, args)
	NOW = NOW + 60001
	pump()
	local notes = sent(H, "coop.dbg.note")
	check(#notes == 1 and notes[1].target == 3 and notes[1].t.ok == true,
		"the selected map's result reaches the requester after 60 seconds")
	local previous_notes = #notes

	ask(H, "coop.dbg.spawn", 3, args)
	local old_run = table.remove(QUEUE, 1)
	NOW = NOW + 60001
	ask(H, "coop.dbg.spawn", 3, args)
	QUEUE[#QUEUE + 1] = old_run
	pump()
	local runs = sent(H, "coop.dbg.run")
	notes = sent(H, "coop.dbg.note")
	check(#notes == previous_notes + 1 and notes[#notes].t.rid == runs[3].t._rid,
		"a new forward sweeps an expired request before its result arrives")
end

print("== malformed results are counted before consuming a request")
do
	local cases = {
		{ id = -1 }, { id = 65535 }, { id = 1.5 }, { id = true },
		{ msg = string.rep("a", 4096) }, { msg = false },
		{ ok = false, code = "not_a_debug_code" }, { ok = false, code = 12 },
	}
	for i, fields in ipairs(cases) do
		local H = world({ dedicated = true })
		map_authority()
		ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "medkit", at = "inv" })
		local run = table.remove(QUEUE, 1)
		local rid = sent(H, "coop.dbg.run")[1].t._rid
		local t = { rid = rid, ok = true, msg = "invalid result" }
		for k, v in pairs(fields) do t[k] = v end
		QUEUE[#QUEUE + 1] = { from = MK, target = 0, name = "coop.dbg.done", payload = H.env.coop_main.encode(t) }
		pump()
		local before = #sent(H, "coop.dbg.note")
		check(before == 0 and #sent(H, "coop.dbg.say") == 0 and debug_fixture.trust_failures(H) == 1,
			"malformed result " .. i .. " is counted and produces no note or announcement")
		QUEUE[#QUEUE + 1] = run
		pump()
		local notes = sent(H, "coop.dbg.note")
		check(#notes == before + 1 and notes[#notes].t.ok == true,
			"the selected map can still finish after malformed result " .. i)
	end
end

print("== a smart uses its map even when the console has no player")
do
	local H, S = world({ dedicated = true })
	local K = map_authority()
	for _, M in ipairs({ H, K }) do
		M.env.SIMBOARD = { smarts_by_names = { test_smart = { id = 701 } } }
		local get_object = M.env.alife_object
		M.env.alife_object = function(id)
			if id == 701 then return { id = id, position = vec(17, 0, 0), m_level_vertex_id = 71, m_game_vertex_id = 72 } end
			return get_object(id)
		end
		M.env.game_graph = function()
			return { vertex = function(_, gv)
				assert(gv == 72)
				return { level_id = function() return LEVEL_MK end }
			end }
		end
	end
	local out = S.console("spawn_object sec=zone_mosquito_bald at=smart sm=test_smart")
	pump()
	check(out:find("forwarded", 1, true) and #H.created == 0 and #K.created == 1,
		"the world console routes to the smart's occupied map without @player", out)
	check(K.created[1] and K.created[1].gv == 72, "the command runs at the smart's vertex")
	H.level_players = 0
	out = S.console("spawn_object sec=zone_mosquito_bald at=smart sm=test_smart")
	pump()
	check(#H.created == 1 and #K.created == 1, "the world makes it offline when the smart's map is empty", out)
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
