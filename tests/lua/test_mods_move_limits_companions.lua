-- F4 G6-2 (m13:2): GAMMA UI designs the single-item check around weight already assigned to the companion.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

start_all()
local limits = load_script("coop_mods_move_limits")
local trust = load_script("coop_trust")
local module = "coop_mods_move_limits_companions"

EDDListType = { iActorBag = 1, iDeadBodyBag = 2 }
AddScriptCallback("npc_on_item_take")

-- The server object moves before the game inventory does. Use the latter for parent() and iterate_inventory().
local actor = make_actor()
local GO = getmetatable(actor)
function GO:weight() return self._weight end
function GO:parent() return OBJ[self._game_parent] end
function GO:iterate_inventory(f, owner)
	for _, obj in pairs(OBJ) do
		if obj._game_parent == self:id() then f(owner, obj) end
	end
end

local companions = {}
function se_load_var(id, _, key) return key == "companion" and companions[id] end

-- GAMMA UI's assignment table and window contract (axr_companions.script:1400-1488).
local assigned = {}
local mod = { Enabled = true }
function mod.is_assigned_item(npc_id, item_id)
	return assigned[npc_id] and assigned[npc_id][item_id]
end
function mod.OnItemAfterMove(npc_id, obj, mode, bag)
	if mode ~= "loot" or not se_load_var(npc_id, nil, "companion") then return end
	assigned[npc_id] = assigned[npc_id] or {}
	assigned[npc_id][obj:id()] = bag == EDDListType.iActorBag and true or nil
end
function mod.OnItemBeforeMove(flags, npc_id, _, mode, bag)
	if mode ~= "loot" or bag ~= EDDListType.iActorBag or not se_load_var(npc_id, nil, "companion") then return end
	local weight = 0
	for id in pairs(assigned[npc_id] or {}) do
		local obj = level.object_by_id(id)
		if obj then weight = weight + obj:weight() end
	end
	if weight > 30 then flags.ret_value = false end
end

local function npc(is_companion, offline)
	local se = spawn("stalker", nil, nil, { kind = "stalker", offline = offline })
	companions[se.id] = is_companion
	return se.id
end

local function item(weight, owner)
	local _, obj = spawn("part", nil, owner)
	obj._weight, obj._game_parent = weight, owner
	return obj
end

local function assign(npc_id, obj)
	mod.OnItemAfterMove(npc_id, obj, "loot", EDDListType.iActorBag)
end

-- Model the G6-1 engine's admission and next-frame inventory update. The reports from the UI can arrive later.
local held = {}
local function ask(npc_id, obj)
	local count, weight = 0, 0
	for _, pending in ipairs(held[npc_id] or {}) do
		count, weight = count + 1, weight + pending:weight()
	end
	return limits.admit(npc_id, obj:id(), count, weight, SE[obj:id()].parent_id)
end

local function give(npc_id, obj)
	local verdict = ask(npc_id, obj)
	if verdict ~= false then SE[obj:id()].parent_id = npc_id end
	if verdict == true then
		held[npc_id] = held[npc_id] or {}
		table.insert(held[npc_id], obj)
	end
	return verdict
end

local function land(npc_id, obj)
	obj._game_parent = npc_id
	SendScriptCallback("npc_on_item_take", OBJ[npc_id], obj)
	for i, pending in ipairs(held[npc_id] or {}) do
		if pending == obj then table.remove(held[npc_id], i) break end
	end
end

axr_companions = mod
-- axr_main discovers on_game_start. With the adapter absent, exercise the same registration path as a no-op for TDD.
local adapter = _G[module]
if adapter then adapter.on_game_start() end

local function remote_gifts(label, player)
	trust.reset_for_test({ default = "refuse" })
	local receiver = npc(true)
	local old = item(29, receiver)
	assign(receiver, old)
	item(20, receiver) -- the companion's own equipment does not use the assigned allowance
	local first, next_item = item(2, player), item(1, player)
	check(give(receiver, first) == true, label .. ": single gift at 29 kg is admitted and reserved")
	check(give(receiver, next_item) == false and SE[next_item:id()].parent_id == player,
		label .. ": the next gift is refused while 2 kg is pending")
	land(receiver, first)
	check(mod.is_assigned_item(receiver, first:id()) == true,
		label .. ": the landed gift is assigned without waiting for a UI message")
	check(give(receiver, next_item) == false, label .. ": settled weight still refuses the next gift")
	SE[old:id()].parent_id, old._game_parent = player, player
	check(give(receiver, next_item) == true, label .. ": taking assigned weight back reopens admission before the UI update")
end

modes.each(coop_mode, function(set)
	if set == "hostplay" then
		remote_gifts(set, PROXY)
		local marked_early = npc(true)
		assign(marked_early, item(12, marked_early))
		local early = item(10, actor:id())
		check(give(marked_early, early) == true, set .. ": the host's first gift at 12 kg is admitted")
		assign(marked_early, early) -- the host UI can mark the gift before the inventory update
		check(give(marked_early, item(1, actor:id())) == true, set .. ": the pending gift is counted once")
		local receiver = npc(true)
		assign(receiver, item(30, receiver))
		check(give(receiver, item(1, actor:id())) == true, set .. ": the host can give at exactly 30 kg")
		trust.reset_for_test({ default = "log" })
		check(give(receiver, item(1, actor:id())) == false, set .. ": the host's own next gift obeys the limit")
		check(give(receiver, item(1, PROXY)) == true, set .. ": the client's over-limit gift passes in trust log mode")
		local trusts = coop_trust.status().companion_assigned_weight
		check(trusts and trusts.failed == 1 and trusts.refused == 0, set .. ": trust logs the client verdict")
	elseif set == "srv_map" then
		remote_gifts(set, PROXY)
		local receiver = npc(true)
		assign(receiver, item(31, receiver))
		check(ask(receiver, item(1, actor:id())) == nil, set .. ": the ghost actor is not a giving player")
		check(ask(receiver, item(1, npc(false))) == nil, set .. ": non-player transfers do not use the allowance")
		check(ask(npc(false), item(1, PROXY)) == nil, set .. ": regular NPCs do not use the allowance")
		check(ask(npc(true, true), item(1, PROXY)) == nil, set .. ": a companion on another map is not judged here")
		local other = npc(true)
		local failed = item(32, PROXY)
		check(ask(other, failed) == true, set .. ": a rule can admit a move before an engine refusal")
		check(not mod.is_assigned_item(other, failed:id()), set .. ": a move the engine never lands is not assigned")
		check(give(other, item(1, PROXY)) == true, set .. ": a rejected engine move leaves no weight behind")
	elseif set == "srv_world" then
		local receiver = npc(true, true)
		check(ask(receiver, item(1, PROXY)) == nil, set .. ": the world server has no companion inventory to judge")
	else -- no session: reproduce the stock window calculation
		MODE = "sp"
		local receiver = npc(true)
		local gift = item(1, actor:id())
		local weight = item(30, receiver)
		assign(receiver, weight)
		local flags = { ret_value = true }
		mod.OnItemBeforeMove(flags, receiver, gift, "loot", EDDListType.iActorBag)
		check(flags.ret_value, set .. ": the stock window allows a gift at 30 kg")
		weight._weight = 31
		mod.OnItemBeforeMove(flags, receiver, gift, "loot", EDDListType.iActorBag)
		check(not flags.ret_value, set .. ": the stock window stops the next gift above 30 kg")
		check(ask(receiver, gift) == nil, set .. ": the co-op rule does not decide a single-player move")
	end
end)

done("mods_move_limits_companions")
