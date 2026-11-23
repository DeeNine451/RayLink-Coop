-- TZ Р43 (Dev 58, the server mode, players on different maps): the G.A.M.M.A. offer "Artefact System Tutorial" (Catspaw's
-- Timed Tutorial Prompts: the title, the timer ring after it and the hold ring - "two small circles") stays on the HUD for
-- good, over the PDA too.
--
-- The chain, all real files of the stand (GAMMA_SCRIPTS): the detector goes to its slot (npe_gamma_tutorial_artefact_mcm,
-- whose trigger stays true from then on) -> New Player Experience runs the lesson's handler, activates it, counts its 6 s
-- down and plays it (npe_director, npe_execution) -> z_npe_timed_prompt turns the play into an offer of ui_timed_prompt
-- under the tutorial id. The offer closes from its own time event, CreateTimeEvent(uid, 0, ...) (ui_timed_prompt.script:418),
-- and a queued event of the same ids is not replaced (_g_patches.script:1516, the fake's queue the same).
-- An on_option_change while the lesson counts down restarts NPE (npe_director.script:1197 mcm_on_option_change: the
-- handler runs again, the lesson is activated a second time, npe_director.script:621) and the lesson is played twice: the
-- second offer gets no timer and never closes. The stock game sends on_option_change only from its options menus; a co-op
-- client gets it from coop_settings whenever the host's settings come (every world entry of a server-mode player, the
-- stand's log appdata_t 2026-11-21 18:09:39: "host settings received" -> "go to the scripts" -> NPE reads its settings
-- again).
-- Sets (tests/lua/support/modes.lua): srv_world / srv_map - a player of the server mode (a client, a mirror); hostplay - a
-- client of a co-op host; none - single player (stock: nothing of co-op runs).
-- Fakes: the game UI and the time queue (tests/lua/support/hud_fake.lua), npe_mcm (the MCM values NPE reads),
-- coop_route.handlers_of (the router's list of a script's handlers).
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua") -- GAMMA_DIR
local HUD = dofile("tests/lua/support/hud_fake.lua")
local UNL = dofile("tests/lua/support/unlocalize.lua")
local BS = string.char(92)
print("== issue P43: the tutorial offer that stays on the HUD")

local function stand(name) return GAMMA_DIR .. BS .. name .. ".script" end
local REAL = { "npe", "npe_logging", "npe_execution", "npe_director", "npe_gamma_tutorial_artefact_mcm",
	"gamma_npe_tutorial_setup", "ui_circular_progress", "ui_timed_prompt", "z_npe_timed_prompt" }
for _, name in ipairs(REAL) do check(have_file(stand(name)), "real script readable: " .. name) end

-- The stand's unlocalizer for npe_director (configs\unlocalizers\timed_prompt_unlocalizers.ltx): without it the timed prompt
-- never sees NPE's plays (play_set_dialog is a local of npe_director.script:714).
local UNLOCAL = { npe_director = { play_set_dialog = true } }
do
	local path = GAMMA_DIR .. BS .. ".." .. BS .. "configs" .. BS .. "unlocalizers" .. BS .. "timed_prompt_unlocalizers.ltx"
	local text = HUD.read(path) or ""
	check(text:find("[npe_director]", 1, true) ~= nil and text:find("play_set_dialog", 1, true) ~= nil,
		"contract: the stand unlocalizes npe_director.play_set_dialog")
	local tp = HUD.read(stand("ui_timed_prompt")) or ""
	check(tp:find("CreateTimeEvent(self.uid, 0, 0", 1, true) ~= nil, "contract: an offer closes from its time event of its uid")
	local npe = HUD.read(stand("npe_director")) or ""
	check(npe:find('RegisterScriptCallback("on_option_change", mcm_on_option_change)', 1, true) ~= nil,
		"contract: npe_director restarts on on_option_change")
end

local function load_real(M, name)
	local fh = assert(io.open(stand(name), "rb"))
	local src = fh:read("*a")
	fh:close()
	src = UNL.source(src, UNLOCAL[name])
	local header = "local this = {} " .. name .. " = this setmetatable(this, {__index = _G}) setfenv(1, this) "
	local f = assert(loadstring(header .. src, "@" .. stand(name)))
	setfenv(f, M.env)
	f()
	return M.env[name]
end

local MIRROR = { -- a client's process in either mode: its actor is the player, a copy of the world
	actor_is_player = function() return true end,
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
}

-- The MCM values NPE reads (npe_mcm.npe_get_setting / npe_module_*): defaults of G.A.M.M.A.; reads are counted.
local function npe_mcm_stub(reads, played)
	local VALUES = {
		general = { enable = true, execution_loop = 1, play_loop = 3, sounds_set = "NPE_MEDIUM", pause_game = false,
			disable_dof = true, safe_distance_threat = 60 },
		logs = { logging_level = 0 },
	}
	return {
		npe_get_setting = function(group, key)
			local k = tostring(group) .. "/" .. tostring(key)
			reads[k] = (reads[k] or 0) + 1
			local g = VALUES[group]
			if g == nil or g[key] == nil then return false end
			return g[key]
		end,
		npe_module_get_setting = function(module, id) return played[tostring(module) .. "/" .. tostring(id)] == true end,
		npe_module_set_setting = function(module, id, v) played[tostring(module) .. "/" .. tostring(id)] = v end,
	}
end

local function new_machine(set)
	reset_world()
	local role = set == "none" and "single" or "client"
	local M = machine(role, role == "client" and 1 or 0, role == "single" and {} or { [0] = 0, [1] = 501 })
	local E = M.env
	local ui = HUD.install(E)
	E.coop_mode = load_script(M, "coop_mode")
	modes.install(E.coop_mode, set, role == "client" and MIRROR or nil)
	-- the script callbacks a script registered, for coop_route.handlers_of (the router keeps its handlers by their script)
	local seen = {}
	local reg = E.RegisterScriptCallback
	E.RegisterScriptCallback = function(name, f)
		local list = seen[name] or {}
		seen[name] = list
		local known = false
		for _, g in ipairs(list) do if g == f then known = true end end
		if not known then list[#list + 1] = f end
		return reg(name, f)
	end
	E.coop_route = {
		handlers_of = function(callback, script)
			local out = {}
			for _, f in ipairs(seen[callback] or {}) do
				if type(f) == "function" and ui.registered(callback, f) then
					local info = debug.getinfo(f, "S")
					local file = info and info.source and info.source:match("([^\\/]+)%.script$")
					if file and file:lower() == tostring(script):lower() then out[#out + 1] = f end
				end
			end
			return out
		end,
	}
	-- the engine and stock pieces the real files use
	E.bind_to_dik = function() return 25 end
	E.key_bindings = setmetatable({}, { __index = function() return 1 end })
	E.ui_mcm = { get = function() return nil end, key_hold = function() return false end, simple_press = function() end,
		get_mod_key = function() return true end, hold = {} }
	E.xr_sound = { get_safe_sound_object = function() return nil end }
	E.utils_data = { collect_section = function() return nil end }
	E.normalize = function(v, a, b) if b == a then return 1 end return (v - a) / (b - a) end
	E.ResetTimeEvent = function(ev_id, act_id, timer)
		local ev = ui.events[tostring(ev_id) .. "\0" .. tostring(act_id)]
		if ev then ev.t = NOW + (timer or 0) * 1000 end
	end
	E.execute_func = function(file, func, ...) -- _g.script:995-999
		local m = file and E[file]
		if func and type(m) == "table" and m[func] then return m[func](...) end
	end
	E.is_empty = function(t) return t == nil or next(t) == nil end
	E.size_table = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
	E.actor_menu = { inventory_opened = function() return false end }
	E.item_device = { is_pda_active = function() return false end }
	E.xr_combat_ignore = { fighting_with_actor_npcs = {} }
	E.check_anim = { anim_playing = false }
	E.gameplay_disguise = { get_default_comm = function() return "stalker" end }
	E.level.iterate_nearest = function() end
	local reads, played = {}, {}
	E.npe_mcm = npe_mcm_stub(reads, played)
	for _, name in ipairs(REAL) do load_real(M, name) end
	-- every offer ui_timed_prompt makes (z_npe_timed_prompt calls the module's field)
	local offers = {}
	local show = E.ui_timed_prompt.show_tutorial_prompt
	E.ui_timed_prompt.show_tutorial_prompt = function(...)
		local p = show(...)
		offers[#offers + 1] = p
		return p
	end
	-- axr_main: every on_game_start, by file name
	local names = {}
	for _, name in ipairs(REAL) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local m = E[name]
		if type(m.on_game_start) == "function" then m.on_game_start() end
	end
	M.fire("actor_on_first_update")
	local W = { M = M, E = E, ui = ui, reads = reads, played = played, offers = offers }
	-- a frame: the actor's update, then the time events (50 ms steps)
	function W.run(ms)
		local left = ms
		repeat
			local step = math.min(50, left)
			NOW = NOW + step
			left = left - step
			M.fire("actor_on_update")
			ui.run_events()
		until left <= 0
	end
	-- runs until cond() or ms are up; true when cond() came
	function W.until_(cond, ms)
		local t = 0
		while t < ms do
			if cond() then return true end
			W.run(50)
			t = t + 50
		end
		return cond() and true or false
	end
	function W.artefact_offers()
		local out = {}
		for _, p in ipairs(offers) do if p.tutorial_id == "artefact" then out[#out + 1] = p end end
		return out
	end
	-- on the screen: a window that lives under the main HUD, shown, not slid out to the left (slide_window_out ends at
	-- x = -w - 1; Destroy drops the window)
	function W.on_screen(p)
		local o = p and p.wnd and HUD.obj_of(p.wnd)
		return o ~= nil and o.alive and o.shown and o.x >= 0 and HUD.under(o, ui.main_obj())
	end
	function W.restarts() return (reads["general/sounds_set"] or 0) - 1 end -- update_settings: start-up + each restart
	function W.counting() return #E.npe_director.get_playableOnCountdownQueue() > 0 end
	function W.equip_detector()
		M.fire("actor_item_to_slot", make_obj(900, 0, 0, 0, { _section = "detector_advanced" }))
	end
	return W
end

-------------------------------------------------------------------------------
-- 1. the lesson alone: one offer, closed by its own timer (wait_time 12 s, gamma_npe_tutorial_setup.script:4)
-------------------------------------------------------------------------------
local function lesson_alone(set)
	local W = new_machine(set)
	W.run(4000) -- NPE starts 3 s after the first update
	W.equip_detector()
	local offered = W.until_(function() return #W.artefact_offers() > 0 end, 15000)
	local p = W.artefact_offers()[1]
	W.run(500) -- its slide-in from the left edge (200 ms, ui_timed_prompt.script:916-926)
	local shown = offered and W.on_screen(p)
	W.run(13500)
	local r = { offered = offered, shown = shown, count = #W.artefact_offers(), gone = p ~= nil and not W.on_screen(p) }
	return r
end

-------------------------------------------------------------------------------
-- 2. the player's own options menu while the lesson counts down (the stock path; single player the same): NPE restarts and
--    plays the lesson twice, the second offer has no timer and stays. This is G.A.M.M.A.'s own behaviour; it shows what any
--    on_option_change in that moment does.
-------------------------------------------------------------------------------
local function own_menu_while_counting(set)
	local W = new_machine(set)
	W.run(4000)
	W.equip_detector()
	local counting = W.until_(W.counting, 5000)
	local before = W.restarts()
	W.M.fire("on_option_change") -- ui_mcm / ui_options after the player pressed Accept
	local heard = W.restarts() - before
	W.run(60000)
	local list = W.artefact_offers()
	local stuck = 0
	for _, p in ipairs(list) do if W.on_screen(p) then stuck = stuck + 1 end end
	return { counting = counting, heard = heard, count = #list, stuck = stuck,
		timer_left = W.ui.has_event("artefact", 0) }
end

-------------------------------------------------------------------------------
-- 3. the host's settings come while the lesson counts down (coop_settings on a client: a world entry of a server-mode
--    player, a join or a level load of a co-op client, a change the host made): the lesson is offered once and the offer
--    closes; NPE does not restart. The player's own menu afterwards still reaches NPE.
-------------------------------------------------------------------------------
local function host_settings_while_counting(set)
	local W = new_machine(set)
	local cs = load_script(W.M, "coop_settings")
	local deliver = W.M.handlers.coop_set and W.M.handlers.coop_set[1]
	W.run(4000)
	W.equip_detector()
	local counting = W.until_(W.counting, 5000)
	local before = W.restarts()
	local payload = W.E.coop_main.encode({ _t = "full", _s = 1, _i = 1, _n = 1, ["o|gameplay/general/max_tasks"] = "4" })
	if deliver then deliver(payload, 0) end
	local heard = W.restarts() - before
	W.run(60000)
	local list = W.artefact_offers()
	local stuck = 0
	for _, p in ipairs(list) do if W.on_screen(p) then stuck = stuck + 1 end end
	local before_own = W.restarts()
	W.M.fire("on_option_change")
	local own = W.restarts() - before_own
	return { cs = cs ~= nil, delivered = deliver ~= nil, counting = counting, heard = heard, count = #list, stuck = stuck,
		own = own, npe_owner = cs and cs.owner_of("mcm", "npe/general/enable"),
		npe_logs_owner = cs and cs.owner_of("mcm", "npe/logs/logging_level"),
		lessons_owner = cs and cs.owner_of("mcm", "npe_module/gamma_tutorial_artefact/artefact") }
end

for _, set in ipairs(modes.names()) do
	local p = "[" .. set .. "] "
	local a = lesson_alone(set)
	check(a.offered and a.shown, p .. "the lesson is offered on the HUD after the detector went to its slot")
	check(a.count == 1 and a.gone, p .. "one offer, and it closes by itself (its timer, 12 s)")

	local b = own_menu_while_counting(set)
	check(b.counting, p .. "stock path: the lesson counts down before it is played")
	check(b.heard == 1, p .. "stock path: the player's own options menu restarts NPE")
	check(b.count == 2 and b.stuck == 1 and not b.timer_left,
		p .. "stock path (G.A.M.M.A. itself): the lesson is offered twice and the second offer, with no timer, stays")

	if set ~= "none" then
		local c = host_settings_while_counting(set)
		check(c.cs and c.delivered, p .. "coop_settings loaded on the client, its settings handler registered")
		check(c.counting, p .. "the lesson counts down when the host's settings come")
		check(c.heard == 0, p .. "the host's settings do not restart NPE")
		check(c.count == 1 and c.stuck == 0, p .. "the lesson is offered once and the offer closes")
		check(c.own == 1, p .. "the player's own options menu still reaches NPE")
		check(c.npe_owner == "player" and c.npe_logs_owner == "player",
			p .. "NPE's own options (npe/*) are the player's, as its lessons")
		check(c.lessons_owner == "player", p .. "NPE's lessons (npe_module/*) stay the player's")
	end
end

print(string.format("ISSUE_P43: %d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
