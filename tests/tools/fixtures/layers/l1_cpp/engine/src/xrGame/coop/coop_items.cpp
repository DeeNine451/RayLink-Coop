// Ядро: без проверок режима (docs/MODES.md)
#include "coop_items.h"
namespace coop::items
{
bool may_pick(int owner, int me)
{
	if (coop::mapserver::is_map_server()) return false;
	return owner == 0 || owner == me;
}
} // namespace coop::items
