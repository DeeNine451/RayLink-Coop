-- R37: use the real camp and sound managers, with engine objects and sound playback stubbed.
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")
local stock = "temp/stock_scripts/scripts/"

local function load_engine_script(env, path)
	local module = setmetatable({}, { __index = env })
	module.class = function(name)
		local methods = {}
		methods.__index = methods
		module[name] = setmetatable(methods, { __call = function(_, ...)
			local object = setmetatable({}, methods)
			object:__init(...)
			return object
		end })
	end
	setfenv(assert(loadfile(path)), module)()
	return module
end

local function verify(mode, label, path, packed)
	reset_world()
	NOW = 100000
	local m = machine(mode == "none" and "single" or "host", 0, { [0] = 0 })
	local env = m.env
	modes.install(load_script(m, "coop_mode"), mode)
	load_script(m, "coop_npc_players")
	load_script(m, "coop_mods_core")
	local compat = load_script(m, "coop_npc_compat")
	local heard, variant = {}, 1
	local sounds = {}
	env.xr_sound = { sound_table = sounds, set_sound_play = function(id, theme)
		heard[#heard + 1] = { id = id, theme = theme }
		sounds[id] = { stop = function() sounds[id] = nil end }
	end }
	env.ini_file = function(name)
		if name == "scripts\\camp.ltx" then return make_ini({}) end
		return {
			section_exist = function() return true end,
			line_count = function() return 2 end,
			r_line = function(_, story, line) return true, tostring(line), "teller," .. story .. "_" .. line .. ",0" end,
		}
	end
	env.parse_names = function(value)
		local fields = {}
		for field in value:gmatch("[^,]+") do fields[#fields + 1] = field end
		return fields
	end
	env.math = setmetatable({ random = function(a, b)
		if b then return a end
		if a == 3 then return 3 end -- choose story from the idle transitions
		if a == 12 then return variant end
		return 1
	end }, { __index = math })
	env.xr_meet = { is_meet = function() return false end }
	env.xr_logic = { issue_event = function() end }
	for _, id in ipairs({ 10, 11 }) do
		env.db.storage[id] = { object = make_obj(id, 0, 0, 0), active_scheme = "animpoint", animpoint = {
			base_action = "sit", description = "sit", approved_actions = { { name = "sit" } },
		} }
	end
	local sound_path = GAMMA_DIR .. "/sound_manager.script"
	env.sound_manager = load_engine_script(env, have_file(sound_path) and sound_path or stock .. "sound_manager.script")
	env.sr_camp = load_engine_script(env, path)
	local vfs_path = "temp/r37_packed_scripts/sr_camp.script"
	env.getFS = function() return { update_path = function(_, _, file)
		assert(file == "sr_camp.script", file)
		return packed and vfs_path or path
	end } end
	env.r_file_as_string = function(name)
		assert(packed and name == vfs_path, name)
		local source = assert(io.open(path, "rb"))
		local text = source:read("*a")
		source:close()
		return text
	end
	compat.on_game_start()
	local tag = label .. " / " .. mode .. ": "
	for _, line in ipairs(m.log) do
		if line:find("! ", 1, true) then check(false, tag .. line) end
	end

	local function start_story(zone)
		local camp = env.sr_camp.CCampManager(make_obj(zone, 0, 0, 0))
		camp:register_npc(10)
		camp:update()
		local intro = camp.timeout - NOW
		NOW = camp.timeout + 1
		camp:update()
		local clip = heard[#heard]
		check(camp.active_state == "story" and camp.director == 10 and camp.timeout == 0
			and clip and clip.id == 10 and clip.theme == "s_story_1_0", tag .. "director starts a story and plays its first line")
		return camp, intro
	end

	local normal = start_story(20)
	sounds[10]:stop()
	normal:update()
	sounds[10]:stop()
	normal:update()
	local idle_pause = normal.active_state_time - NOW
	local idle_timeout = normal.timeout - NOW
	check(normal.active_state == "idle" and not normal.sound_manager_started and idle_pause > 0,
		tag .. "ordinary story completion schedules idle")
	sounds[10]:stop() -- finish the ambient clip played on entering idle

	local camp, story_intro = start_story(21)
	if mode == "srv_map" then camp:register_npc(11) end -- another NPC stays on the map
	camp:unregister_npc(10)
	local departed_at = NOW
	if mode ~= "srv_map" then camp:register_npc(11) end -- the camp empties and someone returns
	check(camp.director == nil and camp.active_state == "idle" and not camp.sound_manager_started
		and camp.npc_count == 1 and camp.npc[10] == nil and camp.npc[11] ~= nil and sounds[10] == nil,
		tag .. "director and his sound are removed")
	local scheduled = camp.active_state_time - NOW == idle_pause and camp.timeout - NOW == idle_timeout
	if mode == "none" then
		check(camp.active_state_time == 0 and camp.timeout == 0, tag .. "single player keeps the original state")
	else
		check(scheduled, tag .. string.format("departure schedules the normal idle transition (timeout=%d, state_time=%d)",
			camp.timeout, camp.active_state_time))
	end

	variant = 2
	NOW = departed_at + idle_timeout + 1
	camp:update() -- the idle timeout re-enables state selection
	NOW = departed_at + idle_pause + 1
	camp:update()
	NOW = NOW + story_intro + 1
	camp:update()
	local clip = heard[#heard]
	local resumed = camp.active_state == "story" and camp.director == 11
		and clip and clip.id == 11 and clip.theme == "s_story_2_0"
	if mode == "none" then
		check(not resumed, tag .. "single player retains the original playback behavior")
	else
		check(resumed, tag .. "remaining or returning NPC directs and voices a new story")
	end
end

for _, mode in ipairs(modes.names()) do
	if mode == "srv_world" then
		local m = machine("host", 0, { [0] = 0 })
		local facade = load_script(m, "coop_mode")
		modes.install(facade, mode)
		check(not facade.leads_here(), "server world delegates camp simulation to the map server")
	else
		verify(mode, "GAMMA", GAMMA_DIR .. "/sr_camp.script", false)
		if have_file(stock .. "sr_camp.script") then
			verify(mode, "Anomaly", stock .. "sr_camp.script", true)
		end
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
