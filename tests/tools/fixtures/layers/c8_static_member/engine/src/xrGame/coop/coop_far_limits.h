#pragma once
struct FarLimits
{
	static u32 squads_per_player;
};
inline u32 far_squads() { return FarLimits::squads_per_player; }
