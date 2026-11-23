-- R32 W7 (temp\r30\design\R32-final.md W7.2, §5 Done = 17 {u32 origin, u32 op, str answer}), Server: the answer of a numbered
-- op goes with its effect and outlives the map server that ran it.
--   A map server: coop_ops_done.record -> coop_mode.op_done -> srv.journal_done(origin, seq, coop_main.encode(answer)): a Done
--   entry in its level journal (the engine binding, WP4/WP11 engine). Without the binding (this build) op_done answers false and
--   the ledger keeps the answer in this process only (a repeat to this map server still gets it).
--   The world server: its ledger is in its own save (m_data.coop_ops_done): op_done answers false and never calls the journal.
--   Both: the engine's coop_op_done(origin, seq, answer) (the world applying a Done entry; a starting map server reading the
--   world's records) puts the record into the ledger, so a retry of that op gets the recorded answer and runs nothing.
--   A player's machine records nothing.
-- Not shipped. Run: tools\test_lua.cmd srv_ops_done
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
make_actor(vec3(0, 0, 0))
start_all()
local F = load_script("coop_mode")
modes.live(F)
local ops = load_script("coop_ops_done")
ops.on_game_start()

local function process(t)
	coop.is_active = function() return t.active ~= false end
	coop.is_host = function() return t.host == true end
	coop.is_map_server = function() return t.map == true end
	coop.is_dedicated = function() return t.dedicated == true end
	coop.levels = { split = function() return t.split == true end, bridge_of_player = function() return 0x101 end }
end

print("== a map server")
process({ map = true })
SendScriptCallback("actor_on_update") -- when_srv runs once the srv layer answers
srv = nil
local op = { origin = 500, seq = 7 }
check(F.op_done(op, { ok = true, ["r.n"] = 3 }) == false, "without the engine's journal binding the answer is not recorded up")
local journal = {}
srv = { journal_done = function(origin, seq, text)
	journal[#journal + 1] = { origin = origin, seq = seq, text = text }
	return true
end }
check(F.op_done(op, { ok = true, ["r.n"] = 3 }) == true, "with it, the layer recorded the answer")
local row = journal[1]
local back = row and coop_main.decode(row.text)
check(#journal == 1 and row.origin == 500 and row.seq == 7 and back.ok == true and back["r.n"] == 3,
	"as a Done entry: the character, the sequence and the whole answer")
journal = {}
ops.record({ origin = 500, seq = 8 }, { ok = false, why = "busy" })
check(#journal == 1 and journal[1].seq == 8, "the ledger's first answer of an op goes up once")
ops.record({ origin = 500, seq = 8 }, { ok = true })
check(#journal == 1 and ops.get({ origin = 500, seq = 8 }).why == "busy", "a repeat goes up no more and keeps the first answer")
srv.journal_done = function() error("boom") end
check(F.op_done({ origin = 500, seq = 9 }, { ok = true }) == false, "a binding that raises: not recorded")

print("== the engine hands back a record (coop_op_done)")
SendScriptCallback("coop_op_done", 501, 40, coop_main.encode({ o = "1:0:40", ok = true, exchange = true }))
local got = ops.get({ origin = 501, seq = 40 })
check(got and got.ok == true and got.exchange == true and got.o == "1:0:40",
	"a record of another map server is in this ledger: a retry gets it and runs nothing")
SendScriptCallback("coop_op_done", 501, 40, coop_main.encode({ o = "1:0:40", ok = false }))
check(ops.get({ origin = 501, seq = 40 }).ok == true, "a record that comes again changes nothing: the first answer stands")
SendScriptCallback("coop_op_done", "x", 41, coop_main.encode({ ok = true }))
SendScriptCallback("coop_op_done", 501, 0, coop_main.encode({ ok = true }))
SendScriptCallback("coop_op_done", 501, 42, 5)
check(ops.get({ origin = 501, seq = 41 }) == nil and ops.get({ origin = 501, seq = 42 }) == nil,
	"a malformed record is ignored")

print("== the world server")
process({ dedicated = true, host = true }) -- the host of its session: host-domain callbacks (save_state) run here
journal = {}
srv = { journal_done = function(...) journal[#journal + 1] = { ... } return true end }
check(F.op_done({ origin = 500, seq = 50 }, { ok = true }) == false and #journal == 0,
	"the world server keeps the answer in its own save: no journal")
SendScriptCallback("coop_op_done", 502, 60, coop_main.encode({ q = 60, o = 1 }))
check(ops.get({ origin = 502, seq = 60 }) and ops.get({ origin = 502, seq = 60 }).o == 1,
	"the world applies a map server's Done: the record joins the world's ledger")
local saved = {}
SendScriptCallback("save_state", saved)
check(type(saved.coop_ops_done) == "table", "and goes into the world save (m_data.coop_ops_done) for the next map server")
-- Dev 58 Lua fix: a module that listens (Nimble's keeper) hears each record the world takes from a map server, once
local told = {}
ops.listen("test", function(op, answer) told[#told + 1] = { op = op, answer = answer } end)
SendScriptCallback("coop_op_done", 503, 90, coop_main.encode({ o = "1:0:90", ok = true }))
SendScriptCallback("coop_op_done", 503, 90, coop_main.encode({ o = "1:0:90", ok = false }))
check(#told == 1 and told[1].op.origin == 503 and told[1].op.seq == 90 and told[1].answer.o == "1:0:90"
	and told[1].answer.ok == true, "a record the world takes is told to the modules that listen, once, with its first answer")
SendScriptCallback("load_state", saved)
check(#told == 1, "a save's records are no news: loading them tells nobody")

print("== a server's player machine")
process({ split = true, host = false })
journal = {}
check(F.op_done({ origin = 500, seq = 70 }, { ok = true }) == false and #journal == 0, "a player's machine records nothing")

print("== the co-op host")
process({ host = true })
check(F.op_done({ origin = 0, seq = 80 }, { ok = true }) == false and #journal == 0,
	"the co-op host keeps the answer in the module's own save, no journal")

done("SRV_OPS_DONE")
