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

-- round 6 (S5 of the round 5 review): an always-on guard of data drops what fails in every mode; its line says "dropped", never
-- "would be refused: let through", and a guard without a text only counts
do
	lines = {}
	local t = load_module(fake_ini({ { "default", "log" }, { "g_off", "off" }, { "g_ref", "refuse" } }))
	check(t.guard("pda_id", true, "bad id") == true and #lines == 0, "guard: what holds passes, no line")
	check(t.guard("pda_id", false, "bad id %s", "x") == false, "guard, log mode: what fails is dropped")
	check(#lines == 1 and lines[1]:find("dropped", 1, true) ~= nil and lines[1]:find("would be refused", 1, true) == nil,
		"guard: the line says dropped: " .. tostring(lines[1]))
	check(t.guard("g_ref", false, "bad") == false, "guard, refuse mode: dropped the same")
	check(t.guard("g_off", false, "bad") == false and t.status().g_off == nil, "guard, off: not counted, still dropped")
	lines = {}
	for _ = 1, 50 do t.guard("pda_identity", false) end
	check(#lines == 0 and t.status().pda_identity.failed == 50, "guard without a text (an id reused in honest play): counted, no line")
	lines = {}
	t.print_status()
	local found = false
	for _, l in ipairs(lines) do if l:find("pda_identity [guard]", 1, true) and l:find("dropped 50", 1, true) then found = true end end
	check(found, "coop_status names a guard as one")
	-- the data guards of the personal PDA state and the helmet id use it, not pass
	for _, f in ipairs({ "coop_mods_pdata_pda", "coop_mods_misc" }) do
		local fh = assert(io.open("gamedata/scripts/" .. f .. ".script", "r"))
		local text = fh:read("*a")
		fh:close()
		check(not text:find('coop_trust.pass("pda_', 1, true) and not text:find('coop_trust.pass("mods_misc_helmet_id"', 1, true)
			and text:find("coop_trust.guard(", 1, true) ~= nil, f .. ": its data guards are coop_trust.guard")
	end
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
