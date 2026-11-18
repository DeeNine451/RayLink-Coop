-- coop_trust.script: a failed check of a client's request is counted and logged; "log" lets it through, "refuse" refuses,
-- "off" does not run it (TZ v2 section 6.4: a new check runs one Dev build in "log"). Run: tools\test_lua.cmd trust
PASSES, FAILS = 0, 0
local function check(cond, text)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. text)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. text)
	end
end

local lines = {}
printf = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end

local function load_module(ini)
	ini_sys = ini
	local env = setmetatable({}, { __index = _G })
	local chunk = assert(loadfile("gamedata/scripts/coop_trust.script"))
	setfenv(chunk, env)
	chunk()
	return env
end

local function fake_ini(rows)
	return {
		section_exist = function(_, s) return rows ~= nil and s == "coop_trust" end,
		line_count = function() return #rows end,
		r_line_ex = function(_, _, i) return true, rows[i + 1][1], rows[i + 1][2] end,
	}
end

-- no ini section at all: the default is "log"
do
	lines = {}
	local t = load_module(fake_ini(nil))
	check(t.mode_of("anything") == "log", "without settings a check logs")
	check(t.pass("task_complete", true, "fine") == true, "a check that holds lets the request through")
	check(#lines == 0, "a check that holds writes nothing")
	check(t.pass("task_complete", false, "player %s, task %s", "tester", "t1") == true, "log: a failed check lets the request through")
	check(#lines == 1 and lines[1]:find("would be refused", 1, true) ~= nil and lines[1]:find("tester", 1, true) ~= nil,
		"log: it says what it would have refused and for whom")
	local c = t.status().task_complete
	check(c.checked == 2 and c.failed == 1 and c.refused == 0, "the counters: 2 checked, 1 failed, 0 refused")
end

-- refuse and off, per check
do
	lines = {}
	local t = load_module(fake_ini({ { "default", "log" }, { "mine", "refuse" }, { "take", "off" }, { "bad", "sometimes" } }))
	check(t.pass("mine", false, "no item") == false, "refuse: a failed check refuses")
	check(t.pass("mine", true, "has it") == true, "refuse: a check that holds still passes")
	check(t.status().mine.refused == 1, "refuse is counted")
	check(t.pass("take", false, "anything") == true and t.status().take == nil, "off: the check does not run and counts nothing")
	check(t.mode_of("bad") == "log", "a word that is no mode falls back to the default")
	check(#lines == 1 and lines[1]:find("refused", 1, true) ~= nil, "refuse writes one line")
end

-- a text that is no format, and a flood
do
	lines = {}
	local t = load_module(fake_ini(nil))
	check(t.pass("x", false, "100%% of %s", nil) == true, "a nil argument does not break the log line")
	check(t.pass("y", false, "bad %d", "not a number") == true, "a wrong format argument does not break the check")
	lines = {}
	for _ = 1, 200 do t.pass("flood", false, "again") end
	check(#lines == 8 + 3, "a check that fails 200 times writes 8 lines and then every 64th")
	lines = {}
	t.print_status()
	check(#lines == 3, "print_status: one line per check that ran")
end

-- the shipped settings: a new check starts in "log"
do
	local fh = io.open("gamedata/configs/mod_system_coop_trust.ltx", "r")
	check(fh ~= nil, "the settings file is shipped")
	if fh then
		local text = fh:read("*a")
		fh:close()
		check(text:find("%[coop_trust%]") ~= nil, "it has the section [coop_trust]")
		check(text:match("\ndefault%s*=%s*(%w+)") == "log", "the shipped default is log")
	end
end

print(string.format("trust: %d passed, %d failed", PASSES, FAILS))
