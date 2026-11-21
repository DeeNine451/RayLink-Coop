-- Anomaly Coop test (coop_mods_radio.script, Zone FM over the stock PDA radio ui_pda_radio_tab): the channel clock of
-- the world's decider reaches the players. The tab is the file the game loads (a G.A.M.M.A. override from GAMMA_SCRIPTS
-- or the review corpus, else the stock script), compiled after every unlocalizer section the game applies to it
-- (gamedata\configs\unlocalizers\*.ltx and the stand's configs\unlocalizers\*.ltx), as script_storage.cpp does.
-- Regression (sweep wf_unloc 2026-11-21, coop_mods_radio.script:535): the tab's path_radio_ch / path_radio_session are
-- main-chunk locals that no function captures and no unlocalizer lists, so find_local found nothing, install_fm logged
-- "Zone FM clock not reachable" and every machine played its own Zone FM, in both modes.
-- Not shipped. Run: tools\test_lua.cmd mods_radio_fm
local modes = dofile("tests/lua/support/modes.lua")
local unloc = dofile("tests/lua/support/unlocalize.lua")
local BS = string.char(92)
local total_passed, total_failed = 0, 0

local function read_all(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- The tab as the stand loads it: G.A.M.M.A.'s loose scripts first, then the review corpus, then stock Anomaly.
local TAB_PATH, TAB_SRC
do
	local gamma = os.getenv("GAMMA_SCRIPTS")
	for _, p in ipairs({ gamma and gamma ~= "" and (gamma .. BS .. "ui_pda_radio_tab.script") or false,
		"temp/review/corpus/merged/ui_pda_radio_tab.script", "../anomaly-ref/unpacked/scripts/ui_pda_radio_tab.script",
		"temp/stock_scripts/scripts/ui_pda_radio_tab.script" }) do
		local src = p and read_all(p)
		if src then TAB_PATH, TAB_SRC = p, src break end
	end
	assert(TAB_SRC, "ui_pda_radio_tab.script required (GAMMA_SCRIPTS, temp/review/corpus/merged or temp/stock_scripts/scripts)")
end

-- What every unlocalizer file the game reads lists for a script (section names compare lower case, as the engine's).
local function unlocalizer_names(script)
	local names, files = {}, 0
	local dirs = { "gamedata" .. BS .. "configs" .. BS .. "unlocalizers" }
	local gamma = os.getenv("GAMMA_SCRIPTS")
	if gamma and gamma ~= "" then dirs[#dirs + 1] = gamma .. BS .. ".." .. BS .. "configs" .. BS .. "unlocalizers" end
	for _, dir in ipairs(dirs) do
		local pipe = io.popen('dir /b "' .. dir .. BS .. '*.ltx" 2>nul')
		if pipe then
			for line in pipe:lines() do
				local src = read_all(dir .. BS .. (line:gsub("\r", "")))
				if src then
					files = files + 1
					local cur
					for l in (src .. "\n"):gmatch("([^\n]*)\n") do
						l = l:gsub("\r", ""):gsub(";.*$", "")
						local sec = l:match("^%s*%[([^%]]+)%]")
						if sec then
							cur = sec:lower()
						elseif cur == script then
							local key = l:match("^%s*([^=%s]+)")
							if key then names[key] = true end
						end
					end
				end
			end
			pipe:close()
		end
	end
	return names, files
end
local UNLOCAL, UNLOCAL_FILES = unlocalizer_names("ui_pda_radio_tab")
assert(UNLOCAL_FILES > 0, "no unlocalizer files read (gamedata\\configs\\unlocalizers)")

-- The channel folders the tab lists (stock ui_pda_radio_tab.script:31-34) and the files in them, as the engine lists them.
local FILES = {
	["radio" .. BS .. "_channel_1" .. BS] = { "c1_track_a.ogg", "c1_track_b.ogg", "c1_track_c.ogg" },
	["radio" .. BS .. "_channel_1_session" .. BS] = { "c1_ident_a.ogg", "c1_ident_b.ogg" },
	["radio" .. BS .. "_channel_2" .. BS] = { "c2_track_a.ogg", "c2_track_b.ogg" },
	["radio" .. BS .. "_channel_2_session" .. BS] = { "c2_ident_a.ogg" },
}
local KIND_TRACK, KIND_SESSION = 0, 1

-- Engine bits the tab's main chunk reads at load.
local function engine_bits()
	local base_ini = ini_file
	function ini_file(name)
		local o = base_ini(name)
		function o:r_float() return nil end -- plugins\radio_zone_fm.ltx: the tab falls back to 2 playlists
		return o
	end
	function game_ini() return { r_string_ex = function() return nil end } end
	utils_data = { collect_section = function() return {} end }
	CUIScriptWnd = {}
	function class(name) -- luabind: class "Name" (Base) defines Name in the calling script
		local env = getfenv(2)
		return function(base) env[name] = setmetatable({}, { __index = base }) end
	end
	for path, list in pairs(FILES) do SOUND_DIRS[path] = list end
end

-- The tab compiled the way the engine compiles it: unlocalized, in its own module table.
local function load_tab()
	local f = assert(loadstring(unloc.source(TAB_SRC, UNLOCAL), "@" .. TAB_PATH))
	local m = setmetatable({}, { __index = _G })
	rawset(_G, "ui_pda_radio_tab", m)
	setfenv(f, m)
	f()
	return m
end

-- mode: the coop.* stubs' MODE ("host", "client", "sp"); set and overrides: the facade's answers (modes.lua).
local function setup(set, overrides, mode)
	MODE = mode
	dofile("tests/lua/support/stubs_mods.lua")
	engine_bits()
	make_actor()
	load_script("coop_main") load_script("coop_mode")
	modes.install(coop_mode, set, overrides)
	load_script("coop_mods_core")
	coop_mods_core.on_game_start()
	local tab = load_tab()
	local fields = {}
	for k, v in pairs(tab) do fields[k] = v end
	-- axr_main starts the scripts by name: coop_mods_radio before ui_pda_radio_tab
	load_script("coop_mods_radio") coop_mods_radio.on_game_start()
	tab.on_game_start()
	return tab, fields
end

local function tick(ms)
	NOW = NOW + (ms or 1100)
	SendScriptCallback("actor_on_update")
end

local function file_of(snd) return snd and snd._name and snd._name:match("([^" .. BS .. "]+)$") end

-- What the tab plays on channel ch: kind, file name.
local function playing(tab, ch)
	local s = tab.radio_session[ch][tab.radio_session_now[ch]]
	if s and s:playing() then return KIND_SESSION, file_of(s) end
	local t = tab.radio_ch[ch][tab.radio_now[ch]]
	if t and t:playing() then return KIND_TRACK, file_of(t) end
	return nil
end

local function sent_fm(ch)
	for i = #SENT, 1, -1 do
		local s = SENT[i]
		if s.name == "mods.fm" then
			local t = coop_main.decode(s.payload)
			if ch == nil or tonumber(t.ch) == ch then return t, s end
		end
	end
	return nil
end

local function from_decider(t) coop_main.on_event("mods.fm", coop_main.encode(t), 0) end

local function same_clock(tab, ch, label)
	local kind, name = playing(tab, ch)
	local t, s = sent_fm(ch)
	check(kind ~= nil and t ~= nil and tonumber(t.k) == kind and t.n == name and s.target == -1,
		string.format("%s: channel %d sent to everybody: %s, the tab plays %s:%s", label, ch,
			t and (tostring(t.k) .. ":" .. tostring(t.n)) or "nothing", tostring(kind), tostring(name)))
end

local function the_real_tab(tab, label)
	check(#tab.radio_ch[1] == 3 and #tab.radio_session[1] == 2 and #tab.radio_ch[2] == 2 and #tab.radio_session[2] == 1,
		label .. ": the real tab listed the fixture's channel folders through its own paths")
	check(rawget(tab, "path_radio_ch") == nil and rawget(tab, "path_radio_session") == nil,
		label .. ": the tab's path tables stay main-chunk locals (no unlocalizer lists them, " .. TAB_PATH .. ")")
end

-- The process that decides the world (Co-op: the host; Server: the world server) sends what its clock plays.
local function decider(set, label)
	print("== " .. label .. ": the world's decider sends its Zone FM clock")
	local tab = setup(set, nil, "host")
	the_real_tab(tab, label)
	check(not log_has("Zone FM clock not reachable"), label .. ": Zone FM installs over the real tab")
	tick() tick()
	for ch = 1, 2 do same_clock(tab, ch, label) end
	-- the track ends, the stock clock picks the next one, the decider sends that
	pcall(function() tab.radio_ch[1][tab.radio_now[1]]:stop() end)
	pcall(function() tab.radio_session[1][tab.radio_session_now[1]]:stop() end)
	tick() tick()
	same_clock(tab, 1, label .. ", next pick")
	check(coop_mods_core.stats.errors == 0, label .. ": no adapter errors")
end

-- A player's process follows the decider's file names.
local MIRROR = { decides_world = function() return false end, leads_here = function() return false end,
	is_player_mirror = function() return true end, decider = function() return "other" end }
local function player(set, label)
	print("== " .. label .. ": a player follows the decider's Zone FM clock")
	local tab = setup(set, MIRROR, "client")
	the_real_tab(tab, label)
	tick() tick() -- the player's own clock plays something of its own first
	SENT = {}
	-- channel 1: a track the player's clock does not play; channel 2: the other kind than it plays
	local own_k1, own_n1 = playing(tab, 1)
	local want1, idx1
	for i, f in ipairs(FILES["radio" .. BS .. "_channel_1" .. BS]) do
		local n = f:sub(1, -5)
		if not (own_k1 == KIND_TRACK and own_n1 == n) then want1, idx1 = n, i break end
	end
	from_decider({ ch = 1, k = KIND_TRACK, n = want1 })
	local k1, n1 = playing(tab, 1)
	check(k1 == KIND_TRACK and n1 == want1 and tab.radio_now[1] == idx1, string.format(
		"%s: channel 1 switches from its own %s:%s to the decider's track %s (got %s:%s)", label, tostring(own_k1),
		tostring(own_n1), want1, tostring(k1), tostring(n1)))
	local own_k2, own_n2 = playing(tab, 2)
	local want_k2, want2 = KIND_SESSION, "c2_ident_a"
	if own_k2 == KIND_SESSION then want_k2, want2 = KIND_TRACK, "c2_track_b" end
	from_decider({ ch = 2, k = want_k2, n = want2 })
	local k2, n2 = playing(tab, 2)
	check(k2 == want_k2 and n2 == want2, string.format("%s: channel 2 switches from its own %s:%s to the decider's %s:%s (got %s:%s)",
		label, tostring(own_k2), tostring(own_n2), want_k2, want2, tostring(k2), tostring(n2)))
	tick() tick()
	local k3, n3 = playing(tab, 1)
	check(k3 == KIND_TRACK and n3 == want1, label .. ": the stock clock keeps the decider's track on its next updates")
	check(sent_fm() == nil, label .. ": a player sends no clock of his own")
	check(coop_mods_core.stats.errors == 0, label .. ": no adapter errors")
end

-- Every setup reloads stubs_mods.lua, which zeroes PASSES / FAILS: a second scenario of a set adds the first one's back.
for _, name in ipairs(modes.names()) do
	PASSES, FAILS = 0, 0
	if name == "hostplay" then
		decider("hostplay", "Co-op host")
		local p, f = PASSES, FAILS
		player("hostplay", "Co-op player")
		PASSES, FAILS = PASSES + p, FAILS + f
	elseif name == "srv_world" then
		decider("srv_world", "Server: world server")
		local p, f = PASSES, FAILS
		player("srv_world", "Server: player")
		PASSES, FAILS = PASSES + p, FAILS + f
	elseif name == "srv_map" then
		print("== Server: map server: it does not decide the world, so it sends no clock")
		local tab = setup("srv_map", nil, "client")
		the_real_tab(tab, "Server: map server")
		check(not log_has("Zone FM clock not reachable"), "Server: map server: Zone FM installs over the real tab")
		tick() tick() tick()
		check(sent_fm() == nil, "Server: map server: no mods.fm from a map server")
		check(coop_mods_core.stats.errors == 0, "Server: map server: no adapter errors")
	else
		print("== single player (no session): the stock tab is untouched and plays its own clock")
		local tab, fields = setup("none", nil, "sp")
		the_real_tab(tab, "single player")
		local same = true
		for k, v in pairs(fields) do if rawget(tab, k) ~= v then same = false end end
		for k in pairs(tab) do if fields[k] == nil then same = false end end
		check(same, "single player: coop_mods_radio adds, replaces or removes no field of the tab")
		tick() tick() tick()
		check(#SENT == 0, "single player: nothing is sent")
		check(playing(tab, 1) ~= nil and playing(tab, 2) ~= nil, "single player: the stock clock plays on both channels")
	end
	total_passed, total_failed = total_passed + PASSES, total_failed + FAILS
end
print(string.format("Zone FM: %d passed, %d failed", total_passed, total_failed))
if total_failed > 0 then error("Zone FM FAILED") end
