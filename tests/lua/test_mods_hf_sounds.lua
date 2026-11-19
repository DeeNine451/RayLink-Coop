-- Dev 57 G5-4: cat interaction, sleep and meows, piano manual play and autoplay.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local CAT, PIANO = 701, 702
local sound_log = {}
local function sound(path)
	return {
		playing = function(self) return self.on == true end,
		stop = function(self) self.on = false end,
		play_at_pos = function(self, obj)
			self.on = true
			sound_log[#sound_log + 1] = { path = path, id = obj:id(), sound = self }
		end,
		play_no_feedback = function(_, obj, _, _, _, pitch)
			sound_log[#sound_log + 1] = { path = path, id = obj:id(), pitch = pitch }
		end,
	}
end
sound_object = setmetatable({ s3d = 1, looped = 2 }, { __call = function(_, path) return sound(path) end })
function random_float(a, b) return (a + b) / 2 end
ui_mcm = { get = function(key) return key:find("color", 1, true) and 3 or true end }

make_actor(vec3(0, 0, 0))
local _, player = spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = 500 })
local _, piano = spawn("placeable_piano", vec3(1, 0, 0), nil, { id = PIANO })
local _, crate = spawn("physic_object", vec3(1, 0, 0))
local GameObject = getmetatable(player)
function GameObject:bind_object(binder) self._binder = binder end
function GameObject:binded_object() return self._binder end
function GameObject:set_shader(_, _, texture) self._texture = texture end
function GameObject:play_cycle(clip) self._clip = clip end

-- Load the active cat script. Only its LuaBind/engine boundary and the HF base binder are stubbed.
local base = { update = function() end, net_destroy = function(self) self.object = nil end }
bind_hf_base = { hf_binder_wrapper = base, get_wrapper = function(id)
	local obj = level.object_by_id(id)
	local binder = obj and obj:binded_object()
	return binder and binder.wrapper
end }
local cat = setmetatable({}, { __index = _G })
-- The real constructor calls super(obj), constructing the base on the current instance.
cat.class = function(name)
	return function(parent)
		local cls = {}
		cat[name] = setmetatable(cls, { __index = parent, __call = function(_, obj)
			local wrapper = setmetatable({}, { __index = cls })
			cat.super = function(o) wrapper.object, wrapper.binder = o, { wrapper = wrapper } end
			wrapper:__init(obj)
			return wrapper
		end })
	end
end
local cat_chunk = loadfile("temp/review/corpus/merged/bind_hideout_cat.script") or
	assert(loadfile("E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/bind_hideout_cat.script"))
setfenv(cat_chunk, cat)()
bind_hideout_cat = cat

-- The installed UI uses these file locals in PlaySound and OnInstrumentSelect. Both the keyboard and chart call PlaySound.
local playing_piano_id = PIANO
local notes, note2i, transpose, volume = { "C4", "C#4", "D4" }, { C4 = 1, ["C#4"] = 2, D4 = 3 }, 1, 1.4
local instruments = { { ["C#4"] = "piano_csharp4" }, { ["C#4"] = "organ_csharp4" } }
local note2snd = instruments[1]
ui_furniture_piano = { UIFurniturePiano = {}, get_safe_sound_object = sound }
function ui_furniture_piano.UIFurniturePiano:OnInstrumentSelect(id) note2snd = instruments[id] end
function ui_furniture_piano.PlaySound(note)
	local path = note2snd[notes[note2i[note] + transpose]]
	local snd = ui_furniture_piano.get_safe_sound_object(path)
	local obj = level.object_by_id(playing_piano_id) or db.actor
	snd:play_at_pos(obj, obj:position(), sound_object.s3d)
	snd.volume = volume
end
function ui_furniture_piano.IterateOverChart() ui_furniture_piano.PlaySound("C4") end

coop.players = function()
	return { { id = 0, is_self = SELF == 0 }, { id = 1, is_self = SELF == 1 }, { id = 2, is_self = SELF == 2 }, { id = 3 } }
end
coop.to_host_id = function(id) return MODE == "client" and id == 711 and PIANO or id end
coop.to_local_id = function(id) return MODE == "client" and id == PIANO and 711 or id end
spawn("placeable_piano", vec3(1, 0, 0), nil, { id = 711 })

start_all()
-- With the adapter absent, run the same calls against the stock paths to get behavioral failures first.
local adapter = coop_mods_hf_sounds
if adapter then adapter.on_game_start() end
cat.on_option_change()

local function new_cat()
	local _, obj = spawn("placeable_hideout_cat", vec3(1, 0, 0), nil, { id = CAT })
	cat.init(obj)
	return bind_hf_base.get_wrapper(CAT)
end

local function count_sound(pattern)
	local count = 0
	for _, event in ipairs(sound_log) do
		if event.path and event.path:find(pattern, 1, true) then count = count + 1 end
	end
	return count
end

local function capture(verb, peer)
	for _, event in ipairs(SENT) do
		if event.name == "mods." .. verb and event.target == peer then return event end
	end
end

local function request(verb, data, from)
	coop_main.on_event("mods." .. verb, coop_main.encode(data), from)
end

local function use_on_decider(name, verb, data)
	if name == "srv_map" then
		data._peer = 1 -- world-server forwarding envelope
		request(verb, data, 0)
	else
		request(verb, data, 1)
	end
end

local function ready_players(peer)
	return peer == 3 and "away" or "here"
end

local function switch_to_listener(set, peer)
	MODE, SELF, playing_piano_id = "client", peer, 711
	modes.install(coop_mode, set, {
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		actor_is_player = function() return true end,
	})
end

for _, name in ipairs(modes.names()) do
	print("== HF sounds / " .. name)
	local joined = false
	modes.install(coop_mode, name, name == "srv_map" and { where = function(peer)
		if peer == 0 or peer == 3 then return "away" end
		if peer == 2 and not joined then return "joining" end
		return "here"
	end } or { where = function(peer)
		if peer == 2 and not joined then return "joining" end
		return ready_players(peer)
	end })
	SENT, sound_log = {}, {}
	if name == "none" then MODE = "sp" end
	local wrapper = new_cat()
	if name == "none" then
		wrapper:_enter_state("sleep_side", true)
		wrapper:update(250)
		cat.toggle_hideout_cat(CAT)
		check(wrapper.anim.force_loop == "idle_3", "single player keeps the stock cat interaction")
		check(wrapper.current_fur_color == 3 and wrapper.current_fur_hidden == true, "single player keeps local cat appearance")
		ui_furniture_piano.PlaySound("C4")
		check(count_sound("piano_csharp4") == 1 and #SENT == 0, "single player piano plays locally without events")
	elseif name == "srv_world" then
		request("hf_cat_use", { o = CAT, _peer = 3 }, 1)
		request("hf_piano_play", { o = PIANO, i = 2, n = 2, v = 1.4, _peer = 3 }, 1)
		local use = capture("hf_cat_use", 0x101)
		local note = capture("hf_piano_play", 0x101)
		check(use and coop_main.decode(use.payload)._peer == 1 and wrapper.anim.force_loop == nil,
			"world server forwards cat use as the transport sender")
		check(note and coop_main.decode(note.payload)._peer == 1 and #sound_log == 0,
			"world server forwards piano play without performing it")
	else
		-- m29:5 sleep is sent even when the late join happens after the last state change.
		wrapper:_enter_state("sleep_side", true)
		wrapper:update(250)
		check(not capture("hf_cat_sleep", 2), "cat state waits for a joining player to enter the map")
		joined = true
		NOW = NOW + 5000
		wrapper:update(250)
		local sleeping = capture("hf_cat_sleep", 2)
		check(sleeping and coop_main.decode(sleeping.payload).s == true, "late listener receives a sleeping cat snapshot")
		check(not capture("hf_cat_sleep", 3), "cat state stays on the cat's map")

		-- m29:4 the same handler runs on the decider for a remote player and the local playing host.
		coop_trust.reset_for_test({ default = "refuse" })
		use_on_decider(name, "hf_cat_use", { o = crate:id() })
		player._pos = vec3(40, 0, 0)
		use_on_decider(name, "hf_cat_use", { o = CAT })
		check(wrapper.anim.force_loop == nil, "distant requester cannot wake the cat in refuse mode")
		player._pos = vec3(1, 0, 0)
		OBJ[500] = nil
		use_on_decider(name, "hf_cat_use", { o = CAT })
		OBJ[500] = player
		check(wrapper.anim.force_loop == nil, "requester needs a body on the map")
		local trust = coop_trust.status()
		check(trust.hf_cat_use_type and trust.hf_cat_use_type.refused == 1 and
			trust.hf_cat_use_near and trust.hf_cat_use_near.refused == 2, "cat type, presence and distance go through trust")
		SENT, sound_log = {}, {}
		use_on_decider(name, "hf_cat_use", { o = CAT })
		check(wrapper.anim.force_loop == "idle_3", "cat use calls on_interact on the authoritative copy")
		for _ = 1, 9 do wrapper:update(250) end
		local meow = capture("hf_cat_meow", 2)
		check(meow and not capture("hf_cat_meow", 3), "the stock wake animation emits one meow toward a listener on the map")
		check(count_sound("cat_miau_") == (name == "hostplay" and 1 or 0), "only a playing decider hears its local meow")
		if name == "hostplay" then
			wrapper.anim.force_loop = nil
			cat.toggle_hideout_cat(CAT)
			check(wrapper.anim.force_loop == "idle_3" and not capture("hf_cat_use", 0), "co-op host uses the authoritative handler directly")
		end

		-- m17:6 the authority only uses its own instrument catalog. Transport identity excludes the original pianist.
		SENT, sound_log = {}, {}
		use_on_decider(name, "hf_piano_play", { o = PIANO, i = 2, n = 2, v = 1.4, from = 2 })
		local note = capture("hf_piano_note", 2)
		check(note and not capture("hf_piano_note", 1) and not capture("hf_piano_note", 3),
			"piano note reaches the same-map listener, excluding pianist and other maps")
		check(count_sound("organ_csharp4") == (name == "hostplay" and 1 or 0), "co-op host hears a guest note once")
		SENT = {}
		use_on_decider(name, "hf_piano_play", { o = PIANO, i = 99, n = 2, v = 1.4 })
		use_on_decider(name, "hf_piano_play", { o = PIANO, i = 2, n = 2, v = 3 })
		use_on_decider(name, "hf_piano_play", { o = PIANO + 0.5, i = 2, n = 2, v = 1.4 })
		check(not capture("hf_piano_note", 2) and trust.hf_piano_play_volume and trust.hf_piano_play_volume.refused == 1,
			"invalid instrument, volume and object ID do not reach listeners")
		if name == "hostplay" then
			ui_furniture_piano.PlaySound("C4")
			check(capture("hf_piano_note", 2) and not capture("hf_piano_note", 0) and count_sound("piano_csharp4") == 1,
				"co-op host's key plays immediately and is sent only to listeners")
		end
		SENT = {}
		coop_trust.reset_for_test({ default = "log" })
		use_on_decider(name, "hf_piano_play", { o = PIANO, i = 2, n = 2, v = 3 })
		local bounded = capture("hf_piano_note", 2)
		local gain_check = coop_trust.status().hf_piano_play_volume
		check(bounded and coop_main.decode(bounded.payload).v == 2 and gain_check.failed == 1 and gain_check.refused == 0,
			"log mode records out-of-range volume and relays the note with a bounded gain")

		-- A fresh mirror wrapper represents a late join. Its update runs the installed mod's actual Lua.
		SENT, sound_log = {}, {}
		switch_to_listener(name, 2)
		wrapper = new_cat()
		wrapper:update(250)
		check(wrapper.object._clip == nil and count_sound("cat_purr") == 0, "mirror does not choose cat animation or purr")
		if sleeping then deliver(sleeping, 0) end
		wrapper:update(250)
		check(count_sound("cat_purr") == 1 and wrapper.snd_purr.volume > 0, "late mirror purrs from the authority's sleep state")
		if sleeping then deliver(sleeping, 0) end
		wrapper:update(250)
		check(count_sound("cat_purr") == 1, "a repeated sleep snapshot leaves the purr playing")
		check(wrapper.current_fur_color == 3 and wrapper.current_fur_hidden == true, "mirror retains local fur settings")
		request("hf_cat_sleep", { o = CAT, s = false }, 0)
		wrapper:update(250)
		check(not wrapper.snd_purr:playing(), "authoritative waking stops the mirror's purr")
		if meow then deliver(meow, 0); deliver(meow, 0) end
		check(count_sound("cat_miau_") == 1, "meow plays once even if the same event is delivered again")
		if meow then
			local msg = coop_main.decode(meow.payload)
			check(sound_log[#sound_log] and sound_log[#sound_log].pitch == msg.p, "meow uses the authority's chosen pitch")
		end
		if note then deliver(note, 0) end
		local heard = sound_log[#sound_log]
		check(heard and heard.path == "organ_csharp4" and heard.id == 711 and heard.sound.volume == 1.4,
			"listener plays the transposed instrument and volume at the local piano object")
		cat.toggle_hideout_cat(CAT)
		check(capture("hf_cat_use", 0) and wrapper.anim.force_loop == nil, "client interaction sends a request without waking its mirror")
		ui_furniture_piano.UIFurniturePiano:OnInstrumentSelect(2)
		ui_furniture_piano.IterateOverChart()
		local played = capture("hf_piano_play", 0)
		local msg = played and coop_main.decode(played.payload)
		check(msg and msg.o == PIANO and msg.i == 2 and msg.n == 2 and msg.v == 1.4 and count_sound("organ_csharp4") == 2,
			"autoplay uses the manual note path, sends the host ID and plays once locally")
	end
	MODE, SELF, playing_piano_id, note2snd = "host", 0, PIANO, instruments[1]
end

done("HF sounds")
