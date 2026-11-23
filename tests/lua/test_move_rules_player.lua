-- Anomaly Coop test (R32 WP18 P4, temp/r30/design/R32-final.md §8a A21 E-3; both modes): the mods' move rules for a move into
-- a player's character.
-- The engine's admitted_move (coop_requests.cpp) asked coop_mods_move_limits.admit only for a container: a move whose
-- destination root is a player was applied unasked, so the Weapon Showcase display rule (coop_mods_hf.script
-- hf_showcase_display) never saw a pickup and a player could still take a display copy. The engine now asks for that
-- destination too (no admission book: pending 0, nothing held; only a refusal stops it, xrCoop/coop_move_admission.h
-- judge, tests/test_move_admission_player.cpp). The rules' side, proven here with the real scripts:
--   - a display copy is refused into a player's character (the host's own, a client's) from anywhere;
--   - no registered rule refuses an ordinary pickup into a player: hf_capacity (stash_capacities, a player's character is no
--     stash and the HF rule weighs only moves out of a player's character), companion_assigned_weight (a player's character
--     is no companion) and the display rule (not a display copy) all answer nil: from the ground, a box, an HF stash, a corpse,
--     a companion and another player, light or heavier than any stash's capacity;
--   - every registration of a move rule in the scripts is one of these three: a new rule fails this test until its answer for
--     a player destination is proven here.
-- Core: runs once per answer set of coop_mode (hostplay, srv_world, srv_map, none). In single player ("none") the engine never
-- asks (no session); the answers are checked anyway, since the rules never ask the mode for this.
-- Not shipped. Run: tools\test_lua.cmd move_rules_player
local modes = dofile("tests/lua/support/modes.lua")
local name = modes.names()[1]
MODE = name == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")

local BS = string.char(92)
local NO_ID = 65535
local DISPLAY_WHY = "a weapon showcase display copy"

-------------------------------------------------------------------------------
-- what the three rules read of the game and of their mods
-------------------------------------------------------------------------------
EDDListType = { iActorBag = 1, iActorSlot = 2, iDeadBodyBag = 4 }
AddScriptCallback("npc_on_item_take")
AddScriptCallback("ActorMenu_on_item_before_move")
AddScriptCallback("ActorMenu_on_item_after_move")

local actor = make_actor(vec3(0, 0, 0))
local GO = getmetatable(actor)
function GO:weight() return self._w or 0 end
function GO:iterate_inventory_box(f)
	for id, se in pairs(SE) do
		if se.parent_id == self._id and OBJ[id] then f(self, OBJ[id]) end
	end
end

-- Hideout Furniture's stash capacity (only its presence matters to coop_mods_move_limits.install_hf)
stash_capacities = {}
INI.hf_stash_small = { placeable_type = "stash", capacity = 60 }
INI.inventory_box = { capacity = 70 }

-- GAMMA UI's companion assignments (axr_companions.script; only NPCs carry the "companion" var, a player's character never)
local companions = {}
function se_load_var(id, _, key) return key == "companion" and companions[id] or nil end
axr_companions = {
	Enabled = true,
	is_assigned_item = function() return false end,
	OnItemAfterMove = function() end,
}

-- Weapon Showcase (weapon_showcase.script): case -> item in the case -> its display copy on the ground
weapon_showcase = {
	weapon_displays = {},
	spawn_displayed_item = function() end,
	remove_displayed_item = function() end,
	respawn_weapon_displays = function() return true end,
}

start_all() -- coop_mods_hf.on_game_start registers hf_showcase_display (install_gadgets)
modes.install(coop_mode, name)
local M = coop_mods_move_limits
M.on_game_start() -- hf_capacity (axr_main runs every script's on_game_start in the game)
load_script("coop_mods_move_limits_companions").on_game_start()

print("== move rules for a destination whose root is a player (R32 P4, A21 E-3), set " .. name)
check(M.has_rule("hf_showcase_display"), name .. ": the Weapon Showcase display rule is installed")
check(M.has_rule("hf_capacity"), name .. ": the HF stash capacity rule is installed")
check(M.has_rule("companion_assigned_weight"), name .. ": the companion weight rule is installed")

-------------------------------------------------------------------------------
-- the world
-------------------------------------------------------------------------------
local _, client = spawn("coop_player_avatar", vec3(1, 0, 0), nil, { id = PROXY, kind = "stalker" })
local box = spawn("trader_box", vec3(2, 0, 0), nil, { kind = "box" }).id
local stash = spawn("hf_stash_small", vec3(2, 0, 1), nil, { kind = "box" }).id
local corpse = spawn("stalker", vec3(3, 0, 0), nil, { kind = "stalker", alive = false }).id
local companion = spawn("stalker", vec3(3, 0, 1), nil, { kind = "stalker" }).id
companions[companion] = true
local case = spawn("hf_weapon_case", vec3(4, 0, 0), nil, { kind = "box" }).id

local function item(sec, w, parent, kind)
	local _, o = spawn(sec, vec3(1, 0, 0), parent ~= NO_ID and parent or nil, { kind = kind })
	o._w = w
	return o
end

-- two display copies of two weapons in the case (one is shown, the second slot too)
local in_case = item("wpn_ak74", 3.5, case, "weapon")
local in_case2 = item("wpn_pm", 0.9, case, "weapon")
local display = item("wpn_ak74", 3.5, NO_ID, "weapon")
local display2 = item("wpn_pm", 0.9, NO_ID, "weapon")
weapon_showcase.weapon_displays = { [case] = { [in_case:id()] = display:id(), [in_case2:id()] = display2:id() } }

-- the players' characters as this process numbers them: the host's own (0; a ghost on the servers) and a client's
local players = { { id = 0, label = "actor 0" }, { id = PROXY, label = "the client's character" } }
local function sources_for(dst)
	local other = dst == 0 and PROXY or 0
	return {
		{ id = NO_ID, label = "the ground" },
		{ id = box, label = "a box" },
		{ id = stash, label = "an HF stash" },
		{ id = corpse, label = "a corpse" },
		{ id = companion, label = "a companion" },
		{ id = other, label = "another player" },
	}
end

-------------------------------------------------------------------------------
-- 1. an ordinary pickup into a player: every rule answers nil (the engine moves it as in the stock game)
-------------------------------------------------------------------------------
local asked, nil_answers = 0, 0
for _, dst in ipairs(players) do
	for _, src in ipairs(sources_for(dst.id)) do
		for _, w in ipairs({ 1, 500 }) do -- 500 kg: heavier than any stash's capacity
			for _, kind in ipairs({ "part", "weapon" }) do
				local it = item(kind == "weapon" and "wpn_ak74" or "part", w, src.id, kind)
				local verdict, why = M.admit(dst.id, it:id(), 0, 0, src.id)
				asked = asked + 1
				if verdict == nil then
					nil_answers = nil_answers + 1
				else
					check(false, string.format("%s: %s %d kg from %s into %s: no rule may speak, got %s (%s)", name, kind, w,
						src.label, dst.label, tostring(verdict), tostring(why)))
				end
			end
		end
	end
end
check(asked == 48 and nil_answers == asked, string.format("%s: %d of %d ordinary pickups into a player: every rule answers nil",
	name, nil_answers, asked))

-------------------------------------------------------------------------------
-- 2. a display copy into a player: refused with the display rule's text, from wherever it is asked
-------------------------------------------------------------------------------
for _, dst in ipairs(players) do
	for _, copy in ipairs({ display, display2 }) do
		local verdict, why = M.admit(dst.id, copy:id(), 0, 0, NO_ID)
		check(verdict == false and why == DISPLAY_WHY, string.format("%s: a display copy (%d) taken from the ground into %s is refused (%s, %s)",
			name, copy:id(), dst.label, tostring(verdict), tostring(why)))
	end
	local verdict = M.admit(dst.id, display:id(), 0, 0, dst.id == 0 and PROXY or 0)
	check(verdict == false, name .. ": a display copy handed on from another player into " .. dst.label .. " is refused")
end
-- the weapon in the case itself is no display copy: the rule does not speak for it (the mod takes it out by its own window)
check(M.admit(PROXY, in_case:id(), 0, 0, case) == nil, name .. ": the weapon in the case is not the display rule's")
-- a display copy that is gone from the table (the mod removed it) is an ordinary item again
weapon_showcase.weapon_displays[case][in_case2:id()] = nil
check(M.admit(PROXY, display2:id(), 0, 0, NO_ID) == nil, name .. ": a copy the mod no longer displays is not refused")
weapon_showcase.weapon_displays[case][in_case2:id()] = display2:id()

-------------------------------------------------------------------------------
-- 3. every registration of a move rule in the scripts is one of the three proven above
-------------------------------------------------------------------------------
local function list_dir(dir)
	local names = {}
	local pipe = io.popen('dir /b /a-d "' .. dir .. BS .. '*.script" 2>nul')
	if not pipe then return names end
	for line in pipe:lines() do
		line = line:gsub("\r", "")
		if line:match("%.script$") then names[#names + 1] = line end
	end
	pipe:close()
	table.sort(names)
	return names
end

local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

-- the code of a script without its comments (block comments first, then line comments)
local function code_of(src)
	src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
	return (src:gsub("%-%-[^\n]*", ""))
end

-- the first argument of each add_rule( call (not the definition `function add_rule(`), a literal resolved by its local
local function registrations(code)
	local out = {}
	local pos = 1
	while true do
		local s, e, arg = code:find("add_rule%s*%(%s*([^,%)]*)", pos)
		if not s then break end
		local before = code:sub(math.max(1, s - 24), s - 1)
		if not before:find("function%s+[%w_%.:]*$") then
			arg = arg:gsub("%s+$", "")
			local literal = arg:match('^"(.-)"$') or arg:match("^'(.-)'$")
			if not literal and arg:match("^[%a_][%w_]*$") then
				literal = code:match("local%s+" .. arg .. "%s*=%s*\"(.-)\"")
			end
			out[#out + 1] = literal or ("<" .. arg .. ">")
		end
		pos = e + 1
	end
	return out
end

local found, files = {}, {}
local dirs = { "gamedata" .. BS .. "scripts", "engine" .. BS .. "gamedata" .. BS .. "scripts", "gamedata_gamma" .. BS .. "scripts" }
local scanned = 0
for _, dir in ipairs(dirs) do
	for _, file in ipairs(list_dir(dir)) do
		local src = read(dir .. BS .. file)
		scanned = scanned + 1
		if src and src:find("coop_mods_move_limits", 1, true) then
			for _, rule in ipairs(registrations(code_of(src))) do
				found[#found + 1] = rule
				files[#files + 1] = file
			end
		end
	end
end
table.sort(found)
local known = { "companion_assigned_weight", "hf_capacity", "hf_showcase_display" }
check(scanned > 100, name .. ": the scripts were read (" .. scanned .. " files)")
check(table.concat(found, ",") == table.concat(known, ","), name .. ": the registered move rules are exactly the three proven here ("
	.. table.concat(found, ", ") .. " in " .. table.concat(files, ", ") .. ")")

done("move_rules_player@" .. name)
