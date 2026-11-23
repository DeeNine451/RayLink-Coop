-- H3-PING: real ping, codec and mode layers. Only the engine, renderer and network are stubbed.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
make_actor()
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local main = load_script("coop_main")
modes.live(facade, load_script)

local map, dedicated, split, map_server = "l01_escape", false, false, false
coop.is_dedicated = function() return dedicated end
coop.is_map_server = function() return map_server end
coop.self_id = function() return MODE == "host" and 0 or 1 end
coop.levels = { split = function() return split end }
level.name = function() return map end
local focus, hit_dist = nil, 40
level.get_target_obj = function() return focus end
level.get_target_dist = function() return hit_dist end
level.get_target_pos = function() return vec3(3, 0, 40) end
function device() return { width = 1920, height = 1080, cam_pos = vec3(0, 1, 0), cam_dir = vec3(0, 0, 1) } end
coop_hud_layout = { get = function() return { world_ring = 16, world_dot = 6 } end }
coop_allies = { color = function(peer) return peer == 1 and 123 or 17, 178, 219 end }
coop_hud3_fonts = { font = function() end }

local playing_to_host, host_to_playing = 41, 716
local objects, lookups = {}, 0
level.object_by_id = function(id)
	lookups = lookups + 1
	return objects[id]
end
coop.to_host_id = function(id)
	if MODE == "client" and id == playing_to_host then return host_to_playing end
end
coop.to_local_id = function(id)
	if MODE == "client" and id == host_to_playing then return playing_to_host end
	if MODE == "host" then return id end
end
local function creature(id, kind)
	local o = { _kind = kind or "monster", pos = vec3(1, 2, 40), alive_now = true }
	function o:id() return id end
	function o:alive() return self.alive_now end
	function o:position() return self.pos end
	return o
end

CUIScriptWnd = { Update = function() end }
function class(name)
	local env = getfenv(2)
	return function(base) env[name] = setmetatable({}, { __index = base }) end
end
function super() end
function vector2() return vector() end
function GetARGB(a, r, g, b) return { a = a, r = r, g = g, b = b } end
local missing, atlas_file, inits, window_count = nil, true, 0, 0
function getFS()
	return { exist = function() return atlas_file and "ui\\coop\\ui_coop_hud3.dds" or nil end }
end
function CScriptXmlInit()
	local function window(_, path, parent)
		window_count = window_count + 1
		local texture = ({ ["coop_ping:ring"] = "coop_hud_ring", ["coop_ping:dot"] = "coop_hud_dot" })[path]
		local w = { path = path, tex = texture, children = {} }
		if parent then parent.children[#parent.children + 1] = w end
		function w:Show(state) self.shown = state end
		function w:IsShown() return self.shown end
		function w:InitTexture(id)
			inits = inits + 1
			self.tex = id
			self.atlas_size = id ~= missing and 16 or 0 -- an unknown ID leaves the blank static's rect at zero
		end
		function w:GetTextureSize() return { x = self.atlas_size or 0, y = self.atlas_size or 0 } end
		function w:SetStretchTexture() end
		function w:SetWndSize(v) self.w, self.h = v.x, v.y end
		function w:SetWndPos(v) self.x, self.y = v.x, v.y end
		function w:SetTextureColor(c) self.color = c end
		function w:SetTextColor(c) self.color = c end
		function w:SetText(t) self.text = t end
		function w:SetTextAlignment() end
		function w:SetFont() end
		return w
	end
	return { ParseFile = function() end, InitStatic = window, InitTextWnd = window }
end
local ping = load_script("coop_hud_ping")
local function new_overlay()
	local overlay = setmetatable({ children = {} }, { __index = ping.UICoopPingWorld })
	overlay:__init()
	return overlay
end
local point, projected = { x = 700, y = 384 }
game = { world2ui = function(pos)
	projected = { x = pos.x, y = pos.y, z = pos.z }
	return point
end }
local function visible(overlay, id)
	local children = overlay.root.children
	for i = #children, 1, -1 do
		local w = children[i]
		if w.shown and (w.tex == id or w.path == id) then return w end
	end
end
local function frame(overlay, tg, x, y)
	NOW = tg
	point.x, point.y = x or 700, y or 384
	overlay:Frame(tg)
end
local function approx(a, b, eps) return a and math.abs(a - b) < (eps or 0.01) end
local function center(w, x, y)
	return w and approx(w.x + w.w / 2, x) and approx(w.y + w.h / 2, y)
end

local function relay(t, from)
	ping.on_ping(main.encode(t), from or 0)
end
local function request_relay(tag)
	local requested = ping.request()
	local req, packet = sent("core.ping_req")
	check(requested and req and req.t == host_to_playing and packet.target == 0, tag .. ": request uses world ID")
	MODE = "host"
	ping.on_req(packet.payload, 1)
	local posted, broadcast = sent("core.ping")
	check(posted and posted.t == host_to_playing and posted.p == 1 and broadcast.target == -1,
		tag .. ": authority relays the same world ID and stamps the sender")
	return posted
end

print("== Co-op: the playing host has the creature")
check(not facade.decides_world() and facade.actor_is_player(), "Co-op author is a playing mirror")
focus = creature(playing_to_host)
objects[host_to_playing] = creature(host_to_playing)
local co = request_relay("Co-op")
check(facade.decides_world() and facade.leads_here() and #ping.active() == 1, "Co-op host keeps the ping on its own map")
local overlay, born = new_overlay(), NOW
frame(overlay, born + 150)
local corner = visible(overlay, "coop_h3_bracket_tl")
local wide = corner and corner.x
frame(overlay, born + 300)
corner = visible(overlay, "coop_h3_bracket_tl")
check(corner and wide and corner.x > wide, "brackets converge through the first 300 ms")
local tight = corner and corner.x
frame(overlay, born + 540)
corner = visible(overlay, "coop_h3_bracket_tl")
check(corner and approx(corner.x, tight), "convergence ends at 300 ms")
for _, id in ipairs({ "tl", "tr", "bl", "br" }) do
	local corner = visible(overlay, "coop_h3_bracket_" .. id)
	check(corner and corner.color.r == 123 and corner.color.g == 178 and corner.color.b == 219,
		"bracket " .. id .. " has the author's color")
end
local cross = visible(overlay, "coop_h3_cross")
check(center(cross, 700, 384) and cross.color.r == 226 and cross.color.g == 58 and cross.color.b == 48
	and not visible(overlay, "coop_h3_dot"), "red cross replaces the dot at the precise projected point")
local label = visible(overlay, "coop_ping:label")
check(label and label.x > 700 and label.text:match("^%d+%s+[^%d%s]+$") and not label.text:find("joiner", 1, true),
	"world label contains only the distance and sits on the right")
local shown = 0
for _, w in ipairs(overlay.root.children) do if w.shown then shown = shown + 1 end end
check(shown == 8, "overlay has four brackets, an outlined center, and the distance with its shadow")
check(projected and approx(projected.y, 3.2), "creature ping projects its position plus head height")
objects[host_to_playing].pos = vec3(12, 4, 50)
frame(overlay, born + 556)
check(projected and projected.x == 12 and approx(projected.y, 5.2) and projected.z == 50, "cross follows a moving creature")
objects[host_to_playing].alive_now = false
objects[host_to_playing].pos = vec3(12, 0, 50)
frame(overlay, born + 572)
local dot = visible(overlay, "coop_h3_dot")
check(center(dot, 700, 384) and dot.color.r == 255 and dot.color.g == 255 and dot.color.b == 255
	and not visible(overlay, "coop_h3_cross") and approx(projected.y, 5.2), "death turns the cross into a white dot at the last point")

local base, base_label = corner and corner.color.a, label and label.color.a
local function aim(tg, radius)
	frame(overlay, tg, 512 + radius * 768 * (1024 * 1080 / (768 * 1920)), 384)
	local corner = visible(overlay, "coop_h3_bracket_tl")
	local dot = visible(overlay, "coop_h3_dot")
	local label = visible(overlay, "coop_ping:label")
	return corner and corner.color.a, dot and dot.color.a, label and label.color.a
end
check(approx(aim(born + 600, 0.07), base, 1.1), "7% cannot enter the aim fade")
check(approx(aim(born + 616, 0.059), base, 1.1), "aim fade starts at the 6% entry without jumping")
check(approx(aim(born + 716, 0.07), base and base * 0.6, 1.1), "hysteresis keeps fading at 7%; halfway after 100 ms")
local a, d, l = aim(born + 816, 0.07)
check(approx(a, base and base * 0.2, 1.1) and approx(d, 51, 1.1) and approx(l, base_label and base_label * 0.2, 1.1),
	"brackets, dot and distance reach 20% together in 200 ms")
check(approx(aim(born + 832, 0.08), base and base * 0.2, 1.1), "aim fade reverses at the 7.9% exit without jumping")
check(approx(aim(born + 932, 0.07), base and base * 0.6, 1.1), "7% cannot re-enter; reverse fade is halfway after 100 ms")
check(approx(aim(born + 1032, 0.07), base, 1.1), "reverse fade reaches full opacity in another 100 ms")
frame(overlay, born + 1100, 512, 384 + 0.059 * 768)
frame(overlay, born + 1150, 512, 384 + 0.07 * 768)
check(approx(corner and corner.color.a, base and base * 0.8, 1.1), "vertical 5.9% enters the same circle, fading at a constant rate")
aim(born + 1150, 0.08)
check(approx(aim(born + 1200, 0.08), base, 1.1), "an interrupted fade reverses from its current alpha at the same speed")
point = { x = -9999, y = 0 }
overlay:Frame(NOW + 16)
check(not visible(overlay, "coop_h3_dot") and not visible(overlay, "coop_ping:label"), "off-screen ping hides all its widgets")
point = { x = 700, y = 384 }

MODE = "client"
ping.clear()
objects[playing_to_host] = focus
relay(co or {})
check(#ping.active() == 1 and approx(ping.active()[1].pos.y, 3.2), "Co-op mirror translates and resolves the relayed target")

print("== Server: the world relays; the map supplies the replicated creature")
ping.clear()
SENT = {}
NOW = NOW + 3000
map, split, dedicated = "l02_garbage", true, true
-- The author is a player, then the same packet is handled by the dedicated world.
coop.is_dedicated = function() return dedicated and MODE == "host" end
local reads = lookups
local sv = request_relay("Server")
check(facade.decides_world() and not facade.leads_here() and #ping.active() == 0 and lookups == reads,
	"dedicated world relays without querying a creature or keeping a local marker")
check(not ping.request(), "dedicated world cannot make a ping from its ghost actor")
MODE = "client"
map_server = true
relay(sv or {})
check(facade.leads_here() and not facade.actor_is_player() and #ping.active() == 0 and lookups == reads,
	"map server supplies objects without displaying or resolving the HUD event")
map_server = false
map = "l03_agroprom"
relay(sv or {})
check(#ping.active() == 0, "Server mirror on another map discards the relay")
map = "l02_garbage"
local npc = creature(playing_to_host, "stalker")
function npc:get_bone_id(name) return name == "bip01_head" and 12 or 65535 end
function npc:bone_position(bone)
	assert(bone == 12)
	return vec3(self.pos.x, self.pos.y + 1.65, self.pos.z)
end
objects[playing_to_host] = npc
relay(sv or {})
born = NOW
frame(overlay, born + 400)
check(center(visible(overlay, "coop_h3_cross"), 700, 384) and projected.x == 1 and approx(projected.y, 3.65),
	"Server mirror on this map draws the cross at the NPC's head height")
npc.pos = vec3(8, 1, 40)
frame(overlay, born + 420)
check(projected.x == 8 and approx(projected.y, 2.65), "Server cross follows the NPC's replicated position")
function npc:get_bone_id() return 65535 end
frame(overlay, born + 430)
check(projected.x == 8 and approx(projected.y, 2.2), "missing head bone uses the 1.2 m offset")
objects[playing_to_host] = nil
frame(overlay, born + 440)
check(visible(overlay, "coop_h3_dot") and not visible(overlay, "coop_h3_cross") and projected.x == 8,
	"Server target leaves: its last point stays marked")
objects[playing_to_host] = creature(playing_to_host)
frame(overlay, born + 460)
check(projected.x == 8, "a detached ping stays fixed if its ID returns")
frame(overlay, born + ping.LIFE_MS)
check(not visible(overlay, "coop_h3_dot") and #ping.active() == 0, "the detached ping expires on schedule")

ping.clear()
objects[playing_to_host] = nil
relay(sv or {})
born = NOW
frame(overlay, born + 500)
check(visible(overlay, "coop_h3_dot") and projected.x == 3 and projected.y == 0 and projected.z == 40,
	"unresolved Server ID falls back to the original hit point")
local mapped = coop.to_local_id
coop.to_local_id = function() return nil end
ping.clear()
local lookup_snapshot = lookups
relay(sv or {})
check(lookups == lookup_snapshot and ping.active()[1] and ping.active()[1].pos.x == 3,
	"unmapped world ID never falls through to an unrelated local ID")
coop.to_local_id = mapped
for _, id in ipairs({ 0, 65535, -1, 1.5, "716", true }) do
	ping.clear()
	relay({ p = 1, n = 1, l = map, x = 3, y = 0, z = 40, t = id })
	check(lookups == lookup_snapshot and ping.active()[1] and ping.active()[1].pos.x == 3,
		"invalid optional target " .. tostring(id) .. " still keeps the fixed ping")
end
focus = creature(500, "stalker") -- the hosting player's avatar in the mirror's local numbering
local calls = 0
coop.to_host_id = function(id) calls = calls + 1; return host_to_playing end
ping.clear()
check(ping.request() and sent("core.ping_req").t == nil and calls == 0, "a player's stalker avatar is never a creature target")
focus = creature(playing_to_host)
focus.alive_now = false
ping.clear()
check(ping.request() and sent("core.ping_req").t == nil and calls == 0, "a dead creature is an ordinary point ping")
focus.alive_now, hit_dist = true, 600
ping.clear()
check(ping.request() and sent("core.ping_req").t == nil and calls == 0, "creatures past the ping range are ignored")

ping.clear()
relay(sv or {})
born = NOW
missing = "coop_h3_bracket_bl"
overlay = new_overlay()
local init_snapshot, window_snapshot = inits, window_count
frame(overlay, born + 500)
frame(overlay, born + 516)
check(center(visible(overlay, "coop_hud_ring"), 700, 384) and center(visible(overlay, "coop_hud_dot"), 700, 384)
	and not visible(overlay, "coop_h3_bracket_tl"), "missing atlas ID falls back to the old drawing")
check(inits == init_snapshot and window_count == window_snapshot, "fallback does not retry texture setup or create widgets per frame")
atlas_file, missing = false, nil
init_snapshot = inits
overlay = new_overlay()
frame(overlay, born + 532)
check(inits == init_snapshot and visible(overlay, "coop_hud_ring"), "missing DDS skips atlas initialization entirely")
done("ping Vizor")
