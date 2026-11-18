// core
namespace coop::items
{
void give(unsigned id)
{
	if (mgr().has_role(ProcessRole::WorldServer))
		return;
}
} // namespace coop::items
