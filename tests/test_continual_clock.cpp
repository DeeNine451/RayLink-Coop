// Anomaly Coop unit tests: the UI's clock while the game window is away (coop_continual_clock.h).
// Live 2026-11-01: the host went silent while a client's fullscreen game was alt-tabbed out. The main menu was built in that
// time; back in the game the clock jumped behind the moment of the menu, and all its titles went to alpha 0 on the first move of
// the pointer.
#include "test_util.h"

#include "coop_continual_clock.h"

#include <cstdint>

using coop::continual_ms;

namespace
{
// What CRenderDevice::OnWM_Activate keeps, driven by the same steps.
struct Window
{
	uint32_t inactive_total = 0;
	uint32_t inactive_start = 0;
	bool active = true;

	void away(uint32_t timer)
	{
		active = false;
		inactive_start = timer;
	}
	void back(uint32_t timer)
	{
		active = true;
		inactive_total += timer - inactive_start;
	}
	uint32_t read(uint32_t timer) const { return continual_ms(timer, inactive_total, inactive_start, active); }
};
} // namespace

TEST(continual_runs_with_the_timer_in_the_foreground)
{
	Window w;
	CHECK(w.read(5000) == 5000);
	CHECK(w.read(5016) == 5016);
}

TEST(continual_never_goes_back_when_the_window_returns)
{
	Window w;
	CHECK(w.read(1000) == 1000);
	w.away(1000);
	uint32_t last = w.read(1000);
	for (uint32_t t = 1016; t < 135000; t += 16)
	{
		const uint32_t now = w.read(t);
		CHECK(now >= last);
		last = now;
	}
	w.back(135000);
	CHECK(w.read(135000) >= last);
	CHECK(w.read(135016) >= last);
}

TEST(continual_takes_no_time_from_the_span_away)
{
	Window w;
	w.away(1000);
	w.back(61000);
	CHECK(w.read(61000) == 1000); // the span is left out, as it always was
	CHECK(w.read(61500) == 1500); // and the clock runs on from there
}

TEST(continual_stands_while_the_window_is_away)
{
	Window w;
	w.away(1000);
	CHECK(w.read(2000) == 1000);
	CHECK(w.read(90000) == 1000);
}

TEST(continual_a_menu_built_while_away_is_not_in_the_future)
{
	Window w;
	w.away(1000);
	const uint32_t built = w.read(135000); // the session ended meanwhile: this is the view's t0
	w.back(200000);
	CHECK(w.read(200000) >= built);
}

TEST(continual_two_trips_away_add_up)
{
	Window w;
	w.away(1000);
	w.back(2000);
	w.away(3000);
	CHECK(w.read(3500) == 2000);
	w.back(4000);
	CHECK(w.read(4000) == 2000);
	CHECK(w.read(4100) == 2100);
}

TEST(continual_a_game_that_starts_behind_other_windows_stands_at_zero)
{
	Window w; // CRenderDevice starts inactive, the first activation takes the time since the timer started
	w.active = false;
	CHECK(w.read(7000) == 0);
	w.back(9000);
	CHECK(w.read(9000) == 0);
	CHECK(w.read(9016) == 16);
}

TEST(continual_survives_the_timer_wrapping_u32)
{
	Window w;
	const uint32_t near_wrap = 0xFFFFF000u;
	w.away(near_wrap);
	const uint32_t held = w.read(near_wrap + 0x2000u);
	w.back(near_wrap + 0x2000u);
	CHECK(w.read(near_wrap + 0x2000u) == held);
	CHECK(w.read(near_wrap + 0x2010u) == held + 0x10u);
}
