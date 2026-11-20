-- Quests a player finishes by holding or handing over an item (owner 2026-11-16, build 51: "the parcel for Sidorovich cannot be
-- turned in, one of the guys has it"). coop_tasks + coop_quests_party + coop_quests_offer on a host and a client.
--   - a client's turn-in of a delivery (stock tasks_delivery, status functor delivery_task) or a fetch task (actor_has_fetch_item)
--     goes through only when the host's own view of the group's characters has the parcel / the items: nobody holds it, or the
--     client only says so, and the host refuses;
--   - the delivery's on_complete (remove_delivery_item) takes THIS task's parcel (var.item_1_id) from whoever holds it, never
--     another parcel of the same section (quest_package_1..8 are also A-Life Quests courier parcels and other deliveries);
--   - a trader-class NPC (Sidorovich is m_trader, class AI_TRD_S = clsid.script_trader: IsStalker says no) gets the host's offer.
-- Every refusal is proved next to the same case with the same ids going through.
-- Run: tools\test_lua.cmd quests_handover
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_mode", "coop_hostplay_mode", "coop_quests_core", "coop_tasks", "coop_quests_offer", "coop_quests_party", "coop_quests_story" }
local DT = "simulation_task_48" -- stock tm_dynamic: on_init_delivery_task(simulation_task_48:false:true:quest_package_4:quest_package_5)
local FT = "fetch_x"

local function setup_world(M)
	local e = M.env
	M.on_complete = {}
	M.ini[DT] = { status_functor = "delivery_task" }
	M.ini[FT] = { status_functor = "actor_has_fetch_item" }
	M.ini.plain_t = {}
	M.npc = M.new_obj(700, "bar_dolg_leader", vec(5, 0, 0), { _stalker = true })
	e.db.storage[700] = { object = M.npc }
	-- Sidorovich: section m_trader, class AI_TRD_S (clsid.script_trader); stock IsStalker is false for him
	M.sid = M.new_obj(760, "esc_m_trader", vec(6, 0, 0), { _trader = true })
	e.db.storage[760] = { object = M.sid }
	M.target = M.new_obj(800, "sim_default_stalker_2", vec(8, 0, 0), { _stalker = true }) -- the delivery's receiver
	e.IsTrader = function(o) return type(o) == "table" and o._trader == true end
	M.npc_tasks = { [760] = { "plain_t" } }
	-- stock tasks_delivery.remove_delivery_item: to the NPC the actor talks to, else the actor's first item of that section
	e.xr_effects.remove_delivery_item = function(actor, npc, p)
		local var = e.load_var(e.db.actor, p[1])
		if not (var and var.item_1_sec) then return end
		local talker = e.mob_trade.GetTalkingNpc()
		local item = e.db.actor:object(var.item_1_sec)
		if talker then
			if item then e.db.actor:transfer_item(item, talker) end
		elseif item then
			e.alife_release_id(item:id())
		end
	end
	-- stock tasks_fetch.actor_has_fetch_item (the part that matters here): the actor's own items
	e.task_status_functor.actor_has_fetch_item = function(tsk, id)
		local sec = e.load_var(e.db.actor, id .. "_fetch")
		local need = tonumber(e.load_var(e.db.actor, id .. "_fetch_count")) or 1
		tsk.stage = (sec and M.count(e.db.actor, sec) >= need) and 1 or 0
	end
	e.task_status_functor.delivery_task = function(tsk, id) end
end

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do M.env[n].on_game_start() end
	fire(M, "actor_on_first_update")
end

print("== setup")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
setup_world(Hm)
setup_world(Cm)
local proxy = Hm.new_obj(500, "coop_player_avatar", vec(4, 0, 0), { _stalker = true }) -- the client's character on the host
Cm.new_obj(500, "coop_player_avatar", vec(0, 0, 0), { _stalker = true }) -- the host's character on the client
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = 500 } }
Cm.actor._pos = vec(4, 0, 0)
boot(Hm)
boot(Cm)

local tm_h = Hm.env.task_manager.get_task_manager()
local tm_c = Cm.env.task_manager.get_task_manager()

local function client_turn_in(id)
	tm_c:set_task_completed(id)
	pump()
	local t = Hm.tm.task_info[id]
	local ok = t ~= nil and t.forced_status == "complete"
	if t then t.forced_status = nil end
	return ok
end

-- what the engine does for a finished task: finisher noted, then the task callback runs the stock on_complete
local function engine_completes(id, peer)
	Hm.env.coop_tasks.host_note(id, "finisher", peer)
	Hm.env.task_manager.task_callback({ get_id = function() return id end }, Hm.env.task.completed)
end

local function exists(M, id) return M.objects[id] ~= nil end
local function holder(M, id) local o = M.objects[id] return o and o._parent and o._parent._id end

-- ---------------------------------------------------------------- the delivery task, taken by the client
print("== delivery: the client takes the task, the host hands the parcel to the client's character")
tm_c:give_task(DT, 700)
pump()
check(Hm.tm.task_info[DT] ~= nil and Hm.env.coop_tasks.taker(DT) == 1, "the host gave the delivery, taker = the client")
local parcel = Hm.give_item(proxy, "quest_package_4") -- the stock status functor's alife_create_item, in the taker's character
Hm.env.save_var(Hm.actor, DT, { item_1_sec = "quest_package_4", item_1_id = parcel:id(), target_id = 800, task_giver_comm = "stalker" })
local alq = Hm.give_item(Hm.actor, "quest_package_4") -- the host carries another parcel of the same section (an A-Life Quests courier's)
Hm.tm.task_info[DT].stage = 1

print("== delivery: nobody of the group holds the parcel -> refused")
proxy._inv = {}
Hm.target._inv[#Hm.target._inv + 1] = parcel
parcel._parent = Hm.target
check(not client_turn_in(DT), "the parcel lies with an NPC: the host does not complete the task")
check(has_log(Hm, "cannot turn in '" .. DT .. "'"), "...and says why")

print("== delivery: the client only says he has it -> refused by the host's own view")
local fake = Cm.give_item(Cm.actor, "quest_package_4") -- the client's own machine shows a parcel; on the host his character has none
check(not client_turn_in(DT), "a client who claims the parcel: refused (the host looks at its own copy of his character)")
Cm.actor._inv, fake._parent = {}, nil

print("== delivery: the same ids, the client really holds it -> goes through")
Hm.target._inv = {}
proxy._inv[#proxy._inv + 1] = parcel
parcel._parent = proxy
check(client_turn_in(DT), "the parcel in the client's character on the host: the turn-in goes through")

print("== delivery: the host's other parcel holds the same section; only the task's parcel is taken")
Hm.on_complete[DT] = function() Hm.env.xr_effects.remove_delivery_item(Hm.actor, nil, { DT }) end
engine_completes(DT, 1)
check(not exists(Hm, parcel:id()), "the task's parcel is gone from the client's character")
check(exists(Hm, alq:id()) and holder(Hm, alq:id()) == 0, "the host's other quest_package_4 stays where it was")

print("== delivery: another player's parcel, the host holds none: taken from him")
Hm.tm.task_info[DT] = setmetatable({ id = DT, stage = 1, status_functor = "delivery_task" }, Hm.env.task_objects.CGeneralTask)
Hm.actor._inv = {}
local p2 = Hm.give_item(proxy, "quest_package_4")
Hm.env.save_var(Hm.actor, DT, { item_1_sec = "quest_package_4", item_1_id = p2:id(), target_id = 800 })
check(client_turn_in(DT), "the client holds the parcel, the host none: the turn-in goes through")
engine_completes(DT, 1)
check(not exists(Hm, p2:id()), "the parcel is taken from the client's character")

print("== delivery: the host turns in its own parcel: the stock does it")
Hm.tm.task_info[DT] = setmetatable({ id = DT, stage = 1, status_functor = "delivery_task" }, Hm.env.task_objects.CGeneralTask)
local p3 = Hm.give_item(Hm.actor, "quest_package_4")
Hm.env.save_var(Hm.actor, DT, { item_1_sec = "quest_package_4", item_1_id = p3:id(), target_id = 800 })
Hm.original_talker = Hm.target -- the host's own dialog with the receiver
engine_completes(DT, 0)
Hm.original_talker = nil
check(holder(Hm, p3:id()) == 800, "the host's own parcel goes to the receiver it talks to (stock)")

print("== delivery: no session: the stock alone")
Hm.tm.task_info[DT] = setmetatable({ id = DT, stage = 1, status_functor = "delivery_task" }, Hm.env.task_objects.CGeneralTask)
local p4 = Hm.give_item(proxy, "quest_package_4")
local own = Hm.give_item(Hm.actor, "quest_package_4")
Hm.env.save_var(Hm.actor, DT, { item_1_sec = "quest_package_4", item_1_id = p4:id(), target_id = 800 })
Hm.active = false
Hm.env.xr_effects.remove_delivery_item(Hm.actor, nil, { DT })
Hm.active = true
check(exists(Hm, p4:id()) and not exists(Hm, own:id()), "outside a session the stock takes the actor's item, untouched")

-- ---------------------------------------------------------------- fetch
print("== fetch: the host counts the group's items for a client's turn-in")
Hm.actor._inv, proxy._inv = {}, {}
tm_c:give_task(FT, 700)
pump()
check(Hm.tm.task_info[FT] ~= nil, "the host gave the fetch task")
Hm.env.save_var(Hm.actor, FT .. "_fetch", "medkit")
Hm.env.save_var(Hm.actor, FT .. "_fetch_count", 2)
Hm.give_item(proxy, "medkit")
check(not client_turn_in(FT), "one medkit of two: refused")
check(has_log(Hm, "cannot turn in '" .. FT .. "'"), "...and says why")
Hm.give_item(Hm.actor, "medkit")
check(client_turn_in(FT), "one with the client, one with the host: the group has two, goes through")
Hm.actor._inv = {}
Hm.give_item(proxy, "medkit")
check(client_turn_in(FT), "two with the client: goes through")

print("== a task with no item to hand over: unchanged")
tm_c:give_task("plain_t", 700)
pump()
check(client_turn_in("plain_t"), "a task without a hand-over is turned in as before")

-- ---------------------------------------------------------------- offers of a trader-class NPC
print("== Sidorovich (a trader, not a stalker class) gets the host's offer")
Cm.env.EVENTS.used_npc_id = 760
Cm.talk_npc = Cm.sid
Cm.log = {}
local offers0 = count_sent(Hm, "quests.offer")
fire(Cm, "GUI_on_show", "Dialog")
local req = last_sent(Cm, "quests.offer_req")
check(req ~= nil and req.n == 760, "the client asks the host for Sidorovich's offer")
pump()
check(count_sent(Hm, "quests.offer") == offers0 + 1 and not has_log(Cm, "host refused the offer"), "the host answers with his offer, no 'npc' refusal")
check(Hm.gen_speaker == Hm.sid, "the host generated it as if its actor talked to Sidorovich")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
