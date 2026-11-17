-- Complaint of build 54 (players, ordinary co-op): "a client with movement 101% runs faster than the host with 110%". The 101/110%
-- is only the outfit line; the speed that moves the actor is speed.script's product of every run / sprint modifier (outfit, load,
-- legs, weapon, skills, artefacts). coop_mods_speed writes one line per 30 s, only when it changed, with the actor's coefficients and
-- every modifier, on every machine that plays a character, so one session log shows why two players differ.
-- Run as client (default), host, server (a map server: no character) or sp (no session: no line).
local which = MODE_ARG or "client"
MODE = which == "server" and "host" or which
dofile("tests/lua/support/stubs_mods.lua")
if which == "server" then coop.is_map_server = function() return true end end

-- speed.script of G.A.M.M.A. (Teepo's fix): its tables are file locals, reachable only as upvalues.
local SPEED_SRC = [[
local speeds = {}
local sprint_modifiers = {}
local run_modifiers = {}
local not_first_update = true
local function actor_on_first_update()
	speeds[0] = 2.410000
	speeds[1] = 1.330000
	speeds[2] = 2.08000
	not_first_update = false
end
function on_game_start() RegisterScriptCallback("actor_on_first_update", actor_on_first_update) end
local function update_speeds()
	if not_first_update then actor_on_first_update() end
	local run_coef = 1
	for k, v in pairs(run_modifiers) do run_coef = run_coef * v end
	local sprint_coef = 1
	for k, v in pairs(sprint_modifiers) do sprint_coef = sprint_coef * v end
	db.actor:set_actor_run_coef(clamp(speeds[0] * run_coef, 1, 10))
	db.actor:set_actor_runback_coef(clamp(speeds[1] * run_coef, 1, 10))
	db.actor:set_actor_sprint_koef(clamp(speeds[2] * sprint_coef, 1, 10))
end
function add_speed(speed_key, speed_mult, is_sprint, force)
	if is_sprint then
		if force or not sprint_modifiers[speed_key] then sprint_modifiers[speed_key] = speed_mult update_speeds() return true end
		return false
	end
	if force or not run_modifiers[speed_key] then run_modifiers[speed_key] = speed_mult update_speeds() return true end
	return false
end
function remove_speed(speed_key)
	sprint_modifiers[speed_key] = nil
	run_modifiers[speed_key] = nil
	update_speeds()
end
]]
local src = SPEED_SRC
local real = os.getenv("GAMMA_SCRIPTS")
if real then
	local fh = io.open(real .. "\\speed.script", "r")
	if fh then src = fh:read("*a") fh:close() end
end
do
	local this = {}
	speed = this
	setmetatable(this, { __index = _G })
	local f = assert(loadstring(src, "@speed.script"))
	setfenv(f, this)
	f()
end

local actor = make_actor()
local sets = 0
local coef = { run = 2.41, sprint = 2.08 }
actor.set_actor_run_coef = function(_, v) sets = sets + 1 coef.run = v end
actor.set_actor_runback_coef = function(_, v) sets = sets + 1 end
actor.set_actor_sprint_koef = function(_, v) sets = sets + 1 coef.sprint = v end
actor.get_actor_run_coef = function() return coef.run end
actor.get_actor_sprint_koef = function() return coef.sprint end

start_all()
load_script("coop_mods_speed")
coop_mods_speed.on_game_start()
speed.on_game_start()
SendScriptCallback("actor_on_first_update")

speed.add_speed("outfit_speed", 1.10, false, true)
speed.add_speed("encumbrance", 0.84, false, true)
speed.add_speed("weapon_speed", 0.92, true, true)

local function lines()
	local out = {}
	for _, l in ipairs(LOG) do
		if l:find("[coop-mods] [speed] run ", 1, true) then out[#out + 1] = l end
	end
	return out
end
local function tick(ms)
	NOW = NOW + ms
	SendScriptCallback("actor_on_update")
end

print("== speed diagnostic (" .. which .. ")")
local plays = which == "client" or which == "host"

-- 1. nothing before 30 s; then one line with the coefficients and every modifier, keys sorted
for _ = 1, 29 do tick(1000) end
check(#lines() == 0, which .. ": no line before 30 s (" .. #lines() .. ")")
tick(1000)
local l = lines()
if plays then
	check(#l == 1, which .. ": one line after 30 s (" .. #l .. ")")
	local want = "[coop-mods] [speed] run 2.23 sprint 1.91 = run encumbrance 0.840 outfit_speed 1.100 | sprint weapon_speed 0.920"
	check(l[1] == want, which .. ": the line names the coefficients and every modifier (" .. tostring(l[1]) .. ")")
else
	check(#l == 0, which .. ": no line on a machine without a player character (" .. #l .. ")")
end

-- 2. nothing changed: no line in the next 30 s windows
for _ = 1, 65 do tick(1000) end
check(#lines() == (plays and 1 or 0), which .. ": no line while nothing changes (" .. #lines() .. ")")

-- 3. a change (BHS legs) shows at the next 30 s mark, not at once
speed.add_speed("bhs_speed_run", 0.875, false, true)
tick(100)
check(#lines() == (plays and 1 or 0), which .. ": a change waits for the next 30 s mark (" .. #lines() .. ")")
for _ = 1, 31 do tick(1000) end
l = lines()
if plays then
	check(#l == 2 and l[2]:find("bhs_speed_run 0.875", 1, true) ~= nil and l[2]:find("run 1.95 ", 1, true) ~= nil,
		which .. ": the changed line (" .. tostring(l[2]) .. ")")
end

-- 4. it only reads: the setters were not called by the diagnostic, the tables are as they were
local before = sets
for _ = 1, 70 do tick(1000) end
check(sets == before, which .. ": the diagnostic calls no setter (" .. sets - before .. ")")

-- 5. a failing foreign call does not throw into actor_on_update
actor.get_actor_run_coef = function() error("boom") end
speed.add_speed("af_peas", 1.05, false, true)
local ok, err = pcall(function() for _ = 1, 31 do tick(1000) end end)
check(ok, which .. ": a failing read does not throw (" .. tostring(err) .. ")")
if plays then
	l = lines()
	check(#l == 3 and l[3]:find("run ? ", 1, true) ~= nil and l[3]:find("af_peas 1.050", 1, true) ~= nil,
		which .. ": the line still comes, the failed value is '?' (" .. tostring(l[3]) .. ")")
end

-- 6. without speed.script there is nothing to read and nothing throws
speed = nil
ok, err = pcall(function() for _ = 1, 31 do tick(1000) end end)
check(ok, which .. ": no speed.script, no error (" .. tostring(err) .. ")")

done("speed diagnostic (" .. which .. ")")
