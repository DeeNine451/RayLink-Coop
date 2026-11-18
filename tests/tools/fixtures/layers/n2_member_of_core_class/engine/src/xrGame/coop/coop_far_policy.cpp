// core
#include "coop_far_policy.h"
namespace coop
{
FarPolicy& far_policy()
{
	static FarPolicy p;
	return p;
}

bool may_switch_offline(unsigned id)
{
	return !far_policy().keep_online(id);
}
} // namespace coop
