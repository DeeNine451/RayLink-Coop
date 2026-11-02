// Anomaly Coop unit tests: what a map server's logic says of "the actor" goes to the players of its level (xrCoop/coop_ghost_rules.h).
#include "test_util.h"

#include "coop_ghost_rules.h"

#include <vector>

using namespace coop::ghost;

namespace
{
Said to_actor(int32_t npc, int32_t value) { return Said{13, false, npc, kActor, value}; }

std::vector<Said> told(Log& log, uint16_t proxy, uint32_t budget = 100)
{
	std::vector<Said> out;
	log.tell(proxy, budget, [&](const Said& s) { out.push_back(s); });
	return out;
}
} // namespace

TEST(ghost_a_goodwill_to_the_actor_is_about_it)
{
	CHECK(about_actor(to_actor(700, -1000)));
	CHECK(about_actor(Said{13, false, kActor, 700, 1000}));
	CHECK(about_actor(Said{31, true, 5, kActor, 100}));
	CHECK(!about_actor(Said{13, false, 700, 701, 100}));
	CHECK(!about_actor(Said{31, true, 0, 500, 100})); // community 0 is a community, not the actor
}

TEST(ghost_the_player_stands_for_the_actor_on_either_side)
{
	Said a = to_actor(700, -1000);
	CHECK(for_player(a, 500));
	CHECK_EQ(a.first, 700);
	CHECK_EQ(a.second, 500);
	CHECK_EQ(a.value, -1000);
	Said b{13, false, kActor, 700, 5};
	CHECK(for_player(b, 500));
	CHECK_EQ(b.first, 500);
	CHECK_EQ(b.second, 700);
}

TEST(ghost_a_community_stays_a_community)
{
	Said s{31, true, kActor, kActor, 100}; // community 0 to the actor
	CHECK(for_player(s, 500));
	CHECK_EQ(s.first, 0);
	CHECK_EQ(s.second, 500);
}

TEST(ghost_a_character_about_himself_is_no_request)
{
	Said s = to_actor(500, 100);
	CHECK(!for_player(s, 500));
	Log log;
	log.add(to_actor(500, 100));
	CHECK(told(log, 500).empty());
	CHECK_EQ(told(log, 501).size(), size_t(1));
}

TEST(ghost_every_player_hears_each_word_once)
{
	Log log;
	log.add(to_actor(700, -1000));
	log.add(to_actor(701, -1000));
	const auto first = told(log, 500);
	CHECK_EQ(first.size(), size_t(2));
	CHECK_EQ(first[1].first, 701);
	CHECK_EQ(first[1].second, 500);
	CHECK(told(log, 500).empty());
	CHECK(!log.pending(500));
	log.add(to_actor(702, 0));
	CHECK(log.pending(500));
	CHECK_EQ(told(log, 500).size(), size_t(1));
}

TEST(ghost_who_comes_later_hears_everything)
{
	Log log;
	log.add(to_actor(700, -1000));
	CHECK(log.pending(501));
	CHECK_EQ(told(log, 500).size(), size_t(1));
	const auto late = told(log, 501);
	CHECK_EQ(late.size(), size_t(1));
	CHECK_EQ(late[0].second, 501);
}

TEST(ghost_a_player_who_comes_back_hears_no_change_twice)
{
	Log log;
	log.add(Said{12, false, 700, kActor, -50}); // a delta
	CHECK_EQ(told(log, 500).size(), size_t(1));
	log.add(to_actor(701, 0));
	CHECK_EQ(told(log, 500).size(), size_t(1));
}

TEST(ghost_a_frame_tells_as_much_as_its_budget)
{
	Log log;
	for (int i = 0; i < 5; ++i)
		log.add(to_actor(700 + i, 0));
	CHECK_EQ(told(log, 500, 2).size(), size_t(2));
	CHECK(log.pending(500));
	const auto rest = told(log, 500, 10);
	CHECK_EQ(rest.size(), size_t(3));
	CHECK_EQ(rest[0].first, 702);
}

TEST(ghost_the_log_keeps_the_newest)
{
	Log log;
	for (size_t i = 0; i < Log::kMax + 3; ++i)
		log.add(to_actor(int32_t(i + 1000), 0));
	CHECK_EQ(log.size(), Log::kMax);
	std::vector<Said> all;
	while (log.pending(500))
		log.tell(500, 4096, [&](const Said& s) { all.push_back(s); });
	CHECK_EQ(all.size(), Log::kMax);
	CHECK_EQ(all[0].first, 1003);
}
