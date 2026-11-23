-- F4 unit G14-2 (review m15:1, m15:2; docs\reports\2026-11-18-f4-gamma-review.md, G14): the fetch tasks of the Tasks QoL Pack
-- (tasks_fetch.script, the real file: the stand's copy GAMMA_SCRIPTS, else temp\review\corpus\merged) in a session.
--   m15:1  the mod pays a fetch task one second after the hand-over from CreateTimeEvent(0, "delay_reward"): the queue keeps one
--          event per key, a second hand-over within that second lost its payment. Every hand-over gets its own key (task,
--          character, counter) and its reward context: each player is paid once, to himself, also when he reconnected meanwhile.
--   m15:2  one criterion of an acceptable item (its section, not on its holder's belt, the condition two tasks ask for, the
--          count) for the readiness check, the hand-over check and the collection. Another player's belt is his machine's word
--          (event mods.fetch_belt), asked again at the hand-over: a stale report is dropped. The take goes through
--          coop_quests_trust.check_take / note_take.
-- Co-op: the host's process decides; the client's character is a game object there, his belt only his machine knows.
-- Server: the world server decides; the players stand on map servers, the world server has their records (what they carry, no
-- belt); once two players on two maps at the same second.
-- Single player (no session): the mod's own functions, untouched.
-- Run: tools\test_lua.cmd quests_fetch
dofile("tests/lua/support/harness_quests.lua")

local BS = string.char(92)

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local MOD_SRC, MOD_FROM = nil, nil
do
	local list = {}
	local real = os.getenv("GAMMA_SCRIPTS")
	if real and real ~= "" then list[#list + 1] = real .. BS .. "tasks_fetch.script" end
	list[#list + 1] = "temp/review/corpus/merged/tasks_fetch.script"
	for _, p in ipairs(list) do
		if not MOD_SRC then MOD_SRC, MOD_FROM = read_file(p), p end
	end
end
if not MOD_SRC then
	print("  FAIL the real tasks_fetch.script is required (GAMMA_SCRIPTS or temp/review/corpus/merged)")
	print("0 passed, 1 failed")
	os.exit(1)
end
print("tasks_fetch.script: " .. MOD_FROM)

local COST = { af_x = 4000, bread = 100, medkit = 300 }

-- What the stubs lack for the real mod, the time event queue of the build and the mod itself, loaded as CScriptStorage does.
local function setup(M)
	local e = M.env
	local O = M.ObjMT
	function O:iterate_belt(f)
		local list = {}
		for _, it in ipairs(self._inv) do if it._belt then list[#list + 1] = it end end
		for _, it in ipairs(list) do f(self, it) end
	end
	function O:get_weapon_type() return 255 end
	-- game objects have no == (luabind): the harness's own release and transfer compare with it, these compare by identity
	function O:transfer_item(item, to)
		for i, it in ipairs(self._inv) do
			if rawequal(it, item) then
				table.remove(self._inv, i)
				to._inv[#to._inv + 1] = item
				item._parent = to
				return
			end
		end
	end
	e.alife_release_id = function(id)
		local o = M.objects[id]
		if o and o._parent then
			for i, it in ipairs(o._parent._inv) do
				if rawequal(it, o) then
					table.remove(o._parent._inv, i)
					break
				end
			end
		end
		M.objects[id] = nil
		M.released = (M.released or 0) + 1
	end
	e.ini_sys.r_float_ex = function(_, sec, key) if key == "cost" then return COST[sec] or 100 end return nil end
	e.ini_sys.r_string_ex = function() return nil end
	e.is_empty = function(t) return next(t) == nil end
	e.IsArtefact = function() return false end
	e.printdbg = function() end
	e.alife = function() return {} end
	e.level.add_cam_effector = function() end
	e.utils_item.get_amount = function(npc, sec) return M.count(npc, sec) end
	e.xr_effects.play_inv_aac_open = function() end
	-- stock xr_effects.reward_random_money pays a random sum between the two through dialogs.relocate_money: here the lower one
	e.xr_effects.reward_random_money = function(a, n, p)
		e.dialogs.relocate_money(e.db.actor, math.floor(tonumber(p[1])), "in")
	end
	M.on_complete = {}
	-- _g_patches.script (merged corpus) CreateTimeEvent: a key the queue holds is not taken again; an event that returns true
	-- is removed, anything else stays for the next frame
	M.evq, M.keys = {}, {}
	e.CreateTimeEvent = function(ev, act, t, f, ...)
		local k = tostring(ev) .. "|" .. tostring(act)
		M.keys[#M.keys + 1] = k
		if M.evq[k] then return end
		M.evq[k] = { f = f, p = { ... }, n = select("#", ...), at = NOW + (tonumber(t) or 0) * 1000, k = k }
	end
	local f = assert(loadstring(MOD_SRC, "@tasks_fetch.script"))
	local mod = setmetatable({}, { __index = e })
	e.tasks_fetch = mod
	setfenv(f, mod)
	f()
end

local function process(M)
	local due = {}
	for _, node in pairs(M.evq) do
		if node.at <= NOW then due[#due + 1] = node end
	end
	table.sort(due, function(a, b) return a.k < b.k end)
	for _, node in ipairs(due) do
		if node.f(unpack(node.p, 1, node.n)) == true and M.evq[node.k] == node then M.evq[node.k] = nil end
	end
end

-- frames of 100 ms: the events travel, the queues run
local function settle(list, ms)
	for _ = 1, math.floor((ms or 1500) / 100) do
		NOW = NOW + 100
		pump()
		for _, M in ipairs(list) do process(M) end
	end
	pump()
end

local modes = dofile("tests/lua/support/modes.lua")

local function boot(M, list)
	local function load(name) return load_script(M, name) end
	local facade = load("coop_mode")
	facade.on_game_start()
	modes.live(facade, load)
	for _, n in ipairs(list) do load_script(M, n) end
	for _, n in ipairs(list) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

-- A running fetch task of the host's task manager, its facts written by the host itself (the offer's fetch_func).
local function fetch_task(M, id, sec, count)
	M.ini[id] = { status_functor = "actor_has_fetch_item" }
	M.tm.task_info[id] = setmetatable({ id = id, stage = 0, status_functor = "actor_has_fetch_item" }, M.env.task_objects.CGeneralTask)
	M.env.save_var(M.actor, id .. "_fetch", sec)
	M.env.save_var(M.actor, id .. "_fetch_count", count)
	M.on_complete[id] = function() M.env.xr_effects.fetch_reward_and_remove(M.actor, nil, { id .. "_fetch", "1" }) end
	return M.tm.task_info[id]
end

-- The engine ends the task for player `peer`: coop_tasks' task callback, the stock on_complete inside (the mod's effect).
local function hand_over(M, id, peer)
	M.env.coop_tasks.host_note(id, "finisher", peer)
	M.env.task_manager.task_callback({ get_id = function() return id end }, M.env.task.completed)
end

-- The readiness check: the status functor as the task manager runs it, once more after the events of the first went round.
local function readiness(M, id)
	local t = M.tm.task_info[id]
	M.env.task_status_functor.actor_has_fetch_item(t, id)
	pump()
	M.env.task_status_functor.actor_has_fetch_item(t, id)
	return t.stage
end

local function granted(M, peer)
	local sum, n = 0, 0
	for _, c in ipairs(M.money_calls) do
		if c.fn == "money_grant" and c.peer == peer and c.ok then sum, n = sum + c.n, n + 1 end
	end
	return sum, n
end

local function trust(M, name)
	local c = M.env.coop_trust.status()[name]
	return c and c.checked or 0, c and c.failed or 0
end

local function holder(M, id) local o = M.objects[id] return o and o._parent and o._parent._id end

local function has_key(M, prefix)
	for _, k in ipairs(M.keys) do if k:sub(1, #prefix) == prefix then return true end end
	return false
end

local HOST_SCRIPTS = { "coop_trust", "coop_quests_trust", "coop_quests_core", "coop_srv_quests_core",
	"coop_mods_core", "coop_tasks", "coop_quests_fetch" }
local PLAYER_SCRIPTS = { "coop_quests_core", "coop_srv_quests_core", "coop_mods_core", "coop_tasks", "coop_quests_fetch" }

-- ==================================================================================================================== Co-op
print("== Co-op: the host plays and decides, the client's character is a game object on the host")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup(Hm)
setup(Cm)
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- the client's character on the host
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true }) -- the host's character on the client
Hm.npc = Hm.new_obj(700, "bar_dolg_leader", vec(5, 0, 0), { _stalker = true })
Hm.env.db.storage[700] = { object = Hm.npc }
Cm.npc = Cm.new_obj(700, "bar_dolg_leader", vec(5, 0, 0), { _stalker = true })
Cm.env.db.storage[700] = { object = Cm.npc }
local HOST_PLAYERS = { { id = 0, is_self = true, avatar_id = 0, nick = "host" }, { id = 1, is_self = false, avatar_id = 500, nick = "cl" } }
Hm.players = HOST_PLAYERS
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
boot(Hm, HOST_SCRIPTS)
boot(Cm, PLAYER_SCRIPTS)
local CO = { Hm, Cm }

-- An item of the client: in his character on the host and in his own actor, one id. Only his own copy is ever on a belt.
local function client_item(sec, opts)
	local it = Hm.give_item(proxy, sec, opts)
	local mine = Cm.new_obj(it._id, sec, nil, opts)
	mine._parent = Cm.actor
	Cm.actor._inv[#Cm.actor._inv + 1] = mine
	return { host = it, mine = mine, id = it._id }
end

local function clear_co()
	Hm.actor._inv, proxy._inv, Cm.actor._inv = {}, {}, {}
end

-- ------------------------------------------------------------------------------------------------------------ m15:1
print("== [m15:1] co-op: the client and the host hand over two fetch tasks in the same second")
clear_co()
fetch_task(Hm, "fetch_a", "bread", 1)
fetch_task(Hm, "fetch_b", "medkit", 1)
client_item("bread")
Hm.give_item(Hm.actor, "medkit")
local m0 = Hm.actor._money
local g0, n0 = granted(Hm, 1)
hand_over(Hm, "fetch_a", 1)
hand_over(Hm, "fetch_b", 0)
settle(CO, 1500)
local g1, n1 = granted(Hm, 1)
check(n1 - n0 == 1 and g1 - g0 == 90, "[m15:1] the client is paid once for his bread (90 RU), got " .. tostring(g1 - g0))
check(Hm.actor._money - m0 == 270, "[m15:1] the host is paid once for his medkit (270 RU), got " .. tostring(Hm.actor._money - m0))
check(Hm.count(proxy, "bread") == 0 and Hm.count(Hm.actor, "bread") == 0, "[m15:1] the bread is taken")
check(Hm.count(Hm.actor, "medkit") == 0, "[m15:1] the medkit is taken")
check(has_key(Hm, "0|delay_reward|fetch_a|500|") and has_key(Hm, "0|delay_reward|fetch_b|0|"),
	"[m15:1] each hand-over has its own timer key: task, character, counter")

print("== [m15:1] co-op: one player hands the same task over twice in a second (given again at once)")
clear_co()
g0, n0 = granted(Hm, 1)
fetch_task(Hm, "fetch_a", "bread", 1)
client_item("bread")
hand_over(Hm, "fetch_a", 1)
fetch_task(Hm, "fetch_a", "bread", 1)
client_item("bread")
hand_over(Hm, "fetch_a", 1)
settle(CO, 1500)
g1, n1 = granted(Hm, 1)
check(n1 - n0 == 2 and g1 - g0 == 180, "[m15:1] two payments of 90 RU, got " .. tostring(n1 - n0) .. " for " .. tostring(g1 - g0))
check(Hm.count(proxy, "bread") == 0 and Hm.count(Hm.actor, "bread") == 0, "[m15:1] both breads are taken")

print("== [m15:1] co-op: the client reconnects (a new peer, the same character) before his reward is paid")
clear_co()
fetch_task(Hm, "fetch_c", "bread", 1)
client_item("bread")
local g_old0 = granted(Hm, 1)
local g_new0 = granted(Hm, 3)
hand_over(Hm, "fetch_c", 1)
pump()
Hm.players = { HOST_PLAYERS[1], { id = 3, is_self = false, avatar_id = 500, nick = "cl" } }
settle(CO, 1500)
local g_new1, n_new = granted(Hm, 3)
check(g_new1 - g_new0 == 90 and n_new == 1, "[m15:1] the reward goes to his character, under his new peer 3, got " .. tostring(g_new1 - g_new0))
check(granted(Hm, 1) == g_old0, "[m15:1] nothing goes to the peer he left")
Hm.players = HOST_PLAYERS

-- ------------------------------------------------------------------------------------------------------------ m15:2
local FT = "fetch_x"
local host_tbl = Hm.env.coop_mods_core.find_local(Hm.env.coop_tasks, "host")
local function short(id) return host_tbl.item_short(Hm.tm, id) end

print("== [m15:2] co-op: the host's only artefact is on his belt")
clear_co()
fetch_task(Hm, FT, "af_x", 1)
local worn_h = Hm.give_item(Hm.actor, "af_x", { _belt = true })
check(readiness(Hm, FT) == 0, "[m15:2] readiness: not ready (a worn artefact is no hand-over, the group's count neither)")
check(short(FT) ~= nil, "[m15:2] hand-over check: a client's turn-in is refused, the same criterion (" .. tostring(short(FT)) .. ")")

print("== [m15:2] co-op: the client's only artefact is on his belt (only his machine knows)")
clear_co()
local asks0 = count_sent(Hm, "mods.fetch_belt_ask")
local c1 = client_item("af_x")
c1.mine._belt = true
check(readiness(Hm, FT) == 0, "[m15:2] readiness: not ready, his machine reports it on his belt")
check(count_sent(Hm, "mods.fetch_belt_ask") > asks0 and count_sent(Cm, "mods.fetch_belt") > 0, "[m15:2] the host asked his machine, it answered")
check(short(FT) ~= nil, "[m15:2] hand-over check: refused with the same report")
c1.mine._belt = false
NOW = NOW + 2500
check(readiness(Hm, FT) == 1, "[m15:2] readiness: ready once his machine reports it off the belt")
check(short(FT) == nil, "[m15:2] hand-over check: goes through with the same report")

print("== [m15:2] co-op: a real client turn-in of the task (his request, the host's check)")
clear_co()
local tm_c = Cm.env.task_manager.get_task_manager()
Hm.tm.task_info[FT] = nil
tm_c:give_task(FT, 700)
pump()
check(Hm.tm.task_info[FT] ~= nil, "the host gave the client the fetch task")
Hm.env.save_var(Hm.actor, FT .. "_fetch", "af_x")
Hm.env.save_var(Hm.actor, FT .. "_fetch_count", 1)
worn_h = Hm.give_item(Hm.actor, "af_x", { _belt = true })
local function client_turn_in(id)
	tm_c:set_task_completed(id)
	pump()
	local t = Hm.tm.task_info[id]
	local ok = t ~= nil and t.forced_status == "complete"
	if t then t.forced_status = nil end
	return ok
end
check(not client_turn_in(FT), "[m15:2] the group's only artefact is worn by the host: the client's turn-in is refused")
local free_c = client_item("af_x")
readiness(Hm, FT)
check(client_turn_in(FT), "[m15:2] the client carries one off his belt: goes through")

print("== [m15:2] co-op: collection: the client's worn artefact stays, the host's spare one goes")
clear_co()
fetch_task(Hm, "fetch_d", "af_x", 1)
local worn_c = client_item("af_x")
worn_c.mine._belt = true
local spare_h = Hm.give_item(Hm.actor, "af_x")
local take0 = trust(Hm, "quest_take")
g0, n0 = granted(Hm, 1)
hand_over(Hm, "fetch_d", 1)
settle(CO, 1500)
check(holder(Hm, worn_c.id) == 500, "[m15:2] the client's worn artefact stays in his character")
check(Hm.objects[spare_h._id] == nil, "[m15:2] the host's spare artefact is taken")
g1, n1 = granted(Hm, 1)
check(n1 - n0 == 1 and g1 - g0 == 3600, "[m15:2] the client is paid for the artefact (3600 RU), got " .. tostring(g1 - g0))
check(trust(Hm, "quest_take") == take0 + 1, "[m15:2] the take went through coop_quests_trust.check_take (quest_take)")

print("== [m15:2] co-op: collection: the turning-in client's own item goes first, the host keeps his")
clear_co()
fetch_task(Hm, "fetch_e", "medkit", 1)
local mk_h = Hm.give_item(Hm.actor, "medkit")
local mk_c = client_item("medkit")
hand_over(Hm, "fetch_e", 1)
settle(CO, 1500)
check(Hm.objects[mk_c.id] == nil, "[m15:2] the client's medkit is taken")
check(holder(Hm, mk_h._id) == 0, "[m15:2] the host keeps his medkit")
check(Hm.count(Hm.actor, "medkit") == 1, "[m15:2] no client item is left behind in the host's inventory")

print("== [m15:2] co-op: the client's answer comes after the mod's second: the reward waits for it")
clear_co()
fetch_task(Hm, "fetch_late", "medkit", 1)
local late = client_item("medkit")
local held, real_ask = {}, Cm.handlers["mods.fetch_belt_ask"]
Cm.handlers["mods.fetch_belt_ask"] = function(payload, from) held[#held + 1] = { payload, from } end
g0 = granted(Hm, 1)
hand_over(Hm, "fetch_late", 1)
settle(CO, 1500)
check(Hm.objects[late.id] ~= nil and granted(Hm, 1) == g0, "[m15:2] 1.5 s later, no answer yet: the reward waits, nothing taken")
Cm.handlers["mods.fetch_belt_ask"] = real_ask
for _, h in ipairs(held) do real_ask(h[1], h[2]) end
settle(CO, 500)
check(Hm.objects[late.id] == nil and granted(Hm, 1) - g0 == 270, "[m15:2] his answer came: his medkit is taken, he is paid")

print("== [m15:2] co-op: the artefact sits in a container the client carries")
clear_co()
fetch_task(Hm, "fetch_box", "af_x", 1)
local box = client_item("af_x_lead_box")
NOW = NOW + 2500
check(readiness(Hm, "fetch_box") == 1 and short("fetch_box") == nil, "[m15:2] a container counts in the checks (no belt involved)")
g0 = granted(Hm, 1)
hand_over(Hm, "fetch_box", 1)
settle(CO, 1500)
check(Hm.objects[box.id] == nil and Hm.count(proxy, "lead_box") == 1, "[m15:2] the container is opened: its empty box goes back to him")
check(Hm.count(Hm.actor, "af_x") == 0 and granted(Hm, 1) - g0 == 3600, "[m15:2] the artefact is taken, he is paid 3600 RU")

print("== [m15:2] co-op: one criterion in the three places")
local CASES = {
	{ "host worn", 1, function() Hm.give_item(Hm.actor, "af_x", { _belt = true }) end, 0 },
	{ "host free", 1, function() Hm.give_item(Hm.actor, "af_x") end, 1 },
	{ "both worn", 1, function() Hm.give_item(Hm.actor, "af_x", { _belt = true }) client_item("af_x").mine._belt = true end, 0 },
	{ "2: host free, client worn", 2, function() Hm.give_item(Hm.actor, "af_x") client_item("af_x").mine._belt = true end, 1 },
	{ "2: host free, client free", 2, function() Hm.give_item(Hm.actor, "af_x") client_item("af_x") end, 2 },
}
for i, c in ipairs(CASES) do
	clear_co()
	local id = "fetch_case_" .. i
	fetch_task(Hm, id, "af_x", c[2])
	c[3]()
	NOW = NOW + 2500
	local stage = readiness(Hm, id)
	local ok = short(id) == nil
	local before = Hm.count(Hm.actor, "af_x") + Hm.count(proxy, "af_x")
	local worn = {}
	for _, it in ipairs(Hm.actor._inv) do if it._belt then worn[#worn + 1] = it._id end end
	for _, it in ipairs(Cm.actor._inv) do if it._belt then worn[#worn + 1] = it._id end end
	hand_over(Hm, id, 1)
	settle(CO, 1500)
	local taken = before - Hm.count(Hm.actor, "af_x") - Hm.count(proxy, "af_x")
	local kept = true
	for _, w in ipairs(worn) do if Hm.objects[w] == nil then kept = false end end
	local ready = c[4] >= c[2]
	check((stage == 1) == ready and ok == ready and kept and taken == c[4],
		string.format("[m15:2] %s: readiness %s, hand-over check %s, taken %d of acceptable %d, worn kept %s", c[1], tostring(stage),
			tostring(ok), taken, c[4], tostring(kept)))
end

print("== [m15:2] co-op: the two tasks that ask for a condition (0.9): the same rule everywhere")
clear_co()
local NIMBLE = "esc_2_12_stalker_nimble_task_1"
fetch_task(Hm, NIMBLE, "medkit", 1)
local worn_mk = client_item("medkit", { _cond = 0.5 })
NOW = NOW + 2500
check(readiness(Hm, NIMBLE) == 0 and short(NIMBLE) ~= nil, "[m15:2] a medkit at 50%: not ready, refused")
local good_mk = client_item("medkit", { _cond = 0.95 })
NOW = NOW + 2500
check(readiness(Hm, NIMBLE) == 1 and short(NIMBLE) == nil, "[m15:2] a medkit at 95%: ready, goes through")
hand_over(Hm, NIMBLE, 1)
settle(CO, 1500)
check(Hm.objects[good_mk.id] == nil and holder(Hm, worn_mk.id) == 500, "[m15:2] the good one is taken, the worn-out one stays")

print("== co-op: on the client's machine (a mirror) the mod's effect stays the mod's: its own timer, kept by the router on the host")
Cm.keys = {}
Cm.env.save_var(Cm.actor, "fetch_cl_fetch", "bread")
Cm.env.xr_effects.fetch_reward_and_remove(Cm.actor, nil, { "fetch_cl_fetch", "1" })
check(Cm.keys[#Cm.keys] == "0|delay_reward" and count_sent(Cm, "mods.fetch_belt_ask") == 0,
	"a player's machine: the mod's own key, no ask goes out")
Cm.evq = {}

-- ------------------------------------------------------------------------------------------------------------ no session
print("== single player (no session): the mod's own functions, untouched")
clear_co()
Hm.active = false
local sp = fetch_task(Hm, "fetch_sp", "af_x", 1)
local sp_worn = Hm.give_item(Hm.actor, "af_x", { _belt = true })
Hm.env.task_status_functor.actor_has_fetch_item(sp, "fetch_sp")
check(sp.stage == 0, "SP: the mod's rule, its only artefact on the belt: not ready")
local sp_free = Hm.give_item(Hm.actor, "af_x")
Hm.env.save_var(Hm.actor, "fetch_sp_fetch_count", 2)
Hm.env.task_status_functor.actor_has_fetch_item(sp, "fetch_sp")
check(sp.stage == 1, "SP: the mod's rule, two of two, one of them worn: ready (as the mod says)")
local sp_asks = count_sent(Hm, "mods.fetch_belt_ask")
Hm.keys = {}
local sp_m0 = Hm.actor._money
Hm.env.xr_effects.fetch_reward_and_remove(Hm.actor, nil, { "fetch_sp_fetch", "1" })
check(Hm.keys[#Hm.keys] == "0|delay_reward", "SP: the mod's own timer key")
settle({ Hm }, 1500)
check(Hm.actor._money - sp_m0 == 3600 and Hm.objects[sp_free._id] == nil and holder(Hm, sp_worn._id) == 0,
	"SP: the mod pays for the free one and leaves the worn one")
check(count_sent(Hm, "mods.fetch_belt_ask") == sp_asks, "SP: nothing goes to the network")
Hm.active = true

-- =================================================================================================================== Server
print("== Server: the world server decides; the players stand on map servers, the world server has their records, no belt")
MACHINES, QUEUE = {}, {}
local W = machine("host", 0)
local P1 = machine("client", 1)
local P2 = machine("client", 2)
setup(W)
setup(P1)
setup(P2)
W.env.coop.is_dedicated = function() return true end -- the world server's actor is a ghost, nobody's character
local CARRIED = { [501] = {}, [502] = {} } -- the world server's records of what each player carries
local LEVEL = { [1] = 11, [2] = 12 } -- two maps: P1 on 11, P2 on 12; the world server stands on neither
W.env.coop.levels = {
	split = function() return true end,
	my_level = function() return 1 end,
	level_of_player = function(p) return LEVEL[p] end,
	carried = function(id) return CARRIED[id] or {} end,
}
-- The server players know the session mode from their Welcome.
P1.env.coop.levels = { split = W.env.coop.levels.split }
P2.env.coop.levels = { split = W.env.coop.levels.split }
W.new_obj(501, "coop_player_avatar")
W.new_obj(502, "coop_player_avatar")
do
	local by_id = W.env.level.object_by_id
	W.env.level.object_by_id = function(id) if CARRIED[id] then return nil end return by_id(id) end -- no map of theirs here
	local release = W.env.alife_release_id
	W.env.alife_release_id = function(id)
		for _, list in pairs(CARRIED) do
			for i, it in ipairs(list) do
				if it.id == id then
					table.remove(list, i)
					return
				end
			end
		end
		return release(id)
	end
	W.env.itms_manager = { create_item = function(sec, to) return W.give_item(W.objects[to:id()], sec) end }
end
W.players = { { id = 0, is_self = true, nick = "world" }, { id = 1, is_self = false, avatar_id = 501, nick = "p1" },
	{ id = 2, is_self = false, avatar_id = 502, nick = "p2" } }
P1.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false }, { id = 2, is_self = false, avatar_id = 502 } }
P2.players = { { id = 2, is_self = true, avatar_id = 0 }, { id = 0, is_self = false }, { id = 1, is_self = false, avatar_id = 501 } }
boot(W, HOST_SCRIPTS)
boot(P1, PLAYER_SCRIPTS)
boot(P2, PLAYER_SCRIPTS)
local SRV = { W, P1, P2 }

-- An item of a player: in his own actor and in the world server's record of him, one id.
local function player_item(P, avatar, sec, belt)
	local it = P.give_item(P.actor, sec, { _belt = belt })
	table.insert(CARRIED[avatar], { id = it._id, section = sec, condition = 1 })
	return it
end
local function carries(avatar, id)
	for _, it in ipairs(CARRIED[avatar]) do if it.id == id then return true end end
	return false
end
local function clear_srv()
	CARRIED[501], CARRIED[502] = {}, {}
	P1.actor._inv, P2.actor._inv, W.actor._inv = {}, {}, {}
end

print("== [m15:1] server: two players on two maps hand over two fetch tasks in the same second")
clear_srv()
fetch_task(W, "fetch_p1", "bread", 1)
fetch_task(W, "fetch_p2", "medkit", 1)
player_item(P1, 501, "bread")
player_item(P2, 502, "medkit")
hand_over(W, "fetch_p1", 1)
hand_over(W, "fetch_p2", 2)
settle(SRV, 1500)
local s1, sn1 = granted(W, 1)
local s2, sn2 = granted(W, 2)
check(sn1 == 1 and s1 == 90, "[m15:1] server: player 1 is paid once for his bread (90 RU), got " .. tostring(s1))
check(sn2 == 1 and s2 == 270, "[m15:1] server: player 2 is paid once for his medkit (270 RU), got " .. tostring(s2))
check(#CARRIED[501] == 0 and #CARRIED[502] == 0, "[m15:1] server: both items left their records")

print("== [m15:2] server: a player hands over with an artefact on his belt and a spare one")
clear_srv()
fetch_task(W, "fetch_s1", "af_x", 1)
local worn1 = player_item(P1, 501, "af_x", true)
local spare1 = player_item(P1, 501, "af_x", false)
s1 = granted(W, 1)
hand_over(W, "fetch_s1", 1)
settle(SRV, 1500)
check(carries(501, worn1._id) and not carries(501, spare1._id), "[m15:2] server: the worn artefact stays with him, the spare one is taken")
check(granted(W, 1) - s1 == 3600, "[m15:2] server: he is paid for it (3600 RU)")

print("== [m15:2] server: the hand-over asks again; the cached readiness report is not used, a stale one is dropped")
clear_srv()
fetch_task(W, "fetch_s2", "af_x", 1)
local a2 = player_item(P1, 501, "af_x", false)
NOW = NOW + 2500
check(readiness(W, "fetch_s2") == 1, "[m15:2] server: readiness with his report (off the belt): ready")
local old_report = last_sent(P1, "mods.fetch_belt")
a2._belt = true -- he puts it on before he turns the task in
hand_over(W, "fetch_s2", 1)
settle(SRV, 1500)
check(carries(501, a2._id), "[m15:2] server: his fresh report at the hand-over (on the belt) wins: the artefact stays with him")
local _, fresh_failed0 = trust(W, "fetch_belt_fresh")
local report_in = W.handlers["mods.fetch_belt"]
if report_in and old_report then report_in(H.encode(old_report), 1) end
local _, fresh_failed1 = trust(W, "fetch_belt_fresh")
check(old_report ~= nil and fresh_failed1 == fresh_failed0 + 1, "[m15:2] server: the old report sent again is dropped (guard fetch_belt_fresh)")
local forged = { o = 999999, t = "fetch_s2", n = 0 }
if report_in then report_in(H.encode(forged), 2) end
local _, fresh_failed2 = trust(W, "fetch_belt_fresh")
check(fresh_failed2 == fresh_failed1 + 1, "[m15:2] server: a report that answers no ask of his is dropped")

print("== [m15:2] server: his machine does not answer: his items are not taken")
clear_srv()
fetch_task(W, "fetch_s3", "af_x", 1)
local b3 = player_item(P2, 502, "af_x", false)
local ask_handler = P2.handlers["mods.fetch_belt_ask"]
P2.handlers["mods.fetch_belt_ask"] = nil
s2 = granted(W, 2)
hand_over(W, "fetch_s3", 2)
settle(SRV, 4500)
P2.handlers["mods.fetch_belt_ask"] = ask_handler
check(carries(502, b3._id), "[m15:2] server: no fresh belt report in time: his artefact stays with him")
check(has_log(W, "no fresh belt report"), "[m15:2] server: the world server says why")
check(granted(W, 2) == s2, "[m15:2] server: nothing was taken, nothing is paid")

print("== REP-TRUST: the world skips known loaders and ignores a belated answer")
do
	clear_srv()
	fetch_task(W, "fetch_expired", "af_x", 1)
	player_item(P2, 502, "af_x", false)
	local p2_joined = false
	W.env.coop.session_info = function()
		return { players = { { id = 1, joined = true }, { id = 2, joined = p2_joined } } }
	end
	local held
	P2.handlers["mods.fetch_belt_ask"] = function(payload, from) held = { payload, from } end
	NOW = NOW + 11000
	local sent = count_sent(W, "mods.fetch_belt_ask")
	readiness(W, "fetch_expired")
	check(count_sent(W, "mods.fetch_belt_ask") == sent and not held, "a peer still loading gets no belt ask")
	p2_joined = true
	NOW = NOW + 2100
	sent = count_sent(W, "mods.fetch_belt_ask")
	readiness(W, "fetch_expired")
	check(count_sent(W, "mods.fetch_belt_ask") == sent + 1 and held ~= nil, "the ask goes out once the peer has joined")
	P2.handlers["mods.fetch_belt_ask"] = ask_handler

	NOW = NOW + 10001
	readiness(W, "fetch_expired") -- a new ask prunes the outstanding old one
	local _, failed = trust(W, "fetch_belt_fresh")
	if held then
		local ask = H.decode(held[1])
		report_in(H.encode({ o = ask.o, t = ask.t, n = 0 }), 1)
	end
	local _, foreign_failed = trust(W, "fetch_belt_fresh")
	check(foreign_failed == failed + 1, "an expired ask never excuses another player's answer")
	local logs = #W.log
	if held then ask_handler(unpack(held)) end
	pump()
	local _, late_failed = trust(W, "fetch_belt_fresh")
	check(late_failed == foreign_failed and #W.log == logs, "the owner of the expired ask answers without a trust line")
	W.env.coop_mods_core.print_status()
	check(has_log(W, "late 1)"), "the late report increments the fetch counter")
	NOW = NOW + 10000
	if held then ask_handler(unpack(held)) end
	pump()
	local _, gone_failed = trust(W, "fetch_belt_fresh")
	check(gone_failed == late_failed + 1, "the expired ask is forgotten after a second TTL")
	W.env.coop.session_info = nil
end

print("== [m15:2] server: two players on two maps hand over in the same second, each with a worn and a spare artefact")
clear_srv()
fetch_task(W, "fetch_t1", "af_x", 1)
fetch_task(W, "fetch_t2", "af_x", 1)
local w1, f1 = player_item(P1, 501, "af_x", true), player_item(P1, 501, "af_x", false)
local w2, f2 = player_item(P2, 502, "af_x", true), player_item(P2, 502, "af_x", false)
s1, s2 = granted(W, 1), granted(W, 2)
hand_over(W, "fetch_t1", 1)
hand_over(W, "fetch_t2", 2)
settle(SRV, 1500)
check(carries(501, w1._id) and not carries(501, f1._id), "[m15:2] server: player 1 keeps his worn one, the spare is taken")
check(carries(502, w2._id) and not carries(502, f2._id), "[m15:2] server: player 2 keeps his worn one, the spare is taken")
check(granted(W, 1) - s1 == 3600 and granted(W, 2) - s2 == 3600, "[m15:2] server: each is paid once, 3600 RU")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
