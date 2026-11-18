// Ядро
#pragma once
#include <cstdint>
namespace coop
{
constexpr uint16_t kNoLevel = 0xffff;
struct Spot
{
	uint16_t level = kNoLevel;
	bool on_this_level = true;
};
inline int pick(int id, uint32_t host_peer = 0) { return id + int(host_peer); }
inline bool keep(int id, bool same_level = false) { return same_level && id; }
} // namespace coop
