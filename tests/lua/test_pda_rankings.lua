-- Anomaly Coop: the ranking list of the PDA "Statistics" tab on a client (coop_pda_rankings + coop_quests_pda).
-- Owner 2026-11-16 (build 51): the list showed on a client only after the HOST opened its PDA, and his own row had a stale
-- faction. Run: tools\test_lua.cmd pda_rankings
dofile("tests/lua/support/harness_quests.lua")

local SIZE = 3
local OWN = SIZE + 1

-- coop_main keeps a set of handlers per event (coop_main.add_event_handler); the harness keeps one: give it the real shape
local function multi_handlers(M)
	local sets = {}
	M.env.coop_main.add_event_handler = function(name, f)
		if not sets[name] then
			sets[name] = {}
			M.handlers[name] = function(...)
				for _, h in ipairs(sets[name]) do h(...) end
			end
		end
		table.insert(sets[name], f)
		return true
	end
end

local Hm = machine("host", 0)
local Cm = machine("client", 1)
multi_handlers(Hm)
multi_handlers(Cm)
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- the client's character on the host
Hm.new_obj(710, "sim_default_bandit_1", vec(300, 0, 0), { _stalker = true })
Hm.actor._cname, Hm.actor._comm, Hm.actor._rank = "Host", "actor_bandit", 900
-- the client's own character: the world's faction bandit, its own rank and reputation
Cm.actor._cname, Cm.actor._comm, Cm.actor._rank, Cm.actor._rep = "stormie", "actor_bandit", 120, 600

for _, M in ipairs({ Hm, Cm }) do
	local e = M.env
	e.ranks = { get_obj_rank_name = function() return "novice" end, get_se_obj_rank_name = function() return "veteran" end }
	e.utils_obj = { get_reputation_name = function(v) return v >= 500 and "st_reputation_good" or "st_reputation_neutral" end }
	e.game_relations = { is_factions_enemies = function() return false end, is_factions_friends = function() return false end }
	e.story_objects = { story_id_by_object_id = {} }
	e.IsStalker = function(o, cls) if cls then return true end return type(o) == "table" and o._stalker == true end
	-- the shared story info of a closed host PDA, on both machines; the client's "ui_pda" is stuck (nothing takes it away there)
	M.infos.ui_pda_hide = true
end
Cm.infos.ui_pda = true

-- host: the stock list (pda.script calculate_rankings over its ALife)
Hm.env.alife = function() return { object = function(_, id)
	local o = Hm.objects[id]
	if not (o and o._stalker) then return nil end
	return { id = id, character_name = function() return "se_" .. id end, rank = function() return id end,
		community = function() return "stalker" end, reputation = function() return 0 end,
		character_icon = function() return "ic" end, clsid = function() return 1 end, alive = function() return true end }
end } end
Hm.actor._stalker = true
Hm.env.alife_object = function(id) return Hm.objects[id] end
Hm.host_calcs = 0
Hm.env.pda = {
	calculate_rankings = function() Hm.host_calcs = Hm.host_calcs + 1 end,
	get_coc_ranking_list = function() return Hm.ranking or { 0, 500, 710 } end,
	get_rankings_array_size = function() return SIZE end,
	coc_rankings_can_show = function(i) if Hm.env.has_alife_info("ui_pda_hide") then return false end return i <= SIZE end,
	coc_rankings_set_name = function(i) return "stock" .. i end,
	coc_rankings_set_description = function() return "" end,
	coc_rankings_set_hint = function() return "" end,
	coc_rankings_set_icon = function() return "" end,
	coc_rankings_show_border = function() return false end,
}
-- client: the stock functions over its frozen ALife copy; its row SIZE+1 is the join save's server object 0
Cm.stock_calcs = 0
local stock_list = { [1] = 710, [2] = 500, [3] = 0, [OWN] = 0 }
Cm.env.pda = {
	calculate_rankings = function() Cm.stock_calcs = Cm.stock_calcs + 1 end,
	get_rankings_array_size = function() return SIZE end,
	coc_rankings_can_show = function(i)
		if Cm.env.has_alife_info("ui_pda_hide") then return false end
		return stock_list[i] ~= nil
	end,
	coc_rankings_set_name = function(i) return "stock" .. i end,
	coc_rankings_set_description = function(i) return i == OWN and "STALE dolg" or "stock desc" end,
	coc_rankings_set_hint = function() return "" end,
	coc_rankings_set_icon = function() return "stock_icon" end,
	coc_rankings_show_border = function() return false end,
}

-- the engine's ranking window (UIRankingWnd.cpp update_info + UIRankingsCoC.cpp Update): a row's text is written when it is added
local function window()
	return { rows = {} }
end
local function pass(M, w)
	local p = M.env.pda
	for i = 1, OWN do
		if p.coc_rankings_can_show(i) then
			if not w.rows[i] then
				w.rows[i] = { name = p.coc_rankings_set_name(i), desc = p.coc_rankings_set_description(i) }
			end
		else
			w.rows[i] = nil
		end
	end
end
local function shown(w) local n = 0 for i = 1, OWN do if w.rows[i] then n = n + 1 end end return n end

-- boot: coop_quests_pda wraps the pda functions on actor_on_first_update, ours on the first actor_on_update after it
local function boot(M, with_fix)
	load_script(M, "coop_mode")
	load_script(M, "coop_hostplay_mode").on_game_start()
	load_script(M, "coop_quests_core").on_game_start()
	load_script(M, "coop_quests_pda").on_game_start()
	if with_fix then load_script(M, "coop_pda_rankings").on_game_start() end
	fire(M, "actor_on_first_update")
	fire(M, "actor_on_update")
end
local WITH_FIX = os.getenv("COOP_PDA_RANKINGS_OFF") == nil
boot(Hm, WITH_FIX)
boot(Cm, WITH_FIX)

print("== the client opens the Statistics tab; the host never opens its PDA")
local w = window()
local sent0 = count_sent(Cm, "quests.rank_req")
pass(Cm, w) -- Show: no actor_on_info_callback "ui_pda" (stuck on the client)
check(count_sent(Cm, "quests.rank_req") == sent0 + 1, "the open tab asks the host for the list itself (no ui_pda callback needed)")
check(not w.rows[OWN], "no own row from the client's frozen ALife copy before the host's answer")
pump()
NOW = NOW + 3000
pass(Cm, w) -- the window's 3 s update
check(shown(w) == OWN, "the host's list and the own row show although the host's PDA is closed (ui_pda_hide on)")
check(w.rows[3] and w.rows[3].name == "3. se_710", "row 3 is the host's list")
local own = w.rows[OWN]
check(own and own.name:find("stormie", 1, true) ~= nil, "own row: his own name")
check(own and own.desc:find("T(actor_bandit)", 1, true) ~= nil and not own.desc:find("dolg", 1, true),
	"own row: his own faction, not the stale one of the ALife copy")
check(own and own.desc:find("120", 1, true) ~= nil and own.desc:find("T(st_reputation_good)", 1, true) ~= nil,
	"own row: his own rank and reputation")
check(w.rows[2] and w.rows[2].name:find("stormie", 1, true) ~= nil, "his line in the host's list carries his own name")

print("== throttling: an open tab does not ask on every pass")
local sent1 = count_sent(Cm, "quests.rank_req")
for _ = 1, 5 do
	NOW = NOW + 3000
	pass(Cm, w)
	pump()
end
check(count_sent(Cm, "quests.rank_req") == sent1, "15 s of an open tab: no new request")
NOW = NOW + 15000
pass(Cm, w)
check(count_sent(Cm, "quests.rank_req") == sent1 + 1, "an open tab asks again after 30 s")

print("== a newer answer is written into the rows")
Hm.objects[710] = nil
Hm.new_obj(720, "sim_default_bandit_2", vec(300, 0, 0), { _stalker = true })
Hm.ranking = { 0, 500, 720 }
pump()
NOW = NOW + 3000
pass(Cm, w)
check(shown(w) == 0, "one pass with every row hidden after a newer answer")
NOW = NOW + 3000
pass(Cm, w)
check(w.rows[3] and w.rows[3].name == "3. se_720", "the rows come back with the newer answer's text")
check(w.rows[OWN] ~= nil, "own row back")

print("== the tab closed and opened again")
NOW = NOW + 20000
local sent2 = count_sent(Cm, "quests.rank_req")
pass(Cm, w)
check(count_sent(Cm, "quests.rank_req") == sent2 + 1, "an open after a pause asks at once")

print("== host and single player: the stock code")
local hw = window()
pass(Hm, hw)
check(shown(hw) == 0, "host: its rows follow its own ui_pda_hide as the stock does")
Hm.infos.ui_pda_hide = nil
pass(Hm, hw)
check(shown(hw) == SIZE and hw.rows[1].name == "stock1", "host: the stock rows")
check(count_sent(Hm, "quests.rank_req") == 0, "the host asks nobody")
Cm.active = false
local sw = window()
Cm.infos.ui_pda_hide = nil
pass(Cm, sw)
check(sw.rows[OWN] and sw.rows[OWN].desc == "STALE dolg", "outside a session: the stock functions unchanged")
Cm.active = true
Cm.infos.ui_pda_hide = true

print("== a reply that is not the host's changes nothing")
NOW = NOW + 3000
pass(Cm, w)
check(shown(w) == OWN, "the rows are up")
Cm.handlers["quests.rank"](Cm.env.coop_main.encode({ q = 5, k = 1, m = 1, w = 1, d = "{}" }), 7)
NOW = NOW + 3000
pass(Cm, w)
check(shown(w) == OWN, "peer 7's 'answer' neither clears the rows nor replaces the list")

do
	local modes = dofile("tests/lua/support/modes.lua")
	local gamma = os.getenv("GAMMA_SCRIPTS")
	local stock_pda = loadfile("temp/review/corpus/merged/pda.script") or (gamma and loadfile(gamma .. "/pda.script"))
	assert(stock_pda, "the active GAMMA pda.script is required")
	for _, answer in ipairs(modes.names()) do
		if answer ~= "none" then
			print("== " .. answer .. ": the stock ranking list contains a reused id")
			local M = machine("host", 0)
			local E = M.env
			local p = setmetatable({}, { __index = E })
			setfenv(stock_pda, p)()
			E.pda = p
			E.ranks, E.utils_obj, E.game_relations = Hm.env.ranks, Hm.env.utils_obj, Hm.env.game_relations
			E.ui_options = { get = function() return false end }
			E.alife_storage_manager = { get_se_obj_state = function() return {} end }
			E.IsStalker = function(o, cls) return (cls or (o and o:clsid())) == 1 end
			local npc = {
				id = 700, clsid = function() return 1 end, character_name = function() return "Krot" end,
				community = function() return "stalker" end, reputation = function() return 0 end,
				rank = function() return 900 end, character_icon = function() return "ui_npc" end,
			}
			local objects = { [700] = npc, [701] = { id = 701, clsid = function() return 2 end } }
			local reads = 0
			E.alife_object = function(id) reads = reads + 1; return objects[id] end
			local list = p.get_coc_ranking_list()
			list[1], list[2] = 700, 701
			local getters = { "name", "description", "hint", "icon" }
			local stock = {}
			for _, name in ipairs(getters) do stock[name] = p["coc_rankings_set_" .. name](1) end

			modes.install(load_script(M, "coop_mode"), answer)
			load_script(M, "coop_quests_core").on_game_start()
			load_script(M, "coop_quests_pda").on_game_start()
			fire(M, "actor_on_first_update")
			reads = 0
			for _, name in ipairs(getters) do
				local getter = p["coc_rankings_set_" .. name]
				local ok, value = pcall(getter, 2)
				check(ok and value == "", answer .. ": reused id returns an empty " .. name)
				if answer == "hostplay" then
					check(getter(1) == stock[name], "hostplay: a stalker keeps the stock " .. name)
				else
					check(getter(1) == "", answer .. ": even a valid row is hidden for the ghost actor")
				end
			end
			check(p.coc_rankings_can_show(2) == false and p.coc_rankings_show_border(2) == false,
				answer .. ": the item has no ranking row or border")
			if answer ~= "hostplay" then check(reads == 0, answer .. ": no stock ALife reads") end
		end
	end
end

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
