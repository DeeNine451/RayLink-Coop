-- H3 fonts are optional. Test the Lua module against both an older exe and the runtime family API.
local passed, failed = 0, 0
local function check(value, label)
	if value then
		passed = passed + 1
	else
		failed = failed + 1
		print("  FAIL " .. label)
	end
end

local path = "gamedata/scripts/coop_hud3_fonts.script"
local chunk, err = loadfile(path)
check(chunk, err or "the H3 font script loads")
if chunk then
	local function module()
		local env = setmetatable({}, { __index = _G })
		setfenv(chunk, env)()
		return env
	end

	local fonts = module()
	check(fonts.font("nick") == nil, "older executable without font exports falls back")
	local registered, objects = {}, {}
	function RegisterFont(name, base, shader, height)
		registered[#registered + 1] = { name, base, height }
		if name == "ui_font_hud3_small" then return false end
		objects[name] = {}
		return true
	end
	check(fonts.font("nick") == nil and #registered == 0, "missing getter falls back without registering")
	function GetFontByName(name)
		if name == "ui_font_hud3_head" then error("font lookup unavailable") end
		return objects[name]
	end
	local nick = fonts.font("nick")
	check(nick ~= nil and nick == objects.ui_font_hud3_nick, "font returns the engine object for SetFont")
	check(fonts.font("small") == nil, "missing atlas falls back")
	check(fonts.font("head") == nil and fonts.font("missing") == nil, "lookup errors and unknown roles fall back")
	check(fonts.font("nick") == nick and #registered == 3, "the three families are registered once")
	for _, entry in ipairs(registered) do
		check(entry[2] == "ui\\" .. entry[1] and (entry[3] == nil or entry[3] == 0),
			"family " .. entry[1] .. " lets the engine choose tiers by screen height")
	end
	RegisterFont = function() error("registration unavailable") end
	GetFontByName = function() return {} end
	check(module().font("nick") == nil, "registration errors fall back even if a lookup can return an object")
end
print(string.format("%d passed, %d failed", passed, failed))
