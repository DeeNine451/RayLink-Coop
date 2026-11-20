-- Co-op host debug handlers and their single-player fallback.
local debug_fixture = dofile("tests/lua/support/debug_server.lua")
local world, ask, sent = debug_fixture.world, debug_fixture.ask, debug_fixture.sent
local LEVEL_HOST = debug_fixture.LEVEL_HOST

print("== the five handlers and their limits (B.5)")
do
	local H = world()
	local LIMITS = {
		["coop.dbg.view"] = { 30, 10 }, ["coop.dbg.world"] = { 5, 0.5 }, ["coop.dbg.self"] = { 10, 2 },
		["coop.dbg.spawn"] = { 10, 2 }, ["coop.dbg.target"] = { 10, 2 },
	}
	for name, l in pairs(LIMITS) do
		check(type(H.sync_handlers[name]) == "function", name .. " is a handler on the world server")
		local got = H.sync_limits[name]
		check(got ~= nil and got[1] == l[1] and got[2] == l[2], name .. " limit " .. l[1] .. " / " .. l[2])
	end
	local n = 0
	for _ in pairs(H.sync_handlers) do n = n + 1 end
	check(n == 5, "five handlers, no more (they share 256 with the mods)")

	reset_world()
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	debug_fixture.engine(C, {})
	if not C.env.coop_mode then
		debug_fixture.modes.live(load_script(C, "coop_mode"), function(name) return load_script(C, name) end)
	end
	if not C.env.coop_trust then load_script(C, "coop_trust") end
	load_script(C, "coop_npc_players")
	load_script(C, "coop_debug_cmds")
	load_script(C, "coop_debug_server").on_game_start()
	local any = false
	for _ in pairs(C.sync_handlers) do any = true end
	check(not any, "a client registers no handler")
	check(next(C.sync_limits) == nil, "a refused client registration installs no limit")
	local rejected = world({ rejected_handler = "coop.dbg.view" })
	check(rejected.sync_limits["coop.dbg.view"] == nil, "the rate limit follows successful registration only")
end

print("== debug off: only view passes (B.5, the engine gate's twin)")
do
	local H = world({ debug = false })
	local cases = {
		{ "coop.dbg.world", { v = 1, cmd = "time_add", h = 6 } },
		{ "coop.dbg.self", { v = 1, cmd = "money", a = 100 } },
		{ "coop.dbg.spawn", { v = 1, cmd = "spawn_item", sec = "wpn_ak74" } },
		{ "coop.dbg.target", { v = 1, cmd = "kill", t = 700 } },
	}
	for _, c in ipairs(cases) do
		local ok, why = ask(H, c[1], 3, c[2])
		check(ok == false and why == "debug_off", c[1] .. " " .. c[2].cmd .. ": debug_off")
	end
	check(#H.time_jumps == 0 and #H.created == 0 and #H.grants == 0, "nothing changed")
	local ok, r = ask(H, "coop.dbg.view", 3, { v = 1, cmd = "obj_info", t = 700 })
	check(ok == true and type(r) == "table" and r.section ~= nil, "view obj_info passes while off")
end

print("== the order of the checks")
do
	local H = world()
	local ok, why = ask(H, "coop.dbg.world", 3, { cmd = "time_add", h = 6 })
	check(ok == false and why == "old_client", "no v: old_client")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 2, cmd = "time_add", h = 6 })
	check(ok == false and why == "old_client", "v = 2: old_client")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "no_such" })
	check(ok == false and why == "unknown_cmd", "an unknown command")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "money", a = 100 })
	check(ok == false and why == "unknown_cmd", "a self command on the world handler: unknown_cmd")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "lua", code = "x = 1" })
	check(ok == false and why == "unknown_cmd", "lua from a player: unknown_cmd (operator only)")
	ok, why = ask(H, "coop.dbg.self", 5, { v = 1, cmd = "money", a = 100 })
	check(ok == false and why == "no_player", "peer 5 is no player: no_player")
	ok, why = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = "lots" })
	check(ok == false and why == "bad_args", "money a = 'lots': bad_args")
end

print("== items to oneself: the parent is the requester's character (C.2)")
do
	local H = world()
	local ok, r = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == true and type(r) == "table" and type(r.msg) == "string", "peer 3: ok with a message")
	local c = H.created[1]
	check(c and c.sec == "wpn_ak74" and type(c.t) == "table" and c.t[4] == 503, "peer 3: the parent is his proxy 503")
	check(c and c.t[4] ~= 0, "peer 3: never the host's actor")
	check(c and c.t[1].x == 10 and c.t[2] == 7 and c.t[3] == 8, "the stock {pos, lvid, gvid, id} of his character")
	ok = ask(H, "coop.dbg.spawn", 0, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	c = H.created[2]
	check(ok == true and c and c.t[4] == 0, "peer 0 (the host player): his character 0")
	ok = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "medkit", n = 5, at = "inv" })
	check(ok == true and #H.created == 7, "n = 5: five items")
	local says = sent(H, "coop.dbg.say")
	check(#says == 3 and says[1].target == -1, "every spawn is announced to everybody")
	check(says[1] and says[1].t.nick == "p3" and says[1].t.cmd == "spawn_item", "the line names who and what")
	check(H.dbg.said[1] ~= nil, "and goes to the server console")
end

print("== a point by the stock formula, checked by the authority (B.5 step 7)")
do
	local H = world()
	H.verts[77] = vec(40, 0, 0)
	local ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 40.5, y = 0, z = 0, lv = 77 })
	local c = H.created[1]
	check(ok == true and c and c.t[4] == nil and c.t[2] == 77 and c.t[3] == 8, "a good point: on the ground, lv of the client, gvid of the character")
	H.verts[78] = vec(400, 0, 0)
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 400, y = 0, z = 0, lv = 78 })
	check(ok == false and why == "too_far", "390 m from him: too_far")
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 60, y = 0, z = 0, lv = 77 })
	check(ok == false and why == "bad_vertex", "20 m from its vertex: bad_vertex")
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 30, y = 0, z = 0, lv = 99 })
	check(ok == false and why == "bad_vertex", "no such vertex: bad_vertex")
	check(#H.created == 1, "nothing made for the refused points")
	H.life[503] = "wounded"
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == false and why == "not_standing", "a player who is down: not_standing")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = 100 })
	check(ok == true, "money still works for him")
end

print("== world commands run once, on the world server (C.1 A16, K35)")
do
	local H = world()
	local ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "time_add", h = 6 })
	check(ok == true and #H.time_jumps == 1, "time_add: change_game_time once")
	local j = H.time_jumps[1]
	check(j and j[1] == 0 and j[2] == 6 and j[3] == 0, "with (0, 6, 0)")
	check(H.forced == 1, "and the stock forced_weather_change")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "time_to", h = 6 })
	j = H.time_jumps[2]
	check(ok == true and j and j[1] == 0 and j[2] == 20 and j[3] == 0, "time_to 06:00 at 10:00: forward 20 h (coop_time)")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "weather", w = "w_storm1" })
	check(ok == true and H.weathers[1][1] == "w_storm1" and H.weathers[1][2] == true, "weather: level.set_weather(w, true)")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "info", k = "give", i = "test_info" })
	check(ok == true and H.infos.test_info == true, "info give on the world server")
end

print("== personal flags and money (B.9)")
do
	local H = world()
	local ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "god", on = true })
	local s = H.dbg.set and H.dbg.set[1]
	check(ok == true and s and s.peer == 3 and s.t.god == true, "god: coop.debug.set_flags(3, {god = true})")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = 50000 })
	local g = H.grants[1]
	check(ok == true and g and g[1] == 3 and g[2] == 50000, "money: coop.money_grant(3, 50000)")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = -1000 })
	g = H.grants[2]
	check(ok == true and g and g[2] == -100, "money never below 0: -1000 of 100 takes 100")
	ok = ask(H, "coop.dbg.self", 0, { v = 1, cmd = "tp", x = 1, y = 2, z = 3 })
	local t = H.teleports[1]
	check(ok == true and t and t[1] == 0 and t[2].x == 1, "tp: the owner moves (coop_mods_core.teleport), the host player too")
end

print("== targets (C.1 T2, T3, K24)")
do
	local H = world()
	local ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 503 })
	check(ok == false and why == "player_target", "release of a player: player_target")
	ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 0 })
	check(ok == false and why == "player_target", "release of id 0: player_target")
	ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 4321 })
	check(ok == false and why == "bad_target", "no such object: bad_target")
	ok = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 700 })
	check(ok == true and H.objects[700]._killed == true, "kill an NPC of the world server's level")
	ok = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 700 })
	check(ok == true and H.released[1] and H.released[1][1] == 700, "release: alife_release_id")

end

print("== P.player (B.4)")
do
	local H = world()
	local P = H.env.coop_npc_players
	local p = P.player(3)
	check(p and p.peer == 3 and p.nick == "p3" and p.character == 503 and p.level == LEVEL_HOST, "player(3): peer, nick, character, level")
	check(p and p.here == true and p.link == "net" and p.standing == true, "here, net, standing")
	check(p and p.object() == H.objects[503], "object() is his proxy")
	local h = P.player(0)
	check(h and h.character == 0 and h.link == "local" and h.object() == H.env.db.actor, "player(0) on a listen host: the host player")
	check(P.player(5) == nil, "player(5): nobody")
	check(P.player_by_name("@P3") and P.player_by_name("@P3").peer == 3, "by nick, any case")
	check(P.player_by_name("@3") and P.player_by_name("@3").peer == 3, "by number")
	check(P.player_by_name("@#3") and P.player_by_name("@#3").peer == 3, "by #number")
	check(P.player_by_name("@nobody") == nil, "an unknown nick")

end

print("== debug on marks the world as stock does (owner decision 1)")
do
	local H = world({ debug = false })
	H.fire("coop_debug_changed", true, 2)
	check(H.infos.debug_mode_flag_on == true, "debug_mode_flag_on given when debug goes on")
end

print("== a command that ran answers so even when its announcement breaks (2026-11-07 handler error sweep)")
do
	local H, S = world()
	local enc = H.env.coop_main.encode
	H.env.coop_main.encode = function(t)
		if type(t) == "table" and t.text ~= nil then error("encode broke") end
		return enc(t)
	end
	local ok, r = ask(H, "coop.dbg.self", 0, { v = 1, cmd = "god", on = 1 })
	check(ok == true and type(r) == "table" and r.msg == "god on", "the host player's god: ok though the announcement broke", tostring(r))
	check(H.dbg.set and H.dbg.set[1] and H.dbg.set[1].peer == 0 and H.dbg.set[1].t.god == true, "the flag was set for peer 0")
	H.env.coop_main.encode = enc
end

print("== the active host may start debug before its mode layer is installed")
do
	local H = world({ delayed_modes = true })
	local count = 0
	for name in pairs(H.sync_handlers) do
		if H.sync_limits[name] then count = count + 1 end
	end
	check(count == 5, "the native host installs all five handlers and limits during on_game_start")
	debug_fixture.modes.live(H.env.coop_mode, function(name) return load_script(H, name) end)
	H.fire("actor_on_first_update")
	local ok = ask(H, "coop.dbg.spawn", 0, { v = 1, cmd = "spawn_item", sec = "medkit", n = 2, at = "inv" })
	check(ok == true and #H.created == 2, "the co-op host's first update enables local debug spawns")
	check(#sent(H, "coop.dbg.run") == 0, "the co-op host sends no map relay")
	local made
	for _, line in ipairs(H.log) do
		if line:find("spawn_item rid %- for p0 %(peer 0, character 0%): medkit x2 at inv, 2 made by the world server: ids") then
			made = line
		end
	end
	check(made ~= nil, "the co-op spawn log identifies a local run and the object IDs")
	local S = world({ single = true })
	check(S.sync_handlers["coop.dbg.view"] ~= nil, "single player still installs its debug handlers")
end

print("== refused debug requests are counted by coop_trust")
do
	local cases = {
		{ "world", 3, false, "bad_args" },
		{ "world", 3, { v = 1, cmd = "time_add", h = 6 }, "debug_off", false },
		{ "world", 3, { v = 2, cmd = "time_add", h = 6 }, "old_client" },
		{ "world", 3, { v = 1, cmd = "money", a = 100 }, "unknown_cmd" },
		{ "self", 5, { v = 1, cmd = "money", a = 100 }, "no_player" },
		{ "self", "3", { v = 1, cmd = "money", a = 100 }, "no_player" },
		{ "self", 3, { v = 1, cmd = "money", a = "lots" }, "bad_args" },
		{ "target", 3, { v = 1, cmd = "kill", t = 4321 }, "bad_target" },
	}
	for _, c in ipairs(cases) do
		local H = world({ debug = c[5] })
		local ok, why = ask(H, "coop.dbg." .. c[1], c[2], c[3])
		check(ok == false and why == c[4], "keeps the refusal code " .. c[4])
		check(debug_fixture.trust_failures(H) == 1, "counts the refusal " .. c[4])
	end
end

print("== debug announcements use the transport sender and bounded fields")
do
	local H = world()
	local chat = {}
	H.env.coop_core_chat = { system = function(line) chat[#chat + 1] = line end }
	local receive = H.handlers["coop.dbg.say"][1]
	local invalid = {
		{ 3, { nick = "p3", cmd = "money", text = "spoofed", from = 0 } },
		{ 0, { nick = 3, cmd = "money", text = "bad nick" } },
		{ 0, { nick = string.rep("a", 4096), cmd = "money", text = "long nick" } },
		{ 0, { nick = "p3", cmd = "unknown", text = "bad cmd" } },
		{ 0, { nick = "p3", cmd = "money", text = true } },
		{ 0, { nick = "p3", cmd = "money", text = string.rep("a", 4096) } },
	}
	for i, c in ipairs(invalid) do
		receive(H.env.coop_main.encode(c[2]), c[1])
		check(#chat == 0 and debug_fixture.trust_failures(H) == i, "drops and counts invalid announcement " .. i)
	end
	receive(H.env.coop_main.encode({ nick = "p3", cmd = "money", text = "paid 100%" }), 0)
	check(#chat == 1 and chat[1] == "[debug] p3: paid 100%", "displays a valid announcement literally")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
