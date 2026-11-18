// core
namespace coop::items
{
void tick(unsigned id)
{
	auto p = &coop::levels::online_at_server;
	p(id);
}
} // namespace coop::items
