// R32 WP4 (W9): one generator per slice. A map server's pool is its slice and the blocks the world gave it; it hands out its own free
// ids and nothing else (an empty pool answers kNoObject, never a stock id); a refused id stays reserved; below the low-water mark it
// asks for another block, once per kIdAskAgainMs. The world gives blocks of its own free ids below the slices, never one twice, and
// takes a Spawn under a block it gave that bridge (review WP4 #4). Not tested here, open (review WP4 #5): the engine's PerformIDgen
// still hands an empty pool's kNoObject to the stock generator (xrServer.h), so the create is not refused yet.
#include "test_util.h"

#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"
#include "srv/coop_levels_keeper.h"

#include <set>

using namespace coop;
using namespace coop::levels;

TEST(levels_ids_the_pool_hands_out_only_its_own_ids)
{
	IdPool pool;
	pool.reset(0x9000, 8);
	std::set<uint16_t> taken;
	const auto free_here = [&](uint16_t id) { return taken.count(id) == 0; }; // the stock generator: every id it has not handed out
	for (int i = 0; i < 8; ++i)
	{
		const uint16_t id = pool.next(free_here);
		REQUIRE(id != wire::kNoObject);
		CHECK(id >= 0x9000 && id < 0x9008);
		CHECK(taken.insert(id).second);
	}
	// every id of the pool is in use: no id at all, although the stock generator has thousands more
	CHECK_EQ(pool.next(free_here), wire::kNoObject);
	taken.erase(0x9003); // one comes back
	CHECK_EQ(pool.next(free_here), uint16_t(0x9003));
}

// The pool alone: with no slice, a slice out of range or every id in use it answers no id (what the engine then does with it is
// PerformIDgen's, see the head of this file).
TEST(levels_ids_an_empty_pool_answers_no_id)
{
	IdPool pool;
	pool.reset(0, 0); // no slice (no map server number)
	CHECK_EQ(pool.size(), size_t(0));
	CHECK_EQ(pool.next([](uint16_t) { return true; }), wire::kNoObject);
	pool.reset(leader_ids_of(kLeaderSlots + 1), kLeaderIdsEach); // a number beyond the slices: leader_ids_of says 0
	CHECK_EQ(pool.next([](uint16_t) { return true; }), wire::kNoObject);
	pool.reset(leader_ids_of(1), kLeaderIdsEach);
	CHECK_EQ(pool.next([](uint16_t) { return false; }), wire::kNoObject); // all in use: refused here, the create finds no id
}

TEST(levels_ids_a_refused_id_stays_reserved)
{
	IdPool pool;
	pool.reset(0x9000, 3);
	pool.reserve(0x9001);
	pool.reserve(0x1234); // not of the pool: nothing
	CHECK(pool.reserved(0x9001));
	CHECK(!pool.reserved(0x1234));
	std::set<uint16_t> got;
	for (int i = 0; i < 6; ++i)
		got.insert(pool.next([](uint16_t) { return true; }));
	CHECK(got.count(0x9001) == 0);
	CHECK_EQ(pool.free_count([](uint16_t) { return true; }), size_t(2));
	pool.reset(0x9000, 3); // a new world
	CHECK(!pool.reserved(0x9001));
}

TEST(levels_ids_low_water_asks_for_a_block_once_until_it_comes)
{
	IdPool pool;
	pool.reset(0x9000, kLeaderIdsEach);
	const auto all_free = [](uint16_t) { return true; };
	CHECK_EQ(pool.free_count(all_free, kIdLowWater), kIdLowWater); // the count stops at the mark
	CHECK(!pool.ask_now(pool.free_count(all_free, kIdLowWater), 0)); // plenty: no ask
	const size_t low = kIdLowWater - 1;
	CHECK(pool.ask_now(low, 1000));
	CHECK(pool.asking());
	CHECK(!pool.ask_now(low, 1000 + kIdAskAgainMs - 1)); // asked: no second ask before the answer or the timeout
	CHECK(pool.ask_now(low, 1000 + kIdAskAgainMs)); // no answer: again
	CHECK(pool.add_block(0x8C00, kIdBlockSize));
	CHECK(!pool.asking());
	CHECK(pool.owns(0x8C00));
	CHECK(pool.owns(0x8FFF));
	CHECK(!pool.owns(0x8BFF));
	CHECK_EQ(pool.size(), size_t(kLeaderIdsEach) + kIdBlockSize);
	// the block's ids are handed out too once the slice is used up
	const auto only_block = [](uint16_t id) { return id >= 0x8C00 && id < 0x9000; };
	const uint16_t id = pool.next(only_block);
	CHECK(id >= 0x8C00 && id < 0x9000);
}

TEST(levels_ids_a_block_that_does_not_fit_is_refused)
{
	IdPool pool;
	pool.reset(0x9000, kLeaderIdsEach);
	CHECK(!pool.add_block(0x9100, 16)); // inside the slice
	CHECK(!pool.add_block(0xFFF0, 0x10)); // reaches kNoObject
	CHECK(!pool.add_block(0x8000, 0)); // empty
	for (size_t i = 0; i < kIdBlocksEach; ++i)
		CHECK(pool.add_block(uint16_t(0x7000 + i * 0x100), 0x100));
	CHECK(!pool.add_block(0x6000, 0x100)); // over the limit
	CHECK(!pool.ask_now(0, 0)); // and asks no more
}

TEST(levels_ids_the_world_gives_free_blocks_below_the_slices_never_twice)
{
	IdGrants grants;
	std::set<uint16_t> world; // ids the world's objects hold
	world.insert(0x8F00); // an object in the top run
	const auto is_free = [&](uint16_t id) { return world.count(id) == 0; };
	IdBlock a, b;
	REQUIRE(grants.grant(1, is_free, a));
	CHECK_EQ(a.count, kIdBlockSize);
	CHECK(uint32_t(a.first) + a.count <= kIdGrantTop);
	CHECK(a.first >= kIdGrantFloor);
	CHECK(!a.has(0x8F00)); // never an id an object holds
	REQUIRE(grants.grant(2, is_free, b));
	CHECK(!a.meets(b)); // two bridges never share an id
	CHECK(grants.granted_to(1, a.first));
	CHECK(!grants.granted_to(2, a.first));
	CHECK(grants.granted_to(2, b.first));
	CHECK_EQ(grants.all().size(), size_t(2));
	// the limit per bridge, and the range runs out
	IdBlock c;
	size_t given = 1;
	while (grants.grant(1, is_free, c))
		++given;
	CHECK(given <= kIdBlocksEach);
	// gone: its blocks may be given again
	const std::vector<IdBlock> back = grants.forget(1);
	CHECK_EQ(back.size(), given);
	CHECK(!grants.granted_to(1, a.first));
	IdBlock again;
	CHECK(grants.grant(3, is_free, again));
}

TEST(levels_ids_nothing_left_gives_no_block)
{
	IdGrants grants;
	IdBlock out;
	CHECK(!grants.grant(1, [](uint16_t) { return false; }, out)); // a world with every id below the slices in use
	CHECK_EQ(out.count, uint16_t(0));
}

// Review WP4 #4: the world takes a Spawn under an id of the sender's slice or of a block it gave that bridge (id_is_senders, which
// coop_levels_alife.cpp host_apply_fact asks through levels::host_id_is_senders), and refuses one under another bridge's block.
TEST(levels_ids_a_spawn_under_a_granted_block_is_the_senders)
{
	namespace acc = coop::levels::accept;
	constexpr coop::PeerId kOne = 101, kTwo = 102;
	IdGrants grants;
	IdBlock a, b;
	REQUIRE(grants.grant(kOne, [](uint16_t) { return true; }, a));
	REQUIRE(grants.grant(kTwo, [](uint16_t) { return true; }, b));
	const uint16_t slice = leader_ids_of(1);
	const auto spawn = [&](coop::PeerId sender, uint16_t id) {
		acc::Facts f;
		f.op = wire::LevelEntityHead::Spawn;
		f.sender = sender;
		f.sender_level = 5;
		f.exists = false;
		f.writer = coop::writer::other(sender); // it stands on the sender's map
		f.id_in_slice = id_is_senders(id, sender == kOne ? slice : leader_ids_of(2), grants, sender);
		return acc::accepts(f);
	};
	CHECK(spawn(kOne, slice).ok); // its slice
	CHECK(spawn(kOne, uint16_t(a.first + 7)).ok); // its block
	const acc::Verdict foreign = spawn(kOne, uint16_t(b.first + 7)); // another bridge's block
	CHECK(!foreign.ok);
	CHECK_EQ(foreign.why, uint8_t(coop::levels::journal::IdRange));
	CHECK(!spawn(kOne, uint16_t(kIdGrantFloor - 1)).ok); // nobody's
	CHECK(spawn(kTwo, uint16_t(b.first)).ok);
	grants.forget(kOne); // its map server is gone: its block is nobody's
	CHECK(!spawn(kOne, uint16_t(a.first + 7)).ok);
	CHECK(!id_is_senders(slice, 0, grants, kOne)); // no slice
}
