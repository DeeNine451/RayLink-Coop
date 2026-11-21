-- WPO requests and strip refusals. The map authority rolls once from its own
-- object. The real GAMMA evaluation and rendering run in mods_wpo_window_fixture.
local which = ...
MODE = which == "host" and "host" or "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== WPO roll (" .. which .. ")")
make_actor(vec3(20, 0, 0))
local _, other = spawn("coop_player_avatar", vec3(20, 0, 1), nil, { id = 500 })
other._kind = "stalker"
local function from(name, t, peer) coop_main.on_event("mods." .. name, coop_main.encode(t), peer) end

local modes = dofile("tests/lua/support/modes.lua")
coop.levels = { split = function() return which == "server client" end }

PARTS, ROLLED = {}, {}
function se_load_var(id, name, var) if var == "parts" then return PARTS[id] end end
coop_economy_mdata = { on_se_value = function() end, send_se = function() return true end }
item_parts = {
	get_parts_con = function(obj, id) local i = obj and obj:id() or id; return PARTS[i] end,
	set_parts_con = function(id, p) PARTS[id] = p end,
	-- GAMMA's evaluate (WPO's patch): rolls from the condition this machine sees, once
	evaluate_parts = function(obj)
		if PARTS[obj:id()] then return end
		ROLLED[obj:id()] = (ROLLED[obj:id()] or 0) + 1
		PARTS[obj:id()] = { wpn_ak = math.ceil(obj:condition() * 100), scope = obj:condition() > 0.9 and 95 or 40 }
	end,
}
zzzz_arti_jamming_repairs = { is_part = function() return true end,
	act_fieldstrip = function(id, part) STRIPPED = (STRIPPED or 0) + 1 end }
arti_jamming = { try_replace_part = function() end, is_barrel = function(s) return s == "barrel" end, reset_cgd = function() end }
TIPS = {}
news_manager = { send_tip = function(_, msg) TIPS[#TIPS + 1] = msg end }

start_all()
local C = coop_mods_core
SendScriptCallback("actor_on_first_update")
SendScriptCallback("actor_on_update")

local function weapon(parent, cond, pos)
	local se, w = spawn("wpn_ak", pos or vec3(21, 0, 0), parent, { cond = cond })
	w._kind = "weapon"
	function w:name() return self:section() .. self:id() end
	se.name = function() return w:name() end
	return w
end

local function eval(w)
	from("wpo_eval", { n = 1, w1 = w:id(), s1 = w:name() }, 1)
end

local function read(w)
	item_parts.evaluate_parts(w)
	SendScriptCallback("actor_on_update")
end

if which == "co-op client" then
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	local plain = weapon(box:id(), 1)
	SENT = {}
	read(plain)
	check(ROLLED[plain:id()] == nil and sent("mods.wpo_eval") ~= nil, "co-op client asks the host for parts")
elseif which == "host" then
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	-- the authority of the level rolls with its own condition: the wear death_manager gave the gun here
	local worn = weapon(box:id(), 0.31)
	SENT = {}
	eval(worn)
	check(ROLLED[worn:id()] == 1 and PARTS[worn:id()].wpn_ak == 31, "wpo_eval: the authority rolls the parts of loot near the player from its own condition")
	eval(worn)
	check(ROLLED[worn:id()] == 1, "wpo_eval: parts that exist are never rolled again")
	-- A living NPC's trade/inventory view uses the same state as a corpse.
	local _, npc = spawn("npc", vec3(21, 0, 0), nil, { id = 600 })
	npc._kind = "stalker"
	local carried = weapon(600, 0.5)
	eval(carried)
	check(ROLLED[carried:id()] == 1, "wpo_eval: a nearby living NPC's weapon is evaluated by the host")
	-- loot far away is not his to look at
	local far = weapon(nil, 0.4, vec3(200, 0, 0))
	eval(far)
	check(ROLLED[far:id()] == nil, "wpo_eval: loot far from the player is refused")
	-- the weapon the requester carries himself (taken before its condition reached his copy) is rolled here too
	local his = weapon(500, 0.27)
	eval(his)
	check(ROLLED[his:id()] == 1, "wpo_eval: the requester's own fresh weapon is rolled by the authority")
	-- Review of R35: an ask the flood limit drops is answered, so the asker's ask is released (he asks again when he
	-- reads the item next) instead of waiting for an answer that never comes.
	SENT = {}
	for _ = 1, 25 do eval(worn) end
	local dropped = sent("mods.wpo_eval_no")
	check(dropped ~= nil and dropped.n == 1 and dropped.w1 == worn:id() and dropped.s1 == worn:name(),
		"wpo_eval: an ask the limit drops is refused to the asker")
	NOW = NOW + 60000

	-- a refused strip answers the player (it was a log line on the host alone)
	SENT = {}
	from("wpo_strip", { w = 9999, p = "scope" }, 1)
	local no, raw = sent("mods.wpo_no")
	check(no ~= nil and raw.target == 1 and no.r == "gone", "wpo_strip: a refusal is told to the requester")
	local loaded = weapon(nil, 0.5)
	loaded._ammo = 10
	PARTS[loaded:id()] = { scope = 80 }
	SENT = {}
	from("wpo_strip", { w = loaded:id(), p = "scope" }, 1)
	no = sent("mods.wpo_no")
	check(no ~= nil and no.r == "loaded", "wpo_strip: a loaded gun on the ground is refused with its own reason")
	local fine = weapon(box:id(), 0.5)
	PARTS[fine:id()] = { scope = 80 }
	SENT = {}
	from("wpo_strip", { w = fine:id(), p = "scope" }, 1)
	check(STRIPPED == 1 and sent("mods.wpo_no") == nil, "wpo_strip: an accepted strip sends no refusal")
else
	-- The world decider is away according to the facade. This answer must work independently of the engine flag.
	coop.levels.split = function() return false end
	modes.install(coop_mode, "srv_map", {
		where = function(peer) return peer == 0 and "away" or "here" end,
		is_player_mirror = function() return true end,
		actor_is_player = function() return true end,
		leads_here = function() return false end,
	})
	local _, box = spawn("box", vec3(21, 0, 0))
	box._kind = "box"
	-- loot in a box: this copy may not have its wear yet, the authority rolls
	local loot = weapon(box:id(), 1)
	SENT = {}
	read(loot)
	local ask = sent("mods.wpo_eval")
	check(ROLLED[loot:id()] == nil, "client, split levels: loot is not rolled from this copy's condition")
	check(ask ~= nil and ask.w1 == loot:id(), "client, split levels: the authority of the level is asked to roll")
	read(loot)
	check(sent_count("mods.wpo_eval") == 1, "client: one request while the answer is on its way")
	NOW = NOW + 5000
	read(loot)
	check(sent_count("mods.wpo_eval") == 1 and not PARTS[loot:id()], "elapsed time cannot authorize a mirror roll")
	-- Taking a weapon whose parts are unknown does not turn the mirror
	-- into its evaluator.
	local taken = weapon(0, 1)
	SENT = {}
	read(taken)
	check(sent("mods.wpo_eval") ~= nil, "client, split levels: a weapon without parts in the bag is rolled by the authority too")
	check(ROLLED[taken:id()] == nil and PARTS[taken:id()] == nil, "client, split levels: no stand-in table")
	read(taken)
	check(ROLLED[taken:id()] == nil and sent_count("mods.wpo_eval") == 1, "client: repeated reads share one request")
	from("wpo_eval_no", { w = taken:id(), name = taken:name() }, 0)
	check(ROLLED[taken:id()] == nil and PARTS[taken:id()] == nil, "refusal never initializes parts on a mirror")
	read(taken)
	check(sent_count("mods.wpo_eval") == 2, "client: a refused ask is asked again at the next read")
	from("wpo_eval_no", { n = 1, w1 = taken:id(), s1 = taken:name() }, 0)
	read(taken)
	check(sent_count("mods.wpo_eval") == 3 and PARTS[taken:id()] == nil,
		"client: an ask the limit dropped (a batch refusal) is released too, and nothing is rolled here")
	-- parts that exist: the mod's own code (it returns at once)
	local known = weapon(box:id(), 1)
	PARTS[known:id()] = { scope = 70 }
	SENT = {}
	read(known)
	check(sent("mods.wpo_eval") == nil, "client: a weapon with parts asks nobody")
	-- the authority's refusal of a strip is said to the player
	TIPS = {}
	from("wpo_no", { w = loot:id(), r = "far" }, 0)
	check(TIPS[1] ~= nil and TIPS[1]:find("st_coop_mods_wpo_strip_refused", 1, true) ~= nil, "client: a refused strip shows a message")
	from("wpo_no", { w = loot:id(), r = "loaded" }, 0)
	check(TIPS[2] ~= nil and TIPS[2]:find("st_coop_mods_wpo_strip_loaded", 1, true) ~= nil, "client: a loaded gun gets its own message")
	from("wpo_no", { w = loot:id(), r = "%s%s%n" }, 0)
	check(TIPS[3] ~= nil and TIPS[3]:find("%", 1, true) == nil, "client: a reason from the network is never shown as text")
	from("wpo_no", { w = loot:id(), r = "far" }, 1)
	check(TIPS[4] == nil, "client: only the host's answer counts")
end

check(C.stats.errors == 0, "no Lua errors (" .. C.stats.errors .. ")")
done("WPO ROLL " .. which)
