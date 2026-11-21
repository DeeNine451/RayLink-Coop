-- The engine's unlocalizer for tests (engine src\xrServerEntities\script_storage.cpp, before a script compiles): for a
-- script listed in a gamedata\configs\unlocalizers\*.ltx section, a column-0 "local a, b = ..." naming a listed variable
-- loses its "local" (a module field from then on) and "local a" becomes "a = nil"; one line for one line, so line numbers
-- stay. A test that loads a G.A.M.M.A. script must load it this way, or it passes where the game fails (stand, build 57:
-- XCV phantoms, corpse search XP, the guide, the Barrier defense - all looked for a local that the game made a field).
local M = {}

-- What the stand's unlocalizers list for the scripts these tests load (E:\RayLinkGames\GAMMA\game-dev\gamedata\configs\
-- unlocalizers, 2026-11-21).
M.GAMMA = {
	tasks_guide = { guid = true, curr_guid = true, tbl_way = true, tbl_ignore_Locations = true },
	tasks_defense = { MDATA = true },
}

function M.source(src, names)
	if not names then return src end
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local l = line:gsub("\r$", "")
		local rest = l:match("^local[ \t]+(.*)$")
		if rest and not rest:match("^function[ \t]") then
			local body = rest:gsub("%-%-.*$", "")
			local has_value = body:find("=", 1, true) ~= nil
			for v in (body:match("^([^=]*)") or ""):gmatch("[^,]+") do
				if names[v:match("^%s*(.-)%s*$")] then
					l = rest
					if not has_value then
						local code, comment = l:match("^(.-)(%-%-.*)$")
						l = code and (code .. "= nil " .. comment) or (l .. " = nil")
					end
					break
				end
			end
		end
		out[#out + 1] = l
	end
	return table.concat(out, "\n")
end

-- loadfile with the game's unlocalizer for that script (by file name); nil, err like loadfile.
function M.loadfile(path)
	local fh = io.open(path, "rb")
	if not fh then return nil, "cannot open " .. path end
	local src = fh:read("*a")
	fh:close()
	local name = path:match("([^/\\]+)%.script$")
	return loadstring(M.source(src, name and M.GAMMA[name]), "@" .. path)
end

return M
