// srv: what the world server keeps online
#include "../coop_far_policy.h"
namespace coop
{
bool FarPolicy::keep_online(unsigned id) const
{
	return id != 0;
}
} // namespace coop
