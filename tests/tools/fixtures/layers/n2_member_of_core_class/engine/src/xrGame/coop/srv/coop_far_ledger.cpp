// srv: its own ledger
namespace coop
{
struct Ledger
{
	int n() const;
};
int Ledger::n() const
{
	return 1;
}
} // namespace coop
