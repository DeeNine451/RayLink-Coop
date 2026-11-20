-- S6: the playing host decides from its own map, and the far-view stub keeps relay registrations.
dofile("tests/lua/support/harness_quests.lua")

local host = machine("host", 0)
local mode = load_script(host, "coop_mode")
load_script(host, "coop_hostplay_mode").on_game_start()
local q = load_script(host, "coop_quests_core")
local trust = load_script(host, "coop_trust")
host.env.coop_quests_core = q
q.on_game_start()

host.players = { { id = 1, avatar_id = 501 } }
local avatar = host.new_obj(501, "coop_player_avatar", vec(1, 0, 0))
local function unexpected() error("co-op must not use a server's far view") end
q.set_part("far", { with_level_of = unexpected, fallback = unexpected })

check(mode.decides_world() and q.host_party() and q.avatar_obj(1) == avatar, "the co-op host uses its live avatar")
local ran = {}
q.register_host_action("box", function(from, t) ran[#ran + 1] = { from, t.b } end)
host.handlers["quests.act"](q.encode({ a = "box", b = 700, _peer = 2 }), 1)
check(#ran == 1 and ran[1][1] == 1 and ran[1][2] == 700, "the local box uses the transport player and no far view")
local act = host.handlers["quests.act"]
for _, from in ipairs({ 0, -1, 1.5, 17, 0x101, 0xffffffff }) do
	act(q.encode({ a = "box", b = 700, _peer = 1 }), from)
end
check(#ran == 1, "a non-player transport sender cannot act as the player named in the payload")
local sender = trust.status().quest_act_sender
check(sender and sender.failed == 6, "the co-op host accounts for each rejected sender")
for _, id in ipairs({ 0, -1, 700.5, 65535, "700" }) do
	act(q.encode({ a = "box", b = id }), 1)
end
check(#ran == 1, "the co-op host drops invalid box IDs before dispatch")
local fields = trust.status().quest_act_fields
check(fields and fields.failed == 5, "the co-op host accounts for each malformed box request")
local body = q.body_for_character(501)
local read, section = pcall(function() return body:section() end)
check(body:id() == 501 and read and section == nil,
	"the far-view stub lets the Core use its own record methods")

load_script(host, "coop_quests_missions").on_game_start()
local listeners = q.death_listeners("monster_on_death_callback")
local callbacks = host.callbacks.monster_on_death_callback
check(#listeners == 1 and #callbacks == 1 and listeners[1] == callbacks[1],
	"the mission registers one stock death callback and one relay listener")
check(type(q.shared().down.bribe) == "table", "co-op keeps the ceasefire registration in the Core")
check(host.handlers["quests.bribe_hit"] == nil, "co-op has no map-server ceasefire receiver")

do
	local opened = {}
	host.env.ui_pda_encyclopedia_tab = {
		is_unlocked_article = function(s) return opened[s] end,
		is_unlocked_note = function() return false end,
		unlock_article = function(s) opened[s] = true end,
		unlock_note = function() end,
	}
	host.players[1].nick = "Reader"
	host.players[2] = { id = 2, nick = "Witness" }
	load_script(host, "coop_quests_pda").on_game_start()
	fire(host, "actor_on_first_update")
	local announce = host.handlers["quests.ency"]
	local article = { s = "encyclopedia_mutants_boar", n = "Impostor" }
	announce(q.encode(article), 0x101)
	check(not opened[article.s] and #host.sent == 0,
		"the co-op host refuses an encyclopedia announcement from a bridge-shaped sender")
	announce(q.encode(article), 1)
	local told = host.sent[#host.sent]
	check(opened[article.s] and told and told.name == "quests.ency" and told.target == 2 and q.decode(told.payload).n == "Reader",
		"the co-op host announces the article with the player name from the transport")
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
