-- Dev 57 G10-5. Run: tools\test_lua.cmd mods_view_fixes
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function run(mode)
	MODE = mode == "none" and "sp" or "host"
	coop.is_map_server = function() return mode == "srv_map" and MODE ~= "client" end
	coop.is_dedicated = function() return mode == "srv_world" and MODE ~= "client" end
	coop.is_host = function() return MODE == "host" and mode ~= "srv_map" end
	coop.is_client = function() return MODE == "client" or mode == "srv_map" end
	coop.levels = { map_servers = function() return { { bridge = 0x101 }, { bridge = 0x102 } } end }
	coop.players = function()
		return {
			{ id = 0, nick = "host", is_self = MODE == "host", avatar_id = 0 },
			{ id = 1, nick = "maker", avatar_id = PROXY },
			{ id = 2, nick = "observer", avatar_id = 501 },
		}
	end
	local actor = make_actor()
	local _, player = spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = PROXY, kind = "stalker" })
	local _, guide = spawn("stalker", vec3(2, 0, 0), nil, { kind = "stalker" })
	local _, other = spawn("stalker", vec3(2, 0, 1), nil, { kind = "stalker" })
	local guide_id = guide:id()
	local spot_type = "secondary_task_location"
	local spots, removals = {}, 0
	level.map_add_object_spot_ser = function(id, _, title) spots[id] = title end
	level.map_remove_object_spot = function(id, spot)
		if spot == spot_type then removals = removals + 1 end
		spots[id] = nil
	end
	local discussed, witnesses = {}, 0
	coop.talk_recent = function(from, id)
		witnesses = witnesses + 1
		return discussed[from] == id
	end
	-- The mod's close callback owns a file-local previous_task. Its listener is registered by value.
	zzz_tasks_guide = from_script("zzz_tasks_guide", [[
		local previous_task
		return {
			offer = function(id) previous_task = id end,
			actor_on_leave_dialog = function(id)
				if previous_task == id then level.map_remove_object_spot(id, "secondary_task_location") end
			end,
		}
	]])
	local role = modes.install(load_script("coop_mode"), mode)
	local function mirror()
		MODE, SELF = "client", 1
		modes.install(coop_mode, mode, {
			leads_here = function() return false end,
			decides_world = function() return false end,
			actor_is_player = function() return true end,
			is_player_mirror = function() return true end,
		})
	end
	local function offer(id)
		zzz_tasks_guide.offer(id)
		spots[id] = "Guide offer"
	end
	local hint_key = "stash_hint_text"
	local state = alife_storage_manager.get_state()
	local names = getmetatable(SE[0])
	function names:name() return self._sec .. "_" .. self.id end
	function se_save_var(id, _, var, value)
		if not state.se_object[id] and alife_object(id) and value ~= nil then
			state.se_object[id] = { name = alife_object(id):name() }
		end
		if state.se_object[id] then state.se_object[id][var] = value end
	end
	local function menu_hint(id)
		local sv = state.se_object[id]
		return sv and sv[hint_key] or "technical name"
	end
	local stock_stashes = 0
	item_backpack = {
		UICreateStash = { OnAccept = function() stock_stashes = stock_stashes + 1 end },
		actor_on_item_use = function() end,
		actor_on_item_take_from_box = function() end,
	}
	INI.test_backpack = { class = "EQ_BAKPK" }
	local loot_flag, recomputes = {}, 0
	xr_corpse_detection = {
		lootable_table = { wpn_test = true },
		set_valuable_loot = function(id, value)
			recomputes = recomputes + 1
			loot_flag[id] = value
		end,
	}
	AddScriptCallback("actor_on_leave_dialog")
	AddScriptCallback("npc_on_item_drop")
	RegisterScriptCallback("actor_on_leave_dialog", zzz_tasks_guide.actor_on_leave_dialog)
	load_script("coop_main").on_game_start()
	coop_mode.on_game_start()
	load_script("coop_mods_core").on_game_start()
	load_script("coop_economy_mdata").on_game_start()
	load_script("coop_mods_items").on_game_start()
	local adapter = coop_mods_view_fixes
	if adapter then adapter.on_game_start() end

	local function incoming(verb, data, peer)
		coop_main.on_event("mods." .. verb, coop_main.encode(data), peer)
	end

	local function check_hint_delivery(id, expected)
		SendScriptCallback("actor_on_update")
		local save = state.se_object
		local hints = {}
		for _, s in ipairs(SENT) do
			if s.name == "economy.se" then
				local t = coop_main.decode(s.payload)
				if tonumber(t.i1) == id and t.k1 == hint_key then hints[s.target] = s end
			end
		end
		mirror()
		for peer = 1, 2 do
			-- A separate player's copy of the save, including an observer on a different map.
			state.se_object = {}
			if hints[peer] then deliver(hints[peer], 0) end
			check(menu_hint(id) == expected, "FFT name arrived for player " .. peer)
		end
		state.se_object = save
		MODE, SELF = "host", 0
		modes.install(coop_mode, mode)
	end

	print("== named stash is visible in FFT after authoritative creation")
	local name = "Backpack %s\n" .. string.rep("x", 70)
	local expected = name:sub(1, 64):gsub("%c", " ")
	local pack = spawn("test_backpack", player:position(), player:id())
	if mode == "hostplay" or mode == "srv_map" then
		local request = { i = pack.id, p = "treasure_player", t = name }
		if mode == "srv_map" then request._peer = 1 end
		incoming("stash_make", request, mode == "srv_map" and 0 or 1)
		local reply = sent("mods.stash_made")
		check(reply and tonumber(reply.b) and reply.t == expected, "the level authority made the box with the sanitized name")
		run_time_events(0)
		if mode == "hostplay" and reply then
			local id = tonumber(reply.b)
			check(menu_hint(id) == expected, "co-op save contains FFT name")
			check_hint_delivery(id, expected)
		elseif mode == "srv_map" then
			local book, raw = sent("mods.stash_book")
			check(book and raw.target == 0 and book.t == expected, "map authority sent sanitized name through stash_book")
		end
	elseif mode == "srv_world" then
		local id = 1900
		incoming("stash_book", { b = id, s = "test_backpack", t = "spoofed" }, 1)
		check(not state.player_created_stashes, "a player cannot book a world stash")
		incoming("stash_book", { b = id, s = "test_backpack", t = expected }, role.bridge)
		run_time_events(0) -- the bridge's box has not arrived yet
		spawn("inv_backpack", nil, nil, { id = id, offline = true })
		run_time_events(50)
		check(state.player_created_stashes and state.player_created_stashes[id] == "test_backpack",
			"world booked the bridge's stash after the box arrived")
		check(menu_hint(id) == expected, "world save contains the FFT name for an offline box")
		check_hint_delivery(id, expected)
	else
		item_backpack.UICreateStash:OnAccept()
		check(stock_stashes == 1 and #SENT == 0, "single-player stash creation still uses the original")
	end

	print("== only the shared owner uses a real dialog to remove the current guide spot")
	offer(guide_id)
	if mode == "hostplay" then
		mirror()
		coop.to_host_id = function(id) return id == guide_id + 10000 and guide_id or id end
		SendScriptCallback("actor_on_leave_dialog", guide_id + 10000)
		local request, raw = sent("mods.view_guide_close")
		check(request and tonumber(request.n) == guide_id and raw.target == 0, "the mirror sent the close in host numbering")
		check(spots[guide_id] and removals == 0, "mirror left the shared mark alone")
		MODE, SELF = "host", 0
		modes.install(coop_mode, mode)
		coop_trust.reset_for_test({ default = "log" })
		discussed[2] = guide_id
		incoming("view_guide_close", { n = guide_id, from = 2 }, 1)
		local gate = coop_trust.status().view_guide_close
		check(spots[guide_id] and gate and gate.failed == 1, "a close without the sender's talk is logged and cannot remove the mark")
		discussed[1] = other:id()
		incoming("view_guide_close", { n = other:id() }, 1)
		check(spots[guide_id] and removals == 0 and gate and gate.failed == 1, "a real talk with another NPC leaves the current mark")
		NOW = NOW + 2000
		discussed[1] = guide_id
		if raw then deliver(raw, 1) end
		check(not spots[guide_id] and removals == 1, "the co-op owner removed the current guide spot after a real talk")
		incoming("view_guide_close", { n = guide_id }, 1)
		check(removals == 1, "an already handled close cannot remove the mark twice")
		NOW = NOW + 2000
		offer(guide_id)
		discussed[0] = guide_id
		SendScriptCallback("actor_on_leave_dialog", guide_id)
		check(not spots[guide_id] and removals == 2, "the co-op host can close its own guide dialog")
	elseif mode == "srv_world" then
		local before = witnesses
		incoming("view_guide_close", { n = guide_id }, 1)
		local relay, raw = sent("mods.view_guide_close")
		check(relay and tonumber(relay._peer) == 1 and raw.target == role.bridge, "world forwarded the close to the level authority")
		check(spots[guide_id] and witnesses == before, "world never decides from local talk data it does not have")
	elseif mode == "srv_map" then
		discussed[1] = guide_id
		incoming("view_guide_close", { n = guide_id, _peer = 1 }, 0)
		check(spots[guide_id] and removals == 0, "map authority does not own the shared guide offer")
	else
		SendScriptCallback("actor_on_leave_dialog", guide_id)
		check(not spots[guide_id] and removals == 1 and #SENT == 0, "single-player guide callback stays unchanged")
	end

	print("== dead stalker loot is recomputed after the inventory transfer")
	local _, corpse = spawn("stalker", vec3(1, 0, 1), nil, { kind = "stalker", alive = false })
	local weapon, item = spawn("wpn_test", corpse:position(), corpse:id())
	local backup, spare = spawn("wpn_test", corpse:position(), corpse:id())
	spawn("worthless", corpse:position(), corpse:id())
	loot_flag[corpse:id()] = true
	SendScriptCallback("npc_on_item_drop", corpse, item)
	check(recomputes == 0, "drop does not scan before transfer commits")
	weapon.parent_id = player:id()
	run_time_events(0)
	if mode == "hostplay" or mode == "srv_map" then
		check(loot_flag[corpse:id()] == true and recomputes == 1, "remaining valuable loot keeps the corpse eligible")
		SendScriptCallback("npc_on_item_drop", corpse, spare)
		backup.parent_id = 65535
		run_time_events(0)
		check(loot_flag[corpse:id()] ~= true and recomputes == 2, "last valuable item leaving to the ground clears the flag")
		local taken, last = spawn("wpn_test", corpse:position(), corpse:id())
		loot_flag[corpse:id()] = true
		SendScriptCallback("npc_on_item_drop", corpse, last)
		taken.parent_id = player:id()
		run_time_events(0)
		check(loot_flag[corpse:id()] ~= true and recomputes == 3, "a client taking the last valuable item clears the flag")
		SendScriptCallback("npc_on_item_drop", actor, item)
		local _, mutant = spawn("boar", corpse:position(), nil, { kind = "monster", alive = false })
		SendScriptCallback("npc_on_item_drop", mutant, item)
		run_time_events(0)
		check(recomputes == 3, "live stalkers and mutant corpses are untouched")
	else
		check(recomputes == 0 and loot_flag[corpse:id()] == true, "without level authority the stock flag is untouched")
	end
end

for _, mode in ipairs(modes.names()) do run(mode) end
done("mods_view_fixes")
