-- Dev 57 G15-3. NTA callback and task fixtures follow the active GAMMA scripts.
local modes = dofile("tests/lua/support/modes.lua")
local role = modes.names()[1]
MODE = role == "none" and "sp" or (role == "srv_map" and "client" or "host")
dofile("tests/lua/support/stubs_mods.lua")

local host = make_actor(vec3(80, 0, 0))
local _, shooter = spawn("coop_player_avatar", vec3(2, 0, 0), nil, { id = 500 })
local _, second = spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 600 })
local here = { [1] = true, [2] = true }
local self_peer = role == "srv_map" and 257 or 0
coop.self_id = function() return self_peer end
coop.is_map_server = function() return role == "srv_map" end
coop.is_dedicated = function() return role == "srv_world" end
coop.to_host_id = function(id) return id end
coop.to_local_id = coop.to_host_id
local seats = { { id = 1, avatar_id = 500 }, { id = 2, avatar_id = 600 } }
if role == "hostplay" then table.insert(seats, 1, { id = 0, avatar_id = 0, is_self = true }) end
coop.players = function() return seats end
coop.avatar_of = function(peer)
	for _, seat in ipairs(seats) do if seat.id == peer then return seat.avatar_id end end
end
coop.peer_of_avatar = function(id)
	for _, seat in ipairs(seats) do if seat.avatar_id == id then return seat.id end end
end

local current_map = role == "srv_world" and "l01_escape" or "l03_agroprom"
level.name = function() return current_map end
local goodwill, disguise, tips, blows = {}, {}, {}, 0
local actor_profiles = {
	[0] = { name = "Host", rank = 20, visual = "host.ogf", weapon = "wpn_host" },
	[500] = { name = "Shooter", rank = 300, visual = "shooter.ogf", weapon = "wpn_shooter" },
	[600] = { name = "Second", rank = 1000, visual = "second.ogf", weapon = "wpn_second" },
}
local GO, SE_METHODS = getmetatable(host), getmetatable(SE[0])
function GO:character_community() return "actor_stalker" end
character_community = GO.character_community
function GO:set_community_goodwill(faction, value) relation_registry.set_community_goodwill(faction, self:id(), value) end
function GO:active_item() return self._active_item end
function GO:get_visual_name() return self._visual or "unknown.ogf" end
function GO:set_visual_name(name) self._visual = name .. ".ogf" end
function SE_METHODS:community() return "actor_stalker" end
function SE_METHODS:rank() return self._rank end
function SE_METHODS:character_name() return self._name end
function SE_METHODS:set_rank(rank) self._rank = rank end
function SE_METHODS:set_character_name(name) self._name = name end
function str_explode(s, _) return { s:match("^[^.]+") } end
for id, profile in pairs(actor_profiles) do
	local _, gun = spawn(profile.weapon, vec3(0, 0, 0), id, { kind = "weapon" })
	OBJ[id]._visual, OBJ[id]._active_item = profile.visual, gun
	SE[id]._rank, SE[id]._name = profile.rank, profile.name
end
local sim = alife()
sim.actor = function() return SE[0] end
alife = function() return sim end

relation_registry = {
	community_relation = function() return 0 end,
	community_goodwill = function(_, id) return goodwill[id] or 0 end,
	set_community_goodwill = function(_, id, value) goodwill[id] = value end,
}
game_relations = { ENEMIES = -1000 }
gameplay_disguise = {
	set_comm = function() disguise[db.actor:id()] = (disguise[db.actor:id()] or 0) + 1 end,
	get_default_comm = function() return "stalker" end,
}
dynamic_news_helper = { send_tip = function() tips[db.actor:id()] = true end }
AC_ID = 0

local hit_cb, choose_cb = "physic_object_on_hit_callback", "npc_on_choose_weapon"
AddScriptCallback(hit_cb)
AddScriptCallback(choose_cb)
AddScriptCallback("npc_on_update")
AddScriptCallback("npc_on_net_destroy")
task_status_functor = {}
nta_utils = {
	levels = { agroprom = "l03_agroprom", zaton = "zaton" },
	actor_on_level = function(name) return level.name() == name end,
	is_melee = function() return false end,
}
if role ~= "none" then
	dofile("tests/lua/support/mod_source.lua")
	local utils = GAMMA_DIR .. "/nta_utils.script"
	assert(mod_chunk(utils, { "function spawn_at_position(" }, "nta_utils", "return true"))
	nta_utils.find_random_stalker = function() return { id = shooter:id() } end
end
local local_squad, remote_squad
if role == "srv_map" or role == "srv_world" then
	local_squad = spawn("bandit_defence_squad_novice", vec3(1, 0, 0))
	remote_squad = spawn("bandit_defence_squad_novice", vec3(1, 0, 0))
	xr_effects, task_functor = {}, {}
	a_tab_utils = { rand_with_exclusion = function() return 1 end }
	function SE_METHODS:create_npc() end
	function SE_METHODS:squad_members() return function() end end
	local script = assert(loadfile(GAMMA_DIR .. "/tasks_hold_the_ground.script"))
	tasks_hold_the_ground = setmetatable({}, { __index = _G })
	setfenv(script, tasks_hold_the_ground)()
end
local sky_state = {}
local _, heli = spawn("new_tasks_addon_heli_strong_static", vec3(0, 0, 0))
if role ~= "srv_map" then sky_state.static_heli_id = heli:id() end
tasks_skyfall = from_script("tasks_skyfall", [[
	return function(state, patched, blew)
		local hits = 0
		local m = {}
		function m.is_enemies_with_military()
			return relation_registry.community_goodwill("army", AC_ID) <= game_relations.ENEMIES
		end
		function m.blow_cover()
			gameplay_disguise.set_comm(gameplay_disguise.get_default_comm())
			dynamic_news_helper.send_tip("skyfall_cover_blow_message")
			db.actor:set_community_goodwill("army", -3000)
		end
		function m.blow_static_heli() blew(); state.static_heli_id = nil end
		function m.physic_object_on_hit_callback(obj, _, _, who)
			if obj:id() ~= state.static_heli_id then return end
			if who:section() == "actor" or (patched and coop.peer_of_avatar(who:id())) then
				CreateTimeEvent(0, "counting_hits", 0.1, function()
					if hits > 15 then m.blow_static_heli() end
					if not m.is_enemies_with_military() then m.blow_cover() end
					hits = 0
					return true
				end)
				hits = hits + 1
			end
			if who:section() == "rpg_new_blow" or who:section() == "ied_new_blow" then m.blow_static_heli() end
		end
		return m
	end
]])(sky_state, role ~= "none", function() blows = blows + 1 end)

local mirage_state = { enemy_ids = {} }
mirage_configs = { teleport_activator_center_point = vec3(0, 0, 0), teleport_activation_distance = 20 }
tasks_mirage = from_script("tasks_mirage", [[
	return function(state)
		local m = {}
		function m.is_mirage(npc) return npc and npc:section() == "mirage_stalker" end
		function m.actor_holds_valid_item()
			local item = db.actor:active_item()
			return item and IsWeapon(item) and not nta_utils.is_melee(item)
		end
		function m.get_actor_visual() return str_explode(db.actor:get_visual_name(), "%.")[1] end
		function m.update_mirages_visual()
			for _, id in ipairs(state.enemy_ids) do
				local npc = level.object_by_id(id)
				if m.is_mirage(npc) then npc:set_visual_name(m.get_actor_visual()) end
			end
		end
		function m.give_mirages_weapon()
			local sec = m.actor_holds_valid_item() and db.actor:active_item():section() or "wpn_pkp"
			for _, id in ipairs(state.enemy_ids) do
				local npc = level.object_by_id(id)
				if m.is_mirage(npc) and not npc:object(sec) then alife_create_item(sec, npc) end
			end
		end
		function m.npc_on_choose_weapon(npc, _, flags)
			for _, id in ipairs(state.enemy_ids) do
				if id == npc:id() and m.is_mirage(npc) then
					local sec = m.actor_holds_valid_item() and db.actor:active_item():section() or "wpn_pkp"
					local gun = npc:object(sec)
					if gun then flags.gun_id = gun:id() end
				end
			end
		end
		function m.spawn_mirages(spots)
			for _, spot in ipairs(spots) do
				local npc = alife_create(spot.section, spot.vector)
				local actor_se = alife():actor()
				npc:set_rank(actor_se:rank())
				npc:set_character_name(actor_se:character_name())
				table.insert(state.enemy_ids, npc.id)
			end
		end
		return m
	end
]])(mirage_state)
task_status_functor.mirage_task_status_functor = function(tsk)
	if tsk.stage == 0 and db.actor:position().x == 2 then
		tasks_mirage.spawn_mirages({ { section = "mirage_stalker", vector = vec3(2, 0, 0) } })
		tsk.stage = 1
	elseif tsk.stage == 1 then
		tasks_mirage.update_mirages_visual()
		tasks_mirage.give_mirages_weapon()
	end
end

local far = {}
nta_utils.actor_in_range = function(pos, dist)
	return db.actor:position():distance_to_sqr(pos) < dist * dist
end
if role == "srv_world" then
	far[500], far[600] = shooter, second
	OBJ[500], OBJ[600], OBJ[heli:id()] = nil, nil, nil
end
coop_quests_core = {
	at_home = function(f, ...) return f(...) end,
	with_level_of = function(_, f, ...) return f(...) end,
	far_body = function(_, id) return far[id] end,
}

load_script("coop_main").on_game_start()
load_script("coop_mode")
modes.install(coop_mode, role, role == "srv_map" and {
	where = function(peer) return here[peer] and "here" or "away" end,
	decider = function(peer) return here[peer] and "this" or "other" end,
	writes = function(id) return id == local_squad.id end,
} or role == "srv_world" and { writes = function(id) return id == local_squad.id end } or nil)
load_script("coop_mods_core").on_game_start()
local nta = load_script("coop_mods_nta")
nta.on_game_start()
RegisterScriptCallback(hit_cb, tasks_skyfall.physic_object_on_hit_callback)
RegisterScriptCallback(choose_cb, tasks_mirage.npc_on_choose_weapon)
load_script("coop_npc_relations").on_game_start() -- G13-2 also wraps the registered Skyfall handler.
SendScriptCallback("actor_on_first_update")

local function hit(who) SendScriptCallback(hit_cb, heli, 1, nil, who, 0) end
local function choose(npc)
	local flags = {}
	SendScriptCallback(choose_cb, npc, nil, flags)
	return flags.gun_id and OBJ[flags.gun_id]:section()
end

if role == "hostplay" then
	print("== m19:2 Skyfall: the timer penalizes and sends cover removal only to the shooter")
	hit(shooter)
	check(goodwill[500] == nil, "no penalty before the stock hit window")
	run_time_events(100)
	check(goodwill[500] == -3000 and goodwill[0] == nil and goodwill[600] == nil, "the shooter alone lost Army goodwill")
	local msg, raw = sent("mods.nta_sky_cover")
	check(msg and msg.c == 500 and raw.target == 1 and next(disguise) == nil, "only the shooter's machine gets the cover order")
	if raw then
		local hid = coop.to_host_id
		MODE = "client"
		deliver(raw, 0)
		check(next(disguise) == nil, "another character ignores the owner's cover order")
		coop.to_host_id = function(id) return id == 0 and 500 or hid(id) end
		deliver(raw, 2)
		check(next(disguise) == nil, "a player's packet cannot remove someone else's cover")
		deliver(raw, 0)
		MODE = "host"
		coop.to_host_id = hid
	end
	check(disguise[0] == 1 and tips[0], "the cover and warning are handled by the receiving player's own actor")
	print("== m19:2 Skyfall: shared explosion threshold and both shooters, without penalizing a replacement")
	goodwill[500] = nil
	for _ = 1, 8 do hit(shooter); hit(second) end
	seats[2].avatar_id = 700 -- the first shooter no longer owns this peer seat
	run_time_events(100)
	check(blows == 1 and goodwill[500] == -3000 and goodwill[600] == -3000, "one blast and the original characters penalized")
	local _, latest = sent("mods.nta_sky_cover")
	check(sent_count("mods.nta_sky_cover") == 2 and latest and latest.target == 2, "no cover removal addressed to the replacement")
	seats[2].avatar_id = 500
elseif role == "srv_map" then
	print("== m19:2 Skyfall: only a hit on the led map reports a fact to the world server")
	here[2] = false
	hit(second)
	run_time_events(100)
	check(#SENT == 0, "an off-map character cannot be a shooter here")
	hit(shooter)
	run_time_events(100)
	local msg, raw = sent("mods.nta_sky_hit")
	check(msg and msg.c == 500 and msg.o == heli:id() and raw.target == 0, "the map reports the physical hit and shooter")
	check(next(goodwill) == nil and next(disguise) == nil, "the map did not apply a world or owner effect")
elseif role == "srv_world" then
	print("== m19:2 Skyfall: only the map's fact can reach the world penalty")
	hit(shooter)
	run_time_events(100)
	check(next(goodwill) == nil, "the process without the map cannot judge its physics callback")
	local payload = coop_main.encode({ c = 500, o = heli:id() })
	coop_main.on_event("mods.nta_sky_hit", payload, 1)
	local trust = coop_trust.status().nta_sky_hit
	check(next(goodwill) == nil and trust and trust.checked == 1 and trust.failed == 1, "a player cannot stand in for a map server in trust log mode")
	coop_main.on_event("mods.nta_sky_hit", coop_main.encode({ c = 500, o = 65535 }), 257)
	check(next(goodwill) == nil, "an out-of-range helicopter id cannot report a hit")
	coop_main.on_event("mods.nta_sky_hit", payload, 257)
	check(goodwill[500] == -3000 and goodwill[0] == nil and goodwill[600] == nil, "the world applied the fact to the named character")
	local msg, raw = sent("mods.nta_sky_cover")
	check(msg and msg.c == 500 and raw.target == 1, "world routes cover removal to that player")
	coop_main.on_event("mods.nta_sky_hit", payload, 257)
	check(sent_count("mods.nta_sky_cover") == 1, "the same hit cannot expose an already hostile character twice")
else
	print("== single player: the installed Skyfall callback behaves as stock")
	hit(host)
	run_time_events(100)
	check(goodwill[0] == -3000 and disguise[0] == 1 and tips[0] and #SENT == 0, "stock cover and goodwill apply locally")
end

if role ~= "srv_world" then current_map = "zaton" end
if role == "hostplay" or role == "srv_world" then
	if role == "srv_world" then
		local is_active = coop.is_active
		coop.is_active = function() return false end
		check(nta_utils.actor_in_range(host:position(), 1), "before hosting, NTA range checks use the stock actor")
		coop.is_active = is_active
	end
	print("== m19:9 Mirage: a client's wave takes rank and name from that pass's server object")
	local tsk = { stage = 0 }
	task_status_functor.mirage_task_status_functor(tsk, "mirage")
	local mirage = OBJ[mirage_state.enemy_ids[1]]
	local se = mirage and SE[mirage:id()]
	check(tsk.stage == 1 and se and se:rank() == 300 and se:character_name() == "Shooter", "wave uses Shooter even with a closer Second")
	check(db.actor == host, "the actor context is restored")
	if role == "hostplay" and mirage then
		print("== m19:8 Mirage: clothing, issued gun and selection use the nearest single sample")
		spawn("wpn_host", vec3(0, 0, 0), mirage:id())
		task_status_functor.mirage_task_status_functor(tsk, "mirage")
		SendScriptCallback("npc_on_update", mirage)
		check(mirage:get_visual_name() == "second.ogf" and mirage:object("wpn_second"), "appearance and issue copy Second")
		check(choose(mirage) == "wpn_second", "selection uses Second even with the host's gun in the inventory")
		second._pos = vec3(30, 0, 0)
		local n = #CREATED
		check(choose(mirage) == "wpn_second" and mirage:get_visual_name() == "second.ogf" and #CREATED == n,
			"weapon selection uses the applied sample when a player moves between callbacks")
		SendScriptCallback("npc_on_update", mirage)
		check(choose(mirage) == "wpn_shooter" and mirage:get_visual_name() == "shooter.ogf",
			"the next map update replaces appearance and weapon choice together")
		SendScriptCallback("npc_on_net_destroy", mirage)
		check(choose(mirage) == nil, "a streaming-out mirage clears its copy before the id can be reused")
	elseif mirage then
		check(choose(mirage) == nil, "the world server does not choose a stalker's gun without the map")
	end
elseif role == "srv_map" then
	print("== m19:8 Mirage: a map server samples its own players and local mirages")
	local _, mirage = spawn("mirage_stalker", vec3(2, 0, 0))
	spawn("wpn_host", vec3(0, 0, 0), mirage:id())
	SendScriptCallback("npc_on_update", mirage)
	check(mirage:get_visual_name() == "shooter.ogf" and mirage:object("wpn_shooter"), "the map issues and copies Shooter, with Second on another map")
	check(choose(mirage) == "wpn_shooter", "the local weapon callback uses the same map sample without a mirrored task table")
	here[2] = true
	SendScriptCallback("npc_on_update", mirage)
	check(mirage:get_visual_name() == "second.ogf" and mirage:object("wpn_second") and choose(mirage) == "wpn_second", "on the same map, the nearer Second is the sample for all three effects")
	second._active_item = nil
	SendScriptCallback("npc_on_update", mirage)
	local n = #CREATED
	check(choose(mirage) == "wpn_pkp" and #CREATED == n, "switching to empty hands uses the stock fallback without issuing a duplicate")
else
	print("== single player: Mirage uses the stock actor and callbacks")
	tasks_mirage.spawn_mirages({ { section = "mirage_stalker", vector = vec3(2, 0, 0) } })
	local id = mirage_state.enemy_ids[1]
	local mirage = OBJ[id]
	tasks_mirage.update_mirages_visual()
	tasks_mirage.give_mirages_weapon()
	check(SE[id]:rank() == 20 and SE[id]:character_name() == "Host", "stock rank and name")
	check(mirage:get_visual_name() == "host.ogf" and choose(mirage) == "wpn_host", "stock appearance, issue and choice")
end

if role == "hostplay" or role == "srv_map" then
	local count = #CREATED
	local id = nta_utils.spawn_at_position("stalker", vec3(1, 0, 0), 1, 8)
	check(type(id) == "number" and SE[id] and #CREATED == count + 1, role .. ": NTA spawn returns its local object ID")
	local stalker = nta_utils.find_random_stalker()
	check(stalker and stalker.id == shooter:id(), role .. ": NTA can query its local stalker simulation")

	if role == "hostplay" then
		MODE = "client"
		modes.live(coop_mode, load_script)
		count = #CREATED
		check(nta_utils.spawn_at_position("stalker", vec3(1, 0, 0), 1, 8) == nil and #CREATED == count,
			"co-op player mirror cannot spawn an NTA NPC")
		check(nta_utils.find_random_stalker() == nil, "co-op player mirror cannot query the stalker simulation")
	end
end

if role == "srv_world" or role == "srv_map" then
	local effect = xr_effects.on_flea_market_defense_squad_death
	if role == "srv_world" then
		local count = #CREATED
		local ok, err = pcall(effect, db.actor, remote_squad)
		local saved = {}
		tasks_hold_the_ground.save_state(saved)
		check(ok and #CREATED == count and saved.hold_the_ground_task_data.killed_squads == 1,
			"world server: replaying a map-held squad's death counts it without duplicating the wave: " .. tostring(err))
	end
	local count = #CREATED
	local ok, err = pcall(effect, db.actor, local_squad)
	local wave = CREATED[count + 1]
	check(ok and #CREATED == count + 1 and wave and wave.sec == "bandit_defence_squad_novice"
		and SE[wave.id].rush_to_target == true, role .. ": one local squad death spawns one rushing wave: " .. tostring(err))
end

done("NTA scenes " .. role)
