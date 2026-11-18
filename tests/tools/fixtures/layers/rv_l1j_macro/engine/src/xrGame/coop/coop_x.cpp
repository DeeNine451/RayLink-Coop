// core
namespace coop::items
{
#define ASK(p) coop::mapserver::p##_map_server()
void give(unsigned id)
{
	if (ASK(is))
		return;
}
} // namespace coop::items
