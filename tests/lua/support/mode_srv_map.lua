-- Test answer set "srv_map" for the facade coop_mode (docs\MODES.md section 4): a map server of the server mode
-- (-coop_mapserver). It leads its map and decides for the players on it, the world is the world server's (peer 0, a
-- seat that plays nobody); its own actor is a ghost. A player's request reaches it only through the world server, with
-- his peer in it (`_peer`); world data it changed goes to the world server. Fixed answers: a Core test asks the facade
-- and gets these, whatever the coop.* stubs say. Not shipped.
local function main()
	local m = rawget(_G, "coop_main")
	if m == nil then m = coop_main end
	return m
end

return {
	name = "srv",
	set = "srv_map",
	applies = function() return true end,
	where = function(peer) return peer == 0 and "away" or "here" end,
	decider = function(peer) return peer == 0 and "nobody" or "this" end,
	actor_is_player = function() return false end,
	decides_world = function() return false end,
	leads_here = function() return true end,
	is_player_mirror = function() return false end,
	seat_plays = function(peer) return peer ~= 0 end,
	group_travels = function() return false end,
	publish_to = function(verb) return 0 end,
	level_request = function(name, payload, from)
		if from ~= 0 then return "drop" end
		local m = main()
		local t = m.decode(payload)
		local peer = tonumber(t._peer)
		if not peer then return "drop" end
		t._peer = nil
		return "here", m.encode(t), peer, true
	end,
}
