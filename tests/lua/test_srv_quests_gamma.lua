-- Dev 57 G14-5: exercise the installed GAMMA callbacks and the real offer entry point.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")
local DAY = 86400
local DEFENSE = "barrier_defense_monolith"
local STARTED = "lttz_hb_task_1_1_dushman_intel_started"
local BREAKTHROUGH = "lttz_hb_isg_breakthrough"
local CROSSFIRE = "lttz_hb_task_4_1_crossfire_done"

local function vendor(M, name)
	local path = "temp/review/corpus/merged/" .. name .. ".script"
	local file = io.open(path, "r")
	if file then
		file:close()
	else
		path = assert(os.getenv("GAMMA_SCRIPTS"), "GAMMA scripts required") .. "/" .. name .. ".script"
	end
	local mod = setmetatable({}, { __index = M.env })
	M.env[name] = mod
	setfenv(assert(loadfile(path)), mod)()
	return mod
end

local function time_at(seconds)
	return { seconds = seconds, diffSec = function(self, other) return self.seconds - other.seconds end }
end

local function base(mode)
	local M = machine("host", 0)
	M.mode = mode
	local e = M.env
	M.active = mode ~= "none"
	M.players = { { id = 0, is_self = true }, { id = 1, avatar_id = 501, level = 1 }, { id = 2, avatar_id = 502, level = 2 } }
	M.factions = { [1] = "stalker", [2] = "monolith" }
	M.maps = { "k01_darkscape", "jupiter_underground", "jupiter", "l01_escape" }
	M.seconds = 0
	M.world_level_reads = 0
	e.level.name = function()
		M.world_level_reads = M.world_level_reads + 1
		return M.map or "fake_start"
	end
	e.level.get_start_time = function() return time_at(0) end
	e.alife = function() return { level_name = function(_, id) return M.maps[id] end } end
	e.game.get_game_time = function() return time_at(M.seconds) end
	e.utils_data = {
		CTime_to_table = function(t) return { seconds = t.seconds } end,
		CTime_from_table = function(t) return time_at(t.seconds) end,
	}
	local random = 0
	e.math = setmetatable({ random = function(n)
		if n then return 1 end
		random = random + 1
		return M.random_roll or 0.99
	end }, { __index = math })
	M.rolls = function() return random end
	M.ObjMT.has_info = function(_, name) return M.infos[name] == true end
	e.printdbg = function() end
	e.give_info = function(name) M.infos[name] = true end
	e.get_actor_true_community = function() return "stalker" end
	e.character_community = function(obj) return obj:character_community() end
	e.coop_faction = { faction_of = function(peer) return M.factions[peer] end }
	e.dialogs.actor_true_isg = function() return M.isg == true end
	e.game_relations = { is_factions_enemies = function(a) return a == "monolith" end }
	e.task_functor = {}
	e.alife_storage_manager = { get_state = function() return M.state end }
	e.dynamic_news_helper = { send_tip = function() M.tips = M.tips + 1 end }
	e.serious_the_job_can_wait_mcm = { get_config = function() return 0 end }
	M.state, M.squads, M.removed, M.tips = {}, {}, {}, 0
	e.xr_effects.clear_smart_terrain = function() end
	e.xr_effects.create_squad = function(_, _, p) M.squads[p[1]] = (M.squads[p[1]] or 0) + 1 end
	e.xr_effects.remove_squad = function(_, _, p) M.removed[p[1]] = (M.removed[p[1]] or 0) + 1 end
	e.db.OnlineStalkers = {}
	e.axr_task_manager.ongoing_tasks = {}
	M.events = {}
	e.CreateTimeEvent = function(id, action, seconds, f, ...)
		local key = id .. ":" .. action
		M.events[key] = M.events[key] or { at = NOW + seconds * 1000, f = f, args = { ... } }
	end
	e.RemoveTimeEvent = function(id, action) M.events[id .. ":" .. action] = nil end
	e.ResetTimeEvent = function(id, action, seconds)
		local ev = M.events[id .. ":" .. action]
		if ev then ev.at = NOW + seconds * 1000 end
	end
	load_script(M, "coop_mode")
	load_script(M, "coop_mods_core")
	modes.install(e.coop_mode, mode, mode == "srv_world" and { where = function(peer)
		for _, player in ipairs(M.players) do
			if player.id == peer and peer ~= 0 then return player.level and "away" or "joining" end
		end
		return "away"
	end } or nil)
	return M
end

local function boot(M)
	local adapter = io.open("gamedata/scripts/coop_srv_quests_gamma.script", "r")
	if adapter then
		adapter:close()
		load_script(M, "coop_srv_quests_gamma").on_game_start()
	end
	for _, name in ipairs({ "dialogs_lostzone", "tasks_defense" }) do
		local mod = M.env[name]
		-- The game's router keeps these vendor callbacks on the world process.
		if mod and M.mode ~= "srv_map" then mod.on_game_start() end
	end
	fire(M, "load_state", {})
	fire(M, "actor_on_first_update")
end

local function advance(M, day, elapsed)
	M.seconds = day * DAY
	NOW = NOW + (elapsed or 21) * 1000
	fire(M, "actor_on_update")
	for key, event in pairs(M.events) do
		if event.at <= NOW and event.f(unpack(event.args)) and M.events[key] == event then M.events[key] = nil end
	end
end

local function defense_packets(M, expire)
	local count = 0
	for _, msg in ipairs(M.sent) do
		if msg.name == "mods.npcrel_offer" then
			local data = M.env.coop_main.decode(msg.payload)
			if data.tid == DEFENSE and (data.expire == true) == expire and (expire or msg.target == 1) then count = count + 1 end
		end
	end
	return count
end

local function lost_zone()
	print("== m09:2 Lost Zone stages during one world session")
	local M = base("srv_world")
	vendor(M, "dialogs_lostzone")
	M.isg = true
	boot(M)
	check(M.squads.ds_isg_leader_squad == 1, "first world update creates the Darkscape leader")
	M.infos[STARTED], M.infos[BREAKTHROUGH] = true, true
	advance(M, 1)
	local stash = M.events["cycle:isg_stash"]
	check(stash ~= nil, "accepting Dushman's task starts the stash timer without a reload")
	local started_at = M.state.lttz_hb_last_stash_time
	check(started_at and started_at.seconds == DAY, "the first stash interval starts at acceptance")
	check(not M.removed.ds_isg_leader_squad, "the leader stays while a participant is in Darkscape")
	check(not M.squads.jup_u_isg_guard_squad, "an Underpass participant blocks the guard spawn")
	M.players[3].level = nil
	advance(M, 1)
	check(not M.squads.jup_u_isg_guard_squad, "a joining participant is not treated as having left")
	M.players[3].level = 3
	advance(M, 1)
	check(M.squads.jup_u_isg_guard_squad == 1 and M.squads.jup_u_isg_guard_2_squad == 1,
		"both guard squads spawn after the last Underpass participant leaves")
	M.players[2].level = 3
	advance(M, 1)
	check(M.removed.ds_isg_leader_squad == 1 and M.removed.ds_isg_recon_squad == 1,
		"both leader squads leave after the last Darkscape participant leaves")
	check(stash ~= nil and M.events["cycle:isg_stash"] == stash, "later checks keep the original stash timer")
	M.infos[CROSSFIRE] = true
	advance(M, 2)
	check(M.events["cycle:isg_stash"] == nil, "finishing Crossfire ends the stash cycle")
	advance(M, 2.1)
	check(M.infos.lttz_hb_leaving_jup_u_done and not M.infos.lttz_hb_leaving_jup_done,
		"the two-hour epilogue waits separately for Jupiter and the Underpass")
	M.players[2].level, M.players[3].level = 4, 4
	advance(M, 2.1)
	check(M.infos.lttz_hb_leaving_jup_done, "the Jupiter epilogue completes after its participants leave")
	check(M.world_level_reads == 0 and M.squads.jup_u_isg_guard_squad == 1 and M.removed.ds_isg_leader_squad == 1,
		"no world-map read or repeated squad effects")
end

local function darkscape_map()
	print("== Darkscape cleanup uses the map server's online NPCs")
	local M = base("srv_map")
	local e = M.env
	M.map = "k01_darkscape"
	M.infos.lttz_hb_spawned_ds_isg_leader_squad = true
	vendor(M, "dialogs_lostzone")
	local npc = M.new_obj(901, "stalker_npc", vec(), { _stalker = true })
	local proxy = M.new_obj(501, "coop_player_avatar", vec(), { _stalker = true })
	M.ObjMT.kill = function(self) self._dead = true end
	e.db.OnlineStalkers = { npc:id(), proxy:id() }
	boot(M)
	advance(M, 1)
	advance(M, 1)
	check(not npc:alive() and proxy:alive(), "the stock cleanup can kill a local NPC and excludes player proxies")
	check(M.infos.killed_darkscape_stalkers and not M.squads.ds_isg_leader_squad and not M.events["cycle:isg_stash"],
		"the map server records cleanup and leaves quest progression to the world server")
end

local function defense()
	print("== m09:4 two Barrier defense offers without a reload")
	local M = base("srv_world")
	vendor(M, "tasks_defense")
	boot(M)
	advance(M, 6)
	check(defense_packets(M, false) == 0 and M.rolls() == 0, "the first week blocks offers and rolls")
	advance(M, 7)
	advance(M, 7)
	check(defense_packets(M, false) == 1 and M.rolls() == 1, "the first eligible check announces once to the friendly seat")
	advance(M, 8.1)
	advance(M, 9)
	check(defense_packets(M, true) == 2, "the skipped offer expires once per seat")
	advance(M, 13.9)
	check(defense_packets(M, false) == 1 and M.rolls() == 1, "the weekly cooldown still blocks another check")
	M.players[3].level = 1
	advance(M, 14)
	advance(M, 14)
	local state = {}
	fire(M, "save_state", state)
	local md = state.defense_task_data[DEFENSE]
	check(defense_packets(M, false) == 2 and M.rolls() == 2 and md.last_check_time and md.last_check_time.seconds == 14 * DAY,
		"a second offer rolls on the week boundary and keeps the stock saved check timestamp")
	M.env.axr_task_manager.ongoing_tasks[DEFENSE] = true
	advance(M, 15.1)
	advance(M, 21)
	check(defense_packets(M, false) == 2, "an ongoing defense blocks another announcement")
end

local function defense_daily_roll()
	print("== m09:4 failed Barrier rolls keep the daily check interval")
	local M = base("srv_world")
	local mod = vendor(M, "tasks_defense")
	local available, calls = mod.barrier_defense_available, 0
	mod.barrier_defense_available = function(...)
		calls = calls + 1
		return available(...)
	end
	M.random_roll = 0.1
	boot(M)
	advance(M, 7)
	local first = calls
	advance(M, 7.5)
	check(M.rolls() == 2 and calls == first, "sub-day polling skips the stock picker after failed rolls")
	advance(M, 8)
	check(M.rolls() == 4 and defense_packets(M, false) == 0, "both defense types can roll again the following day")
end

local function north(mode)
	print("== m15:4 north picker in " .. mode)
	local M = base(mode)
	local e = M.env
	local helper = vendor(M, "blacklist_helper")
	local bounty_cache = {}
	e.tasks_bounty = {}
	-- The installed module keeps this cache in an exported effect's closure, not on its module table.
	e.xr_effects.setup_bounty_task = function()
		if bounty_cache.map == nil then bounty_cache.map = helper.ShouldBlacklistNorth() and "south" or "north" end
		return bounty_cache.map
	end
	local npc = M.new_obj(700, "quest_giver", vec(0, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = npc, pstor = {} }
	e.axr_task_manager.generate_available_tasks = function(giver)
		e.axr_task_manager.available_tasks[giver:id()] = { e.xr_effects.setup_bounty_task() }
	end
	load_script(M, "coop_quests_core")
	load_script(M, "coop_quests_offer").on_game_start()
	boot(M)
	local function offer(peer)
		NOW = NOW + 2100
		M.handlers["quests.offer_req"](e.coop_main.encode({ n = 700, q = 1, peer = 99 }), peer)
		local sent = last_sent(M, "quests.offer")
		return sent and sent.l
	end
	if mode == "srv_world" then
		check(offer(1) == "south", "a regular faction gets the restricted pool")
		check(offer(2) == "north", "a Monolith request uses its transport peer and bypasses the cached south pick")
		M.factions[2] = "stalker"
		check(offer(2) == "south", "changing the requester's faction invalidates its previous north pick")
		M.infos.yan_labx16_switcher_primary_off = true
		check(offer(1) == "north", "unlocking the north also invalidates the restricted cache")
		M.infos.yan_labx16_switcher_primary_off = nil
		check(helper.ShouldBlacklistNorth() == true, "the requester context is cleared when the offer returns")
	elseif mode == "hostplay" then
		check(offer(1) == "south" and offer(2) == "south", "co-op offers still use the host's stock north filter")
	else
		check(helper.ShouldBlacklistNorth() and e.xr_effects.setup_bounty_task() == "south", "single player still uses the original picker")
	end
end

local function stock_lifecycle(mode)
	local M = base(mode)
	M.map = "k01_darkscape"
	M.isg, M.infos[STARTED] = true, true
	local lost = vendor(M, "dialogs_lostzone")
	local stock = M.env.coop_mods_core.find_local(lost, "actor_on_first_update")
	local d = vendor(M, "tasks_defense")
	local stock_defense = d.actor_on_first_update
	boot(M)
	check(M.env.coop_mods_core.find_local(lost, "actor_on_first_update") == stock and d.actor_on_first_update == stock_defense,
		mode .. " keeps both original first-update callbacks")
	check(M.events["cycle:isg_stash"] ~= nil and M.world_level_reads == 1, mode .. " starts the stock timer from the loaded map")
	advance(M, 7, 1)
	check(M.rolls() == 0 and defense_packets(M, false) == 0, mode .. " does not run the server's periodic defense checks")
end

for _, mode in ipairs(modes.names()) do
	if mode == "srv_world" then lost_zone(); defense(); defense_daily_roll(); north(mode) end
	if mode == "srv_map" then darkscape_map() end
	if mode == "hostplay" or mode == "none" then north(mode); stock_lifecycle(mode) end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
