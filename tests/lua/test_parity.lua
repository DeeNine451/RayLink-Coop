-- Anomaly Coop parity probe (scripts\coop_parity.script): the digest, the rows of a dump, a failing engine call, the host's
-- broadcast and a client's dump on it. tests\tools\test_parity_diff.py pins the other half of the format.
-- Run: tools\test_lua.cmd parity
dofile("tests/lua/support/harness_quests.lua")

local PROXY = 500 -- the client's character on the host; on the client ids 0 and 500 are swapped

-- ------------------------------------------------------------------ the world of a machine
local function to_local(M, hid)
	if not M.swapped then return hid end
	return hid == 0 and PROXY or (hid == PROXY and 0 or hid)
end

local function own_section(M, hid, sec)
	if not M.swapped then return sec end
	return hid == 0 and "coop_player_avatar" or (hid == PROXY and "actor" or sec)
end

-- One entity, given in host numbering. o: parent (host id), online, creature, dead, health, pos, cond, ammo, mag, uses
local function entity(M, hid, sec, o)
	o = o or {}
	local lid = to_local(M, hid)
	local pos = o.pos or vec(hid, 0, 0)
	sec = own_section(M, hid, sec)
	local se = {
		id = lid, parent_id = o.parent and to_local(M, o.parent) or 65535, position = pos, online = o.online == true,
		_cls = o.creature and "creature" or "item",
	}
	function se:section_name() return sec end
	function se:clsid() return self._cls end
	function se:alive() return o.dead ~= true end
	M.se[lid] = se
	if o.online then
		local obj = lid == 0 and M.actor or M.new_obj(lid, sec, pos)
		obj._sec, obj._pos, obj._dead, obj._cond, obj._ammo, obj._mag, obj._uses = sec, pos, o.dead, o.cond, o.ammo, o.mag, o.uses or 0
		obj.health = o.health or 1
	end
end

local function build_world(M)
	entity(M, 0, "actor", { online = true, creature = true, pos = vec(1.234, 2, 3) })
	entity(M, PROXY, "coop_player_avatar", { online = true, creature = true, pos = vec(4, 5, 6) })
	entity(M, 700, "stalker_a", { online = true, creature = true, health = 0.734 })
	entity(M, 701, "stalker_b", { creature = true, dead = true })
	entity(M, 800, "wpn_ak74", { online = true, parent = 700, cond = 0.951, mag = 30 })
	entity(M, 801, "ammo_9x18", { online = true, parent = 0, cond = 1, ammo = 20 })
	entity(M, 802, "bandage", { online = true, parent = PROXY, cond = 1, uses = 2 })
	entity(M, 803, "wpn_pm", { parent = 701 })
	entity(M, 804, "wpn_abakan", { parent = 701 })
	entity(M, 900, "physic_object", { pos = vec(9, 9, 9) })
end

local function setup(M, opts)
	opts = opts or {}
	local e = M.env
	M.swapped = opts.swapped == true
	M.se, M.files, M.infos_list = {}, {}, { "story_a", "ui_pda", "ui_talk_x", "inventory_wnd_open", "story_b" }
	M.ObjMT.is_ammo = function(self) return self._ammo ~= nil end
	M.ObjMT.is_weapon = function(self) return self._mag ~= nil end
	M.ObjMT.ammo_get_count = function(self) return self._ammo end
	M.ObjMT.get_ammo_in_magazine = function(self) return self._mag end
	M.ObjMT.money = function(self) return self._money or 0 end
	e.coop.to_host_id = function(id) return to_local(M, id) end -- the swap is symmetric
	e.coop.to_local_id = e.coop.to_host_id
	e.coop.money_of = function(peer) return ({ [0] = 1000, [1] = 2500 })[peer] end
	M.actor._money = opts.money or 1000
	e.alife_object = function(id) return M.se[id] end
	local sim = {}
	function sim:iterate_info(id, f) for _, info in ipairs(M.infos_list) do f(id, info) end end
	e.alife = function() return sim end
	e.IsStalker = function(_, cls) return cls == "creature" end
	e.IsMonster = function() return false end
	e.level.get_time_factor = function() return 12.5 end
	e.level.get_weather = function() return "w_rain1" end
	e.level.is_wfx_playing = function() return false end
	e.weather = { get_value_string = function(name) return "tex_" .. name end }
	e.device = function() return { is_paused = function() return false end } end
	-- 2012-05-01 10:30:15 + a client's lag
	e.game.get_game_time = function() return { get = function() return 2012, 5, 1, 10, 30, 15 + (M.clock_lag or 0), 0 end } end
	M.tasks_ini = { "task_a", "task_b", "task_never_given" }
	e.task_manager.task_ini.section_for_each = function(_, f) for _, id in ipairs(M.tasks_ini) do f(id) end end
	M.engine_tasks.task_a = { state = "in" }
	M.engine_tasks.task_b = { state = "done" }
	e.getFS = function() return { update_path = function(_, root, name) return root .. "\\" .. name end } end
	e.io = {
		open = function(path, mode)
			if M.deny_open then return nil, "denied" end
			local parts = {}
			return {
				write = function(self, ...) for _, s in ipairs({ ... }) do parts[#parts + 1] = s end return self end,
				close = function() M.files[path] = table.concat(parts) end,
			}
		end,
	}
	build_world(M)
end

local function boot(M)
	local mod = load_script(M, "coop_parity")
	mod.on_game_start()
	return mod
end

-- ------------------------------------------------------------------ reading a dump
local function lines_of(text)
	local out = {}
	for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
	return out
end

-- kind -> { rows = { line, ... }, digest = hex, count = n, by = { key -> "fields" } }
local function parse(text)
	local kinds = {}
	for _, line in ipairs(lines_of(text)) do
		local kind, key, rest = line:match("^([^\t]+)\t([^\t]+)\t?(.*)$")
		local k = kinds[kind] or { rows = {}, by = {} }
		kinds[kind] = k
		if key == "DIGEST" then
			k.digest, k.count = rest:match("^(%x+)\t(%d+)$")
		else
			k.rows[#k.rows + 1] = line
			k.by[key] = rest
		end
	end
	return kinds
end

local function has_error_row(kind)
	for key in pairs(kind.by) do
		if key:find("!error", 1, true) == 1 then return true end
	end
	return false
end

print("== digest")
do
	local M = machine("host", 0)
	M.players = { { id = 0, is_self = true, avatar_id = 0 } }
	setup(M)
	local mod = boot(M)
	check(bit.tohex(mod.fnv1a("")) == "811c9dc5", "FNV-1a 32 of nothing is the offset basis")
	check(bit.tohex(mod.fnv1a("a")) == "e40c292c", "FNV-1a 32 test vector 'a'")
	check(bit.tohex(mod.fnv1a("foobar")) == "bf9cf968", "FNV-1a 32 test vector 'foobar'")
	local a = mod.digest({ "x\t1\ta", "x\t2\tb", "x\t3\tc" })
	check(a == mod.digest({ "x\t3\tc", "x\t1\ta", "x\t2\tb" }), "the digest does not depend on the order of the rows")
	check(a == mod.digest({ "x\t1\ta", "x\t2\tb", "x\t3\tc" }), "the digest is deterministic")
	check(a ~= mod.digest({ "x\t1\ta", "x\t2\tb", "x\t3\td" }), "one changed row changes the digest")
	check(a ~= mod.digest({ "x\t1\ta", "x\t2\tb" }), "a missing row changes the digest")
	check(mod.digest({ "objects\t00001\tx" }) == "eb67192a", "pinned against tools\\parity_diff.py (test_parity_diff.py)")
	local unsorted = { "b", "a" }
	mod.digest(unsorted)
	check(unsorted[1] == "b", "the digest leaves the caller's table alone")
end

MACHINES, QUEUE = {}, {}

print("== no session")
do
	local M = machine("host", 0)
	M.players = {}
	setup(M)
	local mod = boot(M)
	M.active = false
	mod.command("x")
	check(next(M.files) == nil and #M.sent == 0, "outside a session the command does nothing")
	M.handlers["parity.dump"]("", 0, "parity.dump")
	check(next(M.files) == nil, "outside a session the event does nothing")

	local N = machine("host", 0)
	setup(N)
	N.env.coop = nil
	local ok, err = pcall(function() load_script(N, "coop_parity").on_game_start() end)
	check(ok, "on an exe without co-op on_game_start does nothing: " .. tostring(err))
	check(N.handlers["parity.dump"] == nil, "and no handler is registered")

	local P = machine("host", 0)
	setup(P)
	P.env.coop_main = nil
	ok, err = pcall(function() load_script(P, "coop_parity").on_game_start() end)
	check(ok, "on_game_start never throws, coop_main missing or not: " .. tostring(err))
end

MACHINES, QUEUE = {}, {}

print("== the host asks, every machine dumps")
local Hm = machine("host", 0)
local Cm = machine("client", 1)
local Hmod, Cmod
do
	setup(Hm)
	setup(Cm, { swapped = true, money = 2500 })
	Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = PROXY } }
	Cm.players = { { id = 1, is_self = true, avatar_id = 0 }, { id = 0, is_self = false, avatar_id = PROXY } }
	Cm.clock_lag = 2
	Hmod, Cmod = boot(Hm), boot(Cm)
	Hmod.command("t1")
	check(count_sent(Hm, "parity.dump") == 1, "the host broadcasts one event")
	check(Hm.sent[1].target == nil or Hm.sent[1].target == -1, "to every other player")
	local ev = last_sent(Hm, "parity.dump")
	check(ev.tag == "t1", "the event carries the tag")
	check(type(ev.t) == "number" and ev.t > 6e10, "and the host's raw game time in seconds: " .. tostring(ev.t))
	check(Hm.files["$logs$\\coop_parity_t1_host.tsv"] ~= nil, "the host wrote its file")
	check(next(Cm.files) == nil, "the client waits for the event")
	pump()
	check(Cm.files["$logs$\\coop_parity_t1_client1.tsv"] ~= nil, "the client dumped when it arrived")
	check(has_log(Hm, "coop_parity_t1_host.tsv"), "the log names the file")
end

local host = parse(Hm.files["$logs$\\coop_parity_t1_host.tsv"])
local client = parse(Cm.files["$logs$\\coop_parity_t1_client1.tsv"])

print("== rows")
do
	for _, kind in ipairs({ "meta", "players", "objects", "positions", "health", "sections", "inventories", "money", "time",
		"weather", "tasks", "infos" }) do
		check(host[kind] ~= nil and host[kind].digest ~= nil, kind .. " is there and ends with a DIGEST row")
		check(host[kind] ~= nil and tonumber(host[kind].count) == #host[kind].rows, kind .. ": DIGEST counts its rows")
		check(host[kind] ~= nil and Hmod.digest(host[kind].rows) == host[kind].digest, kind .. ": DIGEST is over its rows")
		check(host[kind] ~= nil and not has_error_row(host[kind]), kind .. ": no error row")
	end
	local text = Hm.files["$logs$\\coop_parity_t1_host.tsv"]
	check(text:sub(-1) == "\n" and not text:find("\r", 1, true), "LF line ends, a final newline")
	local rows = host.objects.rows
	local sorted = {}
	for i, r in ipairs(rows) do sorted[i] = r end
	table.sort(sorted)
	check(table.concat(sorted, "|") == table.concat(rows, "|"), "rows are sorted")

	check(host.meta.by.role == "host" and client.meta.by.role == "client", "meta: the role")
	check(host.meta.by.tag == "t1" and client.meta.by.tag == "t1", "meta: the tag")
	check(host.meta.by.self_id == "00000" and client.meta.by.self_id == "00500", "meta: this machine's character in host numbering")
	check(client.meta.by.host_game_s == host.meta.by.host_game_s, "meta: the host's game time reached the client")
	check(host.players.by["1"] == "00500" and client.players.by["1"] == "00500", "players: the client's character")
	check(host.players.by["0"] == "00000" and client.players.by["0"] == "00000", "players: the host's character")

	check(host.objects.by["00700"] == "stalker_a\t65535\t1\t1\t1", "objects: section, parent, online, game object, alive")
	check(host.objects.by["00701"] == "stalker_b\t65535\t0\t0\t0", "objects: an offline dead creature")
	check(host.objects.by["00800"] == "wpn_ak74\t00700\t1\t1\t-", "objects: an item has no alive flag")
	check(host.objects.by["00000"] == "@player\t65535\t1\t1\t1", "objects: the host's actor is a player")
	check(client.objects.by["00000"] == "@player\t65535\t1\t1\t1", "objects: the host's avatar on the client too")
	check(host.objects.by["00500"] == client.objects.by["00500"], "objects: the client's proxy equals the client's actor")
	check(host.objects.by["00801"] == "ammo_9x18\t00000\t1\t1\t-", "objects: parents in host numbering, host")
	check(client.objects.by["00801"] == "ammo_9x18\t00000\t1\t1\t-", "objects: parents in host numbering, client")

	check(host.positions.by["00000"] == "1.23\t2.00\t3.00\t1", "positions: online, %.2f")
	check(host.positions.by["00900"] == "9.00\t9.00\t9.00\t0", "positions: offline, from the server entity")
	check(host.positions.by["00800"] == nil, "positions: a carried item is its owner's")
	check(host.health.by["00700"] == "0.73", "health: online creatures")
	check(host.health.by["00701"] == nil, "health: not offline ones")
	check(host.health.by["00800"] == nil, "health: not items")
	check(host.sections.by.actor == "1" and client.sections.by.actor == "1", "sections: entities per section")

	check(host.inventories.by["00000"] == "00801:ammo_9x18:1.00:20:0", "inventories: id:section:cond:ammo:uses")
	check(host.inventories.by["00700"] == "00800:wpn_ak74:0.95:30:0", "inventories: a weapon's magazine")
	check(host.inventories.by["00500"] == "00802:bandage:1.00:-:2", "inventories: uses")
	check(client.inventories.by["00500"] == "00802:bandage:1.00:-:2", "inventories: the client's own, in host numbering")
	check(host.inventories.by["00701"] == "00803:wpn_pm:-:-:-\t00804:wpn_abakan:-:-:-", "inventories: an offline owner, sorted by id")

	check(host.money.by["0"] == "1000" and host.money.by["1"] == "2500", "money: the host has every player's")
	check(client.money.by["1"] == "2500" and client.money.by["0"] == nil, "money: a client has its own")

	check(host.time.by.factor == "12.50" and host.time.by.pause == "0", "time: factor and pause")
	check(tonumber(client.time.by.game_s) - tonumber(host.time.by.game_s) == 2, "time: raw seconds, exact")
	check(host.weather.by.cycle == "w_rain1" and host.weather.by.fx == "0", "weather: cycle and fx")
	check(host.weather.by.sky == "tex_sky_texture", "weather: the env")
	check(host.tasks.by.task_a == "in_progress" and host.tasks.by.task_b == "done", "tasks: id and state")
	check(host.tasks.by.task_never_given == nil, "tasks: only what the engine holds")
	check(host.infos.by.story_a == "1" and host.infos.by.story_b == "1", "infos: the actor's")
	check(host.infos.by.ui_pda == nil and host.infos.by.ui_talk_x == nil and host.infos.by.inventory_wnd_open == nil,
		"infos: machine infos are nobody's story")

	-- a mirrored world: the digests alone tell
	for _, kind in ipairs({ "players", "objects", "positions", "health", "sections", "inventories", "weather", "tasks", "infos" }) do
		check(host[kind].digest == client[kind].digest, kind .. ": equal worlds, equal digests")
	end
	check(host.meta.digest ~= client.meta.digest, "meta is this machine's: its digest differs")
end

print("== the event")
do
	Cm.files = {}
	Cm.handlers["parity.dump"](H.encode({ tag = "bad", t = 1 }), 2, "parity.dump")
	check(next(Cm.files) == nil, "a client ignores a dump order from another client")
	Hm.files = {}
	Hm.handlers["parity.dump"](H.encode({ tag = "bad", t = 1 }), 0, "parity.dump")
	check(next(Hm.files) == nil, "the host never dumps on the event")

	Hm.sent = {}
	Cmod.command("cl")
	check(#Cm.sent == 0 and next(Cm.files) == nil, "the command on a client refuses: half a pair proves nothing")
	check(has_log(Cm, "host only"), "and says so")

	Hmod.command("..\\..\\evil/name tag")
	local path = next(Hm.files)
	check(path == "$logs$\\coop_parity_______evil_name_tag_host.tsv", "a tag cannot leave the logs folder: " .. tostring(path))
	pump()
	path = next(Cm.files)
	check(path == "$logs$\\coop_parity_______evil_name_tag_client1.tsv", "the same tag on the client: " .. tostring(path))

	Hm.files, Cm.files = {}, {}
	Cm.handlers["parity.dump"](H.encode({ tag = "..\\up", t = 1 }), 0, "parity.dump")
	check(next(Cm.files) == "$logs$\\coop_parity____up_client1.tsv", "a client cleans the tag it received")

	Hm.files, Cm.files, Hm.sent = {}, {}, {}
	Hmod.command("")
	local ev = last_sent(Hm, "parity.dump")
	check(ev.tag:match("^t%d+$") ~= nil, "no tag: the host's game time is the tag: " .. tostring(ev.tag))
	pump()
	check(Hm.files["$logs$\\coop_parity_" .. ev.tag .. "_host.tsv"] ~= nil, "host's file under it")
	check(Cm.files["$logs$\\coop_parity_" .. ev.tag .. "_client1.tsv"] ~= nil, "client's file under it")

	Hm.files = {}
	local long = string.rep("x", 200)
	Hmod.command(long)
	path = next(Hm.files)
	check(#path < 100, "a long tag is cut")
	pump()
end

print("== a failing engine call")
do
	local function dump_with(M, mod)
		M.files = {}
		mod.dump("f", 1)
		return parse(M.files["$logs$\\coop_parity_f_host.tsv"])
	end
	Hm.env.level.get_time_factor = function() error("no time factor") end
	local d = dump_with(Hm, Hmod)
	check(has_error_row(d.time), "time: an error row")
	check(d.time.by.game_s ~= nil and d.time.by.pause ~= nil, "time: the other rows are there")
	check(d.weather ~= nil and not has_error_row(d.weather), "the next section did not notice")
	check(d.infos ~= nil and d.infos.digest ~= nil, "the dump reached the last section")
	Hm.env.level.get_time_factor = function() return 12.5 end

	Hm.env.level.get_weather = function() error("no env") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.weather) and d.weather.by.fx == "0", "weather: one row failed, the rest stayed")
	Hm.env.level.get_weather = function() return "w_rain1" end

	Hm.env.alife = function() error("no simulator") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.infos), "infos: an error row")
	check(d.tasks ~= nil and not has_error_row(d.tasks), "the rest is whole")
	local sim = {}
	function sim:iterate_info(id, f) for _, info in ipairs(Hm.infos_list) do f(id, info) end end
	Hm.env.alife = function() return sim end

	local good = Hm.env.alife_object
	Hm.env.alife_object = function(id)
		if id == 701 then error("bad entity") end
		return good(id)
	end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.objects), "objects: a failed entity is an error row")
	check(d.objects.by["00700"] ~= nil and d.objects.by["00701"] == nil, "objects: the others are there")
	Hm.env.alife_object = function() error("no simulator") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.objects) and has_error_row(d.positions) and has_error_row(d.inventories),
		"every section over the entities says so")
	local n = 0
	for _ in pairs(d.objects.by) do n = n + 1 end
	check(n <= 2, "without a row per id: " .. n)
	check(d.time ~= nil and not has_error_row(d.time), "the time section still works")
	Hm.env.alife_object = good

	local o = Hm.objects[700]
	o.position = function() error("no position") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.positions), "positions: one failed object")
	check(d.positions.by["00900"] ~= nil and d.positions.by["00700"] == nil, "positions: only that row is gone")
	o.position = nil

	local item = Hm.objects[800]
	item.condition = function() error("no condition") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.inventories), "inventories: one failed item")
	check(d.inventories.by["00700"] == "00800:wpn_ak74:!:!:!", "inventories: the item stays visible")
	check(d.inventories.by["00000"] ~= nil, "inventories: the others are there")
	item.condition = nil

	local saved = Hm.env.coop.players
	Hm.env.coop.players = function() error("no list") end
	d = dump_with(Hm, Hmod)
	check(has_error_row(d.players), "players: an error row")
	check(d.objects.by["00700"] ~= nil, "objects go on without the list")
	Hm.env.coop.players = saved

	Hm.deny_open = true
	Hm.files = {}
	local ok, r = pcall(Hmod.dump, "f", 1)
	check(ok and r == nil, "a file that cannot be written is a log line")
	check(has_log(Hm, "cannot write"), "the log says so")
	Hm.deny_open = false

	-- more failures than a section keeps
	local many = Hm.env.level.object_by_id
	for id = 1000, 1100 do
		entity(Hm, id, "broken", { online = true, pos = vec(0, 0, 0) })
		Hm.objects[id].position = function() error("broken") end
	end
	d = dump_with(Hm, Hmod)
	n = 0
	for key in pairs(d.positions.by) do
		if key:find("!error", 1, true) == 1 then n = n + 1 end
	end
	check(n > 0 and n <= 20, "error rows are bounded: " .. n)
	check(d.positions.by["!errors"] == "101", "and the total is a row: " .. tostring(d.positions.by["!errors"]))
	Hm.env.level.object_by_id = many
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
