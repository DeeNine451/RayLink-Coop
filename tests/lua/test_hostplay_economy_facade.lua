-- Co-op host with a playing seat: its own wait is allowed, and a client cannot report world loot as a map server.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")

PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "guest", proxy = 501 } }
POS = { [0] = vec(0), [1] = vec(3) }
local H, C = make_world(0), make_world(1)
for _, W in ipairs({ H, C }) do
	local facade = load_script(W, "coop_mode")
	modes.live(facade, function(name) return load_script(W, name) end)
	load_script(W, "coop_trust").reset_for_test({ default = "log" })
	W.game_setup = {
		world_itm_on = { [701] = "spot" }, world_itm_num = { spot = 4 }, world_itm_off = {},
		world_itm_info = {}, limited_uses = {}, try_spawn_world_item = function() end,
	}
	load_script(W, "coop_economy_core")
	load_script(W, "coop_economy_group").on_game_start()
	load_script(W, "coop_economy_world").on_game_start()
end
local core, group, trust = H.coop_economy_core, H.coop_economy_group, H.coop_trust
core.RULES.sleep_rule = "host"

local saved_roll = { coop_world_rolls = { [710] = { s = "ammo_9x19", n = 7 } } }
H.ACTIVE = false
fire(H, "load_state", saved_roll)
H.ACTIVE = true
check(H.coop_economy_world.roll_waiting(710), "the co-op host keeps the roll loaded before hosting")
local saved_ammo = add_item(H, 710, "ammo_9x19", 501)
tick(H, 1000)
check(saved_ammo.ammo == 7, "the co-op host applies the saved roll")

C.ACTIVE = false
fire(C, "load_state", saved_roll)
C.ACTIVE = true
local mirror_ammo = add_item(C, 710, "ammo_9x19", 0)
check(not C.coop_economy_world.roll_waiting(710), "the co-op client ignores pending rolls from its own save")
tick(C, 1000)
check(mirror_ammo.ammo == 30, "the co-op client waits for the host's roll")

local waited = false
group.request_skip("wait", 15, function() waited = true end)
check(waited, "the playing host can wait immediately with the host-only rule")
H.coop_main.on_event("economy.propose", CM_ENCODE({ t = 2, k = "wait", m = 15 }), 1)
local reply = last(H.SENT)
check(reply and reply.target == 1 and reply.name == "economy.verdict" and CM_DECODE(reply.payload).r == "host_only",
	"the co-op host still refuses a guest's wait with the host-only rule")

local forged = CM_ENCODE({ p = 1, id = 701, s = "ammo_9x19" })
H.coop_main.on_event("economy.loot_took", forged, 1)
check(H.game_setup.world_itm_on[701] == "spot", "a player cannot report a co-op pickup through the bridge event")
H.coop_main.on_event("economy.loot_took", forged, 0x101)
check(H.game_setup.world_itm_on[701] == "spot", "a bridge-numbered sender cannot release a co-op world spawn")
local counter = trust.status().economy_loot_took_sender
check(counter and counter.failed == 2, "both sender refusals are recorded through coop_trust in log mode")

local ammo = add_item(C, 702, "ammo_9x19", 0)
local host_ammo = add_item(H, 702, "ammo_9x19", 501)
local roll = CM_ENCODE({ id = 702, s = "ammo_9x19", n = 7 })
C.coop_main.on_event("economy.loot_roll", roll, 0)
check(ammo.ammo == 7, "the co-op client applies its host's world-loot roll")
H.coop_main.on_event("economy.loot_roll", roll, 0)
C.coop_main.on_event("economy.loot_roll", CM_ENCODE({ id = 702, s = "ammo_9x19", n = 9 }), 2)
check(host_ammo.ammo == 30 and ammo.ammo == 7, "the co-op host applies no received roll and its client accepts only peer zero")
local client_trust = C.coop_trust.status()
local host_roll_sender = trust.status().economy_loot_roll_sender
check(host_roll_sender and host_roll_sender.failed == 1, "co-op host records the roll refusal")
local client_roll_sender = client_trust.economy_loot_roll_sender
check(client_roll_sender and client_roll_sender.failed == 1, "co-op client records the non-host roll refusal")
C.coop_main.on_event("economy.loot_roll", CM_ENCODE({ id = 702, s = "ammo_9x19", n = 65536 }), 0)
check(ammo.ammo == 7, "an out-of-range roll cannot replace the co-op client's ammo count")
local roll_payload = client_trust.economy_loot_roll_payload
check(roll_payload and roll_payload.failed == 1, "co-op client records the out-of-range roll")

C.coop_main.on_event("economy.verdict_for", CM_ENCODE({ k = 1, ok = true, r = "", n = "" }), 0)
local verdict_sender = client_trust.economy_verdict_for_sender
check(verdict_sender and verdict_sender.failed == 1, "the co-op client records the refusal of a map-server vote verdict")

print(string.format("%d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
