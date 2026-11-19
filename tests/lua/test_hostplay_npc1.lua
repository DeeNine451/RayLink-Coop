-- The playing host uses the shared NPC player helpers on the group's map.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
local H = machine("host", 0, { [0] = 0, [1] = 500 })
local E = H.env
modes.live(load_script(H, "coop_mode"), function(name) return load_script(H, name) end)
load_script(H, "coop_trust")
local P = load_script(H, "coop_npc_players")

local avatar = H.add(make_obj(500, 10))
check(P.player(1).here, "the connected character is here")
check(#P.everyone() == 2 and P.nearest(avatar:position()):id() == 500, "both players count on the shared map")

local calls, sender, claimed = 0
P.on("test.npc1", function(t, from)
	calls, sender, claimed = calls + 1, from, t._peer
end, "host")
H.handlers["test.npc1"][1](P.encode({ _peer = 17 }), 1)
check(calls == 1 and sender == 1 and claimed == nil, "only the transport supplies the sender")
H.handlers["test.npc1"][1](P.encode({}), 256)
check(calls == 1, "bridge IDs are outside the player sender range")
local checked = E.coop_trust.status().npc_level_sender
check(checked and checked.checked == 2 and checked.failed == 1, "request sender checks pass through coop_trust")

print(("%d passed, %d failed"):format(PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
