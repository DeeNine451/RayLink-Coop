-- Small per-player keys of G.A.M.M.A. mods (coop_mods_misc -> coop_mods_pdata). Build 56 (live 2026-11-18, review F8):
-- a client loads the host's save at every world load, so the belt memory, the voice cooldown, the last helmet, the
-- sorting favourites, the scope FOVs, the NVG scope flag and the DOF reload times were the host's after each load.
-- Each fake below has the shape of the real mod (temp\review\corpus\merged): where its save_state is local, the data
-- is a file local too, reachable only as an upvalue.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")

-- remember_outfit_belt.script:8,102-108 (global on_save_state / on_load_state, keyed by OBJECT ids of the outfit and its items)
do
	local belt_memory = {}
	remember_outfit_belt = {
		on_save_state = function(m) m.beltMemory = belt_memory end,
		on_load_state = function(m) belt_memory = m.beltMemory or {} end,
		_set = function(outfit, items) belt_memory[outfit] = { items = items, date = 12.5 } end,
		_live = function() return belt_memory end,
	}
	remember_outfit_belt.on_game_start = function()
		RegisterScriptCallback("load_state", remember_outfit_belt.on_load_state)
		RegisterScriptCallback("save_state", remember_outfit_belt.on_save_state)
	end
end

-- agdd_voiced_actor.script:288,1481-1489 (global save_state: remaining ms of a time_global cooldown)
do
	local random_long_shout_cooldown = 0
	agdd_voiced_actor = {
		save_state = function(m)
			local remaining = random_long_shout_cooldown - time_global()
			m.varefined_random_long_cd = remaining > 0 and remaining or 0
		end,
		load_state = function(m) random_long_shout_cooldown = time_global() + (m.varefined_random_long_cd or 0) end,
		_shout = function(ms) random_long_shout_cooldown = time_global() + ms end,
		_left = function() return random_long_shout_cooldown - time_global() end,
	}
	agdd_voiced_actor.on_game_start = function()
		RegisterScriptCallback("save_state", agdd_voiced_actor.save_state)
		RegisterScriptCallback("load_state", agdd_voiced_actor.load_state)
	end
end

-- liz_fdda_redone_headgear_animations_hotkey.script:9-10,72-80 (global on_save_state, writes only while a helmet is off)
do
	local lastHelmet
	local lastHelmetId = nil
	liz_fdda_redone_headgear_animations_hotkey = {
		on_save_state = function(m) if lastHelmet then m.lastHelmetId = lastHelmet:id() end end,
		on_load_state = function(m) lastHelmetId = m.lastHelmetId end,
		_take_off = function(id) lastHelmet = { id = function() return id end } end,
		_id = function() return lastHelmetId end,
	}
	liz_fdda_redone_headgear_animations_hotkey.on_game_start = function()
		RegisterScriptCallback("load_state", liz_fdda_redone_headgear_animations_hotkey.on_load_state)
		RegisterScriptCallback("save_state", liz_fdda_redone_headgear_animations_hotkey.on_save_state)
	end
end

-- zzz_rax_sortingplus_mcm.script:25-26,42-50,91-92 (LOCAL save_state; favourites and junk keyed by SECTION)
do
	local favorite_itms = {}
	local junk_itms = {}
	local function save_state(mdata)
		mdata.rax_favorite_itms = favorite_itms
		mdata.rax_junk_itms = junk_itms
	end
	local function load_state(mdata)
		favorite_itms = mdata.rax_favorite_itms or favorite_itms
		junk_itms = mdata.rax_junk_itms or junk_itms
	end
	zzz_rax_sortingplus_mcm = {
		check_favs = function(cell) return favorite_itms[cell.section] end,
		on_game_start = function()
			RegisterScriptCallback("load_state", load_state)
			RegisterScriptCallback("save_state", save_state)
		end,
		_mark = function(sec, junk) if junk then junk_itms[sec] = true else favorite_itms[sec] = true end end,
		_live = function() return favorite_itms, junk_itms end,
	}
end

-- z_auto_looter.script:432-434 (reads the sorting favourites at its own load_state)
do
	local favorite_itms = {}
	local function load_state(mdata) favorite_itms = mdata.rax_favorite_itms or favorite_itms end
	z_auto_looter = {
		on_game_start = function() RegisterScriptCallback("load_state", load_state) end,
		_live = function() return favorite_itms end,
	}
end

-- scope_fov_mcm.script:66-67,338-346 (LOCAL save_state; FOVs keyed by weapon SECTION and parent SECTION)
do
	local saved_custom = {}
	local saved_gls = {}
	local function save_state(mdata)
		mdata.snk_saved_hud_fov = saved_custom
		mdata.snk_saved_gl_fov = saved_gls
	end
	local function load_state(mdata)
		saved_custom = mdata.snk_saved_hud_fov or {}
		saved_gls = mdata.snk_saved_gl_fov or {}
	end
	scope_fov_mcm = {
		on_game_start = function()
			RegisterScriptCallback("save_state", save_state)
			RegisterScriptCallback("load_state", load_state)
		end,
		_set = function(sec, fov, gl) if gl then saved_gls[sec] = fov else saved_custom[sec] = fov end end,
		_live = function() return saved_custom, saved_gls end,
	}
end

-- bas_nvg_scopes.script:5,95-118 (LOCAL save_state; a boolean, false is a value)
do
	local toggle = false
	local function on_key_release(key) toggle = not toggle end
	local function save_state(mdata) mdata.snk_bas_nvg_flag = toggle end
	local function load_state(mdata) toggle = mdata.snk_bas_nvg_flag or false end
	bas_nvg_scopes = {
		on_game_start = function()
			RegisterScriptCallback("on_key_release", on_key_release)
			RegisterScriptCallback("save_state", save_state)
			RegisterScriptCallback("load_state", load_state)
		end,
		_press = function() on_key_release(0) end,
		_live = function() return toggle end,
	}
end

-- ssfx_weapons_dof.script:46,447-455 (LOCAL save_state; reload times keyed by weapon SECTION)
do
	local ssfx_wpn_reloadtime_save = {}
	local function save_state(mdata) mdata.ssfx_saved_reload_time = ssfx_wpn_reloadtime_save end
	local function load_state(mdata) ssfx_wpn_reloadtime_save = mdata.ssfx_saved_reload_time or {} end
	ssfx_weapons_dof = {
		on_game_start = function()
			RegisterScriptCallback("save_state", save_state)
			RegisterScriptCallback("load_state", load_state)
		end,
		_set = function(sec, ms) ssfx_wpn_reloadtime_save[sec] = ms end,
		_live = function() return ssfx_wpn_reloadtime_save end,
	}
end

local FAKES = { "remember_outfit_belt", "agdd_voiced_actor", "liz_fdda_redone_headgear_animations_hotkey",
	"zzz_rax_sortingplus_mcm", "z_auto_looter", "scope_fov_mcm", "bas_nvg_scopes", "ssfx_weapons_dof" }
local KEYS = { "beltMemory", "varefined_random_long_cd", "lastHelmetId", "rax_favorite_itms", "rax_junk_itms",
	"snk_saved_hud_fov", "snk_saved_gl_fov", "snk_bas_nvg_flag", "ssfx_saved_reload_time" }

-- the host's values, as they are in every save a client loads
local function host_save(extra)
	local s = {
		beltMemory = { [9001] = { items = { [9002] = true }, date = 1 } }, -- the host's outfit and artefact ids
		varefined_random_long_cd = 25000,
		lastHelmetId = 9003,
		rax_favorite_itms = { host_fav = true }, rax_junk_itms = { host_junk = true },
		snk_saved_hud_fov = { wpn_host = 0.31 }, snk_saved_gl_fov = { wpn_host = 0.41 },
		snk_bas_nvg_flag = true,
		ssfx_saved_reload_time = { wpn_host = 1111 },
	}
	for k, v in pairs(extra or {}) do s[k] = v end
	return s
end

print("== small per-player keys of G.A.M.M.A. mods (client)")
make_actor()
start_all()
for _, n in ipairs(FAKES) do _G[n].on_game_start() end
local P = coop_mods_pdata
for _, k in ipairs(KEYS) do check(P.owns(k), "registered: " .. k) end

local B, V, H = remember_outfit_belt, agdd_voiced_actor, liz_fdda_redone_headgear_animations_hotkey
local R, L, F, N, D = zzz_rax_sortingplus_mcm, z_auto_looter, scope_fov_mcm, bas_nvg_scopes, ssfx_weapons_dof

-- 1. no record of this character: nothing of the host's (a new player starts the mods fresh)
alife_storage_manager.CALifeStorageManager_load(host_save({ coop_mods_pdata = { ["777"] = { t = "x", d = { lastHelmetId = 5 } } } }))
local m = alife_storage_manager.get_state()
for _, k in ipairs(KEYS) do check(m[k] == nil, "no record: the host's " .. k .. " is not taken") end
check(next(B._live()) == nil, "belt memory: none of the host's outfits")
check(V._left() <= 0, "voice cooldown: not the host's 25 s")
check(H._id() == nil, "last helmet: not the host's id")
local fav, junk = R._live()
check(not fav.host_fav and not junk.host_junk and not L._live().host_fav, "sorting and auto looter: not the host's favourites")
local hud, gl = F._live()
check(hud.wpn_host == nil and gl.wpn_host == nil, "scope FOVs: not the host's")
check(N._live() == false, "NVG scope flag: not the host's")
check(D._live().wpn_host == nil, "reload times: not the host's")

-- 2. the client plays: every mod changes its value, the report carries the client's own
B._set(4001, { [4002] = true })
V._shout(30000)
H._take_off(4003)
R._mark("my_fav"); R._mark("my_junk", true)
F._set("wpn_mine", 0.55); F._set("wpn_mine_gl", 0.66, true)
N._press()
D._set("wpn_mine", 2222)
SENT = {}
NOW = NOW + 20000 -- the voice cooldown has 10 s left
SendScriptCallback("actor_on_update")
local piece = sent("mods.pd")
local d = piece and coop_mods_core.deser(piece.d)
check(d ~= nil, "a report was sent")
d = d or {}
check(type(d.beltMemory) == "table" and d.beltMemory[4001] and d.beltMemory[4001].items[4002] == true, "report: the belt memory")
check(d.varefined_random_long_cd == 10000, "report: the voice cooldown left (" .. tostring(d.varefined_random_long_cd) .. ")")
check(d.lastHelmetId == nil, "report: the last helmet is not read (its game object may be gone: the mod's save would call it)")
check(d.rax_favorite_itms and d.rax_favorite_itms.my_fav and d.rax_junk_itms and d.rax_junk_itms.my_junk, "report: favourites and junk")
check(d.snk_saved_hud_fov and d.snk_saved_hud_fov.wpn_mine == 0.55 and d.snk_saved_gl_fov and d.snk_saved_gl_fov.wpn_mine_gl == 0.66,
	"report: scope FOVs")
check(d.snk_bas_nvg_flag == true, "report: the NVG scope flag")
check(d.ssfx_saved_reload_time and d.ssfx_saved_reload_time.wpn_mine == 2222, "report: the reload times")

-- 3. the next world load: the host's values in the save, the client's own record beside them -> the client's
local seen
RegisterScriptCallback("load_state", function(mm)
	seen = { fov = mm.snk_saved_hud_fov, nvg = mm.snk_bas_nvg_flag }
end)
NOW = NOW + 5000
STASH.coop_mods_pdata = nil
alife_storage_manager.CALifeStorageManager_load(host_save({ coop_mods_pdata = { ["500"] = { t = "TOKX", d = d } } }))
m = alife_storage_manager.get_state()
check(seen and seen.fov and seen.fov.wpn_mine == 0.55 and seen.nvg == true, "load_state already sees the client's values")
check(B._live()[4001] and B._live()[9001] == nil, "belt memory: the client's own")
check(V._left() == 10000, "voice cooldown: the client's 10 s left (" .. tostring(V._left()) .. ")")
check(H._id() == nil, "last helmet: none after a load, and never the host's")
fav, junk = R._live()
check(fav.my_fav and not fav.host_fav and junk.my_junk and not junk.host_junk, "sorting: the client's favourites and junk")
check(L._live().my_fav and not L._live().host_fav, "auto looter: the client's favourites")
hud, gl = F._live()
check(hud.wpn_mine == 0.55 and gl.wpn_mine_gl == 0.66 and hud.wpn_host == nil, "scope FOVs: the client's")
check(N._live() == true, "NVG scope flag: the client's")
check(D._live().wpn_mine == 2222 and D._live().wpn_host == nil, "reload times: the client's")

-- 4. the NVG flag switched off just before the load (false is a value, not "nothing"): kept as he left
local world_epoch = 7
coop.world_epoch = function() return world_epoch end
N._press() -- off
coop_main.on_world_leaving(8)
world_epoch = 8
alife_storage_manager.CALifeStorageManager_load(host_save({ coop_mods_pdata = { ["500"] = { t = "TOKX", d = d } } }))
check(N._live() == false, "NVG scope flag switched off a second before the load stays off (" .. tostring(N._live()) .. ")")
coop.world_epoch = nil

-- 5. the host and single player load their own values as before
for _, mode in ipairs({ "host", "sp" }) do
	MODE = mode
	alife_storage_manager.CALifeStorageManager_load(host_save({ coop_mods_pdata = { ["500"] = { t = "TOKX", d = d } } }))
	hud = F._live()
	check(B._live()[9001] and H._id() == 9003 and R._live().host_fav and hud.wpn_host == 0.31 and N._live() == true
		and D._live().wpn_host == 1111 and V._left() == 25000, mode .. ": its own values, untouched")
end
done("MODS PREFS")
