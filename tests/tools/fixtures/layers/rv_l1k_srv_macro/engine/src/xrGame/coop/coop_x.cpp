// core
#include "xrCoop/coop_scope.h"
namespace coop::items
{
void give(unsigned id)
{
	if (COOP_REMOTE())
		return;
}
} // namespace coop::items
