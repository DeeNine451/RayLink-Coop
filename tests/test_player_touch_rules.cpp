// Anomaly Coop unit tests: TZ P50 (Dev 58), players under the map in the narrow tunnel of Cordon -> Garbage
// (xrCoop/coop_player_touch_rules.h, xrCoop/coop_arrival.h).
// The owner, 2026-11-22: in a group transition "the ones that do not fit just spawn under the map"; his decision: at level
// exits and at the places where players appear, player-player collision is off, and it comes back when the player moves a set
// distance away. Both modes: every machine that plays an actor collides it with the other players' avatars (Coop: the host
// and each client; Server: each client), so the rule is one and is asked by that machine for its own actor.
#include "test_util.h"

#include "coop_arrival.h"
#include "coop_player_touch_rules.h"

#include <cmath>
#include <limits>
#include <map>
#include <utility>
#include <vector>

using namespace coop;

namespace
{
// A level graph for arrival::place: ground by 0.7 m cell (the AI map's cell), missing cells are walls or off the map.
struct FakeGround
{
	std::map<std::pair<int, int>, float> cells;
	void set(float x, float z, float y) { cells[key(x, z)] = y; }
	void set_cell(int i, int j, float y) { cells[{i, j}] = y; }
	static std::pair<int, int> key(float x, float z) { return {int(std::floor(x / 0.7f)), int(std::floor(z / 0.7f))}; }
	arrival::Ground fn() const
	{
		return [this](float x, float probe_y, float z, float& ground_y, uint32_t& vertex)
		{
			const auto it = cells.find(key(x, z));
			if (it == cells.end() || it->second > probe_y)
				return false;
			ground_y = it->second;
			vertex = uint32_t(it->first.first * 1000 + it->first.second + 500000);
			return true;
		};
	}
};

// A tunnel along x, 1.4 m wide (two AI cells, z in [-0.7, 0.7)), floor at y = 0, from x = 80 to x = 120. The level
// changer's point (the host's anchor) is in its middle.
FakeGround tunnel()
{
	FakeGround g;
	for (float x = 80.f; x < 120.f; x += 0.7f)
	{
		g.set(x + 0.35f, -0.35f, 0.f);
		g.set(x + 0.35f, 0.35f, 0.f);
	}
	return g;
}

float dist(const arrival::Point& a, const arrival::Point& b)
{
	const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

bool same(const arrival::Point& a, const arrival::Point& b) { return dist(a, b) < 1e-3f; }

// The host's ring of coop_join.cpp host_place_movers: where it writes each mover's character, at the point's height.
const float kRing[][2] = {{1.5f, 0.f}, {0.f, 1.5f}, {-1.5f, 0.f}, {0.f, -1.5f}, {1.5f, 1.5f}, {-1.5f, -1.5f}, {1.5f, -1.5f}};

const float kInf = std::numeric_limits<float>::infinity();

// A tunnel along the diagonal x = z (no wall along a world axis), about 1.4 m wide (the AI cells (i, j) with |i - j| <= 1), floor
// at y = 0, around the point (100, 0, 100). The four axis spots of the host's ring are in its walls, the two diagonal ones in it.
FakeGround diagonal_tunnel()
{
	FakeGround g;
	for (int i = 120; i < 170; ++i)
		for (int j = i - 1; j <= i + 1; ++j)
			g.set_cell(i, j, 0.f);
	return g;
}

// Two capsules touch at about 0.75 m (actor 0.35 m, avatar 0.4 m): closer, the actor's body is pushed out of the avatar's.
constexpr float kTouch = 0.75f;

// One player of a group transition, as another machine sees him: where that machine's world spawns his character (the host's
// blind spot, written into the level change's save) and where his own machine puts his actor (the spot his snapshots tell).
struct Arrived
{
	arrival::Point spawned;
	arrival::Point at;
};

// The host and the movers of one group transition (coop_join.cpp host_place_movers, then each mover's machine
// on_alife_registered: arrival::place). The host stands on the point; mover i gets the ring spot i at the point's height.
std::vector<Arrived> group_arrival(const FakeGround& g, const arrival::Point& anchor, int movers)
{
	std::vector<Arrived> out;
	out.push_back({anchor, anchor});
	for (int i = 0; i < movers; ++i)
	{
		const arrival::Point own{anchor.x + kRing[i % 7][0], anchor.y, anchor.z + kRing[i % 7][1]};
		const arrival::Placed p = arrival::place(own, anchor, g.fn());
		out.push_back({own, p.at});
	}
	return out;
}

// One machine's pair through the arrival, frame by frame as coop_player_touch.cpp frame() runs it: both appeared; the avatar
// stands where it spawned here while its player still loads (no snapshot of his has placed it); then his snapshots put it on
// his spot. True when the two bodies collide on that spot.
bool collides_after_arrival(const arrival::Point& me, const Arrived& him)
{
	bool off = false;
	player_touch::appeared(off);
	for (int frame = 0; frame < 3; ++frame)
		player_touch::collides(off, false, false, player_touch::apart_known(false, dist(me, him.spawned)));
	return player_touch::collides(off, false, false, player_touch::apart_known(true, dist(me, him.at)));
}

// Every machine of the group, every avatar on it: the pairs that stand one in the other with their bodies on (the actor is
// pushed into the walls), and how many of the overlapping pairs had the avatar spawn kApart or more away (the case at stake).
int pushed_pairs(const std::vector<Arrived>& v, int& spawned_far)
{
	int pushed = 0;
	spawned_far = 0;
	for (size_t i = 0; i < v.size(); ++i)
		for (size_t j = 0; j < v.size(); ++j)
		{
			if (i == j || !(dist(v[i].at, v[j].at) < kTouch))
				continue;
			if (dist(v[i].at, v[j].spawned) >= player_touch::kApart)
				++spawned_far;
			if (collides_after_arrival(v[i].at, v[j]))
				++pushed;
		}
	return pushed;
}
} // namespace

TEST(player_touch_tunnel_arrival_puts_the_ones_that_do_not_fit_on_one_spot)
{
	// The cause in Coop, as the code places today (no change here): each mover's machine snaps its own character
	// (arrival::place); a ring spot in the tunnel wall falls back to the FIRST ring spot with ground, the same for all of them.
	const FakeGround g = tunnel();
	const arrival::Point anchor{100.f, 0.f, 0.f};
	arrival::Placed p[4];
	for (int i = 0; i < 4; ++i)
	{
		const arrival::Point own{anchor.x + kRing[i][0], anchor.y, anchor.z + kRing[i][1]};
		p[i] = arrival::place(own, anchor, g.fn());
	}
	CHECK(p[0].how == arrival::How::Snapped);
	CHECK(p[1].how == arrival::How::Moved); // his spot (z +1.5) is in the wall
	CHECK(p[2].how == arrival::How::Snapped);
	CHECK(p[3].how == arrival::How::Moved); // z -1.5: the other wall
	CHECK(same(p[1].at, p[0].at)); // on the first mover
	CHECK(same(p[3].at, p[0].at)); // and the fourth too: three capsules in one place
	for (const arrival::Placed& q : p)
		CHECK(std::fabs(q.at.y - (0.f + arrival::kLift)) < 1e-3f); // every one stands on the AI map's ground, none in the wall
}

TEST(player_touch_players_put_on_one_spot_do_not_collide_until_apart)
{
	// RED before the rule: the stub of today collides every pair always, and the actor is pushed out of the other body
	// (PHSimpleCharacter.cpp InitContact, PHActorCharacter.cpp restrictors, PHMovementControl.cpp UpdateObjectBox) into the
	// walls and the floor of the tunnel.
	bool off = false;
	player_touch::appeared(off); // the second one came into this machine's world on the first one
	CHECK(!player_touch::collides(off, false, false, 0.f));
	CHECK(!player_touch::collides(off, false, false, 0.5f)); // still inside the other capsule
	CHECK(!player_touch::collides(off, false, false, 2.9f)); // walking out of the tunnel one after the other
	CHECK(player_touch::collides(off, false, false, player_touch::kApart)); // 3 m apart: bodies again
	CHECK(!off);
}

TEST(player_touch_collision_back_stays_when_they_come_close_again)
{
	bool off = false;
	player_touch::appeared(off);
	CHECK(player_touch::collides(off, false, false, 10.f)); // he appeared far from me: bodies at once
	CHECK(player_touch::collides(off, false, false, 0.6f)); // later they walk into each other: they bump, as in a usual game
	CHECK(player_touch::collides(off, false, false, 0.f));
}

TEST(player_touch_at_a_level_exit_players_pass_through_each_other)
{
	using namespace player_touch;
	// The near flag of one player: 2 m from the exit's shape (or inside it) is at the exit, back past 4 m is away.
	CHECK(!near_exit(false, kInf)); // no exit on the level
	CHECK(!near_exit(false, 2.5f));
	CHECK(near_exit(false, 2.f));
	CHECK(near_exit(false, 0.f)); // inside the exit's zone
	CHECK(near_exit(true, 3.9f)); // walking off: still at it (no flicker at the edge)
	CHECK(near_exit(true, 4.f));
	CHECK(!near_exit(true, 4.1f));
	// The pair: off while either of the two is at an exit, whatever the distance between them.
	bool off = false;
	player_touch::appeared(off);
	CHECK(collides(off, false, false, 5.f));
	CHECK(!collides(off, true, false, 0.4f)); // I walk into the exit's queue where he stands
	CHECK(!collides(off, false, true, 0.4f)); // he is in the queue, I am not
	CHECK(off);
	CHECK(!collides(off, false, false, 1.f)); // both left the exit together: not yet, they are still one in the other
	CHECK(collides(off, false, false, kApart));
}

TEST(player_touch_appearing_again_switches_the_pair_off)
{
	bool off = false;
	player_touch::appeared(off);
	CHECK(player_touch::collides(off, false, false, 20.f));
	player_touch::appeared(off); // he went to another level and came back, or my actor arrived anew
	CHECK(!player_touch::collides(off, false, false, 1.f));
	CHECK(player_touch::collides(off, false, false, 3.5f));
}

TEST(player_touch_numbers_that_are_not_numbers_never_switch_collision_on)
{
	const float nan = std::numeric_limits<float>::quiet_NaN();
	bool off = false;
	player_touch::appeared(off);
	CHECK(!player_touch::collides(off, false, false, nan));
	CHECK(off);
	CHECK(player_touch::near_exit(true, nan)); // no information: the flag stays as it was
	CHECK(!player_touch::near_exit(false, nan));
}

TEST(player_touch_an_avatar_its_player_has_not_placed_yet_keeps_the_pair_off)
{
	// Review 2026-11-23: an avatar stands where this machine's world spawned it (in a group arrival the host's blind ring spot)
	// until its player's snapshots are played; that spot is not where the player is, and an on pair stays on however close.
	using namespace player_touch;
	bool off = false;
	appeared(off);
	CHECK(!collides(off, false, false, apart_known(false, 3.35f))); // spawned 3.35 m off, its player still loading
	CHECK(off);
	CHECK(!collides(off, false, false, apart_known(false, 40.f))); // however far: not his place yet
	CHECK(!collides(off, false, false, apart_known(true, 0.f))); // his snapshots put it on my spot: one in the other
	CHECK(!collides(off, false, false, apart_known(true, 2.9f)));
	CHECK(collides(off, false, false, apart_known(true, kApart))); // 3 m apart where they really stand: bodies again
	CHECK(collides(off, false, false, apart_known(true, 0.f))); // and they bump as in a usual game
	bool lone = false;
	appeared(lone); // an arrival alone, 10 m from me, his first snapshot played
	CHECK(collides(lone, false, false, apart_known(true, 10.f)));
}

TEST(player_touch_group_arrival_in_a_diagonal_tunnel_pushes_nobody_into_the_walls)
{
	// The P50 case itself: host and 4 movers into a 1.4 m tunnel that is not along a world axis. All four ring spots of the
	// movers are in the walls, so each mover's machine puts him on the first ring spot with ground: all four on one spot. On a
	// mover's machine the avatars of movers 2 and 3 spawn on their blind spots 3.36 m away, then come onto his spot.
	const FakeGround g = diagonal_tunnel();
	const arrival::Point anchor{100.f, 0.f, 100.f};
	const std::vector<Arrived> v = group_arrival(g, anchor, 4);
	for (int i = 1; i <= 4; ++i)
		CHECK(v[i].at.y > 0.f && dist(v[i].at, v[1].at) < 1e-3f); // on the ground, all on one spot
	int spawned_far = 0;
	CHECK_EQ(pushed_pairs(v, spawned_far), 0);
	CHECK_EQ(spawned_far, 6); // (0,2) (0,3) (1,2) (1,3) (2,3) (3,2): the case is there
}

TEST(player_touch_group_arrival_of_six_in_a_straight_tunnel_pushes_nobody_into_the_walls)
{
	// A tunnel along x: with 6 movers the ring spot 5 (-1.5, -1.5) is 3.35 m from the spot 0 where five of them stand.
	const FakeGround g = tunnel();
	const arrival::Point anchor{100.f, 0.f, 0.f};
	const std::vector<Arrived> v = group_arrival(g, anchor, 6);
	int spawned_far = 0;
	CHECK_EQ(pushed_pairs(v, spawned_far), 0);
	CHECK_EQ(spawned_far, 4); // mover 5's avatar on the machines of movers 0, 1, 3 and 4
}

TEST(player_touch_only_bodies_of_two_players_pass_through)
{
	using player_touch::bodies_meet;
	// (a is a player, a passes players, b is a player, b passes players), as the engine's collide class bits read them
	CHECK(!bodies_meet(true, false, true, true)); // my actor and an avatar whose pair is off
	CHECK(!bodies_meet(true, true, true, false));
	CHECK(bodies_meet(true, false, true, false)); // my actor and an avatar whose pair is on
	CHECK(bodies_meet(false, false, true, true)); // an NPC and an avatar whose pair is off: untouched
	CHECK(bodies_meet(true, true, false, false)); // ... and the other way
	CHECK(bodies_meet(false, false, false, false)); // single player: no bits anywhere, stock
}

// The thresholds leave room for the group ring, the capsules and the delay of an avatar.
// The group ring: its four axis spots are within its diameter of each other. The diagonal ones are farther (up to 4.24 m), and
// an avatar's spawn spot may be one of them while its player stands on mine: apart_known, the group arrival tests above.
static_assert(player_touch::kApart >= 2.f * arrival::kRing, "kApart covers the axis spots of the host's ring");
// Two capsules touch at about 0.75 m (actor 0.35 m, avatar 0.4 m; the actor's restrictor 0.25 m + 0.4 m is less); the avatar
// is drawn up to ~200 ms late (100 ms interpolation + the network), 1.6 m at a sprint of 8 m/s.
static_assert(player_touch::kApart - 0.75f >= 1.6f, "kApart leaves room for the capsules and the avatar's delay");
static_assert(player_touch::kExitFar > player_touch::kExitNear && player_touch::kExitNear > 0.f, "a band, not an edge");
