-- Anomaly Coop test (build 57 stand, b57g_ms_crash_server): a player's item data (se vars, item riders) that was still on its way
-- when he left the world he is in. The world server drops what he sends between his trip request and the SessionReset of his
-- rejoin (coop_script.cpp server_on_script_event, P6: "script event 'economy.se' from #2 dropped: sender is not in the world yet");
-- the co-op host drops what a mover sends after the go of a group transition (host_prepare). The save he loads next is the
-- world's: without the carry the parts of his weapon and the riders of his items come back as they were before. Not shipped.
-- Run: tools\test_lua.cmd economy_trip_carry
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function own_lid(p, info)
	return (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
end

local function start(W)
	for q, info in pairs(PLAYERS) do add_entity(W, own_lid(W.PEER, info), "coop_player_avatar", nil, POS[q]) end
end

local function setup()
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "anna", proxy = 501 } }
	POS = { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 2, y = 0, z = 0 } }
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do start(make_world(p)) end
	for _, W in pairs(WORLDS) do
		modes.live(load_script(W, "coop_mode"), function(name) return load_script(W, name) end)
		start_world(W)
		W.coop_economy_mdata.declare_item_key("exo_devices")
	end
	local H, A = WORLDS[0], WORLDS[1]
	add_item(H, 800, "wpn_pm", 501)
	add_item(A, 800, "wpn_pm", 0)
	A.INV = { 800 }
	A.MDATA.exo_devices = { [800] = { power = 0.9 } }
	H.MDATA.exo_devices = { [800] = { power = 0.9 } }
	tick(A, 1100) deliver_all() -- the seeding pass of the riders
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 60 })
	tick(A, 1100) deliver_all()
	return H, A
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

-- The world drops what the peer sent after it took him for joining again (P6).
local function drop_from(peer)
	local n = 0
	for i = #QUEUE, 1, -1 do
		if QUEUE[i].from == peer and QUEUE[i].to == 0 then
			table.remove(QUEUE, i)
			n = n + 1
		end
	end
	return n
end

-- The world's save as he loads it: the world's records of the items, nothing of his machine.
local function host_save(H)
	local copy = H.coop_economy_core.copy
	local save = { se_object = {}, game_object = {} }
	for id, e in pairs(H.MDATA.se_object) do
		if id ~= 501 then save.se_object[id] = copy(e) end
	end
	save.exo_devices = copy(H.MDATA.exo_devices)
	save.coop_peer_mdata = copy(H.MDATA.coop_peer_mdata)
	return save
end

-- His machine loads the next world: a new Lua state (the old tables are gone), the session stash stays.
local function reload_client(A, save, epoch, item_parent)
	local stash = A.STASH
	local W = make_world(A.PEER)
	W.STASH = stash
	start(W)
	modes.live(load_script(W, "coop_mode"), function(name) return load_script(W, name) end)
	start_world(W)
	W.coop_economy_mdata.declare_item_key("exo_devices")
	if item_parent then add_entity(W, item_parent, "stalker", nil) end
	add_item(W, 800, "wpn_pm", item_parent or 0)
	W.INV = item_parent and {} or { 800 }
	W.coop.world_epoch = function() return epoch end
	W.MDATA = save
	W.alife_storage_manager.on_before_load_state()
	return W
end

local function parts(W) local p = W.se_load_var(800, nil, "parts") return p and p.prt_w_barrel end
local function power(W) local e = W.MDATA.exo_devices and W.MDATA.exo_devices[800] return e and e.power end

-------------------------------------------------------------------------------
section("server trip: what the world dropped while he left comes back with him")
do
	local H, A = setup()
	check(parts(H) == 60, "before the trip his parts reach the world")
	-- he shoots and his exo drains; then the trip: what goes out now is behind his LevelMove
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 41 })
	A.MDATA.exo_devices[800] = { power = 0.4 }
	tick(A, 1100)
	check(drop_from(1) >= 2, "the world drops his se batch and his rider batch (P6)")
	-- the last frames before the SessionReset reaches him: written, not sent yet
	A.se_save_var(800, nil, "upgr_mark", "b")
	A.MDATA.exo_devices[800] = { power = 0.35 }
	A.coop.world_epoch = function() return 1 end
	local sent = #A.SENT
	fire(A, "coop_on_world_leaving", 1) -- the same epoch: the world goes on, only he comes into it anew
	check(#A.SENT == sent, "nothing is sent when the load starts")
	local save = host_save(H)
	check(save.se_object[800].parts.prt_w_barrel == 60 and save.exo_devices[800].power == 0.9,
		"the world's save for him has the values from before")
	local A2 = reload_client(A, save, 1)
	check(sent_since(A2, 0, "economy.se") == 0, "nothing goes out while he loads")
	tick(A2, 1100) deliver_all()
	check(parts(A2) == 41 and A2.se_load_var(800, nil, "upgr_mark") == "b" and power(A2) == 0.35,
		"his machine has what he left with (parts " .. tostring(parts(A2)) .. ", power " .. tostring(power(A2)) .. ")")
	check(parts(H) == 41 and H.se_load_var(800, nil, "upgr_mark") == "b" and power(H) == 0.35,
		"and the world has it now (parts " .. tostring(parts(H)) .. ", power " .. tostring(power(H)) .. ")")
	check(A2.STASH.coop_economy_mdata_items == nil, "the kept item data is read once")
	local n = #A2.SENT
	tick(A2, 1100) deliver_all()
	check(sent_since(A2, n, "economy.se") == 0 and sent_since(A2, n, "economy.imd") == 0, "and sent once")
end

section("co-op group transition: what was in flight at the host's go comes back")
do
	local H, A = setup()
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 33 })
	tick(A, 1100)
	drop_from(1) -- the host saved at its go; his batch came after it and found him moving
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 2) -- LoadWait Prepared: the world of the transition has the next epoch
	local A2 = reload_client(A, host_save(H), 2)
	tick(A2, 1100) deliver_all()
	check(parts(A2) == 33 and parts(H) == 33, "the parts of the last second before the go come through (" .. tostring(parts(A2)) .. ", " .. tostring(parts(H)) .. ")")
end

section("what reached the world is not sent again")
do
	local H, A = setup()
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 41 })
	A.MDATA.exo_devices[800] = { power = 0.4 }
	tick(A, 1100) deliver_all()
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 1)
	local A2 = reload_client(A, host_save(H), 1)
	tick(A2, 1100) deliver_all()
	check(parts(A2) == 41 and power(A2) == 0.4, "the save has his values")
	check(sent_since(A2, 0, "economy.se") == 0 and sent_since(A2, 0, "economy.imd") == 0, "nothing of it is sent again")
end

section("a newer word of the world wins over what he sent before")
do
	local H, A = setup()
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 41 })
	tick(A, 1100) deliver_all()
	H.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 7 }) -- the authority of his weapon rolls it again
	tick(H, 400) deliver_all()
	check(parts(A) == 7, "his machine heard it")
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 1)
	local A2 = reload_client(A, host_save(H), 1)
	tick(A2, 1100) deliver_all()
	check(parts(A2) == 7 and parts(H) == 7 and sent_since(A2, 0, "economy.se") == 0, "the world's later value stays (" .. tostring(parts(A2)) .. ")")
end

section("another world: nothing is carried")
do
	local H, A = setup()
	A.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 41 })
	tick(A, 1100)
	drop_from(1)
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 1)
	-- the host loaded a save meanwhile: the world he loads is of another epoch
	local A2 = reload_client(A, host_save(H), 3)
	tick(A2, 1100) deliver_all()
	check(parts(A2) == 60 and parts(H) == 60 and sent_since(A2, 0, "economy.se") == 0, "the world of the save stands")
	check(A2.STASH.coop_economy_mdata_items == nil, "and the stale state is dropped")
end

section("an item that is not his in the next world is left alone")
do
	local H, A = setup()
	A.se_save_var(800, nil, "upgr_mark", "b")
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 1)
	local A2 = reload_client(A, host_save(H), 1, 810) -- the pistol lies in a stalker's pack there
	tick(A2, 1100) deliver_all()
	check(A2.se_load_var(800, nil, "upgr_mark") == nil and H.se_load_var(800, nil, "upgr_mark") == nil,
		"a var of another's item is neither written nor sent")
end

section("the load rolls the parts again when the save has none: the kept ones go out, both sides agree")
do
	local H, A = setup()
	-- a weapon he just picked up: rolled here, the batch dropped by P6, the world has no parts of it
	add_item(H, 802, "wpn_ak74", 501)
	add_item(A, 802, "wpn_ak74", 0)
	A.INV = { 800, 802 }
	A.se_save_var(802, nil, "parts", { wpn_ak74 = 90, prt_w_barrel = 11 })
	tick(A, 1100)
	drop_from(1)
	A.coop.world_epoch = function() return 1 end
	fire(A, "coop_on_world_leaving", 1)
	local save = host_save(H)
	check(save.se_object[802] == nil or save.se_object[802].parts == nil, "the world's save has no parts of 802")
	local A2 = reload_client(A, save, 1)
	add_item(A2, 802, "wpn_ak74", 0)
	A2.INV = { 800, 802 }
	-- GAMMA's WPO rolls the missing parts while the world is read (se_early)
	local live = A2.coop.is_live
	A2.coop.is_live = function() return false end
	A2.se_save_var(802, nil, "parts", { wpn_ak74 = 90, prt_w_barrel = 99 })
	A2.coop.is_live = live
	tick(A2, 1100) deliver_all()
	tick(A2, 1100) deliver_all()
	local a, h = A2.se_load_var(802, nil, "parts"), H.se_load_var(802, nil, "parts")
	check(a and h and a.prt_w_barrel == 11 and h.prt_w_barrel == 11,
		"his machine and the world have the parts he left with (his " .. tostring(a and a.prt_w_barrel) .. ", world "
		.. tostring(h and h.prt_w_barrel) .. ")")
end

section("the host keeps nothing")
do
	local H = setup()
	H.se_save_var(800, nil, "parts", { wpn_pm = 80, prt_w_barrel = 12 })
	H.coop.world_epoch = function() return 1 end
	fire(H, "coop_on_world_leaving", 2)
	check(H.STASH.coop_economy_mdata_items == nil, "nothing is kept on the process that decides the world")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
