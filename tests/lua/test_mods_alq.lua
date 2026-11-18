-- G16-3, Dev 57: run the real ALQ publisher and dialog consumer, not a copied filter.
-- Co-op: the host has the objects and inventory. Server: the map process has the
-- objects; world/map transport is a separate unit and needs the two-map stand.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")

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
-- Before the adapter exists this runs the unpatched publisher, so RED is a
-- missing trader snapshot rather than a missing-file/runtime error.
if have_file("gamedata/scripts/coop_mods_alq.script") then load_script("coop_mods_alq") end

IsTrader = function(obj) return obj and obj._kind == "trader" end
get_object_squad = function() return nil end
dialogs = { who_is_npc = function(_, npc) return npc end }
alq_mcm = { get_config = function() return true end }

local function setup(role)
	MODE = role == "client" and "client" or role == "none" and "sp" or "host"
	coop.is_map_server = function() return role == "srv_map" end
	coop.is_dedicated = function() return role == "srv_world" end
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
		"function parcel_for(", "function parcel_reward(",
	}, "alq_player", "return true"))
	local values, writes = {}, 0
	coop.sync = {
		keys = function(scope) return values[scope] or {} end,
		set = function(scope, key, value)
			values[scope] = values[scope] or {}
			values[scope][key] = value
			writes = writes + 1
			return true
		end,
		get = function(_, key) return values["player:1"] and values["player:1"][key] end,
		on = function() return true end,
		handler = function() return true end,
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
		values = values, writes = function() return writes end, tick = tick,
		unrelated = unrelated,
	}
end

for _, role in ipairs({ "hostplay", "srv_map" }) do
	local s = setup(role)
	NOW = NOW + 2000
	s.tick()
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
	MODE = "client"
	check(s.dialog.pre_client(db.actor, s.trader) == true,
		role .. ": client_sees_trader_handover_reply")
	MODE = "host"
	local writes = s.writes()
	NOW = NOW + 2000
	s.tick()
	check(s.writes() == writes, role .. ": unchanged_snapshot_not_republished")
	OBJ[100]._alive = false
	NOW = NOW + 2000
	s.tick()
	check(snap["alq.n.100"] == nil, role .. ": dead_trader_snapshot_removed")
	-- Even if a player character has the newly admitted class, exclude it.
	OBJ[500]._kind = "trader"
	NOW = NOW + 2000
	s.tick()
	check(snap["alq.n.500"] == nil, role .. ": trader_class_player_never_published")
end

for _, role in ipairs({ "srv_world", "client", "none" }) do
	local s = setup(role)
	if role == "srv_world" then OBJ = {} end -- no game objects on the world process
	NOW = NOW + 2000
	s.tick()
	check(s.writes() == 0, role .. ": no_local_publication")
	if role == "none" then
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
