// Anomaly Coop unit tests: weapon state riders follow the concrete weapon (xrCoop/coop_item_rider_rules.h, F4 G3-1c,
// findings m01:2 3DSS camo and m27:5 the Lua jam type). A client's move of its weapon carries the riders, so the process
// that applies the move writes them before the item changes hands; one tick counter orders the Lua inbox's arrivals and the
// releases of entities, so a rider that waited while its weapon was released and replaced never reaches the replacement.
// The same rules run in both modes; the cases name the process that asks: the co-op host and a co-op client, a map server
// (one map, two maps) and the world server.
#include "test_util.h"

#include "coop_item_rider_rules.h"

#include <limits>

using namespace coop::riders;

namespace
{
constexpr uint16_t kGun = 800, kOther = 801;

// coop_script.cpp's counter: deliver_later and note_released each take the next tick.
struct Ticks
{
	uint64_t now = 0;
	uint64_t next() { return ++now; }
};
} // namespace

// The client side (send_action): only a weapon leaving our character carries its riders.
TEST(item_riders_client_carries_a_weapon_leaving_its_character)
{
	CHECK(carries(true, true, false, false)); // drop, gift, into a box, to an NPC
	CHECK(!carries(false, true, false, false)); // not a weapon: no rider of this adapter
	CHECK(!carries(true, false, true, false)); // a take
	CHECK(!carries(true, false, false, false)); // between two others: not ours to ask
	CHECK(!carries(true, true, true, false)); // inside our character
	CHECK(!carries(true, true, false, true)); // a thrown missile or launched rocket we applied already
}

TEST(item_riders_text_bound)
{
	CHECK_EQ(text_of(0), Text::None);
	CHECK_EQ(text_of(1), Text::Fits);
	CHECK_EQ(text_of(kMaxCarry), Text::Fits);
	CHECK_EQ(text_of(kMaxCarry + 1), Text::TooLong);
	CHECK_EQ(text_of(std::numeric_limits<size_t>::max()), Text::TooLong);
}

// Co-op host: a client's ReqDrop / ReqTransfer of the weapon his character holds -> the riders go to Lua before the move.
TEST(item_riders_coop_host_takes_the_holders_riders)
{
	CHECK_EQ(judge(0, true), Carried::None);
	CHECK_EQ(judge(120, true), Carried::Take);
	CHECK_EQ(judge(kMaxCarry, true), Carried::Take);
	CHECK_EQ(judge(kMaxCarry + 1, true), Carried::TooLong); // a modified client's flood never reaches Lua
	CHECK_EQ(judge(120, false), Carried::NotHolder); // riders of an item he does not hold: never written
	CHECK_EQ(judge(kMaxCarry + 1, false), Carried::TooLong);
}

// Server, one map or two: the map server of the player's level applies his move (the world tunnels the request whole), with
// the same check; what it writes goes up to the world server as a map's fact.
TEST(item_riders_map_server_judges_like_the_coop_host)
{
	struct Row
	{
		size_t size;
		bool holds;
		Carried want;
	};
	const Row rows[] = {
		{0, false, Carried::None}, {1, true, Carried::Take}, {800, true, Carried::Take},
		{800, false, Carried::NotHolder}, // he stood on map two and the gun is another's on map one
		{kMaxCarry, true, Carried::Take}, {kMaxCarry + 1, true, Carried::TooLong},
	};
	for (const Row& r : rows)
		CHECK_EQ(judge(r.size, r.holds), r.want);
}

TEST(item_riders_lua_arguments_are_bounded)
{
	CHECK(valid_id(0));
	CHECK(valid_id(800));
	CHECK(valid_id(65535));
	CHECK(!valid_id(-1));
	CHECK(!valid_id(65536));
	CHECK(!valid_id(8.5));
	CHECK(!valid_id(std::numeric_limits<double>::quiet_NaN()));
	CHECK(!valid_id(std::numeric_limits<double>::infinity()));
	CHECK(valid_tick(0));
	CHECK(valid_tick(123456789));
	CHECK(valid_tick(double(kMaxTick)));
	CHECK(!valid_tick(double(kMaxTick) * 2));
	CHECK(!valid_tick(-3));
	CHECK(!valid_tick(0.25));
	CHECK(!valid_tick(std::numeric_limits<double>::quiet_NaN()));
}

TEST(item_riders_release_book_orders_releases)
{
	ReleaseBook book;
	CHECK(!book.released_after(kGun, 0)); // never released
	CHECK_EQ(book.last(kGun), uint64_t(0));
	book.note(kGun, 5);
	CHECK(book.released_after(kGun, 4));
	CHECK(!book.released_after(kGun, 5)); // at the same tick: not after
	CHECK(!book.released_after(kGun, 6));
	CHECK(!book.released_after(kOther, 0));
	book.note(kGun, 3); // an older tick never lowers the last release
	CHECK_EQ(book.last(kGun), uint64_t(5));
	book.note(kGun, 9); // the id was taken again and released again
	CHECK(book.released_after(kGun, 6));
	book.note(0, 1);
	book.note(65535, 2);
	CHECK(book.released_after(0, 0));
	CHECK(book.released_after(65535, 1));
	CHECK_EQ(book.notes(), uint64_t(5));
	book.clear();
	CHECK(!book.released_after(kGun, 0));
	CHECK_EQ(book.notes(), uint64_t(0));
}

TEST(item_riders_a_kept_release_is_not_noted_a_later_release_is)
{
	ReleaseBook book;
	book.keep_next(kGun);
	book.keep_next(kGun); // repeated marks still cover a single release
	book.note(kGun, 5);
	CHECK(!book.released_after(kGun, 4));
	CHECK_EQ(book.notes(), uint64_t(0));
	book.note(kGun, 6);
	CHECK(book.released_after(kGun, 5));
	CHECK_EQ(book.notes(), uint64_t(1));

	book.keep_next(kOther);
	book.unkeep(kOther); // cancelled rebuild
	book.note(kOther, 7);
	CHECK(book.released_after(kOther, 6));
}

// Co-op client: the host's relay of a camo for the old weapon waits in the Lua inbox, the host's EntityDestroy and the
// replacement's EntitySpawn run at once. The relay arrived before the release: stale. The replacement's own rider comes
// after the release: fresh.
TEST(item_riders_coop_client_drops_a_rider_older_than_the_release)
{
	Ticks t;
	ReleaseBook book;
	const uint64_t old_relay = t.next();
	book.note(kGun, t.next()); // EntityDestroy -> release; the Lua callback may never have run
	const uint64_t new_relay = t.next();
	CHECK(book.released_after(kGun, old_relay));
	CHECK(!book.released_after(kGun, new_relay));
	CHECK(!book.released_after(kOther, old_relay)); // another weapon's rider of the same moment is untouched
}

// Co-op host (the world): a client's rider for a weapon the host released and replaced at once (a script, a clone) before
// its Lua inbox ran. And what Lua held for the old instance: bound when Lua began to hold it, so the release after that
// moment says the state belongs to the released weapon.
TEST(item_riders_coop_host_drops_what_belongs_to_a_released_weapon)
{
	Ticks t;
	ReleaseBook book;
	const uint64_t held_since = t.next(); // Lua stores the camo of the old gun
	const uint64_t client_rider = t.next(); // the client's next change waits in the inbox
	book.note(kGun, t.next()); // released and replaced under the same name
	CHECK(book.released_after(kGun, held_since));
	CHECK(book.released_after(kGun, client_rider));
	const uint64_t rebound = t.next(); // Lua forgot the old state and holds the replacement's from now
	CHECK(!book.released_after(kGun, rebound));
}

// Server, two maps: the weapon leaves map one with its carrier. Map one releases its copy (the instance goes on on map two):
// a rider that reached map one before is dropped there, the world server never released it and keeps what it has.
TEST(item_riders_map_change_releases_only_on_the_left_map)
{
	Ticks map_one, world;
	ReleaseBook book_one, book_world;
	const uint64_t at_one = map_one.next();
	const uint64_t at_world = world.next();
	book_one.note(kGun, map_one.next());
	CHECK(book_one.released_after(kGun, at_one));
	CHECK(!book_world.released_after(kGun, at_world));
}
