#include "test_util.h"

#include "coop_rules.h"

TEST(machine_info_pda_open_and_close_are_local)
{
	CHECK(coop::rules::is_machine_info("ui_pda"));
	CHECK(coop::rules::is_machine_info("ui_pda_hide"));
	CHECK(!coop::rules::is_machine_info("ui_pda_hide_quest"));
	CHECK(!coop::rules::is_machine_info("UI_PDA_HIDE"));
}
