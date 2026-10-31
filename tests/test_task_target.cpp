// Anomaly Coop unit tests: when the host sends the place of a task's target (xrCoop/coop_task_target.h, tasks audit C1:
// a client's spot, edge pointer and compass stood at the place the target had when the client joined).
#include "test_util.h"

#include "coop_task_target.h"

using coop::task_target::due;
using coop::task_target::kMinGapMs;
using coop::task_target::moved;
using coop::task_target::Place;

namespace
{
Place at(float x, float y, float z, uint16_t vertex)
{
	Place p;
	p.x = x;
	p.y = y;
	p.z = z;
	p.game_vertex = vertex;
	return p;
}
} // namespace

// A new target goes out at once, whatever the clock says.
TEST(task_target_first_place_is_sent)
{
	const Place p = at(1, 2, 3, 7);
	CHECK(due(Place(), 0, p, 1));
	CHECK(due(Place(), 0, p, 500000));
}

// Standing still costs nothing.
TEST(task_target_standing_still_is_not_sent)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(!due(p, 1000, p, 1000 + 10 * kMinGapMs));
	CHECK(!due(p, 1000, at(104, 0, 100, 7), 1000 + 10 * kMinGapMs));
}

TEST(task_target_a_walk_is_sent)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(due(p, 1000, at(105, 0, 100, 7), 1000 + kMinGapMs));
	CHECK(due(p, 1000, at(100, 6, 100, 7), 1000 + kMinGapMs));
	CHECK(moved(p, at(103, 4, 100, 7))); // exactly 5 m
}

// A target that runs still goes out at most once per gap.
TEST(task_target_rate_limit)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(!due(p, 1000, at(900, 0, 100, 7), 1000 + kMinGapMs - 1));
	CHECK(due(p, 1000, at(900, 0, 100, 7), 1000 + kMinGapMs));
}

// Another game vertex can be another level: the name of the map comes from it, however near the numbers are.
TEST(task_target_new_game_vertex_is_a_move)
{
	const Place p = at(100, 0, 100, 7);
	CHECK(moved(p, at(100, 0, 100, 8)));
	CHECK(due(p, 1000, at(100, 0, 100, 8), 1000 + kMinGapMs));
	CHECK(!due(p, 1000, at(100, 0, 100, 8), 1000 + kMinGapMs - 1));
}
