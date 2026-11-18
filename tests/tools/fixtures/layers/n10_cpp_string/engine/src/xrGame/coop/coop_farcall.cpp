// core
namespace coop::farcall
{
bool keep(lua_State* L, unsigned id)
{
	lua_getglobal(L, "coop_srv_far");
	lua_getglobal(L, "coop_items");
	run(L, "coop_levels.key");
	return lua_toboolean(L, -1) != 0;
}
} // namespace coop::farcall
