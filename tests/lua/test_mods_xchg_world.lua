-- Dev 57 G4-3. Start the real exchange dispatcher and send requests through the mode facade.
local modes = dofile("tests/lua/support/modes.lua")
local role = modes.names()[1]
MODE = role == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local actor = make_actor(vec3(20, 0, 0))
spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 500 })
spawn("coop_player_avatar", vec3(20, 0, 0), nil, { id = 501 })
local avatar_of = coop.avatar_of
coop.avatar_of = function(peer) return peer == 2 and 501 or avatar_of(peer) end
coop.world_epoch = function() return 7 end

local PLANTED, MINE, PLACE = "mine_new_blow", "mine_new", "jup_b32_scanner_device"
INI[MINE], INI[PLANTED], INI.bread = {}, {}, {}
INI[PLACE] = { use1_action_functor = "itms_manager.use_place" }

-- The mod entry points reproduce the original order of world calls (create before release for mines, release before
-- create for placement). The vector and camera stubs reproduce the placement offset and angle from use_place.
local v = getmetatable(vector())
function v:add(p) return self:set(self.x + p.x, self.y + p.y, self.z + p.z) end
function v:mul(n) return self:set(self.x * n, self.y * n, self.z * n) end
function v:getH() return -math.pi / 2 end
function device() return { cam_dir = vec3(1, 0, 0) } end
local marks, unregistered = {}, {}
txr_mines = {
	EXPLOSIVE_SECTION_LOOKUP = { [MINE] = PLANTED },
	_mines = {},
	clean_mines = function(id) txr_mines._mines[id] = nil end,
}
local original_mine, original_place = 0, 0
ui_hud_dotmarks = {
	get_mark = function(id) return marks[id] end,
	unregister_scanned_entity = function(id)
		marks[id] = nil
		unregistered[id] = (unregistered[id] or 0) + 1
	end,
	remove_bomb = function(mark)
		original_mine = original_mine + 1
		alife_create_item(mark.inv_section, db.actor)
		txr_mines._mines[mark.id] = nil
		ui_hud_dotmarks.unregister_scanned_entity(mark.id)
		alife_release_id(mark.id)
		return true
	end,
}
itms_manager = {
	use_place = function(obj)
		original_place = original_place + 1
		local p = obj:parent()
		if not (p and p:id() == AC_ID) then return end
		local section = obj:section()
		alife_release_id(obj:id())
		local pos = db.actor:position()
		pos:add(device().cam_dir:mul(1.2))
		pos.y = db.actor:position().y + 1
		local se = alife_create(section, pos, db.actor:level_vertex_id(), db.actor:game_vertex_id())
		se.angle = vector():set(0, device().cam_dir:getH(), 0)
	end,
}

start_all()
local peer2_here = true
local mode = modes.install(coop_mode, role, role == "srv_map" and {
	-- Peer 2 can be on a different map while this map still has its old proxy.
	where = function(peer) return (peer == 0 or (peer == 2 and not peer2_here)) and "away" or "here" end,
} or nil)
if role == "srv_map" then
	coop.is_host = function() return false end
	coop.is_map_server = function() return true end
end
local X = load_script("coop_mods_xchg")
X.on_game_start()
local ok, adapter = pcall(load_script, "coop_mods_xchg_world")
if ok then adapter.on_game_start() end
local function tick(ms)
	NOW = NOW + (ms or 50)
	SendScriptCallback("actor_on_update")
end

local function mine(x)
	local se = spawn(PLANTED, vec3(x or 21, 0, 0))
	local id = se.id
	txr_mines._mines[id] = { active = true }
	coop_npc_world._mines()[id] = { active = true }
	local mark = { id = id, is_disarmable = true, inv_section = MINE }
	marks[id] = mark
	return id, mark
end

local seq = 0
local function request(kind, id, peer, data, direct)
	seq = seq + 1
	local t = data or {}
	t.k, t.o, t.i, t.key = kind, tostring(peer) .. ":7:" .. seq, id, id
	if role == "srv_map" and not direct then t._peer = peer end
	coop_main.on_event("mods.xchg", coop_main.encode(t), t._peer and 0 or peer)
	return t.o
end

local function answer(op)
	for i = #SENT, 1, -1 do
		local msg = SENT[i]
		if msg.name == "mods.xchg_r" then
			local t = coop_main.decode(msg.payload)
			if t.o == op then return t, msg.target end
		end
	end
	return {}
end

local function place_data(x)
	return { x = x or 21.2, y = 1, z = 0, h = -math.pi / 2 }
end

if role == "hostplay" or role == "srv_map" then
	coop_trust.reset_for_test({ default = "refuse" })
	local id, mark = mine()
	local release = alife_release_id
	local attempts = 0
	alife_release_id = function(which)
		if which == id then attempts = attempts + 1; return true end
		return release(which)
	end
	local first = request("dm_bomb", id, 1)
	if role == "hostplay" then
		ui_hud_dotmarks.remove_bomb(mark) -- host's own player competes with peer 1 through the same dispatcher
	else
		local second = request("dm_bomb", id, 2)
		check(answer(second).why == "reserved", "map authority refuses a second operation on the same mine")
	end
	check(attempts == 1 and X.reserved(id) == first and #CREATED == 0 and answer(first).ok == nil,
		"simultaneous defuses reserve the mine and withhold the item")
	check(txr_mines._mines[id] == nil and coop_npc_world._mines()[id] == nil, "both mine registries cleared at release")
	SE[id] = nil
	tick()
	check(#CREATED == 0, "defuse waits for the game object as well as ALife")
	OBJ[id] = nil
	tick()
	local accepted, to = answer(first)
	check(accepted.ok == true and to == 1 and #CREATED == 1 and CREATED[1].sec == MINE and CREATED[1].parent == 500,
		"only the winning peer gets the inventory mine after both objects disappear")
	local repeated = request("dm_bomb", id, 1)
	check(answer(repeated).ok == false and #CREATED == 1, "a defused object cannot pay twice")
	alife_release_id = release

	local foreign = spawn("bread", vec3(21, 0, 0)).id
	local wrong_section = request("dm_bomb", foreign, 1)
	check(answer(wrong_section).ok == false and SE[foreign] and #CREATED == 1, "foreign mine section refused")
	local far = mine(23.6)
	local too_far = request("dm_bomb", far, 1)
	check(answer(too_far).ok == false and SE[far], "distance beyond Dot Marks' 3.5 m is refused in refuse mode")
	coop_trust.reset_for_test({ default = "log" })
	local logged = request("dm_bomb", far, 1)
	tick()
	local count = coop_trust.status().xchg_dm_bomb or {}
	check(count.checked == 1 and count.failed == 1 and count.refused == 0 and answer(logged).ok == true,
		"far mine request counts and proceeds in log mode")
	coop_trust.reset_for_test({ default = "refuse" })

	local item = spawn(PLACE, actor:position(), 500).id
	local other = spawn(PLACE, actor:position(), 0).id
	local own_bread = spawn("bread", actor:position(), 500).id
	local old_count = #CREATED
	local far_place = request("item_place", item, 1, place_data(40))
	local foreign_place = request("item_place", other, 1, place_data())
	local wrong_action = request("item_place", own_bread, 1, place_data())
	local bad_angle = place_data()
	bad_angle.h = 1000
	local malformed = request("item_place", item, 1, bad_angle)
	check(answer(far_place).ok == false and answer(foreign_place).ok == false and answer(wrong_action).ok == false
		and answer(malformed).ok == false and SE[item] and SE[other] and SE[own_bread] and #CREATED == old_count,
		"placement refuses far, foreign, unconfigured and out-of-range requests without spending")

	local create = alife_create
	alife_create = function() return nil end
	local no_spawn = request("item_place", item, 1, place_data())
	check(answer(no_spawn).ok == false and SE[item] and #CREATED == old_count, "a refused spawn leaves the source")
	alife_create = function() return { id = 65530 } end
	local not_registered = request("item_place", item, 1, place_data())
	check(answer(not_registered).ok == false and SE[item] and #CREATED == old_count,
		"an unregistered spawn result cannot spend the source")
	alife_create = function(...)
		check(SE[item] ~= nil, "source still exists while its replacement is created")
		return create(...)
	end
	alife_release_id = function(which)
		if which == item then
			local newest = CREATED[#CREATED]
			check(#CREATED == old_count + 1 and newest and SE[newest.id] ~= nil,
				"exact replacement is registered before attempting to release source")
			return true
		end
		return release(which)
	end
	local placed = request("item_place", item, 1, place_data())
	local duplicate = request("item_place", item, 1, place_data())
	local made = CREATED[#CREATED]
	check(answer(placed).ok == nil and answer(duplicate).why == "reserved" and made and #CREATED == old_count + 1,
		"placement holds its source reservation and waits for removal before answering")
	release(item)
	tick()
	accepted, to = answer(placed)
	local repl = made and SE[made.id]
	check(accepted.ok == true and to == 1 and not SE[item] and repl and repl.parent_id == 65535
		and repl:section_name() == PLACE and math.abs(repl.position.x - 21.2) < 0.001
		and repl.position.y == 1 and repl.angle and math.abs(repl.angle.y + math.pi / 2) < 1e-6,
		"successful placement spends the source and keeps the correctly oriented ground replacement")
	alife_create, alife_release_id = create, release

	local stuck = spawn(PLACE, actor:position(), 500).id
	alife_release_id = function(which) if which ~= stuck then return release(which) end end
	local timed_out = request("item_place", stuck, 1, place_data())
	local undone = CREATED[#CREATED]
	tick(10001)
	check(answer(timed_out).why == "gone_timeout" and SE[stuck] and undone and not SE[undone.id] and not X.reserved(stuck),
		"a source release that never happens rolls back the placement")
	alife_release_id = release

	local boundary = spawn(PLACE, actor:position(), 500).id
	local heading = place_data()
	heading.h = 3.1415927410125732 -- float32 +/-pi from the engine's vector:getH
	local facing_back = request("item_place", boundary, 1, heading)
	tick()
	check(answer(facing_back).ok == true and not SE[boundary], "placement accepts an engine float32 heading at pi")
	local diagonal = spawn(PLACE, actor:position(), 500).id
	local rear_heading = place_data()
	rear_heading.h = 5 * math.pi / 4 -- getH returns pi - atan(x/z) when z < 0
	local rear_quadrant = request("item_place", diagonal, 1, rear_heading)
	tick()
	check(answer(rear_quadrant).ok == true and not SE[diagonal], "placement accepts the rear-right heading above pi")

	if role == "srv_map" then
		peer2_here = false
		local here_mine = mine()
		local away_item = spawn(PLACE, actor:position(), 501).id
		local before = #CREATED
		local fake = request("dm_bomb", here_mine, 1, nil, true)
		local away_mine = request("dm_bomb", here_mine, 2)
		local away_place = request("item_place", away_item, 2, place_data())
		check(answer(fake).ok == nil and answer(away_mine).ok == false and answer(away_place).ok == false
			and SE[here_mine] and SE[away_item] and #CREATED == before,
			"map authority requires a relay and refuses a requester on another map")
	end
elseif role == "srv_world" then
	local id = mine()
	local item = spawn(PLACE, actor:position(), 500).id
	local before = #SENT
	request("dm_bomb", id, 1)
	request("item_place", item, 1, place_data())
	check(#SENT == before + 2 and SENT[#SENT].name == "mods.xchg" and SENT[#SENT].target == mode.bridge
		and coop_main.decode(SENT[#SENT].payload)._peer == 1 and SE[id] and SE[item] and #CREATED == 0,
		"world server relays both kinds with the transport peer and never mutates the map objects")
end

if role == "hostplay" then
	-- A mirror can only ask. In particular the pre-fix use_place dereferences nil if the ground spawn is refused.
	MODE, SELF = "client", 1
	modes.install(coop_mode, role, { leads_here = function() return false end, is_player_mirror = function() return true end })
	local id, mark = mine()
	local _, obj = spawn(PLACE, actor:position(), 0)
	local before = #CREATED
	local create = alife_create
	alife_create = function() return nil end
	ui_hud_dotmarks.remove_bomb(mark)
	local mine_request = sent("mods.xchg") or {}
	ui_hud_dotmarks.remove_bomb(mark)
	local again = sent("mods.xchg") or {}
	check(mine_request.k == "dm_bomb" and mine_request.key == id and mine_request.i == id
		and mine_request.o == again.o and marks[id] == mark and SE[id] and #CREATED == before,
		"mirror sends one defuse request and changes neither mine nor mark before the answer")
	if mine_request.o then
		coop_main.on_event("mods.xchg_r", coop_main.encode({ o = mine_request.o, ok = false }), 0)
	end
	check(marks[id] == mark and SE[id], "refused defuse retains the mark")
	ui_hud_dotmarks.remove_bomb(mark)
	mine_request = sent("mods.xchg") or {}
	if mine_request.o then
		coop_main.on_event("mods.xchg_r", coop_main.encode({ o = mine_request.o, ok = true }), 0)
	end
	check(not marks[id] and unregistered[id] == 1 and not txr_mines._mines[id],
		"successful answer removes the requester's mark and local stock entry")
	local called = pcall(itms_manager.use_place, obj)
	alife_create = create
	local placement = sent("mods.xchg") or {}
	check(called and placement.k == "item_place" and placement.i == obj:id() and SE[obj:id()]
		and math.abs(placement.x - 21.2) < 0.001 and placement.y == 1 and math.abs(placement.h + math.pi / 2) < 1e-6,
		"mirror placement makes one request without calling the original destructive functor")
elseif role == "none" then
	local id, mark = mine()
	local _, obj = spawn(PLACE, actor:position(), 0)
	check(ui_hud_dotmarks.remove_bomb(mark) == true and original_mine == 1 and not SE[id] and not marks[id],
		"single player retains the original defuse")
	itms_manager.use_place(obj)
	check(original_place == 1 and not SE[obj:id()] and #CREATED == 2 and sent_count("mods.xchg") == 0,
		"single player retains the original placement")
end

done("mods_xchg_world@" .. role)
