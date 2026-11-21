-- A co-op host loads its save before its session starts (coop_manager.cpp autostart waits for level_ready; the in-game
-- Host comes later still; stand b57h: hosting 15 s after the first update). coop_npc_relations read the save's squad
-- relation policies (coop_npc_relations_v1) in load_state only when a session already ran, so on every co-op host they
-- were dropped at load, and the first save in the session wrote the empty table back: the loss was permanent.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = mode == "none" and "sp" or "host" -- single player has no session at any time
dofile("tests/lua/support/stubs_mods.lua")

make_actor()
local writes = {}
local function clear() for k in pairs(writes) do writes[k] = nil end end
-- One offline member: the relation goes through ALife goodwill to the character's entity.
spawn("coop_player_avatar", nil, nil, { id = PROXY, offline = true })
local member = spawn("stalker", nil, nil, { id = 102, offline = true })
function member:force_set_goodwill(value, target) writes[self.id .. ":" .. tostring(target)] = value end
local squad = { id = 200, player_id = "stalker" }
function squad:squad_members()
	local done = false
	return function()
		if done then return nil end
		done = true
		return { id = member.id, object = member }
	end
end
SE[squad.id] = squad

-- The engine's phase is Off until the host starts hosting: no session while the level loads.
local hosting = false
local is_active = coop.is_active
coop.is_active = function() return hosting and is_active() end

start_all()
modes.install(coop_mode, mode)
local R = load_script("coop_npc_relations")
R.on_game_start()
local live = mode ~= "none"

local function saved_policies(...)
	local t = { [squad.id] = { all = "neutral", chars = { [PROXY] = "enemy" } } }
	for _, extra in ipairs({ ... }) do t[extra] = { all = "friend", chars = {} } end
	return t
end
local function tick()
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
end

-- alife_storage_manager keeps one m_data: load_state gets it, and each save writes into the same table.
local SAVED = saved_policies()
local m_data = { coop_npc_relations_v1 = SAVED }
SendScriptCallback("load_state", m_data)
SendScriptCallback("actor_on_first_update") -- b57h host: first update 09:52:54, "phase off -> hosting" 09:53:09
tick()
check(next(writes) == nil, mode .. ": no relation is written while this process has no session")
SendScriptCallback("save_state", m_data) -- a save before the session (single player all the time)
check(m_data.coop_npc_relations_v1 == SAVED, mode .. ": a save without a session leaves the save's own record as it was")

hosting = true
-- The first save in the session can come before the next update (a quicksave right after Host).
SendScriptCallback("save_state", m_data)
local kept = m_data.coop_npc_relations_v1
if live then
	local p = type(kept) == "table" and kept[squad.id]
	check(p and p.all == "neutral" and p.chars and p.chars[PROXY] == "enemy",
		mode .. ": the first save in the session keeps the squad audience and the character override it loaded")
else
	check(kept == SAVED, "none: single player never writes the record")
end
tick()
if live then
	check(writes["102:" .. PROXY] == -1000,
		mode .. ": the saved override reaches the squad's member once the session starts after the load")
	if mode == "hostplay" then check(writes["102:0"] == 0, "hostplay: the saved audience reaches the host's own character") end
else
	check(next(writes) == nil, "none: no relation is written in single player")
end

-- A choice made in the session is newer than the save: reading the save afterwards must not undo it.
clear()
hosting = false
m_data = { coop_npc_relations_v1 = saved_policies() }
SendScriptCallback("load_state", m_data)
tick()
hosting = true
if live then R.set_squad_relation_for(squad, "friend", PROXY) end
tick()
SendScriptCallback("save_state", m_data)
if live then
	local p = m_data.coop_npc_relations_v1[squad.id]
	check(p and p.all == "neutral" and p.chars[PROXY] == "friend",
		mode .. ": a relation set in the session before the next update goes on top of the loaded ones")
	check(writes["102:" .. PROXY] == 1000, mode .. ": the newer relation stays on the squad's member")
end

-- Where the session already runs at the load (a co-op client, the server mode) the save is read at once, and a record
-- still waiting from an earlier load is not read on top of it.
clear()
hosting = false
SendScriptCallback("load_state", { coop_npc_relations_v1 = saved_policies(201) })
hosting = true
m_data = { coop_npc_relations_v1 = saved_policies() }
SendScriptCallback("load_state", m_data)
SendScriptCallback("save_state", m_data)
if live then
	local t = m_data.coop_npc_relations_v1
	check(t[squad.id] and t[squad.id].chars[PROXY] == "enemy" and t[201] == nil,
		mode .. ": a load with a running session reads its own record only")
end
done("npc relations late session " .. mode)
