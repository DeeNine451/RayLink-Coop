-- Test answer set "srv_world" for the facade coop_mode (docs\MODES.md section 4): the world server of the server mode
-- (-coop_dedicated). It decides the world, has no player's map (its actor is a ghost on fake_start, it leads no map),
-- every player stands on a map server's map and that server decides for him. Its own seat (peer 0) plays nobody.
-- A player's request to the logic of his map is passed to the map server of his map (BRIDGE) with his peer in it.
-- Fixed answers: a Core test asks the facade and gets these, whatever the coop.* stubs say. Not shipped.
local BRIDGE = 0x101

local function main()
	local m = rawget(_G, "coop_main")
	if m == nil then m = coop_main end
	return m
end

return {
	name = "srv",
	set = "srv_world",
	bridge = BRIDGE,
	applies = function() return true end,
	where = function(peer) return "away" end,
	decider = function(peer) return peer == 0 and "nobody" or "other" end,
	actor_is_player = function() return false end,
	decides_world = function() return true end,
	leads_here = function() return false end,
	is_player_mirror = function() return false end,
	seat_plays = function(peer) return peer ~= 0 end,
	group_travels = function() return false end,
	publish_to = function(verb) return -1 end,
	level_request = function(name, payload, from)
		if type(from) ~= "number" or from == 0 then return "here", payload, from, false end
		local m = main()
		local t = m.decode(payload)
		t._peer = from
		return "pass", BRIDGE, m.encode(t)
	end,
}
