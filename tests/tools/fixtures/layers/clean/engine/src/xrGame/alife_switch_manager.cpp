// stock GSC file with one co-op hook
#include "pch_script.h"
#include "coop/coop_levels.h"

void CALifeSwitchManager::switch_online(unsigned id)
{
	if (coop::levels::online_at_server(id)) return;
	do_switch(id);
}
