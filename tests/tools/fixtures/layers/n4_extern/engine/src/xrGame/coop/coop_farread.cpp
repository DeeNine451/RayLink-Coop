// core
extern bool g_far_world;
extern int g_core_count;
namespace coop::farread
{
bool may_give(unsigned id)
{
	if (g_far_world || g_core_count > 3)
		return false;
	return id != 0;
}
} // namespace coop::farread
