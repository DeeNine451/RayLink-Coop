-- Stand b57h (progress_group): a co-op host starts its session after its level is up (coop_manager.cpp autostart waits
-- for level_ready; the in-game Host comes later still). At that level's actor_on_first_update nobody led here, so
-- coop_progress_check installed no observers and the keeper never counted the guest's steps or corpse search.
local modes = dofile("tests/lua/support/modes.lua")
local mode = modes.names()[1]
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")

local drops = 0
death_manager = { create_release_item = function(npc, marker)
	drops = drops + 1
	return npc:id(), marker
end }
ranks = { get_obj_rank_name = function() return "veteran" end }
game_statistics = { increment_rank = function(value) return value end }

for _, name in ipairs({ "npc_on_death_callback", "monster_on_death_callback" }) do axr_main.callback_add(name) end
make_actor()
local _, body = spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = PROXY })
local _, corpse = spawn("stalker", vec3(0, 0, 0))
corpse._alive = false

-- The engine's phase is Off until the host starts hosting: no session while the level loads.
local hosting = false
local is_active = coop.is_active
coop.is_active = function() return hosting and is_active() end

start_all()
modes.install(coop_mode, mode)
local P, C = coop_progress_check, coop_mods_core
SendScriptCallback("actor_on_first_update") -- the other adapters, as in the game
local release_item = death_manager.create_release_item
local hits = axr_main.count("npc_on_before_hit")
local seen = {}
local observe = P.observe
function P.observe(character, kind, amount, meta)
	seen[#seen + 1] = { character = character, kind = kind, amount = amount, rank = type(meta) == "table" and meta.rank }
	return observe(character, kind, amount, meta)
end
local function count(kind, rank)
	local n = 0
	for _, row in ipairs(seen) do
		if row.kind == kind and row.character == PROXY and (rank == nil or row.rank == rank) then n = n + 1 end
	end
	return n
end

P.on_game_start()
-- The save loads before the session too (load_state comes before the first update): the keeper's records of the save
-- were dropped, so a returning guest was checked from an empty record after a host restart.
local restored = {}
local restore = P.restore
function P.restore(character, saved)
	restored[#restored + 1] = { character = character, saved = saved }
	return restore(character, saved)
end
local SAVED = { records = {} }
SendScriptCallback("load_state", { coop_mods_pdata = { [tostring(PROXY)] = { progress_checked = SAVED } } })
check(#restored == 0, "no records restored while this process has no session")
SendScriptCallback("actor_on_first_update") -- b57h host: first update 09:52:54, "phase off -> hosting" 09:53:09
SendScriptCallback("actor_on_update")
check(death_manager.create_release_item == release_item and axr_main.count("npc_on_before_hit") == hits,
	"no observers while this process has no session")

hosting = true
SendScriptCallback("actor_on_update") -- the first update after hosting starts
if mode == "hostplay" then
	check(#restored == 1 and restored[1].character == PROXY and restored[1].saved == SAVED,
		"the keeper restores the save's records once the co-op host starts its session")
else
	check(#restored == 0, "only the process that decides the world restores the keeper's records")
end
SendScriptCallback("actor_on_update") -- the body's first sampled position
body._pos = vec3(14, 0, 0)
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
-- The client's corpse_loot relay (coop_mods_items.script) runs the loot roll as the searcher.
local ok, id, marker = C.as_player(body, death_manager.create_release_item, corpse, "pass through")
check(ok and id == corpse:id() and marker == "pass through" and drops == 1,
	"the corpse roll keeps its call and returns")

if mode == "none" or mode == "srv_world" then
	check(death_manager.create_release_item == release_item and axr_main.count("npc_on_before_hit") == hits
		and #seen == 0, "no observers without a led map, also once the session runs")
	done("progress late session " .. mode)
	return
end

check(count("step_m") == 1, "the keeper counts the guest's steps once the session starts after the level")
check(count("corpse_search", "veteran") == 1,
	"the keeper counts the guest's relayed corpse search with the corpse's rank once the session starts after the level")
local wrapper = death_manager.create_release_item
NOW = NOW + 1000
SendScriptCallback("actor_on_update")
SendScriptCallback("actor_on_first_update")
check(death_manager.create_release_item == wrapper and axr_main.count("npc_on_before_hit") == hits + 1,
	"the observers install once")
done("progress late session " .. mode)
