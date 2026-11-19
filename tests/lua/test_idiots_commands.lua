-- G12-4 (m21:2): Useful Idiots' wheel (idiots_ui :663, :682, :727) and keys (idiots_keybinds :268, :277) call its NPC
-- library on the player's machine, where the companions are copies: a state, a reload mode, a look or an away order changed
-- nothing the AI reads. The commands of one wheel button or key event go to the decider of the player's level, which checks
-- each companion, runs each command once and answers with the state the player's copy then shows. The co-op host's own
-- commands and single player stay the mod's. The real idiots_ui / idiots_keybinds (corpus) run over a small NPC library
-- with the mod's state rules (info portions on the companion).
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function stock(name)
	local sources = { "temp/review/corpus/merged", os.getenv("GAMMA_SCRIPTS") }
	for _, path in ipairs(sources) do
		local chunk = loadfile(path .. "/" .. name .. ".script")
		if chunk then
			local env = setmetatable({}, { __index = _G })
			setfenv(chunk, env)()
			return env
		end
	end
	error("Useful Idiots script missing from corpus and GAMMA_SCRIPTS: " .. name)
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
	return out
end
dup_table = copy
function table.keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	return keys
end

-- luabind's class "Name" (Base) for idiots_ui
CUIScriptWnd = {}
function super() end
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base }) end
end

local INFO, owners, calls, visible = {}, {}, {}, {}

-- The NPC library: the mod's state rules (a state is an info portion of the companion; a cycle group has one action on).
local NPC = { SELECTED_IDS = {}, LOOT_SHARED_ITEMS = {}, LOOT_SHARING_NPCS = {} }
NPC.ACTIONS = {
	{ name = "movement", cycle = true, actions = {
		{ name = "follow", next = "wait", default = true }, { name = "wait", next = "cover", info = "npcx_beh_wait" },
		{ name = "cover", next = "follow", info = "npcx_beh_hide_in_cover" } } },
	{ name = "speed", toggle = true, actions = { { name = "hurry", info = "npcx_beh_hurry" } } },
	{ name = "distance", cycle = true, actions = {
		{ name = "near", next = "normal", info = "npcx_beh_distance_near" }, { name = "normal", next = "far", default = true },
		{ name = "far", next = "near", info = "npcx_beh_distance_far" } } },
	{ name = "combat", cycle = true, actions = {
		{ name = "default", next = "guard", default = true }, { name = "guard", next = "default", info = "npcx_beh_combat_tactics_guard" } } },
	{ name = "readiness", cycle = true, actions = {
		{ name = "attack", next = "defend", default = true }, { name = "defend", next = "ignore", info = "npcx_beh_ignore_actor_enemies" },
		{ name = "ignore", next = "attack", info = "npcx_beh_ignore_combat" } } },
	{ name = "jobs", toggle = true, actions = { { name = "loot_items", info = "npcx_beh_gather_items" } } },
}
NPC.ACTIONS_KEYED, NPC.DEFAULT_STATE = {}, {}
for _, g in ipairs(NPC.ACTIONS) do
	local keyed = { name = g.name, cycle = g.cycle, toggle = g.toggle, actions = {} }
	NPC.DEFAULT_STATE[g.name] = {}
	for _, a in ipairs(g.actions) do
		keyed.actions[a.name] = a
		NPC.DEFAULT_STATE[g.name][a.name] = a.default or false
	end
	NPC.ACTIONS_KEYED[g.name] = keyed
end
NPC.GLOBAL_STATE = copy(NPC.DEFAULT_STATE)

local function has(o, info) return INFO[o:id()] ~= nil and INFO[o:id()][info] == true end
local function id_of(o) return type(o) == "number" and o or o:id() end
function NPC.get(id) return level.object_by_id(id) end
function NPC.isCompanion(o)
	if type(o) == "number" then o = NPC.get(o) end
	return o ~= nil and o:alive() and has(o, "npcx_is_companion")
end
function NPC.getCompanion(id) local o = NPC.get(id) return NPC.isCompanion(o) and o or nil end
function NPC.getCompanions() return visible end
function NPC.getTargetCompanion() end
function NPC.getBlockingCompanions() return visible end
function NPC.isStateful(g, a) return g ~= nil and a ~= nil and NPC.DEFAULT_STATE[g] ~= nil and NPC.DEFAULT_STATE[g][a] ~= nil end
function NPC.getState(o, g, a)
	if not NPC.isStateful(g, a) then return end
	if not o then return NPC.GLOBAL_STATE[g][a] end
	if type(o) == "number" then o = NPC.getCompanion(o) end
	if not o then return end
	local info = NPC.ACTIONS_KEYED[g].actions[a].info
	if info then return has(o, info) end
	if not NPC.ACTIONS_KEYED[g].cycle then return false end
	for _, other in pairs(NPC.ACTIONS_KEYED[g].actions) do
		if other.info and has(o, other.info) then return false end
	end
	return true
end
local function put(o, g, a, v)
	if not o then NPC.GLOBAL_STATE[g][a] = v return end
	local info = NPC.ACTIONS_KEYED[g].actions[a].info
	if info then
		if v then o:give_info_portion(info) else o:disable_info_portion(info) end
	end
end
function NPC.setState(o, g, a, v)
	if o ~= nil then calls[#calls + 1] = { f = "state", id = id_of(o), g = g, a = a, v = v } end
	if not NPC.isStateful(g, a) or v == NPC.getState(o, g, a) then return end
	if type(o) == "number" then o = NPC.getCompanion(o) end
	if not NPC.ACTIONS_KEYED[g].cycle then
		if o then SendScriptCallback("idiots_on_state_change", o:id(), g, a, v) end
		put(o, g, a, v)
	elseif v then
		if o then SendScriptCallback("idiots_on_state_change", o:id(), g, a, v) end
		for other in pairs(NPC.ACTIONS_KEYED[g].actions) do put(o, g, other, other == a) end
	end
	if not o then
		for _, c in ipairs(NPC.getCompanions()) do NPC.setState(c, g, a, v) end
	end
end
function NPC.setStates(o, states)
	for g, actions in pairs(states) do
		for a, v in pairs(actions) do NPC.setState(o, g, a, v) end
	end
end
function NPC.getActiveState(o, g)
	if not (NPC.ACTIONS_KEYED[g] and NPC.ACTIONS_KEYED[g].cycle) then return end
	for a in pairs(NPC.ACTIONS_KEYED[g].actions) do
		if NPC.getState(o, g, a) then return a end
	end
end
function NPC.cycleActiveState(o, g)
	local active = NPC.getActiveState(o, g)
	local nxt = active and NPC.ACTIONS_KEYED[g].actions[active].next
	if nxt then
		NPC.setState(o, g, nxt, true)
		return nxt
	end
end
function NPC.toggleState(o, g, a)
	if not NPC.isStateful(g, a) then return end
	local v = true
	if NPC.ACTIONS_KEYED[g].toggle then v = not NPC.getState(o, g, a) end
	if v ~= NPC.getState(o, g, a) then
		NPC.setState(o, g, a, v)
		return v
	end
end
function NPC.getAllStates(o)
	local out = {}
	for g, actions in pairs(NPC.DEFAULT_STATE) do
		out[g] = {}
		for a in pairs(actions) do out[g][a] = NPC.getState(o, g, a) end
	end
	return out
end
-- AI data in the companion's db.storage (read by the decider's combat and beh schemes only)
function NPC.setReloadModes(o, w, e)
	calls[#calls + 1] = { f = "reload", id = o:id(), w = w, e = e }
	db.storage[o:id()].IDIOTS_RELOAD = { wmode = w or 0, emode = e or 0 }
end
function NPC.lookAtPoint(o, pos)
	calls[#calls + 1] = { f = "look", id = o:id(), x = pos.x }
	local st = db.storage[o:id()]
	if st.enemy then st.combat.lookPoint = pos else st.beh.lookPoint = pos end
end
function NPC.moveOutOfTheWay(o)
	calls[#calls + 1] = { f = "away", id = o:id(), actor = db.actor:id() }
	db.storage[o:id()].beh.movePoint = 77
end
function NPC.moveToPoint(o) calls[#calls + 1] = { f = "move", id = o:id() } end

package.loaded["illish.lib.npc"] = NPC
package.loaded["illish.lib.table"] = { merge = function(a, b)
	for k, v in pairs(b) do a[k] = v end
	return a
end }
package.loaded["illish.lib.beh"] = {
	saveStorage = function() end, loadStorage = function() end, getAllWaypoints = function() return {} end,
}
package.loaded["illish.lib.weapon"] = { RELOAD_ACTIVE = 0, RELOAD_ALL = 1, EMPTY = 0, HALF_EMPTY = 1, NOT_FULL = 2 }
package.loaded["illish.lib.util"] = {
	throttle = function(f) return f end, timePlus = function() return 0 end, timeExpired = function() return true end,
}
a_idiots_config = { DATA_KEY = "USEFUL_IDIOTS", DATA_VER = "1.0", DATA_STALE_KEYS = {} }

local KEYS = { move = 42, reload = 43, retreat = 44, look = 46, away = 47 }
local opts = { ["idiots/options/artifacts"] = true, ["idiots/keybinds/movement/cycle_movement_key"] = 45,
	["idiots/keybinds/movement/cycle_movement_mode"] = 0 }
for name, key in pairs(KEYS) do
	opts["idiots/keybinds/point/" .. name .. "_key"] = key
	opts["idiots/keybinds/point/" .. name .. "_mode"] = 0
end
ui_mcm = {
	get = function(key) return opts[key] end,
	get_mod_key = function() return true end,
	key_hold = function() return false end,
	double_tap = function() return false end,
}
level.get_target_pos = function() return vec3(12, 4, 8) end
particles_object = function() return {} end
save_var = function() end
local shouts = 0
axr_companions = { companion_squads = {}, UIWheelCompanion = {},
	actors_command = function() shouts = shouts + 1 end } -- VAR: the "actor" shouts an order
axr_task_manager = { hostages_by_id = {} }
AddScriptCallback("on_key_hold")
AddScriptCallback("on_key_release")
AddScriptCallback("npc_on_net_spawn")
AddScriptCallback("mcm_option_change")
AddScriptCallback("idiots_on_state_change")
-- illish.patches.axr_companions' legacy setters: VAR speaks an order there (host-routed in the game)
RegisterScriptCallback("idiots_on_state_change", function() axr_companions.actors_command("order") end)

idiots_ui = stock("idiots_ui")
a_idiots_mdata = stock("a_idiots_mdata")
idiots_keybinds = stock("idiots_keybinds")
idiots_keybinds.showMessage = function() end
idiots_keybinds.playParticle = function() end

coop_npc_companions = { owner_character = function(o) return o and owners[o:id()] end }
coop_npc_players = {
	send = function(name, t, target) return coop.send_event(name, coop_main.encode(t), target) end,
}

local function companion(id, owner, pos)
	local _, o = spawn("stalker", pos or vec3(5, 0, 0), nil, { id = id })
	INFO[id] = { npcx_is_companion = true }
	o.has_info = function(self, i) return INFO[self:id()][i] == true end
	o.give_info_portion = function(self, i) INFO[self:id()][i] = true end
	o.disable_info_portion = function(self, i) INFO[self:id()][i] = nil end
	owners[id] = owner
	db.storage[id] = { object = o, beh = {} }
	return o
end

-- the decider's answer: one digit per info-bearing action, in the order of NPC.ACTIONS
local function bits(id, on)
	local out = {}
	for _, g in ipairs(NPC.ACTIONS) do
		for _, a in ipairs(g.actions) do
			if a.info then
				local v
				if on then v = on[a.info] else v = INFO[id][a.info] end
				out[#out + 1] = v and "1" or "0"
			end
		end
	end
	return table.concat(out)
end
local function hit(verb, t, from)
	NOW = NOW + 1000 -- the decider's rate bucket refills
	coop_main.on_event("mods." .. verb, coop_main.encode(t), from)
end
local function count(f, id)
	local n = 0
	for _, c in ipairs(calls) do
		if c.f == f and (id == nil or c.id == id) then n = n + 1 end
	end
	return n
end
local function rows_of(t)
	local out = {}
	for row in tostring(t and t.c or ""):gmatch("[^|]+") do out[#out + 1] = row end
	return out
end
local function key(dik) SendScriptCallback("on_key_press", dik) end
local wheel = function(gui, group, action) return idiots_ui.UIWheelCompanion.OnClickButton(gui, group, action) end
local function trust(name, field) return (coop_trust.status()[name] or {})[field or "failed"] or 0 end
local RETREAT = { "movement,follow,1", "readiness,ignore,1", "speed,hurry,1", "distance,near,1" }
local function retreat_rows(id)
	local out = {}
	for i, r in ipairs(RETREAT) do out[i] = "s," .. id .. "," .. r end
	return table.concat(out, "|")
end

local function target_error(set, from, peer)
	local owner_character = coop_npc_companions.owner_character
	coop_npc_companions.owner_character = function(obj)
		if obj:id() == 201 then error("target lookup failed") end
		return owner_character(obj)
	end
	SENT, calls = {}, {}
	local before = shouts
	hit("idiots_cmd", { c = "s,201,speed,hurry,1|s,202,movement,wait,1", _peer = peer }, from)
	coop_npc_companions.owner_character = owner_character
	local t, s = sent("mods.idiots_state")
	check(count("state", 201) == 0 and count("state", 202) == 1 and INFO[202].npcx_beh_wait
		and t and s.target == peer and t.s == "202:" .. bits(202),
		"G12-4b [" .. set .. "] a target lookup error skips its row and the next row runs and is answered")
	check(shouts == before, "G12-4b [" .. set .. "] the surviving remote order is quiet")
	axr_companions.actors_command("order")
	check(shouts == before + 1, "G12-4b [" .. set .. "] the target error does not mute the next local shout")
end

local REFUSED_ROWS = "s,201,jobs,loot_items,1|s,202,jobs,loot_items,1|a,201|a,999"

local function rejected_answer(set, reason, peer)
	local t, s = sent("mods.idiots_state")
	check(sent_count("mods.idiots_state") == 1 and s.target == peer
		and t.s == "201:" .. bits(201) .. "|202:" .. bits(202),
		"G12-4b [" .. set .. "] " .. reason .. " sends each named local companion's true state once, just to the sender")
	check(#calls == 0 and not INFO[201].npcx_beh_gather_items and not INFO[202].npcx_beh_gather_items,
		"G12-4b [" .. set .. "] " .. reason .. " applies none of the refused commands")
end

local function missing_avatar(set, from, peer)
	local avatar_of = coop.avatar_of
	coop.avatar_of = function(p) if p ~= peer then return avatar_of(p) end end
	SENT, calls = {}, {}
	hit("idiots_cmd", { c = REFUSED_ROWS, _peer = peer }, from)
	coop.avatar_of = avatar_of
	rejected_answer(set, "missing avatar", peer)
end

local function limited_command()
	local payload = coop_main.encode({ c = "s,202,movement,wait,1" })
	NOW = NOW + 3000 -- refill the bucket once, then spend its burst at one timestamp
	for _ = 1, 8 do coop_main.on_event("mods.idiots_cmd", payload, 1) end
	SENT, calls = {}, {}
	coop_main.on_event("mods.idiots_cmd", coop_main.encode({ c = REFUSED_ROWS }), 1)
end

-- A player's machine (a co-op client or a server player): the commands of one button / key event go out as one request.
local function player_machine(facade, set, overrides)
	MODE, SELF = "client", 1
	modes.install(facade, set, overrides)
	SENT = {}
	calls = {}
	local first, second = level.object_by_id(201), level.object_by_id(202)
	visible, NPC.SELECTED_IDS = { first, second }, { [201] = true }
	INFO[201] = { npcx_is_companion = true, npcx_beh_wait = true }
	key(KEYS.retreat)
	local t, s = sent("mods.idiots_cmd")
	check(sent_count("mods.idiots_cmd") == 1 and s.target == 0 and t.c == retreat_rows(201),
		"m21:2 [" .. set .. "] the retreat key (idiots_keybinds :277) sends its four state commands in one request")
	check(INFO[201].npcx_beh_ignore_combat and not INFO[201].npcx_beh_wait,
		"m21:2 [" .. set .. "] the player's copy shows the order at once, as in single player")
	return t
end

for _, mode in ipairs(modes.names()) do
	MODE = mode == "none" and "sp" or "host"
	SELF = 0
	SENT, calls = {}, {}
	local facade = load_script("coop_mode")
	modes.install(facade, mode)
	coop.is_host = function() return MODE == "host" and mode ~= "srv_map" end
	coop.is_map_server = function() return mode == "srv_map" end
	coop.is_dedicated = function() return mode == "srv_world" end
	coop.levels = {
		split = function() return mode == "srv_world" or mode == "srv_map" end,
		map_servers = function() return { { bridge = 0x101, level = 4 } } end,
	}
	make_actor()
	spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500 })
	local own = companion(101, 0)
	local first, second = companion(201, 500), companion(202, 500)
	local far = companion(301, 600, vec3(100, 0, 0))
	local near = companion(302, 600, vec3(3, 0, 0))
	visible = { own }
	a_idiots_mdata.on_game_start()
	idiots_keybinds.on_game_start()
	load_script("coop_main")
	local adapter = load_script("coop_npc_idiots")
	adapter.on_game_start()
	alife_storage_manager.CALifeStorageManager_load({})
	coop_trust.reset_for_test(nil)

	if mode == "hostplay" then
		-- the co-op host decides for a client's command
		hit("idiots_cmd", { c = "s,201,movement,wait,1|s,201,speed,hurry,1" }, 1)
		local t, s = sent("mods.idiots_state")
		check(count("state", 201) == 2 and INFO[201].npcx_beh_wait and INFO[201].npcx_beh_hurry,
			"m21:2 a client's state commands run once each on the co-op host's companion")
		check(t and s.target == 1 and t.s == "201:" .. bits(201), "m21:2 the client is answered with the companion's state")
		check(sent_count("mods.idiots_cmd") == 0, "m21:2 the decider never forwards the commands it runs")
		hit("idiots_cmd", { c = "m,201,1,2|l,201,12.000,4.000,8.000|a,201" }, 1)
		check(db.storage[201].IDIOTS_RELOAD and db.storage[201].IDIOTS_RELOAD.wmode == 1
			and db.storage[201].IDIOTS_RELOAD.emode == 2, "m21:2 the reload mode (:268, :682) is set where the AI reads it")
		check(db.storage[201].beh.lookPoint and db.storage[201].beh.lookPoint.x == 12, "m21:2 the look order reaches the decider")
		check(count("away", 201) == 1 and calls[#calls].actor == 500,
			"m21:2 the away order runs with the sender's character as the actor")
		check(shouts == 0, "m21:2 a client's order is not shouted by the co-op host's own character (VAR)")

		-- companion checks
		calls = {}
		hit("idiots_cmd", { c = "s,302,movement,wait,1" }, 1)
		check(INFO[302].npcx_beh_wait and trust("idiots_cmd_owner") == 0,
			"m21:2 an order to another player's companion next to the sender is the group's (owner 2026-11-01)")
		hit("idiots_cmd", { c = "s,301,movement,wait,1" }, 1)
		check(trust("idiots_cmd_owner") == 1 and INFO[301].npcx_beh_wait,
			"m21:2 a far foreign companion: the new check logs 'would refuse' and lets it through")
		coop_trust.reset_for_test({ default = "log", idiots_cmd_owner = "refuse" })
		INFO[301].npcx_beh_wait = nil
		SENT = {}
		hit("idiots_cmd", { c = "s,301,movement,wait,1" }, 1)
		t = sent("mods.idiots_state")
		check(not INFO[301].npcx_beh_wait and trust("idiots_cmd_owner", "refused") == 1 and t and t.s == "301:" .. bits(301),
			"m21:2 refused (refuse mode): the companion is untouched and its true state goes back to the sender")
		coop_trust.reset_for_test(nil)
		calls = {}
		INFO[101].npcx_is_companion = nil
		hit("idiots_cmd", { c = "s,101,movement,wait,1|s,999,movement,wait,1" }, 1)
		INFO[101].npcx_is_companion = true
		check(count("state") == 0 and trust("idiots_cmd_target") == 2, "m21:2 a non-companion or unknown id is no target")
		local target_log = log_has("idiots_cmd_target")
		check(trust("idiots_cmd_target", "guard") == true and target_log and target_log:find("(dropped,", 1, true),
			"G12-4b [hostplay] the bad target is logged as a data guard drop")
		for _, bad in ipairs({ "s,201,movement,wait,2", "s,201,movement,fly,1", "x,201", "l,201,1e9,0,0", "m,201,7,0",
			"s,0,movement,wait,1", "s,201,movement,wait,1|", string.rep("a,201|", 300) .. "a,201" }) do
			hit("idiots_cmd", { c = bad }, 1)
		end
		hit("idiots_cmd", { c = 7 }, 1)
		check(count("state") == 0 and count("away") == 0 and trust("idiots_cmd_args") == 9,
			"m21:2 a malformed list, an unknown state, a bad number or too many rows is refused whole")

		-- the co-op host's own wheel and keys: the mod's own path
		SENT, calls = {}, {}
		INFO[101].npcx_beh_wait = true
		key(KEYS.retreat)
		key(KEYS.reload)
		wheel({ ID = 101 }, "jobs", "loot_items")
		check(INFO[101].npcx_beh_ignore_combat and INFO[101].npcx_beh_gather_items and db.storage[101].IDIOTS_RELOAD
			and sent_count("mods.idiots_cmd") == 0, "m21:2 the co-op host's own wheel and keys run the library directly")
		check(shouts > 0, "m21:2 the host's own order is still shouted (VAR)")

		-- a client's machine
		local retreat = player_machine(facade, "hostplay", {
			leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end, decider = function() return "other" end,
		})
		SENT = {}
		visible, NPC.SELECTED_IDS = { first, second }, {}
		key(KEYS.reload)
		local t = sent("mods.idiots_cmd")
		check(sent_count("mods.idiots_cmd") == 1 and t.c == "m,201,0,2|m,202,0,2" and count("reload") == 0,
			"m21:2 the reload key (:268) asks the decider for each companion, nothing is set on the copy")
		SENT = {}
		NPC.SELECTED_IDS = { [201] = true }
		key(KEYS.look)
		key(KEYS.away)
		check(sent_count("mods.idiots_cmd") == 2 and #rows_of(sent("mods.idiots_cmd")) == 2
			and count("look") == 0 and count("away") == 0, "m21:2 look and away orders go to the decider only")
		SENT = {}
		INFO[201].npcx_beh_gather_items = nil
		wheel({ ID = 201 }, "jobs", "loot_items")
		t = sent("mods.idiots_cmd")
		check(t and t.c == "s,201,jobs,loot_items,1", "m21:2 a wheel toggle (:663) sends the state it shows")
		wheel({ ID = 201 }, nil, "reload")
		t = sent("mods.idiots_cmd")
		check(t and t.c == "m,201,0,2", "m21:2 the wheel's reload (:682) is sent")
		wheel({ ID = 201 }, nil, "retreat")
		t = sent("mods.idiots_cmd")
		check(sent_count("mods.idiots_cmd") == 3 and t.c == retreat_rows(201), "m21:2 the wheel's retreat (:727) is one request")
		SENT = {}
		NPC.GLOBAL_STATE.movement = { follow = false, wait = true, cover = false }
		visible = { first, second }
		wheel({}, nil, "retreat")
		local rows, seen, dup = rows_of(sent("mods.idiots_cmd")), {}, false
		for _, r in ipairs(rows) do
			if seen[r] then dup = true end
			seen[r] = true
		end
		check(sent_count("mods.idiots_cmd") == 1 and #rows == 8 and not dup and seen["s,202,movement,follow,1"]
			and sent_count("mods.idiots_template") >= 1,
			"m21:2 'all companions' sends each companion's command once; the template keeps its own request (G12-2)")
		SENT = {}
		key(KEYS.move)
		check(sent_count("mods.idiots_point") == 1 and sent_count("mods.idiots_cmd") == 0,
			"m21:2 the point key (adapted by G12-2) is not forwarded a second time")
		calls = {}
		key(45)
		t = sent("mods.idiots_cmd")
		check(t and #rows_of(t) == 1 and rows_of(t)[1]:match("^s,201,movement,"), "m21:2 a cycle key sends the next state")

		-- the answer corrects the copy; only the transport's peer 0 may send it
		INFO[201] = { npcx_is_companion = true, npcx_beh_hurry = true }
		hit("idiots_state", { s = "201:" .. bits(201, { npcx_beh_wait = true }) }, 0)
		check(INFO[201].npcx_beh_wait and not INFO[201].npcx_beh_hurry and NPC.getState(first, "movement", "wait"),
			"m21:2 the decider's answer sets the copy's state")
		hit("idiots_state", { s = "201:" .. bits(201, { npcx_beh_hurry = true }) }, 1)
		hit("idiots_state", { s = "201:0101" }, 0)
		hit("idiots_state", { s = "201:" .. bits(201, {}):gsub("0", "2") }, 0)
		check(INFO[201].npcx_beh_wait and not INFO[201].npcx_beh_hurry,
			"m21:2 an answer from a player, of the wrong length or with bad digits changes nothing")

		-- the client's real request on the host: every command runs once
		MODE, SELF = "host", 0
		modes.install(facade, "hostplay")
		SENT, calls = {}, {}
		INFO[201] = { npcx_is_companion = true, npcx_beh_wait = true }
		hit("idiots_cmd", retreat, 1)
		check(count("state", 201) == 4 and count("state") == 4 and INFO[201].npcx_beh_ignore_combat
			and INFO[201].npcx_beh_distance_near and not INFO[201].npcx_beh_wait and sent_count("mods.idiots_cmd") == 0,
			"m21:2 the client's retreat runs each of its commands exactly once on the decider")
		target_error(mode, 1, 1)
		missing_avatar(mode, 1, 1)
		limited_command()
		rejected_answer(mode, "rate limit", 1)
		SENT = {}
		coop_main.on_event("mods.idiots_cmd", coop_main.encode({ c = "a,201|ignored" }), 1)
		check(sent_count("mods.idiots_state") == 0, "G12-4b [hostplay] a rate-limited malformed list gets no state")
	elseif mode == "srv_map" then
		local t = { c = "s,201,movement,wait,1|s,401,movement,wait,1", _peer = 1 }
		hit("idiots_cmd", t, 0)
		local a, s = sent("mods.idiots_state")
		check(INFO[201].npcx_beh_wait and count("state", 201) == 1 and trust("idiots_cmd_target") == 1,
			"m21:2 the map server runs the player's command; a companion not on its map is no target")
		check(trust("idiots_cmd_target", "guard") == true, "G12-4b [srv_map] an absent map target is a data guard drop")
		check(a and s.target == 1 and a.s == "201:" .. bits(201), "m21:2 the map server answers the transport's player")
		hit("idiots_cmd", { c = "a,201", _peer = 1 }, 0)
		check(count("away", 201) == 1 and calls[#calls].actor == 500, "m21:2 the map server runs away as that player's character")
		target_error(mode, 0, 1)
		missing_avatar(mode, 0, 1)
		player_machine(facade, "srv_map", {
			leads_here = function() return false end, is_player_mirror = function() return true end,
			actor_is_player = function() return true end, decider = function() return "other" end,
		})
	elseif mode == "srv_world" then
		hit("idiots_cmd", { c = retreat_rows(201) }, 1)
		local t, s = sent("mods.idiots_cmd")
		check(t and s.target == 0x101 and t._peer == 1 and t.c == retreat_rows(201) and #calls == 0,
			"m21:2 the world server (no map) passes the command to the map server of the player's level")
		limited_command()
		check(#calls == 0 and sent_count("mods.idiots_cmd") == 0 and sent_count("mods.idiots_state") == 0,
			"G12-4b [srv_world] a limited request is not relayed and no state is invented without the player's map")
	else
		INFO[101].npcx_beh_wait = true
		key(KEYS.retreat)
		key(KEYS.reload)
		wheel({ ID = 101 }, "jobs", "loot_items")
		wheel({ ID = 101 }, nil, "reload")
		check(INFO[101].npcx_beh_ignore_combat and INFO[101].npcx_beh_gather_items and count("reload", 101) == 2
			and db.storage[101].IDIOTS_RELOAD and #SENT == 0, "single player: the wheel and the keys are the mod's own")
	end
end

done("idiots_commands")
