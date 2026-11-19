-- Anomaly Coop test (build 56, live 2026-11-18): the per-player keys of coop_economy_mdata (thirst, sleep, psy, disguise,
-- detector, radio frequency, bolts ...) across a client's world load, and the providers that read them from the live mods.
-- Owner: "everything a client has must come through a transition exactly as in a usual game". Not shipped.
-- Run: tools\test_lua.cmd economy_load
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function setup(nclients)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = { x = p * 2, y = 0, z = 0 } end
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
	end
	for p, W in pairs(WORLDS) do start_world(W) end
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

-- the events of name `name` machine W sent since `from` (an index into W.SENT)
local function sent_since(W, from, name)
	local n = 0
	for i = from + 1, #W.SENT do
		local s = W.SENT[i]
		if s.name and s.name:find(name, 1, true) then n = n + 1 end
	end
	return n
end

-- the host's save of this moment, as the client reads it (the host's own values on top level, every record inside)
local function host_save(H, top)
	local save = { se_object = {} }
	for k, v in pairs(top or {}) do save[k] = v end
	save.coop_peer_mdata = H.coop_economy_core.copy(H.MDATA.coop_peer_mdata)
	return save
end

-------------------------------------------------------------------------------
section("load stash: a drink 3 s before the load is kept")
do
	local H, A = setup(1)
	A.THIRST = 100
	A.actor_status_thirst = { save_state = function(m) m.drink = { last_drink = A.THIRST } end }
	tick(A, 16000) deliver_all()
	local told = H.coop_economy_mdata.player_value(501, "drink")
	check(told and told.last_drink == 100, "the 15 s look told the host his thirst")
	-- he drinks; the next 15 s look is far: the group changes level 3 s later
	tick(A, 9000)
	A.THIRST = 2100
	tick(A, 3000)
	local sent = #A.SENT
	A.coop.world_epoch = function() return 4 end
	fire(A, "coop_on_world_leaving", 5)
	check(sent_since(A, sent, "pmd") == 0, "nothing is sent when the load starts: the host is saving already")
	local kept = A.STASH.coop_economy_mdata
	check(type(kept) == "string" and kept:sub(1, 8) == "@load:5|", "the stash holds his keys for the world of epoch 5 (" .. tostring(kept and kept:sub(1, 12)) .. ")")
	deliver_all()
	-- the host's save has the record of 9 s ago: the drink is not in it
	local save = host_save(H, { drink = { last_drink = 1 } })
	check(save.coop_peer_mdata[501].keys.drink.last_drink == 100, "the host's record is the older one")
	A.coop.world_epoch = function() return 5 end
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.drink and save.drink.last_drink == 2100, "after the load his thirst is the one after the drink (" .. tostring(save.drink and save.drink.last_drink) .. ")")
	check(A.STASH.coop_economy_mdata == nil, "the kept state is read once")
	-- the stock load_state takes it into the mod: the mod's own value is now the carried one
	A.THIRST = save.drink.last_drink
	tick(A, 16000) deliver_all()
	told = H.coop_economy_mdata.player_value(501, "drink")
	check(told and told.last_drink == 2100, "the next look tells the host the carried value: its record catches up (" .. tostring(told and told.last_drink) .. ")")
	A.actor_status_thirst = nil
end

section("load stash: a state kept for another world is not read")
do
	local H, A = setup(1)
	A.THIRST = 100
	A.actor_status_thirst = { save_state = function(m) m.drink = { last_drink = A.THIRST } end }
	tick(A, 16000) deliver_all()
	A.THIRST = 2100
	A.coop.world_epoch = function() return 8 end
	fire(A, "coop_on_world_leaving", 9)
	-- the host loaded a save meanwhile: this load is of the world of epoch 10, not the one he left for
	A.coop.world_epoch = function() return 10 end
	local save = host_save(H, { drink = { last_drink = 1 } })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.drink and save.drink.last_drink == 100, "the host's record is read, not the state kept for epoch 9")
	check(A.STASH.coop_economy_mdata == nil, "and the stale state is dropped")
	-- an exe without coop.world_epoch: a kept state is never read
	A.coop.world_epoch = function() return 11 end
	fire(A, "coop_on_world_leaving", 11)
	A.coop.world_epoch = nil
	save = host_save(H, { drink = { last_drink = 1 } })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.drink and save.drink.last_drink == 100 and A.STASH.coop_economy_mdata == nil,
		"without coop.world_epoch the record is read and the kept state dropped")
	A.actor_status_thirst = nil
end

section("load stash: the bolts rule holds on the kept values")
do
	local H, A = setup(1)
	local mine, slot = { bolt = 7 }, "bolt"
	A.itms_manager = { save_state = function(m) m.bolts, m.bolt_slot = mine, slot end }
	local made = 0
	A.alife_create_item = function(sec, to) if to == A.db.actor then made = made + 1 end return { id = 900 + made } end
	tick(A, 16000) deliver_all()
	mine = { bolt = 9 } -- he picked two up, the second before the look
	A.coop.world_epoch = function() return 2 end
	fire(A, "coop_on_world_leaving", 3)
	A.coop.world_epoch = function() return 3 end
	local save = host_save(H, { bolts = { bolt = 40 }, bolt_slot = "bolt" })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.bolts == nil and save.bolt_slot == nil, "his kept bolts are out of m_data: the stock makes none while he loads, the host's forty neither")
	-- a second load comes while his bolts are still to be made (his hands are empty then): the held ones are kept, not the hands
	mine, slot = {}, nil
	fire(A, "coop_on_world_leaving", 4)
	A.coop.world_epoch = function() return 4 end
	save = host_save(H, { bolts = { bolt = 40 }, bolt_slot = "bolt" })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	for _ = 1, 20 do tick(A, 300) end
	check(made == 10, "his nine bolts and the slot's one are made once he is live (" .. made .. ")")
	-- a character that never told bolts (no itms_manager): the host's stand
	tick(A, 6000) -- past the quiet time after the creates
	A.itms_manager = nil
	A.coop.world_epoch = function() return 5 end
	fire(A, "coop_on_world_leaving", 6)
	A.coop.world_epoch = function() return 6 end
	save = { se_object = {}, bolts = { bolt = 3 }, bolt_slot = "bolt",
		coop_peer_mdata = { [501] = { name = "coop_player_avatar501", keys = { sleep = { last_sleep = 1 } } } } }
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.bolts and save.bolts.bolt == 3 and save.bolt_slot == "bolt", "never told: the host's bolts stay for the stock")
end

section("load stash: the host and single player keep nothing")
do
	local H, A = setup(1)
	H.coop.world_epoch = function() return 1 end
	fire(H, "coop_on_world_leaving", 2)
	check(H.STASH.coop_economy_mdata == nil, "the host keeps nothing")
	A.ACTIVE = false
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 2)
	check(A.STASH.coop_economy_mdata == nil, "outside a session nothing is kept")
end

-------------------------------------------------------------------------------
-- Providers: keys only the mods' own save_state wrote (it never runs on a client)
-------------------------------------------------------------------------------
section("providers: the radio frequency is read from item_radio")
do
	local H, A = setup(1)
	A.FREQ = 555
	A.item_radio = { get_freq = function() return A.FREQ end }
	local sent = #A.SENT
	tick(A, 16000) deliver_all()
	check(sent_since(A, sent, "pmd") > 0, "an economy.pmd event goes out")
	check(H.coop_economy_mdata.player_value(501, "RF_freq") == 555, "the host has his frequency (" .. tostring(H.coop_economy_mdata.player_value(501, "RF_freq")) .. ")")
	A.FREQ = 610
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "RF_freq") == 610, "a new frequency is told")
	A.item_radio = { get_freq = function() error("broken") end }
	A.MDATA.RF_freq = 610
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "RF_freq") == 610, "a failing accessor falls back to the m_data entry")
	A.item_radio = nil
end

-- gameplay_disguise as G.A.M.M.A. has it: the state in file locals, written by its global functions (corpus
-- gameplay_disguise.script:45-46, 207-224, 227-260, 267-269), save_state local
local DISGUISE = [[
local previous_relation
local can_communicate = false
local is_disguised
function has_comms(v) can_communicate = v end
function set_comm(new_comm, default_comm, rel)
	previous_relation = rel
	is_disguised = default_comm and (new_comm ~= default_comm) and true or false
end
function is_actor_disguised() return is_disguised end
]]

section("providers: disguise state and its relation keys are read from gameplay_disguise")
do
	local H, A = setup(1)
	local facade = load_script(A, "coop_mode")
	modes.live(facade, function(name) return load_script(A, name) end)
	A.coop_mods_core = load_script(A, "coop_mods_core")
	local gd = setmetatable({}, { __index = A })
	setfenv(assert(loadstring(DISGUISE, "=gameplay_disguise")), gd)()
	A.gameplay_disguise = gd
	gd.has_comms(true)
	gd.set_comm("bandit", "stalker", -1000)
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "disguise_state") == true, "the host has his disguise")
	check(H.coop_economy_mdata.player_value(501, "disguise_previous_relation") == -1000, "and the relation the disguise replaced")
	check(H.coop_economy_mdata.player_value(501, "disguise_can_communicate") == true, "and whether he could talk to his faction")
	gd.set_comm("stalker", "stalker", 0)
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "disguise_state") == false, "taking it off is told")
	-- the next load: his own values reach gameplay_disguise.load_state, not the host's
	gd.set_comm("bandit", "stalker", -1000)
	tick(A, 16000) deliver_all()
	local save = host_save(H, { disguise_state = false, disguise_previous_relation = 7, disguise_can_communicate = false })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.disguise_state == true and save.disguise_previous_relation == -1000 and save.disguise_can_communicate == true,
		"after a load his own disguise keys are in m_data")
	check(save.disguise_highest_suspicion == nil and save.disguise_npcs_memory == nil, "the NPC side keys are not his (not carried)")
	A.gameplay_disguise = nil
end

section("providers: the detector, not before 2 s after the first update")
do
	local H, A = setup(1)
	A.DET = true
	A.db.actor.active_detector = function() return A.DET and { id = function() return 950 end } or nil end
	fire(A, "actor_on_first_update")
	tick(A, 3000)
	tick(A, 16000) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "detector_was_active") == true, "a detector out is told")
	-- a load: the record says out; actor_effects shows it at the first update, the show takes a moment
	local save = host_save(H, { detector_was_active = false })
	A.MDATA = save
	A.alife_storage_manager.on_before_load_state()
	check(save.detector_was_active == true, "his own detector state reaches actor_effects.load_state")
	A.DET = false
	fire(A, "actor_on_first_update")
	A.coop_economy_mdata.send_player_keys()
	tick(A, 500) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "detector_was_active") == true,
		"right after the first update the show is not read as put away")
	A.DET = true
	tick(A, 2000)
	A.DET = false -- he puts it away
	A.coop_economy_mdata.send_player_keys()
	tick(A, 500) deliver_all()
	check(H.coop_economy_mdata.player_value(501, "detector_was_active") == false, "putting it away is told")
	A.db.actor.active_detector = nil
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
