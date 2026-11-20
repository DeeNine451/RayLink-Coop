-- The playing host decides group travel, with its map loaded. Its HUD has no remote map placement hook.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
coop.is_world_server = function() return false end -- world authority comes from the active layer
local placed = 0
coop.levels = { far_place = function() placed = placed + 1 end }
modes.live(facade, load_script)

local command
function exec_console_cmd(cmd) command = cmd end
local player = load_script("coop_core_player")
check(facade.where(0) == "here", "the co-op host has the playing seat on its own map")
check(player.accept_transition() and command == "coop_accept_transition", "the co-op layer authorizes the local group move")

local main = load_script("coop_main")
load_script("coop_allies")
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base }) end
end
local hud = load_script("coop_core_hud")
hud.on_game_start()
main.on_event("core.status", main.encode({ h = 1, s = "alive", x = 12, y = 3, z = -25, l = 171, g = 82 }), 1)
hud.place_far({ { peer = 1, far_id = 500 } })
check(placed == 0, "the co-op layer keeps the engine's far placement out of the HUD")

local trust = load_script("coop_trust")
trust.reset_for_test({ default = "log" })
local ping = load_script("coop_hud_ping")
ping.on_game_start()
local char = load_script("coop_menu_char")
local function event(name, t, from)
	main.on_event(name, main.encode(t), from)
end
local function logged(name)
	local counts = trust.status()[name]
	return counts and counts.failed or 0
end

level.name = function() return "l01_escape" end
local packet = { x = 1, y = 2, z = 3, l = "l01_escape" }
event("core.ping_req", packet, 1)
local posted = sent("core.ping")
check(posted and posted.p == 1 and #ping.active() == 1, "a co-op client's valid request keeps one ping with the transport author")
event("core.ping_req", packet, 1)
check(sent_count("core.ping") == 1 and logged("core.ping_req") == 1, "the ping rate refusal goes through trust even in log mode")
NOW = NOW + 2000
for _, from in ipairs({ -1, 0, 1.5, 4294967295, 17 }) do
	local before = logged("core.ping_req")
	event("core.ping_req", packet, from)
	check(sent_count("core.ping") == 1 and logged("core.ping_req") == before + 1,
		"ping request rejects ineligible transport peer " .. from)
end

local tags = { true, "", "l01 escape", string.rep("a", 65) }
for i, tag in ipairs(tags) do
	NOW = NOW + 2000
	packet.l = tag
	local count, before = sent_count("core.ping"), logged("core.ping_req")
	event("core.ping_req", packet, 1)
	check(sent_count("core.ping") == count and logged("core.ping_req") == before + 1, "ping request drops malformed level tag #" .. i)
end
packet.l = "l01_escape"
NOW = NOW + 2000
packet.y = 1e9
local before = logged("core.ping_req")
event("core.ping_req", packet, 1)
check(logged("core.ping_req") == before + 1, "out-of-range ping coordinates are reported to trust")
packet.y = 2

local marked_reads = 0
function se_load_var(id) marked_reads = marked_reads + 1; return id == 0 end
local function check_choice(t, from, reason, label)
	local failures, replies = logged("menu.new_character"), sent_count("menu.char_result")
	event("menu.new_character", t, from)
	local reply = sent("menu.char_result")
	check(logged("menu.new_character") == failures + 1 and
		(reason and sent_count("menu.char_result") == replies + 1 and reply and reply.reason == reason
			or not reason and sent_count("menu.char_result") == replies), label)
end
check_choice({ faction = "stalker", buy = true }, 1, "items", "a non-string buy is refused and reported")
check_choice({ faction = "stalker", buy = string.rep("item,", 64) .. "item" }, 1, "items", "more than 64 requested purchases are refused and reported")
check_choice({ faction = "stalker", buy = "item,,other" }, 1, "items", "an empty entry is an invalid purchase list")
check_choice({}, 1, "items", "a payload without choice fields is refused and reported")
check_choice({ faction = "stalker", buy = string.rep("a", 65) }, 1, "items", "an oversized item name is refused and reported")
check_choice({ faction = string.rep("a", 65) }, 1, "faction", "an oversized faction field is refused and reported")
check_choice({ faction = "stalker" }, 16, "no_character", "a sender without a playing seat gets only the pre-existing no-character refusal")
check_choice({ faction = "stalker" }, 1.5, nil, "a fractional transport sender is refused before a reply")
check(marked_reads == 0, "malformed and unauthorized choices never inspect the character mark")
check_choice({ faction = "zombied", p = 0 }, 1, "not_new", "the transport player's choice checks his mark and keeps the world faction")

MODE = "client"
ping.clear()
packet.p, packet.n = 0, 123
event("core.ping", packet, 0)
check(#ping.active() == 1, "a co-op client shows a valid relay from the playing host")
for _, serial in ipairs({ 0, -1, 1.5, 4294967296, "1e999", false }) do
	packet.n = serial
	before = logged("core.ping")
	event("core.ping", packet, 0)
	check(#ping.active() == 1 and logged("core.ping") == before + 1, "ping relay drops invalid serial " .. tostring(serial))
end
packet.n, packet.p = 124, 4294967295
before = logged("core.ping")
event("core.ping", packet, 0)
check(#ping.active() == 1 and logged("core.ping") == before + 1, "ping relay drops the reserved author id")
packet.p = 17
before = logged("core.ping")
event("core.ping", packet, 0)
check(#ping.active() == 1 and logged("core.ping") == before + 1, "ping relay drops an author outside the player slots")
packet.p, packet.l = 0, true
before = logged("core.ping")
event("core.ping", packet, 0)
check(#ping.active() == 1 and logged("core.ping") == before + 1, "ping relay drops a non-string level tag")
packet.l = "l01_escape"
before = logged("core.ping")
event("core.ping", packet, 1)
check(#ping.active() == 1 and logged("core.ping") == before + 1, "ping relay requires the world transport sender")

MODE = "sp"
ping.on_ping(main.encode(packet), 0)
check(#ping.active() == 1, "no relay is accepted once a co-op session is off")

done("hostplay_hud_mode")
