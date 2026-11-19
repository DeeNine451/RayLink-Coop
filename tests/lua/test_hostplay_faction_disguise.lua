-- Anomaly Coop test (build 56, live 2026-11-18): a client in a disguise keeps it when the host's faction word comes after
-- his load (coop_faction.client_apply). The stock's update_default(comm, now) sets the community at once only with `now` or
-- when the player is not disguised (G.A.M.M.A. gameplay_disguise.script:181-193). Not shipped.
-- Run: tools\test_lua.cmd hostplay_faction_disguise
dofile("tests/lua/support/harness_faction.lua")

local modes = dofile("tests/lua/support/modes.lua")

local function load_modes(M)
	local facade = load_script(M, "coop_mode")
	modes.live(facade, function(name) return load_script(M, name) end)
	load_script(M, "coop_trust")
	-- Faction tests exercise the real handlers with the Dev 57 trust default.
	M.env.coop_trust.reset_for_test({ default = "log" })
end
SETUP_HOOK = load_modes


-- the disguise flag of the stand-in module (a file local, as in the stock)
local function set_disguised(M, v)
	local f = M.env.gameplay_disguise.is_actor_disguised
	for i = 1, 20 do
		local n = debug.getupvalue(f, i)
		if n == nil then break end
		if n == "is_disguised" then debug.setupvalue(f, i, v) return true end
	end
	return false
end

-------------------------------------------------------------------------------
section("group mode: a disguised client keeps his disguise when the group's faction is told")
do
	setup(false)
	-- anna's true faction is Loners, she wears a Bandit outfit (carried with her across the load: the flag is true)
	A.env.gameplay_disguise._test_load("stalker")
	A.storage_state.default_faction = "stalker"
	A.actor._comm = "actor_bandit"
	check(set_disguised(A, true), "the stand-in has the stock's disguise flag")
	-- the group is in Duty: the host's word after her load
	A.handlers.coop_fac(H.encode({ k = "sync", f = "dolg" }), 0, "coop_fac")
	check(A.env.get_actor_true_community() == "dolg" and A.storage_state.default_faction == "dolg", "her true faction becomes the group's")
	check(comm(A) == "actor_bandit", "her disguise community stays (" .. comm(A) .. ")")
	-- the group's faction is hers already: nothing to do, the disguise stays
	A.handlers.coop_fac(H.encode({ k = "sync", f = "dolg" }), 0, "coop_fac")
	check(comm(A) == "actor_bandit", "a word of her own faction leaves the disguise")
end

section("group mode: a client without a disguise moves at once")
do
	setup(false)
	A.env.gameplay_disguise._test_load("stalker")
	A.storage_state.default_faction = "stalker"
	set_disguised(A, false)
	A.handlers.coop_fac(H.encode({ k = "sync", f = "dolg" }), 0, "coop_fac")
	check(comm(A) == "actor_dolg" and A.env.get_actor_true_community() == "dolg", "his community is the group's at once (" .. comm(A) .. ")")
	-- the flag lost at a load (nil, an older build): the community is set as before
	setup(false)
	A.env.gameplay_disguise._test_load("stalker")
	A.actor._comm = "actor_bandit"
	set_disguised(A, nil)
	A.handlers.coop_fac(H.encode({ k = "sync", f = "dolg" }), 0, "coop_fac")
	check(comm(A) == "actor_dolg", "not known as disguised: the community is the group's (" .. comm(A) .. ")")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
