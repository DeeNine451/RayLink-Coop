-- F5-COV-1: body-based cover, real GAMMA ray directions, separate mode answer sets. Not shipped.
local passed, failed = 0, 0
local function check(ok, name)
    if ok then passed = passed + 1 else failed = failed + 1 end
    print((ok and "  ok   " or "  FAIL ") .. name)
end
local function load_module(path)
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)()
    return env
end
local V = {}; V.__index = V
function vector() return setmetatable({ x = 0, y = 0, z = 0 }, V) end
function V:set(x, y, z)
    if type(x) == "table" then self.x, self.y, self.z = x.x, x.y, x.z
    else self.x, self.y, self.z = x, y, z end
    return self
end
function V:add(v) self.x, self.y, self.z = self.x + v.x, self.y + v.y, self.z + v.z; return self end
function V:sub(v) self.x, self.y, self.z = self.x - v.x, self.y - v.y, self.z - v.z; return self end
function V:mul(n) self.x, self.y, self.z = self.x*n, self.y*n, self.z*n; return self end
function V:distance_to(v)
    return math.sqrt((self.x - v.x)^2 + (self.y - v.y)^2 + (self.z - v.z)^2)
end
function V:normalize()
    local n = math.sqrt(self.x^2 + self.y^2 + self.z^2)
    if n > 0 then self:mul(1/n) end
    return self
end
function vector_rotate_y(v, angle)
    local r = angle * math.pi / 180
    return vector():set(v.x*math.cos(r) - v.z*math.sin(r), v.y, v.x*math.sin(r) + v.z*math.cos(r))
end
local function copy(v) return vector():set(v) end
local function close(a,b) return type(a) == "number" and math.abs(a-b) < 1e-10 end
function class(name)
    getfenv(2)[name] = {}
    return function() end
end
local function real_script(name)
    local base = os.getenv("GAMMA_SCRIPTS")
    if base then
        local path = base .. "/" .. name .. ".script"
        local f = io.open(path, "rb")
        if f then f:close(); return path end
    end
    return "temp/review/corpus/merged/" .. name .. ".script"
end
local chunk, load_error = loadfile("gamedata/scripts/coop_env_cover.script")
check(chunk ~= nil, "verdict module exists: " .. tostring(load_error or "loaded"))
if not chunk then print(string.format("%d passed, %d failed", passed, failed)); return end

-- Load the unedited mod and inspect its own init's table, rather than restating the formula as expected data.
local reference = load_module(real_script("dynamic_emission_cover_mcm"))
reference.init()
local directions
for i = 1, 30 do
    local name, value = debug.getupvalue(reference.init, i)
    if not name then break end
    if name == "ray_table" then directions = value end
end
check(directions and #directions == 109, "real Dynamic Emission Cover builds 109 rays")
ini_file = function() return {} end
utils_data = { collect_section = function() return {} end }
local real_tb = load_module(real_script("TB_Coordinate_Based_Safe_Zones"))
local modes = dofile("tests/lua/support/modes.lua")
coop_mode = load_module("gamedata/scripts/coop_mode.script")
local now, active, surge, psi, sm_started, pm_started, map, objects, rows, calls, config
local mods, geometry_pattern, status_lines, bodies, next_body_id
function time_global() return now end
function GetEvent(event, key)
    if key == "state" then return event == "surge" and surge or event == "psi_storm" and psi end
    -- Deliberately false personal claims: they must never decide another body's cover.
    return true
end
coop = { players = function() return rows end }
coop_mods_core = {
    active = function() return active end,
    mod = function(name) return mods[name] end,
    status_line = function(tag, fn) status_lines[tag] = fn end,
}
local function body(x,y,z)
    local p = vector():set(x or 0, y or 0, z or 0)
    local id = next_body_id
    next_body_id = next_body_id + 1
    local function handle()
        return {
            id = function() return id end,
            position = function()
                assert(bodies[id], "position called on a destroyed body")
                return copy(p)
            end,
            p = p,
        }
    end
    bodies[id] = handle
    return handle()
end
local function setup()
    now, active, surge, psi, sm_started, pm_started = 100000, true, true, false, false, false
    map, objects, rows, calls, status_lines = "l01_escape", {}, {}, {}, {}
    bodies, next_body_id = {}, 10
    config = { rays_per_update = 10, cover_range = 8, north_cover_bonus = 0, distance_factor = .85, grace_period = 1 }
    db = { zone_by_name = {} }
    level = {
        name = function() return map end,
        -- C++ gives Lua fresh userdata for the same online object on each lookup.
        object_by_id = function(id) return bodies[id] and bodies[id]() end,
        iterate_nearest = function(p, radius, fn)
            assert(radius == 2.0)
            for _, obj in ipairs(objects) do
                if fn(obj) then break end
            end
        end,
    }
    local sm = { covers = {}, init_surge_covers = function() end }
    mods = {
        level_weathers = { valid_levels = { l01_escape = true } },
        surge_manager = { get_surge_manager = function() sm.started = sm_started; return sm end },
        psi_storm_manager = { get_psi_storm_manager = function() return { started = pm_started } end },
        item_tent = {},
        dynamic_emission_cover_mcm = {
            excluded_maps = reference.excluded_maps,
            get_config = function(key) return config[key] end,
        },
    }
    geometry_pattern = function(n) return n % 10 ~= 0, "concrete" end
    mods.demonized_geometry_ray = { geometry_ray = function(args)
        local saved = {}; for k,v in pairs(args) do saved[k] = v end
        return { get = function(_, p, dir)
            local hit, material, distance = geometry_pattern(#calls + 1)
            distance = distance or 1
            calls[#calls+1] = { pos = copy(p), dir = copy(dir), args = saved }
            return { in_contact = hit, result = { material_name = material }, distance = distance,
                position = copy(p):add(copy(dir):mul(distance)) }
        end }
    end }
    return load_module("gamedata/scripts/coop_env_cover.script"), sm
end
local function verdict(m, b, covered, source, label, peer)
    local c,s = m.verdict(peer or 1, b)
    check(c == covered and s == source, label .. " [" .. tostring(s) .. "]")
end
local function cycle(m, b, peer)
    for _ = 1, math.ceil(109/config.rays_per_update) do m.tick(peer or 1, b); now = now + 10 end
end

for _, mode in ipairs(modes.names()) do
    modes.install(coop_mode, mode)
    print("== env_cover " .. mode)
    local m, sm = setup()
    local b = body()
    if mode == "none" then
        active = false
        m.tick(1,b)
        verdict(m,b,false,"none","outside session ignores cover and casts nothing")
        check(#calls == 0, "outside session has no ray or registration effects")
        check(next(status_lines) == nil, "outside session installs no coop_status entry")
    elseif mode == "srv_world" then
        m.tick(1,nil)
        verdict(m,nil,false,"none","world process without a body has no verdict")
        check(#calls == 0, "world process without a body never scans geometry")
        check(next(status_lines) == nil, "no body means no coop_status registration")
    else
        sm.covers = { shelter = true }
        db.zone_by_name.shelter = { inside = function(_,p) return p.x < 1 end }
        sm.pos_in_cover = function() error("patched actor-specific predicate must not be called") end
        verdict(m,b,true,"static","static restrictor in")
        b.p.x = 2
        verdict(m,b,false,"none","static restrictor out ignores local underground claim")
        sm.covers = {}
        objects = { { section = function() return "ph_tent" end, position = function() return vector():set(3.5,0,0) end } }
        verdict(m,b,false,"none","tent at exactly 1.5 m is outside stock cover")
        b.p.x = 2.1
        verdict(m,b,true,"tent","tent just inside 1.5 m")
        b.p.x = 1.9
        verdict(m,b,false,"none","tent farther than 1.5 m")
        b.p.x = 2.1; mods.item_tent = nil
        verdict(m,b,false,"none","missing tent script skips the nearby object")
        objects = {}
        mods.tb_coordinate_based_safe_zones = real_tb
        local levels = { l09_deadcity="DC", k00_marsh="GS", y04_pole="ME", jupiter="JU", zaton="ZA",
            l05_bar="RO", l11_pripyat="PR", pripyat="OU", l10_radar="RA", l04_darkvalley="DV" }
        for name,suffix in pairs(levels) do
            map = name; mods.level_weathers.valid_levels[name] = true
            local box = real_tb["tbSZ_"..suffix][1]
            b.p:set((box[1]+box[4])/2, box[5]-1, (box[3]+box[6])/2)
            verdict(m,b,true,"tb_zone","TB real box " .. name)
            b.p.x = box[4]
            verdict(m,b,false,"none","TB strict outside boundary " .. name)
        end
        map = "custom_no_atmosfear"
        verdict(m,b,true,"closed_level","initialized weather table excludes non-AtmosFear level")
        local valid_levels = mods.level_weathers.valid_levels
        mods.level_weathers.valid_levels = {}
        verdict(m,b,false,"none","uninitialized weather table cannot establish cover")
        mods.level_weathers.valid_levels = valid_levels
        map = "l13_generators"; mods.level_weathers.valid_levels[map] = true
        verdict(m,b,true,"closed_level","NO_EMISSION level")
        map = "l11_hospital"; mods.level_weathers.valid_levels[map] = true
        verdict(m,b,true,"closed_level","hospital is also a NO_EMISSION level")
        map = "l01_escape"; sm.indoor_levels = { [map] = true }
        verdict(m,b,true,"closed_level","surge manager marks the level indoors")
        sm.indoor_levels = nil
        map = "labx8"; mods.level_weathers.valid_levels[map] = true
        mods.tb_coordinate_based_safe_zones = nil
        verdict(m,b,true,"closed_level","Dynamic Emission Cover excludes the level")
        mods.dynamic_emission_cover_mcm = nil
        mods.tb_coordinate_based_safe_zones = real_tb
        verdict(m,b,true,"closed_level","TB underground list works independently")
        mods.tb_coordinate_based_safe_zones = nil
        verdict(m,b,false,"none","missing mod exclusions are skipped")

        m = setup(); b = body(2,3,4)
        for _ = 1,10 do m.tick(1,b) end
        verdict(m,b,false,"none","dynamic waits for all 109 directions")
        m.tick(1,b)
        verdict(m,b,true,"dynamic","90 percent contacts after full cycle")
        check(type(status_lines.env_cover) == "function" and status_lines.env_cover() == m.status(),
            "first active body tick registers the coop_status line")
        local _,_,score = m.verdict(1,b)
        check(close(score,99/109), "score is the full cycle contact share")
        local equal = true
        for i = 1,109 do
            local d = calls[i] and calls[i].dir; local r = directions[i]
            equal = equal and d ~= nil and close(d.x,r.x) and close(d.y,r.y) and close(d.z,r.z)
        end
        check(equal and #calls == 109, "all directions equal the real mod, exactly one full cycle")
        check(calls[1].args.ignore_object == b and calls[1].args.flags == 15
            and calls[1].args.ray_range == 8 and calls[1].args.contact_range == 7.99,
            "geometry parameters and ignore_object belong to supplied body")
        check(close(calls[1].pos.y,3.75) and b.p.y == 3, "standing offset .75 without mutating body")
        local status = m.status()
        check(type(status) == "string" and status:find("dynamic",1,true) and status:find("rays/s",1,true),
            "status reports source, score and ray rate")
        geometry_pattern = function(n) return n % 2 == 0, "concrete" end
        cycle(m,b)
        verdict(m,b,true,"dynamic","grace keeps preceding covered verdict")
        now = now + 1001
        verdict(m,b,false,"none","grace expires per peer without extra scan")
        local _,_,low = m.verdict(1,b)
        check(low < .51, "50 percent contacts are below threshold")
        verdict(m,b,false,"none","another peer has no inherited cover",2)
        m.reset(1)
        local _,_,cleared = m.verdict(1,b)
        check(cleared == nil, "reset drops cycle, score and grace")

        m = setup(); b = body()
        local id = b:id()
        check(coop_mode.where(1) == "here" and coop_mode.decider(1) == "this"
            and coop_mode.seat_plays(0) == (mode == "hostplay"),
            "mode answers identify the remote body and whether seat zero plays")
        for _ = 1, 11 do m.tick(1,level.object_by_id(id)) end
        check(#calls == 109, "fresh Lua handles for one online body complete a single scan")
        verdict(m,level.object_by_id(id),true,"dynamic","fresh verdict handle keeps the completed score")
        bodies[id] = nil
        local ok_status, departed = pcall(m.status)
        check(ok_status and departed == "env_cover: ", "status drops a departed body without dereferencing its old handle")

        for _,stance in ipairs({ {16,.5}, {48,.25}, {nil,.75} }) do
            m = setup(); b = body(0,3,0); rows = { { id = 1, mstate = stance[1] } }
            m.tick(1,b)
            check(close(calls[1].pos.y,3+stance[2]), "snapshot stance offset " .. stance[2])
        end
        m = setup(); b = body(); config.rays_per_update = 1
        geometry_pattern = function(n) return true, n == 1 and "bush" or n == 2 and "water" or "concrete" end
        m.tick(1,b)
        local fresh = level.object_by_id(b:id())
        m.tick(1,fresh); m.tick(1,fresh)
        check(#calls == 3 and close(calls[2].args.ray_range,7) and close(calls[3].args.ray_range,6)
            and close(calls[2].args.contact_range,6.99), "bush and water recast within shared per-tick budget")
        check(close(calls[2].pos.x,calls[1].pos.x+calls[1].dir.x*1.01), "recast advances .01 past material")
        check(close(calls[3].dir.z,calls[1].dir.z), "recast finishes same direction before next ray")
        check(calls[2].args.ignore_object == fresh, "a resumed recast uses the current engine handle")
        m = setup(); b = body(); surge = false
        m.tick(1,b); check(#calls == 0, "no phase means no dynamic scan")
        pm_started = true; m.tick(1,b); check(#calls == 10, "started psi manager enables scan without event")
        pm_started = false; sm_started = true; m.tick(1,b); check(#calls == 20, "started surge manager enables scan")
        for _ = 1, 10 do m.tick(1,b) end
        verdict(m,b,true,"dynamic","manager-only surge completes a scored cycle")
        sm_started = false; m.tick(1,b)
        local _,_,stopped = m.verdict(1,b)
        check(stopped == nil, "phase end clears scan state")
        m = setup(); b = body(); config.north_cover_bonus = 1; config.distance_factor = .95
        cycle(m,b); verdict(m,b,true,"dynamic","north bonus applies to surge")
        m = setup(); b = body(); surge = false; psi = true
        config.north_cover_bonus = 1; config.distance_factor = .95
        cycle(m,b); verdict(m,b,false,"none","north bonus does not apply to psi storm")

        m = setup(); b = body(); cycle(m,b)
        check(m.status():find("1:dynamic",1,true), "status refreshes verdict after tick alone")
        surge = false; psi = true
        verdict(m,b,false,"none","phase switch invalidates cached dynamic verdict before next tick")
        m = setup(); b = body(); cycle(m,b)
        config.distance_factor = .99
        verdict(m,b,false,"none","changed decider settings invalidate cached verdict immediately")
        m = setup(); b = body(); cycle(m,b)
        mods.demonized_geometry_ray.geometry_ray = nil
        verdict(m,b,false,"none","missing geometry function invalidates cached verdict")
        m = setup(); b = body(); cycle(m,b)
        verdict(m,body(),false,"none","new body cannot inherit old body's dynamic cover")
        cycle(m,b)
        map = "zaton"; mods.level_weathers.valid_levels.zaton = true
        verdict(m,b,false,"none","level change discards previous geometry")
        m = setup(); b = body(); cycle(m,b)
        map = "zaton"; mods.level_weathers.valid_levels.zaton = true
        check(not m.status():find("1:",1,true), "status drops a previous map's body without looking it up on this map")
        m = setup(); b = body(); cycle(m,b); cycle(m,b,2)
        m.reset(1)
        verdict(m,b,false,"none","reset clears only requested peer")
        verdict(m,b,true,"dynamic","reset preserves other peer's covered verdict",2)

        m = setup(); b = body()
        config.grace_period = 0
        cycle(m,b,2)
        verdict(m,b,true,"dynamic","zero-grace configuration still grants cover in shelter",2)
        geometry_pattern = function() return false,"concrete" end
        cycle(m,b,2)
        verdict(m,b,false,"none","zero grace immediately drops unsafe cover",2)
        m = setup(); b = body(); config.rays_per_update = 1000
        cycle(m,b)
        check(#calls == 109, "large update budget stops at cycle boundary")
        m = setup(); b = body(); config.rays_per_update = 3
        local other = body()
        m.tick(1,b)
        local first_count = #calls
        m.tick(2,other)
        check(first_count == 3 and #calls == 6
            and calls[4].args.ignore_object == other and close(calls[4].dir.y, calls[1].dir.y),
            "each player gets its own three-ray budget and cycle cursor")
        m = setup(); b = body(); config.cover_range = 0
        m.tick(1,b); check(#calls == 0, "nonpositive range never reaches ray constructor")
        m = setup(); b = body(); config.cover_range = .02
        geometry_pattern = function() return true,"bush",0 end
        for _ = 1,22 do m.tick(1,b) end
        local _,_,transparent_score = m.verdict(1,b)
        check(transparent_score == 0 and #calls == 218, "zero-distance bushes terminate without becoming shelter")
        m = setup(); b = body(); mods = {}
        m.tick(1,b); verdict(m,b,false,"none","missing mods skipped")
        check(#calls == 0, "missing dynamic dependency casts no rays")
    end
end
print(string.format("%d passed, %d failed", passed, failed))
