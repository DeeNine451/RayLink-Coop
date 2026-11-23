-- R32 W7.2, §8a A21 E-1 (WP11 Server): the round trip of a numbered op's answer across map servers of one level.
--   Map server 1 (srv_map) runs the op: coop_ops_done.record -> coop_mode.op_done -> srv.journal_done(origin, seq, answer): a Done
--     entry of its journal batch (the engine's binding, srv/coop_srv_script.cpp; here a stand-in with its contract: true, the entry
--     kept in the frame's batch).
--   The world (srv_world) applies the batch: its receiver keeps the record of the level and raises coop_op_done(origin, seq, answer)
--     for a new record (srv/coop_levels_xfer.cpp host_take_done): the world's ledger takes it and saves it (m_data.coop_ops_done).
--   Map server 2 of that level (srv_map), served a held save older than the record: the engine raises coop_op_done for every record
--     of its level in its snapshot before it serves anybody (client_replay_done): the retry gets the recorded answer, the effect does
--     not run again and the record goes up no more. Served a fresh save instead: the ledger has it from m_data, the replay is no news.
--   Coop (hostplay): none of it runs: nobody declares or takes coop_op_done, op_done records nothing up, the ledger keeps the answer.
-- The engine's own rules (bounded store, first answer stands, the snapshot) are tests/test_srv_ops_done_e1.cpp.
-- The engine here is stand-ins with its contract: this file pins the Lua side and passes the same with or without the engine's code.
-- The engine's load of the save, the world server's adoption and a map server's replay are pinned by tests/test_srv_ops_done_e1.cpp
-- (journal::done::loads_records and Loaded, and the glue around them; FE1).
-- Not shipped. Run: tools\test_lua.cmd srv_ops_replay
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
modes.live(F)
local ops = load_script("coop_ops_done")
ops.on_game_start()

local CORDON = 1

local function process(t)
	coop.is_active = function() return t.active ~= false end
	coop.is_host = function() return t.host == true end
	coop.is_map_server = function() return t.map == true end
	coop.is_dedicated = function() return t.dedicated == true end
	coop.levels = { split = function() return t.split == true end, bridge_of_player = function() return 0x101 end }
	SendScriptCallback("actor_on_update") -- when_srv runs once the srv layer answers
end

-- the engine's stand-ins, with the contract of the C++ (srv.journal_done; the world's receiver; the replay of a snapshot)
local batch = {}
local journal_calls = 0
local function journal_done(origin, seq, text)
	journal_calls = journal_calls + 1
	batch[#batch + 1] = { origin = origin, seq = seq, text = text }
	return true
end
local world = { order = {}, by = {} } -- the records of the Cordon on the world, in the order kept
local function world_applies(entries)
	for _, e in ipairs(entries) do
		local k = e.origin .. ":" .. e.seq
		if world.by[k] == nil then -- the first answer stands; a new record goes to Lua once
			world.by[k] = e.text
			world.order[#world.order + 1] = e
			SendScriptCallback("coop_op_done", e.origin, e.seq, e.text)
		end
	end
end
local function snapshot_replay()
	for _, e in ipairs(world.order) do SendScriptCallback("coop_op_done", e.origin, e.seq, e.text) end
end

-- an executor of a numbered op that pays: the ledger answers a retry, the effect runs once
local runs = 0
local function pay(op)
	local known, too_old = ops.get(op)
	if known then return known end
	if too_old then return nil end
	runs = runs + 1
	return ops.record(op, { ok = true, o = "1:0:" .. op.seq, ["r.n"] = 3 })
end

print("== Coop (hostplay): none of it runs")
process({ host = true })
srv = { journal_done = journal_done }
check(axr_main.count("coop_op_done") == 0, "nobody declares or takes coop_op_done in a co-op process")
local coop_op = { origin = 0, seq = 9001 }
check(pay(coop_op).ok == true and runs == 1, "the co-op host runs the op")
check(pay(coop_op).ok == true and runs == 1, "a retry gets the host's own recorded answer")
check(journal_calls == 0 and #batch == 0, "and nothing is journaled: the host's module save keeps it")
check(F.op_done(coop_op, { ok = true }) == false, "op_done answers false in a co-op process")

print("== map server 1 of the Cordon runs the op")
process({ map = true })
check(axr_main.count("coop_op_done") >= 1, "the server's layer takes coop_op_done once it answers")
SendScriptCallback("load_state", {}) -- its world: a save without the record
runs = 0
local op = { origin = 500, seq = 7001 }
local first = pay(op)
check(first and first.ok == true and runs == 1, "the op runs once")
check(#batch == 1 and batch[1].origin == 500 and batch[1].seq == 7001, "its answer goes up as a Done entry with the op's number")
local sent = batch[1] and coop_main.decode(batch[1].text)
check(sent and sent.ok == true and sent.o == "1:0:7001" and sent["r.n"] == 3, "with the whole answer")
check(pay(op).ok == true and runs == 1 and #batch == 1, "a retry on the same map server: the recorded answer, nothing new up")

print("== the world applies the batch")
process({ dedicated = true, host = true })
SendScriptCallback("load_state", {}) -- the world's own ledger
local held = {}
SendScriptCallback("save_state", held) -- the save a player's join held before the record came
world_applies(batch)
local kept = ops.get(op)
check(kept and kept.ok == true and kept.o == "1:0:7001", "the world's ledger takes the record (coop_op_done)")
SendScriptCallback("coop_op_done", 500, 7001, coop_main.encode({ ok = false }))
check(ops.get(op).ok == true, "an answer of the op that comes again changes nothing: the first stands")
local fresh = {}
SendScriptCallback("save_state", fresh)
local in_save = false
for _, row in ipairs(type(fresh.coop_ops_done) == "table" and fresh.coop_ops_done.rows or {}) do
	if row.op.origin == 500 and row.op.seq == 7001 then in_save = true end
end
check(in_save, "and its save has it (m_data.coop_ops_done): a fresh save carries it to the next map server")

print("== map server 2 of the Cordon, served the held save")
process({ map = true })
SendScriptCallback("load_state", held)
check(ops.get(op) == nil, "the held save is older than the record: without the snapshot's records a retry would run the op again")
local told = {}
ops.listen("replay_test", function(o, answer) told[#told + 1] = { op = o, answer = answer } end)
batch, journal_calls = {}, 0
snapshot_replay() -- before it serves anybody
check(#told == 1 and told[1].op.origin == 500 and told[1].op.seq == 7001 and told[1].answer.ok == true,
	"each record of its level reaches the ledger and its listeners once")
local again = pay(op)
check(again and again.ok == true and again.o == "1:0:7001" and runs == 1, "the retry gets the recorded answer: the op ran once in all")
check(journal_calls == 0 and #batch == 0, "a record handed over goes up no more")

print("== map server 2 of the Cordon, served a fresh save")
process({ map = true })
SendScriptCallback("load_state", fresh)
told = {}
check(ops.get(op) and ops.get(op).ok == true, "the fresh save's ledger has the record already")
snapshot_replay()
check(#told == 0, "the replay of a record the ledger loaded is no news")
check(pay(op).ok == true and runs == 1 and #batch == 0, "the retry runs nothing")

done("SRV_OPS_REPLAY")
