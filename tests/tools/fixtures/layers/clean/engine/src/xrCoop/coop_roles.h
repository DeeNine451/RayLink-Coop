// Ядро: без проверок режима (docs/MODES.md)
#pragma once
namespace coop
{
struct Roles
{
	bool mirror = false; // copies of the authority's objects
	int seats{4};
};

// a default that carries no mode fact
inline int clamp_seats(int seats, int limit = 8)
{
	return seats > limit ? limit : seats;
}

enum class Kind
{
	HostLike = 1,
	Other = 2,
};
} // namespace coop
