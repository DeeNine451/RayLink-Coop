-- Test answer set "none" for the facade coop_mode (docs\MODES.md section 4): no session, single player (the stock
-- game). It is no layer: tests\lua\support\modes.lua installs it by taking every layer out of the facade, which then
-- answers its own "none". This table is what those answers must be (test_mode_facade compares them). Not shipped.
return {
	name = "none",
	set = "none",
	applies = function() return true end,
	where = function(peer) return "away" end,
	decider = function(peer) return "nobody" end,
	actor_is_player = function() return true end,
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return false end,
	seat_plays = function(peer) return false end,
	group_travels = function() return false end,
	publish_to = function(verb) return nil end,
	from_level = function() return false end,
	level_request = function(name, payload, from) return "here", payload, from, false end,
}
