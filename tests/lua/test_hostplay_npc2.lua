-- The playing host keeps local encounter state without a server share transport.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

reset_world()
local H = machine("host", 0, { [0] = 0, [1] = 500 })
local E = H.env
local function load(name) return load_script(H, name) end
modes.live(load("coop_mode"), load)
load("coop_npc_players")
local trust = load("coop_trust")
load("coop_mods_core")
local quests = load("coop_quests_core")
quests.share = nil -- consumers use the facade over the registry, without the old convenience wrapper
local arena = load("coop_arena")
arena.on_game_start()
load("coop_encounters").on_game_start()

local shared = quests.shared()
check(shared.up.arena_ledger ~= nil and shared.down.arena_ledger ~= nil, "the arena keeps its ledger providers at startup")
check(shared.down.guarded ~= nil and shared.down.encounters ~= nil, "the encounter rule keeps its providers at startup")
check(shared.up.arena_point ~= nil and shared.up.arena_point.every == 30000, "the arena point keeps its 30-second interval")
check(#H.sent == 0, "the co-op host needs no transport for these providers")

trust.reset_for_test({ default = "log" })
local key = string.format("%064x", 500)
H.add(make_obj(500, 0, 0, 0, { _section = "coop_player_avatar",
	_spawn_ini = make_ini({ coop = { { "key", key } } }) }))
local row = { items = {}, kit = {} }
arena._state().ledger["500:" .. key] = row
local function tell_kit(i, from)
	for _, handle in ipairs(H.handlers["arena.kit"]) do
		handle(E.coop_main.encode({ i = i, _peer = 2 }), from)
	end
end
tell_kit("701", 1)
tell_kit("1,65534", 1)
check(table.concat(row.kit, ",") == "701,1,65534", "the host records valid kit IDs against the transport's player")
local invalid_kits = {
	{ "702,65535", "reserved ID" }, { "702,0", "zero ID" }, { "702,65536", "out-of-range ID" },
	{ "702,1.5", "fractional ID" }, { "702,-1", "negative ID" }, { "702x703", "non-CSV delimiter" },
	{ "702,,703", "empty field" }, { ",702", "leading comma" }, { "702,", "trailing comma" },
	{ "", "empty list" }, { 702, "number instead of CSV" }, { nil, "missing list" },
	{ string.rep("1,", 256) .. "1", "too many IDs" },
	{ string.rep("0", 1536) .. "1", "oversized CSV" },
}
for _, invalid in ipairs(invalid_kits) do
	row.kit = { 701, 1, 65534 }
	tell_kit(invalid[1], 1)
	check(table.concat(row.kit, ",") == "701,1,65534", "the host leaves the whole kit intact after " .. invalid[2])
end
row.kit = { 701, 1, 65534 }
tell_kit("702", 2)
check(table.concat(row.kit, ",") == "701,1,65534", "a sender without a character cannot change the kit")
local audit = trust.status()["arena.kit"]
check(audit and audit.checked == #invalid_kits + 3 and audit.failed == #invalid_kits + 1 and audit.refused == 0,
	"the kit validation audits every request and hard-drops an invalid request in log mode")

print(string.format("%d passed, %d failed", PASSES, FAILS))
