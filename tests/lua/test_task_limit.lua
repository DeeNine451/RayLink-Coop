-- The limit of tasks per NPC in a session (coop_quests_offer): the journal is one for the group, so the stock limit counted
-- every player's tasks and a friend's two tasks left the NPC red and silent for everybody.
-- Run: tools\test_lua.cmd task_limit
dofile("tests/lua/support/harness_quests.lua")

local M = machine("client", 1)
local e = M.env
e.game.translate_string = function(id) return id end
e.dialogs.get_npc_task_limit = function() return 2 end
M.msgs = {}
e.actor_menu = { set_msg = function(_, text) M.msgs[#M.msgs + 1] = text end }

-- the taskboard tab, in the shape the mod has it
local clicked = 0
local item = { is_blocked = false }
local list = { GetSelectedItem = function() return item end, RemoveAll = function() end }
local Tab = { task_list = list }
Tab.OnTaskClicked = function(self) clicked = clicked + 1 end
Tab.OnBtnRefreshClicked = function() end
e.ui_pda_taskboard_tab = { pda_taskboard_tab = Tab }
e.pda_taskboard = {
	prepare_task = function() end, get_details = function() end,
	get_nearby_npcs = function() return {} end, refresh_tasks = function() end,
}

M.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
load_script(M, "coop_quests_core")
load_script(M, "coop_quests_offer")
e.coop_quests_core.on_game_start()
e.coop_quests_offer.on_game_start()
fire(M, "actor_on_first_update")

print("== the limit is per player")
check(e.dialogs.get_npc_task_limit() == 4, "two players: twice the stock limit")
M.players[#M.players + 1] = { id = 2, is_self = false, avatar_id = 501 }
check(e.dialogs.get_npc_task_limit() == 6, "three players: three times")
M.active = false
check(e.dialogs.get_npc_task_limit() == 2, "out of a session: stock")
M.active = true

print("== a blocked task says why")
item.is_blocked = true
Tab:OnTaskClicked()
check(#M.msgs == 1 and M.msgs[1] == "st_coop_quests_npc_limit", "the reason is on the screen")
check(clicked == 1, "the mod's own click still runs")
item.is_blocked = false
Tab:OnTaskClicked()
check(#M.msgs == 1 and clicked == 2, "a free task takes no message")
M.active = false
item.is_blocked = true
Tab:OnTaskClicked()
check(#M.msgs == 1, "out of a session: stock, no message")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
