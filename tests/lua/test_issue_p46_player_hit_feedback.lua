-- TZ P46 (Dev 58, owner 2026-11-22): "урон другого игрока передал звук урона хосту в коопе".
--
-- The machine that applies a hit to its own actor runs CActor::Hit (engine Actor.cpp): the hurt sound (sndHit), the hit
-- marks and the fire-hit camera kick come first, and only then the stock Lua entry _G.CActor__BeforeHitCallback
-- (_g.script) decides whether the hit counts. Its clause "the draftsman is a stalker friendly to db.actor" drops the
-- hit: a friendly NPC's stray bullet does no damage. In a session a player's character is a stalker too (his proxy where
-- his level is led, his avatar on another player's machine), and a teammate's hit reaches an actor only by the session's
-- friendly fire rule. Dropped there, it was the sound and picture of a hit with no damage.
--
-- Rule under test (coop_npc_compat wrap_actor_friend_hit): in a session a hit by another player's character goes through
-- the stock function as any hit does (its invulnerability clause and the actor_on_before_hit chain stay); a friendly
-- NPC's hit and single player are the stock game; the global IsStalker is not changed.
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")
local BS = string.char(92)

local function first_file(...)
	for i = 1, select("#", ...) do
		local p = select(i, ...)
		if p and have_file(p) then return p end
	end
end
-- The stock _g.script (Anomaly 1.5.3 db, the G.A.M.M.A. stand has no loose copy and _g_patches does not touch the function).
local STOCK_G = first_file(os.getenv("STOCK_SCRIPTS") and (os.getenv("STOCK_SCRIPTS") .. BS .. "_g.script"),
	".." .. BS .. "anomaly-ref" .. BS .. "unpacked" .. BS .. "scripts" .. BS .. "_g.script",
	"temp" .. BS .. "stock_scripts" .. BS .. "scripts" .. BS .. "_g.script",
	"temp" .. BS .. "anomaly_unpack" .. BS .. "scripts_out" .. BS .. "scripts" .. BS .. "_g.script")
local HEADER = "function CActor__BeforeHitCallback(actor,shit,bone_id)"
-- Used only when no stock file is readable: the function as _g.script has it (its lines 1221-1239), same chunk name.
local REPLICA = [[
function CActor__BeforeHitCallback(actor,shit,bone_id)
	if (shit.type ~= hit.strike) then
		if (bind_stalker_ext.invulnerable_time and time_global() < bind_stalker_ext.invulnerable_time) then
			bind_stalker_ext.invulnerable_time = bind_stalker_ext.invulnerable_time - 500
			return false
		end
	end

	if (shit.power > 0) then
		if (shit.draftsman and shit.draftsman:id() ~= 0 and IsStalker(shit.draftsman) and shit.draftsman:relation(db.actor) == game_object.friend) then
			return false
		end
	end

	flags.ret_value = true
	SendScriptCallback("actor_on_before_hit",shit,bone_id,flags)
	return flags.ret_value
end]]

local function stock_text()
	if not STOCK_G then return REPLICA, "_g.script" end
	local fh = assert(io.open(STOCK_G, "rb"))
	local src = fh:read("*a")
	fh:close()
	local lines = {}
	for line in src:gmatch("([^\n]*)\n?") do lines[#lines + 1] = (line:gsub("\r$", "")) end
	for i, line in ipairs(lines) do
		if line:sub(1, #HEADER) == HEADER then
			local out = {}
			for j = i, #lines do
				out[#out + 1] = lines[j]
				if j > i and lines[j]:match("^end%s*$") then return table.concat(out, "\n"), STOCK_G end
			end
		end
	end
	error("CActor__BeforeHitCallback not found in " .. STOCK_G)
end

local TEXT, CHUNK = stock_text()
print("  stock CActor__BeforeHitCallback from " .. (STOCK_G or "the replica in this test"))

local FRIEND, NEUTRAL, ENEMY = 0, 1, 2
local HIT = { burn = 0, wound = 5, fire_wound = 6, strike = 7, explosion = 8 }

-- One machine: role "host" (the process that leads the level: Coop host, a map server), "client" (a player's machine),
-- "single" (no session). shooter: the local id of the teammate's character on this machine.
local function make_machine(set, role, peer, avatars, shooter)
	reset_world()
	NOW = 100000
	local m = machine(role, peer, avatars)
	local E = m.env
	modes.install(load_script(m, "coop_mode"), set)
	E.hit = HIT
	E.game_object = { friend = FRIEND, neutral = NEUTRAL, enemy = ENEMY }
	E.bind_stalker_ext = {}
	E.IsStalker = function(o) return o ~= nil and o._stalker == true end
	-- the stock function as CScriptStorage loads _g.script: in the global table, with its file local `flags`
	local chunk = assert(loadstring("local flags = { ret_value = true }\n" .. TEXT .. "\n", "@" .. CHUNK))
	setfenv(chunk, E)
	chunk()
	assert(type(E.CActor__BeforeHitCallback) == "function", "the stock function is defined")
	load_script(m, "coop_npc_players")
	load_script(m, "coop_mods_core")
	local compat = load_script(m, "coop_npc_compat")
	compat.on_game_start()
	local seen = {}
	E.RegisterScriptCallback("actor_on_before_hit", function(s, bone, flags) seen[#seen + 1] = s end)
	m.mate = m.add(make_obj(shooter, 1, 0, 0, { _stalker = true, _rel = { [0] = FRIEND } })) -- a teammate's character
	m.npc = m.add(make_obj(700, 2, 0, 0, { _stalker = true, _rel = { [0] = FRIEND } })) -- a friendly NPC
	m.foe = m.add(make_obj(shooter + 1, 3, 0, 0, { _stalker = true, _rel = { [0] = ENEMY } }))
	m.seen = seen
	m.compat = compat
	return m
end

local function hit_actor(m, who, kind, power)
	local before = #m.seen
	local s = { power = power or 0.3, type = kind or HIT.fire_wound, draftsman = who, impulse = 0 }
	local ok = m.env.CActor__BeforeHitCallback(m.env.db.actor, s, 11)
	return ok, #m.seen > before
end

local function verify_session(set, role, tag, m)
	local ok, chain = hit_actor(m, m.mate)
	check(ok == true and chain, tag .. "a teammate's bullet (friendly fire on) stays a hit: damage and the actor_on_before_hit chain")
	ok, chain = hit_actor(m, m.mate, HIT.explosion, 0.6)
	check(ok == true and chain, tag .. "a teammate's grenade blast stays a hit")
	ok, chain = hit_actor(m, m.mate, HIT.strike, 0.1)
	check(ok == true and chain, tag .. "a teammate's blow stays a hit")
	ok, chain = hit_actor(m, m.npc)
	check(ok == false and not chain, tag .. "a friendly NPC's stray bullet stays the stock no-damage hit")
	ok, chain = hit_actor(m, m.foe)
	check(ok == true and chain, tag .. "a hostile character's hit counts, as stock")
	m.env.bind_stalker_ext.invulnerable_time = NOW + 1000
	ok, chain = hit_actor(m, m.mate)
	check(ok == false and not chain and m.env.bind_stalker_ext.invulnerable_time == NOW + 500,
		tag .. "the stock invulnerability after a load still drops a teammate's bullet")
	m.env.bind_stalker_ext.invulnerable_time = nil
	check(m.env.IsStalker(m.mate) == true, tag .. "the global IsStalker still calls a player's character a stalker")
	local listed = false
	for _, a in ipairs(m.compat._applied()) do if a == "actor_friend_hit" then listed = true end end
	check(listed, tag .. "coop_status lists the rule (actor_friend_hit)")
	for _, line in ipairs(m.log) do
		if line:find("! ", 1, true) then check(false, tag .. "no error lines: " .. line) end
	end
end

for _, set in ipairs(modes.names()) do
	if set == "none" then
		local m = make_machine(set, "single", 0, { [0] = 0 }, 501)
		local ok, chain = hit_actor(m, m.mate)
		check(ok == false and not chain, "none: single player, a friendly stalker's hit is the stock no-damage hit")
		ok, chain = hit_actor(m, m.npc, HIT.explosion, 0.6)
		check(ok == false and not chain, "none: single player, a friendly stalker's blast is the stock no-damage hit")
	else
		-- the process that leads the level: Coop host (hostplay), a map server, the world server; the teammate is a proxy
		verify_session(set, "host", set .. " / leader: ", make_machine(set, "host", 0, { [0] = 0, [1] = 501 }, 501))
		-- a player's machine: the teammate (the Coop host or another player) is an avatar there
		verify_session(set, "client", set .. " / player: ", make_machine(set, "client", 1, { [0] = 401, [1] = 0, [2] = 403 }, 403))
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
