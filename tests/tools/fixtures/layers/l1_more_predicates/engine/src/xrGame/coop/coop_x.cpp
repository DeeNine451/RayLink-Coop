// Ядро
namespace coop::items
{
void give(unsigned id)
{
	if (world_server_now())
		return;
	if (levels::game_split())
		return;
	if (mgr().has_role(ProcessRole::MapServer))
		return;
	if (mgr().has_role(ProcessRole::WorldClient))
		return;
	if (mgr().has_role(ProcessRole::Player))
		return;
	if (cmd_param("-coop_dedicated", v))
		return;
	if (strstr(Core.Params, "-coop_connect"))
		return;
	namespace d = coop::dedicated;
}
} // namespace coop::items
