// Ядро: без проверок режима (docs/MODES.md)
#include "coop_net.h"
#include "xrCoop/coop_roles.h"
namespace coop::net
{
void send_all();

void broadcast()
{
	if (mgr().is_host()) send_all();
}

int size_of(const char* s)
{
	int n = 0; // "is_map_server()" in a string is not code
	while (s[n]) // is_map_server() in a comment is not code either
		++n;
	return n;
}
} // namespace coop::net
