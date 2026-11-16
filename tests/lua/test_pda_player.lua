-- Anomaly Coop: the PDA contacts a client has talked to are his own (coop_pda_player over coop_mods_pdata).
-- Run: tools\test_lua.cmd pda_player
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")

print("== contacts of the PDA (client)")
make_actor()
start_all()
local fixed = os.getenv("COOP_PDA_PLAYER_OFF") == nil
if fixed then
	load_script("coop_pda_player")
	coop_pda_player.on_game_start()
end

-- 1. first join: the host's save has the HOST's contacts, no record for this character
alife_storage_manager.CALifeStorageManager_load({ actor_contacts = { [700] = true, [710] = true } })
local m = alife_storage_manager.get_state()
check(m.actor_contacts == nil, "a new player does not get the host's list of contacts")

-- 2. he talks to a trader (pda.actor_menu_mode writes the key) and the report carries it
m.actor_contacts = { [720] = true }
SENT = {}
NOW = NOW + 20000
SendScriptCallback("actor_on_update")
local piece = sent("mods.pd")
local d = piece and coop_mods_core.deser(piece.d)
check(d and type(d.actor_contacts) == "table" and d.actor_contacts[720] == true, "his contacts are reported to the host")
coop_main.on_event("mods.pd_ack", coop_main.encode({ t = "TOK1" }), 0)

-- 3. level change: the host's save again; his own list comes back
alife_storage_manager.CALifeStorageManager_load({
	actor_contacts = { [700] = true, [710] = true },
	coop_mods_pdata = { ["500"] = { t = "TOK1", d = { actor_contacts = { [720] = true } } } },
})
m = alife_storage_manager.get_state()
check(m.actor_contacts and m.actor_contacts[720] == true and m.actor_contacts[700] == nil,
	"after a level change he has his own contacts, not the host's")

-- 4. single player untouched
MODE = "sp"
alife_storage_manager.CALifeStorageManager_load({ actor_contacts = { [700] = true } })
m = alife_storage_manager.get_state()
check(m.actor_contacts and m.actor_contacts[700] == true, "single player: the stock list")
done("PDA PLAYER")
