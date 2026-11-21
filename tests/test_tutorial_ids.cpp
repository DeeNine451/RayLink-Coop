#include "test_util.h"

#include "coop_ui_rules.h"

#include <limits>

TEST(ui_tutorial_instance_ids_reserve_zero_for_no_active_sequence)
{
	uint32_t serial = 0;
	CHECK_EQ(coop::ui_rules::next_tutorial_id(serial), 1u);
	CHECK_EQ(coop::ui_rules::next_tutorial_id(serial), 2u);
	serial = std::numeric_limits<uint32_t>::max();
	CHECK_EQ(coop::ui_rules::next_tutorial_id(serial), 1u);
}
