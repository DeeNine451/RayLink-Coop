-- The S6 answers of the facade coop_mode (A-S6-IF, docs\contracts\coop_mode_api.md section 7): hook(name) (F-HOOK),
-- facts_of(peer) (F-BODY), far() (F-FAR), share_up / share_down (F-SHARE). One part per process kind: the co-op host, a
-- co-op client, the world server, a map server, a player of a server world, no session. The real layer scripts
-- (coop_hostplay_mode, coop_srv_mode) over the coop.* stubs, as axr_main installs them; the server's scripts the hooks name
-- are stand-ins put into _G here. Not shipped.
-- Run: tools\test_lua.cmd mode_s6_facade
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
local QC = load_script("coop_quests_core")
check(type(F.hook) == "function" and type(F.facts_of) == "function" and type(F.far) == "function"
	and type(F.share_up) == "function" and type(F.share_down) == "function", "the facade has the five S6 calls")

-- what the engine says
local S = {}
coop.is_active = function() return S.active end
coop.is_host = function() return S.host end
coop.is_client = function() return S.client end
coop.self_id = function() return S.self end
coop.players = function() return S.rows end
coop.is_map_server = function() return S.map_server end
coop.is_dedicated = function() return S.dedicated end
local function level_of_player(peer) return S.levels_of[peer] end
local function far_place() return true end
coop.levels = {
	split = function() return S.split end,
	bridge_of_player = function() return nil end,
	map_servers = function() return {} end,
	level_of_player = level_of_player,
	far_place = far_place,
	talking = function(peer) return S.talking[peer] == true end,
	talk_partner = function(peer) return S.partner[peer] end,
}
local function engine(t)
	S = { active = true, host = false, client = false, self = 0, rows = {}, map_server = false, dedicated = false,
		split = false, levels_of = { [1] = 7 }, talking = { [1] = true }, partner = { [1] = 0x55 } }
	for k, v in pairs(t) do S[k] = v end
end

-- the server's scripts the hooks name: stand-ins
local function may_take() return false end
local function client_may_write() return false end
local function sees_character() return true end
local function caches_now() end
local function elsewhere_text() return "On another map: Garbage" end
local SRV_LEVELS = { elsewhere_text = elsewhere_text, name = function() return "l02_garbage" end }
local FAR = { -- the server's far view without at_home: the facade's stub gives it
	in_scope = function() return { level = 7 } end,
	with_level_of = function(peer, fn, ...) return "far", fn(...) end,
}
rawset(_G, "coop_srv_storyline", { may_take = may_take, client_may_write = client_may_write })
rawset(_G, "coop_srv_task_audience", { sees_character = sees_character })
rawset(_G, "coop_srv_levels_brain", { caches_now = caches_now })
rawset(_G, "coop_srv_levels", SRV_LEVELS)
rawset(_G, "coop_srv_quests_far", FAR)
local GS = rawget(_G, "coop_game_settings")
if type(GS) ~= "table" then
	GS = { creator = function() return nil end }
	rawset(_G, "coop_game_settings", GS)
end

local NAMES = { "storyline.may_take", "storyline.client_may_write", "task_audience.sees_character", "brain.caches_now",
	"world.creator", "levels.elsewhere_text", "levels.far_place", "levels.module", "levels.level_of_player", "context" }

modes.live(F) -- the real layers, as axr_main installs them

local function no_hooks(kind)
	for _, n in ipairs(NAMES) do
		if F.hook(n) ~= nil then
			check(false, kind .. ": hook " .. n .. " is nil")
			return
		end
	end
	check(true, kind .. ": every hook is nil (no server's script)")
end

local function srv_hooks(kind, role)
	check(F.hook("storyline.may_take") == may_take and F.hook("storyline.client_may_write") == client_may_write,
		kind .. ": the storyline's two functions")
	check(F.hook("task_audience.sees_character") == sees_character, kind .. ": the task audience")
	check(F.hook("brain.caches_now") == caches_now, kind .. ": the brain")
	check(F.hook("world.creator") == GS.creator, kind .. ": the world's creator (coop_game_settings)")
	check(F.hook("levels.elsewhere_text") == elsewhere_text, kind .. ": the 'on another map' text")
	check(F.hook("levels.far_place") == far_place and F.hook("levels.level_of_player") == level_of_player,
		kind .. ": the engine's coop.levels functions")
	local module = F.hook("levels.module")
	check(type(module) == "function" and module() == SRV_LEVELS, kind .. ": the levels module, through a function")
	local context = F.hook("context")
	local c = context and context()
	check(type(c) == "table" and c.role == role and c.split == true, kind .. ": the context is " .. role .. ", split")
	check(F.hook("no.such") == nil and F.hook("") == nil and F.hook(5) == nil, kind .. ": an unknown name, a bad name: nil")
end

local function stub_far(kind)
	local far = F.far()
	check(far.in_scope() == nil and far.level_of_id(5) == nil and far.order(5, "kill") == false and far.object(5) == nil,
		kind .. ": the far view is the stub: no scope, nothing elsewhere")
	local a, b = far.with_level_of(1, function(x, y) return x + y, "here" end, 2, 3)
	check(a == 5 and b == "here", kind .. ": with_level_of runs here")
	check(far.with_target(9, 1, "kill", function(x) return x * 2 end, 4) == 8 and far.at_home(function() return 7 end) == 7,
		kind .. ": with_target and at_home run here")
	far.note_fail("t", {})
	far.print_status()
end

local function srv_far(kind)
	local far = F.far()
	local s = far.in_scope()
	check(type(s) == "table" and s.level == 7, kind .. ": the server's far view answers in_scope")
	local where, v = far.with_level_of(1, function(x) return x end, 9)
	check(where == "far" and v == 9, kind .. ": with_level_of is the server's")
	check(far.at_home(function() return 3 end) == 3 and far.order(1, "kill") == false,
		kind .. ": what the server's view lacks is the stub's")
	check(F.far() == far, kind .. ": one wrapper per view")
end

-- F-SHARE is kept in every process: the registrations come before a map server's layer answers
local function shares(kind)
	local before_up, before_down = 0, 0
	for _ in pairs(QC.shared().up) do before_up = before_up + 1 end
	for _ in pairs(QC.shared().down) do before_down = before_down + 1 end
	local get, set = function() return { 1 } end, function() end
	check(F.share_up(kind .. ".up", get, set, 500) == true and F.share_down(kind .. ".down", get, set) == true,
		kind .. ": share_up / share_down kept")
	check(QC.shared().up[kind .. ".up"].get == get and QC.shared().up[kind .. ".up"].every == 500
		and QC.shared().down[kind .. ".down"].set == set, kind .. ": in coop_quests_core, where the server's share reads them")
	check(F.share_up("", get, set) == false and F.share_up("x", nil, set) == false and F.share_down("x", get, 5) == false
		and F.share_up("x", get, set, -1) == false, kind .. ": a bad name, get, set or every: refused")
	local up, down = 0, 0
	for _ in pairs(QC.shared().up) do up = up + 1 end
	for _ in pairs(QC.shared().down) do down = down + 1 end
	check(up == before_up + 1 and down == before_down + 1, kind .. ": nothing else kept")
end

local function no_facts(kind)
	check(F.facts_of(1) == nil and F.facts_of(0) == nil, kind .. ": facts_of is nil (the body is read where it stands)")
end

print("== the co-op host")
engine({ host = true, self = 0, rows = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, avatar_id = 500 } } })
check(F.decides_world() and F.group_travels(), "the co-op layer answers")
no_hooks("co-op host")
no_facts("co-op host")
stub_far("co-op host")
shares("coophost")
local listened = function() end
F.far().add_death_listener("monster_on_death_callback", listened)
local list = QC.death_listeners("monster_on_death_callback")
check(list[#list] == listened, "co-op host: a death listener is kept by the Core (a server's relay would read it)")

print("== a co-op client")
engine({ client = true, self = 1, rows = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, avatar_id = 500 } } })
check(F.is_player_mirror() and F.group_travels(), "the co-op layer answers")
no_hooks("co-op client")
no_facts("co-op client")
stub_far("co-op client")
shares("coopclient")

print("== the world server (-coop_dedicated)")
engine({ host = true, dedicated = true, split = true, self = 0, rows = { { id = 1, level = 2, elsewhere = true } } })
check(F.decides_world() and not F.actor_is_player(), "the srv layer answers")
srv_hooks("world server", "host")
local facts = F.facts_of(1)
check(type(facts) == "table" and facts.talking == true and facts.partner == 0x55,
	"world server: his map server's facts: in a dialog, with NPC 0x55")
S.talking[1], S.partner[1] = false, nil
facts = F.facts_of(1)
check(facts.talking == false and facts.partner == false, "world server: no dialog: talking false, partner false (nobody)")
local talk_partner = coop.levels.talk_partner
coop.levels.talk_partner = nil
facts = F.facts_of(1)
check(facts.talking == false and facts.partner == nil, "world server: an engine that does not name the partner: nil")
coop.levels.talk_partner = talk_partner
S.partner[1] = 70000
check(F.facts_of(1).partner == nil, "world server: a partner id out of range is no partner")
check(F.facts_of(-1) == nil and F.facts_of(1.5) == nil and F.facts_of("1") == nil, "world server: a bad peer: nil")
srv_far("world server")
shares("world")
-- before its session (A-S4D): the srv layer answers from the process's start
engine({ active = false, host = false, dedicated = true, split = false, self = -1, rows = {} })
check(F.hook("storyline.may_take") == may_take and type(F.facts_of(1)) == "table", "world server before its session: srv")

print("== a map server")
engine({ client = true, map_server = true, split = true, self = 5,
	rows = { { id = 5, is_self = true, level = 2 }, { id = 1, level = 2, elsewhere = false, avatar_id = 700 } } })
check(F.leads_here() and not F.decides_world(), "the srv layer answers")
srv_hooks("map server", "mapserver")
no_facts("map server")
srv_far("map server")
shares("map")

print("== a player of a server world")
engine({ client = true, split = true, self = 1, rows = { { id = 1, is_self = true, level = 2, avatar_id = 0 } } })
check(F.is_player_mirror() and not F.group_travels(), "the srv layer answers")
srv_hooks("server player", "client")
no_facts("server player")
srv_far("server player")
shares("player")

print("== no session")
engine({ active = false })
check(not F.decides_world() and F.actor_is_player() and not F.group_travels(), "none answers")
no_hooks("none")
no_facts("none")
stub_far("none")
shares("none")

print("== a layer table without the S6 fields (a test set) is answered as none answers")
for _, name in ipairs({ "hostplay", "srv_world" }) do
	modes.install(F, name)
	check(F.hook("storyline.may_take") == nil and F.facts_of(1) == nil and F.far().in_scope() == nil,
		name .. " set: no hook, no facts, the stub's far view")
	check(not log_has("! " .. (name == "hostplay" and "hostplay" or "srv") .. ".hook"), name .. " set: no fault logged")
end
F.uninstall("hostplay")
F.uninstall("srv")

print("== a layer's wrong answer is replaced by none's and logged")
F.install({ name = "srv", applies = function() return true end, where = function() return "away" end,
	decider = function() return "nobody" end, actor_is_player = function() return false end,
	decides_world = function() return true end, leads_here = function() return false end,
	is_player_mirror = function() return false end, seat_plays = function() return false end,
	group_travels = function() return false end, from_level = function() return false end,
	publish_to = function() return -1 end, level_request = function(n, p, f) return "here", p, f, false end,
	hook = function() return 5 end, facts_of = function() return "talking" end, far = function() return 3 end })
LOG = {}
check(F.hook("context") == nil and F.facts_of(1) == nil and F.far().in_scope() == nil, "a number, a string: none's answers")
check(log_has("hook answer") ~= nil and log_has("facts_of answer") ~= nil and log_has("far answer") ~= nil, "each logged")
F.install({ name = "srv", applies = function() return true end, where = function() return "away" end,
	decider = function() return "nobody" end, actor_is_player = function() return false end,
	decides_world = function() return true end, leads_here = function() return false end,
	is_player_mirror = function() return false end, seat_plays = function() return false end,
	group_travels = function() return false end, from_level = function() return false end,
	publish_to = function() return -1 end, level_request = function(n, p, f) return "here", p, f, false end,
	hook = function() error("boom") end, facts_of = function() return { talking = "yes", partner = 1.5 } end,
	far = function() error("boom") end })
local f = F.facts_of(1)
check(F.hook("context") == nil and f.talking == nil and f.partner == nil and F.far().in_scope() == nil,
	"an error, a wrong field: none's answer, the field dropped")
F.uninstall("srv")

done("MODE_S6_FACADE")
