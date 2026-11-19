-- Invalid claims are rejected under every set. Only a playing actor in a session can ask the engine.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local mode = load_script("coop_mode")
local claims = {}
coop.is_player = function() return true end -- the engine predicate is not the facade's answer
coop.checkpoint = {
	claim_tent = function(x, y, z, what) claims[#claims + 1] = what; return true end,
}
local checkpoints = load_script("coop_checkpoints")

for _, name in ipairs(modes.names()) do
	modes.install(mode, name)
	MODE = name == "none" and "sp" or "host"
	claims = {}
	make_actor(vec3(0, 0, 0))
	check(checkpoints.request("unknown", 0) == false and #claims == 0, name .. ": unknown claim is rejected")
	db.actor = nil
	checkpoints.request("tent", 0)
	run_time_events(0)
	check(#claims == 0, name .. ": without an actor the engine receives no claim")
	make_actor(vec3(0, 0, 0))
	local accepted = checkpoints.request("tent", 0)
	run_time_events(0)
	check(accepted == (name == "hostplay"), name .. ": only a playing actor in a session may claim")
	check(#claims == (name == "hostplay" and 1 or 0), name .. ": only a playing actor asks the engine")
end

done("SURV_CORE")
