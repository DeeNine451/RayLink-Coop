-- Dev 57 G3-2: run the enabled GAMMA mods with controlled inventories and native delivery.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or mode == "hostplay" and "host" or "client"
dofile("tests/lua/support/stubs_mods.lua")

local function corpus(name)
	local path = "temp/review/corpus/merged/" .. name .. ".script"
	local file = io.open(path, "rb")
	if not file then
		path = assert(os.getenv("GAMMA_SCRIPTS"), name .. ": GAMMA scripts required") .. "/" .. name .. ".script"
		file = assert(io.open(path, "rb"))
	end
	local source = file:read("*a"):gsub("^\239\187\191", "")
	file:close()
	local mod = setmetatable({}, { __index = _G })
	_G[name] = mod
	setfenv(assert(loadstring(source, "@" .. path)), mod)()
	return mod
end

local state = alife_storage_manager.get_state()
local sil_key = "3dss_silencer_condition"
local transition = "3dss_silencer_condition_level_transition"
local sil_section = "test_suppressor"
local source_sec, reward_sec = "test_old_outfit", "test_reward_outfit"
local actor = make_actor()
local function item(section, id, owner, condition, name)
	local se, obj = spawn(section, vec3(0, 0, 0), owner, { id = id, cond = condition })
	se.name = function() return name or (section .. "_" .. id) end
	return obj
end
local function weapon(id, name)
	local obj = item("test_weapon", id, actor:id(), nil, name)
	obj._silencer = sil_section
	return obj
end
local function wear(obj, condition)
	se_save_var(obj:id(), nil, sil_key, { version = 1, section = sil_section, condition = condition })
end
local function carried_vars(old_id)
	local copied = {}
	for k, v in pairs(state.se_object[old_id] or {}) do
		if k ~= sil_key then copied[k] = v end
	end
	return copied
end
function se_load_var(id, _, key)
	local se = state.se_object[id]
	return se and se[key]
end
function se_save_var(id, _, key, value)
	state.se_object[id] = state.se_object[id] or { name = SE[id]:name() }
	state.se_object[id][key] = value
end
function IsWeapon(obj) return obj._silencer ~= nil end
function IsItem(kind, section) return kind == "sil" and section == sil_section end
utils_item = {
	get_attached_silencer = function(obj) return obj._silencer end,
	is_degradable = function(_, section) return section == reward_sec end,
	collect_amount = function(owner, section)
		local ids = {}
		owner:iterate_inventory(function(_, obj)
			if obj:section() == section then ids[obj:id()] = 1 end
		end)
		return ids
	end,
}
function random_key_table(t) return next(t) end

INI[source_sec], INI[reward_sec] = {}, {}
local balance, pending_spawn, pending_transfer = 100
local original_create, original_alife = alife_create_item, alife
actor.money = function() return balance end
itms_manager = { create_item = original_create }
function alife_create_item(...) return itms_manager.create_item(...) end
function alife()
	local sim = original_alife()
	sim.create = function(_, section, _, _, _, parent, registered)
		assert(registered == false, "the mirror must set condition before native registration")
		return { section = section, parent_id = parent }
	end
	sim.register = function(_, se)
		pending_spawn = function()
			return original_create(se.section, OBJ[se.parent_id], { cond = se.condition })
		end
		return nil -- no leased ID, the authority delivers the conditioned reward later
	end
	return sim
end
utils_stpk = {
	get_item_data = function() return {} end,
	set_item_data = function(data, se) se.condition = data.condition end,
}
local paid = 0
news_manager = { relocate_item = function() end }
local function npc_of(first, second) return first:id() == actor:id() and second or first end
dialogs = {
	who_is_npc = npc_of,
	relocate_item_section_from_actor = function(first, second, section)
		actor:transfer_item(actor:object(section), npc_of(first, second))
	end,
	relocate_money_from_actor = function(_, _, cost) balance, paid = balance - cost, paid + cost end,
	relocate_item_section_to_actor = function(first, second, section)
		local npc = npc_of(first, second)
		local ready = npc:object(section)
		if ready then return npc:transfer_item(ready, actor) end
		pending_spawn = function() return alife_create_item(section, actor) end
	end,
}
mlr_utils = { have_item = function(section) return actor:object(section) ~= nil end }
demonized_time_events = { CreateTimeEvent = CreateTimeEvent }
grok_armor_convert = { dolg_light = { [source_sec] = true, reward = reward_sec, cost = 12 } }

local silencer = corpus("z_3dss_silencer_condition")
local armor = corpus("grok_armor_trade")
AddScriptCallback("on_before_level_changing")
AddScriptCallback("actor_on_weapon_fired")
local function switch_role(role, peer)
	MODE, SELF, PROXY = role, peer or 0, peer == 2 and 501 or 500
end
coop.is_map_server = function() return MODE == "map" end
coop.is_dedicated = function() return MODE == "world" end
coop.levels = { split = function() return mode == "srv_map" or mode == "srv_world" end }
start_all()
if mode == "srv_map" or mode == "srv_world" then
	modes.install(coop_mode, mode)
end
local adapter = coop_mods_armor_trade
if adapter then adapter.on_game_start() end
coop_economy_mdata.on_game_start()
silencer.on_game_start()
local function restore(ms)
	SendScriptCallback("actor_on_first_update")
	run_time_events(ms or 0)
end
local function condition(obj) return silencer.get_attached_silencer_condition(obj) end

if mode == "none" then
	local original = weapon(700, "before")
	wear(original, 0.26)
	SendScriptCallback("on_before_level_changing")
	release_id(700)
	local replacement = weapon(701, "after")
	restore()
	check(condition(replacement) == 0.26, "single player retains the stock by-section transition fallback")
	local npc = item("trader", 710)
	item(source_sec, 711, actor:id(), 0.35)
	local reward = item(reward_sec, 712, npc:id(), 0.83)
	armor.duty_light(actor, npc)
	run_time_events(300)
	check(reward:condition() == 0.35 and paid == 12, "single player retains the original armour exchange")
else
	if mode == "srv_map" or mode == "srv_world" then
		switch_role(mode == "srv_map" and "map" or "world")
		local ghost_item = weapon(699, "ghost")
		wear(ghost_item, 0.12)
		SendScriptCallback("on_before_level_changing")
		check(state[transition] == nil, mode .. ": authority's ghost never captures a player snapshot")
		release_id(699)
		local trader = item("trader", 698)
		local ghost_suit = item(source_sec, 697, actor:id(), 0.12)
		armor.duty_light(actor, trader)
		check(ghost_suit:parent():id() == actor:id() and paid == 0,
			mode .. ": the armour dialogue never runs on the authority's ghost")
		release_id(697)
		modes.live(coop_mode)
		switch_role("client", 1)
	end

	local first = weapon(700, "first_player_weapon")
	wear(first, 0.26)
	SendScriptCallback("on_before_level_changing")
	local first_snapshot = state[transition]
	local first_vars = carried_vars(700)
	release_id(700)
	state.se_object[700] = nil
	switch_role("client", mode == "hostplay" and 1 or 2)
	local second = weapon(701, "second_player_weapon")
	wear(second, 0.77)
	restore()
	check(condition(second) == 0.77 and state[transition] == nil,
		"same-section weapons on two characters keep their own wear after a foreign snapshot")
	check(first_snapshot ~= nil, "the first character captured its worn suppressor")

	SendScriptCallback("on_before_level_changing")
	local second_vars = carried_vars(701)
	release_id(701)
	state.se_object[701] = nil
	local decoy = weapon(701, "second_player_weapon")
	restore()
	local moved = weapon(702, "second_player_weapon")
	run_time_events(50)
	check(condition(moved) == 1, "an online item without its SE identity is still waiting for metadata")
	state.se_object[702] = second_vars
	run_time_events(50)
	check(condition(moved) == 0.77 and condition(decoy) == 1,
		"an exact instance arriving late with a new ID wins over a same-section item reusing its old ID")
	check(coop_economy_mdata.apply_se(moved:id(), sil_key, {
		version = 1, section = sil_section, condition = 0.64,
	}) and condition(moved) == 0.64, "a synchronized SE record arriving later replaces the mirror fallback")

	local synchronized = weapon(704, "synchronized_weapon")
	wear(synchronized, 0.33)
	SendScriptCallback("on_before_level_changing")
	wear(synchronized, 0.42)
	restore()
	check(condition(synchronized) == 0.42, "synchronized SE wear has priority over the same instance's saved snapshot")
	check(state[transition] == nil, "the restored snapshot is consumed")

	if mode == "hostplay" then
		switch_role("host", 0)
		state[transition] = first_snapshot
		local returned = weapon(703, "first_player_weapon")
		state.se_object[703] = first_vars
		restore()
		check(condition(returned) == 0.26, "the co-op host keeps his own worn suppressor")
		switch_role("client", 1)
	end

	local npc = item("trader", 710)
	local surrendered = item(source_sec, 711, actor:id(), 0.35)
	local already_owned = item(reward_sec, 712, actor:id(), 0.83)
	SendScriptCallback("actor_on_update") -- the live client's guard installs cond_create here
	armor.duty_light(actor, npc)
	run_time_events(500)
	local se = pending_spawn and pending_spawn()
	check(se and OBJ[se.id]:condition() == 0.35, "reward created after 500 ms already carries the traded wear")
	check(already_owned:condition() == 0.83, "a delayed reward never changes the player's existing same-section armor")
	check(surrendered:parent():id() == npc:id() and paid == 12, "the exchange transfers one suit and charges once")

	item(source_sec, 713, actor:id(), 0.18)
	local ready = item(reward_sec, 714, npc:id(), 0.91)
	npc.transfer_item = function(_, obj, to)
		pending_transfer = function() SE[obj:id()].parent_id = to:id() end
	end
	armor.duty_light(actor, npc)
	run_time_events(500)
	check(ready:condition() == 0.91, "ready reward stays unchanged before the transfer is confirmed")
	if pending_transfer then pending_transfer() end
	run_time_events(50)
	check(ready:parent():id() == actor:id() and ready:condition() == 0.18,
		"the transferred reward receives the traded wear on confirmation by exact ID")
	check(already_owned:condition() == 0.83 and paid == 24, "ready reward leaves duplicate armor alone and charges once")

	if mode == "hostplay" then
		switch_role("host", 0)
		item(source_sec, 715, actor:id(), 0.54)
		pending_spawn = nil
		local count = #CREATED
		armor.duty_light(actor, npc)
		local created = CREATED[count + 1]
		check(created and created.cond == 0.54 and pending_spawn == nil and paid == 36,
			"the playing host creates his exact reward with wear and charges once")
	end
end

done("SILENCER TRANSITIONS AND ARMOUR EXCHANGE " .. mode)
