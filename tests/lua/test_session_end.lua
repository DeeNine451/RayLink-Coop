-- Anomaly Coop test: what a client reads in the main menu when a session sent him out of the host's world (coop_ui.on_session_end).
-- The window and the strings are the real ones. Not shipped. Run: tools\test_lua.cmd session_end
dofile("tests/lua/support/menu_stubs.lua")
XML_FILES["ui_coop_diff.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_diff.xml")

local function table_of(lang)
	local T = {}
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_menu.xml", "rb"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do T[id] = text end
	fh:close()
	return T
end
local RU, EN = table_of("rus"), table_of("eng")
local T = EN
game = { translate_string = function(id) return T[id] or id end }

local ui = load_module("coop_ui")
local function box(info)
	ui.GUI = nil
	ui.on_session_end(info)
	return ui.GUI
end
local function rows(g)
	local out = {}
	for _, r in ipairs(g.scroll.children) do out[#out + 1] = r.text end
	return table.concat(out, "\n")
end

print("== the endings, each in its own words")
for _, lang in ipairs({ "eng", "rus" }) do
	T = lang == "eng" and EN or RU
	local g = box({ code = "host_left", text = "left the session" })
	check(T.st_coop_end_title_host_left and g.cap.text == T.st_coop_end_title_host_left, lang .. ": the host stopped the game")
	check(g.summary.text == T.st_coop_end_text_host_left, lang .. ": what happened")
	check(rows(g):find(T.st_coop_end_hint_host_left, 1, true) ~= nil, lang .. ": what to do")

	g = box({ code = "lost", text = "connection to host lost" })
	check(T.st_coop_end_title_lost and g.cap.text == T.st_coop_end_title_lost, lang .. ": the connection was lost")
	check(g.summary.text == T.st_coop_end_text_lost, lang .. ": what happened")
	check(rows(g):find(T.st_coop_end_hint_lost, 1, true) ~= nil, lang .. ": what to do")
	check(T.st_coop_end_title_host_left ~= T.st_coop_end_title_lost, lang .. ": the two read differently")

	g = box({ code = "Kicked", text = "Kicked: ask the host why" })
	check(g.cap.text == T.st_coop_ui_title_Kicked, lang .. ": a kick has the title of the refusal window")
	check(g.summary.text == "Kicked: ask the host why", lang .. ": and the host's word")

	g = box({ code = "HostNotReady", text = "HostNotReady: host is not in a game right now, try again later" })
	check(g.cap.text == T.st_coop_ui_title_HostNotReady, lang .. ": a refusal after joining too")
	check(rows(g):find(T.st_coop_ui_hint_not_ready, 1, true) ~= nil, lang .. ": with its hint")

	g = box({ code = "failed", text = "joining the host's world took too long" })
	check(T.st_coop_end_title_failed and g.cap.text == T.st_coop_end_title_failed, lang .. ": a join that broke down")
	check(g.summary.text == "joining the host's world took too long", lang .. ": says what broke")
end
T = EN

print("== the co-op window says the same")
local reason = EN.st_coop_menu_reason_host_left
check(reason ~= nil and RU.st_coop_menu_reason_host_left ~= nil, "the status line has the reason in both languages")

print("== nothing to say")
ui.GUI = nil
ui.on_session_end(nil)
check(ui.GUI == nil, "no argument, no window")

print("== the files")
for _, lang in ipairs({ "eng", "rus" }) do
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_menu.xml", "rb"))
	local src = fh:read("*a")
	fh:close()
	check(not src:gsub("\r\n", ""):find("\n", 1, true), lang .. ": CRLF throughout")
end
check(#MISSING_PATHS == 0, "layout paths exist")
print(string.format("%d passed, %d failed", PASSES, FAILS))
