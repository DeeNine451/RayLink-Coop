#include "pch_script.h"
bool xr_switch_hook(unsigned);
void Y::f(unsigned id)
{
	if (xr_switch_hook(id)) return;
}
