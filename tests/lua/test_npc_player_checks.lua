-- Dev 57 G13-3. Run the active upstream schemes over the real player registry and mode facade.
local modes = dofile("tests/lua/support/modes.lua")
local PANIC = "mods.npc_player_checks_panic"
local WARNING = "mods.npc_player_checks_bribe_warning"
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
coop.is_map_server = function() return mode == "srv_map" end
coop.is_dedicated = function() return mode == "srv_world" end

local function stock_chunk(name)
	local file = name .. ".script"
	return assert(loadfile("temp/review/corpus/merged/" .. file)
		or loadfile("temp/stock_scripts/scripts/" .. file)
		or loadfile("../anomaly-ref/unpacked/scripts/" .. file), file)
end

local function stock(name, f)
	local mod = setmetatable({}, { __index = _G })
	_G[name] = mod
	setfenv(f or stock_chunk(name), mod)()
	return mod
end

function class(name)
	local env = getfenv(2)
	return function() env[name] = {} end
end
AC_ID = 0
clsid = setmetatable({ script_actor = 1, script_stalker = 2, bloodsucker_s = 3 }, {
	__index = function(t, k) local v = 10 + #t; t[k] = v; return v end,
})
function IsStalker(o, c) c = c or o:clsid(); return c == 1 or c == 2 end
function IsMonster(o, c) return (c or o:clsid()) == clsid.bloodsucker_s end
function IsWounded(o) return o.wounded == true end
function character_community(o) return o.comm end
function iempty_table(t) for k in pairs(t) do t[k] = nil end end
function size_table(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
function printdbg() end
function parse_list() return {} end
strformat = string.format
ranks = { get_obj_rank_name = function() return "novice" end }
state_mgr = {}
move, look = { stand = 1 }, { fire_point = 1 }
game_object = { enemy = 2 }
action_base = { execute = function() end }
xr_combat_ignore = { is_enemy = function() return true end }
utils_obj = {
	is_actor = function(_, c) return c == clsid.script_actor end,
	get_rank_list = function() return { "novice" } end,
	safe_bone_pos = function(o)
		local p = o:position()
		p.distance_to_xz = function(a, b) return math.abs(a.x - b.x) end
		p.sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
		return p
	end,
	get_sound = sound_object,
}
hit = setmetatable({ strike = 1, wound = 2 }, {
	__call = function() return { bone = function() end } end,
})
local config = { power = 100, k_actor = 3, k_stalker = 2, k_friend = 0.25, enable_vs_actor = true }
local stock_ini = ini_file
function ini_file(name)
	if name ~= "ai_tweaks\\xrs_facer.ltx" then return stock_ini(name) end
	return {
		section_exist = function() return true end,
		r_float_ex = function(_, _, k) return config[k] end,
		r_bool_ex = function(_, s, k, def)
			if s == "plugin" then return true end
			if k == "enable_vs_actor" or k == "enable_vs_stalker" then return config[k] == true end
			return def
		end,
	}
end
local function object(id, x, cls, comm)
	local _, o = spawn("stalker", vec3(x, 0, 0), nil, { id = id })
	o.clsid = function() return cls end
	o.comm = comm or "stalker"
	o.relation = function() return game_object.enemy end
	o.active_item = function() end
	o.best_enemy = function() end
	o.best_danger = function() end
	o.inactualize_patrol_path = function() end
	o.set_movement_type = function() end
	o.set_sight = function() end
	o.animation_count = function() return 1 end
	o.hit = function(self, h) self.hit_power = h.power end
	db.storage[id] = { object = o, ini_filename = "<customdata>" }
	return o
end

local actor = make_actor(vec3(30, 0, 0))
actor.clsid = function() return clsid.script_actor end
actor.hit = function(self, h) self.hit_power = h.power end
actor.comm = "stalker"
db.storage[0] = { object = actor }
local client = object(500, 8, clsid.script_stalker)
local other = object(501, 25, clsid.script_stalker)
local npc = object(600, 0, clsid.script_stalker, "army")
local stalker = object(601, 1, clsid.script_stalker)
local mutant = object(602, 1, clsid.bloodsucker_s)
local players, avatar, peer = coop.players, coop.avatar_of, coop.peer_of_avatar
coop.players = function()
	local list = players()
	if MODE == "host" then list[#list + 1] = { id = 2, avatar_id = 501 } end
	return list
end
coop.avatar_of = function(p) return p == 2 and 501 or avatar(p) end
coop.peer_of_avatar = function(id) return id == 501 and 2 or peer(id) end
coop.talk_recent = function(p, id) return p == 1 and id == npc:id() or p == 0 and id == npc:id() end

local sounds, tips = {}, {}
xr_sound.set_sound_play = function(_, name) sounds[#sounds + 1] = name end
news_manager.send_tip = function(o, message) tips[#tips + 1] = { o:id(), message } end
local clock = 1000
game.get_game_time = function()
	local now = clock
	return { time = now, diffSec = function(_, last) return now - last.time end }
end
utils_data = {
	CTime_to_table = function(t) return { time = t.time } end,
	CTime_from_table = function(t) return t end,
}
xr_conditions, xr_effects = {}, {}
debug_cmd_list = { command_get_list = function() return {} end }
modules = { stype_stalker = 1 }
game_relations = { is_factions_enemies = function(a, b) return a == "army" and b == "stalker" end }
local section_actor
xr_logic = {
	configure_schemes = function(o, _, file) db.storage[o:id()].ini_filename = file end,
	determine_section_to_activate = function(_, _, _, who)
		section_actor = who:id()
		return "remark@aim_bribe"
	end,
	activate_by_section = function(o, _, section) db.storage[o:id()].active_section = section end,
	restore_scheme_and_logic = function(o)
		db.storage[o:id()].active_section = nil
		db.storage[o:id()].ini_filename = "<customdata>"
	end,
}
function get_story_object_id() return db.actor:id() end

-- Use the actual active surrender action without booting the rest of the dialogue library.
local f = assert(io.open("temp/review/corpus/merged/dialogs.script", "r"))
local dialog = f:read("*a"):gsub("\r\n", "\n")
f:close()
local surrender = assert(dialog:match("(function surrender_victim_answers_2%b()[%s%S]-\nend)"))
stock("dialogs", assert(loadstring(surrender .. [[

	function who_is_npc(a, b) return a:id() == AC_ID and b or a end
]], "@dialogs.script")))
function alife_create_item() end
xr_wounded = { unlock_medkit = function() end }
game_statistics = { increment_statistic = function() end }
npc.iterate_inventory = function() end

stock("xrs_facer")
stock("axr_stalker_panic")
stock("xr_bribe")
stock("xr_remark")
for _, cb in ipairs({ "npc_on_update", "npc_on_hit_callback", "on_game_load" }) do AddScriptCallback(cb) end
start_all()
local function install_answers()
	return modes.install(coop_mode, mode, {
		where = function(p)
			if p == 2 and mode == "srv_map" then return "away" end
			return modes.set(mode).where(p)
		end,
	})
end
local answer_set = install_answers()
load_script("coop_trust")
xrs_facer.on_game_start()
xr_bribe.on_game_start()
if coop_npc_player_checks then coop_npc_player_checks.on_game_start() end

local function punch(target)
	local random = math.random
	local x = target._pos.x
	target._pos.x = 1
	math.random = function(_, b) return b or 1 end
	NOW = 100
	function load_var() return target:id() end
	xrs_facer.action_facer.execute({ object = npc, rank = "novice", end_time = 200, hit_time = 50 })
	math.random = random
	target._pos.x = x
	return target.hit_power
end

local function panic(target)
	npc.memory_visible_objects = function()
		local seen = false
		return function()
			if seen then return end
			seen = true
			return { object = function() return target end }
		end
	end
	local st = { memory = {}, target_id = 0 }
	local panicked = axr_stalker_panic.evaluator_stalker_panic.evaluate({ object = npc, st = st })
	return panicked, st.target_id
end

local function incoming_panic(t, src)
	local payload = coop_main.encode(t)
	deliver({ name = PANIC, payload = payload }, src)
end

if mode == "hostplay" or mode == "srv_map" then
	check(xrs_facer.check_enemy(client, npc) and not xrs_facer.check_enemy(stalker, npc),
		"facer enables the player through enable_vs_actor")
	config.enable_vs_actor, config.enable_vs_stalker = false, true
	xrs_facer.on_game_start()
	check(not xrs_facer.check_enemy(client, npc) and xrs_facer.check_enemy(stalker, npc),
		"facer never substitutes enable_vs_stalker for a player")
	check(math.abs(punch(client) - 2.5) < 1e-8 and math.abs(punch(stalker) - 100 * 2 / 120) < 1e-8,
		"facer uses k_actor for the client and k_stalker for an NPC")
	if mode == "srv_map" then check(not xrs_facer.check_enemy(actor, npc), "facer excludes the service actor") end

	local st = db.storage[npc:id()]
	st.panicked_to_actor = true
	check(panic(client), "the stock forced flag recognises a remote player")
	if mode == "srv_map" then
		check(not panic(actor), "the forced flag excludes the service actor")
		check(not panic(nil), "an empty visible list cannot keep the service actor as a panic target")
	end
	check(panic(mutant), "mutant panic still uses the stock rules")
	st.panicked_to_actor = nil
	client._pos.x = 2
	local req = { n = npc:id(), player = other:id() } -- the payload cannot choose who caused panic
	if mode == "srv_map" then req._peer = 1 end
	incoming_panic(req, mode == "srv_map" and 0 or 1)
	local yes, target = panic(client)
	check(yes and target == client:id() and not panic(other), "panic after dialogue is bound to the transport's player")
	if mode == "hostplay" then
		actor._pos.x = 2
		check(dialogs.surrender_victim_answers_2(actor, npc) == "st_surrender_victim_answer_6",
			"the co-op host receives the stock dialogue line")
		check(panic(actor) and not panic(client), "the local dialogue goes straight to the same decider")
		actor._pos.x = 30
	end
	incoming_panic({ n = 65535, _peer = mode == "srv_map" and 1 or nil }, mode == "srv_map" and 0 or 1)
	local trust = coop_trust.status().npc_player_checks_panic_id
	check(trust and trust.failed == 1,
		"an out-of-range dialogue NPC id goes through trust")
	incoming_panic({ n = other:id(), _peer = mode == "srv_map" and 1 or nil }, mode == "srv_map" and 0 or 1)
	local objects = coop_trust.status().npc_player_checks_panic_objects
	check(objects and objects.failed == 1 and db.storage[other:id()].panicked_to_actor == nil,
		"a player ID in the NPC field goes through trust without changing that player's state")

	client._pos.x = 8
	if mode == "srv_map" then
		actor._pos.x, other._pos.x = 1, 6 -- closer than the client, but neither belongs to this map
		check(axr_main.count("npc_on_update") == 0, "the empty map copy registers no bribe update")
		local data = {}
		xr_bribe.save_state(data)
		data.bribe.army = { distance = 25, duration = 86400, start = { time = clock } }
		SendScriptCallback("actor_on_update")
		check(axr_main.count("npc_on_update") == 1, "arrival of the truce table registers the map callback")
	else
		xr_bribe.set_bribe("army", 25, 86400)
		other._pos.x = 10
	end
	SendScriptCallback("npc_on_update", npc)
	local _, sent_warning = sent(WARNING)
	check(sent_warning and sent_warning.target == 1 and #tips == 0, "bribe warning goes only to the approaching client")
	check(section_actor == client:id() and st.active_section == "remark@aim_bribe",
		"the bribe warning scheme starts with the approaching client")
	local _, remark_target = xr_remark.init_target(npc, "story|actor")
	check(remark_target == client:id(), "the warning animation looks at the same client")
	actor._pos.x = 50
	if mode == "hostplay" then other._pos.x = 7 end
	check(not xr_conditions.bribes_dist_to_actor_check(actor, npc), "the warning stays active while that client is close")
	client._pos.x = 30
	check(xr_conditions.bribes_dist_to_actor_check(actor, npc), "that client can leave the warning scheme")
	xr_effects.bribes_reset_scheme(actor, npc)
	check(st.active_section == nil, "stock bribe scheme reset still runs")
elseif mode == "none" then
	check(xrs_facer.check_enemy(actor, npc) and not xrs_facer.check_enemy(client, npc),
		"single-player facer keeps stock eligibility")
	check(math.abs(punch(actor) - 2.5) < 1e-8 and math.abs(punch(client) - 100 * 2 / 120) < 1e-8,
		"single-player melee keeps the stock coefficients")
	dialogs.surrender_victim_answers_2(actor, npc)
	check(panic(actor) and not panic(client) and panic(mutant), "single-player panic is unchanged")
	actor._pos.x = 8
	xr_bribe.set_bribe("army", 25, 86400)
	SendScriptCallback("npc_on_update", npc)
	check(#tips == 1 and tips[1][1] == 0 and section_actor == 0 and #SENT == 0,
		"single-player bribe logic warns the actor directly")
else
	incoming_panic({ n = npc:id(), _peer = 2 }, 1)
	local forwarded, event = sent(PANIC)
	check(event and event.target == answer_set.bridge and forwarded._peer == 1,
		"the world forwards the dialogue to the map with the authenticated peer")
	local data = {}
	xr_bribe.save_state(data)
	data.bribe.army = { distance = 25, duration = 86400, start = { time = clock } }
	SendScriptCallback("actor_on_update")
	check(axr_main.count("npc_on_update") == 0, "the world never registers an NPC update for a truce")

	MODE, SELF = "client", 1
	modes.install(coop_mode, "hostplay", {
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
	})
	dialogs.surrender_victim_answers_2(actor, npc)
	local requested, request = sent(PANIC)
	check(request and request.target == 0 and requested.n == npc:id(), "the mirror sends its dialogue NPC to the decider")
	local warning = { name = WARNING, payload = coop_main.encode({ c = "army" }) }
	deliver(warning, 2)
	check(#tips == 0, "another player cannot send a bribe warning")
	deliver(warning, 0)
	check(#tips == 1 and tips[1][1] == 0 and tips[1][2]:find("army", 1, true),
		"the addressed mirror shows the stock warning")
end

done("NPC player checks (" .. mode .. ")")
