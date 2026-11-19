-- Test answer set "hostplay" for the facade coop_mode (docs\MODES.md section 4): the co-op host's process. It plays,
-- everybody is on its map, it decides the world and every player's character. Fixed answers: a Core test asks the
-- facade and gets these, whatever the coop.* stubs say. tests\lua\support\modes.lua installs it (COOP_LUA_MODE).
-- Not shipped.
return {
	name = "hostplay",
	set = "hostplay",
	applies = function() return true end,
	where = function(peer) return "here" end,
	decider = function(peer) return "this" end,
	actor_is_player = function() return true end,
	decides_world = function() return true end,
	leads_here = function() return true end,
	is_player_mirror = function() return false end,
	seat_plays = function(peer) return true end,
	group_travels = function() return true end,
	publish_to = function(verb) return -1 end,
	from_level = function() return false end,
	level_request = function(name, payload, from) return "here", payload, from, false end,
}
