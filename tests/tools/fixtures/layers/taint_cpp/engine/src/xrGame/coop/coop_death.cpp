// Ядро: без проверок режима (docs/MODES.md)
namespace coop::death
{
static bool ghost()
{
	return levels::leads_here();
}

bool down_here(int id)
{
	if (ghost())
		return false;
	return id != 0;
}
} // namespace coop::death
