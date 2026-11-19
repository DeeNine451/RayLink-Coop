-- G16-3, Dev 57: run the real ALQ publisher and dialog consumer, not a copied filter.
-- Co-op: the host has the objects and inventory. Server: the map process has the
-- objects; the world server owns the state. Supply parcel state directly to the
-- map publisher here. Delivering it there and to the client is m18:1.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function source_path(name)
	local corpus = "temp/review/corpus/merged/" .. name .. ".script"
	if have_file(corpus) then return corpus end
	local stand = "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/" .. name .. ".script"
	assert(have_file(stand), "real ALQ source required: " .. name)
	return stand
end

local function load_mod(name)
	local path = source_path(name)
	local fh = assert(io.open(path, "rb"))
	local src = fh:read("*a")
	fh:close()
	local env = setmetatable({}, { __index = _G })
	rawset(_G, name, env)
	local chunk = assert(loadstring(src, "@" .. path))
	setfenv(chunk, env)
	chunk()
	return env
end

load_script("coop_mods_core")
load_script("coop_mode")
-- Before the adapter exists this runs the unpatched publisher, so RED is a
-- missing trader snapshot rather than a missing-file/runtime error.
if have_file("gamedata/scripts/coop_mods_alq.script") then load_script("coop_mods_alq") end

IsTrader = function(obj) return obj and obj._kind == "trader" end
get_object_squad = function() return nil end
dialogs = { who_is_npc = function(_, npc) return npc end }
alq_mcm = { get_config = function() return true end }
character_community = function() return nil end

local stub_players = coop.players
coop.is_client = function() return MODE == "client" or MODE == "map" end

local function setup(role)
	local engine_modes = { hostplay = "host", srv_world = "host", srv_map = "map", none = "sp", client = "client" }
	MODE, SELF = engine_modes[role], role == "srv_map" and 0x101 or role == "client" and 1 or 0
	coop.is_map_server = function() return role == "srv_map" end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.players = function()
		if role == "srv_world" or role == "srv_map" then
			return { { id = 1, avatar_id = 500, is_self = false } }
		end
		return stub_players()
	end
	SE, OBJ = {}, {}
	make_actor()
	spawn("player", vec3(0, 0, 0), nil, { id = 500, kind = "stalker" })
	local _, trader = spawn("trader", vec3(1, 0, 0), nil, { id = 100, kind = "trader" })
	spawn("stalker", vec3(2, 0, 0), nil, { id = 101, kind = "stalker" })
	spawn("dead_trader", vec3(3, 0, 0), nil, { id = 102, kind = "trader", alive = false })
	spawn("monster", vec3(4, 0, 0), nil, { id = 103, kind = "monster" })
	spawn("far_trader", vec3(21, 0, 0), nil, { id = 104, kind = "trader" })
	spawn("parcel", nil, 500, { id = 200 })
	alq_core = { courier_packages = { [200] = { client_id = 100, reward = 2400 } } }
	-- Give every candidate dialog data, so exclusion cannot pass just because
	-- host_snapshot happened to return nil for a player/dead/distant object.
	for i, recipient in ipairs({ 0, 500, 101, 102, 103, 104 }) do
		spawn("parcel", nil, 500, { id = 200 + i })
		alq_core.courier_packages[200 + i] = { client_id = recipient, reward = 1200 }
	end
	alq_player = { resend_spots = function() end }
	assert(mod_chunk(source_path("alq_player"), {
		"local function net(", "local function change_goodwill(",
		"function parcel_for(", "function parcel_reward(", "function hand_parcel(",
	}, "alq_player", "return true"))
	local values, handlers, writes = {}, {}, 0
	local request, rewards = nil, {}
	coop.money_grant = function(peer, amount)
		rewards[#rewards + 1] = { peer = peer, amount = amount }
		return true
	end
	coop.sync = {
		keys = function(scope) return values[scope] or {} end,
		set = function(scope, key, value)
			values[scope] = values[scope] or {}
			values[scope][key] = value
			writes = writes + 1
			return true
		end,
		get = function(scope, key)
			local own = values["player:" .. SELF]
			if scope == "player" and own then return own[key] end
		end,
		on = function() return true end,
		handler = function(name, fn) handlers[name] = fn; return true end,
		request = function(name, payload) request = { name = name, payload = payload }; return true end,
		near = function(peer, id, dist)
			local player, npc = OBJ[500], OBJ[id]
			return peer == 1 and npc and player:position():distance_to_sqr(npc:position()) <= dist * dist
		end,
		broadcast = function() return true end,
	}
	local compat = load_mod("coop_compat_alq")
	local dialog = load_mod("alq_dialogs")
	local publish = assert(coop_mods_core.find_local(compat, "publish_for"))
	local original_env = getfenv(publish)
	-- A second consumer of the mod namespace must retain its original predicate.
	local unrelated = assert(loadstring("return function(o) return IsStalker(o) end"))
	setfenv(unrelated, original_env)
	unrelated = unrelated()
	local adapter = rawget(_G, "coop_mods_alq")
	if adapter then adapter.on_game_start() end
	compat.on_game_start()
	local tick = assert(coop_mods_core.find_local(compat, "actor_on_update"))
	return {
		compat = compat, dialog = dialog, trader = trader, publish = publish,
		values = values, handlers = handlers, writes = function() return writes end, tick = tick,
		request = function() return request end, rewards = rewards,
		unrelated = unrelated,
	}
end

local function check_publication(role, s, publish)
	NOW = NOW + 2000
	publish()
	local snap = s.values["player:1"] or {}
	check(snap["alq.n.100"] and snap["alq.n.100"].parcel == 2400,
		role .. ": trader_published_with_parcel")
	check(snap["alq.n.0"] == nil and snap["alq.n.500"] == nil,
		role .. ": player_character_never_published")
	check(snap["alq.n.101"] and snap["alq.n.101"].parcel == 1200,
		role .. ": stalker_still_published")
	check(snap["alq.n.102"] == nil and snap["alq.n.103"] == nil and snap["alq.n.104"] == nil,
		role .. ": dead_non_npc_and_distant_objects_excluded")
	check(not IsStalker(s.trader) and not s.unrelated(s.trader),
		role .. ": predicate_change_is_local_to_publication")
	if role == "hostplay" then
		MODE, SELF = "client", 1
		check(s.dialog.pre_client(db.actor, s.trader) == true, "hostplay: client_sees_trader_handover_reply")
		MODE, SELF = "host", 0
	end
	local writes = s.writes()
	NOW = NOW + 2000
	publish()
	check(s.writes() == writes, role .. ": unchanged_snapshot_not_republished")
	OBJ[100]._alive = false
	NOW = NOW + 2000
	publish()
	check(snap["alq.n.100"] == nil, role .. ": dead_trader_snapshot_removed")
	-- Even if a player character has the newly admitted class, exclude it.
	OBJ[500]._kind = "trader"
	NOW = NOW + 2000
	publish()
	check(snap["alq.n.500"] == nil, role .. ": trader_class_player_never_published")
end

local function check_handover()
	local s = setup("hostplay")
	NOW = NOW + 2000
	s.tick()
	MODE, SELF = "client", 1
	s.dialog.act_client(db.actor, s.trader)
	MODE, SELF = "host", 0
	local req = s.request()
	local handler = req and s.handlers[req.name]
	local ok, amount
	if handler then ok, amount = handler(1, req.payload) end
	check(ok == true and amount == 2400 and SE[200] == nil and alq_core.courier_packages[200] == nil
		and #s.rewards == 1 and s.rewards[1].peer == 1 and s.rewards[1].amount == 2400,
		"hostplay: honest_trader_handover_removes_parcel_and_pays_its_holder")
	if handler then handler(1, req.payload) end
	check(#s.rewards == 1, "hostplay: repeated_trader_handover_does_not_pay_twice")
end

local function check_no_publication(role, s)
	if role == "srv_world" then OBJ = {} end -- no game objects on the world process
	NOW = NOW + 2000
	s.tick()
	check(s.writes() == 0, role .. ": no_local_publication")
end

for _, role in ipairs(modes.names()) do
	modes.install(coop_mode, role)
	local s = setup(role)
	if role == "hostplay" then
		check_publication(role, s, s.tick)
		check_handover()
		check_no_publication("client", setup("client"))
	elseif role == "srv_map" then
		NOW = NOW + 2000
		s.tick()
		check(s.handlers["alq.dlg"] == nil, "srv_map: legacy_world_handler_not_registered")
		-- Check the filter with the map's local player, supplying the publisher's input directly.
		local player = { peer = 1, cid = assert(s.compat.cid_of_peer(1)) }
		check_publication(role, s, function() s.publish(player) end)
	elseif role == "srv_world" then
		check_no_publication(role, s)
	else
		check_no_publication(role, s)
		SE[200].parent_id = 0
		check(s.dialog.pre_client(db.actor, s.trader) == true, "none: original_single_player_dialog")
		-- Direct calls also keep the original filter outside a session.
		s.publish({ peer = 1, cid = 500 })
		check(not (s.values["player:1"] or {})["alq.n.100"], "none: original_publication_filter")
	end
end

local adapter = rawget(_G, "coop_mods_alq")
if adapter then
	local before = #coop_mods_core.wrapped
	adapter.on_game_start()
	check(#coop_mods_core.wrapped == before, "startup: repeated_install_is_idempotent")
	coop_compat_alq = nil
	check(pcall(adapter.on_game_start), "startup: missing_mod_does_not_throw")
	coop_compat_alq = { on_game_start = function() end }
	check(pcall(adapter.on_game_start), "startup: changed_mod_does_not_throw")
end

done("ALQ publication filter G16-3")
