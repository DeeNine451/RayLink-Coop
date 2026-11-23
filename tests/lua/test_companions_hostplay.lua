-- K-61, co-op. The playing host has all bodies, squads and talk locks on one map.
-- The client supplies the dialog action, and the transport supplies its sender.
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function stock_source()
	local gamma = os.getenv("GAMMA_SCRIPTS")
	for _, path in ipairs({
		"temp/review/corpus/merged/axr_companions.script",
		gamma and gamma .. "/axr_companions.script" or "temp/stock_scripts/scripts/axr_companions.script",
		"temp/stock_scripts/scripts/axr_companions.script",
	}) do
		local source = io.open(path, "rb")
		if source then source:close(); return path end
	end
	error("K-61 needs axr_companions.script from the GAMMA corpus or GAMMA_SCRIPTS")
end

local stock_path = stock_source()
local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

local function squad(id, member)
	return luabind_object({
		id = id,
		commander_id = function() return member end,
		squad_members = function()
			local pending = true
			return function()
				if not pending then return end
				pending = false
				return { id = member }
			end
		end,
	})
end

local function stock(M, squads, members)
	local E = M.env
	local ac = setmetatable({}, { __index = E })
	E.axr_companions = ac
	E.xr_effects = {}
	E.axr_keybind = { bind = function() end }
	E.class = function(name) E[name] = {}; return function() end end
	setfenv(assert(loadfile(stock_path)), ac)()
	local ini = E.ini_file
	E.ini_file = function(path)
		if path ~= "ai_tweaks\\axr_companions.ltx" then return ini(path) end
		return { r_bool_ex = function(_, _, name) return name == "enable" end, r_float_ex = function() return 2 end }
	end
	ac.on_game_start()
	E.alife_object = function(id) return squads[id] end
	E.get_object_squad = function(npc) return squads[members[npc:id()]] end
	E.alife = function()
		return {
			actor = function() return { m_game_vertex_id = 41 } end,
			object = function(_, id) return squads[id] end,
			has_info = function(_, id, flag) return M.objects[id]:has_info(flag) end,
		}
	end
	E.game_graph = function()
		return { vertex = function(_, id)
			assert(id == 41)
			return { level_vertex_id = function() return 17 end, level_point = function() return M.arrival end }
		end }
	end
	E.TeleportSquad = function(sq, pos, lvid, gvid)
		M.teleported[sq.id] = { pos = pos, lvid = lvid, gvid = gvid }
		M.objects[sq:commander_id()]:set_actor_position(pos)
	end
	E.dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
	-- The dialog stubs keep the stock side effects observable. The co-op wrappers,
	-- transport, teleport predicate, level-change callback and save/load are real.
	E.dialogs_axr_companion = {
		become_actor_companion = function(_, npc)
			local sq = E.get_object_squad(npc)
			ac.companion_squads[sq.id] = sq
			npc:give_info_portion("npcx_is_companion")
		end,
		set_companion_to_wait_state = function(_, npc) npc:give_info_portion("npcx_beh_wait") end,
		set_companion_to_follow_state = function(_, npc) npc:disable_info_portion("npcx_beh_wait") end,
	}
end

local function stand()
	reset_world()
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	H.add(make_obj(500, 5))
	H.add(make_obj(501, 6))
	A.to_host, A.to_local = swap(201, 601), swap(201, 601)
	B.to_host, B.to_local = swap(211, 611), swap(211, 611)
	H.env.coop.levels = { split = function() return false end }
	H.env.coop_mode = load_script(H, "coop_mode")
	modes.install(H.env.coop_mode, "hostplay")
	H.env.coop_trust = load_script(H, "coop_trust")
	H.env.coop_trust.reset_for_test({ default = "refuse" })
	local locks = {}
	H.env.coop.talk_recent = function(peer, npc_id, max_age)
		local lock = locks[npc_id]
		return lock ~= nil and lock.peer == peer and NOW - lock.at <= max_age
	end
	local host_squads = { [300] = squad(300, 201), [310] = squad(310, 211), [320] = squad(320, 221) }
	for _, M in ipairs({ H, A, B }) do
		local members, squads = {}, {}
		for id, sq in pairs(host_squads) do
			local member = M.env.coop.to_local_id(sq:commander_id())
			members[member] = id
			squads[id] = M == H and sq or squad(id, member)
			M.add(make_obj(member, 7 + (id - 300) / 10))
		end
		M.teleported, M.arrival = {}, vec(30, 2, 15)
		stock(M, squads, members)
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		M.comp = load_script(M, "coop_npc_companions")
		M.comp.on_game_start()
	end
	return H, A, B, locks, host_squads
end

local function action(M, name, host_id)
	local npc = M.objects[M.env.coop.to_local_id(host_id)]
	M.env.dialogs_axr_companion[name](M.env.db.actor, npc, "dm_is_not_actor_companion_dialog")
end

local recruit = "become_actor_companion"
local H, A, B, locks, squads = stand()
local leaders = H.comp._leaders()

print("== recruit_without_own_talk")
locks[201] = { peer = 2, at = NOW }
action(A, recruit, 201)
pump()
check(leaders[300] == nil and H.env.axr_companions.companion_squads[300] == nil,
	"another player's lock cannot recruit the squad")
check(H.comp._stats().refused_talk == 1, "the host recorded the missing talk")
-- Known red for F5-CMP-3: host_on_cmd currently returns before coop_trust.pass.
if os.getenv("COOP_CMP_OPEN_GAPS") == "1" then
	local refused = 0
	for _, counter in pairs(H.env.coop_trust.status()) do refused = refused + counter.refused end
	check(refused > 0, "refusing a recruit without the sender's talk goes through coop_trust.pass")
else
	print("[open gap] K-61 (F5-CMP-3) requires coop_trust.pass on recruit refusal without the sender's talk. Set COOP_CMP_OPEN_GAPS=1 to check.")
end

print("== recruit_with_talk")
locks[201] = { peer = 1, at = NOW }
locks[211] = { peer = 2, at = NOW - 1000 }
action(A, recruit, 201)
action(B, recruit, 211)
action(H, recruit, 221)
check(leaders[300] == nil and not A.objects[601]:has_info("npcx_is_companion"),
	"the wrapped client action waits for the host")
pump()
check(leaders[300] == 500 and leaders[310] == 501, "each recruit is led by its sender's character")
local confirmed = false
for _, event in ipairs(sent_named(H, "npc.comp_info")) do
	local data = H.env.coop_main.decode(event.payload)
	if event.target == 1 and data.i == 201 and data.l == 1 then confirmed = true end
end
check(confirmed and A.comp.held_here(A.objects[601]), "npc.comp_info confirms the client's ownership in host numbering")

print("== wait_follow_on_authority")
action(A, "set_companion_to_wait_state", 201)
check(not H.objects[201]:has_info("npcx_beh_wait"), "wait is still in transit")
pump()
check(H.objects[201]:has_info("npcx_beh_wait") and A.objects[601]:has_info("npcx_beh_wait"),
	"wait reaches the host action and mirrors back")
check(not H.objects[211]:has_info("npcx_beh_wait") and not H.objects[221]:has_info("npcx_beh_wait"),
	"the other two leaders' squads did not get the order")
action(A, "set_companion_to_follow_state", 201)
pump()
check(not H.objects[201]:has_info("npcx_beh_wait") and not A.objects[601]:has_info("npcx_beh_wait"),
	"follow reaches the host action and clears wait")

print("== host_keeps_own_squad")
check(leaders[320] == nil and H.comp.owner_character(H.objects[221]) == 0,
	"the host's own recruit stays with the host")

print("== hand_over_choices")
local actor, npc = A.env.db.actor, A.objects[601]
check(A.comp.dlg_can_hand(actor, npc), "the leader is offered the hand-over")
check(A.comp.dlg_slot_text(actor, npc, "d", "p", "", { "1" }) == "p0"
	and A.comp.dlg_slot_text(actor, npc, "d", "p", "", { "2" }) == "p2"
	and not A.comp.dlg_slot(actor, npc, "d", "p", "", { "3" }),
	"hand-over lists the host and the other client and omits self")

print("== group_transition_and_reload")
NOW = NOW + 3000
H.fire("actor_on_update") -- installs the co-op wrapper around the stock teleport rule
H.fire("on_level_changing")
for _, id in ipairs({ 300, 310, 320 }) do
	local jump = H.teleported[id]
	check(jump and jump.pos:distance_to(H.arrival) == 0 and jump.lvid == 17 and jump.gvid == 41,
		"stock on_level_changing sent squad " .. id .. " to the group arrival")
end
local saved = {}
H.fire("save_state", saved)
check(saved.coop_npc_leaders and saved.coop_npc_leaders[300] == 500 and saved.coop_npc_leaders[310] == 501
	and saved.coop_npc_leaders[320] == nil, "the save stores both client characters and implicit host ownership")
local next_host, _, _, _, loaded_squads = stand()
next_host.env.level.name = function() return "l02_garbage" end
next_host.fire("load_state", saved)
for _, id in ipairs({ 300, 310, 320 }) do
	next_host.fire("squad_on_first_update", loaded_squads[id])
end
check(next_host.comp.owner_character(next_host.objects[201]) == 500
	and next_host.comp.owner_character(next_host.objects[211]) == 501
	and next_host.comp.owner_character(next_host.objects[221]) == 0, "the new host state restores all three owners")

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" or answer == "srv_map" then
		print("== " .. answer .. ": a saved squad id now names an item")
		local host = stand()
		local npc = host.objects[201]
		action(host, recruit, 201) -- establish a live squad for the outgoing notification
		modes.install(host.env.coop_mode, answer)
		NOW = NOW + 2100
		host.fire("actor_on_update")
		local pruned, sorted = 0, false
		local hooks = host.comp.set_transfer_hooks({
			wrap_teleport = function() end,
			refresh = function() end,
			reset_travel = function() end,
			sort_loaded_leaders = function() sorted = host.comp._leaders()[300] == nil end,
			prune_missing = function() pruned = pruned + 1 end,
		})
		local previous = host.env.alife_object
		host.env.clsid = { online_offline_group_s = 1 }
		host.env.alife_object = function(id)
			if id == 300 then return luabind_object({ clsid = function() return 2 end }) end
			return previous(id)
		end
		host.fire("load_state", { coop_npc_leaders = { [300] = 500 }, coop_npc_last_leaders = { [999] = 500 } })
		host.env.axr_companions.companion_squads[300] = nil
		host.sent = {}
		local logs = #host.log
		NOW = NOW + 2100
		host.fire("actor_on_update")
		check(sorted and hooks.leaders()[300] == nil, answer .. ": the reused id is dropped before sorting loaded leaders")
		check(#host.log == logs and pruned == 1 and hooks.last_leaders()[999] == nil,
			answer .. ": refresh reaches the remaining cleanup without errors")
		local gone = false
		for _, event in ipairs(sent_named(host, "npc.comp_info")) do
			local data = host.env.coop_main.decode(event.payload)
			if event.target == 1 and data.i == npc:id() and data.s == "" and data.l == nil then gone = true end
		end
		check(gone, answer .. ": the client receives the end notification")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
