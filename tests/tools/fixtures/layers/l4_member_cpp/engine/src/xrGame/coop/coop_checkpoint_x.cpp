// core
namespace coop
{
struct BaseSeen
{
	bool here = false; // on this level with a bed point
	bool host_side = true;
	bool level_known{false};
};
static bool place(int id, bool split_level = false) { return split_level && id; }
} // namespace coop
