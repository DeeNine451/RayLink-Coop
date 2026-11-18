// srv: map server process
#include "coop_mapserver.h"
#include "xrCoop/coop_scope.h"
namespace coop::mapserver
{
bool is_map_server()
{
	return g_role == 2;
}

bool leads()
{
	return is_map_server();
}
} // namespace coop::mapserver
