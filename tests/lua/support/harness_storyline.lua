-- Anomaly Coop test support: the machines of harness_faction.lua (a host and two clients, events between them) with
-- coop_storyline loaded and the stock DRX questlines code it relies on: the real bodies, copied with file and lines (the
-- commented "old code" blocks of axr_task_manager left out). Globals: STORY, ALIVE, REL, LEADERS. Not shipped.
dofile("tests/lua/support/harness_faction.lua")

FACTION_SCRIPTS = { "coop_quests_core", "coop_reward_group", "coop_tasks", "coop_quests_news", "coop_faction", "coop_storyline" }
STORY = true
ALIVE = nil -- story id -> true: the leaders alive (nil: everybody)
REL = {} -- REL[a .. "|" .. b] = relation (default 0)

-- temp/stock_scripts/scripts/_g.script:971-973, 2537-2552, 2561-2566, 2568-2610
local STOCK_G = [[
function starts_with(str, start_txt)
   return str:sub(1, #start_txt) == start_txt
end
function give_info(info)
	db.actor:give_info_portion(info)
	--printf("DEBUG: GIVE INFO %s",info)
	--if (xrs_debug_tools and xrs_debug_tools.actor_info) then
	--	xrs_debug_tools.actor_info[info] = true
	--end
end

function disable_info(info)
	if has_alife_info(info) then
		--printf("DEBUG: DISABLE INFO %s",info)
		--printf("*INFO*: disabled npc='single_player' id='%s'", info)
		db.actor:disable_info_portion(info)
		--if (xrs_debug_tools and xrs_debug_tools.actor_info) then
		--	xrs_debug_tools.actor_info[info] = nil
		--end
	end
end
function pstor_is_registered_type(tv)
	if tv ~= "boolean" and tv ~= "string" and tv ~= "number" then
		return false
	end
	return true
end

function save_var(obj, varname, val)
	if (obj == nil) then
		callstack()
	end
	local id = obj:id()
	if not (db.storage[id]) then
		printe("!save_var: Warning: no db.storage for %s, db.storage is for online objects only",id)
		return
	end

	if not (db.storage[id].pstor) then
		db.storage[id].pstor = {}
	end

	if not (USE_MARSHAL) then
		local tv = type(val)
		if val ~= nil and not pstor_is_registered_type(tv) then
			printe("!save_var: not registered type '%s' encountered [name=%s varname=%s ]", tv,obj:name(),varname)
			return
		end
	end

	if (type(val) == "userdata") then
		printe("!WARNING: save_var ONLY USE LUA DATA TYPES!!! %s",varname)
	else
		--printf("* save_var | id: %s - name: %s, value: %s", id, varname, val)
		db.storage[id].pstor[varname] = val
	end
end

function load_var(obj, varname, defval)
	if (obj == nil) then
 		callstack()
		printf("load_var failed for %s", varname)
		return defval
	end
	local id = obj:id()
	if not (db.storage[id]) then
 		printe("!load_var: Warning: no db.storage for %s, db.storage is for online objects only", id)
		return defval
	end

	--printf("* load_var | id: %s - name: %s", id, varname)
	return db.storage[id].pstor and db.storage[id].pstor[varname] or defval
end
]]

-- temp/gamma_ref/scripts/xr_effects.script:700-779, 823-900, 918-930, 1228-1248
local STOCK_XR = [[
function drx_sl_meet_random_honcho( actor, npc, p ) -- Give actor meet honcho task:
	local drx_sl_honchos_table = axr_task_manager.drx_sl_honchos_table
	local honcho_list = {}
	local size_t = 0
	for i = 1, #drx_sl_honchos_table do
		local honcho = drx_sl_honchos_table[i][1]
		if ( ((xr_conditions.is_alive( nil, nil, {honcho} )) or (honcho == "esc_m_trader")) and (honcho ~= load_var( db.actor, "drx_sl_current_honcho", "" )) ) then
			local is_enemy = false
			for j = 2, #drx_sl_honchos_table[i] do
				if ( relation_registry.community_relation( drx_sl_honchos_table[i][j], alife():actor():community() ) <= -1000 ) then
					is_enemy = true
				end
			end
			if ( is_enemy == false ) then
				size_t = size_t + 1
				honcho_list[size_t] = honcho
			end
		end
	end
	local next_honcho = load_var( db.actor, "drx_sl_current_honcho", "" )
	if ( size_t > 0 ) then
		next_honcho = honcho_list[math.random( size_t )]
	end
	save_var( db.actor, "drx_sl_current_honcho", next_honcho )
	save_var( db.actor, "drx_sl_current_task_number", (load_var( db.actor, "drx_sl_current_task_number", 1 ) + 1) )
	printf( ("DRX SL task count: " .. load_var( db.actor, "drx_sl_current_task_number", 1 )) )
	task_ltx_file = task_manager.task_ini
	local honcho_task_list = {}
	size_t = 0
	local honcho_task_id = ""
	local i = 1
	while ( true ) do
		honcho_task_id = ("drx_sl_" .. next_honcho .. "_meet_task_" .. i)
		if ( task_ltx_file:section_exist( honcho_task_id ) ) then
			size_t = size_t + 1
			honcho_task_list[size_t] = honcho_task_id
			i = (i + 1)
		else
			break
		end
	end
	if ( size_t > 0 ) then
		honcho_task_id = honcho_task_list[math.random( size_t )]
		save_var( db.actor, "drx_sl_current_task", honcho_task_id )
		printf( ("DRX SL current storyline task: " .. honcho_task_id) )
		give_info( ("drx_sl_meet_honcho_" .. next_honcho) )  -- (\configs\gameplay\info_portions.xml)
		task_manager.get_task_manager():give_task( honcho_task_id )
	else
		printf( ("DRX SL no meet honcho tasks available for " .. next_honcho .. " !!") )
		return
	end
end

function drx_sl_setup_questlines( actor, npc, p )
	local faction = p and p[1]
	if (not faction) then
		printe("! ERROR drx_sl_setup_questlines | no faction defined")
		return
	end
	save_var( db.actor, "drx_sl_total_task_number", math.random( 8, 12 ) )  -- Set to range of total meet honcho tasks to complete to finish game
	save_var( db.actor, "drx_sl_current_task_number", 1 )
	local honcho_table = axr_task_manager.drx_sl_main_honcho_table
	local start_game_honcho = honcho_table[faction] or ""
	if (not honcho_table[faction]) then
		printf( "DRX SL no available game start honchos !!" )
	end
	honcho_start_ltx_file = task_manager.task_ini
	local honcho_start_list = {}
	local honcho_start_id = ""
	local i = 1
	while ( true ) do
		honcho_start_id = ("drx_sl_" .. start_game_honcho .. "_start_game_" .. i)
		if ( honcho_start_ltx_file:section_exist( honcho_start_id ) ) then
			table.insert( honcho_start_list, honcho_start_id )
			i = (i + 1)
		else
			break
		end
	end
	if ( #honcho_start_list > 0 ) then
		math.randomseed( device( ):time_global( ) )
		honcho_start_id = honcho_start_list[math.random( #honcho_start_list )]
		printf( ("DRX SL current storyline task: " .. honcho_start_id) )
		save_var( db.actor, "drx_sl_start_task", honcho_start_id )
		save_var( db.actor, "drx_sl_current_honcho", start_game_honcho )
		give_info( ("drx_sl_start_game_" .. start_game_honcho) )  -- (\configs\gameplay\info_portions.xml)
		--task_manager.get_task_manager( ):give_task( honcho_start_id )
		printf( "DRX questlines are successfuly set for [%s] faction", faction )
	else
		printf( ("DRX SL no start game tasks available for " .. start_game_honcho .. " !!") )
	end
end

function drx_sl_cancel_questlines( actor, npc, p ) -- Cancel all DRX questlines, and disabled info portion for them
	save_var( db.actor, "drx_sl_start_task", nil )
	save_var( db.actor, "drx_sl_current_honcho", nil )
	save_var( db.actor, "drx_sl_current_task_number", nil )
	save_var( db.actor, "drx_sl_current_task", nil )
	save_var( db.actor, "drx_sl_total_task_number", nil )
	save_var( db.actor, "drx_sl_current_task_number", nil )
	local drx_sl_honchos_table = axr_task_manager.drx_sl_honchos_table
	local task_cfg = axr_task_manager.CFG_CACHE
	local tm = task_manager.get_task_manager()
    local task_info = tm.task_info
	for i = 1, #drx_sl_honchos_table do
		local honcho = drx_sl_honchos_table[i][1]
		if has_alife_info("drx_sl_meet_honcho_" .. honcho) then
			disable_info("drx_sl_meet_honcho_" .. honcho)
		end
	end
	for task_id,tbl in pairs(task_info) do
		if starts_with(task_id, "drx_sl_") then
			tbl.forced_status = "fail"
			tbl.cancelled_by_actor = true
		end
	end
end

function drx_sl_find_wish_granter( actor, npc, p ) -- Give actor find Wish Granter task:
	local wish_granter_task = "drx_sl_find_wish_granter_task"
	save_var( db.actor, "drx_sl_current_task", wish_granter_task )
	printf( ("DRX SL current storyline task: " .. wish_granter_task) )
	give_info( "drx_sl_on_find_wish_granter" )  -- (\configs\gameplay\info_portions.xml)
	task_manager.get_task_manager():give_task( wish_granter_task )
end

function drx_sl_decrease_sl_tasks_count( actor, npc, p ) -- Decrease number of completed storyline tasks:
	local task_count = load_var( db.actor, "drx_sl_current_task_number", 1 )
	task_count = (task_count - 1)
	if ( task_count < 1 ) then
		task_count = 1
	end
	save_var( db.actor, "drx_sl_current_task_number", task_count )
	printf( "DRX SL: player failed last storyline task, decrementing drx_sl_current_task_number" )
	printf( ("DRX SL task count: " .. task_count) )
end
]]

-- temp/gamma_ref/scripts/dialogs.script:273-294, 429-456, 1869-1871
local STOCK_DIALOGS = [[
function drx_sl_set_finished_task_complete( a, b )
	local npc = who_is_npc( a, b )
	axr_task_manager.drx_sl_set_finished_task_complete( npc )
	xr_effects.drx_sl_meet_random_honcho( )
end

function drx_sl_set_finished_task_complete_endgame( a, b )
	local npc = who_is_npc( a, b )
	axr_task_manager.drx_sl_set_finished_task_complete( npc )
	xr_effects.drx_sl_find_wish_granter( )
end

function drx_sl_give_sl_task( a, b )
	disable_info( ("drx_sl_meet_honcho_" .. load_var( db.actor, "drx_sl_current_honcho", "" )) )
	local npc = who_is_npc( a, b )
	local task_section = axr_task_manager and axr_task_manager.drx_sl_generate_random_sl_task( npc, nil, true )
	while last_task_id and task_section ~= nil and task_section ~= last_task_id do
		task_section = axr_task_manager.drx_sl_generate_random_sl_task( npc, true, true )
	end
	if ( last_task_id ) then
		printf( ("DRX SL storyline task started: " .. last_task_id) )
		local se_obj = npc and alife( ):object( npc:id( ) )
		local giver_id = se_obj and (se_obj.group_id ~= 65535 and se_obj.group_id or se_obj.id)
		save_var( db.actor, "drx_sl_current_task", last_task_id )
		task_manager.get_task_manager( ):give_task( last_task_id, giver_id )
		if ( (not string.find( "meet_task", last_task_id )) and (not string.find( "find_wish_granter", last_task_id )) ) then
			local giver_task_count = (load_var( db.actor, ("drx_sl_task_giver_" .. giver_id), 0 ) + 1)
			save_var( db.actor, ("drx_sl_task_giver_" .. giver_id), giver_task_count )
			printf( ("DRX SL: drx_sl_task_giver_" .. giver_id .. " registered (" .. giver_task_count .. " outstanding)") )
		end
		last_task_id = nil
	end
end

function who_is_npc(first_speaker, second_speaker)
	return first_speaker:id() == AC_ID and second_speaker or first_speaker
end
]]

-- temp/stock_scripts/scripts/axr_task_manager.script:23-85, 200-201, 223-286 (old code left out), 560-614 (old code left
-- out), 668-679
local STOCK_ATM = [[
drx_sl_main_honcho_table = {
	["stalker"] = "esc_m_trader",
	["dolg"] = "bar_dolg_general_petrenko_stalker",
	["freedom"] = "mil_smart_terrain_7_7_freedom_leader_stalker",
	["csky"] = "mar_smart_terrain_base_stalker_leader_marsh",
	["ecolog"] = "yan_stalker_sakharov",
	["killer"] = "cit_killers_merc_trader_stalker",
	["army"] = "agr_smart_terrain_1_6_near_2_military_colonel_kovalski",
	["bandit"] = "zat_b7_bandit_boss_sultan",
	["monolith"] = "pri_monolith_monolith_trader_stalker",
	["renegade"] = "zat_b7_bandit_boss_sultan",
	["greh"] = "red_greh_trader",
	["isg"] = "cit_killers_merc_trader_stalker",
}

drx_sl_honchos_table = {
	{"esc_m_trader", "stalker"},  -- Cordon - Sidorovich (Loner Trader)
	{"esc_smart_terrain_5_7_loner_mechanic_stalker", "stalker"},  -- Cordon - Xenotech (Loner Mechanic)
	{"zat_a2_stalker_barmen", "stalker"},  -- Zaton - Beard (Loner Trader)
	{"zat_b18_noah", "stalker"},  -- Zaton - Noah (Loner Honcho)
	{"bar_dolg_general_petrenko_stalker", "dolg"},  -- Rostok - Petrenko (Duty Trader)
	{"bar_visitors_stalker_mechanic", "dolg"},  -- Rostok - Mangun (Duty Mechanic)
	{"mil_smart_terrain_7_7_freedom_leader_stalker", "freedom"},  -- Military Warehouses - Lukash (Freedom Honcho)
	{"jup_a6_freedom_leader", "freedom", "stalker"},  -- Jupiter - Loki (Freedom Honcho)
	{"mar_smart_terrain_base_stalker_leader_marsh", "csky"},  -- Great Swamp - Cold (Clear Sky Honcho)
	{"mar_base_stalker_barmen", "csky"},  -- Great Swamp - Librarian (Clear Sky Trader)
	{"yan_stalker_sakharov", "ecolog"},  -- Yantar - Sakharov (Ecologist Trader)
	{"jup_b6_scientist_tech", "ecolog", "stalker"},  -- Jupiter - Tukarev (Ecologist Mechanic)
	{"cit_killers_merc_trader_stalker", "killer"},  -- Dead City - Dushman (Mercenary Trader)
	{"cit_killers_merc_mechanic_stalker", "killer"},  -- Dead City - Hog (Mercenary Mechanic)
	{"cit_killers_merc_mechanic_stalker", "killer"},  -- Zaton - Vector (Mercenary Trader)
	{"merc_pri_grifon_mlr", "killer"},  -- Outskirts - Griffith (Mercenary Operator)
	{"agr_smart_terrain_1_6_near_2_military_colonel_kovalski", "army"},  -- Agoroprom - Kuznetsov (Military Honcho)
	{"agr_smart_terrain_1_6_army_mechanic_stalker", "army"},  -- Agoroprom - Kirilov (Military Mechanic)
	{"zat_b7_bandit_boss_sultan", "bandit"},  -- Dark Valley - Sultan (Bandit Honcho)
	{"val_smart_terrain_7_4_bandit_trader_stalker", "bandit"},  -- Dark Valley - Olivius (Bandit Trader)
	{"jup_cont_trader_bandit", "bandit"},  -- Jupiter - Klenov (Bandit Trader)
	{"pri_monolith_monolith_trader_stalker", "monolith"},  -- Pripyat - Rabbit (Monolith Trader)
	{"pri_monolith_monolith_mechanic_stalker", "monolith"},  -- Pripyat - Cleric (Monolith Mechanic)
	{"trader_monolith_kbo", "monolith"},  -- Outskirts - Olivar (Monolith Trader)
	{"red_greh_trader", "greh"},  -- Red Forest - Stribog (Sin Trader)
	{"red_greh_tech", "greh"},  -- Red Forest - Dazhbog (Sin Mechanic)
}

local skipped_tasks = {}

function drx_sl_generate_random_sl_task( npc, skip, is_sim )

	local tm = task_manager.get_task_manager( )
	local task_info = tm.task_info

	-- Get task section:
	local sec
	local st = db.storage[npc:id( )]
	if ( st and st.ini and st.section_logic ) then
		sec = st.ini:r_string_ex( st.section_logic, "task_section" )
		if ( sec ) then
			sec = ("drx_sl_" .. sec .. "_task_")
		end
	end
	if not ( sec ) then
		sec = npc:section( ) ~= "m_trader" and ("drx_sl_" .. npc:section( ) .. "_task_") or ("drx_sl_" .. npc:name( ) .. "_task_")
	end

	-- Build list of valid tasks:
	local honcho_task_list = {}
	local size_t = 0

	for task_id in pairs(CFG_CACHE) do
		if starts_with(task_id, sec) then
			if ( skipped_tasks[task_id] ~= true and task_info[task_id] == nil and xr_conditions.has_completed_task_prerequisites( nil, nil, {task_id} ) ) then
				if ( skip ) then
					skipped_tasks[task_id] = true
					return
				else
					size_t = size_t + 1
					honcho_task_list[size_t] = task_id
				end
			end
		end
	end

	-- Pick random task from list of valid tasks:
	if ( #honcho_task_list > 0 ) then
		math.randomseed( device( ):time_global( ) )
		return honcho_task_list[math.random( #honcho_task_list )]
	else
		return ("drx_sl_" .. load_var( db.actor, "drx_sl_current_honcho", "" ) .. "_default_task")
	end

end

function drx_sl_get_finished_task( npc, is_sim )

	local tm = task_manager.get_task_manager( )
	local task_info = tm.task_info

	local sec
	local st = db.storage[npc:id( )]

	-- Check if player is on end game task:
	local endgame_task = load_var( db.actor, "drx_sl_endgame_task", "" )
	if ( endgame_task ~= "" ) then
		if ( db.actor:get_task( endgame_task, true ) ~= nil and task_info[endgame_task] and task_info[endgame_task].stage ~= nil and task_info[endgame_task].stage == (CFG_CACHE[endgame_task].stage_complete or 254) ) then
			if ( task_info[endgame_task].status ~= "fail" and task_info[endgame_task].status ~= "completed" ) then
				return endgame_task
			end
		end
	end

	if ( st and st.ini and st.section_logic ) then
		sec = st.ini:r_string_ex( st.section_logic, "task_section" )
		if ( sec ) then
			sec = (sec .. "_task_")
		end
	end
	if not ( sec ) then
		sec = npc:section() ~= "m_trader" and ("drx_sl_" .. npc:section( ) .. "_task_") or ("drx_sl_" .. npc:name( ) .. "_task_")
	end


	for task_id in pairs(CFG_CACHE) do
		if starts_with(task_id, sec) then
			if ( db.actor:get_task( task_id, true ) ~= nil and task_info[task_id] and task_info[task_id].stage ~= nil and task_info[task_id].stage == (CFG_CACHE[task_id].stage_complete or 254) ) then
				if ( task_info[task_id].status ~= "fail" and task_info[task_id].status ~= "completed" ) then
					return task_id
				end
			end
		end
	end
end

function drx_sl_set_finished_task_complete( npc, is_sim )

	local task_id = drx_sl_get_finished_task( npc, is_sim )

	if not ( task_id ) then
		printf( "WARNING: axr_task_manager.drx_sl_set_finished_task_complete: no task %s", task_id )
		return
	end

	task_manager.get_task_manager():set_task_completed(task_id)

end
]]

local function stock_module(M, name, src)
	local mod = M.env[name] or {}
	setmetatable(mod, { __index = M.env })
	M.env[name] = mod
	local f = assert(loadstring(src, "=stock " .. name))
	setfenv(f, mod)
	f()
	return mod
end

-- the leaders: an object for each on every machine (ids 900+), the story ids are their sections
LEADERS = {}
local LEADER_IDS = {}

local function chain_tasks(M)
	local ids = {}
	for _, row in ipairs(M.env.axr_task_manager.drx_sl_honchos_table) do
		local h = row[1]
		ids[#ids + 1] = "drx_sl_" .. h .. "_meet_task_1"
		ids[#ids + 1] = "drx_sl_" .. h .. "_task_1"
		ids[#ids + 1] = "drx_sl_" .. h .. "_task_2"
	end
	for _, h in pairs(M.env.axr_task_manager.drx_sl_main_honcho_table) do ids[#ids + 1] = "drx_sl_" .. h .. "_start_game_1" end
	ids[#ids + 1] = "drx_sl_find_wish_granter_task"
	return ids
end

STORYLINE_HOOK = function(M) end -- a test file's own additions

SETUP_HOOK = function(M)
	local e = M.env
	M.declared, M.changed = {}, {}
	e.AddScriptCallback = function(name) M.declared[name] = true end
	e.coop.members = function() return {} end
	e.coop.is_dedicated = function() return false end
	e.coop.is_map_server = function() return false end
	if M.role == "host" then M.world_faction = "stalker" end
	e.USE_MARSHAL = nil
	setfenv(assert(loadstring(STOCK_G, "=stock _g (storyline)")), e)()
	e.IsStoryMode = function() return STORY end
	e.device = function() return { time_global = function() return NOW end } end
	e.relation_registry = { community_relation = function(a, b) return REL[tostring(a) .. "|" .. tostring(b)] or 0 end }
	e.alife = function()
		return {
			object = function(_, id) return e.alife_object(id) end,
			actor = function() return { community = function() return M.actor._comm end } end,
			has_info = function(_, _, i) return M.infos[i] == true end,
		}
	end
	e.xr_conditions.is_alive = function(_, _, p) return ALIVE == nil or ALIVE[p[1]] == true end
	e.xr_conditions.has_completed_task_prerequisites = function() return true end
	stock_module(M, "xr_effects", STOCK_XR)
	stock_module(M, "dialogs", STOCK_DIALOGS)
	stock_module(M, "axr_task_manager", STOCK_ATM)
	local cache = {}
	for _, id in ipairs(chain_tasks(M)) do
		M.ini[id] = M.ini[id] or {}
		cache[id] = {}
	end
	e.axr_task_manager.CFG_CACHE = cache
	M.leader = {}
	local n = 900
	for _, row in ipairs(e.axr_task_manager.drx_sl_honchos_table) do
		if not M.leader[row[1]] then
			n = n + 1
			M.leader[row[1]] = M.new_obj(n, row[1], vec(n, 0, 0), { _stalker = true })
		end
	end
	-- the functions as the stock has them, before any co-op script loads
	M.stock_fn = {
		load_var = e.load_var, save_var = e.save_var, meet = e.xr_effects.drx_sl_meet_random_honcho,
		decrease = e.xr_effects.drx_sl_decrease_sl_tasks_count, wish = e.xr_effects.drx_sl_find_wish_granter,
		fin = e.dialogs.drx_sl_set_finished_task_complete, give = e.dialogs.drx_sl_give_sl_task,
		task_callback = e.task_manager.task_callback,
	}
	STORYLINE_HOOK(M)
end

-- the actor's pstor of machine M
function pstor(M) return M.env.db.storage[0].pstor end
