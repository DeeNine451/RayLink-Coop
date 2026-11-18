// core
namespace coop::items
{
void give(unsigned id)
{
	if (coop::levels::remote_peer(id))
		return;
	give_local(id);
}
} // namespace coop::items
