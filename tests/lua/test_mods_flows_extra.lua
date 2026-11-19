-- HF radio, stove, harvester, showcase, WPO, QAW: host (MODE_ARG = "host") or client (default).
local which = MODE_ARG or "client"
MODE = which
dofile("tests/lua/support/stubs_mods.lua")
print("== extra flows (" .. which .. ")")
make_actor(vec3(20, 0, 0))
local _, other = spawn("coop_player_avatar", vec3(20, 0, 1), nil, { id = 500 })
other._kind = "stalker"
local function from(name, t, peer) coop_main.on_event("mods." .. name, coop_main.encode(t), peer) end

-- placed radio (Hideout Furniture): module with file locals, wrapper class
SOUND_DIRS["radio\\_channel_1\\"] = { "a.ogg", "b.ogg" }
SOUND_DIRS["radio\\_session_1\\"] = { "id.ogg" }
local WR = {}
do
	local path_radio_ch, path_radio_session = { "radio\\_channel_1\\" }, { "radio\\_session_1\\" }
	local radio_vol, psi_vol, safety_lock = 0.6, 0, false
	local W = {}
	function W.update(w) LOCK_SEEN = safety_lock; UPDATES = (UPDATES or 0) + 1 end
	function W.action_radio_start(w) w.radio_state = true; w.radio_selected = 1; w.radio_ch[1][1]:play() end
	function W.action_radio_stop(w) w.radio_state = false end
	function W.action_radio_ch(w, ch) w.radio_selected = ch; return path_radio_ch, path_radio_session, radio_vol, psi_vol end
	function W.action_radio_v_up() radio_vol = radio_vol + 0.1 end
	function W.action_radio_v_down() radio_vol = radio_vol - 0.1 end
	placeable_radio = { placeable_radio_wrapper = W, UIFurnitureRadio = { Pickup = function() end } }
end
bind_hf_base = { hf_binder_wrapper = { pickup = function() end }, get_wrapper = function(id) return WR[id] end }
local function new_radio(id)
	local _, obj = spawn("hf_radio", vec3(21, 0, 0), nil, { id = id })
	local w = { object = obj, radio_ch = { { sound_object("a"), sound_object("b") } }, radio_session = { { sound_object("id") } },
		radio_ch_out = { {} }, radio_session_out = { {} }, radio_now = { 1 }, radio_session_now = { 1 }, radio_selected = 0, radio_state = false }
	WR[id] = w
	return w
end

-- stove (HF Expansion), harvester and showcase (Gadgets)
ui_stove_furniture = {
	access_inventory = function(obj)
		local m = alife_storage_manager.get_state()
		m.stove_stashes = m.stove_stashes or {}
		m.stove_stashes[obj:id()] = m.stove_stashes[obj:id()] or spawn("inv_box", vec3(21, 0, 2)).id
		CreateTimeEvent(obj:id(), "container", 0.1, function() HOST_OPENED_STOVE = true return true end)
	end,
	start_dialog = function() end,
	UICookStove = { UseCook = function() COOKED = true end },
}
HARV = {}
HARV_DATA = {} -- harvester id -> the mod's data
HARV_MOVES = {}
EDDListType = { iActorBag = 1 }
INI.placeable_artifact_harvester = { integrated_storage = "harvester_box" }
hf_obj_manager = hf_obj_manager or {}
hf_obj_manager.get_data = hf_obj_manager.get_data or function(id) return HARV_DATA[id] end
do -- file locals of the mod, reachable only through ensure_callbacks_registered
	local function set_stash_mapping(id, box_id) HARV[id] = box_id end
	local function get_or_create_harvester_stash(obj, allow_create)
		local id = obj:id()
		if not HARV[id] and allow_create then
			local box = spawn("harvester_box", vec3(21, -50, 0), nil, { kind = "box" })
			set_stash_mapping(id, box.id)
		end
		return HARV[id]
	end
	local function harvester_of(box_id)
		for hid, sid in pairs(HARV) do
			if sid == box_id then return hid end
		end
	end
	local valid_actor_bags = { [EDDListType.iActorBag] = true }
	local function is_valid_artifact_section(section) return section == "af_ok" end
	local function get_item_condition_and_setter(id) return OBJ[id]:condition() end
	local function can_reach_first_spawn(_, id) return get_item_condition_and_setter(id) > 0 end
	local function clear_active(id) HARV_DATA[id].artifact_item_id = 0 end
	local function remove_display() end
	local function on_item_before_move(flags, case_id, item, mode, bag_from)
		if mode ~= "loot" or not valid_actor_bags[bag_from] then return end
		if not is_valid_artifact_section(item:section()) or not can_reach_first_spawn(item:section(), item:id())
			or get_item_condition_and_setter(item:id()) <= 0 then
			flags.ret_value = false
			actor_menu.set_msg(1, "Only configured artifacts can be inserted.", 3)
		end
	end
	local function on_item_after_move(case_id, item, mode, bag_from)
		local id = harvester_of(case_id)
		HARV_MOVES[#HARV_MOVES + 1] = { item = item:id(), bag = bag_from }
		if bag_from then
			HARV_DATA[id].artifact_item_id = item:id()
		else
			clear_active(id)
			remove_display(id)
		end
	end
	local function ensure_callbacks_registered() return on_item_before_move, on_item_after_move end
	bind_artifact_harvester = {
		artifact_harvester_wrapper = {},
		open_harvester_stash = function(id)
			local box_id = get_or_create_harvester_stash(OBJ[id], true)
			CreateTimeEvent("hf_artifact_harvester_stash", "open_" .. id, 0.1, function()
				OBJ[box_id]:use(db.actor)
				return true
			end)
		end,
		harvester_save_state = function(m) m.harvester_stashes = HARV end,
		on_game_start = function() ensure_callbacks_registered() end,
	}
end
weapon_showcase = {
	spawn_displayed_item = function(case, item) weapon_showcase.weapon_displays = weapon_showcase.weapon_displays or {}
		weapon_showcase.weapon_displays[case] = weapon_showcase.weapon_displays[case] or {}
		local se = alife_create("display_copy", vec3(21, 0, 4), 1, 2)
		weapon_showcase.weapon_displays[case][item] = se.id
		return se.id end,
	remove_displayed_item = function(item, world, case) weapon_showcase.weapon_displays[case][item] = nil; alife_release_id(world) return true end,
	respawn_weapon_displays = function() RESPAWNED = true end,
}
-- WPO
PARTS = {}
item_parts = { get_parts_con = function(obj, id) local i = obj and obj:id() or id; return PARTS[i] end,
	set_parts_con = function(id, p) PARTS[id] = p end }
zzzz_arti_jamming_repairs = { is_part = function() return true end,
	act_fieldstrip = function(id, part)
		STRIPPED = (STRIPPED or 0) + 1
		alife_create_item(part or "part_any", db.actor)
		PARTS[id][part or "barrel"] = -1
	end }
arti_jamming = { try_replace_part = function() ORIG_REPLACE = true end, is_barrel = function(s) return s == "barrel" end, reset_cgd = function() end }
haru_quick_action_wheel_mcm = { TAB_MANAGER = { classes = { item = { is_obj = true }, action = {} } } }

start_all()
local C = coop_mods_core
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")

if which == "host" then
	-- radio: host publishes, client controls run here
	local w = new_radio(700)
	w.radio_ch[1][1]:play()
	w.radio_state, w.radio_selected = true, 1
	SENT = {}
	placeable_radio.placeable_radio_wrapper.update(w, 10)
	local st = sent("mods.hf_radio")
	check(st and st.on == true and st.c == "a" and st.p == "radio\\_channel_1\\" and st.k == 0 and math.abs(st.v - 0.6) < 1e-6, "radio: programme published by file name")
	SENT = {}
	placeable_radio.placeable_radio_wrapper.update(w, 10)
	check(sent("mods.hf_radio") == nil, "radio: unchanged programme not sent again")
	from("hf_radio_ctl", { o = 700, a = "action_radio_v_up" }, 1)
	check(sent("mods.hf_radio") ~= nil and math.abs(sent("mods.hf_radio").v - 0.7) < 1e-6, "radio: a client's volume button runs on the host")
	from("hf_radio_ctl", { o = 700, a = "os_execute" }, 1)
	check(log_has("hf_radio_ctl from #1 refused") ~= nil, "radio: unknown action refused")
	-- stove: host creates the box, its own queued open is dropped
	local _, stove = spawn("stove", vec3(21, 0, 0))
	SENT = {}
	from("hf_box", { k = "stove", o = stove:id() }, 1)
	local a = sent("mods.hf_box_r")
	check(a and a.b == alife_storage_manager.get_state().stove_stashes[stove:id()], "stove: box id answered")
	run_time_events(500)
	check(HOST_OPENED_STOVE == nil, "stove: the host does not open the box itself")
	local _, harv = spawn("placeable_artifact_harvester", vec3(21, 0, 0))
	HARV_DATA[harv:id()] = {}
	SENT = {}
	from("hf_box", { k = "harvester", o = harv:id() }, 1)
	local answer, reply = sent("mods.hf_box_r")
	local box_id = HARV[harv:id()]
	local box_obj = OBJ[box_id]
	check(box_obj and answer and answer.k == "harvester" and answer.o == harv:id() and answer.b == box_id
		and reply.target == 1 and sent_count("mods.hf_box_r") == 1, "harvester: box id answered once to the requester")
	run_time_events(500)
	check(box_obj and box_obj._used_by == nil, "harvester: the host does not open the box itself")
	-- Arrivals alone never start production. An explicit insert runs the mod's callback on the host.
	if box_obj then
		local kept = spawn("af_ok", vec3(21, 0, 3), box_id)
		local function watch() NOW = NOW + 1100; SendScriptCallback("actor_on_update") end
		watch()
		check(#HARV_MOVES == 0, "harvester: what lay in the box at the first look starts nothing")
		HUD = nil
		local wrong = spawn("af_wrong", other:position(), other:id())
		from("hf_harv_insert", { o = harv:id(), i = wrong.id }, 1)
		local refused, refusal = sent("mods.hf_harv_r")
		check(wrong.parent_id == other:id() and refused and refused.r == "section" and refusal.target == 1
			and #HARV_MOVES == 0 and HUD == nil, "harvester: refused insert stays with the requester and shows no HUD line on the host")
		local put = spawn("af_ok", other:position(), box_id)
		watch()
		check(#HARV_MOVES == 0, "harvester: a new arrival without an insert request starts nothing")
		box_obj:transfer_item(OBJ[put.id], other)
		from("hf_harv_insert", { o = harv:id(), i = put.id }, 1)
		check(put.parent_id == box_id and HARV_MOVES[1] and HARV_MOVES[1].item == put.id and HARV_MOVES[1].bag == EDDListType.iActorBag,
			"harvester: a client's artefact starts production through the mod's own code")
		check(HARV_DATA[harv:id()].artifact_item_id == put.id, "harvester: the mod's data has it")
		from("hf_harv_insert", { o = harv:id(), i = put.id }, 1)
		watch()
		check(#HARV_MOVES == 1, "harvester: retry and polling do not start production again")
		box_obj:transfer_item(OBJ[put.id], other)
		watch()
		check(#HARV_MOVES == 2 and HARV_MOVES[2].item == put.id and HARV_MOVES[2].bag == nil
			and HARV_DATA[harv:id()].artifact_item_id == 0, "harvester: taken out, the mod stops")
		alife_release_id(kept.id)
		alife_release_id(wrong.id)
	end
	-- showcase: the item must be in the case
	local _, case = spawn("showcase", vec3(21, 0, 0))
	local gun = spawn("wpn_ak", vec3(21, 0, 0), case:id())
	SENT = {}
	from("hf_show", { c = case:id(), i = gun.id, m = 1, s = "" }, 1)
	local map = sent("mods.hf_show_map")
	check(map and map.c == case:id() and map.m:find("^" .. gun.id .. ":") ~= nil, "showcase: mounted on the host, map sent")
	local displays = 0
	for _, made in ipairs(CREATED) do if made.sec == "display_copy" then displays = displays + 1 end end
	from("hf_show", { c = case:id(), i = gun.id, m = 1, s = "" }, 1)
	local after_retry = 0
	for _, made in ipairs(CREATED) do if made.sec == "display_copy" then after_retry = after_retry + 1 end end
	check(displays == 1 and after_retry == displays, "showcase: repeated mount does not create another world display")
	local gun2 = spawn("wpn_ak", vec3(21, 0, 0), 0)
	from("hf_show", { c = case:id(), i = gun2.id, m = 1, s = "" }, 1)
	check(log_has("hf_show from #1 refused") ~= nil, "showcase: an item outside the case refused")
	-- WPO: strip a weapon in a box, parts to the requester
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	local w2 = spawn("wpn_ak", vec3(21, 0, 0), box:id())
	PARTS[w2.id] = { scope = 80, barrel = 90 }
	CREATED = {}
	from("wpo_strip", { w = w2.id, p = "scope" }, 1)
	check(STRIPPED == 1 and CREATED[1] and CREATED[1].sec == "scope" and CREATED[1].parent == 500, "WPO: strip in a box runs on the host, part to the requester")
	from("wpo_swap", { w = w2.id, s = "scope", c = 70, t = false, p = -1 }, 1)
	check(PARTS[w2.id].scope == 70, "WPO: swap applied when the slot is as the client saw it")
	from("wpo_swap", { w = w2.id, s = "scope", c = 10, t = false, p = 55 }, 1)
	check(PARTS[w2.id].scope == 70, "WPO: swap refused when the slot changed")
else
	-- radio: client plays the host's programme, its own picker is locked
	local w = new_radio(700)
	from("hf_radio", { o = 700, on = true, p = "radio\\_channel_1\\", q = "radio\\_session_1\\", k = 0, c = "b", v = 0.5, n = 3 }, 0)
	placeable_radio.placeable_radio_wrapper.update(w, 10)
	check(w.radio_state == true and w.radio_now[1] == 2 and w.radio_ch[1][2]:playing(), "radio: host's clip playing here")
	check(LOCK_SEEN == true, "radio: the mod's own picker locked during the update")
	SENT = {}
	local r = placeable_radio.placeable_radio_wrapper.action_radio_stop(w)
	check(r == false and sent("mods.hf_radio_ctl").a == "action_radio_stop" and w.radio_state == true, "radio: button goes to the host")
	from("hf_radio", { o = 700, on = true, p = "radio\\_other\\", q = "x", k = 0, c = "zz", v = 0.5, n = 4 }, 0)
	placeable_radio.placeable_radio_wrapper.update(w, 10)
	check(not w.radio_ch[1][2]:playing() and not w.radio_ch[1][1]:playing(), "radio: a station not installed here stays silent")
	-- stove
	local _, stove = spawn("stove", vec3(21, 0, 0))
	SENT = {}
	ui_stove_furniture.UICookStove.UseCook({ obj_id = stove:id() })
	check(not COOKED and HUD ~= nil, "stove: cooking waits for the box link")
	ui_stove_furniture.access_inventory(stove)
	check(sent("mods.hf_box").k == "stove", "stove: box asked from the host")
	local sb = spawn("inv_box", vec3(21, 0, 2))
	from("hf_box_r", { k = "stove", o = stove:id(), b = sb.id }, 0)
	run_time_events(300)
	check(OBJ[sb.id]._used_by == db.actor, "stove: the box opens for this player")
	ui_stove_furniture.UICookStove.UseCook({ obj_id = stove:id() })
	check(COOKED, "stove: cooking once the link is known")
	-- showcase
	local _, case = spawn("showcase", vec3(21, 0, 0))
	SENT = {}
	check(weapon_showcase.spawn_displayed_item(case:id(), 1500, nil, "wpn_ak") == nil and sent("mods.hf_show").m == 1, "showcase: mount asked from the host")
	check(weapon_showcase.respawn_weapon_displays() == true and not RESPAWNED, "showcase: displays never re-created on a client")
	from("hf_show_map", { c = case:id(), m = "1500:1600:2:wpn_ak" }, 0)
	check(weapon_showcase.weapon_displays[case:id()][1500] == 1600, "showcase: the host's map applied")
	weapon_showcase.weapon_displays = false
	weapon_showcase.weapon_display_slots = false
	weapon_showcase.weapon_display_sections = false
	from("hf_show_map", { c = case:id(), m = "1500:1600:2:wpn_ak" }, 0)
	check(type(weapon_showcase.weapon_displays) == "table" and weapon_showcase.weapon_displays[case:id()][1500] == 1600,
		"showcase: false save fields normalize to tables as in the original mod")
	-- WPO
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	local _, wb = spawn("wpn_ak", vec3(21, 0, 0), box:id())
	PARTS[wb:id()] = { scope = -1 }
	SENT = {}
	zzzz_arti_jamming_repairs.act_fieldstrip(wb:id(), "scope")
	zzzz_arti_jamming_repairs.act_fieldstrip(wb:id(), "grip")
	check(STRIPPED == nil and sent("mods.wpo_strip") == nil, "WPO: strips of a frame are batched")
	run_time_events(100)
	check(sent("mods.wpo_strip").p == "scope,grip", "WPO: one strip request for the frame")
	local _, part = spawn("scope", vec3(0, 0, 0), 0)
	SENT = {}
	arti_jamming.try_replace_part(wb, PARTS[wb:id()], part, false)
	check(sent("mods.wpo_swap").p == -1 and not ORIG_REPLACE, "WPO: swap into a box weapon asked from the host")
	PARTS[wb:id()] = { scope = 100 } -- the host's new part state arrived (economy se mirror)
	run_time_events(500)
	check(SE[part:id()] == nil, "WPO: the part spent once the host's state is here")
	local _, w_own = spawn("wpn_ak", vec3(0, 0, 0), 0)
	PARTS[w_own:id()] = { scope = 50 }
	zzzz_arti_jamming_repairs.act_fieldstrip(w_own:id(), "scope")
	check(STRIPPED == 1 and PARTS[w_own:id()].scope == -1, "WPO: own weapon stripped locally (items into own inventory are forwarded)")
	-- QAW: entries whose item is gone are dropped at the first update
	local own_item = spawn("medkit", vec3(0, 0, 0), 0)
	local m = alife_storage_manager.get_state()
	m.haru_qaw = { tabs = { { { class = "item", id = own_item.id, section = "medkit" }, { class = "item", id = 4444, section = "bandage" },
		{ class = "action", name = "x" }, __ids = { [4444] = true } } } }
	SendScriptCallback("actor_on_first_update")
	local tab = m.haru_qaw.tabs[1]
	check(#tab == 2 and tab[1].id == own_item.id and tab[2].class == "action" and tab.__ids[4444] == nil,
		"QAW: entry of an item not carried any more dropped, others kept")
end

check(C.stats.errors == 0, "no Lua errors (" .. C.stats.errors .. ")")
done("EXTRA " .. which)
