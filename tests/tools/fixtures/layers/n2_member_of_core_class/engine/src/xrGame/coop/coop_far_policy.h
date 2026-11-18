// core
#pragma once
namespace coop
{
struct FarPolicy
{
	bool keep_online(unsigned id) const;
};
struct Ledger
{
	int size() const;
};
FarPolicy& far_policy();
} // namespace coop
