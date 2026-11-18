// Ядро: без проверок режима (docs/MODES.md)
namespace coop::players
{
static void equip_loading_frame()
{
	if (is_map_server()) return;
}

static bool loads_here()
{
	return !is_map_server();
}

void frame()
{
	equip_loading_frame();
	if (loads_here())
		return;
}
} // namespace coop::players
