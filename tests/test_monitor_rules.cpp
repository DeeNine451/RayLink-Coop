#include "test_util.h"

#include "coop_device_rules.h"

using coop::device::auto_startup_display;
using coop::device::defer_monitor_change;
using coop::device::prefer_matching_startup_monitor;
using coop::device::startup_display;

TEST(monitor_policy_fullscreen_auto_uses_the_unique_match_for_the_saved_mode)
{
	CHECK(prefer_matching_startup_monitor(true, false, 1));
	CHECK(!prefer_matching_startup_monitor(true, true, 1));
}

TEST(monitor_policy_auto_keeps_cursor_placement_without_a_unique_fullscreen_match)
{
	CHECK(!prefer_matching_startup_monitor(true, false, 0));
	CHECK(!prefer_matching_startup_monitor(true, false, 2));
	CHECK(!prefer_matching_startup_monitor(false, false, 1));
}

TEST(monitor_policy_coop_host_defers_switches_with_a_level)
{
	CHECK(!defer_monitor_change(false, false));
	CHECK(defer_monitor_change(true, false));
}

TEST(monitor_policy_server_player_defers_switches_with_a_level)
{
	CHECK(defer_monitor_change(true, false));
	CHECK(!defer_monitor_change(false, false));
}

TEST(monitor_policy_single_player_keeps_the_live_switch)
{
	CHECK(!defer_monitor_change(false, true));
	CHECK(!defer_monitor_change(true, true));
}

// auto_startup_display: the facts InitMonitor reads (desktop sizes, the cursor display's mode list) -> the display to start on.
namespace
{
const startup_display kMi1440{2560, 1440, false};      // Mi Monitor
const startup_display kPortrait1080{1080, 1920, false}; // XV242Y turned to portrait, no 2560x1440 mode
const startup_display kDesk1080{1920, 1080, false};
} // namespace

TEST(monitor_auto_owner_start_takes_the_only_display_with_the_saved_desktop)
{
	// 2026-11-21 20:46: vid_mode 2560x1440 fullscreen, the cursor on the portrait display
	const startup_display displays[] = {kMi1440, kPortrait1080};
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kPortrait1080, displays, 2), 0);
	const startup_display reversed[] = {kPortrait1080, kMi1440};
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kPortrait1080, reversed, 2), 1);
}

TEST(monitor_auto_keeps_the_cursor_display_that_lists_the_saved_mode)
{
	// 1920x1080 fullscreen on a 2560x1440 desktop is an ordinary choice; a 1080p second display must not take the game
	const startup_display cursor{2560, 1440, true};
	const startup_display displays[] = {cursor, kDesk1080};
	CHECK_EQ(auto_startup_display(true, 1920, 1080, cursor, displays, 2), -1);
}

TEST(monitor_auto_keeps_the_cursor_without_a_single_match_or_outside_exclusive_fullscreen)
{
	const startup_display two_1440[] = {kPortrait1080, kMi1440, kMi1440};
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kPortrait1080, two_1440, 3), -1); // ambiguous
	const startup_display none[] = {kPortrait1080, kDesk1080};
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kPortrait1080, none, 2), -1); // nothing has it
	const startup_display displays[] = {kMi1440, kPortrait1080};
	CHECK_EQ(auto_startup_display(false, 2560, 1440, kPortrait1080, displays, 2), -1); // borderless / windowed
	CHECK_EQ(auto_startup_display(true, 0, 0, kPortrait1080, displays, 2), -1);         // no vid_mode yet (splash)
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kPortrait1080, nullptr, 0), -1);    // list not filled
	CHECK_EQ(auto_startup_display(true, 2560, 1440, kMi1440, displays, 2), -1);         // the cursor's desktop fits
}
