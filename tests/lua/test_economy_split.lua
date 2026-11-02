-- Anomaly Coop temp test (economy, travel): fast travel, backpack travel and guides with split levels (a player goes
-- alone, nobody has to be gathered) and without them (the group rule, now for the rows of Fair Fast Travel too:
-- backpack and guide). coop_economy_core / _group / _travel on a host and two clients with stub engines. Not shipped.
dofile("tests/lua/support/harness_economy.lua")

local SPLIT = false
-- the rows Fair Fast Travel (game_fast_travel.parse_trip_tokens) puts in front of a destination
local STRINGS = {
	st_pda_fast_travel_to = "Fast travel to",
	st_pda_backpack_travel_to = "Backpack travel to",
	st_fftd_mapspot_guideto = "Hire guide to",
}
local TRAVEL_H = 1
local TRAVEL_MIN = TRAVEL_H * 60

local function row(text)
	return { GetSelectedItem = function() return { GetTextItem = function() return { GetText = function() return text end } end } end }
end

local function stubs(W)
	W.game.translate_string = function(id) return STRINGS[id] or id end
	W.coop.levels = { split = function() return SPLIT end }
	W.ChangeLevel = function(pos, lvid, gvid, dir, anim) W.CHANGED = { pos = pos, gvid = gvid } end
	W.STOCK_CHANGE = W.ChangeLevel
	W.game_graph = function() return { vertex = function(_, gv) return { level_id = function() return gv end } end } end
	local sim = W.alife
	W.alife = function()
		local s = sim()
		s.level_name = function(_, id) return id == 10 and "l01" or "l02" end
		return s
	end
	-- the map's property menu: every travel row moves the actor and costs an hour
	W.pda = {
		property_box_clicked = function(ui)
			local prop = ui:GetSelectedItem():GetTextItem():GetText()
			if prop == "Open" then return end
			-- the end of a trip in Fair Fast Travel: a destination not online here is a level change (game_fast_travel, trip.dest.online)
			if prop == "Fast travel to Quick pin" or prop == "Fast travel to Far pin" then
				W.level.change_game_time(0, TRAVEL_H, 0)
				W.ChangeLevel(vec(120, 0, 7), 5, prop == "Fast travel to Quick pin" and 10 or 20, nil, true)
				return
			end
			W.level.change_game_time(0, TRAVEL_H, 0)
			W.db.actor:set_actor_position(vec(500, 0, 500))
			W.TRAVELLED = (W.TRAVELLED or 0) + 1
		end,
	}
	W.dialogs_mlr = { marsh_post_guid = function() W.db.actor:set_actor_position(vec(-294, 0, 21)) W.GUIDED = (W.GUIDED or 0) + 1 end }
	W.ka_travel = { travel_to_zaton = function() W.level.change_game_time(0, 3, 10) W.KA = true end }
end

local function setup(nclients)
	PLAYERS = { [0] = { nick = "host", proxy = 0 } }
	local nicks = { "anna", "boris" }
	for i = 1, nclients do PLAYERS[i] = { nick = nicks[i], proxy = 500 + i } end
	POS = {}
	for p in pairs(PLAYERS) do POS[p] = { x = p * 2, y = 0, z = 0 } end
	QUEUE, WORLDS = {}, {}
	for p in pairs(PLAYERS) do
		local W = make_world(p)
		stubs(W)
		for q, info in pairs(PLAYERS) do
			local lid = (p == 0) and info.proxy or (info.proxy == 0 and PLAYERS[p].proxy or (info.proxy == PLAYERS[p].proxy and 0 or info.proxy))
			add_entity(W, lid, "coop_player_avatar", nil, POS[q])
		end
	end
	for _, W in pairs(WORLDS) do
		for _, n in ipairs({ "coop_economy_core", "coop_economy_group", "coop_economy_travel" }) do load_script(W, n) end
		for _, n in ipairs({ "coop_economy_core", "coop_economy_group", "coop_economy_travel" }) do
			if W[n].on_game_start then W[n].on_game_start() end
		end
	end
	POS[0] = { x = 3, y = 0, z = 0 }
	return WORLDS[0], WORLDS[1], WORLDS[2]
end

-------------------------------------------------------------------------------
section("split levels: the rows of the map menu need nobody gathered")
do
	SPLIT = true
	local H, A, B = setup(2)
	check(A.coop_economy_group.party_fast_travel() == true, "the rule itself is still on")
	check(A.coop_economy_group.travel_as_group() == false, "with split levels a travel is not a group travel")
	POS[2] = { x = 300, y = 0, z = 0 } -- boris is far (and on another map)
	local hx = POS[0].x
	A.pda.property_box_clicked(row("Fast travel to Bar (1.2 km)"))
	check(A.TRAVELLED == 1 and POS[1].x == 500, "fast travel: the traveller goes")
	check(not has(A.TIPS, "boris"), "no tip about a player who is far")
	deliver_all()
	check(POS[0].x == hx and POS[2].x == 300, "nobody follows (the others are on their own maps)")
	check(H.CLOCK == 0, "a solo travel does not move the shared clock")
	for _, s in ipairs(A.SENT) do check(s.name ~= "economy.tp", "no group teleport is sent") end

	A.TRAVELLED = nil
	A.pda.property_box_clicked(row("Backpack travel to Stash (80 m)"))
	check(A.TRAVELLED == 1, "backpack travel (Fair Fast Travel): alone too")
	A.TRAVELLED = nil
	A.pda.property_box_clicked(row("Hire guide to Bar (1.2 km)"))
	check(A.TRAVELLED == 1, "a guide hired through the map menu: alone too")

	-- the stock guides of the marsh and of the other levels
	B.dialogs_mlr.marsh_post_guid()
	check(B.GUIDED == 1 and POS[2].x == -294, "marsh guide: alone")
	deliver_all()
	check(POS[0].x == hx and POS[1].x == 500, "the others stay where they are")
	A.ka_travel.travel_to_zaton()
	deliver_all()
	check(A.KA == true and A.REFUSED_CGT == 0, "guide to another level: the call goes through the host, not the engine")
	check(H.CLOCK == 0, "and a solo guide trip moves no shared clock either")
	check(not has(A.TIPS, "boris") and not has(B.TIPS, "anna") and not has(H.TIPS, "anna"), "nobody was told to gather")

	-- the host travels as well
	POS[2] = { x = 300, y = 0, z = 0 }
	H.pda.property_box_clicked(row("Fast travel to Bar"))
	check(H.TRAVELLED == 1 and not has(H.TIPS, "boris") and not has(H.TIPS, "anna"), "the host goes alone with split levels")
end

-------------------------------------------------------------------------------
section("no split levels: the group rule holds for backpack and guide rows as for fast travel")
do
	SPLIT = false
	local H, A, B = setup(2)
	check(A.coop_economy_group.travel_as_group() == true, "a travel is a group travel")
	POS[2] = { x = 300, y = 0, z = 0 }
	for _, text in ipairs({ "Fast travel to Bar (1 km)", "Backpack travel to Stash (80 m)", "Hire guide to Bar (1.2 km)" }) do
		A.TRAVELLED, A.TIPS = nil, {}
		A.pda.property_box_clicked(row(text))
		check(A.TRAVELLED == nil and has(A.TIPS, "boris"), text .. ": not gathered, refused, the far player named")
	end
	POS[2] = { x = 6, y = 0, z = 0 }
	H.CLOCK = 0
	A.pda.property_box_clicked(row("Hire guide to Bar (1.2 km)"))
	check(A.TRAVELLED == 1 and POS[1].x == 500, "gathered: the guide takes the traveller")
	check(A.REFUSED_CGT == 0, "the clock call goes to the host instead of the engine")
	deliver_all()
	check(H.CLOCK == TRAVEL_MIN and math.abs(POS[0].x - 500) < 1 and math.abs(POS[2].x - 500) < 1,
		"the host moved the clock once and the group followed (" .. H.CLOCK .. ")")
	H.NOW = H.NOW + 20000
	for _, W in pairs(WORLDS) do W.NOW = H.NOW end
	POS[0], POS[2] = { x = 3, y = 0, z = 0 }, { x = 6, y = 0, z = 0 }
	A.db.actor:set_actor_position(vec(0, 0, 0))
	A.pda.property_box_clicked(row("Backpack travel to Stash (80 m)"))
	deliver_all()
	check(math.abs(POS[0].x - 500) < 1 and math.abs(POS[2].x - 500) < 1, "the group follows a backpack travel")
	A.TRAVELLED = nil
	A.pda.property_box_clicked(row("Open"))
	check(A.TRAVELLED == nil, "an entry that is no travel passes through")
end

-------------------------------------------------------------------------------
section("a build without the Fair Fast Travel strings")
do
	SPLIT = false
	local H, A = setup(1)
	for _, W in pairs(WORLDS) do W.game.translate_string = function(id) return id end end
	POS[1] = { x = 300, y = 0, z = 0 }
	A.pda.property_box_clicked(row("Hire guide to Bar"))
	check(A.TRAVELLED == 1 and #A.TIPS == 0, "untranslated ids recognise no row: the stock menu runs as it is")
end

-------------------------------------------------------------------------------
section("a quick pin of a client's own map: his copy of the world never brings it online, the stock asks for a level change")
for _, split in ipairs({ true, false }) do
	SPLIT = split
	local H, A = setup(1)
	A.pda.property_box_clicked(row("Fast travel to Quick pin"))
	check(A.CHANGED == nil, "no level change to the map he stands on: the engine has no level changer for it")
	check(POS[1].x == 120 and POS[1].z == 7, "he stands on the pin")
	check(A.ChangeLevel == A.STOCK_CHANGE, "the stock function is back after the click")
	deliver_all()
	if split then
		check(H.CLOCK == 0, "with split levels a solo travel moves no shared clock")
	else
		check(H.CLOCK == TRAVEL_MIN and math.abs(POS[0].x - 120) < 1, "with one level the group follows, the clock moved once")
	end
	A.NOW = A.NOW + 20000
	POS[0], POS[1] = { x = 3, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }
	A.pda.property_box_clicked(row("Fast travel to Far pin"))
	check(A.CHANGED and A.CHANGED.gvid == 20, "a point of another map stays a level change")
	check(POS[1].x == 2, "and he stays until it happens")
end

section("the same on the host: the stock's way, nothing replaced")
do
	SPLIT = false
	local H = setup(1)
	POS[1] = { x = 4, y = 0, z = 0 }
	H.pda.property_box_clicked(row("Fast travel to Quick pin"))
	check(H.CHANGED and H.CHANGED.gvid == 10, "the call reaches the stock function")
end

section("a click that fails: the stock function is back all the same")
do
	SPLIT = true
	local H, A = setup(1)
	A.STOCK_CHANGE = function() error("a stock error") end
	A.ChangeLevel = A.STOCK_CHANGE
	A.pda.property_box_clicked(row("Fast travel to Far pin"))
	check(has(A.LOG, "a stock error"), "(with_arm logs it)")
	check(A.ChangeLevel == A.STOCK_CHANGE, "ChangeLevel is the stock's")
end

-------------------------------------------------------------------------------
section("no session: single player")
do
	SPLIT = true
	local H = setup(0)
	H.ACTIVE = false
	H.pda.property_box_clicked(row("Hire guide to Bar"))
	check(H.TRAVELLED == 1 and #H.SENT == 0, "single player: as the stock, nothing sent")
end

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
