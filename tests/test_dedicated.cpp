// Anomaly Coop unit tests: the dedicated host, the pure part (xrCoop/coop_dedicated_rules.h). The keys, the command that starts a world, which
// save -coop_load last means, what a line of the console window is and which lines of the log it shows.
#include "test_util.h"

#include "coop_dedicated_rules.h"
#include "coop_protocol.h"
#include "coop_roles.h"

#include <string>
#include <vector>

using namespace coop;
using namespace coop::dedicated;

// ---------------------------------------------------------------- the keys

TEST(dedicated_key_is_a_whole_word)
{
	CHECK(has_key("-coop_dedicated"));
	CHECK(has_key("-fsltx a.ltx -coop_dedicated 27961 -coop_new"));
	CHECK(!has_key(nullptr));
	CHECK(!has_key(""));
	CHECK(!has_key("-coop_dedicated_x"));
	CHECK(!has_key("x-coop_dedicated"));
	CHECK(!has_key("-coop_host 27960"));
}

TEST(dedicated_port_is_the_session_default_without_a_value)
{
	CHECK_EQ(int(dedicated::kDefaultPort), int(coop::kDefaultPort));
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated -coop_new", a, why));
	CHECK_EQ(int(a.port), int(coop::kDefaultPort));
	CHECK(a.world == World::New);
}

TEST(dedicated_takes_its_port)
{
	Args a;
	std::string why;
	CHECK(parse_args("-fsltx fsgame_d.ltx -coop_dedicated 28000 -coop_load last -nosplashwindow", a, why));
	CHECK_EQ(int(a.port), 28000);
	CHECK(a.world == World::Load);
	CHECK_EQ(a.save, std::string("last"));
}

TEST(dedicated_refuses_a_bad_port)
{
	Args a;
	std::string why;
	CHECK(!parse_args("-coop_dedicated 70000", a, why));
	CHECK(!why.empty());
	why.clear();
	CHECK(!parse_args("-coop_dedicated 0", a, why));
	CHECK(!why.empty());
	CHECK(!parse_args("-coop_dedicated 12x", a, why));
}

TEST(dedicated_without_a_world_waits_for_the_operator)
{
	Args a;
	a.world = World::New;
	std::string why;
	CHECK(parse_args("-coop_dedicated", a, why));
	CHECK(a.world == World::None);
}

TEST(dedicated_new_and_load_exclude_each_other)
{
	Args a;
	std::string why;
	CHECK(!parse_args("-coop_dedicated -coop_new -coop_load x", a, why));
	CHECK(!why.empty());
}

TEST(dedicated_load_needs_a_name)
{
	Args a;
	std::string why;
	CHECK(!parse_args("-coop_dedicated -coop_load", a, why));
	CHECK(!parse_args("-coop_dedicated -coop_load -nosound", a, why));
}

TEST(dedicated_save_names_may_hold_blanks)
{
	Args a;
	std::string why;
	CHECK(parse_args("-coop_dedicated -coop_load stalker - autosave -nosound", a, why));
	CHECK_EQ(a.save, std::string("stalker - autosave"));
	CHECK(parse_args("-coop_dedicated -coop_load \"my world -old\" -nosound", a, why));
	CHECK_EQ(a.save, std::string("my world -old"));
	CHECK(parse_args("-coop_dedicated -coop_load coop_auto_6ae366d4-db00_1", a, why));
	CHECK_EQ(a.save, std::string("coop_auto_6ae366d4-db00_1"));
}

TEST(dedicated_a_save_name_stays_in_its_folder)
{
	CHECK(save_name_ok("stalker - autosave"));
	CHECK(save_name_ok("coop_auto_6ae366d4-db00_1"));
	CHECK(!save_name_ok(""));
	CHECK(!save_name_ok(".."));
	CHECK(!save_name_ok("..\\..\\x"));
	CHECK(!save_name_ok("a/b"));
	CHECK(!save_name_ok("x) client(evil"));
	CHECK(!save_name_ok("c:x"));
	CHECK(!save_name_ok(std::string(201, 'a')));
}

// ---------------------------------------------------------------- the world

TEST(dedicated_start_lines)
{
	CHECK_EQ(start_line(World::New, ""), std::string("start server(all/single/alife/new) client(localhost)"));
	CHECK_EQ(start_line(World::Load, "my world"), std::string("start server(my world/single/alife/load) client(localhost)"));
}

TEST(dedicated_last_is_the_newest_file)
{
	CHECK_EQ(newest_save({}), std::string());
	CHECK_EQ(newest_save({{"a", 5}, {"b", 9}, {"c", 7}}), std::string("b"));
	CHECK_EQ(newest_save({{"only", 0}}), std::string("only"));
}

TEST(dedicated_restore_lists_the_autosaves_newest_first)
{
	const std::vector<SaveFile> list = restore_list({{"stalker - autosave", 90}, {"coop_auto_a_1", 5}, {"coop_auto_tmp", 99}, {"coop_auto_bak", 98}, {"coop_auto_a_2", 7}, {"coop_join_1", 50}});
	CHECK_EQ(list.size(), size_t(2));
	CHECK_EQ(list[0].name, std::string("coop_auto_a_2"));
	CHECK_EQ(list[1].name, std::string("coop_auto_a_1"));
}

TEST(dedicated_restore_takes_a_number_or_a_name)
{
	const std::vector<SaveFile> list = {{"coop_auto_a_2", 7}, {"coop_auto_a_1", 5}};
	CHECK_EQ(pick_restore(list, "1"), std::string("coop_auto_a_2"));
	CHECK_EQ(pick_restore(list, "2"), std::string("coop_auto_a_1"));
	CHECK_EQ(pick_restore(list, "coop_auto_a_1"), std::string("coop_auto_a_1"));
	CHECK_EQ(pick_restore(list, "3"), std::string());
	CHECK_EQ(pick_restore(list, "0"), std::string());
	CHECK_EQ(pick_restore(list, ""), std::string());
	CHECK_EQ(pick_restore(list, "stalker - autosave"), std::string());
}

// ---------------------------------------------------------------- the console window

TEST(dedicated_lines_empty_and_quit)
{
	CHECK(parse_line("").kind == Line::Empty);
	CHECK(parse_line("   \t \r\n").kind == Line::Empty);
	CHECK(parse_line("quit").kind == Line::Quit);
	CHECK(parse_line("  exit \r\n").kind == Line::Quit);
	CHECK(parse_line("stop").kind == Line::Quit);
}

TEST(dedicated_lines_go_is_the_accept_of_a_level_exit)
{
	const Parsed p = parse_line("/go");
	CHECK(p.kind == Line::Command);
	CHECK_EQ(p.text, std::string("coop_accept_transition"));
}

TEST(dedicated_lines_commands_keep_their_arguments)
{
	const Parsed p = parse_line("  coop_kick 3 too loud \r\n");
	CHECK(p.kind == Line::Command);
	CHECK_EQ(p.text, std::string("coop_kick 3 too loud"));
}

TEST(dedicated_lines_say_is_a_chat_line)
{
	const Parsed p = parse_line("say restart in five");
	CHECK(p.kind == Line::Chat);
	CHECK_EQ(p.text, std::string("restart in five"));
}

TEST(dedicated_lines_an_unknown_slash_is_said_to_be_one)
{
	const Parsed p = parse_line("/kick 2");
	CHECK(p.kind == Line::Unknown);
	CHECK_EQ(p.text, std::string("/kick 2"));
}

// ---------------------------------------------------------------- the log in the window

TEST(dedicated_log_errors_always_show)
{
	CHECK(log_shown("! [coop] cannot host on port 27960: busy", 0));
	CHECK(log_shown("FATAL ERROR", 0));
	CHECK(log_shown("[error]Arguments     : x", 0));
	CHECK(!log_shown("[coop] session up", 0));
}

TEST(dedicated_log_the_session_shows_the_noise_does_not)
{
	CHECK(log_shown("[coop] map server 1 starts for level 3", 1));
	CHECK(log_shown("* [coop] map server: WARP device", 1));
	CHECK(log_shown("[coop-game] game 'x' is in force", 1));
	CHECK(log_shown("* [x-ray]: Starting Main Loop", 1));
	CHECK(!log_shown("gamedata: 'anims\\camera_effects\\item_use_fast.anm'", 1));
	CHECK(!log_shown("found variable hold to unlocal", 1));
	CHECK(!log_shown("", 1));
	CHECK(!log_shown(nullptr, 1));
}

TEST(dedicated_log_everything_at_the_top_level)
{
	CHECK(log_shown("gamedata: 'x'", 2));
}

// ---------------------------------------------------------------- the role

TEST(dedicated_roles_lead_the_world_and_play_nothing)
{
	const uint8_t r = dedicated_roles();
	CHECK(has(r, ProcessRole::WorldServer));
	CHECK(has(r, ProcessRole::MapAuthority));
	CHECK(!has(r, ProcessRole::Player));
	CHECK(!has(r, ProcessRole::Mirror));
	CHECK(!has(r, ProcessRole::MapServer));
	CHECK(!has(r, ProcessRole::WorldClient));
	CHECK(uint8_t(r | uint8_t(ProcessRole::Player)) == host_roles());
}
