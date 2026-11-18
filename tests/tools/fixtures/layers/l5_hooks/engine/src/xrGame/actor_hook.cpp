// stock GSC file with co-op hooks
#include "coop/coop_items.h"
void CActor::pick(int owner)
{
	if (!coop::items::may_pick(owner, 1)) return;
	if (coop::mapserver::is_map_server()) return;
}
