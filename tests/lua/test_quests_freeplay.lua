-- Dev 57 G15-2: stock window on the addressed player, one answer on the world.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local CHOICE = "st_freeplay_text_yes_no"
local ACK = "st_freeplay_text_ok"

local function start(M)
	if not M.env.coop_mode then
		local facade = load_script(M, "coop_mode")
		modes.live(facade, function(name) return load_script(M, name) end)
	end
	load_script(M, "coop_mods_core")
	load_script(M, "coop_trust").reset_for_test({ default = "log" })
	M.windows = {}
	M.env.ui_events = { MESSAGE_BOX_OK_CLICKED = 1, MESSAGE_BOX_YES_CLICKED = 2, MESSAGE_BOX_NO_CLICKED = 3 }
	M.env.ui_freeplay_dialog = {
		freeplay_dialog = function()
			local window = { buttons = {} }
			function window:AddCallback(control, event, fn, owner)
				assert(control == "freeplay_mb")
				self.buttons[event] = function() fn(owner) end
			end
			function window:Show(kind, text)
				M.windows[#M.windows + 1] = { kind = kind, text = text, buttons = self.buttons }
			end
			return window
		end,
	}
	local path = io.open("gamedata/scripts/coop_quests_freeplay.script", "r")
	if not path then return end -- red run: no handler at the production entry point
	path:close()
	local mod = load_script(M, "coop_quests_freeplay")
	mod.on_game_start()
	return mod
end

local function send_answer(M, id, answer, claimed_peer)
	M.env.coop_mods_core.to_host("fp_answer", { id = id, answer = answer, peer = claimed_peer })
end

for _, mode in ipairs(modes.names()) do
	MACHINES, QUEUE = {}, {}
	local world = mode == "srv_map" and machine("client", 0x101) or machine("host", 0)
	local first = machine("client", 1)
	local selected = machine("client", 2)
	if mode == "srv_world" then
		for _, player in ipairs({ first, selected }) do
			player.env.coop.levels = { split = function() return true end }
		end
	end
	world.active = mode ~= "none"
	world.env.coop.is_dedicated = function() return mode == "srv_world" end
	world.env.coop.is_map_server = function() return mode == "srv_map" end
	modes.install(load_script(world, "coop_mode"), mode)
	local fp = start(world)
	start(first)
	start(selected)
	if mode == "none" then
		check(not fp or not fp.ask(2, CHOICE, function() error("no session") end), "none: no request")
		check(#world.sent == 0, "none: no traffic")
	elseif mode == "srv_map" then
		-- A process without a local player cannot be made to show a window.
		local h = world.handlers["mods.fp_ask"]
		if h then h(world.env.coop_main.encode({ id = CHOICE }), 0) end
		check(#world.windows == 0, "srv_map: the player route excludes the map process")
	else
		local answers = {}
		local function accept(answer) answers[#answers + 1] = answer end
		check(fp and fp.ask(2, CHOICE, accept), mode .. ": world offers stock evacuation choice")
		pump()
		local window = selected.windows[1]
		check(window and window.kind == "message_box_yes_no" and window.text == CHOICE
			and #first.windows == 0 and #world.windows == 0, mode .. ": only the target sees the stock window")
		send_answer(first, CHOICE, "leave", 2)
		send_answer(selected, CHOICE, "unknown")
		pump()
		local trust = world.env.coop_trust.status().fp_answer
		check(#answers == 0 and trust and trust.failed == 2, mode .. ": foreign and invalid answers go through trust and are ignored")
		if window then window.buttons[2]() window.buttons[3]() end
		pump()
		check(#answers == 1 and answers[1] == "leave" and #selected.sent == 2,
			mode .. ": only Yes sends an answer and opens no local story flag")
		check(next(selected.infos) == nil, mode .. ": the UI cannot change world flags")
		send_answer(selected, CHOICE, "stay")
		pump()
		check(#answers == 1 and not (fp and fp.ask(1, CHOICE, accept)), mode .. ": duplicate answer and reissue are inert")

		check(fp and fp.ask(1, ACK, accept), mode .. ": OK has a distinct dialog id")
		pump()
		window = first.windows[1]
		check(window and window.kind == "message_box_ok" and window.text == ACK, mode .. ": stock OK window")
		send_answer(first, ACK, "leave")
		pump()
		check(#answers == 1, mode .. ": OK cannot select Leave")
		if window then window.buttons[1]() end
		pump()
		check(#answers == 2 and answers[2] == "stay", mode .. ": stock OK records Stay")
	end
end

if modes.names()[1] == "hostplay" then
	local host = machine("host", 0)
	local fp = start(host)
	local recorded
	check(fp and fp.ask(0, CHOICE, function(answer) recorded = answer end), "hostplay: Core can show the host's own window")
	if host.windows[1] then host.windows[1].buttons[3]() end
	check(recorded == "stay" and #host.sent == 0, "hostplay: local No uses the same one-shot answer without a network request")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
