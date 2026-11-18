// core
namespace coop::items
{
void give(unsigned id)
{
	if (strstr(Core.Params, "-coop_mapserver"))
		return;
}
} // namespace coop::items
