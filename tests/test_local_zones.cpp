// Anomaly Coop unit tests: personal map zones (xrCoop/coop_local_zones.h). A script_zone a client's script creates without
// a parent (Personal Adjustable Waypoint: the zone behind every pin and every right click on the PDA map) exists on that
// machine only, under an id the host lent it (coop_id_lease.h ClientPool). The book hands the ids out, keeps some of the
// lease for items, and takes an id back into the pool when the zone is released.
#include "test_util.h"

#include "coop_id_lease.h"
#include "coop_local_zones.h"

#include <set>
#include <vector>

using namespace coop;

namespace
{
// A pool the way client_on_lease fills it: the ids are reserved here, none is taken yet.
lease::ClientPool pool_of(size_t n, uint16_t first = 300)
{
	lease::ClientPool pool;
	std::vector<uint16_t> ids, rejected;
	for (size_t i = 0; i < n; ++i)
		ids.push_back(uint16_t(first + i));
	pool.add(1, ids, [](uint16_t) { return true; }, rejected);
	return pool;
}

bool reserve_ok(uint16_t) { return true; }
bool reserve_no(uint16_t) { return false; }
} // namespace

TEST(zones_which_creates_are_personal)
{
	CHECK(zones::local_section("script_zone"));
	CHECK(!zones::local_section(""));
	CHECK(!zones::local_section("script_zone_2"));
	CHECK(!zones::local_section("Script_Zone"));
	CHECK(!zones::local_section("wpn_pm"));
	CHECK(!zones::local_section("anomaly_zone"));
	CHECK(zones::wants("script_zone", zones::kNoId)); // alife():create(section, pos, lvid, gvid): no parent
	CHECK(!zones::wants("script_zone", 0)); // into the actor: an item's business, never a zone
	CHECK(!zones::wants("script_zone", 1234));
	CHECK(!zones::wants("wpn_pm", zones::kNoId)); // a world spawn of anything else stays the host's
	CHECK(!zones::wants("", zones::kNoId));
}

TEST(zones_issue_takes_the_ids_of_the_pool_in_order)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t a = book.issue(pool);
	const uint16_t b = book.issue(pool);
	CHECK_EQ(a, uint16_t(300));
	CHECK_EQ(b, uint16_t(301));
	CHECK(book.has(a) && book.has(b));
	CHECK(!pool.has(a) && !pool.has(b)); // an id is a zone's or the pool's, never both
	CHECK_EQ(pool.size(), size_t(18));
	CHECK_EQ(book.size(), size_t(2));
	CHECK(!book.has(302));
}

TEST(zones_leave_some_of_the_lease_to_items)
{
	lease::ClientPool pool = pool_of(zones::kKeepForItems + 3);
	zones::Book book;
	std::set<uint16_t> got;
	for (int i = 0; i < 10; ++i)
	{
		const uint16_t id = book.issue(pool);
		if (id != zones::kNoId)
			got.insert(id);
	}
	CHECK_EQ(got.size(), size_t(3)); // the pool never goes below kKeepForItems for a zone
	CHECK_EQ(pool.size(), zones::kKeepForItems);
	CHECK_EQ(book.issue(pool), zones::kNoId); // no id to spare: no zone (the old refusal, nil)
	CHECK_EQ(book.stats().refused, uint64_t(8)); // 7 of the ten asks of the loop, and this one
	// items still get every id that is left
	size_t items = 0;
	while (pool.take() != lease::kNoId)
		++items;
	CHECK_EQ(items, zones::kKeepForItems);
}

TEST(zones_an_empty_pool_gives_nothing)
{
	lease::ClientPool pool;
	zones::Book book;
	CHECK_EQ(book.issue(pool), zones::kNoId);
	CHECK_EQ(book.size(), size_t(0));
	lease::ClientPool exact = pool_of(zones::kKeepForItems); // exactly what items keep: nothing to spare
	CHECK_EQ(book.issue(exact), zones::kNoId);
	CHECK_EQ(exact.size(), zones::kKeepForItems);
}

TEST(zones_a_released_zone_gives_its_id_back_to_the_pool)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t id = book.issue(pool);
	std::vector<uint16_t> reserved;
	const zones::Fate fate = book.retire(pool, id, [&reserved](uint16_t i) { reserved.push_back(i); return true; });
	CHECK(fate == zones::Fate::Pool);
	CHECK_EQ(reserved.size(), size_t(1)); // it is reserved again in the generator before it is the pool's
	CHECK_EQ(reserved.front(), id);
	CHECK(pool.has(id));
	CHECK(!book.has(id));
	CHECK_EQ(pool.size(), size_t(20));
	CHECK_EQ(book.size(), size_t(0));
	// the id is the last of the pool now: first in, first out
	std::vector<uint16_t> order;
	for (uint16_t t = 0; (t = pool.take()) != lease::kNoId;)
		order.push_back(t);
	REQUIRE(order.size() == 20);
	CHECK_EQ(order.back(), id);
}

TEST(zones_an_id_that_is_not_a_zones_goes_nowhere)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t id = book.issue(pool);
	int asked = 0;
	const auto counting = [&asked](uint16_t) { ++asked; return true; };
	CHECK(book.retire(pool, 999, counting) == zones::Fate::NotOurs); // an id nobody leased
	CHECK(book.retire(pool, 0, counting) == zones::Fate::NotOurs); // the actor
	CHECK(book.retire(pool, lease::kNoId, counting) == zones::Fate::NotOurs);
	CHECK(book.retire(pool, 302, counting) == zones::Fate::NotOurs); // in the pool, not issued
	CHECK_EQ(asked, 0); // nothing was reserved for them
	CHECK_EQ(pool.size(), size_t(19));
	CHECK(book.retire(pool, id, counting) == zones::Fate::Pool);
	CHECK(book.retire(pool, id, counting) == zones::Fate::NotOurs); // a second release of the same zone changes nothing
	CHECK_EQ(asked, 1);
	CHECK_EQ(pool.size(), size_t(20));
	std::set<uint16_t> unique;
	for (uint16_t t = 0; (t = pool.take()) != lease::kNoId;)
		unique.insert(t);
	CHECK_EQ(unique.size(), size_t(20)); // no id twice in the pool
}

TEST(zones_an_id_the_generator_will_not_reserve_is_lost_not_pooled)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t id = book.issue(pool);
	CHECK(book.retire(pool, id, reserve_no) == zones::Fate::Lost);
	CHECK(!pool.has(id)); // somebody else holds it here: never lent out again
	CHECK(!book.has(id));
	CHECK_EQ(pool.size(), size_t(19));
	CHECK_EQ(book.stats().lost, uint64_t(1));
}

TEST(zones_made_and_released_again_and_again_do_not_use_the_lease_up)
{
	lease::ClientPool pool = pool_of(lease::kLeaseSize);
	zones::Book book;
	std::vector<uint16_t> alive;
	for (int round = 0; round < 1000; ++round)
	{
		const uint16_t id = book.issue(pool);
		REQUIRE(id != zones::kNoId);
		alive.push_back(id);
		if (alive.size() > 5) // a few pins at a time, the oldest goes
		{
			CHECK(book.retire(pool, alive.front(), reserve_ok) == zones::Fate::Pool);
			alive.erase(alive.begin());
		}
	}
	CHECK_EQ(book.size(), alive.size());
	CHECK_EQ(pool.size() + book.size(), lease::kLeaseSize); // every id is somewhere, none given back to the host
	CHECK_EQ(book.stats().issued, uint64_t(1000));
	CHECK_EQ(book.stats().refused, uint64_t(0));
	CHECK_EQ(book.stats().lost, uint64_t(0));
}

TEST(zones_an_id_of_a_zone_that_was_not_made_is_the_callers)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t id = book.issue(pool);
	CHECK(book.cancel(id));
	CHECK(!book.has(id));
	CHECK(!pool.has(id)); // neither the book's nor the pool's: the caller decides (pool, or the host)
	CHECK(!book.cancel(id));
	CHECK(!book.cancel(500));
	CHECK(book.retire(pool, id, reserve_ok) == zones::Fate::NotOurs);
}

TEST(zones_a_new_world_forgets_them)
{
	lease::ClientPool pool = pool_of(20);
	zones::Book book;
	const uint16_t a = book.issue(pool);
	book.issue(pool);
	book.clear();
	pool.clear(); // the ids went with the old generator (client_pump: lease_sync_world_locked)
	CHECK_EQ(book.size(), size_t(0));
	CHECK(!book.has(a));
	CHECK(book.retire(pool, a, reserve_ok) == zones::Fate::NotOurs); // a release of a zone of the old world
	CHECK_EQ(pool.size(), size_t(0));
}
