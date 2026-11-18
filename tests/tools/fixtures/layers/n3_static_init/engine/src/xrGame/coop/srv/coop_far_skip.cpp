// srv: the world server skips far objects
#include "../coop_hooks.h"
namespace coop::srvfar
{
static bool far_skip(unsigned id)
{
	return id >= 0x9000;
}
static const bool registered = (coop::hooks::set_skip(&far_skip), true);
static const int kLimit = 8;
const char* const kName = "far";
struct Cache
{
	int size = compute_size();
};
int counted()
{
	static int once = compute_size();
	return once;
}
} // namespace coop::srvfar
