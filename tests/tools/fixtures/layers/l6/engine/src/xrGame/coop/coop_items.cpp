// Ядро: без проверок режима (docs/MODES.md)
#include "coop_items.h"
#include "coop_world_server.h"
namespace coop::items
{
bool may_pick(int owner, int me)
{

	return owner == 0 || owner == me;
}
} // namespace coop::items
