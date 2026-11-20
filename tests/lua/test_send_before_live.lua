-- Build 57 regression 2: a player's machine offers no event to the engine before it is Live.
-- coop.send_event refuses "not in a co-op world" (coop_script.cpp l_send_event) until the client is Live; build 56 ran no
-- sender then (0 such lines in its stand logs), build 57 has ~305 lines (~10^4 refusals: the log keeps the first 10, then
-- every 100th). Senders: coop_npc_presence (SafeSpawn arrival, every frame), coop_npc_stealth_facts (2 per 100 ms),
-- coop_pda_marks_local (3 s), coop_mods_world_views (5 s), all through coop_mods_core.send.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local ARRIVED = "mods.npc_presence_arrived"

-- The engine's test (l_send_event): a process that decides the world, or a client that is Live in it.
local live, decides, refused = false, false, 0
coop.is_live = function() return decides or live end
local accept = coop.send_event
coop.send_event = function(name, payload, target)
	if not (decides or live) then
		refused = refused + 1
		return false, "not in a co-op world"
	end
	return accept(name, payload, target)
end

local level_id = 2
local function pos(x) return vec3(x, 0, 0) end
function game_graph() return { valid_vertex_id = function(_, id) return id >= 0 end,
	vertex = function(_, id) return { level_id = function() return level_id end } end } end
local function body(id, x)
	local se, obj = spawn("body", pos(x), nil, { id = id, kind = "stalker" })
	se.m_game_vertex_id = level_id
	function se:name() return "body_" .. id end
	function obj:game_vertex_id() return level_id end
	return obj
end

-- A player's machine of each mode: the co-op client, the server mode's player.
local MIRROR = {
	actor_is_player = function() return true end,
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
	where = function() return "here" end,
	decider = function() return "other" end,
}
local ROLES = {
	{ role = "coop_client", set = "hostplay", over = MIRROR, mirror = true },
	{ role = "srv_player", set = "srv_map", over = MIRROR, mirror = true },
	{ role = "coop_host", set = "hostplay", decides = true },
	{ role = "srv_world", set = "srv_world", decides = true },
	{ role = "srv_map", set = "srv_map", live = true },
}

-- each role starts with none of the callbacks an earlier role's scripts registered
local registered = {}
local register = RegisterScriptCallback
function RegisterScriptCallback(n, f)
	registered[#registered + 1] = { n, f }
	return register(n, f)
end
local function forget_callbacks()
	for _, nf in ipairs(registered) do UnregisterScriptCallback(nf[1], nf[2]) end
	registered = {}
end

local function frames(ms)
	local stop = NOW + ms
	while NOW < stop do
		NOW = NOW + 16
		SendScriptCallback("actor_on_update")
	end
end

for _, r in ipairs(ROLES) do
	forget_callbacks()
	MODE, SELF = r.mirror and "client" or "host", r.mirror and 1 or (r.set == "srv_map" and 257 or 0)
	OBJ, SE, SENT, db.storage = {}, {}, {}, {}
	live, decides, refused = r.live == true, r.decides == true, 0
	local me = body(500, 0)
	db.actor = me
	coop.players = function() return { { id = 1, avatar_id = 500, level = level_id, is_self = r.mirror } } end
	coop.avatar_of = function(id) return id == 1 and 500 or nil end
	coop.life_of = function(id) return OBJ[id] and OBJ[id]:alive() and "alive" or "dead" end
	coop.levels = { split = function() return r.set ~= "hostplay" end, my_level = function() return level_id end,
		level_of_player = function() return level_id end }
	local facade = load_script("coop_mode")
	modes.install(facade, r.set, r.over)
	load_script("coop_main").on_game_start()
	load_script("coop_mods_core")
	load_script("coop_npc_players")
	load_script("coop_trust")
	for _, cb in ipairs({ "actor_on_first_update", "actor_on_update", "on_level_changing", "save_state", "load_state" }) do
		AddScriptCallback(cb)
	end
	game_object = { enemy = 2 }
	safespawn = { perform_silo = function() return "stock" end,
		get_config = function(key) return ({ radius = 5, duration = 10 })[key] end }
	load_script("coop_npc_presence").on_game_start()

	-- 1. The Core's sender (to_host / to_all / to_peer / publish / send_big go through it)
	local ok = coop_mods_core.to_host("probe", { a = 1 })
	if r.mirror then
		check(ok == false and refused == 0, r.role .. ": before Live coop_mods_core offers the engine nothing (" .. refused .. " refused)")
		live = true
		local before = refused
		check(coop_mods_core.to_host("probe", { a = 1 }) == true and refused == before, r.role .. ": once Live the same send goes")
		live = false
	else
		check(ok == true and refused == 0, r.role .. ": a process that may send sends as before")
	end

	-- 2. SafeSpawn arrival: a load held 15 s after the first update (the server mode's held screen; a co-op transition
	-- that waits for the others), then Live
	if r.mirror then
		SENT, refused = {}, 0
		SendScriptCallback("actor_on_first_update")
		frames(15000)
		check(refused == 0 and sent_count(ARRIVED) == 0, r.role .. ": no arrival is offered while loading (" .. refused .. " refused)")
		live = true
		frames(1100)
		local t = sent(ARRIVED)
		check(sent_count(ARRIVED) == 1 and t and t.map == level_id, r.role .. ": the arrival reaches the decider once Live (sent "
			.. sent_count(ARRIVED) .. ")")
		frames(12000)
		check(sent_count(ARRIVED) == 1, r.role .. ": one arrival per appearance")
	end
end

-- 3. Single player: no session, no engine call (unchanged)
MODE, SELF, SENT, refused, live, decides = "sp", -1, {}, 0, false, false
coop.is_active = function() return false end
modes.install(load_script("coop_mode"), "none")
load_script("coop_mods_core")
check(coop_mods_core.to_host("probe", {}) == false and refused == 0 and #SENT == 0, "single player: nothing is sent")

done("send_before_live")
