-- Anomaly Coop test stand-ins: luabind objects. A script `class` instance of the game (task_objects.CGeneralTask,
-- task_manager.CRandomTask) is a userdata: type(x) answers "userdata" and pairs(x) fails. A plain table in a stub hides every
-- `type(tsk) == "table"` of the code under test, which then does nothing in the game. Not shipped.

function luabind_object(t)
	local p = newproxy(true)
	local mt = getmetatable(p)
	mt.__index = t
	mt.__newindex = t
	return p
end

-- A task_info table whose entries become luabind objects when they are stored. A co-op stub on a client is a real Lua table
-- in the game too (its metatable has __coop_data): it stays one.
function luabind_task_table()
	return setmetatable({}, { __newindex = function(self, k, v)
		local mt = type(v) == "table" and getmetatable(v) or nil
		if type(v) == "table" and not (mt and mt.__coop_data) then v = luabind_object(v) end
		rawset(self, k, v)
	end })
end
