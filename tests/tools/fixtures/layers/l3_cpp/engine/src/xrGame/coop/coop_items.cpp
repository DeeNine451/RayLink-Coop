// Ядро: без проверок режима (docs/MODES.md)
#include "coop_items.h"
#include "xrCoop/coop_scope.h"
namespace coop::items
{
bool may_pick(int owner, int me)
{

	return owner == 0 || owner == me;
}
} // namespace coop::items
