-- Dev 57 G4-2. Run the real 3DSS Lua over controlled inventory and network events.
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local thermal_key = "3dss_thermal_battery"
local silencer_key = "3dss_silencer_condition"
local scope_section, sil_section, cell = "thermal_scope", "test_silencer", "test_battery"
local data, functors, canted, leases = {}, {}, {}, {}
local leases_available = 0
local function state(obj, key) return data[obj:id()] and data[obj:id()][key] end
function se_load_var(id, _, key) return data[id] and data[id][key] end
function se_save_var(id, _, key, value)
	data[id] = data[id] or {}
	data[id][key] = value
end

local actor = make_actor()
actor.active_item = function() end
local _, avatar = spawn("coop_player_avatar", vec3(10, 0, 0), nil, { id = 500 })
avatar._kind = "stalker"
INI[scope_section] = { s3ds_image_type = 2 }
INI[sil_section] = { silencer_condition_per_shot = 0.05 }
INI[cell] = {}
INI[thermal_key] = { battery_section = cell }
function ini_file_ex() return { collect_section = function() return {} end } end
function IsItem(kind, section) return kind == "sil" and section == sil_section end
function IsWeapon(obj) return obj and obj._weapon == true end
coop.lease_ids = function() return leases_available end
coop.lease_waiting = function(id) return leases[id] == true end

local function item(owner, section)
	local _, obj = spawn(section, vec3(0, 0, 0), owner)
	return obj
end
local function gun(owner)
	local obj = item(owner, "weapon")
	obj._weapon = true
	obj.cast_Weapon = function(self) return self end
	obj.GetZoomType = function() return 0 end
	obj.weapon_in_grenade_mode = function() return false end
	return obj
end
local function charge(obj, slot, value)
	if slot == "loose" then obj:set_condition(value) end
	se_save_var(obj:id(), nil, thermal_key, { version = 2, [slot] = { section = scope_section, charge = value } })
end
local function get_charge(obj, slot)
	if slot == "loose" then return obj:condition() end
	local record = state(obj, thermal_key)
	return record and record[slot] and record[slot].charge
end
local function close(a, b) return type(a) == "number" and math.abs(a - b) < 0.000001 end

custom_functor_autoinject = {
	add_functor = function(key, visible, label, enabled, action)
		functors[key] = { cond_name = visible, func_name = label, cond_action = enabled or visible, func_action = action }
	end,
}
utils_obj = { play_sound = function() end }
local defer_removal = false
utils_item = {
	can_attach_silencer = function(weapon, addon) return not weapon._silencer and IsItem("sil", addon:section()) end,
	get_attached_silencer = function(weapon) return weapon._silencer end,
	attach_addon = function(weapon, addon)
		if not utils_item.can_attach_silencer(weapon, addon) then return end
		weapon._silencer = addon:section()
		if not defer_removal then release_id(addon:id()) end
	end,
}
scripted_canted_irons = {
	get_installed_section = function(weapon) return canted[weapon:id()] end,
	remove_irons = function(weapon)
		local section = canted[weapon:id()]
		if not section then return end
		local created = alife_create_item(section, db.actor, { cond = 0.23 })
		z_3dss_thermal_battery.on_canted_removed(weapon, created, section)
		canted[weapon:id()] = nil
	end,
}

local function corpus(name)
	local path = "temp/review/corpus/merged/" .. name .. ".script"
	local fh = io.open(path, "rb")
	if not fh then
		local dir = os.getenv("GAMMA_SCRIPTS")
		assert(dir, "3DSS GAMMA script fixture required: " .. path)
		path = dir .. "/" .. name .. ".script"
		fh = assert(io.open(path, "rb"))
	end
	local source = fh:read("*a"):gsub("^\239\187\191", "")
	fh:close()
	local fn = assert(loadstring(source, "@" .. path))
	local mod = setmetatable({}, { __index = _G })
	_G[name] = mod
	setfenv(fn, mod)()
	return mod
end

start_all()
local xchg = load_script("coop_mods_xchg")
xchg.on_game_start()
local set = modes.install(coop_mode, name)
if name == "srv_map" then
	coop.is_host = function() return false end
	coop.is_map_server = function() return true end
end
coop_trust.reset_for_test({ default = "refuse" })
local thermal = corpus("z_3dss_thermal_battery")
local silencer = corpus("z_3dss_silencer_condition")
AddScriptCallback("actor_on_weapon_fired")
local adapter = coop_mods_xchg_3dss
if adapter then adapter.on_game_start() end
thermal.on_game_start()
silencer.on_game_start()
local function tick(ms)
	NOW = NOW + (ms or 100)
	SendScriptCallback("actor_on_update")
	run_time_events(0)
end
SendScriptCallback("actor_on_first_update")
tick()
local battery = assert(functors["3dss_remove_thermal_battery"])

local function request(source, seq, peer)
	local t = { k = "3dss_batt", o = "1:0:" .. seq, key = source, src = source }
	local transport = peer or 1
	if name == "srv_map" then t._peer, transport = transport, 0 end
	coop_main.on_event("mods.xchg", coop_main.encode(t), transport)
	return sent("mods.xchg_r") or {}
end

if name == "hostplay" or name == "srv_map" then
	local fresh = item(500, scope_section)
	fresh:set_condition(1)
	local gifts = #CREATED
	request(fresh:id(), 991, 1)
	check(#CREATED == gifts and sent("mods.xchg_r").ok == false,
		name .. " uninitialized stock scope has no extractable battery")
	local own, foreign = item(500, scope_section), item(0, scope_section)
	charge(own, "loose", 0.91) -- a saved row can be behind the authoritative item
	own:set_condition(0.34)
	local denied = item(500, scope_section)
	charge(denied, "loose", 0.5)
	denied.set_condition = function() end
	request(denied:id(), 992, 1)
	check(#CREATED == gifts and sent("mods.xchg_r").ok == false and close(denied:condition(), 0.5),
		name .. " no output when the writer's debit cannot be applied")
	charge(foreign, "loose", 0.77)
	local before = #CREATED
	local a = request(own:id(), 1)
	local made = CREATED[before + 1]
	check(a.ok and made and made.sec == cell and made.parent == 500 and close(made.cond, 0.34)
		and get_charge(own, "loose") == 0, name .. " m02:1 own-bag extraction carries charge and debits at authority")
	check(request(own:id(), 1).ok == true and #CREATED == before + 1,
		name .. " m02:1 duplicate op creates one battery")
	check(request(own:id(), 2).ok == false and #CREATED == before + 1,
		name .. " m02:1 second operation cannot reuse the charge")
	a = request(foreign:id(), 3)
	local trust = coop_trust.status().xchg_3dss_batt or {}
	check(a.ok == false and trust.refused == 1 and close(get_charge(foreign, "loose"), 0.77),
		name .. " m02:1 foreign bag is refused through coop_trust")
	a = request(65535, 4)
	check(a.ok == false and (coop_trust.status().xchg_3dss_batt or {}).refused == 2,
		name .. " m02:1 out-of-range ID is refused through coop_trust")
	local weapon = gun(500)
	charge(weapon, "main", 0.48)
	local create = _G.alife_create_item
	_G.alife_create_item = function(section, ...) if section ~= cell then return create(section, ...) end end
	a = request(weapon:id(), 5)
	_G.alife_create_item = create
	check(a.ok == false and close(get_charge(weapon, "main"), 0.48),
		name .. " m02:1 failed creation leaves the weapon charged")
	if name == "hostplay" then
		battery.func_action(foreign)
		check(#CREATED == before + 2 and get_charge(foreign, "loose") == 0 and sent_count("mods.xchg") == 0,
			"hostplay m02:1 the host player uses the same decider locally")
	else
		a = request(weapon:id(), 6, 2)
		check(a.ok == false and close(get_charge(weapon, "main"), 0.48),
			"srv_map m02:1 a peer whose body is on another map cannot debit the source here")
	end

	-- Exercise the owner's UI from a player process after the role-specific authority checks.
	MODE, SELF = "client", 1
	if name == "srv_map" then coop.is_map_server = function() return false end end
	modes.install(coop_mode, name, {
		actor_is_player = function() return true end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		decider = function() return "other" end,
	})
	local local_scope, other_scope = item(0, scope_section), item(500, scope_section)
	charge(local_scope, "loose", 0.61)
	charge(other_scope, "loose", 0.55)
	before = #CREATED
	check(battery.cond_name(local_scope) and not battery.cond_name(other_scope) and not battery.cond_action(other_scope),
		name .. " m02:1 extraction is visible only in the player's own inventory")
	battery.func_action(other_scope)
	battery.func_action(local_scope)
	battery.func_action(local_scope)
	local req = sent("mods.xchg") or {}
	check(sent_count("mods.xchg") == 1 and req.k == "3dss_batt" and req.src == local_scope:id()
		and #CREATED == before and close(get_charge(local_scope, "loose"), 0.61),
		name .. " m02:1 a client sends one exchange and waits for authority")
	coop_main.on_event("mods.xchg_r", coop_main.encode({ o = req.o, ok = true,
		["r.slot"] = "loose", ["r.section"] = scope_section }), 0)
	check(close(get_charge(local_scope, "loose"), 0.61) and close(local_scope:condition(), 0.61),
		name .. " m02:1 acknowledgement leaves the player's charge to replication")

	local provisional = gun(0)
	charge(provisional, "canted", 0.42)
	local offline = spawn(scope_section, vec3(0, 0, 0), 0, { offline = true })
	local queued_charge
	local process_item = alife_process_item
	alife_process_item = function(section, id, fields)
		if section == scope_section and id == offline.id then queued_charge = fields.cond end
	end
	z_3dss_thermal_battery.on_canted_removed(provisional, offline, scope_section)
	alife_process_item = process_item
	check(close(queued_charge, 0.42), name .. " native mirror detach preserves charge while its replacement is offline")
	release_id(offline.id)
	release_id(provisional:id())

	local w = gun(0)
	charge(w, "canted", 0.23)
	canted[w:id()] = scope_section
	scripted_canted_irons.remove_irons(w)
	check(#CREATED == before and canted[w:id()] == scope_section and close(get_charge(w, "canted"), 0.23),
		name .. " m02:4 no leased ID refuses detach before changing state")
	local create_scope = _G.alife_create_item
	_G.alife_create_item = function(section, ...)
		local se = create_scope(section, ...)
		if section == scope_section then leases[se.id] = true end
		return se
	end
	leases_available = 1
	scripted_canted_irons.remove_irons(w)
	local exact = CREATED[#CREATED]
	local exact_obj = exact and OBJ[exact.id]
	scripted_canted_irons.remove_irons(w)
	check(#CREATED == before + 1, name .. " m02:4 a second detach cannot create another scope while waiting")
	local decoy = item(0, scope_section)
	charge(decoy, "loose", 0.82)
	tick()
	check(exact and exact.sec == scope_section and canted[w:id()] == scope_section and close(get_charge(w, "canted"), 0.23),
		name .. " m02:4 charge stays on source while concrete create waits")
	if exact then leases[exact.id] = nil end
	tick()
	_G.alife_create_item = create_scope
	check(exact_obj and close(get_charge(exact_obj, "loose"), 0.23) and close(get_charge(decoy, "loose"), 0.82)
		and not canted[w:id()] and not get_charge(w, "canted"), name .. " m02:4 acknowledgement transfers to the exact scope")
	w = gun(0)
	charge(w, "canted", 0.66)
	canted[w:id()] = scope_section
	_G.alife_create_item = function(section, ...)
		local se = create_scope(section, ...)
		leases[se.id] = true
		return se
	end
	scripted_canted_irons.remove_irons(w)
	local denied = CREATED[#CREATED].id
	release_id(denied)
	leases[denied] = nil
	tick()
	_G.alife_create_item = create_scope
	check(canted[w:id()] == scope_section and close(get_charge(w, "canted"), 0.66),
		name .. " m02:4 rejected create leaves the scope installed and charged")

	defer_removal = true
	for _, old in ipairs({ false, 0.91, 0.01 }) do
		w = gun(0)
		if old then se_save_var(w:id(), nil, silencer_key, { version = 1, section = sil_section, condition = old }) end
		local s = item(0, sil_section)
		s:set_condition(0.37)
		utils_item.attach_addon(w, s, "sil")
		check(w._silencer == sil_section and SE[s:id()] ~= nil, name .. " m02:2 installation can precede removal")
		SendScriptCallback("actor_on_weapon_fired", actor, w)
		SE[s:id()] = nil -- the game object takes another frame to disappear
		tick()
		check(not close(coop_mods_items.native_silencer_state(w, false), 0.32),
			name .. " m02:2 condition is still pending while consumable exists")
		release_id(s:id())
		tick()
		check(close(coop_mods_items.native_silencer_state(w, false), 0.32),
			name .. " m02:2 confirmed removal commits captured condition minus wear, old=" .. tostring(old))
	end
elseif name == "srv_world" then
	local own = item(500, scope_section)
	charge(own, "loose", 0.45)
	request(own:id(), 1)
	local relayed, raw = sent("mods.xchg")
	check(relayed and relayed._peer == 1 and raw.target == set.bridge and #CREATED == 0
		and close(get_charge(own, "loose"), 0.45), "srv_world: relays battery request without touching inventory")
else
	local own = item(0, scope_section)
	charge(own, "loose", 0.56)
	check(battery.cond_name(own) and battery.func_name(own), "none: original battery menu works")
	battery.func_action(own)
	check(#CREATED == 1 and close(CREATED[1].cond, 0.56) and get_charge(own, "loose") == 0
		and sent_count("mods.xchg") == 0, "none: original extraction works locally")
	local w = gun(0)
	charge(w, "canted", 0.23)
	canted[w:id()] = scope_section
	scripted_canted_irons.remove_irons(w)
	check(#CREATED == 2 and close(get_charge(OBJ[CREATED[2].id], "loose"), 0.23)
		and not canted[w:id()], "none: original canted removal works without leased IDs")
	local s = item(0, sil_section)
	s:set_condition(0.37)
	utils_item.attach_addon(w, s, "sil")
	check(close(coop_mods_items.native_silencer_state(w, false), 0.37), "none: original attachment uses the item condition")
end

done("mods_xchg_3dss@" .. name)
