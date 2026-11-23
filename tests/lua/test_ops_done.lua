-- R32 W7, persistence, replay and layer reporting of numbered operations.
local modes = dofile("tests/lua/support/modes.lua")
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local name = modes.names()[1]
local mode = load_script("coop_mode")
local reported = {}
modes.install(mode, name, { op_done = function(op, answer)
	reported[#reported + 1] = { op = op, answer = answer }
	return true
end })
local ok, ops = pcall(load_script, "coop_ops_done")
check(ok, name .. ": the operation ledger loads")
if ok then
	ops.on_game_start()
	local op = { origin = 500, seq = 1 }
	ops.record(op, { ok = true, result = 19 })
	ops.record(op, { ok = false })
	check(ops.get(op).ok == true and ops.get(op).result == 19, "the first answer wins")
	check(ops.get({ origin = 501, seq = 1 }) == nil, "another character has its own sequence")
	check(name == "none" or (#reported == 1 and reported[1].op.origin == 500 and reported[1].op.seq == 1
		and reported[1].answer.result == 19), "the decider reports the first answer once")
	local saved = {}
	SendScriptCallback("save_state", saved)
	check(saved.coop_ops_done ~= nil, "the answer is saved under coop_ops_done")
	SendScriptCallback("load_state", {})
	check(ops.get(op) == nil, "a separate save clears the old ledger")
	SendScriptCallback("load_state", saved)
	check(ops.get(op).result == 19, "a reloaded save replays the recorded result")
	for seq = 2, 5000 do ops.record({ origin = 500, seq = seq }, { ok = true }) end
	local _, retired = ops.get(op)
	check(ops.get(op) == nil and retired == true, "bounded history cannot run an evicted operation again")
	check(ops.get({ origin = 500, seq = 5000 }).ok == true, "latest answer is retained")
	local bounded = {}
	SendScriptCallback("save_state", bounded)
	SendScriptCallback("load_state", bounded)
	local _, retired_after_load = ops.get(op)
	check(retired_after_load and ops.get({ origin = 500, seq = 5000 }).ok,
		"the retention boundary and the exact recent answer survive a reload")
end
done("ops_done@" .. name)
