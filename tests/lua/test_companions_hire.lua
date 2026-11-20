-- G12-1 (Dev 57, phase 4, TZ R19; review F4 group G12): companion hire for every player, decided where the companions are.
--   m13:3 / s35:2  a player's companion count is his own and comes from the authority of his map (npc.comp_count); that
--                  authority re-checks the room rule for the stock and G_FLAT hire dialogs (coop_trust comp_hire_room); in the
--                  Server his ordinary companions on the other maps count too (share comp_hired: map servers up, world down)
--   m31:1          G_FLAT's individual recruit from a player's machine is ONE request (npc.comp); the authority checks it as a
--                  recruit, clones and releases, the clone joins that player when it is online, his machine opens the talk
--                  with it (npc.comp_one)
--   m21:6          Fair Fast Travel's companion key (on_key_release -> bring_companions_to_actor(true)) on a player's machine
--                  asks the authority of his map (npc.comp_bring f = true), which brings his squads at once, past FFT's switch,
--                  with the stock's limits (a squad told to wait, one that may not teleport)
-- The mods' functions are the real ones (GAMMA_DIR of tests\lua\support\mod_source.lua: the stand's scripts, else the review
-- corpus): individually_recruitable_companions (become_*_individually, is_room_for_one_in_actor_squad),
-- custom_companion_squad_size (its dialogs_axr_companion.is_room_in_actor_squad), game_fast_travel (companions_travel_with_actor,
-- bring_companions_to_actor, on_key_release). Stock axr_companions / dialogs_axr_companion / txr_paid_companions: stubs with the
-- stock's bodies (axr_companions.script:310 get_companion_count, :393 add_to_actor_squad; dialogs_axr_companion.script:311;
-- txr_paid_companions.script:155). stalker_cloning_utility.clone_stalker: a new squad of one where the NPC stands; on a player's
-- machine it raises, as the mod's create_one_npc does there (no object for the new member, coop_requests.cpp leased ids).
-- Co-op: the host (peer 0) and clients A (1, proxy 500) and B (2, proxy 501). Server: the world server (peer 0, -coop_dedicated),
-- map servers of l01_escape (bridge 0x102) and l02_garbage (0x101); A on l01, B on l02. Single player: one machine, no session.
-- Run: tools\test_lua.cmd companions_hire
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BS = string.char(92)
local LIMIT = 2 -- axr_companions.max_actor_squad_size (ai_tweaks\axr_companions.ltx), no patriarch
local NAMES = { [1] = "l01_escape", [2] = "l02_garbage" }
local LEVEL_OF_VERTEX = { [10] = 1, [20] = 2 }
local ESCAPE, GARBAGE = 0x102, 0x101
local KEY = 77 -- FFT's squad_tp_bind
local IRC = "individually_recruitable_companions"
local ONE = IRC .. ".become_actor_companion_individually"
local ONE_PAID = IRC .. ".become_paid_actor_companion_individually_and_register"

-------------------------------------------------------------------------------
-- The mods' real functions
-------------------------------------------------------------------------------
local function read_lines(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local lines = {}
	for line in fh:read("*a"):gmatch("([^\n]*)\n?") do lines[#lines + 1] = (line:gsub("\r$", "")) end
	fh:close()
	return lines
end

local REAL = {}
local function function_text(script, header)
	REAL[script] = REAL[script] or read_lines(GAMMA_DIR .. BS .. script .. ".script")
		or error("real GAMMA script required: " .. script .. ".script (GAMMA_SCRIPTS or temp\\review\\corpus\\merged)")
	local lines = REAL[script]
	for i, line in ipairs(lines) do
		if line:sub(1, #header) == header then
			local out = {}
			for j = i, #lines do
				out[#out + 1] = lines[j]
				if j > i and lines[j]:match("^end%s*$") then return table.concat(out, "\n") end
			end
		end
	end
	error("not in the real " .. script .. ": " .. header)
end

-- Functions of a mod's script on machine M, compiled in its module table there (CScriptStorage: __index = that machine's _G).
local function real(M, script, headers, pre)
	local parts = { pre or "" }
	for _, h in ipairs(headers) do parts[#parts + 1] = function_text(script, h) end
	local f = assert(loadstring(table.concat(parts, "\n"), "@" .. script .. ".script"))
	local m = rawget(M.env, script)
	if type(m) ~= "table" then
		m = setmetatable({}, { __index = M.env })
		M.env[script] = m
	end
	setfenv(f, m)
	f()
	return m
end

-------------------------------------------------------------------------------
-- A world
-------------------------------------------------------------------------------
local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

local W -- the current stand

local function se_obj(id) return { id = id, name = function() return "m" .. id end } end

-- an NPC online on machine M at x (set_npc_position moves the NPC itself, as the engine's game_object does)
local function npc(M, id, x)
	local o = M.add(make_obj(id, x, 0, 0, { _name = "m" .. id }))
	o.set_npc_position = function(self, p) self._pos = vec(p.x, p.y, p.z); self.placed = (self.placed or 0) + 1 end
	o.dont_has_info = function(self, i) return not self:has_info(i) end
	o.level_vertex_id = function() return 7 end
	M.env.db.storage[id] = { object = o }
	return o
end

local function new_squad(id, vertex, ...)
	local t = { id = id, members = { ... }, m_game_vertex_id = vertex }
	function t.squad_members(self)
		local i = 0
		return function() i = i + 1; local m = t.members[i]; if m then return { id = m } end end
	end
	function t.commander_id() return t.members[1] end
	function t.force_change_position(self, p) t.forced = vec(p.x, p.y, p.z) end
	W.squads[id], W.raw[id] = luabind_object(t), t
	for _, m in ipairs({ ... }) do W.se[m] = W.se[m] or se_obj(m) end
	return W.squads[id]
end

local function stock(M)
	local E = M.env
	E.actor_menu = { set_msg = function() end }
	E.axr_task_manager = { hostages_by_id = {} }
	E.EDDListType = { iActorBag = 1, iDeadBodyBag = 2 }
	E.dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
	E.CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
	E.alife_object = function(id) return W.squads[id] or W.se[id] end
	E.get_object_squad = function(o)
		local id = type(o) == "number" and o or o:id()
		for _, sq in pairs(W.squads) do
			for k in sq:squad_members() do if k.id == id then return sq end end
		end
	end
	E.alife = function()
		return { level_name = function(_, id) return NAMES[id] end, level_id = function() return M.level_id or 1 end }
	end
	E.game_graph = function()
		return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF_VERTEX[gv] end } end }
	end
	M.marks = {}
	E.se_save_var = function(id, name, var, value) M.marks[id] = M.marks[id] or {}; M.marks[id][var] = value end
	E.se_load_var = function(id, name, var) return M.marks[id] and M.marks[id][var] end
	E.db.offline_objects = {}
	E.game_achievements = { has_achievement = function() return false end }
	E.utils_obj = { get_squad_count = function(o)
		local sq, n = E.get_object_squad(o), 0
		if sq then for _ in sq:squad_members() do n = n + 1 end end
		return n
	end }
	E.ui_mcm = { get_mod_key = function() return true end, get = function() return nil end }
	E.sim_squad_scripted = { sim_squad_scripted = { get_current_task = function() return "stock task" end },
		reset_animation = function() end }
	E.axr_beh = { action_beh = { execute = function() end } }
	E.TeleportSquad = function() M.teleported = true end
	E.level.vertex_id = function(p) W.lvn = W.lvn + 1; W.lv[W.lvn] = vec(p.x, p.y, p.z); return W.lvn end
	E.level.vertex_position = function(lv) local p = W.lv[lv]; return p and vec(p.x, p.y, p.z) end
	E.coop.talk_recent = function(peer, id)
		local t = W.talk[peer]
		return t == id or (type(t) == "table" and t[id] == true)
	end
	E.db.actor.run_talk_dialog = function(self, o) M.talks = M.talks or {}; M.talks[#M.talks + 1] = o:id() end
	-- axr_companions (stock bodies: get_companion_count :310, add_to_actor_squad :393, companion_squad_can_teleport :293)
	local ac = { companion_squads = {}, non_task_companions = {}, max_actor_squad_size = LIMIT }
	E.axr_companions = ac
	function ac.get_companion_count()
		local n = 0
		for _ in pairs(ac.non_task_companions) do n = n + 1 end
		return n
	end
	function ac.add_to_actor_squad(o)
		ac.non_task_companions[o:id()] = true
		E.se_save_var(o:id(), o:name(), "companion", true)
		o:give_info_portion("npcx_is_companion")
	end
	function ac.setup_companion_logic(o) o:give_info_portion("npcx_is_companion") end
	function ac.companion_squad_can_teleport(squad)
		local id = squad:commander_id()
		if E.se_load_var(id, nil, "companion_cannot_teleport") then return false end
		local o = M.objects[id]
		return not (o and (o:has_info("npcx_beh_patrol_mode") or o:has_info("npcx_beh_wait")))
	end
	function ac.get_inventory_table() return {} end
	-- dialogs_axr_companion (stock :311 become_actor_companion, :384 is_not_actor_companion)
	E.dialogs_axr_companion = {
		is_not_actor_companion = function(a, o) return o:has_info("npcx_is_companion") ~= true end,
		become_actor_companion = function(a, o)
			local sq = E.get_object_squad(E.dialogs.who_is_npc(a, o))
			if not sq then return end
			ac.companion_squads[sq.id] = sq
			for k in sq:squad_members() do
				local m = M.objects[k.id]
				if m and m:alive() then ac.add_to_actor_squad(m) end
			end
			M.recruits = (M.recruits or 0) + 1
		end,
	}
	-- txr_paid_companions (stock :127-174: the contract of the squad with this machine's guard_period)
	E.txr_paid_companions = { paid_companions = {} }
	function E.txr_paid_companions.take_guard_money_1() M.guard_local = 86400 end
	function E.txr_paid_companions.take_guard_money_2() M.guard_local = 172800 end
	function E.txr_paid_companions.register_paid_companion(a, o)
		local sq = E.get_object_squad(E.dialogs.who_is_npc(a, o))
		if sq then E.txr_paid_companions.paid_companions[sq.id] = { guard_period = M.guard_local } end
	end
	-- G_FLAT's clone (stalker_cloning_utility.clone_stalker): a squad of one where the NPC stands, online at the next update
	E.stalker_cloning_utility = { clone_stalker = function(o)
		M.clones = (M.clones or 0) + 1
		if M.mirror then error("create_one_npc: add_squad_member gave no object on a player's machine", 0) end
		W.next_id = W.next_id + 1
		local id = W.next_id
		new_squad(id + 1000, M.vertex or 10, id)
		W.born[id] = o:position().x
		return id
	end }
	E.alife_release = function(o)
		M.released = M.released or {}
		M.released[#M.released + 1] = o:id()
		for _, each in pairs(MACHINES) do each.objects[o:id()] = nil end
		local sq = E.get_object_squad(o)
		if sq then
			local list = W.raw[sq.id].members
			for i = #list, 1, -1 do if list[i] == o:id() then table.remove(list, i) end end
		end
	end
	-- the share of the server (coop_srv_levels_share carries what the Core registered)
	M.share = { up = {}, down = {} }
	local function up(name, get, set) M.share.up[name] = { get = get, set = set } end
	local function down(name, get, set) M.share.down[name] = { get = get, set = set } end
	E.coop_quests_core = {
		share_up = up,
		share_down = down,
		share = function() return { up = up, down = down } end,
	}
end

-- the real mods' functions of this machine
local function mods(M)
	real(M, "custom_companion_squad_size", { "function dialogs_axr_companion.is_room_in_actor_squad(actor, npc)" })
	real(M, IRC, { "function become_actor_companion_individually(actor, npc)",
		"function become_paid_actor_companion_individually_and_register(actor, npc)",
		"function is_room_for_one_in_actor_squad(actor, npc)" },
		"local custom_actor_squadsize, custom_actor_squadsize_folkhero, hascustomsquadsize = 2, 4, false")
	local fft = real(M, "game_fast_travel", { "function companions_travel_with_actor()", "function bring_companions_to_actor(forced)",
		"function on_key_release(key)" })
	fft.reset_trip_data = function() return {} end
	fft.vl = function() end
	fft.strbool = function(s) return s == "true" end
	fft.squad_local_travel = true
	fft.tp_ignores_hostages, fft.tp_respects_waitfollow = true, true
	fft.squad_tp_bind, fft.squad_tp_mod = KEY, 0
end

local function start(M)
	M.env.coop_npc_players = load_script(M, "coop_npc_players")
	load_script(M, "coop_trust").reset_for_test({ default = W.trust or "refuse" })
	load_script(M, "coop_mods_core")
	local mode = load_script(M, "coop_mode")
	mode.on_game_start()
	modes.live(mode, function(name) return load_script(M, name) end)
	load_script(M, "coop_npc_companions").on_game_start()
	load_script(M, "coop_npc_companions_hire").on_game_start()
end

local function tick(ms)
	NOW = NOW + (ms or 1000)
	for _, M in ipairs(W.machines) do
		M.env.coop_npc_players.invalidate()
		M.fire("actor_on_update")
	end
	pump()
end

local function run_timers(M)
	local left = {}
	for _, t in ipairs(M.timers or {}) do
		if not t.f(unpack(t.p)) then left[#left + 1] = t end
	end
	M.timers = left
end

-- the clone comes online on every machine of the stand
local function online(id)
	for _, M in ipairs(W.machines) do
		if M ~= W.world then npc(M, id, W.born[id]) end
	end
end

local function count(M) return M.env.axr_companions.get_companion_count() end
local function room_refused(M) return (M.env.coop_trust.status().comp_hire_room or {}).refused end
local function cs(M, id) return M.env.axr_companions.companion_squads[id] end
local function sent_f(M, f)
	local n = 0
	for _, s in ipairs(sent_named(M, "npc.comp")) do
		if s.payload:find(f, 1, true) then n = n + 1 end
	end
	return n
end
local function has_line(M, text)
	for _, l in ipairs(M.log) do if l:find(text, 1, true) then return true end end
	return false
end
local function errors(M)
	local n = 0
	for _, l in ipairs(M.log) do if l:find("[coop-npc:companions] !", 1, true) then n = n + 1 end end
	return n
end

-- an ordinary companion squad of one (a dialog's recruit) on authority M, led by character `lead` (nil: its own player's)
local function ordinary(M, sid, mid, x, lead, vertex)
	local sq = new_squad(sid, vertex or 10, mid)
	local o = npc(M, mid, x)
	o:give_info_portion("npcx_is_companion")
	M.env.axr_companions.companion_squads[sid] = sq
	M.env.axr_companions.non_task_companions[mid] = true
	M.marks[mid] = { companion = true }
	M.env.coop_npc_companions._leaders()[sid] = lead
	return o
end

-------------------------------------------------------------------------------
-- Co-op: the host plays; A and B are his clients on his map
-------------------------------------------------------------------------------
-- Host's table: A (500) leads 300 (201) and 310 (211), ordinary, and 340 (241), a task's (cannot_dismiss, may not teleport);
-- B (501) leads 320 (221); the host his own 330 (231). Free NPCs next to everybody: 350 (251, 252), 360 (261), 370 (271, 272),
-- 380 (281), 390 (291, 292).
local function coop_stand(opts)
	opts = opts or {}
	reset_world()
	W = { squads = {}, raw = {}, se = {}, born = {}, talk = {}, lv = {}, lvn = 0, next_id = 900, trust = opts.trust }
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	A.mirror, B.mirror = true, true
	W.H, W.A, W.B, W.machines = H, A, B, { H, A, B }
	for _, M in ipairs(W.machines) do
		stock(M)
		mods(M)
		M.env.coop.levels = { split = function() return false end }
	end
	W.proxy_a = H.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = H.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	for _, p in ipairs({ W.proxy_a, W.proxy_b }) do p.level_vertex_id = function() return H.env.level.vertex_id(p._pos) end end
	for _, M in ipairs(W.machines) do start(M) end
	W.CH = H.env.coop_npc_companions
	ordinary(H, 300, 201, 50, 500)
	ordinary(H, 310, 211, 52, 500)
	ordinary(H, 320, 221, 56, 501)
	ordinary(H, 330, 231, 58, nil)
	local task = ordinary(H, 340, 241, 54, 500)
	H.env.axr_companions.non_task_companions[241] = nil
	H.marks[241] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = true }
	task:give_info_portion("npcx_beh_cannot_dismiss")
	for _, id in ipairs({ 201, 211, 221, 231, 241 }) do -- the clients' copies
		npc(A, id, H.objects[id]._pos.x)
		npc(B, id, H.objects[id]._pos.x)
	end
	for _, r in ipairs({ { 350, 251, 252 }, { 360, 261 }, { 370, 271, 272 }, { 380, 281 }, { 390, 291, 292 } }) do
		new_squad(r[1], 10, r[2], r[3])
		for i = 2, #r do
			for _, M in ipairs(W.machines) do npc(M, r[i], 7 + (r[i] % 10)) end
		end
	end
	tick(3000)
	return W
end

print("== co-op: a client's count of companions is his own, the host's word (m13:3, s35:2)")
do
	coop_stand()
	local H, A, B = W.H, W.A, W.B
	check(count(A) == 2, "A: his two ordinary companions, not the task's, not B's, not the host's (stock: his empty table, 0)")
	check(count(B) == 1, "B: his one")
	check(count(H) == 1, "the host's own dialog: his one (stock: the four of the group)")
	local d = A.env.dialogs_axr_companion
	check(d.is_room_in_actor_squad(A.env.db.actor, A.objects[261]) == false, "A at the limit: the stock dialog (Custom Companion Squad Size) offers no recruit")
	check(B.env.dialogs_axr_companion.is_room_in_actor_squad(B.env.db.actor, B.objects[261]) == true, "B: room for one more")
	check(B.env.dialogs_axr_companion.is_room_in_actor_squad(B.env.db.actor, B.objects[251]) == false, "B: no room for a squad of two")
	check(A.env[IRC].is_room_for_one_in_actor_squad(A.env.db.actor, A.objects[271]) == false
		and B.env[IRC].is_room_for_one_in_actor_squad(B.env.db.actor, B.objects[271]) == true, "G_FLAT's room rule reads the same count")
	-- a dismissal by the host (stock remove_from_actor_squad: the table, the marks): A's count follows within a second
	H.env.axr_companions.companion_squads[310] = nil
	H.env.axr_companions.non_task_companions[211] = nil
	H.marks[211] = nil
	tick(1000)
	check(count(A) == 1, "a dismissal: A's count follows")
	local before = #sent_named(H, "npc.comp_count")
	tick(1000)
	check(#sent_named(H, "npc.comp_count") == before, "an unchanged count is not sent again")
	-- control handed over: the counts move with it
	W.CH._leaders()[300] = 501
	tick(1000)
	check(count(A) == 0 and count(B) == 2, "control of 300 passed to B: A 0, B 2")
	check(errors(H) == 0 and errors(A) == 0, "no error on the host or the client")
end

print("== co-op: the host checks the room again before a recruit; a second hire over the limit is refused")
do
	coop_stand()
	local H, A = W.H, W.A
	W.talk[1] = 261
	-- a modified client at the limit: the dialog would not offer it, the request comes anyway
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], "friendly_companion_dialog")
	pump()
	check(cs(H, 360) == nil, "refused: A has two, a third is over the limit")
	local st = H.env.coop_trust.status().comp_hire_room
	check(st ~= nil and st.failed == 1 and st.refused == 1, "counted by coop_trust comp_hire_room")
	-- one of his goes: room for exactly one; two requests in a row, before his count could change on his machine
	H.env.axr_companions.companion_squads[310] = nil
	H.env.axr_companions.non_task_companions[211] = nil
	H.marks[211] = nil
	W.talk[1] = { [261] = true, [281] = true }
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], "friendly_companion_dialog")
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[281], "friendly_companion_dialog_hostage_version")
	check(sent_f(A, "become_actor_companion") == 3, "the client sent both")
	pump()
	check(cs(H, 360) ~= nil and W.CH._leaders()[360] == 500, "the first one: his")
	check(cs(H, 380) == nil, "the hostage hire: refused, the host counts what he has now")
	check(room_refused(H) == 2, "refused by the room check, not by the talk")
	tick(1000)
	check(count(A) == 2, "A is told 2")
	-- The Fanatic setter is a different action from the training dialog's become_actor_companion.
	local hire = H.env.coop_npc_companions_hire
	check(hire ~= nil and hire.room_on_decider("dialogs_escape.set_esc_2_12_stalker_fanat_as_companion", 1, H.objects[291]) == true,
		"the Fanatic setter has no room rule")
end

print("== co-op: the guide and Fanatic's training use the squad recruit action at the limit")
for _, dialog in ipairs({ "dm_guide_job", "fanat_training_start" }) do
	coop_stand({ trust = "refuse" })
	local H, A = W.H, W.A
	check(count(A) == LIMIT, dialog .. ": A is at the limit")
	W.talk[1] = 261
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], dialog)
	pump()
	check(cs(H, 360) ~= nil and W.CH._leaders()[360] == 500, dialog .. ": recruited for A")
	check(H.env.coop_trust.status().comp_hire_room == nil, dialog .. ": no room check")
end

print("== co-op: the room check ships in coop_trust's log mode: it says it would refuse and lets the recruit through")
do
	coop_stand({ trust = "log" })
	local H, A = W.H, W.A
	W.talk[1] = 261
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], "friendly_companion_dialog")
	pump()
	check(cs(H, 360) ~= nil and W.CH._leaders()[360] == 500, "let through")
	check(has_line(H, "comp_hire_room") and has_line(H, "would be refused"), "logged as would be refused")
	W.talk[1] = 281
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[281], "dm_guide_job")
	pump()
	check(cs(H, 380) ~= nil and W.CH._leaders()[380] == 500, "guide recruited for A")
	local st = H.env.coop_trust.status().comp_hire_room
	check(st and st.failed == 1, "only the ordinary hire would be refused")
end

print("== co-op: G_FLAT's individual recruit from a client is one request; the host clones, the clone joins him (m31:1)")
do
	coop_stand()
	local H, A, B = W.H, W.A, W.B
	W.talk[2] = 271
	local ok = pcall(B.env[IRC].become_actor_companion_individually, B.env.db.actor, B.objects[271])
	check(ok, "the dialog's action does not break on the client")
	check(B.clones == nil and B.released == nil, "the client clones nothing and releases nothing")
	check(sent_f(B, ONE) == 1 and #sent_named(B, "npc.comp") == 1, "one request (npc.comp) with the mod's action")
	pump()
	check(H.clones == 1 and H.released and H.released[1] == 271, "the host clones the NPC and releases it, once")
	local clone = W.next_id
	run_timers(H)
	check(cs(H, clone + 1000) == nil, "not before the clone is online")
	online(clone)
	run_timers(H)
	check(cs(H, clone + 1000) ~= nil and W.CH._leaders()[clone + 1000] == 501, "online: it joins B (his character leads it)")
	check(H.env.axr_companions.non_task_companions[clone] == true, "an ordinary companion (the stock's add_to_actor_squad)")
	check(H.talks == nil, "the host's actor opens no talk")
	pump()
	check(B.talks and B.talks[1] == clone, "B's machine opens the talk with it, as the mod does")
	tick(1000)
	check(count(B) == 2, "B's count: 2")
	check(#(H.timers or {}) == 0, "the host's wait is over")
	-- refusals: no talk, a companion of the group, over the limit, a second while one is under way
	W.talk[2] = nil
	B.env[IRC].become_actor_companion_individually(B.env.db.actor, B.objects[291])
	pump()
	check(H.clones == 1, "no talk with it: nothing cloned")
	W.talk[1] = 201
	A.env[IRC].become_actor_companion_individually(A.env.db.actor, A.objects[201] or npc(A, 201, 50))
	W.talk[1] = 291
	A.env[IRC].become_actor_companion_individually(A.env.db.actor, A.objects[291])
	pump()
	check(H.clones == 1, "a companion of the group, and A at the limit: nothing cloned")
	check(room_refused(H) == 1, "the limit counted by coop_trust")
	W.CH.print_status()
	check(has_line(H, "hire: counts sent") and has_line(H, "individual recruits 1, done 1"), "coop_status: the hire line")
	check(errors(H) == 0 and errors(B) == 0, "no error")
end

print("== co-op: one individual recruit at a time per player; the paid one keeps the days he paid for")
do
	coop_stand()
	local H, B = W.H, W.B
	H.env.axr_companions.companion_squads[320] = nil -- B has none: room for two
	H.env.axr_companions.non_task_companions[221] = nil
	H.marks[221] = nil
	W.talk[2] = 271
	B.env.txr_paid_companions.take_guard_money_2(B.env.db.actor, B.objects[271])
	B.env[IRC].become_paid_actor_companion_individually_and_register(B.env.db.actor, B.objects[271])
	check(sent_f(B, ONE_PAID) == 1, "the paid one: one request")
	pump()
	W.talk[2] = 291
	B.env[IRC].become_actor_companion_individually(B.env.db.actor, B.objects[291])
	pump()
	check(H.clones == 1, "a second before the first is done: refused")
	local clone = W.next_id
	online(clone)
	run_timers(H)
	local contract = H.env.txr_paid_companions.paid_companions[clone + 1000]
	check(contract ~= nil and contract.guard_period == 172800, "the contract: two days, as B paid (take_guard_money_2)")
	check(W.CH._leaders()[clone + 1000] == 501, "the paid clone is B's")
	W.talk[2] = 291
	B.env[IRC].become_actor_companion_individually(B.env.db.actor, B.objects[291])
	pump()
	check(H.clones == 2, "after it: the next one is served")
end

print("== co-op: the host's own individual recruit runs the mod's own code, as before")
do
	coop_stand()
	local H = W.H
	H.env.axr_companions.companion_squads[330] = nil -- the host has room
	H.env.axr_companions.non_task_companions[231] = nil
	H.marks[231] = nil
	H.env[IRC].become_actor_companion_individually(H.env.db.actor, H.objects[271])
	check(#sent_named(H, "npc.comp") == 0 and H.clones == 1, "cloned here, nothing sent")
	local clone = W.next_id
	online(clone)
	run_timers(H)
	check(cs(H, clone + 1000) ~= nil and W.CH._leaders()[clone + 1000] == nil, "the host's own companion")
	check(H.talks and H.talks[1] == clone, "the host's talk with it opens (the mod's run_talk_dialog)")
end

print("== co-op: Fair Fast Travel's companion key on a client: the host brings his squads at once (m21:6)")
do
	coop_stand()
	local H, A = W.H, W.A
	W.CH._leaders()[310] = 500
	H.objects[211]:give_info_portion("npcx_beh_wait")
	A.env.game_fast_travel.squad_local_travel = false -- FFT's switch off: the key is "forced"
	A.env.game_fast_travel.on_key_release(KEY)
	local sent = sent_named(A, "npc.comp_bring")
	check(#sent == 1 and sent[1].target == 0, "the key asks the authority of his map")
	check(A.objects[201]._pos.x == 50, "his machine moves nothing itself")
	pump()
	check(math.abs(H.objects[201]._pos.x - 5) < 0.01, "his following companion comes to him at once, past FFT's switch")
	check(H.objects[211]._pos.x == 52, "one told to wait stays")
	check(H.objects[241]._pos.x == 54, "one that may not teleport (the task's) stays")
	check(H.objects[221]._pos.x == 56 and H.objects[231]._pos.x == 58, "B's and the host's stay")
	A.env.game_fast_travel.bring_companions_to_actor()
	check(#sent_named(A, "npc.comp_bring") == 1, "FFT's time event after a trip (not forced) sends nothing: bring_mine does that")
	A.env.game_fast_travel.on_key_release(KEY + 1)
	check(#sent_named(A, "npc.comp_bring") == 1, "another key: nothing")
	A.env.game_fast_travel.on_key_release(KEY)
	pump()
	check(W.CH._stats().refused >= 1, "a second press within 3 s: refused")
end

-------------------------------------------------------------------------------
-- Server: the world server (no map), map servers of l01_escape and l02_garbage; A on l01, B on l02
-------------------------------------------------------------------------------
-- Escape: A leads 300 (201). Garbage: A leads 400 (301), left behind told to wait (a squad that came from another map: the stock's
-- marks, not its table), B leads 410 (311). Free: 360 (261) on Escape, 460 (461) and 470 (471, 472) on Garbage.
local function server_stand(opts)
	opts = opts or {}
	reset_world()
	W = { squads = {}, raw = {}, se = {}, born = {}, talk = {}, lv = {}, lvn = 0, next_id = 900, trust = opts.trust }
	local level_of = { [1] = 1, [2] = 2 }
	local S = machine("host", 0, { [1] = 500, [2] = 501 })
	W.k_avatars = { [1] = 500 }
	local K = machine("client", ESCAPE, W.k_avatars)
	local G = machine("client", GARBAGE, { [2] = 501 })
	local A = machine("client", 1, { [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	A.mirror, B.mirror = true, true
	S.env.coop.is_dedicated = function() return true end
	S.env.level.name = function() return "fake_start" end
	W.S, W.K, W.G, W.A, W.B, W.world, W.machines = S, K, G, A, B, S, { S, K, G, A, B }
	for _, M in ipairs({ K, G }) do
		local lid = M == K and 1 or 2
		M.env.coop.is_map_server = function() return true end
		M.env.coop.is_mirror = function() return false end
		M.env.level.name = function() return NAMES[lid] end
		M.level_id, M.vertex = lid, lid == 1 and 10 or 20
		-- to a player through the world server's tunnel: he sees the world server as the sender
		local send = M.env.coop.send_event
		M.env.coop.send_event = function(name, payload, target)
			if type(target) == "number" and target > 0 and target < 0x100 then
				M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
				QUEUE[#QUEUE + 1] = { from = 0, name = name, payload = payload, target = target }
				return true
			end
			return send(name, payload, target)
		end
	end
	for _, M in ipairs(W.machines) do
		stock(M)
		mods(M)
		M.env.coop.levels = {
			split = function() return true end,
			level_of_player = function(p) return level_of[p] end,
			level_name = function(id) return NAMES[id] end,
			bridge_of_player = function(p)
				if M ~= S then return nil end
				return (level_of[p] == 1 and ESCAPE) or (level_of[p] == 2 and GARBAGE) or nil
			end,
			map_servers = function()
				if M ~= S then return {} end
				return { { bridge = ESCAPE, level = 1 }, { bridge = GARBAGE, level = 2 } }
			end,
		}
		local players = M.env.coop.players
		M.env.coop.players = function()
			local list = players()
			for _, p in ipairs(list) do p.level = level_of[p.id] end
			return list
		end
	end
	W.proxy_a = K.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = G.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	W.proxy_a.level_vertex_id = function() return K.env.level.vertex_id(W.proxy_a._pos) end
	W.proxy_b.level_vertex_id = function() return G.env.level.vertex_id(W.proxy_b._pos) end
	for _, M in ipairs(W.machines) do start(M) end
	W.CK, W.CG = K.env.coop_npc_companions, G.env.coop_npc_companions
	ordinary(K, 300, 201, 50, 500, 10)
	local left = ordinary(G, 400, 301, 50, 500, 20)
	G.env.axr_companions.non_task_companions[301] = nil -- adopted from another map: the marks, not the stock table
	left:give_info_portion("npcx_beh_wait")
	ordinary(G, 410, 311, 52, 501, 20)
	new_squad(360, 10, 261)
	npc(K, 261, 9)
	npc(A, 261, 9)
	new_squad(460, 20, 461)
	new_squad(470, 20, 471, 472)
	for _, M in ipairs({ G, B }) do
		npc(M, 461, 9)
		npc(M, 471, 10)
		npc(M, 472, 11)
	end
	npc(A, 201, 50)
	return W
end

-- the share as coop_srv_levels_share carries it: map servers up (with their level), the world server down
local function share()
	local S = W.S
	for _, M in ipairs({ W.K, W.G }) do
		local e = M.share.up.comp_hired
		check(e ~= nil, "the map server registered its count to tell the world server")
		if e then S.share.up.comp_hired.set(e.get(), M.level_id) end
	end
	local down = S.share.down.comp_hired
	if down then
		for _, M in ipairs({ W.K, W.G }) do M.share.down.comp_hired.set(down.get()) end
	end
end

print("== server: A's companions on the other map count; two players on two maps each up to the limit (m13:3, s35:2)")
do
	server_stand()
	local S, K, G, A, B = W.S, W.K, W.G, W.A, W.B
	tick(1000)
	check(count(A) == 1, "before the world server's word: A is told his one on Escape")
	share()
	tick(1000)
	check(count(A) == 2, "after it: his one on Escape and the one left on Garbage")
	check(count(B) == 1, "B: his one on Garbage (A's squad there is not B's)")
	check(A.env.dialogs_axr_companion.is_room_in_actor_squad(A.env.db.actor, A.objects[261]) == false, "A: no room, on any map")
	-- a modified client of A asks anyway: the world server passes it to Escape, which refuses
	W.talk[1] = 261
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], "paid_companion_dialog")
	pump()
	check(#sent_named(S, "npc.comp") == 1, "the world server passed it on")
	check(cs(K, 360) == nil, "Escape refuses the paid hire: A's companions on Garbage count")
	check(room_refused(K) == 1, "counted by coop_trust on the map server")
	-- B hires on Garbage up to the limit; A's count stays
	W.talk[2] = 461
	B.env.dialogs_axr_companion.become_actor_companion(B.env.db.actor, B.objects[461], "friendly_companion_dialog")
	pump()
	check(cs(G, 460) ~= nil and W.CG._leaders()[460] == 501, "B's recruit on Garbage: his")
	share()
	tick(1000)
	check(count(B) == 2 and count(A) == 2, "B 2, A still 2")
	check(G.share.up.comp_hired.get()[500] == 1 and G.share.up.comp_hired.get()[501] == 2, "Garbage tells the world server per character")
	-- A leaves Escape's list (another map told him something else meanwhile) and comes back: Escape tells him again
	W.k_avatars[1] = nil
	tick(1000)
	G.env.coop_npc_players.send("npc.comp_count", { n = 0 }, 1)
	pump()
	check(count(A) == 0, "another map's word reached him")
	W.k_avatars[1] = 500
	tick(1000)
	check(count(A) == 2, "back on Escape: told again, though his count there did not change")
	-- the word of the world server is checked: a bad row does not count
	K.share.down.comp_hired.set({ m = { [2] = { [500] = "x", [501] = 1e9 }, ["x"] = { [500] = 5 } }, w = { [500] = -3 } })
	tick(1000)
	check(count(A) == 1, "numbers out of bounds in the world server's word are dropped")
	check(errors(K) == 0 and errors(G) == 0 and errors(S) == 0, "no error on any server")
end

print("== server: the guide and Hip's story can recruit with A at the cross-map limit")
for _, dialog in ipairs({ "dm_guide_job", "devushka_4_quest", "adventure_time_with_hip" }) do
	server_stand({ trust = "refuse" })
	local S, K, A = W.S, W.K, W.A
	share()
	tick(1000)
	check(count(A) == LIMIT, dialog .. ": A is at the limit counting Garbage")
	W.talk[1] = 261
	A.env.dialogs_axr_companion.become_actor_companion(A.env.db.actor, A.objects[261], dialog)
	pump()
	check(#sent_named(S, "npc.comp") == 1, dialog .. ": the world server routed the request")
	check(cs(K, 360) ~= nil and W.CK._leaders()[360] == 500, dialog .. ": recruited for A on Escape")
	check(K.env.coop_trust.status().comp_hire_room == nil, dialog .. ": no room check")
end

print("== server: an individual recruit on Garbage, through the world server (m31:1)")
do
	server_stand()
	local S, G, B = W.S, W.G, W.B
	W.talk[2] = 471
	B.env[IRC].become_actor_companion_individually(B.env.db.actor, B.objects[471])
	check(B.clones == nil and sent_f(B, ONE) == 1, "B's machine: one request, no clone")
	pump()
	check(S.clones == nil and G.clones == 1 and G.released and G.released[1] == 471, "the map server of Garbage clones, the world server only passes it")
	local clone = W.next_id
	online(clone)
	run_timers(G)
	check(cs(G, clone + 1000) ~= nil and W.CG._leaders()[clone + 1000] == 501, "the clone joins B on Garbage")
	pump()
	check(B.talks and B.talks[1] == clone, "B's machine opens the talk")
end

print("== server: FFT's companion key of A on Escape: the map server of Escape brings his squads (m21:6)")
do
	server_stand()
	local S, K, A = W.S, W.K, W.A
	A.env.game_fast_travel.on_key_release(KEY)
	pump()
	check(#sent_named(S, "npc.comp_bring") == 1, "the world server passes the key on")
	check(math.abs(K.objects[201]._pos.x - 5) < 0.01, "Escape brings A's companion to him at once")
	check(W.G.objects[301]._pos.x == 50, "his squad on Garbage stays (another map, told to wait)")
end

-------------------------------------------------------------------------------
-- Single player: nothing changes
-------------------------------------------------------------------------------
print("== single player: the stock count, the mod's own individual recruit, FFT's own key")
do
	reset_world()
	W = { squads = {}, raw = {}, se = {}, born = {}, talk = {}, lv = {}, lvn = 0, next_id = 900 }
	local S = machine("single", 0, { [0] = 0 })
	W.machines = { S }
	stock(S)
	mods(S)
	start(S)
	ordinary(S, 300, 201, 50, nil)
	ordinary(S, 310, 211, 52, nil)
	tick(1000)
	check(count(S) == 2, "the stock count (the size of non_task_companions)")
	S.env.axr_companions.companion_squads[310] = nil
	S.env.axr_companions.non_task_companions[211] = nil
	for _, r in ipairs({ { 370, 271, 272 } }) do
		new_squad(r[1], 10, r[2], r[3])
		npc(S, 271, 8)
		npc(S, 272, 9)
	end
	S.env[IRC].become_actor_companion_individually(S.env.db.actor, S.objects[271])
	check(S.clones == 1 and #S.sent == 0, "the mod clones here, nothing is sent")
	local clone = W.next_id
	online(clone)
	run_timers(S)
	check(cs(S, clone + 1000) ~= nil and S.talks and S.talks[1] == clone, "the clone is a companion, the talk opens")
	S.env.db.actor.level_vertex_id = function() return S.env.level.vertex_id(vec(1000, 0, 0)) end
	S.env.game_fast_travel.on_key_release(KEY)
	check(math.abs(S.objects[201]._pos.x - 1000) < 0.01 and #S.sent == 0, "FFT's key: the stock brings the companions, nothing sent")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
