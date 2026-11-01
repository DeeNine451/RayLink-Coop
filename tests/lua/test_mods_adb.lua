-- Grok's actor damage balancer in a session (coop_mods_misc install_adb): it counts the armour and the body part, and it stops at
-- a bullet whose weapon is not on this machine. Run: tools\test_lua.cmd mods_adb
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
print("== the damage balancer and a player's shot")
make_actor(vec3(0, 0, 0))
hit = { fire_wound = 8, wound = 6 }

local WEAPONS = {}
local BOOSTED, BEFORE = {}, 0
grok_actor_damage_balancer = {}
local g = grok_actor_damage_balancer
function g.shit_booster(shit, bone, ap)
	BOOSTED[#BOOSTED + 1] = { bone = bone, ap = ap }
	shit.power = 0
end
-- the stock's shape: no weapon here, no ammo: the bullet stays as it came
function g.actor_on_before_hit(shit, bone, flags)
	BEFORE = BEFORE + 1
	if shit.type ~= hit.fire_wound then
		shit.power = 0
		return
	end
	local w = level.object_by_id(shit.weapon_id)
	if w == nil or not IsWeapon(w) then return end
	g.shit_booster(shit, bone, 3)
end
RegisterScriptCallback("actor_on_before_hit", g.actor_on_before_hit)

load_script("coop_mods_misc")
coop_mods_misc.on_game_start()
local on_hit = g.actor_on_before_hit

local _, gun = spawn("wpn_ak74", vec3(1, 0, 0), nil, { id = 700 })
gun._kind = "weapon"
local _, friend = spawn("coop_player_avatar", vec3(5, 0, 0), nil, { id = 500 })
friend._kind = "stalker"

local function shot(weapon_id, who)
	return { type = hit.fire_wound, power = 0.5, weapon_id = weapon_id, draftsman = who }
end

local s = shot(700, friend)
on_hit(s, 7, {})
check(#BOOSTED == 1 and BOOSTED[1].ap == 3 and BOOSTED[1].bone == 7 and s.power == 0, "the weapon is here: the stock counts it, on that bone, once")

friend.active_item = function() return gun end
s = shot(999, friend)
on_hit(s, 3, {})
check(s.weapon_id == 700 and #BOOSTED == 2 and BOOSTED[2].ap == 3 and BOOSTED[2].bone == 3, "not here: the shooter's hands stand in, the leg takes it")

friend.active_item = function() return nil end
s = shot(999, friend)
on_hit(s, 12, {})
check(#BOOSTED == 3 and BOOSTED[3].ap == 0 and BOOSTED[3].bone == 12 and s.power == 0, "no weapon at all: still on the body part, no armour piercing")

s = { type = hit.wound, power = 0.2, weapon_id = 500, draftsman = friend }
BOOSTED = {}
on_hit(s, 12, {})
check(#BOOSTED == 0 and s.power == 0, "a blow is the stock's own")

print(string.format("%d passed, %d failed", PASSES or 0, FAILS or 0))
