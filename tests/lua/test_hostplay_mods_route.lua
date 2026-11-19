-- A player's request reaches the co-op host's loaded map directly.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
make_actor()
start_all()
local got
coop_mods_core.on("lvl_req", function(t, from) got = { t = t, from = from } end, "host")
coop_main.on_event("mods.lvl_req", coop_main.encode({ a = 6 }), 2)
check(got and got.from == 2 and got.t.a == 6 and #SENT == 0, "a co-op player's request runs directly on the host")
done("CO-OP MODS ROUTE")
