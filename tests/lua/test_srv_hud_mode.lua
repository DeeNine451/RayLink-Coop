-- The world server decides without a playing seat. Its player has reported map data for an offline friend's PDA spot.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local FRIEND, AVATAR = 2, 502
local is_world_server, is_map_server = false, false
local active = true
local rows = { { id = 1, is_self = true, avatar_id = 0, level = 1 },
	{ id = FRIEND, nick = "Scout", avatar_id = AVATAR, level = 2, elsewhere = true } }
coop.is_dedicated = function() return is_world_server end
coop.is_map_server = function() return is_map_server end
coop.is_active = function() return active end
coop.is_host = function() return active and is_world_server end
coop.is_world_server = coop.is_host
coop.is_client = function() return active and not is_world_server end
coop.is_player = function() return active and not is_world_server and not is_map_server end
coop.self_id = function() return active and (is_world_server and 0 or 1) or -1 end
coop.players = function()
	if not active then return {} end
	return is_world_server and { rows[2] } or rows
end
coop.levels = { split = function() return true end }
modes.live(facade, load_script)

local callbacks = {}
function RegisterScriptCallback(name, fn) callbacks[name] = fn end
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base, __call = function() return {} end }) end
end
local main = load_script("coop_main")
load_script("coop_allies")
coop_allies_map = { sync = function() end, is_ready = function() return false end }
local hud = load_script("coop_core_hud")
hud.on_game_start()

local player = make_actor(vec3(12, 3, -25))
player.health = 1
player.character_icon = function() return "" end
player.character_community = function() return "stalker" end
callbacks.actor_on_update()
local outgoing
for _, event in ipairs(SENT) do
	if event.name == "core.status" then outgoing = main.decode(event.payload) end
end
check(facade.where(0) == "away" and outgoing and tonumber(outgoing.x) == 12 and tonumber(outgoing.y) == 3
	and tonumber(outgoing.z) == -25, "a server player reports coordinates while the world seat is away")

spawn("stalker", vec3(0, 0, 0), nil, { id = AVATAR, offline = true })
main.on_event("core.status", main.encode({ h = 1, s = "alive", x = 14, y = 3, z = -25, l = 171, g = 82 }), FRIEND)
-- The map data becomes available after the HUD has already started.
coop_srv_levels = { elsewhere_text = function(peer) return peer == FRIEND and "On another map: Garbage" end }
local placed
coop.levels.far_place = function(...) placed = { ... } end
local friends = hud.views()
hud.place_far(friends)
check(friends[1] and friends[1].elsewhere == "On another map: Garbage" and friends[1].far_id == AVATAR,
	"the HUD reads the available level text through the server layer")
check(placed and placed[1] == AVATAR and placed[2] == 14 and placed[5] == 171 and placed[6] == 82,
	"the server layer updates the offline record with the reported place")

local trust = load_script("coop_trust")
trust.reset_for_test({ default = "log" })
local good_status = hud.status_of(FRIEND)
local refused_places = {
	{ x = math.huge, y = 3, z = 4, l = 171, g = 82 },
	{ x = 1, y = -1e9, z = 4, l = 171, g = 82 },
	{ x = 1, y = 3, z = 1e9, l = 171, g = 82 },
	{ x = 1, y = 3, z = 4, l = 1.5, g = 82 },
	{ x = 1, y = 3, z = 4, l = 4294967296, g = 82 },
	{ x = 1, y = 3, z = 4, l = 171, g = 1.5 },
	{ x = 1, y = 3, z = 4, l = 171, g = 65535 },
	{ x = 1, y = 3, l = 171, g = 82 },
}
for i, t in ipairs(refused_places) do
	t.h, t.s = 0.75, "alive"
	-- Use an overflowing numeric value that the wire decoder can represent.
	if t.x == math.huge then t.x = "1e999" end
	main.on_event("core.status", main.encode(t), FRIEND)
	local st = hud.status_of(FRIEND)
	placed = nil
	hud.place_far(friends)
	check(st ~= good_status and st.h == 0.75 and st.x == nil and st.g == nil and placed == nil,
		"malformed place #" .. i .. " cannot move the offline record in trust log mode")
end
check(log_has("core.status") ~= nil, "malformed status places are reported to trust")
local failed_status = trust.status()["core.status"] and trust.status()["core.status"].failed or 0
main.on_event("core.status", main.encode({ h = 1, s = "alive" }), 256)
check(not hud.status_of(256) and trust.status()["core.status"] and trust.status()["core.status"].failed == failed_status + 1,
	"a map bridge address cannot be used as a player status slot")

local ping = load_script("coop_hud_ping")
local function request_ping(from, t)
	ping.on_req(main.encode(t), from)
end
local function relay_ping(from, t)
	ping.on_ping(main.encode(t), from)
end
level.name = function() return "l02_garbage" end
local n = #ping.active()
relay_ping(0, { p = FRIEND, n = 1, l = "l02_garbage", x = 7, y = 1, z = 8 })
check(#ping.active() == n + 1, "a server player sees the world server's valid relay for this map")
relay_ping(0, { p = FRIEND, n = 2, l = "l03_agroprom", x = 7, y = 1, z = 8 })
check(#ping.active() == n + 1, "a server player ignores the world server's valid relay for another map")

is_map_server = true
local char = load_script("coop_menu_char")
local faction_starts = char.faction_starts
char.faction_starts = function()
	return { { id = "l02_garbage", x = 7, y = 1, z = 8, lvid = 171, gvid = 82 } }
end
function game_graph()
	return {
		valid_vertex_id = function() return true end,
		vertex = function(_, id) return { level_id = function() return id == 82 and 2 or 1 end } end,
	}
end
player.game_vertex_id = function() return 15 end
local start = char.host_start("stalker")
check(start and start.gvid == 82, "a map server ghost sees the faction start on another map")
is_map_server = false

is_world_server = true
local command
function exec_console_cmd(cmd) command = cmd end
local world = load_script("coop_core_player")
check(facade.decides_world() and not facade.seat_plays(0), "the world server decides with no playing seat")
check(world.accept_transition() and command == "coop_accept_transition", "the server layer authorizes the world action")

local spawned = { id = AVATAR, section_name = function() return "coop_player_avatar" end,
	name = function() return "coop_player_avatar0502" end }
local spawn_marks = {}
function se_save_var(id, _, key, value) spawn_marks[id] = { [key] = value } end
function se_load_var(id, _, key) return spawn_marks[id] and spawn_marks[id][key] end
char.on_game_start()
active = false
callbacks.se_stalker_on_spawn(spawned)
check(not char.is_new(AVATAR), "the world server does not mark a loaded proxy as new before its session starts")
active = true
callbacks.se_stalker_on_spawn(spawned)
check(char.is_new(AVATAR), "a proxy spawned during the world session is marked as new")

local settings = load_script("coop_settings")
settings.on_game_start()
char.budget = function() return 1000 end
coop_game_settings = { creator = function() return { money = 200, bare = true } end }
local saves = load_script("coop_saves")
local menu = load_script("coop_menu")
local chat = load_script("coop_core_chat")
local sysline
chat.system = function(line) sysline = line end
local dialog = {
	IsShown = function() return true end, HideDialog = function() end, Show = function() end,
	input = { GetText = function() return "/go" end, SetText = function() end, CaptureFocus = function() end },
}
dialog.Close = chat.UICoopChat.Close
coop.has_host_rights = function() return active end
level.present = function() return true end

local function upvalue(f, want)
	for i = 1, math.huge do
		local name, value = debug.getupvalue(f, i)
		if name == want then return value end
		if name == nil then error("missing upvalue " .. want) end
	end
end

local settings_host = upvalue(callbacks.on_option_change, "host")
local transition = load_script("coop_hud_transition")
local fade = upvalue(transition.UICoopTransition.Frame, "fade_for_the_go")
local level_change
function SendScriptCallback(name)
	if name == "on_before_level_changing" then level_change = name end
end
level.add_pp_effector = function() end
local graph = load_script("coop_hud_netgraph")
local function netgraph_rows()
	local frame = {
		buckets = {}, rows = { {}, {}, {}, {} }, SetLabel = function() end, SetNumber = function() end,
		ShowRows = function(self, n) self.visible_rows = n end,
	}
	graph.UICoopNetgraph.Refresh(frame, NOW)
	return frame.visible_rows
end

active = false
check(char.join_spawn() == "faction_start", "the world server still picks a faction start before its session")
local planned = char.host_plan_character(FRIEND, "stalker", "", true)
check(planned.ok == false and planned.reason == "busy", "character planning is busy before the world session")
local made, why = char.host_make_character(FRIEND, 600, "stalker", "", true, true)
check(made == false and why == "busy", "character creation is busy before the world session")
local chosen, choice_why = char.host_choose_self("stalker", "")
check(chosen == false and choice_why == "busy", "character choice is busy before the world session")
local offers = sent_count("menu.char_offer")
check(char.host_offer_self() == false and sent_count("menu.char_offer") == offers, "no character offer before the world session")
local replies = sent_count("menu.char_result")
main.on_event("menu.new_character", main.encode({ faction = "stalker", buy = "" }), 0)
check(sent_count("menu.char_result") == replies, "no character request is handled before the world session")
local snapshots = sent_count("coop_set")
main.on_event("coop_set_req", "", FRIEND)
check(sent_count("coop_set") == snapshots, "no settings request is handled before the world session")
settings_host.dirty = false
callbacks.on_option_change()
check(not settings_host.dirty, "an option callback before the session does not dirty the session's baseline")
LOG = {}
settings.print_status()
saves.print_status()
check(not log_has("host: baseline"), "inactive settings diagnostics omit the session host baseline")
check(log_has("saves: session no, host no") ~= nil, "inactive saves diagnostics report no host")
command = nil
chat.UICoopChat.OnCommit(dialog)
check(command == nil and sysline ~= nil, "the inactive world process explains the /go refusal")
local close = { session_at_open = false, IsShown = dialog.IsShown, HideDialog = dialog.HideDialog, Show = dialog.Show }
local returned = false
close.owner = { ShowDialog = function() returned = true end, Show = function() end }
menu.UICoopMenu.Close(close)
check(command == nil and returned, "closing before the session returns to the owner menu")
fade(true)
check(level_change == nil, "the fade does not notify the world of a level change before its session")
check(netgraph_rows() == 3, "refresh before the world session uses the non-host network rows")
local relays = sent_count("core.ping")
request_ping(FRIEND, { l = "l02_garbage", x = 7, y = 1, z = 8 })
check(sent_count("core.ping") == relays, "the world process does not relay requests while the session is off")

active = true
NOW = NOW + 2050
relays, snapshots = sent_count("core.ping"), sent_count("coop_set")
char.faction_starts = faction_starts
callbacks.on_option_change()
check(settings_host.dirty, "an option callback in the world session dirties the session's baseline")
settings.print_status()
saves.print_status()
check(log_has("host: baseline") and log_has("saves: session yes, host yes"), "live diagnostics report world authority")
returned = false
menu.UICoopMenu.Close(close)
check(command == "main_menu off" and not returned, "closing after the world session starts ends the stale menu")
fade(true)
check(level_change == "on_before_level_changing", "the fade notifies the active world of the level change")
check(netgraph_rows() == 4, "refresh in the world session uses the host network rows")

trust.reset_for_test({ default = "log" })
main.on_event("coop_set_req", "x=n1", FRIEND)
check(sent_count("coop_set") == snapshots and log_has("coop_set_req"), "settings request requires an empty body even in trust log mode")
main.on_event("coop_set_req", "", 19)
check(sent_count("coop_set") == snapshots, "a sender without a playing seat gets no settings")
main.on_event("coop_set_req", "", FRIEND)
local snapshot, packet = sent("coop_set")
check(snapshot and snapshot._t == "full" and packet.target == FRIEND, "a listed server player gets the settings requested")
snapshots = sent_count("coop_set")
LOG = {}
main.on_event("coop_set_req", "", FRIEND)
check(sent_count("coop_set") == snapshots and log_has("coop_set_req"), "settings rate refusal is counted in trust log mode")
coop.levels.map_servers = function() return { { bridge = 0x101 } } end
LOG = {}
main.on_event("coop_set_req", "", 0x102)
check(sent_count("coop_set") == snapshots and log_has("coop_set_req"), "an unknown bridge gets no settings")
main.on_event("coop_set_req", "", 0x101)
snapshot, packet = sent("coop_set")
check(snapshot and snapshot._t == "full" and packet.target == 0x101, "a registered map server gets the settings it requested")

LOG = {}
request_ping(FRIEND, { l = "l02/g\narbage", x = 7, y = 1, z = 8 })
check(sent_count("core.ping") == relays and log_has("core.ping_req"), "a malformed map tag is reported and dropped by the world server")
request_ping(19, { l = "l02_garbage", x = 7, y = 1, z = 8 })
check(sent_count("core.ping") == relays, "a sender without a seat cannot post a ping in the world session")
request_ping(FRIEND, { l = "l03_agroprom", x = 7, y = 1, z = 8, p = 99 })
local published = sent("core.ping")
check(published and published.p == FRIEND and published.l == "l03_agroprom",
	"the world relays a ping for another map with the transport's author")

LOG = {}
main.on_event("menu.new_character", main.encode({ faction = "stalker", buy = "" }), 0)
check(log_has("menu.new_character"), "the dedicated world's non-playing seat cannot choose a character")
replies = sent_count("menu.char_result")
main.on_event("menu.new_character", main.encode({ faction = "stalker", buy = "" }), 256)
check(sent_count("menu.char_result") == replies, "an address outside the player slots gets no character reply")

done("srv_hud_mode")
