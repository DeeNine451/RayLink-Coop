-- Dev 57 G7-1: real PBA/Momopate death bodies, on each S4 answer set. No live-game reads.
local modes = dofile("tests/lua/support/modes.lua")
local function source(name)
	local f = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "rb"))
	local s = f:read("*a"):gsub("\r\n", "\n")
	f:close()
	return s
end

for _, mode in ipairs(modes.names()) do
	MODE = mode == "none" and "sp" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	local actor = make_actor(vec3(20, 0, 0))
	local _, other = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500, kind = "stalker" })
	local pba = setmetatable({ artefact_props = {}, artefact_on_npc_death_functions = {},
		artefact_on_monster_death_functions = {}, artefact_on_npc_before_hit_functions = {},
		artefact_on_monster_before_hit_functions = {} }, { __index = _G })
	perk_based_artefacts = pba
	local belt = {}
	pba.artefacts = belt
	local registered = {}
	coop_mods_pdata = { register = function(k) registered[k] = true end }
	local fs = getFS
	function getFS()
		local f = fs()
		f.update_path = function(_, _, name) return "temp/review/corpus/merged/" .. name end
		return f
	end
	local timer_calls, errors, lucifer_spent = 0, 0, 0
	demonized_time_events = { CreateTimeEvent = function(...)
		timer_calls = timer_calls + 1
		return CreateTimeEvent(...)
	end }
	function normalize(v, lo, hi) return (v - lo) / (hi - lo) end
	function random(a, b) if a then return b and a or 1 end return 0 end
	function random_float(a) return a end
	function hit(s_hit) return { type = s_hit.type } end
	AC_ID = actor:id()
	function vector_rotate_y(v) return v end
	function SYS_GetParam() return "dog" end
	function get_safe_sound_object(n) return sound_object(n) end
	function particles_object() return nil end
	function play_sound_on_actor() end
	pba.trace = function() end
	pba.max = math.max
	pba.get_random_array_element = function(t) return t[1] end
	getmetatable(actor).clsid = function() return 1 end
	pba.artefact_props.af_lucifer = { condition = 0,
		check_lucifer = function() return true end,
		change_condition = function(_, n) lucifer_spent = lucifer_spent + n end }
	pba.artefact_props.af_kogot = { dice_roll = 0, monster_to_meat = { dog = "meat_dog" }, valid_hits = { [1] = true } }
	pba.artefact_props.af_dragon_eye = { dice_roll = 0, chance = 1 }
	pba.artefact_props.af_skull_miser = { head_bones = { [2] = true }, money_items = { "money_a" } }
	pba.get_monster_clsid_and_kind = function(o) return o:clsid(), "dog" end
	INI.meat_dog, INI.money_a, INI.ied_new_blow, INI.forbidden = {}, {}, { class = "S_EXPLO" }, {}
	local pba_source, momo_source = source("perk_based_artefacts"), source("momopate_pba_tweaks")
	-- Keep the source name and line numbers: the adapter may patch just this function,
	-- while the complete mod has load-time mutations of other mods and must never be rerun.
	local function real_function(text, name, header, closing, after)
		local at = assert(text:find(header, after or 1, true), header)
		local first = assert(text:find("function%s*%(", at))
		local last = assert(text:find(closing, first, true)) + #closing - 1
		local _, lines = text:sub(1, first - 1):gsub("\n", "")
		local chunk = assert(loadstring(string.rep("\n", lines) ..
			"local CreateTimeEvent = demonized_time_events.CreateTimeEvent; local get_monster_clsid_and_kind = get_monster_clsid_and_kind; return " ..
			text:sub(first, last), "@" .. name .. ".script"))
		setfenv(chunk, pba)
		return chunk()
	end
	local kogot_start = assert(pba_source:find("\taf_kogot = {", 1, true))
	local dragon_start = assert(pba_source:find("\taf_dragon_eye = {", 1, true))
	local deaths_start = assert(pba_source:find("artefact_on_npc_death_functions = {", 1, true))
	local base_claw = real_function(pba_source, "perk_based_artefacts", "on_death = function", "\n\t\tend", kogot_start)
	local momo_claw = real_function(momo_source, "momopate_pba_tweaks", "perk_based_artefacts.artefact_props.af_kogot.on_death =", "\n\tend")
	pba.artefact_props.af_kogot.on_death = momo_claw
	pba.artefact_props.af_dragon_eye.on_death = real_function(pba_source, "perk_based_artefacts", "on_death = function", "\n\t\tend", dragon_start)
	pba.artefact_on_npc_death_functions.af_skull_miser = real_function(pba_source, "perk_based_artefacts", "af_skull_miser = function", "\n\tend", deaths_start)
	pba.artefact_on_npc_death_functions.af_dragon_eye = real_function(pba_source, "perk_based_artefacts",
		"af_dragon_eye = function", "\n\tend", deaths_start)
	local function claw(a, n, ids, names, ...)
		return pba.artefact_props.af_kogot:on_death(a, n, ids, names, ...)
	end
	local function dragon(a, n, ids, names, ...)
		return pba.artefact_props.af_dragon_eye:on_death(a, n, ids, names, ...)
	end
	pba.artefact_on_monster_death_functions.af_kogot = claw
	pba.artefact_on_monster_death_functions.af_dragon_eye = dragon
	local sandstone, lighthouse = 0, 0
	-- Exercise the real Momopate bonuses too, with only their presentation/timer dependencies stubbed.
	local sand_first = assert(momo_source:find("perk_based_artefacts.artefact_props.af_sandstone =", 1, true))
	local sand_last = assert(momo_source:find("perk_based_artefacts.artefact_on_before_hit_functions.af_sandstone", sand_first, true))
	local sand_table = assert(momo_source:find("{", sand_first, true))
	local sand_chunk = assert(loadstring("return " .. momo_source:sub(sand_table, sand_last - 1), "@momopate_pba_tweaks.script"))
	setfenv(sand_chunk, pba)
	pba.artefact_props.af_sandstone = sand_chunk()
	pba.artefact_props.af_lighthouse = { sounds = { "perk_sound" }, on_death = real_function(momo_source,
		"momopate_pba_tweaks", "perk_based_artefacts.artefact_props.af_lighthouse.on_death =", "\n\tend") }
	pba.artefact_on_npc_death_functions.af_sandstone = real_function(momo_source, "momopate_pba_tweaks",
		"perk_based_artefacts.artefact_on_npc_death_functions.af_sandstone =", "\n\tend")
	pba.artefact_on_npc_death_functions.af_lighthouse = function(...)
		return pba.artefact_props.af_lighthouse:on_death(...)
	end
	speed = { remove_speed = function() end, add_speed = function(name)
		if name == "af_sandstone_speed_w" then sandstone = sandstone + 1 end
	end }
	pba.n_event = function(_, f) f() end
	actor.change_health = function(self, n) self.health = self.health + n end
	local setpos = actor.set_actor_position
	actor.set_actor_position = function(self, p) lighthouse = lighthouse + 1; return setpos(self, p) end
	pba.process_artefacts = real_function(pba_source, "perk_based_artefacts", "process_artefacts = function", "\nend")
	local monster_start = assert(pba_source:find("function monster_on_before_hit(", 1, true))
	local monster_end = assert(pba_source:find("\nfunction on_key_press(", monster_start, true))
	local monster_callbacks = assert(loadstring("local last_monster_hit, last_monster_hit_bone_index\n" ..
		pba_source:sub(monster_start, monster_end - 1), "@perk_based_artefacts.script"))
	setfenv(monster_callbacks, pba)
	monster_callbacks()
	-- GAMMA's grok_bo deliberately disables this handler; a callback swap cannot restore it.
	grok_bo = {}
	pba.npc_on_death_callback = function() end
	-- The real world helper calls sim:create, bypassing _G.alife_create.
	local real_create_item_calls = 0
	function alife_create_item(sec, owner, opts)
		real_create_item_calls = real_create_item_calls + 1
		if owner[1] then
			if MODE == "client" then return nil end
			return alife_create(sec, owner[1], owner[2], owner[3], owner[4])
		end
		return alife_create(sec, owner:position(), 7, 8, owner:id())
	end
	load_script("coop_main")
	load_script("coop_mode")
	load_script("coop_mods_core")
	load_script("coop_mods_perks")
	AddScriptCallback("npc_on_death_callback")
	AddScriptCallback("npc_on_before_hit")
	AddScriptCallback("monster_on_before_hit")
	AddScriptCallback("monster_on_death_callback")
	RegisterScriptCallback("monster_on_before_hit", pba.monster_on_before_hit)
	RegisterScriptCallback("monster_on_death_callback", pba.monster_on_death_callback)
	coop_main.on_game_start()
	modes.install(coop_mode, mode)
	coop_mods_core.on_game_start()
	coop_mods_perks.on_game_start()
	coop_mods_perks.on_game_start() -- also verifies an adapter cannot install duplicate callbacks/wrappers
	local original_report = coop_mods_core.report
	coop_mods_core.report = function(...) errors = errors + 1; return original_report(...) end
	local function equip(...)
		for k in pairs(belt) do belt[k] = nil end
		for _, k in ipairs({ ... }) do belt[k] = { count = 2, ids = {}, names = {} } end
	end
	local function corpse(kind, killer)
		local _, o = spawn(kind or "dog", vec3(22, 0, 1), nil, { alive = false, kind = kind == "bandit" and "stalker" or "monster" })
		db.storage[o:id()] = { death_by_id = killer == nil and 500 or killer }
		return o
	end
	local function dispatch(o, who, npc)
		return pba.process_artefacts(npc and pba.artefact_on_npc_death_functions or pba.artefact_on_monster_death_functions,
			o, who or actor, { type = 1 }, 2)
	end
	local function confirm_mutant_kill(o)
		o._alive = true
		SendScriptCallback("monster_on_before_hit", o, { type = 1, draftsman = actor }, 2, {})
		o._alive = false
		SendScriptCallback("monster_on_death_callback", o, actor)
	end
	local function count(sec)
		local n = 0
		for _, c in ipairs(CREATED) do if c.sec == sec then n = n + 1 end end
		return n
	end
	local function mirror()
		MODE, SELF = "client", 1
		modes.install(coop_mode, mode, { leads_here = function() return false end,
			decides_world = function() return false end, actor_is_player = function() return true end,
			is_player_mirror = function() return true end })
	end
	local function authority()
		MODE, SELF = "host", 0
		modes.install(coop_mode, mode)
	end
	local function request(t, sender)
		NOW = NOW + 1000
		if mode == "srv_map" then
			t._peer = sender or 1
			coop_main.on_event("mods.pba_corpse", coop_main.encode(t), 0)
		else
			coop_main.on_event("mods.pba_corpse", coop_main.encode(t), sender or 1)
		end
	end
	print("== G7-1 death perks @" .. mode)
	if mode == "none" then
		equip("af_kogot")
		local v = corpse()
		local create_item, release = alife_create_item, alife_release_id
		confirm_mutant_kill(v)
		check(count("meat_dog") == 7 and SE[v:id()] == nil, "SP: original Momopate meat and direct release unchanged")
		check(alife_create_item == create_item and alife_release_id == release and #SENT == 0, "SP: no interception or request")
		equip("af_sandstone", "af_lighthouse")
		local n = corpse("bandit", 0)
		SendScriptCallback("npc_on_death_callback", n, actor)
		check(sandstone == 0 and lighthouse == 0, "SP: disabled GAMMA stalker callback stays disabled")
		dispatch(n, actor, true); dispatch(n, actor, true)
		check(sandstone == 2 and lighthouse == 2, "SP: original dispatcher returns unchanged, no session deduplication")
		equip("af_dragon_eye")
		local dragon_body = corpse()
		dispatch(dragon_body); run_time_events(500)
		check(count("ied_new_blow") == 1 and SE[dragon_body:id()] == nil and timer_calls == 1 and errors == 0,
			"SP: original Dragon Eye timer and synchronous spawn unchanged")
		equip("af_skull_miser")
		dispatch(corpse("bandit"), actor, true); run_time_events(500)
		check(count("money_a") == 6 and timer_calls == 7 and errors == 0 and #SENT == 0,
			"SP: original money spawning and all six fountain timers unchanged")
	else
		mirror()
		equip("af_kogot")
		local v = corpse()
		local create_item, create, release, release_id = alife_create_item, alife_create, alife_release, alife_release_id
		confirm_mutant_kill(v)
		local meat = sent("mods.pba_corpse")
		check(meat and meat.s == table.concat({"meat_dog", "meat_dog", "meat_dog", "meat_dog", "meat_dog", "meat_dog", "meat_dog"}, "|"),
			"m24:3 Momopate: base and five Lucifer pieces collected through real alife_create_item")
		check(meat and meat.r == true and SE[v:id()] ~= nil, "m24:4 direct sim release captured, local corpse retained")
		check(real_create_item_calls == 0 and count("meat_dog") == 0, "no local world item creation")
		check(alife_create_item == create_item and alife_create == create and alife_release == release and alife_release_id == release_id,
			"all four helpers restored after successful perks")
		local requests = sent_count("mods.pba_corpse")
		dispatch(v)
		check(sent_count("mods.pba_corpse") == requests, "same confirmed corpse runs once on the killer")
		-- A second adapter installation must not wrap the capture around itself.
		check(errors == 0, "no error while collecting enhanced Claw")
		local normal = corpse()
		pba.artefact_props.af_lucifer.check_lucifer = function() return false end
		confirm_mutant_kill(normal)
		local normal_meat = sent("mods.pba_corpse")
		check(normal_meat and normal_meat.s == "meat_dog|meat_dog" and normal_meat.r == false and SE[normal:id()] ~= nil,
			"ordinary Claw creates only the base pieces and leaves its corpse")
		pba.artefact_props.af_lucifer.check_lucifer = function() return true end

		equip("af_dragon_eye")
		local dragon_body = corpse()
		local before_spent = lucifer_spent
		confirm_mutant_kill(dragon_body)
		local boom = sent("mods.pba_corpse")
		check(boom and boom.v == dragon_body:id() and boom.s == "ied_new_blow" and boom.r == true,
			"m08:3 Dragon Eye: declarative explosion and release, no synchronous client id")
		check(timer_calls == 0 and errors == 0 and lucifer_spent > before_spent, "Dragon Eye finishes its remaining effects without nil.id or a client world timer")

		equip("af_skull_miser")
		local money_body = corpse("bandit")
		local torso_body = corpse("bandit")
		money_body._alive, torso_body._alive = true, true
		SendScriptCallback("npc_on_before_hit", money_body, { type = 1, draftsman = actor }, 2)
		SendScriptCallback("npc_on_before_hit", torso_body, { type = 1, draftsman = actor }, 3)
		SendScriptCallback("npc_on_before_hit", money_body, { type = 1, draftsman = other }, 3)
		local before_money = sent_count("mods.pba_corpse")
		torso_body._alive = false
		SendScriptCallback("npc_on_death_callback", torso_body, actor)
		check(sent_count("mods.pba_corpse") == before_money, "m08:3 a torso kill cannot borrow another target's head hit")
		money_body._alive = false
		SendScriptCallback("npc_on_death_callback", money_body, actor)
		local money = sent("mods.pba_corpse")
		check(money and money.v == money_body:id() and money.s == "money_a|money_a|money_a|money_a|money_a|money_a",
			"m08:3 Miser's Skull: confirmed headshot uses this target's owner hit and collects all six items")
		check(errors == 0 and timer_calls == 0, "money perk creates no unresolved world timer on the client")

		equip("af_dragon_eye")
		local old_random = math.random
		math.random = function() return 0.99 end
		local unproc = corpse("bandit")
		unproc._alive = true
		SendScriptCallback("npc_on_before_hit", unproc, { type = 1, draftsman = actor }, 2)
		unproc._alive = false
		local before_dragon = sent_count("mods.pba_corpse")
		SendScriptCallback("npc_on_death_callback", unproc, actor)
		check(sent_count("mods.pba_corpse") == before_dragon, "GAMMA stalker Dragon Eye cannot inherit the default successful roll")
		math.random = function() return 0 end
		local proc = corpse("bandit")
		proc._alive = true
		SendScriptCallback("npc_on_before_hit", proc, { type = 1, draftsman = actor }, 2)
		proc._alive = false
		SendScriptCallback("npc_on_death_callback", proc, actor)
		math.random = old_random
		local stalker_explosion = sent("mods.pba_corpse")
		check(stalker_explosion and stalker_explosion.v == proc:id() and stalker_explosion.s == "ied_new_blow"
			and stalker_explosion.r == true and pba.artefact_props.af_dragon_eye.dice_roll == 0,
			"GAMMA stalker Dragon Eye can still proc without changing the mutant's roll")

		equip("af_sandstone", "af_lighthouse")
		local stalker = corpse("bandit")
		SendScriptCallback("npc_on_death_callback", stalker, other)
		check(sandstone == 0 and lighthouse == 0, "m24:1 another player's stalker kill grants neither bonus")
		SendScriptCallback("npc_on_death_callback", stalker, actor)
		SendScriptCallback("npc_on_death_callback", stalker, actor)
		check(sandstone == 1 and lighthouse == 1, "m24:1 confirmed callback restores GAMMA's disabled stalker table")
		dispatch(stalker, actor, true)
		check(sandstone == 1 and lighthouse == 1 and actor._tp and actor._tp.x == 22, "m24:1 disabled GAMMA stalker table restored for the killer, exactly once")
		local alive = corpse("bandit"); alive._alive = true
		SendScriptCallback("npc_on_death_callback", alive, actor)
		check(sandstone == 1, "no bonus for a death not applied to the mirror")

		-- Inventory destinations and failures must retain the original helper and restore globals.
		pba.artefact_on_monster_death_functions.inventory = function() alife_create_item("meat_dog", actor) end
		equip("inventory"); dispatch(corpse())
		check(CREATED[#CREATED] and CREATED[#CREATED].parent == 0 and real_create_item_calls == 1, "inventory creation still uses the original helper")
		pba.artefact_on_monster_death_functions.fault = function() error("foreign perk failed") end
		equip("fault"); dispatch(corpse())
		check(alife_create_item == create_item and alife_create == create and alife_release == release and alife_release_id == release_id,
			"all helpers restored after an error in the mod")
		local failed_requests = sent_count("mods.pba_corpse")
		local after_fault = corpse()
		pba.artefact_on_monster_death_functions.fault = function()
			alife_create_item("meat_dog", { after_fault:position(), 7, 8 }); error("foreign perk failed after creating loot")
		end
		dispatch(after_fault); dispatch(after_fault)
		check(sent_count("mods.pba_corpse") == failed_requests + 1 and alife_create_item == create_item,
			"collected loot still sent after a mod error, once, with helper restored")
		pba.artefact_on_monster_death_functions.many = function(victim_actor, n, ids, names, victim)
			for _ = 1, 40 do alife_create_item("meat_dog", { victim:position(), 7, 8 }) end
		end
		equip("many"); dispatch(corpse())
		local capped = sent("mods.pba_corpse")
		check(capped and #capped.s == #string.rep("meat_dog|", 25) - 1, "client capture bounded to 25 sections")

		authority()
		coop_trust.reset_for_test({ default = "refuse" })
		CREATED, SENT = {}, {}
		equip("af_sandstone", "af_lighthouse")
		local before_authority = sandstone
		dispatch(corpse("bandit", 0), actor, true)
		check(sandstone == before_authority + (mode == "hostplay" and 1 or 0),
			mode .. ": own host kill unchanged; a server's ghost has no death perks")
		if mode == "srv_world" then
			coop.is_dedicated = function() return true end
			coop.levels = { bridge_of_player = function(peer) return ({ [1] = 0x101, [2] = 0x102 })[peer] end }
			modes.live(coop_mode)
			request({ v = v:id(), s = "meat_dog", r = true, _peer = 2 }, 1)
			local forwarded, raw = sent("mods.pba_corpse")
			check(#CREATED == 0 and SE[v:id()] ~= nil, "Server world: never creates/releases bodies on its empty map")
			check(forwarded and forwarded._peer == 1 and raw.target == 0x101, "Server world: forwards request with transport sender to the player's map")
			request({ v = v:id(), s = "meat_dog", r = true, _peer = 1 }, 2)
			local second, second_raw = sent("mods.pba_corpse")
			check(second and second._peer == 2 and second_raw.target == 0x102 and #CREATED == 0,
				"Server world: the other player's request goes to his different map")
		else
			-- Recreate the sender's avatar and the confirmed death as seen by the decider.
			request(meat or { v = v:id(), s = "", r = false })
			check(count("meat_dog") == 7 and SE[v:id()] == nil, mode .. ": loot created once on decider and corpse released")
			local made = #CREATED
			request(meat or { v = v:id(), s = "", r = false })
			check(#CREATED == made, mode .. ": replay never creates duplicate loot")
			local _, replacement = spawn("dog", vec3(22, 0, 1), nil, { id = v:id(), alive = false, kind = "monster" })
			db.storage[replacement:id()] = { death_by_id = 500 }
			request({ v = replacement:id(), s = "meat_dog", r = false })
			check(#CREATED == made + 1 and SE[replacement:id()] ~= nil, mode .. ": a fresh kill can reuse a served object id")
			request(boom or { v = dragon_body:id(), s = "", r = false })
			run_time_events(500)
			local exploded = false
			for _, o in pairs(OBJ) do if o._sec == "ied_new_blow" and o._exploded then exploded = true end end
			check(exploded and SE[dragon_body:id()] == nil, mode .. ": decider explodes Dragon Eye and releases corpse")
			request(money or { v = money_body:id(), s = "", r = false })
			check(count("money_a") == 6, mode .. ": money created on decider once")
			run_time_events(500)
			local fountains = 0
			for _, o in pairs(OBJ) do
				local f = o._force
				if o._sec == "money_a" and f and f[1] >= 125 and f[1] <= 325 and f[2] == f[1] * 5 and f[3] == f[1] then
					fountains = fountains + 1
				end
			end
			check(fountains == 6, mode .. ": money fountain physics deferred to online objects on decider")
			local bad = corpse("bandit", 0)
			local before = #CREATED
			request({ v = bad:id(), s = "money_a", r = true, from = 0 })
			check(#CREATED == before and SE[bad:id()] ~= nil, "transport sender cannot claim someone else's kill")
			local killed_check = coop_trust.status().pba_corpse_killer
			check(killed_check and killed_check.failed == 1, "killer check goes through coop_trust")
			local forbidden = corpse()
			request({ v = forbidden:id(), s = "forbidden", r = false })
			check(count("forbidden") == 0 and coop_trust.status().pba_corpse_section ~= nil, "section whitelist checked through coop_trust")
			for _, id in ipairs({ -1, 0, 0.5, 65535, math.huge, "nan" }) do request({ v = id, s = "money_a" }) end
			local bounds = coop_trust.status().pba_corpse_id
			check(bounds and bounds.failed == 6, "each malformed/unbounded client id checked before use")
			local long = corpse()
			request({ v = long:id(), s = string.rep("meat_dog|", 40), r = false })
			check(count("meat_dog") <= 33, "world loot count bounded to 25 per corpse")
			equip("af_sandstone", "af_lighthouse")
			local prior = sandstone
			SendScriptCallback("npc_on_death_callback", corpse("bandit"), other)
			check(sandstone == prior, "decider never grants its own belt bonus for the client's kill")
			coop_trust.reset_for_test({ default = "log" })
			local marker = "CLIENT_LINE\n%08x"
			request({ v = marker, s = "money_a" })
			request({ v = corpse():id(), s = marker })
			local trust = coop_trust.status()
			check(trust.pba_corpse_id and trust.pba_corpse_id.failed == 1
				and trust.pba_corpse_section and trust.pba_corpse_section.failed == 1,
				"new trust diagnostics default to log mode")
			check(log_has(marker) == nil, "client-controlled strings never become a log format or console line")
			local mixed = corpse()
			local before_mixed = count("meat_dog")
			request({ v = mixed:id(), s = "meat_dog", r = "true" })
			check(count("meat_dog") == before_mixed + 1 and SE[mixed:id()] ~= nil,
				"payload log mode keeps valid loot and ignores a non-boolean release")
			coop_trust.reset_for_test({ default = "refuse" })
			local before_refuse = count("meat_dog")
			request({ v = corpse():id(), s = "meat_dog", r = "true" })
			local payload_check = coop_trust.status().pba_corpse_payload
			check(count("meat_dog") == before_refuse and payload_check and payload_check.refused == 1,
				"payload refuse mode rejects the same malformed request")
		end
		-- Install against the unmodified PBA variant too: the source selected by a modpack differs.
		mirror()
		local base_props = { af_kogot = { dice_roll = 0, monster_to_meat = { dog = "meat_dog" },
			valid_hits = { [1] = true }, on_death = base_claw }, af_lucifer = pba.artefact_props.af_lucifer }
		local original_props = pba.artefact_props
		pba.artefact_props = base_props
		local base_mod = { artefact_props = base_props, artefact_on_monster_death_functions = pba.artefact_on_monster_death_functions,
			artefact_on_npc_death_functions = {}, process_artefacts = function(_, victim, who, h, b)
				return base_props.af_kogot:on_death(actor, 2, {}, {}, victim, who, h, b)
			end }
		perk_based_artefacts = base_mod
		load_script("coop_mods_perks").on_game_start()
		SENT = {}
		local base_body = corpse()
		base_mod.process_artefacts(base_mod.artefact_on_monster_death_functions, base_body, actor, { type = 1 }, 2)
		local plain = sent("mods.pba_corpse")
		check(plain and plain.s == "meat_dog|meat_dog|meat_dog|meat_dog|meat_dog|meat_dog|meat_dog" and plain.r == true
			and SE[base_body:id()] ~= nil, "m08:3 base PBA captures enhanced meat and direct corpse release")
		pba.artefact_props = original_props
	end
	check(registered.perk_based_artefacts_cooldowns and registered.perk_based_artefacts_lucifer_condition,
		"existing saved player keys still registered")
	done("mods_perks_death " .. mode)
end
