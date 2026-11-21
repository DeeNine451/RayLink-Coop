-- Live 2026-11-01 ("the host's profile could not ping"): a co-op host starts its session after its level is up
-- (coop_manager.cpp autostart waits for level_ready; the in-game Host comes later still, stand b57h: 15 s after the first
-- update), and coop_hud_ping set its default key F8 only at actor_on_first_update of a live session: the first world of
-- every co-op host's session had no ping key. A client's session runs before his level loads, but he goes live after his
-- precache frames (coop_join.cpp client_go_live). Single player never has a session and stays stock: no key.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
axr_main.callback_add("actor_on_net_destroy")

-- The keys: chat_team has no key, F8 does nothing (dik_to_bind answers as for F15, a key nobody binds).
local CHAT_TEAM, F8, F15, NO_ACTION = 77, 66, 102, 999
key_bindings = { kCHAT_TEAM = CHAT_TEAM }
DIK_keys = { DIK_F8 = F8, DIK_F15 = F15 }
local binds = {}
function dik_to_bind(dik) return binds[dik] or NO_ACTION end
function bind_to_dik(action)
	for dik, a in pairs(binds) do
		if a == action then return dik end
	end
	return 0
end
local console = {}
function exec_console_cmd(cmd)
	console[#console + 1] = cmd
	if cmd == "bind chat_team kF8" then binds[F8] = CHAT_TEAM end
end
-- exactly one "bind chat_team kF8" since the console had n0 lines
local function bound(n0)
	return #console == n0 + 1 and console[n0 + 1] == "bind chat_team kF8" and binds[F8] == CHAT_TEAM
end
-- the ping's world overlay (not this test's subject)
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base }) end
end
get_hud = function() return { AddDialogToRender = function() end, RemoveDialogToRender = function() end } end

-- The engine's phase is Off until the host starts hosting: no session while the level loads. A joining client's session
-- is active before he is live.
local hosting, joining = false, false
local is_active, is_live = coop.is_active, coop.is_live
coop.is_active = function() return hosting and is_active() end
coop.is_live = function() return not joining and is_live() end

start_all()
modes.install(coop_mode, mode)
local ping = load_script("coop_hud_ping")
ping.on_game_start()

-- Single player on the co-op exe: the world loads, plays, saves and loads, and no key is set.
SendScriptCallback("actor_on_first_update")
for _ = 1, 5 do
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
end
check(#console == 0 and binds[F8] == nil, "single player: no ping key")
SendScriptCallback("actor_on_net_destroy")
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")
check(#console == 0, "single player: no ping key at the next world either")

-- The co-op host: this world is up, then the session starts (b57h: first update 09:52:54, "phase off -> hosting" 09:53:09).
hosting = true
NOW = NOW + 15000
SendScriptCallback("actor_on_update") -- the first update after hosting starts
check(bound(0), "the co-op host gets the ping key F8 in the first world of its session")
local n0 = #console
binds = {} -- the player takes the key off in this world
for _ = 1, 3 do
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
end
check(#console == n0, "the key is set once a world, as before")
n0 = #console

-- The next world of the session: live at its first update, the key at once, as before.
SendScriptCallback("actor_on_net_destroy")
binds = {}
SendScriptCallback("actor_on_first_update")
check(bound(n0), "the next world of the session: the key at its first update, as before")
SendScriptCallback("actor_on_update")
check(#console == n0 + 1, "a key that is set is left as it is")

-- A client: his session runs before his level loads; he goes live after his precache frames.
SendScriptCallback("actor_on_net_destroy")
binds = {}
joining = true
n0 = #console
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")
if coop_mode.decides_world() then
	check(bound(n0), "the process that decides the world is live with its session: the key at the first update")
else
	check(#console == n0, "no key before this process is live")
end
joining = false
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
SendScriptCallback("actor_on_update")
check(bound(n0), "the key once this process is live, once")

-- F8 taken by another action: left as it is, also after the session starts.
SendScriptCallback("actor_on_net_destroy")
binds = { [F8] = 55 }
hosting = false
n0 = #console
SendScriptCallback("actor_on_first_update")
hosting = true
SendScriptCallback("actor_on_update")
check(#console == n0, "F8 taken by something else: no binding")
done("ping late session " .. mode)
