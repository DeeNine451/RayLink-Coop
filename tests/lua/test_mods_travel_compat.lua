-- Dev 57 G15-4: exercise the active GAMMA scripts at their public entry points.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local function load_mod(mod)
	local file = "temp/review/corpus/merged/" .. mod .. ".script"
	local chunk = loadfile(file)
	if not chunk then
		file = "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/" .. mod .. ".script"
		chunk = assert(loadfile(file))
	end
	local env = setmetatable({}, { __index = _G })
	_G[mod] = env
	setfenv(chunk, env)()
	return env
end

local level_name, clock, weather, fades, changes = "l01_escape", 0, 0, 0, 0
local takes_time, party, deny, broken, flat = false, true, false, false, true
local surge, psi = {}, {}
level.name = function() return level_name end
level.vertex_id = function() return 7 end
level.change_game_time = function(d, h, m) clock = clock + d * 1440 + h * 60 + m end
level.add_pp_effector = function() fades = fades + 1 end
level.map_has_object_spot = function() return 0 end
level.map_add_object_spot_ser = function() end
coop_settings = { rule = function(key)
	if key == "economy/travel_takes_time" then return takes_time end
	if key == "economy/party_fast_travel" then return party end
end }
surge_manager = { get_surge_manager = function() return surge end }
psi_storm_manager = { get_psi_storm_manager = function() return psi end }
level_weathers = { get_weather_manager = function()
	return { forced_weather_change = function() weather = weather + 1 end }
end }
ui_inventory = { UIInventory = { Name_Custom = function() end, Action_Custom = function() end } }
trader_autoinject = { update = function() end }
campfire_placeable_mcm = { get_config = function() return false end }
function hide_hud_inventory() end
function hide_hud_all() end
function SYS_GetParam(_, _, _, default) return default end
function random_float() return 1 end
function str_explode(s)
	local t = {}
	for part in s:gmatch("[^,]+") do t[#t + 1] = part end
	return t
end
VEC_ZERO = vec3(0, 0, 0)
ini_sys.section_for_each = function() end
xr_conditions = {}
xr_logic = {
	parse_condlist = function(_, _, _, value) return value end,
	pick_section_from_condlist = function(actor, _, rule)
		if rule == "gate" then return deny and "false" or "true" end
		actor.applied = (actor.applied or 0) + 1
	end,
}
local actor = make_actor()
local _, remote = spawn("actor", vec3(1, 0, 0), nil, { id = PROXY })
local _, other = spawn("actor", vec3(50, 0, 0), nil, { id = PROXY + 1 })
local stock_players, stock_avatar = coop.players, coop.avatar_of
local other_here = name == "srv_map"
coop.players = function()
	local players = stock_players()
	if name == "srv_map" then players[#players + 1] = { id = 2, avatar_id = other:id(), elsewhere = not other_here } end
	return players
end
coop.avatar_of = function(peer) return peer == 2 and other:id() or stock_avatar(peer) end
local function actor_capabilities(a)
	a.set_actor_direction = function(self, h) self.heading = h end
	a.set_actor_position = function(self, p)
		if broken then error("position setter failed") end
		self._pos = vector():set(p)
	end
	a.direction = function()
		local dir = vec3(1, 0, 0)
		dir.mul = function(v, n) return vec3(v.x * n, v.y * n, v.z * n) end
		return dir
	end
	a.position = function(self)
		local p = vector():set(self._pos)
		p.add = function(v, d) return vec3(v.x + d.x, v.y + d.y, v.z + d.z) end
		return p
	end
	a.eat = function(_, item) alife_release(item) end
	a.is_talking = function() return false end
end
actor_capabilities(actor)
actor_capabilities(remote)

local _, gate = spawn("test_extra_transition", vec3(0, 0, 0))
local _, cross = spawn("test_extra_transition_cross", vec3(0, 0, 0))
game_graph = function() return { vertex = function(_, id)
	return { level_id = function() return id == 42 and 2 or 1 end }
end } end
local sim = alife()
function sim:actor() return SE[0] end
function sim:create(...) return alife_create(...) end
function alife() return sim end
function get_story_se_item(sec) return sec == gate:section() and SE[gate:id()] or SE[cross:id()] end
function TeleportObject() end
utils_obj = { play_sound = function() end }
utils_stpk = { get_anom_zone_data = function() return { shapes = {} } end, set_anom_zone_data = function() end }
lc_extra_transitions_mcm = { op = { gr = { { id = "enable_time_advance", def = true } } } }

local cp = load_mod("campfire_placeable")
cp.is_flat_surface = function() return flat end
local lc = load_mod("lc_extra_transitions")
lc.lc_pool[gate:section()] = { to_pos = "100,0,0", to_gvid = "8", pos = "0,0,0", gvid = "8", spot = "gate",
	precondition = "gate", on_teleport = "effect" }
lc.lc_pool[cross:section()] = { to_pos = "200,0,0", to_gvid = "42", pos = "0,0,0", gvid = "8", spot = "gate",
	on_teleport = "effect" }
local tips = {}
local stock_translate = game.translate_string
game.translate_string = function(id)
	if id == "st_coop_core_go_host_only" then return "Localized group move refusal" end
	return stock_translate(id)
end
news_manager.send_tip = function(_, text) tips[#tips + 1] = text end
local shown, latest_dialog
Frect = function() return { set = function(self) return self end } end
strformat = string.format
ui_events = {}
function super() end
CUIScriptWnd = { SetWndRect = function() end, SetAutoDelete = function() end, Register = function() end, AddCallback = function() end }
function class(key)
	local env = getfenv(2)
	return function(base)
		local cls = setmetatable({}, { __index = base, __call = function(def)
			local obj = setmetatable({}, { __index = def })
			obj:__init()
			latest_dialog = obj
			return obj
		end })
		env[key] = cls
	end
end
function CUIMessageBoxEx()
	return { InitMessageBox = function() end, SetText = function() end,
		ShowDialog = function() shown = level.object_by_id(latest_dialog.obj_id) end }
end
load_mod("lc_extra_transitions_ui")

-- Use the real router's rule for the callback source. The stock client timer is dropped.
local create_event = CreateTimeEvent
function CreateTimeEvent(ev, act, sec, f, ...)
	local domain = coop.route.of("time_event", f)
	if coop.route.runs(domain) then return create_event(ev, act, sec, f, ...) end
end
local function finish_change()
	changes = changes + 1
	return true
end
function ChangeLevel(pos, vid, gid, dir, anim)
	if anim then return CreateTimeEvent(0, "delay_travel", 3, finish_change) end
	return finish_change()
end
local function tick(ms)
	run_time_events(ms)
	SendScriptCallback("actor_on_update")
end

AddScriptCallback("actor_on_item_use")
cp.on_game_start()
lc.on_game_start()
start_all()
coop_economy_group.on_game_start()
coop_economy_travel.on_game_start()
load_script("coop_hostplay_travel").on_game_start()
local file = io.open("gamedata/scripts/coop_mods_travel_compat.script", "r")
if file then
	file:close()
	load_script("coop_mods_travel_compat").on_game_start()
end

local function set_role(role)
	MODE, SELF = "host", 0
	coop.is_map_server = function() return role == "srv_map" end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.levels = { split = function() return role:find("^srv") ~= nil end }
	if role == "none" then MODE = "sp" end
	if role == "client" or role == "srv_client" then
		MODE, SELF = "client", 1
		modes.live(coop_mode, load_script)
	else
		local overrides = role == "srv_map" and {
			where = function(peer) return (peer == 1 or peer == 2 and other_here) and "here" or "away" end,
			decider = function(peer) return (peer == 1 or peer == 2 and other_here) and "this" or "other" end,
		} or nil
		modes.install(coop_mode, role, overrides)
	end
end

local function chop_and_prepare()
	local before, created = clock, #CREATED
	local _, axe = spawn("wpn_axe", actor:position(), actor:id())
	cp.gather_wood(axe)
	cp.prepare_campfire()
	if name == "none" then
		check(clock > before, "m30:2 SP keeps stock chopping and preparation time")
	else
		check(clock == before, "m30:2 " .. MODE .. " chopping and preparation skip no time")
	end
	check(#CREATED == created + 2 and axe:condition() < 1, "m30:2 the same chop produces the fire and wears the axe once")
end

local request, result, prompt = "mods.g15_lc_req", "mods.g15_lc_result", "mods.g15_lc_prompt"
local function event(verb, data, from)
	deliver({ name = verb, payload = coop_main.encode(data) }, from)
end
local function move_phase()
	tick(3100)
end
local function answer_latest(authority_role)
	local _, req = sent(request)
	if not req then return end
	set_role(authority_role)
	if authority_role == "srv_map" then
		local data = coop_main.decode(req.payload)
		data._peer = 1
		event(request, data, 0)
	else
		deliver(req, 1)
	end
	local _, answer = sent(result)
	set_role(authority_role == "srv_map" and "srv_client" or "client")
	if answer then deliver(answer, 0) end
end

set_role(name)
if name == "hostplay" then
	chop_and_prepare()
	lc.teleport_actor(actor, gate)
	move_phase()
	check(actor._pos.x == 100, "m31:4 Co-op host moves to the extra transition destination")
	check(sent_count("economy.tp") == 1, "m31:4 the group receives the travel offer")
	local _, group_offer = sent("economy.tp")
	if group_offer then
		set_role("client")
		actor._pos = vec3(0, 0, 0)
		local accept
		ui_dyn_msg_box = { msg_box_ui = function(_, _, _, yes)
			accept = yes
			return {}
		end }
		deliver(group_offer, 0)
		check(accept and actor._pos.x == 0, "m31:4 a group offer waits for the other player's choice")
		if accept then accept() end
		check(math.abs(actor._pos.x - 100) <= 0.5, "m31:4 accepting the offer moves the other player")
		set_role("hostplay")
	end
	check(clock == 0 and weather == 0 and not surge.time_forwarded and not psi.time_forwarded,
		"m31:4 disabled travel time skips the whole clock, surge, psi and weather block")
	actor._pos = vec3(0, 0, 0)
	takes_time = true
	lc.teleport_actor(actor, gate)
	move_phase()
	check(clock > 0 and weather == 1 and surge.time_forwarded and psi.time_forwarded,
		"m31:4 enabled group travel applies clock and managers once")
	actor._pos = vec3(0, 0, 0)
	party = false
	local before_clock = clock
	lc.teleport_actor(actor, gate)
	move_phase()
	check(actor._pos.x == 100 and sent_count("economy.tp") == 2 and clock == before_clock and weather == 1,
		"m31:4 solo travel leaves the other players and the clock alone")
	party = true

	set_role("client")
	actor._pos = vec3(0, 0, 0)
	chop_and_prepare()
	local before = #RELEASED
	local _, fire = spawn("itm_campfire", actor:position(), actor:id())
	flat = false
	SendScriptCallback("actor_on_item_use", fire)
	check(sent("mods.cf_place") == nil and #RELEASED == before and sent_count("economy.propose") == 0,
		"m30:2 refused placement spends no item and opens no skip vote")
	flat = true
	SendScriptCallback("actor_on_item_use", fire)
	tick(2100)
	local _, place = sent("mods.cf_place")
	check(place and SE[fire:id()] ~= nil, "m30:2 client placement keeps the fire item until the decider places it")
	if place then
		set_role("hostplay")
		SE[fire:id()].parent_id = remote:id()
		local created = #CREATED
		deliver(place, 1)
		deliver(place, 1)
		check(SE[fire:id()] == nil and #CREATED == created + 1, "m30:2 the decider places and spends the client's fire item once")
		set_role("client")
	end
	takes_time = false
	deny = true
	lc.teleport_actor(actor, gate)
	answer_latest("hostplay")
	move_phase()
	check(actor._pos.x == 0, "m31:5 a refusal never moves the client")
	deny = false
	lc.teleport_actor(actor, gate)
	answer_latest("hostplay")
	move_phase()
	check(actor._pos.x == 100 and remote._pos.x == 1, "m31:5 refusal releases the lock and the owner moves on retry")
	actor._pos = vec3(0, 0, 0)
	lc.teleport_actor(actor, gate)
	NOW = NOW + 11000
	answer_latest("hostplay")
	move_phase()
	check(actor._pos.x == 0, "m31:5 an approval after the wait expired cannot move the owner")

	local requests, effects, before_fades, before_tips = sent_count(request), remote.applied, fades, #tips
	lc.teleport_actor(actor, cross)
	check(sent_count(request) == requests, "#444 cross-map refusal happens before an authorization request")
	check(#tips == before_tips + 1 and tips[#tips] == "Localized group move refusal",
		"#444 the client sees the translated host-only tip")
	if sent_count(request) > requests then answer_latest("hostplay") end
	move_phase()
	check(changes == 0 and remote.applied == effects and fades == before_fades,
		"#444 the cross-map refusal prevents movement, transition effects and fade")

	set_role("hostplay")
	local before_changes, host_tips = changes, #tips
	lc.teleport_actor(actor, cross)
	move_phase()
	check(changes == before_changes + 1 and #tips == host_tips, "#444 the host can still use the cross-map extra transition")
elseif name == "srv_map" then
	actor._pos = vec3(50, 0, 0)
	check(xr_conditions.is_actor_inside_lc(actor, gate), "m31:5 transition detects the player next to it on a map server")
	lc.handle_nearby_actor(actor, gate)
	local _, offer = sent(prompt)
	check(offer and offer.target == 1 and shown == nil, "m31:5 map server addresses the dialog to the player, not its ghost")
	set_role("srv_client")
	actor._pos = vec3(0, 0, 0)
	if offer then deliver(offer, 0) end
	check(shown == gate, "m31:5 the server player's machine shows its own transition dialog")
	chop_and_prepare()
	takes_time = true
	deny = true
	if latest_dialog then latest_dialog:OnMsgOk() else lc.teleport_actor(actor, gate) end
	answer_latest("srv_map")
	move_phase()
	check(actor._pos.x == 0 and remote.applied == nil, "m31:5 map server refusal applies neither the move nor the condition effect")

	deny, broken = false, true
	lc.teleport_actor(actor, gate)
	answer_latest("srv_map")
	local ok = pcall(move_phase)
	check(ok and actor._pos.x == 0, "m31:5 owner movement errors are contained")
	broken = false
	lc.teleport_actor(actor, gate)
	answer_latest("srv_map")
	move_phase()
	check(actor._pos.x == 100 and remote._pos.x == 1, "m31:5 server client retries after a movement error and moves its own actor")
	check(clock == 0 and weather == 0 and sent_count("economy.tp") == 0 and other._pos.x == 50,
		"m31:4 server travel never applies shared clock or offers")

	actor._pos = vec3(0, 0, 0)
	local before_effects = remote.applied
	lc.teleport_actor(actor, cross)
	answer_latest("srv_map")
	move_phase()
	check(changes == 1 and remote.applied == before_effects + 1 and #tips == 0,
		"m31:5 the server player's cross-map trip keeps its effects and issues the move after the same delay")
	set_role("srv_map")
	other_here = false
	local before_effect = remote.applied
	local t = { i = gate:id(), t = 12, _peer = 2 }
	event(request, t, 0)
	local verdict, reply = sent(result)
	check(verdict and verdict.ok == false and reply.target == 2 and remote.applied == before_effect,
		"m31:5 requests from a player of another map cannot affect this map")
	local before_created = #CREATED
	get_story_se_item = function() return nil end
	SendScriptCallback("actor_on_first_update")
	check(#CREATED == before_created, "m31:5 map servers do not create copies of the world transitions")
elseif name == "srv_world" then
	event(request, { i = gate:id(), t = 11 }, 1)
	local t, out = sent(request)
	check(out and out.target == 0x101 and t._peer == 1 and not sent(result),
		"m31:5 world server forwards the transport sender and leaves object decisions to the map")
	check(clock == 0 and actor._pos.x == 0 and remote.applied == nil, "world server touches neither clock nor player's map")
	local before_created = #CREATED
	get_story_se_item = function() return nil end
	SendScriptCallback("actor_on_first_update")
	check(#CREATED == before_created + 2, "m31:5 the world authority creates the configured transitions")
else
	chop_and_prepare()
	lc.teleport_actor(actor, gate)
	move_phase()
	check(actor._pos.x == 100 and clock > 0 and weather == 1, "m31:4 SP retains stock travel time, weather and movement")
	check(not sent(request) and not sent("economy.tp"), "SP sends no co-op events")
end
done("mods_travel_compat " .. name)
