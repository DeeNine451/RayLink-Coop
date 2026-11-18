// core
namespace coop::levels { void xfer_newthing(unsigned); }
namespace coop::items
{
void give(unsigned id)
{
	coop::levels::xfer_newthing(id);
}
}
