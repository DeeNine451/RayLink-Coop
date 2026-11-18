// srv: helpers of the world server
namespace coop::levels
{
bool leads_here()
{
	return mapserver::is_map_server() || dedicated::on();
}

bool online_at_server(unsigned id)
{
	if (!split())
		return false;
	return id != 0;
}

void frame()
{
	if (!split())
		return;
}
bool remote2() { return split(); }
} // namespace coop::levels
