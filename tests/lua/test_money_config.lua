-- The shipped money settings (gamedata\configs\coop_money.ltx and the G.A.M.M.A. layer over it). Run: tools\test_lua.cmd money_config
-- Live, build 55: "Апгрейды через верстак не работают, тратят ящики, ничего не происходит". The workbench's modifications tab
-- installs an upgrade by script: no mechanic is named. The host refused every such upgrade of a client ("no mechanic named
-- (scripted_upgrades = false)") while the client's script had already spent the kit through the host. The shipped setting
-- lets the host take a script's upgrade; the host still checks whose the item is and that the upgrade fits it.
PASSES, FAILS = 0, 0
local function check(cond, text)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. text)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. text)
	end
end

-- key -> value of one section of an ltx file; nil when the file is absent
local function section_of(path, section)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local out, here = {}, false
	for line in fh:lines() do
		line = line:gsub("\r", ""):gsub(";.*$", "")
		local name = line:match("^%s*!?%[([%w_]+)%]")
		if name then
			here = name == section
		elseif here then
			local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
			if k then out[k] = v end
		end
	end
	fh:close()
	return out
end

print("== a script's upgrade (the workbench) is taken by the host")
local base = section_of("gamedata/configs/coop_money.ltx", "coop_money")
check(base ~= nil, "coop_money.ltx has the section coop_money")
check(base and base.scripted_upgrades == "true", "scripted_upgrades = true in the shipped settings (found " .. tostring(base and base.scripted_upgrades) .. ")")
local gamma = section_of("gamedata_gamma/configs/mod_coop_money_gamma.ltx", "coop_money")
check(gamma == nil or gamma.scripted_upgrades == nil or gamma.scripted_upgrades == "true",
	"the G.A.M.M.A. layer does not switch it off")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
