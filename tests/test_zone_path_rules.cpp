// Anomaly Coop unit tests: the wander path of a moving anomaly zone across machines (xrCoop/coop_zone_path_rules.h; F4 G11-2,
// review m19:1: every machine rolled its own Ghost path of Dynamic Anomalies Overhaul and stepped it by its own frame time).
#include "test_util.h"

#include "coop_zone_path_rules.h"

#include <cmath>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

using namespace coop::zonepath;
using coop::Reader;
using coop::Writer;

namespace
{
// A path DAO can roll: random_choice(0, 45, 90, 135, 180), i_step 2 -> j_step random_choice(1, 3), two amplitudes
// random() * 2.5 + 0.5 with a sign.
Path ghost()
{
	Path p;
	p.id = 4242;
	p.section_hash = name_hash("zone_mine_ghost");
	p.origin[0] = 120.5f;
	p.origin[1] = -3.25f;
	p.origin[2] = 77.f;
	p.i0 = 90;
	p.i_step = 2;
	p.j_step = 3;
	p.x_mod = 2.2f;
	p.z_mod = -1.4f;
	return p;
}

// The native suite can also check the engine call sites that it cannot link.
std::string engine_source(const char* name)
{
	const std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	std::ifstream file(here.substr(0, slash) + "/../engine/src/xrGame/coop/" + name, std::ios::binary);
	return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

bool near(float a, float b) { return std::fabs(a - b) < 1e-4f; }

bool same_point(const Point& a, const Point& b) { return near(a.x, b.x) && near(a.y, b.y) && near(a.z, b.z); }

// Flat ground 0.1 m under the spawn point.
struct Flat
{
	int* calls;
	bool operator()(float, float y, float, float& out) const
	{
		++*calls;
		out = y - 0.1f;
		return true;
	}
};

// The stock step of drx_da_main (:2473-2475) after `frames` frames of `frame_ms`: i = floor(i + i_step * min(50, dt) / 22).
uint32_t stock_i(const Path& p, uint32_t frame_ms, uint32_t frames)
{
	double i = p.i0;
	const double delta = double(frame_ms < 50 ? frame_ms : 50) / 22.0;
	for (uint32_t f = 0; f < frames; ++f)
	{
		if (i >= 360.0)
			i = std::fmod(i, 360.0);
		i = std::floor(i + p.i_step * delta);
	}
	return uint32_t(std::fmod(i, 360.0));
}
} // namespace

TEST(zone_path_accepts_every_roll_of_dao)
{
	const uint16_t starts[] = {0, 45, 90, 135, 180};
	const uint8_t i_steps[] = {1, 2, 3};
	const uint8_t j_steps[3][2] = {{2, 3}, {1, 3}, {2, 4}}; // :2417-2423
	for (uint16_t i0 : starts)
		for (int s = 0; s < 3; ++s)
			for (uint8_t j : j_steps[s])
				for (float m : {0.5f, 1.75f, 2.9999f, -0.5f, -3.f})
				{
					Path p = ghost();
					p.i0 = i0;
					p.i_step = i_steps[s];
					p.j_step = j;
					p.x_mod = m;
					p.z_mod = -m;
					CHECK(valid(p));
				}
}

TEST(zone_path_refuses_what_dao_cannot_roll)
{
	const float nan = std::numeric_limits<float>::quiet_NaN();
	const float inf = std::numeric_limits<float>::infinity();
	Path p = ghost();
	p.i0 = 360;
	CHECK(!valid(p));
	p = ghost();
	p.i_step = 0;
	CHECK(!valid(p));
	p.i_step = 4;
	CHECK(!valid(p));
	p = ghost();
	p.j_step = 0;
	CHECK(!valid(p));
	p.j_step = 5;
	CHECK(!valid(p));
	for (float bad : {0.2f, 3.5f, -40.f, nan, inf})
	{
		p = ghost();
		p.x_mod = bad;
		CHECK(!valid(p));
		p = ghost();
		p.z_mod = bad;
		CHECK(!valid(p));
	}
	for (int k = 0; k < 3; ++k)
	{
		p = ghost();
		p.origin[k] = nan;
		CHECK(!valid(p));
		p.origin[k] = 2e6f;
		CHECK(!valid(p));
	}
}

TEST(zone_path_period_brings_both_angles_back)
{
	struct Case
	{
		uint8_t i, j;
		uint32_t ticks;
	};
	const Case cases[] = {{1, 2, 360}, {1, 3, 360}, {2, 1, 360}, {2, 3, 360}, {3, 2, 360}, {3, 4, 360}, {2, 4, 180},
		{3, 3, 120}, {2, 2, 180}};
	for (const Case& c : cases)
	{
		Path p = ghost();
		p.i_step = c.i;
		p.j_step = c.j;
		CHECK_EQ(period_ticks(p), c.ticks);
		CHECK_EQ(period_ms(p), c.ticks * kTickMs);
		uint32_t i0 = 0, j0 = 0, i1 = 0, j1 = 0;
		angles(p, 0, i0, j0);
		angles(p, period_ticks(p), i1, j1);
		CHECK_EQ(i1, i0);
		CHECK_EQ(j1, j0);
		bool earlier = false; // no tick before the period is back at the start
		for (uint32_t t = 1; t < period_ticks(p); ++t)
		{
			angles(p, t, i1, j1);
			earlier = earlier || (i1 == i0 && j1 == j0);
		}
		CHECK(!earlier);
	}
}

TEST(zone_path_angles_and_sine_are_the_mods)
{
	const Path p = ghost(); // i0 90, i_step 2, j_step 3
	uint32_t i = 0, j = 0;
	angles(p, 0, i, j);
	CHECK_EQ(i, 90u);
	CHECK_EQ(j, 0u);
	angles(p, 5, i, j);
	CHECK_EQ(i, 100u);
	CHECK_EQ(j, 15u);
	angles(p, 140, i, j); // past the full circle: wrapped like `i % full_circle`
	CHECK_EQ(i, 10u);
	CHECK_EQ(j, 60u);
	float x = 0.f, z = 0.f;
	xz_at(p, 140, x, z);
	CHECK(near(x, p.origin[0] + float(std::sin(10 * 0.0174533)) * p.x_mod));
	CHECK(near(z, p.origin[2] + float(std::sin(60 * 0.0174533)) * p.z_mod));
	// one tick is 22 ms (the mod's divisor), the tick wraps at the period
	CHECK_EQ(tick_at(p, 0), 0u);
	CHECK_EQ(tick_at(p, 21), 0u);
	CHECK_EQ(tick_at(p, 22), 1u);
	CHECK_EQ(tick_at(p, uint64_t(period_ms(p)) * 1000 + 44), 2u);
	CHECK_EQ(phase_ms(p, uint64_t(period_ms(p)) * 7 + 100), 100u);
}

// Review m19:1: "participants get different trajectories". Two viewers at 60 and 30 frames a second and the host at 144 put the
// zone at the same point at the same moment; the stock per-frame step does not.
TEST(zone_path_frame_rates_agree_where_the_stock_step_drifts)
{
	const Path p = ghost();
	int calls = 0;
	const std::vector<float> ys = heights(p, Flat{&calls});
	for (uint64_t t = 0; t <= 60000; t += 528) // 528 ms: a frame of 16 ms and of 33 ms both end there
	{
		Point fast, slow, host;
		// each machine asks at its own frame ends; at t all three have a frame
		for (uint64_t f = 0; f <= t; f += 16)
			fast = point_at(p, ys, f);
		for (uint64_t f = 0; f <= t; f += 33)
			slow = point_at(p, ys, f);
		host = point_at(p, ys, t);
		CHECK(same_point(fast, host));
		CHECK(same_point(slow, host));
	}
	// what the mod does: the same 10.56 s at 16 ms and at 33 ms frames ends at different angles (and at 16 ms frames an i_step
	// of 1 never moves: floor(i + 0.73) == i)
	CHECK(stock_i(p, 16, 660) != stock_i(p, 33, 320));
	Path one = p;
	one.i_step = 1;
	CHECK_EQ(stock_i(one, 16, 660), uint32_t(one.i0));
	uint32_t i = 0, j = 0;
	angles(one, tick_at(one, 10560), i, j);
	CHECK(i != uint32_t(one.i0)); // the rule moves it at the mod's intended speed
}

// A player who comes in when the path has run a while: he gets the phase it had when the word left and his own clock from
// then on. His Ghost is where the host's is, and where the one of a player who saw it start is.
TEST(zone_path_late_joiner_resumes_the_phase)
{
	const Path p = ghost();
	int calls = 0;
	const std::vector<float> ys = heights(p, Flat{&calls});
	const uint64_t host_start = 1000; // the host's clock
	const uint64_t sent_at = host_start + 61234; // the host's clock when the word for the late player left
	const uint32_t phase = phase_ms(p, run_at(host_start, 0, sent_at));
	CHECK(phase < period_ms(p));

	// the word on the wire
	Writer w(64);
	write_path(w, p, phase);
	Reader r(w.ptr(), w.size());
	Path got;
	uint32_t got_phase = 0;
	REQUIRE(read_path(r, got, got_phase));
	CHECK_EQ(got_phase, phase);

	const uint64_t late_received = 9000000; // another machine, another clock
	const uint64_t early_received = 4321; // a player who got it with phase 0 when it started
	for (uint64_t later = 0; later <= 20000; later += 7)
	{
		const Point h = point_at(p, ys, run_at(host_start, 0, sent_at + later));
		const Point late = point_at(got, ys, run_at(late_received, got_phase, late_received + later));
		const Point early = point_at(p, ys, run_at(early_received, 0, early_received + (sent_at - host_start) + later));
		CHECK(same_point(h, late));
		CHECK(same_point(h, early));
	}
	// not back at the start: the late player resumes mid-path
	CHECK(!same_point(point_at(got, ys, run_at(late_received, got_phase, late_received)), point_at(p, ys, 0)));
	// a clock read before the word came does not run it back
	CHECK_EQ(run_at(late_received, got_phase, late_received - 50), uint64_t(got_phase));
}

TEST(zone_path_heights_follow_the_mods_rule)
{
	Path p = ghost();
	p.i0 = 0;
	p.i_step = 1;
	p.j_step = 2;
	p.x_mod = 3.f;
	p.z_mod = 0.5f;
	const float spawn_y = p.origin[1];
	{
		int calls = 0;
		const std::vector<float> ys = heights(p, Flat{&calls});
		CHECK_EQ(ys.size(), size_t(period_ticks(p)));
		CHECK_EQ(calls, int(period_ticks(p))); // one level-graph question per tick of the period
		bool all = true;
		for (float y : ys)
			all = all && near(y, spawn_y - 0.1f);
		CHECK(all);
	}
	{
		// a roof 2 m up where x > origin + 1.5: the step onto it is more than 0.5 m, the zone stays at the spawn height there,
		// and it follows the ground again where the ground is near
		auto roof = [&](float x, float y, float, float& out) {
			out = x > p.origin[0] + 1.5f ? y + 2.f : y - 0.2f;
			return true;
		};
		const std::vector<float> ys = heights(p, roof);
		bool ok = true;
		for (uint32_t k = 0; k < period_ticks(p); ++k)
		{
			float x = 0.f, z = 0.f;
			xz_at(p, k, x, z);
			const float want = x > p.origin[0] + 1.5f ? spawn_y : spawn_y - 0.2f;
			ok = ok && near(ys[k], want);
		}
		CHECK(ok);
		// the same answer twice: every machine builds the same table
		CHECK(heights(p, roof) == ys);
	}
	{
		// no level graph under the point: the spawn height
		auto none = [](float, float, float, float&) { return false; };
		const std::vector<float> ys = heights(p, none);
		bool all = true;
		for (float y : ys)
			all = all && y == spawn_y;
		CHECK(all);
		// and a table that is not there gives the spawn height too
		CHECK(near(point_at(p, std::vector<float>(), 5000).y, spawn_y));
	}
}

TEST(zone_path_wire_round_trip)
{
	const Path in = ghost();
	Writer w(64);
	write_path(w, in, 777);
	Reader r(w.ptr(), w.size());
	Path out;
	uint32_t phase = 0;
	REQUIRE(read_path(r, out, phase));
	CHECK_EQ(out.id, in.id);
	CHECK_EQ(out.section_hash, in.section_hash);
	CHECK(out.origin[0] == in.origin[0] && out.origin[1] == in.origin[1] && out.origin[2] == in.origin[2]);
	CHECK_EQ(out.i0, in.i0);
	CHECK_EQ(out.i_step, in.i_step);
	CHECK_EQ(out.j_step, in.j_step);
	CHECK(out.x_mod == in.x_mod && out.z_mod == in.z_mod);
	CHECK_EQ(phase, 777u);
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(zone_path_wire_refuses_a_broken_word)
{
	{
		// cut short
		Writer w(64);
		write_path(w, ghost(), 10);
		Reader r(w.ptr(), w.size() - 3);
		Path out;
		uint32_t phase = 0;
		CHECK(!read_path(r, out, phase));
	}
	{
		// a phase past the period
		const Path p = ghost();
		Writer w(64);
		write_path(w, p, period_ms(p));
		Reader r(w.ptr(), w.size());
		Path out;
		uint32_t phase = 0;
		CHECK(!read_path(r, out, phase));
	}
	{
		// a step the mod never rolls
		Path p = ghost();
		p.j_step = 9;
		Writer w(64);
		write_path(w, p, 0);
		Reader r(w.ptr(), w.size());
		Path out;
		uint32_t phase = 0;
		CHECK(!read_path(r, out, phase));
	}
	{
		// an amplitude that would throw the zone across the map
		Path p = ghost();
		p.x_mod = 500.f;
		Writer w(64);
		write_path(w, p, 0);
		Reader r(w.ptr(), w.size());
		Path out;
		uint32_t phase = 0;
		CHECK(!read_path(r, out, phase));
	}
}

TEST(zone_path_authority_keeps_a_valid_start_after_a_slow_load)
{
	const std::string source = engine_source("coop_objects.cpp");
	const size_t first = source.find("void host_take_paths(u64 now)");
	REQUIRE(first != std::string::npos);
	const size_t last = source.find("void host_paths()", first);
	REQUIRE(last != std::string::npos);
	const std::string take = source.substr(first, last - first);

	// The enqueue timestamp sets the phase. Zone identity alone decides whether the queue entry is still usable.
	const size_t timestamp = take.find("run.base_ms = s.at;");
	REQUIRE(timestamp != std::string::npos);
	CHECK_EQ(take.find("s.at"), timestamp + sizeof("run.base_ms = ") - 1);
	CHECK(take.find("s.at", timestamp + sizeof("run.base_ms = s.at;") - 1) == std::string::npos);
	CHECK(take.find("zonepath::same_zone(") < timestamp);

	const Path p = ghost();
	const uint64_t queued_at = 1000;
	const uint64_t first_frame = queued_at + 125000;
	CHECK(same_zone(p.section_hash, p.section_hash, p.origin, p.origin));
	CHECK_EQ(run_at(queued_at, 0, first_frame), uint64_t(125000));
	CHECK(tick_at(p, run_at(queued_at, 0, first_frame)) != 0u);
}

TEST(zone_path_viewer_puts_only_the_right_copy_on_it)
{
	const Path p = ghost();
	float pos[3] = {p.origin[0] + 3.f, p.origin[1] + 0.4f, p.origin[2] - 3.f}; // where a Ghost can be on its path
	CHECK(same_zone(p.section_hash, name_hash("zone_mine_ghost"), p.origin, pos));
	CHECK(!same_zone(p.section_hash, name_hash("zone_mine_electric"), p.origin, pos)); // another zone under that id
	pos[0] = p.origin[0] + 25.f;
	CHECK(!same_zone(p.section_hash, p.section_hash, p.origin, pos)); // far from the path's origin
	pos[0] = std::numeric_limits<float>::quiet_NaN();
	CHECK(!same_zone(p.section_hash, p.section_hash, p.origin, pos));
	CHECK(name_hash("zone_mine_ghost") != name_hash("zone_mine_ghosT"));
}
